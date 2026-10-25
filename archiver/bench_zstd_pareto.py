#!/usr/bin/env python3
"""Size/time Pareto curves of gzstd levels against libzstd (Python 3.14 compression.zstd).

Both sides run in process (ours through bench_zstd: three warmups, IO and startup outside the timer),
one thread, one after the other. For every input the script writes the points to JSON and prints, for
each of our levels, libzstd's best size at our speed (log-linear interpolation along libzstd's own
frontier) so that "ahead" means: smaller output than libzstd achieves at that speed.

Usage: python3 archiver/bench_zstd_pareto.py --bench build/archiver/bench_clang.exe --out build/zstd-pareto FILE...
"""
import argparse
import json
import math
import pathlib
import re
import statistics
import subprocess
import time

from compression import zstd


def frontier(points):
    """Points (speed, size) not beaten by another that is at least as fast and as small."""
    keep = []
    for p in points:
        if not any(q[0] >= p[0] and q[1] <= p[1] and (q[0] > p[0] or q[1] < p[1]) for q in points):
            keep.append(p)
    return sorted(keep)


def lib_size_at(front, speed):
    """Smallest size libzstd reaches at `speed` MB/s, interpolated between neighbours of its frontier
    (speed falls as size falls). None outside the range it covers."""
    pts = sorted(front)  # ascending speed, descending size
    if speed < pts[0][0] or speed > pts[-1][0]:
        return None
    for (s0, z0), (s1, z1) in zip(pts, pts[1:]):
        if s0 <= speed <= s1:
            if s1 == s0:
                return min(z0, z1)
            t = (math.log(speed) - math.log(s0)) / (math.log(s1) - math.log(s0))
            return z0 + t * (z1 - z0)
    return pts[-1][1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--batches", type=int, default=3)
    ap.add_argument("--iters", type=int, default=2)
    ap.add_argument("files", nargs="+")
    args = ap.parse_args()
    bench = str(pathlib.Path(args.bench).resolve())
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    ours_levels = list(range(1, 20))
    lib_levels = list(range(-5, 0)) + list(range(1, 23))
    result = {}
    for f in args.files:
        path = pathlib.Path(f).resolve()
        data = path.read_bytes()
        ours, lib = [], []
        for lv in ours_levels:
            speeds, size = [], 0
            for _ in range(args.batches):
                r = subprocess.run([bench, "c", str(path), str(args.iters), str(out / "o.zst"), str(lv)],
                                   capture_output=True, text=True)
                m = re.search(r"output=(\d+).*MB/s=([\d.]+)", r.stdout)
                if r.returncode != 0 or not m:
                    raise SystemExit("bench failed: " + r.stdout + r.stderr)
                size = int(m.group(1))
                speeds.append(float(m.group(2)))
            ours.append((lv, statistics.median(speeds), size))
        for lv in lib_levels:
            speeds, size = [], 0
            for _ in range(args.batches):
                zstd.compress(data, level=lv)
                t = time.perf_counter()
                for _ in range(args.iters):
                    blob = zstd.compress(data, level=lv)
                speeds.append(len(data) * args.iters / (time.perf_counter() - t) / 1e6)
                size = len(blob)
            lib.append((lv, statistics.median(speeds), size))
        result[path.name] = {"bytes": len(data), "ours": ours, "lib": lib}
        lf = frontier([(s, z) for _, s, z in lib])
        print("\n%s (%d bytes)" % (path.name, len(data)))
        print("%5s %9s %9s | %-26s %8s" % ("lvl", "MB/s", "size", "libzstd best at this speed", "ours/lib"))
        for lv, s, z in ours:
            ref = lib_size_at(lf, s)
            if ref is None:
                note = "(outside libzstd's range)"
                print("%5d %9.1f %9d | %-26s %8s" % (lv, s, z, note, ""))
            else:
                print("%5d %9.1f %9d | %-26d %8.4f" % (lv, s, z, ref, z / ref))
    (out / "pareto.json").write_text(json.dumps(result, indent=1))


if __name__ == "__main__":
    main()
