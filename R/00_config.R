# =============================================================================
# 00_config.R — constants, paths and every tunable threshold in one place.
#
# Nothing here reaches the network. Sourced first by build.R.
# =============================================================================

SEASON        <- 2026L
DAYS_BACK     <- 14L      # transaction window shown on the page
SPAN_YEARS    <- 3L       # three-year track record (SEASON-2 .. SEASON)
DFA_WINDOW    <- 7L       # days a club has to resolve a DFA
STALE_AFTER   <- 30L      # a release this old with no further event is not
                          # meaningfully "on the market" any more; the player
                          # has usually left affiliated ball without a closing
                          # transaction ever appearing in the feed
AS_OF         <- Sys.Date()   # overridden by build.R for a past snapshot

# --- paths -------------------------------------------------------------------
# build.R overrides these with the real project root before anything runs.
PROJ_DIR  <- getwd()
CACHE_DIR <- file.path(PROJ_DIR, "cache")
OUT_DIR   <- file.path(PROJ_DIR, "output")
TEMPLATE  <- file.path(PROJ_DIR, "template.html")

# --- small helpers -----------------------------------------------------------
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

nn <- function(x, default = NA) {
  if (is.null(x) || length(x) == 0) default else x[[1]]
}

num <- function(x) {
  v <- suppressWarnings(as.numeric(x))
  if (length(v) == 0) NA_real_ else v[[1]]
}

#' Numeric or zero. `num(x) %||% 0` does NOT do this: %||% catches NULL and
#' length-0, not NA, so an absent field flows through as NA and the next
#' `if (x > 0)` fails with "missing value where TRUE/FALSE needed".
n0 <- function(x) {
  v <- num(x)
  if (is.na(v)) 0 else v
}

#' MLB innings pitched use .1 and .2 for thirds of an inning.
ip_to_num <- function(x) {
  v <- num(x)
  whole <- trunc(v)
  frac  <- round(v - whole, 1)
  whole + ifelse(frac == 0.1, 1/3, ifelse(frac == 0.2, 2/3, 0))
}

#' FanGraphs rate fields come back as decimals: 0.105 means 10.5%.
as_pct <- function(x) if (is.null(x)) NULL else num(x) * 100

strip_tags <- function(x) trimws(gsub("<[^>]+>", "", x %||% ""))

ensure_dirs <- function() {
  for (d in c(CACHE_DIR, OUT_DIR))
    dir.create(d, showWarnings = FALSE, recursive = TRUE)
}

# --- MLB Stats API -----------------------------------------------------------
STATSAPI     <- "https://statsapi.mlb.com/api/v1"
MLB_SPORT    <- 1L
MILB_SPORTS  <- c(11L, 12L, 13L, 14L, 16L)
LEVEL_BY_SPORT <- c("1" = "MLB", "11" = "Triple-A", "12" = "Double-A",
                    "13" = "High-A", "14" = "Single-A", "16" = "Rookie")

# --- FanGraphs ---------------------------------------------------------------
FG_BASE <- "https://www.fangraphs.com/api/leaders/major-league/data"
FG_UA   <- paste("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                 "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36")
# FanGraphs abbreviations differ from MLB's for a few clubs, and its fielding
# leaderboard keys on nickname rather than abbreviation.
FG_ABBR <- c("TB" = "TBR", "SD" = "SDP", "SF" = "SFG", "WSH" = "WSN",
             "KC" = "KCR", "CWS" = "CHW", "AZ" = "ARI")
FG_NICK <- c("D-backs" = "Diamondbacks")

# --- transaction vocabulary --------------------------------------------------
# WARNING: the Stats API typeCode that means Designated for Assignment is
# "DES", not "DFA". "DFA" is the code for Declared Free Agency, which is the
# separate (and much rarer) event where a player with the service time to do so
# elects free agency. Mapping DFA -> DFA looks obviously right and silently
# fills the board with free agents while dropping every real designation.
TYPE_MAP <- c(DES = "DFA", CLW = "Claimed", REL = "Released", OUT = "Outrighted",
              TR = "Trade", SFA = "Signed", SGN = "Signed", SE = "Selected Contract",
              OPT = "Option", CU = "Recall", DFA = "Declared Free Agency",
              ACQ = "Acquired", OBT = "Acquired", RTN = "Returned",
              RET = "Retired")

MARKET_OPEN  <- c("DFA", "Released", "Declared Free Agency")
# Every one of these means somebody already has him. "Signed" arrives under two
# codes: SFA for a free agent signing and SGN for a plain signing. Leaving SGN
# unmapped left released players on the board after another club signed them.
MARKET_CLOSE <- c("Claimed", "Signed", "Trade", "Selected Contract",
                  "Purchased Contract", "Outrighted", "Recall", "Option",
                  "Activated", "Assigned", "Rehab Assignment", "Acquired",
                  "Returned", "Retired")
MLB40_EVENTS <- c("DFA", "Claimed", "Trade", "Selected Contract",
                  "Purchased Contract", "Recall", "Option", "Outrighted")

# Levels kept off the main board. A player who hits the market at rookie or
# complex level is acquired by another club about 3% of the time, against 32%
# in the majors and 26% in Triple-A, yet that level supplied roughly a third of
# everyone shown. They are still listed, in a collapsed section with the rate
# stated, rather than deleted: twelve of them did get taken in 2026.
LOW_SIGNAL_LEVELS <- c("Rookie")

# --- need thresholds ---------------------------------------------------------
# A metric is a need only when the club is BOTH low in rank AND a real distance
# below average. Rank alone flags 15 of 30 clubs on every metric by construction.
NEED_RANK_CUT <- 0.70     # bottom 30%
NEED_Z_CUT    <- -0.50    # at least half a standard deviation below average
NEED_PRI_HIGH <- -1.20
NEED_PRI_MED  <- -0.80
MAX_MLB_NEEDS_PER_CAT  <- 2L
MAX_FARM_NEEDS_PER_CAT <- 2L

# Major league needs run on FanGraphs: park and league adjusted.
# key, label, category, need area, higher_is_better, profile to target
MLB_NEED_PLAN <- list(
  list("wRCplus","wRC+","Hitting","Overall Offense",TRUE,"Impact bat with on-base and contact value"),
  list("OBP","OBP","Hitting","On-Base Ability",TRUE,"Hitters with approach and walk skill"),
  list("SLG","SLG","Hitting","Damage / Power",TRUE,"Extra-base impact"),
  list("ISO","ISO","Hitting","Game Power",TRUE,"Players with game power"),
  list("BBp","BB%","Hitting","Plate Discipline",TRUE,"Zone control and walk skill"),
  list("Kp","K%","Hitting","Contact Ability",FALSE,"Lower-strikeout, bat-to-ball profiles"),
  list("FIP","FIP","Pitching","Run Prevention",FALSE,"Arms with better K, BB and HR indicators"),
  list("xFIP","xFIP","Pitching","Underlying Quality",FALSE,"Arms whose peripherals hold up"),
  list("ERA","ERA","Pitching","Runs Allowed",FALSE,"Starters who limit runs"),
  list("WHIP","WHIP","Pitching","Traffic Prevention",FALSE,"Arms who limit baserunners"),
  list("Kp","K%","Pitching","Swing and Miss",TRUE,"Bat-missing stuff"),
  list("BBp","BB%","Pitching","Command",FALSE,"Strike throwers"),
  list("HR9","HR/9","Pitching","Home Run Suppression",FALSE,"Arms who keep the ball in the park"),
  list("DRS","DRS","Defense","Overall Defensive Value",TRUE,"Versatile defenders at premium positions"),
  list("Def","Def","Defense","Defensive Runs",TRUE,"Reliable run-prevention depth"),
  list("BsR","BsR","Baserunning","Baserunning Value",TRUE,"Runners who add value beyond stolen bases"),
  list("Spd","Spd","Baserunning","Speed",TRUE,"Speed threat and late-game running value")
)

# Farm needs run on the Stats API: FanGraphs has no public minor league
# leaderboard on this path. These are level-adjusted -- every rate is expressed
# against its own league, so 100 is average for the level and higher is always
# better, whichever direction the raw metric runs. See R/07_level_adjust.R.
# Still NOT park-adjusted: the Stats API publishes no minor league park factors.
FARM_NEED_PLAN <- list(
  list("OBP_plus","OBP+","Hitting","On-Base Ability",TRUE,"Hitters with approach and walk skill"),
  list("SLG_plus","SLG+","Hitting","Damage / Power",TRUE,"Extra-base impact"),
  list("OPS_plus","OPS+","Hitting","Overall Offense",TRUE,"Impact bat, on-base plus power"),
  list("ISO_plus","ISO+","Hitting","Game Power",TRUE,"Players with game power"),
  list("BBp_plus","BB%+","Hitting","Plate Discipline",TRUE,"Zone control and walk skill"),
  list("Kp_plus","K%+","Hitting","Contact Ability",TRUE,"Lower-strikeout, bat-to-ball profiles"),
  list("ERA_plus","ERA+","Pitching","Run Prevention",TRUE,"Starters who limit runs"),
  list("WHIP_plus","WHIP+","Pitching","Traffic Prevention",TRUE,"Arms who limit baserunners"),
  list("Kp_plus","K%+","Pitching","Swing and Miss",TRUE,"Bat-missing stuff"),
  list("BBp_plus","BB%+","Pitching","Command",TRUE,"Strike throwers"),
  list("HR9_plus","HR/9+","Pitching","Home Run Suppression",TRUE,"Arms who keep the ball in the park")
)
