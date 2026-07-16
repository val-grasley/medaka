# Native-Emitter Semantics: the Refinement Contract

**Status:** specification (theory-first). **Scope:** what it means for the LLVM
native backend (`compiler/backend/llvm_emit.mdk` + `runtime/medaka_rt.c`) to be
*correct*, stated as laws the emitted code must satisfy — observation
preservation, the value-representation invariants, numeric semantics, trap
totality, identity/naming injectivity, and emission determinism. The WasmGC
backend is bound by the same laws (it is the peer refinement, §1); its
backend-specific encoding is out of scope here.

## 0. Purpose and the non-derivation principle

The objection to writing this document is that "the emitter *is* the semantic
mapping" — there is no OCaml oracle anymore, so what would the spec be checked
against? The objection dissolves once the pipeline is layered correctly:

> **A Medaka program's meaning is fixed *before* the emitter runs.** Type
> checking and dictionary elaboration produce an elaborated core program, and
> `docs/spec/DICT-SEMANTICS.md` §7 (the single-evaluator law) already commits
> to *one* core semantics of which every engine — the tree-walker, the Core-IR
> interpreter, native, wasm — is a **refinement**. The emitter is therefore
> not the semantics; it is a *representation choice* for a semantics defined
> upstream, and a representation choice can be specified and audited like any
> other: by the invariants it must preserve.

This document fixes those invariants **from the theory of compiler refinement**
(observational/contextual refinement between a source semantics and a machine
model), not from the current code. Where this spec and the implementation
disagree, the disagreement is a finding to triage — the spec is not a
description of present behavior. Deliberate, gate-pinned divergences live in
ledgers (`test/engine_divergence.txt`, `test/CAPABILITY-EXCEPTIONS.txt`), never
in silence.

Theory anchors: compiler-correctness as observational refinement (CompCert's
"the compiled program improves on the source program's behaviors" — Leroy);
uniform tagged value representation (OCaml's runtime model); IEEE 754-2019 for
floating point. The terminology bridge:

| Medaka artifact | This document |
|---|---|
| elaborated core + tree-walker (`compiler/eval/eval.mdk`) | the **reference semantics** `⟦P⟧` |
| Core IR (`compiler/ir/core_ir.mdk`) | the compilation IR; its interpreter (`compiler/ir/core_ir_eval.mdk`) is a second refinement |
| emitted IR → clang → binary | the **native refinement** `N(P)` |
| `wasm_emit.mdk` → WasmGC module | the **wasm refinement** `W(P)` |
| a `medaka check`-accepted program | a **well-typed program** (the domain of every law) |

---

## 1. Observables and the refinement law

**Definition (observation).** For a well-typed program `P` run on input‑free
`main`, the observation `obs(·)` is the triple:

1. **stdout** — the exact byte sequence written;
2. **outcome** — `Value` (ran to completion, exit 0), `Trap c` (aborted with
   runtime-error code `c`, §5), or `Divergence`;
3. **stderr on trap** — the diagnostic line carrying the stable `E-*` code.

Exit *status* on `Trap` is part of the outcome (nonzero), but its numeric value
is only pinned where a law says so (`exit`/`abort` externs). Resource
exhaustion (heap OOM, guard-page stack overflow) is **not** an observation:
a refinement may exhaust resources earlier or later than the reference, except
where §6 (space laws) pins a bound.

- **R1 — Observational refinement (the master law).** For every well-typed
  `P`: `obs(N(P)) = obs(⟦P⟧)`. Not "≈", not "up to formatting": byte-equal
  stdout, same outcome class, same trap code. This is the law the differential
  gates sample.
- **R2 — One meaning, every engine.** `obs(⟦P⟧) = obs(ceval(P)) = obs(N(P)) =
  obs(W(P))`. A pairwise-green parity between two engines that are *equally
  wrong* does not discharge R2 — coverage of the underlying capability must be
  gated separately (the TMC dict-veto lesson).
- **R3 — Rejection fidelity.** If `medaka check` rejects `P`, then `build`/`run`
  must reject it **with a diagnostic** — never emit a binary, never trap at
  run time, never produce a value. Conversely a `check`-accepted program must
  not be rejected by the emitter except through a *declared* capability gap
  (a `gapE`-class diagnostic naming the construct), never a silent wrong
  answer. `check` green + `build` wrong is this repo's defining S0 shape.
- **R4 — Totality over the accepted fragment.** For every Core IR construct
  reachable from a well-typed program, the emitter either lowers it correctly
  (R1) or rejects it loudly (R3). There is no third disposition. The
  gap-census methodology (`compiler/EMITTER-GAPS.md`) exists to enumerate the
  frontier; the census reaching 0 made R4 *currently true*; this law keeps it
  true as the language grows.
- **R5 — No undefined behavior.** The emitted IR must have no LLVM UB on any
  reachable path of a well-typed program: no unguarded `sdiv`/`srem` (§4 N2),
  no out-of-range `fptosi` (§4 N7), no `unreachable` reachable under a
  guarantee weaker than a typechecker proof (each `unreachable` must cite the
  invariant that makes it dead — and that invariant must actually be enforced
  upstream, cf. coherence for dispatch chains). UB is worse than wrongness:
  it is wrongness that moves with the optimizer.

**Divergence ledger discipline.** A known R1/R2 violation is pinned in
`test/engine_divergence.txt` (fail-on-accidental-fix, promote by deletion). A
capability asymmetry is pinned in `test/CAPABILITY-EXCEPTIONS.txt`. A
divergence in neither ledger and not in an open issue is by definition an
unfiled S0.

---

## 2. The value-representation contract

Ratified 2026-06-07 (`compiler/RUNTIME-DESIGN.md` §8; restated here as laws
because every numeric and dispatch law below leans on them).

- **V1 — Uniform word.** Every runtime value is one 64-bit word. Every
  compiled function takes and returns words (`i64` ABI, true n-ary; §8.5).
- **V2 — Immediates are odd.** `word & 1 == 1` ⇒ immediate; payload =
  `word >> 1` (arithmetic). `Int`, `Char` (codepoint), `Bool` (False=0,
  True=1), `Unit` (0), and nullary constructors are immediates. Hence **Int is
  exactly 63-bit** (§4 N1) and a conservative scan never mistakes a scalar for
  a pointer.
- **V3 — Boxed cells are uniform.** `word & 1 == 0` ⇒ 8-byte-aligned pointer
  to `{ i64 header, fields… }`. One header word on *every* cell (Float,
  String, ctor, closure, record, tuple, Ref, thunk).
- **V4 — Tag soundness.** The header/immediate tag of a constructor is the
  *only* runtime witness of its identity, so the map
  `constructor → tag` must be **injective across every pair of constructors
  that any single runtime test can compare** — a `match` head test, an
  arg-tag dispatch chain, a dict-witness comparison. A tag scheme that is
  injective per-type but aliases across types is sound only while no
  cross-type comparison exists; the burden of proof is on the emitter, and
  "the hash didn't collide this week" is not proof. (Ratified target: dense
  per-type ordinals, composite `typeId<<32 | ordinal`; residual string-hash
  tags are conformance findings, §9.)
- **V5 — Float is a boxed IEEE-754 binary64.** `{ header, double }`. Unboxing
  is an optimization permitted at monomorphic sites only (§4 N8 governs when
  the emitter may *believe* a site is monomorphic-Float).
- **V6 — The reflective surface is closed and enumerated.** The design
  principle is "the runtime never reflects on a value's layout" (type-directed
  behavior resolves at compile time). Every exception — a C helper that
  branches on a value's low bit or header at run time (`mdk_value_eq`,
  `mdk_value_cmp_raw`, `mdk_append`, generic hash/show paths, arg-tag dispatch
  chains) — is part of the **reflective surface** and must (a) be enumerated
  in this spec's conformance table, (b) individually satisfy the numeric laws
  of §4 (this is where the NaN bug family lived: each reflective helper
  re-implements comparison and each re-implementation is a chance to get IEEE
  wrong), and (c) never *widen* silently: a new reflective helper is a spec
  change, not an implementation detail.

---

## 3. Dispatch lowering (refinement of DICT-SEMANTICS)

Dictionary semantics are fully specified in `docs/spec/DICT-SEMANTICS.md`; the
emitter adds only representation. The binding laws:

- **DL1 — Elaboration decides, the backend transcribes.** Every dispatch
  decision (which impl, which dict, most-specific-wins under overlap) is taken
  during elaboration and carried on the node/route. The emitter must never
  re-derive a dispatch decision from names, declaration order, or runtime
  tags except as the side-condition-guarded arg-tag *optimization* of
  DICT-SEMANTICS §5 — applied identically by every engine (§7 there).
- **DL2 — Dict witnesses obey V4.** A dictionary witness word compared at run
  time (dispatch-chain `icmp`) is a tag; the injectivity burden of V4 applies
  to the impl-key → witness-tag map exactly as to constructor tags.
- **DL3 — An exhausted dispatch chain is `unreachable` only under coherence.**
  The typechecker's coherence guarantee (DICT-SEMANTICS §6) is the invariant
  that justifies the dead arm. Any path that can reach dispatch with a value
  outside the proven impl set (e.g. a tag aliased across types, V4 violation)
  invalidates the `unreachable` and is an R5 violation.

---

## 4. Numeric semantics

The numeric tower is `Int` and `Float`, with no implicit conversion. These
laws bind **all four engines** and every reflective helper (V6).

### Int

- **N1 — Int is 63-bit two's complement, and it wraps.** `intMaxBound =
  2^62 − 1`, `intMinBound = −2^62`. Overflow on `+ - *` (and `intMinBound`
  negation/division edge cases) **wraps modulo 2^63** — by decision, not
  accident. Consequently the emitter must never emit `nsw`/`nuw` flags or an
  overflow trap on Int arithmetic, and no engine may promote to a wider
  integer. (Wrapping falls out of V2's tag-shift discipline: retagging
  truncates to 63 bits; that mechanism *is* the semantics.)
- **N2 — Division truncates toward zero and traps on zero.** `/` and `%` on
  Int are C-style truncating division/remainder (`sdiv`/`srem` on the untagged
  payloads); `x / 0` traps `E-DIV-ZERO`, `x % 0` traps `E-MOD-ZERO` — a
  *guarded* trap emitted before the hardware instruction, because a zero
  divisor is LLVM UB (R5). The identity `(a/b)*b + a%b == a` holds for all
  defined cases. `intMinBound / (−1)` and `intMinBound % (−1)` are defined by
  N1's wrap (payloads are 63-bit, so the i64 hardware edge case is
  structurally unreachable — a proof obligation on V2, not a hope).
- **N3 — Int literals.** A decimal literal in `[intMinBound, intMaxBound]`
  denotes that integer exactly, in every engine and in the emitted IR text.
  Out-of-range literals are a *frontend* concern (diagnostic), but the emitter
  must reject rather than silently truncate any literal that reaches it
  out of range (R3).

### Float

- **N4 — Float ops are IEEE-754 binary64, exactly.** `+ - * /` on Float are
  the IEEE operations on the unboxed doubles (`fadd/fsub/fmul/fdiv`,
  round-to-nearest-even, no fast-math flags — ever). `x / 0.0` is IEEE
  (±inf, NaN), **not** a trap. `%` on Float is C `fmod` — the *exact* IEEE
  truncated remainder (result of `a − b·n`, `n = trunc(a/b)`, computed exactly),
  **not** the one-step `a − b·trunc(a/b)`, which rounds `a/b` and loses precision
  for large ratios (`1e300 % 7` → `1e300`/`0`, not `1`). This binds every arm:
  inline `frem`, the `floatRem` extern (`mdk_float_rem`), native's runtime-dispatch
  `mdk_num_mod`, and wasm's `$mdk_float_rem` (an exact power-of-two reduction) +
  `$mdk_value_mod` — all fmod, all byte-identical (#345). No engine may contract
  (`fma`), reassociate, or constant-fold under rules other than IEEE.
- **N5 — Comparison is IEEE-ordered, uniformly.** `< <= > >=` on Float are the
  IEEE ordered predicates: **every one is false when either operand is NaN**;
  `==` is false and `!=` is true on NaN; `-0.0 == 0.0`. The load-bearing word
  is *uniformly*: the same answer must come from the inline `fcmp` path, the
  interpreter's `evalArith`, the generic/dict-routed `Ord`/`Eq` paths, and
  every V6 reflective helper (`mdk_value_eq`, `mdk_value_cmp_raw`, wasm's
  `$mdk_value_cmp`). A path that funnels Float comparison through a
  three-way `compare` and back **cannot** be IEEE-correct, because a total
  `Ordering` has no "unordered" — see N6.
- **N6 — `compare` at Float needs a decided total-order story.** IEEE defines
  the four predicates; it does *not* give `compare : Float -> Float ->
  Ordering` a lawful answer at NaN (LT/EQ/GT are all wrong; each choice makes
  some derived operator lie). This spec pins the decision structure rather
  than silently choosing: (i) the **derived-operator law** — `<`/`<=`/`>`/`>=`
  at Float must **never** be routed through `compare` (they are primitive
  IEEE predicates; N5); (ii) `compare`/`min`/`max`/`sort` at a NaN operand is
  a **flagged owner decision** — candidates are IEEE-754 `totalOrder`
  (−NaN < −inf … +inf < +NaN), "NaN poisons: trap E-NAN-ORD", or "unspecified
  but engine-uniform". Until the owner decides, the *conformance requirement*
  is engine-uniformity (R2): all four engines must give the same answer, and
  the current per-engine improvisation is a standing R2 violation (#305
  family). **FLAG: owner decision wanted.**
- **N7 — Conversions are total and defined.** `intToFloat` is IEEE
  round-to-nearest (63-bit ints above 2^53 round; that rounding is the
  semantics, identically everywhere). Float→Int conversions (`truncate`,
  `floor`, `ceil`, `round`) must define NaN, ±inf, and out-of-63-bit-range
  inputs — as a trap with a stable code or a pinned saturation, never a raw
  `fptosi` (out-of-range `fptosi` is poison; R5) and never an engine-varying
  answer.

  **PINNED (owner decision, 2026-07-16, #346): `floatToInt` SATURATES. No
  trap.** NaN → `0`; `+inf` / above range → `intMaxBound`; `−inf` / below
  range → `intMinBound`; in-range truncates toward zero. Lowered as
  `llvm.fptosi.sat.i64.f64` (native) / `i64.trunc_sat_f64_s` (wasm); eval
  inherits the native arm through the `floatToInt` extern.

  ⚠️ **The saturating intrinsic ALONE IS NOT CONFORMANT on either backend.**
  Both saturate to **i64** bounds (±2^63), but Medaka's `Int` is the 63-bit
  payload of the tagged word (RUNTIME-DESIGN §8), so its domain is
  `[−2^62, 2^62−1]`. An i64-saturated result is *outside* the Int domain: on
  native, `tagInt`'s `shl 1` shifts `INT64_MAX` straight out the top and it
  decodes to `−1`; on wasm, `$mdk_box_int`'s renormalization wraps it the same
  way. **Each backend must clamp the saturated value to
  `intMinBound`/`intMaxBound` BEFORE tagging/boxing** — saturate-then-box is
  the wrong order. Pinned by `float_to_int_clamp_i64` (input `2^63` exactly),
  which is red under the intrinsic alone.
- **N8 — The emitter must KNOW, not GUESS, scalar types.** The int-vs-float
  choice at every arithmetic/comparison/print site must derive from a fact
  established by the typechecker and carried to the emitter on the node
  (e.g. the `RScalar` stamp), or from a value's actual runtime witness (dict
  dispatch). A structural heuristic (scan the body for a float literal, infer
  a param's type from its first use, default to Int when unknown) is only
  admissible when a wrong guess is *impossible*, i.e. the heuristic is backed
  by a typechecker invariant; "defaults to Int" at a site that can hold a
  boxed Float is a standing miscompile generator (garbage bits, no error —
  the worst class). The comprehensive form of this law: **scalar type
  information flows down the pipeline; it is never re-derived by the
  backend.** Every existing recovery heuristic is a conformance finding until
  it is either deleted (fact carried instead) or proven invariant-backed
  (§9).
- **N9 — One float formatter, one parser, round-trip closed.** All engines
  print a Float through one algorithm with pinned edge cases (`1.0` prints
  `1.0` with the trailing `.0`; negative zero, inf, NaN spellings pinned) and
  the printed form of any finite Float must **re-lex to the identical bits**
  (shortest-round-trip or full-precision — pinned by the formatter, and the
  lexer must accept every string the formatter can emit; the `9e+15`
  formatter-output-the-lexer-rejects incident, #51, is the canonical
  violation). The emitter's serialization of a Float literal *into IR text*
  must likewise be bit-exact (hexadecimal float constant or provably
  round-tripping decimal — "close enough" decimal is a silent-wrongness
  source).

---

## 5. Trap semantics

- **T1 — The trap taxonomy is closed and stable.** Every partial operation
  the accepted fragment can reach has a named trap: `E-DIV-ZERO`,
  `E-MOD-ZERO`, index/bounds (`mdk_oob`), refuted irrefutable-let,
  non-exhaustive match (reachable only through a typechecker-acknowledged
  hole, e.g. a permitted inexhaustive match — otherwise dead by R5),
  explicit `panic`/`abort`/`exit`. A trap is: message to stderr with the
  stable code, buffered stdout flushed first, nonzero exit. Adding a trap is
  a spec change.
- **T2 — Traps are not catchable, and trap ≠ value.** No engine may convert a
  trap into a value (or vice versa); `medaka run` and the native binary must
  agree on *which* trap and its code (R1 includes the trap code; message
  wording is diagnostics-quality territory, the code is semantics).
- **T3 — Stack overflow is a resource event, not UB.** The native runtime
  detects overflow (guard page + fault handler) and reports it as a trap
  rather than corrupting state; the reference interpreter may overflow
  earlier/later (§1 carve-out) but never silently wrong.

---

## 6. Space and tail-call laws

- **S1 — Self tail calls are eliminated.** A self-recursive tail call runs in
  O(1) stack (`musttail`; the calling-convention side condition is satisfied
  by construction under V1's uniform prototypes).
- **S2 — TRMC.** A function accepted by the TRMC analysis
  (`compiler/backend/trmc_analysis.mdk`) builds its result in O(1) stack per
  element. The *analysis verdict* is engine-shared: **both backends must
  TRMC exactly the same functions** (`test/diff_compiler_tmc_parity.sh`), and
  the accepted population itself is coverage-gated (EXPECT-TMC pins), because
  a parity gate alone cannot see a shared veto (R2 note).
- **S3 — What is NOT promised.** General TCO (mutual recursion, arbitrary
  tail calls) is not promised by native; the interpreter's deep-recursion
  tolerance comes from a 256 MB worker stack, not an algorithmic guarantee.
  A program relying on non-self non-TRMC tail depth is outside the portable
  fragment (candidate for a documented ledger row, not silent divergence).

---

## 7. Identity, naming, and linkage

- **M1 — Mangling is injective.** The map `(module id, top-level name) →
  symbol` must be injective over any linkable program set. Sanitization
  (`sanitizeId`) collapses characters, so injectivity must be *enforced*
  (post-sanitization collision detection that renames or rejects), not
  assumed from the scheme's shape. Same law for impl canonical-key symbol
  sanitization and every other name → symbol map (lambda lifts, dispatcher
  thunks, globals).
- **M2 — Tags don't collide (V4 restated as an obligation).** Any tag space
  compared by one runtime test — composite ctor tags, reserved-block tags,
  sentinel hashes, dict-witness hashes — must be collision-checked **at emit
  time** (fail the build with a diagnostic), or constructed collision-free by
  construction with the construction stated. djb2-and-hope is neither.
- **M3 — Private is invisible.** Universal mangling must not make a private
  binding reachable across modules under its mangled name in source (a
  resolve-layer concern, but the emitter owns not *widening* visibility).

---

## 8. Emission determinism and self-hosting

- **D1 — Emission is a pure function.** Byte-identical IR text from identical
  `(program, stdlib)` inputs: no timestamps, no absolute paths, no
  environment- or iteration-order-dependence; opt-level and GC knobs affect
  the *binary*, never the IR text. (This is what makes the fixpoint and the
  golden gates meaningful at all.)
- **D2 — The self-compile fixpoint.** `emit(emitter_source)` is reproducing:
  stage-2 output ≡ stage-1 output byte-for-byte (C3a/C3b). Every change to
  the native self-compile closure re-proves this; a fixpoint break on a
  "correct-looking" change is evidence about the change, the seed, or an
  emitter self-hosting gap — all three are real (see the two-rebuild and
  seed-re-mint disciplines in the `benchmark-emitter` skill).
- **D3 — The seed is sufficient and portable.** The checked-in seed IR
  cold-bootstraps on x86-64 and arm64 from the same bytes (no target triple,
  no platform-conditional IR).
- **D4 — The emitter's own source stays inside its own competence.** The
  language fragment used *by* `llvm_emit.mdk` (and everything in the native
  self-compile closure) must be a fragment the emitter provably compiles —
  "provably" meaning: covered by the fixpoint plus a fixture, not folklore.
  When a construct is known-unsafe in the closure (the module-level
  `Ref (Option (HashMap …))` incident), that is an R4 capability gap to file
  and close, not a permanent style rule to whisper.

---

## 9. Conformance status — where the implementation stands against this spec

> Audit of 2026-07-16 (this document's founding audit, at `40e14b85`).
> Verification legend follows `compiler/TYPECHECK-AUDIT.md`: **CONFIRMED**
> (repro run against the binary) / **LATENT** (code path exists, trigger
> stated) / **STATIC** (code reading only). The backlog lives as `ws:emitter`
> GitHub issues (tracking: **#362**); this table maps law → status and is
> expected to be *edited toward all-✅* as the workstream lands. A ✗/⚠ row
> without an issue number is a documentation bug.

| Law | Status | Evidence / issue |
|---|---|---|
| R1/R2 refinement | ✅ sampled | `diff_compiler_engines` + llvm/build/typed gates; known violations pinned in `test/engine_divergence.txt` |
| R1 — Num-poly Float `%` | ✅ **FIXED (#345)** | `mdk_num_mod` float arm is now `fmod` (`medaka_rt.c`); wasm's `$mdk_value_mod` + `$mdk_float_rem` are an exact power-of-two-reduction fmod (byte-identical to libm across large/negative/small ratios); eval==native==wasm pinned by `polynum_mod_float{,_large,_neg}` |
| R5 — unguarded `sdiv/srem` | ✅ | divisor guarded pre-instruction (`emitIntDivZeroChecked`); i64 `INT_MIN/-1` structurally unreachable under V2 (63-bit payloads) |
| R5/N7 — `floatToInt` | ✅ **FIXED (#346/#372)** | saturates: `llvm.fptosi.sat.i64.f64` (native) / `i64.trunc_sat_f64_s` (wasm), each **clamped to the 63-bit Int bounds before tag/box** (the intrinsic saturates to i64 — out of domain). The status quo was worse than a wrong number: out-of-range `fptosi` poison was read back as a **live pointer**, so `floatToInt 1.0e19` printed an **ASLR-randomized address** (stable under `setarch -R`) — an address-disclosure primitive from safe surface. Pinned eval==native==wasm by `float_to_int_{nan,pos_inf,neg_inf,over,under,clamp_i64,trunc_pos,trunc_neg}` + `engine_value_pins` |
| V1–V3, V5 rep | ✅ | ratified + spike-proven (RUNTIME-DESIGN §8); fixtures throughout |
| V4/M2 — tag injectivity | ⚠ STATIC | ctor tags collision-free by construction (composite ordinals; reserved block guarded upstream by resolver `Duplicate constructor`); sentinel + dict-witness tags still raw djb2 with **no emit-time check** — **#348**; stale "real backend" comment — **#361** |
| V6 — reflective surface | ⚠ enumerated here | `mdk_value_eq` ✅ (IEEE eq), `mdk_value_cmp_raw` ✗ (NaN→EQ, #305/N6), `mdk_num_*` ✅ (Float `%` = fmod, #345 FIXED), `mdk_append` ✅, `mdk_print_num` ✅, `mdk_hash_float` LATENT (−0.0 hash≠eq; −0.0 unconstructible from source — `negate a = 0.0 - a` — trigger: `intBitsToFloat`) |
| DL1–DL3 dispatch | ✅ post-#203/#309 | uniform min⊑ elaboration; residuals #323/#324 (deep-nested overlap emit, wasm key sanitize) |
| N1 wrap / N2 div-mod / N3 literals | ✅ CONFIRMED | bare `add/sub/mul` (no nsw/nuw, grep-clean), `sdiv/srem` guarded, trap codes match eval; literal tag-width guard at 2^61 handled via full-width shl |
| N4 IEEE ops | ✅ | inline paths ✅ (`fadd…frem`, no fast-math); the runtime-dispatch Float `%` arm is now fmod on every engine (#345 FIXED) |
| N5 IEEE compare, uniformly | ⚠ | inline `fcmp o*`/`une` ✅ both backends; `nan <= nan` on global Floats CONFIRMED correct (the `RScalar` stamp covers it — a suspected divergence DISPROVED by probe); residual: the generic/HOF path, #305 |
| N6 total-order story | ✗ undecided | owner decision — **#360**; until then bar = engine uniformity |
| N7 conversions | ✅ **FIXED (#346/#372)** | `floatToInt` saturates (NaN→0, ±inf/range→`intMaxBound`/`intMinBound`), clamped to the 63-bit domain on both backends; `floor/ceil/round/trunc` ✅ (C library, Float→Float) |
| N8 know-don't-guess | ✗ STATIC (architectural) | five accreted recovery heuristics (`staticIsFloat`, two-pass `inferSigs` w/ mutated `sigs`, `bodyFloatRet`/`closureRetTyRef`, `RScalar`, `mainKind`) — umbrella **#353**; the `RScalar` stamp is the done-right model |
| N9 format/parse round-trip | ✅ CONFIRMED | shortest-round-trip lexeme (revised #57), `-0.0`/nan/inf pinned, `1e+300` re-lexes (#51 CLOSED; stale AGENTS.md row — #361); IR-text literal serialization round-trips via same formatter + `ensureFloatDot`; wasm JS-host copies UNVERIFIED — #361 |
| T1–T3 traps | ✅ | closed taxonomy in `medaka_rt.c` (panic/div/mod/oob/refute/nonexh + fault handler); codes match eval |
| S1/S2 tail calls | ✅ gated | `musttail` + TRMC; parity + coverage gates (`tmc_parity`, EXPECT-TMC pins — residual #224); TRMC Phase-2 population gaps documented in EMITTER-GAPS |
| M1 mangling injectivity | ✗ STATIC | `sanitizeId` separator-collapse breaks "impossible by construction" — **#347** (needs-repro) |
| D1 determinism | ✅ | knob-independence measured (PERF-RESULTS); goldens path-stable |
| D2/D3 fixpoint + seed | ✅ gated | `selfcompile_fixpoint` C3a/C3b; seed triple-free |
| D4 self-compile closure | ⚠ improving | the 2026-06-11 HashMap-in-emitter gap **no longer reproduces** (retested 2026-07-16: the exact shape, live in `isKnownFn`, passed the fixpoint C3a/C3b) — the ban is retired; residual ask: pin the shape as a fixture with the first shipped hash-container use so the capability cannot regress silently |
| Perf posture | ✗ STATIC | hot-path quadratics **#349–#352**; enforcement blind spot: no lower/emit stage in `perf_scaling` — **#359** |

---

## 10. How to read recurring emitter defects against this spec

- **"Garbage number, no error"** → N8 (a scalar-type guess went wrong) or V4
  (a tag aliased). Ask: *which fact did the emitter derive that the
  typechecker already knew?*
- **"Works in run, wrong in build"** → R1/R3; find the decision made twice
  (once per engine) and move it upstream of the fork.
- **"NaN does something weird"** → N5/N6; find which reflective helper (V6)
  re-implemented comparison.
- **"Crash under -O2 only"** → R5; UB (unguarded div, out-of-range fptosi,
  false `unreachable`) that -O0 happened to forgive.
- **"Fixpoint broke on a correct change"** → D2/D4; the emitter met a
  construct in its own source it cannot compile, or the seed is stale.
- **"One backend fixed"** → R2; the fix landed on one refinement of a shared
  law. The law lives here precisely so the fix has one home.
