# Medaka — Roadmap

The working handoff between sessions. Read it before starting a task; update it
when you finish one. This document holds only **forward-looking** work — the
completed Phases (1–141, with their detailed implementation notes) live in
[`PLAN-ARCHIVE.md`](./PLAN-ARCHIVE.md). When a phase here is finished, move its
write-up to the archive and leave only what remains. For how to build/test and
the codebase's non-obvious gotchas, see [`AGENTS.md`](./AGENTS.md). The detailed,
living record of the self-host port is [`selfhost/README.md`](./selfhost/README.md).

## Current status (2026-06-05)

The OCaml compiler pipeline is complete end-to-end —
`lexer → parser → desugar → resolve → method_marker → typecheck (runs exhaust)
→ eval` — with phases through ~141 done (see PLAN-ARCHIVE.md). The language has
records, ADTs, interfaces (with superinterfaces, `deriving`, dictionary-passing
for return-position/multi-param dispatch), effect rows, exhaustiveness checking,
`do`-notation, guards (with fall-through + exhaustiveness lint), list
comprehensions, string interpolation, type aliases/newtypes, container literals
(`Map { k => v }` / `Set { x }`), property testing, doctests, **unit tests**
(Phase 127), an LSP server, a formatter, and a project-config/`medaka new` surface.

The stdlib in Medaka is **complete** across `core`, `list`, `array`, `string`
(frozen, Phase 128), ordered `map`/`set`, mutable `hash_map`/`hash_set`,
`mut_array`, `io`, and `json` (STDLIB.md Modules 1–9 all done).

**The self-host port (Stage 1) is complete** — all eight pipeline stages are
ported to Medaka and validated byte-for-byte against the OCaml reference, and
the bootstrap closure ("the compiler processes its own source") has landed for
all four Legs A–D. See [North star → Stage 1](#stage-1--self-host-on-the-interpreter)
below and `selfhost/README.md` for the full slice log. A couple of
forward-looking performance levers remain (lexical addressing eval-consumption
half).

**Conventions.** Work is organized by numbered **Phases**; commit messages and
code comments reference them. Phases left *partial* keep their original number
(e.g. Phase 83/84, 101); genuinely new work gets the next free number (last used:
145). At task triage, match the work against AGENTS.md's task-playbook table and
load the matching skill before planning.

---

## North star — self-hosting, then LLVM

The long-term goal that orders everything below: **rewrite the Medaka compiler
in Medaka, then compile it to native code via LLVM.** Chosen path: **bootstrap on
the existing tree-walking interpreter first** — get a self-hosted compiler running
(slowly but correctly) on the interpreter, *then* build the LLVM backend so that
compiler emits native code.

Three stages, each a gate on the next.

### Stage 0 — Prerequisites before self-hosting can begin — ✅ COMPLETE

All Stage-0 prerequisites are met (details in PLAN-ARCHIVE.md):

- **Standard library breadth** — `Map`/`Set` (ordered) + `HashMap`/`HashSet`
  (mutable) + `mut_array`, `io`, and a finalized importable `string` are all done.
- **Language stability** — `do`→`Thenable`, guard exhaustiveness, plain
  multi-clause exhaustiveness, and the multi-module / return-position dispatch
  residuals are closed (only the nested/structured-dict residual #5 remains — see
  Phase 83/84 below; it does not block the port).
- **Interpreter performance** — "good enough to bootstrap" confirmed; the cost is
  typeclass dispatch + persistent-tree allocation, addressed opportunistically in
  the self-host perf work (`selfhost/PERF-NOTES.md`), not a blocker.
- **Multi-file ergonomics at scale** — scale-probed; cross-module user-defined
  interfaces (the one hard gap) closed by Phase 130.

### Stage 1 — Self-host on the interpreter — ✅ COMPLETE

Port the pipeline into Medaka, one stage at a time, checked against the OCaml
reference. The self-host tree lives in `selfhost/`, each stage validated against
the OCaml reference via a differential harness on the interpreter.

**All eight stages are ported and validated byte-for-byte** (full per-stage slice
logs in `selfhost/README.md`):

| Stage | Status | Validated against |
|-------|--------|-------------------|
| lexer (Phase 132) | ✅ | 17/17 fixtures + all 13 real `.mdk` files |
| parser (Phase 135) | ✅ | stdlib + `parse_fixtures` + `diff_fixtures` + self-source |
| desugar | ✅ | `astdump --desugar`, 95/95 corpus |
| resolve (single + multi-module) | ✅ | `diagdump --resolve[-modules]`, corpus + fixtures |
| method_marker | ✅ | `astdump --mark`, full corpus |
| exhaust (guard coverage) | ✅ | `diagdump --exhaust`, corpus + 5 fixtures |
| eval (untyped, typed/RKey, multi-module) | ✅ | `eval_probe` + all 16 `=== EVAL ===` goldens |
| typecheck | ✅ | `tc_probe` + all 16 `=== TYPES ===` goldens |

**Integration milestones beyond per-stage validation:**
- **Composed front-end** (`selfhost/check.mdk`) — parse → desugar → resolve →
  exhaust → typecheck in one program; reproduces all 16 TYPES goldens + the
  resolve diagnostics.
- **True execution** (`selfhost/eval_run_main.mdk`) — runs programs for stdout,
  matching all 16 `=== EVAL ===` goldens.
- **Typed eval path / return-position dispatch** (`selfhost/eval_typed_main.mdk`).

**The bootstrap closure** ("the compiler processes its own source"), validated by
`test/diff_selfhost_selfproc.sh`:
- ✅ **Leg A** — the self-hosted multi-module front-end typechecks all 12 selfhost
  modules of its own source and matches the OCaml reference.
- ✅ **Leg B** — the self-hosted eval engine executes a real selfhost stage (the
  lexer) identically to the `eval_modules` oracle.
- ✅ **Leg C** — the *typed* self-hosted eval executes a `Parser`-monad stage (the
  parser) identically to the oracle, via `typecheck.elaborateModules`.
- ✅ **Leg D** — the *typed* self-hosted eval executes the `typecheck.mdk` stage
  (also monadic → return-position dispatch) through `eval_typed_modules_main.mdk`,
  validated the same way Leg C validates the parser. See `selfhost/README.md`.

**Dictionary passing** for user `=>`-constrained functions is also ported
(`eval_dict_main.mdk` + `typecheck.elaborateDict`), including inferred/unsignatured
constraints and self/mutual recursion — beyond the RKey-only minimum the bootstrap
source needs (the selfhost source has no `=>`-constrained user polymorphism).

**Forward-looking performance levers** (backend-independent, cheap now / expensive
to retrofit — recorded so they aren't lost; not blocking):
- **Lexical addressing** — resolve emits a `(frame, slot)` address per variable
  reference to replace the assoc-list env scan. 🚧 IN PROGRESS: the EMIT half
  landed (resolve annotates `EVarAt`; harnesses byte-identical because consumption
  is unwired). The eval-consumption half (+ VThunk / Phase-112 shadow interaction)
  is the supervised follow-up. This is the top un-attempted perf lever.
- ✅ **Stdlib string builder** — killed the O(n²) `++` string-building in
  lexer/formatter via native `stringConcat` over cons-built lists (2026-06-05; see
  `selfhost/PERF-NOTES.md`).
- Larger levers (bytecode VM, decision-tree match compilation) are recorded as
  post-profiling work, and feed Stage 2.

### Stage 2 — LLVM backend (after self-host)

> **Backend-architecture decision (bytecode VM first vs. straight to LLVM):** see
> [`selfhost/STAGE2-DESIGN.md`](./selfhost/STAGE2-DESIGN.md). Recommends a Core IR
> + bytecode VM as a "Stage 1.5" on-ramp (conditionally), on differential-testing
> grounds — the bytecode VM is gated against the existing tree-walker oracle per
> slice, where LLVM-first is not. The staged plan there feeds the work items below.

With the language proven, build native codegen. The heavy, decision-dense work
deliberately deferred to here:

- **A frozen Core IR** as the codegen input: desugared, fully typed, effects
  erased, **dictionaries explicit**. The existing elaboration already inserts
  `EMethodRef`/`EDictApp` — this stage commits to it as a serializable lowering
  target.
- **Typeclass lowering strategy:** runtime dictionary passing (already the eval
  model) vs. monomorphization.
- **Memory model & value representation:** heap allocation, closure layout,
  tagged ADTs/records, boxing/unboxing.
- **Garbage collection:** conservative (Boehm) to start vs. reference counting
  vs. a precise collector.
- **Runtime library:** re-implement the `extern` catalog against the native
  runtime.
- **LLVM lowering:** Core IR → LLVM IR, calling convention, FFI.
- **Bootstrap closure:** self-hosted compiler + LLVM backend compiles itself to a
  standalone native binary — the finish line.

---

## Open roadmap

Each item is independently shippable; pick one per session. Grouped by area, not
strict priority.

### Self-host (Stage 1 tail)

- 🚧 **Lexical-addressing perf hook — eval-consumption half.** See Stage 1
  performance levers. Resolve already emits `EVarAt (frame, slot)`; wire eval to
  consume it (with the VThunk / Phase-112 shadow-bypass interaction) and measure.

> **Note for OCaml-compiler tasks below:** the self-host port mirrors the OCaml
> pipeline stage-for-stage (`selfhost/{lexer,parser,desugar,resolve,marker,
> exhaust,typecheck,eval}.mdk`). A change to a *ported* stage in `lib/` must be
> mirrored into the corresponding `selfhost/*.mdk` and re-validated with that
> stage's `test/diff_selfhost_*.sh`, or the differential harness breaks. Changes
> to *non-ported* parts (printer/`fmt`, diagnostics, the CLI driver, doctest) have
> no self-hosted counterpart.

### Compiler / language

- **Phase 145 — an explicit selective `import M.{name}` does not shadow a
  prelude binding of the same name. TODO.** A *local* top-level definition that
  collides with a prelude name shadows it correctly, but an explicit selective
  import of the same name does not — the call site still resolves to (and is
  typechecked against) the prelude binding. Repro (two files in one dir):
  ```
  -- helper.mdk
  export
  apply : Int -> Int -> Int
  apply x y = x + y
  -- main.mdk
  import helper.{apply}
  main = println (apply 3 4)
  -- → Type mismatch: a -> b vs Int
  --   (the prelude `apply : (a -> <e> b) -> a -> <e> b` is used at the call site,
  --    not helper's `apply : Int -> Int -> Int` — `3` is not a function)
  ```
  The control cases confirm the scope: a local `apply x y = …` defined directly in
  `main.mdk` *does* shadow the prelude (prints `7`), and a non-colliding imported
  name resolves fine — so the bug is specific to **imported names vs. the
  auto-injected prelude**. **Where it lives:** name-binding precedence in
  `lib/resolve.ml` (and `selfhost/resolve.mdk` for parity) — the implicit prelude
  frame is being consulted before, or coalesced ahead of, an explicit selective
  import. **Decision needed (design):** either (a) give an explicit `import
  M.{name}` precedence over the prelude (the conventional rule — explicit beats
  implicit), or (b) declare the prelude deliberately un-shadowable-by-import and
  document the alias convention. **Workaround in use:** `selfhost/eval.mdk` exports
  `applyValue = apply` so `selfhost/core_ir_eval.mdk` can import value-application
  unambiguously. Surfaced by the STAGE2 §2.1 Core IR session (the Core-IR evaluator
  importing `eval.{apply}` collided with the prelude's `apply`).

- **Phase 143 — block-`let` is non-recursive while expression `let … in …` is
  recursive: same surface form, opposite recursion. TODO (needs a design
  decision).** The identical syntax `let f x = … f …` recurses at expression
  position (parser emits `ELet _ True`, auto-recursive) but, inside a bare block,
  desugars to a non-recursive `DoLet`, so the self-reference is reported as
  **`Unbound variable: f`** — a confusing error naming the very binding just
  written. Repro:
  ```
  countdown p =
    let go n = if n == 0 then p else go (n - 1)   -- → Unbound variable: go
    go 3
  -- but the one-liner works:
  countdown p = let go n = if n == 0 then p else go (n - 1) in go 3   -- 42
  ```
  **Where it lives:** desugar of block `DoLet` (`lib/desugar.ml`) vs the
  expression-`let` parse rule that sets `isRec` for the param form
  (`parser.mly`); `lib/eval.ml`'s `blockLet` evaluates the RHS before extending
  the frame, so a block-`let` closure never captures its own name. **Decision
  needed (design):** either (a) make a block-`let` with parameters recursive to
  match expression-`let` and the top-level form, or (b) keep it non-recursive but
  replace the bare `Unbound variable` with a targeted hint. Surfaced by the
  lexical-addressing emit session (the addresser correctly emitted `AGlobal` for
  the block-`let` self-reference, matching eval).

- **Phase 101 — drive property generation/shrinking through the `Arbitrary`
  interface (101b). DEFERRED, reassess later.** 101a (registry-first
  `arbitrary`/`shrink`, native element recursion) is DONE (PLAN-ARCHIVE.md). What
  remains — **101b**: synthesized typed generators + parametric `core.mdk`
  `Arbitrary` impls. Phase 83/84 made single-level interface-driven generation
  work, but **nested** parametric elements (`List (List Int)`) still fail — the
  flat `VDict of string` dict can't carry a recursive element dict. Since 101a
  already handles every case *including* nesting and makes hand-written element
  impls win, 101b's only unique gain is honoring a user's custom
  container-*generation* strategy — niche. Revisit only if that need arises (also
  wants structured/recursive dicts, same as Phase 83/84 #5). WIP on branch
  `claude/suspicious-sammet-21d73e` (commit `860ba12`). Skill:
  **add-language-feature** (cross-cutting).

- **Phase 83 / 84 #5 — true recursive/nested instance dictionaries. DEFERRED (the
  big remaining residual).** The instance-`requires` dict-threading into
  return-position impl bodies is DONE; the tractable set was closed by Phase 115,
  and #4 (free-`e` `Result`) closed via head-key dict-application routing (all in
  PLAN-ARCHIVE.md). Only #5 remains: the `List (List Int)` case needs **structured
  dicts** rather than flat impl-key strings — the real "pipeline restructure"; it
  also lifts the Phase 101b nesting limit. Skill: **harden-typechecker** /
  **add-language-feature** (cross-cutting).

### CLI surface (Phase 82, continued)

The design spec lists `new build run check test fmt lsp doc add remove update`;
`check / run / test / repl / lsp / fmt / new` exist, plus `bench`. Remaining
non-package-manager gaps:

- **`medaka build`** — needs its own design first: there is no artifact cache or
  typed-IR serialization format in the tree, so "typecheck + cache" has no honest
  implementation. Until that exists it would only be an alias of `check`.
- **`medaka doc`** — needs (a) a comment→decl matcher (doc comments aren't
  attached to AST nodes — a parallel `Lexer.take_comments()` stream matched by
  position, like `doctest.ml` does), (b) a signature renderer for a typechecker
  `scheme`, and (c) an output-format decision.
- **`medaka check --json` multi-file** — currently single-file (`Diagnostics.
  analyze` doesn't invoke the `Loader`), so a file with `import`s can
  resolve-error in the JSON output. Multi-file `--json` is the follow-up.
- Skill: none specific (lands in `bin/main.ml` + `lib/lsp_server.ml`).

### Stdlib enablement (Phase 19) — ✅ COMPLETE

All of Modules 1–9 are done (`core`/`list`/`array`/`string` + `map`/`set`, hash
containers, `io`, `mut_array`, `json`) — see PLAN-ARCHIVE.md and STDLIB.md. The
hand-write-it-myself constraint was lifted 2026-06-02 and the remaining modules
delegated. `stdlib/string.mdk` API frozen 2026-06-03 (Phase 128).

### Blocked on a package manager (out of scope until one exists)

- `medaka add` / `remove` / `update`, and a `medaka.lock` file.

---

## Won't-do (kept intentional)

- **Phase 78c — multi-module method shadowing.** Investigated 2026-06-01 and
  dropped: the motivating need (`length`/`isEmpty`/`toList` on `Array`) is
  already met by interface impls, and there is no safe export path for a bare
  `length : String -> Int` (it would shadow `Foldable.length` everywhere). The
  real lever, if ever needed, is a `Sized`/`HasLength` interface — which is
  stdlib design, not a compiler feature. (Phase 112 — the *narrower* lever:
  resolve to a local/imported name only when the method has no applicable impl —
  is **DONE** (PLAN-ARCHIVE.md); 78c stays dropped.)
- The broader **rejected-features** list (labeled arguments, active patterns,
  computation expressions, polymorphic variants, first-class modules, row
  polymorphism, macros, lazy sequences, higher-rank polymorphism, custom
  symbolic operators, …) lives in PLAN-ARCHIVE.md §8 with per-item rationale.
  Consult it before proposing any of them so the rejection stays intentional.
