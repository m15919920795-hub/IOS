#include "video_protocol.h"
#include "stream_config.h"
#include <string.h>

uint16_t gx_u16(const uint8_t *p) { return ((uint16_t)p[0] << 8) | p[1]; }
uint32_t gx_u32(const uint8_t *p) {
    return ((uint32_t)p[0]<<24) | ((uint32_t)p[1]<<16) | ((uint32_t)p[2]<<8) | p[3];
}
void gx_put16(uint8_t *p, uint16_t v) { p[0]=v>>8; p[1]=v; }
void gx_put32(uint8_t *p, uint32_t v) {
    p[0]=v>>24; p[1]=v>>16; p[2]=v>>8; p[3]=v;
}
void gx_pack(uint8_t p[GX_HEADER_SIZE], const gx_header_t *h) {
    memset(p,0,GX_HEADER_SIZE); memcpy(p,"GXVP",4);
    p[4]=1; p[5]=h->type; gx_put16(p+6,h->flags); gx_put16(p+8,GX_HEADER_SIZE);
    gx_put32(p+12,h->length); gx_put32(p+16,h->stream); gx_put32(p+20,h->sequence);
    gx_put32(p+24,(uint32_t)(h->timestamp_us>>32)); gx_put32(p+28,(uint32_t)h->timestamp_us);
}
int gx_unpack(gx_header_t *h, const uint8_t p[GX_HEADER_SIZE]) {
    if (memcmp(p,"GXVP",4) || p[4]!=1 || gx_u16(p+8)!=GX_HEADER_SIZE || gx_u16(p+10)) return -1;
    h->type=p[5]; h->flags=gx_u16(p+6); h->length=gx_u32(p+12);
    h->stream=gx_u32(p+16); h->sequence=gx_u32(p+20);
    h->timestamp_us=((uint64_t)gx_u32(p+24)<<32) | gx_u32(p+28);
    return 0;
}
const gx_profile_t *gx_profile(uint8_t id) {
    static const gx_profile_t modes[]={
        {1,1280,720,25,25,STREAM_BITRATE}, {2,1920,1080,20,20,STREAM_BITRATE}
    };
    return id==1 ? &modes[0] : id==2 ? &modes[1] : NULL;
}
void gx_config_payload(uint8_t out[16], const gx_profile_t *p) {
    gx_put16(out,p->width); gx_put16(out+2,p->height); gx_put16(out+4,p->fps); gx_put16(out+6,1);
    gx_put32(out+8,p->bitrate); gx_put16(out+12,p->gop); out[14]=1; out[15]=1;
}
uint32_t gx_nal_types(const void *data, uint32_t size) {
    const uint8_t *p=data; uint32_t types=0;
    for (uint32_t i=0;i+3<size;i++) if (!p[i] && !p[i+1]) {
        if (p[i+2]==1) types |= 1U << (p[i+3]&31);
        else if (i+4<size && !p[i+2] && p[i+3]==1) types |= 1U << (p[i+4]&31);
    }
    return types;
}
