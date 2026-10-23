# LZ78G001 archive format

All byte positions start at zero. The format is independent of host endianness.

| Offset | Bytes | Field |
|---|---:|---|
| 0 | 8 | ASCII `LZ78G001` |
| 8 | 8 | Original length, unsigned little-endian u64 |
| 16 | 4 | FNV-1a-32 of original bytes, unsigned little-endian u32 |
| 20 | remaining | Phrase records |

Dictionary entry 0 is empty. Each record begins with canonical unsigned LEB128
`index * 2 + has_byte`. If has_byte=1, one literal byte follows; emit dictionary[index]
followed by that byte and add that entire phrase at the next sequential index.
If has_byte=0, emit an existing nonempty phrase without adding a dictionary entry;
this record must be the last record in the archive.

After every 65,535 added phrases, reset to entry 0 with no explicit marker.
Thus tags use at most 17 bits/three bytes. References can only name existing
entries in the current block. Overlong ULEB128 encodings are rejected.

The empty archive contains just a header with original length 0 and checksum
2166136261. `aa` has payload `01 61 02`: literal a followed by a final reference.
`ABAABABAABAB` has phrases A, B, AA, BA, BAA, BAB and payload
`01 41 01 42 03 41 05 41 09 41 09 42`.

FNV-1a-32 starts with 2166136261 and updates `h = (h XOR byte) * 16777619`
modulo 2^32. It is a corruption check, not an authentication mechanism.

Decoding requires an exact match to the original length and checksum, with
no trailing records after a final reference. The implementation limits original
and decoded length to 64 MiB; it is a whole-file codec.
