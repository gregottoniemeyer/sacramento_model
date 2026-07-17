import time
from datetime import date, timedelta
from pipeline_steps import fetch_rdb_gauge_height, parse_rdb, downsample_minmax, normalize, rolling_variation, write_output

def fetch_full_range_gauge(site_no, start, end, chunk_days=100):
    all_rows = []
    cur = start
    while cur < end:
        chunk_end = min(cur + timedelta(days=chunk_days), end)
        for attempt in range(3):
            try:
                text = fetch_rdb_gauge_height(site_no, cur.isoformat(), chunk_end.isoformat())
                rows = parse_rdb(text)
                break
            except Exception as e:
                print(f"  attempt {attempt+1} failed: {e}")
                time.sleep(5)
        else:
            rows = []
        print(f"  {cur} to {chunk_end}: {len(rows)} rows")
        all_rows.extend(rows)
        cur = chunk_end
        time.sleep(2)
    return all_rows

start = date(2025, 7, 1)
end = date(2026, 7, 1)
rows = fetch_full_range_gauge("11455420", start, end)
gauge_ft = [r[1] for r in rows]

print(f"total raw points: {len(rows)}")
print(f"min/max gauge height: {min(gauge_ft):.2f} / {max(gauge_ft):.2f} ft")

down = downsample_minmax(gauge_ft, target_n=720)
scale_factor = max(gauge_ft)  # placeholder, same caveat as the rivers
norm, scaled = normalize(down, scale_factor)
high_var, threshold = rolling_variation(down, window=10)

write_output("delta", down, norm, scaled, high_var, scale_factor, threshold, "delta_720.txt")
print(f"downsampled to {len(down)} frames, wrote delta_720.txt")
print(f"{sum(high_var)} frames flagged high variation")
