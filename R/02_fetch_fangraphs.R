# =============================================================================
# 02_fetch_fangraphs.R — wRC+, FIP, xFIP, DRS, BsR for the major league side.
#
# The Stats API has no park- or league-adjusted metrics, so major league
# evaluation runs on FanGraphs. FanGraphs exposes xMLBAMID, so every join is on
# MLBAM id and no name matching is involved.
#
# FanGraphs has no public minor league leaderboard on this path (404), so the
# farm side stays on the Stats API and is unadjusted. That is a real
# limitation, documented on the page rather than hidden.
# =============================================================================

suppressPackageStartupMessages({
  library(jsonlite); library(dplyr); library(purrr); library(tibble); library(httr2)
})

#' One leaderboard call, cached. `date_to` bounds the window for a
#' point-in-time rebuild; leave NULL for the full season to date.
fg_get <- function(stats, team_level, key, season = SEASON,
                   season_from = NULL, date_to = NULL, ttl_hours = 24) {
  ensure_dirs()
  f <- file.path(CACHE_DIR, paste0(key, ".rds"))
  if (file.exists(f)) {
    age <- as.numeric(difftime(Sys.time(), file.mtime(f), units = "hours"))
    if (age < ttl_hours) return(readRDS(f))
  }
  url <- sprintf("%s?pos=all&stats=%s&lg=all&qual=0&season=%d&season1=%d&ind=0&pageitems=3000%s",
                 FG_BASE, stats, season, season_from %||% season,
                 if (isTRUE(team_level)) "&team=0,ts" else "")
  if (!is.null(date_to))
    url <- paste0(url, sprintf("&startdate=%d-03-01&enddate=%s&month=1000", season, date_to))

  out <- tryCatch({
    resp <- request(url) |>
      req_user_agent(FG_UA) |>
      req_timeout(120) |>
      req_retry(max_tries = 3) |>
      req_perform()
    resp_body_json(resp, simplifyVector = FALSE)
  }, error = function(e) { message("  FanGraphs fetch failed: ", key, " — ", conditionMessage(e)); NULL })

  if (is.null(out)) return(NULL)
  saveRDS(out, f)
  Sys.sleep(1.5)   # a handful of cached calls, not a scrape
  out
}

fg_rows <- function(js) {
  if (is.null(js)) return(list())
  if (!is.null(js$data)) js$data else js
}

#' Teams key on abbreviation for batting and pitching but on nickname for
#' fielding, so the two need different lookups.
fg_team_key <- function(r) {
  for (k in c("TeamName", "TeamNameAbb", "Team")) {
    v <- r[[k]]
    if (!is.null(v) && nzchar(as.character(v))) return(strip_tags(as.character(v)))
  }
  NA_character_
}

fetch_fg_teams <- function(season = SEASON, date_to = NULL, tag = "cur") {
  tb <- fg_rows(fg_get("bat", TRUE, sprintf("fg_tb_%s", tag), season, date_to = date_to))
  tp <- fg_rows(fg_get("pit", TRUE, sprintf("fg_tp_%s", tag), season, date_to = date_to))
  tf <- fg_rows(fg_get("fld", TRUE, sprintf("fg_tf_%s", tag), season, date_to = date_to))

  bat <- list(); pit <- list(); fld <- list()
  for (r in tb) { k <- fg_team_key(r); if (!is.na(k)) bat[[k]] <- list(
    wRCplus = num(r$`wRC+`), OBP = num(r$OBP), SLG = num(r$SLG), ISO = num(r$ISO),
    BBp = as_pct(r$`BB%`), Kp = as_pct(r$`K%`),
    BsR = num(r$BaseRunning), Spd = num(r$Spd)) }
  for (r in tp) { k <- fg_team_key(r); if (!is.na(k)) pit[[k]] <- list(
    FIP = num(r$FIP), xFIP = num(r$xFIP), ERA = num(r$ERA), WHIP = num(r$WHIP),
    HR9 = num(r$`HR/9`), Kp = as_pct(r$`K%`), BBp = as_pct(r$`BB%`),
    KBBp = as_pct(r$`K-BB%`)) }
  for (r in tf) { k <- fg_team_key(r); if (!is.na(k)) fld[[k]] <- list(
    DRS = num(r$DRS), Def = num(r$Defense)) }

  list(bat = bat, pit = pit, fld = fld)
}

#' Player lines keyed by MLBAM id. `season_from` below `season` returns one
#' combined multi-year row per player, which is the three-year track record.
fetch_fg_players <- function(season = SEASON, season_from = NULL,
                             date_to = NULL, tag = "cur") {
  pb <- fg_rows(fg_get("bat", FALSE, sprintf("fg_pb_%s", tag), season, season_from, date_to))
  pp <- fg_rows(fg_get("pit", FALSE, sprintf("fg_pp_%s", tag), season, season_from, date_to))

  out <- list()
  for (r in pb) {
    mid <- nn(r$xMLBAMID)
    if (is.null(mid) || is.na(mid) || is.null(r$PA)) next
    k <- as.character(as.integer(mid))
    out[[k]] <- c(out[[k]] %||% list(), list(bat = list(
      PA = num(r$PA), wRCplus = num(r$`wRC+`), OBP = num(r$OBP), SLG = num(r$SLG),
      ISO = num(r$ISO), BBp = as_pct(r$`BB%`), Kp = as_pct(r$`K%`),
      BsR = num(r$BaseRunning), Def = num(r$Defense), WAR = num(r$WAR))))
  }
  for (r in pp) {
    mid <- nn(r$xMLBAMID)
    if (is.null(mid) || is.na(mid) || is.null(r$IP)) next
    k <- as.character(as.integer(mid))
    out[[k]] <- c(out[[k]] %||% list(), list(pit = list(
      IP = num(r$IP), FIP = num(r$FIP), xFIP = num(r$xFIP), ERA = num(r$ERA),
      WHIP = num(r$WHIP), HR9 = num(r$`HR/9`), Kp = as_pct(r$`K%`),
      BBp = as_pct(r$`BB%`), KBBp = as_pct(r$`K-BB%`), WAR = num(r$WAR))))
  }
  out
}

#' Map each MLB club to its FanGraphs batting/pitching key and fielding key.
#' Returns a tibble so a failed crosswalk is visible rather than silent.
fg_crosswalk <- function(teams) {
  teams %>%
    filter(sport_id == MLB_SPORT) %>%
    mutate(fg_abbr = ifelse(abbr %in% names(FG_ABBR), unname(FG_ABBR[abbr]), abbr),
           fg_nick = ifelse(nick %in% names(FG_NICK), unname(FG_NICK[nick]), nick)) %>%
    select(team_id, club, abbr, nick, fg_abbr, fg_nick)
}
