# compiler/AGENTS.md — how not to make the compiler slow

You are editing the Medaka compiler. **This file exists because the people who introduce
performance bugs here are not the people hunting them.** Almost every quadratic in this
tree was added by an agent doing perfectly reasonable *feature* work who never thought
about performance at all — and none of them were caught by a gate, because the gates were
looking the wrong way.

Root router: [`../AGENTS.md`](../AGENTS.md). Deep-dive when you are *hunting* a perf bug:
[`../.claude/workstreams/PERF.md`](../.claude/workstreams/PERF.md) and the `perf-hunt`
skill. **This file is the part you need when you are NOT thinking about performance.**

---

## 🔴 THE ONE RULE

> **A `List` is not a set, and it is not a map.**

**Every quadratic ever found in this compiler was the same shape: a `List` scanned,
`elem`/`contains`-checked, `lookup`-ed, or REBUILT once per element.** Thirteen of them.
Not twelve of one kind and one exotic — **thirteen of the same kind.**

If you are about to write any of these, stop:

```medaka
contains x xs              -- inside anything that runs per-element
lookupAssoc k pairs        -- inside anything that runs per-element
xs ++ [x]                  -- inside a fold. This is O(n²) BY ITSELF: `++` is O(left).
filter (\x -> not (contains x seen)) xs
```

**Use the set/map instead.** `compiler/support/ordmap.mdk` already wraps stdlib `Map`:
`omEmpty`, `omInsert`, `omHasKey`, `omLookup`, `omDelete`, `omFromNames`, `omKeys`.
Building a membership set is one line:

```medaka
let seen = omFromNames names omEmpty      -- then omHasKey n seen, O(log n)
```

Precedents to copy, both in this tree: `55d20ff9` (resolve's `contigGo`) and **#78 P-1**
(`resolve`'s `Env` name sets — the front end got **2× faster** from this one change).

### The exception that is NOT an exception
⚠️ **Do NOT "fix" a hot monomorphic helper by delegating it to a prelude `Foldable` method**
(`elem`/`any`/`all`/`length`). They lose `||`/`&&` **short-circuiting** and become
dict-passed fold+closure. Doing this to `support/util.mdk`'s hottest helpers cost
**+56% self-compile.** Keep hot inner-loop helpers **monomorphic and short-circuiting**.

---

## 🔴 THE SECOND RULE — the one that actually bit us

> **Not every quadratic allocates. The gate only sees the ones that do.**

`test/diff_compiler_perf_scaling.sh` grades **allocation** — deterministic, noise-free, and
the right primary metric. But **a `contains` over a `List` allocates NOTHING.** It is a pure
traversal. So an O(n²)-in-**time** / O(n)-in-**allocation** defect is **invisible to it.**

This is not theoretical. It hid **two** real bugs, one of them for months:

| bug | time ratio per doubling | allocation ratio |
|---|---|---|
| #78 — `resolve` O(refs × decls) | 2.63×, **3.56×** → quadratic | 2.09×, 2.11× → *"ok"* |
| #115 — `typecheck` union-find | 3.17×, 4.15×, **6.69×** → *worse than* quadratic | 1.52×, 1.72×, **1.87× → SUBLINEAR** |

**#115's ledger row said the bug was FIXED — because the *allocation* half had been.** The
time-side blow-up survived, invisible, under a green gate. A 4000-arm `match` took **6
seconds** to typecheck. Fixing it was **58×**.

The gate now grades **TIME per stage** as well (#110/#116), so it would catch these today.
**But the lesson generalises past this one gate:** ask of any check you rely on — *what class
of defect can my metric physically not see?*

### ⚠️ And it is not always a List
**#115 was a union-find `find` with no path compression.** Unifying one large declaration
built an N-long `Link` chain that every later `normalize` walked. Stubbing out the list scans
made it 3.6× faster and **left the ratio at 6.23× — still superquadratic.** The lists were an
*amplifier*; the chain was the bug.

**How it was named — copy this technique.** `perf record --call-graph dwarf,16384`, then a
**stack-depth histogram** of the hot symbol:
```
57.08%  mdk_types_typecheck__rootIdOf     <- flat top
 2.52%  GC_malloc_kind                    <- allocation is NOTHING here
...
2315 samples at 127 frames deep           <- perf's max-stack limit. The chains are DEEPER
                                             than perf can dump.
```
**`rootIdOf` was not hot from call COUNT — each call recursed hundreds of frames deep.**
When a symbol dominates, **check its stack DEPTH, not just its count.**

---

## Before you land a change to a hot file

The three files where a mistake costs the most, because everything runs through them:
**`frontend/resolve.mdk`**, **`types/typecheck.mdk`**, **`backend/llvm_emit.mdk`**.

```sh
# 1. Does it still scale? (~2.0x per doubling = linear; ~4.0x = quadratic)
sh test/diff_compiler_perf_scaling.sh

# 2. Where did the time actually go? Per stage, TIME and ALLOCATION.
FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one profile_main
GC_INITIAL_HEAP_SIZE=2147483648 MEDAKA_PERF=1 \
  test/bin/profile_main stdlib/runtime.mdk stdlib/core.mdk <your fixture>
```

### ⚠️ THREE MEASUREMENT TRAPS — each of these produced a confidently WRONG answer

1. **PIN THE GC HEAP.** `GC_INITIAL_HEAP_SIZE=2147483648` on **every** timing run. A Boehm
   heap resize inside the measured range reads **3.25× on a perfectly CORRECT compiler** —
   and then collapses to 2.07× one doubling later. A real quadratic *holds* near 4.0; a step
   does not. **An unpinned timing measurement is a false-red generator.** (The knob cannot
   change emitted IR, so it is always safe.)
2. **MIN-OF-K, never a mean.** Noise is one-sided — a stall only makes a run *slower*, never
   spuriously faster — so the **minimum** converges on the true cost from above.
3. **Grade PER-STAGE, never a sum.** Dilution can only push a ratio *down* toward 1.0, so a
   summed ratio above 2.0 means something in it is genuinely superlinear. Summing four stages
   gave an 8% margin between green and red; per-stage gives **22%**, costs nothing extra, and
   *names which stage regressed*.

⚠️ **`whenL False (expensiveCall …)` is NOT a stub.** Medaka is **strict** — the argument
still evaluates. This produced a false *"hypothesis disproved"* on a **correct** hypothesis,
and then did it again a week later to a different agent. **To stub something out, remove the
call.**

---

## Where the time actually goes (measured 2026-07-14 — do not re-derive from intuition)

**These are two DIFFERENT bottlenecks. Conflating them wastes a session.**

### `medaka check` (the LSP, the edit loop) is **GC-BOUND**
`perf` on a real `check` of `eval.mdk`: **`libgc` 62%**, our own code 27%. No `mdk_` symbol
exceeds 0.8% — the profile is *flat*, which is what "no algorithmic hot spot left" looks like.
⛔ **The GC knobs are a measured dead end**: `GC_INITIAL_HEAP_SIZE=1G` cuts collections
**124 → 5** and buys **1.02×**. **So collection is not the cost — ALLOCATION is.** See #124.

### `medaka build` (and therefore CI) is **CLANG-BOUND**
CI's critical path is `diff_compiler_engines` = **346 small fixtures × (`medaka build` + clang)**.
A **9-line** program used to emit **32,896 lines of IR — 271 of its 272 functions were prelude.**

⛔ **`MEDAKA_CLANG_OPT=-O0` is UNSOUND** (the knob exists; its comment even says `-O2` "buys
little"). It cuts the engines gate 40% and **regresses `wasm/clos_reftco_indirect`** — clang's
tail-call elimination for **indirect** calls only runs at `-O1`+. **The deep-TCO trap bites
LLVM, not just wasm.** `-O1` saves 10%. Both dead. Verified, not assumed.

**⇒ Making the front end faster barely moves CI. Making clang faster does nothing for the LSP.**
Know which one you are optimising.

---

## The emitter has its own rules

⚠️ **Read the `benchmark-emitter` skill before you MEASURE any change to `backend/*`.**

A binary's **behavior** comes from its **source**; its **speed** comes from **the emitter that
compiled it**. One rebuild after an emitter change gives you new behavior in **old machine
code** — build a "before" and "after" that way and **the binaries are crossed**. An agent
measured its own **2.2× win as a 2.5× SLOWDOWN** and nearly abandoned it.

- **`FORCE_EMITTER_REBUILD=1 make medaka`** for any emitter change. `make medaka`'s
  `find -newer` short-circuit can otherwise leave `./medaka_emitter` NOT carrying your change,
  and `medaka build` shells out to it. You will chase a ghost.
- **The decisive gate is `test/selfcompile_fixpoint.sh`** (C3a/C3b). C3b — the emitter
  reproducing its own IR byte-for-byte — is what proves determinism. A C3a "lagging seed"
  **warning** is expected on a codegen change and is **not** a break.
- **`test/diff_compiler_engines.sh` is the silent-miscompile net** (346 fixtures × 3 engines).
  It is what caught `-O0`. **A changed `known (ledgered)` count is a behavior change and must
  be EXPLAINED, not waved through.**
- **Typeclass dispatch is OUTLINED, not inlined at the site.** An `RDict` site emits a *call*
  to `@mdk_disp_<method>_<nMeth>_<nArgs>`. **Debugging a dispatch miscompile? The arm you want
  is in the dispatcher, not at the call site.** `test/diff_compiler_dispatch_shape.sh` pins
  this — and pins that prelude bodies stay **program-independent**, which is the precondition
  for `prelude.o`.

---

## If you add a gate

**Ask "where is this skipped?" BEFORE you write it.**

- **A gate matching `test/diff_compiler_*.sh` but no shard pattern in `.github/workflows/ci.yml`
  SILENTLY NEVER RUNS.** Green forever, checking nothing. `diff_compiler_ci_shard_coverage.sh`
  catches it — and it has caught us. **Enrol your gate in a shard, and put it where there is
  ROOM** (shards are scheduled by **cost**, not theme; `gates (engines)` at ~5.8 min is the
  critical path — do not add to it).
- **Print `checked N`. `N == 0` MUST be a FAILURE.** A gate that can no-op, will. One of ours
  reported **24 real failures as "not run"**, because the break made every build fail, so
  nothing reached the comparison, so a zero-comparison guard fired first and it exited **2
  (SKIP)**.
- **HAVE YOU SEEN IT FAIL?** Break the thing on purpose and watch the gate name the
  `file:line`. **A gate never observed red is indistinguishable from one that cannot go red.**

---

## Bookkeeping

Open perf work: `gh issue list --label "ws:perf" --state open`.
Measured log **including every dead end** (read the dead ends): `compiler/PERF-RESULTS.md`.
Ranked hot paths, and which ones are **structural** and not fixable by tuning:
`compiler/PERF-SCOPE.md`.
