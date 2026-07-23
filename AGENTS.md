# AGENTS.md

Orientation for AI agents working on **Medaka**, a pragmatic functional language that
**self-hosts to a reproducing fixpoint**: the whole pipeline is written in Medaka
(`compiler/*.mdk`) and compiles via a native LLVM backend
(`compiler/backend/llvm_emit.mdk` → text IR → `clang`; C runtime `runtime/medaka_rt.c` +
Boehm GC) to an OCaml-free `medaka` binary. Native is the **sole** compiler — the OCaml
reference compiler was removed 2026-06-26 (tag `oracle-frozen` preserves the last
`lib/`-present commit).

**This file is a *router*: maps, traps, and links.** It does not teach. For prose,
rationale, and post-mortems, follow the links — and don't assume detail that isn't here.

> ### ⚡ Editing `compiler/`? Read [`compiler/AGENTS.md`](compiler/AGENTS.md) first.
> **How not to make the compiler slow.** It exists because *the agents who introduce
> performance bugs here are not the ones hunting them* — every quadratic in this tree was
> added by someone doing reasonable feature work who never thought about perf at all.
> **Thirteen quadratics, all the same shape: a `List` used as a set or a map.** It also
> records the two bottlenecks (`check` is **GC-bound**; `build`/CI is **clang-bound** — do not
> conflate them) and the measurement traps that produce confidently wrong answers.

`compiler/` is ONE Medaka project (`compiler/medaka.toml`); each stage is one `.mdk` file
under a subfolder: `frontend/` (lex/parse/AST/desugar/resolve/marker/exhaust), `types/`
(typecheck + annotate), `ir/` (Core IR, DCE, S-expr), `backend/` (LLVM + WasmGC emit, TRMC,
mangling), `eval/` (tree-walk interpreter), `driver/` (loader, diagnostics, build, CLI),
`tools/` (fmt/printer/LSP/test/repl/doc/new/lint), `support/` (compiler-private
mini-stdlib), `entries/` (per-stage probe entry points), `seed/` (checked-in LLVM IR seed
for cold bootstrap).

## Pipeline — where each stage lives

**Execution order** (driven by `compiler/driver/medaka_cli.mdk` — *not* the order files are
listed):

```
lexer.mdk → parser.mdk → ast.mdk → desugar.mdk → resolve.mdk → marker.mdk
  → typecheck.mdk (runs exhaust.mdk internally) → eval.mdk
  [all in compiler/frontend/ except typecheck.mdk (types/) and eval.mdk (eval/)]
```

Two non-obvious facts that bite when deciding *where* a check belongs:

- **`desugar.mdk` runs FIRST**, before resolve/typecheck. Surface-sugar nodes (`EGuards`,
  `ESection`, `EStringInterp`, `EDo`) are **already lowered to core** by the time
  typecheck/exhaust/eval see the tree. A check that needs the sugar shape (e.g. guard
  *coverage* on `EGuards`) cannot live in typecheck/exhaust — it must run pre-desugar (see
  `checkGuardExhaustiveness` in `compiler/frontend/exhaust.mdk`, a standalone pass on the
  raw AST).
- **`exhaust.mdk` is not a standalone later stage** — `checkMatchExhaustive` is *called
  from inside* `compiler/types/typecheck.mdk` (once per `EMatch`, with the scrutinee type
  known). It only ever sees core patterns.

| Stage | File | Role |
|-------|------|------|
| Lex | `compiler/frontend/lexer.mdk` | Indentation-sensitive; emits INDENT/DEDENT/NEWLINE |
| Parse | `compiler/frontend/parser.mdk` | Recursive-descent grammar |
| AST | `compiler/frontend/ast.mdk` | Node types + source locations |
| Desugar | `compiler/frontend/desugar.mdk` | Runs FIRST. Lowers `deriving`, record puns, `EGuards`/`ESection`/`EStringInterp`, `EDo` (→ nested `andThen`/`pure`), default-method specialization |
| Resolve | `compiler/frontend/resolve.mdk` | Name binding, single- and multi-module |
| Mark | `compiler/frontend/marker.mdk` | After desugar+resolve, before typecheck. Rewrites interface-method `EVar`→`EMethodRef` so typecheck can stamp the resolved impl key per call site |
| Typecheck | `compiler/types/typecheck.mdk` | Hindley-Milner + interfaces + effects; invokes Exhaust per `EMatch` |
| Exhaust | `compiler/frontend/exhaust.mdk` | Maranget pattern-matrix algorithm; called *from* typecheck |
| Eval | `compiler/eval/eval.mdk` | Tree-walking interpreter; dict-passing typeclass dispatch |

Support files:

| File | Role |
|------|------|
| `compiler/driver/loader.mdk` | Multi-file dependency walk, topo sort, cycle detection; `medaka.toml` project-root walk-up |
| `compiler/driver/diagnostics.mdk` | Accumulating error pipeline — phases collect errors, no exit-on-error |
| `compiler/driver/build_cmd.mdk` | `medaka build` — Core IR lower → LLVM emit → clang |
| `compiler/driver/medaka_cli.mdk` | CLI entry: `check`/`fmt`/`new`/`build`/`run`/`test`/`doc`/`lint`/`manifest`/`repl`/`lsp` |
| `compiler/ir/core_ir.mdk` + siblings | Core IR types, lowering (`core_ir_lower.mdk`), S-expr (`core_ir_sexp.mdk`), DCE (`dce.mdk`), interpreter (`core_ir_eval.mdk`) |
| `compiler/backend/llvm_emit.mdk` | LLVM text IR emitter |
| `compiler/backend/wasm_emit.mdk` | WasmGC text IR emitter (2nd backend) |
| `compiler/backend/private_mangle.mdk` | Universal constructor name mangling |
| `compiler/backend/trmc_analysis.mdk` | Tail-recursion-modulo-cons analysis |
| `compiler/types/annotate.mdk` | Type annotation helpers |
| `compiler/tools/printer.mdk` / `fmt.mdk` | AST→source round-trip / comment-preserving formatter |
| `compiler/tools/lsp.mdk` | LSP over stdio: diagnostics, formatting, symbols, hover, definition, highlight, completion, inlay hints |
| `compiler/tools/mcp.mdk` | `medaka mcp` — MCP stdio server, the LSP-for-agents: 7 tools (check/type_at/symbols/definition/fmt/lint/test), auto-wired via committed `.mcp.json`. See `docs/ops/MCP.md`; use the tools during your own work and file friction as `ws:tooling` |
| `compiler/tools/lint.mdk` | `medaka lint` — modular AST linter on the RAW pre-desugar AST. Per-file `Rule` + cross-file `CrossFileRule` registries (add a rule = one fn + one list entry); `--fix`; `--deny`/`--disable`/`--only` |
| `compiler/tools/doctest.mdk` | Doctest extraction for `medaka test`. Two paths: import-bearing files → multi-module chain; prelude-only → single-file + arg-tag fallback (deliberate — the multi-module path would coalesce a redefined prelude standalone and error every example at once) |
| `compiler/tools/check.mdk` / `check_policy.mdk` | `medaka check` entry + policy checker |
| `compiler/tools/test_cmd.mdk` / `prop_runner.mdk` | `medaka test` — doctests + property tests |
| `compiler/tools/doc.mdk` / `new_cmd.mdk` / `repl.mdk` | `medaka doc` / `medaka new` / `medaka repl` |
| `compiler/support/util.mdk` + siblings | Compiler-private helpers + thin wrappers over `stdlib/` (e.g. `ordmap` wraps stdlib `Map`). Stdlib imports ARE allowed — weigh per module, see Traps |

`stdlib/`: `runtime.mdk` (extern primitive catalog, read from disk at runtime), `core.mdk`
(implicit prelude — `Eq`/`Ord`/`Debug`/`Num`/…), plus `list`/`string`/`array`/`map`/`set`/
`io`/`hash_map`/`hash_set`/`mut_array`/`json`/`byteparser`/`bytebuilder`. `map`/`set` are
weight-balanced ordered trees; `hash_map`/`hash_set` are mutable hash tables; `mut_array` is
a growable vector (amortized-O(1) `push`); `json` is a recursive-descent parser/serializer;
`byteparser`/`bytebuilder` are a binary parser-combinator library and its symmetric output
builder. **Only `core.mdk` is auto-prelude.** For the rest, **an import must say what it
binds**: `import map.{Map, get}` (selective — the common form), `import map.*` (everything
exported), or `import map as M` → `M.get` (**values only** — an alias-qualified name in
*type* position is a parse error, so import types by name). Combinations (`import m.{f} as
A`, `import m.* as A`) are rejected with a diagnostic that names the fix.
⚠️ **A bare `import map` binds NO names** — not values, not types, not `map.get` (qualified
access exists *only* via `as`). But it is **not** a no-op: **any** import of a module brings
that module's `impl`s into scope for dispatch, which is the whole job of the bare form (e.g.
`stdlib/json.mdk`'s bare `import array` — without it, `map (+ 1) [|1,2,3|]` is *"No impl of
Mappable for Array"*).
`io.mdk` is the ergonomic layer over the `runtime.mdk` IO externs.

## 🚦 How work lands: `main` is PROTECTED — you cannot push to it

**Every change goes through a PR.** `git push origin main` fails with `GH013: Repository
rule violations`. There is **no admin bypass**, for anyone. A rejected push is the rule
working, not a credentials problem: open a PR.

```sh
git checkout -b <topic>              # never commit on main
# ... work; verify with `make preflight` ...
git push -u origin <topic>
gh pr create --fill
gh pr merge --auto --merge           # merges itself the moment every required check goes green
```

**Eleven required checks:** the **seven** `gates (…)` shards (engines · backend · tools · sqlite ·
eval · frontend · types), `soundness`, `seed-health`, `inlang`, `wasm`. ⚠️ **A gate matching
`test/diff_compiler_*.sh` but no shard pattern in `ci.yml` SILENTLY NEVER RUNS** —
`diff_compiler_ci_shard_coverage.sh` catches it, and the merge queue will bounce you for it.
⚠️ **Don't trust this count either — DERIVE it** (it said "Ten" while `wasm` was already required, #597):
```sh
gh api repos/MedakaLang/medaka/rulesets --jq '.[]|select(.enforcement=="active")|.id' | while read -r id; do
  gh api "repos/MedakaLang/medaka/rulesets/$id" \
    --jq '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context'
done
```
🚨 **NOT `…/branches/main/protection…` — that endpoint 404s `"Branch not protected"`, which reads
exactly like "nothing is required here".** Required checks live in a repo **RULESET**, not classic
branch protection. That 404 is also why `git push origin main` fails with `GH013: Repository rule
violations` — a *rules* message. **That single 404 is why `ci.yml` (x2) and this file all said
`wasm` was advisory for two days while it was required**, and it misrouted #597's whole design.
Shards are scheduled by **cost, not theme**: put a new gate where there is ROOM. ⚠️ **`gates
(engines)` is NOT the critical path** — that claim (`~5.8 min`) rotted when the shard was given
the whole runner (`full_cores`, `ci.yml`), and it misrouted #597's design; measured across three
real runs in July 2026, `gates (types)` was the pole and `engines` the cheapest heavy shard.
**Numbers here rot — read them off a run instead:**
`gh run view <id> --json jobs --jq '.jobs[]|select(.name|startswith("gates"))|{name,s:((.completedAt|fromdate)-(.startedAt|fromdate))}'`
**Zero approvals required** — the *checks* are the gate, not a human, so an agent can
self-merge on green. The repo is org-owned (MedakaLang), so a **merge queue is live** — see above; `--auto` enqueues.

Two things that are easy to get wrong:

- **`soundness` is required on purpose.** It runs `typecheck_compiler_source.sh` + the
  self-compile fixpoint + the doc gates. **All gates pass on an ill-typed compiler** — `make medaka` does
  not gate on type errors — which is exactly how a compiler with unbound constructors once
  shipped to `main` with every gate green. The gate shards cannot catch that; `soundness` can.
- **There is a MERGE QUEUE (2026-07-13).** `gh pr merge --auto --merge` **enqueues** your PR;
  the queue does the rest. It builds a temp branch of *your PR merged onto current `main`, plus
  everything queued ahead of you*, runs every required check **on that**, and merges only if green —
  so what CI validates is the **merged result**, not your branch in isolation. That is not a
  formality: two green branches have merged cleanly into a **crashing** tree (git auto-merged a
  break it could not see — one branch had added a caller into machinery the other was re-signing,
  on different lines, so no conflict marker).

  **You do NOT need to keep your branch up to date with `main`.** "Strict" mode is OFF and
  `update-branch` kicks are obsolete — the queue handles staleness. If a doc tells you to babysit
  a `BEHIND` branch, that doc is stale.

**Where the backlog and the orchestration rules live** — none of this is reachable from
anywhere else, so it is listed here:

### 🎯 "What should I work on?" → **GitHub Issues.** Not a doc.

```sh
gh issue list --label "S0: silent wrongness"      # always start here — silent wrongness beats everything
gh issue list --label "ws:soundness" --state open # one workstream (ws:soundness|language|tooling|wasm|
                                                  #   diagnostics|testing|release|perf|stdlib|typecheck)
gh issue list --label "needs-repro"               # inherited claims NOBODY has reproduced
gh issue list --milestone "0.1.0 public preview"  # the release floor
```

**Severity:** `S0: silent wrongness` (a wrong answer or destroyed source, **with no error**) →
`S1: loud breakage` → `S2: misleading` → `S3: friction & debt`. **Soundness outranks release.**

⚠️ **`verified` vs `needs-repro` is load-bearing. REPRODUCE BEFORE YOU FIX.** When the backlog was
re-derived against the binary on 2026-07-14, **six entries were already fixed** — including two
"silent build miscompiles", a duplicate-definition segfault, and a `newtype` bug billed as "the best
value-to-risk item on the board". **Closing an issue as already-fixed is a good outcome; say so.**

| Path | What it is |
|------|-----------|
| `.claude/workstreams/` | Per-workstream **domain knowledge**: the traps, the collision map, and *why each bug class recurs*. **Not the backlog** (that is the issue tracker) — read the one matching your labels **before** you start. |
| `.claude/ORCHESTRATING.md` | Orchestration playbook. Its #1 lesson: *the gap docs lie — reproduce before you trust them.* |
| `.claude/HANDOFF.md` | **Known-red gates.** Read BEFORE diagnosing a failing gate — it is usually not your break. |
| `.claude/skills/` | Task playbooks (table at the bottom of this file). |

## Build & test

```sh
make medaka          # WARM (./medaka_emitter present): 2-stage rebuild from current source
                     # COLD (fresh clone): bootstraps from compiler/seed/emitter.ll.gz first
./medaka run yourfile.mdk
```

**Staleness guard.** Every `./medaka` invocation recomputes a live source fingerprint over
`<root>/compiler/*.mdk` and compares it to the one baked in at build time — a mismatch means
you're running a binary built from OLDER compiler source than what's on disk. Default is a
warning; **`MEDAKA_STRICT=1`** promotes it to a hard `exit 1`, useful when you need certainty
you're not debugging or verifying against a stale binary (`checkSourceStaleness`,
`compiler/driver/medaka_cli.mdk`).

**In a worktree:** the shell cwd resets between calls, so use
`make -C /absolute/path/to/worktree medaka`. The `./medaka` binary lands in the worktree.

**Borrowing an emitter (`cp <other-tree>/medaka_emitter .` then `make medaka`) is SAFE, but it
does NOT warm-start the build — say so plainly, since a prior wording sold it as a warm start
and then stated the mechanism that defeats one in its own next clause.** `cp` copies the
emitter binary but not the separate `.medaka_emitter.srcstamp` provenance stamp beside it, so
`build_native_medaka.sh` always sees "provenance unknown" for a borrowed emitter and rebuilds
it from current source anyway — **stages A and B run in the borrow path exactly as they do
cold** (`test/build_native_medaka.sh:212-221`; the *"fresh bootstrap, or copied in from another
tree"* branch covers both cases identically). **The only thing borrowing actually skips is the
~31 s seed-bootstrap step** (measured: `time sh test/bootstrap_from_seed.sh` → `real
0m31.003s`, exit 0). It used to decide staleness by **mtime**, which `cp` inverts — that is
where the spurious "lagging seed" scares came from.

> ### 🚨 If you are a WORKTREE-ISOLATED SUBAGENT, do NOT borrow it. Cold-bootstrap.
>
> **For an isolated subagent, borrowing can cost you your whole session — and the failure is not
> reliable enough to predict.** `cp <other-tree>/medaka_emitter .` *reads* from a tree that is not
> yours, which can trip the auto-mode isolation classifier — and the denial is **stateful**: it
> carries forward and blocks every later `make` you attempt, *including a clean cold-bootstrap
> entirely inside your own worktree*. In the same 2026-07-16 session, one subagent tripped the
> classifier on this exact `cp` and **never built again** (its stated reasons for the successive
> denials even contradicted each other — "you are in another agent's worktree" → "bare `make`
> risks the shared main checkout"), while another borrowed the emitter with no issue.
> **Don't gamble the session on a coin-flip to save ~31 seconds — that is all borrowing buys
> (see above).**
>
> **Just run `make -C <your-absolute-worktree-path> medaka`.** A fresh worktree has NO
> `./medaka_emitter` and **that is FINE** — it cold-bootstraps from `compiler/seed/emitter.ll.gz`
> and works, at the same ~31 s cost either way. This paragraph's cost figure said **~4 s** until
> 2026-07-16, an ~8× understatement that propagated into new code verbatim — re-derive it with
> the `time` command above rather than trust a number here. **Never read from another tree; the
> speedup is not worth the session.**

**Environment.** opam/dune are NOT needed. The native build uses only **clang + Boehm GC**
(Debian: `clang` + system `libgc-dev`, found via plain `-lgc`; macOS: Apple clang + `brew
install bdw-gc`). `node` ≥ 24 is needed only for the wasm/sqlite/playground gates. If clang
or libgc is missing, install from the system package manager — don't vendor it.

**Where you're running.** Primary dev is a dedicated **x86_64 Linux box** (Debian 13, 12
cores / 32 GB; repo at `/root/medaka`). Build natively — no container, no VM, no wrapper.
`scripts/docker-dev.sh` + `docker/` (see `docker/README.md`) exist only for the old macOS
laptop's DLP scanner problem, which **does not exist here — do not reach for the Docker
wrapper.**

⚠️ **The dual-platform invariant still holds: every build/test script must run on BOTH
Linux and macOS** (the Mac is retained for macOS smoke-testing; there is no alternative).
When you touch a script, keep both arms alive — `stat -c %Y` *or* `stat -f %m`,
`pkg-config`/`-lgc` *or* `brew --prefix bdw-gc`, no Mach-O-only link flags.

Two platform facts worth not rediscovering: the emitted LLVM IR carries **no target
triple**, so the checked-in seed cold-bootstraps on x86 *or* arm from the same bytes; and
the deeply-recursive compiler gets its stack from a **256 MB GC-aware worker pthread**
spawned in `runtime/medaka_rt.c`, not a link flag — so it runs fine under Linux's default
8 MB `ulimit -s`.

### ⚡ THE AGENT LOOP: `make preflight`. Do NOT run the full suite locally.

**The full suite is CI's job.** Run the gates your change touches; push; let CI run the
other 80 across six parallel hosted runners.

```sh
PREFLIGHT_DRY=1 sh test/preflight.sh                 # ✅ FIRST STEP if unsure — derives the
                                                      #    gate set for free: builds/runs nothing
make preflight       # ✅ THE LOOP — derives the gate set from YOUR diff, and the oracle
                     #    set from those gates. Touching parser.mdk: 9 oracles, 11 gates.
sh test/run_gates.sh 'diff_compiler_parse*'          # ✅ targeted, by name
sh test/build_oracles.sh --for 'diff_compiler_*'     # ✅ fresh-worktree recipe: 52 oracles, ~2 min
sh test/build_oracles.sh --for --list '<pattern>'    # ✅ DERIVE ONLY — which oracle names a
                                                      #    pattern resolves to, builds nothing
FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one <name>   # ✅ exactly one
sh test/run_gates.sh                                 # ❌ all 83
FORCE=1 sh test/build_oracles.sh                     # ❌ all 54 oracles. Almost never right.
```

🚨 **On a `compiler/backend/*` diff, `make preflight` forces the self-compile fixpoint and the
loop can exceed the 10-minute foreground tool ceiling — killed at 600s with `exit 143`
(SIGTERM). That is the CEILING, not your change hanging — do not go debug a phantom.** Same
risk running `test/diff_compiler_perf_scaling.sh` directly (measured 654-748 s, ~11-12 min) —
it's one of the slowest gates in the tree and just as foreground-unsafe as a single blocking
call. **`PERF_N=<n>` shrinks its input size for faster local iteration (default 250); quick
mode is the default scope, `PERF_DEEP=1` restores the full nightly scope** (`test/diff_compiler_perf_scaling.sh`).
Same trap: `test/diff_compiler_engines.sh` (the 3-engine differential) is ~5-7 min — its
own `ENGINE_JOBS` table reads `JOBS=3 ~5min`, and `MEDAKA_REQUIRE_WASM=1` (the CI wasm arm) pushes
it to ~7. **`ENGINE_JOBS=<n>` is a settable knob, not just a measurement** — override it (e.g.
`ENGINE_JOBS=2`) to throttle the fan-out on a shared/loaded box, or scope to a subset with
`ONLY=<glob>` while iterating (#723).

**Remedy: run either one detached/backgrounded and poll for completion, not in a single
foreground turn** (`run_in_background` in this harness, not a blocking call). Before
committing to a run that long, reach for `PREFLIGHT_DRY=1` (fence above) — `test/preflight.sh`
is the source of truth for it and its sibling `PREFLIGHT_CHANGED_FILE=<path-to-a-file-listing-
changed-paths>` (hands preflight a changed-file list directly instead of deriving one from
`git diff`). ⚠️ `PREFLIGHT_DRY` does NOT surface a forced fixpoint — that decision fires *after*
the DRY exit — so a short dry-run gate list does not by itself mean the real run will finish
inside the ceiling. (#520, #540)

**This is a real cost, not an aesthetic preference.** Several agents share this box. One
agent running the whole suite + a full oracle build takes the load average past 10 and
**turns a 30-second gate run into several minutes for everyone else.** Worse, bare
`FORCE=1 build_oracles.sh` spawns an `xargs -P` pool that **outlives the agent's turn and
gets RESPAWNED by the harness** — it has killed several agents. Use the targeted forms.

⚠️ **`preflight` is a FILTER, NOT AN AUTHORITY.** It runs a subset and prints what it
skipped. **CI on the PR is the authority. Nothing merges on a green preflight.**

⚠️ **On a BLAST-RADIUS path, `make preflight` IS the full suite — the two rules above
collide, and this carve-out is the resolution** (#492). For `stdlib/*`, `compiler/support/*`,
`compiler/entries/*` and friends, preflight's own `mark_full` adds the `diff_compiler_*`
catch-all, so "the loop" silently becomes the ~84-gate run this section forbids. **The
widening is CORRECT** — a prelude change moves essentially every golden, and a narrow
preflight would report green having run lexer + snapshot + doctests. So on those paths:

- preflight now **announces this loudly before it spends the box**, and prints the exact
  `run_gates.sh` line it is about to become;
- **`PREFLIGHT_NO_FULL=1 sh test/preflight.sh`** declines it. It runs **NOTHING** and says
  so — deliberately *not* a narrower subset, because a green that tested less than it
  appears to is the hazard this whole suite exists to prevent;
- **preferred: push and let CI run it** across its parallel runners.

⚠️ **`PREFLIGHT_NO_FULL` does NOT reach the `compiler/backend/*` fixpoint case above it in this
section.** It only guards `full_suite` (the blast-radius path just described); a
`compiler/backend/*` diff instead sets a separate `need_fixpoint` flag
(`grep -n need_fixpoint test/preflight.sh`), which prints no banner and has no opt-out — the
fixpoint runs unconditionally whether or not `PREFLIGHT_NO_FULL` is set. If the 10-minute
ceiling above is what you're trying to dodge, background the run; `PREFLIGHT_NO_FULL` will not
skip the fixpoint for you. (#520, #545)

**Two agents were killed for obeying `make preflight` here** before it said any of this.
If you took the loop at its word on a prelude change, that was the tooling's bug, not
yours. An instruction that silently expands into what another instruction forbids is worse
than either alone: the one who obeys pays.

**A full local run IS justified when:** you changed `compiler/backend/*` (run
`selfcompile_fixpoint.sh` — preflight forces this); you changed `compiler/support/*` or
`stdlib/core.mdk` (blast radius genuinely is everything); you are merging two branches that
touched the same subsystem (pre-merge greens do not carry over); or CI says something you
cannot reproduce. Outside those: **push and let CI answer.**

If `run_gates.sh` reports gates FAILED with *"phantom skip: oracle/binary not built"* —
that is **not a regression**, you just have no oracles. (They count as FAILED, not skipped,
on purpose: a gate that ran nothing must never report green.)

### The gates

```sh
make preflight                         # ⚡ the loop (above)
make test                              # IN-LANGUAGE suite (doctests, props, `test "…"`). No oracles.
make gates                             # the FULL 84-gate differential suite
sh test/run_gates.sh 'pat*' 'pat2*'    # multiple patterns (deduped). NOT brace expansion.
make docs-links                        # doc-link rot: every cited path must exist. No compiler.
make agent-doc-symbols                 # doc-symbol rot: every backticked symbol must resolve. No compiler.
make docs-index                        # regenerate docs/README.md (GENERATED — never hand-edit)
```

| Gate | What it proves |
|------|----------------|
| `test/diff_compiler_*.sh` | Differential: native stage output vs captured goldens |
| `test/selfcompile_fixpoint.sh` | Emitter self-compile fixpoint (C3a/C3b) — **THE decisive gate for any compiler-source change** |
| `test/typecheck_compiler_source.sh` | Strict-typechecks the WHOLE compiler source. Run alongside the fixpoint for any compiler `.mdk` change — the bootstrap emit path does NOT gate on type errors, so an ill-typed compiler builds green without this. ⚠️ It (and `diff_compiler_selfproc.sh`) needs its slow oracle (`diagnostics_project_main`, `check_all_main`, …) BUILT FIRST in a fresh worktree — `FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one <name>` — and REBUILT after every compiler-source edit; a missing/stale oracle exits 2, which reads like a skip, not a failure. **For a fast first-line local check with no oracle build/staleness coupling, reach for `make check-self` instead** — sub-minute (~20s), runs `./medaka check` over the already-built binary's own `medaka_cli.mdk` closure; `typecheck_compiler_source.sh` remains the fuller authority (also covers `compiler/entries/*.mdk`) |
| `test/diff_compiler_engines.sh` | **The 3-engine differential**: eval == native == wasm on the SAME programs. Found 4 bug classes on its first run. Ledger: `test/engine_divergence.txt` |
| `test/diff_compiler_perf_scaling.sh` | **The O(n²) detector.** Inputs at N and 2N; grades the *allocation* growth ratio (linear ≈2.0×, quadratic ≈4.0×). Allocation, not wall-clock — GC bytes are deterministic, so it is machine-independent and noise-free |
| `test/diff_compiler_capability_matrix.sh` | Every extern in `stdlib/runtime.mdk` vs what each engine actually implements (EXISTENCE). Its absence let 37 externs drift for six weeks. Ledger: `test/CAPABILITY-EXCEPTIONS.txt`. **Also (#476) the DOMAIN requirement:** every *pure* extern (no `<Cap>` annotation — derived, not hand-listed) must carry a verdict in `test/EXTERN-DOMAIN-LEDGER.txt` — `TOTAL` / `BOUNDARY` (edge cells pinned across all 3 engines) / `PENDING` (edge domain, cells owed, `#NNN`) / `EXEMPT`. A new pure extern with no row FAILS (self-drains). This is what would have caught the `floatToInt` 3-way edge divergence (#346) structurally |
| `test/diff_compiler_tmc_parity.sh` | Both backends TMC the same functions (needs `sh test/wasm/build_wasm_oracle.sh`) |
| `test/bootstrap_*.sh` | Each native pipeline stage == interpreter output |
| `test/diff_compiler_must_fail.sh` | **The MUST-FAIL suite — the TRACKER's self-drain.** Each `test/must_fail_fixtures/*/` asserts one OPEN issue's bug **still reproduces**; when a fix lands the fixture flips green and **FAILS the gate**, naming the issue to close. **A RED here is usually a GOOD failure, not your break.** Runs in `soundness`, not a shard |
| `test/check_removed_constructs.sh` | Tree-wide scan for stale uses of removed constructs (~2-3 min, `JOBS=` knob) |

**Stale oracles:** `run_gates.sh` already derives which `test/bin/*` probes the SELECTED gates
read, compares their mtimes against `compiler/`/`stdlib/`/`runtime/` source, and REFUSES to run
(exit 1, printing the exact narrow `--build-one`/`--for` rebuild command) rather than report a
false pass/fail — so for any gate you run through it, staleness is already handled for you.
Override with `NO_STALE_CHECK=1` only if you know exactly why. `diff_native_cli` and the
bootstrap suites are especially stale-prone when invoked OUTSIDE `run_gates.sh` (e.g. bare
`sh test/diff_native_cli.sh`) — force-rebuild before trusting a pass/fail from those.

**Parallelism.** The oracle build, `run_gates.sh`, the heavy compiler gates, and every wasm
gate fan out across an `xargs -P` pool — cap with `JOBS=n`, or `INNER_JOBS=n` for per-gate
fan-out inside `run_gates.sh`. Opt-level knobs (`EMITTER_OPT` -O2, `ORACLE_OPT` -O0,
`CLI_OPT` -O2, `WASM_ORACLE_OPT` -O2 — **-O0 overflows the deep-TCO fixtures**) and
`GC_INITIAL_HEAP_SIZE` **all preserve byte-identical emitted IR**: the text IR is produced
before `clang` runs, so an opt level can never change it. Details:
`compiler/PERF-RESULTS.md`.

**Concurrent `medaka build` is scratch-path safe.** `build_cmd.mdk` stages every scratch
file inside ONE `mktemp -d` unique to that build *process*. ⚠️ Until 2026-07-13 the IR path
was keyed on the OUTPUT BASENAME in global `/tmp`, so two concurrent builds writing
`-o <somedir>/out` — different worktrees, different repos — clobbered each other's IR and
produced a **stable-looking WRONG binary** (19/20 iterations). Anything that "keys the temp
file on something distinctive" is a trap; only a per-process temp dir is correct. Still run
a newly-parallelized gate several times — a temp-collision flake shows ~1 in N.

### Pre-commit hook (ACTIVE) — fmt + lint + snapshot + lextok

`.githooks/pre-commit` runs FOUR checks (fmt + lint always; snapshot + lextok gated on what's
staged) over each staged `.mdk` (`test/` fixtures excluded from fmt/lint — they violate style
on purpose). Re-install after a fresh clone:
`cp .githooks/pre-commit "$(git rev-parse --git-common-dir)/hooks/pre-commit"`.

- **Format** — `medaka fmt --check` rejects any staged unformatted `.mdk`. **Run `medaka fmt --write
  <changed.mdk>` and re-`git add` before committing any `.mdk` edit.**
  ⚠️ **The tree is NOT fmt-clean** (verified 2026-07-14): `sqlite/lib/varint.mdk` and
  `stdlib/byteparser.mdk` both fail `fmt --check`, so touching either drags an unrelated
  `.[`→`[` normalization into your diff. (This file claimed "the whole tree is clean". It isn't.)
  **`fmt --write` on a file holding a float literal ≥ 1e15 is FIXED** (#51, CLOSED
  2026-07-15; re-probed 2026-07-16 per #361): it still writes `9e+15`, but the lexer now
  reads that back correctly (`main = println 9000000000000000.0` → `fmt --write` →
  `main = println 9e+15` → `check`/`run` both round-trip to the same `9e+15`, verified
  on the current binary). No longer a destructive operation.
- **Lint** — the tree is at **0 findings and the hook is a MAX RATCHET: all ~20 rules gated**,
  so any NEW finding of any rule fails the commit. The cross-file `rule-duplicate-body` can't
  be checked per-staged-file, so the hook also runs one whole-project scan (`medaka lint
  compiler stdlib sqlite`). **Run `medaka lint` on files you touch.** Silence a genuine
  exception inline: `-- lint-disable-next-line <rule>` (also `-- lint-disable-line`,
  `-- lint-disable-file`; omit the rule to disable all). ⚠️ `medaka lint --fix` **bails on any
  decl containing an interior comment** (it would otherwise drop them) — safe, but it leaves
  comment-bearing sites unfixed.
- **Snapshot** — CHECK ONLY (this hook can never bless): gates on `test/diff_compiler_snapshot_frontend.sh`
  over ANY staged `.mdk` (test/ fixtures included — they're in the corpus) plus `test/snapshots/*.md`
  itself, since a compiler-source change or even a pure `medaka fmt` reflow can move a snapshot.
  A stale snapshot fails the commit rather than reading as tooling breakage. **Run `make
  snapshot-check` first**; to bless a moved snapshot, `sh test/diff_compiler_snapshot_frontend.sh
  --bless <file.mdk>` then re-stage `test/snapshots/` and read the diff (that diff is the real
  review gate).
- **Lextok** — OPPORTUNISTIC: only runs when `test/bin/lex_main` already exists (this hook
  never builds an oracle), scoped to staged `.mdk` files that already have a sibling
  `.lextok.golden`. Gates on `test/diff_compiler_lex_files.sh`. Remedy for a stale golden:
  `CAPTURE=1 sh test/diff_compiler_lex_files.sh <files>`, then re-stage the `.lextok.golden` file(s).

Emergency bypass for any of these: `git commit --no-verify`. If `medaka` isn't built, the hook
warns and allows.

### Debugging a `.mdk` program

`medaka check <file>` prints human `file:L:C:` diagnostics. **`medaka check --json <file>`**
(note: `--json`, not `--format=json`) emits one JSON object per diagnostic carrying a stable
**`code`** (`T-*` type · `R-*` resolve · `P-*` parse · `L-*` lex · `W-*` warning), a `kind`,
a real `range` (0-based LSP line/char), `severity` (1=error, 2=warning), the `message`, and —
for suggestion-bearing errors — a `help` string plus a machine-applicable
`fix { range, replacement }` you can apply verbatim. **When reacting to compile errors
programmatically, prefer `--json` and key off `code`** — it is the stable handle and doesn't
move when wording changes.

**`medaka run --json` and `medaka lint --json` emit the SAME `Diag` JSON envelope** (same
`code`/`kind`/`range`/`severity`/`message` schema as `check --json`) — so a RUNTIME panic, not
just a compile-time error, is machine-parseable the same way.

**Bare `medaka check` filters its scheme dump to the user's OWN top-level bindings** (0.1.0
beginner-UX change — it used to dump the whole ~120-line prelude `=== TYPES ===` corpus ahead
of your own). **`--types` restores the full dump**, prelude schemes included — reach for it
when you need to see what a prelude method (e.g. `pure`/`when`) actually infers to.

When **writing** a diagnostic, follow `compiler/ERROR-QUALITY.md` (the rubric) and add the
code to `compiler/DIAGNOSTIC-CODES-DESIGN.md`.

**To see the TYPED, DICT-PASSED Core IR — the routes and `$dict` params themselves — run
`compiler/entries/core_ir_typed_modules_dump_main.mdk`.** This is the probe for *any* dispatch,
dict-routing, or `requires` bug, and it is the one that answers "which impl did it actually pick,
and what dicts did it actually pass?" It mirrors `llvm_emit_modules_main.mdk` exactly
(`driveModules → runEmitWith → mangle → elaborateModules → dceFilter → lowerProgramEmit`) but
prints `cprogramToSexp` instead of emitting LLVM. An agent chasing a run-path dict bug on
2026-07-16 called it *"the single highest-value tool here — it turned three days of plausible
speculation into a 10-minute proof"*, and it is what disproved a wrong root cause I had briefed.
**Reach for it BEFORE reasoning about routes from the source.**
⚠️ **Do NOT reach for `core_ir_dump_main.mdk` instead — the obvious name is a TRAP.** It is
**prelude-free and typecheck-free**, so it never shows a `$dict` param or a `CDict`/`CMethod`
route: it will show you a clean tree and "confirm" there is no bug. (Its typed sibling's own
header says exactly this — it just wasn't reachable from here.)

**To see the emitted LLVM IR — `medaka build --keep-ir <file>` (or `MEDAKA_KEEP_IR=1`)**, which
writes the IR to **`<output>.ll`** — beside the `-o` target, or beside the default output name if
you passed none — and prints **only that path** (`kept IR: <path>`), *not* the IR itself. On a write
failure it prints `warning: could not keep IR at <path>: <err>` and the build still succeeds — the
note is best-effort either way (`effectiveKeepIr` / `keepIrNote`,
`compiler/driver/build_cmd.mdk:311-319`). **So: `cat` the `.ll`; never expect IR on stdout.**
⚠️ This line said "prints it" until 2026-07-17, which cost an agent a grep cycle looking for IR
that was never going to arrive. `MEDAKA_KEEP_IR=1` is equivalent to the flag; `MEDAKA_KEEP_IR=""`
correctly reads as **unset** (`envOr` maps `Some ""` to the default), so it is *not* an instance of
the empty-env-var-reads-as-set trap. Reach for this the moment a bug is "check/run are green but
the built binary is wrong": it is the only way to see what the backend *actually* emitted, and it
settles dispatch/arity/calling-convention questions that are pure speculation from the source. An
agent debugging a dict-routing S0 on 2026-07-16 called it the single highest-value tool in the
investigation — it turned "I think the wrong impl is selected" into `call
@mdk_impl_S__List_a___s` on the screen, which disproved the filed root cause outright.
⚠️ **`./medaka_emitter <file>` is still NOT the way to get IR** — its CLI is
`<runtime.mdk> <core.mdk> <entry.mdk> [root ...]`, so a bare `./medaka_emitter <file>` is a usage
error, not a build. It no longer LIES about it: every error path of the shared probe scaffolding
now exits **1** with a stderr diagnostic (#440 — `failWith`,
`compiler/entries/entry_support.mdk`), so
`./medaka_emitter … > out.ll || die` fires. Until 2026-07-17 all of them exited **0** with **empty
stdout**, which handed a redirecting harness an empty artifact + apparent success — the same for a
**nonexistent input file** or a **real typecheck error**, not just a wrong arity. `medaka build
--keep-ir` remains the supported route.

**Playground e2e:** `playground/e2e/` is a Playwright harness driving a real browser against
the built CM6 playground (`cd playground/e2e && ./run.sh`). Needs **node v24+** and a
pre-built `playground/dist/playground.wasm`; uses the **system** Chrome. See
`playground/e2e/README.md`.

## Traps

Each of these was paid for in an incident. **They are pointers, not post-mortems** — the
narrative lives at the link.

- ⚠️ **Changing the emitter? Read the `benchmark-emitter` skill BEFORE measuring anything.**
  A binary's *behavior* comes from its source but its *speed* comes from the emitter that
  compiled it, so you need **two** rebuilds to get a single-generation binary. One rebuild
  crosses the arms and makes an optimization look like a regression (a real 2.2× win once
  measured as a 2.5× slowdown). Same skill covers seed re-mints — `test/refresh_seed.sh` is
  **not idempotent after a codegen change; run it TWICE** — and why a **stale seed can
  SEGFAULT the fixpoint on a perfectly correct change**.
- ⚠️ **Chasing a slow stage or a red `perf_scaling`? Read the `perf-hunt` skill.** Profile
  **allocation** (deterministic) over wall-clock (noisy); use **DWARF** call graphs; and note
  `whenL False (expensiveCall …)` is **NOT a stub** — Medaka is strict, so the argument still
  evaluates (this produced a false "hypothesis disproved" on a *correct* hypothesis).
- ⚠️ **A dispatch bug that reproduces through the loader but is green single-file is
  *usually* the EVAL DRIVER, not dict-passing** (recurred at Phases 96/103/121/125). **But
  verify — Phase 134 was the documented inverse**, and the two-probe comparison did *not*
  flag it. Full method, both probes, and the instrument-the-resolution-arms technique:
  **`debug-pipeline` skill**. Regression tests for this class must exercise the multi-module
  path (`test/diff_compiler_eval_modules.sh`), not a single-file doctest.
- ⚠️ **`evalModules` (`eval/eval.mdk`) and `cevalModules` (`ir/core_ir_eval.mdk`) are PARALLEL
  module drivers — fix module-frame semantics in LOCKSTEP.** `cevalModules` deliberately
  mirrors `evalModules` (same frame layout, same `importFrameOf`/`pubReexports`/`installConsts`
  helpers), so a fix to one is **silently absent from the other**. That is how the P0-9
  cross-module ctor-collision fix shipped patching only `eval.mdk`, leaving `core_ir_eval.mdk`
  broken for months. Underlying hazard: **`installConsts` + `findCell` is last-write-wins on
  duplicate names**, so any flat frame keyed by *bare name* across modules inherits it (e.g.
  `map`'s arity-5 `Bin` vs `set`'s arity-4 `Bin` collapse into one cell). The fix shape is a
  per-module **local** ctor frame that shadows the global.
- ⚠️ **A FIXTURE DIRECTORY IS A SHARED CORPUS.** Adding, moving, or deleting a fixture
  silently enrolls (or de-enrolls) you in gates you never named. Before touching one,
  **ENUMERATE every consumer, then run all of them.**
  ⚠️ **Do not trust any count — including this sentence — and WORD-BOUND your grep.** Both
  halves of that matter, and this bullet has been wrong in both directions:
  - It used to say `test/wasm/fixtures/` had *"four"* consumers. That was wrong (it missed
    `diff_compiler_prelude_obj.sh`). A **"correction" to eight was also wrong** — a naive
    `grep -rl 'wasm/fixtures' test/` matches the **real sibling corpora**
    `test/wasm/fixtures_typed/` (9 files) and `test/wasm/fixtures_modules/` (36), which
    `diff_wasm_typed.sh`/`diff_wasm_modules.sh`/`build_wasm_cmd.sh` read *instead* of this
    directory. **The true count is five.** ⚠️ `test/preflight.sh` (grep `Word-boundaries`)
    already solves this — *"Word-boundaries on both sides so `llvm_fixtures` cannot match
    `llvm_fixtures_modules`/`llvm_fixtures_typed` (real sibling corpora in this tree)"* — so
    bound your pattern the same way, or the recipe this bullet hands you lies to you.
  - **That two successive "verified" recounts each produced a different wrong number is the
    point**, not an embarrassing footnote: a count is an encoded fact with no derivation and no
    expiry, while the enumeration is one command away. Write the command, never the number. An
    agent obeying a count literally runs a subset and believes it was exhaustive — the count
    manufactures the very confidence this warning exists to prevent. It is *"check the SET, not
    one member"* failing inside the sentence that teaches it.

  Cautionary example, not a list to trust: `test/eval_modules_fixtures/*/` feeds
  `diff_compiler_eval_modules.sh` **and** `diff_compiler_core_ir_modules.sh` — **P0-9 shipped
  "green" having run only the first.** ⚠️ Also note `test/wasm/diff_wasm.sh` and its `test/wasm/`
  siblings (`diff_wasm_typed.sh`, `diff_wasm_modules.sh`, `diff_sqlite.sh` — all wired directly in
  `ci.yml`) live in the `wasm/` subdir, **not** beside the other gates; assuming the flat path cost
  an agent two failed invocations on 2026-07-16.
- ⚠️ **The compiler's own sources are IN the snapshot corpus, so a source change MOVES ITS
  OWN GOLDEN. Bless it in the SAME commit.** Push the source without the golden and `main`
  goes red, and the hook then forces the *next* agent to bless a file they never touched —
  the exact "rubber-stamp someone else's regression" hazard blessing exists to prevent. Bless
  by NAMING the path; `--bless` refuses to rubber-stamp a whole corpus.
  ⚠️ **Bless via the GATE, not the CLI:** `sh test/diff_compiler_snapshot_<suite>.sh --bless <path>`
  (e.g. `…_frontend.sh`, `…_eval.sh`, `…_types.sh`). **`medaka snapshot --bless <compiler source>`
  is a dead end** — it looks for the `.md` next to the source and fails with *"no snapshot …
  `--bless` never creates one — run `medaka snapshot --new` first"* (exit 1). Two agents lost time
  to this on 2026-07-16 because this bullet said *what* to do and never *which command*.
- **The compiler MAY import `stdlib/`** — deliberately, per module (policy changed
  2026-06-29; the old blanket ban is retired). **Weigh it per module, don't import
  reflexively.** Measured:
  - Importing a module whose types' instances live in `core` (the always-present prelude) is
    **near-free** — `import list`/`import string` drag no new instance surface, so DCE trims
    to the referenced standalone fns (**−256 B, +2% ≈ noise**).
  - Importing a module that defines a **NEW type** is not: DCE keeps every `DImpl`/`DInterface`
    *whole* (runtime dict-passing → pruning an impl would be a silent miscompile), so
    `import map` drags `Map`'s entire Eq/Ord/Debug/Display/Mappable/Monoid surface in
    (**+34 KB binary, +4.8% self-compile**).
  - ⚠️ **Anti-pattern (measured): do NOT delegate the compiler's hot monomorphic helpers to
    prelude Foldable methods** (`elem`/`any`/`all`/`length`). They lose `||`/`&&`
    short-circuiting and become dict-passed fold+closure — doing this to `util.mdk`'s hottest
    helpers cost **+56% self-compile.** Keep hot inner-loop helpers monomorphic and
    short-circuiting.
  - Also: the imported module is re-typechecked on every compile *and* every fixpoint
    iteration; and once the compiler imports a stdlib module, any change there that perturbs
    emitted IR **forces a seed re-mint + fixpoint re-validation** (a feature — it converts
    silent `support/`-vs-`stdlib/` divergence into a build-time gate — but it is churn).
  - Migrating a `support/` structure to stdlib: a **polymorphic empty must be a nullary
    constructor** (a constructor *application* like `OMap Tip` is NOT generalized → it
    monomorphises → "Scheme vs Unit" cascades). Any harness running the emitter/probes over
    compiler source must pass `$STDLIB` as well as the compiler root.
- **Tuples are internally `__tupleN__`-headed `TApp` spines, not a `TTuple` node.**
  `(,)`/`(,,)`/`(,,,)`/`(,,,,)` in TYPE position names the bare *unsaturated* tuple
  constructor — that is what lets a higher-kinded typeclass bind to it (`impl Bimappable (,)`
  in `core.mdk`). A saturated `(a, b)` head is kind-inconsistent and deliberately unsupported.
  See `compiler/TUPLE-TYPE-CONSTRUCTOR-DESIGN.md`.
- **Errors accumulate.** Phases push into `compiler/driver/diagnostics.mdk` rather than
  raising on the first error. **Don't add early-exit/raise paths.**
- **To run a whole program, `main` must be a zero-arg value** (`main = …`, not `main () = …`).
  `medaka run` evaluates top-level bindings and checks `main` exists but never *applies* it,
  so `main () = …` is a silent no-op (exit 0, no output). Use `main = println …` for probes.
- **Medaka multi-arg lambdas are `x y => body`**, not curried `x => y => body`. Curried forms
  predating Phase 59.6 are legacy artifacts — match `x y => body` in new code.
- **The prelude is marked + dict-passed in the typed pipeline** (`markWithPrelude`,
  `compiler/frontend/marker.mdk`), so elaboration reaches prelude methods like
  `pure`/`when`/`unless`. **Untyped eval** (no marker/typecheck — e.g. quick eval tests)
  falls back to arg-tag "first impl wins" for return-position methods. `pure` needs types to
  dispatch, so **route it through the typed pipeline.**
- **Match-arm guards and refutable pattern-guards (`Pat <- e`) both lower natively and work
  in both forms.** Historically neither did; the multi-clause refutable-guard case was a
  run≠build **miscompile** until 2026-07-13 (the `__fallthrough__` sentinel read its jump
  target from a mutable Ref that `emitDecision` nulls across a body-level match — and a
  refutable guard desugars to exactly such a match, so "try the next clause" became
  `@mdk_oob`). It now carries its target in the node (`labelFallthrough`,
  `backend/emit_support.mdk`) — the design the **WasmGC backend already had, which is why
  wasm was never wrong.** Full write-up: `compiler/EMITTER-GAPS.md`.
- **In a worktree, edit the worktree's files — use the full absolute path.** The shell cwd
  resets to the main checkout each call, so a relative `grep -n compiler/foo.mdk` runs
  *there*; Read/Edit that bare path and you have silently changed the **main checkout**,
  which your worktree build never sees. If you slip: `cp` the edited files into the worktree,
  then `git -C <main> checkout -- <files>`.
- **Every worktree shares ONE `.git`, so `origin/main`/`main` move under you** — a sibling's
  `git fetch` advances the ref mid-task with no signal to you. Pin `BASE=$(git rev-parse HEAD)`
  at the start of a task and diff/checkout against `$BASE`, never a moving ref. Full failure
  modes + the pinned-`$BASE` recipe: `.claude/workstreams/HARNESS.md` (H-2).
- **For layout questions** (legal indentation shapes, leading-op set, then/else, tabs,
  let…in wrapping), `docs/spec/LAYOUT-SEMANTICS.md` is ground truth. Its §12 conformance
  contract is scoped to the **lexer's token stream only**: a lexer-vs-spec divergence is a
  lexer bug; a SYNTAX/PLAN-vs-spec divergence is a doc bug. A construct the spec licenses
  that the lexer heralds correctly but the **parser** still can't consume is a parser bug,
  not a lexer bug — don't generalize the rule that far (§12 item 5).
- Development is organized by numbered **Phases**. Open work: `PLAN.md`. Completed Phases
  1–97 with implementation notes: `archive/PLAN-ARCHIVE.md`. Commits reference phase numbers.

## Dogfooding the language

The stdlib and `compiler/` are written *in* Medaka, so prefer its idioms — but **only where
they genuinely improve readability**. Don't force-fit: most candidate sites aren't
improvements, and a rewrite that doesn't typecheck or that changes semantics is worse than
the original. **Verify the rewrite on the binary** (`medaka test <file>`).

Under-used but working: **operator sections** — `(==)`, `(+ 1)`, `(2 * _)` (left needs an
explicit `_`) instead of lambdas; pipe `|>`; compose `>> <<`; inclusive ranges `[lo..=hi]`;
record update `{ r | f = v }`; unary `!`.

⚠️ **Do NOT reach for these — they are REMOVED and are hard parse errors**, each with a
dedicated removal diagnostic in `compiler/frontend/parser.mdk`: the **`function` keyword**
(use `x => match x` with indented arms, or a multi-clause definition), **`let mut`** (use a `Ref`:
`let x = Ref 0`, `x := v`, read `x.value`), **backtick infix** `` `f` `` (use prefix
application), the **`record` keyword**, **`let-else`**, **named impls**, and **`default
impl`**. `test/check_removed_constructs.sh` is the tree-wide gate that keeps them out.

`docs/spec/SYNTAX.md` is the ground-truth list of what parses (⚠️ with one known lie: it
still lists backtick infix, which the parser rejects). `test/parse_fixtures/rare_constructs.mdk`
has minimal examples. The self-hosted parser doesn't cover everything — see PLAN.md "Known
parser gaps" before assuming `compiler/` can parse a construct.

## Writing tests

Tests are shell-based golden-diff harnesses: each `test/diff_compiler_*.sh` runs a native
pipeline stage against goldens in `test/*_fixtures/` or `test/*_goldens/`.

1. Add a fixture to the appropriate `test/` fixture directory (⚠️ first read the
   shared-corpus trap above).
2. Capture a golden: `bash test/capture_goldens.sh`, or the specific gate with `CAPTURE=1`.
   Narrower forms: `sh test/capture_goldens.sh <suffix-tag>` (e.g. `eval`) recaptures only
   that family; `sh test/capture_goldens.sh --check` dry-runs — re-derives and diffs against
   the committed goldens without writing anything.
3. Verify: `bash test/diff_compiler_<name>.sh` passes.

Add cases to the gate matching the stage you changed (parser change →
`test/diff_compiler_parse*.sh` or `diff_compiler_check*.sh`).

## Task playbooks (skills)

**Skills are planning inputs, not just implementation aids.** At task triage — including
during plan-mode exploration, *before* writing the plan — match the task against this table
and load the matching skill rather than re-deriving the workflow. (A `UserPromptSubmit` hook,
`.claude/hooks/skill-triage.py`, nudges this on PLAN.md/Phase prompts.)

| Skill | When |
|-------|------|
| **add-language-feature** | Thread a new construct through the whole pipeline. **Also the right skill for most cross-cutting work that *looks* like typechecking** — see below. |
| **add-primitive** | Add/modify a stdlib `extern` primitive (native, in `compiler/eval/eval.mdk`). |
| **extend-stdlib** | Implement/extend a *pure-Medaka* stdlib function, impl, doctest, or prop. Not for externs. Normally user-reserved; load when asked. |
| **debug-pipeline** | Diagnose a parse/typecheck/eval failure. **Reach here first for a dispatch bug that reproduces through the loader but works single-file.** |
| **harden-typechecker** | Typechecker-*internal* work: add a `type_error`, tighten constraint/coherence/unification logic. |
| **perf-hunt** | A stage is slow, or `diff_compiler_perf_scaling.sh` is red. Find the O(n²). |
| **benchmark-emitter** | ANY change to `compiler/backend/*` you intend to measure, or a fixpoint failure on a change that looks correct. |
| **add-lsp-capability** | Add/extend an LSP feature. |
| **pr-review** | Review an agent-authored PR diff for craft. Read-only; run AFTER CI is green. |
| **bug-hunt** | Adversarially hunt lurking S0/S1 bugs: derive hot veins from the tracker, fan out isolated-worktree subagents by subsystem, verify first-hand, file deduped issues with self-draining pins. Best run right after a batch of S0/S1s is closed. |

⚠️ **`harden-typechecker` is narrower than it looks.** Adding a `type_error` does NOT by
itself make a task typechecker-internal. If the fix threads through resolve/eval/desugar/AST
*as well*, it is **add-language-feature** — that was true of Phase 69 (dispatch), Phase 63
(`deriving`, desugar-rooted), Phase 72 (field-name reuse: added a type_error, but the bulk was
a multimap threaded through resolve *and* typecheck), Phase 73 (bidirectional checking), and
Phases 83/84 (dict-threading through AST + typecheck + dict_pass + eval). **Check where the fix
actually lands before loading it.**

## Doc index

**`docs/README.md` is THE doc index** — generated from every doc's own `**Status:**` banner
(`make docs-index`), so it cannot drift. Go there for the full catalog. The rows below are
only the ones an agent reaches for constantly.

| Doc | What's in it |
|-----|--------------|
| `README.md` | Full build/test/CLI usage, editor setup, layout |
| `docs/spec/SYNTAX.md` | Cheat-sheet of every construct the **current binary** accepts. Reach here first for "does X parse" — faster than reading `parser.mdk`. Ground truth over `language-design.md` |
| `docs/spec/LAYOUT-SEMANTICS.md` | Offside-rule layout spec — formal ground truth for layout work |
| `docs/spec/language-design.md` | Design & semantics (intent/rationale — may describe unimplemented features) |
| `PLAN.md` / `archive/PLAN-ARCHIVE.md` | Open roadmap / completed Phases 1–97 + notes |
| `compiler/BOOTSTRAP.md` | Self-compile log: B1–B7 (each stage native==interpreter) + C1–C3 (fixpoint) |
| `compiler/EMITTER-GAPS.md` | Native emitter gap census (E-series), closed + residual |
| `compiler/ERROR-QUALITY.md` | Error-message rubric. Read before writing/changing a diagnostic |
| `compiler/DIAGNOSTIC-CODES-DESIGN.md` | Stable diagnostic code taxonomy + the `Diag` JSON contract. Add new codes here |
| `compiler/PERF-RESULTS.md` / `PERF-SCOPE.md` | Measured perf log (+ every dead end) / ranked hot paths. Harness: `test/bench.sh` |
| `compiler/STAGE2-DESIGN.md` / `RUNTIME-DESIGN.md` | Native backend design: Core IR seam, value rep, GC, per-extern disposition |
| `docs/stdlib/STDLIB.md` / `stdlib/README.md` | Stdlib module plan / conventions for adding externs |
