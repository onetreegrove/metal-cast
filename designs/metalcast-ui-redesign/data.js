/* Realistic MetalCast UI prototype state and specifications. */
(function () {
  window.MCData = {
    styles: {
      "native-pro": {
        name: "方案 A · 原生精密",
        desc: "克制 macOS 毛玻璃层级 + 清晰的设备头与分标签设置，零表单墙，兼顾日常与专业感。",
        radius: "14px 窗口 / 11px 卡片",
        accentLabel: "#0071E3 / #0A84FF"
      },
      "studio-hardware": {
        name: "方案 B · 硬件控制台",
        desc: "精密影音硬件面板质感：利落 8px 倒角、信号链路等宽读数、高亮 Teal 信号指示。",
        radius: "8px 窗口 / 6px 卡片",
        accentLabel: "#007F6B / #00D4B0"
      },
      "minimal-air": {
        name: "方案 C · 极简清透",
        desc: "更松弛的留白节奏、柔润 18px 窗体与轻边界分组卡，长时挂机与文件整理更轻松。",
        radius: "18px 窗口 / 14px 卡片",
        accentLabel: "#465EE0 / #748BFF"
      }
    },

    devices: [
      {
        id: "tid:4",
        serial: "41281FDAP0019X",
        model: "Pixel 9 Pro",
        state: "device",
        isWifi: false,
        transportId: "4",
        resolution: "1280 × 2856",
        android: "Android 15",
        capabilities: "shell_v2 · stat_v2 · ls_v2 · mv -nT"
      },
      {
        id: "tid:7",
        serial: "192.168.1.48:5555",
        model: "Xiaomi 14 Ultra",
        state: "device",
        isWifi: true,
        transportId: "7",
        resolution: "1440 × 3200",
        android: "Android 14",
        capabilities: "shell_v2 · stat_v2 · ls_v2 · mv -nT"
      },
      {
        id: "serial:R5CX408K",
        serial: "R5CX408KL9N",
        model: "Galaxy S24",
        state: "unauthorized",
        isWifi: false,
        transportId: null,
        resolution: "—",
        android: "未授权 USB 调试",
        capabilities: "请在手机端确认 RSA 调试授权"
      }
    ],

    mdnsDevices: [
      {
        id: "mdns-connect",
        name: "Pixel-9-ADB",
        address: "192.168.1.62:37421",
        isPairing: false
      },
      {
        id: "mdns-pair",
        name: "OnePlus-12-Wireless",
        address: "192.168.1.73:41289",
        isPairing: true
      }
    ],

    keymapPresets: [
      { id: "none", title: "关闭映射", desc: "普通桌面鼠标与触控透传模式" },
      { id: "gameforpeace.json", title: "和平精英 / PUBG Mobile", desc: "WASD 摇杆、~ 键锁定无边界视角、M 地图自动释放" },
      { id: "tiktok.json", title: "抖音 / TikTok 短视频", desc: "方向键上下切换视频、双击/热键快速点赞" },
      { id: "identityv.json", title: "第五人格 / Identity V", desc: "多点触控与视角协同映射配置" },
      { id: "frag.json", title: "FRAG Pro Shooter", desc: "FPS 左键开火、右键开镜与走位预设" },
      { id: "test.json", title: "按键调试预设", desc: "用于测试多点触控与拖拽轨迹的调试配置" }
    ],

    filesByPath: {
      "/": [
        { name: "Download", kind: "folder", kindLabel: "文件夹", size: null, sizeText: "—", mtime: 1764144000, mtimeText: "2026-11-26 16:00", icon: "folder" },
        { name: "DCIM", kind: "folder", kindLabel: "文件夹", size: null, sizeText: "—", mtime: 1764132000, mtimeText: "2026-11-26 12:40", icon: "folder" },
        { name: "Android", kind: "folder", kindLabel: "文件夹", size: null, sizeText: "—", mtime: 1763960000, mtimeText: "2026-11-24 12:53", icon: "folder" },
        { name: "Movies", kind: "folder", kindLabel: "文件夹", size: null, sizeText: "—", mtime: 1763890000, mtimeText: "2026-11-23 17:26", icon: "folder" }
      ],
      "/Download": [
        { name: "ReleaseNotes", kind: "folder", kindLabel: "文件夹", size: null, sizeText: "—", mtime: 1764141000, mtimeText: "2026-11-26 15:10", icon: "folder" },
        { name: "metalcast-beta-4.2.apk", kind: "regular", kindLabel: "APK 安装包", size: 28412900, sizeText: "28.4 MB", mtime: 1764146500, mtimeText: "2026-11-26 16:41", icon: "apk", operable: true },
        { name: "HDR-Sample-120fps.mp4", kind: "regular", kindLabel: "视频文件", size: 148920110, sizeText: "148.9 MB", mtime: 1764139800, mtimeText: "2026-11-26 14:50", icon: "video", operable: true },
        { name: "Shot_20261126.png", kind: "regular", kindLabel: "PNG 图像", size: 4210480, sizeText: "4.2 MB", mtime: 1764128400, mtimeText: "2026-11-26 11:40", icon: "photo", operable: true },
        { name: "report.pdf", kind: "regular", kindLabel: "普通文件", size: 1842200, sizeText: "1.8 MB", mtime: 1764072000, mtimeText: "2026-11-25 20:00", icon: "doc", operable: true },
        { name: "latest-log.link", kind: "symlink", kindLabel: "符号链接", size: 24, sizeText: "24 B", mtime: 1764068000, mtimeText: "2026-11-25 18:53", icon: "link", operable: false, tag: "符号链接" }
      ],
      "/Download/ReleaseNotes": [
        { name: "changelog-v4.2.md", kind: "regular", kindLabel: "普通文件", size: 18420, sizeText: "18.4 KB", mtime: 1764140400, mtimeText: "2026-11-26 15:00", icon: "doc", operable: true },
        { name: "trace\\ndump.txt", kind: "regular", kindLabel: "普通文件", size: 6410, sizeText: "6.4 KB", mtime: 1764120000, mtimeText: "2026-11-26 09:20", icon: "doc", operable: true, tag: "控制字符转义" }
      ],
      "/DCIM": [
        { name: "Camera", kind: "folder", kindLabel: "文件夹", size: null, sizeText: "—", mtime: 1764132000, mtimeText: "2026-11-26 12:40", icon: "folder" },
        { name: "PXL_20261126_0912.jpg", kind: "regular", kindLabel: "JPEG 图像", size: 5830100, sizeText: "5.8 MB", mtime: 1764119520, mtimeText: "2026-11-26 09:12", icon: "photo", operable: true }
      ],
      "/DCIM/Camera": [
        { name: "IMG_001.jpg", kind: "regular", kindLabel: "JPEG 图像", size: 4120900, sizeText: "4.1 MB", mtime: 1764110000, mtimeText: "2026-11-26 06:33", icon: "photo", operable: true }
      ],
      "/Android": [
        { name: "media", kind: "folder", kindLabel: "文件夹", size: null, sizeText: "—", mtime: 1763960000, mtimeText: "2026-11-24 12:53", icon: "folder" },
        { name: "data", kind: "folder", kindLabel: "受限目录", size: null, sizeText: "—", mtime: 1763960000, mtimeText: "2026-11-24 12:53", icon: "lock", restricted: true, tag: "首版不支持访问" },
        { name: "obb", kind: "folder", kindLabel: "受限目录", size: null, sizeText: "—", mtime: 1763960000, mtimeText: "2026-11-24 12:53", icon: "lock", restricted: true, tag: "首版不支持访问" }
      ],
      "/Android/media": [],
      "/Movies": [
        { name: "Capture_60fps.mp4", kind: "regular", kindLabel: "视频文件", size: 92401000, sizeText: "92.4 MB", mtime: 1763890000, mtimeText: "2026-11-23 17:26", icon: "video", operable: true }
      ]
    },

    tasks: [
      {
        id: "t-1",
        kind: "上传",
        name: "firmware-ota (2).zip",
        state: "transferring",
        stateLabel: "传输中",
        progress: 64,
        subtitle: "64% · 128 MB / 200 MB · 42.6 MB/s · 正在传输至暂存目录"
      },
      {
        id: "t-2",
        kind: "上传",
        name: "release-patch.apk",
        state: "pendingConfirmation",
        stateLabel: "待确认",
        progress: 99,
        subtitle: "提交命令已发出但未收到退出回执，请重连后核对结果"
      },
      {
        id: "t-3",
        kind: "下载",
        name: "HDR-Sample-120fps.mp4",
        state: "completed",
        stateLabel: "已完成",
        progress: 100,
        subtitle: "100% · 148.9 MB · 已保存到 ~/Downloads"
      }
    ],

    ledger: [
      {
        id: "l-1",
        path: ".metalcast-tmp-9f12/payload → release-patch.apk",
        meta: "设备 41281FDAP0019X · 目录 /storage/emulated/0/Download",
        state: "pendingConfirmation"
      },
      {
        id: "l-2",
        path: ".metalcast-tmp-3a08/payload → draft-notes.pdf",
        meta: "设备 41281FDAP0019X · 目录 /storage/emulated/0/Download",
        state: "cleanupPending"
      }
    ],

    conflicts: [
      { name: "metalcast-beta-4.2.apk", rename: "metalcast-beta-4.2 (2).apk", resolution: "keepBoth" },
      { name: "Shot_20261126.png", rename: "Shot_20261126 (2).png", resolution: "keepBoth" }
    ],

    swiftMapping: [
      { file: "DashboardView.swift", change: "左侧边栏专注已连接设备并置底「无线连接与发现（含附近计数徽标）」弹窗入口；右侧重做为 Hero 设备头 + Signal Summary Strip + 3 分区 Tab + 均衡双栏卡片" },
      { file: "FileManagerView.swift", change: "统一表格表头排序视觉、单行标签密度与底部任务/清理账本抽屉配色 Token，补全状态一致性" },
      { file: "CapsuleToolbarView.swift", change: "重做 DockToolbarView 图标按压胶囊、分隔发丝线、激活状态点与单向提示标签" }
    ]
  };
})();
