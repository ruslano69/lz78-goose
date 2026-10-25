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
    print(count, " prefix comparisons, bit positions and overlap checks passed");
}
