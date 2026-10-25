namespace zstd_pipe;
import std;
import zstd;

// ---- Two threads: one parses blocks, the other codes them ----
//
// The parsing thread (the caller's) sends each block's sequences; the worker rebuilds the literals from
// them and the input, which it received once, writes the blocks and the checksum, and sends the frame
// body back. The parse assumes every block is written compressed, so its repeat-offset history advances
// at every block. A block written raw leaves the decoder's history where it was, so the worker keeps
// that history itself and, whenever it differs from the parse's, re-expresses the sequences against it.

struct InMsg { data: u8[] }
struct BlockMsg { start: i64, end: i64, kind: i64, seqs: zstd::Seq[] }
struct OutMsg { bytes: u8[] }

fn clone_bytes(d: const u8[:]) -> u8[>..] {
    var v: u8[>..] = [];
    v.append(d);
    return v;
}

fn no_seqs() -> zstd::Seq[>..] {
    var v: zstd::Seq[>..] = [];
    return v;
}

fn parse_block(data: const u8[:], start: i64, end: i64, head: u32[:], longt: u32[:], base: i64, hshift: i64, lshift: i64, rr: i64[:]) -> zstd::Seq[>..] {
    var seqs: zstd::Seq[>..] = [];
    var unused: u8[>..] = [];
    zstd::parse_dfast(data, start, end, head, longt, base, hshift, lshift, rr, seqs, unused, false);
    return seqs;
}

thread_fn entropy_worker() {
    let inm = qget<InMsg>();
    let data = inm.data;
    let sum = zstd::xxh64(data[0..data.len]) & 4294967295;
    var acc: u8[>..] = [];
    var assumed: i64[3] = [1, 4, 8];
    var actual: i64[3] = [1, 4, 8];
    loop {
        let m = qget<BlockMsg>();
        guard m.start >= 0 else { break; }
        let block_at = acc.len;
        if m.kind == 1 {
            let uniform = zstd::rle_block(data, m.start, m.end, acc);
            assert(uniform);
        } else {
            let same = assumed[0] == actual[0] && assumed[1] == actual[1] && assumed[2] == actual[2];
            var lits: u8[>..] = [];
            var seqs2: zstd::Seq[>..] = [];
            var fin: i64[3] = [actual[0], actual[1], actual[2]];
            var pos = m.start;
            for i in m.seqs.len {
                let sq = m.seqs[i];
                lits.append(data[pos..pos + sq.ll]);
                pos += (sq.ll as i64) + sq.ml;
                let off = zstd::rep_update(sq.ov, sq.ll, assumed[0..3]);
                if !same {
                    let nov = zstd::ov_for(off, sq.ll, fin[0..3]);
                    zstd::rep_update(nov, sq.ll, fin[0..3]);
                    seqs2.push(zstd::Seq { sq.ll, sq.ml, nov as! u32 });
                }
            }
            if same {
                fin[0] = assumed[0];
                fin[1] = assumed[1];
                fin[2] = assumed[2];
                zstd::emit_block(data, m.start, m.end, m.seqs[0..m.seqs.len], lits, pos, fin[0..3], actual[0..3], acc);
            } else {
                zstd::emit_block(data, m.start, m.end, seqs2[0..seqs2.len], lits, pos, fin[0..3], actual[0..3], acc);
            }
        }
        if m.end == data.len { acc[block_at] = acc[block_at] | 1; }
    }
    zstd::put_le(acc, sum as i64, 4);
    qput(OutMsg { bytes: clone_bytes(acc[0..acc.len]) });
}

// Compresses data as one zstd frame with two threads at levels 1..3; the output is the bytes zstd::compress_level
// gives. Other levels, and inputs under four blocks, take zstd::compress_level on this thread. Needs a program
// built with a C compiler (goose build), as threads do.
fn compress_pipelined(data: const u8[:], out: u8[>..]&, level: i64) -> bool {
    if level > 3 || data.len < 4 * zstd::BLOCK_MAX { return zstd::compress_level(data, out, level); }
    let hb = zstd::highbit(data.len as i64) + 1;
    let hbits = min(16, max(10, hb));
    let lbits = min(17, max(10, hb + 1));
    var head: u32[>..] = [];
    head.resize(1 << hbits, 0);
    var longt: u32[>..] = [];
    longt.resize(1 << lbits, 0);
    let id = thread_spawn(entropy_worker);
    qput(InMsg { data: clone_bytes(data) });
    zstd::put_le(out, 4247762216, 4);
    out.push(0xE4);
    zstd::put_le(out, data.len as i64, 8);
    var rr: i64[3] = [1, 4, 8];
    var scratch: u8[>..] = [];
    var start: i64 = 0;
    while start < data.len {
        let end = min(data.len, start + zstd::BLOCK_MAX);
        if zstd::rle_block(data, start, end, scratch) {
            qput(BlockMsg { start: start, end: end, kind: 1, seqs: no_seqs() });
        } else {
            qput(BlockMsg { start: start, end: end, kind: 0,
                            seqs: parse_block(data, start, end, head[0..head.len], longt[0..longt.len], 1, 16 - hbits, 17 - lbits, rr[0..3]) });
        }
        start = end;
    }
    qput(BlockMsg { start: -1, end: 0, kind: 0, seqs: no_seqs() });
    let res = qget<OutMsg>();
    thread_wait(id);
    out.append(res.bytes);
    return true;
}

