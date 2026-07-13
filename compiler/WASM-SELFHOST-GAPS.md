# WasmGC self-host gap census

**Status:** IMPLEMENTED — see the doc's own accurate banner immediately below (gap
census is zero; generator `compiler/entries/wasm_emit_gaps_main.mdk` still exists,
theoretically re-runnable). Historical 1428-gap body kept for the roadmap record.

> **STATUS 2026-06-22 — EMITTER-GAP CENSUS IS ZERO.** The all-modules graph now emits
> with **0 recorded gaps** (was 4: `readFile` ×2 / `fileExists` ×2). The LAST gap
> category — the IO externs — is closed: **W12 added the IO host surface** (`readFile`,
> `fileExists`, `args`, `getEnv`, `exit`) as host-import-backed lowerings marshaling
> strings across the import boundary via the length+byte channel (the same protocol as
> the `floatToString` host seam), with the Node-side shim in `test/wasm/run.js` behind a
> swappable `vfs`/`argv` seam (in-memory virtual-FS for the browser playground later).
> `readFile`/`fileExists` are auto-diff-gated (`test/wasm/fixtures/w_readfile_ok.mdk`,
> `w_file_exists_{true,false}.mdk` — oracle = `medaka build`, byte-identical);
> `args`/`getEnv`/`exit` are implemented + hand-verified (valid wasm that runs; not in
> the auto-diff because argv/env differ between the native binary and run.js). diff_wasm
> 129/129, typed 6/6, modules 13/13. The historical 1428-gap census below predates the
> W7–W12 closures and is kept for the roadmap record only.

Enumeration of every Core-IR node / extern / pattern the **WasmGC emitter**
(`compiler/backend/wasm_emit.mdk`) cannot yet lower when pointed at the **whole
compiler source graph**. This mirrors how the LLVM backend reached self-hosting:
a gap-tolerant record mode (`emitProgramGaps`) emits *every* binding (fns +
impls + top-level values, no `main` required) and records each unsupported node
instead of panicking at the first one.

## How this was produced

```sh
export MEDAKA_EMITTER="$PWD/medaka_emitter"
bash test/wasm/build_wasm_oracle.sh                 # rebuild emitter bins
./medaka build compiler/entries/wasm_emit_gaps_main.mdk -o test/bin/wasm_emit_gaps_main
./test/bin/wasm_emit_gaps_main \
    stdlib/runtime.mdk stdlib/core.mdk \
    compiler/entries/all_modules_entry.mdk compiler > /tmp/wasm_census.txt
```

`all_modules_entry.mdk` imports one name from every compiler module, so
`loadProgram` pulls the whole graph. The census entry runs the real
`medaka build` front end (loader → elaborate → lower) **without DCE** (DCE roots
reachability from `main`, which a census input has none of, so it would prune
every plain top-level function), then `emitProgramGaps` emits all bindings in
record mode.

Each line is `<binding>\t<reason>`. The numbers below strip the per-binding
prefix and normalize quoted identifiers / `[in <fn>]` suffixes to aggregate by
category.

## Summary

- **Total gap occurrences:** 1428
- **Distinct normalized categories:** 9 (table below)
- **Sanity check:** `arrayGetUnsafe` (the lexer's array intrinsic) appears — 38×. ✓

## Dedup'd reason table (by normalized category, count desc)

| Count | Normalized gap reason |
|------:|------------------------|
| 978 | `ref-mode: unbound variable 'X'` (sub-categorized below) |
| 283 | `ref-mode: CFieldAccess on unknown field 'X' (no record ctor in the field-order table)` |
| 111 | `ref-mode: unsupported clause parameter pattern PLit-LString` |
|  35 | `ref-mode: unsupported block statement in tail position` |
|   8 | `ref-mode: unknown constructor 'X' (not in the ctor table, not reserved)` |
|   5 | `ref-mode: non-Int literal tail switch head` |
|   4 | `wasm W5: dict param 'X' not in scope` |
|   3 | `only PVar/PWild parameters (pattern params are inner-match material)` |
|   1 | `ref-mode: non-Int literal switch head (Char/String literals are W6)` |

### Breakdown of the 978 `unbound variable` gaps

The dominant category is one emit site (`emitVarRef`'s fall-through), but the
identifiers it can't resolve split into clear sub-categories:

| Count | Sub-category | Identifiers |
|------:|--------------|-------------|
| 261 | **Match/guard fall-through pseudo-var** | `__fallthrough__` — the multi-clause / guard-chain fall-through label is never bound in ref-mode (the chain-decision lowering the LLVM backend has, missing here) |
| 353 | **Mutable-state externs** | `set_ref` (230), `Ref` (123) — the `Ref`/`set_ref` mutable-cell extern surface is unsupported (only `core`/`typecheck`/etc. heavy users hit it) |
| 112 | **`panic` extern** | `panic` — the panic/abort extern is not wired |
|  86 | **Array intrinsics** | `arrayGetUnsafe` (38), `arrayLength` (28), `arrayFromList` (15), `arrayMakeWith` (3), `arrayMake` (1), `arrayCopy` (1) |
|   7 | **String/Char externs** | `charToUpper`/`charToLower`/`charIsUpper`/`charIsSpace`/`charIsPunct`/`charIsLower`/`charIsAlpha` (1 each). **CLOSED (W11b):** `stringToChars` (was 23), `charFromCode` (was 9), `stringFromChars` (was 5) — real UTF-8 decode/encode + range-check WAT runtime (`$mdk_str_to_chars` / `$mdk_chars_to_str` / `$mdk_char_from_code`, byte-identical to `medaka_rt.c`); `charCode` (was 8) closed earlier in W11 |
|   4 | **IO externs** | `readFile` (2), `fileExists` (2) |
| ~111 | **Genuine in-body free vars** | `name` (28), `env` (14), `params` (10), `variants`/`pats`/`fields` (5 each), `s`/`first` (4), `vs` (3), and a long tail of singletons (`t`,`pub`,`mid`,`l`,`iface`,`derives`,`arm`,`arms`,…) — these are real lowering bugs where a let/lambda/where-bound name does not reach the body in ref-mode (e.g. `frontend_parser__parseInterface` body can't see its own `name`). Distinct from the externs above: these are *defined* in the program but the emitter loses the binding. |

## Obvious categories (for the self-hosting roadmap)

1. **Array intrinsics (86)** — `arrayGetUnsafe`/`arrayLength`/`arrayFromList`/
   `arrayMakeWith`/`arrayMake`/`arrayCopy`. The lexer and exhaustiveness checker
   are array-backed; no native WAT lowering exists for these yet. (W7 added the
   `$arr` type + `array.len`/`array.get` for *literals/ranges*, but these
   extern *functions* aren't wired as builtins in `emitLeafExternRef`/the var
   resolver.)

2. **Unsupported externs** — beyond arrays:
   - mutable state: `Ref` / `set_ref` (353) — the single largest extern bucket;
   - control: `panic` (112);
   - string/char: `stringToChars`/`stringFromChars`/`charFromCode`/`charCode`/
     the `charIs*`/`charTo*` predicates (51);
   - IO: `readFile` / `fileExists` (4).

3. **IO externs (4)** — `readFile`, `fileExists` (the loader's file surface).

4. **Unsupported Core-IR nodes / lowering** —
   - `CFieldAccess` on a field whose owning record-ctor isn't in the field-order
     table (283) — `'value'` dominates (i.e. `someRef.value`, the Ref-cell
     accessor), so this is coupled to the `Ref` extern gap;
   - `unsupported block statement in tail position` (35) — tail-position block
     lowering;
   - `non-Int literal tail switch head` (5) + `non-Int literal switch head`
     (1) — Char/String-literal switch heads (W6);
   - `__fallthrough__` (261) — multi-clause / guard-chain fall-through label
     (the chain-decision lowering present in the LLVM backend).

5. **Unsupported patterns** —
   - `unsupported clause parameter pattern PLit-LString` (111) — a function
     clause whose head matches a **string literal** directly (e.g.
     `keywordOrIdent "let" = …`); the ref clause-pattern path handles ctor /
     var / wildcard / Int-literal heads but not String-literal heads;
   - `only PVar/PWild parameters` (3) — non-trivial pattern in a position that
     must be a plain binder.

6. **Dispatch (4)** — `wasm W5: dict param 'X' not in scope` — a few `core`
   constrained fns (`clamp`/`maximum`/`minimum`) whose dict param isn't threaded
   in this whole-graph (un-DCE'd, un-monomorphized) emit.

7. **Genuine in-body free-var loss (~111)** — distinct from missing externs:
   names that ARE bound in the source (let/lambda/where/match binders) but don't
   reach the body under ref-mode lowering. The long singleton tail
   (`name`/`env`/`params`/…) localizes specific lowering bugs per binding.

## Notes

- This census is the WasmGC analogue of the LLVM emitter's
  `gapRecordEnabled`/`gapLog`/`emitProgramGaps` mechanism. The WasmGC emitter is
  **outside the self-host compiler graph** (only the gate/census entries import
  it), so these changes need **no fixpoint and no seed re-mint**.
- The default emit path (record mode OFF) is **behaviorally identical** to
  before this work: every `gap*` variant still `panic`s the same message when
  not recording, so the three wasm gates (`diff_wasm` 85, `diff_wasm_typed` 6,
  `diff_wasm_modules` 9) stay green.
- Census entry: `compiler/entries/wasm_emit_gaps_main.mdk`. Driver:
  `emitProgramGaps` in `compiler/backend/wasm_emit.mdk`.
