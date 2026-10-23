"""Check documented 7z Copy vectors with a caller-supplied official reader.

This validates the layout design, not a Goose 7z implementation. No downloads,
installations or archive producer are involved. Generated files stay in --out.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sevenzip", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    reader = args.sevenzip.resolve()
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    run_dir = Path(tempfile.mkdtemp(prefix="vectors-", dir=output))
    source = Path(__file__).with_name("sevenz-copy-vectors.json")
    vectors = json.loads(source.read_text(encoding="utf-8"))
    assert vectors["protocol"] == "goose.sevenz-copy-vectors/v1"

    def invoke(*arguments, success=True):
        command = [str(reader), *map(str, arguments)]
        p = subprocess.run(command, capture_output=True, timeout=30)
        text = (p.stdout + p.stderr).decode("utf-8", errors="replace")
        if success:
            assert p.returncode == 0, (command, p.returncode, text)
        else:
            assert p.returncode != 0, (command, text)
        return text

    results, entries = [], 0
    for case in vectors["cases"]:
        data = bytes.fromhex(case["archive_hex"])
        digest = hashlib.sha256(data).hexdigest()
        assert digest == case["sha256"]
        assert data[:8] == b"7z\xbc\xaf\x27\x1c\x00\x04"
        assert zlib.crc32(data[12:32]) == struct.unpack_from("<I", data, 8)[0]
        offset, size, crc = struct.unpack_from("<QQI", data, 12)
        assert 32 + offset + size == len(data)
        assert zlib.crc32(data[32+offset:]) == crc
        path = run_dir / (case["name"] + ".7z")
        path.write_bytes(data)
        target = run_dir / ("extracted-" + case["name"])
        target.mkdir()
        for operation, arguments in (
            ("list", ["l", "-slt", "-sccUTF-8", path]),
            ("test", ["t", "-sccUTF-8", path]),
            ("extract", ["x", "-y", "-sccUTF-8", "-o" + str(target), path]),
        ):
            (run_dir / f"{case['name']}-{operation}.txt").write_text(invoke(*arguments), encoding="utf-8")
        expected_data = bytearray()
        for entry in case["entries"]:
            stored_path = entry["path"]
            assert stored_path and not stored_path.startswith(("/", "\\"))
            assert all(p not in ("", ".", "..") for p in stored_path.split("/"))
            assert ":" not in stored_path and "\\" not in stored_path
            dest = target / stored_path
            if entry["kind"] == "directory":
                assert dest.is_dir(), stored_path
            else:
                expected = bytes.fromhex(entry["data_hex"])
                assert dest.read_bytes() == expected, stored_path
                expected_data.extend(expected)
            if entry.get("mtime_filetime") is not None:
                nanoseconds = (entry["mtime_filetime"] - 116444736000000000) * 100
                assert dest.stat().st_mtime_ns == nanoseconds, (stored_path, dest.stat().st_mtime_ns, nanoseconds)
            entries += 1
        assert data[32:32+offset] == expected_data
        results.append({"name": case["name"], "entries": len(case["entries"]), "bytes": len(data), "sha256": digest})
    one = bytes.fromhex(next(c for c in vectors["cases"] if c["name"] == "one")["archive_hex"])
    refusals = []
    for name, at in (("start_header_crc", 12), ("next_header_crc", len(one)-1), ("file_crc", 32)):
        data = bytearray(one)
        data[at] ^= 1
        path = run_dir / ("bad-" + name + ".7z")
        path.write_bytes(data)
        (run_dir / ("bad-" + name + ".txt")).write_text(invoke("t", "-sccUTF-8", path, success=False), encoding="utf-8")
        refusals.append(name)
    identity = invoke("i", "-sccUTF-8")
    report = {"scope": "7z Copy layout vectors; Goose writer not implemented",
              "reader": identity.splitlines()[:5],
              "reader_sha256": hashlib.sha256(reader.read_bytes()).hexdigest(),
              "vectors_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
              "cases": results, "entries": entries, "crc_refusals": refusals,
              "artifacts": str(run_dir)}
    (output / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps({"cases": len(results), "entries": entries, "crc_refusals": len(refusals), "report": str(output / "report.json")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
