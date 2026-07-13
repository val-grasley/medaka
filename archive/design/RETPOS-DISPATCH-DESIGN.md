# RETPOS-DISPATCH-DESIGN — return-position-only method mis-dispatch (run≠build)

**Status:** IMPLEMENTED — see `compiler/types/typecheck.mdk:6334`, comment "RETPOS
soundness — ambiguous interface constraint (run≠build hole)". The typecheck-only
rejection this doc recommends is in place. The rationale/probes below (§0) have
residual value for diagnosing similar dispatch bugs.

Status: DESIGN (decision-ready). Read-only diagnostic pass, base `1b2f0ed`. Root
cause + probes independently re-verified by the orchestrator on a fresh binary.

## 0. Bug reconfirmed
Repro (`project_return_position_only_dispatch_bug` / PLAN Compiler-language):
`f x = reveal (make (reveal x))`, `f : Thing a => a -> Int` →
`run`=(1000,1000), `build`=(2000,2000), brief's "expected"=(1000,2000).

## 1. Confirmed root cause — type AMBIGUITY, not dict mis-threading (overturns the filed framing)

The filed framing (dict-threading failure; eval+emit both need new routing) is
**disproven**. The RDict return-position machinery already works end-to-end; the
defect is one stage earlier, in inference, and the program is genuinely ambiguous.

- **Probe G (decisive):** `g : Thing a => a -> a; g x = make (reveal x)` — `make`'s
  result IS tied to the constraint var `a`. `run`==`build`==(1000,2000), correct,
  ZERO compiler changes. (Orchestrator-verified.) So when the result mono equals the
  enclosing constraint var, `resolveSite` stamps RDict(f's dict) and threading works.
- **Why `f` differs:** in `reveal (make (reveal x))` nothing unifies `make`'s result
  (`make : Int -> a` → fresh `t0`, obligation `Thing t0`) with `f`'s `a`. `t0` feeds
  the outer `reveal` and stays free. `check` confirms: `f : a -> Int` — `t0` appears
  nowhere. Classic ambiguous constraint variable (Haskell `show . read`). There is NO
  unique correct answer; (1000,1000)/(2000,2000)/(1000,2000) are all valid resolutions
  of un-anchored `Thing t0`. The hole: the compiler silently picks, and the two
  backends pick differently.
- **Probe H (fork evidence):** `h : Int -> Int; h k = reveal (make k)` — no constraint
  in scope at all. `check` accepts; `run`=1000, `build`=2000. Mis-dispatches with NO
  enclosing dict to borrow → a "default to enclosing dict" heuristic cannot help it;
  only rejection can.

### Decision point (file:line)
`resolveSite` (`compiler/types/typecheck.mdk:5308-5322`): for `f`, `resultMono`=`t0`
(free, not in `activeDictVars`, no head tycon) → the `None => ()` arm → route stays
**RNone**. Downstream RNone + a method with no argument of the dispatch tyvar
(`make : Int -> a`) can't arg-tag dispatch → eval (`compiler/eval/eval.mdk`) falls to
first-registered impl, emitter (`emitMethod RNone => emitMethodArgDispatch`,
`compiler/backend/llvm_emit.mdk:3021`) to the other → the run≠build fork. The upstream
*cause* is that `t0` was never grounded/rejected at `f`'s generalization.

## 2. Relationship to Gap 3 "Fix B" — DISTINCT (one fix does NOT cover both)
Gap 3 Fix B (`GAP3-SLICE7-DESIGN.md` §3): `sequence ta = traverse identity ta` — the
inner `traverse`'s receiver is an ARGUMENT-position generic receiver present in the
signature; its dict is in scope but not routed RDict in the emitted prelude body (a
threading/grounding bug). Our bug: a RETURN-position method whose tyvar is ABSENT from
the signature and genuinely ambiguous — no in-scope dict the type system must use.
They share only the (already-working) downstream RDict ABI. **Schedule separately.**

## 3. Recommended fix — typecheck-only ambiguous-constraint REJECTION (contained)
At `processSCC` (`compiler/types/typecheck.mdk:8343-8347`), after computing
`addedObls`, detect any obligation whose discriminating tyvar id is NOT present in any
member's generalized type (reuse `monoUnboundIds`/`monoArgUnboundIds` exactly as
`defaultGroupNum`/`defaultAmbiguousNum` do at `:4542-4560`) and is not `Num`. For each,
`pushTypeError` ("ambiguous use of method `make`: the instance for `Thing <var>` is not
determined by the type `a -> Int`"). This:
- is typecheck-only and contained (no marker/dict_pass/lower/emit/eval change);
- closes the hole uniformly — covers both `f` (one enclosing constraint) and `h` (none);
- converts a silent run≠build miscompile into a clean compile error (correct for an
  ambiguous program);
- mirrors a proven existing pattern (`defaultAmbiguousNum`), minimizing blast radius.

**Touchpoints:** `compiler/types/typecheck.mdk` only — new helper beside `defaultGroupNum`
(`:4556`), invoked at `processSCC:8344-8345`, plus the local-binding hooks that already
call `defaultAmbiguousNum` (`blockLet:3325`, `inferRecLet:4066`, `inferLetSimple:4080`,
`processLetGroup:4467`). One new `pushTypeError`. No new AST node, no route kind. eval +
emit untouched (ambiguous programs no longer compile).

## 4. Emitter-graph / seed
`typecheck.mdk` is in the self-compile graph → `FORCE_EMITTER_REBUILD=1 make medaka` →
`selfcompile_fixpoint` C3a/C3b → orchestrator seed re-mint at checkpoint. Fixpoint-safe
by construction (only adds rejections; the compiler corpus has no ambiguous
return-position constraint, else it wouldn't compile today). NOT seed-free.

## 5. Risk + decisive gates
Risk (reject): low–moderate; only regresses if it false-positive-rejects a
currently-well-determined program — mitigated by reusing `defaultAmbiguousNum`'s exact
membership test. Gates: `selfcompile_fixpoint`; `diff_compiler_typecheck` +
`_typecheck_errors` (new reject = golden add); `_eval_dict`/`_eval_modules`/`_llvm_typed`/
`_build`/`_check` stay green (no accepted-program change); `medaka test stdlib/core.mdk`
canary. Acceptance: `f` and `h` error cleanly on run AND build; probe G still prints
(1000,2000) on both.

## 6. DESIGN FORKS — need a human decision
- **F1. Reject vs. silently anchor.** Recommend **reject** (Haskell-style). The program
  has no unique meaning; "expected (1000,2000)" is one arbitrary resolution. Reject is
  sound, contained, uniform, covers `h`. *Alternative (not recommended):* anchor an
  ambiguous return-position constraint var to a unique enclosing same-interface dict
  (unify `t0`:=`a`) → makes `f` print (1000,2000) by reducing to probe G, but blesses an
  arbitrary choice, cannot help `h`, and is a surprising non-standard typing rule.
- **F2. Reject now standalone vs. bundle with Gap 3 Fix B.** Distinct defects (§2);
  recommend **reject now, standalone** (typecheck-contained, seed-cheap); leave Gap 3
  Fix B on its own track.
- **F3. Contained vs. ABI.** Primary fix is fully contained (typecheck-only, no ABI).

## 7. Staging
Single stage (reject): add ambiguous-interface-constraint detection + `pushTypeError` at
`processSCC` (+ the four local-binding hooks), capture the new typecheck-error golden,
run the gate set, orchestrator seed re-mint at checkpoint.

## 8. One-line summary
Root cause is **type ambiguity, not dict mis-threading**: `make`'s result tyvar is never
tied to `f`'s constraint var, so `resolveSite` (`typecheck.mdk:5311 None=>()`) leaves it
RNone and the two backends default differently. RDict return-position machinery is already
correct (probe G). One fix does NOT cover Gap 3 Fix B. Recommended fix: a typecheck-only
ambiguous-constraint **rejection** at `processSCC`, mirroring `defaultAmbiguousNum`;
eval/emit untouched; needs a seed re-mint.
