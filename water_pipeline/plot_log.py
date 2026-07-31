import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from datetime import date, datetime, timedelta
from pipeline_steps import fetch_rdb, parse_rdb, downsample_lttb

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
lttb_down = downsample_lttb(raw, 720)

n = len(timestamps)
bin_size = n / 720
down_timestamps = [timestamps[min(int(i * bin_size), n - 1)] for i in range(720)]

fig, axes = plt.subplots(2, 1, figsize=(14, 8), sharex=True)

axes[0].plot(down_timestamps, lttb_down, linewidth=1, color="red")
axes[0].set_title("Linear scale")
axes[0].set_ylabel("cfs")

axes[1].plot(down_timestamps, lttb_down, linewidth=1, color="red")
axes[1].set_yscale("log")
axes[1].set_title("Log scale — reveals variation in the quiet months")
axes[1].set_ylabel("cfs (log)")
axes[1].xaxis.set_major_formatter(mdates.DateFormatter("%b %Y"))
axes[1].xaxis.set_major_locator(mdates.MonthLocator())
plt.xticks(rotation=45)

plt.tight_layout()
plt.savefig("log_scale_check.png", dpi=150)
print("saved log_scale_check.png")
