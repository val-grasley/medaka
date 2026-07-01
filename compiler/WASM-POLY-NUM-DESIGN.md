# WASM-POLY-NUM-DESIGN — closing the wasm polymorphic-`Num` arithmetic gap

**Status:** DESIGN (read-mostly scoping). No emitter/runtime source changed — this doc
scopes the workstream that `SHARED-FLOAT-RESIDUAL-DESIGN.md` §4 deferred and its LOCKED
SCOPE named as the "SEPARATE next workstream after C". It is the **polymorphic** residual:
a `Num a`-constrained function applied to `Float` traps on WasmGC (`ref.cast` illegal cast),
while native runs it correctly. Approach C (just landed) covers the **monomorphic** concrete-Float
cases; this doc is the **polymorphic** case C cannot reach (no concrete Float to stamp at the
definition site — the operand's type is only known via runtime dispatch).

Reproduced at **BASE_OK** (`git merge-base --is-ancestor ed3c5a6 HEAD` = true; worktree already
up to date with main), native build green (`make medaka`, OCaml-free), wasm toolchain live
(`wasm-tools` on PATH, Node **v24.17.0** via nvm, mirroring `test/wasm/diff_wasm.sh`). Probes in
scratchpad; oracle = native-compiled binary (`medaka build --allow-internal f -o b && ./b`),
wasm = `test/bin/wasm_emit_main f | wasm-tools parse | node test/wasm/run.js`.

---

## 1. Empirical table — which polymorphic-`Num` shapes trap on wasm vs work

"native bare" = the value-`main` as written (auto-print). "native anchored" = wrapped through a
`Float -> Float` identity to isolate the *arithmetic* from the separate auto-print type-loss.
Verbatim wasm error is `instantiate failed: illegal cast` in every trap row.

| # | probe | shape | native (bare / anchored) | wasm | verdict |
|---|-------|-------|--------------------------|------|---------|
| 1 | `sq x = x*x; sq 2.5` | no-sig, inferred `Num a` @ **Float** | `6.25` ✓ | **TRAP** illegal cast | **wasm-only gap** |
| 2 | `sq x = x*x; sq 3` | no-sig `Num a` @ **Int** | `9` ✓ | `9` ✓ | both work (Int is default) |
| 3 | `sq : Num a => a -> a; sq 2.5` | **explicit `Num a =>` sig** @ Float | `6.25` ✓ | **TRAP** | wasm-only; explicit dict sig does **not** help wasm |
| 4 | `sq : Num a => a -> a; sq 3` | explicit sig @ Int | `9` ✓ | `9` ✓ | both work |
| 5 | `addSelf z = z+z; addSelf 4.5` | `+` on `Num a` @ Float | `9.0` ✓ | **TRAP** | wasm-only gap |
| 6 | self-contained fold, float acc: `myFold (acc x=>acc+x) 0.0 [1.5,2.5,3.0]` | poly lambda accumulator @ Float | bare `2187841424` (auto-print garbage) / **`6.0` ✓ anchored** | **TRAP** | native arith **correct** via dict; wasm TRAP |
| 7 | same fold, int acc: `myFold (…) 0 [1,2,3]` | @ Int | `6` ✓ | `6` ✓ | both work |
| 8 | `sq (identity 3.0)` — poly-Num fn on a poly-HOF-hidden Float | @ Float via erased HOF | `9.0` ✓ | **TRAP** | wasm-only (was §4 #12) |
| — | control `sq 2.0 + 3.0`-style literal binop main | concrete Float literal | `5.0` ✓ | `5.0` ✓ | works (approach-C / structural anchor) |
| S | **sibling:** `myMax a b = if a>b then a else b; myMax 3.5 7.5` | poly **`Ord`** compare @ Float | bare garbage / **`7.5` ✓ anchored** | **TRAP** illegal cast | same class — see §2.4 |

**Boundary — precisely bounded:**
- **Int instantiations of every polymorphic-`Num` shape WORK on wasm** (rows 2, 4, 7). Int is the
  representation the fallback path already assumes.
- **Float instantiations TRAP** (rows 1, 3, 5, 6, 8) — uniformly `ref.cast` illegal cast at module
  instantiate. Native runs all of them correctly.
- An **explicit `Num a =>` signature does not rescue wasm** (row 3 traps identically to row 1): the
  dict is not threaded into arithmetic on wasm (§2.2).
- Not part of this gap (excluded from the table as noise): in the **single-file** wasm entry path,
  a probe that calls a *prelude* HOF (`fold`, `fromInt`) emits `wasm_emit gap — ref-mode: unbound
  variable 'fold'`. That is a separate single-file-entry linkage limitation (the prelude isn't
  linked into a bare single-file wasm module), **not** the arithmetic gap — reproduced above with
  a *self-contained* `myFold` (rows 6/7) to avoid it.

---

## 2. Root cause

### 2.1 Wasm arithmetic is a static inline primitive, never dispatched
`CBinPrim op l r tag` lowers at `wasm_emit.mdk:3317` to `emitBinRef` (`wasm_emit.mdk:3589`), which
commits **statically**:

```
if isArithOrCmp op && (tag == "Float" || cexprIsFloat prog env l || cexprIsFloat prog env r)
  then emitFloatBinRef …        -- f64 path
  else  … "call $mdk_unbox_int" … wasmBinOp64 op … "call $mdk_box_int"   -- INT path (the fallback)
```

`tag` is the approach-C typecheck-stamped scalar (`"Float"`/`"Int"`); `cexprIsFloat`
(`wasm_emit.mdk:3667`) is a purely **structural** detector (Float literal, `pi`/`e`, a float local,
a Float-returning extern, nested float binop). A **polymorphic** operand (`Num a`, type known only
at runtime) has **no** stamp and is not structurally Float → it takes the **int fallback**.

### 2.2 The int fallback traps on a boxed Float
The int path calls `$mdk_unbox_int` (`wasm_preamble.mdk`):

```
(func $mdk_unbox_int (param $v (ref eq)) (result i64)
  (if (ref.test (ref i31) (local.get $v))
    (then (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) …))))
    (else (struct.get $boxint 0 (ref.cast (ref $boxint) …)))))   ;; ← traps
```

A Float is a boxed `(type $float (sub (struct (field f64))))`. It is **not** an i31, so it falls to
the `else` and `ref.cast (ref $boxint)` on a `$float` struct → **illegal cast** at instantiate.
That is every trap row in §1.

### 2.3 Wasm HAS dicts — but `+`/`*` are not method calls on either backend
Wasm **does** represent typeclass dictionaries (the §W5 block, `wasm_emit.mdk:2602-2710`): a witness
is an **i31 carrying `hashName(tag)`**, nested `requires`-dicts are `$dictcell`
(`(struct (field i32) (field (ref $dictarr)))`, `wasm_emit.mdk:1817`), and `emitMethodRef`/
`emitMethodDispatchRef` prepend dict-words and if-chain over impl tags — the faithful peer of
native's `emitMethod`/`emitDictApp`/`dictWordsOf`. So Eq/Ord/Show/user methods **are** dict-passed on
wasm. **Arithmetic is simply not a method** — `+`/`*` are the inline `CBinPrim` primitive above, so
they never reach the dict machinery. The Num dict is not threaded because arithmetic never asks for one.

Crucially, **native's "Num dict" is not a dictionary of function pointers either** — it is a
**runtime low-bit value-tag discriminator** in the C runtime (`runtime/medaka_rt.c`):

```
static inline int mdk_is_int(long long w){ return (w & 1) != 0; }
long long mdk_num_add(long long l, long long r){
  if (mdk_is_int(l)) return (((l>>1)+(r>>1))<<1)|1;      // odd immediate = Int
  return mdk_box_float(((double*)l)[1] + ((double*)r)[1]); // even pointer = boxed Float
}
```

Native emits `call @mdk_num_add/sub/mul/…` whenever the operand `LTy` is `LTNum` — the tag it seeds
onto a **polymorphic-`Num` param** (a param whose declared type head is a bare tyvar used
arithmetically: `numPolySeed`/`isNumPolyParam`, `llvm_emit.mdk:7435-7444`; emitted in `emitArithW`,
`llvm_emit.mdk:2325-2356`). So **native already resolves this gap by runtime value-tag dispatch** —
exactly the mechanism wasm is missing. Wasm has no `LTNum`-equivalent and no `$mdk_value_add`.

### 2.4 The `Ord` comparison sibling (row S) is the same gap, already half-built
Comparison operators on wasm already route through a **runtime value-dispatch** helper
`$mdk_value_cmp` (`emitValueCmpRef`, `wasm_emit.mdk:3615-3624`; body in `wasm_preamble.mdk`) — the
*exact* shape approach A wants for arithmetic. But `$mdk_value_cmp` has a `$str` arm and an Int arm
**and no `$float` arm** — it calls `$mdk_unbox_int`, so it **also traps** on a polymorphic Float
compare (row S: `myMax 3.5 7.5` → illegal cast on wasm; native anchored = `7.5` ✓). So the runtime-
value-dispatch *pattern* already exists on wasm and is Float-incomplete in the identical way.

### 2.5 No monomorphization pass exists anywhere
Searches for `monomorph`/`specialize` across `compiler/**` find only Maranget pattern-matrix
specialization (`core_ir_lower.mdk:400` `specializeCon`) and interface-default copying
(`desugar.mdk` `fill_impl_defaults`) — **no type-level monomorphization**. Core IR is explicitly
type-erased (`wasm_emit.mdk:3572`). Approach B would be greenfield.

---

## 3. Approach A vs B

### (A) Runtime value-dispatch arithmetic — a wasm `$mdk_value_add`
Mirror native's `mdk_num_*`: add wasm-runtime helpers `$mdk_value_add/sub/mul/div/mod` in
`wasm_preamble.mdk` that inspect the operand's runtime shape and branch — modelled directly on the
existing `$mdk_value_cmp`:

```
(func $mdk_value_mul (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))
  (if (ref.test (ref $float) (local.get $a))            ;; float path
    (then (return (struct.new $float
             (f64.mul (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))
                      (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))
  ;; else int path (i31 / $boxint), reusing $mdk_unbox_int + $mdk_box_int
  (call $mdk_box_int (i64.mul (call $mdk_unbox_int (local.get $a))
                              (call $mdk_unbox_int (local.get $b)))))
```

Then route `emitBinRef` to these helpers **for the polymorphic-`Num` operand case** instead of the
trapping int fallback. **Value tag-inspectability is already proven** — `$float`, `$boxint`, and i31
are distinct GC types the backend already `ref.test`s throughout (§2.2, `$mdk_value_cmp`,
`$mdk_unbox_int`), so no representation change is needed.

Two variants of the emitter half:
- **A-surgical (recommended):** route to `$mdk_value_add` **only** when the operand is a
  polymorphic-`Num` value — port native's `isNumPolyParam`/`numPolySeed` detection to wasm (a
  bare-tyvar `Num`-constrained param used arithmetically). Statically-Int arithmetic stays on the
  fast inline int path; only the previously-trapping poly case changes. Native-faithful; no int-path
  perf regression.
- **A-blanket (cheaper to land, has a cost):** simply change the int **fallback** in `emitBinRef`
  from the trapping inline path to `$mdk_value_add`. Trivial (one call-site swap + the helpers), and
  sound for every case — but it pushes **all** not-statically-Float arithmetic (a large fraction of
  int ops) through two extra `ref.test`s, a real hot-path perf hit. Not recommended as the endpoint;
  usable as a first correctness landing if the poly-Num detection balloons.

**Fixes:** rows 1, 3, 5, 6, 8 (all polymorphic-`Num`-on-Float). With the trivially-parallel `$float`
arm added to `$mdk_value_cmp`, also closes the `Ord` sibling (row S) — recommended to bundle.
**Change surface:** `wasm_preamble.mdk` (5 arith helpers + 1 `$mdk_value_cmp` arm) + `wasm_emit.mdk`
(`emitBinRef` routing + poly-Num detection for A-surgical). **No native change, no shared Core-IR /
typecheck / lowering change** — functionally wasm-only. **Tag-inspectable? YES** (already used).
**Effort: A-blanket S; A-surgical S–M** (the poly-Num detection port is the only non-trivial part).

### (B) Monomorphization — specialize `Num a` functions per concrete instantiation
A new compile-time pass that clones each `Num a`-polymorphic function per concrete type used at its
call sites (`sq@Float`, `sq@Int`), giving each clone a static scalar type → feeds the existing
approach-C float path, no runtime dispatch. **No such pass exists** (§2.5); Core IR has already
**erased** the instantiation types, so the pass must recover them from typecheck / call-site
inference and thread specialized bodies through `core_ir_lower` into **both** backends.
- **Fixes:** rows 1–8 on both backends via static tags; eliminates runtime arithmetic dispatch.
- **Strategic bonus:** monomorphization is the **long-deferred backend lever** in
  `project_backend_dispatch_strategy` / AGENTS.md Gotchas — it would also shrink the *un-prunable
  instance surface* (the "DCE keeps every `DImpl` whole" cost, ~+34 KB / ~+5% per stdlib import) that
  currently blocks instance-level DCE. So B pays off well beyond this one gap.
- **Change surface:** a new IR pass + typecheck instantiation-type capture + **shared** `core_ir`
  lowering + both backends. **Not wasm-only.** High blast radius; touches the native self-compile
  closure heavily.
- **Tractability:** hard on a type-erased Core IR — you must re-thread the erased instantiation types,
  handle polymorphic recursion / higher-rank / dict-carrying call sites, and bound clone explosion.
  **Effort: XL** (multi-session, its own design + risk register). Out of scope for closing one gap.

### Interaction with the deferred instance-DCE item
A is orthogonal to instance-DCE — it neither helps nor blocks it. B **is** the instance-DCE
enabler. So the honest framing: A closes *this* gap cheaply and wasm-locally; B is a strategic
program you'd undertake for the DCE/monomorphization roadmap, of which this gap is a minor
beneficiary, not the driver.

---

## 4. Recommendation + GO / NO-GO

**GO on approach A (A-surgical), scoped wasm-only, bundling the `$mdk_value_cmp` `$float` arm.**

Rationale:
- A is the **direct wasm port of native's already-shipping mechanism** (`mdk_num_*` value-tag
  dispatch) onto a representation that is **already tag-inspectable** and already has the precedent
  helper (`$mdk_value_cmp`). It is low-risk and **S–M**.
- It converts every trap row (1, 3, 5, 6, 8, and sibling S) from "module fails to instantiate" into
  a correct result, restoring native↔wasm parity for hand-written generic numeric code (sum /
  average / dot-product / `sq` over Float without a concrete-Float signature anchor) — the realistic
  win now that approach C covers the monomorphic concrete-Float cases.
- It is **functionally wasm-only** (no native/shared-lowering edit), so it does not perturb native
  codegen or the LLVM self-compile *logic*; the only re-mint is the mechanical one below.

**NO-GO / defer approach B (monomorphization).** It is XL, greenfield on a type-erased IR, and
cross-cutting. It is worth doing **for the instance-DCE roadmap**, not to close this gap — this gap
is a cheap A-fix. Recommend: **A now; B someday, decided on the DCE/monomorphization agenda, not
here.**

**Is the gap worth closing at all?** Yes, modestly. After approach C the residual is exactly
"polymorphic-`Num` value whose concrete type reaches it only at runtime, run on wasm" — i.e. any
generic numeric routine over Float without a `Float` signature/literal anchor. On native it already
works for free; the native↔wasm asymmetry is a real correctness cliff (instantiate-time trap, not a
wrong number) for the wasm numeric / playground / SQLite-aggregate track. If that track is live, GO.
If no wasm numeric consumer is pending, A is small enough to land opportunistically but is not urgent.

---

## 5. Staged plan (if GO on A)

Re-mint note: `wasm_emit.mdk` and `wasm_preamble.mdk` are compiled into the `medaka` binary (the
`build --target wasm` subcommand), so any source change there perturbs the self-compiled
`medaka_cli.ll` and requires a **seed re-mint + `selfcompile_fixpoint` re-validation** — but only
*mechanically* (the new code is wasm-only paths never exercised when the LLVM emitter compiles the
compiler, so it is deterministic/low-risk, not a correctness fork). Batch the re-mint once at the
end per `feedback_defer_seed_remint`. No `typecheck`/`core_ir`/`ast` change ⇒ no native codegen
behavior change, no golden recapture beyond wasm.

| stage | change | files | gate | model |
|-------|--------|-------|------|-------|
| A0 | Add `$mdk_value_add/sub/mul/div/mod` runtime helpers (mirror `$mdk_value_cmp` + `mdk_num_*`: `ref.test $float` → f64 op + `struct.new $float`; else i31/`$boxint` int path). No emitter change yet — helpers unused, module still validates. | `wasm_preamble.mdk` | `wasm-tools validate` on any fixture still green | Sonnet |
| A1 | Port poly-`Num` operand detection to wasm (mirror native `isNumPolyParam`/`numPolySeed`): a binop operand that is a bare-tyvar `Num`-constrained param used arithmetically. Route those operands in `emitBinRef` to `$mdk_value_*` instead of the trapping int fallback; leave the static Int/Float fast paths untouched. | `wasm_emit.mdk` | new wasm fixtures rows 1/3/5/6/8 wasm==native; `diff_wasm.sh` + `diff_sqlite.sh` green (no int-path regression) | Sonnet (Opus if the detection needs typecheck plumbing) |
| A2 *(bundle)* | Add a `$float` arm to `$mdk_value_cmp` (`ref.test $float` → f64 compare → −1/0/1) to close the `Ord` sibling (row S). | `wasm_preamble.mdk` | new wasm fixture row S wasm==native | Sonnet |
| A3 | Rebuild `test/bin/wasm_emit_main` (`test/wasm/build_wasm_oracle.sh`); full `diff_wasm.sh` / `diff_wasm_modules.sh` / `diff_wasm_typed.sh` / `diff_sqlite.sh`. | — | all wasm gates green | Sonnet |
| RM | **Seed re-mint once** (`medaka_emitter` → `compiler/seed/emitter.ll.gz`); verify `selfcompile_fixpoint` C3a/C3b + cold `bootstrap_from_seed`. | seed | fixpoint + cold bootstrap green | orchestrator |

Fixtures land in `test/wasm/fixtures/` with captured native-oracle goldens per §"Writing tests".

---

## 6. Forks needing a human decision

1. **A vs B.** Recommend **A** (wasm-local, S–M, native-faithful value-tag dispatch). B
   (monomorphization) is XL greenfield and belongs to the instance-DCE roadmap, not this gap — defer.
2. **A-surgical vs A-blanket.** Recommend **A-surgical** (route only poly-`Num` operands; keeps the
   fast int path) despite the small extra detection work. A-blanket (swap the whole int fallback to
   value-dispatch) is a one-line correctness landing but taxes every non-static int op with two
   `ref.test`s — acceptable only as a stepping stone, not the endpoint.
3. **Bundle the `Ord` sibling (row S) or not.** The `$mdk_value_cmp` `$float` arm is a ~5-line
   parallel fix that closes an identical-class trap (poly `Ord` compare on Float). Recommend
   bundling — same test infra, same re-mint.
4. **Is it worth the re-mint churn now?** A is a single wasm-only re-mint unit. If a wasm numeric
   consumer (playground/SQLite aggregates/generic Float reductions) is on the near roadmap, GO. If
   not, A is cheap enough to land opportunistically but non-urgent — document in `EMITTER-GAPS.md`
   and fold into the next wasm re-mint batch rather than a standalone cycle.

---

## LOCKED SCOPE (orchestrator + user decision, 2026-06-30)

**GO on approach A (runtime value-dispatch), A-surgical, bundle the Ord-compare sibling. Defer B (monomorphization).** Forks: (1) **A** not B — B is XL greenfield + is really the instance-DCE/monomorphization roadmap item, not this gap's driver; (2) **A-surgical** — port native's `isNumPolyParam` poly-Num operand detection so the fast static int/float path is unchanged (NOT A-blanket, which taxes the hot int path); (3) **bundle** the `$mdk_value_cmp` `$float` arm (poly `Ord`-on-Float traps identically, ~5 lines); (4) GO now — near consumers exist (SQLite aggregates / Float reductions / playground).

**Plan (one cohesive change — all `compiler/backend/wasm_emit.mdk` + `wasm_preamble.mdk`, wasm-only):**
- **A0** — `$mdk_value_add/sub/mul/div/mod` runtime helpers in `wasm_preamble.mdk`, mirroring native `mdk_num_*` + the existing `$mdk_value_cmp` (runtime `ref.test` on `i31`/`$boxint`/`$float` → int or f64 arith → rebox).
- **A1** — `emitBinRef`: detect a POLYMORPHIC `Num`-operand (port native's `isNumPolyParam`; the operand has neither a static Float scalar-tag from approach C nor a structural Float shape, but IS a Num-constrained param) → route to the `$mdk_value_*` helper instead of the static int primitive. Static/monomorphic cases (incl. approach-C Float-tagged) keep the fast path.
- **A2** — add the `$float` arm to `$mdk_value_cmp` so poly `Ord`-on-Float works (the sibling).
- **A3** — gates: poly-Num-on-Float + poly-Ord-on-Float fixtures wasm==native; `diff_wasm`/`diff_wasm_modules`/`diff_sqlite` green.
- **Re-mint:** VERIFY `selfcompile_fixpoint` against the COMMITTED seed first (per the C-core lesson — a wasm_emit/preamble change may NOT perturb the seed if the seed-minting entry doesn't reach it; the prior wasm stages needed none). Re-mint ONLY if C3a fails against the committed seed.

**Deferred:** B (monomorphization) — tracked as the separate instance-DCE/backend-dispatch roadmap item (`project_backend_dispatch_strategy`), not this gap.
