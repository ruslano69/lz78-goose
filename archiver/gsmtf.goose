// SPDX-License-Identifier: MIT
namespace gsmtf;
import std;

// Bijective binary zero runs: digits RUNA=0 and RUNB=1 have weights 1 and 2.
// Other ranks 1..255 become symbols 2..256. No end symbol is necessary.
fn put_run(count: i64, out: u16[>..]&) {
    var n = count;
    while n > 0 {
        n--;
        out.push((n & 1) as u16);
        n >>= 1;
    }
}

fn encode(data: const u8[:], out: u16[>..]&) -> bool {
    if out.len != 0 { return false; }
    var alphabet: u8[256] = [0; 256];
    for i in 256 { alphabet[i] = i as u8; }
    var zeros: i64 = 0;
    for byte in data {
        var rank: i64 = 0;
        while alphabet[rank] != byte { rank++; }
        if rank == 0 { zeros++; continue; }
        put_run(zeros, out); zeros = 0;
        out.push((rank + 1) as u16);
        var j = rank;
        while j > 0 { alphabet[j] = alphabet[j - 1]; j--; }
        alphabet[0] = byte;
    }
    put_run(zeros, out);
    return true;
}

fn decode(symbols: const u16[:], expected: i64, out: u8[>..]&) -> bool {
    if out.len != 0 || expected < 0 || expected > 4194304 || symbols.len > expected { return false; }
    var alphabet: u8[256] = [0; 256];
    for i in 256 { alphabet[i] = i as u8; }
    var pos: i64 = 0;
    while pos < symbols.len {
        if symbols[pos] <= 1 {
            var run: i64 = 0;
            var weight: i64 = 1;
            while pos < symbols.len && symbols[pos] <= 1 {
                let add = (symbols[pos] as i64 + 1) * weight;
                if add > expected - out.len - run { return false; }
                run += add;
                weight *= 2;
                pos++;
            }
            for i in run { out.push(alphabet[0]); }
        } else {
            let rank = symbols[pos] as i64 - 1;
            if rank > 255 || out.len >= expected { return false; }
            let byte = alphabet[rank];
            var j = rank;
            while j > 0 { alphabet[j] = alphabet[j - 1]; j--; }
            alphabet[0] = byte;
            out.push(byte);
            pos++;
        }
    }
    return out.len == expected;
}
