#!/usr/bin/env python3
"""dev-utils/sync_gcs_to_firestore.py — diff/merge GCS JSON → Firestore.

Reads gs://<bucket>/<DATA_BLOB> (the master findings log produced by the
arboryx.ai pipeline) and applies the minimal set of Firestore writes to
make the `findings/` collection match. Idempotent: re-running with no
upstream changes is a no-op (zero writes, zero cost).

Diff strategy:
    Each entry's content fields are SHA256-hashed (16 hex chars). The
    hash is stored on the Firestore doc as `_hash`. On sync:
      - GCS-only entry_id        -> upsert (create)
      - hash mismatch (in both)  -> upsert (update)
      - Firestore-only entry_id  -> delete (entry was dedup'd / removed
                                   upstream; we mirror the deletion)

Auth:
    Uses Application Default Credentials. Two ways to get them:
      1. `gcloud auth application-default login` (interactive, recommended
         for ad-hoc sync runs)
      2. service_account.json + GOOGLE_APPLICATION_CREDENTIALS env var
         (set by dev-utils/make_dev_env_ready.sh)

Usage:
    python3 dev-utils/sync_gcs_to_firestore.py
    python3 dev-utils/sync_gcs_to_firestore.py --dry-run
    python3 dev-utils/sync_gcs_to_firestore.py --verbose
    python3 dev-utils/sync_gcs_to_firestore.py --force-rewrite   # rewrite all
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_FILE = REPO_ROOT / "arboryx_admin_backend.config"
COLLECTION = "findings"
BATCH_SIZE = 500  # Firestore hard limit per batch

# Fields that participate in the content hash. Adding a field here will
# cause every existing doc to be re-upserted on the next sync (intentional
# — it's the migration path when the schema grows).
HASH_FIELDS = (
    "entry_id",
    "timestamp",
    "category",
    "finding",
    "sentiment_takeaways",
    "guidance_play",
    "price_levels",
    "source_url",
    "tooltip",
)

# ANSI helpers (TTY only)
_TTY = sys.stdout.isatty()
def _c(code: str, s: str) -> str:
    return f"\033[{code}m{s}\033[0m" if _TTY else str(s)
HDR  = lambda s: _c("1",   s)
OK   = lambda s: _c("32",  s)
INFO = lambda s: _c("36",  s)
WARN = lambda s: _c("33",  s)
ERR  = lambda s: _c("31",  s)
DIM  = lambda s: _c("2",   s)


def _load_config() -> dict:
    """Parse the bash-style config file into a dict of KEY=VALUE pairs.
    Only handles the simple `KEY="value"` / `KEY=value` shape we use.
    """
    if not CONFIG_FILE.exists():
        print(ERR(f"Config not found: {CONFIG_FILE}"), file=sys.stderr)
        print(ERR("Copy from .example and populate before running."), file=sys.stderr)
        sys.exit(1)
    out = {}
    for line in CONFIG_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip().strip('"').strip("'")
        out[key.strip()] = value
    return out


def _hash_entry(entry: dict) -> str:
    """Stable content hash. Only HASH_FIELDS contribute — extra fields like
    `_synced_at` are deliberately excluded so server-side metadata can
    change without churning the diff.
    """
    parts = []
    for field in HASH_FIELDS:
        v = entry.get(field, "")
        parts.append(f"{field}={v}")
    blob = "\x1f".join(parts)  # unit-separator — won't collide with content
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()[:16]


def _read_gcs(bucket_name: str, blob_name: str) -> tuple[list, int]:
    """Returns (entries, generation)."""
    from google.cloud import storage
    client = storage.Client()
    blob = client.bucket(bucket_name).blob(blob_name)
    if not blob.exists():
        return [], 0
    blob.reload()
    data = json.loads(blob.download_as_text())
    if not isinstance(data, list):
        raise SystemExit(ERR(f"GCS blob is not a JSON array — got {type(data).__name__}"))
    return data, blob.generation


def _read_firestore(db, verbose: bool) -> dict:
    """Returns {entry_id: {"data": {...}, "hash": "<hex>"}} for every doc
    in the findings/ collection.
    """
    out = {}
    if verbose:
        print(INFO(f"Streaming existing Firestore /{COLLECTION} ..."))
    n = 0
    for doc in db.collection(COLLECTION).stream():
        d = doc.to_dict() or {}
        out[doc.id] = {"data": d, "hash": d.get("_hash")}
        n += 1
    if verbose:
        print(DIM(f"  read {n} existing docs."))
    return out


def _commit_in_batches(db, ops, label: str, dry_run: bool):
    """Apply a list of (kind, doc_id, payload?) tuples in chunks of BATCH_SIZE.
    kind in {'set', 'delete'}.
    """
    if not ops:
        return
    if dry_run:
        print(DIM(f"  [dry-run] would commit {len(ops)} {label} op(s) "
                  f"in {(len(ops) + BATCH_SIZE - 1) // BATCH_SIZE} batch(es)."))
        return
    for i in range(0, len(ops), BATCH_SIZE):
        chunk = ops[i:i + BATCH_SIZE]
        batch = db.batch()
        for op in chunk:
            doc_ref = db.collection(COLLECTION).document(op[1])
            if op[0] == "set":
                batch.set(doc_ref, op[2])
            elif op[0] == "delete":
                batch.delete(doc_ref)
        batch.commit()
        print(DIM(f"  committed batch {i // BATCH_SIZE + 1} "
                  f"({len(chunk)} {label} ops)"))


def main():
    parser = argparse.ArgumentParser(
        description="Sync GCS findings JSON → Firestore (diff-merge, idempotent).")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print the diff plan but make no writes.")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Print per-doc decisions.")
    parser.add_argument("--force-rewrite", action="store_true",
                        help="Re-upsert every entry, ignoring hash equality. "
                             "Useful after changing HASH_FIELDS.")
    args = parser.parse_args()

    cfg = _load_config()
    project_id = cfg.get("PROJECT_ID")
    bucket = cfg.get("STORAGE_BUCKET")
    data_blob = os.environ.get("DATA_BLOB", "market_findings_log.json")
    if not project_id or not bucket:
        print(ERR("PROJECT_ID and STORAGE_BUCKET must be set in arboryx_admin_backend.config."),
              file=sys.stderr)
        sys.exit(1)

    print()
    print(HDR("============================================"))
    print(HDR("  GCS → Firestore Sync"))
    print(HDR("============================================"))
    print(f"  Project    : {project_id}")
    print(f"  Source     : gs://{bucket}/{data_blob}")
    print(f"  Target     : firestore /{COLLECTION}")
    if args.dry_run:
        print(WARN("  Mode       : DRY RUN — no writes will be applied."))
    if args.force_rewrite:
        print(WARN("  Mode       : FORCE REWRITE — every entry will be re-upserted."))
    print()

    # Read both sides
    t0 = time.time()
    print(INFO("Reading GCS master log..."))
    gcs_entries, gcs_gen = _read_gcs(bucket, data_blob)
    print(DIM(f"  {len(gcs_entries)} entries, generation {gcs_gen} "
              f"({time.time() - t0:.2f}s)"))

    # Index GCS entries by entry_id (skip rows missing one — they can't sync)
    gcs_by_id: dict[str, dict] = {}
    skipped = 0
    for entry in gcs_entries:
        eid = entry.get("entry_id")
        if not eid:
            skipped += 1
            continue
        if eid in gcs_by_id and args.verbose:
            print(WARN(f"  duplicate entry_id in GCS: {eid} (last wins)"))
        gcs_by_id[eid] = entry
    if skipped:
        print(WARN(f"  skipped {skipped} GCS entries with no entry_id"))

    # Firestore client (lazy import — keeps --help working without the dep)
    try:
        from google.cloud import firestore
    except ImportError:
        print(ERR("google-cloud-firestore is not installed."), file=sys.stderr)
        print(ERR("Install with:  pip3 install google-cloud-firestore"), file=sys.stderr)
        sys.exit(1)
    print(INFO("Connecting to Firestore..."))
    db = firestore.Client(project=project_id)
    fs_existing = _read_firestore(db, verbose=args.verbose)

    gcs_ids = set(gcs_by_id.keys())
    fs_ids = set(fs_existing.keys())

    # Compute deltas
    upsert_ops = []
    delete_ops = []
    new_count = changed_count = same_count = 0

    for eid in gcs_ids:
        entry = gcs_by_id[eid]
        new_hash = _hash_entry(entry)
        existing = fs_existing.get(eid)
        is_new = existing is None
        if is_new:
            new_count += 1
            reason = "new"
        elif args.force_rewrite or existing["hash"] != new_hash:
            changed_count += 1
            reason = "changed" if not args.force_rewrite else "force"
        else:
            same_count += 1
            if args.verbose:
                print(DIM(f"  same   {eid}"))
            continue
        payload = dict(entry)
        payload["_hash"] = new_hash
        payload["_synced_at"] = firestore.SERVER_TIMESTAMP
        upsert_ops.append(("set", eid, payload))
        if args.verbose:
            print(OK(f"  {reason:>7} {eid}"))

    for eid in fs_ids - gcs_ids:
        delete_ops.append(("delete", eid))
        if args.verbose:
            print(ERR(f"  delete  {eid}"))

    # Summary
    print()
    print(HDR("--- Plan ---"))
    print(f"  GCS entries        : {len(gcs_ids)}")
    print(f"  Firestore entries  : {len(fs_ids)}")
    print(f"  Upsert (new)       : {OK(str(new_count))}")
    print(f"  Upsert (changed)   : {WARN(str(changed_count)) if changed_count else '0'}")
    print(f"  Delete             : {ERR(str(len(delete_ops))) if delete_ops else '0'}")
    print(f"  Unchanged          : {DIM(str(same_count))}")
    print()

    # Apply
    if not upsert_ops and not delete_ops:
        print(OK("Already in sync. No writes needed."))
        return

    print(HDR("--- Applying ---"))
    _commit_in_batches(db, upsert_ops, "upsert", args.dry_run)
    _commit_in_batches(db, delete_ops, "delete", args.dry_run)

    print()
    elapsed = time.time() - t0
    if args.dry_run:
        print(WARN(f"Dry run complete in {elapsed:.2f}s — nothing written."))
    else:
        print(OK(f"Sync complete in {elapsed:.2f}s "
                f"({len(upsert_ops)} upserts, {len(delete_ops)} deletes)."))


if __name__ == "__main__":
    main()
