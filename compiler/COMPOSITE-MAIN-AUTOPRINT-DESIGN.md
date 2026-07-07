# Composite-`main` Auto-Print — Design (Option A: uniform auto-print)

Status: DESIGN (2026-07-07). Chosen direction = **Option A** (auto-print ALL main
types on both `run` and `build`, killing the run/build divergence). Owning task:
playground-filed deferred item "Bare non-Unit `main` — run/build divergence +
composite-main emitter crash" (PLAN.md 2026-07-06).

> ⚠️ **UPDATE 2026-07-07 — §2's in-process re-elaborate mechanism is UNSOUND; superseded.**
> An implementation attempt proved that `elaborateModules` is **not cleanly
> re-runnable in one process**: the first elaboration pollutes global
> dict/instance-dispatch state, so the "elaborate → inspect → wrap → re-elaborate"
> flow mis-resolves dispatch on the second pass. Concretely, an **underived-ADT
> main** (`main = G`, type has no `Display`) wrapped to `println G` then
> re-elaborated **silently defaults dispatch to `Int` and builds a binary that
> prints garbage `17179869185`, exit 0** — a miscompile regression, WORSE than
> today's clean `cannot print an ADT value` error. (Explicit `main = println G`
> with a *single* elaborate correctly errors `No impl of Display for C` — the
> double-elaborate is the corruptor.) The GOOD cases all work byte-identical
> run==build (tuples/lists/scalars/deriving-enums, Unit-main-not-doubled).
> **Confirmed renderer: `println` renders via `display`** (raw strings, `(a, b)`
> tuples, `True`) — so the wrap is `main = println <body>`.
> The sound path is either (a) a two-process wrap (CLI detects main type via its
> clean gate, emitter does the single clean elaborate — but does NOT cover the
> **single-process in-browser playground**), or (b) making in-process
> re-elaborate sound via a `resetElaborationState()`. **Mechanism resolution is
> under investigation** (which global state pollutes; is a reset feasible; what
> covers build + wasm-CLI + in-browser-playground with least scope). `run`
> (single-process interpreter) is a separate bite; for now it keeps warning.

## 1. Reproduction (confirmed on `54344aba`)

| Program | `medaka run` | `medaka build` + exec |
|---|---|---|
| `main = 42` | warns `W-MAIN-SHAPE`, no output | `42\n` |
| `main = "hi"` | warns, no output | `hi\n` (raw) |
| `main = 6.0` | warns, no output | `6.0\n` |
| `main = True` | warns, no output | `true\n` (lowercase!) |
| `main = ("abc", 1.23)` | warns, no output | **crash** |
| `main = [1,2,3]` | warns, no output | **crash** |
| `main = SomeCtor` (bare ADT) | warns | **crash** |

Build crash string:
```
error: emitter failed compiling …
llvm spike: cannot print an ADT value (slice 3: `main` must reduce to a scalar Int/Bool/Float)
```
Emitted at `compiler/backend/llvm_emit.mdk:8690-8692` (`emitPrint _ _ LTCon`);
closure sibling `:8693-8695`. Run-side warning: `medaka_cli.mdk:397`
(`mainNonUnitMsg`) via `mainNonUnitWarning` (`:412`), gated by
`mainTypeIsUnit () || mainTypeIsAsync ()`.

### How build auto-prints scalars today
`llvm_emit.mdk` `emitProgram` (`@mdk_program_main` builder): `:8572`
`emitExpr` → `(mv, mty)`; `:8583` Float-hint override; `:8584`
`if mainIsUnit e mty2 then () else emitPrint e mv mty2`. `emitPrint`
(`:8670-8695`) hard-codes scalar printers and **panics** on `LTCon`/`LTClosure`.

Main type threaded via `mainSchemeRef` (`typecheck.mdk:2150`); queries
`mainTypeIsUnit` (`:2172`), `mainTypeIsFloat` (`:2183`), `mainTypeIsAsync`
(`:2162`); pushed to emitter by `installMainIsUnitHint`/`installMainIsFloatHint`
(`llvm_emit.mdk:8641,8652`) from the emit drivers
(`entries/llvm_emit_modules_main.mdk:78-80`).

### Wasm (playground path)
`wasm_emit.mdk` mirrors it: `emitRefMain` (`:2294`) → `refMainKind` (`:2377`,
scalar kinds only) → `refPrintFor` (`:2462`, scalar imports only);
`mainBodyIsUnit` (`:2317`); `mainIsFloatHintRef` (`:306`). No composite print →
composite main gaps/misprints. Playground entry `runEmit`
(`entries/playground_main.mdk:283-295`).

## 2. Recommended mechanism — source-level rewrite of entry `main`, then re-elaborate

Reduce main auto-print to the existing polymorphic print path. When the elaborated
`main` is a **bare non-Unit value**, rewrite the entry decl:

```
main = <e>      ⟶      main = putStrLn (<render> <e>)
```

where `<render>` is `debug` or `display` (fork F1), then re-run
`elaborateModules` so the `Debug`/`Display` dict for `<e>`'s type is resolved and
dict-passed normally. **No emitter change required** — the rewritten `main` is an
ordinary `<IO> Unit` program every backend already compiles; composites work for
free via dict-passing (build) / `VMulti` dispatch (run).

### Verified viable (in worktree, `54344aba`)
- Build `main = putStrLn (debug ("abc",1.23))` → `("abc", 1.23)`;
  `println [1,2,3]` → `[1, 2, 3]`; `deriving (Debug)` ADT → `Red`.
- **Run/eval dispatches `debug`/`println` on composites even on the untyped path**
  → `medaka run` output byte-matches `build`-exec. Run and build byte-match with
  zero extra machinery.
- Trailing newline already matches (`putStrLn`/`println` append `\n`, as the
  current scalar printers do).

### Why not a special-cased composite printer in the emitter
Emitting `debug <mainType>` at emit time needs the resolved `Debug` dict; if the
program never called `debug`, that dict was never instantiated → you'd re-implement
dict resolution (recursive `Debug (a,b) requires Debug a, Debug b`). Source-rewrite
+ re-elaborate lets the existing elaborator do it. Rejected.

### The one cost — re-elaborate
Must know `main` is non-Unit *before* rewriting (wrapping a Unit
`main = println "hi"` double-prints). So: **elaborate once → inspect main kind → if
bare non-Unit value, rewrite entry decl → elaborate again → emit/eval.** Unit mains
(the common case, incl. every compiler entry) never take the second pass.
`elaborateModules` is already called twice on the `check` path
(`medaka_cli.mdk:431`), so re-runnability is established.

### Per-backend
Backend-agnostic (source AST). Each driver, after its existing `elaborateModules`,
calls a shared `autoPrintWrap` returning `(coreD, modules, didWrap)`; if wrapped,
re-elaborate before `emitProgram`/eval.
- **LLVM** `entries/llvm_emit_modules_main.mdk:68-80` — insert wrap+re-elaborate;
  wrapped main lowers to `LTUnit`, `emitPrint LTCon` panic path becomes dead.
- **Wasm** `entries/wasm_emit_modules_main.mdk` (~`:68-80`) — identical;
  `mainBodyIsUnit` True; printing flows through compiled `debug`+`putStrLn`.
- **Playground** `entries/playground_main.mdk:283-295` `runEmit` — same insertion;
  this is what stops the playground crashing on composites.
- **Run/eval** `medaka_cli.mdk:870-890` `runRunCmd` — rewrite entry decl,
  re-elaborate, `runProgramOutput`. Replace `mainNonUnitWarning` value-main path
  with the wrap; keep `mainArityWarning` (function-shaped main) as error.

### Rejected cheaper run-only fallback (fork F3)
Run could `ppValue (force mainVal)` (`eval.mdk:109`, renders any
`VTuple/VList/VCon/VRecord`) without re-elaborate — but `ppValue` uses
`true`/raw-strings/`(a, b)`, so run would NOT byte-match build. Since Option A's
goal is to kill the divergence, prefer the unified rewrite.

## 3. Touchpoint map

**typecheck / main-kind (reused as-is, no change):**
`typecheck.mdk:2150` `mainSchemeRef`, `:2162` `mainTypeIsAsync`, `:2172`
`mainTypeIsUnit`, `:2183` `mainTypeIsFloat`.

**Shared helper (new):** in `medaka_cli.mdk` (or small shared module). Reuse
`findMainFunDef` (`medaka_cli.mdk:380`) to extract the entry `main` body; build
`DFunDef _ "main" [] (EApp putStrLn (EApp render body))`. New
`autoPrintWrap`/`shouldAutoPrintMain` gated on
`not (mainTypeIsUnit () || mainTypeIsAsync ())` AND empty param list.

**LLVM emit driver:** `entries/llvm_emit_modules_main.mdk:68…80`.
(`llvm_emit_typed_main.mdk:66`, `llvm_bootstrap_lex_main.mdk:75` are fixed-purpose;
likely no change — verify they can't receive user non-Unit mains.)

**Wasm emit driver:** `entries/wasm_emit_modules_main.mdk` (~`:68-80`);
`entries/playground_main.mdk:283-295` `runEmit`.

**eval / run:** `medaka_cli.mdk:870-890` `runRunCmd` (wrap+re-elaborate branch).
`eval.mdk:2425` `evalModulesOutput` / `:2235` `runMainForEffect` unchanged if
rewrite is upstream (recommended); touched only for the `ppValue` fallback.

**CLI guard (behavior change):** `medaka_cli.mdk:412` `mainNonUnitWarning` — retire
for value mains. `:403` `mainArityWarning` — KEEP. `:397` `mainNonUnitMsg` —
delete/repurpose. Leave emitter panics `llvm_emit.mdk:8690`, `wasm_emit.mdk`
scalar gaps in place as dead-path guards (protects the seed).

## 4. Error vs auto-print delineation

- **Auto-print (new):** any bare zero-arg value `main = <e>` whose inferred type
  is not `Unit`/`Async _` — scalars, strings, tuples, lists, records, ADTs.
  Requires a `Debug`/`Display` instance; a bare underived ADT yields a clean
  typecheck error (`No impl of Debug for T; add 'deriving Debug'`) instead of the
  crash — strictly better.
- **Still error/warning:** function-shaped `main () =`/`main x =`
  (`mainArityWarning`, arity ≥ 1). `Async _` main keeps `runAsync` routing
  (`medaka_cli.mdk:917`).

## 5. Effect typing
No obstacle. `println`/`putStrLn` are `<IO>`; `debug`/`display` are pure.
Wrapped `main : <IO> Unit` is the ordinary main signature.

## 6. Re-mint verdict — NO seed re-mint (if confined to drivers)
Every in-graph compiler `main` is Unit/`<IO>`-typed → `autoPrintWrap` never fires
on the compiler graph → emitter output byte-identical → fixpoint stable.
**Prerequisite:** do NOT modify `emitProgram`/`emitPrint`/`refMainKind`/`refPrintFor`
logic (leave the dead scalar-panic path). Keep the change in entry drivers +
`medaka_cli` (+ eval fallback only). If implementation instead touches those emitter
functions, re-mint IS owed — avoid.

## 7. Staging (ascending risk; each independently gated + mergeable)

- **Bite 1 — shared `autoPrintWrap` + LLVM build.** (Opus) Add helper; wire
  `llvm_emit_modules_main.mdk`. Gate: composite-main fixtures build+exec correctly;
  `selfcompile_fixpoint` C3a/C3b green (proves compiler graph unchanged). Shares
  `medaka_cli.mdk` with Bite 2 → sequence first.
- **Bite 2 — run/eval parity.** (Opus, shares `medaka_cli.mdk`) Replace
  `mainNonUnitWarning` value path with wrap+re-elaborate in `runRunCmd`. Gate:
  `run` output byte-matches `build`-exec; `mainArityWarning` still fires for
  `main x =`.
- **Bite 3 — wasm + playground.** (Opus) Wire `wasm_emit_modules_main.mdk` +
  `playground_main.mdk`. Gate: wasm oracle builds composite-main fixtures;
  playground no longer crashes on `("abc",1.23)`.
- **Bite 4 — cleanup.** (Sonnet) Retire `mainNonUnitMsg`/dead `mainNonUnitWarning`;
  refresh doc comments. Gate: full `make medaka` + fixpoint green; no output change.

## 8. Design forks (need a human decision)

**F1 (biggest) — `debug` vs `display` for `<render>`.**

| value | current build | `display` | `debug` |
|---|---|---|---|
| `True` | `true` | `True` | `True` |
| `"hi"` | `hi` | `hi` | `"hi"` |
| `6.0` | `6.0` | `6.0` | `6.0` |
| `("abc",1.23)` | crash | `(abc, 1.23)` | `("abc", 1.23)` |

Either choice changes existing scalar `Bool` output `true`→`True`. `debug`
additionally quotes strings (round-trippable, matches doctests/`deriving Debug`);
`display` keeps raw strings (matches the `println` UX the current warning message
recommends, closest to today's output). Both require the type to HAVE the chosen
instance.

**F2 — Trailing newline.** `putStrLn`/`println` append `\n`, matching today's
scalar printers. Recommend keep.

**F3 — Must `run` and `build` byte-match?** Recommended mechanism gives it for
free; the `ppValue` run-fallback would diverge. Option A's goal → yes.

**F4 — Records: field names?** Rendered via the derived instance;
`run` uses the same wrapped `debug` so it matches build.

**F5 — Underived ADT/record main** → clean typecheck error (`add 'deriving …'`)
instead of a crash. Recommend accept (vs auto-deriving, a larger change).
