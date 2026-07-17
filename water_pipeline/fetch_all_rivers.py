from datetime import date, timedelta
from pipeline_steps import fetch_rdb, parse_rdb, downsample_minmax, normalize, rolling_variation, write_output

def fetch_full_range(site_no, start, end, chunk_days=100):
    all_rows = []
    cur = start
    while cur < end:
        chunk_end = min(cur + timedelta(days=chunk_days), end)
        text = fetch_rdb(site_no, cur.isoformat(), chunk_end.isoformat())
        rows = parse_rdb(text)
        all_rows.extend(rows)
        cur = chunk_end
    return all_rows

RIVERS = {
    "cottonwood": {"site": "11376000", "scale_factor": 30000.0},
    "mccloud":    {"site": "11367500", "scale_factor": None},
    "mill_creek": {"site": "11381500", "scale_factor": None},
    "feather":    {"site": "11407000", "scale_factor": None},
    "american":   {"site": "11446500", "scale_factor": None},
}

start = date(2025, 7, 1)
end = date(2026, 7, 1)

for name, cfg in RIVERS.items():
    print(f"\nfetching {name} (site {cfg['site']})...")
    rows = fetch_full_range(cfg["site"], start, end)
    cfs = [r[1] for r in rows]

    if not cfs:
        print(f"  NO DATA -- skipping {name}, check site number or date range")
        continue

    scale_factor = cfg["scale_factor"] or max(cfs)
    down = downsample_minmax(cfs, target_n=720)
    norm, scaled = normalize(down, scale_factor)
    high_var, threshold = rolling_variation(down, window=10)

    write_output(name, down, norm, scaled, high_var, scale_factor, threshold, f"{name}_720.txt")
    print(f"  {len(rows)} raw points -> 720 frames")
    print(f"  min/max cfs: {min(cfs):.0f} / {max(cfs):.0f}")
    print(f"  scale_factor used: {scale_factor}")
    print(f"  {sum(high_var)} frames flagged high variation")
