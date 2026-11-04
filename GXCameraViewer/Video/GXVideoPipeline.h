#import <Foundation/Foundation.h>
#import "GXVPWire.h"
@class GXVideoView;

NS_ASSUME_NONNULL_BEGIN
@interface GXVideoPipeline : NSObject
@property (nonatomic, copy, nullable) void (^needsIDR)(void);
@property (nonatomic, copy, nullable) void (^logMessage)(NSString *message);
@property (nonatomic, copy, nullable) void (^fatalError)(NSString *message, uint64_t generation);
- (instancetype)initWithVideoView:(GXVideoView *)view;
- (void)configure:(GXVPVideoConfig)config streamID:(uint32_t)streamID;
- (void)stop;
/* Called on the client's serial network queue. It never waits for the decoder/UI. */
- (BOOL)receiveFrame:(NSData *)body header:(GXVPMessageHeader)header error:(NSError **)error;
- (NSDictionary<NSString *, NSNumber *> *)statistics;
@end
NS_ASSUME_NONNULL_END
