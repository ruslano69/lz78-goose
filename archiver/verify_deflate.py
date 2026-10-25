#!/usr/bin/env python3
"""Interoperability check of archiver/gsdeflate.goose against zlib (Python's zlib module).

Builds a small CLI around gsdeflate (its Goose source is embedded here and written to a temporary
directory), then for every corpus case:
  - zlib must restore the bytes from the raw DEFLATE stream that gsdeflate produced;
  - gsdeflate must restore the bytes from the raw DEFLATE streams zlib produced at levels 1, 6 and 9;
  - gsdeflate must restore its own streams.
Exit status 0 only if all pass. The corpus is verify_zstd's, plus inputs that put matches at the
window's edge (distance 32768) and beyond it.

Usage: python3 archiver/verify_deflate.py --goose PATH/TO/goose --out OUTDIR [--archiver DIR]
  --archiver DIR   take gsdeflate.goose from DIR instead of this directory
"""
import argparse
import hashlib
import pathlib
import random
import shutil
import subprocess
import sys
import tempfile
import zlib

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import verify_zstd  # noqa: E402  (shares the corpus)

CLI = '''import std;
import os;
import gsdeflate;

// Usage: dfl c|d SOURCE TARGET
fn main() {
    if arg_count() != 4 { write_stderr("usage: dfl c|d SOURCE TARGET\\n"); exit(2); }
    var mode: u8[>..] = []; arg(1, mode);
    var source: u8[>..] = []; arg(2, source);
    var target: u8[>..] = []; arg(3, target);
    var input: u8[>..] = [];
    if !read_file(source, input) { write_stderr("cannot read input\\n"); exit(1); }
    var output: u8[>..] = [];
    if mode == "c" {
        if !gsdeflate::compress(input, output) { write_stderr("compress failed\\n"); exit(1); }
    } else {
        if !gsdeflate::decompress(input, output) { write_stderr("decompress failed\\n"); exit(1); }
    }
    if !write_file_atomic(target, output) { write_stderr("cannot write output\\n"); exit(1); }
}
'''


def extra_cases():
    """Matches at distance 32768 (the farthest DEFLATE allows) and 32769 (out of reach)."""
    rng = random.Random(3)
    chunk = bytes(rng.getrandbits(8) for _ in range(40))
    filler = lambda n: bytes(rng.getrandbits(8) for _ in range(n))
    return {
        "window_edge": chunk + filler(32768 - 40) + chunk + filler(100),
        "window_past": chunk + filler(32769 - 40) + chunk + filler(100),
        "long_run": b"ab" * 100000,
    }


def run(args, check=True):
    result = subprocess.run(args, capture_output=True, text=True)
    if check and result.returncode:
        raise RuntimeError(" ".join(map(str, args)) + "\n" + result.stderr)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--goose", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--archiver", default=str(HERE))
    args = parser.parse_args()

    out = pathlib.Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    workdir = pathlib.Path(tempfile.mkdtemp(prefix="gsdeflate_"))
    try:
        shutil.copy(pathlib.Path(args.archiver).resolve() / "gsdeflate.goose", workdir / "gsdeflate.goose")
        (workdir / "dfl.goose").write_text(CLI)
        dfl = out / "dfl"
        run([args.goose, "build", str(workdir / "dfl.goose"), "-o", str(dfl)])

        cases = dict(verify_zstd.corpus())
        cases.update(extra_cases())
        failures = 0
        total = 0
        for name, data in cases.items():
            raw = out / (name + ".bin")
            raw.write_bytes(data)
            digest = hashlib.sha256(data).hexdigest()

            ours = out / (name + ".ours.deflate")
            run([str(dfl), "c", str(raw), str(ours)])
            total += 1
            try:
                ok = hashlib.sha256(zlib.decompressobj(-15).decompress(ours.read_bytes())).hexdigest() == digest
            except zlib.error:
                ok = False
            if not ok:
                failures += 1
                print("FAIL zlib cannot read our stream:", name)

            total += 1
            back = out / (name + ".ours.out")
            if back.exists():
                back.unlink()
            result = run([str(dfl), "d", str(ours), str(back)], check=False)
            if result.returncode or hashlib.sha256(back.read_bytes()).hexdigest() != digest:
                failures += 1
                print("FAIL we cannot read our own stream:", name)

            for level in (1, 6, 9):
                total += 1
                packer = zlib.compressobj(level, zlib.DEFLATED, -15)
                theirs = out / (name + ".z%d.deflate" % level)
                theirs.write_bytes(packer.compress(data) + packer.flush())
                back = out / (name + ".z%d.out" % level)
                if back.exists():
                    back.unlink()
                result = run([str(dfl), "d", str(theirs), str(back)], check=False)
                if result.returncode or hashlib.sha256(back.read_bytes()).hexdigest() != digest:
                    failures += 1
                    print("FAIL we cannot read zlib level %d stream: %s" % (level, name))
        print("deflate interoperability: %d checks, %d failures" % (total, failures))
        return 0 if failures == 0 else 1
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
