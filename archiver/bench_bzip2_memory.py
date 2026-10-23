"""Windows process peak memory, timings and sizes for the BZip2 block policy.

Measures the entire executable, including runtime, input/output and scratch.
PeakWorkingSetSize is resident memory; PeakPagefileUsage is peak private commit.
Does not equate either with the logical scratch formulas in BZIP2.md.
"""
import argparse
import bz2
import ctypes
from ctypes import wintypes
import hashlib
import json
from pathlib import Path
import random
import statistics
import subprocess
import tempfile
import time


class Memory(ctypes.Structure):
    _fields_ = [('cb', wintypes.DWORD), ('faults', wintypes.DWORD)] + [
        (name, ctypes.c_size_t) for name in ['peak_ws', 'ws', 'peak_paged', 'paged',
                                           'peak_nonpaged', 'nonpaged', 'commit', 'peak_commit', 'private']]


def measure(argv):
    get_memory = ctypes.WinDLL('psapi', use_last_error=True).GetProcessMemoryInfo
    get_memory.argtypes = [wintypes.HANDLE, ctypes.POINTER(Memory), wintypes.DWORD]
    get_memory.restype = wintypes.BOOL
    start = time.perf_counter()
    with subprocess.Popen(list(map(str, argv)), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) as child:
        peaks = [0, 0]
        while True:
            counters = Memory(); counters.cb = ctypes.sizeof(counters)
            if get_memory(int(child._handle), ctypes.byref(counters), counters.cb):
                peaks = [max(peaks[0], counters.peak_ws), max(peaks[1], counters.peak_commit)]
            if child.poll() is not None:
                break
            time.sleep(.002)
        assert child.returncode == 0, child.stderr.read()
    assert all(peaks), 'no process counters captured'
    return dict(seconds=time.perf_counter() - start, peak_ws=peaks[0], peak_commit=peaks[1])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--exe', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--runs', type=int, default=3)
    p.add_argument('--corpus', type=Path, help='optional saved input for corpus replay')
    a = p.parse_args()
    assert 1 <= a.runs <= 10
    a.out.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='memory-', dir=a.out.resolve()))
    exe = a.exe.resolve(); rows = []
    text = (a.corpus or Path(__file__).with_name('README.md')).read_bytes()
    assert text, 'corpus must not be empty'
    text = (text * (2100000 // len(text) + 1))[:2100000]
    for name, raw in [('empty', b''), ('text_300k', text[:300000]),
                      ('text_2100k', text), ('random_2100k', random.Random(781).randbytes(2100000))]:
        source = work / (name + '.raw'); source.write_bytes(raw)
        for level in [1, 3, 9]:
            packed = work / f'{name}-{level}.bz2'
            encode = [measure([exe, 'c', source, packed, level]) for _ in range(a.runs)]
            stream = packed.read_bytes(); assert bz2.decompress(stream) == raw
            restored = work / 'restored.raw'
            decode = [measure([exe, 'd', packed, restored]) for _ in range(a.runs)]
            assert restored.read_bytes() == raw
            # libbz2 size is a quality reference, not timing/memory of a C executable.
            rows.append(dict(name=name, level=level, original=len(raw), goose=len(stream),
                             libbz2=len(bz2.compress(raw, compresslevel=level)),
                             sha256=hashlib.sha256(raw).hexdigest(), encode=encode, decode=decode))
    report = dict(executable=str(exe), sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),
                  runs=a.runs, rows=rows, source_sha256={
                      x.name: hashlib.sha256(x.read_bytes()).hexdigest()
                      for x in Path(__file__).parent.glob('*.goose')})
    (work / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf8')
    print(work / 'report.json')
    for row in rows:
        print(row['name'], row['level'], row['goose'], '/', row['libbz2'],
              *[f"{direction} {statistics.median(x['seconds'] for x in row[direction]):.3f}s "
                f"WS {max(x['peak_ws'] for x in row[direction])/1048576:.2f} MiB "
                f"commit {max(x['peak_commit'] for x in row[direction])/1048576:.2f} MiB"
                for direction in ['encode', 'decode']])


if __name__ == '__main__':
    main()
