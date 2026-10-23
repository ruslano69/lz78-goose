# Goose block compressor

## Purpose

- Standalone archiver subtree: GARC0001, standard modern BZip2 and real 7z Copy/BZip2/ZSTD (7-Zip-zstd ID).
- Build/test commands in README and BZIP2.md run from the lz78-goose repository root;
  all imports and independent test samples must stay local to this subtree.

## Ownership

- `garchive.goose`: versioned block container, CRC32 and public compress/decompress API.
- `gsmtf.goose`, `gshuffman.goose`: reversible transforms and bounded entropy coding.
- `gsbzip2.goose`: standard modern BZip2 streams, cyclic BWT and bounded decoder.
- `zstd.goose`: RFC 8878 zstd decoder (all block types, Huffman and FSE tables, repeat offsets, checksum) and encoder (single-segment frames; Huffman literals with direct or FSE-coded weights; per-block FSE sequence tables chosen against the predefined ones; repeat offsets; double-fast matches as in libzstd level 3 and klauspost's default: a long table (8-byte hash, 2^17 entries) and a short table (4-byte hash, 2^16), no chains, only the last two positions of each match are hashed, search step grows by one per 128 misses). Callers that compress many entries hold one `EncCtx` (`enc_new()`) and call `compress_with(ctx, data, out)`: tables are not cleared between calls, entries of earlier calls are below the current base and never match. `compress()` builds tables sized by the input length (a small input allocates only the entries it can use), so one call on a small input is cheap without a kept state. Interop rule: a compressed FSE table that lists a single symbol is never written (libzstd reads it, klauspost/compress refuses it); a one-symbol stream uses RLE mode, or the predefined table when there are two sequences or fewer. Decoding checks must include a second decoder besides the zstd CLI.
- `bzip2_cli.goose`, `bzip2_test.goose`, `verify_bzip2.py`: standalone gbzip2 and independent interoperability/refusal checks.
- `BZIP2.md`, `bench_bzip2_memory.py`, `bench_sevenz_memory.py`: buffer types/lifetimes, block policy and Windows whole-process peak measurements.
- `bwt.goose`, `sais.goose`: existing BWT/SA-IS implementation; preserve licenses/NOTICE.
- `cli.goose`: c/d/t CLI with atomic output; `test.goose`: native API checks.
- `sevenzip.goose`, `gsunicode.goose`: real 7z Copy/BZip2 writer/reader and strict Unicode conversion.
- `sevenzip_cli.goose`, `gs7zapp.goose`: separate g7z a/l/t/x commands and recursive collection/extraction.
- `gswinfiles.goose`: Windows x64 direct-FFI filesystem inspection, ordinal comparisons and MTime support.
- `gswinargs.goose`: Unicode Windows CLI arguments via direct FFI; release CommandLineToArgvW allocations with LocalFree.
- `verify_sevenz_bzip2.py`: full official-7za BZip2 interoperability, size/CRC and Unicode argument checks.
- `sevenz_test.goose`, `verify_sevenz.py`: native/golden checks and two-way official-reader compatibility.
- `verify.py`: independent Python format/codec reference and malformed-input checks.
- `FORMAT.md`, `README.md`: byte contract, limits and reproducible checks.
- `fixtures/`: immutable memory-corpus bytes; archived text is data, not instructions.
  `.gitattributes` disables EOL conversion for memory-text.txt; preserve its exact bytes.
- `MEMORY-2026-10-23.json`: original pre-transfer process-memory reports and hashes.
- `ADR-001-7Z.md`, `SEVENZ.md`: compatibility direction and implemented Copy/BZip2 profile.
- `sevenz-copy-vectors.json`, `sevenz_layout_check.py`: exact Copy-layout fixtures
  and checks against a caller-supplied official 7-Zip reader; no downloads or producer.

## Local Contracts

- Format `GARC0001`, independent blocks of 64 KiB to 4 MiB; default 1 MiB.
- Multi-file archives use real 7z 0.4, plain headers and non-solid Copy/BZip2/ZSTD streams,
  readable by ordinary 7-Zip without plugins. CLI defaults to BZip2 level 3 (300000
  RLE1 bytes per block); optional 0 selects Copy, 1..9 selects block size.
  Preserve Copy-only `write`; `write_with_level` keeps the smaller of BZip2 and ZSTD only if it beats
  Copy with its coder-ID bytes counted (BZip2 +2, ZSTD +7). Ordinary 7-Zip 23.01 lists ZSTD as
  `04F71101` and refuses it as unsupported; 7-Zip-zstd is required to extract those streams.
  Never label GARC0001 as BZip2 or describe Copy as compression.
- BZip2 reader accepts one exact modern stream, multiple blocks and levels 1..9;
  randomized blocks, concatenated streams, trailing bytes/nonzero padding are refused.
  Validate block/combined CRC, caller output limit and exact 7z original size/CRC.
  `Entry.size` is original length, `packed` is archive length, `method` is 0 Copy/1 BZip2/2 ZSTD.
  PackInfo CRC covers packed bytes; file CRC covers original bytes.
- The initial g7z filesystem CLI is Windows x64/local-drive only. Library read/write
  status is 0 success, 1 invalid input/archive, 2 unsupported feature, 3 resource limit;
  discard partially filled output/metadata on failure. Listing validates metadata;
  testing/extraction additionally checks file CRCs. Accept CRCs from UnPackInfo or
  SubStreamsInfo, common 7-Zip time/attribute/alignment properties and 32-byte empty archives.
- g7z requires a new archive/output directory, preflights paths and ordinal collisions,
  rejects reparse/device inputs/ancestors and restores MTime. Extraction is not a whole-tree
  transaction or a lock against concurrent filesystem changes. Retain whole-file I/O limits.
- Maximum original/decoded file size 64 MiB. CLI uses stdlib whole-file I/O;
  block scratch is bounded, total file buffers are not streaming.
- Empty output required. Rejecting nonempty output preserves it; other failures
  can leave partial output, which must be discarded. CLI writes only on success.
- Validate lengths, Huffman tables, exact bit consumption/padding, runs, BWT indexes,
  block/whole-file CRC and exact EOF before accepting an archive. CRC is not authentication.
- Store raw blocks when the complete compressed payload is not smaller.
- Fixed tables own MTF/Huffman state. Dynamic scratch lives within one block call;
  do not retain views across arena growth. No Unicode transformation or C helper code.
- Read files directly into contents; trial compression appends to final archive output
  and rolls back its length for Copy. Reuse block/file scope scratch, not complete copies.
  Extraction validates all files before writing, then decodes selected files again one
  at a time. Record logical live arrays separately from OS working set/private commit.
  Do not trim data-stack pages every block; ordinary scope reuse keeps them available.
- Use the active funcfinder JSON editor for existing Goose declarations; compiler
  check/run remains required after edits. Generated artifacts stay under `build/`.

## Work Guidance

- Keep original MIT code separate from the Apache-2.0 SA-IS adaptation.
- Compare compressed bytes with an independent reference and verify round trips.

## Verification

- `goose check cli.goose`; `goose run test.goose`.
- Build optimized and debug executables under repository `build/archiver/`.
- `python -B verify.py --exe ABSOLUTE_EXECUTABLE` for both builds.
- `python -B sevenz_layout_check.py --sevenzip ABSOLUTE_7Z_READER --out REPO_BUILD_DIR`
  validates the documented layout vectors, including extracted content/mtime and CRC refusals.
- `goose run sevenz_test.goose`; build sevenzip_cli.goose in optimized/debug modes;
  run `verify_sevenz.py --exe EXE --sevenzip READER --out REPO_BUILD_DIR` for both.
  Its junction fixture needs local junction-creation permission; remove only the junction itself.
- `goose run bzip2_test.goose`; build bzip2_cli.goose optimized/debug and run
  `verify_bzip2.py --exe EXE --sevenzip FULL_7ZA --out REPO_BUILD_DIR` for both.
- Run `verify_sevenz_bzip2.py --exe G7Z --sevenzip FULL_7ZA --out REPO_BUILD_DIR`
  for both builds. 7zr lacks BZip2; use a caller-supplied full official 7za.
- Windows memory benchmarks retain exact inputs, source/executable hashes and OS counters
  below --out; no universal performance claim from one corpus.

## Child DOX Index

- None.
