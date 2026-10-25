# Zstd performance notes (2026-10-25)

The encoder uses a double-fast search, standard Zstd blocks, and a content
checksum. These observations describe synthetic screening inputs, not a
general claim that Goose is faster than another language or codec.

## Implementation changes

- Grow the search step by bytes since the last match:
  `1 + ((position - literal_start) >> 7)`. Counting failed probes instead
  made incompressible input search unnecessarily dense.
- Compute long and short hashes from one input word and compare common
  prefixes a word at a time, with bounded slices and a byte tail.
- Reuse the LL/ML/OF code arrays during sequence encoding.
- Append blocks directly to the frame, avoiding an intermediate block copy.
- Emit a standard RLE block for uniform bytes. Skip Huffman work that
  cannot improve a raw block or literal section.
- Normalize new sequence FSE tables over 256 states (tableLog 8), retaining
  the format-defined logs for predefined tables and RLE for single-symbol
  streams. The finer frequency precision improves density on these inputs.

The last change can produce different compressed bytes. Zstd does not
require a canonical encoding; the decoded bytes remain identical.

## Word-corpus measurements

Windows x64, AMD Ryzen 9 5950X; Goose compiler `e76d5c9`, GCC 15.2.0,
Go 1.25.7 and klauspost/compress
`7cfdd8fb9c59ef8d6407801a284439036ab02a9f`. Go uses SpeedDefault,
encoder concurrency 1 and checksum enabled. Each input is 1 MiB.

Seven batches of 250 encodes, three warmups per process, rotating variant
order; median decimal MB/s. State/output capacity are reused. File IO,
process startup and context creation are excluded. Tests/builds did not
run concurrently with timing. A difference of about 1% is not a reliable
claim of superiority.

| Input | Goose/GCC | Go | Goose bytes | Go bytes |
|---|---:|---:|---:|---:|
| Five-word synthetic corpus | 433.2 | 425.3 | 131079 | 132419 |
| Same vocabulary, seed 42 | 431.7 | 425.9 | 131173 | 132585 |
| Same vocabulary, seed 99 | 428.8 | 425.7 | 131012 | 132435 |
| Vocabulary of 256 words | 263.9 | 285.5 | 220915 | 236740 |

Before increasing FSE precision, the first row occupied 138834 bytes at
431.8 MB/s. The larger tables reduced its size by 5.59% while retaining
throughput. The other word cases changed speed by -1.08% to +0.72%.
These initial measurements predate the match-probe follow-up below. The
256-word case was slower than Go at that point but produced a smaller
stream. These generated words are not a natural-language corpus.

A separate three-batch screening of larger FSE tables found similar GCC
throughput on sources, random bytes, zeros and executable bytes. Source
output shrank from 30827 to 29104 bytes and executable output from 116539
to 112244; random/zero sizes were unchanged. Source/executable inputs were
repeated or truncated to 1 MiB. The original word input SHA-256 is
`581fbb5f361dd39afc3ff6149fe16531f26217dd3fadee2178b1b2ab182e641c`.

MSVC 19.44 remains slower: the final word run was about 336 MB/s. An
MSVC-specific zero-input regression remains: the final screening measured
about 0.358 versus 0.347 seconds per 1000 encodes relative to the version
before the shared-hash/code-reuse work. Earlier runs showed a larger gap.
Treat compiler/backend effects separately from algorithmic improvements.

## Match-probe follow-up: 256-word vocabulary

Baseline: repository revision `5ee008b`, including tableLog 8. The same
current-position u64 now serves the repeat-offset checks, both hashes and
both table-candidate checks. A nonzero XOR identifies the first differing
byte; equal words let the remaining comparison start eight bytes later.
Candidate first-byte rejection is retained. A block tail shorter than
eight bytes keeps the original byte comparison even if another block's
bytes follow in the input. Match choices and compressed bytes are unchanged.

The original 256-word input is 131072 choices from `word000 ` through
`word255 ` using Python `random.Random(7).choice`, giving 1 MiB. SHA-256:
`eb85cbb79bbdb7ab4bf513f9a3e8ae398416215876b5ae79d24e3912868ceb69`.
Two additional 1 MiB inputs use `random.Random(seed).choices` over the
same vocabulary with seeds 42 and 99.

Seven rotating batches of 250 encodes, three warmups per process, reused
state/output, checksum enabled, concurrency 1, median decimal MB/s. Same
compiler/reference versions as above. File IO/startup are excluded, and
no tests, builds or profiling ran concurrently with timing.

| Input | Before / GCC | After / GCC | Go | Goose bytes | Go bytes |
|---|---:|---:|---:|---:|---:|
| Original 256 words | 260.7 | 291.2 | 283.9 | 220915 | 236740 |
| 256 words, seed 42 | 260.6 | 290.4 | 284.3 | 220977 | 236739 |
| 256 words, seed 99 | 260.4 | 288.8 | 284.1 | 221182 | 236574 |

This meets the parity target on these screening cases: throughput rises
about 11% while the output stays byte-identical and 6.5–6.7% smaller than
Go's. This is not a general natural-language performance claim.

A three-batch broader screen (200 encodes/batch) also retained identical
bytes on both C backends:

| Input | Before / GCC | After / GCC | Before / MSVC | After / MSVC |
|---|---:|---:|---:|---:|
| 256 words | 261 | 289 | 208 | 239 |
| Sources | 1472 | 1552 | 925 | 951 |
| Five-word corpus | 426 | 432 | 336 | 338 |
| Random | 3291 | 3434 | 2340 | 2398 |
| Zeros | 8021 | 8002 | 2921 | 2921 |
| Executable | 395 | 437 | 346 | 381 |

The roughly 0.2% zero-input difference is within normal variation; no
material regression was observed in this screen. MSVC still trails Go
on the large-word corpus. A variant without first-byte rejection reached
about 303 MB/s with GCC but regressed two MSVC cases by 2–3%, so it was
not kept. Removing the per-position length clamp did not improve speed
and was reverted.

The before-profile attributed 45.6% of 9646 leaf-symbol samples to
compress_block, 12.0% to match_at, 22.8% to encode_sequences and 10.6%
to the bit writer. Inlined work belongs to the containing function.
The final profile collected 8007 samples: compress_block 48.4%, match_at
4.2%, encode_sequences 26.3% and the bit writer 10.8%. These are leaf-symbol
percentages, not absolute function timings or call counts. Sampling runtimes
are separate from throughput measurements.

Local raw samples and hashes are in ignored `build/zstd-bench/`:
`v256-final-results.json`, `v256-broad-final.json` and the before/after
profiles. The retained source changes use no C helper or unchecked memory
access.

## Repeating a Goose measurement

From the repository root, create `build/archiver/`, then on Windows:

```powershell
goose build archiver/bench_zstd.goose --cc C:/msys64/ucrt64/bin/gcc.exe -o build/archiver/bench_zstd.exe
./build/archiver/bench_zstd.exe reuse INPUT.bin 250 build/archiver/output.zst
```

Choose an installed C compiler with `--cc`; omit it to use Goose's default.
The harness reads once, warms up three times and times only repeated codec
calls. `c` creates encoder tables per call, `reuse` keeps an EncCtx, and
`d` decodes. Decoder MB/s uses the regenerated byte count. Repeat whole
process runs, keep input bytes fixed, and report both throughput and size.

## Validation

- `zstd_test.goose --debug`: 138336 prefix comparisons, mismatch bit
  positions, overlapping ranges and 4352 short RLE round trips.
- klauspost master: 80 checks in each of Release and Debug; both DecodeAll
  and its streaming reader check Goose output, and Goose reads all four
  Go encoder levels.
- Official libzstd 1.5.7: 95 checks in each mode, including malformed
  frames and caller output limits.
- Native 7z writer/reader tests pass in both modes.
- The match-probe follow-up additionally cross-checked 217 short,
  unaligned, mismatch and block-tail inputs against the pre-change encoder
  byte-for-byte and independently decoded them with Go. The verifier corpus
  includes durable word-prefix and multi-block tail cases.

The independent verification scripts and their build commands are listed
in AGENTS.md. Downloaded references, binaries, profiler traces and local
raw timing samples stay under ignored `build/`.

## Levels 4-12: where the time goes, and a row finder that did not help (2026-10-25)

Hash-chain levels (lazy parsing, 5-byte hash). Windows x64, MSVC 19.44, 1.3 MB source text,
2 MB executable, 1 MiB word corpus; speeds are in-process medians from `bench_zstd_levels.py`.

A sampling profile (a thread-suspending sampler over a `-g -fno-inline` gcc build, resolved with
addr2line) put 93-98% of the time in the parse and under 3% in block writing. Inside the parse,
57% was the chain walk, whose loads depend on one another (`data[cand + len]` 26%, `prev[cand]` 14%,
`head[h]` 9%) and 12% was insertion. Trying all three repeat offsets at every probe cost 10-25%.
Not helpful: stopping the walk at a nice length (no change), smaller hash or chain tables (no
change), loading eight bytes before building slices (no change).

Kept: the level table in `compress_level` (4 to 128 candidates, one repeat offset up to level 6),
which matches libzstd's density per level. Level 12 on the word corpus went from 0.8 to 5.4 MB/s.

Tried and dropped: replacing chains by rows of 16-128 slots, indexed by the 5-byte hash, each slot
holding a 32-bit tag and the position (as libzstd's row finder, with a scalar scan instead of SIMD).
Round trips were exact, but at the same candidate counts the output grew 1-2% (4% on the words,
since a row mixes several strings) and speed fell by 10-30% on text and executables (level 6 text
37 -> 33 MB/s, level 12 executable 15 -> 9.5 MB/s). The scan of 15-127 tags per probe costs more than
the few chain hops it replaces. A SWAR tag compare over a separate byte array might change this;
it was not tried.

## Two-thread pipeline at levels 1-3 (2026-10-25)

`zstd_pipe.goose` (`compress_pipelined`) parses on the calling thread and entropy-codes on a worker: the
worker gets the input once, rebuilds each block's literals from the sequences it receives, writes the
blocks and the checksum, and returns the frame body. Goose workers share no memory, so every block crosses
a queue by copy. The parse assumes every block is written compressed; when the worker writes one raw, the
decoder's repeat-offset history stays behind the parse's, and the worker re-expresses the following
sequences against its own history. The module is separate because a `thread_fn` anywhere in an imported
module makes `goose run` (the in-process backend) refuse the program.

Output is byte-identical to `compress_level` on the corpus (including a file with raw blocks interleaved);
with raw blocks forced on every third block, single-thread and pipelined outputs both decode with libzstd
and differ by a few bytes.

Result: it does not pay. Clang build, level 3, wall-clock MB/s, medians of 9 alternating runs, spawn and
input copy included, machine otherwise idle; libzstd 1.5.7 through Python, one thread (`nbWorkers` 0).
The one-thread column comes from `bench_zstd`, the two-thread column from `bench_zstd_pipe`:

| Input | ours 1 thread | ours 2 threads | libzstd 1 thread |
|---|---:|---:|---:|
| source text 1.3 MB | 174 | 146 | 211 |
| executable 2 MB | 166 | 152 | 196 |
| words 1 MB | 330 | 277 | 333 |
| Python sources 4 MB | 234 | 211 | 281 |
| DLL 3 MB | 150 | 148 | 179 |
| mixed 14 MB | 176 | 176 | 214 |

Two threads are 0.84-1.00 times the one-thread speed. A parse-only run reaches 217 MB/s on the mixed
input; a worker that only drains the messages already leaves the parsing thread at about 193 MB/s
(building the message, copying 14 MB of input and about 18 MB of sequences), and the working worker costs
more again. Another effect distorted the first measurement: the same one-thread code runs about 10% slower
in a program that imports a module with a `thread_fn` (176 against 158 MB/s on the source text, probably
thread-local data stacks), so a one-thread baseline taken from a program that links the pipeline flatters
it. That is why the benchmark is split in two programs. The module stays as an opt-in, used by nothing else.

## EXE/DLL: cached prefixes and five-byte short hashes (2026-10-25)

The retained change targets levels 1-3. Kept contexts store position + base in the low 32 bits of each
u64 entry and the first four input bytes in the high 32 bits. A short candidate is checked without
following its position back into the input; long candidates reject a mismatching cached prefix before
reading the full eight bytes. The short hash now covers five bytes, and the skip grows by byte distance
shifted by seven, as in klauspost's default. Repeat lookahead reuses bytes 1..4 of the current word;
a matching word is extended by XOR/ctz before calling the general suffix matcher. All source is Goose.

A sampling profile on the preceding Clang build attributed about 73% of leaf samples on both EXE and
DLL to the parse (including work inlined into encode_frame), 21-22% to block/entropy writing, 3-4% to
match_at and under 1% to xxh64. The largest hotspots were the dependent loads of table candidates and
the input words they address. These are sample shares, not absolute function timings.

**GCC 15.2.0 is the faster backend for this revision.** Windows x64, Go 1.25.7, the same pinned klauspost
source as the earlier comparison (7cfdd8f), SpeedDefault, CRC enabled, one thread, reused contexts and
output. Three warmups; medians of seven alternating batches of about 0.16 s. File IO and process startup
are outside each timer. Before/after below both use GCC; do not confuse this with the earlier Clang
comparison. The table includes four full PE files in addition to the original EXE/DLL prefixes.

| Input | before MB/s | after MB/s | Go MB/s | after / Go | output vs Go |
|---|---:|---:|---:|---:|---:|
| EXE, 2 MB | 154.8 | 191.0 | 186.3 | +2.5% | -1.20% |
| DLL, 3 MB | 139.6 | 176.4 | 168.7 | +4.5% | -0.90% |
| Full Goose EXE, 4.26 MB | 155.9 | 196.1 | 192.4 | +1.9% | -1.19% |
| Full Python DLL, 6.78 MB | 185.2 | 234.5 | 227.0 | +3.3% | -1.28% |
| ntdll.dll, 2.03 MB | 156.3 | 194.5 | 189.6 | +2.6% | -1.20% |
| KernelBase.dll, 3.11 MB | 194.8 | 237.4 | 223.7 | +6.1% | -0.93% |

On these six files the same-backend gain is 22-27%, with a 2-6% lead over Go. Compressed size grows
0.7-1.9% from the preceding Goose version, while remaining 0.9-1.3% smaller than Go. Changing the hash
and skip changes the parse and compressed bytes; caching a prefix by itself does not.

The broader GCC screen kept the previous word wins: small words 498.7 vs Go 423.5 MB/s, 256 words 325.3
vs 280.4 MB/s. Mixed input reaches 210.7 vs 200.8 MB/s; random input is still behind, 3460 vs 6602 MB/s.
Zeros are effectively tied at 8.0 GB/s. The word cases improve about 3% from the preceding GCC build.

Fresh calls retain compact u32 tables, through the same generic parser, to avoid zeroing an extra
768 KiB on every call. Measured fresh-call GCC gains are 19% on EXE and 20% on DLL; 256 words gain 4%.
The fresh random case regresses 6%. With Clang the retained version improves kept EXE/DLL throughput
about 12-14%, but remains behind Go and its fresh random/word cases regress about 11%/9%. Compiler and
API mode are part of these results; this is not a universal speedup.

Logical full-size table storage: 768 KiB for fresh calls, 1536 KiB for EncCtx (formerly 768 KiB).
Separately, three whole-process runs on the 3 MB DLL, 40 encodes with a kept context, measured median
peak working set 10.61 -> 13.00 MiB and sampled peak private commit 17.16 -> 19.16 MiB.
Those process figures include input/output, runtime and scratch; they are not the table sizes.

Validation: 171 level/corpus cases in each of Release and Debug; 80 klauspost and 95 libzstd checks in
each mode; 51 fresh/reused-context comparisons, including changed sizes/prefixes, block boundaries and
an epoch reset; the existing 138336 prefix and 4352 short RLE checks; native 7z tests in both modes.
The native codec tests also pass as MSVC executables in Release and Debug. All 13 benchmark corpora
produce identical bytes with fresh and kept tables, and their kept frames decode with Go and libzstd.
The opt-in pipeline still passes 18 sequential interoperability cases; its known concurrent-call
queue issue is outside this change.

Reproduce the kept-context build:

```powershell
goose build archiver/bench_zstd.goose --cc C:/msys64/ucrt64/bin/gcc.exe -o build/archiver/bench_zstd.exe
./build/archiver/bench_zstd.exe reuse INPUT.bin 100 build/archiver/output.zst
```

Raw samples, input/executable/source hashes and rejected probes remain under ignored
`build/zstd-bench/`: `exe-dll-retained-gcc-full-results.json`,
`exe-dll-retained-gcc-oneshot-results.json`, `exe-dll-retained-results.json` (Clang),
`exe-dll-retained-oneshot-results.json`, `exe-dll-memory-results.json`, and
`exe-dll-profile-before.json` / `exe-dll-profile-ip.json`. Small first-byte prechecks, packed six-bit
tags, four-byte flush batching and redundant match-limit removal did not improve this workload
and were discarded.
