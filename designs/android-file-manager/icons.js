'use strict';

(function () {
  const SVG_NS = 'http://www.w3.org/2000/svg';

  function makeSvg(size, childrenSpecs) {
    const svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('width', String(size));
    svg.setAttribute('height', String(size));
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('fill', 'none');
    svg.setAttribute('stroke', 'currentColor');
    svg.setAttribute('stroke-width', '1.75');
    svg.setAttribute('stroke-linecap', 'round');
    svg.setAttribute('stroke-linejoin', 'round');
    svg.setAttribute('aria-hidden', 'true');

    for (const spec of childrenSpecs) {
      const el = document.createElementNS(SVG_NS, spec.tag);
      for (const [k, v] of Object.entries(spec.attrs)) {
        el.setAttribute(k, String(v));
      }
      svg.appendChild(el);
    }
    return svg;
  }

  const ICONS = {
    apple: [
      { tag: 'path', attrs: { d: 'M12 4.5c1.2-1.4 2.8-2 4-2-.1 1.4-.9 2.7-2 3.5-1 .8-2 .9-2 .9z', fill: 'currentColor', stroke: 'none' } },
      { tag: 'path', attrs: { d: 'M16.5 8.5c-1.4 0-2.5.8-3.4.8-.9 0-2-.8-3.3-.8-2.4 0-4.3 2-4.3 5 0 3.2 2.2 7 4.4 7 .9 0 1.6-.6 2.7-.6s1.7.6 2.7.6c2.2 0 4-3.4 4-6.3-1.9-.9-2.2-3.4-.3-4.6-.7-.7-1.6-1.1-2.5-1.1z', fill: 'currentColor', stroke: 'none' } }
    ],
    phoneUsb: [
      { tag: 'rect', attrs: { x: 6, y: 2, width: 12, height: 20, rx: 2.5 } },
      { tag: 'line', attrs: { x1: 11, y1: 18, x2: 13, y2: 18 } }
    ],
    phoneWifi: [
      { tag: 'path', attrs: { d: 'M5 12.55a11 11 0 0 1 14.08 0' } },
      { tag: 'path', attrs: { d: 'M8.53 16.11a6 6 0 0 1 6.95 0' } },
      { tag: 'circle', attrs: { cx: 12, cy: 19.5, r: 0.9, fill: 'currentColor' } }
    ],
    folder: [
      { tag: 'path', attrs: { d: 'M3 6a2 2 0 0 1 2-2h4.2a2 2 0 0 1 1.6.8l1 1.2H19a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z' } }
    ],
    folderLock: [
      { tag: 'path', attrs: { d: 'M3 6a2 2 0 0 1 2-2h4.2l1.8 2H19a2 2 0 0 1 2 2v3' } },
      { tag: 'path', attrs: { d: 'M3 10v7a2 2 0 0 0 2 2h6' } },
      { tag: 'rect', attrs: { x: 14, y: 14, width: 7, height: 6, rx: 1.5 } },
      { tag: 'path', attrs: { d: 'M15.8 14v-1.5a1.7 1.7 0 0 1 3.4 0V14' } }
    ],
    file: [
      { tag: 'path', attrs: { d: 'M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z' } },
      { tag: 'polyline', attrs: { points: '14 3 14 8 19 8' } }
    ],
    image: [
      { tag: 'rect', attrs: { x: 3, y: 4, width: 18, height: 16, rx: 2 } },
      { tag: 'circle', attrs: { cx: 8.5, cy: 9, r: 1.5 } },
      { tag: 'path', attrs: { d: 'm21 16-5-5-6 6-2-2-5 5' } }
    ],
    video: [
      { tag: 'rect', attrs: { x: 3, y: 5, width: 14, height: 14, rx: 2 } },
      { tag: 'polygon', attrs: { points: '17 10 22 7 22 17 17 14' } }
    ],
    apk: [
      { tag: 'path', attrs: { d: 'M12 3 4 7.5v9L12 21l8-4.5v-9z' } },
      { tag: 'polyline', attrs: { points: '4 7.5 12 12 20 7.5' } },
      { tag: 'line', attrs: { x1: 12, y1: 12, x2: 12, y2: 21 } }
    ],
    symlink: [
      { tag: 'path', attrs: { d: 'M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71' } },
      { tag: 'path', attrs: { d: 'M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71' } }
    ],
    back: [
      { tag: 'polyline', attrs: { points: '15 18 9 12 15 6' } }
    ],
    refresh: [
      { tag: 'polyline', attrs: { points: '23 4 23 10 17 10' } },
      { tag: 'path', attrs: { d: 'M20.49 15a9 9 0 1 1-2.12-9.36L23 10' } }
    ],
    upload: [
      { tag: 'path', attrs: { d: 'M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4' } },
      { tag: 'polyline', attrs: { points: '17 8 12 3 7 8' } },
      { tag: 'line', attrs: { x1: 12, y1: 3, x2: 12, y2: 15 } }
    ],
    download: [
      { tag: 'path', attrs: { d: 'M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4' } },
      { tag: 'polyline', attrs: { points: '7 10 12 15 17 10' } },
      { tag: 'line', attrs: { x1: 12, y1: 15, x2: 12, y2: 3 } }
    ],
    trash: [
      { tag: 'polyline', attrs: { points: '3 6 5 6 21 6' } },
      { tag: 'path', attrs: { d: 'M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2' } }
    ],
    drawer: [
      { tag: 'rect', attrs: { x: 3, y: 4, width: 18, height: 16, rx: 2 } },
      { tag: 'line', attrs: { x1: 3, y1: 14, x2: 21, y2: 14 } }
    ],
    play: [
      { tag: 'polygon', attrs: { points: '6 4 20 12 6 20 6 4', fill: 'currentColor' } }
    ],
    warning: [
      { tag: 'path', attrs: { d: 'M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z' } },
      { tag: 'line', attrs: { x1: 12, y1: 9, x2: 12, y2: 13 } },
      { tag: 'circle', attrs: { cx: 12, cy: 17, r: 0.8, fill: 'currentColor' } }
    ],
    check: [
      { tag: 'circle', attrs: { cx: 12, cy: 12, r: 9 } },
      { tag: 'polyline', attrs: { points: '9 12 11 14 15 10' } }
    ],
    disconnect: [
      { tag: 'line', attrs: { x1: 2, y1: 2, x2: 22, y2: 22 } },
      { tag: 'path', attrs: { d: 'M8.5 16.5a5 5 0 0 1 7 0' } },
      { tag: 'path', attrs: { d: 'M5 12.859a10 10 0 0 1 5.17-2.69' } },
      { tag: 'path', attrs: { d: 'M19 12.859a10 10 0 0 0-2.007-1.523' } }
    ],
    sliders: [
      { tag: 'line', attrs: { x1: 4, y1: 21, x2: 4, y2: 14 } },
      { tag: 'line', attrs: { x1: 4, y1: 10, x2: 4, y2: 3 } },
      { tag: 'line', attrs: { x1: 12, y1: 21, x2: 12, y2: 12 } },
      { tag: 'line', attrs: { x1: 12, y1: 8, x2: 12, y2: 3 } },
      { tag: 'line', attrs: { x1: 20, y1: 21, x2: 20, y2: 16 } },
      { tag: 'line', attrs: { x1: 20, y1: 12, x2: 20, y2: 3 } },
      { tag: 'line', attrs: { x1: 1, y1: 14, x2: 7, y2: 14 } },
      { tag: 'line', attrs: { x1: 9, y1: 8, x2: 15, y2: 8 } },
      { tag: 'line', attrs: { x1: 17, y1: 16, x2: 23, y2: 16 } }
    ],
    close: [
      { tag: 'line', attrs: { x1: 18, y1: 6, x2: 6, y2: 18 } },
      { tag: 'line', attrs: { x1: 6, y1: 6, x2: 18, y2: 18 } }
    ]
  };

  window.McIcons = {
    create(name, size = 15) {
      return makeSvg(size, ICONS[name] || ICONS.file);
    }
  };
})();
