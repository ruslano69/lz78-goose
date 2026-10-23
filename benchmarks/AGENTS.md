# C comparison

## Purpose

Compare the Goose codec with independent C implementations of the same format.

## Ownership

- `lz78_c.c`: C compression, output-range decoding and classic parent-chain decoding; test CLI and kernel timing driver.
- `driver.goose`: timings through the public library API.
- `compare.py`: shuffled paired measurements, output validation and retained evidence.
- `build-msvc.cmd`: Windows/MSVC build helper; installation-path assumptions must remain explicit in README.md.
- `README.md`: measured results, memory-strategy differences and reproduction commands.

## Local Contracts

- Preserve archive compatibility and corruption checks. Verify C with test/verify.py before timing.
- Compile C and generated Goose C using the same compiler and optimization level. Record all raw samples, hashes and versions under ignored build/.
- Time codec work including its checksum and temporary allocations, excluding input reads, startup, extra verification and printing. Output freeing occurs after timing in both drivers.
- Keep classic parent-chain and range decoder results distinct. This is an implementation/backend comparison, not a universal language-speed claim.

## Work Guidance

- Do not change the library to favor a benchmark. Allocation strategy and packed C record layouts must be explicit in the report.

## Verification

- Python independent byte-exact verification against the C CLI, then compare.py; run Goose test/roundtrip.goose for the library.

## Child DOX Index

No child documents.
