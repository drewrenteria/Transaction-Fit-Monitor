# =============================================================================
# 03_needs.R — which metrics actually represent a hole.
#
# The original rule was `bottom_half = rank > teams_count / 2`, which flags 15
# of 30 clubs on every metric by construction. With ~20 metrics an average club
# collected 10+ need flags, so every category read as a need and the fit labels
# stopped discriminating. A v6 screenshot of the old report shows 15 flags on
# screen at once.
#
# A metric is flagged here only when the club is BOTH low in rank AND a real
# distance below league average, and priority comes from the size of that gap
# rather than from the rank bucket.
# =============================================================================

suppressPackageStartupMessages({ library(dplyr); library(purrr); library(tibble) })

#' Rank one metric across clubs and measure the gap to league average.
rank_metric <- function(values, higher_is_better) {
  v <- values[!is.na(values)]
  if (length(v) < 10) return(NULL)
  mean_v <- mean(v); sd_v <- stats::sd(v) * sqrt((length(v) - 1) / length(v))  # population sd
  if (is.na(sd_v) || sd_v == 0) return(NULL)
  ord  <- order(if (higher_is_better) -v else v)
  rank <- integer(length(v)); rank[ord] <- seq_along(v)
  # signed so negative always means worse, whichever direction is good
  z <- if (higher_is_better) (v - mean_v) / sd_v else (mean_v - v) / sd_v
  tibble(org = names(v), value = unname(v), rank = rank, n = length(v),
         mean = mean_v, z = z, pct_rank = rank / length(v))
}

need_priority <- function(z) {
  ifelse(z <= NEED_PRI_HIGH, "High", ifelse(z <= NEED_PRI_MED, "Medium", "Low"))
}

#' Build the need list for every organization from a plan.
#'
#' @param hit_by_org named list: org -> named list of hitting-side values.
#'   Defense and baserunning values live here too, alongside wRC+.
#' @param pit_by_org named list: org -> named list of pitching-side values.
#' @param plan list of list(key, label, category, area, higher_is_better, profile)
#' @param cap  max needs kept per category, most acute first.
build_needs <- function(hit_by_org, pit_by_org, plan, cap = NULL) {
  orgs <- union(names(hit_by_org), names(pit_by_org))
  needs <- setNames(vector("list", length(orgs)), orgs)
  for (o in orgs) needs[[o]] <- list()

  for (p in plan) {
    key <- p[[1]]; label <- p[[2]]; cat_ <- p[[3]]
    area <- p[[4]]; hib <- p[[5]]; profile <- p[[6]]
    src <- if (identical(cat_, "Pitching")) pit_by_org else hit_by_org

    vals <- vapply(orgs, function(o) {
      x <- src[[o]][[key]]
      if (is.null(x) || length(x) == 0) NA_real_ else as.numeric(x[[1]])
    }, numeric(1))
    names(vals) <- orgs

    ranked <- rank_metric(vals, hib)
    if (is.null(ranked)) next

    flagged <- ranked %>% filter(pct_rank >= NEED_RANK_CUT, z <= NEED_Z_CUT)
    for (i in seq_len(nrow(flagged))) {
      r <- flagged[i, ]
      needs[[r$org]] <- c(needs[[r$org]], list(list(
        area = area, cat = cat_, metric = label,
        metricFull = sprintf("%s (%s)", label, cat_), key = key,
        val = round(r$value, 4), mean = round(r$mean, 4), z = round(r$z, 2),
        rank = as.integer(r$rank), n = as.integer(r$n),
        pri = need_priority(r$z), profile = profile)))
    }
  }

  # most acute first, then cap per category: five broad farm needs match almost
  # any competent minor leaguer, two do not
  for (o in orgs) {
    if (length(needs[[o]]) == 0) next
    needs[[o]] <- needs[[o]][order(vapply(needs[[o]], function(n) n$z, numeric(1)))]
    if (!is.null(cap)) {
      per <- list(); kept <- list()
      for (n in needs[[o]]) {
        c0 <- per[[n$cat]] %||% 0
        if (c0 < cap) { kept <- c(kept, list(n)); per[[n$cat]] <- c0 + 1 }
      }
      needs[[o]] <- kept
    }
  }
  needs
}

# --- rate helpers for the Stats API side (farm) ------------------------------

hit_rates <- function(s) {
  pa <- num(s$plateAppearances); if (is.na(pa) || pa <= 0) return(NULL)
  ab <- n0(s$atBats); h <- n0(s$hits)
  d2 <- n0(s$doubles); d3 <- n0(s$triples)
  hr <- n0(s$homeRuns); bb <- n0(s$baseOnBalls)
  k  <- n0(s$strikeOuts)
  hbp <- n0(s$hitByPitch); sf <- n0(s$sacFlies)
  avg <- if (ab > 0) h / ab else NA_real_
  tb  <- (h - d2 - d3 - hr) + 2 * d2 + 3 * d3 + 4 * hr
  slg <- if (ab > 0) tb / ab else NA_real_
  den <- ab + bb + hbp + sf
  obp <- if (den > 0) (h + bb + hbp) / den else NA_real_
  list(PA = pa, AVG = avg, OBP = obp, SLG = slg,
       OPS = obp + slg, ISO = slg - avg, HR = hr,
       BBp = 100 * bb / pa, Kp = 100 * k / pa, SB = n0(s$stolenBases))
}

pit_rates <- function(s) {
  ip <- ip_to_num(s$inningsPitched); if (is.na(ip) || ip <= 0) return(NULL)
  bf <- n0(s$battersFaced)
  k  <- n0(s$strikeOuts); bb <- n0(s$baseOnBalls)
  hr <- n0(s$homeRuns);  er <- n0(s$earnedRuns)
  h  <- n0(s$hits)
  kp  <- if (bf > 0) 100 * k / bf else NA_real_
  bbp <- if (bf > 0) 100 * bb / bf else NA_real_
  list(IP = ip, G = n0(s$gamesPlayed), GS = n0(s$gamesStarted),
       ERA = 9 * er / ip, WHIP = (h + bb) / ip, HR9 = 9 * hr / ip,
       Kp = kp, BBp = bbp, KBBp = kp - bbp)
}

#' Sum raw counting stats across several stat blocks, then recompute rates.
#' Averaging rates across affiliates would weight a 40-game rookie club the
#' same as a full Triple-A season.
aggregate_stats <- function(blocks, kind) {
  if (length(blocks) == 0) return(NULL)
  keys <- c("plateAppearances","atBats","hits","doubles","triples","homeRuns",
            "baseOnBalls","strikeOuts","stolenBases","hitByPitch","sacFlies",
            "battersFaced","earnedRuns","gamesPlayed","gamesStarted")
  tot <- setNames(as.list(rep(0, length(keys))), keys)
  ip <- 0
  for (b in blocks) {
    for (k in keys) {
      v <- num(b[[k]]); if (!is.na(v)) tot[[k]] <- tot[[k]] + v
    }
    v <- ip_to_num(b$inningsPitched); if (!is.na(v)) ip <- ip + v
  }
  if (identical(kind, "pit")) {
    if (ip <= 0) return(NULL)
    tot$inningsPitched <- ip
    bf <- tot$battersFaced
    kp  <- if (bf > 0) 100 * tot$strikeOuts / bf else NA_real_
    bbp <- if (bf > 0) 100 * tot$baseOnBalls / bf else NA_real_
    return(list(IP = ip, ERA = 9 * tot$earnedRuns / ip,
                WHIP = (tot$hits + tot$baseOnBalls) / ip,
                HR9 = 9 * tot$homeRuns / ip, Kp = kp, BBp = bbp, KBBp = kp - bbp))
  }
  hit_rates(tot)
}
