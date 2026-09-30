# 清听

<img src="Design/AppIcon-mac-1024.png" width="128" alt="清听图标">

把 Mac 或 iPhone 麦克风收到的声音实时降噪，只保留人声，再通过蓝牙送到 MFi 助听器里。为坐在教室里听远处老师讲课而做。

所有处理都在本机完成，不联网。

> 清听不是医疗器械，不能替代助听器验配，也不保证改善听力。输出端有限幅器，但请从小音量开始试。

## 功能

- **多种降噪引擎可选**：DeepFilterNet 3（默认，适合远处的人声）、DeepFilterNet 低延迟版、RNNoise、Apple 语音隔离（两种模式）、不降噪
- **自动调参**：每秒分析最近 8 秒的收音，估计人声信噪比和高频情况，自动设置降噪强度和清晰度
- **自动音量**：只在有人说话时测量响度，把忽大忽小的人声拉平，停顿时不放大底噪
- **清晰度**：强调 2 kHz 以上的辅音
- **保存最近 30 秒**：同时存原始收音和处理后的声音，用来分析问题
- **iPhone 版**：锁屏继续工作；灵动岛和锁屏显示收听状态，可一键停止；助听器断开时自动停止，防止扬声器啸叫
- **离线对比工具**：把一段录音用各个引擎分别处理，输出音频和指标

## 处理流程

```
麦克风 → 低切 250 Hz → 降噪引擎 → 清晰度 EQ → 自动音量 → 压缩 → 限幅 → 助听器
```

- 收音不是 48 kHz 时（有的 iPhone 连上助听器后只有 16 kHz），先整数倍升采样到 48 kHz 再降噪
- 降噪在独立的实时优先级线程里做，和音频设备的回调之间用无锁环形缓冲衔接，缓冲余量会根据卡顿情况自适应

## 目录

| 路径 | 内容 |
|---|---|
| `Sources/Shared` | 两个平台共用：降噪引擎封装、处理链、自动音量、现场分析、环形缓冲、声纹显示 |
| `Sources/Mac` | Mac 版：音频设备、双引擎管线、界面、离线工具 |
| `Sources/iOS` | iPhone 版：音频会话、管线、界面、实时活动控制 |
| `Sources/Widget`、`Sources/LiveActivity` | 灵动岛 / 锁屏实时活动 |
| `Patches` | 对 DeepFilterNet 的改动（补丁）和锁定的依赖版本 |
| `Design` | 图标和绘制图标的代码 |

## 构建

需要 Apple 芯片的 Mac、Xcode、Rust（`rustup`）和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

```bash
# 1. 准备第三方降噪库（下载、打补丁、编译，只需一次，约 3GB）
./setup-deps.sh

# 2. Mac 版，产物在 build/清听.app
./build.sh

# 3. iPhone 版：先在 local.env 里写上自己的开发者团队 ID
echo 'QINGTING_TEAM_ID=你的团队ID' > local.env
./install-ios.sh      # 编译并装到已连接的 iPhone 上
```

iPhone 版说明：

- 需要在 Xcode → Settings → Accounts 里登录 Apple ID；免费账号签的 App 7 天后要重装一次
- 手机用数据线配对过一次后，和 Mac 在同一个局域网（比如手机的个人热点）里也能无线安装
- 包名在 `project.yml` 里（`PRODUCT_BUNDLE_IDENTIFIER`），自己用时改成自己的

## 命令行工具

Mac 版的可执行文件带两个不需要界面的模式：

```bash
APP=build/清听.app/Contents/MacOS/QingTing

# 离线对比：用每个引擎处理一段录音，输出 wav 和指标
$APP --offline 录音.wav --out 输出目录 [--mode classroom] [--strength 0.5] [--engines deepFilter,rnnoise]

# 实时自检：跑几秒，打印电平、缓冲和卡顿计数（会往输出设备放音）
$APP --selftest 5 [--engine deepFilter] [--in 麦克风名] [--out 输出设备名]
```

运行日志：Mac 在 `~/Library/Logs/QingTing.log`，iPhone 在「文件」App → 我的 iPhone → 清听。

## 已知限制

- 延迟：Mac 约 120–130 ms，iPhone 约 80–100 ms（全向麦克风）。助听器自己的麦克风也在收音时，两份声音会有重影，建议在助听器 App 里调低串流时的环境麦克风比例
- 单麦克风降噪主要改善听感舒适度；老师很远、教室很吵时，能提升的清晰度有限
- iPhone 的指向收音模式实测会让声音变小、变闷，延迟多约 30 ms，默认关闭
- 灵动岛里的声纹每秒刷新一次（系统不允许第三方 App 连续动画）

## 第三方

- [DeepFilterNet](https://github.com/Rikorose/DeepFilterNet)（MIT / Apache-2.0）：降噪模型和推理库，本项目加了增益释放平滑的补丁
- [RNNoise](https://github.com/xiph/rnnoise)（BSD-3-Clause）
- Apple `AUSoundIsolation`：系统自带的语音隔离

## 许可

本项目自己的代码以 [MIT 许可](LICENSE) 开源。第三方库按各自的许可使用，见上。
