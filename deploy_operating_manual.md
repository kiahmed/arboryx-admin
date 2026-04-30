# Arboryx — Deploy & Operating Manual

> Living document. Updated as we ship. Each component has a deploy recipe,
> a verify recipe, and notes on what can go wrong.

**Last revision:** 2026-04-25

---

## 1. Project at a glance

Arboryx is a three-repo system that surfaces daily market findings across
six sectors (Robotics, Crypto, AI Stack, Space & Defense, Power & Energy,
Strategic Minerals).

| Repo | Role |
|---|---|
| `arboryx.ai/` | Pipeline that produces the master findings log (one JSON in GCS). |
| `arboryx-admin/` (**this repo**) | Admin UI + Cloud Function API + public landing. |
| `catalyst-knowledge-graph/` | Robotics-only deep analysis + knowledge graphs. Consumes the same master log. |

The master log lives at `gs://marketresearch-agents/market_findings_log.json`.

---

## 2. Components in this repo

### 2.1 Cloud Function API — `cloud_function/`
Python 3.12, 2nd-gen HTTP-triggered Cloud Function. Reads the master log
from GCS, caches in memory, serves filtered JSON. Two-tier auth:

- **Admin (write) keys** in env var `API_KEY` / `API_KEYS` — full access
  including `update`, `delete`, `refresh`.
- **Read-only keys** in env var `READ_ONLY_API_KEYS` — pass `findings`,
  `stats`, `categories`, `entry`, `health`, `cache_status`; rejected with
  403 on writes.

Function name: `arboryx-admin-api`. Runs as
`market-agent-sa@marketresearch-agents.iam.gserviceaccount.com`.

### 2.2 Admin UI — `arborist_3.2.html`
Single-file SPA. No build step. Loads from the API in chunks, caches in
sessionStorage. Edit/delete pencil + trash icons per row, modal with all
writable fields including `tooltip`. Currently the only file that uses
the admin (write) API key.

### 2.3 Public Frontend — `frontend/`
Two design variants of a public landing page on the same scaffold:

- `frontend/index.html` — dark / terminal-ops aesthetic
- `frontend/index_v2.html` — slate / AI-lab aesthetic

3-row layout (header / grove canvas / footer). 6 trees scattered on a
single SVG canvas, sector-colored, leaves placeholder (Phase 4 will
render leaves from real entries). Uses the **read-only** API key.

### 2.4 Tooltip backfill util — `dev-utils/backfill_tooltips.py`
Walks the master log, generates `tooltip` field on entries that lack it
using a port of `_short_subtitle` from
`catalyst-knowledge-graph/src/export.py`. Interactive prompt + automatic
backup before write.

---

## 3. Configs at a glance

All configs are **gitignored**; `.example` files are committed.

| Config | Purpose |
|---|---|
| `arboryx_admin_backend.config` | API project / bucket / function names + admin key + read-only key. Consumed by `cloud_function/deploy.sh`. |
| `arboryx_admin_ui.config` | Admin UI deploy target (HTML filename, API URL, admin key). Consumed by `deploy_arboryx-admin.sh`. |
| `frontend/arboryx_frontend.config` | Public frontend runtime + deploy config: API URL, **read-only** key, sector toggles, share-button toggles, brand fields, deploy targets (GCS prefix, Firebase site). Consumed by `frontend/deploy.sh`. |

> The two-key model is load-bearing: `arboryx_admin_ui.config` carries the
> **admin** key (writes allowed); `frontend/arboryx_frontend.config`
> carries the **read-only** key (writes rejected). Don't mix them.

---

## 4. Deploy recipes

### 4.1 Cloud Function API

```bash
bash cloud_function/deploy.sh                 # auto-detect: source-only update or full deploy
bash cloud_function/deploy.sh --full          # force full redeploy (re-applies IAM)
bash cloud_function/deploy.sh --dry-run       # preview gcloud command without running it
```

**Verify:**
```bash
export ARBORYX_ADMIN_API_URL=https://arboryx-admin-api-pnucidjlvq-uc.a.run.app
export ARBORYX_ADMIN_API_KEY=<admin-key-from-config>
export ARBORYX_ADMIN_READ_ONLY_API_KEY=<read-only-key-from-config>
python3 dev-utils/test_api.py --suite all
```
Expected: 39/39 pass.

**What can go wrong:**
- `API_KEY not set` warning + prompt — config is missing the key.
- `READ_ONLY_API_KEYS not set` — auth tier tests in `--suite auth` will SKIP
  but the deploy still works.

### 4.2 Admin UI

```bash
bash deploy_arboryx-admin.sh                         # injects API creds + uploads to GCS
bash deploy_arboryx-admin.sh --dry-run               # preview
```

Reads `arboryx_admin_ui.config` for the HTML filename, API URL, and admin
key. Substitutes `__ARBORYX_ADMIN_API_URL__` and
`__ARBORYX_ADMIN_API_KEY__` placeholders. Sets per-object public-read
ACL. Also uploads `assets/favicon.ico` (skips if unchanged in bucket).

**Verify:**
```bash
node dev-utils/test_ui_live.js
```
Expected: 807 entries load, schema intact.

**What can go wrong:**
- **Manual `gsutil cp` instead of `deploy_arboryx-admin.sh`** leaves placeholders
  unreplaced → page loads but every API call returns 403. Always use the
  deploy script. (This bit us once — see memory.)

### 4.3 Public Frontend (3 modes)

```bash
bash frontend/deploy.sh                   # default --local — regen scripts/config.js
bash frontend/deploy.sh --gcs             # + push to gs://marketresearch-agents/arboryx.ai/
bash frontend/deploy.sh --firebase        # + firebase deploy --only hosting:arboryx-ai
bash frontend/deploy.sh --gcs --dry-run   # preview either mode
```

Reads `frontend/arboryx_frontend.config`. Generates
`frontend/scripts/config.js` (which `landing.js` reads at runtime). For
`--gcs` and `--firebase`, also uploads.

**One-time Firebase setup:**
```bash
npm install -g firebase-tools
firebase login
firebase hosting:sites:create arboryx-ai --project marketresearch-agents
```
After that, `--firebase` mode works.

**Verify:**
```bash
# Local preview:
cd frontend && python3 -m http.server 8000
# Open http://localhost:8000/index.html or index_v2.html

# Headless smoke against live API:
node dev-utils/test_frontend_landing.js
```

**Toggling at deploy time:** edit `arboryx_frontend.config`, then run
`bash frontend/deploy.sh --local` to regenerate `config.js`. Changes that
work this way: sector on/off, share-button on/off, X handle, slogan,
LinkedIn URL, `MAX_LEAVES_PER_DAY`, `RECENCY_DAYS`, `TREE_SCALE`.

---

## 5. Maintenance recipes

### 5.1 Tooltip backfill

When `arboryx.ai` produces new entries that lack the `tooltip` field
(until Phase 2.5 ships the upstream pipeline fix), run the backfill:

```bash
python3 dev-utils/backfill_tooltips.py --dry-run   # scan + 5-entry preview
python3 dev-utils/backfill_tooltips.py             # interactive (prompts before write)
python3 dev-utils/backfill_tooltips.py --yes       # non-interactive (CI)
python3 dev-utils/backfill_tooltips.py --force     # regenerate even existing tooltips
```

The script auto-creates a timestamped backup at
`gs://marketresearch-agents/backups/market_findings_log.backup-<UTC>.json`
before writing.

After backfill, force a cache refresh on the live API so consumers see
the new field immediately:
```bash
curl -s -H "X-API-Key: <admin-key>" "<API_URL>?action=refresh"
```

### 5.2 Key rotation (Track A Phase 1 — Secret Manager is source of truth)

Three secrets, all in GCP Secret Manager:

| Secret | What it is | Consumer | Rotation source |
|---|---|---|---|
| `arboryx-admin-key` | write-enabled API key | Cloud Function `arboryx-admin-api` (env-var fallback also retained for migration safety) | Auto: quarterly via `arboryx-key-rotator` + Cloud Scheduler. Manual: `rotate_key.sh admin` |
| `arboryx-public-key` | read-only API key | Cloud Function (auth) + `frontend/scripts/config.js` (frontend bundle) | Manual only: `rotate_key.sh public` (frontend redeploy required) |
| `arboryx-smtp-pass` | Gmail app password for the reminder function | Cloud Function `arboryx-rotation-reminder` | Manual sync: `rotate_key.sh smtp` |

The Cloud Function reads ALL ENABLED versions of each secret at cold
start and accepts any of them — so adding a new version doesn't break
existing clients. Old versions get disabled after a soak window.

#### Calendar-driven (proactive)

| Key | Cadence | Action |
|---|---|---|
| **Public** | every **90–180 days** | `bash dev-utils/rotate_key.sh public` (also re-runs `frontend/deploy.sh` so `config.js` ships the new key) |
| **Admin** | auto every **quarter** (Jan/Apr/Jul/Oct 1, 09:00 NY) | nothing — Cloud Scheduler `arboryx-key-rotator-quarterly` does it |
| **Admin — disable old** | ~30 days after each rotation | nothing — auto rotator disables versions ≥30 days old on its next firing |
| **SMTP password** | only when you change it | `bash dev-utils/rotate_key.sh smtp` (idempotent — no-op if config matches Secret Manager) |

A quarterly reminder email lands in `info@solutionjet.net` (Cloud
Scheduler `arboryx-rotation-reminder-quarterly`) so the public-key
rotation window doesn't get forgotten.

#### Event-driven (reactive — rotate immediately on any of these)

- Key value appears in a public place (paste in chat, screenshot,
  accidentally committed, leaked in a bug report)
- Suspected / known compromise (unusual API logs, 429s from unexpected IPs)
- Anyone with key access leaves the team
- Audit / compliance milestone

#### `rotate_key.sh` cheat sheet

| Scenario | Command |
|---|---|
| Rotate public key (90–180 day cadence or on incident) | `bash dev-utils/rotate_key.sh public` |
| Rotate admin key off-cycle (incident, audit, staff change) | `bash dev-utils/rotate_key.sh admin` |
| Sync SMTP password after editing it in `arboryx_admin_backend.config` | `bash dev-utils/rotate_key.sh smtp` |
| Disable a leaked version sooner than 30 days | `bash dev-utils/rotate_key.sh {public\|admin\|smtp} --finalize <N>` |
| Preview without writing anything | add `--dry-run` to any of the above |

The script:
1. Generates a fresh key (or reads from config for `smtp`).
2. Adds it as a new ENABLED version in Secret Manager.
3. Updates the consumer-side config file (frontend config for `public`,
   backend config for `admin`; nothing to update for `smtp` since the
   config IS the source).
4. For `public`: prompts to re-run `bash frontend/deploy.sh` so the live
   site carries the new key.
5. Prints a `--finalize` reminder for the soak window (default 7 days
   for manual rotations; 30 days for auto-rotator's cleanup pass).

#### Soak window guidance

- **Manual rotations**: keep both versions ENABLED for ~7 days, then
  `--finalize <OLD_VER>` to disable.
- **Auto admin rotation**: keeps versions ENABLED until they're 30 days
  old, then disables on the next quarterly run.
- **Suspected leak**: skip the soak — add a new version, then
  `--finalize <LEAKED_VER>` immediately to revoke.

### 5.3 Cache management

The Cloud Function caches the master log in memory. Default TTL is 0
(cache only resets on cold start or explicit refresh).

```bash
# Inspect cache state
curl -s -H "X-API-Key: <admin-key>" "<API_URL>?action=cache_status" | python3 -m json.tool

# Force reload from GCS (admin key only — read-only keys 403)
curl -s -H "X-API-Key: <admin-key>" "<API_URL>?action=refresh"
```

---

## 6. Quick verification dashboard

Run all of these after any deploy. Expect zero failures.

```bash
# 1. API
python3 dev-utils/test_api.py --suite all                # 39 tests

# 2. Admin UI (live)
node dev-utils/test_ui_live.js                            # initialLoad + refreshDelta

# 3. Public frontend (live, read-only key)
node dev-utils/test_frontend_landing.js                   # stats fetch + paint
```

---

## 7. Living log

Newest first. Add an entry whenever ops behavior changes.

### 2026-04-25 (later) — Phase 4 grove rendering + recency-scoped stats

- Cloud Function: `?action=stats` now accepts optional `&days=N` to scope
  `total_findings`, `categories`, and `date_range` to the last N days.
  Without `days`, returns all-time stats — backward compatible. Response
  includes `days_window: N` when scoped.
- Public landing: count under each tree now reads from
  `?action=stats&days=RECENCY_DAYS` so it matches the leaves'
  recency window (e.g. `Robotics 25` for last 7d, not `Robotics 164` all-time).
- New `frontend/scripts/grove.js`: fetches recent findings, buckets by
  sector and recency-day (cap = `MAX_LEAVES_PER_DAY` = 5 default), renders
  one `<ellipse>` per entry into the per-tree `[data-leaves-for]` slot,
  colored by recency (`leaf-d0` teal → `leaf-d6` orange).
- Leaf interactions: hover triggers Web Audio chirp (sector-specific
  frequency, lazy-init on first user gesture, mute toggle in legend,
  default-muted on prefers-reduced-motion). Click shows floating tooltip
  with the entry's `tooltip` field; second click or Enter on focused
  leaf navigates to `new_growth.html?sector=…&entry=…&date=…` (Phase 5
  builds that page).
- Tree skeleton (trunk + branches + ground) stays inline as `<symbol>`;
  leaves are JS-rendered. 35 deterministic `LEAF_SLOTS` arranged so newest
  entries fill the most prominent (top-of-tree) positions first.
- Tests: `dev-utils/test_api.py` 40/40 pass; `dev-utils/test_frontend_landing.js`
  now exercises grove's data layer (per-day cap, newest-first ordering,
  recency-class clamping) end-to-end against the live API.

### 2026-04-25 — Public landing scaffold + tooltip backfill
- Cloud Function: added read-only API key tier (`READ_ONLY_API_KEYS` env
  var), `?action=entry&id=<entry_id>` endpoint, `tooltip` field on every
  finding response with fallback to truncated `finding`.
- 807/807 entries in master log backfilled with smart tooltips
  (port of `_short_subtitle` from catalyst-knowledge-graph; splits on
  `|` AND `\n`).
- Admin UI now has a `tooltip` field in the edit modal with a
  `↻ Regenerate` button that runs the same trim logic client-side.
- New `/frontend/` tree with two design variants
  (`index.html` dark, `index_v2.html` slate) and `frontend/deploy.sh`
  with `--local` / `--gcs` / `--firebase` modes.
- Two-key model now consistently applied: admin UI uses write keys,
  public frontend uses read-only keys.
- All deploy targets verified via headless smoke harnesses.

### Earlier — see git log
Pre-2026-04-25 history is in commit messages.

---

## Runbook — Cloudflare Free escalation (Track A Phase 1)

### When to flip this on

Escalate to Cloudflare Free in front of the Cloud Function if **any** of:

- API logs show sustained 429s from a small set of source IPs over 15+ min.
- A single source generates >10× normal traffic for >15 min.
- A leaked key is in active abuse and rotation alone isn't fast enough — you
  need an L7 deny rule that doesn't require a function deploy.
- The public landing gets DDoS'd (volume approaches `--max-instances=5` from
  external sources, costing Cloud Functions invocations even though we 429).

### What you get on Cloudflare Free ($0/month)

- Anycast DDoS mitigation (always-on, no config).
- Free WAF managed rules (OWASP, Cloudflare Special).
- 5 custom rate-limit rules per zone.
- Free DNS + edge caching (the static frontend gets faster too).
- TLS termination at the edge (origin sees fewer slow connections).

### Pre-flight (10 min — do this BEFORE you need it)

1. **Sign up** at `https://dash.cloudflare.com` with the production domain
   (e.g. `arboryx.ai`). Add it as a Cloudflare site. You'll re-point its
   nameservers to Cloudflare during cutover.
2. **Note the origin hostnames** that need proxying:
   - Cloud Function URL: `https://arboryx-admin-api-pnucidjlvq-uc.a.run.app`
   - Public frontend (current): `https://arboryx-ai.web.app` (or the GCS URL)
3. **Decide your CF rate-limit baseline.** Reasonable: 600 req/min per IP
   (10/sec) — well above the function's internal cap, drops abuse before it
   ever costs a Cloud Function invocation.

### Cutover (~30 min once decided)

1. **Add proxied DNS records** in Cloudflare (orange-cloud icon = proxied):
   ```
   CNAME  api.arboryx.ai    → arboryx-admin-api-pnucidjlvq-uc.a.run.app   (proxied)
   CNAME  www.arboryx.ai    → arboryx-ai.web.app                          (proxied)
   ```

2. **Add a custom rate-limit rule** (Security → WAF → Rate limiting):
   ```
   When:   (http.host eq "api.arboryx.ai")
   Then:   Block for 60 seconds
   Rate:   600 requests per 1 minute per IP
   ```

3. **Repoint consumers to the proxied hostname**:
   - `frontend/arboryx_frontend.config`:
     `ARBORYX_API_URL="https://api.arboryx.ai"`
   - `bash frontend/deploy.sh` to regenerate `scripts/config.js`.

4. **Tighten Cloud Function CORS** to the proxied origin only (so anyone
   bypassing CF and hitting the raw Cloud Run URL gets no Allow-Origin):
   - In `arboryx_admin_backend.config`:
     `ALLOWED_ORIGINS="https://arboryx.ai,https://www.arboryx.ai"`
   - `bash cloud_function/deploy.sh`

5. **Optional** — lock the function to internal-ingress so the only path is
   through Cloudflare → ALB → function. Requires a serverless NEG + Global
   Application LB (~$18/mo). Skip unless you want defense-in-depth; the WAF
   + CF rate-limit already drop most abuse.

### Roll-back (if Cloudflare misbehaves)

1. In CF DNS, click orange cloud → grey cloud (DNS-only). Removes CF from
   the path immediately.
2. Or change the CNAME back to your direct Cloud Run URL with grey cloud.
3. Revert `frontend/arboryx_frontend.config` and re-run
   `bash frontend/deploy.sh` if you also flipped the consumer-side URL.

### Verify after cutover

```bash
# Resolves through Cloudflare? Look for a cf-ray header.
curl -sI https://api.arboryx.ai/?action=health | grep -iE 'cf-ray|server'

# Rate limit kicks in beyond 600 RPM? CF should 429 before the function does.
for i in $(seq 1 700); do
  curl -s -o /dev/null -w "%{http_code} " -H "X-API-Key: <key>" \
    "https://api.arboryx.ai/?action=stats"
done
```

### Cost confirmation

- Cloudflare Free: $0/month, no card, no usage caps for the features used here.
- Cloud Functions: same pricing as before (CF reduces invocations, never adds).

