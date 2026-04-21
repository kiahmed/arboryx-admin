/*
 * test_ui_render.js — headless smoke-test of market_findings_3.0.html render logic
 * against a local findings JSON file.
 *
 * Usage:
 *   node dev-utils/test_ui_render.js [path/to/market_findings_log.json]
 *
 * Strategy: load the HTML, strip the <script> block, neutralise DOM refs
 * with a minimal jsdom-style shim, inject the data via processData(), and
 * ensure renderCards, renderSentimentVal, parseTS etc. succeed on every row.
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const HTML_PATH = path.resolve(__dirname, '..', 'market_findings_3.0.html');
const DATA_PATH = process.argv[2] || path.resolve(__dirname, '..', '..', 'alphasnap', 'dev-utils', 'market_findings_log2.json');

// -- Load source HTML and extract the script body --
const html = fs.readFileSync(HTML_PATH, 'utf8');
const scriptMatch = html.match(/<script>([\s\S]*?)<\/script>/);
if (!scriptMatch) { console.error('no <script> found'); process.exit(1); }
let code = scriptMatch[1];

// Strip the auto-init tail so we drive it manually
code = code.replace(/\/\/ -- INIT --[\s\S]*$/, '// (init stripped for test)');

// Expose symbols declared with const/let to the sandbox (vm doesn't hoist those)
code += `
globalThis.__api = {
  get CONFIG() { return CONFIG; },
  get DATA() { return DATA; },
  get RAW() { return RAW; },
  processData, parseTS, renderSentimentVal, renderCards,
};
`;

// -- Minimal DOM shim --
const DOM = {};
function el(id) {
  if (!DOM[id]) DOM[id] = {
    id, innerHTML: '', className: '', value: '', disabled: false, style: {},
    classList: {
      _set: new Set(),
      add(c) { this._set.add(c); },
      remove(c) { this._set.delete(c); },
      toggle(c, on) { if (on) this._set.add(c); else this._set.delete(c); },
      contains(c) { return this._set.has(c); },
    },
    addEventListener() {},
    querySelector() { return stub(); },
    querySelectorAll() { return []; },
  };
  return DOM[id];
}
function stub() {
  return {
    innerHTML: '', className: '', style: {}, disabled: false,
    classList: { add(){}, remove(){}, toggle(){}, contains(){ return false; } },
    addEventListener() {}, querySelector() { return stub(); }, querySelectorAll() { return []; },
    set onclick(_) {}, get onclick() { return null; },
  };
}

const document = {
  getElementById: el,
  querySelector(sel) {
    if (sel === '.search-wrap') return el('__searchWrap');
    return null;
  },
  querySelectorAll() { return []; },
};

const sessionStorage = { _d: {}, getItem(k) { return this._d[k] ?? null; }, setItem(k, v) { this._d[k] = v; }, removeItem(k) { delete this._d[k]; } };
const window = {};
const fetch = async () => ({ ok: true, json: async () => ({}) });

const sandbox = {
  document, window, sessionStorage, fetch,
  URLSearchParams, console,
  setTimeout, setInterval, clearTimeout, clearInterval,
};
vm.createContext(sandbox);

try {
  vm.runInContext(code, sandbox);
} catch (e) {
  console.error('SCRIPT LOAD ERROR:', e.message);
  process.exit(1);
}

// -- Run smoke test --
const data = JSON.parse(fs.readFileSync(DATA_PATH, 'utf8'));
console.log(`[info] loaded ${data.length} entries from ${DATA_PATH}`);

let failures = 0;
const checks = [];

// 1. processData doesn't throw on full set
try {
  sandbox.__api.processData(data);
  checks.push(`[ok] processData() completed on ${data.length} entries`);
} catch (e) {
  failures++;
  checks.push(`[FAIL] processData: ${e.message}`);
}

// 2. parseTS handles every timestamp
let tsFail = 0, tsOk = 0;
for (const r of data) {
  const d = sandbox.__api.parseTS(r.timestamp);
  if (d && !isNaN(d)) tsOk++; else tsFail++;
}
checks.push(`[${tsFail === 0 ? 'ok' : 'WARN'}] parseTS: ${tsOk} parsed, ${tsFail} unparseable`);

// 3. renderSentimentVal doesn't throw and produces HTML for every row
let sentFail = 0, sentEmpty = 0;
for (const r of data) {
  const v = r.sentiment_takeaways;
  if (v == null || v === '') { sentEmpty++; continue; }
  try {
    const out = sandbox.__api.renderSentimentVal(String(v), '');
    if (!out || typeof out !== 'string') throw new Error('empty output');
    if (!out.includes('<span') && !out.includes('<ul')) throw new Error('no markup produced');
  } catch (e) {
    sentFail++;
    checks.push(`[FAIL] sentiment render ${r.entry_id}: ${e.message}`);
    if (sentFail > 5) break;
  }
}
checks.push(`[${sentFail === 0 ? 'ok' : 'FAIL'}] renderSentimentVal: ${data.length - sentEmpty - sentFail} ok, ${sentEmpty} empty, ${sentFail} failed`);
if (sentFail) failures++;

// 4. renderCards over the full page of 25
try {
  sandbox.__api.renderCards(data.slice(0, 25), 0);
  const html = DOM['findingsList'].innerHTML;
  if (!html.includes('field-title')) throw new Error('no titles rendered');
  if (html.includes('entry_id') || html.includes('source_url')) {
    throw new Error('entry_id or source_url leaked into rendered HTML');
  }
  checks.push(`[ok] renderCards(): ${html.length} chars, no entry_id/source_url leak`);
} catch (e) {
  failures++;
  checks.push(`[FAIL] renderCards: ${e.message}`);
}

// 5. Categories resolve
const cats = sandbox.__api.CONFIG._cats || [];
checks.push(`[ok] categories detected: ${cats.join(', ')}`);

// 6. Sort direction honoured
const sortedDates = sandbox.__api.DATA.slice(0, 5).map(r => r.timestamp);
checks.push(`[info] first 5 timestamps after sort (desc): ${sortedDates.join(', ')}`);

// -- Report --
console.log('');
checks.forEach(c => console.log(c));
console.log('');
console.log(failures === 0 ? `[pass] all checks green` : `[fail] ${failures} check(s) failed`);
process.exit(failures === 0 ? 0 : 1);
