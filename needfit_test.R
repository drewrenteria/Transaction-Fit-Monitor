#!/usr/bin/env Rscript
# =============================================================================
# needfit_test.R — run the need-fit backtest.
#
#   Rscript needfit_test.R
#
# Asks whether clubs acquire players who answer their OWN flagged needs more
# often than chance, using a within-event comparison across all 30 clubs. See
# the header of R/06_needfit_test.R for why that design controls for player
# quality. Results land in output/needfit_results.csv and are printed.
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
            "06_needfit_test.R"))
  source(file.path(HERE, "R", f))

PROJ_DIR  <<- HERE
CACHE_DIR <<- file.path(HERE, "cache")
OUT_DIR   <<- file.path(HERE, "output")
ensure_dirs()

SEASON_START <- as.Date(sprintf("%d-03-25", SEASON))
SEASON_END   <- min(Sys.Date(), as.Date(sprintf("%d-10-01", SEASON)))

# Needs are rebuilt every two weeks rather than daily. Team rates move slowly
# at this point in a season, and a daily grid would be ~200 leaderboard calls
# for a difference well inside the noise.
GRID <- seq(SEASON_START + 30, SEASON_END, by = "14 days")

message("=== need-fit backtest ===")
message(sprintf("season %d, %d grid dates from %s to %s",
                SEASON, length(GRID), min(GRID), max(GRID)))

# --- 1. acquisitions ---------------------------------------------------------
teams <- fetch_teams()
message("\n[1/4] transactions")
txns <- enrich_transactions(fetch_transactions(SEASON_START, SEASON_END), teams)
message(sprintf("  %d transactions", nrow(txns)))

acq <- collect_market_acquisitions(txns)
message(sprintf("  %d market acquisitions by a club other than the one that let him go",
                nrow(acq)))
acq$grid <- vapply(acq$date, nearest_grid, character(1), grid = GRID)
acq <- acq %>% filter(!is.na(grid))
message(sprintf("  %d inside the grid", nrow(acq)))

# --- 2. point-in-time needs --------------------------------------------------
message("\n[2/4] club needs as of each grid date")
grid_needs <- needs_as_of(GRID, teams)
message(sprintf("  %d usable dates", length(grid_needs)))

# --- 3. player lines ---------------------------------------------------------
# Base 1: 2024-25 combined. Complete and public before 2026 began.
# Base 2/3: the current season bounded to each grid date, which is what the club
# actually had in front of it. Bounded, so there is no lookahead either way.
message("\n[3/4] player lines")
prior <- fetch_fg_players(season = SEASON - 1, season_from = SEASON - 2,
                          tag = "needfit_prior")
message(sprintf("  base 1: %d players with a 2024-25 line", length(prior)))

cur_by_date <- list()
for (d in names(grid_needs)) {
  cur_by_date[[d]] <- fetch_fg_players(date_to = d,
                                       tag = paste0("needfit_cur_", gsub("-", "", d)))
}
message(sprintf("  base 2/3: %d dated snapshots, %.0f players each",
                length(cur_by_date), mean(lengths(cur_by_date))))

people <- fetch_people(unique(acq$mlbam_id))
bios <- list()
for (i in seq_len(nrow(people))) {
  r <- people[i, ]
  bios[[as.character(r$mlbam_id)]] <-
    list(name = r$name, group = derive_profile(r$pos_type, r$pos, r$throws)$group)
}
message(sprintf("  %d bios", length(bios)))

# --- 4. test -----------------------------------------------------------------
# Base 3 is the primary test: the only basis that grades a player the way
# template.html grades him. Pre-registered in the README before this ran.
message("\n[4/4] scoring, three grading bases")
bases <- list(
  "1. prior season (2024-25)" =
    run_needfit_test(acq, grid_needs, prior, bios),
  "2. current season to date" =
    run_needfit_test(acq, grid_needs, NULL, bios, lines_by_date = cur_by_date),
  "3. PRIMARY: the page's own rule" =
    run_needfit_test(acq, grid_needs, NULL, bios, lines_by_date = cur_by_date,
                     career = prior)
)
for (nm in names(bases))
  message(sprintf("  %-34s %d scorable", nm, nrow(bases[[nm]])))

report_basis <- function(nm, r) {
  pt  <- perm_p(r, "pct", "n_clubs")
  pts <- perm_p(r, "pct_strict", "n_with_need")
  cm  <- category_match(r)
  cat(sprintf("\n%s\n%s\n", nm, strrep("-", nchar(nm))))
  cat(sprintf("  n = %d  (%d pitchers, %d position)\n",
              nrow(r), sum(r$is_pit), sum(!r$is_pit)))
  if (!is.null(cm))
    cat(sprintf("  category match      acquirer %.4f  base %.4f  lift %+.4f  p %.4f\n",
                cm$obs, cm$base, cm$obs - cm$base, cm$p_two))
  if (!is.null(pt))
    cat(sprintf("  rank, all 30        percentile %.4f   rate %.4f vs %.4f   p %.4f\n",
                pt$obs, mean(r$acq_rate), mean(r$others_mean), pt$p_two))
  if (!is.null(pts))
    cat(sprintf("  rank, needful only  percentile %.4f   (n=%d)   p %.4f\n",
                pts$obs, pts$n, pts$p_two))
  invisible(list(pt = pt, pts = pts, cm = cm))
}

cat("\n", strrep("=", 72), "\n", sep = "")
cat("ALL THREE GRADING BASES\n")
cat(strrep("=", 72), "\n", sep = "")
stats <- list()
for (nm in names(bases)) stats[[nm]] <- report_basis(nm, bases[[nm]])

res <- bases[[3]]
pt  <- stats[[3]]$pt
pts <- stats[[3]]$pts
cm  <- stats[[3]]$cm

cat("\n", strrep("=", 68), "\n", sep = "")
cat("PRIMARY TEST — base 3, the page's own rule\n")
cat(strrep("=", 68), "\n\n", sep = "")
cat(sprintf("Acquisitions scored            %d\n", nrow(res)))
cat(sprintf("  pitchers                     %d\n", sum(res$is_pit)))
cat(sprintf("  position players             %d\n", sum(!res$is_pit)))
cat(sprintf("Clubs compared per acquisition %.0f\n\n", mean(res$n_clubs)))

cat("--- 1. Did the acquirer need this kind of player at all? ---\n\n")
if (!is.null(cm)) {
  cat(sprintf("  acquirer had a need in his category   %.4f  (n=%d)\n", cm$obs, cm$n))
  cat(sprintf("  base rate across all 30 clubs         %.4f\n", cm$base))
  cat(sprintf("  difference                            %+.4f\n", cm$obs - cm$base))
  cat(sprintf("  permutation p (two-sided)             %.4f\n\n", cm$p_two))
}

cat("--- 2. Among all 30 clubs, how well did the acquirer rank? ---\n")
cat("    (a club with no need in his category scores 0)\n\n")
cat(sprintf("  acquirer clear-rate                   %.4f\n", mean(res$acq_rate)))
cat(sprintf("  other 29 clubs, mean                  %.4f\n", mean(res$others_mean)))
cat(sprintf("  difference                            %+.4f\n",
            mean(res$acq_rate) - mean(res$others_mean)))
cat(sprintf("  acquirer mean percentile              %.4f  (0.5000 under the null)\n", pt$obs))
cat(sprintf("  permutation p (two-sided)             %.4f\n\n", pt$p_two))

cat("--- 3. Among only clubs that needed his category ---\n\n")
if (!is.null(pts)) {
  cat(sprintf("  acquirer mean percentile              %.4f  (n=%d)\n", pts$obs, pts$n))
  cat(sprintf("  permutation p (two-sided)             %.4f\n\n", pts$p_two))
}

# --- exploratory splits ------------------------------------------------------
# Not pre-registered. Reported because the route split is large and has an
# obvious mechanism, but it is a hypothesis for next season, not a result.
cat("--- Category match by subgroup (exploratory) ---\n\n")
cat(sprintf("  %-18s %5s  %8s %8s %8s\n", "", "n", "acquirer", "base", "lift"))
split_row <- function(label, s) {
  if (nrow(s) == 0) return(invisible())
  obs  <- mean(s$acq_has_need)
  base <- mean(s$n_with_need / s$n_clubs)
  cat(sprintf("  %-18s %5d  %8.3f %8.3f %+8.3f\n", label, nrow(s), obs, base, obs - base))
}
split_row("pitchers",         res %>% filter(is_pit))
split_row("position players", res %>% filter(!is_pit))
cat("\n")
for (h in c("Trade", "Claimed", "Signed"))
  split_row(h, res %>% filter(how == h))

sig <- function(x) !is.null(x) && x$p_two < 0.05
verdict <- if (sig(cm) && cm$obs > cm$base) {
  "Clubs acquire players whose category they had flagged, above the base rate."
} else if (sig(pt) && pt$obs > 0.5) {
  "Clubs acquire players who answer their own needs more often than chance."
} else if (sig(pt) || sig(cm)) {
  "Significant, but in the direction AGAINST need-matching. Read the numbers."
} else {
  "No detectable relationship. Need-fit does not predict which club acquires a player."
}
cat("\n", strrep("-", 68), "\n", verdict, "\n", strrep("=", 68), "\n\n", sep = "")

write.csv(res, file.path(OUT_DIR, "needfit_results.csv"), row.names = FALSE)
message("wrote output/needfit_results.csv")
