from datetime import date, timedelta
from pipeline_steps import fetch_rdb, parse_rdb, downsample, normalize, rolling_variation, write_output

def fetch_full_range(site_no, start, end, chunk_days=100):
    all_rows = []
    cur = start
    while cur < end:
        chunk_end = min(cur + timedelta(days=chunk_days), end)
        text = fetch_rdb(site_no, cur.isoformat(), chunk_end.isoformat())
        rows = parse_rdb(text)
        print(f"  {cur} to {chunk_end}: {len(rows)} rows")
        all_rows.extend(rows)
        cur = chunk_end
    return all_rows

start = date(2025, 7, 1)
end = date(2026, 7, 1)
rows = fetch_full_range("11376000", start, end)
cfs = [r[1] for r in rows]

print(f"total raw points: {len(rows)}")
print(f"min/max cfs: {min(cfs)} / {max(cfs)}")

down = downsample(cfs, target_n=720)
norm, scaled = normalize(down, scale_factor=30000.0)
high_var, threshold = rolling_variation(down, window=10)

write_output("cottonwood", down, norm, scaled, high_var, 5000.0, threshold, "cottonwood_720.txt")
print(f"downsampled to {len(down)} frames, wrote cottonwood_720.txt")
print(f"{sum(high_var)} frames flagged high variation")
