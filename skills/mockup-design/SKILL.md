---
name: mockup-design
description: >-
  Create web-based HTML/CSS mockups during UI feature planning AND prove the
  implementation matches the approved mockup with the project-agnostic fidelity
  gate (mockup-spec → mockup-diff → side-by-side PNG sent to the user). Use when
  planning UI features, designing interfaces, wireframing, prototyping visual
  layouts before implementation, and BEFORE declaring any mockup-backed UI task
  done. Triggers on: UI planning, mockup, wireframe, prototype, design preview,
  layout planning, visual design, interface design, before implementing a UI
  feature, match the mockup, mockup fidelity,
  verify against mockup.
---

# Mockup Design — author, then prove fidelity

`<skill-dir>` below means this skill's install directory (for example `~/.claude/skills/mockup-design`).

A mockup is a **measurable spec**, not a picture. Every mockup-backed UI task has
two halves: author the mockup (Steps 1–4) and prove the implementation matches it
(Step 5). A task is not done until Step 5's diff is clean and the user has the
side-by-side image.

## Step 1: Discover the project's code patterns

Before writing any mockup code, identify: framework, style system, existing UI
components, design tokens/theme, file naming conventions. For a re-skin of an
existing component, also read its REAL DOM (template + CSS) — the mockup must be
buildable on that DOM.

## Step 2: Build the mockup (the contract)

**Case A — modifying existing UI:** replicate the actual component using its real
CSS/tokens. **Case B — new feature:** write it in the project's framework, naming
and tokens, as if it were the real implementation living in `docs/mockups/`.

Rules that make the mockup verifiable (all mandatory):

1. **Real viewport, real scale.** The window/screen frame in the mockup is sized at
   the real target viewport (e.g. 812×375 landscape phone), not a decorative
   620×320 "phone" bezel. Page chrome (dark page background, headings, Option A/B
   galleries, notes) is fine, but the frame itself must be one element that
   contains exactly the UI being specified.
2. **Real CSS, not invented tokens.** Use the project's own variables/classes
   (e.g. `MobileShell.css` house style) and, for sibling consistency, the same
   titlebar/close/tab metrics siblings use. No private `--pg-*` palettes.
3. **Every element that matters carries `data-m="<key>"`** (titlebar, title,
   close, tabs, active tab, list, one representative row and its parts, action bar
   and its buttons, modal parts…). Keys are stable identifiers reused by the map
   file in Step 5. Legacy mockups without `data-m` can use a `keys.json` instead.
4. **Header comment** at the top listing the real project files/patterns referenced
   and the frame selector to use for the spec (e.g. `<!-- frame: .phone:nth-of-type(5) .win -->`).
5. **State frames.** One frame per distinct state that must be verified (empty
   list, populated list, modal open, leader vs member…). Each gets its own spec.

## Step 3: Location, preview, approval

- **Location:** `docs/mockups/` only — never `/tmp`, project root, or scratchpad.
- **Preview:** open the file in the user's browser (`open docs/mockups/x.html`) or
  screenshot it with headless Chrome and show the PNG. Do NOT publish to Artifact
  unless the user asks for it in that instance.
- **Iterate** until the user explicitly approves. Record the approval and the frame
  selectors in the task file.

## Step 4: Extract the spec, then delegate with the spec

Immediately after approval, run the extractor for each approved frame:

```
NODE_PATH="$(npm root -g)" node <skill-dir>/scripts/mockup-spec.cjs \
  --mockup docs/mockups/<name>.html --frame "<frame selector>" [--keys keys.json] \
  --viewport 812x375 --scale 2 --out docs/mockups/spec/<name>-<state>/
```

Outputs `spec.json` (rect + computed style + text + child count per key) and
`mockup.png` (the frame only). Commit them next to the mockup.

Then write `map.json`: `{ root, keys: { key → live selector }, approved: {}, require: { bodyClass, viewport } }`
(see `scripts/README.md`). The map IS the mockup→DOM mapping table — build it by
reading the real DOM, never by copying mockup class names.

The implementer agent's prompt must contain: the `spec.json` values (or its path),
the `map.json`, and the acceptance criterion "mockup-diff exits 0". Never delegate
with "match the mockup visually" / "make it look like the mockup".

## Step 5: Fidelity gate (required before "done")

1. Write a project adapter (`adapter.cjs` exporting `open() → { page, close }`) that
   returns a Playwright page already showing the UI in the correct mode and
   viewport. Projects keep adapters next to their test harness (e.g. `e2e/mockup-adapter.cjs`).
2. Run the gate:
   ```
   NODE_PATH="$(npm root -g)" node <skill-dir>/scripts/mockup-diff.cjs \
     --spec docs/mockups/spec/<name>-<state>/spec.json --map map.json --adapter adapter.cjs \
     --out <scratchpad>/fidelity/<name>-<state>/
   ```
   It refuses to run when `require.bodyClass`/`viewport` do not hold (verifying in
   the wrong mode is the classic false pass), writes `diff.md`, `diff.json`,
   `live.png`, `side-by-side.png`, and exits 1 on any unapproved divergence.
3. **Every divergence is either fixed or approved by the user** — approved ones go
   into `map.json` → `approved` with the reason. Never mark something approved
   yourself; never widen `tolPx` to make it pass.
4. **Send the image.** Show `side-by-side.png` to the user (`open <png>` and give
   the path) together with the diff table in the final report. Do not ask the user
   to "refresh and check" — the gate output is the proof, and the user must see it.
5. Re-run the gate after every later visual fix in the same task; the last report
   before closing the task must be a clean run for every approved frame.

## Cleanup

After implementation is complete and the gate is clean, remove the mockup HTML
but keep `spec/` + `map.json` if the project wants regression protection
(re-running Step 5 later catches drift); otherwise remove `docs/mockups/` entirely.

---

Scripts, contracts, exit codes: `scripts/README.md`. Unit tests: `NODE_PATH="$(npm root -g)" node --test <skill-dir>/scripts/*.test.cjs` (fidelity-lib 41 specs + mockup-diff.timeout: mockup-diff must not inherit an adapter's short page default timeout — it sets its own after `open()` and detects absent keys with `count()`, so adapters need no tiny default).
