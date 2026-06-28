# Medaka style guide

Conventions for hand-written Medaka source — primarily the self-hosted compiler
(`compiler/*.mdk`) and stdlib (`stdlib/*.mdk`). These are the rules the formatter
**cannot** enforce (it preserves your choices); they live here so reviewers and
agents apply them consistently. For what the formatter *does* enforce
(indentation, width-breaking, trailing commas, import wrapping) see `fmt`.

> Each entry is a convention, not a hard gate. Prefer it where it improves
> readability; don't force-fit. When you touch nearby code, nudge it toward
> these — don't churn a file wholesale just to conform.

## 1. Block comments for prose; line comments for asides

Use a block comment `{- … -}` for any explanation spanning more than one line —
a function's doc, a paragraph of rationale, a worked example. Reserve `--` line
comments for short single-line asides next to the code they annotate.

A run of three-plus consecutive `--` lines is a smell: it's prose wearing a
line-comment costume. Convert it to one `{- … -}` block. (Watch the
[[mdk_comment_first_line_of_block]] gotcha: a comment can't be the first line of
an indented block — put the block *above* the opening line, not inside it.)

```
-- BAD: prose as a wall of line comments
-- This function lowers guard arms into a nested
-- if/match chain, terminated by a fallthrough
-- sentinel so the fold has a base case.
lowerGuards = …

{- GOOD: prose as one block, attached above the signature
   Lowers guard arms into a nested if/match chain, terminated by a
   fallthrough sentinel so the fold has a base case. -}
lowerGuards = …
```

## 2. Comment placement: whole-function docs above the signature; per-clause notes above the clause

A comment describing *what the function is/does* goes **above its type
signature** (or above the first clause if unsigned) — never wedged between the
signature and the first clause, and never trailing the last clause.

A comment about *one specific clause* (why this case is special, what edge it
handles) goes **immediately above that clause**, indented to match it.

```
{- Desugar a section like `(+ 1)` into a lambda. -}   -- whole-fn: above sig
sectionToCore : Section -> Expr
sectionToCore (SecRight op e) = …
-- left section needs an explicit `_` placeholder           -- clause note: above clause
sectionToCore (SecLeft op e)  = …
```

## 3. Prefer pattern guards over a nested `match`

When a clause's body is a `match` whose only purpose is to test/destructure a
computed value, a **guard** usually reads better — especially a pattern-bind
guard (`Pat <- e`). Function-clause guards (`f n | Some v <- e = v`) fully work
(interp + native, bind reaches the body).

```
-- BAD: match purely to gate one case
classify n =
  match lookup n table
    Some v => use v
    None   => fallback

-- GOOD: pattern-bind guard, function-clause form
classify n
  | Some v <- lookup n table = use v
  | otherwise                = fallback
```

Note: in a **match-arm** guard (`x if Some v <- e => body`) the bound `v` reaches
both later guard qualifiers **and the arm body** (fixed 2026-06-15 in the compiler
resolve/typecheck passes). Both forms are now safe.

The strength of the rewrite scales with whether the `Some`-arm actually
**binds**. When the match destructures and *uses* the payload (`Some a => … a …`),
the guard recovers that bind directly (`| Some a <- e = … a …`) — a clear win.
When the arm **discards** it (`Some _ => …`), there's no destructuring to
recover; the match is just a binary `Option` test, already compact and
symmetric, and the guard only trades it for `<-` + `otherwise` ceremony — a
wash. Convert the binding cases on their own merit; convert the discarding ones
mainly for **family consistency** (a group of same-shaped functions should read
uniformly — don't leave one a guard and its sibling a match).

## 4. Magic strings: three categories, three treatments

Synthetic string literals in compiler code fall into three kinds — keep them
distinct:

1. **Local synthetic binder names** (`"__fn_arg"`, `"__do_x"`, `"__a"`/`"__b"`,
   `"__r"`). Gensym-style names produced *and consumed* within one desugaring.
   Fine inline; keep the `__`-prefix and make the stem name the site
   (`__do_x` = a do-block bind's scrutinee). They never cross a module boundary,
   so a local literal is correct.
2. **Cross-module protocol names** (`"__fallthrough__"` — referenced in
   `desugar.mdk`, `eval.mdk`, *and* `llvm_emit.mdk`). These MUST be a single
   shared constant in the support layer; three independent literals silently
   drift. (Tracked as the protocol-name-centralization refactor.)
3. **Language-surface names** (`"eq"`, `"compare"`, `"show"`, interface method
   names). These are the actual contract with the prelude/interfaces — keep them
   as literals at the call site; "centralizing" them only adds indirection over
   a name that is *defined* to be that string.

The rule of thumb: centralize a magic string exactly when **two+ files must
agree on it and nothing else defines it** (category 2). Leave categories 1 and 3
inline.

## 5. Reach for a support helper over manual index-threading

When you find yourself threading an explicit index/accumulator through a fold
just to join or separate elements (commas between fields, newlines between
clauses), prefer a named helper — `intersperseStr`, `intercalate`-shaped — from
`compiler/support/util.mdk`. It states intent and removes the off-by-one surface.

Compiler code may **not** `import` stdlib (`list`/`string`/…) for this — see the
no-stdlib-in-compiler rule in AGENTS.md. Add the helper to `support/` (or inline
it) instead.

```
-- BAD: manual index threading to place separators
go i [] acc = acc
go i (f :: fs) acc =
  go (i + 1) fs (acc ++ (if i == 0 then "" else ", ") ++ f)

-- GOOD: intent named, no index
intercalateStr ", " fields
```

## 6. Derive `Eq`/`Ord`/`Debug` — don't hand-roll structural equality

`deriving (Eq)` works in compiler on payload-bearing types, not just nullary
enums — `Eq`/`Ord`/`Debug` are in scope via the implicit `core.mdk` prelude (the
no-stdlib rule bans `import list`/`string`/… *modules*, not the prelude). So
**derive** these instances unless you have a **concrete** reason not to:

- **Underivable** — the function is intentionally *not* full structural `==`:
  head-only (`tyHeadEq` ignores type args), or over a non-AST type (`valueEq`
  over runtime `Value`). Keep these hand-rolled; they're a different relation.
- **Measured hot path** — a derived `==` dispatches through the `Eq` dict; a
  hand-rolled `litEq : Lit -> Lit -> Bool` is a direct monomorphic call. Only
  invoke this for a *profiled* hotspot (see `compiler/PERF-RESULTS.md`), not a
  hunch. The bar is high: we A/B-tested exactly this shape (`concatMapList` →
  the prelude's dict-dispatched `flatMap`, ~414 sites, whole self-compile) and
  measured **no difference** — dict witnesses are hoisted to global constants
  (`PERF-RUNTIME`), so the dispatch cost the prior assumed is gone. Treat "perf"
  as disproven until a paired A/B says otherwise.

Everything else: derive it. A hand-rolled structural eq carries a silent hazard
— the `_ _ = False` catch-all keeps typechecking when a new variant is added,
quietly returning `False` for it; a derived instance stays correct. And the same
8-line body tends to get copy-pasted across files (e.g. `litEq` lived verbatim in
both `exhaust.mdk` and `ir/core_ir_lower.mdk`).

```
-- BAD: hand-rolled structural eq (drifts; goes stale on a new variant)
litEq : Lit -> Lit -> Bool
litEq (LInt a) (LInt b) = a == b
litEq (LFloat a) (LFloat b) = a == b
-- … one arm per variant …
litEq _ _ = False

-- GOOD: derive it on the type; call sites use `==` / `(l ==)`
data Lit = LInt Int | LFloat Float | … deriving (Eq)
```

## 7. Prefer the prelude's idioms over re-implementing them

When `core.mdk`'s prelude already provides an operation — `flatMap`/`andThen`
(the `Thenable` bind), `map`/`filter`, `<>`, do-blocks — use it directly rather
than defining a bespoke monomorphic twin in `support/`.
A duplicate helper fragments the codebase: new code (and AI agents extending it)
copy whichever form they happened to see first, and the two drift. In a young
language the *first* pattern in the tree becomes the de-facto standard — so make
the standard the language's own idiom, not a private alias for it.

This was historically hedged on perf (`concatMapList` is a direct call;
`flatMap` dispatches through the `Thenable` dict). That cost is **empirically
negligible** — see §6: a paired A/B measured no difference. So default to the
prelude idiom; demand a measured A/B before keeping a duplicate for speed.

`flatMap` is the default replacement (same arg order as a `concatMap`-shaped
helper). Where the call site has extra shape — a guard or an inline transform —
a `filter` + `map` (`|>`) pipeline reads better; but a plain flatten of a
named, list-returning function stays `flatMap`:

```
-- BAD: bespoke helper re-spelling a prelude op
concatMapList children nodes
concatMapList (x => if p x then [x] else []) xs

-- GOOD: prelude idiom; filter/map pipeline where there's a guard
flatMap children nodes               -- plain flatten: flatMap
filter p xs |> map f                 -- guard + transform: filter then map
```

## 8. Prefer multi-clause functions over a `match` on an immediate parameter

When a function body is a `match` directly on one of its **bare parameters**, write
it as **multi-clause** definitions instead — one clause per pattern. The arm
patterns move into the parameter position; any other parameters keep their plain
names, repeated in each clause. It reads as the function's shape rather than a
nested expression, and it scales cleanly as cases grow.

```
-- BAD: match on a bare parameter
choice ps = match ps
  []        => failWith "choice: no alternatives"
  q :: rest => orElse q (choice rest)

-- GOOD: multi-clause
choice []         = failWith "choice: no alternatives"
choice (q :: rest) = orElse q (choice rest)

-- GOOD: match on a non-final param — repeat the others
applySign None    n = n
applySign (Some _) n = 0 - n
```

This is the **immediate** complement to §3: §3 converts a `match` on a *computed*
value (`match (lookup n table) …`) into a **guard**; §8 converts a `match` on a
*parameter already in hand* into **clauses**. A computed scrutinee is not a §8
case — keep it a `match` (or make it a guard per §3).

When **not** to convert: a single-arm match (no shape to spread across clauses);
a body with `let`/`where` bindings shared by every arm (clauses would duplicate
them — leave it a `match`, or hoist the shared work); or where splitting would
separate same-named clauses (they must stay **contiguous**). As in §3, convert on
each function's own merit, but keep a family of same-shaped functions uniform.

Reserve a `support/` helper for functionality the prelude genuinely lacks (a
fold shape it doesn't expose) — not for re-spelling one it has. (Contrast §5,
which is about reaching for a helper instead of hand-threading an index: there
the helper *adds* intent; here the bespoke helper merely *shadows* the prelude.)

## §9 — Write `::` tight when both operands are atoms

The cons operator `::` signals **structure** (list construction), not
computation. It is written **tight** (no surrounding spaces) only when **both
operands are atoms**; it is **spaced** when either operand is an application or a
binop, so the visual grouping matches the parse. (Supersedes the prior
"tight everywhere" rule.) An *atom* is a variable, a literal, an index access
(`a.[i]`), a field access (`r.x`), or a parenthesized/delimited expression
(tuple, list/array/map/set literal, record, range, section). All other binary
operators (`+`, `==`, `++`, `&&`, `|>`, …) are always spaced.

```
-- Tight: both operands are atoms (variable :: variable, index :: variable, …)
prepend h t = h::t
build n acc = n::acc
takeOne input pos acc = input.[pos]::acc
keep x = pure (x::xs)

-- Spaced: an operand is an application or a binop
emitU8 b r = set_ref r (bitAnd b 255 :: r.value)   -- left is an application
addContBits (x::rest) = x + 128 :: addContBits rest -- left binop, right app

-- Pattern position is already all-atoms — stays tight
go []       acc = acc
go (x::xs) acc = go xs (x::acc)
```

The formatter enforces this rule (`compiler/tools/printer.mdk`): `consTight`
gates the tight rendering on `isConstructorOp op && isConsAtomOperand l &&
isConsAtomOperand r`. Medaka has no user-defined infix constructors, so `::` is
the only case.

## 10. `export` sits on its own line above a value's type signature

A value/function declaration's `export` modifier goes on its **own line**,
above the type signature — never collapsed onto it. Collapsing reads as though
you're exporting *a type* `name : T` rather than marking the binding exported
(the same reasoning Idris uses for `export`/`public export` on their own line).
The formatter applies this: `export` over a value signature stays split, while
`export data`/`export impl` *do* collapse onto one line — those genuinely are
type-level exports, so `export data Foo = …` reads correctly.

```
-- GOOD: export on its own line above a value signature
export
runParser : Parser a -> String -> Result String a

-- GOOD: export collapsed for a type-level declaration
export data Parser a = Parser (Array Char -> Int -> PResult a)
```

## 11. Sequencing vs transforming — `do` for monads, `map`/`filter`/`|>` for collections

Medaka has two orthogonal sequencing mechanisms; **the form should match the
intent**, and there is exactly one spelling for each:

- **Effect sequencing** → a **bare indented block**. Statements in a plain block
  run in order, sequenced by their `<E>` effects (IO/Mut/…). No keyword.
- **Monadic sequencing** → a **`do` block**, where `x <- e` binds a value out of a
  `Thenable` monad (`Result`/`Option`/`Parser`/…). `<-` lives *only* in a `do`
  block — the `do` keyword is the deliberate delimiter that tells the reader (and
  the compiler) "this block is monadic, not plain imperative."
- **Collection transforming** → `map`/`filter`/`flatMap`/`|>`. A data
  transformation is not "sequencing"; spell it as a pipeline, not a `do` block.

There is no `?` operator and no list comprehension — both were removed as
redundant special forms (a `?` is just a `<-`; a comprehension is just
`filter |> map`). Don't reach for either; they no longer parse.

For a `Result`/`Option`, pick the lightest form that fits, and only `match` when
you actually *use* the failure:

- **`map f x`** — one pure transform of the success (`Err`/`None` passes through).
- **`flatMap f x`** / **`andThen x f`** — one fallible step feeding another.
- **`do` + `<-`** — a chain of fallible steps that thread values.
- **`match`** — *only* to do something with the failure: transform it
  (`Err e => Err "header: \{e}"`), recover, or branch on it. A pass-through arm
  (`Err e => Err e`) means you wanted one of the forms above.

An effect statement inside a `do` block is written **`let _ = effectfulCall`**,
never bare — a bare statement is a monadic `>>` and must be in the block's monad,
so an `<IO>`/`<Mut>` call is rejected; `let _ =` stays a plain let and the block
types as `<e> Result _`.

```
-- BAD: pass-through match repackages the error; comprehension/`?` removed
findTable db name = match readSchema db
  Err e => Err e
  Ok entries => findTableGo name entries

-- GOOD: combinator for one step; do/<- for a chain; let _ = for an effect
findTable db name = flatMap (findTableGo name) (readSchema db)

scanRows db name = do
  entry <- findTable db name
  let _ = writeHeader entry        -- <Mut>; bare would fail in a do block
  decode entry

-- GOOD: a collection transform is a pipeline, not a do block
namesIn xs = filter inScope xs |> map nameOf

-- match stays ONLY where the error is transformed
openDb path = match readFileBytes path
  Err e => Err "readFileBytes: \{e}"   -- does something with the error
  Ok bytes => fromBytes bytes
```
