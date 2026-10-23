"""Independent BZip2 interoperability and bounded malformed-input checks.

No package dependencies. Artifacts stay in a unique directory below --out.
An optional official 7za verifies streams without Python's libbz2 decoder.
"""
import argparse
import bz2
import hashlib
import json
from pathlib import Path
import random
import subprocess
import tempfile
import time


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--exe', type=Path, required=True)
    p.add_argument('--sevenzip', type=Path)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='bzip2-', dir=a.out.resolve()))
    exe = str(a.exe.resolve())
    rng = random.Random(1782010)
    report = dict(goose_to_python=0, python_to_goose=0, sevenzip_checks=0,
                  malformed_refusals=0, mutation_checks=0, cases=[], work=str(work))

    def run(args, good=True):
        r = subprocess.run([exe, *map(str, args)], capture_output=True, timeout=90)
        assert (r.returncode == 0) == good, (args, r.returncode, r.stdout, r.stderr)
        return r

    cases = [('empty', b''), ('single', b'z'), ('banana', b'banana'),
             ('all_bytes', bytes(range(256)) * 17),
             ('four_runs', b''.join(bytes([i % 251]) * 4 for i in range(34000))),
             ('rle_boundaries', b''.join(bytes([i % 256]) * n for i, n in enumerate([1, 2, 3, 4, 5, 258, 259, 260, 518, 519] * 100))),
             ('periodic', b'abaacabaac' * 23001),
             ('long_run', b'x' * 2000000),
             ('random_multiblock', rng.randbytes(1000100)),
             ('text', (Path(__file__).parent / 'README.md').read_bytes() * 20)]
    cases += [('random_' + str(i), rng.randbytes(i)) for i in [2, 3, 4, 7, 31, 49, 50, 51, 199, 200, 257, 1024, 4095]]
    seed = None
    for name, data in cases:
        src = work / (name + '.raw'); src.write_bytes(data)
        for level in [1, 3, 9]:
            packed = work / f'{name}.{level}.bz2'
            start = time.perf_counter(); run(['c', src, packed, level]); enc = time.perf_counter() - start
            stream = packed.read_bytes()
            assert stream[:4] == b'BZh' + str(level).encode()
            assert bz2.decompress(stream) == data, (name, level)
            report['goose_to_python'] += 1
            restored = work / 'restored.raw'
            start = time.perf_counter(); run(['d', packed, restored]); dec = time.perf_counter() - start
            assert restored.read_bytes() == data
            reference = work / 'python.bz2'; reference.write_bytes(bz2.compress(data, compresslevel=level))
            run(['d', reference, restored]); assert restored.read_bytes() == data
            report['python_to_goose'] += 1
            if a.sevenzip and name in ['empty', 'banana', 'long_run', 'random_multiblock', 'text']:
                r = subprocess.run([str(a.sevenzip.resolve()), 'x', '-so', str(packed)], capture_output=True, timeout=90)
                assert r.returncode == 0 and r.stdout == data, (r.returncode, r.stderr)
                report['sevenzip_checks'] += 1
            report['cases'].append(dict(name=name, level=level, original=len(data), goose=len(stream),
                                       libbz2=len(reference.read_bytes()), encode_s=enc, decode_s=dec))
            if name == 'banana' and level == 3:
                seed = stream

    malformed = [seed[:i] for i in range(len(seed))]
    malformed += [seed + b'\0', seed + seed, b'BZh0' + seed[4:], b'BZh:' + seed[4:]]
    # Reserved/legacy randomized flag, impossible primary, block/end CRC damage.
    for at, mask in [(4, 1), (10, 1), (14, 128), (15, 255), (len(seed) - 2, 1)]:
        bad = bytearray(seed); bad[at] ^= mask; malformed.append(bytes(bad))
    for i, stream in enumerate(malformed):
        path = work / 'bad.bz2'; path.write_bytes(stream)
        output = work / 'preserved.raw'; output.write_bytes(b'keep me')
        run(['d', path, output], good=False)
        assert output.read_bytes() == b'keep me'
        report['malformed_refusals'] += 1

    # Mutations can be valid streams: compare independent decoded contents.
    for i in range(150):
        bad = bytearray(seed)
        bad[rng.randrange(len(bad))] ^= 1 << rng.randrange(8)
        path = work / 'mutated.bz2'; path.write_bytes(bad)
        try:
            independent = bz2.decompress(bad)
        except (OSError, EOFError, ValueError):
            independent = None
        r = subprocess.run([exe, 'd', str(path), str(work / 'mutated.raw')], capture_output=True, timeout=5)
        if r.returncode == 0:
            assert independent is not None and (work / 'mutated.raw').read_bytes() == independent
        # Strict trailing/padding and legacy limits can refuse libbz2-tolerated streams.
        report['mutation_checks'] += 1
    for path in Path(__file__).parent.glob('*.goose'):
        report.setdefault('source_sha256', {})[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    (work / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps({k: v for k, v in report.items() if k not in ['cases', 'source_sha256']}, indent=2))


if __name__ == '__main__':
    main()
