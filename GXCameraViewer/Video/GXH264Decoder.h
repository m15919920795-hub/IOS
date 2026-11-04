#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "GXVPWire.h"

NS_ASSUME_NONNULL_BEGIN
typedef void (^GXDecodedImageHandler)(CVPixelBufferRef image, uint64_t generation, CFTimeInterval arrivalTime);

/* All methods and properties except the output callback belong to ONE decode queue. */
@interface GXH264Decoder : NSObject
@property (nonatomic, readonly) BOOL usingHardwareDecoder;
- (instancetype)initWithOutput:(GXDecodedImageHandler)output;
- (BOOL)decodeAnnexB:(NSData *)data config:(GXVPVideoConfig)config
        timestampUs:(uint64_t)timestamp generation:(uint64_t)generation
        arrivalTime:(CFTimeInterval)arrival error:(NSError **)error fatal:(BOOL *)fatal;
- (void)reset;
@end
NS_ASSUME_NONNULL_END
