#import "GXVideoView.h"
#import <AVFoundation/AVFoundation.h>

@class GXDisplayLinkProxy;
@interface GXVideoView () {
    NSLock *_lock;
    CVPixelBufferRef _latest;
    CFTimeInterval _arrival;
    uint64_t _generation, _offered, _replaced, _displayed, _stale;
    AVSampleBufferDisplayLayer *_displayLayer;
    CADisplayLink *_displayLink;
}
- (void)drawLatest;
@end
@interface GXDisplayLinkProxy : NSObject
@property (nonatomic, weak) GXVideoView *view;
- (void)tick:(CADisplayLink *)link;
@end
@implementation GXDisplayLinkProxy
- (void)tick:(CADisplayLink *)link { (void)link; [self.view drawLatest]; }
@end

@implementation GXVideoView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _lock = [NSLock new]; self.backgroundColor = UIColor.blackColor;
        self.clipsToBounds = YES; self.layer.cornerRadius = 12;
        [self replaceDisplayLayer];
        GXDisplayLinkProxy *proxy = [GXDisplayLinkProxy new]; proxy.view = self;
        _displayLink = [CADisplayLink displayLinkWithTarget:proxy selector:@selector(tick:)];
        [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:)
            name:UIApplicationDidEnterBackgroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(foreground:)
            name:UIApplicationWillEnterForegroundNotification object:nil];
    }
    return self;
}
- (void)dealloc {
    [_displayLink invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_latest) CVPixelBufferRelease(_latest);
}
- (void)background:(NSNotification *)notification { (void)notification; _displayLink.paused = YES; }
- (void)foreground:(NSNotification *)notification { (void)notification; _displayLink.paused = NO; }
- (void)replaceDisplayLayer {
    [_displayLayer removeFromSuperlayer];
    _displayLayer = [AVSampleBufferDisplayLayer layer];
    _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    _displayLayer.frame = self.bounds;
    [self.layer addSublayer:_displayLayer];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _displayLayer.frame = self.bounds; [CATransaction commit];
}
- (void)beginGeneration:(uint64_t)generation {
    [_lock lock];
    _generation = generation;
    if (_latest) { CVPixelBufferRelease(_latest); _latest = NULL; }
    _offered = _replaced = _displayed = _stale = 0;
    [_lock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_lock lock]; BOOL current = generation == self->_generation; [self->_lock unlock];
        if (current) [self replaceDisplayLayer];
    });
}
- (void)offerPixelBuffer:(CVPixelBufferRef)image generation:(uint64_t)generation arrivalTime:(CFTimeInterval)arrival {
    [_lock lock];
    if (generation == _generation) {
        _offered++;
        if (_latest) { CVPixelBufferRelease(_latest); _replaced++; }
        _latest = CVPixelBufferRetain(image); _arrival = arrival;
    }
    [_lock unlock];
}
- (NSDictionary<NSString *, NSNumber *> *)statistics {
    [_lock lock];
    NSDictionary *value = @{@"decoded": @(_offered), @"displayed": @(_displayed),
                           @"replaced": @(_replaced), @"displayStale": @(_stale)};
    [_lock unlock]; return value;
}
- (void)drawLatest {
    [_lock lock];
    CVPixelBufferRef image = _latest; _latest = NULL;
    uint64_t generation = _generation; CFTimeInterval arrival = _arrival;
    [_lock unlock];
    if (!image) return;
    if (CACurrentMediaTime() - arrival > 0.2) {
        CVPixelBufferRelease(image); [_lock lock]; _stale++; [_lock unlock]; return;
    }
    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, image, &format);
    CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000), kCMTimeInvalid};
    if (status == noErr) status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, image, format, &timing, &sample);
    CVPixelBufferRelease(image);
    if (format) CFRelease(format);
    if (status != noErr) return;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
    if (attachments && CFArrayGetCount(attachments)) {
        CFMutableDictionaryRef item = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(item, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }
    [_lock lock]; BOOL current = generation == _generation; [_lock unlock];
    BOOL enqueued = NO;
    if (current) {
        if (@available(iOS 17.0, *)) {
            AVSampleBufferVideoRenderer *renderer = _displayLayer.sampleBufferRenderer;
            if (renderer.status == AVQueuedSampleBufferRenderingStatusFailed) [renderer flush];
            if (renderer.readyForMoreMediaData) { [renderer enqueueSampleBuffer:sample]; enqueued = YES; }
        } else {
            if (_displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) [_displayLayer flush];
            if (_displayLayer.readyForMoreMediaData) { [_displayLayer enqueueSampleBuffer:sample]; enqueued = YES; }
        }
    }
    CFRelease(sample);
    [_lock lock];
    if (current && generation == _generation) { if (enqueued) _displayed++; else _stale++; }
    [_lock unlock];
}
@end
