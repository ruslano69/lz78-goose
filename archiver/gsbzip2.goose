// SPDX-License-Identifier: MIT
// Original implementation of the public BZip2 bitstream format.
namespace gsbzip2;
import std;

let MAX_FILE: i64 = 67108864;
let DEFAULT_LEVEL: i64 = 3;
struct Bits { pos: i64, value: u64, count: i64, failed: bool }

// MSB first, at most 32 bits per operation; at most 39 bits live in value.
fn put(out: u8[>..]&, b: Bits&, value: u32, width: i64) {
    b.value = (b.value << width) | value as u64; b.count += width;
    while b.count >= 8 {
        b.count -= 8; out.push(((b.value >> b.count) & 255) as u8);
    }
    b.value &= (1 as u64 << b.count) - 1;
}

fn get(data: const u8[:], b: Bits&, width: i64) -> u32 {
    if b.failed { return 0; }
    while b.count < width {
        if b.pos >= data.len { b.failed = true; return 0; }
        b.value = (b.value << 8) | data[b.pos] as u64; b.pos++; b.count += 8;
    }
    b.count -= width;
    let value = ((b.value >> b.count) & ((1 as u64 << width) - 1)) as u32;
    b.value &= (1 as u64 << b.count) - 1;
    return value;
}

fn crc_table(table: u32[:]) {
    for i in 256 {
        var c = i as u32 << 24;
        for j in 8 { c = if (c & 2147483648) != 0 { (c << 1) ^ 79764919 } else { c << 1 }; }
        table[i] = c;
    }
}

fn crc_byte(c: u32, value: u8, table: const u32[:]) -> u32 {
    return (c << 8) ^ table[((c >> 24) ^ value as u32) as i64];
}

// Four u32 arrays, 16*N bytes: bounded cyclic prefix doubling. Scratch dies
// on return, before the u16 MTF buffer is allocated. Positions need no u64.
fn rotations(data: const u8[:], order: u32[>..]&) {
    let n = data.len;
    var ranks: u32[>..] = []; ranks.resize(n, 0);
    var work: u32[>..] = []; work.resize(n, 0);
    var counts: u32[>..] = []; counts.resize(max(n, 256), 0);
    order.resize(n, 0);
    for x in data { counts[x as i64]++; }
    var sum: u32 = 0;
    for i in 256 { let v = counts[i]; counts[i] = sum; sum += v; }
    for i in n { let c = data[i] as i64; order[counts[c] as i64] = i as u32; counts[c]++; }
    var classes: i64 = 0;
    for i in n {
        if i == 0 || data[order[i] as i64] != data[order[i - 1] as i64] { classes++; }
        ranks[order[i] as i64] = (classes - 1) as u32;
    }
    var width: i64 = 1;
    while width < n && classes < n {
        fill(counts[..classes], 0);
        for r in ranks { counts[r as i64]++; }
        sum = 0;
        for i in classes { let v = counts[i]; counts[i] = sum; sum += v; }
        for p in order {
            let at = if p as i64 >= width { p as i64 - width } else { p as i64 + n - width };
            let c = ranks[at] as i64;
            work[counts[c] as i64] = at as u32; counts[c]++;
        }
        // Counts are dead now: reuse them for the next ranks, indexed by position.
        classes = 1; counts[work[0] as i64] = 0;
        for i in 1..n {
            let a = work[i - 1] as i64; let c = work[i] as i64;
            if ranks[a] != ranks[c] || ranks[(a + width) % n] != ranks[(c + width) % n] { classes++; }
            counts[c] = (classes - 1) as u32;
        }
        for i in n { order[i] = work[i]; ranks[i] = counts[i]; }
        width *= 2;
    }
}

// RLE1 groups are indivisible. A run of 4..259 bytes becomes five bytes;
// capacity limits the transformed block, not its original size.
fn rle_block(input: const u8[:], pos: i64&, capacity: i64, out: u8[>..]&, table: const u32[:]) -> u32 {
    var crc: u32 = 4294967295;
    while pos < input.len {
        let value = input[pos];
        var run: i64 = 1;
        while run < 259 && pos + run < input.len && input[pos + run] == value { run++; }
        let size = if run < 4 { run } else { 5 };
        if size > capacity - out.len { break; }
        for i in min(run, 4) { out.push(value); }
        if run >= 4 { out.push((run - 4) as u8); }
        for i in run { crc = crc_byte(crc, value, table); }
        pos += run;
    }
    return ~crc;
}

fn zero_run(out: u16[>..]&, count: i64) {
    var n = count;
    while n > 0 {
        n--; out.push((n & 1) as u16); n /= 2;
    }
}

// Emit the BWT column straight into MTF/RUNA/RUNB: no byte-column copy.
fn mtf(data: const u8[:], order: const u32[:], used: const u8[:], symbols: u16[>..]&, primary: u32&) {
    var list: u8[256] = [0; 256];
    var active: i64 = 0;
    for i in 256 { if used[i] != 0 { list[active] = i as u8; active++; } }
    var zeros: i64 = 0;
    for row in order.len {
        let at = order[row] as i64;
        if at == 0 { primary = row as u32; }
        let value = data[if at == 0 { data.len - 1 } else { at - 1 }];
        var rank: i64 = 0;
        while list[rank] != value { rank++; }
        if rank == 0 { zeros++; continue; }
        zero_run(symbols, zeros); zeros = 0;
        symbols.push((rank + 1) as u16);
        var j = rank;
        while j > 0 { list[j] = list[j - 1]; j--; }
        list[0] = value;
    }
    zero_run(symbols, zeros); symbols.push((active + 1) as u16);
}

// Positive weights make a complete tree. Rescale if its depth exceeds 20;
// no clipping of lengths, which could create an oversubscribed code.
fn lengths_for(freq: const u32[:], lengths: u8[:]) {
    let n = freq.len;
    var weights: u32[515] = [0; 515];
    var parents: i16[515] = [-1; 515];
    for i in n { weights[i] = max(freq[i], 1); }
    while true {
        fill(parents, -1);
        var nodes = n;
        while nodes < 2 * n - 1 {
            var a: i64 = -1; var b: i64 = -1;
            for i in nodes {
                if parents[i] >= 0 { continue; }
                if a < 0 || weights[i] < weights[a] { b = a; a = i; }
                else if b < 0 || weights[i] < weights[b] { b = i; }
            }
            weights[nodes] = weights[a] + weights[b]; parents[a] = nodes as i16; parents[b] = nodes as i16; nodes++;
        }
        var deepest: i64 = 0;
        for i in n {
            var p = i; var depth: i64 = 0;
            while parents[p] >= 0 { p = parents[p] as i64; depth++; }
            lengths[i] = depth as u8; deepest = max(deepest, depth);
        }
        if deepest <= 20 { return; }
        for i in n { weights[i] = weights[i] / 2 + 1; }
    }
}

// Canonical first codes, lengths and permutation; fixed-size caller storage.
// Incomplete trees are safe to decode; missing bit patterns fail to resolve.
fn canonical(lengths: const u8[:], counts: u32[:], first: u32[:], perm: u16[:]) -> bool {
    fill(counts, 0); fill(first, 0);
    for length in lengths { if length == 0 || length > 20 { return false; } counts[length as i64]++; }
    var code: u32 = 0; var at: i64 = 0;
    for width in 1..21 {
        code = (code + counts[width - 1]) << 1; first[width] = code;
        if code + counts[width] > (1 as u32 << width) { return false; }
        for i in lengths.len { if lengths[i] as i64 == width { perm[at] = i as u16; at++; } }
    }
    return true;
}

// Four refinement passes select 2..6 Huffman tables for groups of 50 symbols.
// Only selectors scale with N (one u8 per group); all tables are fixed.
fn entropy(symbols: const u16[:], alphabet: i64, out: u8[>..]&, bits: Bits&) {
    let groups: i64 = if symbols.len < 200 { 2 } else if symbols.len < 600 { 3 } else if symbols.len < 1200 { 4 } else if symbols.len < 2400 { 5 } else { 6 };
    var lengths: u8[1548] = [0; 1548]; var freqs: u32[1548] = [0; 1548];
    var selectors: u8[>..] = []; selectors.resize((symbols.len + 49) / 50, 0);
    // Seed distinct, contiguous alphabet regions. Refinement adapts to data.
    for t in groups {
        for i in alphabet { lengths[t * 258 + i] = if i * groups / alphabet == t { 0 } else { 15 }; }
    }
    for pass in 4 {
        fill(freqs, 0);
        for chunk in selectors.len {
            let start = chunk * 50; let end = min(start + 50, symbols.len);
            var best: i64 = 0; var cost: u32 = 4294967295;
            for t in groups {
                var total: u32 = 0;
                for i in start..end { total += lengths[t * 258 + symbols[i] as i64] as u32; }
                if total < cost { cost = total; best = t; }
            }
            selectors[chunk] = best as u8;
            for i in start..end { freqs[best * 258 + symbols[i] as i64]++; }
        }
        for t in groups { lengths_for(freqs[t * 258..t * 258 + alphabet], lengths[t * 258..t * 258 + alphabet]); }
    }
    put(out, bits, groups as u32, 3); put(out, bits, selectors.len as u32, 15);
    var list: u8[6] = [0, 1, 2, 3, 4, 5];
    for t in selectors {
        var rank: i64 = 0; while list[rank] != t { rank++; }
        for j in rank { put(out, bits, 1, 1); } put(out, bits, 0, 1);
        var j = rank; while j > 0 { list[j] = list[j - 1]; j--; } list[0] = t;
    }
    var codes: u32[1548] = [0; 1548];
    for t in groups {
        var current = lengths[t * 258] as i64; put(out, bits, current as u32, 5);
        for i in alphabet {
            let target = lengths[t * 258 + i] as i64;
            while current < target { put(out, bits, 2, 2); current++; }
            while current > target { put(out, bits, 3, 2); current--; }
            put(out, bits, 0, 1);
        }
        var counts: u32[21] = [0; 21]; var first: u32[21] = [0; 21]; var perm: u16[258] = [0; 258];
        canonical(lengths[t * 258..t * 258 + alphabet], counts, first, perm);
        for i in alphabet { let at = t * 258 + i; let width = lengths[at] as i64; codes[at] = first[width]; first[width]++; }
    }
    for i in symbols.len {
        let at = selectors[i / 50] as i64 * 258 + symbols[i] as i64;
        put(out, bits, codes[at], lengths[at] as i64);
    }
}

fn encode_block(data: const u8[:], crc: u32, out: u8[>..]&, bits: Bits&) {
    var used: u8[256] = [0; 256]; for value in data { used[value as i64] = 1; }
    var alphabet: i64 = 2; for v in used { alphabet += v as i64; }
    var symbols: u16[>..] = []; var primary: u32 = 0;
    {
        var order: u32[>..] = []; rotations(data, order);
        mtf(data, order, used, symbols, primary);
    }
    put(out, bits, 0x314159, 24); put(out, bits, 0x265359, 24);
    put(out, bits, crc, 32); put(out, bits, 0, 1); put(out, bits, primary, 24);
    for group in 16 {
        var any = false; for i in 16 { if used[group * 16 + i] != 0 { any = true; } }
        put(out, bits, if any { 1 } else { 0 }, 1);
    }
    for group in 16 {
        var any = false; for i in 16 { if used[group * 16 + i] != 0 { any = true; } }
        if any { for i in 16 { put(out, bits, used[group * 16 + i] as u32, 1); } }
    }
    entropy(symbols, alphabet, out, bits);
}

fn compress(input: const u8[:], out: u8[>..]&, level: i64) -> bool {
    if out.len != 0 { return false; }
    return append_stream(input, out, level);
}
fn append_stream(input: const u8[:], out: u8[>..]&, level: i64) -> bool {
    if input.len > MAX_FILE || level < 1 || level > 9 { return false; }
    out.append("BZh"); out.push(('0' as i64 + level) as u8);
    var bits = Bits { 0, 0, 0, false }; var pos: i64 = 0; var combined: u32 = 0;
    var table: u32[256] = [0; 256]; crc_table(table);
    while pos < input.len {
        var rle: u8[>..] = [];
        let crc = rle_block(input, pos, level * 100000, rle, table);
        encode_block(rle, crc, out, bits);
        combined = ((combined << 1) | (combined >> 31)) ^ crc;
    }
    put(out, bits, 0x177245, 24); put(out, bits, 0x385090, 24); put(out, bits, combined, 32);
    if bits.count > 0 { put(out, bits, 0, 8 - bits.count); }
    return true;
}


// Symbol decoder consumes one selector per 50 symbols, including RUNA/RUNB/EOB.
fn symbol(data: const u8[:], bits: Bits&, selectors: const u8[:], ordinal: i64&, counts: const u32[:], first: const u32[:], perm: const u16[:]) -> i64 {
    let chunk = ordinal / 50; ordinal++;
    if chunk >= selectors.len { bits.failed = true; return -1; }
    let t = selectors[chunk] as i64;
    var code: u32 = 0; var offset: u32 = 0;
    for width in 1..21 {
        code = (code << 1) | get(data, bits, 1);
        let at = t * 21 + width;
        if code >= first[at] && code - first[at] < counts[at] {
            return perm[t * 258 + (offset + code - first[at]) as i64] as i64;
        }
        offset += counts[at];
    }
    bits.failed = true; return -1;
}

// u32 cells hold the BWT byte in bits 0..7 and the next index in bits 8..31.
// No second BWT column or RLE output buffer; expand directly to final output.
fn restore(tt: u32[:], primary: i64, out: u8[>..]&, limit: i64, table: const u32[:]) -> u32, bool {
    let n = tt.len; if primary >= n || n == 0 { return 0, false; }
    var starts: u32[256] = [0; 256];
    for cell in tt { starts[(cell & 255) as i64]++; }
    var sum: u32 = 0;
    for i in 256 { let v = starts[i]; starts[i] = sum; sum += v; }
    for i in n {
        let c = (tt[i] & 255) as i64; let target = starts[c] as i64;
        tt[target] |= i as u32 << 8; starts[c]++;
    }
    var row = (tt[primary] >> 8) as i64;
    var previous: u8 = 0; var run: i64 = 0; var crc: u32 = 4294967295;
    for i in n {
        let value = (tt[row] & 255) as u8; row = (tt[row] >> 8) as i64;
        if run == 4 {
            let extra = value as i64;
            if extra > limit - out.len { return 0, false; }
            out.resize(out.len + extra, previous);
            for j in extra { crc = crc_byte(crc, previous, table); }
            run = 0;
        } else {
            if out.len >= limit { return 0, false; }
            out.push(value); crc = crc_byte(crc, value, table);
            run = if run > 0 && previous == value { run + 1 } else { 1 }; previous = value;
        }
    }
    return ~crc, run != 4;
}

fn decode_block(data: const u8[:], bits: Bits&, capacity: i64, out: u8[>..]&, limit: i64, table: const u32[:]) -> u32, bool {
    let crc = get(data, bits, 32);
    if get(data, bits, 1) != 0 { return 0, false; } // obsolete randomized blocks unsupported
    let primary = get(data, bits, 24) as i64;
    var used: u8[16] = [0; 16]; for i in 16 { used[i] = get(data, bits, 1) as u8; }
    var list: u8[256] = [0; 256]; var active: i64 = 0;
    for group in 16 { if used[group] != 0 { for i in 16 { if get(data, bits, 1) != 0 { list[active] = (group * 16 + i) as u8; active++; } } } }
    let alphabet = active + 2; let groups = get(data, bits, 3) as i64; let count = get(data, bits, 15) as i64;
    if bits.failed || active == 0 || groups < 2 || groups > 6 || count == 0 || count > 32767 { return 0, false; }
    var selectors: u8[>..] = []; var group_list: u8[6] = [0, 1, 2, 3, 4, 5];
    for i in count {
        var rank: i64 = 0;
        while get(data, bits, 1) != 0 { rank++; if rank >= groups { return 0, false; } }
        if bits.failed { return 0, false; }
        let value = group_list[rank]; var j = rank;
        while j > 0 { group_list[j] = group_list[j - 1]; j--; } group_list[0] = value;
        // Some producers pad the selector list. Parse all, retain only usable ones.
        if i < 18002 { selectors.push(value); }
    }
    var counts: u32[126] = [0; 126]; var first: u32[126] = [0; 126]; var perm: u16[1548] = [0; 1548];
    for t in groups {
        var lengths: u8[258] = [0; 258]; var current = get(data, bits, 5) as i64;
        for i in alphabet {
            while true {
                if bits.failed || current < 1 || current > 20 { return 0, false; }
                if get(data, bits, 1) == 0 { break; }
                current += if get(data, bits, 1) == 0 { 1 } else { -1 };
            }
            lengths[i] = current as u8;
        }
        if !canonical(lengths[..alphabet], counts[t * 21..t * 21 + 21], first[t * 21..t * 21 + 21], perm[t * 258..t * 258 + alphabet]) { return 0, false; }
    }
    var tt: u32[>..] = []; var ordinal: i64 = 0;
    var value = symbol(data, bits, selectors, ordinal, counts, first, perm);
    while value != active + 1 {
        if bits.failed || value < 0 { return 0, false; }
        if value <= 1 {
            var run: i64 = 0; var weight: i64 = 1;
            while value == 0 || value == 1 {
                run += (value + 1) * weight;
                if run > capacity - tt.len { return 0, false; }
                weight *= 2;
                value = symbol(data, bits, selectors, ordinal, counts, first, perm);
                if bits.failed { return 0, false; }
            }
            tt.resize(tt.len + run, list[0] as u32);
        } else {
            let rank = value - 1;
            if rank >= active || tt.len >= capacity { return 0, false; }
            let ch = list[rank]; var j = rank;
            while j > 0 { list[j] = list[j - 1]; j--; } list[0] = ch;
            tt.push(ch as u32);
            value = symbol(data, bits, selectors, ordinal, counts, first, perm);
        }
    }
    if bits.failed || primary >= tt.len { return 0, false; }
    let actual, ok = restore(tt, primary, out, limit, table);
    return crc, ok && actual == crc;
}

// One exact modern BZip2 stream. limit is the caller's expected upper bound,
// checked during RLE expansion, not after allocating untrusted output.
fn decompress(data: const u8[:], out: u8[>..]&, limit: i64) -> bool {
    if out.len != 0 || limit < 0 || limit > MAX_FILE || data.len < 14 || data[..3] != "BZh" || data[3] < '1' || data[3] > '9' { return false; }
    let capacity = (data[3] - '0') as i64 * 100000;
    var bits = Bits { 4, 0, 0, false }; var combined: u32 = 0;
    var table: u32[256] = [0; 256]; crc_table(table);
    while !bits.failed {
        let high = get(data, bits, 24); let low = get(data, bits, 24);
        if high == 0x177245 && low == 0x385090 {
            let crc = get(data, bits, 32);
            return !bits.failed && crc == combined && bits.value == 0 && bits.pos == data.len;
        }
        if high != 0x314159 || low != 0x265359 { return false; }
        let crc, ok = decode_block(data, bits, capacity, out, limit, table);
        if !ok { return false; }
        combined = ((combined << 1) | (combined >> 31)) ^ crc;
    }
    return false;
}
