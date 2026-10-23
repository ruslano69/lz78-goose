// SPDX-License-Identifier: MIT
namespace bwt;
import std;
import sais;

let MAX_BYTES: i64 = 4194304;

// SA-IS induced suffix sorting; rank-doubling oracle is in bwt_baseline.goose.
// The unique symbol 0 terminates the text; input bytes map to symbols 1..256.
fn forward(input: const u8[:], out: u8[>..]&, primary: u32&) -> bool {
    if out.len != 0 || input.len > MAX_BYTES { return false; }
    var text: u32[>..] = [];
    for b in input { text.push(b as u32 + 1); }
    text.push(0);
    var order: u32[>..] = [];
    sais::sort(text, 257, order);
    primary = 0;
    for i in order.len {
        let p = order[i] as i64;
        if p == 0 { primary = i as u32; }
        else { out.push(input[p - 1]); }
    }
    return true;
}

// LF permutation over a virtual last column containing the omitted sentinel.
fn inverse(input: const u8[:], primary: u32, out: u8[>..]&) -> bool {
    let n = input.len;
    let p = primary as i64;
    if out.len != 0 || n > MAX_BYTES || p > n || (n > 0 && p == 0) { return false; }
    var counts: u32[>..] = []; counts.resize(257, 0);
    counts[0] = 1;
    for b in input { counts[b as i64 + 1]++; }
    var sum: u32 = 0;
    for i in 257 { let c = counts[i]; counts[i] = sum; sum += c; }
    var links: u32[>..] = []; links.resize(n + 1, 0);
    for i in n + 1 {
        let c = if i == p { 0 } else { input[if i < p { i } else { i - 1 }] as i64 + 1 };
        links[i] = counts[c]; counts[c]++;
    }
    out.resize(n, 0);
    var row = p;
    for i in n {
        row = links[row] as i64;
        if row == p { return false; }
        out[n - 1 - i] = input[if row < p { row } else { row - 1 }];
    }
    return links[row] as i64 == p;
}
