# PLAYGROUND-EDITOR-DESIGN.md — Tier 3 in-browser editor

Decision-ready design for upgrading the server-free playground (`playground/`) from a
plain `<textarea>` to TypeScript-playground-grade editing: syntax highlighting, inline
red squiggles, hover-types, autocomplete. **Read-only design pass — nothing implemented.**

---

## 1. Goal & scope

**Tier 3 = a real code editor with a browser language service:**
1. **Syntax highlighting** — Medaka tokens colored to match the dark UI.
2. **Inline squiggles** — type/parse diagnostics underlined at their range (not just a text pane).
3. **Hover types** — hover an identifier → its inferred type.
4. **Autocomplete** — identifier/keyword completion at the cursor.

**Out for v1:** go-to-definition, find-references, rename, formatting-on-save, document
symbols/outline, inlay hints, semantic-token highlighting (we use a lexer grammar instead),
signature help, multi-file projects in the editor (single buffer only — the playground is
one file today). All of these have compiler implementations already (`compiler/tools/lsp.mdk`)
and can be added later through the same seam; they are deferred only to bound v1.

---

## 2. Recommended architecture (headline)

**Editor: CodeMirror 6.** **Language service: stateless per-request wasm entries** (NOT an
LSP server loop in wasm). **Highlighting: a hand-written stream tokenizer** (CM6
`StreamLanguage`) derived from the compiler lexer's token classes. **Bundling: ESM via an
import-map + pinned CDN URLs, vendored into `playground/vendor/` so the static-site /
zero-network-after-load property holds** — no bundler/build step added.

Rationale in one paragraph: the playground's whole value prop is *server-free, static,
zero-build*. CM6 is pure ESM and theme-via-data (no AMD `vs/` loader, no web-worker
indirection of its own), so it drops into the existing module-worker setup without a
bundler. The language service must respect the wasm host's **one-shot** execution model
(§3), which rules out porting the streaming LSP loop; instead we add small stateless
`analyze`/`hover`/`complete` wasm entries that mirror the existing `playground_main.mdk`
analyze→JSON path — and reuse the LSP's already-pure hover/complete functions verbatim.

---

## 3. Feasibility findings — the LSP-loop-in-wasm verdict

### Verdict: **The persistent LSP server loop CANNOT run in the browser wasm host. Use stateless one-shot entries instead.** (High confidence.)

**Evidence — the LSP is a blocking stdio loop:**
- `serve`/`serveOnce` (`compiler/tools/lsp.mdk:1507`) repeatedly read one JSON-RPC message,
  dispatch, and loop until EOF/`exit`.
- `readHeaders` (`lsp.mdk:882`) is a **blocking recursive `readLineOpt ()` loop** accumulating
  `Content-Length`; `readExactly len` (`lsp.mdk:1487`) then blocks for exactly N bytes of body.
- Session state lives in a `Docs = Docs (List (String,String))` in-memory map plus two
  module-level parse-cache `Ref`s (`lsp.mdk:99-115`, `1183-1193`), mutated across messages.

**Evidence — the wasm host is strictly one-shot, no stdin/loop:**
- `compile.mjs:70-117` (`runGuest`) instantiates the module, the guest `(start)` runs **once to
  completion**, and termination is via `mdk_exit` throwing `ExitSignal` (`compile.mjs:105`).
  A second compile re-instantiates the module.
- The host IO ABI (`compile.mjs:85-106`) is **write-only stdout/stderr** (`mdk_write_byte`),
  static args (`mdk_arg_byte`), and pull-by-path vfs reads (`mdk_read_file`). **There is no
  `readLine`/incremental-stdin import, no threads, no event loop.** `readLineOpt`/`readExactly`
  — the LSP's transport primitives — simply do not exist in this host surface.

A streaming, stateful, blocking-read server has no execution substrate here. Porting it would
mean inventing a stdin-streaming host ABI *and* keeping a wasm instance live across messages
*and* a JS-side framing shim — a large surface, all to re-derive request handlers that are
already pure (below).

### Why stateless entries are the *right* fit, not just the fallback

The LSP's request handlers are **already pure functions of (source, line, col)** — they do a
fresh parse+typecheck per request and do **not** depend on accumulated server state (the
caches are only an import-graph optimization, irrelevant to a single-file playground buffer):
- `hoverFor` / `hoverEnvFor` (`lsp.mdk:515-617`, `533-548`) — fresh desugar+typecheck, look up
  the scheme at cursor.
- `completionFor` / `completionEnvFor` (`lsp.mdk:681-709`) — fresh env, filter names by cursor prefix.
- (inlay hints `lsp.mdk:760-798` likewise, deferred.)

So each becomes a **one-shot wasm entry** structured exactly like the proven
`playground_main.mdk` (`compiler/entries/playground_main.mdk`): read `runtime.mdk`/`core.mdk`/
the user buffer from the vfs, run the existing analyze/hover/complete function, print a
one-line `__MEDAKA_*__\n<json>` marker, `mdk_exit`. The JS seam (`compile.mjs`) already
demuxes that exact marker protocol (`compile.mjs:171-188`). This is a small, low-risk port
that reuses the LSP's own logic.

---

## 4. The three reuse seams (so tomorrow's implementers don't re-derive)

1. **Diagnostics → squiggles are nearly free.** `playground_main.mdk` already emits
   `__MEDAKA_DIAGNOSTICS__\n<json>` in **exact `medaka check --json` shape** — `{files:[{file,
   diagnostics:[{message, range:{start:{line,character},end},severity,source}]}]}` (compile.mjs:11-14,
   178-180). `main.js:renderDiagnostics` (`main.js:81-93`) already parses `.files[].diagnostics[]`
   into a text pane. Re-targeting that same object to editor decorations (CM6 `Diagnostic[]`)
   is a ~1:1 field map: `range.start/end` → `from/to` offsets, `severity 1/2` → `"error"/"warning"`.
   **No compiler work for squiggles** — the analyze path already runs on every compile.
2. **The `compile.mjs` marker seam generalizes.** Adding `hover`/`complete` is: a new wasm entry
   + a new marker (`__MEDAKA_HOVER__`, `__MEDAKA_COMPLETE__`) + a thin `compile.mjs` sibling fn
   (`analyze(src)`, `hover(src,line,col)`, `complete(src,line,col)`) that passes line/col as extra
   argv and demuxes the new marker. The vfs/host-ABI boilerplate (`runGuest`) is reused verbatim.
3. **The highlighting grammar is already documented** (§5) from the compiler lexer — no need to
   reverse-engineer `parser.mly`/`lexer.mdk` again.
4. **The WasmGC self-host trick** (`build_playground_wasm.sh`: native emitter → WAT →
   `wasm-tools` → validate) is the build recipe for any new entry; a new `*_main.mdk` entry
   builds identically.

---

## 5. Highlighting grammar — token-class census (from `compiler/frontend/lexer.mdk` + `SYNTAX.md`)

Derived empirically; cite-backed. **A stateless regex tokenizer suffices for *coloring*** (we do
NOT need layout for highlighting — INDENT/DEDENT/NEWLINE are synthetic and invisible to the user).

| Class | Detail | lexer.mdk |
|-------|--------|-----------|
| **Keywords (28)** | `let rec with mut in if then else match data record interface default impl import export public where of do as extern requires deriving type newtype prop test bench effect internal function` | `295-328` |
| **Line comment** | `--` to EOL | `344-347` |
| **Block comment** | `{- … -}`, **nestable** (depth-tracked) | `348-350,369` |
| **String** | `"…"`, escapes `\n\t\r\0\\\"`, `\u{HEX}`; **interpolation `\{expr}`** | `479-517,709-718` |
| **Triple string** | `"""…"""` raw multiline + interpolation | `540-584` |
| **Char** | `'…'` same escapes | `658-695` |
| **Int** | decimal `[0-9][0-9_]*`; **hex `0x` / bin `0b` / oct `0o`** | `415-455` |
| **Float** | `int.digits` — **no scientific notation** (`1e3` rejected; known lexer gap) | `462-476` |
| **Operators** | 2-char: `== != <= >= && \|\| :: ++ \|> >> << => -> <- [\| \|] {. .* .. .= ...`; 1-char: `+ - * / % < > = : , . \| ! ? @` | `725-775` |
| **Identifiers** | `TIdent` lowercase vs **`TUpper` Capitalized — lexically distinguished** (color types/ctors differently); backtick `` `f` `` infix; `_` wildcard | `382-407` |
| **Note** | `True`/`False` are `TUpper`, **not** keywords | `293` |

**Effort:** A CM6 `StreamLanguage` stream tokenizer covers all of the above in ~150 lines (the
two stateful bits — nested block comments and string interpolation — use the stream state object,
which `StreamLanguage` supports). **Do NOT attempt a Lezer grammar** — Medaka's layout
(`lexer.mdk:814-1000`: indentation stack + previous-token + trailing/leading-op + application
continuation) is not LR-expressible, and we don't need a parse tree for coloring. A Monarch
grammar (if Monaco were chosen) is comparable effort but its nested-comment/interpolation
support is weaker than CM6's stream-state.

---

## 6. Wiring & performance

**Flow per keystroke (debounced):**
```
editor change → debounce(250ms) → languageWorker.analyze(buffer)
   → __MEDAKA_DIAGNOSTICS__ json → CM6 setDiagnostics() (squiggles)
hover event   → languageWorker.hover(buffer,line,col)  → tooltip
ctrl-space    → languageWorker.complete(buffer,line,col) → completion list
```

**Worker placement: a dedicated language worker, separate from the run-compiler worker.**
`compiler-worker.js` is busy/blocked during a Run (instantiate + wat2wasm assemble). A second
module-worker (`language-worker.js`) imports the same `compile.mjs` seam and keeps the
playground.wasm instantiation warm for analyze/hover/complete. (The wasm is already fetched &
cached by `main.js:loadAssets` — `main.js:98-129`; share the bytes.)

**Perf budget.** The front-end lexer is ~90× the tree-walker and the 2.59 MB wasm is already
loaded, so a fresh parse+typecheck of a single playground buffer is sub-100ms range. Strategy:
- **Diagnostics:** debounce 250–400 ms after last keystroke; cancel in-flight (re-instantiate is cheap).
- **Hover:** on-demand only (no debounce needed — fires on mouseover).
- **Completion:** on trigger (`ctrl-space` / `.`), debounced 150 ms.
- One wasm **instance reused** across analyze calls in the language worker (instantiate once,
  call the start entry per request — note: each call still re-runs the guest start, so "reuse"
  = reuse the *compiled module*, re-instantiate per call, which is what `runGuest` already does cheaply).

---

## 7. Design forks — NEED A HUMAN DECISION

1. **Editor: CodeMirror 6 (recommended) vs Monaco.**
   - *CM6* — pure ESM, ~ few-hundred-KB tree-shaken, theme = data, drops into the import-map/ESM
     worker setup with **no bundler**. Custom providers: `linter`/`setDiagnostics`, `hoverTooltip`,
     `autocompletion`, `StreamLanguage` tokenizer. **Best fit for the zero-build static-site goal.**
   - *Monaco* — the literal TS-playground editor, richest OOTB, but ~5 MB and historically wants an
     AMD `vs/` loader or a bundler/`MonacoEnvironment` worker shim; vendoring `min/vs` statically is
     possible but heavier and fights the ESM-module-worker setup. Providers: `setModelMarkers`,
     `registerHoverProvider`, `registerCompletionItemProvider`, Monarch tokenizer.
   - **Recommendation: CM6.** Pick Monaco only if exact-TS-playground-parity UX is a hard requirement.

2. **Language service: stateless wasm entries (recommended) vs full LSP-in-wasm.**
   - Full LSP-in-wasm is **infeasible without a new streaming-stdin host ABI** (§3) — not recommended.
   - Stateless `analyze`/`hover`/`complete` entries reuse the LSP's already-pure handlers. **Recommended.**
   - *Sub-fork:* do we even build hover/complete entries for v1, or ship **Tier-3-lite**
     (highlighting + squiggles only, zero compiler work) and add hover/complete later? (See fork 4.)

3. **Bundling: import-map + vendored ESM (recommended) vs add an esbuild step vs Monaco `min/vs`.**
   - The playground is **zero-build, statically served** today. Adding a bundler breaks that property
     and adds a CI/deploy step. **Recommended: vendor CM6's prebuilt ESM into `playground/vendor/`
     and reference via an import-map** (mirrors how `wat2wasm` is already vendored) — keeps zero-build.
   - **Human call:** is adding a one-time `esbuild`/`npm` build step to the playground acceptable? It
     would simplify dependency management but forfeits the "plain files served statically" guarantee.

4. **How much hover/completion in v1?** Options: (a) **squiggles + highlighting only** (no new
   compiler work, all frontend); (b) + **hover** (one new wasm entry); (c) + **completion** (second
   entry). Each is independently shippable (§8). **Human call:** ship (a) first, or go straight to (c)?

5. **Completion quality.** The LSP `completionFor` is **prefix-filtered names from the typecheck env**
   (`lsp.mdk:626-673`) — no scope-precise/dot-member completion. Acceptable for v1, or is richer
   completion expected? (Richer = more compiler work in the entry.)

---

## 8. Staged implementation plan (ascending risk; each independently shippable)

| Stage | What | Compiler work? | Effort | Risk |
|-------|------|----------------|--------|------|
| **S1 — Highlighting** | Swap `<textarea>`→CM6; vendor CM6 ESM + import-map; write the `StreamLanguage` tokenizer (§5); dark theme matching `index.html` palette (`#0d1117`/`#c9d1d9`, accents `#e2b96f`/`#58a6ff`). | **No** (pure frontend) | M | Low — token classes fully specced; only risk is the CM6-vendor/import-map plumbing. |
| **S2 — Squiggles** | Add a `language-worker.js`; on debounced change call `analyze` (reuse existing `__MEDAKA_DIAGNOSTICS__` path — **already emitted by `playground_main.mdk`**, no new entry needed); map `check --json` ranges → CM6 `setDiagnostics`. | **No** (the analyze JSON already exists) | S–M | Low — near-free; the diagnostics object is already produced and field-compatible. |
| **S3 — Hover entry** | New compiler entry `hover_main.mdk` wrapping `hoverFor` (`lsp.mdk:515`); argv adds `line col`; new `__MEDAKA_HOVER__` marker; build via `build_playground_wasm.sh` recipe. Add `compile.mjs` `hover()` sibling. | **Yes** (1 new wasm entry) | M | Med — first new entry; must thread cursor argv + confirm single-file hover env path (`lsp.mdk:533-548`) works without project graph. |
| **S4 — Completion entry** | New `complete_main.mdk` wrapping `completionFor` (`lsp.mdk:681`); `__MEDAKA_COMPLETE__`; `compile.mjs` `complete()`; CM6 `autocompletion` source. | **Yes** (1 new wasm entry) | M | Med — same shape as S3; plus the prefix-extraction at cursor. |
| **S4.5 — CM6 providers** | Wire `hoverTooltip` (S3) + `autocompletion` (S4) into the CM6 instance. | **No** | S | Low. |

**Recommended cut for v1:** **S1 + S2** ship a credible "real editor" (color + live squiggles) with
**zero compiler work** — this is "Tier-3-lite" and de-risks the editor/bundling choices before
touching the compiler. **S3/S4** (the two new wasm entries) follow once the editor seam is proven.

---

## 9. Risk register + decisive feasibility checks to run first

**Risks:**
- **R1 — CM6 vendoring vs zero-build (Med).** CM6's package graph (`@codemirror/*`, `@lezer/*`) is
  many small ESM modules; an import-map must pin them all, or we vendor a pre-rolled single ESM
  bundle. *Mitigation:* roll one prebuilt ESM file once (offline, esbuild) and commit it to
  `vendor/` as a static artifact — build-time only, **not** a playground build step. **Decide in fork 3.**
- **R2 — re-instantiation cost per analyze (Low/Med).** Every analyze re-runs the guest start. If a
  large buffer makes 250 ms-debounced analyze janky, raise debounce / cancel in-flight. *Measure first.*
- **R3 — single-file hover/complete env (Med).** The LSP hover/complete env path branches on
  imports (`lsp.mdk:533-548`); the playground is single-file, so the simpler `analyzeLocated`-style
  path applies — confirm `hoverEnvFor` works with no sibling modules before building S3.
- **R4 — cursor offset mapping (Low).** CM6 uses absolute offsets; the JSON ranges are line/character.
  A small bidirectional line/col↔offset map is needed in the worker glue.
- **R5 — wasm size (Low).** Adding hover/complete entries to the *same* `playground.wasm` grows it;
  or ship them as separate small wasms. Decide whether to bundle entries or split.

**Decisive checks to run first (in order):**
1. **Bundling spike (S1 blocker):** can a vendored CM6 ESM + import-map load and tokenize in the
   existing module-worker/static-serve setup with **no bundler**? If no → fork-3 decision forced.
2. **Squiggle round-trip (S2):** feed a known type-error buffer through the *existing* analyze path,
   confirm `range.start/end` maps cleanly to CM6 decoration offsets. (No new code in the guest.)
3. **Hover-entry spike (S3 gate):** build a throwaway `hover_main.mdk` calling `hoverFor` on a
   single-file buffer + cursor; confirm it emits a hover JSON and `hoverEnvFor` doesn't require the
   project graph. This validates the whole "new stateless entry" pattern before committing to S3/S4.

---

## 10. One-line summary for implementers

Ship **CM6 + a StreamLanguage tokenizer (§5) + reuse the existing `check --json` analyze output for
squiggles** first (S1+S2, zero compiler work); then add **two stateless one-shot wasm entries**
(`hover_main.mdk`, `complete_main.mdk`) that wrap the LSP's already-pure `hoverFor`/`completionFor`
through the proven `playground_main.mdk` marker seam — **never** the streaming LSP loop, which the
one-shot wasm host cannot run.
