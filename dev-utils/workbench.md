# Arboryx Admin workbench — design decisions (living doc)

Captures decisions made while implementing changes in this repo. Companion to
`../arboryx.ai/dev-utils/workbench.md` (the agent-pipeline side).

Format: each decision records the options considered, trade-offs, and the
final choice. New context gets appended — do not rewrite history.

---

## 2026-04-30 — `arboryx.ai` apex served from GCS via Cloudflare

### Goal
Serve the public landing page at `https://arboryx.ai/` from a GCS-hosted
static site, fronted by Cloudflare for TLS + CDN. Replace the previous
"deploy to a sub-prefix of `marketresearch-agents` and link to the storage
URL" pattern.

### Decision B1 — proxy architecture
**Options:**
1. Cloudflare Worker that rewrites `arboryx.ai/*` → `storage.googleapis.com/marketresearch-agents/arboryx.ai/*`. Keeps the existing GCS prefix.
2. **Dedicated bucket `gs://arboryx.ai/` + apex CNAME → `c.storage.googleapis.com`.** GCS dispatches by Host header.
3. CF Transform Rules (URL Rewrite) + Origin Rule (Host override) — rewrites path on the fly without renaming the bucket.

**Chose #2.** The CF API token in the sibling project (`soljet-postiz/auth/cloudflare.yaml`) only has `Zone:DNS:Edit` scope — no Workers, no Rulesets. We probed and confirmed both alternative tokens in the file are also scope-limited. Option 1 was the cleanest if available; Option 3 is non-trivial (needs Origin Rule + Transform Rule + careful Host-header handling) and isn't the documented GCS+CF pattern. Option 2 is the standard Google-documented pattern, requires only DNS:Edit, and gives us natural separation: the public bucket holds *only* the frontend, while `marketresearch-agents` (with private findings data) stays untouched.

**Cost:** GCS gates `gcloud storage buckets create gs://<domain>` on Search Console domain ownership for the calling Google account. SAs can't own a domain. So the bucket-create step is one-time-only under a verified user account; everything after is unrestricted.

### Decision B2 — `DOMAIN_OWNER_ACCOUNT` config flag
**Problem.** Once B1 was set, day-2 deploys want to run under the project SA via ADC (matches every other deploy in this repo). But Stage 3 of the deploy script runs `gcloud storage buckets create`, which the SA can't do. Naive workaround: tell the user to switch active account before each run. Bad UX.

**Options:**
1. Always require active account = domain owner. User toggles before/after each deploy.
2. **Add `DOMAIN_OWNER_ACCOUNT` to `frontend/cloudflare.config`. Pass `--account=$DOMAIN_OWNER_ACCOUNT` *only* to the bucket-create command.** Everything else uses whatever's active (the SA in normal dev env).
3. Add the SA as a Search Console owner. Not feasible — SC ownership is bound to human Google accounts; SAs can't sign in to SC.

**Chose #2.** One-line config field, one-time bucket creation, then the field is dead until someone deletes the bucket. Subsequent deploys never touch the user account — they run end-to-end under ADC.

### Decision B3 — `frontend/deploy.sh --gcs` after the cutover
**Problem.** The pre-existing `--gcs` mode shipped to the old prefix `gs://marketresearch-agents/arboryx.ai/` and used `gsutil acl ch` for per-object public-read. After the cutover, the bucket is `gs://arboryx.ai/` with uniform-bucket-level access (per-object ACLs disabled; IAM is bucket-wide). So `--gcs` would silently write to the wrong bucket *and* its ACL line would error.

**Options:**
A. Delete `--gcs`. Force users onto `frontend/cloudflare/deploy.sh`.
B. **Make `--gcs` a thin shim:** keep Step 1 (regenerate `scripts/config.js`), then `bash frontend/cloudflare/deploy.sh --skip-verify --skip-dns`. Backwards compatible.
C. Update `--gcs` to point at the new bucket and drop `gsutil acl ch`. Two scripts overlapping.

**Chose B.** A would break muscle memory + any external scripts. C creates two near-duplicate deploy paths that drift over time. B keeps one canonical deploy (`cloudflare/deploy.sh`) and `--gcs` becomes a fast-path alias that skips one-time setup stages — exactly the right semantics for "I just want to push my latest changes."

### Lesson — `gcloud storage rsync --exclude` uses `re.match`, not `re.search`
**Real leak.** First production run of `frontend/cloudflare/deploy.sh` uploaded `cloudflare.config` (CF API token), `arboryx_frontend.config` (read-only key), `cloudflare.config.example`, `arboryx_frontend.config.example`, and `.firebaserc` to the public bucket. They were live for ~3 minutes before detection.

**Root cause.** Pattern was `\.config$|\.config\.example$|^deploy\.sh$|^cloudflare/|^firebase\.json$`. With `re.search` semantics this is correct. With `re.match` semantics (anchored at start), `\.config$` only matches a string that *starts with* `.config` — i.e., literally the string `.config`, nothing else. Patterns with leading `^` (`^deploy\.sh$`, `^cloudflare/`) worked; patterns relying on suffix-only match (`\.config$`, `\.config\.example$`) silently passed everything through.

**Fix.** `^(.*\.config|.*\.config\.example|deploy\.sh|cloudflare/.*|firebase\.json|\.firebaserc)$` — every alternative anchored from the start.

**Action items taken:**
- Deleted leaked files from bucket; verified 404 at edge.
- Rotated CF API token (user, manual via dashboard).
- Rotated public read-only API key via `bash dev-utils/rotate_key.sh public`.

**Generalized rule for future scripts:** when using gcloud's `--exclude`, write patterns assuming `re.match` (always anchor at start with `^` or `.*`). Test with `--dry-run` against a known-bad file before going live.

### Followup — CORS allowlist regression
**Bug.** First end-to-end test of `https://arboryx.ai/` rendered the chrome but the grove leaves were empty. Direct GCS URL (`https://storage.googleapis.com/arboryx.ai/index.html`) worked. Symptom screamed CORS — the page's `Origin` differs by hostname.

**Confirmed via preflight diff.** From `Origin: https://arboryx.ai` the API returned 204 with no `access-control-allow-origin` header (silent deny). From `Origin: https://storage.googleapis.com` the header came back. `_DEFAULT_ALLOWED_ORIGINS` in `cloud_function/main.py` had `storage.googleapis.com` (legacy origin) but not `arboryx.ai` (the new public origin).

**Fix.** Added `https://arboryx.ai` and `https://www.arboryx.ai` to `_DEFAULT_ALLOWED_ORIGINS`. Redeployed via `cloud_function/deploy.sh`. Re-ran preflight from both — `access-control-allow-origin` now echoed back correctly.

**Lesson.** Any time the public origin of the frontend changes, the API CORS allowlist needs to move with it. Two options for keeping these in lockstep next time:
1. Pull the public origin into a shared config (e.g. a single `PUBLIC_ORIGIN` env var that the frontend's `config.js` and the cloud function both read).
2. Drive `ALLOWED_ORIGINS` from `arboryx_admin_backend.config` instead of relying on the in-code default.

Neither is needed today — the cutover is a one-time event — but worth noting if a third frontend host (e.g., a staging domain) ever comes online.

### Result
- `https://arboryx.ai/` serves `gs://arboryx.ai/index.html` via CF (HTTP/2 200, edge cached).
- DNS: apex `A 192.0.2.1` (placeholder) replaced with `CNAME arboryx.ai → c.storage.googleapis.com` (proxied).
- IAM: bucket-wide `allUsers:objectViewer`. Bucket holds only frontend assets (no private data co-located).
- API CORS allowlist includes `arboryx.ai` + `www.arboryx.ai`; preflights pass.
- `frontend/deploy.sh --gcs` is now a 5-line shim around `frontend/cloudflare/deploy.sh --skip-verify --skip-dns`. Day-2 redeploys take ~10s.
- Firebase Hosting mode (`--firebase`) untouched and still functional.
