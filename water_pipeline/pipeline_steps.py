import urllib.request
import statistics
from pathlib import Path


def fetch_rdb(site_no, begin_date, end_date):
    url = (
        "https://waterservices.usgs.gov/nwis/iv/?format=rdb"
        f"&sites={site_no}&parameterCd=00060"
        f"&startDT={begin_date}&endDT={end_date}"
    )
    req = urllib.request.Request(url, headers={"User-Agent": "sacramento-model/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8")


def parse_rdb(text):
    rows = []
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 6 or parts[0] in ("agency_cd", "5s"):
            continue
        try:
            rows.append((parts[2], float(parts[4])))
        except ValueError:
            continue
    return rows


def downsample(values, target_n=720):
    n = len(values)
    if n <= target_n:
        return values[:]
    bin_size = n / target_n
    out = []
    for i in range(target_n):
        start, end = int(i * bin_size), int((i + 1) * bin_size)
        chunk = values[start:max(end, start + 1)]
        out.append(sum(chunk) / len(chunk))
    return out


def normalize(values, scale_factor, multiplier=200):
    norm = [min(v / scale_factor, 1.0) for v in values]
    scaled = [x * multiplier for x in norm]
    return norm, scaled


def rolling_variation(values, window=10):
    diffs = [0.0] + [abs(values[i] - values[i - 1]) for i in range(1, len(values))]
    local_var = [
        sum(diffs[max(0, i - window + 1):i + 1]) / len(diffs[max(0, i - window + 1):i + 1])
        for i in range(len(diffs))
    ]
    mean = statistics.mean(local_var[window:])
    std = statistics.pstdev(local_var[window:])
    threshold = mean + 2 * std
    return [lv > threshold for lv in local_var], threshold


def write_output(river_name, cfs_values, norm, scaled, high_var, scale_factor, threshold, out_path):
    lines = [f"# river={river_name} scale_factor={scale_factor} threshold={threshold:.3f}"]
    lines.append("frame\tcfs\tnorm\tscaled\thigh_variation")
    for i in range(len(cfs_values)):
        lines.append(f"{i}\t{round(cfs_values[i],1)}\t{round(norm[i],4)}\t{round(scaled[i],2)}\t{int(high_var[i])}")
    Path(out_path).write_text("\n".join(lines))


if __name__ == "__main__":
    # step 6: sanity check with a known spike before wiring to real data
    test_values = [100.0] * 50 + [100.0 + i * 20 for i in range(10)] + [100.0] * 50
    down = downsample(test_values, target_n=len(test_values))
    norm, scaled = normalize(down, scale_factor=500.0)
    high_var, threshold = rolling_variation(down, window=10)
    spike_flags = [i for i, v in enumerate(high_var) if v]
    print(f"threshold={threshold:.3f}")
    print(f"flagged frames: {spike_flags}")
    print("expected flags to cluster around index 50-60 where the spike is")
