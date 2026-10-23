"""Cross-check the Goose executable with an independent byte-string LZ78 codec."""
import argparse
import hashlib
import json
import pathlib
import random
import struct
import subprocess
import tempfile

MAGIC = b"LZ78G001"
LIMIT = 65535
MAX_BYTES = 64 * 1024 * 1024


def checksum(data):
    h = 2166136261
    for b in data:
        h = ((h ^ b) * 16777619) & 0xFFFFFFFF
    return h


def tag(value):
    out = bytearray()
    while value >= 128:
        out.append((value & 127) | 128)
        value >>= 7
    out.append(value)
    return out


def encode(data):
    out = bytearray(MAGIC + struct.pack("<QI", len(data), checksum(data)))
    phrases = {b"": 0}
    word = b""
    resets = 0
    for b in data:
        extended = word + bytes([b])
        if extended in phrases:
            word = extended
        else:
            out.extend(tag(phrases[word] * 2 + 1))
            out.append(b)
            phrases[extended] = len(phrases)
            word = b""
            if len(phrases) > LIMIT:
                phrases = {b"": 0}
                resets += 1
    if word:
        out.extend(tag(phrases[word] * 2))
    return bytes(out), resets


def decode(data):
    if len(data) < 20 or data[:8] != MAGIC:
        raise ValueError("header")
    size, expected = struct.unpack_from("<QI", data, 8)
    if size > MAX_BYTES:
        raise ValueError("size")
    phrases, out, pos = [b""], bytearray(), 20
    while pos < len(data):
        value = 0
        for i in range(3):
            if pos == len(data):
                raise ValueError("truncated tag")
            b = data[pos]
            pos += 1
            if i == 2 and b > 7:
                raise ValueError("tag overflow")
            value |= (b & 127) << (7 * i)
            if b < 128:
                if i and b == 0:
                    raise ValueError("overlong tag")
                break
        else:
            raise ValueError("tag length")
        index, has_byte = value >> 1, value & 1
        if index >= len(phrases):
            raise ValueError("forward reference")
        word = phrases[index]
        if has_byte:
            if pos == len(data):
                raise ValueError("missing byte")
            word += data[pos:pos + 1]
            pos += 1
        elif index == 0 or pos != len(data):
            raise ValueError("invalid final reference")
        if len(word) > size - len(out):
            raise ValueError("output exceeds length")
        out.extend(word)
        if has_byte:
            phrases.append(word)
            if len(phrases) > LIMIT:
                phrases = [b""]
    if len(out) != size or checksum(out) != expected:
        raise ValueError("length/checksum")
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--exe", required=True)
    ap.add_argument("--work", default="build/verification")
    args = ap.parse_args()
    exe, work = pathlib.Path(args.exe).resolve(), pathlib.Path(args.work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    rng = random.Random(780023)
    cases = [("empty", b""), ("single", b"\0"), ("tail", b"aa"),
             ("classic", b"ABAABABAABAB"), ("all-bytes", bytes(range(256))),
             ("utf8", ("LZ78: Привіт, Goose! Гусь стискає дані.\n" * 1000).encode()),
             ("repeat", b"A" * 1048576),
             ("text", b"abracadabra abracadabra\n" * 20000),
             ("dictionary-reset", rng.randbytes(524288))]
    cases += [(f"random-{n}", rng.randbytes(n)) for n in (2, 3, 7, 16, 31, 127, 128, 255, 1024, 8192)]
    # Exhaustively enumerate short strings over a three-byte alphabet.
    import itertools
    cases += [(f"tiny-{n}-{i}", bytes(v)) for n in range(5)
              for i, v in enumerate(itertools.product((0, 65, 255), repeat=n))]
    results = []
    with tempfile.TemporaryDirectory(prefix="case-", dir=work) as tmp:
        base = pathlib.Path(tmp)
        src, packed, restored = base / "input.bin", base / "archive.lz78", base / "restored.bin"

        def run(mode, source, target):
            return subprocess.run([str(exe), mode, str(source), str(target)], capture_output=True)

        for name, data in cases:
            src.write_bytes(data)
            p = run("c", src, packed)
            assert p.returncode == 0, (name, p.stderr.decode(errors="replace"))
            actual = packed.read_bytes()
            reference, resets = encode(data)
            assert actual == reference, (name, "encoded bytes differ")
            assert decode(actual) == data, (name, "Python decoder")
            p = run("d", packed, restored)
            assert p.returncode == 0, (name, p.stderr.decode(errors="replace"))
            assert restored.read_bytes() == data, (name, "Goose decoder")
            if name == "dictionary-reset":
                assert resets >= 2, resets
            results.append({"case": name, "input": len(data), "archive": len(actual), "resets": resets})

        # An independent fixed trace catches a shared round-trip misconception.
        # Phrases: A, B, AA, BA, BAA, BAB.
        assert encode(b"ABAABABAABAB")[0][20:] == bytes([1, 65, 1, 66, 3, 65, 5, 65, 9, 65, 9, 66])
        assert encode(b"aa")[0][20:] == bytes([1, 97, 2])
        good, _ = encode(b"ABAABABAABAB")
        malformed = [good[:n] for n in range(len(good))]
        malformed += [b"", b"bad header", good + b"\0", good[:20] + b"\x80\0",
                      good[:20] + b"\xff\xff\x08", good[:20] + b"\x7fX",
                      MAGIC + struct.pack("<QI", MAX_BYTES + 1, 0),
                      good[:20] + b"\0", good[:20] + b"\x01"]
        for i in range(len(good)):
            mutation = bytearray(good)
            mutation[i] ^= 1
            malformed.append(bytes(mutation))
        rejected = 0
        for data in malformed:
            try:
                decode(data)
            except ValueError:
                pass
            else:
                continue
            packed.write_bytes(data)
            restored.write_bytes(b"KEEP EXISTING OUTPUT")
            p = run("d", packed, restored)
            assert p.returncode == 1, ("bad archive accepted", data.hex(), p.returncode)
            assert restored.read_bytes() == b"KEEP EXISTING OUTPUT", "failed decode changed output"
            rejected += 1

    report = {"exe": str(exe), "exe_sha256": hashlib.sha256(exe.read_bytes()).hexdigest(),
              "roundtrips": len(results), "rejected_archives": rejected, "cases": results}
    (work / "results.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"PASS: {len(results)} byte-exact cross-checks, {rejected} malformed archives rejected")
    for row in results[:9]:
        print(f"{row['case']}: {row['input']} -> {row['archive']} bytes; resets={row['resets']}")


if __name__ == "__main__":
    main()
