"""Cloud Function (2nd gen, HTTP) — API backend for AlphaSnap UI.

Reads market findings from GCS and serves them as JSON.
Includes API key authentication, in-memory caching, pagination,
and production logging.

Authentication:
    All endpoints except OPTIONS preflight and ?action=health require
    a valid API key. Send via:
        X-API-Key: <key>
        Authorization: Bearer <key>
    The expected key is set in the API_KEY env var.  For key rotation,
    API_KEYS can hold a comma-separated list of valid keys.

Endpoints (via ?action= query param):
    GET ?action=findings                  -> all findings (optionally filtered)
    GET ?action=findings&category=X       -> findings for one sector
    GET ?action=findings&days=N           -> findings from the last N days
    GET ?action=findings&date=YYYY-MM-DD  -> findings from an exact date
    GET ?action=findings&sort=asc|desc    -> sort order (default: desc)
    GET ?action=findings&limit=N&offset=M -> pagination
    GET ?action=categories                -> list of available categories
    GET ?action=stats                     -> total findings, category breakdown, date range
    GET ?action=health                    -> health check (no auth required)
    GET ?action=cache_status              -> cache hit count, last refresh, TTL, entry count
    GET ?action=refresh                   -> force cache invalidation and reload

Query parameter validation:
    days, limit, offset  -> must be positive integers
    date                 -> must be YYYY-MM-DD format
    sort                 -> must be 'asc' or 'desc'
    Invalid values return 400 with a descriptive error message.
"""

import os
import re
import json
import time
import logging
from datetime import datetime, timedelta, timezone
from google.cloud import storage

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PROJECT_ID = os.environ.get("PROJECT_ID", "marketresearch-agents")
BUCKET_NAME = os.environ.get("STORAGE_BUCKET", "marketresearch-agents")
DATA_BLOB = os.environ.get("DATA_BLOB", "market_findings_log.json")
CACHE_TTL_SECONDS = int(os.environ.get("CACHE_TTL_SECONDS", "300"))

# Auth — single key or comma-separated list for rotation
_API_KEY = os.environ.get("API_KEY", "")
_API_KEYS_RAW = os.environ.get("API_KEYS", "")
_VALID_KEYS: set = set()


def _build_valid_keys():
    """Build the set of valid API keys from env vars (once)."""
    global _VALID_KEYS
    keys: set = set()
    if _API_KEY:
        keys.add(_API_KEY.strip())
    if _API_KEYS_RAW:
        for k in _API_KEYS_RAW.split(","):
            k = k.strip()
            if k:
                keys.add(k)
    _VALID_KEYS = keys


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
# In-memory cache
# ---------------------------------------------------------------------------
_cache = {
    "data": None,
    "loaded_at": None,
    "ttl": CACHE_TTL_SECONDS,
    "hit_count": 0,
    "miss_count": 0,
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
    else:
        data = json.loads(blob.download_as_text())

    _cache["data"] = data
    _cache["loaded_at"] = time.time()
    _cache["miss_count"] += 1
    return data, False


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _cors_response(data, status=200):
    """Wrap response with CORS headers."""
    headers = {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-Key",
        "Content-Type": "application/json",
    }
    body = json.dumps(data) if not isinstance(data, str) else data
    return (body, status, headers)


def _error_response(message, status=400):
    """Convenience wrapper for error JSON with CORS."""
    return _cors_response({"error": message}, status)


def _authenticate(request):
    """Validate the API key from the request.

    Returns None if auth succeeds, or a CORS error tuple if it fails.
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

    return None


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


def _parse_positive_int(value, param_name):
    """Parse a string as a positive integer. Returns (int, None) or (None, error_string)."""
    try:
        n = int(value)
    except (ValueError, TypeError):
        return None, f"'{param_name}' must be a positive integer, got '{value}'"
    if n <= 0:
        return None, f"'{param_name}' must be a positive integer, got {n}"
    return n, None


def _parse_date(value):
    """Parse a YYYY-MM-DD string. Returns (date_str, None) or (None, error_string)."""
    try:
        datetime.strptime(value, "%Y-%m-%d")
        return value, None
    except (ValueError, TypeError):
        return None, f"'date' must be in YYYY-MM-DD format, got '{value}'"


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

def api_handler(request):
    """HTTP Cloud Function entrypoint."""
    request_start = time.time()

    # Handle CORS preflight — no auth required
    if request.method == "OPTIONS":
        return _cors_response("", 204)

    action = request.args.get("action", "findings")

    # Health check — no auth required
    if action == "health":
        elapsed = time.time() - request_start
        logging.info(f"action=health cache=n/a time={elapsed:.4f}s")
        return _cors_response({
            "status": "ok",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "cache_ttl": _cache["ttl"],
        })

    # Authenticate all other endpoints
    auth_error = _authenticate(request)
    if auth_error is not None:
        elapsed = time.time() - request_start
        logging.warning(f"action={action} auth=FAILED time={elapsed:.4f}s")
        return auth_error

    try:
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

        # ---- stats ----
        if action == "stats":
            category_counts: dict = {}
            normalized_dates = []
            for e in findings:
                cat = e.get("category", "Unknown")
                category_counts[cat] = category_counts.get(cat, 0) + 1
                nd = _normalize_timestamp(e.get("timestamp", ""))
                if nd:
                    normalized_dates.append(nd)

            normalized_dates.sort()
            elapsed = time.time() - request_start
            logging.info(f"action=stats cache={cache_label} total={len(findings)} time={elapsed:.4f}s")
            return _cors_response({
                "total_findings": len(findings),
                "categories": category_counts,
                "date_range": {
                    "earliest": normalized_dates[0] if normalized_dates else None,
                    "latest": normalized_dates[-1] if normalized_dates else None,
                },
            })

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

        paginated = findings[offset: offset + limit]
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
