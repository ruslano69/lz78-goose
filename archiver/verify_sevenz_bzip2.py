"""Two-way standard BZip2/Copy 7z checks using an official full 7za.

Windows x64 filesystem checks. The supplied reader must support BZip2 (7zr
does not). No downloads or recursive cleanup; keep artifacts below --out.
"""
import argparse
import bz2
import hashlib
import json
from pathlib import Path
import random
import struct
import subprocess
import tempfile
import zlib
from verify_sevenz import number, wrap


def fixture(payload, original, declared=None, packed_crc=None):
    size = len(original) if declared is None else declared
    h = b'\x01\x04\x06\0\x01\x09' + number(len(payload))
    if packed_crc is not None:
        h += b'\x0a\x01' + struct.pack('<I', packed_crc)
    h += b'\0\x07\x0b\x01\0\x01\x03\x04\x02\x02\x0c' + number(size)
    h += b'\x0a\x01' + struct.pack('<I', zlib.crc32(original)) + b'\0\x08\0\0\x05\x01'
    text = b'\0' + 'file.txt\0'.encode('utf-16le')
    h += b'\x11' + number(len(text)) + text + b'\0\0'
    return wrap(payload, h)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--exe', type=Path, required=True)
    p.add_argument('--sevenzip', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='bzip2-7z-', dir=a.out.resolve()))
    work = work / 'тест 🦆'; work.mkdir()
    exe, seven = str(a.exe.resolve()), str(a.sevenzip.resolve())
    report = dict(goose_to_7zip=0, sevenzip_to_goose=0, packed_crc_checks=0,
                  malformed_refusals=0, selective_extracts=0, work=str(work), sizes=[])

    def run(binary, *args, cwd=None, good=True):
        r = subprocess.run([binary, *map(str, args)], cwd=cwd, capture_output=True, timeout=90)
        assert (r.returncode == 0) == good, (args, r.returncode, r.stdout, r.stderr)
        return r.stdout.decode('utf8', errors='replace')

    def snapshot(root):
        return {p.relative_to(root).as_posix(): (p.read_bytes() if p.is_file() else None, p.stat().st_mtime_ns)
                for p in root.rglob('*')}

    root = work / 'input'; root.mkdir()
    (root / 'Гусь 🐦').mkdir(); (root / 'empty-dir').mkdir()
    (root / 'empty').touch()
    (root / 'text.txt').write_bytes(Path(__file__).with_name('README.md').read_bytes() * 80)
    (root / 'Гусь 🐦' / 'zeros').write_bytes(b'\0' * 2000000)
    (root / 'random.bin').write_bytes(random.Random(781234).randbytes(170000))
    (root / 'tiny.txt').write_bytes(b'abc')
    original = snapshot(root)
    for level in [0, 1, 3, 9]:
        archive = work / f'goose-{level}.7z'
        run(exe, 'a', archive, root, level)
        run(exe, 't', archive)
        listing = run(seven, 'l', '-slt', archive)
        if level:
            assert 'BZip2' in listing and 'Copy' in listing, listing
        else:
            assert 'BZip2' not in listing
        out = work / f'official-{level}'
        run(seven, 'x', '-y', '-o' + str(out), archive)
        assert snapshot(out) == original
        own = work / f'own-{level}'
        run(exe, 'x', archive, own); assert snapshot(own) == original
        selected = work / f'select-{level}'
        run(exe, 'x', archive, selected, 'Гусь 🐦')
        assert (selected / 'Гусь 🐦' / 'zeros').read_bytes() == b'\0' * 2000000
        assert not (selected / 'text.txt').exists()
        report['selective_extracts'] += 1; report['goose_to_7zip'] += 1
        report['sizes'].append(dict(level=level, archive=archive.stat().st_size))
    for level in [1, 3, 9]:
        archive = work / f'official-{level}.7z'
        run(seven, 'a', '-t7z', '-m0=BZip2', f'-mx={level}', '-ms=off', '-mhc=off', '-mmt=off', archive, '.', cwd=root)
        run(exe, 'l', archive); run(exe, 't', archive)
        out = work / f'from-official-{level}'; run(exe, 'x', archive, out)
        assert snapshot(out) == original
        report['sevenzip_to_goose'] += 1
    raw = b'banana' * 1000; packed = bz2.compress(raw)
    for valid in [None, zlib.crc32(packed)]:
        archive = work / 'packed-crc.7z'; archive.write_bytes(fixture(packed, raw, packed_crc=valid))
        run(exe, 't', archive); run(seven, 't', archive)
        report['packed_crc_checks'] += 1
    damaged = bytearray(packed); damaged[len(damaged) // 2] ^= 1
    cases = [fixture(packed, raw, len(raw) - 1), fixture(packed, raw, len(raw) + 1),
             fixture(packed, raw, 67108865), fixture(packed, raw, 0),
             fixture(bytes(damaged), raw), fixture(packed[:-1], raw),
             fixture(packed + packed, raw), fixture(packed + b'\0', raw),
             fixture(packed, raw, packed_crc=zlib.crc32(packed) ^ 1)]
    for i, bad in enumerate(cases):
        archive = work / f'bad-{i}.7z'; archive.write_bytes(bad)
        run(exe, 't', archive, good=False)
        out = work / f'bad-{i}-output'; run(exe, 'x', archive, out, good=False)
        assert not out.exists()
        report['malformed_refusals'] += 1
    for path in Path(__file__).parent.glob('*.goose'):
        report.setdefault('source_sha256', {})[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    report['sevenzip_sha256'] = hashlib.sha256(Path(seven).read_bytes()).hexdigest()
    (work / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf8')
    print(json.dumps({k: v for k, v in report.items() if k != 'source_sha256'}, indent=2))


if __name__ == '__main__':
    main()
