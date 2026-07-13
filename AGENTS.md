# AGENTS.md

Orientation for AI agents working on **Medaka**, a pragmatic functional
language that self-hosts: the compiler is written in Medaka in `compiler/` and
compiles via an LLVM backend (`compiler/backend/llvm_emit.mdk` → text IR →
`clang`; C runtime `runtime/medaka_rt.c` + Boehm GC) to a native OCaml-free
`medaka` binary. This file is a *router*: maps, gotchas, and links. For prose
and rationale, follow the links — don't assume detail that isn't here.

`compiler/` is organized into subfolders: `frontend/` (lex/parse/AST/desugar/
resolve/marker/exhaust), `types/` (typecheck + annotate), `ir/` (Core IR, DCE,
S-expr), `backend/` (LLVM + WasmGC emit, TRMC, name mangling), `eval/` (tree-walk
interpreter), `driver/` (loader, diagnostics, build, CLI), `tools/` (fmt/printer/
LSP/test/repl/doc/new), `support/` (compiler private mini-stdlib: util/ordmap/
char/path/timer), `entries/` (per-stage probe entry points), `seed/` (checked-in
LLVM IR seed for cold bootstrap). The compiler source is ONE Medaka project
(`compiler/medaka.toml`); each stage is one `.mdk` file under its subfolder.

> **Medaka self-hosts to a reproducing fixpoint.** The whole pipeline is written
> in Medaka (`compiler/*.mdk`) and compiles via a native **LLVM backend**
> (`compiler/backend/llvm_emit.mdk` → text IR → `clang`; C runtime
> `runtime/medaka_rt.c` + Boehm GC) to an OCaml-free `medaka` binary. As of
> 2026-06-12 the native `medaka` is CANONICAL (`make medaka` builds it OCaml-free
> from a checked-in IR seed). **As of 2026-06-26 the OCaml reference compiler
> (`lib/`+`bin/`+`gen/`+`dev/`) is REMOVED** — tag `oracle-frozen` preserves the
> last lib/-present commit; native is the sole compiler.
>
> Key docs: `compiler/BOOTSTRAP.md` (B1–B7 + C1–C3 bootstrap log),
> `compiler/EMITTER-GAPS.md` (closed/residual emitter gaps),
> `compiler/DISPATCH-GAPS-SCOPE.md` (all four native dispatch gaps #54/#55/#50/#21
> now CLOSED), `compiler/PERF-RESULTS.md` (bar-4 perf: self-compile ~7× faster,
> ~73× vs the old interpreter; harness `test/bench.sh`),
> `compiler/STAGE2-DESIGN.md` + `compiler/RUNTIME-DESIGN.md` (design),
> `compiler/README.md` (slice log). Harnesses: `test/bootstrap_*.sh` (each
> native stage == interpreter output), `test/selfcompile_fixpoint.sh` (emitter
> self-compile fixpoint C3a/C3b).

## Pipeline — where each stage lives

**Execution order** (driven by `compiler/driver/medaka_cli.mdk` — *not* the
order files are listed):

```
lexer.mdk → parser.mdk → ast.mdk → desugar.mdk → resolve.mdk → marker.mdk
  → typecheck.mdk (runs exhaust.mdk internally) → eval.mdk
  [all in compiler/frontend/ except typecheck.mdk (compiler/types/) and eval.mdk (compiler/eval/)]
```

Two non-obvious facts that bite when deciding *where* a check belongs:
- **`desugar.mdk` runs first**, before resolve/typecheck. So surface-sugar nodes
  (`EGuards`, `EFunction`, `ESection`, string interp) are
  **already lowered to core** by the time typecheck/exhaust/eval see the tree. A
  check that needs the sugar shape (e.g. guard *coverage* on `EGuards`) cannot
  live in typecheck/exhaust — it must run pre-desugar (see `checkGuardExhaust`
  in `compiler/frontend/exhaust.mdk`, a standalone pass on the raw AST).
- **`exhaust.mdk` is not a standalone later stage** — `checkMatch` is
  *called from inside* `compiler/types/typecheck.mdk` (once per `EMatch`, with
  the scrutinee type known). It only ever sees core patterns.

| Stage | File | Role |
|-------|------|------|
| Lex | `compiler/frontend/lexer.mdk` | Indentation-sensitive; emits INDENT/DEDENT/NEWLINE |
| Parse | `compiler/frontend/parser.mdk` | Recursive-descent grammar |
| AST | `compiler/frontend/ast.mdk` | Node types + source locations |
| Desugar | `compiler/frontend/desugar.mdk` | Runs FIRST. Lowers surface sugar: `deriving`, record puns, `EGuards`/`EFunction`/`ESection`/string-interp, `EDo` (do-blocks → nested `andThen`/`pure`), default-method specialization |
| Resolve | `compiler/frontend/resolve.mdk` | Name binding, single- and multi-module |
| Mark | `compiler/frontend/marker.mdk` | Runs after desugar+resolve, before typecheck. Rewrites interface-method `EVar`→`EMethodRef` so typecheck can stamp the resolved impl key per call site and eval routes return-position/multi-param dispatch by it |
| Typecheck | `compiler/types/typecheck.mdk` | Hindley-Milner + interfaces + effects; invokes Exhaust per `EMatch` |
| Exhaust | `compiler/frontend/exhaust.mdk` | Maranget pattern-matrix algorithm; called *from* typecheck, not standalone |
| Eval | `compiler/eval/eval.mdk` | Tree-walking interpreter; dict-passing typeclass dispatch |

Support files:

| File | Role |
|------|------|
| `compiler/driver/loader.mdk` | Multi-file dependency walk, topo sort, cycle detection; `medaka.toml` project-root walk-up |
| `compiler/driver/diagnostics.mdk` | Accumulating error pipeline — phases collect errors, no exit-on-error |
| `compiler/tools/printer.mdk` / `compiler/tools/fmt.mdk` | AST→source round-trip / comment-preserving formatter |
| `compiler/tools/lsp.mdk` | LSP over stdio: diagnostics, formatting, symbols, hover, definition, highlight, completion, inlay hints |
| `compiler/tools/doctest.mdk` | Extracts + runs doctests for `medaka test`. Two paths (Phase 92): import-bearing files → multi-module typecheck chain; prelude-only files → single-file path with arg-tag fallback. Single-file fallback is deliberate: the multi-module path's `marked_prelude` would coalesce a redefined prelude standalone (e.g. `string.mdk`'s `count`) and ERROR every example at once |
| `compiler/tools/doc.mdk` | `medaka doc` — doc-comment→Markdown extractor |
| `compiler/tools/new_cmd.mdk` | `medaka new` — project scaffolder |
| `compiler/tools/repl.mdk` | `medaka repl` — interactive REPL |
| `compiler/tools/check.mdk` / `compiler/tools/check_policy.mdk` | `medaka check` type-check entry + policy checker |
| `compiler/tools/lint.mdk` | `medaka lint` — modular AST linter. Runs on the RAW pre-desugar AST (mirrors `checkGuardExhaustiveness`). Per-file `Rule` registry + cross-file `CrossFileRule` registry (add a rule = one fn + one list entry); `--fix` autofix; ESLint-style severity + `--deny`/`--disable`/`--only`; files/dir/`medaka.toml`-project targets, recursive |
| `compiler/tools/test_cmd.mdk` / `compiler/tools/prop_runner.mdk` | `medaka test` — doctests + property tests |
| `compiler/driver/build_cmd.mdk` | `medaka build` — Core IR lower → LLVM emit → clang |
| `compiler/driver/medaka_cli.mdk` | CLI entry point: all subcommands (`check`/`fmt`/`new`/`build`/`run`/`test`/`doc`/`lint`/`manifest`/`repl`/`lsp`) |
| `compiler/ir/core_ir.mdk` + siblings | Core IR type definitions, lowering (`core_ir_lower.mdk`), S-expr (`core_ir_sexp.mdk`), DCE (`dce.mdk`) |
| `compiler/backend/llvm_emit.mdk` | LLVM text IR emitter |
| `compiler/backend/wasm_emit.mdk` | WasmGC text IR emitter (2nd backend) |
| `compiler/backend/private_mangle.mdk` | Universal constructor name mangling |
| `compiler/backend/trmc_analysis.mdk` | Tail-recursion-modulo-cons analysis |
| `compiler/types/annotate.mdk` | Type annotation helpers |
| `compiler/support/util.mdk` + siblings | Compiler helpers — private mini-stdlib + thin wrappers over `stdlib/` (e.g. `ordmap` wraps stdlib `Map`); stdlib imports are now allowed, weighed per module (see Gotchas) |

`stdlib/`: `runtime.mdk` (extern primitive catalog, read from disk at runtime), `core.mdk`
(implicit prelude — `Eq`/`Ord`/`Debug`/`Num`/…), `list.mdk`/`string.mdk`/`array.mdk`/`map.mdk`/`set.mdk`/`io.mdk`/`hash_map.mdk`/`hash_set.mdk`/`mut_array.mdk`/`json.mdk`/`byteparser.mdk`/`bytebuilder.mdk`
(written in Medaka; `map.mdk`/`set.mdk` are weight-balanced ordered `Map`/`Set`;
`hash_map.mdk`/`hash_set.mdk` are mutable hash tables; `mut_array.mdk` is a
growable mutable vector (amortized-O(1) `push` over a doubling `Array`); `json.mdk`
is a recursive-descent JSON parser/serializer with an `Array`-backed `Json` ADT;
`byteparser.mdk` is a generic binary parser-combinator library (`ByteParser`,
big-endian `beUint`/`beSint`/`beFloat64`) and `bytebuilder.mdk` its symmetric
byte-output builder (`emit*`/`buildArray`); neither is auto-prelude — import them
by bare name like `import map`;
`io.mdk` is the ergonomic layer over the `runtime.mdk` IO externs).

## Build & test

```sh
make medaka     # WARM (./medaka_emitter present): 2-stage rebuild from current source.
                # COLD (fresh clone): bootstraps emitter from compiler/seed/emitter.ll.gz first.
                # Equivalent scripts: test/build_native_medaka.sh (warm), test/bootstrap_from_seed.sh (cold)
./medaka run yourfile.mdk
```

**Where you're running (2026-07-13).** Primary dev is a **dedicated x86_64 Linux box** (Debian 13
trixie, 12 EPYC cores / 32 GB; repo at `/root/medaka`). Build straight on it — `make medaka`, then
the gate suite. No container, no VM, no wrapper: run everything natively and in parallel. This box
is the machine every number and every instruction in this file assumes.

The **Mac is retained for macOS smoke-testing only** (there is no macOS alternative), so the
**dual-platform invariant still holds: every build/test script must run on BOTH Linux and macOS.**
When you touch a script, keep both arms alive — `stat -c %Y` *or* `stat -f %m`, `pkg-config`/system
`-lgc` *or* `brew --prefix bdw-gc`, and no Mach-O-only link flags. Linux is the default arm now (it
is what CI-of-record and every agent runs); macOS is the fallback arm, but it is not optional.

Two platform facts worth knowing rather than rediscovering: the emitted LLVM IR carries **no target
triple**, so the checked-in seed (`compiler/seed/emitter.ll.gz`) cold-bootstraps on x86 *or* arm from
the same bytes (the C3a fixpoint reproduces byte-for-byte on both); and the deeply-recursive compiler
gets its stack from a **256 MB GC-aware worker pthread** spawned in `runtime/medaka_rt.c`, not from a
link flag — so it runs fine under Linux's default 8 MB `ulimit -s`.

*Historical:* `scripts/docker-dev.sh` + `docker/` exist to run the build inside a Linux container,
because the old macOS work laptop ran a DLP/endpoint scanner (Cyberhaven) that turned the gate
suite's write storm into a 6.5×-idle host CPU spike. **That problem does not exist on this box — do
not reach for the Docker wrapper.** It is kept only in case the Mac ever has to run a full suite.

**Debugging a `.mdk` program — reach for structured diagnostics.** `medaka check <file>` prints
human `file:L:C:` diagnostics with a caret; **`medaka check --json <file>`** (note: `--json`, not
`--format=json`) emits machine-parseable JSON — one object per diagnostic carrying a stable
**`code`** (per-stage prefix: `T-*` type · `R-*` resolve · `P-*` parse · `L-*` lex · `W-*` warning),
a **`kind`**, a real **`range`** (0-based LSP line/char; warnings included — no longer a `{0,0}`
dummy), **`severity`** (1=error, 2=warning), the **`message`**, and — for suggestion-bearing errors
— a **`help`** string plus a machine-applicable **`fix { range, replacement }`** you can apply
verbatim (e.g. an unbound-name typo yields the nearest in-scope name as a `fix`). When
programmatically reacting to compile errors, prefer `--json` and key off `code` (it's the stable
handle — it doesn't move when wording changes). When WRITING a new diagnostic, follow
`compiler/ERROR-QUALITY.md` (the rubric + copy standard — located, names the rule, actionable fix,
carries a code) and add the code to the taxonomy in `compiler/DIAGNOSTIC-CODES-DESIGN.md`.

Correctness gates (all shell-based, golden-diff style):

```sh
sh test/run_gates.sh                    # run the WHOLE diff_compiler_* suite in PARALLEL (~32s)
bash test/diff_compiler_*.sh           # differential: native output vs captured goldens (~67 suites)
bash test/selfcompile_fixpoint.sh      # emitter self-compile fixpoint (C3a/C3b)
bash test/typecheck_compiler_source.sh # strict-typecheck the WHOLE compiler source (~4min); run
                                       #   alongside the fixpoint for compiler .mdk changes — the
                                       #   bootstrap emit path does NOT gate on hadTypeErrors(), so
                                       #   an ill-typed compiler source builds green without this
bash test/bootstrap_*.sh              # each native pipeline stage == interpreter output
FORCE=1 bash test/build_oracles.sh    # force-rebuild oracles (parallel; always FORCE=1 — stale-prone)
sh test/check_removed_constructs.sh   # tree-wide scan (incl. non-gated test/) for stale uses of
                                       #   removed constructs (record/function/backtick/let-mut/
                                       #   let-else/named-impl/@Name/default-impl); ~2-3min, JOBS= knob
```

**Parallelism (2026-07-02).** `build_oracles.sh`, `run_gates.sh`, the heavy compiler
gates (`diff_compiler_{llvm,build,llvm_typed}`), and every wasm gate
(`test/wasm/diff_{wasm,wasm_typed,wasm_modules,sqlite}.sh`) fan work across an
`xargs -P` pool — cap with `JOBS=n` (build_oracles/individual gates) or
`INNER_JOBS=n` (per-gate fan-out inside `run_gates.sh`). Oracle build **327s→34s**,
full suite **125s→~32s**. Perf **env knobs** (all preserve byte-identical output —
opt level/heap size never change emitted IR): `EMITTER_OPT` (emitter clang opt,
default **-O2** — it's the reused workhorse), `ORACLE_OPT` (oracle clang, default
**-O0** — throwaway binaries, gate runtime hidden by parallelism), `CLI_OPT`
(`medaka` CLI clang, default -O0; `CLI_OPT=-O2 make medaka` → ~2× faster
`run`/`test`/`check` interpreter, at +~4s on make medaka), `WASM_ORACLE_OPT`
(default -O2 — **-O0 overflows the deep-TCO fixtures**), `GC_INITIAL_HEAP_SIZE`
(large heap defers Boehm collections ~30% on SERIAL emits — set for make medaka +
fixpoint; NOT the parallel oracle build, where 10× the RSS causes pressure). See
`compiler/PERF-RESULTS.md`.

⚠️ **When parallelizing a gate that shells to `medaka build`, watch for same-named
inputs** (e.g. multiple `entry.mdk`): `build_cmd.mdk` keys its temp IR on the
OUTPUT path (fixed 2026-07-02) so concurrent builds are race-safe, but ALWAYS run a
newly-parallelized gate several times — a temp-collision flake only shows ~1 in N.

**In a `.claude/worktrees/<name>` worktree:** `make medaka` works from the worktree
root. Since the shell cwd resets between calls, use `make -C /absolute/path/to/worktree medaka`
or `cd` to the worktree root. The `./medaka` binary is written to the worktree directory.

**Note on stale oracles:** `diff_native_cli` and the bootstrap suites are especially
stale-prone. Always force-rebuild (`FORCE=1 bash test/build_oracles.sh`) before trusting
a pass/fail result from those gates.

**Fmt + lint pre-commit hook (ACTIVE, 2026-07-01).** A pre-commit hook (`.githooks/pre-commit`,
installed at `$(git rev-parse --git-common-dir)/hooks/pre-commit`) runs TWO checks over each
staged `.mdk` (`test/` fixtures excluded from both — intentionally unformatted golden inputs
that often violate style rules on purpose):
- **Format** — `medaka fmt --check` **rejects any staged unformatted `.mdk`**. The whole tree is
  `medaka fmt`-clean. **Run `medaka fmt --write <changed.mdk>` and re-`git add` before committing
  any `.mdk` edit.** `medaka fmt` is safe (0 corruptions / 0 non-idempotent repo-wide) and
  idempotent, so `fmt --write` on a clean file is a no-op.
- **Lint** — **the whole tree is at 0 `medaka lint` findings, and the hook is a MAX RATCHET: ALL
  ~20 rules are gated, so any NEW finding of any rule (style OR correctness) fails the commit.** The
  19 per-file rules (`GATED_LINT_RULES` in `.githooks/pre-commit`: match-on-param, lambda-section,
  if-max-min, match-to-map, not-eq, missing-signature, dead-code, concat-to-interp, … — the full
  `allRules` set) run `medaka lint --only=<rules> --deny=<rules>` on each staged `.mdk`. The
  cross-file rule `rule-duplicate-body` compares a body against OTHER files, so it can't be checked
  per-staged-file — the hook runs **one whole-project scan over all source roots** (`medaka lint
  compiler stdlib sqlite`) when any `.mdk` is staged, so cross-ROOT duplicates are caught too.
  **So: `medaka lint` must stay clean on ALL rules — run it on files you touch and fix or
  `-- lint-disable` any finding before committing.** (A gated rule that proves too noisy can be
  dropped from `GATED_LINT_RULES`; it then still warns under plain `medaka lint`.)
  A genuine intentional exception is silenced inline with an ESLint-style directive comment (these
  work for per-file AND cross-file rules): `-- lint-disable-next-line <rule>` (also
  `-- lint-disable-line <rule>` trailing, and `-- lint-disable-file <rule>` for the whole file;
  omit the rule name to disable all rules). ⚠️ `medaka lint --fix` autofixes
  `rule-match-on-param`/`rule-bind-then-destructure` but **bails on any decl containing an interior
  comment** (it would otherwise drop them) — safe, but it leaves comment-bearing sites unfixed.

Emergency bypass for either check: `git commit --no-verify`. If `medaka` isn't built the hook
warns-and-allows. Re-install after a fresh clone by copying `.githooks/pre-commit` into the hooks
dir (`cp .githooks/pre-commit "$(git rev-parse --git-common-dir)/hooks/pre-commit"`).

**Playground e2e (real-browser harness).** `playground/e2e/` is a Playwright harness that drives a
real browser against the built CM6 playground — verifies CM6 mounts, syntax highlighting, running
a program (`#run-btn` → `#stdout`), and inline type-error squiggles/gutter markers/`#problems`
pane, as opposed to the headless-logic tests (`playground/tokenizer_test.mjs`,
`playground/squiggle_test.mjs`). Run: `cd playground/e2e && ./run.sh` (screenshots land in
`playground/e2e/screenshots/`, gitignored). Requirements/gotchas: needs **node v24+** (system v20
can't run finalized WasmGC) and `playground/dist/playground.wasm` already built (`bash
playground/build_playground_wasm.sh` — the harness never builds it); launches
`chromium.launch({channel:'chrome'})` — the **system** Google Chrome, not a Playwright-downloaded
browser, because `npx playwright install` TLS-fails on this machine (do not try to bypass TLS
verification to fix that). See `playground/e2e/README.md` for the full list.

## Gotchas

- **Tuples are internally `__tupleN__`-headed `TApp` spines, not a `TTuple` node** (shipped 2026-07-02, `compiler/TUPLE-TYPE-CONSTRUCTOR-DESIGN.md`). `(,)`/`(,,)`/`(,,,)`/`(,,,,)` surface syntax (arities 2-5) in TYPE position names the bare *unsaturated* tuple constructor, which is what lets a higher-kinded typeclass bind to it (`impl Bimappable (,)` in `core.mdk`) — a saturated `(a, b)` head is kind-inconsistent with the rest of the language and deliberately not supported. Also part of this arc: the emitter's opaque application path now carries callable arity in the closure cell header and routes non-matching-arity calls through a runtime `mdk_apply` (fixed a wrapped-PAP-then-saturate SIGSEGV that blocked `map2`/`map3`). (A cross-module sibling-impl-emit gap suspected during this arc was verified CLOSED 2026-07-02 — non-reproducing on current main, now build-guarded; see `compiler/EMITTER-GAPS.md`.)
- **The compiler (`compiler/*.mdk`) MAY import `stdlib/` — deliberately, per module (policy changed 2026-06-29).** The old blanket "NEVER import stdlib" rule
  was retired after a measurement spike: `import` from compiler code resolves fine
  (the build already passes the stdlib root to the emitter — `build_native_medaka.sh`
  passes `$STDLIB`), and the cost of pulling stdlib `map`'s whole instance surface
  into the compiler is small (**~+34 KB binary, ~+5% self-compile**). So the
  long-feared blocker (monomorphization / instance-level DCE) was never actually a
  blocker; it was a cost decision, and the cost is low. First migration step:
  `support/ordmap.mdk` now wraps stdlib `Map` (`59f0545`), retiring the duplicate
  weight-balanced tree. Prefer reusing stdlib over hand-rolling/duplicating in
  `support/` where it's a clear win (kills divergence between `support/` and
  `stdlib/`); `support/` remains for genuinely compiler-private helpers.
  - **The cost is real but low — weigh it per module, don't import reflexively.**
    (1) **Un-prunable instance surface — but ONLY for a module that defines a NEW
    type.** DCE keeps every `DImpl`/`DInterface` *whole* (runtime dict-passing →
    pruning an impl would be a silent miscompile). Measured rule (steps 1+2,
    2026-06-29/30): `import map` introduced a *new type* `Map` → its whole
    Eq/Ord/Debug/Display/Mappable/Monoid surface came in (**+34 KB / +4.8%
    self-compile**). But `import list`/`import string` drag **no new instance
    surface** — List/String instances live in `core` (the always-present prelude),
    so DCE trims to just the referenced standalone fns (`reverse`/`zip`/`join`):
    **−256 B, +2% (noise)**. So: importing a stdlib module whose types' instances
    are core-defined is **near-free**; importing one that defines a new type is not.
    ⚠️ **Anti-pattern (measured): do NOT delegate the compiler's hot monomorphic
    helpers to prelude Foldable methods** (`elem`/`any`/`all`/`length`) — they lose
    `||`/`&&` short-circuiting and become dict-passed fold+closure; doing this to
    `util.mdk`'s hottest helpers cost **+56% self-compile**. Keep hot inner-loop
    helpers monomorphic + short-circuiting; the cross-file dedup should fold dups
    into util's FAST helpers, not the prelude methods. (2) **Compile-time tax** — the
    imported module is lexed/parsed/typechecked on every compile + every
    self-compile/fixpoint iteration. (3) **Bidirectional coupling** — once the
    compiler imports a stdlib module, a change to that module that perturbs emitted
    IR forces a **seed re-mint + fixpoint re-validation**. This is a *feature* (it
    converts silent `support/`-vs-`stdlib/` divergence into a build-time gate) but
    it is more re-mint churn on stdlib work. Instance-level DCE via monomorphization
    (the deferred backend item) would shrink (1) but is **not** needed for this.
  - **Gotchas when migrating a `support/` structure to stdlib** (learned on ordmap):
    a polymorphic empty must be a **nullary constructor** (a constructor
    *application* like `OMap Tip` is NOT generalized by this typechecker → it
    monomorphises to `…Unit` → "Scheme vs Unit" cascades); **type aliases NOW
    expand transparently** (`type X = Y`, parameterized `type Pair a = (a,a)`, and
    `export type` across modules — landed 2026-06-30, `compiler/TYPE-ALIAS-EXPANSION-DESIGN.md`;
    cyclic/recursive aliases are rejected) so a `data`-wrap is **no longer required**
    just to alias a type (it WAS, hence the original `data OrdMap` wrapper); and any
    **test harness that runs the emitter/probes over compiler source with only the
    compiler root must also pass `$STDLIB`** (already fixed: `selfcompile_fixpoint`,
    `diff_compiler_{selfproc,check_modules,check_modules_batch,resolve_modules}`,
    `profile_compiler`).
- **Environment.** opam/dune are NOT needed — the native build uses only **clang + Boehm GC**. On this
  box (Debian 13) that is `clang` 19 and the system `libgc-dev` (`/usr/lib/x86_64-linux-gnu/libgc.so`,
  found via plain `-lgc`); on macOS it is Apple clang + `brew install bdw-gc`. `node` ≥ 24 is needed
  only for the wasm/sqlite/playground gates (present here; a system node 20 cannot run finalized
  WasmGC). If clang or libgc is missing, install it from the system package manager — don't vendor it.
- **In a worktree, build with `make -C /absolute/path/to/worktree medaka`.** The shell cwd resets to the main checkout root each call; running `make medaka` from there would build in main, not the worktree.
- **In a worktree, edit the worktree's files — use the full worktree path.**
  The shell cwd resets to the main checkout root each call, so a relative
  `grep -n compiler/foo.mdk` runs there and prints `compiler/foo.mdk:NN`; Read/Edit that
  bare path and you've silently changed the **main checkout**,
  which the worktree build never sees (and which dirties `git status` in main). Always
  target `/…/.claude/worktrees/<name>/compiler/foo.mdk`. If you slip: `cp` the edited
  files into the worktree, then `git -C <main> checkout -- <files>` to restore
  main.
- **Medaka multi-arg lambdas are `x y => body`**, not curried
  `x => y => body`. Curried forms predating Phase 59.6 are legacy artifacts,
  not the current style — match the `x y => body` form in new code.
- **Errors accumulate.** Phases push into `compiler/driver/diagnostics.mdk` rather than raising
  on the first error; don't add early exit/raise paths.
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
  through the typed pipeline.
- **A dispatch bug that reproduces through the loader but is a green single-file
  doctest is *usually* the EVAL DRIVER, not typecheck/dict-passing** — even when a
  PLAN entry says otherwise. This shape recurred at Phases 96, 103, 121, and 125,
  where the filed root cause blamed dict-passing and was wrong. Why the split
  exists: single-file `eval_program` merges everything into one by-name frame and
  forces deferred thunks only after every impl is installed; the loader's
  `eval_modules` uses per-module frames and a separate prelude/Phase-B install
  order, so **binding-order and impl-install-order** bugs surface *only* there.
  Diagnose via native entry points in `compiler/entries/`: run
  `compiler/entries/eval_modules_main.mdk` (drives `eval_modules`, the loader
  path) and `compiler/entries/eval_typed_main.mdk` (the single-file path) on the
  same input — identical input but only the modules path errors ⇒ eval driver
  (fix in `compiler/eval/eval.mdk`).
  **But VERIFY empirically — this heuristic has a documented exception (Phase
  134), where a loader-only bug WAS dict-passing.** `eval_modules` dict-passes
  the prelude + all modules *jointly* and `Dict_pass.collect_arities` keys arity
  by **bare name**, so a genuinely-constrained function in one module forces
  spurious leading dict params onto an *unconstrained same-named* function in
  another → its call site under-applies → an un-run partial closure (clean exit,
  no output). Two traps that hid it: (1) running `eval_modules_main.mdk` vs
  `eval_typed_main.mdk` on the same input showed both behaving identically — **"no
  divergence" does NOT exonerate dict-passing**; (2) the printer renders
  `EDictApp`/`EMethodRef` transparently as the bare name, so the dict-passed dump
  *looks* clean. What nailed it: instrument eval's `EVar`/`EMethodRef`/`EDictApp`
  arms to see how the name *actually* resolves (Phase 134 was a secret `EDictApp`
  with `routes=None arity=3`). Corollary (unchanged): because single-file masks
  these, the regression test must exercise the multi-module path
  (`diff_compiler_eval_modules.sh` drives `eval_modules`), not a single-file doctest.
- **`evalModules` (`eval/eval.mdk`) and `cevalModules` (`ir/core_ir_eval.mdk`) are PARALLEL
  module drivers — fix module-frame semantics in LOCKSTEP.** `cevalModules` is a deliberate
  structural mirror of `evalModules`: same frame layout, same `importFrameOf`/`pubReexports`/
  `installConsts` helpers. So any fix to module-frame *semantics* (ctor scoping, impl coalescing,
  install order) applied to one is **silently absent from the other**. This is exactly how the
  P0-9 cross-module ctor-collision fix (`2b17677f`) shipped: it patched `eval.mdk` and left
  `core_ir_eval.mdk` broken for months (ported 2026-07-13). Note this is a *different* split from
  the loader-vs-single-file one above — same family, one more axis.
  - Underlying hazard, worth recognizing on sight: **`installConsts` + `findCell` is
    last-write-wins on duplicate names** (`findCell` returns the *first* matching cell while
    `installConsts` writes each entry in turn). Any flat frame keyed by **bare name** and built
    from multi-module decls inherits it — e.g. `map`'s arity-5 `Bin` vs `set`'s arity-4 `Bin`
    collapse into one cell, so a module constructs via the *other* module's arity, saturates
    early, and applies the surplus arg (`E-NOT-A-FUNCTION`). The fix shape is a per-module
    **local** ctor frame that shadows the global (the global stays, for `Type(..)` imports).
- ⚠️ **`test/eval_modules_fixtures/*/` is globbed by TWO gates** — `diff_compiler_eval_modules.sh`
  *and* `diff_compiler_core_ir_modules.sh`. Adding a regression fixture there silently enrolls it
  in the Core-IR gate too. P0-9 shipped "green" on `eval_modules 5/0` while leaving
  `core_ir_modules` red, because only the first gate was run. **When adding a fixture to a shared
  corpus, run every gate that globs it.**
- Development is organized by numbered **Phases**. Open/forward work is in
  `PLAN.md`; the completed Phases 1–97 (with implementation notes) are in
  `PLAN-ARCHIVE.md`. Commit messages and code comments reference phase numbers.
- **Match-arm guards (`match … pat if guard => body`) lower natively (`CTGuard` CLOSED, 2026-06-08); refutable pattern-guards (`Pat <- e`) work fully in both forms (native-resolve/typecheck guard-binder scoping fixed 2026-06-15).** Historically the native emitter could not lower a guard — `emitTree`'s `CTGuard` arm gapped, silently blanking the body to `0` under the gap-tolerant self-compile build (this bit `llvm_emit.mdk`'s own source at self-compile step C1). `emitTree` now emits a real guard test + branch (`emitGuardedArm`/`emitGuardChain`). Both refutable-guard forms now work, verified native==OCaml:
  - **Function-clause refutable guards** (`f n | Some v <- e = v`) — guard gating *and* the bound var scoping into the body. (They desugar to if-chains, not `CTGuard`.)
  - **Match-arm refutable guards** (`x if Some v <- e => body`) — gate correctly, bind scopes rightward into *later qualifiers* (`Some v <- e, v > 0`) **and into the arm body** (`=> v`). This last part was a native-only bug (the compiler `frontend/resolve.mdk` `checkArm` + `types/typecheck.mdk` `inferArm` did not thread the guard binder, so the body saw `UnboundVariable`). Fixed 2026-06-15 by threading the guard binders through later qualifiers and into the body — `medaka run` always evaluated it correctly, only `check` rejected it.
  Fixtures: `test/llvm_fixtures/guard_match_{chain,ctor}.mdk`.
- **For layout questions** (what indentation shapes are legal, leading-op set, then/else, tabs, let…in wrapping), `LAYOUT-SEMANTICS.md` is the ground truth. A lexer-vs-spec divergence is a lexer bug; a SYNTAX.md/PLAN.md-vs-spec divergence is a doc bug.

## Dogfooding the language

The stdlib and `compiler/` are written *in* Medaka, so prefer its idioms. A
handful of constructs parse and work but are **under-used** — when you touch
nearby code, consider them, but **only where they genuinely improve
readability**. Don't force-fit: most candidate sites aren't improvements, and a
rewrite that doesn't typecheck or that changes semantics is worse than the
original. **Verify the rewrite on the binary** (`medaka test <file>`) — a
plausible-looking change here is often wrong (e.g. `function` only applies when
the body matches the *bare last param*, not `match (g param)`).

- **Operator sections** — `(==)`, `(+ 1)`, `(2 * _)` (left needs explicit `_`)
  instead of `(x y => x == y)` / `(x => x + 1)` lambdas.
- **`function` keyword** — point-free match, only when the body is
  `match <lastParam>` on the bare final argument.
- Pipe `|>` / compose `>> <<`, inclusive ranges `[lo..=hi]`, record update
  `{ r | f = v }`, `let mut`, unary `!`, backtick infix `` `f` ``.

`SYNTAX.md` is the ground-truth list of what parses; `test/parse_fixtures/rare_constructs.mdk`
has minimal examples. The self-hosted parser doesn't cover all of these yet —
see PLAN.md "Known parser gaps" before assuming `compiler/` can parse one.

## Writing tests

Tests are shell-based golden-diff harnesses. Each `test/diff_compiler_*.sh`
runs a native pipeline stage against golden output files in
`test/*_fixtures/` or `test/*_goldens/`. To add a test:
1. Add a fixture file to the appropriate `test/` fixture directory.
2. Capture a golden: `bash test/capture_goldens.sh` (or the specific
   `diff_compiler_*.sh` with `CAPTURE=1`).
3. Verify: `bash test/diff_compiler_<name>.sh` passes.

Add cases to the gate matching the stage you changed (e.g. parser change →
`test/diff_compiler_parse*.sh` or `test/diff_compiler_check*.sh`).

## Task playbooks (skills)

For recurring multi-file tasks, load the matching skill rather than
re-deriving the workflow. **Skills are planning inputs, not just
implementation aids** — at task triage (including during plan-mode
exploration, *before* writing the plan) match the task against this table and
load the matching skill. A roadmap/Phase task is the cue: confirm where the
fix lands, then load. (A `UserPromptSubmit` hook,
`.claude/hooks/skill-triage.py`, nudges this on PLAN.md/Phase prompts.)

- **add-language-feature** — thread a new construct through the whole pipeline.
- **add-primitive** — add/modify a stdlib `extern` primitive (native, in `compiler/eval/eval.mdk`).
- **extend-stdlib** — implement/extend a *pure-Medaka* stdlib function, impl,
  doctest, or prop in `stdlib/{core,list,string,array}.mdk` (per STDLIB.md). Not
  for externs — that's add-primitive. Normally user-reserved; load when asked.
- **debug-pipeline** — diagnose a parse/typecheck/eval failure. **Reach here
  first for a dispatch bug that reproduces through the loader but works
  single-file** (Phases 96/103/121/125): that shape is *usually* a
  `compiler/eval/eval.mdk` ordering bug, not the dict-passing machinery a PLAN
  entry may name. But confirm empirically — Phase 134 was the inverse (loader-only
  AND dict-passing: the *joint* dict-pass conflating same-named cross-module fns),
  and the eval-modules vs single-file comparison did not flag it. See Gotchas for
  the full counterexample and the instrument-eval's-resolution-arms technique.
- **add-lsp-capability** — add/extend an LSP feature.
- **harden-typechecker** — typechecker-*internal* correctness/diagnostics work
  (much of the Phase 62–72 arc): add a `type_error`, tighten constraint/
  coherence/unification logic, without breaking error accumulation or level
  bracketing. Note: not every typechecker-flavored Phase item lives *only* in
  the typechecker — and adding a `type_error` does NOT by itself make a task
  this skill. Cross-cutting work is **add-language-feature** instead:
  - Phase 69 dispatch / 69.x dictionary passing — touches resolve/typecheck/eval
    + a marker pass.
  - Phase 63 — `compiler/frontend/desugar.mdk`-rooted (`deriving` for parametric types).
  - Phase 72 (done) — field-name reuse / receiver-directed resolution: added the
    `AmbiguousField` type_error but the bulk was a `field_owners` multimap
    threaded through *both* `compiler/frontend/resolve.mdk` and `compiler/types/typecheck.mdk`. Looked like harden;
    wasn't.
  - Phase 73 (TODO) — signature-driven parameter typing (bidirectional checking):
    pure inference work, yet a delicate cross-cutting change to the letrec-group
    path, so add-language-feature.
  - Phase 83/84 dict-threading (e.g. instance-`requires` dicts into return-position
    impl bodies) — feels like typechecker-internal dispatch work, but a route
    threads through `compiler/frontend/ast.mdk` (resolved record) + `compiler/types/typecheck.mdk` + dict_pass logic +
    `compiler/eval/eval.mdk` together, so add-language-feature. Gotchas: register dict-route
    var-ids *after* inference (unify picks the surviving id); gate to
    return-position methods (arg-position stay on arg-tag); the flat impl-key dict
    can't carry nested dicts.
  Check where the fix actually lands before loading this skill.

## Doc index

| Doc | What's in it |
|-----|--------------|
| `README.md` | Full build/test/CLI usage, editor setup, layout |
| `docker/README.md` | The `scripts/docker-dev.sh` container workflow — run `make medaka` + the gate suite entirely in a Linux VM so the write storm never hits the host FS (escapes a host DLP/endpoint scanner's CPU spikes). Read before touching the Dockerfile/wrapper or adding node/wasm gates |
| `SYNTAX.md` | Terse cheat-sheet of every construct the **current binary** accepts (one verified example each). Reach here first for "what syntax exists / does X parse" — faster than reading `compiler/frontend/parser.mdk`. Ground truth over `language-design.md` when they disagree |
| `LAYOUT-SEMANTICS.md` | Offside-rule layout spec — the formal ground truth for layout work. A lexer-vs-spec divergence is a lexer bug; a SYNTAX.md/PLAN.md-vs-spec divergence is a doc bug (§12.4). Start here for any layout investigation |
| `language-design.md` | Language design & semantics (intent/rationale — may describe unimplemented features) |
| `PLAN.md` | Forward-looking roadmap (open phases) |
| `PLAN-ARCHIVE.md` | Completed Phases 1–97 + per-phase implementation notes |
| `STDLIB.md` | Stdlib module plan |
| `stdlib/README.md` | Conventions for adding extern primitives |
| `compiler/ERROR-QUALITY.md` | Error-message rubric + copy standard (dual human+LLM-agent audience; 7-dim grading). Read before writing/changing a diagnostic. Graded corpus + scores live in `test/error_quality_fixtures/{INVENTORY,GRADING}.md` |
| `compiler/DIAGNOSTIC-CODES-DESIGN.md` | Stable diagnostic error-code taxonomy (per-stage `T-*`/`R-*`/`P-*`/`L-*`/`W-*`) + the `Diag` `code`/`kind`/`help`/`fix` JSON contract. Add new codes here |
| `compiler/BOOTSTRAP.md` | Native self-compile log: B1–B7 (each stage native==interpreter) + C1–C3 (emitter self-compile fixpoint), with the emitter bugs fixed per slice |
| `compiler/EMITTER-GAPS.md` | Native emitter gap census — closed gaps (E-series) + the residual: the emitter's **refutable** `CGBind` (`Just x <- e`) lowering is a contained `gapU` (not produced by current source; the front-end resolve/typecheck side of refutable match-arm guards was fixed 2026-06-15, see the guard note above). The mixed-nullary/payload-ADT fuzzer crash was CLOSED 2026-06-13 — root cause was a cross-module **constructor-name collision** in the emitter's bare-name ctor tables (fixed by universal ctor mangling in `backend/private_mangle.mdk`), NOT match field mis-extraction as first filed. |
| `compiler/DISPATCH-GAPS-SCOPE.md` | Repro-verified scope of the 4 native dispatch gaps (#54 Map `toList` / #55 sum-product / #50 parametric-Ord / #21 nested route flattening): minimal repro + root cause + fix-location per gap. **ALL FOUR NOW CLOSED** (#54 2026-06-11; #50; #55 2026-06-11 build + 2026-06-13 eval path; #21 2026-06-14 — gated binop element-reqs on `argStampEnabled`, removed the `suppressBinopStamp` workaround). The deeper root — the `argStampEnabled` eval-vs-emit fork these shared — is being retired by `compiler/ARGSTAMP-UNIFY-PLAN.md`. |
| `compiler/PERF-SCOPE.md` | Bar-4 performance scoping: every `clang` invocation + the one-line `-O2` enable, why `-O2` is fixpoint-safe (text IR is pre-clang), benchmark-harness plan, ranked hot paths (2234 `alloca`→`mem2reg`, GC alloc density), sequenced session steps |
| `compiler/PERF-RESULTS.md` | Measured perf log. **⚠️ the 1.72s self-compile below is STALE — see the 2026-07-02 warning at the top of that file: emit is now ~3.7s (compiler grew), and that session parallelized the build/test harness (oracle build 327→34s, gate suite 125→32s) + built the emitter at -O2 + added env knobs (EMITTER_OPT/ORACLE_OPT/CLI_OPT/GC_INITIAL_HEAP_SIZE).** Historical: **Bar-4 EXECUTED (2026-06-11), extended session 2 (2026-06-14):** self-compile **12.04 s → ~1.72 s (~7×); ~73× vs the OCaml interpreter**. Session 1 (18 wins): `-O2` + GC `free_space_divisor=1` + O(N²)→O(N·log N) SMap/EMap membership/index fixes across DCE/typecheck/emit. Session 2 (3 wins, 2.57→1.72 s): two MISATTRIBUTED-symbol O(N²) sites session 1 missed — `scopeArities` (~23%) + `maybeInferConstraint` (~7.5%) membership→SMap — plus `GC_malloc_atomic` for pointer-free string cells (~3%). Reusable patterns (map the lam-id to source before trusting a filed hotspot; verify by wall-clock not sample count), every dead-end, and the supervised-only remaining levers (threaded float-augmented sig tree, GC allocation density). Harness: `test/bench.sh` |
| `compiler/STAGE2-DESIGN.md` / `compiler/RUNTIME-DESIGN.md` | Native backend design: Core IR seam, value rep, GC, per-extern disposition |
| `compiler/README.md` | Self-host port slice log + roadmap |
| `compiler/REROOT-PLAN.md` | The plan that took every differential gate OCaml-free (DONE 2026-06-13): gate categories (HOST/eval-probe-oracle/front-end/build), golden-capture infra, native-interp oracle, phasing. |
| `compiler/DRIVER-COLLAPSE-PLAN.md` | The plan that folded single-file typecheck+eval into the 1-module case of the multi-module path (DONE 2026-06-13, closes audit §6): 5 phases (scaffold→test→dict→eval→check→delete), `check`-option-A (resolves imports), risk register. |
| `compiler/ARGSTAMP-UNIFY-PLAN.md` | The approved plan (2026-06-14, IN PROGRESS) to retire the `argStampEnabled` eval-vs-emit dispatch fork (the finer split the driver collapse left; shared root of #55/#21): flip eval to full dict-threading, arg-tag survives only for the irreducible primitive residual; 6 phases, fork inventory, arg-tag dependency map. |
