# Findings — SQL expression parser (`sqlite/lib/sqlparse.mdk`)

Task: build `parseSqlExpr : String -> Result String SqlExpr` on the `parsec` combinator
library, via a cross-project dependency. Stage 1 of the SQL front end.

**Headline:** one **soundness bug** (F1 — `medaka build` silently miscompiles a partially
applied constructor; `check` and `run` are both clean, so this is only reachable in a
native build) and one **diagnostics hole** (F4 — a parse error in an *imported* module was
reported as an unlocated `E-PANIC`, even under `--json`; ✅ **FIXED, re-verified 2026-07-23**).
Both have minimal reproducers.

---

## F1 — `medaka build` silently miscompiles a partially-applied data CONSTRUCTOR

- **Category:** compiler-bug
- **Severity:** blocker (workaround found; without it, *every* arithmetic operator in the
  grammar was broken in a native build while passing `check` + `run` + all doctests)
- **Repro:** 18 lines, prelude only — no `sqlite`, no `parsec`, no stdlib import.
  ```medaka
  data Op = Add | Mul
  data E = Lit Int | Arith Op E E

  -- `Arith o` is a PARTIAL APPLICATION: `Arith` has arity 3, we supply 1 arg.
  mkOp : Op -> Option (E -> E -> E)
  mkOp o = Some (Arith o)

  -- ...and it is applied to its remaining 2 args later.
  useIt : Option (E -> E -> E) -> E -> E -> E
  useIt None l _ = l
  useIt (Some f) l r = f l r

  render : E -> String
  render (Lit n) = "\{n}"
  render (Arith Add l r) = "(\{render l} + \{render r})"
  render (Arith Mul l r) = "(\{render l} * \{render r})"

  main = println (render (useIt (mkOp Add) (Lit 1) (Lit 2)))
  ```
- **Expected:** `(1 + 2)` from all three of `check` / `run` / `build`.
- **Actual:**
  - `medaka check` → clean (no diagnostics).
  - `medaka run` → `(1 + 2)` ✅
  - `medaka build` + exec → `runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match`

  The `match` in `render` is exhaustive over `E`. The value flowing into it is not a
  well-formed `Arith` node — the PAP is miscompiled, and the corruption only surfaces at
  the next pattern match. **This is a silent miscompile, not a crash at the faulty site.**
- **Characterization** (each variant checked `run` vs `build`):

  | variant | `run` | `build` |
  |---|---|---|
  | ctor PAP in a container (`Some (Arith o)`) | ✅ | ❌ |
  | ctor PAP with **no** container (`useIt (Arith 9)`) | ✅ | ❌ |
  | ctor PAP of a **2-ary** ctor (`Some (P 5)`, `data P = P Int Int`) | ✅ | ❌ |
  | **plain function** PAP (`Some (add3 1)`) | ✅ | ✅ |
  | bare ctor at **exact** arity as a fn value (`pure EOr`) | ✅ | ✅ |
  | eta-expanded lambda (`Some (l r => Arith o l r)`) | ✅ | ✅ |

  So: **constructors only** (plain-function PAPs are fine), **any arity**, **container
  irrelevant**. Applying a constructor to *fewer* args than its arity and calling the
  result later is the trigger.
- **Workaround:** eta-expand the constructor into an explicit lambda. In
  `sqlparse.mdk`, `arithTok` had to become
  ```medaka
  pure (l r => EArith op l r)   -- NOT `pure (EArith op)`
  ```
  There is a comment at that site warning against "simplifying" it back.
- **How it was found / why it is nasty:** the doctests (`medaka test`, which uses the
  interpreter) were **32/32 green** and the probe passed under `medaka run`, while the
  *natively built* probe died instantly. Nothing in the interpreter-backed workflow can
  see this. Anything that only runs `check` + `test` will ship it.
- **Notes:** smells like a residual of the known PAP arc (`compiler/EMITTER-GAPS.md` /
  the 2026-07-02 "wrapped-PAP-then-saturate" fix, which routed non-matching-arity calls
  through `mdk_apply`). That fix covered the *opaque application* path; a partially applied
  **constructor** appears to still take a different route. Worth a `test/llvm_fixtures/`
  regression fixture — the shape is 6 lines.

---

## F2 — ✅ FIXED (re-verified 2026-07-23) — Derived `Debug` does not parenthesize nested constructor arguments

**Status: FIXED.** `debug (O (I 1) (I 2))` now prints `O (I 1) (I 2)` — with parens — matching the
"Expected" below. Left in place as the original repro.

- **Category:** compiler-bug
- **Severity:** workaround-required
- **Repro:**
  ```medaka
  data Inner = I Int deriving (Debug)
  data Outer = O Inner Inner deriving (Debug)

  main = println (debug (O (I 1) (I 2)))
  ```
- **Expected:** `O (I 1) (I 2)` — i.e. re-parseable Medaka, like Haskell's `derive Show`
  (which inserts parens at precedence 11).
- **Actual:** `O I 1 I 2`
- **Why it matters (not cosmetic):** the output is **ambiguous** — several distinct trees
  render identically — so derived `Debug` cannot be used as a test oracle for any nested
  ADT. For a parser, that is exactly the oracle you need. Concretely, my precedence
  assertion would have read:
  ```
  Ok EAnd EBin OpEq ECol "a" ELit LInt 1 EBin OpEq ECol "b" ELit LInt 2
  ```
  which proves nothing about the tree shape. It also means doctest expectations have to be
  written in a form that is not valid Medaka source, which looks like a typo to a reader.
- **Workaround:** hand-wrote `dumpExpr`/`dumpLiteral` in `sqlparse.mdk` — a fully
  parenthesized constructor dump. ~25 lines of pure boilerplate that `deriving (Debug)`
  should have produced. The precedence proofs are built on it.
- **Notes:** likely a missing precedence/paren argument in the `deriving (Debug)`
  expansion in `compiler/frontend/desugar.mdk`. Related nit: `Array` debugs as
  `[|65, 66|]`, which is also not valid source (a `List` debugs as `[65, 66]`) — fine as a
  deliberate Array/List visual distinction, just noting it also blocks copy-paste.

---

## F3 — `medaka run` does not gate on TYPE errors in a multi-module project

- **Category:** compiler-bug / error-message
- **Severity:** workaround-required
- **Repro:** a 2-file project (`medaka.toml` + `lib/t.mdk` + `main.mdk`):
  ```medaka
  -- lib/t.mdk
  public export data Foo = Foo Int

  -- main.mdk
  import lib.t.{Foo}
  main = println "\{Foo 1}"     -- Foo has no Display impl
  ```
- **Expected:** all three commands report the missing `Display` instance. Single-file
  `run` *does* — it prints the same clean diagnostic `check` does, and refuses to run.
- **Actual:** the three commands disagree three ways.
  - `medaka check` → correct and excellent:
    ```
    main.mdk:2:16: No impl of Display for Foo; add 'deriving Display' to the 'Foo' type, or write an 'impl Display Foo'.
    ```
  - `medaka run` → **ignores the type error, evaluates anyway**, and dies with an
    unrelated, unlocated panic:
    ```
    runtime error [E-PANIC]: intToString: not an Int
    ```
  - `medaka build` → right cause, but framed as an internal emitter crash with no source
    location and a leaked internal detail:
    ```
    error: emitter failed compiling .../main.mdk
    runtime error [E-PANIC]: no impl of method 'display' for type 'Foo' (slice 6)
    ```
- **Scope (checked):** **resolve** errors *are* gated by multi-module `run` (an unbound
  variable is reported properly, with a genuinely great message — see F8). Only
  **typecheck** errors leak through. Single-file `run` gates correctly. So the gap is
  specifically *typecheck errors on the loader path*.
- **Workaround:** run `medaka check` before `medaka run` on anything import-bearing, and
  never trust a clean `run`. This cost me real time early on: I read a green `check` on the
  *library* and a panicking `run` on the *probe* as a compiler bug, when the probe simply
  had a type error `run` declined to tell me about.
- **Notes:** `run` on the loader path presumably never consults `hadTypeErrors()`. AGENTS.md
  already documents that the *bootstrap emit path* doesn't gate on `hadTypeErrors()`; this
  looks like the same hole on the `run` path.

---

## F4 — ✅ FIXED (re-verified 2026-07-23) — A parse error in an IMPORTED module is reported as an unlocated `E-PANIC`

**Status: FIXED.** Both `medaka check` and `medaka check --json` now locate the error correctly —
`check` reports `P-PARSE` at `lib/t.mdk:1:42` (the imported module's own file/line/column), not an
unlocated panic on the entry file. Left in place as the original repro.

- **Category:** error-message / tooling
- **Severity:** workaround-required
- **Repro:** 2-file project; put a syntax error in the imported module.
  ```medaka
  -- lib/t.mdk   (deliberate error: `deriving` needs parens)
  public export data Foo = Foo Int deriving Eq

  -- main.mdk
  import lib.t.{Foo}
  main = println "hi"
  ```
- **Expected:** checking `main.mdk` surfaces the imported module's parse error with its
  file/line/column — exactly what checking `lib/t.mdk` directly produces:
  ```
  lib/t.mdk:1:42: unexpected `Eq`; expected `(`
    |
  1 | public export data Foo = Foo Int deriving Eq
    |                                           ^
  ```
- **Actual:** checking `main.mdk` gives, in full:
  ```
  runtime error [E-PANIC]: parse error
  ```
  No file. No line. No column. No caret. **And `medaka check --json main.mdk` emits the
  same bare panic** — so the machine-readable path, which an LSP or an agent keys off, gets
  nothing actionable at all.
- **Workaround:** when a project-level `check` panics with `parse error`, re-run `check`
  on each imported module individually until you find the one that reports properly.
- **Notes:** the loader raises rather than pushing into the accumulating diagnostics
  pipeline (`compiler/driver/diagnostics.mdk`) — which is exactly the "don't add
  exit-on-error paths" rule in AGENTS.md, violated on the loader's parse path. Matches the
  known-open "LSP loader panics on parse error" item.

---

## F5 — parsec's backtracking collapsed every error to a useless position (FIXED, in-library)

- **Category:** ergonomics (library we own) — *fixed*, with a documented residual
- **Severity:** annoyance → resolved
- **Problem:** `orElse` backtracks fully and, on failure of both branches, kept the
  **rightmost** branch's message. Since `choice` folds right, the *shallowest* alternative
  always won, so a deep failure was reported at the position of the last thing tried.
  Separately, `chainl1`/`optional`'s loop tail is `orElse (…) (pure acc)` — a branch that
  **succeeds**, discarding whatever deep failure was found under it.
- **Actual, before (real output from my grammar):**

  | input | error |
  |---|---|
  | `(a + b * c` | `choice: no alternatives at 0` ← flat wrong, blames col 0 |
  | `a = ` | `expected end of input at 2` |
  | `a = 1 AND` | `expected end of input at 6` |
  | `a = 'unterminated` | `expected end of input at 2` |
  | `1 + + 2` | `expected end of input at 2` |

  Every error is "expected end of input" at wherever the last *successful* sub-parse
  stopped — i.e. it blames the token *before* the mistake, and the unclosed-paren case
  blames column 0.
- **Fix (3 changes to `parsec/lib/parser.mdk`, all backward-compatible):**
  1. `orElse` now keeps the **farthest** failure when both branches fail (ties → left, so
     left-bias is preserved). This alone fixed the `choice`-collapse class.
  2. Added `attempt` (rewind a failure's *reported position* to the parser's start) and
     `label` (replace the message of a failure that consumed nothing — classic parsec's
     `<?>`). These let a grammar control which failure "wins".
  3. Made `chainl1` **committed**: `optional op` backtracks over the operator only, and
     once an operator has matched the right operand is mandatory. This is also the
     *faithful* semantics — classic Parsec's `<|>` refuses to backtrack once the left
     branch consumed input, so a matched operator already commits there. Our
     unconditionally-backtracking `orElse` had silently turned `1 +` into a successful
     parse of `1` with `+` left over.
- **Actual, after:**

  | input | error |
  |---|---|
  | `(a + b * c` | `expected ')' at 10` |
  | `a = ` | `expected an expression at 4` |
  | `a = 1 AND` | `unexpected end of input at 9` |
  | `a = 'unterminated` | `unexpected end of input at 17` |
  | `1 + + 2` | `expected an expression at 4` |

  Every error now points at the actual offending column.
- **Residual (deliberately NOT fixed — this is where it would have ballooned):** an
  alternative that **succeeds** still discards deeper failures explored beneath it
  (`optional`/`many`'s loop tail). Fixing that in general requires threading the
  farthest-failure through *success* as well — i.e. carrying it in `POk` too, which means
  touching every one of parsec's ~20 `POk`/`PErr` construction sites. Committing `chainl1`
  sidesteps the dominant instance of it for infix grammars, which is why the table above is
  clean. Flagged for whoever wants to take parsec further.
- **⚠️ For the orchestrator:** `parsec/lib/parser.mdk` is **modified** (`orElse` semantics
  + 2 new exports + committed `chainl1`). Verified: parsec doctests 6/6, `parsec/lib/toml.mdk`
  1/1, and `parsec/main.mdk`'s output is **byte-identical** before/after.

---

## F6 — Recursive combinator grammars: strict argument position ⇒ `E-CYCLIC-VALUE`

- **Category:** surprising-semantics
- **Severity:** annoyance (the diagnostic is good; the rule is just non-obvious)
- **Repro:**
  ```medaka
  atomP : Parser Char
  atomP = choice [parenP, digit]

  parenP : Parser Char
  parenP = between (char '(') (char ')') atomP   -- recursive ref in ARG position
  ```
- **Actual:** `runtime error [E-CYCLIC-VALUE]: atomP refers to itself during
  initialization (non-productive cyclic value)`, correctly located at the use site.
- **Expected:** honestly, this is *right* — and the error is genuinely good (named, located,
  says why). The finding is that the **rule is invisible**: whether a recursive grammar
  works depends on where the recursive reference lands.
  - `between open close p` / `chainl1 p op` take the parser as a **strict argument** → the
    cycle is forced at construction → `E-CYCLIC-VALUE`.
  - The *same grammar* written with `do`-notation works, because the recursive reference
    lands inside a continuation lambda and is only forced when the parser **runs**:
    ```medaka
    parenP = do
      _ <- char '('
      x <- atomP        -- 2nd position ⇒ inside a lambda ⇒ delayed ⇒ fine
      _ <- char ')'
      pure x
    ```
- **Workaround:** every back-edge in `sqlparse.mdk` (`parens`→`sqlExpr`,
  `notPrefix`→`notExpr`, `negAtom`→`atom`) is written with `do`-notation *on purpose*, with
  a comment saying so — otherwise a future "simplification" to `between` reintroduces the
  cycle.
- **Suggestion:** parsec should ship a `delay : (Unit -> Parser a) -> Parser a` combinator
  (every strict-language combinator library has one) so the fix is explicit rather than an
  accident of do-notation's desugaring. I did not add it — the do-notation form covered
  every case here and I did not want to widen the parsec diff further.

---

## F7 — `export data` exports the type but NOT its constructors

- **Category:** ergonomics
- **Severity:** annoyance
- **Repro:** parsec has `export data PResult a = POk a Int | PErr String Int`. Then
  `import parsec.lib.parser.{PResult, POk}` fails:
  ```
  Module 'parsec.lib.parser' has no exported name 'POk'
  ```
  The distinction is `export data` (type only) vs `public export data` (type +
  constructors) — `sqlite/lib/select.mdk` uses the latter.
- **Expected:** the error is clear and I recovered in one iteration, so this is minor. But
  the message names the *constructor* as "not exported" without mentioning that the
  **type** was exported and that `public` is the knob. A hint (`did you mean 'public export
  data PResult'?`) would close it instantly.

---

## F8 — stdlib discovery: `List` helpers live on the prelude, not in `list`

- **Category:** ergonomics
- **Severity:** annoyance
- **Repro:** `import list.{elem}` / `import list.{map}` / `import list.{length}` all fail
  with e.g. `Module 'list' has no exported name 'elem'`. They are prelude `Foldable`/
  `Mappable` methods and must be used **bare**, with no import at all.
- **Expected:** reasonable once known, but the reflex "it operates on a List, so it's in
  `list`" is wrong three times in a row, and the error doesn't say where the name *does*
  live. `Module 'list' has no exported name 'elem' (it is a prelude Foldable method — use
  it unqualified)` would be a one-line fix.
- **Positive callout, worth keeping:** the neighbouring diagnostic is *excellent* and is
  exactly the standard `compiler/ERROR-QUALITY.md` asks for —
  ```
  Unbound variable: foldl. Did you mean 'fold' ('foldl' is Haskell; Medaka uses 'fold')
  ```
  That message told me the name, the fix, *and* why I got it wrong. More of these.

---

## Categories with nothing to report

- **Missing stdlib:** none. Everything the parser needed already existed and worked first
  try: `string.{toUpper, toInt, toFloat, fromChars, isAlpha, isAlphaNum, replaceAll}` and
  `hex.{decode, encodeUpper}`. **No `stdlib/` changes were made.**
- **Cross-project imports (`sqlite` → `parsec`):** flagged as "lightly travelled", but it
  was **frictionless**. Adding
  ```toml
  [dependencies]
  parsec = "../parsec"
  ```
  to `sqlite/medaka.toml` and writing `import parsec.lib.parser.{…}` worked on the first
  attempt, under `check`, `run`, `test` *and* `build`. No findings.
- **Typeclass / dispatch friction:** flagged as historically rich; I hit **none**.
  `do`-notation over parsec's user-defined `Thenable Parser`, `orElse` from `Alternative`,
  `map` from `Mappable`, and the derived `Eq`/`Debug` on a recursive ADT all dispatched
  correctly through `run` *and* the native build. (F1 is a backend PAP bug, not dispatch.)
- **⚠️ Note for the orchestrator on the `select.mdk` diff:** besides the four
  `deriving (Eq, Debug)` additions, the diff contains hunks rewriting `chars.[i]` →
  `chars[i]` and re-wrapping two one-line `data` decls. Those are **not mine** — they are
  `medaka fmt --write` output. `sqlite/lib/select.mdk` at HEAD already fails
  `medaka fmt --check` ("not formatted"): the `.[i]` → `[i]` Index-syntax migration never
  reached it. `fmt --check` and `fmt --write` **agree** (verified on the pristine file), so
  this is not a `fmt` bug — just a stale file. The pre-commit hook requires staged `.mdk`
  to be fmt-clean, so staging `select.mdk` at all forces the normalization. Doctests stay
  14/14 and `select_demo` still builds.
- **`fmt` / `lint`:** no bugs. `fmt --write` was idempotent and never corrupted anything;
  `lint` caught three real style nits in my code (`rule-when-unless`, two
  `rule-lambda-section`) and its cross-file `rule-duplicate-body` correctly spotted that my
  local committed `chainl1` duplicated parsec's — which is what prompted the principled fix
  in F5 rather than leaving a fork. The linter did its job well here.
