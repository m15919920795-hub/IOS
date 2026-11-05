# GX 摄像板 iOS 客户端 V0.1.0

Objective-C / UIKit 工程，对接当前 BK7259 `camera_tcp_example` 的 **GXVP v1** 固件。TCP 使用 GCDAsyncSocket，H.264 使用 VideoToolbox 硬件解码，解码图像使用 AVSampleBufferDisplayLayer 显示。工程不依赖 FFmpeg、FFplay、RTSP 或 CocoaPods。

## 2026-11-05 人形识别端口

新增独立 **TCP 5601 / 逐行 JSON v1**。点击主“连接”时，同时连接视频 5600 和识别 5601；识别连接失败不影响视频，可点击“识别重连”。“人形识别”开关控制板端取帧/推理，不控制视频。板端默认开启，每 300 ms 启动一次检测，视频未 START 时等待输入。

竖屏显示最新人数、推理时间及首框置信度、视频像素坐标。无人时人数归零，错误与无人分开显示；开关、流编号、代次变化时清除旧结果。横屏隐藏详细统计，保留开关和视频。

视频上以绿色矩形叠加所有有效人框，使用 `video_x/video_y/video_w/video_h`，按实际视频图像的缩放与居中位置映射到屏幕，支持竖横屏、720p/1080p 及黑边；坐标映射也兼容等比填充时的中心裁切。检测层独立于视频像素，不拷贝或重新编码视频。无人、检测失败、关闭识别、停止视频、断开连接或切换视频流时清框，超过 1.5 秒未收到新的界面检测结果也隐藏旧框。只在视频已有画面且流编号、视频尺寸、识别代次匹配时显示。识别约每 300 ms 更新一次，按最新结果更新框，移动时可能有滞后；检测序号不对应 H.264 帧号，叠框不代表逐帧同步。

`Network/GXPersonClient.h/.m` 使用单独的 GCDAsyncSocket 和串行队列，按 LF 读取，单条上限 8192 字节；校验 JSON 后只保留最新结果，主线程更新合并，避免 UI 积压。delegate 状态的 `result` 字典保留全部 boxes，供后续业务使用。其 `seq` 是检测序号，不是 H.264 帧编号。关闭成功应答后不再接受旧代结果，关闭 App/识别连接不自动改变板端 enabled。

随包 `PERSON_TCP_V1_REFERENCE.md` 给出完整协议，只有新固件提供 5601。旧固件仍可播放视频，但识别端口会连接失败。本次工程结构、视频 C 核心测试及 25 项框坐标映射测试通过；新增 Objective-C 叠框尚未在 Xcode 编译或真机验证。

## 在 Xcode 运行

1. 将 **整个 `GXCameraViewer` 目录**复制到 Mac，或解压提供的源码 ZIP。不要只复制 `.xcodeproj`。
2. 用 Xcode 15 或以上打开 `GXCameraViewer.xcodeproj`，等待自动解析 Swift Package。已配置 CocoaAsyncSocket **7.6.5 精确版本**，首次解析需要 Mac 能访问 GitHub。项目自身全为 Objective-C/C；Swift Package Manager 只负责依赖管理。
3. 选择 `GXCameraViewer` Target → Signing & Capabilities → 选择自己的 Team。Bundle Identifier 默认 `com.guanxukeji.GXCameraViewer`，如有签名冲突可改为自己的唯一值。
4. 选择 **iPhone/iPad 真机，iOS 17 或以上**，点击 Run。开发签名、设备信任及 Developer Mode 按 Xcode 提示处理。
5. 在手机系统 Wi-Fi 设置中连接无密码热点 **GX-7259**。保持使用该热点，即使系统提示无互联网。关闭电脑端测试客户端，设备当前只允许一个活动 TCP 客户端。
6. App 默认地址 **192.168.188.1:5600**，点击“连接”。首次弹出“本地网络”权限时选择允许；若首次授权耗时导致超时，再点一次连接。
7. 选择 **720p · 25 fps** 或 **1080p · 20 fps**，点击“开始”。换档位必须先点“停止”，等待“空闲”后再选择另一档并开始。

**连接不自动播放，断线不自动开始，返回前台不自动恢复视频。** 本版进入后台主动断开，设备据此回收视频资源。画面保持原始横向比例，支持竖屏、横屏和 iPad；旋转不重启视频。

模拟器可以检查界面、网络和协议，但不能用来验证本项目要求的硬件解码。若系统不能创建或确认硬件解码会话，App 会停止视频并记录错误，不切换软件解码。

## 按钮与统计

| 功能 | 行为 |
|---|---|
| 连接 / 断开 | GCDAsyncSocket TCP；连接后先 GET_STATUS |
| 开始 | START，携带档位及 H.264 编码类型 |
| 停止 | STOP；立即清本地旧画面，收到成功应答后才能再次 START |
| 状态 | GET_STATUS，显示设备状态及 StreamID |
| 关键帧 | REQUEST_IDR，至多每秒一次 |
| 接收 / 硬解 / 显示帧率 | 最近约一秒统计；“显示”指提交到系统显示图层，不是物理屏幕扫描计数 |
| 丢弃 / 替换 | 丢弃为解码前丢帧/恢复；替换为解码后旧待显示图像被最新图像替换，二者都不能当作 TCP 丢包率 |

两档目标码率来自板端 CONFIG，当前均为 **2 Mbps**。连接地址和端口支持修改、保存在 App 本地。

## 接收、硬解与显示路径

```text
GCDAsyncSocket 内部 socket 队列
    → 独立串行网络 delegate 队列（按 32 字节头和 PayloadLength 完整读体）
    → 最多 3 帧 H.264 待解码队列
    → 串行解码队列（VideoToolbox，同步提交一帧，不启用时序重排）
    → CVPixelBuffer 最新图像槽（最多 1 帧）
    → 主线程 CADisplayLink + 系统 AVSampleBufferDisplayLayer
```

- 严格校验魔数、版本、方向、标志、头/体长度、流编号和应答编号。单帧体上限 **512000 字节**，不会按未验证的长度分配。
- GCDAsyncSocket 的定长读负责 TCP 半包/粘包；网络线程不等待解码和主线程。
- 收到首个完整 SPS/PPS/IDR 后，提取参数集，构造四字节 NAL 长度前缀的 AVCC sample，创建 VideoToolbox 会话。
- 要求硬件加速并查询实际硬解状态；使用 NV12/IOSurface 像素缓冲，避免把每帧转换成 UIImage 或在 CPU 上拷贝整幅 BGRA 图像。
- 解码器不开异步或 temporal processing 标志：回调在 DecodeFrame 返回前完成，一次只提交一帧，避免硬解内部无限排队。该调用只在独立解码线程执行。
- 未开始解码的帧在本地等待超过 **200 ms**、队列满、序号中断或源端不连续时，清队列并等待 SPS/PPS/IDR；不会丢 P 帧后继续解码相关 P 帧。
- 到达偏移相对本流最小值超过 **300 ms** 时，丢弃旧输入、请求关键帧恢复。未进行设备/手机时钟同步，该偏移不是端到端延迟。
- 系统图层接收已解码图像，设置 `kCMSampleAttachmentKey_DisplayImmediately`，不按板端时间戳排播放时钟。iOS 17 及以上使用 `sampleBufferRenderer`，源码保留 iOS 15/16 的图层兼容分支；工程的最低运行版本仍设为 iOS 17。
- 主线程暂停时新图像替换旧图像，恢复后不补播显示队列。TCP、系统渲染和硬件仍可能引入时延，200 ms 是局部年龄策略。
- STOP、重连和档位切换都有 generation 隔离，旧硬解输出和旧代故障不会污染新流。

## 文件职责

| 路径 | 职责 |
|---|---|
| `GXCameraViewer/App/` | App 入口、Window 和控制器安装 |
| `GXCameraViewer/Core/GXVPWire.c/.h` | 可在主机运行的协议校验、请求封装、Annex-B NAL 扫描 |
| `GXCameraViewer/Core/GXVideoGeometry.c/.h` | 视频像素框到视图坐标的等比缩放、居中和裁剪，可在主机测试 |
| `GXCameraViewer/Network/GXCameraClient.m` | GCDAsyncSocket、请求编号/匹配、启停状态、超时、断线清理、统计 |
| `GXCameraViewer/Video/GXVideoPipeline.m` | 有界输入队列、帧龄/参考链恢复、流代隔离 |
| `GXCameraViewer/Video/GXH264Decoder.m` | SPS/PPS、AVCC sample、VideoToolbox 硬件会话 |
| `GXCameraViewer/Video/GXVideoView.m` | 最新像素缓冲槽、DisplayLink、系统显示图层及人形框叠加层 |
| `GXCameraViewer/UI/GXCameraViewController.m` | 中文界面、按钮状态、设置和日志 |
| `tools/check_macos.sh` | Mac 上解析依赖并编译真机目标（不签名） |
| `tools/test_core.sh` | 协议对照、内存边界及检测框映射测试；仓库中使用真实板端源码，独立包中使用随附协议快照 |
| `tools/check_project.py` | 不依赖 Xcode 的工程引用、资源、Scheme 和源文件清单检查 |

## 已检查与待真机确认

2026-11-04 在当前 Linux 环境完成：

- 与**现有板端真实协议源码**对照的 START 两档、STOP、STATUS、REQUEST_IDR 编码测试通过。
- 设备消息头、大端/64 位时间戳、CONFIG、带符号错误码、方向/长度边界、非法 Annex-B、混合三/四字节起始码、截断及随机输入边界测试通过；运行 AddressSanitizer 和 UndefinedBehaviorSanitizer。当前工具的 ptrace 限制不支持 LeakSanitizer，因此该次运行关闭了泄漏检查。
- Xcode 工程结构、文件引用、资源 JSON、Info.plist、共享 Scheme 静态校验通过。

**本环境没有 macOS/iOS SDK，尚未执行 Xcode 编译、SPM 解析或 iPhone 真机播放，不能把主机测试当作已经在 iPhone 上通过。** Mac 上可先运行：

```sh
bash tools/check_macos.sh
```

这会解析 CocoaAsyncSocket 并编译 generic iOS target，关闭签名，只验证构建。实际安装请选择 Team 并在 Xcode Run。

首轮真机请依次验证：连接后空闲 → 720p 开始 → 停止 → 1080p 开始 → 停止 → 多轮重复 → 旋转/操作界面 → 断开重连 → 进入后台再返回。查看接收/硬解/显示帧率及 Xcode 日志；帧率和“相对到达偏移”均不替代拍摄计时器等光学端到端延迟测量。

叠框真机检查：单人及多人检测均显示框 → 横竖屏旋转后仍对齐实际图像 → 人离开、关闭识别或停止视频后旧框消失 → 720p/1080p 切换及断线重连不保留旧流框。识别数据停止更新超过 1.5 秒时，旧框应隐藏；恢复新结果后重新显示。框会跟随约 300 ms 一次的识别结果，移动目标与视频可能有时间差。

## 常见问题

- **连不上**：确认手机确实连接 GX-7259，电脑客户端已退出，地址 192.168.188.1/端口 5600 未变；设置 → 本 App → 本地网络中允许访问。
- **协议头错误**：当前客户端对应 GXVP v1，不兼容早期直接发送 RAW H.264 的固件。
- **无法解析 CocoaAsyncSocket**：首次构建需要 Mac 能访问 GitHub。Xcode File → Packages → Resolve Package Versions；无需另行执行 pod install。
- **START 成功但硬解失败**：记录错误码和完整日志。既有板端样本的 SPS `level_idc=13` 与 720p/1080p 规格可能不相符，软件能解码不代表所有硬件都接受。客户端保留原始参数，不盲目改写 SPS；需要真机判断是否必须在板端修正声明。
- **暂停/切后台后不恢复**：本版设计为主动断开，回来后手动连接及开始。
- **显示帧率略低于接收**：系统可能替换旧画面、刷新受阻或解码帧已过期；先结合硬解帧率、队列、丢弃计数判断。

## 本版范围与参考

本版提供实时视频、已有 GXVP 控制及 TCP 人形识别控制和人框叠加。UDP/UART、录制、音频、自动加入热点、RTSP、MJPEG尚未加入；本次 iOS 叠框修改未改动嵌入式源码和固件。

- [GXVP v1 固件协议快照](GXVP_V1_REFERENCE.md)（来源：仓库 `camera_tcp_example/GXVP_V1.md`）
- [CocoaAsyncSocket 官方项目与安装方式](https://github.com/robbiehanson/CocoaAsyncSocket)
- [VideoToolbox：要求硬件解码](https://developer.apple.com/documentation/videotoolbox/kvtvideodecoderspecification_requirehardwareacceleratedvideodecoder)
- [VideoToolbox：同步/异步解码标志](https://developer.apple.com/documentation/videotoolbox/vtdecodeframeflags/kvtdecodeframe_enableasynchronousdecompression)
- [CoreMedia：立即显示图像](https://developer.apple.com/documentation/coremedia/kcmsampleattachmentkey_displayimmediately)
- [AVFoundation：iOS 17 起的显示提交接口](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/enqueue(_:))
