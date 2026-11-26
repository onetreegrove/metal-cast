'use strict';

(function () {
  const DEVICES = [
    {
      selectionKey: 'tid:3',
      serial: '8e45f92a',
      transportId: '3',
      model: 'Xiaomi 14 Pro',
      androidVersion: 'Android 14',
      connectionType: 'USB',
      state: 'device',
      physicalRoot: '/storage/emulated/0',
      capabilities: {
        hasShellV2: true,
        hasStatV2: true,
        hasLsV2: true,
        commitMode: 'mvNoClobberNoTarget' // mv -nT
      }
    },
    {
      selectionKey: 'tid:7',
      serial: '192.168.1.108:5555',
      transportId: '7',
      model: 'Galaxy S24 Ultra',
      androidVersion: 'Android 14',
      connectionType: 'Wi-Fi',
      state: 'device',
      physicalRoot: '/storage/emulated/0',
      capabilities: {
        hasShellV2: true,
        hasStatV2: true,
        hasLsV2: true,
        commitMode: 'mvNoClobberNoTarget'
      }
    },
    {
      selectionKey: 'tid:11',
      serial: '9B141FFAZ00291',
      transportId: '11',
      model: 'Pixel 4 XL',
      androidVersion: 'Android 10',
      connectionType: 'USB',
      state: 'device',
      physicalRoot: '/storage/emulated/0',
      capabilities: {
        hasShellV2: true,
        hasStatV2: false,
        hasLsV2: false,
        commitMode: 'mvNoClobberWithGuard' // 缺少 -T，降级 mv -n 护栏
      }
    },
    {
      selectionKey: 'tid:15',
      serial: 'HT64V0301192',
      transportId: '15',
      model: 'Legacy Phone',
      androidVersion: 'Android 6.0',
      connectionType: 'USB',
      state: 'device',
      physicalRoot: '/storage/emulated/0',
      capabilities: {
        hasShellV2: false,
        hasStatV2: false,
        hasLsV2: false,
        commitMode: 'unsupported'
      }
    },
    {
      selectionKey: 'serial:op12-001',
      serial: 'op12-001',
      transportId: null,
      model: 'OnePlus 12',
      androidVersion: 'Android 14',
      connectionType: 'USB',
      state: 'unauthorized',
      physicalRoot: null,
      capabilities: null
    }
  ];

  function createInitialFileSystem() {
    const xiaomiTree = {
      '/': [
        { name: 'Download', kind: 'directory', size: null, isSizeReliable: true, mtime: 1764123600, dev: 2049, ino: 1001 },
        { name: 'DCIM', kind: 'directory', size: null, isSizeReliable: true, mtime: 1764091200, dev: 2049, ino: 1002 },
        { name: 'Documents', kind: 'directory', size: null, isSizeReliable: true, mtime: 1764050000, dev: 2049, ino: 1003 },
        { name: 'Android', kind: 'directory', size: null, isSizeReliable: true, mtime: 1763900000, dev: 2049, ino: 1004 },
        { name: 'EmptyFolder', kind: 'directory', size: null, isSizeReliable: true, mtime: 1764001000, dev: 2049, ino: 1005 },
        { name: 'RestrictedCache', kind: 'directory', size: null, isSizeReliable: true, mtime: 1763990000, dev: 2049, ino: 1006, simulateProbeExit: 13 },
        { name: 'device-readme.txt', kind: 'regular', size: 2480, isSizeReliable: true, mtime: 1764100200, dev: 2049, ino: 1007 }
      ],
      '/Download': [
        { name: 'photo.jpg', kind: 'regular', size: 4281904, isSizeReliable: true, mtime: 1764119000, dev: 2049, ino: 2001 },
        { name: 'metalcast-notes.txt', kind: 'regular', size: 18420, isSizeReliable: true, mtime: 1764118200, dev: 2049, ino: 2002 },
        { name: 'MetalCast-helper.apk', kind: 'regular', size: 14820910, isSizeReliable: true, mtime: 1764109000, dev: 2049, ino: 2003 },
        { name: '4K_Gameplay_Capture_2026.mp4', kind: 'regular', size: 4960686899, isSizeReliable: true, mtime: 1764095000, dev: 2049, ino: 2004 },
        { name: 'quarterly-android-sync-protocol-benchmark-report-2026-v3.pdf', kind: 'regular', size: 9412800, isSizeReliable: true, mtime: 1764081200, dev: 2049, ino: 2005 },
        { name: 'latest-release.apk', kind: 'symlink', size: 28, isSizeReliable: true, mtime: 1764070000, dev: 2049, ino: 2006 },
        { name: 'report\nfinal.txt', kind: 'regular', size: 6144, isSizeReliable: true, mtime: 1764060000, dev: 2049, ino: 2007 },
        { name: 'broken__name.bin', kind: 'regular', size: 4096, isSizeReliable: true, mtime: 1764040000, dev: 2049, ino: 2008, isLosslessUTF8: false },
        { name: 'Builds', kind: 'directory', size: null, isSizeReliable: true, mtime: 1764030000, dev: 2049, ino: 2009 }
      ],
      '/Download/Builds': [
        { name: 'scrcpy-server-v4.1.jar', kind: 'regular', size: 68200, isSizeReliable: true, mtime: 1764020000, dev: 2049, ino: 2101 }
      ],
      '/DCIM': [
        { name: 'Camera', kind: 'directory', size: null, isSizeReliable: true, mtime: 1764091000, dev: 2049, ino: 3001 }
      ],
      '/DCIM/Camera': [
        { name: 'IMG_20261125_183022.jpg', kind: 'regular', size: 5912440, isSizeReliable: true, mtime: 1764066622, dev: 2049, ino: 3101 },
        { name: 'VID_20261124_201500.mp4', kind: 'regular', size: 284192000, isSizeReliable: true, mtime: 1763986500, dev: 2049, ino: 3102 }
      ],
      '/Documents': [
        { name: 'adb-sync-spec.md', kind: 'regular', size: 18086, isSizeReliable: true, mtime: 1764120000, dev: 2049, ino: 4001 }
      ],
      '/Android': [
        { name: 'data', kind: 'directory', size: null, isSizeReliable: true, mtime: 1763900000, dev: 2049, ino: 5001, isRestricted: true },
        { name: 'obb', kind: 'directory', size: null, isSizeReliable: true, mtime: 1763900000, dev: 2049, ino: 5002, isRestricted: true },
        { name: 'media', kind: 'directory', size: null, isSizeReliable: true, mtime: 1763900000, dev: 2049, ino: 5003 }
      ],
      '/Android/media': [
        { name: 'com.metalcast.sample', kind: 'directory', size: null, isSizeReliable: true, mtime: 1763900000, dev: 2049, ino: 5101 }
      ],
      '/EmptyFolder': [],
      '/RestrictedCache': []
    };

    const galaxyTree = {
      '/': [
        { name: 'Download', kind: 'directory', size: null, isSizeReliable: true, mtime: 1764121000, dev: 2050, ino: 6001 },
        { name: 'Pictures', kind: 'directory', size: null, isSizeReliable: true, mtime: 1764110000, dev: 2050, ino: 6002 },
        { name: 'Android', kind: 'directory', size: null, isSizeReliable: true, mtime: 1763900000, dev: 2050, ino: 6003 }
      ],
      '/Download': [
        { name: 'galaxy-log-2026.txt', kind: 'regular', size: 91204, isSizeReliable: true, mtime: 1764115000, dev: 2050, ino: 6101 },
        { name: 'firmware-patch.zip', kind: 'regular', size: 124518400, isSizeReliable: true, mtime: 1764102000, dev: 2050, ino: 6102 }
      ],
      '/Pictures': [
        { name: 'Screenshot_20261126.png', kind: 'regular', size: 1940221, isSizeReliable: true, mtime: 1764122000, dev: 2050, ino: 6201 }
      ],
      '/Android': [
        { name: 'data', kind: 'directory', size: null, isSizeReliable: true, mtime: 1763900000, dev: 2050, ino: 6301, isRestricted: true },
        { name: 'obb', kind: 'directory', size: null, isSizeReliable: true, mtime: 1763900000, dev: 2050, ino: 6302, isRestricted: true }
      ]
    };

    const pixelTree = {
      '/': [
        { name: 'Download', kind: 'directory', size: null, isSizeReliable: false, mtime: 1764080000 },
        { name: 'DCIM', kind: 'directory', size: null, isSizeReliable: false, mtime: 1764075000 }
      ],
      '/Download': [
        { name: 'pixel-dump.zip', kind: 'regular', size: 68291840, isSizeReliable: false, mtime: 1764080000 },
        { name: '4gb-raw-recording.mp4', kind: 'regular', size: null, isSizeReliable: false, mtime: 1764070000 },
        { name: '.env', kind: 'regular', size: 420, isSizeReliable: false, mtime: 1764060000 },
        { name: 'archive.tar.gz', kind: 'regular', size: 882100, isSizeReliable: false, mtime: 1764050000 }
      ],
      '/DCIM': [
        { name: 'IMG_0012.jpg', kind: 'regular', size: 3201100, isSizeReliable: false, mtime: 1764040000 }
      ]
    };

    return {
      'tid:3': xiaomiTree,
      'tid:7': galaxyTree,
      'tid:11': pixelTree,
      'tid:15': { '/': [] },
      'serial:op12-001': { '/': [] }
    };
  }

  const MAC_UPLOAD_POOL = [
    {
      id: 'mac-1',
      name: 'ReleaseNotes_v4.2.pdf',
      size: 3842100,
      note: 'Mac 普通 PDF 文档（直接上传）'
    },
    {
      id: 'mac-2',
      name: 'Photo.jpg',
      size: 2948120,
      note: '与手机端 photo.jpg 大小写冲突（验证 /sdcard 大小写不敏感查重）'
    },
    {
      id: 'mac-3',
      name: 'MetalCast-helper.apk',
      size: 16420100,
      note: 'APK 在文件窗口按普通文件上传（若存在同名则进入批量冲突策略）'
    },
    {
      id: 'mac-4',
      name: '.env',
      size: 512,
      note: '测试隐藏文件自动重命名（生成 .env (2) 而非 (2).env）'
    },
    {
      id: 'mac-5',
      name: 'archive.tar.gz',
      size: 1582900,
      note: '测试多扩展名拆分（按最后一个点拆分为 archive.tar (2).gz）'
    },
    {
      id: 'mac-6',
      name: 'notes:2026?.txt',
      size: 1280,
      note: '含 /sdcard 禁止字符（: 与 ?）—— 入队前直接前置拦截'
    },
    {
      id: 'mac-7',
      name: 'ultra-long-filename-exceeding-255-utf8-bytes-' + 'x'.repeat(216) + '.txt',
      size: 6400,
      note: '超过 255 UTF-8 字节上限 —— 入队前拒绝，不静默截断'
    },
    {
      id: 'mac-8',
      name: 'Gameplay_HDR_4K_60fps_Session.mp4',
      size: 4718592000,
      note: '超过 4 GiB 大文件（流式 SEND + UInt64 进度）'
    }
  ];

  const MAC_DOWNLOAD_DESTS = {
    downloads: {
      path: '~/Downloads/PhoneBackup',
      existing: ['metalcast-notes.txt', 'PHOTO.JPG', 'report\nfinal.txt']
    },
    desktop: {
      path: '~/Desktop/MetalCastTransfer',
      existing: []
    }
  };

  const INITIAL_LEDGER = [
    {
      id: '550E8400-E29B-41D4-A716-446655440000',
      taskId: '6BA7B810-9DAD-11D1-80B4-00C04FD430C8',
      endpoint: { host: '127.0.0.1', port: 5037 },
      serial: '8e45f92a',
      transportId: '3',
      serverGeneration: 2,
      targetParentPhysicalPath: '/storage/emulated/0/Download',
      tempDirName: '.metalcast-tmp-9f2c8b14',
      tempPayloadName: 'payload',
      finalTargetName: 'interrupted-backup.zip',
      state: 'cleanupPending',
      createdAt: '2026-11-26T02:58:10Z',
      updatedAt: '2026-11-26T02:59:02Z'
    }
  ];

  window.McData = {
    DEVICES,
    createInitialFileSystem,
    MAC_UPLOAD_POOL,
    MAC_DOWNLOAD_DESTS,
    INITIAL_LEDGER
  };
})();
