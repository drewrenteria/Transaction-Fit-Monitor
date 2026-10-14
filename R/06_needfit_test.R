# =============================================================================
# 06_needfit_test.R — does need-matching predict WHICH club acquires a player?
#
# The backtest in python/backtest.py asks whether a well-graded player gets
# picked up by anyone. That is close to asking whether good players are good,
# and it is not the claim this dashboard makes. The dashboard claims that
# matching a player's production to a SPECIFIC club's holes carries
# information. That is the claim tested here.
#
# Design, and why it controls for the thing that matters:
#
#   For every event where a club acquired a player off the market, score that
#   player against the acquiring club's flagged needs AND against each of the
#   other 29 clubs' needs, all as of the same date.
#
#   Because every comparison inside an event uses the SAME player in the SAME
#   week, player quality is held constant by construction. So is the state of
#   the market. The only thing that varies across the 30 is whose needs are
#   being scored against. Under the null -- clubs pay no attention to need-fit
#   -- the acquiring club should land at the middle of that distribution, and
#   its mean percentile rank should be 0.50.
#
#   python/backtest.py cannot do this. It compares different players to each
#   other, so player quality swamps everything else.
#
# No lookahead: players are graded on their 2024-25 line, complete and public
# before the 2026 season began, and club needs are rebuilt from date-bounded
# FanGraphs leaderboards as of the acquisition date.
#
# WART: the thresholds below are duplicated from template.html, which is the
# other place they live. If you change one, change both. Folding them into
# 00_config.R and injecting them into the template would fix this properly.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(purrr); library(tibble)
})

# --- scoring thresholds, mirroring template.html ----------------------------
NEED_TO_STAT <- c("OBP"="OBP","SLG"="SLG","OPS"="OPS","ISO"="ISO","BB%"="BBp",
                  "K%"="Kp","ERA"="ERA","WHIP"="WHIP","HR/9"="HR9",
                  "wRC+"="wRCplus","FIP"="FIP","xFIP"="xFIP",
                  "DRS"="DRS","Def"="Def","BsR"="BsR","Spd"="Spd")

PIT_POS <- list(BBp = function(v) v <= 8.5, Kp = function(v) v >= 23,
                KBBp = function(v) v >= 15, WHIP = function(v) v <= 1.25,
                ERA = function(v) v <= 4.00, HR9 = function(v) v <= 1.10,
                FIP = function(v) v <= 4.00, xFIP = function(v) v <= 4.00)

HIT_POS <- list(OBP = function(v) v >= .330, BBp = function(v) v >= 9,
                Kp = function(v) v <= 22, ISO = function(v) v >= .170,
                OPS = function(v) v >= .750, SLG = function(v) v >= .400,
                wRCplus = function(v) v >= 105, BsR = function(v) v > 0,
                Def = function(v) v > 0, DRS = function(v) v > 0,
                Spd = function(v) v >= 5.0)

RELIABLE_PA <- c(Kp=60, BBp=120, ISO=160, SLG=200, OPS=200, OBP=200,
                 wRCplus=200, BsR=200, Def=200, DRS=200, Spd=200)
RELIABLE_IP <- c(Kp=17, BBp=40, KBBp=40, HR9=60, ERA=60, WHIP=60,
                 FIP=40, xFIP=40)
THIN_FLOOR  <- 0.6

#' Fraction of a club's relevant flagged needs that this player's line clears.
#'
#' "Relevant" means needs in categories the player can answer at all: a pitcher
#' is scored on Pitching needs, a position player on Hitting, Defense and
#' Baserunning.
#'
#' A club with NO relevant need is the interesting case, and the first version
#' of this got it wrong. Returning NA there and excluding the club looks
#' principled, but only 15 of 30 clubs carry a pitching need in a typical week,
#' so every pitcher failed the minimum comparison-set size and the whole test
#' ran on position players -- discarding 174 of 302 acquisitions, the majority.
#'
#' It is also the wrong call on the merits. A club with no pitching need does
#' not have missing data about a pitcher; it genuinely needs nothing he offers.
#' That is a real fit of zero, and whether clubs acquire pitchers when they
#' need pitching is the coarsest and most important version of the question.
#'
#' So `rate` scores an empty relevant-need set as 0, and `rate_strict` keeps
#' the NA for the narrower question: among clubs that DO need this player's
#' category, did the acquirer need him most? Both are reported.
#'
#' @param line named list of rates (the FanGraphs bat or pit record)
#' @param is_pit TRUE for a pitcher
#' @param needs  that club's flagged needs, as build_needs returns them
clear_rate <- function(line, is_pit, needs) {
  cats <- if (is_pit) "Pitching" else c("Hitting", "Defense", "Baserunning")
  rel  <- Filter(function(n) n$cat %in% cats, needs)
  if (length(rel) == 0)
    return(list(rate = 0, rate_strict = NA_real_, cleared = 0L, n = 0L))

  POS      <- if (is_pit) PIT_POS else HIT_POS
  RELIABLE <- if (is_pit) RELIABLE_IP else RELIABLE_PA
  sample   <- if (is_pit) n0(line$IP) else n0(line$PA)

  seen <- character(0); cleared <- 0L; counted <- 0L
  for (n in rel) {
    key <- unname(NEED_TO_STAT[n$metric])
    if (is.na(key) || key %in% seen) next
    seen <- c(seen, key)
    counted <- counted + 1L
    v <- line[[key]]
    if (is.null(v) || is.na(v)) next
    if (is.null(POS[[key]])) next
    # same two-tier reliability rule the page uses: a rate counts once the
    # sample is within THIN_FLOOR of where that metric stabilizes
    floor_n <- unname(RELIABLE[key]); if (is.na(floor_n)) floor_n <- 0
    if (sample < floor_n * THIN_FLOOR) next
    if (isTRUE(POS[[key]](v))) cleared <- cleared + 1L
  }
  if (counted == 0)
    return(list(rate = 0, rate_strict = NA_real_, cleared = 0L, n = 0L))
  list(rate = cleared / counted, rate_strict = cleared / counted,
       cleared = cleared, n = counted)
}

#' Every event where a club acquired a player who was on the market, and the
#' acquiring club is NOT the club that let him go.
#'
#' Re-signing your own designated player is not a market decision in the sense
#' being tested, so those are dropped.
collect_market_acquisitions <- function(txns) {
  tx <- txns %>% filter(!is.na(mlbam_id), affiliated) %>%
    arrange(mlbam_id, date, txn_id)
  if (nrow(tx) == 0) return(tibble())

  out <- list()
  for (idx in split(seq_len(nrow(tx)), tx$mlbam_id)) {
    rows <- tx[idx, ]
    open_from <- NULL; open_date <- NULL
    for (i in seq_len(nrow(rows))) {
      ty <- rows$txn_type[i]
      if (ty %in% MARKET_OPEN) {
        open_from <- rows$org[i]; open_date <- rows$date[i]
      } else if (ty %in% c("Claimed", "Signed", "Trade")) {
        if (!is.null(open_from) && !is.na(rows$org[i]) &&
            !identical(rows$org[i], open_from)) {
          out[[length(out) + 1]] <- tibble(
            mlbam_id = rows$mlbam_id[i], acquirer = rows$org[i],
            from = open_from, date = rows$date[i],
            open_date = open_date, how = ty,
            days_on_market = as.integer(rows$date[i] - open_date))
        }
        open_from <- NULL
      } else if (ty %in% MARKET_CLOSE) {
        open_from <- NULL
      }
    }
  }
  if (length(out) == 0) return(tibble())
  bind_rows(out)
}

#' Club needs as of a series of dates, each rebuilt from date-bounded
#' leaderboards. Cached per date, so a rerun costs no network calls.
needs_as_of <- function(dates, teams) {
  xw <- fg_crosswalk(teams)
  res <- list()
  for (d in as.character(dates)) {
    tag <- paste0("nf_", gsub("-", "", d))
    ft  <- fetch_fg_teams(date_to = d, tag = tag)
    if (length(ft$bat) == 0) { message("  no FanGraphs data for ", d); next }
    hit <- list(); pit <- list()
    for (i in seq_len(nrow(xw))) {
      r <- xw[i, ]
      b <- ft$bat[[r$fg_abbr]]; p <- ft$pit[[r$fg_abbr]]; f <- ft$fld[[r$fg_nick]]
      if (is.null(b) || is.null(p) || is.null(f)) next
      hit[[r$club]] <- c(b, list(DRS = f$DRS, Def = f$Def))
      pit[[r$club]] <- p
    }
    if (length(hit) < 25) { message("  thin crosswalk for ", d, ": ", length(hit)); next }
    res[[d]] <- build_needs(hit, pit, MLB_NEED_PLAN, cap = MAX_MLB_NEEDS_PER_CAT)
    message(sprintf("  %s: %.1f needs per club", d, mean(lengths(res[[d]]))))
  }
  res
}

#' Snap each acquisition back to the most recent grid date at or before it.
nearest_grid <- function(d, grid) {
  g <- as.Date(grid); g <- g[g <= d]
  if (length(g) == 0) return(NA_character_)
  as.character(max(g))
}

#' The test itself.
#'
#' For each acquisition, rank the acquiring club's clear-rate among all 30.
#' Ties share the average rank, so a player who answers nobody's needs (or
#' everybody's) lands at 0.50 rather than counting as evidence either way.
run_needfit_test <- function(acq, needs_grid, lines, bios, n_perm = 10000L) {
  recs <- list()
  for (i in seq_len(nrow(acq))) {
    a <- acq[i, ]
    ng <- needs_grid[[a$grid]]; if (is.null(ng)) next
    pid <- as.character(a$mlbam_id)
    pl  <- lines[[pid]]; if (is.null(pl)) next
    bio <- bios[[pid]]
    is_pit <- identical(bio$group, "Pitching")
    line <- if (is_pit) pl$pit else pl$bat
    if (is.null(line)) next

    clubs <- names(ng)
    if (!(a$acquirer %in% clubs)) next
    scored <- lapply(clubs, function(cl) clear_rate(line, is_pit, ng[[cl]]))
    names(scored) <- clubs
    r  <- vapply(scored, function(s) s$rate, numeric(1))
    rs <- vapply(scored, function(s) s$rate_strict, numeric(1))
    if (length(r) < 20) next

    # average-rank percentile: 1.0 means the acquirer was the single best fit,
    # and ties split the difference so a player who answers nobody (or
    # everybody) lands at 0.50 instead of counting as evidence either way
    pctile <- function(v, who) {
      v <- v[!is.na(v)]
      if (length(v) < 10 || is.na(v[[who]] %||% NA)) return(NA_real_)
      (sum(v < v[[who]]) + 0.5 * sum(v == v[[who]])) / length(v)
    }

    recs[[length(recs) + 1]] <- tibble(
      mlbam_id = a$mlbam_id, name = bio$name %||% NA_character_,
      acquirer = a$acquirer, from = a$from, date = a$date, how = a$how,
      is_pit = is_pit,
      acq_rate = r[[a$acquirer]],
      others_mean = mean(r[names(r) != a$acquirer]),
      pct = pctile(r, a$acquirer),
      pct_strict = if (a$acquirer %in% names(rs) && !is.na(rs[[a$acquirer]]))
                     pctile(rs, a$acquirer) else NA_real_,
      acq_has_need = !is.na(rs[[a$acquirer]]),
      n_with_need = sum(!is.na(rs)),
      n_clubs = length(r))
  }
  if (length(recs) == 0) stop("no scorable acquisitions")
  bind_rows(recs)
}

#' Permutation test on the mean percentile. Under the null the acquirer is just
#' one of the clubs, so shuffling which club counts as the acquirer within each
#' event gives the null distribution directly -- no distributional assumptions.
perm_p <- function(res, col = "pct", n_col = "n_clubs",
                   n_perm = 10000L, seed = 20261013L) {
  set.seed(seed)
  keep <- !is.na(res[[col]]) & !is.na(res[[n_col]]) & res[[n_col]] > 1
  v <- res[[col]][keep]; k <- res[[n_col]][keep]
  if (length(v) == 0) return(NULL)
  obs <- mean(v)
  # Under the null, a percentile rank is uniform over the ranks that event's
  # own comparison set could have produced, so resampling those ranks gives
  # the null distribution directly, with no distributional assumptions.
  null_means <- replicate(n_perm,
    mean(vapply(k, function(kk) (sample.int(kk, 1) - 0.5) / kk, numeric(1))))
  list(n = length(v), obs = obs,
       null_mean = mean(null_means), null_sd = sd(null_means),
       p_two = mean(abs(null_means - 0.5) >= abs(obs - 0.5)),
       p_greater = mean(null_means >= obs))
}

#' The coarsest version of the question, and the most interpretable: when a
#' club acquires a pitcher, did that club have a pitching need flagged?
#'
#' Compared against the base rate -- the share of all 30 clubs carrying a need
#' in that player's category that week. If clubs shop to need at all, the
#' acquirer should clear the base rate.
category_match <- function(res, n_perm = 10000L, seed = 20261013L) {
  set.seed(seed)
  keep <- !is.na(res$n_with_need) & !is.na(res$n_clubs) & res$n_clubs > 0
  r <- res[keep, ]
  if (nrow(r) == 0) return(NULL)
  obs  <- mean(r$acq_has_need)
  base <- mean(r$n_with_need / r$n_clubs)
  null_rates <- replicate(n_perm,
    mean(runif(nrow(r)) < (r$n_with_need / r$n_clubs)))
  list(n = nrow(r), obs = obs, base = base,
       p_two = mean(abs(null_rates - base) >= abs(obs - base)),
       p_greater = mean(null_rates >= obs))
}
