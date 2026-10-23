/* SPDX-License-Identifier: MIT
 * Independent C implementation of LZ78G001 for measurement, not the library API.
 * Hash/load/growth/reset rules follow the Goose dictionary used by the codec.
 */
#define _CRT_SECURE_NO_WARNINGS
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <windows.h>

#define MAX_BYTES (64u * 1024u * 1024u)
#define MAX_PHRASES 65535u
#ifndef CLASSIC_DEFAULT
#define CLASSIC_DEFAULT 0
#endif
typedef struct { uint8_t *data; size_t len, cap; } Buffer;
typedef struct { uint64_t key; uint32_t value, tag; } Slot;
typedef struct { Slot *slots; size_t cap, count; } Dict;
#pragma pack(push, 1)
typedef struct { uint32_t start; uint16_t length; } Range;
typedef struct { uint32_t parent; uint8_t symbol; uint64_t length; } Phrase;
#pragma pack(pop)
_Static_assert(sizeof(Slot) == 16, "slot layout");
_Static_assert(sizeof(Range) == 6, "range layout");
_Static_assert(sizeof(Phrase) == 13, "phrase layout");

static int reserve(Buffer *b, size_t need) {
    if (need <= b->cap) return 1;
    size_t cap = b->cap ? b->cap : 256;
    while (cap < need) { if (cap > SIZE_MAX / 2) return 0; cap *= 2; }
    void *p = realloc(b->data, cap); if (!p) return 0;
    b->data = p; b->cap = cap; return 1;
}
static int push(Buffer *b, uint8_t x) {
    if (!reserve(b, b->len + 1)) return 0;
    b->data[b->len++] = x; return 1;
}
static uint32_t checksum(const uint8_t *p, size_t n) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 16777619u;
    return h;
}
static int put_le(Buffer *b, uint64_t value, unsigned width) {
    for (unsigned i = 0; i < width; i++, value >>= 8) if (!push(b, (uint8_t)value)) return 0;
    return 1;
}
static uint64_t get_le(const uint8_t *p, unsigned width) {
    uint64_t x = 0;
    for (unsigned i = 0; i < width; i++) x |= (uint64_t)p[i] << (8 * i);
    return x;
}
static int put_tag(Buffer *b, uint32_t x) {
    while (x >= 128) { if (!push(b, (uint8_t)((x & 127) | 128))) return 0; x >>= 7; }
    return push(b, (uint8_t)x);
}
static int get_tag(const uint8_t *p, size_t n, size_t *at, uint32_t *value) {
    uint32_t x = 0;
    for (unsigned i = 0; i < 3; i++) {
        if (*at >= n) return 0;
        uint8_t b = p[(*at)++];
        if (i == 2 && b > 7) return 0;
        x |= (uint32_t)(b & 127) << (7 * i);
        if (b < 128) { if (i && b == 0) return 0; *value = x; return 1; }
    }
    return 0;
}
static uint64_t hash_key(uint64_t key) {
    uint64_t h = key * UINT64_C(11400714819323198485); return h ^ (h >> 32);
}
static int dict_grow(Dict *d, size_t cap) {
    size_t old = d->cap;
    Slot *p = realloc(d->slots, cap * sizeof(Slot)); if (!p) return 0;
    d->slots = p; memset(p + old, 0, (cap - old) * sizeof(Slot)); d->cap = cap;
    if (!d->count) return 1;
    size_t s = 0, mask = cap - 1;
    while (p[s].tag) s++;
    for (size_t k = 1; k < old; k++) {
        size_t from = s + k; if (from >= old) from -= old;
        uint32_t tag = p[from].tag;
        if (tag) {
            size_t to = tag & mask; Slot entry = p[from]; p[from].tag = 0;
            while (p[to].tag) to = (to + 1) & mask;
            p[to] = entry;
        }
    }
    return 1;
}
static uint32_t dict_get(const Dict *d, uint64_t key) {
    if (!d->count) return 0;
    uint64_t h = hash_key(key); uint32_t tag = (uint32_t)h | 0x80000000u;
    size_t at = (size_t)h & (d->cap - 1);
    for (;;) {
        if (!d->slots[at].tag) return 0;
        if (d->slots[at].tag == tag && d->slots[at].key == key) return d->slots[at].value;
        at = (at + 1) & (d->cap - 1);
    }
}
static int dict_insert(Dict *d, uint64_t key, uint32_t value) {
    if (!d->cap) { if (!dict_grow(d, 8)) return 0; }
    else if ((d->count + 1) * 3 > d->cap * 2) { if (!dict_grow(d, d->cap * 2)) return 0; }
    uint64_t h = hash_key(key); uint32_t tag = (uint32_t)h | 0x80000000u;
    size_t at = (size_t)h & (d->cap - 1);
    while (d->slots[at].tag && !(d->slots[at].tag == tag && d->slots[at].key == key)) at = (at + 1) & (d->cap - 1);
    if (!d->slots[at].tag) d->count++;
    d->slots[at] = (Slot){key, value, tag}; return 1;
}
static int compress_data(const uint8_t *p, size_t n, Buffer *out) {
    if (out->len || n > MAX_BYTES) return 0;
    if (!reserve(out, n + 20)) return 0;
    memcpy(out->data, "LZ78G001", 8); out->len = 8;
    if (!put_le(out, n, 8) || !put_le(out, checksum(p, n), 4)) return 0;
    Dict d = {0}; uint32_t next = 1, prefix = 0; int ok = 0;
    for (size_t i = 0; i < n; i++) {
        uint64_t key = ((uint64_t)prefix << 8) | p[i]; uint32_t found = dict_get(&d, key);
        if (found) { prefix = found; continue; }
        if (!put_tag(out, (prefix << 1) | 1) || !push(out, p[i]) || !dict_insert(&d, key, next)) goto done;
        next++; prefix = 0;
        if (next > MAX_PHRASES) {
            for (size_t k = 0; k < d.cap; k++) d.slots[k].tag = 0;
            d.count = 0; next = 1;
        }
    }
    if (prefix && !put_tag(out, prefix << 1)) goto done;
    ok = 1;
done:
    free(d.slots); return ok;
}
static int decompress_data(const uint8_t *p, size_t n, Buffer *out, int classic) {
    if (out->len || n < 20 || memcmp(p, "LZ78G001", 8)) return 0;
    uint64_t raw_size = get_le(p + 8, 8); if (raw_size > MAX_BYTES) return 0;
    size_t expected = (size_t)raw_size, at = 20, count = 1;
    uint32_t sum = (uint32_t)get_le(p + 16, 4); int ok = 0;
    if (!reserve(out, expected)) return 0;
    Range *ranges = classic ? NULL : malloc((MAX_PHRASES + 1) * sizeof(Range));
    Phrase *parents = classic ? malloc((MAX_PHRASES + 1) * sizeof(Phrase)) : NULL;
    uint8_t *scratch = classic ? malloc(MAX_PHRASES + 1) : NULL;
    if ((classic && (!parents || !scratch)) || (!classic && !ranges)) goto done;
    if (classic) parents[0] = (Phrase){0,0,0}; else ranges[0] = (Range){0,0};
    while (at < n) {
        uint32_t tag; if (!get_tag(p,n,&at,&tag)) goto done;
        size_t index = tag >> 1; int has_byte = tag & 1;
        if (index >= count || (!has_byte && (!index || at != n)) || (has_byte && at == n)) goto done;
        size_t length = classic ? (size_t)parents[index].length : ranges[index].length;
        if (length + has_byte > expected - out->len) goto done;
        size_t start = out->len;
        if (classic) {
            size_t node = index, used = 0;
            while (node) { scratch[used++] = parents[node].symbol; node = parents[node].parent; }
            while (used) out->data[out->len++] = scratch[--used];
        } else {
            if (length) memcpy(out->data + out->len, out->data + ranges[index].start, length);
            out->len += length;
        }
        if (has_byte) {
            uint8_t symbol = p[at++]; out->data[out->len++] = symbol;
            if (classic) parents[count] = (Phrase){(uint32_t)index,symbol,length+1};
            else ranges[count] = (Range){(uint32_t)start,(uint16_t)(length+1)};
            if (++count > MAX_PHRASES) count = 1;
        }
    }
    ok = out->len == expected && checksum(out->data,out->len) == sum;
done:
    free(ranges); free(parents); free(scratch); return ok;
}
static int load(const char *path, Buffer *out) {
    FILE *f = fopen(path,"rb"); if (!f) return 0;
    if (fseek(f,0,SEEK_END)) { fclose(f); return 0; }
    long length = ftell(f); if (length < 0 || fseek(f,0,SEEK_SET) || !reserve(out,(size_t)length)) { fclose(f); return 0; }
    out->len = fread(out->data,1,(size_t)length,f); fclose(f); return out->len == (size_t)length;
}
int main(int argc, char **argv) {
    int bench = argc == 5 && !strcmp(argv[1],"--bench");
    if ((!bench && argc != 4) || (bench && atoi(argv[4]) < 1)) return 2;
    const char *mode = argv[bench ? 2 : 1], *input = argv[bench ? 3 : 2];
    if (strcmp(mode,"c") && strcmp(mode,"d") && strcmp(mode,"p")) return 2;
    Buffer data = {0}; if (!load(input,&data)) return 1;
    int rounds = bench ? atoi(argv[4]) : 1, status = 0;
    LARGE_INTEGER freq; QueryPerformanceFrequency(&freq);
    for (int i = 0; i < rounds; i++) {
        Buffer out = {0}; LARGE_INTEGER start,end; QueryPerformanceCounter(&start);
        int ok = !strcmp(mode,"c") ? compress_data(data.data,data.len,&out) : decompress_data(data.data,data.len,&out,CLASSIC_DEFAULT || !strcmp(mode,"p"));
        QueryPerformanceCounter(&end);
        if (!ok) { free(out.data); status = 1; break; }
        if (bench) {
            unsigned long long ns = (unsigned long long)((end.QuadPart-start.QuadPart)*1000000000/freq.QuadPart);
            printf("BENCH %llu %zu %u\n",ns,out.len,checksum(out.data,out.len));
        } else {
            FILE *f = fopen(argv[3],"wb");
            if (!f) status = 1;
            else { if (fwrite(out.data,1,out.len,f) != out.len) status = 1; if (fclose(f)) status = 1; }
        }
        free(out.data);
    }
    free(data.data); return status;
}
