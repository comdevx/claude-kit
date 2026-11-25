'use strict';
/**
 * mockup-diff.timeout.test.cjs
 * Regression: an adapter that sets a tiny page default timeout (to make missing-key lookups fail fast) must not make
 * mockup-diff flaky. Before the fix the live screenshot / evaluate inherited that default and timed out under load
 * ("locator.screenshot: Timeout 289ms exceeded" in a real project gate). Here the adapter sets 1 ms: the run must
 * still exit 0 on an identical page, and a mapped key that is absent from the page must be reported as missing.
 * Run: NODE_PATH="$(npm root -g)" node --test <skill-dir>/scripts/*.test.cjs
 * Browser rules: installed Chrome, muted, local-network permission, closed in finally (via the adapter's close()).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const HERE = __dirname;
const NODE_PATH = process.env.NODE_PATH || require('child_process').execSync('npm root -g').toString().trim();

const HTML = `<!doctype html><html><head><meta charset="utf-8"><style>
body{margin:0;background:#0b1020;font-family:-apple-system,sans-serif}
.frame{width:400px;height:300px;position:relative;background:#111a33;color:#fff}
.title{position:absolute;left:20px;top:20px;font-size:24px}
.btn{position:absolute;left:20px;top:200px;width:120px;height:40px;background:#3ee0ff;color:#06101f}
</style></head><body><div class="frame" data-m="frame"><div class="title" data-m="title">Hello</div>
<div class="btn" data-m="btn">Go</div></div></body></html>`;

function setup() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mockup-diff-timeout-'));
  const page = path.join(dir, 'page.html');
  fs.writeFileSync(page, HTML);
  const adapter = path.join(dir, 'adapter.cjs');
  fs.writeFileSync(adapter, `'use strict';
const { chromium } = require('playwright');
module.exports = { async open() {
  const browser = await chromium.launch({ channel: 'chrome', args: ['--mute-audio'] });
  const context = await browser.newContext({ viewport: { width: 400, height: 300 }, deviceScaleFactor: 1 });
  await context.grantPermissions(['local-network-access']).catch(() => {});
  const page = await context.newPage();
  await page.goto(${JSON.stringify('file://' + page)});
  page.setDefaultTimeout(1); // the trap: a tiny default inherited by screenshot/evaluate before the fix
  return { page, close: async () => { await context.close(); await browser.close(); } };
} };
`);
  return { dir, page, adapter };
}

function run(script, args) {
  return spawnSync(process.execPath, [path.join(HERE, script), ...args], {
    encoding: 'utf8', env: { ...process.env, NODE_PATH }, timeout: 120000,
  });
}

test('mockup-diff is not broken by an adapter page default timeout of 1 ms (identical page → exit 0)', () => {
  const { dir, page, adapter } = setup();
  try {
    const specDir = path.join(dir, 'spec');
    const s = run('mockup-spec.cjs', ['--mockup', page, '--frame', '[data-m="frame"]', '--viewport', '400x300', '--scale', '1', '--out', specDir]);
    assert.equal(s.status, 0, `mockup-spec failed:\n${s.stdout}\n${s.stderr}`);
    const map = path.join(dir, 'map.json');
    fs.writeFileSync(map, JSON.stringify({ root: '[data-m="frame"]', keys: { title: '[data-m="title"]', btn: '[data-m="btn"]', frame: '[data-m="frame"]' }, approved: {} }));
    const d = run('mockup-diff.cjs', ['--spec', path.join(specDir, 'spec.json'), '--map', map, '--adapter', adapter, '--out', path.join(dir, 'out')]);
    assert.doesNotMatch(d.stdout + d.stderr, /Timeout \d+(\.\d+)?ms exceeded/, 'no call may inherit the adapter\'s 1 ms default');
    assert.equal(d.status, 0, `mockup-diff exit ${d.status}:\n${d.stdout.slice(-1500)}\n${d.stderr.slice(-1500)}`);
    assert.ok(fs.existsSync(path.join(dir, 'out', 'live.png')), 'live screenshot written');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('with the 1 ms adapter default, a mapped key absent from the live page is still reported as missing (exit 1)', () => {
  const { dir, page, adapter } = setup();
  try {
    const specDir = path.join(dir, 'spec');
    const s = run('mockup-spec.cjs', ['--mockup', page, '--frame', '[data-m="frame"]', '--viewport', '400x300', '--scale', '1', '--out', specDir]);
    assert.equal(s.status, 0, s.stderr);
    const map = path.join(dir, 'map.json');
    fs.writeFileSync(map, JSON.stringify({ root: '[data-m="frame"]', keys: { title: '[data-m="title"]', btn: '[data-m="nope"]', frame: '[data-m="frame"]' }, approved: {} }));
    const d = run('mockup-diff.cjs', ['--spec', path.join(specDir, 'spec.json'), '--map', map, '--adapter', adapter, '--out', path.join(dir, 'out')]);
    assert.equal(d.status, 1, `expected a failing diff for the missing key:\n${d.stdout.slice(-1500)}`);
    assert.match(fs.readFileSync(path.join(dir, 'out', 'diff.md'), 'utf8'), /btn/);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
