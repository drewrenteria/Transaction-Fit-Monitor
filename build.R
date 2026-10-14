#!/usr/bin/env Rscript
# =============================================================================
# build.R — run the whole chain and write the dashboard.
#
#   Rscript build.R                 # as of today
#   Rscript build.R 2026-07-04      # point-in-time rebuild
#
# Everything is cached under cache/, so a second run is fast and re-knitting
# while you change the template costs no network calls.
# =============================================================================

suppressPackageStartupMessages({
  library(jsonlite); library(dplyr); library(purrr); library(tibble); library(httr2)
})

HERE <- tryCatch(dirname(normalizePath(sub("^--file=", "",
         grep("^--file=", commandArgs(FALSE), value = TRUE)[1]))),
         error = function(e) getwd())
if (is.na(HERE) || !nzchar(HERE)) HERE <- getwd()

for (f in c("00_config.R", "01_fetch_statsapi.R", "02_fetch_fangraphs.R",
            "03_needs.R", "04_availability.R", "05_build_payload.R",
            "07_level_adjust.R"))
  source(file.path(HERE, "R", f))

PROJ_DIR  <<- HERE
CACHE_DIR <<- file.path(HERE, "cache")
OUT_DIR   <<- file.path(HERE, "output")
TEMPLATE  <<- file.path(HERE, "template.html")
ensure_dirs()

args  <- commandArgs(trailingOnly = TRUE)
AS_OF <<- if (length(args) >= 1) as.Date(args[1]) else Sys.Date()
snapshot <- length(args) >= 1
tag <- format(AS_OF, "%Y%m%d")
message(sprintf("building as of %s%s", AS_OF, if (snapshot) " (point-in-time)" else ""))

# --- 1. clubs ----------------------------------------------------------------
teams <- fetch_teams()
stopifnot(nrow(teams) > 0)
mlb_teams <- teams %>% filter(sport_id == MLB_SPORT)
message(sprintf("  %d clubs, %d major league", nrow(teams), nrow(mlb_teams)))

# --- 2. transactions ---------------------------------------------------------
# The availability walk needs history before the window, or a player designated
# three weeks ago and claimed last week reads as still available.
hist_from <- AS_OF - 120
txns_raw  <- fetch_transactions(hist_from, AS_OF)
txns      <- enrich_transactions(txns_raw, teams)
window_tx <- txns %>% filter(date >= AS_OF - DAYS_BACK)
message(sprintf("  %d transactions in history, %d in the %d-day window",
                nrow(txns), nrow(window_tx), DAYS_BACK))

# --- 3. availability ---------------------------------------------------------
# Resolved over the full history, not just the window: a player designated
# three weeks ago and never claimed is still on the market today.
roster40 <- fetch_roster40(mlb_teams$team_id)
avail <- build_availability(txns, as_of = AS_OF, roster40 = roster40)
avail <- mark_new_entrants(avail, txns, as_of = AS_OF, days = 7L)
on_market <- names(avail)[vapply(avail, function(a) isTRUE(a$avail), logical(1))]
message(sprintf("  %d of %d players on the market", length(on_market), length(avail)))

# --- 4. bios -----------------------------------------------------------------
# Everyone in the window PLUS everyone still on the market. Fetching only the
# window left available players with no position, and they dropped silently
# out of the league board.
bio_ids <- union(window_tx$mlbam_id, as.integer(on_market))
people <- fetch_people(bio_ids)
message(sprintf("  %d player bios (%d window, %d on market)",
                nrow(people), length(unique(na.omit(window_tx$mlbam_id))), length(on_market)))

# --- 5. FanGraphs ------------------------------------------------------------
date_to  <- if (snapshot) format(AS_OF, "%Y-%m-%d") else NULL
fg_teams <- fetch_fg_teams(date_to = date_to, tag = tag)
fg_play  <- fetch_fg_players(date_to = date_to, tag = tag)
# three-year track record; for a snapshot stop before the current season so no
# information from after the as-of date leaks into the context line
fg_car   <- fetch_fg_players(season = if (snapshot) SEASON - 1 else SEASON,
                             season_from = SEASON - (SPAN_YEARS - 1),
                             tag = paste0("span_", tag))
message(sprintf("  FanGraphs: %d team bat, %d player lines, %d career lines",
                length(fg_teams$bat), length(fg_play), length(fg_car)))

# --- 6. MLB needs, from FanGraphs -------------------------------------------
xw <- fg_crosswalk(teams)
hit_by_org <- list(); pit_by_org <- list(); missing <- character()
for (i in seq_len(nrow(xw))) {
  r <- xw[i, ]
  b <- fg_teams$bat[[r$fg_abbr]]; p <- fg_teams$pit[[r$fg_abbr]]
  f <- fg_teams$fld[[r$fg_nick]]
  if (is.null(b) || is.null(p) || is.null(f)) { missing <- c(missing, r$club); next }
  hit_by_org[[r$club]] <- c(b, list(DRS = f$DRS, Def = f$Def))
  pit_by_org[[r$club]] <- p
}
if (length(missing))
  warning("FanGraphs crosswalk missed: ", paste(missing, collapse = ", "))
message(sprintf("  FanGraphs crosswalk: %d of %d clubs", length(hit_by_org), nrow(xw)))
mlb_needs <- build_needs(hit_by_org, pit_by_org, MLB_NEED_PLAN, cap = MAX_MLB_NEEDS_PER_CAT)

# --- 7. farm needs and minor league lines, from the Stats API ---------------
# Every stint keeps the level it happened at. Summing counting stats across
# levels and dividing once credits a Double-A line at complex-league
# difficulty; R/07_level_adjust.R has how far off that runs.
team_stats <- list()
for (sid in c(MLB_SPORT, MILB_SPORTS))
  team_stats[[as.character(sid)]] <- list(
    hitting  = fetch_team_stats("hitting",  sid),
    pitching = fetch_team_stats("pitching", sid))
baselines <- level_baselines(team_stats)
plus_cut  <- derive_plus_cutoffs(baselines)
message(sprintf("  league baselines for %d levels (MLB OBP %.3f, Rookie OBP %.3f)",
                length(baselines), n0(baselines$MLB$hit$OBP), n0(baselines$Rookie$hit$OBP)))

farm_hit_raw <- list(); farm_pit_raw <- list()
for (sid in MILB_SPORTS) {
  lv <- unname(LEVEL_BY_SPORT[as.character(sid)])
  for (grp in c("hitting", "pitching")) {
    st <- team_stats[[as.character(sid)]][[grp]]
    for (tid in names(st)) {
      parent <- teams$parent_org[match(as.integer(tid), teams$team_id)]
      if (is.na(parent)) next
      e <- list(level = lv, stat = st[[tid]])
      if (grp == "hitting") farm_hit_raw[[parent]] <- c(farm_hit_raw[[parent]] %||% list(), list(e))
      else                  farm_pit_raw[[parent]] <- c(farm_pit_raw[[parent]] %||% list(), list(e))
    }
  }
}
farm_hit <- lapply(farm_hit_raw, org_farm_plus, baselines = baselines, kind = "hit")
farm_pit <- lapply(farm_pit_raw, org_farm_plus, baselines = baselines, kind = "pit")
farm_needs <- build_needs(farm_hit, farm_pit, FARM_NEED_PLAN, cap = MAX_FARM_NEEDS_PER_CAT)
message(sprintf("  needs per club: %.1f major league, %.1f farm",
                mean(lengths(mlb_needs)), mean(lengths(farm_needs))))

# minor league player lines, each stint scored against its own level
milb_hit <- list(); milb_pit <- list()
for (sid in MILB_SPORTS) {
  lv <- unname(LEVEL_BY_SPORT[as.character(sid)])
  for (grp in c("hitting", "pitching")) {
    for (sp in fetch_leaderboard(grp, sid)) {
      pid <- nn(sp$player$id); if (is.null(pid) || is.na(pid)) next
      k <- as.character(as.integer(pid))
      e <- list(level = lv, stat = sp$stat)
      if (grp == "hitting") milb_hit[[k]] <- c(milb_hit[[k]] %||% list(), list(e))
      else                  milb_pit[[k]] <- c(milb_pit[[k]] %||% list(), list(e))
    }
  }
}
milb_hit <- lapply(milb_hit, combine_stints, baselines = baselines, kind = "hit")
milb_pit <- lapply(milb_pit, combine_stints, baselines = baselines, kind = "pit")
message(sprintf("  minor league lines: %d hitters, %d pitchers",
                length(milb_hit), length(milb_pit)))

# --- 8. assemble and write ---------------------------------------------------
payload <- build_payload(window_tx, teams, people, avail, mlb_needs, farm_needs,
                         fg_play, fg_car, milb_hit, milb_pit, as_of = AS_OF,
                         plus_cut = plus_cut, baselines = baselines)
if (snapshot) {
  payload$snapshot <- TRUE
  payload$asOf <- as.character(AS_OF)
  payload$caveat <- paste("Point-in-time rebuild. Transactions, FanGraphs team and",
                          "player rates and the claim clock are all bounded to this",
                          "date. Minor league rates are season totals because the",
                          "Stats API will not bound them by date, so the farm side",
                          "carries later information.")
}

out <- file.path(OUT_DIR, if (snapshot)
  sprintf("transaction_fit_dashboard_%s.html", AS_OF) else
  "transaction_fit_dashboard.html")
write_dashboard(payload, out)

# also drop the raw payload so it can be diffed against a reference build
writeLines(jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null",
                            na = "null", digits = NA),
           file.path(OUT_DIR, sprintf("payload_%s.json", tag)))
message("done")
