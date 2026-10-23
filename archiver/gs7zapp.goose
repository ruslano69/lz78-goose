// SPDX-License-Identifier: MIT
namespace gs7zapp;
import std;
import os;
import sevenzip;
import gswinfiles;
import garchive;

struct Span { at: u32, length: u32 }

fn slice(span: Span, names: const u8[:]) -> const u8[:] {
    return names[(span.at as i64)..span.at as i64 + span.length as i64];
}

fn joined(root: const u8[:], name: const u8[:], out: u8[>..]&) {
    out.append(root);
    if name.len > 0 {
        if root[root.len - 1] != '/' { out.push('/'); }
        out.append(name);
    }
}

fn compatible(entries: const sevenzip::Entry[:], names: const u8[:]) -> bool {
    var order: u32[>..] = [];
    for i in entries.len {
        let name = sevenzip::path(entries[i], names);
        var start: i64 = 0;
        for j in name.len + 1 {
            if j < name.len && name[j] != '/' { continue; }
            if !gswinfiles::component(name[start..j]) { return false; }
            start = j + 1;
        }
        order.push(i as u32);
    }
    sort(order) { a, b => gswinfiles::compare(sevenzip::path(entries[a as i64], names), sevenzip::path(entries[b as i64], names)) < 0 }
    for i in order.len {
        let name = sevenzip::path(entries[order[i] as i64], names);
        if i > 0 && gswinfiles::compare(name, sevenzip::path(entries[order[i - 1] as i64], names)) == 0 { return false; }
        for j in name.len {
            if name[j] != '/' { continue; }
            let prefix = name[..j];
            var lo: i64 = 0; var hi = order.len;
            while lo < hi {
                let mid = lo + (hi - lo) / 2;
                if gswinfiles::compare(sevenzip::path(entries[order[mid] as i64], names), prefix) < 0 { lo = mid + 1; } else { hi = mid; }
            }
            if lo < order.len {
                let parent = entries[order[lo] as i64];
                if gswinfiles::compare(sevenzip::path(parent, names), prefix) == 0 && (parent.flags & 1) == 0 { return false; }
            }
        }
    }
    return true;
}

fn collect(root: const u8[:], entries: sevenzip::Entry[>..]&, names: u8[>..]&, contents: u8[>..]&) -> bool {
    let root_info, root_kind = gswinfiles::info(root);
    if root_kind != 2 || !gswinfiles::safe(root) { return false; }
    var pending: Span[>..] = []; pending.push(Span { 0, 0 });
    var next: i64 = 0;
    while next < pending.len {
        var relative: u8[>..] = []; relative.append(slice(pending[next], names)); next++;
        var directory: u8[>..] = []; joined(root, relative, directory);
        if !gswinfiles::safe(directory) { return false; }
        var children: u8[>..] = [];
        if !list_dir(directory, children) { return false; }
        var start: i64 = 0;
        for j in children.len {
            if children[j] != '\n' { continue; }
            let child = children[start..j]; start = j + 1;
            if !gswinfiles::component(child) { return false; }
            var name: u8[>..] = [];
            if relative.len > 0 { name.append(relative); name.push('/'); }
            name.append(child);
            if !sevenzip::valid_path(name) || entries.len >= sevenzip::MAX_FILES || name.len > sevenzip::MAX_HEADER - names.len { return false; }
            var full: u8[>..] = []; joined(root, name, full);
            let metadata, kind = gswinfiles::info(full);
            if kind != 1 && kind != 2 { return false; }
            let n = (metadata.size_high as u64 << 32) | metadata.size_low as u64;
            let time = (metadata.write_high as u64 << 32) | metadata.write_low as u64;
            let at = names.len;
            names.append(name);
            var e = sevenzip::Entry { at as u32, name.len as u32, 0, contents.len as u64, 0, time, 2, 0, 0 };
            if kind == 2 {
                e.flags |= 1; pending.push(Span { at as u32, name.len as u32 });
            } else {
                if n > sevenzip::MAX_DATA - contents.len as u64 { return false; }
                let mark = contents.len;
                if !read_file(full, contents) || (contents.len - mark) as u64 != n { return false; }
                let after, after_kind = gswinfiles::info(full);
                if after_kind != 1 || after.size_low != metadata.size_low || after.size_high != metadata.size_high || after.write_low != metadata.write_low || after.write_high != metadata.write_high { return false; }
                e.size = n; e.crc = garchive::crc32(contents[mark..]); e.flags |= 4;
            }
            entries.push(e);
        }
        if start != children.len { return false; }
    }
    let text = names[..];
    sort(entries) { a, b => sevenzip::less(sevenzip::path(a, text), sevenzip::path(b, text)) }
    return sevenzip::validate(entries, names) == 0 && compatible(entries, names);
}

fn selected(name: const u8[:], filters: const Span[:], text: const u8[:]) -> bool {
    if filters.len == 0 { return true; }
    for f in filters {
        let prefix = slice(f, text);
        if name == prefix || (name.len > prefix.len && name[..prefix.len] == prefix && name[prefix.len] == '/') { return true; }
    }
    return false;
}

fn extract(data: const u8[:], entries: const sevenzip::Entry[:], names: const u8[:], destination: const u8[:], filters: const Span[:], filter_text: const u8[:]) -> bool {
    if !sevenzip::test(data, entries) || !compatible(entries, names) { return false; }
    let root_info, root_kind = gswinfiles::info(destination);
    if root_kind != 0 || !gswinfiles::safe(destination) { return false; }
    for f in filters {
        let requested = slice(f, filter_text);
        var found = false;
        for e in entries { if selected(sevenzip::path(e, names), [f], filter_text) { found = true; break; } }
        if !found { return false; }
    }
    // Validate every planned destination before creating the destination tree.
    for e in entries {
        let name = sevenzip::path(e, names);
        if !selected(name, filters, filter_text) { continue; }
        var full: u8[>..] = []; joined(destination, name, full);
        if !gswinfiles::safe(full) { return false; }
    }
    if !gswinfiles::parents(destination) || !make_dir(destination) { return false; }
    for e in entries {
        let name = sevenzip::path(e, names);
        if !selected(name, filters, filter_text) { continue; }
        var full: u8[>..] = []; joined(destination, name, full);
        if !gswinfiles::safe(full) || !gswinfiles::parents(full) { return false; }
        let previous, kind = gswinfiles::info(full);
        if (e.flags & 1) != 0 {
            if kind == 0 { if !make_dir(full) { return false; } }
            else if kind != 2 { return false; }
        } else {
            if kind != 0 { return false; }
            if e.method == 0 {
                let bytes = if e.size == 0 { data[..0] } else { data[(e.offset as i64)..(e.offset + e.size) as i64] };
                if !write_file_atomic(full, bytes) { return false; }
            } else {
                var decoded: u8[>..] = [];
                if !sevenzip::unpack(data, e, decoded) || !write_file_atomic(full, decoded) { return false; }
            }
            if (e.flags & 2) != 0 && !gswinfiles::set_time(full, e.mtime) { return false; }
        }
    }
    for e in entries {
        let name = sevenzip::path(e, names);
        if (e.flags & 3) != 3 || !selected(name, filters, filter_text) { continue; }
        var full: u8[>..] = []; joined(destination, name, full);
        if !gswinfiles::safe(full) || !gswinfiles::set_time(full, e.mtime) { return false; }
    }
    return true;
}
