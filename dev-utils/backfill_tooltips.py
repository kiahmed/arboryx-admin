#!/usr/bin/env python3
"""Backfill `tooltip` field on every entry in the master findings log.

The cloud function injects a request-time fallback tooltip (first 30 chars of
`finding`), but the master log itself stores no tooltip. This util walks every
entry, generates a smart tooltip from `sentiment_takeaways`, and writes them
back atomically to GCS (or a local file).

Generation logic is a port of `_short_subtitle` from
catalyst-knowledge-graph/src/export.py, adapted for the `|`-separated sentiment
format used in the arboryx master log:
  - Split `sentiment_takeaways` on `|` and newlines.
  - Take the first piece starting with `Direct:`, `Market Dynamics:`, or
    `Indirect:` (case-insensitive); strip the prefix.
  - Trim to 30 chars with `…` ellipsis.
  - Fall back to first 30 chars of `finding` if no marker found.

This script is idempotent — by default it only touches entries that lack a
tooltip. Use `--force` to regenerate tooltips on every entry.

Usage:
    # Dry-run scan + preview against the live GCS log (default source):
    python3 dev-utils/backfill_tooltips.py --dry-run

    # Backfill missing tooltips on the live log (interactive prompt):
    python3 dev-utils/backfill_tooltips.py

    # Backfill with no prompt (CI / scripted use):
    python3 dev-utils/backfill_tooltips.py --yes

    # Run against a local file instead of GCS:
    python3 dev-utils/backfill_tooltips.py --source path/to/findings.json

    # Regenerate tooltips on every entry, even ones that already have one:
    python3 dev-utils/backfill_tooltips.py --force

Dependencies: google-cloud-storage (already a dependency of the cloud function).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DEFAULT_BUCKET = "marketresearch-agents"
DEFAULT_OBJECT = "market_findings_log.json"
DEFAULT_GCS_URI = f"gs://{DEFAULT_BUCKET}/{DEFAULT_OBJECT}"
BACKUP_PREFIX = "backups/"

TOOLTIP_MAX_CHARS = 30
SENTIMENT_MARKERS = ("direct:", "market dynamics:", "indirect:")
_SPLIT_RE = re.compile(r"\s*\|\s*|\n")


# ---------------------------------------------------------------------------
# ANSI colours
# ---------------------------------------------------------------------------
class _C:
    _enabled = hasattr(sys.stdout, "isatty") and sys.stdout.isatty()
    PASS  = "\033[92m" if _enabled else ""
    FAIL  = "\033[91m" if _enabled else ""
    WARN  = "\033[93m" if _enabled else ""
    BOLD  = "\033[1m"  if _enabled else ""
    DIM   = "\033[2m"  if _enabled else ""
    CYAN  = "\033[96m" if _enabled else ""
    RESET = "\033[0m"  if _enabled else ""


# ---------------------------------------------------------------------------
# Tooltip generation
# ---------------------------------------------------------------------------
def _truncate(text: str, max_chars: int = TOOLTIP_MAX_CHARS) -> str:
    """Trim to max_chars with '…' ellipsis if truncated."""
    text = (text or "").strip()
    if len(text) > max_chars:
        return text[:max_chars].rstrip() + "…"
    return text


def generate_tooltip(entry: dict) -> str:
    """Compute a tooltip for an entry from its sentiment_takeaways.

    Falls back to truncated `finding` if no Direct/Indirect/Market Dynamics
    line is found.
    """
    st = entry.get("sentiment_takeaways") or ""
    for piece in _SPLIT_RE.split(st):
        piece = piece.strip()
        if not piece:
            continue
        lower = piece.lower()
        for marker in SENTIMENT_MARKERS:
            if lower.startswith(marker):
                text = piece.split(":", 1)[1].strip() if ":" in piece else piece
                return _truncate(text)
    # Fallback to first chars of `finding`
    return _truncate(entry.get("finding") or "")


# ---------------------------------------------------------------------------
# Source IO
# ---------------------------------------------------------------------------
def _is_gcs_uri(source: str) -> bool:
    return source.startswith("gs://")


def _parse_gcs_uri(uri: str) -> tuple[str, str]:
    if not uri.startswith("gs://"):
        raise ValueError(f"Not a gs:// URI: {uri}")
    rest = uri[5:]
    bucket, _, obj = rest.partition("/")
    if not bucket or not obj:
        raise ValueError(f"Malformed gs:// URI: {uri}")
    return bucket, obj


def load_entries(source: str) -> list[dict]:
    if _is_gcs_uri(source):
        from google.cloud import storage  # local import — heavy
        bucket, obj = _parse_gcs_uri(source)
        client = storage.Client()
        blob = client.bucket(bucket).blob(obj)
        return json.loads(blob.download_as_text())
    return json.loads(Path(source).read_text())


def save_entries_local(path: Path, entries: list[dict]) -> None:
    path.write_text(json.dumps(entries, indent=2, ensure_ascii=False))


def save_entries_gcs(uri: str, entries: list[dict]) -> None:
    from google.cloud import storage
    bucket, obj = _parse_gcs_uri(uri)
    client = storage.Client()
    blob = client.bucket(bucket).blob(obj)
    blob.upload_from_string(
        json.dumps(entries, indent=2, ensure_ascii=False),
        content_type="application/json",
    )


def backup_gcs(uri: str) -> str:
    """Copy the current blob to backups/<stem>.backup-<ts>.json. Returns the backup URI."""
    from google.cloud import storage
    bucket, obj = _parse_gcs_uri(uri)
    client = storage.Client()
    src = client.bucket(bucket).blob(obj)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup_obj = f"{BACKUP_PREFIX}{Path(obj).stem}.backup-{stamp}.json"
    client.bucket(bucket).copy_blob(src, client.bucket(bucket), backup_obj)
    return f"gs://{bucket}/{backup_obj}"


# ---------------------------------------------------------------------------
# Pretty print
# ---------------------------------------------------------------------------
def _print_scan(entries: list[dict], force: bool) -> tuple[list[int], dict]:
    """Print scan summary; return (target_indices, stats)."""
    total = len(entries)
    targets: list[int] = []
    by_cat: Counter = Counter()
    for i, e in enumerate(entries):
        if force or not e.get("tooltip"):
            targets.append(i)
            by_cat[e.get("category", "Unknown")] += 1

    print(f"\n{_C.BOLD}=== Scan ==={_C.RESET}")
    print(f"  Total entries:     {total}")
    label = "to regenerate" if force else "missing tooltip"
    print(f"  Entries {label}: {_C.BOLD}{len(targets)}{_C.RESET}")
    print(f"  Already populated: {total - len(targets)}")
    if by_cat:
        print(f"\n  {_C.DIM}By category:{_C.RESET}")
        for cat, count in sorted(by_cat.items(), key=lambda x: -x[1]):
            print(f"    {cat:<22} {count}")
    return targets, dict(by_cat)


def _print_preview(entries: list[dict], targets: list[int], n: int = 5) -> None:
    """Show before/after for the first N target entries."""
    if not targets:
        return
    print(f"\n{_C.BOLD}=== Preview (first {min(n, len(targets))}) ==={_C.RESET}")
    for idx in targets[:n]:
        e = entries[idx]
        tt = generate_tooltip(e)
        st_excerpt = (e.get("sentiment_takeaways") or "")[:90]
        print(f"\n  {_C.CYAN}{e.get('entry_id', '?')}{_C.RESET}  ({e.get('category', '?')})")
        print(f"    {_C.DIM}sentiment_takeaways:{_C.RESET} {st_excerpt}…")
        print(f"    {_C.DIM}existing tooltip:{_C.RESET}    {e.get('tooltip') or '(none)'}")
        print(f"    {_C.DIM}generated tooltip:{_C.RESET}   {_C.BOLD}{tt}{_C.RESET}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "--source", "-s",
        default=DEFAULT_GCS_URI,
        help=f"Local path or gs:// URI for the master log (default: {DEFAULT_GCS_URI})",
    )
    p.add_argument(
        "--dry-run", action="store_true",
        help="Scan + preview only; do not prompt or write.",
    )
    p.add_argument(
        "--yes", "-y", action="store_true",
        help="Skip the confirmation prompt and write immediately.",
    )
    p.add_argument(
        "--force", action="store_true",
        help="Regenerate tooltips on every entry, even ones that already have one.",
    )
    p.add_argument(
        "--no-backup", action="store_true",
        help="Skip the backup copy in GCS before writing (faster; less safe).",
    )
    return p


def main() -> int:
    args = _build_parser().parse_args()

    print(f"\n{_C.BOLD}Arboryx tooltip backfill{_C.RESET}")
    print(f"  {_C.DIM}Source:{_C.RESET}   {args.source}")
    print(f"  {_C.DIM}Dry-run:{_C.RESET}  {args.dry_run}")
    print(f"  {_C.DIM}Force:{_C.RESET}    {args.force}")

    try:
        entries = load_entries(args.source)
    except Exception as exc:
        print(f"\n{_C.FAIL}[ERROR]{_C.RESET} Failed to load source: {exc}", file=sys.stderr)
        return 2

    targets, _stats = _print_scan(entries, force=args.force)
    _print_preview(entries, targets, n=5)

    if not targets:
        print(f"\n{_C.PASS}Nothing to do. All {len(entries)} entries already have tooltips.{_C.RESET}\n")
        return 0

    if args.dry_run:
        print(f"\n{_C.WARN}Dry-run — no write performed.{_C.RESET}")
        print(f"  Re-run without --dry-run to apply tooltips to {len(targets)} entries.\n")
        return 0

    if not args.yes:
        prompt = f"\nGenerate tooltips for {_C.BOLD}{len(targets)}{_C.RESET} entries and write to {args.source}? [y/N] "
        try:
            reply = input(prompt).strip().lower()
        except EOFError:
            reply = "n"
        if reply not in ("y", "yes"):
            print("Aborted. No changes made.\n")
            return 1

    # Backup (GCS only)
    if _is_gcs_uri(args.source) and not args.no_backup:
        try:
            backup_uri = backup_gcs(args.source)
            print(f"\n{_C.PASS}[BACKUP]{_C.RESET} {backup_uri}")
        except Exception as exc:
            print(f"\n{_C.FAIL}[ERROR]{_C.RESET} Backup failed: {exc}", file=sys.stderr)
            print("Aborting. Re-run with --no-backup if you want to skip the backup step.")
            return 2

    # Apply tooltips in memory
    changed = 0
    for idx in targets:
        new_tt = generate_tooltip(entries[idx])
        if entries[idx].get("tooltip") != new_tt:
            entries[idx]["tooltip"] = new_tt
            changed += 1

    # Write back
    try:
        if _is_gcs_uri(args.source):
            save_entries_gcs(args.source, entries)
        else:
            save_entries_local(Path(args.source), entries)
    except Exception as exc:
        print(f"\n{_C.FAIL}[ERROR]{_C.RESET} Write failed: {exc}", file=sys.stderr)
        return 2

    print(f"\n{_C.PASS}[OK]{_C.RESET} Wrote {changed} tooltip(s) to {args.source}.")
    print(f"  {_C.DIM}Cloud function cache will pick up the change on next ?action=refresh "
          f"or after CACHE_TTL.{_C.RESET}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
