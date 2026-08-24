# San Francisco Bay tide input

The Delta tide animation uses NOAA CO-OPS station `9414290` (San Francisco,
CA), a primary water-level station at the entrance to San Francisco Bay. The
source product is NOAA's hourly tide prediction in meters relative to MLLW,
GMT, from July 1, 2025 through June 30, 2026.

`build_sf_bay_tide_720.py` validates all 8,760 consecutive hourly predictions,
linearly samples the half-open annual cycle at 720 positions, min-max normalizes
height, and normalizes the centered hourly height derivative to `-1…1`. The
runtime file is `sf_bay_9414290_tide_720.txt`. Positive velocity means a rising
(flooding) tide; negative velocity means a falling (ebbing) tide.

Rebuild from NOAA:

```sh
python3 flow/data/tide/build_sf_bay_tide_720.py
```

API documentation: <https://api.tidesandcurrents.noaa.gov/api/dev>

Station inventory: <https://tidesandcurrents.noaa.gov/inventory.html?id=9414290>
