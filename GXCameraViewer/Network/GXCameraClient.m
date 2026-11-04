#import "GXCameraClient.h"
#import "GXVideoPipeline.h"
#import "GXVPWire.h"
@import CocoaAsyncSocket;
#import <QuartzCore/QuartzCore.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>

enum { GXReadHeaderTag = 1, GXReadBodyTag = 2 };
@interface GXPendingCommand : NSObject
@property (nonatomic) uint8_t command, profile;
@property (nonatomic) CFTimeInterval deadline;
@end
@implementation GXPendingCommand
@end

@interface GXCameraClient () <GCDAsyncSocketDelegate> {
    dispatch_queue_t _networkQueue;
    dispatch_source_t _timer;
    GCDAsyncSocket *_socket;
    GXVideoPipeline *_pipeline;
    NSMutableDictionary<NSNumber *, GXPendingCommand *> *_pending;
    GXVPMessageHeader _incoming;
    GXVPVideoConfig _config;
    uint32_t _requestNumber, _streamID;
    uint8_t _state, _profile;
    BOOL _connected, _connecting, _configured, _suppressVideo;
    CFTimeInterval _lastIDR, _lastReport;
    uint64_t _reportGeneration, _reportReceived, _reportBytes, _reportDecoded, _reportDisplayed;
    double _receiveFPS, _decodeFPS, _displayFPS, _receiveKbps;
    NSString *_message;
}
@end

@implementation GXCameraClient
- (instancetype)initWithVideoView:(GXVideoView *)view {
    if ((self = [super init])) {
        _networkQueue = dispatch_queue_create("com.gx.camera.network", DISPATCH_QUEUE_SERIAL);
        _pending = [NSMutableDictionary dictionary];
        _pipeline = [[GXVideoPipeline alloc] initWithVideoView:view];
        _message = @"先在系统设置连接 GX-7259，再点击连接。";
        __weak typeof(self) weakSelf = self;
        _pipeline.needsIDR = ^{ [weakSelf requestIDR]; };
        _pipeline.logMessage = ^(NSString *message) {
            GXCameraClient *client = weakSelf;
            if (client) dispatch_async(client->_networkQueue, ^{ [client log:message]; });
        };
        _pipeline.fatalError = ^(NSString *message, uint64_t generation) {
            GXCameraClient *client = weakSelf;
            if (client) dispatch_async(client->_networkQueue, ^{
                if ([[client->_pipeline statistics][@"generation"] unsignedLongLongValue] != generation) return;
                [client log:[@"播放停止：" stringByAppendingString:message]];
                if (client->_connected) [client sendCommand:GXVPStop profile:0];
                [client->_pipeline stop]; client->_suppressVideo = YES;
                [client publish];
            });
        };
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _networkQueue);
        dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(_timer, ^{ [weakSelf timerFired]; });
        dispatch_resume(_timer);
    }
    return self;
}
- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
    [_socket setDelegate:nil]; [_socket disconnect]; [_pipeline stop];
}
- (void)log:(NSString *)message {
    _message = [message copy];
    dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate cameraClient:self logMessage:message]; });
}
- (BOOL)hasPendingOperation {
    for (GXPendingCommand *command in _pending.allValues)
        if (command.command == GXVPStart || command.command == GXVPStop) return YES;
    return NO;
}
- (void)publish {
    NSDictionary *stats = [_pipeline statistics];
    NSDictionary *status = @{
        @"connected": @(_connected), @"connecting": @(_connecting), @"pending": @([self hasPendingOperation]),
        @"state": @(_state), @"profile": @(_profile), @"stream": @(_streamID),
        @"configured": @(_configured), @"width": @(_config.width), @"height": @(_config.height),
        @"receiveFPS": @(_receiveFPS), @"decodeFPS": @(_decodeFPS), @"displayFPS": @(_displayFPS),
        @"kbps": @(_receiveKbps), @"hardware": stats[@"hardware"] ?: @NO,
        @"queue": stats[@"queue"] ?: @0, @"drops": stats[@"dropped"] ?: @0,
        @"replaced": stats[@"replaced"] ?: @0, @"relativeLag": stats[@"relativeLag"] ?: @0,
        @"message": _message ?: @""
    };
    dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate cameraClient:self statusChanged:status]; });
}
- (void)clearSession {
    [_pending removeAllObjects]; [_pipeline stop];
    _connected = _connecting = _configured = _suppressVideo = NO;
    _state = GXVPIdle; _profile = 0; _streamID = 0; _config = (GXVPVideoConfig){0};
    _receiveFPS = _decodeFPS = _displayFPS = _receiveKbps = 0;
    _reportGeneration = UINT64_MAX; _lastReport = CACurrentMediaTime();
}
- (void)fail:(NSString *)message {
    [self log:message];
    GCDAsyncSocket *socket = _socket; _socket = nil;
    [socket setDelegate:nil]; [socket disconnect];
    [self clearSession]; [self publish];
}
- (void)connectToHost:(NSString *)host port:(uint16_t)port {
    dispatch_async(_networkQueue, ^{
        if (self->_connected || self->_connecting) return;
        [self clearSession]; self->_requestNumber = 0; self->_lastIDR = -1000;
        self->_connecting = YES;
        self->_socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:self->_networkQueue];
        [self log:[NSString stringWithFormat:@"连接 %@:%u…", host, port]]; [self publish];
        NSError *error = nil;
        if (![self->_socket connectToHost:host onPort:port withTimeout:10 error:&error])
            [self fail:[@"无法连接：" stringByAppendingString:error.localizedDescription ?: @"参数错误"]];
    });
}
- (void)disconnect {
    dispatch_async(_networkQueue, ^{ [self fail:@"已断开连接，设备将回收视频资源。"] ; });
}
- (void)startProfile:(uint8_t)profile {
    dispatch_async(_networkQueue, ^{
        if (!self->_connected || [self hasPendingOperation]) return;
        if (self->_state != GXVPIdle) {
            [self log:@"请先停止并等待成功，再选择另一档位开始。"];
            [self publish]; return;
        }
        [self sendCommand:GXVPStart profile:profile];
    });
}
- (void)stop { dispatch_async(_networkQueue, ^{ [self sendCommand:GXVPStop profile:0]; }); }
- (void)getStatus { dispatch_async(_networkQueue, ^{ [self sendCommand:GXVPGetStatus profile:0]; }); }
- (void)requestIDR {
    dispatch_async(_networkQueue, ^{
        if (self->_connected && self->_configured && !self->_suppressVideo && self->_state == GXVPRunning &&
            CACurrentMediaTime() - self->_lastIDR >= 1.0) {
            self->_lastIDR = CACurrentMediaTime();
            [self sendCommand:GXVPRequestIDR profile:0];
        }
    });
}
- (void)sendCommand:(uint8_t)command profile:(uint8_t)profile {
    if (!_connected) return;
    if ((command == GXVPStart || command == GXVPStop) && [self hasPendingOperation]) return;
    // Avoid poll/button floods and keep the server's small command queue bounded.
    for (GXPendingCommand *item in _pending.allValues) if (item.command == command) return;
    if (_pending.count >= 4) return;
    if (_requestNumber == UINT32_MAX) { [self fail:@"请求编号用尽，请重新连接。"] ; return; }
    uint32_t sequence = ++_requestNumber;
    uint8_t bytes[36];
    size_t count = GXVPWriteCommand(bytes, sizeof(bytes), command, sequence, profile);
    if (!count) { [self log:@"无效命令参数"]; [self publish]; return; }
    GXPendingCommand *pending = [GXPendingCommand new]; pending.command = command; pending.profile = profile;
    pending.deadline = CACurrentMediaTime() + (command == GXVPStart ? 20 : 15);
    _pending[@(sequence)] = pending;
    if (command == GXVPStop) { _suppressVideo = YES; [_pipeline stop]; }
    [_socket writeData:[NSData dataWithBytes:bytes length:count] withTimeout:5 tag:sequence];
    NSString *name = command == GXVPStart ? @"START" : command == GXVPStop ? @"STOP" :
                     command == GXVPRequestIDR ? @"REQUEST_IDR" : @"GET_STATUS";
    [self log:[NSString stringWithFormat:@"发送 %@ #%u%@", name, sequence,
        command == GXVPStart ? (profile == 1 ? @" 720p/25" : @" 1080p/20") : @""]];
    [self publish];
}
- (void)socket:(GCDAsyncSocket *)socket didConnectToHost:(NSString *)host port:(uint16_t)port {
    (void)host; (void)port;
    if (socket != _socket) return;
    _connecting = NO; _connected = YES;
    [socket performBlock:^{
        int enabled = 1;
        setsockopt(socket.socketFD, IPPROTO_TCP, TCP_NODELAY, &enabled, sizeof(enabled));
    }];
    [socket readDataToLength:GXVPHeaderSize withTimeout:-1 tag:GXReadHeaderTag];
    [self log:@"TCP 已连接；不会自动开始视频。"];
    [self sendCommand:GXVPGetStatus profile:0];
}
- (void)socketDidDisconnect:(GCDAsyncSocket *)socket withError:(NSError *)error {
    if (socket != _socket) return;
    _socket = nil;
    [self log:error ? [NSString stringWithFormat:@"连接断开：%@。检查 GX-7259、本地网络权限及电脑客户端是否已退出。", error.localizedDescription]
                   : @"设备关闭了连接。"];
    [self clearSession]; [self publish];
}
- (void)socket:(GCDAsyncSocket *)socket didReadData:(NSData *)data withTag:(long)tag {
    if (socket != _socket) return;
    if (tag == GXReadHeaderTag) {
        if (!GXVPReadHeader(data.bytes, data.length, &_incoming)) {
            [self fail:@"GXVP 消息头无效，请确认设备烧录的是 GXVP v1 固件。"] ; return;
        }
        [socket readDataToLength:_incoming.payloadLength withTimeout:10 tag:GXReadBodyTag];
        return;
    }
    if (tag != GXReadBodyTag || data.length != _incoming.payloadLength) {
        [self fail:@"GXVP 消息体长度错误。"] ; return;
    }
    BOOL accepted = YES;
    if (_incoming.type == GXVPReply) accepted = [self handleReply:data header:_incoming];
    else if (_incoming.type == GXVPConfig) accepted = [self handleConfig:data header:_incoming];
    else {
        if (!_configured || _incoming.streamID != _streamID) {
            [self fail:@"收到没有对应 VIDEO_CONFIG 的视频流。"] ; return;
        }
        if (!_suppressVideo) {
            NSError *error = nil;
            accepted = [_pipeline receiveFrame:data header:_incoming error:&error];
            if (!accepted) [self fail:error.localizedDescription ?: @"视频帧无效。"];
        }
    }
    if (accepted && socket == _socket)
        [socket readDataToLength:GXVPHeaderSize withTimeout:-1 tag:GXReadHeaderTag];
}
- (BOOL)handleReply:(NSData *)body header:(GXVPMessageHeader)header {
    GXVPCommandReply reply;
    GXPendingCommand *pending = _pending[@(header.sequenceID)];
    if (!GXVPReadReply(body.bytes, body.length, &reply) || !pending || pending.command != reply.command) {
        [self fail:@"应答与待处理请求不匹配。"] ; return NO;
    }
    if ((reply.state == GXVPIdle && (reply.profile || header.streamID)) ||
        (reply.state == GXVPRunning && (!reply.profile || !header.streamID)) ||
        (reply.command == GXVPStart && reply.result == 0 &&
         (reply.state != GXVPRunning || reply.profile != pending.profile)) ||
        (reply.command == GXVPStop && reply.result == 0 && reply.state != GXVPIdle)) {
        [self fail:@"应答状态与流编号不一致。"] ; return NO;
    }
    [_pending removeObjectForKey:@(header.sequenceID)];
    _state = reply.state; _profile = reply.profile; _streamID = header.streamID;
    if (reply.command == GXVPStart && reply.result == 0) { _configured = NO; _suppressVideo = NO; }
    if (reply.command == GXVPStop) {
        _suppressVideo = NO;
        if (reply.result == 0) { _configured = NO; _config = (GXVPVideoConfig){0}; [_pipeline stop]; }
        else if (_configured) { [_pipeline configure:_config streamID:_streamID]; [self requestIDR]; }
    }
    NSArray *results = @[@"成功", @"设备忙，请稍后重试", @"必须先停止", @"参数错误", @"不支持", @"启动失败", @"请求编号冲突"];
    [self log:[NSString stringWithFormat:@"应答 #%u：命令 0x%02x，%@，state=%u，profile=%u，stream=%u，detail=%d",
        header.sequenceID, reply.command, results[reply.result], reply.state, reply.profile, header.streamID, (int)reply.detail]];
    [self publish]; return YES;
}
- (BOOL)handleConfig:(NSData *)body header:(GXVPMessageHeader)header {
    GXVPVideoConfig config;
    if (_state != GXVPRunning || header.streamID != _streamID || _configured ||
        !GXVPReadConfig(body.bytes, body.length, &config) ||
        (_profile == 1 && config.width != 1280) || (_profile == 2 && config.width != 1920)) {
        [self fail:@"VIDEO_CONFIG 无效或与 START 档位不一致。"] ; return NO;
    }
    _config = config; _configured = YES;
    [_pipeline configure:config streamID:header.streamID];
    [self log:[NSString stringWithFormat:@"配置：%u×%u / %u fps，%.2f Mbps，等待硬解首帧。",
        config.width, config.height, config.fpsNumerator, config.bitrate / 1000000.0]];
    [self publish]; return YES;
}
- (void)timerFired {
    CFTimeInterval now = CACurrentMediaTime();
    for (GXPendingCommand *item in _pending.allValues) {
        if (now > item.deadline) {
            [self fail:@"控制应答超时，已断开以清理设备状态；重新连接后再试。"] ; return;
        }
    }
    NSDictionary *stats = [_pipeline statistics];
    uint64_t generation = [stats[@"generation"] unsignedLongLongValue];
    uint64_t received = [stats[@"received"] unsignedLongLongValue], bytes = [stats[@"bytes"] unsignedLongLongValue];
    uint64_t decoded = [stats[@"decoded"] unsignedLongLongValue], displayed = [stats[@"displayed"] unsignedLongLongValue];
    if (_lastReport > 0 && generation == _reportGeneration && now > _lastReport) {
        double seconds = now - _lastReport;
        _receiveFPS = (received >= _reportReceived ? received - _reportReceived : 0) / seconds;
        _receiveKbps = (bytes >= _reportBytes ? bytes - _reportBytes : 0) * 8 / seconds / 1000.0;
        _decodeFPS = (decoded >= _reportDecoded ? decoded - _reportDecoded : 0) / seconds;
        _displayFPS = (displayed >= _reportDisplayed ? displayed - _reportDisplayed : 0) / seconds;
    } else _receiveFPS = _decodeFPS = _displayFPS = _receiveKbps = 0;
    _lastReport = now; _reportGeneration = generation;
    _reportReceived = received; _reportBytes = bytes; _reportDecoded = decoded; _reportDisplayed = displayed;
    [self publish];
}
@end
