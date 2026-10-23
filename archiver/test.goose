// SPDX-License-Identifier: MIT
import std;
import garchive;
import gsmtf;
import gshuffman;

fn main() {
    assert(garchive::crc32("123456789") == 3421780262);
    var preserved: u8[>..] = []; preserved.append("keep");
    assert(!garchive::compress("hello", preserved));
    assert(!garchive::decompress("broken", preserved));
    assert(preserved == "keep");
    var data: u8[>..] = [];
    for i in 20000 { data.append("Goose learns compression. Гусь учится сжимать тексты.\n"); }
    var packed: u8[>..] = [];
    assert(garchive::compress(data, packed, 65536));
    assert(packed.len < data.len / 10);
    var restored: u8[>..] = [];
    assert(garchive::decompress(packed, restored));
    assert(restored == data);
    var empty: u8[>..] = [];
    assert(garchive::compress("", empty));
    assert(empty.len == 24);
    var empty_output: u8[>..] = [];
    assert(garchive::decompress(empty, empty_output) && empty_output.len == 0);
    for n in 1..128 {
        var input: u8[>..] = [];
        for i in n { input.push(((i * 71 + n) % 256) as u8); }
        var symbols: u16[>..] = [];
        assert(gsmtf::encode(input, symbols));
        var bits: u8[>..] = [];
        assert(gshuffman::encode(symbols, bits));
        var decoded: u16[>..] = [];
        assert(gshuffman::decode(bits, input.len, decoded));
        assert(decoded == symbols);
        var bytes: u8[>..] = [];
        assert(gsmtf::decode(decoded, input.len, bytes));
        assert(bytes == input);
    }
    print("PASS: CRC32, native block roundtrip, empty/precondition and transform checks");
}
