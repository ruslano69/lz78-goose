#!/usr/bin/env python3
"""Text matching and grouped sequence-bitstream interoperability checks.

Uses a caller-supplied gzstd and reference zstd; no downloads. Optional --bench
checks fresh/reused fast encoders, --before-bench checks unchanged sequence
encoding at levels >=4, and --checker adds the klauspost checker protocol.
"""
import argparse
import hashlib
import json
import pathlib
import random
import subprocess


def corpus():
    rng = random.Random(781)
    words = [("word%03d " % k).encode() for k in range(256)]
    cases = {
        "words": b"".join(rng.choices(words, k=8192)),
        "utf8": ("Текст українською. Русский текст. Repeat words and offsets.\n" * 200).encode(),
        "prefixes": b"".join(b"common prefix " + bytes([k]) + b" another phrase " for k in range(256)) * 3,
        "empty": b"",
        "short": b"a long phrase a long phrase a long phrase",
    }
    # Large literal/match lengths and distant offsets exercise >32-bit groups,
    # while ordinary words exercise packed groups and RLE/predefined FSE modes.
    noise = rng.randbytes(70000)
    cases["wide_fields"] = b"ab" * 32 + noise + b"xy" * 28000 + noise + b"xy" * 28000
    cases["raw_then_words"] = rng.randbytes(131072) + cases["words"] * 3
    for n in [7, 16, 17, 131071, 131072, 131073]:
        cases["tail_%d" % n] = (b"abcdefgh common phrase " * (n // 23 + 1))[:n]
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True)
    parser.add_argument("--zstd", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--bench")
    parser.add_argument("--before-bench")
    parser.add_argument("--checker")
    args = parser.parse_args()
    exe, ref = str(pathlib.Path(args.exe).resolve()), str(pathlib.Path(args.zstd).resolve())
    out = pathlib.Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    rows = []

    def run(command):
        subprocess.run([str(x) for x in command], check=True, capture_output=True)

    for name, data in corpus().items():
        raw = out / (name + ".bin")
        raw.write_bytes(data)
        levels = [1, 2, 3, 6, 12] if len(data) > 65536 else [1, 2, 3, 6, 12, 19]
        for level in levels:
            frame = out / (name + ".%d.zst" % level)
            run([exe, "c", raw, frame, level])
            restored = out / "reference.out"
            run([ref, "-q", "-d", "-f", frame, "-o", restored])
            assert restored.read_bytes() == data, (name, level, "reference")
            run([exe, "d", frame, restored, len(data)])
            assert restored.read_bytes() == data, (name, level, "native")
            if args.checker:
                run([pathlib.Path(args.checker).resolve(), "decode", frame, raw])
            if args.bench and level <= 3:
                reused = out / "reused.zst"
                run([pathlib.Path(args.bench).resolve(), "reuse", raw, 1, reused, level])
                assert reused.read_bytes() == frame.read_bytes(), (name, level, "reused")
            if args.before_bench and level >= 4:
                before = out / "before.zst"
                run([pathlib.Path(args.before_bench).resolve(), "c", raw, 1, before, level])
                assert before.read_bytes() == frame.read_bytes(), (name, level, "sequence bits changed")
            rows.append(dict(name=name, level=level, bytes=len(data), packed=frame.stat().st_size,
                             sha256=hashlib.sha256(data).hexdigest()))
        print(name, "passed", flush=True)
    (out / "report.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
    print(len(rows), "text/sequence cases passed")


if __name__ == "__main__":
    main()
