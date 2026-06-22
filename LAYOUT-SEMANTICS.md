# LAYOUT-SEMANTICS.md — Medaka's layout rule, formalized

**Status:** idealized formal specification + conformance anchor.
**Scope:** the indentation-sensitive token-stream transformation that inserts
`INDENT` / `DEDENT` / `NEWLINE` (Medaka's "offside rule").
**Audience:** compiler maintainers; the two lexers
(`selfhost/frontend/lexer.mdk` — canonical; `lib/lexer.mll` — frozen oracle)
must both conform to *this document*.

> **Why this file exists.** The layout rule lives only as imperative code in two
> lexers that must agree, and it is where the recurring lexer bugs concentrate.
> This is the declarative ground truth: it states what layout *should* do, so the
> two implementations can be audited against one definition rather than against
> each other. When `lib/` is removed (the soak-tail plan, AGENTS.md), this file —
> not the OCaml oracle — is the conformance anchor that
> `selfhost/frontend/lexer.mdk` is validated against. Written to outlive `lib/`.
>
> Cross-references: `SYNTAX.md` "Layout notes" is the operational *what-parses*
> cheat-sheet (and currently drifts from the binary — see
> `LAYOUT-CONFORMANCE-AUDIT.md`); `language-design.md` is intent/rationale. When
> any of those disagree with the **binary**, the binary wins and this file is
> updated to match it.

---

## 0. Background: the offside rule, and how Medaka differs

The **offside rule** (Landin, *The Next 700 Programming Languages*, 1966) lets
two-dimensional layout stand in for explicit block delimiters: a construct's
extent is the region indented to the right of a reference column; a token to the
*left* of that column closes the construct.

The reference treatment is **Haskell 2010 §10.3** ("Layout"), whose `L` function
maps a token stream annotated with line/column data plus a stack of layout
contexts `(m : ms)` to a stream with `{`, `}`, `;` inserted. Haskell's `L` has a
distinctive escape hatch — the **`parse-error(t)` side condition**:

> `L (t : ts) (m : ms) = } : (L (t : ts) ms)`  if `m ≠ 0` and `parse-error(t)`

i.e. when the parser *would fail* on the next token, an implicit layout context
is closed instead. This couples the lexer to the parser.

**Medaka deliberately departs from Haskell in three ways:**

1. **No `parse-error(t)`.** Medaka layout is *purely lexer-side*: the layout pass
   never consults the parser. Closing an implicit block is driven entirely by
   column comparison and a fixed set of **continuation rules** baked into the
   lexer (§5). This is simpler and re-entrant, but it means a handful of
   Haskell-legal shapes that rely on `parse-error(t)` (notably `let … in` where
   `in` *leads* a less/equally-indented line) are **not** accepted; Medaka
   requires the continuation to be expressed by indentation or by a known
   continuation token. This departure is **intentional** and is specified here,
   not treated as a bug (§9, §11).

2. **`INDENT`/`DEDENT`/`NEWLINE`, not `{`/`}`/`;`.** Medaka emits explicit
   `INDENT` and `DEDENT` bracketing tokens (Python-style) plus `NEWLINE` item
   separators, rather than virtual braces. The grammar consumes these directly.

3. **Implicit *and* explicit blocks coexist.** Implicit (column-driven) blocks
   are opened by **heralds** (§7). Explicit blocks are the bracket pairs
   `( )` `[ )` `[| |]` `{ }` `.{ }`, inside which layout is **switched off
   entirely** (§6). There is no `of`/`where`/`do`-keyword whitelist as in
   Haskell; the herald set is *derived* from the predicate `canEndExpr` (§7.1).

---

## 1. The pipeline: three idealized stages

The transformation `source → cooked token stream` factors into three stages. The
canonical lexer (`selfhost/frontend/lexer.mdk`) implements them as three
literal passes; the OCaml oracle (`lib/lexer.mll`) **fuses** all three into one
stateful ocamllex pass with a pending-token queue, but computes the identical
relation. This document specifies the *relation*; either factoring conforms.

```
                 ┌──────────────────────────────────────────────┐
  source  ──────▶│ Stage A — SCAN                               │──▶ raw stream
   (chars)       │  chars → Tok / Comment / Nl(col) items.       │   [RawTok]
                 │  Tracks bracket depth; emits Nl ONLY at        │
                 │  depth 0 AND only where no scanner-level       │
                 │  continuation suppresses it (§3, §5.1, §6).    │
                 └──────────────────────────────────────────────┘
                                      │  stripComments
                                      ▼
                 ┌──────────────────────────────────────────────┐
  raw    ───────▶│ Stage B — LAYOUT                             │──▶ cooked stream
  stream         │  [RawTok] × stack × prev × opener →            │   [(Token,off)]
                 │  inserts INDENT/DEDENT/NEWLINE by the          │
                 │  transition relation L (§4).                   │
                 └──────────────────────────────────────────────┘
                                      │
                                      ▼
                 ┌──────────────────────────────────────────────┐
  cooked ───────▶│ Stage C — ELSEFILTER                         │──▶ final stream
                 │  drop a NEWLINE immediately before THEN/ELSE   │   to parser
                 │  (the `if` continuation, §5.4).                │
                 └──────────────────────────────────────────────┘
```

`RawTok` is one of:
- `Tok t` — a real token `t` with source span,
- `Comment …` — a captured comment (a side-channel for the formatter; **never**
  reaches the parser; dropped by `stripComments` before Stage B),
- `Nl col` — a *line boundary* carrying `col`, the column of the **first
  non-whitespace** of the line it introduces.

The key design fact: **everything that suppresses a line boundary at the
*scanner* level — comment-only lines, leading-operator continuations, and being
inside brackets — is handled in Stage A by simply *not emitting* an `Nl`
item.** By the time Stage B runs, the only continuations left to decide are
trailing-operator and atom continuations (§5). This keeps Stage B a clean
column-comparison automaton.

---

## 2. The layout-context stack

```
stack : List Int          -- columns of enclosing implicit blocks, innermost first
initial: [0]              -- the top-level block at column 0; never empties
```

Each entry is the **column** of an open implicit layout block. The stack is
initialized `[0]` and the base `0` is never popped before `EOF`. `INDENT` pushes
a column; `DEDENT` pops one. (Both lexers store exactly this: `indent_stack`
in `lib/lexer.mll`, the `List Int` argument to `layout` in
`selfhost/frontend/lexer.mdk`.)

---

## 3. Column of a line (Stage A)

When a newline is consumed, the scanner walks the following whitespace to compute
the new line's indentation `col`:

```
space (' ')   ⟹  col := col + 1
tab   ('\t')  ⟹  col := (col / 8 + 1) * 8        -- round UP to next multiple of 8
CR/LF          ⟹  col := 0   (start of a fresh physical line)
other char     ⟹  stop; that char is the first token; its column is col
```

Consequences, all **specified** (not accidental):

- **Tabs are 8-wide, rounded.** Mixing tabs and spaces is permitted and well
  defined, but a tab after `n` spaces jumps to the next 8-boundary, which can
  surprise. (Haskell makes tab handling implementation-defined; Medaka pins it.)
- **Blank lines are transparent.** A run of newlines + whitespace with no token
  collapses: only the column of the line bearing the *next real token* matters.
  Intermediate blank lines never emit `NEWLINE`/`DEDENT`.
- **Comment-only lines are transparent (§5.2).** If the first non-whitespace of
  the line begins a comment (`--` or `{-`), the scanner emits **no** `Nl` for
  that line; layout is decided by the next *code* line. A comment never shifts
  the layout column.

---

## 4. The transition relation L (Stage B)

Let the layout state be `(stack, prev, opener)` where `prev : Option Token` is
the most recent real token already emitted on the current logical line and
`opener : Bool` records whether a **herald** (§7) appeared anywhere on the line
now being closed. Stage B consumes the raw stream:

```
L (Tok t : rest) (stack, prev, opener)
    =  t : L rest (stack, Some t, opener ∨ isOpener t)         -- emit t, carry state

L (Nl col : rest) (stack@(top : _), prev, opener)
    | col >  top   =  wouldIndent col rest (stack, prev, opener)        -- (I)
    | col == top   =  NEWLINE : L rest (stack, None, False)             -- (II)
    | col <  top   =  NEWLINE : popDedents col rest stack               -- (III)

L [] (stack, _, _)  =  closeAll stack                          -- EOF (§8)
```

A `NEWLINE`/`INDENT`/`DEDENT` resets `prev := None` and `opener := False` — they
start a fresh logical line.

### (I) `col > top` — deeper line: continue or open a block (`wouldIndent`)

```
wouldIndent col rest (stack, prev, opener)
    | prevIsTrailingOp prev            =  L rest (stack, prev, opener)         -- (I.a) trailing-op continuation
    | opener ∨ ¬ prevCanEnd prev       =  INDENT : L rest (col:stack, …)       -- (I.b) open implicit block
    | otherwise                        =  resolveCont col rest (stack, prev)   -- (I.c) decide on next token
```

- **(I.a) trailing-operator continuation.** If the line just closed ended in a
  binary operator (`prev ∈` trailing set, §5.0), the deeper line is that
  operator's right operand: **suppress all layout** (no `NEWLINE`, no `INDENT`;
  stack unchanged). `a +⏎  b` lexes identically to `a + b`.
- **(I.b) block opener.** If a herald armed `opener` (a `match`/`record` header
  appeared on the line), **or** `prev` cannot syntactically end an expression
  (`¬ canEndExpr`, §7.1 — e.g. `=`, `=>`, `->`, `do`, `where`, `if`, `then`,
  `else`, `|`, `(`, a binary op…), then the deeper line **opens an implicit
  block**: push `col`, emit `INDENT`.
- **(I.c) ambiguous: decide on the deeper line's first token** (`resolveCont`):

```
resolveCont col (Tok t : more) (stack, prev)
    | canStartAtom t  =  L (Tok t : more) (stack, prev, _)   -- continue application
    | t == THEN       =  L (Tok t : more) (stack, prev, _)   -- continue enclosing `if`
    | t == ELSE       =  L (Tok t : more) (stack, prev, _)   -- continue enclosing `if`
    | otherwise       =  INDENT : L (Tok t : more) (col:stack, …)   -- open block
```

  When `prev` *can* end an expression and no herald is active, the deeper line is
  a continuation **iff** its first token starts an atom (`canStartAtom`, §7.2) or
  is `then`/`else`; then the line is absorbed as an extra application argument /
  `if`-continuation with **no** `INDENT`. Otherwise (deeper line led by a
  non-atom: `-`, `*`, a keyword, `|`, …) an `INDENT` opens a block. This is the
  precise content of the **"expression RHS cannot wrap"** folklore rule (§11).

### (II) `col == top` — same column: item separator

Emit a single `NEWLINE`. Stack unchanged. This separates sibling items in the
same block (top-level bindings; `let`-group bindings; `match` arms; `data`
variants; statements in a bare/`do` block).

### (III) `col < top` — shallower: close block(s)

```
popDedents col (top : tl)
    | top >  col  =  DEDENT : NEWLINE : popDedents col tl       -- pop one, recurse
    | otherwise   =  L rest ((top:tl), None, False)             -- stop when top ≤ col
```

Emit one leading `NEWLINE` (from rule III), then a `DEDENT : NEWLINE` pair for
**each** open block strictly deeper than `col`, until the stack top is `≤ col`.
Multiple blocks can close on one line. Note `top == col` stops the pop (no
`DEDENT`) — the line is a sibling at that level, already handled by the leading
`NEWLINE`.

> **Non-matching dedent.** If `col` falls *between* two stack columns (no entry
> equals it), the pop stops at the first `top ≤ col`, leaving the stack top
> `< col`. The idealized rule treats this as a layout error in waiting — there is
> no context at column `col` — but neither lexer raises here; the resulting
> stream is handed to the parser, which rejects it. (Haskell's `L` raises an
> explicit error in this case; Medaka's lexer is silent and defers to the
> parser. Specified behavior, see `LAYOUT-CONFORMANCE-AUDIT.md` A-DEDENT.)

---

## 5. Continuation rules (the heart of the bug surface)

A *continuation* is when a physical line break does **not** end the logical line.
There are four, applied at two different stages.

### 5.0 The two operator sets (asymmetric — note carefully)

```
TRAILING-continuation ops (≈20): prev token that absorbs the next deeper line
    +  -  *  /  %  ++  ::  ==  !=  <  >  <=  >=  &&  ||  |>  >>  <<  `ident`
    (arrows -> => <- are EXCLUDED; trailing `-` is always binary here)

LEADING-continuation ops (7): next-line-initial token that continues prev line
    |>  >>  <<  &&  ||  ++  ::
```

The leading set is a **strict subset** of the trailing set. The difference is
deliberate: `+`, `-`, `*`, `/` may *trail* a line (`x +⏎ y`), but may **not**
*lead* one (`x⏎ + y` is **not** a continuation — leading `-`/`*`/`+` is
ambiguous with unary minus / a section / a fresh term, so it opens a block
instead). Only operators that are unambiguously infix-and-nothing-else may lead.

### 5.1 Leading-operator continuation (Stage A)

If, after a newline, the first non-whitespace begins one of the 7 leading ops,
the scanner emits the operator token and **no `Nl`** — the line is glued to the
previous one. `a⏎  |> f` lexes as `a |> f`.

### 5.2 Comment transparency (Stage A) — see §3.

### 5.3 Trailing-operator continuation (Stage B, rule I.a) — see §4.

### 5.4 `then` / `else` continuation (Stages B + C)

A `then` or `else` leading the next line continues the enclosing `if`; the
grammar wants `IF e THEN e' ELSE e''` with **no** intervening `NEWLINE`. This is
enforced in two complementary places, and **both** are required:

- **Stage B (`resolveCont`)** swallows a *deeper-line* `then`/`else` (the I.c
  arm) before any `NEWLINE` is even produced.
- **Stage C (`elseFilter`)** is a final pass that drops a `NEWLINE` appearing
  immediately before a `THEN`/`ELSE` token, **keeping any `DEDENT`**. This
  catches the *same-column* and *dedented* cases (II and III) that Stage B
  emitted a `NEWLINE` for.

> **Implementation note / latent-divergence site.** The OCaml oracle fuses these
> as `filter_newline` (one-token lookahead, drop `NEWLINE` before `THEN`/`ELSE`)
> plus `resolve_pending` (the deferred-INDENT path). The selfhost lexer uses
> `resolveCont` + a pure-list `elseFilter`. These are *different code* computing
> the *same relation*; they are verified equivalent across the audit battery, but
> a future edit to one without the other is the single most likely way to
> reintroduce a layout divergence. See `LAYOUT-CONFORMANCE-ROADMAP.md` WS-2.

---

## 6. Bracket depth disables layout

The four bracket families increment a **depth** counter; their closers
decrement it:

```
open:  (   [   [|   {   .{          close:  )   ]   |]   }
```

While `depth > 0`, **Stage A emits no `Nl` items at all** — every newline inside
a bracketed region is invisible to layout. This is *how* multi-line parenthesized
expressions, list/array literals, and record/set braces work: indentation is
free-form inside them. `INDENT`/`DEDENT`/`NEWLINE` never appear between a matched
bracket pair.

**String interpolation** (`"… \{ e } …"`) is tracked by a *separate* depth
(`interp_depth` / the `id` thread): a `{` inside an interpolation increments the
interpolation depth, **not** the bracket depth, so the layout-disabling counter
is never confused by interpolation braces. Layout is likewise disabled inside an
interpolated expression.

**Brace-in-comment safety.** Because comments are recognized in Stage A *before*
any character reaches the bracket-depth counter, a `{` (or `(`/`[`) appearing
inside a `--` line comment or a `{- … -}` block comment **never** perturbs the
depth counter. This closes a historically recurring bug class (an unbalanced `{`
in a comment throwing off brace counting).

---

## 7. Heralds, and the predicates that define them

Medaka has **no explicit layout-keyword whitelist**. Whether a deeper line opens
a block is decided by three predicates over tokens.

### 7.1 `canEndExpr` — the atom-ender whitelist

```
canEndExpr t  =  t ∈ { IDENT, UPPER, INT, FLOAT, STRING, CHAR, BOOL,
                       INTERP_END, ')', ']', '}', '|]'(RARRAY), '_', '?' }
```

`prevCanEnd prev = canEndExpr prev` (and `False` if `prev = None`). A token that
can end an expression is a possible left operand / function for a continuation; a
token that **cannot** (rule I.b) is, by definition, an **implicit-block herald**.
Heralds are therefore *derived*, not listed — but in practice the herald set is:

```
=   =>   ->   <-   match   record   do   where   of   let   if   then   else
|   ,   :   and every binary operator   ( [ {   …  (anything not in canEndExpr)
```

This is why `f x =⏎  body`, `match s⏎  Arm => …`, `g x =>⏎  body`, and
`do⏎  stmt` all open blocks: the line being closed ends in `=` / `match`-armed
`opener` / `=>` / `do`, none of which `canEndExpr`.

### 7.2 `canStartAtom` — the application-argument starter set

```
canStartAtom t  =  t ∈ { INT, FLOAT, STRING, CHAR, BOOL, IDENT, UPPER, '_',
                         '(', '[', '[|'(LARRAY), '{', '@', INTERP_OPEN }
```

Used in `resolveCont` (rule I.c): a deeper line starting with an atom is absorbed
as another application argument rather than opening a block.

### 7.3 `isOpener` — the match/record one-shot

```
isOpener t  =  t ∈ { match, record }
```

`opener` is armed if a `match` or `record` header appears anywhere on the line
being closed and forces rule I.b (open a block) even when `prev` *could* end an
expression. Without it, `match s⏎  Some x => …` would mis-absorb `Some` as an
argument of `s` (since `s` `canEndExpr` and `Some` `canStartAtom`). The flag is
**one-shot**: consumed (reset to `False`) at the next line boundary.

---

## 8. End of file

At `EOF`, flush the layout stack: emit one `NEWLINE`, then a `DEDENT : NEWLINE`
pair for every open block above the base, then `EOF`:

```
closeAll [c]          =  NEWLINE : EOF                 -- only base 0 left
closeAll (c : rest)   =  NEWLINE : DEDENT : closeAll rest
```

An empty source lexes to exactly `NEWLINE EOF`. (Both lexers: verified.)

---

## 9. Construct-by-construct summary

| Construct | Block kind | How layout treats it |
|---|---|---|
| Top-level bindings | implicit @ col 0 | siblings separated by `NEWLINE` (II); `EOF` closes |
| `name … = body` (body on next line) | implicit | `=` is a herald (¬canEndExpr) ⟹ body line opens `INDENT` |
| `name … = body` (body same line) | none | body is an application; deeper lines continue per §5/I.c |
| `let`-group | implicit | bindings are siblings (II); herald is the line-ending `=` of each |
| `let … in …` (one line) | none | accepted; `in` is an infix-ish keyword on the same logical line |
| `let …⏎ in …` (`in` leads a line) | n/a | **rejected** by both parsers — no `parse-error(t)` to close the let-block; see §11, AUDIT P-LETIN |
| `where` at end of body line | implicit | `… body where⏎  defs` — `where` heralds the defs block |
| `where` on its own indented line | implicit | defs must be **deeper** than `where`; both forms in SYNTAX.md verified |
| `match s` arms | implicit | `match` arms `opener` ⟹ arm line opens block; arms are siblings (II) |
| `Arm => body` (body on next line) | implicit | `=>` heralds the arm-body block |
| `if / then / else` (multi-line) | none | `then`/`else` leading a line continue the `if` (§5.4); **no** block |
| `data T =⏎ \| A \| B` (leading `\|`) | implicit | `=` heralds the variant block; each `\| A` is a sibling line (II). **Lexes identically in both; the OCaml *parser* rejects leading-`\|`, the native parser accepts it — a frozen-oracle parser gap, not a layout gap.** See AUDIT P-DATAPIPE |
| record `{ … }`, set `{ … }`, list `[ … ]`, array `[\| … \|]`, tuple `( … )` | **explicit** | bracket depth > 0 ⟹ layout **off** (§6); free-form multi-line |
| string interpolation `"… \{e} …"` | explicit | separate interp depth; layout off inside `e` |

---

## 10. Worked examples (token streams; both lexers identical)

```
main =                    IDENT "main" EQUAL INDENT
  if True                 IF UPPER "True" THEN INT 1 ELSE INT 2     ← then/else glued (§5.4)
  then 1                  NEWLINE DEDENT
  else 2                  NEWLINE NEWLINE EOF
```
```
data Color =              DATA UPPER "Color" EQUAL INDENT
  | Red                   PIPE UPPER "Red"   NEWLINE
  | Green                 PIPE UPPER "Green" NEWLINE
  | Blue                  PIPE UPPER "Blue"  NEWLINE DEDENT NEWLINE NEWLINE EOF
```
```
r = identity              IDENT "r" EQUAL IDENT "identity" INT 5     ← atom continuation (§4 I.c): NO indent
  5                       NEWLINE NEWLINE EOF                          → parses as `identity 5`
```
```
x = 1                     IDENT "x" EQUAL INT 1 INDENT MINUS INT 2    ← `-` is not an atom/leading-op:
  - 2                     NEWLINE DEDENT NEWLINE NEWLINE EOF            opens a block ⟹ RHS parse error (§11)
```

---

## 11. The "expression RHS cannot wrap" rule, stated precisely

SYNTAX.md says an expression RHS "cannot wrap onto a second indented line, except
when the continuation starts with a leading binary operator." That is an
*approximation*. The exact rule, derived from §4–§5:

> A deeper-indented line **continues** the current logical line (emits **no**
> `INDENT`) iff **one** of:
> 1. the previous token is a **trailing-continuation operator** (§5.0), or
> 2. the line **starts with a leading-continuation operator** (§5.0, the 7-op
>    set — note this set includes `::`, which SYNTAX.md omits), or
> 3. the previous token **`canEndExpr`** *and* the line's first token
>    **`canStartAtom`** (or is `then`/`else`).
>
> Otherwise the deeper line **opens an implicit block** (`INDENT`). In
> expression-RHS position the grammar has no production for a block there, so the
> result is a **parse error** — which is the symptom users describe as "the RHS
> can't wrap."

So `r = 1 +⏎ x` (1, trailing), `r = a⏎ |> f` (2, leading), and `r = id⏎ x`
(3, atom) **all wrap and parse**; `x = 1⏎ - 2` and `x = id⏎ let …` open a block
and **fail**. The `let … in` own-line case (§9) fails for the related reason: no
`parse-error(t)` exists to retro-close the let-block when `in` appears
left-shifted.

---

## 12. Conformance contract

1. **Both lexers compute the relation L of §4 plus the Stage-A/§5/§6 rules,
   bit-for-bit.** The differential gates `test/diff_selfhost_lexer.sh`
   (curated corpus) and `test/diff_selfhost_lex_files.sh` (the stdlib + the
   lexer itself) enforce token-stream identity. As of this writing they pass and
   the audit battery (≈65 probes beyond the corpus) finds **zero** token-level
   divergence.

2. **Dump probes (how to observe the relation):**
   - canonical: `test/bin/lex_main <file>` (the native lexer on the interpreter
     entry `selfhost/entries/lex_main.mdk`; build via `sh test/build_oracles.sh`),
   - oracle: `./_build/default/dev/lextok.exe <file>` (OCaml
     `Lexer.tokenize_string`; build via `dune build dev/lextok.exe`).
   Both print one token per line in the canonical `token_to_string` form,
   including `INDENT` / `DEDENT` / `NEWLINE`.

3. **When `lib/` is removed,** §4–§8 of this file replace the oracle as the
   definition `selfhost/frontend/lexer.mdk` is held to; the audit's probe battery
   (promoted to fixtures per ROADMAP WS-7) becomes the regression net.

4. **This file is updated to track the binary, never the reverse for accepted
   behavior** — but a *newly discovered* divergence between a lexer and this
   spec is a lexer bug (file a ROADMAP item), whereas a divergence between this
   spec and SYNTAX.md/PLAN.md is a doc-drift bug in *those* files (this file is
   the layout ground truth).
