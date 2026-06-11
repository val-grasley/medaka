# PERF-RESULTS.md — native-backend performance log

Running log of measured native-backend performance. Companion to
`selfhost/PERF-SCOPE.md` (the scoping/plan). Each entry: what changed, the
gate state, and the numbers (min-of-N, single-threaded, quiet machine).

## Machine / toolchain

| | |
|---|---|
| Chip | Apple M5 (10-core: 4 P + 6 E), 32 GB |
| OS | macOS 26.5 (25F71) |
| clang | Apple clang 21.0.0 (clang-2100.0.123.102) |
| Date | 2026-06-10 |

Method: `/usr/bin/time -l`, min-of-3 unless noted, cache pre-warmed, no parallel
CPU work during timing runs.

Reproduce with **`sh test/bench.sh`** (`--quick` for micros only, `--interp` to
add the OCaml-interpreter self-compile, `-n N` for min-of-N). It builds each
fixture via `medaka build` so it always reflects the current build-driver flags.

Workloads:
- **fib 38** (`test/bench_fixtures/fib.mdk`) — exponential tree recursion,
  pure Int, **no heap allocation** → isolates raw codegen, zero GC.
- **self-compile** — the native emitter binary emitting its OWN module graph
  (`runtime.mdk core.mdk llvm_emit_modules_main.mdk selfhost stdlib`),
  emits 10 119 834 bytes of text IR. The heaviest representative workload.

---

## Entry 1 — Baseline -O0 + flip to -O2 (2026-06-10)

**Change:** added `-O2` to the clang link step in both build drivers
(`lib/build_cmd.ml:233`, `selfhost/build_cmd.mdk:219`). Previously all 6 clang
invocations ran at implicit `-O0`.

**Gates (all green, both at -O2):**
- `test/selfcompile_fixpoint.sh` (emit driver) — C3a YES, C3b YES.
- `test/selfcompile_build_fixpoint.sh` (build driver) — C3a YES, C3b YES.
- `test/diff_selfhost_build.sh` — 9/9 programs byte-identical (OCaml vs selfhost
  build, GC correct under -O2; no `-fno-omit-frame-pointer` needed).
- `dune build --root .` clean.
- Emitter self-compile IR **byte-identical -O0 vs -O2** (`cmp -s` clean) and
  fib output identical → `-O2` is behavior-preserving, fixpoint-safe (text IR is
  pre-clang, as predicted in PERF-SCOPE §1c).

**Numbers (min-of-3 wall / max-RSS):**

| Workload | -O0 wall | -O0 RSS | -O2 wall | -O2 RSS | OCaml interp wall | interp RSS |
|---|---|---|---|---|---|---|
| fib 38 | 0.11 s | 2.31 MB | 0.10 s | 2.33 MB | n/a | n/a |
| self-compile | 12.04 s | ~770 MB | **9.78 s** | **162 MB** | 125.35 s | 1467 MB |

**Headline findings:**
- **Native vs OCaml interpreter (the retirement bar):** native -O0 is **10.4×**
  faster than the interpreter (12.04 s vs 125.35 s) and uses **1.9×** less memory;
  native -O2 widens it to **12.8×** faster and **9.1×** less memory. The
  performance bar for OCaml retirement is satisfied with comfortable margin.
- **-O2 self-compile:** ~18 % wall-clock improvement (12.04→9.78 s) and a
  **4.7× drop in peak RSS** (770→162 MB). The RSS collapse is the standout win —
  consistent with `mem2reg` promoting the 2 234 `alloca` slots out of the
  emitter's hot functions (PERF-SCOPE §3b#1), eliminating stack-spill pressure.
- **fib 38:** essentially flat (0.11→0.10 s). Expected — fib allocates nothing
  and the inner loop is already register-tight at -O0; there is no alloca/GC
  overhead for -O2 to remove. Confirms the self-compile win comes from
  alloca/spill elimination, not arithmetic.

**Cost / tradeoff:** clang `-O2` of the 10 MB emitter IR makes the *build* step
much slower (emitter native build ~127 s at -O2 vs a few s at -O0). This is a
one-time compile cost paid by `medaka build`; runtime + RSS improve. Acceptable
for the compiler binary; revisit if per-invocation build latency matters for
small user programs (could gate -O2 on input size).

**Next candidates (PERF-SCOPE §3b, not yet done):** TRMC for `x :: recurse`
list builders (PLAN #56); reduce GC allocation density on hot paths (4 201
`mdk_alloc` sites) — structural, beyond what -O2 reaches.

---

## Entry 2 — Boehm GC free-space-divisor tuning (2026-06-10)

**Change:** `runtime/medaka_rt.c` `mdk_gc_init` now calls
`GC_set_free_space_divisor(1)` after `GC_INIT()` (was the default, 3), unless
`GC_FREE_SPACE_DIVISOR` is set in the environment. A lower divisor lets the heap
grow further between collections → fewer collection cycles. This is a **runtime**
change only — it is NOT in the emitter module graph, so the seed and the
text-IR fixpoint are unaffected by construction.

Motivation: after Entry 1, the emitter self-compile was GC-bound — RSS had
dropped to 162 MB (lots of headroom) but wall-clock was still 9.78 s, dominated
by collection of the ~4 200 cells/run + every cons/closure. The default divisor
optimizes for low RSS at the cost of collection frequency; Medaka's short-lived
allocation-heavy workloads prefer the opposite trade.

**Gates (all green):** `dune build --root .` clean; `selfcompile_fixpoint.sh`
C3a/C3b YES; `diff_selfhost_build.sh` 9/9 byte-identical; self-compile emitted IR
byte-identical to Entry-1 output; listsum output unchanged.

**Numbers (min-of-3 self-compile, min-of-5 listsum; all -O2):**

| Workload | -O2 default GC | -O2 divisor=1 | Δ wall | RSS default→tuned |
|---|---|---|---|---|
| self-compile | 9.78 s | **6.25 s** | **−36 %** | 162 → 229 MB |
| listsum (20M cons) | 0.11 s | 0.11 s | flat | 3.1 → 3.7 MB |

**Cumulative vs the original -O0 / default-GC baseline:**

| Workload | original (-O0, div 3) | now (-O2, div 1) | speedup | RSS |
|---|---|---|---|---|
| self-compile | 12.04 s / 770 MB | **6.25 s / 229 MB** | **1.93×** | 3.4× less |
| vs OCaml interpreter | 125.35 s | 6.25 s | **20.1×** | 6.4× less |

**Findings:**
- GC collection frequency, not codegen, was the dominant self-compile cost after
  -O2. Trading ~67 MB of peak RSS for divisor=1 buys a 36 % wall-clock cut.
- The native compiler is now **~20× faster than the OCaml interpreter** at the
  representative self-compile workload — the perf bar for OCaml retirement is met
  with wide margin.
- listsum (pure cons churn, tiny live set) is unaffected — its GC cost was
  already negligible; the win is specific to workloads with a large transient
  working set like the emitter.
- divisor=1 is bounded: heap grows to ~2× the live set, so RSS stays well under
  the -O0 baseline. Env var `GC_FREE_SPACE_DIVISOR` overrides for memory-tight
  deployments.

**Next candidates:** TRMC (PLAN #56) for list-builder stack pressure; profile the
remaining 6.25 s self-compile to see whether it is now emit-logic-bound or still
alloc-bound (try divisor=2 as a memory/speed midpoint; measure GC_get_heap_size).

**Divisor sweep (self-compile, min-of-3, -O2, via `GC_FREE_SPACE_DIVISOR`):**

| divisor | wall | RSS | note |
|---|---|---|---|
| 1 | 6.26 s | 218 MB | chosen — speed floor |
| 2 | 8.36 s | 175 MB | midpoint |
| 3 | 10.35 s | 153 MB | Boehm default |
| 4 | 11.23 s | 154 MB | |

Monotonic: lower divisor → fewer collections → faster, more RSS. The curve shows
GC still costs ~40 % of self-compile wall-clock at the default — collection, not
codegen, was the bottleneck. divisor=1 is the practical floor (218 MB stays 3.5×
under the -O0 baseline's 770 MB), so it is the chosen default.

---

## Entry 3 — allocation profile + initial-heap knob (investigation, 2026-06-10)

**Profile (Boehm `GC_PRINT_STATS=1`, self-compile, divisor=1):** **265 full
collections**, each world-stop marking ~27 ms over a live set of only **~45 MB**;
~100 MB churned and freed *per* collection → on the order of **~26 GB of
transient garbage** allocated to emit 10 MB of IR (~2600× write amplification).
The live set is tiny and stable; the cost is re-marking it hundreds of times.
This is the structural GC-density issue (PERF-SCOPE §3b#2): the emitter builds
enormous transient string garbage (`++`, `intToString`, `freshReg`, …).

**Initial-heap sweep (env `GC_INITIAL_HEAP_SIZE`, divisor=1, min-of-2):**

| initial heap | wall | RSS |
|---|---|---|
| default growth | 6.16 s | 216 MB |
| 256 MB | 4.91 s | 341 MB |
| 512 MB | 4.39 s | 569 MB |
| 1 GB | 3.99 s | 1152 MB |
| 2 GB | 3.72 s | 2255 MB |

A bigger starting heap collects less often → faster, but RSS scales ~1:1 with the
heap. **Not baked as a default:** a fixed large initial heap would regress every
tiny program (fib's RSS would jump from 2 MB to 256 MB+ resident). Instead it is a
**tuning knob** — for heavy compiles, `GC_INITIAL_HEAP_SIZE=512000000 medaka build …`
trades RSS for ~30 % more emit speed. The universal default stays divisor=1 / grow
on demand.

**Conclusion / next:** the remaining self-compile cost is dominated by transient
string allocation in the emitter, not codegen. The principled fixes are
emitter-side (reduce string churn: build output with fewer intermediate `++`
concatenations; reuse buffers) and are the highest-value remaining perf work,
but they touch the emitter module graph and must preserve the byte-identical
fixpoint — to be done as carefully-gated emitter changes. The clang `-O2` +
GC-divisor wins are banked and universal; the heap-size knob is documented for
heavy batch use.

---

## Entry 4 — emitter lifted-define buffer: O(N²) → O(N) (2026-06-10)

**Change:** `selfhost/llvm_emit.mdk` accumulated all lifted-lambda / global /
impl `define`s into the `lamsRef` side buffer with `acc ++ reverseL chunk` at 10
append sites — each append copies the *entire growing* buffer, so building the
side buffer was **O(N²)** in the number of accumulated lines. Switched the buffer
to reverse (newest-first) order: each site now **prepends** its chunk
(`chunk ++ acc`, copying only the small chunk → amortized O(N) total), and the
single consumer `reverseL`s once at module end. Uses
`reverseL (a ++ b) = reverseL b ++ reverseL a`, so the emitted order is provably
unchanged.

**Gates (all green):**
- `selfcompile_fixpoint.sh` — C3a YES, C3b YES (emitter reproduces itself
  byte-for-byte under the new buffer logic).
- `diff_selfhost_llvm` 172/172, `diff_selfhost_llvm_typed` 37/37,
  `diff_selfhost_llvm_modules` 8/8 — **217 fixtures byte-identical to the
  unchanged OCaml emitter oracle**, proving the reorder is output-preserving.
- `diff_selfhost_build.sh` 9/9 byte-identical.
- ⚠️ Seed (`selfhost/seed/emitter.ll`) is now stale (emitter graph changed). Per
  policy NOT re-minted here — fixpoint verified instead; human re-mints at a
  checkpoint.

**Numbers (self-compile, min-of-3, -O2 + divisor=1):**

| | wall | RSS |
|---|---|---|
| before (Entry 2) | 6.16 s | 216 MB |
| after lams O(N) | **5.49 s** | 198 MB |

~11 % wall, ~8 % RSS. Modest because the lams buffer is only one of many
allocation sources in the full self-compile pipeline, but it is a genuine
algorithmic fix (O(N²)→O(N)) on the emitter's own output path and removes a
quadratic that would worsen as the compiler grows.

**Cumulative vs original -O0 / default-GC baseline:**

| Workload | original | now | speedup |
|---|---|---|---|
| self-compile | 12.04 s | **5.49 s** | **2.19×** |
| vs OCaml interpreter | 125.35 s | 5.49 s | **22.8×** |

---

## Entry 5 — DCE reachability: O(N²) list appends → O(1) prepends (2026-06-10)

**Profile first.** `sample` on the emitter during self-compile (2 GB heap to
isolate compute from GC) ranked the hot symbols: O(N²) dedup/closure routines
dominate — `dedupSGo`/`clausesFor` (typechecker), and the DCE pass
(`addRefs`/`filterReachable`/`dedupAgainst`/`closure`).

**Change (`selfhost/dce.mdk`):** the DCE reachability result is consumed *only* by
`filterReachable`'s membership test (`contains n reach`), and `filterReachable`
emits decls in their original order — so the reachable list's **order and
duplicates are irrelevant**, only its set membership matters. That makes every
`acc ++ [x]` / `visited ++ fresh` / `work ++ fresh` / `v ++ rs` append (each
O(len) inside a loop → O(N²)) safe to flip to an O(1) prepend (`x :: acc`,
`fresh ++ visited`, `rs ++ v`). The closure fixpoint set is unchanged.

**Gates:** `selfcompile_fixpoint` C3a/C3b YES; `diff_selfhost_build` 9/9
byte-identical; `diff_selfhost_llvm` 172/172; `diff_selfhost_llvm_modules` 8/8.
Set membership is provably invariant under the reorder. (Seed stale — dce.mdk is
in the emit graph; fixpoint verified, not re-minted.)

**Numbers (self-compile, min-of-3, -O2 + divisor=1):** 5.49 s → **5.33 s**
(~3 %), RSS flat at 199 MB. Modest — the append-quadratic was only part of the
DCE cost; the remaining `contains` membership scans are still linear-per-element
(a future hash-set conversion, safe for the same set-invariance reason, would
remove them). Banked because it is correct, verified, and kills a quadratic that
grows with the compiler.

**Remaining hotspots (profiled, not yet addressed):** typechecker `dedupSGo` /
`clausesFor` / `groupNames` are O(N²) over the whole-program clause list and rank
above DCE, but they sit on the typecheck output path (not order-invariant) and a
safe rewrite needs O(1) membership (hash set) with full differential
re-verification — deferred as higher-risk than tonight's banked wins warrant
unattended.

---

## Entry 6 — negative results (don't re-investigate) (2026-06-10)

Tested and **rejected** — recorded so future sessions skip them:

- **`-flto`** (clang LTO, on top of -O2): listsum flat (0.11→0.10 s, noise),
  self-compile **no gain** (5.50 s vs 5.33 s, RSS slightly worse), build time
  unchanged (~128 s). `mdk_alloc` is a thin `GC_malloc` wrapper and `GC_malloc`
  lives in the `-lgc` dylib (not LTO-visible), so the inlinable surface is tiny.
  Reverted.
- **`GC_MARKERS` parallel marking** (env sweep 1/2/4/8): within noise of the
  divisor=1 baseline (markers=4 ~5.27 s vs markers=1 ~5.67 s, ranges overlap).
  The brew `bdw-gc` likely lacks parallel-mark, or marking isn't the
  parallelizable bottleneck. Not baked — would add GC threads + nondeterminism to
  a conservative collector for no reliable gain.
- **`GC_INITIAL_HEAP_SIZE` large default** (Entry 3): real speedup but RSS scales
  1:1 → regresses tiny programs. Kept as an env knob, not a default.
- **`GC_set_all_interior_pointers(0)`**: potential mark speedup, but unsound to
  flip without a full audit that no pointer ever targets an object interior
  (conservative-GC premature-free bugs are nondeterministic and won't reliably
  surface in the small build gate). Not attempted unattended.
- **hash-set for typecheck/DCE membership**: the principled O(N) fix for the
  remaining O(N²) `contains` scans, but `stdlib/hash_set.mdk` is not yet in the
  emit graph and its `Hashable`/`Eq` constrained dispatch + mutable `Array`
  resize risk the parked route-fragile dispatch gaps (#54/#55/#50/#21). Deferred
  to a supervised session.

## Final state (this session)

| Workload | original (-O0, div 3) | final | speedup |
|---|---|---|---|
| emitter self-compile | 12.04 s / 770 MB | **3.51 s / 200 MB** | **3.43× / 3.9× less RSS** |
| vs OCaml interpreter | 125.35 s / 1467 MB | 3.51 s / 200 MB | **35.7× / 7.3× less RSS** |
| fib 38 (no alloc) | 0.11 s | 0.10 s | flat (already optimal) |

Banked, all universal defaults, every change gated byte-identical (fixpoint +
differential fixtures + build gate): clang `-O2`, GC `free_space_divisor=1`,
lifted-define buffer O(N²)→O(N), DCE reachability+graph O(N²)→O(N) via HashMap,
typecheck dep-graph + SCC clause grouping O(N²)→O(N·log N) via SMap. The native
compiler is **~36× faster than the OCaml interpreter** at the representative
self-compile workload — the OCaml-retirement performance bar is met with wide
margin.

---

## Entry 9 — typecheck dep-graph membership O(N²) → O(N·log N) (2026-06-11)

**Profile** ranked `keepGroupNames` / `clausesFor` (the let-group dependency-graph
builder, `depGraphMap`) among the top compute hotspots. `buildAdj` calls
`depsOf name allNames defs` for every top-level name, and `keepGroupNames allNames
refs = filterList (r => containsName r allNames) refs` did a linear `containsName`
scan of *all* top-level names per ref → O(names²·refs) over the whole compiler.

**Change (`selfhost/typecheck.mdk`):** build an `SMap Unit` name-membership set
**once** (`namesToSet`, the in-tree balanced BST already used for the adjacency
map) and thread it through `buildAdj`/`depsOf`; `keepGroupNames` now tests
`smHasKey` (O(log n)) instead of `containsName` (O(names)). `filterList` is
unchanged, so the dependency lists — and therefore the Tarjan SCC order, the
type-inference order, and all emitted output — are **byte-identical**; only the
membership test is faster.

**Gates (byte-identical output, comprehensively):** `diff_selfhost_check` 40/40;
`diff_selfhost_typecheck` 12/12; `diff_selfhost_typecheck_golden` 25/25;
`selfcompile_fixpoint` C3a/C3b YES (self-compile runs selfhost typecheck over the
*whole compiler* — the strongest invariance test); `diff_selfhost_build` 9/9;
`diff_selfhost_llvm` 172/172. Seed stale (typecheck.mdk in emit graph); not
re-minted.

**Numbers (self-compile, min-of-4, -O2 + divisor=1):** 4.69 s → **4.13 s** (~12%).
The single largest algorithmic win after the GC/-O2 infra changes — the dep-graph
membership was genuinely O(N²) over ~2 800 top-level names.

**Cumulative this session:** 12.04 s → 4.13 s (**2.92×**); vs OCaml interpreter
125.35 s → 4.13 s (**30.3×**).

**Note on safety:** this touches the typechecker (the most delicate module), but
the change is membership-only and order-preserving by construction, and was held
to the full differential-vs-oracle gate set above. `clausesFor`'s per-name rescan
(the smaller O(names·defs) cost) remains; grouping defs by name once would remove
it but requires order-preserving group-by (foldr or prepend+reverse) — a safe
follow-up.

---

## Entry 10 — typecheck `clausesFor` group-by (2026-06-11)

**Change (`selfhost/typecheck.mdk`):** the follow-up flagged in Entry 9.
`depsOf` re-scanned all defs (`clausesFor name defs`, O(defs)) for every name →
O(names·defs). Now `depGraphMap` groups defs by name **once** into an
`SMap (List clauses)` (`groupClauses`, built by O(1) prepend; `clausesOf`
reverses on read to restore defs order), and `depsOf` does an O(log n) lookup.
The per-name clause list is identical to the old `clausesFor` (same clauses, same
order), so dep lists / SCC order / output stay byte-identical.

**Gates:** `diff_selfhost_check` 40/40; `diff_selfhost_typecheck_golden` 25/25;
`selfcompile_fixpoint` C3a/C3b YES; `diff_selfhost_build` 9/9; `diff_selfhost_llvm`
172/172. Seed stale; not re-minted.

**Numbers (self-compile, min-of-4, -O2 + divisor=1):** 4.13 s → **4.00 s** (~3%).
With Entry 9 the typecheck dep-graph build is now fully O(N·log N). **Crossed 3×:**
cumulative this session 12.04 s → 4.00 s (**3.01×**); vs OCaml interpreter 31.3×.


---

## Entry 8 — DCE graph also via HashMap; full O(N) DCE (2026-06-11)

**Change (`selfhost/dce.mdk`):** completed the DCE rewrite — the call graph
(`funGraph`/`addRefs` assoc list, O(N²) to build; `refsOf` O(N) scan) is now a
`HashMap String (List String)` with O(1) insert/merge/lookup, and the visited set
is a `HashMap String Unit` (replacing Entry 7's `HashSet` — `hash_map` carries
both, avoiding the `new`/`insert` name clash from importing two containers, since
Medaka aliased imports `import m as M` are **not** supported by the self-hosted
emitter). The whole DCE pass is now ~O(reachable + edges); reachable set
unchanged → output byte-identical.

**Gates:** `medaka check` clean (93 bindings); `selfcompile_fixpoint` C3a/C3b YES;
`diff_selfhost_build` 9/9; `diff_selfhost_llvm` 172/172. Seed stale; not re-minted.

**Numbers (self-compile, min-of-4, -O2 + divisor=1):** 4.98 s → **4.69 s** (~6%),
RSS ~207 MB. DCE is no longer a profile hotspot.

**Cumulative this session:** 12.04 s → 4.69 s (**2.57×**); vs OCaml interpreter
125.35 s → 4.69 s (**26.7×**).


---

## Entry 7 — DCE membership via HashSet: O(N²) → O(N) (2026-06-11)

**Change (`selfhost/dce.mdk`):** the reachability closure and `filterReachable`
used linear-scan `contains` for set membership (O(N²) over the reachable set).
Replaced the visited set with a `stdlib/hash_set.mdk` `HashSet String`: the
closure is now a BFS that `insert`s each unseen name and skips seen ones (O(1)
average `member`), and `filterReachable` tests `member` per decl. The reachable
**set** is identical (membership-only consumption — order/dups never surface;
`HashSet` is never iterated), so output is byte-identical.

**De-risking:** `hash_set` was not previously in the emit graph. Verified first
that a `hash_set` user program self-compiles AND runs correctly via the native
backend (insert/member, `Hashable`/`Eq String` dispatch — NOT blocked by the
parked dispatch gaps). Only then imported it into `dce.mdk`.

**Gates:** `medaka check` clean (93 bindings); `selfcompile_fixpoint` C3a/C3b YES
(emitter self-compiles **with hash_set now in its own graph** and reproduces
byte-for-byte); `diff_selfhost_build` 9/9; `diff_selfhost_llvm` 172/172;
`diff_selfhost_llvm_modules` 8/8. Seed stale (emit graph changed); fixpoint
verified, not re-minted.

**Numbers (self-compile, min-of-3, -O2 + divisor=1):** 5.33 s → **4.98 s**
(~7 %), RSS flat ~199 MB. The remaining DCE cost is the `funGraph`/`addRefs`
graph build and `refsOf` linear scan (both still O(N)·assoc); hashing the graph
map would remove them next.

**Significance beyond the number:** this is the first use of `hash_set` in the
emitter's own module graph, proven self-compiling and fixpoint-stable. It
unblocks the higher-value typechecker O(N²) work (`dedupSGo`/`clausesFor`/
`groupNames`), which was deferred precisely because O(1) string membership had no
emit-proven structure — now it has one. That conversion is still
output-order-sensitive (typecheck SCC/tyvar order) and should be done supervised,
but the structural blocker is cleared.








---

## Entry 11 — typecheck SCC clause lookup: whole-defs scan → grouped lookup (2026-06-11)

**Change (`selfhost/typecheck.mdk`):** `processSCCs` passed the **whole** top-level
defs list (~2 800) to every `processSCC`, and `inferMembers`/`sccSchemes` then did
`clausesFor m defs` (a full O(defs) scan) for every SCC member → O(members·defs) =
O(N²) over the whole compiler. This `clausesFor` was the #1 profile hotspot.
Now `processTopGroups` builds the `groupClauses` SMap **once** and threads it
(replacing the raw `defs` arg) through `depGraphMap` + `processSCCs` →
`processSCC` → `inferMembers`/`sccSchemes`, which look up `clausesOf m grouped`
(O(log n)). Per-member clause lists are identical → output byte-identical.

**Gates:** `diff_selfhost_check` 40/40; `diff_selfhost_typecheck` 12/12;
`typecheck_golden` 25/25; `selfcompile_fixpoint` C3a/C3b YES; `diff_selfhost_build`
9/9; `diff_selfhost_llvm` 172/172. Seed stale; not re-minted.

**Numbers (self-compile, min-of-5, -O2 + divisor=1):** 4.00 s → **3.51 s** (~12%).
Eliminated the largest remaining hotspot. Cumulative this session: 12.04 s →
3.51 s (**3.43×**); vs OCaml interpreter 35.7×.
