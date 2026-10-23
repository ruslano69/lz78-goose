import std;
import os;
import zstd;

// Usage: gzstd c|d SOURCE TARGET   (c: compress to a zstd frame, d: decompress)
fn main() {
    if arg_count() != 4 && arg_count() != 5 { write_stderr("usage: gzstd c|d SOURCE TARGET [MAX]\n"); exit(2); }
    var mode: u8[>..] = []; arg(1, mode);
    var source: u8[>..] = []; arg(2, source);
    var target: u8[>..] = []; arg(3, target);
    var input: u8[>..] = [];
    if !read_file(source, input) { write_stderr("cannot read input\n"); exit(1); }
    var output: u8[>..] = [];
    if mode == "c" {
        if !zstd::compress(input, output) { write_stderr("zstd encode failed\n"); exit(1); }
    } else if mode == "d" {
        var max: i64 = 4611686018427387904;
        if arg_count() == 5 {
            var text: u8[>..] = []; arg(4, text);
            let value, ok = parse_int(text);
            if !ok || value < 0 { write_stderr("MAX must be a non-negative number\n"); exit(2); }
            max = value;
        }
        if !zstd::decompress_max(input, output, max) { write_stderr("zstd decode failed\n"); exit(1); }
    } else {
        write_stderr("mode must be c or d\n"); exit(2);
    }
    if !write_file_atomic(target, output) { write_stderr("cannot write output\n"); exit(1); }
}
