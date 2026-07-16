# WasmGC Backend Semantics: the physical-encoding + host-boundary supplement

**Status:** specification (supplement). **Scope:** the two things
`docs/spec/EMITTER-SEMANTICS.md` deliberately left out of the shared refinement
contract: (1) the **WasmGC physical encoding** of the abstract value contract
(`compiler/RUNTIME-DESIGN.md` §8.6, ratified 2026-06-07), stated as laws; and
(2) the **host-boundary contract** — the part of wasm's semantics that lives in
JS host imports (`test/wasm/run.js`, `playground/worker.js`), which is wasm's
biggest specification hole. §4 is the wasm arm of EMITTER-SEMANTICS §9: every
shared law → wasm status → issue.

## 0. What this document is NOT

It is **not a second refinement contract.** `docs/spec/EMITTER-SEMANTICS.md`
already binds the wasm refinement `W(P)` (its §0/§1: R2 quantifies over all
four engines, and every V/N/T/S/M/D law binds "all engines and every reflective
helper"). A wasm defect against those laws cites the *shared* law; this
document only adds the wasm-specific representation and boundary laws the
shared contract could not state without naming a backend. Where this spec and
`compiler/backend/wasm_emit.mdk` disagree, the disagreement is a finding to
triage, not a description error — same discipline as the parent document.

Audit provenance: founding audit 2026-07-16 at `be6159f3` (three parallel
static passes + binary probes; probe method: `medaka build` native vs
`medaka build --target wasm` + `node test/wasm/run.js`, eval arm via
`medaka run`). Verification legend follows `compiler/TYPECHECK-AUDIT.md`:
**CONFIRMED** / **LATENT** / **STATIC**.

---

## 1. The physical encoding contract (WP-laws)

WasmGC implements the §8.6 abstract value contract with **`(ref eq)` + i31 +
typed structs** in place of native's tagged word. The encoding never leaks
above Core IR; these laws are the wasm peers of EMITTER-SEMANTICS §2 (V1–V6).

- **WP1 — Uniform slot.** Every abstract value position (params, returns,
  fields, array elements, dict slots) is `(ref eq)`. Generics erase to
  `(ref eq)` + downcast — the same erasure dict-passing assumes. (Peer of V1.)
- **WP2 — Two-tier Int, one semantics.** `Int` in `[−2³⁰, 2³⁰)` is an
  `i31ref` immediate; outside that range it boxes as `$boxint`
  `(struct (field i64))`. The split is the ratified "one honest asymmetry":
  a **performance** fact, never a semantic one. The binding obligation:
  **the i64 field is a container for a 63-bit value, not a license for 64-bit
  arithmetic** — every producer of an `Int` (arithmetic result, extern return,
  literal) must land in the 63-bit domain of N1, wrapping modulo 2⁶³ exactly
  as native's tag-shift does. An unnormalized `$boxint` holding a value
  outside `[intMinBound, intMaxBound]` is a V2-class corruption: it prints,
  compares, and hashes as a number no other engine can produce. (Status: ✗
  CONFIRMED — see §4 N1 row.)
- **WP3 — Boxed cells are nominal-by-discriminant.** Heap aggregates are
  typed structs/arrays (`$float` `(struct f64)`, `$str`, `$arr`, `$tupN`,
  `$ref`, `$cons`, per-ctor structs). Because WasmGC subtyping is structural,
  two same-shape constructors are **not** distinguishable by `ref.test` —
  the explicit `i32` discriminant at field 0 of every ADT struct is therefore
  **mandatory, not an optimization** (peer of V4). Field-less constructors are
  i31 immediates carrying their ordinal.
- **WP4 — Tag spaces.** Match discrimination uses the ratified dense per-type
  ctor ordinal (`br_table`-ready — the native backend's target design, which
  wasm already implements). Dict-witness tags are name-hash-derived i32s
  (`dictTag`); the V4/M2 injectivity burden applies **with less headroom than
  native** (i32-truncated hash space, and the known layer-17 residual: wasm's
  dispatch-hash constants differ from native's i64 ones by 2³⁰-scale deltas —
  self-consistent, but a per-backend tag space that must independently satisfy
  M2). Like native (#348), wasm has **no emit-time collision check** on the
  hashed spaces.
- **WP5 — Strings.** `(array i8)` UTF-8 bytes + cached codepoint count —
  the same locked rep as native (RUNTIME-DESIGN §7 decision 2), so
  `stringLength` is a field read and string equality is byte equality.
- **WP6 — Closures.** Uniform code type + **arity carried in the closure
  struct** + universal `$mdk_apply` doing exact/under (PAP)/over (saturate +
  re-apply) dispatch. This is the design that kills the native table-miss
  class by construction; it is also the reference design EMITTER-SEMANTICS
  cites for node-carried decisions (the fallthrough label is threaded as an
  argument here, not stashed in a mutable Ref — why wasm never had the
  refutable-guard miscompile).
- **WP7 — Tail calls.** `return_call` / `return_call_ref` at every syntactic
  tail position (S1/S2's engine mechanism, guaranteed by Wasm 3.0). Exception:
  a tail call into a **host import** cannot be guaranteed-tail; a plain `call`
  there is conformant (host imports are leaf effect calls).
- **WP8 — Coded traps precede engine traps.** Wasm has no stderr; a Medaka
  trap is realized as: stream the coded `runtime error [E-*]: …` line through
  `mdk_write_err_byte`, then execute `unreachable`. The T1 obligation on this
  encoding: **every reachable trap fires the coded line first.** A path that
  reaches a raw engine trap (`ref.cast` failure, `i64.trunc_f64_s` range
  trap, `i64.div_s` edge) with no preceding coded line violates T1 — the
  user sees the engine's message ("illegal cast", "float unrepresentable in
  integer range"), which is an observation no other engine produces.
  (Status: ✅ the `floatToInt` violation is FIXED — #346/#372; `$mdk_float_to_int`
  now saturates via `i64.trunc_sat_f64_s` and never reaches the range trap, so
  there is no uncoded engine trap left on that path. See §4 N7 row.)
- **WP9 — The wasm reflective surface.** The `$mdk_value_*` WAT helpers
  (`$mdk_value_add/sub/mul/div/mod`, `$mdk_value_cmp`, `$mdk_value_eq`,
  `$mdk_value_cmp_num`/`$mdk_value_eq_num`, hash helpers, `$mdk_append`) are
  wasm's V6 reflective surface: each branches on a value's runtime shape
  (`ref.test`), each independently owes the §4 numeric laws, and adding one
  is a spec change. They are enumerated in the §4 V6 row.

---

## 2. The host-boundary contract (WH-laws)

Native's TCB below the emitted IR is `runtime/medaka_rt.c`. Wasm's is **two
JS files** — `test/wasm/run.js` (Node runner: gates, CLI users) and
`playground/worker.js` (the 0.1.0 front door) — plus the engine. Parts of the
observable semantics (float formatting, string→float parsing, process exit,
the entire IO surface) execute **in JS, not in the module**. That makes the
import surface part of the semantics, with laws:

- **WH1 — The import surface is closed and enumerated.** Every `env.*` import
  the emitter can declare is listed in §3 with a pinned contract. A new host
  import is a spec change: it lands with (a) a §3 row, (b) implementations or
  explicit capability stubs in **both** shims, and (c) a
  `test/CAPABILITY-EXCEPTIONS.txt` disposition if any engine withholds it.
- **WH2 — The C runtime is the behavioral oracle.** Where a host import
  reimplements something `medaka_rt.c` implements natively, the JS copy must
  be **byte-identical on the observable surface**: `mdk_float_fmt` ≡
  `mdk_float_lexeme` (N9's "one formatter" law quantifies over THREE copies:
  the C one and the two `fmt12g`s), `mdk_str_to_float` ≡ the `strtod`
  acceptance set (spelling set for inf/nan, empty-string rejection, trailing
  garbage, C99 hex floats), `mdk_exit` ≡ flush-then-exit. "Close enough for the
  fixtures" is how the `stringToFloat` divergence shipped (#370 — `Number("")` is
  `0`, `strtod("")` is a parse failure). #370 also shows the oracle constrains the
  SEAM, not just the shim: `strtod("nan")` SUCCEEDS with a NaN value, so a seam that
  returns only an f64 and reads NaN as failure cannot express the C contract at all
  — hence the separate `mdk_str_to_float_ok` channel. A JS shim behavior with no C-oracle
  equivalent (worker sandbox stubs) must be a **loud, named** capability
  error, never a value.
- **WH3 — Shim parity, LinkError ban.** Both shims provide the **same `env`
  key set**. A capability the playground sandbox withholds must still be a
  *callable* that raises the friendly `CapabilityError` at call time —
  instantiation must never fail with a raw `LinkError` on a module the
  compiler legally emitted. (Status: ✗ CONFIRMED — `worker.js` is missing the
  `mdk_write_file_reset/push/commit` trio; §4 R3 row.)
- **WH4 — Flush discipline.** On normal completion, `exit`, and trap alike:
  buffered stdout bytes, then buffered stderr bytes, are delivered before the
  process/worker stops (R1's observation triple includes stderr-on-trap).
  (Status: ✗ CONFIRMED — `run.js` `mdk_exit` drops accumulated stderr; §4 T1
  row.)
- **WH5 — GC refs never cross the boundary.** Strings and buffers marshal
  through the byte-channel protocol only: guest pushes path/name bytes
  (`mdk_path_reset`/`mdk_path_push`), host caches result bytes exposed as
  `(mdk_result_len, mdk_result_byte)`; args as `(count, len(i), byte(i,j))`;
  file writes stream through `mdk_write_file_push` and commit atomically.
  The protocol is stateful per module instance; imports that consume the path
  buffer (`takePath`) must be called in the guest's push→consume order.
- **WH6 — Engine baseline is pinned.** Node ≥ 24 (CI pins the dev box's
  major), `wasm-tools` parse+validate as the assembler gate; Wasmtime needs
  `-W gc -W tail-call`. The playground must feature-detect WasmGC (#75) —
  an unsupported browser is a *named* failure, not a hang.

---

## 3. Host-import inventory (the wasm TCB surface)

> One row per `env.*` import name the emitter can declare. "Emitted when":
> imports are declared per **group** when the program's extern usage pulls the
> group in, not per individual extern — a pure program declares only the core
> quartet (`mdk_write_byte`, `mdk_write_err_byte`, `mdk_float_fmt`,
> `mdk_float_fmt_byte`; probe-verified 2026-07-16).

| Import | Declared (`wasm_preamble.mdk`) | Emitted when | `run.js` | `worker.js` | Contract | Law risk |
|---|---|---|---|---|---|---|
| `mdk_write_byte` | ~184 | unconditional | real (accumulate, decode at end) | real (accumulate, flush on `\n`) | one stdout byte | — |
| `mdk_write_err_byte` | ~319 | ePutStr/trap use | real (buffered; **lost on `mdk_exit`** — WH4 ✗) | real (streams + trap-copy) | one stderr byte | T1 |
| `mdk_float_fmt` / `mdk_float_fmt_byte` | ~922 | any Float use | real (`fmt12g`) | real (byte-identical copy) | float → cached shortest-round-trip lexeme (≡ `mdk_float_lexeme`) | N9 — **verified equivalent by review + probe battery** (the #361 ask); comments still say `%.12g` |
| 14 unary libm (`mdk_cbrt exp log log2 log10 sin cos tan asin acos atan sinh cosh tanh`) | ~939–952 | math-extern use | real (`Math.*`) | real | transcendental | N4-adjacent: JS `Math.*` vs C libm sub-ULP (ledgered class) |
| `mdk_pow` / `mdk_atan2` / `mdk_hypot` | ~953–955 | math-extern use | real | real | binary libm | same |
| `mdk_str_to_float` | ~968 | `stringToFloat` use | real — strtod acceptance set | same | parse path-channel bytes; latch ok | **WH2 ✅ FIXED** (#370) |
| `mdk_str_to_float_ok` | ~969 | `stringToFloat` use | real — ok flag of the last parse | same | did that parse succeed? | **WH2 ✅** (#370; `Some nan` needs a channel NaN cannot carry) |
| `mdk_path_reset` / `mdk_path_push` | ~1106–1107 | IO group | real | real | guest→host byte channel | — |
| `mdk_read_file` / `mdk_file_exists` / `mdk_get_env` | ~1108–1110 | IO group | real (Node fs/env) | capability stub | 1/0 + cached result bytes | capability |
| `mdk_args_count` / `mdk_arg_len` / `mdk_arg_byte` | ~1111–1113 | IO group | real (`MDK_ARGS`) | capability stub | argv marshaling | capability |
| `mdk_result_len` / `mdk_result_byte` | ~1114–1115 | IO group | real | capability stub | read cached result | — |
| `mdk_exit` | ~1116 | IO group | real, **drops buffered stderr** | capability stub (clean `exit 0` reports an error — deliberate, UX-noteworthy) | flush + exit | T1/WH4 ✗ |
| `mdk_write_file_reset` / `_push` / `_commit` | ~1223–1225 | `writeFileBytes` use | real | **MISSING → LinkError** | streamed file write | **WH3 ✗ CONFIRMED** |
| `mdk_write_int` / `mdk_write_bool` | ~53–54 | **never** (dead W2 scaffold; verified unreferenced) | absent | absent | legacy | — |

---

## 4. Conformance table — wasm against every shared law

> Wasm arm of EMITTER-SEMANTICS §9, founding audit 2026-07-16 at `be6159f3`.
> A ✗/⚠ row without an issue number is a documentation bug. Probe transcripts:
> the audit's probe ledger (p-numbers below) ran native `build` vs wasm
> `build --target wasm` vs `run` on the same source.

| Law | Wasm status | Evidence / issue |
|---|---|---|
| R1/R2 refinement | ✅ sampled | `diff_wasm` (154) + `diff_wasm_typed` + `diff_wasm_modules` + `diff_sqlite` + `diff_compiler_engines`; violations pinned in `test/engine_divergence.txt`. ⚠ coverage caveat: the CI `wasm` job is **advisory, not a required check** (`ci.yml`: "a red wasm job does not BLOCK a merge yet") |
| R3 — rejection fidelity | ⚠ | emitter gaps land as loud `BuildErr` diagnostics via the subprocess seam (`build_cmd.mdk` wraps the E-PANIC — disposition conformant); quality defects: range-pattern gap prints `?`, native-only externs die as "unbound variable" — **#380** |
| R4 — totality | ✗ CONFIRMED | reachable ref-mode gaps: recursive `let..in`, refutable guard in tail arm, range patterns — **#379**; the string/char-literal match-head **invalid-module** class (the forbidden third disposition; only `wasm-tools validate` makes it loud) — **#374**. Scalar-mode gaps (CRecord/W7 rows) are **unreachable from check-accepted input** — any ctor/string/closure forces ref-mode; those ledger rows are ill-typed fixtures reaching an emitter that doesn't gate on type errors |
| R5 — no UB | ⚠ | the `INT64_MIN /(−1)` div-overflow trap is **GONE** — #368's renormalization makes i64 `INT64_MIN` unreachable, so the claim it invalidated holds again. Pinned by `arith_int63_div_intmin`, whose dividend is `intMinBound + intMinBound` — an ADD that overflows to exactly **−2^63**, since `i64.div_s` traps only on `INT64_MIN` and `intMinBound` is −2^62, **not** INT64_MIN (a `intMinBound / −1` fixture yields a wrong value, not a trap, and pins nothing here — that case is `arith_int63_div_wrap`, which covers the scalar `/` renormalization instead). Verified against the pre-fix emitter: trap → `0`. Residual: dispatch-chain `unreachable`s cite coherence but are invalidated under #377 collision / #324 key-space mismatch, and #372's `i64.trunc_f64_s` still traps uncoded |
| V1–V3, V5 rep (WP1–WP3) | ✅ | ratified §8.6 encoding; typed structs + mandatory explicit discriminant; `$float` boxed f64 |
| V4/M2 — tag injectivity (WP4) | ⚠ STATIC | ctor tags = dense per-type ordinals, collision-free by construction (`br_table` — the design native #355 wants); **dict-witness tags are 30-bit-truncated djb2 with no emit-time check** — **#377** (also the layer-17 hash-width residual's tracker); no native-style hashed-sentinel population exists on wasm |
| V6 — reflective surface (WP9) | ⚠ enumerated | `$mdk_value_add/sub/mul` ✅ (each re-boxes through `$mdk_box_int`, so **#368 FIXED** closes the width hole they inherited — probe-verified via a `Num a => a -> a -> a` dict call at `Int`), `$mdk_value_div/mod` ✗ unguarded zero (**#371**), `$mdk_value_cmp`/`_num` ⚠ 3-way, NaN→EQ — reachable ONLY for the `$str`/int shapes now that relational ops call the per-op IEEE `$mdk_value_lt/le/gt/ge`(`_num`) ✅ (**#305 FIXED**; lockstep with native `mdk_value_lt/le/gt/ge`), `$mdk_value_eq` ✅ (`f64.eq` NaN/−0.0-correct; `$boxint` by value — probe-verified), `$mdk_float_rem` ✅ (exact fmod via power-of-two reduction; **#369 FIXED** by #388), `$mdk_append` ✅, hash/RNG helpers ✅ (SplitMix64/FNV constants + full-width `hashInt` verified vs `medaka_rt.c`) |
| DL1 — transcribe routes | ✅ | RKey/RLocal/RDict transcribed; chain order decl-order but semantically inert while tags are distinct |
| DL2 — dict witnesses obey V4 | ✗ STATIC | **#377** (30-bit space, no check) |
| DL3 — `unreachable` under coherence | ⚠ | conformant except: witness/chain key-space mismatch under overlap through a dict param (runtime `unreachable` on a valid program — **#324**, facet added 2026-07-16) |
| N1 — 63-bit wrap | ✅ | **#368 FIXED** — sign-extend from bit 62 (`(x << 1) >> 1`, mirroring native's tag/untag) at BOTH Int seams: `$mdk_box_int` (ref mode re-boxes after every op, and it is the sole `$boxint` producer ⇒ "a `(ref eq)` Int holds a 63-bit value" is a representation invariant) and, separately, at each scalar-mode `+ - * /` — scalar mode (`useRef == False`) never boxes, so the box seam alone would have left 64-bit intermediates. Pinned by `arith_int63_wrap_scalar` / `arith_int63_wrap_boxed` |
| N2 — div/mod | ⚠ | inline paths guarded with coded traps, codes match (probe); poly helper arms unguarded (**#371**); `INT_MIN/−1` is structurally unreachable again now that #368 renormalizes (`arith_int63_div_intmin`) |
| N3 — Int literals | ✅ | i31 / `i64.const`+box split exact over the legal range; out-of-range is a frontend reject |
| N4 — IEEE ops | ⚠ | inline `f64.add/sub/mul/div` ✅ no fast-math; `%` ✅ **exact fmod on BOTH the inline and poly paths** — **#369 FIXED** by #388 (`53f63fbd`), which landed N4 as ONE cross-engine semantics with native #345: `$mdk_float_rem` is the libm power-of-two reduction (`wasm_preamble.mdk:1024-1046`) and `$mdk_value_mod`'s Float arm routes to it (`:730-734`); re-verified 2026-07-16 with 36 probes (inline+poly × 6 cases × 3 engines, incl. `1.0e17 % 3.0` → `1.0` and `1.0e300 % 1.0e-300`), pinned by `test/wasm/fixtures/polynum_mod_float{,_large,_neg}.mdk`. **Residual ⚠ (NOT the old S0):** transcendentals are JS `Math.*` host imports (sub-ULP vs C libm, ledgered class — §3 row 14) |
| N5 — IEEE compare, uniformly | ✅ | inline predicates ✅ (probe: `nan==nan` False, `!=` True, `<`/`<=` False; `-0.0` prints/compares right); `$mdk_value_eq` ✅; the type-lost relational path **#305 FIXED** — `$mdk_value_lt/le/gt/ge`(`_num`) answer a `$float` operand with a direct `f64` predicate (IEEE, False at NaN) and use the 3-way only for `$str`/int, **in lockstep with native** |
| N6 — total-order story | ✅ | **DECIDED + IMPLEMENTED 2026-07-16 (#360)**: `compare`/`min`/`max`/`sort` at Float = IEEE-754 totalOrder (−NaN < −inf … +inf < +NaN). Implemented ONCE, in `impl Ord Float` (`stdlib/core.mdk`) — it is prelude Medaka, not backend code, so wasm inherits it with no `wasm_emit.mdk` change and no divergence surface. Derived `<`/`<=`/`>`/`>=` stay primitive IEEE on every path (all four False at NaN): the impl explicitly overrides them, since Ord's DEFAULTS would derive them from `compare` and re-open **#305**. `min`/`max` keep the compare-derived defaults on purpose. ⚠ **Not pinned on the wasm arm**: the totalOrder fixtures are prelude-bearing, and the typed corpora `diff_wasm_typed.sh` runs are prelude-FREE (a real prelude emit hits the W6/W7 gaps — see that gate's header), so no 3-engine gate can reach `impl Ord Float` today. eval == Core IR == native are pinned; wasm rests on the shared-prelude argument. Closing that hole is the wasm-arm half of #102 |
| N7 — conversions total | ✅ **FIXED (#346/#372)** | `$mdk_float_to_int` = `i64.trunc_sat_f64_s` **then clamped** to the 63-bit `intMinBound`/`intMaxBound` before the `$mdk_box_int` seam — `trunc_sat` alone saturates to i64 bounds, which the box seam would renormalize to `−1` rather than the bound (the clamp is pinned by `float_to_int_clamp_i64`). NaN→0, ±inf/out-of-range→`intMaxBound`/`intMinBound`, no trap; eval==native==wasm. `intToFloat` ✅ (`f64.convert_i64_s`) |
| N8 — know, don't guess | ✗ STATIC (architectural) | the wasm recovery stack: `cexprIsFloat` structural arms, `refMainKind` defaults-to-Int, `numPolyLocalsRef` lexical seeding — wasm arm of umbrella **#353**; mitigations: the typecheck `RScalar` stamp is read first, and most wrong guesses die as loud `ref.cast` traps, not garbage |
| N9 — one formatter, round-trip | ✅ **verified** | the three copies (`mdk_float_lexeme`, two `fmt12g`s) reviewed element-by-element + 22-case probe battery byte-identical (incl. −0.0, denormals, 3-digit exponents, 17-digit shortest) — the #361 wasm verification; WAT `f64.const` literal serialization bit-exact via the same formatter; residual: stale `%.12g` comments — **#383** |
| T1 — closed coded taxonomy | ⚠ | `E-DIV-ZERO`/`E-MOD-ZERO`/`E-INDEX-OOB`/`E-NONEXHAUSTIVE-MATCH`/`E-PANIC` coded, stdout-flushed, exit-1 parity (probes); **uncoded engine traps reachable** via #371/#372 (WP8 violations; the #368 div-overflow corollary is FIXED — that trap is now unreachable); `CTFail` is a coded trap, better than a bare `unreachable` |
| T2 — traps ≠ values | ✅ | no catch mechanism; codes agree where coded |
| T3 — stack overflow | ⚠ unaudited | engine-reported exhaustion; not probed this audit |
| S1/S2 — tail calls / TRMC | ✅ gated | `return_call`/`return_call_ref` (fixture-asserted IR shape); TMC parity + EXPECT-TMC coverage pins (`tmc_parity`; residual #224 is the check_main leg) |
| M1 — mangling injective | ✗ STATIC | `gname` near-identity punctures + separator-ambiguous `implFnSym`, no post-mangle check — **#378** (order constraint with #324's sanitizer); #324 canonical-key symbols |
| M3 — private invisible | ✅ inherited | universal mangling shared with native (upstream of both emitters) |
| D1 — deterministic emission | ✅ | probe: byte-identical `.wasm` across rebuilds; static pass: all Refs reset per program, no env/clock reads, sequential counters |
| D2/D3 — fixpoint + seed | n/a / ⚠ | wasm has no seed and no self-compile fixpoint; the wasm **self-host** (playground.wasm = the compiler on WasmGC) is linkage-gated (`assemble_check_main.sh`: parse+validate+zero undefined wrappers) but has **no fixpoint-analog behavior gate** — open D2-style assurance gap, noted in #384 |
| D4 — own-source competence | ⚠ | the D4-analog closure is "what the playground compiler emits for itself"; unaudited beyond the linkage gate |
| Perf posture | ⚠ | **#381 FIXED** by #401 (`5d82fa48`): `ctorOrdinal`'s per-(slot,branch) whole-table rescan was **CUBIC** — O(N ctors × B branches × C table), measured 7.91×/8.35× per doubling at N=400/800 on the DCE-running probe — now memoized to **1.90× (linear)**, a 53× win at N=400, proven by byte-identical WAT across 200 fixtures. ⚠ It was **never "wasm-specific"**: `llvm_emit`'s `ctorOrdinal` has the **same** scan and a **quadratic** twin (3.71/3.73 at N=1000→4000, **#408**); only the slot×branch nesting was wasm's. `indent` (**#381**'s own second finding — NOT #382) is fixed for the re-copying (8.1×) but **cannot reach linear** — the if/else chain nests arm *k* at depth *k*, so the output is inherently O(arms²) **bytes**. Residual: the #349–#352 sibling census (**#382**); enforcement — the **native** emit stage shipped (#396), **the wasm arm is still open (#359)**, and it must grade **TIME** (pure scans allocate nothing) |
| WH1 — enumerated imports | ✅ | §3 inventory (grep-complete; dead W2 scaffold imports verified never-emitted) |
| WH2 — C-runtime oracle | ✅ **HELD** | `mdk_str_to_float` was JS `Number()`, not strtod (`""`→`Some 0.0`, `"1.5 "`→`Some 1.5`, `"nan"`/`"inf"`→`None`, `"0x1p4"`→`None`) — **#370 FIXED**: both shims now implement the strtod acceptance set (leading-ws-only, full consumption, inf/nan spellings, C99 hex floats), derived from the C oracle over a 621-case battery and pinned on all three engines by `test/llvm_fixtures/str_to_float_frontier.mdk`; `mdk_float_fmt` ✅ verified (N9 row) |
| WH3 — shim parity, LinkError ban | ✗ CONFIRMED (env-key half) | `worker.js` missing `mdk_write_file_reset/push/commit` → raw LinkError on `writeFileBytes` programs (node simulation with worker's exact env set) — **#375**, still open. The SHARED-BLOCK half is now mechanised: `test/diff_compiler_wasm_shim_parity.sh` (a required `gates (frontend)` shard) byte-diffs every `--- SHARED SHIM ---` region across the two hosts. It found `fmt12g` had ALREADY drifted (comments/whitespace only — behaviour unaffected) under the "copied verbatim" comment that was the only prior enforcement. The env-KEY-SET half (#375) is still unchecked by any gate |
| WH4 — flush discipline | ✗ CONFIRMED | `run.js` `mdk_exit` writes stdout, **drops buffered stderr** — **#376**; trap path flushes both ✅ (probe: pre-trap stdout delivered) |
| WH5 — byte-channel only | ✅ | no GC ref crosses an import signature (inventory) |
| WH6 — engine baseline | ⚠ | node 24 + wasm-tools pinned in CI; playground WasmGC feature-detect still open (**#75**); the CI wasm job is not a required check (R1 row) |

---

## 5. Reading recurring wasm defects against this spec

- **"illegal cast" at instantiate** → N8/WP2: a static scalar-type guess
  committed to the Int path over a `$float` (or vice versa); find which
  registry (`cexprIsFloat` arm, float-param/ret table) missed the fact the
  typechecker knew.
- **"func N failed to validate"** → an R3 violation *class of its own*: the
  emitter produced an invalid module instead of a named `gapL` rejection.
  The `wasm-tools validate` step is the backstop that makes it loud, but the
  diagnostic names no construct — triage by minimizing the fixture.
- **"instantiate failed: <engine text>"** with no `runtime error [E-*]` line
  → WP8/T1: a raw engine trap on a path that never streamed its coded line —
  or WH3: a LinkError from a shim missing an import.
- **A large wrong number, no error** → WP2/N1 (an unnormalized `$boxint` —
  wasm-only value), or a tag leak (odd `2n+1` reading of an i31 — the
  `charCode charMaxBound` shape).
- **Wrong answer only via a HOF / only when type-lost** → the `$mdk_value_*`
  runtime helpers (WP9): the reflective surface re-implements the operation;
  check its shape arms against N4/N5/N6.
- **Works in run.js, breaks in the playground** → WH3 shim-parity; diff the
  two `env` objects before diffing the module.
