# mq — a tiny `jq` in Medaka

A first real (non-compiler) Medaka program, built to kick the tires on the
language. Reads JSON from stdin (or a file), applies a **filter expression**
given on the command line, writes JSON to stdout.

```sh
echo '{"a":1}' | mq '.a'                 # 1
echo '{"users":[{"name":"x"}]}' | mq '.users[] | .name'   # "x"
```

This spec is **milestone-paced for a human**: each milestone produces a
*runnable* program, and each teaches one area of the language. Build top to
bottom. Keep a running `NOTES.md` of every rough edge — that log is the real
deliverable (see "Why this project" at the end).

---

## The one design choice that matters

**A filter is a function `Json -> List Json`.** jq filters produce a *stream*:
`.` yields one value, `.[]` yields many, a failed `select` yields none. Modeling
the result as a `List Json` makes the pipe `|` simply `flatMap` — and that
stream core is what exercises the `List` monad. Start without error threading;
add `Result` only at M5.

## JSON — don't build it

`import json` and reuse the stdlib `Json` ADT + parser/serializer. Parsing and
serializing JSON is free, so all your effort goes into the *filter* language.
(First task in M0: open `stdlib/json.mdk` and read the `Json` constructor names
+ the parse/serialize entry points — you'll pattern-match on them constantly.)

## Filter AST (the thing you define and evaluate)

```
data Filter
  = Identity              -- .
  | Field String          -- .foo
  | Index Int             -- .[0]
  | Iterate               -- .[]
  | Pipe Filter Filter    -- f | g
  | Select Filter         -- select(f)
  | MapF Filter           -- map(f)
  | Call String           -- length, keys, add
  | Lit Json              -- 1, "x", true, null
```

---

## Milestone ladder (each one runs)

### M0 — Skeleton + JSON echo
`main` reads all of stdin → `json` parse → serialize → print. No filter yet.
*Proves the I/O + json round-trip works end-to-end.*
- Teaches: project layout, `io` (`readAll`/`putStrLn`), `json`, threading
  `Result` at the boundary.
- Done when: `echo '{"a":1}' | medaka run main.mdk` echoes the JSON back.

### M1 — Evaluator on hand-built ASTs (NO parser yet)
Define `Filter`, write `eval : Filter -> Json -> List Json`. Construct a
`Field "foo"` value *in code* and run it against parsed input.
- The key move: get the evaluator working on hand-built ASTs **before** touching
  filter-string parsing. Two hard things, one at a time.
- Teaches: the `Filter` ADT, pattern matching over `Json`.
- Done when: a hard-coded `Field "a"` extracts `.a` from the input.

### M2 — Filter parser
Parse the CLI-arg string (`".foo.bar"`) into a `Filter`. Start with `.`,
`.field`, and chains. The eval from M1 already works, so you see results
immediately.
- Teaches: hand-rolled recursive descent over a `String`, `string` handling,
  `Result` errors.
- Done when: `mq '.a.b'` works against nested objects.

### M3 — Pipe + iterate (the payoff)
Add `|` and `.[]`. This is where `Json -> List Json` earns its keep: `.[]` fans
out to many outputs, `|` threads the stream via `flatMap`. Most satisfying
milestone.
- Teaches: the `List` monad, `flatMap`, do-notation over `List`.
- Done when: `.users[] | .name` works.

### M4 — Builtins + higher-order filters
Add `length`, `keys`, `select(f)`, `map(f)`. `select`/`map` take a *filter as an
argument*.
- Teaches: filters-as-values, comparisons (for `select`).
- Done when: `.[] | select(.age)` and `map(.name)` work.

### M5 — Polish (stretch)
`-r` raw output, compact vs pretty print, read from a file arg instead of stdin,
real error messages (this is where `Result` threading pays off).
- Teaches: CLI ergonomics, formatting.

---

## File layout

`medaka new` scaffolds flat with `entry = "main.mdk"` at the root. Keep sibling
modules flat next to it:

```
mq/
  medaka.toml      -- entry = "main.mdk"
  main.mdk         -- CLI: args, read input, drive pipeline, serialize outputs
  filter.mdk       -- the Filter ADT + string->Filter parser
  eval.mdk         -- eval : Filter -> Json -> List Json
```

Start with `filter` + `eval` in `main.mdk`; split them out at M3 when it grows.
`main.mdk` imports siblings by bare module name (`import filter`, `import eval`).

## Stdlib you'll lean on

`json` (parse/serialize), `io` (`readAll`, `readFile`, `putStrLn`), `string`
(the parser), `list` (`flatMap`/`map`/`filter` — the stream engine), `Result`.

## Scope boundary (so it doesn't balloon)

- **In:** projection/query — field access, indexing, iteration, pipe,
  `select`/`map`, a few builtins.
- **Out:** arithmetic expressions, `as $x` bindings, `reduce`, recursive descent
  `..`, path expressions, assignment. `mq` is a *query* tool, not a transform
  language.

Effort: M0–M2 in an evening or two; M3–M4 another session or two. ~3–5 sittings.

---

## Why this project (the actual goal)

Self-hosting already hammers ADTs, pattern matching, recursion, and maps. `mq`
is chosen to hit the language's **blind spots**: real I/O, CLI ergonomics, error
handling at boundaries, and stream/`List`-monad composition.

So the deliverable isn't the tool — it's `NOTES.md`: every "I reached for X and
it wasn't there / was awkward." Expect rough edges here, and log them:

- **String parsing ergonomics** — `string.mdk` is frozen with known gaps
  (`length`/`isEmpty` absent over a Foldable clash). Char-by-char parsing may
  feel clunky. Prime signal.
- **`Result` threading** through parser + eval — how pleasant is do-notation over
  `Result`?
- **`Json` pattern matching** — is matching/indexing the (Array-backed) `Json`
  comfortable?
- **Stream semantics** — does `flatMap` / do-notation over `List` read naturally?

That list is what feeds back into the language initiatives.
