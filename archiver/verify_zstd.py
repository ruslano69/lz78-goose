#!/usr/bin/env python3
"""Interoperability check of archiver/zstd.goose against the reference zstd command.

Builds gzstd from zstd_cli.goose, then for every corpus file and level:
  - the reference `zstd -d` must restore the bytes that gzstd compressed (encoder check);
  - gzstd must restore the bytes that the reference `zstd` compressed (decoder check).
Checks run on skippable-frame and multi-frame streams too. Hand-built frames then check what a
decoder of untrusted input must refuse: an output past the caller's limit, a block over 128 KiB, and a
Frame_Content_Size that is not the decoded size. Exit status 0 only if all pass.

Usage: python3 archiver/verify_zstd.py --goose PATH/TO/goose --zstd PATH/TO/zstd --out OUTDIR
"""
import argparse
import hashlib
import os
import pathlib
import random
import shutil
import struct
import subprocess
import sys
import tempfile

ARCHIVER = pathlib.Path(__file__).resolve().parent


def corpus():
    rng = random.Random(7)
    items = {
        "empty": b"",
        "one": b"A",
        "small": b"hello hello hello world, repeated text. " * 4,
        "random": bytes(rng.getrandbits(8) for _ in range(70000)),
        "zeros": bytes(300000),
        "uniform_short": b"\xff" * 7,
        "uniform_word_tail": b"\x80" * 135,
        "uniform_crossblock": b"\xff" * 262145,
        "rle_then_words": bytes(131072) + b"alpha beta gamma delta " * 8000 + b"\xff" * 131072,
        "match_word_edges": b"".join(
            bytes(range(32)) + bytes(range(k)) + b"\xff" + bytes(range(k, 32))
            for k in range(17)
        ) * 70,
        "match_block_tails": b"abcdefgh" * 16384 + b"abcdefgX" + b"abcdefgh" * 16384 + b"abc",
        "words": b"".join(rng.choice([b"alpha", b"beta", b"gamma", b" ", b"\n"]) for _ in range(40000)),
    }
    text = b"".join((ARCHIVER / name).read_bytes() for name in ["zstd.goose", "sevenzip.goose", "gsbzip2.goose"])
    items["sources"] = text
    items["sources_x3"] = text * 3
    return items


def block(kind, size, last, payload=b""):
    """Block_Header (last flag, type, size) followed by the payload."""
    return struct.pack("<I", last | (kind << 1) | (size << 3))[:3] + payload


def frame(fcs, blocks, fcs_flag=3):
    """Single-segment frame without checksum; fcs is the declared Frame_Content_Size."""
    width = {0: 1, 1: 2, 2: 4, 3: 8}[fcs_flag]
    value = fcs - 256 if fcs_flag == 1 else fcs
    return b"\x28\xb5\x2f\xfd" + bytes([(fcs_flag << 6) | 0x20]) + value.to_bytes(width, "little") + b"".join(blocks)


def hostile_cases():
    """(name, frame bytes, decode limit or None, must be accepted)."""
    rle = lambda size, last, byte=b"A": block(1, size, last, byte)
    sizes = 131072
    return [
        ("exact content size", frame(3 * sizes, [rle(sizes, 0), rle(sizes, 0), rle(sizes, 1)]), None, True),
        ("two-byte content size", frame(300, [rle(300, 1)], fcs_flag=1), None, True),
        ("limit equal to output", frame(3 * sizes, [rle(sizes, 0), rle(sizes, 0), rle(sizes, 1)]), 3 * sizes, True),
        ("100 RLE blocks over the limit", frame(100 * sizes, [rle(sizes, 0)] * 99 + [rle(sizes, 1)]), 1000000, False),
        ("RLE block of 2 MB", frame(2000000, [rle(2000000, 1)]), None, False),
        ("raw block of 128 KiB + 1", frame(sizes + 1, [block(0, sizes + 1, 1, b"x" * (sizes + 1))]), None, False),
        ("content size below the output", frame(5, [rle(100, 1)]), None, False),
        ("content size above the output", frame(200, [rle(100, 1)]), None, False),
        ("content size with the top bit set", frame(2 ** 63 + 5, [rle(10, 1)]), None, False),
        ("content size above the limit", frame(10 ** 12, [rle(10, 1)]), 1000, False),
        ("two frames over the limit", frame(600000, [rle(sizes, 0)] * 4 + [rle(600000 - 4 * sizes, 1)]) * 2, 1000000, False),
    ]


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
    with_temp = pathlib.Path(tempfile.mkdtemp(prefix="zstd_"))
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
        for name, data, limit, accepted in hostile_cases():
            total += 1
            crafted = out / "hostile.zst"
            crafted.write_bytes(data)
            result_file = out / "hostile.out"
            if result_file.exists():
                result_file.unlink()
            command = [str(gzstd), "d", str(crafted), str(result_file)] + ([str(limit)] if limit is not None else [])
            result = run(command, check=False)
            if (result.returncode == 0) != accepted:
                failures += 1
                print("FAIL %s: %s" % ("refused" if accepted else "accepted", name))
        print("zstd interoperability: %d checks, %d failures" % (total, failures))
        return 0 if failures == 0 else 1
    finally:
        shutil.rmtree(with_temp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
