# =============================================================================
# 04_availability.R — who is actually gettable today.
#
# This is the difference between a transaction list and a tool. Walk each
# player's events in order; the last one that changes his market status decides
# whether he is available. Without it a player who was designated and then
# claimed by someone else still reads as a target, and a player another club
# just signed reads as available.
#
# "Signed" and "Claimed" mean somebody already got him. "Outrighted" means he
# cleared waivers and stayed in his own organization. None are opportunities.
# =============================================================================

suppressPackageStartupMessages({ library(dplyr); library(purrr); library(tibble) })

#' @param txns tibble from fetch_transactions, enriched with org/scope/level
#' @param as_of date the clock is measured against
#' @param roster40 named list keyed by player id
#' @return named list keyed by player id
build_availability <- function(txns, as_of = AS_OF, roster40 = list()) {
  tx <- txns %>% filter(!is.na(mlbam_id)) %>%
    arrange(mlbam_id, date, txn_id)
  if (nrow(tx) == 0) return(list())

  split_idx <- split(seq_len(nrow(tx)), tx$mlbam_id)
  out <- list()

  for (pid_chr in names(split_idx)) {
    rows <- tx[split_idx[[pid_chr]], ]
    last_open <- NULL; closed_by <- NULL
    for (i in seq_len(nrow(rows))) {
      ty <- rows$txn_type[i]
      if (ty %in% MARKET_OPEN) {
        last_open <- rows[i, ]; closed_by <- NULL
      } else if (ty %in% MARKET_CLOSE) {
        if (!is.null(last_open)) closed_by <- rows[i, ]
        last_open <- NULL
      }
    }

    available <- !is.null(last_open)
    days_left <- NA_integer_; expired <- FALSE; stale <- FALSE
    if (available && identical(last_open$txn_type, "DFA")) {
      deadline <- last_open$date + DFA_WINDOW
      days_left <- as.integer(deadline - as_of)
      if (days_left < 0) { expired <- TRUE; available <- FALSE }
    } else if (available &&
               as.integer(as_of - last_open$date) > STALE_AFTER) {
      stale <- TRUE; available <- FALSE
    }

    src <- if (!is.null(last_open)) last_open else rows[nrow(rows), ]
    on40 <- !is.null(roster40[[pid_chr]])

    status <-
      if (available && identical(last_open$txn_type, "DFA")) "DFA"
      else if (available) "Free agent"
      else if (expired) "Window lapsed"
      else if (stale) "Stale listing"
      else if (!is.null(closed_by) && closed_by$txn_type == "Claimed") "Claimed"
      else if (!is.null(closed_by) && closed_by$txn_type == "Signed") "Signed elsewhere"
      else if (!is.null(closed_by) && closed_by$txn_type == "Trade") "Traded"
      else if (!is.null(closed_by) && closed_by$txn_type == "Outrighted") "Stayed in org"
      else if (!is.null(closed_by)) "Resolved"
      else "Rostered"

    path <- NULL; cost <- NULL
    if (available) {
      if (identical(last_open$txn_type, "DFA")) {
        path <- "Waiver claim"
        cost <- "Claiming him takes a 40-man spot and his remaining salary."
      } else {
        path <- "Free agent signing"
        cost <- paste("He is a free agent. A major league deal needs a 40-man spot;",
                      "a minor league deal does not.")
      }
    }

    out[[pid_chr]] <- list(
      st = status, avail = available,
      scope = src$scope %||% NA_character_, lvl = src$level %||% NA_character_,
      openType = if (!is.null(last_open)) last_open$txn_type else NA_character_,
      since = as.character(src$date),
      onMarketDays = as.integer(as_of - src$date),
      days = if (is.na(days_left)) NULL else days_left,
      by = if (!is.null(closed_by)) closed_by$org else NULL,
      byType = if (!is.null(closed_by)) closed_by$txn_type else NULL,
      from = src$org %||% NULL,
      path = path, cost = cost,
      on40 = on40
    )
  }
  out
}

#' How often a player who hits the market at each level is actually acquired by
#' another club.
#'
#' Measured over the 2026 season: 396 rookie-level players reached the market
#' and twelve were taken, a 3.0% rate against 32.4% in the majors and 26.1% in
#' Triple-A. Rookie and complex ball nonetheless supplied about a third of the
#' board, so a third of what the page showed was, by its own purpose, noise.
#'
#' Computed from whatever history the build pulled rather than hardcoded, so
#' the number stays true next season instead of quietly going stale.
acquisition_rates <- function(txns) {
  tx <- txns %>% filter(!is.na(mlbam_id), affiliated) %>%
    arrange(mlbam_id, date, txn_id)
  if (nrow(tx) == 0) return(list())

  opened <- list(); taken <- list()
  for (idx in split(seq_len(nrow(tx)), tx$mlbam_id)) {
    rows <- tx[idx, ]
    open_lv <- NULL; open_from <- NULL
    for (i in seq_len(nrow(rows))) {
      ty <- rows$txn_type[i]
      if (ty %in% MARKET_OPEN) {
        open_lv <- rows$level[i]; open_from <- rows$org[i]
        if (!is.na(open_lv)) opened[[open_lv]] <- (opened[[open_lv]] %||% 0) + 1
      } else if (ty %in% c("Claimed", "Signed", "Trade")) {
        if (!is.null(open_lv) && !is.na(open_lv) && !is.na(rows$org[i]) &&
            !identical(rows$org[i], open_from))
          taken[[open_lv]] <- (taken[[open_lv]] %||% 0) + 1
        open_lv <- NULL
      } else if (ty %in% MARKET_CLOSE) {
        open_lv <- NULL
      }
    }
  }
  out <- list()
  for (lv in names(opened)) {
    n <- opened[[lv]]; k <- taken[[lv]] %||% 0
    if (n < 20) next                       # too thin to quote a rate
    out[[lv]] <- list(opened = as.integer(n), acquired = as.integer(k),
                      rate = round(k / n, 4))
  }
  out
}

#' Mark who is new to the market since a cutoff. A returning reader wants the
#' handful that changed, not the whole board again.
mark_new_entrants <- function(avail, txns, as_of = AS_OF, days = 7L) {
  cutoff <- as_of - days
  prior <- build_availability(txns %>% filter(date <= cutoff), as_of = cutoff)
  was <- names(prior)[vapply(prior, function(a) isTRUE(a$avail), logical(1))]
  for (pid in names(avail))
    avail[[pid]]$new <- isTRUE(avail[[pid]]$avail) && !(pid %in% was)
  avail
}

#' Scope and organization for each transaction. 40-man roster events stay MLB
#' whatever the destination level; everything else falls back to the club's
#' sportId rather than a regex over the description text.
enrich_transactions <- function(txns, teams) {
  tm <- teams %>% select(team_id, club, parent_org, sport_id, level)
  txns %>%
    left_join(tm %>% rename(to_team_id = team_id, to_club = club,
                            to_parent = parent_org, to_sport = sport_id,
                            to_level = level), by = "to_team_id") %>%
    left_join(tm %>% rename(from_team_id = team_id, from_club = club,
                            from_parent = parent_org, from_sport = sport_id,
                            from_level = level), by = "from_team_id") %>%
    mutate(
      org   = coalesce(to_parent, from_parent),
      level = coalesce(to_level, from_level),
      # amateur, independent and foreign-league clubs appear in this feed;
      # they are kept but excluded from need matching
      affiliated = !is.na(org),
      scope = case_when(
        !affiliated ~ "Other",
        txn_type %in% MLB40_EVENTS ~ "MLB",
        !is.na(to_sport)   & to_sport   == MLB_SPORT ~ "MLB",
        !is.na(from_sport) & from_sport == MLB_SPORT ~ "MLB",
        !is.na(to_sport) | !is.na(from_sport) ~ "MiLB",
        TRUE ~ "MLB"),
      opens = txn_type %in% MARKET_OPEN
    )
}
