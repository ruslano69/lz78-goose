// SPDX-License-Identifier: MIT
import std;
import gsbzip2;

fn main() {
    let cases: const u8[:][5] = ["", "a", "banana", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "ababababababababababababababab"];
    for input in cases {
        var packed: u8[>..] = []; assert(gsbzip2::compress(input, packed, 1));
        var restored: u8[>..] = []; assert(gsbzip2::decompress(packed, restored, input.len)); assert(restored == input);
    }
    var raw: u8[>..] = []; raw.resize(2000000, 'x');
    var packed: u8[>..] = []; assert(gsbzip2::compress(raw, packed, 1));
    var limited: u8[>..] = []; assert(!gsbzip2::decompress(packed, limited, 1024)); assert(limited.len <= 1024);
    var nonempty: u8[>..] = []; nonempty.append("preserve");
    assert(!gsbzip2::compress("x", nonempty, 1));
    assert(!gsbzip2::decompress(packed, nonempty, 2000000)); assert(nonempty == "preserve");
    assert(!gsbzip2::compress("x", limited, 0));
    var table: u32[256] = [0; 256]; gsbzip2::crc_table(table);
    var crc: u32 = 4294967295;
    for b in "123456789" { crc = gsbzip2::crc_byte(crc, b, table); }
    assert(~crc == 0xfc891918);
    print("BZip2 native checks OK");
}
