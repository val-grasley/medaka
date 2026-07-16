# SHARED-FLOAT-RESIDUAL-DESIGN — the signature-free type-lost-Float residual

**Status:** IMPLEMENTED — approach C shipped `f3d4f71d` (C-core) + `27969e7f` (C3 wasm
wiring), 2026-06-30. Confirmed by `compiler/EMITTER-GAPS.md`'s closing note ("Float on
WasmGC is CLOSED"). C4 (bare-Float-main auto-print) was planned as a DEFERRED follow-up
(§6/§7 below) but is now fixed-or-mooted rather than open (#361, re-probed 2026-07-16):
`main = fold (acc x => acc + x) 0.0 [1.0, 2.0, 3.0]` — bug #1 in the table below, which
this doc's own capture recorded as `2187642768` (garbage) on native — now builds and
auto-prints `6.0` correctly (`medaka build … && ./…` on the current binary). Whichever
later change closed it, C4's specific proposed implementation (a dedicated `Ref String`
main-type stamp) was never separately built; the outcome it targeted is simply no longer
reproducible. Separately, `medaka run` on the same bare-Float-main source now REJECTS it
with a clean diagnostic ("'main' must be a value of type Unit…") rather than printing
anything — a deliberate `run`-vs-`build` CLI/UX asymmetry, not a regression; see
`compiler/entries/eval_autoprint_main.mdk`'s header for where that asymmetry is pinned
for the 3-engine differential gate.

Original header (predates the fix): **Status:** DESIGN (read-mostly scoping). No emitter/lib source changed. This doc
scopes the residual left after the two signature-driven fixes closed the anchored
cases: the native "arith on type-lost floats" arc (`project_arith_on_typelost_floats_bug`,
7 fixes 2026-06-18) and the wasm W-SQLITE-4 stages 1-2 (`WASM-FLOAT-TYPING-DESIGN.md`,
`floatRetFnsRef`/`floatParamsRef`/`ctorFloatFieldsRef` — **verified landed in this
worktree: 7 source markers, `sq : Float -> Float` works on wasm**).

Reproduced at BASE_OK (`git merge-base --is-ancestor 2d321af HEAD` = true), native
build green, wasm oracle rebuilt (`test/wasm/build_wasm_oracle.sh`), Node v24.17.0,
`wasm-tools` on PATH. Probes in scratchpad.

**Oracle for auto-print** = the native-compiled binary (`medaka build f -o b && ./b`,
value-mains auto-print). For each probe I distinguish two things the task's premise
conflated:
- **ARITHMETIC correctness** — does the Float math produce the right bits? Isolated
  by piping the result through a `Float`-signed identity `fid : Float -> Float`, which
  anchors both the arithmetic (native LTy) and the auto-print.
- **AUTO-PRINT** — does a *bare* value-`main` (no anchor) render the Float correctly?
  A separate decision point (`refMainKind`/`mainKind`) that is type-lost independently
  of the arithmetic.

---

## 1. Empirical table — arithmetic vs auto-print, per backend

`aXX` = wrong/garbage (non-deterministic pointer-bits reinterpreted as int/float).
"native bare" = value-`main` as written; "native anchored" = wrapped in `fid`.

| # | case | probe | native **bare** | native **anchored** (arith) | wasm | verdict |
|---|------|-------|-----------------|------------------------------|------|---------|
| 1 | prelude `fold` accumulator | `main = fold (acc x => acc+x) 0.0 [1.0,2.0,3.0]` | `2187642768` (garbage) | **6.0 ✓** | *emit-gap: `fold` unbound in single-file wasm entry* → tested as #5 | native: AUTO-PRINT only; wasm: see #5 |
| 2 | `foldRight` accumulator | `foldRight (x acc => x+acc) 0.0 …` | garbage | **6.0 ✓** | (same fold-unbound gap) | native: AUTO-PRINT only |
| 3 | user HOF wrapping fold | `applyAcc f s xs = fold f s xs; applyAcc (acc x=>acc+x) 0.0 …` | garbage | **6.0 ✓** | (same) | native: AUTO-PRINT only |
| 4 | map then fold | `fold (…) 0.0 (map (x=>x+x) […])` | garbage | **12.0 ✓** | (same) | native: AUTO-PRINT only |
| 5 | **self-contained fold** accumulator | `myFold f acc xs = match xs …; myFold (acc x=>acc+x) 0.0 […]` | garbage | **6.0 ✓** | **TRAP** illegal cast (bare & anchored) | **native: AUTO-PRINT only; wasm: real arith TRAP** |
| 6 | tuple-destructured Float | `addPair p = match p ((a,b)=>a+b); addPair (1.5,2.5)` | garbage | **4.0 ✓** | **TRAP** | **native: AUTO-PRINT only; wasm: real arith TRAP** |
| 7 | tuple via inline lambda | `addPair = ((a,b)=>a+b); addPair (1.5,2.5)` | garbage | **4.0 ✓** | **TRAP** | same as #6 |
| 8 | let-bound **literal** | `let y = 2.5; y + y` | — | **5.0 ✓** | **TRAP** | **wasm-only** (native correct) |
| 9 | let-bound from **poly HOF** | `let y = identity 2.5; y + y` | garbage | **`a2.9e+48` (WRONG)** | **TRAP** | **SHARED real arith bug** |
| 10 | let-bound poly HOF, one literal operand | `let y = identity 2.5; y + 0.0` | `2.5 ✓` | `2.5 ✓` | `2.5 ✓` | already-ok (literal anchors) |
| 11 | fold, seed+elements all hidden by `identity` | `myFold (acc x=>acc+x) (identity 0.0) [identity 1.0, identity 2.0]` | — | **3.0 ✓** | (fold-unbound) | native correct (dict-dispatch) |
| 12 | poly-Num fn applied to hidden Float | `sq x = x*x; sq (identity 3.0)` | — | **9.0 ✓** | **TRAP** | **wasm-only, OUT OF SCOPE** (see §4) |
| 13 | poly-Num `z+z` applied to hidden Float | `addSelf z = z+z; addSelf (identity 3.0)` | — | **6.0 ✓** | **TRAP** | **wasm-only, OUT OF SCOPE** |
| — | control: bare Float binop main | `main = 2.0 + 3.0` | `5.0 ✓` | — | ✓ | works (literal-anchored) |
| — | control: no-sig `sq x=x*x; sq 3.0` | `9.0 ✓` | — | **TRAP** | native ok / wasm out-of-scope |

**The premise correction that drives everything below:** for the fold accumulator and
tuple cases (#1–7), **native arithmetic is already CORRECT** — the bare-main garbage is
pure AUTO-PRINT type-loss, not a miscompile. The one case where **native arithmetic is
genuinely wrong** is #9 (`let y = identity 2.5; y + y`). So the *shared, genuinely-broken*
arithmetic set is **exactly #9** (a monomorphic concrete-Float binop whose operands trace
only to a polymorphic-HOF-bound let-binder, with no literal / Float-sig / field / list-literal
anchor). Everything else the task grouped as "shared" is either native-AUTO-PRINT-only or
wasm-only.

---

## 2. Root cause

### Why native gets #1–7 right but #9 wrong — the dict-vs-primitive fork
Medaka arithmetic has **two** codegen paths:
- **Polymorphic / Num-constrained** operators (inside a *generalized* function, or an
  *inline lambda* whose param is `Num a`) dispatch through the **runtime Num dict** — the
  `Num Float` dict's `add`/`mul` handle Float correctly regardless of erasure. This is why
  #1–5 (fold accumulator lambda), #11 (all-hidden), #12–13 (poly-Num fns) are all correct
  on native: the `+`/`*` is polymorphic and dict-routed.
- **Monomorphic concrete-Float** operators (operands have a *ground* `Float` type, no dict)
  emit a **direct primitive** whose int-vs-float choice depends on the emitter recovering the
  operand `LTy`. This is the type-lost path. When the operand `LTy` can't be recovered it
  defaults to `LTInt` → integer op on a boxed-Float word → garbage.

Case #9 is the minimal *monomorphic concrete-Float* site with no anchor: `let y = identity 2.5`
gives `y` a ground `Float` type (value-restricted, monomorphic), so `y + y` is a *direct
primitive* `+`, not dict-routed. And its operand `LTy` is `LTInt` because:

- `emitLet` (`llvm_emit.mdk:2542`) types the binder from `emitExpr` of the RHS.
- `staticIsFloat` (`llvm_emit.mdk:2136`) sees only a literal / already-`LTFloat` local / arith —
  **not through a call**, so `identity 2.5` is not float.
- the `CApp` result LTy comes from `indirectRetTy`→`indirectResultTy` (`llvm_emit.mdk:3010–3024`),
  which returns `LTInt` unless `closureRetTyRef` recorded the callee — and `recordFloatRet`
  (`2174`) only fires when `bodyFloatRet` (a *structural* body scan, `2152`) proves the body
  evidently returns Float. `identity`'s body is `CVar x` with no float evidence → `LTInt`.

### Why wasm is far broader (#5–9, #12–13 all TRAP)
Wasm has **no dict-dispatched arithmetic path**. `emitBinRef` (`wasm_emit.mdk:~3518`) commits
*statically*: `cexprIsFloat` (`wasm_emit.mdk:3667`, structural-only, same blind spot as
native's `staticIsFloat`) or the sig registries → float path; otherwise **int path** →
`mdk_unbox_int` (`i31.get_s`) on a `$float` box → **runtime `ref.cast` trap at instantiate**.
So wasm traps on *anything* Float that isn't structurally/sig-detectable, **including ordinary
polymorphic-Num arithmetic** (#12–13) that native handles for free via dicts. That is a
distinct, larger wasm architectural gap (§4), not the "type-lost" residual.

### Auto-print (native #1–4 bare garbage)
`refMainKind` (`wasm_emit.mdk:2126` and native's `mainKind`) picks the print formatter from the
`main` expression's *structural* kind. `main = fold (…) 0.0 xs` is a `CApp` to a polymorphic-return
fn; the return LTy is unresolvable → defaults to Int-kind → prints the boxed-Float word as an int.
Independent of the arithmetic being correct. (`main = 2.0 + 3.0` prints `5.0` because the `CBinPrim`
result is structurally Float.)

---

## 3. Approach comparison

Three approaches. The task named A and B; **C is a cheaper variant of B** that the seam study
surfaced (reuse the `EBinOp` ref + the existing deferred-stamp infra) — included because it
dominates B on cost for the same coverage.

### (A) Targeted fold seed→accumulator propagation
Propagate a fold-family HOF's seed-arg type to the lambda's accumulator param at emit time.
- **Fixes:** #1–5 on wasm (fold accumulator). **On native these already work** — A is a
  wasm-only patch for a case native handles via dicts.
- **Misses:** #6–7 (tuple), #9 (the genuinely-shared bug), #12–13.
- **Change surface:** wasm `emitBinRef`/seeding only (native no-op). Fold-family hardcoded list.
- **Verdict:** narrow, non-general, doesn't touch the one genuinely-broken shared case (#9).
  **Effort: wasm S. Not recommended as the primary fix.**

### (B) Binder scalar-type stamp from the typechecker
The typechecker stamps a `"Float"`/`"Int"` tag onto **let / lambda / match binders** (a new
`Ref String` on `ELet`/`ELam`/`LetBind` or `Pat`), threaded through `core_ir_lower` into a new
field on `CLet`/`CLam`/`CClause`, read by both emitters.
- **Type-availability (the crux): CHEAP and well-precedented.** The inferred binder mono is in
  hand at `inferLetSimple` (`typecheck.mdk:4417`, already calls `recordLocalBind x t1`,
  `1475`), `inferLam` (`4368`), `inferArm` (`4559`). Reuse the deferred `resolveBinopSites`-style
  post-pass (`typecheck.mdk:5131`) to zonk after HOF results ground (needed for #9's late
  grounding). `fieldNameToLTy` (`llvm_emit.mdk:481`) already turns `"Float"`→`LTFloat`; wasm's
  `cexprIsFloat` gets one new arm. Emitter-consumption end is trivial.
- **Plumbing (the real cost): EXPENSIVE.** Unlike `EFieldAccess`/`EIndex` (born with their ref),
  binders carry **no ref today**. A new field on `ELet`/`ELam`/`LetBind` (or `Pat`) ripples
  through parser, sexp/astdump lockstep, printer, resolve, desugar, eval, **and** a new field on
  `CLet`/`CLam`/`CClause` (`core_ir.mdk:61/63/190`) threaded through every `core_ir_lower` map
  (`98–100`, `427–431`) + DCE/sexp/eval consumers.
- **Fixes:** #6–9 on both backends (all *monomorphic concrete-Float* binders). **Bonus over C:**
  a stamped binder is Float at *every* use, so it could also feed an auto-print fix and
  non-binop uses.
- **Misses:** #12–13 (binder is genuinely `Num a`-polymorphic at its definition — no concrete
  Float to stamp; needs dicts, §4).
- **Effort: typecheck M, lowering M, native emit S, wasm emit S, plus two-IR field plumbing M.
  Overall M–L.**

### (C) Arithmetic-binop scalar-type stamp *(recommended)*
Stamp the **arithmetic `EBinOp` site** with its resolved scalar type, reusing the existing
`EBinOp … (Ref Route)` (`ast.mdk:136`) and the existing `pendingBinopSites` deferred-stamp
mechanism (`typecheck.mdk:1327`) that already stamps *comparison* operators post-inference.
Extend `Route` with a scalar variant (e.g. `RScalar "Float"`) — or a parallel tag — stamped
**only when the operand grounds to a concrete primitive** `Float`/`Int` (exactly the guard
`resolveBinopSites` already uses: stamp only when grounded, else leave `RNone` for the
dict/structural path). Carry the tag through `lowerBinop` (`core_ir_lower.mdk:103`, currently
**drops** the route `_`) into a new field on `CBinPrim` (`core_ir.mdk:81`), read at the emit
decision point (`emitBin`, `llvm_emit.mdk:2069`; `emitBinRef`, `wasm_emit.mdk:~3518`).
- **Why it covers the same set as B:** the type-lost miscompile is *always decided at the binop*
  (that's where int-vs-float is chosen). #6, #7, #9 are all binops on concrete-Float operands →
  stamped Float → both emitters emit the float path. #8 (let-literal) too.
- **Why it's cheaper than B:** **no new AST binder field** (reuse `EBinOp`'s ref; no
  parser/resolve/desugar/eval binder churn) and **no `CLet`/`CLam`/`CClause` changes** — only
  one new `CBinPrim` field + `lowerBinop` reading the already-present route. The decision point
  IS the node being stamped.
- **Doesn't regress dicts:** a polymorphic `Num a` binop stays ungrounded → unstamped → current
  dict/structural path (native #12–13 stay dict-correct; wasm #12–13 stay trapping, unchanged).
- **Misses:** #12–13 (§4, out of scope for either B or C) and does **not** by itself fix
  auto-print (#1–4 bare) — that's a separate `refMainKind`/`mainKind` fix (main-expr result-type
  stamp), a tiny orthogonal add.
- **Effort: typecheck S–M (extend existing binop-site infra to arithmetic), lowering S (one
  `CBinPrim` field + read the route), native emit S, wasm emit S. Overall S–M.**

---

## 4. Explicitly out of scope: wasm polymorphic-Num arithmetic (#12–13)

`sq x = x*x` / `addSelf z = z+z` applied to a Float TRAP on wasm but are correct on native.
Root: at the *definition* site the operand is `Num a` (polymorphic) — there is no concrete Float
to stamp, so **neither B nor C reaches it**. Native survives via runtime dict-dispatch; **wasm
has no dict-dispatched arithmetic path at all**. Closing this requires giving wasm a
runtime-dispatched arithmetic path (a `$mdk_value_add` analogous to the existing
`$mdk_value_cmp` that comparisons already use) or monomorphization — a **separate, larger wasm
workstream**, not part of the type-lost-Float residual. Flag it in `EMITTER-GAPS.md` as its own
item. (It means: even after B/C, a hand-written generic `sum`/`average` over Float still traps on
wasm unless it carries a `Float` signature.)

---

## 5. Recommendation + GO / NO-GO

**The genuinely-shared arithmetic bug is a single narrow corner (#9).** Native handles every
*realistic* Float pattern already (dict-dispatch + LTy); wasm's broad trapping is mostly the
separate §4 gap plus the monomorphic-erased corner.

**Recommendation: conditional GO on approach C (arithmetic-binop stamp), scoped to the
monomorphic concrete-Float residual — NOT B.** Rationale:
- C closes the *entire realistic monomorphic residual* (#6–9) on **both** backends from **one
  upstream source** (typecheck stamp + lower + two trivial emit reads), symmetric by construction.
- C reuses the exact infra that already exists for comparison operators (`pendingBinopSites` +
  `resolveBinopSites` + `EBinOp`'s ref), so it is **S–M**, materially cheaper than B (M–L) for
  the **same realistic coverage**. B's only advantage — a binder that's Float at every use —
  buys the auto-print and non-binop uses, which are better served by a separate tiny
  `refMainKind` stamp.
- A is a wasm-only fold patch that ignores #9; reject as the primary fix.

**NO-GO / defer** the §4 wasm polymorphic-Num arithmetic gap — bigger, distinct, and native is
already correct there. Document it, don't bundle it.

**Is closing #9 "for good" worth it on its own?** Marginally. #9 is esoteric (a monomorphic
non-generalized Float binop fed only by a polymorphic-HOF let, no literal/sig/field/list anchor).
The **value of C is the wasm side** — it converts the *trapping* #5–8 (fold accumulator, tuple,
let) from "program crashes at instantiate" into "works," which is the realistic win (generic Float
reductions on wasm). If the wasm SQLite/aggregate track needs those, **GO on C**. If not, the
native-only #9 alone does **not** justify a native seed re-mint — **defer and document**.

---

## 6. Staged plan (if GO on C)

Each stage independently gated. **Re-mint flag:** the native self-compile fixpoint reads the
checked-in seed; any change to a file in the LLVM self-compile closure (`llvm_emit.mdk` **and**
its shared upstream `typecheck.mdk` / `core_ir_lower.mdk` / `ast.mdk` / `core_ir.mdk`, all
compiled into `medaka`) perturbs emitted IR → **requires `selfcompile_fixpoint` + a SEED RE-MINT**.
Because C touches typecheck + lowering + both emitters, **the whole of C is one re-mint unit** —
unlike the wasm-only MINIMAL stages 1-2, you cannot land the emit half wasm-only.

| stage | change | files | gate | re-mint | model |
|-------|--------|-------|------|---------|-------|
| C0 | Add `RScalar String` to `Route` (or a parallel arith tag); add a `CBinPrim` scalar-tag field; make `lowerBinop` pass the `EBinOp` route through (default `RNone`/none). No behavior change yet. | `ast.mdk`, `core_ir.mdk`, `core_ir_lower.mdk` (+ sexp/astdump lockstep) | `diff_compiler_*` sexp/lower goldens unchanged (tag defaults inert) | **YES** (ast/IR shape) | Opus (IR-shape lockstep is footgun-prone) |
| C1 | Typecheck: record arithmetic `EBinOp` sites into the (extended) `pendingBinopSites`, stamp `RScalar "Float"`/`"Int"` **only when the operand grounds to a concrete primitive** (mirror `resolveBinopSites`' grounded-only guard). | `typecheck.mdk` | `diff_compiler_check*` unchanged; new check fixture asserts the stamp on #9-shaped input | YES | Opus |
| C2 | Native `emitBin` reads the `CBinPrim` tag → `fieldNameToLTy` → `LTFloat` (bypass `staticIsFloat`). | `llvm_emit.mdk` | `diff_compiler_llvm` + **`selfcompile_fixpoint`**; new native fixture for #6/#9 | YES | Opus (native emitter) |
| C3 | Wasm `emitBinRef`/`cexprIsFloat` read the tag → float path. | `wasm_emit.mdk` | `test/wasm/diff_wasm.sh` + `diff_sqlite`; new wasm fixtures #5/#6/#8/#9 | (part of same re-mint unit) | Sonnet |
| C4 *(optional, orthogonal)* | Auto-print: stamp `main`'s result scalar type so `refMainKind`/`mainKind` render bare Float mains (#1–4). Small `Ref String` on the program's main or a typecheck-exported main-type. | `typecheck.mdk` + both `refMainKind`/`mainKind` | native + wasm bare-main fixtures | YES | Sonnet |

Land C0–C3 as **one seed re-mint** at the end (per `feedback_defer_seed_remint`: don't re-mint
per sub-stage; verify `selfcompile_fixpoint` once at the checkpoint).

---

## 7. Forks needing a human decision

1. **A vs B vs C.** Recommend **C** (binop stamp): same realistic coverage as B, ~half the
   plumbing (no binder AST field, no `CLet`/`CLam`/`CClause` churn), reuses the comparison-operator
   infra. B only wins if you also want the auto-print/every-use-Float property — better bought
   with the tiny C4. A rejected (fold-only, wasm-only, skips #9).
2. **Scope: whole realistic residual (#6–9) vs native-#9-only.** The native-only #9 is esoteric
   and does **not** justify a native seed re-mint by itself. The wasm trapping (#5–8) is the real
   payoff. GO only if the wasm Float-reduction path is wanted; otherwise **defer + document in
   `EMITTER-GAPS.md`**.
3. **Is the native seed-re-mint churn worth it?** C is a single re-mint unit touching the native
   self-compile closure. If you're batching other native emitter work, fold C in. If not, the
   isolated benefit (wasm Float reductions + one esoteric native corner) may not justify a
   standalone re-mint this cycle.
4. **§4 wasm polymorphic-Num arithmetic (#12–13)** — separate, larger (`$mdk_value_add` runtime
   dispatch or monomorphization). Decide independently; **not** part of this residual. Without it,
   generic Float math still needs a `Float` signature to run on wasm.

---

## LOCKED SCOPE (orchestrator + user decision, 2026-06-30)

**GO on approach C (arithmetic-binop scalar-type stamp), full realistic residual (#5–9), THEN the wasm polymorphic-Num gap (§4) as a separate follow-up workstream.** Fork answers: (1) **C** (not A/B); (2) whole realistic residual, not native-#9-only; (3) native seed re-mint accepted (user wants Float closed for good); (4) the wasm polymorphic-Num arithmetic (#12–13, `sq x = x*x`) IS wanted — scoped as a SEPARATE next workstream after C, not part of C.

**Execution:**
- **C-core (Opus) = C0 + C1 + C2** as one coupled unit: add the scalar-tag field to `Route`/`CBinPrim` + `lowerBinop` passthrough (C0, do first + verify goldens inert/recaptured — IR-shape lockstep footgun); typecheck grounded-only stamp into the `pendingBinopSites` infra (C1); native `emitBin` reads the tag → `LTFloat` (C2). Gate: native #6/#9 fixtures run==build correct Float; `diff_compiler_llvm`/`check`/sexp-lower goldens recaptured; `selfcompile_fixpoint` C3a/C3b YES. Incremental-landing OK (land C0 alone + STOP if the AST lockstep balloons).
- **C3 (Sonnet)** = wasm `emitBinRef`/`cexprIsFloat` read the tag → float path. Gate: wasm #5/#6/#8/#9 fixtures wasm==native; `diff_wasm` + `diff_sqlite` green.
- **Seed re-mint ONCE** after C3 (orchestrator): C touches the native self-compile closure → one re-mint unit; verify `selfcompile_fixpoint` + cold `bootstrap_from_seed`.
- **C4 (auto-print bare Float mains) DEFERRED at the time this plan was locked** —
  orthogonal nicety, not part of the arithmetic fix. ⚠️ See the Status line at the top of
  this doc: re-probed 2026-07-16 (#361), the specific symptom C4 targeted no longer
  reproduces (native now auto-prints correctly). This plan is kept for the record, not as
  a live TODO.
- **NEXT workstream (after C):** wasm polymorphic-Num arithmetic (§4, #12–13) — its own design pass (`$mdk_value_add` runtime dispatch vs monomorphization).
