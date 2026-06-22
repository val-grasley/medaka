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
6. ✅ UTF-8 string externs (stringToChars/charFromCode/stringFromChars) (`ae16d02`, →115; census →82)
7. ✅ nested-closure free-var capture — `freeVarsExpr` now descends compound value nodes (CTuple/CRecord/CList/…) so do-notation `pure (a,b)` captures earlier `<-` binds; parallel `maxIndexAt` fix (`508fdd3`, modules →13; census →35)
8. ✅ structural batch — Char/String match-switch heads, ctor/tuple lambda-params, **record-ctor registration** (`registerRecordCtors` in `lowerProgramEmit` — IN-GRAPH, fixpoint C3a/C3b YES + diff_selfhost_build 35/0), W5 dict-param capture (`freeVarsExpr` CMethod/CDict arms) (`945c685`, →119; census →11)
9. ✅ char-classification externs (charIs*/charTo*, 7) — pure-WAT ASCII (`a979385`, →126)
10. ✅ IO host surface (readFile/args/getEnv/fileExists/exit) — byte-channel host imports + JS virtual-FS shim (`6a90970`, →129). **🏁 ALL-MODULES EMITTER-GAP CENSUS = 0.**
11. 🟡 **Whole-program LINKAGE** (the self-host-proof layer — NEW frontier the per-binding census can't see). `check_main.mdk` (the real lex→parse→resolve→exhaust→typecheck front-end) emits a **6.77 MB / 241k-line WAT**, but `wasm-tools parse` finds **15 functions referenced-but-undefined** — all VALUE-only-used helpers (`map eqFieldCall fields`, `map (showArm …) variants`, `flatMap dataArity prog`): the emitter emits a closure-WRAPPER referencing them but not the underlying DEFINITION (the fn-emission loop only emits directly-called fns). DCE keeps them (native LLVM links check_main fine). Fix in progress (wasm-emitter fn-collection).
12. ⬜ runtime validation — once it assembles, run check_main under Node (host shim feeds runtime/core/source) and diff its schemes output vs the native `check_main` oracle. Expect a runtime-correctness layer (miscompiles producing valid-but-wrong wasm), like LLVM's B1–B7 bootstrap stages.

**🏁 MILESTONE (2026-06-22): the per-binding emitter-gap census is 0 — the WasmGC
emitter can LOWER every construct in the whole compiler graph (1428→0, 9 categories).**
The next layers toward a *running* self-hosted wasm compiler are (11) whole-program
linkage and (12) runtime/validate correctness — neither visible to the per-binding census.

**LAYER 11 — whole-program LINKAGE: ✅ CLOSED (`39fd801`).** `check_main.mdk` (the real
front-end) emits a **6.77 MB WAT** and `wasm-tools parse` now succeeds (0 referenced-but-undefined
funcs). Root was the SAME compound-value-node bug as the closure-capture fix, but in
`scanFnValueUses` (value-uses inside CTuple/CRecord/CRecordUpdate weren't scanned → no closure
wrapper emitted → ref-to-undefined). Gate: `test/wasm/assemble_check_main.sh`.

**LAYER 12 — `wasm-tools validate` (peeling class-by-class toward VALIDATE_OK):**
- ✅ func 20 — eta-saturation of PLAIN constrained fns (`elem = fold … `): `etaSaturateFnClause` +
  method-spine deficit (`6fcf914`).
- ✅ func 509 — arity>0 ctor used as a VALUE (`map PVar vars`): `emitCtorEtaClosure` (`6fcf914`).
- 🟡 func 1377 (`setNumlitFloatsGo`) — decision-tree match discriminating same-tag ctors by a STRING
  field (`TCon "Float"` vs `TCon "Int"`): dead `br $swd*` leaves a value at a block boundary
  ("values remaining on stack"). Decision-tree-emission class, in progress.
- Expect further classes after 1377 (the validate onion — each fix surfaces the next; like LLVM's
  B1–B7 bootstrap stages). After VALIDATE_OK: run check_main under Node (host shim feeds
  runtime/core/source) + diff schemes vs the native `check_main` oracle = the self-host-of-the-front-end demo.

**RUNTIME LAYERS (VALIDATE_OK reached — now run check_main under Node, peel miscompile layers):**
- ✅ layer-1 `debugStringLit`/`debugCharLit` real escape runtime; ✅ layer-2 value-global init topo-sort
  by eager deps; ✅ layer-3 list-`++` runtime-shape-dispatching `$mdk_append`.
- ✅ **layer-4 (`f9c9bc3`)** — UTF-8 `cp_count` bug in `$mdk_io_result_to_str` (`wasm_preamble.mdk`):
  rebuilt host readFile `$str` with `cp_count = byte_len`, so multibyte content (an em-dash in a
  `runtime.mdk` comment) padded the decoded `Array Char` with trailing `\0` → stray codepoint-0 fell
  through every lexer clause into `singleOp`'s panic → `unreachable`. Fixed by counting true UTF-8 lead
  bytes (`(b & 0xC0) != 0x80`), mirroring `$mdk_chars_to_str`. The self-hosted **lexer now lexes
  `runtime.mdk` (749 tokens) byte-identical to native.** Emitter-only → no fixpoint/seed.
- 🏁 **layer-5 CLOSED — the WasmGC TRMC arc (Stages 0–2, emitter-only)** — the self-hosted lexer now
  runs to COMPLETION under Node. Design `selfhost/WASMGC-TRMC-DESIGN.md` diagnosed the overflow as
  **shape (b′) dispatch-into-single-target TMC** (each per-token leaf does `RTok :: scan …`; cons-bearer
  ≠ recursion target — the single dispatcher `scan`). Ported the existing LLVM TMC (`TRMC-DESIGN.md`):
  Stage 0 (`8c69296`, seed re-mint `6bbcde8`) made cons/ctor recursive fields `mut` + lifted the
  backend-agnostic analysis to `backend/trmc_analysis.mdk` (the one in-graph change, fixpoint YES);
  Stage 1 (`8737d11`) WasmGC self-recursive destination-passing TMC (2M cons: overflow→`2000000`, 0
  loop calls; `diff_wasm` 131); Stage 2 (`2688edb`) the novel (b′) dispatch-TMC — `detectDispatchGroups`
  grows a `scan`-rooted 49-member group, each spine cons → cons-into-dest + `return_call $scan__disploop`
  (dest in 3 module globals); `diff_wasm` 132 + `DISP-ASSERT` (0 recursive `call $scan`). Verified:
  `check_main` lexes `runtime.mdk`+`core.mdk` fully under Node (flat `tokenize→parse→runCheck` trace).
- 🏁 **layer-6 CLOSED (`a332da7`, emitter-only)** — `stringToFloat` implemented via a HOST SEAM
  (`mdk_str_to_float` import + `$mdk_string_to_float` WAT runtime, the inverse of `floatToString`'s
  `mdk_float_fmt`; pushes `$str` bytes → JS `Number()` → boxes `Option Float`). Byte-identical to the
  native `strtod` oracle (`stringToFloat "3.14"` → `Some 3.14`; `diff_wasm_modules` 13→14). `check_main`
  now runs PAST `floatTok`.
- 🏁 **layer-7 CLOSED (`f96cd10`, emitter-only)** — `stripComments` (multi-clause patterned {cons-tail +
  plain-tail-drop + base}) overflowed because `wasmTrmcTry`'s `wTrmcAllPVarParams` gate rejected its
  list/ctor pattern params. Fix (`wasm_emit.mdk`): drop the gate (`trmcEligible` already vets); emit the
  clause-dispatch chain with the TMC ctx LIVE for patterned multi-clause builders; save+clear the TMC ctx
  before lifted-lambda bodies (a 2nd bug — leaked `$__tmc_first`/`$tmcloop` into invalid wasm). Gate
  `w_trmc_strip_clauses.mdk` + S1B-ASSERT; `diff_wasm` 133. `check_main` runs past the lexer.
- 🏁 **layer-8 CLOSED (`a76c8b3`, emitter-only)** — dispatched `List map` impl-method TMC. WasmGC
  self-TMC reached only top-level fn binds → generalized `emitWasmTrmcFn`→`emitWasmTrmcCore`
  (self-ref-agnostic) + `wTrmcImplTry` (`SelfByMethod`) tried by `emitImplGroup`. `mentionsSelfMethod`
  safety net verified (`map` TMC's, `ap` non-tail stays ordinary). Gate `w_dispatch_map_stack.mdk` +
  TMC-ASSERT, `diff_wasm_modules` 15. `check_main` now runs into the parser.
- 🏁 **layer-9 CLOSED (`bab91b2`, emitter-only)** — ref-mode comparison miscompile. `emitBinRef` lowered
  ALL comparisons as i31 compares → `String ==` (`$str` operands) `ref.cast`-trapped. Fix: runtime-shape
  `$mdk_value_eq`/`$mdk_value_cmp` (mirror LLVM `@mdk_value_eq`), routed when the program uses strings.
  Broad fix (all string comparisons). Gate `str_value_eq_cmp.mdk`, `diff_wasm` 134. `check_main` runs into
  resolve.
- 🏁 **layer-10 CLOSED (`117a30f`, emitter-only)** — refutable NESTED ctor in a fn-clause head
  (`Variant cname (ConNamed fs)`): `patTestBind` tested only the outer ctor, descended fields via
  `bindConFields` (bind-only, no test) → nested `ConNamed` cast unconditional, trapped on a `ConPos`
  sibling. Fix: descend fields with `patTestBind` via `patTestBindCon` (mirror PCons/PTuple/PList). Gate
  `w_clause_nested_ctor.mdk`, `diff_wasm` 135. check_main runs into typecheck.
- 🏁 **layer-11 CLOSED (`9095462`, emitter-only)** — synthetic-param/clause-binder name collision (BROAD):
  positional params named `$a0/$a1` clobbered by a clause-head var spelled `a1` → `unifyN` TFun cast trapped.
  Fix: `synthParams` emits reserved `$__wparg<i>` + `gname` escapes user `__wparg<digits>`. Gate
  `clause_param_name_collision.mdk`, `diff_wasm` 136. check_main runs into application inference.
- 🏁🏁 **layer-12 CLOSED (`faef8fa`, emitter-only) — MILESTONE: self-hosted FRONT-END runs on WasmGC
  byte-identical to native.** Root: `match <Bool>` lowering to a `CDecision` switch got a 0-slot `br_table`
  (both arms dropped) because `ctorsOfType "Bool"` returned `[]` (True/False are synthetic ctors). Fix: add
  `ctorsOfType "Bool" = ["False","True"]`. BROAD (every Bool decision-switch). Gate `match_bool_decision.mdk`,
  `diff_wasm` 137. **VERIFIED:** `check_main` (lex→parse→resolve→exhaust→typecheck) compiled to WasmGC runs to
  COMPLETION under Node, printing all 88 schemes byte-identical to the native compiled oracle (only diff = a
  trailing Unit-main `0`). This IS the layer-12 "diff schemes vs native = self-host-of-the-front-end demo" — MET.
- 🟡 **layer-13 (small/cosmetic)** — wasm value-main prints check_main's own `main`'s trailing `0`; port the
  native `mainIsUnit` auto-print suppression to `wasm_emit` (trivial, emitter-only).
- 🟡 **BEYOND:** `check_main` is the FRONT-END only. The whole-compiler-on-WasmGC goal needs the BACKEND
  (Core IR lower + the wasm/llvm emitter) compiled too — a further frontier (more miscompile layers; the
  emitter dwarfs the front-end). Also exercise check_main on more input shapes (records/ADTs/effects/multi-module)
  to surface remaining miscompiles.
- **LLVM (b′) port DEFERRED** (2026-06-22) — musttail-arity ISA wall + native doesn't need it; see
  `TRMC-DESIGN.md` §"Phase 3 … DEFERRED" + WIP `selfhost/bprime-llvm-wip.patch`.

**SEED: ✅ RE-MINTED (`11f2229`), `bootstrap_from_seed` PASS.** (Was stale from the step-8
in-graph `core_ir_lower.mdk` change; re-minted at the census-0 checkpoint.)

## Census progress: 1428 → 0 (per-binding emittability). Lazy-emitter rule: this emitter
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
