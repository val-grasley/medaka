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

The stdlib in Medaka covers `core`, `list`, `array`, a drafted `string`
(STDLIB.md Modules 1–4), and the weight-balanced ordered `map` + `set`
(Module 5, complete). As of 2026-06-02 the user lifted the hand-write-it-myself
constraint and delegated the remaining modules.

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
  - **101a — DONE (2026-06-02).** `lib/eval.ml` gains a `shrink_registry`
    (mirror of `arbitrary_registry`, populated from an `impl Arbitrary T` that
    *overrides* `shrink`); `lib/prop_runner.ml` `gen_for_type`/`shrink_value`
    consult the registries first (generation gated to nullary head) with native
    fallback, so a hand-written/`deriving` `arbitrary`/`shrink` actually wins —
    **including container elements**, because native `gen_for_type` recurses and
    each element routes through `arbitrary_registry` (`List Tagged` →
    `[Tagged 7,…]`, all nesting handled). Also fixes a pre-existing bug: native
    generation only matched single-arg `Result`; two-arg `Result e a` now
    generates (`Ok a` / `Err e`) instead of crashing.
  - **101b (synthesized typed generators + parametric `core.mdk` Arbitrary impls)
    — DEFERRED, reassess later.** Phase 83/84 (now in main) made single-level
    interface-driven generation work (`impl Arbitrary (List a)` correctly
    generates `List Int`/`List Tagged`/`Option Int`), but **nested** parametric
    elements (`List (List Int)`) still fail — the flat `VDict of string` dict
    model can't carry a recursive element dict. Since 101a (native + registry
    recursion) already handles every case **including nesting** and makes
    hand-written element impls win, 101b's only unique gain is honoring a user's
    custom `impl Arbitrary (List a)` *generation strategy* — a niche case that
    also needs a native fallback for nested/tuple/`Result`. Revisit only if a
    concrete need for custom container-generation strategies arises (would also
    want structured/recursive dicts to lift the nesting limit). The synthesized-
    generator WIP is on branch `claude/suspicious-sammet-21d73e` (commit
    `860ba12`) for reference.

- ✅ **Phase 102 — plain multi-clause exhaustiveness. DONE.** A plain
  multi-clause function (`f Nil = ..` with no `Cons` clause) never becomes an
  `EMatch`, so `check_match` never saw it — an uncovered case surfaced only as a
  runtime `Impl_no_match`. New `Exhaust.check_clauses` runs from the end of
  `process_letrec_group` (covering all entry points + the REPL) with a type-aware
  oracle (`exhaust_oracle`, backed by `env.type_ctors`/`env.ctors`, so prelude
  types like `Option`/`List` are enumerable — unlike the Phase 91(2) lint's
  data-decl-only oracle). Each clause's parameter list is wrapped as one synthetic
  `__tuple__` column (the same reduction `check_group` uses). No genuine stdlib
  partials surfaced; the one false positive was `Unit` missing from the
  `type_ctors` builtin seed (now fixed). See PLAN-ARCHIVE.md. Skill:
  **harden-typechecker**.

*(Phases 103–105 + 107 below were surfaced implementing Module 5 `map`,
2026-06-02 — see the per-item repros.)*

- **Phase 103 — nullary return-position method dispatch — DONE (2026-06-02).**
  Two facets, both fixed with two small targeted edits (no structured-dict
  redesign needed):
  - **(a) Type ascription ignored — root cause was scheme shadowing, not the
    ascription.** A standalone top-level binding sharing a nullary method's name
    (array.mdk's `empty : Array a` next to `impl Monoid (Array a)`) shadowed the
    Monoid method scheme in `env.vars`. `infer`'s `EVar` method branch then called
    `instantiate_method` with the *shadow* scheme, so `param_vars` came back empty
    (the shadow's bound ids ≠ the interface's `iface_param_ids`) and
    `check_method_usages` skipped route-stamping → eval fell to the first impl
    (List's `[]`) → `arrayLength: expected Array`. **Fix:** instantiate the
    interface's own method scheme via `List.assoc_opt x info.iface_methods`
    (`lib/typecheck.ml`, EVar method branch). The standalone `empty` bindings in
    `array.mdk`/`map.mdk` are now removed (redundant + the footgun); `empty` is
    purely `Monoid.empty`, use `[||]`/`Tip` internally.
  - **(b) Constrained impl over-applied its dict to a nullary terminal.**
    typecheck stamps `res_impl_dicts` for a return-position-with-`requires` method,
    but `dict_pass`'s `uses_impl_dict` gate adds *no* param when the body
    (`empty = Tip`) references no dict — so eval's `EMethodRef` folded the dict
    onto the bare `VCon Tip` → `applied non-function: Tip`. **Fix:** in `eval.ml`'s
    `EMethodRef`, only fold `res_method_dicts`/`res_impl_dicts` when the (post
    Phase-96-strip) value still awaits application (`VClosure`/`VPrim`/`VMulti`/
    `VThunk`/`VTypedImpl`/`VNamedImpl`); a terminal value takes none. Mirrors
    dict_pass's gate exactly; single-level (`Tip` needs no `Ord k`).
  - **Payoff landed:** `impl Monoid (Map k v) requires Ord k where empty = Tip`
    re-enabled in `stdlib/map.mdk`; `Array`/`Map` are now proper `Monoid`s and the
    `array.empty` footgun is gone. Regression tests: `test_run` (facet b,
    `t_nullary_empty_requires`), `test_doctest` (facet a, cross-module
    `t_nullary_shadowed_method_routes_by_annotation` — the bug only repros through
    the loader; single-file eval returns the standalone value and masks it),
    doctests in array/map. Skill used: **debug-pipeline** (diagnose) +
    **add-language-feature** (cross-cutting typecheck+eval edits).
  - **Surfaced (separate, pre-existing): dual stdlib import double-registers
    default impls.** Importing two sibling stdlib modules together (e.g. `map` +
    `array`) raises a spurious "Multiple default impls of `<Iface>` for `<Type>`"
    (loader/typecheck dedup bug; confirmed pre-existing — same error on the
    Semigroup impl without the new Monoid one). Spun off as its own task.

- ✅ **Phase 104 — parser: a leading `_` (or `_name`) as the *first* lambda
  parameter mis-parses as a constructor. DONE.** `(_ x => …)` /
  `(_k v acc => …)` failed with `Unknown constructor: _`; a `_` in any
  *non-first* position was fine (`(k _ acc => …)`). Root cause was **not** a
  grammar conflict but a buggy constructor-head test in the expr-first
  binding-LHS lowering (`expr_to_pat`/`expr_to_pats` in `lib/parser.mly`): both
  used `Char.uppercase_ascii c.[0] = c.[0]`, which is `true` for `_` (and digits)
  since underscore has no case — so a leading-`_` application head was lowered to
  `PCon ("_", …)`. Fixed by factoring `is_ctor_name s` (an explicit `'A'..'Z'`
  ASCII-range check, matching the already-correct third site) and using it at all
  three constructor-head checks. No grammar rule changed → `parser.conflicts`
  unchanged at 3. Regression tests in `test/test_parser.ml`
  (`lambda leading wild` / `lambda leading underscore name` /
  `lambda nonfirst wild`). See [[project_binding_lhs_expr_first]].

- **Phase 105 — exhaustiveness false-positive on imported-type constructors.**
  ✅ DONE (2026-06-02). See PLAN-ARCHIVE.md. The multi-module seeding loop now
  rebuilds `env.type_ctors` for imported types from their exported `te_ctors`, so
  a function totally covering an imported ADT no longer falsely warns.

*(Two "minor ergonomics" candidates from the Module 5 work were investigated
and dropped as non-issues, both verified 2026-06-02: (1) bulk-importing a type's
constructors — `import map.{Map(..)}` already works, implemented in Phase 100;
(2) the `Ordering` constructor `Eq` does NOT clash with the `Eq` interface —
constructors and interfaces are already separately namespaced, so `match compare
… Eq => …` resolves fine even under `Ord k =>` with `Eq` imported. map.mdk's
earlier "use `_` for the equal case" comment was mistaken and has been corrected
to name `Eq`.)*

- **Phase 109 — spurious "Multiple default impls" when importing two sibling
  stdlib modules. ✅ DONE (2026-06-02).** A consumer importing both `map` and
  `array` (`import map.{Map, fromList, size}` + `import array.{make}`) failed
  typecheck with `Multiple default impls of Semigroup for Map a b`. Root cause:
  the per-module impl-export filter in `typecheck.ml` (`te_impls`) matched an
  impl to this module's `user_prog` by **iface name only**. Two facts combine:
  (1) `typecheck_module`'s `known_modules` accumulates *every* previously
  typechecked module (not just this module's imports), so when `array.mdk` is
  typechecked `env.impls` already holds map's `Semigroup (Map k v)`; (2)
  `array.mdk` also declares `default impl Semigroup (Array a)`, so the iface-name
  match re-exported the foreign `Semigroup (Map k v)` in array's `te_impls`. A
  consumer importing both then registered it twice → coherence error. Fixed by
  matching the full `impl_key` (iface + head type + name), so a module only
  exports impls it actually declares. Not Monoid-specific — affected any
  `default impl` in a module imported alongside another stdlib module. See
  [[project_typecheck_two_entrypoints]].

- **Phase 110 — eval has no module name-isolation — DONE (2026-06-02).**
  Surfaced while verifying Phase 109: with the coherence error gone, `run` of the
  map+array repro panicked `applied non-function: [|1|]` at `map.mdk` `insert k v
  Tip = singleton k v`. Eval flattened all modules into one `top_frame` and a
  by-name `fundef_acc`, so map's `singleton k v` (2-arg) and array's `singleton x`
  (1-arg) **merged into one `VMulti`**; the 1-arg clause matched first, returned
  `[|k|]`, then that array was applied to `v`. A clause merge, not just shadowing
  — a module-`b` function calling its own *private* helper ran module-`a`'s
  same-named helper. Broad surface (~20 top-level names shared across
  list/string/array/map: `get`/`take`/`drop`/`concat`/`reverse`/`zip`/`fromList`/
  `singleton`/`sort`/…), and it matters for the self-hosting north star.
  Eval-only: `typecheck_module` already scopes per module with per-module
  `use_schemes`, so the program type-checks; eval was the lone stage ignoring
  module boundaries.
  - **Fix — Approach B (per-module eval frames).** Added `Eval.eval_modules`
    (flat `eval_program` left for single-file/REPL/tests). Each module evaluates
    in `[ M_local ; M_imports ; global ]`: the **global** frame holds primitives,
    the evaluated prelude, all data ctors, and one coherent `VMulti` per interface
    method/impl (shared `impl_acc` across modules); **M_local** holds the module's
    own `DFunDef`/`DLetGroup` (the colliding names — isolation lives here, via a
    per-module `fundef_acc`); **M_imports** binds each `use`d name to the
    *exporting* module's actual cell (shared refs, so forward/thunk refs resolve).
    Export resolution mirrors resolve's `build_exports` (a value is exported via
    its `export`ed *signature* `DTypeSig(true)` — the `DFunDef`'s own `is_pub` is
    false — plus `export`ed defs and `pub use` re-exports). Impl method bodies
    close over their *defining* module's env (private helpers) yet install into
    the global method cell. Dict-passing is kept byte-identical: one
    `Dict_pass.run (marked_prelude @ all decls)` then sliced back by decl count
    (Dict_pass is a 1:1 decl map). Refactor seam: `eval_program` and
    `eval_modules` share `collect_ctors_and_dispatch` / `prealloc_cells` /
    `eval_decl_into`, the last parameterised by `fill_local`/`fill_global`.
    Routed only the multi-module **run** driver (`bin/main.ml` `Run`) and
    doctest's `run_file_multi` (via `eval_suppressed_modules`); `diagnostics.ml`
    is typecheck-only (never evals) and `medaka test` props are single-file, so
    neither needed routing. Tests: `test_loader` "same-named fn, different arity"
    and `test_doctest` "per-module eval isolation". See
    [[project_eval_no_module_isolation]], [[project_module5_map]].
  - **Rejected — Approach A (qualify names in resolve).** `resolve_module` is a
    pure *checker* (returns `exports × errors`, never a rewritten AST); making it
    a transformer changes its contract + every caller, ripples mangled names
    through typecheck/dict_pass/eval, and needs de-mangling for LSP
    hover/completion/symbols. Fights the architecture.

- **Phase 111 — `print`/`println` leak language internals; route them through a
  user-facing interface.** Surfaced 2026-06-02 in the Phase 108 `show` discussion.
  - **Problem (verified):** `println m` for a `Map` prints the raw
    weight-balanced tree — `Bin 2 1 10 Tip (Bin 1 2 20 Tip Tip)` — i.e. the
    internal constructors, not a user-facing form like `fromList [(1, 10), …]`.
    Every user ADT prints its raw `VCon` structure. `show m` is fine
    (`fromList […]`), but plain `println` is the common path and exposes the
    implementation.
  - **Root cause:** `print`/`println : a -> <IO> Unit` (stdlib/runtime.mdk) are
    **unconstrained** externs; eval's `print`/`println` (`lib/eval.ml` ~1088)
    call native `pp_value`, which renders a runtime value structurally (`VCon`
    name + args) with no interface dispatch — at runtime the value is just
    `VCon "Bin" […]`, so `pp_value` *can't* reach a type's user-defined rendering.
  - **Goal / the decision to make:** standardize human-facing output on a
    user-facing interface. Likely **`Display`** (`display : a -> String`,
    unquoted; already backs `\{…}` interpolation, and matches println's
    putStr-vs-show intent per runtime.mdk's comment) rather than `Show` (quoted,
    round-trippable). **Pick one.**
  - **`Display` should use the literal syntax (the Show/Display split, resolved).**
    Because `Display` does *not* need to round-trip, it is free to render a
    container with its pretty literal form, while `Show` keeps the re-evaluable
    function form:
      - `show m`    → `fromList [(1, 10), (2, 20)]` (round-trips; empty → `fromList []`)
      - `display m` → `Map { 1 => 10, 2 => 20 }` (pretty; empty → `Map {}`, which
        Show could *not* emit because it doesn't parse — but Display needn't care)
    So this phase adds `impl Display (Map k v)` (and per container) rendering the
    `Map { … }` literal, and `println m` then shows that. This is exactly why the
    Phase 108 `show` switch was declined but Display is the right home for the
    literal rendering.
    - **Sub-decision:** do the keys/values *inside* a Display'd container render
      via `Display` (unquoted — `Map { ada => 1 }`) or `Show` (quoted —
      `Map { "ada" => 1 }`)? Unquoted is Display-consistent but makes a string key
      read like an identifier. Decide when building.
  - **Clean implementation shape:** make `print`/`println` *Medaka* stdlib
    functions over a raw string-only extern — `putStr/putStrLn : String -> <IO>
    Unit` (the only externs), then `println : Display a => a -> <IO> Unit;
    println x = putStrLn (display x)`. This sidesteps the extern-can't-receive-a-
    dict wrinkle (externs take raw values; a constrained extern would need eval to
    supply the dict) by moving the constraint into Medaka where dict-passing
    already works.
  - **Cost / fork:** constraining the signature means **`Display` must cover every
    printable type** — built-ins (Int/Float/Bool/Char/String/Unit/tuples/List/
    Option/Result/Array/Map/…) plus `deriving (Display)` for user types; printing
    an un-`Display`able type becomes a *compile error*, losing today's
    "println anything" ergonomic. Mitigation: keep the current unconstrained raw
    dump under a debug name (`debug`/`inspect : a -> <IO> Unit`) for REPL/quick
    prints. `pp_value` is also used by error messages, the REPL result echo, and
    `applied non-function: …` — leave those raw (internal/debug), scope this to
    `print`/`println`.
  - Lands in: stdlib/runtime.mdk (externs) + stdlib/core.mdk (Display coverage +
    `print`/`println` defs + wider `deriving (Display)`) + `lib/eval.ml` (swap the
    externs for `putStr`/`putStrLn`). Skill: **add-language-feature**.

- ⭐ **Phase 83 / 84 (residuals, deferred — layered like 69.x→74).** Lower priority;
  each is a known limitation with a correct-enough fallback today:
  - **Instance-`requires` dict-threading into return-position impl bodies — DONE
    (2026-06-02, single-level).** An impl's `requires` dicts now thread into its
    method bodies so a *return-position* element ref resolves via the element dict
    (e.g. `impl Arbitrary (List a) requires Arbitrary a where arbitrary () =
    arbitraryList arbitrary 8` now generates `List Tagged` as `[Tagged 7, …]`
    instead of panicking `no matching impl for dispatch`). Mechanism mirrors
    69.x-e: a per-impl `impl_dict_routes` table (impl-local slots, keyed by
    impl_key) feeds `find_enclosing_dict`; the call site stamps a new
    `res_impl_dicts` on the `EMethodRef`; `dict_pass` prepends the matching params
    to the impl clause; eval applies them after `res_method_dicts`. **Gated to
    return-position methods** (the dispatch param appears only in the result):
    arg-position methods (`show`/`eq`/`compare`) stay on arg-tag dispatch, which
    already handles nesting. **Remaining limitation:** *nested* parametric element
    types (`List (List Int)`) don't fully thread — the flat impl-key dict model
    (`VDict of string`) can't carry a recursive element dict, so the inner list's
    own element dict is missing; single-level (`List Int`, `List Tagged`,
    `Option Int`) works. Lands in `ast.ml`/`typecheck.ml`/`dict_pass.ml`/`eval.ml`.
    This unblocks the common cases of **Phase 101**.
  - Runtime dict-threading *into* an inferred (unsignatured top-level) constrained
    body (currently arg-tag dispatch, correct for argument-dispatched wrappers).
    Distinct from the impl-body case above. Needs a post-typecheck marker re-run
    against the final constraint tables — a pipeline restructure.
  - Self-/mutually-recursive *unsignatured* wrappers under-infer their own
    recursive-call routing.
  - `pure` in a do-block with **no `<-`** is groundable only from surrounding
    type context.
  - `Result e` with a free `e` mis-dispatches even when signatured (a multi-param
    dict-resolution gap). (Did not reproduce on the 2026-06-02 binary with the
    probes tried; re-verify before working it.)
  - True recursive/nested instance dictionaries (the `List (List Int)` case above)
    need structured dicts rather than flat impl-key strings — the real
    "pipeline restructure."
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
the per-module checklist.

- **Phase 107 — `core.mdk` gaps surfaced by Module 5 (2026-06-02).**
  - **`Foldable.isEmpty` / `length` have no default body** — only `foldMap`
    does, yet the interface comment *and* STDLIB.md claim all three default. So
    every `Foldable` impl (List, Array, and any new one like a future tree) is
    forced to spell out `isEmpty`/`length`. Either add the default bodies
    (`isEmpty t = ...` via `toList`; `length = fold (acc _ => acc + 1) 0` — mind
    the point-free-dispatched-method eval trap, eta-expand) or correct the
    misleading comment + STDLIB.md. Lands in `stdlib/core.mdk`. Skill:
    **extend-stdlib**.
  - **No `fst` / `snd` tuple accessors** in core (`fst (1,2)` → `Unbound
    variable: fst`). Trivial to add (`fst (a, _) = a` / `snd (_, b) = b`); add to
    `core.mdk` utilities, or decide they're intentionally omitted (pattern-match
    instead) and document it. Skill: **extend-stdlib**.

- ⭐ **`stdlib/string.mdk`** is drafted and passes its 49 doctests but is flagged
  *awaiting user review* (archive Phase 75 step 3). Open decisions: the
  `length`/`isEmpty`/`count` omissions and `toUpper` vs `charToUpper` naming.
- **Module 5 — `map`/`set` (ordered):**
  - ✅ **`stdlib/map.mdk` — DONE (2026-06-02).** Weight-balanced BST (Adams /
    `Data.Map`, `data Map k v = Tip | Bin Int k v …`, `delta = 3`, `ratio = 2`).
    Full API (insert/insertWith/adjust/delete/lookup/member/union/unionWith/
    difference/intersectionWith/min-max views/folds-with-key/keys/elems/
    filterWithKey) + `Mappable`/`Eq`/`Show`/`Semigroup` instances + an exported
    `wellFormed` invariant checker. 33 doctests + 7 props (700 cases) green;
    depth 15 for 1000 ascending inserts. See STDLIB.md Module 5 for the full
    surface + the two gotchas: (a) **no `Monoid (Map k v)`** — `Monoid.empty` is
    return-position and can't supply the instance's `Ord k` (Phase 83/84 flat-dict
    limit); use the standalone `empty`/`Tip`. (b) `Foldable` deliberately skipped
    so `toList` keeps meaning assoc-pairs.
    - **Compiler change:** removed `"Map"` from `resolve.ml`'s `primitive_types`
      (it was a reserved placeholder), so the stdlib `data Map` is canonical —
      mirroring `Option`/`Result`/`Ordering`.
    - **Known issue (pre-existing, low priority):** map's exported standalone
      `toList : Map k v -> List (k, v)` **and `isEmpty : Map k v -> Bool`** are
      **unreachable from a user file** that imports map — a bare `toList m` /
      `isEmpty m` there resolves to the generic `Foldable.toList`/`isEmpty` method
      (which has no `Map` impl) and errors `No impl of Foldable for Map`. (Both
      are `Foldable` method names map exports as standalones; `member`/`size`/
      `insert`/… don't collide, and `empty` is now `Monoid.empty` not a
      standalone.) Same standalone-vs-interface-method name-collision class as the
      `empty`/`Monoid.empty` landmine (Phase 103) and won't-do Phase 78c.
      `set.mdk` sidesteps it by *implementing* `Foldable`, so its `toList`/
      `isEmpty` ARE the methods and resolve. Workarounds for map today:
      `toAscList`-style rename, or qualified access. Surfaced while testing
      Phase 108; reproduces on map built via `fromList` too (not a 108
      regression).
  - ✅ **`stdlib/set.mdk` — DONE (2026-06-02).** Chose a **standalone**
    weight-balanced element tree (`data Set a = Tip | Bin Int a …`) over a
    `Map a Unit` wrapper: a wrapper would force qualified imports to dodge map's
    identically-named `insert`/`union`/… exports and carry a `Unit` payload;
    standalone is self-contained and perf-optimal, balancing mirrored from
    map.mdk and re-verified by props (depth 15 for 1000 ascending inserts).
    Full API: member/insert/delete, union/intersection/difference/isSubsetOf,
    min-max views, fromList/singleton, + `Foldable`/`Eq`/`Show`/`Semigroup`/
    `Monoid`/`FromEntries` instances + `wellFormed`. 23 doctests + 8 props.
    `Set { 1, 2, 3 }` literal works (Phase 108 impl). Notably **set's `toList`
    works from user files** (it's the `Foldable` method, since Set impls
    Foldable) — no `map`/`filter` standalones (would clash with the interface
    method names). Module 5 (`map` + `set`) is now complete.
    - **Compiler change:** removed `"Set"` from `resolve.ml`'s `primitive_types`
      (mirroring the earlier `"Map"` removal), so `data Set a` is canonical.
  - ✅ **Phase 108 — wire the `Map { k => v }` / `Set { … }` literal sugar. DONE
    (2026-06-02).** Authoritative + interface-driven: a new core interface
    `FromEntries c e` (`fromEntries : List e -> c`, dispatched on the result type
    `c`); `impl FromEntries (Map k v) (k, v) requires Ord k` lives in map.mdk
    (Set's awaits set.mdk). `Desugar.lower_container_literals` lowers
    `Map { k => v, … }` → `(fromEntries [(k,v), …] :~ Name _k _v)` and `Set { … }`
    → `(fromEntries [...] :~ Name _a)`, where `:~` is a new **`EHeadAnnot`** node —
    EAnnot minus the skolemization-by-identity check, so it pins only the *head*
    tycon flexibly (the element vars may ground). That pin makes `fromEntries`'s
    return-position dispatch resolve to the named container's impl (so the name is
    **authoritative** — `Banana { … }` is a resolve-time `Unknown type`), and the
    impl's `Ord k` threads in via the ordinary return-position dict machinery
    (Phase 103). Key insight that kept it cheap: lowering to a *normal* method call
    + a tiny transparent pin node means **zero changes to the dispatch/dict core** —
    EHeadAnnot recursion rides `Desugar.map_expr` (so marker + dict_pass get it
    free), and eval just evaluates the inner expr. The old eval stub (`VCon
    "<Name>.fromList"`) and the direct EMapLit/ESetLit typecheck arms are now
    `InternalError`/`assert false` guards (the EDo/Phase-99 pattern; EMapLit/ESetLit
    stay surface nodes for fmt round-trip). Touches ast/desugar/printer/coverage/
    resolve/typecheck/eval + core.mdk + map.mdk. **Limitations:** (1) extends to
    any container with a `FromEntries` impl, but two same-shape containers in
    scope need a type annotation to disambiguate (the name pins the *head*, not
    the full type). (2) **Empty literals don't work** — `Map { }` / `Set { }`
    fail (`Type mismatch: Map Int vs Map`): empty braces carry no `=>` to mark
    map-vs-set, so the parser emits `ESetLit(name, [])` and the lowering pins the
    *unary* `name _a`, the wrong arity for a binary `Map`. Low value (empty
    containers have `empty`/`Monoid.empty`), but recordable. Possible fix:
    `EHeadAnnot` in typecheck could ignore the lowering-supplied arity and apply
    the head tycon to its *declared* arity of fresh vars (a tycon-arity lookup).
    Skill: **add-language-feature**.
- **Modules 6–8 unstarted:** `mut_array`/`hash_map`/`hash_set`, `io`
  (`readFile`/`writeFile`/`readLine`), `json` (type + parser + serializer).
  Expect each to surface new language gaps — record them here as new phases.
  - ⭐ **`set` (finishing Module 5) and `io` are the remaining critical-path
    Stage 0 prerequisites** — a self-hosted compiler needs symbol tables (have
    `map` now) and file I/O. (`mut_array`/`hash_map`/`hash_set` matter mainly for
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
