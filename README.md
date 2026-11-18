# ⚡️ MetalCast

> **macOS 原生专享的极速 Android 投屏与控制工具**  
> 抛弃 Qt 与 FFmpeg 重型跨平台包袱，基于 **Swift + SwiftUI + AppKit + VideoToolbox + Metal** 全栈重构，打造专属于 Mac 生态的一等公民体验。

---

## ✨ 核心特性

- 🚀 **全硬件加速与零拷贝架构**
  - **Apple VideoToolbox 硬解**：直接将 Android H.264 码流解包为原生 `CVPixelBuffer (NV12)`。
  - **Metal 0-Copy 极速渲染**：借助 `CVMetalTextureCache` 实现统一内存零拷贝映射，搭配定制 BT.709 MSL 矩阵着色器，CPU 占用极低（~3%-5%），端到端延迟低至 **~35ms**。
- 🖥️ **100% 纯净视窗与独立停靠栏**
  - 操作栏完全移出手机投屏显示区，绝不遮挡游戏技能、背包或底部导航。
  - **支持右侧独立停靠栏与底部独立停靠栏**一键平滑切换（点击 `⇄` 按钮）。
  - 支持 **`Cmd + T`** 随时一键折叠/唤出侧边栏，享受全面沉浸体验。
- 📱 **物理息屏控制（省电降温）**
  - 投屏期间一键熄灭手机物理屏幕（🌙），Mac 端画面与操作保持畅通，大幅减少手机发热与功耗。
- 📋 **双向剪贴板实时无感同步**
  - Mac 复制文本即刻静默同步到手机，手机复制文本瞬间同步回 Mac `NSPasteboard`。
- 📦 **拖拽安装与文件推流**
  - 直接拖拽 `.apk` 安装包进视窗，ADB 自动静默安装并实时提示结果。
  - 拖拽任意图片、文档或音视频，极速推流保存到 `/sdcard/Download/`。
- ⌨️ **丰富原生快捷键与触控手势**
  - 支持 Mac 触控板双指平滑无级滚动。
  - 鼠标右键默认触发 Android `返回 (Back)`。
  - 键盘快捷键全面对齐 macOS 肌肉记忆。

---

## ⌨️ 常用快捷键速查

| 快捷键 | 功能说明 |
| :--- | :--- |
| `Cmd + B` / `Esc` / `鼠标右键` | **返回键 (Back)** |
| `Cmd + H` | **回到桌面 (Home)** |
| `Cmd + S` | **多任务后台 (Recents)** |
| `Cmd + T` | **收起 / 展开独立操作工具栏** |
| `Cmd + Shift + P` | **熄灭 / 点亮手机物理屏幕** |
| `Cmd + Shift + S` | **纯净高清截图**（仅截取手机画面并写入剪贴板及桌面） |
| `Cmd + ↑` / `Cmd + ↓` | **音量增加 / 音量减小** |

---

## 📂 源码模块结构

```text
metal-cast/
├── Package.swift               # Swift Package 模块定义文件
├── build_app.sh                # Release 原生应用一键打包脚本
├── Resources/                  # 内置通用架构二进制依赖
│   ├── adb                     # Universal adb (x86_64 + arm64)
│   └── scrcpy-server           # scrcpy 协议服务端 JAR
├── Sources/
│   ├── MetalCastCore/          # 核心通信协议、ADB 进程与二进制消息编解码
│   │   ├── ADB/                # ADB 进程派生与多设备扫描管理
│   │   ├── Network/            # Network.framework TCP 会话与包头切分
│   │   └── Protocol/           # scrcpy 控制指令与状态事件序列化
│   ├── MetalCastMedia/         # 0-Copy 音视频解码与渲染流水线
│   │   ├── Parser/             # Annex-B NALU 切分与 SPS/PPS 动态重构
│   │   ├── Decoder/            # VideoToolbox 硬解会话管理
│   │   ├── Render/             # Metal MTKView 与 CVMetalTextureCache 渲染器
│   │   └── Shaders.metal       # NV12 ➔ sRGB BT.709 Metal 片段着色器
│   ├── MetalCastCLI/           # 命令行极速验证与网络帧率统计工具
│   └── MetalCastApp/           # 完整 macOS App 交互与图形窗口
│       ├── DashboardView.swift # 控制中心主面板 (SwiftUI)
│       ├── MirrorWindowController.swift # 独立视窗与动态比例保持
│       ├── MirrorMTKView.swift # 手机视窗与手势拖拽注入
│       ├── CapsuleToolbarView.swift # 独立停靠操作侧边栏 (DockToolbar)
│       ├── ClipboardManager.swift # 双向剪贴板无感同步监控器
│       └── SessionManager.swift # 投屏全生命周期管理中枢
└── docs/
    ├── ARCHITECTURE_AND_PLAN.md # 深度架构设计与各阶段落地演进计划
    └── prototype/               # 原型交互演示 (HTML 可交互预览)
```

---

## 🛠️ 构建与运行指南

### 环境要求
- **操作系统**：macOS 13.0 (Ventura) 及以上
- **处理器架构**：Apple Silicon (M1/M2/M3/M4) 或 Intel Mac
- **构建工具**：Xcode 14.0+ / Swift 5.9+

### 1. 一键编译并打包 Release 应用（推荐）
```bash
./build_app.sh
```
编译成功后，将在 `output/` 目录下生成独立的 **`MetalCast.app`**。你可以直接运行：
```bash
open output/MetalCast.app
```
也可以直接将 `MetalCast.app` 拖入 `/Applications` 应用程序目录中日常使用。

### 2. 命令行快速烟测与流诊断
```bash
swift run metalcast-cli
```

### 3. 开发环境即时运行
```bash
swift run MetalCastApp
```

---

## 🗺️ 后续路线图 (Roadmap)

- [x] **M1**: 架构脚手架与 ADB 进程管理、scrcpy 协议打通
- [x] **M2**: Annex-B 语法分析与 VideoToolbox + Metal NV12 零拷贝硬解渲染
- [x] **M3**: macOS 原生交互上屏与右侧独立停靠工具栏
- [x] **M4**: 双向剪贴板同步、文件/APK拖拽静默安装、物理息屏控制
- [ ] **M5**: FPS 射击游戏按键映射宏与鼠标锁定视角控制 (`CGEventTap` + `CGWarpMouseCursorPosition`)
- [ ] **M6**: 多设备群控、多窗口同屏与无线 Wi-Fi 自动保活发现

---

## 📄 开源许可

本项目遵循 MIT 开源协议。
