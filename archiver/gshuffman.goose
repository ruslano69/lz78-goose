// SPDX-License-Identifier: MIT
namespace gshuffman;
import std;

let ALPHABET: i64 = 257;
let MAX_BITS: i64 = 24;
let HEADER: i64 = 265;

fn put32(out: u8[>..]&, value: u32) {
    for i in 4 { out.push(((value >> (i * 8)) & 255) as u8); }
}

fn get32(data: const u8[:], at: i64) -> u32 {
    var value: u32 = 0;
    for i in 4 { value |= data[at + i] as u32 << (i * 8); }
    return value;
}

// Counts and first codes form the canonical decoder. Refuse incomplete and
// oversubscribed trees, except a singleton represented by one zero bit.
fn canonical(lengths: const u8[:], counts: u32[:], first: u32[:]) -> bool {
    if lengths.len != ALPHABET || counts.len != 25 || first.len != 25 { return false; }
    fill(counts, 0); fill(first, 0);
    var active: i64 = 0;
    for length in lengths {
        if length > MAX_BITS { return false; }
        if length > 0 { counts[length as i64]++; active++; }
    }
    if active == 0 { return false; }
    var code: u32 = 0;
    for bits in 1..25 {
        code = (code + counts[bits - 1]) << 1;
        first[bits] = code;
        if code + counts[bits] > (1 as u32 << bits) { return false; }
    }
    if active == 1 { return counts[1] == 1; }
    return code + counts[24] == (1 as u32 << 24);
}

// Deterministic tree: among equal weights, the smaller node index wins.
fn lengths_for(data: const u16[:], lengths: u8[:]) -> bool {
    if lengths.len != ALPHABET || data.len == 0 || data.len > 4194304 { return false; }
    fill(lengths, 0);
    var weights: u32[513] = [0; 513];
    var parents: i16[513] = [-1; 513];
    for symbol in data {
        if symbol >= ALPHABET { return false; }
        weights[symbol as i64]++;
    }
    var nodes: i64 = ALPHABET;
    while true {
        var left: i64 = -1;
        var right: i64 = -1;
        for i in nodes {
            if weights[i] == 0 || parents[i] >= 0 { continue; }
            if left < 0 || weights[i] < weights[left] { right = left; left = i; }
            else if right < 0 || weights[i] < weights[right] { right = i; }
        }
        if right < 0 { break; }
        weights[nodes] = weights[left] + weights[right];
        parents[left] = nodes as i16; parents[right] = nodes as i16;
        nodes++;
    }
    for i in ALPHABET {
        if weights[i] == 0 { continue; }
        var node = i;
        var depth: i64 = 0;
        while parents[node] >= 0 { depth++; node = parents[node] as i64; }
        if depth == 0 { depth = 1; }
        if depth > MAX_BITS { return false; }
        lengths[i] = depth as u8;
    }
    return true;
}

fn encode(data: const u16[:], out: u8[>..]&) -> bool {
    if out.len != 0 { return false; }
    var lengths: u8[257] = [0; 257];
    if !lengths_for(data, lengths) { return false; }
    var counts: u32[25] = [0; 25];
    var first: u32[25] = [0; 25];
    if !canonical(lengths, counts, first) { return false; }
    var next = first;
    var codes: u32[257] = [0; 257];
    for i in ALPHABET {
        let n = lengths[i] as i64;
        if n > 0 { codes[i] = next[n]; next[n]++; }
    }
    var bits: u32 = 0;
    for symbol in data { bits += lengths[symbol as i64] as u32; }
    put32(out, data.len as u32); put32(out, bits); out.append(lengths);
    var pending: u64 = 0;
    var used: i64 = 0;
    for symbol in data {
        let i = symbol as i64;
        let n = lengths[i] as i64;
        pending = (pending << n) | codes[i] as u64;
        used += n;
        while used >= 8 {
            used -= 8;
            out.push(((pending >> used) & 255) as u8);
        }
        pending &= (1 as u64 << used) - 1;
    }
    if used > 0 { out.push((pending << (8 - used)) as u8); }
    return true;
}

fn decode(data: const u8[:], limit: i64, out: u16[>..]&) -> bool {
    if out.len != 0 || data.len < HEADER || limit <= 0 || limit > 4194304 { return false; }
    let size = get32(data, 0) as i64;
    let bits = get32(data, 4) as i64;
    if size == 0 || size > limit || bits < size || bits > MAX_BITS * size || data.len != HEADER + (bits + 7) / 8 { return false; }
    let lengths = data[8..HEADER];
    var counts: u32[25] = [0; 25];
    var first: u32[25] = [0; 25];
    if !canonical(lengths, counts, first) { return false; }
    var offsets: i64[25] = [0; 25];
    var total: i64 = 0;
    for n in 1..25 { offsets[n] = total; total += counts[n] as i64; }
    var next = offsets;
    var ordered: u16[257] = [0; 257];
    for i in ALPHABET {
        let n = lengths[i] as i64;
        if n > 0 { ordered[next[n]] = i as u16; next[n]++; }
    }
    var code: u32 = 0;
    var length: i64 = 0;
    for pos in bits {
        code = (code << 1) | ((data[HEADER + pos / 8] >> (7 - pos % 8)) & 1) as u32;
        length++;
        if length > MAX_BITS { return false; }
        if code >= first[length] && code - first[length] < counts[length] {
            if out.len >= size { return false; }
            out.push(ordered[offsets[length] + (code - first[length]) as i64]);
            code = 0; length = 0;
        }
    }
    let padding = (8 - bits % 8) % 8;
    if padding > 0 && (data[data.len - 1] & ((1 as u8 << padding) - 1)) != 0 { return false; }
    return length == 0 && out.len == size;
}
