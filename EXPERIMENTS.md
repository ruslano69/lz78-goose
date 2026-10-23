# Learning notes and historical measurements

This library grew from a funcfinder LZ78 exercise. Measurements below concern
that earlier standalone program on one Windows machine, Goose 94cc64d and
MSVC 19.44 /O2. They are learning observations, not general speed guarantees
or fresh measurements of the packaged library.

## Goose properties used

- const u8[:] borrows input. u8[>..]& writes into the caller's grow-only output.
- Grow-only output preserves earlier bytes. The decoder can append a phrase
  from a slice of that same array without walking a parent chain.
- Structs are packed. Range { start:u32, length:u16 } occupies six bytes;
  the original parent/symbol/length entry occupied thirteen.
- A dictionary lookup returns an optional reference. Copy its value inside
  a short scope before any operation that might resize the dictionary.
- Unsigned arithmetic wraps (needed by FNV); widening conversions are implicit.

## Decoder result

Ten shuffled native before/after pairs on the same retained 1 MiB inputs,
with two in-process warmups before each measured sample:

| Input | Parent chain | Output ranges |
|---|---:|---:|
| Repeated A | 3.586 ms | 1.006 ms |
| UTF-8 text | 4.861 ms | 1.047 ms |
| Source | 6.547 ms | 1.783 ms |
| Random bytes | 4.734 ms | 4.499 ms |

Archive bytes were unchanged. Long phrases benefit most; random inputs have
little reuse. The range decoder is the current library implementation.

## Compressor trade-offs

A 24-bit key fits u32, and phrase IDs fit u16. Standard dictionary slots shrink
from sixteen to twelve or ten bytes with narrower types. The smallest slots
saved memory but were about 8% faster on source and 11% slower on repeated A
in one paired comparison. get_or_insert was not a universal win either.

An eight-byte-slot grow-only table with a generation counter avoided growth,
rehashing and full-table clearing. It improved source/random compression about
1.4x, but repeated A regressed from 5.460 to 8.211 ms. It always initialized
131072 slots, even when the original dictionary remained small.

The original generic compressor remains the balanced default. Smaller entries
do not automatically mean lower total memory or shorter runtime. Experimental
variants and timing harnesses are not supported library APIs. Python comparison
also changes dictionary representation, so it does not isolate language speed.
