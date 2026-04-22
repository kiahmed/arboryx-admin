# Arboryx Admin — Production Implementation Plan

> **Last updated:** 2026-04-09
> **Scope:** Phases 1-5 following Phase 0 (MVP auth, caching, pagination)
> **Team assumption:** 1-2 developers, pragmatic choices over enterprise ceremony

---

## Current State (Phase 0 — In Progress)

Phase 0 delivers the baseline API hardening on top of the existing Cloud Function:

- Static `X-API-Key` header authentication (key stored as env var)
- In-memory cache with configurable TTL (module-level dict, resets on cold start)
- New query params: `date`, `sort`, `offset`/`limit` pagination
- `?action=stats` and `?action=cache` inspection endpoints
- Parameter validation returning 400 on bad input
- Smart deploy script (auto-detect create vs update)
- Configurable test script

**What the system looks like after Phase 0:**
A single Cloud Function reading a flat JSON file from GCS, protected by a static API key, with basic caching and pagination. The frontend (`arborist_2.95.html`) still loads data from a local file or raw URL — not yet wired to the authenticated API.

---

## Target Architecture (After All Phases)

```
                          USERS
                            |
                            v
                 ┌─────────────────────┐
                 │   Cloud CDN / LB    │  <-- Phase 2: caching proxy
                 │   (HTTPS, gzip)     │
                 └────────┬────────────┘
                          │
                 ┌────────v────────────┐
                 │   Cloud Armor       │  <-- Phase 1: rate limiting + WAF
                 │   (rate limit,      │
                 │    IP allowlisting)  │
                 └────────┬────────────┘
                          │
                 ┌────────v────────────┐
                 │  API Gateway or     │  <-- Phase 1: auth gateway
                 │  Cloud Endpoints    │
                 │  (API key rotation, │
                 │   request routing)  │
                 └────────┬────────────┘
                          │
            ┌─────────────┼─────────────┐
            │             │             │
    ┌───────v──────┐      │      ┌──────v───────┐
    │  CF: prod    │      │      │  CF: staging │  <-- Phase 4
    │  arboryx-    │      │      │  arboryx-    │
    │  admin-api   │      │      │  admin-api-s │
    └───────┬──────┘      │      └──────┬───────┘
            │             │             │
    ┌───────v──────┐      │      ┌──────v───────┐
    │  Firestore   │      │      │  Firestore   │  <-- Phase 2
    │  (prod)      │      │      │  (staging)   │
    └──────────────┘      │      └──────────────┘
                          │
                 ┌────────v────────────┐
                 │  Cloud Monitoring   │  <-- Phase 3
                 │  + Cloud Logging    │
                 │  + Alerting         │
                 └─────────────────────┘
                          │
                 ┌────────v────────────┐
                 │  GitHub Actions     │  <-- Phase 4
                 │  CI/CD Pipeline     │
                 └─────────────────────┘

    Frontend (market_findings.html)     <-- Phase 5
    ├── Auth: API key from settings panel
    ├── Fetch: authenticated requests to CF
    ├── Polling: ETag-based cache revalidation
    └── Export: CSV / PDF from browser
```

---

## Phase 1 — Auth & Security Hardening

**Goal:** Replace the static API key with a real auth layer, lock down CORS, and eliminate secrets from environment variables.

**Why now:** Phase 0's `X-API-Key` in an env var is a fine starting point but has no rotation mechanism, no per-client scoping, and the key is visible in `gcloud functions describe` output. This phase closes those gaps before any external users touch the API.

### Deliverables

#### 1.1 Secret Manager for API Keys

Move the API key from a Cloud Function env var to GCP Secret Manager.

```python
# cloud_function/main.py — secret access at cold start
from google.cloud import secretmanager

def _get_secret(secret_id: str) -> str:
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{PROJECT_ID}/secrets/{secret_id}/versions/latest"
    return client.access_secret_version(name=name).payload.data.decode("utf-8")

_API_KEY = None
def _load_api_key():
    global _API_KEY
    if _API_KEY is None:
        _API_KEY = _get_secret("arboryx-admin-api-key")
    return _API_KEY
```

- Add `google-cloud-secret-manager>=2.18.0` to `requirements.txt`.
- Update `deploy_cloud_func.sh` to grant the service account `roles/secretmanager.secretAccessor` on the specific secret.
- Remove `--set-env-vars` entry for the API key from deploy scripts.

**Rationale:** Secret Manager gives you versioned secrets, audit logs on access, and key rotation without redeploying the function. The secret is fetched once per cold start and cached in `_API_KEY`, so there is no per-request latency penalty.

#### 1.2 API Key Rotation Support

Support multiple valid keys simultaneously by storing a JSON array in the secret:

```json
["key-v2-abc123", "key-v1-oldkey-expires-2026-05-01"]
```

The auth check validates against all keys in the array. To rotate: add the new key, update clients, then remove the old key from the secret and create a new version.

**Rationale:** Zero-downtime rotation without coordinated deploys. Avoids the complexity of a full API Gateway for a single-function API.

#### 1.3 CORS Tightening

Replace `Access-Control-Allow-Origin: *` with an allowlist:

```python
ALLOWED_ORIGINS = os.environ.get("ALLOWED_ORIGINS", "").split(",")

def _cors_headers(request):
    origin = request.headers.get("Origin", "")
    if origin in ALLOWED_ORIGINS:
        allow = origin
    else:
        allow = ALLOWED_ORIGINS[0] if ALLOWED_ORIGINS else ""
    return {
        "Access-Control-Allow-Origin": allow,
        "Access-Control-Allow-Methods": "GET, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, X-API-Key",
        "Access-Control-Max-Age": "3600",
        "Vary": "Origin",
    }
```

Set `ALLOWED_ORIGINS` as an env var during deploy (e.g., `https://arboryx.example.com,http://localhost:8080`).

**Rationale:** Wildcard CORS means any website can make authenticated requests if it knows the API key. Origin allowlisting is the minimal browser-side protection.

#### 1.4 Rate Limiting

Implement in-function rate limiting using a module-level dict (same lifecycle as the in-memory cache — resets on cold start, per-instance):

```python
import time
from collections import defaultdict

_rate_limits = defaultdict(list)  # key -> list of timestamps
RATE_LIMIT = 60        # requests per window
RATE_WINDOW = 60       # seconds

def _check_rate_limit(api_key: str) -> bool:
    now = time.time()
    _rate_limits[api_key] = [t for t in _rate_limits[api_key] if now - t < RATE_WINDOW]
    if len(_rate_limits[api_key]) >= RATE_LIMIT:
        return False
    _rate_limits[api_key].append(now)
    return True
```

Return `429 Too Many Requests` with a `Retry-After` header when the limit is exceeded.

**Why not Cloud Armor:** Cloud Armor requires a load balancer in front of the function ($18/month minimum for the forwarding rule alone). For a single-function API with a handful of clients, in-function limiting is sufficient. Revisit when there are multiple function instances sharing traffic and per-instance limits become too loose.

#### 1.5 Input Sanitization

Harden parameter parsing beyond the Phase 0 validation:

- Reject query param values longer than 200 characters.
- Reject non-ASCII characters in category names (the categories are English strings).
- Strip leading/trailing whitespace from all param values.
- Log rejected requests with the sanitized input for debugging.

#### 1.6 HTTPS Documentation

Cloud Functions 2nd gen are HTTPS-only by default (the function URL is `https://...`). No action needed, but document this in the API usage section so consumers know not to configure HTTP fallbacks.

### Definition of Done

- [ ] API key is read from Secret Manager, not env vars
- [ ] Rotating keys works: two keys valid simultaneously, remove old one, new version deployed, old key rejected
- [ ] CORS returns the requesting origin only if it is in the allowlist; returns empty/no origin otherwise
- [ ] `OPTIONS` preflight returns `Access-Control-Max-Age: 3600`
- [ ] Rate limiting returns 429 after 60 requests/minute from the same key
- [ ] Query params over 200 chars return 400
- [ ] `X-API-Key` is included in `Access-Control-Allow-Headers`
- [ ] Deploy scripts updated: SA has `secretmanager.secretAccessor`, `ALLOWED_ORIGINS` env var set
- [ ] Test script covers: valid key, invalid key, expired key, rate limit trip, oversized params, CORS origin check

---

## Phase 2 — Data Layer & Performance

**Goal:** Move off the flat JSON file so queries don't require loading the entire dataset into memory, and add a caching/compression layer.

**Why now:** The flat JSON approach works while the dataset is small (the current `market_findings_log.json` is ~550KB). But every request deserializes the full file even for single-category queries. As the agent pipelines add more categories and history, this becomes the bottleneck — both in latency and in Cloud Function memory.

### Deliverables

#### 2.1 Migrate from GCS JSON to Firestore

**Decision: Firestore (Native mode), not BigQuery.**

Rationale:
- The access pattern is simple filtered reads (by category, date range, pagination) — Firestore handles this natively with composite indexes.
- BigQuery is overkill: the data volume is thousands of rows, not millions. BigQuery's minimum query cost (10MB billed per query) and cold-start latency (~1-2s) are worse than Firestore for this use case.
- Firestore has a generous free tier (50K reads/day) that this project will stay within for a long time.
- The Cloud Function SDK already includes `google-cloud-firestore` — no new heavyweight dependency.

**Collection design:**

```
Collection: findings
Document ID: auto-generated
Fields:
  - timestamp: Timestamp (Firestore native)
  - category: string
  - finding: string
  - insights_sentiment: string
  - guidance_play: string
  - price_levels: string
  - ingested_at: Timestamp (when the agent pipeline wrote it)
```

**Indexes (composite):**
- `category ASC, timestamp DESC` — for category-filtered, date-sorted queries
- `timestamp DESC` — for "latest across all categories"

**Migration script** (`dev-utils/migrate_gcs_to_firestore.py`):
1. Read `market_findings_log.json` from GCS
2. Batch-write to Firestore (500 docs per batch, Firestore max)
3. Verify counts match
4. The GCS file remains as a backup / source-of-truth for the agent pipelines

**Agent pipeline integration:** The arboryx.ai agent pipelines currently write to GCS. Two options:
- **Option A (recommended):** Add a GCS-triggered Cloud Function that watches `market_findings_log.json` and syncs new entries to Firestore. This decouples the data pipeline from the UI backend — the agents keep writing JSON, and the sync function handles the translation.
- **Option B:** Modify the agent pipelines to write directly to Firestore. Tighter coupling but fewer moving parts.

#### 2.2 Server-Side Pagination (Cursor-Based)

Replace offset-based pagination with Firestore cursor-based pagination:

```python
# Request: GET ?action=findings&category=Robotics&limit=20&after=<cursor>
# Response includes: { "findings": [...], "next_cursor": "base64-encoded-doc-snapshot" }
```

**Why cursor-based:** Offset pagination (`OFFSET 200`) gets slower as the offset grows because Firestore still reads and discards the skipped documents. Cursor-based pagination is O(1) regardless of position. The cursor is an opaque base64-encoded string containing the last document's sort key — the client passes it back as `?after=<cursor>`.

Keep `offset` as a deprecated but functional parameter for backward compatibility with Phase 0 clients. Log a deprecation warning when it is used.

#### 2.3 Response Compression

Enable gzip for JSON responses:

```python
import gzip

def _cors_response(data, status=200, request=None):
    body = json.dumps(data)
    headers = _cors_headers(request)
    if request and "gzip" in request.headers.get("Accept-Encoding", ""):
        headers["Content-Encoding"] = "gzip"
        body = gzip.compress(body.encode("utf-8"))
    headers["Content-Type"] = "application/json"
    return (body, status, headers)
```

**Expected impact:** The findings JSON compresses well (repetitive field names, similar text patterns). Expect 70-80% reduction in transfer size.

#### 2.4 ETag Support

Add ETag headers based on a hash of the response content:

```python
import hashlib

etag = hashlib.md5(body_bytes).hexdigest()
headers["ETag"] = f'"{etag}"'

if request.headers.get("If-None-Match") == f'"{etag}"':
    return ("", 304, headers)
```

This enables the frontend to poll without transferring data when nothing has changed. Critical for Phase 5's real-time update strategy.

#### 2.5 Cloud CDN (Deferred)

**Decision: Skip Cloud CDN for now.**

Cloud CDN requires a Global External Application Load Balancer, which adds $18+/month and configuration complexity. The in-function cache from Phase 0 plus Firestore's low-latency reads are sufficient for the expected traffic (< 100 RPM). If traffic grows 10x, revisit.

Instead, set `Cache-Control: public, max-age=60` on responses so browser caches and any intermediary proxies help.

#### 2.6 Data Integrity & Backup

- Firestore daily export to GCS (`gs://marketresearch-agents/firestore-backups/`) via a scheduled Cloud Function or `gcloud firestore export`.
- The original `market_findings_log.json` continues to be written by the agent pipelines — it serves as the authoritative source.
- The GCS-to-Firestore sync function (2.1, Option A) should be idempotent: re-running it on the same data produces no duplicates. Use a deterministic document ID derived from `sha256(timestamp + category + finding[:100])`.

### Definition of Done

- [ ] Firestore collection `findings` is populated with all historical data
- [ ] Cloud Function reads from Firestore instead of GCS
- [ ] Category + date range queries use Firestore composite indexes (verify with `explain()`)
- [ ] Cursor-based pagination works: `?after=<cursor>` returns the next page, `next_cursor` is null on the last page
- [ ] Offset pagination still works but logs a deprecation warning
- [ ] Responses are gzip-compressed when `Accept-Encoding: gzip` is present
- [ ] ETag + `If-None-Match` returns 304 when data is unchanged
- [ ] `Cache-Control: public, max-age=60` is set on all responses
- [ ] GCS-to-Firestore sync function is deployed and triggers on blob changes
- [ ] Sync function is idempotent (re-running produces no duplicate documents)
- [ ] Firestore daily backup export is scheduled
- [ ] Phase 0 in-memory cache is removed (Firestore's own caching and the CDN headers replace it)
- [ ] Cold-start latency tested: < 2 seconds for first request after deploy

---

## Phase 3 — Observability & Reliability

**Goal:** Know when the system is healthy, know when it is not, and have the data to debug problems. Define what "reliable" means for this project with concrete SLOs.

**Why now:** With auth, Firestore, and a sync function, there are now three moving pieces that can fail independently. Before adding more features (CI/CD, frontend integration), establish the ability to detect and diagnose failures.

### Deliverables

#### 3.1 Structured Logging

Replace `print()` statements with `google.cloud.logging`-integrated structured logging:

```python
import logging
import google.cloud.logging

google.cloud.logging.Client().setup_logging()
logger = logging.getLogger("arboryx-admin-api")

# Structured log entry
logger.info("request_handled", extra={
    "json_fields": {
        "action": action,
        "category": category,
        "result_count": len(findings),
        "latency_ms": int((time.time() - start) * 1000),
        "cache_hit": was_cache_hit,
        "api_key_hash": hashlib.sha256(api_key.encode()).hexdigest()[:12],
    }
})
```

**Key principle:** Log the API key hash (first 12 chars of SHA-256), never the raw key. This allows correlating requests to clients without exposing secrets in logs.

Add `google-cloud-logging>=3.9.0` to `requirements.txt`.

#### 3.2 Custom Metrics

Use Cloud Monitoring custom metrics via the `google-cloud-monitoring` SDK:

| Metric | Type | Labels | Purpose |
|--------|------|--------|---------|
| `arboryx_admin/api/request_count` | Counter | `action`, `status`, `category` | Traffic and error rates |
| `arboryx_admin/api/latency_ms` | Distribution | `action`, `cache_hit` | Performance tracking |
| `arboryx_admin/api/findings_count` | Gauge | `category` | Data freshness (is the count growing?) |
| `arboryx_admin/sync/documents_written` | Counter | | Sync function throughput |
| `arboryx_admin/sync/last_success` | Gauge | | Sync recency |

**Pragmatic alternative:** Rather than adding `google-cloud-monitoring` as a dependency and writing custom metric descriptors, use structured logs (3.1) and create log-based metrics in Cloud Monitoring. This is zero-code — just configure it in the Cloud Console:

```
# Log-based metric: error rate
resource.type="cloud_function"
resource.labels.function_name="arboryx-admin-api"
severity>=ERROR
```

**Recommendation:** Start with log-based metrics. Only add the monitoring SDK if you need distribution metrics (latency percentiles) that log-based metrics cannot provide.

#### 3.3 Alerting

Set up Cloud Monitoring alert policies:

| Alert | Condition | Channel | Severity |
|-------|-----------|---------|----------|
| Error rate spike | > 5% of requests return 5xx over 5 minutes | Slack `#arboryx-admin-alerts` | Warning |
| Function down | Health check fails 3 consecutive times (uptime check) | Slack + email | Critical |
| Sync stale | `arboryx_admin/sync/last_success` > 24 hours ago | Slack | Warning |
| Latency degradation | p95 latency > 3s over 10 minutes | Slack | Warning |
| Cold start rate | > 50% of requests hit cold start in 15 min window | Slack | Info |

**Slack integration:** Use Cloud Monitoring's native Slack notification channel. No PagerDuty — this is a market intelligence dashboard, not a payment system. Slack is the right severity for the business impact.

#### 3.4 Health Check Upgrade

Enhance the existing `?action=health` endpoint:

```json
{
  "status": "ok",
  "timestamp": "2026-04-09T12:00:00Z",
  "checks": {
    "firestore": { "status": "ok", "latency_ms": 12 },
    "data_freshness": {
      "status": "ok",
      "latest_finding": "2026-04-09T08:30:00Z",
      "age_hours": 3.5
    }
  },
  "version": "1.2.0",
  "instance_id": "abc123"
}
```

Add an uptime check in Cloud Monitoring that hits `?action=health` every 60 seconds from 3 regions.

#### 3.5 SLO Definition

| SLO | Target | Measurement |
|-----|--------|-------------|
| Availability | 99.5% (3.6 hours downtime/month) | Uptime check success rate |
| Latency (p95) | < 1 second | Log-based latency metric |
| Data freshness | Findings < 12 hours old | Health check `age_hours` |

**Why 99.5% and not 99.9%:** This is a daily-use analytics dashboard, not a trading platform. The agent pipelines run once or twice a day. Users check it during business hours. 99.5% means at most one 20-minute outage per week during business hours, which is acceptable. The Cloud Function's built-in HA (auto-scaling, multi-zone) gives us ~99.5% for free without additional infrastructure.

**Error budget:** 3.6 hours/month. If we burn through 50% of the error budget in a week, freeze deployments and investigate.

#### 3.6 Load Testing

Use `hey` or `vegeta` for load testing (both are single-binary tools, no setup):

```bash
# Baseline: 10 concurrent users, 60 seconds
hey -z 60s -c 10 -H "X-API-Key: test-key" \
  "https://FUNCTION_URL?action=findings&category=Robotics&limit=20"
```

Document results:
- Requests/sec at 10 concurrency
- p50, p95, p99 latency
- Error rate under load
- Cold start frequency

Run this after each phase to track performance regression.

### Definition of Done

- [ ] All `print()` statements replaced with structured `logger.*()` calls
- [ ] Log entries include: action, category, result count, latency, cache hit, API key hash
- [ ] At least 3 log-based metrics created in Cloud Monitoring (error rate, request count, latency)
- [ ] Slack notification channel configured in Cloud Monitoring
- [ ] Alert policies created for: error rate, health check failure, sync staleness, latency
- [ ] Health endpoint returns Firestore connectivity and data freshness
- [ ] Uptime check configured (60s interval, 3 regions)
- [ ] SLOs documented and measurable from the Cloud Monitoring dashboard
- [ ] Load test script committed to `dev-utils/load_test.sh`
- [ ] Load test baseline results documented (save output to `dev-utils/run-logs/`)

---

## Phase 4 — CI/CD & Developer Experience

**Goal:** Eliminate manual deploys. Every merge to `main` automatically lints, tests, and deploys. A staging environment exists for pre-production validation.

**Why now:** With three functions (API, sync, backup) and growing config, manual `bash deploy_cloud_func.sh` is error-prone. Before adding frontend features (Phase 5), make the deploy pipeline trustworthy.

### Deliverables

#### 4.1 GitHub Actions Pipeline

```yaml
# .github/workflows/deploy.yml
name: Deploy Arboryx Admin API
on:
  push:
    branches: [main]
    paths:
      - 'cloud_function/**'
      - 'deploy_cloud_func.sh'
      - 'as_backend.config'
  pull_request:
    branches: [main]

jobs:
  lint-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'
      - run: pip install ruff mypy google-cloud-storage google-cloud-firestore google-cloud-secret-manager
      - run: ruff check cloud_function/
      - run: ruff format --check cloud_function/
      - run: mypy cloud_function/main.py --ignore-missing-imports
      - run: python -m pytest tests/ -v

  deploy-staging:
    needs: lint-and-test
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    environment: staging
    steps:
      - uses: actions/checkout@v4
      - uses: google-github-actions/auth@v2
        with:
          credentials_json: ${{ secrets.GCP_SA_KEY }}
      - uses: google-github-actions/setup-gcloud@v2
      - run: |
          FUNCTION_NAME="arboryx-admin-api-staging" \
          ALLOWED_ORIGINS="https://staging.arboryx.example.com" \
          bash deploy_cloud_func.sh
      - run: |
          # Smoke test staging
          URL=$(gcloud functions describe arboryx-admin-api-staging --gen2 --region=us-central1 --format='value(serviceConfig.uri)')
          STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$URL?action=health")
          if [ "$STATUS" != "200" ]; then echo "Staging health check failed"; exit 1; fi

  deploy-prod:
    needs: deploy-staging
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4
      - uses: google-github-actions/auth@v2
        with:
          credentials_json: ${{ secrets.GCP_SA_KEY }}
      - uses: google-github-actions/setup-gcloud@v2
      - run: bash deploy_cloud_func.sh
```

**Key decisions:**
- `paths` filter: only deploy when cloud function code or config changes, not on frontend HTML edits.
- Staging deploys automatically. Prod deploys use a GitHub environment with required reviewers (configure in repo settings).
- Staging smoke test gates the prod deploy.

#### 4.2 Staging Environment

Create a parallel environment:

| Resource | Production | Staging |
|----------|-----------|---------|
| Cloud Function | `arboryx-admin-api` | `arboryx-admin-api-staging` |
| Firestore DB | `(default)` | `arboryx-admin-staging` (named database) |
| Secret | `arboryx-admin-api-key` | `arboryx-admin-api-key-staging` |
| GCS backup bucket | `marketresearch-agents` | `marketresearch-agents-staging` |

The staging function reads from a staging Firestore database populated with a subset of production data (latest 30 days). A script `dev-utils/seed_staging.sh` copies data from prod Firestore to staging.

**Why not a separate GCP project:** This is a small project. Separate projects add billing complexity and IAM duplication. Named Firestore databases (available since 2024) give collection-level isolation within the same project.

#### 4.3 Infrastructure as Code (Terraform)

Adopt Terraform for the function, IAM, secrets, and monitoring resources:

```
infra/
  main.tf
  variables.tf
  outputs.tf
  environments/
    prod.tfvars
    staging.tfvars
```

Key resources:
- `google_cloudfunctions2_function` (API, sync, backup)
- `google_secret_manager_secret` + `_version`
- `google_cloud_run_service_iam_member` (invoker permissions)
- `google_monitoring_alert_policy` (from Phase 3)
- `google_monitoring_uptime_check_config`

**Rationale:** The bash deploy scripts work for one function, but with three functions, two environments, IAM bindings, secrets, and monitoring config, Terraform prevents drift and makes the staging/prod parity verifiable. Terraform over Pulumi because Terraform has better GCP provider coverage and the team does not need a general-purpose programming language for infra.

**Migration path:** Keep the bash scripts working during transition. Add Terraform alongside them, then deprecate the scripts once Terraform is verified.

#### 4.4 Pre-Commit Hooks

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.4.0
    hooks:
      - id: ruff
        args: [--fix]
      - id: ruff-format
  - repo: https://github.com/pre-commit/mirrors-mypy
    rev: v1.10.0
    hooks:
      - id: mypy
        additional_dependencies:
          - google-cloud-storage
          - google-cloud-firestore
```

Add `pyproject.toml` for ruff configuration:

```toml
[tool.ruff]
target-version = "py312"
line-length = 120

[tool.ruff.lint]
select = ["E", "F", "I", "N", "W", "UP"]
```

#### 4.5 API Documentation (OpenAPI)

Generate a minimal OpenAPI 3.0 spec from the function's actual behavior. Since the API is small (5 actions), hand-write the spec rather than adding an auto-generation framework:

```yaml
# docs/openapi.yaml
openapi: "3.0.3"
info:
  title: Arboryx Admin API
  version: "1.0.0"
paths:
  /:
    get:
      parameters:
        - name: action
          in: query
          schema:
            type: string
            enum: [findings, categories, stats, cache, health]
        - name: category
          in: query
          schema:
            type: string
        - name: days
          in: query
          schema:
            type: integer
        - name: limit
          in: query
          schema:
            type: integer
        - name: after
          in: query
          description: Cursor for pagination
          schema:
            type: string
      security:
        - apiKey: []
      responses:
        "200":
          description: Success
        "400":
          description: Invalid parameters
        "401":
          description: Missing or invalid API key
        "429":
          description: Rate limit exceeded
```

Serve the spec at `?action=docs` as a JSON response, and include a link to it in the `?action=health` response.

#### 4.6 Local Development Server

Add a `dev-utils/run_local.sh` script using `functions-framework`:

```bash
#!/bin/bash
# Run the Cloud Function locally with hot reload
pip install functions-framework watchdog 2>/dev/null
export GOOGLE_APPLICATION_CREDENTIALS=dev-utils/service_account.json
export PROJECT_ID=marketresearch-agents
export ALLOWED_ORIGINS=http://localhost:8080
cd cloud_function
functions-framework --target=api_handler --port=8080 --debug
```

This replaces the `test_api_local.py` script for interactive development. Keep the test script for CI (it does not need a running server).

### Definition of Done

- [ ] GitHub Actions workflow runs on every push to `main` and every PR
- [ ] Pipeline stages: lint (ruff) -> type check (mypy) -> test (pytest) -> deploy staging -> smoke test -> deploy prod
- [ ] Staging Cloud Function exists and is accessible with a staging API key
- [ ] Staging Firestore database is seeded with production data subset
- [ ] `infra/` Terraform configs provision all resources for both environments
- [ ] `terraform plan` shows no diff against the live infrastructure
- [ ] Pre-commit hooks installed and documented in CLAUDE.md
- [ ] `docs/openapi.yaml` describes all endpoints, parameters, and error responses
- [ ] `?action=docs` returns the OpenAPI spec as JSON
- [ ] `dev-utils/run_local.sh` starts a local server on port 8080
- [ ] Local server works with the frontend HTML (CORS configured for localhost)
- [ ] Bash deploy scripts still work (not yet removed, deprecated in favor of Terraform)

---

## Phase 5 — Frontend Integration & Feature Expansion

**Goal:** Wire the existing `arborist_2.95.html` frontend to the authenticated API, add user-facing features (export, real-time updates), and improve mobile experience.

**Why last:** The frontend is functional today with local file upload and raw URL loading. Backend hardening, observability, and CI/CD are higher priority because they reduce risk. Frontend features are user-visible polish built on a stable foundation.

### Deliverables

#### 5.1 Authenticated API Integration

Modify the frontend's `CONFIG` and `loadFromUrl` to send the API key:

```javascript
const CONFIG = {
  API_URL: 'https://arboryx-admin-api-xxxxxxxx.a.run.app',
  API_KEY: localStorage.getItem('arboryx_admin_api_key') || '',
  // ... existing fields
};

async function loadFromUrl(url) {
  const headers = {};
  if (CONFIG.API_KEY) {
    headers['X-API-Key'] = CONFIG.API_KEY;
  }
  const res = await fetch(url, {
    cache: 'no-store',
    headers: headers,
  });
  // ... existing error handling
}
```

The API key is stored in `localStorage` — acceptable because this is a single-user analytics dashboard, not a multi-tenant app with sensitive PII. The key is equivalent to a browser bookmark of a private URL.

Update `loadData()` to construct the URL from `CONFIG.API_URL` with query parameters:

```javascript
async function loadData() {
  if (state.loading) return;
  const params = new URLSearchParams({ action: 'findings' });
  if (state.cat !== 'All') params.set('category', state.cat);
  if (state.days) params.set('days', state.days);
  params.set('limit', '50');
  if (state.cursor) params.set('after', state.cursor);
  const url = `${CONFIG.API_URL}?${params}`;
  await loadFromUrl(url);
}
```

#### 5.2 Settings Panel

Add a collapsible settings panel (triggered by a gear icon in the header):

- **API URL** input (pre-filled from `CONFIG.API_URL`)
- **API Key** input (password field, stored in `localStorage`)
- **Test Connection** button (calls `?action=health`)
- **Clear Cache** button (calls `?action=cache` if the user has admin access)

Design: same dark theme, slides in from the right, uses existing CSS variables.

#### 5.3 Real-Time Updates (ETag Polling)

Implement background polling using the ETags from Phase 2:

```javascript
let _pollInterval = null;
let _lastETag = null;

function startPolling(intervalMs = 60000) {
  _pollInterval = setInterval(async () => {
    const headers = { 'X-API-Key': CONFIG.API_KEY };
    if (_lastETag) headers['If-None-Match'] = _lastETag;

    const res = await fetch(`${CONFIG.API_URL}?action=findings&limit=1`, { headers });
    if (res.status === 304) return; // no changes

    _lastETag = res.headers.get('ETag');
    // Full refresh
    await loadData();
    showToast('New findings available');
  }, intervalMs);
}
```

**Why polling with ETags and not WebSockets/SSE:** Cloud Functions are request-response only; they do not support persistent connections. ETags make the poll free (304, no body) when data has not changed. A 60-second poll interval means at most 1 lightweight request per minute per open browser tab.

A subtle status indicator in the header shows the connection state:
- Green dot: last poll succeeded, data is fresh
- Yellow dot: last poll returned a network error (will retry)
- Grey dot: polling disabled (no API key configured)

#### 5.4 Infinite Scroll / Load More

Replace the current fixed-page pagination with cursor-based "Load More":

- Initial load fetches 50 findings.
- A "Load More" button (or infinite scroll trigger) appends the next 50 using the `next_cursor` from the API response.
- Category tab switches reset the cursor and reload from the beginning.

This replaces the current client-side pagination where all data is loaded upfront.

#### 5.5 Export Functionality

Add export buttons to the results meta bar:

**CSV Export:**
```javascript
function exportCSV() {
  const rows = filtered();
  const headers = Object.keys(rows[0] || {});
  const csv = [
    headers.join(','),
    ...rows.map(r => headers.map(h => `"${String(r[h] || '').replace(/"/g, '""')}"`).join(','))
  ].join('\n');
  downloadBlob(csv, 'arboryx_findings.csv', 'text/csv');
}
```

**PDF Export:**
Use the browser's `window.print()` with a print-specific CSS stylesheet that reformats the cards into a clean printable layout. No PDF library dependency needed.

```css
@media print {
  header, .filter-bar, .meta-bar, #settings { display: none; }
  .card { break-inside: avoid; border: 1px solid #ccc; margin-bottom: 8px; }
  body { background: white; color: black; }
}
```

#### 5.6 Mobile Responsiveness

The current UI has `overflow: hidden` on body and uses fixed layouts. Improve for mobile:

- Stack the header controls vertically below 768px
- Make category tabs horizontally scrollable (not wrapping)
- Cards take full width on mobile
- Touch-friendly tap targets (minimum 44x44px)
- Source URL bar collapses into an expandable section

No framework needed — media queries in the existing `<style>` block.

#### 5.7 Multi-Tenant API Keys (If Needed)

**Decision: Defer unless there is a clear need.**

The current design assumes a single user or small team sharing one API key. If multiple teams need different access levels (e.g., one team sees only Crypto, another sees everything), implement it as:

- Secret Manager stores a JSON object mapping keys to permissions:
  ```json
  {
    "key-team-alpha": { "categories": ["*"], "rate_limit": 120 },
    "key-team-crypto": { "categories": ["Crypto"], "rate_limit": 60 }
  }
  ```
- The Cloud Function checks the key's allowed categories and filters accordingly.
- The frontend does not need to know about permissions — the API simply returns fewer results for restricted keys.

This is architecturally simple and avoids a full IAM / RBAC system.

### Definition of Done

- [ ] Frontend loads data from the Cloud Function API (not from a local file by default)
- [ ] API key is configurable from the settings panel and persisted in `localStorage`
- [ ] Settings panel has a "Test Connection" button that verifies the API URL and key
- [ ] Background polling runs every 60 seconds, uses ETags, and shows a freshness indicator
- [ ] "Load More" button fetches the next page using cursor-based pagination
- [ ] CSV export downloads all currently filtered findings
- [ ] Print/PDF export produces a clean single-column layout
- [ ] UI is usable on a 375px-wide screen (iPhone SE size)
- [ ] Category tabs scroll horizontally on mobile
- [ ] File upload still works as a fallback (no regression from Phase 0 behavior)
- [ ] New `arborist_3.0.html` committed (or the 2.95 file is updated in place — team's call)

---

## Risks & Dependencies

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Firestore costs exceed free tier** | Unexpected billing | Set a budget alert at $5/month. The free tier (50K reads/day, 20K writes/day) should cover expected usage. Monitor with billing alerts before Phase 2 goes live. |
| **Agent pipeline changes break sync** | Stale data in Firestore | The GCS-to-Firestore sync function validates the schema on each write. If a field is missing, it logs a warning and writes anyway (nullable fields). Add an alert for schema validation warnings. |
| **Cold start latency with new dependencies** | Slow first request after deploy | Each new dependency (Secret Manager, Firestore, Logging) adds cold start time. Measure after each phase. If cold start exceeds 5s, consider: minimum instances = 1 ($0.000025/s idle cost ~$2/month) or lazy-loading optional dependencies. |
| **Secret Manager adds a network call to every cold start** | Added latency, potential failure point | Cache the secret at module level (already planned). If Secret Manager is down, the function cannot authenticate anyone — this is acceptable (fail-closed is correct for auth). |
| **Terraform state management** | Lost state file = dangerous drift | Store Terraform state in a GCS backend (`gs://marketresearch-agents/terraform-state/`). Enable state locking with a Cloud Storage object lock. |
| **Frontend localStorage API key** | Key visible in browser dev tools | Acceptable risk for a single-user/small-team analytics tool. Document that this is not suitable for untrusted browser environments. If needed, upgrade to a session cookie with HTTP-only flag in a future phase. |
| **Multiple HTML file versions** | Confusion about which file is current | Phase 5 should consolidate to a single `index.html`. Archive old versions in a `legacy/` directory. |
| **GCS-to-Firestore sync latency** | Findings appear in UI minutes after agent writes them | GCS object change notifications trigger within seconds. The sync function should complete in < 10 seconds. Set the Phase 3 data freshness SLO accordingly (< 12 hours is generous). |

### External Dependencies

- **Arboryx.ai agent pipelines** (sibling repo): Continues writing to GCS. No changes required for Phase 1-4. Phase 2's sync function bridges the gap.
- **GCP services**: Cloud Functions, Firestore, Secret Manager, Cloud Monitoring, Cloud Logging. All are GA services with SLAs. No beta dependencies.
- **GitHub Actions**: Free tier provides 2,000 minutes/month for private repos. This pipeline will use ~5 minutes per run, supporting ~400 deploys/month.

### Phase Sequencing & Parallelism

```
Phase 0 (now)
    │
    v
Phase 1 (Auth)  ───────────────────┐
    │                               │
    v                               │
Phase 2 (Data Layer) ──────────┐    │
    │                          │    │
    v                          v    v
Phase 3 (Observability)   Phase 4 (CI/CD)
    │                          │
    └──────────┬───────────────┘
               v
         Phase 5 (Frontend)
```

- **Phases 1 and 2 are sequential:** Phase 2's Firestore migration changes the data layer that Phase 1's auth protects. Do auth first so the new data layer is born secure.
- **Phases 3 and 4 can overlap:** Observability and CI/CD are independent workstreams. Start CI/CD (linting, testing) while building out monitoring.
- **Phase 5 depends on all prior phases:** The frontend integration assumes the API is authenticated (1), fast (2), observable (3), and safely deployable (4).

### Estimated Timeline (1 developer, part-time)

| Phase | Estimated Effort | Calendar Time |
|-------|-----------------|---------------|
| Phase 1 | 2-3 days | Week 1-2 |
| Phase 2 | 4-5 days | Week 3-4 |
| Phase 3 | 2-3 days | Week 5 |
| Phase 4 | 3-4 days | Week 5-6 |
| Phase 5 | 4-5 days | Week 7-8 |

Total: ~6-8 weeks of part-time work to reach a fully production-hardened, CI/CD-deployed, observable, mobile-friendly dashboard.
