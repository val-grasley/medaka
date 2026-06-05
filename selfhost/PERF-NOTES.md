# Self-host performance notes & log

Living record of performance work on the self-hosted compiler (`selfhost/*.mdk`)
and its diff harnesses (`test/diff_selfhost_*.sh`). **Append measurements and
findings to the Results log at the bottom** — don't rewrite history, add to it.

The harnesses run the OCaml interpreter (`lib/eval.ml`, a tree-walker) over the
self-hosted compiler. So "slow" almost always means *interpretation overhead*,
not OCaml. Baseline reality check: OCaml's own `check` of the whole self-hosted
program is ~0.05s; a self-hosted parse of `core.mdk` (1003 lines) is ~4.4s.

## Methodology (read this — it is the whole game)

1. **MEASURE/PROFILE before hypothesizing.** During the work that produced this
   file, the hotspot was guessed wrong *twice* (env-lookup O(n²); `normalize`
   Link chains — chains turned out to be length 2). Reasoning about hot paths is
   unreliable here. Use `sample` + counter instrumentation. The binary arbitrates.
2. **min-of-3 wall-clock** for every timing; record the exact command. Contention
   and GC only ever inflate, so the minimum ≈ true cost.
3. **Correctness gate after EVERY change.** Re-run the relevant harness and
   confirm it still passes / output is byte-identical *before* moving on. Revert
   anything that doesn't verify or doesn't measurably help.
4. **Keep `selfhost/*.mdk` self-host-parseable.** The `mark`/`parse`/`check_modules`
   harnesses re-parse the selfhost source with the *self-hosted* parser. After
   editing a selfhost module, run `diff_selfhost_mark_batch.sh` (parses+marks all
   of `selfhost/*.mdk`). Gotcha: `then`/`else` can't start a line — write
   `if c then x else y` inline. Multi-arg lambdas are `x y => body`.

## How to run things

```sh
export PATH="$HOME/.opam/5.4.1/bin:$PATH"     # if `dune` is not found
dune build --root .                            # in a worktree, --root . is required

# a harness (fast batch variant where one exists, else the original):
sh test/diff_selfhost_check_modules.sh
sh test/diff_selfhost_mark_batch.sh

# a single check_modules entry (module as entry + its transitive imports):
./_build/default/bin/main.exe run selfhost/check_modules_main.mdk \
    stdlib/runtime.mdk stdlib/core.mdk selfhost/<mod>.mdk selfhost
# its OCaml oracle (compare sorted):
./_build/default/dev/tc_module_probe.exe selfhost/<mod>.mdk selfhost

# sample-profile a running interpreter (macOS; flat in eval_1221 = pure interp):
./_build/default/bin/main.exe run <args> >/dev/null 2>&1 & PID=$!
sleep 20; sample $PID 15 -file /tmp/prof.txt; kill $PID
```

**Do NOT run `dune test`** (it can hang). Run individual `./_build/default/test/test_<name>.exe --compact`.
`dune build @thorough` runs the exhaustive suites.

## What's already done (don't redo)

- **check_modules: 1515s → 300.5s (5.0×).** Replaced `processTopGroups`' O(n³)
  letrec dependency analysis (all-pairs reachability + mutual-reachability SCC +
  topo) with a linear **Tarjan SCC** in `typecheck.mdk`. (loader entry 367→40s.)
- **TcEnv uses a vendored persistent weight-balanced tree (`SMap`)** instead of an
  assoc list — measured ~12% on the biggest closure once Tarjan removed the cubic.
  Selfhost can't `import map` (loader root only sees `selfhost/`), so it's vendored.
- **eval harness 78.6s → 4.4s.** `test/eval_fixtures/letrec_mutual.mdk` `collatz 27`
  → `collatz 7` (27 peaks at 9232 under O(n) unary isEven/isOdd → ~75s).
- **Prelude-caching `*_batch.mdk` drivers/harnesses** for 9 prelude-dominated
  stages: parse the prelude once, loop fixtures in one process. ~710s saved.

## Baseline (single runs this session — RE-BASELINE min-of-3 before trusting)

| Harness | orig | best now | how |
|---|--:|--:|--|
| check_modules | 1515 | **300.5** | Tarjan (in place) |
| mark | 443 | 109 | `_batch` |
| eval_run | 125 | 17.5 | `_batch` |
| typecheck_golden | 103 | 28 | `_batch` |
| **desugar** | **97** | **97** | **UNTOUCHED — open target** |
| check | 146 | 28.7 | `_batch` |
| eval | 79 | 4.4 | fixture fix (in place) |
| resolve | 42 | 5.1 | `_batch` |
| eval_dict/prelude/list/typed | ~78 | ~37 | `_batch` |
| lex_files / parse / typecheck / lexer / exhaust | ~15 | ~15 | fast, untouched |

Fast path (batch variants + in-place wins) ≈ **11 min**, down from ~44 min.
Note: `_batch` harnesses are *separate* files kept alongside the originals.

## Target backlog (ranked; each is a HYPOTHESIS TO TEST, not a conclusion)

1. **`desugar` harness (~97s, 81 invocations).** The only un-optimized
   prelude-free stage. TEST: time desugar on the smallest vs largest fixture. If
   per-process fixed overhead dominates → a `desugar_batch.mdk` helps (mirror the
   others). If per-target parse of big selfhost files dominates → batching won't,
   and it's an interpreter problem.
2. **`check_modules` residual (300s).** Re-`sample` the biggest entry (`check`,
   `parser`). Candidate costs to MEASURE/instrument, not assume: (a) base HM
   inference ~5ms/line, pure interpretation; (b) `registerAllData` re-registering
   accumulated `accData` per module (O(modules × data)); (c) cross-entry
   re-typechecking — `checkModulesGo` already computes schemes for *every* module
   in a closure but the driver emits only the entry's; could ~5 runs cover all 12?
   (needs a safety check: are a module's schemes context-independent across
   closures? watch the resolve/eval `Env` name clash.)
3. **`eval.ml` tree-walker (deepest lever, highest ceiling).** ~26ms/line of
   *everything* is interpretation. Profile `eval_1221` hot paths (by-name frame
   lookup, closure application, pattern matching). Any constant-factor win here
   multiplies across every harness. Hardest; verify with the full eval/run suites.
4. **typecheck env/instantiate.** SMap env gave 12% — are there other O(n) env
   ops (instantiate/freshSubst copying large types, registerAllData)? Instrument.
5. **Promote `_batch` variants to canonical?** Product/coordination decision, not
   perf — leave a recommendation, don't act on it unattended.

## Results log (append-only)

<!-- Template — copy per measurement:
### YYYY-MM-DD — <target>
- cmd: `<exact command>`
- before: <min-of-3>  after: <min-of-3>  (Nx)
- correctness: <harness> <pass/byte-identical?>
- finding: <one line>
- committed: <sha or "reverted: didn't verify / no win">
-->

### 2026-06-04 — env frames: assoc-list → Hashtbl (target #1 desugar + target #3 interpreter)
- cmd (full): `sh test/diff_selfhost_desugar.sh` ; (single): `main.exe run selfhost/desugar_main.mdk selfhost/parser.mdk`
- **Target #1 finding (desugar batchability):** fixed per-process overhead is only
  ~0.10s (smallest 2-line fixture, min-of-3); the largest file (parser.mdk, 2419
  lines) was 13.43s. So desugar's ~97s is NOT process startup — a `desugar_batch`
  would save ~8s at most. The cost is per-file interpretation. **Batching ruled out;
  it's an interpreter problem.** → pivoted to profiling the interpreter (#3).
- **Profile (sample, desugar parser.mdk):** ~87% of samples in
  `Stdlib.List.assoc_opt → caml_compare → compare_val → memcmp`. The OCaml eval
  env was `(string*value ref) list list`; every var lookup linearly scanned each
  frame with string compares. The bottom global/prelude frame holds 600-1000+
  bindings → every global-name reference paid a long scan. (Distinct from the
  self-hosted TcEnv already fixed with SMap — this is the OCaml interpreter's env.)
- **Fix:** frame = variant `FList` (assoc, tiny per-call frames) | `FTable`
  (Hashtbl, the big global/module frames). Key set is frozen after prealloc so a
  Hashtbl snapshot shares cell refs safely; `table_of_assoc` keeps assoc_opt
  first-wins. Touched lib/eval.ml (+ prop_runner/bench_runner/bin-main env builds).
- before: 13.43s (parser.mdk) / ~97s (full)   after: **0.78s / 9.67s**  (**17.2× / ~10×**)
- correctness: desugar + mark harnesses byte-identical (91 matched, 0 differing);
  test_eval/run/loader/repl/doctest/snapshot/coverage/typecheck/resolve/parser/diagnostics all exit 0.
- committed: f06727c
- **NOTE: this is a global interpreter win — re-baseline EVERY other harness next**
  (check_modules 300s, mark 109s, eval_run, typecheck_golden, etc. all run through
  `medaka run` → eval_modules → same hot lookup). Expect broad speedups.

### 2026-06-04 — RE-BASELINE after env-Hashtbl win (global propagation confirmed)
The env frame Hashtbl change (commit f06727c) propagated to EVERY `medaka run`
harness. All min-of-2/3, all correctness-clean (matched/ok, 0 differing/failing):

| Harness | prev best | NOW | speedup |
|---|--:|--:|--|
| **check_modules** | 300.5 | **17.07** | **17.6×** |
| mark_batch | 109 | 11.07 | ~10× |
| eval_run_batch | 17.5 | 1.03 | ~17× |
| typecheck_golden_batch | 28 | 0.91 | ~31× |
| check_batch | 28.7 | 1.13 | ~25× |
| resolve_batch | 5.1 | 0.37 | ~14× |
| eval_dict_batch | ~37 | 0.50 | ~74× |
| eval_list_batch | ~37 | 0.54 | — |
| eval_prelude_batch | ~37 | 0.43 | — |
| eval_typed_batch | ~37 | 0.41 | — |
| desugar (full) | 97 | 9.67 | ~10× |

Whole fast-path suite is now a few minutes (was ~11 min batched / ~44 min orig).
**check_modules is once again the single biggest harness (17s)** — it's the next
profiling target. (No code change this unit; verified measurement.)
