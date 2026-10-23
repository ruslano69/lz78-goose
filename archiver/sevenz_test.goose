// SPDX-License-Identifier: MIT
import std;
import os;
import sevenzip;
import gsunicode;
import gswinfiles;

fn main() {
    var entries: sevenzip::Entry[>..] = [];
    entries.push(sevenzip::Entry { 0, 5, 3, 0, 0, 0, 0, 0, 0 });
    var archive: u8[>..] = [];
    assert(sevenzip::write(entries, "a.txt", "abc", archive) == 0);
    assert(archive.len == 81);
    assert(archive == "\x37\x7a\xbc\xaf\x27\x1c\x00\x04\xac\x77\xd0\xc3\x03\x00\x00\x00\x00\x00\x00\x00\x2e\x00\x00\x00\x00\x00\x00\x00\x88\x58\x88\xba\x61\x62\x63\x01\x04\x06\x00\x01\x09\x03\x00\x07\x0b\x01\x00\x01\x01\x00\x0c\x03\x0a\x01\xc2\x41\x24\x35\x00\x08\x00\x00\x05\x01\x11\x0d\x00\x61\x00\x2e\x00\x74\x00\x78\x00\x74\x00\x00\x00\x00\x00");
    var parsed: sevenzip::Entry[>..] = []; var names: u8[>..] = [];
    assert(sevenzip::read(archive, parsed, names) == 0);
    assert(parsed.len == 1 && names == "a.txt" && parsed[0].size == 3 && parsed[0].offset == 32);
    assert(sevenzip::test(archive, parsed));
    archive[32] ^= 1;
    assert(!sevenzip::test(archive, parsed));
    var wide: u16[>..] = []; var text: u8[>..] = [];
    assert(gsunicode::to_utf16("Гусь/🐦.txt", wide));
    assert(gsunicode::from_utf16(wide[..wide.len - 1], text));
    assert(text == "Гусь/🐦.txt");
    assert(gswinfiles::compare("Гусь", "гусь") == 0);
    assert(!gswinfiles::component("COM¹.txt") && !gswinfiles::component("CON .txt"));
    var current: u8[>..] = [];
    assert(gswinfiles::absolute(".", current));
    let data, kind = gswinfiles::info(current);
    assert(kind == 2 && gswinfiles::safe(current));
    assert(!sevenzip::valid_path("../escape") && !sevenzip::valid_path("C:/escape"));
    print("PASS: native 7z writer/reader, CRC, Unicode and Windows filesystem adapter");
}
