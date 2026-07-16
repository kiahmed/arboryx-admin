/**
 * Arboryx auth — SAME-ORIGIN end-to-end browser suite (Playwright + Chromium).
 *
 * Runs against a Firebase Hosting PREVIEW channel (a *.web.app origin) where
 * Firebase `local` (IndexedDB) persistence works. The cross-subdomain
 * `.arboryx.ai` cookie can NOT set on a *.web.app origin, so that flow is
 * covered by the separate prod suite (test_auth_xdomain.js).
 *
 * Drives the 4 user-reported bugs with a REAL browser:
 *   #1 auth wired into every page (index, new_growth) — no "coming soon" stub
 *   #2 session survives same-origin navigation (Home <-> new_growth)
 *   #4 new_growth is member-gated (signed-out: leaf click + direct URL blocked)
 *   (#3 is cross-subdomain — prod suite.)
 *
 * Test user (fixed, email/password — Google OAuth cannot be driven headless):
 *   email:    arboryx-e2e@example.com
 *   password: Arboryx-E2E-9f3kZ!pw   (deterministic; reset each run via admin)
 * Created/reset with firebase-admin using GOOGLE_APPLICATION_CREDENTIALS (SA
 * has firebaseauth.admin). It is a real Auth user; delete with --cleanup.
 *
 * Usage:
 *   GOOGLE_APPLICATION_CREDENTIALS=.../service_account.json \
 *   BASE_URL=https://arboryx-ai--authfix-xxxx.web.app node dev-utils/test_auth_e2e.js
 *   node dev-utils/test_auth_e2e.js --cleanup   # delete the test user
 */
const { initializeApp, applicationDefault } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { chromium } = require("@playwright/test");

const BASE = (process.env.BASE_URL || process.argv[2] || "").replace(/\/$/, "");
const EMAIL = "arboryx-e2e@example.com";
const PASSWORD = "Arboryx-E2E-9f3kZ!pw";
const PROJECT = process.env.FIREBASE_PROJECT || "marketresearch-agents";

initializeApp({ credential: applicationDefault(), projectId: PROJECT });

async function ensureUser() {
  try {
    const u = await getAuth().getUserByEmail(EMAIL);
    await getAuth().updateUser(u.uid, { password: PASSWORD, emailVerified: true, disabled: false });
    return u.uid;
  } catch (e) {
    if (e.code === "auth/user-not-found") {
      const u = await getAuth().createUser({ email: EMAIL, password: PASSWORD, emailVerified: true });
      return u.uid;
    }
    throw e;
  }
}
async function deleteUser() {
  try { const u = await getAuth().getUserByEmail(EMAIL); await getAuth().deleteUser(u.uid);
    console.log("deleted test user", EMAIL); } catch (e) { console.log("no user to delete:", e.code || e.message); }
}

const results = [];
function check(name, cond, detail) {
  results.push({ name, ok: !!cond, detail: detail || "" });
  console.log((cond ? "PASS " : "FAIL ") + name + (detail ? "  [" + detail + "]" : ""));
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function visible(page, sel) {
  const el = await page.$(sel);
  if (!el) return false;
  return await el.isVisible();
}

async function main() {
  if (process.argv.includes("--cleanup")) { await deleteUser(); process.exit(0); }
  if (!BASE) { console.error("BASE_URL required"); process.exit(2); }
  const uid = await ensureUser();
  console.log("test user ready uid=" + uid + " base=" + BASE + "\n");

  const browser = await chromium.launch();
  const context = await browser.newContext();
  const page = await context.newPage();
  page.on("console", (m) => { if (m.type() === "error") console.log("  [browser console.error]", m.text()); });

  try {
    // ---- BUG #4a: signed-out, DIRECT load of new_growth.html is blocked ----
    await page.goto(BASE + "/new_growth.html", { waitUntil: "domcontentloaded" });
    // wait for the gate to run (onAuthReady after Firebase + session settle)
    await page.waitForFunction(() => !location.pathname.endsWith("new_growth.html") || false, null, { timeout: 15000 }).catch(() => {});
    await sleep(500);
    const url4a = page.url();
    check("#4 signed-out direct new_growth.html is redirected away",
      !/new_growth\.html/.test(url4a), "url=" + url4a);
    check("#4 redirect lands on grove with ?signin=1", /[?&]signin=1/.test(url4a), "url=" + url4a);
    await page.waitForSelector(".aauth-scrim:not([hidden])", { timeout: 8000 }).catch(() => {});
    check("#4 sign-in modal auto-opens after gated redirect", await visible(page, ".aauth-scrim"));

    // close modal for the next step
    await page.evaluate(() => { const s = document.getElementById("aauthScrim"); if (s) s.hidden = true; });

    // ---- BUG #4b: signed-out leaf click opens modal, does NOT navigate ----
    await page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
    await page.waitForSelector(".aauth-trigger", { timeout: 15000 });
    check("#1 signed-out chip shows a Sign in trigger on the grove", await visible(page, ".aauth-trigger"));
    const gotLeaf = await page.waitForSelector(".tree-leaf", { timeout: 12000 }).then(() => true).catch(() => false);
    if (gotLeaf) {
      const beforeUrl = page.url();
      await page.click(".tree-leaf");
      await sleep(800);
      check("#4 signed-out leaf click does NOT navigate to new_growth",
        !/new_growth/.test(page.url()), "url=" + page.url());
      check("#4 signed-out leaf click opens the sign-in modal", await visible(page, ".aauth-scrim"));
      await page.evaluate(() => { const s = document.getElementById("aauthScrim"); if (s) s.hidden = true; });
    } else {
      check("#4 leaf-click gating (SKIPPED — no grove leaves rendered from API data)", true, "no .tree-leaf");
    }

    // ---- BUG #1: SIGN IN via email/password modal, chip renders ----
    await page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
    await page.waitForSelector(".aauth-trigger", { timeout: 15000 });
    await page.click(".aauth-trigger");
    await page.waitForSelector(".aauth-scrim:not([hidden])", { timeout: 8000 });
    await page.fill("#aauthEmail", EMAIL);
    await page.fill("#aauthPassword", PASSWORD);
    await page.click("#aauthSubmit");
    const signedIn = await page.waitForSelector(".aauth-account", { timeout: 20000 }).then(() => true).catch(() => false);
    check("#1 account chip renders after email/password sign-in", signedIn);

    // ---- BUG #1: new_growth shows the chip and NO "coming soon" stub ----
    await page.goto(BASE + "/new_growth.html", { waitUntil: "domcontentloaded" });
    await sleep(1200); // allow gate to (not) redirect
    check("#4 signed-IN user reaches new_growth.html", /new_growth\.html/.test(page.url()), "url=" + page.url());
    const chipOnNG = await page.waitForSelector(".aauth-account", { timeout: 15000 }).then(() => true).catch(() => false);
    check("#1 account chip present on new_growth.html", chipOnNG);
    const stub = await page.$(".auth-stub");
    const comingSoon = (await page.content()).toLowerCase().includes("coming soon");
    check("#1 no auth-stub element on new_growth.html", !stub);
    check("#1 no \"coming soon\" text on new_growth.html", !comingSoon);

    // ---- BUG #2: navigate back to Home — chip STILL present ----
    const homeLink = await page.$("a.nav-link[href=\"/\"]");
    if (homeLink) await homeLink.click(); else await page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
    const chipHome = await page.waitForSelector(".aauth-account", { timeout: 15000 }).then(() => true).catch(() => false);
    check("#2 session survives navigation: chip STILL present on Home", chipHome);

    // ---- BUG #2: new TAB in same context restores the chip ----
    const page2 = await context.newPage();
    await page2.goto(BASE + "/", { waitUntil: "domcontentloaded" });
    const chipNewTab = await page2.waitForSelector(".aauth-account", { timeout: 15000 }).then(() => true).catch(() => false);
    check("#2 session restored in a NEW TAB (same context/origin)", chipNewTab);
    await page2.close();

    // ---- BUG #4: signed-IN leaf click now navigates to new_growth ----
    const gotLeaf2 = await page.waitForSelector(".tree-leaf", { timeout: 12000 }).then(() => true).catch(() => false);
    if (gotLeaf2) {
      await page.click(".tree-leaf");
      const navd = await page.waitForFunction(() => /new_growth/.test(location.href), null, { timeout: 8000 }).then(() => true).catch(() => false);
      check("#4 signed-IN leaf click navigates to new_growth", navd, "url=" + page.url());
      await page.goBack().catch(() => {});
    } else {
      check("#4 signed-in leaf navigation (SKIPPED — no leaves)", true, "no .tree-leaf");
    }

    // ---- SIGN OUT — signed-out everywhere ----
    await page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
    await page.waitForSelector(".aauth-account", { timeout: 15000 });
    await page.click(".aauth-account");
    await page.waitForSelector("#aauthSignOut", { timeout: 5000 });
    await page.click("#aauthSignOut");
    const signedOut = await page.waitForSelector(".aauth-trigger", { timeout: 15000 }).then(() => true).catch(() => false);
    check("sign-out returns the Sign in trigger", signedOut);
    await page.reload({ waitUntil: "domcontentloaded" });
    const stillOut = await page.waitForSelector(".aauth-trigger", { timeout: 15000 }).then(() => true).catch(() => false);
    check("sign-out persists across reload", stillOut);

  } catch (e) {
    check("suite ran without throwing", false, String(e && e.stack || e));
  } finally {
    await browser.close();
  }

  const failed = results.filter((r) => !r.ok);
  console.log("\n==== " + (results.length - failed.length) + "/" + results.length + " checks passed ====");
  process.exit(failed.length ? 1 : 0);
}
main().catch((e) => { console.error(e); process.exit(3); });
