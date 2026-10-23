import std;
import os;
import lz78 from "..";

fn main() {
    var mode: u8[>..] = []; arg(1, mode);
    var path: u8[>..] = []; arg(2, path);
    var count: u8[>..] = []; arg(3, count);
    let rounds, valid = parse_int(count);
    if !valid || rounds < 1 { exit(2); }
    var input: u8[>..] = [];
    if !read_file(path, input) { exit(1); }
    for iteration in rounds {
        var output: u8[>..] = [];
        let start = clock_ns();
        let ok = if mode == "c" { lz78::compress(input, output) } else { lz78::decompress(input, output) };
        let elapsed = clock_ns() - start;
        if !ok { exit(1); }
        print("BENCH ", elapsed, " ", output.len, " ", lz78::checksum(output));
    }
}
