/* NeoFreeBird — BUG Clicker 캐릭터 창(pet.html)을 X 안의 WKWebView 로 띄울 때 쓰는 다리.
   데스크톱판은 preload.js 가 window.bridge 를 만들고 Electron 본체와 IPC 로 이야기한다.
   여기서는 같은 이름의 window.bridge 를 만들어 webkit.messageHandlers.clicker 로 네이티브(NFBClicker.m)와 이야기한다.
   네이티브는 window.__clk.resolve(id, 값) 으로 답하고, window.__clk.emit(채널, 값) 으로 알린다.
   문서 시작 때 WKUserScript 로 넣는다. 네이티브가 앞에 window.__clkLang 을 정해 둔다. */
(function () {
  'use strict';
  if (window.bridge) return;

  var seq = 0;
  var waits = {};
  var subs = {};

  function handler() {
    try {
      return window.webkit.messageHandlers.clicker;
    } catch (e) {
      return null;
    }
  }
  /* 형식 있는 배열(Uint8Array 등)은 JSON 에서 객체가 되므로 보통 배열로 바꿔 보낸다 */
  function plain(v) {
    if (v && typeof v === 'object') {
      if (ArrayBuffer.isView(v)) return Array.prototype.slice.call(v);
      if (Array.isArray(v)) return v.map(plain);
      var o = {};
      Object.keys(v).forEach(function (k) {
        o[k] = plain(v[k]);
      });
      return o;
    }
    return v;
  }
  function post(op, args, cb) {
    var h = handler();
    if (!h) return false;
    try {
      h.postMessage({ op: op, args: plain(args || []), cb: cb || 0 });
      return true;
    } catch (e) {
      return false;
    }
  }
  function call(op, args, fallback) {
    return new Promise(function (res) {
      var id = ++seq;
      waits[id] = res;
      if (!post(op, args, id)) {
        delete waits[id];
        res(fallback);
      }
    });
  }
  function send(op, args) {
    post(op, args, 0);
  }
  function on(ch) {
    return function (fn) {
      if (typeof fn !== 'function') return;
      (subs[ch] = subs[ch] || []).push(fn);
    };
  }
  function noop() {}
  function note(text) {
    send('log', [String(text).slice(0, 300)]);
  }
  function none() {
    return Promise.resolve(null);
  }

  /* 가져온 캐릭터 — 네이티브는 원래 .cvclk 를 그대로(잠긴 채) 넘기고, 여기서 ios-import.js
     (데스크톱 importer.js 그대로)로 풀어 둔다. 한 번 푼 파일은 charKey 로 기억해 두고,
     네이티브에는 "받았다"(charInfo)를 알려 같은 파일을 다시 보내지 않게 한다. */
  var loadedFiles = {};
  var current = null;
  function fill(p) {
    if (!p || !p.charKey) return Promise.resolve(p);
    var key = p.charKey;
    var ready = loadedFiles[key];
    if (!ready && p.charFile && window.ClickerImport) {
      ready = loadedFiles[key] = window.ClickerImport.load(p.charFile).then(
        function (entry) {
          send('charInfo', [key, entry.names, entry.locked, '']);
          return entry;
        },
        function (e) {
          delete loadedFiles[key];
          send('charInfo', [key, [], false, String((e && e.message) || e)]);
          return null;
        }
      );
    }
    if (!ready) {
      send('charNeed', [key]);
      return Promise.resolve(Object.assign({}, p, { char: p.charDefault }));
    }
    return ready.then(function (entry) {
      var c = entry ? entry.resolve(p.charIndex || 0, p.geom && p.geom.size) : null;
      if (!c) return Object.assign({}, p, { char: p.charDefault });
      current = { entry: entry, id: c.id };
      var pet = Object.assign({}, p.pet, { charId: c.id });
      return Object.assign({}, p, { char: c, pet: pet });
    });
  }

  window.__clk = {
    resolve: function (id, v) {
      var f = waits[id];
      if (!f) return;
      delete waits[id];
      f(v);
    },
    emit: function (ch, v) {
      var deliver = function (val) {
        (subs[ch] || []).slice().forEach(function (f) {
          try {
            f(val);
          } catch (e) {
            console.error('[clicker] ' + ch, e);
          }
        });
      };
      if (ch === 'data') fill(v).then(deliver);
      else deliver(v);
    }
  };

  window.bridge = {
    lang: window.__clkLang || 'ko',

    /* 캐릭터 · 크기 · 설정 */
    ready: function () {
      return call('ready', [], null).then(fill);
    },
    onData: on('data'),
    onArea: on('area'),
    onLift: on('lift'),
    onRest: on('rest'),
    onReact: on('react'),
    onRemind: on('remind'),
    onCapture: on('capture'),
    onCapState: on('capState'),
    onMenuClose: on('menuClose'),
    loaded: function () {
      send('loaded');
    },
    lineSoundUrl: function (charId, name) {
      if (current && current.id === charId) return Promise.resolve(current.entry.lineSoundUrl(charId, name));
      return call('lineSound', [charId, name], '');
    },

    /* 눌리는 자리 — 그림이 있는 칸 지도와 알림 같은 덧붙은 자리 */
    sendMask: function (id, mask) {
      var on = 0;
      if (mask && mask.bits) for (var i = 0; i < mask.bits.length; i++) on += mask.bits[i] ? 1 : 0;
      note('mask ' + (mask && mask.gw) + 'x' + (mask && mask.gh) + ' on=' + on);
      send('mask', [mask]);
    },
    hot: function (id, rect, key) {
      send('hot', [rect || null, typeof key === 'string' && key ? key : 'remind']);
    },

    /* 끌기 — 손가락 자리는 네이티브가 직접 잰다 */
    dragStart: function () {
      return call('dragStart', [], false);
    },
    dragMove: function () {
      send('dragMove');
    },
    dragEnd: function () {
      send('dragEnd');
    },
    clicked: function () {
      send('clicked');
    },

    /* X 안에서는 쓰지 않는 것 — 메뉴 · 촬영 · 시간 알림 · 여러 캐릭터 사이 말풍선 피하기 */
    contextMenu: noop,
    menuOpen: none,
    menuAct: none,
    menuClosed: noop,
    pressed: noop,
    penAway: noop,
    quiet: noop,
    vis: noop,
    avoid: function () {
      return Promise.resolve({ hard: [], soft: [] });
    },
    bubbleShown: function (id, r, ms) {
      note('bubble shown ' + (r ? [r.l, r.t, r.r, r.b].map(Math.round).join(',') : '-') + ' ' + ms + 'ms');
    },
    bubbleHidden: function () {
      note('bubble hidden');
    },
    capToggle: noop,
    capOpt: noop,
    capShot: noop,
    capEnd: noop,
    capArea: noop,
    capHello: noop,
    capSize: noop,
    capDir: none,
    remindDone: noop,
    setRemind: none,
    remindNext: none,
    remindTest: none,
    reorderPet: none,
    undo: noop,
    redo: noop
  };

  /* 손가락은 마우스보다 떨린다. pet.js 는 4px 넘게 움직이면 끌기로 보고 누르기(말풍선)를 건너뛰므로,
     누른 자리에서 10px 안의 움직임은 pet.js 에 넘기지 않는다. 넘어서면 그때부터는 그대로 넘긴다. */
  var TAP_SLOP = 10;
  var press = null;
  window.addEventListener(
    'pointerdown',
    function (e) {
      press = e.pointerType === 'mouse' ? null : { id: e.pointerId, x: e.clientX, y: e.clientY, free: false };
    },
    true
  );
  window.addEventListener(
    'pointermove',
    function (e) {
      if (!press || press.free || e.pointerId !== press.id) return;
      if (Math.abs(e.clientX - press.x) + Math.abs(e.clientY - press.y) < TAP_SLOP) e.stopImmediatePropagation();
      else press.free = true;
    },
    true
  );
  ['pointerup', 'pointercancel'].forEach(function (t) {
    window.addEventListener(
      t,
      function (e) {
        if (press && e.pointerId === press.id) press = null;
        if (t === 'pointercancel') note('pointercancel');
      },
      true
    );
  });

  /* 흔들기 덤프(DebugDump)에 실기기 기록을 남긴다 — 오류와 말풍선 · 지도 소식만 */
  window.addEventListener('error', function (e) {
    note('error ' + (e.message || '') + ' @' + (e.filename || '').split('/').pop() + ':' + (e.lineno || 0));
  });
  window.addEventListener('unhandledrejection', function (e) {
    note('rejection ' + String((e.reason && e.reason.message) || e.reason));
  });
  ['error', 'warn'].forEach(function (k) {
    var orig = console[k];
    console[k] = function () {
      try {
        note(k + ' ' + Array.prototype.map.call(arguments, function (a) {
          return a && a.message ? a.message : String(a);
        }).join(' '));
      } catch (e) {}
      return orig.apply(console, arguments);
    };
  });

  /* 길게 누를 때 뜨는 확대경 · 복사 메뉴 · 끌어서 저장을 막는다 */
  function noCallout() {
    var s = document.createElement('style');
    s.textContent =
      'html,body,*{-webkit-touch-callout:none!important;-webkit-user-select:none!important;user-select:none!important;' +
      '-webkit-user-drag:none!important;-webkit-tap-highlight-color:transparent!important}' +
      'html,body{background:transparent!important;overflow:hidden!important}' +
      '#stack{touch-action:none}';
    (document.head || document.documentElement).appendChild(s);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', noCallout);
  else noCallout();
})();
