# PERF-SCOPE.md — Stage-3 bar-item-4 performance scoping

**Status:** IMPLEMENTED — bar-4 executed 2026-06-11; results in `compiler/PERF-RESULTS.md`.
Kept as historical rationale/hot-path analysis (its own ✅ banner below is accurate). The
dual OCaml+native scoping content and the Mach-O-only `-Wl,-stack_size` link flag are
historical — both are gone (OCaml removed 2026-06-26; the stack flag retired with the
Mac→Linux box migration, see `compiler/PERF-RUNTIME.md`). Dead bare `compiler/build_cmd.mdk`
citations corrected to `compiler/driver/build_cmd.mdk` (2026-07-13 doc pass).

> ✅ **EXECUTED 2026-06-11 — see [`PERF-RESULTS.md`](./PERF-RESULTS.md).** This was the
> read-only scoping pass; the work it planned (and much more) is done: `-O2` flipped, GC tuned,
> 18 fixpoint-gated O(N²) fixes → self-compile **12.04 s → 2.12 s (5.68×); ~59× vs the OCaml
> interpreter**. The `-O2`-is-fixpoint-safe and `mem2reg`-alloca-win predictions below were
> confirmed empirically. Kept for the rationale/hot-path analysis.

> Read-only scoping pass, 2026-06-10. Sources inspected:
> `compiler/driver/build_cmd.mdk`, `lib/build_cmd.ml`, `test/bootstrap_from_seed.sh`,
> `test/selfcompile_build_fixpoint.sh`, `test/refresh_seed.sh`,
> `runtime/medaka_rt.c`, `compiler/seed/emitter.ll` (271 277 lines / ~9.6 MB text IR).

---

## 1. `-O0` → `-O2` wiring points

Every clang invocation is enumerated below. **None passes any `-O` flag**, so all
currently compile at clang's default, which is `-O0`.

### 1a. Invocation inventory

| Location | Exact command template | Change for `-O2` |
|---|---|---|
| `lib/build_cmd.ml:231–237` | `[cc; "-Wl,-stack_size,0x20000000"] @ gc_cflags @ [ll_path; rt_c] @ gc_libs @ ["-o"; out_path]` | Insert `"-O2"` after the stack flag |
| `compiler/driver/build_cmd.mdk:219–223` | `["-Wl,-stack_size,0x20000000"] ++ gcCflags ++ [llPath; rtC] ++ gcLibs ++ ["-o"; outPath]` | Insert `"-O2"` after the stack flag |
| `test/bootstrap_from_seed.sh:66` | `"$CC" -Wl,-stack_size,"$STACK_SIZE" $GC_CFLAGS "$SEED" "$RT" $GC_LIBS -o "$SEED_EMITTER"` | Add `-O2` before `$GC_CFLAGS` |
| `test/bootstrap_from_seed.sh:90` | `"$CC" -Wl,-stack_size,"$STACK_SIZE" $GC_CFLAGS "$EMITTER2" "$RT" $GC_LIBS -o "$OUT"` | Add `-O2` before `$GC_CFLAGS` |
| `test/selfcompile_build_fixpoint.sh:64` | `"$CC" -Wl,-stack_size,"$STACK_SIZE" $GC_CFLAGS "$INTERP" "$RT" $GC_LIBS -o "$EMITA"` | Add `-O2` before `$GC_CFLAGS` |
| `test/selfcompile_build_fixpoint.sh:81` | `"$CC" -Wl,-stack_size,"$STACK_SIZE" $GC_CFLAGS "$IR1" "$RT" $GC_LIBS -o "$EMITB"` | Add `-O2` before `$GC_CFLAGS` |

**Total: 6 clang invocations.** There is no separate `llc` or `opt` invocation
anywhere — the pipeline is textual IR straight to `clang`, no IR-level opt passes.

### 1b. Minimal one-line change to enable -O2 globally

Add `-O2` to the `clangArgs`/`clang_argv` list in both `build_cmd.mdk` and
`lib/build_cmd.ml`. The test scripts also need `-O2` if you want the
bootstrapped `medaka_emitter` binary to be optimized too (for the perf
comparison to be meaningful).

For `lib/build_cmd.ml` line 232:
```ocaml
([ cc; "-Wl,-stack_size,0x20000000"; "-O2" ]
```

For `compiler/driver/build_cmd.mdk` line 219:
```
let clangArgs = ["-Wl,-stack_size,0x20000000", "-O2"]
```

For the shell scripts, add `-O2` before `$GC_CFLAGS`:
```sh
"$CC" -O2 -Wl,-stack_size,"$STACK_SIZE" $GC_CFLAGS ...
```

### 1c. Does `-O2` threaten the byte-identical fixpoint?

**No. Reasoning:**

The fixpoint (C3a/C3b) compares **emitted text IR** (`emitter2.ll` vs
`seed/emitter.ll`), not compiled binaries. The emitter's IR text is produced
by the Medaka program running on top of the runtime — it is a pure output of
the *program logic*, not of clang optimization. Clang optimization only affects
the **binary** produced from the IR; it does not alter the IR text the emitter
writes to stdout.

Concretely: `test/selfcompile_build_fixpoint.sh` flow is:
1. Emit IR via interpreter → `INTERP.ll` (text)
2. `clang(INTERP.ll)` → `emitA` (binary, `-O0` or `-O2` — doesn't matter)
3. Run `emitA` to re-emit the driver → `IR1.ll` (text produced by the program)
4. C3a: `cmp INTERP.ll IR1.ll` — compares *text outputs*, clang opt level invisible
5. C3b: `cmp IR1.ll IR2.ll` — same

The fixpoint is a property of the **emitter source logic** (deterministic,
content-addressed text generation). Clang optimization cannot cause the emitter
binary to produce different IR text — it only affects execution speed and binary
layout. Therefore `-O2` at clang link time is **safe** and does not require a
seed refresh.

One edge case to confirm empirically: Boehm GC behavior under optimization (GC
scans the stack conservatively; `-O2` may change register allocation and spill
patterns). This is a **runtime correctness** question, not a fixpoint threat.
GC + `-O2` is standard and is expected to work (Boehm is designed for this), but
confirm with the `diff_compiler_build.sh` behavioral gate after flipping.

---

## 2. Benchmark harness plan

### 2a. Workloads

Three tiers, ordered by diagnostic value:

**Tier 1 — Emitter self-compile wall-clock (most representative)**

The emitter compiling its own module graph (~9.6 MB IR output from ~5 000 lines
of `.mdk` source) is the heaviest real-world workload. This directly measures
"native compiler speed" vs the OCaml interpreter.

```sh
# Prerequisite: build medaka_emitter (from seed, or via selfcompile_build_fixpoint.sh)
# oracle: OCaml interpreter path (medaka run)
/usr/bin/time -l ./medaka_emitter \
    stdlib/runtime.mdk stdlib/core.mdk \
    compiler/entries/llvm_emit_modules_main.mdk \
    compiler stdlib > /tmp/emitter_native.ll

# native emitter: same args, native binary
# (set MEDAKA_EMITTER to the bootstrapped binary)
```

Measure: wall-clock + max-RSS via `/usr/bin/time -v` (Linux; `-l` on macOS). Run 3×, take min.

**Tier 2 — Compute microbenchmarks (isolate native speed)**

Use `fib` (exponential tree recursion, no I/O), `fact` (linear tail recursion
with accumulator via match), and a list-sum (allocation + GC pressure).

Create `test/bench_fixtures/fib.mdk`:
```
fib : Int -> Int
fib n = match n
  0 => 0
  1 => 1
  n => fib (n - 1) + fib (n - 2)
main : <IO> Unit
main = putStrLn (intToString (fib 38))
```

`fib 38` ≈ 126 million recursive calls — enough to exceed ~0.5s at 200 MIPS and
expose the per-call overhead. Compare:
- `medaka run test/bench_fixtures/fib.mdk` (OCaml tree-walker)
- `medaka build test/bench_fixtures/fib.mdk -o /tmp/fib_bench && /tmp/fib_bench` (-O0)
- Same at -O2

`fib 35` if 38 is too slow at -O0 (exponential — will take ~8× as long as 35).

**Tier 3 — `medaka check` of the whole compiler tree (end-to-end latency)**

```sh
/usr/bin/time -l ./_build/default/bin/main.exe check compiler/entries/llvm_emit_modules_main.mdk \
    compiler stdlib
```

This tests OCaml-native-vs-native-compile of the front-end (parsing, typechecking).
Currently always OCaml; after retirement, the native binary would run this path.
Include as baseline for documentation.

### 2b. Reproducibility / quiet-machine discipline

- Disable Turbo Boost: `sudo powermetrics --samplers smc -n 1` shows CPU freq;
  alternatively `sudo pmset -a disablesleep 1` + unplug charger. Simpler: accept
  variance and run min-of-5 instead.
- Kill background agents: close browser, Spotlight disabled (`sudo mdutil -a -i off`
  for the run), `pkill -9 CopilotAgent` etc.
- Warm the file cache before timing: run the command once untimed, then 3× timed.
- Record: `uname -m`, `sw_vers`, `clang --version`, `date`, machine model
  (`system_profiler SPHardwareDataType | grep 'Model\|Chip'`).

### 2c. Exact comparison matrix

| Workload | -O0 wall | -O0 RSS | -O2 wall | -O2 RSS | OCaml interp wall | Ratio |
|---|---|---|---|---|---|---|
| fib 38 | | | | | N/A (no native for interp) | |
| emitter self-compile | | | | | | native/interp |

---

## 3. Candidate hot paths (static analysis, ranked)

### 3a. IR shape summary (from `compiler/seed/emitter.ll`)

| Metric | Count |
|---|---|
| Total IR lines | 271 277 |
| Function definitions | 2 859 |
| Lambda functions (`@mdk_lam*`) | 660 |
| `call ptr @mdk_alloc` | 4 201 |
| `alloca i64` slots | 2 234 |
| `musttail call` | 37 |
| Indirect calls (`call i64 %tN(…)`) | 38 |
| Total call sites | ~18 792 |

### 3b. Hot path hypotheses (ranked by expected `-O2` payoff)

**#1 — `alloca`-slot mem2reg promotion (HIGH payoff)**

Every `if`-expression lowers to an `alloca i64` slot + `store` in each arm +
`load` after the join (`emitIf` in `llvm_emit.mdk:1701`, comment explicitly
says "clang -O0 keeps the alloca; mem2reg would promote it under -O"). There are
**2 234 alloca slots** across the IR (roughly one per `if`/`match` arm join in
the largest functions). At `-O2`, `mem2reg` promotes each to an SSA `phi`
node, eliminating 2 234 pairs of load/store + the stack slot allocation.
For compute-heavy functions (parser, emitter inner loops) this removes
substantial register-spill pressure. **Expected: major improvement in hot
compute loops.** This is the single largest `-O2` win based on IR structure.

**#2 — GC allocation density: every cons/closure/ADT allocates (MEDIUM payoff)**

`mdk_alloc` (a `GC_malloc` call) is invoked **4 201 times across the emitter IR**
— roughly 1.5× per function on average. This covers:
- Every list `Cons` cell (24 bytes via `mdk_cons`)
- Every closure capture (16–24+ bytes depending on arity)
- Every multi-field ADT constructor (tag + N fields × 8 bytes)
- String concatenation buffers
- `Ref` values (16 bytes: tag + payload)

`GC_malloc` is not free even for small objects (it touches the free list, may
trigger collection, is not inlinable by clang from a `declare`). At `-O2`,
clang can hoist allocation calls out of loops (if the GC function is marked
`noinline`), but it cannot eliminate them. **The allocation rate is a structural
property of the value representation** (uniform heap boxing) — `-O2` helps at
the margin (instruction reordering, dead-alloc elim for short-lived temps in
non-returning paths) but the main payoff here is a future change to stack-allocate
short-lived values or avoid boxing nullary constructors in hot paths.
For the fib microbenchmark specifically: each call allocates the Cons-tagged result
path — at `fib 38` this is ~126M allocations triggering GC pressure. The GC
overhead will likely dominate at -O0; `-O2` reduces surrounding code overhead but
not the allocation count.

**#3 — Dict-passing extra arguments (LOW-MEDIUM payoff from `-O2`)**

Typeclass dispatch compiles to extra `i64` arguments (runtime dictionary values
passed as leading args to constrained functions). This is visible as functions
with more args than their surface arity. At `-O0` these are passed on the stack
per ABI; at `-O2` they are register-allocated (arm64 has 8 integer argument
registers). For a self-compiled program that dispatches heavily (e.g. every `show`
/ `==` call in the type checker itself), this removes stack push/pop per dispatch.
**Expected: modest improvement for dispatch-heavy code; the inner parser loop is
mostly non-dispatching and won't see it.** Dict-passing is also an algorithmic
target (PLAN.md §Stage-3 dispatch consolidation) but that is separate from the
clang optimization level question.

**#4 — Indirect closure calls not inlineable (STRUCTURAL, not -O2 fixable)**

There are 38 indirect calls (`call i64 %tN(…)`) in the emitter IR — these are
closure dispatch sites where clang cannot devirtualize without whole-program
information. At `-O2` clang applies speculative inlining only if it can prove the
target. In practice these 38 sites are unlikely to be inlined. **The real fix is
compile-time specialization or closure conversion with known targets** — a
significant future optimization, not a `-O2` flip. Not ranked high because 38
indirect calls is small relative to the 18 792 total call sites (the vast majority
are direct named calls to `@mdk_<funcname>`).

**Note on TRMC:** PLAN.md §Stack scalability item (b) identifies TRMC
(tail-recursion-modulo-cons) as the principled fix for list-builder stack pressure.
This is orthogonal to `-O2` — TRMC is an emitter IR-generation change, not a clang
optimization. Do not conflate them. The 37 `musttail` calls already handle pure
tail recursion; TRMC is for `x :: recurse` patterns.

---

## 4. Sequenced plan for tonight's session

Execute in order; do not proceed past a failing step.

### Step 1 — Build prerequisites (5 min)
```sh
export PATH="$HOME/.opam/5.4.1/bin:$PATH"
dune build --root .   # builds medaka binary + test binaries
```
Confirm `medaka_emitter` exists (from a prior run of `bootstrap_from_seed.sh`),
or build it first:
```sh
sh test/bootstrap_from_seed.sh
```
This produces `./medaka_emitter` (the `-O0` native emitter binary, bootstrapped
from the seed).

### Step 2 — Baseline benchmarks at -O0 (20 min)
Record system info:
```sh
system_profiler SPHardwareDataType | grep 'Model Identifier\|Chip\|Memory'
clang --version
```

Run min-of-3 for each workload; record to a log file:

**Micro: fib 38**
First create `test/bench_fixtures/fib.mdk` (see §2a above). Then:
```sh
# Build at -O0 (current default)
./_build/default/bin/main.exe build test/bench_fixtures/fib.mdk -o /tmp/fib_o0
# Time
for i in 1 2 3; do /usr/bin/time -l /tmp/fib_o0 2>&1 | grep -E "real|maximum"; done
```

**Self-compile at -O0**
The `medaka_emitter` binary (already at -O0) emitting itself:
```sh
for i in 1 2 3; do
  /usr/bin/time -l ./medaka_emitter \
    stdlib/runtime.mdk stdlib/core.mdk \
    compiler/entries/llvm_emit_modules_main.mdk \
    compiler stdlib > /tmp/sc_out.ll 2>/tmp/sc_time.txt
  grep -E "real|maximum" /tmp/sc_time.txt
done
```

**OCaml interpreter self-compile (for ratio comparison)**
```sh
for i in 1 2 3; do
  /usr/bin/time -l ./_build/default/bin/main.exe run \
    compiler/entries/llvm_emit_modules_main.mdk \
    stdlib/runtime.mdk stdlib/core.mdk \
    compiler/entries/llvm_emit_modules_main.mdk \
    compiler stdlib > /dev/null 2>/tmp/interp_time.txt
  grep -E "real|maximum" /tmp/interp_time.txt
done
```

### Step 3 — Flip to `-O2` and re-run fixpoint (15 min)

Edit **both** drivers (two changes):

`lib/build_cmd.ml` line 232 — change:
```ocaml
([ cc; "-Wl,-stack_size,0x20000000" ]
```
to:
```ocaml
([ cc; "-Wl,-stack_size,0x20000000"; "-O2" ]
```

`compiler/driver/build_cmd.mdk` line 219 — change:
```
let clangArgs = ["-Wl,-stack_size,0x20000000"]
```
to:
```
let clangArgs = ["-Wl,-stack_size,0x20000000", "-O2"]
```

Rebuild:
```sh
dune build --root .
```

Confirm fixpoint still holds (**critical gate — do not skip**):
```sh
sh test/selfcompile_build_fixpoint.sh
```
Expected: `C3a PASS`, `C3b PASS`. If either fails, the `-O2` edit introduced
non-determinism in the binary (would be surprising) or changed GC behavior.
If C3a/C3b fail, revert and investigate before proceeding.

Also run the behavioral gate:
```sh
sh test/diff_compiler_build.sh
```
Expected: all programs byte-identical between compiler and OCaml builds.

Build a fresh `-O2` `medaka_emitter`:
```sh
sh test/bootstrap_from_seed.sh ./medaka_emitter_o2
```
(The seed itself is still the -O0 IR — that is fine; `bootstrap_from_seed.sh`
compiles the seed with whatever the `$CC` flags produce, and those now include
`-O2` if you edited `build_cmd.mdk` above. Alternatively pass `CC="clang -O2"`
to the bootstrap script directly — but the cleaner path is the build_cmd edit
above so both drivers are consistent.)

### Step 4 — `-O2` benchmarks (15 min)

Same commands as Step 2 but with the -O2-compiled `medaka_emitter_o2` binary:
```sh
# Micro: fib 38 (rebuild using the -O2 CLI)
./_build/default/bin/main.exe build test/bench_fixtures/fib.mdk -o /tmp/fib_o2
for i in 1 2 3; do /usr/bin/time -l /tmp/fib_o2 2>&1 | grep -E "real|maximum"; done

# Self-compile via -O2 emitter
for i in 1 2 3; do
  /usr/bin/time -l ./medaka_emitter_o2 \
    stdlib/runtime.mdk stdlib/core.mdk \
    compiler/entries/llvm_emit_modules_main.mdk \
    compiler stdlib > /tmp/sc_out_o2.ll 2>/tmp/sc_time_o2.txt
  grep -E "real|maximum" /tmp/sc_time_o2.txt
done
```

Confirm `-O2` output is byte-identical to `-O0` output for fib:
```sh
diff /tmp/fib_o0_out.txt /tmp/fib_o2_out.txt   # capture outputs first
```

### Step 5 — Compare and interpret (10 min)

Fill in the matrix from §2c. Key questions:
1. **fib 38 -O0 vs -O2**: expected 2–5× speedup (alloca promotion + instruction
   scheduling). If < 1.5×, the GC allocation overhead dominates (every Cons cell
   for the intermediate tree).
2. **self-compile -O2 vs OCaml interp**: the metric that matters for the retirement
   bar. Expected: native at -O0 already faster than interpreter; -O2 should widen
   the gap. If -O0 native is already >10× faster, the performance bar item is
   satisfied regardless.
3. **Self-compile output byte-identical across opt levels**: confirm `cmp -s`
   between `-O0` and `-O2` emitter outputs (the IR text should be identical since
   the emitter is a deterministic text-output program).

### Step 6 — Decide on opt IR-level passes (5 min)

The current pipeline has NO `opt` or `llc` step — it goes directly
`textIR → clang`. Options for IR-level passes:

- **`-O2` at clang is equivalent to running `opt -O2` on the IR** before code
  generation. No separate `opt` invocation is needed — clang at `-O2` runs the
  full middle-end pipeline (mem2reg, instcombine, GVN, loop opts, inline, etc.).
- A separate `opt` step is only useful if you want fine-grained control (e.g.
  `opt -mem2reg -instcombine` without inlining). Given the emitter IR has 2 859
  functions that are mostly small (<100 lines each), inlining is likely beneficial
  too. Recommend: use `-O2` directly, skip a separate `opt` step.
- If benchmarks show the self-compile is I/O-bound (emitter writes 9.6 MB to a
  tmp file), consider measuring the emit phase separately from the clang phase.
  Use `time ./medaka_emitter ... > /dev/null` vs `time ./medaka_emitter ... | wc -c`
  to isolate I/O.

---

## 5. Known blockers for tonight's session

**No hard blockers** identified that would prevent execution of Steps 1–6.

**Soft risks:**

1. **`bootstrap_from_seed.sh` uses `-O0` hardcoded in its comment** (line 9 says
   "clang(seed)") but the actual `$CC` call inherits whatever flags are in the
   env. If you edit `build_cmd.mdk` for `-O2`, the bootstrap script's clang call
   does NOT pick it up automatically — you need to also edit the test scripts'
   clang lines or set `CC="clang -O2"` (not idiomatic since `CC` is the compiler
   path, not flags; use `CFLAGS` or edit directly). Recommendation: edit the
   test scripts' clang calls explicitly for the perf session.

2. **Boehm GC + `-O2` conservatism.** GC conservatively scans the stack for
   pointers. At `-O2`, a pointer might be kept only in a register (no stack spill)
   — Boehm might miss it. This is Boehm's known issue with optimized code. In
   practice Medaka programs that pass `diff_compiler_build.sh` are short-lived
   enough that collection pressure is low, but a long-running compute job (fib 38
   over the full 126M calls) could trigger a collection. If the -O2 fib binary
   crashes or returns wrong results, add `-fno-omit-frame-pointer` and retry.

3. **Seed is stale** per PLAN.md note: "ELoc `c7b4c4b` re-minted; the seed goes
   stale again with B.10.2b/B.10.5/tuple — re-mint pending". Run
   `sh test/selfcompile_build_fixpoint.sh` BEFORE `bootstrap_from_seed.sh` to
   confirm C3a holds with the current sources. If C3a fails, the seed must be
   re-minted first (`sh test/refresh_seed.sh`) before the perf session can
   proceed. (The re-mint requires the OCaml build.)

4. **No `fib.mdk` benchmark fixture exists yet.** Must be created (5 lines —
   trivial, but confirm it compiles and runs correctly before timing it). Use
   `fib 38` for native; the interpreter will take minutes on `fib 38` — use
   `fib 30` for the interpreter comparison instead (~1M calls, ~few seconds).

---

## Summary (for the session log)

- **6 clang invocations**, all at implicit `-O0`. One-line change: add `"-O2"` to
  the `clangArgs` list in `lib/build_cmd.ml:232` and `compiler/driver/build_cmd.mdk:219`.
  Shell scripts need manual edits for their bootstrap paths.
- **`-O2` does NOT threaten the fixpoint.** The fixpoint compares emitted text IR
  (pre-clang), which is invariant to clang optimization level.
- **Top 3 hot-path hypotheses:**
  1. `alloca` mem2reg (2 234 slots → SSA promotion at `-O2`) — expected 2–5× on
     compute-heavy loops.
  2. GC allocation density (4 201 `mdk_alloc` calls) — structural, not -O2-fixable;
     future value-rep / stack-alloc work.
  3. Dict-passing register pressure (extra `i64` args now register-allocated at
     `-O2` vs stack-passed at `-O0`) — modest improvement on dispatch-heavy code.
- **No `opt` IR pipeline needed.** Clang `-O2` subsumes `opt -O2`; add a separate
  `opt` step only if profiling shows a specific IR pass is needed that `-O2` skips.
