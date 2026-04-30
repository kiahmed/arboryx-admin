"""Cloud Function (2nd gen, HTTP) — API backend for Arboryx Admin.

Reads market findings from GCS and serves them as JSON.
Includes API key authentication, in-memory caching, pagination,
and production logging.

Authentication:
    All endpoints except OPTIONS preflight and ?action=health require
    a valid API key. Send via:
        X-API-Key: <key>
        Authorization: Bearer <key>
    Two key tiers:
        API_KEY / API_KEYS         -> write-enabled (admin). Pass everywhere.
        READ_ONLY_API_KEYS         -> public read-only. Rejected with 403
                                      on update/delete/refresh.

Endpoints (via ?action= query param):
    GET  ?action=findings                  -> all findings (optionally filtered)
    GET  ?action=findings&category=X       -> findings for one sector
    GET  ?action=findings&days=N           -> findings from the last N days
    GET  ?action=findings&date=YYYY-MM-DD  -> findings from an exact date
    GET  ?action=findings&sort=asc|desc    -> sort order (default: desc)
    GET  ?action=findings&limit=N&offset=M -> pagination
    GET  ?action=entry&id=<entry_id>       -> single entry by entry_id
    GET  ?action=categories                -> list of available categories
    GET  ?action=stats                     -> total findings, category breakdown, date range
    GET  ?action=stats&days=N              -> same shape, filtered to the last N days
    GET  ?action=health                    -> health check (no auth required)
    GET  ?action=cache_status              -> cache hit count, last refresh, TTL, entry count
    GET  ?action=refresh                   -> force cache invalidation and reload (write key only)
    POST ?action=update                    -> update an entry by entry_id (JSON body, write key only)
    POST ?action=delete                    -> delete an entry by entry_id (JSON body, write key only)

Response shape:
    Every finding entry served by /findings, /entry, and /update carries
    a `tooltip` field — the short label shown on grove leaves. Falls back
    to a 30-char truncation of `finding` if the stored tooltip is empty.

Query parameter validation:
    days, limit, offset  -> must be positive integers
    date                 -> must be YYYY-MM-DD format
    sort                 -> must be 'asc' or 'desc'
    Invalid values return 400 with a descriptive error message.
"""

import os
import re
import gzip
import json
import time
import logging
import contextvars
from datetime import datetime, timedelta, timezone
from google.cloud import storage

# Per-request resolved CORS origin (set once at the top of the entry-point;
# read inside _cors_response without threading it through every call site).
_request_origin: contextvars.ContextVar = contextvars.ContextVar("request_origin", default="")
# Per-request gzip preference, mirrored from Accept-Encoding. Same plumbing
# pattern as _request_origin so _cors_response stays signature-stable.
_request_accepts_gzip: contextvars.ContextVar = contextvars.ContextVar("request_accepts_gzip", default=False)

# Secret Manager is the source of truth for API keys (Track A Phase 1).
# Import is wrapped so the function still cold-starts in environments
# where the package isn't installed (e.g. unit tests); falls back to
# env-var keys in that case.
try:
    from google.cloud import secretmanager
    _SECRETMANAGER_AVAILABLE = True
except ImportError:  # pragma: no cover
    secretmanager = None
    _SECRETMANAGER_AVAILABLE = False

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PROJECT_ID = os.environ.get("PROJECT_ID", "marketresearch-agents")
BUCKET_NAME = os.environ.get("STORAGE_BUCKET", "marketresearch-agents")
DATA_BLOB = os.environ.get("DATA_BLOB", "market_findings_log.json")
CACHE_TTL_SECONDS = int(os.environ.get("CACHE_TTL_SECONDS", "300"))

# Track B Phase 2.1 PR 2 — read backend selector.
#   "gcs"        -> read from gs://<bucket>/<DATA_BLOB> (legacy default)
#   "firestore"  -> read from the `findings` collection in Firestore
# Writes (action=update/delete) ALWAYS go to GCS — Firestore stays a
# read-optimized mirror that's refreshed via dev-utils/sync_gcs_to_firestore.py.
# Flip-and-rollback: change this env var and redeploy; no data migration.
FINDINGS_BACKEND = os.environ.get("FINDINGS_BACKEND", "gcs").strip().lower()
FINDINGS_COLLECTION = os.environ.get("FINDINGS_COLLECTION", "findings")

# Auth — write keys (admin) and read-only keys (public landing).
#
# Keys are now stored in Secret Manager as two secrets:
#   arboryx-admin-key   -> write-enabled (admin). Pass everywhere.
#   arboryx-public-key  -> read-only. Rejected with 403 on writes.
# Each secret may carry MULTIPLE ENABLED versions during a rotation
# soak window; all enabled versions are accepted simultaneously.
#
# Env-var keys (API_KEY / API_KEYS / READ_ONLY_API_KEYS) are still read
# as a fallback so:
#   1. local unit tests can run without GCP credentials
#   2. emergency rollback can bypass Secret Manager via env override
# Override env vars take precedence (union with secret-sourced keys).
ADMIN_SECRET_NAME = os.environ.get("ADMIN_SECRET_NAME", "arboryx-admin-key")
PUBLIC_SECRET_NAME = os.environ.get("PUBLIC_SECRET_NAME", "arboryx-public-key")

_API_KEY = os.environ.get("API_KEY", "")
_API_KEYS_RAW = os.environ.get("API_KEYS", "")
_READ_ONLY_API_KEYS_RAW = os.environ.get("READ_ONLY_API_KEYS", "")
_WRITE_KEYS: set = set()
_READ_ONLY_KEYS: set = set()
_VALID_KEYS: set = set()

_secret_client = None


def _get_secret_client():
    """Singleton SecretManagerServiceClient; None if package unavailable."""
    global _secret_client
    if not _SECRETMANAGER_AVAILABLE:
        return None
    if _secret_client is None:
        try:
            _secret_client = secretmanager.SecretManagerServiceClient()
        except Exception as exc:  # auth failure, etc. — log and degrade
            logging.warning("Secret Manager client init failed: %s", exc)
            return None
    return _secret_client


def _fetch_enabled_versions(secret_id: str) -> set:
    """Return the set of payload values for every ENABLED version of `secret_id`.

    Returns empty set on any error (auth, missing secret, no enabled versions);
    the calling code must tolerate this and fall back to env-var keys.
    """
    client = _get_secret_client()
    if client is None:
        return set()
    parent = f"projects/{PROJECT_ID}/secrets/{secret_id}"
    keys: set = set()
    try:
        for ver in client.list_secret_versions(
            request={"parent": parent, "filter": "state:ENABLED"}
        ):
            try:
                payload = client.access_secret_version(request={"name": ver.name})
                val = payload.payload.data.decode("utf-8").strip()
                if val:
                    keys.add(val)
            except Exception as exc:
                logging.warning("Failed to read %s: %s", ver.name, exc)
    except Exception as exc:
        logging.warning("Failed to list versions of %s: %s", secret_id, exc)
    return keys


def _build_valid_keys():
    """Build write/read key sets from Secret Manager (primary) + env vars (fallback)."""
    global _WRITE_KEYS, _READ_ONLY_KEYS, _VALID_KEYS

    # Primary source: Secret Manager (all ENABLED versions of each secret).
    write = _fetch_enabled_versions(ADMIN_SECRET_NAME)
    readonly = _fetch_enabled_versions(PUBLIC_SECRET_NAME)

    # Fallback / override: env vars (kept for local tests + emergency rollback).
    if _API_KEY:
        write.add(_API_KEY.strip())
    if _API_KEYS_RAW:
        for k in _API_KEYS_RAW.split(","):
            k = k.strip()
            if k:
                write.add(k)
    if _READ_ONLY_API_KEYS_RAW:
        for k in _READ_ONLY_API_KEYS_RAW.split(","):
            k = k.strip()
            if k:
                readonly.add(k)

    _WRITE_KEYS = write
    _READ_ONLY_KEYS = readonly
    _VALID_KEYS = _WRITE_KEYS | _READ_ONLY_KEYS

    logging.info(
        "API keys loaded: %d write (admin), %d read-only (public)",
        len(_WRITE_KEYS), len(_READ_ONLY_KEYS),
    )


_build_valid_keys()

# ---------------------------------------------------------------------------
# GCS client singleton
# ---------------------------------------------------------------------------
_gcs_client = None


def _get_client():
    global _gcs_client
    if _gcs_client is None:
        _gcs_client = storage.Client(project=PROJECT_ID)
    return _gcs_client


# ---------------------------------------------------------------------------
# Firestore client singleton (lazy — only paid for when FINDINGS_BACKEND=firestore)
# ---------------------------------------------------------------------------
_firestore_client = None


def _get_firestore_client():
    global _firestore_client
    if _firestore_client is None:
        from google.cloud import firestore  # local import — keeps GCS path import-light
        _firestore_client = firestore.Client(project=PROJECT_ID)
    return _firestore_client


# ---------------------------------------------------------------------------
# In-memory cache
# ---------------------------------------------------------------------------
_cache = {
    "data": None,
    "loaded_at": None,
    "ttl": CACHE_TTL_SECONDS,
    "hit_count": 0,
    "miss_count": 0,
    # GCS object generation at time of cache fill — surfaced to clients so they
    # can detect when the master log changed (insert, delete, dedup, reorder)
    # and invalidate their own session caches without polling for diffs.
    "generation": None,
}


def _cache_is_valid():
    """Return True if cached data exists and has not expired.

    A TTL of 0 means the cache never expires on its own — it only
    resets on cold start or an explicit ?action=refresh request.
    """
    if _cache["data"] is None or _cache["loaded_at"] is None:
        return False
    if _cache["ttl"] == 0:
        return True  # never expire
    age = time.time() - _cache["loaded_at"]
    return age < _cache["ttl"]


def _load_findings(force_refresh=False):
    """Dispatcher: route to GCS or Firestore loader based on FINDINGS_BACKEND.

    Both loaders return (list, cache_hit) and populate _cache identically,
    so all downstream code (filtering, pagination, ETag) is backend-agnostic.
    """
    if FINDINGS_BACKEND == "firestore":
        return _load_findings_firestore(force_refresh)
    return _load_findings_gcs(force_refresh)


def _load_findings_gcs(force_refresh=False):
    """Load findings from cache or GCS.

    Returns the list of finding dicts and a boolean indicating cache hit.
    """
    if not force_refresh and _cache_is_valid():
        _cache["hit_count"] += 1
        return _cache["data"], True

    # Cache miss — read from GCS
    client = _get_client()
    bucket = client.bucket(BUCKET_NAME)
    blob = bucket.blob(DATA_BLOB)
    if not blob.exists():
        data = []
        generation = None
    else:
        blob.reload()  # populates metadata including generation
        data = json.loads(blob.download_as_text())
        generation = blob.generation

    _cache["data"] = data
    _cache["loaded_at"] = time.time()
    _cache["generation"] = generation
    _cache["miss_count"] += 1
    return data, False


# Fields written by sync_gcs_to_firestore.py that aren't part of the wire schema.
# Stripped on read so the cached entries are byte-identical to GCS-sourced ones.
_FIRESTORE_INTERNAL_FIELDS = ("_hash", "_synced_at")


def _load_findings_firestore(force_refresh=False):
    """Load findings from cache or Firestore (`/findings` collection).

    Generation is derived from max(_synced_at) milliseconds plus entry count,
    so it changes on any sync that adds, updates, or deletes a doc — even a
    delete-only sync (where max(_synced_at) is unchanged but count drops).
    """
    if not force_refresh and _cache_is_valid():
        _cache["hit_count"] += 1
        return _cache["data"], True

    db = _get_firestore_client()
    data = []
    max_synced_ms = 0
    for doc in db.collection(FINDINGS_COLLECTION).stream():
        d = doc.to_dict() or {}
        synced = d.get("_synced_at")
        if synced is not None:
            try:
                ms = int(synced.timestamp() * 1000)
                if ms > max_synced_ms:
                    max_synced_ms = ms
            except Exception:  # noqa: BLE001 — bad timestamps shouldn't break the load
                pass
        for f in _FIRESTORE_INTERNAL_FIELDS:
            d.pop(f, None)
        data.append(d)

    if max_synced_ms:
        # Multiplex (sync_ms, count) into a single monotonic int. The 1e5 shift
        # gives count up to ~99,999 entries before collision — orders of
        # magnitude beyond expected scale.
        generation = max_synced_ms * 100_000 + len(data)
    else:
        generation = None

    _cache["data"] = data
    _cache["loaded_at"] = time.time()
    _cache["generation"] = generation
    _cache["miss_count"] += 1
    return data, False


def _download_with_generation():
    """Fetch the current findings blob along with its GCS generation number.

    Used by write paths to implement optimistic concurrency control via
    if_generation_match. Returns (list, generation) where generation is 0
    when the blob does not yet exist (for create-if-absent semantics).
    """
    client = _get_client()
    bucket = client.bucket(BUCKET_NAME)
    blob = bucket.blob(DATA_BLOB)
    if not blob.exists():
        return [], 0
    blob.reload()
    text = blob.download_as_text()
    return json.loads(text), blob.generation


def _upload_with_precondition(data, expected_generation):
    """Upload findings back to GCS with an if_generation_match precondition.

    Raises google.api_core.exceptions.PreconditionFailed if another writer
    updated the object since we read it.
    """
    client = _get_client()
    bucket = client.bucket(BUCKET_NAME)
    blob = bucket.blob(DATA_BLOB)
    payload = json.dumps(data, ensure_ascii=False, indent=2)
    blob.upload_from_string(
        payload,
        content_type="application/json",
        if_generation_match=expected_generation,
    )


def _invalidate_cache_with(data):
    """Replace the in-memory cache with freshly-written data."""
    _cache["data"] = data
    _cache["loaded_at"] = time.time()


def _find_index_by_entry_id(findings, entry_id):
    """Return index of the first entry whose entry_id matches, else -1."""
    for i, e in enumerate(findings):
        if e.get("entry_id") == entry_id:
            return i
    return -1


# Fields the admin UI may modify. category is intentionally excluded.
_EDITABLE_FIELDS = (
    "entry_id",
    "timestamp",
    "finding",
    "sentiment_takeaways",
    "guidance_play",
    "price_levels",
    "source_url",
    "tooltip",
)


def _with_tooltip(entry):
    """Return entry dict with a `tooltip` field always present.

    Prefers a stored tooltip; falls back to the first 30 chars of `finding`
    with an ellipsis. Phase 2 backfills the field properly using the
    sentiment_takeaways-derived logic ported from
    catalyst-knowledge-graph/src/export.py:_short_subtitle.
    """
    if not entry:
        return entry
    if entry.get("tooltip"):
        return entry
    finding = (entry.get("finding") or "").strip()
    if len(finding) > 30:
        tooltip = finding[:30].rstrip() + "…"
    else:
        tooltip = finding
    out = dict(entry)
    out["tooltip"] = tooltip
    return out


def _apply_update(findings, original_entry_id, patch):
    """Apply an update patch to the entry with the given original_entry_id.

    Returns (updated_findings, updated_entry) or raises ValueError for
    lookup/collision errors (caller maps these to 4xx responses).
    """
    idx = _find_index_by_entry_id(findings, original_entry_id)
    if idx < 0:
        raise ValueError(f"entry_id '{original_entry_id}' not found")

    new_entry_id = patch.get("entry_id", original_entry_id)
    if new_entry_id != original_entry_id:
        # Renaming — reject if the new id already exists on a different row.
        collision = _find_index_by_entry_id(findings, new_entry_id)
        if collision >= 0 and collision != idx:
            raise ValueError(f"entry_id '{new_entry_id}' already exists")

    entry = dict(findings[idx])
    for field in _EDITABLE_FIELDS:
        if field in patch:
            entry[field] = patch[field]
    findings = list(findings)
    findings[idx] = entry
    return findings, entry


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# CORS allowlist (Track A Phase 1 — replaces wildcard `*`).
# Driven by the ALLOWED_ORIGINS env var (comma-separated).  Defaults
# cover production GCS/Firebase hosting + local dev; extend via env var
# in cloud_function/deploy.sh without code changes.
_DEFAULT_ALLOWED_ORIGINS = (
    "https://storage.googleapis.com,"
    "https://arboryx-ai.web.app,"
    "https://arboryx-ai.firebaseapp.com,"
    "http://localhost:8000,"
    "http://localhost:3000,"
    "http://127.0.0.1:8000,"
    "http://127.0.0.1:3000"
)
_ALLOWED_ORIGINS = {
    o.strip() for o in os.environ.get("ALLOWED_ORIGINS", _DEFAULT_ALLOWED_ORIGINS).split(",") if o.strip()
}


def _resolve_origin(request_origin: str) -> str:
    """Return the request's Origin if it's in the allowlist, else empty string.
    An empty string in Access-Control-Allow-Origin signals 'no CORS allowed'
    to a browser without throwing — the response still works for non-browser
    clients (curl, server-to-server) that don't enforce CORS at all.
    """
    if not request_origin:
        return ""
    return request_origin if request_origin in _ALLOWED_ORIGINS else ""


def _cors_response(data, status=200):
    """Wrap response with CORS headers.

    Reads the per-request validated Origin from the _request_origin
    ContextVar (set at the top of the entry-point). Empty origin means
    the request had no Origin header OR the origin wasn't on the allowlist;
    in that case Access-Control-Allow-Origin is omitted so browsers reject
    the cross-site response, while non-browser clients (curl, server-to-
    server) still get the body.
    """
    origin = _request_origin.get()
    headers = {
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-Key, If-None-Match",
        "Access-Control-Expose-Headers": "ETag",
        "Access-Control-Max-Age": "3600",
        # Origin AND Accept-Encoding both vary the response — caches must
        # key on both so a gzipped body never gets served to a client that
        # didn't advertise gzip.
        "Vary": "Origin, Accept-Encoding",
        "Content-Type": "application/json",
    }
    if origin:
        headers["Access-Control-Allow-Origin"] = origin
    # Surface the cached GCS object generation on every JSON response so
    # clients can detect master-log changes (insert/delete/dedup/reorder)
    # without polling for diffs. Skip if data is a string (e.g. preflight).
    gen = _cache.get("generation")
    if isinstance(data, dict) and gen is not None and "data_generation" not in data:
        data["data_generation"] = gen
    # Strong-looking weak ETag — generation IS unique per data version, but
    # the wire body varies per query (filters, pagination), so weak is honest.
    if gen is not None:
        headers["ETag"] = f'W/"{gen}"'
    body = json.dumps(data) if not isinstance(data, str) else data
    # Track A Phase 2.3 — gzip when client opts in and the body is large
    # enough to justify the ~20-byte gzip header. Skip empty bodies
    # (preflight, errors with no string content) — gzipping nothing wastes CPU.
    if (
        body
        and _request_accepts_gzip.get()
        and isinstance(body, str)
        and len(body) >= _GZIP_MIN_BYTES
    ):
        body = gzip.compress(body.encode("utf-8"))
        headers["Content-Encoding"] = "gzip"
    return (body, status, headers)


def _matches_if_none_match(inm: str, generation) -> bool:
    """Return True if If-None-Match accepts the current generation as 'unchanged'.

    Tolerates the three legal forms: '*', strong '"123"', weak 'W/"123"',
    and comma-separated lists of those.
    """
    if not inm or generation is None:
        return False
    inm = inm.strip()
    if inm == "*":
        return True
    weak = f'W/"{generation}"'
    strong = f'"{generation}"'
    for tag in (t.strip() for t in inm.split(",")):
        if tag == weak or tag == strong:
            return True
    return False


def _not_modified_response(generation):
    """304 Not Modified — empty body, ETag + CORS headers preserved."""
    origin = _request_origin.get()
    headers = {
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-Key, If-None-Match",
        "Access-Control-Expose-Headers": "ETag",
        "Access-Control-Max-Age": "3600",
        "Vary": "Origin, Accept-Encoding",
        "ETag": f'W/"{generation}"',
    }
    if origin:
        headers["Access-Control-Allow-Origin"] = origin
    return ("", 304, headers)


def _error_response(message, status=400):
    """Convenience wrapper for error JSON with CORS."""
    return _cors_response({"error": message}, status)


# ---------------------------------------------------------------------------
# Per-IP rate limit (Track A Phase 1)
# ---------------------------------------------------------------------------
# In-memory token bucket — one bucket per (client_ip), keyed in a module-level
# dict. Per-instance state, so a request landing on a different function
# instance gets a fresh bucket; combined with --max-instances=5 this caps
# worst-case throughput at ~5 * RATE_LIMIT_BURST per minute. Acceptable
# leakage for a casual-abuse defense; upgrade to Redis/Firestore-backed
# limiting only if real abuse appears.
# 300/min sustained = 5 RPS — comfortably above human-driven page loads and
# automated test sweeps; still hard-caps abuse (combined with --max-instances=5
# the worst-case is ~1500 RPS total before Cloud Functions itself starts
# returning 429s). Tunable via env var without redeploy.
RATE_LIMIT_PER_MIN = int(os.environ.get("RATE_LIMIT_PER_MIN", "300"))
RATE_LIMIT_BURST = int(os.environ.get("RATE_LIMIT_BURST", "100"))
_rate_buckets: dict = {}  # ip -> {"tokens": float, "ts": float}


def _client_ip(request) -> str:
    """Extract the client IP, preferring X-Forwarded-For (Cloud Run/LB chain)."""
    xff = request.headers.get("X-Forwarded-For", "")
    if xff:
        # XFF is a comma-list of upstream hops; the first is the original client.
        return xff.split(",")[0].strip()
    return request.remote_addr or "unknown"


def _rate_limit_check(request):
    """Token-bucket per IP. Returns None if allowed, or a 429 CORS response if not."""
    ip = _client_ip(request)
    now = time.time()
    bucket = _rate_buckets.get(ip)
    if bucket is None:
        # New bucket: full burst.
        _rate_buckets[ip] = {"tokens": float(RATE_LIMIT_BURST), "ts": now}
        return None
    # Refill: RATE_LIMIT_PER_MIN tokens/minute, capped at BURST.
    elapsed = now - bucket["ts"]
    refill = elapsed * (RATE_LIMIT_PER_MIN / 60.0)
    bucket["tokens"] = min(float(RATE_LIMIT_BURST), bucket["tokens"] + refill)
    bucket["ts"] = now
    if bucket["tokens"] < 1.0:
        # Throttled. Compute Retry-After hint (seconds until 1 token refills).
        retry_after = max(1, int((1.0 - bucket["tokens"]) * 60.0 / RATE_LIMIT_PER_MIN))
        logging.warning("rate_limit ip=%s tokens=%.2f", ip, bucket["tokens"])
        body, status, headers = _error_response(
            f"Rate limit exceeded ({RATE_LIMIT_PER_MIN}/min per IP). Retry in {retry_after}s.",
            429,
        )
        headers["Retry-After"] = str(retry_after)
        return (body, status, headers)
    bucket["tokens"] -= 1.0
    return None


def _authenticate(request, requires_write=False):
    """Validate the API key from the request.

    Returns None if auth succeeds, or a CORS error tuple if it fails.
    When requires_write=True, read-only keys are rejected with 403.
    """
    if not _VALID_KEYS:
        # No keys configured — auth is disabled (open access)
        return None

    # Check X-API-Key header first, then Authorization: Bearer
    key = request.headers.get("X-API-Key", "").strip()
    if not key:
        auth_header = request.headers.get("Authorization", "")
        if auth_header.lower().startswith("bearer "):
            key = auth_header[7:].strip()

    if not key:
        return _error_response("Missing API key. Provide via X-API-Key header or Authorization: Bearer <key>.", 401)

    if key not in _VALID_KEYS:
        return _error_response("Invalid API key.", 401)

    if requires_write and key in _READ_ONLY_KEYS and key not in _WRITE_KEYS:
        return _error_response("This action requires a write-enabled API key.", 403)

    return None


# Actions that mutate state (or invalidate the read cache). Read-only
# keys are rejected with 403 on these.
_WRITE_ACTIONS = frozenset({"update", "delete", "refresh"})


_MONTH_MAP = {
    "january": 1, "february": 2, "march": 3, "april": 4,
    "may": 5, "june": 6, "july": 7, "august": 8,
    "september": 9, "october": 10, "november": 11, "december": 12,
}
_ISO_PREFIX_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})")
_HUMAN_RE = re.compile(r"^([A-Za-z]+)\s+(\d{1,2}).*?(\d{4})")


def _normalize_timestamp(ts: str) -> str:
    """Extract a YYYY-MM-DD date from varied timestamp formats for sorting.

    Handles: ISO (2026-04-10, 2026-03-14 18:13:55), human-readable
    (March 24, 2026), date ranges (March 21-22, 2026), and mixed variants.
    Returns '' for empty or unparseable input.
    """
    if not ts:
        return ""
    # ISO-like: extract YYYY-MM-DD prefix
    m = _ISO_PREFIX_RE.match(ts)
    if m:
        return m.group(1)
    # Human-readable: "March 24, 2026", "March 12-13, 2026", etc.
    m = _HUMAN_RE.match(ts)
    if m:
        month_str, day_str, year_str = m.group(1), m.group(2), m.group(3)
        month_num = _MONTH_MAP.get(month_str.lower())
        if month_num:
            return f"{year_str}-{month_num:02d}-{int(day_str):02d}"
    return ""


# Hard upper bounds — defense against pathological clients (e.g. limit=999999999
# blowing a list comprehension; days=10000 hitting timestamp arithmetic edge cases).
_LIMIT_MAX = 1000
_OFFSET_MAX = 1_000_000
_DAYS_MAX = 3650  # 10 years — plenty for current data, fits in an int

# Sector whitelist — must match frontend's CONFIG.sectors order/spelling.
# Used to validate ?category= against a closed set instead of accepting
# any string (which we'd then have to escape downstream).
_VALID_SECTORS = {
    "Robotics", "Crypto", "AI Stack",
    "Space & Defense", "Power & Energy", "Strategic Minerals",
}

# Strict regexes for scalar inputs.  Compile once at module load.
_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_ENTRY_ID_RE = re.compile(r"^[A-Z]{2,4}-\d{6}-\d{3}$")  # e.g. ROB-041926-001, CRY-042126-001


def _parse_positive_int(value, param_name, max_value=None):
    """Parse a string as a positive integer with an upper bound.
    Returns (int, None) or (None, error_string).
    """
    try:
        n = int(str(value).strip())
    except (ValueError, TypeError):
        return None, f"'{param_name}' must be a positive integer, got '{value}'"
    if n <= 0:
        return None, f"'{param_name}' must be a positive integer, got {n}"
    cap = max_value if max_value is not None else (
        _LIMIT_MAX if param_name == "limit"
        else _OFFSET_MAX if param_name == "offset"
        else _DAYS_MAX if param_name == "days"
        else None
    )
    if cap is not None and n > cap:
        return None, f"'{param_name}' must be <= {cap}, got {n}"
    return n, None


def _parse_date(value):
    """Parse a YYYY-MM-DD string strictly. Returns (date_str, None) or (None, error_string)."""
    if not isinstance(value, str) or not _DATE_RE.match(value):
        return None, f"'date' must be in YYYY-MM-DD format, got '{value}'"
    try:
        datetime.strptime(value, "%Y-%m-%d")
    except ValueError:
        return None, f"'date' is not a real calendar date: '{value}'"
    return value, None


def _parse_entry_id(value):
    """Validate an entry_id against the canonical SEC-DDMMYY-NNN shape.
    Returns (entry_id, None) or (None, error_string).
    """
    if not isinstance(value, str) or not _ENTRY_ID_RE.match(value):
        return None, f"'entry_id' must match ^[A-Z]{{2,4}}-\\d{{6}}-\\d{{3}}$, got '{value}'"
    return value, None


def _parse_category(value):
    """Validate ?category= against the closed sector whitelist.
    Returns (category, None) or (None, error_string).
    """
    if value not in _VALID_SECTORS:
        return None, f"'category' must be one of {sorted(_VALID_SECTORS)}, got '{value}'"
    return value, None


def _parse_sort(value):
    """Validate ?sort= as 'asc' or 'desc'.  Returns (sort, None) or (None, error_string)."""
    if value not in ("asc", "desc"):
        return None, f"'sort' must be 'asc' or 'desc', got '{value}'"
    return value, None


# Track A Phase 1.5 — defense-in-depth length cap. Individual parsers already
# enforce strict shapes (regex / whitelist), but a 200-char gate on every query
# string value rejects pathological payloads before we touch them.
_PARAM_MAX_LEN = 200

# Track A Phase 2.3 — minimum body size worth gzipping. Below this, the
# ~20-byte gzip header eats into any savings; CPU cost is also non-trivial
# at high QPS for tiny payloads.
_GZIP_MIN_BYTES = 512


def _validate_arg_lengths(request):
    """Return an error response if any query-arg value exceeds _PARAM_MAX_LEN, else None."""
    for key, value in request.args.items():
        if value is not None and len(value) > _PARAM_MAX_LEN:
            preview = value[:60] + ("..." if len(value) > 60 else "")
            logging.warning(
                f"reject_oversize_arg key={key} len={len(value)} preview='{preview}'"
            )
            return _error_response(
                f"query parameter '{key}' exceeds {_PARAM_MAX_LEN} chars", 400
            )
    return None


# ---------------------------------------------------------------------------
# Write handler (update / delete)
# ---------------------------------------------------------------------------

_WRITE_MAX_RETRIES = 1  # one retry on generation-precondition failure


def _handle_write(action, request, request_start):
    """Apply an update or delete to the findings blob in GCS.

    Uses optimistic concurrency: we read the current generation, apply the
    change in memory, and write back with if_generation_match. If the blob
    was modified concurrently we retry once; after that we surface 409 so
    the UI can prompt the user to refresh.
    """
    try:
        body = request.get_json(silent=True) or {}
    except Exception:
        return _error_response("Invalid JSON body", 400)

    if action == "update":
        original_entry_id = body.get("original_entry_id") or body.get("entry_id")
        patch = body.get("patch") or {k: body[k] for k in _EDITABLE_FIELDS if k in body}
        if not original_entry_id:
            return _error_response("Missing 'original_entry_id' (or 'entry_id')", 400)
        if not patch:
            return _error_response("No editable fields supplied", 400)
    else:  # delete
        original_entry_id = body.get("entry_id")
        if not original_entry_id:
            return _error_response("Missing 'entry_id'", 400)
        patch = None

    # Load + mutate + write with optimistic retry
    from google.api_core.exceptions import PreconditionFailed  # local import — cold start

    last_error = None
    for attempt in range(_WRITE_MAX_RETRIES + 1):
        findings, generation = _download_with_generation()
        try:
            if action == "update":
                new_findings, updated_entry = _apply_update(findings, original_entry_id, patch)
                result_payload = {"status": "updated", "entry": _with_tooltip(updated_entry)}
            else:
                idx = _find_index_by_entry_id(findings, original_entry_id)
                if idx < 0:
                    return _error_response(f"entry_id '{original_entry_id}' not found", 404)
                new_findings = findings[:idx] + findings[idx + 1:]
                result_payload = {"status": "deleted", "entry_id": original_entry_id}
        except ValueError as ve:
            # Lookup miss or entry_id collision — deterministic 4xx, no retry
            msg = str(ve)
            status = 409 if "already exists" in msg else 404
            return _error_response(msg, status)

        try:
            _upload_with_precondition(new_findings, generation)
            _invalidate_cache_with(new_findings)
            result_payload["total"] = len(new_findings)
            elapsed = time.time() - request_start
            logging.info(
                f"action={action} entry_id={original_entry_id} "
                f"total={len(new_findings)} attempts={attempt + 1} time={elapsed:.4f}s"
            )
            return _cors_response(result_payload)
        except PreconditionFailed as pe:
            last_error = pe
            continue  # someone else wrote — reload and retry

    elapsed = time.time() - request_start
    logging.warning(
        f"action={action} entry_id={original_entry_id} "
        f"conflict_after_retries time={elapsed:.4f}s err={last_error}"
    )
    return _error_response(
        "Conflict: the findings file changed while we were writing. Please refresh and try again.",
        409,
    )


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

def api_handler(request):
    """HTTP Cloud Function entrypoint."""
    request_start = time.time()

    # Resolve + stash the CORS origin once for this request — _cors_response
    # reads it from the ContextVar so we don't have to thread it everywhere.
    _request_origin.set(_resolve_origin(request.headers.get("Origin", "")))
    # Mirror the client's gzip preference for _cors_response. Be permissive
    # on parsing — any 'gzip' token is a yes; 'identity' / empty / missing = no.
    _request_accepts_gzip.set("gzip" in request.headers.get("Accept-Encoding", "").lower())

    # Handle CORS preflight — no auth required
    if request.method == "OPTIONS":
        return _cors_response("", 204)

    # Track A Phase 1.5 — reject pathologically-long query args before any
    # downstream parsing/auth work. Individual parsers still enforce shape;
    # this is a cheap upstream gate against >200-char payloads.
    size_error = _validate_arg_lengths(request)
    if size_error is not None:
        return size_error

    # Track A Phase 1 — per-IP rate limit BEFORE auth so a flood of bad-key
    # requests can't burn through the auth check on every hit. Bypassed for
    # the unauthenticated health check so probes/uptime checks aren't capped.
    action = request.args.get("action", "findings")
    if action != "health":
        rl_error = _rate_limit_check(request)
        if rl_error is not None:
            return rl_error

    # Health check — no auth required
    if action == "health":
        elapsed = time.time() - request_start
        logging.info(f"action=health cache=n/a time={elapsed:.4f}s")
        return _cors_response({
            "status": "ok",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "cache_ttl": _cache["ttl"],
        })

    # Authenticate all other endpoints. Write actions require a key
    # NOT in the read-only allowlist; everything else accepts either.
    auth_error = _authenticate(request, requires_write=(action in _WRITE_ACTIONS))
    if auth_error is not None:
        elapsed = time.time() - request_start
        logging.warning(f"action={action} auth=FAILED time={elapsed:.4f}s")
        return auth_error

    try:
        # ---- update / delete (write paths) ----
        if action in ("update", "delete"):
            if request.method != "POST":
                return _error_response(f"action={action} requires POST", 405)
            return _handle_write(action, request, request_start)

        # ---- ETag conditional GET (Track A Phase 2.4) ----
        # Skip for `refresh` (caller explicitly wants a fresh read) and
        # `cache_status` (admin debug — should always reflect live cache state).
        # For everything else, the response is a function of the master-log
        # generation; if the client already has that version, return 304.
        if action not in ("refresh", "cache_status"):
            inm = request.headers.get("If-None-Match", "")
            if inm:
                _load_findings()  # populate _cache["generation"]
                gen = _cache.get("generation")
                if _matches_if_none_match(inm, gen):
                    elapsed = time.time() - request_start
                    logging.info(f"action={action} etag=HIT 304 time={elapsed:.4f}s")
                    return _not_modified_response(gen)

        # ---- cache_status ----
        if action == "cache_status":
            elapsed = time.time() - request_start
            logging.info(f"action=cache_status time={elapsed:.4f}s")
            return _cors_response({
                "cache_valid": _cache_is_valid(),
                "entry_count": len(_cache["data"]) if _cache["data"] is not None else 0,
                "hit_count": _cache["hit_count"],
                "miss_count": _cache["miss_count"],
                "ttl_seconds": _cache["ttl"],
                "last_refresh": (
                    datetime.fromtimestamp(_cache["loaded_at"], tz=timezone.utc).isoformat()
                    if _cache["loaded_at"] else None
                ),
                "age_seconds": (
                    round(time.time() - _cache["loaded_at"], 1)
                    if _cache["loaded_at"] else None
                ),
            })

        # ---- refresh ----
        if action == "refresh":
            findings, cache_hit = _load_findings(force_refresh=True)
            elapsed = time.time() - request_start
            logging.info(f"action=refresh entries={len(findings)} time={elapsed:.4f}s")
            return _cors_response({
                "status": "refreshed",
                "entry_count": len(findings),
                "timestamp": datetime.now(timezone.utc).isoformat(),
            })

        # ---- Load findings (cached) ----
        findings, cache_hit = _load_findings()
        cache_label = "HIT" if cache_hit else "MISS"

        # ---- categories ----
        if action == "categories":
            cats = sorted(set(e.get("category", "Unknown") for e in findings))
            elapsed = time.time() - request_start
            logging.info(f"action=categories cache={cache_label} count={len(cats)} time={elapsed:.4f}s")
            return _cors_response({"categories": cats, "count": len(cats)})

        # ---- entry by id ----
        if action == "entry":
            entry_id = request.args.get("id") or request.args.get("entry_id")
            if not entry_id:
                return _error_response("'id' query parameter required for action=entry")
            idx = _find_index_by_entry_id(findings, entry_id)
            if idx < 0:
                return _error_response(f"entry_id '{entry_id}' not found", 404)
            elapsed = time.time() - request_start
            logging.info(f"action=entry cache={cache_label} entry_id={entry_id} time={elapsed:.4f}s")
            return _cors_response({"entry": _with_tooltip(findings[idx])})

        # ---- stats ----
        # Optional ?days=N filter scopes the response (total_findings,
        # categories, date_range) to the last N days. Without days, returns
        # all-time stats — preserves backward compat.
        if action == "stats":
            days_raw = request.args.get("days")
            scoped = findings
            if days_raw is not None:
                days, err = _parse_positive_int(days_raw, "days")
                if err:
                    return _error_response(err)
                cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d")
                scoped = [e for e in findings if _normalize_timestamp(e.get("timestamp", "")) >= cutoff]

            category_counts: dict = {}
            normalized_dates = []
            for e in scoped:
                cat = e.get("category", "Unknown")
                category_counts[cat] = category_counts.get(cat, 0) + 1
                nd = _normalize_timestamp(e.get("timestamp", ""))
                if nd:
                    normalized_dates.append(nd)

            normalized_dates.sort()
            elapsed = time.time() - request_start
            logging.info(
                f"action=stats cache={cache_label} days={days_raw} "
                f"total={len(scoped)} time={elapsed:.4f}s"
            )
            response = {
                "total_findings": len(scoped),
                "categories": category_counts,
                "date_range": {
                    "earliest": normalized_dates[0] if normalized_dates else None,
                    "latest": normalized_dates[-1] if normalized_dates else None,
                },
            }
            if days_raw is not None:
                response["days_window"] = int(days_raw)
            return _cors_response(response)

        # ---- findings (default) ----
        category = request.args.get("category")
        days_raw = request.args.get("days")
        limit_raw = request.args.get("limit")
        offset_raw = request.args.get("offset")
        date_raw = request.args.get("date")
        sort_order = request.args.get("sort", "desc")

        # Validate sort
        if sort_order not in ("asc", "desc"):
            return _error_response(f"'sort' must be 'asc' or 'desc', got '{sort_order}'")

        # Validate and apply category filter
        if category:
            findings = [e for e in findings if e.get("category", "").lower() == category.lower()]

        # Validate and apply days filter
        if days_raw is not None:
            days, err = _parse_positive_int(days_raw, "days")
            if err:
                return _error_response(err)
            cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d")
            findings = [e for e in findings if _normalize_timestamp(e.get("timestamp", "")) >= cutoff]

        # Validate and apply date filter
        if date_raw is not None:
            date_str, err = _parse_date(date_raw)
            if err:
                return _error_response(err)
            findings = [e for e in findings if _normalize_timestamp(e.get("timestamp", "")) == date_str]

        # Sort by timestamp (normalized to YYYY-MM-DD for consistent ordering)
        findings = sorted(
            findings,
            key=lambda e: _normalize_timestamp(e.get("timestamp", "")),
            reverse=(sort_order == "desc"),
        )

        # Pagination
        total = len(findings)
        offset = 0
        limit = total  # default: return everything

        if offset_raw is not None:
            offset, err = _parse_positive_int(offset_raw, "offset")
            if err:
                # Allow offset=0 explicitly
                if offset_raw == "0":
                    offset = 0
                else:
                    return _error_response(err)

        if limit_raw is not None:
            limit, err = _parse_positive_int(limit_raw, "limit")
            if err:
                return _error_response(err)

        paginated = [_with_tooltip(e) for e in findings[offset: offset + limit]]
        has_more = (offset + limit) < total

        elapsed = time.time() - request_start
        logging.info(
            f"action=findings cache={cache_label} category={category} days={days_raw} "
            f"date={date_raw} sort={sort_order} total={total} returned={len(paginated)} "
            f"time={elapsed:.4f}s"
        )

        return _cors_response({
            "findings": paginated,
            "count": len(paginated),
            "total": total,
            "offset": offset,
            "limit": limit,
            "has_more": has_more,
            "filters": {
                "category": category,
                "days": days_raw,
                "date": date_raw,
                "sort": sort_order,
            },
        })

    except Exception as e:
        elapsed = time.time() - request_start
        logging.error(f"action={action} error={e} time={elapsed:.4f}s", exc_info=True)
        return _cors_response({"error": str(e)}, 500)
