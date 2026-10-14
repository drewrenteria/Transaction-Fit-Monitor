# Transaction Fit Monitor

**[Open the live dashboard →](https://drewrenteria.github.io/Transaction-Fit-Monitor/)**

[![Transaction Fit Monitor](docs/preview.png)](https://drewrenteria.github.io/Transaction-Fit-Monitor/)

*Pick any of the thirty clubs from the dropdown and the whole page re-scores
instantly. Rebuilds itself daily, so the live version will have moved on from
this screenshot.*

There is also a **[point-in-time rebuild of July 4, 2026](https://drewrenteria.github.io/Transaction-Fit-Monitor/snapshot-2026-07-04.html)**,
frozen mid-season so the claim clocks are live: transactions, FanGraphs rates
and the seven-day DFA window are all bounded to that date, nothing from after it
leaks in.

---

About a thousand transactions clear league-wide in a two-week window, major and
minor league combined. Almost all of them are noise. A handful put somebody on
the market who could actually help your club, and finding those means reading
the whole feed.

This reads it for you. It works out who is genuinely gettable right now, then
sorts that list by whether a player's production answers a hole your
organization actually has. The point is to turn a thousand rows into a dozen
names worth a human look, not to make the call for anyone.

Built for people with ninety seconds.

![status](https://img.shields.io/badge/status-working-brightgreen)
![R](https://img.shields.io/badge/built%20with-R-276DC3)

### What this is confident about, and what it is not

**Availability is the solid half.** Each player's transaction history is walked
in order, so a man designated and then claimed drops off the board, a man
another club just signed drops off, and a man designated three weeks ago and
never claimed is still on it with his clock showing. That is checkable against
the feed and it is right.

**Fit is a first-pass sort, not a prediction.** Two backtests say the coarse
signal is real and the fine one is not. Clubs do acquire players in the
category they are short in, measurably more often than chance (76.0% against a
68.5% base rate, p = 0.0099). But *which* player they take inside that category
has no relationship to how many specific metrics he clears. So the labels state
what was computed ("clears 2 of 3 needs") instead of implying confidence
("strong match"), and the work they do is narrowing the list, not ranking it
for a decision. The read still belongs to the reader.
[Does any of this work?](#does-any-of-this-work) has the numbers and the
caveats.

## What it does

- Pulls every transaction league-wide, major and minor, from the MLB Stats API
- Works out who is **actually gettable today** by walking each player's event
  sequence, so a player who was designated and then claimed drops off the board
- Runs a claim clock on designations, since that decision expires
- Flags each club's real weaknesses using rank **and** distance from league
  average, rather than "bottom half", which flags fifteen clubs on every metric
- Scores available players against those weaknesses, with the sample size
  caveats stated rather than buried
- Ships as one HTML file with no dependencies: email it, open it offline, print it

## Quick start

```bash
Rscript build.R                 # as of today
Rscript build.R 2026-07-04      # point-in-time rebuild of a past date
```

Output lands in `output/`. Open the HTML in any browser.

First run takes a few minutes and fills `cache/`. After that it is fast, and
changing `template.html` costs no network calls at all.

### Requirements

```r
install.packages(c("jsonlite", "dplyr", "purrr", "tibble", "httr2"))
```

## How it is put together

```
build.R                      run the chain end to end
R/00_config.R                constants and every tunable threshold
R/01_fetch_statsapi.R        transactions, clubs, bios, minor league rates
R/02_fetch_fangraphs.R       wRC+, FIP, xFIP, DRS, BsR, three-year lines
R/03_needs.R                 z-score need detection
R/04_availability.R          market status, claim clock, acquisition path
R/05_build_payload.R         assemble JSON, write the HTML
template.html                the page; reads the payload and scores fit in-browser

R/06_needfit_test.R          the need-fit backtest: does need predict the buyer?
needfit_test.R               runs it
python/                      reference implementation, not the pipeline
validate.R                   diffs the R payload against that reference
```

**Why there is Python in an R repo.** The project was prototyped in Python and
then ported. The prototype is kept rather than deleted for two reasons: it
produces the same payload shape, so a suspicious R result can be diffed against
a second implementation instead of being argued about (`validate.R` does this,
and it is how the missing-bios bug below was caught), and `backtest.py` holds
the threshold validation, which was never ported. Nothing in `python/` runs
during a build.

The page computes fit in the browser from one shipped dataset. That is why
switching organizations is instant rather than reloading: the data ships once
instead of being precomputed thirty times.

Thresholds all live in `R/00_config.R`. Change a cutoff there and rebuild.

## Where the numbers come from

| Layer | Source | Why |
|---|---|---|
| Transactions, rosters, positions | MLB Stats API | One call covers every club with MLBAM ids attached |
| Major league club needs | FanGraphs | wRC+, FIP, xFIP, DRS and BsR are park and league adjusted |
| Major league player lines | FanGraphs | Joined on MLBAM id, so no name matching |
| Farm needs and minor league lines | MLB Stats API | FanGraphs has no public minor league leaderboard on this path |

That last row is the weakest link and the page says so. Minor league rates carry
no park or level adjustment, so a .170 ISO in the complex league is treated the
same as a .170 ISO in Triple-A.

## Things that will bite you

**The Stats API code for Designated for Assignment is `DES`, not `DFA`.**
`DFA` is taken: it is the code for *Declared Free Agency*, the separate and far
rarer event where a player with the service time to do so elects free agency
after an outright. MLB's own `typeDesc` strings, counted over six weeks of the
2026 feed:

| `typeCode` | `typeDesc` | events |
|---|---|---|
| `DES` | Designated for Assignment | 123 |
| `DFA` | Declared Free Agency | 2 |

Mapping `DFA -> DFA` looks obviously correct, and quietly drops every real
designation while filling the board with free agents.

**Market-closing events arrive under more than one code.** A signing is `SFA`
when it is logged as a free agent signing and `SGN` when it is not; an
independent-league pickup is `ACQ` or `OBT`; a player coming back off a loan is
`RTN`. Any code left unmapped falls through as "Other" and can never close a
listing, which is how a player another club already signed would keep showing
as available. In the 2026 feed these four happen to close nobody who was on the
board — `SFA` already covers the affiliated path, and the rest are players
arriving from outside affiliated ball — but that is luck, not design. The Audit
tab counts unmapped types so the next unmapped code gets noticed before it
matters. What is left in "Other" now is suspensions, which genuinely belong in
neither bucket.

**`playerPool=All` on Stats API leaderboards.** The default returns only
qualified players: 46 major league pitchers instead of 868.

**FanGraphs keys fielding on nickname, batting and pitching on abbreviation,**
and its abbreviations differ from MLB's for seven clubs. The crosswalk is in
`00_config.R`; it warns loudly if a club fails to resolve.

**Fetch the bios for everyone on the market, not everyone in the window.** An
earlier version pulled player bios only for the fourteen-day transaction
window, which quietly dropped 127 available players: a man designated three
weeks ago is still on the market today but has no transaction inside the
window, so he arrived with no position and fell out of the board without an
error anywhere. `build.R` fetches the union of the two sets. This is the bug
`validate.R` was written to catch, and it is the reason the Python reference is
still in the repo.

**Sample size cuts both ways.** Only good numbers get flagged, so an ungated
small sample fills the board with players whose rates look strong precisely
because the sample is small. Rates are credited in tiers by where they
stabilize, and red flags are deliberately not gated the same way: missing a
decent player costs less than surfacing a bad one.

## Does any of this work?

Two backtests, and they disagree in a way that is worth understanding.

### Test one: do the labels predict that anyone wants the player?

`python/backtest.py`. Every player who hit the market in 2026, graded using
only his 2024-25 line, then checked against whether another club picked him up.
**No significant relationship, on any outcome including waiver claims.** So the
labels state what was computed ("clears 2 of 3 needs") rather than implying
confidence ("strong match").

That test is weaker than it looks, though. It asks whether good players are
good, which is not the claim this tool makes.

### Test two: do the needs predict *which* club takes him?

`needfit_test.R`, and this is the claim that matters. For every 2026
acquisition where a club picked up a player another club had let go, score that
player against the acquiring club's needs **and against all 29 others', as of
the same date**. Same player, same week, same market, so player quality is held
constant by construction. Under the null the acquirer lands mid-pack.

**Clubs match to need at the category level.**

| | acquirer | base rate | lift | p |
|---|---|---|---|---|
| Had a flagged need in his category | 0.760 | 0.685 | **+0.075** | **0.0099** |

**But inside a category, the metric-level scoring is worthless.** Among clubs
that needed pitching, which pitcher they took had nothing to do with how well
his rates answered the specific flagged metric:

| | acquirer percentile | p |
|---|---|---|
| All 30 clubs ranked | 0.511 | 0.55 |
| Only clubs needing his category | 0.501 | 0.95 |

**And the effect lives in deliberate moves, not depth signings** (exploratory,
not pre-registered):

| route | n | acquirer | base | lift |
|---|---|---|---|---|
| Trade | 41 | 0.829 | 0.644 | +0.185 |
| Claimed off waivers | 60 | 0.817 | 0.687 | +0.129 |
| Signed as free agent | 124 | 0.710 | 0.698 | +0.012 |

Trades and claims cost something: a prospect, a 40-man spot, waiver priority.
Those track need. In-season free agent signings are organizational depth and
track nothing.

### What that means for this dashboard

The coarse signal is real and the fine signal is not. Grouping available
players by the category a club is short in is doing honest work. Ranking them
by how many specific metrics they clear is not, and the labels are worded to
promise only the former.

### What would undercut this

- **Shared cause, not need-matching.** A club with a worn-out bullpen has both
  a flagged pitching need and an urgent roster hole. The need flag may be
  measuring the same thinness that forces the move, rather than any club
  consulting anything need-like. This design cannot separate the two.
- One season, n=225, and the route splits are small enough to be noise.
- Needs are rebuilt on a 14-day grid, so they are up to 13 days stale.
- Players are graded on their prior-season line, so a 2026 breakout is invisible.
  Realistic for a waiver decision, still a limitation.

### A flaw worth recording

The first version of the need-fit test excluded clubs with no flagged need in
the player's category, on the reasoning that "could not answer" is not "failed
to answer." That dropped **every pitcher** — 174 of 302 acquisitions — because
only about half of clubs carry a pitching need in a given week, so no pitcher
ever had a large enough comparison set. The test ran on position players alone
and returned a tidy null.

Scoring those clubs zero instead is both more correct, since a club with no
pitching need genuinely needs nothing a pitcher offers, and the thing that let
the majority of the sample back in. The finding above only exists because that
got caught. Both measures are still reported.

## Honest limitations

- The farm side is unadjusted for park and level.
- No write-back. Nobody can mark a player reviewed or dismissed, and nothing is
  logged automatically between runs. The Audit tab exports the current flag list
  as CSV so a forward record can be kept by hand.

## Data and licensing

Public data only: the MLB Stats API and FanGraphs leaderboards. No proprietary
or club-internal data is used, stored or committed, which is what makes this
shareable. **If you extend it with internal data, that stops being true** — move
the repo private and strip the cache before committing anything.

Not affiliated with or endorsed by MLB or FanGraphs.
