#import "GXPersonClient.h"
@import CocoaAsyncSocket;
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdint.h>

static BOOL GXPersonUnsigned(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number >= 0 && number <= UINT32_MAX && floor(number) == number;
}
static BOOL GXPersonBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}
static BOOL GXPersonNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() && isfinite([value doubleValue]);
}

@interface GXPersonClient () <GCDAsyncSocketDelegate> {
    dispatch_queue_t _queue;
    GCDAsyncSocket *_socket;
    uint32_t _requestID, _pendingID;
    NSString *_pendingCommand;
    BOOL _connected, _connecting;
    NSDictionary *_remote, *_result;
    NSLock *_publicationLock;
    NSDictionary *_latestPublication;
    BOOL _publicationQueued;
}
@end

@implementation GXPersonClient
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.gx.camera.person", DISPATCH_QUEUE_SERIAL);
        _publicationLock = [NSLock new];
    }
    return self;
}
- (void)dealloc { [_socket setDelegate:nil]; [_socket disconnect]; }
- (void)publish {
    NSMutableDictionary *state = [NSMutableDictionary dictionaryWithDictionary:_remote ?: @{}];
    state[@"connected"] = @(_connected); state[@"connecting"] = @(_connecting);
    state[@"pending"] = @(_pendingID != 0); state[@"known"] = @(_remote != nil);
    if (_result) state[@"result"] = _result;
    [_publicationLock lock];
    _latestPublication = [state copy];
    BOOL schedule = !_publicationQueued;
    _publicationQueued = YES;
    [_publicationLock unlock];
    if (!schedule) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_publicationLock lock];
        NSDictionary *latest = self->_latestPublication;
        self->_publicationQueued = NO;
        [self->_publicationLock unlock];
        [self.delegate personClient:self stateChanged:latest];
    });
}
- (void)log:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate personClient:self logMessage:message]; });
}
- (void)clear {
    [_socket setDelegate:nil]; [_socket disconnect]; _socket = nil;
    _connected = _connecting = NO; _pendingID = 0; _pendingCommand = nil;
    _remote = _result = nil;
}
- (void)fail:(NSString *)message { [self log:message]; [self clear]; [self publish]; }
- (void)connectToHost:(NSString *)host {
    dispatch_async(_queue, ^{
        [self clear]; self->_requestID = 0;
        self->_socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:self->_queue];
        NSError *error = nil;
        self->_connecting = YES;
        if (![self->_socket connectToHost:host onPort:5601 withTimeout:5 error:&error]) {
            [self fail:[NSString stringWithFormat:@"识别端口连接失败：%@", error.localizedDescription]]; return;
        }
        [self publish];
    });
}
- (void)disconnect { dispatch_async(_queue, ^{ [self clear]; [self publish]; }); }
- (void)getStatus { dispatch_async(_queue, ^{ [self sendCommand:@"get" enabled:NO]; }); }
- (void)setDetectionEnabled:(BOOL)enabled {
    dispatch_async(_queue, ^{ [self sendCommand:@"set" enabled:enabled]; });
}
- (void)sendCommand:(NSString *)command enabled:(BOOL)enabled {
    if (!_connected || _pendingID) return;
    if (_requestID == UINT32_MAX) { [self fail:@"识别请求编号耗尽，请重新连接。"] ; return; }
    _pendingID = ++_requestID; _pendingCommand = command;
    NSMutableDictionary *body = [@{@"id":@(_pendingID), @"cmd":command} mutableCopy];
    if ([command isEqualToString:@"set"]) body[@"enabled"] = @(enabled);
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:body options:0 error:nil] mutableCopy];
    const char lf = '\n'; [data appendBytes:&lf length:1];
    [_socket writeData:data withTimeout:3 tag:_pendingID];
    GCDAsyncSocket *socket = _socket;
    uint32_t request = _pendingID;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), _queue, ^{
        GXPersonClient *client = weakSelf;
        if (client && client->_socket == socket && client->_pendingID == request)
            [client fail:@"识别指令应答超时，识别端口已断开；视频可继续播放。"];
    });
    [self publish];
}
- (void)readNext {
    /* GCDAsyncSocket handles TCP splitting/coalescing. Bound every complete line
     * before JSON parsing; an idle detection connection has no read timeout. */
    [_socket readDataToData:[NSData dataWithBytes:"\n" length:1] withTimeout:-1 maxLength:8192 tag:1];
}
- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port {
    (void)host; (void)port; if (sock != _socket) return;
    _connected = YES; _connecting = NO;
    [self log:@"识别 TCP 5601 已连接，检测间隔 300 ms。"];
    [self readNext]; [self sendCommand:@"get" enabled:NO];
}
- (BOOL)acceptState:(NSDictionary *)message {
    for (NSString *key in @[@"generation", @"stream", @"interval_ms", @"ref_width", @"ref_height", @"video_width", @"video_height"])
        if (!GXPersonUnsigned(message[key])) return NO;
    for (NSString *key in @[@"enabled", @"ready", @"running"])
        if (!GXPersonBoolean(message[key])) return NO;
    if (!GXPersonNumber(message[@"init_status"])) return NO;
    if ([_remote[@"generation"] unsignedIntValue] != [message[@"generation"] unsignedIntValue] ||
        ![message[@"enabled"] boolValue] || ![message[@"running"] boolValue]) _result = nil;
    _remote = message;
    return YES;
}
- (BOOL)acceptResult:(NSDictionary *)message {
    for (NSString *key in @[@"generation", @"stream", @"seq", @"read_ms", @"done_ms", @"run_us", @"ref_width", @"ref_height", @"video_width", @"video_height", @"count"])
        if (!GXPersonUnsigned(message[key])) return NO;
    if (!GXPersonBoolean(message[@"valid"]) || !GXPersonNumber(message[@"status"]) ||
        ![message[@"boxes"] isKindOfClass:NSArray.class]) return NO;
    NSUInteger count = [message[@"count"] unsignedIntegerValue];
    if (count > 32 || [message[@"boxes"] count] != count || (![message[@"valid"] boolValue] && count)) return NO;
    double width = [message[@"ref_width"] doubleValue], height = [message[@"ref_height"] doubleValue];
    if (!width || !height) return NO;
    for (id item in message[@"boxes"]) {
        if (![item isKindOfClass:NSDictionary.class]) return NO;
        NSDictionary *box = item;
        for (NSString *key in @[@"score", @"x", @"y", @"w", @"h", @"video_x", @"video_y", @"video_w", @"video_h"])
            if (!GXPersonNumber(box[key]) || [box[key] doubleValue] < 0) return NO;
        if ([box[@"score"] doubleValue] > 1 || [box[@"x"] doubleValue] > width || [box[@"w"] doubleValue] > width ||
            [box[@"y"] doubleValue] > height || [box[@"h"] doubleValue] > height) return NO;
    }
    /* Status precedes each new generation. Never revive stale boxes after OFF. */
    if ([_remote[@"enabled"] boolValue] && [_remote[@"running"] boolValue] &&
        [_remote[@"generation"] unsignedIntValue] == [message[@"generation"] unsignedIntValue] &&
        [_remote[@"stream"] unsignedIntValue] == [message[@"stream"] unsignedIntValue]) _result = message;
    return YES;
}
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
    (void)tag; if (sock != _socket) return;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![parsed isKindOfClass:NSDictionary.class]) { [self fail:@"识别协议 JSON 错误。"] ; return; }
    NSDictionary *message = parsed;
    if (!GXPersonUnsigned(message[@"v"]) || [message[@"v"] unsignedIntValue] != 1 ||
        ![message[@"type"] isKindOfClass:NSString.class]) { [self fail:@"识别协议版本或类型错误。"] ; return; }
    NSString *type = message[@"type"];
    BOOL valid = NO;
    if ([type isEqualToString:@"status"]) valid = [self acceptState:message];
    else if ([type isEqualToString:@"result"]) valid = [self acceptResult:message];
    else if ([type isEqualToString:@"reply"] && GXPersonUnsigned(message[@"id"]) &&
        GXPersonUnsigned(message[@"code"]) && [message[@"id"] unsignedIntValue] == _pendingID &&
        [message[@"cmd"] isKindOfClass:NSString.class] && [message[@"cmd"] isEqualToString:_pendingCommand]) {
        valid = [self acceptState:message];
        _pendingID = 0; _pendingCommand = nil;
        if ([message[@"code"] unsignedIntValue])
            [self log:[NSString stringWithFormat:@"识别指令未执行，code=%@。", message[@"code"]]];
    }
    if (!valid) { [self fail:@"识别协议字段错误，已关闭识别连接。"] ; return; }
    [self publish]; [self readNext];
}
- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)error {
    if (sock != _socket) return;
    [self fail:[NSString stringWithFormat:@"识别端口已断开：%@", error.localizedDescription ?: @"连接结束"]];
}
@end
