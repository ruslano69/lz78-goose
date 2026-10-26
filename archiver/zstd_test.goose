import std;
import zstd;

// Word-at-a-time prefix comparison: unaligned starts, all mismatch positions,
// complete words, short tails, identical ranges and overlapping ranges.
fn main() {
    var data: u8[512] = [0; 512];
    var count = 0;
    for offset in 16 {
        for length in 131 {
            for mismatch in length + 1 {
                for i in length {
                    data[offset + i] = (i % 251) as u8;
                    data[256 + i] = (i % 251) as u8;
                }
                if mismatch < length { data[256 + mismatch] ^= 255; }
                assert(zstd::match_at(data, offset, 256, length) == mismatch);
                count += 1;
            }
        }
    }
    for bit in 8 {
        for i in 512 { data[i] = 0; }
        data[263] = (1 << bit) as u8;
        assert(zstd::match_at(data, 0, 256, 16) == 7);
    }
    assert(zstd::match_at(data, 512, 512, 0) == 0);
    assert(zstd::match_at(data, 0, 0, 512) == 512);
    for i in 512 { data[i] = 0; }
    assert(zstd::match_at(data, 0, 1, 511) == 511);
    data[511] = 1;
    assert(zstd::match_at(data, 0, 1, 511) == 510);
    // Every byte value, short words and partial word tails. The independent
    // verifier additionally exercises RLE followed by compressed blocks.
    for byte in 256 {
        for length in 1..18 {
            var input: u8[>..] = [];
            input.resize(length, byte as u8);
            var frame: u8[>..] = [];
            assert(zstd::compress(input, frame));
            var restored: u8[>..] = [];
            assert(zstd::decompress(frame, restored));
            assert(restored == input);
            assert(frame.len == 21);
        }
    }
    print(huffman_stream_checks(), " scalar Huffman comparisons passed");
    let contexts = context_prefix_checks();
    print(contexts, " reused-context prefix checks passed");
    print(count, " prefix comparisons, bit positions and overlap checks passed");
}

fn context_prefix_checks() -> i64 {
    // Reused tables must agree with fresh tables across input sizes, changed prefixes and epoch reset.
    var ctx = zstd::enc_new();
    let sizes: i64[17] = [0, 1, 3, 7, 8, 15, 16, 17, 255, 256, 1024, 32767, 32768,
                          131071, 131072, 131073, 262151];
    var count: i64 = 0;
    for phase in 3 {
        for k in sizes.len {
            var input: u8[>..] = [];
            for i in sizes[k] {
                let lane = (i / 11) % 23;
                let byte = if i % 13 < 4 { 208 + i % 13 } else { (i % 11 + lane * 17 + phase * 31) % 251 };
                input.push(byte as u8);
            }
            let reset = phase == 1 && k == 7;
            if reset {
                ctx.base = 1073741820;
                ctx.head[0] = 18446744073709551615;
                ctx.longt[0] = 18446744073709551615;
            }
            var fresh: u8[>..] = [];
            var reused: u8[>..] = [];
            var back: u8[>..] = [];
            assert(zstd::compress(input, fresh));
            assert(zstd::compress_with(ctx, input, reused));
            assert(fresh == reused);
            assert(zstd::decompress(reused, back));
            assert(back == input);
            if reset {
                assert(ctx.base == input.len + 2);
                assert(ctx.head[0] != 18446744073709551615);
                assert(ctx.longt[0] != 18446744073709551615);
            }
            count += 1;
        }
    }
    return count;
}

fn huf_scalar(src: const u8[:], h: const zstd::Huf&, count: i64, out: u8[>..]&) -> bool {
    if src.len == 0 || src[src.len - 1] == 0 { return false; }
    var pos = (src.len - 1) * 8 + zstd::highbit(src[src.len - 1] as i64);
    for i in count {
        var idx: i64 = 0;
        for bit in h.acc {
            let at = pos - h.acc + bit;
            if at >= 0 { idx |= (((src[at >> 3] as i64) >> (at & 7)) & 1) << bit; }
        }
        let nb = h.nb[idx] as i64;
        if nb == 0 { return false; }
        pos -= nb;
        out.push(h.sym[idx]);
    }
    return pos >= 0;
}

fn huffman_stream_checks() -> i64 {
    var checks: i64 = 0;
    var bytes: u8[257] = [0; 257];
    var seed: u32 = 123456789;
    for i in 257 { seed = seed * 1664525 + 1013904223; bytes[i] = (seed >> 24) as u8; }
    for acc in 1..12 {
        var h = zstd::huf_new();
        h.acc = acc;
        for i in 1 << acc {
            h.sym[i] = ((i * 131 + 17) & 255) as u8;
            h.nb[i] = (1 + (i * 17) % acc) as u8;
        }
        for invalid in 2 {
            if invalid == 1 { for i in 1 << acc { if i % 7 == 0 { h.nb[i] = 0; } } }
            for len in [0, 1, 2, 3, 4, 7, 8, 9, 15, 16, 17, 31, 32, 63, 64, 65, 127, 128, 129, 257] {
                for stop in 9 {
                    if len > 0 { bytes[len - 1] = if stop == 8 { 0 } else { ((1 << stop) | ((seed as i64) & ((1 << stop) - 1))) as u8 }; }
                    for count in [0, 1, 2, 3, 4, 7, 8, 11, 15, 16, 31, 63, 127, 255, 513] {
                        var actual: u8[>..] = [42, 99];
                        var expected: u8[>..] = [42, 99];
                        let ok = zstd::huf_stream(bytes[0..len], h, count, actual);
                        let ref_ok = huf_scalar(bytes[0..len], h, count, expected);
                        assert(ok == ref_ok);
                        if ok { assert(actual == expected); }
                        checks += 1;
                    }
                }
            }
        }
    }
    return checks;
}
