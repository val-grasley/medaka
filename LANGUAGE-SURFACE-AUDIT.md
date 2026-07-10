# LANGUAGE-SURFACE-AUDIT.md

**Read-only language-surface audit for the 0.1.0 public-preview trim.** Goal: find
optional/sugar/rare constructs that don't pull their weight, so a newcomer learns a small,
coherent language. This doc **recommends**; a later batch does any cutting. Nothing here was
built or edited beyond this file.

Scope of "dogfood" = genuine syntactic use in the two biggest Medaka codebases, `compiler/*.mdk`
and `stdlib/*.mdk` (comment/string/identifier occurrences excluded — disambiguation noted per
construct). Sources enumerated: `SYNTAX.md`, `test/parse_fixtures/rare_constructs.mdk`, the lexer
keyword table (`compiler/frontend/lexer.mdk:403–434`), and the AGENTS.md "Dogfooding" list.

## Verdict axes (four)

A construct earns its place if it is EITHER (a) meaningfully **dogfooded**, OR (b) a real
**newcomer ergonomic win**, OR (c) **irreplaceable**, OR (d) a deliberate **future strategic
seam** (foundational idiom / planned-work hook / costly-to-re-add). The DEFAULT prior stays: *if
we haven't used it by now, that is real evidence it isn't pulling weight* — low usage counts
against a construct. Axis (d) spares something only with a **concrete** future-use rationale, not
"might be handy someday." Cut only what is low on ALL four AND redundant with an existing feature.

Verdict buckets: **KEEP** (earner / high newcomer value / irreplaceable) · **KEEP-FOR-FUTURE**
(low usage now, concrete strategic seam) · **REMOVE** (dead-weight: low on all axes + redundant) ·
**RESERVE-WITH-HINT** (remove the construct, keep the keyword reserved as a beginner hint) ·
**DISCUSS** (borderline — human call).

---

## Ranked table

Ordered by verdict strength (clear cuts first, clear keeps last). Dogfood = compiler+stdlib genuine
uses.

| Construct | Dogfood uses | Newcomer value | Future strategic value | Redundant with | Verdict | Blast radius |
|---|---|---|---|---|---|---|
| **`function` keyword** (point-free matching lambda) | **0** | lo | lo | `f x = match x` / multi-clause defs — and `rule-match-on-param` *discourages* exactly this shape | **RESERVE-WITH-HINT** | Medium; dedicated `EFunction` AST node, ~13 `.mdk` arms, desugars early → mechanical |
| **backtick infix** `` x `f` y `` | **0** | lo–med | lo | prefix application `f x y`; symbolic operators | **DISCUSS (lean REMOVE)** | Small; `EInfix` node (14 files), no desugar-early shortcut (survives to eval) |
| **unary `!`** (boolean not, prefix) | **0** | med | lo | `not` (prelude fn) | **DISCUSS (lean REMOVE)** | Tiny; shares `EUnOp` with unary minus — parser/eval string-keyed, no node to delete |
| **`let rec … with`** (inline/local mutual rec) | **0** | lo | lo | top-level defs are *implicitly* mutually recursive (no keyword) | **DISCUSS** | Small; parser + `ELetGroup` handling. `let rec` (single, non-`with`) still needed for local recursive lambdas |
| **`let … else`** (refutable let-else) | **0** | med | lo–med | `match`/`if let` early-return | **DISCUSS** | Small; parser + `ELet` refutable path + `llvm_emit` gap note |
| **left section `(2 * _)`** (explicit-`_` form) | **0** | med | med | right/bare sections + lambda | **KEEP** (family coherence) | n/a — cutting only the `_` form fragments the section family the linter promotes |
| **compose `>>` / `<<`** | `>>` 1, `<<` 0 | med | **hi** (see note) | pipe `\|>` / lambda | **KEEP-FOR-FUTURE** | n/a |
| **pipe `\|>`** | 6 (one pipeline, desugar.mdk) | **hi** | hi | nested application / lambda | **KEEP** | n/a |
| **operator sections** bare `(+)` / right `(+1)` | bare ~5, right ~3 | hi | med | lambdas | **KEEP** | n/a — `rule-lambda-section` actively rewrites lambdas *into* these |
| **refutable pattern-guards** `Pat <- e` | 4 (all `exhaust.mdk`) | med | med | nested `match` | **KEEP** | n/a — recently hardened (native resolve/typecheck fixed 2026-06-15) |
| **inclusive `..=` / exclusive `..` ranges** | `..=` 1, `..` 1 | **hi** | hi | manual `range` helpers | **KEEP** | n/a — core numeric/collection ergonomics; `[1..=10]` is table-stakes |
| **as-patterns** `x@(…)` | ~42–54 | med | med | re-bind + destructure separately | **KEEP** | n/a — real dogfood |
| **record/variant update** `{ r \| f = v }` | ~24 | hi | hi | manual reconstruct-all-fields | **KEEP** | n/a — real dogfood, no substitute for immutable update |
| **string interpolation** `\{e}` | ~1594 | **hi** | hi | `++` / `debug` concatenation | **KEEP** | n/a — ubiquitous, highest-value newcomer sugar |
| **do-notation** `do { x <- … }` | ~323 | **hi** | hi | manual `andThen`/`pure` | **KEEP** | n/a — heavily dogfooded (parser combinators, JSON) |
| **`deriving (…)`** | 2 decl-sites (+30 test files) | **hi** | hi | hand-written Eq/Ord/Debug impls (`rule-*` *discourages* hand-rolling) | **KEEP** | n/a — foundational; the linter steers *toward* it |
| **`let mut`** | 0 (being removed) | — | — | `Ref` | *in-progress (P0-5)* | not re-audited |

Newcomer/strategic ratings are user-facing judgments, not usage counts — e.g. string interpolation
is low-ceremony-but-omnipresent and `deriving` is barely used in the terse compiler yet is a
headline newcomer feature. Do **not** cut newcomer sugar because the compiler is written tersely.

---

## Recommended trim batch

Only **one** construct is a clean, low-risk cut. The rest of the low-usage set is deliberately
routed to DISCUSS because each trips a newcomer-value or coherence concern.

### CONFIRMED — `function` keyword → RESERVE-WITH-HINT

- **Why:** 0 keyword-position uses across compiler+stdlib (365 raw "function" hits are all the
  English word in comments/strings or the `TFunction`/`EFunction` identifiers). It desugars to
  exactly `\x => match x` (`desugar.mdk:199` → `ELam [PVar "__fn_arg"] (EMatch (EVar "__fn_arg")
  arms)`), i.e. the same shape as `f x = match x`, which the linter's `rule-match-on-param`
  actively **discourages**. Low on all four axes + redundant. This is the textbook cut.
- **Recommendation:** remove the `EFunction` construct but **keep the `function` keyword reserved**
  with a beginner-hint diagnostic ("`function` isn't a keyword here — write a multi-clause
  definition or `x => match x`"). Reserving avoids a silent identifier-capture footgun and gives
  newcomers a signpost.
- **Removal surface (blast radius):**
  - AST: `EFunction (List Arm)` in `frontend/ast.mdk`.
  - Desugar: `desugar.mdk:96` (`mapKids`), `:199` (`rewriteSugar`) — this is where it dies; because
    it desugars *before* resolve/typecheck, every downstream `EFunction` arm is defensive/dead.
  - Exhaustive arms in ~13 `.mdk` files: `resolve`, `marker`, `types/typecheck`, `types/annotate`,
    `frontend/exhaust`, `ir/core_ir_lower`, `ir/sexp` (`:158`), `backend/private_mangle`,
    `tools/lint`, `tools/check_policy`, `frontend/parser`, `frontend/desugar`, `frontend/ast`.
    **Exhaustiveness-self-guiding:** delete the constructor and the self-hosted compiler flags every
    orphaned arm — mechanical, not logic-threading.
  - Lexer (only if going full-remove rather than reserve): `TFunction` at `lexer.mdk:87, 186, 288,
    434`, and `armsHerald` (`:1206–1208`, which lets `function` open an arm block). For
    RESERVE-WITH-HINT, **keep** the token + `keywordOrIdent` mapping and swap the parser action for
    a diagnostic.
  - Parser: the `function`-lambda production.
  - Fixtures: `test/construct_fixtures/function_keyword.mdk` (+ `.build.golden`),
    `test/parse_fixtures/rare_constructs.mdk` (the `classify = function …` block).
  - Docs: `SYNTAX.md` (Lambdas §), `AGENTS.md` Dogfooding list, `STYLE.md`, `CONSTRUCT-COVERAGE.md`.

---

## DISCUSS (needs a human call)

Each is 0-dogfood, but has a non-usage reason not to auto-cut. Surface both directions.

1. **backtick infix `` x `f` y ``** — 0 genuine uses (every backtick in source is a Markdown code
   span inside a `{- -}`/`--` doc comment). *Cut:* redundant with prefix application; `EInfix`
   survives all the way to eval (14 files carry arms), so it's real surface. *Keep:* Haskell/Ord
   users expect it; it's a one-line reader for `` a `div` b ``. **Lean REMOVE** — lowest newcomer
   value of the sugar set and fully redundant, but confirm no editor/teaching material leans on it.

2. **unary `!` (boolean not)** — 0 genuine uses; every `!` in source is `!=`, a char/string, or the
   `EUnOp "!"` machinery. *Cut:* `not` already exists and reads clearer for a functional audience;
   `!` invites C-style habits and collides visually with `!=`. *Keep:* near-universal muscle memory;
   tiny (no dedicated AST node — shares `EUnOp`, string-keyed in parser/eval, so removal is a parser
   guard + eval arm, not a node deletion). **Genuinely borderline** — the cost to keep is almost
   nil, which weakens the case to cut.

3. **`let rec … with` (inline/local mutual recursion)** — 0 uses. *Cut:* top-level bindings are
   *already* implicitly mutually recursive with no keyword, so the `with` clause is redundant for
   the common case; the compiler itself never reaches for it. *Keep:* it's the only way to express
   *local* mutual recursion inside a body. **Recommendation:** keep single `let rec` (needed for
   local recursive lambdas), DISCUSS dropping only the `with`-group extension.

4. **`let … else` (let-else)** — 0 uses; implemented but never dogfooded (see the `llvm_emit.mdk`
   gap note). *Cut:* `if let` / `match` already cover refutable-bind-or-diverge. *Keep:* it's a
   clean early-return idiom newcomers from Rust/Swift expect. **Borderline** — medium newcomer
   value, zero cost-of-carry evidence either way.

5. **compose `>>` / `<<` → KEEP-FOR-FUTURE (flagged, not a cut)** — `>>` has 1 use
   (`core.mdk:174` `clamp lo hi = min hi >> max lo`), `<<` has 0. *The concrete future rationale:*
   Medaka bills itself as a *pragmatic functional* language; point-free composition is a
   foundational FP primitive that pairs with the already-KEEP pipe `|>`, is cheap to carry (shares
   the binop path, no dedicated AST node), and is **costly to re-add credibly later** (removing then
   re-introducing a core operator churns docs, teaching material, and muscle memory). This is the
   one construct where "low usage now" should *not* trigger a cut. If forced to prune, `<<`
   (right-to-left) is the more expendable half — but keeping the symmetric pair is cleaner.

## Bottom line

- **One clean cut:** `function` keyword → RESERVE-WITH-HINT (0 uses, redundant, lint-discouraged;
  mechanical exhaustiveness-guided removal).
- **One explicit spare:** compose `>>`/`<<` → KEEP-FOR-FUTURE (foundational point-free seam).
- **Four to adjudicate:** backtick infix (lean REMOVE), unary `!` (borderline), `let rec … with`
  (drop only the `with`), `let-else` (borderline).
- **Everything else earns its place** on dogfood usage (sections, as-patterns, record update, do,
  interpolation), high newcomer value (ranges, interpolation, deriving), or recent investment
  (refutable pattern-guards). Do not cut them for the compiler's terseness.

The removal surface for the low-usage set is dominated by dedicated `test/construct_fixtures/*`
goldens and reference docs (`SYNTAX.md`, `language-design.md`, `STYLE.md`, design docs) rather than
compiler logic — so any cut is mostly fixture + doc churn plus a mechanical AST-arm sweep.
