# Medaka — Roadmap

The working handoff between sessions. Read it before starting a task; update it
when you finish one. This document holds only **forward-looking** work — the
completed Phases (1–115, with their detailed implementation notes) live in
[`PLAN-ARCHIVE.md`](./PLAN-ARCHIVE.md). When a phase here is finished, move its
write-up to the archive and leave only what remains. For how to build/test and
the codebase's non-obvious gotchas, see [`AGENTS.md`](./AGENTS.md).

## Current status (2026-06-02)

The compiler pipeline is complete end-to-end —
`lexer → parser → desugar → resolve → method_marker → typecheck (runs exhaust)
→ eval` — with phases through ~115 done (see PLAN-ARCHIVE.md). The language has
records, ADTs, interfaces (with superinterfaces, `deriving`, dictionary-passing
for return-position/multi-param dispatch), effect rows, exhaustiveness checking,
`do`-notation, guards (with fall-through + exhaustiveness lint), list
comprehensions, string interpolation, type aliases/newtypes, container literals
(`Map { k => v }` / `Set { x }`, Phase 108), property testing, doctests, an LSP
server, a formatter, and a project-config/`medaka new` surface. Operators are
wired to the real `Eq`/`Ord`/`Num` interfaces in `core.mdk` (Phase 52).

The stdlib in Medaka covers `core`, `list`, `array`, a drafted `string`
(STDLIB.md Modules 1–4), and the weight-balanced ordered `map` + `set`
(Module 5, complete). As of 2026-06-02 the user lifted the hand-write-it-myself
constraint and delegated the remaining modules.

**Conventions.** Work is still organized by numbered **Phases**; commit messages
and code comments reference them. Phases that were left *partial* keep their
original number (e.g. Phase 82, 101); genuinely new work gets the next free
number (last used: 121). At task triage, match the work against AGENTS.md's
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
  - **`Map` / `Set`** — symbol tables, scopes, type-variable substitutions, impl
    registries. ✅ **DONE** (Module 5, ordered/weight-balanced; plus the mutable
    `HashMap`/`HashSet` performance variant, Module 6 / Phase 120). Only
    `mut_array` (a growable vector) remains in Module 6.
  - **`io`** — read source files, write artifacts, stdin/stdout, process args,
    exit codes, structured error reporting. ✅ **DONE** (Module 7, Phase 116).
  - `string` finalized and reviewed (drafted; awaiting full review) — **now
    importable** ✅ (Phase 117 unblocked it: renamed the colliding `count` and
    hardened the multi-module typecheck). A self-hosted compiler can now pull
    string utilities from another module.
- **Language stability / completeness.** Close the sharp edges that would bite a
  large codebase, then *freeze the surface syntax and semantics* for the duration
  of the port:
  - ~~`do`→`Thenable` (Phase 98)~~, ~~guard exhaustiveness + inline guards (Phase
    91)~~, ~~plain multi-clause exhaustiveness (Phase 102)~~ — **DONE**.
  - Multi-module / return-position dispatch residuals (Phase 83/84) shouldn't
    force arg-tag workarounds in compiler code — mostly closed (Phase 115 closed
    the inferred/recursive-wrapper cases; the free-`e` `Result` case #4 closed
    2026-06-02 via head-key dict-application routing); only the nested/structured
    -dict residual (#5) remains.
- **Interpreter performance, "good enough" to bootstrap.** Running the compiler
  *on* the interpreter must finish in minutes, not hours. May require interpreter
  hot-path work (the eval loop, environment representation) — measure once a
  non-trivial program exists.
- **Multi-file ergonomics at scale.** The module system, qualified access, and
  `medaka.toml` workspaces exist; per-module eval isolation landed (Phase 110).
  Confirm they hold up across the dozens of files a compiler needs. Surface gaps
  here become new phases.

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

- **Phase 121 — point-free method bodies in `impl`s panic at eval (Phase 89
  residual).** Phase 89 fixed point-free *standalone constrained* defs
  (`maximum = fold step None`). The residual: a **dispatched method body** in an
  `impl` defined point-free can panic `applied non-function: ()` at eval.
  Verified 2026-06-02: a *partial-application* body reproduces —
  `impl Bar Int where bar = replicate2 3` then `bar 7` panics — while a
  *bare-name* body (`foo = identity`) now works, so it's arity-/shape-specific
  (the dispatch applies the method's argument to a point-free body that took no
  clause params, hitting a `()` placeholder). This is the trap behind the
  `0dd8e14` fix (`toList = identity` in `impl Foldable List` was eta-expanded to
  `toList xs = xs` rather than fixed). **Workaround (everywhere today):**
  eta-expand the method body (`bar x = replicate2 3 x`). Recurring enough across
  the stdlib to fix properly. Lands in `lib/eval.ml`'s method-dispatch /
  `EMethodRef` application (likely the point-free-arity handling), possibly with
  `lib/dict_pass.ml`/`method_marker.ml`. Skill: **debug-pipeline** (diagnose) →
  the dispatch machinery.

- **Phase 119 — false-positive non-exhaustiveness warning for 3+-arg functions
  matching a list.** A multi-clause function with **≥3 parameters** where one
  column is a `List` pattern wrongly warns `non-exhaustive clauses` even when it
  is total. Minimal repro: `r [] _ _ = 0` / `r ((a,b)::rest) x y = …` warns;
  the 2-arg version is clean, and single-arg is clean. Bit `hash_map.mdk`'s
  `bucketReplace`/`reinsertBucket`. Lands in Phase 102's `Exhaust.check_clauses`
  (`lib/exhaust.ml`/`typecheck.ml`) — the param-tuple `__tuple__` column reduction
  likely mishandles a list column alongside wildcard columns at arity ≥3.
  Warning only (eval is unaffected), but noisy. **Workaround (used in
  hash_map.mdk):** match the list in a single-arg `where go` helper that closes
  over the other args, or keep such functions to ≤2 params. Surfaced building
  Module 6, 2026-06-02. Skill: **harden-typechecker**.

- ✅ **Phase 118 — `if`/`else` block branches: complete the layout matrix. DONE
  (2026-06-03).** The original framing ("any block as a `then`/`else` branch is a
  parse error") was **stale** — Phase 45.7/45.8 already parsed block branches for
  most layouts (block/block, block/inline, inline-then+newline+inline-else). The
  one missing cell was **inline `then` expr + NEWLINE + indented `else` block**
  (`if present then replace` / newline / block `else`) — the exact `<Mut>`
  hash-table friction. Fix: a single `parser.mly` production in `expr_lam`
  (`IF expr_or THEN expr_lam newlines ELSE INDENT nonempty_list(stmt) DEDENT`,
  reusing `stmts_to_expr`); no AST/resolve/typecheck/eval change. Conflict count
  unchanged (3, freshly measured — the checked-in `parser.conflicts` had drifted
  to 14). Also fixed a **pre-existing formatter bug**: `printer.ml`'s `EIf`
  printed branches inline unconditionally, so *all* block-branch `if/else` (even
  the parseable Phase-45.7 ones) emitted unparseable output — `medaka fmt` now
  lays `then`/`else` on aligned lines with the block indented one step (rewrote
  the `EIf` arm + made `is_block_body` recurse into `EIf` branches). Tests in
  `test_parser`/`test_roundtrip`/`test_fmt`/`test_run`. The remaining `if`
  ergonomics gap — **else-less `if`** — is split out as Phase 122 below.
  (`stdlib/hash_map.mdk` keeps its guard-based `<Mut>` ops; the block-branch
  claim in its header comment is now superseded by Phase 122.)

- **Phase 122 — else-less `if … then <block>` (statement-position `if`).**
  Every `if` grammar rule requires `ELSE` (`parser.mly:564-588`), so
  `if c then <block>` with no `else` is a **parse error**. This is the remaining
  imperative-`<Mut>` ergonomics gap after Phase 118: side-effecting code that
  conditionally runs a block and otherwise does nothing (e.g. a `maybeResize`
  that resizes only past a load factor) must today fall back to function guards
  (`| cond = <block>` / `| otherwise = ()`), as `stdlib/hash_map.mdk` does. Add
  an else-less form that defaults the missing branch to the unit value `()`
  (`ELit LUnit`, `ast.ml:17`), i.e. `if c then e` ≡ `if c then e else ()`.
  Needs: a parser production for the no-`ELSE` form (inline *and* indented-block
  `then` branch), and a typecheck rule that the `then` branch is `Unit` (so the
  `if` itself types as `Unit`) — cleanest as a desugar to `EIf (c, t, ELit
  LUnit)` so typecheck/eval need no new arm. Mind the indentation-sensitive
  lexer and re-measure `parser.conflicts` (an else-less `if` introduces a
  dangling-else-style ambiguity to resolve). Surfaced alongside Phase 118,
  2026-06-03. Skill: **add-language-feature**.

- **Phase 101 — drive property generation/shrinking through the `Arbitrary`
  interface (101b).** 101a (registry-first `arbitrary`/`shrink`, native element
  recursion) is **DONE** (see PLAN-ARCHIVE.md). What remains — **101b, deferred,
  reassess later**: synthesized typed generators + parametric `core.mdk`
  `Arbitrary` impls. Phase 83/84 made single-level interface-driven generation
  work (`impl Arbitrary (List a)` generates `List Int`/`List Tagged`/`Option
  Int`), but **nested** parametric elements (`List (List Int)`) still fail — the
  flat `VDict of string` dict can't carry a recursive element dict. Since 101a
  (native + registry recursion) already handles every case *including* nesting
  and makes hand-written element impls win, 101b's only unique gain is honoring a
  user's custom container-*generation* strategy — niche. Revisit only if that
  need arises (also wants structured/recursive dicts to lift the nesting limit).
  WIP on branch `claude/suspicious-sammet-21d73e` (commit `860ba12`). Skill:
  **add-language-feature** (cross-cutting).

- ⭐ **Phase 83 / 84 (residuals, layered like 69.x→74).** The
  instance-`requires` dict-threading into return-position impl bodies (single
  level) is **DONE** (see PLAN-ARCHIVE.md). The tractable set was closed by
  **Phase 115** (2026-06-02, see PLAN-ARCHIVE.md) — #1/#2 fixed, #3 decided; **#4
  (free-`e` `Result`) closed 2026-06-02** by head-key dict-application routing
  (see PLAN-ARCHIVE.md). Only #5 (nested/structured dicts) remains:
  - ~~Runtime dict-threading *into* an inferred (unsignatured top-level)
    constrained body~~ — **DONE (Phase 115 #1).** Generalized Phase 84's
    promotion (`promotable_from`) from the hard-coded `Applicative` to *any*
    interface with a return-position method (`iface_has_return_position_method`),
    so `mk n = tag n` over a user `interface Tag a where tag : Int -> a` now
    dispatches by result type. Argument-dispatched wrappers (`Eq`/`Show`/`Ord`)
    stay on arg tag (unchanged).
  - ~~Self-/mutually-recursive *unsignatured* wrappers under-infer their own
    recursive-call routing~~ — **DONE (Phase 115 #2).** Dropped the non-recursive
    promotion guard; a promoted wrapper's own recursive `EDictApp` call (inferred
    during Pass B before its `fun_constraints` entry exists) is deferred via
    `env.recursive_promoted_usages` and resolved by `realize_recursive_dict_apps`
    once `fun_constraints` is populated — recovering the discriminating var from
    the live occurrence mono (`find_tvar_in_mono`). Covers recursive return-pos
    wrappers, mutual recursion (single result type), and recursive poly-monad
    builders. (Polymorphic recursion at *two different* result types remains a
    separate pre-existing limit — fails signatured too.)
  - `pure` in a do-block with **no `<-`** is groundable only from surrounding
    type context — **decided (Phase 115 #3): document-and-accept.** When the
    result type is pinned (a def-site or use-site annotation) it dispatches
    correctly; with no context at all (`println (do { pure 5 })`) it defaults to
    the first Applicative impl (List) by arg tag. That is an inherent ambiguity
    (the program names no monad), analogous to Haskell type-defaulting — not a
    mis-dispatch. A stricter "ambiguous type" *error* is possible future work but
    out of scope.
  - ~~`Result e` with a free `e` mis-dispatches even when signatured~~ — **DONE
    (#4, 2026-06-02).** Was: `f m = do { x <- m; pure x }` called `f (Ok 5)`
    routed to List's `pure` (`[5]`) for both the unsignatured and signatured
    forms, because dict-*application* routes (`resolve_one_route`) emitted only
    `RKey`/`RDict` — never a head-key — so the non-ground `Result e` dict
    collapsed to `RKey ""` → arg-tag → first impl. Fix: extended the head-key
    escape hatch the *method-occurrence* path already had (`RHeadKey` via
    `head_key_route`, now a shared helper) to the dict-application path, plus a
    head-bearing runtime dict value `VDictHead` that narrows by head tag
    (`select_impl_by_head`) when the body reads it. `f (Ok 5)` → `Ok 5`;
    List/Option dispatch and #3's no-context default (`[5]`) unchanged.
  - True recursive/nested instance dictionaries (the `List (List Int)` case) need
    structured dicts rather than flat impl-key strings — the real "pipeline
    restructure"; also lifts the Phase 101b nesting limit. **Still deferred** (the
    big remaining residual).
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

### Stdlib enablement (Phase 19)

Originally hand-written by the user by design; as of 2026-06-02 the user lifted
that constraint and delegated the remaining modules (Modules 5–8). STDLIB.md is
the per-module checklist. **Module 5 (`map` + `set`) is complete** — see
PLAN-ARCHIVE.md and STDLIB.md.

- ⭐ **`stdlib/string.mdk`** is drafted and passes its 49 doctests but is flagged
  *awaiting full user review* (archive Phase 75 step 3). Remaining open decisions:
  the `length`/`isEmpty` omissions and `toUpper` vs `charToUpper` naming. (The
  `count` naming sub-decision is **resolved** — renamed to `countOccurrences` in
  Phase 117, see below.)

- ✅ **Phase 117 — make `stdlib/string.mdk` importable. DONE (2026-06-02).**
  Surfaced building `io` (Phase 116): *any* module that `import`ed `string` (even
  `import string.{trim}`) failed the multi-module typecheck with `core.mdk:661:
  Type mismatch: String vs a -> b`. Two compounding causes, both fixed:
  - `string.mdk` defined a standalone `count : String -> String -> Int` that
    **redefined the prelude's droppable `count`** (`Foldable t => (a -> Bool) ->
    t a -> Int`). **Renamed → `countOccurrences`** (the name genuinely clashed
    semantically and was an open string-review item).
  - `typecheck_module` (the multi-module path) always prepended the *full*
    `marked_prelude`, unlike `check_program_impl` which uses
    `Method_marker.prelude_for` to drop droppable prelude standalones a module
    redefines — so the two `count`s coalesced into one letrec group and corrupted
    core's own definition. **Fixed** `lib/typecheck.ml` to use
    `prelude_for user_prog` on the multi-module path too (no-op when nothing is
    shadowed; preventive for future modules). Scoped to the droppable-standalone
    (78a) case; interface-method (78b) parity stays out of scope (Won't-do 78c).
  Regression tests in `test/test_typecheck.ml` (module redefining a droppable
  prelude fn, single + imported). `io.mdk`'s `readLines` keeps its local line
  splitter deliberately — `string.lines` retains the trailing empty line,
  `readLines` drops it (stale "un-importable" comment refreshed). Skill:
  **harden-typechecker**.

- **Module 6 — hash containers ✅ DONE (Phase 120); `mut_array` remains.**
  `stdlib/hash_map.mdk` + `stdlib/hash_set.mdk` — **mutable** hash tables
  (separate chaining in a `Ref`-held `Array`, resize past load factor 0.75),
  the O(1)-average performance counterpart to the ordered Module 5. New `hash`
  extern (structural, non-negative); removed `"HashMap"`/`"HashSet"` from
  `resolve.ml` `primitive_types`. HashSet impls `Foldable` (elements = `toList`);
  HashMap uses `entries` internally (its `toList` = pairs would clash with
  `Foldable.toList`). 8 + 7 doctests, stress-verified (100 inserts → multiple
  resizes, delete, dedupe). Surfaced **Phase 118** (`if`/`else` block branches,
  now ✅ DONE), **Phase 122** (else-less `if`, the remaining `<Mut>` ergonomics
  gap), and **Phase 119** (false-positive non-exhaustiveness for 3+-arg list
  matches); all above, the open ones with clean workarounds. **`mut_array`** (growable vector over
  `Array`) is still unstarted — mainly an interpreter/compiler perf nicety.
- **Module 8 — `json` unstarted:** `Json` type + parser + serializer. Not on the
  self-hosting path.
  - ✅ **Module 7 `io` — DONE (Phase 116).** Comprehensive: externs (`args`,
    `getEnv`, `fileExists`, `appendFile`, `listDir`, `ePutStr`/`ePutStrLn`,
    `readLineOpt`, `readAll`) in runtime.mdk + eval.ml, `args` wired through
    `bin/main.ml` (`medaka run FILE a b c` → `["a","b","c"]`), plus `stdlib/io.mdk`
    (`eprint`/`eprintln` via Display, `readLines`, `getEnvOr`). See STDLIB.md
    Module 7. (Surfaced Phase 117, the string-import blocker, above.)

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
  is now **DONE** (see PLAN-ARCHIVE.md); 78c stays dropped.)
- The broader **rejected-features** list (labeled arguments, active patterns,
  computation expressions, polymorphic variants, first-class modules, row
  polymorphism, macros, lazy sequences, higher-rank polymorphism, custom
  symbolic operators, …) lives in PLAN-ARCHIVE.md §8 with per-item rationale.
  Consult it before proposing any of them so the rejection stays intentional.
