# Workstream: LANGUAGE

**Owns:** the surface language — what parses, and what it means. Lexer → parser → desugar → typecheck.
**Touches:** `compiler/frontend/`, `compiler/types/`.

```sh
gh issue list --label "ws:language" --state open
```

**Load the `add-language-feature` skill before planning.** It is the right skill for most cross-cutting
work that *looks* like typechecking — if the fix threads through resolve/eval/desugar/AST as well, it
is **not** `harden-typechecker`.

---

## Every item here costs a seed re-mint + a fixpoint re-validation. BATCH THEM.

The sweep for a new construct is lexer → parser → AST → desugar → resolve → typecheck → exhaust →
eval → fmt/printer → LSP → `SYNTAX.md` → both emitters. Then `test/refresh_seed.sh` (**not idempotent
after a codegen change — run it TWICE**) and `test/selfcompile_fixpoint.sh`.

**Do not land these one at a time.** Two language PRs in flight will fight over every golden.

---

## Two non-obvious facts that decide *where* a check belongs

- **`desugar.mdk` runs FIRST**, before resolve/typecheck. Surface-sugar nodes (`EGuards`, `ESection`,
  `EStringInterp`, `EDo`) are **already lowered to core** by the time typecheck/exhaust/eval see the
  tree. A check that needs the sugar shape (e.g. guard *coverage* on `EGuards`) **cannot live in
  typecheck/exhaust** — it must run pre-desugar (see `checkGuardExhaustiveness` in
  `compiler/frontend/exhaust.mdk`, a standalone pass on the raw AST).
- **`exhaust.mdk` is not a standalone later stage** — `checkMatchExhaustive` is *called from inside*
  `compiler/types/typecheck.mdk` (once per `EMatch`, with the scrutinee type known). It only ever sees
  core patterns.

---

## Ground truth for "does X parse?"

`docs/spec/SYNTAX.md` — the cheat-sheet of every construct **the current binary accepts**. Faster than
reading `parser.mdk`, and it outranks `language-design.md` (which is explicitly NON-NORMATIVE and
"deliberately includes aspirational features never built").

For layout questions (legal indentation shapes, the leading-op set, `then`/`else`, tabs, `let…in`
wrapping), **`docs/spec/LAYOUT-SEMANTICS.md` is ground truth.** A lexer-vs-spec divergence is a *lexer*
bug; a SYNTAX/PLAN-vs-spec divergence is a *doc* bug.

⚠️ **REMOVED — hard parse errors, each with a dedicated removal diagnostic:** the **`function`
keyword**, **`let mut`** (use a `Ref`), **backtick infix**, the **`record` keyword**, **`let-else`**,
**named impls**, **`default impl`**. `test/check_removed_constructs.sh` is the tree-wide gate that
keeps them out.

⚠️ But those removal diagnostics **fire on the bare token regardless of syntactic position** (#62), so
you cannot currently *name a binding* `record` or `mut`. Fix that before reserving any more words.

---

## The float round-trip is one defect wearing three hats

`fmt --write` destroying source (**#51**), the "scientific-notation float literal rejected" *parser
gap*, and the `1e12` row of the proposed must-fail suite are **the same bug**: the printer emits
exponent notation (`9e+15`) and **`scanNumber` in `compiler/frontend/lexer.mdk` has no exponent form**,
so the lexer cannot read what the printer writes.

**Fix the lexer and all three close.** This is the highest-severity bug in the tree — it destroys
source files, and `fmt` runs in the **pre-commit hook**, so the *instructed* workflow is what detonates
it.

It is also the clearest example of why the backlog moved to one tracker: three docs, three items, one
bug, and nobody could see it.
</content>
