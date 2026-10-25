import std;
import os;
import zstd;
import zstd_pipe;

// c: fresh encoder tables (optional LEVEL 1..19, default 3); p: the same with two threads (levels 1..3); reuse: retained EncCtx; d: decoder.
// Read/write and context creation are outside the timed region.
fn main() {
    let av = args();
    if av.len != 5 && av.len != 6 {
        write_stderr("usage: bench_zstd c|reuse|d INPUT ITERATIONS OUTPUT\n");
        exit(2);
    }
    let mode = av[1];
    if mode != "c" && mode != "p" && mode != "reuse" && mode != "d" {
        write_stderr("mode must be c, reuse or d\n"); exit(2);
    }
    let n, ok = parse_int(av[3]);
    if !ok || n <= 0 { write_stderr("ITERATIONS must be positive\n"); exit(2); }
    var level: i64 = 3;
    if av.len == 6 {
        let lv, lok = parse_int(av[5]);
        if !lok || lv < 1 { write_stderr("LEVEL must be positive\n"); exit(2); }
        level = lv;
    }
    var input: u8[>..] = [];
    if !read_file(av[2], input) { write_stderr("cannot read INPUT\n"); exit(1); }
    var output: u8[>..] = [];
    var ctx = zstd::enc_new();
    for i in 3 {
        output.clear();
        if mode == "d" { assert(zstd::decompress(input, output)); }
        else if mode == "reuse" { assert(zstd::compress_with(ctx, input, output)); }
        else if mode == "p" { assert(zstd_pipe::compress_pipelined(input, output, level)); }
        else { assert(zstd::compress_level(input, output, level)); }
    }
    let begin = clock();
    for i in n {
        output.clear();
        if mode == "d" { assert(zstd::decompress(input, output)); }
        else if mode == "reuse" { assert(zstd::compress_with(ctx, input, output)); }
        else if mode == "p" { assert(zstd_pipe::compress_pipelined(input, output, level)); }
        else { assert(zstd::compress_level(input, output, level)); }
    }
    let elapsed = clock() - begin;
    if !write_file_atomic(av[4], output) { write_stderr("cannot write OUTPUT\n"); exit(1); }
    let bytes = if mode == "d" { output.len } else { input.len };
    print("seconds=", elapsed, " input=", input.len, " output=", output.len,
          " iterations=", n, " MB/s=", bytes * n / elapsed / 1000000.0);
}
