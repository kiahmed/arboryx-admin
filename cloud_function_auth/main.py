"""arboryx-auth — cross-subdomain SSO for the Arboryx family (Phase 2).

A tiny, dedicated public-user auth function. It mints an HttpOnly session
cookie scoped to the whole registrable domain (`Domain=.arboryx.ai`) so a user
signed in on `arboryx.ai` is auto-detected as signed in on
`robotics.arboryx.ai` (and vice-versa), with a global sign-out.

Exposed first-party via a Firebase Hosting rewrite: `/__session/**` on each
apex/subdomain forwards here (Cloud Run `run:` rewrite). Because the browser
hits `https://<host>.arboryx.ai/__session/...`, the Set-Cookie lands on the
`.arboryx.ai` origin and is shared across every subdomain.

HARD SEPARATION — this is NOT the admin API:
  • Different concern from cloud_function/ (arboryx-admin-api). This never
    touches the `admin_sessions` collection or Secret-Manager admin creds.
  • Public end-users only. Session state lives in a firebase-admin session
    cookie (a signed JWT) + the shared `users/{uid}` doc. No server-side
    session store, no admin_sessions.

Endpoints (path segment after `/__session/`, or `?action=`):
  POST  login   body {idToken}     → verify, mint session cookie (5d), upsert users/{uid}.lastSeenAt
  GET   me                          → verify cookie → {uid,email,displayName,photoURL,products} or 401
  POST  logout                      → clear cookie + revoke refresh tokens
  POST  link    body {product}      → cookie-authed grant: add product to users/{uid}.products (+ subdoc)

Security:
  • login is CSRF-proof: it requires the Firebase ID token in the JSON body
    (an attacker's cross-site form/fetch cannot read the victim's ID token).
  • logout/link are cookie-authed state changes, so they require an
    `X-Requested-With: XMLHttpRequest` header AND a credentialed CORS origin
    on the allowlist (blocks cross-site form posts; XHR/fetch header can't be
    forged cross-origin without a passing CORS preflight).
  • The client NEVER writes `entitlement` — tier/entitlement is backend-only.
  • Cache-Control: no-store on every response.

IAM / signing note:
  create_session_cookie() calls the Identity Toolkit REST API
  (`accounts:createSessionCookie`) using an OAuth2 access token from the
  runtime credential — it does NOT sign a JWT locally, so it needs
  roles/firebaseauth.admin (which market-agent-sa has) and does NOT require
  roles/iam.serviceAccountTokenCreator. That role is only needed if we ever
  mint CUSTOM tokens (create_custom_token → signBlob). We don't. If a future
  change adds custom tokens, grant:
    gcloud iam service-accounts add-iam-policy-binding \
      market-agent-sa@marketresearch-agents.iam.gserviceaccount.com \
      --member=serviceAccount:market-agent-sa@marketresearch-agents.iam.gserviceaccount.com \
      --role=roles/iam.serviceAccountTokenCreator
"""

import json
import os
import re
from datetime import date, datetime, timedelta

import firebase_admin
from firebase_admin import auth as fb_auth
from firebase_admin import firestore
from flask import Response

# ── Config ──────────────────────────────────────────────────────────────────
PROJECT_ID = os.environ.get("PROJECT_ID", "marketresearch-agents")
COOKIE_NAME = os.environ.get("SESSION_COOKIE_NAME", "__Secure-arboryx_session")
COOKIE_DOMAIN = os.environ.get("COOKIE_DOMAIN", ".arboryx.ai")
SESSION_TTL = timedelta(days=5)
SESSION_MAX_AGE = int(SESSION_TTL.total_seconds())  # 432000

# Product → tier map. tier is written to the members subdoc, NOT `entitlement`.
PRODUCT_TIERS = {
    "arboryx": 1,
    "robotics": 1,
}

# CORS allowlist: explicit apex/product origins + Firebase preview channels for
# the arboryx-ai site. NOT a blanket *.arboryx.ai wildcard (which would trust any
# subdomain, including a future dangling / takeover-able one).
_EXACT_ORIGINS = {
    "https://arboryx.ai",
    "https://www.arboryx.ai",
    "https://robotics.arboryx.ai",
    "https://arboryx-ai.web.app",
}
# Firebase Hosting preview channels are Firebase-namespaced under the arboryx-ai
# site, not attacker-registrable.
_PREVIEW_RE = re.compile(r"^https://arboryx-ai--[a-z0-9-]+\.web\.app$", re.IGNORECASE)

# ── Firebase Admin singleton (reused across warm invocations) ───────────────
_app = None
_db = None


def _init():
    global _app, _db
    if _app is None:
        # Application Default Credentials = the runtime service account
        # (market-agent-sa, roles/firebaseauth.admin).
        _app = firebase_admin.initialize_app(options={"projectId": PROJECT_ID})
        _db = firestore.client()
    return _db


# ── Helpers ─────────────────────────────────────────────────────────────────
def _allowed_origin(origin):
    if not origin:
        return None
    if origin in _EXACT_ORIGINS:
        return origin
    if _PREVIEW_RE.match(origin):
        return origin
    return None


def _base_headers(origin):
    """CORS + no-store headers shared by every response."""
    h = {
        "Cache-Control": "no-store",
        "Vary": "Origin",
    }
    allowed = _allowed_origin(origin)
    if allowed:
        h["Access-Control-Allow-Origin"] = allowed
        h["Access-Control-Allow-Credentials"] = "true"
        h["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        h["Access-Control-Allow-Headers"] = "Content-Type, X-Requested-With"
    return h


def _json_default(o):
    # Firestore returns DatetimeWithNanoseconds (a datetime subclass) for
    # timestamp fields; make them JSON-serializable.
    if isinstance(o, (datetime, date)):
        return o.isoformat()
    return str(o)


def _json(body, status, origin, extra_headers=None):
    resp = Response(
        json.dumps(body, default=_json_default),
        status=status,
        mimetype="application/json",
    )
    for k, v in _base_headers(origin).items():
        resp.headers[k] = v
    if extra_headers:
        for k, v in extra_headers:
            resp.headers.add(k, v)
    return resp


def _set_cookie_header(value, max_age):
    """Exact Set-Cookie string. __Secure- prefix REQUIRES Secure (and permits
    Domain — unlike __Host-, which forbids it, so __Host- can't be shared
    across subdomains). SameSite=Lax is fine: apex↔subdomain are the same
    registrable site, so these are same-site requests."""
    return (
        "{name}={val}; Domain={dom}; Path=/; Max-Age={age}; "
        "HttpOnly; Secure; SameSite=Lax"
    ).format(name=COOKIE_NAME, val=value, dom=COOKIE_DOMAIN, age=max_age)


def _require_xrw(request):
    return request.headers.get("X-Requested-With", "") == "XMLHttpRequest"


def _read_action(request):
    """Route on the trailing path segment (…/__session/<action>) or ?action=."""
    action = request.args.get("action")
    if not action:
        # path looks like /__session/login or /login depending on rewrite
        segs = [s for s in (request.path or "").split("/") if s]
        if segs:
            action = segs[-1]
    return (action or "").lower()


# ── Endpoint handlers ───────────────────────────────────────────────────────
def _login(request, origin, db):
    if request.method != "POST":
        return _json({"error": "method_not_allowed"}, 405, origin)
    data = request.get_json(silent=True) or {}
    id_token = data.get("idToken")
    if not id_token:
        return _json({"error": "missing_id_token"}, 400, origin)
    try:
        decoded = fb_auth.verify_id_token(id_token, check_revoked=True)
    except Exception as e:  # noqa: BLE001
        logging.warning("verify_id_token failed: %s", e)
        return _json({"error": "invalid_id_token"}, 401, origin)

    try:
        cookie = fb_auth.create_session_cookie(id_token, expires_in=SESSION_TTL)
    except Exception as e:  # noqa: BLE001
        # Most likely an IAM/token issue on the runtime SA — log, don't leak.
        logging.error("create_session_cookie failed: %s", e)
        return _json({"error": "session_cookie_failed"}, 500, origin)

    uid = decoded.get("uid")
    now = firestore.SERVER_TIMESTAMP
    try:
        db.collection("users").document(uid).set(
            {"uid": uid, "lastSeenAt": now}, merge=True
        )
    except Exception:  # noqa: BLE001 — cookie already minted; profile write is best-effort
        pass

    return _json(
        {"ok": True, "uid": uid},
        200,
        origin,
        extra_headers=[("Set-Cookie", _set_cookie_header(cookie, SESSION_MAX_AGE))],
    )


def _me(request, origin, db):
    cookie = request.cookies.get(COOKIE_NAME)
    if not cookie:
        return _json({"error": "no_session"}, 401, origin)
    try:
        decoded = fb_auth.verify_session_cookie(cookie, check_revoked=True)
    except Exception:  # noqa: BLE001 — expired/revoked/tampered
        return _json({"error": "invalid_session"}, 401, origin)

    uid = decoded.get("uid")
    products = {}
    try:
        snap = db.collection("users").document(uid).get()
        if snap.exists:
            products = (snap.to_dict() or {}).get("products", {}) or {}
    except Exception:  # noqa: BLE001
        products = {}

    return _json(
        {
            "uid": uid,
            "email": decoded.get("email"),
            "displayName": decoded.get("name"),
            "photoURL": decoded.get("picture"),
            "products": products,
        },
        200,
        origin,
    )


def _logout(request, origin, db):
    if request.method != "POST":
        return _json({"error": "method_not_allowed"}, 405, origin)
    if not _require_xrw(request):
        return _json({"error": "missing_xrw"}, 403, origin)

    cookie = request.cookies.get(COOKIE_NAME)
    if cookie:
        try:
            decoded = fb_auth.verify_session_cookie(cookie, check_revoked=False)
            fb_auth.revoke_refresh_tokens(decoded.get("uid"))
        except Exception:  # noqa: BLE001 — clear the cookie regardless
            pass

    # Clear by re-issuing with Max-Age=0 (same Domain/Path).
    return _json(
        {"ok": True},
        200,
        origin,
        extra_headers=[("Set-Cookie", _set_cookie_header("", 0))],
    )


def _link(request, origin, db):
    if request.method != "POST":
        return _json({"error": "method_not_allowed"}, 405, origin)
    if not _require_xrw(request):
        return _json({"error": "missing_xrw"}, 403, origin)

    cookie = request.cookies.get(COOKIE_NAME)
    if not cookie:
        return _json({"error": "no_session"}, 401, origin)
    try:
        decoded = fb_auth.verify_session_cookie(cookie, check_revoked=True)
    except Exception:  # noqa: BLE001
        return _json({"error": "invalid_session"}, 401, origin)

    data = request.get_json(silent=True) or {}
    product = (data.get("product") or "").lower()
    tier = PRODUCT_TIERS.get(product)
    if tier is None:
        return _json({"error": "unknown_product"}, 400, origin)

    uid = decoded.get("uid")
    now = firestore.SERVER_TIMESTAMP
    user_ref = db.collection("users").document(uid)
    product_ref = user_ref.collection("products").document(product)

    # Product summary on the user doc + members subdoc. NEVER `entitlement`.
    user_ref.set(
        {
            "uid": uid,
            "lastSeenAt": now,
            "products": {product: {"member": True, "access": True, "since": now}},
        },
        merge=True,
    )
    product_ref.set(
        {
            "productId": product,
            "tier": tier,
            "joinedAt": now,
            "joinedVia": "link",
            "lastSeenAt": now,
        },
        merge=True,
    )

    products = {}
    try:
        snap = user_ref.get()
        if snap.exists:
            products = (snap.to_dict() or {}).get("products", {}) or {}
    except Exception:  # noqa: BLE001
        products = {}

    return _json({"ok": True, "product": product, "products": products}, 200, origin)


# ── Entry point ─────────────────────────────────────────────────────────────
def auth_handler(request):
    origin = request.headers.get("Origin")

    # CORS preflight
    if request.method == "OPTIONS":
        resp = Response("", status=204)
        for k, v in _base_headers(origin).items():
            resp.headers[k] = v
        resp.headers["Access-Control-Max-Age"] = "3600"
        return resp

    action = _read_action(request)
    db = _init()

    if action == "login":
        return _login(request, origin, db)
    if action == "me":
        return _me(request, origin, db)
    if action == "logout":
        return _logout(request, origin, db)
    if action == "link":
        return _link(request, origin, db)

    return _json({"error": "not_found", "action": action}, 404, origin)
