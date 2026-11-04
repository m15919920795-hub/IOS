#include "GXVPWire.h"
#include "video_protocol.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { unsigned count; uint8_t types[8]; size_t lengths[8]; } Visits;
static bool visit(const uint8_t *p, size_t n, uint8_t type, void *reference) {
    Visits *v = reference;
    assert(n && (p[0] & 31) == type && v->count < 8);
    v->types[v->count] = type; v->lengths[v->count++] = n;
    return true;
}
static bool decline(const uint8_t *p, size_t n, uint8_t type, void *reference) {
    (void)p; (void)n; (void)type; (void)reference; return false;
}
static void command_tests(void) {
    uint8_t packet[36], reference[36];
    const uint8_t golden[36] = {
        0x47,0x58,0x56,0x50,1,0x10,0,0,0,0x20,0,0,0,0,0,4,
        0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,1,1,0,0
    };
    assert(GXVPWriteCommand(packet, sizeof(packet), GXVPStart, 1, 1) == 36);
    assert(memcmp(packet, golden, 36) == 0);
    for (uint8_t mode = 1; mode <= 2; mode++) {
        gx_header_t header = {.type=GX_START, .length=4, .sequence=0x89abcdef};
        gx_pack(reference, &header); reference[32]=mode; reference[33]=1; reference[34]=reference[35]=0;
        assert(GXVPWriteCommand(packet, 36, GXVPStart, header.sequence, mode) == 36);
        assert(memcmp(packet, reference, 36) == 0);
    }
    for (uint8_t command = GXVPStop; command <= GXVPGetStatus; command++) {
        gx_header_t header = {.type=command, .sequence=UINT32_MAX}; gx_pack(reference, &header);
        assert(GXVPWriteCommand(packet, 36, command, header.sequence, 0) == 32);
        assert(memcmp(packet, reference, 32) == 0);
    }
    assert(!GXVPWriteCommand(packet, 35, GXVPStart, 1, 1));
    assert(!GXVPWriteCommand(packet, 36, GXVPStart, 0, 1));
    assert(!GXVPWriteCommand(packet, 36, GXVPStart, 1, 0));
    assert(!GXVPWriteCommand(packet, 36, GXVPStop, 1, 1));
    assert(!GXVPWriteCommand(packet, 36, 0xff, 1, 0));
}
static void header_tests(void) {
    uint8_t bytes[32]; GXVPMessageHeader parsed;
    gx_header_t header = {.type=GX_FRAME,.flags=3,.length=GXVPMaximumFrameSize,
        .stream=0x12345678,.sequence=UINT32_MAX,.timestamp_us=0x123456789abcULL};
    gx_pack(bytes, &header); assert(GXVPReadHeader(bytes, 32, &parsed));
    assert(parsed.type==header.type && parsed.flags==3 && parsed.streamID==header.stream);
    assert(parsed.sequenceID==header.sequence && parsed.timestampUs==header.timestamp_us);
    assert(parsed.payloadLength==GXVPMaximumFrameSize);
    assert(!GXVPReadHeader(bytes, 31, &parsed));
    header.length++; gx_pack(bytes,&header); assert(!GXVPReadHeader(bytes,32,&parsed));
    header.length=1; header.flags=4; gx_pack(bytes,&header); assert(!GXVPReadHeader(bytes,32,&parsed));
    header.flags=0; header.stream=0; gx_pack(bytes,&header); assert(!GXVPReadHeader(bytes,32,&parsed));
    header=(gx_header_t){.type=GX_CONFIG,.stream=1,.length=16}; gx_pack(bytes,&header);
    assert(GXVPReadHeader(bytes,32,&parsed)); bytes[10]=1; assert(!GXVPReadHeader(bytes,32,&parsed));
    gx_pack(bytes,&header); bytes[4]=2; assert(!GXVPReadHeader(bytes,32,&parsed));
    gx_pack(bytes,&header); bytes[0]='Z'; assert(!GXVPReadHeader(bytes,32,&parsed));
    header.sequence=1; gx_pack(bytes,&header); assert(!GXVPReadHeader(bytes,32,&parsed));
    header=(gx_header_t){.type=GX_REPLY,.length=8,.sequence=1}; gx_pack(bytes,&header);
    assert(GXVPReadHeader(bytes,32,&parsed)); // IDLE replies legitimately have stream=0.
    header.sequence=0; gx_pack(bytes,&header); assert(!GXVPReadHeader(bytes,32,&parsed));
    header=(gx_header_t){.type=GX_START,.length=4,.sequence=1}; gx_pack(bytes,&header);
    assert(!GXVPReadHeader(bytes,32,&parsed)); // Reject wrong-direction command messages.
}
static void payload_tests(void) {
    for (uint8_t id=1;id<=2;id++) {
        uint8_t bytes[16]; const gx_profile_t *mode=gx_profile(id); gx_config_payload(bytes,mode);
        GXVPVideoConfig config; assert(GXVPReadConfig(bytes,16,&config));
        assert(config.width==mode->width && config.height==mode->height && config.fpsNumerator==mode->fps);
        assert(config.bitrate==mode->bitrate && config.gop==mode->gop && config.codec==1);
        bytes[6]=1; assert(!GXVPReadConfig(bytes,16,&config));
        gx_config_payload(bytes,mode); bytes[14]=2; assert(!GXVPReadConfig(bytes,16,&config));
    }
    uint8_t bytes[8]={GXVPStart,5,GXVPIdle,0,0xff,0xff,0xff,0xf0}; GXVPCommandReply reply;
    assert(GXVPReadReply(bytes,8,&reply) && reply.detail==-16);
    assert(!GXVPReadReply(bytes,7,&reply)); bytes[1]=7; assert(!GXVPReadReply(bytes,8,&reply));
}
static void nal_tests(void) {
    const uint8_t frame[]={0,0,0,0,1,0x67,0x64,0,0,1,0x68,0xee,0,0,0,1,0x65,0x88,0,0};
    Visits visits={0}; uint32_t mask=0;
    assert(GXH264VisitAnnexB(frame,sizeof(frame),visit,&visits,&mask));
    assert(mask==0x1a0 && visits.count==3 && visits.types[0]==7 && visits.types[1]==8 && visits.types[2]==5);
    assert(visits.lengths[0]==2 && visits.lengths[2]==2);
    assert(!GXH264VisitAnnexB(frame,sizeof(frame),decline,NULL,&mask));
    const uint8_t bad[][8]={
        {1,0,0,1,0x65,1,0,0}, {0,0,1,0xe5,1,0,0,0}, {0,0,1,0x78,1,0,0,0},
        {0,0,1,0x65,0,0,0,1}, {0,0,1,0,0,0,0,0}
    };
    for(size_t i=0;i<sizeof(bad)/sizeof(bad[0]);i++) assert(!GXH264VisitAnnexB(bad[i],8,NULL,NULL,&mask));
    const uint8_t escaped[]={0,0,1,0x61,0x80,0,0,3,1,0x80};
    assert(GXH264VisitAnnexB(escaped,sizeof(escaped),NULL,NULL,&mask) && mask==(1U<<1));
    uint8_t *oversize=calloc(1,GXVPMaximumFrameSize+1); assert(oversize);
    assert(!GXH264VisitAnnexB(oversize,GXVPMaximumFrameSize+1,NULL,NULL,&mask)); free(oversize);
    // Exercise truncated/hostile input bounds under address/undefined-behavior sanitizers.
    uint32_t random=1234567; uint8_t data[513];
    for(unsigned round=0;round<10000;round++) {
        for(size_t i=0;i<sizeof(data);i++) { random=random*1664525U+1013904223U; data[i]=(uint8_t)(random>>24); }
        GXH264VisitAnnexB(data,round%sizeof(data),NULL,NULL,&mask);
        GXVPReadHeader(data,round%33,&(GXVPMessageHeader){0});
    }
}
int main(void) {
    command_tests(); header_tests(); payload_tests(); nal_tests();
    puts("PASS: iOS wire codec matches firmware; header/body limits, command vectors, signed errors, Annex-B and bounds tests.");
    return 0;
}
