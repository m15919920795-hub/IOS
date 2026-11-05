#import <Foundation/Foundation.h>
@class GXPersonClient;
NS_ASSUME_NONNULL_BEGIN
@protocol GXPersonClientDelegate <NSObject>
/* Main queue. State includes the latest complete `result` dictionary, if any.
 * Updates are coalesced; callers should also replace rather than queue results. */
- (void)personClient:(GXPersonClient *)client stateChanged:(NSDictionary<NSString *, id> *)state;
- (void)personClient:(GXPersonClient *)client logMessage:(NSString *)message;
@end

@interface GXPersonClient : NSObject
@property (nonatomic, weak, nullable) id<GXPersonClientDelegate> delegate;
- (void)connectToHost:(NSString *)host; /* Separate TCP 5601; does not start video. */
- (void)disconnect;
- (void)setDetectionEnabled:(BOOL)enabled;
- (void)getStatus;
@end
NS_ASSUME_NONNULL_END
