// Arboryx public-user auth (Phase 1) — client-side Firebase Auth for the
// arboryx.ai apex landing page.
//
// Ported and adapted from the working robotics module
// (catalyst-knowledge-graph/frontend/assets/auth.js) on the SAME GCP project.
// Key differences from robotics:
//   • The landing page is NOT gated behind a hard sign-in wall. Auth is a
//     header slot: a "Sign in" trigger when logged out, an account/settings
//     button (email/avatar + Sign out) when logged in. The sign-in modal is
//     dismissable (close button + backdrop click).
//   • A soft deferred prompt still fires like robotics — the modal auto-opens
//     once after 60s OR 2 interactions — but is skipped entirely when the
//     visitor is already signed in (or has already dismissed it this visit).
//   • On sign-in it records tier-1 Arboryx membership:
//       users/{uid}                      → base profile + products.arboryx summary + createdVia
//       users/{uid}/products/arboryx     → { productId, tier:1, joinedAt, joinedVia, lastSeenAt }
//     The client NEVER writes an `entitlement` field (backend-only).
//
// Providers: Google popup + email/password (phone/SMS coded but off by
// default — enable by adding 'phone' handling as robotics does).
//
// Public API (window.ArboryxAuth):
//   init(config?)        — boot; config defaults to window.FIREBASE_CONFIG
//   openSignIn()         — open the sign-in modal
//   signOut()            — sign out
//   noteInteraction()    — feed the deferred-prompt counter (2 → prompt)
(function () {
  'use strict';

  var SDK_VERSION = '10.14.1';
  var SDK_BASE = 'https://www.gstatic.com/firebasejs/' + SDK_VERSION + '/';

  var PRODUCT_ID = 'arboryx';
  var PRODUCT_TIER = 1;

  // ── Phase 2: cross-subdomain SSO via a shared .arboryx.ai session cookie ──
  // The apex/subdomain each expose the arboryx-auth function first-party under
  // /__session/** (Firebase Hosting rewrite). We POST the Firebase ID token to
  // /__session/login to mint an HttpOnly Domain=.arboryx.ai cookie, and read
  // /__session/me on boot so a session established on robotics.arboryx.ai (or
  // vice-versa) is auto-detected here. All calls are credentialed.
  var SESSION_BASE = '/__session';
  var sessionMe = null;        // last successful /me payload, or null
  var renderedFromSession = false;  // chip rendered from cookie (no local Firebase user yet)

  // ── Deferred soft-prompt tuning ────────────────────────────────────
  var PROMPT_DELAY_MS = 60 * 1000;   // auto-open N ms after first paint…
  var PROMPT_INTERACTIONS = 2;       // …or on the Nth interaction, if sooner
  var PROMPT_KEY = 'arboryx.auth.prompted';  // localStorage: '1' once shown

  var SOCIAL = ['google'];  // add 'twitter'/'github' once their OAuth apps exist

  // ── SDK loading ────────────────────────────────────────────────────
  function loadScript(src) {
    return new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = src;
      s.onload = function () { resolve(); };
      s.onerror = function () { reject(new Error('failed to load ' + src)); };
      document.head.appendChild(s);
    });
  }

  function loadSdk() {
    if (window.firebase && firebase.auth && firebase.firestore) {
      return Promise.resolve();
    }
    return loadScript(SDK_BASE + 'firebase-app-compat.js').then(function () {
      return Promise.all([
        loadScript(SDK_BASE + 'firebase-auth-compat.js'),
        loadScript(SDK_BASE + 'firebase-firestore-compat.js'),
      ]);
    });
  }

  // ── Styles (dark theme, keyed off the site's CSS tokens) ───────────
  function injectStyles() {
    if (document.getElementById('aauth-styles')) return;
    var css = '' +
      '.aauth-scrim{position:fixed;inset:0;z-index:9999;display:flex;align-items:center;justify-content:center;padding:24px;background:rgba(0,0,0,0.62);backdrop-filter:blur(2px);font-family:var(--font-mono,ui-monospace,monospace);}' +
      '.aauth-scrim[hidden]{display:none;}' +
      '.aauth-card{position:relative;width:100%;max-width:384px;background:color-mix(in srgb,var(--bg,#222) 88%,#000);border:1px solid var(--border2,#243050);border-radius:var(--r-md,12px);box-shadow:0 12px 48px rgba(0,0,0,0.55);padding:30px 28px;color:var(--text,#c8d6f0);}' +
      '.aauth-close{position:absolute;top:12px;right:12px;width:28px;height:28px;display:flex;align-items:center;justify-content:center;background:transparent;border:1px solid transparent;border-radius:8px;color:var(--muted,#4a5e80);font-size:18px;line-height:1;cursor:pointer;}' +
      '.aauth-close:hover{border-color:var(--border2,#243050);color:var(--text,#c8d6f0);}' +
      '.aauth-brand{display:flex;align-items:center;gap:8px;font-size:12px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;color:var(--muted,#4a5e80);}' +
      '.aauth-logo{display:inline-flex;align-items:center;justify-content:center;width:22px;height:22px;border-radius:6px;background:var(--accent,#f0b840);color:#1a1a1a;font-size:12px;font-weight:700;}' +
      '.aauth-title{margin:20px 0 4px;font-family:var(--font-display,var(--font-mono,inherit));font-size:20px;font-weight:700;letter-spacing:-.01em;color:var(--text,#c8d6f0);}' +
      '.aauth-sub{margin:0 0 20px;font-size:12.5px;line-height:1.5;color:var(--muted,#4a5e80);}' +
      '.aauth-providers{display:flex;flex-direction:column;gap:9px;}' +
      '.aauth-provider{display:flex;align-items:center;justify-content:center;gap:10px;width:100%;padding:10px 14px;background:color-mix(in srgb,var(--bg,#222) 70%,#fff 6%);border:1px solid var(--border2,#243050);border-radius:10px;font:inherit;font-size:13px;font-weight:500;color:var(--text,#c8d6f0);cursor:pointer;transition:border-color .12s,background .12s,transform .04s;}' +
      '.aauth-provider:hover{border-color:var(--accent,#f0b840);}' +
      '.aauth-provider:active{transform:scale(.992);}' +
      '.aauth-provider svg{width:17px;height:17px;flex:none;}' +
      '.aauth-divider{display:flex;align-items:center;gap:12px;margin:16px 0;color:var(--muted,#4a5e80);font-size:10.5px;text-transform:uppercase;letter-spacing:.1em;}' +
      '.aauth-divider::before,.aauth-divider::after{content:"";flex:1;height:1px;background:var(--border2,#243050);}' +
      '.aauth-form{display:flex;flex-direction:column;gap:9px;}' +
      '.aauth-form input{width:100%;padding:10px 13px;background:color-mix(in srgb,var(--bg,#222) 80%,#000);border:1px solid var(--border2,#243050);border-radius:10px;font:inherit;font-size:13px;color:var(--text,#c8d6f0);}' +
      '.aauth-form input::placeholder{color:var(--muted,#4a5e80);}' +
      '.aauth-form input:focus{outline:none;border-color:var(--accent,#f0b840);box-shadow:0 0 0 3px color-mix(in srgb,var(--accent,#f0b840) 22%,transparent);}' +
      '.aauth-submit{margin-top:3px;padding:11px 14px;background:var(--accent,#f0b840);color:#1a1a1a;border:none;border-radius:10px;font:inherit;font-size:13px;font-weight:700;cursor:pointer;transition:filter .12s,transform .04s;}' +
      '.aauth-submit:hover{filter:brightness(1.06);}' +
      '.aauth-submit:active{transform:scale(.992);}' +
      '.aauth-provider:disabled,.aauth-submit:disabled{opacity:.6;cursor:progress;}' +
      '.aauth-msg{min-height:16px;margin-top:12px;font-size:12px;line-height:1.4;}' +
      '.aauth-msg.error{color:#ff6b6b;}' +
      '.aauth-msg.info{color:var(--muted,#4a5e80);}' +
      '.aauth-links{display:flex;justify-content:space-between;gap:12px;margin-top:14px;}' +
      '.aauth-link{background:none;border:none;padding:0;font:inherit;font-size:12px;color:var(--accent3,#5b9cf6);cursor:pointer;}' +
      '.aauth-link:hover{text-decoration:underline;}' +
      '.aauth-link[hidden]{display:none;}' +
      /* header slot buttons */
      '.aauth-trigger{font-family:var(--font-mono,monospace);font-size:10.5px;font-weight:600;color:#1a1a1a;background:var(--accent,#f0b840);border:1px solid var(--accent,#f0b840);border-radius:var(--r-sm,7px);padding:6px 13px;letter-spacing:.05em;text-transform:uppercase;cursor:pointer;transition:filter .12s;}' +
      '.aauth-trigger:hover{filter:brightness(1.06);}' +
      '.aauth-account{display:flex;align-items:center;gap:8px;font-family:var(--font-mono,monospace);font-size:10.5px;color:var(--text,#c8d6f0);background:transparent;border:1px solid var(--border2,#243050);border-radius:var(--r-sm,7px);padding:4px 6px 4px 10px;letter-spacing:.03em;cursor:pointer;}' +
      '.aauth-account:hover{border-color:var(--accent,#f0b840);}' +
      '.aauth-account .aauth-avatar{width:22px;height:22px;border-radius:50%;background:var(--accent,#f0b840);color:#1a1a1a;display:inline-flex;align-items:center;justify-content:center;font-size:11px;font-weight:700;overflow:hidden;}' +
      '.aauth-account .aauth-avatar img{width:100%;height:100%;object-fit:cover;}' +
      '.aauth-menu{position:absolute;top:calc(100% + 6px);right:0;min-width:200px;background:color-mix(in srgb,var(--bg,#222) 90%,#000);border:1px solid var(--border2,#243050);border-radius:10px;box-shadow:0 8px 28px rgba(0,0,0,0.5);padding:10px;z-index:400;}' +
      '.aauth-menu[hidden]{display:none;}' +
      '.aauth-menu .aauth-email{font-family:var(--font-mono,monospace);font-size:11px;color:var(--muted,#4a5e80);padding:4px 6px 10px;border-bottom:1px solid var(--border2,#243050);margin-bottom:8px;word-break:break-all;}' +
      '.aauth-signout{width:100%;padding:8px 10px;background:transparent;border:1px solid var(--border2,#243050);border-radius:8px;font-family:var(--font-mono,monospace);font-size:11px;color:var(--text,#c8d6f0);cursor:pointer;text-transform:uppercase;letter-spacing:.05em;}' +
      '.aauth-signout:hover{border-color:var(--accent,#f0b840);color:var(--accent,#f0b840);}' +
      '.aauth-link-cta{width:100%;margin-bottom:8px;padding:8px 10px;background:var(--accent,#f0b840);color:#1a1a1a;border:none;border-radius:8px;font-family:var(--font-mono,monospace);font-size:11px;font-weight:700;cursor:pointer;letter-spacing:.03em;}' +
      '.aauth-link-cta:hover{filter:brightness(1.06);}' +
      '.aauth-link-cta:disabled{opacity:.6;cursor:progress;}' +
      '.aauth-slot{position:relative;display:inline-flex;align-items:center;}';
    var style = document.createElement('style');
    style.id = 'aauth-styles';
    style.textContent = css;
    document.head.appendChild(style);
  }

  // ── Provider icons + labels ────────────────────────────────────────
  var ICONS = {
    google:
      '<svg viewBox="0 0 18 18"><path fill="#4285F4" d="M17.64 9.2c0-.64-.06-1.25-.16-1.84H9v3.48h4.84a4.14 4.14 0 0 1-1.8 2.72v2.26h2.92c1.7-1.57 2.68-3.88 2.68-6.62z"/><path fill="#34A853" d="M9 18c2.43 0 4.47-.8 5.96-2.18l-2.92-2.26c-.8.54-1.84.86-3.04.86-2.34 0-4.32-1.58-5.03-3.7H.96v2.34A9 9 0 0 0 9 18z"/><path fill="#FBBC05" d="M3.97 10.72A5.4 5.4 0 0 1 3.68 9c0-.6.1-1.18.29-1.72V4.94H.96A9 9 0 0 0 0 9c0 1.45.35 2.83.96 4.06l3.01-2.34z"/><path fill="#EA4335" d="M9 3.58c1.32 0 2.5.45 3.44 1.35l2.58-2.58A9 9 0 0 0 .96 4.94l3.01 2.34C4.68 5.16 6.66 3.58 9 3.58z"/></svg>',
  };
  var LABELS = { google: 'Google' };

  // ── Modal markup ───────────────────────────────────────────────────
  function modalHTML() {
    var social = '';
    SOCIAL.forEach(function (id) {
      social +=
        '<button type="button" class="aauth-provider" data-provider="' + id + '">' +
        ICONS[id] + '<span>Continue with ' + LABELS[id] + '</span></button>';
    });
    return '' +
      '<div class="aauth-card" role="dialog" aria-modal="true" aria-label="Sign in to Arboryx">' +
        '<button type="button" class="aauth-close" id="aauthClose" aria-label="Close">×</button>' +
        '<div class="aauth-brand"><span class="aauth-logo">A</span><span>Arboryx</span></div>' +
        '<h1 class="aauth-title" id="aauthTitle">Sign in to Arboryx</h1>' +
        '<p class="aauth-sub">Save your grove, follow sectors, and unlock member features.</p>' +
        '<div class="aauth-providers">' + social + '</div>' +
        '<div class="aauth-divider"><span>or</span></div>' +
        '<form class="aauth-form" id="aauthForm" novalidate>' +
          '<input type="email" id="aauthEmail" placeholder="Email" autocomplete="email">' +
          '<input type="password" id="aauthPassword" placeholder="Password" autocomplete="current-password">' +
          '<button type="submit" class="aauth-submit" id="aauthSubmit">Sign in</button>' +
        '</form>' +
        '<div class="aauth-msg" id="aauthMsg" role="status"></div>' +
        '<div class="aauth-links">' +
          '<button type="button" class="aauth-link" id="aauthForgot">Forgot password?</button>' +
          '<button type="button" class="aauth-link" id="aauthToggle">Create an account</button>' +
        '</div>' +
      '</div>';
  }

  // ── Error mapping ──────────────────────────────────────────────────
  function friendlyError(e) {
    var map = {
      'auth/invalid-email': 'That email address looks invalid.',
      'auth/user-not-found': 'No account with that email — create one below.',
      'auth/wrong-password': 'Incorrect password.',
      'auth/invalid-credential': 'Incorrect email or password.',
      'auth/email-already-in-use': 'An account with that email already exists — sign in instead.',
      'auth/weak-password': 'Password must be at least 6 characters.',
      'auth/popup-closed-by-user': 'Sign-in window closed before finishing.',
      'auth/cancelled-popup-request': 'Sign-in already in progress.',
      'auth/popup-blocked': 'Your browser blocked the sign-in popup — allow popups and retry.',
      'auth/account-exists-with-different-credential':
        'That account is already registered with a different sign-in method.',
      'auth/operation-not-allowed': 'That sign-in method is not enabled yet.',
      'auth/unauthorized-domain': 'This domain is not authorized for sign-in yet.',
      'auth/network-request-failed': 'Network error — check your connection.',
      'auth/too-many-requests': 'Too many attempts — wait a minute and retry.',
    };
    return (e && map[e.code]) || (e && e.message) || 'Sign-in failed. Please try again.';
  }

  // ── State ──────────────────────────────────────────────────────────
  var els = {};
  var slot = null;
  var mode = 'signin';        // 'signin' | 'signup'
  var currentUser = null;
  var authKnown = false;
  var booted = false;
  var promptShown = false;
  var interactions = 0;
  var promptTimer = null;

  function showMsg(text, kind) {
    if (!els.msg) return;
    els.msg.textContent = text || '';
    els.msg.className = 'aauth-msg' + (text ? ' ' + (kind || 'info') : '');
  }
  function setBusy(busy) {
    if (!els.card) return;
    var btns = els.card.querySelectorAll('button');
    for (var i = 0; i < btns.length; i++) btns[i].disabled = busy;
  }

  function applyMode() {
    els.submit.textContent = (mode === 'signup') ? 'Create account' : 'Sign in';
    els.toggle.textContent = (mode === 'signup') ? 'Have an account? Sign in' : 'Create an account';
    els.title.textContent = (mode === 'signup') ? 'Create your Arboryx account' : 'Sign in to Arboryx';
    els.forgot.hidden = (mode === 'signup');
    els.password.setAttribute('autocomplete', mode === 'signup' ? 'new-password' : 'current-password');
    showMsg('', '');
  }
  function setMode(m) { mode = m; applyMode(); }

  // ── Sign-in flows ──────────────────────────────────────────────────
  function providerFor(id) {
    if (id === 'google') return new firebase.auth.GoogleAuthProvider();
    return null;
  }
  function signInWithProvider(id) {
    var p = providerFor(id);
    if (!p) return;
    setBusy(true); showMsg('', '');
    firebase.auth().signInWithPopup(p)
      .catch(function (e) { showMsg(friendlyError(e), 'error'); })
      .then(function () { setBusy(false); });
  }
  function submitEmail() {
    var email = els.email.value.trim();
    var pw = els.password.value;
    if (!email || !pw) { showMsg('Enter your email and password.', 'error'); return; }
    setBusy(true); showMsg('', '');
    var auth = firebase.auth();
    var op = (mode === 'signup')
      ? auth.createUserWithEmailAndPassword(email, pw)
      : auth.signInWithEmailAndPassword(email, pw);
    op.catch(function (e) { showMsg(friendlyError(e), 'error'); })
      .then(function () { setBusy(false); });
  }
  function forgotPassword() {
    var email = els.email.value.trim();
    if (!email) { showMsg('Enter your email above, then click “Forgot password?”.', 'info'); return; }
    setBusy(true);
    firebase.auth().sendPasswordResetEmail(email)
      .then(function () { showMsg('Password reset email sent to ' + email + '.', 'info'); })
      .catch(function (e) { showMsg(friendlyError(e), 'error'); })
      .then(function () { setBusy(false); });
  }
  function onSubmit(ev) { ev.preventDefault(); submitEmail(); }

  // ── Modal open/close ───────────────────────────────────────────────
  function buildModal() {
    if (els.scrim) return;
    var scrim = document.createElement('div');
    scrim.className = 'aauth-scrim';
    scrim.id = 'aauthScrim';
    scrim.hidden = true;
    scrim.innerHTML = modalHTML();
    document.body.appendChild(scrim);

    els.scrim = scrim;
    els.card = scrim.querySelector('.aauth-card');
    els.msg = scrim.querySelector('#aauthMsg');
    els.email = scrim.querySelector('#aauthEmail');
    els.password = scrim.querySelector('#aauthPassword');
    els.submit = scrim.querySelector('#aauthSubmit');
    els.toggle = scrim.querySelector('#aauthToggle');
    els.forgot = scrim.querySelector('#aauthForgot');
    els.title = scrim.querySelector('#aauthTitle');

    var provBtns = scrim.querySelectorAll('.aauth-provider');
    for (var i = 0; i < provBtns.length; i++) {
      (function (btn) {
        btn.addEventListener('click', function () {
          signInWithProvider(btn.getAttribute('data-provider'));
        });
      })(provBtns[i]);
    }
    scrim.querySelector('#aauthForm').addEventListener('submit', onSubmit);
    els.toggle.addEventListener('click', function () {
      setMode(mode === 'signin' ? 'signup' : 'signin');
    });
    els.forgot.addEventListener('click', forgotPassword);
    scrim.querySelector('#aauthClose').addEventListener('click', closeModal);
    scrim.addEventListener('click', function (ev) {
      if (ev.target === scrim) closeModal();  // backdrop click
    });
    document.addEventListener('keydown', function (ev) {
      if (ev.key === 'Escape' && els.scrim && !els.scrim.hidden) closeModal();
    });
    setMode('signin');
  }
  function openModal() {
    if (currentUser) return;         // already signed in — nothing to do
    buildModal();
    els.scrim.hidden = false;
    if (els.email) { try { els.email.focus(); } catch (_) {} }
  }
  function closeModal() { if (els.scrim) els.scrim.hidden = true; }

  // ── Header slot rendering ──────────────────────────────────────────
  function findSlot() {
    if (slot && document.body.contains(slot)) return slot;
    slot = document.getElementById('arboryxAuthSlot');
    // Ensure the slot is a positioning context so the account dropdown anchors
    // to it (the page markup uses class "auth-slot"; the CSS keys off
    // "aauth-slot" — add it here so we don't depend on the HTML class).
    if (slot) slot.classList.add('aauth-slot');
    return slot;
  }
  function initial(user) {
    var s = user.displayName || user.email || 'A';
    return s.trim().charAt(0).toUpperCase();
  }
  function renderSignedOut() {
    var s = findSlot();
    if (!s) return;
    s.innerHTML =
      '<button type="button" class="aauth-trigger" id="aauthSignIn">Sign in</button>';
    var b = s.querySelector('#aauthSignIn');
    if (b) b.addEventListener('click', openModal);
  }
  function renderSignedIn(user, opts) {
    var s = findSlot();
    if (!s) return;
    opts = opts || {};
    // Only render a photoURL that is a real https URL, and escape it — never
    // interpolate raw user-controlled data into an innerHTML attribute (XSS).
    var safePhoto = (user.photoURL && /^https:\/\//i.test(user.photoURL)) ? escapeHtml(user.photoURL) : '';
    var avatar = safePhoto
      ? '<span class="aauth-avatar"><img src="' + safePhoto + '" alt=""></span>'
      : '<span class="aauth-avatar">' + initial(user) + '</span>';
    var label = user.displayName || user.email || user.phoneNumber || 'Account';
    // Phase 2: if the visitor arrived with a shared .arboryx.ai session but is
    // not yet a member of THIS product, offer a one-click "continue with your
    // existing profile" grant (→ /__session/link).
    var linkCta = opts.showLink
      ? '<button type="button" class="aauth-link-cta" id="aauthLinkProfile">Continue with your existing profile</button>'
      : '';
    s.innerHTML =
      '<button type="button" class="aauth-account" id="aauthAccount" aria-haspopup="true" aria-expanded="false">' +
        avatar + '<span class="aauth-account-label">' + escapeHtml(label) + '</span>' +
      '</button>' +
      '<div class="aauth-menu" id="aauthMenu" hidden>' +
        '<div class="aauth-email">' + escapeHtml(user.email || user.phoneNumber || '') + '</div>' +
        linkCta +
        '<button type="button" class="aauth-signout" id="aauthSignOut">Sign out</button>' +
      '</div>';
    var acct = s.querySelector('#aauthAccount');
    var menu = s.querySelector('#aauthMenu');
    acct.addEventListener('click', function (ev) {
      ev.stopPropagation();
      menu.hidden = !menu.hidden;
      acct.setAttribute('aria-expanded', String(!menu.hidden));
    });
    document.addEventListener('click', function () { if (menu) menu.hidden = true; });
    var linkBtn = s.querySelector('#aauthLinkProfile');
    if (linkBtn) {
      linkBtn.addEventListener('click', function (ev) {
        ev.stopPropagation();
        linkBtn.disabled = true;
        linkProduct(PRODUCT_ID).then(function (ok) {
          if (ok) { linkBtn.remove(); }
          else { linkBtn.disabled = false; }
        });
      });
    }
    s.querySelector('#aauthSignOut').addEventListener('click', function () {
      globalSignOut();
    });
  }
  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  // ── users/{uid} profile + tier-1 membership upsert ─────────────────
  function upsertProfileAndMembership(user) {
    var db = firebase.firestore();
    var now = firebase.firestore.FieldValue.serverTimestamp();
    var userRef = db.collection('users').doc(user.uid);
    var productRef = userRef.collection('products').doc(PRODUCT_ID);
    var providerId =
      (user.providerData && user.providerData[0] && user.providerData[0].providerId) || 'password';

    return userRef.get().catch(function () { return null; }).then(function (snap) {
      var isNew = !snap || !snap.exists;
      var hasProduct = snap && snap.exists && snap.data() &&
        snap.data().products && snap.data().products[PRODUCT_ID];

      // 1) Base profile + product summary on the user doc (never `entitlement`).
      var userData = {
        uid: user.uid,
        email: user.email || null,
        phoneNumber: user.phoneNumber || null,
        displayName: user.displayName || null,
        photoURL: user.photoURL || null,
        provider: providerId,
        lastSeenAt: now,
        products: {},
      };
      userData.products[PRODUCT_ID] = { member: true, access: true, since: now };
      if (isNew) {
        userData.createdAt = now;
        userData.createdVia = PRODUCT_ID;
      }

      // 2) Tier-1 membership subdoc (never `entitlement`).
      var productData = {
        productId: PRODUCT_ID,
        tier: PRODUCT_TIER,
        lastSeenAt: now,
        joinedVia: 'signup',
      };
      if (!hasProduct) productData.joinedAt = now;

      return Promise.all([
        userRef.set(userData, { merge: true }),
        productRef.set(productData, { merge: true }),
      ]);
    });
  }

  // ── Deferred soft-prompt ───────────────────────────────────────────
  function alreadyPrompted() {
    try { return localStorage.getItem(PROMPT_KEY) === '1'; } catch (_) { return false; }
  }
  function markPrompted() {
    try { localStorage.setItem(PROMPT_KEY, '1'); } catch (_) {}
  }
  function maybePrompt() {
    if (promptShown) return;
    if (currentUser) return;                 // signed in — never prompt
    if (!authKnown) return;                  // wait until auth state is known
    if (alreadyPrompted()) { promptShown = true; return; }
    promptShown = true;
    markPrompted();
    openModal();
  }
  function armPromptTimer() {
    if (promptTimer !== null || promptShown) return;
    promptTimer = setTimeout(function () { promptTimer = null; maybePrompt(); }, PROMPT_DELAY_MS);
  }
  function noteInteraction() {
    if (promptShown || currentUser) return;
    interactions += 1;
    if (interactions >= PROMPT_INTERACTIONS) maybePrompt();
  }

  // ── Phase 2: shared-session (.arboryx.ai cookie) helpers ───────────
  function sessionFetch(path, opts) {
    opts = opts || {};
    opts.credentials = 'include';   // send/receive the .arboryx.ai cookie
    return fetch(SESSION_BASE + path, opts);
  }
  function isMember(products) {
    return !!(products && products[PRODUCT_ID]);
  }
  // Mint the shared cookie from a signed-in Firebase user's ID token.
  function postLogin(user) {
    return user.getIdToken().then(function (idToken) {
      return sessionFetch('/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
        body: JSON.stringify({ idToken: idToken }),
      });
    }).catch(function (e) {
      console.warn('[ArboryxAuth] session login failed:', e);
    });
  }
  // Read the shared session (200 → payload; 401/err → null).
  function fetchMe() {
    return sessionFetch('/me', {
      headers: { 'X-Requested-With': 'XMLHttpRequest' },
    }).then(function (r) {
      return r.ok ? r.json() : null;
    }).catch(function () { return null; });
  }
  // Grant THIS product to the existing shared profile.
  function linkProduct(productId) {
    return sessionFetch('/link', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
      body: JSON.stringify({ product: productId }),
    }).then(function (r) {
      if (!r.ok) return false;
      return r.json().then(function (data) {
        if (sessionMe) sessionMe.products = data.products || sessionMe.products;
        return true;
      });
    }).catch(function () { return false; });
  }
  // Global sign-out: clear the shared cookie + revoke, THEN drop local Firebase.
  function globalSignOut() {
    sessionMe = null;
    renderedFromSession = false;
    sessionFetch('/logout', {
      method: 'POST',
      headers: { 'X-Requested-With': 'XMLHttpRequest' },
    }).catch(function () {}).then(function () {
      if (window.firebase && firebase.auth && firebase.auth().currentUser) {
        firebase.auth().signOut().catch(function () {});
      } else {
        renderSignedOut();
      }
    });
  }
  // Boot-time cross-product detection: render the account chip from the shared
  // cookie before Firebase resolves, so a session from another subdomain shows
  // immediately. onAuthStateChanged remains authoritative and reconciles.
  function bootSessionCheck() {
    return fetchMe().then(function (me) {
      sessionMe = me;
      if (!me) return;
      if (currentUser) return;          // Firebase already rendered — defer to it
      renderedFromSession = true;
      renderSignedIn(me, { showLink: !isMember(me.products) });
    });
  }
  // Re-check on tab focus so a sign-out on another subdomain propagates here.
  function recheckSession() {
    if (!currentUser && !renderedFromSession) return;   // nothing to lose
    fetchMe().then(function (me) {
      if (me) { sessionMe = me; return; }
      // Cookie gone/revoked elsewhere → drop to signed-out (and local Firebase).
      sessionMe = null;
      renderedFromSession = false;
      if (window.firebase && firebase.auth && firebase.auth().currentUser) {
        firebase.auth().signOut().catch(function () {});
      } else {
        renderSignedOut();
      }
    });
  }

  // ── Boot ───────────────────────────────────────────────────────────
  function init(config) {
    if (booted) return;
    booted = true;
    var cfg = config || window.FIREBASE_CONFIG;
    if (!cfg || !cfg.apiKey) {
      console.warn('[ArboryxAuth] no FIREBASE_CONFIG — auth disabled.');
      return;
    }
    injectStyles();
    renderSignedOut();               // show the trigger immediately
    armPromptTimer();                // clock starts at first paint

    // Phase 2: detect a shared .arboryx.ai session (e.g. signed in on
    // robotics.arboryx.ai) before Firebase resolves, and render the chip.
    bootSessionCheck();

    // Propagate cross-subdomain sign-out into an open tab.
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'visible') recheckSession();
    });
    window.addEventListener('focus', recheckSession);

    // Light, non-invasive interaction signal: clicks on grove trees.
    document.addEventListener('click', function (ev) {
      if (ev.target && ev.target.closest && ev.target.closest('[data-sector]')) {
        noteInteraction();
      }
    }, true);

    loadSdk().then(function () {
      if (!firebase.apps.length) {
        firebase.initializeApp({
          apiKey: cfg.apiKey,
          authDomain: cfg.authDomain,
          projectId: cfg.projectId,
          appId: cfg.appId,
        });
      }
      firebase.auth().onAuthStateChanged(function (user) {
        currentUser = user;
        authKnown = true;
        if (user) {
          closeModal();
          renderedFromSession = false;
          renderSignedIn(user);
          upsertProfileAndMembership(user).catch(function (e) {
            console.warn('[ArboryxAuth] profile/membership upsert failed:', e);
          });
          // Phase 2: mint / refresh the shared .arboryx.ai cookie, then
          // re-sync membership state from /me (drives the link CTA).
          postLogin(user).then(function () {
            return fetchMe();
          }).then(function (me) {
            if (me) sessionMe = me;
          });
        } else if (sessionMe) {
          // No local Firebase user, but a shared cookie exists (signed in on
          // another subdomain). Keep the session chip — don't drop to signed-out.
          renderedFromSession = true;
          renderSignedIn(sessionMe, { showLink: !isMember(sessionMe.products) });
        } else {
          renderedFromSession = false;
          renderSignedOut();
        }
      });
    }).catch(function (e) {
      console.error('[ArboryxAuth] SDK init failed:', e);
    });
  }

  window.ArboryxAuth = {
    init: init,
    openSignIn: openModal,
    signOut: globalSignOut,
    noteInteraction: noteInteraction,
  };

  // Auto-init after config scripts have run.
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { init(); });
  } else {
    init();
  }
})();
