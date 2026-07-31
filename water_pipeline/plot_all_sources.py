import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from datetime import date, datetime, timedelta
from pipeline_steps import fetch_rdb, fetch_rdb_daily, fetch_rdb_gauge_height, parse_rdb, parse_rdb_daily

def fetch_full_range(fetch_fn, parse_fn, site_no, start, end, chunk_days=100):
    all_rows = []
    cur = start
    while cur < end:
        chunk_end = min(cur + timedelta(days=chunk_days), end)
        text = fetch_fn(site_no, cur.isoformat(), chunk_end.isoformat())
        all_rows.extend(parse_fn(text))
        cur = chunk_end
    return all_rows

SOURCES = [
    {"name": "Cottonwood Creek", "site": "11376000", "fetch": fetch_rdb, "parse": parse_rdb,
     "start": date(2025,7,1), "end": date(2026,7,1)},
    {"name": "Mill Creek", "site": "11381500", "fetch": fetch_rdb, "parse": parse_rdb,
     "start": date(2025,7,1), "end": date(2026,7,1)},
    {"name": "American River", "site": "11446500", "fetch": fetch_rdb, "parse": parse_rdb,
     "start": date(2025,7,1), "end": date(2026,7,1)},
    {"name": "McCloud River", "site": "11367500", "fetch": fetch_rdb_daily, "parse": parse_rdb_daily,
     "start": date(2024,7,1), "end": date(2025,7,1)},
    {"name": "Feather River (Thermalito)", "site": "11406920", "fetch": fetch_rdb_daily, "parse": parse_rdb_daily,
     "start": date(2024,7,1), "end": date(2025,7,1)},
    {"name": "Shasta River", "site": "11517500", "fetch": fetch_rdb, "parse": parse_rdb,
     "start": date(2025,7,1), "end": date(2026,7,1)},
    {"name": "Delta (Rio Vista) - gauge ft", "site": "11455420", "fetch": fetch_rdb_gauge_height, "parse": parse_rdb,
     "start": date(2025,7,1), "end": date(2026,7,1)},
]

results = []
for src in SOURCES:
    print(f"fetching {src['name']}...")
    try:
        rows = fetch_full_range(src["fetch"], src["parse"], src["site"], src["start"], src["end"])
    except Exception as e:
        print(f"  FAILED: {e}")
        results.append((src["name"], [], []))
        continue
    if not rows:
        print(f"  NO DATA")
        results.append((src["name"], [], []))
        continue
    timestamps = [datetime.strptime(r[0], "%Y-%m-%d %H:%M") if " " in r[0] else datetime.strptime(r[0], "%Y-%m-%d") for r in rows]
    values = [r[1] for r in rows]
    print(f"  {len(rows)} points, {min(values):.1f} - {max(values):.1f}")
    results.append((src["name"], timestamps, values))

# shared y-axis across ALL sources (note: Delta is in feet, not cfs -- different unit,
# so it's plotted separately at the bottom rather than sharing the cfs axis)
cfs_sources = [r for r in results if "Delta" not in r[0]]
delta_source = [r for r in results if "Delta" in r[0]][0]

all_cfs_values = [v for _, _, vals in cfs_sources for v in vals]
y_min, y_max = min(all_cfs_values), max(all_cfs_values)

fig, axes = plt.subplots(len(cfs_sources) + 1, 1, figsize=(14, 3 * (len(cfs_sources) + 1)), sharex=False)

for i, (name, timestamps, values) in enumerate(cfs_sources):
    ax = axes[i]
    if values:
        avg = sum(values) / len(values)
        ax.plot(timestamps, values, linewidth=0.7)
        ax.axhline(avg, color="red", linestyle="--", linewidth=1, label=f"avg = {avg:.0f}")
        ax.legend(loc="upper right", fontsize=8)
    ax.set_ylim(y_min, y_max)
    ax.set_title(name, fontsize=10)
    ax.set_ylabel("cfs")

# delta on its own axis, different unit (feet)
ax = axes[-1]
name, timestamps, values = delta_source
if values:
    avg = sum(values) / len(values)
    ax.plot(timestamps, values, linewidth=0.7, color="teal")
    ax.axhline(avg, color="red", linestyle="--", linewidth=1, label=f"avg = {avg:.2f} ft")
    ax.legend(loc="upper right", fontsize=8)
    ax.set_ylabel("ft")
else:
    ax.text(0.5, 0.5, "Delta data unavailable (USGS service error)", ha="center", va="center", transform=ax.transAxes)
ax.set_title(name + " (separate axis -- feet, not cfs)", fontsize=10)

plt.tight_layout()
plt.savefig("all_sources_comparison.png", dpi=150)
print("\nsaved all_sources_comparison.png")
