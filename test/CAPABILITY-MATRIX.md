# CAPABILITY-MATRIX.md — which engine implements which extern

Status: **active**, 2026-07-13.

## The bug this exists to catch

Medaka has three execution engines that each must independently implement
every `extern` primitive declared in `stdlib/runtime.mdk` (~132 of them):

- the tree-walking **interpreter** (`compiler/eval/eval.mdk`) — runs
  `medaka run` / `medaka test`
- the **LLVM backend** (`compiler/backend/llvm_emit.mdk`) — runs `medaka
  build`
- the **WasmGC backend** (`compiler/backend/wasm_emit.mdk`) — runs `medaka
  build --target wasm`

`eval.mdk` was originally written as a *value oracle* for differential
testing against the (now-deleted, 2026-06-26) OCaml reference compiler — it
only ever needed to compute `main`'s value, so effectful/IO externs
(`readFile`, `exit`, …) were legitimately out of scope. When OCaml was
removed, `eval.mdk` was silently promoted to be the production `medaka run`
engine and its contract was never re-litigated. The result: **37 externs
type-check GREEN and then panic at runtime** with `unbound identifier: X`
under `medaka run` — including a *pure* extern with no effect row at all
(`arraySortBy`). Nothing in `test/` or `scripts/` ever compared the three
engines' extern coverage against each other, so this drifted silently for
weeks.

`test/diff_compiler_capability_matrix.sh` + `test/CAPABILITY-EXCEPTIONS.txt`
are the fix: a gate that fails the moment an extern is unsupported by an
engine with no documented reason, *and* fails the moment a documented gap
gets silently fixed without updating the record (so the exceptions file
can't rot the other direction either).

## How to read it

Run `sh test/diff_compiler_capability_matrix.sh -v` for the full per-extern
table (`Y`/`N` per engine); plain (no `-v`) prints just the summary counts
and any failures.

Every `N` cell must be explained by a row in `test/CAPABILITY-EXCEPTIONS.txt`
(format documented in that file's header). Categories, briefly:

| Category | Meaning |
|---|---|
| `BUG` | Works in ≥1 other engine; this engine's gap is a real regression to fix. |
| `DEAD` | Declared but not called by current stdlib code (superseded by a rewrite); still directly reachable by a user program. |
| `TODO` | Unimplemented everywhere — a forward-declared primitive with no caller yet, not an asymmetric gap. |
| `PERMANENT` | Will never close for a documented structural reason (e.g. WasmGC has no raw-socket equivalent). |
| `TRAP-STUB` | Bound in source, but to an `unreachable`/abort — better than a silent wrong value, still not real. |
| `WASM-GAP` | Unported to WasmGC; no structural blocker, just not done. |
| `FROZEN-CONSTANT` | Bound to a **fabricated/no-op value** — worse than missing, because it's silent instead of a loud panic. Tracked even though it counts as "implemented" for pass/fail purposes. |

## How the gate decides "implemented" (and its limits)

This is **pure text analysis over checked-in `.mdk` source — no compiler
build, no `./medaka` invocation**. It parses:

- **Interpreter**: every literal `("name", ...)` key inside the
  `externBindings = [ ... ]` list in `eval.mdk`, plus the one variable-keyed
  entry (`fallthroughName` → `"__fallthrough__"`) added by hand.
- **LLVM**: the ~20 `is*Extern`/`isMathUnary`/`isMathBinary` family
  predicates that `isAnyExtern` ORs together (each is a `contains name [
  "a", "b", ... ]` literal list, extracted mechanically), plus a handful of
  names that bypass that ladder entirely — `pi`/`e`/`intMinBound`/
  `intMaxBound`/`charMinBound`/`charMaxBound` (constant-inlined in
  `emitVar`), `Ref`/`setRef` (dispatched by exact name ahead of the ladder),
  `arrayMakeWith` (dispatched by exact name inside the ladder),
  `__fallthrough__` (a desugar-generated sentinel, its own code path).
- **Wasm**: `isStrExternW`/`isLeafExternW`/`isArrayExternW` (real
  implementations), `isNetExternW` (an *explicit rejection* — tracked as
  `PERMANENT`, not "implemented"), the same constant-inline/`Ref`/`setRef`/
  `__fallthrough__` bypass list as LLVM, and `intMinBound`/`intMaxBound`
  which the parser deliberately does NOT count as implemented even though
  the name appears in source — they lower to `unreachable` (see
  `TRAP-STUB`).

**This is a heuristic**, documented in detail in the gate script's own
header comment (`test/diff_compiler_capability_matrix.sh`). It will drift if
an engine's dispatch structure is refactored (e.g. a new extern family added
under a differently-named predicate, or a name moved from a predicate list
into a hand-dispatched special case). When that happens the gate does the
*safe* thing: it fails loudly (either "silent omission" if the new form
isn't recognized, or a hygiene error) rather than silently reporting stale
numbers — update the gate's family list or the exceptions file, don't just
turn it off.

## How to add a new primitive without breaking an engine

This is the missing doc the codebase didn't have. Follow
`.claude/skills/add-primitive` (or the manual version below) and this gate
will tell you exactly what's left:

1. **Declare it** in `stdlib/runtime.mdk`: `extern myThing : T1 -> <Effect> T2`.
   Run the gate now — it should FAIL with "SILENT OMISSION" for all three
   engines (this is expected: you haven't implemented it anywhere yet).
   Either implement it immediately (steps 2-4) or add three
   `CAPABILITY-EXCEPTIONS.txt` rows with category `TODO` (unimplemented
   everywhere is fine as a checked-in state; unimplemented in *one* engine
   while it works in another is not).
2. **Interpreter**: implement it in `compiler/eval/eval.mdk` — add a `pMyThing`
   helper function and a `("myThing", prim1 pMyThing)`-shaped entry to the
   `externBindings` list.
3. **LLVM**: implement it in `compiler/backend/llvm_emit.mdk` — add it to the
   most fitting existing `is*Extern` family's literal list (or start a new
   family + fold it into `isAnyExtern`'s OR-chain and `emitExternApplied`'s
   dispatch ladder) and write the `emit*Extern` arm that lowers it to LLVM IR
   / a runtime call into `runtime/medaka_rt.c`.
4. **WasmGC**: implement it in `compiler/backend/wasm_emit.mdk` similarly —
   fold it into `isStrExternW`/`isLeafExternW`/`isArrayExternW` (or a new
   family wired into `emitAppRef`'s dispatch ladder) and write the emitter
   arm, plus any host-import seam it needs.
5. **Re-run the gate.** Once all three engines implement it, remove the
   `TODO` exceptions rows you added in step 1 — the gate will FAIL with
   "ACCIDENTAL FIX" (this arc's term for "you fixed it, the paperwork didn't
   catch up") until you do. Green means the catalog, the three engines' own
   dispatch source, and the checked-in exceptions file all agree.

If you deliberately DON'T want to support a primitive on one engine (e.g. it
has no meaning there, like `net*` on wasm), add a `CAPABILITY-EXCEPTIONS.txt`
row with category `PERMANENT` and a real reason instead of skipping this
gate — see that file's header for the exact format, and
`compiler/backend/wasm_emit.mdk`'s `isNetExternW` rejection message for the
model of what a good reason looks like.

## Wired into the gate suite

`test/diff_compiler_capability_matrix.sh` is named to match `run_gates.sh`'s
default `diff_compiler_*` glob, so it runs automatically as part of `sh
test/run_gates.sh` / `make test` — no separate wiring needed. It needs no
toolchain (no `./medaka`, no C compiler, no oracle), so it should never
legitimately SKIP; treat any exit code other than 0/1 from it as a bug in the
gate itself.
