# AlphaSnap UI

Frontend + API layer for the AlphaSnap market intelligence system. Surfaces daily findings collected by the AlphaSnap agent pipelines through a browser-based dashboard.

## Architecture

```
                        GCS Bucket
                   (market_findings_log.json)
                            |
                            v
  Browser  --->  Cloud Function (API)  --->  GCS read
  (HTML)         Python 3.12, HTTP           singleton client
                 in-memory cache             + cache
                 API key auth
```

**API Backend** (`cloud_function/main.py`) — 2nd-gen Google Cloud Function serving filtered JSON over HTTP. Reads the master findings log from GCS, caches in memory, and exposes endpoints for findings, categories, stats, and cache management. All endpoints except health check require an API key.

**Frontend** (`market_findings_3.0.html`) — Single-file SPA with no build step. Loads data from the API in chunks on first visit, caches in `sessionStorage` for the tab lifetime, and does incremental delta refreshes. Dark theme, category tabs, search, date filtering, pagination.

### API Endpoints

| Endpoint | Auth | Description |
|---|---|---|
| `?action=health` | No | Health check |
| `?action=findings` | Yes | Findings list (supports `category`, `days`, `date`, `sort`, `limit`, `offset`) |
| `?action=categories` | Yes | List of available categories |
| `?action=stats` | Yes | Total count, per-category breakdown, date range |
| `?action=cache_status` | Yes | Cache hit/miss counts, last refresh time, TTL |
| `?action=refresh` | Yes | Force server-side cache reload from GCS |

## Setup

### Prerequisites

- Google Cloud SDK (`gcloud`, `gsutil`)
- Python 3.12+
- GCP service account key with Storage Object Viewer access

### 1. Clone and configure

```bash
# Copy example configs and fill in your values
cp as_backend.config.example as_backend.config
cp ui_config.config.example ui_config.config
```

`as_backend.config` — GCP project, bucket, function name, API key, deploy settings.

`ui_config.config` — UI filename, API URL, and API key (injected at deploy time).

### 2. Dev environment

```bash
# Place your service account key
cp /path/to/your/service_account.json dev-utils/

# Activate GCP auth
bash dev-utils/make_dev_env_ready.sh
```

## Testing

### Local (server-side, no deploy needed)

Runs the cloud function handler directly in-process against GCS:

```bash
export GOOGLE_APPLICATION_CREDENTIALS=dev-utils/service_account.json
python3 dev-utils/test_api_local.py
```

Includes a timestamp format diagnostic that validates the `stats` endpoint returns correct date ranges.

### Remote (client-side, against deployed API)

Full test suite against a live endpoint — auth, basic endpoints, filters, combined queries, edge cases:

```bash
python3 dev-utils/test_api.py \
  --url https://YOUR-REGION-PROJECT.cloudfunctions.net/FUNCTION-NAME \
  --api-key YOUR_KEY \
  --suite all \
  --verbose
```

Options: `--suite auth|basic|filters|combined|edge|all`, `--category`, `--days`, `--date`.

Results are saved to `dev-utils/run-logs/`.

## Deploy

### API Backend

```bash
# Source-only update (auto-detects existing function)
bash deploy_cloud_func.sh

# Full redeploy (infra + IAM + source)
bash deploy_cloud_func.sh --full

# Preview without changes
bash deploy_cloud_func.sh --dry-run
```

Reads all settings from `as_backend.config`.

### UI Frontend

```bash
# Deploy to GCS with API key/URL injection
bash deploy_ui.sh

# Preview without changes
bash deploy_ui.sh --dry-run
```

The deploy script injects `API_URL` and `API_KEY` from `ui_config.config` into a temp copy of the HTML file, uploads it to GCS, and sets public read on that single object. The source file in git only contains placeholders.

## Project Structure

```
alphasnap-ui/
  cloud_function/
    main.py              # Cloud Function API handler
    requirements.txt     # google-cloud-storage
  dev-utils/
    test_api_local.py    # Local test (direct GCS)
    test_api.py          # Remote test (HTTP against deployed API)
    make_dev_env_ready.sh
    run-logs/            # Test result logs (gitignored)
  market_findings_3.0.html  # Frontend SPA (placeholders, no secrets)
  deploy_cloud_func.sh      # API deploy script
  deploy_ui.sh              # UI deploy script
  as_backend.config.example  # API config template
  ui_config.config.example   # UI config template
```
