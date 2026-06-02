# Medaka — Roadmap

The working handoff between sessions. Read it before starting a task; update it
when you finish one. This document holds only **forward-looking** work — the
completed Phases 1–97 (with their detailed implementation notes) live in
[`PLAN-ARCHIVE.md`](./PLAN-ARCHIVE.md). For how to build/test and the codebase's
non-obvious gotchas, see [`AGENTS.md`](./AGENTS.md).

## Current status (2026-06-02)

The compiler pipeline is complete end-to-end —
`lexer → parser → desugar → resolve → method_marker → typecheck (runs exhaust)
→ eval` — and 97 numbered phases are done. The language has records, ADTs,
interfaces (with superinterfaces, `deriving`, dictionary-passing for
return-position/multi-param dispatch), effect rows, exhaustiveness checking,
`do`-notation, guards (with fall-through), list comprehensions, string
interpolation, type aliases/newtypes, property testing, doctests, an LSP server,
a formatter, and a project-config/`medaka new` surface. Operators are wired to
the real `Eq`/`Ord`/`Num` interfaces in `core.mdk` (Phase 52).

The stdlib in Medaka covers `core`, `list`, `array`, and a drafted `string`
(STDLIB.md Modules 1–4). The remaining stdlib modules are user-written by
design (see the stdlib division-of-labor convention).

**Conventions.** Work is still organized by numbered **Phases**; commit messages
and code comments reference them. Phases that were left *partial* keep their
original number (e.g. Phase 82, 91, 92); genuinely new work gets the next free
number continuing from 97. At task triage, match the work against AGENTS.md's
task-playbook table and load the matching skill before planning.

---

## North star — self-hosting, then LLVM

The long-term goal that orders everything below: **rewrite the Medaka compiler
in Medaka, then compile it to native code via LLVM.** Chosen path (2026-06-02):
**bootstrap on the existing tree-walking interpreter first** — get a self-hosted
compiler running (slowly but correctly) on the interpreter, *then* build the
LLVM backend so that compiler emits native code. This validates the language as
a real engineering medium before we pay for the heavy memory-model / GC / codegen
work.

Most items in the Open roadmap are small course-corrections; this section is the
destination they steer toward. Three stages, each a gate on the next.

### Stage 0 — Prerequisites before self-hosting can begin

The language is already expressive enough to *describe* a compiler (ADTs,
records, exhaustive pattern matching, interfaces, modules, effects — all done).
What's missing is the supporting surface a real multi-thousand-line program needs:

- **Standard library breadth.** The compiler needs the data structures it is
  itself built on:
  - **`Map` / `Set`** (and likely a hash variant) — symbol tables, scopes,
    type-variable substitutions, impl registries. *Today: missing (Phase 19
    modules 5–6).* This is the single biggest gap.
  - **`io`** — read source files, write artifacts, stdin/stdout, process args,
    exit codes, structured error reporting. *Today: missing (Phase 19 module 7).*
  - `string` finalized and reviewed (drafted; awaiting review).
- **Language stability / completeness.** Close the sharp edges that would bite a
  large codebase, then *freeze the surface syntax and semantics* for the duration
  of the port:
  - ~~Resolve the `do`→`Thenable` question (Phase 98)~~ — **DONE.** `do` is now
    load-bearing on `Thenable`: a `<-` bind over a non-`Thenable` type is a
    compile-time error (see PLAN-ARCHIVE.md Phase 98).
  - Multi-module / return-position dispatch residuals (Phase 83/84) shouldn't
    force arg-tag workarounds in compiler code.
  - ✅ Guard exhaustiveness + inline guards (Phase 91) — done. (Plain
    multi-clause non-guard exhaustiveness remains; see below.)
- **Interpreter performance, "good enough" to bootstrap.** Running the compiler
  *on* the interpreter must finish in minutes, not hours. May require interpreter
  hot-path work (the eval loop, environment representation) — measure once the
  stdlib is in place and a non-trivial program exists.
- **Multi-file ergonomics at scale.** The module system, qualified access, and
  `medaka.toml` workspaces exist; confirm they hold up across the dozens of files
  a compiler needs. Surface gaps here become new phases.

### Stage 1 — Self-host on the interpreter

Port the pipeline (`lexer → parser → desugar → resolve → typecheck (runs
exhaust) → eval`) into Medaka, one stage at a time, checked against the OCaml
reference at each step. **Done when** Medaka-in-Medaka compiles a real program identically to
the OCaml compiler, and ultimately compiles *itself*. The output of this stage is
a validated language and a compiler whose only slow part is the interpreter
underneath it.

### Stage 2 — LLVM backend (after self-host)

With the language proven, build native codegen. The heavy, decision-dense work
deliberately deferred to here:

- **A frozen Core IR** as the codegen input: desugared, fully typed, effects
  erased, **dictionaries explicit**. The existing elaboration already inserts
  `EMethodRef`/`EDictApp` — that is the foundation; this stage commits to it as a
  serializable lowering target.
- **Typeclass lowering strategy:** runtime dictionary passing (already the eval
  model) vs. monomorphization. Decide deliberately — it shapes the whole backend.
- **Memory model & value representation:** heap allocation, closure layout,
  tagged ADTs/records, boxing/unboxing. *Decision-dense; the real cost of going
  native.*
- **Garbage collection:** conservative (Boehm) to start vs. reference counting
  vs. a precise collector. Strict + functional + closures ⇒ this is unavoidable.
- **Runtime library:** re-implement the `extern` catalog (today OCaml in
  `eval.ml`, incl. Unicode via `uucp`, arrays, strings, IO) against the native
  runtime.
- **LLVM lowering:** Core IR → LLVM IR, calling convention, FFI.
- **Bootstrap closure:** self-hosted compiler + LLVM backend compiles itself to a
  standalone native binary — the finish line.

---

## Open roadmap

Each item is independently shippable; pick one per session. Grouped by area, not
strict priority. Where an item is a **Stage 0 prerequisite** for the north star
above, it is flagged ⭐.

### Compiler / language

- **Phase 99 — lower `do` to `andThen`/`pure` (make it true sugar). ✅ DONE.**
  `Desugar.lower_do_blocks` (`lib/desugar.ml`) now rewrites `EDo` into nested
  `andThen`/`pure` calls (mirroring the list-comp lowering: bare `ELam [pat]` for
  irrefutable binds, a 2-arm `EMatch` ending in `__fallthrough__` for refutable
  ones). It runs **after `desugar_questions`, before `method_marker` + typecheck**
  (also threaded into `desugar_expr` for the REPL), so the emitted bare
  `andThen`/`pure` EVars get marked to `EMethodRef`/`EDictApp` and bind dispatch
  flows through the normal dictionary elaboration — `eval.ml`'s `eval_do` + the
  `monadic_ctors` hashtable are deleted, and the `EDo` typecheck arm is now an
  `InternalError` guard. The `Thenable` obligation rides the lowered `andThen`'s
  constraint, so Phase 98's win is preserved structurally (a `<-` over a
  non-`Thenable` type is still a compile-time error; a `pure`-only block pulls no
  Thenable obligation). Behavior changes (intended): a non-final `DoExpr` now
  sequences monadically (`None; …` short-circuits), and a single-statement
  `do x` is just `x` (identity, no forced monad). Do-block well-formedness
  (no `let mut`/assign/field-assign; no bad terminator) moved to a pre-lowering
  scan raising `Desugar.Do_error`, caught at the driver/test `Type_error` sites.
  Imperative IO/`let mut` sequences now use a bare indented block (`EBlock`),
  which is untouched. Skill: **add-language-feature**.

- ✅ **Phase 91 — guard gaps (done).** All three items complete:
  - (1) Fall-through (archived).
  - (2) Compile-time non-exhaustive-guard detection — a conservative "guards may
    not be exhaustive" warning. Function-clause guards (`EGuards`) desugar to
    `EIf` chains before exhaust runs, so this is a standalone pre-desugar lint
    (`Exhaust.check_guard_exhaustiveness`, wired into the `Diagnostics` drivers +
    `bin/main` `check`/`run`). It reuses the `useful` pattern matrix over a
    constructor oracle built from the program's own data decls + builtins, so a
    partial guard chain is *excused* when sibling clause patterns already cover
    every input (e.g. a final `f _ = ..` clause). Closed prelude types
    (Option/Result/Ordering) aren't in a user file's AST, so guards discriminating
    on them conservatively warn — an accepted limitation of the type-free pass.
  - (3) Inline guard form — `f n | n <= 0 = []` on one line (single arm; further
    arms keep the indented-block / separate-clause forms). Added to `inner_fun_def`
    and `where_binding` in `lib/parser.mly`; no new parser conflicts (still 3).

- **Phase 92 — doctest harness reaches cross-module instances. ✅ DONE.**
  `medaka test <file>` now routes a file that imports real sibling modules
  through the multi-module (`typecheck_module`) path in `lib/doctest.ml`
  (`run_file_multi`), mirroring `medaka run`/`check`: load the dependency graph
  via `Loader`, inject the synthetic `__dt_i__` doctest bindings into the root
  module, resolve + mark + two-pass-typecheck each module separately (so
  deliberately-reused top-level names stay unmerged), then dict-pass + eval. A
  doctest sees what its module **imports**. A file with no imports — or whose only
  imports were the implicit prelude `core` (which the loader filters, so no real
  sibling loads) — keeps the single-file path, which `prelude_for`-shadow-drops
  redefined names (this is what lets `stdlib/string.mdk`, which redefines the
  prelude standalone `count`, still doctest cleanly).
  - **Non-goal (intentional):** a *reverse* dependency — a `core` doctest that
    `show`s an `Array`, whose `Show Array` lives downstream in `array.mdk` — is
    **not** supported. The prelude reaching into a module that imports *it* is a
    layering inversion; String/Char already live in the prelude for exactly this
    reason, and no such doctest exists. The import graph is the source of truth.

- **Phase 100 — `import m.{T(..)}` bulk-constructor import (sugar).** Data
  visibility is already a deliberate three levels — `data T` (private),
  `export data T` (abstract: type name only), `public export data T` (type +
  constructors) — and a `public export` type's constructors *can* be imported,
  but only by listing each one (`import m.{T, A, B}`). The Haskell-style
  `import m.{T(..)}` shorthand for "the type and all its exported constructors"
  is currently a **parse error**: `import_ident` inside the `{…}` group
  (`UseGroup`, `lib/parser.mly:1053`/`1061`) accepts only a bare name. Pure
  convenience — explicit listing already covers the need — so it's low priority.
  Lands in `lib/parser.mly` (a new `import_ident` form), `lib/ast.ml` (the
  `use_path` group element must carry a "with constructors" marker, today a bare
  `ident`), and `lib/resolve.ml` (expand `T(..)` to the type + its exported
  constructors at bind time). Re-measure parser conflicts after the grammar
  change. Skill: **add-language-feature**.

- **Phase 101 — drive property generation/shrinking through the `Arbitrary`
  interface.** Phase 42's generator gaps are closed (`lib/prop_runner.ml` now
  generates `Array`, tuples, and parametric user types structurally, with
  matching shrinking — see PLAN-ARCHIVE.md Phase 42). What remains is the
  *principled* version: `gen_for_type`/`shrink_value` are still native OCaml, so
  a user's hand-written `arbitrary`/`shrink` impl is not actually called for
  built-in or structurally-generated types, and parametric generation works by
  the runner substituting type arguments itself rather than by passing element
  dictionaries. Unifying both paths — drive every generator/shrink through the
  Medaka-level interface via the dict-passed typed pipeline — would let
  hand-written impls win and element dictionaries flow into parametric
  instances. It is deferred because it intersects the Phase 83/84
  return-position dispatch residuals (a post-typecheck marker re-run / pipeline
  restructure). Lands in `lib/prop_runner.ml` + the typed/dict-passing pipeline.
  Skill: **add-language-feature** (cross-cutting).

- **Phase 102 — plain multi-clause exhaustiveness.** `Exhaust.check_match` runs
  only on `EMatch`, so a plain multi-clause function with no guards — `f Nil = ..`
  with no `Cons` clause — gets *no* exhaustiveness check (only a runtime
  `Impl_no_match`). Closing it needs the type-aware oracle (run inside typecheck
  where `env.ctors` is populated, rather than the Phase 91(2) lint's
  data-decl-only oracle, which can't see prelude types) and may newly flag partial
  functions across the stdlib. The Phase 91(2) guard lint (`Exhaust.
  check_guard_exhaustiveness`) deliberately scoped this out. Skill:
  **harden-typechecker** / **add-language-feature**.

- ⭐ **Phase 83 / 84 (residuals, deferred — layered like 69.x→74).** Lower priority;
  each is a known limitation with a correct-enough fallback today:
  - Runtime dict-threading *into* an inferred constrained body (currently arg-tag
    dispatch, correct for argument-dispatched wrappers). Needs a post-typecheck
    marker re-run against the final constraint tables — a pipeline restructure.
  - Self-/mutually-recursive *unsignatured* wrappers under-infer their own
    recursive-call routing.
  - `pure` in a do-block with **no `<-`** is groundable only from surrounding
    type context.
  - `Result e` with a free `e` mis-dispatches even when signatured (a multi-param
    dict-resolution gap).
  - Skill: **harden-typechecker** / **add-language-feature** (cross-cutting).

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

### Stdlib enablement (Phase 19 — user-owned)

Deliberately hand-written by the user; listed for completeness, not as agent
work unless explicitly delegated (see the stdlib division-of-labor convention).

- ⭐ **`stdlib/string.mdk`** is drafted and passes its 45 doctests but is flagged
  *awaiting user review* (archive Phase 75 step 3). Open decisions: the
  `length`/`isEmpty`/`count` omissions and `toUpper` vs `charToUpper` naming.
- **Modules 5–8 unstarted:** `map`/`set` (persistent trees), `mut_array`/
  `hash_map`/`hash_set`, `io` (`readFile`/`writeFile`/`readLine`), `json`
  (type + parser + serializer). Expect each to surface new language gaps —
  record them here as new phases when they do.
  - ⭐ **`map`/`set` and `io` are the critical-path Stage 0 prerequisites** — a
    self-hosted compiler can't be written without symbol tables and file I/O.
    (`mut_array`/`hash_map`/`hash_set` matter mainly for interpreter/compiler
    *performance*; `json` is not on the self-hosting path.)

### Blocked on a package manager (out of scope until one exists)

- `medaka add` / `remove` / `update`, and a `medaka.lock` file.

---

## Won't-do (kept intentional)

- **Phase 78c — multi-module method shadowing.** Investigated 2026-06-01 and
  dropped: the motivating need (`length`/`isEmpty`/`toList` on `Array`) is
  already met by interface impls, and there is no safe export path for a bare
  `length : String -> Int` (it would shadow `Foldable.length` everywhere). The
  real lever, if ever needed, is a `Sized`/`HasLength` interface — which is
  stdlib design, not a compiler feature. Reopen only for a genuine, non-cosmetic
  need that interface impls can't serve.
- The broader **rejected-features** list (labeled arguments, active patterns,
  computation expressions, polymorphic variants, first-class modules, row
  polymorphism, macros, lazy sequences, higher-rank polymorphism, custom
  symbolic operators, …) lives in PLAN-ARCHIVE.md §8 with per-item rationale.
  Consult it before proposing any of them so the rejection stays intentional.
