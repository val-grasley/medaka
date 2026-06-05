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

### 2026-06-04 — match_pat List.compare_lengths (target #3 interpreter, depth)
- cmd: `sh test/diff_selfhost_check_modules.sh` ; entry `main.exe run check_modules_main.mdk runtime.mdk core.mdk selfhost/parser.mdk selfhost`
- **Re-profiled the check_modules parser entry AFTER the env-Hashtbl win.** Hotspot
  moved: ~52% still in List.assoc_opt but now via `search_644` (env `lookup`)
  scanning small per-call FList frames MANY times — NOT big frames. ~17% in
  `match_pat → List.length_aux` (PCon/PTuple/PList arms doing two full length
  traversals per match). Remainder spread: Hashtbl hashing (50+42), caml_modify, GC.
- **Attempt A — adaptive FList/FTable frames (threshold 6, then 2): REVERTED.**
  No help at 6 (2.36s vs 2.35s); threshold 2 was *worse* (2.42s — Hashtbl build
  overhead on many tiny per-call frames). **Confirms the FList scans are small
  frames hit often, so the lever is lookup COUNT/constant, not frame size.** The
  env-Hashtbl commit already covers the big frames; per-call frames belong as FList.
- **Attempt B — match_pat `List.compare_lengths` instead of `length = length`: WIN.**
  Walks both lists once in lockstep, early-stops; semantically identical.
- before: 17.07s (full) / 2.29s (entry)   after: **15.60s / 1.99s**  (**~9% / ~13%**)
- correctness: test_eval/run/loader/repl/doctest green; mark+desugar byte-identical; check_modules 12 ok.
- committed: 1d0d8fe
- **Next lever (measured, not yet attempted):** env `lookup` still ~half the time,
  scanning small FList frames repeatedly + Hashtbl string-hashing on globals. The
  per-lookup constant is the cost. Candidate: speed the EVar hot arm itself, or
  cut lookup count, or intern names→ints to kill string hashing/compare. Harder.

### 2026-06-04 — env-lookup residual: 3 attempts, NEEDS DEEPER REWORK (move on)
Re-profiled the check_modules parser entry after compare_lengths. `match_pat`
length cost gone (~7 samples). Residual top is env `lookup` (search_644 +
assoc_opt FList scans + Hashtbl find_opt/key_index/hash on globals) ≈ ~28% +
`caml_alloc_small` ~21. Three attempts to cut it, all REVERTED (verify-or-revert):
- **A. adaptive FList/FTable frames** (threshold 6, 2): flat / worse. Small frames.
- **B. skip empty `extend`** (PWild/literal binds): flat (2.02 vs 1.99s) — empty
  binds too rare on this path; the match guard offsets any gain.
- **C. spine-collect + coalesce a saturated call's n param-frames into 1**
  (order-safe, arity m≥n guard, no VClosure type change): **REGRESSED** 1.99→2.20s
  (entry), 15.60→16.92s (full). The collect_spine/compare_lengths/rev_append
  machinery runs on EVERY EApp — most parser applications are single-arg (curried
  combinators), so the per-application overhead dwarfs the multi-arg frame-walk
  savings. Coalescing only pays if you can detect arity *without* per-call spine
  work — i.e. resolve-time arity annotation.
- **Conclusion:** the residual is the per-variable-reference cost of a by-name
  environment. Cutting it needs a STRUCTURAL change — slot-indexed / De Bruijn
  env: a resolve pass annotates each EVar with (depth, index) so lookup is array
  indexing, no string hash/compare and no frame walk. That threads resolve.ml →
  ast.ml → eval.ml and is too big/risky for an unattended single unit. Filed as
  the single most promising un-attempted lead (see top summary at STOP_AT).
- **Redirect:** next units target ALGORITHMIC wins in the self-hosted compiler
  (.mdk), like the Tarjan win — PERF-NOTES backlog #2 candidates (registerAllData
  O(modules×data) re-registration; cross-entry re-typecheck) live in typecheck.mdk
  and don't touch the interpreter.
- committed: no code change (all attempts reverted); log only.

### 2026-06-04 — batch check_modules harness (backlog #2c, harness win)
- cmd: `sh test/diff_selfhost_check_modules_batch.sh`  (vs original `..._check_modules.sh`)
- **#2b registerAllData: RULED OUT by sizing + profile.** accData accumulates only
  ~30 public data decls (ast) + a handful; ~150 registerData calls total across a
  closure vs millions of per-node inference eval-steps. Never appeared in the
  sample. O(M²·D) is real but negligible — not worth the threading change.
- **#2c cross-entry re-typecheck: WIN.** Original ran 12 processes, each emitting
  only the ENTRY module's schemes while re-typechecking shared deps up to 12×.
  Verified the key invariant empirically: every module in `check`'s 8-module
  closure is byte-identical to its standalone tc_module_probe oracle (schemes
  depend only on the dependency-closure, which precedes them in topo order).
- New `checkModulesAllLines` (typecheck.mdk) emits all closure modules with
  `## MODULE <mid>` markers; `check_all_main.mdk` driver; batch harness runs a
  5-entry covering set {check,eval,loader,sexp,marker} and diffs each target's
  section vs the same oracle. (check.mdk exports nothing → can't fold into one
  synthetic entry; a synthetic-11 + check run measured ~9s, WORSE than the 5-run
  8.8s because the check run unavoidably re-types its 8 deps.)
- before: 15.60s   after: **8.80s**  (**1.77×**)
- correctness: 12 ok, 0 failing — byte-identical per-module, same as original;
  mark+desugar 92 matched, 0 differing. Original harness kept alongside.
- committed: 7ac547d
- **Remaining redundancy (next lever):** the 5 runs still re-typecheck ast/lexer/
  parser across closures. A true single-pass (one process emitting all 12) needs
  either check.mdk to export a name (so a synthetic entry can pull it in → 1 run)
  or a multi-root loader. Could push ~8.8s → ~5.5s.

### 2026-06-04 — single-pass batch check_modules (1 process)
- cmd: `sh test/diff_selfhost_check_modules_batch.sh`
- Collapsed the 5-entry batch to ONE process: synthetic `all_modules_entry.mdk`
  imports one name from every selfhost module → loadProgram unions all 12 into a
  single closure → one check_all_main run emits all 12 sections; every shared
  module typechecked exactly once. Needed a 1-line `export runCheck` on check.mdk
  (inert — schemes emitted regardless of visibility) so the synthetic entry can
  pull check into the closure.
- before: 8.80s (5-entry batch) / 15.60s (orig)   after: **5.37s**  (1.64× / 2.9×)
- correctness: 12 ok, 0 failing byte-identical; mark+desugar 93 matched, 0 diff;
  original harness still 12 ok.
- committed: a34326b
- **check_modules journey: 1515s → 300.5s (Tarjan) → 17.07s (env-Hashtbl) →
  15.60s (compare_lengths) → 5.37s (single-pass batch). ~282× from origin.**

### 2026-06-04 — mark_batch harness shell quadratic + match_pat alloc (reverted)
- **LOCATE:** mark_batch 9.80s decomposed: self-hosted mark PROCESS 6.66s (min-3),
  astdump oracle loop 0.32s, **shell comparison loop ~2.9s**. (Gotcha: the Bash
  tool runs ZSH which doesn't word-split unquoted vars — manual `$list` glob runs
  failed/`File name too long`; wrap corpus-glob timing in `sh -c '...'`.)
- **Mark process profile:** match_pat_1042 79, search_644 68, assoc_opt 48,
  find_opt 33, caml_alloc_small 30. Match-heavy (parser/marker dispatch).
- **Attempt — match_pats/PRec O(k²)→O(k) bind-list build** (`b @ binds` not
  `binds @ b`; `(f,v)::bs` not `bs @ [(f,v)]`; safe: linear patterns, unique keys):
  byte-identical but FLAT (mark 6.69 vs 6.66; check_modules_batch 5.45 vs 5.37;
  parser desugar 0.74 vs 0.78). Constructors are narrow (2-4 fields) so k² vs k is
  noise; the 79 match_pat samples are DISPATCH, not allocation. **REVERTED.**
- **Win — mark_batch harness shell loop:** `section()` awk re-scanned the whole
  combined output per corpus file (quadratic). Split once into per-file section
  files in a single awk pass; loop reads its small file.
- before: 9.80s   after: **7.61s**  (~1.29×, ~2.2s of shell quadratic removed)
- correctness: 93 matched, 0 differing.
- committed: 41f1095
- **Note:** other *_batch harnesses (check_batch 1.13s, resolve_batch 0.37s) use
  the same section() pattern but are tiny — quadratic there is negligible, skip.
  The mark PROCESS residual (6.66s) is match_pat/env-lookup interpretation = the
  parked slot-indexed-env structural lever.

### 2026-06-04 — batch desugar harness (backlog #1, RE-OPENED)
- cmd: `sh test/diff_selfhost_desugar_batch.sh`  (vs original `..._desugar.sh`)
- Backlog #1 originally concluded "batching won't help desugar — per-file parse
  of big selfhost files dominates." That was measured pre-env-Hashtbl (parser.mdk
  desugar was 13.43s then). AFTER the env-Hashtbl win (parser 0.74s), per-file is
  cheap and the ~92× per-process module-load overhead dominates → batching DOES
  help now. (Lesson: a measured finding can expire when an upstream win changes
  the calculus — re-test backlog items after big wins.)
- selfhost/desugar_batch.mdk (load parser/desugar/sexp once, loop files,
  `===SELFHOST-DESUGAR===` sections) + batch harness with single-pass awk split.
- before: 9.43s   after: **6.11s**  (1.54×)
- decomposed: batch desugar process 5.20s (real interpretation), astdump oracle
  loop 0.34s, ~0.57s shell. Fixed per-proc overhead was ~0.04s/proc (×92 ≈ 3.3s
  saved), not the 0.10s I'd estimated (that included the tiny file's own work).
- correctness: 94 matched, 0 differing; mark_batch 94 matched (new .mdk parses).
- committed: 0521899
- Residual 5.20s = per-file desugar interpretation (parser/typecheck/eval bodies)
  = the parked slot-indexed-env structural lever.

### 2026-06-04 — parser is LINEAR (algorithmic O(n²) ruled out) + String-Hashtbl win
- **Parser scaling test (self-hosted parse, per-line cost):** 956 lines 0.46s
  (0.00044/ln) → 1527 0.63s (0.00039) → 1759 0.67s (0.00036) → 2419 0.73s
  (0.00029). Per-line cost DECREASES with size ⇒ linear/sub-linear, **no O(n²)**.
  The "self-hosted parser hottest" cost is linear interpretation, not an
  algorithmic bug — no Tarjan-style win available there. (Hypothesis ruled out.)
- **Win — Hashtbl.Make(String) for env FTable.** Polymorphic Hashtbl compared
  string keys via generic caml_equal→compare_val→memcmp; String.equal is direct.
  Rigorous back-to-back A/B (check_modules_batch min-of-5): 5.43s → **5.25s**
  (~3.3%, every with-change run below every baseline run). hash kept Hashtbl.hash.
- correctness: all suites green; mark/desugar/check_modules batches byte-identical.
- committed: 10e99eb
