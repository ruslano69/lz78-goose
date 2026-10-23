// Original LZ78 experiment. See README.md for the algorithm and file format.
import std;
import dictionary;
import os;

let MAX_BYTES: i64 = 67108864;
let MAX_PHRASES: i64 = 65535;

// The output only grows, so earlier phrases stay addressable by compact offsets.
// A dictionary block has at most 65535 phrases; phrase lengths fit in u16.
struct Range { start: u32, length: u16 }

fn checksum(data: const u8[:]) -> u32 {
    var h: u32 = 2166136261;
    for b in data { h = (h ^ b) * 16777619; }
    return h;
}

fn put_le(out: u8[>..]&, value: u64, width: i64) {
    var v = value;
    for i in width { out.push((v & 255) as u8); v = v >> 8; }
}

fn get_le(data: const u8[:], at: i64, width: i64) -> u64 {
    var value: u64 = 0;
    for i in width { value |= data[at + i] as u64 << (i * 8); }
    return value;
}

fn put_tag(out: u8[>..]&, value: u32) {
    var v = value;
    while v >= 128 { out.push(((v & 127) | 128) as u8); v = v >> 7; }
    out.push(v as u8);
}

// Tags need at most 17 bits: (phrase index << 1) | has_symbol.
fn get_tag(data: const u8[:], pos: i64&) -> u32, bool {
    var value: u32 = 0;
    for i in 3 {
        if pos >= data.len { return 0, false; }
        let b = data[pos]; pos++;
        if i == 2 && b > 7 { return 0, false; }
        value |= (b & 127) as u32 << (i * 7);
        if b < 128 {
            if i > 0 && b == 0 { return 0, false; }
            return value, true;
        }
    }
    return 0, false;
}

fn compress(data: const u8[:], out: u8[>..]&) -> bool {
    if data.len > MAX_BYTES { return false; }
    out.append("LZ78G001");
    put_le(out, data.len as u64, 8);
    put_le(out, checksum(data), 4);
    var edges = dictionary<u64, u32> {};
    var next: u32 = 1;
    var prefix: u32 = 0;
    for b in data {
        let key = (prefix as u64 << 8) | b;
        var found: u32 = 0;
        {
            let entry = edges.get(key);
            if entry { found = entry; }
        }
        if found != 0 { prefix = found; continue; }
        put_tag(out, (prefix << 1) | 1);
        out.push(b);
        edges.insert(key, next);
        next++;
        prefix = 0;
        if next > MAX_PHRASES {
            edges.clear();
            next = 1;
        }
    }
    // A final phrase already present in the dictionary has no following byte.
    if prefix != 0 { put_tag(out, prefix << 1); }
    return true;
}

fn decompress(data: const u8[:], out: u8[>..]&) -> bool {
    if data.len < 20 || data[..8] != "LZ78G001" { return false; }
    let size = get_le(data, 8, 8);
    if size > MAX_BYTES as u64 { return false; }
    let expected = size as i64;
    let sum = get_le(data, 16, 4) as u32;
    var phrases: Range[>..<] = [];
    phrases.push(Range { 0, 0 });
    var pos: i64 = 20;
    while pos < data.len {
        let tag, ok = get_tag(data, pos);
        if !ok { return false; }
        let index = (tag >> 1) as i64;
        let has_symbol = (tag & 1) != 0;
        if index >= phrases.len { return false; }
        if !has_symbol && (index == 0 || pos != data.len) { return false; }
        if has_symbol && pos == data.len { return false; }
        let length = phrases[index].length + (if has_symbol { 1 } else { 0 });
        if length > expected - out.len { return false; }
        let start = out.len;
        let from = phrases[index].start as i64;
        let count = phrases[index].length as i64;
        out.append(out[from..from + count]);
        if has_symbol {
            let symbol = data[pos]; pos++;
            out.push(symbol);
            phrases.push(Range { start: start as u32, length: length });
            if phrases.len > MAX_PHRASES {
                phrases.clear();
                phrases.push(Range { 0, 0 });
            }
        }
    }
    return out.len == expected && checksum(out) == sum;
}

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
    let ok = if mode == "c" { compress(input, output) } else { decompress(input, output) };
    if !ok { write_stderr("invalid archive or size limit exceeded\n"); exit(1); }
    if !write_file_atomic(target, output) { write_stderr("cannot write output\n"); exit(1); }
    print(input.len, " -> ", output.len, " bytes");
}
