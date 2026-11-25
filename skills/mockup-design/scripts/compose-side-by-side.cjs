'use strict';
/**
 * compose-side-by-side.cjs
 * Compose two PNG screenshots side by side using headless Chromium.
 *
 * CLI: node compose-side-by-side.cjs <left.png> <right.png> <out.png>
 *       [--labels "Mockup,Live"] [--title "..."]
 *
 * Export: composeSideBySide({ left, right, out, labels, title })
 */

const fs = require('fs');

async function composeSideBySide({ left, right, out, labels = ['Mockup', 'Live'], title = '' }) {
  const { chromium } = require('playwright');

  const leftData = fs.readFileSync(left).toString('base64');
  const rightData = fs.readFileSync(right).toString('base64');
  const [leftLabel, rightLabel] = Array.isArray(labels)
    ? labels
    : String(labels).split(',').map(s => s.trim());

  const html = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: #1a1d23; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; padding: 24px; }
  .title { color: #9ba3b0; font-size: 13px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; text-align: center; margin-bottom: 16px; }
  .row { display: flex; gap: 16px; align-items: flex-start; }
  .pane { display: flex; flex-direction: column; align-items: center; gap: 8px; }
  .label { color: #6b7280; font-size: 11px; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; }
  .pane img { display: block; max-width: 100%; border: 1px solid #2d3340; border-radius: 4px; }
</style>
</head>
<body>
${title ? `<div class="title">${title}</div>` : ''}
<div class="row">
  <div class="pane">
    <div class="label">${leftLabel}</div>
    <img src="data:image/png;base64,${leftData}" alt="${leftLabel}">
  </div>
  <div class="pane">
    <div class="label">${rightLabel}</div>
    <img src="data:image/png;base64,${rightData}" alt="${rightLabel}">
  </div>
</div>
</body>
</html>`;

  const browser = await chromium.launch({ channel: 'chrome', headless: true, args: ['--mute-audio'] });
  try {
    const context = await browser.newContext();
    await context.grantPermissions(['local-network-access']);
    const page = await context.newPage();
    await page.setViewportSize({ width: 1400, height: 900 });
    await page.setContent(html, { waitUntil: 'load' });

    // Size viewport to content
    const box = await page.locator('.row').boundingBox();
    const titleBox = title ? await page.locator('.title').boundingBox() : null;
    const contentH = (titleBox ? titleBox.height + 16 : 0) + (box ? box.height : 600) + 48 + 32;
    const contentW = box ? box.width + 48 : 1200;
    await page.setViewportSize({ width: Math.ceil(contentW), height: Math.ceil(contentH) });

    await page.screenshot({
      path: out,
      fullPage: true,
      scale: 'device',
    });
  } finally {
    await browser.close();
  }
}

// ─── CLI ─────────────────────────────────────────────────────────────────────

if (require.main === module) {
  const args = process.argv.slice(2);
  const positional = [];
  const opts = {};

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--labels') {
      opts.labels = args[++i].split(',').map(s => s.trim());
    } else if (args[i] === '--title') {
      opts.title = args[++i];
    } else {
      positional.push(args[i]);
    }
  }

  const [left, right, out] = positional;
  if (!left || !right || !out) {
    console.error('Usage: compose-side-by-side.cjs <left.png> <right.png> <out.png> [--labels "Mockup,Live"] [--title "..."]');
    process.exit(1);
  }

  composeSideBySide({ left, right, out, ...opts })
    .then(() => { console.log(`Side-by-side written: ${out}`); })
    .catch(e => { console.error(e.message); process.exit(1); });
}

module.exports = { composeSideBySide };
