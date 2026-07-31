import sys
import json
from datetime import date, datetime, timedelta
from pipeline_steps import fetch_rdb, fetch_rdb_daily, fetch_rdb_gauge_height, parse_rdb, parse_rdb_daily

def fetch_full_range(fetch_fn, parse_fn, site_no, start, end, chunk_days=100):
    all_rows = []
    cur = start
    while cur < end:
        chunk_end = min(cur + timedelta(days=chunk_days), end)
        try:
            text = fetch_fn(site_no, cur.isoformat(), chunk_end.isoformat())
            rows = parse_fn(text)
            print(f"  {cur} to {chunk_end}: {len(rows)} rows")
            all_rows.extend(rows)
        except Exception as e:
            print(f"  {cur} to {chunk_end}: FAILED ({e})")
        cur = chunk_end
    return all_rows

SOURCES = {
    "cottonwood":    {"site": "11376000", "fetch": fetch_rdb, "parse": parse_rdb, "start": date(2025,7,1), "end": date(2026,7,1)},
    "mill_creek":    {"site": "11381500", "fetch": fetch_rdb, "parse": parse_rdb, "start": date(2025,7,1), "end": date(2026,7,1)},
    "american":      {"site": "11446500", "fetch": fetch_rdb, "parse": parse_rdb, "start": date(2025,7,1), "end": date(2026,7,1)},
    "mccloud":       {"site": "11367500", "fetch": fetch_rdb_daily, "parse": parse_rdb_daily, "start": date(2024,7,1), "end": date(2025,7,1)},
    "feather":       {"site": "11406920", "fetch": fetch_rdb_daily, "parse": parse_rdb_daily, "start": date(2024,7,1), "end": date(2025,7,1)},
    "shasta":        {"site": "11517500", "fetch": fetch_rdb, "parse": parse_rdb, "start": date(2025,7,1), "end": date(2026,7,1)},
    "delta":         {"site": "11455420", "fetch": fetch_rdb_gauge_height, "parse": parse_rdb, "start": date(2025,7,1), "end": date(2026,7,1)},
}

name = sys.argv[1]
src = SOURCES[name]
print(f"fetching {name} (site {src['site']})...")

try:
    rows = fetch_full_range(src["fetch"], src["parse"], src["site"], src["start"], src["end"])
except Exception as e:
    print(f"FAILED: {e}")
    sys.exit(1)

if not rows:
    print("NO DATA")
    sys.exit(1)

vals = [r[1] for r in rows]
print(f"{len(rows)} points, {min(vals):.2f} - {max(vals):.2f}")

with open(f"cache_{name}.json", "w") as f:
    json.dump(rows, f)
print(f"saved cache_{name}.json")
