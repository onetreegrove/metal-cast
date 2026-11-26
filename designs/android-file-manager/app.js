'use strict';

(function () {
  const { DEVICES, createInitialFileSystem, MAC_UPLOAD_POOL, MAC_DOWNLOAD_DESTS, INITIAL_LEDGER } = window.McData;

  const textEncoder = new TextEncoder();
  const collator = new Intl.Collator('zh-CN', { numeric: true, sensitivity: 'base' });
  const MAX_GLOBAL_TRANSFER_SLOTS = 2;

  const appState = {
    theme: 'dark',
    tweaksOpen: false,
    activeScenario: 'normal',
    endpoint: { host: '127.0.0.1', port: 5037, incompatibleDetail: null },
    serverGeneration: 2,
    devices: structuredClone(DEVICES),
    selectedDeviceKey: 'tid:3',
    fs: createInitialFileSystem(),
    openWindows: new Map(), // selectionKey -> windowSession
    activeWindowKey: 'tid:3',
    drawerOpen: true,
    drawerTab: 'tasks',
    tasks: [],
    ledger: structuredClone(INITIAL_LEDGER),
    mirroringDevices: new Set(),
    activeUploadPickerSelection: new Set(['mac-1', 'mac-2']),
    pendingConflictContext: null,
    pendingGuardAction: null
  };

  // DOM Cache
  const dom = {
    root: document.documentElement,
    menubarApple: document.getElementById('menubar-apple-icon'),
    menubarEndpointPill: document.getElementById('menubar-endpoint-pill'),
    menubarEndpoint: document.getElementById('menubar-endpoint'),
    menubarBtnCc: document.getElementById('menubar-btn-cc'),
    menubarBtnFm: document.getElementById('menubar-btn-fm'),
    menubarBtnQuit: document.getElementById('menubar-btn-quit'),
    btnToggleTweaks: document.getElementById('btn-toggle-tweaks'),
    tweaksToggleIcon: document.getElementById('tweaks-toggle-icon'),
    tweaksPanel: document.getElementById('tweaks-panel'),
    scenarioChips: document.getElementById('scenario-chips'),
    simBtnCloseGuard: document.getElementById('sim-btn-close-guard'),
    simBtnQuitGuard: document.getElementById('sim-btn-quit-guard'),

    // Control Center
    ccDeviceCount: document.getElementById('cc-device-count'),
    ccDeviceList: document.getElementById('cc-device-list'),
    ccBtnRefresh: document.getElementById('cc-btn-refresh'),
    ccEndpointStatus: document.getElementById('cc-endpoint-status'),
    ccGenerationBadge: document.getElementById('cc-generation-badge'),
    ccHeroTitle: document.getElementById('cc-hero-title'),
    ccHeroState: document.getElementById('cc-hero-state'),
    ccHeroMeta: document.getElementById('cc-hero-meta'),
    ccHeroCaps: document.getElementById('cc-hero-caps'),
    ccBtnFiles: document.getElementById('cc-btn-files'),
    ccBtnFilesIcon: document.getElementById('cc-btn-files-icon'),
    ccBtnFilesLabel: document.getElementById('cc-btn-files-label'),
    ccBtnMirror: document.getElementById('cc-btn-mirror'),
    ccBtnMirrorIcon: document.getElementById('cc-btn-mirror-icon'),
    ccBtnMirrorLabel: document.getElementById('cc-btn-mirror-label'),
    ccHeroNotice: document.getElementById('cc-hero-notice'),
    ccGlobalSlots: document.getElementById('cc-global-slots'),

    // File Manager Window
    fileWindow: document.getElementById('file-window'),
    fmWindowTabs: document.getElementById('fm-window-tabs'),
    fmBtnCloseWindow: document.getElementById('fm-btn-close-window'),
    fmWindowTitle: document.getElementById('fm-window-title'),
    fmSessionChip: document.getElementById('fm-session-chip'),
    fmSessionText: document.getElementById('fm-session-text'),
    fmBtnBack: document.getElementById('fm-btn-back'),
    fmBtnRefresh: document.getElementById('fm-btn-refresh'),
    fmBreadcrumbs: document.getElementById('fm-breadcrumbs'),
    fmBtnUpload: document.getElementById('fm-btn-upload'),
    fmIconUpload: document.getElementById('fm-icon-upload'),
    fmBtnDownload: document.getElementById('fm-btn-download'),
    fmIconDownload: document.getElementById('fm-icon-download'),
    fmBtnDelete: document.getElementById('fm-btn-delete'),
    fmIconDelete: document.getElementById('fm-icon-delete'),
    fmBtnDrawer: document.getElementById('fm-btn-drawer'),
    fmIconDrawer: document.getElementById('fm-icon-drawer'),
    fmDrawerBadge: document.getElementById('fm-drawer-badge'),
    fmBanner: document.getElementById('fm-banner'),
    fmBannerIcon: document.getElementById('fm-banner-icon'),
    fmBannerText: document.getElementById('fm-banner-text'),
    fmTableRegion: document.getElementById('fm-table-region'),
    fileTable: document.getElementById('file-table'),
    fmSelectAll: document.getElementById('fm-select-all'),
    fmTbody: document.getElementById('fm-tbody'),
    fmSortStatus: document.getElementById('fm-sort-status'),
    fmStatePanel: document.getElementById('fm-state-panel'),
    fmStateIcon: document.getElementById('fm-state-icon'),
    fmStateTitle: document.getElementById('fm-state-title'),
    fmStateDesc: document.getElementById('fm-state-desc'),
    fmStateActions: document.getElementById('fm-state-actions'),
    fmDrawer: document.getElementById('fm-drawer'),
    tabBtnTasks: document.getElementById('tab-btn-tasks'),
    tabBtnLedger: document.getElementById('tab-btn-ledger'),
    drawerTasksCount: document.getElementById('drawer-tasks-count'),
    drawerLedgerCount: document.getElementById('drawer-ledger-count'),
    fmActiveSlotsLabel: document.getElementById('fm-active-slots-label'),
    fmBtnViewLedgerJson: document.getElementById('fm-btn-view-ledger-json'),
    fmDrawerTasks: document.getElementById('fm-drawer-tasks'),
    fmDrawerLedger: document.getElementById('fm-drawer-ledger'),
    fmStatusLeft: document.getElementById('fm-statusbar-left'),
    fmStatusRight: document.getElementById('fm-statusbar-right'),

    // Dialogs
    uploadPickerDialog: document.getElementById('upload-picker-dialog'),
    uploadPickerClose: document.getElementById('upload-picker-close'),
    uploadPickerDest: document.getElementById('upload-picker-dest'),
    uploadPickerList: document.getElementById('upload-picker-list'),
    uploadPickerCount: document.getElementById('upload-picker-count'),
    uploadPickerCancel: document.getElementById('upload-picker-cancel'),
    uploadPickerConfirm: document.getElementById('upload-picker-confirm'),

    downloadPickerDialog: document.getElementById('download-picker-dialog'),
    downloadPickerClose: document.getElementById('download-picker-close'),
    downloadDestSelect: document.getElementById('download-dest-select'),
    downloadDestExisting: document.getElementById('download-dest-existing'),
    downloadPickerCount: document.getElementById('download-picker-count'),
    downloadPickerCancel: document.getElementById('download-picker-cancel'),
    downloadPickerConfirm: document.getElementById('download-picker-confirm'),

    conflictDialog: document.getElementById('conflict-dialog'),
    conflictSummary: document.getElementById('conflict-summary'),
    conflictList: document.getElementById('conflict-list'),
    conflictApplyAll: document.getElementById('conflict-apply-all'),
    conflictCancelBtn: document.getElementById('conflict-cancel-btn'),
    conflictSkipBtn: document.getElementById('conflict-skip-btn'),
    conflictKeepBtn: document.getElementById('conflict-keep-btn'),

    deleteConfirmDialog: document.getElementById('delete-confirm-dialog'),
    deleteDeviceLabel: document.getElementById('delete-device-label'),
    deletePathLabel: document.getElementById('delete-path-label'),
    deleteCountLabel: document.getElementById('delete-count-label'),
    deleteFileList: document.getElementById('delete-file-list'),
    deleteConfirmCancel: document.getElementById('delete-confirm-cancel'),
    deleteConfirmSubmit: document.getElementById('delete-confirm-submit'),

    deleteResultDialog: document.getElementById('delete-result-dialog'),
    deleteResultClose: document.getElementById('delete-result-close'),
    deleteResultSummary: document.getElementById('delete-result-summary'),
    deleteResultList: document.getElementById('delete-result-list'),
    deleteResultOk: document.getElementById('delete-result-ok'),

    guardDialog: document.getElementById('guard-dialog'),
    guardTitle: document.getElementById('guard-title'),
    guardMessage: document.getElementById('guard-message'),
    guardProgressArea: document.getElementById('guard-progress-area'),
    guardProgressBar: document.getElementById('guard-progress-bar'),
    guardProgressText: document.getElementById('guard-progress-text'),
    guardHint: document.getElementById('guard-hint'),
    guardCancelBtn: document.getElementById('guard-cancel-btn'),
    guardConfirmBtn: document.getElementById('guard-confirm-btn'),

    ledgerJsonDialog: document.getElementById('ledger-json-dialog'),
    ledgerJsonClose: document.getElementById('ledger-json-close'),
    ledgerJsonPre: document.getElementById('ledger-json-pre'),
    ledgerJsonOk: document.getElementById('ledger-json-ok'),

    toastRegion: document.getElementById('toast-region')
  };

  // =================================================
  // Utility Helpers
  // =================================================
  function uuidLike() {
    if (window.crypto && typeof window.crypto.randomUUID === 'function') {
      return window.crypto.randomUUID();
    }
    return 'tmp-' + Math.random().toString(16).slice(2, 10) + '-' + Date.now().toString(16);
  }

  function formatBytes(bytes) {
    if (bytes === null || bytes === undefined) return '—';
    if (bytes === 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.min(units.length - 1, Math.floor(Math.log(bytes) / Math.log(1024)));
    const val = bytes / Math.pow(1024, i);
    return (i === 0 ? String(bytes) : val.toFixed(val >= 100 ? 0 : val >= 10 ? 1 : 2)) + ' ' + units[i];
  }

  function formatDate(unixSec) {
    if (!unixSec) return '—';
    const d = new Date(unixSec * 1000);
    const pad = (n) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  function sanitizeControlDisplay(name) {
    let hasControl = false;
    let out = '';
    for (const ch of name) {
      const code = ch.codePointAt(0);
      if (code === 10) {
        hasControl = true;
        out += '↵';
      } else if (code < 32 || code === 127) {
        hasControl = true;
        out += '^' + String.fromCharCode((code + 64) & 0x7f);
      } else {
        out += ch;
      }
    }
    return { text: out, hasControl };
  }

  function splitStemAndExt(name) {
    if (name.startsWith('.') && name.indexOf('.', 1) === -1) {
      return { stem: name, ext: '' };
    }
    const idx = name.lastIndexOf('.');
    if (idx <= 0) {
      return { stem: name, ext: '' };
    }
    return { stem: name.slice(0, idx), ext: name.slice(idx) };
  }

  function computeRenameCandidate(name, existingNormalizedSet, normalizeFn) {
    const { stem, ext } = splitStemAndExt(name);
    for (let i = 2; i <= 999; i++) {
      const candidate = `${stem} (${i})${ext}`;
      if (!existingNormalizedSet.has(normalizeFn(candidate))) {
        return candidate;
      }
    }
    return null;
  }

  function validateAndroidUploadName(name, parentPhysicalPath) {
    if (!name || name === '.' || name === '..' || name.includes('/') || name.includes('\0')) {
      return { ok: false, reason: '非法路径分量' };
    }
    if (/[\x00-\x1f\x7f?"*:<>\\|]/.test(name)) {
      return { ok: false, reason: '包含 /sdcard 禁止字符 (? " * : < > \\ | 或控制字符)' };
    }
    const byteLen = textEncoder.encode(name).length;
    if (byteLen > 255) {
      return { ok: false, reason: `文件名长度 ${byteLen} B 超过 255 UTF-8 字节上限` };
    }
    const simulatedTmpParam = `${parentPhysicalPath}/.metalcast-tmp-00000000/payload,33188`;
    if (textEncoder.encode(simulatedTmpParam).length > 1024) {
      return { ok: false, reason: '暂存路径加 ,33188 超过 Sync 1024 字节上限' };
    }
    return { ok: true };
  }

  function normalizeAndroidCase(name) {
    return name.toLowerCase();
  }

  function normalizeMacAPFS(name) {
    return name.normalize('NFC').toLowerCase();
  }

  function pathKey(components) {
    return components.length === 0 ? '/' : '/' + components.join('/');
  }

  function isRestrictedComponents(components) {
    return (
      components.length >= 2 &&
      components[0].toLowerCase() === 'android' &&
      (components[1].toLowerCase() === 'data' || components[1].toLowerCase() === 'obb')
    );
  }

  function entryKindLabel(entry) {
    if (entry.isRestricted) return '受限目录';
    if (entry.kind === 'directory') return '文件夹';
    if (entry.kind === 'symlink') return '符号链接';
    if (entry.name.toLowerCase().endsWith('.apk')) return 'APK 文件';
    return '普通文件';
  }

  function entryIconName(entry) {
    if (entry.isRestricted) return 'folderLock';
    if (entry.kind === 'directory') return 'folder';
    if (entry.kind === 'symlink') return 'symlink';
    const lower = entry.name.toLowerCase();
    if (lower.endsWith('.apk')) return 'apk';
    if (/\.(jpg|jpeg|png|webp)$/.test(lower)) return 'image';
    if (/\.(mp4|mov|mkv)$/.test(lower)) return 'video';
    return 'file';
  }

  function renderFilenameElement(name) {
    const { text, hasControl } = sanitizeControlDisplay(name);
    const { stem, ext } = splitStemAndExt(text);
    const outer = document.createElement('span');
    outer.className = 'filename';
    outer.title = text;
    const inner = document.createElement('span');
    inner.textContent = stem;
    outer.appendChild(inner);
    if (ext) {
      outer.appendChild(document.createTextNode(ext));
    }
    return { el: outer, hasControl };
  }

  function showToast(message, tone = 'info') {
    const item = document.createElement('div');
    item.className = `toast-item ${tone}`;

    const iconWrap = document.createElement('span');
    iconWrap.className = 'toast-icon';
    const iconName = tone === 'success' ? 'check' : tone === 'danger' || tone === 'warning' ? 'warning' : 'sliders';
    iconWrap.appendChild(window.McIcons.create(iconName, 16));

    const msgSpan = document.createElement('span');
    msgSpan.className = 'toast-msg';
    msgSpan.textContent = message;

    item.appendChild(iconWrap);
    item.appendChild(msgSpan);
    dom.toastRegion.appendChild(item);

    setTimeout(() => {
      item.remove();
    }, 3400);
  }

  // =================================================
  // Session & Window Management
  // =================================================
  function createWindowSession(device, initialComponents = ['Download']) {
    const tree = appState.fs[device.selectionKey] || { '/': [] };
    const startComps = tree[pathKey(initialComponents)] ? [...initialComponents] : [];
    const session = {
      key: device.selectionKey,
      sessionId: {
        endpoint: { host: appState.endpoint.host, port: appState.endpoint.port },
        serverGeneration: appState.serverGeneration,
        transportId: device.transportId,
        serial: device.serial
      },
      device: structuredClone(device),
      pathComponents: startComps,
      selectedNames: new Set(),
      sortCol: 'name',
      sortDir: 'ascending',
      viewState: resolveViewStateForDevice(device, startComps),
      requestSeq: 1
    };
    return session;
  }

  function resolveViewStateForDevice(device, components) {
    if (appState.endpoint.incompatibleDetail) {
      return 'incompatibleEndpoint';
    }
    if (!device.capabilities || !device.capabilities.hasShellV2) {
      return 'unsupportedShellV2';
    }
    if (device.state !== 'device') {
      return 'disconnected';
    }
    if (isRestrictedComponents(components)) {
      return 'permissionDenied';
    }
    const tree = appState.fs[device.selectionKey] || { '/': [] };
    const key = pathKey(components);
    const parentComps = components.slice(0, -1);
    const parentEntries = tree[pathKey(parentComps)] || [];
    const curEntry = parentEntries.find((e) => e.name === components[components.length - 1]);
    if (curEntry && curEntry.simulateProbeExit === 13) {
      return 'permissionDenied';
    }
    const entries = tree[key] || [];
    if (entries.length === 0) {
      return 'empty';
    }
    return 'normal';
  }

  function getActiveWindow() {
    if (appState.activeWindowKey && appState.openWindows.has(appState.activeWindowKey)) {
      return appState.openWindows.get(appState.activeWindowKey);
    }
    const first = appState.openWindows.values().next();
    return first.done ? null : first.value;
  }

  function openOrFocusFileWindow(device, initialComponents = ['Download']) {
    if (!device || device.state !== 'device' || !device.transportId) {
      showToast('仅对已连接、已授权且具备 transport_id 的设备开放文件窗口', 'warning');
      return;
    }

    if (appState.openWindows.has(device.selectionKey)) {
      appState.activeWindowKey = device.selectionKey;
      renderAll();
      dom.fileWindow.classList.add('window-flash');
      setTimeout(() => dom.fileWindow.classList.remove('window-flash'), 750);
      showToast(`已置前「手机文件 - ${device.model}」（单设备至多一个文件窗口）`, 'info');
      return;
    }

    const session = createWindowSession(device, initialComponents);
    appState.openWindows.set(device.selectionKey, session);
    appState.activeWindowKey = device.selectionKey;
    renderAll();
    showToast(`已打开「手机文件 - ${device.model}」（绑定 tid:${device.transportId}）`, 'success');
  }

  // =================================================
  // Task Queue & Concurrency Scheduler
  // =================================================
  function countActiveGlobalTransferSlots() {
    return appState.tasks.filter(
      (t) => (t.kind === 'upload' || t.kind === 'download') && t.state === 'transferring'
    ).length;
  }

  function updateSlotIndicators() {
    const activeSlots = countActiveGlobalTransferSlots();
    dom.ccGlobalSlots.textContent = `${activeSlots} / ${MAX_GLOBAL_TRANSFER_SLOTS} 活跃`;
    dom.fmActiveSlotsLabel.textContent = `传输槽 ${activeSlots}/${MAX_GLOBAL_TRANSFER_SLOTS}`;

    const activeCount = appState.tasks.filter((t) =>
      ['queued', 'transferring', 'committing', 'pendingConfirmation'].includes(t.state)
    ).length;
    const totalAttention = activeCount + appState.ledger.length;
    dom.fmDrawerBadge.textContent = String(totalAttention);
    dom.fmDrawerBadge.classList.toggle('empty', totalAttention === 0);
    dom.drawerTasksCount.textContent = String(appState.tasks.length);
    dom.drawerLedgerCount.textContent = String(appState.ledger.length);
  }

  function pumpScheduler() {
    // 1. Per-device serial write channel
    const busyDevices = new Set(
      appState.tasks
        .filter((t) => t.state === 'transferring' || t.state === 'committing')
        .map((t) => t.deviceKey)
    );

    for (const task of appState.tasks) {
      if (task.state !== 'queued') continue;
      if (busyDevices.has(task.deviceKey)) continue;

      const activeSlots = countActiveGlobalTransferSlots();
      if (activeSlots >= MAX_GLOBAL_TRANSFER_SLOTS) continue;

      const win = appState.openWindows.get(task.deviceKey);
      if (!win || win.viewState === 'disconnected' || win.sessionId.serverGeneration !== task.sessionGen) {
        task.state = 'failed';
        task.detail = '会话已失效或设备已断线';
        continue;
      }

      busyDevices.add(task.deviceKey);
      startTransferTask(task);
    }
    renderDrawer();
    updateSlotIndicators();
  }

  function startTransferTask(task) {
    task.state = 'transferring';
    task.bytesDone = 0;
    task.rateBytesPerSec = 0;
    task.detail = task.kind === 'upload' ? '正在写入 .metalcast-tmp/payload...' : '正在读取 DATA 帧写入 .part...';

    if (task.kind === 'upload') {
      const ledgerEntry = {
        id: uuidLike().toUpperCase(),
        taskId: task.id,
        endpoint: { ...appState.endpoint },
        serial: task.deviceSerial,
        transportId: task.transportId,
        serverGeneration: task.sessionGen,
        targetParentPhysicalPath: task.parentPhysicalPath,
        tempDirName: task.tempDirName,
        tempPayloadName: 'payload',
        finalTargetName: task.finalName,
        state: 'created',
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      };
      task.ledgerId = ledgerEntry.id;
      appState.ledger.unshift(ledgerEntry);
    }

    const total = task.totalBytes || 8_000_000;
    const steps = Math.max(8, Math.min(20, Math.round(total / 2_000_000) + 8));
    let step = 0;

    task._timer = setInterval(() => {
      if (task.state !== 'transferring') {
        clearInterval(task._timer);
        return;
      }
      step++;
      const ratio = Math.min(0.99, step / steps);
      task.bytesDone = Math.floor(total * ratio);
      task.rateBytesPerSec = task.isWifi ? 14_200_000 : 38_400_000;

      if (step >= steps) {
        clearInterval(task._timer);
        finishTransferAndCommit(task);
      } else {
        renderDrawer();
      }
    }, 110);

    renderDrawer();
    updateSlotIndicators();
  }

  function finishTransferAndCommit(task) {
    const win = appState.openWindows.get(task.deviceKey);
    if (!win || win.viewState === 'disconnected') {
      task.state = 'failed';
      task.detail = '传输中断线';
      if (task.ledgerId) {
        const le = appState.ledger.find((e) => e.id === task.ledgerId);
        if (le) {
          le.state = 'cleanupPending';
          le.updatedAt = new Date().toISOString();
        }
      }
      pumpScheduler();
      return;
    }

    task.state = 'committing';
    if (task.kind === 'upload') {
      const modeText = task.commitMode === 'mvNoClobberNoTarget' ? 'mv -nT' : 'mv -n 护栏';
      task.detail = `正在提交… (${modeText})`;
      const le = appState.ledger.find((e) => e.id === task.ledgerId);
      if (le) {
        le.state = 'committing';
        le.updatedAt = new Date().toISOString();
      }
    } else {
      task.detail = task.isSizeReliable
        ? '校验 64 位长度与元数据后执行 renamex_np(RENAME_EXCL)...'
        : 'v1 元数据跳过长度比对，执行 renamex_np(RENAME_EXCL)...';
    }
    renderDrawer();
    updateSlotIndicators();

    setTimeout(() => {
      if (task.state !== 'committing') return;
      task.state = 'completed';
      task.bytesDone = task.totalBytes || task.bytesDone;

      if (task.kind === 'upload') {
        appState.ledger = appState.ledger.filter((e) => e.id !== task.ledgerId);
        const tree = appState.fs[task.deviceKey];
        const key = pathKey(task.dirComponents);
        if (tree && tree[key]) {
          tree[key].push({
            name: task.finalName,
            kind: 'regular',
            size: task.totalBytes,
            isSizeReliable: task.deviceCaps.hasStatV2,
            mtime: Math.floor(Date.now() / 1000),
            dev: 2049,
            ino: Math.floor(Math.random() * 90000) + 10000
          });
        }
        const mediaNote =
          task.deviceModel === 'Pixel 4 XL' && /\.(jpg|jpeg|png|mp4)$/i.test(task.finalName)
            ? '（Android 10 不主动刷新媒体库，相册可能延迟可见）'
            : '';
        task.detail = `已完成提交 · 已清理临时目录 ${mediaNote}`;

        if (win && pathKey(win.pathComponents) === pathKey(task.dirComponents)) {
          win.viewState = resolveViewStateForDevice(win.device, win.pathComponents);
          renderFileWindow();
        }
        showToast(`上传完成: ${task.finalName}`, 'success');
      } else {
        task.detail = `已原子发布到 ${task.localDestPath}/${task.finalName}`;
        showToast(`下载完成: ${task.finalName}`, 'success');
      }

      pumpScheduler();
    }, 450);
  }

  function cancelTask(taskId) {
    const task = appState.tasks.find((t) => t.id === taskId);
    if (!task) return;
    if (task.state === 'queued') {
      task.state = 'cancelled';
      task.detail = '已从排队中移除';
    } else if (task.state === 'transferring') {
      if (task._timer) clearInterval(task._timer);
      task.state = 'cancelled';
      task.detail = '已关闭连接并清理临时文件';
      if (task.ledgerId) {
        appState.ledger = appState.ledger.filter((e) => e.id !== task.ledgerId);
      }
    }
    pumpScheduler();
  }

  // =================================================
  // Rendering: Control Center
  // =================================================
  function renderControlCenter() {
    dom.ccDeviceCount.textContent = `已连接设备 (${appState.devices.length})`;
    dom.ccEndpointStatus.textContent = appState.endpoint.incompatibleDetail
      ? '不兼容'
      : `${appState.endpoint.host}:${appState.endpoint.port}`;
    dom.ccGenerationBadge.textContent = `Gen #${appState.serverGeneration}`;

    dom.menubarEndpoint.textContent = appState.endpoint.incompatibleDetail
      ? 'ADB 端点配置不兼容'
      : `ADB ${appState.endpoint.host}:${appState.endpoint.port} · Gen #${appState.serverGeneration}`;
    dom.menubarEndpointPill.className = 'endpoint-pill' + (appState.endpoint.incompatibleDetail ? ' error' : '');

    // Device List
    const frag = document.createDocumentFragment();
    for (const dev of appState.devices) {
      const li = document.createElement('li');
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'cc-device-btn' + (dev.selectionKey === appState.selectedDeviceKey ? ' active' : '');
      btn.setAttribute('role', 'option');
      btn.setAttribute('aria-selected', String(dev.selectionKey === appState.selectedDeviceKey));

      const iconWrap = document.createElement('span');
      iconWrap.className = 'cc-dev-icon';
      iconWrap.appendChild(window.McIcons.create(dev.connectionType === 'Wi-Fi' ? 'phoneWifi' : 'phoneUsb', 16));

      const meta = document.createElement('span');
      meta.className = 'cc-dev-meta';
      const nameSpan = document.createElement('span');
      nameSpan.className = 'cc-dev-name';
      nameSpan.textContent = dev.model;
      const subSpan = document.createElement('span');
      subSpan.className = 'cc-dev-sub';
      subSpan.textContent = `${dev.connectionType} · ${dev.state === 'device' ? dev.androidVersion : dev.state}`;
      meta.appendChild(nameSpan);
      meta.appendChild(subSpan);

      const tag = document.createElement('span');
      tag.className = 'cc-dev-tag';
      tag.textContent = dev.transportId ? `tid:${dev.transportId}` : '无 tid';

      btn.appendChild(iconWrap);
      btn.appendChild(meta);
      btn.appendChild(tag);
      btn.addEventListener('click', () => {
        appState.selectedDeviceKey = dev.selectionKey;
        renderControlCenter();
      });

      li.appendChild(btn);
      frag.appendChild(li);
    }
    dom.ccDeviceList.replaceChildren(frag);

    // Hero Card
    const selected = appState.devices.find((d) => d.selectionKey === appState.selectedDeviceKey) || appState.devices[0];
    dom.ccHeroTitle.textContent = `${selected.model} (${selected.androidVersion})`;
    dom.ccHeroState.textContent = selected.state;
    dom.ccHeroState.className = `state-badge state-${selected.state}`;
    dom.ccHeroMeta.textContent = `序列号: ${selected.serial} · transport_id: ${selected.transportId || '缺失'} · ${selected.connectionType}`;

    const capsFrag = document.createDocumentFragment();
    if (selected.capabilities) {
      const caps = selected.capabilities;
      const items = [
        { label: caps.hasShellV2 ? 'shell_v2' : '无 shell_v2', cls: caps.hasShellV2 ? 'ok' : 'bad' },
        { label: caps.hasStatV2 ? 'stat_v2 (64B)' : 'STAT v1 (32B)', cls: caps.hasStatV2 ? 'ok' : 'warn' },
        { label: caps.hasLsV2 ? 'ls_v2 (DNT2)' : 'LIST v1', cls: caps.hasLsV2 ? 'ok' : 'warn' },
        {
          label:
            caps.commitMode === 'mvNoClobberNoTarget'
              ? 'mv -nT'
              : caps.commitMode === 'mvNoClobberWithGuard'
              ? 'mv -n (降级护栏)'
              : '不支持 mv -n',
          cls: caps.commitMode === 'mvNoClobberNoTarget' ? 'ok' : caps.commitMode === 'mvNoClobberWithGuard' ? 'warn' : 'bad'
        }
      ];
      for (const item of items) {
        const chip = document.createElement('span');
        chip.className = `cap-chip ${item.cls}`;
        chip.textContent = item.label;
        capsFrag.appendChild(chip);
      }
    }
    dom.ccHeroCaps.replaceChildren(capsFrag);

    const canOpenFiles = selected.state === 'device' && Boolean(selected.transportId) && !appState.endpoint.incompatibleDetail;
    dom.ccBtnFiles.disabled = !canOpenFiles;
    const isWindowOpen = appState.openWindows.has(selected.selectionKey);
    dom.ccBtnFilesLabel.textContent = isWindowOpen ? '置前文件窗口' : '手机文件';

    const isMirroring = appState.mirroringDevices.has(selected.selectionKey);
    dom.ccBtnMirror.disabled = selected.state !== 'device';
    dom.ccBtnMirrorLabel.textContent = isMirroring ? '停止投屏' : '开启原生投屏';

    if (selected.state !== 'device') {
      dom.ccHeroNotice.hidden = false;
      dom.ccHeroNotice.textContent = '设备尚未授权 USB/无线调试，请在手机上点击「允许调试」后刷新。';
    } else if (selected.capabilities && !selected.capabilities.hasShellV2) {
      dom.ccHeroNotice.hidden = false;
      dom.ccHeroNotice.textContent = '该设备缺少 shell_v2 能力（Android 7.0 以下或定制精简），文件管理窗口将提示暂不支持。';
    } else if (appState.endpoint.incompatibleDetail) {
      dom.ccHeroNotice.hidden = false;
      dom.ccHeroNotice.textContent = `端点配置不兼容：${appState.endpoint.incompatibleDetail}`;
    } else {
      dom.ccHeroNotice.hidden = true;
    }
  }

  // =================================================
  // Rendering: File Manager Window
  // =================================================
  function renderWindowTabs() {
    const frag = document.createDocumentFragment();
    for (const [key, win] of appState.openWindows.entries()) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'win-tab' + (key === appState.activeWindowKey ? ' active' : '');
      btn.textContent = `${win.device.model} (tid:${win.sessionId.transportId})`;
      btn.addEventListener('click', () => {
        appState.activeWindowKey = key;
        renderFileWindow();
      });
      frag.appendChild(btn);
    }
    dom.fmWindowTabs.replaceChildren(frag);
  }

  function getEntriesForWindow(win) {
    const tree = appState.fs[win.key] || { '/': [] };
    return [...(tree[pathKey(win.pathComponents)] || [])];
  }

  function sortEntries(entries, col, dir) {
    const factor = dir === 'ascending' ? 1 : -1;
    return entries.sort((a, b) => {
      const aIsDir = a.kind === 'directory' ? 0 : 1;
      const bIsDir = b.kind === 'directory' ? 0 : 1;
      if (aIsDir !== bIsDir) return aIsDir - bIsDir;

      if (col === 'size') {
        const va = a.isSizeReliable && a.size !== null ? a.size : -1;
        const vb = b.isSizeReliable && b.size !== null ? b.size : -1;
        if (va !== vb) return factor * (va - vb);
      } else if (col === 'mtime') {
        const va = a.mtime || 0;
        const vb = b.mtime || 0;
        if (va !== vb) return factor * (va - vb);
      } else if (col === 'kind') {
        const cmp = collator.compare(entryKindLabel(a), entryKindLabel(b));
        if (cmp !== 0) return factor * cmp;
      }
      return factor * collator.compare(a.name, b.name);
    });
  }

  function renderFileWindow() {
    renderWindowTabs();
    const win = getActiveWindow();

    if (!win) {
      dom.fmWindowTitle.textContent = '手机文件 - 未打开窗口';
      dom.fmSessionChip.className = 'fm-session-chip disconnected';
      dom.fmSessionText.textContent = '无绑定会话';
      dom.fmTableRegion.hidden = true;
      dom.fmStatePanel.hidden = false;
      dom.fmStateIcon.className = 'state-illustration';
      dom.fmStateIcon.replaceChildren(window.McIcons.create('folder', 26));
      dom.fmStateTitle.textContent = '未打开手机文件窗口';
      dom.fmStateDesc.textContent = '请在左侧「MetalCast 控制中心」选择一台已连接且授权的设备，点击「手机文件」打开独立管理窗口。';
      dom.fmStateActions.replaceChildren();
      renderDrawer();
      updateSlotIndicators();
      return;
    }

    const dev = win.device;
    dom.fmWindowTitle.textContent = `手机文件 - ${dev.model}`;

    if (win.viewState === 'disconnected' || win.viewState === 'incompatibleEndpoint') {
      dom.fmSessionChip.className = 'fm-session-chip disconnected';
      dom.fmSessionText.textContent = win.viewState === 'disconnected'
        ? `${dev.connectionType} · tid:${win.sessionId.transportId} · 已断线 (Gen #${win.sessionId.serverGeneration})`
        : '端点不兼容';
    } else if (dev.capabilities && (!dev.capabilities.hasStatV2 || dev.capabilities.commitMode !== 'mvNoClobberNoTarget')) {
      dom.fmSessionChip.className = 'fm-session-chip degraded';
      dom.fmSessionText.textContent = `${dev.connectionType} · tid:${win.sessionId.transportId} · Gen #${win.sessionId.serverGeneration} (降级)`;
    } else {
      dom.fmSessionChip.className = 'fm-session-chip';
      dom.fmSessionText.textContent = `${dev.connectionType} · tid:${win.sessionId.transportId} · Gen #${win.sessionId.serverGeneration}`;
    }

    // Breadcrumbs
    const crumbFrag = document.createDocumentFragment();
    const rootBtn = document.createElement('button');
    rootBtn.type = 'button';
    rootBtn.className = 'crumb-btn';
    rootBtn.textContent = '共享存储';
    if (win.pathComponents.length === 0) rootBtn.setAttribute('aria-current', 'location');
    rootBtn.addEventListener('click', () => navigateWindow(win, []));
    crumbFrag.appendChild(rootBtn);

    win.pathComponents.forEach((seg, idx) => {
      const sep = document.createElement('span');
      sep.className = 'crumb-sep';
      sep.textContent = '›';
      crumbFrag.appendChild(sep);

      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'crumb-btn';
      btn.textContent = seg;
      if (idx === win.pathComponents.length - 1) btn.setAttribute('aria-current', 'location');
      const targetPath = win.pathComponents.slice(0, idx + 1);
      btn.addEventListener('click', () => navigateWindow(win, targetPath));
      crumbFrag.appendChild(btn);
    });
    dom.fmBreadcrumbs.replaceChildren(crumbFrag);

    // Banner
    if (win.viewState === 'normal' && dev.capabilities) {
      const msgs = [];
      if (!dev.capabilities.hasStatV2) {
        msgs.push('当前设备使用 v1 元数据（文件大小不可用于下载长度校验，≥ 4 GiB 采用未知进度）');
      }
      if (dev.capabilities.commitMode === 'mvNoClobberWithGuard') {
        msgs.push('旧版 Toybox 不支持 mv -nT，已切换为 mv -n 护栏提交');
      } else if (dev.capabilities.commitMode === 'unsupported') {
        msgs.push('当前设备缺少 mv -n 能力，已禁用上传，浏览/下载/删除仍可正常使用');
      }
      if (dev.androidVersion === 'Android 10') {
        msgs.push('首版不主动刷新媒体库，上传至 DCIM/Pictures 后系统相册可能延迟可见');
      }
      if (msgs.length > 0) {
        dom.fmBanner.hidden = false;
        dom.fmBannerIcon.replaceChildren(window.McIcons.create('warning', 15));
        dom.fmBannerText.textContent = msgs.join('；') + '。';
      } else {
        dom.fmBanner.hidden = true;
      }
    } else {
      dom.fmBanner.hidden = true;
    }

    // Toolbar button states
    const canOperate = win.viewState === 'normal' || win.viewState === 'empty';
    const canUpload = canOperate && dev.capabilities && dev.capabilities.commitMode !== 'unsupported';
    dom.fmBtnBack.disabled = win.pathComponents.length === 0 || win.viewState === 'disconnected' || win.viewState === 'incompatibleEndpoint';
    dom.fmBtnRefresh.disabled = win.viewState === 'incompatibleEndpoint';
    dom.fmBtnUpload.disabled = !canUpload;

    // Main Content Switch (Table vs State Panel)
    if (win.viewState === 'normal') {
      dom.fmTableRegion.hidden = false;
      dom.fmStatePanel.hidden = true;
      renderFileTable(win);
    } else {
      dom.fmTableRegion.hidden = true;
      dom.fmStatePanel.hidden = false;
      renderStatePanel(win);
    }

    updateToolbarSelectionButtons(win);
    renderDrawer();
    updateSlotIndicators();

    // Status bar
    const entries = win.viewState === 'normal' ? getEntriesForWindow(win) : [];
    dom.fmStatusLeft.textContent = `物理根: ${dev.physicalRoot || '未解析'} · 当前共 ${entries.length} 项 · 已选 ${win.selectedNames.size} 项`;
    if (dev.capabilities) {
      const capStr = [
        dev.capabilities.hasShellV2 ? 'shell_v2' : '无 shell_v2',
        dev.capabilities.hasStatV2 ? 'stat_v2' : 'STAT v1',
        dev.capabilities.hasLsV2 ? 'ls_v2' : 'LIST v1',
        dev.capabilities.commitMode === 'mvNoClobberNoTarget' ? 'mv -nT' : dev.capabilities.commitMode === 'mvNoClobberWithGuard' ? 'mv -n' : '无 mv -n'
      ].join(' · ');
      dom.fmStatusRight.textContent = capStr;
    } else {
      dom.fmStatusRight.textContent = '能力未探测';
    }
  }

  function renderFileTable(win) {
    const rawEntries = getEntriesForWindow(win);
    const entries = sortEntries(rawEntries, win.sortCol, win.sortDir);

    // Sync aria-sort headers
    for (const th of dom.fileTable.tHead.rows[0].cells) {
      const type = th.dataset.type;
      if (!type) continue;
      const colKey = th.classList.contains('col-name')
        ? 'name'
        : th.classList.contains('col-kind')
        ? 'kind'
        : th.classList.contains('col-size')
        ? 'size'
        : 'mtime';
      if (colKey === win.sortCol) {
        th.setAttribute('aria-sort', win.sortDir);
      } else {
        th.removeAttribute('aria-sort');
      }
    }

    const frag = document.createDocumentFragment();
    for (const entry of entries) {
      const tr = document.createElement('tr');
      tr.dataset.name = entry.name;
      tr.dataset.isDir = entry.kind === 'directory' ? '1' : '0';
      tr.dataset.kindLabel = entryKindLabel(entry);
      tr.dataset.sizeVal = entry.isSizeReliable && entry.size !== null ? String(entry.size) : '-1';
      tr.dataset.mtimeVal = String(entry.mtime || 0);

      const isOperableRegular = entry.kind === 'regular' && !entry.isRestricted && entry.isLosslessUTF8 !== false;
      const isSelected = win.selectedNames.has(entry.name);
      if (isSelected) tr.classList.add('selected');
      if (entry.isRestricted) tr.classList.add('restricted');

      // Col 1: Checkbox
      const tdCheck = document.createElement('td');
      tdCheck.className = 'cell-check';
      const cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.checked = isSelected;
      cb.disabled = !isOperableRegular;
      cb.setAttribute('aria-label', `选择 ${entry.name}`);
      cb.addEventListener('click', (e) => e.stopPropagation());
      cb.addEventListener('change', () => {
        if (cb.checked) win.selectedNames.add(entry.name);
        else win.selectedNames.delete(entry.name);
        tr.classList.toggle('selected', cb.checked);
        updateToolbarSelectionButtons(win);
      });
      tdCheck.appendChild(cb);

      // Col 2: Name (single-line truncation keeping extension visible)
      const tdName = document.createElement('td');
      const wrap = document.createElement('div');
      wrap.className = 'name-cell-wrap';

      const iconSpan = document.createElement('span');
      iconSpan.className = 'entry-icon';
      if (entry.isRestricted) iconSpan.classList.add('is-restricted');
      else if (entry.kind === 'directory') iconSpan.classList.add('is-dir');
      else if (entry.isLosslessUTF8 === false) iconSpan.classList.add('is-warn');
      iconSpan.appendChild(window.McIcons.create(entryIconName(entry), 15));
      wrap.appendChild(iconSpan);

      const { el: fnEl, hasControl } = renderFilenameElement(entry.name);
      wrap.appendChild(fnEl);

      if (entry.isRestricted) {
        const tag = document.createElement('span');
        tag.className = 'entry-tag restricted';
        tag.textContent = '首版不支持访问';
        wrap.appendChild(tag);
      } else if (entry.kind === 'symlink') {
        const tag = document.createElement('span');
        tag.className = 'entry-tag';
        tag.textContent = '符号链接 · 仅展示';
        wrap.appendChild(tag);
      } else if (entry.isLosslessUTF8 === false) {
        const tag = document.createElement('span');
        tag.className = 'entry-tag danger';
        tag.textContent = '非 UTF-8 · 不可操作';
        wrap.appendChild(tag);
      } else if (hasControl) {
        const tag = document.createElement('span');
        tag.className = 'entry-tag';
        tag.textContent = '控制字符转义';
        wrap.appendChild(tag);
      }
      tdName.appendChild(wrap);

      // Col 3: Kind
      const tdKind = document.createElement('td');
      tdKind.className = 'cell-muted';
      tdKind.textContent = entryKindLabel(entry);

      // Col 4: Size
      const tdSize = document.createElement('td');
      tdSize.className = 'cell-muted';
      if (entry.kind === 'directory') {
        tdSize.textContent = '—';
      } else if (!entry.isSizeReliable) {
        tdSize.textContent = entry.size !== null ? `${formatBytes(entry.size)} (v1)` : '未知 (v1)';
      } else {
        tdSize.textContent = formatBytes(entry.size);
      }

      // Col 5: Mtime
      const tdMtime = document.createElement('td');
      tdMtime.className = 'cell-muted';
      tdMtime.textContent = formatDate(entry.mtime);

      tr.appendChild(tdCheck);
      tr.appendChild(tdName);
      tr.appendChild(tdKind);
      tr.appendChild(tdSize);
      tr.appendChild(tdMtime);

      tr.addEventListener('click', (e) => {
        if (!isOperableRegular) return;
        if (!e.metaKey && !e.shiftKey) {
          win.selectedNames.clear();
          win.selectedNames.add(entry.name);
        } else if (win.selectedNames.has(entry.name)) {
          win.selectedNames.delete(entry.name);
        } else {
          win.selectedNames.add(entry.name);
        }
        renderFileTable(win);
        updateToolbarSelectionButtons(win);
      });

      tr.addEventListener('dblclick', () => {
        if (entry.isRestricted) {
          showToast(`已拦截：首版不支持访问 Android/${entry.name}（restrictedPath）`, 'warning');
          return;
        }
        if (entry.kind === 'directory') {
          navigateWindow(win, [...win.pathComponents, entry.name]);
        } else if (entry.kind === 'symlink') {
          showToast('符号链接仅作展示，不跟随进入或当作普通文件操作', 'info');
        }
      });

      frag.appendChild(tr);
    }

    dom.fmTbody.replaceChildren(frag);

    const operableCount = entries.filter((e) => e.kind === 'regular' && !e.isRestricted && e.isLosslessUTF8 !== false).length;
    dom.fmSelectAll.disabled = operableCount === 0;
    dom.fmSelectAll.checked = operableCount > 0 && win.selectedNames.size === operableCount;
  }

  function updateToolbarSelectionButtons(win) {
    const canOperate = win && win.viewState === 'normal';
    const hasSel = canOperate && win.selectedNames.size > 0;
    dom.fmBtnDownload.disabled = !hasSel;
    dom.fmBtnDelete.disabled = !hasSel;
    dom.fmStatusLeft.textContent = win
      ? `物理根: ${win.device.physicalRoot || '未解析'} · 当前共 ${getEntriesForWindow(win).length} 项 · 已选 ${win.selectedNames.size} 项`
      : '';
  }

  function renderStatePanel(win) {
    const actions = document.createDocumentFragment();
    if (win.viewState === 'empty') {
      dom.fmStateIcon.className = 'state-illustration';
      dom.fmStateIcon.replaceChildren(window.McIcons.create('folder', 26));
      dom.fmStateTitle.textContent = '此文件夹为空';
      dom.fmStateDesc.textContent = 'LIST/LIS2 返回空结果，且经 Shell 访问探测确认（exit 0）当前目录存在且可读。你可以将 Mac 上的普通文件上传到此目录。';
      const upBtn = document.createElement('button');
      upBtn.type = 'button';
      upBtn.className = 'btn-primary';
      upBtn.textContent = '上传文件到当前目录';
      upBtn.addEventListener('click', openUploadPicker);
      actions.appendChild(upBtn);
    } else if (win.viewState === 'permissionDenied') {
      dom.fmStateIcon.className = 'state-illustration warning';
      dom.fmStateIcon.replaceChildren(window.McIcons.create('folderLock', 26));
      dom.fmStateTitle.textContent = '无权限访问此目录';
      dom.fmStateDesc.textContent = isRestrictedComponents(win.pathComponents)
        ? '首版已将 Android/data 与 Android/obb 排除在支持范围外，服务层已拦截导航与读写请求。'
        : 'Shell 访问探测返回退出码 13（权限不足或无法枚举），已阻断浏览并避免误判为空目录。';
      const backBtn = document.createElement('button');
      backBtn.type = 'button';
      backBtn.className = 'btn-secondary';
      backBtn.textContent = '返回上一级';
      backBtn.addEventListener('click', () => navigateWindow(win, win.pathComponents.slice(0, -1)));
      actions.appendChild(backBtn);
    } else if (win.viewState === 'disconnected') {
      dom.fmStateIcon.className = 'state-illustration error';
      dom.fmStateIcon.replaceChildren(window.McIcons.create('disconnect', 26));
      dom.fmStateTitle.textContent = '设备连接已断开';
      dom.fmStateDesc.textContent = `跟踪通道检测到 ${win.device.model}（tid:${win.sessionId.transportId}）已断开或会话代次已变化。为防止跨设备误操作，窗口不会自动切换到其他在线设备；请重新连接并在核对设备后继续。`;
      const reconBtn = document.createElement('button');
      reconBtn.type = 'button';
      reconBtn.className = 'btn-primary';
      reconBtn.textContent = '重新连接并核对设备';
      reconBtn.addEventListener('click', () => reconnectWindowSession(win));
      actions.appendChild(reconBtn);
    } else if (win.viewState === 'unsupportedShellV2') {
      dom.fmStateIcon.className = 'state-illustration error';
      dom.fmStateIcon.replaceChildren(window.McIcons.create('warning', 26));
      dom.fmStateTitle.textContent = '当前设备暂不支持所需 Shell 协议';
      dom.fmStateDesc.textContent = `${win.device.model}（${win.device.androidVersion}）未报告 shell_v2 能力。首版需要 Android 7.0+ 的 shell_v2 帧退出码验证目录范围与写操作结果。`;
    } else if (win.viewState === 'incompatibleEndpoint') {
      dom.fmStateIcon.className = 'state-illustration error';
      dom.fmStateIcon.replaceChildren(window.McIcons.create('warning', 26));
      dom.fmStateTitle.textContent = 'ADB 端点配置不兼容';
      dom.fmStateDesc.textContent = appState.endpoint.incompatibleDetail || '检测到未支持的 ADB 环境变量配置，请使用本地 TCP 端点。';
      const resetBtn = document.createElement('button');
      resetBtn.type = 'button';
      resetBtn.className = 'btn-secondary';
      resetBtn.textContent = '恢复默认 127.0.0.1:5037';
      resetBtn.addEventListener('click', () => applyScenario('normal'));
      actions.appendChild(resetBtn);
    }
    dom.fmStateActions.replaceChildren(actions);
  }

  function navigateWindow(win, nextComponents) {
    if (win.viewState === 'disconnected' || win.viewState === 'incompatibleEndpoint') return;
    if (isRestrictedComponents(nextComponents)) {
      showToast('首版不支持访问 Android/data 与 Android/obb（restrictedPath）', 'warning');
      return;
    }
    win.requestSeq += 1;
    win.pathComponents = [...nextComponents];
    win.selectedNames.clear();
    win.viewState = resolveViewStateForDevice(win.device, win.pathComponents);
    renderFileWindow();
  }

  function reconnectWindowSession(win) {
    appState.serverGeneration += 1;
    const newTid = String(Number(win.device.transportId || 3) + 1);
    win.device.state = 'device';
    win.device.transportId = newTid;
    win.sessionId = {
      ...win.sessionId,
      serverGeneration: appState.serverGeneration,
      transportId: newTid
    };

    const devRef = appState.devices.find((d) => d.serial === win.device.serial);
    if (devRef) {
      devRef.state = 'device';
      devRef.transportId = newTid;
    }

    win.viewState = resolveViewStateForDevice(win.device, win.pathComponents);
    renderControlCenter();
    renderFileWindow();
    showToast(`已重新绑定 ${win.device.model}（新 transport_id: ${newTid} · Gen #${appState.serverGeneration}）`, 'success');
  }

  // =================================================
  // Sortable Table (Modern Web Guidance)
  // =================================================
  function sortByHeaderButton(button) {
    const win = getActiveWindow();
    if (!win || win.viewState !== 'normal') return;

    const th = button.closest('th');
    if (!th) return;
    const colKey = th.classList.contains('col-name')
      ? 'name'
      : th.classList.contains('col-kind')
      ? 'kind'
      : th.classList.contains('col-size')
      ? 'size'
      : 'mtime';

    const nextDir =
      win.sortCol === colKey && win.sortDir === 'ascending' ? 'descending' : 'ascending';
    win.sortCol = colKey;
    win.sortDir = nextDir;

    for (const header of dom.fileTable.tHead.rows[0].cells) {
      header.removeAttribute('aria-sort');
    }
    th.setAttribute('aria-sort', nextDir);

    const rows = [...dom.fmTbody.rows];
    const factor = nextDir === 'ascending' ? 1 : -1;
    rows.sort((a, b) => {
      const aDir = Number(a.dataset.isDir) ? 0 : 1;
      const bDir = Number(b.dataset.isDir) ? 0 : 1;
      if (aDir !== bDir) return aDir - bDir;

      if (colKey === 'size') {
        const va = Number(a.dataset.sizeVal);
        const vb = Number(b.dataset.sizeVal);
        if (va !== vb) return factor * (va - vb);
      } else if (colKey === 'mtime') {
        const va = Number(a.dataset.mtimeVal);
        const vb = Number(b.dataset.mtimeVal);
        if (va !== vb) return factor * (va - vb);
      } else if (colKey === 'kind') {
        const cmp = collator.compare(a.dataset.kindLabel, b.dataset.kindLabel);
        if (cmp !== 0) return factor * cmp;
      }
      return factor * collator.compare(a.dataset.name, b.dataset.name);
    });

    const moveRow = (row) => {
      if (typeof dom.fmTbody.moveBefore === 'function') {
        dom.fmTbody.moveBefore(row, null);
      } else {
        dom.fmTbody.appendChild(row);
      }
    };
    for (const row of rows) {
      moveRow(row);
    }

    const colName = button.textContent.trim();
    dom.fmSortStatus.textContent = `已按${colName}${nextDir === 'ascending' ? '升序' : '降序'}排列，共 ${rows.length} 项`;
  }

  dom.fileTable.addEventListener('command', (event) => {
    if (event.command === '--sort' && event.source) {
      sortByHeaderButton(event.source);
    }
  });

  if (!('commandForElement' in HTMLButtonElement.prototype)) {
    for (const btn of dom.fileTable.tHead.querySelectorAll('button[command="--sort"]')) {
      btn.addEventListener('click', () => sortByHeaderButton(btn));
    }
  }

  // =================================================
  // Drawer Rendering (Tasks & Cleanup Ledger)
  // =================================================
  function renderDrawer() {
    dom.fmDrawer.hidden = !appState.drawerOpen;
    dom.fmBtnDrawer.setAttribute('aria-expanded', String(appState.drawerOpen));
    dom.fmDrawerTasks.hidden = appState.drawerTab !== 'tasks';
    dom.fmDrawerLedger.hidden = appState.drawerTab !== 'ledger';
    dom.tabBtnTasks.classList.toggle('active', appState.drawerTab === 'tasks');
    dom.tabBtnLedger.classList.toggle('active', appState.drawerTab === 'ledger');
    dom.tabBtnTasks.setAttribute('aria-selected', String(appState.drawerTab === 'tasks'));
    dom.tabBtnLedger.setAttribute('aria-selected', String(appState.drawerTab === 'ledger'));

    // Render Tasks
    if (appState.tasks.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'drawer-empty';
      empty.textContent = '暂无传输或删除任务。点击上方「上传文件」「下载所选」体验队列调度与状态流转。';
      dom.fmDrawerTasks.replaceChildren(empty);
    } else {
      const frag = document.createDocumentFragment();
      for (const t of appState.tasks) {
        const row = document.createElement('div');
        row.className = 'task-row';

        const info = document.createElement('div');
        info.className = 'task-info';

        const top = document.createElement('div');
        top.className = 'task-top';
        const kindBadge = document.createElement('span');
        kindBadge.className = 'task-kind-badge';
        kindBadge.textContent = t.kind === 'upload' ? '上传' : '下载';
        const nameSpan = document.createElement('span');
        nameSpan.className = 'task-name';
        nameSpan.textContent = `${t.finalName} (${t.deviceModel})`;
        const statePill = document.createElement('span');
        statePill.className = `task-state-pill ${t.state}`;
        statePill.textContent = stateLabel(t.state);
        top.appendChild(kindBadge);
        top.appendChild(nameSpan);
        top.appendChild(statePill);

        const track = document.createElement('div');
        track.className = 'progress-track';
        const fill = document.createElement('div');
        fill.className = 'progress-fill';
        if (t.state === 'transferring' && !t.isSizeReliable) {
          fill.classList.add('indeterminate');
        } else {
          const pct =
            t.state === 'completed'
              ? 100
              : t.state === 'committing'
              ? 99
              : t.totalBytes
              ? Math.min(99, Math.round((t.bytesDone / t.totalBytes) * 100))
              : 0;
          fill.style.width = `${pct}%`;
        }
        track.appendChild(fill);

        const sub = document.createElement('div');
        sub.className = 'task-sub';
        const pctText =
          t.state === 'completed'
            ? '100%'
            : !t.isSizeReliable && t.state === 'transferring'
            ? `已传输 ${formatBytes(t.bytesDone)} (v1 未知总大小)`
            : t.totalBytes
            ? `${Math.min(99, Math.round((t.bytesDone / t.totalBytes) * 100))}% · ${formatBytes(t.bytesDone)} / ${formatBytes(t.totalBytes)}`
            : '';
        const rateText = t.state === 'transferring' && t.rateBytesPerSec ? `${formatBytes(t.rateBytesPerSec)}/s` : '';
        sub.textContent = [pctText, rateText, t.detail].filter(Boolean).join(' · ');

        info.appendChild(top);
        info.appendChild(track);
        info.appendChild(sub);

        const actions = document.createElement('div');
        actions.className = 'task-actions';
        if (t.state === 'queued' || t.state === 'transferring') {
          const btnCancel = document.createElement('button');
          btnCancel.type = 'button';
          btnCancel.className = 'mini-btn';
          btnCancel.textContent = '取消';
          btnCancel.addEventListener('click', () => cancelTask(t.id));
          actions.appendChild(btnCancel);
        } else if (t.state === 'pendingConfirmation') {
          const btnVerify = document.createElement('button');
          btnVerify.type = 'button';
          btnVerify.className = 'mini-btn primary';
          btnVerify.textContent = '核对结果';
          btnVerify.addEventListener('click', () => verifyPendingTask(t));
          actions.appendChild(btnVerify);
        } else if (t.state === 'completed' && t.kind === 'download') {
          const btnFinder = document.createElement('button');
          btnFinder.type = 'button';
          btnFinder.className = 'mini-btn primary';
          btnFinder.textContent = '在 Finder 中显示';
          btnFinder.addEventListener('click', () => {
            showToast(`已在 Finder 中定位: ${t.localDestPath}/${t.finalName}`, 'info');
          });
          actions.appendChild(btnFinder);
        } else if (t.state === 'failed') {
          const btnRetry = document.createElement('button');
          btnRetry.type = 'button';
          btnRetry.className = 'mini-btn primary';
          btnRetry.textContent = '重试';
          btnRetry.addEventListener('click', () => retryFailedTask(t));
          actions.appendChild(btnRetry);
        }

        row.appendChild(info);
        row.appendChild(actions);
        frag.appendChild(row);
      }
      dom.fmDrawerTasks.replaceChildren(frag);
    }

    // Render Ledger
    if (appState.ledger.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'drawer-empty';
      empty.textContent = '当前没有未收敛的暂存清理记录。';
      dom.fmDrawerLedger.replaceChildren(empty);
    } else {
      const frag = document.createDocumentFragment();
      for (const le of appState.ledger) {
        const row = document.createElement('div');
        row.className = 'ledger-row';

        const info = document.createElement('div');
        info.className = 'task-info';
        const top = document.createElement('div');
        top.className = 'task-top';
        const nameSpan = document.createElement('span');
        nameSpan.className = 'task-name';
        nameSpan.textContent = `${le.tempDirName}/${le.tempPayloadName} → ${le.finalTargetName}`;
        const pill = document.createElement('span');
        pill.className = `task-state-pill ${le.state === 'pendingConfirmation' || le.state === 'cleanupPending' ? 'warning' : ''}`;
        pill.textContent = le.state;
        top.appendChild(nameSpan);
        top.appendChild(pill);

        const sub = document.createElement('div');
        sub.className = 'task-sub';
        sub.textContent = `设备 ${le.serial} (tid:${le.transportId} · Gen #${le.serverGeneration}) · 目录 ${le.targetParentPhysicalPath}`;

        info.appendChild(top);
        info.appendChild(sub);

        const actions = document.createElement('div');
        actions.className = 'task-actions';

        const btnRetry = document.createElement('button');
        btnRetry.type = 'button';
        btnRetry.className = 'mini-btn primary';
        btnRetry.textContent = '重试清理';
        btnRetry.addEventListener('click', () => {
          const online = appState.devices.find(
            (d) => d.serial === le.serial && d.state === 'device'
          );
          if (!online) {
            showToast(`无法确认设备 ${le.serial} 在线，请先重新连接或选择「忽略」`, 'warning');
            return;
          }
          appState.ledger = appState.ledger.filter((e) => e.id !== le.id);
          renderDrawer();
          updateSlotIndicators();
          showToast(`已通过 Shell 清理 ${le.tempDirName} 并移除账本记录`, 'success');
        });

        const btnDismiss = document.createElement('button');
        btnDismiss.type = 'button';
        btnDismiss.className = 'mini-btn';
        btnDismiss.textContent = '忽略并移除';
        btnDismiss.addEventListener('click', () => {
          appState.ledger = appState.ledger.filter((e) => e.id !== le.id);
          renderDrawer();
          updateSlotIndicators();
          showToast('已忽略并移除该残留清理记录', 'info');
        });

        actions.appendChild(btnRetry);
        actions.appendChild(btnDismiss);
        row.appendChild(info);
        row.appendChild(actions);
        frag.appendChild(row);
      }
      dom.fmDrawerLedger.replaceChildren(frag);
    }
  }

  function stateLabel(state) {
    const map = {
      queued: '排队',
      transferring: '传输中',
      committing: '正在提交',
      completed: '已完成',
      skipped: '已跳过',
      cancelled: '已取消',
      failed: '失败',
      pendingConfirmation: '待确认'
    };
    return map[state] || state;
  }

  function verifyPendingTask(task) {
    const win = appState.openWindows.get(task.deviceKey);
    if (!win || win.viewState === 'disconnected') {
      showToast('设备仍处于断线状态，请先点击「重新连接并核对设备」', 'warning');
      return;
    }
    task.state = 'completed';
    task.bytesDone = task.totalBytes || task.bytesDone;
    task.detail = '只读核对确认：远端最终文件完整存在，已清除空暂存目录';
    appState.ledger = appState.ledger.filter((e) => e.id !== task.ledgerId);
    const tree = appState.fs[task.deviceKey];
    const key = pathKey(task.dirComponents);
    if (tree && tree[key] && !tree[key].some((e) => e.name === task.finalName)) {
      tree[key].push({
        name: task.finalName,
        kind: 'regular',
        size: task.totalBytes || 12_400_000,
        isSizeReliable: true,
        mtime: Math.floor(Date.now() / 1000),
        dev: 2049,
        ino: 88210
      });
    }
    renderFileWindow();
    showToast(`核对完成：${task.finalName} 已在手机端提交生效`, 'success');
  }

  function retryFailedTask(task) {
    const win = appState.openWindows.get(task.deviceKey);
    if (!win || win.viewState === 'disconnected') {
      showToast('请先重新连接设备再重试', 'warning');
      return;
    }
    task.sessionGen = win.sessionId.serverGeneration;
    task.transportId = win.sessionId.transportId;
    task.state = 'queued';
    task.detail = '重新校验会话与路径后已入队';
    pumpScheduler();
  }

  // =================================================
  // Upload / Download / Delete Modal Flows
  // =================================================
  function openUploadPicker() {
    const win = getActiveWindow();
    if (!win || win.device.capabilities.commitMode === 'unsupported') return;

    const physicalDir = win.device.physicalRoot + (win.pathComponents.length ? '/' + win.pathComponents.join('/') : '');
    dom.uploadPickerDest.textContent = `目标目录: ${physicalDir}（提交模式: ${win.device.capabilities.commitMode === 'mvNoClobberNoTarget' ? 'mv -nT' : 'mv -n 护栏'}）`;

    const frag = document.createDocumentFragment();
    for (const item of MAC_UPLOAD_POOL) {
      const check = validateAndroidUploadName(item.name, physicalDir);
      const row = document.createElement('label');
      row.className = 'picker-row' + (check.ok ? '' : ' invalid');

      const cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.checked = appState.activeUploadPickerSelection.has(item.id);
      cb.addEventListener('change', () => {
        if (cb.checked) appState.activeUploadPickerSelection.add(item.id);
        else appState.activeUploadPickerSelection.delete(item.id);
        updateUploadPickerCount();
      });

      const meta = document.createElement('div');
      meta.className = 'picker-meta';
      const title = document.createElement('span');
      title.className = 'picker-name';
      title.textContent = `${item.name} (${formatBytes(item.size)})`;
      const sub = document.createElement('span');
      sub.className = 'picker-sub' + (check.ok ? '' : ' error');
      sub.textContent = check.ok ? item.note : `前置拦截：${check.reason}`;
      meta.appendChild(title);
      meta.appendChild(sub);

      row.appendChild(cb);
      row.appendChild(meta);
      frag.appendChild(row);
    }

    dom.uploadPickerList.replaceChildren(frag);
    updateUploadPickerCount();
    dom.uploadPickerDialog.showModal();
  }

  function updateUploadPickerCount() {
    const count = appState.activeUploadPickerSelection.size;
    dom.uploadPickerCount.textContent = `已选 ${count} 个文件`;
    dom.uploadPickerConfirm.disabled = count === 0;
  }

  function handleUploadConfirm() {
    const win = getActiveWindow();
    if (!win) return;
    const physicalDir = win.device.physicalRoot + (win.pathComponents.length ? '/' + win.pathComponents.join('/') : '');
    const selectedItems = MAC_UPLOAD_POOL.filter((item) => appState.activeUploadPickerSelection.has(item.id));
    dom.uploadPickerDialog.close('confirm');

    const validItems = [];
    const rejected = [];
    for (const item of selectedItems) {
      const check = validateAndroidUploadName(item.name, physicalDir);
      if (check.ok) validItems.push(item);
      else rejected.push(`${item.name}: ${check.reason}`);
    }

    if (rejected.length > 0) {
      showToast(`已前置拦截 ${rejected.length} 个不合规文件（${rejected[0]}）`, 'warning');
    }
    if (validItems.length === 0) return;

    const existingEntries = getEntriesForWindow(win);
    const existingSet = new Set(existingEntries.map((e) => normalizeAndroidCase(e.name)));
    const conflicts = [];
    const nonConflicts = [];

    for (const item of validItems) {
      const norm = normalizeAndroidCase(item.name);
      if (existingSet.has(norm)) {
        const preview = computeRenameCandidate(item.name, existingSet, normalizeAndroidCase);
        conflicts.push({ item, preview });
        if (preview) existingSet.add(normalizeAndroidCase(preview));
      } else {
        existingSet.add(norm);
        nonConflicts.push({ item, finalName: item.name });
      }
    }

    if (conflicts.length > 0) {
      openConflictDialog('upload', win, physicalDir, nonConflicts, conflicts, existingEntries.map((e) => e.name));
    } else {
      enqueueUploadItems(win, physicalDir, nonConflicts.map((x) => ({ ...x.item, finalName: x.finalName })));
    }
  }

  function openDownloadPicker() {
    const win = getActiveWindow();
    if (!win) return;
    const count = win.selectedNames.size;
    if (count === 0) return;
    dom.downloadPickerCount.textContent = `待下载 ${count} 个普通文件`;
    renderDownloadDestExisting();
    dom.downloadPickerDialog.showModal();
  }

  function renderDownloadDestExisting() {
    const destKey = dom.downloadDestSelect.value;
    const dest = MAC_DOWNLOAD_DESTS[destKey];
    const frag = document.createDocumentFragment();
    if (dest.existing.length === 0) {
      const li = document.createElement('li');
      li.textContent = '（空目录）';
      frag.appendChild(li);
    } else {
      for (const name of dest.existing) {
        const li = document.createElement('li');
        li.textContent = sanitizeControlDisplay(name).text;
        frag.appendChild(li);
      }
    }
    dom.downloadDestExisting.replaceChildren(frag);
  }

  function handleDownloadConfirm() {
    const win = getActiveWindow();
    if (!win) return;
    const destKey = dom.downloadDestSelect.value;
    const dest = MAC_DOWNLOAD_DESTS[destKey];
    dom.downloadPickerDialog.close('confirm');

    const entries = getEntriesForWindow(win).filter((e) => win.selectedNames.has(e.name));
    const existingSet = new Set(dest.existing.map((n) => normalizeMacAPFS(n)));
    const conflicts = [];
    const nonConflicts = [];

    for (const entry of entries) {
      const norm = normalizeMacAPFS(entry.name);
      if (existingSet.has(norm)) {
        const preview = computeRenameCandidate(entry.name, existingSet, normalizeMacAPFS);
        conflicts.push({ item: entry, preview });
        if (preview) existingSet.add(normalizeMacAPFS(preview));
      } else {
        existingSet.add(norm);
        nonConflicts.push({ item: entry, finalName: entry.name });
      }
    }

    if (conflicts.length > 0) {
      openConflictDialog('download', win, dest.path, nonConflicts, conflicts, dest.existing);
    } else {
      enqueueDownloadItems(win, dest.path, nonConflicts.map((x) => ({ entry: x.item, finalName: x.finalName })));
    }
  }

  function openConflictDialog(direction, win, destPath, nonConflicts, conflicts, baselineNames) {
    appState.pendingConflictContext = { direction, win, destPath, nonConflicts, conflicts, baselineNames };
    dom.conflictSummary.textContent =
      direction === 'upload'
        ? `上传到 ${destPath} 时发现 ${conflicts.length} 个大小写不敏感同名文件：`
        : `下载到 ${destPath} 时发现 ${conflicts.length} 个 APFS 同名冲突文件：`;

    const frag = document.createDocumentFragment();
    for (const c of conflicts) {
      c.perItemResolution = 'keepBoth';
      const row = document.createElement('div');
      row.className = 'conflict-row';
      const top = document.createElement('div');
      top.className = 'conflict-row-top';
      const orig = document.createElement('span');
      orig.textContent = sanitizeControlDisplay(c.item.name).text;

      const rightWrap = document.createElement('div');
      rightWrap.style.display = 'flex';
      rightWrap.style.alignItems = 'center';
      rightWrap.style.gap = '8px';

      const badge = document.createElement('span');
      badge.className = 'entry-tag restricted';
      badge.textContent = '同名冲突';

      const perSelect = document.createElement('select');
      perSelect.className = 'mac-select';
      perSelect.style.padding = '2px 6px';
      perSelect.style.fontSize = '11px';
      perSelect.hidden = true;
      const optKeep = document.createElement('option');
      optKeep.value = 'keepBoth';
      optKeep.textContent = '保留两份';
      const optSkip = document.createElement('option');
      optSkip.value = 'skip';
      optSkip.textContent = '跳过';
      perSelect.appendChild(optKeep);
      perSelect.appendChild(optSkip);
      perSelect.addEventListener('change', () => {
        c.perItemResolution = perSelect.value;
      });
      c._selectEl = perSelect;

      rightWrap.appendChild(badge);
      rightWrap.appendChild(perSelect);
      top.appendChild(orig);
      top.appendChild(rightWrap);

      const sub = document.createElement('div');
      sub.className = 'conflict-row-sub';
      const candidateLen = c.preview ? textEncoder.encode(c.preview).length : 999;
      sub.textContent = c.preview
        ? `选择「保留两份」将重命名为: ${sanitizeControlDisplay(c.preview).text} (${candidateLen} UTF-8 B)`
        : '无法生成合规候选名';

      row.appendChild(top);
      row.appendChild(sub);
      frag.appendChild(row);
    }

    dom.conflictList.replaceChildren(frag);
    dom.conflictApplyAll.checked = true;
    dom.conflictSkipBtn.hidden = false;
    dom.conflictSkipBtn.textContent = '跳过冲突文件';
    dom.conflictKeepBtn.textContent = '保留两份';
    dom.conflictDialog.showModal();
  }

  function resolveConflictDialog(resolution) {
    const ctx = appState.pendingConflictContext;
    appState.pendingConflictContext = null;
    dom.conflictDialog.close(resolution);
    if (!ctx || resolution === 'cancel') return;

    const applyAll = dom.conflictApplyAll.checked;
    const normalizer = ctx.direction === 'upload' ? normalizeAndroidCase : normalizeMacAPFS;
    const occupied = new Set(ctx.baselineNames.map(normalizer));
    const finalItems = [];

    for (const okItem of ctx.nonConflicts) {
      occupied.add(normalizer(okItem.finalName));
      finalItems.push(okItem);
    }

    let skippedCount = 0;
    for (const c of ctx.conflicts) {
      const effectiveResolution = applyAll ? resolution : c.perItemResolution;
      if (effectiveResolution === 'skip') {
        skippedCount++;
        continue;
      }
      const candidate = computeRenameCandidate(c.item.name, occupied, normalizer);
      if (!candidate || textEncoder.encode(candidate).length > 255) {
        showToast(`重命名 ${c.item.name} 超过 255 UTF-8 字节，已跳过`, 'warning');
        continue;
      }
      occupied.add(normalizer(candidate));
      finalItems.push({ item: c.item, finalName: candidate });
    }

    if (skippedCount > 0) {
      showToast(`已跳过 ${skippedCount} 个同名冲突文件`, 'info');
    }

    if (ctx.direction === 'upload') {
      enqueueUploadItems(
        ctx.win,
        ctx.destPath,
        finalItems.map((x) => ({ ...x.item, finalName: x.finalName }))
      );
    } else {
      enqueueDownloadItems(
        ctx.win,
        ctx.destPath,
        finalItems.map((x) => ({ entry: x.item, finalName: x.finalName }))
      );
    }
  }

  function enqueueUploadItems(win, physicalDir, items) {
    if (items.length === 0) return;
    for (const item of items) {
      appState.tasks.unshift({
        id: uuidLike(),
        kind: 'upload',
        deviceKey: win.key,
        deviceModel: win.device.model,
        deviceSerial: win.device.serial,
        deviceCaps: win.device.capabilities,
        isWifi: win.device.connectionType === 'Wi-Fi',
        transportId: win.sessionId.transportId,
        sessionGen: win.sessionId.serverGeneration,
        dirComponents: [...win.pathComponents],
        parentPhysicalPath: physicalDir,
        tempDirName: '.metalcast-tmp-' + uuidLike().slice(0, 8),
        commitMode: win.device.capabilities.commitMode,
        finalName: item.finalName,
        totalBytes: item.size,
        isSizeReliable: true,
        bytesDone: 0,
        rateBytesPerSec: 0,
        state: 'queued',
        detail: '等待设备写队列与全局传输槽位'
      });
    }
    appState.drawerOpen = true;
    appState.drawerTab = 'tasks';
    pumpScheduler();
  }

  function enqueueDownloadItems(win, localDestPath, items) {
    if (items.length === 0) return;
    for (const { entry, finalName } of items) {
      appState.tasks.unshift({
        id: uuidLike(),
        kind: 'download',
        deviceKey: win.key,
        deviceModel: win.device.model,
        deviceSerial: win.device.serial,
        deviceCaps: win.device.capabilities,
        isWifi: win.device.connectionType === 'Wi-Fi',
        transportId: win.sessionId.transportId,
        sessionGen: win.sessionId.serverGeneration,
        dirComponents: [...win.pathComponents],
        localDestPath,
        finalName,
        totalBytes: entry.isSizeReliable ? entry.size : null,
        isSizeReliable: Boolean(entry.isSizeReliable),
        bytesDone: 0,
        rateBytesPerSec: 0,
        state: 'queued',
        detail: '等待设备写队列与全局传输槽位'
      });
    }
    appState.drawerOpen = true;
    appState.drawerTab = 'tasks';
    pumpScheduler();
  }

  function openDeleteConfirm() {
    const win = getActiveWindow();
    if (!win || win.selectedNames.size === 0) return;

    const physicalDir = win.device.physicalRoot + (win.pathComponents.length ? '/' + win.pathComponents.join('/') : '');
    const selected = [...win.selectedNames];

    dom.deleteDeviceLabel.textContent = `${win.device.model} (tid:${win.sessionId.transportId})`;
    dom.deletePathLabel.textContent = physicalDir;
    dom.deleteCountLabel.textContent = `${selected.length} 个普通文件`;

    const frag = document.createDocumentFragment();
    for (const name of selected) {
      const li = document.createElement('li');
      li.textContent = sanitizeControlDisplay(name).text;
      frag.appendChild(li);
    }
    dom.deleteFileList.replaceChildren(frag);
    dom.deleteConfirmDialog.showModal();
  }

  function executeBatchDelete() {
    const win = getActiveWindow();
    dom.deleteConfirmDialog.close('delete');
    if (!win) return;

    const tree = appState.fs[win.key];
    const key = pathKey(win.pathComponents);
    const dirList = tree[key] || [];
    const targets = [...win.selectedNames];

    const results = [];
    for (const name of targets) {
      const idx = dirList.findIndex((e) => e.name === name);
      if (idx === -1) {
        results.push({ name, status: '已不存在 (exit 30)', cls: 'warning' });
      } else {
        dirList.splice(idx, 1);
        results.push({ name, status: '已删除 (exit 0)', cls: 'completed' });
      }
    }

    win.selectedNames.clear();
    win.viewState = resolveViewStateForDevice(win.device, win.pathComponents);
    renderFileWindow();

    dom.deleteResultSummary.textContent = `本次共确认 ${targets.length} 项，按原确认清单顺序执行完毕：`;
    const frag = document.createDocumentFragment();
    for (const r of results) {
      const li = document.createElement('li');
      const n = document.createElement('span');
      n.textContent = sanitizeControlDisplay(r.name).text;
      const badge = document.createElement('span');
      badge.className = `task-state-pill ${r.cls}`;
      badge.textContent = r.status;
      li.appendChild(n);
      li.appendChild(badge);
      frag.appendChild(li);
    }
    dom.deleteResultList.replaceChildren(frag);
    dom.deleteResultDialog.showModal();
  }

  // =================================================
  // Guard Dialogs (windowShouldClose & Cmd+Q)
  // =================================================
  function openGuardDialog(mode) {
    appState.pendingGuardAction = mode;
    dom.guardProgressArea.hidden = true;
    dom.guardProgressBar.style.width = '0%';
    dom.guardConfirmBtn.disabled = false;
    dom.guardCancelBtn.disabled = false;

    const activeCount = appState.tasks.filter((t) =>
      ['queued', 'transferring', 'committing'].includes(t.state)
    ).length;

    if (mode === 'windowClose') {
      const win = getActiveWindow();
      dom.guardTitle.textContent = `确认关闭「手机文件 - ${win ? win.device.model : ''}」？`;
      dom.guardMessage.textContent =
        activeCount > 0
          ? `当前窗口有 ${activeCount} 项进行中的任务。关闭窗口将取消尚未提交的传输并尝试清理当前临时目录；已进入提交的指令将保留核对记录。`
          : '确认关闭当前手机文件窗口？（演示 windowShouldClose 生命周期拦截）';
      dom.guardConfirmBtn.textContent = '确认关闭窗口';
    } else {
      dom.guardTitle.textContent = '退出 MetalCast (applicationShouldTerminate)';
      dom.guardMessage.textContent =
        activeCount > 0
          ? `全应用存在 ${activeCount} 项活跃文件任务。确认退出后将通过 .terminateLater 限时（5 秒）取消未提交任务并将清理记录原子写入 file-transfer-ledger.json。`
          : '当前无活跃文件传输，可直接退出；你也可以点击「确认退出」预览 .terminateLater 清理落盘流程。';
      dom.guardConfirmBtn.textContent = '确认退出并落盘';
    }

    dom.guardDialog.showModal();
  }

  function handleGuardConfirm() {
    const mode = appState.pendingGuardAction;
    if (!mode) return;

    dom.guardProgressArea.hidden = false;
    dom.guardConfirmBtn.disabled = true;
    dom.guardCancelBtn.disabled = true;
    dom.guardProgressText.textContent =
      mode === 'appQuit'
        ? '.terminateLater 已挂起退出：正在取消未提交传输并原子写入 file-transfer-ledger.json...'
        : '正在执行 cancelWindowTasks 并清理暂存临时目录...';

    let pct = 15;
    const timer = setInterval(() => {
      pct += 25;
      dom.guardProgressBar.style.width = `${Math.min(100, pct)}%`;
      if (pct >= 100) {
        clearInterval(timer);
        for (const t of appState.tasks) {
          if (t.state === 'queued' || t.state === 'transferring') {
            if (t._timer) clearInterval(t._timer);
            t.state = 'cancelled';
            t.detail = mode === 'appQuit' ? '应用退出已取消并记录清理' : '窗口关闭已取消';
          }
        }
        dom.guardDialog.close('confirmed');
        if (mode === 'windowClose') {
          const win = getActiveWindow();
          if (win && appState.openWindows.size > 1) {
            appState.openWindows.delete(win.key);
            appState.activeWindowKey = appState.openWindows.keys().next().value || null;
          } else if (win) {
            appState.openWindows.delete(win.key);
            appState.activeWindowKey = null;
          }
          renderControlCenter();
          renderFileWindow();
          showToast('已安全关闭文件窗口并清理未提交任务', 'info');
        } else {
          renderDrawer();
          updateSlotIndicators();
          showToast('已完成 5s 限时清理与账本原子落盘，reply(toApplicationShouldTerminate: true)', 'success');
        }
      }
    }, 240);
  }

  // =================================================
  // Tweaks & Scenario Presets
  // =================================================
  function applyScenario(scenarioId) {
    appState.activeScenario = scenarioId;
    for (const btn of dom.scenarioChips.querySelectorAll('.chip-btn')) {
      btn.classList.toggle('active', btn.dataset.scenario === scenarioId);
    }

    // Reset baseline endpoint & Xiaomi device before applying scenario
    appState.endpoint = { host: '127.0.0.1', port: 5037, incompatibleDetail: null };
    const xiaomi = appState.devices.find((d) => d.serial === '8e45f92a');
    if (xiaomi) {
      xiaomi.state = 'device';
      xiaomi.capabilities.commitMode = 'mvNoClobberNoTarget';
    }

    if (scenarioId === 'normal') {
      appState.selectedDeviceKey = 'tid:3';
      const win = createWindowSession(xiaomi, ['Download']);
      appState.openWindows.set('tid:3', win);
      appState.activeWindowKey = 'tid:3';
    } else if (scenarioId === 'android-restricted') {
      appState.selectedDeviceKey = 'tid:3';
      const win = createWindowSession(xiaomi, ['Android']);
      appState.openWindows.set('tid:3', win);
      appState.activeWindowKey = 'tid:3';
    } else if (scenarioId === 'empty-dir') {
      appState.selectedDeviceKey = 'tid:3';
      const win = createWindowSession(xiaomi, ['EmptyFolder']);
      appState.openWindows.set('tid:3', win);
      appState.activeWindowKey = 'tid:3';
    } else if (scenarioId === 'permission-denied') {
      appState.selectedDeviceKey = 'tid:3';
      const win = createWindowSession(xiaomi, ['RestrictedCache']);
      appState.openWindows.set('tid:3', win);
      appState.activeWindowKey = 'tid:3';
    } else if (scenarioId === 'commit-disconnect') {
      appState.selectedDeviceKey = 'tid:3';
      xiaomi.state = 'offline';
      const win = createWindowSession(xiaomi, ['Download']);
      win.viewState = 'disconnected';
      appState.openWindows.set('tid:3', win);
      appState.activeWindowKey = 'tid:3';

      const alreadyPending = appState.tasks.some((t) => t.tempDirName === '.metalcast-tmp-commit99');
      if (!alreadyPending) {
        const pendingId = uuidLike();
        const pendingLedgerId = uuidLike().toUpperCase();
        appState.tasks.unshift({
          id: pendingId,
          ledgerId: pendingLedgerId,
          kind: 'upload',
          deviceKey: 'tid:3',
          deviceModel: xiaomi.model,
          deviceSerial: xiaomi.serial,
          transportId: xiaomi.transportId,
          sessionGen: appState.serverGeneration,
          dirComponents: ['Download'],
          parentPhysicalPath: '/storage/emulated/0/Download',
          tempDirName: '.metalcast-tmp-commit99',
          finalName: 'build-artifact-v4.2.apk',
          totalBytes: 24_800_000,
          isSizeReliable: true,
          bytesDone: 24_800_000,
          rateBytesPerSec: 0,
          state: 'pendingConfirmation',
          detail: '已发出 mv -nT 提交命令但连接断开，重连后仅只读核对状态'
        });
        appState.ledger.unshift({
          id: pendingLedgerId,
          taskId: pendingId,
          endpoint: { ...appState.endpoint },
          serial: xiaomi.serial,
          transportId: xiaomi.transportId,
          serverGeneration: appState.serverGeneration,
          targetParentPhysicalPath: '/storage/emulated/0/Download',
          tempDirName: '.metalcast-tmp-commit99',
          tempPayloadName: 'payload',
          finalTargetName: 'build-artifact-v4.2.apk',
          state: 'pendingConfirmation',
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString()
        });
      }
      appState.drawerOpen = true;
      appState.drawerTab = 'tasks';
    } else if (scenarioId === 'legacy-toybox') {
      const pixel = appState.devices.find((d) => d.selectionKey === 'tid:11');
      appState.selectedDeviceKey = 'tid:11';
      const win = createWindowSession(pixel, ['Download']);
      appState.openWindows.set('tid:11', win);
      appState.activeWindowKey = 'tid:11';
    } else if (scenarioId === 'missing-mv-n') {
      appState.selectedDeviceKey = 'tid:3';
      xiaomi.capabilities.commitMode = 'unsupported';
      const win = createWindowSession(xiaomi, ['Download']);
      appState.openWindows.set('tid:3', win);
      appState.activeWindowKey = 'tid:3';
    } else if (scenarioId === 'missing-shell-v2') {
      const legacy = appState.devices.find((d) => d.selectionKey === 'tid:15');
      appState.selectedDeviceKey = 'tid:15';
      const win = createWindowSession(legacy, []);
      appState.openWindows.set('tid:15', win);
      appState.activeWindowKey = 'tid:15';
    } else if (scenarioId === 'incompatible-endpoint') {
      appState.endpoint = {
        host: '127.0.0.1',
        port: 5037,
        incompatibleDetail: 'ADB_SERVER_SOCKET=localfilesystem:/tmp/adb.sock（首版仅支持本地 TCP 端点）'
      };
      const win = createWindowSession(xiaomi, ['Download']);
      appState.openWindows.set('tid:3', win);
      appState.activeWindowKey = 'tid:3';
    }

    renderAll();
  }

  function renderAll() {
    renderControlCenter();
    renderFileWindow();
  }

  // =================================================
  // Dialog Helpers (Modern Web Guidance close + fallback)
  // =================================================
  function wireDialogBehavior(dialog) {
    dialog.addEventListener('close', () => {
      dialog.returnValue = '';
      if (dialog === dom.conflictDialog) {
        appState.pendingConflictContext = null;
      } else if (dialog === dom.guardDialog) {
        appState.pendingGuardAction = null;
      }
    });

    if (!('closedBy' in HTMLDialogElement.prototype) && dialog.getAttribute('closedby') === 'any') {
      const outside = (e) => {
        const r = dialog.getBoundingClientRect();
        return e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom;
      };
      let pressedOutside = false;
      dialog.addEventListener('pointerdown', (e) => {
        pressedOutside = outside(e);
      });
      dialog.addEventListener('pointerup', (e) => {
        if (pressedOutside && outside(e)) {
          dialog.close('');
        }
      });
    }
  }

  // =================================================
  // Initialization & Event Wiring
  // =================================================
  function initIcons() {
    dom.menubarApple.appendChild(window.McIcons.create('apple', 14));
    dom.tweaksToggleIcon.appendChild(window.McIcons.create('sliders', 13));
    dom.ccBtnRefresh.appendChild(window.McIcons.create('refresh', 13));
    dom.ccBtnFilesIcon.appendChild(window.McIcons.create('folder', 14));
    dom.ccBtnMirrorIcon.appendChild(window.McIcons.create('play', 12));
    dom.fmBtnBack.appendChild(window.McIcons.create('back', 14));
    dom.fmBtnRefresh.appendChild(window.McIcons.create('refresh', 14));
    dom.fmIconUpload.appendChild(window.McIcons.create('upload', 14));
    dom.fmIconDownload.appendChild(window.McIcons.create('download', 14));
    dom.fmIconDelete.appendChild(window.McIcons.create('trash', 14));
    dom.fmIconDrawer.appendChild(window.McIcons.create('drawer', 14));

    for (const closeBtn of [
      dom.uploadPickerClose,
      dom.downloadPickerClose,
      dom.deleteResultClose,
      dom.ledgerJsonClose
    ]) {
      closeBtn.appendChild(window.McIcons.create('close', 14));
    }
  }

  function initEvents() {
    // Tweaks toggle
    dom.btnToggleTweaks.addEventListener('click', () => {
      appState.tweaksOpen = !appState.tweaksOpen;
      dom.tweaksPanel.hidden = !appState.tweaksOpen;
      dom.btnToggleTweaks.setAttribute('aria-expanded', String(appState.tweaksOpen));
    });

    // Theme switcher
    for (const btn of document.querySelectorAll('[data-theme-choice]')) {
      btn.addEventListener('click', () => {
        const theme = btn.dataset.themeChoice;
        appState.theme = theme;
        dom.root.setAttribute('data-theme', theme);
        for (const other of document.querySelectorAll('[data-theme-choice]')) {
          other.classList.toggle('active', other === btn);
        }
      });
    }

    // Scenario presets
    for (const btn of dom.scenarioChips.querySelectorAll('[data-scenario]')) {
      btn.addEventListener('click', () => applyScenario(btn.dataset.scenario));
    }

    dom.simBtnCloseGuard.addEventListener('click', () => openGuardDialog('windowClose'));
    dom.simBtnQuitGuard.addEventListener('click', () => openGuardDialog('appQuit'));
    dom.menubarBtnQuit.addEventListener('click', () => openGuardDialog('appQuit'));

    // Menubar quick focus
    dom.menubarBtnCc.addEventListener('click', () => {
      document.getElementById('control-window').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    });
    dom.menubarBtnFm.addEventListener('click', () => {
      dom.fileWindow.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    });

    // Control Center actions
    dom.ccBtnRefresh.addEventListener('click', () => {
      showToast('已通过 host:devices-l 刷新设备列表，已打开的文件窗口保持不变', 'info');
      renderControlCenter();
    });

    dom.ccBtnFiles.addEventListener('click', () => {
      const selected = appState.devices.find((d) => d.selectionKey === appState.selectedDeviceKey);
      openOrFocusFileWindow(selected);
    });

    dom.ccBtnMirror.addEventListener('click', () => {
      const selected = appState.devices.find((d) => d.selectionKey === appState.selectedDeviceKey);
      if (!selected || selected.state !== 'device') return;
      if (appState.mirroringDevices.has(selected.selectionKey)) {
        appState.mirroringDevices.delete(selected.selectionKey);
        showToast(`已停止 ${selected.model} 投屏，独立文件窗口可继续使用`, 'info');
      } else {
        appState.mirroringDevices.add(selected.selectionKey);
        showToast(`已开启 ${selected.model} 原生投屏（与文件 Socket 并发运行）`, 'success');
      }
      renderControlCenter();
    });

    // File Window Toolbar
    dom.fmBtnCloseWindow.addEventListener('click', () => openGuardDialog('windowClose'));
    dom.fmBtnBack.addEventListener('click', () => {
      const win = getActiveWindow();
      if (win && win.pathComponents.length > 0) {
        navigateWindow(win, win.pathComponents.slice(0, -1));
      }
    });
    dom.fmBtnRefresh.addEventListener('click', () => {
      const win = getActiveWindow();
      if (!win) return;
      win.viewState = resolveViewStateForDevice(win.device, win.pathComponents);
      renderFileWindow();
      showToast('已刷新当前目录', 'info');
    });
    dom.fmBtnUpload.addEventListener('click', openUploadPicker);
    dom.fmBtnDownload.addEventListener('click', openDownloadPicker);
    dom.fmBtnDelete.addEventListener('click', openDeleteConfirm);
    dom.fmBtnDrawer.addEventListener('click', () => {
      appState.drawerOpen = !appState.drawerOpen;
      renderDrawer();
    });

    dom.tabBtnTasks.addEventListener('click', () => {
      appState.drawerTab = 'tasks';
      renderDrawer();
    });
    dom.tabBtnLedger.addEventListener('click', () => {
      appState.drawerTab = 'ledger';
      renderDrawer();
    });

    dom.fmSelectAll.addEventListener('change', () => {
      const win = getActiveWindow();
      if (!win) return;
      const entries = getEntriesForWindow(win).filter(
        (e) => e.kind === 'regular' && !e.isRestricted && e.isLosslessUTF8 !== false
      );
      if (dom.fmSelectAll.checked) {
        for (const e of entries) win.selectedNames.add(e.name);
      } else {
        win.selectedNames.clear();
      }
      renderFileTable(win);
      updateToolbarSelectionButtons(win);
    });

    // Keyboard Cmd+A & Cmd+Q simulation
    document.addEventListener('keydown', (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'a') {
        if (document.querySelector('dialog[open]')) return;
        const win = getActiveWindow();
        if (win && win.viewState === 'normal') {
          e.preventDefault();
          const entries = getEntriesForWindow(win).filter(
            (item) => item.kind === 'regular' && !item.isRestricted && item.isLosslessUTF8 !== false
          );
          for (const item of entries) win.selectedNames.add(item.name);
          renderFileTable(win);
          updateToolbarSelectionButtons(win);
        }
      }
    });

    // Dialog Controls
    for (const d of [
      dom.uploadPickerDialog,
      dom.downloadPickerDialog,
      dom.conflictDialog,
      dom.deleteConfirmDialog,
      dom.deleteResultDialog,
      dom.guardDialog,
      dom.ledgerJsonDialog
    ]) {
      wireDialogBehavior(d);
    }

    dom.uploadPickerClose.addEventListener('click', () => dom.uploadPickerDialog.close('cancel'));
    dom.uploadPickerCancel.addEventListener('click', () => dom.uploadPickerDialog.close('cancel'));
    dom.uploadPickerConfirm.addEventListener('click', handleUploadConfirm);

    dom.downloadDestSelect.addEventListener('change', renderDownloadDestExisting);
    dom.downloadPickerClose.addEventListener('click', () => dom.downloadPickerDialog.close('cancel'));
    dom.downloadPickerCancel.addEventListener('click', () => dom.downloadPickerDialog.close('cancel'));
    dom.downloadPickerConfirm.addEventListener('click', handleDownloadConfirm);

    dom.conflictApplyAll.addEventListener('change', () => {
      const ctx = appState.pendingConflictContext;
      if (!ctx) return;
      const applyAll = dom.conflictApplyAll.checked;
      for (const c of ctx.conflicts) {
        if (c._selectEl) c._selectEl.hidden = applyAll;
      }
      dom.conflictSkipBtn.hidden = !applyAll;
      dom.conflictKeepBtn.textContent = applyAll ? '保留两份' : '按逐项选择执行';
    });
    dom.conflictCancelBtn.addEventListener('click', () => resolveConflictDialog('cancel'));
    dom.conflictSkipBtn.addEventListener('click', () => resolveConflictDialog('skip'));
    dom.conflictKeepBtn.addEventListener('click', () => resolveConflictDialog('keepBoth'));

    dom.deleteConfirmCancel.addEventListener('click', () => dom.deleteConfirmDialog.close('cancel'));
    dom.deleteConfirmSubmit.addEventListener('click', executeBatchDelete);

    dom.deleteResultClose.addEventListener('click', () => dom.deleteResultDialog.close('ok'));
    dom.deleteResultOk.addEventListener('click', () => dom.deleteResultDialog.close('ok'));

    dom.guardCancelBtn.addEventListener('click', () => dom.guardDialog.close('cancel'));
    dom.guardConfirmBtn.addEventListener('click', handleGuardConfirm);

    dom.fmBtnViewLedgerJson.addEventListener('click', () => {
      const payload = { schemaVersion: 1, entries: appState.ledger };
      dom.ledgerJsonPre.textContent = JSON.stringify(payload, null, 2);
      dom.ledgerJsonDialog.showModal();
    });
    dom.ledgerJsonClose.addEventListener('click', () => dom.ledgerJsonDialog.close('ok'));
    dom.ledgerJsonOk.addEventListener('click', () => dom.ledgerJsonDialog.close('ok'));
  }

  function bootstrap() {
    initIcons();
    initEvents();
    const xiaomi = appState.devices.find((d) => d.selectionKey === 'tid:3');
    appState.openWindows.set('tid:3', createWindowSession(xiaomi, ['Download']));
    appState.activeWindowKey = 'tid:3';
    renderAll();
  }

  bootstrap();
})();
