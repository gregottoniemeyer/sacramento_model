from pipeline_steps import fetch_rdb_daily, parse_rdb_daily, downsample_minmax, normalize, rolling_variation, write_output

rows = parse_rdb_daily(fetch_rdb_daily("11367500", "2024-07-01", "2025-07-01"))
cfs = [r[1] for r in rows]

print(f"raw points: {len(rows)}")
print(f"min/max cfs: {min(cfs):.0f} / {max(cfs):.0f}")

down = downsample_minmax(cfs, target_n=720)
scale_factor = max(cfs)  # placeholder, same caveat as the others
norm, scaled = normalize(down, scale_factor)
high_var, threshold = rolling_variation(down, window=10)

write_output("mccloud", down, norm, scaled, high_var, scale_factor, threshold, "mccloud_720.txt")
print(f"downsampled to {len(down)} frames, wrote mccloud_720.txt")
print(f"{sum(high_var)} frames flagged high variation")
