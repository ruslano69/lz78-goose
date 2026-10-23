// SPDX-License-Identifier: MIT
namespace gsunicode;
import std;

fn scalar(data: const u8[:], pos: i64&) -> u32, bool {
    if pos >= data.len { return 0, false; }
    let a = data[pos]; pos++;
    if a < 128 { return a as u32, true; }
    var count: i64 = 0;
    var value: u32 = 0;
    var minimum: u32 = 0;
    if a >= 194 && a <= 223 { count = 1; value = (a & 31) as u32; minimum = 128; }
    else if a >= 224 && a <= 239 { count = 2; value = (a & 15) as u32; minimum = 2048; }
    else if a >= 240 && a <= 244 { count = 3; value = (a & 7) as u32; minimum = 65536; }
    else { return 0, false; }
    if data.len - pos < count { return 0, false; }
    for i in count {
        let b = data[pos]; pos++;
        if b < 128 || b > 191 { return 0, false; }
        value = (value << 6) | (b & 63) as u32;
    }
    return value, value >= minimum && value <= 1114111 && !(value >= 55296 && value <= 57343);
}

fn put_utf8(value: u32, out: u8[>..]&) -> bool {
    if value > 1114111 || (value >= 55296 && value <= 57343) { return false; }
    if value < 128 { out.push(value as u8); }
    else if value < 2048 {
        out.push((192 | (value >> 6)) as u8); out.push((128 | (value & 63)) as u8);
    } else if value < 65536 {
        out.push((224 | (value >> 12)) as u8); out.push((128 | ((value >> 6) & 63)) as u8); out.push((128 | (value & 63)) as u8);
    } else {
        out.push((240 | (value >> 18)) as u8); out.push((128 | ((value >> 12) & 63)) as u8);
        out.push((128 | ((value >> 6) & 63)) as u8); out.push((128 | (value & 63)) as u8);
    }
    return true;
}

fn to_utf16(data: const u8[:], out: u16[>..]&, terminate: bool = true) -> bool {
    var pos: i64 = 0;
    while pos < data.len {
        let cp, ok = scalar(data, pos);
        if !ok || cp == 0 { return false; }
        if cp < 65536 { out.push(cp as u16); }
        else {
            let n = cp - 65536;
            out.push((55296 + (n >> 10)) as u16); out.push((56320 + (n & 1023)) as u16);
        }
    }
    if terminate { out.push(0); }
    return true;
}

fn from_utf16(data: const u16[:], out: u8[>..]&) -> bool {
    var pos: i64 = 0;
    while pos < data.len {
        var cp = data[pos] as u32; pos++;
        if cp >= 55296 && cp <= 56319 {
            if pos >= data.len || data[pos] < 56320 || data[pos] > 57343 { return false; }
            cp = 65536 + ((cp - 55296) << 10) + (data[pos] as u32 - 56320); pos++;
        }
        if cp == 0 || !put_utf8(cp, out) { return false; }
    }
    return true;
}
