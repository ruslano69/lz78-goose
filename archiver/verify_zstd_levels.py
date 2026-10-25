#!/usr/bin/env python3
"""Interoperability and density check of gzstd compression levels against libzstd.

For every corpus file and level, gzstd compresses, libzstd (Python 3.14 compression.zstd) must restore the
bytes, and gzstd d must restore them as well. Prints the compressed size next to libzstd's at the
comparable level. Exit status 0 only if every round trip is exact.

Usage: python3 archiver/verify_zstd_levels.py --gzstd build/archiver/gzstd.exe --out build/zstd-levels [FILE...]
"""
import argparse
import pathlib
import random
import subprocess
import sys
import time

from compression import zstd


def corpus(files):
    rng = random.Random(11)
    items = {
        "empty": b"",
        "one": b"A",
        "small": b"hello hello hello world, repeated text. " * 4,
        "random": bytes(rng.getrandbits(8) for _ in range(70000)),
        "zeros": bytes(300000),
        "rle_then_words": bytes(131072) + b"alpha beta gamma delta " * 8000 + b"\xff" * 131072,
        "words": " ".join("word%03d" % rng.randrange(256) for _ in range(131072)).encode(),
        "overlap": b"abc" * 100000 + b"xyz" + b"abc" * 5000,
        "far_repeat": bytes(rng.getrandbits(8) for _ in range(300000)) * 2,
    }
    for f in files:
        items[pathlib.Path(f).name] = pathlib.Path(f).read_bytes()
    return items


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gzstd", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--levels", default="1,3,4,5,6,7,8,9,10,11,12,13,15,17,19")
    ap.add_argument("files", nargs="*")
    args = ap.parse_args()
    args.gzstd = str(pathlib.Path(args.gzstd).resolve())
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    levels = [int(x) for x in args.levels.split(",")]
    failed = 0
    print("%-22s %9s %5s %9s %9s %7s %8s" % ("input", "bytes", "lvl", "goose", "libzstd", "ratio", "sec"))
    for name, data in corpus(args.files).items():
        src = out / "in.bin"
        src.write_bytes(data)
        for lv in levels:
            dst = out / "c.zst"
            back = out / "back.bin"
            t = time.perf_counter()
            r = subprocess.run([args.gzstd, "c", str(src), str(dst), str(lv)], capture_output=True)
            sec = time.perf_counter() - t
            if r.returncode != 0:
                print("FAIL encode", name, lv, r.stderr.decode(errors="replace"))
                failed += 1
                continue
            blob = dst.read_bytes()
            try:
                if zstd.decompress(blob) != data:
                    raise ValueError("bytes differ")
            except Exception as e:
                print("FAIL libzstd decode", name, lv, e)
                failed += 1
                continue
            r = subprocess.run([args.gzstd, "d", str(dst), str(back)], capture_output=True)
            if r.returncode != 0 or back.read_bytes() != data:
                print("FAIL gzstd decode", name, lv)
                failed += 1
                continue
            ref = len(zstd.compress(data, level=lv))
            print("%-22s %9d %5d %9d %9d %7.4f %8.3f" % (name, len(data), lv, len(blob), ref, len(blob) / max(1, ref), sec))
    print("failures:", failed)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
