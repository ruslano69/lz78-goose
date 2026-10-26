#!/usr/bin/env python3
"""Independently check adaptive chain insertion at levels 4..12.

Pass a built gzstd CLI and an installed reference zstd command. Keep artifacts
under --out (normally build/). Includes sparse repeats, late matches, raw/RLE
transitions, block boundaries and a chain-window wrap. Never downloads tools.
"""
import argparse
import hashlib
import json
import pathlib
import random
import subprocess


def corpus():
    rng = random.Random(781)
    noise = rng.randbytes(131072)
    cases = {"random": rng.randbytes(262144),
             "raw_then_matches": noise + b"alpha beta gamma delta " * 7000,
             "matches_then_raw": b"alpha beta gamma delta " * 7000 + noise,
             "raw_rle_raw_matches": noise + bytes(131072) + noise + noise,
             "late_match": rng.randbytes(90000) + b"abcdefgh" * 5000,
             "sparse_islands": b"".join(rng.randbytes(8192) + b"sparse repeat " * 20 for _ in range(20)),
             "chain_wrap": rng.randbytes(4200000) + noise * 2}
    for n in [4095, 4096, 4097, 131071, 131072, 131073]:
        cases["boundary_%d" % n] = rng.randbytes(n) + b"abcdefgh" * 40
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True)
    parser.add_argument("--zstd", required=True)
    parser.add_argument("--checker", help="optional klauspost checker from verify_zstd_go.py")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    exe, ref = str(pathlib.Path(args.exe).resolve()), str(pathlib.Path(args.zstd).resolve())
    out = pathlib.Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    rows = []
    for name, data in corpus().items():
        raw = out / (name + ".bin")
        raw.write_bytes(data)
        for level in range(4, 13):
            frame = out / (name + ".%d.zst" % level)
            independent, native = out / "reference.out", out / "native.out"
            subprocess.run([exe, "c", str(raw), str(frame), str(level)], check=True, capture_output=True)
            subprocess.run([ref, "-q", "-d", "-f", str(frame), "-o", str(independent)], check=True, capture_output=True)
            subprocess.run([exe, "d", str(frame), str(native), str(len(data))], check=True, capture_output=True)
            assert independent.read_bytes() == data, (name, level, "reference")
            assert native.read_bytes() == data, (name, level, "native")
            if args.checker:
                subprocess.run([str(pathlib.Path(args.checker).resolve()), "decode", str(frame), str(raw)],
                               check=True, capture_output=True)
            rows.append(dict(name=name, level=level, size=len(data), packed=frame.stat().st_size,
                             sha256=hashlib.sha256(data).hexdigest()))
        print(name, "levels 4..12 passed", flush=True)
    (out / "report.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
    print(len(rows), "chain cases passed with native/reference decoders" +
          (" and klauspost" if args.checker else ""))


if __name__ == "__main__":
    main()
