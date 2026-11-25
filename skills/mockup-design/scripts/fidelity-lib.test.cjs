'use strict';
/**
 * fidelity-lib.test.cjs
 * Unit tests for fidelity-lib.cjs
 * Run: node --test <skill-dir>/scripts/
 */

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const { normalizeColor, normalizeValue, compare, renderMarkdown } = require('./fidelity-lib.cjs');

// ─── normalizeColor ───────────────────────────────────────────────────────────

describe('normalizeColor', () => {
  test('#rgb short form', () => {
    assert.equal(normalizeColor('#abc'), 'rgba(170,187,204,1)');
  });

  test('#rrggbb long form', () => {
    assert.equal(normalizeColor('#aabbcc'), 'rgba(170,187,204,1)');
  });

  test('#rrggbbaa with alpha', () => {
    // #ffffff80 → alpha = 128/255 ≈ 0.502
    const result = normalizeColor('#ffffff80');
    assert.match(result, /^rgba\(255,255,255,0\.50/);
  });

  test('rgb() functional', () => {
    assert.equal(normalizeColor('rgb(255, 0, 128)'), 'rgba(255,0,128,1)');
  });

  test('rgba() functional', () => {
    assert.equal(normalizeColor('rgba(255, 0, 128, 0.5)'), 'rgba(255,0,128,0.5)');
  });

  test('rgba() with alpha=1', () => {
    assert.equal(normalizeColor('rgba(0, 0, 0, 1)'), 'rgba(0,0,0,1)');
  });

  test('gradient string normalizes embedded hex', () => {
    const result = normalizeColor('linear-gradient(to bottom, #fff, #000)');
    assert.ok(result.includes('rgba(255,255,255,1)'), `expected rgba for #fff, got: ${result}`);
    assert.ok(result.includes('rgba(0,0,0,1)'), `expected rgba for #000, got: ${result}`);
  });

  test('gradient string normalizes embedded rgb()', () => {
    const result = normalizeColor('linear-gradient(to right, rgb(255,0,0), rgba(0,0,255,0.5))');
    assert.ok(result.includes('rgba(255,0,0,1)'), `expected rgba for rgb(255,0,0), got: ${result}`);
    assert.ok(result.includes('rgba(0,0,255,0.5)'), `expected rgba for rgba(0,0,255,0.5), got: ${result}`);
  });

  test('unknown string passes through trimmed', () => {
    assert.equal(normalizeColor('  none  '), 'none');
  });
});

// ─── normalizeValue ───────────────────────────────────────────────────────────

describe('normalizeValue', () => {
  test('color prop normalizes to rgba', () => {
    const v = normalizeValue('color', '#ff0000');
    assert.equal(v, 'rgba(255,0,0,1)');
  });

  test('background-color normalizes', () => {
    const v = normalizeValue('background-color', 'rgb(10, 20, 30)');
    assert.equal(v, 'rgba(10,20,30,1)');
  });

  test('px value becomes number', () => {
    const v = normalizeValue('width', '16.5px');
    assert.equal(v, 16.5);
  });

  test('px value 0px becomes 0', () => {
    const v = normalizeValue('height', '0px');
    assert.equal(v, 0);
  });

  test('non-px string passes through trimmed', () => {
    const v = normalizeValue('display', '  flex  ');
    assert.equal(v, 'flex');
  });

  test('font-size px value normalized', () => {
    const v = normalizeValue('font-size', '14px');
    assert.equal(v, 14);
  });
});

// ─── compare ─────────────────────────────────────────────────────────────────

function makeSnapshot(keys) {
  return { keys };
}

function makeKey({ h = 40, fontSize = 14, color = 'rgba(0,0,0,1)', text = 'hello', childCount = 2 } = {}) {
  return {
    rect: { x: 0, y: 0, w: 100, h },
    style: {
      height: h,
      'font-size': fontSize,
      color,
      width: 100,
      display: 'flex',
    },
    text,
    childCount,
  };
}

describe('compare — px tolerance', () => {
  test('within tolPx=1 passes (delta=1)', () => {
    const spec = makeSnapshot({ btn: makeKey({ h: 40 }) });
    const live = makeSnapshot({ btn: makeKey({ h: 41 }) });
    const result = compare(spec, live, { tolPx: 1 });
    // height diff = 1, tolPx = 1 → should pass (delta <= threshold)
    const heightDiff = result.diffs.find(d => d.prop === 'height');
    assert.equal(heightDiff, undefined, 'height=41 vs spec=40 with tolPx=1 should NOT be a diff');
  });

  test('exceeds tolPx=1 fails (delta=2)', () => {
    const spec = makeSnapshot({ btn: makeKey({ h: 40 }) });
    const live = makeSnapshot({ btn: makeKey({ h: 42 }) });
    const result = compare(spec, live, { tolPx: 1 });
    const heightDiff = result.diffs.find(d => d.prop === 'height');
    assert.ok(heightDiff, 'height=42 vs spec=40 with tolPx=1 should be a diff');
    assert.equal(heightDiff.delta, 2);
  });

  test('within tolPx=0 exact match (delta=0)', () => {
    const spec = makeSnapshot({ btn: makeKey({ h: 40 }) });
    const live = makeSnapshot({ btn: makeKey({ h: 40 }) });
    const result = compare(spec, live, { tolPx: 0 });
    const heightDiff = result.diffs.find(d => d.prop === 'height');
    assert.equal(heightDiff, undefined);
  });

  test('boundary: delta=1 tolPx=1 passes', () => {
    const spec = makeSnapshot({ x: makeKey({ fontSize: 14 }) });
    const live = makeSnapshot({ x: makeKey({ fontSize: 15 }) });
    const result = compare(spec, live, { tolPx: 1 });
    const diff = result.diffs.find(d => d.prop === 'font-size');
    assert.equal(diff, undefined, 'font-size diff=1 with tolPx=1 should pass');
  });

  test('boundary: delta=2 tolPx=1 fails', () => {
    const spec = makeSnapshot({ x: makeKey({ fontSize: 14 }) });
    const live = makeSnapshot({ x: makeKey({ fontSize: 16 }) });
    const result = compare(spec, live, { tolPx: 1 });
    const diff = result.diffs.find(d => d.prop === 'font-size');
    assert.ok(diff, 'font-size diff=2 with tolPx=1 should fail');
  });
});

describe('compare — approved', () => {
  test('approved suppresses failing but keeps diff listed', () => {
    // Build keys manually so only style.height differs (rect.h is equal)
    const specKey = {
      rect: { x: 0, y: 0, w: 100, h: 40 },
      style: { height: 40, width: 100, display: 'flex', 'font-size': 14, color: 'rgba(0,0,0,1)' },
      text: 'hello', childCount: 2,
    };
    const liveKey = {
      rect: { x: 0, y: 0, w: 100, h: 40 },          // rect.h intentionally same
      style: { height: 45, width: 100, display: 'flex', 'font-size': 14, color: 'rgba(0,0,0,1)' },
      text: 'hello', childCount: 2,
    };
    const spec = makeSnapshot({ btn: specKey });
    const live = makeSnapshot({ btn: liveKey });
    const result = compare(spec, live, {
      tolPx: 1,
      approved: { 'btn.height': 'design deviation approved' },
    });
    const heightDiff = result.diffs.find(d => d.prop === 'height');
    assert.ok(heightDiff, 'approved diff must still appear in diffs');
    assert.equal(heightDiff.approved, true, 'approved flag must be true');
    assert.equal(heightDiff.reason, 'design deviation approved');

    const failingDiff = result.failing.find(d => d.prop === 'height');
    assert.equal(failingDiff, undefined, 'approved diff must NOT appear in failing');
    assert.equal(result.summary.failing, 0, 'failing count must be 0');
  });

  test('wildcard approved suppresses all props for that key', () => {
    const spec = makeSnapshot({ btn: makeKey({ h: 40, fontSize: 14 }) });
    const live = makeSnapshot({ btn: makeKey({ h: 45, fontSize: 16 }) });
    const result = compare(spec, live, {
      tolPx: 0,
      approved: { 'btn.*': 'all deviations approved' },
    });
    assert.ok(result.diffs.length > 0, 'diffs still listed');
    assert.equal(result.failing.length, 0, 'no failing with wildcard approval');
  });
});

describe('compare — missing key', () => {
  test('key in spec but missing from live is reported', () => {
    const spec = makeSnapshot({ btn: makeKey(), label: makeKey() });
    const live = makeSnapshot({ btn: makeKey() });
    const result = compare(spec, live, { tolPx: 1 });
    const missing = result.diffs.find(d => d.key === 'label' && d.prop === '(missing)');
    assert.ok(missing, '"label" missing from live should be reported');
    assert.equal(missing.approved, false);
    assert.ok(result.failing.find(d => d.key === 'label'));
  });
});

describe('compare — text', () => {
  test('text compared with whitespace collapse', () => {
    const spec = makeSnapshot({ x: makeKey({ text: 'hello   world' }) });
    const live = makeSnapshot({ x: makeKey({ text: 'hello world' }) });
    const result = compare(spec, live, { tolPx: 1 });
    // both collapse to 'hello world'
    const textDiff = result.diffs.find(d => d.prop === 'text');
    assert.equal(textDiff, undefined, 'whitespace-collapsed texts should match');
  });

  test('text diff is reported when content changes', () => {
    const spec = makeSnapshot({ x: makeKey({ text: 'Hello' }) });
    const live = makeSnapshot({ x: makeKey({ text: 'World' }) });
    const result = compare(spec, live, { tolPx: 1 });
    const textDiff = result.diffs.find(d => d.prop === 'text');
    assert.ok(textDiff, 'changed text must be reported');
  });

  test('ignoreText skips text comparison', () => {
    const spec = makeSnapshot({ x: makeKey({ text: 'Hello' }) });
    const live = makeSnapshot({ x: makeKey({ text: 'World' }) });
    const result = compare(spec, live, { tolPx: 1, ignoreText: true });
    const textDiff = result.diffs.find(d => d.prop === 'text');
    assert.equal(textDiff, undefined, 'ignoreText should skip text diff');
  });
});

describe('compare — rect', () => {
  test('rect w/h compared with tolPx', () => {
    const sp = makeKey();
    sp.rect = { x: 10, y: 20, w: 100, h: 40 };
    const lv = makeKey();
    lv.rect = { x: 50, y: 80, w: 100, h: 43 }; // x/y differ (not compared), h differs by 3
    const result = compare(makeSnapshot({ el: sp }), makeSnapshot({ el: lv }), { tolPx: 1 });
    const rectH = result.diffs.find(d => d.prop === 'rect.h');
    assert.ok(rectH, 'rect.h diff of 3 with tolPx=1 should be reported');
    const rectX = result.diffs.find(d => d.prop === 'rect.x');
    assert.equal(rectX, undefined, 'rect.x should NOT be compared');
  });
});

// ─── renderMarkdown ───────────────────────────────────────────────────────────

describe('renderMarkdown', () => {
  test('zero diffs emits "0 divergences" line', () => {
    const result = { diffs: [], failing: [], summary: { keys: 3, compared: 3, diffs: 0, approved: 0, failing: 0 } };
    const md = renderMarkdown(result);
    assert.ok(md.includes('0 divergences'), `Expected "0 divergences" in: ${md}`);
  });

  test('failing diff renders ❌', () => {
    const spec = makeSnapshot({ btn: makeKey({ h: 40 }) });
    const live = makeSnapshot({ btn: makeKey({ h: 50 }) });
    const result = compare(spec, live, { tolPx: 1 });
    const md = renderMarkdown(result, { specLabel: 'Mockup', liveLabel: 'Live' });
    assert.ok(md.includes('❌'), `Expected ❌ in:\n${md}`);
  });

  test('approved diff renders ☑︎', () => {
    const spec = makeSnapshot({ btn: makeKey({ h: 40 }) });
    const live = makeSnapshot({ btn: makeKey({ h: 50 }) });
    const result = compare(spec, live, {
      tolPx: 1,
      approved: { 'btn.height': 'approved' },
    });
    const md = renderMarkdown(result, { specLabel: 'Mockup', liveLabel: 'Live' });
    assert.ok(md.includes('☑︎'), `Expected ☑︎ in:\n${md}`);
  });

  test('summary line present with key counts', () => {
    const spec = makeSnapshot({ btn: makeKey({ h: 40 }) });
    const live = makeSnapshot({ btn: makeKey({ h: 50 }) });
    const result = compare(spec, live, { tolPx: 1 });
    const md = renderMarkdown(result);
    assert.ok(md.includes('Summary'), `Expected Summary in:\n${md}`);
    assert.ok(md.includes('failing'), `Expected "failing" in:\n${md}`);
  });

  test('column headers include custom specLabel and liveLabel', () => {
    const spec = makeSnapshot({ x: makeKey({ h: 40 }) });
    const live = makeSnapshot({ x: makeKey({ h: 50 }) });
    const result = compare(spec, live, { tolPx: 1 });
    const md = renderMarkdown(result, { specLabel: 'ApprovedMockup', liveLabel: 'Staging' });
    assert.ok(md.includes('ApprovedMockup'), `Expected custom specLabel in:\n${md}`);
    assert.ok(md.includes('Staging'), `Expected custom liveLabel in:\n${md}`);
  });
});

// ─── RED-THEN-GREEN demonstration ─────────────────────────────────────────────
// We show that compare() correctly catches a diff when called with tolPx=0
// (deliberately strict, so delta=1 fails) and passes at tolPx=1.

describe('RED-THEN-GREEN demonstration', () => {
  const spec = makeSnapshot({ el: makeKey({ h: 40 }) });
  const live = makeSnapshot({ el: makeKey({ h: 41 }) }); // 1px deviation

  test('RED: tolPx=0 reports height diff of 1px', () => {
    const result = compare(spec, live, { tolPx: 0 });
    const diff = result.diffs.find(d => d.prop === 'height');
    // This MUST find a diff — delta=1 exceeds tolPx=0
    assert.ok(diff, 'Expected height diff at tolPx=0 (this is the RED case)');
    assert.equal(diff.delta, 1);
    assert.equal(result.failing.length > 0, true);
  });

  test('GREEN: tolPx=1 passes the same 1px deviation', () => {
    const result = compare(spec, live, { tolPx: 1 });
    const diff = result.diffs.find(d => d.prop === 'height');
    // delta=1 == tolPx=1 → within tolerance → no diff
    assert.equal(diff, undefined, 'Expected NO height diff at tolPx=1 (GREEN case)');
    assert.equal(result.failing.length, 0);
  });
});

// ─── Pseudo-element keys ──────────────────────────────────────────────────────

/**
 * Build a pseudo-element snapshot entry.
 * rect=null, childCount=null, style has 'content' and MEASURED_PROPS.
 */
function makePseudoKey({ fontSize = 10, content = '"★"', text = '★' } = {}) {
  return {
    rect: null,
    childCount: null,
    style: {
      'font-size': fontSize,
      content,
      // include a few other props as they would appear from getComputedStyle
      color: 'rgba(0,0,0,1)',
      display: 'inline',
    },
    text,
    selector: '.node',
    pseudo: '::before',
  };
}

describe('compare — pseudo-element keys', () => {
  test('matching pseudo font-size produces no diff', () => {
    const spec = makeSnapshot({ icon: makePseudoKey({ fontSize: 10 }) });
    const live = makeSnapshot({ icon: makePseudoKey({ fontSize: 10 }) });
    const result = compare(spec, live, { tolPx: 1 });
    assert.equal(result.diffs.length, 0, 'identical pseudo keys should produce no diffs');
  });

  test('mismatching pseudo font-size is reported', () => {
    const spec = makeSnapshot({ icon: makePseudoKey({ fontSize: 10 }) });
    const live = makeSnapshot({ icon: makePseudoKey({ fontSize: 14 }) });
    const result = compare(spec, live, { tolPx: 1 });
    const diff = result.diffs.find(d => d.prop === 'font-size');
    assert.ok(diff, 'font-size mismatch in pseudo should be reported');
    assert.equal(diff.delta, 4);
    assert.ok(result.failing.length > 0);
  });

  test('rect=null skips rect.w and rect.h comparison', () => {
    // Both sides have rect=null → no rect diffs
    const spec = makeSnapshot({ icon: makePseudoKey() });
    const live = makeSnapshot({ icon: makePseudoKey() });
    const result = compare(spec, live, { tolPx: 0 });
    const rectDiff = result.diffs.find(d => d.prop.startsWith('rect.'));
    assert.equal(rectDiff, undefined, 'rect=null on both sides must not produce rect diffs');
  });

  test('rect=null on one side skips rect comparison', () => {
    // spec side has a real rect, live side is pseudo (null rect) → no rect.w/h diff
    const sp = makePseudoKey({ fontSize: 10 });
    sp.rect = null; // explicit null
    const lv = makePseudoKey({ fontSize: 10 });
    lv.rect = null;
    const result = compare(makeSnapshot({ x: sp }), makeSnapshot({ x: lv }), { tolPx: 0 });
    assert.equal(result.diffs.find(d => d.prop.startsWith('rect.')), undefined,
      'null rect on either side skips rect comparison');
  });

  test('childCount=null skips childCount comparison', () => {
    const sp = makePseudoKey();
    sp.childCount = null;
    const lv = makePseudoKey();
    lv.childCount = null;
    const result = compare(makeSnapshot({ x: sp }), makeSnapshot({ x: lv }), { tolPx: 0 });
    assert.equal(result.diffs.find(d => d.prop === 'childCount'), undefined,
      'null childCount must not be compared');
  });

  test('pseudo absent in live (key missing) is reported as (missing)', () => {
    // In the live snapshot, the pseudo key is omitted — simulates content:none being
    // filtered out at measure time, leaving the key absent from live.keys
    const spec = makeSnapshot({ icon: makePseudoKey() });
    const live = makeSnapshot({}); // icon absent
    const result = compare(spec, live, { tolPx: 1 });
    const missing = result.diffs.find(d => d.key === 'icon' && d.prop === '(missing)');
    assert.ok(missing, 'absent pseudo key must be reported as (missing)');
    assert.ok(result.failing.find(d => d.key === 'icon'));
  });

  test('pseudo content mismatch is reported via style.content', () => {
    const spec = makeSnapshot({ icon: makePseudoKey({ content: '"★"', text: '★' }) });
    const live = makeSnapshot({ icon: makePseudoKey({ content: '"✦"', text: '✦' }) });
    const result = compare(spec, live, { tolPx: 1 });
    const diff = result.diffs.find(d => d.prop === 'content');
    assert.ok(diff, 'content value mismatch should be reported as a style.content diff');
  });
});
