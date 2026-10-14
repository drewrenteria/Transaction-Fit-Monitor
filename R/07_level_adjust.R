# =============================================================================
# 07_level_adjust.R — put minor league rates on a common scale.
#
# The farm side used to grade minor leaguers against major league thresholds.
# Measured against the 2026 league baselines, that is not a small bias, it is
# backwards for half the metrics:
#
#   level        league OBP   league ERA   league BB%
#   MLB               .318         4.17          8.9
#   Triple-A          .349         4.99         11.2
#   Double-A          .340         4.85         10.9
#   High-A            .351         5.08         12.0
#   Single-A          .354         4.98         12.5
#   Rookie            .401         5.34         15.6
#
# "OBP >= .330 is on-base ability" reads a dozen points above average in the
# majors, nineteen points BELOW average in Triple-A, and seventy-one points
# below in rookie ball -- and passes in all three. Low-level hitters were
# systematically over-flagged. Pitchers broke the other way: ERA <= 4.00 is
# ordinary in MLB and nearly unreachable against a 5.34 rookie league, so good
# low-level arms were missed.
#
# The fix is the oldest one in baseball: express a rate against its own
# league, the way OPS+ and ERA+ have always worked. 100 is average for the
# level, higher is always better, and a number means the same thing wherever
# it was earned.
#
# What this does NOT fix: park. The Stats API publishes no minor league park
# factors, so El Paso and Dayton are still treated alike. Level is much the
# larger distortion -- .318 to .401 on OBP dwarfs any single park -- but the
# residual is real and is stated on the page rather than hidden.
# =============================================================================

suppressPackageStartupMessages({ library(dplyr); library(purrr) })

# Which direction is good. TRUE means a bigger raw number is better.
HIT_DIR <- c(OBP = TRUE, SLG = TRUE, OPS = TRUE, ISO = TRUE, AVG = TRUE,
             BBp = TRUE, Kp = FALSE)
PIT_DIR <- c(ERA = FALSE, WHIP = FALSE, HR9 = FALSE, BBp = FALSE,
             Kp = TRUE, KBBp = TRUE)

#' League average rates at every level, from the team stat blocks already
#' fetched for the farm needs. Keyed by the level label, not the sport id,
#' because that is what a player's stint carries.
#'
#' @param team_stats list: sport_id -> group -> (team_id -> stat block)
level_baselines <- function(team_stats) {
  out <- list()
  for (sid in names(team_stats)) {
    lv <- unname(LEVEL_BY_SPORT[sid]); if (is.na(lv)) next
    h <- team_stats[[sid]]$hitting; p <- team_stats[[sid]]$pitching
    out[[lv]] <- list(
      hit = if (length(h)) aggregate_stats(unname(h), "hit") else NULL,
      pit = if (length(p)) aggregate_stats(unname(p), "pit") else NULL)
  }
  out
}

#' One rate as a percentage of its league. 100 is average, higher is better,
#' whichever direction the raw metric runs.
as_plus <- function(value, league, higher_is_better) {
  if (is.null(value) || is.na(value) || is.null(league) || is.na(league) ||
      league == 0) return(NA_real_)
  if (higher_is_better) {
    100 * value / league
  } else {
    if (value == 0) return(NA_real_)   # a 0.00 ERA is not infinitely good
    100 * league / value
  }
}

#' Convert a whole rate line to plus values against one level.
to_plus <- function(rates, league, dirs) {
  if (is.null(rates) || is.null(league)) return(NULL)
  out <- list()
  for (k in names(dirs)) {
    v <- rates[[k]]; l <- league[[k]]
    if (is.null(v) || is.null(l)) next
    out[[k]] <- as_plus(num(v), num(l), dirs[[k]])
  }
  out
}

#' Combine a player's stints into one level-adjusted line.
#'
#' Each stint is scored against the level it actually happened at, then the
#' plus values are averaged weighted by playing time. Summing the counting
#' stats first and dividing once -- which is what the old aggregate_stats did
#' -- silently credits a Double-A line at complex-league difficulty.
#'
#' Raw rates are kept alongside so the page can still show a real OBP. They
#' are the PA-weighted blend, for display only; grading uses the plus values.
#'
#' @param stints list of list(level=, stat=) for one player
#' @param kind "hit" or "pit"
combine_stints <- function(stints, baselines, kind) {
  if (length(stints) == 0) return(NULL)
  dirs <- if (identical(kind, "hit")) HIT_DIR else PIT_DIR
  rate_of <- if (identical(kind, "hit")) hit_rates else pit_rates

  acc <- list(); wt <- list(); raw_blocks <- list(); total <- 0
  for (s in stints) {
    r <- rate_of(s$stat); if (is.null(r)) next
    w <- if (identical(kind, "hit")) n0(r$PA) else n0(r$IP)
    if (w <= 0) next
    raw_blocks[[length(raw_blocks) + 1]] <- s$stat
    total <- total + w
    lg <- baselines[[s$level]]
    lg <- if (is.null(lg)) NULL else lg[[kind]]
    pl <- to_plus(r, lg, dirs)
    if (is.null(pl)) next
    for (k in names(pl)) {
      v <- pl[[k]]; if (is.na(v)) next
      acc[[k]] <- (acc[[k]] %||% 0) + v * w
      wt[[k]]  <- (wt[[k]]  %||% 0) + w
    }
  }
  if (total <= 0) return(NULL)

  raw <- aggregate_stats(raw_blocks, kind)
  if (is.null(raw)) return(NULL)
  for (k in names(acc))
    if (wt[[k]] > 0) raw[[paste0(k, "_plus")]] <- round(acc[[k]] / wt[[k]], 1)
  # the level the bulk of the work happened at, for display
  raw$lvl <- {
    byl <- list()
    for (s in stints) {
      r <- rate_of(s$stat); if (is.null(r)) next
      w <- if (identical(kind, "hit")) n0(r$PA) else n0(r$IP)
      byl[[s$level]] <- (byl[[s$level]] %||% 0) + w
    }
    if (length(byl)) names(byl)[which.max(unlist(byl))] else NA_character_
  }
  raw
}

#' An organization's farm rates, each affiliate scored against its own level
#' before being combined.
#'
#' Without this, an org's flagged needs partly reflect how many complex-league
#' clubs it runs rather than how its players are performing.
org_farm_plus <- function(affiliates, baselines, kind) {
  combine_stints(affiliates, baselines, kind)
}

#' Plus thresholds derived from the major league ones already in template.html,
#' divided by the major league baseline. This deliberately invents no new
#' cutoffs: whatever stringency was already tuned carries over unchanged, it
#' just stops depending on which level a player happened to be standing in.
#'
#' @return named list of key -> plus cutoff, for hitters and pitchers
derive_plus_cutoffs <- function(baselines) {
  mlb <- baselines[["MLB"]]
  if (is.null(mlb)) return(NULL)
  h <- mlb$hit; p <- mlb$pit
  mk <- function(raw, league, hib) {
    if (is.null(raw) || is.null(league) || is.na(num(league)) || num(league) == 0)
      return(NA_real_)
    round(as_plus(num(raw), num(league), hib))
  }
  list(
    hit = list(
      OBP = mk(0.330, h$OBP, TRUE),  SLG = mk(0.400, h$SLG, TRUE),
      OPS = mk(0.750, h$OPS, TRUE),  ISO = mk(0.170, h$ISO, TRUE),
      BBp = mk(9,     h$BBp, TRUE),  Kp  = mk(22,    h$Kp,  FALSE)),
    pit = list(
      ERA = mk(4.00, p$ERA,  FALSE), WHIP = mk(1.25, p$WHIP, FALSE),
      HR9 = mk(1.10, p$HR9,  FALSE), BBp  = mk(8.5,  p$BBp,  FALSE),
      Kp  = mk(23,   p$Kp,   TRUE),  KBBp = mk(15,   p$KBBp, TRUE))
  )
}
