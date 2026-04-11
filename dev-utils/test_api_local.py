"""Local test for the Cloud Function API handler.

Simulates HTTP requests without deploying. Reads from GCS directly.

Usage:
    # Requires GCP auth:
    #   export GOOGLE_APPLICATION_CREDENTIALS=dev-utils/service_account.json
    python3 dev-utils/test_api_local.py
"""
import os
import sys
import json

# Point to service account if available
svc_path = os.path.join(os.path.dirname(__file__), "service_account.json")
if os.path.exists(svc_path):
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = svc_path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "cloud_function"))
from main import api_handler


class FakeRequest:
    """Minimal request object matching Flask/functions-framework interface."""
    def __init__(self, args=None, method="GET"):
        self.args = args or {}
        self.method = method


def test(label, args):
    print(f"\n{'='*50}")
    print(f"  {label}")
    print(f"{'='*50}")
    req = FakeRequest(args)
    body, status, headers = api_handler(req)
    data = json.loads(body)
    print(f"  Status: {status}")
    print(f"  Response: {json.dumps(data, indent=2)[:500]}")
    return status


def test_timestamp_diagnostic():
    """Diagnose mixed timestamp formats and verify stats date_range accuracy."""
    print(f"\n{'='*60}")
    print(f"  TIMESTAMP FORMAT DIAGNOSTIC")
    print(f"{'='*60}")

    # Load data directly to inspect raw timestamps
    req = FakeRequest({"action": "findings", "limit": "99999"})
    body, status, headers = api_handler(req)
    data = json.loads(body)
    findings = data.get("findings", [])
    print(f"  Total findings loaded: {len(findings)}")

    iso_timestamps = []
    human_timestamps = []
    bad_timestamps = []

    for e in findings:
        ts = e.get("timestamp", "")
        if not ts:
            bad_timestamps.append(("EMPTY", e.get("finding", "")[:60]))
        elif ts[0].isdigit():
            iso_timestamps.append(ts)
        else:
            human_timestamps.append(ts)

    print(f"\n  ISO-format timestamps:   {len(iso_timestamps)}")
    print(f"  Human-format timestamps: {len(human_timestamps)}")
    print(f"  Empty/missing:           {len(bad_timestamps)}")

    if human_timestamps:
        unique_human = sorted(set(human_timestamps))
        print(f"\n  Unique human-readable formats ({len(unique_human)}):")
        for t in unique_human[:15]:
            print(f"    - {t}")
        if len(unique_human) > 15:
            print(f"    ... and {len(unique_human) - 15} more")

    # Now check what stats returns
    print(f"\n{'-'*60}")
    print(f"  STATS ENDPOINT RESULT")
    print(f"{'-'*60}")
    req = FakeRequest({"action": "stats"})
    body, status, headers = api_handler(req)
    stats = json.loads(body)
    date_range = stats.get("date_range", {})
    print(f"  earliest: {date_range.get('earliest')}")
    print(f"  latest:   {date_range.get('latest')}")

    # What the correct answer should be (parse all timestamps)
    from main import _normalize_timestamp
    normalized = [_normalize_timestamp(e.get("timestamp", "")) for e in findings if e.get("timestamp")]
    normalized = [n for n in normalized if n]
    normalized.sort()
    if normalized:
        print(f"\n  EXPECTED (after normalization):")
        print(f"  earliest: {normalized[0]}")
        print(f"  latest:   {normalized[-1]}")
        if date_range.get("latest") != normalized[-1] or date_range.get("earliest") != normalized[0]:
            print(f"\n  *** BUG: stats date_range does not match actual data! ***")
        else:
            print(f"\n  OK: stats date_range matches normalized data.")


if __name__ == "__main__":
    test("Health check", {"action": "health"})
    test("Categories", {"action": "categories"})
    test("Stats", {"action": "stats"})
    test("All findings (limit 3)", {"action": "findings", "limit": "3"})
    test("Robotics last 7 days", {"action": "findings", "category": "Robotics", "days": "7"})
    test_timestamp_diagnostic()
    print("\nAll tests completed.")
