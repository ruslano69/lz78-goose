import std;
import lz78 from "..";

fn roundtrip(input: const u8[:]) {
    var archive: u8[>..] = [];
    assert(lz78::compress(input, archive));
    var restored: u8[>..] = [];
    assert(lz78::decompress(archive, restored));
    assert(restored == input);
}

fn main() {
    roundtrip("");
    roundtrip("aa");
    roundtrip("ABAABABAABAB");
    roundtrip("Goose: Привіт! Гусь стискає дані.");
    var bytes: u8[>..] = [];
    for i in 256 { bytes.push(i as u8); }
    roundtrip(bytes);
    var repeated: u8[>..] = [];
    repeated.resize(100000, 'A');
    roundtrip(repeated);
    var existing: u8[>..] = [];
    existing.append("keep");
    assert(!lz78::compress("input", existing));
    assert(existing == "keep");
    assert(!lz78::decompress("invalid", existing));
    assert(existing == "keep");
    print("PASS: Goose library roundtrips and output preconditions");
}
