# Goose versus C: Windows experiment, 2026-10-23

Independent C11 implementation of LZ78G001, compared with the public Goose
library. This is a controlled implementation comparison, not a benchmark of
an existing industrial C library or a universal language-speed result.

Both are compiled by the installed MSVC 19.44 x64 with `/O2`; Goose uses
`-O2`. C additionally uses `/std:c11`. Same input bytes, format, checksum,
65535-entry dictionary reset, hash function, linear probing, 2/3 load growth
and in-place rehash rules. The library was not changed for this comparison.

## Results

Each input is 1 MiB. Medians of 15 shuffled paired rounds; each measured process
first executes two warmups. Times cover codec execution, checksum and temporary
allocation/release. File reads, process startup, output freeing, printing and
extra result verification are outside timing. No CPU affinity was imposed.

| Input | Goose compress | C compress | Goose decode | C ranges decode | C parents decode |
|---|---:|---:|---:|---:|---:|
| Repeated A | 5.499 ms | 5.070 ms | 1.005 ms | 1.203 ms | 3.786 ms |
| UTF-8 text | 9.025 ms | 9.369 ms | 1.061 ms | 1.206 ms | 5.122 ms |
| Source | 13.879 ms | 14.519 ms | 1.576 ms | 1.884 ms | 7.021 ms |
| Random | 13.493 ms | 15.989 ms | 4.452 ms | 5.095 ms | 5.113 ms |

Compression is comparable: C wins on repeated A, Goose wins on these other
three workloads. The range decoder is about 1.14–1.20x faster in Goose here.
Against the classic C parent-chain decoder the Goose range decoder is about
3.8–4.8x faster on repetitive text/source, but only 1.15x on random bytes.
The large gap primarily demonstrates a representation change: C also gains
substantially when switched to ranges. Small differences need caution.

## Memory and implementation differences

- C uses malloc/realloc/free; Goose uses its compiler-managed data stacks.
- C compression reserves output based on input size, then doubles if needed.
  Its hash slots dynamically double, matching the Goose dictionary's policy.
- C decoding reserves output from the validated original length and allocates
  the maximum metadata table once per call. Goose grows output and metadata
  on its data stacks. C does not need to keep old output pointers alive: its
  records store offsets.
- C range decoding uses memcpy for each phrase; source and destination never
  overlap. Goose uses append from an earlier output slice. Compiler decisions
  and per-copy call overhead can affect their difference; no single cause was
  isolated by these measurements.
- Explicit C packing matches Goose's six-byte Range and thirteen-byte classic
  Phrase records; C hash slots are sixteen bytes. Static assertions enforce this.
- The classic decoder stores parents/symbols/lengths and reverses each phrase
  through a scratch buffer. It uses the same framing/reference/size/checksum
  validation as the range decoder.

Both C executables pass `test/verify.py`: 140 byte-exact cross-checks and 73
malformed-input rejections each. The exact measured datasets are additionally
cross-encoded/decoded byte-for-byte by all three applications before timing.
The C file-writing wrapper is only a test driver; it does not promise the
Goose CLI's atomic destination replacement on a write failure.

## Reproduce

From the repository root in Windows PowerShell, with Goose on PATH:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
cmd /c benchmarks\build-msvc.cmd
goose build examples/cli.goose -o build/lz78.exe
goose build benchmarks/driver.goose -o build/goose-bench.exe
python -B test/verify.py --exe build/lz78-c.exe --work build/c-verify
python -B test/verify.py --exe build/lz78-c-classic.exe --work build/c-classic-verify
python -B benchmarks/compare.py
```

The batch file uses the installed VS environment or the default Visual Studio
2022 Community path; adjust that path for another installation. The C timing
driver uses Windows QueryPerformanceCounter. It is not a cross-platform build
script. Goose `clock_ns` uses the platform monotonic clock.

Ignored `build/c-comparison/timings.json` records every sample, medians/ranges,
dataset/archive hashes, source/binary hashes and environment. `RESULTS.md`
contains the compact table. Compiler/runtime startup and I/O are not measured.
