#!/usr/bin/env python3
"""Comprehensive, configurable test script for the Arboryx Admin API backend.

Tests all endpoints, filters, auth, combined queries, and edge cases against
a live (deployed or local) API instance.

Requirements:
    pip install requests

Usage:
    # Minimal — URL from env or CLI:
    export ARBORYX_ADMIN_API_URL=https://us-central1-marketresearch-agents.cloudfunctions.net/arboryx-admin-api
    export ARBORYX_ADMIN_API_KEY=your-key-here
    python3 dev-utils/test_api.py

    # Override everything on the command line:
    python3 dev-utils/test_api.py \\
        --url https://my-api.example.com \\
        --api-key my-secret \\
        --suite filters \\
        --category "AI Stack" \\
        --days 14 \\
        --verbose

    # Run only auth tests:
    python3 dev-utils/test_api.py -u https://... -k my-key --suite auth
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass, field
from datetime import date, datetime
from enum import Enum
from typing import Any, Optional
from urllib.parse import urlencode

import requests


# ---------------------------------------------------------------------------
# ANSI colours
# ---------------------------------------------------------------------------
class _C:
    """Terminal colour helpers (degrade to no-op when piped)."""
    _enabled = hasattr(sys.stdout, "isatty") and sys.stdout.isatty()

    PASS  = "\033[92m" if _enabled else ""   # green
    FAIL  = "\033[91m" if _enabled else ""   # red
    SKIP  = "\033[93m" if _enabled else ""   # yellow
    BOLD  = "\033[1m"  if _enabled else ""
    DIM   = "\033[2m"  if _enabled else ""
    RESET = "\033[0m"  if _enabled else ""
    CYAN  = "\033[96m" if _enabled else ""


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------
class Status(Enum):
    PASS = "PASS"
    FAIL = "FAIL"
    SKIP = "SKIP"


@dataclass
class TestResult:
    name: str
    status: Status
    url: str = ""
    http_status: Optional[int] = None
    elapsed_ms: float = 0.0
    result_count: Optional[int] = None
    detail: str = ""
    response_body: str = ""


# ---------------------------------------------------------------------------
# HTTP helper
# ---------------------------------------------------------------------------
def _make_request(
    base_url: str,
    params: dict[str, str],
    *,
    api_key: Optional[str] = None,
    method: str = "GET",
    timeout: int = 30,
) -> tuple[str, int, float, requests.Response | None]:
    """Fire an HTTP request and return (url, status_code, elapsed_ms, response).

    On connection/timeout errors returns status_code=-1 and response=None.
    """
    url = base_url
    if params:
        url = f"{base_url}?{urlencode(params)}"

    headers: dict[str, str] = {}
    if api_key is not None:
        headers["X-API-Key"] = api_key

    t0 = time.perf_counter()
    try:
        resp = requests.request(method, url, headers=headers, timeout=timeout)
        elapsed = (time.perf_counter() - t0) * 1000
        return url, resp.status_code, elapsed, resp
    except requests.exceptions.Timeout:
        elapsed = (time.perf_counter() - t0) * 1000
        return url, -1, elapsed, None
    except requests.exceptions.ConnectionError:
        elapsed = (time.perf_counter() - t0) * 1000
        return url, -1, elapsed, None
    except requests.exceptions.RequestException as exc:
        elapsed = (time.perf_counter() - t0) * 1000
        return url, -1, elapsed, None


def _safe_json(resp: Optional[requests.Response]) -> Any:
    """Try to parse response JSON; return None on failure."""
    if resp is None:
        return None
    try:
        return resp.json()
    except (json.JSONDecodeError, ValueError):
        return None


def _count_from_body(body: Any) -> Optional[int]:
    """Extract a result count from common response shapes."""
    if body is None:
        return None
    if isinstance(body, dict):
        if "count" in body:
            return int(body["count"])
        if "findings" in body and isinstance(body["findings"], list):
            return len(body["findings"])
        if "categories" in body and isinstance(body["categories"], list):
            return len(body["categories"])
    if isinstance(body, list):
        return len(body)
    return None


# ---------------------------------------------------------------------------
# Pretty print
# ---------------------------------------------------------------------------
def _truncate(text: str, max_len: int = 500) -> str:
    if len(text) <= max_len:
        return text
    return text[:max_len] + f"... ({len(text) - max_len} chars truncated)"


def _print_result(tr: TestResult, verbose: bool = False) -> None:
    if tr.status == Status.PASS:
        badge = f"{_C.PASS}{_C.BOLD}[PASS]{_C.RESET}"
    elif tr.status == Status.FAIL:
        badge = f"{_C.FAIL}{_C.BOLD}[FAIL]{_C.RESET}"
    else:
        badge = f"{_C.SKIP}{_C.BOLD}[SKIP]{_C.RESET}"

    status_str = str(tr.http_status) if tr.http_status is not None else "---"
    count_str = str(tr.result_count) if tr.result_count is not None else "-"

    print(f"  {badge}  {tr.name}")
    print(f"         {_C.DIM}URL:{_C.RESET} {tr.url}")
    print(
        f"         {_C.DIM}Status:{_C.RESET} {status_str}  "
        f"{_C.DIM}Time:{_C.RESET} {tr.elapsed_ms:,.0f} ms  "
        f"{_C.DIM}Count:{_C.RESET} {count_str}"
    )
    if tr.detail:
        print(f"         {_C.DIM}Detail:{_C.RESET} {tr.detail}")
    if verbose and tr.response_body:
        print(f"         {_C.DIM}Body:{_C.RESET}")
        for line in _truncate(tr.response_body).splitlines():
            print(f"           {line}")
    print()


# ---------------------------------------------------------------------------
# Individual test helpers
# ---------------------------------------------------------------------------
def _run_one(
    name: str,
    base_url: str,
    params: dict[str, str],
    *,
    api_key: Optional[str] = None,
    method: str = "GET",
    timeout: int = 30,
    expect_status: int = 200,
    expect_count: Optional[int] = None,
    expect_count_max: Optional[int] = None,
    expect_count_min: Optional[int] = None,
    expect_empty: bool = False,
    expect_key: Optional[str] = None,
    expect_finding_field: Optional[str] = None,
) -> TestResult:
    """Run a single test and return a TestResult."""
    url, status, elapsed, resp = _make_request(
        base_url, params, api_key=api_key, method=method, timeout=timeout,
    )
    body = _safe_json(resp)
    body_str = ""
    if body is not None:
        try:
            body_str = json.dumps(body, indent=2)
        except (TypeError, ValueError):
            body_str = str(body)
    elif resp is not None:
        body_str = resp.text[:1000]

    count = _count_from_body(body)
    detail = ""
    passed = True

    # Connection-level failure
    if status == -1:
        return TestResult(
            name=name, status=Status.FAIL, url=url,
            http_status=None, elapsed_ms=elapsed, result_count=None,
            detail="Connection error or timeout",
            response_body=body_str,
        )

    # Status code check
    if status != expect_status:
        passed = False
        detail = f"Expected HTTP {expect_status}, got {status}"

    # Count checks (only when status matched)
    if passed and expect_count is not None and count != expect_count:
        passed = False
        detail = f"Expected count={expect_count}, got {count}"

    if passed and expect_count_max is not None and count is not None and count > expect_count_max:
        passed = False
        detail = f"Expected count <= {expect_count_max}, got {count}"

    if passed and expect_count_min is not None and count is not None and count < expect_count_min:
        passed = False
        detail = f"Expected count >= {expect_count_min}, got {count}"

    if passed and expect_empty:
        if count is not None and count != 0:
            passed = False
            detail = f"Expected empty results, got {count}"

    if passed and expect_key is not None:
        if body is None or (isinstance(body, dict) and expect_key not in body):
            passed = False
            detail = f"Expected key '{expect_key}' in response"

    if passed and expect_finding_field is not None:
        target = None
        if isinstance(body, dict):
            if isinstance(body.get("findings"), list) and body["findings"]:
                target = body["findings"][0]
            elif isinstance(body.get("entry"), dict):
                target = body["entry"]
        if target is None or expect_finding_field not in target:
            passed = False
            detail = f"Expected field '{expect_finding_field}' in findings[0]/entry"

    return TestResult(
        name=name,
        status=Status.PASS if passed else Status.FAIL,
        url=url,
        http_status=status,
        elapsed_ms=elapsed,
        result_count=count,
        detail=detail,
        response_body=body_str,
    )


# ---------------------------------------------------------------------------
# Test suites
# ---------------------------------------------------------------------------
def suite_auth(cfg: argparse.Namespace) -> list[TestResult]:
    """Authentication / authorization tests."""
    results: list[TestResult] = []

    # 1) No API key -> 401
    results.append(_run_one(
        "Auth: no API key -> 401",
        cfg.url, {"action": "findings"},
        api_key=None, timeout=cfg.timeout,
        expect_status=401,
    ))

    # 2) Invalid API key -> 401
    results.append(_run_one(
        "Auth: invalid API key -> 401",
        cfg.url, {"action": "findings"},
        api_key="INVALID_KEY_000", timeout=cfg.timeout,
        expect_status=401,
    ))

    # 3) Valid API key -> 200
    if cfg.api_key:
        results.append(_run_one(
            "Auth: valid API key -> 200",
            cfg.url, {"action": "findings", "limit": "1"},
            api_key=cfg.api_key, timeout=cfg.timeout,
            expect_status=200,
        ))
    else:
        results.append(TestResult(
            name="Auth: valid API key -> 200",
            status=Status.SKIP,
            detail="No --api-key provided; skipping valid-key test",
        ))

    # 4) OPTIONS preflight should work without API key (CORS)
    results.append(_run_one(
        "Auth: OPTIONS preflight without key (CORS)",
        cfg.url, {"action": "findings"},
        api_key=None, method="OPTIONS", timeout=cfg.timeout,
        expect_status=204,
    ))

    # 5–8) Read-only key tier — passes reads, blocked from writes
    if cfg.read_only_key:
        results.append(_run_one(
            "Auth: read-only key on findings -> 200",
            cfg.url, {"action": "findings", "limit": "1"},
            api_key=cfg.read_only_key, timeout=cfg.timeout,
            expect_status=200,
        ))
        results.append(_run_one(
            "Auth: read-only key on update -> 403",
            cfg.url, {"action": "update"},
            api_key=cfg.read_only_key, method="POST", timeout=cfg.timeout,
            expect_status=403,
        ))
        results.append(_run_one(
            "Auth: read-only key on delete -> 403",
            cfg.url, {"action": "delete"},
            api_key=cfg.read_only_key, method="POST", timeout=cfg.timeout,
            expect_status=403,
        ))
        results.append(_run_one(
            "Auth: read-only key on refresh -> 403",
            cfg.url, {"action": "refresh"},
            api_key=cfg.read_only_key, timeout=cfg.timeout,
            expect_status=403,
        ))
    else:
        for label in (
            "Auth: read-only key on findings -> 200",
            "Auth: read-only key on update -> 403",
            "Auth: read-only key on delete -> 403",
            "Auth: read-only key on refresh -> 403",
        ):
            results.append(TestResult(
                name=label, status=Status.SKIP,
                detail="No --read-only-key provided; skipping read-only-tier tests",
            ))

    return results


def suite_basic(cfg: argparse.Namespace) -> list[TestResult]:
    """Basic endpoint tests — one call per action."""
    results: list[TestResult] = []

    # Health check (no auth required)
    results.append(_run_one(
        "Basic: health check (no auth)",
        cfg.url, {"action": "health"},
        api_key=None, timeout=cfg.timeout,
        expect_status=200, expect_key="status",
    ))

    # Categories
    results.append(_run_one(
        "Basic: categories list",
        cfg.url, {"action": "categories"},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200, expect_key="categories",
    ))

    # Stats
    results.append(_run_one(
        "Basic: stats endpoint",
        cfg.url, {"action": "stats"},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200,
    ))

    # Stats with recency window — categories/total scoped to last N days
    results.append(_run_one(
        "Basic: stats with days=7 (recency-scoped)",
        cfg.url, {"action": "stats", "days": "7"},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200, expect_key="days_window",
    ))

    # Cache status
    results.append(_run_one(
        "Basic: cache_status endpoint",
        cfg.url, {"action": "cache_status"},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200,
    ))

    # Force refresh
    results.append(_run_one(
        "Basic: force cache refresh",
        cfg.url, {"action": "refresh"},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200,
    ))

    # Findings response carries `tooltip` field on every entry
    results.append(_run_one(
        "Basic: findings include tooltip field",
        cfg.url, {"action": "findings", "limit": "1"},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200, expect_finding_field="tooltip",
    ))

    # Entry-by-id endpoint — fetch one entry_id, then look it up
    sample_entry_id = _fetch_sample_entry_id(cfg)
    if sample_entry_id:
        results.append(_run_one(
            f"Basic: entry by id ({sample_entry_id}) -> 200",
            cfg.url, {"action": "entry", "id": sample_entry_id},
            api_key=cfg.api_key, timeout=cfg.timeout,
            expect_status=200, expect_finding_field="tooltip",
        ))
    else:
        results.append(TestResult(
            name="Basic: entry by id -> 200",
            status=Status.SKIP,
            detail="Could not fetch a sample entry_id (no findings or auth failure)",
        ))

    # Entry endpoint without id -> 400
    results.append(_run_one(
        "Basic: entry without id -> 400",
        cfg.url, {"action": "entry"},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=400,
    ))

    # Entry endpoint with bogus id -> 404
    results.append(_run_one(
        "Basic: entry with unknown id -> 404",
        cfg.url, {"action": "entry", "id": "DEFINITELY-NOT-AN-ENTRY-XYZ"},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=404,
    ))

    return results


def _fetch_sample_entry_id(cfg: argparse.Namespace) -> Optional[str]:
    """Fetch a single finding and return its entry_id (for entry-by-id tests)."""
    url, status, _, resp = _make_request(
        cfg.url, {"action": "findings", "limit": "1"},
        api_key=cfg.api_key, timeout=cfg.timeout,
    )
    if status != 200 or resp is None:
        return None
    body = _safe_json(resp)
    if not isinstance(body, dict):
        return None
    findings = body.get("findings")
    if not isinstance(findings, list) or not findings:
        return None
    return findings[0].get("entry_id")


def suite_filters(cfg: argparse.Namespace) -> list[TestResult]:
    """Single-filter tests."""
    results: list[TestResult] = []

    # Limit sweep (limit_min to limit_max, step 5)
    for lim in range(cfg.limit_min, cfg.limit_max + 1, 5):
        results.append(_run_one(
            f"Filter: limit={lim}",
            cfg.url, {"action": "findings", "limit": str(lim)},
            api_key=cfg.api_key, timeout=cfg.timeout,
            expect_status=200, expect_count_max=lim,
        ))

    # Category
    results.append(_run_one(
        f"Filter: category={cfg.category}",
        cfg.url, {"action": "findings", "category": cfg.category},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200,
    ))

    # Days
    results.append(_run_one(
        f"Filter: days={cfg.days}",
        cfg.url, {"action": "findings", "days": str(cfg.days)},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200,
    ))

    # Exact date
    results.append(_run_one(
        f"Filter: date={cfg.date}",
        cfg.url, {"action": "findings", "date": cfg.date},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200,
    ))

    # Sort ascending
    results.append(_run_one(
        "Filter: sort=asc",
        cfg.url, {"action": "findings", "sort": "asc", "limit": "5"},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200,
    ))

    # Sort descending
    results.append(_run_one(
        "Filter: sort=desc",
        cfg.url, {"action": "findings", "sort": "desc", "limit": "5"},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200,
    ))

    return results


def suite_combined(cfg: argparse.Namespace) -> list[TestResult]:
    """Multi-filter combination tests."""
    results: list[TestResult] = []

    # days + category
    results.append(_run_one(
        f"Combined: days={cfg.days} + category={cfg.category}",
        cfg.url, {"action": "findings", "days": str(cfg.days), "category": cfg.category},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200,
    ))

    # limit + category
    results.append(_run_one(
        f"Combined: limit={cfg.limit_min} + category={cfg.category}",
        cfg.url, {"action": "findings", "limit": str(cfg.limit_min), "category": cfg.category},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200, expect_count_max=cfg.limit_min,
    ))

    # category + days + limit
    results.append(_run_one(
        f"Combined: category={cfg.category} + days={cfg.days} + limit={cfg.limit_max}",
        cfg.url, {
            "action": "findings",
            "category": cfg.category,
            "days": str(cfg.days),
            "limit": str(cfg.limit_max),
        },
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200, expect_count_max=cfg.limit_max,
    ))

    # date + category
    results.append(_run_one(
        f"Combined: date={cfg.date} + category={cfg.category}",
        cfg.url, {"action": "findings", "date": cfg.date, "category": cfg.category},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200,
    ))

    # limit + offset (pagination)
    results.append(_run_one(
        f"Combined: limit={cfg.limit_min} + offset={cfg.limit_min} (page 2)",
        cfg.url, {
            "action": "findings",
            "limit": str(cfg.limit_min),
            "offset": str(cfg.limit_min),
        },
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200, expect_count_max=cfg.limit_min,
    ))

    # category + sort + limit
    results.append(_run_one(
        f"Combined: category={cfg.category} + sort=desc + limit={cfg.limit_min}",
        cfg.url, {
            "action": "findings",
            "category": cfg.category,
            "sort": "desc",
            "limit": str(cfg.limit_min),
        },
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200, expect_count_max=cfg.limit_min,
    ))

    return results


def suite_edge(cfg: argparse.Namespace) -> list[TestResult]:
    """Edge-case and negative tests."""
    results: list[TestResult] = []

    # Invalid category -> empty results (not an error)
    results.append(_run_one(
        "Edge: invalid category -> empty results",
        cfg.url, {"action": "findings", "category": "NonexistentCategoryXYZ"},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200, expect_empty=True,
    ))

    # days=0 -> 400 (must be positive integer)
    results.append(_run_one(
        "Edge: days=0 -> 400",
        cfg.url, {"action": "findings", "days": "0"},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=400,
    ))

    # limit=0 -> 400 (must be positive integer)
    results.append(_run_one(
        "Edge: limit=0 -> 400",
        cfg.url, {"action": "findings", "limit": "0"},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=400,
    ))

    # Invalid date format -> 400
    results.append(_run_one(
        "Edge: invalid date format -> 400",
        cfg.url, {"action": "findings", "date": "not-a-date"},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=400,
    ))

    # Negative days -> 400
    results.append(_run_one(
        "Edge: negative days -> 400",
        cfg.url, {"action": "findings", "days": "-5"},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=400,
    ))

    # Track A Phase 1: limit is now capped at 1000. limit at-cap should pass,
    # limit above-cap should 400 with a clear "must be <= 1000" message.
    results.append(_run_one(
        "Edge: limit at cap (1000) -> 200",
        cfg.url, {"action": "findings", "limit": "1000"},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=200,
    ))
    results.append(_run_one(
        "Edge: limit above cap (9999) -> 400",
        cfg.url, {"action": "findings", "limit": "9999"},
        api_key=cfg.api_key, timeout=cfg.timeout,
        expect_status=400,
    ))

    return results


# ---------------------------------------------------------------------------
# Suite dispatcher
# ---------------------------------------------------------------------------
SUITES = {
    "auth": suite_auth,
    "basic": suite_basic,
    "filters": suite_filters,
    "combined": suite_combined,
    "edge": suite_edge,
}

SUITE_ORDER = ["auth", "basic", "filters", "combined", "edge"]


def run_suites(cfg: argparse.Namespace) -> list[TestResult]:
    """Run selected suites and return all results."""
    all_results: list[TestResult] = []

    if cfg.suite == "all":
        names = SUITE_ORDER
    else:
        names = [cfg.suite]

    for name in names:
        fn = SUITES[name]
        header = f"  Suite: {name.upper()}  "
        print(f"\n{_C.CYAN}{_C.BOLD}{'=' * 60}")
        print(f"{header:^60}")
        print(f"{'=' * 60}{_C.RESET}\n")
        results = fn(cfg)
        for r in results:
            _print_result(r, verbose=cfg.verbose)
        all_results.extend(results)

    return all_results


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
def _print_summary(results: list[TestResult]) -> None:
    passed  = sum(1 for r in results if r.status == Status.PASS)
    failed  = sum(1 for r in results if r.status == Status.FAIL)
    skipped = sum(1 for r in results if r.status == Status.SKIP)
    total   = len(results)

    print(f"\n{_C.BOLD}{'=' * 60}")
    print(f"  SUMMARY")
    print(f"{'=' * 60}{_C.RESET}")
    print(
        f"  Total: {total}   "
        f"{_C.PASS}Passed: {passed}{_C.RESET}   "
        f"{_C.FAIL}Failed: {failed}{_C.RESET}   "
        f"{_C.SKIP}Skipped: {skipped}{_C.RESET}"
    )

    if failed:
        print(f"\n  {_C.FAIL}{_C.BOLD}Failed tests:{_C.RESET}")
        for r in results:
            if r.status == Status.FAIL:
                detail = f" -- {r.detail}" if r.detail else ""
                print(f"    {_C.FAIL}- {r.name}{detail}{_C.RESET}")

    if skipped:
        print(f"\n  {_C.SKIP}Skipped tests:{_C.RESET}")
        for r in results:
            if r.status == Status.SKIP:
                detail = f" -- {r.detail}" if r.detail else ""
                print(f"    {_C.SKIP}- {r.name}{detail}{_C.RESET}")

    avg_ms = sum(r.elapsed_ms for r in results) / max(total, 1)
    max_ms = max((r.elapsed_ms for r in results), default=0)
    print(f"\n  {_C.DIM}Avg response: {avg_ms:,.0f} ms   Max: {max_ms:,.0f} ms{_C.RESET}")
    print()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Comprehensive test script for the Arboryx Admin API backend.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Environment variables (fallbacks for CLI args):\n"
            "  ARBORYX_ADMIN_API_URL   -> --url\n"
            "  ARBORYX_ADMIN_API_KEY   -> --api-key\n"
        ),
    )

    p.add_argument(
        "--url", "-u",
        default=os.environ.get("ARBORYX_ADMIN_API_URL"),
        help="API base URL (or set ARBORYX_ADMIN_API_URL env var)",
    )
    p.add_argument(
        "--api-key", "-k",
        default=os.environ.get("ARBORYX_ADMIN_API_KEY"),
        help="API key for authenticated requests (or set ARBORYX_ADMIN_API_KEY env var)",
    )
    p.add_argument(
        "--read-only-key",
        default=os.environ.get("ARBORYX_ADMIN_READ_ONLY_API_KEY"),
        help="Read-only API key for tier tests (or set ARBORYX_ADMIN_READ_ONLY_API_KEY env var)",
    )
    p.add_argument(
        "--category", "-c",
        default="Robotics",
        help="Category to test with (default: Robotics)",
    )
    p.add_argument(
        "--days", "-d",
        type=int,
        default=7,
        help="Number of days for time-range filter tests (default: 7)",
    )
    p.add_argument(
        "--date",
        default=date.today().strftime("%Y-%m-%d"),
        help="Exact date for date filter tests (default: today, YYYY-MM-DD)",
    )
    p.add_argument(
        "--limit-min",
        type=int,
        default=5,
        help="Minimum limit to sweep in filter tests (default: 5)",
    )
    p.add_argument(
        "--limit-max",
        type=int,
        default=25,
        help="Maximum limit to sweep in filter tests (default: 25)",
    )
    p.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Show full response bodies (truncated to 500 chars)",
    )
    p.add_argument(
        "--suite",
        choices=["all", "auth", "basic", "filters", "combined", "edge"],
        default="all",
        help="Which test suite to run (default: all)",
    )
    p.add_argument(
        "--timeout",
        type=int,
        default=30,
        help="Request timeout in seconds (default: 30)",
    )

    return p


# ---------------------------------------------------------------------------
# Log persistence
# ---------------------------------------------------------------------------
LOG_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "run-logs")


def _save_log(results: list[TestResult], cfg: argparse.Namespace) -> str:
    """Save test results as a JSON file in dev-utils/run-logs/."""
    os.makedirs(LOG_DIR, exist_ok=True)

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"test_run_{ts}.json"
    filepath = os.path.join(LOG_DIR, filename)

    passed = sum(1 for r in results if r.status == Status.PASS)
    failed = sum(1 for r in results if r.status == Status.FAIL)
    skipped = sum(1 for r in results if r.status == Status.SKIP)

    log = {
        "timestamp": datetime.now().isoformat(),
        "config": {
            "url": cfg.url,
            "suite": cfg.suite,
            "category": cfg.category,
            "days": cfg.days,
            "date": cfg.date,
            "limit_min": cfg.limit_min,
            "limit_max": cfg.limit_max,
            "timeout": cfg.timeout,
        },
        "summary": {
            "total": len(results),
            "passed": passed,
            "failed": failed,
            "skipped": skipped,
            "avg_ms": round(sum(r.elapsed_ms for r in results) / max(len(results), 1), 1),
            "max_ms": round(max((r.elapsed_ms for r in results), default=0), 1),
        },
        "results": [
            {
                "name": r.name,
                "status": r.status.value,
                "url": r.url,
                "http_status": r.http_status,
                "elapsed_ms": round(r.elapsed_ms, 1),
                "result_count": r.result_count,
                "detail": r.detail or None,
            }
            for r in results
        ],
    }

    with open(filepath, "w") as f:
        json.dump(log, f, indent=2)

    return filepath


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = _build_parser()
    cfg = parser.parse_args()

    if not cfg.url:
        parser.error(
            "API URL is required. Pass --url or set ARBORYX_ADMIN_API_URL."
        )

    # Strip trailing slash for consistent URL building
    cfg.url = cfg.url.rstrip("/")

    print(f"\n{_C.BOLD}Arboryx Admin API Test Runner{_C.RESET}")
    print(f"  {_C.DIM}URL:{_C.RESET}       {cfg.url}")
    print(f"  {_C.DIM}API Key:{_C.RESET}   {'***' + cfg.api_key[-4:] if cfg.api_key and len(cfg.api_key) > 4 else '(not set)'}")
    print(f"  {_C.DIM}Suite:{_C.RESET}     {cfg.suite}")
    print(f"  {_C.DIM}Category:{_C.RESET}  {cfg.category}")
    print(f"  {_C.DIM}Days:{_C.RESET}      {cfg.days}")
    print(f"  {_C.DIM}Date:{_C.RESET}      {cfg.date}")
    print(f"  {_C.DIM}Limit:{_C.RESET}     {cfg.limit_min}-{cfg.limit_max}")
    print(f"  {_C.DIM}Timeout:{_C.RESET}   {cfg.timeout}s")
    print(f"  {_C.DIM}Verbose:{_C.RESET}   {cfg.verbose}")

    results = run_suites(cfg)
    _print_summary(results)

    logfile = _save_log(results, cfg)
    print(f"  {_C.DIM}Log saved:{_C.RESET} {logfile}\n")

    failed = any(r.status == Status.FAIL for r in results)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
