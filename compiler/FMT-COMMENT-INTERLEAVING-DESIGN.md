# FMT comment-interleaving design — fixing finding "L"

**Status:** LANDED. Stages 1–2 (verbatim safety-net + parser side-channel),
Stage 3+4 (operator-CHAIN interior-comment interleaving), and **Stage 5
(statement-level block/`do`/let-group interiors)** are all shipped. A decl whose
body is a bare block (`EBlock`) or do-block (`EDo`) now FORMATS with each
statement's trailing comment anchored to its statement across reflow, provided
(a) the parser side-channel's per-statement line count matches the AST statement
count and (b) every interior comment anchors to a statement line; otherwise the
decl stays on the verbatim safety-net (multi-line statements, standalone interior
comments). Seed re-mint NOT required — the parser side-channel is emit-invisible
(`selfcompile_fixpoint` C3a/C3b byte-for-byte).

**Scope of the bug (finding "L"):** `medaka fmt` misplaces trailing line-comments
when it reflows a multi-line expression body. Canonical repro —
`sqlite/lib/select.mdk`'s `identChar`:

```
-- SOURCE
identChar c =
  (c >= 48 && c <= 57)        -- 0-9
  || (c >= 65 && c <= 90)     -- A-Z
  || (c >= 97 && c <= 122)    -- a-z
  || c == 95                  -- _
-- fmt PRODUCES (comments shift down one operand; last two merge)
identChar c = c >= 48 && c <= 57
  || c >= 65 && c <= 90  -- 0-9
  || c >= 97 && c <= 122  -- A-Z
  || c == 95  -- a-z  -- _
```

---

## 1. Empirical root cause of L (with citations)

### 1a. The current self-hosted port ALREADY goes beyond OCaml

The self-host formatter is split across two modules:

- `compiler/tools/printer.mdk` — the **comment-FREE** Wadler/Leijen Doc engine
  (`data Doc = Nil | Text | Cat | Line | Softline | Hardline | Nest | Group |
  FlatGroup | FlatAlt`, printer.mdk:59–74; `render`/`go`/`fits`, :156–209). It
  renders an expression body **opaquely** — the Doc it produces carries no memory
  of which source line any sub-expression came from.
- `compiler/tools/fmt.mdk` — the comment-aware driver `formatProgram`
  (fmt.mdk:333–340), a port of OCaml `format_program`, that interleaves the
  lexer's captured comment side-channel (`Comment line col text`,
  lexer.mdk:1327–1339; `collectComments`, :1360) using the parser's per-decl
  `(line, end_line)` position side-channel.

Crucially, fmt.mdk did **not** stop at the OCaml feature set. It added an
**interior-comment splice** that OCaml never had — `spliceInterior` /
`attachInterior` / `attachOnLine` (fmt.mdk:246–274), gated by `isInterior`
(:212–215). This is the code path that produces the L bug.

### 1b. Why the splice mis-places comments — the exact mechanism

`isInterior startLine endLine c` (fmt.mdk:212–215) selects single-line comments
strictly inside the decl body (`startLine < c.line < endLine`). `spliceInterior`
(:249) then splits the **rendered** decl string into output lines and re-attaches
each interior comment onto the output line whose index equals
**`c.line − decl.startLine`** (`attachOnLine`, :270:
`if commentLine c - startLine == idx`). The header comment states the assumption
outright (fmt.mdk:206–210): *"The decl renders one output line per source line …
output-line index = c.line - decl.line."*

That assumption is **false whenever the Doc engine reflows the body**, which is
exactly what happens to a wide `||`-chain RHS:

- `printDefRhsGeneral` routes a non-continuation binop RHS to
  `Cat (text " =") (group (nest (Cat Line (printBinOpTrailing op l r))))`
  (printer.mdk:996–1000). The width-driven `group`/`Line` and
  `printBinOpTrailing` (:1017–1026, `afterOp = Line`) decide breaks by **column
  width**, not by source line — and they pull the first operand up onto the `=`
  line. So source line 2 (`(c >= 48 && c <= 57)`) and the header collapse into
  **output line 0**.
- Every subsequent operand is therefore off by one: the `-- 0-9` comment (source
  line 2, index 1) lands on output line 1 (`|| c >= 65 && c <= 90`) instead of
  line 0. Hence the "shift down one operand."
- The **last** comment `-- _` sits on `end_line`, so it is *also* pulled out by
  the decl-granular `takeTrailing` (fmt.mdk:182–189) and appended inline after
  the whole decl (`appendTrailing`, :192–195). Meanwhile `-- a-z` (interior, out
  of range or last-line index) splices onto the final output line too — so the
  last line collects **both** (`|| c == 95  -- a-z  -- _`). Hence the "last two
  merge."

Root cause in one line: **fmt.mdk maps comments to output by source-line index,
but printer.mdk reflows the body so output lines no longer correspond 1:1 to
source lines.** The two layers share no coordinate system.

### 1c. The OCaml reference behaves differently — and is ALSO wrong here

`git show oracle-frozen:lib/printer.ml`, `format_program` (:1009–1109):

- `take_trailing loc` (:1087–1094) pulls only comments on `loc.end_line`
  (single-line) → rendered inline after the decl (:1099–1102).
- `flush_before line` (:1042–1050) emits pending comments with `c_line < line`
  as **standalone lines**, blank-gated.
- `decl_doc` (:1066–1079) renders every decl via `print_decl` **opaquely**,
  *except* `DData`, which is special-cased through `print_data_decl_commented`
  (:964–989) using the `variant_lines` side-channel to anchor interior comments
  before the `|`-variant they precede.

For a `||`-chain body there is **no** variant machinery. The three interior
comments (`-- 0-9`, `-- A-Z`, `-- a-z`) are not `< loc.line` and not on
`loc.end_line`, so they are neither flushed-before nor taken-trailing at *this*
decl. They stay in the `cs` stream and get flushed by the **next** decl's
`flush_before` (:1096) — i.e. OCaml would emit them as **standalone lines dumped
before the next declaration**, detached from their operands. Different wrong
output, same underlying limitation.

---

## 2. The key finding (answer to the central question)

**Does the OCaml `format_program` correctly place a trailing comment in the
MIDDLE of a multi-line expression body (the `identChar` case)? — NO.**

OCaml anchors comments at exactly three granularities, all citable:

1. **Leading** — standalone lines before a decl (`flush_before`, :1042).
2. **Decl-trailing** — a single-line comment on the decl's `end_line`, inline
   (`take_trailing`, :1087).
3. **Data-variant-interior** — via the `variant_lines` side-channel and
   `print_data_decl_commented` (:964, :1068–1077).

There is **no per-source-line / sub-expression anchoring for expression bodies**.
An expression body is rendered opaquely by the comment-unaware Doc engine
(`render width (decl_doc decl)`, :1098). Interior expression comments fall
through to the next decl's flush.

**Consequence:** a "full port" of OCaml would **not** fix L — it would replace
one wrong output with another (interior comments dumped as standalone lines above
the next decl). The self-host port already *attempted* new work
(`spliceInterior`) that OCaml lacked, and got it half-right; the missing piece —
**making comment placement survive Doc reflow** — is genuinely **new work beyond
a port**, in both the OCaml and self-host lineages. State this plainly to avoid
the trap of "just finish the port."

---

## 3. Recommended mechanism

The fundamental problem is a **missing shared coordinate system** between the
comment stream (keyed by source line) and the rendered output (keyed by
width-driven layout). Three candidate mechanisms:

### Option A — Thread comments INTO the Doc IR as first-class nodes *(recommended)*

Add one constructor, e.g. `TrailingComment String` (a `Doc` that renders as
`"  " ++ text` and forces its enclosing group to **break** so nothing can be
appended after it on the same output line — a line comment runs to EOL). Anchor
it at the exact sub-expression where the comment belongs, at Doc-construction
time, *before* layout runs. Because it is part of the Doc, wherever the engine
places that operand's line, the comment rides along — reflow can no longer
separate them.

- **How anchoring works:** the printer functions that build the RHS Doc
  (`printBinOpTrailing`, printer.mdk:1017; the operand walk) must receive the
  per-operand comment map (keyed by source line) and, when an operand's source
  line has a trailing comment, wrap that operand's Doc with the comment node.
  This requires the AST operands to carry (or be correlated with) source lines.
  **Gap:** the self-host AST `EBinOp op l r _` has no per-node `Loc` (printer.mdk
  header, :14–15: "No ELoc wrapper — the self-host parser builds no location
  nodes"). So operand→source-line correlation needs either (i) a parser
  side-channel of operand start lines (mirroring `variant_lines`), or (ii)
  re-lexing the decl's source span to recover operand line positions.
- **Break discipline:** the comment node must set the enclosing group to Break
  (like `Hardline`) so `fits` never tries to pack a following operand after a
  `--` comment. `fits` (printer.mdk:156) and `go` (:186) each need one arm.
- **Pro:** correct by construction across arbitrary reflow; localizes the fix in
  the Doc engine + the RHS printers; no fragile index math.
- **Con:** changes the `Doc` type (a `public export data`, printer.mdk:59) → all
  `fits`/`go`/`flatten`-style totality points must gain an arm; needs an
  operand→line side-channel from the parser (the largest sub-task). Touches the
  printer's byte-exact output contract → golden recapture.

### Option B — Source-line mapping layer (extend the current splice)

Keep comments out of the Doc but make the engine emit, alongside each output
line, the **source line it originated from** (a parallel `List Int`), then splice
by matching source line instead of by output-line index. `go`/`render` would
return `(String, sourceLine)` pairs.

- **Pro:** no new `Doc` constructor; keeps comment logic in fmt.mdk.
- **Con:** the Doc engine has **no source-line information to emit** in the first
  place — `Text`/`Line` nodes carry no origin. You would still have to thread
  operand source lines into the Doc (same parser side-channel as A) just to tag
  output lines. So B pays A's hardest cost (operand→line correlation) *and* keeps
  the brittle post-hoc splice. Strictly worse than A. **Not recommended.**

### Option C — Hybrid: bail-and-preserve-verbatim fallback

Detect the unsupported shape (a decl body that reflows *and* carries interior
comments) and, rather than risk mis-placement, **emit that decl's original source
span verbatim** (unformatted) — formatting everything else. A safe, small,
shippable first step that guarantees **no comment is ever moved to the wrong
operand or dropped**, at the cost of not reformatting those specific decls.

- **Pro:** tiny, low-risk, immediately kills the *corrupting* face of L
  (misattribution/merge). Good Stage-1 safety net regardless of A.
- **Con:** those decls aren't reflowed at all (acceptable — they were already
  hand-laid-out); needs the decl's raw source span (parser already tracks
  `(line, end_line)`; needs column/offset span too, or re-slice by line).

**Recommendation:** ship **C as Stage 1** (stop corrupting), then build **A** as
the real fix (correct interior placement across reflow). Retire the current
`spliceInterior` index-math path (fmt.mdk:246–284) — it is unsound by
construction and A/C both supersede it.

---

## 4. Touchpoints

| Layer | File | Change |
|-------|------|--------|
| Doc IR | `compiler/tools/printer.mdk` | (A) add `TrailingComment String` (or `LineComment`) to `data Doc` (:59); add arms to `fits` (:156) and `go` (:186) forcing Break; anchor comments in `printBinOpTrailing` (:1017), `printOperand` (:1030), `printDefRhsGeneral` (:996). |
| Comment driver | `compiler/tools/fmt.mdk` | Remove/replace the source-index splice (`spliceInterior`/`attachInterior`/`attachOnLine`/`isInterior`, :212–284). Feed per-operand comments to the printer instead of post-splicing. Keep leading/`takeTrailing`/`DData`-variant paths (they're correct). |
| Parser side-channel | `compiler/frontend/parser.mdk` | (A) surface operand/sub-expression start lines for binop-chain RHSs — a new `Positions` field mirroring `positionsVariantLines`. (C) surface each decl's raw source **span** (offsets) for verbatim fallback. |
| Lexer | `compiler/frontend/lexer.mdk` | No change expected — `Comment line col text` (:1327) already carries line+col+text; block-vs-line is derivable from an embedded `\n` (as OCaml does, `String.contains c_text '\n'`, and fmt.mdk `isSingleLine`, :68). Confirm col is populated if operand-column disambiguation is needed. |

The **seam** is the parser side-channel: the whole fix hinges on giving the
formatter a way to correlate a comment's source line with the sub-expression Doc
it should ride on. Everything else follows.

---

## 5. DESIGN FORKS — need a human decision

1. **Scope of interior support.** (a) Only **binop-chain** RHS trailing comments
   (the L case, ~covers the sqlite repro)? (b) All **block/`do`/`let`-group**
   inner-statement trailing comments too (fmt.mdk already *attempts* these via
   the same broken splice, :197–210)? (c) Full arbitrary interior? Recommend
   (a)+(b) — they share the mechanism — deferring (c).
2. **Change the `Doc` type (Option A) vs verbatim-only (Option C forever)?**
   A is the correct fix but touches the byte-exact printer contract and needs the
   parser side-channel; C alone never mis-places but never reflows commented
   decls. Do we commit to A, or is C acceptable as the permanent answer?
3. **Operand→source-line correlation strategy:** new parser side-channel
   (clean, mirrors `variant_lines`, but threads through parser + `Positions` +
   fmt) vs. re-lex the decl's source span in fmt (localized to fmt.mdk, no parser
   change, but re-derives layout). Which seam do you want to own?
4. **Block comments** (`{- … -}`, multi-line) in mid-expression: keep OCaml's
   rule (single-line only is trailing; multi-line stays standalone,
   fmt.mdk:66–69) or attempt inline placement? Recommend keep the OCaml rule.
5. **Unplaceable comment fallback:** if a comment can't be confidently anchored
   (operand line not recoverable, reflow ambiguous), do we (a) bail to verbatim
   for that decl (Option C), (b) emit standalone-before-next-decl (OCaml
   behavior), or (c) hard-error? Recommend (a) — never drop, never misplace.
6. **Retire `spliceInterior`?** It is unsound (index math vs reflow). Confirm we
   delete it rather than layer A on top.

---

## 6. Staged implementation plan (ascending risk; each stage independently gated)

**Stage 0 — regression fixtures (no code).** Add `identChar`-shaped fixtures to
`test/fmt_fixtures/` (binop chain with per-operand trailing comments; a
block-body variant; a `data`-variant control that must stay correct). Capture
goldens with the *desired* output. Gate: `test/diff_compiler_fmt.sh`.

**Stage 1 — safety net (Option C).** Detect "reflowed body + interior comment"
and emit that decl verbatim from its source span; disable the unsound
`spliceInterior` for that shape. Goal: **no misplacement/merge/drop**, even if the
decl isn't reflowed. Gates: `diff_compiler_fmt`, `diff_compiler_printer`,
`selfcompile_fixpoint`. Lowest risk — no `Doc` type change.

**Stage 2 — parser side-channel.** Surface operand/sub-expression start lines
(and/or decl source spans) via `Positions`. No formatter behavior change yet;
gate that existing goldens are unperturbed (`diff_compiler_parse*`,
`diff_compiler_fmt`, `diff_compiler_printer`).

**Stage 3 — Doc-IR comment node (Option A core).** Add `TrailingComment` to
`Doc`; wire `fits`/`go` (force Break); anchor in `printBinOpTrailing` /
`printOperand` / `printDefRhsGeneral` using the Stage-2 side-channel. Replace the
Stage-1 verbatim path for binop chains with real interleaving. Recapture
`fmt`/`printer` goldens. Gates: `diff_compiler_fmt`, `diff_compiler_printer`,
`selfcompile_fixpoint`, plus a full `medaka fmt` idempotency sweep over
`stdlib/` + `sqlite/` (`diff <(medaka fmt --stdout f) <(medaka fmt --stdout <(medaka fmt --stdout f))`).

**Stage 4 — extend to block/`do`/let-group interiors** (fork 1b), same mechanism.
Gates as Stage 3.

**Stage 5 — SHIPPED (block/`do`/let-group statement interiors).** The parser
side-channel's `declChainLines` now, for a block-bodied decl (`declBlockRhs`),
returns each top-level statement's first-content source line
(`blockStmtLines`/`blockStmtGo`, INDENT/DEDENT/NEWLINE-tracked at block depth 1);
`fmt.mdk`'s `stepDecl` gates a `useBlock` path (statement count ==
`declBlockLen` decl AND every span comment covers a statement line) that calls
`printer.mdk`'s `printDeclBlockCommented`, which renders the block/do body with
`Hardline`-separated statements and each statement's trailing comment anchored as
a `LineComment`. Because commented blocks/chains are now structured with
unconditional `Hardline`s, `fits (LineComment _) = True` (stops the line-measure
at the comment rather than force-breaking via `fits`). Multi-line statements make
the line count mismatch the AST → verbatim fallback (never drops/misplaces a
comment). Gates: `diff_compiler_{fmt,printer,parse}`, whole-repo idempotency,
6-file comment-multiset sweep (0 loss), `selfcompile_fixpoint` C3a/C3b YES.

**Gates summary per stage:** `bash test/diff_compiler_fmt.sh` +
`bash test/diff_compiler_printer.sh` (recapture with `CAPTURE=1` when output
intentionally changes) and `bash test/selfcompile_fixpoint.sh`. Always
`FORCE=1 bash test/build_oracles.sh` before trusting stale-prone gates, and run
`make -C <worktree> medaka` first (fmt runs on the *binary*).

---

## 7. Risk register + seed re-mint

| Risk | Mitigation |
|------|------------|
| Changing `data Doc` breaks totality in `fits`/`go` | Compiler is total-checked; add both arms in one edit; `printer` goldens catch layout drift. |
| Byte-exact printer contract drift (LSP hover, `medaka new`, REPL echo all use `render`) | New Doc node is inert unless a comment is present, so pure-AST rendering (no comments) is unchanged; verify `diff_compiler_printer` shows **zero** diff for comment-free fixtures. |
| Idempotency regression (fmt must be a fixpoint) | Explicit idempotency sweep in Stage 3 gate; this is how the last 3 fmt bugs were caught (MEMORY: `project_fmt_three_bugs_fixed`). |
| Comment forces a break that widens diff churn on already-fitting lines | A trailing `--` comment inherently forces a line break in source too; matching that is correct, not churn. |
| Parser side-channel perturbs unrelated position consumers | Stage 2 is behavior-neutral and gated before any formatter change. |

**Seed re-mint: NOT required.** The emitter self-compile graph is
`compiler/backend/llvm_emit.mdk` + its transitive imports; the checked-in seed is
`compiler/seed/emitter.ll(.gz)`. `printer.mdk` and `fmt.mdk` are **`medaka fmt`
tooling** — the emitter never formats source, so neither module is in the emitter
import graph. `selfcompile_fixpoint` compiles the **emitter** source, whose IR is
unaffected by printer/fmt edits, so the fixpoint holds without a re-mint (it must
still be *run* as a gate to prove no accidental coupling). A normal
`make -C <worktree> medaka` rebuild picks up the tooling change; only the
`fmt`/`printer` **goldens** need recapture. (Contrast: a lexer primitive rename
*would* need a re-mint — MEMORY `project_byteparser_stdlib_promotion` — but this
work touches no emitter-graph module.)
