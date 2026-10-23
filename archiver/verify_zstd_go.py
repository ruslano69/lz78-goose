#!/usr/bin/env python3
"""Optional interoperability check of archiver/zstd.goose against a second implementation,
klauspost/compress (Go), besides the reference zstd command checked by verify_zstd.py.

A second decoder matters: libzstd accepts some streams that other decoders refuse (a compressed
FSE table that lists a single symbol was one), and only a different implementation finds that.

Builds gzstd from zstd_cli.goose and a small Go checker (the Go source is embedded here and
written to a temporary module; nothing Go is kept in the repository), then, for every corpus case:
  - our frame must decode in klauspost/compress, with DecodeAll and with the streaming reader;
  - a klauspost/compress frame at each encoder level must decode in gzstd.

The check is optional. Without `go`, or when the module cannot be fetched, it prints SKIPPED and
exits 0; --require turns a skip into a failure (exit 2). Exit status 1 means a real mismatch.

Usage: python3 archiver/verify_zstd_go.py --goose PATH/TO/goose --out OUTDIR
         [--go PATH/TO/go] [--module-version v1.20.3] [--go-directive 1.25]
         [--toolchain auto|local] [--archiver DIR] [--require]
  --archiver DIR   take zstd.goose and zstd_cli.goose from DIR instead of this directory
"""
import argparse
import hashlib
import os
import pathlib
import random
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import verify_zstd  # noqa: E402  (shares the corpus)

MODULE = "github.com/klauspost/compress"

GO_SOURCE = r'''package main

import (
	"bytes"
	"fmt"
	"io"
	"os"

	"github.com/klauspost/compress/zstd"
)

func fail(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		fail("usage: decode FILE ORIGINAL | encode LEVEL ORIGINAL OUT")
	}
	switch os.Args[1] {
	case "decode":
		comp, err := os.ReadFile(os.Args[2])
		if err != nil {
			fail("%v", err)
		}
		want, err := os.ReadFile(os.Args[3])
		if err != nil {
			fail("%v", err)
		}
		dec, err := zstd.NewReader(nil, zstd.WithDecoderConcurrency(1))
		if err != nil {
			fail("%v", err)
		}
		got, err := dec.DecodeAll(comp, nil)
		dec.Close()
		if err != nil {
			fail("DecodeAll: %v", err)
		}
		if !bytes.Equal(got, want) {
			fail("DecodeAll: output differs (%d bytes, want %d)", len(got), len(want))
		}
		sr, err := zstd.NewReader(bytes.NewReader(comp), zstd.WithDecoderConcurrency(1))
		if err != nil {
			fail("%v", err)
		}
		streamed, err := io.ReadAll(sr)
		sr.Close()
		if err != nil {
			fail("stream: %v", err)
		}
		if !bytes.Equal(streamed, want) {
			fail("stream: output differs (%d bytes, want %d)", len(streamed), len(want))
		}
	case "encode":
		levels := map[string]zstd.EncoderLevel{
			"fastest": zstd.SpeedFastest, "default": zstd.SpeedDefault,
			"better": zstd.SpeedBetterCompression, "best": zstd.SpeedBestCompression,
		}
		level, ok := levels[os.Args[2]]
		if !ok {
			fail("unknown level %q", os.Args[2])
		}
		orig, err := os.ReadFile(os.Args[3])
		if err != nil {
			fail("%v", err)
		}
		enc, err := zstd.NewWriter(nil, zstd.WithEncoderLevel(level), zstd.WithEncoderConcurrency(1),
			zstd.WithEncoderCRC(true), zstd.WithZeroFrames(true))
		if err != nil {
			fail("%v", err)
		}
		out := enc.EncodeAll(orig, nil)
		enc.Close()
		if err := os.WriteFile(os.Args[4], out, 0o644); err != nil {
			fail("%v", err)
		}
	default:
		fail("unknown command %q", os.Args[1])
	}
}
'''

LEVELS = ["fastest", "default", "better", "best"]


def extra_cases():
    """Inputs of several 128 KiB blocks over a small vocabulary. A block whose sequences all share
    one code made an older encoder write a compressed FSE table listing a single symbol; libzstd
    reads that, klauspost/compress refuses it. verify_zstd's own corpus has no such input."""
    rng = random.Random(7)
    tokens = [b"alpha", b"beta", b"gamma", b" ", b"\n"]
    return {
        "words_2blocks": b"".join(rng.choice(tokens) for _ in range(60000)),
        "words_5blocks": b"".join(rng.choice(tokens) for _ in range(200000)),
    }


def run(args, check=True, env=None, cwd=None, timeout=600):
    result = subprocess.run(args, capture_output=True, text=True, env=env, cwd=cwd, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(" ".join(map(str, args)) + "\n" + result.stderr)
    return result


def skip(message, require):
    print("SKIPPED: " + message)
    return 2 if require else 0


def build_checker(go, version, workdir, go_directive, toolchain):
    src = workdir / "checker"
    src.mkdir()
    (src / "main.go").write_text(GO_SOURCE)
    # The module needs Go 1.25 or newer. With GOTOOLCHAIN=auto (the default here) an older Go
    # downloads the toolchain it needs, as it downloads the module; --toolchain local forbids that
    # and turns an older Go into a skip.
    (src / "go.mod").write_text("module zstdcheck\n\ngo %s\n\nrequire %s %s\n" % (go_directive, MODULE, version))
    env = dict(os.environ, GOFLAGS="-mod=mod", CGO_ENABLED="0", GOTOOLCHAIN=toolchain)
    exe = workdir / "klaus_check"
    run([go, "build", "-o", str(exe), "."], env=env, cwd=str(src))
    return exe


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--goose", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--go", default=shutil.which("go"))
    parser.add_argument("--module-version", default="v1.20.3")
    parser.add_argument("--go-directive", default="1.25", help="go line of the generated module")
    parser.add_argument("--toolchain", default="auto", choices=["auto", "local"], help="GOTOOLCHAIN for the build")
    parser.add_argument("--archiver", default=str(HERE))
    parser.add_argument("--require", action="store_true", help="a skipped check is a failure")
    args = parser.parse_args()

    if not args.go:
        return skip("go not found (use --go)", args.require)
    archiver = pathlib.Path(args.archiver).resolve()
    out = pathlib.Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    workdir = pathlib.Path(tempfile.mkdtemp(prefix="zstd_go_"))
    try:
        try:
            checker = build_checker(args.go, args.module_version, workdir, args.go_directive, args.toolchain)
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
            return skip("cannot build the Go checker (offline or module unavailable?): %s"
                        % str(error).strip().splitlines()[-1][:200], args.require)

        for name in ["zstd.goose", "zstd_cli.goose"]:
            shutil.copy(archiver / name, workdir / name)
        gzstd = out / "gzstd_go"
        run([args.goose, "build", str(workdir / "zstd_cli.goose"), "-o", str(gzstd)])

        # The corpus reads sources from verify_zstd's own directory; the --archiver option only
        # changes which encoder and decoder are checked.
        cases = dict(verify_zstd.corpus())
        cases.update(extra_cases())
        failures = 0
        total = 0
        for name, data in cases.items():
            raw = out / (name + ".bin")
            raw.write_bytes(data)
            digest = hashlib.sha256(data).hexdigest()

            total += 1
            ours = out / (name + ".go.ours.zst")
            run([str(gzstd), "c", str(raw), str(ours)])
            result = run([str(checker), "decode", str(ours), str(raw)], check=False)
            if result.returncode:
                failures += 1
                print("FAIL klauspost cannot read our frame:", name, result.stderr.strip())

            for level in LEVELS:
                total += 1
                theirs = out / (name + "." + level + ".go.zst")
                run([str(checker), "encode", level, str(raw), str(theirs)])
                back = out / (name + "." + level + ".go.out")
                if back.exists():
                    back.unlink()
                result = run([str(gzstd), "d", str(theirs), str(back)], check=False)
                if result.returncode or not back.exists() or hashlib.sha256(back.read_bytes()).hexdigest() != digest:
                    failures += 1
                    print("FAIL we cannot read klauspost frame:", name, level, result.stderr.strip())
        print("klauspost/compress %s interoperability: %d checks, %d failures" % (args.module_version, total, failures))
        return 0 if failures == 0 else 1
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
