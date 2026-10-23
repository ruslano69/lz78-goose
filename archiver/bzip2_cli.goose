// SPDX-License-Identifier: MIT
import std;
import os;
import gsbzip2;
import gswinargs;

fn main() {
    let argc = gswinargs::count();
    if argc < 3 || argc > 5 { write_stderr("usage: gbzip2 c INPUT OUTPUT [1..9]\n       gbzip2 d INPUT OUTPUT\n       gbzip2 t INPUT\n"); exit(2); }
    var mode: u8[>..] = []; gswinargs::arg(1, mode);
    if (mode == "t" && argc != 3) || (mode == "d" && argc != 4) || (mode == "c" && argc != 4 && argc != 5) || (mode != "c" && mode != "d" && mode != "t") { exit(2); }
    var source: u8[>..] = []; gswinargs::arg(2, source);
    var target: u8[>..] = []; if argc >= 4 { gswinargs::arg(3, target); if source == target { exit(2); } }
    var level = gsbzip2::DEFAULT_LEVEL;
    if argc == 5 {
        var text: u8[>..] = []; gswinargs::arg(4, text);
        if text.len != 1 || text[0] < '1' || text[0] > '9' { exit(2); }
        level = (text[0] - '0') as i64;
    }
    var input: u8[>..] = []; if !read_file(source, input) { exit(1); }
    var output: u8[>..] = [];
    let ok = if mode == "c" { gsbzip2::compress(input, output, level) } else { gsbzip2::decompress(input, output, gsbzip2::MAX_FILE) };
    if !ok { write_stderr("invalid input, damaged/unsupported BZip2 stream or size limit\n"); exit(1); }
    if mode != "t" && !write_file_atomic(target, output) { exit(1); }
    print(input.len, " -> ", output.len, " bytes");
}
