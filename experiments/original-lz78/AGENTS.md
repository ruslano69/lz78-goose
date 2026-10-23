# Goose LZ78 experiment

## Purpose

Standalone, binary-safe LZ78 example and an exercise for Goose navigation.

## Ownership

- `lz78.goose`: codec, file format and command-line application.
- `verify.py`: independent Python codec and cross-decoding/malformed-input checks.
- `benchmark.py`: timing driver generation, codec timings and complete CLI timings against the independent Python codec.
- `README.md`: format, build/run commands, provenance and limits.

## Local Contracts

- Keep the implementation independent of reference-project source code; document algorithm references and the reference revision.
- Format `LZ78G001`: little-endian original length/checksum, canonical ULEB128 tagged pairs, bounded dictionary with deterministic reset. Preserve byte-level interoperability with the independent Python implementation.
- Reject malformed archives before writing output. Dictionary limit is 65535 phrases, decoded/input limit is 64 MiB. Use atomic file output.
- Build/test artifacts belong under ignored root `build/`, not this folder. No external Python packages are required by verification.

## Work Guidance

- Use the Goose compiler for syntax/type/lifetime validation; funcfinder discovery alone does not establish program correctness.
- Benchmark identical bytes/format with warmups and retained samples; separate kernel time from process/file I/O. Goose native and TinyCC comparisons use `-O2`. Python stores complete phrases whereas Goose stores trie edges/output ranges: speed differences do not isolate the language alone. Keep timing separate from test loads.
- Decoder ranges point into its grow-only output: validate indexes and decoded size before appending. `start:u32` fits the 64 MiB limit; `length:u16` fits a block of at most 65535 added phrases. Dictionary resets do not shrink output. Preserve the archive format and corruption checks.

## Verification

- Compile with Goose `build`, then run `python experiments/original-lz78/verify.py --exe <path-to-lz78-executable>`.
- For timing, run `benchmark.py --prepare --exe <lz78-exe> --goose <goose-exe>` then the same command without `--prepare`; generated drivers and reports stay under `--work` (default ignored `build/research/lz78-timing`).

## Child DOX Index

No children.
