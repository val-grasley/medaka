# SYNTAX.md — Medaka construct cheat-sheet

A terse, example-driven catalog of **what the current binary accepts**, so an
agent knows what syntax exists without reading the 1100-line grammar. One
minimal example per construct.

**Ground truth, in order:** `lib/parser.mly` (what parses) and the
`test/test_parser.ml` / `test/test_eval.ml` corpora (verified-passing
snippets). `language-design.md` describes *intent* and includes aspirational
features — when it disagrees with this file or the binary, the binary wins.
This file is hand-maintained; the language gains constructs every Phase, so if
a construct here fails to parse, re-derive from the grammar and fix this file.

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
fetch    : String -> <Async, IO> String
applyTo  : (a -> <e> b) -> a -> b           -- effect variable
run      : (Unit -> <IO | e> a) -> <IO | e> a  -- open tail row
```

Effect-label declarations (Phase 146 gap 2 — builtins are
`IO, Mut, Async, Panic, Rand, Time`; declare more):

```
effect KV                  -- a user/platform effect label, usable as <KV> in rows
export effect Fetch        -- export-marked (cross-module import is future work)
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

-- `function`: one-arg lambda that immediately matches
function
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
Ok 5 ?                                          -- `?` short-circuit unwrap Result/Option
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

## let / mutation

```
let x = 5 in x + 1
let mut x = 5 in x                  -- mutable binding
let f x = x + 1 in f 5             -- let-bound function
let g x y = x + y in g 1 2
let rec f = x => f x in f 0        -- recursive value (RHS must be a lambda)
let rec f = x => g x with g = x => f x in f 0  -- mutual; inline `in` form is ONE line
let Some x = opt else panic "no"   -- let-else: refutable; else must diverge (panic / early return)
```

Mutual recursion as a *top-level* declaration (the `with` group may span lines
here, unlike the inline `in` form above):

```
let rec isEven = n => if n == 0 then True else isOdd (n - 1)
with isOdd = n => if n == 0 then False else isEven (n - 1)
```

Inside a bare (non-`do`) indented block, statements may be `let`, `let mut`,
expression statements, reassignment `x = e`, field assignment `x.f = e`,
nested field assignment `a.b.c = e`, and `let else`. **`<-` is forbidden in a
bare block** — use `do`.

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
data Event                                          -- named-field variant (block)
  = Click { x : Int, y : Int }
  | Scroll Int

data Bool = True | False deriving (Debug)          -- deriving

Pt { p | y = 9 }                                    -- variant functional update
                                                    -- (copy p, override y; p must be a Pt)
```

## Records

```
record Person
  name : String
  age  : Int

Person { name = "Alice", age = 30 }   -- construction (all fields required)
Person { name, age }                   -- pun shorthand (name = name, ...)
person.name                            -- field access
{ p | age = 31 }                       -- functional update
{ p | address.city = "Boston" }        -- nested update sugar
record Person                          -- deriving
  x : Int
  deriving (Debug)
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
import collections.HashMap as HM    -- alias
import colors.{Color(..)}           -- type + all its constructors
import m.{f, T(..), g}              -- mixed
export import list.{map, filter}    -- re-export

export                              -- export the following declaration
foo x = x

public export data Color = Red | Green | Blue   -- export type + constructors
export data Color = Red | Green | Blue           -- abstract export (type only)
```

## Externs (primitive declarations — see stdlib/runtime.mdk)

```
extern foo : Int -> String
extern id : a -> a
extern putStrLn : String -> <IO> Unit
extern pi : Float
```

## Tests & benchmarks (declaration forms)

```
prop "commutative" (x : Int) = x + 0 == x
bench "identity" = 42
```

## Attributes

```
@deprecated "use bar"
foo x = x

@inline
foo x = x

@must_use
f x = x
```

## Refs & list comprehensions

```
let mut count = Ref 0 in set_ref count 42     -- Ref cell

[x * 2 | x <- [1,2,3,4,5], x > 2]              -- comprehension: generator + filter
[(x, y) | x <- [1,2], y <- [3,4]]              -- multi-generator
[y | x <- [1,2,3], let y = x * x, y > 2]       -- with let-binding qualifier
```

## Map / Set literals

```
Map { "a" => 1, "b" => 2 }
Set { 1, 2, 3 }
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
- An expression RHS **cannot** wrap onto a second indented line, *except* when
  the continuation line *starts* with a leading binary operator
  (`|> >> << && || ++`), which continues the expression.
- `then` cannot start a line. (`else` *may* — it is treated as a continuation
  of the preceding `if`.)

---

## Verification

Every example was checked against the current binary by feeding minimal
programs through `medaka check`. To re-verify after a grammar change, build
(`dune build --root .` in a worktree) and re-run the probes; constructs sourced
from `test/test_eval.ml` / `test/test_run.ml` are additionally exercised
end-to-end by those suites.
