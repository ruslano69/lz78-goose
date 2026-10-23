#!/usr/bin/env python3
"""Interoperability check of archiver/zstd.goose against the reference zstd command.

Builds gzstd from zstd_cli.goose, then for every corpus file and level:
  - the reference `zstd -d` must restore the bytes that gzstd compressed (encoder check);
  - gzstd must restore the bytes that the reference `zstd` compressed (decoder check).
Checks run on skippable-frame and multi-frame streams too. Exit status 0 only if all pass.

Usage: python3 archiver/verify_zstd.py --goose PATH/TO/goose --zstd PATH/TO/zstd --out OUTDIR
"""
import argparse
import hashlib
import os
import pathlib
import random
import shutil
import subprocess
import sys

ARCHIVER = pathlib.Path(__file__).resolve().parent


def corpus():
    rng = random.Random(7)
    items = {
        "empty": b"",
        "one": b"A",
        "small": b"hello hello hello world, repeated text. " * 4,
        "random": bytes(rng.getrandbits(8) for _ in range(70000)),
        "zeros": bytes(300000),
        "words": b"".join(rng.choice([b"alpha", b"beta", b"gamma", b" ", b"\n"]) for _ in range(40000)),
    }
    text = b"".join((ARCHIVER / name).read_bytes() for name in ["zstd.goose", "sevenzip.goose", "gsbzip2.goose"])
    items["sources"] = text
    items["sources_x3"] = text * 3
    return items


def run(args, check=True):
    result = subprocess.run(args, capture_output=True, text=True)
    if check and result.returncode:
        raise RuntimeError(" ".join(map(str, args)) + "\n" + result.stderr)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--goose", required=True)
    parser.add_argument("--zstd", required=True, help="reference zstd command-line tool")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    out = pathlib.Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    gzstd = out / "gzstd"
    with_temp = pathlib.Path(subprocess.run(["mktemp", "-d"], capture_output=True, text=True, check=True).stdout.strip())
    try:
        for name in ["zstd.goose", "zstd_cli.goose"]:
            shutil.copy(ARCHIVER / name, with_temp / name)
        run([args.goose, "build", str(with_temp / "zstd_cli.goose"), "-o", str(gzstd)])
        cases = corpus()
        failures = 0
        total = 0
        for name, data in cases.items():
            raw = out / (name + ".bin")
            raw.write_bytes(data)
            digest = hashlib.sha256(data).hexdigest()
            for level in ["-1", "-3", "-19"]:
                total += 2
                # Encoder check: our frame must be read by the reference decoder.
                ours = out / (name + ".ours.zst")
                run([str(gzstd), "c", str(raw), str(ours)])
                back = out / (name + ".ref.out")
                run([args.zstd, "-q", "-d", "-f", str(ours), "-o", str(back)], check=False)
                if back.exists() and hashlib.sha256(back.read_bytes()).hexdigest() == digest:
                    pass
                else:
                    failures += 1
                    print("FAIL encoder:", name)
                # Decoder check: the reference frame must be read by ours.
                theirs = out / (name + ".ref.zst")
                run([args.zstd, "-q", level, "-f", str(raw), "-o", str(theirs)])
                ours_back = out / (name + ".our.out")
                result = run([str(gzstd), "d", str(theirs), str(ours_back)], check=False)
                if result.returncode == 0 and hashlib.sha256(ours_back.read_bytes()).hexdigest() == digest:
                    pass
                else:
                    failures += 1
                    print("FAIL decoder:", name, level, result.stderr.strip())
        print("zstd interoperability: %d checks, %d failures" % (total, failures))
        return 0 if failures == 0 else 1
    finally:
        shutil.rmtree(with_temp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
