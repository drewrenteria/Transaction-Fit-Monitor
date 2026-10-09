"""Pull FanGraphs team and player leaderboards: wRC+, FIP, xFIP, DRS, BsR.

The MLB Stats API has no park- or league-adjusted metrics, so major league
evaluation runs on FanGraphs. FanGraphs exposes xMLBAMID, so everything joins
on MLBAM ID with no name matching.

FanGraphs has no public minor league leaderboard on this path (404), so the
farm side stays on the Stats API. That is a real limitation, not an oversight.
"""
import json, re, time, pathlib, urllib.request, urllib.error

CACHE = pathlib.Path("/home/claude/build/cache"); CACHE.mkdir(parents=True, exist_ok=True)
SEASON = 2026
BASE = "https://www.fangraphs.com/api/leaders/major-league/data"
UA = {"User-Agent": ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                     "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36")}

TAG = re.compile(r"<[^>]+>")


def get(url, key, ttl=86400):
    f = CACHE / f"{key}.json"
    if f.exists() and time.time() - f.stat().st_mtime < ttl:
        return json.loads(f.read_text())
    for attempt in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=90) as r:
                d = json.load(r)
            f.write_text(json.dumps(d))
            return d
        except Exception as e:
            if attempt == 2:
                print(f"  FAIL {key}: {e}")
                return {}
            time.sleep(3)


def rows_of(d):
    if isinstance(d, list):
        return d
    return d.get("data") or []


def leaderboard(stats, team_level, key, pageitems=2500):
    url = (f"{BASE}?pos=all&stats={stats}&lg=all&qual=0"
           f"&season={SEASON}&season1={SEASON}&ind=0&pageitems={pageitems}"
           + ("&team=0,ts" if team_level else ""))
    d = get(url, key)
    r = rows_of(d)
    print(f"  {key}: {len(r)} rows")
    # Be a considerate client: a handful of cached calls, not a scrape.
    time.sleep(1.5)
    return r


def clean_name(v):
    return TAG.sub("", v or "").strip()


def pct(v):
    """FanGraphs rate fields come back as decimals (0.105 = 10.5%)."""
    return None if v is None else v * 100


def main():
    out = {}

    print("FanGraphs team leaderboards...")
    tb = leaderboard("bat", True, "fg_team_bat")
    tp = leaderboard("pit", True, "fg_team_pit")
    tf = leaderboard("fld", True, "fg_team_fld")

    if tb:
        print("   team key candidates:",
              [k for k in tb[0] if re.search(r"team", k, re.I)][:8])

    def team_key(r):
        for k in ("TeamName", "TeamNameAbb", "Team", "teamName"):
            v = r.get(k)
            if v:
                return clean_name(str(v))
        return None

    team_bat, team_pit, team_fld = {}, {}, {}
    for r in tb:
        t = team_key(r)
        if t:
            team_bat[t] = {
                "wRCplus": r.get("wRC+"), "wOBA": r.get("wOBA"),
                "OBP": r.get("OBP"), "SLG": r.get("SLG"), "ISO": r.get("ISO"),
                "BBp": pct(r.get("BB%")), "Kp": pct(r.get("K%")),
                "BsR": r.get("BaseRunning"), "Spd": r.get("Spd"),
                "PA": r.get("PA"),
            }
    for r in tp:
        t = team_key(r)
        if t:
            team_pit[t] = {
                "FIP": r.get("FIP"), "xFIP": r.get("xFIP"), "SIERA": r.get("SIERA"),
                "ERA": r.get("ERA"), "WHIP": r.get("WHIP"), "HR9": r.get("HR/9"),
                "Kp": pct(r.get("K%")), "BBp": pct(r.get("BB%")),
                "KBBp": pct(r.get("K-BB%")), "IP": r.get("IP"),
            }
    for r in tf:
        t = team_key(r)
        if t:
            team_fld[t] = {"DRS": r.get("DRS"), "FP": r.get("FP"),
                           "Inn": r.get("Inn"), "Def": r.get("Defense")}

    print(f"  parsed teams: bat {len(team_bat)}, pit {len(team_pit)}, fld {len(team_fld)}")

    print("FanGraphs player leaderboards...")
    pb = leaderboard("bat", False, "fg_player_bat")
    pp = leaderboard("pit", False, "fg_player_pit")

    players = {}
    for r in pb:
        mid = r.get("xMLBAMID")
        if not mid:
            continue
        players.setdefault(int(mid), {})["bat"] = {
            "name": clean_name(r.get("Name")), "fgid": r.get("playerid"),
            "PA": r.get("PA"), "wRCplus": r.get("wRC+"), "wOBA": r.get("wOBA"),
            "OBP": r.get("OBP"), "SLG": r.get("SLG"), "ISO": r.get("ISO"),
            "BBp": pct(r.get("BB%")), "Kp": pct(r.get("K%")),
            "BsR": r.get("BaseRunning"), "Def": r.get("Defense"),
            "WAR": r.get("WAR"),
        }
    for r in pp:
        mid = r.get("xMLBAMID")
        if not mid:
            continue
        players.setdefault(int(mid), {})["pit"] = {
            "name": clean_name(r.get("Name")), "fgid": r.get("playerid"),
            "IP": r.get("IP"), "FIP": r.get("FIP"), "xFIP": r.get("xFIP"),
            "SIERA": r.get("SIERA"), "ERA": r.get("ERA"), "WHIP": r.get("WHIP"),
            "HR9": r.get("HR/9"), "Kp": pct(r.get("K%")), "BBp": pct(r.get("BB%")),
            "KBBp": pct(r.get("K-BB%")), "WAR": r.get("WAR"),
        }
    print(f"  players with FanGraphs lines: {len(players)}")

    # ---- three-year aggregate ------------------------------------------
    # One call per group: ind=0 with season1 < season returns a single combined
    # row per player. This is the direct answer to small current-season samples
    # -- a reliever with 27 innings this year has a few hundred across three.
    print("FanGraphs three-year aggregate...")
    SPAN_FROM = SEASON - 2

    def span(stats, key):
        url = (f"{BASE}?pos=all&stats={stats}&lg=all&qual=0"
               f"&season={SEASON}&season1={SPAN_FROM}&ind=0&pageitems=3000")
        d = get(url, key)
        r = rows_of(d)
        print(f"  {key}: {len(r)} rows")
        time.sleep(1.5)
        return r

    career = {}
    for r in span("bat", "fg_span_bat"):
        mid = r.get("xMLBAMID")
        if not mid or not r.get("PA"):
            continue
        career.setdefault(int(mid), {})["bat"] = {
            "PA": r.get("PA"), "wRCplus": r.get("wRC+"), "OBP": r.get("OBP"),
            "SLG": r.get("SLG"), "ISO": r.get("ISO"),
            "BBp": pct(r.get("BB%")), "Kp": pct(r.get("K%")),
            "BsR": r.get("BaseRunning"), "Def": r.get("Defense"),
            "WAR": r.get("WAR"),
        }
    for r in span("pit", "fg_span_pit"):
        mid = r.get("xMLBAMID")
        if not mid or not r.get("IP"):
            continue
        career.setdefault(int(mid), {})["pit"] = {
            "IP": r.get("IP"), "FIP": r.get("FIP"), "xFIP": r.get("xFIP"),
            "ERA": r.get("ERA"), "WHIP": r.get("WHIP"), "HR9": r.get("HR/9"),
            "Kp": pct(r.get("K%")), "BBp": pct(r.get("BB%")),
            "KBBp": pct(r.get("K-BB%")), "WAR": r.get("WAR"),
        }
    print(f"  players with a three-year line: {len(career)}")

    out = {"teamBat": team_bat, "teamPit": team_pit, "teamFld": team_fld,
           "players": players, "career": career,
           "season": SEASON, "spanFrom": SPAN_FROM}
    p = pathlib.Path("/home/claude/build/fg.json")
    p.write_text(json.dumps(out))
    print(f"wrote {p} ({p.stat().st_size/1e6:.1f} MB)")


if __name__ == "__main__":
    main()
