# =============================================================================
# 05_build_payload.R — assemble the JSON the page reads, and write the HTML.
#
# The page computes fit labels in the browser from this payload, which is why
# switching organizations is instant: the data ships once instead of being
# precomputed 30 times. Keep the key names below exactly as they are, because
# the template reads them directly.
# =============================================================================

suppressPackageStartupMessages({
  library(jsonlite); library(dplyr); library(purrr); library(tibble)
})

rnd <- function(x, digits) {
  if (is.null(x)) return(NULL)
  for (k in names(x)) {
    v <- x[[k]]
    if (is.numeric(v) && length(v) == 1 && !is.na(v))
      x[[k]] <- round(v, digits[[k]] %||% 3)
  }
  x
}

GROUP_OF <- c(Pitcher = "Pitching", Catcher = "Catching", Infielder = "Infield",
              Outfielder = "Outfield", Hitter = "Infield")

#' Position label the report uses. DH maps into Infield so it still resolves to
#' a position player downstream.
derive_profile <- function(pos_type, pos, throws) {
  grp <- unname(GROUP_OF[pos_type %||% ""]); if (is.na(grp)) grp <- "Unknown"
  p <- if (identical(grp, "Pitching")) {
    if (identical(throws, "L")) "LHP" else "RHP"
  } else if (!is.na(pos) && pos %in% c("LF", "CF", "RF", "OF")) "OF"
  else if (!is.na(pos)) pos else "Unknown"
  list(pos = p, group = grp)
}

#' Track record for the league board. Pick the record that matches what the
#' player is: a catcher who threw an inning in a blowout has a pitching line,
#' and reading it shows him as a 1 IP pitcher with the wrong WAR.
track_record <- function(pl) {
  is_pit <- identical(pl$g, "Pitching")
  c0 <- if (is_pit) pl$cp else pl$cb
  if (is.null(c0)) { c0 <- if (is_pit) pl$cb else pl$cp; is_pit <- !is_pit }
  if (is.null(c0)) return(NULL)
  list(WAR = c0$WAR, sample = if (is_pit) c0$IP else c0$PA,
       unit = if (is_pit) "IP" else "PA")
}

build_payload <- function(txns, teams, people, avail, mlb_needs, farm_needs,
                          fg_players, fg_career, milb_hit, milb_pit,
                          as_of = AS_OF, span_from = SEASON - (SPAN_YEARS - 1)) {

  # ---- players ----
  PL <- list()
  for (i in seq_len(nrow(people))) {
    r <- people[i, ]
    prof <- derive_profile(r$pos_type, r$pos, r$throws)
    k <- as.character(r$mlbam_id)
    fg <- fg_players[[k]]; car <- fg_career[[k]]
    PL[[k]] <- list(
      n = r$name, p = prof$pos, g = prof$group, a = r$age,
      b = r$bats, t = r$throws,
      nh = rnd(milb_hit[[k]], list(PA = 0, HR = 0, SB = 0, BBp = 1, Kp = 1)),
      np = rnd(milb_pit[[k]], list(IP = 1, ERA = 2, WHIP = 2, HR9 = 2,
                                   Kp = 1, BBp = 1, KBBp = 1)),
      fb = rnd(fg$bat,  list(PA = 0, wRCplus = 0, BBp = 1, Kp = 1,
                             BsR = 1, Def = 1, WAR = 1)),
      fp = rnd(fg$pit,  list(IP = 1, FIP = 2, xFIP = 2, ERA = 2, WHIP = 2,
                             HR9 = 2, Kp = 1, BBp = 1, KBBp = 1, WAR = 1)),
      cb = rnd(car$bat, list(PA = 0, wRCplus = 0, BBp = 1, Kp = 1,
                             BsR = 1, Def = 1, WAR = 1)),
      cp = rnd(car$pit, list(IP = 1, FIP = 2, xFIP = 2, ERA = 2, WHIP = 2,
                             HR9 = 2, Kp = 1, BBp = 1, KBBp = 1, WAR = 1))
    )
  }

  # ---- transactions for the page ----
  TX <- txns %>%
    transmute(id = txn_id, d = as.character(date), pid = mlbam_id,
              ty = txn_type, sc = scope, org = org, lvl = level,
              to = to_club, fr = from_club, tx = description %||% "",
              aff = affiliated, opens = opens)

  # ---- league board: best available, regardless of who needs them ----
  board <- list()
  for (pid in names(avail)) {
    a <- avail[[pid]]
    if (!isTRUE(a$avail)) next
    pl <- PL[[pid]]; if (is.null(pl)) next
    tr <- track_record(pl)
    board[[length(board) + 1]] <- list(
      pid = as.integer(pid), n = pl$n, p = pl$p, a = pl$a,
      lvl = a$lvl, st = a$st, days = a$days, onMarketDays = a$onMarketDays,
      new = isTRUE(a$new), from = a$from, openType = a$openType,
      war = tr$WAR, sample = tr$sample, unit = tr$unit)
  }
  ord <- order(vapply(board, function(b) is.null(b$war) || is.na(b$war), logical(1)),
               -vapply(board, function(b) b$war %||% NA_real_, numeric(1)),
               na.last = TRUE)
  board <- board[ord]

  n_new <- sum(vapply(avail, function(a) isTRUE(a$new), logical(1)))

  list(
    window = list(start = as.character(as_of - DAYS_BACK),
                  end = as.character(as_of), days = as.integer(DAYS_BACK)),
    today = as.character(as_of),
    spanFrom = as.integer(span_from),
    dfaWindow = as.integer(DFA_WINDOW),
    orgs = sort(teams$club[teams$sport_id == MLB_SPORT]),
    mlbNeeds = mlb_needs, farmNeeds = farm_needs,
    players = PL, avail = avail, txns = TX, board = board,
    newCount = as.integer(n_new),
    audit = list(
      txnTotal = nrow(TX),
      unmappedType = sum(TX$ty == "Other", na.rm = TRUE),
      missingPid = sum(is.na(TX$pid)),
      missingOrg = sum(is.na(TX$org)),
      outsideAffiliated = sum(!TX$aff),
      unknownGroup = sum(vapply(PL, function(p) identical(p$g, "Unknown"), logical(1))),
      mlbScope = sum(TX$sc == "MLB", na.rm = TRUE),
      milbScope = sum(TX$sc == "MiLB", na.rm = TRUE),
      otherScope = sum(TX$sc == "Other", na.rm = TRUE),
      players = length(PL),
      withFgStats = sum(vapply(PL, function(p) !is.null(p$fb) || !is.null(p$fp), logical(1))),
      # the page reads this name; keep both so the Audit tab does not blow up
      withMlbStats = sum(vapply(PL, function(p) !is.null(p$fb) || !is.null(p$fp), logical(1))),
      withMilbStats = sum(vapply(PL, function(p) !is.null(p$nh) || !is.null(p$np), logical(1))),
      withCareer = sum(vapply(PL, function(p) !is.null(p$cb) || !is.null(p$cp), logical(1))),
      onMarket = sum(vapply(avail, function(a) isTRUE(a$avail), logical(1))),
      marketOpenEvents = sum(TX$opens & TX$aff, na.rm = TRUE),
      on40man = sum(vapply(avail, function(a) isTRUE(a$on40), logical(1))),
      mlbNeedAvg = round(mean(lengths(mlb_needs)), 1),
      farmNeedAvg = round(mean(lengths(farm_needs)), 1)
    )
  )
}

#' Serialise and inject into the template.
#' auto_unbox matters: without it every scalar becomes a one-element array and
#' the page reads `["MLB"]` where it expects `"MLB"`.
write_dashboard <- function(payload, out_file = file.path(OUT_DIR, "transaction_fit_dashboard.html")) {
  ensure_dirs()
  js <- jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null",
                         na = "null", digits = NA)
  js <- gsub("</", "<\\\\/", js, fixed = TRUE)   # cannot close the script tag early

  # The template carries accented names, en dashes and arrows. Reading it in
  # the session locale mangles them and sub() then refuses the string, so the
  # whole round trip stays in bytes.
  tpl <- rawToChar(readBin(TEMPLATE, "raw", file.size(TEMPLATE)))
  Encoding(tpl) <- "UTF-8"
  if (!grepl("__PAYLOAD__", tpl, fixed = TRUE, useBytes = TRUE))
    stop("template.html has no __PAYLOAD__ placeholder")

  html <- sub("__PAYLOAD__", js, tpl, fixed = TRUE, useBytes = TRUE)
  con <- file(out_file, open = "wb")
  writeBin(charToRaw(html), con); close(con)
  message(sprintf("wrote %s (%.2f MB)", out_file, file.size(out_file) / 1e6))
  invisible(out_file)
}
