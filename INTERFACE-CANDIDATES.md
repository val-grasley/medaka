# INTERFACE-CANDIDATES.md — which built-in constructs could generalize behind an interface

Read-only design audit (2026-07-09). Surveys every built-in operator, literal,
and syntactic form in Medaka and classifies whether it is (A) already
interface-dispatched, (B) hardcoded but a good generalization candidate, or
(C) hardcoded and should stay narrow. Empirically derived from
`compiler/types/typecheck.mdk` (`inferBinop`/`inferUnop`), `compiler/eval/eval.mdk`
(`evalBinop`/`evalUnop`/`evalArith`), and `compiler/frontend/desugar.mdk`.

## How dispatch actually works here (mechanism, so the wiring changes make sense)

Operators are **not** desugared to method calls. They stay as `EBinOp op l r
(Ref Route)` and dispatch by two cooperating pieces:

1. **Typecheck** (`inferBinopE`, typecheck.mdk:4264) calls two recorders per site:
   - `recordBinopSite` (4298) maps the operator to an interface method via
     `binopMethod` (4318: `==`/`!=`→`eq`, `<`→`lt`, `>`→`gt`, `<=`→`lte`,
     `>=`→`gte`) and stashes a *pending binop site* carrying the route ref.
     After inference, `resolveBinopSites` stamps that route with the resolved
     `Eq`/`Ord` impl once the operand type grounds.
   - `recordArithSite` (4312) does the analogous thing for `+ - * / %`, and
     `numArithOp` (4369) records a **`Num` obligation** on the (unified) operand —
     so `1 + "x"` yields `No impl of Num for String`.
2. **The stamped route** is what lets a *user* `impl Num`/`Eq`/`Ord` participate:
   eval's structural `valueEq`/`valueCompare` (eval.mdk:506+) is the derived
   default; the route stamp forwards to the user's impl dict.

The upshot for this audit: a construct is **already general (A)** iff it has (a)
a `binopMethod`/obligation entry mapping it to an interface method AND (b) that
interface exists with clear laws. A construct is a **candidate (B)** iff eval
pattern-matches builtin `Value` constructors with *no* `binopMethod` entry and
*no* obligation — i.e. it is welded to specific `V*` cases.

---

## Master table

| Construct | Current backing | Class | Proposed iface (exists?) | Enables | Value | Cost/risk |
|---|---|---|---|---|---|---|
| `+` `-` `*` `/` `%` | `Num` obligation (numArithOp 4369; methods add/sub/mul/div) | **A** | `Num` (Y) | — | — | keep |
| `==` `!=` | `eq` via binopMethod; `valueEq` default | **A** | `Eq` (Y) | — | — | keep |
| `<` `>` `<=` `>=` | `lt`/`gt`/`lte`/`gte`; `valueCompare` default | **A** | `Ord` (Y) | — | — | keep |
| string interp `"a\{e}b"` | desugars to `++ display e ++` (desugar.mdk:227) | **A** | `Display` (Y) | — | — | keep |
| numeric literal `1` | `ENumLit` → `Num`-poly, `fromInt` (ast.mdk:270) | **A** | `Num` (Y) | — | — | keep |
| map/set literal `Map{..}`/`Set{..}` | desugars to `fromEntries` (desugar.mdk:842) | **A** | `FromEntries` (Y) | — | — | keep |
| `do` blocks | desugars to `andThen`/`pure` chains | **A** | monad/`Thenable` (Y) | — | — | keep |
| indexing `a[i]` | being wired to `Index` (in progress) | **A** (soon) | `Index` (Y, WIP) | — | — | keep |
| **`++` (concat)** | `arithOp` (typecheck 4333, bare unify, NO method/obligation); `appendVal` welded to `VList`/`VString` (eval 1369) | **B** | **`Semigroup` (Y, orphaned)** | `impl Semigroup` on ropes, `NonEmpty`, `Text`, difference-lists, custom builders → `++` Just Works | **HIGH** | **LOW** — interface + `append` method already exist; laws clear |
| **ranges `[lo..hi]` / `[lo..=hi]`** | `inferIntRange` unifies both bounds to `Int` (typecheck 3337); `evalRange` panics on non-`VInt` (eval:1130) | **B** | **`Enum` (N, new)** | `['a'..'z']`, custom enum ADTs (`Mon..Fri`), date ranges | **MED-HIGH** | **MED** — new interface; must handle inclusive/exclusive + step; note pattern ranges already accept Char (asymmetry, see below) |
| **unary minus `-x`** | `inferUnop "-" t = t` (identity, no obligation, typecheck 4604); eval welded to `VInt`/`VFloat` (1326) | **B** | **`Num.negate` (Y, orphaned)** | `-v` on vectors, complex, money, matrices | **LOW-MED** | **LOW** — `negate` already in `Num`; just route the unop |
| list literal `[1,2,3]` | `EListLit` → `List` (typecheck 3337 area) | **DISCUSS** | `FromList`/`IsList` (N) | overloaded literals for `Array`/`Set`/`Vec` | MED | **HIGH** — inference ambiguity, needs defaulting; likely a trap (see DISCUSS) |
| array literal `[..]` (array form) | `EArrayLit` → `Array` | **DISCUSS** | same as above | same | LOW | same — subsumed by list-literal question |
| string literal `"..."` | `ELit (LString)` → `String` | **C/DISCUSS** | `FromString`/`IsString` (N) | `Text`/bytestring literals | LOW | HIGH — OverloadedStrings is a known inference footgun |
| char literal `'a'` | `ELit (LChar)` → `Char` | **C** | — | nothing real | — | keep narrow |
| `&&` `\|\|` | `boolOp` unify to `Bool` (typecheck 4564); `evalAnd`/`evalOr` short-circuit | **C** | `Truthy`/boolean-algebra (N) | — | — | **REJECT** — JS-truthiness footgun; short-circuit semantics don't generalize |
| `if` condition | must be `Bool` | **C** | `Truthy` (N) | — | — | **REJECT** — same footgun |
| `!` / `not` | `inferUnop "!"` unify `Bool` (4605); eval welded `VBool` (1329) | **C** | boolean-algebra (N) | — | — | keep narrow — negation-of-Bool only |
| `::` (cons) | `consOp` builds `List a` (typecheck 4571) | **C** | `Cons`/`IsList` (N) | — | — | keep — pairs with list-literal question; not worth alone |
| `\|>` `>>` `<<` | structural (application/composition) | **C** | — | — | — | keep — pure function plumbing, no type to abstract |
| tuple `(a,b)` | structural `ETuple` / `__tupleN__` | **C** | — | — | — | keep — structural, already HKT-capable as a ctor |
| record literal `{f=v}` | nominal `ERecordCreate` | **C** | — | — | — | keep — nominal by design |
| record update `{r\|f=v}` | nominal | **C** | — | — | — | keep |
| field access `r.f` | nominal / receiver-directed resolution (Phase 72) | **C** | — | — | — | keep — already resolution-aware |

---

## Recommended generalizations (the B set, best value/cost first)

### 1. `++` → `Semigroup` — GOLD STANDARD (do first)
**Value HIGH / cost LOW.** The `Semigroup` interface already exists
(`stdlib/core.mdk`, `interface Semigroup a where append : a -> a -> a`, with
impls for `List`/`String`; `Monoid` sits on top with `empty`). But `++`
**bypasses it entirely**:
- typecheck.mdk:4333 `inferBinop "++" lt rt = arithOp lt rt` — bare `unify lt rt`,
  no obligation, no method mapping.
- `binopMethod` (4318) has **no `"++"` entry**, so no route is ever stamped.
- eval.mdk:1342 `evalBinop "++" = appendVal`; `appendVal` (1369) hardcodes
  `VList`/`VString` and panics otherwise.

A user who writes `impl Semigroup MyRope` today still cannot use `++` on it.

**Wiring change (mirror `==`→`eq`):**
1. `binopMethod "++" = Some "append"` (typecheck.mdk:4318) — so `recordBinopSite`
   stashes the site and `resolveBinopSites` stamps the route to the resolved
   `Semigroup` impl.
2. Replace `inferBinop "++" = arithOp` with a Semigroup-obligation op: keep the
   `unify lt rt`, but record a `Semigroup` obligation on the operand (clone
   `numArithOp`/`recordNumObligation`, swap `Num`→`Semigroup`), gated on the
   `Semigroup` interface being registered — exactly as `numArithOp` is gated on
   `Num` being registered (keeps no-prelude probe drivers byte-identical).
3. eval: in `evalBinop`/`appendVal`, keep the `VList`/`VString` fast paths as the
   builtin impls, but on the fall-through route to the stamped `append` method
   (via the `EBinOp` route ref, which the arm currently discards as `_`, eval:1019)
   instead of panicking.

**Risk:** LOW. Interface and laws (associativity) already exist and are
documented. `List`/`String` impls stay the fast builtin path so hot code is
unperturbed. Perturbs the self-compile fixpoint only if the compiler's own `++`
sites re-route — mitigate by keeping the `VList`/`VString` fast path byte-identical
(the compiler only ever `++`s lists/strings), so emitted IR for compiler sources
should be unchanged → **likely no seed re-mint**, but verify with the fixpoint gate.

### 2. Ranges `[lo..hi]`/`[lo..=hi]` → new `Enum` interface
**Value MED-HIGH / cost MED.** Today both bounds are unified to `Int`
(typecheck.mdk:3337-3338 `inferIntRange`, `unify … (TCon "Int")`) and `evalRange`
(eval.mdk:1130) panics on anything but `VInt`. Compelling motivator: **range
*patterns* already accept `Char`** (typecheck.mdk:3173 "only Int and Char bounds
are valid") — so `'a'..'z'` matches as a pattern but `['a'..'z']` fails to
typecheck as an expression. Generalizing removes that asymmetry and enables
`['a'..'z']`, custom enum ADTs, etc.

**Wiring change:** introduce `interface Enum a where enumFromTo : a -> a -> List a`
(plus an inclusive variant or a `succ`/`fromEnum`/`toEnum` trio à la Haskell).
Desugar `ERangeList lo hi incl` → `enumFromTo lo hi` (or keep the AST node and
have typecheck impose an `Enum` obligation on the unified bound type instead of
`unify … Int`; eval routes to the impl). Provide `impl Enum Int`, `impl Enum Char`.

**Risk:** MED. New interface (no existing laws to lean on — must define
`succ`/inclusive semantics carefully). Bigger surface than `++`. The `Array`-form
range (`ERangeArray`) needs the same treatment. Worth doing but a real design
increment — see DISCUSS for the inclusive/step question.

### 3. Unary minus `-x` → `Num.negate`
**Value LOW-MED / cost LOW.** `inferUnop "-" t = t` (typecheck.mdk:4604) is a
no-op identity with no `Num` obligation; eval (1326) hardcodes `VInt`/`VFloat`.
`Num` **already declares `negate : a -> a`**, so a user `impl Num Vector` defines
`negate` but `-v` still won't dispatch.

**Wiring change:** `inferUnop "-"` should impose the same `Num` obligation as
binary arithmetic (so `-x` requires `Num`), and eval's `evalUnop "-"` should route
to the `negate` method (fast paths for `VInt`/`VFloat` retained). Small, self-
contained, interface already exists. Lower priority only because custom-`Num`
types are niche.

---

## Keep narrow (with reason) — the C set

- **`&&` / `||` and `if`-conditions (→ `Bool`).** A `Truthy` interface would
  invite the JavaScript truthiness footgun (`if []`, `if 0`) — implicit coercions
  that destroy the "condition is a proposition" invariant. Additionally `&&`/`||`
  have short-circuit evaluation semantics (`evalAnd`/`evalOr`) that don't map onto
  a two-argument method cleanly. **Reject.**
- **`!` / `not` (→ `Bool`).** Boolean negation only; no real user type wants to
  overload it. A general boolean-algebra interface has no demand here.
- **`::` (cons).** Builds `List a` structurally (`consOp`). Only worth
  generalizing as part of a full `IsList` story (see DISCUSS); not on its own.
- **`|>` / `>>` / `<<`.** Pure function plumbing (application/composition). There
  is no type to abstract over — these are structural, not typeclass-shaped.
- **Tuples, record literals, record update, field access.** Structural/nominal by
  design. Tuples are already `__tupleN__` ctor spines usable at higher kinds
  (`impl Bimappable (,)`); records are nominal and field access is already
  receiver-directed (Phase 72). Nothing to generalize.
- **Char literals.** No real overloaded-char use case.

---

## DISCUSS (need a human design call)

1. **Overloaded list literals `[1,2,3]` → `FromList`/`IsList`.** *Tempting but
   likely a trap.* Map/Set literals already route through `fromEntries`
   (`FromEntries`, desugar.mdk:842) — but they carry a **syntactic head pin**
   (`Map{…}`/`Set{…}` name the target type via `:~ Name`), which *resolves the
   ambiguity for free*. A bare `[1,2,3]` has no such pin, so overloading it means
   the result type is unconstrained and needs a **defaulting rule** (default to
   `List`) plus principled-typing care, or every `[…]` becomes ambiguous. This is
   the Haskell `OverloadedLists`/`ExtendedDefaultRules` can-of-worms. **Recommend:
   either keep `[…]` monomorphic to `List` (status quo), OR adopt the same
   head-pin escape hatch already used for maps (`[…] :~ Array`) rather than
   silent overloading.** Human call: is the ergonomic win worth the inference
   complexity? Leaning NO for a preview release.
2. **Overloaded string literals → `IsString`.** Same ambiguity/defaulting cost as
   list literals, with even less demand (no second string type in stdlib today).
   Recommend NO unless/until a `Text`/bytestring type lands.
3. **`Enum` scope (couples to recommendation #2 above).** If ranges generalize,
   decide the interface shape: minimal `enumFromTo`/`enumFromThenTo` (Haskell) vs
   a `succ`/`pred`/`fromEnum`/`toEnum` core. Also: does `[lo..=hi]` inclusive vs
   `[lo..hi]` exclusive stay a `Bool` flag on the node, or become two methods?
   And should stepped ranges (`[0,2..10]`) be in scope? These are design
   decisions, not mechanical wiring.

---

## Bottom line for the orchestrator

- **Do now (clear win, low risk):** `++` → `Semigroup` (#1). Interface exists, laws
  exist, wiring mirrors `==`→`eq` exactly, hot paths preserved.
- **Do next (real feature, moderate design):** ranges → `Enum` (#2); unary minus →
  `Num.negate` (#3, cheap add-on to the same batch).
- **Reject:** truthiness for `&&`/`||`/`if`, boolean-op overloading, cons-alone.
- **Defer/DISCUSS:** overloaded list & string literals (inference ambiguity;
  prefer the existing head-pin pattern over silent overloading if pursued at all).
