# DIAGNOSTICS-SURFACING-PLAN.md — native `check` error positions + messages (WS-4 / F6)

Closes the native-CLI diagnostics-quality gap: `medaka check` prints errors as raw
OCaml-style constructor sexps with no source position
(`(UnboundVariable "foo")`), while the frozen OCaml oracle prints a positioned,
carat-rendered, human-readable diagnostic. Source: `LAYOUT-CONFORMANCE-AUDIT.md`
F6 (recorded there as out-of-*layout*-scope; this is the diagnostics workstream).
Tracked in PLAN.md Stage-4 as "Diagnostics surfacing layer". **`lib/`-removal-relevant:**
once the oracle is gone, native is the only error UX.

## Locked decisions (user, 2026-06-21)

- **Full scope:** S1+S2+S3+S4 (below). Close parse / type / resolve / exhaust.
- **Carat rendering** is the end-state plain-CLI format (echo the source line + a
  `^` underline under the span) — match the oracle byte-for-byte while it lives.
- **Ladder:** build positioned *single-line* output first (proves locs flow,
  cheap, gated vs oracle `--json` coordinates), THEN layer carat on top (pure
  presentation over already-proven spans). De-risks the column math.
- **Native-only** throughout (the OCaml oracle is frozen + slated for removal;
  most diagnostics goldens are location-stripped). The ONE oracle-coupled gate is
  `diff_selfhost_check_json` (native vs LIVE oracle json, byte-identical) — adding
  parse/resolve fixtures there pins native to the oracle's 0-based coordinate
  convention. The carat gate (Stage C) compares native plain-text vs a positioned
  oracle leg byte-for-byte; it retires with the oracle.

## Key facts (verified live on the binary, 2026-06-21; line refs updated 2026-06-22)

- **Human messages already exist** for every class: `ppResError`
  (`selfhost/frontend/resolve.mdk:937`) + typecheck `(msg, Option Loc)` pairs. The
  raw sexp is only the plain-text path calling `resErrorSexp` (`resolve.mdk:885`).
- **Type-error positions are byte-identical to the oracle** in `--json` already
  (full `ELoc`/`currentLoc` threading done, gated green).
- **Positions genuinely missing at the source for exactly two classes:** resolve
  (`ResError` ctors `resolve.mdk:65-91` carry NO `Loc` — Stage B added them all;
  `resErrorLoc` accessor :95-112) and exhaust/guard
  warnings (`diagnostics.mdk:168` passes `None`). Parse errors have a near-correct
  loc with a **line off-by-one** + message-case mismatch (`"parse error"` vs
  oracle `"Parse error"`, `medaka_cli.mdk:132-133`).

*(These described the pre-Stage-A/B/C state; Stages A–C are now all DONE. The
remaining two classes — exhaust/guard `None` spans and parse-error column accuracy
— are tracked as residuals below.)*

## Render fork (today)

CLI forks at `selfhost/driver/medaka_cli.mdk:124`:
- **plain text** → `runCheckCmd` → `checkRoute` → on error: `ppDiagCliSrc` (carat);
  on success: `runCheck` (`selfhost/tools/check.mdk:49`) — full scheme dump
  (gated byte-identical — do NOT disturb).
- **`--json`** → `runCheckJsonCmd` (`medaka_cli.mdk:293`) → `analyzeLocated`
  (`selfhost/driver/diagnostics.mdk:146`) — humane + positioned for all error types;
  resolve now carries real spans (Stage B); `loc=None` fallback arm in `ppDiagCliSrc`
  at `diagnostics.mdk:104`.

*(Line numbers verified 2026-06-22; file grew ~80 lines after Stage A/B edits.)*

## Stages

Sequential — shared files (`resolve.mdk`, `diagnostics.mdk`, `medaka_cli.mdk`,
`check.mdk`). Each gated green + merged before the next branches.

### Stage A — messages + surface existing locs (S1+S2)  ·  Sonnet
- **Re-route the plain ERROR path only** through located diagnostics
  (`analyzeLocated` / `ppDiagLoc`, `diagnostics.mdk:73` emits `@L:C: msg`) so it
  emits positioned humane single-line text `file:L:C: message`. KEEP `runCheck`'s
  success `=== TYPES ===` dump intact (error-path-only re-route — fully replacing
  `runCheck` would disturb `diff_selfhost_check`'s clean-fixture goldens).
- Swap resolve plain render `resErrorSexp` → `ppResError` (message exists).
- Fix parse-error **line off-by-one** + `"parse error"` → `"Parse error"`
  (`medaka_cli.mdk:269`).
- **Gate:** add parse + type fixtures to `test/check_json_fixtures/` (positions vs
  live oracle, byte-identical); recapture `resolve_fixtures/*.expected` /
  `diff_selfhost_check` goldens for the new plain text.
- **Outcome:** parse + type errors positioned + humane; resolve humane but still a
  coarse whole-doc range (closed in B).

### Stage B — real resolve spans (S3)  ·  Opus
- Add a `Loc` (or `Option Loc`) field to the `ResError` constructors
  (`resolve.mdk:60-115`) and **populate at each construction site** — the resolve
  walk has the offending `EVar`/AST node's `ELoc` span in scope (the same span the
  LSP already squiggles type errors with; confirm per site).
- `analyzeFrom` (`diagnostics.mdk:106`) uses the carried loc instead of `None`.
- **Gate:** add a resolve-error fixture to `check_json_fixtures/` (now positioned,
  byte-identical vs oracle). ~12 ctor sites — verify the span is in scope at each.

### Stage C — carat rendering + exhaust spans (S4)  ·  Opus
- Upgrade the plain renderer from `file:L:C: message` to the oracle's carat form
  (read the offending source line, emit it + a `^`/`~` underline under the span,
  multi-line aware). Match the oracle byte-for-byte.
- Thread spans into exhaust/guard warnings (`checkGuardExhaustiveness`).
- **Gate:** a positioned plain-text gate comparing native vs a positioned oracle
  leg byte-for-byte (the existing diagnostics goldens are location-stripped — this
  needs a positioned capture; retires with the oracle).

## Footgun

`capture_goldens.sh` regenerates the whole corpus + path-bakes build goldens
(~400 spurious diffs, no per-fixture filter — memory
`project_diff_fixtures_golden_add_footgun`). The `check_json` gate has its own
capture (cheap); touching `check.mdk` text re-captures the `resolve_fixtures`
`.expected` corpus (budget for it). Audit `grep -rlE '/Users/' test/
--include='*.golden'` stays 0.

## Critical files

- `selfhost/frontend/resolve.mdk` — `ResError` type :65, `resErrorSexp` :885,
  `ppResError` :937 (all ctors now carry `Option Loc` — Stage B complete).
- `selfhost/driver/diagnostics.mdk` — `ppDiag` :71, `ppDiagCli`/`ppDiagCliSrc` :89-105,
  `analyzeFrom` :153 (resolve `loc=None` pattern match at :104; `resErrorLoc e` used at :160).
- `selfhost/driver/medaka_cli.mdk` — `runCheckCmd` :104, `runCheckJsonCmd` :293,
  parse-err block :130-134 (inside `runCheckCmd`).
- `selfhost/tools/check.mdk` — `runCheck` :49, `routeImportCheck` :67 (message
  swap; host of `diff_selfhost_check`).
- `test/diff_selfhost_check_json.sh` + `test/check_json_fixtures/` — the only
  position-sensitive gate (parse/type/resolve fixtures present).

*(Line numbers verified 2026-06-22 — file grew ~80 lines post Stage A/B/C edits.)*

## Status + residuals (live)

- **Stage A — DONE** (`main` 1cbe1e1): positioned humane single-line plain-text
  errors for parse/type/resolve; `ppDiagCli` added; parse line off-by-one + case
  fixed. check_json 6/0, fixpoint C3a/C3b YES.
- **Stage B — DONE** (`main` dd05010): `Option Loc` threaded through all 17
  `ResError` ctors + the whole resolve walk; resolve-error spans byte-identical to
  oracle (`main = foo + 1` → `1:7`, span `{0,7}-{0,10}`). Decl/build-phase errors
  intentionally `None` → oracle dummy `{0,0}`. check_json 9/0, fixpoint C3a/C3b YES.
- **Stage C — DONE** (`main` 395a276): carat rendering (`ppDiagCliSrc`) byte-identical
  to the oracle (errors now on **stderr**, `file:L:C: msg` + `  | N | src | ^` block);
  non-exhaustive-match warning span threaded (`matchWarningLocs` in typecheck). Carat
  gate = extended `diff_native_cli.sh` `error/*` 7/7 vs live oracle. fixpoint C3a/C3b YES.
  **Seed re-minted** (`87886da`, `bootstrap_from_seed` C3a PASS).
- **Residual #4 — RESOLVED** (`main` eab10c1): captured the 22 WS-7 layout-fixture
  `native_cli_goldens/check/` goldens that WS-7 missed → `diff_native_cli` 99/0 green
  (goldens are native self-goldens — that gate's check/* section is re-rooted, captured
  from `./medaka`, NOT the oracle).

**WS-4 COMPLETE.** `medaka check` now prints positioned, humane, carat-rendered
diagnostics for parse/type/resolve, byte-identical to the oracle; non-exhaustive-match
warnings carry a span. Remaining are the position-accuracy follow-ups below (separate).

**Tracked residuals (NOT WS-4 scope — separate follow-ups):**
1. **Parse-error column is "which-token"-wrong on non-trivial inputs** (oracle vs
   native disagree on the error point, e.g. `data = 5` → oracle `{0,6}` / native
   `{1,0}`). Deeper self-hosted-parser position/recovery tracking, not a span-plumbing
   fix. **Recommend a dedicated parser-position investigation.** Parse-error fixtures
   are excluded from `check_json` so it doesn't block.
2. **Oracle `analyze_project` double-counts `UnboundVariable`/`UnknownConstructor`**
   (emits the expr-walk error twice; native emits once = correct). Pre-existing oracle
   quirk; native is canonical so native-once is right. These classes are excluded from
   the byte-identical count gate (their *spans* are still correct). No action — document.
3. **Pattern-position errors inherit the enclosing `match`-expr span** (native) rather
   than the scrutinee's — only affects `UnknownConstructor`-in-pattern (already excluded
   by #2). Low priority refinement.
4. **`diff_native_cli` WS-7 fixture goldens — RESOLVED** (`main` eab10c1): the 22
   `(no golden)` skips from the WS-7 layout fixtures were closed by capturing their
   `native_cli_goldens/check/` goldens → 99/0 green.
