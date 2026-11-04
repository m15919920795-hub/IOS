#import "GXH264Decoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>

@interface GXH264Decoder () {
    VTDecompressionSessionRef _session;
    CMVideoFormatDescriptionRef _format;
    NSData *_sps, *_pps;
    GXDecodedImageHandler _output;
}
@end

typedef struct {
    __unsafe_unretained GXH264Decoder *decoder;
    uint64_t generation;
    CFTimeInterval arrival;
    OSStatus status;
    BOOL delivered;
} GXDecodeContext;

@interface GXH264Decoder (Output)
- (void)outputImage:(CVPixelBufferRef)image context:(GXDecodeContext *)context;
@end

static void decoded(void *reference, void *frameReference, OSStatus status,
                    VTDecodeInfoFlags flags, CVImageBufferRef image, CMTime pts, CMTime duration) {
    (void)reference; (void)pts; (void)duration;
    GXDecodeContext *context = frameReference;
    context->status = status;
    if (status == noErr && image && !(flags & kVTDecodeInfo_FrameDropped)) {
        context->delivered = YES;
        [context->decoder outputImage:image context:context];
    }
}

@interface GXNALCollection : NSObject
@property (nonatomic, strong, nullable) NSData *sps;
@property (nonatomic, strong, nullable) NSData *pps;
@property (nonatomic, strong) NSMutableData *avcc;
@end
@implementation GXNALCollection
@end

static bool collectNAL(const uint8_t *p, size_t n, uint8_t type, void *reference) {
    GXNALCollection *collection = (__bridge GXNALCollection *)reference;
    if (type == 7) collection.sps = [NSData dataWithBytes:p length:n];
    else if (type == 8) collection.pps = [NSData dataWithBytes:p length:n];
    else {
        uint32_t length = (uint32_t)n;
        uint8_t prefix[4] = {(uint8_t)(length >> 24), (uint8_t)(length >> 16),
                             (uint8_t)(length >> 8), (uint8_t)length};
        [collection.avcc appendBytes:prefix length:4];
        [collection.avcc appendBytes:p length:n];
    }
    return true;
}

@implementation GXH264Decoder
- (instancetype)initWithOutput:(GXDecodedImageHandler)output {
    if ((self = [super init])) _output = [output copy];
    return self;
}
- (void)dealloc { [self reset]; }
- (void)reset {
    if (_session) { VTDecompressionSessionInvalidate(_session); CFRelease(_session); _session = NULL; }
    if (_format) { CFRelease(_format); _format = NULL; }
    _sps = nil; _pps = nil; _usingHardwareDecoder = NO;
}
- (void)outputImage:(CVPixelBufferRef)image context:(GXDecodeContext *)context {
    // The consumer must retain the image before returning. No image is copied on the CPU.
    _output(image, context->generation, context->arrival);
}
- (BOOL)fail:(NSError **)error code:(NSInteger)code message:(NSString *)message {
    if (error) *error = [NSError errorWithDomain:@"GXHardwareDecoder" code:code
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}
- (BOOL)createSession:(GXVPVideoConfig)config error:(NSError **)error {
    const uint8_t *sets[] = {_sps.bytes, _pps.bytes};
    const size_t lengths[] = {_sps.length, _pps.length};
    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault, 2, sets, lengths, 4, &_format);
    if (status != noErr) return [self fail:error code:status message:
        [NSString stringWithFormat:@"SPS/PPS 无法建立 H.264 格式（%d）", (int)status]];
    // 1080p may have a 1088-line coded surface. Compare the clean aperture, not padded macroblocks.
    CGSize dimensions = CMVideoFormatDescriptionGetPresentationDimensions(_format, false, true);
    if (dimensions.width != config.width || dimensions.height != config.height)
        return [self fail:error code:-1 message:@"SPS 分辨率与 VIDEO_CONFIG 不一致"];

    NSDictionary *specification = @{
        (__bridge NSString *)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES
    };
    NSDictionary *attributes = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    VTDecompressionOutputCallbackRecord callback = {decoded, NULL};
    status = VTDecompressionSessionCreate(kCFAllocatorDefault, _format,
        (__bridge CFDictionaryRef)specification, (__bridge CFDictionaryRef)attributes, &callback, &_session);
    if (status != noErr) return [self fail:error code:status message:
        [NSString stringWithFormat:@"无法创建 H.264 硬解码器（%d）。请用真机，并检查码流的 SPS/profile/level。", (int)status]];
    VTSessionSetProperty(_session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    CFTypeRef hardware = NULL;
    status = VTSessionCopyProperty(_session, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                  kCFAllocatorDefault, &hardware);
    _usingHardwareDecoder = status == noErr && hardware && CFEqual(hardware, kCFBooleanTrue);
    if (hardware) CFRelease(hardware);
    if (!_usingHardwareDecoder) return [self fail:error code:status ?: -2
        message:@"系统未确认使用硬件解码，已停止播放；请使用支持 H.264 的 iPhone 真机。"];
    return YES;
}
- (BOOL)decodeAnnexB:(NSData *)data config:(GXVPVideoConfig)config
        timestampUs:(uint64_t)timestamp generation:(uint64_t)generation
        arrivalTime:(CFTimeInterval)arrival error:(NSError **)error fatal:(BOOL *)fatal {
    *fatal = NO;
    GXNALCollection *collection = [GXNALCollection new];
    collection.avcc = [NSMutableData dataWithCapacity:data.length];
    uint32_t mask = 0;
    if (!GXH264VisitAnnexB(data.bytes, data.length, collectNAL, (__bridge void *)collection, &mask) ||
        !(mask & ((1U << 1) | (1U << 5))))
        return [self fail:error code:-3 message:@"视频帧不是有效的 Annex-B H.264 访问单元"];
    BOOL key = (mask & (1U << 5)) != 0;
    if ((collection.sps && ![collection.sps isEqualToData:_sps]) ||
        (collection.pps && ![collection.pps isEqualToData:_pps])) {
        NSData *sps = collection.sps ?: _sps;
        NSData *pps = collection.pps ?: _pps;
        [self reset]; _sps = sps; _pps = pps;
    }
    if (!_session) {
        if (!key || !_sps || !_pps) return [self fail:error code:-4 message:@"等待包含 SPS/PPS 的 IDR 帧"];
        if (![self createSession:config error:error]) { *fatal = YES; [self reset]; return NO; }
    }

    CMBlockBufferRef block = NULL;
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, collection.avcc.length,
        kCFAllocatorDefault, NULL, 0, collection.avcc.length, 0, &block);
    if (status == noErr) status = CMBlockBufferReplaceDataBytes(collection.avcc.bytes, block, 0, collection.avcc.length);
    // No B frames: decode in arrival order, no temporal reordering and no playback clock queue.
    CMSampleTimingInfo timing = {CMTimeMake(config.fpsDenominator, config.fpsNumerator),
                                CMTimeMake((int64_t)timestamp, 1000000), kCMTimeInvalid};
    size_t size = collection.avcc.length;
    if (status == noErr) status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _format,
                                                         1, 1, &timing, 1, &size, &sample);
    GXDecodeContext context = {self, generation, arrival, noErr, NO};
    VTDecodeInfoFlags info = 0;
    if (status == noErr) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
        if (attachments && CFArrayGetCount(attachments)) {
            CFMutableDictionaryRef item = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(item, kCMSampleAttachmentKey_NotSync, key ? kCFBooleanFalse : kCFBooleanTrue);
        }
        // Both asynchronous and temporal processing flags are CLEAR. Apple guarantees the callback
        // finishes before this returns, so the stack context is safe and in-flight frames are bounded to one.
        status = VTDecompressionSessionDecodeFrame(_session, sample, 0, &context, &info);
    }
    if (sample) CFRelease(sample);
    if (block) CFRelease(block);
    if (status == noErr && context.status != noErr) status = context.status;
    if (status != noErr || !context.delivered) {
        [self reset];
        return [self fail:error code:status ?: -5 message:
            [NSString stringWithFormat:@"H.264 硬解失败（%d），请求 IDR 恢复", (int)status]];
    }
    return YES;
}
@end
