# Zstd memory experiments — 2026-10-26

Baseline: `ea98a6e`, source SHA-256
`159ec5037a393fa73b15ed67514b8be5702b1bba278763b0395e448ccddf8120`.
Windows x64, Goose `a108677` (runtime `fba599d313fe`), GCC 15.2.0,
Go 1.25.7, klauspost/compress `7cfdd8fb9c59ef8d6407801a284439036ab02a9f`.
These measurements use this toolchain and these inputs; they must not be
combined with the GCC 16.1/libzstd tables in the other report.

## Retained decoder change

`huf_stream` keeps a loaded 64-bit input word and the number of available
bits in local variables. It reloads only when the next table lookup needs
more bits. The last word remains at byte zero and uses the existing virtual
zero padding below the stream. Inputs shorter than eight bytes retain the
bounded reader. The Huffman table is passed by const reference.

This removes repeated overlapping input loads; it changes neither the
encoder nor the decoded data. It adds no buffer or persistent context.

Seven rotating process runs of about 0.18 seconds per variant, three
warmups, reused output and decoder context, startup and file IO excluded.
All decoders receive the same Go SpeedDefault frame, including checksum.
Decimal MB/s counts restored bytes, not compressed input bytes.

| Input | Bytes | Baseline decode | Retained decode | Gain | Go decode |
|---|---:|---:|---:|---:|---:|
| Compiler documentation, once | 346726 | 490.7 | 526.5 | 7.3% | 1248.1 |
| Source corpus | 1313921 | 526.2 | 555.8 | 5.6% | 1219.5 |
| Synthetic 256-word corpus | 1048576 | 689.2 | 701.7 | 1.8% | 1107.5 |
| EXE corpus | 2000000 | 446.8 | 523.2 | 17.1% | 1243.5 |
| DLL corpus | 3000000 | 385.0 | 448.6 | 16.5% | 1100.8 |
| Random bytes | 1048576 | 10850.3 | 10866.5 | 0.1% | 13801.7 |

Go remains substantially faster at decoding compressed data. This is a
decoder improvement; it does not establish a new encoder advantage.

## Encoder memory layouts

All variants below preserved the baseline compressed bytes on six inputs.
They were screened with seven rotating runs, retained contexts and CRC.

* Packing position + cached prefix into six bytes (32 + 16 bits), or five
  bytes (32 + 8), saved 25% or 37.5% of table storage but slowed working
  corpora by roughly 4–10%. Short-prefix hits still verified the full input
  word, preserving match choices.
* A 16-bit hot-position cache used a 64 KiB input bank, presence bitsets,
  and the original 64-bit tables as cold history. Bank rotation flushed
  touched entries, so distant candidates and output bytes were retained.
  Hot tables + masks occupied 408 KiB, in addition to the 1536 KiB cold
  tables. It slowed text/words about 33% and EXE/DLL about 45–47%. Mask
  access, candidate-prefix loads and flushing outweighed the smaller hot
  position arrays. This result rejects this particular design, not narrow
  references in general.
* Direct Huffman-part construction and direct compressed-block construction
  with rollback removed temporary copies. Working-corpus changes were
  generally around 0–1%; an owned-part-return probe gained about 3% only
  on the synthetic word corpus. None was retained.

Current `u64` hash entries are not native pointers: they contain a 32-bit
position and a cached 32-bit input prefix. A 128 KiB Zstd block needs 17 bits
for arbitrary byte positions. A bare 16-bit byte offset covers only 64 KiB.

Committed compressed sequences used offsets above 65535 for about 22% of
matched bytes in documentation, 30% in sources, 14% in EXE and 18% in DLL.
The synthetic words had almost none. These shares describe current match
choices, not unavoidable density losses: a bounded finder could choose
alternative matches and must be measured separately.

## Nonlocal returns and decoder probes

Goose `return value from outer` was tested in a four-stream decoder helper.
It correctly returns through intermediate calls and restores data stacks.
The generated C uses a thread-local return flag and checks after calls on
the propagation path. Compiler documentation also says such a channel can
disable stack-top caching through fat references.

The tested owned result used a growable local converted to `u8[]`. Generated
C showed a final copy into the append destination. Thus that spelling did
not achieve the intended construction without a copy; it is not evidence
against construction in place with matching types. Its measured result
did not justify replacing the ordinary-return implementation.

Other probes: passing `Huf` by reference alone gave about 0–1%; packing
symbol + bit length into one `u16` lookup regressed working corpora up to
8%; four-way interleaving plus bit reservoirs reached about 19–22% on
EXE/DLL in screening. The extra interleaving code was not retained: the
simple reservoir delivered most of the gain with a much smaller change.

## Verification and reproduction

* `zstd_test.goose`: 59400 comparisons against an independent bit-by-bit
  Huffman oracle, covering table depths 1–11, word/tail boundaries, all stop
  bit positions, missing stop bits, zero entries, overreads and output
  prefixes; existing prefix/RLE/reused-context checks also pass.
* GCC Release and Debug: 95 libzstd interoperability/refusal checks and
  80 checks with the pinned Go implementation, per build.
* Compression control: baseline and retained streams are byte-identical on
  all six benchmark inputs. Working-corpus timings fluctuate by about 1–2%;
  there is no measured encoder improvement from this change.

Random encoding repeatedly switches between roughly 2.8 and 3.4 GB/s in
different processes, including the baseline. Reversals between successive
series preclude claiming a raw-encoding gain or loss from these medians.
The cause is not established.

A follow-up with nine alternating pairs and longer batches gave 374.1 vs
374.5 MB/s on words (300 encodes per process, +0.1%) and 3439.8 vs
3419.9 MB/s on random bytes (1000 encodes, −0.6%). Both raw-encoding
executables exhibited both speed ranges within the same series.

Build `bench_zstd.goose` with `--cc C:/msys64/ucrt64/bin/gcc.exe` at the
baseline and retained source. Use `d FRAME ITERATIONS RESTORED` for decode
and `reuse INPUT ITERATIONS FRAME` for encoding. Keep each timed batch
above 0.15 seconds, rotate order, and verify all output bytes. The committed
JSON companion records the exact input hashes and retained measurements.
Detailed probes, generated C, funcfinder previews and logs are under ignored
`build/memory-20261026/`.

Next encoder experiment: a bounded 16-bit finder with measured alternative
matches and explicit density accounting, or a layout that retains cached
prefixes without adding a second dependent lookup. Avoid assuming that
smaller records or absence of GC automatically improve a reused-context
hot loop.
