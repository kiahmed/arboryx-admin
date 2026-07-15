# Robotics (`catalyst-knowledge-graph`) — Phase 2 SSO integration checklist

This repo (`arboryx-admin`) ships the shared auth function `arboryx-auth` and
the apex (`arboryx.ai`) client. To complete cross-subdomain SSO, the robotics
site at `robotics.arboryx.ai` needs the same first-party `/__session/**`
rewrite + a small client hook. **Do NOT change `catalyst-knowledge-graph` from
this PR** — this is the checklist for that repo's own PR.

Same GCP project (`marketresearch-agents`), same Firebase Auth user pool, same
`(default)` Firestore. Nothing new to deploy on the backend — robotics just
points at the already-deployed `arboryx-auth` Cloud Run service.

## 1. Firebase Hosting rewrite

`catalyst-knowledge-graph/firebase.json` — add the `/__session/**` rewrite
**before** the `**` catch-all (mirror the existing `/card/**` → `robotics-og`
`run:` rewrite already in that file):

```json
"rewrites": [
  { "source": "/card/**",     "run": { "serviceId": "robotics-og",  "region": "us-central1" } },
  { "source": "/card-img/**", "run": { "serviceId": "robotics-og",  "region": "us-central1" } },
  { "source": "/__session/**","run": { "serviceId": "arboryx-auth", "region": "us-central1" } },
  { "source": "**", "destination": "/index.html" }
]
```

Because robotics is served on `robotics.arboryx.ai`, the browser hits
`https://robotics.arboryx.ai/__session/...` first-party, and the cookie
(`Domain=.arboryx.ai`) is shared with the apex.

> The `arboryx-auth` CORS allowlist already accepts any `https://*.arboryx.ai`
> origin, so `robotics.arboryx.ai` works with no function change. If robotics
> ever gets its own preview channel that needs credentialed calls, add that
> exact origin to `_EXACT_ORIGINS` / `PREVIEW_ORIGIN` in `cloud_function_auth/main.py`.

## 2. Client hook (robotics `frontend/assets/auth.js`)

The robotics auth module already runs Firebase Auth. Add:

- **On sign-in** (inside its `onAuthStateChanged` when a user is present):
  ```js
  user.getIdToken().then(function (idToken) {
    return fetch('/__session/login', {
      method: 'POST',
      credentials: 'include',
      headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
      body: JSON.stringify({ idToken: idToken })
    });
  });
  ```

- **On boot** (before deciding signed-out UI): `GET /__session/me` with
  `credentials:'include'`. If `200`, the visitor already has a `.arboryx.ai`
  session (e.g. signed in on the apex) — render the signed-in chip and, if
  `products.robotics` is absent, offer a one-click **“Continue with your
  existing profile”** → `POST /__session/link {product:'robotics'}` (with the
  `X-Requested-With: XMLHttpRequest` header). Reconcile with Firebase's own
  `onAuthStateChanged` so you don't double-render.

- **Global sign-out**: `POST /__session/logout` (with `X-Requested-With`) +
  `firebase.auth().signOut()`. Add a `visibilitychange`/`focus` re-check that
  calls `/__session/me`; on `401`, drop to signed-out so an apex sign-out
  propagates to an open robotics tab.

`cloud_function_auth/main.py` maps `robotics → tier 1` in `PRODUCT_TIERS`, so
the link grant works out of the box. The client must NEVER write `entitlement`.

## 3. Verify

1. Sign in on `arboryx.ai`. Open `robotics.arboryx.ai` in a new tab → the chip
   should show signed-in without a fresh Firebase sign-in.
2. Click “Continue with your existing profile” on robotics → `users/{uid}`
   gains `products.robotics` + a `users/{uid}/products/robotics` subdoc.
3. Sign out on either → focus the other tab → it drops to signed-out.
