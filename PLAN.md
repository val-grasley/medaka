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
number (last used: 134). At task triage, match the work against AGENTS.md's
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
  *on* the interpreter must finish in minutes, not hours. **First measurement
  (2026-06-03):** the bare eval loop is fine — 1,000,000 tight-loop iterations in
  ~0.15s (~150ns/iter). The cost is in **typeclass dispatch + persistent-tree
  allocation**: 5000 ordered-`Map` inserts + 5000 lookups take ~1.0s (~100µs/op,
  ~600× a loop iter). So symbol-table-heavy passes (resolve, type-substitution)
  will dominate, and the eval hot path / environment representation will likely
  need work — but it does **not** block *starting* the port (slow-but-correct is
  the accepted Stage-1 bargain). Re-measure on the first real Medaka-in-Medaka
  stage.
- **Multi-file ergonomics at scale.** The module system, qualified access, and
  `medaka.toml` workspaces exist; per-module eval isolation landed (Phase 110).
  **Scale-probed 2026-06-03** with a synthetic 25-module project (deep chains +
  diamonds + cross-module impls): deep linear import chains, diamond deps,
  qualified access, and generic dispatch over imported instances all hold up. The
  probe surfaced one hard gap — cross-module user-defined interfaces — **now
  closed (Phase 130 ✅)**: an interface declared in one module can be `impl`'d for
  a type in another and its constraint discharged (directly *and* through a
  generic constrained function) in a third, provided the `impl` is `export`ed. The
  only residue is a verbosity papercut (per-function `export` lines; importing
  method names for `impl` bodies) — ergonomic, not a blocker. Multi-file
  ergonomics now hold up for the self-host port.

### Stage 1 — Self-host on the interpreter

Port the pipeline (`lexer → parser → desugar → resolve → typecheck (runs
exhaust) → eval`) into Medaka, one stage at a time, checked against the OCaml
reference at each step. **Done when** Medaka-in-Medaka compiles a real program identically to
the OCaml compiler, and ultimately compiles *itself*. The output of this stage is
a validated language and a compiler whose only slow part is the interpreter
underneath it.

**Started 2026-06-03 (Phase 132).** The self-host tree lives in `selfhost/`
(see `selfhost/README.md`), and the validation loop is wired: `sh
test/diff_selfhost_lexer.sh` runs the Medaka lexer on the interpreter over
`test/diff_fixtures/` and diffs its token stream against the OCaml-emitted golden
`=== TOKENS ===` sections. Scaffold + harness are in place; the lexer's
`tokenize` is still a stub — porting it is the active slice.

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

- ⭐ **Phase 132 — self-host Stage 1: port the lexer to Medaka. IN PROGRESS
  (started 2026-06-03); lexer fixture-complete.** First stage of the self-hosting
  effort (North star → Stage 1). **Done:** the `selfhost/` scaffold + differential
  validation loop (`selfhost/lexer.mdk`, `selfhost/lex_main.mdk`,
  `test/diff_selfhost_lexer.sh`), and the full tokenizer — literals, idents/
  keywords, operators/punctuation, line comments, string interpolation, and a
  faithful port of `lib/lexer.mll`'s INDENT/DEDENT/NEWLINE layout algorithm +
  else-continuation filter + leading-operator continuation. **All 15/15 fixtures
  in `test/diff_fixtures/` match the OCaml reference byte-for-byte.** Pure
  two-pass design (scan → RawTok stream with `RNewline` markers; layout pass →
  INDENT/DEDENT/NEWLINE). Lexer uses prelude + global externs only (no stdlib
  import), so `selfhost/` is a single-root project.
  **Now also validated on real source** (2026-06-03): added `{- … -}` nestable
  block comments, hex/bin/oct int literals, and the `@`/`AS_AT` adjacency rule —
  the gaps surfaced by self-lexing. `dev/lextok.exe` dumps the OCaml reference
  token stream for any file, and `test/diff_selfhost_lex_files.sh` diffs the
  Medaka lexer against it over **all 13 real `.mdk` files (every stdlib module +
  the lexer lexing itself) — 13/13 match byte-for-byte** (FLOAT text normalized:
  OCaml `%g` vs `floatToString`, same TFloat value). **Still deferred** (no real
  file or fixture uses them): triple-quoted strings (+ `strip_indent`) and nested
  interpolation. **Next:** the parser stage, which forces the **stdlib-access**
  decision (multi-root loader or vendored `Map`/`List`/`string`).
  **Two self-host-surfaced compiler quirks to file/fix:** (1) char literals do no
  escape processing, so newline/tab/quote/backslash must be matched by `charCode`
  (worked around in `lexer.mdk`); (2) an `<IO>`-returning *helper* called from a
  `match` arm is not forced by the eval driver — the action is returned but never
  run (clean exit, no output) — while the inline form runs (`lex_main.mdk` is
  written inline to dodge it). (2) deserves a minimal repro + fix. Byte-for-byte
  serialization caveats mapped: OCaml `%S` escapes non-ASCII as decimal byte
  escapes (`debugStringLit` agrees on ASCII), `FLOAT` uses `%g` (vs
  `floatToString`). See `selfhost/README.md`.

- **Phase 134 — eval bug: an `<IO>`-returning helper called from a `match` arm
  isn't forced (surfaced by Phase 132).** TODO — investigate + fix.
  **Symptom:** a function whose body produces an `<IO>` action, when invoked from
  a `match` arm, returns the action without running it — the program exits 0 with
  **no output**; inlining the identical body runs correctly. This silently breaks
  the obvious "factor the IO into a helper" refactor and is a real correctness
  bug, not just an ergonomic wart.
  **Confirmed repro (current tree):** with `selfhost/lexer.mdk` present, the
  `emit`-helper form of the lexer entry prints nothing while the inline form
  prints all tokens —
  ```
  emit path =
    match readFile path
      Ok src => putStr (renderToks (tokenize src))
      Err msg => ePutStrLn msg
  main =
    match args ()
      [path] => emit path           -- ← 0 bytes out, exit 0
      _ => ePutStrLn "usage"
  ```
  vs. inlining the inner `match readFile …` directly under `[path] =>` (works —
  this is what `selfhost/lex_main.mdk` does).
  **Bisection so far (narrowing, not yet minimal):** the small/standalone analogs
  all *work* — helper-from-match-arm with a constant `putStr`, with a recursively
  built string, with a `match readFile` body, and even a 2-module case where the
  helper renders a `List` of an imported ADT. The failure only reproduces with the
  *actual* large `lexer.mdk` (`tokenize`/`renderToks`), so the trigger correlates
  with something the minimal cases lack (recursion depth / list size / the
  90-arm `tokenToString` / cross-module thunk-forcing order). Producing a minimal
  repro is the first task.
  **Where it lands / how to chase:** almost certainly the eval driver in
  `lib/eval.ml` — how a top-level `main` (and nested calls) force `<IO>` actions,
  i.e. whether a function-application result that *is* an IO action gets run or
  just returned. Smells like the deferred-thunk / install-order family behind
  Phases 96/103/121/125 (loader vs flat eval); confirm with `dev/module_debug.exe`
  and shrink `lexer.mdk` until it stops reproducing. **Skill: debug-pipeline.**

- **Phase 133 — char literal escape processing. ✅ DONE (2026-06-03).**
  Char literals now process the same escape suite as string literals: `\n \t \r \0 \\ \'`
  and `\u{…}`. The fix replaced the single-regex rule in `lib/lexer.mll` with a
  `read_char` auxiliary (matching the `read_string` / `read_triple_string` pattern);
  `lib/printer.ml` gained `escape_char_lit` so `LChar` round-trips correctly;
  `debugCharLit` in `lib/eval.ml` likewise escapes special chars. The `selfhost/lexer.mdk`
  workaround (comparing via `charCode` for `\t`/`\n`/`\'`/`\\`) was replaced with
  direct char literals. 7 new parser test cases cover every new escape form.

- **Phase 131 — add token-stream section to the diff harness. ✅ DONE
  (2026-06-03).** Added `Lexer.tokenize_string : string -> string list` +
  exhaustive `token_to_string` in `lib/lexer.mll` (no wildcard arm, so a new
  grammar token surfaces a non-exhaustive-match warning here). Prepended a
  `=== TOKENS ===` section (one token per line, same `rstrip_nl` normalization)
  to both `dev/gen_golden.ml` and `test/thorough/thorough_diff.ml`, regenerated
  all 15 goldens (purely additive), and the harness now runs 60 cases (15 ×
  {TOKENS, AST, TYPES, EVAL}, up from 45). `split_sections` is order-independent
  so it needed no change. The diff harness now validates lexer output for all 15
  fixtures before the Medaka lexer is wired in (Stage 1). Token format: payload
  tokens render kind + value (`INT 42`, `STRING "hi"`, `IDENT "foo"`), everything
  else (keywords/operators/punctuation/`NEWLINE`/`INDENT`/`DEDENT`/`EOF`) as the
  bare variant name.

- ⭐ **Phase 130 — cross-module user-defined interfaces ✅ DONE (2026-06-03).**
  A user `interface` declared+`export`ed in module A can now be `impl`'d for a
  type owned by module B and its constraint discharged in a third module C. The
  whole gap was a single resolve omission: the `DUse` import loop in `resolve.ml`
  copied an imported interface's *name* into `env.interfaces` but not its method
  set into `env.iface_methods`, so any `impl` of it tripped "Method 'X' is not
  part of interface Y". Layer 2 (impl discharge) needed **no** change — `te_impls`
  already propagates a module's `export impl`s by full `impl_key`, and the orphan
  check only fires when both iface and type are non-local. See PLAN-ARCHIVE.md for
  the full writeup. *Secondary ergonomic finding still open* (file separately if
  it compounds): every cross-module function needs its own `export` line, and an
  `impl` module must import each interface **method name** it references.

- **Phase 129 — differential-testing harness (self-host validation rig). ✅ DONE
  (2026-06-03).** 15 standalone `.mdk` fixtures in `test/diff_fixtures/`; each
  gets a `<name>.golden` with three sections committed to git: `=== AST ===`
  (canonical `Printer.program_to_string` round-trip), `=== TYPES ===` (full
  alphabetic type env from `Typecheck.check_program`), `=== EVAL ===` (typed
  pipeline stdout via `Elaborate.elaborate` + `eval_program ~prelude:false`).
  Regeneration probe: `dev/gen_golden.exe`. Comparison runner:
  `test/thorough/thorough_diff.ml` (45 alcotest cases), wired into `@thorough`
  via `(setenv DIFF_FIXTURES_DIR %{workspace_root}/test/diff_fixtures ...)`.
  Token-stream section deferred to Phase 131 (natural point: when the lexer port
  begins). Medaka-stage comparison slots in alongside each port stage.

- **Phase 128 — freeze `stdlib/string.mdk` (review + lock the API). DONE 2026-06-03.**
  49/49 doctests pass. Open decisions settled and documented in STDLIB.md (Module 3
  marked reviewed/frozen): (1) `length`/`isEmpty` intentionally absent — would
  clash with `Foldable`; callers use `stringLength`/`s == ""`; `Sized`/`HasLength`
  deferred. (2) `toUpper`/`toLower` confirmed as the String-level names (full
  Unicode, 1→N expansion); `charToUpper`/`charToLower` remain as Char-level kernel
  externs only. No code changes needed — decisions were already encoded; Phase was
  pure documentation/freeze.

- **Phase 127 — unit testing library (`test` keyword + `stdlib/test.mdk`). DONE 2026-06-03.**
  Medaka has doctests (example-as-documentation) and `prop` tests (universal
  laws) but no plain unit tests. Add a third kind for what the other two cover
  poorly: error/negative paths, non-`show`-able or multi-step results, effectful
  checks, and maintainer-only checks that shouldn't clutter docstrings. **Design
  settled 2026-06-03** (brainstorm); division of labor goes in STDLIB.md so the
  three don't compete.

  **Surface syntax** — a new `test` declaration keyword, symmetric with `prop`,
  whose body evaluates to an `Expectation`:
  ```
  test "reverse is an involution" =
    expectEqual (reverse (reverse [1, 2, 3])) [1, 2, 3]
  ```

  **Architecture: dogfooded Medaka runner, host does discovery only.**
  - *Host (discovery, no type inference):* scan `DTest` decls — exactly like
    `DProp` — and synthesize an injected registry value, wrapping each body in a
    thunk so nothing runs at collection time:
    `__tests__ : List (String, Unit -> Expectation) = [ ("name", () => <body>), … ]`.
    Then evaluate a call to the library's `runTests __tests__` and read the
    returned `VBool` for the exit code. New **third pass** in `bin/main.ml`
    (`if has_sub "test"`) after doctests + props, `&&`-ed into the result.
  - *`stdlib/test.mdk` (pure Medaka — the dogfooded part):* `public export data
    Expectation = Pass | Fail String` plus the assertion vocabulary —
    `expectEqual`/`expectNotEqual : (Eq a, Show a) => a -> a -> Expectation`,
    `expectTrue`/`expectFalse : Bool -> Expectation`,
    `expectLessThan`/`expectGreaterThan : (Ord a, Show a) => …`, `pass`, `fail :
    String -> Expectation`, `expectAll : List Expectation -> Expectation` (first
    `Fail` wins) — and `runTests : List (String, Unit -> Expectation) -> <IO>
    Bool`, which loops, forces each thunk, formats results (match
    `lib/test_cmd.ml`'s style), and returns all-passed. **v1 is minimal: one
    `Expectation` per test, `expectAll` for conjunction, NO `describe`/nesting**
    (group via `"List/reverse/…"` names).

  **The one new extern (`add-primitive`): `runExpectation`.** A pure-Medaka
  `runTests` cannot survive a crashing test — a partial match / `head []` is an
  OCaml-level `Eval_error`, and the language has no `try`/`catch`, so one crash
  takes down the whole run and loses every later test (doctests/props dodge this
  only because their loops live in OCaml). So a dogfooded runner *requires* a
  single narrow escape hatch — NOT a general `try`/`catch` (that would contradict
  the "errors are `Result` data, not exceptions" stance), but one purpose-built
  primitive:
  `runExpectation : (Unit -> <e> Expectation) -> <IO> Expectation`,
  implemented in `eval.ml` as `try force-thunk with Eval_error | Impl_no_match ->
  Fail <msg>`. `runTests` maps it over the registry and never sees a raw panic.

  **Resolution caveat (the real risk).** `test.mdk` is NOT in the prelude (see
  below), so test files `import test.{…}` and the host's injected `runTests
  __tests__` references an *imported* module. Route the discovery pass through
  the **proven multi-module loader path** Phase 92 built for import-bearing
  doctests (`Doctest.run_file` branches on `has_use_decls` → `Loader.load_program`
  + `Eval.eval_modules`) — reuse the same shared loader-assembly helper Phase 126
  wants factored out, rather than a new single-file path that would hit the
  loader-vs-flat eval landmines (Phases 96/103/121/125).

  **Why not the prelude (settled, not open).** Full prelude inclusion is
  *inadvisable*: it pollutes *every* program (incl. non-test code) with generic
  names — `Pass`/`Fail`/`fail`/`pass`/`Expectation` — and taxes every compile
  with test machinery + the `runExpectation` `<IO>` extern. `prop` needs no
  import only because it uses pure prelude vocab (`eq`/`&&`); `test` needs a real
  library, which shouldn't be global. v1 uses an explicit `import test.{…}`
  (conventional — Elm `import Expect`, HUnit/Hspec all import).

  **Followup (v2, deliberately deferred — do NOT bundle into v1):**
  *conditional auto-import.* Since the discovery pass already detects `test`
  decls, it can inject the test vocabulary **only into files that contain a
  `test` decl** — frictionless like a keyword, with zero pollution of non-test
  files. Deferred because it is a *second conditional-prelude* path, and
  `marked_prelude` coalescing + loader-vs-flat ordering is this codebase's most
  repeated bug source — build it on a working, tested v1, not speculatively.

  **Build shape:** `add-language-feature` (the `test` keyword: lexer.mll →
  parser.mly → ast.ml `DTest` → resolve.ml → `bin/main.ml` discovery) +
  `add-primitive` (`runExpectation` in runtime.mdk + eval.ml) + `extend-stdlib`
  (`stdlib/test.mdk`, STDLIB.md division-of-labor paragraph, gen/embed.ml if
  embedded). Tests: a fixture file with `test` decls (incl. one crashing test and
  one `expectAll`) driven through the multi-module path, plus an import-bearing
  variant — land in `test_run`/`test_doctest`-adjacent suites.

- **Phase 126 — `medaka test` prop phase now resolves sibling imports ✅ DONE
  (2026-06-03).** The prop phase routed import-bearing files single-file and failed
  at `Unbound variable: <name>`; it now reuses the loader exactly like doctests.
  Factored `Doctest.assemble_marked_modules` (shared by both phases), and the prop
  phase evals via the new `Eval.eval_modules_root_env` (the root's *full* env — the
  plain `eval_modules` returns only root locals, so prop bodies couldn't see imports
  or prelude operators). `--coverage` works on import-bearing files too. See
  PLAN-ARCHIVE.md for the full writeup.

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
    dispatches by result type. Argument-dispatched wrappers (`Eq`/`Debug`/`Ord`)
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
that constraint and delegated the remaining modules (Modules 5–9). STDLIB.md is
the per-module checklist; **all of Modules 5–9 are now complete** (`map`/`set`,
hash containers, `io`, `mut_array`, `json`) — see PLAN-ARCHIVE.md and STDLIB.md.

- ✅ **`stdlib/string.mdk`** — API frozen 2026-06-03 (Phase 128). 49/49 doctests
  pass. Open decisions resolved: `length`/`isEmpty` intentionally absent (clash
  with `Foldable`; use `stringLength`/`s == ""`); `toUpper`/`toLower` own the
  String-level names; `charToUpper`/`charToLower` remain as Char-level externs.

- **Module 6 — hash containers ✅ DONE (Phase 120).**
  `stdlib/hash_map.mdk` + `stdlib/hash_set.mdk` — **mutable** hash tables
  (separate chaining in a `Ref`-held `Array`, resize past load factor 0.75),
  the O(1)-average performance counterpart to the ordered Module 5. New `hash`
  extern (structural, non-negative); removed `"HashMap"`/`"HashSet"` from
  `resolve.ml` `primitive_types`. HashSet impls `Foldable` (elements = `toList`);
  HashMap uses `entries` internally (its `toList` = pairs would clash with
  `Foldable.toList`). 8 + 7 doctests, stress-verified (100 inserts → multiple
  resizes, delete, dedupe). Surfaced **Phase 118** (`if`/`else` block branches),
  **Phase 122** (else-less `if`, the remaining `<Mut>` ergonomics gap), and
  **Phase 119** (false-positive non-exhaustiveness for 3+-arg list matches) — all
  three now ✅ DONE (see PLAN-ARCHIVE.md).
- **`mut_array` ✅ DONE (2026-06-03)** — `stdlib/mut_array.mdk`, a growable mutable
  vector (amortized-O(1) `push` over a doubling `Array`). Closes out Module 6's
  remaining piece (STDLIB.md numbers it Module 8). Mainly an interpreter/compiler
  perf nicety; not on the self-hosting critical path.
- **`json` ✅ DONE (2026-06-03)** — `stdlib/json.mdk` (STDLIB.md Module 9): a
  recursive-descent `Json` ADT (`JNull`/`JBool`/`JInt`/`JFloat`/`JString`/
  `JArray`/`JObject`, `Array`-backed) with `parse : String -> Result String Json`
  and compact `stringify`, plus `Eq`/`Show`/`Display` instances. The first stdlib
  module to import real siblings (`list`/`string`) — which surfaced Phase 126
  (the prop phase's single-file import limitation, now ✅ DONE 2026-06-03). Not on
  the self-hosting path.
- ✅ **Module 7 `io` — DONE (Phase 116).** Comprehensive: externs (`args`,
  `getEnv`, `fileExists`, `appendFile`, `listDir`, `ePutStr`/`ePutStrLn`,
  `readLineOpt`, `readAll`) in runtime.mdk + eval.ml, `args` wired through
  `bin/main.ml` (`medaka run FILE a b c` → `["a","b","c"]`), plus `stdlib/io.mdk`
  (`eprint`/`eprintln` via Display, `readLines`, `getEnvOr`). See STDLIB.md
  Module 7. (Surfaced Phase 117, the string-import blocker — see
  PLAN-ARCHIVE.md.)

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
