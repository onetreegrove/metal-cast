# MetalCast 手机文件管理实现方案

## 方案 2 · 纯 Swift ADB Sync 首版

从 MetalCast 控制中心选择已连接且授权的 Android 设备，打开独立的「手机文件」窗口。首版支持浏览共享存储、批量上传和下载普通文件、逐项删除普通文件。USB 和已配对的 Wi‑Fi 设备使用同一条调用链，文件窗口可以在投屏前打开，也可以在投屏结束后继续使用。

文件操作由 Swift 通过 `Network.framework` 连接当前设备列表所用的本地 ADB Server。目录与文件读写走 `sync:`，路径检查、上传提交和删除走 `shell,v2,raw:`。设备发现、无线配对、投屏和 ADB Server 启动继续使用仓库内置的 `adb`。文件操作的正常路径无需启动 Mac 上的 `adb` 子进程。

### 首版范围

| 操作 | 行为 |
| --- | --- |
| 浏览 | 从设备的 `/sdcard` 打开共享存储。优先显示 `Download`，该目录不可用时回到共享存储根。支持逐级进入、返回、面包屑和刷新。列表显示名称、类型、大小和修改时间。 |
| 上传 | 用系统打开面板多选 Mac 上的普通文件，上传到当前目录。同名时可跳过或保留两份。文件窗口中的 APK 按普通文件上传。 |
| 下载 | 多选手机上的普通文件，通过系统面板选择 Mac 目标目录。同名时可跳过或保留两份。 |
| 删除 | 只删除当前目录所选的普通文件。永久删除前显示设备名、目录、文件名和数量，执行后逐项报告结果。 |

首版运行环境基线为 **macOS 13+** 与 **Android 7.0+**（要求设备支持 `shell_v2`），并交付控制中心入口。投屏工具栏入口、投屏窗口拖拽迁移、目录递归操作、覆盖替换、回收站、重命名、新建目录、预览、容量统计和媒体库刷新另列后续；因首版不主动触发媒体库刷新，Android 10 及更早或部分机型上传至 `DCIM`、`Pictures` 等目录后，系统相册可能不会立即可见，留待后续版本补齐。共享存储仅支持已验证的主共享卷，将 `Android/data`、`Android/obb`、外置 SD 卡、工作资料和其他用户存储排除在首版范围外（具体拦截规则见第 3 节）。

#### Android 版本与能力兼容性预期

| 设备代际 | `shell_v2` | `stat_v2` / `ls_v2` | 提交命令预期 | 存储栈与典型限制 |
| --- | --- | --- | --- | --- |
| Android 7.0 – 10 | 支持（若自定义阉割缺失则拒绝） | 部分机型仅支持 v1 (`STAT`/`LIST`) | 旧版 Toybox 可能缺少 `-T`，自动降级 `mv -n` 护栏 | `sdcardfs` 大小写不敏感；上传媒体文件后相册通常需系统下次扫描才可见 |
| Android 11 – 15+ | 支持 | 普遍支持 `STA2`/`LST2`/`LIS2` | 普遍支持 `mv -nT` | MediaProvider FUSE；严格禁止 `? " * : < > \ \|` 及换行；`Android/data`、`Android/obb` 强制隔离 |

---

## 1. 模块、数据模型与设备绑定

| 模块 | 实现职责 |
| --- | --- |
| `MetalCastCore/ADB/ADBServerEndpoint.swift` | 解析并统一 CLI 与 Socket 共用的本地回环端点（默认 `127.0.0.1:5037`），校验环境变量兼容性与子进程环境清洗规则。 |
| `MetalCastCore/ADB/Sync/ADBSocketConnection.swift` | `NWConnection` 生命周期、跨包精确读写、阶段超时、并发 `start-server` 合并、Host 握手及 `host:transport-id:<id>` 绑定。 |
| `MetalCastCore/ADB/Sync/ADBSyncClient.swift` | Sync v1/v2 帧编解码、`features` 能力解析、目录枚举、属性查询、64 KiB 分块收发与 `QUIT` 收尾。 |
| `MetalCastCore/ADB/Sync/ADBShellClient.swift` | Shell v2 帧解析（含超长命令经 stdin 投喂）、内部固定 POSIX Shell 模板、路径转义与退出码映射。 |
| `MetalCastCore/ADB/ADBFileService.swift` | `actor` 状态机、设备会话绑定、边界与字符校验、设备写队列、全局 2 槽位传输调度、冲突重命名与清理账本持久化。 |
| `MetalCastApp/FileManager/` | `FileManagerWindowCoordinator`、`FileManagerWindowController`、`FileManagerViewModel` 和 `FileManagerView`。`MainActor` 管理单设备单窗口生命周期与界面状态，I/O 与协议解析全部运行在后台。 |

### 1.1 统一端点（`ADBServerEndpoint` 与 `ADBProcessRunner`）

1. **端点解析优先级与白名单：**
   1. 显式传入的自定义本地端点（如测试或未来偏好设置）。
   2. `ADB_SERVER_SOCKET`：仅接受 `tcp:<loopback>:<port>`；若为 `localfilesystem:`、非本地回环主机或非法端口，抛出 `ADBFileError.incompatibleEndpoint`。
   3. `ANDROID_ADB_SERVER_ADDRESS` 与 `ANDROID_ADB_SERVER_PORT`：主机仅允许 `127.0.0.1`、`localhost` 或 `::1`（为空时默认 `127.0.0.1`），端口须在 `1...65535`（为空时默认 `5037`）；若二者与 `ADB_SERVER_SOCKET` 同时存在且冲突，抛出 `ADBFileError.incompatibleEndpoint`。
   4. 未配置上述变量时回退默认值 `127.0.0.1:5037`。
2. **CLI 统一参数与环境清洗：**
   - 所有通过 `ADBProcessRunner` 启动的 `adb` 子进程（包括 `run(args:)` 与供投屏 `executeServer` 使用的 `spawn(args:onOutput:)`）统一前置参数 `["-L", "tcp:\(endpoint.host):\(endpoint.port)"]`。
   - `Process.environment` 默认为 `nil`（直接继承父进程环境），因此启动子进程前必须先复制 `ProcessInfo.processInfo.environment` 为可变字典，从中移除 `ADB_SERVER_SOCKET`、`ANDROID_ADB_SERVER_PORT`、`ANDROID_ADB_SERVER_ADDRESS` 后再赋值给 `process.environment`，避免原生 `adb` 在同时存在 `-L` 与 `ADB_SERVER_SOCKET` 时报错退出，确保投屏、`adb devices` 与 Socket 文件通道永远连接同一 ADB Server。
   - 若 `resolveAdbPath()` 未找到可用 `adb` 可执行文件，应明确抛出错误或通过 `PATH` 解析真实路径，避免将裸字符串 `"adb"` 传入 `URL(fileURLWithPath:)`。
3. **`ADBProcessRunner.run(args:)` 非阻塞改造：**
   - 保留现有 `Pipe.readabilityHandler` 异步流式读取，移除阻塞 Swift Concurrency 协作线程池的 `process.waitUntilExit()`。
   - 改用 `withTaskCancellationHandler` 包裹 `withCheckedThrowingContinuation`，在 `process.terminationHandler` 中完成管道余量刷新与唯一一次 continuation resume（使用 `NSLock` 保护完成状态）；外部 Task 取消时主动调用 `process.terminate()`。 [ADBProcessRunner.swift](../Sources/MetalCastCore/ADB/ADBProcessRunner.swift)
4. **并发 `start-server` 合并：**
   - 当 `ADBSocketConnection` 连向本地端点收到 `ECONNREFUSED` 时，在 `ADBFileService` 内部按端点合并并发的 Server 启动请求：共享同一个在途 `start-server` Task，复用现有 `ADBProcessRunner` 执行一次 `adb start-server` 后再重连一次。
   - 协议格式错误、设备未授权（`unauthorized`）或传输中途断线不触发自动重启 Server，直接进入各自错误处理路径。

### 1.2 固定设备、列表标识对齐与单设备单窗口

1. **设备列表标识对齐：**
   - 在 `ADBDevice` 中保留 `serial`，新增稳定列表选中标识（如 `var selectionKey: String { transportId.map { "tid:\($0)" } ?? "serial:\(serial)" }`）。
   - 同步对齐 `SessionManager.refreshDevices()` 与 `DashboardView` 列表 `id` / `selection` 匹配逻辑，消除同一 `serial` 出现多条记录（如旧 `offline` 残留叠加新连接）时控制中心选中项与文件窗口绑定的错位风险。 [ADBDevice.swift](../Sources/MetalCastCore/ADB/ADBDevice.swift) · [SessionManager.swift](../Sources/MetalCastApp/SessionManager.swift) · [DashboardView.swift](../Sources/MetalCastApp/DashboardView.swift)
2. **单设备单窗口与设备固定：**
   - 控制中心仅对 `device.state == .device` 且具备有效 `transportId` 的设备开放「手机文件」入口；缺失 `transportId` 时提示需要升级或重新初始化连接。
   - 由 `@MainActor` 单例或管理器 `FileManagerWindowCoordinator` 持有 `[String: FileManagerWindowController]`（键为设备绑定标识）。每台设备会话至多打开一个文件窗口；重复点击入口时直接调用已有窗口的 `showWindow(nil)` 与 `makeKeyAndOrderFront(nil)` 置前，关闭窗口后移除字典引用。
   - 窗口打开时固化 `deviceName`、`serial`、`transportId` 与当次 `ADBFileSessionID`。之后每个操作连接均发送 `host:transport-id:<id>` 绑定设备，能力查询在独立 Host Socket 发送 `host-transport-id:<id>:features`。控制中心刷新或切换选中设备时，绝不改变已打开窗口所绑定的目标设备。 [AOSP transport 选择与能力查询](https://android.googlesource.com/platform/system/core/+/a49d024/adb/client/adb_client.cpp#316)

### 1.3 设备跟踪与会话代次

1. **跟踪通道与降级：**
   - 在后台建立长连接向本地 ADB Server 发送 `host:track-devices-l`，持续循环读取「4 位十六进制长度 + UTF‑8 设备明细列表」（长度为 `0000` 表示当前无设备）。
   - 仅当旧版自定义 ADB Server 对 `host:track-devices-l` 返回 `FAIL` 时，降级为建立 `host:track-devices` 长连接；每次收到推送后，再在同一端点通过独立 Host Socket 发送 `host:devices-l` 读取完整明细（不启动 `adb` CLI 子进程）。
   - 控制中心 `SessionManager` 直接消费同一条设备跟踪快照（并在用户点击刷新时触发一次即时 `host:devices-l` 与无线 mDNS 扫描），避免文件窗口与控制中心对设备在线状态、`transportId` 的感知出现分叉。 [AOSP 设备跟踪服务](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/dev/services.md)
2. **会话代次（`serverGeneration`）与失效策略：**
   - 每次跟踪通道首次连通、断线重连成功或触发 `start-server` 后，`serverGeneration: UInt64` 单调递增。
   - 会话标识 `ADBFileSessionID` 由 `(endpoint, serverGeneration, transportId, serial)` 四元组构成。
   - 一旦跟踪通道中断、Server 重启导致 `serverGeneration` 变化、目标 `transportId` 消失或状态离开 `.device`，立即将旧 `ADBFileSession`、其能力缓存及该会话尚未进入提交阶段的排队操作置为失效；文件窗口保持打开并切换至「设备已断线」状态，禁止自动迁移到同 `serial` 的新 `transportId`，须由用户点击「重新连接并核对」或重新打开确认后再恢复浏览，旧传输和删除均由用户重新发起。

### 1.4 核心 Swift 数据模型与 `ADBFileService` 接口草案

```swift
public struct ADBServerEndpoint: Hashable, Sendable, Codable {
    public let host: String      // 仅本地回环: "127.0.0.1" / "localhost" / "::1"
    public let port: UInt16      // 默认 5037
    public var cliAddressArgument: String { "tcp:\(host):\(port)" }
}

public enum ADBCommitMode: String, Sendable {
    case mvNoClobberNoTarget     // 首选: mv -nT -- <tmp> <dst>
    case mvNoClobberWithGuard    // 降级: [ ! -e ] && [ ! -L ] && mv -n -- <tmp> <dst>
    case unsupported             // 缺少 mv -n，禁止上传
}

public struct ADBDeviceCapabilities: Sendable, Equatable {
    public let hasShellV2: Bool
    public let hasStatV2: Bool
    public let hasLsV2: Bool
    public let commitMode: ADBCommitMode
}

public struct ADBFileSessionID: Hashable, Sendable, Codable {
    public let endpoint: ADBServerEndpoint
    public let serverGeneration: UInt64
    public let transportId: String
    public let serial: String
}

public enum ADBRemoteEntryKind: String, Sendable {
    case regular, directory, symlink, other
}

public struct ADBRemoteEntry: Identifiable, Hashable, Sendable {
    public let rawNameBytes: Data
    public let displayName: String
    public let isLosslessUTF8: Bool
    public let kind: ADBRemoteEntryKind
    public let size: UInt64?
    public let isSizeReliable: Bool      // 仅 stat_v2 / ls_v2 的 64 位大小为 true
    public let mtime: Date?
    public let dev: UInt64?
    public let ino: UInt64?
    public let posixMode: UInt32?
    public let entryErrno: Int32?
    public let isRestricted: Bool        // 如 Android/data、Android/obb 置灰不可访问
    public var id: Data { rawNameBytes }
}

public enum ADBTransferConflictResolution: String, Sendable {
    case skip
    case keepBoth
}

public enum ADBFileTaskState: String, Sendable {
    case queued, transferring, committing, completed, skipped, cancelled, failed, pendingConfirmation
}

public enum ADBFileError: LocalizedError, Sendable {
    case incompatibleEndpoint(String)
    case adbServerStartFailed(String)
    case sessionInvalidated
    case unsupportedDevice(String)       // 缺少 shell_v2 或 mv -n
    case restrictedPath(String)          // Android/data、Android/obb 等受限路径
    case invalidFileName(String)         // 非法字符、控制字符、非 UTF-8 或超过 255 字节
    case pathTooLong(Int)                // 超过 Sync 1024 字节或命令上限
    case pathChanged(String)             // 物理父目录或共享根发生漂移
    case permissionDenied(String)
    case targetChanged(String)           // dev/ino/属性与确认时不一致
    case diskFull(String)
    case protocolError(stage: String, detail: String)
    case operationUnconfirmed(String)    // 提交/删除缺少终态回执
}

public protocol ADBFileServicing: Actor {
    func openSession(for device: ADBDevice) async throws -> ADBFileSessionSnapshot
    func listDirectory(sessionId: ADBFileSessionID, relativeComponents: [Data], requestId: UUID) -> AsyncThrowingStream<ADBDirectoryBatch, Error>
    func enqueueUpload(sessionId: ADBFileSessionID, targetComponents: [Data], items: [ADBUploadPlanItem]) async throws -> [UUID]
    func enqueueDownload(sessionId: ADBFileSessionID, sourceComponents: [Data], items: [ADBDownloadPlanItem], localDirectory: URL) async throws -> [UUID]
    func enqueueDelete(sessionId: ADBFileSessionID, directoryComponents: [Data], items: [ADBDeleteTarget]) async throws -> UUID
    func cancelTransfer(taskId: UUID) async
    func cancelWindowTasks(sessionId: ADBFileSessionID) async
    func retryLedgerCleanup(entryId: UUID) async throws
    func dismissLedgerEntry(entryId: UUID) async
    var events: AsyncStream<ADBFileTaskEvent> { get }
}
```

> 补充接口：`ADBFileService` 对界面提供 `openSession`、`listDirectory`、`enqueueUpload`、`enqueueDownload`、`enqueueDelete`、`cancelTransfer` 及残片账本操作（`retryLedgerCleanup`、`dismissLedgerEntry`）。批量删除同样进入所属设备的 FIFO 写队列并作为单条删除任务在抽屉展示（设备空闲时立即执行完毕并弹出逐项结果报告；设备正在大文件传输时可清晰看到排队状态且在执行前可取消，不阻塞界面弹窗）。UI 更新同时校验 `(sessionId, requestId)`。

---

## 2. 协议与兼容性

### 2.1 Host 协议与连接复用

- **Host 帧格式**：所有 Host 请求先发送 4 位小写 ASCII 十六进制长度前缀（`%04x`，UTF‑8 载荷字节数）及载荷。服务端返回 4 字节状态标签 `OKAY` 或 `FAIL`；若为 `FAIL`，紧跟 4 位 hex 长度和 UTF‑8 错误文本。
- **能力查询**：新建独立 Host Socket，直接发送 `host-transport-id:<id>:features`，读取 `OKAY` 后再读 4 位 hex 长度及逗号分隔能力列表（如 `shell_v2,stat_v2,ls_v2`）。
- **服务切换**：设备数据连接先发送 `host:transport-id:<id>` 并读取 `OKAY`，随后在同一条连接上发送 `sync:` 或 `shell,v2,raw:<command>` 并读取服务 `OKAY`，之后切换为对应二进制帧解析器。
- **连接复用与收尾**：目录列表、属性查询、单次 Shell 命令及每个独立传输任务均使用独立连接，不跨操作复用已切入子服务的 Socket。健康结束 `sync:` 会话前固定发送 8 字节 `QUIT`（`QUIT` + `0x00000000`）后再关闭连接。 [AOSP Host 服务](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/dev/services.md)

### 2.2 超时与防呆上限

| 操作 / 通道 | 超时策略 | 缓冲区 / 长度防呆上限 | 超限或异常行为 |
| --- | --- | --- | --- |
| TCP 连接与 Host 握手 | 总超时 5 秒 | Host `FAIL` 文本 ≤ 64 KiB | 关闭 Socket，保留握手阶段名 |
| `adb start-server` + 重连 | 启动 10 秒，重连 5 秒 | CLI 输出 ≤ 256 KiB | 失败直接报错，不再二次重试 |
| `features` / `STAT` / `STA2` / `LST2` | 总超时 5 秒 | Sync 路径/参数 ≤ 1024 字节 | 超时或超长提前拒绝 |
| `LIST` / `LIS2` 目录枚举 | 单次读空闲 15 秒，总超时 60 秒 | 单个条目名 ≤ 4096 字节 | 丢弃残缺尾部，保留出错阶段 |
| 短 Shell 操作（根解析、探测、提交、删除、清理） | 总超时 10 秒 | `stdout` ≤ 256 KiB，`stderr` ≤ 64 KiB，单帧 ≤ 1 MiB | 提交/删除无退出帧时转入「待确认」 |
| 文件收发（`SEND` / `RECV`） | I/O 空闲超时 30 秒（无总时长上限） | `DATA` 载荷 ≤ 64 KiB，Sync `FAIL` ≤ 64 KiB | 持续有数据的大文件可继续；断开即停 |
| `host:track-devices-l` / `host:track-devices` | 长连接无空闲超时 | 单帧设备清单 ≤ 1 MiB | EOF 或解析错误立即失效会话并重连 |

- Socket 写入与精确读取必须循环拼接以跨 TCP 分包与合包。遇到未知帧标签、半帧 EOF、非法长度或超限帧时立即关闭连接并保留当前阶段；取消或超时回调必须通过状态锁保证每个等待只恢复一次（`resume` 幂等）。

### 2.3 Shell v2 帧结构与超长命令处理

- **帧结构**：每帧固定 5 字节帧头：`1 字节 id` + `4 字节小端 UInt32 length` + `length 字节 payload`。
  - `id = 0` (`kIdStdin`)：客户端写入命令或标准输入数据。
  - `id = 1` (`kIdStdout`)：远端标准输出，追加至有界缓冲区。
  - `id = 2` (`kIdStderr`)：远端标准错误，追加至有界缓冲区。
  - `id = 3` (`kIdExit`)：载荷固定 1 字节 `UInt8` 退出码。缺失该帧时不得推断成功，必须返回 `ADBFileError.operationUnconfirmed`。
  - `id = 4` (`kIdCloseStdin`)：载荷长度 `0`，通知远端关闭 stdin EOF。
  - `id = 5` (`kIdWindowSizeChange`)：本方案不使用。
- **超长命令保护**：
  - 旧版 `adbd` 的 `OPEN` 包存在 `MAX_PAYLOAD_V1 = 4096` 字节限制；路径中若含大量单引号，经转义（`'` → `'\''`）后可能使命令总长膨胀超限。
  - 发出 `shell,v2,raw:<cmd>` 前校验整个服务串字节长度：若 `< 3800` 字节，直接随请求发送；若 `>= 3800` 字节（且未超单命令上限 32 KiB），改用 `shell,v2,raw:sh` 打开非交互 Shell，将脚本文本经 `id = 0` 分块写入并发送 `id = 4` 关闭 stdin，再按常规收集 stdout、stderr 和退出帧。
- **能力门槛**：首版要求设备 `features` 包含 `shell_v2`（Android 7.0+）；缺失时直接提示「当前设备不支持所需 Shell 协议」。 [AOSP Shell 服务](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/daemon/services.cpp) · [AOSP Shell 退出帧](https://android.googlesource.com/platform/system/core/+/refs/tags/android-security-11.0.0_r72/adb/daemon/shell_service.cpp)

### 2.4 Sync v1/v2 二进制字段偏移规格

所有多字节整数字段均采用**小端序（Little-Endian）**，4 字节指令标签为 ASCII 字符。POSIX `mode` 类型掩码为 `S_IFMT = 0o170000`（`S_IFREG = 0o100000` 普通文件、`S_IFDIR = 0o040000` 目录、`S_IFLNK = 0o120000` 符号链接）。

| 帧类型 | 总长度 | 字节偏移与字段布局 | 说明与限制 |
| --- | --- | --- | --- |
| `STAT` 请求 | `8 + len` | `0..4 "STAT"` · `4..8 pathLen` · `8.. pathBytes` | `pathLen <= 1024`，`lstat` 语义 |
| `STAT` 响应 | 16 B | `0..4 "STAT"` · `4..8 mode(U32)` · `8..12 size(U32)` · `12..16 mtime(U32)` | 全零元数据时无法区分权限/不存在，需 Shell 复核 |
| `STA2` / `LST2` 请求 | `8 + len` | `0..4 "STA2"/"LST2"` · `4..8 pathLen` · `8.. pathBytes` | `pathLen <= 1024`；`STA2` 跟随链接、`LST2` 不跟随 |
| `STA2` / `LST2` 响应 | 72 B | `0..4 id` · `4..8 error(U32)` · `8..16 dev(U64)` · `16..24 ino(U64)` · `24..28 mode(U32)` · `28..32 nlink(U32)` · `32..36 uid(U32)` · `36..40 gid(U32)` · `40..48 size(U64)` · `48..56 atime(I64)` · `56..64 mtime(I64)` · `64..72 ctime(I64)` | `error != 0` 按对应 POSIX errno 处理 |
| `LIST` / `LIS2` 请求 | `8 + len` | `0..4 "LIST"/"LIS2"` · `4..8 pathLen` · `8.. pathBytes` | `pathLen <= 1024`（全部 Sync 请求统一限制） |
| `DENT` 条目 / `DONE` | `20 + namelen` | `0..4 "DENT"/"DONE"` · `4..8 mode(U32)` · `8..12 size(U32)` · `12..16 mtime(U32)` · `16..20 namelen(U32)` · `20.. nameBytes` | 遇到 `DONE` 后已消费完 20 字节定长头，`namelen` 应为 0 |
| `DNT2` 条目 / `DONE` | `76 + namelen` | `0..72` 同 `STA2` 响应结构 · `72..76 namelen(U32)` · `76.. nameBytes` | `DONE` 发出同样 76 字节结构：读掉 4 字节标签后必须再精确消费剩余 72 字节；单条目 `error != 0` 保留该条目错误标识，不影响同批合法条目 |
| `SEND` / `RECV` 请求 | `8 + len` | `0..4 "SEND"/"RECV"` · `4..8 paramLen` · `8.. paramBytes` | `paramLen <= 1024`；`SEND` 参数为 `<tmpPath>,33188`（即 `0o100644`），`RECV` 为 `<remotePath>` |
| `DATA` 帧 | `8 + len` | `0..4 "DATA"` · `4..8 dataLen` · `8.. payload` | `dataLen <= 65536`（64 KiB） |
| `DONE`（传输结束） | 8 B | `0..4 "DONE"` · `4..8 mtime(U32)` | 上传时由客户端发送（填秒级 mtime，超出 `UInt32` 范围用可表示当前时间）；下载时由服务端返回（长度/mtime 字段固定 `0`） |
| `OKAY`（上传确认） | 8 B | `0..4 "OKAY"` · `4..8 msglen(U32)` | 必须读满完整 8 字节并校验 `msglen == 0`，非零按协议错误处理并断开 |
| `FAIL`（Sync 错误） | `8 + msglen` | `0..4 "FAIL"` · `4..8 msglen(U32)` · `8.. utf8Error` | 与 Host `FAIL` 的 hex 长度不同，此处为小端二进制长度 |
| `QUIT` | 8 B | `0..4 "QUIT"` · `4..8 0x00000000` | 健康结束 `sync:` 会话前发送 |

- **元数据可靠性硬边界**：能力按会话缓存，`stat_v2` 和 `ls_v2` 独立选择，数据收发首版统一用 `SEND` / `RECV`，字节累计统一用 `UInt64`。**仅来自 `stat_v2`（`STA2`/`LST2`）或 `ls_v2`（`DNT2`）的 64 位 `size` 属于可靠已知长度**；降级到 `STAT` / `LIST` 时，32 位 `size` 在文件 `>= 4 GiB` 时会截断回绕，界面显示「未知」（或经 `STA2` 补齐后转为可靠），**严禁使用 v1 大小显示确定百分比或在下载 `DONE` 后触发长度不符报错**。超过 4 GiB 的文件照常进入流式收发并列入真机验收，若目标文件系统（如 FAT32）拒绝大文件，通过 `FAIL` 错误文本直接反馈给用户。 [AOSP Sync 协议结构](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/android13-gsi/file_sync_protocol.h) · [AOSP Sync 服务](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/daemon/file_sync_service.cpp)

---

## 3. 路径、浏览、字符规范与 Shell 探测模板

### 3.1 共享存储根解析与路径分量规范

1. **物理根解析模板**：打开会话时执行内置 POSIX `mksh` 命令解析 `/sdcard` 实际物理目录并校验可读性（不依赖 `realpath` 外部命令）：
   ```sh
   if [ ! -e /sdcard ]; then exit 10; fi
   cd -P -- /sdcard 2>/dev/null || { [ -d /sdcard ] && exit 13 || exit 10; }
   [ -r . ] || exit 13
   pwd -P
   ```
   - `exit 0`：去掉末尾单个 `\n` 得到共享存储物理根（如 `/storage/emulated/0`），要求为非空 `/` 开头绝对路径且不包含换行等异常尾随。
   - `exit 10`：共享存储不存在或未挂载；`exit 13`：无读取权限。
2. **单分量合法性与字节身份**：
   - 导航只接受来自「共享根」「`Download` 快捷入口」或当前列表条目的合法单个路径分量。拒绝空分量、`.`、`..`、包含 `/`（`0x2F`）或 NUL（`0x00`）的字节序列。
   - **浏览与删除保留原始 UTF‑8 字节身份（`rawNameBytes`）**：仅用于匹配已存在条目与防止 Unicode 等价折叠（NFC/NFD）将手机上两个不同文件误合并。对无法无损解码为 UTF‑8 的条目，`isLosslessUTF8 = false`，列表仅展示替换字符并禁用操作（提示文件名编码不受支持）。
   - **特殊字符读写区分**：读取、浏览与删除支持手机上已存在的含空格、中文、Emoji、单双引号及换行符的名称（界面层把 `0x00...0x1F` 与 `0x7F` 控制字符转成可见转义如 `\n`、`^G` 渲染，避免列表行错乱）；**上传新建与自动重命名时**，必须按 Android `/sdcard`（`sdcardfs` / FUSE / casefold）规则前置校验：
     - 目标文件名禁止包含 `? " * : < > \ |`、换行符及任何 ASCII 控制字符（`0x00...0x1F`, `0x7F`），否则在 `SEND` 前直接拦截报错。
     - 单路径分量长度不得超过 **255 UTF‑8 字节**。
     - 目标目录同名查重按**大小写不敏感**匹配（例如已有 `photo.jpg` 时上传 `Photo.jpg` 必须命中冲突）。

### 3.2 边界检查与 `Android/data`、`Android/obb` 拦截

1. **受限目录精确规则**：
   - 当相对路径分量数组 `components.count >= 2` 且 `components[0]` 按 ASCII 大小写不敏感等于 `"android"`、`components[1]` 按 ASCII 大小写不敏感等于 `"data"` 或 `"obb"` 时，判定为首版受限路径。
   - **UI 表现**：进入 `Android` 目录浏览时，列表照常展示 `data` 和 `obb` 条目，但标记 `isRestricted = true`，界面置灰禁用双击进入、下载与删除，并附带提示标签「首版不支持访问」。
   - **服务层防线**：`listDirectory`、`enqueueUpload`、`enqueueDownload`、`enqueueDelete` 对任何命中上述条件的请求直接拒绝并返回 `ADBFileError.restrictedPath`。
2. **路径边界与符号链接策略**：
   - 根本身可读，根下普通子项可操作。根以下出现的符号链接仅作为条目展示（标记 `kind == .symlink`），不允许作为目录导航或当普通文件读写/删除。
   - 最后一个路径分量统一使用 `lstat` 语义（`LST2` 或旧版 `STAT`）确认类型。每次执行 Shell 写操作时，必须在同一条 Shell 命令内 `cd -P` 进入物理父目录并校验 `pwd -P` 等于预期物理父路径，随后使用相对文件名（`-- './<name>'` 或已校验不含 `/` 的相对名）操作，将校验与操作的时间差压至最小。

### 3.3 空目录访问探测与大目录交付

1. **空目录访问探测模板**：AOSP 的 `LIST`/`LIS2` 在部分设备权限不足时会返回 0 条目而非报错。当目录枚举结果为空时，向设备发送以下访问探测模板（不解析 `ls` 输出，仅依据数字退出码判定；为避免 `$(pwd -P)` 吞掉路径末尾可能出现的换行符，统一用末尾附加 `\nx` 哨兵的方式精确比对物理路径）：
   ```sh
   # 1) 探测子目录时：传入物理父路径与目标分量
   cd -P -- '<parentPhysicalPath>' 2>/dev/null || exit 12
   p=$(pwd -P && echo x) || exit 12
   [ "$p" = '<parentPhysicalPath>
   x' ] || exit 12
   [ -e '<dirName>' ] || exit 10
   [ -L '<dirName>' ] && exit 11
   [ -d '<dirName>' ] || exit 11
   cd -P -- '<dirName>' 2>/dev/null || exit 13
   [ -r . ] && [ -x . ] || exit 13
   ```
   ```sh
   # 2) 探测共享存储根目录本身为空时：仅验证物理根存在、非符号链接且可读可执行
   [ -e '<physicalRoot>' ] || exit 10
   [ -L '<physicalRoot>' ] && exit 11
   [ -d '<physicalRoot>' ] || exit 11
   cd -P -- '<physicalRoot>' 2>/dev/null || exit 13
   p=$(pwd -P && echo x) || exit 12
   [ "$p" = '<physicalRoot>
   x' ] || exit 12
   [ -r . ] && [ -x . ] || exit 13
   ```
   - 退出码语义：`0` = 合法可读空目录；`10` = 目录已不存在；`11` = 已变为非目录或符号链接；`12` = 父目录物理路径已变化；`13` = 权限不足或无法读取。 [AOSP LIST 实现](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/daemon/file_sync_service.cpp#197)
2. **大目录分批交付**：枚举结果每累计 `200` 条或距离上次推送超过 `50 ms` 向 UI 流发出一个 `ADBDirectoryBatch`，携带 `(sessionId, requestId)`；用户切换目录、刷新或断线后，`ViewModel` 与 `ADBFileService` 立即递增/作废旧 `requestId` 并丢弃迟到批次。

### 3.4 操作前对象身份复核

- 入队确认时为每个目标条目快照保存 `(sessionId, parentPhysicalPath, rawNameBytes, kind, dev, ino, mtime, posixMode, size, isSizeReliable)`。
- 实际执行上传检查、下载或删除前重新查询当前对象属性：
  - 若设备支持 `LST2`：校验 `kind`、`dev`、`ino` 完全一致（普通文件再比对可见 `mtime` / `size` 提示变化）。
  - 若降级到旧版 `STAT`：比对 `kind`、`posixMode`、`mtime` 及已知属性（界面提示降级条件下无法提供 inode 级强身份保证）。
  - 任一项不一致即停止该条目操作，报告 `targetChanged`（「目标已变化，请刷新目录」）。

---

## 4. 上传、下载、删除详细流程与命令/账本规格

### 4.1 上传到当前目录

#### 1) 入队预检与批量冲突策略
1. 通过 `NSOpenPanel`（允许多选文件、禁止选目录）获取本地文件 URL，打开 `FileHandle` 前通过 `lstat` / `URLResourceValues` 复核为本地普通文件。
2. 校验源文件名：不含 `/sdcard` 禁止字符（`? " * : < > \ |` 及控制字符）且单分量 `<= 255` UTF‑8 字节；失败文件在预检结果中直接标明原因跳过，不阻塞其他文件。
3. 入队前拉取/使用当前远端目录新鲜快照（支持枚举期间阻塞等待或快速重扫当前目录，避免依赖过期缓存），按**大小写不敏感**比对远端已有项以及**同批次待上传文件互相之间**的同名冲突（例如从 Mac 不同目录同时选中 `a/photo.jpg` 与 `b/Photo.jpg`）：
   - 若存在任意冲突项，在正式入队前弹出**统一批量冲突策略面板**（展示冲突文件清单，提供「跳过」「保留两份」及「应用到本次全部冲突」开关；支持逐项或一键应用；若加 `(2)` 后缀将超过 255 UTF‑8 字节则直接标记无法自动重命名并禁用该项「保留两份」），避免传输队列中途弹模态窗阻塞后续任务。
4. **自动重命名规则（`名称 (2).扩展名`）**：
   - 若文件名为 `.name`（以 `.` 开头且后续不再含 `.`）或不含 `.`，视为无扩展名，生成 `<名称> (2)`；否则按最后一个 `.` 拆分主干与扩展名，生成 `<主干> (2).<扩展名>`（如 `archive.tar.gz` → `archive.tar (2).gz`）。
   - 序号从 `2` 起逐一尝试至上限 `999`（跳过远端当前目录大小写不敏感已存在项以及本批前面已分配的候选名）。
   - 每次生成候选名均校验 `candidate.utf8.count <= 255`；若加后缀超限，直接报错提示文件名过长，绝不静默截断文件名。
5. 校验远端暂存路径 `<parentPhysicalPath>/.metalcast-tmp-<uuid>/payload,33188` 以及最终目标路径 `<parentPhysicalPath>/<finalTargetName>` 的 UTF‑8 字节数均 `<= 1024`（确保后续 `LST2`/`STAT`/`RECV` 均不会因超过 Sync 1024 字节上限而不可访问）。

#### 2) 清理账本（Ledger）与隐藏临时子目录
- **账本路径**：`~/Library/Application Support/MetalCast/file-transfer-ledger.json`，使用 `Data.write(to:options:.atomic)` 落盘。
- **隐藏临时目录**：采用 `.metalcast-tmp-<uuid>` 命名（以 `.` 开头隐藏目录，固定载荷文件名为 `payload`），避免传输期间污染手机相册与常见文件管理器视图。
- **账本 JSON Schema**：
  ```json
  {
    "schemaVersion": 1,
    "entries": [
      {
        "id": "550E8400-E29B-41D4-A716-446655440000",
        "taskId": "6BA7B810-9DAD-11D1-80B4-00C04FD430C8",
        "endpoint": { "host": "127.0.0.1", "port": 5037 },
        "serial": "emulator-5554",
        "transportId": "3",
        "serverGeneration": 2,
        "targetParentPhysicalPath": "/storage/emulated/0/Download",
        "tempDirName": ".metalcast-tmp-9f2c...",
        "tempPayloadName": "payload",
        "finalTargetName": "demo (2).zip",
        "state": "created",
        "createdAt": "2026-11-26T03:10:00Z",
        "updatedAt": "2026-11-26T03:10:05Z"
      }
    ]
  }
  ```
- **状态流转**：`planned`（创建远端临时目录前落盘）→ `created`（收到建目录成功回执）→ `committing`（发提交 Shell 命令前）→ 正常完成后从账本移除；若发送提交命令时断线或无退出帧则转为 `pendingConfirmation`；若传输失败/取消需清理临时项但设备未在线则记为 `cleanupPending`。
- **分块写入**：账本落盘成功后再在目标目录独占创建 `.metalcast-tmp-<uuid>`（`mkdir -- '<tmpDir>'`）。通过 `SEND <tmpPath>,33188` 以每块最大 64 KiB 流式读取本地文件并写入连接；写完一块等待连接完成回调后再读下一块，同时并发监听提前到达的 Sync `FAIL`。传输结束发 `DONE`（秒级 mtime），读满 8 字节 `OKAY` 且校验 `msglen == 0`。 [AOSP SEND 写入行为](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/daemon/file_sync_service.cpp#518)

#### 3) 实测提交能力探测与提交 / 清理 Shell 模板
- **Shell 单引号安全转义**：所有动态路径参数不经双引号展开，统一先校验**不含 `\0`（NUL 字节）** 后，将字符串中每个单引号 `'` 替换为 `'\''` 再用 `'...'` 包裹。单引号转义器本身放行非 NUL 的合法 UTF‑8 字节（包括 `\n` 等既有文件名字符），以确保浏览与删除手机端含换行/引号的历史文件不受阻；对换行等控制字符的禁止规则仅在「上传新建与自动重命名」入口强制拦截。
- **提交能力实测探测（每会话首次上传前）**：不依赖解析 `mv --help` 文案，在目标目录（或共享存储根）创建一个临时探测目录 `.metalcast-probe-<uuid>` 及空文件 `a`，依次实测并在探测结束后逐项清理（`rm --` 与 `rmdir --`）：
  1. 尝试 `mv -nT -- a b && [ -f b ] && [ ! -e a ]`；成功则缓存 `commitMode = .mvNoClobberNoTarget`。
  2. 若 `-T` 报错，尝试 `mv -n -- a c && [ -f c ] && [ ! -e a ]`；成功则缓存 `commitMode = .mvNoClobberWithGuard`。
  3. 若仍失败，缓存 `commitMode = .unsupported`，清理探测残片并在上传入口明确提示设备不支持安全提交。
- **上传提交 Shell 模板**（同一次 Shell 调用内完成校验、移动、复核并顺手移除空暂存目录）：
  ```sh
  cd -P -- '<parentPhysicalPath>' 2>/dev/null || exit 20
  p=$(pwd -P && echo x) || exit 20
  [ "$p" = '<parentPhysicalPath>
  x' ] || exit 20
  [ -f '<tmpDir>/<tmpPayload>' ] && [ ! -L '<tmpDir>/<tmpPayload>' ] || exit 21
  [ ! -e '<dstName>' ] && [ ! -L '<dstName>' ] || exit 22
  # commitMode == .mvNoClobberNoTarget 时执行:
  mv -nT -- '<tmpDir>/<tmpPayload>' '<dstName>' || exit 23
  # commitMode == .mvNoClobberWithGuard 时执行（依赖上方预检确认目标不存在且非目录）:
  # mv -n -- '<tmpDir>/<tmpPayload>' '<dstName>' || exit 23
  [ ! -e '<tmpDir>/<tmpPayload>' ] && [ ! -L '<tmpDir>/<tmpPayload>' ] || exit 24
  [ -f '<dstName>' ] && [ ! -L '<dstName>' ] || exit 24
  rmdir -- '<tmpDir>' 2>/dev/null || exit 27
  ```
  - **退出码语义**：`0` = 提交成功且空暂存目录已清理；`20` = 物理父目录变化；`21` = 暂存文件丢失或类型异常；`22` = 目标名称已存在（触发跳过或递增重命名）；`23` = `mv` 执行失败；`24` = `mv` 返回 0 但暂存仍在或最终位置非普通文件（在 `mv -n` 无 `-T` 降级模式下，若并发创建了同名目录会导致 `payload` 被移入 `<dstName>/payload`，因此需报错提示并核查，禁止盲目重命名重传）；`27` = 目标文件已成功提交，仅空暂存目录 `rmdir` 未能移除（任务标记完成并保留 `cleanupPending` 账本项供清理）。
  - **竞态说明**：Android Toybox 的 `mv -n` 实现存在先 `stat` 再 `rename` 的窗口，外部写入者同时抢占目标名时仍存在 TOCTOU 竞态，因此「保留两份」仅对已观察到的同名项和应用内串行队列提供保护。 [Toybox `mv` 实现](https://android.googlesource.com/platform/external/toybox/+/master/toys/posix/cp.c#440)
- **暂存清理 Shell 模板**（严禁使用 `rm -rf`）：
  ```sh
  cd -P -- '<parentPhysicalPath>' 2>/dev/null || exit 20
  p=$(pwd -P && echo x) || exit 20
  [ "$p" = '<parentPhysicalPath>
  x' ] || exit 20
  [ -d '<tmpDir>' ] && [ ! -L '<tmpDir>' ] || exit 25
  if [ -f '<tmpDir>/<tmpPayload>' ] && [ ! -L '<tmpDir>/<tmpPayload>' ]; then
    rm -- '<tmpDir>/<tmpPayload>' || exit 26
  fi
  if [ -d '<tmpDir>' ]; then
    rmdir -- '<tmpDir>' || exit 27
  fi
  ```

#### 4) 失败、断线与残留账本收敛
- **常规失败/取消**：按上述清理模板移除本应用账本登记的 `payload` 和空 `.metalcast-tmp-<uuid>` 目录后移除账本条目。
- **提交时断线（`pendingConfirmation`）**：禁止自动重传或删除最终目标文件。重连同一设备后，只读核对 `tmpDir/payload` 与 `finalTargetName` 状态并向用户汇报结果。
- **残留记录UI收敛**：对于断线阻止清理（`cleanupPending`）、原始设备长时间不可确认或用户在手机端已手动删除临时目录的账本条目，在任务与清理抽屉中明文展示「设备序列号 + 目录路径 + 临时目录名」，同时提供「重试清理」与「忽略并移除记录」按钮，避免残留条目永久滞留。

### 4.2 下载到 Mac

1. **前置核对与批量冲突**：
   - 逐项复核绑定会话、物理父目录与普通文件类型；请求路径长度须 `<= 1024` 字节。
   - **仅当 `isSizeReliable == true`（来源为 `stat_v2` / `ls_v2`）** 时记录预期总字节数与高精度修改时间；v1 条目将总大小记为 `nil` 并采用不确定进度。
   - 通过 `NSOpenPanel`（仅允许选目录）选择 Mac 目标目录。按 macOS 默认 APFS **大小写不敏感且考虑 NFC/NFD 规范化**检查同名冲突，入队前通过统一批量冲突面板选择「跳过」或「保留两份」（支持「应用到本次全部冲突」）。自动重命名遵循 `名称 (2).扩展名` 规则并校验单个分量 `<= 255` UTF‑8 字节。
2. **独占临时文件与写盘校验**：
   - 在目标目录内以 `open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)` 独占创建 `.MetalCast-<uuid>.part`。
   - 发送 `RECV <remotePath>`，读取 `DATA` 帧逐块写盘，进度以已落盘字节数为准。
   - 收到 `DONE` 后：
     - 仅当 `isSizeReliable == true` 时校验「已写入字节 == 预期 64 位大小」；**v1 元数据禁止触发长度不符报错**。
     - 再查一次源文件 `LST2`/`STAT` 元数据是否发生变化（如文件在传输中被替换或截断）。任一不符则删除 `.part` 临时文件并提示重新下载。
   - 关闭文件前通过 `futimens(fd, ...)` 按可用精度直接在已打开的文件描述符上写回修改时间（避免基于路径的竞态）。
3. **排他发布**：
   - 在同一 Mac 目录下调用 `renamex_np(tempPath, finalPath, RENAME_EXCL)` 原子重命名。
   - 若传输期间目标名被占用返回 `EEXIST`：策略为「跳过」时删除 `.part` 并记为 `skipped`；策略为「保留两份」时循环重新扫描可用 `名称 (k).扩展名`（`k` 至多 `999` 且校验 `<= 255` UTF‑8 字节）再执行排他重命名。
   - 失败与取消仅删除本任务的 `.part` 临时文件。下载完成后任务条目提供「在 Finder 中显示」。

### 4.3 删除所选文件

1. **确认清单冻结与写队列入队**：确认对话框展示设备名、当前物理目录、待删除文件名清单与总数量，并明确标注「永久删除（不经过回收站）」。仅允许删除当前目录选中的普通文件；目录、符号链接、受限项及非无损 UTF‑8 项在确认前即拒绝选中。用户确认后调用 `enqueueDelete(...)` 进入该设备的 FIFO 写队列（设备空闲时立即执行完毕并弹出逐项结果报告；若当前正有大文件传输占用写队列，则作为一条可取消的排队删除任务展示在任务抽屉中，不阻塞界面操作）。
2. **逐项非递归 Shell 模板**（严禁 `-r` 与 `-f`）：
   ```sh
   cd -P -- '<parentPhysicalPath>' 2>/dev/null || exit 33
   p=$(pwd -P && echo x) || exit 33
   [ "$p" = '<parentPhysicalPath>
   x' ] || exit 33
   if [ -L '<targetName>' ]; then exit 31; fi
   if [ ! -e '<targetName>' ]; then exit 30; fi
   if [ ! -f '<targetName>' ]; then exit 32; fi
   rm -- '<targetName>' || { [ -e '<targetName>' ] && exit 34 || exit 30; }
   ```
   - 执行前先按第 3.4 节复核目标身份；不符则直接报「目标已变化」，不发出 Shell 删除命令。
   - **退出码与结果映射**：`0` =「已删除」；`30` =「已不存在」；`31` / `32` =「非普通文件（链接或目录），已拒绝」；`33` =「目录已变化」；`34` =「权限不足或删除失败」。
   - 断线时立即停止后续尚未发出命令的条目（单独标记为「未执行」）；已发出命令但尚未收到 `id = 3` 退出帧的条目标记为「待确认」，重连后刷新目录并提示用户该文件当前是否仍存在，由用户决定是否重新发起。
3. **单窗口刷新**：整批删除执行结束后，通知该设备绑定的文件窗口刷新；仅当该窗口仍处于同一 `ADBFileSessionID` 且当前目录未切换时应用刷新结果。

---

## 5. 任务调度、状态机与界面规格

### 5.1 队列并发与防死锁模型

- **设备串行写通道**：`ADBFileService` 为每台设备（按 `transportId` / `sessionId`）维护一条 FIFO 串行写队列，统一排队该设备的上传、下载和删除任务；同一设备任意时刻最多执行 1 个写操作。
- **全局 2 槽位传输信号量**：全应用最多同时执行 2 条文件传输（`SEND` 或 `RECV`）。
- **无死锁加锁顺序**：任务先在所属设备写队列中排队；**仅当轮到该设备写队列队首后**，传输任务再异步申请全局 2 槽位传输信号量，删除任务不占传输槽位直接执行。由于每台设备仅队首任务会申请全局槽位，跨设备之间不存在循环持锁等待，天然无死锁。
- **独立浏览通道**：目录枚举与 `STA2`/`LST2` 探测使用独立临时 Socket，不进入设备写队列，也不占用全局传输槽位，大文件传输期间仍可流畅浏览。

### 5.2 任务状态流转表

| 状态 (`ADBFileTaskState`) | 允许流转的下一状态 | 触发条件 / 副作用 | 允许的 UI 操作 |
| --- | --- | --- | --- |
| `queued` | `transferring` / `cancelled` / `failed` | 获准执行；用户取消直接移出队列；会话失效直接标失败 | 取消 |
| `transferring` | `committing` / `cancelled` / `failed` | 传完数据进入提交/重命名；取消立即关 Socket 并清临时项 | 取消 |
| `committing` | `completed` / `skipped` / `failed` / `pendingConfirmation` | 退出码 `0` / `renamex_np` 成功进 `completed`；冲突选跳过进 `skipped`；断线或缺退出帧进 `pendingConfirmation` | 等待完成（不可静默取消） |
| `completed` | —（终态） | 上传清理空临时目录并移除账本；下载支持在 Finder 中显示 | 在 Finder 中显示（下载） / 清除记录 |
| `skipped` | —（终态） | 冲突策略跳过；若有临时文件已清理 | 清除记录 |
| `cancelled` | —（终态） | 已完成或已记录临时项清理 | 重试 / 清除记录 |
| `failed` | `queued`（手动重试） | 重试时重新校验当前会话、目录与同名策略 | 重试 / 清除记录 |
| `pendingConfirmation` | `completed` / `failed` / `queued` | 重连后用户触发「核对结果」：只读核对远端暂存与目标状态给出结论 | 核对结果 / 忽略（账本项） |

### 5.3 进度与速率计算

- 进度事件在 `ADBFileService` 内部按约 `100 ms` 节流推送一次（终态立即推送，不节流）。
- 上传字节计数以客户端写入 `NWConnection` 完成回调为准；下载字节计数以写入 `.part` 临时文件成功为准。
- 速率采用最近 `1 秒` 滑动窗口（或指数移动平均 EMA）计算 `bytesPerSecond`。
- 仅当 `isSizeReliable == true` 时显示百分比与剩余时间预估；**`100%` 仅在提交/排他重命名确认完成后显示**，进入 `committing` 时文本显示「正在提交…」。

### 5.4 文件窗口布局与界面状态

- **窗口规格**：由 `FileManagerWindowController` 托管独立 `NSWindow`，默认尺寸 `920 × 620`，最小尺寸 `780 × 520`，标题格式 `手机文件 - <deviceName>`。
- **顶部工具栏**：返回上一级、刷新、可点击的面包屑路径栏（根目录显示「共享存储」）、上传文件、下载所选、删除所选、任务与清理抽屉切换按钮（带进行中任务数量角标）。
- **主文件列表**：
  - 列构成：**名称**（文件类型图标 + 控制字符可见转义 + 符号链接角标 + `Android/data` 与 `Android/obb` 置灰徽章）、**类型**、**大小**（目录或 `isSizeReliable == false` 严格显示 `—` / `未知 (v1)`，严禁直接显示可能已截断回绕的 32 位 v1 数值）、**修改时间**。
  - 默认排序：目录在前、文件在后，同组按名称本地化升序；支持点击表头切换排序字段与方向。支持单击高亮选中目录/链接行（同时保持「下载所选/删除所选」禁用）、`Cmd+A` 全选可操作普通文件、多选下载与多选删除。
- **底部状态栏与可折叠任务/清理抽屉**：
  - 状态栏展示当前设备连接方式（USB / Wi‑Fi）、当前目录项统计、活跃传输摘要。
  - 抽屉默认在无活跃任务且无未收敛账本时收起（以保证 `780 × 520` 最小窗口下文件列表可用高度），有任务入队或存在未收敛账本时自动展开。
  - 抽屉内部采用与原型对齐的**双标签页结构**（「任务队列」与「清理账本」，各带计数徽章）：「任务队列」展示当前窗口绑定设备的上传/下载/删除任务（同时展示全局传输槽 `0/2` 占用），终态均提供「清除记录」（`failed` 与 `cancelled` 提供「重试」）；当存在未收敛账本记录时，在「任务队列」顶部同步显示引导横幅，并在「清理账本」页逐条展示「设备序列号 + 目录路径 + 临时目录名」及「重试清理」「忽略并移除记录」按钮。
- **可区分空态与异常态**：
  1. 空目录：「此文件夹为空」+ 快捷上传按钮。
  2. 权限不足：「无权限访问此目录」提示。
  3. 设备断线：「设备连接已断开」横幅/遮罩 +「重新连接并核对」按钮（核对恢复后重新绑定新代次会话）。
  4. 能力不支持：缺少 `shell_v2` 或缺少 `mv -n` 时明确提示原因（缺少 `mv -n` 时仍允许浏览、下载和删除，仅禁用上传）。
  5. 端点配置不兼容：明确展示冲突或不支持的环境变量名称（如 `ADB_SERVER_SOCKET=localfilesystem:...`）。

### 5.5 窗口关闭与 `Cmd+Q` 退出流程

- **单个文件窗口关闭（`NSWindowDelegate.windowShouldClose`）**：
  - 若该设备会话存在未提交或正在提交的任务，弹窗确认「关闭窗口将取消未开始的传输并尝试清理当前临时文件，确认关闭？」；正在提交中的任务提示等待提交回执或转入账本 `pendingConfirmation`。
  - 确认关闭后调用 `cancelWindowTasks(sessionId:)` 并从 `FileManagerWindowCoordinator` 移除控制器。
- **应用级退出（`MetalCastApp.swift` 中的 `AppDelegate.applicationShouldTerminate(_:)`）**：
  - 检查 `ADBFileService` 是否存在活跃传输、排队删除或正在提交的任务：
    - 若无活跃任务，直接返回 `.terminateNow`（在 `applicationWillTerminate` 继续执行 `SessionManager.shared.stopMirroring()`）。
    - 若存在活跃任务，弹窗确认是否中断退出；用户取消则返回 `.terminateCancel`。
    - 用户确认退出后，返回 `.terminateLater`：在后台 Task 中同步停止投屏（`SessionManager.shared.stopMirroring()`）、取消所有未进入提交阶段的传输与排队删除、在总上限 `5 秒` 预算内等待已发出的 `committing` 命令收尾与暂存清理，并将仍未收尾的提交标为 `pendingConfirmation`、未清理暂存标为 `cleanupPending` 后以 `Data.write(to:options:.atomic)` 落盘 `file-transfer-ledger.json`，最终调用 `NSApp.reply(toApplicationShouldTerminate: true)` 放行退出（替代原先 `applicationWillTerminate` 中无等待的异步 `Task`）。 [MetalCastApp.swift](../Sources/MetalCastApp/MetalCastApp.swift)

---

## 6. 实施顺序、单测矩阵与真机验收

### 阶段 1 · Host 通道、统一端点与设备会话
- **交付物**：
  - 在 `Package.swift` 新增 `MetalCastCoreTests` 单元测试 Target；完成 `ADBServerEndpoint`、`ADBProcessRunner` 非阻塞与环境变量清洗、`ADBDevice.selectionKey` 列表对齐、`ADBSocketConnection` 及 `host:track-devices-l`（含 `host:devices-l` 降级）跟踪服务。 [Package.swift](../Package.swift)
- **单元测试（`MetalCastCoreTests`）**：
  - 环境变量优先级与非法端点拒绝（`localfilesystem:`、非回环 IP、冲突端口）。
  - 清洗后 CLI 参数 `-L tcp:<host>:<port>` 组装与 `ADBProcessRunner` 并发取消释放测试。
  - Mock TCP Server 验证 1 字节分包与多帧合包、Host `FAIL` hex 长度、设备切换代次失效、并发 `ECONNREFUSED` 仅触发一次 `start-server`、连接/握手超时与幂等取消。
  - 双设备同在线、同 `serial` 新旧 `transportId` 切换、`host:track-devices-l` 降级到 `host:track-devices` + `host:devices-l`。

### 阶段 2 · 协议编解码、路径边界与目录浏览
- **交付物**：
  - `ADBSyncClient`（`STAT`/`STA2`/`LST2`/`LIST`/`LIS2`）、`ADBShellClient`（Shell v2 帧解析与 `sh` stdin 超长回退）以及共享根解析、路径边界校验、空目录探测。
- **单元测试**：
  - `DNT2` 76B 与 `DONE` 72B 尾包精确消费、单条目 `errno != 0` 保留、16B `STAT` 零元数据回退、所有 Sync 请求超 1024 字节拒绝、Shell v2 `>= 3800` 字节自动走 stdin 投喂、缺失退出帧报错。
  - `cd -P /sdcard && pwd -P` 根解析测试、`Android/data` 与 `Android/obb`（含大小写变体 `ANDROID/DATA`、`android/Obb/com.demo`）拦截测试、`.`/`..`/`/`/`\0` 拒绝、非无损 UTF‑8 标记、控制字符转义、空目录探测退出码 `0/10/11/12/13`、快速切换目录丢弃迟到批次。

### 阶段 3 · 文件收发、冲突策略、提交与恢复账本
- **交付物**：
  - `ADBSyncClient` `SEND`/`RECV`/`QUIT` 流式传输、上传提交能力实测探测、上传/下载自动重命名与账本持久化、清理与断线核对流程。
- **单元测试与集成测试**：
  - 零字节、64 KiB 恰好一帧、多帧及 `> 4 GiB`（模拟与真机）流式传输字节一致性校验；上传 `OKAY` 非零 `msglen` 协议拦截；健康结束发送 `QUIT`。
  - v1 元数据下载 `>= 4 GiB` 不误报长度不符；APFS 大小写 + NFC/NFD 下载查重；`/sdcard` 大小写冲突查重、非法字符拦截（`? " * : < > \ |` 及换行）、`.env (2)` / `a.tar (2).gz` 重命名与 255 UTF‑8 字节边界拒绝。
  - 无 `-T` 的 `mv -n` 降级提交、退出码 `20/21/22/23/24` 处理、提交断线转 `pendingConfirmation`、重启后账本恢复清理与手动「忽略并移除记录」。

### 阶段 4 · 删除与 SwiftUI/AppKit 窗口交互
- **交付物**：
  - 控制中心入口与 `FileManagerWindowCoordinator`、`FileManagerWindowController`、`FileManagerViewModel`、`FileManagerView`、批量冲突面板、删除确认与 `AppDelegate.applicationShouldTerminate(_:)` 退出拦截。
- **验证点**：
  - 同设备重复点击入口置前现有窗口；控制中心选中切换或刷新不影响已打开窗口。
  - 批量上传/下载「应用到本次全部冲突」、逐项删除成功/失败混合清单、确认后文件变化停止操作、断线转 `pendingConfirmation` 重连核对、窗口关闭取消与 `Cmd+Q` `.terminateLater` 限时清理落盘、结束投屏后继续独立管理文件。

### 阶段 5 · 发布前真机验收
- **系统覆盖**：macOS 13 与当前支持版本 macOS；USB 与已配对 Wi‑Fi 均全量跑通。
- **Android 机型覆盖**：至少覆盖 1 台较旧版本/Toybox 设备（如 Android 10/11，实际验证 `mv -n` 降级、v1/v2 元数据与媒体库不自动刷新限制）和 1 台新版本设备（Android 13/14+，验证 FUSE 非法字符、权限拒绝与 `Android/data` 隔离）。
- **并发与性能**：记录 1080P/原生分辨率 Wi‑Fi 投屏并行大文件上传/下载时的传输速率、投屏帧率与操作响应；确认浏览不受 2 槽位传输队列阻塞。
- **发布准出条件**：零跨设备误操作、零残缺最终文件、所有冲突与部分失败具备可解释结果、取消/断线/异常退出后所有暂存项均可通过账本追踪或手动清除。
