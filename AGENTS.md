# AGENTS.md

Orientation for AI agents working on **Medaka**, a pragmatic functional
language implemented in OCaml. This file is a *router*: maps, gotchas, and
links. For prose and rationale, follow the links — don't assume detail that
isn't here.

The compiler is one OCaml library, `medaka_lib` (everything in `lib/`).
**There are no `.mli` files** — modules expose everything. Compilation is a
linear pipeline; each stage is one file.

> **Medaka self-hosts and compiles to native code.** Besides the OCaml reference
> compiler (`lib/`, described below), the whole pipeline is rewritten in Medaka
> (`selfhost/*.mdk`) and a native **LLVM backend** (`selfhost/llvm_emit.mdk` → text
> IR → `clang`; C runtime `runtime/medaka_rt.c` + Boehm GC) compiles it. As of
> 2026-06-08 all 7 stages are native-compiled byte-identical to the interpreter
> and the compiler self-hosts to a **reproducing fixpoint** (`selfhost/BOOTSTRAP.md`).
> As of 2026-06-10 the **Stage-4 tooling is ported** (fmt/test/new/repl/build/lsp, all
> differential-tested vs OCaml) and the **Phase-C native CLI capstone is complete**:
> `selfhost/medaka_cli.mdk` native-compiles into a single OCaml-free `medaka` binary
> that does all 8 subcommands (`check`/`fmt`/`new`/`build`/`run`/`test`/`repl`/`lsp`) with no
> OCaml at runtime. **As of 2026-06-12 the native `medaka` is CANONICAL (milestone flip):** all
> PRE-FLIP-GAPS.md soundness/capability gaps (G1–G9) are closed, and **`make medaka` builds the
> native compiler OCaml-free** — day-to-day a 2-stage warm rebuild from current source
> (`build_native_medaka.sh`, no seed), and on a fresh clone a cold bootstrap from the
> gzipped checked-in IR seed (`selfhost/seed/emitter.ll.gz` → `bootstrap_from_seed.sh` →
> `build_native_medaka.sh`). The OCaml compiler (`lib/`+`bin/`) is now
> the **frozen soak-period differential oracle** — **retired (≠ removed; see PLAN.md "Retirement ≠
> removal" + [[retirement-is-not-removal]])**. **Current focus (2026-06-14) = the soak tail.
> DONE: gate re-rooting (all correctness gates now OCaml-free — `selfhost/REROOT-PLAN.md`);
> the DRIVER COLLAPSE (single-file typecheck+eval folded into the 1-module case of the
> multi-module path — `selfhost/DRIVER-COLLAPSE-PLAN.md`, closes audit §6's recurring
> single-vs-multi defect; `medaka check` now resolves imports); native dispatch fixes #55
> (sum/product, both build AND eval paths), #21 (binop over-application on parametric user
> impls), and the map `Foldable (Map a)` typecheck false-positive + `medaka test` SIGBUS;
> expanded native stdlib test coverage (json/toml/list/set); fuzzer ported to native
> (`fuzz_diff.sh` OCaml-free); the native-emitter cross-module **constructor-name collision**
> (the fuzzer's find — mis-filed as "mixed-ADT match", really bare-name ctor-table collapse)
> fixed via universal ctor mangling; the **`argStampEnabled` eval-vs-emit dispatch unification
> COMPLETE** (`selfhost/ARGSTAMP-UNIFY-PLAN.md` — eval now threads dicts; the GENUINE #21
> nested-element-dict flattening solved, not contained; `evalDictLayerActive` retired); and
> the **emit-path Set-literal / mutual-rec-Monoid dict gaps** (#44) fixed. **REMAINING = the
> soak itself:** a clean bug-free stretch of native-only dev, then the confidence-gated `lib/`
> removal.** Native-backend docs: `selfhost/BOOTSTRAP.md` (the B1–B7 + C1–C3 log), `selfhost/PRE-FLIP-GAPS.md`
> (the closed pre-flip punch list), `selfhost/EMITTER-GAPS.md`
> (closed/residual emitter gaps), `selfhost/DISPATCH-GAPS-SCOPE.md` (repro-verified scope of
> the now-CLOSED native dispatch gaps #54/#55/#50/#21 — all four resolved as of 2026-06-14), `selfhost/PERF-SCOPE.md` (bar-4 `-O2`/benchmark
> scoping) + `selfhost/PERF-RESULTS.md` (**bar-4 EXECUTED 2026-06-11: self-compile 5.68× / ~59× vs
> the OCaml interpreter, 18 fixpoint-gated wins; harness `test/bench.sh`**),
> `selfhost/STAGE2-DESIGN.md` + `selfhost/RUNTIME-DESIGN.md`
> (design), `selfhost/README.md` (slice log). Harnesses: `test/bootstrap_*.sh`
> (native stage == interpreter), `test/selfcompile_*.sh` (emitter self-compile).

## Pipeline — where each stage lives

**Execution order** (the drivers in `diagnostics.ml` / `bin/main.ml` run it this
way — *not* the order files happen to be listed):

```
lexer.mll → parser.mly → ast.ml → desugar.ml → resolve.ml → method_marker.ml
  → typecheck.ml (runs exhaust.ml internally) → eval.ml
```

Two non-obvious facts that bite when deciding *where* a check belongs:
- **`desugar.ml` runs first**, before resolve/typecheck. So surface-sugar nodes
  (`EGuards`, `EFunction`, `ESection`, list comprehensions, string interp) are
  **already lowered to core** by the time typecheck/exhaust/eval see the tree. A
  check that needs the sugar shape (e.g. guard *coverage* on `EGuards`) cannot
  live in typecheck/exhaust — it must run pre-desugar (see `Exhaust.
  check_guard_exhaustiveness`, a standalone pass on the raw AST).
- **`exhaust.ml` is not a standalone later stage** — `Exhaust.check_match` is
  *called from inside* `typecheck.ml` (once per `EMatch`, with the scrutinee type
  known). It only ever sees core patterns.

| Stage | File | Role |
|-------|------|------|
| Lex | `lib/lexer.mll` | Indentation-sensitive; emits INDENT/DEDENT/NEWLINE |
| Parse | `lib/parser.mly` | Menhir grammar |
| AST | `lib/ast.ml` | Node types + source locations |
| Desugar | `lib/desugar.ml` | Runs FIRST. Lowers surface sugar: `deriving`, record puns, list comprehensions, `EGuards`/`EFunction`/`ESection`/string-interp, `EDo` (do-blocks → nested `andThen`/`pure`, Phase 99) |
| Resolve | `lib/resolve.ml` | Name binding, single- and multi-module |
| Mark | `lib/method_marker.ml` | Phase 69: runs after desugar+resolve, before typecheck. Rewrites interface-method `EVar`→`EMethodRef` so typecheck can stamp the resolved impl key per call site and eval routes return-position/multi-param dispatch by it |
| Typecheck | `lib/typecheck.ml` | Hindley-Milner + interfaces + effects; invokes Exhaust per `EMatch` |
| Exhaust | `lib/exhaust.ml` | Maranget pattern-matrix algorithm; called *from* typecheck, not standalone |
| Eval | `lib/eval.ml` | Tree-walking interpreter; VMulti typeclass dispatch |

Support files:

| File | Role |
|------|------|
| `lib/loader.ml` | Multi-file dependency walk, topo sort, cycle detection; structured `ParseError` (file/line/col) |
| `lib/prelude.ml` | Caches `stdlib/core.mdk` as the implicit prelude |
| `lib/runtime.ml` | Parses `stdlib/runtime.mdk` to derive primitive signatures |
| `lib/diagnostics.ml` | Accumulating error pipeline — phases collect errors, no exit-on-error |
| `lib/printer.ml` / `lib/fmt.ml` | AST→source round-trip / comment-preserving formatter |
| `lib/builtins.ml` | Operator → stdlib method-name registry |
| `lib/lsp_server.ml` | LSP over stdio: diagnostics, formatting, symbols, hover, definition, highlight, completion, inlay hints |
| `lib/project_config.ml` | `medaka.toml` reader + project-root walk-up |
| `lib/doctest.ml` | Extracts + runs doctests for `medaka test`. Reads the lexer comment side-channel: `-- > expr` then `-- result` lines (block comments `{- … > expr … -}` are expanded to the same line form). Synthesizes one `__dt_i__ = debug (...)` binding per example, then **two paths** (Phase 92): a file importing a real sibling module goes through `run_file_multi` (the multi-module `typecheck_module` chain — keeps modules separate, reports typecheck failures honestly per-example); a file with no imports (or whose only imports were the prelude `core`, which the loader filters) takes the single-file `check_program` path, which `prelude_for`-shadow-drops redefined names and on typecheck failure falls back to arg-tag dispatch. The single-file fallback is deliberate: the multi-module path's full `marked_prelude` would coalesce a redefined prelude standalone (e.g. `string.mdk`'s `count`) and ERROR every example at once |
| `gen/embed.ml` | Build-time: embeds `runtime.mdk`/`core.mdk` into generated `lib/stdlib_content.ml` |
| `bin/main.ml` | CLI: `check` / `run` / `test` (doctests + prop tests) / `repl` / `lsp` / `fmt` / `new` |

`stdlib/`: `runtime.mdk` (extern primitive catalog, embedded), `core.mdk`
(implicit prelude — `Eq`/`Ord`/`Debug`/`Num`/…), `list.mdk`/`string.mdk`/`array.mdk`/`map.mdk`/`set.mdk`/`io.mdk`/`hash_map.mdk`/`hash_set.mdk`/`mut_array.mdk`/`json.mdk`
(written in Medaka; `map.mdk`/`set.mdk` are weight-balanced ordered `Map`/`Set`;
`hash_map.mdk`/`hash_set.mdk` are mutable hash tables; `mut_array.mdk` is a
growable mutable vector (amortized-O(1) `push` over a doubling `Array`); `json.mdk`
is a recursive-descent JSON parser/serializer with an `Array`-backed `Json` ADT;
`io.mdk` is the ergonomic layer over the `runtime.mdk` IO externs).

## Build & test

```sh
dune build      # also regenerates lib/stdlib_content.ml from gen/embed.ml
```

**In a `.claude/worktrees/<name>` worktree, use `dune build --root .`** (and
the same `--root .` for `@thorough`). Plain `dune build` fails with `No rule
found for alias .../default`: the worktree lives physically inside the main
checkout, so dune walks up to the parent repo and treats the worktree as a
subdir. `--root .` pins the worktree as the project root. The built exes still
run from `./_build/default/...` as below.

**Do NOT run `dune test` — it can hang.** Run individual suites instead:

```sh
./_build/default/test/test_<name>.exe --compact
```

Suites: `test_parser` `test_roundtrip` `test_resolve` `test_typecheck`
`test_eval` `test_run` `test_repl` `test_loader` `test_diagnostics` `test_fmt`
`test_project_config` `test_new_cmd` `test_doctest` `test_snapshot`
`test_coverage` `test_lsp`.

Exhaustive edge-case suites: `dune build @thorough` — this **runs** them (the
`thorough` alias's rules execute each `thorough_*.exe`, so a failing assertion
fails the build and `dune` exits non-zero). It is *not* in `dune test`/`runtest`
(deliberately, to avoid the hang above). A new suite needs both a `(names …)`
entry and its own `(rule (alias thorough) (action (run …)))` runner in
`test/thorough/dune`. Caching is by content: edit a suite or `lib/` and the run
re-fires; otherwise it's cached. (Historically this alias only *built* the exes
without running them, so the suites silently drifted — don't regress that.)

Dev probes (build to `_build/default/dev/`):

```sh
./_build/default/dev/debug.exe      # parse-and-print probe
./_build/default/dev/tc_debug.exe   # typecheck probe
./_build/default/dev/module_debug.exe [entry.mdk [root ...]]
                                    # multi-module probe: runs the full loader→
                                    # mark→typecheck_module→eval_modules pipeline,
                                    # dumps the dict-passed user decls, and evals
                                    # the SAME tree through both eval_modules (the
                                    # loader path) and eval_program (the flat
                                    # single-file path) — diff the two to localize
                                    # a loader-vs-flat divergence to typecheck/
                                    # dict_pass (trees differ) vs the eval driver
                                    # (trees identical, outputs differ). No arg ⇒
                                    # runs the Phase-125 repro from a temp dir.
```

## Gotchas

- **Environment is pre-set.** opam env vars (switch `5.4.1`, PATH) are already
  exported via `.claude/settings.local.json`. **Never** prefix commands with
  `eval $(opam env)` — it's redundant. *Exception:* a sandboxed shell sometimes
  strips PATH, so `dune` reports `command not found`. If that happens, prepend
  the switch bin inline — `export PATH="$HOME/.opam/5.4.1/bin:$PATH"` — rather
  than reaching for `eval $(opam env)`.
- **In a worktree, build with `dune build --root .`.** When the working
  directory is under `.claude/worktrees/`, a plain `dune build` climbs to the
  parent checkout and fails with `No rule found for alias …/default`. Pass
  `--root .` to pin the build (and tests) to the worktree. Combine with the
  PATH fix above if the sandbox also stripped PATH.
- **In a worktree, edit the worktree's files — use the full worktree path.**
  The shell cwd resets to the main checkout root each call, so a relative
  `grep -n lib/foo.ml` runs there and prints `lib/foo.ml:NN`; Read/Edit that
  bare path and you've silently changed the **main checkout**, which the
  `--root .` build never sees (and which dirties `git status` in main). Always
  target `/…/.claude/worktrees/<name>/lib/foo.ml`. If you slip: `cp` the edited
  files into the worktree, then `git -C <main> checkout -- <files>` to restore
  main.
- **Medaka multi-arg lambdas are `x y => body`**, not curried
  `x => y => body`. Curried forms predating Phase 59.6 are legacy artifacts,
  not the current style — match the `x y => body` form in new code.
- **Errors accumulate.** Phases push into `diagnostics.ml` rather than raising
  on the first error; don't add early `exit`/`raise` paths.
- **`lib/dune` has an explicit `(modules …)` list.** A new `lib/<name>.ml` is
  *not* picked up automatically — add it to that stanza or the build fails with
  `Unbound module Medaka_lib.<Name>`.
- **The prelude (`core.mdk`) is embedded at build time** (`gen/embed.ml` →
  `lib/stdlib_content.ml`). After editing `core.mdk`/`runtime.mdk` you **must
  `dune build`** before `run`/cross-module tests reflect it — they read the
  *embedded* snapshot. Confusing split: `medaka test stdlib/core.mdk` reads the
  file directly (sees edits immediately), but a *different* file importing the
  prelude uses the stale embed until rebuild — symptom is an error citing an old
  `core.mdk` line number.
- **To run a whole program, `main` must be a zero-arg value** (`main = …`), not
  `main () = …`: `medaka run` evaluates top-level bindings and checks `main`
  exists but never *applies* it, so `main () = …` is a silent no-op (exit 0, no
  output). Use `main = println …` for scratch probes.
- **The prelude is marked + dict-passed in the typed pipeline (Phase 69.x-c).**
  `Method_marker.marked_prelude` is the prelude marked against its own interface
  methods + constrained fns; `Typecheck.check_program`/`typecheck_module` prepend
  *it* (filling its `EMethodRef`/`EDictApp` refs in place), and the typed eval
  drivers build `marked_prelude @ user`, `Dict_pass.run` it, and call
  `Eval.eval_program ~prelude:false`.  So elaboration (EMethodRef/EDictApp)
  reaches prelude methods like `pure`/`when`/`unless`.  **Untyped**
  `Eval.eval_program` (default `~prelude:true`, no marker/typecheck — e.g. quick
  eval tests) prepends the *raw* prelude and falls back to arg-tag "first impl
  wins" for return-position methods: `pure` needs types to dispatch, so route it
  through the typed pipeline (see `run_typed` in `test/test_eval.ml`).
- **A dispatch bug that reproduces through the loader but is a green single-file
  doctest is *usually* the EVAL DRIVER, not typecheck/dict-passing** — even when a
  PLAN entry says otherwise. This shape recurred at Phases 96, 103, 121, and 125,
  where the filed root cause blamed dict-passing and was wrong. Why the split
  exists: single-file `eval_program` merges everything into one by-name frame and
  forces deferred thunks only after every impl is installed; the loader's
  `eval_modules` uses per-module frames and a separate prelude/Phase-B install
  order, so **binding-order and impl-install-order** bugs surface *only* there.
  Diagnose with `dev/module_debug.exe`: it evals the *same* typechecked +
  dict-passed tree through both drivers — identical tree but only `eval_modules`
  panics ⇒ eval driver (load **debug-pipeline**, fix in `lib/eval.ml`).
  **But VERIFY empirically — this heuristic has a documented exception (Phase
  134), where a loader-only bug WAS dict-passing.** `eval_modules` dict-passes
  the prelude + all modules *jointly* and `Dict_pass.collect_arities` keys arity
  by **bare name**, so a genuinely-constrained function in one module forces
  spurious leading dict params onto an *unconstrained same-named* function in
  another → its call site under-applies → an un-run partial closure (clean exit,
  no output). Two traps that hid it: (1) `module_debug` mirrors that joint
  dict-pass for its flat path too, so both drivers behaved identically — **"no
  divergence" does NOT exonerate dict-passing**; (2) the printer renders
  `EDictApp`/`EMethodRef` transparently as the bare name, so the dict-passed dump
  *looks* clean. What nailed it: instrument eval's `EVar`/`EMethodRef`/`EDictApp`
  arms to see how the name *actually* resolves (Phase 134 was a secret `EDictApp`
  with `routes=None arity=3`). Corollary (unchanged): because single-file masks
  these, the regression test must go in `test_loader` (drives `eval_modules`),
  never `test_run`/doctest.
- Development is organized by numbered **Phases**. Open/forward work is in
  `PLAN.md`; the completed Phases 1–97 (with implementation notes) are in
  `PLAN-ARCHIVE.md`. Commit messages and code comments reference phase numbers.
- **Match-arm guards (`match … pat if guard => body`) now lower natively (`CTGuard` CLOSED, 2026-06-08); refutable pattern-guards (`p <- e`) do NOT yet.** Historically the native emitter could not lower a guard — `emitTree`'s `CTGuard` arm gapped, silently blanking the body to `0` under the gap-tolerant self-compile build (this bit `llvm_emit.mdk`'s own source at self-compile step C1). `emitTree` now emits a real guard test + branch (`emitGuardedArm`/`emitGuardChain`), so `CGBool` guards and irrefutable `CGBind` (`x <- e`) work; a **refutable** `CGBind` (`Just x <- e`) is still a contained gap. So: `match pat if cond => …` is fine on the self-compile path; avoid `Pat <- e` pattern-guards with a *refutable* `Pat`. (Function-clause guards `f p | g = …` always worked — they desugar to if-chains, not `CTGuard`.) Fixtures: `test/llvm_fixtures/guard_match_{chain,ctor}.mdk`.

## Dogfooding the language

The stdlib and `selfhost/` are written *in* Medaka, so prefer its idioms. A
handful of constructs parse and work but are **under-used** — when you touch
nearby code, consider them, but **only where they genuinely improve
readability**. Don't force-fit: most candidate sites aren't improvements, and a
rewrite that doesn't typecheck or that changes semantics is worse than the
original. **Verify the rewrite on the binary** (`medaka test <file>`) — a
plausible-looking change here is often wrong (e.g. `function` only applies when
the body matches the *bare last param*, not `match (g param)`; a comprehension
desugars over `List`, so `map` over an `Option`/`Array` won't convert).

- **Operator sections** — `(==)`, `(+ 1)`, `(2 * _)` (left needs explicit `_`)
  instead of `(x y => x == y)` / `(x => x + 1)` lambdas.
- **List comprehensions** — `[f x | x <- xs, p x]` *only* when there's a guard
  or a destructuring lambda to remove; a plain `map f xs` already beats
  `[f x | x <- xs]`.
- **`function` keyword** — point-free match, only when the body is
  `match <lastParam>` on the bare final argument.
- Pipe `|>` / compose `>> <<`, inclusive ranges `[lo..=hi]`, record update
  `{ r | f = v }`, `let mut`, unary `!`, backtick infix `` `f` ``.

`SYNTAX.md` is the ground-truth list of what parses; `test/parse_fixtures/rare_constructs.mdk`
has minimal examples. The self-hosted parser doesn't cover all of these yet —
see PLAN.md "Known parser gaps" before assuming `selfhost/` can parse one.

## Writing tests

alcotest-based. Tests are self-diagnosing: embed the source under test in the
assertion so failures are readable. Add cases to the suite matching the stage
you changed (e.g. parser change → `test/test_parser.ml`).

## Task playbooks (skills)

For recurring multi-file tasks, load the matching skill rather than
re-deriving the workflow. **Skills are planning inputs, not just
implementation aids** — at task triage (including during plan-mode
exploration, *before* writing the plan) match the task against this table and
load the matching skill. A roadmap/Phase task is the cue: confirm where the
fix lands, then load. (A `UserPromptSubmit` hook,
`.claude/hooks/skill-triage.py`, nudges this on PLAN.md/Phase prompts.)

- **add-language-feature** — thread a new construct through the whole pipeline.
- **add-primitive** — add/modify a stdlib `extern` primitive (native, in `eval.ml`).
- **extend-stdlib** — implement/extend a *pure-Medaka* stdlib function, impl,
  doctest, or prop in `stdlib/{core,list,string,array}.mdk` (per STDLIB.md). Not
  for externs — that's add-primitive. Normally user-reserved; load when asked.
- **debug-pipeline** — diagnose a parse/typecheck/eval failure. **Reach here
  first for a dispatch bug that reproduces through the loader but works
  single-file** (Phases 96/103/121/125): that shape is *usually* an `eval.ml`
  ordering bug, not the dict-passing machinery a PLAN entry may name. But confirm
  empirically — Phase 134 was the inverse (loader-only AND dict-passing: the
  *joint* dict-pass conflating same-named cross-module fns), and `module_debug`
  did not flag it. See Gotchas for the full counterexample and the
  instrument-eval's-resolution-arms technique.
- **add-lsp-capability** — add/extend an LSP feature.
- **harden-typechecker** — typechecker-*internal* correctness/diagnostics work
  (much of the Phase 62–72 arc): add a `type_error`, tighten constraint/
  coherence/unification logic, without breaking error accumulation or level
  bracketing. Note: not every typechecker-flavored Phase item lives *only* in
  the typechecker — and adding a `type_error` does NOT by itself make a task
  this skill. Cross-cutting work is **add-language-feature** instead:
  - Phase 69 dispatch / 69.x dictionary passing — touches resolve/typecheck/eval
    + a marker pass.
  - Phase 63 — `desugar.ml`-rooted (`deriving` for parametric types).
  - Phase 72 (done) — field-name reuse / receiver-directed resolution: added the
    `AmbiguousField` `type_error` but the bulk was a `field_owners` multimap
    threaded through *both* `resolve.ml` and `typecheck.ml`. Looked like harden;
    wasn't.
  - Phase 73 (TODO) — signature-driven parameter typing (bidirectional checking):
    pure inference work, yet a delicate cross-cutting change to the letrec-group
    path, so add-language-feature.
  - Phase 83/84 dict-threading (e.g. instance-`requires` dicts into return-position
    impl bodies) — feels like typechecker-internal dispatch work, but a route
    threads through `ast.ml` (resolved record) + `typecheck.ml` + `dict_pass.ml` +
    `eval.ml` together, so add-language-feature. Gotchas: register dict-route
    var-ids *after* inference (unify picks the surviving id); gate to
    return-position methods (arg-position stay on arg-tag); the flat impl-key dict
    can't carry nested dicts.
  Check where the fix actually lands before loading this skill.

## Doc index

| Doc | What's in it |
|-----|--------------|
| `README.md` | Full build/test/CLI usage, editor setup, layout |
| `SYNTAX.md` | Terse cheat-sheet of every construct the **current binary** accepts (one verified example each). Reach here first for "what syntax exists / does X parse" — faster than reading `parser.mly`. Ground truth over `language-design.md` when they disagree |
| `language-design.md` | Language design & semantics (intent/rationale — may describe unimplemented features) |
| `PLAN.md` | Forward-looking roadmap (open phases) |
| `PLAN-ARCHIVE.md` | Completed Phases 1–97 + per-phase implementation notes |
| `STDLIB.md` | Stdlib module plan |
| `stdlib/README.md` | Conventions for adding extern primitives |
| `selfhost/BOOTSTRAP.md` | Native self-compile log: B1–B7 (each stage native==interpreter) + C1–C3 (emitter self-compile fixpoint), with the emitter bugs fixed per slice |
| `selfhost/EMITTER-GAPS.md` | Native emitter gap census — closed gaps (E-series) + residual capability gaps (refutable pattern-guards). **IN PROGRESS 2026-06-14:** a mixed-nullary/payload-ADT `match` field mis-extraction (compiled output faults where `medaka run` is correct) — surfaced by the now-native fuzzer (`fuzz_diff.sh` Tier-1), being root-caused + fixed. |
| `selfhost/DISPATCH-GAPS-SCOPE.md` | Repro-verified scope of the 4 native dispatch gaps (#54 Map `toList` / #55 sum-product / #50 parametric-Ord / #21 nested route flattening): minimal repro + root cause + fix-location per gap. **ALL FOUR NOW CLOSED** (#54 2026-06-11; #50; #55 2026-06-11 build + 2026-06-13 eval path; #21 2026-06-14 — gated binop element-reqs on `argStampEnabled`, removed the `suppressBinopStamp` workaround). The deeper root — the `argStampEnabled` eval-vs-emit fork these shared — is being retired by `selfhost/ARGSTAMP-UNIFY-PLAN.md`. |
| `selfhost/PERF-SCOPE.md` | Bar-4 performance scoping: every `clang` invocation + the one-line `-O2` enable, why `-O2` is fixpoint-safe (text IR is pre-clang), benchmark-harness plan, ranked hot paths (2234 `alloca`→`mem2reg`, GC alloc density), sequenced session steps |
| `selfhost/PERF-RESULTS.md` | **Bar-4 EXECUTED (2026-06-11), extended session 2 (2026-06-14).** Measured log of the perf wins: self-compile **12.04 s → ~1.72 s (~7×); ~73× vs the OCaml interpreter**. Session 1 (18 wins): `-O2` + GC `free_space_divisor=1` + O(N²)→O(N·log N) SMap/EMap membership/index fixes across DCE/typecheck/emit. Session 2 (3 wins, 2.57→1.72 s): two MISATTRIBUTED-symbol O(N²) sites session 1 missed — `scopeArities` (~23%) + `maybeInferConstraint` (~7.5%) membership→SMap — plus `GC_malloc_atomic` for pointer-free string cells (~3%). Reusable patterns (map the lam-id to source before trusting a filed hotspot; verify by wall-clock not sample count), every dead-end, and the supervised-only remaining levers (threaded float-augmented sig tree, GC allocation density). Harness: `test/bench.sh` |
| `selfhost/STAGE2-DESIGN.md` / `selfhost/RUNTIME-DESIGN.md` | Native backend design: Core IR seam, value rep, GC, per-extern disposition |
| `selfhost/README.md` | Self-host port slice log + roadmap |
| `selfhost/REROOT-PLAN.md` | The plan that took every differential gate OCaml-free (DONE 2026-06-13): gate categories (HOST/eval-probe-oracle/front-end/build), golden-capture infra, native-interp oracle, phasing. |
| `selfhost/DRIVER-COLLAPSE-PLAN.md` | The plan that folded single-file typecheck+eval into the 1-module case of the multi-module path (DONE 2026-06-13, closes audit §6): 5 phases (scaffold→test→dict→eval→check→delete), `check`-option-A (resolves imports), risk register. |
| `selfhost/ARGSTAMP-UNIFY-PLAN.md` | The approved plan (2026-06-14, IN PROGRESS) to retire the `argStampEnabled` eval-vs-emit dispatch fork (the finer split the driver collapse left; shared root of #55/#21): flip eval to full dict-threading, arg-tag survives only for the irreducible primitive residual; 6 phases, fork inventory, arg-tag dependency map. |
