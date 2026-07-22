# SOURCE-POSITION-DESIGN.md — principled, unified line:column (source-span) tracking; #331 as increment 1

**Status:** DESIGN — 9bda822a, 2026-07-22 (forks F1/F2/F3 locked, see "Decisions" below; F4/F5 default to RECs). Read-only static analysis of the tree at the orchestrator's HEAD, no
build run. Every `file:line` below was `sed`-confirmed against `.mdk` source (not docs).
Scope: make line:column tracking principled and bulletproof for tooling (LSP/MCP go-to-def,
document-outline, references/rename, blast-radius) with issue **#331** (decl ranges are
line-granular, `character` hardcoded to 0) as increment 1.

## Decisions (locked 2026-07-22 by Val)

The §6 forks are resolved as below — this is the scope the implementation increments build to.
Sequencing (which increment lands when, and `typecheck.mdk` ordering vs the concurrent
typecheck refactor) is deliberately deferred; see §4/§5, decided per-increment.

- **F1 — span type: REUSE `Loc`.** No new `Span` type. This finishes the existing convention
  rather than forking it (accepts `Loc`'s `file==""` wart).
- **F2 — name-span carrier: CHANNEL-FIRST.** Increment 1 (#331) stores the name `Loc`
  additively in the `Positions` channel; the carrier migrates onto an AST node field at
  increment 4. Chosen because it composes toward the target (the name-finder logic is reused —
  only the carrier moves) and keeps increment 1 small and low-risk.
- **F3 — selectionRange extent: NAME-TOKEN ONLY** (`foo`, not `foo x y`), with the whole-decl
  line range as the enclosing `range`.
- **F4 — impl head target:** defaults to the doc REC (head `TyCon`'s `Loc`, falling back to the
  `impl` keyword for fully-parametric heads); revisit at increment 5.
- **F5 — `columnAfterName`:** defaults to the doc REC — retire once increment 1 gives inlay
  hints a real name `Loc`.

---

## 0. Relationship to existing location design docs (does a spec already answer this?)

**There is NO umbrella source-position spec.** There are **three point-fix design docs**, each
solving one diagnostic's bad span, plus this facet (decl ranges) which never got one:

| Doc | Scope | Node it put a `Loc` on | Status |
|---|---|---|---|
| `compiler/PARSE-ERROR-LOCATION-DESIGN.md` | parse-error caret/column | (none — furthest-fail token index → `offsetToLineCol`) | PARTIAL/IMPLEMENTED |
| `compiler/RESOLVER-DIAG-LOCATION-DESIGN.md` | 3 resolver `{0,0}` diags | `TyCon String (Option Loc)`, `DUse Bool UsePath Loc` | IMPLEMENTED |
| `compiler/TYPE-ERROR-SPAN-DESIGN.md` | type-error squiggle width | (widened lexer string offset + `ELoc`/`currentLoc` reads) | IMPLEMENTED |

**Verdict: they are three independent point-fixes, but they CONVERGED — without ever saying so
— on a single latent convention.** That convention, never written down as a spec, is:

> **The canonical span type is `Loc String Int Int Int Int`** = (file, startLine, startCol,
> endLine, endCol), 1-based line / 0-based col (`ast.mdk:26`). **To give an AST node a real
> source span, add an `Option Loc` (or inline `Loc`) FIELD to that node, capture it in the
> parser via `locOfSpan startTok endTok`, and make the S-expr serializer ignore the field so
> goldens stay byte-identical.** `ELoc Loc Expr` did it for expressions (`ast.mdk:290`);
> `TyCon String (Option Loc)` did it for type leaves (RESOLVER doc, Chunk A); `DUse Bool
> UsePath Loc` did it for imports (RESOLVER doc, Chunk B).

So the ideal architecture is **NOT a fourth scheme** — it is *finishing the adoption of the
convention the three docs already established*, on the one holdout that predates it: the
declaration layer, which still uses a **separate out-of-band line-only side-channel
(`Positions`/`DeclPos`)** instead of a `Loc` field. **#331 is "make decls join the `Loc`
convention."** Contradiction between code and the docs' intent is flagged in §2.6.

---

## 1. Current-state map (empirical)

### 1.1 The position data pipeline (verified call-chain)

```
SOURCE STRING
  │
  ▼  lexer.mdk — layout/scan
RawTok Token startOff endOff            (RTok carries 0-based char offsets; lexer.mdk:359-367)
  │
  ├─► tokenizeWithLines   (lexer.mdk:2032)  → (tokens, per-token 1-based LINE)   [drops columns]
  ├─► tokenizeWithOffsets (lexer.mdk:2047)  → (tokens, per-token start OFFSET)
  └─► tokenizeWithOffsetPairs (lexer.mdk:2062) → (tokens, per-token (start,end) OFFSET pair)
  │
  ▼  offset→(line,col) SERVICE
offsetToLineCol      (lexer.mdk:2075)  String  -> Int -> (1-based line, 0-based col)   [O(N) walk]
offsetToLineColFast  (lexer.mdk:2099)  Array Int(lineStarts) -> Int -> (line,col)      [O(log N)]
lineStartsOf         (lexer.mdk:2082)  precomputes the sorted line-start array
  │
  ├───────────────── EXPRESSION LAYER (column-precise) ─────────────────┐
  │                                                                       │
  │  setLocState src offsets    (parser.mdk:180) stashes src+lineStarts+offsets in module Refs
  │  tokOffsetAt / tokEndOffsetAt (parser.mdk:187-198) read the offset arrays by token index
  │  locOfSpan startIdx endIdx  (parser.mdk:205-211) → full Loc via offsetToLineColFast (x2)
  │  located : Parser Expr      (parser.mdk:214-219) wraps a production in ELoc (locOfSpan s q)
  │  → ELoc Loc Expr            (ast.mdk:290)  transparent; parser wraps ONLY atoms/leaves +
  │                              let/if/match/function/do (TYPE-ERROR-SPAN-DESIGN §1, parser.mdk:628-634)
  │
  └───────────────── DECLARATION LAYER (line-only, out-of-band) ─────────┐
                                                                          │
     declWithSpan   (parser.mdk:3395) captures (Decl, startTokIdx, endTokIdx) per decl
     programWithSpans (parser.mdk:3410) = skipNoise; many (declWithSpan; skipNoise)
     declPosOf toks lines (parser.mdk:3440-3442):
         DeclPos (lineAt lines s) (lineAt lines (lastContentIdx toks s (e-1)))
                  └── uses lineAt ONLY (parser.mdk); there is NO colAt/offset use here ──┘
     → DeclPos Int Int               (line, end_line) 1-based, NO COLUMNS   (parser.mdk:3363-3364)
     → Positions (List DeclPos) (List Int) Int (List (List Int))            (parser.mdk:3365-3366)
        │  fields: decl line-ranges · variant start-lines · last-content-line · per-decl chain-lines
        │  — computed OUT OF BAND from the token/line arrays; "the AST carries no locations"
        │    (parser.mdk:3345-3354 header comment)
        ▼
     positionsDecls / declPosLine / declPosEndLine  (parser.mdk:3376-3392)  accessors
```

Two parse entry points expose these, and they are **not equivalent**:

- `parseWithPositionsOpt src` (`parser.mdk:3720`) — re-tokenizes with `tokenizeWithLines`
  (lines only), **never calls `setLocState`**, so every `located` atom in the returned tree
  carries `located`'s **zero-loc placeholder**, not a real span. Used by the LSP
  `symbols`/`definition`/`inlayHint` handlers. → decl `Positions` are real (line-only);
  expression `ELoc`s are placeholders.
- `parseWithPositionsLocated src` (`parser.mdk:3710`) — calls `setLocState src offPairs`
  first (via `tokenizeWithOffsetPairs`), then defers to `parseWithPositions`, so the tree's
  `ELoc`s are **real column-precise spans** (added for `medaka lint` per-expr findings, #649).
  Costs one extra tokenize pass. Decl `Positions` remain line-only either way.

### 1.2 The consumers of the decl-layer channel (`DeclPos`/`Positions`)

Grepped consumers (`compiler/**/*.mdk`) — what each actually reads:

| File | Uses | Needs columns? |
|---|---|---|
| `tools/fmt.mdk` (43-49, 392-489) | `declPosLine`/`declPosEndLine` + variant/chain lines | No — line anchoring only |
| `tools/doc.mdk` (21-23, 287-366) | `declPosLine` to place doc-comment gathering | No |
| `tools/snapshot.mdk` (156-161, 486-492) | `renderDeclPos` emits `"{line}:{endLine}\n"` | No — **line-only by construction** |
| `tools/lint.mdk` (38-41, 455-480) | decl line-range to splice `--fix` over source | No |
| `tools/codemod.mdk` (61, 163) | `positionsDecls`/variant/chain lines | No |
| `tools/lsp.mdk` | `symbolParts`/`defZip`/`renderSymbol`/`inlayZip` | **YES — this is #331** |
| `tools/mcp.mdk` (256-257) | wraps lsp `documentSymbols`/`definitionResult` | **YES (surfaced via #331)** |
| `types/typecheck.mdk` | **NONE — see §1.4** | — |
| entries: `lsp_harness`, `fmt`, `lint`, `lint_fix`, `profile` | pass-through wiring | — |

### 1.3 The #331 bug sites (all in `tools/lsp.mdk`, all hardcode column 0)

- `symbolParts` (`lsp.mdk:481-490`): `let sl = declPosLine p - 1`, `el = declPosEndLine p - 1`,
  then `symbolPartsOfDecl d (jRange sl 0 el 0)` — **col 0 both ends**.
- `renderSymbol` (`lsp.mdk:514-516`): `jSymbol name kind (jRange sl 0 el 0) kids` — **col 0**.
- `defZip` (`lsp.mdk:553-554`): `Some (jRange (declPosLine p - 1) 0 (declPosEndLine p - 1) 0)`
  — **col 0**; this is the go-to-definition `Location.range`, so the cursor lands at column 0.
- **Deeper**: `symbolPartsOfDecl` (`lsp.mdk:413-441`) gives every CHILD symbol — variant
  constructors, record fields, interface methods, impl methods, let-binds — the **same
  `range` as the parent decl** (`jChild mn 6 range`, `lsp.mdk:429/433`). So nested names carry no
  own position at all; the whole outline of an `interface`/`impl`/`data` block collapses onto
  the parent's line span at col 0. This is a strictly bigger gap than the decl name itself,
  and it is exactly what symbol-nav / blast-radius (#850/#851) will need.

### 1.4 DISPROOF — `typecheck.mdk` does NOT use `DeclPos`

The orchestrator's hypothesis (a "`DeclPos` side-table threaded into typecheck at :9356")
is **false**. Every `DeclPos` token in `types/typecheck.mdk` is at line 9356, and it is a
**comment** inside the `implHeadLoc`/`#414` doc block (`typecheck.mdk:9340-9358`) that merely
*names* "the parser's `DeclPos` side-table threaded into typecheck" as one hypothetical way to
locate a fully-parametric impl — a road **not taken**. typecheck.mdk does not import `DeclPos`
or `Positions`, does not pattern-match or accessor them, and carries no decl-position table.
(The `methodConstraintPositionsRef` at :2695/:13882 is *constraint-slot indices*, unrelated to
source positions.) **Consequence: #331 and the near-term increments need not touch
`typecheck.mdk` at all.** typecheck's own span needs are served by the *type-leaf* `Loc`
(`TyCon`'s `Option Loc`, read by `tyFirstLoc`/`implHeadLoc`, `typecheck.mdk:9362-9370`) and by
`ELoc`/`currentLoc` — both already on the `Loc` convention.

### 1.5 The existing heuristic patch (`columnAfterName`)

`columnAfterName src line` (`lsp.mdk:869-877`): scans char 0 of the decl's start line over
identifier chars and returns the run length; used by `inlayZip` (`lsp.mdk:904`) to place an
inlay type hint after a value binding's name. It assumes **the name is a leading identifier
run at column 0**, so it silently misplaces for: `public`/`export`-prefixed decls, indented
decls (methods inside `impl`/`interface`), operator definitions, `data`/`impl` heads, and any
decl whose first line-token is a keyword. It is the "throwaway heuristic" B-shape, already in
the tree, already limited to the one inlay-hint site.

---

## 2. Diagnosis — what is bolted-on and why it is fragile

**2.1 Two parallel, non-interoperating position systems.** Expressions live on the `Loc`
convention (a span *in the tree*, column-precise, produced by `locOfSpan`). Declarations live
on `Positions` (a span *beside the tree*, line-only, produced by `declPosOf`). They share
neither the type (`Loc` vs `DeclPos`), the granularity (col-precise vs line-only), nor the
producer (`locOfSpan` vs `lineAt`). Every tooling feature that wants "the span of this name"
has to know which of the two worlds the name lives in.

**2.2 The asymmetry is not fundamental — the decl layer just never adopted the machinery that
already exists.** `declPosOf` (`parser.mdk:3440`) already has the decl's `(startTok, endTok)`
token span in hand; it calls `lineAt lines s` where it could call the very same
`offsetToLineColFast` that `locOfSpan` uses. The column data is one function call away and
requires **no lexer change** — the offsets are already produced by `tokenizeWithOffsetPairs`.
The line-only `DeclPos` is a historical shortcut, not a design boundary.

**2.3 Out-of-band channels rot against the tree.** Because `Positions` is a *parallel list*
zipped 1:1 with the decl list (`symbolParts (d::ds) (p::ps)`, `defZip`, `inlayZip`,
`zipDeclPos`), any change to how decls are produced/filtered risks a silent misalignment;
consumers all carry "defensive truncation to the shorter list" comments (`lsp.mdk:479`). A
span carried *in* the node cannot desync from the node.

**2.4 Hardcoded 0s and whole-decl ranges are load-bearing lies.** `jRange sl 0 el 0` reports a
range the user's editor will honor: go-to-definition lands the cursor at column 0 of the decl
(often on `public`, not the name); the outline highlights the entire decl body, so
`selectionRange` cannot chain into type-at-point. Child names inherit the parent range, so the
outline cannot address a single method/variant/field.

**2.5 Two entry points with different fidelity is a footgun.** `parseWithPositionsOpt` (LSP
symbols/definition) yields placeholder expression `ELoc`s while `parseWithPositionsLocated`
(lint) yields real ones — a caller that reaches for the wrong one gets silently position-less
sub-expressions (this already bit `medaka lint`, #649). Nothing in the types distinguishes
"positions primed" from "not."

**2.6 Where the code contradicts the docs' own convention.** `RESOLVER-DIAG-LOCATION-DESIGN.md`
established (Fork 1) that a node's span belongs as a **field on the node**, chosen *over* a
line-only or out-of-band scheme, precisely so downstream shape-matches and serializers stay
intact. The decl layer violates that settled decision: it keeps a `DeclPos` line-only
side-channel. `TYPE-ERROR-SPAN-DESIGN.md` §1 notes the parser deliberately does **not** `ELoc`
the binop/app levels — so even in the expression world the `Loc` coverage is partial. Neither
is "wrong code" against a written spec (no spec governs decls), but both are **the same
convention half-adopted**. The #414 residual (`typecheck.mdk:9351-9358`: fully-parametric
`impl Foo a` has no locatable head because only `TyCon` leaves, not `TyVar`, carry a `Loc`) is
the *same gap one layer up* — a name-bearing site with no span.

---

## 3. Ideal target architecture

**One span type, carried in the tree, produced by one service, for every name-bearing site.**

### 3.1 The three pillars (two already exist)

1. **Canonical span type: `Loc` (unchanged).** `Loc String Int Int Int Int` (file, sl, sc,
   el, ec), 1-based line / 0-based col (`ast.mdk:26`). Do **not** introduce a new `Span` type;
   the three existing docs, `ELoc`, `TyCon`, `DUse`, and all diagnostics already speak `Loc`.
   A new type would fork the very convergence this design is completing. (Fork F1 records the
   dissent for Val.)

2. **Canonical offset→(line,col) service: `offsetToLineColFast` over `lineStartsOf`
   (unchanged).** Already O(log N), already the single source of truth used by `locOfSpan`.
   Every span in the compiler should be minted through it. The line-only `lineAt` path in
   `declPosOf` is the one place that bypasses it and should be retired.

3. **Spans live as node FIELDS, minted in the parser via `locOfSpan`.** This is the
   RESOLVER-doc convention. Extend it to the two holdouts:
   - **Declaration NAME span.** Each name-bearing decl gains an `Option Loc` for the *name
     token(s)* — not the whole-decl span, the **selectionRange** the LSP wants. The whole-decl
     line range that fmt/doc/lint/snapshot rely on stays available (it is line-only and those
     consumers never want columns), so the name span is *additive*, not a replacement.
   - **Child NAME spans.** Variant constructors, record fields, interface/impl methods, and
     let-binds each carry their own name `Loc`, so the outline addresses them individually.

### 3.2 What "carried where" should look like

The cleanest end state gives the parser a single **`declNameLoc : Decl -> Option Loc`** truth,
fed by name-token `Loc` fields on the AST decl/variant/method nodes, minted by `locOfSpan`
exactly as `TyCon`/`ELoc`/`DUse` already are. The out-of-band `Positions` channel **survives**
as the line-granular fmt/doc/codemod substrate (it genuinely wants lines, not columns, and it
carries fmt-specific channels — variant lines, chain lines — that are not "locations" at all).
So the target is **not** "delete `Positions`" — it is "stop using `Positions` for *name*
spans; route those through the `Loc` convention like every other name in the compiler."

For the **name token identification** problem (which token is "the name" per decl kind), the
authority is the parser, which is already *at* the name token when it builds each decl — it
does not need to re-derive it by scanning (`columnAfterName`'s fragile approach) or by
guessing from a token span. This is the decisive reason the parser, not the LSP, should own
the span (see §7).

### 3.3 Invariants the design guarantees

- **I1 — one span type.** Every source position in the compiler is a `Loc`; no line-only decl
  positions remain in any *tooling* (LSP/MCP/diagnostic) path.
- **I2 — spans cannot desync from nodes.** Name spans are node fields, not zip-parallel lists.
- **I3 — one offset→(line,col) service.** All spans mint through `offsetToLineColFast`; the
  `lineAt`-only shortcut is gone from the name path.
- **I4 — every name-bearing site is addressable.** decl names, variant ctors, record fields,
  interface methods, impl methods, let-binds, and (closing #414) impl heads each resolve to a
  precise name `Loc`. This is the substrate references/rename (#254) and blast-radius
  (#850/#851) require.
- **I5 — golden-invisibility.** Name `Loc` fields are ignored by the S-expr serializers
  (the `tySexp (TyCon c _)` idiom, RESOLVER doc), so snapshot/desugar/mark/resolve goldens stay
  byte-identical; only the *tooling* goldens (lsp/positions/mcp) move, and only where a real
  column now appears.
- **I6 — one primed entry point.** A single parse-with-real-locations entry (the
  `parseWithPositionsLocated` shape) is the tooling default, so no caller silently gets
  placeholder `ELoc`s.

### 3.4 Justification against real future needs

- **MCP #849 (line-or-string addressing), #850/#851 (symbol nav / blast-radius).** These need
  robust **name spans** to resolve "the symbol at X" and to enumerate a symbol's def site and
  references. I4 is exactly that substrate; without it, nav lands at col 0 and blast-radius
  cannot point at a method inside an impl. `mcp.mdk:256` already advertises the gap in its own
  tool description ("Ranges are line-granular … #331 tracks true name-column fidelity").
- **references / rename (#254).** Rename must know the precise character span of every *use*
  and every *def* of a name. Uses ride on expression `ELoc` (already precise, once the primed
  entry point is the default, I6); defs ride on the new name `Loc` (I4). A line-only def span
  cannot drive a safe textual rename.
- **Diagnostics quality.** The #414 residual (parametric impl head → file-start caret) closes
  naturally once name-bearing sites carry spans; the same machinery that gives `impl Foo a`
  head a `Loc` gives the diagnostic its caret.

---

## 4. Gap analysis + staged refactor plan

**Gap summary (today → target):**

| # | Today | Target invariant |
|---|---|---|
| G1 | decl name range = `jRange sl 0 el 0` (col 0, whole-decl) | I4 — precise name `Loc`, real `selectionRange` |
| G2 | child names (variant/field/method/let-bind) reuse parent range | I4 — each carries own name `Loc` |
| G3 | name spans minted by `lineAt` (line-only) or `columnAfterName` (col-0 heuristic) | I3 — minted by `offsetToLineColFast` |
| G4 | `DeclPos` line-only side-channel is the decl carrier | I2 — name span is a node field / at least a `Loc` in the channel |
| G5 | two entry points, one gives placeholder `ELoc`s | I6 — one primed tooling entry |
| G6 | `impl Foo a` head → file-start caret (#414 residual) | I4 — parametric impl head locatable |

The plan is **five increments, ascending risk, each independently landable and gated.** The
name-token-finder built in Increment 1 is the reusable core; later increments migrate its
*carrier* and *coverage*, never re-derive its logic — so #331 composes toward the target
rather than being thrown away.

**Golden fan-out note (applies to every increment).** `parser.mdk` and `lsp.mdk` are both in
the compiler-source snapshot corpus, and BOTH are covered by the **single** suite
`test/diff_compiler_snapshot_frontend.sh` (its `run_family compiler` globs
`compiler/tools/*.mdk` and `compiler/frontend/*.mdk`, `:164-168`). So any edit to either moves
that file's own desugar/mark snapshot golden and must be blessed **same-commit** via
`sh test/diff_compiler_snapshot_frontend.sh --bless <path>` (NOT the `medaka snapshot` CLI —
memory note). Because all new spans are made **S-expr-invisible** (the `tySexp (TyCon c _)`
idiom), the desugar/mark renders stay byte-identical → the snapshot move is only the *source
text* of the edited file, not a semantic golden churn.

---

### Increment 1 — #331: precise decl-NAME span (the LSP `selectionRange`/definition range)

**Goal.** Replace `jRange sl 0 el 0` in `symbolParts`/`renderSymbol`/`defZip` with the decl
name's real `Loc`; give the inlay-hint site a real name column too (retiring `columnAfterName`).

**Mechanism (parser-authoritative — shape A, see §7):**
1. In the positions parse path, make per-token **offsets** available alongside lines
   (`tokenizeWithOffsetPairs` already exists, `lexer.mdk:2062`; the located entry
   `parseWithPositionsLocated` already primes `setLocState`, `parser.mdk:3710`).
2. Add `declNameSpanOf : (tokens, offsetPairs, lineStarts) -> (Decl, startTok, endTok) ->
   Option Loc` in `parser.mdk`: scan forward from the decl's `startTok` over leading
   modifier/keyword tokens (`public`/`export`/`data`/`newtype`/`type`/`interface`/`impl`/
   `extern`/`effect`/`test`/`prop`/`bench`/`let`) to the first **name-role** token for that
   decl kind, and return `locOfSpan nameTok (nameTok+1)`. The parser reads the token kinds
   directly, so operators, `public export`-prefixed, and indented method decls all resolve
   (this is precisely what `columnAfterName`'s col-0 scan cannot do). For `impl` (no single
   name), point at the head `TyCon`'s existing `Loc` (reuse `tyFirstLoc` logic) — this also
   sets up G6.
3. Widen the decl channel **additively**: `DeclPos Int Int` → carry an `Option Loc` name span
   (e.g. `DeclPos Int Int (Option Loc)`) OR add a parallel `List (Option Loc)` to `Positions`.
   Either is **snapshot-invisible** because `snapshot.mdk:renderDeclPos` (`:490-492`) reads
   only `declPosLine`/`declPosEndLine` — the positions golden family stays byte-identical.
4. `symbolParts`/`renderSymbol`/`defZip`/`inlayZip` (`lsp.mdk:483/514/553/904`) consume the
   name `Loc`: use its `(sc,ec)` for the symbol `selectionRange` and the definition
   `Location.range`; fall back to the old line range (col 0) when `None`.

**Files touched:** `compiler/frontend/parser.mdk` (name-finder + additive channel field),
`compiler/tools/lsp.mdk` (4 consumer sites), possibly `compiler/tools/mcp.mdk:256` (drop the
"character is 0; #331" caveat from the tool description). **NOT `typecheck.mdk`** (§1.4 disproof).
**NOT `ast.mdk`** — the carrier stays in the positions channel for this increment.

**Moves goldens:** YES — LSP `lsp_goldens/b3_sym_def_hl.ndjson` and `b4_inlay.ndjson`
(`diff_compiler_lsp_b3.sh`/`_b4.sh`), MCP `mcp_fixtures` (`diff_compiler_mcp.sh`), plus the
parser.mdk+lsp.mdk own snapshot source (`diff_compiler_snapshot_frontend.sh --bless`). The
`positions` snapshot family does NOT move (renderDeclPos is line-only). Recapture via each
gate's `CAPTURE=1`. **Fixpoint:** parser.mdk is in the self-compile graph, but the new field
is display-only (no codegen feed) and S-expr-invisible → fixpoint re-validates byte-identical,
**no seed re-mint expected** (same profile as RESOLVER doc's `DUse`/`TyCon` loc adds, which
were zero-re-mint). Decisive gate: `diff_compiler_lsp_b3.sh` + `selfcompile_fixpoint.sh`.

**Model tier:** **Sonnet** — mechanical, well-scoped, mirrors existing `locOfSpan`/`DUse`-loc
patterns; the only judgment is the per-decl-kind name-token table (enumerable from
`symbolPartsOfDecl`/`declDefines`).

---

### Increment 2 — child-NAME spans (variant ctors, record fields, interface/impl methods, let-binds)

**Goal.** Close G2: each child symbol in the outline gets its own name `Loc`, so
document-outline addresses individual methods/variants and blast-radius (#851) can point at them.

**Mechanism.** This is the first increment that genuinely wants spans **in the AST**, because
children are nested inside the decl and have no line-channel entry. Add `Option Loc` name
fields to the child-bearing AST nodes — `Variant`, record field, `IfaceMethod`, `ImplMethod`,
`LetBind` — captured in the parser at the point each child name is parsed (the parser is *at*
the token, exactly as `TyCon`/`DUse` capture). Make all `*Sexp` serializers ignore the fields
(the settled RESOLVER-doc idiom) so desugar/mark/resolve goldens stay byte-identical.
`symbolPartsOfDecl` (`lsp.mdk:413-441`) then emits each `jChild` with the child's own range
instead of the shared parent `range`.

**Files touched:** `compiler/frontend/ast.mdk` (child-node fields), `compiler/frontend/parser.mdk`
(capture), every `*Sexp` serializer (`compiler/ir/sexp.mdk` etc.) to add ignoring `_`,
`compiler/tools/lsp.mdk` (`symbolPartsOfDecl`). **Broad but mechanical** — the compiler flags
every construction site missing the new field. Likely touches `resolve.mdk`, `eval.mdk`,
`core_ir_lower.mdk`, `printer.mdk`, `lint.mdk` as `_`-sites (the ~40-site profile the RESOLVER
doc's Chunk A actually hit). **Does it touch typecheck.mdk?** Only as a `_`-pattern site if
typecheck matches on `Variant`/`IfaceMethod`/`ImplMethod`/`LetBind` shape — verify with a grep
before scheduling; if it does, this is where the concurrent-refactor sequencing note bites
(see §5). It does NOT add logic to typecheck.

**Moves goldens:** LSP/MCP outline goldens; snapshot source of every edited file. AST-shape
snapshots (desugar/mark/resolve) stay byte-identical via serializer-invisibility — VERIFY that
claim per gate, it is the whole safety argument. Fixpoint: display-only → no re-mint expected.

**Model tier:** **Opus** — the field additions ripple through many shape-matchers and the
"serializer stays byte-identical" invariant must be actively protected (a positional match that
starts matching the new field is a silent bug — the exact hazard RESOLVER-doc Fork 1 names).

---

### Increment 3 — unify the parse entry points (I6)

**Goal.** Close G5: one tooling parse that always yields real expression `ELoc`s AND real
decl/child name spans, so no caller silently gets placeholders.

**Mechanism.** Make the primed path (`parseWithPositionsLocated`, which sets `setLocState`) the
default the LSP/MCP handlers call, and either retire `parseWithPositionsOpt`'s unprimed variant
or make it prime loc-state unconditionally (the extra tokenize pass is linear — `parser.mdk:3705`
comment). Audit `symbols`/`definition`/`inlayHint`/`hover`/`type_at` call sites so all use the
primed entry.

**Files touched:** `parser.mdk`, `tools/lsp.mdk`, `tools/mcp.mdk`. **Moves goldens:** possibly
LSP goldens if any sub-expression range changes from placeholder→real (that is the fix). Model
tier: **Sonnet**.

---

### Increment 4 — retire the line-only name path; `declNameLoc` as the single truth (I1/I3)

**Goal.** Close G3/G4 conceptually: the decl **name** carrier moves from the `Positions`
side-channel into an AST decl-node `Option Loc` field (or a single `declNameLoc : Decl ->
Option Loc` backed by such fields), matching how expressions and type leaves already work. The
`Positions` channel **remains** for its genuinely line-level fmt/doc/codemod duties (variant
lines, chain lines, last-content line) — those are not "locations" and correctly stay
line-granular; only the *name span* leaves the channel.

**Files touched:** `ast.mdk` (decl-node name-`Loc` field — the same additive shape as `DUse`'s
inline `Loc`), `parser.mdk`, `lsp.mdk`, the `*Sexp` files as `_`-sites. This is the increment
where `typecheck.mdk` is *most likely* to appear — as a `_`-pattern site if it matches decl
shapes — but still adds no logic. **Moves goldens:** snapshot source of edited files;
AST-shape goldens byte-identical via serializer-invisibility. Model tier: **Opus**.

---

### Increment 5 — close #414 (parametric impl head) + references/rename substrate (#254)

**Goal.** Close G6 and light up references/rename. With every name-bearing site carrying a
precise `Loc` (uses via `ELoc`, defs via the name fields), `impl Foo a` gains a head span
(point at the `impl` keyword or the interface name when no `TyCon` leaf exists — the RESOLVER
doc's `TyVar`-span alternative, now cheap because the convention is universal), and a
references/rename feature has a complete def+use span map.

**Files touched:** `typecheck.mdk` (`implHeadLoc`/`tyFirstLoc`, `:9362-9370` — this one DOES
change logic, to consult the new impl-head span), `lsp.mdk` (new `references`/`rename`
handlers — see the `add-lsp-capability` skill). **Moves goldens:** typecheck error fixtures
(`overlapping_impls.mdk`), new LSP goldens. Model tier: **Opus**. This is the increment that
genuinely needs the concurrent typecheck refactor to have settled (§5).

---

## 5. `typecheck.mdk` contact points (sequencing note, NOT a design constraint)

A concurrent session is refactoring `compiler/types/typecheck.mdk`. Per the corrected brief
this is a **sequencing** concern, not an architectural one. Where the plan meets typecheck:

- **Increment 1 (#331): ZERO contact.** typecheck.mdk does not use `DeclPos` (§1.4 — the only
  mention at `:9356` is a comment). #331 lands entirely in `parser.mdk` + `lsp.mdk`. It can
  proceed in parallel with the typecheck refactor with no collision.
- **Increments 2 & 4: possible `_`-SITE contact only.** If typecheck pattern-matches on
  `Variant`/`IfaceMethod`/`ImplMethod`/`LetBind` (increment 2) or the decl nodes (increment 4),
  the new `Option Loc` fields force a mechanical `_` at those match sites — **no logic change**.
  This is a snapshot-golden and merge-ordering concern (a whole-file snapshot render always
  conflicts — memory note), resolved by sequencing after the refactor lands or by rebasing and
  regenerating the snapshot (never hand-merging it). GREP the actual match sites before
  scheduling to know if contact even occurs.
- **Increment 5: genuine LOGIC contact.** `implHeadLoc`/`tyFirstLoc` (`typecheck.mdk:9362-9370`)
  change to consult the new impl-head span. Schedule this **after** the concurrent refactor
  settles.

**The target architecture is reachable without churning `typecheck.mdk`'s logic** up through
Increment 4 (only `_`-site touches, if any). typecheck-logic contact is confined to Increment 5
(the #414/rename close-out), which is genuinely last and genuinely wants the refactor done.

---

## 6. Design forks — need a human (Val) decision

**F1 — `Loc` reused vs a new `Span` type.** REC: **reuse `Loc`.** The three existing docs,
`ELoc`, `TyCon`, `DUse`, and all diagnostics already speak `Loc`; a new `Span` forks the
convergence. Dissent worth naming: `Loc` carries a `file : String` that is often `""` for
in-tree spans (the multi-module `Loc.file == ""` wart the RESOLVER doc's Chunk B hit) — a
`Span` without a file could be cleaner, but the migration cost across every existing `Loc`
consumer is not worth it. **Tradeoff:** reuse = zero new type surface, inherits the `file==""`
wart; new type = cleaner semantics, forks the ecosystem. REC reuse.

**F2 — name-span CARRIER: AST node field vs the out-of-band `Positions` channel.** REC:
**channel for #331 (increment 1), migrate to AST field by increment 4.** The RESOLVER doc's
Fork 1 settled that spans belong *on the node* (a line-only/out-of-band scheme silently defeats
shape-matches and desyncs). But #331 can ship correctly via an additive channel field with zero
AST ripple, buying the fix now; the principled AST-field end state follows once child spans
(increment 2) have already forced the AST work. **Tradeoff:** channel-first = fast, low-risk
#331, but leaves a transient two-carrier state; AST-first = principled immediately, but a much
larger increment 1 that collides with more files (incl. likely typecheck `_`-sites) up front.
REC channel-first, converge to field. **Val may prefer AST-first if she wants #331 to *be* the
architecture in one shot.**

**F3 — decl name span EXTENT: name-token only vs whole-name-with-params.** For `foo x y = …`,
should the selectionRange be `foo` or `foo x y`? LSP `selectionRange` wants the **name only**
(`foo`), with the whole-decl line range as the enclosing `range`. REC: **name-token only.**

**F4 — `impl` head target (no single name).** Point the impl symbol/selectionRange at (a) the
head `TyCon`'s existing `Loc`, (b) the `impl` keyword, or (c) the interface name. REC: **(a)
head `TyCon`** (reuses `tyFirstLoc`, consistent with `implHeadLoc`), falling back to the `impl`
keyword for the fully-parametric `impl Foo a` case (which also closes #414 in increment 5).

**F5 — retire `columnAfterName` or keep as fallback?** Once increment 1 gives inlay hints a
real name `Loc`, the col-0 heuristic is dead code. REC: **retire it** (delete `columnAfterName`
+ `identRunLen` + `offsetOfLineStart` if unused elsewhere — grep first).

---

## 7. A-vs-B verdict for #331

**Verdict: A (parser-authoritative), decisively — but a refined A, not the orchestrator's
sketch.** B (generalize `columnAfterName` in `lsp.mdk`) is rejected.

**Why A over B:**
- **B cannot identify the name token from source text alone.** `columnAfterName` already proves
  this: it assumes a col-0 leading identifier and silently misplaces on `public`/`export`
  prefixes, indented methods, operators, and `data`/`impl` heads (§1.5). A source-scan
  generalization would have to *re-lex and re-parse* enough structure to find the name per decl
  kind — i.e. reimplement the parser, in the LSP, heuristically. That is strictly more code than
  A and permanently throwaway.
- **A already has the name token in hand.** The parser knows each decl's kind and is positioned
  at its name token as it builds the node; `declNameSpanOf` scans a handful of known leading
  keyword tokens (not source characters) to the name-role token and mints its `Loc` via the
  **existing** `locOfSpan`/`offsetToLineColFast` service. No lexer change, no new offset
  machinery — the offsets are already produced by `tokenizeWithOffsetPairs`.
- **A composes toward the target; B fights it.** A's `declNameSpanOf` IS the target's
  `declNameLoc` logic — increments 2/4 migrate only its *carrier* (channel → AST field), never
  its logic. B would be deleted wholesale at increment 4 and contributes nothing reusable.
- **A is `Loc`-native.** It produces the same `Loc` type expressions and type leaves already
  use, satisfying I1/I3 on day one. B produces an ad-hoc column int in the LSP, off-convention.

**Refinement over the orchestrator's A-sketch:** the sketch proposed "thread a `cols` array
alongside `lines`." That is unnecessary — the offset arrays already exist
(`tokenizeWithOffsetPairs`) and `offsetToLineColFast` already turns any token offset into a
column. #331 needs a **name-token finder**, not a new parallel column array. Build
`declNameSpanOf` (returns a full `Loc`) and store it additively in the channel; skip the
`cols` array entirely.

---

## 8. Friction report

- **The orchestrator's headline typecheck hypothesis is FALSE.** "A `DeclPos` side-table in
  `typecheck.mdk:9356`" does not exist — line 9356 is a **comment** in the `implHeadLoc`/#414
  doc block; typecheck.mdk imports/uses no `DeclPos`. The grep that listed `types/typecheck.mdk`
  as a "consumer" matched that comment. **#331 needs no typecheck edit.** (This also means the
  original HARD CONSTRAINT in the brief was chasing a phantom collision.)
- **The orchestrator's `offsetToLineCol` and `ELoc` hypotheses are CORRECT and stronger than
  stated.** Not only does `offsetToLineCol` exist (`lexer.mdk:2075`), there is a full
  col-precise decl-span pipeline already built for expressions (`locOfSpan`/`setLocState`/
  `offsetToLineColFast`) that the decl layer simply never adopted. The fix is smaller than "A"
  implies — no `cols` array needed (§7 refinement).
- **No umbrella position spec exists; three point-fix docs silently share one convention.**
  `PARSE-ERROR-LOCATION-DESIGN.md`, `RESOLVER-DIAG-LOCATION-DESIGN.md`, `TYPE-ERROR-SPAN-DESIGN.md`
  each solve one diagnostic and never cross-reference a shared model, though all three landed on
  `Loc`-as-a-node-field. This design names that convention explicitly for the first time. Worth
  promoting to a real `docs/spec/` or `compiler/*DESIGN*` entry once decided.
- **Bigger latent gap than #331 names:** child symbols (variant ctors, record fields, interface/
  impl methods, let-binds) have **no position at all** — they reuse the parent decl's range
  (`lsp.mdk:429/433`). #331 as filed only mentions the decl name; the outline/nav story
  (#850/#851) needs the child spans (increment 2), which #331 does not cover. Flagging so the
  issue scope is not mistaken for complete after increment 1.
- **`columnAfterName` is a live throwaway heuristic** (`lsp.mdk:869`) already misplacing inlay
  hints on prefixed/indented/operator decls — a small pre-existing correctness wart that
  increment 1 incidentally fixes.
- **Two positions entry points with different fidelity and no type-level distinction**
  (`parseWithPositionsOpt` gives placeholder `ELoc`s; `parseWithPositionsLocated` gives real
  ones) already caused a lint bug (#649). A footgun until increment 3 unifies them.
- **Stale-comment nuance:** `TYPE-ERROR-SPAN-DESIGN.md`'s header and `PARSE-ERROR-LOCATION-DESIGN.md`'s
  header both note their own "Status:" lines never flipped to SHIPPED despite the fixes landing —
  consistent with the memory note that status banners rot. Trust the in-source "Bite N"/"Chunk N"
  AS-BUILT sections over the headers.
