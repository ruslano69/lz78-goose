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
