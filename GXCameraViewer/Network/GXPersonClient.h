#import <Foundation/Foundation.h>
@class GXPersonClient;
NS_ASSUME_NONNULL_BEGIN
@protocol GXPersonClientDelegate <NSObject>
/* Main queue. State includes latest `result` / `recording` dictionaries, if any,
 * recording capability and the pending command. Disconnect means unknown
 * recorder state, not proof that its MP4 has closed.
 * Updates are coalesced; callers should also replace rather than queue results. */
- (void)personClient:(GXPersonClient *)client stateChanged:(NSDictionary<NSString *, id> *)state;
- (void)personClient:(GXPersonClient *)client logMessage:(NSString *)message;
@end

@interface GXPersonClient : NSObject
@property (nonatomic, weak, nullable) id<GXPersonClientDelegate> delegate;
- (void)connectToHost:(NSString *)host; /* Shared control TCP 5601; does not start video. */
- (void)disconnect;
- (void)setDetectionEnabled:(BOOL)enabled;
- (void)getStatus;
- (void)startRecording;
- (void)stopRecording;
- (void)getRecordingStatus;
@end
NS_ASSUME_NONNULL_END
