# Goose vs libzstd — 2026-10-26

GCC 16.1.0 / Goose -O2; 5 alternating batches, 3 warmups; libzstd checksum enabled, workers=0; retained contexts level 3; fresh Goose tables levels 6/12; lib contexts retained; same lib frame for decode; IO/startup excluded; ctypes overhead included

libzstd 1.5.7

| Input | Level | Goose MB/s | libzstd MB/s | Goose decode | lib decode | Goose bytes | lib bytes |
|---|---:|---:|---:|---:|---:|---:|---:|
| sources | 3 | 921.2 | 1229.1 | 2225.9 | 3832.6 | 60162 | 59493 |
| sources | 6 | 185.5 | 441.4 | 2333.1 | 3931.7 | 54224 | 54263 |
| sources | 12 | 91.0 | 191.3 | 2389.7 | 4081.1 | 52839 | 52904 |
| text | 3 | 5694.3 | 5324.8 | 9730.2 | 10644.1 | 3827 | 3821 |
| text | 6 | 563.9 | 2737.3 | 9863.8 | 10645.2 | 3739 | 3743 |
| text | 12 | 501.1 | 1834.2 | 9872.2 | 10828.3 | 3741 | 3741 |
| random | 3 | 4693.5 | 3904.6 | 10576.8 | 10110.4 | 1048617 | 1048613 |
| random | 6 | 125.5 | 2524.3 | 10553.9 | 10189.7 | 1048617 | 1048613 |
| random | 12 | 115.6 | 1673.2 | 10714.5 | 10016.7 | 1048617 | 1048613 |
| zeros | 3 | 8291.4 | 5101.9 | 13045.4 | 10687.5 | 49 | 54 |
| zeros | 6 | 695.8 | 2393.0 | 13316.1 | 10971.8 | 49 | 53 |
| zeros | 12 | 704.9 | 1474.6 | 13328.2 | 10965.2 | 49 | 53 |
| words256 | 3 | 327.1 | 387.8 | 708.0 | 885.0 | 241290 | 236121 |
| words256 | 6 | 68.3 | 87.0 | 617.8 | 891.3 | 229097 | 232506 |
| words256 | 12 | 6.2 | 15.7 | 687.1 | 1160.8 | 204966 | 217065 |
| exe | 3 | 116.7 | 263.9 | 324.7 | 897.2 | 141914 | 140232 |
| exe | 6 | 52.5 | 88.3 | 333.0 | 888.5 | 137134 | 136533 |
| exe | 12 | 34.3 | 50.7 | 336.8 | 925.1 | 136190 | 135892 |

## Scope and interpretation

Current repository revision: 633c3eba4e60e3041dd385f5125b0de1181988c6. Primary results use GCC 16.1.0, not the older GCC 15.2.0 of the historical report. Reference: bundled native libzstd 1.5.7 DLL; its original build flags are unknown. This compares usable implementations, not identical compiler settings. MSVC screening results are retained separately in build/libzstd-comparison; a GCC build overlapped part of that screening, so use the subsequent GCC series as the primary evidence.

Six inputs: sources and fixture text repeated/truncated to 1 MiB; deterministic random bytes (seed 781), zeros, 256 synthetic words (seed 7), and the full locally built MSVC benchmark executable. These are screening inputs; repeated text/sources are unusually compressible and the small benchmark EXE is not the EXE from the historical report. Exact inputs, hashes, archives and every sample remain in build/libzstd-comparison-gcc/results.json and its directory. No memory measurements were made.

Compression level 3 reuses Goose EncCtx and the native libzstd context. Levels 6/12 allocate Goose tables on each call while libzstd retains its context; allocation is included and is part of the measured API difference. Both encoders emit checksums and use one thread. Each result is the median of five batches with alternating order; file IO/startup are excluded. Python ctypes call overhead is included for libzstd, which can affect the fastest cases. Goose clears and grows its output; libzstd receives a preallocated destination.

Every Goose output was independently decoded with libzstd and compared byte-for-byte; Goose decoded every libzstd output with a byte-for-byte check. Both decoder speeds use the same libzstd-produced frame. This is corpus interoperability validation, not a full malformed-input test run. Levels 1/2 and 13-19 were not timed.

## Remaining gaps

At level 3 GCC Goose beats libzstd on repeated fixture text, random bytes and zeros here, but trails on sources (921 vs 1229 MB/s), synthetic words (327 vs 388), and the benchmark EXE (117 vs 264). On levels 6/12 random data is 14-20x slower despite essentially identical raw output sizes; an early incompressibility decision is a candidate for profiling, not an implemented fix. On words level 12 Goose is 2.5x slower but produces 5.6% fewer bytes, so speed alone does not describe that trade-off. Decoder throughput trails on sources (about 1.7x), words (1.3-1.7x), and EXE (about 2.7x); it approaches or exceeds the reference on raw/RLE-heavy frames. GCC materially improves over MSVC on this machine.

## Reproduce local series

The complete retained ctypes driver is build/archiver/compare_libzstd_gcc.py; the MSVC variant is build/archiver/compare_libzstd.py. They bind the installed DLL directly (no Python compression wrapper). Rebuild archiver/bench_zstd.goose with -O2 --cc C:/msys64/ucrt64/bin/gcc.exe to build/archiver/bench_zstd_gcc.exe and run the GCC driver with Python 3.12. Bundled DLL and runtime paths are machine-specific and recorded by the driver. Generated drivers and raw evidence remain under ignored build/ per repository policy.
