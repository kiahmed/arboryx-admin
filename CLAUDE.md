# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is AlphaSnap UI

AlphaSnap UI is the frontend + API layer for the AlphaSnap market intelligence system. It surfaces the daily findings collected by the AlphaSnap agent pipelines (in the sibling `alphasnap/` repo) through a browser-based dashboard.

The data lives in GCS (`gs://marketresearch-agents/market_findings_log.json`) and is served to the frontend via a lightweight Cloud Function API backend.

## Architecture

### Frontend (HTML + JS)
- Single-page app, no build step — plain HTML, CSS, and vanilla JavaScript
- Multiple versioned iterations exist (`market_findings_*.html`); the latest is `market_findings_2.95.html`
- Dark theme, JetBrains Mono + Syne fonts, category-filtered card/table views
- Data loaded via fetch from the Cloud Function API or local file upload

### Backend (Cloud Function)
- `cloud_function/main.py` — Python 3.12, 2nd gen Cloud Function (HTTP trigger)
- Reads `market_findings_log.json` from GCS, serves filtered JSON
- Query params: `?action=findings|categories|health`, `&category=X`, `&days=N`, `&limit=N`
- CORS enabled for browser access
- Reuses a singleton `storage.Client` across invocations

### Configuration
- `as_backend.config` — GCP project, bucket, function name, deploy settings (mirrors `ae_config.config` pattern from alphasnap)

## Common Commands

### Deploy the API backend
```bash
bash deploy_cloud_func.sh      # Full deploy (creates function + IAM)
bash update_cloud_func.sh      # Quick source-only update
```

### Test API locally
```bash
# Requires GCP auth
export GOOGLE_APPLICATION_CREDENTIALS=dev-utils/service_account.json
python3 dev-utils/test_api_local.py
```

### Dev environment setup
```bash
bash dev-utils/make_dev_env_ready.sh
```

## Data Schema (from alphasnap)

The master findings log is a JSON array of entries:
```json
{
  "timestamp": "ISO-8601",
  "category": "Robotics",
  "finding": "...",
  "insights_sentiment": "Direct: ... | Indirect: ... | Sentiment: Bullish",
  "guidance_play": "...",
  "price_levels": "..."
}
```

Categories: Robotics, Crypto, AI Stack, Space & Defense, Power & Energy, Strategic Minerals.

## Key Dependencies
- `google-cloud-storage` — GCS reads in the Cloud Function
- GCP project: `marketresearch-agents`, bucket: `marketresearch-agents`
- No npm/node dependencies yet — frontend is dependency-free
