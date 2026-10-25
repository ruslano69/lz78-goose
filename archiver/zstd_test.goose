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
