# lz78-goose

## Purpose

Learn Goose through a small binary-safe LZ78 library. The implemented algorithm is LZ78.

## Ownership

- `lz78.goose`: namespace lz78, in-memory codec and format constants. No file I/O or main function.
- `examples/cli.goose`: command line and atomic file I/O.
- `test/roundtrip.goose`: native Goose API and precondition checks.
- `test/verify.py`: independent Python reference codec, byte-exact cross-checks and malformed-input tests.
- `README.md`: public API and build/use instructions; `FORMAT.md`: archive contract; `EXPERIMENTS.md`: learning history.
- `LICENSE`: repository MIT license; `NOTICE`: retained original funcfinder copyright/license notice.

## Local Contracts

- Preserve format LZ78G001 and deterministic resets after 65535 added phrases. Input/decoded size limit: 64 MiB.
- Public API: lz78::compress/decompress(input: const u8[:], out: u8[>..]&) -> bool. Require empty output. Rejection of nonempty output leaves it intact; malformed data can leave partial output in an initially empty buffer, which callers must discard on false.
- Grow-only decoded output preserves phrase ranges. Entry start:u32/length:u16 is bounded by the size/dictionary limits. Do not replace it with shrinking storage while views are live.
- Default compressor is the original generic dictionary. Experimental narrower/epoch tables have workload-dependent regressions; do not claim universal gains.
- Keep generated files under ignored build/. Keep tests independent of checkout location. Do not commit compiler binaries or caches.

## Work Guidance

- Map declarations before reading/editing them with funcfinder if available; Goose JSON code objects are not yet supported.
- Use compiler syntax/type/lifetime checks and independent Python verification before changing the codec. Navigation alone is not validation.

## Verification

- `goose check examples/cli.goose`
- `goose run test/roundtrip.goose`
- `goose build examples/cli.goose -o build/lz78.exe`
- `python test/verify.py --exe build/lz78.exe`
- Repeat with a Goose --debug executable when codec changes affect arithmetic or bounds.

## Child DOX Index

No child AGENTS.md files. This document owns examples/ and test/.
