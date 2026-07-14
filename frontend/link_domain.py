#!/usr/bin/env python3
"""Link the arboryx.ai apex to the Firebase Hosting site, DNS and all.

Registers `arboryx.ai` as a custom domain on the Firebase Hosting site, reads
back the A/AAAA/TXT records Firebase requires, upserts them into the Cloudflare
zone (replacing the old GCS CNAME), then polls until Firebase reports the domain
active. Idempotent — safe to re-run to re-check provisioning.

Auth: uses your gcloud user credentials (`gcloud auth print-access-token`) for
the Firebase Hosting API — no service-account key file needed. Cloudflare uses
the token in frontend/cloudflare.config.

Config (bash-sourceable .config files, parsed here):
    frontend/arboryx_frontend.config : FIREBASE_PROJECT, FIREBASE_SITE
    frontend/cloudflare.config       : CLOUDFLARE_API_TOKEN, CLOUDFLARE_ZONE_NAME

Modes:
    (default)     register domain + set DNS + poll to active
    --check       print current host/cert state; exit 0 if HOST_ACTIVE (i.e.
                  already migrated), 3 if not-yet-active, 2 if unregistered/error
    --dry-run     show what would change; make no Firebase/Cloudflare writes

Usually invoked via frontend/migrate_to_firebase.sh / `make migrate`.
"""
from __future__ import annotations

import os
import sys
import json
import time
import argparse
import subprocess
import urllib.error
import urllib.request

FB_API = "https://firebasehosting.googleapis.com/v1beta1"
CF_API = "https://api.cloudflare.com/client/v4"
SIMPLE_TYPES = {"A", "AAAA", "TXT", "CNAME"}
HERE = os.path.dirname(os.path.abspath(__file__))


def die(msg: str, code: int = 2):
    print(f"!! {msg}", file=sys.stderr)
    sys.exit(code)


# ── config parsing ──────────────────────────────────────────────────
def parse_config(path: str) -> dict:
    """Parse simple KEY=value / KEY="value" lines from a bash .config file."""
    if not os.path.isfile(path):
        die(f"{path} missing — copy the .example and fill it in")
    out: dict[str, str] = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            # strip trailing inline comment on unquoted values, then quotes
            val = val.strip()
            if val and val[0] in "\"'":
                q = val[0]
                val = val[1:].split(q, 1)[0]
            else:
                val = val.split("#", 1)[0].strip()
            out[key] = val
    return out


# ── HTTP (stdlib) ───────────────────────────────────────────────────
def _req(method: str, url: str, headers: dict, body: dict | None = None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw) if raw else {}
        except Exception:
            return e.code, {"_raw": raw}


def access_token() -> str:
    """Mint a cloud-platform access token.

    Prefers GOOGLE_APPLICATION_CREDENTIALS (a service-account key) when set, so
    ONE env var drives BOTH this script AND the `firebase` CLI (which also reads
    GOOGLE_APPLICATION_CREDENTIALS) — the two migration steps then run as the
    same identity. Falls back to your interactive gcloud user credentials.
    """
    sa = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS", "").strip()
    if sa:
        if not os.path.isfile(sa):
            die(f"GOOGLE_APPLICATION_CREDENTIALS points at a missing file: {sa}")
        try:
            from google.oauth2 import service_account
            from google.auth.transport.requests import Request as _GReq
            creds = service_account.Credentials.from_service_account_file(
                sa, scopes=["https://www.googleapis.com/auth/cloud-platform"])
            creds.refresh(_GReq())
            return creds.token
        except Exception as exc:
            die(f"Failed to mint a token from GOOGLE_APPLICATION_CREDENTIALS ({sa}): {exc}")
    try:
        tok = subprocess.check_output(
            ["gcloud", "auth", "print-access-token"], text=True).strip()
    except Exception as exc:
        die(f"`gcloud auth print-access-token` failed ({exc}). Run `gcloud auth login`.")
    if not tok:
        die("gcloud returned an empty access token — run `gcloud auth login`.")
    return tok


# ── Firebase Hosting customDomains ──────────────────────────────────
def _fb_headers(parent: str, token: str, json_body: bool = False) -> dict:
    # gcloud USER tokens must name a quota project, or the Firebase Hosting API
    # attributes the call to Google's shared gcloud project (where the API is
    # disabled) and returns 403. `parent` is "projects/<id>/sites/<site>".
    h = {"Authorization": f"Bearer {token}", "X-Goog-User-Project": parent.split("/")[1]}
    if json_body:
        h["Content-Type"] = "application/json"
    return h


def fb_get(parent: str, domain: str, token: str) -> dict | None:
    status, body = _req("GET", f"{FB_API}/{parent}/customDomains/{domain}",
                        _fb_headers(parent, token))
    if status == 404:
        return None
    if status >= 400:
        die(f"Firebase get customDomain failed [{status}]: {body}")
    return body


def fb_create(parent: str, domain: str, token: str):
    status, body = _req(
        "POST", f"{FB_API}/{parent}/customDomains?customDomainId={domain}",
        _fb_headers(parent, token, json_body=True), {})
    if status == 409:
        print(f"   customDomain {domain} already registered — reusing")
        return
    if status >= 400:
        die(f"Firebase create customDomain failed [{status}]: {body}")
    print(f"   registered customDomain {domain}")


def desired_records(cd: dict) -> list[dict]:
    out = []
    for rset in (cd.get("requiredDnsUpdates") or {}).get("desired", []):
        for rec in rset.get("records", []):
            out.append({
                "name": (rec.get("domainName") or rset.get("domainName", "")).rstrip("."),
                "type": rec.get("type", ""),
                "rdata": rec.get("rdata", ""),
            })
    return out


def fb_state(cd: dict) -> tuple[str, str, str]:
    return (cd.get("hostState", "?"), cd.get("ownershipState", "?"),
            (cd.get("cert") or {}).get("state", "?"))


# ── Cloudflare DNS ──────────────────────────────────────────────────
def cf(method: str, path: str, token: str, body: dict | None = None) -> dict:
    status, data = _req(method, f"{CF_API}{path}",
                        {"Authorization": f"Bearer {token}",
                         "Content-Type": "application/json"}, body)
    if status >= 400 or not data.get("success", False):
        die(f"Cloudflare {method} {path} failed [{status}]: {data.get('errors', data)}")
    return data


def cf_zone_id(zone_name: str, token: str) -> str:
    res = cf("GET", f"/zones?name={zone_name}", token).get("result", [])
    if not res:
        die(f"Cloudflare zone '{zone_name}' not found (or token lacks access)")
    return res[0]["id"]


def cf_upsert(zone_id: str, token: str, name: str, rtype: str, content: str, dry: bool):
    if rtype == "TXT":
        content = content.strip().strip('"')
    existing = cf("GET", f"/zones/{zone_id}/dns_records?type={rtype}&name={name}",
                  token).get("result", [])
    if any(e.get("content") == content for e in existing):
        print(f"   = {rtype:5} {name} — already set")
        return
    payload = {"type": rtype, "name": name, "content": content, "ttl": 1, "proxied": False}
    if dry:
        verb = "~ would update" if existing else "+ would create"
        print(f"   {verb} {rtype:5} {name}  {content}")
        return
    if existing:
        cf("PUT", f"/zones/{zone_id}/dns_records/{existing[0]['id']}", token, payload)
        print(f"   ~ {rtype:5} {name} — updated")
    else:
        cf("POST", f"/zones/{zone_id}/dns_records", token, payload)
        print(f"   + {rtype:5} {name} — created")


# ── main ────────────────────────────────────────────────────────────
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="report state only; exit 0 if active")
    ap.add_argument("--dry-run", action="store_true", help="no Firebase/Cloudflare writes")
    args = ap.parse_args()

    fe = parse_config(os.path.join(HERE, "arboryx_frontend.config"))
    cfg = parse_config(os.path.join(HERE, "cloudflare.config"))
    project = fe.get("FIREBASE_PROJECT") or die("FIREBASE_PROJECT not set in arboryx_frontend.config")
    site = fe.get("FIREBASE_SITE") or project
    domain = cfg.get("CLOUDFLARE_ZONE_NAME") or "arboryx.ai"   # apex == zone name
    cf_token = cfg.get("CLOUDFLARE_API_TOKEN") or die("CLOUDFLARE_API_TOKEN not set in cloudflare.config")
    parent = f"projects/{project}/sites/{site}"
    token = access_token()

    # --check: just report and signal migrated/not-migrated via exit code.
    if args.check:
        cd = fb_get(parent, domain, token)
        if cd is None:
            print(f"not-registered: {domain} is not a custom domain on '{site}'")
            return 3
        host, own, cert = fb_state(cd)
        print(f"host={host} ownership={own} cert={cert}")
        return 0 if host == "HOST_ACTIVE" else 3

    print(f"Linking {domain} → Firebase Hosting site '{site}'"
          + ("  [DRY-RUN]" if args.dry_run else ""))

    # 1. register
    print("── 1/4  Firebase: register custom domain ─────────────────────")
    if args.dry_run:
        exists = fb_get(parent, domain, token) is not None
        print(f"   would {'reuse existing' if exists else 'register'} customDomain {domain}")
    else:
        fb_create(parent, domain, token)

    # 2. read required records
    print("── 2/4  Firebase: read required DNS records ──────────────────")
    records: list[dict] = []
    for _ in range(1 if args.dry_run else 15):
        records = desired_records(fb_get(parent, domain, token) or {})
        if records or args.dry_run:
            break
        time.sleep(5)
    if not records:
        if args.dry_run:
            print("   (none yet — Firebase computes them shortly after registration)")
        else:
            die("Firebase returned no required DNS records yet — re-run shortly.", 3)
    for r in records:
        print(f"   need {r['type']:5} {r['name']}  {r['rdata']}")

    # 3. Cloudflare DNS
    print("── 3/4  Cloudflare: upsert DNS records ───────────────────────")
    zone_id = cf_zone_id(cfg.get("CLOUDFLARE_ZONE_NAME") or domain, cf_token)
    for r in records:
        if r["type"] in SIMPLE_TYPES:
            cf_upsert(zone_id, cf_token, r["name"], r["type"], r["rdata"], args.dry_run)
        else:
            print(f"   !! add this {r['type']} record by hand: {r['name']} {r['rdata']}")

    if args.dry_run:
        print("── 4/4  (dry-run — skipping activation poll) ─────────────────")
        return 0

    # 4. poll for activation
    print("── 4/4  Firebase: wait for activation ────────────────────────")
    host = own = cert = "?"
    for _ in range(20):
        host, own, cert = fb_state(fb_get(parent, domain, token) or {})
        print(f"   host={host}  ownership={own}  cert={cert}")
        if host == "HOST_ACTIVE" and cert == "CERT_ACTIVE":
            print(f"\n✅ {domain} is live on Firebase Hosting: https://{domain}")
            return 0
        time.sleep(15)
    print(f"\nDNS is in place; Firebase is still provisioning (host={host} cert={cert}).")
    print("Cert issuance can take up to ~24h. Re-run `make migrate` later to re-check.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
