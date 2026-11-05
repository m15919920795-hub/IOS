#import "GXVideoView.h"
#import "GXVideoGeometry.h"
#import <AVFoundation/AVFoundation.h>

static const CFTimeInterval GXPersonOverlayLifetime = 1.5;

@interface GXVideoView () {
    NSLock *_lock;
    CVPixelBufferRef _latest;
    CFTimeInterval _arrival;
    uint64_t _generation, _offered, _replaced, _displayed, _stale;
    uint32_t _streamID;
    AVSampleBufferDisplayLayer *_displayLayer;
    BOOL _drawScheduled, _inBackground, _needsLayerReset;
    CAShapeLayer *_personOverlay;
    NSDictionary<NSString *, id> *_personResult;
    CFTimeInterval _personResultArrival;
    CGSize _displayedVideoSize;
    uint64_t _displayedGeneration;
    NSTimer *_personExpiryTimer;
}
- (void)scheduleDrawLocked;
- (void)drawLatest;
- (void)updatePersonOverlay;
@end

@implementation GXVideoView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _lock = [NSLock new]; self.backgroundColor = UIColor.blackColor;
        self.clipsToBounds = YES;
        _personOverlay = [CAShapeLayer layer];
        _personOverlay.fillColor = UIColor.clearColor.CGColor;
        _personOverlay.strokeColor = [UIColor colorWithRed:0.15 green:1 blue:0.3 alpha:1].CGColor;
        _personOverlay.lineWidth = 2;
        _personOverlay.lineJoin = kCALineJoinRound;
        _personOverlay.actions = @{@"path": NSNull.null};
        [self.layer addSublayer:_personOverlay];
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
    [_personExpiryTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_latest) CVPixelBufferRelease(_latest);
}
- (void)background:(NSNotification *)notification {
    (void)notification;
    [_lock lock];
    _inBackground = YES;
    if (_latest) { CVPixelBufferRelease(_latest); _latest = NULL; _stale++; }
    [_lock unlock];
    [self setPersonDetectionResult:nil];
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
    [self.layer insertSublayer:_displayLayer below:_personOverlay];
    _displayedVideoSize = CGSizeZero;
    _personOverlay.path = NULL;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _displayLayer.frame = self.bounds; _personOverlay.frame = self.bounds;
    [self updatePersonOverlay]; [CATransaction commit];
}
- (void)beginGeneration:(uint64_t)generation streamID:(uint32_t)streamID {
    [_lock lock];
    _generation = generation; _streamID = streamID;
    if (_latest) { CVPixelBufferRelease(_latest); _latest = NULL; }
    _offered = _replaced = _displayed = _stale = 0;
    // Reset and submission share one main-queue task; a new frame cannot precede its reset.
    _needsLayerReset = YES;
    [self scheduleDrawLocked];
    [_lock unlock];
}
- (void)setPersonDetectionResult:(NSDictionary<NSString *, id> *)result {
    NSAssert(NSThread.isMainThread, @"Detection overlays must be updated on the main queue");
    // Video status is republished every second. It must not renew an old result's lifetime.
    if (_personResult == result) return;
    _personResult = [result copy]; _personResultArrival = CACurrentMediaTime();
    [_personExpiryTimer invalidate]; _personExpiryTimer = nil;
    if (result) {
        // Expire boxes even when no new video frames or detection results arrive.
        // One timer is rearmed per new result, not per decoded frame or status publication.
        __weak GXVideoView *weakSelf = self;
        _personExpiryTimer = [NSTimer timerWithTimeInterval:GXPersonOverlayLifetime repeats:NO block:^(NSTimer *timer) {
            (void)timer; [weakSelf updatePersonOverlay];
        }];
        [NSRunLoop.mainRunLoop addTimer:_personExpiryTimer forMode:NSRunLoopCommonModes];
    }
    [self updatePersonOverlay];
}
- (void)updatePersonOverlay {
    [_lock lock];
    uint32_t stream = _streamID; uint64_t generation = _generation;
    BOOL active = !_inBackground && !_needsLayerReset;
    [_lock unlock];
    double width = [_personResult[@"video_width"] doubleValue], height = [_personResult[@"video_height"] doubleValue];
    if (!active || !_personResult || ![_personResult[@"valid"] boolValue] || [_personResult[@"status"] integerValue] != 0 ||
        !stream || [_personResult[@"stream"] unsignedIntValue] != stream || _displayedGeneration != generation ||
        width <= 0 || height <= 0 || width != _displayedVideoSize.width || height != _displayedVideoSize.height ||
        CACurrentMediaTime() - _personResultArrival > GXPersonOverlayLifetime) {
        _personOverlay.path = NULL; return;
    }
    GXVideoRect viewport = {0, 0, self.bounds.size.width, self.bounds.size.height};
    BOOL fill = [_displayLayer.videoGravity isEqualToString:AVLayerVideoGravityResizeAspectFill];
    CGMutablePathRef path = CGPathCreateMutable();
    for (NSDictionary *box in _personResult[@"boxes"]) {
        GXVideoRect pixels = {[box[@"video_x"] doubleValue], [box[@"video_y"] doubleValue],
                              [box[@"video_w"] doubleValue], [box[@"video_h"] doubleValue]}, visible;
        if (GXVideoMapRect(pixels, width, height, viewport, fill, &visible))
            CGPathAddRect(path, NULL, CGRectMake(visible.x, visible.y, visible.width, visible.height));
    }
    _personOverlay.path = path;
    CGPathRelease(path);
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
// Caller holds _lock. At most one submission task is queued; pending images coalesce to the latest.
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
    // Use presentation dimensions, not the padded 1088-line coded surface of some 1080p streams.
    CGSize imageSize = format ? CMVideoFormatDescriptionGetPresentationDimensions(format, false, true) : CGSizeZero;
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
    // Keep generation validation and enqueue atomic with STOP/reconnect.
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
    if (enqueued && (!CGSizeEqualToSize(_displayedVideoSize, imageSize) || _displayedGeneration != generation)) {
        _displayedVideoSize = imageSize; _displayedGeneration = generation;
        [self updatePersonOverlay];
    }
}
@end
