#pragma once
#include <stdint.h>
#include <stddef.h>

#define GX_HEADER_SIZE 32
#define GX_MAX_COMMAND 16
#define GX_CONFIG 0x01
#define GX_FRAME 0x02
#define GX_REPLY 0x03
#define GX_START 0x10
#define GX_STOP 0x11
#define GX_IDR 0x12
#define GX_STATUS 0x13
#define GX_KEY 1
#define GX_DISCONTINUITY 2
enum { GX_IDLE, GX_STARTING, GX_RUNNING, GX_STOPPING };
enum { GX_OK, GX_BUSY, GX_ALREADY_RUNNING, GX_BAD_PARAMETER,
       GX_UNSUPPORTED, GX_START_FAILED, GX_REQUEST_CONFLICT };

typedef struct {
    uint8_t type;
    uint16_t flags;
    uint32_t length, stream, sequence;
    uint64_t timestamp_us;
} gx_header_t;
typedef struct {
    uint8_t id;
    uint16_t width, height, fps, gop;
    uint32_t bitrate;
} gx_profile_t;
uint16_t gx_u16(const uint8_t *p);
uint32_t gx_u32(const uint8_t *p);
void gx_put16(uint8_t *p, uint16_t v);
void gx_put32(uint8_t *p, uint32_t v);
void gx_pack(uint8_t out[GX_HEADER_SIZE], const gx_header_t *h);
int gx_unpack(gx_header_t *h, const uint8_t in[GX_HEADER_SIZE]);
const gx_profile_t *gx_profile(uint8_t id);
void gx_config_payload(uint8_t out[16], const gx_profile_t *p);
uint32_t gx_nal_types(const void *data, uint32_t length);
