/* MetalCast UI Redesign Interactive Prototype Controller */
(function () {
  var STYLE_KEY = "metalcast-redesign-style";
  var THEME_KEY = "color-scheme";

  var state = {
    style: "native-pro",
    themePref: "system",
    selectedDeviceId: "tid:4",
    isMirroring: false,
    stream: {
      res: "原生原画",
      fps: "自适应",
      rate: "16 Mbps",
      codec: "H.264",
      audio: true,
      screenOff: false
    },
    keymapId: "gameforpeace.json",
    fmPath: "/Download",
    fmSelectedNames: new Set(),
    fmSort: { col: "name", dir: "ascending" },
    fmDrawerOpen: true,
    mirrorDockPos: "right",
    mirrorDockHidden: false,
    mirrorGameActive: false,
    mirrorScreenOff: false,
    mirrorMuted: false,
    pendingPairTarget: ""
  };

  var collator = new Intl.Collator("zh-CN", { numeric: true, sensitivity: "base" });

  function injectStaticIcons() {
    var slots = document.querySelectorAll("[data-icon]");
    for (var i = 0; i < slots.length; i += 1) {
      var name = slots[i].getAttribute("data-icon");
      if (window.MCIcons[name]) {
        slots[i].innerHTML = window.MCIcons[name];
      }
    }
  }

  /* =========================================================
   * Dark Mode Toggle (System / Light / Dark) per modern-web-guidance
   * ========================================================= */
  var darkQuery = window.matchMedia("(prefers-color-scheme: dark)");

  function readStoredTheme() {
    try {
      var raw = localStorage.getItem(THEME_KEY);
      return raw === "light" || raw === "dark" ? raw : "system";
    } catch (e) {
      return "system";
    }
  }

  function applyTheme(pref, persist) {
    state.themePref = pref;
    var meta = document.querySelector('meta[name="color-scheme"]');
    if (meta) {
      meta.content = pref === "system" ? "light dark" : pref;
    }
    if (persist) {
      try {
        if (pref === "system") {
          localStorage.removeItem(THEME_KEY);
        } else {
          localStorage.setItem(THEME_KEY, pref);
        }
      } catch (e) {}
    }

    var btns = document.querySelectorAll("[data-theme-btn]");
    for (var i = 0; i < btns.length; i += 1) {
      var isActive = btns[i].getAttribute("data-theme-btn") === pref;
      btns[i].setAttribute("aria-pressed", String(isActive));
    }

    var sysBtn = document.getElementById("theme-system-btn");
    if (sysBtn) {
      sysBtn.textContent = "跟随系统（当前" + (darkQuery.matches ? "深色" : "浅色") + "）";
    }

    renderDesignTokens();
  }

  function setupThemeControls() {
    applyTheme(readStoredTheme(), false);

    var btns = document.querySelectorAll("[data-theme-btn]");
    for (var i = 0; i < btns.length; i += 1) {
      btns[i].addEventListener("click", function () {
        applyTheme(this.getAttribute("data-theme-btn"), true);
      });
    }

    // Do NOT remove stored overrides when OS scheme matches; only refresh the System label.
    if (darkQuery.addEventListener) {
      darkQuery.addEventListener("change", function () {
        applyTheme(state.themePref, false);
      });
    }

    window.addEventListener("storage", function (e) {
      if (e.key === THEME_KEY) {
        applyTheme(readStoredTheme(), false);
      }
    });
  }

  /* =========================================================
   * 3-Style Switcher
   * ========================================================= */
  function applyStyle(styleId, persist) {
    if (!window.MCData.styles[styleId]) styleId = "native-pro";
    state.style = styleId;
    document.documentElement.dataset.style = styleId;
    if (persist) {
      try {
        localStorage.setItem(STYLE_KEY, styleId);
      } catch (e) {}
    }

    var btns = document.querySelectorAll("[data-style-btn]");
    for (var i = 0; i < btns.length; i += 1) {
      var match = btns[i].getAttribute("data-style-btn") === styleId;
      btns[i].setAttribute("aria-pressed", String(match));
    }

    var info = window.MCData.styles[styleId];
    document.getElementById("brief-name").textContent = info.name;
    document.getElementById("brief-desc").textContent = info.desc;
    renderDesignTokens();
  }

  function setupStyleSwitcher() {
    var saved = "native-pro";
    try {
      saved = localStorage.getItem(STYLE_KEY) || "native-pro";
    } catch (e) {}
    applyStyle(saved, false);

    var btns = document.querySelectorAll("[data-style-btn]");
    for (var i = 0; i < btns.length; i += 1) {
      btns[i].addEventListener("click", function () {
        applyStyle(this.getAttribute("data-style-btn"), true);
      });
    }
  }

  /* =========================================================
   * Accessible Tabs with hidden="until-found" + beforematch
   * ========================================================= */
  function initTablist(tablistId, onSelect) {
    var tablist = document.getElementById(tablistId);
    if (!tablist) return null;
    var tabs = Array.prototype.slice.call(tablist.querySelectorAll('button[id]'));

    function getPanelForTab(tab) {
      return document.querySelector('[role="tabpanel"][aria-labelledby="' + tab.id + '"]');
    }

    function activate(targetTab, moveFocus) {
      tabs.forEach(function (tab) {
        var selected = tab === targetTab;
        tab.setAttribute("aria-selected", String(selected));
        if (selected) {
          tab.setAttribute("focusgroupstart", "");
        } else {
          tab.removeAttribute("focusgroupstart");
        }
        var panel = getPanelForTab(tab);
        if (panel) {
          if (selected) {
            panel.removeAttribute("hidden");
            panel.setAttribute("tabindex", "0");
          } else {
            panel.setAttribute("hidden", "until-found");
            panel.removeAttribute("tabindex");
          }
        }
      });

      if (targetTab.scrollIntoView) {
        targetTab.scrollIntoView({ block: "nearest", inline: "nearest" });
      }
      if (moveFocus) {
        targetTab.focus();
      }
      if (onSelect) onSelect(targetTab.id);
    }

    tabs.forEach(function (tab, index) {
      tab.addEventListener("click", function () {
        activate(tab, false);
      });

      // Keyboard fallback when native `focusgroup` is unavailable
      tab.addEventListener("keydown", function (e) {
        if (Object.hasOwn(HTMLElement.prototype, "focusGroup")) return;
        var nextIndex = null;
        if (e.key === "ArrowRight") nextIndex = (index + 1) % tabs.length;
        else if (e.key === "ArrowLeft") nextIndex = (index - 1 + tabs.length) % tabs.length;
        else if (e.key === "Home") nextIndex = 0;
        else if (e.key === "End") nextIndex = tabs.length - 1;
        if (nextIndex !== null) {
          e.preventDefault();
          activate(tabs[nextIndex], true);
        }
      });

      var panel = getPanelForTab(tab);
      if (panel) {
        panel.addEventListener("beforematch", function () {
          activate(tab, false);
        });
      }
    });

    return { activateById: function (id) {
      var match = tabs.find(function (t) { return t.id === id; });
      if (match) activate(match, false);
    }};
  }

  /* =========================================================
   * Native <dialog> Modals + closedby="any" Light-Dismiss Fallback
   * ========================================================= */
  function setupDialogHelpers() {
    if (!("closedBy" in HTMLDialogElement.prototype)) {
      var outside = function (e, dialog) {
        var r = dialog.getBoundingClientRect();
        return e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom;
      };
      var dialogs = document.querySelectorAll('dialog[closedby="any"]');
      for (var i = 0; i < dialogs.length; i += 1) {
        (function (dlg) {
          var pressedOutside = false;
          dlg.addEventListener("pointerdown", function (e) {
            pressedOutside = outside(e, dlg);
          });
          dlg.addEventListener("pointerup", function (e) {
            if (pressedOutside && outside(e, dlg)) {
              dlg.close("");
            }
          });
        })(dialogs[i]);
      }
    }

    var allDialogs = document.querySelectorAll("dialog");
    for (var j = 0; j < allDialogs.length; j += 1) {
      allDialogs[j].addEventListener("close", function () {
        var val = this.returnValue;
        handleDialogClose(this.id, val);
        this.returnValue = "";
      });
    }
  }

  function handleDialogClose(dialogId, value) {
    if (dialogId === "dlg-conflict" && (value === "keepBoth" || value === "skip")) {
      var msg =
        value === "keepBoth"
          ? "已将 2 个冲突文件按「保留两份」规范重命名（例: metalcast-beta-4.2 (2).apk）并入队传输。"
          : "已按策略跳过 2 个同名冲突文件，无本地或远端覆盖发生。";
      showFileBanner(msg);
      window.MCData.tasks.unshift({
        id: "t-" + Date.now(),
        kind: "上传",
        name: value === "keepBoth" ? "metalcast-beta-4.2 (2).apk" : "其余非冲突文件",
        state: value === "keepBoth" ? "completed" : "skipped",
        stateLabel: value === "keepBoth" ? "已完成" : "已跳过",
        progress: value === "keepBoth" ? 100 : 0,
        subtitle: value === "keepBoth" ? "100% · 已原子 mv -nT 提交并清理暂存目录" : "目标已存在，按策略跳过"
      });
      renderDrawer();
    } else if (dialogId === "dlg-delete" && value === "confirm") {
      var names = Array.from(state.fmSelectedNames);
      var currentList = window.MCData.filesByPath[state.fmPath] || [];
      window.MCData.filesByPath[state.fmPath] = currentList.filter(function (item) {
        return names.indexOf(item.name) === -1;
      });
      state.fmSelectedNames.clear();
      renderFileTable();
      showFileBanner("已完成逐项非递归 rm -- 删除：共移除 " + names.length + " 个普通文件。");
    }
  }

  /* =========================================================
   * Control Center Logic
   * ========================================================= */
  function getSelectedDevice() {
    return window.MCData.devices.find(function (d) { return d.id === state.selectedDeviceId; }) || window.MCData.devices[0];
  }

  function setCCFooter(text) {
    document.getElementById("cc-footer-status").textContent = text;
  }

  function renderControlCenterDevices() {
    var listEl = document.getElementById("cc-device-list");
    listEl.innerHTML = "";

    window.MCData.devices.forEach(function (dev) {
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "device-item";
      btn.setAttribute("aria-current", dev.id === state.selectedDeviceId ? "true" : "false");

      var iconWrap = document.createElement("span");
      iconWrap.className = "device-icon-wrap";
      var iconSpan = document.createElement("span");
      iconSpan.className = "icon icon-sm";
      iconSpan.innerHTML = dev.isWifi ? window.MCIcons.wifi : window.MCIcons.phone;
      iconWrap.appendChild(iconSpan);

      var meta = document.createElement("span");
      meta.className = "device-meta";
      var name = document.createElement("span");
      name.className = "device-name";
      name.textContent = dev.model;
      var serial = document.createElement("span");
      serial.className = "device-serial mono";
      serial.textContent = dev.serial;
      meta.appendChild(name);
      meta.appendChild(serial);

      var badge = document.createElement("span");
      badge.className = "transport-pill" + (dev.state !== "device" ? " warn" : "");
      badge.textContent = dev.state !== "device" ? "未授权" : dev.isWifi ? "Wi-Fi" : "USB";

      btn.appendChild(iconWrap);
      btn.appendChild(meta);
      btn.appendChild(badge);

      btn.addEventListener("click", function () {
        state.selectedDeviceId = dev.id;
        renderControlCenterDevices();
        updateHeroDevice();
      });

      listEl.appendChild(btn);
    });
  }

  function updateMdnsBadge() {
    var count = window.MCData.mdnsDevices.length;
    var pill = document.getElementById("cc-mdns-pill");
    var dot = document.getElementById("cc-mdns-dot");
    var label = document.getElementById("cc-mdns-count");
    if (!pill || !label) return;
    if (count > 0) {
      pill.classList.remove("empty");
      if (dot) dot.hidden = false;
      label.textContent = count + " 附近";
    } else {
      pill.classList.add("empty");
      if (dot) dot.hidden = true;
      label.textContent = "无广播";
    }
  }

  function addOrFocusWifiDevice(serial, labelName) {
    var existing = window.MCData.devices.find(function (d) { return d.serial === serial; });
    if (existing) {
      state.selectedDeviceId = existing.id;
    } else {
      var newDev = {
        id: "tid:wifi-" + Date.now(),
        serial: serial,
        model: labelName || "Wireless (" + serial.split(":")[0] + ")",
        state: "device",
        isWifi: true,
        transportId: String(10 + window.MCData.devices.length),
        resolution: "1200 × 2670",
        android: "Android 15 (TCP/IP)",
        capabilities: "shell_v2 · stat_v2 · ls_v2 · mv -nT"
      };
      window.MCData.devices.unshift(newDev);
      state.selectedDeviceId = newDev.id;
    }
    renderControlCenterDevices();
    updateHeroDevice();
    setCCFooter("已接入无线设备 " + serial);
  }

  function renderMdnsList() {
    updateMdnsBadge();
    var el = document.getElementById("dlg-mdns-list");
    if (!el) return;
    el.innerHTML = "";

    window.MCData.mdnsDevices.forEach(function (m) {
      var card = document.createElement("div");
      card.className = "mdns-card";

      var info = document.createElement("div");
      info.className = "mdns-info";

      var row = document.createElement("div");
      row.className = "mdns-title-row";
      var dot = document.createElement("span");
      dot.className = "mdns-dot" + (m.isPairing ? " pairing" : "");
      var name = document.createElement("span");
      name.className = "mdns-name";
      name.textContent = m.name;
      row.appendChild(dot);
      row.appendChild(name);

      var addr = document.createElement("span");
      addr.className = "mdns-addr mono";
      addr.textContent = m.address;

      info.appendChild(row);
      info.appendChild(addr);

      var actionBtn = document.createElement("button");
      actionBtn.type = "button";
      actionBtn.className = m.isPairing ? "btn btn-sm" : "btn btn-primary btn-sm";
      actionBtn.textContent = m.isPairing ? "配对" : "连接";
      actionBtn.addEventListener("click", function () {
        if (m.isPairing) {
          state.pendingPairTarget = m.address;
          document.getElementById("dlg-pair-inline-target").textContent = "正在配对：" + m.name + " (" + m.address + ")";
          var codeInput = document.getElementById("pair-code-input");
          codeInput.value = "";
          document.getElementById("dlg-pair-inline").hidden = false;
          codeInput.focus();
        } else {
          addOrFocusWifiDevice(m.address, m.name);
          document.getElementById("dlg-wireless").close("close");
        }
      });

      card.appendChild(info);
      card.appendChild(actionBtn);
      el.appendChild(card);
    });
  }

  function updateHeroDevice() {
    var dev = getSelectedDevice();
    document.getElementById("hero-model").textContent = dev.model;
    document.getElementById("hero-serial").textContent = dev.serial;
    document.getElementById("hero-resolution").textContent = dev.resolution;
    document.getElementById("hero-os").textContent = dev.android;
    document.getElementById("cc-footer-caps").textContent = dev.capabilities;

    var badges = document.getElementById("hero-badges");
    badges.innerHTML = "";
    var stateTag = document.createElement("span");
    stateTag.className = "meta-tag " + (dev.state === "device" ? "ok" : "warn");
    stateTag.textContent = dev.state === "device" ? "已授权在线" : "未授权";
    var modeTag = document.createElement("span");
    modeTag.className = "meta-tag";
    modeTag.textContent = dev.isWifi ? "Wi-Fi 无线" : "USB 有线";
    badges.appendChild(stateTag);
    badges.appendChild(modeTag);

    var warnEl = document.getElementById("hero-warning");
    var isReady = dev.state === "device" && dev.transportId;
    if (!isReady) {
      warnEl.hidden = false;
      warnEl.textContent = "当前设备未完成 USB 调试授权或缺少 transport_id，已保护性禁用投屏与文件操作。";
    } else {
      warnEl.hidden = true;
      warnEl.textContent = "";
    }

    document.getElementById("hero-files-btn").disabled = !isReady;
    document.getElementById("hero-mirror-btn").disabled = !isReady;
    var wifiSwitchBtn = document.getElementById("hero-wifi-switch-btn");
    wifiSwitchBtn.style.display = dev.isWifi ? "none" : "inline-flex";
    wifiSwitchBtn.disabled = !isReady;
  }

  function updateSignalSummary() {
    document.getElementById("sig-res").textContent = state.stream.res;
    document.getElementById("sig-fps").textContent = state.stream.fps;
    document.getElementById("sig-rate").textContent = state.stream.rate;
    document.getElementById("sig-codec").textContent = state.stream.codec;
    document.getElementById("sig-audio").textContent = state.stream.audio ? "Mac 转发" : "关闭";
    var km = window.MCData.keymapPresets.find(function (k) { return k.id === state.keymapId; });
    document.getElementById("sig-keymap").textContent = km ? km.title.split(" ")[0] : "关闭";
  }

  function renderKeymapGrid() {
    var grid = document.getElementById("cc-keymap-grid");
    grid.innerHTML = "";
    window.MCData.keymapPresets.forEach(function (preset) {
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "keymap-tile";
      btn.setAttribute("aria-pressed", String(preset.id === state.keymapId));

      var title = document.createElement("span");
      title.className = "keymap-tile-title";
      title.textContent = preset.title;

      var desc = document.createElement("span");
      desc.className = "keymap-tile-sub";
      desc.textContent = preset.desc;

      btn.appendChild(title);
      btn.appendChild(desc);

      btn.addEventListener("click", function () {
        state.keymapId = preset.id;
        renderKeymapGrid();
        updateSignalSummary();
        setCCFooter("已切换键鼠映射预设：" + preset.title);
      });

      grid.appendChild(btn);
    });
  }

  function setupControlCenter(studioTabs) {
    renderControlCenterDevices();
    renderMdnsList();
    updateHeroDevice();
    renderKeymapGrid();
    updateSignalSummary();

    var segGroups = document.querySelectorAll("[data-setting]");
    for (var i = 0; i < segGroups.length; i += 1) {
      (function (group) {
        var key = group.getAttribute("data-setting");
        var btns = group.querySelectorAll("button");
        for (var j = 0; j < btns.length; j += 1) {
          btns[j].addEventListener("click", function () {
            for (var k = 0; k < btns.length; k += 1) {
              btns[k].setAttribute("aria-pressed", String(btns[k] === this));
            }
            state.stream[key] = this.getAttribute("data-val");
            updateSignalSummary();
          });
        }
      })(segGroups[i]);
    }

    document.getElementById("toggle-audio").addEventListener("change", function () {
      state.stream.audio = this.checked;
      updateSignalSummary();
    });
    document.getElementById("toggle-screenoff").addEventListener("change", function () {
      state.stream.screenOff = this.checked;
    });

    document.getElementById("hero-mirror-btn").addEventListener("click", function () {
      state.isMirroring = !state.isMirroring;
      var chip = document.getElementById("cc-run-chip");
      var chipLabel = document.getElementById("cc-run-label");
      var btn = this;
      var btnLabel = document.getElementById("hero-mirror-label");
      var btnIcon = document.getElementById("hero-mirror-icon");

      if (state.isMirroring) {
        chip.classList.add("live");
        chipLabel.textContent = "投屏中";
        btn.classList.remove("btn-primary");
        btn.classList.add("btn-danger");
        btnLabel.textContent = "停止投屏";
        btnIcon.innerHTML = window.MCIcons.stop;
        setCCFooter("投屏运行中 (" + state.stream.codec + " · 音频" + (state.stream.audio ? "开启" : "关闭") + ")");
      } else {
        chip.classList.remove("live");
        chipLabel.textContent = "待机";
        btn.classList.remove("btn-danger");
        btn.classList.add("btn-primary");
        btnLabel.textContent = "开启原生投屏";
        btnIcon.innerHTML = window.MCIcons.play;
        setCCFooter("已断开投屏会话 · ADB 跟踪运行中");
      }
    });

    document.getElementById("hero-files-btn").addEventListener("click", function () {
      studioTabs.activateById("view-tab-files");
    });

    document.getElementById("hero-wifi-switch-btn").addEventListener("click", function () {
      var dev = getSelectedDevice();
      setCCFooter("已为 " + dev.model + " 切换无线免插线模式 (192.168.1.62:5555)");
    });

    function openWirelessDialog() {
      studioTabs.activateById("view-tab-dashboard");
      document.getElementById("dlg-pair-inline").hidden = true;
      renderMdnsList();
      var dlg = document.getElementById("dlg-wireless");
      if (!dlg.open) {
        dlg.showModal();
      }
    }

    document.getElementById("cc-open-wireless-btn").addEventListener("click", openWirelessDialog);
    document.getElementById("cc-add-wireless-btn").addEventListener("click", openWirelessDialog);
    document.getElementById("btn-preview-wireless").addEventListener("click", openWirelessDialog);

    window.addEventListener("hashchange", function () {
      if (window.location.hash === "#wireless") {
        openWirelessDialog();
      }
    });
    if (window.location.hash === "#wireless") {
      openWirelessDialog();
    }

    document.getElementById("dlg-mdns-rescan-btn").addEventListener("click", function () {
      renderMdnsList();
      setCCFooter("已刷新局域网无线调试广播：发现 " + window.MCData.mdnsDevices.length + " 台设备");
    });

    document.getElementById("dlg-pair-inline-cancel").addEventListener("click", function () {
      document.getElementById("dlg-pair-inline").hidden = true;
    });

    document.getElementById("dlg-pair-submit-btn").addEventListener("click", function () {
      var code = document.getElementById("pair-code-input").value.trim();
      if (!code) return;
      var pairMdns = window.MCData.mdnsDevices.find(function (m) { return m.address === state.pendingPairTarget; });
      if (pairMdns) {
        pairMdns.isPairing = false;
      }
      document.getElementById("dlg-pair-inline").hidden = true;
      renderMdnsList();
      setCCFooter("已完成配对 " + state.pendingPairTarget + "（配对码 " + code + "），可直接点击连接。");
    });

    document.getElementById("dlg-wifi-connect-btn").addEventListener("click", function () {
      var ip = document.getElementById("wifi-ip").value.trim();
      var port = document.getElementById("wifi-port").value.trim() || "5555";
      if (!ip) return;
      addOrFocusWifiDevice(ip + ":" + port);
      document.getElementById("dlg-wireless").close("close");
    });

    document.getElementById("cc-refresh-btn").addEventListener("click", function () {
      setCCFooter("扫描完成: 发现 " + window.MCData.devices.length + " 台已连接设备");
    });

    document.getElementById("cc-open-keymap-dir").addEventListener("click", function () {
      setCCFooter("已在 Finder 打开 ~/Library/Application Support/MetalCast/keymap");
    });
  }

  /* =========================================================
   * File Manager + Semantic Sortable Table (moveBefore + aria-sort)
   * ========================================================= */
  function showFileBanner(msg) {
    var banner = document.getElementById("fm-banner");
    document.getElementById("fm-banner-text").textContent = msg;
    banner.hidden = false;
  }

  function renderBreadcrumb() {
    var nav = document.getElementById("fm-breadcrumb");
    nav.innerHTML = "";
    var parts = state.fmPath === "/" ? [] : state.fmPath.slice(1).split("/");

    var rootBtn = document.createElement("button");
    rootBtn.type = "button";
    rootBtn.className = "crumb-btn" + (parts.length === 0 ? " current" : "");
    rootBtn.textContent = "共享存储";
    rootBtn.addEventListener("click", function () {
      state.fmPath = "/";
      state.fmSelectedNames.clear();
      renderFileTable();
    });
    nav.appendChild(rootBtn);

    parts.forEach(function (part, idx) {
      var sep = document.createElement("span");
      sep.className = "crumb-sep";
      sep.textContent = "›";
      nav.appendChild(sep);

      var pathTarget = "/" + parts.slice(0, idx + 1).join("/");
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "crumb-btn" + (idx === parts.length - 1 ? " current" : "");
      btn.textContent = part;
      btn.addEventListener("click", function () {
        state.fmPath = pathTarget;
        state.fmSelectedNames.clear();
        renderFileTable();
      });
      nav.appendChild(btn);
    });

    document.getElementById("fm-back-btn").disabled = parts.length === 0;
  }

  function compareFileRows(rowA, rowB, col, dir) {
    var aDir = rowA.dataset.isdir === "1" ? 0 : 1;
    var bDir = rowB.dataset.isdir === "1" ? 0 : 1;
    if (aDir !== bDir) return aDir - bDir;

    var factor = dir === "ascending" ? 1 : -1;
    var val = function (row, index) {
      var cell = row.cells[index];
      return cell.dataset.value !== undefined ? cell.dataset.value : cell.textContent.trim();
    };

    var th = document.querySelector('#fm-table thead th[data-col="' + col + '"]');
    var idx = th ? th.cellIndex : 0;
    var type = th ? th.dataset.type : "text";
    if (type === "number") {
      var numA = Number(val(rowA, idx));
      var numB = Number(val(rowB, idx));
      if (numA !== numB) return factor * (numA - numB);
      return factor * collator.compare(val(rowA, 0), val(rowB, 0));
    }
    return factor * collator.compare(val(rowA, idx), val(rowB, idx));
  }

  function applyTableSort(announceButton) {
    var table = document.getElementById("fm-table");
    var tbody = document.getElementById("fm-tbody");
    var rows = Array.prototype.slice.call(tbody.rows);
    rows.sort(function (a, b) {
      return compareFileRows(a, b, state.fmSort.col, state.fmSort.dir);
    });

    // Move existing <tr> nodes without recreating tbody HTML (sortable-table guidance)
    for (var i = 0; i < rows.length; i += 1) {
      if (typeof tbody.moveBefore === "function") {
        tbody.moveBefore(rows[i], null);
      } else {
        tbody.appendChild(rows[i]);
      }
    }

    var headers = table.tHead.rows[0].cells;
    for (var j = 0; j < headers.length; j += 1) {
      if (headers[j].dataset.col === state.fmSort.col) {
        headers[j].setAttribute("aria-sort", state.fmSort.dir);
      } else {
        headers[j].removeAttribute("aria-sort");
      }
    }

    if (announceButton) {
      var label = announceButton.textContent.trim();
      document.getElementById("fm-sort-status").textContent =
        "已按「" + label + "」" + (state.fmSort.dir === "ascending" ? "升序" : "降序") + "排列，共 " + rows.length + " 项";
    }
  }

  function renderFileTable() {
    renderBreadcrumb();
    var tbody = document.getElementById("fm-tbody");
    tbody.innerHTML = "";

    var entries = window.MCData.filesByPath[state.fmPath] || [];
    entries.forEach(function (entry) {
      var tr = document.createElement("tr");
      tr.dataset.isdir = entry.kind === "folder" ? "1" : "0";
      tr.dataset.restricted = entry.restricted ? "true" : "false";
      tr.setAttribute("aria-selected", String(state.fmSelectedNames.has(entry.name)));

      var tdName = document.createElement("td");
      tdName.dataset.value = entry.name;
      var nameBox = document.createElement("div");
      nameBox.className = "fm-name-cell";
      var iconSpan = document.createElement("span");
      iconSpan.className = "icon icon-sm";
      iconSpan.style.color = entry.restricted ? "var(--text-soft)" : entry.kind === "folder" ? "var(--accent)" : "var(--text-muted)";
      iconSpan.innerHTML = window.MCIcons[entry.icon] || window.MCIcons.doc;
      var titleSpan = document.createElement("span");
      titleSpan.className = "fm-entry-name";
      titleSpan.textContent = entry.name;
      nameBox.appendChild(iconSpan);
      nameBox.appendChild(titleSpan);
      if (entry.tag) {
        var tagSpan = document.createElement("span");
        tagSpan.className = "entry-tag" + (entry.restricted ? " warn" : "");
        tagSpan.textContent = entry.tag;
        nameBox.appendChild(tagSpan);
      }
      tdName.appendChild(nameBox);

      var tdKind = document.createElement("td");
      tdKind.textContent = entry.kindLabel;
      tdKind.style.color = "var(--text-muted)";

      var tdSize = document.createElement("td");
      tdSize.className = "num-cell";
      tdSize.dataset.value = entry.size === null ? "-1" : String(entry.size);
      tdSize.textContent = entry.sizeText;

      var tdMtime = document.createElement("td");
      tdMtime.className = "num-cell";
      tdMtime.dataset.value = String(entry.mtime);
      tdMtime.textContent = entry.mtimeText;

      tr.appendChild(tdName);
      tr.appendChild(tdKind);
      tr.appendChild(tdSize);
      tr.appendChild(tdMtime);

      tr.addEventListener("click", function (e) {
        if (e.metaKey || e.ctrlKey) {
          if (state.fmSelectedNames.has(entry.name)) state.fmSelectedNames.delete(entry.name);
          else state.fmSelectedNames.add(entry.name);
        } else {
          state.fmSelectedNames.clear();
          state.fmSelectedNames.add(entry.name);
        }
        updateTableSelectionUI();
      });

      tr.addEventListener("dblclick", function () {
        if (entry.restricted) {
          showFileBanner("已拦截：首版不支持访问 Android/" + entry.name + "（restrictedPath 权限边界）。");
          return;
        }
        if (entry.kind === "folder") {
          state.fmPath = state.fmPath === "/" ? "/" + entry.name : state.fmPath + "/" + entry.name;
          state.fmSelectedNames.clear();
          renderFileTable();
        }
      });

      tbody.appendChild(tr);
    });

    applyTableSort(null);
    updateTableSelectionUI();
  }

  function updateTableSelectionUI() {
    var entries = window.MCData.filesByPath[state.fmPath] || [];
    var rows = document.getElementById("fm-tbody").rows;
    var operableCount = 0;

    for (var i = 0; i < rows.length; i += 1) {
      var name = rows[i].cells[0].dataset.value;
      var selected = state.fmSelectedNames.has(name);
      rows[i].setAttribute("aria-selected", String(selected));
      if (selected) {
        var meta = entries.find(function (item) { return item.name === name; });
        if (meta && meta.operable) operableCount += 1;
      }
    }

    document.getElementById("fm-download-btn").disabled = operableCount === 0;
    document.getElementById("fm-delete-btn").disabled = operableCount === 0;
    document.getElementById("fm-footer-stats").textContent =
      "USB · 物理根: /storage/emulated/0 · 当前目录 " + entries.length + " 项 · 已选可操作文件 " + operableCount + " 项";
  }

  function renderDrawer() {
    var tasksEl = document.getElementById("fm-tasks-body");
    var ledgerEl = document.getElementById("fm-ledger-body");
    tasksEl.innerHTML = "";
    ledgerEl.innerHTML = "";

    document.getElementById("drawer-tasks-count").textContent = String(window.MCData.tasks.length);
    document.getElementById("drawer-ledger-count").textContent = String(window.MCData.ledger.length);
    document.getElementById("fm-attention-badge").textContent = String(
      window.MCData.tasks.filter(function (t) { return t.state !== "completed" && t.state !== "skipped"; }).length +
        window.MCData.ledger.length
    );

    window.MCData.tasks.forEach(function (t) {
      var row = document.createElement("div");
      row.className = "task-row";

      var main = document.createElement("div");
      main.className = "task-main";

      var titleRow = document.createElement("div");
      titleRow.className = "task-title-row";
      var kind = document.createElement("span");
      kind.className = "task-kind";
      kind.textContent = t.kind;
      var name = document.createElement("span");
      name.className = "task-name";
      name.textContent = t.name;
      var st = document.createElement("span");
      st.className = "task-state" + (t.state === "completed" ? " ok" : t.state === "pendingConfirmation" ? " warn" : "");
      st.textContent = t.stateLabel;
      titleRow.appendChild(kind);
      titleRow.appendChild(name);
      titleRow.appendChild(st);

      var track = document.createElement("div");
      track.className = "progress-track";
      var fill = document.createElement("div");
      fill.className = "progress-fill";
      fill.style.width = t.progress + "%";
      track.appendChild(fill);

      var sub = document.createElement("div");
      sub.className = "task-sub num";
      sub.textContent = t.subtitle;

      main.appendChild(titleRow);
      main.appendChild(track);
      main.appendChild(sub);

      var actions = document.createElement("div");
      actions.className = "task-actions";
      if (t.state === "transferring") {
        var cancelBtn = document.createElement("button");
        cancelBtn.type = "button";
        cancelBtn.className = "btn btn-sm";
        cancelBtn.textContent = "取消";
        cancelBtn.addEventListener("click", function () {
          t.state = "skipped";
          t.stateLabel = "已取消";
          t.progress = 0;
          t.subtitle = "已取消上传并清理远端暂存目录";
          renderDrawer();
        });
        actions.appendChild(cancelBtn);
      } else if (t.state === "pendingConfirmation") {
        var verifyBtn = document.createElement("button");
        verifyBtn.type = "button";
        verifyBtn.className = "btn btn-primary btn-sm";
        verifyBtn.textContent = "核对结果";
        verifyBtn.addEventListener("click", function () {
          t.state = "completed";
          t.stateLabel = "已完成";
          t.progress = 100;
          t.subtitle = "核对确认：文件已成功提交并清理暂存目录";
          window.MCData.ledger = window.MCData.ledger.filter(function (l) { return l.state !== "pendingConfirmation"; });
          renderDrawer();
        });
        actions.appendChild(verifyBtn);
      }

      row.appendChild(main);
      row.appendChild(actions);
      tasksEl.appendChild(row);
    });

    window.MCData.ledger.forEach(function (l) {
      var row = document.createElement("div");
      row.className = "task-row";

      var main = document.createElement("div");
      main.className = "task-main";
      var name = document.createElement("div");
      name.className = "task-name mono";
      name.textContent = l.path;
      var sub = document.createElement("div");
      sub.className = "task-sub";
      sub.textContent = l.meta + " · 状态 " + l.state;
      main.appendChild(name);
      main.appendChild(sub);

      var actions = document.createElement("div");
      actions.className = "task-actions";
      var primaryBtn = document.createElement("button");
      primaryBtn.type = "button";
      primaryBtn.className = l.state === "pendingConfirmation" ? "btn btn-primary btn-sm" : "btn btn-sm";
      primaryBtn.textContent = l.state === "pendingConfirmation" ? "核对结果" : "重试清理";
      primaryBtn.addEventListener("click", function () {
        window.MCData.ledger = window.MCData.ledger.filter(function (item) { return item.id !== l.id; });
        showFileBanner(l.state === "pendingConfirmation" ? "核对确认：文件已提交并收敛。" : "暂存目录已完成远端 rmdir 清理。");
        renderDrawer();
      });

      var dismissBtn = document.createElement("button");
      dismissBtn.type = "button";
      dismissBtn.className = "btn btn-ghost btn-sm";
      dismissBtn.textContent = "忽略并移除";
      dismissBtn.addEventListener("click", function () {
        window.MCData.ledger = window.MCData.ledger.filter(function (item) { return item.id !== l.id; });
        renderDrawer();
      });

      actions.appendChild(primaryBtn);
      actions.appendChild(dismissBtn);
      row.appendChild(main);
      row.appendChild(actions);
      ledgerEl.appendChild(row);
    });
  }

  function setupFileManager() {
    renderFileTable();
    renderDrawer();

    var table = document.getElementById("fm-table");
    var sortByButton = function (button) {
      var th = button.closest("th");
      var col = th.dataset.col;
      if (state.fmSort.col === col) {
        state.fmSort.dir = state.fmSort.dir === "ascending" ? "descending" : "ascending";
      } else {
        state.fmSort.col = col;
        state.fmSort.dir = "ascending";
      }
      applyTableSort(button);
      button.focus();
    };

    table.addEventListener("command", function (e) {
      if (e.command === "--sort" && e.source) {
        sortByButton(e.source);
      }
    });

    if (!("commandForElement" in HTMLButtonElement.prototype)) {
      var sortBtns = table.tHead.querySelectorAll('button[command="--sort"]');
      for (var i = 0; i < sortBtns.length; i += 1) {
        sortBtns[i].addEventListener("click", function () {
          sortByButton(this);
        });
      }
    }

    document.getElementById("fm-back-btn").addEventListener("click", function () {
      if (state.fmPath === "/") return;
      var idx = state.fmPath.lastIndexOf("/");
      state.fmPath = idx <= 0 ? "/" : state.fmPath.slice(0, idx);
      state.fmSelectedNames.clear();
      renderFileTable();
    });

    document.getElementById("fm-refresh-btn").addEventListener("click", function () {
      renderFileTable();
      showFileBanner("已刷新目录 " + state.fmPath + "（通过 sync: LIS2）。");
    });

    document.getElementById("fm-banner-close").addEventListener("click", function () {
      document.getElementById("fm-banner").hidden = true;
    });

    document.getElementById("fm-drawer-toggle-btn").addEventListener("click", function () {
      state.fmDrawerOpen = !state.fmDrawerOpen;
      document.getElementById("fm-drawer").hidden = !state.fmDrawerOpen;
      this.setAttribute("aria-expanded", String(state.fmDrawerOpen));
    });

    document.getElementById("fm-clear-finished").addEventListener("click", function () {
      window.MCData.tasks = window.MCData.tasks.filter(function (t) {
        return t.state !== "completed" && t.state !== "skipped";
      });
      renderDrawer();
    });

    document.getElementById("fm-upload-btn").addEventListener("click", function () {
      var listEl = document.getElementById("dlg-conflict-rows");
      listEl.innerHTML = "";
      window.MCData.conflicts.forEach(function (c) {
        var row = document.createElement("div");
        row.className = "conflict-row";
        var copy = document.createElement("div");
        copy.style.display = "flex";
        copy.style.flexDirection = "column";
        copy.style.gap = "2px";
        var name = document.createElement("strong");
        name.textContent = c.name;
        var rename = document.createElement("span");
        rename.style.fontSize = "11px";
        rename.style.color = "var(--text-muted)";
        rename.textContent = "若保留两份将自动命名为 " + c.rename;
        copy.appendChild(name);
        copy.appendChild(rename);
        var tag = document.createElement("span");
        tag.className = "meta-tag";
        tag.textContent = "同名冲突";
        row.appendChild(copy);
        row.appendChild(tag);
        listEl.appendChild(row);
      });
      document.getElementById("dlg-conflict-dest").textContent = "目标路径: /storage/emulated/0" + state.fmPath;
      document.getElementById("dlg-conflict").showModal();
    });

    document.getElementById("fm-download-btn").addEventListener("click", function () {
      showFileBanner("已按 macOS APFS 规则查重并加入全局 2 槽下载队列（" + state.fmSelectedNames.size + " 项）。");
    });

    document.getElementById("fm-delete-btn").addEventListener("click", function () {
      var names = Array.from(state.fmSelectedNames);
      document.getElementById("dlg-delete-list").textContent = names.join(" · ");
      document.getElementById("dlg-delete").showModal();
    });
  }

  /* =========================================================
   * Mirror Window + DockToolbarView Prototype
   * ========================================================= */
  function setupMirrorWindow() {
    var frame = document.getElementById("mirror-window-frame");
    var logEl = document.getElementById("mirror-action-log");
    var rightBtn = document.getElementById("mirror-dock-right-btn");
    var bottomBtn = document.getElementById("mirror-dock-bottom-btn");
    var hideBtn = document.getElementById("dock-hide-btn");
    var restoreBtn = document.getElementById("mirror-restore-btn");

    function setDockPos(pos) {
      state.mirrorDockPos = pos;
      frame.setAttribute("data-dock", pos);
      rightBtn.setAttribute("aria-pressed", String(pos === "right"));
      bottomBtn.setAttribute("aria-pressed", String(pos === "bottom"));
      logEl.textContent = "停靠位置已切换至" + (pos === "right" ? "窗口右侧" : "窗口底部");
    }

    rightBtn.addEventListener("click", function () { setDockPos("right"); });
    bottomBtn.addEventListener("click", function () { setDockPos("bottom"); });
    document.getElementById("dock-pos-btn").addEventListener("click", function () {
      setDockPos(state.mirrorDockPos === "right" ? "bottom" : "right");
    });

    hideBtn.addEventListener("click", function () {
      state.mirrorDockHidden = true;
      frame.setAttribute("data-dock-hidden", "true");
      restoreBtn.hidden = false;
      logEl.textContent = "工具栏已收起（实际应用按 Cmd+T 唤出）";
    });

    restoreBtn.addEventListener("click", function () {
      state.mirrorDockHidden = false;
      frame.setAttribute("data-dock-hidden", "false");
      restoreBtn.hidden = true;
      logEl.textContent = "工具栏已恢复停靠显示";
    });

    document.getElementById("dock-game-btn").addEventListener("click", function () {
      state.mirrorGameActive = !state.mirrorGameActive;
      this.setAttribute("aria-pressed", String(state.mirrorGameActive));
      document.getElementById("mirror-hud-pill").hidden = !state.mirrorGameActive;
      logEl.textContent = state.mirrorGameActive ? "游戏键鼠映射已开启 (~ 锁定视角)" : "游戏键鼠映射已退出";
    });

    document.getElementById("dock-screen-btn").addEventListener("click", function () {
      state.mirrorScreenOff = !state.mirrorScreenOff;
      this.setAttribute("aria-pressed", String(state.mirrorScreenOff));
      frame.setAttribute("data-screen-off", String(state.mirrorScreenOff));
      logEl.textContent = state.mirrorScreenOff ? "手机物理屏幕已熄灭（投屏画面保留）" : "手机物理屏幕已点亮";
    });

    document.getElementById("dock-mute-btn").addEventListener("click", function () {
      state.mirrorMuted = !state.mirrorMuted;
      this.setAttribute("aria-pressed", String(state.mirrorMuted));
      logEl.textContent = state.mirrorMuted ? "Mac 转发音频已静音" : "Mac 转发音频已恢复输出";
    });

    var genericBtns = document.querySelectorAll("[data-dock-action]");
    for (var i = 0; i < genericBtns.length; i += 1) {
      genericBtns[i].addEventListener("click", function () {
        logEl.textContent = this.getAttribute("data-dock-action");
      });
    }
  }

  /* =========================================================
   * Design Tokens & SwiftUI Spec Renderer
   * ========================================================= */
  function renderDesignTokens() {
    var grid = document.getElementById("tokens-swatch-grid");
    var specList = document.getElementById("swift-mapping-list");
    if (!grid || !specList) return;

    var cs = getComputedStyle(document.documentElement);
    var info = window.MCData.styles[state.style];
    document.getElementById("tokens-meta-line").textContent =
      "当前激活：" + info.name + " · " + info.radius + " · 主强调色 " + info.accentLabel;

    var swatches = [
      { name: "画布底色 --canvas", prop: "--canvas" },
      { name: "窗体背景 --window", prop: "--window" },
      { name: "侧栏背景 --sidebar", prop: "--sidebar" },
      { name: "卡片表面 --surface", prop: "--surface" },
      { name: "分割线 --border", prop: "--border" },
      { name: "主强调色 --accent", prop: "--accent" },
      { name: "状态成功 --success", prop: "--success" },
      { name: "告警警示 --warning", prop: "--warning" }
    ];

    grid.innerHTML = "";
    swatches.forEach(function (sw) {
      var val = cs.getPropertyValue(sw.prop).trim();
      var card = document.createElement("div");
      card.className = "swatch-card";
      var chip = document.createElement("div");
      chip.className = "swatch-chip";
      chip.style.background = "var(" + sw.prop + ")";
      var title = document.createElement("div");
      title.className = "swatch-name";
      title.textContent = sw.name;
      var code = document.createElement("div");
      code.className = "swatch-value mono";
      code.textContent = val || "computed";
      card.appendChild(chip);
      card.appendChild(title);
      card.appendChild(code);
      grid.appendChild(card);
    });

    specList.innerHTML = "";
    window.MCData.swiftMapping.forEach(function (item) {
      var row = document.createElement("div");
      row.className = "spec-item";
      var k = document.createElement("span");
      k.className = "spec-item-k mono";
      k.textContent = item.file;
      var v = document.createElement("span");
      v.className = "spec-item-v";
      v.textContent = item.change;
      row.appendChild(k);
      row.appendChild(v);
      specList.appendChild(row);
    });
  }

  /* =========================================================
   * Bootstrap
   * ========================================================= */
  injectStaticIcons();
  var studioTabs = initTablist("studio-view-tabs");
  initTablist("cc-workspace-tabs");
  initTablist("fm-drawer-tabs");
  setupStyleSwitcher();
  setupThemeControls();
  setupDialogHelpers();
  setupControlCenter(studioTabs);
  setupFileManager();
  setupMirrorWindow();

  document.getElementById("btn-jump-files").addEventListener("click", function () {
    studioTabs.activateById("view-tab-files");
  });
  document.getElementById("btn-jump-mirror").addEventListener("click", function () {
    studioTabs.activateById("view-tab-mirror");
  });
})();
