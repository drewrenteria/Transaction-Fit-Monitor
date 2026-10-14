"""Pull everything the dashboard needs from the MLB Stats API, cache to JSON."""
import json, urllib.request, pathlib, datetime, sys, time
import os

B = "https://statsapi.mlb.com/api/v1"
BUILD = pathlib.Path(os.environ.get("BUILD_DIR")
                    or pathlib.Path(__file__).resolve().parent.parent / "build")

CACHE = BUILD / "cache"
CACHE.mkdir(parents=True, exist_ok=True)
SEASON = 2026
DAYS_BACK = 14
MILB_SPORTS = [11, 12, 13, 14, 16]
LEVEL = {1: "MLB", 11: "Triple-A", 12: "Double-A", 13: "High-A", 14: "Single-A", 16: "Rookie"}


def get(url, key, ttl=3600):
    f = CACHE / f"{key}.json"
    if f.exists() and time.time() - f.stat().st_mtime < ttl:
        return json.loads(f.read_text())
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                d = json.load(r)
            f.write_text(json.dumps(d))
            return d
        except Exception as e:
            if attempt == 2:
                print(f"  FAIL {key}: {e}", file=sys.stderr)
                return {}
            time.sleep(2)


def main():
    out = {}

    # ---- teams / affiliate map -------------------------------------------
    print("teams...")
    tj = get(f"{B}/teams?sportIds=1,{','.join(map(str,MILB_SPORTS))}&season={SEASON}",
             "teams", ttl=86400)
    teams = {}
    for t in tj.get("teams", []):
        sid = (t.get("sport") or {}).get("id")
        teams[t["id"]] = {
            "club": t.get("name"),
            "parent": t.get("parentOrgName") or t.get("name"),
            "sport": sid,
            "level": LEVEL.get(sid),
            "abbr": t.get("abbreviation"),
            "nick": t.get("teamName"),
        }
    out["teams"] = teams
    mlb_orgs = sorted({v["club"] for v in teams.values() if v["sport"] == 1})
    out["orgs"] = mlb_orgs
    print(f"  {len(teams)} clubs, {len(mlb_orgs)} MLB orgs")

    # ---- transactions ----------------------------------------------------
    end = datetime.date.today()
    start = end - datetime.timedelta(days=DAYS_BACK)
    print(f"transactions {start}..{end}")
    txj = get(f"{B}/transactions?startDate={start}&endDate={end}", "txns", ttl=1800)
    out["txns"] = txj.get("transactions", [])
    out["window"] = {"start": str(start), "end": str(end), "days": DAYS_BACK}
    print(f"  {len(out['txns'])} transactions")

    # ---- player bios for everyone in the window --------------------------
    pids = sorted({(t.get("person") or {}).get("id") for t in out["txns"]} - {None})
    print(f"player bios for {len(pids)}...")
    people = {}
    for i in range(0, len(pids), 100):
        ch = pids[i:i + 100]
        pj = get(f"{B}/people?personIds={','.join(map(str,ch))}", f"people_{i}", ttl=86400)
        for p in pj.get("people", []):
            pos = p.get("primaryPosition") or {}
            people[p["id"]] = {
                "name": p.get("fullName"),
                "pos": pos.get("abbreviation"),
                "posType": pos.get("type"),
                "bats": (p.get("batSide") or {}).get("code"),
                "throws": (p.get("pitchHand") or {}).get("code"),
                "age": p.get("currentAge"),
            }
    out["people"] = people
    print(f"  {len(people)} resolved")

    # ---- player season stat leaderboards ---------------------------------
    def leaderboard(group, sport_id, label):
        rows = {}
        off = 0
        while True:
            u = (f"{B}/stats?stats=season&season={SEASON}&group={group}"
                 f"&sportId={sport_id}&gameType=R&playerPool=All"
                 f"&limit=1000&offset={off}")
            d = get(u, f"lb2_{group}_{sport_id}_{off}", ttl=86400)
            splits = []
            for s in d.get("stats", []):
                splits += s.get("splits", [])
            if not splits:
                break
            for sp in splits:
                pl = sp.get("player") or {}
                pid = pl.get("id")
                if pid is None:
                    continue
                st = sp.get("stat") or {}
                tm = sp.get("team") or {}
                rows.setdefault(pid, []).append({"stat": st, "team": tm.get("name"),
                                                 "teamId": tm.get("id")})
            off += 1000
            if off > 8000:
                break
        print(f"  {label}: {len(rows)} players")
        return rows

    print("stat leaderboards...")
    out["mlb_hit"] = leaderboard("hitting", 1, "MLB hitting")
    out["mlb_pit"] = leaderboard("pitching", 1, "MLB pitching")

    milb_hit, milb_pit = {}, {}
    for sid in MILB_SPORTS:
        for grp, dest in (("hitting", milb_hit), ("pitching", milb_pit)):
            for pid, recs in leaderboard(grp, sid, f"{LEVEL[sid]} {grp}").items():
                for r in recs:
                    r["sport"] = sid
                    r["level"] = LEVEL[sid]
                dest.setdefault(pid, []).extend(recs)
    out["milb_hit"] = milb_hit
    out["milb_pit"] = milb_pit
    print(f"  MiLB totals: {len(milb_hit)} hitters, {len(milb_pit)} pitchers")

    # ---- team stats for needs --------------------------------------------
    print("team stats...")
    def team_stats(group, sport_id):
        d = get(f"{B}/teams/stats?season={SEASON}&stats=season&group={group}"
                f"&sportIds={sport_id}&gameType=R", f"ts_{group}_{sport_id}", ttl=86400)
        rows = {}
        for s in d.get("stats", []):
            for sp in s.get("splits", []):
                tm = sp.get("team") or {}
                if tm.get("id"):
                    rows[tm["id"]] = sp.get("stat") or {}
        return rows

    out["mlb_team_hit"] = team_stats("hitting", 1)
    out["mlb_team_pit"] = team_stats("pitching", 1)
    print(f"  MLB team: {len(out['mlb_team_hit'])} hitting, {len(out['mlb_team_pit'])} pitching")

    farm_hit, farm_pit = {}, {}
    for sid in MILB_SPORTS:
        for grp, dest in (("hitting", farm_hit), ("pitching", farm_pit)):
            for tid, st in team_stats(grp, sid).items():
                dest.setdefault(tid, []).append(st)
    out["farm_team_hit"] = farm_hit
    out["farm_team_pit"] = farm_pit
    print(f"  farm affiliates: {len(farm_hit)} hitting, {len(farm_pit)} pitching")

    # ---- 40-man rosters (acquisition cost context) -----------------------
    print("40-man rosters...")
    roster40 = {}
    for tid, info in teams.items():
        if info["sport"] != 1:
            continue
        rj = get(f"{B}/teams/{tid}/roster?rosterType=40Man&season={SEASON}",
                 f"r40_{tid}", ttl=86400)
        for e in rj.get("roster", []):
            pid = (e.get("person") or {}).get("id")
            if pid:
                roster40[pid] = {"org": info["club"],
                                 "status": (e.get("status") or {}).get("description")}
    out["roster40"] = roster40
    print(f"  {len(roster40)} players on 40-man rosters")

    p = (BUILD / "data.json")
    p.write_text(json.dumps(out))
    print(f"\nwrote {p} ({p.stat().st_size/1e6:.1f} MB)")


if __name__ == "__main__":
    main()
