#!/usr/bin/env python3
"""Per-frame statistics of a zstd stream: blocks, literal bytes, sequence count, section sizes.

Reads only the block, literal-section and sequence-section headers (no FSE or Huffman decoding), so it
shows where two encoders differ: in the parse (sequences, literals) or in the entropy coding (bytes spent).

Usage: python3 archiver/zstd_stats.py FRAME.zst [FRAME.zst ...]
"""
import struct
import sys


def stats(blob):
    assert blob[:4] == b"\x28\xb5\x2f\xfd", "not a zstd frame"
    fhd = blob[4]
    pos = 5
    single = (fhd >> 5) & 1
    if not single:
        pos += 1
    did = fhd & 3
    pos += (0, 1, 2, 4)[did]
    fcs = fhd >> 6
    pos += (1 if single else 0, 2, 4, 8)[fcs]
    s = dict(blocks=0, raw=0, rle=0, comp=0, lit_bytes=0, lit_coded=0, seqs=0, body=0, modes={})
    while True:
        h = blob[pos] | blob[pos + 1] << 8 | blob[pos + 2] << 16
        pos += 3
        last, typ, size = h & 1, (h >> 1) & 3, h >> 3
        s["blocks"] += 1
        if typ == 0:
            s["raw"] += 1
            pos += size
        elif typ == 1:
            s["rle"] += 1
            pos += 1
        else:
            s["comp"] += 1
            s["body"] += size
            b = blob[pos:pos + size]
            lt = b[0] & 3
            sf = (b[0] >> 2) & 3
            if lt < 2:  # raw or RLE literals
                if sf in (0, 2):
                    reg, hl = b[0] >> 3, 1
                elif sf == 1:
                    reg, hl = (b[0] >> 4) | b[1] << 4, 2
                else:
                    reg, hl = (b[0] >> 4) | b[1] << 4 | b[2] << 12, 3
                csz = reg if lt == 0 else 1
            else:
                if sf in (0, 1):
                    v = b[0] | b[1] << 8 | b[2] << 16
                    hl, reg, csz = 3, (v >> 4) & 0x3FF, (v >> 14) & 0x3FF
                elif sf == 2:
                    v = b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24
                    hl, reg, csz = 4, (v >> 4) & 0x3FFF, (v >> 18) & 0x3FFF
                else:
                    v = b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24 | b[4] << 32
                    hl, reg, csz = 5, (v >> 4) & 0x3FFFF, (v >> 22) & 0x3FFFF
            s["lit_bytes"] += reg
            s["lit_coded"] += hl + csz
            q = hl + csz
            n = b[q]
            if n == 0:
                nseq, q = 0, q + 1
            elif n < 128:
                nseq, q = n, q + 1
            elif n < 255:
                nseq, q = ((n - 128) << 8) + b[q + 1], q + 2
            else:
                nseq, q = b[q + 1] + (b[q + 2] << 8) + 0x7F00, q + 3
            s["seqs"] += nseq
            if nseq:
                m = b[q]
                key = ((m >> 6) & 3, (m >> 4) & 3, (m >> 2) & 3)
                s["modes"][key] = s["modes"].get(key, 0) + 1
                s["seq_coded"] = s.get("seq_coded", 0) + size - q - 1
            pos += size
        if last:
            break
    return s


if __name__ == "__main__":
    for p in sys.argv[1:]:
        blob = open(p, "rb").read()
        s = stats(blob)
        print("%-28s total=%d blocks=%d(comp %d raw %d rle %d) lit_bytes=%d lit_coded=%d seqs=%d seq_coded=%d modes(ll,of,ml)=%s"
              % (p.replace("\\", "/").split("/")[-1], len(blob), s["blocks"], s["comp"], s["raw"], s["rle"],
                 s["lit_bytes"], s["lit_coded"], s["seqs"], s.get("seq_coded", 0), s["modes"]))
