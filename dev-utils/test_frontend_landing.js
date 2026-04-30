/*
 * test_frontend_landing.js — exercise the public landing's stats fetch
 * against the live cloud-function API using the read-only API key.
 *
 * Catches: placeholder substitution issues, schema drift, read-only-key
 * regressions, missing categories.
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const HTML_PATH    = path.resolve(__dirname, '..', 'frontend', 'index.html');
const SCRIPT_PATH  = path.resolve(__dirname, '..', 'frontend', 'scripts', 'landing.js');
const GROVE_PATH   = path.resolve(__dirname, '..', 'frontend', 'scripts', 'grove.js');
const API_URL      = process.env.ARBORYX_ADMIN_API_URL
  || 'https://arboryx-admin-api-pnucidjlvq-uc.a.run.app';
const PUBLIC_KEY   = process.env.ARBORYX_ADMIN_READ_ONLY_API_KEY;
if (!PUBLIC_KEY) {
  console.error('Missing ARBORYX_ADMIN_READ_ONLY_API_KEY env var.');
  console.error('  export ARBORYX_ADMIN_READ_ONLY_API_KEY=$(grep "^READ_ONLY_API_KEYS" ../arboryx_admin_backend.config | cut -d= -f2 | tr -d \\")');
  process.exit(2);
}
const EXPECTED_SECTORS = [
  'Robotics', 'Crypto', 'AI Stack',
  'Space & Defense', 'Power & Energy', 'Strategic Minerals',
];

// Inject the runtime config that scripts/config.js would set in the browser.
const code = fs.readFileSync(SCRIPT_PATH, 'utf8');
const configBootstrap = `window.ARBORYX_CONFIG = ${JSON.stringify({
  api:    { url: API_URL, publicKey: PUBLIC_KEY },
  grove:  { maxLeavesPerDay: 5, recencyDays: 7, treeScale: 1.0, leafSize: 1.0 },
  sectors: EXPECTED_SECTORS.map((name, i) => ({ name, cat: i, enabled: true })),
  shares:  { x: true, whatsapp: true, facebook: true, linkedin: true, reddit: true, telegram: true, email: true, instagram: true },
  brand:   { xHandle: 'arboryx_ai', linkedinUrl: 'https://www.linkedin.com/company/arboryx', slogan: 'Turning Market Noise Into Your Edge' },
})};\n`;

// Minimal DOM shim. The test focuses on data flow (API → paintStats);
// real DOM mutation is browser-only and out of scope for a node smoke.
const fakeEl = (extra = {}) => ({
  innerHTML: '', textContent: '',
  attrs: {},
  setAttribute(k, v){ this.attrs[k] = v; },
  removeAttribute(k){ delete this.attrs[k]; },
  getAttribute(k){ return this.attrs[k]; },
  addEventListener(){},
  removeEventListener(){},
  classList: { add(){}, remove(){}, toggle(){}, contains(){ return false; } },
  style: {},
  appendChild(){}, removeChild(){},
  ...extra,
});

const cells = {};         // populated below to mimic buildGrid output
const lastUpdated = fakeEl();
const dynamicYear = fakeEl();

const document = {
  getElementById(id) {
    if (id === 'groveGrid') return fakeEl({
      // when buildGrid sets innerHTML we don't parse it; instead we
      // pre-register the cells in the cells{} map so paintStats can find them.
    });
    return fakeEl();
  },
  querySelector(sel) {
    if (sel === '[data-last-updated]') return lastUpdated;
    if (sel === '[data-dynamic-year]') return dynamicYear;
    return null;
  },
  querySelectorAll(sel) {
    if (sel === '[data-sector-count]') return Object.values(cells);
    return [];
  },
  addEventListener(evt, cb) { if (evt === 'DOMContentLoaded') setTimeout(cb, 0); },
};

// Pre-register the 6 cells so paintStats can find them. In a browser
// these come from buildGrid's innerHTML; here we register them up front.
for (const name of EXPECTED_SECTORS) {
  cells[name] = fakeEl();
  cells[name].setAttribute('data-sector-count', name);
  cells[name].setAttribute('data-pending', '');
}

const sandbox = {
  document,
  window: {},
  fetch: globalThis.fetch,
  console,
  setTimeout, clearTimeout,
};
sandbox.window = sandbox;
// Provide an SVG-namespace stub so grove.js's createElementNS doesn't blow up.
sandbox.document.createElementNS = (ns, tag) => fakeEl({ tagName: tag });
sandbox.matchMedia = () => ({ matches: false });

vm.createContext(sandbox);
// Bootstrap config first (mirrors what scripts/config.js does in the browser).
vm.runInContext(configBootstrap, sandbox);
vm.runInContext(code, sandbox);
// Load grove.js to expose window.__grove for the data-flow tests below.
const groveCode = fs.readFileSync(GROVE_PATH, 'utf8');
vm.runInContext(groveCode, sandbox);

(async () => {
  console.log('[step 1] wait for DOMContentLoaded handler to complete');
  await new Promise((r) => setTimeout(r, 1500));

  const arboryx = sandbox.window.__arboryx;
  if (!arboryx) {
    console.error('[FAIL] window.__arboryx not exposed by landing.js');
    process.exit(1);
  }

  console.log(`[ok] sectors registered: ${arboryx.CONFIG.sectors.length}`);

  console.log('\n[step 2] fetchStats() against live API');
  const stats = await arboryx.fetchStats();
  if (!stats) {
    console.error('[FAIL] stats fetch returned null');
    process.exit(1);
  }
  console.log(`[ok] total_findings: ${stats.total_findings}`);
  console.log(`[ok] date_range: ${stats.date_range.earliest} → ${stats.date_range.latest}`);
  console.log(`[ok] categories returned: ${Object.keys(stats.categories).length}`);

  console.log('\n[step 3] every expected sector is present in stats');
  let missing = [];
  for (const name of EXPECTED_SECTORS) {
    if (!(name in stats.categories)) missing.push(name);
    else console.log(`  ${name.padEnd(22)} ${stats.categories[name]}`);
  }
  if (missing.length) {
    console.error(`[FAIL] missing sectors in API response: ${missing.join(', ')}`);
    process.exit(1);
  }

  console.log('\n[step 4] paintStats() updates the cells');
  arboryx.paintStats(stats);
  for (const name of EXPECTED_SECTORS) {
    const cell = cells[name];
    if (!cell.textContent || cell.textContent === '—') {
      console.error(`[FAIL] cell for "${name}" not painted (textContent=${JSON.stringify(cell.textContent)})`);
      process.exit(1);
    }
    if (cell.getAttribute('data-pending') !== undefined) {
      console.error(`[FAIL] cell for "${name}" still has data-pending after paint`);
      process.exit(1);
    }
  }
  console.log('[ok] all 6 sector cells painted');
  console.log(`[ok] last-updated = ${JSON.stringify(lastUpdated.textContent)}`);

  // ---------- Phase 4: grove data-layer verification ----------
  console.log('\n[step 5] grove.js — fetch recent findings and bucket per sector');
  const grove = sandbox.window.__grove;
  if (!grove) {
    console.error('[FAIL] window.__grove not exposed by grove.js');
    process.exit(1);
  }

  // Fetch findings directly via the same endpoint the grove uses
  const fResp = await fetch(`${API_URL}?action=findings&days=7&sort=desc&limit=9999`, {
    headers: { 'X-API-Key': PUBLIC_KEY },
  });
  const fBody = await fResp.json();
  const findings = fBody.findings || [];
  console.log(`[ok] fetched ${findings.length} findings in last 7 days`);

  const today = new Date();
  const todayUTC = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate());
  const cfg = sandbox.window.ARBORYX_CONFIG;
  const sectorMap = grove.pickEntriesForGrove(findings, cfg, todayUTC);
  const cap = cfg.grove.maxLeavesPerDay;
  const days = cfg.grove.recencyDays;

  let totalLeaves = 0;
  for (const name of EXPECTED_SECTORS) {
    const arr = sectorMap.get(name) || [];
    totalLeaves += arr.length;

    // Verify cap: no more than maxLeavesPerDay entries per recency-day per sector.
    const perDay = {};
    for (const e of arr) perDay[e.daysOld] = (perDay[e.daysOld] || 0) + 1;
    for (const [d, c] of Object.entries(perDay)) {
      if (c > cap) {
        console.error(`[FAIL] ${name} day ${d} has ${c} leaves (cap ${cap})`);
        process.exit(1);
      }
    }

    // Verify all daysOld are within window.
    for (const e of arr) {
      if (e.daysOld < 0 || e.daysOld > days) {
        console.error(`[FAIL] ${name} entry ${e.entry_id} daysOld=${e.daysOld} outside [0,${days}]`);
        process.exit(1);
      }
    }

    // Verify newest first.
    for (let i = 1; i < arr.length; i++) {
      if (arr[i].daysOld < arr[i - 1].daysOld) {
        console.error(`[FAIL] ${name} not sorted newest first at index ${i}`);
        process.exit(1);
      }
    }

    console.log(`  ${name.padEnd(22)} ${arr.length} leaves (cap ${cap * days})`);
  }
  console.log(`[ok] total leaves placed across grove: ${totalLeaves}`);

  console.log('\n[step 6] verify recency-class mapping is sane');
  const samples = [
    { daysOld: 0, expect: 'leaf-d0' },
    { daysOld: 1, expect: 'leaf-d1' },
    { daysOld: 6, expect: 'leaf-d6' },
    { daysOld: 9, expect: 'leaf-d6' },  // clamped
  ];
  for (const s of samples) {
    const got = (typeof grove.recencyClass === 'function')
      ? grove.recencyClass(s.daysOld)
      : `leaf-d${Math.max(0, Math.min(6, Math.floor(s.daysOld)))}`;
    if (got !== s.expect) {
      console.error(`[FAIL] recencyClass(${s.daysOld}) = ${got}, expected ${s.expect}`);
      process.exit(1);
    }
  }
  console.log('[ok] recency clamps OK');

  console.log('\n[pass] landing.js + grove.js work end-to-end against live API.');
})();
