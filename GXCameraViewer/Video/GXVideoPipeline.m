#import "GXVideoPipeline.h"
#import "GXH264Decoder.h"
#import "GXVideoView.h"
#import <QuartzCore/QuartzCore.h>
#include <float.h>

@interface GXVideoPacket : NSObject
@property (nonatomic, strong) NSData *body;
@property (nonatomic) GXVPMessageHeader header;
@property (nonatomic) GXVPVideoConfig config;
@property (nonatomic) uint64_t generation;
@property (nonatomic) CFTimeInterval arrived;
@end
@implementation GXVideoPacket
@end

@interface GXVideoPipeline () {
    NSLock *_lock;
    NSMutableArray<GXVideoPacket *> *_packets;
    dispatch_queue_t _decodeQueue;
    GXH264Decoder *_decoder;
    __weak GXVideoView *_view;
    GXVPVideoConfig _config;
    uint64_t _generation, _received, _bytes, _drops, _lastTimestamp;
    uint32_t _streamID, _lastSequence;
    BOOL _configured, _workerScheduled, _needsReset, _waitingForIDR, _haveSequence, _hardware;
    double _minimumOffset, _relativeLag;
    NSUInteger _decodeFailures;
}
@end

@implementation GXVideoPipeline
- (instancetype)initWithVideoView:(GXVideoView *)view {
    if ((self = [super init])) {
        _lock = [NSLock new]; _packets = [NSMutableArray array]; _view = view;
        _decodeQueue = dispatch_queue_create("com.gx.camera.decode", DISPATCH_QUEUE_SERIAL);
        __weak GXVideoView *weakView = view;
        _decoder = [[GXH264Decoder alloc] initWithOutput:^(CVPixelBufferRef image, uint64_t generation, CFTimeInterval arrival) {
            [weakView offerPixelBuffer:image generation:generation arrivalTime:arrival];
        }];
    }
    return self;
}
/* Caller holds _lock. One work item drains the bounded queue, rather than dispatching one block per frame. */
- (void)scheduleWorkerLocked {
    if (_workerScheduled) return;
    _workerScheduled = YES;
    dispatch_async(_decodeQueue, ^{ [self drain]; });
}
- (void)configure:(GXVPVideoConfig)config streamID:(uint32_t)streamID {
    [_lock lock];
    _generation++; _config = config; _streamID = streamID; _configured = YES;
    _haveSequence = NO; _waitingForIDR = YES; _needsReset = YES; _hardware = NO;
    _received = _bytes = _drops = _lastTimestamp = 0; _decodeFailures = 0;
    _minimumOffset = DBL_MAX; _relativeLag = 0; [_packets removeAllObjects];
    uint64_t generation = _generation;
    [_view beginGeneration:generation];
    [self scheduleWorkerLocked]; [_lock unlock];
}
- (void)stop {
    [_lock lock];
    _configured = NO; _streamID = 0; _generation++; _needsReset = YES; _hardware = NO;
    [_packets removeAllObjects]; [_view beginGeneration:_generation];
    [self scheduleWorkerLocked]; [_lock unlock];
}
- (void)recoverLocked {
    _drops += _packets.count; [_packets removeAllObjects];
    _waitingForIDR = YES; _needsReset = YES;
}
- (BOOL)receiveFrame:(NSData *)body header:(GXVPMessageHeader)header error:(NSError **)error {
    uint32_t mask = 0;
    BOOL key = (header.flags & GXVPKeyFrame) != 0;
    if (!GXH264VisitAnnexB(body.bytes, body.length, NULL, NULL, &mask) ||
        !(mask & ((1U << 1) | (1U << 5))) || key != ((mask & (1U << 5)) != 0) ||
        (key && (mask & 0x1a0) != 0x1a0) || header.timestampUs > INT64_MAX) {
        if (error) *error = [NSError errorWithDomain:@"GXVP" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"非法 H.264 帧或 IDR 缺少 SPS/PPS，连接已关闭"}];
        return NO;
    }
    CFTimeInterval now = CACurrentMediaTime();
    BOOL request = NO;
    [_lock lock];
    if (!_configured || header.streamID != _streamID) { [_lock unlock]; return YES; }
    if (_haveSequence && header.timestampUs < _lastTimestamp) {
        [_lock unlock];
        if (error) *error = [NSError errorWithDomain:@"GXVP" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"同一视频流的时间戳倒退"}];
        return NO;
    }
    _received++; _bytes += body.length;
    double offset = now * 1000.0 - header.timestampUs / 1000.0;
    _minimumOffset = MIN(_minimumOffset, offset); _relativeLag = MAX(0, offset - _minimumOffset);
    BOOL gap = _haveSequence && header.sequenceID != (uint32_t)(_lastSequence + 1U);
    _lastSequence = header.sequenceID; _lastTimestamp = header.timestampUs; _haveSequence = YES;
    if (gap || (header.flags & GXVPDiscontinuity) || _packets.count >= 3) [self recoverLocked];
    if (_relativeLag > 300.0) { [self recoverLocked]; _drops++; request = YES; }
    else if (_waitingForIDR && !key) { _drops++; request = YES; }
    else {
        GXVideoPacket *packet = [GXVideoPacket new];
        packet.body = body; packet.header = header; packet.config = _config;
        packet.generation = _generation; packet.arrived = now;
        _waitingForIDR = NO; [_packets addObject:packet]; [self scheduleWorkerLocked];
    }
    [_lock unlock];
    if (request && self.needsIDR) self.needsIDR();
    return YES;
}
- (void)drain {
    for (;;) {
        @autoreleasepool {
            [_lock lock];
            BOOL reset = _needsReset; _needsReset = NO;
            GXVideoPacket *packet = _packets.firstObject;
            if (packet) [_packets removeObjectAtIndex:0];
            if (!packet && !reset) { _workerScheduled = NO; [_lock unlock]; return; }
            BOOL current = packet && _configured && packet.generation == _generation;
            [_lock unlock];
            if (reset) [_decoder reset];
            if (!current) continue;
            if (CACurrentMediaTime() - packet.arrived > 0.2) {
                [_lock lock];
                BOOL stillCurrent = _configured && packet.generation == _generation;
                if (stillCurrent) { _drops++; [self recoverLocked]; }
                [_lock unlock];
                if (stillCurrent && self.needsIDR) self.needsIDR();
                continue;
            }
            NSError *error = nil; BOOL fatal = NO;
            BOOL ok = [_decoder decodeAnnexB:packet.body config:packet.config
                timestampUs:packet.header.timestampUs generation:packet.generation
                arrivalTime:packet.arrived error:&error fatal:&fatal];
            [_lock lock];
            current = _configured && packet.generation == _generation;
            if (current) {
                _hardware = _decoder.usingHardwareDecoder;
                if (ok) _decodeFailures = 0;
                else {
                    _drops++; _decodeFailures++; [self recoverLocked];
                    fatal = fatal || _decodeFailures >= 3;
                    if (fatal) _configured = NO;
                }
            }
            [_lock unlock];
            if (current && !ok) {
                if (fatal) { if (self.fatalError) self.fatalError(error.localizedDescription, packet.generation); }
                else {
                    if (self.logMessage) self.logMessage(error.localizedDescription);
                    if (self.needsIDR) self.needsIDR();
                }
            }
        }
    }
}
- (NSDictionary<NSString *, NSNumber *> *)statistics {
    [_lock lock];
    NSMutableDictionary *value = [@{@"received": @(_received), @"bytes": @(_bytes),
        @"dropped": @(_drops), @"queue": @(_packets.count), @"relativeLag": @(_relativeLag),
        @"hardware": @(_hardware), @"generation": @(_generation)} mutableCopy];
    [value addEntriesFromDictionary:[_view statistics] ?: @{}];
    [_lock unlock]; return value;
}
@end
