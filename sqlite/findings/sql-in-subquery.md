# `WHERE col IN (SELECT …)` subqueries — design + friction log

Adding non-correlated `expr [NOT] IN (SELECT …)` to the SQL front end + engine.
Pure-Medaka library change (parser, AST, renderer, executor); no compiler edits.

Scope shipped: **non-correlated** `IN (SELECT …)` and `NOT IN (SELECT …)`, where the
subquery may be a single SELECT or a compound (`… UNION SELECT …`). The subquery is
evaluated **once**, must project **exactly one column**, and its membership routes
through the existing three-valued `IN` evaluator so SQLite's NULL rules match exactly.
Explicitly OUT of scope (each a clean error, never a wrong answer): **correlated**
subqueries, scalar `= (SELECT …)`, and `EXISTS`.

Verified differentially against `sqlite3` 3.46.1: `test/sql_oracle.sh` now runs **206
queries / 0 diffs** (14 new subquery rows), **37 rejections** (multi-column + correlated
+ CTE), round-trip 87/87. The three-valued NULL cases were each checked against `sqlite3`
by hand first (see the corpus comments).

---

## F1. THE parse cycle — and why the "obvious" fix was unavailable

`expr IN (SELECT …)` means the **expression** grammar (`lib/sqlparse.mdk`) must parse a
**SELECT** — but the SELECT grammar lives in `lib/sqlstmt.mdk`, which already
`import`s `sqlExpr` FROM `sqlparse`. That is a genuine module-level mutual recursion, and
the loader forbids an import cycle. There is no way around injecting the sqlstmt-side
parser into sqlparse at **run time** — either as a threaded parameter or through a hole.

**First instinct: a `Ref (Parser Compound)` hole with a deferring parser** that reads the
hole at parse-run time:

```
subqueryParser = Parser (input pos => runP (hole.value) input pos)   -- ✗ won't compile
```

This needs to construct a raw `Parser (…)` and, inside `runP`, a `POk`. **`parsec/lib/
parser.mdk` does not export its `Parser` / `POk` / `PErr` constructors** — only the
combinators and `runP`. (`export data Parser a = Parser (…)` exports the type but not the
constructor unless imported by name, and it isn't; `import parsec.lib.parser.{POk}` fails
with *"has no exported name 'POk'"*.) parsec is not an owned file, so exporting them was
off the table.

**Resolution actually shipped — a hole tied through the COMBINATORS only** (no raw `Parser`
construction, no parsec edit):

```
subqueryParserHole : Ref (Parser Compound)
subqueryParserHole = Ref (failWith "…requires the statement parser…")

-- defer the hole READ to run time by keeping it inside map's continuation:
subqueryParser : Parser Compound
subqueryParser = do
  p <- map (_ => subqueryParserHole.value) (pure ())   -- read at RUN time
  p                                                     -- then run it (join)
```

`map (_ => hole.value) (pure ())` is a parser that, when run, applies its function and so
reads the hole **then** — not at construction. `do { p <- that; p }` joins it. `lib.sqlstmt`
installs the hole as the first step of each parse entry (`statement`, `queryStatement`,
`statementAny`):

```
setSubqueryParser p = map (_ => (subqueryParserHole := p)) (pure ())   -- side effect in map's fn
…
statement = do { _ <- spaces; _ <- setSubqueryParser compoundP; … }
```

Because the write also sits inside `map`'s continuation, **building `setSubqueryParser
compoundP` never forces `compoundP` at construction** — which is what keeps the knot from
re-entering the cycle. The hole is a shared top-level `Ref` CAF (verified: a top-level
`Ref` is memoized/shared, and a `:=` through one reference is visible through another), so
one install serves every later parse.

At the `IN (` suffix, subquery-vs-value-list is decided by `orElse`, no explicit peek: the
subquery branch begins with an `attempt`-wrapped `keyword "SELECT"`, so on a value list it
fails **without consuming** and `orElse` falls cleanly to the value-list branch; a broken
`SELECT` commits and wins parsec's farthest-failure race.

## F2. The RENDER cycle is the SAME cycle, and pure — a second hole

`renderSqlExpr` (sqlparse) renders an expression; to render `EInSubquery`'s `Compound` it
needs `renderCompound` (sqlstmt) → same one-way-dependency cycle, but on the **pure** side
(no `Parser` monad to sequence an install into). Resolved with a second hole
`subqueryRenderHole : Ref (Compound -> String)`, installed by a **strict `let`** at each
sqlstmt render entry (`renderSelect`/`renderCompound`/`renderStmt`):

```
renderSelect (Select {…}) =
  let _ = setSubqueryRenderer renderCompound   -- strict ⇒ the := runs before the body
  …
```

Every render path that can reach an `EInSubquery` (via a WHERE) comes THROUGH one of those
entries, so the hole is always installed by the time `renderSqlExpr (EInSubquery …)` reads
it. `renderSelect`/`renderCompound` are mutually recursive **functions** (not nullary
values), so naming each other is fine — no cyclic-value hazard.

The **placeholder** projection (`lib.select.render`, `?`-binds) does NOT have this problem:
its subquery renderer `renderCompoundParam` lives in `lib.select` and reuses `render`
per-arm, so it is self-contained (no hole). Only the INLINE round-trip renderer, split
across the two modules, needs the forward reference.

## F3. Db-threading → materialization (the executor seam)

The three-valued predicate evaluator (`compileTri`) has no `Db` and runs per-row; a
subquery needs the `Db` and must run ONCE, before the row scan. Rather than thread `Db`
through `compileTri`/`compileOperand`/join-ON/HAVING (many call sites, plus `lib.mutate`),
the subquery is **pre-materialized**:

`runPipeline` now calls `materializeSelect db sel` first, which walks every expression slot
(WHERE, join ONs, GROUP BY, HAVING, ORDER BY, projection), runs each `EInSubquery col q`
via `runCompoundCells db q` (a refactor of `runCompound` that stops before decode), and
rewrites the node to an ordinary **`EIn col [ELit lit, …]`** (`cellToLiteral` inverts
`litToCell`). After this pass no `EInSubquery` survives, so nothing downstream needs
subquery awareness. Nested subqueries fall out for free: `runCompoundCells` → `runPipeline`
→ `materializeSelect` again.

**The `EIn` rewrite is the key simplification.** Membership then reuses the exact `inTri`
evaluator the literal `IN (1,2,3)` form uses, so SQLite's subtle NULL semantics are matched
by construction rather than re-derived:

| case | result | reason |
|------|--------|--------|
| `x IN S`, x matches some v | TRUE | TRUE dominates the OR-of-equalities |
| `x IN S`, no match, S has a NULL (or x is NULL) | **UNKNOWN** ⇒ row dropped | the NULL comparison is UNKNOWN, survives the OR |
| `x IN S`, no match, no NULL | FALSE | |
| `x IN (empty)` | FALSE (even x=NULL) | empty short-circuits before NULL |
| `NOT IN` | three-valued negation of the above | `NOT UNKNOWN = UNKNOWN` |

All verified against `sqlite3`. The famous trap — `x NOT IN (SELECT … containing a NULL)`
drops **every** row — works: e.g. `amount NOT IN (SELECT amount FROM orders)` returns
nothing because `orders.amount` has a NULL.

Column-count check: `selectColumnCount db (first arm)` before running; `!= 1` ⇒ `Err
"sub-select returns N columns - expected 1"` (SQLite's own message). Correlated subqueries
need no special handling — the inner scan's lookup resolves only its own tables, so an outer
column reference is a clean `unknown column` error.

## F4. Smaller frictions

- **WasmGC partial-constructor hazard (B1w).** `lib.sqlparse` documents that the WasmGC
  backend miscompiles a **partially-applied constructor** passed as a value (`pure
  (EArith op)` fails to emit). So `materializeExpr` rebuilds every node via FULL application
  in do-blocks (`Ok (EBin op l2 r2)`), never `map (EBin op) …` — matching the existing
  `rewriteInner` style. Bare 1-arg constructors as map fns (`map ENot …`) are fine (already
  used in `rewriteInner`); it is the multi-arg partials to avoid.
- **`Ok { r | … }` needs a `let`.** A record-update block passed directly to a constructor
  (`Ok { sel | f = v, … }` spanning lines) parsed as *"Ok has no field f"*; binding it first
  (`let sel2 = { sel | … }; Ok sel2`) fixed it.
- **IO is not a monad** — a probe `main = do { println …; println … }` fails
  (*"andThen expects a container … got Unit"*); use one `println` with an interpolated
  multi-line string, or `let _ = println …`.
- **Worktree isolation classifier vs bash.** A compound command with `$(…)`, a `>` redirect,
  or a `for`-loop over a variable is REFUSED (*"too complex to verify it stays inside the
  worktree"*). Every verification here was run as plain, separate commands with the absolute
  worktree path hardcoded (or via a script file). No `MEDAKA_ROOT="$(pwd)"` — write the path.

## F5. Deferred / not done

- **Correlated subqueries, scalar `= (SELECT …)`, `EXISTS`** — out of scope by design.
- **`UPDATE/DELETE … WHERE x IN (SELECT …)`** now PARSES (the WHERE slot shares `sqlExpr`),
  but `lib.mutate` compiles its predicate without `materializeSelect`, so execution reaches
  `compileTri (EInSubquery …)` → a clean `internal:` error, not a wrong answer. Supporting it
  is a `lib.mutate` change (not an owned file here). Not gated by any oracle; documented so the
  next person knows it is a loud stub, not silently broken.
