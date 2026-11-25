'use strict';

// ─── Measured props ──────────────────────────────────────────────────────────
const MEASURED_PROPS = [
  'display', 'flex-direction', 'flex-wrap', 'justify-content', 'align-items',
  'gap', 'width', 'height',
  'padding-top', 'padding-right', 'padding-bottom', 'padding-left',
  'margin-top', 'margin-bottom',
  'font-size', 'font-weight', 'line-height',
  'color', 'background-color', 'background-image',
  'border-top-width', 'border-top-color', 'border-bottom-width', 'border-bottom-color',
  'border-radius', 'box-shadow',
  'text-align', 'white-space', 'overflow-y', 'opacity',
];

// ─── Color normalization ─────────────────────────────────────────────────────

/**
 * Parse any CSS color token into rgba(r,g,b,a).
 * Returns the trimmed input unchanged if it cannot be parsed.
 */
function normalizeColor(str) {
  if (typeof str !== 'string') return str;
  str = str.trim();
  if (!str) return str;

  // gradient / complex: normalize each color token inside
  if (str.startsWith('linear-gradient') || str.startsWith('radial-gradient') ||
      str.startsWith('-webkit-linear-gradient') || str.startsWith('-webkit-radial-gradient')) {
    return str
      .replace(/#[0-9a-fA-F]{3,8}/g, m => normalizeColor(m))
      .replace(/rgba?\([^)]+\)/g, m => normalizeColor(m))
      .replace(/\s+/g, ' ');
  }

  // #rgb → #rrggbb
  let m;
  if ((m = str.match(/^#([0-9a-fA-F]{3})$/))) {
    const [r, g, b] = [...m[1]].map(c => parseInt(c + c, 16));
    return `rgba(${r},${g},${b},1)`;
  }
  // #rrggbb
  if ((m = str.match(/^#([0-9a-fA-F]{6})$/))) {
    const hex = m[1];
    const r = parseInt(hex.slice(0, 2), 16);
    const g = parseInt(hex.slice(2, 4), 16);
    const b = parseInt(hex.slice(4, 6), 16);
    return `rgba(${r},${g},${b},1)`;
  }
  // #rrggbbaa
  if ((m = str.match(/^#([0-9a-fA-F]{8})$/))) {
    const hex = m[1];
    const r = parseInt(hex.slice(0, 2), 16);
    const g = parseInt(hex.slice(2, 4), 16);
    const b = parseInt(hex.slice(4, 6), 16);
    const a = Math.round(parseInt(hex.slice(6, 8), 16) / 255 * 1000) / 1000;
    return `rgba(${r},${g},${b},${a})`;
  }
  // rgb(r,g,b) or rgb(r g b)
  if ((m = str.match(/^rgb\(\s*(\d+)[,\s]+(\d+)[,\s]+(\d+)\s*\)$/i))) {
    return `rgba(${m[1]},${m[2]},${m[3]},1)`;
  }
  // rgba(r,g,b,a)
  if ((m = str.match(/^rgba\(\s*(\d+)[,\s]+(\d+)[,\s]+(\d+)[,\s]+([\d.]+)\s*\)$/i))) {
    const a = Math.round(parseFloat(m[4]) * 1000) / 1000;
    return `rgba(${m[1]},${m[2]},${m[3]},${a})`;
  }
  // named colors: pass through (browsers return rgb() for them anyway)
  return str;
}

// ─── Value normalization ─────────────────────────────────────────────────────

const COLOR_PROPS = new Set([
  'color', 'background-color', 'border-top-color', 'border-bottom-color',
]);

/** Return true if the value looks like a px number (e.g. "16px", "0px"). */
function isPxValue(v) {
  return typeof v === 'string' && /^-?[\d.]+px$/.test(v.trim());
}

/**
 * Normalize a computed-style value for comparison.
 * - Color props: normalizeColor
 * - px numbers: parse and round to 2 decimal places
 * - background-image gradients: normalizeColor on embedded colors + collapse ws
 * - everything else: trimmed string
 */
function normalizeValue(prop, value) {
  if (typeof value !== 'string') return value;
  value = value.trim();

  if (COLOR_PROPS.has(prop)) {
    return normalizeColor(value);
  }

  if (prop === 'background-image') {
    return normalizeColor(value); // gradient handler fires inside normalizeColor
  }

  if (isPxValue(value)) {
    return Math.round(parseFloat(value) * 100) / 100;
  }

  return value;
}

// ─── Compare ─────────────────────────────────────────────────────────────────

// Style props iterated in compare() — MEASURED_PROPS plus 'content' for pseudo keys.
// For regular elements 'content' is absent from their style dict (undefined on both
// sides), so the `undefined+undefined → skip` guard prevents false diffs.
const COMPARE_PROPS = [...MEASURED_PROPS, 'content'];

function collapsedText(s) {
  if (typeof s !== 'string') return '';
  return s.replace(/\s+/g, ' ').trim();
}

/**
 * Compare spec vs live snapshots.
 *
 * @param {object} spec - { keys: { [key]: { rect, style, text, childCount } } }
 * @param {object} live - same shape
 * @param {object} opts - { tolPx=1, tolPct=0, approved={}, ignoreProps=[], ignoreText=false }
 * @returns {{ diffs, failing, summary }}
 */
function compare(spec, live, opts = {}) {
  const {
    tolPx = 1,
    tolPct = 0,
    approved = {},
    ignoreProps = [],
    ignoreText = false,
  } = opts;

  const ignoreSet = new Set(ignoreProps);
  const diffs = [];

  const specKeys = Object.keys(spec.keys || {});

  for (const key of specKeys) {
    const sp = spec.keys[key];
    const lv = live.keys ? live.keys[key] : undefined;

    if (!lv) {
      const approvedKey = approved[`${key}.(missing)`] || approved[`${key}.*`];
      diffs.push({
        key, prop: '(missing)',
        expected: '(present)', actual: '(absent)',
        delta: null,
        approved: !!approvedKey,
        reason: approvedKey || null,
      });
      continue;
    }

    // Compare rect w/h (not x/y)
    for (const dim of ['w', 'h']) {
      if (sp.rect && lv.rect) {
        const a = sp.rect[dim];
        const b = lv.rect[dim];
        if (a !== undefined && b !== undefined) {
          const delta = Math.abs(a - b);
          const threshold = Math.max(tolPx, tolPct > 0 ? (a * tolPct / 100) : 0);
          if (delta > threshold) {
            const propKey = `rect.${dim}`;
            const approvedKey = approved[`${key}.${propKey}`] || approved[`${key}.*`];
            diffs.push({
              key, prop: propKey,
              expected: a, actual: b,
              delta,
              approved: !!approvedKey,
              reason: approvedKey || null,
            });
          }
        }
      }
    }

    // Compare style props (MEASURED_PROPS + 'content' for pseudo keys)
    for (const prop of COMPARE_PROPS) {
      if (ignoreSet.has(prop)) continue;

      const spVal = sp.style ? sp.style[prop] : undefined;
      const lvVal = lv.style ? lv.style[prop] : undefined;

      if (spVal === undefined && lvVal === undefined) continue;

      const spNorm = normalizeValue(prop, spVal ?? '');
      const lvNorm = normalizeValue(prop, lvVal ?? '');

      let pass = false;
      let delta = null;

      if (typeof spNorm === 'number' && typeof lvNorm === 'number') {
        delta = Math.abs(spNorm - lvNorm);
        const threshold = Math.max(tolPx, tolPct > 0 ? (spNorm * tolPct / 100) : 0);
        pass = delta <= threshold;
      } else {
        pass = spNorm === lvNorm;
      }

      if (!pass) {
        const approvedKey = approved[`${key}.${prop}`] || approved[`${key}.*`];
        diffs.push({
          key, prop,
          expected: spVal, actual: lvVal,
          delta,
          approved: !!approvedKey,
          reason: approvedKey || null,
        });
      }
    }

    // Compare text
    if (!ignoreText) {
      const spText = collapsedText(sp.text || '');
      const lvText = collapsedText(lv.text || '');
      if (spText !== lvText) {
        const approvedKey = approved[`${key}.text`] || approved[`${key}.*`];
        diffs.push({
          key, prop: 'text',
          expected: spText.slice(0, 100), actual: lvText.slice(0, 100),
          delta: null,
          approved: !!approvedKey,
          reason: approvedKey || null,
        });
      }
    }

    // Compare childCount — skip when either side is null (pseudo-element keys)
    if (sp.childCount !== undefined && sp.childCount !== null &&
        lv.childCount !== undefined && lv.childCount !== null) {
      if (sp.childCount !== lv.childCount) {
        const approvedKey = approved[`${key}.childCount`] || approved[`${key}.*`];
        diffs.push({
          key, prop: 'childCount',
          expected: sp.childCount, actual: lv.childCount,
          delta: Math.abs(sp.childCount - lv.childCount),
          approved: !!approvedKey,
          reason: approvedKey || null,
        });
      }
    }
  }

  // Keys in live map but not in spec → unmapped (only when live.keys has extras vs spec)
  // Per spec: keys in spec but not in map → '(unmapped)' diffs
  // (These are added by mockup-diff when it detects keys in spec missing from map)
  // The compare function itself only handles spec keys vs live keys.

  const failing = diffs.filter(d => !d.approved);
  const summary = {
    keys: specKeys.length,
    compared: specKeys.length,
    diffs: diffs.length,
    approved: diffs.filter(d => d.approved).length,
    failing: failing.length,
  };

  return { diffs, failing, summary };
}

// ─── Render Markdown ─────────────────────────────────────────────────────────

/**
 * Render a markdown table from compare() results.
 * @param {object} result - return value of compare()
 * @param {object} opts - { specLabel='Mockup', liveLabel='Live' }
 */
function renderMarkdown(result, { specLabel = 'Mockup', liveLabel = 'Live' } = {}) {
  const { diffs, summary } = result;

  if (diffs.length === 0) {
    return `**0 divergences** — all ${summary.keys} keys match ${liveLabel}.\n`;
  }

  const rows = [
    `| key | prop | ${specLabel} | ${liveLabel} | delta | status |`,
    '|-----|------|' + '-'.repeat(specLabel.length + 2) + '|' + '-'.repeat(liveLabel.length + 2) + '|-------|--------|',
  ];

  for (const d of diffs) {
    const status = d.approved ? '☑︎' : '❌';
    const key = String(d.key);
    const prop = String(d.prop);
    const exp = d.expected !== null && d.expected !== undefined ? String(d.expected).slice(0, 60) : '—';
    const act = d.actual !== null && d.actual !== undefined ? String(d.actual).slice(0, 60) : '—';
    const delta = d.delta !== null && d.delta !== undefined ? String(Math.round(d.delta * 100) / 100) : '—';
    rows.push(`| ${key} | ${prop} | ${exp} | ${act} | ${delta} | ${status} |`);
  }

  rows.push('');
  rows.push(
    `**Summary**: ${summary.keys} keys · ${summary.diffs} divergence(s) · ` +
    `${summary.approved} approved · **${summary.failing} failing**`
  );

  return rows.join('\n') + '\n';
}

// ─── Exports ─────────────────────────────────────────────────────────────────

module.exports = {
  MEASURED_PROPS,
  normalizeColor,
  normalizeValue,
  compare,
  renderMarkdown,
};
