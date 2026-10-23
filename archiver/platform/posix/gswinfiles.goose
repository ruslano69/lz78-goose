// SPDX-License-Identifier: MIT
// POSIX adapter for gswinfiles (Linux x86_64 glibc). Same API as the Windows module.
// build_posix.py stages this file over archiver/gswinfiles.goose, so Windows builds never see it.
namespace gswinfiles;
import std;
import os;

struct Info {
    attributes: u32, creation_low: u32, creation_high: u32,
    access_low: u32, access_high: u32, write_low: u32, write_high: u32,
    size_high: u32, size_low: u32
}

// POSIX host (Linux x86_64 glibc). Only reached when host_posix() is true, so these
// libc symbols are never bound on Windows. struct stat offsets below are x86_64 glibc.
extern "libc.so.6" {
    fn posix_lstat(path: const u8&, buf: u8&) -> i32 = "lstat";
    fn posix_utimensat(dirfd: i32, path: const u8&, times: const u8&, flags: i32) -> i32 = "utimensat";
}


fn posix_c_string(name: const u8[:], out: u8[>..]&) -> bool {
    if name.len == 0 || name.len > 4095 { return false; }
    for b in name { if b == 0 { return false; } }
    out.append(name); out.push(0);
    return true;
}

fn read_le(data: const u8[:], at: i64, width: i64) -> u64 {
    var value: u64 = 0;
    var i: i64 = width - 1;
    while i >= 0 { value = (value << 8) | (data[at + i] as u64); i = i - 1; }
    return value;
}

fn write_le(out: u8[>..]&, value: u64, width: i64) {
    var i: i64 = 0;
    while i < width { out.push(((value >> ((8 * i) as u64)) & 255) as u8); i = i + 1; }
}

fn info(name: const u8[:]) -> Info, i64 {
    var result = Info { 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    if name.len == 0 || name[0] != '/' { return result, 4; }
    var cpath: u8[>..] = [];
    if !posix_c_string(name, cpath) { return result, 4; }
    var buffer: u8[>..] = []; buffer.resize(144, 0);
    if posix_lstat(cpath[0], buffer[0]) != 0 { return result, 0; }
    let mode = read_le(buffer, 24, 4) & 61440;
    if mode == 40960 { return result, 3; }
    if mode != 16384 && mode != 32768 { return result, 3; }
    let size = read_le(buffer, 48, 8);
    let seconds = read_le(buffer, 88, 8);
    let nanos = read_le(buffer, 96, 8);
    let ticks = (seconds + 11644473600) * 10000000 + nanos / 100;
    result.size_low = (size & 4294967295) as u32; result.size_high = (size >> 32) as u32;
    result.write_low = (ticks & 4294967295) as u32; result.write_high = (ticks >> 32) as u32;
    return result, if mode == 16384 { 2 } else { 1 };
}

fn absolute(name: const u8[:], out: u8[>..]&) -> bool {
    if out.len != 0 || name.len == 0 { return false; }
    var joined: u8[>..] = [];
    if name[0] == '/' { joined.append(name); }
    else {
        var cwd: u8[>..] = [];
        if !env("PWD", cwd) || cwd.len == 0 || cwd[0] != '/' { return false; }
        joined.append(cwd); joined.push('/'); joined.append(name);
    }
    var normal: u8[>..] = [];
    var start: i64 = 0; var i: i64 = 0;
    while i <= joined.len {
        if i == joined.len || joined[i] == '/' {
            let segment = joined[start..i];
            if segment.len == 2 && segment[0] == '.' && segment[1] == '.' { return false; }
            if segment.len > 0 && !(segment.len == 1 && segment[0] == '.') { normal.push('/'); normal.append(segment); }
            start = i + 1;
        }
        i = i + 1;
    }
    if normal.len == 0 { normal.push('/'); }
    out.append(normal);
    return true;
}

fn compare(a: const u8[:], b: const u8[:]) -> i32 {
    let n = if a.len < b.len { a.len } else { b.len };
    for i in n { if a[i] != b[i] { return if a[i] < b[i] { -1 } else { 1 }; } }
    return if a.len == b.len { 0 } else if a.len < b.len { -1 } else { 1 };
}

fn component(name: const u8[:]) -> bool {
    if name.len == 0 || name.len > 255 { return false; }
    if name.len == 1 && name[0] == '.' { return false; }
    if name.len == 2 && name[0] == '.' && name[1] == '.' { return false; }
    for b in name { if b < 32 || b == 127 || b == '/' || b == '\\' { return false; } }
    return true;
}

fn safe(name: const u8[:]) -> bool {
    if name.len < 1 || name[0] != '/' { return false; }
    for i in 1..name.len + 1 {
        if i < name.len && name[i] != '/' { continue; }
        let data, kind = info(name[..i]);
        if kind == 3 || kind == 4 { return false; }
        if i < name.len && kind != 0 && kind != 2 { return false; }
    }
    return true;
}

fn parents(name: const u8[:]) -> bool {
    for i in 1..name.len {
        if name[i] != '/' { continue; }
        let data, kind = info(name[..i]);
        if kind == 0 { if !make_dir(name[..i]) { return false; } }
        else if kind != 2 { return false; }
    }
    return true;
}

// FILETIME (100 ns ticks since 1601) to a timespec for the modification time only.
// atime is left unchanged with UTIME_OMIT.
fn set_time(name: const u8[:], value: u64) -> bool {
    var cpath: u8[>..] = [];
    if !posix_c_string(name, cpath) { return false; }
    let seconds = (value / 10000000) as i64 - 11644473600;
    if seconds < 0 { return false; }
    let nanos = (value % 10000000) * 100;
    var times: u8[>..] = [];
    write_le(times, 0, 8); write_le(times, 1073741822, 8);
    write_le(times, seconds as u64, 8); write_le(times, nanos, 8);
    return posix_utimensat(-100, cpath[0], times[0], 0) == 0;
}
