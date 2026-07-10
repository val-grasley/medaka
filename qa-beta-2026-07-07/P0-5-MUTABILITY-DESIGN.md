# P0-5 — Beta Mutability Model: enforce immutability + make `let mut` work

> **⚠️ PIVOT (2026-07-09, SHIPPED).** The user re-decided the model: **`let mut`
> is DROPPED, not fixed.** Mutability consolidates on the **`Ref` type + `<Mut>`
> effect**. Bindings are immutable; `=` is declaration only; a bare reassignment
> `x = e` of an existing binding is a located error (`R-IMMUTABLE-ASSIGN`), and
> `let mut` is a located error (`R-MUT-LET-REMOVED`) pointing at `Ref`. Mutation:
> construct `Ref v`, **write** with the new **`:=`** operator (`x := e`, surface
> sugar for `setRef x e`), **read** with `.value`. Shadowing (`let x = …` reusing
> a name) stays legal.
>
> **Superseded by this pivot:** §4/§5 below (the `let mut` branch-write
> representation + closure-snapshot engine) — there is **no mutable-binding
> engine**. What SURVIVES and was implemented: the enforcement map + the
> reassignment/`let mut` rejection sites. See `SYNTAX.md` (§Refs, §let/mutation)
> and `language-design.md` (§Mutability Rules) for the shipped model.


**Status:** design / scoping pass (no compiler source changed). Deliverable is this
doc. All behavior below verified empirically on the current binary, built and run
**in the Docker Linux container** (`scripts/docker-dev.sh build`; ad-hoc runs against
volume `medaka-work`) on commit at branch `worktree-agent-a5d6deb2c20f49398`
(base contains `6213258c`).

**Decision already made by the user (do NOT relitigate):** enforce immutability
(reassigning a non-`mut` binding is a located `check` error naming `let mut` as the
fix) **and** make `let mut` actually work (a branch-local write to a `mut` binding
persists on both `run` and `build`).

---

## 0. TL;DR

* **The whole feature is "shadow, not mutate."** There is no expression-level
  assignment node. `x = e` parses to a **statement** `DoAssign x e` (AST
  `ast.mdk:110`), and at *every* stage — resolve, typecheck, eval, emit —
  reassignment is modeled as **rebinding the name for the linear tail of the same
  block** (a fresh env frame / fresh SSA register), never as a store into a shared
  cell. `let mut` is *identical* to `let` at runtime; the `mut` flag only gates a
  typecheck value-restriction tweak and a "must be in a block" front-end check.
* **Consequences that the QA sweep flagged, re-confirmed here:** (a) reassigning a
  non-`mut` binding is silently accepted at every binding kind; (b) a reassignment
  can silently *change the binding's type*; (c) a write inside an `if`/`match`
  branch is **lost** because the shadow frame is discarded when control leaves the
  branch; (d) a branch whose *only* statement is an assignment **panics the
  emitter** with `E-PANIC: empty block`.
* **The symptom shifted vs the QA sweep in one place:** the sweep's literal example
  `if True then x = 2` (single-line) **does not parse at all** today — a bare
  assignment cannot be an `if`-branch on a single line. The reproducing shape is
  the **block form** `if True then` ⏎ `  x = 2`, which parses, then loses the write
  on `run` and panics on `build`. Details in §1/§2.
* **Recommended rep for the branch-write fix:** promote a `mut` binding to a **real
  mutable cell** scoped to the enclosing function (eval: a tagged `Ref` cell that
  `DoAssign` `setRef`s; emit: an `alloca` slot with load/store, which `mem2reg`
  promotes to SSA+φ). To preserve today's **closure-snapshot** semantics, closures
  **snapshot `mut` cells by value at capture time**. Option (b) SSA/env-return
  threading is heavier and rejected (§4).
* **Enforcement lands in `resolve`** (purely syntactic scoping property; parser
  already distinguishes `DoLet` from `DoAssign`, so shadowing stays legal for free),
  with a companion type-preservation check in `typecheck` for the type-changing-mut
  fork. New code `R-IMMUTABLE-ASSIGN`.
* **No seed re-mint owed:** no `.mdk` source in `compiler/` or `stdlib/` uses
  `let mut` or bare reassignment (grep = 0 real sites), so the emitter change emits
  byte-identical IR for the compiler itself. Verify via `selfcompile_fixpoint`
  against the committed seed (expect PASS, no re-mint).

---

## 1. Empirical current-behavior matrix (fresh, in-container)

`check` = `medaka check`; `run` = `medaka run`; `build` = `medaka build` then run the
native binary. All fixtures are minimal; exit codes captured un-piped.

| # | Sub-case (source shape) | `check` | `run` | `build` (then exec) |
|---|---|---|---|---|
| 1 | **plain reassign** `let x = 1; x = 2; println x` | accept | **2** | **2** |
| 2 | **type-changing reassign** `let x = 1; x = "hello"; println x` | accept | **hello** | **hello** |
| 3 | **param reassign** `f x = (x = 2; x)` | accept | **2** | **2** |
| 4 | **pattern-bound reassign** `let (a,b)=(1,2); a = 9; println a` | accept | **9** | **9** |
| 5 | **top-level reassign** `x = 1` / `main = (x = 2; println x)` | accept | **2** | **1** ⚠ diverges |
| 6 | **`let mut` straight-line write** `let mut x=1; x=2; println x` | accept | **2** | **2** |
| 7 | **`let mut` branch-write, single-line** `let mut x=1; if True then x=2; println x` | **PARSE ERROR** | PARSE ERROR | PARSE ERROR |
| 7b | **`let mut` branch-write, block form** `let mut x=1;` `if True then` ⏎ `  x=2;` `println x` | accept | **1** ⚠ write lost | **E-PANIC: empty block** |
| 7c | **branch-write, multi-stmt then** `if True then` ⏎ `  x=2` ⏎ `  println "set"` | accept | `set` then **1** ⚠ lost | builds; `set` then **1** ⚠ lost |
| 7d | **whole-if reassign** `x = if True then 2 else x` (parses; not a branch write) | accept | **2** | **2** |
| 8 | **top-level branch write** (= case 5) | accept | **2** | **1** ⚠ diverges |
| 9 | **closure snapshot** `let mut x=1; let f=()=>x; x=2; println (f ())` | accept | **1** | **1** |
| 10 | **shadowing (must stay legal)** `let x=1; let x=2; println x` | accept | **2** | **2** |
| 11 | **branch-write with else** `if False then x=2 else x=3` (single-line) | **PARSE ERROR** | PARSE ERROR | PARSE ERROR |
| 12 | **closure write-back** `let f = () => (x = 2)` | **PARSE ERROR** | PARSE ERROR | PARSE ERROR |

**Parse-error detail (cases 7, 11, 12).** The failure is triggered by *an assignment
inside a single-line `if`/lambda branch*, **not** by `mut`:
`if True then x = 2 else ()` fails identically with `let x` (non-mut); a `let mut`
followed by an ordinary `if True then println "a" else println "b"` parses fine. The
error is `unexpected 'if'; expected a dedent` (or `unexpected '=>'` for the lambda).
Root cause (§2): `parseExpr` consumes `if True then x` as an expression, the trailing
`= 2` then drives `assignFromLhs (EIf …)` → `flattenFieldPath = None`, and the
layout/commit interaction surfaces the error at the `if`. **The block form (7b) is
the canonical reproducing shape** for the lost-write / empty-block bugs.

**Key divergences / bugs distilled:**
1. Non-`mut` reassignment is **silently accepted at all five binding kinds** (1,3,4,5,
   and the general `let`) — `run` and `build` agree except case 5.
2. Reassignment **silently changes type** (case 2) — accepted, both engines print
   `hello`.
3. `run`/`build` **diverge on top-level reassign** (case 5: `run`=2, `build`=1).
   Moot once enforcement rejects it (top-level is immutable — §6 fork iii).
4. `let mut` **straight-line writes work** on both engines (case 6). Only writes that
   must escape a branch are broken.
5. `let mut` **branch-write is lost on `run`** and **panics the emitter** when the
   branch is a sole assignment (7b), or **is lost on `build`** when the branch has a
   trailing non-assignment (7c).
6. **Closure snapshot is 1 on both engines** (case 9) — this is the semantics to
   preserve.

---

## 2. How `let mut` / reassignment is threaded today (file:line)

### Parse — `compiler/frontend/parser.mdk`
* `let mut` statement → `letKind TMut` (`2905`) → `letMutBody` (`2914-2925`) →
  `DoLet True False pat e1`. The **`mut` flag is the first `Bool`** of `DoLet`.
* Bare `x = e` reassignment → statements parse as expressions, and a trailing `=`
  reinterprets: `exprStmtFor e TEqual` (`3004`) → `assignFromLhs` (`3025-3030`):
  `Some (x, []) => DoAssign x rhs` (bare var), `Some (x, fs) => DoFieldAssign …`
  (field path), `None => failP "invalid assignment target in do-block"`.
  There is **no `EAssign`/`SAssign` expression node.**
* Single-line assignment-in-branch (case 7): `parseExpr` eats `if True then x`;
  `assignFromLhs (EIf …)` → `flattenFieldPath (EIf …) = None` → parse fails.

### AST — `compiler/frontend/ast.mdk`
* `DoStmt` (`106-112`): `DoLet Bool Bool Pat Expr` (`109`; `<isMut> <isFun>`),
  `DoAssign String Expr` (`110`; **target name as a bare `String`**, no back-link to
  the binding or its `mut`-ness), `DoFieldAssign String (List String) Expr` (`111`).
* Expression let: `ELet Bool Bool Pat Expr Expr` (`140`; `<isMut> <isFun>`).
* `mut` is a **flag**; there is no distinct mutable-binding node and no assignment
  expression.

### Resolve — `compiler/frontend/resolve.mdk`
* `checkStmt … (DoLet _ False p e)` (`751`) / `(DoLet _ True p e)` (`755`): the
  **`mut` flag is discarded** (`_`).
* `checkStmt … (DoAssign _ e)` (`759`): the **target name is discarded** (`_`); only
  the RHS is walked; scope returned unchanged. → **No check that the target is in
  scope, and none that it was declared `mut`.** This is exactly the enforcement gap.

### Typecheck — `compiler/types/typecheck.mdk`
* `inferStmt env (DoAssign x e) = extendVar env x (monoScheme (infer env e))`
  (`3885`): **rebinds `x` to a fresh monomorphic scheme of the new RHS type** — does
  **not** unify with the existing type → silent type change (case 2), and no
  `mut`-ness check.
* `let mut` binding: `blockLet` (`3916-3929`): `isMut` forces
  value-restriction/monomorphism (`genRestricted (not isMut && …)` at `3928`; T1b
  rationale `3930-3933`) and is excluded from α-scope seeding (`3929`).
* `mut` rejected inline: `inferLet … | isMut` pushes `T-MUT-LET-BLOCK`
  (`5410-5423`; msg `mutLetRequiresBlockMsg`, `1014-1017`). `mut` rejected in a
  monadic `do`: `collectDoStmtErrors` (`1073-1081`, `mutLetInDoMsg`).

### Eval — `compiler/eval/eval.mdk`
* Env: `EvalEnv (List (List (String, Ref Value)))` (`106`) — frames of **mutable
  `Ref` cells**, but cells are only mutated for letrec knot-tying, never for
  reassignment.
* `let mut` has **no special case** — `DoLet` → `blockLet` (`1215` → `1237-1240`) →
  `extendEnv env binds` pushes a **new frame with a fresh cell** (`490-494`).
* Reassignment: `evalBlock env ((DoAssign x e)::rest) = evalBlock (extendEnv env
  [(x, eval env e)]) rest` (`1220-1221`) — **pushes a new shadow frame**, threaded
  only into `rest`. Sole/tail assignment: `evalBlock env [DoAssign _ e] = …; VUnit`
  (`1217-1219`) — evaluates RHS for effect and yields Unit, **discarding the shadow**.
* **Why the branch write is lost:** `eval env (EIf c t e) = evalIf env (eval env c)
  t e` (`1018`); `evalIf … (VBool True) t _ = eval env t` evaluates the branch with
  the *incoming* env and returns **only a Value**. The branch's `EBlock [DoAssign …]`
  hits `1217`/`1221` and its shadow frame never flows back out of the `if`. The
  enclosing block continues with its original env → old value.
* **Closure capture:** `eval env (ELam pats body) = VClosure env pats body` (`1013`)
  snapshots the current frame list. Because reassignment pushes *new* frames rather
  than mutating captured cells, a closure created before a reassignment never sees it
  — **snapshot-by-value falls out of the shadow model, with no dedicated code path.**

### Emit — `compiler/backend/llvm_emit.mdk`
* Straight-line `let mut` write: reuses the plain `CSLet _ (PVar x)` arm (`3085`); the
  `mut` flag carries no emit work (comment `3119-3125`). Reassignment: `emitBlock e
  env ((CSAssign x ex)::rest)` (`~3125`) rebinds `x` to a new SSA register in the env
  list — **shadow, no `alloca`/store**.
* `if` emit (`2814-2838`): each branch is emitted and its **value** stored into one
  shared `alloca i64` result slot; env extensions inside a branch are local to that
  branch's `emitExpr` and discarded — same shadow-lost-past-`if` behavior as eval.
* **Why the `empty block` panic (case 7b):** the arm `((CSAssign x ex)::rest)`
  (`~3125`) is listed **before** the intended tail arm `[CSAssign _ ex]` (`~3130`).
  A branch whose sole statement is `x = 2` is `[CSAssign x 2]`, which matches the
  earlier cons arm with `rest = []`, recursing `emitBlock e env2 []` → the catch-all
  `emitBlock _ _ [] = gapE "empty block"` (`3144`). The tail arm at `~3130` (which
  would have yielded `("1", LTUnit)`) is **shadowed / unreachable**. (Case 7c has a
  trailing `println`, so the block is non-empty → it builds but the write is still
  lost via the shadow.)

### `let mut` usage in the tree
`grep 'let mut ' compiler/ stdlib/ --include='*.mdk'` → **0 real binding sites**. All
hits are message strings / comments (`typecheck.mdk:1015,1022,2514,3926,3931,5422`;
`parser.mdk:1175,2897,2914`; `llvm_emit.mdk:3119`; `wasm_emit.mdk:1928`) or design
docs. **The self-hosting compiler and stdlib do not exercise `mut`.** This is the key
fact making the emitter change re-mint-free (§7).

---

## 3. Enforcement design (immutability)

### Where it lands: **resolve** (with a typecheck companion for the type fork)
Argument: reassignability is a **purely syntactic scoping property** — "is the target
in scope, and was it introduced with `mut`?" It needs no types. `resolve` already
threads a `scope` of bound names through `checkStmt`, and the parser **already
distinguishes** a fresh binding (`DoLet`) from a reassignment (`DoAssign`). So the
enforcement is local and does not risk the type pipeline. (Typecheck's `DoAssign`
arm at `3885` also needs a change, but only for the *type-preservation* fork —
§6 fork ii — not for the mut-ness check.)

### The change
Extend the resolve `scope` so each binder carries a **`mut` flag** (a parallel
`Set String` of mutable names threaded alongside `scope`, or a `(name, isMut)` scope
entry). Then:
* `DoLet isMut _ p e` (`resolve.mdk:751/755`): record each var in `patBindings p`
  with `isMut`.
* `DoAssign x e` (`resolve.mdk:759`): **look `x` up in scope.**
  * not in scope → `R-UNBOUND-ASSIGN` (bonus: today silently accepted).
  * in scope but **not `mut`** → `R-IMMUTABLE-ASSIGN` (the P0-5 error).
  * in scope and `mut` → OK (resolve RHS as today).

### Coverage of all five binding kinds — falls out automatically
Every non-`mut` binder is recorded non-mutable, so a `DoAssign` targeting it errors:
* **plain `let x`** — `DoLet False …` → non-mut.
* **function param** — params are bound non-mut in the clause's initial scope → a
  `DoAssign` to a param errors. (Requires param binders to be seeded into the same
  mut-aware scope; they already enter `scope`.)
* **pattern-bound `let (a,b)`** — `DoLet False (PTuple …)` → each of `a`,`b` non-mut.
* **top-level binding** — top-level decls are non-mut (there is no top-level `mut`
  syntax; §6 fork iii recommends keeping it that way) → a `DoAssign` whose target
  resolves to a global non-mut binding errors.
* **type-changing** — covered by the same rule (any non-mut reassign errors); for a
  *mut* binding, type change is the separate typecheck fork (§6 ii).

### Shadowing stays legal (required)
`let x = 1` then a new `let x = 2` (inner or same block) is a **`DoLet`**, always a
fresh binding — never touched by the `DoAssign` rule. So shadowing remains legal; only
**`DoAssign` (bare `x = e`) of a non-`mut` binding** is the error. This is the exact
distinction the parser already draws, so no ambiguity.

### The diagnostic (per ERROR-QUALITY.md + DIAGNOSTIC-CODES-DESIGN.md)
* **Code:** `R-IMMUTABLE-ASSIGN` (resolve stage → `R-*` prefix; add to the taxonomy
  in `DIAGNOSTIC-CODES-DESIGN.md`). `severity = 1` (error).
* **Located** at the `DoAssign`'s source span (the `x` on the LHS).
* **Message (names the rule + the binding):**
  `` cannot reassign immutable binding `x` `` .
* **`help` (actionable, names the fix):**
  `` `x` was introduced with `let`; declare it `let mut x = …` to allow reassignment. `` 
* **`fix`:** optional machine fix that inserts `mut` at the binding's `let` site. The
  `DoAssign` node does not carry the declaration span, so a precise `fix { range,
  replacement }` requires resolve to remember each mutable-candidate binder's decl
  span (cheap: store `(name, isMut, declRange)` in scope). **Recommendation:** ship
  the textual `help` first (Stage 1); add the machine `fix` as a follow-up once the
  decl span is threaded — do not block enforcement on it.

New `run`≡`check` fixtures: cases 1–5 above should all become located rejects.

---

## 4. Branch-write design (make `let mut` persist across branches)

**Requirement pair that pulls in opposite directions:**
* A branch write must **escape** to the enclosing function scope (so `if c then x=2;
  x` reads 2).
* A closure must **NOT** see a later write (case 9 must stay `1`).

Today both hold trivially because assignment is a *non-destructive shadow*: the write
never escapes (breaks req 1) but also never reaches a captured cell (satisfies the
snapshot). Any fix that makes the write escape must **re-establish the snapshot by
another mechanism.**

### Option (a) — **mutable cell scoped to the function + capture-time snapshot** ✅ recommend
* **Eval.** A `mut` binding gets a distinguished mutable cell (the env already holds
  `Ref` cells; tag `mut` cells so they're recognizable — e.g. a cell-kind flag, or a
  separate `MutCell` wrapper). `let mut x = e` installs the cell **in the enclosing
  block's frame** (not a per-statement shadow frame). `DoAssign x e` becomes
  `setRef (lookupCell env x) (eval env e)` — a **store into the shared cell**, so a
  write inside an `if`/`match` branch mutates the cell the enclosing scope holds →
  the write escapes. **Reads** of a `mut` var deref the cell (already how `lookupEnv`
  returns the cell's value). **Snapshot:** change `ELam` capture so that, for each
  `mut` cell the closure captures, it stores a **fresh immutable copy of the current
  value** (freeze at capture). Because only `mut` cells are ever mutated (immutable
  bindings are never reassigned — enforced in §3), non-`mut` cells can still be
  captured by reference with no observable difference; only `mut` cells need the copy.
* **Emit.** A `mut` binding becomes a real **`alloca` slot**: `let mut x = e` →
  `alloca; store init`; `x = e` → `store`; a read → `load`. A branch write stores into
  the **same slot** (exactly the mechanism the `if`-result slot already uses at
  `2814-2838`), so the write escapes the branch; `mem2reg` promotes the slot to
  SSA+φ. This **also fixes `empty block`**: the branch `x = 2` lowers to a real
  `store` instruction plus a unit result value — there is no empty residual `CBlock`,
  so the `emitBlock [] = gapE` path is never reached. (Independent of the fix, the
  shadowed tail arm at `~3130` should be reordered before the cons arm, but that alone
  would only turn the panic into a *silent drop* — not the desired persist.)
* **Closure-snapshot under emit:** closures over `mut` locals must capture the
  **current value**, not the slot pointer. Since closure write-back does not parse and
  the only `mut` cells are function-local, the closure conversion freezes the loaded
  value at capture — symmetric to the eval capture-copy.
* **Cost:** localized. Eval touches `DoAssign` (setRef), `let mut` cell install, and
  `ELam` capture (freeze mut cells). Emit adds an `alloca`-slot lowering for `mut`
  vars and their reads/writes. No change to the eval/emit *signatures*.

### Option (b) — SSA / env-return reconciliation (φ at joins) ❌ reject
Thread an **env delta out of** every block/branch: `evalBlock`/`evalIf` return
`(Value, EnvDelta)` and reconcile the two branches' deltas at the join (a φ). Emit
already does the memory version of this for the result slot. **Why rejected:** it is a
**signature-level refactor** of the eval core (every `eval*` that can contain a
statement must re-export env deltas) and a join-merge policy for `match` with N arms —
far more churn and risk than option (a), for no semantic gain. Option (a)'s
mutable-cell rep *is* the memory form of φ that `mem2reg` reconstructs for free on the
emit side.

### Option (c) — narrow "hoist the shadow to the enclosing frame" ❌ insufficient
Keep shadow semantics but install the reassignment's new frame in the enclosing
block's env rather than the branch-local tail. This cannot work with the functional
env threading: the `if` returns only a Value, so there is nowhere for the enclosing
`evalBlock` to receive the hoisted frame without option (b)'s env-return. Subsumed by
(a)/(b).

**Recommendation: option (a).** It is the most localized, it matches the emitter's
natural `alloca` lowering (so `run` and `build` converge on the same mental model),
and it cleanly preserves the closure snapshot via capture-copy.

---

## 5. Reconciliation with closure snapshot (worked example)

```
main =
  let mut x = 1
  let f = () => x
  x = 2
  println (f ())
```

* **Today:** prints **1** on both `run` and `build` (case 9). `f` captured the frame
  list before the `x = 2` shadow frame was pushed.
* **Under option (a):** `let f = () => x` captures `x` by **freezing the current value
  (1)** into `f`'s closure at capture time. The later `x = 2` stores into the shared
  `mut` cell/slot, which `f`'s frozen copy does not observe. `f ()` returns **1**.
  **Snapshot preserved.** ✅
* Meanwhile:
  ```
  let mut x = 1
  if True then
    x = 2
  println x        -- option (a): 2 (write escapes via the shared cell/slot)
  ```
  reads back **2** on both engines, as required.

The two requirements coexist precisely because the escape uses a **shared cell** while
capture takes a **copy** — the copy is what quarantines closures from later writes.

---

## 6. ⭐ Forks needing a human decision

**(i) Branch-write representation — mutable cell (a) vs SSA/env-return (b).**
→ **Recommend (a):** mutable cell scoped to the function + capture-time snapshot of
`mut` cells. Most localized; matches the emit `alloca` path; preserves snapshot. (b)
is a core signature refactor for no gain.

**(ii) Type-changing reassignment of a `mut` binding — allow or reject?**
`let mut x = 1; x = "s"` today is **accepted** (case 2, because `inferStmt`/`DoAssign`
rebinds rather than unifies). → **Recommend reject:** `mut` re-binds the *same* type;
change `typecheck.mdk:3885` to **unify** the RHS type against `x`'s existing type and
push a `T-*` error (e.g. `T-MUT-TYPE-MISMATCH`) on failure. This also removes the last
"silently changes type" footgun. (Note: `mut` bindings are already forced
monomorphic at introduction — `3928` — so unification is well-defined.) The
alternative — allowing heterogeneous reassignment — is inconsistent with an HM core
and is not wanted.

**(iii) Top-level mutability — allow a top-level `mut`, or make all top-level
immutable?** There is no top-level `mut` syntax today, and case 5 shows top-level
reassign is *accepted but `run`/`build` diverge* (2 vs 1). → **Recommend: all
top-level bindings are immutable.** Enforcement (§3) then rejects case 5 with
`R-IMMUTABLE-ASSIGN`, which **also eliminates the run/build divergence** (both reject).
`mut` stays a **block-local** feature (consistent with it already being rejected
inline and in `do`). Reconsider top-level `mut` only if a concrete beta use-case
appears.

**(iv) Unused-`mut` warning.** A `let mut x` that is never reassigned is a code smell.
→ **Recommend: a `W-UNUSED-MUT` warning** (severity 2), suggesting `let`. Additive,
lint-flavored, **low priority** — ship after the core fix; do not block on it.

**(v) Parse: should `if c then x = 2` (single-line assignment-in-branch) parse?**
Today it does not (cases 7/11/12); only the block form works. → **Recommend: block
form is the supported shape for the beta**; make the parse error *clear* (today it
mislocates at the `if` with `expected a dedent`). Accepting a single-line assignment
branch is a separate parser change (teach `assignFromLhs`/branch parsing to allow an
assignment statement in a single-line `then`/lambda body) — **defer** unless the beta
needs the one-liner. If deferred, the P0-5 semantic fix targets the **block form**
(7b), which is what the eval/emit rep change makes read back `2`.

---

## 7. Staged, independently-gate-able implementation plan (ascending risk)

**Stage 0 — parser diagnostic polish (optional, tiny).** Improve the mislocated
single-line assignment-in-branch error (fork v) OR document block-form-only. No
semantic change. *Gate:* a parse-fixture golden.

**Stage 1 — Enforcement (additive; no runtime change).** Thread a `mut` flag through
resolve `scope`; add `R-IMMUTABLE-ASSIGN` (+ optional `R-UNBOUND-ASSIGN`); add the
type-preservation reject in typecheck (`3885`, fork ii → `T-MUT-TYPE-MISMATCH`). This
only *rejects* previously-accepted programs; it changes **no** eval/emit output for
programs that already type-checked, so all existing `build`/`run` goldens stay
byte-identical.
*Gates:* new `check`-reject fixtures for cases 1–5 (+ type-change 2); `run`≡`check`
agreement fixtures (reassign-of-immutable rejected); shadowing (case 10) still
accepted; existing `diff_compiler_check*` green.

**Stage 2 — Eval branch-write (option a).** Distinguish `mut` cells; install the cell
in the enclosing frame; `DoAssign` → `setRef`; `ELam` capture freezes `mut` cells.
*Gates:* block-form branch-write (7b) `run` → **2**; multi-stmt (7c) → **2**;
straight-line (6) still **2**; closure snapshot (9) still **1**; existing
`diff_compiler_eval*` / `bootstrap_*` green (no `mut` in compiler source → unchanged).
**Exercise the multi-module path** too (per the eval-driver gotcha) — add a case to a
gate that drives `eval_modules`.

**Stage 3 — Emit branch-write (option a).** `alloca` slot for `mut` locals;
load/store for reads/writes; fix the `empty block` (real store + unit result;
reorder/repair the shadowed tail `CSAssign` arm). Closure conversion freezes `mut`
value at capture.
*Gates:* block-form branch-write (7b) `build` → **2** (no panic); `build` == `run` for
all 6/7b/7c/9; **byte-identical IR** for non-`mut` programs
(`diff_compiler_llvm`, `diff_compiler_llvm_typed`, `diff_compiler_build`);
`selfcompile_fixpoint` C3a/C3b PASS; wasm parity if the `mut` rep is mirrored in
`wasm_emit.mdk` (else scope wasm out for beta and note it).

**Seed re-mint:** the emitter change touches `mut`/assignment lowering, but **no
`compiler/` or `stdlib/` source uses `mut`** (§2), so the emitter emits byte-identical
IR for the whole compiler → **no re-mint owed.** Confirm by running
`selfcompile_fixpoint` **against the committed seed** (expect PASS). A re-mint would
only become necessary if the compiler later dogfoods `let mut`.

---

## 8. Decisive gates the implementation will need

* **`run`≡`check` agreement fixtures** — the five reassign-rejected cases (1–5) plus
  type-change (2): `check` errors with `R-IMMUTABLE-ASSIGN` / `T-MUT-TYPE-MISMATCH`.
* **New build/eval fixtures** — block-form branch-write → **2 on `run` AND `build`**
  (7b, 7c); straight-line still 2 (6); closure snapshot still 1 (9). Drive both the
  single-file and the **multi-module** eval path.
* **`diff_compiler_llvm` / `diff_compiler_llvm_typed` / `diff_compiler_build`** —
  **byte-identical** for all existing (non-`mut`) programs after Stage 3.
* **`selfcompile_fixpoint` C3a/C3b** — emitter self-compile fixpoint against the
  committed seed (PASS ⇒ no re-mint).
* **Regression sentinel** — `grep 'let mut ' compiler/ stdlib/ --include='*.mdk'`
  stays **0 real sites** (any future compiler use of `mut` re-opens the re-mint
  question). Confirmed 0 today.
* **Shadowing sentinel** — case 10 (`let x`; `let x`) stays accepted at every stage
  (guards against over-broad enforcement).

---

## Appendix — reproduction commands (Docker, Linux binary)

```sh
scripts/docker-dev.sh build   # build medaka + medaka_emitter into volume medaka-work
# per-fixture (exit code captured un-piped):
docker run --rm -v medaka-work:/work -v <fixtures>:/fix:ro \
  -e MEDAKA_EMITTER=/work/repo/medaka_emitter -w /work/repo medaka-dev:latest bash -c '
    ./medaka check /fix/f.mdk; echo "check=$?"
    ./medaka run   /fix/f.mdk; echo "run=$?"
    ./medaka build /tmp/f.mdk -o /tmp/f.bin; echo "build=$?"; /tmp/f.bin; echo "exec=$?"'
```
All matrix rows in §1 were produced this way on the current binary.
