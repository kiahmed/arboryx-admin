/**
 * Arboryx auth — CROSS-SUBDOMAIN SSO browser suite (bug #3).
 *
 * Only meaningful on the LIVE .arboryx.ai domains: the shared session cookie is
 * Domain=.arboryx.ai, which a *.web.app preview channel cannot hold. Run AFTER
 * both apex (arboryx.ai) and robotics (robotics.arboryx.ai) are deployed to prod.
 *
 * Flow, driven in ONE Playwright browser context (email/password — Google
 * OAuth popups cannot be driven headlessly):
 *   1. Sign in on robotics.arboryx.ai (its own Firebase gate). robotics auth.js
 *      now POSTs the idToken to /__session/login, minting the .arboryx.ai cookie.
 *   2. Assert a Domain=.arboryx.ai cookie exists in the context.
 *   3. Open arboryx.ai in a NEW tab of the SAME context (no fresh sign-in). The
 *      apex bootSessionCheck() GETs /__session/me, sees the cookie, and renders
 *      the account chip WITHOUT showing the sign-in modal.
 *
 * Uses the same fixed test user as test_auth_e2e.js.
 */
const { initializeApp, applicationDefault } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { chromium } = require("@playwright/test");

const APEX = (process.env.APEX_URL || "https://arboryx.ai").replace(/\/$/, "");
const ROBOTICS = (process.env.ROBOTICS_URL || "https://robotics.arboryx.ai").replace(/\/$/, "");
const EMAIL = "arboryx-e2e@example.com";
const PASSWORD = "Arboryx-E2E-9f3kZ!pw";
const PROJECT = process.env.FIREBASE_PROJECT || "marketresearch-agents";

initializeApp({ credential: applicationDefault(), projectId: PROJECT });

const results = [];
function check(name, cond, detail) {
  results.push({ name, ok: !!cond });
  console.log((cond ? "PASS " : "FAIL ") + name + (detail ? "  [" + detail + "]" : ""));
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function ensureUser() {
  try { const u = await getAuth().getUserByEmail(EMAIL);
    await getAuth().updateUser(u.uid, { password: PASSWORD, emailVerified: true, disabled: false }); return u.uid;
  } catch (e) {
    if (e.code === "auth/user-not-found") { const u = await getAuth().createUser({ email: EMAIL, password: PASSWORD, emailVerified: true }); return u.uid; }
    throw e;
  }
}

async function main() {
  const uid = await ensureUser();
  console.log("test user uid=" + uid + "  robotics=" + ROBOTICS + "  apex=" + APEX + "\n");
  const browser = await chromium.launch();
  const context = await browser.newContext();
  const rp = await context.newPage();
  rp.on("console", (m) => { if (m.type() === "error") console.log("  [robotics console.error]", m.text()); });

  try {
    // 1. Sign in on robotics. Force its gate open immediately (return-visit flag).
    await rp.goto(ROBOTICS + "/", { waitUntil: "domcontentloaded" });
    await rp.evaluate(() => { try { localStorage.setItem("rauth.gateTripped", "1"); } catch (e) {} });
    await rp.reload({ waitUntil: "domcontentloaded" });
    const gate = await rp.waitForSelector("#rauthGate .rauth-form", { timeout: 20000 }).then(() => true).catch(() => false);
    check("robotics sign-in gate renders", gate);
    await rp.fill("#rauthEmail", EMAIL);
    await rp.fill("#rauthPassword", PASSWORD);
    await rp.click("#rauthSubmit");
    const robSignedIn = await rp.waitForSelector("#rauthUserChip:not([hidden])", { timeout: 25000 }).then(() => true).catch(() => false);
    check("robotics: signed in (user chip visible)", robSignedIn);

    // Give sessionLogin() time to POST /__session/login and Set-Cookie.
    await sleep(2500);

    // 2. The shared .arboryx.ai cookie must now exist in the context.
    const cookies = await context.cookies();
    const shared = cookies.filter((c) => (c.domain || "").endsWith("arboryx.ai") && c.domain.startsWith("."));
    check("shared Domain=.arboryx.ai cookie was minted by robotics sign-in",
      shared.length > 0, shared.map((c) => c.name + "@" + c.domain).join(", ") || "none");

    // Sanity: /__session/me from the robotics origin returns the session.
    const meRobotics = await rp.evaluate(async (base) => {
      try { const r = await fetch(base + "/__session/me", { credentials: "include", headers: { "X-Requested-With": "XMLHttpRequest" } });
        return { ok: r.ok, status: r.status }; } catch (e) { return { ok: false, err: String(e) }; }
    }, ROBOTICS);
    check("robotics /__session/me returns the session (200)", meRobotics.ok, "status=" + (meRobotics.status || meRobotics.err));

    // 3. Open the apex in the SAME context — must auto-detect WITHOUT sign-in.
    const ap = await context.newPage();
    ap.on("console", (m) => { if (m.type() === "error") console.log("  [apex console.error]", m.text()); });
    await ap.goto(APEX + "/", { waitUntil: "domcontentloaded" });
    const apexChip = await ap.waitForSelector(".aauth-account", { timeout: 20000 }).then(() => true).catch(() => false);
    check("#3 apex auto-detects the robotics session: account chip shows (no fresh sign-in)", apexChip);
    // And the blocking sign-in modal is NOT forced open.
    const modalOpen = await ap.$(".aauth-scrim:not([hidden])");
    check("#3 apex did NOT force the sign-in modal (session auto-detected)", !modalOpen);

    // apex /__session/me also sees it first-party.
    const meApex = await ap.evaluate(async (base) => {
      try { const r = await fetch(base + "/__session/me", { credentials: "include", headers: { "X-Requested-With": "XMLHttpRequest" } });
        return { ok: r.ok, status: r.status }; } catch (e) { return { ok: false, err: String(e) }; }
    }, APEX);
    check("#3 apex /__session/me returns the shared session (200)", meApex.ok, "status=" + (meApex.status || meApex.err));

    // Cleanup: clear the shared cookie so the session does not linger.
    await ap.evaluate(async (base) => { try { await fetch(base + "/__session/logout", { method: "POST", credentials: "include", headers: { "X-Requested-With": "XMLHttpRequest" } }); } catch (e) {} }, APEX);
  } catch (e) {
    check("xdomain suite ran without throwing", false, String(e && e.stack || e));
  } finally {
    await browser.close();
  }

  const failed = results.filter((r) => !r.ok);
  console.log("\n==== " + (results.length - failed.length) + "/" + results.length + " checks passed ====");
  process.exit(failed.length ? 1 : 0);
}
main().catch((e) => { console.error(e); process.exit(3); });
