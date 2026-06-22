# WASM-SELFHOST-ROADMAP.md — driving the WasmGC backend to compile the compiler

> **Goal:** run the Medaka compiler *itself*, compiled to WasmGC, in a browser — a
> frontend-only playground with **no server-side compilation**. This is the
> `WASMGC-DESIGN.md` §1 "far horizon" made concrete. The compute+print MVP (W1–W9b +
> W8b) is done; this doc tracks the gap-closing toward self-host.
>
> **Companion docs:** `WASMGC-DESIGN.md` (backend design + slices), `WASM-SELFHOST-GAPS.md`
> (the raw gap census), `PLAYGROUND-DESIGN.md` (the product surface).

## How the census works (the measurement loop)

`selfhost/entries/wasm_emit_gaps_main.mdk` runs the WasmGC emitter in **gap-record
mode** (`enableGapRecordW`) over the whole compiler source graph
(`all_modules_entry.mdk` + `selfhost` root), recording every node/extern it can't
lower instead of panicking. Re-run after each gap-close to measure progress:

```sh
make medaka                                  # if not built
export MEDAKA_EMITTER="$PWD/medaka_emitter"
bash test/wasm/build_wasm_oracle.sh
./medaka build selfhost/entries/wasm_emit_gaps_main.mdk -o test/bin/wasm_emit_gaps_main
./test/bin/wasm_emit_gaps_main stdlib/runtime.mdk stdlib/core.mdk \
  selfhost/entries/all_modules_entry.mdk selfhost 2>&1 | sort | uniq -c | sort -rn
```

The WasmGC emitter is **OUTSIDE the self-host compiler graph** (only the gate/census
entries import it) → emitter changes need **NO fixpoint and NO seed re-mint**; the
decisive checks are the output-diff gates (`test/wasm/diff_wasm{,_typed,_modules}.sh`)
plus the shrinking census.

## Gap categories (baseline census 2026-06-22 — 1428 occurrences, 9 categories)

| Category | Baseline | Status | Notes |
|---|---:|---|---|
| `panic` extern | 112 | ✅ DONE | → `unreachable` trap. |
| Array intrinsics | 86 | ✅ DONE | `arrayGetUnsafe`/`Length`/`FromList`/`MakeWith`/`Make`/`Copy`/`SetUnsafe` over `$arr`. |
| Ref (`set_ref`/`.value`/`Ref`) | ~636 | ✅ DONE | `$refbox` 1-field mutable struct; `Ref x`→`struct.new`, `set_ref`→`struct.set 0`, `.value`→`struct.get 0`. |
| `__fallthrough__` | 261 | ✅ DONE | multi-clause / guard-chain fall-through. Each clause body wraps in a `(block $cl_<name>_<i>)`; `labelFallthrough` rewrites `__fallthrough__` → label-carrying sentinel `__ft__<clLabel>` lowered to `br <clLabel>` (a PURE function of the var name — the lazily-assembled emitter can't thread a mutable "current label" ref reliably, since strings are forced at final assembly long after any `set_ref`). Single-clause guarded bodies divert to the chain path (block + trailing `unreachable`). A bare (unrewritten) `__fallthrough__` → `unreachable` trap (typechecker-proven-exhaustive context). Census 261 → 0, no new gaps. |
| string-literal clause heads (`f "kw" =`) | 111 | ⬜ | lower to string-eq if-chain (MEDIUM codegen). |
| string/char externs (subset) | 51 | ⬜ | extend `emitStrExternRef`. |
| `CFieldAccess on unknown field` | 283 | 🟡 | mostly `.value` (Ref read) — closed by the Ref work; residual = other records. |
| block-stmt in tail position | 35 | ⬜ | tail-position block lowering. |
| IO externs (`readFile`/`args`/`getEnv`/`exit`) | 4 | ⬜ | the **host-surface workstream** (see below). |
| misc (unknown ctor 8, non-Int switch heads 6, dict-param 4, PVar-only 3) | ~21 | ⬜ | small structural arms. |

Plus ~111 "genuine in-body free-var losses" inside the 978 unbound-variable bucket —
investigate after the big categories close (some are artifacts of the above).

## Sequence (all on `selfhost/backend/wasm_emit.mdk` → strictly sequential)

1. ✅ panic + array externs (`63cab37`, diff_wasm 85→93)
2. ✅ Ref support (`9566ae2`, →96; census ~636→0)
3. ✅ `__fallthrough__` (`0d30279`, →99; census 261→0). Lazy-emitter pivot: label encoded in the Core-IR node (`__ft__<lbl>` sentinel), not a mutable ref.
4. 🟡 charCode + string-literal clause heads (PLit-LString) — next batch
5. ⬜ scope-threading unbound vars (evalBinop `env`, derive params — CLetGroup/multi-clause free-var capture)
6. ⬜ block-stmt-in-tail (refutable let-bind) + misc structural arms
7. ⬜ IO host surface (task #3 — see below)
8. ⬜ assemble + run the compiler-on-wasm on a trivial input (the self-host proof)

**Census progress:** 1428 → 334 (panic, arrays, Ref, fallthrough closed). Remaining
top: PLit-LString 111, scope-threading unbound ~54, block-tail 35, string/char externs
~51 (subset), IO externs 4, misc ~21.

## IO host surface (scoped 2026-06-22 — task #3)

For a **browser self-host**, the compiler-as-wasm reads source in-memory and writes
WAT to stdout. Essential externs: `readFile`, `args`, `getEnv` (for `MEDAKA_ROOT`),
`exit` (+ output `putStr`/`ePutStr` already work). **Avoidable** (stub/omit):
`writeFile`, `runCommand` (no subprocess/FS in browser).

**String ABI across the host boundary:** GC refs (`(ref $str)`) cannot cross the
import boundary — use the existing **length + byte-at-a-time** channel (the
`mdk_float_fmt` / `mdk_float_fmt_byte` pattern in `test/wasm/run.js`). So `readFile`
becomes host imports: guest passes the path bytewise; host returns `is_ok` + result
length + byte reader; guest rebuilds `Result String String`. `args`/`getEnv`
likewise. **Decision (user, 2026-06-22):** in-memory virtual-FS shim for the
playground now; real WASI file IO later for a CLI cross-check — build the host seam
generically so both back the same imports.

## Open decision (deferred — revisit after the emitter gaps close)

**In-browser WAT assembly.** The compiler-on-wasm emits WAT *text*; the browser needs
to assemble it to bytes. Options: (a) emit WAT + a JS/wasm wat-assembler
(wasm-tools-compiled-to-wasm, or a JS lib); (b) add a WAT→binary encoder in Medaka
(direct binary emit — larger, fully self-contained). **User chose "defer — census
first"**; decide once the emitter can actually compile the compiler.
