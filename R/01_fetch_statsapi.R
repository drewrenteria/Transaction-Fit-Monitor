# =============================================================================
# 01_fetch_statsapi.R — transactions, clubs, player bios, minor league rates.
#
# One call covers every transaction in a date range across MLB and the whole
# minor league system, with MLBAM ids attached. That replaces the 30-page
# mlb.com scrape and the regex that used to recover names and positions from
# free text.
# =============================================================================

suppressPackageStartupMessages({
  library(jsonlite); library(dplyr); library(purrr); library(tibble)
})

#' Fetch JSON with on-disk caching. Returns NULL on failure so callers can
#' fall back to an empty frame rather than aborting the build.
api_get <- function(url, key, ttl_hours = 24) {
  ensure_dirs()
  f <- file.path(CACHE_DIR, paste0(key, ".rds"))
  if (file.exists(f)) {
    age <- as.numeric(difftime(Sys.time(), file.mtime(f), units = "hours"))
    if (age < ttl_hours) return(readRDS(f))
  }
  out <- NULL
  for (attempt in 1:3) {
    out <- tryCatch(jsonlite::fromJSON(url, simplifyVector = FALSE),
                    error = function(e) NULL)
    if (!is.null(out)) break
    Sys.sleep(2)
  }
  if (is.null(out)) {
    message("  fetch failed: ", key)
    return(NULL)
  }
  saveRDS(out, f)
  out
}

# --- clubs and affiliate map -------------------------------------------------

#' Every MLB club and affiliate with its parent organization.
#' `parentOrgName` is authoritative, so no hand-maintained affiliate map.
fetch_teams <- function(season = SEASON) {
  sports <- paste(c(MLB_SPORT, MILB_SPORTS), collapse = ",")
  js <- api_get(sprintf("%s/teams?sportIds=%s&season=%d", STATSAPI, sports, season),
                sprintf("teams_%d", season), ttl_hours = 24 * 7)
  if (is.null(js$teams)) return(tibble())
  map_dfr(js$teams, function(t) {
    sid <- suppressWarnings(as.integer(nn(t$sport$id)))
    tibble(team_id    = suppressWarnings(as.integer(nn(t$id))),
           club       = as.character(nn(t$name)),
           parent_org = as.character(nn(t$parentOrgName, nn(t$name))),
           abbr       = as.character(nn(t$abbreviation)),
           nick       = as.character(nn(t$teamName)),
           sport_id   = sid,
           level      = unname(LEVEL_BY_SPORT[as.character(sid)]))
  })
}

# --- transactions ------------------------------------------------------------

map_transaction_type <- function(type_code, description) {
  d <- tolower(description %||% "")
  out <- unname(TYPE_MAP[type_code])
  if (!is.na(out)) return(out)
  if (identical(type_code, "ASG"))
    return(if (grepl("rehab", d)) "Rehab Assignment" else "Assigned")
  if (identical(type_code, "SC")) {
    if (grepl("activated", d))    return("Activated")
    if (grepl("injured list", d)) return("Injured List")
    return("Status Change")
  }
  "Other"
}

#' League-wide transactions between two dates, flattened.
fetch_transactions <- function(start_date, end_date) {
  url <- sprintf("%s/transactions?startDate=%s&endDate=%s",
                 STATSAPI, format(start_date, "%Y-%m-%d"), format(end_date, "%Y-%m-%d"))
  js <- api_get(url, sprintf("txn_%s_%s", start_date, end_date), ttl_hours = 1)
  tx <- js$transactions
  if (is.null(tx) || length(tx) == 0) return(tibble())
  map_dfr(tx, function(t) {
    tibble(txn_id      = suppressWarnings(as.integer(nn(t$id))),
           date        = as.Date(nn(t$date, NA_character_)),
           mlbam_id    = suppressWarnings(as.integer(nn(t$person$id))),
           player      = as.character(nn(t$person$fullName)),
           type_code   = as.character(nn(t$typeCode)),
           description = as.character(nn(t$description)),
           to_team_id  = suppressWarnings(as.integer(nn(t$toTeam$id))),
           from_team_id= suppressWarnings(as.integer(nn(t$fromTeam$id))))
  }) %>%
    mutate(txn_type = map2_chr(type_code, description, map_transaction_type))
}

# --- player bios -------------------------------------------------------------

#' Bulk position and handedness. Replaces the `\\bC\\b` style regex, which
#' matched the C in "C.J." and filed shortstops as catchers.
fetch_people <- function(ids, chunk = 100L) {
  ids <- unique(ids[!is.na(ids)])
  if (length(ids) == 0) return(tibble())
  groups <- split(ids, ceiling(seq_along(ids) / chunk))
  map_dfr(groups, function(ch) {
    js <- api_get(sprintf("%s/people?personIds=%s", STATSAPI, paste(ch, collapse = ",")),
                  sprintf("people_%s_%d", ch[1], length(ch)), ttl_hours = 24 * 7)
    if (is.null(js$people)) return(tibble())
    map_dfr(js$people, function(p) {
      tibble(mlbam_id = suppressWarnings(as.integer(nn(p$id))),
             name     = as.character(nn(p$fullName)),
             pos      = as.character(nn(p$primaryPosition$abbreviation)),
             pos_type = as.character(nn(p$primaryPosition$type)),
             bats     = as.character(nn(p$batSide$code)),
             throws   = as.character(nn(p$pitchHand$code)),
             age      = suppressWarnings(as.integer(nn(p$currentAge))))
    })
  })
}

# --- leaderboards ------------------------------------------------------------

#' Season leaderboard for one sport and group.
#' playerPool=All matters: the default returns only qualified players, which is
#' 46 major league pitchers instead of 868.
fetch_leaderboard <- function(group, sport_id, season = SEASON) {
  out <- list(); offset <- 0L
  repeat {
    url <- sprintf(paste0("%s/stats?stats=season&season=%d&group=%s&sportId=%d",
                          "&gameType=R&playerPool=All&limit=1000&offset=%d"),
                   STATSAPI, season, group, sport_id, offset)
    js <- api_get(url, sprintf("lb_%s_%d_%d_%d", group, sport_id, season, offset),
                  ttl_hours = 24)
    splits <- unlist(lapply(js$stats %||% list(), function(s) s$splits), recursive = FALSE)
    if (is.null(splits) || length(splits) == 0) break
    out <- c(out, splits)
    offset <- offset + 1000L
    if (offset > 8000L) break
  }
  out
}

#' Team-level season stats for one sport and group, keyed by team id.
fetch_team_stats <- function(group, sport_id, season = SEASON) {
  url <- sprintf("%s/teams/stats?season=%d&stats=season&group=%s&sportIds=%d&gameType=R",
                 STATSAPI, season, group, sport_id)
  js <- api_get(url, sprintf("ts_%s_%d_%d", group, sport_id, season), ttl_hours = 24)
  splits <- unlist(lapply(js$stats %||% list(), function(s) s$splits), recursive = FALSE)
  res <- list()
  for (sp in splits %||% list()) {
    tid <- nn(sp$team$id)
    if (!is.null(tid) && !is.na(tid)) res[[as.character(tid)]] <- sp$stat
  }
  res
}

#' 40-man rosters, for acquisition cost context.
fetch_roster40 <- function(mlb_team_ids, season = SEASON) {
  res <- list()
  for (tid in mlb_team_ids) {
    js <- api_get(sprintf("%s/teams/%d/roster?rosterType=40Man&season=%d",
                          STATSAPI, tid, season),
                  sprintf("r40_%d_%d", tid, season), ttl_hours = 24)
    for (e in js$roster %||% list()) {
      pid <- nn(e$person$id)
      if (!is.null(pid) && !is.na(pid))
        res[[as.character(pid)]] <- list(status = as.character(nn(e$status$description)))
    }
  }
  res
}
