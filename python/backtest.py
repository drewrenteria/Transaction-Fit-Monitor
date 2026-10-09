"""Backtest the evaluation thresholds against the 2026 season.

Method, and the reason it is honest:

  For every event that put a player on the market in 2026, the player is graded
  using ONLY his 2024-2025 line. That line was complete and public before the
  2026 season began, so nothing about the grade depends on information that
  arrived after the event. No lookahead.

  The outcome is then read from the transaction feed: did another organization
  claim or sign him within the window?

  This tests one specific thing -- whether the positive thresholds in the
  dashboard pick out players the industry actually wants. It does NOT test
  whether those players went on to perform. That needs another season.
"""
import json, pathlib, datetime, collections

BUILD = pathlib.Path("/home/claude/build")
TX = json.loads((BUILD / "tx2026.json").read_text())
PRIOR = {int(k): v for k, v in json.loads((BUILD / "prior2425.json").read_text()).items()}

MARKET_OPEN = {"Designated for Assignment", "Released", "Declared Free Agency"}
RESOLVE = {"Claimed Off Waivers", "Signed as Free Agent", "Trade", "Selected"}
WINDOW_DAYS = 45

# Same cutoffs the dashboard uses.
PIT_POS = {"BBp": lambda v: v <= 8.5, "Kp": lambda v: v >= 23,
           "WHIP": lambda v: v <= 1.25, "ERA": lambda v: v <= 4.00,
           "HR9": lambda v: v <= 1.10, "FIP": lambda v: v <= 4.00}
PIT_RISK = {"BBp": lambda v: v >= 11, "Kp": lambda v: v <= 18,
            "WHIP": lambda v: v >= 1.40, "ERA": lambda v: v >= 5.00,
            "HR9": lambda v: v >= 1.50, "FIP": lambda v: v >= 5.00}
HIT_POS = {"OBP": lambda v: v >= .330, "BBp": lambda v: v >= 9, "Kp": lambda v: v <= 22,
           "ISO": lambda v: v >= .170, "SLG": lambda v: v >= .400,
           "wRCplus": lambda v: v >= 105}
HIT_RISK = {"OBP": lambda v: v < .300, "BBp": lambda v: v < 6, "Kp": lambda v: v >= 28,
            "ISO": lambda v: v < .120, "SLG": lambda v: v < .330,
            "wRCplus": lambda v: v < 85}

MIN_PA, MIN_IP = 100, 30   # a real 2024-25 sample, not a cup of coffee


def d(s):
    return datetime.date.fromisoformat(s) if s else None


# index every transaction by player, in order
by_player = collections.defaultdict(list)
for t in TX:
    pid = (t.get("person") or {}).get("id")
    if pid:
        by_player[pid].append(t)
for pid in by_player:
    by_player[pid].sort(key=lambda e: (e.get("date") or "", e.get("id") or 0))


def grade(pid):
    """Strength and risk counts from the 2024-25 line only."""
    pr = PRIOR.get(pid)
    if not pr:
        return None
    if "pit" in pr and (pr["pit"].get("IP") or 0) >= MIN_IP:
        s, POS, RISK, grp = pr["pit"], PIT_POS, PIT_RISK, "Pitcher"
    elif "bat" in pr and (pr["bat"].get("PA") or 0) >= MIN_PA:
        s, POS, RISK, grp = pr["bat"], HIT_POS, HIT_RISK, "Hitter"
    else:
        return None
    pos = sum(1 for k, fn in POS.items() if s.get(k) is not None and fn(s[k]))
    risk = sum(1 for k, fn in RISK.items() if s.get(k) is not None and fn(s[k]))
    if risk >= 2 or (risk >= 1 and pos == 0):
        label = "Does not match"
    elif pos >= 2 and risk == 0:
        label = "Strong"
    elif pos >= 1:
        label = "Possible"
    else:
        label = "Further review"
    return {"pos": pos, "risk": risk, "label": label, "grp": grp}


rows = []
for t in TX:
    if t.get("typeDesc") not in MARKET_OPEN:
        continue
    pid = (t.get("person") or {}).get("id")
    if not pid:
        continue
    g = grade(pid)
    if not g:
        continue                      # no meaningful prior-season line
    ev_date = d(t.get("date"))
    from_org = ((t.get("fromTeam") or t.get("toTeam") or {}).get("name"))

    # Several outcomes, because "somebody signed him" is a weak signal: most
    # of this population lands somewhere. A waiver claim costs a 40-man spot
    # and the remaining salary, so it reflects real demand. Reaching a major
    # league roster afterward reflects whether the bet paid off.
    picked, by, how, lag = False, None, None, None
    claimed = False      # taken on waivers specifically
    fast = False         # picked up inside a week
    reached_mlb = False  # selected or recalled to an MLB roster afterward
    for nxt in by_player[pid]:
        nd = d(nxt.get("date"))
        if not nd or nd < ev_date or (nxt.get("id") or 0) <= (t.get("id") or 0):
            continue
        gap = (nd - ev_date).days
        if gap <= WINDOW_DAYS and nxt.get("typeDesc") in RESOLVE and not picked:
            picked = True
            by = (nxt.get("toTeam") or {}).get("name")
            how = nxt.get("typeDesc")
            lag = gap
            claimed = nxt.get("typeDesc") == "Claimed Off Waivers"
            fast = gap <= 7
        if gap <= 180 and nxt.get("typeDesc") in ("Selected", "Recalled"):
            reached_mlb = True

    rows.append({"pid": pid, "name": (t.get("person") or {}).get("fullName"),
                 "date": str(ev_date), "event": t.get("typeDesc"),
                 "from": from_org, "grp": g["grp"], "label": g["label"],
                 "pos": g["pos"], "risk": g["risk"],
                 "picked": picked, "by": by, "how": how, "lag": lag,
                 "claimed": claimed, "fast": fast, "reachedMlb": reached_mlb})

print(f"market-opening events in 2026: "
      f"{sum(1 for t in TX if t.get('typeDesc') in MARKET_OPEN)}")
print(f"gradeable from a 2024-25 line ({MIN_PA}+ PA or {MIN_IP}+ IP): {len(rows)}")
print()

ORDER = ["Strong", "Possible", "Further review", "Does not match"]

def rate_table(title, field, note):
    print(f"\n{title}")
    print(f"{'label':<16}{'n':>6}{'hits':>7}{'rate':>8}")
    print("-" * 37)
    base_n = sum(1 for r in rows if r[field])
    for lab in ORDER:
        sub = [r for r in rows if r["label"] == lab]
        if not sub:
            continue
        h = sum(1 for r in sub if r[field])
        print(f"{lab:<16}{len(sub):>6}{h:>7}{h/len(sub):>7.1%}")
    print("-" * 37)
    print(f"{'all':<16}{len(rows):>6}{base_n:>7}{base_n/len(rows):>7.1%}")
    print(f"  {note}")

print(f"{'label':<16}{'n':>6}{'picked up':>11}{'rate':>8}   {'median days':>11}")
print("-" * 56)
summary = []
for lab in ORDER:
    sub = [r for r in rows if r["label"] == lab]
    if not sub:
        continue
    hit = [r for r in sub if r["picked"]]
    lags = sorted(r["lag"] for r in hit if r["lag"] is not None)
    med = lags[len(lags)//2] if lags else None
    rate = len(hit)/len(sub)
    summary.append({"label": lab, "n": len(sub), "picked": len(hit),
                    "rate": round(rate, 4), "medianDays": med})
    print(f"{lab:<16}{len(sub):>6}{len(hit):>11}{rate:>7.1%}   {str(med):>11}")

base = sum(1 for r in rows if r["picked"]) / len(rows)
print("-" * 56)
print(f"{'all':<16}{len(rows):>6}{sum(1 for r in rows if r['picked']):>11}{base:>7.1%}")
print()

# does strength count track demand monotonically?
print("by number of strengths cleared:")
for n in range(0, 7):
    sub = [r for r in rows if r["pos"] == n]
    if len(sub) < 15:
        continue
    hit = sum(1 for r in sub if r["picked"])
    print(f"  {n} strengths  n={len(sub):>4}  picked up {hit/len(sub):>6.1%}")

print()
print("by event type:")
for ev in ["Designated for Assignment", "Released", "Declared Free Agency"]:
    sub = [r for r in rows if r["event"] == ev]
    if not sub:
        continue
    hit = sum(1 for r in sub if r["picked"])
    print(f"  {ev:<30} n={len(sub):>4}  picked up {hit/len(sub):>6.1%}")

for title, field, note in [
    ("OUTCOME: claimed off waivers (costs a 40-man spot)", "claimed",
     "A claim is real demand. A free agent signing often is not."),
    ("OUTCOME: picked up within 7 days", "fast",
     "Speed separates wanted from eventually-placed."),
    ("OUTCOME: reached an MLB roster within 180 days", "reachedMlb",
     "Did the pickup actually produce major league value."),
]:
    rate_table(title, field, note)

out = {"rows": rows, "summary": summary, "base": round(base, 4),
       "windowDays": WINDOW_DAYS, "minPA": MIN_PA, "minIP": MIN_IP,
       "events": sum(1 for t in TX if t.get("typeDesc") in MARKET_OPEN),
       "graded": len(rows)}
(BUILD / "backtest.json").write_text(json.dumps(out))
print(f"\nwrote backtest.json ({len(rows)} graded events)")
