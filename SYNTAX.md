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

Every example below was confirmed to `medaka check` clean on the current
binary (see "Verification" at the bottom). Comments mark the few that are
parse-only or have caveats.

---

## Literals

```
42                  -- Int
0xFF  0b1010  0o17  -- hex / binary / octal Int
1_000_000           -- underscores allowed
3.14   3.141_592    -- Float
"hello"             -- String
"""triple quoted"""  -- triple-quoted String (may span lines)
'a'                 -- Char
True   False        -- Bool
()                  -- Unit
[1, 2, 3]    []     -- List / empty List
[|1, 2, 3|]  [||]   -- Array / empty Array
(1, "hi")           -- Tuple
```

`Int` is a 63-bit tagged signed integer (`intMinBound`/`intMaxBound` = `-2^62`
/ `2^62 - 1`, i.e. `-4611686018427387904` / `4611686018427387903`), not a full
64-bit machine word. Literals and arithmetic silently wrap on overflow with no
diagnostic. `println 9223372036854775807` (a legal-looking 64-bit-max literal)
prints `-1`; `4611686018427387903 + 1` wraps to a negative number. (There is
no `minInt`/`maxInt` — use `intMinBound`/`intMaxBound`, or the polymorphic
`minBound`/`maxBound : Bounded a => a` with a type annotation.)

String escapes: `\n \t \\ \" \{` and unicode `\u{48}`.

## String interpolation (`\{ }`)

```
"hello \{name}!"            -- desugars to `display name` (auto Display, no manual debug)
"\{a} and \{b}"            -- multiple holes
"result: \{1 + 2}"          -- arbitrary expression
"""multi \{name}"""         -- works in triple-quoted too
```

## Type annotations & signatures

```
x : Int
add : Int -> Int -> Int           -- curried arrow
id : a -> a                       -- type variable (lowercase)
head : List a -> Option a         -- type application
neq : Eq a => a -> a -> Bool      -- one constraint
f : (Eq a, Ord b) => a -> b -> Bool  -- multiple constraints
(e : Int)                          -- annotation in expression position
let x : Int = e in body           -- annotated let
```

Effect rows in signatures (see Effects):

```
readFile : String -> <IO> String
fetch    : String -> <Clock, IO> String
applyTo  : (a -> <e> b) -> a -> b           -- effect variable
run      : (Unit -> <IO | e> a) -> <IO | e> a  -- open tail row
```

Effect-label declarations (Phase 146 gap 2 — builtins are
`IO, Mut, Panic, Rand, Stdout, Stderr, Stdin, Clock, Env, Exec, Net,
FileRead, FileWrite`; declare more):

```
effect KV                  -- a user/platform effect label, usable as <KV> in rows
export effect Fetch        -- export-marked (cross-module import works; Phase 146 gap 3 ✅ 2026-06-07)
```

## Function definitions

```
double x = x + x                  -- simple
factorial 0 = 1                   -- pattern-matching head; multiple clauses stack
factorial n = n * factorial (n - 1)
setX v p@(Pt { x, y }) = Pt { p | x = v }  -- `@` as-pattern param (binds whole + fields)
```

Implicitly self-recursive and mutually recursive at top level — no keyword.

Guards (arm fires only if every comma-separated qualifier holds; else fall through):

```
classify n
  | n < 0     = "neg"
  | n > 0     = "pos"
  | otherwise = "zero"

-- inline single-guard form is allowed:
drop n xs | n <= 0 = xs

-- pattern-bind qualifier `pat <- expr`; binds scope rightward + into body:
filterMap f (x::xs)
  | Some y <- f x = y :: filterMap f xs
  | None   <- f x = filterMap f xs
```

`where` block (local defs). `where` may sit at the *end of the body line* or on
its own indented line below the body (Haskell-style); both parse:

```
f x = g x where
  g y = y * 2

f x = g x
  where
    g y = y * 2
```

A `where` on its own line may also scope over *all* arms of a guarded function
(place it at the same indentation as the guards):

```
classify x
  | x > limit = "big"
  | otherwise = "small"
  where
    limit = 100
```

## Lambdas

```
x => x + 1                  -- single param. NOTE: no `\` or `fun` prefix
x y => x + y                -- multi-param (NOT curried `x => y => ...`)
(x, y) => x + y             -- tuple-destructuring param
(Some x) => x               -- constructor-pattern param
_ => 0                      -- wildcard param
xs@rest => xs               -- as-pattern param

-- point-free one-arg lambda that immediately matches (no `function` keyword)
x => match x
  Some x => x
  None   => 0
```

## Operators

```
2 + 3   10 - 4   3 * 4   10 / 2   5 % 2     -- arithmetic
-(5)                                          -- unary minus
x == y   x != y   x < y   x > y   x <= y   x >= y
x && y   x || y   !True                       -- boolean / not
1 :: [2, 3]                                    -- cons
[1,2] ++ [3,4]                                 -- append (Semigroup): works on lists...
"ab" ++ "cd"                                   -- ...and strings too
5 |> double                                    -- pipe (apply value through fn)
double >> inc                                  -- left-to-right composition
f << g                                         -- right-to-left composition
x `div` y                                      -- backtick infix (any named fn)
person.name   utils.greet                      -- dot = field/module access ONLY
```

Sections (parenthesized partial operators):

```
(+5)        -- right section  \x => x + 5
(2 * _)     -- left section   \x => 2 * x
(+)  (-)    -- bare operator as function
```

Indexing & slicing:

```
arr.[0]       -- index
arr.[2..5]    -- slice, half-open
arr.[0..=3]   -- slice, inclusive
```

## Ranges

```
[1..10]       -- List Int, half-open [1,10)
[1..=10]      -- List Int, inclusive
[|1..=100|]   -- Array Int, inclusive
-- and in patterns (see below)
```

## Match & patterns

```
match x
  0           => "zero"          -- literal
  n           => debug n          -- variable
  _           => "other"         -- wildcard
  (a, b)      => ...             -- tuple
  x :: rest   => ...             -- cons
  [1, 2, 3]   => ...             -- explicit list
  Some x      => x               -- constructor
  ys@(x::_)   => x               -- as-pattern (binds whole + parts)
  1..9        => "single digit"  -- int range pattern
  'a'..='z'   => "lower"         -- char range pattern (inclusive)
  Person { name }            => name   -- record pattern (pun)
  Person { name = "Al", age } => age   -- record pattern (explicit + bind)
  Person { name, ... }       => name   -- record pattern with rest
  Person { ... }             => 0      -- record rest only
```

Match-arm guards (same qualifiers as equation guards):

```
match n
  x if x > 0           => "pos"
  x if Some y <- f x, y > 0 => "some-pos"
  _                    => "other"
```

## Control flow

```
if x > 0 then x else 0
if let Some x = opt then x else 0        -- if-let (single-ctor bind)
if x > 0 then println "pos"              -- else-less: else defaults to (); then must be Unit
if x > 0 then                            -- else-less with an indented <Mut> block
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

```
let x = 5 in x + 1
let f x = x + 1 in f 5             -- let-bound function
let g x y = x + y in g 1 2
let rec f = x => f x in f 0        -- recursive value (RHS must be a lambda)
let Some x = opt else panic "no"   -- let-else: refutable; else must diverge (panic / early return)
```

`let rec` binds exactly ONE recursive binding — there is no `with` grouping
for mutual recursion (removed; define each binding as its own separate
`let rec`). This also works as a top-level declaration:

```
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

```
result = do
  x <- computation1          -- monadic bind
  y <- computation2 x
  let z = x + y              -- pure let (no `mut`)
  pure z                    -- expression statement, must unify to `m a`
```

`do` abstracts over any monad (Option, Result, custom). It is true sugar
(lowers to `andThen`/`pure`). For imperative IO sequencing, use a **bare**
indented block, not `do`.

## Data types

```
data Bool = True | False                          -- inline sum
data Option a = Some a | None                     -- with payload + type param
data Shape                                         -- block form
  = Circle Float
  | Rectangle Float Float

data Point = Pt { x : Int, y : Int }              -- named-field variant (inline)
data Vec = { x : Int, y : Int }                   -- SHORT form: single braced ctor,
                                                    -- name omitted → ctor name = tycon
                                                    -- (`Vec`); == `data Vec = Vec { … }`.
                                                    -- Only for a lone `{ … }` ctor with
                                                    -- no `|`; multi-ctor stays explicit.
data Event                                          -- named-field variant (block)
  = Click { x : Int, y : Int }
  | Scroll Int

data Bool = True | False deriving (Debug)          -- deriving

Pt { p | y = 9 }                                    -- variant functional update
                                                    -- (copy p, override y; p must be a Pt)
```

## Records

A record is just a single-constructor `data` type with named fields. There is no
separate `record` keyword — write `data X = { … }` (the constructor is named after
the type) or the explicit `data X = X { … }`.

```
data Person = { name : String, age : Int }   -- record = single-ctor named data
                                              -- (ctor implicitly named `Person`)
data Person = Person { name : String, age : Int }  -- explicit ctor name (equivalent)

Person { name = "Alice", age = 30 }   -- construction (all fields required)
Person { name, age }                   -- pun shorthand (name = name, ...)
person.name                            -- field access
{ p | age = 31 }                       -- functional update
{ p | address.city = "Boston" }        -- nested update sugar
data Boxed = { x : Int } deriving (Debug)   -- deriving on a record-shaped data type
```

## Type aliases & newtypes

```
type Name = String
type Wrapper a = Option a
newtype UserId = UserId Int
newtype Age = Age Int deriving (Eq)
```

## Interfaces & implementations

```
interface Eq a where
  eq : a -> a -> Bool

interface Ord a requires Eq a where      -- superclass constraint
  compare : a -> a -> Ordering

interface Greeter a where                 -- default method body
  greet x = "Hello, " ++ x

interface Empty a                         -- marker interface (no `where`)

impl Eq Int where
  eq a b = a == b

impl Eq (List a) requires Eq a where      -- conditional impl
  eq xs ys = ...

impl Additive of Monoid Int where         -- named instance
  ...

default impl Mappable (Result e) where    -- default (unnamed-resolution) impl
  ...

combine @Additive                          -- impl hint: pick a named instance at use site
```

## Modules — import / export

```
import utils.greet                  -- single name
import utils.{greet, helper}        -- group
import utils.*                      -- wildcard
import colors.{Color(..)}           -- type + all its constructors
import m.{f, T(..), g}              -- mixed
export import list.{map, filter}    -- re-export

export                              -- export the following declaration
foo x = x

public export data Color = Red | Green | Blue   -- export type + constructors
export data Color = Red | Green | Blue           -- abstract export (type only)
```

### Import aliasing (`as`)

Two forms, both of which make a name collision between modules resolvable. Landed
2026-07-13 (before that, `as` parsed and was silently ignored).

```
import backend.wasm_emit as W                  -- module alias: refer to W.emitProgram
import backend.wasm_emit.{emitProgram as wasmText}   -- member alias: rename one value
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

```
extern foo : Int -> String
extern id : a -> a
extern putStrLn : String -> <IO> Unit
extern pi : Float
```

## Tests (declaration forms)

```
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

```
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

Mutable state lives in a `Ref` cell (carrying the `<Mut>` effect), not in the
binding. Construct with `Ref v`, write with the `:=` operator, read the `.value`
field:

```
main =
  let count = Ref 0      -- immutable BINDING of a mutable CELL
  count := 42            -- `:=` writes the cell (sugar for `setRef count 42`)
  count := count.value + 1  -- read with `.value`; `:=` is right-assoc, low prec
  println count.value    -- .value reads it  => 43
```

`x := e` is surface sugar that desugars to `setRef x e` (type
`Ref a -> a -> <Mut> Unit`), so `x` must be a `Ref`; a non-`Ref` left side is a
type error. `setRef` may still be called directly.

## Map / Set literals

Requires an explicit named import of the module *and* the type — a bare
`import map` / `import set` does not bring any names into scope:

```
import map.{Map, get}
import set.{Set, has}

main =
  println (get "a" (Map { "a" => 1, "b" => 2 }))
  println (has 2 (Set { 1, 2, 3 }))
```

## Comments

```
-- line comment
{- block comment {- nests -} -}

-- > expr        -- doctest side-channel: `-- > expr` then `-- expected`
-- expected
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

---

## Verification

Every example was checked against the current binary by feeding minimal
programs through `medaka check`. To re-verify after a grammar change, build
(`make medaka` in a worktree) and re-run the probes; constructs are additionally
exercised end-to-end by the `test/diff_compiler_*.sh` gate suite (see AGENTS.md
"Build & test").
