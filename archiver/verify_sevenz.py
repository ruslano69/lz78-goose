"""Cross-check Goose Copy 7z against official 7-Zip, including refusal paths.

Windows x64 CLI test. Requires caller-supplied native binaries; downloads and
installs nothing. Test trees/artifacts are retained under the explicit output.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile
import zlib


def number(value):
    for extra in range(8):
        if value < 1 << (7 * (extra + 1)):
            return bytes([((0xFF << (8-extra)) & 255 if extra else 0) | (value >> (extra*8))]) + value.to_bytes(8, "little")[:extra]
    return b"\xff" + value.to_bytes(8, "little")


def wrap(payload, header):
    start = struct.pack("<QQI", len(payload), len(header), zlib.crc32(header))
    return b"7z\xbc\xaf\x27\x1c\0\4" + struct.pack("<I", zlib.crc32(start)) + start + payload + header


def copy_fixture(names, directory=False):
    # Small fixed Copy stream reference used to construct malicious metadata.
    n = len(names)
    header = b"\x01\x04\x06\0" + number(n) + b"\x09" + b"\x03"*n + b"\0\x07\x0b" + number(n) + b"\0"
    header += b"\x01\x01\0"*n + b"\x0c" + b"\x03"*n
    header += b"\x0a\x01" + struct.pack("<I", zlib.crc32(b"abc"))*n + b"\0\x08\0\0\x05" + number(n)
    text = b"\0" + b"".join(s.encode("utf-16le", errors="surrogatepass") + b"\0\0" for s in names)
    header += b"\x11" + number(len(text)) + text + b"\0\0"
    return wrap(b"abc"*n, header)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--exe", type=Path, required=True)
    ap.add_argument("--sevenzip", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    exe, reader = args.exe.resolve(), args.sevenzip.resolve()
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="copy-", dir=output))
    counts = {"golden_vectors": 0, "goose_to_7zip": 0, "7zip_to_goose": 0,
              "malformed_refusals": 0, "path_refusals": 0, "random_header_probes": 0,
              "filesystem_refusals": 0, "selective_extracts": 0}

    def run(binary, *argv, cwd=None, ok=True, code=None):
        p = subprocess.run([str(binary), *map(str, argv)], cwd=cwd, capture_output=True, timeout=90)
        text = (p.stdout + p.stderr).decode("utf-8", errors="replace")
        expected = 0 if ok else 1
        assert p.returncode == (expected if code is None else code), (binary, argv, p.returncode, text)
        return text

    def tree(path):
        return {p.relative_to(path).as_posix(): (None if p.is_dir() else p.read_bytes()) for p in path.rglob("*")}

    def check(source, target):
        assert tree(source) == tree(target), (source, target)
        for p in source.rglob("*"):
            dest = target / p.relative_to(source)
            assert dest.stat().st_mtime_ns == p.stat().st_mtime_ns, (p, p.stat().st_mtime_ns, dest.stat().st_mtime_ns)

    vectors = json.loads(Path(__file__).with_name("sevenz-copy-vectors.json").read_text(encoding="utf-8"))
    for case in vectors["cases"]:
        archive = work / (case["name"] + ".7z")
        archive.write_bytes(bytes.fromhex(case["archive_hex"]))
        run(exe, "l", archive); run(exe, "t", archive)
        target = work / ("vector-" + case["name"])
        run(exe, "x", archive, target)
        for entry in case["entries"]:
            p = target / entry["path"]
            if entry["kind"] == "directory":
                assert p.is_dir()
            else:
                assert p.read_bytes() == bytes.fromhex(entry["data_hex"])
            if entry.get("mtime_filetime") is not None:
                assert p.stat().st_mtime_ns == (entry["mtime_filetime"]-116444736000000000)*100
        counts["golden_vectors"] += 1

    rng = random.Random(700023)
    for label in ("empty", "empty-files", "unicode-many"):
        source = work / ("input-" + label)
        source.mkdir()
        if label == "empty-files":
            (source / "vacant").mkdir(); (source / "blank.txt").write_bytes(b"")
        if label == "unicode-many":
            (source / "docs/nested").mkdir(parents=True)
            (source / "vacant").mkdir()
            for name, data in (("a.txt", b"abc"), ("b.txt", b"two"), ("docs/nested/empty", b""),
                               ("Русский.txt", "Гусь\n".encode()), ("🐦.txt", b"bird"),
                               ("docs/nested/random.bin", rng.randbytes(17000))):
                (source / name).write_bytes(data)
            for i in range(130):
                (source / f"f{i:03}.dat").write_bytes(b"" if i % 3 else bytes(range(256)))
        # Fixed 100-nanosecond timestamps, including directories after file creation.
        for i, p in enumerate(sorted(source.rglob("*"))):
            ns = 1700000000000000000 + i*100000000 + 123400
            os.utime(p, ns=(ns, ns))
        archive = work / ("goose-" + label + ".7z")
        run(exe, "a", archive, source)
        run(reader, "t", "-sccUTF-8", archive)
        official_output = work / ("official-extract-" + label)
        run(reader, "x", "-y", "-sccUTF-8", "-o" + str(official_output), archive)
        if not official_output.exists():
            official_output.mkdir()
        check(source, official_output)
        counts["goose_to_7zip"] += 1
        official = work / ("official-" + label + ".7z")
        run(reader, "a", "-t7z", "-mx=0", "-ms=off", "-mhc=off", "-sccUTF-8", official, ".", cwd=source)
        run(exe, "l", official); run(exe, "t", official)
        target = work / ("goose-extract-" + label)
        run(exe, "x", official, target)
        check(source, target)
        counts["7zip_to_goose"] += 1
        if label == "unicode-many":
            selected = work / "selected"
            run(exe, "x", official, selected, "docs", "Русский.txt")
            expected = {k: v for k, v in tree(source).items() if k == "docs" or k.startswith("docs/") or k == "Русский.txt"}
            assert tree(selected) == expected
            counts["selective_extracts"] += 1
            absent = work / "no-match"
            run(exe, "x", official, absent, "not-present", ok=False)
            assert not absent.exists()
            counts["filesystem_refusals"] += 1
            unsupported = work / "lzma2.7z"
            run(reader, "a", "-t7z", "-m0=LZMA2", "-mhc=off", unsupported, "a.txt", cwd=source)
            assert "unsupported_feature" in run(exe, "t", unsupported, ok=False)
            encoded = work / "encoded-header.7z"
            run(reader, "a", "-t7z", encoded, ".", cwd=source)
            assert "unsupported_feature" in run(exe, "t", encoded, ok=False)

    good = bytes.fromhex(vectors["cases"][1]["archive_hex"])
    bad = [b"", b"garbage", good + b"tail"] + [good[:i] for i in range(len(good))]
    for at in (0, 8, 12, 20, 28, 32, len(good)-1):
        data = bytearray(good); data[at] ^= 1; bad.append(bytes(data))
    payload, header = good[32:35], good[35:]
    for at, value in ((4, 255), (9, 127), (12, 255), (13, 0x21), (14, 0x21), (18, 255)):
        h = bytearray(header); h[at] = value; bad.append(wrap(payload, h))
    for name in ("../escape", "/absolute", "C:/absolute", "a//b", "a/./b", "a/../b", "a\\b", "NUL.txt", "trail.", "trail ", "a:stream", "\ud800"):
        bad.append(copy_fixture([name]))
    path_cases = [copy_fixture(["a.txt", "a.txt"]), copy_fixture(["A.txt", "a.txt"]),
                  copy_fixture(["Я.txt", "я.txt"]), copy_fixture(["file", "file/child"]),
                  copy_fixture(["FILE", "file/child"])]
    for i, data in enumerate(bad):
        archive = work / "bad.7z"; archive.write_bytes(data)
        target = work / f"bad-output-{i}"
        run(exe, "t", archive, ok=False) if i < len(bad)-12 else None
        run(exe, "x", archive, target, ok=False)
        assert not target.exists(), i
        counts["malformed_refusals"] += 1
    for i, data in enumerate(path_cases):
        archive = work / "path.7z"; archive.write_bytes(data)
        target = work / f"path-output-{i}"
        run(exe, "x", archive, target, ok=False)
        assert not target.exists()
        counts["path_refusals"] += 1
    # Recompute outer CRCs to reach the parser with malformed internal metadata.
    for _ in range(120):
        h = bytearray(header)
        at = rng.randrange(len(h)); h[at] ^= 1 << rng.randrange(8)
        archive = work / "mutant.7z"; archive.write_bytes(wrap(payload, h))
        p = subprocess.run([str(exe), "t", str(archive)], capture_output=True, timeout=10)
        assert p.returncode in (0, 1), (p.returncode, p.stdout, p.stderr, h.hex())
        if p.returncode == 0:
            external = subprocess.run([str(reader), "t", str(archive)], capture_output=True)
            assert external.returncode == 0, (h.hex(), external.stdout, external.stderr)
        counts["random_header_probes"] += 1
    source = work / "protected-input"; source.mkdir(); (source / "keep").write_bytes(b"keep")
    existing = work / "existing.7z"; existing.write_bytes(b"preserve")
    run(exe, "a", existing, source, ok=False)
    assert existing.read_bytes() == b"preserve"
    archive = work / "protected.7z"; archive.write_bytes(good)
    run(exe, "x", archive, source, ok=False)
    assert (source / "keep").read_bytes() == b"keep" and len(list(source.iterdir())) == 1
    counts["filesystem_refusals"] += 2
    oversized = work / "oversized"; oversized.mkdir()
    with (oversized / "large").open("wb") as f:
        f.truncate((64 << 20)+1)
    run(exe, "a", work / "too-large.7z", oversized, ok=False)
    assert not (work / "too-large.7z").exists()
    counts["filesystem_refusals"] += 1
    # A junction points to a benign sibling fixture, outside the selected root.
    link = source / "junction"
    p = subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(oversized)], capture_output=True)
    assert p.returncode == 0, (p.stdout, p.stderr)
    try:
        run(exe, "a", work / "junction.7z", source, ok=False)
        assert not (work / "junction.7z").exists()
        run(exe, "x", archive, link / "new-dest", ok=False)
        assert not (oversized / "new-dest").exists()
        counts["filesystem_refusals"] += 2
    finally:
        # Remove just the junction itself, never recursively delete its target.
        os.rmdir(link)
    report = {"scope": "Windows x64 Goose non-solid Copy 7z CLI", "counts": counts,
              "exe_sha256": hashlib.sha256(exe.read_bytes()).hexdigest(),
              "reader_sha256": hashlib.sha256(reader.read_bytes()).hexdigest(),
              "source_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in Path(__file__).parent.glob("*.goose")},
              "artifacts": str(work)}
    (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(counts))


if __name__ == "__main__":
    main()
