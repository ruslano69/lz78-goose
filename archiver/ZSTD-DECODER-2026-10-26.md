# Zstd decoder profile and decoded FSE entries — 2026-10-26

Baseline `bd980af` already includes the Huffman bit reservoir. The EXE/DLL
decoder still trails Go by roughly 2.4x and native libzstd by roughly 2.5x
on the retained benchmark corpus. These are implementation comparisons,
not isolated measurements of language overhead.

## Sampled work

GCC 15.2.0, Goose `a108677`, Windows x64. The release benchmark was sampled
while decoding the same Go frames used for timing. The collector suspended
only its own child's main thread, read RIP and immediately resumed it;
intervals were randomized between 0.7 and 2.3 ms. One long run per input
produced 5315 EXE samples and 9226 DLL samples. Profiling duration is not a
benchmark result. The final restored DLL was compared byte-for-byte.

A second build of the generated C with `-O2 -g` had an identical `.text`
SHA-256 to the measured executable. `addr2line -i` resolved inline sequences
inside the frame decoder. No full native call-stack unwinding was done.
Standalone copy-helper samples therefore remain separate from callers.

| Operation | EXE samples | DLL samples |
|---|---:|---:|
| Huffman streams | 41.0% | 41.9% |
| Sequences, including inline helpers | 37.5% | 36.0% |
| Copy helper | 15.0% | 16.2% |
| Checksum | 4.0% | 3.4% |
| Huffman table setup | 1.2% | 1.2% |
| FSE table setup | 1.0% | 0.9% |

Percentages use all samples, including the small external/other remainder.
They are instruction samples, not cache-miss measurements or a breakdown
of the performance gap to C. Generated C already caches the output length
and stack top in the sequence loop; repeated arena-metadata stores are not
the observed cause of this gap.

## Retained change

For a compressed block with sequences, prepare three arrays of decoded FSE
entries. One `u64` contains the decoded value base (low 32 bits), next-state
base (16 bits), state bit count (8 bits) and value bit count (high 8 bits).
The hot loop needs one entry lookup per LL/ML/OF state instead of a symbol
lookup followed by dependent base/bit table lookups. Symbol bounds are
checked during preparation.

The three fixed arrays occupy 12 KiB of temporary native-stack storage per
sequence call; blocks reuse this space. Existing context tables and public
APIs are unchanged. The encoder, sequence bitstream, repeat-offset rules,
block limits and checksum verification are unchanged.

Seven rotating process runs of about 0.18 seconds per variant, three
warmups, reused outputs, CRC, no concurrent builds/tests, IO/startup excluded.
All decoders receive identical Go SpeedDefault frames. Decimal MB/s counts
restored bytes. Go 1.25.7, klauspost/compress
`7cfdd8fb9c59ef8d6407801a284439036ab02a9f`.

| Input | Baseline MB/s | Retained MB/s | Gain | Go MB/s |
|---|---:|---:|---:|---:|
| Documentation | 522.0 | 548.1 | 5.0% | 1231.0 |
| Sources | 556.5 | 583.0 | 4.8% | 1211.3 |
| Synthetic 256 words | 697.7 | 766.8 | 9.9% | 1117.0 |
| EXE | 521.6 | 537.4 | 3.0% | 1238.0 |
| DLL | 443.7 | 459.1 | 3.5% | 1102.7 |
| Random bytes | 10778.1 | 10807.8 | 0.3% | 13754.5 |

This is a modest additional improvement. It leaves a substantial decoder
gap; a new simultaneous native-libzstd series was not run for this change.

## Rejected probes

* Two-symbol Huffman lookups, 11/12/13-bit tables: on EXE/DLL, about 9–14%
  slower. Larger tables and preparation did not pay back in these versions.
* Short copies split into fixed pieces or byte loops: about 5–21% slower
  on compressed inputs. The existing copy helper already handles small
  lengths efficiently.
* Pre-sized output with fixed views and word-copy loops: about 7–24% slower.
* Packing only the original FSE fields into `u32`: generally around 0–2%.
* Persistent decoded tables in a larger context: slower than temporary
  decoded tables in screening. The selected version also avoids changing
  the existing context representation.

## Validation and next experiment

GCC Release and Debug each pass 95 libzstd interoperability/refusal checks,
80 checks with the pinned Go decoder/encoder, and 73 text/sequence cases:
496 checks total. Native Debug also passes 59400 scalar Huffman comparisons,
138336 prefix comparisons, 4352 short RLE round trips and 51 reused-context
comparisons. Decoded outputs match original bytes on all six timed inputs.

Compression control preserves every output byte on all six inputs. Working
corpus median changes were −0.5% to +0.8%; no encoding gain is claimed.
The noisy raw-encoding result is retained separately in the JSON companion.

Next: decode a small fixed batch of sequence records before executing
literal/match copies. This may keep FSE states in registers across more
work and separate table reads from copy calls, using only a small bounded
scratch array. It must preserve offset history, limits and overlap rules;
its speed is not yet measured. Huffman remains another major target.

Exact hashes and timing samples are in `ZSTD-DECODER-2026-10-26.json`.
Probe sources, funcfinder previews, original RIP samples, generated C and
symbol binaries remain under ignored `build/decoder-20261026/`.
