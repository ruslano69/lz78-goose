# lz78-goose

A small **LZ78** compression library written in [Goose](https://github.com/aardappel/goose).

This is a learning project: binary-safe input, a simple documented format,
independent verification, and experiments with Goose's grow-only memory model.
It is not intended to replace mature compression utilities.

## Layout

```text
lz78.goose              reusable module, namespace lz78
examples/cli.goose      file compressor/decompressor
test/roundtrip.goose    Goose API checks
test/verify.py          independent Python codec and cross-checks
FORMAT.md              versioned archive format
EXPERIMENTS.md          measured optimizations and learning notes
LICENSE                MIT
```

The library is pure Goose. It needs no `.build` sidecar, CMake project or Python
package dependencies. Native executable builds require a C compiler supported by Goose.

## Use as a library

From another project's root file, declare the package by its module name:

```goose
import std;
import lz78 from "../lz78-goose";

fn main() {
    let input = "Goose learns LZ78. Goose learns LZ78.";
    var archive: u8[>..] = [];
    assert(lz78::compress(input, archive));
    var restored: u8[>..] = [];
    assert(lz78::decompress(archive, restored));
    assert(restored == input);
    print(input.len, " -> ", archive.len, " bytes");
}
```

After publishing a tag, the local directory source can be replaced with a pinned
Git source, for example `github.com/ruslano69/lz78-goose@v0.1.0`. That tag must
exist first. The import name remains `lz78`, matching `lz78.goose`.

## API

```goose
fn compress(data: const u8[:], out: u8[>..]&) -> bool
fn decompress(data: const u8[:], out: u8[>..]&) -> bool
```

- Supply an **empty** output builder. Passing a nonempty builder returns false
  without modifying it.
- Input bytes are borrowed, not modified. Results are written directly into the
  caller's builder. No library file I/O, global mutable workspace or process exit.
- On false, an initially empty output may contain a partial result: discard it.
  Only consume/save output after success. No rollback guarantee is made.
- Maximum input/decoded size: 64 MiB. Dictionary resets after 65,535 added phrases.
- Decompression validates framing, references, decoded size and checksum. The
  checksum detects ordinary corruption and is not authentication.
- Empty inputs and all 256 byte values are supported; text encoding is irrelevant.

Only compress/decompress and the documented format/limits are the supported API.
Other declarations in the namespace are implementation details. Goose currently
uses namespace conventions rather than library-level privacy enforcement.

## CLI and verification

From this directory, on Windows PowerShell:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
goose check examples/cli.goose
goose run test/roundtrip.goose
goose build examples/cli.goose -o build/lz78.exe
./build/lz78.exe c input.txt archive.lz78
./build/lz78.exe d archive.lz78 restored.txt
python -B test/verify.py --exe build/lz78.exe
```

On Linux/macOS use `mkdir -p build`, `-o build/lz78`, and `./build/lz78`.
For TinyCC, run `goose run examples/cli.goose -- c input.txt archive.lz78`.
For runtime arithmetic/bounds checks, build with `--debug` and repeat verification.

The CLI atomically replaces its destination only after a successful codec run.
Exit codes: 0 success, 1 codec/I/O failure, 2 bad arguments. It processes whole files.

Tested with upstream Goose revision `94cc64d` (2026-10-22), MSVC 19.44 and Python
3.12. Release and debug builds each pass 140 byte-exact cross-checks plus 73
malformed-archive rejection checks. Tests include UTF-8, exhaustive short binary
strings, final references, repetitive/random inputs and multiple dictionary resets.

## Provenance and license

Original implementation of the classic LZ78 algorithm, developed as an exercise
in the funcfinder project. Studied [aaronscode/meZip](https://github.com/aaronscode/meZip)
at `929f9de0a20a570289ee822d813cf2425d01960f` and the
[Prague Stringology Club description](https://www.stringology.org/DataCompression/lz78/index_en.html).
No reference-project source code or data is included. Its `.mz` format is not compatible.

MIT; see [LICENSE](LICENSE) and the original attribution in [NOTICE](NOTICE).
