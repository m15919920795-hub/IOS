#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN
@interface GXVideoView : UIView
/* Thread-safe. Old-generation outputs are ignored, including outputs from an in-flight decode. */
- (void)beginGeneration:(uint64_t)generation streamID:(uint32_t)streamID;
- (void)offerPixelBuffer:(CVPixelBufferRef)image generation:(uint64_t)generation arrivalTime:(CFTimeInterval)arrival;
- (NSDictionary<NSString *, NSNumber *> *)statistics;
/* Main queue only. Pass the latest validated detection result, or nil to clear. */
- (void)setPersonDetectionResult:(nullable NSDictionary<NSString *, id> *)result;
@end
NS_ASSUME_NONNULL_END
