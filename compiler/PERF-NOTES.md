# Self-host performance notes & log

Living record of performance work on the self-hosted compiler (`compiler/*.mdk`)
and its diff harnesses (`test/diff_compiler_*.sh`). **Append measurements and
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
4. **Keep `compiler/*.mdk` self-host-parseable.** The `mark`/`parse`/`check_modules`
   harnesses re-parse the compiler source with the *self-hosted* parser. After
   editing a compiler module, run `diff_compiler_mark_batch.sh` (parses+marks all
   of `compiler/*.mdk`). Gotcha: `then`/`else` can't start a line — write
   `if c then x else y` inline. Multi-arg lambdas are `x y => body`.

## How to run things

```sh
export PATH="$HOME/.opam/5.4.1/bin:$PATH"     # if `dune` is not found
dune build --root .                            # in a worktree, --root . is required

# a harness (fast batch variant where one exists, else the original):
sh test/diff_compiler_check_modules.sh
sh test/diff_compiler_mark_batch.sh

# a single check_modules entry (module as entry + its transitive imports):
./_build/default/bin/main.exe run compiler/entries/check_modules_main.mdk \
    stdlib/runtime.mdk stdlib/core.mdk compiler/<mod>.mdk compiler
# its OCaml oracle (compare sorted):
./_build/default/dev/tc_module_probe.exe compiler/<mod>.mdk compiler

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
  Selfhost can't `import map` (loader root only sees `compiler/`), so it's vendored.
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
   others). If per-target parse of big compiler files dominates → batching won't,
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

### ⭐ FINAL SUMMARY (overnight session ended 2026-06-05 ~06:10, user woke early)
**Verified wins committed this session (each its own commit, min-of-3, correctness-gated):**
1. `f06727c` **env frames assoc-list → Hashtbl** — THE big one. Var lookup was a
   linear string-compare scan; ~87% of interp time. Desugar 97→9.7s; **check_modules
   300→17s**; propagated to EVERY `medaka run` harness (10–30×).
2. `1d0d8fe` **match_pat List.compare_lengths** — check_modules 17.07→15.60s (~9%).
3. `7ac547d` **5-entry batch check_modules** harness — 15.60→8.80s.
4. `a34326b` **single-pass batch check_modules** (synthetic all-12 entry) — 8.80→5.37s (2.9× vs orig).
5. `41f1095` **mark_batch harness: split output once** (was per-file re-scan) — 9.80→7.61s.
6. `0521899` **desugar_batch** (new batch harness; #1 re-opened post-env-win) — 9.43→6.11s.
7. `10e99eb` **Hashtbl.Make(String) env frames** — ~3% (A/B 5.43→5.25s).
8. `6b6072c` **guard Coverage.record_hit at ELoc arm** — ~2% (A/B 5.28→5.17s).
9. `275b4ff` **hoist prelude scan out of mark_batch loop** (marker.markerFor) — 7.61→6.36s.

**check_modules journey: 1515s → 300.5 (Tarjan, prior) → 17.07 (env-Hashtbl) → 15.60
(compare_lengths) → 5.37 (single-pass batch). ~282× from origin.** Whole fast-path
suite now a few minutes (was ~44 min).

**Measured & ruled out / reverted (negative results — also valuable):** adaptive
FList/FTable frames (flat/worse), empty-frame skip (flat), saturated-call frame
coalescing (regressed — per-EApp spine overhead), match_pat O(k²)→O(k) bind build
(flat — narrow ctors), registerAllData O(M²·D) (#2b, negligible), parser O(n²)
(LINEAR — ruled out), mark/resolve O(n²) (LINEAR), small batch harnesses (already
amortize prelude), frame-merge (unsafe — breaks Phase-112 lookup_method),
flambda/release build (no flambda; release==dev).

**THE single most promising un-attempted lead:** a **slot-indexed / inline-cached
env** to replace the by-name lookup. Instrumented: 19.9M lookups marking
parser.mdk, **avg depth 2.80 frames, 74% local hits, 49.7M string-compares**. This
~28%-of-eval floor is the by-name environment. Removing it (resolve assigns each
EVar a (depth,index) OR a mutable inline cache on EVar) could be ~7–15%+. PARKED
for a SUPERVISED session: threads resolve.ml + ast.ml (huge blast radius) + eval.ml,
must preserve VThunk forcing, FTable globals, and Phase-112 lookup_method's
deliberate shadow-bypass; a subtle index/resolution mismatch is silent corruption
that needs interactive debugging — unsafe to land unattended.

> **UPDATE 2026-06-05 — EMIT half landed (de-risked, byte-identical).** The "huge
> blast radius" on ast.ml is sidestepped: instead of a field on `EVar`, the
> self-host AST gained a *separate* node `EVarAt String Addr` (`Addr = ALocal Int
> Int | AGlobal`), so the change is confined to `compiler/ast.mdk` +
> `resolve.mdk`. `resolve.annotateProgram` (exported, **unwired**) now emits the
> `(frame,slot)` per reference, with a framed scope mirroring `EvalEnv` exactly
> (empirically verified). The SUPERVISED part is now narrowly the CONSUME side:
> an `EVarAt` eval arm (array-frame indexing) that preserves VThunk + the
> shadow-bypass, wiring the pass into the pipeline, and the array-frame rep. The
> silent-corruption risk is now isolated to that consumer change.


<!-- Template — copy per measurement:
### YYYY-MM-DD — <target>
- cmd: `<exact command>`
- before: <min-of-3>  after: <min-of-3>  (Nx)
- correctness: <harness> <pass/byte-identical?>
- finding: <one line>
- committed: <sha or "reverted: didn't verify / no win">
-->

### 2026-06-04 — env frames: assoc-list → Hashtbl (target #1 desugar + target #3 interpreter)
- cmd (full): `sh test/diff_compiler_desugar.sh` ; (single): `main.exe run compiler/entries/desugar_main.mdk compiler/parser.mdk`
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
- cmd: `sh test/diff_compiler_check_modules.sh` ; entry `main.exe run check_modules_main.mdk runtime.mdk core.mdk compiler/parser.mdk compiler`
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
- cmd: `sh test/diff_compiler_check_modules_batch.sh`  (vs original `..._check_modules.sh`)
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
- cmd: `sh test/diff_compiler_check_modules_batch.sh`
- Collapsed the 5-entry batch to ONE process: synthetic `all_modules_entry.mdk`
  imports one name from every compiler module → loadProgram unions all 12 into a
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
- cmd: `sh test/diff_compiler_desugar_batch.sh`  (vs original `..._desugar.sh`)
- Backlog #1 originally concluded "batching won't help desugar — per-file parse
  of big compiler files dominates." That was measured pre-env-Hashtbl (parser.mdk
  desugar was 13.43s then). AFTER the env-Hashtbl win (parser 0.74s), per-file is
  cheap and the ~92× per-process module-load overhead dominates → batching DOES
  help now. (Lesson: a measured finding can expire when an upstream win changes
  the calculus — re-test backlog items after big wins.)
- compiler/entries/desugar_batch.mdk (load parser/desugar/sexp once, loop files,
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

### 2026-06-04 — mark scaling LINEAR + Coverage.record_hit guard (~2%)
- **Mark scaling test (mark_batch single file, per-line):** util→lexer→eval→
  typecheck→parser per-line 0.00051→0.00043→0.00040→0.00030. DECREASING ⇒
  resolve+marker also linear, **no O(n²)**. Entire self-hosted pipeline (parse,
  mark/resolve) is algorithmically linear — Tarjan was the only superlinear bug.
  All residual cost is linear interpretation = the parked slot-indexed-env lever.
- **Profile (mark process):** eval_1426 ~90% (env-lookup+match+apply inlined);
  collect_partials (VMulti dispatch) ~2% — inherent, risky, skip.
- **Win — guard Coverage.record_hit at the ELoc arm.** ELoc fires on ~every node
  and called the cross-module record_hit (2 field reads + call) unconditionally
  though it no-ops when coverage is off. `if !Coverage.enabled then ...` skips it.
  A/B (check_modules_batch min-of-5): 5.28s → **5.17s** (~2%, clusters disjoint).
- correctness: test_coverage green (records when enabled); batches byte-identical.
- committed: 6b6072c

### 2026-06-04 — regression sweep (8 wins insured) + mark_batch prelude-scan hoist
- **Regression sweep:** all 16 OCaml suites green + `dune build @thorough` 68
  tests OK. The 8 committed eval.ml/harness wins introduce no regression.
- **Harness re-survey (single run):** mark_batch 7.38, desugar_batch 5.84,
  check_modules_batch 5.23, then check_batch 1.10 / parse 1.14 / lex_files 1.05 /
  eval_run_batch 0.90 / rest <0.9. Top 3 are interpretation-bound (the floor).
- **Win — hoist prelude scan out of mark_batch's per-file loop.** markWithPrelude
  rescanned the fixed ~1000-line prelude (interfaceMethodNames/droppablePreludeFns/
  constrainedFnNames) on every call; mark_batch called it ~92×. Added marker.markerFor
  (scan prelude once → closure); mark_batch maps it. before 7.61s after **6.36s**
  (~1.2×). 94 matched 0 differing; check_modules 12 ok; desugar 94 matched.
- committed: 275b4ff
- **Frame-merge lever RULED OUT:** merging per-module [local;import;global] FTables
  into one (to cut 3 hashes→1 for prelude/ctor lookups) would break Phase-112
  lookup_method's shadow-bypass (which needs the separate frames). Don't.

### 2026-06-04 — small batch harnesses already amortize prelude (no rescan win)
- Tested whether check_batch/resolve_batch/typecheck_golden_batch re-process the
  prelude per file (the markerFor pattern). MEASURED: typecheck_golden_batch on
  1 fixture = 0.87s, full set = 0.81s — IDENTICAL. The cost is fixed prelude
  setup (parse runtime+core once); per-file is negligible. They already amortize
  correctly. **No rescan win in the small harnesses.** (mark_batch was the
  exception because markWithPrelude re-scanned the prelude in Medaka per file;
  resolve/typecheck seed the prelude once via checkProgramSeeded.)
- **State of the floor:** every batch harness is now either interpretation-bound
  (mark 6.36 / desugar 5.84 / check_modules 5.23 — the big 3) or fixed-prelude-
  setup-bound (the rest, <1.1s, irreducible). The one remaining large lever is
  the interpreter's by-name env lookup (~28% of eval), which needs a structural
  (slot-indexed / inline-cache) change — constrained by Phase-112 lookup_method
  needing separate frames. Instrumenting lookup next to decide if it's worth it.

### 2026-06-04 — env-lookup instrumentation: the floor, quantified
- Instrumented `lookup` (temp, reverted) over marking parser.mdk:
  **19.9M lookups, 55.9M frames walked (avg depth 2.80), 74% hit an FList (local/
  per-call) frame, 26% hit an FTable (global), 49.7M FList string-compares
  (~2.5/lookup).** The self-hosted parser is LOCAL-variable-heavy: most lookups
  resolve in the per-call frame chain via a multi-frame walk + string compare.
- **Conclusion:** the residual ~28% env-lookup cost is the by-name environment
  itself — a structural floor, NOT a micro-opt target. The 74% local hits need
  the frame walk to find the right binding; only a slot-indexed / De-Bruijn env
  (resolve assigns each EVar a (depth,index); eval indexes directly, no walk/
  string-compare) removes it. Estimated ~7-15% overall (could be more).
- **Why parked for supervised work, not unattended:** threads resolve.ml (compute
  lexical slots) + ast.ml (EVar carries slot) + eval.ml (indexable env), and must
  preserve VThunk forcing, the FTable globals, AND Phase-112 lookup_method's
  shadow-bypass (which deliberately walks frames for a VMulti past a nearer
  shadow). A subtle resolution regression here is exactly the kind that's hard to
  debug non-interactively; verify-or-revert protects committed state but a clean
  landing needs a supervised session. **This is THE top un-attempted lead.**

### 2026-06-04 — build-optimization lever DEAD (no flambda)
- `ocamlopt -config`: **flambda: false**. So `-O3`/aggressive cross-module
  inlining unavailable (would need a new opam switch — out of scope).
- A/B `--profile release` vs dev (check_modules_batch min-of-3): **5.18s vs 5.18s,
  identical.** Without flambda, dev≈release at runtime (ocamlopt optimizes
  natively in dev; the dev profile only adds -g). No build-flag win available.
- `-unsafe` (drop bounds checks) is the only remaining build knob; NOT pursued —
  build-wide safety removal on an interpreter is too risky unattended for an
  unquantified gain. Noted for supervised consideration.

### 2026-06-04 — ctor-table String-specialization: flat, REVERTED
- Desugar profile showed a 2nd hashtbl find_opt (find_opt_1154, ~30 samples)
  distinct from the env FrameTbl (1400). Converted eval's string-keyed
  ctor_to_type + ctor_field_order to the String-specialized FrameTbl (same proven
  pattern as the env win). A/B (min-of-5): check_modules_batch 5.08→5.04
  (~0.8%, noise), desugar_batch 5.71→5.72 (flat). Unlike the env table, these
  aren't hot enough for the specialized-equality to matter. **REVERTED.** (iface_
  dispatch is tuple-keyed; registries are prop-only — none worth converting.)
- The desugar/mark residual is match_pat dispatch + eval_1426 + env walk — the
  interpretation floor. No further contained interpreter win found.

### 2026-06-05 00:56 — DEFINITIVE final harness table (min-of-3, all green)
Whole fast-path suite ≈ **24.6s total** across all 16 harnesses (was ~11 min
batched pre-session / ~44 min original non-batch ⇒ ~27× this session on the fast
path, ~107× vs the original suite).

| Harness | min-of-3 |
|---|--:|
| mark_batch | 6.06s |
| desugar_batch | 5.58s |
| check_modules_batch | 5.03s |
| check_batch | 1.03s |
| parse | 1.09s |
| lex_files | 1.01s |
| eval_run_batch | 0.86s |
| typecheck_golden_batch | 0.81s |
| typecheck | 0.54s |
| eval_dict_batch | 0.46s |
| eval_list_batch | 0.46s |
| eval_prelude_batch | 0.38s |
| eval_typed_batch | 0.38s |
| resolve_batch | 0.34s |
| lexer | 0.31s |
| exhaust | 0.22s |

The 3 leaders (mark/desugar/check_modules) are interpretation-bound (the env-walk
floor); the rest are fixed-prelude-setup-bound (<1.1s, irreducible). Next lever
for all 3 = the slot-indexed-env rework (supervised — see interim summary).

### 2026-06-05 — string-building O(n²): renderToks/joinNl/joinSp via stringConcat
- **Hypothesis (README §Performance):** the lexer/sexp/formatter build strings via
  left/right-fold `acc ++ piece`; `++` is OCaml `^` (eval.ml `VString (a ^ b)`),
  which allocs a fresh String and blits both operands — so a fold over n pieces is
  O(n²). VERIFIED, with an important refinement on *where* it actually bites.
- **MEASURE — synthetic lex scaling** (`lex_main` over core.mdk repeated 1/2/4/8×,
  min-of-3): **0.14 / 0.32 / 0.84 / 2.34s**. Doubling factors 2.3/2.6/3.0× (>2×) ⇒
  super-linear. Fit T(n)=a·n+b·n²: at 8× the quadratic term is ~63% of runtime.
- **PROFILE (sample, 8× lex):** `eval_binop_1427` (the `++`/`^` arm) 1276+510 samples
  + `caml_alloc_string` 1200 + `caml_blit_string` 173 — string concat dominates at
  scale. Confirms the cost is `^` alloc+blit, not interpretation, on this path.
- **Root loop:** `lex_main.renderToks` did `tokenToString t ++ "\n" ++ renderToks rest`
  — right-recursive, re-copying the whole growing output tail once per token (~80k
  tokens at 8×). Same shape in `util.joinNl`, `sexp.joinSp`, `util.escStr/escFrom`.
- **Fix (no new primitive / no mutable buffer needed):** the existing native
  `stringConcat : List String -> String` (eval.ml = `String.concat ""`) is a single
  O(total) pass. Added `util.joinWith sep xs = stringConcat (intersperseStr sep xs)`
  (cons pieces O(1) each, freeze once) and routed `joinNl`/`joinSp` through it;
  `renderToks = joinNl (map tokenToString toks)`; `escFrom` collects a `List String`
  then `stringConcat`. This *is* the "amortized-append + single-freeze" pattern, but
  functional (list) rather than a vendored mut_array StringBuilder — under the
  tree-walker the native `String.concat` freeze beats any Medaka-level per-char push,
  and a mutable buffer would need vendoring into compiler + threading mutation through
  pure recursion for no asymptotic gain. (Considered & rejected on those grounds.)
- before: lex 8× **2.34s** / core.mdk 0.14s   after: **1.01s / 0.11s** (**2.3× / ~21%**);
  scaling now clean-linear (0.11/0.22/0.45/1.01 ⇒ 2.0/2.0/2.2× per doubling).
- correctness: lexer harness 17/17 ok, lex_files 13/13 matched, mark_batch &
  desugar_batch 96/96 matched (byte-identical), check_modules_batch 12 ok,
  OCaml `check` of util/lex_main OK. Output byte-identical everywhere.
- committed: this commit (string-building O(n²) → stringConcat)
- **KEY REFINEMENT — the win is in joins over MANY elements, not large strings.**
  A/B on the things that *look* like the same bug but measured **FLAT (reverted /
  left as-is):**
  - `mark_batch`/`desugar_batch` overall: interleaved A/B old-vs-new sexp `joinSp`
    = 6.90→6.88 / 6.22→6.22s (noise). The sexp dump is tree-shaped — each node
    joins a *short* child list; total cost is parse+mark interpretation (the env
    floor), not string concat. joinSp/escStr kept anyway (byte-identical, strictly
    lower asymptotic complexity, share the joinWith helper) but they buy nothing here.
  - `desugar_batch.renderAll` (joins ~96 per-file outputs right-recursively):
    A/B 6.26→6.28s, FLAT — **REVERTED.** Even though the combined output is large,
    96 iterations = 96 allocations; native `^` blits the large suffixes at memcpy
    speed (~ms). The lex win came from ~80k iterations (alloc churn + GC), not byte
    volume. **Lesson: fix joins whose LIST IS LONG (alloc count), not joins of a
    few large strings.**
  - `lexer.mdk` `scanStr`/`scanTriple`/`scanInterpCont` (`acc ++ charToStr c` per
    char) ARE O(L²) per string literal (synthetic 20k/40k-char literal = 0.09/0.25s,
    2.8× super-linear) — but the **longest literal in the whole stdlib+compiler
    corpus is 98 chars** (≈9.6k char-copies, negligible). Left untouched: fixing 3
    escape-handling guard functions adds correctness risk for zero real-world gain.
- **Latent (not exercised at scale, left as-is):** `eval.mdk`'s module-local
  `joinWith` (line ~103) is the same right-recursive quadratic, used by `ppValue`
  value rendering — only bites if a rendered value has a very long list/tuple;
  fixture results are small, so flat. Same one-line fix available if it ever shows.

### 2026-06-05 — standing per-phase instrumentation (perf_main.mdk + timer.mdk)

**Added reusable per-stage timing infrastructure** so future sessions don't need
ad-hoc env-lookup counters or sample-profiling to localise cost.

**What was added:**
- `stdlib/runtime.mdk`: `extern wallTimeSec : Unit -> <IO> Float` — wall-clock
  time in seconds (OCaml `Unix.gettimeofday`); impl in `lib/eval.ml`.
- `compiler/timer.mdk`: helpers (`perfEnabled`, `now`, `emitPhase`, `emitTotal`,
  `totalDecls`) guarded by `MEDAKA_PERF` env var. All output goes to stderr; with
  the flag unset the module is a pure no-op.
- `compiler/entries/perf_main.mdk`: instrumented eval driver (mirrors
  `eval_typed_modules_main.mdk`) that brackets each pipeline stage with `now()`.
  Stages timed: **parse** (runtime+core lex+parse+desugar), **load**
  (`loadProgram`: read+lex+parse all transitive imports), **desugar** (all
  modules), **elaborate** (`elaborateModules`: marker + per-module typecheck),
  **eval** (`evalModulesOutput`). Op counts derived from already-computed results
  (module count, total decl count) — no extra work.

**Correctness:** `MEDAKA_PERF` unset → stdout byte-identical to
`eval_typed_modules_main.mdk` (verified by diff). mark_batch 101 matched 0
differing (includes timer.mdk + perf_main.mdk); check_modules_batch 12 ok;
selfproc 14 ok; desugar_batch 101 matched; eval_run_batch 17 ok.

## How to read the output

```
MEDAKA_PERF=1 medaka run compiler/entries/perf_main.mdk \
    stdlib/runtime.mdk stdlib/core.mdk compiler/entries/all_modules_entry.mdk compiler
```

Each line on stderr:
```
[perf] <stage>   <elapsed>s   <ops>
```
- **stage** — pipeline phase name
- **elapsed** — wall-clock seconds for that phase (self-hosted code running
  through the OCaml tree-walker — this is interpreter time, not native time)
- **ops** — work-unit proxy: "N modules" for load, "N decls" for desugar/
  elaborate/eval, "runtime+core" for parse.  Useful for normalizing per-file
  or per-declaration cost across different entry points.

The total includes file I/O for reading runtime.mdk and core.mdk (a few ms,
negligible).  The `load` phase includes self-hosted lex+parse for all transitive
imports; it dominates because the self-hosted lexer/parser interpret through the
full OCaml eval — same interpreter overhead as every other stage but applied to
the larger pre-desugar source rather than the post-desugar AST.

## Baseline (min-of-3, full compiler closure via all_modules_entry.mdk)

Entry: `compiler/entries/all_modules_entry.mdk`, 14 modules, 4609 decls post-desugar.

| Stage      | min-of-3 | ops             |
|---|--:|--|
| parse      | 0.228s   | runtime+core    |
| load       | 3.093s   | 14 modules      |
| desugar    | 0.221s   | 4609 decls      |
| elaborate  | 1.846s   | 4609 decls      |
| eval       | 0.326s   | 4609 decls      |
| **total**  | **5.71s**|                 |

**Takeaways:**
- `load` (3.09s, 54%) and `elaborate` (1.85s, 32%) are the two dominant stages.
- `load` dominates because it runs the self-hosted lex+parse pipeline for 14
  modules through the OCaml tree-walker; the self-hosted parser alone is the
  hottest single function (see prior profiling: ~54% of check_modules samples).
- `elaborate` is per-module typecheck (HM inference + Tarjan SCC + constraint
  solving); already 282× faster than origin after the Tarjan + env-Hashtbl wins.
- `desugar` (0.221s) and `eval` (0.326s) are minor — the AST shrinks after
  desugaring and eval has minimal dispatch overhead for this particular program
  (no main side-effects).
- `parse` (0.228s) is just runtime.mdk + core.mdk lex+parse (2 files, ~600 lines
  total) — fast and not a target.

**Next lever (confirmed by this data):** the `load` phase is the largest remaining
cost. Since load is self-hosted lex+parse, any improvement to the self-hosted
lexer or parser interpretation speed (e.g. the slot-indexed env rework) would
directly reduce it. See the prior parked lead in this file.

### 2026-06-05 — slot-indexed env CONSUME half: measured NO WIN under the tree-walker (kept dormant)
The parked "single most promising un-attempted lead" (slot-indexed / lexical-
addressing env) was implemented end-to-end in the **self-hosted** eval and
measured. **Verdict: it does not help this tree-walker — list-indexed is neutral,
array frames clearly regress.** Kept as DORMANT, validated Stage-2 scaffolding
(not wired into the eval pipeline); the win is deferred to a bytecode VM.

- **What was built (all byte-identical across the whole eval+core_ir+selfproc
  corpus; the `EVarAt` slot/name assertion never fired, so the emit/consume frame
  model is provably exact):**
  - `compiler/annotate.mdk` — the §2.0 EMIT pass (`annotateProgram`, `EVar`→`EVarAt
    n (ALocal frame slot)`) relocated out of `resolve.mdk` into a lean ast+util-only
    module (so eval drivers need not pull all of resolve into their load closure);
    Core IR drivers now import it from here.
  - `eval.mdk` — an `EVarAt` consume arm + `lookupAtAddr`/`frameAtDepth`/`addrCell`
    (AGlobal ⇒ by-name `lookupEnv`, the self-host analog of the lookup_method
    shadow-bypass; ALocal ⇒ index (frame,slot), name-checked).
- **MEASURE (synthetic eval-lookup probe — a local-var-heavy hot loop run through
  the self-hosted eval via `eval_main`, 60k iters, min-of-3, the only way to
  isolate eval-lookup since the real compiler workloads are load/elaborate-bound
  and eval is <6% of them):**

  | config | min-of-3 | vs baseline |
  |---|--:|--:|
  | baseline (by-name, `List (List ..)` frames) | **50.31s** | — |
  | list-indexed (EVarAt arm, list frames, annotation wired) | 52.02s | within noise (~neutral, baseline runs were high-variance 50.3–55.0) |
  | array-indexed (`List (Array ..)` frames, O(1) slot) | 57.47s | **+14% (clear regression, tight runs)** |

- **WHY no win (the key insight — sharpens the OCaml-side floor finding above):**
  in a tree-walker the lookup logic is **itself interpreted Medaka**, so the
  "O(1) index" is not a native op — `lookupAtAddr→frameAtDepth→addrCell` plus the
  `Addr` destructure cost roughly what the by-name string-compares cost (list:
  neutral), and `arrayFromList` on **every** `extendEnv`/`pushFrame` (per call /
  let / match) far outweighs O(1) slot indexing on small frames (array: −14%).
  Lexical addressing pays only when the consumer compiles the index to a native
  array access (bytecode VM / LLVM) — which is exactly why the **Core IR already
  carries the addresses** (`CVar String Addr`) for that future consumer.
- **Decision (per the "revert if it doesn't measurably help" rule):** reverted the
  array-frame rep and the eval-pipeline wiring; eval frames stay `List (List ..)`
  and the drivers do **not** run `annotateProgram` (AST eval stays by-name, zero
  added cost). KEPT the `EVarAt` arm + `annotate.mdk` as dormant, validated
  scaffolding — activate by running `annotateProgram` in `evalProgram`/`evalModules`
  (and a VM consumer would index natively). `resolve.mdk` lost its now-relocated
  260-line annotate block.
- correctness: eval 16 / eval_modules 4 / eval_run 18 / eval_prelude 5 / eval_typed
  2 / eval_dict 11 / core_ir 16+5+2+2 / selfproc 16 / mark_batch 110 / desugar 110 /
  resolve 14+7 / check_modules 13 — all byte-identical, in every config measured.
- **corpus cost of the new module:** `annotate.mdk` is added to the self-host
  typecheck corpus (now 13 modules — `check_modules` + selfproc Leg A diff it
  byte-for-byte vs the reference; it's a compiler module, not a slow fixture). The
  three big batch harnesses moved up ~1s each (min-of-3): mark_batch 6.06→7.43s,
  desugar_batch 5.58→6.72s, check_modules_batch 5.03→5.87s — the cost of one extra
  ~330-line module being parsed/marked/typechecked (partly offset elsewhere by the
  260-line block leaving `resolve.mdk`; some of the delta is also session-load
  variance). Still single-digit-seconds, within the fast-path budget.
- committed: kept annotate.mdk + dormant eval EVarAt arm; reverted arrays + wiring.

#### 2026-06-05 (follow-up) — independent re-confirmation on the true-execution path
Re-verified the above from a clean state, on a *different* workload than the
synthetic `eval_main` probe: wired `annotateProgram` into the single-file
true-execution driver (`eval_run_main.mdk`, via `evalOutput (annotateProgram
combined)`) and ran a compute-heavy `fib 25` through the self-hosted eval.

- **Correctness re-validated:** all **18/18 `=== EVAL ===` goldens byte-identical**
  with the CONSUME path active; the `EVarAt` slot/name self-assert never fired —
  so `annotate`'s EMIT addressing is provably exact against eval's *runtime* frame
  model on the single-file path (the prerequisite the bytecode VM / LLVM consumers
  depend on).
- **Perf re-measured (`fib 25`, `/usr/bin/time -p`, 2 runs each):** consume-active
  **12.30 / 12.38s** vs by-name baseline **12.02 / 12.05s** → **~2.5% slower**.
  A second, independent confirmation of "no tree-walker win" (list-indexed lands
  neutral-to-slightly-negative, matching the synthetic probe). Same root cause:
  the address resolution is itself interpreted, and `AGlobal` references still scan
  by name. **Reverted the driver wiring; the arm stays dormant.**
- **Standing conclusion (do not re-attempt on the tree-walker):** the lexical-
  addressing *consume* lever is a confirmed non-win for the AST interpreter — twice
  measured, structurally explained. The win is already captured where it belongs:
  the §2.2 bytecode VM lowers the same `annotateProgram` output to O(1) compiled
  slot loads, and §2.4 LLVM will too. EMIT (annotate) + the dormant CONSUME arm are
  validated, ready scaffolding for those compiled consumers — not a tree-walker
  optimization.

### 2026-06-05 — single-file per-stage profiler (profile_main.mdk + profile_compiler.sh)

**Added single-file per-stage timing harness** to complement `perf_main.mdk`
(which times the full multi-module loader path, bundling mark+typecheck into
a single `elaborate` phase).  The new harness breaks the single-file pipeline
into individually-timed stages so the cost of each is visible:
- `compiler/entries/profile_main.mdk`: times parse-prelude (runtime+core setup),
  **parse** (lex+parse), **desugar**, **resolve**, **mark**, **typecheck**
  separately for a single target file.  `MEDAKA_PERF` guard: unset → silent exit.
- `test/profile_compiler.sh [N]`: runs the driver N times (default 3) over
  `compiler/lexer.mdk` (self-contained; all stages accurate) and
  `compiler/parser.mdk` (parse/desugar/resolve/mark accurate; typecheck fails —
  see below), takes per-stage minimums with awk, and prints a table.

**Bug fixed (pre-existing, surfaced by loading typecheck.mdk in the driver):**
`doStmtSites (DoLet _ _ e)` in `typecheck.mdk` had 3 wildcards for a
4-arg `DoLet Bool Bool Pat Expr` constructor.  Phase 143 added the first `Bool`
field but this arm wasn't updated.  Fixed → `(DoLet _ _ _ e)`.  The bug was
latent (the corpus has no bare-block `DoLet` in an `elaborate` path that reaches
`doStmtSites`); all 16 harnesses still pass byte-identical after the fix.

**How to run:**
```
sh test/profile_compiler.sh 3           # min-of-3 over lexer.mdk + parser.mdk
MEDAKA_PERF=1 medaka run compiler/entries/profile_main.mdk \
    stdlib/runtime.mdk stdlib/core.mdk compiler/lexer.mdk
```

**Note on parser.mdk typecheck:** `parser.mdk` imports `ast` and `lexer`, which
are not in scope in single-file mode.  The typecheck stage panics with
`unbound variable: TEof` before emitting its `[perf]` line.  The
parse/desugar/resolve/mark rows are still accurate; typecheck is omitted.
Use `perf_main.mdk` with the full multi-module loader for an accurate
end-to-end typecheck measurement.

**Correctness:** all 16 diff harnesses byte-identical after the DoLet fix:
check_modules_batch 13 ok; selfproc 16 ok; eval_typed 3 ok; eval_dict 13 ok;
mark_batch / desugar_batch unchanged.

## Baseline (min-of-3, single-file path via profile_compiler.sh 3)

### compiler/lexer.mdk — 958 lines, 406 post-desugar decls, no imports (all stages accurate)

| Stage         | min-of-3 | ops          |
|---|--:|--|
| parse-prelude | 0.233s   | runtime+core |
| parse         | 0.368s   | 405 decls    |
| desugar       | 0.037s   | 406 decls    |
| resolve       | 0.149s   | 406 decls    |
| mark          | 0.053s   | 406 decls    |
| typecheck     | 0.172s   | 406 decls    |
| **total**     | **1.018s** |            |

### compiler/parser.mdk — 2424 lines, 883 post-desugar decls, has imports (parse/desugar/resolve/mark only)

| Stage         | min-of-3 | ops          |
|---|--:|--|
| parse-prelude | 0.228s   | runtime+core |
| parse         | 0.584s   | 883 decls    |
| desugar       | 0.039s   | 883 decls    |
| resolve       | 0.427s   | 883 decls    |
| mark          | 0.064s   | 883 decls    |
| typecheck     | *(panic — unresolved imports)* | |

**Takeaways:**
- For `lexer.mdk`, **parse dominates** (0.368s = 36% of total), more than
  resolve + mark + typecheck combined (0.374s).  The self-hosted lex+parse runs
  through the OCaml tree-walker — same interpreter overhead as every other stage
  but over the un-lowered pre-desugar source.
- **desugar and mark are cheap** (~0.037s and ~0.053s) relative to
  parse/resolve/typecheck.  They are not bottlenecks.
- **resolve (0.149s) and typecheck (0.172s)** have similar cost for lexer.mdk
  (a 406-decl, no-import file); their ratio will shift for larger programs where
  typecheck's HM inference compounds.
- For `parser.mdk`, **resolve scales up more steeply** (0.427s vs 0.149s for a
  ~2× decl count) while desugar and mark remain flat — the O(decls²) candidate
  in resolve is worth investigating if it grows further.
- **§2.2 VM capstone comparison:** when the VM is complete, rerun
  `sh test/profile_compiler.sh 3` and compare the per-stage minimums above.
  The parse/desugar stages use the self-hosted OCaml tree-walker (unchanged by
  the VM); only the `elaborate` and `eval` stages in `perf_main.mdk` will
  shrink when the VM replaces tree-walking.  Use `perf_main.mdk` for the
  multi-module VM-vs-tree-walker comparison; this table is the AST tree-walker
  baseline for the single-file stages.

---

### 2026-06-05 — multi-module per-stage timing + allocation counter

**Added:**
- `extern allocBytes : Unit -> <IO> Float` (stdlib/runtime.mdk + lib/eval.ml) —
  total GC-allocated bytes since process start, backed by `Gc.allocated_bytes ()`.
  Monotonically increasing; deltas give per-phase allocation pressure (counts
  OCaml values created through the tree-walker, including GC-reclaimed temporaries).
- `compiler/timer.mdk`: `allocSnap`, `emitPhaseA`, `emitTotalA` — new variants
  of the timing helpers that include an allocation-delta column (bytes → MB).
- `compiler/typecheck.mdk`: `markModules` exported — the mark sub-phase of
  `elaborateModules` (compute rpNames + prePassDict over the full module graph);
  allows profiling drivers to bracket mark vs typecheck separately.
- `compiler/entries/profile_modules_main.mdk` (NEW) — multi-module per-stage profiler:
  times parse, load, desugar, mark, typecheck (no eval) over `all_modules_entry.mdk`.
  Breaks out the `elaborate` lump that `perf_main.mdk` reports as one phase.
- `test/profile_compiler.sh` updated: adds `profile_modules` section, handles
  4-field output format (stage / time / allocMB / ops).
- `compiler/entries/profile_main.mdk` updated: uses `emitPhaseA`/`emitTotalA` — alloc
  column now appears in the single-file table too.

**Correctness:** check_modules_batch 13 ok; selfproc 16 ok; eval_dict 16 ok;
mark_batch/desugar_batch 121 matched; eval_modules 4 ok.  perf_main.mdk still
works with the old 3-field `emitPhase` format (unchanged).

## Baseline (min-of-3, 2026-06-05, via profile_compiler.sh 3)

Alloc column = `Gc.allocated_bytes()` delta per phase (total bytes allocated by
the OCaml process during that phase, including short-lived intermediates reclaimed
by GC — NOT peak live memory).  Useful for comparing allocation pressure between
stages and tracking regressions.

### compiler/lexer.mdk — 958 lines, 406 post-desugar decls, no imports

| Stage         | min-of-3 | alloc     | ops          |
|---|--:|--:|--|
| parse-prelude | 0.225s   | 1025.7MB  | runtime+core |
| parse         | 0.352s   | 1588.3MB  | 405 decls    |
| desugar       | 0.037s   | 374.9MB   | 406 decls    |
| resolve       | 0.140s   | 835.4MB   | 406 decls    |
| mark          | 0.051s   | 341.4MB   | 406 decls    |
| typecheck     | 0.168s   | 883.4MB   | 406 decls    |
| **total**     | **0.973s** | **5049.3MB** |          |

### compiler/parser.mdk — 2424 lines, 883 post-desugar decls (parse/desugar/resolve/mark only)

| Stage         | min-of-3 | alloc     | ops          |
|---|--:|--:|--|
| parse-prelude | 0.224s   | 1025.7MB  | runtime+core |
| parse         | 0.578s   | 2582.0MB  | 883 decls    |
| desugar       | 0.038s   | 371.2MB   | 883 decls    |
| resolve       | 0.422s   | 2239.6MB  | 883 decls    |
| mark          | 0.063s   | 403.1MB   | 883 decls    |
| typecheck     | *(panic — unresolved imports)* | | |

### compiler/entries/all_modules_entry.mdk — 15 modules, 5017 post-desugar decls (multi-module, no eval)

| Stage      | min-of-3 | alloc      | ops          |
|---|--:|--:|--|
| parse      | 0.230s   | 1025.7MB   | runtime+core |
| load       | 3.463s   | 14903.7MB  | 15 modules   |
| desugar    | 0.239s   | 2380.5MB   | 5017 decls   |
| mark       | 0.083s   | 633.9MB    | 5017 decls   |
| typecheck  | 2.026s   | 10410.0MB  | 5017 decls   |
| **total**  | **6.046s** | **29353.8MB** |          |

**Takeaways from the multi-module breakdown:**
- **`load` (3.46s = 57.3%) dominates** — confirmed by `perf_main.mdk` baseline.
  This is self-hosted lex+parse for 15 modules through the OCaml tree-walker;
  load allocates 14.9 GB of short-lived values (~4.4 GB/s).
- **`typecheck` (2.03s = 33.5%)** is the second largest phase.  The `elaborate`
  lump in `perf_main.mdk` (2.13s) ≈ mark (0.083s) + typecheck (2.026s) + small
  route-stamping overhead — confirming mark is not a bottleneck.
- **`mark` (0.083s = 1.4%)** is negligible.  It's a pure prePassDict rewrite
  with no inference — cheap even for 5017 decls.
- **`desugar` (0.239s = 4.0%)** is also minor.
- **Allocation rate:** load is the highest-pressure phase (14.9 GB for 3.46s
  ≈ 4.3 GB/s); typecheck is second (10.4 GB for 2.03s ≈ 5.1 GB/s — more
  allocation-dense per second due to HM unification creating many type cells).
- **§2.2 VM capstone:** see the "VM vs Core IR tree-walker" section below for the
  full comparison.  Short answer: the VM is slower here — the `load` overhead (load
  uses the self-hosted OCaml tree-walker lexer+parser, not the VM) completely masks
  any eval difference at the multi-module granularity.

## 2026-06-06 — Phase 146 effect-tracking port (expected typecheck regression)

Ported the full effect-tracking subsystem (Phase 79 propagation + 79e escape +
146 laundering) into `compiler/typecheck.mdk`. This adds genuine per-arrow work to
the typecheck phase — `openRow ()` allocates a fresh effvar `Ref` on every
inference-synthesized arrow (each `EApp`/`ELam`-intermediate/pipe/compose), plus
`performEffect`/`unifyRow` per application. Faithfully mirrors OCaml's
`open_row`/`fresh_effvar` design; the cost is inherent to sound effect inference,
not avoidable without diverging from the reference.

Measured (min-of-3, `sh test/profile_compiler.sh 3`, same machine as the
2026-06-05 baseline above):

| metric                       | 2026-06-05 | 2026-06-06 |    Δ |
|---|--:|--:|--:|
| lexer.mdk typecheck          |   0.168s   |   0.200s   | +19% |
| all_modules typecheck        |   2.026s   |   2.501s   | +23% |
| all_modules typecheck / decl | 0.404 ms   | 0.486 ms   | **+20%** |
| all_modules total            |   6.046s   |   6.748s   | +12% |

(Decl count rose 5017→5146; per-decl normalization isolates the true effect-inference
overhead at +20%.) `substMonoP`/`reopenRow` (Stage D instantiation re-open) add
near-zero: the reopen fires only on rare closed-with-labels covariant rows; pure
schemes hit the cheap `_ r => r` arm. Heaviest single `check_modules` entry
(`typecheck.mdk` closure) min-of-3 = **2.83s**. The Tarjan SCC 5× win is intact —
check_modules remains far under its 1515s pre-optimization regime. Judged an
acceptable, proportionate cost for the gap-1 soundness feature; no perf-work
attempted to claw it back (would be premature pre-VM, and the dominant `load` phase
is the real lever). Correctness gate: every `diff_compiler_*` harness byte-identical;
`@thorough` 72 green.

---

## §2.2 VM capstone: VM vs Core IR tree-walker (2026-06-06)

> **Note:** The bytecode VM (`compiler/bytecode.mdk` + `vm_perf_main.mdk`) was
> removed 2026-06-10 as confirmed off the canonical path. This section is kept
> as a historical performance record.

**New driver:** `compiler/vm_perf_main.mdk` — lowers a source file once to
`CProgram`, then runs both evaluators in the same process and times each via
`timer.mdk`; `MEDAKA_PERF` unset ⇒ byte-identical to `core_ir_main.mdk`.

**Method:** `MEDAKA_PERF=1 medaka run compiler/vm_perf_main.mdk <file>`, min-of-3
invocations per fixture.  The `lower` column is the shared front-end
(parse → desugar → annotateProgram → lowerProgram); `ceval` is `cevalMain` (§2.1
Core IR tree-walker); `bceval` is `bcEvalMain` (§2.2 bytecode compiler + stack VM).

### Single-file engine fixtures (intra-process, min-of-3, 2026-06-06)

| fixture | lower | ceval | bceval | ratio (bc/ceval) |
|---------|------:|------:|-------:|:---:|
| fib 22 (17 711 calls) | 0.0022s | 1.904s | 6.116s | **3.21×** |
| guarded\_clauses (collatzLen 27 — 111 steps) | 0.0065s | 0.0065s | 0.0319s | **4.88×** |
| letrec\_mutual (mutual isEven/isOdd + collatz) | 0.0054s | 0.0132s | 0.0311s | **2.36×** |
| refs\_mut (Ref + set\_ref + countUp/sumTo) | 0.0087s | 0.0018s | 0.0050s | **2.78×** |
| records (record construction/update/access) | 0.0086s | 0.00077s | 0.00129s | 1.68× |
| adt\_nested (ADT + match) | 0.0077s | 0.00133s | 0.00193s | 1.44× |
| arrays\_ranges (array/range/slice ops) | 0.0078s | 0.00100s | 0.00168s | 1.68× |
| hof\_compose (HOF/closures/pipe/sections) | 0.0078s | 0.00138s | 0.00329s | 2.38× |
| list\_ops (cons/append/eq/ordering) | 0.0091s | 0.00111s | 0.00232s | 2.09× |
| dispatch\_basic (interface, arg-position) | 0.0068s | 0.00102s | 0.00179s | 1.75× |
| dispatch\_multi (multi-method interface) | 0.0020s | 0.00202s | 0.00310s | 1.52× |
| dispatch\_default (default method override) | 0.0007s | 0.00074s | 0.00082s | 1.11× |
| shadow\_closure (lexical capture/shadow) | 0.0007s | 0.00070s | 0.00114s | 1.63× |
| string\_kernel (string externs) | 0.0008s | 0.00079s | 0.00131s | 1.64× |
| patterns\_misc (literal/as/curried patterns) | 0.0121s | 0.00299s | 0.00625s | 2.09× |

### Multi-module fixtures (process-level user time, min-of-3, 2026-06-06)

| fixture | core\_ir\_modules (ceval) | eval\_bytecode\_modules (bceval) | ratio |
|---------|-------------------------:|--------------------------------:|:---:|
| basic | 0.29s | 0.29s | 1.00× |
| iface | 0.29s | 0.29s | 1.00× |
| isolation | 0.29s | 0.30s | 1.03× |
| prelude | 0.30s | 0.30s | 1.00× |

### Interpretation

**The §2.2 bytecode VM is 1.5–4.9× slower than the §2.1 Core IR tree-walker**
on pure-compute workloads under double interpretation (the self-hosted compiler
itself runs through the OCaml tree-walker, so the VM instruction dispatch runs
*interpreted*).  Structural fixtures (records, ADTs, arrays) show 1.4–1.7× overhead;
recursive kernels (fib, collatz) show 2.4–4.9× because each recursive call adds VM
instruction-loop overhead on top of the already-interpreted `VClosureF` dispatch.
`refs_mut` (2.78×) and closures (1.6–2.4×) are in the middle — heap allocation and
env-frame construction dominate their cost equally in both paths, but the VM adds
bytecode-step overhead on top.

**Multi-module: no observable difference.** The 0.29–0.30s process time for all
four multi-module fixtures is load-dominated (loading the self-hosted driver itself
costs ~0.29s regardless of which evaluator is called); the actual eval step for
these small fixtures (a handful of decls each) is unmeasurable at process-level
granularity.

**Why not a win here?** Lexical addressing (`annotateProgram` → `CVar` with `Addr`)
was designed so the VM does O(1) slot-indexed loads instead of by-name env scans.
However, the VM's instruction dispatch loop is itself *interpreted Medaka* running
through the OCaml tree-walker, so each `runChunk` step costs an OCaml-level
`eval`/`apply` call — the same overhead the tree-walker pays per AST node, PLUS the
additional stack-machine bookkeeping (ip increment, `Array` index, value-stack
push/pop).  The theoretical win from O(1) slot loads is swamped by the constant
factor of double interpretation.  The VM speedup will materialize when the OCaml
tree-walker is replaced by a native backend that can JIT or AOT the bytecode
interpreter loop — at that point the slot-indexed `CVar` addresses become genuine
O(1) loads in native code.

**Takeaway for the LLVM Stage (§2.4):** the bytecode VM is a correctness and IR
exercise, not a performance target in itself.  The Core IR (§2.1) remains the
faster choice for the self-hosted pipeline under the OCaml tree-walker.  When §2.4
emits real LLVM IR for the VM instruction loop (or lowers Core IR directly), the
performance picture reverses.

---

## §2.2 Capstone — selfproc_lex_probe through the bytecode multi-module VM (2026-06-06)

The capstone gate: run a real self-hosted stage (the lexer) through the bytecode
multi-module VM (`bytecode.bcEvalModulesOutput` via `eval_bytecode_modules_main.mdk`)
and diff byte-for-byte against the OCaml oracle.  Harness: `test/diff_compiler_bytecode_selfproc.sh`.

**Result: lex probe PASSES** (3/3 ok — 1 real pass, 2 documented expected-gaps):

| probe | result | notes |
|-------|--------|-------|
| `selfproc_lex_probe.mdk` | ✅ byte-identical | lexer uses untyped eval only |
| `selfproc_parse_probe.mdk` | expected gap (§2.3) | Parser monad needs return-pos dispatch |
| `selfproc_tc_probe.mdk` | expected gap (§2.3) | typecheck stage uses Parser monad |

### Intra-process timing (vm_perf_modules_main.mdk, min-of-3, 2026-06-06)

Workload: `selfproc_lex_probe.mdk` — tokenizes an embedded Medaka snippet through
`compiler/lexer.mdk` (a recursive descent lexer with string operations).

| phase | time | notes |
|-------|-----:|-------|
| tree-walker | 0.240s | `evalModulesOutput` (desugar only, no annotation) |
| annotate | 0.018s | `annotateProgram` per module (bytecode VM setup cost) |
| bytecode-vm | 0.657s | `bcEvalModulesOutput` (Core IR lower + stack VM exec) |
| **ratio** | **2.74×** | bytecode VM / tree-walker |

The lex probe's 2.74× overhead is consistent with the single-file recursive-kernel
measurements (2.36–4.88×) — the lexer is a recursive string-scanning loop, so
each recursive call adds VM instruction-loop overhead on top of the interpreted
`VClosureF` dispatch.  The "why not a win" analysis above applies: the VM runs
under double interpretation.  The capstone confirms correctness (byte-identical
output); the performance improvement awaits the LLVM backend (§2.4).

**Command to reproduce:**
```sh
MEDAKA_PERF=1 medaka run compiler/vm_perf_modules_main.mdk \
    stdlib/core.mdk compiler/entries/selfproc_lex_probe.mdk compiler
```
