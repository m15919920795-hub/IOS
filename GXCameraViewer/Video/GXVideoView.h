#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN
@interface GXVideoView : UIView
/* Thread-safe. Old-generation outputs are ignored, including outputs from an in-flight decode. */
- (void)beginGeneration:(uint64_t)generation;
- (void)offerPixelBuffer:(CVPixelBufferRef)image generation:(uint64_t)generation arrivalTime:(CFTimeInterval)arrival;
- (NSDictionary<NSString *, NSNumber *> *)statistics;
@end
NS_ASSUME_NONNULL_END
