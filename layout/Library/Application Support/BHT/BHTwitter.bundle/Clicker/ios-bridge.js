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
  var bubbleProbes = 0;
  function probeBubble() {
    try {
      var b = document.getElementById('bubble');
      if (!b) return note('probe no #bubble');
      var cs = getComputedStyle(b);
      var r = b.getBoundingClientRect();
      var cx = r.left + r.width / 2;
      var cy = r.top + r.height / 2;
      var top = document.elementFromPoint(cx, cy);
      var bt = b.querySelector('.bt');
      note(
        'probe cls=' + b.className + ' op=' + cs.opacity + ' vis=' + cs.visibility + ' disp=' + cs.display +
          ' z=' + cs.zIndex + ' tf=' + cs.transform + ' bg=' + cs.backgroundColor + ' fg=' + cs.color +
          ' rect=' + [r.left, r.top, r.width, r.height].map(Math.round).join(',') +
          ' text="' + (bt ? bt.textContent : '').slice(0, 20) + '" textop=' + (bt ? getComputedStyle(bt).opacity : '-') +
          ' atCenter=' + (top ? top.tagName + '#' + top.id + '.' + top.className : 'none') +
          ' view=' + innerWidth + 'x' + innerHeight + ' body=' + document.body.className
      );
    } catch (e) {
      note('probe failed ' + e.message);
    }
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
    if (p && p.char && !p.charKey && window.ClickerImport && ClickerImport.normalizeBuiltIn) {
      try {
        p = Object.assign({}, p, { char: ClickerImport.normalizeBuiltIn(p.char) });
      } catch (e) {
        note('normalize failed ' + e.message);
      }
    }
    if (p && p.charDefault && window.ClickerImport && ClickerImport.normalizeBuiltIn) {
      try {
        p = Object.assign({}, p, { charDefault: ClickerImport.normalizeBuiltIn(p.charDefault) });
      } catch (e) {}
    }
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
      /* 실기기에서 "떴다는데 안 보인다" 를 가리기 위해, 실제로 그려진 모양을 한 번 남긴다 */
      if (bubbleProbes++ < 3) setTimeout(probeBubble, 260);
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

  /* 손가락 → 데스크톱 입력. pet.js 는 마우스용이다: 누르면 바로 끌기를 시작하고, 쓰다듬기(하트)는
     "누르지 않고 위에서 문지르기"(hover)로만 된다. 손가락에는 hover 가 없으므로 이렇게 나눈다.
       · 톡 누르기                  → 누르기 + 떼기 (클릭 · 말풍선)
       · 누르자마자 문지르기        → 버튼 없는 pointermove (쓰다듬기 · 하트), 끝나면 pointerleave
       · 0.35초 꾹 누른 뒤 움직이기 → 그때 누르기를 넘겨 pet.js 가 집어 든다(끌기)
     진짜 손가락 이벤트는 여기서 붙잡아 두고, pet.js 에는 만든 이벤트를 넘긴다(__clk 표시). */
  var TAP_SLOP = 10;
  var HOLD_MS = 350;
  var touch = null;
  function fake(type, src, buttons, target) {
    var ev = new PointerEvent(type, {
      bubbles: type !== 'pointerleave',
      cancelable: true,
      composed: true,
      pointerId: src.pointerId,
      pointerType: src.pointerType,
      isPrimary: true,
      clientX: src.clientX,
      clientY: src.clientY,
      screenX: src.screenX,
      screenY: src.screenY,
      button: type === 'pointermove' || type === 'pointerleave' ? -1 : 0,
      buttons: buttons,
      pressure: buttons ? 0.5 : 0
    });
    ev.__clk = true;
    (target || touch.target).dispatchEvent(ev);
  }
  function lift() {
    if (!touch || touch.mode !== 'wait') return;
    touch.mode = 'drag';
    note('touch hold → drag');
    fake('pointerdown', touch.last, 1);
  }
  window.addEventListener(
    'pointerdown',
    function (e) {
      if (e.__clk || e.pointerType === 'mouse') return;
      e.stopImmediatePropagation();
      if (touch) clearTimeout(touch.timer);
      touch = { id: e.pointerId, x: e.clientX, y: e.clientY, target: e.target, last: e, mode: 'wait' };
      touch.timer = setTimeout(lift, HOLD_MS);
    },
    true
  );
  window.addEventListener(
    'pointermove',
    function (e) {
      if (e.__clk || !touch || e.pointerId !== touch.id) return;
      touch.last = e;
      if (touch.mode === 'drag') return; // pet.js 가 끌고 있다 — 그대로 넘긴다
      e.stopImmediatePropagation();
      if (touch.mode === 'wait') {
        if (Math.abs(e.clientX - touch.x) + Math.abs(e.clientY - touch.y) < TAP_SLOP) return;
        clearTimeout(touch.timer);
        touch.mode = 'pet';
        note('touch rub → pet');
      }
      fake('pointermove', e, 0, document.elementFromPoint(e.clientX, e.clientY) || touch.target);
    },
    true
  );
  function finish(e) {
    if (e.__clk || !touch || e.pointerId !== touch.id) return;
    var t = touch;
    clearTimeout(t.timer);
    if (t.mode === 'drag') {
      touch = null; // pet.js 가 진짜 떼기를 받아 끌기를 마친다
      return;
    }
    e.stopImmediatePropagation();
    if (t.mode === 'wait' && e.type === 'pointerup') {
      fake('pointerdown', t.last, 1);
      fake('pointerup', e, 0);
    } else if (t.mode === 'pet') {
      fake('pointerleave', e, 0, document.getElementById('stack') || t.target);
    }
    touch = null;
  }
  window.addEventListener('pointerup', finish, true);
  window.addEventListener(
    'pointercancel',
    function (e) {
      note('pointercancel');
      finish(e);
    },
    true
  );

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

  /* pet.html 은 데스크톱(Electron)용이라 viewport 가 없다. 그러면 iOS WebKit 은 페이지를 980px 폭으로
     그리고 창 크기(약 500pt)로 줄여 보여 준다. 그림 · 말풍선은 980px 기준으로 자리를 잡고, 눌리는 칸 지도는
     창 기준이라 둘이 어긋났다(7.3.118 덤프: WKContentView 안 980x735). 문서 시작 때 창 폭 그대로 그리게 한다. */
  var vp = document.createElement('meta');
  vp.name = 'viewport';
  vp.content = 'width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover';
  /* 문서 시작 때는 아직 <html> 도 없다. <head> 가 생기는 순간 맨 앞에 넣는다(그래야 첫 배치부터 맞다). */
  function placeViewport() {
    if (!document.head) return false;
    if (vp.parentNode !== document.head) document.head.insertBefore(vp, document.head.firstChild);
    return true;
  }
  if (!placeViewport()) {
    var watch = new MutationObserver(function () {
      if (placeViewport()) watch.disconnect();
    });
    watch.observe(document, { childList: true, subtree: true });
    document.addEventListener('DOMContentLoaded', function () {
      watch.disconnect();
      placeViewport();
    });
  }

  /* 길게 누를 때 뜨는 확대경 · 복사 메뉴 · 끌어서 저장을 막는다 */
  function noCallout() {
    var s = document.createElement('style');
    s.textContent =
      'html,body,*{-webkit-touch-callout:none!important;-webkit-user-select:none!important;user-select:none!important;' +
      '-webkit-user-drag:none!important;-webkit-tap-highlight-color:transparent!important}' +
      'html,body{background:transparent!important;overflow:hidden!important;-webkit-text-size-adjust:100%!important}' +
      '#stack{touch-action:none}';
    (document.head || document.documentElement).appendChild(s);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', noCallout);
  else noCallout();
})();
