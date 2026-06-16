# ASYNC-DESIGN.md

Design for Medaka's `Async` monad — a basic, **swappable** cooperative-concurrency
layer. Design-only: NO implementation until a stage is green-lit. Companion to
`CAPABILITY-EFFECTS-V2-DESIGN.md` (the effect-row work this deliberately stays *out* of).

Status: **DESIGN LOCKED** (2026-06-16, collaborative). Decisions in §0 are authoritative.

---

## 0. Locked decisions

| # | Decision | Rationale |
|---|---|---|
| **D1** | `Async a` is a **value-level monad** (Promise/Future shape). Composition via the existing `do` notation (EDo → `andThen`/`pure`). | The DX target; reuses the monad machinery already in the language. |
| **D2** | **No `<Async>` effect.** Async-ness is carried by the *type* (`Async a`), exactly as `Result e a` carries error-ness — not by a tracked row label. | Direct parallel to the `Throws`-rejection (`CAPABILITY-EFFECTS-V2-DESIGN.md` §5 / [[no-catchable-panics-isolation]]). The type is the tracking. |
| **D3** | v1 commits to the **cooperative-concurrency *contract*** (tasks may interleave at await/yield boundaries; single-thread; **no parallelism**), implemented as a **degenerate sequential scheduler**. | The Boehm analogy done right: swapping the scheduler later changes *performance + parallelism*, never observable correctness. Locking only the API (eager v1) would leak sequential semantics and force a future rewrite. |
| **D4** | Errors ride **`Result`** inside `Async` (`Async (Result e a)`). **No rejected-promise / throw channel.** `panic` inside a task still aborts the whole process (uncatchable). | Honors Result-canonical + [[no-catchable-panics-isolation]]. |
| **D5** | **`main : Async Unit`** is a first-class entrypoint alongside `main : Unit`. The `run` driver dispatches on `main`'s type and drives the scheduler at the boundary. | Nicer DX than a mandatory explicit `runAsync` wrapper. |
| **D6** | The whole layer lives in **`stdlib/async.mdk`** as **pure Medaka** — no `eval.ml` / `runtime/medaka_rt.c` changes for v1. The scheduler is a pure interpreter of a trampolined `Async a` description. | Maximum swappability + zero backend coupling; the v1 runtime is *replaceable stdlib code*, not baked-in primitives. |
| **D7** | Remove the now-vestigial reserved builtin effect labels **`Async`** and **`Time`** from `builtInEffects` (both backends) when this lands. `Time`'s capability is `Clock` (minted in capability-effects Stage 3); `Async` is gone by D2. | Keep the effect vocabulary honest — it shouldn't advertise labels nothing uses. |
| **D8** | v1 ships **structured concurrency first**: `concurrent : List (Async a) -> Async (List a)`. A `spawn`/`Task a` handle API is deferred (avoids dangling-handle lifecycle in v1). | Smaller surface; the common case (fan-out/join) without handle bookkeeping. |

Non-goals (v1): real parallelism / OS threads, non-blocking syscalls (epoll/kqueue),
cancellation, timeouts, deadline propagation, `spawn`/`Task` handles, async iterators/streams,
select/race. The API must not *preclude* these (§5), but none are built in v1.

---

## 1. Why async, why monadic, why now

Async is the one major control-flow feature the language lacks. The user goal: a **basic
version now, swappable later** for something robust/performant — modeled on how Boehm GC is a
stable interface behind a replaceable implementation. The DX must be right from the start
because it's what downstream code is written against.

Monadic (Promise/Future-shaped) is the chosen model: it composes through the `do` notation that
already exists (`do`-blocks desugar to nested `andThen`/`pure`, [[medaka-io-not-a-monad]] —
note `do` is monadic-only; multi-statement IO is a bare block, *not* this), and it does not
require algebraic-effect handlers / resumptions (a permanent non-goal — see v1 effect design).

**Async vs effect (the resolved tension).** "Async effect/monad" conflates two separable things:
- the **`Async a` monad** — value-level deferred computation; the substance + DX. **KEPT.**
- the **`<Async>` row effect** — ambient capability label. **DROPPED (D2).**

The capabilities an async program actually exercises are still tracked, by the labels that
already exist: a fetch is `<Net>`, a timer/`sleep` is `<Clock>` (both from capability-effects
Stage 3). `<Async>` would only have marked "schedules concurrent work," which is structure, not
authority — and the `Async a` type already says that. So it earns no keep.

---

## 2. The `Async a` type + scheduler (v1)

### 2.1 Representation — trampolined description

To honor the **interleave-at-yield** contract (D3) without delimited continuations, encode
`Async a` as a steppable description: a computation is either finished or a thunk that produces
the next step.

```
data Async a
  = Done a
  | Suspend (Unit -> Async a)     -- a yield point; force to advance one step
```

- `pure x          = Done x`
- `map f m         = andThen m (x => pure (f x))`
- `andThen m k` chains: walk `m` to its next `Done`/`Suspend`; at `Done x` continue with `k x`;
  at `Suspend t` re-wrap as `Suspend (u => andThen (t u) k)` (preserves the yield boundary).

Each `andThen` boundary is a natural yield point — the granularity at which the scheduler can
switch tasks. (An explicit `yield : Async Unit = Suspend (_ => Done ())` lets a CPU-bound task
cooperate; optional in v1.)

This is a free-monad-ish / trampoline encoding. It is **pure Medaka** and **stack-safe** when
`runAsync` trampolines iteratively rather than recursing.

> **Validation gate before committing to this encoding:** typecheck the trampoline + the Monad
> instance *on the binary* (`medaka test stdlib/async.mdk`). Medaka's value restriction and
> recursive-binding handling can bite a recursive `andThen` / a `Unit -> Async a` thunk field —
> if `Async a` as written doesn't generalize or the instance won't resolve, fall back to a CPS
> encoding (`Async a = (a -> Result) -> Result`) which composes identically but trampolines
> differently. Decide empirically, not on paper.

### 2.2 The scheduler — `runAsync`

```
runAsync : Async a -> a          -- drive a single computation to its value
```

Trampoline: force `Suspend` thunks in a loop until `Done a`, return `a`. For a single chain this
is just sequential execution — the yield points are inert until there's more than one task.

### 2.3 Structured concurrency — `concurrent` (D8)

```
concurrent : List (Async a) -> Async (List a)
```

Contract: the N computations **may interleave** at their yield boundaries; results returned in
input order once all complete. v1 impl: a run-queue of the N trampolines; the scheduler advances
each by one `Suspend` round-robin (or, simplest-legal, drains them in order) until all are
`Done`, then collects. Either satisfies the contract — round-robin is preferred so that even v1
*observably* interleaves (catches order-dependent bugs early, before the real scheduler lands).

Because v1 I/O externs block (§4), an interleaving v1 gains no wall-clock overlap — but the
*semantics* are the production semantics. That is the entire point of D3.

---

## 3. Entry point — `main : Async Unit` (D5)

The `run` driver currently evaluates top-level bindings and checks `main` exists (it must be a
zero-arg value, [[project-medaka-eval-harness-gotchas]]). Extend:

- `main : Unit` (and the IO-shaped `main`) — unchanged, evaluated as today.
- `main : Async Unit` — the driver wraps it in `runAsync` and drives the scheduler.

Mechanically a small typecheck + driver change: inspect `main`'s inferred type; if it unifies
with `Async _`, route through `runAsync`. Both `medaka run` and the native `run` path. No new
syntax. (`runAsync` stays public for embedding async work inside a non-async `main` too.)

---

## 4. Honest runtime constraints (v1)

Both backends are single-threaded (the tree-walking interpreter; native LLVM + Boehm GC, one OS
thread). v1 async **I/O still calls the existing blocking externs** (`readFile`, `runCommand`,
… now narrowly-labeled by capability-effects Stage 3) from inside the sequential scheduler. So
v1 delivers: the monad, `do`-composition, structured fan-out, correct capability tracking via
the *I/O* effect labels — but **no actual I/O overlap**. Real overlap is the swap (§5).

`sleep : Float -> Async Unit` — the one scheduling primitive worth shipping; incurs `<Clock>`.
v1 impl can be a blocking `wallTimeSec` spin or a real sleep extern (decide at build time); the
*type* and the yield behavior are what matter for the contract.

---

## 5. The swap — what v1 must NOT preclude

The deferred "robust" layer replaces the **scheduler internals only**:
- **OS threads** (Boehm-aware) or an **event loop** over non-blocking syscalls (epoll/kqueue) for
  real I/O overlap + parallelism.
- **Non-blocking extern variants** the scheduler can poll instead of blocking on.
- **`spawn`/`Task a` handles**, **cancellation**, **timeouts**, **select/race**, **streams**.

These must be reachable without changing: the `Async a` type's public face, the `pure`/`map`/
`andThen` laws, the `do` DX, `concurrent`'s contract, or `main : Async Unit`. The trampoline
encoding (§2.1) is the seam: `Suspend` already models "this task can be paused and resumed,"
which is exactly the hook a real scheduler needs. A non-blocking extern becomes
`Suspend (_ => poll …)`; a thread pool drains the same queue. The *contract* written down in v1
(interleave-at-yield, errors-via-Result, no rejection channel) is what makes the swap behavior-
preserving.

---

## 6. Open questions (decide at stage time, not now)

1. **Encoding:** trampoline (§2.1) vs CPS — settle empirically against the typechecker (§2.1 gate).
2. **`sleep` impl:** real sleep extern vs `wallTimeSec` spin in v1 (perf irrelevant in v1; pick the
   simpler that yields correctly).
3. **Scheduler order in v1:** round-robin-by-`Suspend` (recommended — observable interleaving) vs
   drain-in-order (simplest). Round-robin surfaces order bugs before the real scheduler exists.
4. **Monad interface wiring:** confirm which interface `do` desugars against (the `andThen`/`pure`
   pair) and add the `Async` instance to it — verify `do` over `Async` lowers correctly on the
   binary.
5. **`spawn`/`Task`:** stays deferred (D8) unless a concrete need appears; if added, define the
   handle lifecycle (await-once? GC'd if never awaited?) up front.

---

## 7. Staging sketch (when green-lit)

A single language-level stage, fixpoint-gated like the capability-effects stages:

1. `stdlib/async.mdk`: `Async a` type, Monad/Mappable instances, `pure`/`map`/`andThen`/`await`/
   `runAsync`/`concurrent`/`yield`/`sleep`. Doctests + the §2.1 validation gate.
2. Driver: `main : Async Unit` dispatch in both `run` paths (OCaml + native).
3. Vocabulary cleanup (D7): drop `Async`/`Time` from `builtInEffects` (both backends).
4. Gates: fixpoint C3a/C3b; new `async` doctests; the full diff_selfhost battery byte-identical
   (async is additive — only `builtInEffects` removal + any golden printing those labels should
   move); `medaka test stdlib/async.mdk` green on both backends.

No backend (eval.ml / runtime.c) changes in this stage — that's the deferred robust-runtime swap.
