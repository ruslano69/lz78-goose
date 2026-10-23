// SPDX-License-Identifier: MIT
import std;
import os;
import garchive;

fn main() {
    let argc = arg_count();
    if argc < 3 || argc > 5 {
        write_stderr("usage: garchive c INPUT OUTPUT [BLOCK_KiB]\n       garchive d INPUT OUTPUT\n       garchive t INPUT\n"); exit(2);
    }
    var mode: u8[>..] = []; arg(1, mode);
    var source: u8[>..] = []; arg(2, source);
    var target: u8[>..] = [];
    if argc >= 4 { arg(3, target); }
    if (mode == "t" && argc != 3) || (mode == "d" && argc != 4) || (mode == "c" && argc != 4 && argc != 5) || (mode != "c" && mode != "d" && mode != "t") {
        write_stderr("invalid mode or arguments\n"); exit(2);
    }
    if mode != "t" && source == target { write_stderr("input and output paths must differ\n"); exit(2); }
    var block_size = garchive::DEFAULT_BLOCK;
    if argc == 5 {
        var text: u8[>..] = []; arg(4, text);
        if text.len == 0 || text.len > 4 { exit(2); }
        var value: i64 = 0;
        for byte in text {
            if byte < '0' || byte > '9' { exit(2); }
            value = value * 10 + (byte - '0') as i64;
        }
        if value < 64 || value > 4096 { write_stderr("block size must be 64..4096 KiB\n"); exit(2); }
        block_size = value * 1024;
    }
    var input: u8[>..] = [];
    if !read_file(source, input) { write_stderr("cannot read input\n"); exit(1); }
    var output: u8[>..] = [];
    if mode == "c" {
        if !garchive::compress(input, output, block_size) { write_stderr("compression failed (64 MiB input limit)\n"); exit(1); }
    } else {
        if !garchive::decompress(input, output) { write_stderr("invalid, damaged or unsupported archive\n"); exit(1); }
    }
    if mode == "t" { print("OK: ", output.len, " bytes"); return; }
    if !write_file_atomic(target, output) { write_stderr("cannot write output\n"); exit(1); }
    print(input.len, " -> ", output.len, " bytes");
}
