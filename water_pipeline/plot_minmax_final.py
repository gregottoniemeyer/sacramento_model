import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from datetime import date, datetime, timedelta
from pipeline_steps import fetch_rdb, parse_rdb, downsample_minmax

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

start = date(2025, 7, 1)
end = date(2026, 7, 1)
rows = fetch_full_range("11376000", start, end)

timestamps = [datetime.strptime(r[0], "%Y-%m-%d %H:%M") for r in rows]
raw = [r[1] for r in rows]
minmax_down = downsample_minmax(raw, 720)

n = len(timestamps)
bin_size = n / 360
ts_minmax = []
for i in range(360):
    t = timestamps[min(int(i * bin_size), n - 1)]
    ts_minmax.extend([t, t])

print(f"raw peak:    {max(raw):.0f}")
print(f"minmax peak: {max(minmax_down):.0f}")
print(f"raw points: {len(raw)} -> minmax points: {len(minmax_down)}")

fig, axes = plt.subplots(2, 1, figsize=(14, 8), sharex=True)

axes[0].plot(timestamps, raw, linewidth=0.5)
axes[0].set_title(f"Raw ({len(raw)} points)")
axes[0].set_ylabel("cfs")

axes[1].plot(ts_minmax, minmax_down, linewidth=1, color="purple")
axes[1].set_title("Min/Max envelope -- final method (720 frames)")
axes[1].set_ylabel("cfs")
axes[1].xaxis.set_major_formatter(mdates.DateFormatter("%b %Y"))
axes[1].xaxis.set_major_locator(mdates.MonthLocator())
plt.xticks(rotation=45)

plt.tight_layout()
plt.savefig("minmax_final.png", dpi=150)
print("saved minmax_final.png")
