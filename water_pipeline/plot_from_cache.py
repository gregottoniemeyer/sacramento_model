import json
import matplotlib.pyplot as plt
from datetime import datetime

CACHE_FILES = [
    ("cottonwood", "Cottonwood Creek", "cfs"),
    ("mill_creek", "Mill Creek", "cfs"),
    ("american", "American River", "cfs"),
    ("mccloud", "McCloud River", "cfs"),
    ("feather", "Feather River (Thermalito)", "cfs"),
    ("shasta", "Shasta River", "cfs"),
    ("delta", "Delta (Rio Vista)", "ft"),
]

results = []
for key, name, unit in CACHE_FILES:
    try:
        with open(f"cache_{key}.json") as f:
            rows = json.load(f)
    except FileNotFoundError:
        print(f"{name}: no cache file, skipping")
        results.append((name, unit, [], []))
        continue
    timestamps = [datetime.strptime(r[0], "%Y-%m-%d %H:%M") if " " in r[0] else datetime.strptime(r[0], "%Y-%m-%d") for r in rows]
    values = [r[1] for r in rows]
    print(f"{name}: {len(rows)} points loaded")
    results.append((name, unit, timestamps, values))

cfs_results = [r for r in results if r[1] == "cfs" and r[3]]
ft_results = [r for r in results if r[1] == "ft"]

all_cfs = [v for _, _, _, vals in cfs_results for v in vals]
y_min, y_max = (min(all_cfs), max(all_cfs)) if all_cfs else (0, 1)

n_plots = len(cfs_results) + len(ft_results)
fig, axes = plt.subplots(n_plots, 1, figsize=(14, 3 * n_plots))
if n_plots == 1:
    axes = [axes]

i = 0
for name, unit, timestamps, values in cfs_results:
    ax = axes[i]
    avg = sum(values) / len(values)
    ax.plot(timestamps, values, linewidth=0.7)
    ax.axhline(avg, color="red", linestyle="--", linewidth=1, label=f"avg = {avg:.0f}")
    ax.set_ylim(y_min, y_max)
    ax.set_title(name, fontsize=10)
    ax.set_ylabel("cfs")
    ax.legend(loc="upper right", fontsize=8)
    i += 1

for name, unit, timestamps, values in ft_results:
    ax = axes[i]
    if values:
        avg = sum(values) / len(values)
        ax.plot(timestamps, values, linewidth=0.7, color="teal")
        ax.axhline(avg, color="red", linestyle="--", linewidth=1, label=f"avg = {avg:.2f} ft")
        ax.legend(loc="upper right", fontsize=8)
    else:
        ax.text(0.5, 0.5, "no data", ha="center", va="center", transform=ax.transAxes)
    ax.set_title(name + " (separate axis -- feet, partial data)", fontsize=10)
    ax.set_ylabel("ft")
    i += 1

plt.tight_layout()
plt.savefig("all_sources_comparison.png", dpi=150)
print("saved all_sources_comparison.png")
