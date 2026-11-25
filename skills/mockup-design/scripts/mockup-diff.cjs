'use strict';
/**
 * mockup-diff.cjs
 * Diff a live UI against an approved spec.
 *
 * Usage:
 *   node mockup-diff.cjs --spec <spec.json> --map <map.json> \
 *     --adapter <adapter.cjs> --out <dir> \
 *     [--tol-px 1] [--labels "Mockup,Live"]
 */

const path = require('path');
const fs = require('fs');
const { MEASURED_PROPS, normalizeValue, compare, renderMarkdown } = require('./fidelity-lib.cjs');
const { composeSideBySide } = require('./compose-side-by-side.cjs');

// ─── Arg parse ────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = argv.slice(2);
  const opts = { tolPx: 1, labels: 'Mockup,Live' };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--spec') opts.spec = args[++i];
    else if (a === '--map') opts.map = args[++i];
    else if (a === '--adapter') opts.adapter = args[++i];
    else if (a === '--out') opts.out = args[++i];
    else if (a === '--tol-px') opts.tolPx = Number(args[++i]);
    else if (a === '--labels') opts.labels = args[++i];
  }
  return opts;
}

// ─── Measure elements (same logic as mockup-spec) ────────────────────────────

async function measureKeys(rootLocator, keyMap, measuredProps, renderedChildrenOnly = false) {
  const rootBox = await rootLocator.boundingBox({ timeout: 30000 });
  if (!rootBox) throw new Error('Root element has no bounding box — is it visible?');

  const result = {};

  for (const [key, selectorOrObj] of Object.entries(keyMap)) {
    let selector, nth, pseudo;
    if (typeof selectorOrObj === 'object' && selectorOrObj !== null) {
      selector = selectorOrObj.selector;
      nth = selectorOrObj.nth || 0;
      pseudo = selectorOrObj.pseudo || null;
    } else {
      selector = selectorOrObj;
      nth = 0;
      pseudo = null;
    }

    const loc = rootLocator.locator(selector).nth(nth);

    // ── Pseudo-element branch ───────────────────────────────────────────────
    if (pseudo) {
      let found = false;
      try { found = await loc.count() > 0; } catch (e) { found = false; }
      if (!found) {
        console.warn(`  [warn] key "${key}" pseudo ${pseudo} host (${selector}) not found in live UI`);
        result[key] = null;
        continue;
      }
      const rawData = await loc.evaluate((el, { props, ps }) => {
        const cs = window.getComputedStyle(el, ps);
        const out = {};
        for (const p of props) out[p] = cs.getPropertyValue(p);
        out.content = cs.getPropertyValue('content');
        return out;
      }, { props: measuredProps, ps: pseudo });

      const content = (rawData.content || '').trim();
      if (content === 'none' || content === '') {
        // Pseudo absent — null causes compare() to report (missing)
        result[key] = null;
        continue;
      }

      const style = {};
      for (const [prop, value] of Object.entries(rawData)) {
        style[prop] = normalizeValue(prop, value);
      }
      const text = content.replace(/^["']|["']$/g, '').slice(0, 200);
      result[key] = { rect: null, style, text, childCount: null, selector, pseudo };
      continue;
    }

    // ── Regular element branch ──────────────────────────────────────────────
    let box, styleData, text, childCount;

    // Absent keys are decided by count() (no auto-wait), so adapters never need a tiny page default timeout to fail
    // lookups fast; present elements get an explicit, load-tolerant timeout (a 300 ms page default made the gate flaky).
    try { box = (await loc.count()) > 0 ? await loc.boundingBox({ timeout: 15000 }) : null; } catch (e) { box = null; }

    if (!box) {
      console.warn(`  [warn] key "${key}" (${selector}) not found in live UI`);
      // Record as missing
      result[key] = null;
      continue;
    }

    styleData = await loc.evaluate((el, props) => {
      const cs = window.getComputedStyle(el);
      const out = {};
      for (const p of props) out[p] = cs.getPropertyValue(p);
      return out;
    }, measuredProps);

    text = await loc.evaluate(el => {
      return (el.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 200);
    });

    // map.renderedChildrenOnly: skip display:none children (e.g. widget-injected hidden nodes
    // such as Scrollbar.js's .ro-custom-scrollbar) so only rendered structure is compared.
    childCount = await loc.evaluate((el, only) => (only
      ? Array.from(el.children).filter(c => getComputedStyle(c).display !== 'none').length
      : el.children.length), renderedChildrenOnly);

    const style = {};
    for (const [prop, value] of Object.entries(styleData)) {
      style[prop] = normalizeValue(prop, value);
    }

    const rect = {
      x: Math.round((box.x - rootBox.x) * 100) / 100,
      y: Math.round((box.y - rootBox.y) * 100) / 100,
      w: Math.round(box.width * 100) / 100,
      h: Math.round(box.height * 100) / 100,
    };

    result[key] = { rect, style, text, childCount, selector };
  }

  return {
    rootRect: { w: Math.round(rootBox.width * 100) / 100, h: Math.round(rootBox.height * 100) / 100 },
    keys: result,
  };
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const opts = parseArgs(process.argv);

  if (!opts.spec) { console.error('--spec required'); process.exit(1); }
  if (!opts.map) { console.error('--map required'); process.exit(1); }
  if (!opts.adapter) { console.error('--adapter required'); process.exit(1); }
  if (!opts.out) { console.error('--out required'); process.exit(1); }

  const spec = JSON.parse(fs.readFileSync(path.resolve(opts.spec), 'utf8'));
  const mapData = JSON.parse(fs.readFileSync(path.resolve(opts.map), 'utf8'));
  const adapterPath = path.resolve(opts.adapter);

  const {
    root: rootSel,
    keys: liveKeyMap = {},
    approved = {},
    ignoreProps = [],
    ignoreText = false,
    renderedChildrenOnly = false,
    decodedImageKeys = [],
    require: requirements = {},
  } = mapData;

  if (!rootSel) { console.error('map.json must have "root" selector'); process.exit(1); }

  fs.mkdirSync(path.resolve(opts.out), { recursive: true });

  const adapter = require(adapterPath);
  const { page, close } = await adapter.open();
  // Absent keys are detected with count() (no auto-wait), so a load-tolerant default is safe here and overrides any
  // short default an adapter set to make missing-key lookups fast (a 300 ms default made screenshots/evaluate flaky).
  page.setDefaultTimeout(15000);

  let exitCode = 0;

  try {
    // Check requirements
    if (requirements.bodyClass) {
      const hasClass = await page.evaluate(cls => document.body.classList.contains(cls), requirements.bodyClass);
      if (!hasClass) {
        console.error(`Requirement failed: not in the required UI mode (body.classList missing "${requirements.bodyClass}")`);
        exitCode = 1;
        return;
      }
    }

    if (requirements.viewport) {
      const [reqW, reqH] = requirements.viewport;
      const vp = page.viewportSize();
      if (vp.width !== reqW || vp.height !== reqH) {
        console.error(`Requirement failed: viewport is ${vp.width}x${vp.height}, expected ${reqW}x${reqH}`);
        exitCode = 1;
        return;
      }
    }

    // Record devicePixelRatio
    const devicePixelRatio = await page.evaluate(() => window.devicePixelRatio);

    // Locate root
    const rootLoc = page.locator(rootSel).first();
    const rootCount = await page.locator(rootSel).count();
    if (rootCount === 0) {
      console.error(`Root selector "${rootSel}" matched 0 elements in live UI.`);
      exitCode = 1;
      return;
    }

    // Screenshot live root
    const livePng = path.join(path.resolve(opts.out), 'live.png');
    // explicit timeout: must not inherit an adapter's short page default (fonts/stability wait under load)
    await rootLoc.screenshot({ path: livePng, scale: 'device', timeout: 30000 });
    console.log(`Live screenshot: ${livePng}`);

    // Detect keys in spec that are not in map → unmapped diffs
    const specKeys = Object.keys(spec.keys || {});
    const mapKeys = Object.keys(liveKeyMap);
    const unmappedKeys = specKeys.filter(k => !mapKeys.includes(k));

    // Measure live
    console.log(`Measuring ${mapKeys.length} keys in live UI...`);
    const { keys: liveKeys } = await measureKeys(rootLoc, liveKeyMap, MEASURED_PROPS, renderedChildrenOnly);

    // Build live snapshot (null entries become missing)
    const liveSnapshot = { keys: {} };
    for (const [key, val] of Object.entries(liveKeys)) {
      if (val !== null) {
        liveSnapshot.keys[key] = val;
      }
      // null → not added, so compare() will report it as (missing)
    }

    // map.decodedImageKeys: compare background-image by decoded RGBA pixels (hash) instead of the
    // url string, for keys whose bitmap is identical but encoded differently (mockup PNG vs live
    // loader data URI). Both sides are decoded in the live page; any pixel difference still fails.
    // Every url() layer is hashed (multi-layer backgrounds included). A file:// url from a mockup
    // extracted from disk cannot be loaded by an http(s) live page, so its bytes are read here and
    // handed to the page as a data: url (same bytes, decoded by the same browser).
    const URL_RE = /url\(["']?(.*?)["']?\)/g;
    const MIME = { jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', gif: 'image/gif', webp: 'image/webp', bmp: 'image/bmp', svg: 'image/svg+xml' };
    const decodable = (u) => {
      if (!/^file:\/\//i.test(u)) return u;
      try {
        const p = require('url').fileURLToPath(u);
        const mime = MIME[path.extname(p).slice(1).toLowerCase()] || 'application/octet-stream';
        return `data:${mime};base64,${fs.readFileSync(p).toString('base64')}`;
      } catch (e) { return u; }
    };
    for (const key of decodedImageKeys) {
      const sv = spec.keys && spec.keys[key] && spec.keys[key].style;
      const lv = liveSnapshot.keys[key] && liveSnapshot.keys[key].style;
      if (!sv || !lv) continue;
      const specUrls = [...String(sv['background-image'] || '').matchAll(URL_RE)].map(m => m[1]);
      const liveUrls = [...String(lv['background-image'] || '').matchAll(URL_RE)].map(m => m[1]);
      if (!specUrls.length || !liveUrls.length) continue;
      const hashes = await page.evaluate(async urls => {
        const one = async u => {
          const img = new Image();
          img.src = u;
          try { await img.decode(); } catch (e) { return null; }
          const c = document.createElement('canvas');
          c.width = img.naturalWidth; c.height = img.naturalHeight;
          const x = c.getContext('2d');
          x.drawImage(img, 0, 0);
          const d = x.getImageData(0, 0, c.width, c.height).data;
          let h = 2166136261;
          for (let i = 0; i < d.length; i++) { h ^= d[i]; h = Math.imul(h, 16777619) >>> 0; }
          return `pixels:${c.width}x${c.height}:${h.toString(16)}`;
        };
        return Promise.all(urls.map(one));
      }, [...specUrls.map(decodable), ...liveUrls]);
      if (hashes.every(Boolean)) {
        let si = 0, li = 0;
        const sh = hashes.slice(0, specUrls.length), lh = hashes.slice(specUrls.length);
        sv['background-image'] = String(sv['background-image']).replace(URL_RE, () => sh[si++]);
        lv['background-image'] = String(lv['background-image']).replace(URL_RE, () => lh[li++]);
      }
    }

    // Add unmapped keys as missing in live (failing diffs)
    const unmappedDiffs = unmappedKeys.map(key => ({
      key, prop: '(unmapped)',
      expected: '(mapped in map.json)', actual: '(not mapped)',
      delta: null,
      approved: false,
      reason: null,
    }));

    // Run compare
    const result = compare(spec, liveSnapshot, {
      tolPx: opts.tolPx,
      tolPct: 0,
      approved,
      ignoreProps,
      ignoreText,
    });

    // Merge unmapped diffs into result
    result.diffs.push(...unmappedDiffs);
    result.failing.push(...unmappedDiffs);
    result.summary.diffs += unmappedDiffs.length;
    result.summary.failing += unmappedDiffs.length;

    const [specLabel, liveLabel] = String(opts.labels).split(',').map(s => s.trim());

    // Render markdown
    const md = renderMarkdown(result, { specLabel: specLabel || 'Mockup', liveLabel: liveLabel || 'Live' });
    console.log('\n' + md);

    // Write files
    const diffJsonPath = path.join(path.resolve(opts.out), 'diff.json');
    const diffMdPath = path.join(path.resolve(opts.out), 'diff.md');

    const fullReport = {
      spec: opts.spec,
      map: opts.map,
      adapter: opts.adapter,
      devicePixelRatio,
      createdAt: new Date().toISOString(),
      ...result,
    };
    fs.writeFileSync(diffJsonPath, JSON.stringify(fullReport, null, 2));
    fs.writeFileSync(diffMdPath, md);
    console.log(`diff.json → ${diffJsonPath}`);
    console.log(`diff.md   → ${diffMdPath}`);

    // Compose side-by-side
    const mockupPng = spec.source
      ? path.join(path.dirname(path.resolve(opts.spec)), 'mockup.png')
      : null;
    const sidePng = path.join(path.resolve(opts.out), 'side-by-side.png');

    if (mockupPng && fs.existsSync(mockupPng)) {
      await composeSideBySide({
        left: mockupPng,
        right: livePng,
        out: sidePng,
        labels: [specLabel || 'Mockup', liveLabel || 'Live'],
      });
      console.log(`side-by-side.png → ${sidePng}`);
    } else {
      console.warn('mockup.png not found alongside spec.json — skipping side-by-side');
    }

    exitCode = result.failing.length > 0 ? 1 : 0;
    if (exitCode === 0) {
      console.log(`\n✅ 0 failing diffs — live UI matches the spec.`);
    } else {
      console.log(`\n❌ ${result.failing.length} failing diff(s) — see diff.md`);
    }
  } finally {
    await close();
    process.exitCode = exitCode;
  }
}

main().catch(e => { console.error(e.message); process.exitCode = 1; });
