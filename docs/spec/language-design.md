# Medaka Language Design Document
*A pragmatic, modern functional programming language*

**Status:** PARTIAL — design rationale/philosophy (mostly current), plus an
"Implementation Roadmap" section that fully completed 2026-06-26 (OCaml
retired, native canonical — see `LIB-REMOVAL-DESIGN.md`) but is written entirely
in forward tense with no completion marker.

> ⚠️ **NON-NORMATIVE — `SYNTAX.md` is the ground-truth ledger of what the
> current binary actually accepts, and wins whenever the two disagree.** This
> document is intent and rationale, and deliberately includes aspirational
> features never built. In particular: the "Product Types (`record`)" section
> below teaches a standalone `record` keyword that **does not exist** — write
> `data X = { … }` (SYNTAX.md: "There is no separate `record` keyword"). The
> "Mutability and Passing Values" section teaches `let mut` extensively as
> current syntax; `let mut` **has been removed** (SYNTAX.md: "a parse error
> pointing at `Ref`"). If you're about to write code from what you read here,
> check it against SYNTAX.md first.

---

## Vision & Philosophy

This language is best described as sitting at the intersection of three existing languages:

- **A modernized, cleaned-up OCaml** — keeping strict evaluation and pragmatism, replacing dated syntax and the object system
- **A practical Haskell** — keeping the type system and syntax elegance, removing laziness and the IO monad tax
- **A more functional, garbage-collected Rust** — keeping the trait/typeclass model and algebraic data types, removing the borrow checker complexity

The north star: **the language a pragmatic functional programmer would design if they could start fresh today.** Informed by research languages (OCaml, Haskell, Idris), not beholden to them. Every feature must earn its complexity in practical daily use.

**Key design filter:** *Does this feature earn its complexity in practical use, or is it just theoretically neat?*

### One Language, No Extensions
Medaka has no language extensions, no compiler pragmas that alter semantics, and no opt-in type system features. Every feature is either in the language or it isn't. No pragma at the top of a file changes how the language works.

This is a direct rejection of Haskell's extension system, where enabling `OverloadedStrings`, `TypeFamilies`, `UndecidableInstances`, `RankNTypes`, `GADTs` etc. effectively creates a family of related but different languages. The consequences of that approach are real:
- Code is harder to read without knowing which extensions are active
- Libraries impose their extension choices on users
- The learning curve is multiplied
- Tooling and error messages become harder to reason about

In Medaka, features that didn't make the cut (GADTs, existential types, dependent types) are simply absent — not available via an opt-in flag. The language you learn is the language everyone uses.

The closest parallel is Go, which is famously rigid about this. It's one of Go's most quietly important design decisions and one worth emulating.

### Influences
- **OCaml** — strict evaluation, pragmatic side effects, practical functional programming
- **Haskell** — type system, typeclasses, syntax, higher-kinded types, do-notation
- **Idris** — cleaned-up Haskell syntax, named interface instances, modern design sensibilities
- **Rust** — traits/typeclasses, ADTs, module system, Result-based error handling
- **Elm** — record syntax, friendly error messages, accessibility of concepts
- **F#** — practical ML-family language targeting a real ecosystem

---

## Type System

### Core
- **Hindley-Milner with System F** parametric polymorphism
- Full **type inference** — type annotations are optional in most cases
- **Higher-kinded types** — the one advanced feature, justified by enabling user-defined abstractions like `Functor`, `Monad`, `Traversable`
- "**If it compiles, it runs**" — a core property inherited from the HM family

### Interfaces (Typeclasses)
- Called **interfaces**, not typeclasses (more accessible terminology)
- Full Haskell-style power, including higher-kinded types
- Enables user-defined `Functor`, `Monad`, etc. — monads are available as a pattern, not mandatory

### Named Instances with Defaults
Solves Haskell's coherence problem without sacrificing inference:

- One instance → resolved automatically
- Multiple instances → one can be marked `default`, used unless annotated otherwise
- Multiple instances, no default → compiler requires explicit annotation
- Overlapping instances where one is *strictly more specific* (e.g.
  `impl Eq (List Int)` alongside `impl Eq (List a)`) → resolved by
  **most-specific-wins**: each call site commits the most specific matching
  impl, with no `default` marker needed. Instances that overlap but where
  neither is more specific (`Conv Int a` vs `Conv a Bool`), or exact
  duplicates, are rejected at declaration time (reported at a source line).
  `default` remains the tiebreaker when overlapping impls are incomparable.

```
interface default Additive of Monoid Int where ...
interface Multiplicative of Monoid Int where ...

sum [1, 2, 3]              -- uses Additive automatically
fold @Multiplicative [1, 2, 3]  -- explicit opt-out
```

This eliminates the `newtype` hack entirely.

### How impl resolution reaches runtime

Resolution is *order-independent*: the type checker commits the chosen impl at
each call site (most-specific-wins, `@Name` hint, or `default` tiebreaker), and
the evaluator honours that choice rather than guessing from a runtime value.
Two cooperating mechanisms make this sound even when the discriminating type is
in *result* position (e.g. `fromInt : Int -> a`, `pure : a -> f a`) or a
non-first interface parameter, where no argument's runtime tag could pick the
impl:

- **At concrete call sites** the checker stamps the resolved impl's canonical
  key onto the method occurrence; eval narrows the method's dispatch table to
  that one impl. (`(fromInt 3 : Float)` runs the `Float` impl, not the first
  registered one.)
- **In polymorphic code** — a `Num a => … a` helper, a generic container
  function — the discriminating type isn't known until a caller fixes it, so the
  compiler uses **dictionary passing**: a constrained function takes a hidden
  dictionary argument per constraint, and method calls in its body consult that
  dictionary. The caller supplies the concrete dictionary (when it knows the
  type) or forwards its own (when it's itself still generic). Dictionaries are
  lightweight — just the identity of the chosen impl — so this reuses the same
  resolution machinery rather than duplicating it.
- **Method-level constraints** — a constraint on an interface method's *own*
  signature, e.g. `foldMap : Monoid m => (a -> m) -> t a -> m` — are dictionaries
  too. Such a method is dispatched on its interface type (`t`, by the container
  argument) *and* carries a `Monoid m` dictionary for the constraint on `m`;
  inside its default body a return-position method like `empty` resolves through
  that dictionary. The caller supplies it the same way as for a constrained
  function (concrete key when `m` is fixed, forwarded when the caller is itself
  `Monoid m =>`), so `foldMap MkSum xs : Sum` folds with the user's `Sum` monoid
  rather than the first registered one.

### Friendly Naming
Abstract concepts get accessible names:
- `interface` instead of typeclass
- `Option` / `Some` / `None` instead of `Maybe` / `Just` / `Nothing`
- `Mappable` instead of `Functor` (where surfaced to users)
- `flatMap` / `andThen` as primary operation names rather than `>>=`

### Explicitly Out of Scope
- GADTs
- Existential types
- Dependent types
- Row polymorphism (structural records). Field-name reuse across record types
  is supported via receiver-type-directed resolution; structural abstraction
  over "any record with field `x`" is intentionally declined so it does not
  compete with interfaces. See *Field-name reuse and the decision against row
  polymorphism* under Product Types.
- Anything that significantly damages inference or error message quality

### Error Message Quality
First-class design goal. Elm-style friendly, actionable error messages. The compiler should explain what went wrong and why, not just dump a type unification failure.

---

## Syntax

### General Principles
- **Indentation-sensitive** (Haskell/Idris/Python style) — no braces for blocks
- **Expression-oriented** — everything is an expression
- **Declarative** — functions defined by pattern matching, not imperative steps
- **Accessible** — no insider notation, names over symbols

### Type Annotations
Idris-style single colon:
```
x : Int
greet : String -> String
add : Int -> Int -> Int
```

### Function Definition
Declarative pattern matching style — no `match` keyword needed:
```
factorial : Int -> Int
factorial 0 = 1
factorial n = n * factorial (n - 1)

head : List a -> Option a
head []     = None
head (x::_) = Some x
```

#### Guards

Equation heads, `where`-bindings, and `match` arms may carry guards. A guard is a
comma-separated sequence of qualifiers; the arm fires only when every qualifier
succeeds, otherwise control falls through to the next arm. Each qualifier is either a
boolean test or a **pattern bind** `pat <- expr` (the arm is skipped if the pattern
doesn't match). Bindings introduced by an earlier qualifier are in scope for later
qualifiers and the body:
```
classify : Int -> String
classify n
  | n < 0     = "neg"
  | n > 0     = "pos"
  | otherwise = "zero"

filterMap : (a -> Option b) -> List a -> List b
filterMap f [] = []
filterMap f (x::xs)
  | Some y <- f x = y :: filterMap f xs
  | None  <- f x  = filterMap f xs
```
The same qualifiers work in `match` arms, after `if`:
```
describe o =
  match o
    n if Some y <- n, y > 0 => "some-pos"
    _                       => "other"
```

### Currying
Functions are curried by default. Partial application falls out naturally:
```
add : Int -> Int -> Int
add x y = x + y

addFive : Int -> Int
addFive = add 5

result = map (add 5) [1, 2, 3]  -- [6, 7, 8]
```

Tuples are regular data, not special argument syntax. Passing multiple values as a unit means wrapping in a tuple explicitly.

### Lambda Syntax
Fat arrow `=>` for lambda bodies, thin arrow `->` reserved for type signatures:
```
x => x + 1
(x, y) => x + y

-- distinction is clear at a glance
add : Int -> Int -> Int    -- type signature
add = (x, y) => x + y     -- lambda
```

### Operators
- **Fixed set of built-in symbolic operators:** `+`, `-`, `*`, `/`, `==`, `<`, `>`, `&&`, `||`, `::` (cons), `++` (append), etc.
- **No custom symbolic operators** — eliminates unreadable operator soup
- **Named functions can be used infix** via backticks:

```
x `div` y
x `andThen` f
3 `elem` [1, 2, 3]
```

Functions always have real names. Infix is a calling convenience, not a way to invent hieroglyphics.

### Pipe and Composition Operators

Three operators, three unambiguous meanings:

```
-- |> pipe: apply a value through a pipeline
"alice" |> toUpper |> trim |> greet

-- >> composition: build a reusable function pipeline (left to right, F#/OCaml style)
let processName = toUpper >> trim >> greet
processName "alice"

-- << composition: right to left (available but less idiomatic)
let processName = greet << trim << toUpper

-- . dot: field access and module access only, always
person.name
utils.greet
```

**Dot is never function composition.** This is an explicit departure from Haskell, where `.` is the composition operator — a decision that confuses anyone coming from virtually any other language. In Medaka, `.` means one thing: access. `>>` and `<<` handle composition, following F# and OCaml conventions.

### Do Notation
General monad abstraction, not tied to effects. **The `do` keyword is required** to introduce a monadic block — bare indented blocks are sequential procedural blocks, not monadic ones.

```
result = do
  x <- computation1
  y <- computation2 x
  pure (x + y)
```

`do` is for abstracting over monadic patterns (Option, Result, custom monads) — not a required wrapper for side effects.

**Bare blocks vs `do` blocks.** Medaka distinguishes two kinds of indented blocks:

- **Bare sequential blocks** (function bodies, `if`/`else` branches, match-arm bodies, any indented multi-statement block without a `do` keyword): purely sequential evaluation. Allowed statements: `let` (immutable declaration), expression statements (including `Ref` writes `x := e`), field assignment (`x.f = e`), `let else`. **`<-` is forbidden.** Bindings are immutable — a bare reassignment `x = e` is an error, and `let mut` is not a construct (use a `Ref`).
- **Monadic `do` blocks** (introduced by the explicit `do` keyword): every statement is sequenced through monadic bind. Allowed statements: `let`, `<-` bind, expression statements (each must unify to `m a`), `let else`. **Reassignment and field assignment are forbidden** — monads are for computational composition, not in-place mutation.

If you write `<-` inside a bare block, the typechecker emits a clear error pointing you at the `do` keyword.

### `if let` and `let else`

Two sugars for the common pattern of binding through a single-constructor match.

`if let` binds when the pattern matches, with an `else` branch for the no-match case:
```
if let Some name = lookup id users then
  greet name
else
  print "no user"
```

`let else` is a refutable binding that *must* match — the `else` branch must diverge (return early, panic, etc.):
```
fetchProfile : Int -> Result Profile Error
fetchProfile id =
  let Some user = lookup id users else
    return Err NotFound
  let Ok prefs = readPrefs user else
    return Err CorruptPrefs
  Ok (Profile user prefs)
```

Both are strictly sugar — they desugar to `match`. They exist because the single-arm extraction pattern is too common to spell out in full every time, and a full `do`-block is heavy when you want one variable.

### Recursion and `let rec`

Function definitions are implicitly self-recursive — `factorial n = n * factorial (n - 1)` works without any keyword:

```
fact n = if n == 0 then 1 else n * fact (n - 1)
```

Plain value bindings are **not** recursive. `let x = ... x ...` is an error because Medaka evaluates strictly — without lazy thunks, a self-referencing value either loops forever or produces nonsense. Forgetting this gets a targeted diagnostic suggesting `let rec`.

For explicit value recursion and mutual recursion, use `let rec ... with ...`:

```
-- single recursive value (must be a lambda)
let rec fact = n => if n == 0 then 1 else n * fact (n - 1)

-- mutually recursive at the top level
let rec is_even = n => if n == 0 then True else is_odd (n - 1)
with is_odd  = n => if n == 0 then False else is_even (n - 1)

-- inline form (single line)
sum = let rec go = acc => xs => match xs
  []      => acc
  x :: rest => go (acc + x) rest
in go 0 [1, 2, 3]
```

`with` is the binding-group separator. `and` is deliberately not used because it's a stdlib function for short-circuit-free boolean conjunction; reclaiming it would break existing code.

**Lambda-only restriction on value RHS.** Inside a `let rec` group, a clause with no formal parameters must have a lambda right-hand side. This is stricter than OCaml's "syntactic value" rule because Medaka's strict evaluator has no special support for cyclic data structures — `let rec ones = 1 :: ones` would silently produce `Cons(1, Unit)` (a placeholder cell) rather than a cyclic list. The typechecker rejects this case explicitly.

Mutual recursion between *functions* declared as ordinary top-level `f x = ...` is already implicit (top-level names are all in scope in each other's bodies through closure capture). `let rec ... with ...` is what you reach for when you need mutual recursion between *values* — including lambdas not declared in function-definition form.

### `function` Keyword

A one-argument lambda that immediately pattern-matches:
```
filter (function
  | Some x => x > 0
  | None   => false
) results
```

Equivalent to `(x => match x with Some x => x > 0 | None => false)`. Restricted to a single argument to keep the desugar trivial; for multi-argument matches, use `match` directly.

### Range Literals

`1..10` is the half-open range `[1, 10)`. `1..=10` is the inclusive range `[1, 10]`. Ranges work in three places:

```
-- as collections
[1..10]              -- List Int: [1, 2, ..., 9]
[|1..=100|]          -- Array Int: [|1, 2, ..., 100|]

-- in slicing
chars[0..5]          -- substring

-- in patterns
match c
  'a'..='z' => Lower
  'A'..='Z' => Upper
  '0'..='9' => Digit
  _         => Other
```

The pattern-match case is the highest-value: it replaces ugly chains of `&&` guards with a syntactic form the exhaustiveness checker can reason about.

---

## Data Types

### Sum Types (`data`)
```
data Shape
  = Circle Float
  | Rectangle Float Float
  | Triangle Float Float Float

area : Shape -> Float
area (Circle r)      = pi * r * r
area (Rectangle w h) = w * h
```

#### Variants with Named Fields
For variants carrying multiple payloads, named fields are clearer than positional ones. A variant can use record-style syntax inline — no separate `record` declaration required:
```
data Event
  = Click { x : Int, y : Int }
  | KeyPress { key : Char, shift : Bool }
  | Scroll Int

handle : Event -> <IO> Unit
handle (Click { x, y })          = println "click at \{debug x},\{debug y}"
handle (KeyPress { key, shift }) = println "key \{debug key} (shift=\{debug shift})"
handle (Scroll n)                = println "scroll \{debug n}"
```

Field punning works in patterns (`{ x, y }` is shorthand for `{ x = x, y = y }`). Positional variants and named-field variants can coexist in the same `data` declaration. Field names are namespaced to the variant.

### Product Types (`record`)
```
record Person
  name : String
  age  : Int
```

- **Dot access** for fields: `person.name`
- **Immutable update syntax** (Elm-style):
  ```
  let p2 = { p | age = 31 }
  ```
- **Nested update sugar** — dotted paths on the left of `=`:
  ```
  let p2 = { p | address.city = "Boston" }
  ```
  Equivalent to `{ p | address = { p.address | city = "Boston" } }`. The path can only appear on the LHS; the RHS is a plain expression.
- **Construction requires all fields** — no partial construction, no runtime surprises
- **Fields are namespaced** to the type — no global namespace pollution

#### Field-name reuse and the decision against row polymorphism

Because fields are namespaced to their type, two record types may declare the
same field name:

```
record Person
  name : String

record Company
  name : String
```

Field access resolves by the **record type inferred for the receiver**: in
`p.name` the compiler already knows `p : Person`, so `name` resolves to
`Person.name`. There is no global field namespace, so no collision arises.

When a field name is declared by **only one** record, access still resolves
even if the receiver's type isn't yet known — the single owner drives
inference (`getName p = p.name` infers `p : Person`). When a field name is
**shared** by several records, the receiver's type must be determinable at the
access site; otherwise the compiler reports an *ambiguous field access* error.
The receiver type is known when it comes from construction (`(Person { … }).name`)
or an annotation (`(p : Person).name`). A top-level function signature does
**not** yet disambiguate (`getName : Person -> String; getName p = p.name`
fails on a shared field), because signatures are unified against the body
*after* it is inferred rather than pushed into the parameters — see the
bidirectional-checking phase (Phase 73) in PLAN-ARCHIVE.md.

We deliberately stop there. We do **not** support *row polymorphism* — i.e.
inferring `\r => r.x` as "any record with a field `x`" via row variables. That
would add a second, *structural* axis of abstraction ("any value shaped like
`{ x, .. }`") alongside our existing *nominal* one (interfaces / typeclasses).
The two overlap heavily for "abstract over things that have capability X," and
carrying both fractures the language into two idioms for the same job. Medaka's
abstraction-over-capability mechanism is the interface; records stay concrete.

This is a conscious narrowing, not an oversight:

- The practical pain we needed to fix was field-name *reuse* across record
  types — receiver-type-directed resolution solves that completely.
- "Haskell doesn't have row polymorphism" is sometimes cited as a reason to
  skip it, but the honest reading is the opposite: Haskell's pre-`HasField`
  record story (no field reuse at all) is widely regarded as one of its weakest
  features, and PureScript added rows specifically to fix it. We take the
  lesson as *fix field reuse* (done above) while *declining* the structural
  abstraction that competes with interfaces.
- It is not a one-way door. If a concrete program ever needs polymorphic
  `\r => r.x` that an interface method genuinely cannot express, row variables
  can be layered onto `mono` later. Shipping them speculatively and walking
  them back would be far costlier.

### Combining Them
```
record Point2D
  x : Float
  y : Float

data Shape
  = Circle Float
  | Rectangle Float Float
  | Positioned Point2D Float
```

`data` and `record` are kept clearly separate. Pattern matching on `data` is always positional. Named field access is always through `record` via dot notation.

---

## Error Handling

No exceptions. Two distinct categories:

### Recoverable Errors → `Result`
```
divide : Int -> Int -> Result Int String
parseJson : String -> Result Json ParseError

match divide 10 0
  Ok n    => print n
  Err msg => print msg
```

Errors are data. Pattern match to handle them. Library authors cannot be lazy and throw — they must model failure explicitly.

#### `do`-notation — Sequencing Fallible Steps
A `do` block sequences a value-level monad (`Result`/`Option`/`Parser`/…). `x <- e` binds the
success out of the monad and short-circuits the failure (an `Err`/`None`) to the whole block:
```
parseConfig : String -> Result Config String
parseConfig path = do
  raw    <- readFile path     -- on Err, the do-block returns that Err
  parsed <- decode raw
  validate parsed

lookupAge : String -> Map String Person -> Option Int
lookupAge name m = do
  p <- mapLookup name m       -- on None, the do-block returns None
  Some p.age
```

A `do` block desugars to nested `andThen`/`pure`. `<-` lives only inside `do` — the keyword is the
deliberate delimiter that marks a block as monadic rather than plain imperative (a bare indented block
sequences *effects*, not a monad). An effect statement inside a `do` block is written `let _ =
effectfulCall` (a bare statement would be a monadic `>>` and is required to be in the block's monad).
There is no postfix `?` operator — it was removed as a redundant spelling of `<-`.

### Unrecoverable Errors → `panic`
For genuine invariant violations, index out of bounds, stack overflow — situations where the program cannot reasonably continue. `panic` is an ordinary primitive (`String -> a`), not an effect label — it carries no row annotation (see Effects).

---

## Effect System

### Philosophy
Pure by default. Effects are explicit in type signatures. No IO monad infection — you don't have to rewrite your entire call stack to use a side effect deep in your program.

A small, fixed set of built-in effects tracked by the compiler. Not a full algebraic effect system — practical benefit without the complexity tax.

### Built-in Effects
```
IO      -- file system, network, console
Async   -- asynchronous computation
Rand    -- randomness / nondeterminism
Time    -- current time / clock access
```

Every effect label is a host capability — there is no internal/purity-tracking
label class. Mutation (via `Ref`/`:=`) and `panic` are untracked: they carry no
effect row (see "Mutability" and "Unrecoverable Errors" above).

### How It Works
Effects appear in type signatures:
```
readFile  : String -> <IO> String
divide    : Int -> Int -> Result Int String   -- pure, uses Result not Exn
fetchUser : String -> <Async, IO> User
roll      : <Rand> Int
now       : <Time> Timestamp

-- pure function — no annotation, compiler enforces purity
add : Int -> Int -> Int
```

### Rules
- **Pure by default** — no annotation means guaranteed pure, compiler enforced
- **Effects compose automatically** via inference — call an `<IO>` and `<Rand>` function, your function is inferred as `<IO, Rand>`
- **No manual annotation needed in most cases** — inference propagates effects up the call stack
- **Purity is a guarantee about host capabilities** — a function with no effect annotation genuinely cannot do IO, access the clock, etc. It says nothing about mutation: mutating a `Ref` is untracked, so a "pure" function may still mutate one.

### What This Gives You
- Know what any function can do just from its signature
- Pure functions are trivially testable
- Nondeterminism (`Rand`, `Time`) is visible and can be controlled in tests
- No exceptions — `Exn` replaced entirely by `Result` and `panic`

---

## Module System

Idris-inspired. Private by default, file structure mirrors module hierarchy.

```
-- src/utils.lang
export
greet : String -> String
greet name = "Hello, " ++ name

internal : String -> String  -- private, not exported
internal s = ...

-- src/main.lang
import utils.greet

main =
  print (greet "Alice")
```

The `export` keyword can appear on its own line before a declaration (Idris style) or inline:

```
-- standalone export (Idris style)
export
toList : BTree a -> List a
toList Leaf = []
toList (Node l v r) = toList l ++ (v :: toList r)

-- inline export (equivalent)
export toList : BTree a -> List a
toList Leaf = []
toList (Node l v r) = toList l ++ (v :: toList r)
```

### Rules
- **Private by default** — explicitly `export` to make public
- **File/directory structure = module hierarchy** — intuitive, no separate declaration
- **`import` for imports** — clean and explicit
- **No circular dependencies** — enforced by compiler
- **No first-class modules or functors** — OCaml-style complexity explicitly rejected

### Abstract Type Exports

For data types, `export` exposes only the **type name** — constructors stay private to the defining module. To additionally expose constructors, use `public export`. This follows Idris's visibility model directly:

```
-- in collections/map.mdk

-- abstract: users see the type, can't pattern-match or construct directly
export data Map k v
  = Empty
  | Node k v (Map k v) (Map k v)

export lookup : Ord k => k -> Map k v -> Option v
export insert : Ord k => k -> v -> Map k v -> Map k v
```

```
-- in user code
import collections.map.{Map, lookup, insert}

m : Map String Int
m = empty |> insert "alice" 30   -- fine, uses the public API

-- compile error: constructor `Node` not exported from collections.map
bad m = match m with Node _ v _ _ => v | _ => 0
```

When you genuinely want constructors public — for transparent ADTs like `Option`, `Result`, `Ordering` — use `public export`:

```
public export data Option a = Some a | None
public export data Result e a = Ok a | Err e
```

The same applies to `record` types: `export record Foo` exposes the type name; `public export record Foo` additionally exposes the fields (for construction, dot access, and update syntax). An abstractly-exported record can only be used via the operations the defining module chooses to expose.

**Why default-abstract:** library invariants (`Map` balance, `NonEmpty` non-emptiness, `Email` well-formedness) need compiler enforcement, not convention. Defaulting to abstract pushes authors toward designing a public API; defaulting to concrete bakes the representation into every call site. The cost is one extra word (`public`) when you want full transparency.

Derived instances survive abstract export: `deriving (Debug, Eq)` on an abstract type still gives downstream users working `debug` and `eq` — only pattern matching and direct construction are gated.

### To Be Decided (follow Rust's lead)
- Selective imports: `import utils.{greet, helper}`
- Wildcard imports: `import utils.*`
- Qualified imports: `import utils` then `utils.greet`
- Re-exports for clean public APIs

---

## Implementation Plan

> **HISTORICAL — this roadmap completed in full 2026-06-26.** It reads as a
> live forward plan below, but every phase (through "Phase 4: retire OCaml
> implementation") executed; Medaka now self-hosts on a native LLVM backend
> with OCaml fully removed. See `compiler/BOOTSTRAP.md` for the real
> completion log and `LIB-REMOVAL-DESIGN.md` for the removal record.

### Phase 1: OCaml-hosted compiler + Tree-sitter grammar
- Write the compiler in OCaml (fitting given the influence, and Rust did the same initially)
- Transpile to OCaml or interpret directly
- Focus entirely on nailing language design — type system, syntax, semantics
- Do not optimize for performance, codegen, or multiple architecture targets
- **Tree-sitter grammar in parallel** — purely syntactic, no type checker needed, gives syntax highlighting in VSCode immediately. Writing the grammar formally also benefits the parser design.

### Phase 2: REPL
- Interactive read-eval-print loop
- Forces clean incremental typechecking and evaluation
- Makes language features immediately explorable and testable
- Essential for developing the standard library interactively
- Good for motivation — the language feels alive early

### Phase 3: Basic LSP
- Error reporting only — red squiggles for type errors
- Needs a working type checker but nothing more
- Ships as part of the blessed toolchain (`medaka lsp`)
- Makes day-to-day development significantly more pleasant early

### Phase 4: Standard Library
- Implemented in Medaka itself, on top of `extern` primitives
- Developed and tested interactively via the REPL
- Stress tests the type system, interfaces, and collections design

### Phase 5: Proof of Concept Projects
In order:
1. **Web server framework** — stress tests effects, `<Async>`, `<IO>`, monads, do-notation, JSON. The real world test of whether the effect system earns its keep.
2. **Additional projects** — driven by what the language needs at that point

### Phase 6: Rich LSP
- Go-to-definition, autocomplete, hover for type signatures, find references
- Requires the compiler to track source spans carefully throughout — design for this from day one even if implementation comes later
- Added incrementally once the language is stable enough that the AST isn't changing constantly

### Phase 7: Revisit backend if warranted
Once the language design is stable and the project feels worth continuing:
- **LLVM** is the likely long-term target for native compilation
- Could also explore self-hosting — writing the compiler in the language itself
- The `extern` abstraction layer makes this transition clean (see Runtime Primitives)
- JVM remains an option if ecosystem access becomes a priority

### Non-goals (for now)
- Performance optimization
- Multiple architecture targets
- Production-ready GC
- Package ecosystem

---

## Standard Library Philosophy

### Core Principle
Batteries included — a rich standard library so most things are available out of the box without reaching for third party packages. Consistent interfaces across all collection types — `map`, `filter`, `fold` work the same way on everything via shared interfaces (`Mappable`, `Foldable`, etc.).

### Collections Hierarchy

#### List — the default sequential collection
Linked list. Immutable. The conceptual entry point for learning Medaka and the natural collection for functional programming. Pattern matches beautifully, structurally recursive. Reach for it when performance isn't a concern.

```
-- natural pattern matching
sum : List Int -> Int
sum []      = 0
sum (x::xs) = x + sum xs

-- standard operations
map (x => x + 1) [1, 2, 3]
filter (x => x > 2) [1, 2, 3]
```

#### Array — immutable, cache-friendly sequential collection
For performance-sensitive code, random access, numeric work. Immutable by default. Array literal syntax: `[|1, 2, 3|]` (borrowed from OCaml, visually distinct from list literals).

```
let arr = [|1, 2, 3|]
arr[0]                        -- 1
map (x => x + 1) arr         -- [|2, 3, 4|], same interface as List
```

#### MutArray — mutable array
Opt-in mutability for performance. The cell is mutable; the binding is immutable. Mutation is untracked — it carries no effect row.

```
let arr = MutArray [|1, 2, 3|]
arr[0] = 5                    -- index assignment, mutates in place
```

Conversion between Array and MutArray:
```
freeze : MutArray a -> Array a   -- zero cost, type change only
thaw   : Array a -> MutArray a   -- copies
```

#### Map — immutable tree map
Persistent, structurally shared updates. Efficient for immutable update patterns. Keys require `Hashable` interface.

```
let m = Map { "alice" => 30, "bob" => 25 }
m["alice"]                        -- Some 30
m["charlie"]                      -- None, never a runtime error
m `insert` ("charlie", 35)        -- returns new Map, cheap via structural sharing
```

#### HashMap — mutable hash map
Hash-based, mutable. Its mutating operations are untracked — no effect row. Faster for update-heavy code.

```
let m = HashMap { "alice" => 30 }
m `insert` ("charlie", 35)        -- mutates in place
```

#### Set and HashSet
Same immutable/mutable distinction as Map/HashMap:
- `Set` — immutable tree set
- `HashSet` — mutable hash set (mutating ops are untracked, no effect row)

### Mutability Rules
Universal and consistent across all collection types and bindings:

**Bindings are immutable. Mutation lives in a `Ref` cell.** Mutation is
untracked by the effect system — writing a `Ref` carries no effect row. There
is no mutable binding form — `let mut` has been removed, and a bare
reassignment `x = e` of an already-bound name is an error. `=` (with
`let`, or at the top level) is *declaration only*.

```
let x = 5                              -- immutable binding
x = 6                                  -- ERROR (R-IMMUTABLE-ASSIGN): reassignment
let x = 6                              -- OK: shadowing declares a NEW binding

let count = Ref 0                      -- an immutable binding of a mutable CELL
count := count.value + 1               -- `:=` writes the cell; read with `.value`
println count.value                    -- => 1

let p = Person { name = "Alice", age = 30 }     -- immutable record
p.age = 31                             -- field assignment (in-place record mutation)
```

`Ref` is the single mutation primitive:
- construct — `Ref v` (type `a -> Ref a`)
- write — `x := e` (surface sugar for `setRef x e`, type `Ref a -> a -> Unit`)
- read — `x.value`

Mutation is untracked: a function that writes a `Ref` carries no additional
effect in its inferred type signature — the effect system tracks host
capabilities only.

Practical benefit: grep a codebase for `Ref` / `:=` and find every place mutation
is introduced.

### Strings

**Encoding:** UTF-8 internally.

**Abstraction:** Strings are sequences of grapheme clusters, not bytes or code points. `Char` represents a grapheme cluster. No integer indexing — `str[0]` is a compiler error, not a runtime footgun.

```
length "hello"       -- 5
length "👋🏽"         -- 1 (one grapheme cluster, not 4 bytes)
chars "hello"        -- ['h', 'e', 'l', 'l', 'o']
bytes "hello"        -- [|104, 101, 108, 108, 111|]
slice "hello" 1 3    -- "ell"
```

String literals use double quotes. Multiline strings strip leading indentation:
```
let s = "hello"
let multiline = "
  this is
  a multiline string
  "
```

String interpolation uses `\{expr}` — the same escape-sequence model as `\n`, `\t`, `\u{XXXX}`. Each hole `\{e}` desugars to `display e`, so the embedded expression only needs a `Display` instance — no explicit `debug`:
```
greeting = "Hello, \{name}!"
summary  = "Count: \{n}, total: \{total}"
```
`Display` is the user-facing half of the `Debug`-vs-`Display` split: unlike `debug`, it does *not* quote `String`/`Char` (interpolating a string splices its characters), and it renders every other type the same as `debug` while recursing with `display` so nested strings stay unquoted. The base instances live in `core.mdk` (interpolation is core syntax, so they can't depend on an imported module); user types get one via `deriving (Display)`. A hole whose type has no `Display` instance is a type error. Unescaped `{` is always literal.

**Why no indexing:** String indexing by integer is almost always a bug waiting to happen in non-ASCII text. Elm takes this approach and it's been validated in practice. Interact with strings through functions — honest about what strings actually are.

**Strings are not generic collections.** `String` (and `ByteString`) deliberately do *not* implement `Mappable`, `Foldable`, or the rest of the shared collection interfaces. To use those operations on a string, convert explicitly:

```
name |> toList |> filter isAlpha |> fromList
```

Two reasons:

1. **Semantic honesty.** A grapheme-cluster sequence is not the same shape of thing as `List a`. Mapping over graphemes can produce sequences that re-cluster differently; filtering can break combining-character invariants. Pretending `String` is just another `Mappable` glosses over this. Forcing explicit conversion makes the user acknowledge "I am treating this as a sequence of characters" — the same instinct behind banning integer indexing.
2. **Allocation visibility.** `chars`/`toList` allocates. The explicit conversion makes that cost visible at the call site instead of hiding it behind a uniform interface.

The corollary is that the `String` module itself must be rich enough that reaching for `toList` is rare. Text-shaped operations (`toUpper`, `trim`, `split`, `replace`, `contains`, `startsWith`, `count`, `any`, `all`, `find`) live directly on `String`. Conversion is reserved for genuinely character-sequence-shaped work.

This is also why Medaka does not need associated types or `Collection c e`-style multi-parameter interfaces: the generic interfaces stay restricted to parametric containers where HKT works naturally, and monomorphic containers stand on their own.

### Naming Conventions
- Collection operations are consistent: `map`, `filter`, `fold`, `insert`, `remove`, `contains`
- Backed by shared interfaces (`Mappable`, `Foldable`, etc.) so switching between collection types is low friction — change the data structure, operations stay the same
- Simple, unsurprising names throughout — no Haskell-style operator soup

## Async

`Async` is a monad, not special runtime syntax. Do-notation handles sequencing naturally:

```
fetch : String -> <Async> Response
parse : Response -> <Async> Json

result : <Async> Json
result = do
  response <- fetch "https://api.example.com"
  json <- parse response
  pure json
```

The friendly name for the monad interface is **`Thenable`** — familiar to JS developers, descriptive, not academic.

`<Async>` is still tracked as an effect even though it's monad-based. The effect tag and the monad are two views of the same thing — the effect tells you a function can kick off async work, the monad is how you compose it. Consistent with the rest of the effect system.

---

## Module System — Import Details

```
-- selective imports
import utils.{greet, helper}

-- wildcard (available but discouraged in style guides)
import utils.*

-- qualified (no names brought into scope)
import utils
utils.greet "Alice"

-- re-exports (for clean public APIs)
export import list.{map, filter, fold}

-- aliased imports
import collections.HashMap as HM
```

Wildcard imports are available but style guides should discourage them — makes it hard to know where names come from.

---

## Standard Library

**Philosophy: batteries included, but not to an extreme.**

Rule of thumb: *"Would the absence of this cause every non-trivial project to immediately reach for a third party package?"* If yes → stdlib. If no → ecosystem.

Rough target: Go's stdlib scope, maybe slightly smaller.

### In stdlib:
- Core collections — List, Array, MutArray, Map, HashMap, Set, HashSet
- String utilities — split, trim, join, regex
- Math — standard numeric operations
- IO — file system, stdin/stdout
- Date/Time — too universally needed and historically painful to leave out
- JSON — too ubiquitous to omit
- Basic concurrency primitives
- Testing utilities — built-in test runner

### Left to ecosystem:
- HTTP client/server — too opinionated, let ecosystem compete
- Database drivers
- Serialization formats beyond JSON (YAML, TOML, XML etc.)
- Cryptography — too security-sensitive to get half right
- GUI
- Domain-specific libraries (ML, graphics, etc.)

---

## Mutability and Passing Values

### Value vs Reference Semantics
Medaka uses **value semantics by default** for primitive types — passing a mutable primitive to a function gives the function a copy, consistent with functional expectations. Mutable collections (`MutArray`, `HashMap`, `HashSet`) use reference semantics naturally since they are heap allocated.

```
-- primitives: value semantics, copy on pass
let mut x = 5
addOne x         -- x unchanged, function got a copy

-- mutable collections: reference semantics
let mut arr = [|1, 2, 3|]
fillZeros arr    -- arr is mutated, function got a reference
```

### The `Ref` Type
For the specific case of shared mutable state across multiple call sites, Medaka provides a `Ref` type — an explicit mutable cell. This is the escape hatch for when you genuinely need reference semantics on a primitive:

```
let x : Ref Int = Ref 5
increment x      -- x's contents are now 6
x.value          -- 6
```

The key distinction:
- `let mut x` — the *binding* can be repointed to a different value
- `Ref` — the *binding* is stable but the *contents* are mutable

**`let mut`, reassignment (`x = e`), and field assignment (`x.f = e`) are only allowed inside bare sequential blocks**, not inside a `do` block. Monads are for composing computational patterns, not for in-place mutation — mixing the two would muddle both. If you need mutation inside a function that also uses `do`, keep the `do` block scoped to the monadic piece and do the mutation in the surrounding bare block.

You can combine them:
```
let mut x : Ref Int = Ref 5   -- binding can be repointed AND contents mutable
let x : Ref Int = Ref 5       -- binding stable, contents mutable
let mut x : Int = 5           -- binding can be repointed, no shared mutation
```

Mutation via `Ref` is untracked by the effect system — a function that mutates a `Ref` carries no extra effect in its signature:
```
increment : Ref Int -> Unit
```

`Ref` makes shared mutable state explicit in the *type* (a `Ref a` argument or field), even though it's no longer surfaced in the effect row.

This is a fundamental design decision worth stating explicitly, as it resolves a tension that plagues Haskell.

### The Core Insight
Strict evaluation means **execution order is always well defined by syntax**. You don't need monads to sequence side effects — the language already sequences things top to bottom. This eliminates Haskell's "monad infection" problem entirely.

### What Monads Are For in Medaka
Monads and do-notation are for **abstraction over computational patterns**, not for containing or ordering effects:
- `Option` — chaining computations that might be absent
- `Result` — chaining computations that might fail
- `Async` — chaining asynchronous computations
- Custom monads — user-defined computational patterns

### What Effects Are For
The effect system tracks **what a function can do**, independently of whether monads are involved:
```
-- side effects just work, sequenced by evaluation order
greet : String -> <IO> String
greet name =
  let loud = String.toUpper name    -- pure, no ceremony
  println "What's your name?"       -- IO, just works
  let input = readLine ()           -- IO, just works
  pure (loud ++ input)

-- monads for computational abstraction, not effect sequencing
fetchAndProcess : String -> <IO, Async> Result Json Error
fetchAndProcess url =
  let response = await fetch url    -- IO + Async, just works
  do                                -- `do` keyword required for monadic block
    json <- parseJson response      -- Result chaining via do-notation
    pure (transform json)
```

### The Division of Responsibility
- **Effect system** answers: *"what does this function do?"*
- **Monads/do-notation** answers: *"how do I compose these computational patterns?"*

These are orthogonal tools for orthogonal problems. Neither steps on the other.

---

## Pipe Operator

The `|>` pipe operator is included as a first-class operator, following Elm, F#, and Gleam:

```
[1, 2, 3]
  |> map (x => x * 2)
  |> filter (x => x > 2)
  |> fold 0 (acc, x => acc + x)
```

This replaces Haskell's `$` operator (which is a workaround for the same problem) with something more readable and widely understood. Pipelines read left to right, matching the natural flow of data transformation.

---

## Stdlib Design Principles

Beyond the collections and modules already documented, a few explicit principles:

### No Partial Functions
The stdlib never exports functions that can crash on valid input. Every function that might not return a value returns `Option`. Every function that might fail returns `Result`.

```
-- this does not exist in Medaka stdlib
head : List a -> a          -- crashes on empty list, NEVER

-- this does
head : List a -> Option a   -- always safe
```

This is a direct lesson from Haskell's Prelude, which exports partial functions like `head`, `tail`, `fromJust` that undermine the "if it compiles it runs" guarantee.

### Consistent Naming Across Collections
`map`, `filter`, `fold`, `insert`, `remove`, `contains` work identically across `List`, `Array`, `Map`, `Set` etc. via shared interfaces. Switching collection types requires changing the data structure, not relearning the API.

Monomorphic containers (`String`, `ByteString`) are deliberately excluded from these interfaces — see the Strings section for the rationale. They expose their own text/byte-shaped APIs and require explicit `toList`/`fromList` for character-sequence work.

### No Orphan Instances
Interface instances must be defined either in the module that defines the type, or the module that defines the interface. Never in a third unrelated module. This prevents coherence problems and makes instance resolution predictable.

---

## Tooling

A single blessed build tool ships with the language from day one. No competing tools, no ecosystem fragmentation. Cargo and Go's toolchain are the reference points.

### Core Commands
```
medaka new myproject      -- create new project
medaka build              -- compile
medaka run                -- compile and run
medaka run --release      -- optimized build
medaka check              -- typecheck only, fast feedback
medaka check --json       -- machine readable output for tooling/AI agents
medaka test               -- run all tests
medaka test mymodule      -- run specific module
medaka fmt                -- format code (one blessed style, no arguments)
medaka lsp                -- start language server
medaka add somepackage    -- add dependency
medaka remove somepackage -- remove dependency
medaka update             -- update dependencies
medaka doc                -- generate documentation
medaka bench              -- run benchmarks
```

### Project Config
Cargo-style `medaka.toml` for project configuration, `medaka.lock` for reproducible builds.

### One Blessed Formatter
`medaka fmt` is the official style. No competing formatters, no style arguments. Gofmt proved this is the right call — a community with one style is healthier than a community fragmented by style wars.

### Structured Compiler Output
`medaka check --json` emits machine-readable errors for tooling and AI agent consumption. Building with AI-assisted development in mind from day one.

### Language Server
Ships with the toolchain, not a third party plugin. Provides syntax highlighting, inline type errors, go-to-definition, autocomplete. Tree-sitter grammar for fast, incremental syntax highlighting.

### Testing

The blessed test runner (`medaka test`) supports three flavours of test, all first-class:

**Example tests** — ordinary functions that return `Bool` or assert via `assertEq`:
```
test "factorial of 5" =
  factorial 5 == 120
```

**Property tests** — quantified over the type, generated automatically via a derivable `Arbitrary` interface:
```
prop "reverse is its own inverse" (xs : List Int) =
  reverse (reverse xs) == xs

prop "sort preserves length" (xs : List Int) =
  length (sort xs) == length xs
```
`Arbitrary` is derivable for any `data`/`record` whose fields are themselves `Arbitrary`. Shrinking is built in. This is the QuickCheck/Hypothesis lineage, made cheap by Medaka's HM types and `deriving` infrastructure.

**Doctests** — executable examples embedded in doc comments:
```
-- | Returns the first element of a list, if any.
--
-- > head [1, 2, 3]
-- Some 1
-- > head []
-- None
head : List a -> Option a
```
`medaka test` runs these alongside regular tests. `medaka doc` renders them into the generated documentation. Examples stay correct because the build fails when they go stale.

### Snapshot Tests
For structured output (rendered HTML, generated code, formatted JSON), snapshot tests compare a fresh result against a stored reference, with `medaka test --update-snapshots` to refresh them deliberately.

### Coverage and Benchmarks
- `medaka test --coverage` produces line coverage as part of the standard toolchain — no third-party tool needed.
- `medaka bench` is a first-class benchmark target alongside `medaka test`, following Rust's `cargo bench` model.

### Workspaces
`medaka.toml` supports Cargo-style workspaces — a single root `medaka.toml` can declare member packages, share a lockfile, and build the whole graph. Designed in from day one so multi-package projects never need third-party tooling.

### Attributes
A small, fixed set of declaration attributes for metadata the compiler or tooling consumes:
- `@deprecated "use newName instead"` — warning at call sites
- `@inline` — hint to inline the body (advisory)
- `@must_use` — warn if the result is discarded
- `@test` / `@prop` / `@bench` — already the keywords for `test`/`prop`/`bench` declarations

Attributes are not user-extensible. Same philosophy as the rest of the language: a closed set, no extension mechanism.

---

## Runtime Primitives & Abstraction Layer

### The Problem
The OCaml-hosted compiler calls into OCaml primitives for IO, memory, etc. If/when Medaka moves to a self-hosted compiler targeting LLVM, those primitives need to be reimplemented. Without a clean abstraction layer, this requires rewriting large parts of the language.

### The Solution: `extern` Declarations
A thin runtime abstraction layer defined in Medaka, implemented externally by the host runtime. The `extern` keyword declares primitives that the runtime must provide:

```
-- runtime.mdk
extern println  : String -> <IO> Unit
extern readLine : Unit -> <IO> String
extern readFile : String -> <IO> Result String IoError
extern writeFile : String -> String -> <IO> Result Unit IoError
extern exit     : Int -> Unit
```

During the OCaml phase, these are backed by OCaml implementations. During the LLVM phase, they're backed by C or LLVM IR implementations. The Medaka code above this layer never changes.

### The Primitive Surface Area
The extern layer is intentionally small. Only the things that genuinely require host language support:
- Basic IO (print, file read/write, stdin)
- Memory allocation hooks for the GC
- Arithmetic primitives (the compiler handles most of this)
- String primitives (UTF-8 encoding/decoding)
- Concurrency primitives for `<Async>`
- Clock/time access for `<Time>`
- Random number generation for `<Rand>`

Everything else — `List`, `Map`, `Option`, `Result`, the entire collections hierarchy — is implemented in pure Medaka on top of these primitives. This means the standard library is largely portable across backends automatically.

### Bootstrap Path
This design enables a clean bootstrap sequence:
1. OCaml compiler, OCaml runtime primitives → working language
2. Add LLVM backend to OCaml compiler, C runtime primitives → native binaries
3. Rewrite compiler in Medaka using the same `extern` interface → self-hosted
4. Compile the Medaka compiler with itself → bootstrap complete, retire OCaml implementation

---

## Open Questions

1. ~~**GC design**~~ — **SETTLED: Boehm GC** (`runtime/medaka_rt.c`), per AGENTS.md.

2. **Algebraic effects** — kept as a future possibility. The current effect system reserves space in the type system, making a future upgrade to full algebraic effects less painful than bolting it on from scratch.

---

## Quick Reference

| Concept | This Language | Haskell | OCaml | Rust |
|---|---|---|---|---|
| Evaluation | Strict | Lazy | Strict | Strict |
| Polymorphism | Interfaces (HKT) | Typeclasses (HKT) | Objects + Modules | Traits |
| Error handling | Result + panic | Either + exceptions | exceptions | Result + panic |
| Effects | Built-in tracked set | IO Monad | Unrestricted | Unrestricted |
| Memory | GC | GC | GC | Ownership |
| Syntax style | Haskell/Idris | Haskell | ML | C-like |
| Module system | Rust-style | Weak namespacing | Powerful functors | Rust-style |
