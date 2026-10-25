// SPDX-License-Identifier: MIT
//
// Written from RFC 1951 and zlib's published design. The lazy matching and its measure of a
// better match (4 for each byte longer, 1 for each power of two nearer) follow libdeflate's
// (https://github.com/ebiggers/libdeflate, MIT, Eric Biggers). Checked against zlib in both
// directions by verify_deflate.py. A standalone codec: the 7z writer does not use it.
namespace gsdeflate;
import std;
import os;

// RFC 1951 raw DEFLATE. Output is appended to `out`; a stream is one or more blocks.
let WINDOW: i64 = 32768;
let WMASK: i64 = 32767;
let MIN_MATCH: i64 = 3;
let MAX_MATCH: i64 = 258;
let MAX_CHAIN: i64 = 32;

// Matches at least this long skip the lazy check (as zlib does at its mid levels).
let LAZY_LIMIT: i64 = 8;
// A match this long ends the search: a longer one is not worth the chain walk.
let NICE_MATCH: i64 = 48;
let BLOCK_BYTES: i64 = 65536;
let MAX_STORED: i64 = 65535;

let LEN_BASE: u16[29] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
let LEN_EXTRA: u8[29] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
let DIST_BASE: u16[30] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
let DIST_EXTRA: u8[30] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
let CLEN_ORDER: u8[19] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
let CLEN_EXTRA: u8[19] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 7];

struct Bw { acc: u64, count: i64 }
struct Br { pos: i64, acc: u64, count: i64, filler: i64 }
struct Match { len: i64, dist: i64 }
// Primary table: codes up to PRIMARY bits, indexed by the next PRIMARY input bits (constant mask).
// Longer codes have entry 0 and are decoded from `symbol` one bit at a time.
struct Huff { table: u32[1024], count: i64[16], symbol: u16[288] }
struct Dyn { lit: i64, dst: i64 }

// Bits collect in a 64-bit buffer and leave 4 bytes at a time, so the buffer holds fewer
// than 32 bits between calls (a code adds at most 15, an extra field at most 13).
fn put(out: u8[>..]&, bw: Bw&, value: u32, width: i64) {
    bw.acc = bw.acc | ((value as u64) << (bw.count as u64));
    bw.count = bw.count + width;
    if bw.count >= 32 {
        for i in 4 { out.push(((bw.acc >> (i * 8)) & 255) as u8); }
        bw.acc = bw.acc >> 32;
        bw.count = bw.count - 32;
    }
}

// Pads to a byte boundary and writes out every pending bit: up to 4 bytes.
fn flush_partial(out: u8[>..]&, bw: Bw&) {
    while bw.count > 0 {
        out.push((bw.acc & 255) as u8);
        bw.acc = bw.acc >> 8;
        bw.count = bw.count - 8;
    }
    bw.acc = 0;
    bw.count = 0;
}

fn reverse_bits(code: i64, len: i64) -> u32 {
    var r: i64 = 0;
    var c = code;
    for i in len {
        r = (r << 1) | (c & 1);
        c = c >> 1;
    }
    return r as u32;
}

// Canonical codes (RFC 1951 3.2.2), stored bit-reversed for LSB-first output.
fn assign_codes(lengths: const u8[:], codes: u32[:]) {
    var bl_count: i64[16] = [0; 16];
    var next_code: i64[16] = [0; 16];
    for s in lengths.len {
        bl_count[lengths[s] as i64] += 1;
    }
    bl_count[0] = 0;
    var code: i64 = 0;
    var bits: i64 = 1;
    while bits <= 15 {
        code = (code + bl_count[bits - 1]) << 1;
        next_code[bits] = code;
        bits += 1;
    }
    for s in lengths.len {
        let len = lengths[s] as i64;
        if len != 0 {
            codes[s] = reverse_bits(next_code[len], len);
            next_code[len] += 1;
        } else {
            codes[s] = 0;
        }
    }
}

// Huffman code lengths limited to maxbits, using count-based Kraft repair.
// Returns false only if the repair cannot complete (never for valid inputs).
fn build_lengths(freq: const u32[:], maxbits: i64, lengths: u8[:]) -> bool {
    var order: i64[288] = [0; 288];
    var weight: u64[576] = [0; 576];
    var parent: i64[576] = [0; 576];
    var depth: i64[576] = [0; 576];
    var count: i64[320] = [0; 320];
    var m: i64 = 0;
    for s in freq.len {
        lengths[s] = 0;
        if freq[s] > 0 {
            order[m] = s;
            m += 1;
        }
    }
    // A code needs at least two symbols to be complete; add unused ones with weight 1.
    if m == 0 {
        order[0] = 0;
        order[1] = 1;
        m = 2;
    } else if m == 1 {
        order[1] = if order[0] == 0 { 1 } else { 0 };
        m = 2;
    }
    for i in m {
        let f = freq[order[i]] as u64;
        weight[i] = if f > 0 { f } else { 1 };
    }
    // Insertion sort by weight: m is at most 288, so this is cheap next to the symbol loop.
    var i: i64 = 1;
    while i < m {
        var j = i;
        while j > 0 && weight[j - 1] > weight[j] {
            let tw = weight[j];
            weight[j] = weight[j - 1];
            weight[j - 1] = tw;
            let to = order[j];
            order[j] = order[j - 1];
            order[j - 1] = to;
            j -= 1;
        }
        i += 1;
    }
    // Two-queue Huffman: leaves 0..m-1, internal nodes m..2m-2.
    var li: i64 = 0;
    var ii: i64 = m;
    var next: i64 = m;
    var step: i64 = 0;
    while step < m - 1 {
        var a: i64 = 0;
        var b: i64 = 0;
        var k: i64 = 0;
        while k < 2 {
            var pick: i64 = 0;
            if li < m && (ii >= next || weight[li] <= weight[ii]) {
                pick = li;
                li += 1;
            } else {
                pick = ii;
                ii += 1;
            }
            if k == 0 { a = pick; } else { b = pick; }
            k += 1;
        }
        weight[next] = weight[a] + weight[b];
        parent[a] = next;
        parent[b] = next;
        next += 1;
        step += 1;
    }
    let root = next - 1;
    depth[root] = 0;
    var node = root - 1;
    while node >= 0 {
        depth[node] = depth[parent[node]] + 1;
        node -= 1;
    }
    for leaf in m {
        count[depth[leaf]] += 1;
    }
    var d = maxbits + 1;
    while d < 320 {
        count[maxbits] += count[d];
        count[d] = 0;
        d += 1;
    }
    let full: i64 = 1 << maxbits;
    var total: i64 = 0;
    var len: i64 = 1;
    while len <= maxbits {
        total += count[len] << (maxbits - len);
        len += 1;
    }
    while total > full {
        if count[maxbits] == 0 { return false; }
        count[maxbits] -= 1;
        var up = maxbits - 1;
        while up > 0 && count[up] == 0 { up -= 1; }
        if up == 0 { return false; }
        count[up] -= 1;
        count[up + 1] += 2;
        total -= 1;
    }
    if total != full { return false; }
    // Most frequent symbols (end of `order`) take the shortest lengths.
    var idx: i64 = m - 1;
    var l: i64 = 1;
    while l <= maxbits {
        var c = count[l];
        while c > 0 {
            lengths[order[idx]] = l as u8;
            idx -= 1;
            c -= 1;
        }
        l += 1;
    }
    return true;
}

fn init_codes(len_code: u8[:], dist_code: u8[:]) {
    for c in 28 {
        let base = LEN_BASE[c] as i64;
        let span: i64 = 1 << (LEN_EXTRA[c] as i64);
        for k in span {
            let l = base + k;
            if l <= MAX_MATCH { len_code[l] = c as u8; }
        }
    }
    len_code[258] = 28;
    for c in 30 {
        let base = DIST_BASE[c] as i64;
        let span: i64 = 1 << (DIST_EXTRA[c] as i64);
        for k in span {
            dist_code[base + k - 1] = c as u8;
        }
    }
}

fn hash_at(data: const u8[:], p: i64) -> i64 {
    let v = ((data[p] as u32) << 24) | ((data[p + 1] as u32) << 16) | ((data[p + 2] as u32) << 8) | (data[p + 3] as u32);
    return ((v * 2654435761) >> 17) as i64;
}

fn insert(data: const u8[:], p: i64, head: i32[:], prev: i32[:]) {
    if p + 3 < data.len {
        let h = hash_at(data, p);
        prev[p & WMASK] = head[h];
        head[h] = p as i32;
    }
}

// Bytes 4 at a time from a slice: one bounds check per load, not per byte.
inline fn load32(s: const u8[:], i: i64) -> u32 {
    let c = s[i..i + 4];
    return c[0] as u32 | (c[1] as u32) << 8 | (c[2] as u32) << 16 | (c[3] as u32) << 24;
}

// Index of the lowest set bit of a u64, by a de Bruijn multiply and a 64-entry table.
let CTZ64 = ctz64_tab();

fn ctz64_tab() -> i64[64] {
    var t: i64[64] = [0; 64];
    for i in 64 {
        let bit: u64 = 1 << (i as u64);
        t[((bit * 0x03F79D71B4CB0A89) >> 58) as i64] = i;
    }
    return t;
}

// Length of the common prefix of data[a..] and data[b..], at most `most` bytes. A match
// is extended 8 bytes at a time; the first differing byte is found in the XOR.
inline fn match_len(data: const u8[:], a: i64, b: i64, most: i64) -> i64 {
    var n: i64 = 0;
    while n + 8 <= most {
        let x = (load32(data, a + n) as u64) | ((load32(data, a + n + 4) as u64) << 32);
        let y = (load32(data, b + n) as u64) | ((load32(data, b + n + 4) as u64) << 32);
        let d = x ^ y;
        if d != 0 {
            let low = d & (0 - d);
            return n + (CTZ64[((low * 0x03F79D71B4CB0A89) >> 58) as i64] >> 3);
        }
        n += 8;
    }
    while n < most && data[a + n] == data[b + n] { n += 1; }
    return n;
}

// Longest match at p among earlier positions still in the window; the chain is
// only a hint, so every candidate is verified byte by byte.
// Inserts p into its chain, then returns the longest match at p. The chain is searched as
// it was before p was added, so p never matches itself. The hash is computed once.
fn search_insert(data: const u8[:], p: i64, head: i32[:], prev: i32[:], floor: i64, depth: i64) -> Match {
    var best = Match { floor, 0 };
    if p + 4 > data.len { return Match { 0, 0 }; }
    let limit = min(MAX_MATCH, data.len - p);
    let h = hash_at(data, p);
    var cand = head[h] as i64;
    prev[p & WMASK] = head[h];
    head[h] = p as i32;
    // A floor at the end of the input leaves no longer match to find (after the insert).
    if floor >= limit { return Match { 0, 0 }; }
    var chain = depth;
    while cand >= 0 && chain > 0 && p - cand <= WINDOW {
        chain -= 1;
        // Candidates that cannot beat the best are turned away by one fused test of 4-byte words.
        let worth = if best.len >= 4 {
            load32(data, cand + best.len - 3) == load32(data, p + best.len - 3) && load32(data, cand) == load32(data, p)
        } else {
            load32(data, cand) == load32(data, p)
        };
        if worth {
            let l = match_len(data, cand, p, limit);
            if l > best.len {
                best.len = l;
                best.dist = p - cand;
                if l >= limit || l >= NICE_MATCH { break; }
            }
        }
        cand = prev[cand & WMASK] as i64;
    }
    if best.dist == 0 || best.len < MIN_MATCH { return Match { 0, 0 }; }
    return best;
}

// log2 of a distance, rounded down, from a table (for `better`).
let LOG2 = log2_tab();

fn log2_tab() -> i64[256] {
    var t: i64[256] = [0; 256];
    for i in 2..256 { t[i] = t[i >> 1] + 1; }
    return t;
}

fn log2_dist(d: i64) -> i64 {
    return if d >= 256 { 8 + LOG2[(d >> 8) & 255] } else { LOG2[d & 255] };
}

// Whether a match of len at dist is worth the literal it costs against cur at cur_dist:
// 4 for each byte longer, 1 for each power of two nearer, past the threshold.
fn better(len: i64, dist: i64, cur: i64, cur_dist: i64, threshold: i64) -> bool {
    return len >= cur && 4 * (len - cur) + log2_dist(cur_dist) - log2_dist(dist) > threshold;
}

fn fixed_lengths(lit: u8[:], dst: u8[:]) {
    for s in 288 {
        lit[s] = if s < 144 { 8 } else if s < 256 { 9 } else if s < 280 { 7 } else { 8 };
    }
    for s in 32 { dst[s] = 5; }
}

fn put_symbols(syms: const u32[:], lit_codes: const u32[:], lit_len: const u8[:], dst_codes: const u32[:], dst_len: const u8[:], len_code: const u8[:], dist_code: const u8[:], out: u8[>..]&, bw: Bw&) {
    for s in syms.len {
        let v = syms[s] as i64;
        if v < 256 {
            put(out, bw, lit_codes[v], lit_len[v] as i64);
        } else {
            let len = v >> 16;
            let dist = v & 65535;
            let lc = len_code[len] as i64;
            put(out, bw, lit_codes[257 + lc], lit_len[257 + lc] as i64);
            let le = LEN_EXTRA[lc] as i64;
            put(out, bw, (len - LEN_BASE[lc] as i64) as u32, le);
            let dc = dist_code[dist - 1] as i64;
            put(out, bw, dst_codes[dc], dst_len[dc] as i64);
            let de = DIST_EXTRA[dc] as i64;
            put(out, bw, (dist - DIST_BASE[dc] as i64) as u32, de);
        }
    }
    put(out, bw, lit_codes[256], lit_len[256] as i64);
}

// Run-length encodes the code lengths (RFC 1951 3.2.7). Token = symbol | extra << 8.
fn length_tokens(lit_len: const u8[:], hlit: i64, dst_len: const u8[:], hdist: i64, tok: u32[>..]&) {
    var seq: u8[320] = [0; 320];
    for i in hlit { seq[i] = lit_len[i]; }
    for i in hdist { seq[hlit + i] = dst_len[i]; }
    let total = hlit + hdist;
    var i: i64 = 0;
    while i < total {
        let v = seq[i];
        var run: i64 = 1;
        while i + run < total && seq[i + run] == v { run += 1; }
        if v == 0 && run >= 11 {
            let r = min(run, 138);
            tok.push((18 + ((r - 11) << 8)) as u32);
            i += r;
        } else if v == 0 && run >= 3 {
            let r = min(run, 10);
            tok.push((17 + ((r - 3) << 8)) as u32);
            i += r;
        } else {
            tok.push(v as u32);
            i += 1;
            if v != 0 && run - 1 >= 3 {
                let r = min(run - 1, 6);
                tok.push((16 + ((r - 3) << 8)) as u32);
                i += r;
            }
        }
    }
}

fn emit_stored(data: const u8[:], first: i64, last: i64, is_final: bool, out: u8[>..]&, bw: Bw&) {
    var at = first;
    while true {
        let n = min(MAX_STORED, last - at);
        let is_last = at + n == last;
        put(out, bw, if is_final && is_last { 1 } else { 0 }, 1);
        put(out, bw, 0, 2);
        flush_partial(out, bw);
        out.push((n & 255) as u8);
        out.push(((n >> 8) & 255) as u8);
        out.push(((MAX_STORED - n) & 255) as u8);
        out.push(((MAX_STORED - n) >> 8) as u8);
        out.append(data[at..at + n]);
        at += n;
        if at == last { break; }
    }
}

// Picks the smallest of stored, fixed and dynamic encodings for one block.
fn emit_block(data: const u8[:], first: i64, last: i64, syms: const u32[:], is_final: bool, len_code: const u8[:], dist_code: const u8[:], out: u8[>..]&, bw: Bw&) -> bool {
    var lit_freq: u32[288] = [0; 288];
    var dst_freq: u32[32] = [0; 32];
    var extra: i64 = 0;
    for s in syms.len {
        let v = syms[s] as i64;
        if v < 256 {
            lit_freq[v] += 1;
        } else {
            let lc = len_code[v >> 16] as i64;
            let dc = dist_code[(v & 65535) - 1] as i64;
            lit_freq[257 + lc] += 1;
            dst_freq[dc] += 1;
            extra += (LEN_EXTRA[lc] as i64) + (DIST_EXTRA[dc] as i64);
        }
    }
    lit_freq[256] += 1;

    var lit_len: u8[288] = [0; 288];
    var dst_len: u8[32] = [0; 32];
    if !build_lengths(lit_freq[0..288], 15, lit_len[0..288]) { return false; }
    if !build_lengths(dst_freq[0..32], 15, dst_len[0..32]) { return false; }

    var hlit: i64 = 286;
    while hlit > 257 && lit_len[hlit - 1] == 0 { hlit -= 1; }
    var hdist: i64 = 30;
    while hdist > 1 && dst_len[hdist - 1] == 0 { hdist -= 1; }

    var tok: u32[>..] = [];
    length_tokens(lit_len[0..288], hlit, dst_len[0..32], hdist, tok);
    var cl_freq: u32[19] = [0; 19];
    for t in tok.len { cl_freq[tok[t] & 255] += 1; }
    var cl_len: u8[19] = [0; 19];
    if !build_lengths(cl_freq[0..19], 7, cl_len[0..19]) { return false; }
    var hclen: i64 = 19;
    while hclen > 4 && cl_len[CLEN_ORDER[hclen - 1]] == 0 { hclen -= 1; }

    var body_dyn: i64 = extra;
    for s in 288 { body_dyn += (lit_freq[s] as i64) * (lit_len[s] as i64); }
    for d in 32 { body_dyn += (dst_freq[d] as i64) * (dst_len[d] as i64); }
    var header_bits: i64 = 14 + 3 * hclen;
    for t in tok.len {
        let sym = (tok[t] & 255) as i64;
        header_bits += (cl_len[sym] as i64) + (CLEN_EXTRA[sym] as i64);
    }
    var body_fix: i64 = extra;
    var fix_lit: u8[288] = [0; 288];
    var fix_dst: u8[32] = [0; 32];
    fixed_lengths(fix_lit[0..288], fix_dst[0..32]);
    for s in 288 { body_fix += (lit_freq[s] as i64) * (fix_lit[s] as i64); }
    for d in 32 { body_fix += (dst_freq[d] as i64) * 5; }

    let raw = last - first;
    let chunks = max(1, (raw + MAX_STORED - 1) / MAX_STORED);
    let stored_bits = raw * 8 + chunks * 42;
    let dyn_bits = 3 + header_bits + body_dyn;
    let fix_bits = 3 + body_fix;

    if stored_bits <= dyn_bits && stored_bits <= fix_bits {
        emit_stored(data, first, last, is_final, out, bw);
        return true;
    }
    let final_bit: u32 = if is_final { 1 } else { 0 };
    var lit_codes: u32[288] = [0; 288];
    var dst_codes: u32[32] = [0; 32];
    if fix_bits <= dyn_bits {
        put(out, bw, final_bit, 1);
        put(out, bw, 1, 2);
        assign_codes(fix_lit[0..288], lit_codes[0..288]);
        assign_codes(fix_dst[0..32], dst_codes[0..32]);
        put_symbols(syms, lit_codes[0..288], fix_lit[0..288], dst_codes[0..32], fix_dst[0..32], len_code, dist_code, out, bw);
        return true;
    }
    put(out, bw, final_bit, 1);
    put(out, bw, 2, 2);
    put(out, bw, (hlit - 257) as u32, 5);
    put(out, bw, (hdist - 1) as u32, 5);
    put(out, bw, (hclen - 4) as u32, 4);
    for i in hclen { put(out, bw, cl_len[CLEN_ORDER[i]] as u32, 3); }
    var cl_codes: u32[19] = [0; 19];
    assign_codes(cl_len[0..19], cl_codes[0..19]);
    for t in tok.len {
        let sym = (tok[t] & 255) as i64;
        let e = tok[t] >> 8;
        put(out, bw, cl_codes[sym], cl_len[sym] as i64);
        let eb = CLEN_EXTRA[sym] as i64;
        if eb > 0 { put(out, bw, e, eb); }
    }
    assign_codes(lit_len[0..288], lit_codes[0..288]);
    assign_codes(dst_len[0..32], dst_codes[0..32]);
    put_symbols(syms, lit_codes[0..288], lit_len[0..288], dst_codes[0..32], dst_len[0..32], len_code, dist_code, out, bw);
    return true;
}

// Appends a raw DEFLATE stream for `data` to `out`.
fn compress(data: const u8[:], out: u8[>..]&) -> bool {
    var len_code: u8[259] = [0; 259];
    var dist_code: u8[32768] = [0; 32768];
    init_codes(len_code[0..259], dist_code[0..32768]);
    var head: i32[32768] = [-1; 32768];
    var prev: i32[32768] = [-1; 32768];
    var syms: u32[>..] = [];
    var bw = Bw { 0, 0 };
    var block_start: i64 = 0;
    var pos: i64 = 0;
    // Result of the lazy search for `pos`, reused when the literal at pos-1 was chosen.
    var ahead = Match { 0, 0 };
    var have_ahead = false;
    // Every position below ins is in the chains.
    var ins: i64 = 0;
    while pos < data.len {
        if pos - block_start >= BLOCK_BYTES {
            if !emit_block(data, block_start, pos, syms[0..syms.len], false, len_code[0..259], dist_code[0..32768], out, bw) { return false; }
            syms = [];
            block_start = pos;
        }
        var m = ahead;
        if !have_ahead {
            m = search_insert(data, pos, head[0..32768], prev[0..32768], 0, MAX_CHAIN);
            ins = pos + 1;
        }
        have_ahead = false;
        if m.len >= MIN_MATCH && m.len < LAZY_LIMIT && pos + 1 < data.len {
            let next = search_insert(data, pos + 1, head[0..32768], prev[0..32768], m.len, MAX_CHAIN / 2);
            ins = pos + 2;
            if better(next.len, next.dist, m.len, m.dist, 2) {
                syms.push(data[pos] as u32);
                pos += 1;
                ahead = next;
                have_ahead = true;
                continue;
            }
        }
        if m.len >= MIN_MATCH {
            syms.push(((m.len as u32) << 16) | (m.dist as u32));
            while ins < pos + m.len {
                insert(data, ins, head[0..32768], prev[0..32768]);
                ins += 1;
            }
            pos += m.len;
        } else {
            syms.push(data[pos] as u32);
            pos += 1;
        }
    }
    if !emit_block(data, block_start, data.len, syms[0..syms.len], true, len_code[0..259], dist_code[0..32768], out, bw) { return false; }
    flush_partial(out, bw);
    return true;
}

fn refill(data: const u8[:], br: Br&) {
    while br.count <= 56 {
        if br.pos < data.len {
            br.acc = br.acc | ((data[br.pos] as u64) << (br.count as u64));
            br.pos += 1;
        } else {
            br.filler += 1;
        }
        br.count += 8;
    }
}

// Bits consumed so far, counting zero bytes loaded past the end as virtual input.
fn bitpos(br: Br) -> i64 {
    return (br.pos + br.filler) * 8 - br.count;
}

fn get_bits(data: const u8[:], br: Br&, n: i64) -> i64 {
    if br.count < n { refill(data, br); }
    let v = br.acc & ((1 << (n as u64)) - 1);
    br.acc = br.acc >> (n as u64);
    br.count -= n;
    return v as i64;
}

// Canonical decoding tables (RFC 1951 3.2.2): the primary table maps each code of at most
// 10 bits, and `count` and `symbol` (sorted by length, then value) decode the longer ones.
// Returns false if the lengths over-subscribe the code.
fn build_huff(lengths: const u8[:], h: Huff&) -> bool {
    for i in 16 { h.count[i] = 0; }
    for s in lengths.len { h.count[lengths[s] as i64] += 1; }
    h.count[0] = 0;
    var left: i64 = 1;
    var len: i64 = 1;
    while len <= 15 {
        left = (left << 1) - h.count[len];
        if left < 0 { return false; }
        len += 1;
    }
    var offs: i64[16] = [0; 16];
    var next: i64 = 0;
    len = 1;
    while len <= 15 {
        offs[len] = next;
        next += h.count[len];
        len += 1;
    }
    for s in lengths.len {
        let l = lengths[s] as i64;
        if l != 0 {
            h.symbol[offs[l]] = s as u16;
            offs[l] += 1;
        }
    }
    var codes: u32[288] = [0; 288];
    assign_codes(lengths, codes[0..lengths.len]);
    for i in 1024 { h.table[i] = 0; }
    for s in lengths.len {
        let l = lengths[s] as i64;
        if l != 0 && l <= 10 {
            let step: i64 = 1 << l;
            var j = codes[s] as i64;
            while j < 1024 {
                h.table[j] = ((s as u32) << 4) | (l as u32);
                j += step;
            }
        }
    }
    return true;
}

// Decodes a code longer than the primary table, one bit at a time (RFC 1951 puff-style).
fn decode_slow(data: const u8[:], br: Br&, h: const Huff&) -> i64 {
    var code: i64 = 0;
    var first: i64 = 0;
    var index: i64 = 0;
    var len: i64 = 1;
    while len <= 15 {
        if br.count < 1 { refill(data, br); }
        code = code | ((br.acc & 1) as i64);
        br.acc = br.acc >> 1;
        br.count -= 1;
        let count = h.count[len];
        if code - count < first { return h.symbol[index + (code - first)] as i64; }
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
        len += 1;
    }
    return -1;
}

fn decode_sym(data: const u8[:], br: Br&, h: const Huff&) -> i64 {
    if br.count < 15 { refill(data, br); }
    let e = h.table[(br.acc & 1023) as i64];
    let len = (e & 15) as i64;
    if len == 0 { return decode_slow(data, br, h); }
    br.acc = br.acc >> (len as u64);
    br.count -= len;
    return (e >> 4) as i64;
}

// Hot loop: bit state lives in locals, and the input is checked for overrun only when
// refilling. 48 bits cover one whole length/distance pair (15 + 5 + 15 + 13). A long
// code goes through decode_slow, so the locals are handed to `br` and read back around it.
fn decode_block(data: const u8[:], br: Br&, lit: const Huff&, dst: const Huff&, out: u8[>..]&) -> bool {
    var pos = br.pos;
    var acc = br.acc;
    var count = br.count;
    var filler = br.filler;
    var ok = false;
    while true {
        if count < 48 {
            while count <= 56 {
                if pos < data.len {
                    acc = acc | ((data[pos] as u64) << (count as u64));
                    pos += 1;
                } else {
                    filler += 1;
                }
                count += 8;
            }
            if (pos + filler) * 8 - count > data.len * 8 { break; }
        }
        var sym: i64 = -1;
        let e = lit.table[(acc & 1023) as i64];
        if (e & 15) != 0 {
            sym = (e >> 4) as i64;
            acc = acc >> ((e & 15) as u64);
            count -= (e & 15) as i64;
        } else {
            br.pos = pos; br.acc = acc; br.count = count; br.filler = filler;
            sym = decode_slow(data, br, lit);
            pos = br.pos; acc = br.acc; count = br.count; filler = br.filler;
        }
        if sym < 0 { break; }
        if sym < 256 {
            out.push(sym as u8);
        } else if sym == 256 {
            ok = true;
            break;
        } else {
            let lc = sym - 257;
            if lc >= 29 { break; }
            let le = LEN_EXTRA[lc] as i64;
            let len = LEN_BASE[lc] as i64 + ((acc & ((1 << (le as u64)) - 1)) as i64);
            acc = acc >> (le as u64);
            count -= le;
            var dsym: i64 = -1;
            let de = dst.table[(acc & 1023) as i64];
            if (de & 15) != 0 {
                dsym = (de >> 4) as i64;
                acc = acc >> ((de & 15) as u64);
                count -= (de & 15) as i64;
            } else {
                br.pos = pos; br.acc = acc; br.count = count; br.filler = filler;
                dsym = decode_slow(data, br, dst);
                pos = br.pos; acc = br.acc; count = br.count; filler = br.filler;
            }
            if dsym < 0 || dsym >= 30 { break; }
            let dx = DIST_EXTRA[dsym] as i64;
            let dist = DIST_BASE[dsym] as i64 + ((acc & ((1 << (dx as u64)) - 1)) as i64);
            acc = acc >> (dx as u64);
            count -= dx;
            if dist > out.len { break; }
            let start = out.len - dist;
            for k in len { out.push(out[start + k]); }
        }
    }
    br.pos = pos;
    br.acc = acc;
    br.count = count;
    br.filler = filler;
    return ok;
}

fn read_dynamic(data: const u8[:], br: Br&, lit: Huff&, dst: Huff&, clen: Huff&) -> bool {
    let hlit = get_bits(data, br, 5) + 257;
    let hdist = get_bits(data, br, 5) + 1;
    let hclen = get_bits(data, br, 4) + 4;
    if hlit > 286 || hdist > 30 { return false; }
    var cl: u8[19] = [0; 19];
    for i in hclen { cl[CLEN_ORDER[i] as i64] = get_bits(data, br, 3) as u8; }
    if !build_huff(cl[0..19], clen) { return false; }
    var lens: u8[320] = [0; 320];
    let total = hlit + hdist;
    var i: i64 = 0;
    while i < total {
        let sym = decode_sym(data, br, clen);
        if sym < 0 { return false; }
        if sym < 16 {
            lens[i] = sym as u8;
            i += 1;
        } else {
            var rep: i64 = 0;
            var value: u8 = 0;
            if sym == 16 {
                if i == 0 { return false; }
                rep = 3 + get_bits(data, br, 2);
                value = lens[i - 1];
            } else if sym == 17 {
                rep = 3 + get_bits(data, br, 3);
            } else {
                rep = 11 + get_bits(data, br, 7);
            }
            if i + rep > total { return false; }
            for k in rep {
                lens[i] = value;
                i += 1;
            }
        }
    }
    if lens[256] == 0 { return false; }
    return build_huff(lens[0..hlit], lit) && build_huff(lens[hlit..total], dst);
}

// Decodes a raw DEFLATE stream and appends the result to `out`.
fn decompress(data: const u8[:], out: u8[>..]&) -> bool {
    var br = Br { 0, 0, 0, 0 };
    var lit = Huff { [0; 1024], [0; 16], [0; 288] };
    var dst = Huff { [0; 1024], [0; 16], [0; 288] };
    var clen = Huff { [0; 1024], [0; 16], [0; 288] };
    var last = false;
    while !last {
        last = get_bits(data, br, 1) == 1;
        let kind = get_bits(data, br, 2);
        if bitpos(br) > data.len * 8 { return false; }
        if kind == 0 {
            // Stored blocks start on a byte boundary; bytes still in the bit buffer are re-read from input.
            let at = (bitpos(br) + 7) / 8;
            if at + 4 > data.len { return false; }
            let n = (data[at] as i64) | ((data[at + 1] as i64) << 8);
            let nn = (data[at + 2] as i64) | ((data[at + 3] as i64) << 8);
            if (n ^ nn) != MAX_STORED { return false; }
            if at + 4 + n > data.len { return false; }
            out.append(data[at + 4..at + 4 + n]);
            br.pos = at + 4 + n;
            br.acc = 0;
            br.count = 0;
            br.filler = 0;
        } else if kind == 1 {
            var fix_lit: u8[288] = [0; 288];
            var fix_dst: u8[32] = [0; 32];
            fixed_lengths(fix_lit[0..288], fix_dst[0..32]);
            if !build_huff(fix_lit[0..288], lit) || !build_huff(fix_dst[0..32], dst) { return false; }
            if !decode_block(data, br, lit, dst, out) { return false; }
        } else if kind == 2 {
            if !read_dynamic(data, br, lit, dst, clen) { return false; }
            if !decode_block(data, br, lit, dst, out) { return false; }
        } else {
            return false;
        }
    }
    return bitpos(br) <= data.len * 8;
}
