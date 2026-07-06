# Medaka playground e2e harness

A Playwright harness that drives a **real browser** against the built
playground so agents/humans can verify frontend changes (CodeMirror 6
mounting, syntax highlighting, running a program, inline type-error squiggles)
instead of relying only on headless-logic tests
(`playground/tokenizer_test.mjs`, `playground/squiggle_test.mjs`).

## What it checks

1. The page loads and CodeMirror 6 mounts (`.cm-editor .cm-content` present,
   no legacy `<textarea>`).
2. The funnel strip (`#funnel-strip`) renders on first load, dismisses on
   `#funnel-dismiss` click, and stays dismissed across a reload
   (`localStorage`-backed).
3. Syntax highlighting is active (>5 highlighted `<span>`s, >=3 distinct
   token colors).
4. The default sample program runs (`#run-btn` click) and the unified
   `#console` pane shows the expected stdout plus a "compiled & ran in NN ms"
   meta line.
5. Injecting a type-error buffer (`main = println (1 + "hello")`) produces an
   inline squiggle (`.cm-lintRange-error`), a gutter marker
   (`.cm-lint-marker-error`), and the right message rendered as a problem line
   inside `#console` ("No impl of Num for String").
6. Hover-type and autocomplete (unchanged data path via `window.__mdkLang`).
7. The Examples picker (`#example-select`) swaps in the `hello` sample, which
   then runs and prints its greeting.
8. Share round-trip: `#share-btn` encodes the current buffer into a `#code=`
   URL hash; reloading at that URL restores the exact program in the editor.

A screenshot is captured after each test into `screenshots/` (gitignored) for
human eyeballing: `01_loaded.png`, `02_highlighting.png`, `03_run_output.png`,
`04_squiggle.png`, `05_hover.png`, `06_completion.png`, `07_examples.png`,
`08_share_roundtrip.png` (plus `ERROR.png` if the harness itself throws).

## How to run

```sh
cd playground/e2e
./run.sh
```

That's it — `run.sh`:
- puts node v24 on `PATH` (falls back to whatever `node` finds if the fixed
  nvm path doesn't exist on your machine — but the version check below still
  gates on v24+);
- checks `playground/dist/playground.wasm` exists, and tells you to run
  `bash playground/build_playground_wasm.sh` first if not (this harness never
  builds the ~2.6MB wasm itself);
- runs `npm install` once if `node_modules/playwright` is missing;
- starts `playground/server.js` on `PORT` (default 8099, override via env),
  waits for it to answer, runs the Playwright spec against it, and **always**
  tears the server down afterward (even on failure);
- exits non-zero if any check fails.

You can also just run the test spec directly against an already-running
server: `node tests/playground.spec.mjs http://localhost:8099/ ./screenshots`.

## Gotchas (read before "fixing" something that isn't broken)

- **No Playwright browser download.** `npx playwright install chromium` fails
  with `UNABLE_TO_GET_ISSUER_CERT_LOCALLY` on this machine (TLS interception).
  Do **not** try to work around this by disabling TLS verification. Instead
  every test launches `chromium.launch({ channel: 'chrome' })`, i.e. the
  **system Google Chrome** — `npm install playwright` itself (just the JS
  driver, no browser binary) works fine over the network.
- **node v20 (the system default on some shells) can't run the playground** —
  it doesn't support finalized WasmGC. You need **node v24+**.
- **`dist/` is gitignored.** A fresh worktree/clone has no
  `dist/playground.wasm`. Build it (`bash playground/build_playground_wasm.sh`)
  or copy an already-built `playground/dist/` over before running this
  harness.
- **The Run button is disabled until the WasmGC module finishes loading** —
  tests wait for `#run-btn:not([disabled])` before clicking it.
- **Editor content is set via a debug hook, not simulated typing.**
  `playground/main.js` exposes `window.__mdkView` (the CM6 `EditorView`);
  tests set the buffer with
  `v.dispatch({changes:{from:0,to:v.state.doc.length,insert:'...'}})`.
- Single-threaded WasmGC needs no COOP/COEP headers, so the plain
  `playground/server.js` static server is sufficient — no special dev server
  required.
