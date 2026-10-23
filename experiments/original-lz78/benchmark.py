"""Measure LZ78 codec time separately from complete CLI wall time.

Requires the built native application and Goose for the temporary timing driver.
No external Python dependencies. All generated files stay under --work.
"""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import random
import statistics
import subprocess
import sys
import time

from verify import encode, decode, checksum


def worker(mode, source, target):
    data = pathlib.Path(source).read_bytes()
    result = encode(data)[0] if mode == "c" else decode(data)
    target = pathlib.Path(target)
    temporary = target.with_suffix(".tmp")
    with temporary.open("wb") as stream:
        stream.write(result)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, target)


DRIVER = '''fn main() {
    var mode: u8[>..] = []; arg(1, mode);
    var path: u8[>..] = []; arg(2, path);
    var count: u8[>..] = []; arg(3, count);
    let rounds, valid = parse_int(count);
    if !valid || rounds < 1 { exit(2); }
    var input: u8[>..] = [];
    if !read_file(path, input) { exit(1); }
    for iteration in rounds {
        var output: u8[>..] = [];
        let start = clock_ns();
        let ok = if mode == "c" { compress(input, output) } else { decompress(input, output) };
        let elapsed = clock_ns() - start;
        if !ok { exit(1); }
        let check = checksum(output);
        print("BENCH ", elapsed, " ", output.len, " ", check);
    }
}
'''


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--exe", required=True)
    ap.add_argument("--goose", required=True)
    ap.add_argument("--funcfinder", default="funcfinder.exe")
    ap.add_argument("--work", default="build/research/lz78-timing")
    ap.add_argument("--prepare", action="store_true")
    ap.add_argument("--rounds", type=int, default=7)
    args = ap.parse_args()
    work = pathlib.Path(args.work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    exe, goose = pathlib.Path(args.exe).resolve(), pathlib.Path(args.goose).resolve()
    codec = pathlib.Path(__file__).with_name("lz78.goose").resolve()
    driver, native = work / "driver.goose", work / "driver.exe"
    if args.rounds < 3:
        ap.error("use at least three measured rounds")
    if args.prepare:
        mapped = subprocess.check_output([str(pathlib.Path(args.funcfinder).resolve()),
            "--inp", str(codec), "--source", "goose", "--func", "main", "--extract"], encoding="utf-8")
        original_main = mapped.split("\n", 1)[1].rstrip()
        source = codec.read_text(encoding="utf-8")
        assert source.count(original_main) == 1
        driver.write_text(source.replace(original_main, DRIVER), encoding="utf-8")
        subprocess.run([str(goose), "build", str(driver), "-o", str(native)], check=True)
        return

    size = 1024 * 1024
    rng = random.Random(780023)
    text = "Goose learns LZ78. Привіт! abracadabra\n".encode()
    code = codec.read_bytes()
    datasets = {"repeat": b"A" * size, "text": (text * (size // len(text) + 1))[:size],
                "source": (code * (size // len(code) + 1))[:size], "random": rng.randbytes(size)}
    rows = []
    total = args.rounds + 2

    def run(command):
        p = subprocess.run(command, capture_output=True, encoding="utf-8")
        if p.returncode:
            raise RuntimeError(p.stdout + p.stderr)
        return p.stdout

    for case, data in datasets.items():
        raw, packed = work / (case + ".bin"), work / (case + ".lz78")
        raw.write_bytes(data)
        archive, _ = encode(data)
        packed.write_bytes(archive)
        variants = ["native", "tinycc", "python"]
        rng.shuffle(variants)
        for mode, inp, expected in [("c", raw, archive), ("d", packed, data)]:
            for variant in variants:
                samples = []
                if variant == "python":
                    for _ in range(total):
                        # Input I/O is outside the measured codec interval.
                        payload = data if mode == "c" else archive
                        before = time.perf_counter_ns()
                        result = encode(payload)[0] if mode == "c" else decode(payload)
                        samples.append(time.perf_counter_ns() - before)
                        assert result == expected
                else:
                    command = ([str(native)] if variant == "native" else
                               [str(goose), "run", str(driver), "-O2", "--"])
                    output = run(command + [mode, str(inp), str(total)])
                    expected_sum = checksum(expected)
                    for line in output.splitlines():
                        if line.startswith("BENCH "):
                            _, ns, length, digest = line.split()
                            assert int(length) == len(expected) and int(digest) == expected_sum
                            samples.append(int(ns))
                    assert len(samples) == total, output
                samples = samples[2:]
                rows.append({"case":case,"mode":mode,"variant":variant,"scope":"codec",
                             "input_bytes":len(data),"archive_bytes":len(archive),"samples_ns":samples})
            # Alternate processes each round, retaining all samples. Both CLIs
            # read input and flush/atomically replace output; process startup is included.
            outputs = {v:work / (case + mode + v + ".out") for v in ("native","python")}
            wall = {v:[] for v in outputs}
            for iteration in range(total):
                order = list(outputs)
                rng.shuffle(order)
                for variant in order:
                    command = ([str(exe)] if variant == "native" else
                               [sys.executable,"-B",str(pathlib.Path(__file__).resolve()),"--worker"])
                    before = time.perf_counter_ns()
                    run(command + [mode,str(inp),str(outputs[variant])])
                    elapsed = time.perf_counter_ns() - before
                    assert outputs[variant].read_bytes() == expected
                    if iteration >= 2:
                        wall[variant].append(elapsed)
            for variant, samples in wall.items():
                rows.append({"case":case,"mode":mode,"variant":variant,"scope":"cli",
                             "input_bytes":len(data),"archive_bytes":len(archive),"samples_ns":samples})
        print(case, "done", flush=True)
    for row in rows:
        samples = row['samples_ns']
        row.update(median_ms=statistics.median(samples)/1e6,
                   min_ms=min(samples)/1e6,max_ms=max(samples)/1e6)
    report = {"python":sys.version,"platform":platform.platform(),"cpu":platform.processor(),
              "rounds":args.rounds,"warmups":2,"rows":rows,
              "sha256":{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in
                        (exe,goose,native,driver,codec,pathlib.Path(__file__),pathlib.Path(__file__).with_name('verify.py'))}}
    (work/'timings.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    lines = ["| Data (1 MiB) | Operation | Goose MSVC | Goose TinyCC | Python | Python / MSVC |",
             "|---|---|---:|---:|---:|---:|"]
    for case in datasets:
        for mode in ('c','d'):
            ms={row['variant']:row['median_ms'] for row in rows if row['scope']=='codec' and row['case']==case and row['mode']==mode}
            lines.append(f"| {case} | {mode} | {ms['native']:.3f} ms | {ms['tinycc']:.3f} ms | {ms['python']:.3f} ms | {ms['python']/ms['native']:.1f}x |")
    (work/'RESULTS.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    print('\n'.join(lines))


if __name__ == "__main__":
    if len(sys.argv)>1 and sys.argv[1]=='--worker':
        worker(*sys.argv[2:])
    else:
        main()
