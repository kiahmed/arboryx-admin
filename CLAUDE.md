# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Arboryx Admin

Arboryx Admin is the frontend + API layer for the Arboryx market intelligence system. It surfaces the daily findings collected by the arboryx.ai agent pipelines (in the sibling `arboryx.ai/` repo) through a browser-based dashboard.

The data lives in GCS (`gs://marketresearch-agents/market_findings_log.json`) and is served to the frontend via a lightweight Cloud Function API backend.

## Architecture

### Frontend (HTML + JS)
- Single-page app, no build step — plain HTML, CSS, and vanilla JavaScript
- Multiple versioned iterations exist (`arborist_*.html`); current deploy target is set in `arboryx_admin_ui.config` (`UI_FILE=`)
- Dark theme, JetBrains Mono + Syne fonts, category-filtered card/table views
- Data loaded via fetch from the Cloud Function API; chunked initial load + delta refresh, session-cached per tab

### Backend (Cloud Function)
- `cloud_function/main.py` — Python 3.12, 2nd gen Cloud Function (HTTP trigger)
- Function name: `arboryx-admin-api` (see `arboryx_admin_backend.config`)
- Reads `market_findings_log.json` from GCS, serves filtered JSON
- Query params: `?action=findings|categories|stats|health|cache_status|refresh`, `&category=X`, `&days=N`, `&limit=N`, `&offset=M`, `&date=YYYY-MM-DD`, `&sort=asc|desc`
- API key auth via `X-API-Key` header (all endpoints except health + OPTIONS)
- CORS enabled for browser access
- Singleton `storage.Client` + in-memory cache across invocations

### Configuration
- `arboryx_admin_backend.config` — GCP project, bucket, function name, API key, deploy settings (gitignored; `.example` committed)
- `arboryx_admin_ui.config` — UI file, API URL, API key used by `deploy_ui.sh` for placeholder injection (gitignored; `.example` committed)

## Common Commands

### Deploy the API backend
```bash
bash deploy_cloud_func.sh            # Auto-detects update vs full deploy
bash deploy_cloud_func.sh --full     # Force full redeploy
bash deploy_cloud_func.sh --dry-run  # Preview
```

### Deploy the UI
```bash
bash deploy_ui.sh                    # Injects API creds, uploads to GCS, sets public ACL
bash deploy_ui.sh --dry-run
```

### Test the deployed API
```bash
export ARBORYX_ADMIN_API_URL=https://us-central1-marketresearch-agents.cloudfunctions.net/arboryx-admin-api
export ARBORYX_ADMIN_API_KEY=your-key-here
python3 dev-utils/test_api.py --suite all --verbose
```

### Smoke-test the UI before deploy
```bash
node dev-utils/test_ui_render.js    # Local render check against JSON
node dev-utils/test_ui_live.js      # End-to-end against live API
```

### Dev environment setup
```bash
bash dev-utils/make_dev_env_ready.sh
```

## Data Schema (from arboryx.ai)

The master findings log is a JSON array of entries:
```json
{
  "entry_id": "ROB-041926-001",
  "timestamp": "2026-04-19",
  "category": "Robotics",
  "finding": "...",
  "sentiment_takeaways": "Bullish. Direct: ... . Indirect: ... . Market Dynamics: ...",
  "guidance_play": "...",
  "price_levels": "...",
  "source_url": "..."
}
```

`entry_id` and `source_url` are present in the data but not displayed in the UI (skipped via `CONFIG.COLUMN_CONFIG`).

Categories: Robotics, Crypto, AI Stack, Space & Defense, Power & Energy, Strategic Minerals.

## Key Dependencies
- `google-cloud-storage` — GCS reads in the Cloud Function
- GCP project: `marketresearch-agents`, bucket: `marketresearch-agents` (names predate the Arboryx rename and are retained)
- No npm/node dependencies yet — frontend is dependency-free
