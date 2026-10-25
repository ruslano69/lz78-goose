// Zstandard decoder (RFC 8878) in Goose. Tables are from RFC 8878 and libzstd (BSD-3-Clause).
// Scope: frames with skippable frames, raw/RLE/compressed blocks, Huffman literals (direct
// and FSE-coded weights, four streams, treeless), FSE sequence tables (predefined, RLE,
// compressed, repeat), repeat offsets and the content checksum. Dictionaries are rejected.
namespace zstd;
import std;

let LL_BASE: i64[36] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536];
let LL_BITS: i64[36] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
let ML_BASE: i64[53] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539];
let LL_CODE_SMALL: u8[64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 20, 20, 21, 21, 21, 21, 22, 22, 22, 22, 22, 22, 22, 22, 23, 23, 23, 23, 23, 23, 23, 23, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24];
let ML_CODE_SMALL: u8[128] = [0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 32, 33, 33, 34, 34, 35, 35, 36, 36, 36, 36, 37, 37, 37, 37, 38, 38, 38, 38, 38, 38, 38, 38, 39, 39, 39, 39, 39, 39, 39, 39, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42];
let ML_BITS: i64[53] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
let LL_DEFAULT: i64[36] = [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1];
let ML_DEFAULT: i64[53] = [1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1];
let OF_DEFAULT: i64[29] = [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1];

// Forward bit reader (LSB first), for FSE headers.
struct Fwd { pos: i64 }
// Backward bit reader, for FSE-coded and Huffman bitstreams: bits are taken from the end,
// after the highest set bit of the last byte (the sentinel).
struct Bwd { pos: i64 }
struct Fse { acc: i64, sym: u8[512], nb: u8[512], base: u16[512] }
struct Huf { acc: i64, sym: u8[2048], nb: u8[2048] }
struct FseHdr { acc: i64, bytes: i64, nsym: i64 }
struct Ctx { huf: Huf, has_huf: bool, ll: Fse, of: Fse, ml: Fse, has_ll: bool, has_of: bool, has_ml: bool, rep0: i64, rep1: i64, rep2: i64 }

fn fse_new() -> Fse {
    return Fse { 0, [0; 512], [0; 512], [0; 512] };
}

fn huf_new() -> Huf {
    return Huf { 0, [0; 2048], [0; 2048] };
}

fn new_ctx() -> Ctx {
    return Ctx { huf_new(), false, fse_new(), fse_new(), fse_new(), false, false, false, 1, 4, 8 };
}

fn le16(d: const u8[:], i: i64) -> i64 {
    return (d[i] as i64) | ((d[i + 1] as i64) << 8);
}

fn le32(d: const u8[:], i: i64) -> i64 {
    return le16(d, i) | (le16(d, i + 2) << 16);
}

fn highbit(x: i64) -> i64 {
    // Position of the top set bit; 0 for 0 and 1.
    return 63 - clz((x | 1) as u64);
}

// Reads k bits LSB first.
fn fwd_read(src: const u8[:], r: Fwd&, k: i64) -> i64 {
    var v: i64 = 0;
    for i in k {
        let idx = r.pos + i;
        if idx < src.len * 8 {
            v = v | ((((src[idx >> 3] as i64) >> (idx & 7)) & 1) << i);
        }
    }
    r.pos += k;
    return v;
}

fn fwd_peek(src: const u8[:], r: Fwd, k: i64) -> i64 {
    var t = Fwd { r.pos };
    return fwd_read(src, t, k);
}

fn bwd_init(src: const u8[:]) -> Bwd {
    let last = src[src.len - 1] as i64;
    return Bwd { (src.len - 1) * 8 + highbit(last) };
}

// Reads k bits taken from just below r.pos; the value's first bit is its MSB. Bits below
// the start of the stream read as 0, and r.pos < 0 afterwards means the stream ran out.
// The bits are gathered from whole bytes, not one at a time.
fn bwd_read(src: const u8[:], r: Bwd&, k: i64) -> i64 {
    if k == 0 { return 0; }
    let lo = r.pos - k;
    var v: i64 = 0;
    if lo >= 0 && (lo >> 3) + 8 <= src.len {
        // Eight bytes from the byte holding the lowest bit; k <= 32 and the shift is below 8.
        v = ((read64(src, lo >> 3) >> ((lo & 7) as u64)) as! i64) & ((1 << k) - 1);
    } else if lo >= 0 {
        let shift = lo & 7;
        var acc: i64 = 0;
        var j = lo >> 3;
        var got: i64 = 0;
        while got < shift + k {
            acc = acc | ((src[j] as i64) << got);
            j += 1;
            got += 8;
        }
        v = (acc >> shift) & ((1 << k) - 1);
    } else {
        for i in k {
            let idx = lo + i;
            if idx >= 0 {
                v = v | ((((src[idx >> 3] as i64) >> (idx & 7)) & 1) << i);
            }
        }
    }
    r.pos = lo;
    return v;
}

fn bwd_peek(src: const u8[:], r: Bwd, k: i64) -> i64 {
    var t = Bwd { r.pos };
    return bwd_read(src, t, k);
}

// Builds the decoding table from normalized counts (RFC 8878 4.1.1 / FSE spreading).
fn fse_build(norm: i64[:], nsym: i64, acc: i64, t: Fse&) -> bool {
    let size: i64 = 1 << acc;
    t.acc = acc;
    var next: i64[256] = [0; 256];
    var high: i64 = size - 1;
    for s in nsym {
        if norm[s] == -1 {
            t.sym[high] = s as u8;
            high -= 1;
            next[s] = 1;
        } else {
            next[s] = norm[s];
        }
    }
    let step: i64 = (size >> 1) + (size >> 3) + 3;
    let mask = size - 1;
    var pos: i64 = 0;
    for s in nsym {
        if norm[s] > 0 {
            for i in norm[s] {
                t.sym[pos] = s as u8;
                pos = (pos + step) & mask;
                while pos > high {
                    pos = (pos + step) & mask;
                }
            }
        }
    }
    for u in size {
        let s = t.sym[u] as i64;
        let n = next[s];
        next[s] += 1;
        let nb = acc - highbit(n);
        t.nb[u] = nb as u8;
        t.base[u] = ((n << nb) - size) as u16;
    }
    return true;
}

// A table that always yields `sym` and reads no bits.
fn fse_rle(sym: i64, t: Fse&) {
    t.acc = 0;
    t.sym[0] = sym as u8;
    t.nb[0] = 0;
    t.base[0] = 0;
}

// Reads a normalized-count header (RFC 8878 4.1.1). Fills norm; nsym is the symbol count.
fn fse_read_header(src: const u8[:], maxsym: i64, maxacc: i64, norm: i64[:]) -> FseHdr {
    var r = Fwd { 0 };
    let acc = fwd_read(src, r, 4) + 5;
    if acc > maxacc { return FseHdr { -1, 0, 0 }; }
    for i in norm.len { norm[i] = 0; }
    var remaining: i64 = (1 << acc) + 1;
    var threshold: i64 = 1 << acc;
    var nb: i64 = acc + 1;
    var sym: i64 = 0;
    var prev0 = false;
    while remaining > 1 {
        if prev0 {
            // Zero-probability symbols come in runs: each 2-bit 3 adds three, the final value adds itself.
            var zeros: i64 = 0;
            var more = true;
            while more {
                let v = fwd_read(src, r, 2);
                if v == 3 {
                    zeros += 3;
                } else {
                    zeros += v;
                    more = false;
                }
            }
            sym += zeros;
            prev0 = false;
            if sym > maxsym { break; }
        }
        let max = (2 * threshold - 1) - remaining;
        let raw = fwd_peek(src, r, nb);
        var count: i64 = 0;
        if (raw & (threshold - 1)) < max {
            count = raw & (threshold - 1);
            r.pos += nb - 1;
        } else {
            count = raw & (2 * threshold - 1);
            if count >= threshold { count -= max; }
            r.pos += nb;
        }
        count -= 1;
        if count >= 0 {
            remaining -= count;
        } else {
            remaining += count;
        }
        if sym > maxsym { return FseHdr { -1, 0, 0 }; }
        norm[sym] = count;
        sym += 1;
        prev0 = count == 0;
        if remaining < threshold {
            if remaining <= 1 { break; }
            nb = highbit(remaining) + 1;
            threshold = 1 << (nb - 1);
        }
    }
    if remaining != 1 { return FseHdr { -1, 0, 0 }; }
    return FseHdr { acc, (r.pos + 7) / 8, sym };
}

// Huffman decoding table from code lengths (RFC 8878 4.2.1), indexed by the next tl input
// bits, MSB first. libzstd orders codes the other way round from DEFLATE: the longest codes
// (lowest weight) take the lowest indices, and within a length the symbols keep their order.
fn huf_from_lengths(lens: i64[:], nsym: i64, tl: i64, h: Huf&) -> bool {
    if tl > 11 { return false; }
    h.acc = tl;
    var idx: i64 = 0;
    for w in tl {
        let len = tl - w;
        for s in nsym {
            if lens[s] == len {
                let span: i64 = 1 << w;
                if idx + span > (1 << tl) { return false; }
                for j in span {
                    h.sym[idx + j] = s as u8;
                    h.nb[idx + j] = len as u8;
                }
                idx += span;
            }
        }
    }
    return idx == (1 << tl);
}

// Huffman weights (w[0..nw), the last symbol's weight implied) to code lengths.
fn huf_from_weights(w: i64[:], nw: i64, h: Huf&) -> bool {
    var total: i64 = 0;
    for s in nw {
        if w[s] > 0 { total += 1 << (w[s] - 1); }
    }
    if total == 0 { return false; }
    let tl = highbit(total) + 1;
    let rest = (1 << tl) - total;
    if (rest & (rest - 1)) != 0 { return false; }
    let last = highbit(rest) + 1;
    var lens: i64[256] = [0; 256];
    for s in nw {
        lens[s] = if w[s] > 0 { tl + 1 - w[s] } else { 0 };
    }
    lens[nw] = tl + 1 - last;
    return huf_from_lengths(lens, nw + 1, tl, h);
}

// Parses the Huffman tree description at src[0..]; returns its byte length or -1.
fn huf_header(src: const u8[:], h: Huf&) -> i64 {
    if src.len < 1 { return -1; }
    let h0 = src[0] as i64;
    var w: i64[257] = [0; 257];
    var nw: i64 = 0;
    var bytes: i64 = 0;
    if h0 >= 128 {
        nw = h0 - 127;
        bytes = 1 + (nw + 1) / 2;
        if bytes > src.len { return -1; }
        for i in nw {
            let b = src[1 + i / 2] as i64;
            w[i] = if (i & 1) == 0 { b >> 4 } else { b & 15 };
        }
    } else {
        let csz = h0;
        if 1 + csz > src.len { return -1; }
        var norm: i64[256] = [0; 256];
        let fh = fse_read_header(src[1..1 + csz], 255, 6, norm);
        if fh.acc < 0 || fh.bytes >= csz { return -1; }
        var t = fse_new();
        if !fse_build(norm, fh.nsym, fh.acc, t) { return -1; }
        let stream = src[1 + fh.bytes..1 + csz];
        var r = bwd_init(stream);
        var st1 = bwd_read(stream, r, t.acc);
        var st2 = bwd_read(stream, r, t.acc);
        var done = false;
        while !done {
            if nw >= 254 { return -1; }
            w[nw] = t.sym[st1] as i64;
            nw += 1;
            st1 = (t.base[st1] as i64) + bwd_read(stream, r, t.nb[st1] as i64);
            if r.pos < 0 {
                w[nw] = t.sym[st2] as i64;
                nw += 1;
                done = true;
            } else {
                w[nw] = t.sym[st2] as i64;
                nw += 1;
                st2 = (t.base[st2] as i64) + bwd_read(stream, r, t.nb[st2] as i64);
                if r.pos < 0 {
                    w[nw] = t.sym[st1] as i64;
                    nw += 1;
                    done = true;
                }
            }
        }
        bytes = 1 + csz;
    }
    if !huf_from_weights(w, nw, h) { return -1; }
    return bytes;
}

// Decodes `count` symbols from a Huffman stream, read backwards.
fn huf_stream(src: const u8[:], h: Huf, count: i64, out: u8[>..]&) -> bool {
    if src.len < 1 || src[src.len - 1] == 0 { return false; }
    var r = bwd_init(src);
    for i in count {
        let idx = bwd_peek(src, r, h.acc);
        let nb = h.nb[idx] as i64;
        if nb == 0 { return false; }
        r.pos -= nb;
        out.push(h.sym[idx]);
    }
    return r.pos >= 0;
}

// Literals section (RFC 8878 3.1.1.3.1). Appends the literal bytes to lits; returns the
// section's byte length or -1.
fn lit_section(blk: const u8[:], lits: u8[>..]&, ctx: Ctx&) -> i64 {
    if blk.len < 1 { return -1; }
    let b0 = blk[0] as i64;
    let ltype = b0 & 3;
    let fmt = (b0 >> 2) & 3;
    if ltype <= 1 {
        var hdr: i64 = 1;
        var size: i64 = 0;
        if fmt == 0 || fmt == 2 {
            size = b0 >> 3;
        } else if fmt == 1 {
            hdr = 2;
            if blk.len < 2 { return -1; }
            size = (b0 >> 4) | ((blk[1] as i64) << 4);
        } else {
            hdr = 3;
            if blk.len < 3 { return -1; }
            size = (b0 >> 4) | ((blk[1] as i64) << 4) | ((blk[2] as i64) << 12);
        }
        if ltype == 0 {
            if hdr + size > blk.len { return -1; }
            lits.append(blk[hdr..hdr + size]);
            return hdr + size;
        }
        if hdr + 1 > blk.len { return -1; }
        for i in size { lits.push(blk[hdr]); }
        return hdr + 1;
    }
    var hdr: i64 = 3;
    var regen: i64 = 0;
    var csize: i64 = 0;
    var streams: i64 = 1;
    if blk.len < 3 { return -1; }
    let v3 = (b0 | ((blk[1] as i64) << 8) | ((blk[2] as i64) << 16));
    if fmt == 0 {
        regen = (v3 >> 4) & 1023;
        csize = (v3 >> 14) & 1023;
    } else if fmt == 1 {
        streams = 4;
        regen = (v3 >> 4) & 1023;
        csize = (v3 >> 14) & 1023;
    } else if fmt == 2 {
        hdr = 4;
        streams = 4;
        if blk.len < 4 { return -1; }
        let v4 = v3 | ((blk[3] as i64) << 24);
        regen = (v4 >> 4) & 16383;
        csize = (v4 >> 18) & 16383;
    } else {
        hdr = 5;
        streams = 4;
        if blk.len < 5 { return -1; }
        let v5 = v3 | ((blk[3] as i64) << 24) | ((blk[4] as i64) << 32);
        regen = (v5 >> 4) & 262143;
        csize = (v5 >> 22) & 262143;
    }
    if hdr + csize > blk.len { return -1; }
    var p = hdr;
    if ltype == 2 {
        let hb = huf_header(blk[hdr..hdr + csize], ctx.huf);
        if hb < 0 { return -1; }
        ctx.has_huf = true;
        p = hdr + hb;
    } else if !ctx.has_huf {
        return -1;
    }
    let body = blk[p..hdr + csize];
    if streams == 1 {
        if !huf_stream(body, ctx.huf, regen, lits) { return -1; }
    } else {
        if body.len < 6 { return -1; }
        let s1 = le16(body, 0);
        let s2 = le16(body, 2);
        let s3 = le16(body, 4);
        let data = body[6..body.len];
        if s1 + s2 + s3 > data.len { return -1; }
        let seg = (regen + 3) / 4;
        if !huf_stream(data[0..s1], ctx.huf, seg, lits) { return -1; }
        if !huf_stream(data[s1..s1 + s2], ctx.huf, seg, lits) { return -1; }
        if !huf_stream(data[s1 + s2..s1 + s2 + s3], ctx.huf, seg, lits) { return -1; }
        if !huf_stream(data[s1 + s2 + s3..data.len], ctx.huf, regen - 3 * seg, lits) { return -1; }
    }
    return hdr + csize;
}

// The table for one sequence kind: predefined, RLE, compressed or repeat (RFC 8878 3.1.1.3.2.1).
// Returns the bytes it used from src, or -1.
fn seq_table(src: const u8[:], mode: i64, which: i64, t: Fse&, has: bool, defaults: i64[:], dacc: i64, maxsym: i64, maxacc: i64) -> i64 {
    if mode == 0 {
        var norm: i64[64] = [0; 64];
        for i in defaults.len { norm[i] = defaults[i]; }
        return if fse_build(norm, defaults.len, dacc, t) { 0 } else { -1 };
    }
    if mode == 1 {
        if src.len < 1 { return -1; }
        if (src[0] as i64) > maxsym { return -1; }
        fse_rle(src[0] as i64, t);
        return 1;
    }
    if mode == 2 {
        var norm: i64[64] = [0; 64];
        let fh = fse_read_header(src, maxsym, maxacc, norm);
        if fh.acc < 0 { return -1; }
        if !fse_build(norm, fh.nsym, fh.acc, t) { return -1; }
        return fh.bytes;
    }
    return if has { 0 } else { -1 };
}

// Sequences section and execution (RFC 8878 3.1.1.3.2 and 3.1.1.4).
fn sequences(blk: const u8[:], lits: const u8[:], out: u8[>..]&, frame_start: i64, ctx: Ctx&, cap_end: i64) -> bool {
    if blk.len < 1 { return false; }
    var p: i64 = 0;
    var nbseq: i64 = 0;
    let b0 = blk[0] as i64;
    if b0 == 0 {
        p = 1;
    } else if b0 < 128 {
        nbseq = b0;
        p = 1;
    } else if b0 < 255 {
        if blk.len < 2 { return false; }
        nbseq = ((b0 - 128) << 8) + (blk[1] as i64);
        p = 2;
    } else {
        if blk.len < 3 { return false; }
        nbseq = (blk[1] as i64) + ((blk[2] as i64) << 8) + 0x7F00;
        p = 3;
    }
    if nbseq == 0 {
        if p != blk.len { return false; }
        if out.len + lits.len > cap_end { return false; }
        out.append(lits[0..lits.len]);
        return true;
    }
    if p >= blk.len { return false; }
    let modes = blk[p] as i64;
    p += 1;
    let m_ll = modes >> 6;
    let m_of = (modes >> 4) & 3;
    let m_ml = (modes >> 2) & 3;
    let u = seq_table(blk[p..blk.len], m_ll, 0, ctx.ll, ctx.has_ll, LL_DEFAULT, 6, 35, 9);
    if u < 0 { return false; }
    ctx.has_ll = true;
    p += u;
    if p > blk.len { return false; }
    let uo = seq_table(blk[p..blk.len], m_of, 1, ctx.of, ctx.has_of, OF_DEFAULT, 5, 31, 8);
    if uo < 0 { return false; }
    ctx.has_of = true;
    p += uo;
    if p > blk.len { return false; }
    let um = seq_table(blk[p..blk.len], m_ml, 2, ctx.ml, ctx.has_ml, ML_DEFAULT, 6, 52, 9);
    if um < 0 { return false; }
    ctx.has_ml = true;
    p += um;
    if p > blk.len { return false; }

    let stream = blk[p..blk.len];
    if stream.len < 1 || stream[stream.len - 1] == 0 { return false; }
    var r = bwd_init(stream);
    // Initial states are read LL, OF, ML (libzstd order).
    var st_ll = bwd_read(stream, r, ctx.ll.acc);
    var st_of = bwd_read(stream, r, ctx.of.acc);
    var st_ml = bwd_read(stream, r, ctx.ml.acc);
    var lp: i64 = 0;
    for i in nbseq {
        let ofc = ctx.of.sym[st_of] as i64;
        let mlc = ctx.ml.sym[st_ml] as i64;
        let llc = ctx.ll.sym[st_ll] as i64;
        if ofc > 31 || mlc > 52 || llc > 35 { return false; }
        // The six reads of a sequence come from two windows of eight bytes: the offset and
        // match extra bits (at most 47), then the literal extra bits and the three state
        // updates (at most 43). The first value read is the highest field of its window.
        let mlb = ML_BITS[mlc];
        let llb = LL_BITS[llc];
        var of_x: i64 = 0;
        var ml_x: i64 = 0;
        let loa = r.pos - (ofc + mlb);
        if loa >= 0 && (loa >> 3) + 8 <= stream.len {
            let w = (read64(stream, loa >> 3) >> ((loa & 7) as u64)) as! i64;
            of_x = (w >> mlb) & ((1 << ofc) - 1);
            ml_x = w & ((1 << mlb) - 1);
            r.pos = loa;
        } else {
            of_x = bwd_read(stream, r, ofc);
            ml_x = bwd_read(stream, r, mlb);
        }
        let more = i + 1 < nbseq;
        var nbl: i64 = 0;
        var nbm: i64 = 0;
        var nbo: i64 = 0;
        if more {
            nbl = ctx.ll.nb[st_ll] as i64;
            nbm = ctx.ml.nb[st_ml] as i64;
            nbo = ctx.of.nb[st_of] as i64;
        }
        var ll_x: i64 = 0;
        var s_ll: i64 = 0;
        var s_ml: i64 = 0;
        var s_of: i64 = 0;
        let lob = r.pos - (llb + nbl + nbm + nbo);
        if lob >= 0 && (lob >> 3) + 8 <= stream.len {
            let w = (read64(stream, lob >> 3) >> ((lob & 7) as u64)) as! i64;
            ll_x = (w >> (nbl + nbm + nbo)) & ((1 << llb) - 1);
            s_ll = (w >> (nbm + nbo)) & ((1 << nbl) - 1);
            s_ml = (w >> nbo) & ((1 << nbm) - 1);
            s_of = w & ((1 << nbo) - 1);
            r.pos = lob;
        } else {
            ll_x = bwd_read(stream, r, llb);
            s_ll = bwd_read(stream, r, nbl);
            s_ml = bwd_read(stream, r, nbm);
            s_of = bwd_read(stream, r, nbo);
        }
        let off_val = (1 << ofc) + of_x;
        let ml = ML_BASE[mlc] + ml_x;
        let ll = LL_BASE[llc] + ll_x;
        if more {
            st_ll = (ctx.ll.base[st_ll] as i64) + s_ll;
            st_ml = (ctx.ml.base[st_ml] as i64) + s_ml;
            st_of = (ctx.of.base[st_of] as i64) + s_of;
        }
        if r.pos < 0 { return false; }
        // Literals first, then the match from the window (RFC 8878 3.1.1.3.2.2).
        if lp + ll > lits.len { return false; }
        // A block never decodes to more than 128 KiB, and never past the caller's limit.
        if out.len + ll > cap_end { return false; }
        if ll > 0 { out.append(lits[lp..lp + ll]); }
        lp += ll;
        let ll0: i64 = if ll == 0 { 1 } else { 0 };
        var offset: i64 = 0;
        if off_val > 3 {
            offset = off_val - 3;
            ctx.rep2 = ctx.rep1;
            ctx.rep1 = ctx.rep0;
            ctx.rep0 = offset;
        } else {
            let rc = off_val - 1 + ll0;
            if rc == 0 {
                offset = ctx.rep0;
            } else {
                let cur = if rc == 3 { ctx.rep0 - 1 } else if rc == 2 { ctx.rep2 } else { ctx.rep1 };
                if rc >= 2 { ctx.rep2 = ctx.rep1; }
                ctx.rep1 = ctx.rep0;
                ctx.rep0 = cur;
                offset = cur;
            }
        }
        let produced = out.len - frame_start;
        if offset <= 0 || offset > produced { return false; }
        if out.len + ml > cap_end { return false; }
        // Source before the end of the output: one copy when it does not overlap what is
        // written, else the repeating pattern is extended by doubling chunks.
        let base = out.len - offset;
        if offset >= ml {
            out.append(out[base..base + ml]);
        } else {
            var rem = ml;
            while rem > 0 {
                let c = min(rem, out.len - base);
                out.append(out[base..base + c]);
                rem -= c;
            }
        }
    }
    if lp < lits.len {
        if out.len + (lits.len - lp) > cap_end { return false; }
        out.append(lits[lp..lits.len]);
    }
    return true;
}

fn decode_block(blk: const u8[:], out: u8[>..]&, frame_start: i64, ctx: Ctx&, cap_end: i64) -> bool {
    var lits: u8[>..] = [];
    let used = lit_section(blk, lits, ctx);
    if used < 0 { return false; }
    return sequences(blk[used..blk.len], lits[0..lits.len], out, frame_start, ctx, cap_end);
}

// XXH64 with seed 0 (RFC: xxHash specification). Used for the frame content checksum.
let P1: u64 = 11400714785074694791;
let P2: u64 = 14029467366897019727;
let P3: u64 = 1609587929392839161;
let P4: u64 = 9650029242287828579;
let P5: u64 = 2870177450012600261;

fn rotl64(x: u64, r: i64) -> u64 {
    return (x << (r as u64)) | (x >> ((64 - r) as u64));
}

inline fn read64(d: const u8[:], i: i64) -> u64 {
    // One bounds check for the whole word, then constant indices into the slice.
    let c = d[i..i + 8];
    return (c[0] as u64) | ((c[1] as u64) << 8) | ((c[2] as u64) << 16) | ((c[3] as u64) << 24) |
        ((c[4] as u64) << 32) | ((c[5] as u64) << 40) | ((c[6] as u64) << 48) | ((c[7] as u64) << 56);
}

fn xxh_round(acc: u64, input: u64) -> u64 {
    return rotl64(acc + input * P2, 31) * P1;
}

fn xxh_merge(acc: u64, v: u64) -> u64 {
    return (acc ^ xxh_round(0, v)) * P1 + P4;
}

fn xxh64(d: const u8[:]) -> u64 {
    var i: i64 = 0;
    var h: u64 = 0;
    if d.len >= 32 {
        var v1: u64 = P1 + P2;
        var v2: u64 = P2;
        var v3: u64 = 0;
        var v4: u64 = 0 - P1;
        while i + 32 <= d.len {
            v1 = xxh_round(v1, read64(d, i));
            v2 = xxh_round(v2, read64(d, i + 8));
            v3 = xxh_round(v3, read64(d, i + 16));
            v4 = xxh_round(v4, read64(d, i + 24));
            i += 32;
        }
        h = rotl64(v1, 1) + rotl64(v2, 7) + rotl64(v3, 12) + rotl64(v4, 18);
        h = xxh_merge(h, v1);
        h = xxh_merge(h, v2);
        h = xxh_merge(h, v3);
        h = xxh_merge(h, v4);
    } else {
        h = P5;
    }
    h = h + (d.len as u64);
    while i + 8 <= d.len {
        h = h ^ xxh_round(0, read64(d, i));
        h = rotl64(h, 27) * P1 + P4;
        i += 8;
    }
    if i + 4 <= d.len {
        let w = (d[i] as u64) | ((d[i + 1] as u64) << 8) | ((d[i + 2] as u64) << 16) | ((d[i + 3] as u64) << 24);
        h = h ^ (w * P1);
        h = rotl64(h, 23) * P2 + P3;
        i += 4;
    }
    while i < d.len {
        h = h ^ ((d[i] as u64) * P5);
        h = rotl64(h, 11) * P1;
        i += 1;
    }
    h = h ^ (h >> 33);
    h = h * P2;
    h = h ^ (h >> 29);
    h = h * P3;
    h = h ^ (h >> 32);
    return h;
}

// Decodes a sequence of zstd frames and skippable frames; appends the content to out.
fn decompress(data: const u8[:], out: u8[>..]&) -> bool {
    return decompress_max(data, out, 4611686018427387904);
}
// Decodes every frame of data and appends the bytes to out. The output may grow by at most
// `limit` bytes; more is refused, so a small input cannot demand an unbounded buffer.
fn decompress_max(data: const u8[:], out: u8[>..]&, limit: i64) -> bool {
    if limit < 0 { return false; }
    let limit_end = if limit > 4611686018427387904 - out.len { 4611686018427387904 } else { out.len + limit };
    var pos: i64 = 0;
    while pos < data.len {
        if pos + 8 > data.len { return false; }
        let magic = le32(data, pos);
        if (magic & 0xFFFFFFF0) == 0x184D2A50 {
            pos += 8 + le32(data, pos + 4);
            continue;
        }
        if magic != 4247762216 { return false; }
        pos += 4;
        let fhd = data[pos] as i64;
        pos += 1;
        if (fhd & 8) != 0 { return false; }
        let fcs_flag = fhd >> 6;
        let single = (fhd >> 5) & 1;
        let has_checksum = ((fhd >> 2) & 1) == 1;
        let did = fhd & 3;
        if single == 0 {
            pos += 1;
        }
        let did_bytes: i64 = if did == 0 { 0 } else if did == 1 { 1 } else if did == 2 { 2 } else { 4 };
        if did_bytes > 0 {
            if pos + did_bytes > data.len { return false; }
            var dict_id: i64 = 0;
            for k in did_bytes { dict_id = dict_id | ((data[pos + k] as i64) << (8 * k)); }
            if dict_id != 0 { return false; }
            pos += did_bytes;
        }
        let fcs_bytes: i64 = if fcs_flag == 0 { if single == 1 { 1 } else { 0 } } else if fcs_flag == 1 { 2 } else if fcs_flag == 2 { 4 } else { 8 };
        if pos + fcs_bytes > data.len { return false; }
        // Frame_Content_Size, when present, is the exact size of the decoded frame.
        var fcs: i64 = -1;
        if fcs_bytes > 0 {
            var v: i64 = 0;
            for k in fcs_bytes { v = v | ((data[pos + k] as i64) << (8 * k)); }
            if fcs_flag == 1 { v += 256; }
            if v < 0 || v > limit_end - out.len { return false; }
            fcs = v;
        }
        pos += fcs_bytes;

        let frame_start = out.len;
        var ctx = new_ctx();
        var last = false;
        while !last {
            if pos + 3 > data.len { return false; }
            let h = le16(data, pos) | ((data[pos + 2] as i64) << 16);
            pos += 3;
            last = (h & 1) == 1;
            let btype = (h >> 1) & 3;
            let bsize = h >> 3;
            // Block_Maximum_Size: no block is larger than 128 KiB.
            if bsize > 131072 { return false; }
            if btype == 0 {
                if pos + bsize > data.len { return false; }
                if out.len + bsize > limit_end { return false; }
                out.append(data[pos..pos + bsize]);
                pos += bsize;
            } else if btype == 1 {
                if pos + 1 > data.len { return false; }
                if out.len + bsize > limit_end { return false; }
                out.resize(out.len + bsize, data[pos]);
                pos += 1;
            } else if btype == 2 {
                if pos + bsize > data.len { return false; }
                let cap_end = min(out.len + 131072, limit_end);
                if !decode_block(data[pos..pos + bsize], out, frame_start, ctx, cap_end) { return false; }
                pos += bsize;
            } else {
                return false;
            }
        }
        if fcs >= 0 && out.len - frame_start != fcs { return false; }
        if has_checksum {
            if pos + 4 > data.len { return false; }
            let want = le32(data, pos);
            pos += 4;
            let have = xxh64(out[frame_start..out.len]) & 4294967295;
            if (want as u64) != have { return false; }
        }
    }
    return true;
}


// ---------------------------------------------------------------------------------------
// Encoder. Writes standard zstd frames: single-segment header with the 8-byte content size,
// 128 KB blocks, raw literals, sequences coded with the predefined FSE tables (mode 0),
// full offsets only, and the content checksum. A block that does not shrink is stored raw.

let BLOCK_MAX: i64 = 131072;
let MIN_MATCH_ZSTD: i64 = 3;
let HASH_BITS_ZSTD: i64 = 16;
let NICE_LEN_ZSTD: i64 = 128;

struct FseCt { tl: i64, tbl: u16[512], dnb: i64[64], dfind: i64[64] }
struct BitW { acc: u64, count: i64 }
struct Seq { ll: i64, ml: i64, ov: i64 }

fn fse_ct_new() -> FseCt {
    return FseCt { 0, [0; 512], [0; 64], [0; 64] };
}

// Encoding table from normalized counts (the decoder's spreading, plus the state table).
fn fse_ct_build(norm: i64[:], nsym: i64, tl: i64, ct: FseCt&) {
    let size: i64 = 1 << tl;
    ct.tl = tl;
    var cumul: i64[64] = [0; 64];
    var tsym: i64[512] = [0; 512];
    var high: i64 = size - 1;
    var total: i64 = 0;
    for s in nsym {
        cumul[s] = total;
        if norm[s] == -1 {
            tsym[high] = s;
            high -= 1;
            total += 1;
        } else {
            total += norm[s];
        }
    }
    let step: i64 = (size >> 1) + (size >> 3) + 3;
    let mask = size - 1;
    var pos: i64 = 0;
    for s in nsym {
        for i in (if norm[s] > 0 { norm[s] } else { 0 }) {
            tsym[pos] = s;
            pos = (pos + step) & mask;
            while pos > high {
                pos = (pos + step) & mask;
            }
        }
    }
    for u in size {
        let s = tsym[u];
        ct.tbl[cumul[s]] = (size + u) as u16;
        cumul[s] += 1;
    }
    total = 0;
    for s in nsym {
        let c = norm[s];
        if c == 0 {
            ct.dnb[s] = 0;
            ct.dfind[s] = 0;
        } else if c == -1 || c == 1 {
            ct.dnb[s] = (tl << 16) - size;
            ct.dfind[s] = total - 1;
            total += 1;
        } else {
            let max_bits = tl - highbit(c - 1);
            let min_state_plus = c << max_bits;
            ct.dnb[s] = (max_bits << 16) - min_state_plus;
            ct.dfind[s] = total - c;
            total += c;
        }
    }
}

fn bitw_add(out: u8[>..]&, bw: BitW&, value: i64, n: i64) {
    if n == 0 { return; }
    let v = (value & ((1 << n) - 1)) as u64;
    bw.acc = bw.acc | (v << (bw.count as u64));
    bw.count += n;
    // Four bytes at a time: this branch is taken once per 32 bits instead of once per byte.
    if bw.count >= 32 {
        out.push((bw.acc & 255) as u8);
        out.push(((bw.acc >> 8) & 255) as u8);
        out.push(((bw.acc >> 16) & 255) as u8);
        out.push(((bw.acc >> 24) & 255) as u8);
        bw.acc = bw.acc >> 32;
        bw.count -= 32;
    }
}

// Ends a backward stream: a sentinel 1 bit, then zero padding to a byte boundary.
fn bitw_close(out: u8[>..]&, bw: BitW&) {
    bitw_add(out, bw, 1, 1);
    bitw_pad(out, bw);
}

// Encodes sym from state (the state value lies in [size, 2*size)); returns the next state.
fn fse_put(out: u8[>..]&, bw: BitW&, ct: FseCt&, state: i64, sym: i64) -> i64 {
    let nb = (state + ct.dnb[sym]) >> 16;
    bitw_add(out, bw, state, nb);
    return ct.tbl[((state >> nb) + ct.dfind[sym]) as i64] as i64;
}

// The initial state for sym (libzstd's FSE_initCState2); writes no bits.
fn fse_init(ct: FseCt&, sym: i64) -> i64 {
    let nb = (ct.dnb[sym] + (1 << 15)) >> 16;
    let v = (nb << 16) - ct.dnb[sym];
    return ct.tbl[((v >> nb) + ct.dfind[sym]) as i64] as i64;
}

fn ll_code(v: i64) -> i64 {
    if v < 64 { return LL_CODE_SMALL[v] as i64; }
    return highbit(v) + 19;
}

fn ml_code(v: i64) -> i64 {
    if v < 128 { return ML_CODE_SMALL[v] as i64; }
    return highbit(v - 3) + 36;
}

// Sequences of one block as a backward bitstream, in the order the decoder reads them.
fn encode_sequences(seqs: Seq[:], ll_codes: i64[:], ml_codes: i64[:], of_codes: i64[:], ll_ct: FseCt&, of_ct: FseCt&, ml_ct: FseCt&, out: u8[>..]&) {
    // Reuse the codes already computed for choosing the FSE tables.
    let n = seqs.len;
    assert(ll_codes.len == n && ml_codes.len == n && of_codes.len == n);
    var bw = BitW { 0, 0 };
    let last = seqs[n - 1];
    let llc = ll_codes[n - 1];
    let mlc = ml_codes[n - 1];
    let ofv = last.ov;
    let ofc = of_codes[n - 1];
    var st_ll = fse_init(ll_ct, llc);
    var st_of = fse_init(of_ct, ofc);
    var st_ml = fse_init(ml_ct, mlc);
    bitw_add(out, bw, last.ll - LL_BASE[llc], LL_BITS[llc]);
    bitw_add(out, bw, last.ml - ML_BASE[mlc], ML_BITS[mlc]);
    bitw_add(out, bw, ofv - (1 << ofc), ofc);
    var i = n - 2;
    while i >= 0 {
        let s = seqs[i];
        let llc2 = ll_codes[i];
        let mlc2 = ml_codes[i];
        let ofv2 = s.ov;
        let ofc2 = of_codes[i];
        st_of = fse_put(out, bw, of_ct, st_of, ofc2);
        st_ml = fse_put(out, bw, ml_ct, st_ml, mlc2);
        st_ll = fse_put(out, bw, ll_ct, st_ll, llc2);
        bitw_add(out, bw, s.ll - LL_BASE[llc2], LL_BITS[llc2]);
        bitw_add(out, bw, s.ml - ML_BASE[mlc2], ML_BITS[mlc2]);
        bitw_add(out, bw, ofv2 - (1 << ofc2), ofc2);
        i -= 1;
    }
    bitw_add(out, bw, st_ml - of_size(ml_ct), ml_ct.tl);
    bitw_add(out, bw, st_of - of_size(of_ct), of_ct.tl);
    bitw_add(out, bw, st_ll - of_size(ll_ct), ll_ct.tl);
    bitw_close(out, bw);
}

fn of_size(ct: FseCt&) -> i64 {
    return 1 << ct.tl;
}

// Writes a little-endian value of width bytes.
fn put_le(out: u8[>..]&, v: i64, width: i64) {
    for i in width {
        out.push(((v >> (8 * i)) & 255) as u8);
    }
}

// Literals: the raw section header and the bytes.
fn put_literals(out: u8[>..]&, lits: u8[>..]) {
    let n = lits.len;
    if n < 32 {
        out.push((n << 3) as u8);
    } else if n < 4096 {
        out.push((4 | ((n & 15) << 4)) as u8);
        out.push((n >> 4) as u8);
    } else {
        out.push((12 | ((n & 15) << 4)) as u8);
        out.push(((n >> 4) & 255) as u8);
        out.push((n >> 12) as u8);
    }
    out.append(lits[0..lits.len]);
}

fn hash4_zstd(data: const u8[:], p: i64) -> i64 {
    let v: u32 = (data[p] as u32) | ((data[p + 1] as u32) << 8) | ((data[p + 2] as u32) << 16) | ((data[p + 3] as u32) << 24);
    return ((v * 2654435761) >> (32 - HASH_BITS_ZSTD)) as i64;
}
fn hash8_zstd(data: const u8[:], p: i64) -> i64 {
    return ((read64(data, p) * 11400714819323198485) >> 47) as i64;
}

// Length-limited Huffman code lengths (Kraft-exact repair, as zlib-style builders).
fn huf_lengths(freq: i64[:], maxbits: i64, lengths: i64[:]) -> bool {
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
            lengths[order[idx]] = l;
            idx -= 1;
            c -= 1;
        }
        l += 1;
    }
    return true;
}

// Huffman literal coding. Codes follow huf_from_lengths: the longest codes take the lowest
// table indices, so a symbol's code is its index shifted down by (tl - length). The tree is
// described with direct weights (one 4-bit weight per symbol below the largest used one; the
// largest is implicit), which covers literal alphabets up to 128 symbols.
fn huf_codes(lens: i64[:], nsym: i64, tl: i64, codes: i64[:]) {
    var idx: i64 = 0;
    for w in tl {
        let len = tl - w;
        for s in nsym {
            if lens[s] == len {
                codes[s] = idx >> w;
                idx += 1 << w;
            }
        }
    }
}

// Writes the literal bytes as a backward Huffman stream (the decoder reads it from the end).
fn huf_put_stream(lits: const u8[:], lens: i64[:], codes: i64[:], out: u8[>..]&) {
    var bw = BitW { 0, 0 };
    var i = lits.len - 1;
    while i >= 0 {
        let s = lits[i] as i64;
        bitw_add(out, bw, codes[s], lens[s]);
        i -= 1;
    }
    bitw_close(out, bw);
}

// Appends a compressed literals section to out and returns true; false if the literals are
// not suitable (fewer than two distinct bytes, or a largest byte above 128).
fn put_compressed_literals(lits: const u8[:], out: u8[>..]&) -> bool {
    let n = lits.len as i64;
    var freq: i64[256] = [0; 256];
    for i in n { freq[lits[i] as i64] += 1; }
    var maxsym: i64 = 0;
    var distinct: i64 = 0;
    for s in 256 {
        if freq[s] > 0 {
            distinct += 1;
            maxsym = s;
        }
    }
    if distinct < 2 || maxsym == 0 { return false; }
    var lens: i64[256] = [0; 256];
    if !huf_lengths(freq, 11, lens) { return false; }
    // Even without tree/stream headers these codes cannot beat raw bytes.
    // Avoid encoding and copying a Huffman candidate that will be discarded.
    var bits: i64 = 0;
    for s in 256 { bits += freq[s] * lens[s]; }
    if bits >= n * 8 { return false; }
    var tl: i64 = 0;
    for s in maxsym + 1 {
        if lens[s] > tl { tl = lens[s]; }
    }
    var codes: i64[256] = [0; 256];
    huf_codes(lens, maxsym + 1, tl, codes);
    // Tree description: FSE-coded weights when the alphabet is large, else direct 4-bit weights.
    var tree: u8[>..] = [];
    var weights: i64[256] = [0; 256];
    for i in maxsym { weights[i] = if lens[i] > 0 { tl + 1 - lens[i] } else { 0 }; }
    if maxsym >= 4 && put_fse_weights(weights, maxsym, tree) >= 0 {
        // weights already written into tree
    } else if maxsym <= 128 {
        tree.push((127 + maxsym) as u8);
        var i: i64 = 0;
        while i < maxsym {
            let hi = weights[i];
            let lo = if i + 1 < maxsym { weights[i + 1] } else { 0 };
            tree.push(((hi << 4) | lo) as u8);
            i += 2;
        }
    } else {
        return false;
    }
    var stream_bytes: u8[>..] = [];
    var sizes: i64[4] = [0; 4];
    var four = n >= 256;
    if !four {
        huf_put_stream(lits, lens, codes, stream_bytes);
        sizes[0] = stream_bytes.len as i64;
    } else {
        let seg = (n + 3) / 4;
        var starts: i64[5] = [0, seg, 2 * seg, 3 * seg, n];
        for k in 4 {
            var part: u8[>..] = [];
            huf_put_stream(lits[starts[k]..starts[k + 1]], lens, codes, part);
            sizes[k] = part.len as i64;
            stream_bytes.append(part[0..part.len]);
        }
    }
    let jump = if four { 6 } else { 0 };
    let csize = tree.len as i64 + jump + stream_bytes.len as i64;
    var fmt: i64 = 0;
    if !four {
        fmt = 0;
    } else if n < 1024 && csize < 1024 {
        fmt = 1;
    } else if n < 16384 && csize < 16384 {
        fmt = 2;
    } else {
        fmt = 3;
    }
    if fmt == 2 {
        put_le(out, 2 | (2 << 2) | (n << 4) | (csize << 18), 4);
    } else if fmt == 3 {
        put_le(out, 2 | (3 << 2) | (n << 4) | (csize << 22), 5);
    } else {
        put_le(out, 2 | (fmt << 2) | (n << 4) | (csize << 14), 3);
    }
    out.append(tree[0..tree.len]);
    if four {
        put_le(out, sizes[0], 2);
        put_le(out, sizes[1], 2);
        put_le(out, sizes[2], 2);
    }
    out.append(stream_bytes[0..stream_bytes.len]);
    return true;
}

// Forward bitstream padding (no sentinel): pending bits go out in whole bytes.
fn bitw_pad(out: u8[>..]&, bw: BitW&) {
    while bw.count > 0 {
        out.push((bw.acc & 255) as u8);
        bw.acc = bw.acc >> 8;
        bw.count -= 8;
    }
    bw.acc = 0;
    bw.count = 0;
}

// Normalizes counts to sum 2^acc; every present symbol keeps at least one slot.
fn fse_normalize(counts: i64[:], nsym: i64, acc: i64, norm: i64[:]) -> bool {
    let size: i64 = 1 << acc;
    var total: i64 = 0;
    var present: i64 = 0;
    for s in nsym {
        total += counts[s];
        if counts[s] > 0 { present += 1; }
    }
    if present < 2 || present > size { return false; }
    var sum: i64 = 0;
    for s in nsym {
        if counts[s] > 0 {
            var v = counts[s] * size / total;
            if v < 1 { v = 1; }
            norm[s] = v;
        } else {
            norm[s] = 0;
        }
        sum += norm[s];
    }
    while sum > size {
        var best: i64 = -1;
        for s in nsym {
            if norm[s] > 1 && (best < 0 || counts[s] > counts[best]) { best = s; }
        }
        if best < 0 { return false; }
        norm[best] -= 1;
        sum -= 1;
    }
    while sum < size {
        var best: i64 = -1;
        for s in nsym {
            if counts[s] > 0 && (best < 0 || counts[s] > counts[best]) { best = s; }
        }
        norm[best] += 1;
        sum += 1;
    }
    return true;
}

// Writes an FSE normalized-count header (RFC 8878 4.1.1), the inverse of fse_read_header.
fn fse_put_header(norm: i64[:], nsym: i64, acc: i64, out: u8[>..]&) {
    var bw = BitW { 0, 0 };
    bitw_add(out, bw, acc - 5, 4);
    var remaining: i64 = (1 << acc) + 1;
    var threshold: i64 = 1 << acc;
    var nb: i64 = acc + 1;
    var s: i64 = 0;
    var prev0 = false;
    while remaining > 1 && s < nsym {
        if prev0 {
            // Zero-count symbols that follow: 2-bit codes, three per code 3, then the rest.
            var r: i64 = 0;
            while s + r < nsym && norm[s + r] == 0 { r += 1; }
            var k = r;
            while k >= 3 {
                bitw_add(out, bw, 3, 2);
                k -= 3;
            }
            bitw_add(out, bw, k, 2);
            s += r;
            prev0 = false;
            if s >= nsym { break; }
        }
        let c = norm[s];
        let max = (2 * threshold - 1) - remaining;
        var x = c + 1;
        let fits_short = x < max;
        if x >= threshold { x += max; }
        if x < max {
            bitw_add(out, bw, x, nb - 1);
        } else {
            bitw_add(out, bw, x, nb);
        }
        if c >= 0 { remaining -= c; } else { remaining += c; }
        prev0 = c == 0;
        s += 1;
        if remaining < threshold {
            if remaining <= 1 { break; }
            nb = highbit(remaining) + 1;
            threshold = 1 << (nb - 1);
        }
    }
    bitw_pad(out, bw);
}

// Huffman weights (w[0..nw), implicit last symbol excluded) as an FSE stream with two states
// (decoded by huf_header). Returns the bytes written, or -1 if the table cannot be built.
fn put_fse_weights(w: i64[:], nw: i64, out: u8[>..]&) -> i64 {
    var counts: i64[16] = [0; 16];
    for i in nw { counts[w[i]] += 1; }
    var maxw: i64 = 0;
    for v in 12 {
        if counts[v] > 0 { maxw = v; }
    }
    var norm: i64[16] = [0; 16];
    let acc: i64 = 6;
    if !fse_normalize(counts, maxw + 1, acc, norm) { return -1; }
    var ct = fse_ct_new();
    fse_ct_build(norm, maxw + 1, acc, ct);
    var body: u8[>..] = [];
    fse_put_header(norm, maxw + 1, acc, body);
    var bw = BitW { 0, 0 };
    var st_a = fse_init(ct, w[nw - 1]);
    var st_b = fse_init(ct, w[nw - 2]);
    var i = nw - 3;
    while i >= 0 {
        if ((i - (nw - 1)) & 1) == 0 {
            st_a = fse_put(body, bw, ct, st_a, w[i]);
        } else {
            st_b = fse_put(body, bw, ct, st_b, w[i]);
        }
        i -= 1;
    }
    // The decoder reads state 1 (even positions) first, so it is flushed last.
    let size: i64 = 1 << acc;
    let odd_state = if ((nw - 1) & 1) == 1 { st_a } else { st_b };
    let even_state = if ((nw - 1) & 1) == 1 { st_b } else { st_a };
    bitw_add(body, bw, odd_state - size, acc);
    bitw_add(body, bw, even_state - size, acc);
    bitw_close(body, bw);
    if body.len >= 128 { return -1; }
    out.push(body.len as u8);
    out.append(body[0..body.len]);
    return body.len as i64 + 1;
}

// Chooses the FSE table for one sequence kind: the predefined table (mode 0) or a table built
// from this block's code counts (mode 2, header written to hdr), whichever codes the codes in
// fewer bits including the header. ct receives the table the encoder uses.
fn choose_seq_table(codes: i64[:], n: i64, nsym: i64, dnorm: i64[:], dacc: i64, acc: i64, ct: FseCt&, hdr: u8[>..]&) -> i64 {
    var counts: i64[64] = [0; 64];
    for i in n { counts[codes[i]] += 1; }
    var cost_pre: i64 = 0;
    for s in nsym {
        let m = if dnorm[s] < 0 { -dnorm[s] } else { dnorm[s] };
        if counts[s] > 0 && m > 0 { cost_pre += counts[s] * (dacc - highbit(m)); }
    }
    var norm: i64[64] = [0; 64];
    var present: i64 = 0;
    var only: i64 = 0;
    for s in nsym {
        if counts[s] > 0 { present += 1; only = s; }
    }
    if present == 1 {
        // One symbol throughout. libzstd writes this as RLE: the symbol in one byte and no
        // bits per sequence. A table that lists a single symbol is accepted by libzstd but
        // refused by other decoders, so it is never written; with two sequences or fewer the
        // predefined table is cheaper than the byte.
        if n > 2 {
            norm[only] = 1;
            fse_ct_build(norm, nsym, 0, ct);
            hdr.push(only as u8);
            return 1;
        }
        fse_ct_build(dnorm, nsym, dacc, ct);
        return 0;
    }
    if !fse_normalize(counts, nsym, acc, norm) {
        fse_ct_build(dnorm, nsym, dacc, ct);
        return 0;
    }
    var header: u8[>..] = [];
    fse_put_header(norm, nsym, acc, header);
    var cost_new: i64 = 8 * header.len as i64;
    for s in nsym {
        if counts[s] > 0 { cost_new += counts[s] * (acc - highbit(norm[s])); }
    }
    if cost_new < cost_pre {
        fse_ct_build(norm, nsym, acc, ct);
        hdr.append(header[0..header.len]);
        return 2;
    }
    fse_ct_build(dnorm, nsym, dacc, ct);
    return 0;
}

// Repeat-offset state as the decoder keeps it (RFC 8878 3.1.2.5): applies the offset value
// `ov` (1..3 for repeat codes, offset + 3 otherwise) with literal length `ll`, returns the
// offset and updates r in place.
fn rep_update(ov: i64, ll: i64, r: i64[:]) -> i64 {
    // 1 when the literal run is empty, without a data-dependent branch.
    let ll0: i64 = 1 - min(ll, 1);
    if ov > 3 {
        let off = ov - 3;
        r[2] = r[1];
        r[1] = r[0];
        r[0] = off;
        return off;
    }
    let rc = ov - 1 + ll0;
    if rc == 0 { return r[0]; }
    let cur = if rc == 3 { r[0] - 1 } else { r[rc] };
    if rc >= 2 { r[2] = r[1]; }
    r[1] = r[0];
    r[0] = cur;
    return cur;
}

// Length of the common prefix of data[a..] and data[p..], at most limit bytes.
fn match_at(data: const u8[:], a: i64, p: i64, limit: i64) -> i64 {
    // Most hash candidates differ at the first byte: reject them before
    // constructing word-comparison views.
    if limit == 0 || data[a] != data[p] { return 0; }
    // Validate the ranges once, then compare eight little-endian bytes at a
    // time. XOR's first set bit identifies the first differing byte.
    let left = data[a..a + limit];
    let right = data[p..p + limit];
    var l: i64 = 0;
    while l + 8 <= limit {
        let diff = read64(left, l) ^ read64(right, l);
        if diff != 0 { return l + ctz(diff) / 8; }
        l += 8;
    }
    while l < limit && left[l] == right[l] { l += 1; }
    return l;
}

// Encodes data[start..end) as one block. r holds the repeat offsets at the block start and
// is updated only when the block is written compressed; a raw block leaves it unchanged.
fn compress_block(data: const u8[:], start: i64, end: i64, head: i32[:], longt: i32[:], base: i64, hshift: i64, lshift: i64, r: i64[:], out: u8[>..]&) {
    // A uniform block needs one byte, no match tables or entropy coding.
    // Reject ordinary input after inspecting only the first word.
    let raw_size = end - start;
    if raw_size > 0 {
        let byte = data[start];
        let word = (byte as u64) * 72340172838076673;
        var same = true;
        var at = start;
        while at + 8 <= end {
            if read64(data, at) != word { same = false; break; }
            at += 8;
        }
        if same {
            while at < end {
                if data[at] != byte { same = false; break; }
                at += 1;
            }
        }
        if same {
            // Block_Type = 1; Block_Size is the regenerated byte count.
            // RLE blocks preserve the repeat-offset history.
            put_le(out, 2 | (raw_size << 3), 3);
            out.push(byte);
            return;
        }
    }
    var seqs: Seq[>..] = [];
    var lits: u8[>..] = [];
    var lit_start = start;
    var p = start;
    var rr: i64[3] = [r[0], r[1], r[2]];
    while p < end {
        var best_len: i64 = 0;
        var best_pos: i64 = -1;
        var best_ov: i64 = 0;
        let ll = p - lit_start;
        let limit = min(131072, end - p);
        // Repeat-offset candidates that the coding can express at this literal length.
        var roff: i64[3] = [rr[1], rr[2], rr[0] - 1];
        if ll > 0 {
            roff[0] = rr[0];
            roff[1] = rr[1];
            roff[2] = rr[2];
        }
        // Only the offset of the last literal run is tried, as libzstd's double-fast does (rep1).
        for k in 1 {
            let o = roff[k];
            if o <= 0 || p - o < 0 { continue; }
            // A candidate can only win if it matches at best_len (for ties the repeat code wins).
            if best_len > 0 && (best_len >= limit || data[p - o + best_len] != data[p + best_len]) { continue; }
            let l = match_at(data, p - o, p, limit);
            if l >= MIN_MATCH_ZSTD && l >= best_len {
                best_len = l;
                best_pos = p - o;
                best_ov = k + 1;
            }
        }
        if p + 8 <= data.len {
            // Two tables, no chains: the long table hashes 8 bytes, the short one 4.
            // Both hashes use the same input word. Keep its low 32 bits
            // for the short hash instead of loading the first bytes again.
            let word = read64(data, p);
            let hl = (((word * 11400714819323198485) >> 47) as i64) >> lshift;
            let hs = ((((word as! u32) * 2654435761) >> (32 - HASH_BITS_ZSTD)) as i64) >> hshift;
            let cl = longt[hl] as i64 - base;
            let cs = head[hs] as i64 - base;
            longt[hl] = (p + base) as i32;
            head[hs] = (p + base) as i32;
            if cl >= 0 && cl < p {
                let l = match_at(data, cl, p, limit);
                if l >= MIN_MATCH_ZSTD && l > best_len {
                    best_len = l;
                    best_pos = cl;
                    best_ov = (p - cl) + 3;
                }
            }
            // The short table is consulted only when neither the long table nor a repeat matched.
            if best_len == 0 && cs >= 0 && cs < p && cs != cl {
                let l = match_at(data, cs, p, limit);
                if l >= MIN_MATCH_ZSTD && l > best_len {
                    best_len = l;
                    best_pos = cs;
                    best_ov = (p - cs) + 3;
                }
            }
        }
        if best_len >= MIN_MATCH_ZSTD {
            seqs.push(Seq { ll, best_len, best_ov });
            rep_update(best_ov, ll, rr);
            lits.append(data[lit_start..p]);
            // Fast search: only the last two positions of a match enter the hash chains.
            // The last two positions of the match, each if its 8 bytes are in the block.
            let e1 = p + best_len - 2;
            if e1 + 8 <= data.len {
                let word1 = read64(data, e1);
                let hl1 = (((word1 * 11400714819323198485) >> 47) as i64) >> lshift;
                let hs1 = ((((word1 as! u32) * 2654435761) >> (32 - HASH_BITS_ZSTD)) as i64) >> hshift;
                longt[hl1] = (e1 + base) as i32;
                head[hs1] = (e1 + base) as i32;
            }
            if e1 + 9 <= data.len {
                let word2 = read64(data, e1 + 1);
                let hl2 = (((word2 * 11400714819323198485) >> 47) as i64) >> lshift;
                let hs2 = ((((word2 as! u32) * 2654435761) >> (32 - HASH_BITS_ZSTD)) as i64) >> hshift;
                longt[hl2] = (e1 + 1 + base) as i32;
                head[hs2] = (e1 + 1 + base) as i32;
            }
            p += best_len;
            lit_start = p;
        } else {
            // Grow the skip by bytes since the last match, not by failed
            // probes. This is the double-fast byte-distance search strength.
            p += 1 + ((p - lit_start) >> 7);
        }
    }
    // With no sequence this encoder always writes a raw block. Do not build
    // literal buffers or run Huffman on data that will be discarded.
    if seqs.len == 0 {
        put_le(out, (end - start) << 3, 3);
        out.append(data[start..end]);
        return;
    }
    lits.append(data[lit_start..end]);
    // Block body: literals, sequence count, modes (all predefined), bitstream.
    var body: u8[>..] = [];
    // Size of the raw literal section (header plus bytes), without building it.
    let raw_len = (if lits.len < 32 { 1 } else if lits.len < 4096 { 2 } else { 3 }) + lits.len;
    var huf_lits: u8[>..] = [];
    if put_compressed_literals(lits[0..lits.len], huf_lits) && huf_lits.len < raw_len {
        body.append(huf_lits[0..huf_lits.len]);
    } else {
        put_literals(body, lits[0..lits.len]);
    }
    let n = seqs.len;
    if n == 0 {
        body.push(0);
    } else if n < 128 {
        body.push(n as u8);
    } else if n < 0x7F00 {
        body.push(((n >> 8) + 128) as u8);
        body.push((n & 255) as u8);
    } else {
        body.push(255);
        put_le(body, n - 0x7F00, 2);
    }
    if n > 0 {
        var llc: i64[>..] = [];
        var mlc: i64[>..] = [];
        var ofc: i64[>..] = [];
        for i in n {
            llc.push(ll_code(seqs[i].ll));
            mlc.push(ml_code(seqs[i].ml));
            ofc.push(highbit(seqs[i].ov));
        }
        var ll_ct = fse_ct_new();
        var of_ct = fse_ct_new();
        var ml_ct = fse_ct_new();
        var tables: u8[>..] = [];
        // Normalize new tables over 256 states for finer frequency precision;
        // predefined tables retain their format-defined logs.
        let m_ll = choose_seq_table(llc[0..n], n, 36, LL_DEFAULT, 6, 8, ll_ct, tables);
        let m_of = choose_seq_table(ofc[0..n], n, 29, OF_DEFAULT, 5, 8, of_ct, tables);
        let m_ml = choose_seq_table(mlc[0..n], n, 53, ML_DEFAULT, 6, 8, ml_ct, tables);
        body.push(((m_ll << 6) | (m_of << 4) | (m_ml << 2)) as u8);
        body.append(tables[0..tables.len]);
        encode_sequences(seqs[0..n], llc[0..n], mlc[0..n], ofc[0..n], ll_ct, of_ct, ml_ct, body);
    }
    let raw = end - start;
    if n == 0 || body.len >= raw {
        // Raw block: the bytes themselves; the repeat offsets stay as they were.
        let hdr = 0 | ((raw as i64) << 3);
        put_le(out, hdr, 3);
        out.append(data[start..end]);
    } else {
        let hdr = 0 | (2 << 1) | ((body.len as i64) << 3);
        put_le(out, hdr, 3);
        out.append(body[0..body.len]);
        r[0] = rr[0];
        r[1] = rr[1];
        r[2] = rr[2];
    }
}

// Compresses data as one zstd frame.
fn compress(data: const u8[:], out: u8[>..]&) -> bool {
    // Tables of the size the input needs: a small input does not pay for the full ones.
    let hb = highbit(data.len as i64) + 1;
    let hbits = min(16, max(10, hb));
    let lbits = min(17, max(10, hb + 1));
    var head: i32[>..] = [];
    head.resize(1 << hbits, 0);
    var longt: i32[>..] = [];
    longt.resize(1 << lbits, 0);
    return encode_frame(data, out, head[0..head.len], longt[0..longt.len], 1, 16 - hbits, 17 - lbits);
}
fn encode_frame(data: const u8[:], out: u8[>..]&, head: i32[:], longt: i32[:], base: i64, hshift: i64, lshift: i64) -> bool {
    // Frame header: magic, Frame_Header_Descriptor (single segment, 8-byte content size,
    // content checksum), the content size.
    put_le(out, 4247762216, 4);
    out.push(0xE4);
    put_le(out, data.len as i64, 8);
    var reps: i64[3] = [1, 4, 8];
    var start: i64 = 0;
    if data.len == 0 {
        put_le(out, 1 | (0 << 1) | (0 << 3), 3);
    }
    while start < data.len {
        let end = min(data.len, start + BLOCK_MAX);
        let last = end == data.len;
        // Append directly to the frame; a temporary block would copy every
        // raw or compressed byte once more before reaching this destination.
        let block_at = out.len;
        compress_block(data, start, end, head, longt, base, hshift, lshift, reps[0..3], out);
        // The first byte of the block header carries the last-block flag.
        if last { out[block_at] = out[block_at] | 1; }
        start = end;
    }
    let sum = xxh64(data[0..data.len]) & 4294967295;
    put_le(out, sum as i64, 4);
    return true;
}

fn compress_with(ctx: EncCtx&, data: const u8[:], out: u8[>..]&) -> bool {
    // Entries hold position + base; entries of earlier calls are below this call's base, so
    // they are never candidates. The base only restarts, with cleared tables, past 2^30.
    if ctx.base + data.len as i64 + 2 > 1073741824 {
        for i in 65536 { ctx.head[i] = 0; }
        for i in 131072 { ctx.longt[i] = 0; }
        ctx.base = 1;
    }
    // Same index shifts as compress(): table size follows the input length.
    let hb = highbit(data.len as i64) + 1;
    let ok = encode_frame(data, out, ctx.head[0..65536], ctx.longt[0..131072], ctx.base,
                          16 - min(16, max(10, hb)), 17 - min(17, max(10, hb + 1)));
    ctx.base = ctx.base + data.len as i64 + 1;
    return ok;
}

// Encoder state kept between calls: hash tables of positions (stored with an offset, see
// compress_with) and the offset of the next call.
struct EncCtx { head: i32[65536], longt: i32[131072], base: i64 }

fn enc_new() -> EncCtx {
    return EncCtx { [0; 65536], [0; 131072], 1 };
}


