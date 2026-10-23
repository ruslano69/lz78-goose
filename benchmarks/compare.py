"""Paired native LZ78 timings. Run from the package root after building drivers."""
import argparse
import hashlib
import json
import pathlib
import platform
import random
import statistics
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "test"))
from verify import encode, checksum


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--rounds", type=int, default=15)
    ap.add_argument("--work", default="build/c-comparison")
    args = ap.parse_args()
    if args.rounds < 5:
        ap.error("use at least five measured pairs")
    work = pathlib.Path(args.work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    size = 1024 * 1024
    rng = random.Random(780023)
    source = (ROOT / "lz78.goose").read_bytes()
    text = "Goose learns LZ78. Привіт! abracadabra\n".encode()
    data = {"repeat": b"A" * size, "text": (text * (size // len(text) + 1))[:size],
            "source": (source * (size // len(source) + 1))[:size], "random": rng.randbytes(size)}
    goose = ROOT / "build/goose-bench.exe"
    c = ROOT / "build/lz78-c.exe"
    apps = {"goose": ROOT / "build/lz78.exe", "c": c,
            "classic": ROOT / "build/lz78-c-classic.exe"}
    rows, inputs = [], []

    def run(command):
        p = subprocess.run([str(x) for x in command], capture_output=True, encoding="utf-8")
        if p.returncode:
            raise RuntimeError(p.stdout + p.stderr)
        return p.stdout

    for case, original in data.items():
        raw, packed = work / (case + ".bin"), work / (case + ".lz78")
        archive, _ = encode(original)
        raw.write_bytes(original)
        packed.write_bytes(archive)
        inputs.append({"case": case, "original_bytes": len(original), "archive_bytes": len(archive),
                       "sha256": hashlib.sha256(original).hexdigest(),
                       "archive_sha256": hashlib.sha256(archive).hexdigest()})
        # Full byte equality outside timing, on the exact measured data.
        for name, app in apps.items():
            target = work / (case + ".check")
            run([app, "c", raw, target])
            assert target.read_bytes() == archive, (case, name, "encode")
            run([app, "d", packed, target])
            assert target.read_bytes() == original, (case, name, "decode")

        for mode, inp, expected in [("c", raw, archive), ("d", packed, original)]:
            variants = {"Goose": [goose, mode, inp, "3"],
                        "C ranges": [c, "--bench", mode, inp, "3"]}
            if mode == "d":
                variants["C parents"] = [c, "--bench", "p", inp, "3"]
            samples = {v: [] for v in variants}
            digest = checksum(expected)
            for iteration in range(args.rounds):
                order = list(variants)
                rng.shuffle(order)
                for variant in order:
                    lines = [s.split() for s in run(variants[variant]).splitlines() if s.startswith("BENCH ")]
                    assert len(lines) == 3
                    for _, elapsed, length, actual_sum in lines:
                        assert int(length) == len(expected) and int(actual_sum) == digest, (case,variant)
                    # Two warmups, then one measured codec sample, in each process.
                    samples[variant].append(int(lines[-1][1]))
            medians = {v: statistics.median(ns) / 1e6 for v,ns in samples.items()}
            rows.append({"case": case, "mode": mode, "median_ms": medians,
                         "samples_ns": samples,
                         "ranges_ms": {v:[min(ns)/1e6,max(ns)/1e6] for v,ns in samples.items()}})
            print(case, mode, medians, flush=True)
    paths = [goose, c, *apps.values(), ROOT / "lz78.goose", pathlib.Path(__file__),
             ROOT / "benchmarks/lz78_c.c", ROOT / "benchmarks/driver.goose",
             ROOT / "benchmarks/build-msvc.cmd", ROOT / "test/verify.py"]
    report = {"platform":platform.platform(), "cpu":platform.processor(), "python":sys.version,
              "compiler_flags":"MSVC 19.44 x64 /O2; Goose -O2; C /std:c11",
              "rounds":args.rounds, "warmups_per_sample":2,
              "inputs":inputs, "rows":rows,
              "sha256":{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}}
    (work/"timings.json").write_text(json.dumps(report,indent=2),encoding="utf-8")
    lines = ["| Data (1 MiB) | Mode | Goose | C ranges | C parents |",
             "|---|---|---:|---:|---:|"]
    for row in rows:
        ms=row["median_ms"]
        parent=f"{ms['C parents']:.3f} ms" if 'C parents' in ms else '—'
        lines.append(f"| {row['case']} | {row['mode']} | {ms['Goose']:.3f} ms | {ms['C ranges']:.3f} ms | {parent} |")
    (work/"RESULTS.md").write_text("\n".join(lines)+"\n",encoding="utf-8")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
