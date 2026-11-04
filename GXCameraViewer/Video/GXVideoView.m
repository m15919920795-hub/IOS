#import "GXVideoView.h"
#import <AVFoundation/AVFoundation.h>

@interface GXVideoView () {
    NSLock *_lock;
    CVPixelBufferRef _latest;
    CFTimeInterval _arrival;
    uint64_t _generation, _offered, _replaced, _displayed, _stale;
    AVSampleBufferDisplayLayer *_displayLayer;
    BOOL _drawScheduled, _inBackground, _needsLayerReset;
}
- (void)scheduleDrawLocked;
- (void)drawLatest;
@end

@implementation GXVideoView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _lock = [NSLock new]; self.backgroundColor = UIColor.blackColor;
        self.clipsToBounds = YES;
        [self replaceDisplayLayer];
        _inBackground = UIApplication.sharedApplication.applicationState == UIApplicationStateBackground;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:)
            name:UIApplicationDidEnterBackgroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(foreground:)
            name:UIApplicationWillEnterForegroundNotification object:nil];
    }
    return self;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_latest) CVPixelBufferRelease(_latest);
}
- (void)background:(NSNotification *)notification {
    (void)notification;
    [_lock lock];
    _inBackground = YES;
    if (_latest) { CVPixelBufferRelease(_latest); _latest = NULL; _stale++; }
    [_lock unlock];
}
- (void)foreground:(NSNotification *)notification {
    (void)notification;
    [_lock lock]; _inBackground = NO; [self scheduleDrawLocked]; [_lock unlock];
}
- (void)replaceDisplayLayer {
    [_displayLayer removeFromSuperlayer];
    _displayLayer = [AVSampleBufferDisplayLayer layer];
    _displayLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
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
    // Reset and submission share one main-queue task so a new frame cannot race ahead of its reset.
    _needsLayerReset = YES;
    [self scheduleDrawLocked];
    [_lock unlock];
}
- (void)offerPixelBuffer:(CVPixelBufferRef)image generation:(uint64_t)generation arrivalTime:(CFTimeInterval)arrival {
    [_lock lock];
    if (generation == _generation) {
        _offered++;
        if (_inBackground) { _stale++; [_lock unlock]; return; }
        if (_latest) { CVPixelBufferRelease(_latest); _replaced++; }
        _latest = CVPixelBufferRetain(image); _arrival = arrival;
        [self scheduleDrawLocked];
    }
    [_lock unlock];
}
// Caller holds _lock. Wake the main queue immediately, without waiting for a refresh callback.
// At most one task is queued; newer decoded frames replace the pending image if the main thread is busy.
- (void)scheduleDrawLocked {
    if (_drawScheduled || (!_needsLayerReset && (_inBackground || !_latest))) return;
    _drawScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [self drawLatest]; });
}
- (NSDictionary<NSString *, NSNumber *> *)statistics {
    [_lock lock];
    NSDictionary *value = @{@"decoded": @(_offered), @"displayed": @(_displayed),
                           @"replaced": @(_replaced), @"displayStale": @(_stale)};
    [_lock unlock]; return value;
}
- (void)drawLatest {
    [_lock lock];
    _drawScheduled = NO;
    if (_needsLayerReset) { [self replaceDisplayLayer]; _needsLayerReset = NO; }
    CVPixelBufferRef image = _inBackground ? NULL : _latest;
    if (image) _latest = NULL;
    uint64_t generation = _generation; CFTimeInterval arrival = _arrival;
    [_lock unlock];
    if (!image) return;
    if (CACurrentMediaTime() - arrival > 0.2) {
        CVPixelBufferRelease(image);
        [_lock lock]; if (generation == _generation) _stale++; [_lock unlock]; return;
    }
    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, image, &format);
    CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000), kCMTimeInvalid};
    if (status == noErr) status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, image, format, &timing, &sample);
    CVPixelBufferRelease(image);
    if (format) CFRelease(format);
    if (status != noErr) {
        [_lock lock]; if (generation == _generation) _stale++; [_lock unlock]; return;
    }
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
    if (attachments && CFArrayGetCount(attachments)) {
        CFMutableDictionaryRef item = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(item, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }
    // Keep validation and enqueue atomic with STOP/reconnect generation changes.
    [_lock lock];
    BOOL current = generation == _generation && !_needsLayerReset && !_inBackground;
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
    if (generation == _generation) { if (enqueued) _displayed++; else _stale++; }
    [_lock unlock];
    CFRelease(sample);
}
@end
