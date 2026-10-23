// SPDX-License-Identifier: MIT
// Read UTF-16 Windows arguments rather than the CRT's ANSI argv.
namespace gswinargs;
import std;
import ffi;
import gsunicode;

extern "kernel32.dll" {
    fn GetCommandLineW() -> u64;
    fn LocalFree(memory: u64) -> u64;
    fn lstrlenW(text: u64) -> i32;
}
extern "shell32.dll" {
    fn CommandLineToArgvW(command: u64, count: i32&) -> u64;
}

fn count() -> i64 {
    var n: i32 = 0; let argv = CommandLineToArgvW(GetCommandLineW(), n);
    if argv == 0 { abort("cannot read Windows arguments"); }
    LocalFree(argv); return n as i64;
}

fn arg(index: i64, out: u8[>..]&) {
    var n: i32 = 0; let argv = CommandLineToArgvW(GetCommandLineW(), n);
    if argv == 0 { abort("cannot read Windows arguments"); }
    var ok = false;
    if index >= 0 && index < n as i64 && out.len == 0 {
        var pointer: u8[>..] = [];
        if ffi::bytes(argv + index as u64 * 8, 8, pointer) {
            var address: u64 = 0;
            for i in 8 { address |= pointer[i] as u64 << (i * 8); }
            let length = lstrlenW(address) as i64;
            if length >= 0 && length <= 32767 {
                var raw: u8[>..] = [];
                if ffi::bytes(address, length * 2, raw) {
                    var wide: u16[>..] = [];
                    for i in length { wide.push(raw[i * 2] as u16 | (raw[i * 2 + 1] as u16 << 8)); }
                    ok = gsunicode::from_utf16(wide, out);
                }
            }
        }
    }
    // CommandLineToArgvW owns one allocation for the whole vector and strings.
    LocalFree(argv);
    if !ok { abort("invalid Windows argument"); }
}
