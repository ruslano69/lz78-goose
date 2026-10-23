// SPDX-License-Identifier: Apache-2.0
// Goose adaptation of the SA-IS approach in ruslano69/kanzi-rs sais.rs.
// See NOTICE and LICENSE-APACHE-2.0; uses byte flags and direct reduced sentinel.
namespace sais;
import std;

// Arena offsets remain valid while grow-only storage relocates; no live views
// cross growth. Explicit levels satisfy Goose's no-owned-buffers recursion rule.
struct Frame {
    text: i64, order: i64, types: i64, lms: i64, counts: i64,
    n: i64, alphabet: i64, lms_count: i64
}

// SA-IS with explicit unique zero sentinel. Positions and names fit in u32.
// This implementation uses checked indexing and byte S/L flags, not raw pointers.
fn is_lms(types: const u8[:], p: i64) -> bool {
    return p > 0 && types[p] != 0 && types[p - 1] == 0;
}

fn same_lms(text: const u32[:], types: const u8[:], a: i64, b: i64) -> bool {
    if a == b { return true; }
    var d: i64 = 0;
    while a + d < text.len && b + d < text.len {
        let x = a + d;
        let y = b + d;
        if text[x] != text[y] { return false; }
        let xl = is_lms(types, x);
        let yl = is_lms(types, y);
        if d > 0 && (xl || yl) { return xl && yl; }
        d++;
    }
    return false;
}

fn induce(text: const u32[:], types: const u8[:], counts: const u32[:],
          seeds: const u32[:], order: u32[:]) {
    let empty: u32 = 4294967295;
    for i in order.len { order[i] = empty; }
    var buckets: u32[>..] = []; buckets.resize(counts.len, 0);
    var sum: u32 = 0;
    for i in counts.len { sum += counts[i]; buckets[i] = sum; }
    var i = seeds.len;
    while i > 0 {
        i--;
        let p = seeds[i];
        let c = text[p as i64];
        buckets[c as i64]--;
        order[buckets[c as i64] as i64] = p;
    }
    sum = 0;
    for c in counts.len { buckets[c] = sum; sum += counts[c]; }
    for slot in order.len {
        let p = order[slot];
        if p == empty || p == 0 { continue; }
        let prev = p as i64 - 1;
        if types[prev] == 0 {
            let c = text[prev] as i64;
            order[buckets[c] as i64] = prev as u32;
            buckets[c]++;
        }
    }
    sum = 0;
    for c in counts.len { sum += counts[c]; buckets[c] = sum; }
    i = order.len;
    while i > 0 {
        i--;
        let p = order[i];
        if p == empty || p == 0 { continue; }
        let prev = p as i64 - 1;
        if types[prev] != 0 {
            let c = text[prev] as i64;
            buckets[c]--;
            order[buckets[c] as i64] = prev as u32;
        }
    }
}

// Internal preconditions: nonempty text, unique terminal zero, other symbols
// in 1..alphabet-1, empty output. Reduced levels have the same contract.
fn sort(text: const u32[:], alphabet: i64, order: u32[>..]&) {
    var texts: u32[>..] = []; texts.append(text);
    var all_types: u8[>..] = [];
    var all_lms: u32[>..] = [];
    var all_counts: u32[>..] = [];
    var orders: u32[>..] = [];
    var frames: Frame[>..] = [];
    var at: i64 = 0;
    var n = text.len;
    var alpha = alphabet;
    while true {
        let type_at = all_types.len;
        let lms_at = all_lms.len;
        let count_at = all_counts.len;
        let order_at = orders.len;
        var types: u8[>..] = []; types.resize(n, 0);
        types[n - 1] = 1;
        var i = n - 1;
        while i > 0 {
            i--;
            if texts[at + i] < texts[at + i + 1] ||
               (texts[at + i] == texts[at + i + 1] && types[i + 1] != 0) { types[i] = 1; }
        }
        var lms: u32[>..] = [];
        for p in 1..n { if is_lms(types, p) { lms.push(p as u32); } }
        var counts: u32[>..] = []; counts.resize(alpha, 0);
        for p in n { counts[texts[at + p] as i64]++; }
        var local_order: u32[>..] = []; local_order.resize(n, 0);
        if n == 1 {
            orders.push(0);
            frames.push(Frame { at, order_at, type_at, lms_at, count_at, n, alpha, 0 });
            break;
        }
        induce(texts[at..at + n], types, counts, lms, local_order);
        var names: u32[>..] = []; names.resize(n, 0);
        var classes: u32 = 0;
        var previous: i64 = -1;
        for pos in local_order {
            let p = pos as i64;
            if !is_lms(types, p) { continue; }
            if previous >= 0 && !same_lms(texts[at..at + n], types, previous, p) { classes++; }
            names[p] = classes;
            previous = p;
        }
        classes++;
        var reduced: u32[>..] = [];
        for p in lms { reduced.push(names[p as i64]); }
        all_types.append(types);
        all_lms.append(lms);
        all_counts.append(counts);
        frames.push(Frame { at, order_at, type_at, lms_at, count_at, n, alpha, lms.len });
        if classes as i64 == lms.len {
            var seeds: u32[>..] = []; seeds.resize(lms.len, 0);
            for p in reduced.len { seeds[reduced[p] as i64] = lms[p]; }
            induce(texts[at..at + n], types, counts, seeds, local_order);
            orders.append(local_order);
            break;
        }
        orders.resize(orders.len + n, 0);
        at = texts.len;
        texts.append(reduced);
        n = reduced.len;
        alpha = classes as i64;
    }
    var depth = frames.len - 1;
    while depth > 0 {
        let child = frames[depth];
        let parent = frames[depth - 1];
        var seeds: u32[>..] = [];
        for i in child.n {
            seeds.push(all_lms[parent.lms + orders[child.order + i] as i64]);
        }
        induce(texts[parent.text..parent.text + parent.n],
               all_types[parent.types..parent.types + parent.n],
               all_counts[parent.counts..parent.counts + parent.alphabet], seeds,
               orders[parent.order..parent.order + parent.n]);
        depth--;
    }
    order.append(orders[..text.len]);
}
