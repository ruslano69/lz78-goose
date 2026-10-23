"""Independent GARC0001 reference, exact-byte vectors and malformed-input checks.

Only Python's standard library is required. The reference sorts literal suffix
strings and builds Huffman trees with heapq; neither is the production algorithm.
Large cases use the CLI roundtrip; smaller cases also use the independent codec.
"""
import argparse
import bz2
import gzip
import hashlib
import heapq
import itertools
import json
from pathlib import Path
import random
import struct
import subprocess
import tempfile
import zlib

MAGIC = b"GARC0001"
HEADER, FRAME, HUFF = 24, 17, 265
MAX_FILE = 64 << 20


def bwt_forward(data):
    rows = sorted(range(len(data) + 1), key=lambda i: data[i:])
    return bytes(data[i - 1] for i in rows if i), rows.index(0)


def bwt_inverse(data, primary):
    assert 0 < primary <= len(data)
    column = [c + 1 for c in data]
    column.insert(primary, 0)
    frequency = [0] * 257
    for c in column:
        frequency[c] += 1
    starts, total = [], 0
    for count in frequency:
        starts.append(total)
        total += count
    links = []
    for c in column:
        links.append(starts[c])
        starts[c] += 1
    result, row = [], primary
    for _ in data:
        row = links[row]
        assert row != primary
        result.append(column[row] - 1)
    assert links[row] == primary
    return bytes(reversed(result))


def mtf_encode(data):
    alphabet, symbols, run = list(range(256)), [], 0

    def flush(n):
        while n:
            n -= 1
            symbols.append(n & 1)
            n >>= 1

    for byte in data:
        rank = alphabet.index(byte)
        if not rank:
            run += 1
        else:
            flush(run)
            run = 0
            symbols.append(rank + 1)
            alphabet.insert(0, alphabet.pop(rank))
    flush(run)
    return symbols


def mtf_decode(symbols, size):
    alphabet, result, i = list(range(256)), bytearray(), 0
    while i < len(symbols):
        if symbols[i] < 2:
            run, weight = 0, 1
            while i < len(symbols) and symbols[i] < 2:
                run += (symbols[i] + 1) * weight
                weight *= 2
                i += 1
                assert run <= size - len(result)
            result.extend([alphabet[0]] * run)
        else:
            rank = symbols[i] - 1
            assert 1 <= rank <= 255 and len(result) < size
            byte = alphabet.pop(rank)
            alphabet.insert(0, byte)
            result.append(byte)
            i += 1
    assert len(result) == size
    return bytes(result)


def lengths_for(symbols):
    freq = [0] * 257
    for s in symbols:
        freq[s] += 1
    heap = [(n, i, [i]) for i, n in enumerate(freq) if n]
    heapq.heapify(heap)
    lengths, next_node = [0] * 257, 257
    if len(heap) == 1:
        lengths[heap[0][1]] = 1
    while len(heap) > 1:
        a, _, left = heapq.heappop(heap)
        b, _, right = heapq.heappop(heap)
        members = left + right
        for s in members:
            lengths[s] += 1
        heapq.heappush(heap, (a + b, next_node, members))
        next_node += 1
    return lengths


def codebook(lengths):
    entries = sorted((n, s) for s, n in enumerate(lengths) if n)
    assert entries and all(1 <= n <= 24 for n, _ in entries)
    code, previous, result = 0, 0, {}
    for length, symbol in entries:
        code <<= length - previous
        assert code < 1 << length
        result[symbol] = f"{code:0{length}b}"
        code += 1
        previous = length
    assert (len(entries) == 1 and entries[0][0] == 1) or code == 1 << previous
    return result


def huffman_encode(symbols):
    lengths = lengths_for(symbols)
    codes = codebook(lengths)
    text = "".join(codes[s] for s in symbols)
    padded = text + "0" * (-len(text) % 8)
    return struct.pack("<II", len(symbols), len(text)) + bytes(lengths) + bytes(int(padded[i:i+8], 2) for i in range(0, len(padded), 8))


def huffman_decode(data, limit):
    assert len(data) >= HUFF
    size, bit_count = struct.unpack_from("<II", data)
    assert 0 < size <= limit and size <= bit_count <= 24 * size
    assert len(data) == HUFF + (bit_count + 7) // 8
    lookup = {v: k for k, v in codebook(data[8:HUFF]).items()}
    bits = "".join(f"{b:08b}" for b in data[HUFF:])
    assert set(bits[bit_count:]) <= {"0"}
    result, pending = [], ""
    for bit in bits[:bit_count]:
        pending += bit
        assert len(pending) <= 24
        if pending in lookup:
            result.append(lookup[pending])
            pending = ""
    assert not pending and len(result) == size
    return result


def encode(data, block_size=1 << 20):
    out = bytearray(MAGIC + struct.pack("<IQI", block_size, len(data), zlib.crc32(data)))
    for start in range(0, len(data), block_size):
        chunk = data[start:start+block_size]
        method, payload, primary = 0, chunk, 0
        if len(chunk) > HUFF:
            last, index = bwt_forward(chunk)
            compressed = huffman_encode(mtf_encode(last))
            if len(compressed) < len(chunk):
                method, payload, primary = 1, compressed, index
        out.extend(struct.pack("<BIIII", method, len(chunk), len(payload), primary, zlib.crc32(chunk)))
        out.extend(payload)
    return bytes(out)


def decode(data):
    assert len(data) >= HEADER and data[:8] == MAGIC
    block_size, size, checksum = struct.unpack_from("<IQI", data, 8)
    assert (64 << 10) <= block_size <= (4 << 20) and size <= MAX_FILE
    pos, out = HEADER, bytearray()
    while len(out) < size:
        assert len(data) - pos >= FRAME
        method, n, stored, primary, crc = struct.unpack_from("<BIIII", data, pos)
        pos += FRAME
        assert n == min(block_size, size - len(out)) and 0 < stored <= len(data) - pos
        payload = data[pos:pos+stored]
        pos += stored
        if method == 0:
            assert primary == 0 and stored == n
            chunk = payload
        else:
            assert method == 1 and stored < n
            chunk = bwt_inverse(mtf_decode(huffman_decode(payload, n), n), primary)
        assert zlib.crc32(chunk) == crc
        out.extend(chunk)
    assert pos == len(data) and len(out) == size and zlib.crc32(out) == checksum
    return bytes(out)


def frames(data):
    result, pos = [], HEADER
    while pos < len(data):
        method, n, stored, _, _ = struct.unpack_from("<BIIII", data, pos)
        result.append({"method": method, "original": n, "payload": stored})
        pos += FRAME + stored
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--exe", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()
    exe, report_path = args.exe.resolve(), args.output.resolve()
    counts = {"exact_vectors": 0, "reference_decodes": 0, "large_roundtrips": 0,
              "rejections": 0, "cli_rejections": 0}
    ratios = []
    rng = random.Random(780023)
    with tempfile.TemporaryDirectory(prefix="goose-archive-", dir=report_path.parent) as tmp:
        work = Path(tmp)
        source, archive, restored = (work / n for n in ("вход.bin", "archive.garc", "restored.bin"))

        def invoke(mode, inp, target=None, block_kib=None, ok=True):
            command = [str(exe), mode, str(inp)]
            if target is not None:
                command.append(str(target))
            if block_kib is not None:
                command.append(str(block_kib))
            p = subprocess.run(command, capture_output=True, timeout=90)
            assert p.returncode == (0 if ok else 1), (command, p.returncode, p.stdout, p.stderr)
            return p

        cases = [b"", b"a", bytes(range(256)), bytes(reversed(range(256))) * 3,
                 b"banana" * 100, b"A" * 4096, b"\0" * 4096,
                 "Гусь сжимает тексты. Goose compresses text.\n".encode() * 30]
        for n in range(65):
            cases.append(rng.randbytes(n))
        for n in (266, 267, 511, 1024, 2048):
            cases.extend([bytes(rng.randrange(4) for _ in range(n)), rng.randbytes(n)])
        cases.extend(bytes(p) * 100 for n in range(1, 6) for p in itertools.product((65, 66), repeat=n))
        for data in cases:
            source.write_bytes(data)
            invoke("c", source, archive)
            packed = archive.read_bytes()
            assert packed == encode(data), (len(data), hashlib.sha256(data).hexdigest())
            assert decode(packed) == data
            invoke("d", archive, restored)
            assert restored.read_bytes() == data
            invoke("t", archive)
            counts["exact_vectors"] += 1

        root = Path(__file__).resolve().parent
        real = [(p.relative_to(root).as_posix(), p.read_bytes()) for p in
                (root / "README.md", root / "FORMAT.md", root / "garchive.goose")]
        large = [("repeat-64KiB-minus-1", b"A" * 65535, 64),
                 ("repeat-64KiB", b"B" * 65536, 64),
                 ("repeat-64KiB-plus-1", b"C" * 65537, 64),
                 ("repeat-1MiB-plus-1", b"D" * ((1 << 20) + 1), 1024),
                 ("max-block-4MiB", b"E" * (4 << 20), 4096),
                 ("random-multiple-blocks", rng.randbytes((1 << 20) + 91), 64),
                 ("UTF8-multiple-blocks", "Русский текст, English text, числа 0123456789.\n".encode() * 14000, 64)]
        large += [(name, data, 64) for name, data in real]
        for name, data, block_kib in large:
            source.write_bytes(data)
            invoke("c", source, archive, block_kib)
            packed = archive.read_bytes()
            invoke("d", archive, restored)
            assert restored.read_bytes() == data
            invoke("t", archive)
            if len(data) <= (1 << 20):
                assert decode(packed) == data
                counts["reference_decodes"] += 1
            counts["large_roundtrips"] += 1
            ratios.append({"name": name, "input": len(data), "archive": len(packed),
                           "gzip9": len(gzip.compress(data, compresslevel=9, mtime=0)),
                           "bzip2_9": len(bz2.compress(data, compresslevel=9)),
                           "block_kib": block_kib, "frames": frames(packed),
                           "sha256": hashlib.sha256(data).hexdigest()})
            if name.startswith("random"):
                assert all(f["method"] == 0 for f in frames(packed))

        raw = encode(b"small raw payload")
        good = encode(b"A" * 4096)
        bad = [b"", b"garbage", raw + b"tail", good + b"tail"]
        bad += [good[:i] for i in range(len(good))]

        def field(base, offset, fmt, value):
            data = bytearray(base)
            struct.pack_into(fmt, data, offset, value)
            bad.append(bytes(data))

        field(good, 0, "B", 0)
        for value in (0, 65535, 4194305, 0xFFFFFFFF):
            field(good, 8, "<I", value)
        for value in (0, MAX_FILE+1, 0xFFFFFFFFFFFFFFFF):
            field(good, 12, "<Q", value)
        field(good, 20, "<I", 0)
        field(good, 24, "B", 2)
        field(good, 25, "<I", 0)
        field(good, 29, "<I", 0)
        field(good, 29, "<I", 0xFFFFFFFF)
        for value in (0, 1, 4097, 0xFFFFFFFF):
            field(good, 33, "<I", value)
        field(good, 37, "<I", 0)
        field(raw, 33, "<I", 1)
        field(good, 41, "<I", 0)
        field(good, 41, "<I", 4097)
        field(good, 45, "<I", 0)
        field(good, 45, "<I", 0xFFFFFFFF)
        for table in (bytes(257), bytes([1] * 257), bytes([25] + [0] * 256), bytes([2] + [0] * 256)):
            value = bytearray(good)
            value[49:306] = table
            bad.append(bytes(value))
        bits = struct.unpack_from("<I", good, 45)[0]
        if bits % 8:
            value = bytearray(good)
            value[-1] |= 1
            bad.append(bytes(value))
        # A valid Huffman stream with a zero run exceeding the decoded block.
        payload = huffman_encode([1] * 20)
        bad.append(MAGIC + struct.pack("<IQI", 1 << 20, 4096, zlib.crc32(b"A" * 4096)) +
                   struct.pack("<BIIII", 1, 4096, len(payload), 4096, zlib.crc32(b"A" * 4096)) + payload)
        for _ in range(80):
            value = bytearray(good)
            pos = rng.randrange(24, len(value))
            value[pos] ^= 1 << rng.randrange(8)
            # Some table changes can legally represent the same decoded bytes;
            # only independently invalid archives are rejection candidates.
            try:
                decode(value)
            except (AssertionError, IndexError, ValueError):
                bad.append(bytes(value))
        for data in bad:
            archive.write_bytes(data)
            restored.write_bytes(b"preserve existing output")
            invoke("d", archive, restored, ok=False)
            assert restored.read_bytes() == b"preserve existing output"
            invoke("t", archive, ok=False)
            counts["rejections"] += 1
        source.write_bytes(b"keep input")
        for command in (["c", source, source], ["c", source, archive, "0"],
                        ["c", source, archive, "4097"], ["c", source, archive, "xx"],
                        ["bad", source, archive], ["t", source, archive]):
            p = subprocess.run([str(exe), *map(str, command)], capture_output=True)
            assert p.returncode == 2, (command, p.returncode, p.stderr)
            counts["cli_rejections"] += 1
        assert source.read_bytes() == b"keep input"
        # Oversized input must refuse before any BWT allocation or output write.
        with source.open("wb") as f:
            f.truncate(MAX_FILE + 1)
        archive.write_bytes(b"preserve existing output")
        invoke("c", source, archive, ok=False)
        assert archive.read_bytes() == b"preserve existing output"
        counts["rejections"] += 1
    report = {"counts": counts, "executable": str(exe),
              "executable_sha256": hashlib.sha256(exe.read_bytes()).hexdigest(),
              "source_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in Path(__file__).parent.glob("*.goose")},
              "ratios": ratios}
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(counts))
    for row in ratios:
        print(f"{row['name']}: {row['input']} -> {row['archive']} bytes (gzip9 {row['gzip9']}, bzip2-9 {row['bzip2_9']})")


if __name__ == "__main__":
    main()
