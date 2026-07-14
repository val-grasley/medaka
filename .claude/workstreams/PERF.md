# Workstream: PERF

**Owns:** quadratics and constant factors in the compiler.
**Touches:** `compiler/frontend/resolve.mdk`, `compiler/tools/check.mdk`, `compiler/types/`.

```sh
gh issue list --label "ws:perf" --state open
```

**Load the `perf-hunt` skill before you start.**

**The gate:** `test/diff_compiler_perf_scaling.sh` — it grades **ALLOCATION** *and* (since #110) **TIME,
per stage**. GC bytes are deterministic, so allocation is machine-independent and noise-free, which no
timing gate can be on a shared runner; it stays the **primary** verdict. Ratio per input doubling: linear
≈2.0×, n·log n ≈2.1×, **quadratic ≈4.0×**.

---

## ⚠️ THE THREE MEASUREMENT TRAPS (2026-07-14 — each produced a confidently WRONG answer first)

### 1. TIME and ALLOCATION diverge. Grading one HIDES the other.
**A `List` `contains` allocates NOTHING** — it is a pure traversal. So an O(n²)-in-time / O(n)-in-allocation
defect is **invisible to an allocation-graded gate**. This is not hypothetical: it hid **two** real bugs.

| bug | time ratio | allocation ratio |
|---|---|---|
| #78 `resolve` O(refs×decls) | 2.63×, **3.56×** → quadratic | 2.09×, 2.11× → *"ok"* |
| #115 `typecheck` union-find | 3.17×, 4.15×, **6.69×** → *worse than* quadratic | 1.52×, 1.72×, **1.87× → SUBLINEAR** |

**#115's ledger row even said the bug was FIXED — because the ALLOCATION half had been.** The time-side
blow-up survived for a day under a green gate. **Ask of any perf gate: what defect class can my metric
physically not see?**

### 2. ⚠️ THE GC FAKES A QUADRATIC IN WALL-CLOCK. Pin the heap.
On a **correct** compiler, per-stage time reads `exhaust-guards` **3.25×**, `desugar` 2.72× — apparently
quadratic. They are not: at the next doubling they **collapse** (3.42 → 2.07, 2.91 → 2.16). A real quadratic
*holds* ~4.0; this is a **STEP, not a curve** — a Boehm heap resize inside the measured range.

> **`GC_INITIAL_HEAP_SIZE=2147483648` on every timing run.** It removes the step (3.25 → 2.17). The knob
> cannot change emitted IR, so it is always safe. **An unpinned time measurement is a false-red generator.**

### 3. NEVER grade a SUM of stages. Grade PER-STAGE.
Dilution can only push a ratio **DOWN toward 1.0** — so a summed ratio reading **above** 2.0 means something
in it is genuinely superlinear. A first cut of the #110 gate summed 4 stages and was silently adding the
GC-step artifacts *into* resolve's clean signal:

| metric | green (correct) | red (broken) | margin |
|---|---|---|---|
| summed 4 stages | 2.39–2.86 | 3.17–3.44 | **~8%** — would have flaked on CI |
| **per-stage, heap pinned** | 2.12–2.35 | 3.56–3.89 | **~22% both sides** |

Per-stage costs **nothing extra** — same runs, different accounting — and it names *which* stage regressed.

### The rule that ties them together (for any new perf gate)
> **An ABSOLUTE number may only be gated if the metric is DETERMINISTIC. A NOISY metric may only be gated as
> a self-normalizing RATIO, with generous headroom.**

Wall-clock on a shared runner ⇒ **never** an absolute ceiling. But a *ratio* is self-normalizing, and linear
(2.0) vs quadratic (4.0) has a full 2× of headroom. Make it non-flaky with **min-of-K**: runner noise is
**one-sided** (a stall only makes a run *slower*, never spuriously faster), so the **minimum** converges on
the true cost from above. Plus: fail only on a **sustained** signal (both doublings), and enforce an absolute
**floor** per stage — a 10–70 ms stage is too small to time-gate and must **SKIP LOUDLY**.

⚠️ **And a LEDGERED stage may never SKIP.** When #115's fix took `match:typecheck` from 6.0 s to 75 ms, it fell
*under* the floor and the SKIP arm swallowed the stale ledger entry — the gate printed *"0 known-superlinear,
0 regressed"* and **exited 0**. Dropping below the floor is not an *absence* of signal for a ledgered stage;
**it IS the signal.** "Too fast to measure" is what fixed looks like, and it must demand promotion.

---

## A PERF FIXTURE CAN BE STRUCTURALLY UNABLE TO TRIGGER THE PATH

`gen_bindings` emitted `fN x = x + N` — **every body referenced only the local `x`**, so `lookupValue`'s
short-circuiting `||` hit on element 1 and **never once scanned `env.values`**. N top-level bindings, all
mutually unreferenced: **a shape no real program has.** One character (`x + N` → a call to `f(N-1)`) and it
goes quadratic. **A perf fixture must look like real code — and cross-referencing is the part always
forgotten.** Hence the `xref` shape.

---

## ⚠️ NOT every quadratic is a List. #115 was a UNION-FIND WITHOUT PATH COMPRESSION.

The "a List scanned once per element" shape below is the *most common* cause, not the only one — and
assuming it cost real time on #115. **The list scans were an amplifier, not the bug.** Stubbing them out
made it 3.6× faster and **left the ratio at 6.23× — still superquadratic.**

The real cause: `normalize` was a union-find FIND with **no path compression**, and `unifyVars` always links
the current root to the *fresh* var it meets. Inferring **one large declaration** (an N-arm `match`, an
N-element list literal) builds a `Link` chain of length N; every later `normalize` walks it. **O(N²)+ link
steps in a loop that allocates nothing.**

**How it was named — this is the technique to copy.** `perf record --call-graph dwarf,16384`, then a
**stack-depth histogram** of the hot symbol's samples:
```
57.08%  mdk_types_typecheck__rootIdOf     <- flat top
20.66%  mdk_types_typecheck__normalize
 2.52%  GC_malloc_kind                    <- allocation is NOTHING here
...
   2 120      <- rootIdOf frames per sample
   4 125
2315 127      <- perf's max-stack limit. The chains are DEEPER than perf can dump.
```
**`rootIdOf` was not hot from call COUNT — each call recursed hundreds of frames deep.** A flat profile alone
would have sent you hunting a hot loop that does not exist. **When a symbol dominates, check its stack
DEPTH, not just its count.**

Discriminator worth stealing: the blow-up needed **one BIG declaration**, not many. `xref` has **16 000
top-level decls and typechecks linearly**. If a fixture with many small decls is linear but one with a single
large decl is not, you are looking at something that grows *within* one inference — a chain, a substitution,
a constraint set — not a per-decl scan.

---

## Where `medaka build` time ACTUALLY goes (measured 2026-07-14) — it is NOT the front end

**`medaka build` / CI is CLANG-BOUND. `medaka check` (LSP) is GC-BOUND. These are DIFFERENT problems and
conflating them wastes a session.**

Originally, for a **9-line** program (with `MEDAKA_RT_OBJ` on): front end **12%**, **`clang -O2` 77%**, emit+link
11%. It emitted **32,896 lines of IR — 272 `define`s, exactly ONE of which was its own.**

### ⭐ And ~80% of that IR was TYPECLASS DISPATCH CHAINS
Not prelude *logic* — dispatch. **2,123 `icmp` arm-pairs** to express **9 distinct chains**, because the chain was
**inlined at every one of 107 dispatch sites.** A Medaka dict carries **no code pointer** (it is a type TAG), so
"project a method from a dict" *means* a linear scan over every impl of that method — and that scan was copied
into every caller.

**Fixed by OUTLINING** (#129): one shared `@mdk_disp_<method>_<nMeth>_<nArgs>` per method. **IR −64%, binaries
−47%.** Then **`prelude.o`** (#131) cached the now-program-independent prelude: **build 2×**, engines gate
**67 s → 43 s**. Compound: **`medaka build` 1.06 s → 0.343 s (3.1×).**

- ⚠️ **Dispatch is OUTLINED, not inlined at the site.** Debugging a dispatch miscompile? **The arm you want is in
  `@mdk_disp_*`, not at the call site.** `test/diff_compiler_dispatch_shape.sh` pins this — and pins that prelude
  bodies stay **program-independent**, the precondition for `prelude.o`.
- ⚠️ **`soleImplDirect` is a live silent-miscompile hazard for anything CACHED.** A site may shortcut to a direct
  call when a method has exactly **one** impl — true of the prelude alone, **FALSE the moment a user program adds
  one.** Baking that into a cached `prelude.o` would direct-call the wrong impl in every program that links it,
  and **no fixture would catch it.** Under `MEDAKA_PRELUDE_OBJ` the shortcut lives **inside the dispatcher**
  (per-program, recomputed from the whole-program impl table).

### ⚠️ Shortcuts that are DEAD — measured, do not re-try
- **`MEDAKA_CLANG_OPT=-O0`** (the knob exists; its own comment says `-O2` "buys little"). Cuts the engines gate
  40% and is **UNSOUND**: it **regresses `wasm/clos_reftco_indirect`** — clang's tail-call elimination for
  **indirect** calls only runs at `-O1`+. **The deep-TCO trap bites LLVM, not just wasm.**
- **`-O1`** — saves ~10%. Not worth a semantics risk.
- **Option E (give dicts method slots / a vtable)** — the "obvious" fix, and **dominated**. `requires` arity varies
  per impl, so a uniform indirect call needs a trampoline anyway ⇒ it converges on outlining's IR for **~3%** more,
  and it needs the interface at dict-construction (`RKey` carries none — `Eq Int` and `Ord Int` build **identical
  cells**), which means an AST change to `Route` that `eval`/`wasm` pattern-match ⇒ **escapes the backend blast
  radius.** Full analysis: `compiler/PRELUDE-OBJ-DESIGN.md`.
- **Chain DEPTH is not a runtime cost.** 31 vs 159 arms = **1.05×** (non-monotonic ⇒ noise): the branch predictor
  nails the always-taken path. But IR grows **linearly** in arms (2.00× IR, 1.72× build). **The chain costs COMPILE
  time, not RUN time** — which is why outlining wins and a vtable does not.

---

## The method that has now worked eleven times

**Every single quadratic found so far was the same shape: a `List` scanned, `elem`-checked, `lookup`-ed,
or REBUILT once per element.** Note `xs ++ [x]` inside a fold is O(n²) all by itself, since list append
is O(n).

1. **`MEDAKA_PERF=1 test/bin/profile_main <runtime> <core> <target>`** — per-stage time AND allocation.
   **Allocation is the reliable signal**: deterministic, no runner noise, and it exposed every one of
   them more sharply than wall-clock did.

2. **`perf record --call-graph dwarf,16384`** to NAME the hot symbol. **This works** — the emitted LLVM
   carries CFI. (An older doc claimed call graphs were unusable; that was wrong and cost an agent a
   wrong turn.)
   **But flat counts profile TIME while the gate grades ALLOCATION, and on this workload they point at
   different functions.** Pipe `perf script` through a filter that attributes each `GC_malloc_kind`
   sample to its nearest `mdk_` frame — allocation attribution is what the gate measures.

3. ⚠️ **`whenL False (expensiveCall …)` is NOT a stub.** Medaka is **STRICT** — the argument still
   evaluates. This produced a false *"hypothesis disproved"* on a **correct** hypothesis. To stub
   something out, actually remove the call.

---

## ⚠️ Benchmarking an EMITTER change needs TWO rebuilds

A binary's **behavior** comes from its **source**; its **speed** comes from **the emitter that compiled
it**. One `FORCE_EMITTER_REBUILD=1 make medaka` after an emitter change gives you new behavior in **old
machine code** — build a "before" and "after" that way and **the binaries are crossed**. An agent
measured its own **2.2× win as a 2.5× SLOWDOWN** and nearly abandoned it.

**Never use the main checkout's shared `./medaka_emitter` as a baseline** — it is a mutable artifact
another agent will rebuild under you.

Read the **`benchmark-emitter`** skill first. Every time.

---

## Know which problems are STRUCTURAL before you chase them

Two of the four ranked hot paths in `compiler/PERF-SCOPE.md` are **not fixable by tuning**, and an
agent who does not know that will burn a session:

- **GC allocation density** (`PERF-SCOPE.md:206`) — *"a structural property of the value
  representation"* (uniform heap boxing). `-O2` helps at the margin. The real payoff needs
  stack-allocation of short-lived values, or unboxed nullary constructors in hot paths.
- **Indirect closure calls are not inlineable** (`:242`) — *"STRUCTURAL, not -O2 fixable."* The real fix
  is compile-time specialization, or closure conversion with known targets.

`compiler/PERF-RESULTS.md` is the measured log **including every dead end** — read the dead ends. The
segment-emit attempt is recorded there as a failure, which means the doc's own "highest-value remaining
work" line above it is stale.

---

## ⚠️ Do NOT delegate hot monomorphic helpers to prelude Foldable methods

`elem` / `any` / `all` / `length` lose `||`/`&&` **short-circuiting** and become dict-passed
fold+closure. Doing this to `util.mdk`'s hottest helpers cost **+56% self-compile.** Keep hot inner-loop
helpers **monomorphic and short-circuiting**.

---

## Opt-level knobs preserve byte-identical IR

`EMITTER_OPT` (-O2), `ORACLE_OPT` (-O0), `CLI_OPT` (-O2), `WASM_ORACLE_OPT` (-O2 — **-O0 overflows the
deep-TCO fixtures**) and `GC_INITIAL_HEAP_SIZE` **all preserve byte-identical emitted IR**: the text IR
is produced *before* `clang` runs, so an opt level can never change it.
</content>
