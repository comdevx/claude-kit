# Mockup Fidelity Gate

Machine-readable diff between an approved HTML mockup and the live UI.
Three CLIs, one Node.js ≥ 18 runtime, Playwright as the only dependency.

## Setup

```sh
export NODE_PATH="$(npm root -g)"   # any node_modules dir that contains playwright
```

No `npm install` needed — Playwright is resolved via `NODE_PATH`.

---

## 1. mockup-spec.cjs — extract the approved spec

```sh
node mockup-spec.cjs \
  --mockup path/to/approved.html \
  --frame  ".frame-group:nth-child(6) .phone .win" \
  --keys   keys.json \
  --viewport 812x375 \
  --scale  2 \
  --out    out/spec-dir/
```

**Outputs**: `out/spec-dir/spec.json` · `out/spec-dir/mockup.png`

**`--frame`** — CSS selector for the one window/panel to measure (first match used).
If `.phone` elements share no common parent, use `:nth-child` on the container
(`".gallery > div:nth-child(6) .phone .win"`).

**`--keys`** — JSON object `{ "keyName": "css-selector-relative-to-frame" }`.
A key may also be `{ "selector": "...", "nth": 0 }` to pick a specific match.
If omitted, every `[data-m="key"]` attribute inside the frame is used.

---

## 2. mockup-diff.cjs — diff live UI against spec

```sh
node mockup-diff.cjs \
  --spec    out/spec-dir/spec.json \
  --map     map.json \
  --adapter file-adapter.cjs \
  --out     out/diff-dir/ \
  --tol-px  1 \
  --labels  "Mockup,Live"
```

**Outputs**: `diff.json` · `diff.md` · `live.png` · `side-by-side.png`

**Exit code**: `1` when failing diffs exist, `0` when all diffs are approved or absent.

---

## 3. compose-side-by-side.cjs — standalone composer

```sh
node compose-side-by-side.cjs left.png right.png out.png \
  --labels "Mockup,Live" \
  --title  "Party Window — v1.3 vs main"
```

---

## map.json contract

```json
{
  "root": ".frame-group:nth-child(6) .phone .win",
  "keys": {
    "titlebar": ".win-titlebar",
    "row":      { "selector": ".mrow", "nth": 1 }
  },
  "approved": {
    "hpTxt.text":   "HP format is a user-approved deviation",
    "avatar.*":     "Avatar styling intentionally changed"
  },
  "ignoreProps": ["opacity"],
  "ignoreText":  false,
  "require": {
    "bodyClass": "mobile-shell",
    "viewport":  [812, 375]
  }
}
```

Keys in `spec.json` but absent from `map.keys` → `(unmapped)` failing diff.
`approved` entries: `"<key>.<prop>"` or `"<key>.*"` (wildcard all props for key).

Measurement normalisers (opt-in, not approvals — use only for differences that are invisible by construction):
- `"renderedChildrenOnly": true` — `childCount` ignores `display:none` children (e.g. a game UI's hidden
  custom-scrollbar node that the app's scrollbar script injects). Extract the spec with `mockup-spec.cjs --rendered-children-only` to match.
- `"decodedImageKeys": ["btn-info", ...]` — for these keys `background-image` is compared by decoded canvas pixels
  (FNV hash), not by URL bytes: same bitmap, different encoding (mockup BMP→PNG vs the app's packed-asset data URI). Every `url()`
  layer is hashed (multi-layer backgrounds keep their layer order and non-url layers); a `file://` url from a spec
  extracted from disk is read by mockup-diff and decoded in the live page as a `data:` url, so an http(s) live page can
  be compared with a file:// mockup. Never list a key whose image is part of the change under review.
- `mockup-spec.cjs` always extracts with `prefers-reduced-motion: reduce`, so give looping mockup animations a
  reduced-motion rule or they are captured mid-frame.

### Pseudo-element keys

A key value may include a `"pseudo"` field to measure a CSS `::before` / `::after`
instead of the element itself:

```json
"leaderStar": { "selector": ".party .node:nth-of-type(2)", "pseudo": "::before" }
```

- `style` = `getComputedStyle(el, pseudo)` over all measured props plus `content`
- `text` = the `content` value with surrounding CSS quotes stripped
- `rect` = `null` (pseudo-elements have no layout box)
- `childCount` = `null`
- If the pseudo's computed `content` is `none` the key is treated as absent →
  `(missing)` diff when spec has it but live does not.
- Works identically in `--keys` (mockup-spec) and `map.keys` (mockup-diff).

---

## Adapter contract

An adapter is a `.cjs` file that exports:

```js
module.exports = {
  async open() {
    // Return a Playwright page already showing the UI.
    // Must use the same deviceScaleFactor as --scale in mockup-spec.
    return { page, close: async () => { await browser.close(); } };
  }
};
```

### Minimal file:// adapter example

```js
'use strict';
module.exports = {
  async open() {
    const { chromium } = require('playwright');
    const browser = await chromium.launch({ channel: 'chrome', headless: true });
    const context = await browser.newContext({
      viewport: { width: 812, height: 375 },
      deviceScaleFactor: 2,
    });
    const page = await context.newPage();
    await page.goto('file:///path/to/live.html', { waitUntil: 'load' });
    await page.evaluate(() => document.fonts.ready);
    return { page, close: async () => browser.close() };
  }
};
```

---

## Exit codes

| Code | Meaning |
|------|---------|
| 0    | All diffs absent or approved |
| 1    | One or more failing (unapproved) diffs |

---

## Running unit tests

```sh
NODE_PATH="$(npm root -g)" node --test <skill-dir>/scripts/*.test.cjs   # 43 specs (fidelity-lib 41 + mockup-diff.timeout 2; the bare-directory form does not resolve on node 26)
```
