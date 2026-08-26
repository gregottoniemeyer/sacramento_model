# Basin input data: 2025–2026

This folder replaces river discharge as the Water Council's primary input with
one modeled local-water-arrival signal for each stage. The model year runs from
July 1, 2025 through June 30, 2026 and every Godot file contains exactly 720
uniform samples.

## Source

The raw archive is an unmodified response from the NOAA/NCEI Daily Summaries
Access Data Service. It contains daily precipitation, temperature, snowfall,
and snow-depth fields where each station reports them. The query was:

`https://www.ncei.noaa.gov/access/services/data/v1?dataset=daily-summaries&stations=USC00045983,USC00045449,USW00024216,USC00045679,USC00047195,USW00023225,USW00023237&startDate=2025-07-01&endDate=2026-06-30&format=json&units=metric&includeAttributes=true&includeStationName=true`

NOAA describes the Access Data Service and its station/date subsetting at
<https://www.ncei.noaa.gov/access/search/documentation/data-service/>.

| Stage | NOAA station | Observational role |
|---|---|---|
| Lake Shasta | USC00045983, Mount Shasta | Upper Sacramento rain/snow proxy |
| McCloud-Pit | USC00045449, McCloud | McCloud-Pit rain/snow proxy |
| Cottonwood Creek | USW00024216, Red Bluff | Lower watershed precipitation proxy |
| Mill Creek | USC00045679, Mineral | Upper Mill Creek/Lassen rain/snow proxy |
| Feather River | USC00047195, Quincy | Upper Feather rain/snow proxy |
| American River | USW00023225, Blue Canyon | Upper American precipitation/temperature proxy |
| Delta | USW00023237, Stockton | Local precipitation plus weighted seven-stage aggregate |

These are point-station proxies, not basin-wide gridded estimates. Missing
precipitation is zero-filled after NOAA multiday totals (`MDPR`/`DAPR`) are
distributed across their reporting interval. That choice is explicit in the
notebook and is appropriate for a speculative installation model, but not for
operational allocation or flood forecasting.

## Transformation

1. Frozen precipitation is placed in a modeled snow store instead of entering
   the river immediately.
2. Measured snow-depth decline and a degree-day term release stored water as
   snowmelt. The store caps release, preventing double-counting.
3. A small 0–0.1 mm/day humidity/dew term is estimated from daily minimum and
   mean temperature because these stations do not report a consistent humidity
   series.
4. A separate 0.05 mm/day fog-drip baseline is added after transport. This is a
   conservative conceptual value based on the USGS observation of about 3 mm
   between July 4 and September 15, 1970 in the northern California redwood
   region. Godot redistributes the same daily-equivalent volume into a smooth
   03:00–10:00 morning pulse. It is a speculative basin baseline, not a measured
   value for all seven stations. Source: <https://pubs.usgs.gov/of/1975/0568/report.pdf>.
5. A causal, unit-sum 21-day kernel represents travel through soil and
   tributaries.
6. Each local signal is normalized by its 99th percentile and clipped to 0–1.
7. The Delta uses the documented conceptual weights in
   `build_basin_input_720.py`; the weights are speculative and sum to one.
8. The 365 daily values are linearly resampled to exactly 720 rows.

The second runtime column is now `input_mm_day`, although Godot intentionally
reads it through the unit-neutral `raw_value` field. Existing filenames remain
unchanged for scene compatibility. `water_temperature_kwk_freeport_720.txt` is
not modified by this pipeline.

Run:

```sh
python3 flow/data/basin_input/build_basin_input_720.py
```

Then execute `basin_input_2025_2026.ipynb` to reproduce the tables and plots.
