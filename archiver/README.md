# File compression on Goose

A pure Goose block compressor: **BWT → MTF → zero runs → canonical Huffman**.
Decompression reverses the stages and verifies block and whole-file CRC32.
Text is treated as bytes; UTF-8, binary data, NULs and all 256 byte values work.

## Build and use

From the lz78-goose repository root, with the Goose compiler on PATH:

```powershell
New-Item -ItemType Directory -Force build/archiver | Out-Null
goose check archiver/cli.goose
goose run archiver/test.goose
goose build archiver/cli.goose -O2 -o build/archiver/garchive.exe
./build/archiver/garchive.exe c input.txt output.garc
./build/archiver/garchive.exe d output.garc restored.txt
./build/archiver/garchive.exe t output.garc
# Optional compression block size in KiB (64..4096, default 1024):
./build/archiver/garchive.exe c input.txt output.garc 256
```

On Unix, use `mkdir -p build/archiver`, omit `.exe` and run the resulting
executable with the same arguments. Goose requires a supported C compiler for
native builds; the codec itself has no handwritten C helper or third-party library.
Existing output files are replaced atomically only after successful completion.
Bad input exits 1; bad CLI arguments exit 2. Test mode writes no output file.

## Library API

```goose
fn compress(data: const u8[:], out: u8[>..]&, block_size: i64 = 1048576) -> bool
fn decompress(data: const u8[:], out: u8[>..]&) -> bool
```

Import `garchive` from this directory. Supply an empty output builder. Rejecting
a nonempty builder preserves it; other failures may leave partial output, which
must be discarded. Save or consume the result only on success. Inputs are borrowed.
It is the caller's responsibility to handle a false return; the library has no I/O
or process exits. Individual transform helpers are implementation details.

Original and decoded size are limited to **64 MiB**; blocks are 64 KiB..4 MiB.
The standard library currently provides whole-file I/O, so the CLI holds input
and output in memory. Transform scratch is released between block calls, but
this is **not streaming file I/O**, and the accepted-size limit does not cap the
initial file read. GARC0001 remains a single-file format; multi-file packaging
and metadata use the separate 7z tool below.
The file format, code lengths, checks and stored-block policy are in [FORMAT.md](FORMAT.md).

The additional multi-file tool below creates real `.7z` archives with standard
**BZip2** compression and **Copy** fallback. A standalone `.bz2` CLI and the
buffer types, lifetimes, block choices and measurements are in [BZIP2.md](BZIP2.md).
The `garchive` commands above continue to use single-file `GARC0001`.

## Multi-file 7z on Goose

The initial filesystem CLI targets **Windows x64 and local drive paths**. Its
format/Unicode modules are independent of Windows; `gswinfiles.goose` binds
Windows APIs directly from Goose to inspect file types/reparse points and
read/restore modification times. There is no handwritten C helper.

```powershell
goose run archiver/sevenz_test.goose
goose build archiver/sevenzip_cli.goose -O2 -o build/archiver/g7z.exe
./build/archiver/g7z.exe a backup.7z ./input-folder
# Explicit BZip2 block level (1..9); 0 selects Copy without compression:
./build/archiver/g7z.exe a compact.7z ./input-folder 9
./build/archiver/g7z.exe l backup.7z
./build/archiver/g7z.exe t backup.7z
./build/archiver/g7z.exe x backup.7z ./new-output-folder
# Select one directory and one file:
./build/archiver/g7z.exe x backup.7z ./new-selected-folder docs Русский.txt
```

`a` recursively packs the contents of ROOT, retaining relative Unicode paths,
empty files/directories and modification times. The output archive must not
already exist. `x` requires a **new destination directory** and refuses existing
targets, reparse ancestors, Windows device names, case-insensitive collisions
and file/directory path conflicts. An unmatched selection fails before creating
the destination. All file CRCs are checked before extraction starts. Files are
written atomically; an I/O failure can leave previously extracted files/directories.
Filesystem checks are path-based and do not lock against concurrent changes.
Names with LF cannot be enumerated safely through the current stdlib and are refused.
Win32 path-length/API restrictions still apply; UNC roots are outside this first CLI.

The default is BZip2 level 3: 300000 RLE1 bytes per block. Each file falls back
to Copy if compressed bytes plus the extra coder-ID bytes do not save space;
files below 64 bytes use Copy directly. Copy stores bytes **without compression**.
Ordinary 7-Zip opens, tests and extracts these archives without plugins.
Goose reads this non-solid/plain-header Copy/BZip2
profile, including 7-Zip's CRC placement and common time/attribute/alignment
properties. It restores MTime, not permissions/ACL/creation/access times.
LZMA2, encoded headers, solid and other codecs report `unsupported_feature`.
BZip2 randomized blocks and concatenated standalone streams are outside the reader
profile; its produced streams use standard modern BZip2. Windows arguments are
read as UTF-16 and converted strictly, preserving Cyrillic and emoji selections.
Limits: 65,535 entries, 8 MiB header and UTF-8 name arena, 64 MiB total content;
file I/O is currently whole-file. Format/profile: [SEVENZ.md](SEVENZ.md).

Both optimized and debug builds passed three Copy golden vectors, three source-tree
roundtrips in each direction with official 7-Zip, 109 malformed-input refusals,
five path-conflict refusals, 120 mutated-header probes, six filesystem refusals
and selective extraction. File and directory modification times are checked.

```powershell
python -B archiver/verify_sevenz.py --exe build/archiver/g7z.exe --sevenzip PATH_TO_7ZA --out build/sevenz-layout/goose-release
goose build archiver/sevenzip_cli.goose --debug -o build/archiver/g7z-debug.exe
python -B archiver/verify_sevenz.py --exe build/archiver/g7z-debug.exe --sevenzip PATH_TO_7ZA --out build/sevenz-layout/goose-debug
python -B archiver/verify_sevenz_bzip2.py --exe build/archiver/g7z.exe --sevenzip PATH_TO_7ZA --out build/sevenz-layout/bzip-release
```

The Windows junction test needs permission to create a junction between its
own fixture directories; the test removes only that junction, without recursive
deletion. Reports and retained trees stay under the explicit output directory.

MTF state, Huffman frequencies/tree/code tables and CRC lookup use fixed arrays.
Dynamic buffers hold block transforms; SA-IS uses explicit frames and grow-only
arenas. BWT and its SA-IS implementation are carried over from the earlier experiment.
These refer to GARC0001; the BZip2 cyclic sorter and packed inverse-BWT cells are
documented separately. Full official 7za 26.05 supports the BZip2 checks; reduced
7zr does not. No external codec library is used by our executables.

## Independent verification

Python's standard-library-only reference sorts complete suffix strings rather
than implementing SA-IS, and uses a heap for Huffman tree construction. It compares
the entire archive byte-for-byte on small cases, independently decodes additional
cases, and tests large native round trips, malformed archives and output preservation.
Reports retain source/executable/input hashes and compressed sizes. Gzip/bzip2
sizes are reference points; their algorithms and settings differ from this format.

```powershell
python -B archiver/verify.py --exe build/archiver/garchive.exe --output build/archiver/release-report.json
goose build archiver/cli.goose --debug -o build/archiver/garchive-debug.exe
python -B archiver/verify.py --exe build/archiver/garchive-debug.exe --output build/archiver/debug-report.json
```

Generated executables, reports and temporary cases stay under ignored `build/`.
Performance and compression quality are workload-dependent; see the saved ratios
for their exact input hashes and block sizes. This is a first working compressor,
with one Huffman table per block; **GARC0001** is not bzip2-compatible.
The separate `gsbzip2` module implements the standard modern BZip2 stream.

Verification on 2026-10-23 passed in both optimized and debug native builds:
145 exact-archive vectors, seven additional independent decodes, ten large
round trips, 422 invalid-input/output-preservation checks and six CLI argument
refusals. Tests include the 4 MiB block boundary, multiple blocks, Unicode paths,
the 64 MiB input-limit refusal, bad Huffman trees/bit padding, excess zero runs,
CRC failures, invalid BWT cycles, truncation and trailing data.

Historical sample from the original funcfinder checkout (`docs/EDIT.md`, SHA-256
retained in its report; this file is not a dependency of this subtree's tests):
43,059 → 14,284 bytes with 64 KiB blocks. The same input gave 15,261 bytes with
Python gzip level 9 and 13,742 with bzip2 level 9. These are file-size comparisons
on one input, not equal-algorithm speed measurements or general compression claims.
The relocated verifier uses this folder's README.md, FORMAT.md and garchive.goose
as its three real-file samples, so it runs independently of the original checkout.

## Licensing

Original modules and wrapper: MIT, [LICENSE](LICENSE). `sais.goose` adapts the
Apache-2.0 Rust SA-IS reference from kanzi-rs; retain [NOTICE](NOTICE) and
[LICENSE-APACHE-2.0](LICENSE-APACHE-2.0) when distributing the combined program.
