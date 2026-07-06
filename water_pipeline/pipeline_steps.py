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


def downsample_max(values, target_n=720):
    """local max per bin — preserves peak height, but baseline looks noisier/higher"""
    n = len(values)
    if n <= target_n:
        return values[:]
    bin_size = n / target_n
    out = []
    for i in range(target_n):
        start, end = int(i * bin_size), int((i + 1) * bin_size)
        chunk = values[start:max(end, start + 1)]
        out.append(max(chunk))
    return out


def downsample_lttb(values, target_n=720):
    """Largest-Triangle-Three-Buckets — picks the actual raw point per bin
    that best preserves the visual shape of the line"""
    n = len(values)
    if n <= target_n:
        return values[:]

    out = [values[0]]
    bucket_size = (n - 2) / (target_n - 2)
    a = 0  # index of last selected point

    for i in range(target_n - 2):
        # this bucket's range
        start = int((i + 1) * bucket_size) + 1
        end = int((i + 2) * bucket_size) + 1
        end = min(end, n)

        # average point of the NEXT bucket, used as a reference
        next_start = min(end, n - 1)
        next_end = min(int((i + 3) * bucket_size) + 1, n)
        next_end = max(next_end, next_start + 1)
        next_chunk = values[next_start:next_end]
        avg_next = sum(next_chunk) / len(next_chunk)
        avg_next_x = (next_start + next_end) / 2

        best_area = -1
        best_point = values[start]
        ax, ay = a, values[a]

        for j in range(start, end):
            area = abs(
                (ax - avg_next_x) * (values[j] - ay) -
                (ax - j) * (avg_next - ay)
            )
            if area > best_area:
                best_area = area
                best_point = values[j]
                best_idx = j

        out.append(best_point)
        a = best_idx

    out.append(values[-1])
    return out


def downsample_minmax(values, target_n=720):
    n_bins = target_n // 2
    n = len(values)
    bin_size = n / n_bins
    out = []
    for i in range(n_bins):
        start, end = int(i * bin_size), int((i + 1) * bin_size)
        chunk = values[start:max(end, start + 1)]
        lo, hi = min(chunk), max(chunk)
        lo_idx = chunk.index(lo)
        hi_idx = chunk.index(hi)
        if lo_idx <= hi_idx:
            out.extend([lo, hi])
        else:
            out.extend([hi, lo])
    return out
