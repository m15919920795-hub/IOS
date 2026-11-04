#ifndef GXVP_WIRE_H
#define GXVP_WIRE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { GXVPHeaderSize = 32, GXVPMaximumFrameSize = 512000 };
enum { GXVPConfig = 1, GXVPFrame = 2, GXVPReply = 3,
       GXVPStart = 0x10, GXVPStop = 0x11, GXVPRequestIDR = 0x12, GXVPGetStatus = 0x13 };
enum { GXVPKeyFrame = 1, GXVPDiscontinuity = 2 };
enum { GXVPIdle, GXVPStarting, GXVPRunning, GXVPStopping };

typedef struct {
    uint8_t type;
    uint16_t flags;
    uint32_t payloadLength, streamID, sequenceID;
    uint64_t timestampUs;
} GXVPMessageHeader;

typedef struct {
    uint16_t width, height, fpsNumerator, fpsDenominator;
    uint32_t bitrate;
    uint16_t gop;
    uint8_t codec, timestampKind;
} GXVPVideoConfig;

typedef struct {
    uint8_t command, result, state, profile;
    int32_t detail;
} GXVPCommandReply;

/* Validate a DEVICE -> CLIENT header before allocating its body. */
bool GXVPReadHeader(const uint8_t *bytes, size_t count, GXVPMessageHeader *header);
bool GXVPReadConfig(const uint8_t *bytes, size_t count, GXVPVideoConfig *config);
bool GXVPReadReply(const uint8_t *bytes, size_t count, GXVPCommandReply *reply);
/* Returns packet length, or zero for invalid arguments. Only START has a body. */
size_t GXVPWriteCommand(uint8_t *output, size_t capacity, uint8_t command,
                       uint32_t sequenceID, uint8_t profile);

/* Annex-B NAL spans exclude start codes and trailing_zero_8bits. */
typedef bool (*GXH264NALVisitor)(const uint8_t *bytes, size_t count, uint8_t type, void *context);
bool GXH264VisitAnnexB(const uint8_t *bytes, size_t count,
                      GXH264NALVisitor visitor, void *context, uint32_t *nalMask);
#endif
