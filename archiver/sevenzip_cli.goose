// SPDX-License-Identifier: MIT
// Initial filesystem CLI targets Windows x64; sevenzip.goose is portable.
import std;
import os;
import sevenzip;
import gswinfiles;
import gs7zapp;
import gswinargs;

fn fail(status: i64) {
    if status == 2 { write_stderr("unsupported_feature: plain-header non-solid Copy/BZip2 7z required\n"); }
    else if status == 3 { write_stderr("limit_exceeded: 65535 entries, 8 MiB header/names, 64 MiB contents\n"); }
    else { write_stderr("invalid_archive_or_io_error\n"); }
    exit(1);
}

fn main() {
    let count = gswinargs::count();
    if count < 3 {
        write_stderr("usage: g7z a OUT.7z ROOT [0..9]\n       g7z l|t ARCHIVE.7z\n       g7z x ARCHIVE.7z NEW_DEST [REL_PATH...]\n"); exit(2);
    }
    var mode: u8[>..] = []; gswinargs::arg(1, mode);
    var source_arg: u8[>..] = []; gswinargs::arg(2, source_arg);
    if (mode == "a" && count != 4 && count != 5) || ((mode == "l" || mode == "t") && count != 3) || (mode == "x" && count < 4) || (mode != "a" && mode != "l" && mode != "t" && mode != "x") { exit(2); }
    var source: u8[>..] = [];
    if !gswinfiles::absolute(source_arg, source) || !gswinfiles::safe(source) { fail(1); }
    if mode == "a" {
        let output_info, output_kind = gswinfiles::info(source);
        if output_kind != 0 { write_stderr("output already exists\n"); fail(1); }
        var root_arg: u8[>..] = []; gswinargs::arg(3, root_arg);
        var root: u8[>..] = [];
        if !gswinfiles::absolute(root_arg, root) { fail(1); }
        var entries: sevenzip::Entry[>..] = []; var names: u8[>..] = []; var contents: u8[>..] = [];
        if !gs7zapp::collect(root, entries, names, contents) { fail(1); }
        var archive: u8[>..] = [];
        var level: i64 = 3;
        if count == 5 {
            var option: u8[>..] = []; gswinargs::arg(4, option);
            if option.len != 1 || option[0] < '0' || option[0] > '9' { exit(2); }
            level = (option[0] - '0') as i64;
        }
        let status = sevenzip::write_with_level(entries, names, contents, archive, level);
        if status != 0 { fail(status); }
        if !gswinfiles::safe(source) || !write_file_atomic(source, archive) { fail(1); }
        print("OK: ", entries.len, " entries, ", archive.len, " bytes, Copy/BZip2/ZSTD"); return;
    }
    var archive: u8[>..] = [];
    if !read_file(source, archive) { fail(1); }
    var entries: sevenzip::Entry[>..] = []; var names: u8[>..] = [];
    let status = sevenzip::read(archive, entries, names);
    if status != 0 { fail(status); }
    if mode == "l" {
        for e in entries { print(if (e.flags & 1) != 0 { "D " } else { "F " }, e.size, " ", if e.method == 1 { "BZip2 " } else if e.method == 2 { "ZSTD " } else { "Copy " }, sevenzip::path(e, names)); }
        print("OK: ", entries.len, " entries, Copy/BZip2/ZSTD"); return;
    }
    if mode == "t" {
        if !sevenzip::test(archive, entries) { write_stderr("crc_or_codec_error\n"); fail(1); }
        print("OK: ", entries.len, " entries, CRC verified"); return;
    }
    var target_arg: u8[>..] = []; gswinargs::arg(3, target_arg);
    var target: u8[>..] = [];
    if !gswinfiles::absolute(target_arg, target) { fail(1); }
    var filter_text: u8[>..] = []; var filters: gs7zapp::Span[>..] = [];
    for i in 4..count {
        var name: u8[>..] = []; gswinargs::arg(i, name);
        if !sevenzip::valid_path(name) { exit(2); }
        let at = filter_text.len; filter_text.append(name); filters.push(gs7zapp::Span { at as u32, name.len as u32 });
    }
    if !gs7zapp::extract(archive, entries, names, target, filters, filter_text) { fail(1); }
    print("OK: extracted to ", target);
}
