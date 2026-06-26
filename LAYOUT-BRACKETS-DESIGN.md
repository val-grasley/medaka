# LAYOUT-BRACKETS-DESIGN — block expressions inside brackets

Status: DESIGN (2026-06-23). Goal: allow `match`/`do`/`function`/`record`/bare-`INDENT`
block-expressions to appear directly inside `( )` `[ ]` `{ }`, so code need not lift every
`=> match …` body into a named top-level helper (as `parsec/lib/parser.mdk` had to). Companion
ground truth: `LAYOUT-SEMANTICS.md` (§6 is revised by this design).

## 1. Root cause — TWO independent gates (both must be opened)

Reproduced on `./medaka check`: bare `f x = match x ⏎ arms` works; `(match x ⏎ arms)`,
`[match …]`, `(do …)`, `({a=1 ⏎ ,b=2})`, `(x => match x ⏎ arm)` all parse-error — in BOTH the
native compiler and the OCaml oracle. Free-form continuation `(x + ⏎ y)`, `[1, ⏎ 2]` works;
single-line `(let y = … in y)` works; one-line `(match x 0=>1 _=>2)` fails (proving the parser
needs INDENT/DEDENT to delimit arms — not merely a newline issue).

**Gate A — lexer suppresses layout tokens inside brackets (LAYOUT-SEMANTICS §6).**
- OCaml `lib/lexer.mll:148` — `handle_indent` opens `if !paren_depth > 0 then ()`; `paren_depth`
  bumped by every opener (`(`:467, `[`:469, `{`/`[|`/`.{`:433,449,472). The newline rule (`:373`)
  computes the column but `handle_indent` discards it inside brackets ⇒ no NEWLINE/INDENT/DEDENT.
- Selfhost `compiler/frontend/lexer.mdk:833` — `afterNl … | depth > 0 = scan …` emits no
  `RNewline`; depth bumped in `scanOp`/`openBrace` (`:762-768,:804`); 2nd-pass `layout` (`:881`)
  never sees a bracket-interior newline. Structurally mirrors OCaml.

**Gate B — the grammar forbids block expressions inside brackets (independent of A).**
- `lib/parser.mly:800` parens parse `LPAREN expr_no_block RPAREN`. `expr_no_block` (`:612`) →
  `expr_lam` (single-line `LET…IN`, lambdas) but NOT the block forms `MATCH … INDENT arms DEDENT`
  (`:667`), `DO INDENT stmts DEDENT` (`:671`), `FUNCTION …` (`:669`), bare-block `INDENT stmt+ DEDENT`
  (`:457`) — those live in `expr`, deliberately excluded. `[ ]` (`:811-823`) and records likewise
  consume `expr_no_block`. So even with tokens present, `(MATCH … INDENT …)` has NO production.
- Mirror in `compiler/frontend/parser.mdk` (recursive-descent; same expr-vs-expr_no_block split).

The `expr_no_block`/`expr` split exists PRECISELY to avoid LR conflicts → re-merging is the main
cost driver.

## 2. Feasibility verdict

**No clean small lexer-only fix.** It's a moderate two-lexer + two-grammar change. The core
tension: free-form bracket layout = "newlines invisible"; herald-block layout = "newlines structure
arms" — irreconcilable globally, so the fix must be **context-sensitive**: per open bracket, track
whether a herald armed a nested layout context and treat newlines accordingly. That is a
layout-context stack interleaved with bracket depth (a "bracket frame"), closer to Haskell's `L` —
NOT a one-line rule, but NOT a from-scratch rewrite either.

Hard cases: (i) continued operand less-indented than opener `(x + ⏎ y)` — existing trailing-op
rule I.a keeps it safe if newlines flow through I.a not popDedents; (ii) `,`-led shallow list line
`[1, ⏎ 2]` — DANGEROUS: I.b would open a block; must NOT open a nested context for non-herald lines;
(iii) closing bracket with arms pending — must flush pending DEDENTs before the closer; (iv) nested
heralds — needs the full frame stack, not a boolean. No `parse-error(t)` close (consistent with
the decided no-parser→layout-feedback rule); use an explicit bracket-aware close.

## 3. Blast radius + risk

- `grep '(match'/'(do'/'(let'` over `stdlib/ compiler/` → ZERO in code (only docs): GAINING the
  feature breaks nothing. Risk is entirely in NOT regressing free-form continuation of existing
  multi-line list/record/operator wraps (~20 files have trailing-`(` lines). Those are the
  regression-fixture targets.
- Two lexers must stay BYTE-IDENTICAL (`diff_compiler_lexer`, `diff_compiler_lex_files`,
  `bootstrap_lex`). Selfhost lexer is in the emitter self-compile graph ⇒ `selfcompile_fixpoint.sh`
  C3a/C3b + seed re-mint at the checkpoint.
- Grammar: new Menhir productions risk shift/reduce + reduce/reduce conflicts (the very split being
  re-merged). Contain via a dedicated `bracket_block` nonterminal.
- Size estimate: lexer ~30-60 lines each; grammar ~3-6 productions each + conflict resolution. A
  focused multi-day change.

## 4. DESIGN FORKS — recommendations (CONFIRM/ADJUST, then mark LOCKED)

- **(a) Which heralds inside brackets?** REC: `match`, `do`, `function`, record, bare-`INDENT`
  block. DEFER `let…in` multi-binding groups and bracketed `if/then/else` (own-line-`in` +
  dangling-else hazards; rarely needed in brackets). [LOCKED 2026-06-23 ✓]
- **(b) Close rule?** REC: close on EITHER a dedent to ≤ the herald block column OR the matching
  bracket closer (whichever first); the closer force-flushes all contexts opened in this frame
  (emit their DEDENTs before the closer). No parse-error close. [LOCKED 2026-06-23 ✓]
- **(c) Same-line arms?** REC: require a newline after the herald (deeper-line form only);
  `(match x 0=>1 _=>2)` stays a parse error — matches bare-`match`. [LOCKED 2026-06-23 ✓]
- **(d) Full Haskell `L` rewrite vs targeted frame?** REC: targeted bracket frame
  `(entryDepth, openedContexts)`; NOT a full rewrite (unjustified risk vs the frozen oracle).
  [LOCKED 2026-06-23 ✓]
- **(e) Free-form default, change only on herald?** REC: YES — load-bearing. Inside brackets the
  default stays "newlines invisible" (current §6 preserved exactly); ONLY when `isOpener` arms does
  that frame emit layout tokens for the herald's block. Confines the change; keeps the regression
  surface tiny. [LOCKED 2026-06-23 ✓]

## 5. Staged implementation plan (ascending risk, each independently gated)

1. **Spec** — extend `LAYOUT-SEMANTICS.md §6` with the bracket-frame model + (a)-(e). Zero binary risk.
2. **Grammar** (before the lexer, so tokens have a target) — add a `bracket_block` nonterminal +
   productions to `lib/parser.mly` and mirror in `compiler/frontend/parser.mdk`. Gate: `dune build`
   (Menhir conflict count must not regress), `test_parser`, `test_roundtrip`. Iterate conflicts here.
3. **Lexer — compiler FIRST** (canonical), bracket frame + herald-armed context in
   `afterNl`/`scanOp`/`closeBrace` + close-flush; then mirror BYTE-IDENTICALLY into `lib/lexer.mll`
   `handle_indent` + bracket rules. Gate: `diff_compiler_lexer`, `diff_compiler_lex_files`,
   `bootstrap_lex`, lextok dumps on new fixtures AND the full existing corpus (free-form regression).
4. **Fixtures** — positives (bracketed match/do/function/record, one level + nested) + negatives/
   regressions (`[1,⏎2]`, `({a=1⏎,b=2})`, `(x +⏎ y)`, own-line `let…in`) in `test/parse_fixtures` +
   layout probes; capture goldens (mind path-stability + capture_goldens corpus-wide footgun).
5. **E2E + fixpoint + seed** — `diff_compiler_*` (typecheck/eval/build), `selfcompile_fixpoint.sh`
   C3a/C3b, re-mint the emitter seed. Dogfood: revert `parsec/lib/parser.mdk`'s lifted helpers to
   inline `=> match` and confirm it checks.

Decisive gates: byte-identical-lexer (`diff_compiler_lexer` + `bootstrap_lex`) = hard wall;
`selfcompile_fixpoint` + seed = release wall; Menhir conflict count = grammar wall.

## Critical files
- `compiler/frontend/lexer.mdk` (canonical lexer; gate `:833` `afterNl`, frame in
  `scanOp`/`openBrace`/`closeBrace`, layout pass `:881`)
- `lib/lexer.mll` (oracle lexer; gate `:148` `handle_indent`, bracket depth `:433-472`)
- `compiler/frontend/parser.mdk` (native grammar; bracket-block productions)
- `lib/parser.mly` (oracle grammar; `expr_no_block` `:612`, paren atom `:800`, block forms `:457,667,671`)
- `LAYOUT-SEMANTICS.md` (§6 spec, ground truth both lexers are held to)

## LOCKED SCOPE (2026-06-23, user-approved)
- **GO: full 5-stage fix, staged** (each stage independently gated + merged).
- **(a) Heralds:** `match`, `do`, `function`, `record`, bare-`INDENT` block. **DEFER** `let…in`
  multi-binding groups and bracketed `if/then/else` (own-line-`in` + dangling-else hazards).
- **(b)** close on dedent-≤-herald-col OR matching bracket closer (closer force-flushes pending
  DEDENTs); no parse-error close. **(c)** require a newline after the herald (no same-line arms).
  **(d)** targeted bracket-frame stack, NOT a full Haskell `L` rewrite. **(e)** free-form remains the
  default inside brackets; layout re-enabled ONLY when a herald arms.
