#import <Foundation/Foundation.h>
@class GXCameraClient, GXVideoView;

NS_ASSUME_NONNULL_BEGIN
@protocol GXCameraClientDelegate <NSObject>
/* All delegate calls are delivered on the main queue. */
- (void)cameraClient:(GXCameraClient *)client statusChanged:(NSDictionary<NSString *, id> *)status;
- (void)cameraClient:(GXCameraClient *)client logMessage:(NSString *)message;
@end

@interface GXCameraClient : NSObject
@property (nonatomic, weak, nullable) id<GXCameraClientDelegate> delegate;
- (instancetype)initWithVideoView:(GXVideoView *)view;
- (void)connectToHost:(NSString *)host port:(uint16_t)port;
- (void)disconnect;
- (void)startProfile:(uint8_t)profile;
- (void)stop;
- (void)getStatus;
- (void)requestIDR;
@end
NS_ASSUME_NONNULL_END
