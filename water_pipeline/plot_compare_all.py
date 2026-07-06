import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from datetime import date, datetime, timedelta
from pipeline_steps import fetch_rdb, parse_rdb, downsample, downsample_max, downsample_lttb, downsample_minmax

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

mean_down = downsample(raw, 720)
max_down = downsample_max(raw, 720)
lttb_down = downsample_lttb(raw, 720)
minmax_down = downsample_minmax(raw, 720)

n = len(timestamps)

bin_size_720 = n / 720
ts_720 = [timestamps[min(int(i * bin_size_720), n - 1)] for i in range(720)]

bin_size_360 = n / 360
ts_minmax = []
for i in range(360):
    t = timestamps[min(int(i * bin_size_360), n - 1)]
    ts_minmax.extend([t, t])

print(f"raw peak:      {max(raw):.0f}")
print(f"mean-bin peak: {max(mean_down):.0f}")
print(f"max-bin peak:  {max(max_down):.0f}")
print(f"lttb peak:     {max(lttb_down):.0f}")
print(f"minmax peak:   {max(minmax_down):.0f}")

fig, axes = plt.subplots(5, 1, figsize=(14, 15), sharex=True)

axes[0].plot(timestamps, raw, linewidth=0.5)
axes[0].set_title(f"Raw ({len(raw)} points)")

axes[1].plot(ts_720, mean_down, linewidth=1, color="orange")
axes[1].set_title("Mean-bin")

axes[2].plot(ts_720, max_down, linewidth=1, color="green")
axes[2].set_title("Max-bin")

axes[3].plot(ts_720, lttb_down, linewidth=1, color="red")
axes[3].set_title("LTTB")

axes[4].plot(ts_minmax, minmax_down, linewidth=1, color="purple")
axes[4].set_title("Min/Max envelope (360 bins, 720 points)")
axes[4].xaxis.set_major_formatter(mdates.DateFormatter("%b %Y"))
axes[4].xaxis.set_major_locator(mdates.MonthLocator())
plt.xticks(rotation=45)

for ax in axes:
    ax.set_ylabel("cfs")

plt.tight_layout()
plt.savefig("downsample_compare_all.png", dpi=150)
print("saved downsample_compare_all.png")
