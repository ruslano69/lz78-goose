// Zstandard decoder (RFC 8878) in Goose. Tables are from RFC 8878 and libzstd (BSD-3-Clause).
// Scope: frames with skippable frames, raw/RLE/compressed blocks, Huffman literals (direct
// and FSE-coded weights, four streams, treeless), FSE sequence tables (predefined, RLE,
// compressed, repeat), repeat offsets and the content checksum. Dictionaries are rejected.
namespace zstd;
import std;

let LL_BASE: i64[36] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536];
let LL_BITS: i64[36] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
let ML_BASE: i64[53] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539];
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
    var h: i64 = 0;
    var v = x;
    while v > 1 {
        v = v >> 1;
        h += 1;
    }
    return h;
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
fn bwd_read(src: const u8[:], r: Bwd&, k: i64) -> i64 {
    var v: i64 = 0;
    for i in k {
        let idx = r.pos - k + i;
        if idx >= 0 {
            v = v | ((((src[idx >> 3] as i64) >> (idx & 7)) & 1) << i);
        }
    }
    r.pos -= k;
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
fn sequences(blk: const u8[:], lits: const u8[:], out: u8[>..]&, frame_start: i64, ctx: Ctx&) -> bool {
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
        let off_val = (1 << ofc) + bwd_read(stream, r, ofc);
        let ml = ML_BASE[mlc] + bwd_read(stream, r, ML_BITS[mlc]);
        let ll = LL_BASE[llc] + bwd_read(stream, r, LL_BITS[llc]);
        if i + 1 < nbseq {
            st_ll = (ctx.ll.base[st_ll] as i64) + bwd_read(stream, r, ctx.ll.nb[st_ll] as i64);
            st_ml = (ctx.ml.base[st_ml] as i64) + bwd_read(stream, r, ctx.ml.nb[st_ml] as i64);
            st_of = (ctx.of.base[st_of] as i64) + bwd_read(stream, r, ctx.of.nb[st_of] as i64);
        }
        if r.pos < 0 { return false; }
        // Literals first, then the match from the window (RFC 8878 3.1.1.3.2.2).
        if lp + ll > lits.len { return false; }
        for k in ll {
            out.push(lits[lp + k]);
        }
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
        for k in ml {
            out.push(out[out.len - offset]);
        }
    }
    if lp < lits.len {
        out.append(lits[lp..lits.len]);
    }
    return true;
}

fn decode_block(blk: const u8[:], out: u8[>..]&, frame_start: i64, ctx: Ctx&) -> bool {
    var lits: u8[>..] = [];
    let used = lit_section(blk, lits, ctx);
    if used < 0 { return false; }
    return sequences(blk[used..blk.len], lits[0..lits.len], out, frame_start, ctx);
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

fn read64(d: const u8[:], i: i64) -> u64 {
    var v: u64 = 0;
    for k in 8 {
        v = v | ((d[i + k] as u64) << ((8 * k) as u64));
    }
    return v;
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
        pos += fcs_bytes;
        if pos > data.len { return false; }

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
            if btype == 0 {
                if pos + bsize > data.len { return false; }
                out.append(data[pos..pos + bsize]);
                pos += bsize;
            } else if btype == 1 {
                if pos + 1 > data.len { return false; }
                let b = data[pos];
                for k in bsize { out.push(b); }
                pos += 1;
            } else if btype == 2 {
                if pos + bsize > data.len { return false; }
                if !decode_block(data[pos..pos + bsize], out, frame_start, ctx) { return false; }
                pos += bsize;
            } else {
                return false;
            }
        }
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
let CHAIN_DEPTH: i64 = 16;

struct FseCt { tl: i64, tbl: u16[512], dnb: i64[64], dfind: i64[64] }
struct BitW { acc: u64, count: i64 }
struct Seq { ll: i64, ml: i64, off: i64 }

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
    while bw.count >= 8 {
        out.push((bw.acc & 255) as u8);
        bw.acc = bw.acc >> 8;
        bw.count -= 8;
    }
}

// Ends a backward stream: a sentinel 1 bit, then zero padding to a byte boundary.
fn bitw_close(out: u8[>..]&, bw: BitW&) {
    bitw_add(out, bw, 1, 1);
    if bw.count > 0 {
        out.push((bw.acc & 255) as u8);
    }
    bw.acc = 0;
    bw.count = 0;
}

// Encodes sym from state (the state value lies in [size, 2*size)); returns the next state.
fn fse_put(out: u8[>..]&, bw: BitW&, ct: FseCt, state: i64, sym: i64) -> i64 {
    let nb = (state + ct.dnb[sym]) >> 16;
    bitw_add(out, bw, state, nb);
    return ct.tbl[((state >> nb) + ct.dfind[sym]) as i64] as i64;
}

// The initial state for sym (libzstd's FSE_initCState2); writes no bits.
fn fse_init(ct: FseCt, sym: i64) -> i64 {
    let nb = (ct.dnb[sym] + (1 << 15)) >> 16;
    let v = (nb << 16) - ct.dnb[sym];
    return ct.tbl[((v >> nb) + ct.dfind[sym]) as i64] as i64;
}

fn ll_code(v: i64) -> i64 {
    var c: i64 = 35;
    while LL_BASE[c] > v { c -= 1; }
    return c;
}

fn ml_code(v: i64) -> i64 {
    var c: i64 = 52;
    while ML_BASE[c] > v { c -= 1; }
    return c;
}

// Sequences of one block as a backward bitstream, in the order the decoder reads them.
fn encode_sequences(seqs: Seq[:], ll_ct: FseCt, of_ct: FseCt, ml_ct: FseCt, out: u8[>..]&) {
    let n = seqs.len;
    var bw = BitW { 0, 0 };
    let last = seqs[n - 1];
    let llc = ll_code(last.ll);
    let mlc = ml_code(last.ml);
    let ofv = last.off + 3;
    let ofc = highbit(ofv);
    var st_ll = fse_init(ll_ct, llc);
    var st_of = fse_init(of_ct, ofc);
    var st_ml = fse_init(ml_ct, mlc);
    bitw_add(out, bw, last.ll - LL_BASE[llc], LL_BITS[llc]);
    bitw_add(out, bw, last.ml - ML_BASE[mlc], ML_BITS[mlc]);
    bitw_add(out, bw, ofv - (1 << ofc), ofc);
    var i = n - 2;
    while i >= 0 {
        let s = seqs[i];
        let llc2 = ll_code(s.ll);
        let mlc2 = ml_code(s.ml);
        let ofv2 = s.off + 3;
        let ofc2 = highbit(ofv2);
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

fn of_size(ct: FseCt) -> i64 {
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

// Encodes one block of data[start..end). Returns false if it cannot be made smaller.
fn compress_block(data: const u8[:], start: i64, end: i64, head: i32[:], prev: i32[:], out: u8[>..]&) {
    var seqs: Seq[>..] = [];
    var lits: u8[>..] = [];
    var lit_start = start;
    var p = start;
    while p < end {
        var best_len: i64 = 0;
        var best_pos: i64 = -1;
        if p + 4 <= data.len {
            let h = hash4_zstd(data, p);
            var cand = head[h] as i64;
            var chain = CHAIN_DEPTH;
            let limit = min(131072, end - p);
            while cand >= 0 && chain > 0 {
                chain -= 1;
                var l: i64 = 0;
                while l < limit && data[cand + l] == data[p + l] { l += 1; }
                if l > best_len {
                    best_len = l;
                    best_pos = cand;
                }
                cand = prev[cand] as i64;
            }
            prev[p] = head[h];
            head[h] = p as i32;
        }
        if best_len >= MIN_MATCH_ZSTD {
            seqs.push(Seq { p - lit_start, best_len, p - best_pos });
            lits.append(data[lit_start..p]);
            var k = p + 1;
            while k < p + best_len && k + 4 <= data.len {
                let h2 = hash4_zstd(data, k);
                prev[k] = head[h2];
                head[h2] = k as i32;
                k += 1;
            }
            p += best_len;
            lit_start = p;
        } else {
            p += 1;
        }
    }
    lits.append(data[lit_start..end]);
    // Block body: literals, sequence count, modes (all predefined), bitstream.
    var body: u8[>..] = [];
    put_literals(body, lits[0..lits.len]);
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
        body.push(0);
        var ll_ct = fse_ct_new();
        var of_ct = fse_ct_new();
        var ml_ct = fse_ct_new();
        fse_ct_build(LL_DEFAULT, 36, 6, ll_ct);
        fse_ct_build(OF_DEFAULT, 29, 5, of_ct);
        fse_ct_build(ML_DEFAULT, 53, 6, ml_ct);
        encode_sequences(seqs[0..n], ll_ct, of_ct, ml_ct, body);
    }
    let raw = end - start;
    if n == 0 || body.len >= raw {
        // Raw block: the bytes themselves.
        let hdr = 0 | ((raw as i64) << 3);
        put_le(out, hdr, 3);
        out.append(data[start..end]);
    } else {
        let hdr = 0 | (2 << 1) | ((body.len as i64) << 3);
        put_le(out, hdr, 3);
        out.append(body[0..body.len]);
    }
}

fn hash4_zstd(data: const u8[:], p: i64) -> i64 {
    let v: u32 = (data[p] as u32) | ((data[p + 1] as u32) << 8) | ((data[p + 2] as u32) << 16) | ((data[p + 3] as u32) << 24);
    return ((v * 2654435761) >> (32 - HASH_BITS_ZSTD)) as i64;
}

// Compresses data as one zstd frame.
fn compress(data: const u8[:], out: u8[>..]&) -> bool {
    // Frame header: magic, Frame_Header_Descriptor (single segment, 8-byte content size,
    // content checksum), the content size.
    put_le(out, 4247762216, 4);
    out.push(0xE4);
    put_le(out, data.len as i64, 8);
    var head: i32[65536] = [-1; 65536];
    var prev: i32[>..] = [];
    for i in data.len { prev.push(-1); }
    var start: i64 = 0;
    if data.len == 0 {
        put_le(out, 1 | (0 << 1) | (0 << 3), 3);
    }
    while start < data.len {
        let end = min(data.len, start + BLOCK_MAX);
        let last = end == data.len;
        var blkbuf: u8[>..] = [];
        compress_block(data, start, end, head[0..65536], prev[0..prev.len], blkbuf);
        // The first byte of the block header carries the last-block flag.
        if last {
            blkbuf[0] = blkbuf[0] | 1;
        }
        out.append(blkbuf[0..blkbuf.len]);
        start = end;
    }
    let sum = xxh64(data[0..data.len]) & 4294967295;
    put_le(out, sum as i64, 4);
    return true;
}
