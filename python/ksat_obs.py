#!/usr/bin/env python3
"""Cache NWS observations for a station (default KSAT) into SQLite.

  <script> fetch            # run from cron; idempotent
  <script> show [-n 24]     # latest N rows
  <script> show --since 2026-09-28
  <script> csv > out.csv
  <script>                  # == summary (per-day + range totals)
  <script> summary --table  # classic min/avg/max metrics table

Stdlib only. Source: https://api.weather.gov/stations/<ID>/observations
(the JSON behind the obhistory page; returns ~7 days, not 3).

Storage is canonical UTC; everything displayed (show, summary, csv,
day totals) is in the viewer's local time, and --since/--until are
interpreted as local wall time unless given with an explicit UTC offset
(e.g. 2026-09-28T12:00:00Z).
"""
import argparse
import csv
import datetime
import json
import os
import re
import sqlite3
import sys
import urllib.request

STATION = os.environ.get("KSAT_STATION", "KSAT")
DB = os.environ.get("KSAT_DB", os.path.expanduser("~/ksat_obs.db"))
# NWS asks for an identifying User-Agent; put a real contact here.
UA = os.environ.get("KSAT_UA", "ksat-obs-cache (you@example.com)")
URL = "https://api.weather.gov/stations/%s/observations"

# Single source of truth for the obs table: column names and order.
# DDL and the INSERT statement are generated from this, so a
# schema change happens in exactly one place.
COLUMNS = ["ts", "station", "temp_f", "dewpoint_f", "rh_pct",
           "wind_mph", "gust_mph", "wind_dir_deg", "vis_mi", "pressure_inhg",
           "precip_1h_in", "conditions", "raw_message", "raw_json"]
COL_DEFS = {  # column declarations that aren't plain REAL
    "ts": "TEXT PRIMARY KEY",        # canonical UTC ISO8601, normalized at ingest
    "station": "TEXT NOT NULL",
    "conditions": "TEXT",
    "raw_message": "TEXT",
    "raw_json": "TEXT",
}
SCHEMA = ("CREATE TABLE IF NOT EXISTS obs (\n"
          + ",\n".join(f"  {c} {COL_DEFS.get(c, 'REAL')}" for c in COLUMNS)
          + "\n);")
# Named-column INSERT + guarded upsert. If NWS ever re-issues a record at the
# same timestamp (a COR report, or a "Z" preliminary value later replaced), a
# re-fetch can pick up the new version: ON CONFLICT(ts) updates the row only
# when the stored raw_json differs from the new one (re-fetching an unchanged
# record touches nothing). Numeric fields are COALESCE-protected so a null
# can never wipe out a value already stored; the raw METAR text is only
# replaced by a non-empty one; a row is never taken over by another station.
# Run compare_stale.py before relying on this: whether NWS actually revises
# records here is unconfirmed.
INSERT_SQL = ("INSERT INTO obs (" + ", ".join(COLUMNS) + ") VALUES ("
              + ",".join("?" * len(COLUMNS)) + ") "
              "ON CONFLICT(ts) DO UPDATE SET"
              " station=excluded.station,"
              " temp_f=COALESCE(excluded.temp_f, obs.temp_f),"
              " dewpoint_f=COALESCE(excluded.dewpoint_f, obs.dewpoint_f),"
              " rh_pct=COALESCE(excluded.rh_pct, obs.rh_pct),"
              " wind_mph=COALESCE(excluded.wind_mph, obs.wind_mph),"
              " gust_mph=COALESCE(excluded.gust_mph, obs.gust_mph),"
              " wind_dir_deg=COALESCE(excluded.wind_dir_deg, obs.wind_dir_deg),"
              " vis_mi=COALESCE(excluded.vis_mi, obs.vis_mi),"
              " pressure_inhg=COALESCE(excluded.pressure_inhg, obs.pressure_inhg),"
              " precip_1h_in=COALESCE(excluded.precip_1h_in, obs.precip_1h_in),"
              " conditions=excluded.conditions,"
              " raw_message=COALESCE(NULLIF(excluded.raw_message, ''), obs.raw_message),"
              " raw_json=excluded.raw_json"
              " WHERE excluded.raw_json IS NOT obs.raw_json AND excluded.station = obs.station")

# Columns shown by `show`/`csv` and the (shorter) header printed for them.
SHOW_COLS = ["ts", "temp_f", "dewpoint_f", "rh_pct", "wind_mph", "gust_mph",
             "vis_mi", "pressure_inhg", "precip_1h_in", "conditions"]
HDR = ["ts", "temp_f", "dewpt_f", "rh%", "wind", "gust", "vis", "inHg",
       "precip1h", "conditions"]
# Summary/stats need the display columns minus the free-text conditions.
SUMMARY_COLS = SHOW_COLS[:-1]
# Per-day summary table header (by_local_day view).
DAY_HDR = ["date", "obs", "rain (in)", "temp low", "temp high", "temp avg",
           "dew avg", "RH avg", "wind max", "gust max"]


def log(msg, file=sys.stdout):
    ts = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    print(f"{ts} {msg}", file=file)


def parse_ts(s):
    """Parse an ISO8601 timestamp; .replace() keeps 'Z' working pre-3.11."""
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))


def norm_ts(s):
    """Store every timestamp as canonical UTC, so ordering, filtering and day
    grouping don't depend on the host timezone. NWS returns the timestamp
    with a UTC offset; if it's already UTC this is a no-op, otherwise it
    converts the station-local offset to UTC. US offsets are whole hours, so
    the report minute (e.g. :51) is preserved either way."""
    return parse_ts(s).astimezone(datetime.timezone.utc).isoformat()


def local_ts(s):
    """Render a stored UTC timestamp in the viewer's local time, keeping
    the offset so it stays parseable and unambiguous even when local == UTC."""
    return parse_ts(s).astimezone().isoformat(timespec="seconds")


def resolve_bound(s):
    """Interpret a --since/--until value as viewer-local wall time unless it
    carries an explicit UTC offset; return the comparable canonical-UTC ISO
    string. So '2026-09-28' means local midnight, converted to UTC for the
    WHERE clause."""
    try:
        dt = parse_ts(s)
    except ValueError:
        print(f"error: unrecognized date/time {s!r} "
              "(use a local date or ISO timestamp)", file=sys.stderr)
        sys.exit(2)
    if dt.tzinfo is None:
        dt = dt.astimezone()          # naive -> local wall time
    return dt.astimezone(datetime.timezone.utc).isoformat(timespec="seconds")


def val(p, key):
    """Float value of an NWS property dict ({"value": ...}), or None when
    absent. Non-numeric values are treated as missing rather than crashing
    the whole batch."""
    v = (p.get(key) or {}).get("value")
    if v is None:
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def c2f(c): return None if c is None else round(c * 9 / 5 + 32, 1)
def kmh2mph(k): return None if k is None else round(k * 0.621371, 1)
def m2mi(m): return None if m is None else round(m / 1609.344, 2)
def pa2inhg(pa): return None if pa is None else round(pa / 3386.389, 2)
def mm2in(mm): return None if mm is None else round(mm / 25.4, 2)


def coalesce(*vals):
    """First argument that is not None (None if all are)."""
    for v in vals:
        if v is not None:
            return v
    return None


WIND_RE = re.compile(r"\b(VRB|\d{3})(\d{2,3})(?:G(\d{2,3}))?KT\b")
def kt2mph(k): return round(int(k) * 1.150779, 1)


def metar_wind(raw):
    """(dir_deg, speed_mph, gust_mph) from a METAR string, or None when it
    has no wind group. The API sometimes returns wind fields as null
    (qualityControl "Z") even though the METAR contains them, so the raw
    message is the fallback. Calm wind (00000KT) has no meaningful
    direction, so dir is None."""
    m = WIND_RE.search(raw or "")
    if not m:
        return None
    d, sp, g = m.groups()
    if int(sp) == 0:
        return (None, 0.0, None)
    return (None if d == "VRB" else float(d), kt2mph(sp), kt2mph(g) if g else None)


def row_from_feature(f, station):
    """One obs row per GeoJSON feature; None when the feature lacks a
    timestamp (nothing to key the row on)."""
    p = f["properties"]
    ts = p.get("timestamp")
    if not ts:
        return None
    wdir = val(p, "windDirection")
    wspd = kmh2mph(val(p, "windSpeed"))
    wgust = kmh2mph(val(p, "windGust"))
    # Backfill only the wind fields the API left null; a present API value
    # always wins. (Most rows have no gust, so the parse runs often, but it's
    # a cheap regex and the result is only used to fill nulls.)
    if wdir is None or wspd is None or wgust is None:
        mw = metar_wind(p.get("rawMessage"))
        if mw:
            wdir  = wdir  if wdir  is not None else mw[0]
            wspd  = wspd  if wspd  is not None else mw[1]
            wgust = wgust if wgust is not None else mw[2]
    rh = val(p, "relativeHumidity")
    return (
        norm_ts(ts), station,
        c2f(val(p, "temperature")), c2f(val(p, "dewpoint")),
        round(rh, 1) if rh is not None else None,
        wspd, wgust, wdir,
        m2mi(val(p, "visibility")), pa2inhg(val(p, "barometricPressure")),
        mm2in(val(p, "precipitationLastHour")),
        p.get("textDescription"), p.get("rawMessage"), json.dumps(p),
    )


def store(db, features, station):
    """Insert observations. A row whose ts already exists is updated only if
    its raw_json changed (see INSERT_SQL). Returns (new, updated, seen)."""
    rows = [r for r in (row_from_feature(f, station) for f in features) if r is not None]
    n0 = db.execute("SELECT count(*) FROM obs").fetchone()[0]
    c0 = db.total_changes
    db.executemany(INSERT_SQL, rows)
    db.commit()
    new = db.execute("SELECT count(*) FROM obs").fetchone()[0] - n0
    return new, db.total_changes - c0 - new, len(rows)


def fetch(db):
    req = urllib.request.Request(URL % STATION,
        headers={"User-Agent": UA, "Accept": "application/geo+json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    new, updated, seen = store(db, data.get("features") or [], STATION)
    if seen == 0:
        # A station observed for weeks should never return zero features;
        # treat it as a failure so cron (or you) notices an outage / shape change.
        log(f"{STATION}: fetch returned 0 observations "
            "(API outage or response-shape change?)", sys.stderr)
        sys.exit(1)
    log(f"{STATION}: {seen} fetched, {new} new, {updated} updated")


# Minute of the routine hourly METAR (KSAT reports at :51). Specials arrive at
# other minutes and their precip value is a running accumulation, so rain
# totals and averages only use routine reports. (The minute is unchanged by
# the UTC normalization: US offsets are whole hours.)
ROUTINE_MIN = int(os.environ.get("KSAT_ROUTINE_MIN", "51"))

# Also add the in-progress (partial) hour to rain totals. NWS specials report
# precip "since the last regular METAR", so the newest special with a
# positive value after the newest routine report is the not-yet-completed
# hour's amount (a lower bound; the label shows its as-of time). A trailing
# blank special (a missing value) is skipped in favor of the most
# recent meaningful one. Anchored to the newest routine report regardless of
# its precip, so a special inside an hour a routine already covers is never
# added (that would double-count). Per-day rows stay full-hours-only; the
# overall total picks this up, labeled. Set False to sum complete hours only.
INCLUDE_PARTIAL_HOUR = True


def is_routine(ts):
    return int(ts[14:16]) == ROUTINE_MIN


def where_clause(args):
    """WHERE fragment for --since/--until. Bounds are interpreted in the
    viewer's local time (resolve_bound) and compared lexicographically
    against the stored canonical-UTC ts; --since inclusive, --until
    exclusive, so --since A --until B covers local days A .. B-1."""
    where, params = [], []
    if args.since:
        where.append("ts >= ?"); params.append(resolve_bound(args.since))
    if args.until:
        where.append("ts < ?"); params.append(resolve_bound(args.until))
    return (" WHERE " + " AND ".join(where) if where else ""), params


def query(db, args):
    """Display rows, newest first. -n always applies, on its own or
    combined with --since/--until. Ordering is on the stored UTC ts, which
    is chronological order regardless of local DST transitions."""
    w, params = where_clause(args)
    sql = ("SELECT " + ", ".join(SHOW_COLS) + " FROM obs" + w
           + " ORDER BY ts DESC LIMIT ?")
    params.append(args.n)
    return db.execute(sql, params).fetchall()


def render(hdr, rows, left=(0,)):
    """Print a table with each column as wide as its widest cell."""
    rows = [["" if v is None else str(v) for v in r] for r in rows]
    widths = [max([len(h)] + [len(r[i]) for r in rows]) for i, h in enumerate(hdr)]
    def fmt(cells):
        return "  ".join(c.ljust(w) if i in left else c.rjust(w)
                         for i, (c, w) in enumerate(zip(cells, widths))).rstrip()
    print(fmt(hdr))
    for r in rows:
        print(fmt(r))


def stats(vals, nd=1):
    """(min, avg, max) of the non-None values; (None, None, None) if empty.
    The average is rounded to nd decimals; min/max keep their stored precision."""
    v = [x for x in vals if x is not None]
    return (min(v), round(sum(v) / len(v), nd), max(v)) if v else (None, None, None)


def rain(rows, include_partial=INCLUDE_PARTIAL_HOUR):
    """(total_in, wet_hours, (max_in, ts), partial_in, partial_ts) over the range.

    Sums the complete routine hours: each :51 report's precip is that hour's
    rain, so the sum equals the range total (cross-checkable against the
    official precipitationLast6Hours values in raw_json). When include_partial
    is set, the in-progress hour is also added as a lower bound: everything
    after the newest routine report is a special, and NWS specials report
    rain "since the last regular METAR", so the newest special with a
    positive value is the not-yet-completed hour's amount. (A trailing blank
    special — a value missing for whatever reason — is skipped in favor of
    the most recent meaningful one; the label's timestamp shows where the
    figure stops.) The 'heaviest' (max) is over complete hours only (a
    partial hour's in/h would understate intensity)."""
    vals = [(r[-1], r[0]) for r in rows if is_routine(r[0]) and r[-1] is not None]
    partial_in, partial_ts = 0.0, None
    if include_partial:
        routine_ts = [r[0] for r in rows if is_routine(r[0])]
        if routine_ts:
            latest = max(routine_ts)    # computed once: O(n), not O(n * n)
            withp = [(r[-1], r[0]) for r in rows
                     if r[0] > latest and r[-1] is not None and r[-1] > 0]
        else:
            # No routine hours in range; the newest precip-carrying report
            # stands in for the partial hour (a rough cap on it).
            withp = [(r[-1], r[0]) for r in rows
                     if r[-1] is not None and r[-1] > 0]
        if withp:
            partial_in, partial_ts = max(withp, key=lambda x: x[1])
    if not vals and not partial_in:
        return 0.0, 0, (None, None), 0.0, None
    total = round(sum(v for v, _ in vals) + partial_in, 2)
    wet = sum(1 for v, _ in vals if v > 0) + (1 if partial_in > 0 else 0)
    peak = max(vals) if vals else (partial_in, partial_ts)
    return total, wet, peak, partial_in, partial_ts


def summary(args, db):
    """Banner + either the per-day breakdown (default) or the classic
    min/avg/max metrics table (--table). A missing-hourly-report warning is
    printed only when the hourly record is actually incomplete."""
    w, params = where_clause(args)
    rows = db.execute("SELECT " + ", ".join(SUMMARY_COLS) + " FROM obs" + w
                      + " ORDER BY ts", params).fetchall()
    if not rows:
        print("no observations in that range"); return
    routine = [r for r in rows if is_routine(r[0])]
    print(f"{STATION}  {local_ts(rows[0][0])} .. {local_ts(rows[-1][0])}  (local)")
    if routine:
        # Stored times are canonical UTC, so consecutive hourly reports are
        # always exactly 3600 s apart (DST shifts the *local* wall clock,
        # never the UTC spacing) — the expected count is exact.
        expected = int((parse_ts(routine[-1][0]) - parse_ts(routine[0][0])).total_seconds() // 3600) + 1
        if len(routine) < expected:
            print(f"Warning: {expected - len(routine)} of {expected} hourly "
                  f"reports missing — rain total may be low")
    print()
    if args.table:
        summary_table(rows, routine)
    else:
        by_local_day(rows)


def summary_table(rows, routine):
    """Classic min/avg/max metrics over the range (the pre-by-day view)."""
    metrics = [  # (label, col index in SUMMARY_COLS, show min, show avg, show max, avg decimals)
        ("temp_f", 1, True, True, True, 1),
        ("dewpt_f", 2, True, True, True, 1),
        ("rh%", 3, True, True, True, 1),
        ("wind_mph", 4, True, True, True, 1),
        ("gust_mph", 5, False, False, True, 1),
        ("vis_mi", 6, True, True, True, 2),
        ("inHg", 7, True, True, True, 2),
    ]
    table = []
    for name, i, show_min, show_avg, show_max, nd in metrics:
        lo, _, hi = stats([r[i] for r in rows])          # extremes: every observation
        _, avg, _ = stats([r[i] for r in routine], nd)   # averages: routine reports only
        table.append([name,
                      lo if show_min else "",
                      avg if show_avg else "",
                      hi if show_max else ""])
    render(["", "min", "avg", "max"], table, left=(0,))
    total, wet, (mx, mts), rpartial, rpts = rain(rows)   # honors INCLUDE_PARTIAL_HOUR
    print(f"\nRain: {total:.2f} in over {wet} wet hour(s)"
          + (f"; max {mx} in/h at {local_ts(mts)}" if mx else ""))
    if rpartial:
        print(f"(includes in-progress partial hour +{rpartial:.2f} in, "
              f"as of {local_ts(rpts)})")
    print("min/max use all observations; averages and rain use routine hourly reports only")


def by_local_day(rows):
    """One row per viewer-local day, plus an 'overall' row carrying the
    range totals/averages. Per-day rain uses full hours only (stable); the
    overall row adds the in-progress partial hour when INCLUDE_PARTIAL_HOUR
    is set, labeled below. The heaviest single complete hour is printed
    below the table when present."""
    days = {}
    for r in rows:
        d = parse_ts(r[0]).astimezone().date().isoformat()
        days.setdefault(d, []).append(r)
    routine_all = [r for r in rows if is_routine(r[0])]
    out = []
    for d, rs in days.items():
        routine = [r for r in rs if is_routine(r[0])]
        tmin, _, tmax = stats([r[1] for r in rs])
        out.append([d, len(rs), f"{rain(rs, include_partial=False)[0]:.2f}", tmin, tmax,
                    stats([r[1] for r in routine])[1], stats([r[2] for r in routine])[1],
                    stats([r[3] for r in routine])[1], stats([r[4] for r in rs])[2],
                    stats([r[5] for r in rs])[2]])
    rtotal, _, (rmx, rmts), rpartial, rpts = rain(rows)  # honors INCLUDE_PARTIAL_HOUR
    out.append([""] * len(DAY_HDR))                      # blank line before the overall row
    out.append(["overall", len(rows), f"{rtotal:.2f}",
                stats([r[1] for r in rows])[0], stats([r[1] for r in rows])[2],
                stats([r[1] for r in routine_all])[1], stats([r[2] for r in routine_all])[1],
                stats([r[3] for r in routine_all])[1], stats([r[4] for r in rows])[2],
                stats([r[5] for r in rows])[2]])
    render(DAY_HDR, out)
    if rpartial:
        print(f"\nRain total includes the in-progress hour: +{rpartial:.2f} in "
              f"(as of {local_ts(rpts)}); per-day rows show full hours only")
    if rmx:
        print(f"\nHeaviest {rmx} in/h at {local_ts(rmts)}")


def build_parser():
    rng = argparse.ArgumentParser(add_help=False)  # range options shared by the read commands
    rng.add_argument("--since", metavar="TS",
                     help="inclusive lower bound, local date or timestamp")
    rng.add_argument("--until", metavar="TS",
                     help="exclusive upper bound, local date or timestamp")

    prog = os.path.basename(sys.argv[0])  # so --help examples always match the real name
    examples = [
        (f"{prog} fetch",                      "fetch + store new observations"),
        (f"{prog}",                            "per-day summary of everything stored"),
        (f"{prog} summary --since 2026-09-28", "per-day summary from Sept 28 onward"),
        (f"{prog} summary --table",            "classic min/avg/max metrics table"),
        (f"{prog} show -n 48",                 "48 most recent observations"),
        (f"{prog} show --since 2026-09-28",    "everything since Sept 28"),
        (f"{prog} csv --since 2026-09-28",     "CSV from Sept 28 (pipe to a file)"),
    ]
    width = max(len(cmd) for cmd, _ in examples) + 2
    epilog = ("examples:\n"
              + "\n".join("  " + cmd.ljust(width) + "# " + note
                          for cmd, note in examples))
    ap = argparse.ArgumentParser(
        description="Cache NWS station observations in SQLite",
        epilog=epilog,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=False)  # no subcommand -> default summary

    sub.add_parser("fetch", help="fetch and store new observations (idempotent)")
    s = sub.add_parser("show", parents=[rng],
                       help="print the latest N rows",
                       description="Print the most recent observations, newest first.",
                       epilog="examples:\n"
                              "  show                 # latest 24 rows\n"
                              "  show -n 48           # latest 48 rows\n"
                              "  show --since 2026-09-28   # everything since that date",
                       formatter_class=argparse.RawDescriptionHelpFormatter)
    s.add_argument("-n", type=int, default=24,
                   help="max rows to display, e.g. 'show -n 48' (applies with --since too)")
    sm = sub.add_parser("summary", parents=[rng],
                        help="per-day breakdown + range totals (default view)")
    sm.add_argument("--table", action="store_true",
                    help="classic min/avg/max metrics table instead")
    sub.add_parser("repair", help="fill missing wind from stored raw METAR text")
    c = sub.add_parser("csv", parents=[rng], help="dump rows as CSV")
    c.add_argument("-n", type=int, default=10**9, help="max rows, e.g. 'csv -n 48'")
    return ap


def do_fetch(args, db):
    try:
        fetch(db)
    except SystemExit:
        raise
    except Exception as e:
        log(f"{STATION}: fetch failed: {e}", sys.stderr)
        sys.exit(1)


def do_repair(args, db):
    """Backfill wind fields left null at ingest (quality-control "Z" rows, or
    rows stored before per-field backfill existed). Fills only null fields;
    never overwrites a value that's already present. Counts only rows that
    actually changed, so a re-run with nothing left to fill reports 0."""
    fixed = 0
    for ts, d, sp, g, raw in db.execute(
            "SELECT ts, wind_dir_deg, wind_mph, gust_mph, raw_message FROM obs"
            " WHERE (wind_dir_deg IS NULL OR wind_mph IS NULL OR gust_mph IS NULL)"
            "   AND raw_message IS NOT NULL"):
        mw = metar_wind(raw)
        if not mw:
            continue
        nd, ns, ng = coalesce(d, mw[0]), coalesce(sp, mw[1]), coalesce(g, mw[2])
        if (nd, ns, ng) != (d, sp, g):
            db.execute("UPDATE obs SET wind_dir_deg=?, wind_mph=?, gust_mph=? WHERE ts=?",
                       (nd, ns, ng, ts))
            fixed += 1
    db.commit()
    log(f"{STATION}: repaired wind on {fixed} rows")


def do_show(args, db):
    rows = [(local_ts(r[0]), *r[1:]) for r in query(db, args)]
    render(HDR, rows, left=(0, len(HDR) - 1))
    w, params = where_clause(args)
    total, lo, hi = db.execute("SELECT count(*), min(ts), max(ts) FROM obs" + w,
                               params).fetchone()
    if total:
        print(f"\n{len(rows)} of {total} rows in range; covers "
              f"{local_ts(lo)} .. {local_ts(hi)} (local)")
    else:
        print("\nno rows in that range")


def do_csv(args, db):
    out = csv.writer(sys.stdout)
    out.writerow(HDR)
    out.writerows((local_ts(r[0]), *r[1:]) for r in query(db, args))


def main():
    ap = build_parser()
    args = ap.parse_args()
    if args.cmd is None:            # no subcommand -> run the default summary
        args = ap.parse_args(["summary"])
    db = sqlite3.connect(DB)
    db.executescript(SCHEMA)
    try:
        {"fetch": do_fetch, "repair": do_repair, "show": do_show,
         "summary": summary, "csv": do_csv}[args.cmd](args, db)
    finally:
        db.close()


if __name__ == "__main__":
    main()
