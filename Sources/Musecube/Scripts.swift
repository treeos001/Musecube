enum Scripts {
    /// Injected at document start in the main frame. Exposes window.__wtb.
    static let core = #"""
(function () {
  if (window.__wtb) return;
  var post = function (m) { try { window.webkit.messageHandlers.wtb.postMessage(m); } catch (e) {} };
  var STYLE =
    'html[data-wtb-on] [data-wtb-anc] > :not([data-wtb-anc]):not([data-wtb-keep]):not(#__wtb_style):not(#__wtb_pick){display:none !important;}' +
    'html[data-wtb-on] [data-wtb-anc]{width:100% !important;max-width:none !important;min-width:0 !important;margin:0 !important;padding:0 !important;border:0 !important;float:none !important;position:static !important;transform:none !important;left:auto !important;top:auto !important;}' +
    'html[data-wtb-on], html[data-wtb-on] > body{height:auto !important;min-height:100% !important;overflow:auto !important;}' +
    'html[data-wtb-on] [data-wtb-keep]{width:100% !important;max-width:none !important;margin:0 !important;box-sizing:border-box !important;position:relative !important;left:auto !important;top:auto !important;transform:none !important;float:none !important;}';

  var W = { sel: null, obs: null, poll: null, found: null, picking: false, debounce: null };

  function q(s) { try { return document.querySelector(s); } catch (e) { return null; } }
  function lca(a, b) {
    var set = new Set(); var p = a;
    while (p) { set.add(p); p = p.parentElement; }
    p = b; while (p && !set.has(p)) p = p.parentElement;
    return p;
  }
  function findTarget(sel) {
    var cands = sel.split('||');
    for (var i = 0; i < cands.length; i++) {
      var c = cands[i].trim(); if (!c) continue;
      if (c.indexOf('&&') >= 0) {
        var parts = c.split('&&').map(function (s) { return s.trim(); });
        var els = parts.map(q);
        if (els.every(function (e) { return !!e; })) {
          var a = els[0];
          for (var j = 1; j < els.length && a; j++) a = lca(a, els[j]);
          if (a && a !== document.documentElement && a !== document.body) return a;
        }
      } else {
        var el = q(c);
        if (el && el !== document.documentElement) return el;
      }
    }
    return null;
  }
  function clearMarks() {
    document.querySelectorAll('[data-wtb-keep],[data-wtb-anc]').forEach(function (e) {
      e.removeAttribute('data-wtb-keep'); e.removeAttribute('data-wtb-anc');
    });
    document.documentElement.removeAttribute('data-wtb-on');
  }
  function ensureStyle() {
    if (document.getElementById('__wtb_style')) return;
    var s = document.createElement('style'); s.id = '__wtb_style'; s.textContent = STYLE;
    (document.head || document.documentElement).appendChild(s);
  }
  function report(found) {
    if (W.found === found) return;
    W.found = found; post({ type: 'ruleStatus', found: found });
  }
  function mark() {
    if (!W.sel) return false;
    var el = findTarget(W.sel);
    if (!el) return false;
    if (el.hasAttribute('data-wtb-keep') && document.documentElement.hasAttribute('data-wtb-on')) return true;
    clearMarks();
    el.setAttribute('data-wtb-keep', '');
    var p = el.parentElement;
    while (p) { p.setAttribute('data-wtb-anc', ''); p = p.parentElement; }
    ensureStyle();
    document.documentElement.setAttribute('data-wtb-on', '');
    return true;
  }
  function onMutate() {
    if (W.debounce) return;
    W.debounce = setTimeout(function () {
      W.debounce = null;
      if (!W.sel || W.poll) return;
      if (mark()) { report(true); } else { clearMarks(); report(false); }
    }, 150);
  }

  W.apply = function (sel) {
    W.remove();
    W.sel = sel; W.found = null;
    if (!W.obs) W.obs = new MutationObserver(onMutate);
    W.obs.observe(document.documentElement, { childList: true, subtree: true });
    if (mark()) { report(true); return; }
    // SPA pages render late: poll up to ~8s before declaring the rule broken.
    var tries = 0;
    W.poll = setInterval(function () {
      tries++;
      if (mark()) { clearInterval(W.poll); W.poll = null; report(true); }
      else if (tries >= 16) { clearInterval(W.poll); W.poll = null; report(false); }
    }, 500);
  };
  W.remove = function () {
    W.sel = null;
    if (W.poll) { clearInterval(W.poll); W.poll = null; }
    if (W.obs) W.obs.disconnect();
    clearMarks();
    var s = document.getElementById('__wtb_style'); if (s) s.remove();
  };

  function esc(s) { return (window.CSS && CSS.escape) ? CSS.escape(s) : s.replace(/[^a-zA-Z0-9_-]/g, '\\$&'); }
  function selectorFor(el) {
    var parts = [];
    while (el && el.nodeType === 1 && el !== document.documentElement) {
      if (el.id && !/\d{3,}/.test(el.id)) {
        var idSel = '#' + esc(el.id);
        try { if (document.querySelectorAll(idSel).length === 1) { parts.unshift(idSel); break; } } catch (e) {}
      }
      if (el === document.body) { parts.unshift('body'); break; }
      var s = el.tagName.toLowerCase();
      var p = el.parentElement;
      if (p) {
        var same = Array.prototype.filter.call(p.children, function (c) { return c.tagName === el.tagName; });
        if (same.length > 1) s += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
      }
      parts.unshift(s); el = p;
    }
    return parts.join(' > ');
  }

  W.startPick = function () {
    if (W.picking) return;
    W.picking = true;
    var box = document.createElement('div'); box.id = '__wtb_pick';
    box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #0a84ff;background:rgba(10,132,255,.18);border-radius:3px;transition:all .05s;display:none;';
    var label = document.createElement('div');
    label.style.cssText = 'position:absolute;left:0;top:-20px;font:11px -apple-system,sans-serif;background:#0a84ff;color:#fff;padding:1px 5px;border-radius:3px;white-space:nowrap;';
    box.appendChild(label);
    document.documentElement.appendChild(box);
    var cur = null;
    function show(el) {
      if (!el || el === document.documentElement) return;
      cur = el;
      var r = el.getBoundingClientRect();
      box.style.display = 'block';
      box.style.left = r.left + 'px'; box.style.top = r.top + 'px';
      box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
      label.style.top = r.top < 22 ? '2px' : '-20px';
      label.textContent = el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + '  ' + Math.round(r.width) + '×' + Math.round(r.height);
    }
    function block(e) { e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation(); }
    function over(e) { if (e.target !== box) show(e.target); }
    function click(e) {
      block(e);
      if (cur) { var s = selectorFor(cur); finish(); post({ type: 'picked', selector: s }); }
    }
    function key(e) {
      if (e.key === 'Escape') { block(e); finish(); post({ type: 'pickCancel' }); }
      else if (e.key === 'ArrowUp' && cur && cur.parentElement && cur.parentElement !== document.documentElement) { block(e); show(cur.parentElement); }
    }
    var evs = ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick'];
    function finish() {
      W.picking = false;
      document.removeEventListener('mouseover', over, true);
      document.removeEventListener('click', click, true);
      document.removeEventListener('keydown', key, true);
      evs.forEach(function (t) { document.removeEventListener(t, block, true); });
      box.remove();
      W.stopPick = function () {};
    }
    document.addEventListener('mouseover', over, true);
    document.addEventListener('click', click, true);
    document.addEventListener('keydown', key, true);
    evs.forEach(function (t) { document.addEventListener(t, block, true); });
    W.stopPick = finish;
  };
  W.stopPick = function () {};

  window.__wtb = W;
})();
"""#

    /// window.open(blob:) is sent in pieces so a large file is not held as one base64 string.
    /// data: URLs are still one message. Native replies with __wtbDLGo / __wtbDLAbort.
    static let downloadHelper = #"""
(function () {
  if (window.__wtbDL) return; window.__wtbDL = true;
  var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wtbdl;
  if (!h) return;
  var jobs = {};
  function pump(job) {
    var chunk = 8 * 1024 * 1024, b = job.blob;
    if (job.i >= b.size) { h.postMessage({ type: 'blob-end', id: job.id }); return; }
    var fr = new FileReader();
    fr.onload = function () {
      var s = String(fr.result), c = s.indexOf(',');
      h.postMessage({ type: 'blob-chunk', id: job.id, offset: job.i, data: c >= 0 ? s.slice(c + 1) : '' });
      job.i += chunk;
      pump(job);
    };
    fr.onerror = function () { h.postMessage({ type: 'error', message: 'read failed', id: job.id }); };
    fr.readAsDataURL(b.slice(job.i, Math.min(job.i + chunk, b.size)));
  }
  window.__wtbDLGo = function (id) { var job = jobs[id]; if (!job) return; delete jobs[id]; pump(job); };
  window.__wtbDLAbort = function (id) { delete jobs[id]; };
  function send(url, name) {
    fetch(url).then(function (r) { return r.blob(); }).then(function (b) {
      var id = Math.random().toString(36).slice(2) + Date.now().toString(36);
      jobs[id] = { id: id, blob: b, i: 0 };
      h.postMessage({ type: 'blob-begin', id: id, name: name || '', mime: b.type || '', size: b.size });
    }).catch(function (e) { h.postMessage({ type: 'error', message: String(e) }); });
  }
  var orig = window.open;
  window.open = function (u) {
    try {
      var s = String(u || '');
      if (/^blob:/i.test(s)) { send(s, ''); return null; }
      if (/^data:/i.test(s)) { h.postMessage({ type: 'data-url', url: s }); return null; }
    } catch (e) {}
    return orig.apply(window, arguments);
  };
})();
"""#
}
