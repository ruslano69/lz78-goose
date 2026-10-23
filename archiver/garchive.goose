// SPDX-License-Identifier: MIT
namespace garchive;
import std;
import bwt;
import gsmtf;
import gshuffman;

let MAX_FILE: i64 = 67108864;
let MIN_BLOCK: i64 = 65536;
let MAX_BLOCK: i64 = 4194304;
let DEFAULT_BLOCK: i64 = 1048576;
let HEADER: i64 = 24;
let FRAME: i64 = 17;

fn crc32(data: const u8[:]) -> u32 {
    var table: u32[256] = [0; 256];
    for i in 256 {
        var c = i as u32;
        for bit in 8 {
            c = if (c & 1) != 0 { (c >> 1) ^ 3988292384 } else { c >> 1 };
        }
        table[i] = c;
    }
    var c: u32 = 4294967295;
    for byte in data { c = table[((c ^ byte as u32) & 255) as i64] ^ (c >> 8); }
    return ~c;
}

fn put_le(out: u8[>..]&, value: u64, width: i64) {
    for i in width { out.push(((value >> (i * 8)) & 255) as u8); }
}

// Callers check the complete header before requesting any field.
fn get_le(data: const u8[:], at: i64, width: i64) -> u64 {
    var value: u64 = 0;
    for i in width { value |= data[at + i] as u64 << (i * 8); }
    return value;
}

fn encode_block(data: const u8[:], out: u8[>..]&) -> bool {
    var primary: u32 = 0;
    var payload: u8[>..] = [];
    var packed = false;
    // The Huffman header alone costs 265 bytes, so tiny blocks cannot win.
    if data.len > gshuffman::HEADER {
        var last: u8[>..] = [];
        if !bwt::forward(data, last, primary) { return false; }
        var symbols: u16[>..] = [];
        if !gsmtf::encode(last, symbols) { return false; }
        packed = gshuffman::encode(symbols, payload) && payload.len < data.len;
    }
    out.push(if packed { 1 } else { 0 });
    put_le(out, data.len as u64, 4);
    put_le(out, (if packed { payload.len } else { data.len }) as u64, 4);
    put_le(out, (if packed { primary } else { 0 }) as u64, 4);
    put_le(out, crc32(data) as u64, 4);
    if packed { out.append(payload); } else { out.append(data); }
    return true;
}

fn compress(data: const u8[:], out: u8[>..]&, block_size: i64 = 1048576) -> bool {
    if out.len != 0 || data.len > MAX_FILE || block_size < MIN_BLOCK || block_size > MAX_BLOCK { return false; }
    out.append("GARC0001");
    put_le(out, block_size as u64, 4);
    put_le(out, data.len as u64, 8);
    put_le(out, crc32(data) as u64, 4);
    var pos: i64 = 0;
    while pos < data.len {
        let n = min(block_size, data.len - pos);
        if !encode_block(data[pos..pos + n], out) { return false; }
        pos += n;
    }
    return true;
}

fn decode_block(payload: const u8[:], method: u8, size: i64, primary: u32, checksum: u32, out: u8[>..]&) -> bool {
    if method == 0 {
        if primary != 0 || payload.len != size || crc32(payload) != checksum { return false; }
        out.append(payload);
        return true;
    }
    if method != 1 || payload.len >= size || primary == 0 || primary as i64 > size { return false; }
    var symbols: u16[>..] = [];
    if !gshuffman::decode(payload, size, symbols) { return false; }
    var last: u8[>..] = [];
    if !gsmtf::decode(symbols, size, last) { return false; }
    var restored: u8[>..] = [];
    if !bwt::inverse(last, primary, restored) || crc32(restored) != checksum { return false; }
    out.append(restored);
    return true;
}

fn decompress(data: const u8[:], out: u8[>..]&) -> bool {
    if out.len != 0 || data.len < HEADER || data[..8] != "GARC0001" { return false; }
    let block_size = get_le(data, 8, 4);
    let size = get_le(data, 12, 8);
    let checksum = get_le(data, 20, 4) as u32;
    if block_size < MIN_BLOCK || block_size > MAX_BLOCK || size > MAX_FILE { return false; }
    let total = size as i64;
    var pos = HEADER;
    while out.len < total {
        if data.len - pos < FRAME { return false; }
        let method = data[pos];
        let n = get_le(data, pos + 1, 4) as i64;
        let stored = get_le(data, pos + 5, 4) as i64;
        let primary = get_le(data, pos + 9, 4) as u32;
        let crc = get_le(data, pos + 13, 4) as u32;
        pos += FRAME;
        if n != min(block_size as i64, total - out.len) || stored <= 0 || stored > data.len - pos { return false; }
        if !decode_block(data[pos..pos + stored], method, n, primary, crc, out) { return false; }
        pos += stored;
    }
    return pos == data.len && out.len == total && crc32(out) == checksum;
}
