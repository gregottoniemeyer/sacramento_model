# San Francisco Bay tide input

The Delta tide animation uses NOAA CO-OPS station `9414290` (San Francisco,
CA), a primary water-level station at the entrance to San Francisco Bay. The
source product is NOAA's hourly tide prediction in meters relative to MLLW,
GMT, from July 1, 2025 through June 30, 2026.

`build_sf_bay_tide_hourly.py` retains all 8,760 consecutive hourly predictions,
min-max normalizes height, and normalizes the cyclic centered hourly height
derivative to `-1…1`. It writes the runtime output to
`sf_bay_9414290_tide_hourly_2025_2026.txt`. Positive velocity means a rising
(flooding) tide; negative velocity means a falling (ebbing) tide.

The Delta renders a wrapped 48-hour window synchronized to the shared model
timeline. Current time stays at screen center, with 24 hours of past tide above
and 24 hours of future tide below. The polygon is anchored to the right screen
edge and its left boundary follows the hourly tide profile. It has no boundary
or solid fill; white horizontal 3-pixel hatches with 6-pixel gaps fill its area
at 33% alpha.

Rebuild from NOAA:

```sh
python3 flow/data/tide/build_sf_bay_tide_hourly.py
```

API documentation: <https://api.tidesandcurrents.noaa.gov/api/dev>

Station inventory: <https://tidesandcurrents.noaa.gov/inventory.html?id=9414290>
