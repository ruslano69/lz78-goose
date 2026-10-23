// SPDX-License-Identifier: MIT
// Windows x64 filesystem adapter. The archive format module is platform neutral.
namespace gswinfiles;
import std;
import os;
import gsunicode;

struct Info {
    attributes: u32, creation_low: u32, creation_high: u32,
    access_low: u32, access_high: u32, write_low: u32, write_high: u32,
    size_high: u32, size_low: u32
}
struct Time { low: u32, high: u32 }

extern "kernel32.dll" {
    fn GetFileAttributesExW(name: const u16&, level: i32, info: Info&) -> i32;
    fn GetFullPathNameW(name: const u16&, capacity: u32, out: u16&, part: u64) -> u32;
    fn GetLastError() -> u32;
    fn CompareStringOrdinal(a: const u16&, n: i32, b: const u16&, m: i32, ignore_case: i32) -> i32;
    fn CreateFileW(name: const u16&, access: u32, share: u32, security: u64, disposition: u32, flags: u32, template_handle: u64) -> u64;
    fn SetFileTime(handle: u64, creation: u64, access: u64, write: const Time&) -> i32;
    fn CloseHandle(handle: u64) -> i32;
}

// kind: 0 absent, 1 ordinary file, 2 directory, 3 reparse/device, 4 I/O error.
fn info(name: const u8[:]) -> Info, i64 {
    var wide: u16[>..] = [];
    var result = Info { 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    if !gsunicode::to_utf16(name, wide) { return result, 4; }
    if GetFileAttributesExW(wide[0], 0, result) == 0 {
        let code = GetLastError();
        return result, if code == 2 || code == 3 { 0 } else { 4 };
    }
    if (result.attributes & 1088) != 0 { return result, 3; }
    return result, if (result.attributes & 16) != 0 { 2 } else { 1 };
}

fn absolute(name: const u8[:], out: u8[>..]&) -> bool {
    var wide: u16[>..] = [];
    if out.len != 0 || !gsunicode::to_utf16(name, wide) { return false; }
    var buffer: u16[32768] = [0; 32768];
    let length = GetFullPathNameW(wide[0], 32768, buffer[0], 0) as i64;
    if length == 0 || length >= 32768 { return false; }
    if !gsunicode::from_utf16(buffer[..length], out) { return false; }
    for i in out.len { if out[i] == '\\' { out[i] = '/'; } }
    while out.len > 3 && out[out.len - 1] == '/' { out.pop(); }
    // First CLI accepts local drive roots only, including explicitly rooted paths.
    return out.len >= 3 && out[1] == ':' && out[2] == '/';
}

fn compare(a: const u8[:], b: const u8[:]) -> i32 {
    var x: u16[>..] = []; var y: u16[>..] = [];
    if !gsunicode::to_utf16(a, x) || !gsunicode::to_utf16(b, y) { abort("invalid filesystem comparison"); }
    let value = CompareStringOrdinal(x[0], (x.len - 1) as i32, y[0], (y.len - 1) as i32, 1);
    if value == 0 { abort("filesystem comparison failed"); }
    return value - 2;
}

fn component(name: const u8[:]) -> bool {
    if name.len == 0 || name[name.len - 1] == '.' || name[name.len - 1] == ' ' { return false; }
    for b in name { if b < 32 || b == 127 || b == '<' || b == '>' || b == ':' || b == '"' || b == '|' || b == '?' || b == '*' { return false; } }
    var stem: u8[>..] = [];
    for b in name { if b == '.' { break; } stem.push(if b >= 'a' && b <= 'z' { b - 32 } else { b }); }
    while stem.len > 0 && stem[stem.len - 1] == ' ' { stem.pop(); }
    if stem.len == 5 && (stem[..3] == "COM" || stem[..3] == "LPT") && stem[3] == 194 && (stem[4] == 185 || stem[4] == 178 || stem[4] == 179) { return false; }
    if stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" || stem == "CONIN$" || stem == "CONOUT$" { return false; }
    if stem.len == 4 && (stem[..3] == "COM" || stem[..3] == "LPT") && stem[3] >= '1' && stem[3] <= '9' { return false; }
    return true;
}

// Validate existing prefixes, including the chosen root, before any I/O.
// This is a path-based check, not a lock against concurrent filesystem changes.
fn safe(name: const u8[:]) -> bool {
    if name.len < 3 || name[1] != ':' || name[2] != '/' { return false; }
    for i in 3..name.len + 1 {
        if i < name.len && name[i] != '/' { continue; }
        let data, kind = info(name[..i]);
        if kind == 3 || kind == 4 { return false; }
        if i < name.len && kind != 0 && kind != 2 { return false; }
    }
    return true;
}

fn set_time(name: const u8[:], value: u64) -> bool {
    var wide: u16[>..] = [];
    if !gsunicode::to_utf16(name, wide) { return false; }
    let handle = CreateFileW(wide[0], 256, 7, 0, 3, 35651584, 0);
    if handle == ~(0 as u64) { return false; }
    let time = Time { (value & 4294967295) as u32, (value >> 32) as u32 };
    let result = SetFileTime(handle, 0, 0, time) != 0;
    let closed = CloseHandle(handle) != 0;
    return result && closed;
}

fn parents(name: const u8[:]) -> bool {
    for i in 3..name.len {
        if name[i] != '/' { continue; }
        let data, kind = info(name[..i]);
        if kind == 0 { if !make_dir(name[..i]) { return false; } }
        else if kind != 2 { return false; }
    }
    return true;
}
