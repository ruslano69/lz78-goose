import std;
import os;
import lz78 from "..";

fn main() {
    if arg_count() != 4 {
        write_stderr("usage: lz78 c|d INPUT OUTPUT\n");
        exit(2);
    }
    var mode: u8[>..] = []; arg(1, mode);
    var source: u8[>..] = []; arg(2, source);
    var target: u8[>..] = []; arg(3, target);
    if (mode != "c" && mode != "d") || source == target {
        write_stderr("invalid mode or identical input/output paths\n"); exit(2);
    }
    var input: u8[>..] = [];
    if !read_file(source, input) { write_stderr("cannot read input\n"); exit(1); }
    var output: u8[>..] = [];
    let ok = if mode == "c" { lz78::compress(input, output) } else { lz78::decompress(input, output) };
    if !ok { write_stderr("invalid archive or size limit exceeded\n"); exit(1); }
    if !write_file_atomic(target, output) { write_stderr("cannot write output\n"); exit(1); }
    print(input.len, " -> ", output.len, " bytes");
}
