/* Monochrome vector icon registry inspired by SF Symbols. */
(function () {
  function svg(paths, size) {
    var px = size || 16;
    return (
      '<svg viewBox="0 0 16 16" width="' +
      px +
      '" height="' +
      px +
      '" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      paths +
      "</svg>"
    );
  }

  window.MCIcons = {
    phone: svg('<rect x="4" y="1.5" width="8" height="13" rx="1.6"></rect><path d="M7 12.2h2"></path>'),
    wifi: svg('<path d="M2 6a8.8 8.8 0 0 1 12 0"></path><path d="M4.4 8.6a5.4 5.4 0 0 1 7.2 0"></path><path d="M6.8 11.2a2 2 0 0 1 2.4 0"></path><circle cx="8" cy="13.2" r="0.6" fill="currentColor" stroke="none"></circle>'),
    play: svg('<path d="M4.5 3.2 12.5 8l-8 4.8V3.2Z" fill="currentColor" stroke="none"></path>'),
    stop: svg('<rect x="3.8" y="3.8" width="8.4" height="8.4" rx="1.4" fill="currentColor" stroke="none"></rect>'),
    folder: svg('<path d="M2 4.2A1.2 1.2 0 0 1 3.2 3h3l1.3 1.4h5.3A1.2 1.2 0 0 1 14 5.6v6.7a1.2 1.2 0 0 1-1.2 1.2H3.2A1.2 1.2 0 0 1 2 12.3V4.2Z"></path>'),
    bolt: svg('<path d="M8.8 1.6 3.5 9h4l-.8 5.4 5.8-7.4h-4l.3-5.4Z"></path>'),
    refresh: svg('<path d="M13.2 7.2A5.2 5.2 0 1 0 12 11.6"></path><path d="M10.8 7.2h2.8V4.4"></path>'),
    plus: svg('<path d="M8 3.2v9.6"></path><path d="M3.2 8h9.6"></path>'),
    upload: svg('<path d="M8 10.5V2.8"></path><path d="m4.8 5.8 3.2-3.2 3.2 3.2"></path><path d="M2.8 11v2a1 1 0 0 0 1 1h8.4a1 1 0 0 0 1-1v-2"></path>'),
    download: svg('<path d="M8 2.8v7.7"></path><path d="m4.8 7.6 3.2 3.2 3.2-3.2"></path><path d="M2.8 11v2a1 1 0 0 0 1 1h8.4a1 1 0 0 0 1-1v-2"></path>'),
    trash: svg('<path d="M2.8 4.5h10.4"></path><path d="M6 4.5V3a.8.8 0 0 1 .8-.8h2.4a.8.8 0 0 1 .8.8v1.5"></path><path d="M4.2 4.5 4.8 13a1 1 0 0 0 1 .9h4.4a1 1 0 0 0 1-.9l.6-8.5"></path>'),
    tray: svg('<path d="M2.5 9.5 3.6 3.8A1 1 0 0 1 4.6 3h6.8a1 1 0 0 1 1 .8l1.1 5.7v2.8a1 1 0 0 1-1 1h-9a1 1 0 0 1-1-1V9.5Z"></path><path d="M2.5 9.5h3.2l1 1.6h2.6l1-1.6h3.2"></path>'),
    back: svg('<path d="M10.2 3.4 5.6 8l4.6 4.6"></path>'),
    home: svg('<circle cx="8" cy="8" r="4.6"></circle>'),
    recents: svg('<rect x="3.5" y="3.5" width="9" height="9" rx="1.8"></rect>'),
    gamepad: svg('<path d="M3.2 6.2A2.4 2.4 0 0 1 5.6 4h4.8a2.4 2.4 0 0 1 2.4 2.2l.6 4.1a1.7 1.7 0 0 1-2.8 1.5L9.2 10.5H6.8l-1.4 1.3a1.7 1.7 0 0 1-2.8-1.5l.6-4.1Z"></path><path d="M5.4 7.3h2.2"></path><path d="M6.5 6.2v2.2"></path><circle cx="10.8" cy="7.3" r="0.6" fill="currentColor" stroke="none"></circle>'),
    moon: svg('<path d="M12.5 9.8A5.2 5.2 0 0 1 6.2 3.5a5.4 5.4 0 1 0 6.3 6.3Z"></path>'),
    sun: svg('<circle cx="8" cy="8" r="3"></circle><path d="M8 1.8v1.4M8 12.8v1.4M1.8 8h1.4M12.8 8h1.4M3.6 3.6l1 1M11.4 11.4l1 1M12.4 3.6l-1 1M4.6 11.4l-1 1"></path>'),
    monitor: svg('<rect x="2" y="2.6" width="12" height="8.4" rx="1.4"></rect><path d="M5.5 13.4h5M8 11v2.4"></path>'),
    camera: svg('<path d="M2.2 5.2A1.2 1.2 0 0 1 3.4 4h2l.9-1.4h3.4L10.6 4h2a1.2 1.2 0 0 1 1.2 1.2v6.6a1.2 1.2 0 0 1-1.2 1.2H3.4a1.2 1.2 0 0 1-1.2-1.2V5.2Z"></path><circle cx="8" cy="8.4" r="2.2"></circle>'),
    volUp: svg('<path d="M2.5 6.4h2.6l3.2-2.8v8.8L5.1 9.6H2.5V6.4Z"></path><path d="M11.2 5.4a3.6 3.6 0 0 1 0 5.2"></path><path d="M13 3.6a6 6 0 0 1 0 8.8"></path>'),
    volDown: svg('<path d="M2.8 6.4h2.6l3.2-2.8v8.8L5.4 9.6H2.8V6.4Z"></path><path d="M11.4 6.2a2.6 2.6 0 0 1 0 3.6"></path>'),
    mute: svg('<path d="M2.5 6.4h2.5l3-2.6v8.4l-3-2.6H2.5V6.4Z"></path><path d="m10.8 6 3 4M13.8 6l-3 4"></path>'),
    power: svg('<path d="M8 2.2v4.6"></path><path d="M4.6 4.2a5 5 0 1 0 6.8 0"></path>'),
    fullscreen: svg('<path d="M2.5 5.8V2.5h3.3M10.2 2.5h3.3v3.3M13.5 10.2v3.3h-3.3M5.8 13.5H2.5v-3.3"></path>'),
    dockPos: svg('<rect x="2" y="2.8" width="12" height="10.4" rx="1.6"></rect><path d="M10.2 2.8v10.4"></path>'),
    chevronRight: svg('<path d="m6 3.5 4.2 4.5L6 12.5"></path>'),
    sortAsc: svg('<path d="m4.5 9.8 3.5-3.6 3.5 3.6"></path>'),
    lock: svg('<rect x="3.5" y="7" width="9" height="6.5" rx="1.4"></rect><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2"></path>'),
    link: svg('<path d="M6.4 9.6 9.6 6.4"></path><path d="M5.2 6.8 3.8 8.2a2.3 2.3 0 0 0 3.2 3.2l1.4-1.4M10.8 9.2l1.4-1.4A2.3 2.3 0 0 0 9 4.6L7.6 6"></path>'),
    doc: svg('<path d="M4 2h5.2l2.8 2.8V13a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V3a1 1 0 0 1 1-1Z"></path><path d="M9 2v3h3"></path>'),
    photo: svg('<rect x="2.4" y="3" width="11.2" height="10" rx="1.4"></rect><circle cx="5.7" cy="6.2" r="1"></circle><path d="m3.4 11.4 2.8-2.8 2.2 2.2 1.8-1.6 2.4 2.2"></path>'),
    video: svg('<rect x="2" y="3.8" width="8.5" height="8.4" rx="1.4"></rect><path d="m10.5 6.8 3.5-2v6.4l-3.5-2V6.8Z"></path>'),
    apk: svg('<path d="M8 2.2 13 5v6l-5 2.8L3 11V5l5-2.8Z"></path><path d="M3 5l5 2.8L13 5M8 7.8v6"></path>'),
    warn: svg('<path d="M8 2.4 14 13H2L8 2.4Z"></path><path d="M8 6.4v3"></path><circle cx="8" cy="11.2" r="0.6" fill="currentColor" stroke="none"></circle>')
  };
})();
