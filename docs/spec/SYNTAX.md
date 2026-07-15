# SYNTAX.md — Medaka construct cheat-sheet

A terse, example-driven catalog of **what the current binary accepts**, so an
agent knows what syntax exists without reading the 1100-line grammar. One
minimal example per construct.

**Ground truth, in order:** the current `medaka` binary (native, self-hosted —
the OCaml reference compiler `lib/`+`bin/` was removed 2026-06-26; the
`oracle-frozen` tag preserves the last commit that had it) and the
`test/*_fixtures/` / `test/*_goldens/` corpora (verified-passing snippets).
`language-design.md` describes *intent* and includes aspirational features —
when it disagrees with this file or the binary, the binary wins. This file is
hand-maintained; the language gains constructs every Phase, so if a construct
here fails to parse, re-derive from `compiler/frontend/parser.mdk` and fix this
file.

Every fenced ` ```medaka ` / ` ```medaka-project ` block below is machine-checked
against the current binary by `test/check_syntax_examples.sh` — see
"Verification" at the bottom. That is what makes the claim above true instead
of aspirational.

---

## Literals

```medaka
p1 = 42                     -- Int
p2 = 0xFF                   -- hex Int
p3 = 0b1010                 -- binary Int
p4 = 0o17                   -- octal Int
p5 = 1_000_000              -- underscores allowed
p6 = 3.14                   -- Float
p7 = 3.141_592              -- Float
p7a = 1e12                   -- Float (scientific: integer mantissa + exponent)
p7b = 1.5e10                 -- Float (fractional mantissa + exponent)
p7c = 9e+15                  -- Float (explicit `+` exponent)
p7d = 1e-05                  -- Float (negative exponent)
p8 = "hello"                -- String
p9 = """triple quoted"""    -- triple-quoted String (may span lines)
p10 = 'a'                   -- Char
p11 = True                  -- Bool
p12 = False                 -- Bool
p13 = ()                    -- Unit
p14 = [1, 2, 3]             -- List
p15 = []                    -- empty List
p16 = [|1, 2, 3|]           -- Array
p17 = [||]                  -- empty Array
p18 = (1, "hi")             -- Tuple
```

`Int` is a 63-bit tagged signed integer (`intMinBound`/`intMaxBound` = `-2^62`
/ `2^62 - 1`, i.e. `-4611686018427387904` / `4611686018427387903`), not a full
64-bit machine word. An **integer literal** whose magnitude exceeds `2^62` is a
lex error (`L-INT-OVERFLOW`) — `println 9223372036854775807` (a legal-looking
64-bit-max literal) no longer silently prints `-1`, it is rejected. The lexer
sees only the unsigned digits (the `-` is a separate token), so it admits
magnitude `2^62` = `4611686018427387904` for the writable negative minimum
`-4611686018427387904` and rejects `4611686018427387905` (= `2^62 + 1`) and
above; a bare *positive* `4611686018427387904` therefore still wraps to the
negative minimum (the lexer cannot see the sign). **Arithmetic** overflow wraps
two's-complement-style **by design** — a documented footgun, not a bug (decided
2026-07-15): `Int` is a fixed-width machine integer (as in C, Go, or Haskell's
Int), not an arbitrary-precision bignum, so `4611686018427387903 + 1` wraps to a
negative number with no diagnostic. Code that relies on wraparound (hashing,
RNG) depends on this; to detect it, bounds-check the operands against
`intMaxBound`/`intMinBound` yourself. (There is no `minInt`/`maxInt` — use
`intMinBound`/`intMaxBound`, or
the polymorphic `minBound`/`maxBound : Bounded a => a` with a type annotation.)

String escapes: `\n \t \\ \" \{` and unicode `\u{48}`.

## String interpolation (`\{ }`)

```medaka
name = "world"
a = 1
b = 2
p1 = "hello \{name}!"        -- desugars to `display name` (auto Display, no manual debug)
p2 = "\{a} and \{b}"         -- multiple holes
p3 = "result: \{1 + 2}"      -- arbitrary expression
p4 = """multi \{name}"""     -- works in triple-quoted too
```

## Type annotations & signatures

```medaka
x : Int
x = 5
add : Int -> Int -> Int             -- curried arrow
add a b = a + b
id : a -> a                         -- type variable (lowercase)
id v = v
head : List a -> Option a           -- type application
head xs = match xs
  (h :: _) => Some h
  []       => None
neq : Eq a => a -> a -> Bool        -- one constraint
neq p q = p != q
f : (Eq a, Ord b) => a -> b -> Bool -- multiple constraints
f p q = True
p1 = (5 : Int)                       -- annotation in expression position
p2 = let y : Int = 5 in y + 1        -- annotated let
```

Effect rows in signatures (see Effects):

```medaka
extern readFile : String -> <IO> String
extern fetch    : String -> <Clock, IO> String
applyTo : (a -> <e> b) -> a -> b               -- effect variable
applyTo g v = g v
run      : (Unit -> <IO | e> a) -> <IO | e> a  -- open tail row
run g = g ()
```

Effect-label declarations (Phase 146 gap 2 — builtins are
`IO, Rand, Stdout, Stderr, Stdin, Clock, Env, Exec, Net,
FileRead, FileWrite`; declare more):

```medaka
effect KV                  -- a user/platform effect label, usable as <KV> in rows
export effect Fetch        -- export-marked (cross-module import works; Phase 146 gap 3 ✅ 2026-06-07)
```

## Function definitions

```medaka
double x = x + x                  -- simple
factorial 0 = 1                   -- pattern-matching head; multiple clauses stack
factorial n = n * factorial (n - 1)
data Point = Pt { x : Int, y : Int }
setX v p@(Pt { x, y }) = Pt { p | x = v }  -- `@` as-pattern param (binds whole + fields)
```

Implicitly self-recursive and mutually recursive at top level — no keyword.

Guards (arm fires only if every comma-separated qualifier holds; else fall through):

```medaka
classify n
  | n < 0     = "neg"
  | n > 0     = "pos"
  | otherwise = "zero"

-- inline single-guard form is allowed:
drop n xs | n <= 0 = xs
drop n (x::xs) = drop (n - 1) xs
drop n [] = []

-- pattern-bind qualifier `pat <- expr`; binds scope rightward + into body:
filterMap f (x::xs)
  | Some y <- f x = y :: filterMap f xs
  | None   <- f x = filterMap f xs
filterMap f [] = []
```

`where` block (local defs). `where` may sit at the *end of the body line* or on
its own indented line below the body (Haskell-style); both parse:

```medaka
f x = g x where
  g y = y * 2
```

```medaka
f x = g x
  where
    g y = y * 2
```

A `where` on its own line may also scope over *all* arms of a guarded function
(place it at the same indentation as the guards):

```medaka
classify x
  | x > limit = "big"
  | otherwise = "small"
  where
    limit = 100
```

## Lambdas

```medaka
p1 = x => x + 1                  -- single param. NOTE: no `\` or `fun` prefix
p2 = x y => x + y                -- multi-param (NOT curried `x => y => ...`)
p3 = (x, y) => x + y             -- tuple-destructuring param
p4 = (Some x) => x               -- constructor-pattern param
p5 = _ => 0                      -- wildcard param
p6 = xs@rest => xs               -- as-pattern param

-- point-free one-arg lambda that immediately matches (no `function` keyword)
p7 = x => match x
  Some x => x
  None   => 0
```

## Operators

```medaka
x = 1
y = 2
p = True
q = False
double n = n + n
inc n = n + 1
data Person = { name : String }
person = Person { name = "n" }

e1  = 2 + 3               -- arithmetic
e2  = 10 - 4
e3  = 3 * 4
e4  = 10 / 2
e5  = 5 % 2
e6  = -(5)                 -- unary minus
e7  = x == y
e8  = x != y
e9  = x < y
e10 = x > y
e11 = x <= y
e12 = x >= y
e13 = p && q               -- boolean
e14 = p || q
e15 = !True                 -- not
e16 = 1 :: [2, 3]            -- cons
e17 = [1,2] ++ [3,4]         -- append (Semigroup): works on lists...
e18 = "ab" ++ "cd"           -- ...and strings too
e19 = 5 |> double            -- pipe (apply value through fn)
e20 = double >> inc          -- left-to-right composition
e21 = inc << double          -- right-to-left composition
e22 = person.name            -- dot = field/module access ONLY
```

There is no backtick-infix operator syntax (`` x `f` y ``) — see "Removed — do not use".

Sections (parenthesized partial operators):

```medaka
p1 = (+5)        -- right section  x => x + 5
p2 = (2 * _)      -- left section   x => 2 * x
p3 = (+)          -- bare operator as function
p4 = (-)
```

Indexing & slicing:

```medaka
arr = [|1,2,3,4,5,6|]
p1 = arr.[0]        -- index
p2 = arr.[2..5]      -- slice, half-open
p3 = arr.[0..=3]     -- slice, inclusive
```

## Ranges

```medaka
p1 = [1..10]        -- List Int, half-open [1,10)
p2 = [1..=10]        -- List Int, inclusive
p3 = [|1..=100|]     -- Array Int, inclusive
-- and in patterns (see below)
```

## Match & patterns

```medaka
data Person = Person { name : String, age : Int }

m1 x = match x
  0           => "zero"          -- literal
  n           => debug n         -- variable (also serves as catch-all)

m2 t = match t
  (a, b)      => a               -- tuple

m3 xs = match xs
  x :: rest   => x                -- cons
  []          => 0

m3b lst = match lst
  [1, 2, 3]   => 0                -- explicit list
  _           => 1                -- wildcard

m4 o = match o
  Some x      => x                -- constructor
  _           => 0

m5 xs = match xs
  ys@(x::_)   => x                -- as-pattern (binds whole + parts)
  _           => 0

m6 n = match n
  1..9        => "single digit"   -- int range pattern
  _           => "multi"

m7 c = match c
  'a'..='z'   => "lower"          -- char range pattern (inclusive)
  _           => "other"

m8 p = match p
  Person { name }            => name    -- record pattern (pun)

m9 p = match p
  Person { name = "Al", age } => debug age -- record pattern (explicit + bind)
  Person { name, ... }       => name       -- record pattern with rest

m10 p = match p
  Person { ... }             => 0          -- record rest only
```

Match-arm guards (same qualifiers as equation guards):

```medaka
f : Int -> Option Int
f n = if n > 10 then Some n else None

classify n = match n
  x if x > 0                 => "pos"
  x if Some y <- f x, y > 0  => "some-pos"
  _                           => "other"
```

## Control flow

```medaka
opt = Some 5
doThing = println "a"
doOther = println "b"

p1 = if 1 > 0 then 1 else 0
p2 = if let Some v = opt then v else 0        -- if-let (single-ctor bind)
p3 x = if x > 0 then println "pos"            -- else-less: else defaults to (); then must be Unit
main =
  if 1 > 0 then                               -- else-less with an indented side-effecting block
    doThing
    doOther
```

Branches may be inline or indented blocks, in any combination; `else` may begin
a line. An else-less `if` is for side effects — its `then` branch must be `Unit`.

A `let` in a branch follows the normal `let` rules: an inline `let` needs `in`
(`else let x = e in body`), and a multi-statement body uses a block — put `else`
on its own line, then indent the `let … ⏎ body` (`then`/`else` with a `let` and
the body on a *following* line, all on the `else` line, is **not** a block opener —
`else let x = e ⏎ body` is a parse error by design; see LAYOUT-SEMANTICS.md §9).

## let / mutation

```medaka
p1 = let x = 5 in x + 1
p2 = let f x = x + 1 in f 5             -- let-bound function
p3 = let g x y = x + y in g 1 2
p4 = let rec f = x => f x in f 0        -- recursive value (RHS must be a lambda)
```

There is no `let-else` (`let PAT = EXPR else DEFAULT`) — see "Removed — do not use".

`let rec` binds exactly ONE recursive binding — there is no `with` grouping
for mutual recursion (removed; define each binding as its own separate
`let rec`). This also works as a top-level declaration:

```medaka
isOdd n = if n == 0 then False else isEven (n - 1)
let rec isEven n = if n == 0 then True else isOdd (n - 1)
```

Inside a bare (non-`do`) indented block, statements may be `let`,
expression statements, field assignment `x.f = e`, nested field assignment
`a.b.c = e`, and `let else`. **`<-` is forbidden in a bare block** — use `do`.

**Bindings are immutable.** `=` (with `let`, or a top-level definition) is
*declaration only*; there is no mutable binding. A bare reassignment `x = e` of
an already-bound name is an error (`R-IMMUTABLE-ASSIGN`), and `let mut` has been
removed (a parse error pointing at `Ref`). Shadowing — a *new* `let x = …` that reuses a
name — stays legal (it declares a fresh binding). For in-place mutable state,
use a `Ref` (see [Refs](#refs)).

## do notation (`do` keyword required)

```medaka
computation1 = Some 1
computation2 x = Some (x + 1)

result = do
  x <- computation1           -- monadic bind
  y <- computation2 x
  let z = x + y               -- pure let (no `mut`)
  pure z                     -- expression statement, must unify to `m a`
```

`do` abstracts over any monad (Option, Result, custom). It is true sugar
(lowers to `andThen`/`pure`). For imperative IO sequencing, use a **bare**
indented block, not `do`.

## Data types

```medaka
data MyBool = MyTrue | MyFalse                      -- inline sum
data MyOption a = MySome a | MyNone                 -- with payload + type param
data Shape                                           -- block form
  = Circle Float
  | Rectangle Float Float

data Point = Pt { x : Int, y : Int }                -- named-field variant (inline)
data Vec = { x : Int, y : Int }                     -- SHORT form: single braced ctor,
                                                      -- name omitted → ctor name = tycon
                                                      -- (`Vec`); == `data Vec = Vec { … }`.
                                                      -- Only for a lone `{ … }` ctor with
                                                      -- no `|`; multi-ctor stays explicit.
data Event                                           -- named-field variant (block)
  = Click { x : Int, y : Int }
  | Scroll Int

data MyColor = MyRed | MyGreen deriving (Debug)      -- deriving

p = Pt { x = 1, y = 2 }
p2 = Pt { p | y = 9 }                                -- variant functional update
                                                      -- (copy p, override y; p must be a Pt)
```

## Records

A record is just a single-constructor `data` type with named fields. There is no
separate `record` keyword — write `data X = { … }` (the constructor is named after
the type) or the explicit `data X = X { … }`.

```medaka
data Person = { name : String, age : Int }          -- record = single-ctor named data
                                                      -- (ctor implicitly named `Person`)
-- equivalent explicit form: data Person = Person { name : String, age : Int }

p1 = Person { name = "Alice", age = 30 }             -- construction (all fields required)

name = "Bob"
age = 40
p2 = Person { name, age }                            -- pun shorthand (name = name, ...)

n  = p1.name                                          -- field access
p3 = { p1 | age = 31 }                                -- functional update

data Address = { city : String }
data PersonA = { address : Address }
pa  = PersonA { address = Address { city = "NYC" } }
pa2 = { pa | address.city = "Boston" }                -- nested update sugar

data Boxed = { x : Int } deriving (Debug)             -- deriving on a record-shaped data type
```

## Type aliases & newtypes

```medaka
type Name = String
type Wrapper a = Option a
newtype UserId = UserId Int
newtype Age = Age Int deriving (Eq)
```

## Interfaces & implementations

```medaka
interface Eq2 a where
  eq2 : a -> a -> Bool

interface Ord2 a requires Eq2 a where       -- superclass constraint
  compare2 : a -> a -> Ordering

interface Greeter a where                    -- default method body
  greet : a -> String                        -- the default body's sig MUST mention `a`
  greet x = "Hello!"                         -- (dispatch needs it in the signature)

interface Empty a                            -- marker interface (no `where`)

impl Eq2 Int where
  eq2 a b = a == b

data Box a = Box a

impl Eq2 (Box a) requires Eq2 a where        -- conditional impl
  eq2 (Box x) (Box y) = eq2 x y
```

There are no **named impls** (`impl Name of Iface Ty where`), no `default impl`, and
no `@Name` impl-hint at a use site — all three were removed together (a plain `impl`
covers every case; overlap resolves by picking the most-specific instance
automatically). See "Removed — do not use".

## Modules — import / export

A module lives in its own file; import paths are relative to the project root
(`medaka.toml`). The forms below (in a `main*.mdk` consumer of `utils.mdk` /
`colors.mdk` / `m.mdk`):

```medaka-project
-- file: utils.mdk
export greet = "hi"
export helper = "help"

-- file: colors.mdk
public export data Color = Red | Green | Blue deriving (Debug)

-- file: m.mdk
export f = 1
public export data T = TA | TB
export g = 2

-- file: main_single.mdk
import utils.greet                  -- single name
main = println greet

-- file: main_group.mdk
import utils.{greet, helper}        -- group
main = println (greet ++ helper)

-- file: main_wildcard.mdk
import utils.*                      -- wildcard
main = println greet

-- file: main_type.mdk
import colors.{Color(..)}           -- type + all its constructors
main = println (debug Red)

-- file: main_mixed.mdk
import m.{f, T(..), g}              -- mixed
main = println (f + g)

-- file: main_reexport.mdk
export import list.{reverse, take}  -- re-export
main = println (reverse (take 2 [1, 2, 3]))
```

Export forms:

```medaka-project
-- file: exports_demo.mdk
export                              -- export the following declaration
foo x = x

public export data Shade = Light | Dark   -- export type + constructors
export data Hidden = HiddenCtor            -- abstract export (type only)

-- file: main.mdk
import exports_demo.{foo, Shade(..), Hidden}
main = println (foo (match Light
  Light => "l"
  Dark => "d"))
```

⚠️ **`export import <mod>.{name}` does NOT re-export a name that `<mod>` itself
only has via its own `export import core.{name}`** (re-exporting something
that originates in the implicit prelude module `core`) — it type-checks with
**zero diagnostic** at the `export import` site, then a downstream
`import <mod>.{name}` fails with `R-PRIVATE-NAME: Module '<mod>' has no
exported name 'name'`. This reproduces on current `main` (verified against a
freshly-built binary, not a stale one) and is a **real compiler bug**, not a
doc error — filed as a finding by this pass, not fixed here. Concretely:
`stdlib/list.mdk` re-exports `core`'s `filter` "for discoverability" (its own
comment says so) but `import list.{filter}` from a third module fails. This is
why the re-export example above uses `reverse`/`take` (defined directly in
`list.mdk`) rather than `map`/`filter` (the latter live in `core`, so they
need no import at all — see stdlib docs).

### Import aliasing (`as`)

Two forms, both of which make a name collision between modules resolvable. Landed
2026-07-13 (before that, `as` parsed and was silently ignored).

```medaka-project
-- file: emit_a.mdk
export emit = "A"

-- file: emit_b.mdk
export emit = "B"

-- file: main.mdk
import emit_a as EA                 -- module alias: refer to EA.emit
import emit_b.{emit as emitB}       -- member alias: rename one value
main = println (EA.emit ++ emitB)
```

| form | meaning |
|---|---|
| `import m as A` | binds every VALUE `m` exports as `A.name`. Does **not** bind bare `name`. |
| `import m.sub as A` | same, for a nested module path |
| `import m.{a as b, c}` | binds `m`'s `a` as `b`, plus `c`. Does **not** bind bare `a`. |

**An alias REPLACES the unqualified import** (like Python's `import x as y`, or
Haskell's `qualified`). That is what makes a collision resolvable: `import emit_a as A`
and `import emit_b as B` puts both modules' `emit` in scope, as `A.emit` and `B.emit`.

Rules, each a real error rather than a silent no-op:

| rejected form | why |
|---|---|
| `import m.{a} as A` | group + alias is contradictory (the group already binds names unqualified) |
| `import m.* as A` | wildcard + alias, same reason |
| `import m as l` | a module alias must be **Uppercase** — it is used as a qualifier (`A.name`), and a lowercase one would be ambiguous with `record.field` |
| `import m.{Foo as Bar}` | only a **value** member can be renamed. Impl coherence and constructor identity resolve on the REAL name globally, so aliasing a type/ctor/interface would be a soundness hole, not a rename |
| `export import m as A` | an alias is FILE-LOCAL. Re-exporting `A.name` would export a name no importer could write |

A qualified reference `A.name` is lowered by `frontend/desugar.mdk` to the flat name
`A.name` (a dot cannot occur in an identifier, so it cannot collide), and
`backend/private_mangle.mdk` maps it back to the origin module's real symbol — no dotted
name reaches the emitted code.

Only values can be qualified: `A.SomeType` does not parse (a field name is lowercase).
Import a type with `import m.{T(..)}`.

## Externs (primitive declarations — see stdlib/runtime.mdk)

```medaka
extern foo : Int -> String
extern id : a -> a
extern putStrLn : String -> <IO> Unit
extern pi : Float
```

## Tests (declaration forms)

```medaka
prop "commutative" (x : Int) = x + 0 == x
```

`bench "name" = expr` parses, but the `bench` subcommand is not yet
implemented in the native CLI (`medaka bench` → `subcommand 'bench' not yet
in native CLI`, even though `--help` still lists it) — don't rely on it.

## Attributes

An attribute needs a **type signature between it and the definition** — an
attribute directly above a signature-less def silently unbinds the def
(`@inline` ⏎ `foo x = x` ⏎ `main = println (foo 3)` → `Unbound variable: foo`).
The working shape:

```medaka
@deprecated "use bar"
foo : Int -> Int
foo x = x

@inline
bar : Int -> Int
bar x = x

@must_use
baz : Int -> Int
baz x = x
```

## Refs

Mutable state lives in a `Ref` cell, not in the binding. Mutation is untracked
(no effect label). Construct with `Ref v`, write with the `:=` operator, read
the `.value` field:

```medaka
main =
  let count = Ref 0      -- immutable BINDING of a mutable CELL
  count := 42            -- `:=` writes the cell (sugar for `setRef count 42`)
  count := count.value + 1  -- read with `.value`; `:=` is right-assoc, low prec
  println count.value    -- .value reads it  => 43
```

`x := e` is surface sugar that desugars to `setRef x e` (type
`Ref a -> a -> Unit`), so `x` must be a `Ref`; a non-`Ref` left side is a
type error. `setRef` may still be called directly.

## Map / Set literals

Requires an explicit named import of the module *and* the type — a bare
`import map` / `import set` does not bring any names into scope:

```medaka
import map.{Map, get}
import set.{Set, has}

main =
  println (get "a" (Map { "a" => 1, "b" => 2 }))
  println (has 2 (Set { 1, 2, 3 }))
```

## Comments

```medaka
-- line comment
{- block comment {- nests -} -}

-- > 1 + 1        -- doctest side-channel: `-- > expr` then the expected value
-- 2
main = println "ok"
```

## Layout notes

- **Indentation-sensitive** (INDENT/DEDENT/NEWLINE). No braces for blocks.
- For the exact wrapping rules, see `LAYOUT-SEMANTICS.md` §11. In brief:
  a deeper-indented line continues the current logical line (no `INDENT`) when
  the previous token is a trailing-continuation operator, **or** the line starts
  with a leading-continuation operator (`|> >> << && || ++ ::`), **or** the
  previous token can end an expression and the new line starts with an atom.
  Otherwise the deeper line opens a block, causing a parse error in expression-RHS
  position.
- `then` **may** start a line — like `else`, a leading `then` continues the
  enclosing `if` (§5.4 of `LAYOUT-SEMANTICS.md`).
- Tabs round to the next multiple of 8 (`LAYOUT-SEMANTICS.md` §3); mixing a tab
  after spaces in indentation can produce surprising column values.

## Removed — do not use

These constructs previously existed (or were briefly floated in this file) and no
longer parse. Each has a dedicated, located parser diagnostic — the parser doesn't
just choke, it names the removal and points at a replacement. Tree-wide gate:
`test/check_removed_constructs.sh`.

| removed | replacement |
|---|---|
| the `record` keyword | `data X = { … }` (a record is a single-ctor named `data` type — see Records) |
| the `function` keyword (point-free-by-last-arg sugar) | point-free `match` lambda: `x => match x  …` |
| backtick infix, `` x `f` y `` | prefix application: `f x y` |
| `let mut` | immutable `let` + a `Ref` cell for mutable state (see Refs) |
| `let PAT = EXPR else DEFAULT` (let-else) | `if let PAT = EXPR then … else DEFAULT`, or `match` |
| named impls, `impl Name of Iface Ty where` | a plain `impl Iface Ty where` — overlap resolves to the most-specific instance automatically |
| `default impl Iface Ty where` | a plain `impl Iface Ty where` |
| `@Name` impl-hint at a call site (`combine @Additive`) | n/a — named instances are gone, so there is nothing left to hint at |

---

## Verification

Every ` ```medaka ` (single-file) and ` ```medaka-project ` (multi-file, using
`-- file: name.mdk` markers and one or more `main*.mdk` entry points) fenced
block in this file is extracted and run through `medaka check` by
`test/check_syntax_examples.sh`. A block tagged plain ` ``` ` (no language) or
` ```sh ` is prose/shell and is not checked; a block that is genuinely
grammar-illustration-only (not a full example) would be tagged
` ```medaka-nocheck: reason ` — none currently are. Run after any grammar
change:

```sh
make medaka                              # in a worktree
sh test/check_syntax_examples.sh         # POSIX sh; dash-compatible
```

Constructs are additionally exercised end-to-end by the `test/diff_compiler_*.sh`
gate suite (see AGENTS.md "Build & test").
