"""Compute per-org needs and compact player/transaction payload for the dashboard."""
import json, pathlib, statistics as st

import os

# Snapshot mode rebuilds the page as of a past date. Everything that can be
# bounded to that date is: the transaction feed, FanGraphs team and player
# rates, the career line (2024-25 only, so no 2026 leakage) and the clock.
SNAP = os.environ.get("SNAP_FILE")
OUT_NAME = os.environ.get("OUT_NAME", "payload.json")

BUILD = pathlib.Path(os.environ.get("BUILD_DIR")
                    or pathlib.Path(__file__).resolve().parent.parent / "build")

D = json.loads((BUILD / "data.json").read_text())
if SNAP:
    _S = json.loads(pathlib.Path(SNAP).read_text())
    D["txns"] = _S["hist"]            # full history to as-of, for the walk
    D["window"] = {"start": str(__import__("datetime").date.fromisoformat(_S["asOf"])
                                - __import__("datetime").timedelta(days=_S["daysBack"])),
                   "end": _S["asOf"], "days": _S["daysBack"]}
    print(f"SNAPSHOT MODE as of {_S['asOf']}")
teams = {int(k): v for k, v in D["teams"].items()}
MLB_ORG_ID = {tid: v["club"] for tid, v in teams.items() if v["sport"] == 1}
PARENT_OF = {tid: v["parent"] for tid, v in teams.items()}

# Events that put a player ON the market.
#   DFA                   -> club has a limited window to trade, release or waive him
#   Released              -> free agent immediately
#   Declared Free Agency  -> elected free agency rather than accept an assignment
MARKET_OPEN = {"DFA", "Released", "Declared Free Agency"}

# Events that take a player OFF the market. "Signed" and "Claimed" mean another
# club already got him; "Outrighted" means he cleared waivers and stayed in the
# organization. None of these are opportunities.
MARKET_CLOSE = {"Claimed", "Signed", "Trade", "Selected Contract",
                "Purchased Contract", "Outrighted", "Recall", "Option",
                "Activated", "Assigned", "Rehab Assignment", "Retired"}

# Days a club has to resolve a DFA before the window closes.
DFA_WINDOW_DAYS = 7
MLB40 = {"DFA", "Claimed", "Trade", "Selected Contract", "Purchased Contract",
         "Recall", "Option", "Outrighted"}


def f(x):
    try:
        v = float(x)
        return v
    except (TypeError, ValueError):
        return None


def ip_to_float(x):
    """MLB innings pitched use .1/.2 for thirds."""
    v = f(x)
    if v is None:
        return None
    whole = int(v)
    frac = round(v - whole, 1)
    return whole + {0.1: 1 / 3, 0.2: 2 / 3}.get(frac, 0.0)


def map_type(code, desc):
    d = (desc or "").lower()
    m = {"DES": "DFA", "CLW": "Claimed", "REL": "Released", "OUT": "Outrighted",
         "TR": "Trade", "SFA": "Signed", "SE": "Selected Contract",
         "OPT": "Option", "CU": "Recall", "DFA": "Declared Free Agency",
         "RET": "Retired"}
    if code in m:
        return m[code]
    if code == "ASG":
        return "Rehab Assignment" if "rehab" in d else "Assigned"
    if code == "SC":
        if "activated" in d:
            return "Activated"
        if "injured list" in d:
            return "Injured List"
        return "Status Change"
    return "Other"


# ---------------------------------------------------------------- hitting/pitching rate helpers
def hit_rates(s):
    pa = f(s.get("plateAppearances"))
    if not pa or pa <= 0:
        return None
    ab = f(s.get("atBats")) or 0
    h = f(s.get("hits")) or 0
    d2 = f(s.get("doubles")) or 0
    d3 = f(s.get("triples")) or 0
    hr = f(s.get("homeRuns")) or 0
    bb = f(s.get("baseOnBalls")) or 0
    k = f(s.get("strikeOuts")) or 0
    sb = f(s.get("stolenBases")) or 0
    avg = h / ab if ab else None
    tb = (h - d2 - d3 - hr) + 2 * d2 + 3 * d3 + 4 * hr
    slg = tb / ab if ab else None
    obp = f(s.get("obp")) if f(s.get("obp")) is not None else None
    if obp is None:
        hbp = f(s.get("hitByPitch")) or 0
        sf = f(s.get("sacFlies")) or 0
        den = ab + bb + hbp + sf
        obp = (h + bb + hbp) / den if den else None
    iso = (slg - avg) if (slg is not None and avg is not None) else None
    ops = (obp + slg) if (obp is not None and slg is not None) else None
    return {"PA": pa, "AVG": avg, "OBP": obp, "SLG": slg, "OPS": ops, "ISO": iso,
            "HR": hr, "BBp": 100 * bb / pa, "Kp": 100 * k / pa, "SB": sb}


def pit_rates(s):
    ip = ip_to_float(s.get("inningsPitched"))
    if not ip or ip <= 0:
        return None
    bf = f(s.get("battersFaced")) or 0
    k = f(s.get("strikeOuts")) or 0
    bb = f(s.get("baseOnBalls")) or 0
    hr = f(s.get("homeRuns")) or 0
    er = f(s.get("earnedRuns")) or 0
    h = f(s.get("hits")) or 0
    era = f(s.get("era"))
    if era is None:
        era = 9 * er / ip
    whip = f(s.get("whip"))
    if whip is None:
        whip = (h + bb) / ip
    kp = 100 * k / bf if bf else None
    bbp = 100 * bb / bf if bf else None
    return {"IP": ip, "G": f(s.get("gamesPlayed")) or 0, "GS": f(s.get("gamesStarted")) or 0,
            "ERA": era, "WHIP": whip, "HR9": 9 * hr / ip,
            "Kp": kp, "BBp": bbp,
            "KBBp": (kp - bbp) if (kp is not None and bbp is not None) else None}


def agg_hit(records):
    tot = {}
    levels = []
    for r in records:
        s = r["stat"]
        for key in ("plateAppearances", "atBats", "hits", "doubles", "triples",
                    "homeRuns", "baseOnBalls", "strikeOuts", "stolenBases",
                    "hitByPitch", "sacFlies"):
            tot[key] = (tot.get(key) or 0) + (f(s.get(key)) or 0)
        if r.get("level"):
            levels.append(r["level"])
    out = hit_rates(tot)
    if out:
        order = ["Triple-A", "Double-A", "High-A", "Single-A", "Rookie"]
        out["levels"] = "/".join(sorted(set(levels), key=lambda x: order.index(x) if x in order else 9))
        out["club"] = records[-1].get("team")
    return out


def agg_pit(records):
    tot = {}
    ip = 0.0
    levels = []
    for r in records:
        s = r["stat"]
        ip += ip_to_float(s.get("inningsPitched")) or 0
        for key in ("battersFaced", "strikeOuts", "baseOnBalls", "homeRuns",
                    "earnedRuns", "hits", "gamesPlayed", "gamesStarted"):
            tot[key] = (tot.get(key) or 0) + (f(s.get(key)) or 0)
        if r.get("level"):
            levels.append(r["level"])
    if ip <= 0:
        return None
    bf = tot.get("battersFaced") or 0
    k, bb = tot.get("strikeOuts") or 0, tot.get("baseOnBalls") or 0
    kp = 100 * k / bf if bf else None
    bbp = 100 * bb / bf if bf else None
    order = ["Triple-A", "Double-A", "High-A", "Single-A", "Rookie"]
    return {"IP": ip, "G": tot.get("gamesPlayed") or 0, "GS": tot.get("gamesStarted") or 0,
            "ERA": 9 * (tot.get("earnedRuns") or 0) / ip,
            "WHIP": ((tot.get("hits") or 0) + bb) / ip,
            "HR9": 9 * (tot.get("homeRuns") or 0) / ip,
            "Kp": kp, "BBp": bbp,
            "KBBp": (kp - bbp) if (kp is not None and bbp is not None) else None,
            "levels": "/".join(sorted(set(levels), key=lambda x: order.index(x) if x in order else 9)),
            "club": records[-1].get("team")}


# ---------------------------------------------------------------- needs
RANK_CUT, Z_CUT = 0.70, -0.50

NEED_PLAN = [
    # key, label, category, need_area, higher_is_better, target_profile
    ("OBP",  "OBP",   "Hitting",  "On-Base Ability",      True,  "Hitters with approach and walk skill"),
    ("SLG",  "SLG",   "Hitting",  "Damage / Power",       True,  "Extra-base impact"),
    ("OPS",  "OPS",   "Hitting",  "Overall Offense",      True,  "Impact bat, on-base plus power"),
    ("ISO",  "ISO",   "Hitting",  "Game Power",           True,  "Players with game power"),
    ("BBp",  "BB%",   "Hitting",  "Plate Discipline",     True,  "Zone control and walk skill"),
    ("Kp",   "K%",    "Hitting",  "Contact Ability",      False, "Lower-strikeout, bat-to-ball profiles"),
    ("ERA",  "ERA",   "Pitching", "Run Prevention",       False, "Starters who limit runs"),
    ("WHIP", "WHIP",  "Pitching", "Traffic Prevention",   False, "Arms who limit baserunners"),
    ("Kp",   "K%",    "Pitching", "Swing and Miss",       True,  "Bat-missing stuff"),
    ("BBp",  "BB%",   "Pitching", "Command",              False, "Strike throwers"),
    ("HR9",  "HR/9",  "Pitching", "Home Run Suppression", False, "Arms who keep the ball in the park"),
]


def build_needs(hit_by_org, pit_by_org, plan=None, cap=None):
    """hit_by_org / pit_by_org: {org_name: rates_dict}. Returns {org: [need,...]}."""
    needs = {o: [] for o in hit_by_org}
    for key, label, cat, area, hib, profile in (plan or NEED_PLAN):
        # Defense and baserunning live on the batting-side record.
        src = pit_by_org if cat == "Pitching" else hit_by_org
        vals = {o: v.get(key) for o, v in src.items() if v and v.get(key) is not None}
        if len(vals) < 10:
            continue
        mean = st.mean(vals.values())
        sd = st.pstdev(vals.values())
        if sd == 0:
            continue
        order = sorted(vals, key=lambda o: -vals[o] if hib else vals[o])
        n = len(order)
        for i, org in enumerate(order, 1):
            v = vals[org]
            z = (v - mean) / sd if hib else (mean - v) / sd
            if i / n >= RANK_CUT and z <= Z_CUT:
                needs[org].append({
                    "area": area, "cat": cat, "metric": label,
                    "metricFull": f"{label} ({cat})", "key": key,
                    "val": round(v, 4), "mean": round(mean, 4), "z": round(z, 2),
                    "rank": i, "n": n,
                    "pri": "High" if z <= -1.2 else ("Medium" if z <= -0.8 else "Low"),
                    "profile": profile,
                })
    for o in needs:
        needs[o].sort(key=lambda d: d["z"])
        if cap:
            # Keep only the most acute gaps per category. Five broad farm needs
            # match almost any competent minor leaguer; two or three do not.
            kept, per = [], {}
            for n in needs[o]:
                c = per.get(n["cat"], 0)
                if c < cap:
                    kept.append(n)
                    per[n["cat"]] = c + 1
            needs[o] = kept
    return needs


# ---------------------------------------------------------------- FanGraphs
# Major league evaluation runs on FanGraphs: wRC+, FIP, xFIP, DRS and BsR are
# park- and league-adjusted, which raw Stats API rates are not. FanGraphs has
# no public minor league leaderboard on this path, so the farm side below stays
# on the Stats API.
FG = json.loads((BUILD / "fg.json").read_text())
if SNAP:
    # date-bounded team and player rates; career line is 2024-25 only
    FG["teamBat"], FG["teamPit"], FG["teamFld"] = _S["teamBat"], _S["teamPit"], _S["teamFld"]
    FG["players"] = _S["players"]
    FG["career"] = json.loads((BUILD / "prior2425.json").read_text())
    FG["spanFrom"] = 2024
    D["people"] = _S["people"]      # bios for this snapshot's own population

# FanGraphs abbreviations differ from MLB's for a few clubs, and its fielding
# leaderboard keys on nickname rather than abbreviation.
FG_ABBR = {"TB": "TBR", "SD": "SDP", "SF": "SFG", "WSH": "WSN",
           "KC": "KCR", "CWS": "CHW", "AZ": "ARI"}
FG_NICK = {"D-backs": "Diamondbacks"}

fg_bat, fg_pit, fg_fld = FG["teamBat"], FG["teamPit"], FG["teamFld"]
mlb_hit_org, mlb_pit_org = {}, {}
_xwalk_miss = []
for tid, t in teams.items():
    if t["sport"] != 1:
        continue
    org = t["club"]
    ab = FG_ABBR.get(t["abbr"], t["abbr"])
    nick = FG_NICK.get(t["nick"], t["nick"])
    b, pch, fl = fg_bat.get(ab), fg_pit.get(ab), fg_fld.get(nick)
    if not b or not pch or not fl:
        _xwalk_miss.append((org, ab, nick, bool(b), bool(pch), bool(fl)))
        continue
    mlb_hit_org[org] = {**b, "DRS": fl.get("DRS"), "Def": fl.get("Def")}
    mlb_pit_org[org] = pch

if _xwalk_miss:
    print("FanGraphs crosswalk misses:", _xwalk_miss)
else:
    print(f"FanGraphs crosswalk: {len(mlb_hit_org)}/30 clubs resolved")

MLB_NEED_PLAN = [
    ("wRCplus", "wRC+",  "Hitting",     "Overall Offense",        True,  "Impact bat with on-base and contact value"),
    ("OBP",     "OBP",   "Hitting",     "On-Base Ability",        True,  "Hitters with approach and walk skill"),
    ("SLG",     "SLG",   "Hitting",     "Damage / Power",         True,  "Extra-base impact"),
    ("ISO",     "ISO",   "Hitting",     "Game Power",             True,  "Players with game power"),
    ("BBp",     "BB%",   "Hitting",     "Plate Discipline",       True,  "Zone control and walk skill"),
    ("Kp",      "K%",    "Hitting",     "Contact Ability",        False, "Lower-strikeout, bat-to-ball profiles"),
    ("FIP",     "FIP",   "Pitching",    "Run Prevention",         False, "Arms with better K, BB and HR indicators"),
    ("xFIP",    "xFIP",  "Pitching",    "Underlying Quality",     False, "Arms whose peripherals hold up"),
    ("ERA",     "ERA",   "Pitching",    "Runs Allowed",           False, "Starters who limit runs"),
    ("WHIP",    "WHIP",  "Pitching",    "Traffic Prevention",     False, "Arms who limit baserunners"),
    ("Kp",      "K%",    "Pitching",    "Swing and Miss",         True,  "Bat-missing stuff"),
    ("BBp",     "BB%",   "Pitching",    "Command",                False, "Strike throwers"),
    ("HR9",     "HR/9",  "Pitching",    "Home Run Suppression",   False, "Arms who keep the ball in the park"),
    ("DRS",     "DRS",   "Defense",     "Overall Defensive Value", True, "Versatile defenders at premium positions"),
    ("Def",     "Def",   "Defense",     "Defensive Runs",         True,  "Reliable run-prevention depth"),
    ("BsR",     "BsR",   "Baserunning", "Baserunning Value",      True,  "Runners who add value beyond stolen bases"),
    ("Spd",     "Spd",   "Baserunning", "Speed",                  True,  "Speed threat and late-game running value"),
]

mlb_needs = build_needs(mlb_hit_org, mlb_pit_org, plan=MLB_NEED_PLAN, cap=2)

# Farm system needs: aggregate affiliate team stats by parent org
farm_hit_raw, farm_pit_raw = {}, {}
for tid, stats in D["farm_team_hit"].items():
    parent = PARENT_OF.get(int(tid))
    if parent in mlb_hit_org:
        farm_hit_raw.setdefault(parent, []).extend(stats)
for tid, stats in D["farm_team_pit"].items():
    parent = PARENT_OF.get(int(tid))
    if parent in mlb_pit_org:
        farm_pit_raw.setdefault(parent, []).extend(stats)

farm_hit_org = {o: agg_hit([{"stat": s} for s in v]) or {} for o, v in farm_hit_raw.items()}
farm_pit_org = {o: agg_pit([{"stat": s} for s in v]) or {} for o, v in farm_pit_raw.items()}
MAX_FARM_NEEDS_PER_CATEGORY = 2
farm_needs = build_needs(farm_hit_org, farm_pit_org, cap=MAX_FARM_NEEDS_PER_CATEGORY)

# ---------------------------------------------------------------- players
people = {int(k): v for k, v in D["people"].items()}
mlb_hit = {int(k): v for k, v in D["mlb_hit"].items()}
mlb_pit = {int(k): v for k, v in D["mlb_pit"].items()}
milb_hit = {int(k): v for k, v in D["milb_hit"].items()}
milb_pit = {int(k): v for k, v in D["milb_pit"].items()}

GROUP = {"Pitcher": "Pitching", "Catcher": "Catching",
         "Infielder": "Infield", "Outfielder": "Outfield", "Hitter": "Infield"}


def rnd(d, places):
    if not d:
        return None
    return {k: (round(v, places.get(k, 3)) if isinstance(v, (int, float)) else v)
            for k, v in d.items()}


FGP = {int(k): v for k, v in FG["players"].items()}
FGC = {int(k): v for k, v in FG.get("career", {}).items()}
SPAN_FROM = FG.get("spanFrom")

PL = {}
for pid, bio in people.items():
    grp = GROUP.get(bio.get("posType"), "Unknown")
    pos = bio.get("pos")
    if grp == "Pitching":
        pos = "LHP" if bio.get("throws") == "L" else "RHP"
    mh = agg_hit([{"stat": r["stat"], "team": r["team"]} for r in mlb_hit.get(pid, [])]) if pid in mlb_hit else None
    mp = agg_pit([{"stat": r["stat"], "team": r["team"]} for r in mlb_pit.get(pid, [])]) if pid in mlb_pit else None
    nh = agg_hit(milb_hit.get(pid, [])) if pid in milb_hit else None
    np_ = agg_pit(milb_pit.get(pid, [])) if pid in milb_pit else None
    PL[pid] = {
        "n": bio.get("name"), "p": pos, "g": grp, "a": bio.get("age"),
        "b": bio.get("bats"), "t": bio.get("throws"),
        "mh": rnd(mh, {"PA": 0, "HR": 0, "SB": 0, "BBp": 1, "Kp": 1}),
        "mp": rnd(mp, {"IP": 1, "G": 0, "GS": 0, "ERA": 2, "WHIP": 2, "HR9": 2, "Kp": 1, "BBp": 1, "KBBp": 1}),
        "nh": rnd(nh, {"PA": 0, "HR": 0, "SB": 0, "BBp": 1, "Kp": 1}),
        "np": rnd(np_, {"IP": 1, "G": 0, "GS": 0, "ERA": 2, "WHIP": 2, "HR9": 2, "Kp": 1, "BBp": 1, "KBBp": 1}),
    }
    # FanGraphs major league line, joined on MLBAM id. Park- and league-adjusted,
    # so it supersedes the Stats API line for major league evaluation.
    fg = FGP.get(pid)
    if fg:
        fb, fp = fg.get("bat"), fg.get("pit")
        if fb:
            PL[pid]["fb"] = rnd({k: v for k, v in fb.items()
                                 if k in ("PA","wRCplus","wOBA","OBP","SLG","ISO",
                                          "BBp","Kp","BsR","Def","WAR")},
                                {"PA":0,"wRCplus":0,"BBp":1,"Kp":1,"BsR":1,"Def":1,"WAR":1})
        if fp:
            PL[pid]["fp"] = rnd({k: v for k, v in fp.items()
                                 if k in ("IP","FIP","xFIP","SIERA","ERA","WHIP",
                                          "HR9","Kp","BBp","KBBp","WAR")},
                                {"IP":1,"FIP":2,"xFIP":2,"SIERA":2,"ERA":2,"WHIP":2,
                                 "HR9":2,"Kp":1,"BBp":1,"KBBp":1,"WAR":1})
    # Three-year aggregate. Context for a thin current season, never the line
    # that gets graded -- the need is current, so the evaluation stays current.
    car = FGC.get(pid)
    if car:
        cb, cp = car.get("bat"), car.get("pit")
        if cb and (cb.get("PA") or 0) > 0:
            PL[pid]["cb"] = rnd(cb, {"PA":0,"wRCplus":0,"BBp":1,"Kp":1,
                                     "BsR":1,"Def":1,"WAR":1})
        if cp and (cp.get("IP") or 0) > 0:
            PL[pid]["cp"] = rnd(cp, {"IP":1,"FIP":2,"xFIP":2,"ERA":2,"WHIP":2,
                                     "HR9":2,"Kp":1,"BBp":1,"KBBp":1,"WAR":1})

# ---------------------------------------------------------------- transactions
TX = []
for t in D["txns"]:
    per = t.get("person") or {}
    pid = per.get("id")
    tt = teams.get((t.get("toTeam") or {}).get("id"), {})
    ft = teams.get((t.get("fromTeam") or {}).get("id"), {})
    typ = map_type(t.get("typeCode"), t.get("description"))
    org = tt.get("parent") or ft.get("parent")
    if not org:
        scope = "Other"          # amateur / independent / foreign league
    elif typ in MLB40:
        scope = "MLB"
    elif tt.get("sport") == 1 or ft.get("sport") == 1:
        scope = "MLB"
    elif tt.get("sport") or ft.get("sport"):
        scope = "MiLB"
    else:
        scope = "MLB"
    TX.append({
        "id": t.get("id"),
        "d": t.get("date"), "pid": pid, "ty": typ, "sc": scope, "org": org,
        "lvl": tt.get("level") or ft.get("level"),
        "to": tt.get("club"), "fr": ft.get("club"),
        "tx": t.get("description") or "",
        "aff": bool(org),
        "opens": typ in MARKET_OPEN,
    })

# ---------------------------------------------------------------- availability
# Walk each player's transaction sequence in order. The LAST event that changes
# his market status decides whether he is actually gettable today. Without this,
# a player who was DFA'd and then claimed by someone else still reads as a
# target, and a player another club just signed reads as available.
import datetime as _dt

TODAY = _dt.date.fromisoformat(D["window"]["end"])
roster40 = {int(k): v for k, v in D.get("roster40", {}).items()}

by_player = {}
for t in TX:
    if t["pid"]:
        by_player.setdefault(t["pid"], []).append(t)

AVAIL = {}
for pid, evs in by_player.items():
    # (date, id) ordering: ids are chronological, which settles same-day events
    # such as an outright and a free-agency election landing on one date.
    evs = sorted(evs, key=lambda e: (e["d"], e["id"] or 0))
    last_open = None
    status = "Rostered"
    status_date = evs[-1]["d"]
    closed_by = None
    for e in evs:
        if e["ty"] in MARKET_OPEN:
            last_open = e
            status = e["ty"]
            status_date = e["d"]
            closed_by = None
        elif e["ty"] in MARKET_CLOSE:
            if last_open is not None:
                closed_by = e
                last_open = None
            status = "Rostered"
            status_date = e["d"]

    available = last_open is not None
    days_left = None
    expired = False
    if available and last_open["ty"] == "DFA":
        deadline = _dt.date.fromisoformat(last_open["d"]) + _dt.timedelta(days=DFA_WINDOW_DAYS)
        days_left = (deadline - TODAY).days
        if days_left < 0:
            # The window lapsed and no resolving move appears in this feed.
            expired = True
            available = False

    r40 = roster40.get(pid)
    if available:
        if last_open["ty"] == "DFA":
            path = "Waiver claim"
            cost = "Claiming him takes a 40-man spot and his remaining salary."
        else:
            path = "Free agent signing"
            cost = ("He is a free agent. A major league deal needs a 40-man spot; "
                    "a minor league deal does not.")
    else:
        path = cost = None

    src = last_open or evs[-1]
    on_market_days = (TODAY - _dt.date.fromisoformat(src["d"])).days

    AVAIL[pid] = {
        "scope": src.get("sc"),
        "lvl": src.get("lvl"),
        "openType": (last_open or {}).get("ty"),
        "onMarketDays": on_market_days,
        "st": ("DFA" if available and last_open["ty"] == "DFA"
               else "Free agent" if available
               else "Window lapsed" if expired
               else "Claimed" if closed_by and closed_by["ty"] == "Claimed"
               else "Signed elsewhere" if closed_by and closed_by["ty"] == "Signed"
               else "Traded" if closed_by and closed_by["ty"] == "Trade"
               else "Stayed in org" if closed_by and closed_by["ty"] == "Outrighted"
               else "Resolved" if closed_by
               else "Rostered"),
        "avail": available,
        "since": (last_open or evs[-1])["d"],
        "days": days_left,
        "by": (closed_by or {}).get("org"),
        "byType": (closed_by or {}).get("ty"),
        "from": (last_open or {}).get("org"),
        "path": path,
        "cost": cost,
        "on40": bool(r40),
        "on40org": (r40 or {}).get("org"),
    }

# ---- who was already on the market a week ago? -----------------------------
# Same walk, cut off seven days earlier. Anyone available now who was not
# available then is new, which is what a returning reader actually wants.
WEEK_AGO = TODAY - _dt.timedelta(days=7)
was_available = set()
for pid, evs in by_player.items():
    prior = [e for e in sorted(evs, key=lambda e: (e["d"], e["id"] or 0))
             if _dt.date.fromisoformat(e["d"]) <= WEEK_AGO]
    open_ev = None
    for e in prior:
        if e["ty"] in MARKET_OPEN:
            open_ev = e
        elif e["ty"] in MARKET_CLOSE:
            open_ev = None
    if open_ev is not None:
        if open_ev["ty"] == "DFA":
            deadline = _dt.date.fromisoformat(open_ev["d"]) + _dt.timedelta(days=DFA_WINDOW_DAYS)
            if deadline < WEEK_AGO:
                continue
        was_available.add(pid)

for pid, a in AVAIL.items():
    a["new"] = bool(a["avail"] and pid not in was_available)

_avail_n = sum(1 for v in AVAIL.values() if v["avail"])
_new_n = sum(1 for v in AVAIL.values() if v.get("new"))
print(f"new to the market in the last 7 days: {_new_n}")
print(f"availability: {_avail_n} of {len(AVAIL)} players currently on the market")
import collections as _c
print(" status mix:", dict(_c.Counter(v["st"] for v in AVAIL.values()).most_common()))

# ---- league board: best players available, regardless of who needs them ----
# The fit filter is org-specific by design, which means the most notable name
# on the board can be invisible to most clubs. A busy reader wants it anyway.
def track_record(pid):
    """Pick the record that matches what the player is. A catcher who threw an
    inning in a blowout has a pitching line; reading it would show him as a
    1 IP pitcher and take his WAR from the wrong side of the ball."""
    pl = PL.get(pid) or {}
    is_pit = pl.get("g") == "Pitching"
    c = pl.get("cp") if is_pit else pl.get("cb")
    if not c:                      # fall back only if the matching one is absent
        c = pl.get("cb") if is_pit else pl.get("cp")
        if not c:
            return None
        is_pit = not is_pit
    return {"WAR": c.get("WAR"),
            "sample": c.get("IP") if is_pit else c.get("PA"),
            "unit": "IP" if is_pit else "PA"}

board = []
for pid, a in AVAIL.items():
    if not a["avail"]:
        continue
    pl = PL.get(pid)
    if not pl:
        continue
    tr = track_record(pid)
    board.append({
        "pid": pid, "n": pl["n"], "p": pl.get("p"), "a": pl.get("a"),
        "lvl": a.get("lvl"), "st": a["st"], "days": a.get("days"),
        "onMarketDays": a.get("onMarketDays"), "new": a.get("new"),
        "from": a.get("from"), "openType": a.get("openType"),
        "war": (tr or {}).get("WAR"), "sample": (tr or {}).get("sample"),
        "unit": (tr or {}).get("unit"),
    })
board.sort(key=lambda b: (b["war"] is None, -(b["war"] or 0)))
print("league board top 5:",
      [(b["n"], b["war"]) for b in board[:5]])

payload = {
    "window": D["window"],
    "board": board,
    "newCount": _new_n,
    "today": str(TODAY),
    "spanFrom": SPAN_FROM,
    "dfaWindow": DFA_WINDOW_DAYS,
    "avail": AVAIL,
    "orgs": D["orgs"],
    "mlbNeeds": mlb_needs,
    "farmNeeds": farm_needs,
    "players": PL,
    "txns": TX,
    "audit": {
        "txnTotal": len(TX),
        "unmappedType": sum(1 for t in TX if t["ty"] == "Other"),
        "missingPid": sum(1 for t in TX if not t["pid"]),
        "missingOrg": sum(1 for t in TX if not t["org"]),
        "outsideAffiliated": sum(1 for t in TX if not t["aff"]),
        "unknownGroup": sum(1 for t in TX if t["pid"] and PL.get(t["pid"], {}).get("g") == "Unknown"),
        "mlbScope": sum(1 for t in TX if t["sc"] == "MLB"),
        "milbScope": sum(1 for t in TX if t["sc"] == "MiLB"),
        "otherScope": sum(1 for t in TX if t["sc"] == "Other"),
        "players": len(PL),
        "withMlbStats": sum(1 for p in PL.values() if p["mh"] or p["mp"]),
        "withMilbStats": sum(1 for p in PL.values() if p["nh"] or p["np"]),
        "withFgStats": sum(1 for p in PL.values() if p.get("fb") or p.get("fp")),
        "withCareer": sum(1 for p in PL.values() if p.get("cb") or p.get("cp")),
        "onMarket": _avail_n,
        "marketOpenEvents": sum(1 for t in TX if t["opens"] and t["aff"]),
        "on40man": sum(1 for v in AVAIL.values() if v["on40"]),
        "mlbNeedAvg": round(st.mean([len(v) for v in mlb_needs.values()]), 1),
        "farmNeedAvg": round(st.mean([len(v) for v in farm_needs.values()]), 1),
    },
}

# Fold in the backtest if it has been run. Doing this inside the build keeps
# the pipeline idempotent: re-running analyze no longer silently drops the
# Track record tab, which is exactly what happened when this was a side script.
bt_path = (BUILD / "backtest.json")
if bt_path.exists():
    import math
    B = json.loads(bt_path.read_text())
    rows_bt = B["rows"]

    def ztest(n1, k1, n2, k2):
        if not n1 or not n2:
            return 0.0, 1.0
        pp = (k1 + k2) / (n1 + n2)
        se = math.sqrt(pp * (1 - pp) * (1 / n1 + 1 / n2))
        if se == 0:
            return 0.0, 1.0
        z = (k1 / n1 - k2 / n2) / se
        return z, math.erfc(abs(z) / math.sqrt(2))

    ORDER = ["Strong", "Possible", "Further review", "Does not match"]
    OUTS = [("picked", "Picked up within 45 days"),
            ("fast", "Picked up within 7 days"),
            ("claimed", "Claimed off waivers"),
            ("reachedMlb", "Reached an MLB roster within 180 days")]
    table = []
    for field, title in OUTS:
        cells = []
        for lab in ORDER:
            sub = [r for r in rows_bt if r["label"] == lab]
            k = sum(1 for r in sub if r.get(field))
            cells.append({"label": lab, "n": len(sub), "k": k,
                          "rate": round(k / len(sub), 4) if sub else None})
        allk = sum(1 for r in rows_bt if r.get(field))
        st_ = [r for r in rows_bt if r["label"] == "Strong"]
        dn_ = [r for r in rows_bt if r["label"] == "Does not match"]
        _, pv = ztest(len(st_), sum(1 for r in st_ if r.get(field)),
                      len(dn_), sum(1 for r in dn_ if r.get(field)))
        table.append({"outcome": title, "cells": cells,
                      "all": {"n": len(rows_bt), "k": allk,
                              "rate": round(allk / len(rows_bt), 4)},
                      "p": round(pv, 3), "sig": pv < 0.05})
    payload["backtest"] = {
        "table": table, "events": B["events"], "graded": B["graded"],
        "coverage": round(B["graded"] / B["events"], 4),
        "windowDays": B["windowDays"], "minPA": B["minPA"], "minIP": B["minIP"],
        "byEvent": [{"event": e,
                     "n": len([r for r in rows_bt if r["event"] == e]),
                     "rate": round(sum(1 for r in rows_bt if r["event"] == e and r["picked"])
                                   / max(1, len([r for r in rows_bt if r["event"] == e])), 4)}
                    for e in ["Designated for Assignment", "Released", "Declared Free Agency"]],
    }
    print(f"backtest folded in: {B['graded']} graded events")
else:
    print("no backtest.json; Track record tab will be empty")

if SNAP:
    # The availability walk needs the full history, but the page only needs the
    # window. Shipping the whole season put 12 MB into the file.
    _ws = D["window"]["start"]
    payload["txns"] = [t for t in payload["txns"] if t["d"] >= _ws]
    _keep = {t["pid"] for t in payload["txns"] if t["pid"]}
    _keep |= {int(k) for k, v in payload["avail"].items() if v["avail"]}
    payload["avail"] = {k: v for k, v in payload["avail"].items() if int(k) in _keep}
    payload["players"] = {k: v for k, v in payload["players"].items() if int(k) in _keep}
    payload["board"] = [b for b in payload["board"]][:60]
    payload["snapshot"] = True
    payload["asOf"] = _S["asOf"]
    payload["caveat"] = ("Point-in-time rebuild. Transactions, FanGraphs team and player "
                         "rates and the claim clock are all bounded to this date. Minor "
                         "league rates are season totals because the Stats API will not "
                         "bound them by date, so the farm side carries later information.")
    payload.pop("backtest", None)

out = (BUILD / OUT_NAME)
out.write_text(json.dumps(payload, separators=(",", ":")))
print(f"payload {out.stat().st_size/1e6:.2f} MB")
print("MLB need flags per org  avg", payload["audit"]["mlbNeedAvg"],
      "| range", min(len(v) for v in mlb_needs.values()), "-", max(len(v) for v in mlb_needs.values()))
print("Farm need flags per org avg", payload["audit"]["farmNeedAvg"])
print("Pirates MLB needs:", [f"{n['area']} {n['metricFull']} {n['rank']}/{n['n']} z{n['z']}" for n in mlb_needs["Pittsburgh Pirates"]])
print("Pirates farm needs:", [f"{n['area']} {n['metricFull']} {n['rank']}/{n['n']} z{n['z']}" for n in farm_needs["Pittsburgh Pirates"]])
print("audit:", json.dumps(payload["audit"], indent=1))
