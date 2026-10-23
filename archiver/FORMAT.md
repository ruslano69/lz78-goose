# GARC0001 file format

One file, independent blocks, little-endian integer fields. This format is not
compatible with bzip2, ZIP, the LZ78 exercise or the earlier BWT-only wrapper.

## File header: 24 bytes

| Offset | Size | Field |
|---|---:|---|
| 0 | 8 | ASCII `GARC0001` (version 1) |
| 8 | 4 | Block size, u32, 65,536 through 4,194,304 bytes |
| 12 | 8 | Total original byte count, u64, at most 67,108,864 |
| 20 | 4 | CRC32 of the entire original file, u32 |

Blocks follow until the declared original size is reached. Each block's original
size must equal min(block size, remaining original bytes). There are no empty
blocks and no footer. Exact EOF is required. Empty files have just this header
and CRC32 zero. The encoder defaults to a 1,048,576-byte block.

## Block header: 17 bytes

| Offset | Size | Field |
|---|---:|---|
| 0 | 1 | Method: 0 = stored; 1 = BWT/MTF/zero runs/Huffman |
| 1 | 4 | Original block size, u32 |
| 5 | 4 | Payload size, u32 |
| 9 | 4 | BWT primary row, u32 |
| 13 | 4 | CRC32 of the original block, u32 |
| 17 | payload size | Payload |

Stored blocks have primary zero and payload size equal to original size. Their
payload is the original bytes. Compressed blocks require a smaller payload than
the original block, including all Huffman metadata. The encoder stores a block
when compression does not win. Common block/file framing can still expand a file.

## Method 1

1. BWT sorts ordinary suffixes with an implicit unique smallest sentinel.
   Map bytes to symbols 1..256 and sentinel to zero. Omit the sentinel from the
   last column, retaining its row as primary (1..original size). For `banana`,
   payload is `annbaa`, primary 4. The BWT payload has exactly the original size.
2. MTF starts with alphabet 0..255. Emit each byte's zero-based rank, then move
   it to the front. A zero rank leaves the alphabet unchanged.
3. Replace consecutive zero ranks by bijective binary digits: while run > 0,
   decrement run, emit run & 1 (RUNA=0 or RUNB=1), then shift run right by one.
   Nonzero ranks r=1..255 become symbols r+1=2..256. Decoding a run sums
   (digit+1)*2^position, least significant digit first. No end marker is used.
4. Encode these symbols with canonical Huffman codes over alphabet 0..256.

Huffman payload:

| Offset | Size | Field |
|---|---:|---|
| 0 | 4 | Number of decoded zero-run/MTF symbols, u32, 1..original size |
| 4 | 4 | Number of significant encoded bits, u32 |
| 8 | 257 | Code length for each symbol in numeric order, u8 |
| 265 | ceil(bit count / 8) | Bitstream |

Length zero means unused; active lengths are 1..24. Assign codes by increasing
length and then symbol, shifting the next code when length increases. Trees
must be complete and not oversubscribed. The sole exception is one active symbol:
length 1, code zero. Bits are emitted most significant first; final low padding
bits must be zero. Require exact symbol count, bit consumption and payload size.

The encoder's tree is deterministic: choose the two least-weight unparented
nodes, breaking ties by increasing node index. Leaves have indexes 0..256 and
internal nodes start at 257 in creation order. A lone symbol gets length 1.
If a generated tree would exceed 24 bits, the encoder stores the original block.
Decoders may accept other valid complete code-length tables.

All intermediate symbol counts, run lengths and BWT output are bounded by the
original block size. Invalid indexes, disconnected LF cycles, invalid Huffman
tables, excess runs, bad CRCs, truncation and trailing bytes reject the archive.

## CRC32

CRC-32/ISO-HDLC (the same result as Python `zlib.crc32`): reflected polynomial
`0xEDB88320`, initial state `0xFFFFFFFF`, final XOR `0xFFFFFFFF`. The check value
for ASCII `123456789` is `0xCBF43926`. CRC detects ordinary corruption; it does
not authenticate the file or metadata.
