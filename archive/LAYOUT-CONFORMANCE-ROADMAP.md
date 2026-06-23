# LAYOUT-CONFORMANCE-ROADMAP.md

> **📦 ARCHIVED — historical record (moved 2026-06-22).** This conformance doc is CLOSED; all tracked items are resolved. Any open residual is now tracked in [`PLAN.md`](../PLAN.md). Kept for provenance; not a living roadmap.

> **STATUS — substantially CLOSED (2026-06-21, `main` = `5a767bb`).** WS-1·WS-2·WS-3·WS-5·WS-6·WS-7
> all landed; WS-4 is out of scope by design (cross-ref only). Two merges:
> `eb01df3` (WS-1/3/5/6 — erased SYNTAX/PLAN/AGENTS doc drift, seated `LAYOUT-SEMANTICS.md`
> as the doc-index anchor, wrote the `no-parser-layout-feedback` decision memory, tracked the
> leading-`|` `data` frozen-oracle gap, documented the tab policy) and `0182cbc` (WS-7 — 22
> gated layout fixtures in `test/diff_fixtures/` + WS-2 then/else dual-mechanism source-comment
> cross-links in both lexers). No lexer behavior change — edits were docs, fixtures, and comments
> only; fixpoint C3a/C3b held byte-for-byte (comment-only lexer edits → IR identical). Gates on
> merged main: `diff_selfhost_lexer` 57/0, `diff_selfhost_parse` 27/0, `diff_selfhost_lex_files`
> 13/0. **Excluded:** `data_leading_pipe` fixture — the frozen OCaml parser rejects leading-`|`
> `data`, so `gen_golden` can't emit the AST/TYPES/EVAL sections `@thorough` needs (F5/WS-5,
> auto-resolves at `lib/` removal). **Open:** WS-4 (native `check` error positions) stays out of
> layout scope; the WS-3 bounded retro-close for own-line `in` stays DEFER by design.

Sequenced, WS-style plan to close the gaps found in
`LAYOUT-CONFORMANCE-AUDIT.md`. **No fixes are implemented this session** — this is
the plan. `LAYOUT-SEMANTICS.md` (`§`) is the spec; the audit's findings (F1–F7)
are the source items.

**Framing.** The audit found **no native↔oracle layout-token divergence** — the
two lexers are locked by the diff gates and stay locked far outside the gated
corpus. So this roadmap is *not* "fix divergent lexers." It is: (1) erase the
**doc drift** that makes the layout rule look murkier than it is, (2) **lock**
the one latent-divergence site so it can't regress, (3) **promote** the probe
battery into the gates as a permanent net, and (4) formally seat
`LAYOUT-SEMANTICS.md` as the anchor that replaces the oracle when `lib/` is
removed. Most items are doc/test work; none requires a lexer behavior change.

Each gate references: **fixpoint** = `sh test/selfcompile_fixpoint.sh` (native
emitter reproduces its own IR — required after any `selfhost/` lexer edit);
**lexer gates** = `sh test/diff_selfhost_lexer.sh` + `sh
test/diff_selfhost_lex_files.sh`; **parse gate** = `sh
test/diff_selfhost_parse.sh`.

Priority order: **WS-1 → WS-7 → WS-2 → WS-3** (core), then **WS-5 / WS-6 / WS-4**
(track / optional / cross-ref).

---

## WS-1 — Erase the layout doc drift  ·  *docs only, no code*

**Source:** F1, F2, F3, F4. **Risk:** none (no binary change). **Effort:** ~30 min.

The binary's layout behavior is correct and stable; three doc statements have
drifted away from it. Fix the docs to match the binary (and point them at the new
spec), do **not** change the lexer.

| # | File:line | Says (stale) | Should say (verified) |
|---|---|---|---|
| 1 | `SYNTAX.md:426` | "`then` cannot start a line." | `then` **may** start a line; like `else`, a leading `then` continues the enclosing `if` (§5.4). |
| 2 | `SYNTAX.md:424` | leading set `\|> >> << && \|\| ++` | add `::` → `\|> >> << && \|\| ++ ::` (7 ops, §5.0). |
| 3 | `SYNTAX.md:423-425` | "RHS cannot wrap … except leading-op" | replace with a pointer to `LAYOUT-SEMANTICS.md` §11 (trailing-op **and** atom continuations also wrap). |
| 4 | `PLAN.md` "Known parser gaps → `let … in` as indented clause body" | selfhost rejects | **closed** — both accept on `main`; delete the bullet (keep only the still-true own-line-`in` language rule, cross-ref §9/§11). |
| 5 | `AGENTS.md` (Gotchas, guard/layout area) | — | add a one-line pointer to `LAYOUT-SEMANTICS.md` as the layout ground truth. |

**Failing-before fixture** (a doc-vs-binary check, no lexer change):
```
main =          -- SYNTAX.md:426 says this can't parse; it does:
  if True
  then 1
  else 2
```
`medaka check` → ACCEPT (both), contradicting the doc.

**Passing-after:** SYNTAX.md/PLAN.md edited; the example is reflected in
`LAYOUT-SEMANTICS.md` §10. **Gate:** doc review + `grep` self-check that
SYNTAX.md's leading-op set matches `selfhost/frontend/lexer.mdk:851-857`. No
fixpoint/lexer-gate run needed (no code change).

---

## WS-7 — Promote the probe battery into `test/diff_fixtures/`  ·  *test infra*

**Source:** all of Part 1 (regression net). **Risk:** low. **Effort:** ~1–2 h
(mind the golden-recapture footgun below).

The audit's ≈65 probes live in `/tmp` and vanish. The seed-case + adversarial
fixtures are exactly the recurring-bug surface; they belong in the gated corpus
so a future lexer edit that breaks one fails CI, not a human.

**Candidate fixtures** (one `.mdk` each, with a captured `=== TOKENS ===` golden):
`comment_in_block`, `comment_only_indented`, `if_then_else_aligned`,
`if_then_else_indented`, `if_then_else_comments`, `dedented_else`,
`comment_before_then`, `nested_if`, `data_leading_pipe`, `trailing_op_wrap`,
`trailing_op_blankline`, `leading_minus_opens_block`, `lead_cons` (the `::` case
F2 misses), `rhs_atom_wrap`, `paren_multiline`, `brace_in_comment`,
`block_comment_unbalanced_brace`, `crlf`, `tabs`, `where_trailing`,
`where_ownline`, `do_nested`, `multi_blank_before_else`.

**Failing-before:** revert any one historical layout fix (e.g. the comment-line
transparency fix) → the matching fixture's golden mismatches.
**Passing-after:** `diff_selfhost_lexer` covers all of them; both lexers match
the golden.
**Gate:** lexer gates green with the new fixtures; goldens captured via
`sh test/capture_goldens.sh` (the OCaml-oracle path).

> **Footgun (memory `project_diff_fixtures_golden_add_footgun`):** adding fixtures
> to `test/diff_fixtures/` is *not* cheap — `capture_goldens.sh` regenerates the
> whole corpus + build goldens (path-baked), ~400 spurious diffs, no per-fixture
> filter. **Batch all WS-7 fixtures into one capture**, and audit
> `grep -rlE '/Users/' test/ --include='*.golden'` stays 0
> (memory `project_golden_path_stability`).

---

## WS-2 — Lock the `then`/`else` dual mechanism  ·  *test + spec note, no behavior change*

**Source:** F7. **Risk:** none if scoped to tests+docs. **Effort:** ~1 h.

`§5.4`: gluing `then`/`else` is computed by *different code* in the two lexers
(oracle `filter_newline`+`resolve_pending`; selfhost `resolveCont`+`elseFilter`).
Equivalent today, but the two can drift independently — the highest-probability
way to reintroduce a layout divergence. **Do not refactor the lexers** (risky,
no behavior win). Instead, *pin* the equivalence:

1. Add a dedicated `then/else` edge-case block to WS-7's fixtures covering all
   four entry paths: deeper-line `then`/`else` (`resolveCont`/`resolve_pending`),
   same-column (`elseFilter`/`filter_newline`), dedented (DEDENT-kept), and the
   blank-line / comment-line-before-`then` variants. (Several already pass — the
   point is to *gate* them so they can't silently regress.)
2. Add a cross-link in **both** lexers' source at the then/else code
   (`selfhost/frontend/lexer.mdk` `elseFilter`/`resolveCont`;
   `lib/lexer.mll` `filter_newline`/`resolve_pending`) → "conforms to
   `LAYOUT-SEMANTICS.md` §5.4; edits must keep both mechanisms in step
   (LAYOUT-CONFORMANCE-ROADMAP WS-2)."

**Failing-before:** hand-perturb the selfhost `elseFilter` to only match `TElse`
(not `TThen`) → the `then`-leading-a-line fixtures diverge from the oracle in the
lexer gate.
**Passing-after:** the fixtures pin all four paths; lexer gates + parse gate
green; fixpoint holds (no source-behavior change, but run it since `selfhost/`
comment edits touch the emitter input).
**Gate:** lexer gates + `diff_selfhost_parse` + fixpoint.

---

## WS-3 — Seat `LAYOUT-SEMANTICS.md` as the conformance anchor  ·  *spec + decision*

**Source:** §0, §1, §11, §12 (the `parse-error(t)` departure). **Risk:** none.
**Effort:** ~1 h, mostly a written decision.

Two things to make official:

1. **Adopt the file as ground truth.** Add it to the AGENTS.md doc index and the
   "router" so future layout work starts here. State the rule: a lexer-vs-spec
   divergence is a *lexer* bug; a SYNTAX.md/PLAN.md-vs-spec divergence is a *doc*
   bug (§12.4).
2. **Ratify the `parse-error(t)` absence as intentional** (§0.1, §11). Medaka has
   *no* parser→layout feedback; the own-line `let … in` and the
   `where` edge shapes are governed by the §5 continuation rules instead. Record
   this as a *decision* (like memory `no-catchable-panics-isolation` /
   `lazy-toplevel-nullary-canonical`), so a future "let's add Haskell-style
   layout recovery" proposal is redirected here unless it brings a concrete need.
   - *Optional sub-item, only if a need arises:* a minimal, **bounded** retro-close
     (close the innermost implicit block when the next token is `in` and the block
     was opened by a `let` herald) would make own-line `in` parse. Scoped as
     **DEFER** — it reintroduces lexer↔parser coupling the design avoids; revisit
     only with a real program that needs it.

**Failing-before / passing-after:** N/A (no behavior change). The "fixture" is
the own-line-`in` probe (`let y = …⏎ in y`) which **stays rejected** by both —
the decision is to keep it that way and document it, not to make it parse.
**Gate:** doc review; AGENTS.md index updated.

---

## WS-5 — Track the leading-`|` `data` parser gap  ·  *track only, resolves at `lib/` removal*

**Source:** F5. **Risk:** none. **Effort:** trivial (tracking).

Leading-`|` `data` decls lex identically in both but the **frozen OCaml parser**
rejects them (native accepts). This is a deliberate frozen-oracle parser gap, not
a layout issue — and it **auto-resolves** when `lib/` is removed (native becomes
sole ground truth; AGENTS.md soak-tail plan). No lexer action.

**Action:** one line in `PLAN.md` "Known parser gaps" noting it is *native-only
by design, oracle frozen*, with a pointer to the `lib/`-removal milestone. (Do
**not** "fix" the frozen oracle — diverging it breaks the diff-gate contract,
memory `project_diff`-style frozen-oracle rule.)
**Failing-before:** `d1` fixture — native ACCEPT, oracle `2:0: Parse error`.
**Passing-after (at `lib/` removal):** only the native parser remains; the case
is plainly accepted; the diff gate is retired with the oracle.
**Gate:** `diff_selfhost_parse` documents the known exclusion until then.

---

## WS-6 — Document the tab / mixed-whitespace policy  ·  *docs, optional lint*

**Source:** A-TAB / spec §3. **Risk:** none (docs); low (optional lint).
**Effort:** ~30 min docs.

Tabs round to the next multiple of 8 (§3) — well-defined, but mixed tabs+spaces
can produce surprising columns. **Document** it in SYNTAX.md "Layout notes" (one
line). *Optional, DEFER:* a `fmt`/lint warning on a line that mixes a tab after
spaces in indentation. Out of the lexer's scope (lexer behavior is correct and
must not change); a formatter/lint concern only.

**Failing-before:** none (behavior is correct). **Passing-after:** SYNTAX.md
states the tab rule; (optional) `fmt` warns on mixed indentation.
**Gate:** doc review; if the optional lint lands, a `test_fmt` case.

---

## WS-4 — (cross-ref only) native `check` error positions  ·  *out of layout scope*

**Source:** F6. **Not a layout item.** Native `check` parse/resolve/type errors
print without `file:line:col`; the oracle is positioned. This is a CLI
diagnostics-quality gap, independent of the lexer (token streams agree).

> **UPDATE (2026-06-21): pursued + DONE as a separate diagnostics workstream —
> `selfhost/DIAGNOSTICS-SURFACING-PLAN.md` (S1–S4).** Native `medaka check` now
> prints positioned, humane, carat-rendered diagnostics byte-identical to the
> oracle (parse/type/resolve spans + non-exhaustive-match warning spans). It is
> NOT a layout change — recorded here only because F6 surfaced it during the
> layout audit.

---

## Summary

| WS | Item | Kind | Behavior change? | Gate |
|---|---|---|---|---|
| 1 | Erase layout doc drift (F1–F4) | docs | no | review + grep self-check |
| 7 | Promote probe battery to `diff_fixtures` | test infra | no | lexer gates (batch capture) |
| 2 | Lock then/else dual mechanism (F7) | test + source comment | no | lexer + parse gates + fixpoint |
| 3 | Seat spec as anchor; ratify no-`parse-error(t)` | spec/decision | no | review + AGENTS.md index |
| 5 | Track leading-`\|` `data` (F5) | track | no (auto at `lib/` removal) | `diff_selfhost_parse` note |
| 6 | Tab/mixed-ws policy | docs (+opt lint) | no | review |
| 4 | Native error positions (F6) | cross-ref | n/a (out of scope) | — |

The through-line: the layout *machine* is healthy and locked; the work is to make
its **specification** authoritative and its **regression net** permanent, so the
recurring-bug history (comment-line transparency, multi-line if/then/else,
leading-`|`, brace-in-comment) cannot recur unnoticed once `lib/` and its oracle
are gone.
