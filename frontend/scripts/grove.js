/* =========================================================================
   Arboryx grove — leaf rendering + interactions (Phase 4).

   Reads recent findings via the read-only API, buckets each entry into a
   recency-day slot (today → 7d ago), and renders ovate-leaf <ellipse>
   nodes into the per-tree <g class="leaf-cluster" data-leaves-for="..."/>
   placeholders. Each leaf is keyboard-focusable and:

     - Hover (pointer)         → CSS scale + glow + Web Audio chirp
     - Focus (keyboard)        → CSS scale + glow (no chirp)
     - Click (1st)             → show floating tooltip
     - Click (2nd) / Enter     → navigate to new_growth.html?sector=…&entry=…&date=…

   Web Audio is gated on first user gesture (browser autoplay policy),
   default-muted on prefers-reduced-motion, and toggleable via the legend.

   Dependencies: window.ARBORYX_CONFIG (set by scripts/config.js),
                 window.__arboryx (set by landing.js).
   ========================================================================= */

(() => {
  'use strict';

  const SVG_NS = 'http://www.w3.org/2000/svg';

  // ----------------------------------------------------------------------
  // Leaf slots — five branch clusters, seven slots each (35 total).
  // Coordinates are relative to the trunk base (0,0); tree grows in -y.
  //
  // Within each cluster, slot[0] is the branch *tip* (largest, most
  // prominent), then satellites work back along the branch with smaller
  // sizes. Slot allocation across clusters is round-robin (see
  // LEAF_SLOT_ORDER below) so a sparse tree has leaves on EVERY branch
  // before any branch gets a second leaf.
  // ----------------------------------------------------------------------
  const CLUSTER_TOP = [
    { x:   0, y: -152, rx: 11.0, ry: 8.4 },   // crown tip
    { x: -14, y: -144, rx:  9.0, ry: 7.0 },
    { x:  14, y: -146, rx:  9.0, ry: 7.0 },
    { x: -22, y: -136, rx:  8.0, ry: 6.2 },
    { x:  22, y: -138, rx:  8.0, ry: 6.2 },
    { x:  -8, y: -130, rx:  7.0, ry: 5.4 },
    { x:   8, y: -132, rx:  7.0, ry: 5.4 },
  ];
  const CLUSTER_UL = [
    { x: -36, y: -138, rx: 11.0, ry: 8.4 },   // upper-left tip
    { x: -50, y: -132, rx:  9.0, ry: 7.0 },
    { x: -22, y: -130, rx:  9.0, ry: 7.0 },
    { x: -50, y: -120, rx:  8.0, ry: 6.2 },
    { x: -28, y: -116, rx:  8.0, ry: 6.2 },
    { x: -42, y: -108, rx:  7.0, ry: 5.4 },
    { x: -16, y: -118, rx:  7.0, ry: 5.4 },
  ];
  const CLUSTER_UR = [
    { x:  38, y: -135, rx: 11.0, ry: 8.4 },   // upper-right tip
    { x:  52, y: -130, rx:  9.0, ry: 7.0 },
    { x:  24, y: -126, rx:  9.0, ry: 7.0 },
    { x:  52, y: -118, rx:  8.0, ry: 6.2 },
    { x:  30, y: -114, rx:  8.0, ry: 6.2 },
    { x:  44, y: -106, rx:  7.0, ry: 5.4 },
    { x:  18, y: -116, rx:  7.0, ry: 5.4 },
  ];
  const CLUSTER_LL = [
    { x: -62, y: -88,  rx: 11.0, ry: 8.4 },   // lower-left tip
    { x: -74, y: -82,  rx:  9.0, ry: 7.0 },
    { x: -50, y: -82,  rx:  9.0, ry: 7.0 },
    { x: -74, y: -94,  rx:  8.0, ry: 6.2 },
    { x: -48, y: -94,  rx:  8.0, ry: 6.2 },
    { x: -62, y: -76,  rx:  7.0, ry: 5.4 },
    { x: -56, y: -100, rx:  7.0, ry: 5.4 },
  ];
  const CLUSTER_LR = [
    { x:  64, y: -95,  rx: 11.0, ry: 8.4 },   // lower-right tip
    { x:  76, y: -89,  rx:  9.0, ry: 7.0 },
    { x:  52, y: -89,  rx:  9.0, ry: 7.0 },
    { x:  76, y: -101, rx:  8.0, ry: 6.2 },
    { x:  50, y: -101, rx:  8.0, ry: 6.2 },
    { x:  64, y: -83,  rx:  7.0, ry: 5.4 },
    { x:  58, y: -107, rx:  7.0, ry: 5.4 },
  ];

  // Round-robin slot order: tip-of-each-cluster first, then satellite[1]
  // of each, etc. This guarantees that a tree with N≥5 leaves shows at
  // least one leaf on every branch.
  const CLUSTERS = [CLUSTER_TOP, CLUSTER_UL, CLUSTER_UR, CLUSTER_LL, CLUSTER_LR];
  const LEAF_SLOTS = [];
  for (let i = 0; i < 7; i++) {
    for (const c of CLUSTERS) LEAF_SLOTS.push(c[i]);
  }
  const MAX_LEAVES = LEAF_SLOTS.length;   // 35

  // ----------------------------------------------------------------------
  // Recency → leaf-color class
  // ----------------------------------------------------------------------
  function recencyClass(daysOld) {
    const d = Math.max(0, Math.min(6, Math.floor(daysOld)));
    return `leaf-d${d}`;
  }

  function daysOldFromTimestamp(ts, todayUTC) {
    if (!ts) return 7;
    // Master log timestamps are YYYY-MM-DD (verified in dev-utils audit).
    const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(ts);
    if (!m) return 7;
    const d = Date.UTC(+m[1], +m[2] - 1, +m[3]);
    return Math.max(0, Math.round((todayUTC - d) / 86400000));
  }

  // ----------------------------------------------------------------------
  // API fetch — recency-scoped findings
  // ----------------------------------------------------------------------
  async function fetchRecentFindings(cfg) {
    const url = cfg.api.url;
    const key = cfg.api.publicKey;
    if (!url || !key) return [];
    const days = Number(cfg.grove.recencyDays) || 7;
    try {
      // limit=1000 = the API's hard cap (Track A Phase 1).  Plenty for the
      // grove: max needed = MAX_LEAVES_PER_DAY * sectors * recencyDays
      // (~5 * 6 * 7 = 210), and the days filter already trims to recent.
      const resp = await fetch(`${url}?action=findings&days=${days}&sort=desc&limit=1000`, {
        headers: { 'X-API-Key': key },
      });
      if (!resp.ok) throw new Error(`findings ${resp.status}`);
      const body = await resp.json();
      return Array.isArray(body.findings) ? body.findings : [];
    } catch (err) {
      console.warn('grove findings fetch failed:', err);
      return [];
    }
  }

  // ----------------------------------------------------------------------
  // Bucket entries by sector → by recency-day, capped at MAX_LEAVES_PER_DAY
  // Returns sectorMap[sector] = ordered array of entries assigned to slots
  // (newest first, with per-day cap applied).
  // ----------------------------------------------------------------------
  function pickEntriesForGrove(findings, cfg, todayUTC) {
    const cap = Number(cfg.grove.maxLeavesPerDay) || 5;
    const recencyDays = Number(cfg.grove.recencyDays) || 7;
    const sectorMap = new Map();

    for (const e of findings) {
      const sec = e.category || 'Unknown';
      const daysOld = daysOldFromTimestamp(e.timestamp, todayUTC);
      if (daysOld >= recencyDays + 1) continue;
      const arr = sectorMap.get(sec) || [];
      arr.push({ ...e, daysOld });
      sectorMap.set(sec, arr);
    }

    // Sort each sector's entries newest first, then apply per-day cap.
    for (const [sec, arr] of sectorMap) {
      arr.sort((a, b) => a.daysOld - b.daysOld);
      const perDay = new Map();
      const kept = [];
      for (const e of arr) {
        const c = perDay.get(e.daysOld) || 0;
        if (c >= cap) continue;
        perDay.set(e.daysOld, c + 1);
        kept.push(e);
        if (kept.length >= MAX_LEAVES) break;
      }
      sectorMap.set(sec, kept);
    }

    return sectorMap;
  }

  // ----------------------------------------------------------------------
  // Render leaves into one tree
  // ----------------------------------------------------------------------
  function renderLeavesIntoTree(treeEl, entries, leafSizeMul) {
    const cluster = treeEl.querySelector('.leaf-cluster');
    if (!cluster) return;
    while (cluster.firstChild) cluster.removeChild(cluster.firstChild);

    const mul = Number(leafSizeMul) || 1.0;
    entries.forEach((entry, i) => {
      if (i >= LEAF_SLOTS.length) return;
      const slot = LEAF_SLOTS[i];
      const leaf = document.createElementNS(SVG_NS, 'ellipse');
      leaf.setAttribute('cx', slot.x);
      leaf.setAttribute('cy', slot.y);
      leaf.setAttribute('rx', (slot.rx * mul).toFixed(2));
      leaf.setAttribute('ry', (slot.ry * mul).toFixed(2));
      leaf.setAttribute('class', `tree-leaf ${recencyClass(entry.daysOld)}`);
      leaf.setAttribute('tabindex', '0');
      leaf.setAttribute('role', 'button');
      leaf.setAttribute('data-entry-id', entry.entry_id || '');
      leaf.setAttribute('data-sector', entry.category || '');
      leaf.setAttribute('data-timestamp', entry.timestamp || '');
      leaf.setAttribute('data-tooltip', entry.tooltip || entry.finding || '');
      leaf.setAttribute('data-days-old', String(entry.daysOld));
      leaf.setAttribute(
        'aria-label',
        `${entry.category} — ${entry.tooltip || entry.finding || entry.entry_id} · ${entry.daysOld === 0 ? 'today' : entry.daysOld + ' day' + (entry.daysOld === 1 ? '' : 's') + ' ago'}`,
      );
      cluster.appendChild(leaf);
    });
  }

  // ----------------------------------------------------------------------
  // Web Audio — chirp on hover.  Lazy-init on first user gesture so
  // browsers don't block the AudioContext.  Each sector has its own
  // base frequency for tonal interest.
  // ----------------------------------------------------------------------
  // Per-sector base frequency for the tone body of the hover blip.
  // Tightened into the typical UI-sound range (700–1000 Hz) so the
  // result feels like a soft menu-hover tap rather than a musical bell.
  const SECTOR_FREQ = {
    'Robotics':           700,
    'Crypto':             760,
    'AI Stack':           820,
    'Space & Defense':    880,
    'Power & Energy':     940,
    'Strategic Minerals': 1000,
  };

  const audio = {
    ctx: null,
    muted: false,
    init() {
      if (this.ctx) return;
      const Ctor = window.AudioContext || window.webkitAudioContext;
      if (!Ctor) return;
      try { this.ctx = new Ctor(); } catch (_) { /* no-op */ }
    },
    chirp(sector, daysOld) {
      if (this.muted || !this.ctx || this.ctx.state === 'suspended') return;
      try {
        // UI dialog-hover style blip: a lowpassed triangle tone with a
        // subtle downward pitch sweep (the "tap-and-settle" feel) plus a
        // very brief filtered-noise click at the front for the tactile
        // "tick" that distinguishes a UI sound from a musical chirp.
        const ctx = this.ctx;
        const base = SECTOR_FREQ[sector] || 820;
        // Newer entries blip slightly higher; older a touch lower.
        const ageBoost = Math.pow(2, (3 - Math.min(6, daysOld)) / 36);
        const f0 = base * ageBoost;
        const t0 = ctx.currentTime;

        // --- Tone body ---
        const osc = ctx.createOscillator();
        osc.type = 'triangle';
        osc.frequency.setValueAtTime(f0 * 1.35, t0);
        osc.frequency.exponentialRampToValueAtTime(f0, t0 + 0.04);

        const lp = ctx.createBiquadFilter();
        lp.type = 'lowpass';
        lp.frequency.setValueAtTime(2400, t0);
        lp.Q.setValueAtTime(0.7, t0);

        const toneGain = ctx.createGain();
        toneGain.gain.setValueAtTime(0.0001, t0);
        toneGain.gain.exponentialRampToValueAtTime(0.06, t0 + 0.003);
        toneGain.gain.exponentialRampToValueAtTime(0.0001, t0 + 0.07);

        osc.connect(lp).connect(toneGain).connect(ctx.destination);
        osc.start(t0);
        osc.stop(t0 + 0.08);

        // --- Tactile click (filtered noise burst, < 15 ms) ---
        const noiseBuf = ctx.createBuffer(1, 256, ctx.sampleRate);
        const ch = noiseBuf.getChannelData(0);
        for (let i = 0; i < ch.length; i++) ch[i] = Math.random() * 2 - 1;
        const noise = ctx.createBufferSource();
        noise.buffer = noiseBuf;

        const noiseFilter = ctx.createBiquadFilter();
        noiseFilter.type = 'highpass';
        noiseFilter.frequency.setValueAtTime(1500, t0);

        const noiseGain = ctx.createGain();
        noiseGain.gain.setValueAtTime(0.018, t0);
        noiseGain.gain.exponentialRampToValueAtTime(0.0001, t0 + 0.012);

        noise.connect(noiseFilter).connect(noiseGain).connect(ctx.destination);
        noise.start(t0);
        noise.stop(t0 + 0.02);
      } catch (_) { /* swallow — never block UI on audio */ }
    },
    setMuted(m) {
      this.muted = !!m;
      if (!this.muted && this.ctx && this.ctx.state === 'suspended') {
        this.ctx.resume().catch(() => {});
      }
    },
  };

  // ----------------------------------------------------------------------
  // Tooltip — single floating <div> reused across all leaves
  // ----------------------------------------------------------------------
  function createTooltipNode() {
    const tt = document.createElement('div');
    tt.className = 'leaf-tooltip';
    tt.setAttribute('role', 'tooltip');
    tt.setAttribute('aria-hidden', 'true');
    document.body.appendChild(tt);
    return tt;
  }

  function showTooltip(tt, leafEl) {
    const text   = leafEl.getAttribute('data-tooltip') || '';
    const sector = leafEl.getAttribute('data-sector') || '';
    const ts     = leafEl.getAttribute('data-timestamp') || '';
    const days   = leafEl.getAttribute('data-days-old') || '';
    const ago = days === '0' ? 'today' : `${days}d ago`;
    tt.innerHTML = '';
    const head = document.createElement('div');
    head.className = 'leaf-tooltip-head';
    head.textContent = `${sector} · ${ago}`;
    const body = document.createElement('div');
    body.className = 'leaf-tooltip-body';
    body.textContent = text;
    const date = document.createElement('div');
    date.className = 'leaf-tooltip-date';
    date.textContent = ts;
    tt.appendChild(head);
    tt.appendChild(body);
    tt.appendChild(date);

    // Position near the leaf's bounding rect, clamped to viewport.
    const r = leafEl.getBoundingClientRect();
    tt.style.visibility = 'hidden';
    tt.classList.add('visible');
    tt.setAttribute('aria-hidden', 'false');
    const ttR = tt.getBoundingClientRect();
    let left = r.left + r.width / 2 - ttR.width / 2;
    let top  = r.top - ttR.height - 10;
    const pad = 8;
    if (left < pad) left = pad;
    if (left + ttR.width > window.innerWidth - pad) left = window.innerWidth - pad - ttR.width;
    if (top < pad) top = r.bottom + 10; // flip below
    tt.style.left = `${Math.round(left)}px`;
    tt.style.top  = `${Math.round(top)}px`;
    tt.style.visibility = '';
  }

  function hideTooltip(tt) {
    tt.classList.remove('visible');
    tt.setAttribute('aria-hidden', 'true');
  }

  // ----------------------------------------------------------------------
  // Click → tooltip → navigate
  // First click: show tooltip on that leaf
  // Second click on SAME leaf (or Enter while focused): navigate
  // ----------------------------------------------------------------------
  function navigateToEntry(leafEl) {
    const sector  = leafEl.getAttribute('data-sector') || '';
    const entryId = leafEl.getAttribute('data-entry-id') || '';
    const ts      = leafEl.getAttribute('data-timestamp') || '';
    const params = new URLSearchParams({ sector, entry: entryId, date: ts });
    window.location.href = `new_growth.html?${params.toString()}`;
  }

  // ----------------------------------------------------------------------
  // Wire all interactions on the canvas.
  //
  // Hover  → chirp + tooltip (no click required).
  // Click  → navigate immediately to the entry's detail page.
  // Focus  → tooltip (keyboard parity).
  // Enter  → navigate.
  // Esc    → blur leaf.
  // ----------------------------------------------------------------------
  function wireInteractions(svg) {
    const tt = createTooltipNode();
    let armedFirstGesture = false;

    function armAudioOnce() {
      if (armedFirstGesture) return;
      armedFirstGesture = true;
      audio.init();
      if (audio.ctx && audio.ctx.state === 'suspended') {
        audio.ctx.resume().catch(() => {});
      }
    }

    // Browsers only treat click / keydown / pointerdown / touchstart as
    // valid user gestures for resuming a suspended AudioContext —
    // pointerover does NOT count. Without this, hover chirps stay silent
    // until the user happens to click a leaf. Listen once at document
    // level so any first interaction unlocks audio for subsequent hovers.
    const unlockEvents = ['pointerdown', 'keydown', 'touchstart'];
    const unlock = () => {
      armAudioOnce();
      unlockEvents.forEach((ev) => document.removeEventListener(ev, unlock));
    };
    unlockEvents.forEach((ev) => document.addEventListener(ev, unlock, { passive: true }));

    const isLeaf = (el) => el && el.classList && el.classList.contains('tree-leaf');

    // Pointer over a leaf → chirp + show tooltip
    svg.addEventListener('pointerover', (e) => {
      const t = e.target;
      if (!isLeaf(t)) return;
      armAudioOnce();
      audio.chirp(
        t.getAttribute('data-sector'),
        Number(t.getAttribute('data-days-old')) || 0,
      );
      showTooltip(tt, t);
    });

    svg.addEventListener('pointerout', (e) => {
      if (!isLeaf(e.target)) return;
      // pointerout fires on the leaving leaf BEFORE pointerover on the
      // next one. Defer the hide one frame so adjacent-leaf transitions
      // feel continuous instead of flickering.
      requestAnimationFrame(() => {
        // If a new leaf is under the pointer it'll have already shown
        // its tooltip; the next showTooltip call will repaint our reused
        // node. If not, we hide.
        const hovered = document.querySelector('.tree-leaf:hover');
        if (!hovered) hideTooltip(tt);
      });
    });

    // Keyboard focus → tooltip parity
    svg.addEventListener('focusin', (e) => {
      if (!isLeaf(e.target)) return;
      showTooltip(tt, e.target);
    });
    svg.addEventListener('focusout', (e) => {
      if (!isLeaf(e.target)) return;
      hideTooltip(tt);
    });

    // Click → navigate immediately
    svg.addEventListener('click', (e) => {
      const t = e.target;
      if (!isLeaf(t)) return;
      armAudioOnce();
      navigateToEntry(t);
    });

    // Keyboard: Enter / Space navigates; Escape blurs.
    svg.addEventListener('keydown', (e) => {
      const t = e.target;
      if (!isLeaf(t)) return;
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        navigateToEntry(t);
      } else if (e.key === 'Escape') {
        t.blur();
      }
    });
  }

  function wireMuteToggle() {
    const btn = document.getElementById('muteToggle');
    if (!btn) return;
    const reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduced) audio.setMuted(true);
    btn.classList.toggle('is-muted', audio.muted);
    btn.setAttribute('aria-pressed', audio.muted ? 'true' : 'false');
    btn.addEventListener('click', () => {
      audio.setMuted(!audio.muted);
      btn.classList.toggle('is-muted', audio.muted);
      btn.setAttribute('aria-pressed', audio.muted ? 'true' : 'false');
    });
  }

  // ----------------------------------------------------------------------
  // Boot
  // ----------------------------------------------------------------------
  async function init() {
    const cfg = (window.__arboryx && window.__arboryx.CONFIG)
      || (window.ARBORYX_CONFIG)
      || null;
    if (!cfg || !cfg.api || !cfg.api.url) return;

    const todayUTC = Date.UTC(
      new Date().getUTCFullYear(),
      new Date().getUTCMonth(),
      new Date().getUTCDate(),
    );

    const findings = await fetchRecentFindings(cfg);
    const sectorMap = pickEntriesForGrove(findings, cfg, todayUTC);

    const leafSizeMul = Number(cfg.grove.leafSize) || 1.0;
    document.querySelectorAll('.tree[data-sector]').forEach((tree) => {
      const sec = tree.getAttribute('data-sector');
      const entries = sectorMap.get(sec) || [];
      renderLeavesIntoTree(tree, entries, leafSizeMul);
    });

    const svg = document.querySelector('svg.grove-canvas');
    if (svg) wireInteractions(svg);
    wireMuteToggle();
  }

  // Run after landing.js has finished its DOMContentLoaded boot.  Both
  // scripts are deferred and execute in order, so by the time this runs
  // the DOM is parsed and window.__arboryx is set.  Wait for the document
  // ready signal anyway, defensively.
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => { init(); });
  } else {
    init();
  }

  // Expose for tests + Phase-5 hook.
  window.__grove = {
    init,
    LEAF_SLOTS,
    pickEntriesForGrove,
    daysOldFromTimestamp,
    audio,
  };
})();
