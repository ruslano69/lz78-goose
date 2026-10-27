# Zstd performance notes (2026-10-25)

Detailed sampling of the current level-3 parser on ordinary prose is in
[PROFILE-TEXT-2026-10-26.md](PROFILE-TEXT-2026-10-26.md): hash/table work is
50–55% of parser samples; short-candidate/lookahead work is another 16–20%.
These are operation-cluster sample shares, not libzstd-relative function timings.

The subsequent memory-layout and nonlocal-return experiments, including the
retained Huffman decoder reservoir (+16–17% on EXE/DLL with GCC 15.2), are
in [ZSTD-MEMORY-2026-10-26.md](ZSTD-MEMORY-2026-10-26.md).
The decoder follow-up and modest additional gains from decoded FSE entries
are in [ZSTD-DECODER-2026-10-26.md](ZSTD-DECODER-2026-10-26.md).

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

## Adaptive chain insertion after long literal runs (2026-10-26)

The levels 4..12 parser already increases its search step after unsuccessful
probes, but `chain_insert` still hashed every skipped byte. On incompressible
input, dense insertion defeated most of that acceleration. After more than
4096 pending literal bytes, the parser now inserts only the last position of
each skipped gap. It continues probing throughout the block, so compressible
suffixes are still discoverable. Matches reset the pending literal distance;
matched ranges and ordinary short gaps retain dense insertion. No early raw
decision is made and repeat-offset commit/rollback remains in `emit_block`.

Windows x64, GCC 16.1.0, Goose `-O2`, baseline repository `633c3eb`.
Five alternating before/after batches, three in-process warmups; inputs read
once and file IO/startup outside the timer. Both sides use fresh-call `c`
mode, including table initialization; 15 encodes per batch, five for words.
Raw inputs, every sample, frames and source/binary hashes are under ignored
`build/zstd-incompressible/` (`screen.py`, `screen.json`, `manifest.json`).
Tests and builds did not overlap this timing series.

| Input | Level | Before MB/s | After MB/s | Gain | Before bytes | After bytes |
|---|---:|---:|---:|---:|---:|---:|
| Random 1 MiB | 6 | 115.8 | 889.5 | 7.68x | 1048617 | 1048617 |
| Random 1 MiB | 12 | 112.3 | 856.9 | 7.63x | 1048617 | 1048617 |
| Mixed raw/text/repeated raw | 6 | 151.6 | 205.8 | 1.36x | 131173 | 131173 |
| Mixed raw/text/repeated raw | 12 | 146.0 | 197.4 | 1.35x | 131173 | 131173 |
| Repeated random block | 6 | 118.9 | 133.0 | 1.12x | 131173 | 131173 |
| Late repetitive suffix | 6 | 614.9 | 997.7 | 1.62x | 90040 | 90745 |
| Sparse repeat islands | 12 | 115.8 | 164.6 | 1.42x | 328480 | 328890 |

Density trade-off: the constructed late-suffix level-6 case grows by 705
bytes (0.78% of its previous archive size), and sparse islands by about
0.12%; fewer inserted positions can miss useful matches. The corpus's
sources, repeated fixture text, words, zeros and EXE retain identical bytes.
Their level-6/12 throughput differences were within about 3%; this small
screen does not establish gains on them. Levels 1..3 and 13..19 are unchanged.

The previous libzstd 1.5.7 GCC comparison measured random input at 2524 MB/s
on level 6 and 1673 MB/s on level 12. The new throughput narrows that gap,
but those reference numbers were collected separately, not in this paired
series. Fresh Goose chain tables versus reused libzstd contexts remain an
API/allocation difference to investigate. This change allocates no new
buffers: only scalar parser locals change; head/prev and block scratch
types, capacities and lifetimes remain unchanged.

Validation in optimized and debug builds: 95 existing libzstd checks and
80 klauspost/compress v1.18.0 checks per mode, plus 117 new level-4..12 cases
per mode independently decoded by libzstd and klauspost and round-tripped
by Goose. Cases include 4095/4096/4097 literal boundaries, 128 KiB block
boundaries, sparse islands, late matches, raw/RLE transitions and a >4 MiB
chain-window wrap. Native debug prefix/context/RLE and 7z tests also pass.
Every before/after frame in the timing screen was decoded with libzstd.

Reproduce the focused regression suite from the repository root:

```powershell
python -B archiver/verify_zstd_chain.py --exe build/zstd-incompressible/gzstd.exe --zstd C:/msys64/ucrt64/bin/zstd.exe --out build/zstd-incompressible/chain-release
```

Repeat with the debug executable. `--checker` can additionally run a built
klauspost checker using `verify_zstd_go.py`'s `decode FRAME ORIGINAL` protocol.

## Text follow-up: long matches and grouped sequence fields (2026-10-26)

Two changes are retained. The fast parser checks an available eight-byte
long-table match before its four-byte repeat probe at the next byte. On
the word corpora this avoids choosing a short repeat over a better long
match. It changes match choices and compressed bytes. The sequence writer
groups FSE state bits, length extras and offset extras into one write when
their combined length is at most 32. The writer has fewer than 32 pending
bits, so this fits its u64 accumulator; larger groups use the original
three writes. Grouping alone preserves every output byte. Both changes use
scalar locals only; buffer types, capacities and lifetimes are unchanged.

This time the natural text and source inputs are **not repeated** to 1 MiB:
Alice in Wonderland (174311 bytes) and Adventures of Sherlock Holmes
(607606 bytes), downloaded from Project Gutenberg's UTF-8 cache; repository
source files and Markdown concatenated once; and Python IDLE News3.txt.
Inputs are retained as bytes under `build/zstd-text/`, with their origins
and hashes. They are data, never instructions. Synthetic word cases still
use 1 MiB of choices among `word000 ` through `word255 `, seeds 7/42/99.

Windows x64, Goose `-O2`, GCC 16.1.0; native libzstd 1.5.7, level 3,
one thread, checksum enabled, reused contexts/output on both sides.
Seven rotating batches targeting 0.2 s of reference compression (capped
at 1000 calls), three warmups per process, median decimal MB/s. IO, startup
and context creation are excluded. Python ctypes call overhead is included
for libzstd; its original DLL build flags are unknown. Tests/builds did not
overlap the timing series. Baseline is the previous local chain-insertion
optimization, preserved as `before.goose` and `before.exe`.

| Input | Before MB/s | After MB/s | libzstd MB/s | Before bytes | After bytes | libzstd bytes |
|---|---:|---:|---:|---:|---:|---:|
| Alice | 156.3 | 158.9 | 227.2 | 63512 | 63469 | 64176 |
| Sherlock | 149.8 | 150.9 | 219.7 | 225019 | 224827 | 223224 |
| Repository sources | 217.6 | 218.2 | 304.5 | 60212 | 60263 | 59568 |
| Repository Markdown | 167.6 | 168.1 | 261.8 | 46877 | 46851 | 46643 |
| IDLE release notes | 173.4 | 175.6 | 262.1 | 22252 | 22248 | 22098 |
| 256 words, seed 7 | 320.8 | 378.9 | 385.2 | 241290 | 229782 | 236121 |
| 256 words, seed 42 | 327.4 | 384.4 | 382.9 | 241029 | 229567 | 236217 |
| 256 words, seed 99 | 324.3 | 377.3 | 383.4 | 241022 | 229831 | 235966 |
| Random | 5129.5 | 5100.6 | 3926.4 | 1048617 | 1048617 | 1048613 |
| Benchmark EXE | 116.8 | 115.1 | 266.3 | 141914 | 142009 | 140232 |
| Zeros | 8337.7 | 8409.2 | 5031.0 | 49 | 49 | 54 |

The synthetic word cases improve 16-18% and shrink 4.6-4.8% from the
previous Goose version; they approach libzstd speed while producing
2.6-2.8% fewer bytes. This is **not a general natural-text speedup**:
the prose/documentation differences are only 0-2%, not a material win.
libzstd remains about 1.4-1.6x as fast there. Source output grows 51 bytes
(0.085%); the EXE grows 95 bytes (0.067%) and is 1.5% slower in this series.

A separate phase-timing harness over the baseline put 77-79% in parsing,
21-23% in block/entropy emission and about 1% in the checksum on the prose,
source and documentation cases. These are coarse phase timings in a
separate harness, not sampled instruction shares or production timings.
The remaining natural-text gap is chiefly in parsing, not table sizing.

Separate five-batch screens: fresh-call GCC words improve 289 -> 367 MB/s;
ordinary prose/docs vary from roughly -3.4% to flat. MSVC 19.44 words improve
228 -> 249 MB/s, while prose/docs range from -2.1% to +0.8%; its random and
EXE cases regress about 3%. Compiler/API mode must accompany claims; no
universal speedup is claimed. GCC remains the recommended measured backend
for this workload, rather than interpreting these results as language speed.

Rejected probes are retained only under ignored `build/`: skipping empty
literal appends, direct single-byte literals, pre-sizing sequence output,
smaller active tables, combined repeat-offset updates, rejecting short
ordinary matches, wider cached tags and reusing repeat words. They produced
no broad natural-text gain or worsened density/other inputs. The grouped
writer and long-match preference were screened separately before combining.

Validation in optimized/debug builds: 95 existing libzstd checks and 80
klauspost/compress v1.18.0 checks per mode, plus 73 text/sequence cases per
mode read by libzstd, klauspost and Goose. These include UTF-8, shared
prefixes, wide fields, raw/text transitions and 128 KiB tails. Fast outputs
agree between fresh/reused contexts; higher-level outputs match the prior
encoder byte-for-byte, isolating the writer change. Native debug prefix,
context, RLE and 7z tests pass; five opt-in pipeline frames independently
decode with libzstd. Every timed output is also independently decoded.

Raw evidence: `build/zstd-text/results-before-final.json`,
`fresh-results-before-final.json`, `results-before-msvc-final-msvc.json`,
`manifest.json`, fixed inputs and all candidate screens. Reproduction
drivers are `bench-final.py` and `bench.py` in that directory. The durable
regression suite, from the repository root, is:

```powershell
python -B archiver/verify_zstd_text.py --exe build/zstd-text/gzstd.exe --zstd C:/msys64/ucrt64/bin/zstd.exe --out build/zstd-text/check-release
```

Repeat for the debug CLI. Optional `--bench`, `--before-bench` and
`--checker` add fresh/reused, old-writer byte equality and klauspost checks.

## Folded unsigned hash shifts (2026-10-26)

Following the detailed text profile, fast hashing now applies one right
shift to the unsigned product instead of shifting, converting to i64 and
shifting again. The parser precomputes `47 + lshift` and
`64 - HASH_BITS_ZSTD + hshift` outside its hot loop; `dfast_put` uses the
same expressions. Existing callers use lshift 0..7 and hshift 0..6, so the
old intermediate was nonnegative. Converting only after the combined
unsigned shift preserves every hash index, candidate, sequence and byte.
This does not change the matcher strategy, table sizes or allocation.

Baseline is the preceding local text optimization, source SHA-256
`37c13829c87108033e9dbe8d1a74b78c4419eb5814d251897c75cc881dcd3d7b`;
the retained source is
`159ec5037a393fa73b15ed67514b8be5702b1bba278763b0395e448ccddf8120`.
Exact inputs are the preceding non-repeated text corpus and controls.
Seven rotating batches, three warmups, reused context/output, level 3,
one thread with checksum enabled. IO/startup are excluded. GCC 16.1.0
and MSVC 19.44 are measured separately; tests/builds did not overlap timing.

| Input | GCC before MB/s | GCC after MB/s | MSVC before MB/s | MSVC after MB/s |
|---|---:|---:|---:|---:|
| Alice | 160.9 | 163.1 | 122.9 | 126.9 |
| Sherlock | 155.7 | 156.3 | 121.4 | 124.6 |
| Sources | 221.0 | 221.3 | 167.3 | 170.3 |
| Markdown | 168.7 | 172.4 | 129.7 | 132.7 |
| IDLE notes | 174.7 | 178.0 | 131.5 | 132.4 |
| Words, seed 42 | 376.8 | 385.2 | 252.1 | 262.0 |
| Words, seed 99 | 383.4 | 388.7 | 249.3 | 257.9 |
| Words, seed 7 | 380.3 | 391.4 | 254.8 | 257.0 |
| Random | 4907.3 | 4846.5 | 2964.7 | 2996.7 |
| Benchmark EXE | 115.3 | 117.1 | 89.8 | 91.1 |
| Zeros | 8290.5 | 8342.3 | 2768.0 | 2778.5 |

This is a small improvement, not closure of the natural-text gap. On GCC,
ordinary prose/source differences are 0-1.4% and should be treated cautiously;
Markdown/notes improve about 2%, synthetic words about 1-3%. MSVC prose
improves about 3% (all seven paired Alice samples, six of seven Sherlock
samples were faster). Reused GCC random is 1.2% slower in this series;
its paired differences ranged from -7% to +7%, so no reliable random-data
gain or loss is established. Uniform RLE data does not execute the changed
hash code. The remaining natural-text deficit against libzstd persists.

A separate five-batch fresh-call GCC screen gave about 1-3% on most text
inputs, with unchanged bytes. Raw/RLE screening variation is not presented
as a universal improvement. Raw samples and reference libzstd measurements
remain in `build/zstd-shifts/results-before-after.json`,
`results-before-msvc-after-msvc.json` and `fresh-results-before-after.json`.

An isolated adaptive-lookahead probe was rejected: a saturating hit score
sampled only one in eight lookaheads after poor recent success. Alice,
Sherlock and Markdown streams grew 1.4-1.7%, while throughput remained
roughly flat. Fewer probes also lose useful matches and add bookkeeping;
profile heat alone does not establish that skipping them is profitable.
That code exists only under ignored `build/zstd-shifts/adaptive/` and is
not part of the library.

Validation: 264 before/after fresh/reused Release/Debug frames across 44
inputs are byte-identical and decode with libzstd. Cases include every
table-size boundary from 512 through 131072, small tails and the fixed text
corpus. Both modes additionally pass 95 existing libzstd, 80 klauspost and
73 text/sequence checks. Native debug prefix/context/RLE checks and native
7z tests pass; ten before/after opt-in pipeline frames decode independently.
No new buffers or retained state are introduced. Exact source/executable
hashes, corpus bytes and scripts are under `build/zstd-shifts/manifest.json`
and that directory.

## Next-candidate loading experiment (2026-10-26)

An isolated Goose parser variant computes the next failed-search position,
loads its word, computes both hashes and reads both table entries before
testing the current candidates. On a failed search these values are carried
to the next iteration; after a match they are discarded. Reads follow the
current position's table writes, preserving collisions and match choices.
This is early ordinary loading, not a hardware prefetch instruction.

Two alternatives were screened: early loading only for the p+1 long-table
lookahead, and reusing the full pipeline's cached values for that lookahead.
Neither removed the workload regressions. All variants remain under ignored
`build/zstd-prefetch/`; the library retains its previous parser.

Seven rotating batches, reused context, level 3, checksum enabled, medians
in MB/s (same fixed corpus as the preceding section):

| Input | GCC baseline | GCC pipeline | MSVC baseline | MSVC pipeline |
|---|---:|---:|---:|---:|
| Alice | 160.2 | 168.7 | 125.8 | 130.7 |
| Sherlock | 155.0 | 160.8 | 124.6 | 128.4 |
| Markdown | 168.0 | 174.9 | 129.9 | 135.0 |
| IDLE notes | 177.2 | 180.0 | 132.5 | 134.2 |
| Words, seed 42 | 375.3 | 357.8 | 258.9 | 241.5 |
| Words, seed 99 | 389.0 | 355.1 | 256.7 | 239.1 |
| Words, seed 7 | 384.4 | 364.7 | 258.6 | 243.7 |

The GCC series overlapped a short correctness check during the first two
inputs; separate five-batch screens also showed prose gains and word-data
regressions. The MSVC series ran after those checks. Timing variation does
not justify a universal speed claim. In particular, speculative work on
successful probes adds cost; early table loading alone does not reproduce
the complete libzstd search pipeline or close the text performance gap.

Validation: the full pipeline passes compiler checks and 264 byte-exact
fresh/reused Release/Debug comparisons across 44 inputs, including table-size
boundaries, tiny tails and block transitions. Baseline frames also decode
with libzstd. All timed variant outputs match baseline bytes and decode
independently. Baseline source SHA-256 remains
`159ec5037a393fa73b15ed67514b8be5702b1bba278763b0395e448ccddf8120`.
Scripts, experimental sources, binary hashes and raw timing samples are in
`build/zstd-prefetch/` (`manifest.json`, `results-*.json`, `byte-checks.json`).

## Cached Huffman bit window (2026-10-27)

The Huffman literal decoder keeps an eight-byte window while consecutive
backwards reads remain inside it. A refill loads a word starting up to four
bytes before the requested position; stream ends and past-end positions use
the original reader. Only scalar state is added. The table lookup, output,
invalid-entry handling and final position check are unchanged.

Seven alternating paired batches, three benchmark warmups per process, GCC
16.1.0 `-O2 -g` standalone, one thread, I/O outside the timer. Frames are
from zstd CLI level 3 and contain the same source bytes for both variants.
Each timed result was compared byte-for-byte with its input. The three EXEs
were built from this project; the benchmark EXE includes debug symbols.

| Input | Before MB/s | After MB/s | Change |
|---|---:|---:|---:|
| benchmark EXE | 361.6 | 377.7 | +4.5% |
| gzstd EXE | 407.9 | 419.7 | +2.9% |
| g7z EXE | 377.6 | 398.1 | +5.4% |
| repeated sources | 2251.7 | 2294.4 | +1.9% |
| synthetic words | 713.8 | 713.3 | −0.1% |
| random | 10609.6 | 10630.9 | +0.2% |
| zeros | 13169.8 | 13223.2 | +0.4% |

This is a small single-machine screen, not a universal speed claim; the EXEs
are related. The raw/RLE cases do not establish a change in Huffman throughput.
All samples and exact frame hashes are in ignored `build/zstd-huf-opt/screen.json`;
the standalone baseline, candidate and driver are retained beside them.

Validation: compiler checks, native debug tests including a direct comparison
with the original reader across 1–11 bit tables, short streams, cache refills,
invalid table entries and overrun; 95 libzstd interoperability/refusal checks
and 80 klauspost/compress v1.18.0 checks in each of optimized and debug modes;
73 text/sequence cases in each mode checked with libzstd and klauspost.

## Interleaved four-stream Huffman decoding (2026-10-27)

Four-stream literal sections now decode their streams in one unrolled loop on
one thread. Each stream has its own bit reader and cached word; its symbols
are written into its own portion of the grow-only literal buffer. The buffer
is extended once for the declared literal size; no four complete temporary
outputs are allocated. Short streams still use the existing bit-reader
fallback, and invalid streams return failure with output discarded by callers.

An indexed four-stream prototype had no consistent benefit. The unrolled
version was compared with the preceding Huffman-window implementation using
the same libzstd-produced frames, GCC 16.1.0 `-O2 -g`, standalone, two
independent alternating series (five and nine pairs, three warmups). File I/O
and process startup are outside the timed region. The table is the medians of
the nine-pair confirmation; every result was compared to the original input.

| Input | Level | Before MB/s | After MB/s | Change |
|---|---:|---:|---:|---:|
| gzstd EXE | 3 / 19 | 418.1 / 364.5 | 435.2 / 374.3 | +4.1% / +2.7% |
| g7z EXE | 3 / 19 | 396.0 / 345.0 | 424.2 / 355.1 | +7.1% / +2.9% |
| Sherlock | 3 / 19 | 453.0 / 552.4 | 471.4 / 561.6 | +4.0% / +1.7% |
| Sources | 3 / 19 | 560.1 / 625.2 | 576.3 / 637.6 | +2.9% / +2.0% |
| 256 words | 3 / 19 | 707.8 / 378.5 | 731.6 / 392.1 | +3.4% / +3.6% |
| Random | 3 / 19 | 10662.2 / 10595.5 | 10692.5 / 10683.1 | +0.3% / +0.8% |

This is a local corpus/compiler result; it does not identify hardware-resource
contention. The indexed and unrolled prototypes also differ in output and
control details, so their timing difference cannot be attributed to one cause.
Raw samples, inputs, sources and binaries remain under ignored
`build/zstd-huf4-unrolled/` and `build/zstd-decode-levels/`.

Validation: 8046 native debug comparisons of four-way against sequential
Huffman decoding with uneven splits, small streams, invalid entries and
overruns; native context/prefix and 7z checks. Optimized and debug prototypes
passed 95 libzstd interoperability/refusal and 80 klauspost/compress v1.18.0
checks each. The final optimized and debug CLIs passed 73 text/sequence cases
each with both independent decoders; 304 truncated or mutated libzstd frames
were rejected by the old, optimized and debug decoders alike.

## Combined sequence output limit check (2026-10-27)

The sequence decoder checks the combined literal and match lengths against
the remaining block/caller limit before writing either part. The separate
second check after copying literals is no longer needed. The invalid-offset
and literal input checks remain; as before, callers discard any partial
output on failure. The valid lengths are bounded by the Zstd code tables,
and the enclosing decoder limits the output end to at most 2^62 bytes.
No buffers, code tables or encoded bytes change.

Windows x64, GCC 16.1.0 `-O2 -g`, Goose `-O2`, standalone; nine alternating
pairs, three warmups, same libzstd frames, no I/O or startup in the timer.
Every output was compared with the original. Medians in decimal MB/s:

| Input | Level | Before | After |
|---|---:|---:|---:|
| gzstd EXE | 3 / 19 | 478.6 / 371.6 | 486.8 / 382.4 |
| g7z EXE | 3 / 19 | 472.2 / 349.7 | 479.8 / 362.5 |
| Sherlock | 3 / 19 | 462.8 / 562.4 | 474.1 / 575.1 |
| Sources | 3 / 19 | 567.3 / 624.3 | 592.1 / 638.4 |
| 256 words | 3 / 19 | 723.4 / 421.4 | 729.9 / 418.9 |
| Random | 3 / 19 | 10551.3 / 10499.1 | 10535.6 / 10508.4 |

The first five-pair screen showed a similar small gain on text and EXE.
These are single-machine/compiler measurements; small differences on words
and random data are not evidence of a consistent change. All individual
samples and hashes are under ignored `build/zstd-seq-onecheck/`.

Validation: 95 libzstd and 80 klauspost/compress 1.18.0 interoperability
checks in each optimized/debug prototype; 73 text/sequence cases in each
final build, independently checked with both decoders. Native debug Huffman,
prefix and reused-context tests, native 7z tests, and compiler checks pass.
The new `verify_zstd_limits.py` performs 48 output-limit checks per build on
compressed blocks without a frame content size, verifies that they contain
sequences, and checks preservation of the destination on refusal. The two
final builds also matched the previous decoder on 304 mutated/truncated frames.

Other isolated screens were rejected: our precomputed FSE entry variants in
per-block or retained tables did not improve this corpus, and emitting short
literals or matches byte by byte slowed several inputs. The separately
instrumented debug decoder counted 12683 sequences on the level-3 sources
block, 9584 with no literals, and 7273 matches of at most eight bytes; such
frequency alone did not make byte-at-a-time copying profitable. The counted
outputs matched the reference bytes. Experimental scripts/results remain in
`build/zstd-seq-{precalc,stored,smalllit,smallmatch,counts}/`.

## Combining independent decoder work (2026-10-27)

The Huffman X2 and output-limit changes above were developed independently of
`bd980af` and `34a6492`. After integration, the upstream bit-reservoir reader
is retained for one-stream Huffman; four-stream X2 and the combined output
check are retained alongside the upstream per-block predecoded FSE entries.
Earlier before/after tables describe the individual versions tested, not a
measurement of their combined gains.

Five rotating batches, three warmups, GCC 16.1.0 `-O2 -g`, Goose `-O2`,
identical libzstd frames; all outputs verified. Medians in MB/s. `ours` is
the independent decoder before integration, `upstream` is 34a6492, and
`combined` includes both. Startup and I/O are excluded.

| Input | Level | Upstream | Ours | Combined |
|---|---:|---:|---:|---:|
| gzstd EXE | 3 / 19 | 447.1 / 376.0 | 491.5 / 385.4 | 485.2 / 374.0 |
| g7z EXE | 3 / 19 | 437.8 / 354.7 | 484.8 / 362.4 | 474.9 / 355.4 |
| Sherlock | 3 / 19 | 466.0 / 564.8 | 470.0 / 574.5 | 473.7 / 565.7 |
| Sources | 3 / 19 | 583.7 / 630.0 | 599.4 / 649.6 | 589.7 / 622.4 |
| 256 words | 3 / 19 | 729.9 / 386.3 | 732.0 / 420.6 | 718.6 / 418.7 |
| Random | 3 / 19 | 10525.5 / 10598.2 | 10469.1 / 10642.2 | 10557.0 / 10605.8 |

These are screening measurements on one machine; small differences need
further investigation and cannot be attributed to a single change. Raw
samples, input hashes and binaries are under `build/zstd-merge-comparison/`.

The combined decoder passed 59400 independent scalar Huffman checks, 8046
four-stream/batched checks, native prefix/context and 7z tests, and in both
release/debug: 95 libzstd, 80 klauspost, 73 text/sequence and 48 output-limit
checks. Both builds rejected 304 mutated or truncated test frames as did the
prior independent decoder. Partial output on failure remains unspecified.
