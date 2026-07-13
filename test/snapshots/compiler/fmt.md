# META
source_lines=487
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted comment-preserving formatter — port of lib/printer.ml's
-- `format_program` (the tail half of the printer, NOT covered by
-- compiler/printer.mdk's comment-FREE `programToString` core).
--
-- Walks the top-level declarations in source order, interleaving the lexer's
-- captured comment side-channel (compiler/lexer.mdk `collectComments` →
-- `Comment line col text`) at their original positions, using the parser's
-- position side-channel (compiler/parser.mdk `parseWithPositions` →
-- `Positions`: per-decl `(line, end_line)`, flat `data`-variant start lines,
-- and `last_content_line`).
--
-- Mirrors `format_program` byte-for-byte:
--   * leading comments (`c_line < loc.line`) flush as standalone lines, with a
--     blank-line gap when `target_line - cursor >= 2`;
--   * a single-line comment on `loc.end_line` is a TRAILING comment rendered
--     inline after the decl (`"  " ++ text`);
--   * a `DData` decl consumes its variants' source lines so an interior comment
--     anchors before the variant it precedes (`printDataDeclCommented`);
--   * a final `flush_before` (last_content_line + 1, i.e. drain-all) emits the
--     remaining trailing comments.
--
-- Pure state threading (no refs): the OCaml `ref` cell quartet
-- (cs / vlines / cursor / started) plus the output Buffer is carried as an
-- explicit `FmtState pieces cs vlines cursor started` and the output pieces are
-- accumulated reversed, then concatenated once at the end.

import frontend.ast.{DataVis(..), Variant(..), ConPayload(..), Decl(..)}
import tools.printer.{
  render,
  printDecl,
  printDataDeclCommented,
  printNamedFieldData,
  printDeclChainCommented,
  declChainLen,
  printDeclBlockCommented,
  declBlockLen,
  Doc,
}
import frontend.lexer.{Comment, commentLine, commentText, collectComments}
import frontend.parser.{
  parseWithPositions,
  Positions,
  DeclPos,
  positionsDecls,
  positionsVariantLines,
  positionsLastContentLine,
  positionsChainLines,
  declPosLine,
  declPosEndLine,
}
import support.util.{
  listLen,
  reverseL,
  isEmptyL,
  isNonEmptyL,
  filterList,
  splitNl,
  joinNl,
  allList,
}

-- ── State ─────────────────────────────────────────
-- pieces : output fragments, REVERSED (cons-prepend, reverse+concat at end)
-- cs     : remaining captured comments, source order
-- vlines : remaining `data`-variant start lines, decl order
-- cursor : last consumed source line
-- started: whether any output has been emitted (gates the blank-line rule)
data FmtState = FmtState (List String) (List Comment) (List Int) Int Bool

-- ── String helpers (prelude-only; mirror lib/printer.ml's OCaml idioms) ──

-- Count '\n' in a comment lexeme — a multi-line block comment advances the
-- cursor by that many lines (OCaml: String.fold_left counting '\n').
countNl : String -> Int
countNl s = countNlChars (stringToChars s) 0 (arrayLength (stringToChars s)) 0

countNlChars : Array Char -> Int -> Int -> Int -> Int
countNlChars src i n acc
  | i >= n = acc
  | charAt src i == '\n' = countNlChars src (i + 1) n (acc + 1)
  | otherwise = countNlChars src (i + 1) n acc

charAt : Array Char -> Int -> Char
charAt src i = arrayGetUnsafe i src

-- True iff the lexeme is single-line (no embedded '\n'); a trailing comment
-- must be single-line (OCaml: `not (String.contains c.c_text '\n')`).
isSingleLine : String -> Bool
isSingleLine s = countNl s == 0

-- ── Blank-line / comment emission ─────────────────

-- Prepend a blank line when started and the gap to `targetLine` is >= 2
-- (OCaml `blank_line_if_needed`).  Returns the (possibly extended) pieces.
blankLineIfNeeded : List String -> Int -> Int -> Bool -> List String
blankLineIfNeeded pieces targetLine cursor started =
  if started && targetLine - cursor >= 2 then
    "\n"::pieces
  else
    pieces

-- Emit one standalone comment (OCaml `emit_comment`): blank-line gate, then
-- the lexeme + newline; advance cursor past any embedded newlines; mark started.
emitComment : FmtState -> Comment -> FmtState
emitComment (FmtState pieces cs vlines cursor started) c =
  let pieces1 = blankLineIfNeeded pieces (commentLine c) cursor started
  let pieces2 = "\n" :: commentText c :: pieces1
  let nls = countNl (commentText c)
  FmtState pieces2 cs vlines (commentLine c + nls) True

-- Emit all pending comments strictly above `line` (OCaml `flush_before`).
flushBefore : FmtState -> Int -> FmtState
flushBefore (FmtState pieces [] vlines cursor started) _ =
  FmtState pieces [] vlines cursor started
flushBefore (FmtState pieces (c::rest) vlines cursor started) line =
  if commentLine c < line then
    flushBefore (emitComment (FmtState pieces rest vlines cursor started) c) line
  else
    FmtState pieces (c::rest) vlines cursor started

-- ── Variant-line + interior-comment bucketing (DData) ─────

-- Take the next k variant start lines off `vlines` (OCaml `take_n_variant_lines`).
takeNVariantLines : List Int -> Int -> (List Int, List Int)
takeNVariantLines vlines k = takeNVarGo vlines k []

takeNVarGo : List Int -> Int -> List Int -> (List Int, List Int)
takeNVarGo vlines k acc
  | k <= 0 = (vlines, reverseL acc)
  | otherwise = match vlines
    [] => (vlines, reverseL acc)
    x::rest => takeNVarGo rest (k - 1) (x::acc)

-- Pop (WITHOUT emitting) the pending comments strictly above `line`, returning
-- their lexemes in source order plus the leftover comment stream (OCaml
-- `take_before`).  Used to bucket interior comments onto the variant they precede.
takeBefore : List Comment -> Int -> (List String, List Comment)
takeBefore cs line = takeBeforeGo cs line []

takeBeforeGo : List Comment -> Int -> List String -> (List String, List Comment)
takeBeforeGo [] _ acc = (reverseL acc, [])
takeBeforeGo (c::rest) line acc =
  if commentLine c < line then
    takeBeforeGo rest line (commentText c :: acc)
  else
    (reverseL acc, c::rest)

-- Pop the single-line comments ON `line` (a variant's TRAILING comments, e.g.
-- `| Field String  -- .foo`).  Without this they leak into the NEXT variant's
-- `takeBefore` bucket and get re-rendered as a leading comment on their own line.
takeSameLine : List Comment -> Int -> (List String, List Comment)
takeSameLine [] _ = ([], [])
takeSameLine (c::rest) line =
  if commentLine c == line && isSingleLine (commentText c) then match takeSameLine rest line
    (more, leftover) => (commentText c :: more, leftover)
  else ([], c::rest)

-- For each variant line, pop its preceding (leading) comments AND its same-line
-- (trailing) comments.  Returns per-variant (leading, trailing) lexeme lists
-- (parallel to vls) and the leftover stream.
vcommentsFor : List Comment -> List Int -> (List (List String, List String), List Comment)
vcommentsFor cs [] = ([], cs)
vcommentsFor cs (l::ls) = match takeBefore cs l
  (leading, rest1) => match takeSameLine rest1 l
    (trailing, rest2) => match vcommentsFor rest2 ls
      (more, leftover) => ((leading, trailing)::more, leftover)

allEmptyPairs : List (List String, List String) -> Bool
allEmptyPairs [] = True
allEmptyPairs ((ld, tr)::xs) = isEmptyL ld && isEmptyL tr && allEmptyPairs xs

-- ── Per-declaration rendering ─────────────────────

-- Render one declaration's Doc, consuming variant lines for a DData (always, to
-- keep vlines aligned) and interleaving any interior comment before the variant
-- it documents.  Other decls render opaquely.  Mirror of OCaml `decl_doc`.
-- Returns (renderedString, newState) — the Doc is rendered here so the comment
-- pops are threaded back into the state.
declDoc : FmtState -> Decl -> (String, FmtState)
declDoc (FmtState pieces cs vlines cursor started) (DData vis n params variants derives) = match takeNVariantLines vlines (listLen variants)
  (vlinesRest, vls) => match vcommentsFor cs vls
    (vcomments, csRest) =>
      if listLen vcomments == listLen variants && not (allEmptyPairs vcomments) then
        (
          render (printDataDeclCommented vis n params variants derives vcomments),
          FmtState pieces csRest vlinesRest cursor started,
        )
      else
        (
          render (printDecl (DData vis n params variants derives)),
          FmtState pieces cs vlinesRest cursor started,
        )
declDoc st decl = (render (printDecl decl), st)

-- ── Trailing comments ─────────────────────────────

-- A comment on the decl's final source line, single-line, is trailing: pull it
-- out of the pending stream so it renders inline.  Order-preserving partition.
-- Mirror of OCaml `take_trailing`.
isTrailing : Int -> Comment -> Bool
isTrailing endLine c = commentLine c == endLine && isSingleLine (commentText c)

takeTrailing : List Comment -> Int -> (List Comment, List Comment)
takeTrailing cs endLine = (
  filterList (isTrailing endLine) cs,
  filterList (c => not (isTrailing endLine c)) cs,
)

-- Append the inline trailing comments after the decl text.
appendTrailing : List String -> List Comment -> List String
appendTrailing pieces [] = pieces
appendTrailing pieces (c::cs) =
  appendTrailing (commentText c :: "  "::pieces) cs

-- ── Interior (inner-block) trailing comments ──────────────────────────────
-- A single-line comment on a source line strictly *inside* a multi-line decl
-- body (line < c.line < end_line) trails an INNER statement (e.g. each
-- `println …  -- note` line of a bare indented block), not the decl as a whole.
-- The decl-granular `takeTrailing` only catches the comment on `end_line`, so
-- the earlier ones used to escape to `drainAll` and flush *below* the decl. We
-- instead splice each one back inline onto the rendered output line that
-- originated at its source line.
--
-- The decl renders one output line per source line (statements keep their
-- source line breaks), so output-line index = c.line - decl.line maps a source
-- line to its rendered line.  We attach `"  " ++ text` to that output line; a
-- comment whose index is out of range (a reflowed/wrapped statement, rare) is
-- left in the stream so `drainAll` still emits it rather than dropping it.

isInterior : Int -> Int -> Comment -> Bool
isInterior startLine endLine c =
  let l = commentLine c
  l > startLine && l < endLine && isSingleLine (commentText c)

-- DData (incl. an attribute-wrapped one) routes interior comments through
-- vcommentsFor, not the generic inline splice.
isDataDeclF : Decl -> Bool
isDataDeclF (DData _ _ _ _ _) = True
isDataDeclF (DAttrib _ inner) = isDataDeclF inner
isDataDeclF _ = False

-- A single-variant record-style data decl (`data X = X { f : T, ... }`).  Its
-- per-field trailing comments cannot be carried by the per-VARIANT vcommentsFor
-- machinery (one variant, many field comments), and the flat one-line render
-- gives them no line to attach to — so when such a decl carries field comments
-- we render it one-field-per-line (printNamedFieldData) and route the comments
-- through the generic interior splice instead (see stepDecl).  Only the bare
-- (non-attribute-wrapped) shape, to avoid dropping `@attr` annotations.
isSingleNamedFieldData : Decl -> Bool
isSingleNamedFieldData (DData _ _ _ [Variant _ (ConNamed _ _)] _) = True
isSingleNamedFieldData _ = False

-- Render a single-variant named-field data decl one-field-per-line, consuming its
-- one variant line (to keep vlines aligned, exactly as declDoc's DData arm does).
renderNamedFieldMulti : FmtState -> Decl -> (String, FmtState)
renderNamedFieldMulti (FmtState pieces cs vlines cursor started) (DData vis n params variants derives) = match takeNVariantLines vlines 1
  (vlinesRest, _) => (
    render (printNamedFieldData vis n params variants derives),
    FmtState pieces cs vlinesRest cursor started,
  )
renderNamedFieldMulti st decl = declDoc st decl

-- Splice interior comments into the rendered decl string by output-line index.
-- Returns (newDeclStr, consumedComments) — consumed ones are removed from the
-- pending stream; any whose index fell out of range are NOT consumed.
spliceInterior : String -> Int -> List Comment -> (String, List Comment)
spliceInterior declStr startLine interior =
  let outLines = splitNl declStr
  let n = listLen outLines
  match attachInterior outLines startLine 0 n interior []
    (newLines, consumed) => (joinNl newLines, reverseL consumed)

-- Walk the output lines, prepending each comment's inline text onto the line at
-- its index.  `idx` is the current output-line index; `consumed` accumulates
-- (reversed) the comments actually attached.
attachInterior : List String -> Int -> Int -> Int -> List Comment -> List Comment -> (List String, List Comment)
attachInterior [] _ _ _ _ consumed = ([], consumed)
attachInterior (ln::rest) startLine idx n interior consumed = match attachOnLine ln startLine idx interior consumed
  (ln1, consumed1) => match attachInterior rest startLine (idx + 1) n interior consumed1
    (rest1, consumed2) => (ln1::rest1, consumed2)

-- Attach every interior comment whose output-line index == idx onto `ln`.
attachOnLine : String -> Int -> Int -> List Comment -> List Comment -> (String, List Comment)
attachOnLine ln _ _ [] consumed = (ln, consumed)
attachOnLine ln startLine idx (c::cs) consumed =
  if commentLine c - startLine == idx then match attachOnLine ln startLine idx cs consumed
    (ln1, consumed1) => ("\{ln1}  \{commentText c}", c::consumed1)
  else attachOnLine ln startLine idx cs consumed

-- Drop the consumed comments from the pending stream (order-preserving), by
-- source line — interior comment lines are unique per output line.
dropConsumed : List Comment -> List Comment -> List Comment
dropConsumed cs consumed =
  filterList (c => not (anyLineEq (commentLine c) consumed)) cs

anyLineEq : Int -> List Comment -> Bool
anyLineEq _ [] = False
anyLineEq l (c::cs) = if commentLine c == l then True else anyLineEq l cs

-- ── Comment-interleaved continuation chains (finding "L") ──────────────────
-- A continuation-op chain RHS (`||`/`&&`/`++`/…) whose operands carry trailing
-- comments is formatted with each comment anchored to ITS operand's Doc (via
-- printer.LineComment), so reflow can't shift a comment to the wrong operand —
-- superseding the verbatim safety-net for this (the finding-"L") shape.  The
-- parser's per-decl chain operand-line side-channel (`positionsChainLines`)
-- lines the operands up with the comments; we take this path only when every
-- comment in the decl's span anchors cleanly (else fall back to verbatim).

intInList : Int -> List Int -> Bool
intInList _ [] = False
intInList x (y::ys) = if x == y then True else intInList x ys

-- The single-line comment sitting on source line `l`, if any.
commentOnLine : List Comment -> Int -> Option String
commentOnLine [] _ = None
commentOnLine (c::cs) l =
  if commentLine c == l && isSingleLine (commentText c) then
    Some (commentText c)
  else
    commentOnLine cs l

-- Comments belonging to this decl's source span [lo, hi] (flushBefore has
-- already drained everything strictly before `lo`).
spanComments : List Comment -> Int -> Int -> List Comment
spanComments cs lo hi =
  filterList (c => commentLine c >= lo && commentLine c <= hi) cs

-- Can EVERY comment in the decl's span be anchored to a chain operand line?
-- (each single-line AND on an operand line).  If not, keep the verbatim net so
-- no comment is dropped or misplaced.
chainCoversAll : List Comment -> Int -> Int -> List Int -> Bool
chainCoversAll cs lo hi ols = allList
  (c => isSingleLine (commentText c) && intInList (commentLine c) ols)
  (spanComments cs lo hi)

-- ── Verbatim safety-net (Option C) ────────────────────────────────────────
-- When a declaration carries an INTERIOR trailing comment (a single-line
-- comment strictly between its start and end line — see `isInterior`), the
-- comment-free Doc engine (printer.mdk) may REFLOW the body by width, so the
-- source-line→output-line index map that `spliceInterior` relies on no longer
-- holds and comments drift to the wrong operand (finding "L").  Rather than
-- risk misplacement, we emit that decl's ORIGINAL source lines verbatim, so a
-- hand-laid-out commented body keeps its exact layout and no comment is ever
-- moved or merged.  Data decls are EXCLUDED — their interior comments are
-- placed per-variant/per-field by `printDataDeclCommented`/`printNamedFieldData`
-- (a path that IS reflow-safe), so they keep formatting normally.
-- Conservative by design: any non-data decl with >=1 interior comment goes
-- verbatim, even in cases the old splice happened to get right.

-- Extract source lines [startLine .. endLine] (1-based, inclusive) and rejoin
-- them exactly — the decl's original text, comments and all.
verbatimSpan : List String -> Int -> Int -> String
verbatimSpan srcLines startLine endLine =
  joinNl (spanLines srcLines 1 startLine endLine)

spanLines : List String -> Int -> Int -> Int -> List String
spanLines [] _ _ _ = []
spanLines (l::ls) idx startLine endLine
  | idx > endLine = []
  | idx >= startLine = l :: spanLines ls (idx + 1) startLine endLine
  | otherwise = spanLines ls (idx + 1) startLine endLine

-- ── Main walk ─────────────────────────────────────

-- Process one (decl, declPos) pair.  Mirror of one OCaml `List.iter2` body.
stepDecl : FmtState -> List String -> List Int -> Decl -> DeclPos -> FmtState
stepDecl st srcLines chainOls decl dp =
  let line = declPosLine dp
  let endLine = declPosEndLine dp
  let st1 = flushBefore st line
  match st1
    FmtState pieces1 cs1 vlines1 cursor1 started1 =>
      let pieces2 = blankLineIfNeeded pieces1 line cursor1 started1
      let hasInterior = isNonEmptyL (filterList (isInterior line endLine) cs1)
      -- Continuation-chain path (finding "L"): interleave each operand's
      -- trailing comment via printer.LineComment, IF the decl is a chain whose
      -- operand count matches the AST and every span comment anchors cleanly.
      let useChain = hasInterior
        && isNonEmptyL chainOls
        && declChainLen decl == listLen chainOls
        && chainCoversAll cs1 line endLine chainOls
      -- Block/do path (Stage 5): interleave each statement's trailing comment,
      -- IF the decl is a bare/do-block whose statement count matches the AST and
      -- every span comment anchors to a statement line.  (chainOls carries the
      -- statement lines for a block-bodied decl.)
      let useBlock = hasInterior
        && not useChain
        && isNonEmptyL chainOls
        && declBlockLen decl == listLen chainOls
        && chainCoversAll cs1 line endLine chainOls
      -- Verbatim safety-net: a non-data decl with an interior trailing comment
      -- keeps its original source text (reflow would misplace the comment).
      let useVerbatim = hasInterior && not (isDataDeclF decl)
      let st2 = FmtState pieces2 cs1 vlines1 cursor1 started1
      if useChain then
        -- One trailing comment per operand (in collectChain order); the parser's
        -- operand lines are in the same order, so map by line.
        let perOp = map (ol => commentOnLine cs1 ol) chainOls
        let declStr = render (printDeclChainCommented decl perOp)
        -- Every span comment was placed inline; drain the decl's prefix.
        let csRest = filterList (c => commentLine c > endLine) cs1
        let pieces3 = "\n" :: declStr :: pieces2
        FmtState pieces3 csRest vlines1 endLine True
      else if useBlock then
        -- One trailing comment per statement (source order == parser line order).
        let perStmt = map (ol => commentOnLine cs1 ol) chainOls
        let declStr = render (printDeclBlockCommented decl perStmt)
        let csRest = filterList (c => commentLine c > endLine) cs1
        let pieces3 = "\n" :: declStr :: pieces2
        FmtState pieces3 csRest vlines1 endLine True
      else if useVerbatim then
        -- The verbatim span [line .. endLine] already contains every comment on
        -- those lines, so consume the whole decl's pending comment prefix
        -- (flushBefore already drained everything strictly before `line`).
        let csRest = filterList (c => commentLine c > endLine) cs1
        let pieces3 = "\n" :: verbatimSpan srcLines line endLine :: pieces2
        FmtState pieces3 csRest vlines1 endLine True
      else
        stepDeclNormal st2 decl line endLine

-- The normal (reflowing) path: render the decl's Doc, splice interior comments
-- by output-line index, and append end-line trailing comments inline.  Used for
-- every decl WITHOUT an interior trailing comment (see stepDecl's safety-net).
stepDeclNormal : FmtState -> Decl -> Int -> Int -> FmtState
stepDeclNormal (FmtState pieces2 cs1 vlines1 cursor1 started1) decl line endLine =
  -- A single-variant named-field data decl that carries field comments is
  -- rendered one-field-per-line and routed through the generic interior
  -- splice (the per-variant vcommentsFor path cannot attach per-field
  -- comments).  Other data decls keep the vcommentsFor path.
  let nfMulti = isSingleNamedFieldData decl && isNonEmptyL (filterList (isInterior line endLine) cs1)
  let st2 = FmtState pieces2 cs1 vlines1 cursor1 started1
  match (if nfMulti then renderNamedFieldMulti st2 decl else declDoc st2 decl)
    (declStr0, (FmtState pieces3 cs3 vlines3 _cursor3 _started3)) =>
      -- DData has its own interior-comment machinery (vcommentsFor); leave
      -- its comments to that path.  Every other decl (and a commented
      -- named-field data decl, nfMulti) interleaves inner-block trailing
      -- comments inline.
      let interior = if isDataDeclF decl && not nfMulti then [] else filterList (isInterior line endLine) cs3
      match spliceInterior declStr0 line interior
        (declStr, consumed) =>
          let cs3b = dropConsumed cs3 consumed
          match takeTrailing cs3b endLine
            (trailing, csRest) =>
              let pieces4 = appendTrailing (declStr :: pieces3) trailing
              FmtState ("\n" :: pieces4) csRest vlines3 endLine True
-- (1) flush_before loc.line, (2) blank-line gate, (3) render decl (consumes
-- variant lines + interior comments), (4) splice inner-block trailing comments
-- back inline, (5) end-line inline trailing comment(s),
-- (6) newline + advance cursor to end_line + started := true.

-- Threads the per-decl chain operand-line side-channel (`cls`) in lockstep with
-- the decls; a decl with no entry (list exhausted) gets `[]` (non-chain).
walkDecls : FmtState -> List String -> List Decl -> List DeclPos -> List (List Int) -> FmtState
walkDecls st _ [] _ _ = st
walkDecls st _ _ [] _ = st
walkDecls st srcLines (d::ds) (p::ps) [] =
  walkDecls (stepDecl st srcLines [] d p) srcLines ds ps []
walkDecls st srcLines (d::ds) (p::ps) (c::rest) =
  walkDecls (stepDecl st srcLines c d p) srcLines ds ps rest

-- ── Public entry ──────────────────────────────────

-- format_program: interleave comments into the rendered program.  If the decl
-- position list and the decl list differ in length, fall back to the plain
-- comment-free `programToString`-equivalent (render each decl + "\n").  Mirror
-- of lib/printer.ml's length guard.
export formatProgram : List Decl -> List DeclPos -> List Int -> List (List Int) -> List Comment -> Int -> String -> String
formatProgram decls declPositions variantLines chainLines comments _lastContentLine src =
  if listLen declPositions != listLen decls then stringConcat (map (d => render (printDecl d) ++ "\n") decls)
  else
    let st0 = FmtState [] comments variantLines 0 False
    match drainAll (walkDecls st0 (splitNl src) decls declPositions chainLines)
      FmtState finalPieces _ _ _ _ => stringConcat (reverseL finalPieces)
-- After the walk, the final `flush_before max_int` drains EVERY remaining
-- comment; `drainAll` does that unconditionally (no max_int literal needed).

-- Drain every remaining comment (final `flush_before max_int`).
drainAll : FmtState -> FmtState
drainAll (FmtState pieces [] vlines cursor started) =
  FmtState pieces [] vlines cursor started
drainAll (FmtState pieces (c::rest) vlines cursor started) =
  drainAll (emitComment (FmtState pieces rest vlines cursor started) c)

-- Convenience: parse + collect comments + format, from source text.
export formatSource : String -> String
formatSource src = match parseWithPositions src
  (decls, pos) => formatProgram decls (positionsDecls pos) (positionsVariantLines pos) (positionsChainLines pos) (collectComments src) (positionsLastContentLine pos) src
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "DataVis" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Decl" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "render" false) (mem "printDecl" false) (mem "printDataDeclCommented" false) (mem "printNamedFieldData" false) (mem "printDeclChainCommented" false) (mem "declChainLen" false) (mem "printDeclBlockCommented" false) (mem "declBlockLen" false) (mem "Doc" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "commentLine" false) (mem "commentText" false) (mem "collectComments" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseWithPositions" false) (mem "Positions" false) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "positionsVariantLines" false) (mem "positionsLastContentLine" false) (mem "positionsChainLines" false) (mem "declPosLine" false) (mem "declPosEndLine" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "reverseL" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "filterList" false) (mem "splitNl" false) (mem "joinNl" false) (mem "allList" false))))
(DData Private "FmtState" () ((variant "FmtState" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int") (TyCon "Bool")))) ())
(DTypeSig false "countNl" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "countNl" ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "countNlChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "s")))) (ELit (LInt 0))))
(DTypeSig false "countNlChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "countNlChars" ((PVar "src") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "charAt") (EVar "src")) (EVar "i")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EVar "countNlChars") (EVar "src")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "countNlChars") (EVar "src")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "charAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Char"))))
(DFunDef false "charAt" ((PVar "src") (PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")))
(DTypeSig false "isSingleLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isSingleLine" ((PVar "s")) (EBinOp "==" (EApp (EVar "countNl") (EVar "s")) (ELit (LInt 0))))
(DTypeSig false "blankLineIfNeeded" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "blankLineIfNeeded" ((PVar "pieces") (PVar "targetLine") (PVar "cursor") (PVar "started")) (EIf (EBinOp "&&" (EVar "started") (EBinOp ">=" (EBinOp "-" (EVar "targetLine") (EVar "cursor")) (ELit (LInt 2)))) (EBinOp "::" (ELit (LString "\n")) (EVar "pieces")) (EVar "pieces")))
(DTypeSig false "emitComment" (TyFun (TyCon "FmtState") (TyFun (TyCon "Comment") (TyCon "FmtState"))))
(DFunDef false "emitComment" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started")) (PVar "c")) (EBlock (DoLet false false (PVar "pieces1") (EApp (EApp (EApp (EApp (EVar "blankLineIfNeeded") (EVar "pieces")) (EApp (EVar "commentLine") (EVar "c"))) (EVar "cursor")) (EVar "started"))) (DoLet false false (PVar "pieces2") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EVar "pieces1")))) (DoLet false false (PVar "nls") (EApp (EVar "countNl") (EApp (EVar "commentText") (EVar "c")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "cs")) (EVar "vlines")) (EBinOp "+" (EApp (EVar "commentLine") (EVar "c")) (EVar "nls"))) (EVar "True")))))
(DTypeSig false "flushBefore" (TyFun (TyCon "FmtState") (TyFun (TyCon "Int") (TyCon "FmtState"))))
(DFunDef false "flushBefore" ((PCon "FmtState" (PVar "pieces") (PList) (PVar "vlines") (PVar "cursor") (PVar "started")) PWild) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EListLit)) (EVar "vlines")) (EVar "cursor")) (EVar "started")))
(DFunDef false "flushBefore" ((PCon "FmtState" (PVar "pieces") (PCons (PVar "c") (PVar "rest")) (PVar "vlines") (PVar "cursor") (PVar "started")) (PVar "line")) (EIf (EBinOp "<" (EApp (EVar "commentLine") (EVar "c")) (EVar "line")) (EApp (EApp (EVar "flushBefore") (EApp (EApp (EVar "emitComment") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "rest")) (EVar "vlines")) (EVar "cursor")) (EVar "started"))) (EVar "c"))) (EVar "line")) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EBinOp "::" (EVar "c") (EVar "rest"))) (EVar "vlines")) (EVar "cursor")) (EVar "started"))))
(DTypeSig false "takeNVariantLines" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "takeNVariantLines" ((PVar "vlines") (PVar "k")) (EApp (EApp (EApp (EVar "takeNVarGo") (EVar "vlines")) (EVar "k")) (EListLit)))
(DTypeSig false "takeNVarGo" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "takeNVarGo" ((PVar "vlines") (PVar "k") (PVar "acc")) (EIf (EBinOp "<=" (EVar "k") (ELit (LInt 0))) (ETuple (EVar "vlines") (EApp (EVar "reverseL") (EVar "acc"))) (EIf (EVar "otherwise") (EMatch (EVar "vlines") (arm (PList) () (ETuple (EVar "vlines") (EApp (EVar "reverseL") (EVar "acc")))) (arm (PCons (PVar "x") (PVar "rest")) () (EApp (EApp (EApp (EVar "takeNVarGo") (EVar "rest")) (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EBinOp "::" (EVar "x") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "takeBefore" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "takeBefore" ((PVar "cs") (PVar "line")) (EApp (EApp (EApp (EVar "takeBeforeGo") (EVar "cs")) (EVar "line")) (EListLit)))
(DTypeSig false "takeBeforeGo" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment")))))))
(DFunDef false "takeBeforeGo" ((PList) PWild (PVar "acc")) (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EListLit)))
(DFunDef false "takeBeforeGo" ((PCons (PVar "c") (PVar "rest")) (PVar "line") (PVar "acc")) (EIf (EBinOp "<" (EApp (EVar "commentLine") (EVar "c")) (EVar "line")) (EApp (EApp (EApp (EVar "takeBeforeGo") (EVar "rest")) (EVar "line")) (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EVar "acc"))) (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EBinOp "::" (EVar "c") (EVar "rest")))))
(DTypeSig false "takeSameLine" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "takeSameLine" ((PList) PWild) (ETuple (EListLit) (EListLit)))
(DFunDef false "takeSameLine" ((PCons (PVar "c") (PVar "rest")) (PVar "line")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "line")) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))) (EMatch (EApp (EApp (EVar "takeSameLine") (EVar "rest")) (EVar "line")) (arm (PTuple (PVar "more") (PVar "leftover")) () (ETuple (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EVar "more")) (EVar "leftover")))) (ETuple (EListLit) (EBinOp "::" (EVar "c") (EVar "rest")))))
(DTypeSig false "vcommentsFor" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "vcommentsFor" ((PVar "cs") (PList)) (ETuple (EListLit) (EVar "cs")))
(DFunDef false "vcommentsFor" ((PVar "cs") (PCons (PVar "l") (PVar "ls"))) (EMatch (EApp (EApp (EVar "takeBefore") (EVar "cs")) (EVar "l")) (arm (PTuple (PVar "leading") (PVar "rest1")) () (EMatch (EApp (EApp (EVar "takeSameLine") (EVar "rest1")) (EVar "l")) (arm (PTuple (PVar "trailing") (PVar "rest2")) () (EMatch (EApp (EApp (EVar "vcommentsFor") (EVar "rest2")) (EVar "ls")) (arm (PTuple (PVar "more") (PVar "leftover")) () (ETuple (EBinOp "::" (ETuple (EVar "leading") (EVar "trailing")) (EVar "more")) (EVar "leftover")))))))))
(DTypeSig false "allEmptyPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Bool")))
(DFunDef false "allEmptyPairs" ((PList)) (EVar "True"))
(DFunDef false "allEmptyPairs" ((PCons (PTuple (PVar "ld") (PVar "tr")) (PVar "xs"))) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "ld")) (EApp (EVar "isEmptyL") (EVar "tr"))) (EApp (EVar "allEmptyPairs") (EVar "xs"))))
(DTypeSig false "declDoc" (TyFun (TyCon "FmtState") (TyFun (TyCon "Decl") (TyTuple (TyCon "String") (TyCon "FmtState")))))
(DFunDef false "declDoc" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started")) (PCon "DData" (PVar "vis") (PVar "n") (PVar "params") (PVar "variants") (PVar "derives"))) (EMatch (EApp (EApp (EVar "takeNVariantLines") (EVar "vlines")) (EApp (EVar "listLen") (EVar "variants"))) (arm (PTuple (PVar "vlinesRest") (PVar "vls")) () (EMatch (EApp (EApp (EVar "vcommentsFor") (EVar "cs")) (EVar "vls")) (arm (PTuple (PVar "vcomments") (PVar "csRest")) () (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "vcomments")) (EApp (EVar "listLen") (EVar "variants"))) (EApp (EVar "not") (EApp (EVar "allEmptyPairs") (EVar "vcomments")))) (ETuple (EApp (EVar "render") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "printDataDeclCommented") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "variants")) (EVar "derives")) (EVar "vcomments"))) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "csRest")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started"))) (ETuple (EApp (EVar "render") (EApp (EVar "printDecl") (EApp (EApp (EApp (EApp (EApp (EVar "DData") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "variants")) (EVar "derives")))) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "cs")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started")))))))))
(DFunDef false "declDoc" ((PVar "st") (PVar "decl")) (ETuple (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "decl"))) (EVar "st")))
(DTypeSig false "isTrailing" (TyFun (TyCon "Int") (TyFun (TyCon "Comment") (TyCon "Bool"))))
(DFunDef false "isTrailing" ((PVar "endLine") (PVar "c")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))))
(DTypeSig false "takeTrailing" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "takeTrailing" ((PVar "cs") (PVar "endLine")) (ETuple (EApp (EApp (EVar "filterList") (EApp (EVar "isTrailing") (EVar "endLine"))) (EVar "cs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "isTrailing") (EVar "endLine")) (EVar "c"))))) (EVar "cs"))))
(DTypeSig false "appendTrailing" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "appendTrailing" ((PVar "pieces") (PList)) (EVar "pieces"))
(DFunDef false "appendTrailing" ((PVar "pieces") (PCons (PVar "c") (PVar "cs"))) (EApp (EApp (EVar "appendTrailing") (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EBinOp "::" (ELit (LString "  ")) (EVar "pieces")))) (EVar "cs")))
(DTypeSig false "isInterior" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Comment") (TyCon "Bool")))))
(DFunDef false "isInterior" ((PVar "startLine") (PVar "endLine") (PVar "c")) (EBlock (DoLet false false (PVar "l") (EApp (EVar "commentLine") (EVar "c"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "l") (EVar "startLine")) (EBinOp "<" (EVar "l") (EVar "endLine"))) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))))))
(DTypeSig false "isDataDeclF" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isDataDeclF" ((PCon "DData" PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "isDataDeclF" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "isDataDeclF") (EVar "inner")))
(DFunDef false "isDataDeclF" (PWild) (EVar "False"))
(DTypeSig false "isSingleNamedFieldData" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isSingleNamedFieldData" ((PCon "DData" PWild PWild PWild (PList (PCon "Variant" PWild (PCon "ConNamed" PWild PWild))) PWild)) (EVar "True"))
(DFunDef false "isSingleNamedFieldData" (PWild) (EVar "False"))
(DTypeSig false "renderNamedFieldMulti" (TyFun (TyCon "FmtState") (TyFun (TyCon "Decl") (TyTuple (TyCon "String") (TyCon "FmtState")))))
(DFunDef false "renderNamedFieldMulti" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started")) (PCon "DData" (PVar "vis") (PVar "n") (PVar "params") (PVar "variants") (PVar "derives"))) (EMatch (EApp (EApp (EVar "takeNVariantLines") (EVar "vlines")) (ELit (LInt 1))) (arm (PTuple (PVar "vlinesRest") PWild) () (ETuple (EApp (EVar "render") (EApp (EApp (EApp (EApp (EApp (EVar "printNamedFieldData") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "variants")) (EVar "derives"))) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "cs")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started"))))))
(DFunDef false "renderNamedFieldMulti" ((PVar "st") (PVar "decl")) (EApp (EApp (EVar "declDoc") (EVar "st")) (EVar "decl")))
(DTypeSig false "spliceInterior" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Comment")))))))
(DFunDef false "spliceInterior" ((PVar "declStr") (PVar "startLine") (PVar "interior")) (EBlock (DoLet false false (PVar "outLines") (EApp (EVar "splitNl") (EVar "declStr"))) (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "outLines"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "attachInterior") (EVar "outLines")) (EVar "startLine")) (ELit (LInt 0))) (EVar "n")) (EVar "interior")) (EListLit)) (arm (PTuple (PVar "newLines") (PVar "consumed")) () (ETuple (EApp (EVar "joinNl") (EVar "newLines")) (EApp (EVar "reverseL") (EVar "consumed"))))))))
(DTypeSig false "attachInterior" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment"))))))))))
(DFunDef false "attachInterior" ((PList) PWild PWild PWild PWild (PVar "consumed")) (ETuple (EListLit) (EVar "consumed")))
(DFunDef false "attachInterior" ((PCons (PVar "ln") (PVar "rest")) (PVar "startLine") (PVar "idx") (PVar "n") (PVar "interior") (PVar "consumed")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "attachOnLine") (EVar "ln")) (EVar "startLine")) (EVar "idx")) (EVar "interior")) (EVar "consumed")) (arm (PTuple (PVar "ln1") (PVar "consumed1")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "attachInterior") (EVar "rest")) (EVar "startLine")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))) (EVar "n")) (EVar "interior")) (EVar "consumed1")) (arm (PTuple (PVar "rest1") (PVar "consumed2")) () (ETuple (EBinOp "::" (EVar "ln1") (EVar "rest1")) (EVar "consumed2")))))))
(DTypeSig false "attachOnLine" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Comment")))))))))
(DFunDef false "attachOnLine" ((PVar "ln") PWild PWild (PList) (PVar "consumed")) (ETuple (EVar "ln") (EVar "consumed")))
(DFunDef false "attachOnLine" ((PVar "ln") (PVar "startLine") (PVar "idx") (PCons (PVar "c") (PVar "cs")) (PVar "consumed")) (EIf (EBinOp "==" (EBinOp "-" (EApp (EVar "commentLine") (EVar "c")) (EVar "startLine")) (EVar "idx")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "attachOnLine") (EVar "ln")) (EVar "startLine")) (EVar "idx")) (EVar "cs")) (EVar "consumed")) (arm (PTuple (PVar "ln1") (PVar "consumed1")) () (ETuple (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ln1"))) (ELit (LString "  "))) (EApp (EVar "display") (EApp (EVar "commentText") (EVar "c")))) (ELit (LString ""))) (EBinOp "::" (EVar "c") (EVar "consumed1"))))) (EApp (EApp (EApp (EApp (EApp (EVar "attachOnLine") (EVar "ln")) (EVar "startLine")) (EVar "idx")) (EVar "cs")) (EVar "consumed"))))
(DTypeSig false "dropConsumed" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Comment")))))
(DFunDef false "dropConsumed" ((PVar "cs") (PVar "consumed")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "anyLineEq") (EApp (EVar "commentLine") (EVar "c"))) (EVar "consumed"))))) (EVar "cs")))
(DTypeSig false "anyLineEq" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyCon "Bool"))))
(DFunDef false "anyLineEq" (PWild (PList)) (EVar "False"))
(DFunDef false "anyLineEq" ((PVar "l") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "l")) (EVar "True") (EApp (EApp (EVar "anyLineEq") (EVar "l")) (EVar "cs"))))
(DTypeSig false "intInList" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "intInList" (PWild (PList)) (EVar "False"))
(DFunDef false "intInList" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EApp (EApp (EVar "intInList") (EVar "x")) (EVar "ys"))))
(DTypeSig false "commentOnLine" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "commentOnLine" ((PList) PWild) (EVar "None"))
(DFunDef false "commentOnLine" ((PCons (PVar "c") (PVar "cs")) (PVar "l")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "l")) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))) (EApp (EVar "Some") (EApp (EVar "commentText") (EVar "c"))) (EApp (EApp (EVar "commentOnLine") (EVar "cs")) (EVar "l"))))
(DTypeSig false "spanComments" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "spanComments" ((PVar "cs") (PVar "lo") (PVar "hi")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "commentLine") (EVar "c")) (EVar "lo")) (EBinOp "<=" (EApp (EVar "commentLine") (EVar "c")) (EVar "hi"))))) (EVar "cs")))
(DTypeSig false "chainCoversAll" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))))
(DFunDef false "chainCoversAll" ((PVar "cs") (PVar "lo") (PVar "hi") (PVar "ols")) (EApp (EApp (EVar "allList") (ELam ((PVar "c")) (EBinOp "&&" (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c"))) (EApp (EApp (EVar "intInList") (EApp (EVar "commentLine") (EVar "c"))) (EVar "ols"))))) (EApp (EApp (EApp (EVar "spanComments") (EVar "cs")) (EVar "lo")) (EVar "hi"))))
(DTypeSig false "verbatimSpan" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "verbatimSpan" ((PVar "srcLines") (PVar "startLine") (PVar "endLine")) (EApp (EVar "joinNl") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "srcLines")) (ELit (LInt 1))) (EVar "startLine")) (EVar "endLine"))))
(DTypeSig false "spanLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "spanLines" ((PList) PWild PWild PWild) (EListLit))
(DFunDef false "spanLines" ((PCons (PVar "l") (PVar "ls")) (PVar "idx") (PVar "startLine") (PVar "endLine")) (EIf (EBinOp ">" (EVar "idx") (EVar "endLine")) (EListLit) (EIf (EBinOp ">=" (EVar "idx") (EVar "startLine")) (EBinOp "::" (EVar "l") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "ls")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))) (EVar "startLine")) (EVar "endLine"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "ls")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))) (EVar "startLine")) (EVar "endLine")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "stepDecl" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Decl") (TyFun (TyCon "DeclPos") (TyCon "FmtState")))))))
(DFunDef false "stepDecl" ((PVar "st") (PVar "srcLines") (PVar "chainOls") (PVar "decl") (PVar "dp")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "declPosLine") (EVar "dp"))) (DoLet false false (PVar "endLine") (EApp (EVar "declPosEndLine") (EVar "dp"))) (DoLet false false (PVar "st1") (EApp (EApp (EVar "flushBefore") (EVar "st")) (EVar "line"))) (DoExpr (EMatch (EVar "st1") (arm (PCon "FmtState" (PVar "pieces1") (PVar "cs1") (PVar "vlines1") (PVar "cursor1") (PVar "started1")) () (EBlock (DoLet false false (PVar "pieces2") (EApp (EApp (EApp (EApp (EVar "blankLineIfNeeded") (EVar "pieces1")) (EVar "line")) (EVar "cursor1")) (EVar "started1"))) (DoLet false false (PVar "hasInterior") (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs1")))) (DoLet false false (PVar "useChain") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "hasInterior") (EApp (EVar "isNonEmptyL") (EVar "chainOls"))) (EBinOp "==" (EApp (EVar "declChainLen") (EVar "decl")) (EApp (EVar "listLen") (EVar "chainOls")))) (EApp (EApp (EApp (EApp (EVar "chainCoversAll") (EVar "cs1")) (EVar "line")) (EVar "endLine")) (EVar "chainOls")))) (DoLet false false (PVar "useBlock") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "hasInterior") (EApp (EVar "not") (EVar "useChain"))) (EApp (EVar "isNonEmptyL") (EVar "chainOls"))) (EBinOp "==" (EApp (EVar "declBlockLen") (EVar "decl")) (EApp (EVar "listLen") (EVar "chainOls")))) (EApp (EApp (EApp (EApp (EVar "chainCoversAll") (EVar "cs1")) (EVar "line")) (EVar "endLine")) (EVar "chainOls")))) (DoLet false false (PVar "useVerbatim") (EBinOp "&&" (EVar "hasInterior") (EApp (EVar "not") (EApp (EVar "isDataDeclF") (EVar "decl"))))) (DoLet false false (PVar "st2") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "cs1")) (EVar "vlines1")) (EVar "cursor1")) (EVar "started1"))) (DoExpr (EIf (EVar "useChain") (EBlock (DoLet false false (PVar "perOp") (EApp (EApp (EVar "map") (ELam ((PVar "ol")) (EApp (EApp (EVar "commentOnLine") (EVar "cs1")) (EVar "ol")))) (EVar "chainOls"))) (DoLet false false (PVar "declStr") (EApp (EVar "render") (EApp (EApp (EVar "printDeclChainCommented") (EVar "decl")) (EVar "perOp")))) (DoLet false false (PVar "csRest") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")))) (EVar "cs1"))) (DoLet false false (PVar "pieces3") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EVar "declStr") (EVar "pieces2")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces3")) (EVar "csRest")) (EVar "vlines1")) (EVar "endLine")) (EVar "True")))) (EIf (EVar "useBlock") (EBlock (DoLet false false (PVar "perStmt") (EApp (EApp (EVar "map") (ELam ((PVar "ol")) (EApp (EApp (EVar "commentOnLine") (EVar "cs1")) (EVar "ol")))) (EVar "chainOls"))) (DoLet false false (PVar "declStr") (EApp (EVar "render") (EApp (EApp (EVar "printDeclBlockCommented") (EVar "decl")) (EVar "perStmt")))) (DoLet false false (PVar "csRest") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")))) (EVar "cs1"))) (DoLet false false (PVar "pieces3") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EVar "declStr") (EVar "pieces2")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces3")) (EVar "csRest")) (EVar "vlines1")) (EVar "endLine")) (EVar "True")))) (EIf (EVar "useVerbatim") (EBlock (DoLet false false (PVar "csRest") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")))) (EVar "cs1"))) (DoLet false false (PVar "pieces3") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EApp (EApp (EApp (EVar "verbatimSpan") (EVar "srcLines")) (EVar "line")) (EVar "endLine")) (EVar "pieces2")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces3")) (EVar "csRest")) (EVar "vlines1")) (EVar "endLine")) (EVar "True")))) (EApp (EApp (EApp (EApp (EVar "stepDeclNormal") (EVar "st2")) (EVar "decl")) (EVar "line")) (EVar "endLine"))))))))))))
(DTypeSig false "stepDeclNormal" (TyFun (TyCon "FmtState") (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "FmtState"))))))
(DFunDef false "stepDeclNormal" ((PCon "FmtState" (PVar "pieces2") (PVar "cs1") (PVar "vlines1") (PVar "cursor1") (PVar "started1")) (PVar "decl") (PVar "line") (PVar "endLine")) (EBlock (DoLet false false (PVar "nfMulti") (EBinOp "&&" (EApp (EVar "isSingleNamedFieldData") (EVar "decl")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs1"))))) (DoLet false false (PVar "st2") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "cs1")) (EVar "vlines1")) (EVar "cursor1")) (EVar "started1"))) (DoExpr (EMatch (EIf (EVar "nfMulti") (EApp (EApp (EVar "renderNamedFieldMulti") (EVar "st2")) (EVar "decl")) (EApp (EApp (EVar "declDoc") (EVar "st2")) (EVar "decl"))) (arm (PTuple (PVar "declStr0") (PCon "FmtState" (PVar "pieces3") (PVar "cs3") (PVar "vlines3") (PVar "_cursor3") (PVar "_started3"))) () (EBlock (DoLet false false (PVar "interior") (EIf (EBinOp "&&" (EApp (EVar "isDataDeclF") (EVar "decl")) (EApp (EVar "not") (EVar "nfMulti"))) (EListLit) (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs3")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "spliceInterior") (EVar "declStr0")) (EVar "line")) (EVar "interior")) (arm (PTuple (PVar "declStr") (PVar "consumed")) () (EBlock (DoLet false false (PVar "cs3b") (EApp (EApp (EVar "dropConsumed") (EVar "cs3")) (EVar "consumed"))) (DoExpr (EMatch (EApp (EApp (EVar "takeTrailing") (EVar "cs3b")) (EVar "endLine")) (arm (PTuple (PVar "trailing") (PVar "csRest")) () (EBlock (DoLet false false (PVar "pieces4") (EApp (EApp (EVar "appendTrailing") (EBinOp "::" (EVar "declStr") (EVar "pieces3"))) (EVar "trailing"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EBinOp "::" (ELit (LString "\n")) (EVar "pieces4"))) (EVar "csRest")) (EVar "vlines3")) (EVar "endLine")) (EVar "True")))))))))))))))))
(DTypeSig false "walkDecls" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyCon "FmtState")))))))
(DFunDef false "walkDecls" ((PVar "st") PWild (PList) PWild PWild) (EVar "st"))
(DFunDef false "walkDecls" ((PVar "st") PWild PWild (PList) PWild) (EVar "st"))
(DFunDef false "walkDecls" ((PVar "st") (PVar "srcLines") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PList)) (EApp (EApp (EApp (EApp (EApp (EVar "walkDecls") (EApp (EApp (EApp (EApp (EApp (EVar "stepDecl") (EVar "st")) (EVar "srcLines")) (EListLit)) (EVar "d")) (EVar "p"))) (EVar "srcLines")) (EVar "ds")) (EVar "ps")) (EListLit)))
(DFunDef false "walkDecls" ((PVar "st") (PVar "srcLines") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PCons (PVar "c") (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EVar "walkDecls") (EApp (EApp (EApp (EApp (EApp (EVar "stepDecl") (EVar "st")) (EVar "srcLines")) (EVar "c")) (EVar "d")) (EVar "p"))) (EVar "srcLines")) (EVar "ds")) (EVar "ps")) (EVar "rest")))
(DTypeSig true "formatProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))))))
(DFunDef false "formatProgram" ((PVar "decls") (PVar "declPositions") (PVar "variantLines") (PVar "chainLines") (PVar "comments") (PVar "_lastContentLine") (PVar "src")) (EIf (EBinOp "!=" (EApp (EVar "listLen") (EVar "declPositions")) (EApp (EVar "listLen") (EVar "decls"))) (EApp (EVar "stringConcat") (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EBinOp "++" (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "d"))) (ELit (LString "\n"))))) (EVar "decls"))) (EBlock (DoLet false false (PVar "st0") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EListLit)) (EVar "comments")) (EVar "variantLines")) (ELit (LInt 0))) (EVar "False"))) (DoExpr (EMatch (EApp (EVar "drainAll") (EApp (EApp (EApp (EApp (EApp (EVar "walkDecls") (EVar "st0")) (EApp (EVar "splitNl") (EVar "src"))) (EVar "decls")) (EVar "declPositions")) (EVar "chainLines"))) (arm (PCon "FmtState" (PVar "finalPieces") PWild PWild PWild PWild) () (EApp (EVar "stringConcat") (EApp (EVar "reverseL") (EVar "finalPieces")))))))))
(DTypeSig false "drainAll" (TyFun (TyCon "FmtState") (TyCon "FmtState")))
(DFunDef false "drainAll" ((PCon "FmtState" (PVar "pieces") (PList) (PVar "vlines") (PVar "cursor") (PVar "started"))) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EListLit)) (EVar "vlines")) (EVar "cursor")) (EVar "started")))
(DFunDef false "drainAll" ((PCon "FmtState" (PVar "pieces") (PCons (PVar "c") (PVar "rest")) (PVar "vlines") (PVar "cursor") (PVar "started"))) (EApp (EVar "drainAll") (EApp (EApp (EVar "emitComment") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "rest")) (EVar "vlines")) (EVar "cursor")) (EVar "started"))) (EVar "c"))))
(DTypeSig true "formatSource" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "formatSource" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositions") (EVar "src")) (arm (PTuple (PVar "decls") (PVar "pos")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "formatProgram") (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "pos"))) (EApp (EVar "positionsVariantLines") (EVar "pos"))) (EApp (EVar "positionsChainLines") (EVar "pos"))) (EApp (EVar "collectComments") (EVar "src"))) (EApp (EVar "positionsLastContentLine") (EVar "pos"))) (EVar "src")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "DataVis" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Decl" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "render" false) (mem "printDecl" false) (mem "printDataDeclCommented" false) (mem "printNamedFieldData" false) (mem "printDeclChainCommented" false) (mem "declChainLen" false) (mem "printDeclBlockCommented" false) (mem "declBlockLen" false) (mem "Doc" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "commentLine" false) (mem "commentText" false) (mem "collectComments" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseWithPositions" false) (mem "Positions" false) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "positionsVariantLines" false) (mem "positionsLastContentLine" false) (mem "positionsChainLines" false) (mem "declPosLine" false) (mem "declPosEndLine" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "reverseL" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "filterList" false) (mem "splitNl" false) (mem "joinNl" false) (mem "allList" false))))
(DData Private "FmtState" () ((variant "FmtState" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int") (TyCon "Bool")))) ())
(DTypeSig false "countNl" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "countNl" ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "countNlChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "s")))) (ELit (LInt 0))))
(DTypeSig false "countNlChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "countNlChars" ((PVar "src") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "charAt") (EVar "src")) (EVar "i")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EVar "countNlChars") (EVar "src")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "countNlChars") (EVar "src")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "charAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Char"))))
(DFunDef false "charAt" ((PVar "src") (PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")))
(DTypeSig false "isSingleLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isSingleLine" ((PVar "s")) (EBinOp "==" (EApp (EVar "countNl") (EVar "s")) (ELit (LInt 0))))
(DTypeSig false "blankLineIfNeeded" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "blankLineIfNeeded" ((PVar "pieces") (PVar "targetLine") (PVar "cursor") (PVar "started")) (EIf (EBinOp "&&" (EVar "started") (EBinOp ">=" (EBinOp "-" (EVar "targetLine") (EVar "cursor")) (ELit (LInt 2)))) (EBinOp "::" (ELit (LString "\n")) (EVar "pieces")) (EVar "pieces")))
(DTypeSig false "emitComment" (TyFun (TyCon "FmtState") (TyFun (TyCon "Comment") (TyCon "FmtState"))))
(DFunDef false "emitComment" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started")) (PVar "c")) (EBlock (DoLet false false (PVar "pieces1") (EApp (EApp (EApp (EApp (EVar "blankLineIfNeeded") (EVar "pieces")) (EApp (EVar "commentLine") (EVar "c"))) (EVar "cursor")) (EVar "started"))) (DoLet false false (PVar "pieces2") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EVar "pieces1")))) (DoLet false false (PVar "nls") (EApp (EVar "countNl") (EApp (EVar "commentText") (EVar "c")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "cs")) (EVar "vlines")) (EBinOp "+" (EApp (EVar "commentLine") (EVar "c")) (EVar "nls"))) (EVar "True")))))
(DTypeSig false "flushBefore" (TyFun (TyCon "FmtState") (TyFun (TyCon "Int") (TyCon "FmtState"))))
(DFunDef false "flushBefore" ((PCon "FmtState" (PVar "pieces") (PList) (PVar "vlines") (PVar "cursor") (PVar "started")) PWild) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EListLit)) (EVar "vlines")) (EVar "cursor")) (EVar "started")))
(DFunDef false "flushBefore" ((PCon "FmtState" (PVar "pieces") (PCons (PVar "c") (PVar "rest")) (PVar "vlines") (PVar "cursor") (PVar "started")) (PVar "line")) (EIf (EBinOp "<" (EApp (EVar "commentLine") (EVar "c")) (EVar "line")) (EApp (EApp (EVar "flushBefore") (EApp (EApp (EVar "emitComment") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "rest")) (EVar "vlines")) (EVar "cursor")) (EVar "started"))) (EVar "c"))) (EVar "line")) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EBinOp "::" (EVar "c") (EVar "rest"))) (EVar "vlines")) (EVar "cursor")) (EVar "started"))))
(DTypeSig false "takeNVariantLines" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "takeNVariantLines" ((PVar "vlines") (PVar "k")) (EApp (EApp (EApp (EVar "takeNVarGo") (EVar "vlines")) (EVar "k")) (EListLit)))
(DTypeSig false "takeNVarGo" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "takeNVarGo" ((PVar "vlines") (PVar "k") (PVar "acc")) (EIf (EBinOp "<=" (EVar "k") (ELit (LInt 0))) (ETuple (EVar "vlines") (EApp (EVar "reverseL") (EVar "acc"))) (EIf (EVar "otherwise") (EMatch (EVar "vlines") (arm (PList) () (ETuple (EVar "vlines") (EApp (EVar "reverseL") (EVar "acc")))) (arm (PCons (PVar "x") (PVar "rest")) () (EApp (EApp (EApp (EVar "takeNVarGo") (EVar "rest")) (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EBinOp "::" (EVar "x") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "takeBefore" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "takeBefore" ((PVar "cs") (PVar "line")) (EApp (EApp (EApp (EVar "takeBeforeGo") (EVar "cs")) (EVar "line")) (EListLit)))
(DTypeSig false "takeBeforeGo" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment")))))))
(DFunDef false "takeBeforeGo" ((PList) PWild (PVar "acc")) (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EListLit)))
(DFunDef false "takeBeforeGo" ((PCons (PVar "c") (PVar "rest")) (PVar "line") (PVar "acc")) (EIf (EBinOp "<" (EApp (EVar "commentLine") (EVar "c")) (EVar "line")) (EApp (EApp (EApp (EVar "takeBeforeGo") (EVar "rest")) (EVar "line")) (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EVar "acc"))) (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EBinOp "::" (EVar "c") (EVar "rest")))))
(DTypeSig false "takeSameLine" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "takeSameLine" ((PList) PWild) (ETuple (EListLit) (EListLit)))
(DFunDef false "takeSameLine" ((PCons (PVar "c") (PVar "rest")) (PVar "line")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "line")) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))) (EMatch (EApp (EApp (EVar "takeSameLine") (EVar "rest")) (EVar "line")) (arm (PTuple (PVar "more") (PVar "leftover")) () (ETuple (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EVar "more")) (EVar "leftover")))) (ETuple (EListLit) (EBinOp "::" (EVar "c") (EVar "rest")))))
(DTypeSig false "vcommentsFor" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "vcommentsFor" ((PVar "cs") (PList)) (ETuple (EListLit) (EVar "cs")))
(DFunDef false "vcommentsFor" ((PVar "cs") (PCons (PVar "l") (PVar "ls"))) (EMatch (EApp (EApp (EVar "takeBefore") (EVar "cs")) (EVar "l")) (arm (PTuple (PVar "leading") (PVar "rest1")) () (EMatch (EApp (EApp (EVar "takeSameLine") (EVar "rest1")) (EVar "l")) (arm (PTuple (PVar "trailing") (PVar "rest2")) () (EMatch (EApp (EApp (EVar "vcommentsFor") (EVar "rest2")) (EVar "ls")) (arm (PTuple (PVar "more") (PVar "leftover")) () (ETuple (EBinOp "::" (ETuple (EVar "leading") (EVar "trailing")) (EVar "more")) (EVar "leftover")))))))))
(DTypeSig false "allEmptyPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Bool")))
(DFunDef false "allEmptyPairs" ((PList)) (EVar "True"))
(DFunDef false "allEmptyPairs" ((PCons (PTuple (PVar "ld") (PVar "tr")) (PVar "xs"))) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "ld")) (EApp (EVar "isEmptyL") (EVar "tr"))) (EApp (EVar "allEmptyPairs") (EVar "xs"))))
(DTypeSig false "declDoc" (TyFun (TyCon "FmtState") (TyFun (TyCon "Decl") (TyTuple (TyCon "String") (TyCon "FmtState")))))
(DFunDef false "declDoc" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started")) (PCon "DData" (PVar "vis") (PVar "n") (PVar "params") (PVar "variants") (PVar "derives"))) (EMatch (EApp (EApp (EVar "takeNVariantLines") (EVar "vlines")) (EApp (EVar "listLen") (EVar "variants"))) (arm (PTuple (PVar "vlinesRest") (PVar "vls")) () (EMatch (EApp (EApp (EVar "vcommentsFor") (EVar "cs")) (EVar "vls")) (arm (PTuple (PVar "vcomments") (PVar "csRest")) () (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "vcomments")) (EApp (EVar "listLen") (EVar "variants"))) (EApp (EVar "not") (EApp (EVar "allEmptyPairs") (EVar "vcomments")))) (ETuple (EApp (EVar "render") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "printDataDeclCommented") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "variants")) (EVar "derives")) (EVar "vcomments"))) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "csRest")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started"))) (ETuple (EApp (EVar "render") (EApp (EVar "printDecl") (EApp (EApp (EApp (EApp (EApp (EVar "DData") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "variants")) (EVar "derives")))) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "cs")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started")))))))))
(DFunDef false "declDoc" ((PVar "st") (PVar "decl")) (ETuple (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "decl"))) (EVar "st")))
(DTypeSig false "isTrailing" (TyFun (TyCon "Int") (TyFun (TyCon "Comment") (TyCon "Bool"))))
(DFunDef false "isTrailing" ((PVar "endLine") (PVar "c")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))))
(DTypeSig false "takeTrailing" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "takeTrailing" ((PVar "cs") (PVar "endLine")) (ETuple (EApp (EApp (EVar "filterList") (EApp (EVar "isTrailing") (EVar "endLine"))) (EVar "cs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "isTrailing") (EVar "endLine")) (EVar "c"))))) (EVar "cs"))))
(DTypeSig false "appendTrailing" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "appendTrailing" ((PVar "pieces") (PList)) (EVar "pieces"))
(DFunDef false "appendTrailing" ((PVar "pieces") (PCons (PVar "c") (PVar "cs"))) (EApp (EApp (EVar "appendTrailing") (EBinOp "::" (EApp (EVar "commentText") (EVar "c")) (EBinOp "::" (ELit (LString "  ")) (EVar "pieces")))) (EVar "cs")))
(DTypeSig false "isInterior" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Comment") (TyCon "Bool")))))
(DFunDef false "isInterior" ((PVar "startLine") (PVar "endLine") (PVar "c")) (EBlock (DoLet false false (PVar "l") (EApp (EVar "commentLine") (EVar "c"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "l") (EVar "startLine")) (EBinOp "<" (EVar "l") (EVar "endLine"))) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))))))
(DTypeSig false "isDataDeclF" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isDataDeclF" ((PCon "DData" PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "isDataDeclF" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "isDataDeclF") (EVar "inner")))
(DFunDef false "isDataDeclF" (PWild) (EVar "False"))
(DTypeSig false "isSingleNamedFieldData" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isSingleNamedFieldData" ((PCon "DData" PWild PWild PWild (PList (PCon "Variant" PWild (PCon "ConNamed" PWild PWild))) PWild)) (EVar "True"))
(DFunDef false "isSingleNamedFieldData" (PWild) (EVar "False"))
(DTypeSig false "renderNamedFieldMulti" (TyFun (TyCon "FmtState") (TyFun (TyCon "Decl") (TyTuple (TyCon "String") (TyCon "FmtState")))))
(DFunDef false "renderNamedFieldMulti" ((PCon "FmtState" (PVar "pieces") (PVar "cs") (PVar "vlines") (PVar "cursor") (PVar "started")) (PCon "DData" (PVar "vis") (PVar "n") (PVar "params") (PVar "variants") (PVar "derives"))) (EMatch (EApp (EApp (EVar "takeNVariantLines") (EVar "vlines")) (ELit (LInt 1))) (arm (PTuple (PVar "vlinesRest") PWild) () (ETuple (EApp (EVar "render") (EApp (EApp (EApp (EApp (EApp (EVar "printNamedFieldData") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "variants")) (EVar "derives"))) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "cs")) (EVar "vlinesRest")) (EVar "cursor")) (EVar "started"))))))
(DFunDef false "renderNamedFieldMulti" ((PVar "st") (PVar "decl")) (EApp (EApp (EVar "declDoc") (EVar "st")) (EVar "decl")))
(DTypeSig false "spliceInterior" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Comment")))))))
(DFunDef false "spliceInterior" ((PVar "declStr") (PVar "startLine") (PVar "interior")) (EBlock (DoLet false false (PVar "outLines") (EApp (EVar "splitNl") (EVar "declStr"))) (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "outLines"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "attachInterior") (EVar "outLines")) (EVar "startLine")) (ELit (LInt 0))) (EVar "n")) (EVar "interior")) (EListLit)) (arm (PTuple (PVar "newLines") (PVar "consumed")) () (ETuple (EApp (EVar "joinNl") (EVar "newLines")) (EApp (EVar "reverseL") (EVar "consumed"))))))))
(DTypeSig false "attachInterior" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Comment"))))))))))
(DFunDef false "attachInterior" ((PList) PWild PWild PWild PWild (PVar "consumed")) (ETuple (EListLit) (EVar "consumed")))
(DFunDef false "attachInterior" ((PCons (PVar "ln") (PVar "rest")) (PVar "startLine") (PVar "idx") (PVar "n") (PVar "interior") (PVar "consumed")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "attachOnLine") (EVar "ln")) (EVar "startLine")) (EVar "idx")) (EVar "interior")) (EVar "consumed")) (arm (PTuple (PVar "ln1") (PVar "consumed1")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "attachInterior") (EVar "rest")) (EVar "startLine")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))) (EVar "n")) (EVar "interior")) (EVar "consumed1")) (arm (PTuple (PVar "rest1") (PVar "consumed2")) () (ETuple (EBinOp "::" (EVar "ln1") (EVar "rest1")) (EVar "consumed2")))))))
(DTypeSig false "attachOnLine" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Comment")))))))))
(DFunDef false "attachOnLine" ((PVar "ln") PWild PWild (PList) (PVar "consumed")) (ETuple (EVar "ln") (EVar "consumed")))
(DFunDef false "attachOnLine" ((PVar "ln") (PVar "startLine") (PVar "idx") (PCons (PVar "c") (PVar "cs")) (PVar "consumed")) (EIf (EBinOp "==" (EBinOp "-" (EApp (EVar "commentLine") (EVar "c")) (EVar "startLine")) (EVar "idx")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "attachOnLine") (EVar "ln")) (EVar "startLine")) (EVar "idx")) (EVar "cs")) (EVar "consumed")) (arm (PTuple (PVar "ln1") (PVar "consumed1")) () (ETuple (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ln1"))) (ELit (LString "  "))) (EApp (EMethodRef "display") (EApp (EVar "commentText") (EVar "c")))) (ELit (LString ""))) (EBinOp "::" (EVar "c") (EVar "consumed1"))))) (EApp (EApp (EApp (EApp (EApp (EVar "attachOnLine") (EVar "ln")) (EVar "startLine")) (EVar "idx")) (EVar "cs")) (EVar "consumed"))))
(DTypeSig false "dropConsumed" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Comment")))))
(DFunDef false "dropConsumed" ((PVar "cs") (PVar "consumed")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "anyLineEq") (EApp (EVar "commentLine") (EVar "c"))) (EVar "consumed"))))) (EVar "cs")))
(DTypeSig false "anyLineEq" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyCon "Bool"))))
(DFunDef false "anyLineEq" (PWild (PList)) (EVar "False"))
(DFunDef false "anyLineEq" ((PVar "l") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "l")) (EVar "True") (EApp (EApp (EVar "anyLineEq") (EVar "l")) (EVar "cs"))))
(DTypeSig false "intInList" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "intInList" (PWild (PList)) (EVar "False"))
(DFunDef false "intInList" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EApp (EApp (EVar "intInList") (EVar "x")) (EVar "ys"))))
(DTypeSig false "commentOnLine" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "commentOnLine" ((PList) PWild) (EVar "None"))
(DFunDef false "commentOnLine" ((PCons (PVar "c") (PVar "cs")) (PVar "l")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "l")) (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c")))) (EApp (EVar "Some") (EApp (EVar "commentText") (EVar "c"))) (EApp (EApp (EVar "commentOnLine") (EVar "cs")) (EVar "l"))))
(DTypeSig false "spanComments" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Comment"))))))
(DFunDef false "spanComments" ((PVar "cs") (PVar "lo") (PVar "hi")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "commentLine") (EVar "c")) (EVar "lo")) (EBinOp "<=" (EApp (EVar "commentLine") (EVar "c")) (EVar "hi"))))) (EVar "cs")))
(DTypeSig false "chainCoversAll" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))))
(DFunDef false "chainCoversAll" ((PVar "cs") (PVar "lo") (PVar "hi") (PVar "ols")) (EApp (EApp (EVar "allList") (ELam ((PVar "c")) (EBinOp "&&" (EApp (EVar "isSingleLine") (EApp (EVar "commentText") (EVar "c"))) (EApp (EApp (EVar "intInList") (EApp (EVar "commentLine") (EVar "c"))) (EVar "ols"))))) (EApp (EApp (EApp (EVar "spanComments") (EVar "cs")) (EVar "lo")) (EVar "hi"))))
(DTypeSig false "verbatimSpan" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "verbatimSpan" ((PVar "srcLines") (PVar "startLine") (PVar "endLine")) (EApp (EVar "joinNl") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "srcLines")) (ELit (LInt 1))) (EVar "startLine")) (EVar "endLine"))))
(DTypeSig false "spanLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "spanLines" ((PList) PWild PWild PWild) (EListLit))
(DFunDef false "spanLines" ((PCons (PVar "l") (PVar "ls")) (PVar "idx") (PVar "startLine") (PVar "endLine")) (EIf (EBinOp ">" (EVar "idx") (EVar "endLine")) (EListLit) (EIf (EBinOp ">=" (EVar "idx") (EVar "startLine")) (EBinOp "::" (EVar "l") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "ls")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))) (EVar "startLine")) (EVar "endLine"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "spanLines") (EVar "ls")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))) (EVar "startLine")) (EVar "endLine")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "stepDecl" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Decl") (TyFun (TyCon "DeclPos") (TyCon "FmtState")))))))
(DFunDef false "stepDecl" ((PVar "st") (PVar "srcLines") (PVar "chainOls") (PVar "decl") (PVar "dp")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "declPosLine") (EVar "dp"))) (DoLet false false (PVar "endLine") (EApp (EVar "declPosEndLine") (EVar "dp"))) (DoLet false false (PVar "st1") (EApp (EApp (EVar "flushBefore") (EVar "st")) (EVar "line"))) (DoExpr (EMatch (EVar "st1") (arm (PCon "FmtState" (PVar "pieces1") (PVar "cs1") (PVar "vlines1") (PVar "cursor1") (PVar "started1")) () (EBlock (DoLet false false (PVar "pieces2") (EApp (EApp (EApp (EApp (EVar "blankLineIfNeeded") (EVar "pieces1")) (EVar "line")) (EVar "cursor1")) (EVar "started1"))) (DoLet false false (PVar "hasInterior") (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs1")))) (DoLet false false (PVar "useChain") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "hasInterior") (EApp (EVar "isNonEmptyL") (EVar "chainOls"))) (EBinOp "==" (EApp (EVar "declChainLen") (EVar "decl")) (EApp (EVar "listLen") (EVar "chainOls")))) (EApp (EApp (EApp (EApp (EVar "chainCoversAll") (EVar "cs1")) (EVar "line")) (EVar "endLine")) (EVar "chainOls")))) (DoLet false false (PVar "useBlock") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "hasInterior") (EApp (EVar "not") (EVar "useChain"))) (EApp (EVar "isNonEmptyL") (EVar "chainOls"))) (EBinOp "==" (EApp (EVar "declBlockLen") (EVar "decl")) (EApp (EVar "listLen") (EVar "chainOls")))) (EApp (EApp (EApp (EApp (EVar "chainCoversAll") (EVar "cs1")) (EVar "line")) (EVar "endLine")) (EVar "chainOls")))) (DoLet false false (PVar "useVerbatim") (EBinOp "&&" (EVar "hasInterior") (EApp (EVar "not") (EApp (EVar "isDataDeclF") (EVar "decl"))))) (DoLet false false (PVar "st2") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "cs1")) (EVar "vlines1")) (EVar "cursor1")) (EVar "started1"))) (DoExpr (EIf (EVar "useChain") (EBlock (DoLet false false (PVar "perOp") (EApp (EApp (EMethodRef "map") (ELam ((PVar "ol")) (EApp (EApp (EVar "commentOnLine") (EVar "cs1")) (EVar "ol")))) (EVar "chainOls"))) (DoLet false false (PVar "declStr") (EApp (EVar "render") (EApp (EApp (EVar "printDeclChainCommented") (EVar "decl")) (EVar "perOp")))) (DoLet false false (PVar "csRest") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")))) (EVar "cs1"))) (DoLet false false (PVar "pieces3") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EVar "declStr") (EVar "pieces2")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces3")) (EVar "csRest")) (EVar "vlines1")) (EVar "endLine")) (EVar "True")))) (EIf (EVar "useBlock") (EBlock (DoLet false false (PVar "perStmt") (EApp (EApp (EMethodRef "map") (ELam ((PVar "ol")) (EApp (EApp (EVar "commentOnLine") (EVar "cs1")) (EVar "ol")))) (EVar "chainOls"))) (DoLet false false (PVar "declStr") (EApp (EVar "render") (EApp (EApp (EVar "printDeclBlockCommented") (EVar "decl")) (EVar "perStmt")))) (DoLet false false (PVar "csRest") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")))) (EVar "cs1"))) (DoLet false false (PVar "pieces3") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EVar "declStr") (EVar "pieces2")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces3")) (EVar "csRest")) (EVar "vlines1")) (EVar "endLine")) (EVar "True")))) (EIf (EVar "useVerbatim") (EBlock (DoLet false false (PVar "csRest") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp ">" (EApp (EVar "commentLine") (EVar "c")) (EVar "endLine")))) (EVar "cs1"))) (DoLet false false (PVar "pieces3") (EBinOp "::" (ELit (LString "\n")) (EBinOp "::" (EApp (EApp (EApp (EVar "verbatimSpan") (EVar "srcLines")) (EVar "line")) (EVar "endLine")) (EVar "pieces2")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces3")) (EVar "csRest")) (EVar "vlines1")) (EVar "endLine")) (EVar "True")))) (EApp (EApp (EApp (EApp (EVar "stepDeclNormal") (EVar "st2")) (EVar "decl")) (EVar "line")) (EVar "endLine"))))))))))))
(DTypeSig false "stepDeclNormal" (TyFun (TyCon "FmtState") (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "FmtState"))))))
(DFunDef false "stepDeclNormal" ((PCon "FmtState" (PVar "pieces2") (PVar "cs1") (PVar "vlines1") (PVar "cursor1") (PVar "started1")) (PVar "decl") (PVar "line") (PVar "endLine")) (EBlock (DoLet false false (PVar "nfMulti") (EBinOp "&&" (EApp (EVar "isSingleNamedFieldData") (EVar "decl")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs1"))))) (DoLet false false (PVar "st2") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces2")) (EVar "cs1")) (EVar "vlines1")) (EVar "cursor1")) (EVar "started1"))) (DoExpr (EMatch (EIf (EVar "nfMulti") (EApp (EApp (EVar "renderNamedFieldMulti") (EVar "st2")) (EVar "decl")) (EApp (EApp (EVar "declDoc") (EVar "st2")) (EVar "decl"))) (arm (PTuple (PVar "declStr0") (PCon "FmtState" (PVar "pieces3") (PVar "cs3") (PVar "vlines3") (PVar "_cursor3") (PVar "_started3"))) () (EBlock (DoLet false false (PVar "interior") (EIf (EBinOp "&&" (EApp (EVar "isDataDeclF") (EVar "decl")) (EApp (EVar "not") (EVar "nfMulti"))) (EListLit) (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "isInterior") (EVar "line")) (EVar "endLine"))) (EVar "cs3")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "spliceInterior") (EVar "declStr0")) (EVar "line")) (EVar "interior")) (arm (PTuple (PVar "declStr") (PVar "consumed")) () (EBlock (DoLet false false (PVar "cs3b") (EApp (EApp (EVar "dropConsumed") (EVar "cs3")) (EVar "consumed"))) (DoExpr (EMatch (EApp (EApp (EVar "takeTrailing") (EVar "cs3b")) (EVar "endLine")) (arm (PTuple (PVar "trailing") (PVar "csRest")) () (EBlock (DoLet false false (PVar "pieces4") (EApp (EApp (EVar "appendTrailing") (EBinOp "::" (EVar "declStr") (EVar "pieces3"))) (EVar "trailing"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EBinOp "::" (ELit (LString "\n")) (EVar "pieces4"))) (EVar "csRest")) (EVar "vlines3")) (EVar "endLine")) (EVar "True")))))))))))))))))
(DTypeSig false "walkDecls" (TyFun (TyCon "FmtState") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyCon "FmtState")))))))
(DFunDef false "walkDecls" ((PVar "st") PWild (PList) PWild PWild) (EVar "st"))
(DFunDef false "walkDecls" ((PVar "st") PWild PWild (PList) PWild) (EVar "st"))
(DFunDef false "walkDecls" ((PVar "st") (PVar "srcLines") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PList)) (EApp (EApp (EApp (EApp (EApp (EVar "walkDecls") (EApp (EApp (EApp (EApp (EApp (EVar "stepDecl") (EVar "st")) (EVar "srcLines")) (EListLit)) (EVar "d")) (EVar "p"))) (EVar "srcLines")) (EVar "ds")) (EVar "ps")) (EListLit)))
(DFunDef false "walkDecls" ((PVar "st") (PVar "srcLines") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PCons (PVar "c") (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EVar "walkDecls") (EApp (EApp (EApp (EApp (EApp (EVar "stepDecl") (EVar "st")) (EVar "srcLines")) (EVar "c")) (EVar "d")) (EVar "p"))) (EVar "srcLines")) (EVar "ds")) (EVar "ps")) (EVar "rest")))
(DTypeSig true "formatProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))))))
(DFunDef false "formatProgram" ((PVar "decls") (PVar "declPositions") (PVar "variantLines") (PVar "chainLines") (PVar "comments") (PVar "_lastContentLine") (PVar "src")) (EIf (EBinOp "!=" (EApp (EVar "listLen") (EVar "declPositions")) (EApp (EVar "listLen") (EVar "decls"))) (EApp (EVar "stringConcat") (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EBinOp "++" (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "d"))) (ELit (LString "\n"))))) (EVar "decls"))) (EBlock (DoLet false false (PVar "st0") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EListLit)) (EVar "comments")) (EVar "variantLines")) (ELit (LInt 0))) (EVar "False"))) (DoExpr (EMatch (EApp (EVar "drainAll") (EApp (EApp (EApp (EApp (EApp (EVar "walkDecls") (EVar "st0")) (EApp (EVar "splitNl") (EVar "src"))) (EVar "decls")) (EVar "declPositions")) (EVar "chainLines"))) (arm (PCon "FmtState" (PVar "finalPieces") PWild PWild PWild PWild) () (EApp (EVar "stringConcat") (EApp (EVar "reverseL") (EVar "finalPieces")))))))))
(DTypeSig false "drainAll" (TyFun (TyCon "FmtState") (TyCon "FmtState")))
(DFunDef false "drainAll" ((PCon "FmtState" (PVar "pieces") (PList) (PVar "vlines") (PVar "cursor") (PVar "started"))) (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EListLit)) (EVar "vlines")) (EVar "cursor")) (EVar "started")))
(DFunDef false "drainAll" ((PCon "FmtState" (PVar "pieces") (PCons (PVar "c") (PVar "rest")) (PVar "vlines") (PVar "cursor") (PVar "started"))) (EApp (EVar "drainAll") (EApp (EApp (EVar "emitComment") (EApp (EApp (EApp (EApp (EApp (EVar "FmtState") (EVar "pieces")) (EVar "rest")) (EVar "vlines")) (EVar "cursor")) (EVar "started"))) (EVar "c"))))
(DTypeSig true "formatSource" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "formatSource" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositions") (EVar "src")) (arm (PTuple (PVar "decls") (PVar "pos")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "formatProgram") (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "pos"))) (EApp (EVar "positionsVariantLines") (EVar "pos"))) (EApp (EVar "positionsChainLines") (EVar "pos"))) (EApp (EVar "collectComments") (EVar "src"))) (EApp (EVar "positionsLastContentLine") (EVar "pos"))) (EVar "src")))))
