#!/usr/bin/env python3
"""Check Zstd output limits inside compressed blocks without a frame content size.

Usage: python -B archiver/verify_zstd_limits.py --exe GZSTD --zstd ZSTD --out DIR
"""
import argparse
import pathlib
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True)
    parser.add_argument("--zstd", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    exe = str(pathlib.Path(args.exe).resolve())
    ref = str(pathlib.Path(args.zstd).resolve())
    out = pathlib.Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)

    samples = {
        "mixed": (b"alpha-123 beta-456 gamma-789\n" * 700) + b"last literals!",
        "short_offsets": (b"aaabaaaaabaa" * 1800) + b"tail?",
        "long_offsets": bytes(range(251)) * 100 + bytes(range(197)),
    }
    cases = 0
    sentinel = b"destination remains unchanged on failure"
    for name, data in samples.items():
        # stdin makes the frame content size unknown, so limits are enforced
        # while decoding blocks instead of being rejected from the header.
        proc = subprocess.run([ref, "-q", "-3", "-c"], input=data, capture_output=True, check=True)
        frame = proc.stdout
        assert frame[:4] == b"\x28\xb5\x2f\xfd" and frame[4] >> 6 == 0 and not (frame[4] & 0x20), name
        assert frame[4] & 3 == 0, (name, "unexpected dictionary ID")
        assert (frame[6] >> 1) & 3 == 2, (name, "not a compressed block")
        block_size = int.from_bytes(frame[6:9], "little") >> 3
        block = frame[9:9 + block_size]
        kind, fmt = block[0] & 3, (block[0] >> 2) & 3
        if kind <= 1:
            header = 1 if fmt in (0, 2) else 2 if fmt == 1 else 3
            value = int.from_bytes(block[:header], "little")
            length = value >> (3 if header == 1 else 4)
            used = header + (length if kind == 0 else 1)
        else:
            header = 3 if fmt < 2 else 4 if fmt == 2 else 5
            shift = (14, 14, 18, 22)[fmt]
            mask = (1023, 1023, 16383, 262143)[fmt]
            used = header + ((int.from_bytes(block[:header], "little") >> shift) & mask)
        assert used < len(block) and block[used] != 0, (name, "no sequences")
        archive = out / (name + ".zst")
        archive.write_bytes(frame)
        restored = out / (name + ".out")
        limits = sorted({0, 1, 2, 3, 7, 15, 31, 127, 255, 511, 1023,
                         len(data) // 2, len(data) - 2, len(data) - 1,
                         len(data), len(data) + 1})
        for limit in limits:
            restored.write_bytes(sentinel)
            result = subprocess.run([exe, "d", str(archive), str(restored), str(limit)], capture_output=True)
            if limit < len(data):
                assert result.returncode != 0, (name, limit, "accepted")
                assert restored.read_bytes() == sentinel, (name, limit, "output modified")
            else:
                assert result.returncode == 0, (name, limit, result.stderr)
                assert restored.read_bytes() == data, (name, limit, "decoded bytes differ")
            cases += 1
    print(f"{cases} compressed-block output-limit checks passed")


if __name__ == "__main__":
    main()
