#!/usr/bin/env Rscript
# Compare the R payload against a reference payload produced by the Python
# prototype. Structural check only: keys, counts and a few spot values. Use it
# after changing the R chain to catch a port that drifted.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) stop("usage: Rscript validate.R <r_payload.json> <reference.json>")
library(jsonlite)
a <- fromJSON(args[1], simplifyVector = FALSE)
b <- fromJSON(args[2], simplifyVector = FALSE)

cmp <- function(label, x, y) {
  ok <- isTRUE(all.equal(x, y))
  cat(sprintf("%-28s %-14s %-14s %s\n", label, format(x), format(y),
              if (ok) "match" else "DIFFER"))
}
cat(sprintf("%-28s %-14s %-14s %s\n", "field", "R", "reference", ""))
cat(strrep("-", 72), "\n")
cmp("orgs",            length(a$orgs),    length(b$orgs))
cmp("players",         length(a$players), length(b$players))
cmp("transactions",    length(a$txns),    length(b$txns))
cmp("on the market",   a$audit$onMarket,  b$audit$onMarket)
cmp("board entries",   length(a$board),   length(b$board))
cmp("avg MLB needs",   a$audit$mlbNeedAvg,  b$audit$mlbNeedAvg)
cmp("avg farm needs",  a$audit$farmNeedAvg, b$audit$farmNeedAvg)
cmp("unmapped types",  a$audit$unmappedType, b$audit$unmappedType)
missing <- setdiff(names(b), names(a))
if (length(missing)) cat("\nkeys missing from the R payload:", paste(missing, collapse=", "), "\n")
