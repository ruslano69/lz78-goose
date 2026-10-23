#!/usr/bin/env python3
"""Build the g7z CLI for POSIX hosts (Linux x86_64) from the shared archiver sources.

Goose binds an extern library at program start when any reachable call names it, so the
Windows adapters cannot stay in the Linux build even behind a runtime check. This script
stages the shared sources in a temporary directory, overlays platform/posix/*.goose on
top (same module names, same API), and builds sevenzip_cli.goose from there. The
repository files are never modified.

Usage: python3 build_posix.py --goose PATH/TO/goose --out OUTPUT
"""
import argparse
import pathlib
import shutil
import subprocess
import tempfile

ARCHIVER = pathlib.Path(__file__).resolve().parent.parent
ADAPTERS = ARCHIVER / "platform" / "posix"
ENTRY = "sevenzip_cli.goose"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--goose", required=True, help="path to the goose compiler executable")
    parser.add_argument("--out", required=True, help="output executable path")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="g7z-posix-") as stage_name:
        stage = pathlib.Path(stage_name)
        for source in sorted(ARCHIVER.glob("*.goose")):
            shutil.copy2(source, stage / source.name)
        for adapter in sorted(ADAPTERS.glob("*.goose")):
            shutil.copy2(adapter, stage / adapter.name)
        subprocess.run([args.goose, "build", str(stage / ENTRY), "-o", str(pathlib.Path(args.out).resolve())], check=True)


if __name__ == "__main__":
    main()
