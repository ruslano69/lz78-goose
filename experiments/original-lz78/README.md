# Learning Goose with LZ78

An original, small binary-file compressor/decompressor written in Goose.
The goal is practice with the language, not a production archive format.

## Build and run

Requires Goose, its standard library and a C compiler for the native build.
From the lz78-goose repository root:

```powershell
goose check experiments/original-lz78/lz78.goose
goose build experiments/original-lz78/lz78.goose -o build/lz78.exe
./build/lz78.exe c input.txt output.lz78
./build/lz78.exe d output.lz78 restored.txt
python experiments/original-lz78/verify.py --exe build/lz78.exe
```

The in-process TinyCC route also works:

```powershell
goose run experiments/original-lz78/lz78.goose -- c input.txt output.lz78
goose run experiments/original-lz78/lz78.goose -- d output.lz78 restored.txt
```

Historical measurements used Goose `94cc64d`; supply a Goose compiler on PATH.
Set `GOOSE_HOME` to a directory under ignored `build/` to keep its caches local.
When needed on sandboxed Windows, set `TMP` and `TEMP` to a writable workspace
directory **before the first build using that GOOSE_HOME**: this Goose revision
caches the Visual Studio environment, including its temporary paths.

Exit codes: 0 success, 1 invalid archive/file I/O/size limit, 2 bad arguments.
Destination files are written atomically, only after the codec succeeds.
An existing destination is replaced on success. Identical path strings are refused.
This is a whole-file implementation, not a streaming codec.

## What we practiced

- `const u8[:]` borrows input bytes; `u8[>..]&` appends directly to the caller's output.
- `dictionary<u64,u32>` represents trie edges with a packed `(prefix, byte)` key.
  No complete phrase strings are copied during compression.
- A lookup returns an optional reference into the dictionary. Copy its value in
  a short scope, then insert/clear after that scope: mutation cannot invalidate
  a live borrowed table slot.
- The decoder stores `Range { start:u32, length:u16 }` entries into its already
  restored output. `u8[>..]` preserves earlier bytes while growing, so a phrase
  can be appended from a slice of that same array. Parent traversal and the
  reverse buffer are eliminated.
- Widening integer conversions are implicit; intentional narrowing uses `as`.
  Unsigned 32-bit arithmetic wraps, which the checksum needs.
- Control flow is an expression, but an `if` used after `+` needs parentheses.
- Error results use a trailing `bool`; `main` handles file errors explicitly.
- Compiler/type/lifetime checks complement funcfinder mapping and guarded edits.

## Algorithm and references

Classic LZ78 starts with dictionary entry 0 = empty. If a phrase extended with
the next byte exists, keep scanning. Otherwise emit `(prefix index, byte)`,
add the extended phrase and restart from empty. At EOF an existing unfinished
phrase is emitted as an index without a new byte.

Studied reference: [aaronscode/meZip](https://github.com/aaronscode/meZip), revision
`929f9de0a20a570289ee822d813cf2425d01960f`, especially `tokenize`, `encode` and
`decompress`. Its implementation and archive format are not copied; no code or
data from that GPL project is redistributed here. Our byte-oriented implementation
and format differ, and `.mz` archives are not compatible.

Algorithm description: [LZ78 at the Prague Stringology Club](https://www.stringology.org/DataCompression/lz78/index_en.html).

## Experimental format, version 1

| Bytes | Meaning |
|---|---|
| 0–7 | ASCII `LZ78G001` |
| 8–15 | Original byte length, unsigned 64-bit little endian |
| 16–19 | FNV-1a-32 checksum of original bytes, little endian |
| 20 onward | Tagged phrase records |

A record starts with canonical unsigned LEB128 `index * 2 + has_byte`.
For `has_byte=1`, one literal byte follows; add this phrase to the dictionary.
For `has_byte=0`, emit an existing nonempty phrase and end the archive immediately.
The empty input is just the 20-byte header.

After every 65,535 added phrases, both sides reset their dictionaries to the
empty entry. No reset marker is needed because their counts are identical.
Tags fit in 17 bits (at most three bytes). Input and decoded length are limited
to 64 MiB. The decoder rejects truncated/noncanonical tags, invalid references,
misplaced final references, excess data, size mismatches and checksum failures.
FNV detects ordinary corruption; it is not an authentication mechanism.

## Verification and observations

`verify.py` uses an independent Python implementation whose dictionary stores
complete byte strings. It checks exact encoded bytes, Python decoding, Goose
decoding, fixed phrase traces, short exhaustive inputs, binary/UTF-8/repeated/random
data and multiple dictionary resets. Malformed archives must fail without
changing an existing output file. No Python dependencies are needed.

MSVC Release and Goose `--debug` builds each pass **140 byte-exact cross-checks
and 73 malformed archive rejections**. TinyCC also passes a separate file
round-trip (34,000 → 4,407 → 34,000 bytes, identical SHA-256). Examples (header included):

| Input | Original | Archive |
|---|---:|---:|
| UTF-8 repeated text | 61,000 | 7,871 |
| Repeated `A` | 1,048,576 | 4,299 |
| Repeated `abracadabra` line | 480,000 | 14,070 |
| Seeded random bytes | 524,288 | 693,314 |

Random data expands, as expected; these are size observations, not performance
benchmarks or a comparison with modern codecs. Reports and executables stay under
ignored `build/research/`.

## Timing experiment (2026-10-23)

`benchmark.py` generates a temporary Goose timing driver by replacing the mapped
main function in a copy of the codec. No production codec changes are needed.
The driver loads data before timing; each timed interval includes compression or
decompression and the codec's checksum work, but excludes input/output file I/O,
compilation, process startup, the extra result-verification checksum and printing.
Each iteration gets a fresh output buffer. Output lengths/checksums and CLI bytes
are checked outside timing. Python uses the independent codec from `verify.py`.

This table records the initial parent-chain decoder, before the range optimization
below. Each input is 1 MiB. Medians use seven measured iterations after two warmups;
Goose's native and TinyCC paths both use Goose `-O2`. The native C backend is MSVC
19.44 `/O2`; Python is CPython 3.12. Native/TinyCC sample batches are run separately;
CLI variants alternate in seeded shuffled order. No core affinity is imposed.

| Input | Goose/MSVC compress | Python compress | Goose/MSVC decompress | Python decompress |
|---|---:|---:|---:|---:|
| Repeated A | 6.002 ms | 386.255 ms | 3.926 ms | 76.990 ms |
| Repeated UTF-8 text | 8.973 ms | 241.735 ms | 4.838 ms | 77.974 ms |
| Repeated codec source | 13.811 ms | 275.606 ms | 6.403 ms | 129.902 ms |
| Seeded random bytes | 13.410 ms | 418.390 ms | 4.725 ms | 373.837 ms |

On the text case, TinyCC takes 14.185 ms for compression and 7.594 ms for
decompression, versus MSVC's 8.973/4.838 ms. This compares C backends for the same
Goose implementation. The Python comparison also changes dictionary representation
(complete byte strings versus edges/parent chains), so it is not a language-only
speed claim. These numbers are this machine's experiment, not general guarantees.

The harness separately records whole-CLI timings, including process startup,
input reads and flushed atomic output replacement, in `timings.json`. All raw
samples, medians/ranges, environment and source/binary hashes are retained under
`build/research/lz78-timing/`; `RESULTS.md` includes TinyCC for every case.

```powershell
python experiments/original-lz78/benchmark.py --prepare --exe build/lz78.exe --goose PATH/TO/goose.exe --funcfinder PATH/TO/funcfinder.exe
python experiments/original-lz78/benchmark.py --exe build/lz78.exe --goose PATH/TO/goose.exe
```

## Grow-only output range optimization

Replaced decoder parent chains and the reverse scratch buffer with ranges into
the grow-only output. Dictionary entries shrink from 13 packed bytes to 6 bytes;
the stored fields are a 32-bit output offset and a 16-bit length. The 64 MiB output
limit bounds offsets, and the dictionary block limit bounds phrase lengths.
Appending from an earlier slice is accepted by Goose's lifetime checks: output
growth preserves its storage, and previously emitted phrases remain intact.

Native MSVC paired experiment on the same retained 1 MiB inputs (10 shuffled
before/after pairs, two in-process warmups before each measured sample, tests
run separately):

| Decode input | Before | Output ranges | Speedup |
|---|---:|---:|---:|
| Repeated A | 3.586 ms | 1.006 ms | 3.57x |
| UTF-8 text | 4.861 ms | 1.047 ms | 4.64x |
| Codec source | 6.547 ms | 1.783 ms | 3.67x |
| Random bytes | 4.734 ms | 4.499 ms | 1.05x |

Compression was not changed; its small timing differences are not an optimization
claim. Long phrases benefit most; random inputs have short phrases, so eliminating
parent traversal changes little. The format and encoded bytes are unchanged.
Release and debug builds still pass 140 byte-exact cross-checks and 73 malformed
archive rejections each.

The old executable and timing driver are preserved under ignored `build/research/`.
The isolated comparison is `build/research/lz78-ranges-timing/paired.json` (raw
samples and binary hashes); an earlier run overlapping verification is retained
as `paired-during-tests.json` and is not the table's source. The reproduction script
is `build/research/compare_lz78_ranges.py`.

## Compressor memory experiments

Tested five alternatives without changing the default compressor: compact
`dictionary<u32,u32>` / `dictionary<u32,u16>` slots, `get_or_insert` with the
original slots, compact slots plus `get_or_insert`, and a dedicated grow-only
table with generation-based resets. Each experimental executable passes the
same 140 byte-exact cross-checks and 73 invalid-archive rejections.

The key needs only 24 bits (16-bit prefix ID plus byte). Packed standard-library
slots shrink from 16 bytes to 12 or 10 bytes. Narrowing saves storage, but the
10-byte stride is not uniformly faster. In 15 shuffled paired rounds on the
retained 1 MiB inputs, compact 10-byte slots take 6.164/8.832/12.698/13.336 ms
for repeat/text/source/random, versus 5.570/9.136/13.823/13.310 ms originally.
`get_or_insert` alone is not a uniform improvement either; its room check runs
even on hits. These experiments do not establish a single mechanism for every
timing difference.

The specialized table uses packed `Slot { key:u32, value:u16, generation:u16 }`
in a `Slot[>..]` array, pre-sized to 131072 entries. It has no growth/rehashing,
one probe sequence per input byte and O(1) dictionary reset by advancing the
generation. At most 1024 resets fit in the 64 MiB input limit, so a 16-bit
generation cannot wrap. This changes both layout and table management.

| Compression input | Original dictionary | Grow-only epoch table |
|---|---:|---:|
| Repeated A | 5.460 ms | 8.211 ms |
| UTF-8 text | 9.191 ms | 9.014 ms |
| Source | 14.439 ms | 10.271 ms |
| Random | 13.199 ms | 9.229 ms |

The epoch table helps source/random inputs about 1.4x, but loses on repeated A.
It always initializes 1 MiB of slots: although it halves the maximum table
storage compared with the original 16-byte slots, it uses more storage than
the original's small table on repetitive inputs. A smaller entry does not
automatically mean lower total memory or shorter runtime.

Keep the original compressor as the balanced default. No archive format change
or unexplained universal speed claim is warranted. Experimental source files,
executables, binary hashes and raw timing samples stay under ignored
`build/research/lz78-compact/` (`paired.json`, `epoch-paired.json`); scripts are
`build/research/lz78_compact_experiment.py`, `lz78_epoch.py` and
`lz78_epoch_compare.py`. These tables are separate runs with their own baselines.
