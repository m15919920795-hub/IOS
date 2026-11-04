#include "GXVPWire.h"
#include <string.h>

static uint16_t read16(const uint8_t *p) { return (uint16_t)((uint16_t)p[0] << 8 | p[1]); }
static uint32_t read32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
static void write32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v;
}
static bool isCommand(uint8_t command) { return command >= GXVPStart && command <= GXVPGetStatus; }

bool GXVPReadHeader(const uint8_t *p, size_t count, GXVPMessageHeader *h) {
    if (!p || !h || count != GXVPHeaderSize || memcmp(p, "GXVP", 4) ||
        p[4] != 1 || read16(p + 8) != GXVPHeaderSize || read16(p + 10) != 0) return false;
    GXVPMessageHeader value = {0};
    value.type = p[5]; value.flags = read16(p + 6); value.payloadLength = read32(p + 12);
    value.streamID = read32(p + 16); value.sequenceID = read32(p + 20);
    value.timestampUs = (uint64_t)read32(p + 24) << 32 | read32(p + 28);
    if (value.flags & ~3U) return false;
    switch (value.type) {
        case GXVPConfig:
            if (value.payloadLength != 16 || !value.streamID || value.sequenceID ||
                value.flags || value.timestampUs) return false;
            break;
        case GXVPReply:
            if (value.payloadLength != 8 || !value.sequenceID || value.flags || value.timestampUs) return false;
            break;
        case GXVPFrame:
            if (!value.streamID || !value.payloadLength || value.payloadLength > GXVPMaximumFrameSize) return false;
            break;
        default: return false;
    }
    *h = value;
    return true;
}

bool GXVPReadConfig(const uint8_t *p, size_t count, GXVPVideoConfig *c) {
    if (!p || !c || count != 16) return false;
    GXVPVideoConfig v = {read16(p), read16(p + 2), read16(p + 4), read16(p + 6),
                         read32(p + 8), read16(p + 12), p[14], p[15]};
    if (v.codec != 1 || v.timestampKind != 1 || v.fpsDenominator != 1 || !v.bitrate || !v.gop ||
        !((v.width == 1280 && v.height == 720 && v.fpsNumerator == 25) ||
          (v.width == 1920 && v.height == 1080 && v.fpsNumerator == 20))) return false;
    *c = v;
    return true;
}

bool GXVPReadReply(const uint8_t *p, size_t count, GXVPCommandReply *r) {
    if (!p || !r || count != 8 || !isCommand(p[0]) || p[1] > 6 || p[2] > GXVPStopping || p[3] > 2) return false;
    GXVPCommandReply v = {p[0], p[1], p[2], p[3], 0};
    uint32_t raw = read32(p + 4);
    v.detail = raw <= INT32_MAX ? (int32_t)raw : (int32_t)((int64_t)raw - 4294967296LL);
    *r = v;
    return true;
}

size_t GXVPWriteCommand(uint8_t *p, size_t capacity, uint8_t command, uint32_t seq, uint8_t profile) {
    size_t length = GXVPHeaderSize + (command == GXVPStart ? 4U : 0U);
    if (!p || capacity < length || !seq || !isCommand(command) ||
        (command == GXVPStart ? (profile != 1 && profile != 2) : profile != 0)) return 0;
    memset(p, 0, length); memcpy(p, "GXVP", 4); p[4] = 1; p[5] = command; p[9] = GXVPHeaderSize;
    write32(p + 12, (uint32_t)(length - GXVPHeaderSize)); write32(p + 20, seq);
    if (command == GXVPStart) { p[32] = profile; p[33] = 1; }
    return length;
}

static bool startCode(const uint8_t *p, size_t n, size_t from, size_t *position, size_t *length) {
    for (size_t i = from; i + 2 < n; i++) {
        if (p[i] || p[i + 1]) continue;
        if (p[i + 2] == 1) { *position = i; *length = 3; return true; }
        if (i + 3 < n && !p[i + 2] && p[i + 3] == 1) { *position = i; *length = 4; return true; }
    }
    return false;
}

bool GXH264VisitAnnexB(const uint8_t *p, size_t n, GXH264NALVisitor visitor, void *context, uint32_t *mask) {
    if (mask) *mask = 0;
    if (!p || n < 4 || n > GXVPMaximumFrameSize) return false;
    size_t pos = 0, prefix = 0;
    if (!startCode(p, n, 0, &pos, &prefix)) return false;
    for (size_t i = 0; i < pos; i++) if (p[i]) return false;
    uint32_t types = 0;
    unsigned units = 0;
    for (;;) {
        size_t begin = pos + prefix, next = 0, nextPrefix = 0;
        bool more = startCode(p, n, begin, &next, &nextPrefix);
        size_t end = more ? next : n;
        while (end > begin && p[end - 1] == 0) end--;
        if (begin >= end || (p[begin] & 0x80) || ++units > 256) return false;
        uint8_t type = p[begin] & 31;
        if (!type || type >= 24) return false;
        types |= 1U << type;
        if (visitor && !visitor(p + begin, end - begin, type, context)) return false;
        if (!more) break;
        pos = next; prefix = nextPrefix;
    }
    if (mask) *mask = types;
    return true;
}
