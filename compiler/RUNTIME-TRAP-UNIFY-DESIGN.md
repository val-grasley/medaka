# Runtime-trap-format unification — design

**Status:** OPEN — verified live: `stdlib/array.mdk:268` still has a bare, uncoded
`panic "Array.set: index out of bounds"`, matching this doc's reproduction matrix row
for `Array.set`/`MutArray.set` OOB ("wrong code, stdlib loc"). Staged-and-ready open work
(reproduction matrix, target format, touchpoints, staging plan already written); resolves
`compiler/RUNTIME-DESIGN.md`'s explicitly-deferred "panic unwind model" item.

Status: DESIGN (2026-07-07, read-only scoping over `90d775fd`, every row reproduced
on the built binary incl. wasm via Node 24). Playground-filed deferred item. The four
backends trap differently on the same runtime error.

## 1. Reproduction matrix (what the user SEES)
All exit 1.

| Trap | interp (`run`) | native binary | wasm (node) | playground |
|---|---|---|---|---|
| div-zero | `f:L:C: runtime error [E-DIV-ZERO]: division by zero` | same, **no loc** | `divide by zero` (**engine trap, no code/msg**) | `program panicked` |
| mod-zero | `f:L:C: … [E-MOD-ZERO]…` | same, no loc | `remainder by zero` (engine) | `program panicked` |
| non-exhaustive | `f:L:C: … [E-NONEXHAUSTIVE-MATCH]…` | same, no loc | `unreachable` | `program panicked` |
| array/list OOB `.[i]` | `f:L:C: … [E-INDEX-OOB]: index N…` | no loc, **no index N** | array `unreachable`; **list `.[i]` = hard wasm emit gap** | `program panicked` |
| `Array.set`/`MutArray.set` OOB | `stdlib/array.mdk:L: [E-PANIC]: Array.set…` (**wrong code, stdlib loc**) | **bare, no code/loc** | `unreachable` | `program panicked` |
| user `panic "msg"` | `f:L:C: [E-PANIC]: msg` | **bare msg, no code/loc** | `unreachable` (**msg dropped, partial stdout LOST**) | `program panicked` |
| no `main` | `program has no 'main' binding` (bare) | `emitter failed … no main` (bare) | build-time | build-time |

**Reads:** interp/native are already ~80% consistent for the 4 coded traps — differ
only in **loc** (interp has it) + native OOB dropping `index N`. **Wasm is the real
gap** (engine text not Medaka's; `unreachable` collapses nonexhaust/OOB/panic). The
**playground erases everything** (`worker.js:99` `/unreachable|trap|RuntimeError/i` →
one generic `program panicked` for all five). Two under-coded non-wasm paths:
stdlib set-OOB (bare `panic`) and native user-`panic` (raw string, no `[E-PANIC]`).

## 2. Target format
Per trap, stderr, exit 1: `[<file>:<L>:<C>: ]runtime error [E-CODE]: <message>`.
Codes reuse the landed set (`E-DIV-ZERO`/`E-MOD-ZERO`/`E-NONEXHAUSTIVE-MATCH`/
`E-INDEX-OOB`/`E-PANIC`). Loc prefix present when available (interp always; native/wasm
only if the Core-IR-loc project lands — see §5). Message+code consistent even without
loc. Bad-main → the diagnostic channel as a coded driver diagnostic (`E-NO-MAIN`).

## 3. Touchpoints (grouped)
- **(1) eval.mdk** (IN seed graph): `:693` `panic "non-exhaustive match"` →
  `runtimePanic` (infra `:1664`, `currentEvalLoc` `:1649`); `:2214/:2248/:2458`
  no-main panics → diagnostic channel (`E-NO-MAIN`), share one builder; `:2462`
  `main:Async` panic → coded+located.
- **(2) stdlib/array.mdk `:268`, blit `:296/:298`; stdlib/mut_array.mdk `:144`**
  (NOT in emitter graph): bare `panic` → coded OOB. Constraint: stdlib has no
  `runtimePanic`, only the `panic` extern → needs a new coded-OOB seam (fork 4).
- **(3) runtime/medaka_rt.c** (NOT in seed graph, C): `mdk_oob:192`, `mdk_div_zero:345`,
  `mdk_mod_zero:349`, `mdk_nonexhaustive_match:360` already coded (loc blocked, §5;
  `mdk_oob` could take the index arg → `index N`); `mdk_panic:339` prints raw → wrap
  with `runtime error [E-PANIC]:`.
- **(4) typecheck.mdk `:969-970`/`:997`** (IN seed graph): dedup the T-EFFECT-PARAM
  "must end in '*'…" message into one builder.
- **(5) wasm_emit.mdk** (NOT in LLVM seed graph): `panic` lowering `:941-944/:1252` →
  `unreachable` (msg dropped); division `:4196-4197` raw `i64.div_s/rem_s` **no
  guard** (native peer `llvm_emit.mdk:2626` `emitIntDivZeroChecked`); OOB/nonexhaust
  `unreachable` `:3957-3969/:2650/:3001`. To carry a message: a wasm trap helper
  streaming bytes via the existing `mdk_write_err_byte` host import before trapping.
  Consumers: `playground/worker.js:94-104`, `test/wasm/run.js:122`.

## 4. Seed re-mint (verified by import trace)
- eval.mdk (1) → IN seed graph (imported by the driver) → **re-mint owed**.
- typecheck.mdk (4) → IN seed graph → **re-mint owed**.
- stdlib array/mut_array (2) → NOT in emitter graph (compiler uses low-level externs)
  → no re-mint (but the seam's native lowering may touch runtime_rt.c/emitter).
- runtime_rt.c (3) → C, not in seed → no re-mint.
- wasm_emit.mdk (5) → not in LLVM seed → no LLVM re-mint.
Batch B1+B3 (the two in-graph edits) into ONE re-mint.

## 5. Core-IR-loc blocker
Native/wasm traps carry no loc because Core IR drops source spans (genuinely blocked
on threading `Loc` through Core IR — a large separate project). **Message+code
consistency = ~90% of the beginner win and needs NONE of it.** Recommended scope
EXCLUDES Core-IR locs; the residual gap is only "interp has file:L:C:, native/wasm
don't" (precision degradation, not identity inconsistency). Partial loc win without the
project: `mdk_oob` printing `index N`.

## 6. Staging (ascending risk)
| Bite | Scope | Model | Re-mint |
|---|---|---|---|
| B1 | typecheck.mdk (4) dedup message builder | Sonnet | yes (in-graph, mechanical) |
| B2 | medaka_rt.c (3): `mdk_panic` → `[E-PANIC]` prefix; `mdk_oob(index)` → `index N` | Sonnet | no |
| B3 | eval.mdk (1): route `:693`/`:2462` via `runtimePanic`; no-main → `E-NO-MAIN` | Opus | **yes — make seed** |
| B4 | stdlib array/mut_array (2): coded-OOB seam | Opus | no (stdlib) |
| B5 | wasm_emit.mdk (5): divisor guard + coded trap text via `mdk_write_err_byte` + surface in worker.js/run.js | Opus | no (wasm from source) |
Order B1→B2→B3→B4→B5; batch B1+B3 re-mint.

## 7. Design forks
1. **Wasm: coded message text vs stable code + generic text.** Full parity (B5) = a
   real emitter change (trap preamble streaming the coded message + `unreachable`, +
   teach `worker.js`). Cheaper: keep `unreachable`, map distinguishable engine signals
   to codes — feasible only for div/mod ("divide by zero"/"remainder by zero");
   `unreachable` is indistinguishable across nonexhaust/OOB/panic → generic
   `program panicked` is the floor without the emitter change. **In scope for 0.1.0?**
2. **Wasm divisor guard** — codegen change to a hot arith path; worth it vs engine
   trap + playground string-map?
3. **Wasm partial-stdout on trap** — `run.js:122` loses pre-trap stdout (native +
   playground preserve it); one-line flush for parity — in scope?
4. **Stdlib coded-OOB seam (B4):** new stdlib-visible primitive (`oobPanic : Int -> a`
   → `mdk_oob`) vs compiler special-casing the `"…out of bounds"` panic strings. The
   primitive is cleaner but adds an extern across all three backends.
5. **User-panic code identity:** unify native user `panic` to `[E-PANIC]` (B2) —
   confirm `E-PANIC` is the intended public code for user panics.
6. **`main : Async`** — the repro surfaced `Unknown effect: Async`, not the
   runAsync-missing panic (`eval.mdk:2462`). Confirm the trigger before coding.
7. **Exit codes** — already uniformly 1; confirm that's intended.

Critical files: `compiler/eval/eval.mdk`, `runtime/medaka_rt.c`,
`compiler/backend/wasm_emit.mdk`, `stdlib/array.mdk` + `stdlib/mut_array.mdk`,
`playground/worker.js` (peer `compiler/backend/llvm_emit.mdk:2626`).
