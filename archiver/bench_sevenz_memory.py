"""Measure whole-process memory for one vs many files, Copy vs BZip2.

Windows x64. Reuses bench_bzip2_memory's OS peak counters. All artifacts are
retained beneath --out; no downloads, installation or recursive cleanup.
"""
import argparse
import hashlib
import json
from pathlib import Path
import random
import subprocess
import tempfile
from bench_bzip2_memory import measure


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--exe', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--runs', type=int, default=3)
    a = p.parse_args(); assert 1 <= a.runs <= 10
    a.out.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='archive-memory-', dir=a.out.resolve()))
    raw = random.Random(781).randbytes(16777216)
    rows = []; exe = a.exe.resolve()
    for files in [1, 16]:
        source = work / ('input-' + str(files)); source.mkdir()
        size = len(raw) // files
        for i in range(files):
            (source / f'{i:02}.bin').write_bytes(raw[i * size:(i + 1) * size])
        for level in [0, 3]:
            runs = []
            for i in range(a.runs):
                archive = work / f'{files}-{level}-{i}.7z'
                result = measure([exe, 'a', archive, source, level])
                subprocess.run([str(exe), 't', str(archive)], check=True, capture_output=True, timeout=90)
                result['archive'] = archive.stat().st_size; runs.append(result)
            rows.append(dict(files=files, level=level, runs=runs))
    report = dict(executable=str(exe), executable_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),
                  input_bytes=len(raw), input_sha256=hashlib.sha256(raw).hexdigest(), rows=rows,
                  source_sha256={x.name: hashlib.sha256(x.read_bytes()).hexdigest()
                                 for x in Path(__file__).parent.glob('*.goose')})
    (work / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf8')
    print(work / 'report.json')
    for row in rows:
        print(row['files'], 'files level', row['level'],
              'WS MiB', max(x['peak_ws'] for x in row['runs']) / 1048576,
              'commit MiB', max(x['peak_commit'] for x in row['runs']) / 1048576)


if __name__ == '__main__':
    main()
