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
    NSDictionary *_record;
    NSString *_recordFeedback;
    BOOL _recordSupported, _requestedRecordStatus;
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
    BOOL recordPending = [_pendingCommand hasPrefix:@"record_"];
    state[@"personPending"] = @(_pendingID && !recordPending);
    state[@"recordPending"] = @(_pendingID && recordPending);
    state[@"pendingCommand"] = _pendingCommand ?: @"";
    state[@"recordSupported"] = @(_recordSupported);
    state[@"recordKnown"] = @(_record != nil);
    if (_record) state[@"recording"] = _record;
    if (_recordFeedback) state[@"recordFeedback"] = _recordFeedback;
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
    _record = nil; _recordFeedback = nil; _recordSupported = _requestedRecordStatus = NO;
}
- (void)fail:(NSString *)message { [self log:message]; [self clear]; [self publish]; }
- (void)connectToHost:(NSString *)host {
    dispatch_async(_queue, ^{
        [self clear]; self->_requestID = 0;
        self->_socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:self->_queue];
        NSError *error = nil;
        self->_connecting = YES;
        if (![self->_socket connectToHost:host onPort:5601 withTimeout:5 error:&error]) {
            [self fail:[NSString stringWithFormat:@"控制端口连接失败：%@", error.localizedDescription]]; return;
        }
        [self publish];
    });
}
- (void)disconnect { dispatch_async(_queue, ^{ [self clear]; [self publish]; }); }
- (void)getStatus { dispatch_async(_queue, ^{ [self sendCommand:@"get" enabled:NO]; }); }
- (void)setDetectionEnabled:(BOOL)enabled {
    dispatch_async(_queue, ^{ [self sendCommand:@"set" enabled:enabled]; });
}
- (void)startRecording { dispatch_async(_queue, ^{ [self sendCommand:@"record_start" enabled:NO]; }); }
- (void)stopRecording { dispatch_async(_queue, ^{ [self sendCommand:@"record_stop" enabled:NO]; }); }
- (void)getRecordingStatus { dispatch_async(_queue, ^{ [self sendCommand:@"record_get" enabled:NO]; }); }
- (void)sendCommand:(NSString *)command enabled:(BOOL)enabled {
    if (!_connected || _pendingID) return;
    if ([command hasPrefix:@"record_"]) {
        if (!_recordSupported) { [self log:@"当前固件未声明录像控制协议，请更新板端固件。"] ; return; }
        _recordFeedback = nil;
    }
    if (_requestID == UINT32_MAX) { [self fail:@"控制请求编号耗尽，请重新连接。"] ; return; }
    _pendingID = ++_requestID; _pendingCommand = command;
    NSMutableDictionary *body = [@{@"id":@(_pendingID), @"cmd":command} mutableCopy];
    if ([command isEqualToString:@"set"]) body[@"enabled"] = @(enabled);
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:body options:0 error:nil] mutableCopy];
    const char lf = '\n'; [data appendBytes:&lf length:1];
    [_socket writeData:data withTimeout:3 tag:_pendingID];
    GCDAsyncSocket *socket = _socket;
    uint32_t request = _pendingID;
    __weak typeof(self) weakSelf = self;
    BOOL recordCommand = [command hasPrefix:@"record_"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (recordCommand ? 20 : 5) * NSEC_PER_SEC), _queue, ^{
        GXPersonClient *client = weakSelf;
        if (client && client->_socket == socket && client->_pendingID == request)
            [client fail:recordCommand ? @"录像指令应答超时，操作结果未知；请重连控制端口查询，勿据此认为文件已关闭。" :
                @"识别指令应答超时，控制端口已断开；视频可继续播放。"];
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
    [self log:@"控制 TCP 5601 已连接：人形识别与 TF 录像共用此连接。"];
    [self readNext]; [self sendCommand:@"get" enabled:NO];
}
- (BOOL)acceptState:(NSDictionary *)message {
    for (NSString *key in @[@"generation", @"stream", @"interval_ms", @"ref_width", @"ref_height", @"video_width", @"video_height"])
        if (!GXPersonUnsigned(message[key])) return NO;
    for (NSString *key in @[@"enabled", @"ready", @"running"])
        if (!GXPersonBoolean(message[key])) return NO;
    if (!GXPersonNumber(message[@"init_status"])) return NO;
    id recordingProtocol = message[@"recording_protocol"];
    if (recordingProtocol && !GXPersonUnsigned(recordingProtocol)) return NO;
    _recordSupported = [recordingProtocol unsignedIntValue] == 1;
    if ([_remote[@"generation"] unsignedIntValue] != [message[@"generation"] unsignedIntValue] ||
        ![message[@"enabled"] boolValue] || ![message[@"running"] boolValue]) _result = nil;
    _remote = message;
    return YES;
}
- (BOOL)acceptRecordingState:(NSDictionary *)message {
    for (NSString *key in @[@"record_id", @"stream", @"width", @"height", @"fps", @"frames", @"bytes", @"gaps", @"error", @"close_error"])
        if (!GXPersonUnsigned(message[key])) return NO;
    for (NSString *key in @[@"available", @"video_online", @"active"])
        if (!GXPersonBoolean(message[key])) return NO;
    if (!GXPersonNumber(message[@"boot_card"]) || floor([message[@"boot_card"] doubleValue]) != [message[@"boot_card"] doubleValue] ||
        [message[@"boot_card"] doubleValue] < -1 || [message[@"boot_card"] doubleValue] > INT32_MAX) return NO;
    NSString *state = message[@"state"], *file = message[@"file"];
    if (![state isKindOfClass:NSString.class] || ![file isKindOfClass:NSString.class] || file.length > 79) return NO;
    NSArray *states = @[@"IDLE", @"STARTING", @"WAIT_IDR", @"RECORDING", @"STOPPING", @"ERROR", @"UNAVAILABLE"];
    if (![states containsObject:state]) return NO;
    BOOL active = [@[@"STARTING", @"WAIT_IDR", @"RECORDING", @"STOPPING"] containsObject:state];
    if (active != [message[@"active"] boolValue] ||
        [message[@"available"] boolValue] == [state isEqualToString:@"UNAVAILABLE"]) return NO;
    if (active && (![message[@"record_id"] unsignedIntValue] || ![message[@"stream"] unsignedIntValue] ||
        ![message[@"width"] unsignedIntValue] || ![message[@"height"] unsignedIntValue] || ![message[@"fps"] unsignedIntValue])) return NO;
    if (_record && (![_record[@"state"] isEqual:message[@"state"]] ||
        ![_record[@"record_id"] isEqual:message[@"record_id"]])) _recordFeedback = nil;
    _record = message;
    return YES;
}
- (NSString *)recordingFailure:(NSDictionary *)message {
    switch ([message[@"code"] unsignedIntValue]) {
        case 1: return @"指令格式错误";
        case 2: return @"录像模块未就绪";
        case 3: return @"请求编号已过期";
        case 4: return @"已有录像正在进行或保存中";
        case 5: return @"请先开启视频预览";
        case 7: return @"等待操作完成超时，结果尚未确认，请查询状态";
        case 8: return @"操作被视频停止或其他操作中止";
        default: break;
    }
    NSDictionary *errors = @{@1:@"录像缓存满", @3:@"录像内存不足", @4:@"等待关键帧超时", @10:@"TF卡初始化失败",
        @11:@"文件编号扫描失败", @12:@"文件创建失败", @13:@"MP4打开失败", @14:@"写卡失败",
        @15:@"文件关闭失败", @16:@"达到单文件大小上限", @17:@"空间不足或空间查询失败"};
    return errors[message[@"error"]] ?: [NSString stringWithFormat:@"录像操作失败，error=%@ close_error=%@", message[@"error"], message[@"close_error"]];
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
    if (![parsed isKindOfClass:NSDictionary.class]) { [self fail:@"控制协议 JSON 错误。"] ; return; }
    NSDictionary *message = parsed;
    if (!GXPersonUnsigned(message[@"v"]) || [message[@"v"] unsignedIntValue] != 1 ||
        ![message[@"type"] isKindOfClass:NSString.class]) { [self fail:@"控制协议版本或类型错误。"] ; return; }
    NSString *type = message[@"type"];
    BOOL valid = NO;
    if ([type isEqualToString:@"status"]) valid = [self acceptState:message];
    else if ([type isEqualToString:@"result"]) valid = [self acceptResult:message];
    else if ([type isEqualToString:@"record_status"] && _recordSupported) valid = [self acceptRecordingState:message];
    else if ([type isEqualToString:@"record_reply"] && _recordSupported &&
        GXPersonUnsigned(message[@"id"]) && GXPersonUnsigned(message[@"code"]) &&
        GXPersonBoolean(message[@"ok"]) && [message[@"ok"] boolValue] == ([message[@"code"] unsignedIntValue] == 0) &&
        [message[@"id"] unsignedIntValue] == _pendingID && [_pendingCommand hasPrefix:@"record_"] &&
        [message[@"cmd"] isKindOfClass:NSString.class] && [message[@"cmd"] isEqualToString:_pendingCommand]) {
        valid = [self acceptRecordingState:message];
        if (valid) {
            NSString *command = _pendingCommand;
            BOOL ok = [message[@"ok"] boolValue];
            if ([command isEqualToString:@"record_start"]) {
                valid = !ok || ([message[@"active"] boolValue] && [message[@"frames"] unsignedIntValue] > 0 &&
                    [@[@"RECORDING", @"WAIT_IDR"] containsObject:message[@"state"]] &&
                    ![message[@"error"] unsignedIntValue] && ![message[@"close_error"] unsignedIntValue]);
                _recordFeedback = ok ? @"开始录像成功：已写入首帧" : [@"开始录像失败：" stringByAppendingString:[self recordingFailure:message]];
            } else if ([command isEqualToString:@"record_stop"]) {
                valid = !ok || (![message[@"active"] boolValue] && ![message[@"error"] unsignedIntValue] && ![message[@"close_error"] unsignedIntValue]);
                _recordFeedback = ok ? @"停止录像成功：文件已关闭" : [@"停止录像未成功确认：" stringByAppendingString:[self recordingFailure:message]];
            } else _recordFeedback = ok ? @"录像状态已更新" : [self recordingFailure:message];
            if (valid) [self log:_recordFeedback];
        }
        _pendingID = 0; _pendingCommand = nil;
    }
    else if ([type isEqualToString:@"reply"] && GXPersonUnsigned(message[@"id"]) &&
        GXPersonUnsigned(message[@"code"]) && [message[@"id"] unsignedIntValue] == _pendingID &&
        [message[@"cmd"] isKindOfClass:NSString.class] && [message[@"cmd"] isEqualToString:_pendingCommand]) {
        valid = [self acceptState:message];
        _pendingID = 0; _pendingCommand = nil;
        if ([message[@"code"] unsignedIntValue])
            [self log:[NSString stringWithFormat:@"识别指令未执行，code=%@。", message[@"code"]]];
    }
    if (!valid) { [self fail:@"控制协议字段错误，已关闭控制连接。"] ; return; }
    /* Old firmware does not advertise this capability, so it never receives
     * an unsupported record command. Read state after reconnect; never infer
     * that disconnecting the control socket stopped a board-side recording. */
    if (_recordSupported && !_requestedRecordStatus && !_pendingID) {
        _requestedRecordStatus = YES;
        [self sendCommand:@"record_get" enabled:NO];
    }
    [self publish]; [self readNext];
}
- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)error {
    if (sock != _socket) return;
    [self fail:[NSString stringWithFormat:@"控制端口已断开：%@", error.localizedDescription ?: @"连接结束"]];
}
@end
