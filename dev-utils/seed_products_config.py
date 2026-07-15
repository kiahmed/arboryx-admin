#!/usr/bin/env python3
"""dev-utils/seed_products_config.py — seed the shared products catalog doc.

Writes the world-readable product-catalog entry that the public frontend and
the (future) entitlement backend both key off:

    config/products/items/arboryx = {
        productId:   "arboryx",
        displayName: "Arboryx",
        tier:        1,
        gateEnabled: false,          # Phase-1: membership recorded, gate OFF
        updatedAt:   <server ts>,
    }

This is metadata, NOT a per-user entitlement — it never touches users/*. It is
written server-side (Admin SDK bypasses security rules) so the value cannot be
forged from the browser. Idempotent: re-running just refreshes updatedAt.

Auth: Application Default Credentials. For an unattended run point
GOOGLE_APPLICATION_CREDENTIALS at dev-utils/service_account.json:

    export GOOGLE_APPLICATION_CREDENTIALS=$(pwd)/dev-utils/service_account.json
    python3 dev-utils/seed_products_config.py

Usage:
    python3 dev-utils/seed_products_config.py            # write
    python3 dev-utils/seed_products_config.py --dry-run  # preview only
"""

from __future__ import annotations

import argparse
import sys

PROJECT_ID = "marketresearch-agents"
DOC_PATH = ("config", "products", "items", "arboryx")

PRODUCT_DOC = {
    "productId": "arboryx",
    "displayName": "Arboryx",
    "tier": 1,
    "gateEnabled": False,
}


def main() -> int:
    ap = argparse.ArgumentParser(description="Seed config/products/items/arboryx.")
    ap.add_argument("--dry-run", action="store_true", help="Preview, don't write.")
    ap.add_argument("--project", default=PROJECT_ID, help="GCP project id.")
    args = ap.parse_args()

    path_str = "/".join(DOC_PATH)
    print(f"  Project : {args.project}")
    print(f"  Target  : {path_str}")
    print(f"  Payload : {PRODUCT_DOC}")

    if args.dry_run:
        print("  [dry-run] no write performed.")
        return 0

    try:
        from google.cloud import firestore
    except ImportError:
        print("ERROR: google-cloud-firestore not installed "
              "(pip3 install google-cloud-firestore)", file=sys.stderr)
        return 2

    db = firestore.Client(project=args.project)
    ref = (
        db.collection(DOC_PATH[0]).document(DOC_PATH[1])
          .collection(DOC_PATH[2]).document(DOC_PATH[3])
    )
    payload = dict(PRODUCT_DOC)
    payload["updatedAt"] = firestore.SERVER_TIMESTAMP
    ref.set(payload, merge=True)
    print(f"  [OK] wrote {path_str}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
