"""Rebuild the dashboard as of an arbitrary past date, point in time.

Everything is bounded to the as-of date:
  - transactions come from the feed up to that date only
  - FanGraphs leaderboards are date-bounded, so team and player rates reflect
    what was known then, not the finished season
  - the DFA clock is measured against the as-of date, so claim windows that
    were live that day show as live

The one compromise is minor league rates: the Stats API serves season totals
and will not bound by date, so the farm side carries later-season information.
That is flagged in the build and on the page rather than papered over.
"""
import json, pathlib, datetime, sys, time, urllib.request, collections
import os

AS_OF = datetime.date.fromisoformat(sys.argv[1] if len(sys.argv) > 1 else "2026-07-04")
DAYS_BACK = 14
UA = {"User-Agent": ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                     "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36")}
FGB = "https://www.fangraphs.com/api/leaders/major-league/data"
BUILD = pathlib.Path(os.environ.get("BUILD_DIR")
                    or pathlib.Path(__file__).resolve().parent.parent / "build")

CACHE = BUILD / "cache"; CACHE.mkdir(exist_ok=True)


def fg(stats, team_level, key, extra=""):
    f = CACHE / f"{key}.json"
    if f.exists():
        return json.loads(f.read_text())
    url = (f"{FGB}?pos=all&stats={stats}&lg=all&qual=0&season={AS_OF.year}"
           f"&season1={AS_OF.year}&ind=0&pageitems=3000"
           + ("&team=0,ts" if team_level else "")
           + f"&startdate={AS_OF.year}-03-01&enddate={AS_OF}&month=1000" + extra)
    d = json.load(urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120))
    f.write_text(json.dumps(d))
    time.sleep(1.5)
    return d


def rows_of(d):
    return d if isinstance(d, list) else (d.get("data") or [])


import re
TAG = re.compile(r"<[^>]+>")
clean = lambda v: TAG.sub("", v or "").strip()
pct = lambda v: None if v is None else v * 100

print(f"building snapshot as of {AS_OF}")

# ---- transactions up to the as-of date -------------------------------------
TX_ALL = json.loads((BUILD / "tx2026.json").read_text())
start = AS_OF - datetime.timedelta(days=DAYS_BACK)
tx = [t for t in TX_ALL if t.get("date") and
      start <= datetime.date.fromisoformat(t["date"]) <= AS_OF]
print(f"  transactions {start} to {AS_OF}: {len(tx)}")

# full history up to as-of, for the availability walk
hist = [t for t in TX_ALL if t.get("date") and
        datetime.date.fromisoformat(t["date"]) <= AS_OF]

# ---- date-bounded FanGraphs -------------------------------------------------
tag = AS_OF.isoformat().replace("-", "")
tb = rows_of(fg("bat", True, f"snap_tb_{tag}"))
tp = rows_of(fg("pit", True, f"snap_tp_{tag}"))
tf = rows_of(fg("fld", True, f"snap_tf_{tag}"))
pb = rows_of(fg("bat", False, f"snap_pb_{tag}"))
pp = rows_of(fg("pit", False, f"snap_pp_{tag}"))
print(f"  FanGraphs as of {AS_OF}: teams {len(tb)}/{len(tp)}/{len(tf)}, "
      f"players {len(pb)}/{len(pp)}")


def team_key(r):
    for k in ("TeamName", "TeamNameAbb", "Team"):
        if r.get(k):
            return clean(str(r[k]))
    return None


team_bat = {team_key(r): {
    "wRCplus": r.get("wRC+"), "OBP": r.get("OBP"), "SLG": r.get("SLG"),
    "ISO": r.get("ISO"), "BBp": pct(r.get("BB%")), "Kp": pct(r.get("K%")),
    "BsR": r.get("BaseRunning"), "Spd": r.get("Spd")} for r in tb if team_key(r)}
team_pit = {team_key(r): {
    "FIP": r.get("FIP"), "xFIP": r.get("xFIP"), "ERA": r.get("ERA"),
    "WHIP": r.get("WHIP"), "HR9": r.get("HR/9"), "Kp": pct(r.get("K%")),
    "BBp": pct(r.get("BB%")), "KBBp": pct(r.get("K-BB%"))} for r in tp if team_key(r)}
team_fld = {team_key(r): {"DRS": r.get("DRS"), "Def": r.get("Defense")}
            for r in tf if team_key(r)}

players = {}
for r in pb:
    mid = r.get("xMLBAMID")
    if mid and r.get("PA"):
        players.setdefault(int(mid), {})["bat"] = {
            "PA": r.get("PA"), "wRCplus": r.get("wRC+"), "OBP": r.get("OBP"),
            "SLG": r.get("SLG"), "ISO": r.get("ISO"), "BBp": pct(r.get("BB%")),
            "Kp": pct(r.get("K%")), "BsR": r.get("BaseRunning"),
            "Def": r.get("Defense"), "WAR": r.get("WAR")}
for r in pp:
    mid = r.get("xMLBAMID")
    if mid and r.get("IP"):
        players.setdefault(int(mid), {})["pit"] = {
            "IP": r.get("IP"), "FIP": r.get("FIP"), "xFIP": r.get("xFIP"),
            "ERA": r.get("ERA"), "WHIP": r.get("WHIP"), "HR9": r.get("HR/9"),
            "Kp": pct(r.get("K%")), "BBp": pct(r.get("BB%")),
            "KBBp": pct(r.get("K-BB%")), "WAR": r.get("WAR")}

# ---- bios for this snapshot's own population --------------------------------
# The live build's bios cover only its own window, so a past snapshot has to
# fetch its own or most of its players have no position and drop out.
SAPI = "https://statsapi.mlb.com/api/v1"
need_ids = sorted({(t.get("person") or {}).get("id") for t in tx} - {None})
print(f"  fetching bios for {len(need_ids)} players in window")
people = {}
for i in range(0, len(need_ids), 100):
    ch = need_ids[i:i + 100]
    f = CACHE / f"snap_people_{tag}_{i}.json"
    if f.exists():
        pj = json.loads(f.read_text())
    else:
        pj = json.load(urllib.request.urlopen(
            f"{SAPI}/people?personIds={','.join(map(str,ch))}", timeout=90))
        f.write_text(json.dumps(pj))
    for pr in pj.get("people", []):
        pos = pr.get("primaryPosition") or {}
        people[pr["id"]] = {"name": pr.get("fullName"), "pos": pos.get("abbreviation"),
                            "posType": pos.get("type"),
                            "bats": (pr.get("batSide") or {}).get("code"),
                            "throws": (pr.get("pitchHand") or {}).get("code"),
                            "age": pr.get("currentAge")}
print(f"  bios resolved: {len(people)}")

out = {"asOf": str(AS_OF), "daysBack": DAYS_BACK, "tx": tx, "hist": hist,
       "people": people,
       "teamBat": team_bat, "teamPit": team_pit, "teamFld": team_fld,
       "players": players}
(BUILD / f"snap_{tag}.json").write_text(json.dumps(out))
print(f"  wrote snap_{tag}.json")

# quick look at what DFA clocks were live that day
opens = collections.Counter()
for t in tx:
    if t.get("typeDesc") in ("Designated for Assignment", "Released", "Declared Free Agency"):
        opens[t["typeDesc"]] += 1
print(f"  market-opening events in window: {dict(opens)}")
