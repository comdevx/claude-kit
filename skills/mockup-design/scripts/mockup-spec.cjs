'use strict';
/**
 * mockup-spec.cjs
 * Extract a machine-readable spec from an approved HTML mockup.
 *
 * Usage:
 *   node mockup-spec.cjs --mockup <file.html> --frame <css-selector> \
 *     [--keys <keys.json>] [--viewport 812x375] [--scale 2] --out <dir>
 */

const path = require('path');
const fs = require('fs');
const { MEASURED_PROPS, normalizeValue } = require('./fidelity-lib.cjs');

// ─── Arg parse ────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = argv.slice(2);
  const opts = { viewport: '812x375', scale: 2 };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--mockup') opts.mockup = args[++i];
    else if (a === '--frame') opts.frame = args[++i];
    else if (a === '--keys') opts.keys = args[++i];
    else if (a === '--viewport') opts.viewport = args[++i];
    else if (a === '--scale') opts.scale = Number(args[++i]);
    else if (a === '--out') opts.out = args[++i];
    else if (a === '--rendered-children-only') opts.renderedChildrenOnly = true;
  }
  return opts;
}

// ─── Measure elements in page ─────────────────────────────────────────────────

/**
 * Returns snapshot of all keys relative to frameLocator.
 * Supports regular element keys and pseudo-element keys ({ selector, pseudo }).
 */
async function measureKeys(frameLocator, keyMap, measuredProps, renderedChildrenOnly = false) {
  const frameBox = await frameLocator.boundingBox();
  if (!frameBox) throw new Error('Frame element has no bounding box — is it visible?');

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

    // Locate element relative to frame
    const loc = frameLocator.locator(selector).nth(nth);

    // ── Pseudo-element branch ─────────────────────────────────────────────────
    if (pseudo) {
      let found = false;
      try { found = await loc.count() > 0; } catch (e) { found = false; }
      if (!found) {
        console.warn(`  [warn] key "${key}" pseudo ${pseudo} host (${selector}) not found`);
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
        // Pseudo is absent — omit so compare() reports (missing)
        continue;
      }

      const style = {};
      for (const [prop, value] of Object.entries(rawData)) {
        style[prop] = normalizeValue(prop, value);
      }
      // Strip CSS string quotes from content for text
      const text = content.replace(/^["']|["']$/g, '').slice(0, 200);

      result[key] = { rect: null, style, text, childCount: null, selector, pseudo };
      continue;
    }

    // ── Regular element branch ────────────────────────────────────────────────
    let box, styleData, text, childCount;
    try {
      box = await loc.boundingBox();
    } catch (e) {
      box = null;
    }

    if (!box) {
      console.warn(`  [warn] key "${key}" (${selector}) not found or not visible`);
      continue;
    }

    // Compute style via evaluate
    styleData = await loc.evaluate((el, props) => {
      const cs = window.getComputedStyle(el);
      const out = {};
      for (const p of props) out[p] = cs.getPropertyValue(p);
      return out;
    }, measuredProps);

    text = await loc.evaluate(el => {
      const t = (el.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 200);
      return t;
    });

    // --rendered-children-only mirrors map.renderedChildrenOnly in mockup-diff: skip display:none children.
    childCount = await loc.evaluate((el, only) => (only ? Array.from(el.children).filter(c => getComputedStyle(c).display !== 'none').length : el.children.length), renderedChildrenOnly);

    // Normalize style
    const style = {};
    for (const [prop, value] of Object.entries(styleData)) {
      style[prop] = normalizeValue(prop, value);
    }

    // Rect relative to frame
    const rect = {
      x: Math.round((box.x - frameBox.x) * 100) / 100,
      y: Math.round((box.y - frameBox.y) * 100) / 100,
      w: Math.round(box.width * 100) / 100,
      h: Math.round(box.height * 100) / 100,
    };

    result[key] = { rect, style, text, childCount, selector };
  }

  return { frameRect: { w: Math.round(frameBox.width * 100) / 100, h: Math.round(frameBox.height * 100) / 100 }, keys: result };
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const opts = parseArgs(process.argv);

  if (!opts.mockup) { console.error('--mockup required'); process.exit(1); }
  if (!opts.frame) { console.error('--frame required'); process.exit(1); }
  if (!opts.out) { console.error('--out required'); process.exit(1); }

  // A page state may be given as a query / hash on the file (e.g. gallery.html?f=inv): the file must exist, the
  // suffix is kept in the URL that is opened.
  const qAt = opts.mockup.search(/[?#]/);
  const mockupFile = qAt >= 0 ? opts.mockup.slice(0, qAt) : opts.mockup;
  const mockupSuffix = qAt >= 0 ? opts.mockup.slice(qAt) : '';
  const mockupAbs = path.resolve(mockupFile) + mockupSuffix;
  if (!fs.existsSync(path.resolve(mockupFile))) { console.error(`File not found: ${path.resolve(mockupFile)}`); process.exit(1); }

  const [vpW, vpH] = opts.viewport.split('x').map(Number);
  const scale = opts.scale;

  // Parse keys
  let keyMap = null;
  if (opts.keys) {
    keyMap = JSON.parse(fs.readFileSync(path.resolve(opts.keys), 'utf8'));
  }

  // Ensure out dir
  fs.mkdirSync(path.resolve(opts.out), { recursive: true });

  const { chromium } = require('playwright');
  const browser = await chromium.launch({ channel: 'chrome', headless: true, args: ['--mute-audio'] });

  try {
    const context = await browser.newContext({
      viewport: { width: vpW, height: vpH },
      deviceScaleFactor: scale,
    });
    await context.grantPermissions(['local-network-access']);
    const page = await context.newPage();

    const fileUrl = `file://${mockupAbs}`;
    // deterministic extraction: mockups can opt out of looping animations via @media (prefers-reduced-motion: reduce)
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.goto(fileUrl, { waitUntil: 'load' });

    // Wait for fonts
    await page.evaluate(() => document.fonts.ready);

    // Locate frame
    const frameLoc = page.locator(opts.frame).first();
    const frameCount = await page.locator(opts.frame).count();
    if (frameCount === 0) {
      console.error(`Frame selector "${opts.frame}" matched 0 elements.`);
      await browser.close();
      process.exit(1);
    }
    console.log(`Frame selector "${opts.frame}" matched ${frameCount} element(s) (using first).`);

    // Resolve key map: data-m attributes if not supplied
    if (!keyMap) {
      keyMap = await frameLoc.evaluate((frameEl) => {
        const result = {};
        frameEl.querySelectorAll('[data-m]').forEach(el => {
          result[el.getAttribute('data-m')] = '[data-m="' + el.getAttribute('data-m') + '"]';
        });
        return result;
      });
      if (Object.keys(keyMap).length === 0) {
        console.error('No keys found: neither --keys given nor data-m attributes in frame.');
        await browser.close();
        process.exit(1);
      }
    }

    console.log(`Measuring ${Object.keys(keyMap).length} keys...`);
    const { frameRect, keys } = await measureKeys(frameLoc, keyMap, MEASURED_PROPS, !!opts.renderedChildrenOnly);

    const measuredCount = Object.keys(keys).length;
    if (measuredCount === 0) {
      console.error('No keys could be measured (all selectors failed to match). Check your selectors.');
      await browser.close();
      process.exit(1);
    }

    // Screenshot frame
    const pngPath = path.join(path.resolve(opts.out), 'mockup.png');
    await frameLoc.screenshot({ path: pngPath, scale: 'device' });

    // Write spec.json
    const spec = {
      source: mockupAbs,
      frame: opts.frame,
      viewport: `${vpW}x${vpH}`,
      scale,
      frameRect,
      createdAt: new Date().toISOString(),
      keys,
    };
    const specPath = path.join(path.resolve(opts.out), 'spec.json');
    fs.writeFileSync(specPath, JSON.stringify(spec, null, 2));

    console.log(`\nDone. ${measuredCount}/${Object.keys(keyMap).length} keys measured.`);
    console.log(`  spec.json → ${specPath}`);
    console.log(`  mockup.png → ${pngPath}`);
  } finally {
    await browser.close();
  }
}

main().catch(e => { console.error(e.message); process.exit(1); });
