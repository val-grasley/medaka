# LAYOUT-CONFORMANCE-AUDIT.md

> **📦 ARCHIVED — historical record (moved 2026-06-22).** This conformance doc is CLOSED; all tracked items are resolved. Any open residual is now tracked in [`PLAN.md`](../PLAN.md). Kept for provenance; not a living roadmap.

**Date:** 2026-06-21 · **Tree:** current `main` (post-WS-4 effects work,
`e7b2bd0`) · **Method:** every rule reproduced *on the binary*, not recited from
code or status docs.

- **Canonical** = native `test/bin/lex_main <file>` — the self-hosted lexer
  (`selfhost/frontend/lexer.mdk`) compiled to native and run on
  `selfhost/entries/lex_main.mdk`. Built with `sh test/build_oracles.sh` (or
  directly: `./medaka build selfhost/entries/lex_main.mdk -o test/bin/lex_main`).
- **Oracle** = `./_build/default/dev/lextok.exe <file>` — the OCaml reference
  lexer (`lib/lexer.mll`, `Lexer.tokenize_string`). Built with
  `dune build dev/lextok.exe`.
- Both print the cooked stream one token/line (incl. `INDENT`/`DEDENT`/`NEWLINE`)
  in canonical `token_to_string` form. The strings below are abbreviated for
  readability (positions and trailing `NEWLINE NEWLINE EOF` elided where noise).
- Each rule cites `LAYOUT-SEMANTICS.md` (`§`).

**Headline result.** Across the seed cases + ≈65 probes (a curated battery beyond
the `test/diff_fixtures` corpus), the canonical and oracle lexers produce
**byte-identical token streams on every probe** — zero layout-token divergence.
The differential gates (`diff_selfhost_lexer`, `diff_selfhost_lex_files`) keep
the two lexers locked; this audit confirms they stay locked well outside the
gated corpus, and confirms each spec rule holds on the binary. The *findings*
below are therefore **not** native↔oracle layout divergences (there are none);
they are (a) **doc drift** in SYNTAX.md / PLAN.md, (b) **parser-level**
divergences where the token stream agrees but a parser differs, and (c)
**idealized-spec gaps / latent risks** worth a roadmap item.

Legend: **AGREE** = canonical and oracle token streams identical. **CONFORMS** =
matches `LAYOUT-SEMANTICS.md`.

---

## Part 1 — Per-rule conformance (token stream)

### A-STACK / A-COL — stack + column computation (§2, §3)

| Probe | Source | Canonical == Oracle | Conforms |
|---|---|---|---|
| empty | `` (0 bytes) | `NEWLINE EOF` | AGREE / CONFORMS |
| only-blanks | `\n\n\n` | `NEWLINE EOF` | AGREE / CONFORMS |
| only-spaces | `   ` | `NEWLINE EOF` | AGREE / CONFORMS |
| no-final-nl | `x = 1` (no `\n`) | `IDENT "x" EQUAL INT 1 NEWLINE NEWLINE EOF` | AGREE / CONFORMS |

Blank/whitespace-only lines emit no layout tokens (§3). Base stack `[0]` flushes
to `NEWLINE EOF` (§8). ✅

### A-TAB — tab = round-to-8 (§3)

Probes `tab1` (`main =⏎ \tif True⏎ \tthen 1⏎ \telse 2`), `tab2` (`x =⏎ \t1`):
**AGREE**, both compute the tab column as the next multiple of 8 and produce the
same `INDENT`. ✅ CONFORMS. *(Spec note, not a defect: mixed tabs+spaces is
well-defined but can surprise — ROADMAP WS-6.)*

### B-NL — same-column NEWLINE separator (§4 II)

`x = 1⏎ y = 2` → `IDENT "x" EQUAL INT 1 NEWLINE IDENT "y" EQUAL INT 2 …`.
Two top-level siblings separated by one `NEWLINE`. **AGREE / CONFORMS.** ✅

### B-INDENT/DEDENT — block open/close (§4 I.b, III)

`x =⏎  1` → `IDENT "x" EQUAL INDENT INT 1 NEWLINE DEDENT NEWLINE …`. `=` heralds
(¬canEndExpr); deeper line opens block; `EOF`-region closes it. **AGREE /
CONFORMS.** ✅ Multi-level dedent (`x_deep_match`, nested `match`):
`… NEWLINE DEDENT NEWLINE DEDENT NEWLINE …` — one `DEDENT:NEWLINE` per level.
**AGREE / CONFORMS.** ✅

### A-DEDENT — non-matching (mid-stack) dedent (§4 III note)

Probes with a line dedenting to a column *between* two stack entries
(`te1_dedented_else`, `x_then_shallower`): **AGREE**. Neither lexer raises; the
pop stops at the first `top ≤ col` and the stream is handed to the parser.
Matches the spec's "silent, defer to parser" note. ✅

### C-COMMENT — comment transparency + nesting + brace-safety (§3, §5.2, §6)

| Probe | Source shape | Result |
|---|---|---|
| `c1` | comment line inside a `=` block | comment emits no token, block intact | AGREE/CONFORMS |
| `c2` | comment line between top-level bindings | transparent | AGREE/CONFORMS |
| `c3` | comment line at same indent inside a `let` block | transparent, no spurious NEWLINE/DEDENT | AGREE/CONFORMS |
| `m1` | trailing `-- …` after `=>`, body next line | comment dropped, `=>` still heralds arm body | AGREE/CONFORMS |
| `b1`,`b2`,`b3` | `--` comment containing `{` / `[` / `(` | bracket depth **unperturbed** | AGREE/CONFORMS |
| `x_nested_block_comment` | `{- a {- nested -} b -}` | nesting depth correct, fully dropped | AGREE/CONFORMS |
| `x_block_comment_brace` | `{- has { unbalanced -}` | depth unperturbed | AGREE/CONFORMS |
| `x_comment_no_nl` | file = `-- comment` (no newline) | `NEWLINE EOF` | AGREE/CONFORMS |

The historically recurring "unbalanced `{` in a comment throws off the
brace-depth counter" bug class is **closed** on current main: comments are
recognized before any char reaches the depth counter (§6). ✅

### C-IFTHENELSE — then/else continuation (§5.4)

| Probe | Source | Result |
|---|---|---|
| `if1` | `then`/`else` aligned to `if` | `IF True THEN 1 ELSE 2` — no NEWLINE before THEN/ELSE | AGREE/CONFORMS |
| `if2` | `then`/`else` indented past `if` | identical stream to `if1` | AGREE/CONFORMS |
| `if3` | trailing `-- …` after cond/then/else | comments dropped, glued | AGREE/CONFORMS |
| `te1` | `else` dedented below `then` | `… NEWLINE DEDENT ELSE …` — DEDENT kept, NEWLINE dropped | AGREE/CONFORMS |
| `te2` | blank line before `then` | glued | AGREE/CONFORMS |
| `te3` | comment-only line before `then` | glued | AGREE/CONFORMS |
| `te4` | nested `if/then/else` | AGREE/CONFORMS |
| `x_multi_blank_before_else` | 2 blank lines before `else` | glued | AGREE/CONFORMS |
| `x_extreme_dedent_then` | `then`/`else` at col 0 (below `if` block) | AGREE/CONFORMS |

Both the same-column/dedented path (Stage C `elseFilter` / OCaml `filter_newline`)
and the deeper-line path (Stage B `resolveCont` / OCaml `resolve_pending`) are
exercised and **agree**. ✅ *(But see Finding F4 — the two mechanisms are
structurally different code; this is a latent-divergence site, not a current
defect.)*

### C-TRAILOP / C-LEADOP — operator continuations (§5.0–§5.3)

- **Trailing** (`to1`–`to4`, `r1`, `tw1`, `x_trailing_op_eof`): `x = 1 +⏎  2` →
  `… INT 1 PLUS INT 2 …` (no INDENT). With a blank line (`to2`) or trailing
  comment (`to3`) between op and operand: still glued. At EOF (`x = 1 +`):
  AGREE. **All AGREE / CONFORMS.** ✅
- **Leading** (`lo_pipe lo_rcomp lo_lcomp lo_and lo_or lo_concat lo_cons`): each
  of the 7 ops `|> >> << && || ++ ::` on a deeper line glues to the prev line
  (`x = a⏎  |> b` → `… IDENT "a" PIPE_RIGHT IDENT "b" …`). **All 7 AGREE /
  CONFORMS.** ✅ Confirmed source-of-truth set is `|> >> << && || ++ ::` in
  **both** lexers (`selfhost/frontend/lexer.mdk:851-857`; `lib/lexer.mll:345`).
- **Leading `-` is NOT a continuation** (`to4`, `x = 1⏎  - 2`):
  `… INT 1 INDENT MINUS INT 2 …` — opens a block (asymmetry §5.0). **AGREE /
  CONFORMS.** ✅

### D-BRACKET — bracket depth disables layout (§6)

`pd1` (multi-line `( … )` with ragged indentation), `pd2` (`[ … ]`), `rec1`
(record `{ … }`), `set1` (set `{ … }`), `interp1` (`"… \{1+2}"`): **AGREE**, no
`INDENT`/`DEDENT`/`NEWLINE` inside any bracketed region. `pd3` (`( 1  -- has {
unbalanced⏎ , 2 )`) — comment-brace inside parens harmless. **All AGREE /
CONFORMS.** ✅

### E-EOF — flush (§8) — covered by A-STACK probes. ✅

### Other constructs (§9)

`do1` (do-block), `do_nested`, `w1`/`wA`/`wC`/`wD` (where forms), `x_crlf`
(CRLF line endings): **all AGREE.** CRLF handled identically (column resets to 0
on `\r\n`). ✅

---

## Part 2 — Findings

> None of these is a native↔oracle **layout-token** divergence. They are doc
> drift, parser-level divergences, and idealized-spec gaps.

### F1 — SYNTAX.md:426 "`then` cannot start a line" is **STALE** (doc drift)

Probe `tt` (`main =⏎  if True⏎  then 1⏎  else 2`):
```
canonical/oracle tokens: … IF UPPER "True" THEN INT 1 ELSE INT 2 NEWLINE …
native check:  ACCEPT      oracle check:  ACCEPT
```
Both lexers strip the `NEWLINE` before `THEN` (§5.4) and **both parsers accept**
`then` leading a line. SYNTAX.md:426 ("`then` cannot start a line") predates the
multi-line-`if` fix (main `fdd3980`) and is now false. → ROADMAP **WS-1**.

### F2 — SYNTAX.md:424 leading-op set is **INCOMPLETE** (doc drift)

SYNTAX.md lists `|> >> << && || ++` (six). The actual leading-continuation set in
both lexers is **seven** — it includes `::`. Probe `lo_cons`
(`x = a⏎  :: b` → `… IDENT "a" CONS IDENT "b" …`) confirms `::` glues. →
ROADMAP **WS-1**.

### F3 — SYNTAX.md "RHS cannot wrap … except leading-op" is an **OVERSIMPLIFICATION**

The blanket statement misses two cases that **do** wrap (verified):
- trailing-op: `r = 1 +⏎  identity 2` → `1 + identity 2`, **ACCEPT** both (`tw1`).
- atom continuation: `r = identity⏎  5` → `identity 5`, **ACCEPT** both (`aw1`).

And it correctly predicts the failures: `x = 1⏎  - 2` (`to4`) and
`x = identity⏎  let y = 5` (`wf1`) both open a block → **parse error** both
(native `parse error`; oracle `…:2:1: Parse error`). The precise rule is
`LAYOUT-SEMANTICS.md` §11. → ROADMAP **WS-1** (point SYNTAX.md at §11).

### F4 — PLAN.md "Known parser gaps → `let … in` as indented clause body" is **STALE** (doc drift)

PLAN.md (verified 2026-06-09) claims the selfhost parser rejects
```
f x =
  let go n = if n == 0 then 0 else go (n - 1) in go x
```
On current `main`, **both** native and oracle **ACCEPT** it (probe `letin_plan`,
exit 0 / exit 0). The gap is **closed**; the PLAN.md note has drifted. (Note: the
*own-line* `in` form — `let y = …⏎ in y` — is still rejected by both, but that is
a **language rule both honor** (§9, §11 — no `parse-error(t)`), not a selfhost
divergence.) → ROADMAP **WS-1**.

### F5 — Leading-pipe `data` decl: token stream AGREES, **parsers diverge** (parser-level, intentional)

Probe `d1` (`data Color =⏎  | Red⏎  | Green⏎  | Blue`):
```
tokens (AGREE): DATA UPPER "Color" EQUAL INDENT PIPE UPPER "Red" NEWLINE PIPE … DEDENT …
native check:  ACCEPT          oracle check:  …:2:0: Parse error
```
The **layout is identical**; the frozen OCaml *parser* never learned the
native-only leading-`|` variant syntax (memory `project_data_decl_leading_pipe_syntax`;
the native parser handles it in `dataBodyFor`/`variantStartsAt`). This is an
expected frozen-oracle parser gap, **not a layout gap**. No action while `lib/`
is the oracle; resolves automatically at `lib/` removal (native becomes sole
ground truth). → ROADMAP **WS-5** (track, no fix).

### F6 — Native `check` diagnostics lack source positions (out of layout scope)

> **UPDATE (2026-06-21): CLOSED.** Pursued as a separate diagnostics workstream
> (`selfhost/DIAGNOSTICS-SURFACING-PLAN.md`, S1–S4; merges `1cbe1e1`/`dd05010`/`395a276`/`ca1876f`).
> Native `medaka check` now prints positioned, humane, carat-rendered diagnostics
> byte-identical to the oracle (parse/type/resolve spans + non-exhaustive-match warning spans).
> The original finding text is preserved below for audit-log integrity.

~~Across every rejecting probe, native errors are positionless (`parse error`,
`(UnboundVariable "id")`) while the oracle is positioned (`…:2:1: Parse error`,
`…:2:4: Unbound variable: id`). This is a **diagnostics-quality** divergence in
the CLI, *not* a layout/lexer divergence (the token streams agree). Recorded for
completeness; **out of scope** for the layout roadmap.~~ → ROADMAP **WS-4**
(cross-reference only; now DONE).

### F7 — `then`/`else` dual mechanism: equivalent today, **latent divergence** (idealized-spec gap)

`§5.4`: the oracle implements then/else gluing as `filter_newline` (1-token
lookahead) + `resolve_pending`; the selfhost lexer as `resolveCont` + a pure-list
`elseFilter` post-pass. Different code, same relation — verified across
`if1`/`if2`/`if3`/`te1`–`te4`/`x_multi_blank_before_else`/`x_extreme_dedent_then`.
No current defect, but the two mechanisms can drift independently. → ROADMAP
**WS-2** (lock with an expanded shared fixture set + a spec-anchored note).

---

## Part 3 — Coverage ledger

| Spec area (§) | Probed | Native==Oracle | Conforms to spec |
|---|---|---|---|
| Stack + column + tab (§2,§3) | ✅ | ✅ | ✅ |
| NEWLINE / INDENT / DEDENT core (§4) | ✅ | ✅ | ✅ |
| Mid-stack dedent (§4 III note) | ✅ | ✅ | ✅ (silent-defer) |
| Comment transparency + nesting + brace-safety (§3,§5.2,§6) | ✅ | ✅ | ✅ |
| Blank-line transparency (§3) | ✅ | ✅ | ✅ |
| Trailing-op continuation (§5.3) | ✅ | ✅ | ✅ |
| Leading-op continuation, all 7 (§5.1) | ✅ | ✅ | ✅ |
| Leading/trailing asymmetry (§5.0) | ✅ | ✅ | ✅ |
| then/else continuation (§5.4) | ✅ | ✅ | ✅ (dual mech — F7) |
| Bracket depth off + interp + brace-in-comment (§6) | ✅ | ✅ | ✅ |
| Heralds (=, =>, match, do, where) (§7) | ✅ | ✅ | ✅ |
| Atom continuation / RHS-wrap (§11) | ✅ | ✅ | ✅ |
| EOF flush (§8) | ✅ | ✅ | ✅ |
| CRLF | ✅ | ✅ | ✅ |

**Token-level layout conformance: 100% across the battery. No native↔oracle
layout divergence found.** All open items are doc drift (F1–F4), an intentional
frozen-parser gap (F5), a diagnostics gap (F6), or a latent-risk lock (F7) —
sequenced in `LAYOUT-CONFORMANCE-ROADMAP.md`.

---

## Appendix — reproduce

```sh
# build the two dump probes
dune build dev/lextok.exe bin/main.exe
sh test/build_oracles.sh           # builds test/bin/lex_main (+ others)

# dump + diff one file
diff <(./_build/default/dev/lextok.exe f.mdk) \
     <(test/bin/lex_main f.mdk | sed '$ s/()$//; ${/^$/d;}')

# the gates this audit corroborates
sh test/diff_selfhost_lexer.sh        # curated corpus
sh test/diff_selfhost_lex_files.sh    # stdlib + lexer.mdk self-lex
sh test/diff_selfhost_parse.sh        # parser-level (catches F5-class)
```
The probe fixtures used here are catalogued in `LAYOUT-CONFORMANCE-ROADMAP.md`
WS-7 for promotion into `test/diff_fixtures/`.
