/*
 * test_ui_live.js — exercise the UI's initialLoad() + refreshDelta() against
 * the live cloud-function API, catching any runtime error that only appears
 * when the real schema and real sizes flow through.
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const HTML_PATH = path.resolve(__dirname, '..', 'arborist_3.2.html');
const html = fs.readFileSync(HTML_PATH, 'utf8');
let code = html.match(/<script>([\s\S]*?)<\/script>/)[1];
code = code.replace(/\/\/ -- INIT --[\s\S]*$/, '');

// Inject real API creds the deploy script would inject
code = code
  .replace("'__ARBORYX_ADMIN_API_URL__'", "'https://us-central1-marketresearch-agents.cloudfunctions.net/arboryx-admin-api'")
  .replace("'__ARBORYX_ADMIN_API_KEY__'", "'***REDACTED-ADMIN-KEY***'");

code += `
globalThis.__api = {
  get CONFIG(){return CONFIG;}, get RAW(){return RAW;}, get DATA(){return DATA;}, get state(){return state;},
  initialLoad, refreshDelta, processData, apiFetch, renderSentimentVal,
};`;

// Minimal DOM + sessionStorage shim
const DOM = {};
function el(id) {
  if (!DOM[id]) DOM[id] = {
    id, innerHTML: '', className: '', value: '', disabled: false, style: {},
    classList: { add(){}, remove(){}, toggle(){}, contains(){ return false; } },
    addEventListener() {}, querySelector() { return stub(); }, querySelectorAll() { return []; },
  };
  return DOM[id];
}
function stub() {
  return { innerHTML:'', className:'', style:{}, disabled:false,
    classList:{add(){},remove(){},toggle(){},contains(){return false;}},
    addEventListener(){}, querySelector(){return stub();}, querySelectorAll(){return [];},
    set onclick(_){}, get onclick(){return null;} };
}
const document = { getElementById: el, querySelector: () => stub(), querySelectorAll: () => [], addEventListener(){}, removeEventListener(){} };
const sessionStorage = { _d:{}, getItem(k){return this._d[k]??null;}, setItem(k,v){this._d[k]=v;}, removeItem(k){delete this._d[k];} };

const sandbox = {
  document, window:{}, sessionStorage,
  fetch: globalThis.fetch, URLSearchParams, console,
  setTimeout, setInterval, clearTimeout, clearInterval,
};
vm.createContext(sandbox);
vm.runInContext(code, sandbox);

(async () => {
  console.log('[step 1] calling initialLoad() against live API...');
  try {
    await sandbox.__api.initialLoad();
    console.log(`[ok] initialLoad completed. RAW=${sandbox.__api.RAW.length}, DATA=${sandbox.__api.DATA.length}`);
    console.log(`[ok] state.loaded=${sandbox.__api.state.loaded}, state.error=${sandbox.__api.state.error}`);
  } catch (e) {
    console.error(`[FAIL] initialLoad threw: ${e.message}`);
    console.error(e.stack);
    process.exit(1);
  }

  console.log('');
  console.log('[step 2] calling refreshDelta()...');
  try {
    await sandbox.__api.refreshDelta();
    console.log(`[ok] refreshDelta completed. RAW=${sandbox.__api.RAW.length}`);
  } catch (e) {
    console.error(`[FAIL] refreshDelta threw: ${e.message}`);
    process.exit(1);
  }

  console.log('');
  console.log('[step 3] verify first entry has expected schema...');
  const first = sandbox.__api.RAW[0];
  const required = ['entry_id', 'timestamp', 'category', 'finding', 'sentiment_takeaways'];
  const missing = required.filter(k => !(k in first));
  if (missing.length) {
    console.error(`[FAIL] first entry missing fields: ${missing.join(', ')}`);
    process.exit(1);
  }
  console.log(`[ok] first entry: ${first.entry_id} (${first.category}) ${first.timestamp}`);

  console.log('');
  console.log('[pass] full e2e pipeline works against live API.');
})().catch(e => { console.error('UNHANDLED:', e); process.exit(1); });
