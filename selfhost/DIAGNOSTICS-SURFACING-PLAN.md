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

## Key facts (verified live on the binary, 2026-06-21)

- **Human messages already exist** for every class: `ppResError`
  (`selfhost/frontend/resolve.mdk:858`) + typecheck `(msg, Option Loc)` pairs. The
  raw sexp is only the plain-text path calling `resErrorSexp` (`resolve.mdk:805`).
- **Type-error positions are byte-identical to the oracle** in `--json` already
  (full `ELoc`/`currentLoc` threading done, gated green).
- **Positions genuinely missing at the source for exactly two classes:** resolve
  (`ResError` ctors `resolve.mdk:60-115` carry NO `Loc`) and exhaust/guard
  warnings (`diagnostics.mdk:114` passes `None`). Parse errors have a near-correct
  loc with a **line off-by-one** + message-case mismatch (`"parse error"` vs
  oracle `"Parse error"`, `medaka_cli.mdk:269-273`).

## Render fork (today)

CLI forks at `selfhost/driver/medaka_cli.mdk:124`:
- **plain text** → `runCheckCmd` → `runCheck` (`selfhost/tools/check.mdk:50`) —
  deliberately location-free; emits `resErrorSexp` for resolve, `"TYPE ERROR: …"`
  for type, `"parse error"` for parse. Also emits the success `=== TYPES ===`
  scheme dump (gated byte-identical — do NOT disturb).
- **`--json`** → `runCheckJsonCmd` (`medaka_cli.mdk:263`) → `analyzeLocated`
  (`selfhost/driver/diagnostics.mdk:92`) — already humane + positioned for type;
  resolve gets the message but a **placeholder whole-doc range** (`loc=None`
  fallback, `diagnostics.mdk:106`).

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

- `selfhost/frontend/resolve.mdk` — `ResError` type :60, `resErrorSexp` :805,
  `ppResError` :858 (S1 swap + S3 span threading).
- `selfhost/driver/diagnostics.mdk` — `analyzeFrom` :99, resolve `loc=None` :106,
  `ppDiag`/`ppDiagLoc` :70-73 (the loc seam).
- `selfhost/driver/medaka_cli.mdk` — `runCheckCmd` :104, `runCheckJsonCmd` :263,
  parse-err block :269 (plain re-route + parse fix).
- `selfhost/tools/check.mdk` — `runCheck` :50, `routeImportCheck` :68 (message
  swap; host of `diff_selfhost_check`).
- `test/diff_selfhost_check_json.sh` + `test/check_json_fixtures/` — the only
  position-sensitive gate (add parse/resolve fixtures).
</content>
</invoke>
