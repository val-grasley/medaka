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
4. ✅ charCode + string-literal clause heads (PLit-LString) (`d15d5bf`, →102; census 334→153, cascade cleared downstream unbound vars)
5. ✅ destructuring / refutable / assign let-binds — CSLet tuple/ctor/record destructure + CSLetElse + CSAssign (`38d45f8`, →109; tail-block 56→0, total →119)
6. 🟡 UTF-8 string externs (stringToChars/charFromCode/stringFromChars, 37) — in progress
7. ⬜ diffuse unbound vars (~50: where/let-rec/if-let/guard/closure-capture in parser/lexer/typecheck) — being scoped for batch-fix by construct
8. ⬜ small structural: unknown ctor (8), non-Int switch heads (5), PVar-only clause params (3), dict-param (4)
9. ⬜ IO host surface (task #3 — see below): readFile/args/getEnv/fileExists/exit
10. ⬜ assemble + run the compiler-on-wasm on a trivial input (the self-host proof)

6. ✅ UTF-8 string externs (stringToChars/charFromCode/stringFromChars) (`ae16d02`, →115; census →82)
7. ✅ nested-closure free-var capture — `freeVarsExpr` now descends compound value nodes (CTuple/CRecord/CList/…) so do-notation `pure (a,b)` captures earlier `<-` binds; parallel `maxIndexAt` fix (`508fdd3`, modules →13; census →35)
8. ✅ structural batch — Char/String match-switch heads, ctor/tuple lambda-params, **record-ctor registration** (`registerRecordCtors` in `lowerProgramEmit` — IN-GRAPH, fixpoint C3a/C3b YES + diff_selfhost_build 35/0), W5 dict-param capture (`freeVarsExpr` CMethod/CDict arms) (`945c685`, →119; census →11)
9. 🟡 char-classification externs (charIs*/charTo*, 7) — pure-WAT ASCII, in progress
10. ⬜ IO host surface (task #3): readFile/args/getEnv/fileExists/exit — emit host-import byte-channel + JS virtual-FS shim. LAST emitter-gap category.
11. ⬜ whole-compiler emit + `wasm-tools` assemble → run under Node with virtual-FS (the self-host proof). NOTE: census=0 means EMITTABLE, not yet runtime-correct — expect a runtime-validation layer (like LLVM's B1–B7).

**Census progress: 1428 → 11** (panic, arrays, Ref, fallthrough, string-clauses+charCode,
destructuring, UTF-8, closure-capture, structural-batch all closed — 99.2%). Remaining:
char externs 7 (in progress), IO externs 4. **SEED STATUS:** the structural batch touched
`core_ir_lower.mdk` (in-graph) → committed seed (`selfhost/seed/emitter.ll.gz`) is STALE;
fixpoint self-compiles fresh (C3a/C3b YES) so it's the decisive check. Re-mint the seed at
the next checkpoint (`bootstrap_from_seed` red is expected until then). Lazy-emitter rule: this emitter
forces instruction strings at final assembly, so binding/label state must thread as
data / locals / Core-IR-encoded sentinels — NOT mutable refs read at a different time
than set.

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
