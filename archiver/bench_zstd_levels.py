#!/usr/bin/env python3
"""Compression speed of gzstd levels next to libzstd (Python 3.14 compression.zstd).

Our side runs bench_zstd (in-process loop, three warmups, file IO and startup outside the timer);
libzstd is timed in this process the same way. Speeds are decimal MB/s of input, the median of
--batches batches of --iters encodes. Both sides run one thread, one after the other.

Usage: python3 archiver/bench_zstd_levels.py --bench build/archiver/bench_zstd.exe --out build/zstd-bench FILE...
"""
import argparse
import pathlib
import re
import statistics
import subprocess
import time

from compression import zstd


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--levels", default="1,3,4,5,6,7,8,9,10,11,12,13,15,17,19")
    ap.add_argument("--batches", type=int, default=3)
    ap.add_argument("--iters", type=int, default=3)
    ap.add_argument("files", nargs="+")
    args = ap.parse_args()
    bench = str(pathlib.Path(args.bench).resolve())
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    levels = [int(x) for x in args.levels.split(",")]
    for f in args.files:
        path = pathlib.Path(f).resolve()
        data = path.read_bytes()
        print("\n%s (%d bytes)" % (path.name, len(data)))
        print("%5s %10s %10s %8s %10s %10s" % ("lvl", "goose MB/s", "libzstd", "ratio", "goose size", "lib size"))
        for lv in levels:
            ours = []
            size = 0
            for _ in range(args.batches):
                r = subprocess.run([bench, "c", str(path), str(args.iters), str(out / "o.zst"), str(lv)],
                                   capture_output=True, text=True)
                m = re.search(r"output=(\d+).*MB/s=([\d.]+)", r.stdout)
                if r.returncode != 0 or not m:
                    raise SystemExit("bench failed: " + r.stdout + r.stderr)
                size = int(m.group(1))
                ours.append(float(m.group(2)))
            ref = []
            for _ in range(args.batches):
                zstd.compress(data, level=lv)
                t = time.perf_counter()
                for _ in range(args.iters):
                    blob = zstd.compress(data, level=lv)
                ref.append(len(data) * args.iters / (time.perf_counter() - t) / 1e6)
            a, b = statistics.median(ours), statistics.median(ref)
            print("%5d %10.1f %10.1f %8.2f %10d %10d" % (lv, a, b, a / b, size, len(blob)))


if __name__ == "__main__":
    main()
