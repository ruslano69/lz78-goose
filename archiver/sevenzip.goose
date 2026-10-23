// SPDX-License-Identifier: MIT
namespace sevenzip;
import std;
import garchive;
import gsunicode;
import gsbzip2;
import zstd;

let MAX_FILES: i64 = 65535;
let MAX_HEADER: i64 = 8388608;
let MAX_DATA: u64 = 67108864;
// Status: 0 success, 1 invalid archive/input, 2 unsupported feature, 3 limit.
struct Entry {
    name_at: u32, name_len: u32, size: u64, offset: u64,
    crc: u32, mtime: u64, flags: u8, packed: u64, method: u8
}
// flags: bit 0 directory, bit 1 defined mtime, bit 2 defined content CRC.
// packed/offset describe archive bytes after read; size is always original.
// method: 0 Copy, 1 BZip2, 2 ZSTD (7-Zip-zstd ID 04 F7 11 01). Writer input offsets address contents, not archive.
struct Cursor { pos: i64, error: i64 }

fn path(e: Entry, names: const u8[:]) -> const u8[:] {
    return names[(e.name_at as i64)..e.name_at as i64 + e.name_len as i64];
}

fn put_number(out: u8[>..]&, value: u64) {
    var first: u8 = 0;
    var mask: u8 = 128;
    var extra: i64 = 0;
    while extra < 8 {
        if value < (1 as u64 << (7 * (extra + 1))) {
            first |= (value >> (8 * extra)) as u8;
            break;
        }
        first |= mask; mask >>= 1; extra++;
    }
    out.push(first);
    garchive::put_le(out, value, extra);
}

fn byte(data: const u8[:], c: Cursor&) -> u8 {
    if c.error != 0 { return 0; }
    if c.pos >= data.len { c.error = 1; return 0; }
    let v = data[c.pos]; c.pos++; return v;
}

fn fixed(data: const u8[:], c: Cursor&, width: i64) -> u64 {
    if c.error != 0 || data.len - c.pos < width { c.error = 1; return 0; }
    let value = garchive::get_le(data, c.pos, width); c.pos += width; return value;
}

fn number(data: const u8[:], c: Cursor&) -> u64 {
    let first = byte(data, c);
    var mask: u8 = 128;
    var value: u64 = 0;
    for i in 8 {
        if (first & mask) == 0 {
            return value | ((first & (mask - 1)) as u64 << (i * 8));
        }
        value |= byte(data, c) as u64 << (i * 8);
        mask >>= 1;
    }
    return value;
}

fn expect(data: const u8[:], c: Cursor&, tag: u8) {
    if byte(data, c) != tag && c.error == 0 { c.error = 2; }
}

fn less(a: const u8[:], b: const u8[:]) -> bool {
    for i in min(a.len, b.len) { if a[i] != b[i] { return a[i] < b[i]; } }
    return a.len < b.len;
}

fn valid_path(name: const u8[:]) -> bool {
    if name.len == 0 || name.len > 4096 || name[0] == '/' { return false; }
    var start: i64 = 0;
    var pos: i64 = 0;
    while pos < name.len {
        let at = pos;
        let cp, ok = gsunicode::scalar(name, pos);
        if !ok || cp < 32 || cp == 127 || cp == 92 || cp == 58 { return false; }
        if cp == 47 {
            let part = name[start..at];
            if part.len == 0 || part == "." || part == ".." { return false; }
            start = pos;
        }
    }
    let tail = name[start..];
    return tail.len > 0 && tail != "." && tail != "..";
}

fn validate(entries: const Entry[:], names: const u8[:]) -> i64 {
    if entries.len > MAX_FILES || names.len > MAX_HEADER { return 3; }
    var order: u32[>..] = [];
    var total: u64 = 0;
    for i in entries.len {
        let e = entries[i];
        if e.name_at as i64 > names.len || e.name_len as i64 > names.len - e.name_at as i64 { return 1; }
        if !valid_path(path(e, names)) || (e.flags & 248) != 0 { return 1; }
        if (e.flags & 1) != 0 && e.size != 0 { return 1; }
        if e.size > MAX_DATA - total { return 3; }
        total += e.size;
        order.push(i as u32);
    }
    sort(order) { a, b => less(path(entries[a as i64], names), path(entries[b as i64], names)) }
    for i in order.len {
        let name = path(entries[order[i] as i64], names);
        if i > 0 && name == path(entries[order[i - 1] as i64], names) { return 1; }
        for j in name.len {
            if name[j] != '/' { continue; }
            let prefix = name[..j];
            var lo: i64 = 0; var hi = order.len;
            while lo < hi {
                let mid = lo + (hi - lo) / 2;
                if less(path(entries[order[mid] as i64], names), prefix) { lo = mid + 1; } else { hi = mid; }
            }
            if lo < order.len {
                let parent = entries[order[lo] as i64];
                if path(parent, names) == prefix && (parent.flags & 1) == 0 { return 1; }
            }
        }
    }
    return 0;
}

fn bit(data: const u8[:], i: i64) -> bool { return (data[i / 8] & (128 as u8 >> (i % 8))) != 0; }

fn bitmap(entries: const Entry[:], empty_only: bool, out: u8[>..]&) {
    var current: u8 = 0; var n: i64 = 0;
    for e in entries {
        let empty = e.size == 0;
        if empty_only && !empty { continue; }
        let value = if empty_only { (e.flags & 1) == 0 } else { empty };
        if value { current |= 128 as u8 >> (n % 8); }
        n++;
        if n % 8 == 0 { out.push(current); current = 0; }
    }
    if n % 8 != 0 { out.push(current); }
}

fn property(out: u8[>..]&, tag: u8, payload: const u8[:]) {
    out.push(tag); put_number(out, payload.len as u64); out.append(payload);
}

fn write(entries: const Entry[:], names: const u8[:], contents: const u8[:], out: u8[>..]&) -> i64 {
    return write_with_level(entries, names, contents, out, 0);
}
fn write_with_level(entries: const Entry[:], names: const u8[:], contents: const u8[:], out: u8[>..]&, level: i64) -> i64 {
    if out.len != 0 || level < 0 || level > 9 { return 1; }
    let checked = validate(entries, names); if checked != 0 { return checked; }
    var header: u8[>..] = []; header.push(1);
    var streams: i64 = 0; var empties: i64 = 0;
    for e in entries {
        if e.size > 0 { streams++; } else { empties++; }
        if e.offset > contents.len as u64 || e.size > contents.len as u64 - e.offset { return 1; }
    }
    out.resize(32, 0);
    var packed_sizes: u64[>..] = []; var methods: u8[>..] = [];
    for e in entries {
        if e.size == 0 { continue; }
        let input = contents[(e.offset as i64)..(e.offset + e.size) as i64];
        let mark = out.len;
        var bz_out: u8[>..] = [];
        var zs_out: u8[>..] = [];
        var method: u8 = 0;
        // Trial encodings are written after mark and rolled back; the smallest one that beats
        // Copy wins. Each method's coder-ID bytes count in the break-even test.
        if level > 0 && e.size >= 64 {
            if !gsbzip2::append_stream(input, out, level) { return 1; }
            let bz: i64 = out.len as i64 - mark as i64;
            if bz > 0 && bz + 2 < input.len as i64 { bz_out.append(out[mark..out.len]); method = 1; }
            out.resize(mark);
            if !zstd::compress(input, out) { return 1; }
            let zs: i64 = out.len as i64 - mark as i64;
            let beats_bzip2 = method == 0 || zs < bz;
            if zs > 0 && zs + 7 < input.len as i64 && beats_bzip2 { zs_out.append(out[mark..out.len]); method = 2; }
            out.resize(mark);
        }
        if method == 0 { out.append(input); packed_sizes.push(e.size); }
        else if method == 1 { out.append(bz_out[0..bz_out.len]); packed_sizes.push(bz_out.len as u64); }
        else { out.append(zs_out[0..zs_out.len]); packed_sizes.push(zs_out.len as u64); }
        methods.push(method);
    }
    if streams > 0 {
        header.append([4, 6]); put_number(header, 0); put_number(header, streams as u64); header.push(9);
        for n in packed_sizes { put_number(header, n); }
        header.append([0, 7, 11]); put_number(header, streams as u64); header.push(0);
        for method in methods {
            if method == 0 { header.append("\x01\x01\0"); }
            else if method == 1 { header.append("\x01\x03\x04\x02\x02"); }
            else { header.append("\x01\x24\x04\xf7\x11\x01\x01\0"); }
        }
        header.push(12);
        for e in entries { if e.size > 0 { put_number(header, e.size); } }
        header.append([10, 1]);
        for e in entries {
            if e.size > 0 { garchive::put_le(header, garchive::crc32(contents[(e.offset as i64)..(e.offset + e.size) as i64]) as u64, 4); }
        }
        header.append([0, 8, 0, 0]);
    }
    if entries.len > 0 {
        header.push(5); put_number(header, entries.len as u64);
        if empties > 0 {
            var empty_stream: u8[>..] = []; bitmap(entries, false, empty_stream); property(header, 14, empty_stream);
            var empty_file: u8[>..] = []; bitmap(entries, true, empty_file); property(header, 15, empty_file);
        }
        var text: u8[>..] = []; text.push(0);
        for e in entries {
            var wide: u16[>..] = [];
            if !gsunicode::to_utf16(path(e, names), wide) { return 1; }
            for w in wide { garchive::put_le(text, w as u64, 2); }
        }
        property(header, 17, text);
        var times: i64 = 0;
        for e in entries { if (e.flags & 2) != 0 { times++; } }
        if times > 0 {
            var values: u8[>..] = []; values.push(if times == entries.len { 1 } else { 0 });
            if times != entries.len {
                var current: u8 = 0;
                for i in entries.len {
                    if (entries[i].flags & 2) != 0 { current |= 128 as u8 >> (i % 8); }
                    if i % 8 == 7 { values.push(current); current = 0; }
                }
                if entries.len % 8 != 0 { values.push(current); }
            }
            values.push(0);
            for e in entries { if (e.flags & 2) != 0 { garchive::put_le(values, e.mtime, 8); } }
            property(header, 20, values);
        }
        header.push(0);
    }
    header.push(0);
    if header.len > MAX_HEADER { return 3; }
    let offset = out.len - 32;
    var start: u8[>..] = [];
    garchive::put_le(start, offset as u64, 8); garchive::put_le(start, header.len as u64, 8);
    garchive::put_le(start, garchive::crc32(header) as u64, 4);
    let signature: u8[8] = [55, 122, 188, 175, 39, 28, 0, 4];
    for i in 8 { out[i] = signature[i]; }
    let crc = garchive::crc32(start);
    for i in 4 { out[8 + i] = ((crc >> (i * 8)) & 255) as u8; }
    for i in 20 { out[12 + i] = start[i]; }
    out.append(header);
    return 0;
}

fn unpack(data: const u8[:], e: Entry, out: u8[>..]&) -> bool {
    if out.len != 0 || e.size > MAX_DATA || e.offset > data.len as u64 || e.packed > data.len as u64 - e.offset { return false; }
    if e.size == 0 { return e.packed == 0 && e.method == 0; }
    let bytes = data[(e.offset as i64)..(e.offset + e.packed) as i64];
    if e.method == 0 { if e.packed != e.size { return false; } out.append(bytes); }
    else if e.method == 1 { if !gsbzip2::decompress(bytes, out, e.size as i64) { return false; } }
    else if e.method == 2 { if !zstd::decompress(bytes, out) { return false; } }
    else { return false; }
    return out.len as u64 == e.size && (e.flags & 4) != 0 && garchive::crc32(out) == e.crc;
}


// Digest vectors can be all-defined or have a separate MSB-first presence map.
fn digests(data: const u8[:], c: Cursor&, count: i64, values: u32[>..]&, defined: u8[>..]&) {
    let all = byte(data, c);
    if all > 1 { c.error = 1; return; }
    let start = c.pos;
    if all == 0 { c.pos += (count + 7) / 8; }
    if c.pos > data.len { c.error = 1; return; }
    for i in count {
        let present = all == 1 || bit(data[start..c.pos], i);
        defined.push(if present { 1 } else { 0 });
        values.push(if present { fixed(data, c, 4) as u32 } else { 0 });
    }
}

fn read(data: const u8[:], entries: Entry[>..]&, names: u8[>..]&) -> i64 {
    if entries.len != 0 || names.len != 0 || data.len < 32 || data[..6] != "7z\xbc\xaf\x27\x1c" { return 1; }
    if data[6] != 0 || data[7] > 4 { return 2; }
    if garchive::crc32(data[12..32]) != garchive::get_le(data, 8, 4) as u32 { return 1; }
    let offset = garchive::get_le(data, 12, 8); let size = garchive::get_le(data, 20, 8);
    if size > MAX_HEADER || offset > MAX_DATA { return 3; }
    if offset > (data.len - 32) as u64 || size != (data.len - 32) as u64 - offset { return 1; }
    if size == 0 { return if offset == 0 && data.len == 32 && garchive::get_le(data, 28, 4) == 0 { 0 } else { 1 }; }
    let header = data[32 + (offset as i64)..];
    if garchive::crc32(header) != garchive::get_le(data, 28, 4) as u32 { return 1; }
    var c = Cursor { 0, 0 };
    expect(header, c, 1);
    if c.error != 0 { return c.error; }
    var tag = byte(header, c);
    var sizes: u64[>..] = []; var unpacked: u64[>..] = []; var methods: u8[>..] = [];
    var crcs: u32[>..] = []; var crc_defined: u8[>..] = [];
    var packed_crcs: u32[>..] = []; var packed_defined: u8[>..] = [];
    if tag == 4 {
        expect(header, c, 6);
        if number(header, c) != 0 && c.error == 0 { c.error = 2; }
        let streams = number(header, c);
        if streams == 0 || streams > MAX_FILES { return 3; }
        expect(header, c, 9);
        var total: u64 = 0;
        for i in streams as i64 {
            let n = number(header, c);
            if n == 0 || n > MAX_DATA - total { return 3; }
            total += n; sizes.push(n);
        }
        if total != offset { return 1; }
        tag = byte(header, c);
        if tag == 10 { digests(header, c, streams as i64, packed_crcs, packed_defined); tag = byte(header, c); }
        if tag != 0 && c.error == 0 { c.error = 2; }
        expect(header, c, 7); expect(header, c, 11);
        if number(header, c) != streams { return 1; }
        expect(header, c, 0);
        for i in streams as i64 {
            if number(header, c) != 1 { return 2; }
            let descriptor = byte(header, c);
            if descriptor == 1 && byte(header, c) == 0 { methods.push(0); }
            else if descriptor == 3 && byte(header, c) == 4 && byte(header, c) == 2 && byte(header, c) == 2 { methods.push(1); }
            else if descriptor == 0x24 && byte(header, c) == 4 && byte(header, c) == 0xF7 && byte(header, c) == 0x11 && byte(header, c) == 1 {
                // ZSTD 04 F7 11 01 (7-Zip-zstd). Its properties are one flags byte; 3 and 5 bytes are accepted too.
                let props = number(header, c);
                if props != 1 && props != 3 && props != 5 { return 2; }
                for k in props as i64 { let skip = byte(header, c); }
                methods.push(2);
            }
            else { return if c.error != 0 { c.error } else { 2 }; }
        }
        expect(header, c, 12);
        var decoded_total: u64 = 0;
        for i in sizes.len {
            let n = number(header, c);
            if n == 0 { return 2; }
            if n > MAX_DATA - decoded_total { return 3; }
            if methods[i] == 0 && n != sizes[i] { return 1; }
            decoded_total += n; unpacked.push(n);
        }
        tag = byte(header, c);
        if tag == 10 { digests(header, c, streams as i64, crcs, crc_defined); tag = byte(header, c); }
        else { crcs.resize(streams as i64, 0); crc_defined.resize(streams as i64, 0); }
        if c.error != 0 { return c.error; }
        if tag != 0 { return 2; }
        tag = byte(header, c);
        if tag == 8 {
            tag = byte(header, c);
            if tag == 13 {
                for i in streams as i64 { if number(header, c) != 1 { return if c.error != 0 { c.error } else { 2 }; } }
                tag = byte(header, c);
            }
            if tag == 10 {
                var missing: i64 = 0;
                for present in crc_defined { if present == 0 { missing++; } }
                var sub_crcs: u32[>..] = []; var sub_defined: u8[>..] = [];
                digests(header, c, missing, sub_crcs, sub_defined);
                if c.error != 0 { return c.error; }
                var j: i64 = 0;
                for i in crc_defined.len {
                    if crc_defined[i] == 0 { crcs[i] = sub_crcs[j]; crc_defined[i] = sub_defined[j]; j++; }
                }
                tag = byte(header, c);
            }
            if tag != 0 { return if c.error != 0 { c.error } else { 2 }; }
            tag = byte(header, c);
        }
        if tag != 0 { return 2; }
        tag = byte(header, c);
    } else if offset != 0 { return 1; }
    if c.error != 0 { return c.error; }
    if tag == 0 { return if c.pos == header.len && sizes.len == 0 { 0 } else { 1 }; }
    if tag != 5 { return 2; }
    let count = number(header, c);
    if count == 0 || count > MAX_FILES { return 3; }
    entries.resize(count as i64, Entry { 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    var empty_stream: u8[>..] = []; var empty_file: u8[>..] = [];
    var seen: u32 = 0;
    while c.error == 0 {
        tag = byte(header, c); if tag == 0 { break; }
        let length = number(header, c);
        if length > (header.len - c.pos) as u64 { return 1; }
        let p = header[c.pos..c.pos + length as i64]; c.pos += length as i64;
        var q = Cursor { 0, 0 };
        var flag: u32 = 0;
        if tag == 14 { flag = 1; empty_stream.append(p); }
        else if tag == 15 { flag = 2; empty_file.append(p); }
        else if tag == 17 {
            flag = 4; expect(p, q, 0);
            for i in entries.len {
                var wide: u16[>..] = [];
                while q.error == 0 {
                    let w = fixed(p, q, 2) as u16;
                    if w == 0 { break; }
                    wide.push(w);
                    if wide.len > 4096 { return 3; }
                }
                let at = names.len;
                if q.error != 0 { return q.error; }
                if !gsunicode::from_utf16(wide, names) { return 1; }
                if names.len > MAX_HEADER { return 3; }
                entries[i].name_at = at as u32; entries[i].name_len = (names.len - at) as u32;
            }
            if q.error != 0 || q.pos != p.len { return if q.error == 2 { 2 } else { 1 }; }
        } else if tag == 20 || tag == 21 || tag == 18 || tag == 19 {
            flag = if tag == 20 { 8 } else if tag == 21 { 16 } else if tag == 18 { 32 } else { 64 };
            let all = byte(p, q); if all > 1 { return 1; }
            let at = q.pos;
            if all == 0 { q.pos += (entries.len + 7) / 8; }
            if q.pos > p.len { return 1; }
            let mask_end = q.pos;
            expect(p, q, 0);
            for i in entries.len {
                if all == 1 || bit(p[at..mask_end], i) {
                    let value = fixed(p, q, if tag == 21 { 4 } else { 8 });
                    if tag == 20 { entries[i].mtime = value; entries[i].flags |= 2; }
                    if tag == 21 {
                        if (value & 1024) != 0 { return 2; }
                        let mode = (value >> 16) & 61440;
                        if mode != 0 && mode != 32768 && mode != 16384 { return 2; }
                    }
                }
            }
            if q.error != 0 || q.pos != p.len { return if q.error == 2 { 2 } else { 1 }; }
        } else if tag == 16 || tag == 24 { return 2; }
        else if tag != 25 { return 2; }
        if flag != 0 && (seen & flag) != 0 { return 1; }
        seen |= flag;
    }
    expect(header, c, 0);
    if c.error != 0 || c.pos != header.len || (seen & 4) == 0 { return if c.error != 0 { c.error } else { 1 }; }
    if (seen & 1) != 0 && empty_stream.len != (entries.len + 7) / 8 { return 1; }
    var empties: i64 = 0;
    for i in entries.len { if empty_stream.len > 0 && bit(empty_stream, i) { empties++; } }
    if (seen & 2) != 0 && empty_file.len != (empties + 7) / 8 { return 1; }
    var stream: i64 = 0; var empty: i64 = 0; var position: u64 = 32;
    for i in entries.len {
        if empty_stream.len > 0 && bit(empty_stream, i) {
            if empty_file.len == 0 || !bit(empty_file, empty) { entries[i].flags |= 1; }
            empty++;
        } else {
            if stream >= sizes.len || stream >= crcs.len { return 1; }
            if crc_defined[stream] == 0 { return 2; }
            let n = sizes[stream];
            entries[i].size = unpacked[stream]; entries[i].packed = n; entries[i].method = methods[stream]; entries[i].offset = position; entries[i].crc = crcs[stream]; entries[i].flags |= 4;
            if packed_defined.len > 0 && packed_defined[stream] != 0 && packed_crcs[stream] != garchive::crc32(data[(position as i64)..(position + n) as i64]) { return 1; }
            position += n; stream++;
        }
    }
    if stream != sizes.len || position != 32 + offset { return 1; }
    return validate(entries, names);
}

fn test(data: const u8[:], entries: const Entry[:]) -> bool {
    for e in entries {
        if e.size == 0 { if e.packed != 0 || e.method != 0 { return false; } continue; }
        if (e.flags & 4) == 0 || e.size > MAX_DATA || e.offset > data.len as u64 || e.packed > data.len as u64 - e.offset { return false; }
        if e.method == 0 {
            if e.packed != e.size || garchive::crc32(data[(e.offset as i64)..(e.offset + e.size) as i64]) != e.crc { return false; }
        } else {
            var decoded: u8[>..] = [];
            if !unpack(data, e, decoded) { return false; }
        }
    }
    return true;
}
