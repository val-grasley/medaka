# META
source_lines=1570
stages=DESUGAR,MARK
# SOURCE
-- lint-disable-file rule-duplicate-body
-- (A handful of small pure cursor/env helpers here — identifierAt/offsetOfLineCol/
--  prefixBefore/lookupSchemeL/jHover/… — are intentionally mirrored in
--  compiler/entries/playground_main.mdk, which cannot import this module: doing so
--  drags tools.fmt + io into that entry's graph and trips a pre-existing
--  multi-module flat-union conflation.  The duplication is deliberate; see the
--  note atop playground_main.mdk.)
-- compiler/lsp.mdk — self-hosted Language Server (Stage 4 Phase B.10)
--
-- Slices B.10.0 + B.10.1:
--   B.10.0 — JSON-RPC-over-stdio skeleton: Content-Length framing, the
--            `initialize` handshake, `initialized`/`shutdown`/`exit`.
--   B.10.1 — textDocument/didOpen + didChange → publishDiagnostics
--            (decl-level fidelity; the compiler AST is location-stripped so
--            resolve/typecheck diagnostics span the whole document, parse
--            errors use parseResult's located line/col).
--
-- Mirrors lib/lsp_server.ml's framing (`Content-Length: N\r\n\r\n` then exactly
-- N body bytes) and handle_initialize's capability set, but only advertises
-- what B.10 implements: textDocumentSync = Full (1).  Hover/completion/
-- definition/symbols/highlight/inlay and the ELoc expr-level ranges are LATER
-- slices and are deliberately NOT advertised here.
--
-- The runtime/core prelude sources are threaded in from the driver
-- (lsp_main.mdk reads them once at startup) so `analyze` can run the full
-- resolve+typecheck pipeline per document.

import json.{
  Json,
  JNull,
  JBool,
  JInt,
  JString,
  JArray,
  JObject,
  jObject,
  jArray,
  stringify,
  parse,
  lookup,
  asString,
  asInt,
}
import driver.diagnostics.{
  Diag,
  Severity,
  SevError,
  SevWarning,
  analyzeLocated,
  analyzeProject,
  projectEntrySchemes,
}
import driver.loader.{findProjectRoot}
import frontend.parser.{
  ParseError,
  parseResult,
  parseErrorLine,
  parseErrorCol,
  parseErrorMessage,
  parseWithPositions,
  parseWithPositionsOpt,
  positionsDecls,
  DeclPos,
  declPosLine,
  declPosEndLine,
}
import frontend.lexer.{Token(..), tokenizeWithOffsetPairs}
import support.char.{isIdentChar, isDigit}
import support.util.{maxI, utf8Len, joinWith}
import io.{stripCR}
import frontend.desugar.{desugar}
import types.typecheck.{
  checkProgramSchemes,
  checkProgramSchemesWithRuntime,
  ppSchemeNamed,
  Scheme(..),
  currentLocalSchemes,
  currentSeedSchemes,
}
import tools.fmt.{formatSource}
import frontend.ast.{
  Decl,
  DTypeSig,
  DExtern,
  DFunDef,
  DData,
  DUse,
  DEffect,
  DProp,
  DTest,
  DBench,
  DInterface,
  DImpl,
  DTypeAlias,
  DNewtype,
  DLetGroup,
  DAttrib,
  Ty,
  TyEffect,
  Loc(..),
  Variant,
  ConPayload(..),
  Field,
  IfaceMethod,
  ImplMethod,
  LetBind,
  UsePath,
  UseName,
  UseGroup,
  UseWild,
  UseAlias,
}

-- ── open-document store ─────────────────────────────────────────────────────
-- uri → source text.  A plain association list; LSP sessions open a handful of
-- files, so linear scan is fine.

public export data Docs = Docs (List (String, String))

emptyDocs : Docs
emptyDocs = Docs []

docsPut : String -> String -> Docs -> Docs
docsPut uri src (Docs xs) = Docs ((uri, src) :: docsRemove uri xs)

docsRemove : String -> List (String, String) -> List (String, String)
docsRemove _ [] = []
docsRemove uri ((k, v)::rest)
  | k == uri = docsRemove uri rest
  | otherwise = (k, v) :: docsRemove uri rest

-- ── JSON helpers ────────────────────────────────────────────────────────────

-- 0-based LSP Position: { line, character }.
jPosition : Int -> Int -> Json
jPosition line ch = jObject [("line", JInt line), ("character", JInt ch)]

-- LSP Range: { start, end }.
jRange : Int -> Int -> Int -> Int -> Json
jRange sl sc el ec =
  jObject [("start", jPosition sl sc), ("end", jPosition el ec)]

-- A single LSP Diagnostic object.  severity: 1=Error, 2=Warning (LSP spec).
jDiagnostic : Int -> Json -> String -> Json
jDiagnostic sev range msg = jObject
  [
    ("range", range),
    ("severity", JInt sev),
    ("source", JString "medaka"),
    ("message", JString msg),
  ]

severityCode : Severity -> Int
severityCode SevError = 1
severityCode SevWarning = 2

-- ── diagnostics → LSP (expr-level) ──────────────────────────────────────────
--
-- B.10.2b: type-error Diags now carry the ELoc span captured at the push site
-- (`Some Loc`), so they map to an expr-level LSP range — mirror of the OCaml
-- LSP's `range_of_loc` (lib/lsp_server.ml:100): a 1-based `Loc` line maps to a
-- 0-based LSP line (line-1), the col is already 0-based.  Resolve / guard /
-- match diagnostics carry `None` (the compiler pipeline doesn't locate them) and
-- fall back to the whole-document range.  Parse errors keep using parseResult's
-- located line/col (below).

-- Count the lines in a source string (number of '\n' separators).  Used to
-- build the whole-document range end position.
countLines : String -> Int
countLines src = countLinesGo (stringToChars src) 0 0

countLinesGo : Array Char -> Int -> Int -> Int
countLinesGo arr i acc
  | i >= arrayLength arr = acc
  | arrayGetUnsafe i arr == '\n' = countLinesGo arr (i + 1) (acc + 1)
  | otherwise = countLinesGo arr (i + 1) acc

-- The range covering the whole document: (0,0) .. (lineCount, 0).
wholeDocRange : String -> Json
wholeDocRange src = jRange 0 0 (countLines src) 0

-- Map an `Option Loc` to an LSP range.  `Some` → the expr-level span (mirror of
-- OCaml `range_of_loc`: line-1 for both start/end line, cols verbatim); `None` →
-- the whole-document fallback.
rangeOfLoc : String -> Option Loc -> Json
rangeOfLoc src (Some (Loc _ sl sc el ec)) = jRange (sl - 1) sc (el - 1) ec
rangeOfLoc src None = wholeDocRange src

-- Map one analyze Diag onto an LSP diagnostic JSON, using its captured span
-- (B.10.2b) for an expr-level range, falling back to whole-document for
-- loc-less diagnostics.
diagToJson : String -> Diag -> Json
diagToJson src (Diag sev _ msg loc _ _) =
  jDiagnostic (severityCode sev) (rangeOfLoc src loc) msg

-- Produce the LSP diagnostics array for a source.  A parse failure short-
-- circuits to a single located diagnostic (parseResult); otherwise run the
-- full resolve+typecheck `analyzeLocated` pipeline (real ELoc spans, so type
-- errors carry expr-level ranges).
diagnosticsFor : String -> String -> String -> List Json
diagnosticsFor runtimeSrc coreSrc src = match parseResult src
  Err e =>
    let ln = maxI 0 (parseErrorLine e - 1)
    let col = maxI 0 (parseErrorCol e)
    let r = jRange ln col ln (col + 1)
    [jDiagnostic 1 r (parseErrorMessage e)]
  Ok _ => map (diagToJson src) (analyzeLocated runtimeSrc coreSrc src)
-- parseResult line is 1-based, col 0-based (matches the OCaml loader); LSP
-- wants 0-based lines, so subtract 1 from the line.

-- ── document store accessor (request handlers) ──────────────────────────────
-- Look up an open document's source by uri.  Request handlers (formatting/
-- documentSymbol/definition/highlight) read the buffer the client last sent.
docsGet : String -> Docs -> Option String
docsGet uri (Docs xs) = docsLookup uri xs

docsLookup : String -> List (String, String) -> Option String
docsLookup _ [] = None
docsLookup uri ((k, v)::rest)
  | k == uri = Some v
  | otherwise = docsLookup uri rest

-- ── textDocument/formatting ─────────────────────────────────────────────────
-- Mirror lib/lsp_server.ml handle_formatting: run the formatter; if the text is
-- unchanged return [] (no edits); otherwise return ONE TextEdit replacing the
-- whole document with the formatted source.  The replaced range is
-- (0,0)..(lineCount+1, 0) — mirrors OCaml full_document_range, which uses
-- `nl = newline_count + 1` for the end line so every line (incl. the last) is
-- covered without knowing its width.  A formatter/parse failure yields [] here
-- rather than crashing (the compiler formatSource is total on parseable input;
-- a parse error short-circuits to []).
fullDocRangeFmt : String -> Json
fullDocRangeFmt src = jRange 0 0 (countLines src + 1) 0

formattingEdits : String -> List Json
formattingEdits src = match parseResult src
  Err _ => []
  Ok _ =>
    let formatted = formatSource src
    if formatted == src then
      []
    else
      [jObject [("range", fullDocRangeFmt src), ("newText", JString formatted)]]
-- unparseable → no edits (client keeps buffer)

-- ── identifier-at-cursor + occurrence scan (pure string ops) ────────────────
-- Mirrors lib/lsp_server.ml is_ident_char / identifier_at / find_all_occurrences.

-- Byte offset of 0-based (line, col): walk to the line start, add col.  Returns
-- None if the line doesn't exist or the offset is past EOF.
offsetOfLineCol : Array Char -> Int -> Int -> Option Int
offsetOfLineCol arr line col = offsetGo arr (arrayLength arr) 0 0 0 line col

offsetGo : Array Char -> Int -> Int -> Int -> Int -> Int -> Int -> Option Int
offsetGo arr len i curLine lineStart line col
  | curLine == line =
    let pos = lineStart + col
    if pos >= 0 && pos < len then Some pos else None
  | i >= len = None
  | arrayGetUnsafe i arr == '\n' =
    offsetGo arr len (i + 1) (curLine + 1) (i + 1) line col
  | otherwise = offsetGo arr len (i + 1) curLine lineStart line col
-- ran out before reaching `line`

-- Expand left/right from `pos` over identifier chars; returns (start, stopExcl).
identStart : Array Char -> Int -> Int
identStart arr i
  | i <= 0 = 0
  | isIdentChar (arrayGetUnsafe (i - 1) arr) = identStart arr (i - 1)
  | otherwise = i

identStop : Array Char -> Int -> Int -> Int
identStop arr len i
  | i + 1 >= len = i + 1
  | isIdentChar (arrayGetUnsafe (i + 1) arr) = identStop arr len (i + 1)
  | otherwise = i + 1

-- The identifier under (line, col), or None if the cursor isn't on one.
identifierAt : String -> Int -> Int -> Option String
identifierAt src line col =
  let arr = stringToChars src
  let len = arrayLength arr
  match offsetOfLineCol arr line col
    None => None
    Some pos => if not (isIdentChar (arrayGetUnsafe pos arr)) then None
    else
      let s = identStart arr pos
      let e = identStop arr len pos
      Some (stringSlice s e src)

-- 0-based (line, character) of a byte offset.  Used to turn occurrence offsets
-- back into LSP Positions (mirror offset_to_position).
posOfOffset : Array Char -> Int -> (Int, Int)
posOfOffset arr off = posOffGo arr off 0 0 0

posOffGo : Array Char -> Int -> Int -> Int -> Int -> (Int, Int)
posOffGo arr off i line lineStart
  | i >= off = (line, off - lineStart)
  | arrayGetUnsafe i arr == '\n' = posOffGo arr off (i + 1) (line + 1) (i + 1)
  | otherwise = posOffGo arr off (i + 1) line lineStart

-- A whole-source word-boundary occurrence scan: every offset where `name`
-- appears as a standalone identifier.  Returns the offsets in source order.
occurrences : String -> String -> List Int
occurrences src name =
  let arr = stringToChars src
  let len = arrayLength arr
  let nlen = stringLength name
  if nlen == 0 then [] else occGo src arr len name nlen 0

occGo : String -> Array Char -> Int -> String -> Int -> Int -> List Int
occGo src arr len name nlen i
  | i + nlen > len = []
  | windowEq src i name nlen && (i == 0 || not (isIdentChar (arrayGetUnsafe (i - 1) arr))) && (i + nlen == len || not (isIdentChar (arrayGetUnsafe (i + nlen) arr))) = i :: occGo src arr len name nlen (i + nlen)
  | otherwise = occGo src arr len name nlen (i + 1)

windowEq : String -> Int -> String -> Int -> Bool
windowEq src i name nlen = stringSlice i (i + nlen) src == name

-- documentHighlight ranges (one per occurrence) of `name` in `src`.
highlightRanges : String -> String -> List Json
highlightRanges src name =
  let arr = stringToChars src
  let nlen = stringLength name
  map (occToHighlight arr nlen) (occurrences src name)

occToHighlight : Array Char -> Int -> Int -> Json
occToHighlight arr nlen off = match posOfOffset arr off
  (sl, sc) => match posOfOffset arr (off + nlen)
    (el, ec) => jObject [("range", jRange sl sc el ec)]

-- ── textDocument/documentSymbol ─────────────────────────────────────────────
-- parseWithPositions → zip decls with their DeclPos (1-based line..end_line) →
-- one DocumentSymbol per decl: { name, kind, range, selectionRange, children }.
-- Range/selectionRange are decl-level: (line-1, 0)..(end_line-1, 0).  The
-- compiler AST is location-stripped of columns, so symbol ranges are line-
-- granular (the column-precise spans are the ELoc slice).  SymbolKind codes are
-- the LSP spec integers (Struct=23, Method=6, Field=8, Enum=10, EnumMember=22,
-- Interface=11, Class=5, Function=12, Variable=13, TypeParameter=26, Event=24).
-- Mirrors symbol_of_decl's kind mapping + child nesting.

-- Strip a DAttrib wrapper to the inner decl (mirror inner_decl).
innerDecl : Decl -> Decl
innerDecl (DAttrib _ d) = innerDecl d
innerDecl d = d

jSymbol : String -> Int -> Json -> List Json -> Json
jSymbol name kind range children = jObject
  [
    ("name", JString name),
    ("kind", JInt kind),
    ("range", range),
    ("selectionRange", range),
    ("children", jArray children),
  ]

jChild : String -> Int -> Json -> Json
jChild name kind range = jSymbol name kind range []

variantName : Variant -> String
variantName (Variant n _) = n

fieldName : Field -> String
fieldName (Field n _) = n

-- Outline children for one data variant: a nameOmitted record variant
-- (`data X = { … }`) exposes its fields as Field symbols (kind 8); any other
-- variant shows its constructor name (kind 22).
variantSymChildren : Json -> Variant -> List Json
variantSymChildren range (Variant _ (ConNamed fs True)) =
  map ((Field fn _) => jChild fn 8 range) fs
variantSymChildren range (Variant vn _) = [jChild vn 22 range]

-- The named-field labels of a variant (empty for positional variants).
variantFieldNames : Variant -> List String
variantFieldNames (Variant _ (ConNamed fs _)) = map fieldName fs
variantFieldNames (Variant _ (ConPos _)) = []

ifaceMethodName : IfaceMethod -> String
ifaceMethodName (IfaceMethod n _ _) = n

implMethodName : ImplMethod -> String
implMethodName (ImplMethod n _ _) = n

letBindName : LetBind -> String
letBindName (LetBind n _) = n

-- One DocumentSymbol JSON for a decl + its DeclPos, or None for decls that
-- don't surface in the outline (DUse).
symbolOfDecl : Decl -> DeclPos -> Option Json
symbolOfDecl d dp =
  let range = jRange (declPosLine dp - 1) 0 (declPosEndLine dp - 1) 0
  match innerDecl d
    DTypeSig _ name _ => Some (jSymbol name 13 range [])
    DExtern _ name _ => Some (jSymbol name 12 range [])
    DFunDef _ name _ _ => Some (jSymbol name 12 range [])
    DLetGroup _ binds => match binds
      [] => None
      (LetBind n0 _)::_ =>
        let kids = map ((LetBind n _) => jChild n 12 range) binds
        Some (jSymbol n0 12 range kids)
    DData _ name _ variants _ =>
      -- records (the `data X = { … }` short form, nameOmitted) expose their
      -- fields as child symbols (kind 8); ordinary variants show their ctor name.
      let kids = flatMap (variantSymChildren range) variants
      Some (jSymbol name 10 range kids)
    DInterface { name = n, methods = ms, ... } =>
      let kids = map ((IfaceMethod mn _ _) => jChild mn 6 range) ms
      Some (jSymbol n 11 range kids)
    DImpl { iface = ifc, methods = ms, ... } =>
      let label = implLabel ifc
      let kids = map ((ImplMethod mn _ _) => jChild mn 6 range) ms
      Some (jSymbol label 5 range kids)
    DTypeAlias _ name _ _ => Some (jSymbol name 26 range [])
    DNewtype _ name _ _ _ _ => Some (jSymbol name 23 range [])
    DUse _ _ _ => None
    DProp _ name _ _ => Some (jSymbol name 12 range [])
    DTest _ name _ => Some (jSymbol name 12 range [])
    DBench _ name _ => Some (jSymbol name 12 range [])
    DEffect _ name _ _ => Some (jSymbol name 24 range [])
    DAttrib _ _ => None  -- unreachable post innerDecl
-- Variable
-- Function
-- Function

-- EnumMember
-- Enum

-- Field
-- Struct

-- Interface

-- Class
-- TypeParameter
-- Struct

-- Event

-- "impl Iface" / "Name of impl Iface" label (mirror handle_document_symbol's).
implLabel : String -> String
implLabel iface = stringConcat ["impl ", iface]

-- Zip decls with positions (1:1; defensive truncation to the shorter list) and
-- collect the symbols.
documentSymbols : String -> List Json
documentSymbols src = match parseWithPositionsOpt src
  None => []
  Some (decls, positions) => symbolsZip decls (positionsDecls positions)

symbolsZip : List Decl -> List DeclPos -> List Json
symbolsZip (d::ds) (p::ps) = match symbolOfDecl d p
  None => symbolsZip ds ps
  Some s => s :: symbolsZip ds ps
symbolsZip _ _ = []

-- ── textDocument/definition ─────────────────────────────────────────────────
-- identifier-at-cursor → first decl that DEFINES that name → its DeclPos range
-- as a Location { uri, range }.  Mirror decl_defines / find_definition_loc.

declDefines : Decl -> String -> Bool
declDefines d name = match innerDecl d
  DTypeSig _ n _ => n == name
  DExtern _ n _ => n == name
  DFunDef _ n _ _ => n == name
  DLetGroup _ binds => anyName (map letBindName binds) name
  DData _ n _ vs _ => n == name
    || anyName (map variantName vs) name
    || anyName (flatMap variantFieldNames vs) name
  DInterface { name = n, methods = ms, ... } => n == name
    || anyName (map ifaceMethodName ms) name
  DImpl { methods = ms, ... } => anyName (map implMethodName ms) name
  DTypeAlias _ n _ _ => n == name
  DNewtype _ n _ c _ _ => n == name || c == name
  DUse _ _ _ => False
  DProp _ n _ _ => n == name
  DTest _ n _ => n == name
  DBench _ n _ => n == name
  DEffect _ n _ _ => n == name
  DAttrib _ _ => False

anyName : List String -> String -> Bool
anyName [] _ = False
anyName (x::xs) name = x == name || anyName xs name

-- The DeclPos of the first decl defining `name`, or None.
definitionRange : String -> String -> Option Json
definitionRange src name = match parseWithPositionsOpt src
  None => None
  Some (decls, positions) => defZip decls (positionsDecls positions) name

defZip : List Decl -> List DeclPos -> String -> Option Json
defZip (d::ds) (p::ps) name
  | declDefines d name =
    Some (jRange (declPosLine p - 1) 0 (declPosEndLine p - 1) 0)
  | otherwise = defZip ds ps name
defZip _ _ _ = None

-- ── typecheck-env build (hover / completion / inlayHint) ────────────────────
-- Mirror lib/lsp_server.ml's handlers, which run `Typecheck.check_program prog`
-- (which prepends the prelude) and look names up in the returned env.  Here the
-- self-host `checkProgram` does NOT auto-prepend, so we mirror repl.mdk's
-- pipeline (compiler/repl.mdk:221): desugar the prelude (coreSrc) + the desugared
-- user buffer, then `checkProgram (coreDecls ++ userDecls)` → the (name, Scheme)
-- env.  The runtime externs reach scope via core.mdk's own DExterns, exactly as
-- in repl (whose `checkProgram (preludeDecls ++ combined)` likewise omits a
-- separate runtime seed).  Returns None when the buffer doesn't parse (the
-- OCaml handlers bail the same way on a parse failure).
docSchemes : String -> String -> String -> Option (List (String, Scheme))
docSchemes runtimeSrc coreSrc src = match parseResult src
  Err _ => None
  Ok userRaw =>
    let runtimeDecls = desugar (unwrapDecls (parseResult runtimeSrc))
    let coreDecls = desugar (unwrapDecls (parseResult coreSrc))
    let userDecls = desugar userRaw
    Some (checkProgramSchemesWithRuntime runtimeDecls coreDecls userDecls)

-- core.mdk always parses; unwrap its parseResult (defensive None → []).
unwrapDecls : Result ParseError (List Decl) -> List Decl
unwrapDecls (Ok ds) = ds
unwrapDecls (Err _) = []

-- Lookup a name's Scheme in the env (mirror repl.mdk lookupScheme / OCaml
-- List.assoc_opt).
lookupSchemeL : String -> List (String, Scheme) -> Option Scheme
lookupSchemeL _ [] = None
lookupSchemeL name ((n, s)::rest)
  | name == n = Some s
  | otherwise = lookupSchemeL name rest

-- ── textDocument/hover ──────────────────────────────────────────────────────
-- Mirror handle_hover (lib/lsp_server.ml:482): identifier-at-cursor → checkProgram
-- env → lookup → a Hover whose contents is a Markdown MarkupContent rendering
--   ```medaka
--   <name> : <type>
--   ```
-- (exactly the OCaml format string).  Null when off an identifier or not in env.
-- Extension over the OCaml oracle: when the name isn't a top-level/global binding,
-- fall back to `localSchemesOut` (let-bound names, lambda/clause params, match
-- binders captured during the typecheck docSchemes just ran), so local variables
-- also show their inferred type on hover.
-- Produce the hover Json for the cursor position.  Resolve the identifier FIRST
-- (cheap), then build the env (potentially loading the project graph), so an
-- off-identifier hover never pays for a typecheck/load.
hoverFor : String -> String -> String -> String -> Json -> Docs -> <IO> Json
hoverFor runtimeSrc coreSrc uri src params docs = match (positionLine params, positionChar params)
  (Some line, Some col) => match identifierAt src line col
    None => JNull
    Some name => match hoverEnvFor runtimeSrc coreSrc uri src docs
      None => JNull
      Some env => match hoverScheme name env
        None => JNull
        Some sch =>
          let pfx = sigLeadingEff name (unwrapDecls (parseResult src))
          jHover name (stringConcat [pfx, ppSchemeNamed name sch])
  _ => JNull

-- The hover lookup env for the buffer.  A buffer with a non-core sibling import
-- goes through the multi-module project pipeline (loads the import graph; the
-- entry's own schemes are returned and its locals + import-scoped seed land in the
-- hover side-channels), so imported names resolve.  A single-file buffer keeps the
-- fast `docSchemes` path (core + runtime + this buffer only).
hoverEnvFor : String -> String -> String -> String -> Docs -> <IO> Option (List (String, Scheme))
hoverEnvFor runtimeSrc coreSrc uri src docs
  | bufferHasImports src = projectEntryEnv runtimeSrc coreSrc uri docs
  | otherwise = docSchemes runtimeSrc coreSrc src

-- Load the import graph rooted at this buffer (same loader/cache/read disk-
-- fallback as publishProjectDiagnostics) and return the ENTRY module's own
-- schemes.  Side effect: the entry's locals + import-scoped seed (runtime + core
-- + imported names) are left in the typecheck hover side-channels.
projectEntryEnv : String -> String -> String -> Docs -> <IO> Option (List (String, Scheme))
projectEntryEnv runtimeSrc coreSrc uri docs =
  let rootFile = pathOfUri uri
  let projectDir = findProjectRoot (dirOfPath rootFile)
  let stdlibDir = lspMedakaRoot "." ++ "/stdlib"
  let read = path => docsGet (uriOfPath path) docs
  projectEntrySchemes
    projectCache
    projectParseCache
    read
    rootFile
    [projectDir, stdlibDir]
    runtimeSrc
    coreSrc

-- Resolve a hovered name's scheme: the returned typecheck env (globals +
-- top-level) first, then the hover-only side-channels — locals (let/param/match
-- binders) and the seed (runtime.mdk externs) — neither of which the env carries.
hoverScheme : String -> List (String, Scheme) -> Option Scheme
hoverScheme name env = match lookupSchemeL name env
  Some s => Some s
  None => match lookupSchemeL name (currentLocalSchemes ())
    Some s => Some s
    None => lookupSchemeL name (currentSeedSchemes ())

-- The leading effect annotation of NAME's top-level signature, rendered as a
-- `<IO> ` prefix (trailing space), or "" if none.  `from_ast_type` drops a
-- leading `TyEffect` when building the Mono (both compilers do — it's a latent
-- computation effect, not part of the value's type), so `main : <IO> Unit`
-- otherwise renders as bare `Unit`.  Recover it from the written sig for display.
sigLeadingEff : String -> List Decl -> String
sigLeadingEff _ [] = ""
sigLeadingEff name (d::ds) = match sigLeadingEffOne name d
  Some pfx => pfx
  None => sigLeadingEff name ds

sigLeadingEffOne : String -> Decl -> Option String
sigLeadingEffOne name (DAttrib _ d) = sigLeadingEffOne name d
sigLeadingEffOne name (DTypeSig _ n ty)
  | n == name = leadingEffOf ty
  | otherwise = None
sigLeadingEffOne _ _ = None

leadingEffOf : Ty -> Option String
leadingEffOf (TyEffect labels tail _) =
  Some (stringConcat [renderEffRow labels tail, " "])
leadingEffOf _ = None

-- Render a written effect row to surface syntax: `<IO>`, `<IO, State>`,
-- `<IO | e>`, `<e>` (mirrors parser.mdk effectBody: comma-separated labels, an
-- optional `| tail` var).
renderEffRow : List (String, Option String) -> Option String -> String
renderEffRow labels tail =
  let lbls = joinWith ", " (map renderEffAtom labels)
  let body = match tail
    None => lbls
    Some v => if lbls == "" then v else stringConcat [lbls, " | ", v]
  stringConcat ["<", body, ">"]

renderEffAtom : (String, Option String) -> String
renderEffAtom (nm, None) = nm
renderEffAtom (nm, Some "_") = stringConcat [nm, " _"]
renderEffAtom (nm, Some p) = stringConcat [nm, " \"", p, "\""]

-- Build the Hover { contents: MarkupContent{ kind:"markdown", value } } object.
jHover : String -> String -> Json
jHover name ty =
  let value = stringConcat ["```medaka\n", name, " : ", ty, "\n```"]
  jObject
    [
      (
        "contents",
        jObject [("kind", JString "markdown"), ("value", JString value)],
      )
    ]

handleHover : String -> String -> Json -> Json -> Docs -> <IO> Unit
handleHover runtimeSrc coreSrc idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match docsGet uri docs
      None => JNull
      Some src => hoverFor runtimeSrc coreSrc uri src params docs
  writeMessage (responseMsg idJson result)

-- ── textDocument/completion ─────────────────────────────────────────────────
-- Mirror handle_completion (lib/lsp_server.ml:693): the identifier prefix ending
-- just before the cursor → env names with that prefix → CompletionItem[]
-- { label, kind, detail }.  kind = Function (3) for every item (OCaml's
-- completion_kind_for_scheme defaults to Function); detail = ppScheme.  Names are
-- emitted in env order, deduplicated, prefix-filtered — mirroring
-- filter_completions.
prefixBefore : String -> Int -> Int -> String
prefixBefore src line col =
  let arr = stringToChars src
  let len = arrayLength arr
  match offsetOfLineStart arr len line
    None => ""
    Some lineStart =>
      let stop = lineStart + col - 1
      if stop < lineStart then ""
      else
        if stop >= len then ""
        else
          if not (isIdentChar (arrayGetUnsafe stop arr)) then ""
          else
            let start = prefixStart arr lineStart stop
            stringSlice start (stop + 1) src

-- Byte offset of the start of 0-based `line`, or None if it doesn't exist.
offsetOfLineStart : Array Char -> Int -> Int -> Option Int
offsetOfLineStart arr len line = lineStartGo arr len 0 0 0 line

lineStartGo : Array Char -> Int -> Int -> Int -> Int -> Int -> Option Int
lineStartGo arr len i curLine lineStart line
  | curLine == line = Some lineStart
  | i >= len = None
  | arrayGetUnsafe i arr == '\n' =
    lineStartGo arr len (i + 1) (curLine + 1) (i + 1) line
  | otherwise = lineStartGo arr len (i + 1) curLine lineStart line

-- Walk left from `stop` over identifier chars, not past the line start.
prefixStart : Array Char -> Int -> Int -> Int
prefixStart arr lineStart i
  | i <= lineStart = lineStart
  | isIdentChar (arrayGetUnsafe (i - 1) arr) = prefixStart arr lineStart (i - 1)
  | otherwise = i

-- True when string n has prefix p (mirror plen==0 || prefix match).
startsWith : String -> String -> Bool
startsWith p n =
  let pl = stringLength p
  if pl == 0 then True else stringLength n >= pl && stringSlice 0 pl n == p

-- Filter env to names matching the prefix, deduplicating (first occurrence
-- wins).  Mirror filter_completions.
filterCompletions : String -> List String -> List (String, Scheme) -> List Json
filterCompletions _ _ [] = []
filterCompletions prefix seen ((n, s)::rest)
  | startsWith prefix n && not (anyName seen n) = jCompletionItem n (ppSchemeNamed n s) :: filterCompletions prefix (n::seen) rest
  | otherwise = filterCompletions prefix seen rest

-- One CompletionItem { label, kind, detail }.  kind 3 = Function (LSP spec).
jCompletionItem : String -> String -> Json
jCompletionItem label detail = jObject
  [("label", JString label), ("kind", JInt 3), ("detail", JString detail)]

completionFor : String -> String -> String -> String -> Json -> Docs -> <IO> Json
completionFor runtimeSrc coreSrc uri src params docs = match (positionLine params, positionChar params)
  (Some line, Some col) => match completionEnvFor runtimeSrc coreSrc uri src docs
    None => JNull
    Some env =>
      let prefix = prefixBefore src line col
      jArray (filterCompletions prefix [] env)
  _ => JNull

-- Completion suggests names from the env directly (no side-channel fallback like
-- hover), so for a project buffer the env must be the FULL visible set: the
-- entry's own schemes + its locals + its import-scoped seed (core + runtime +
-- imported names).  A single-file buffer keeps `docSchemes` unchanged — adding
-- the seed/locals there would change the single-file completion golden.
completionEnvFor : String -> String -> String -> String -> Docs -> <IO> Option (List (String, Scheme))
completionEnvFor runtimeSrc coreSrc uri src docs
  | bufferHasImports src = map (own => own ++ currentLocalSchemes () ++ currentSeedSchemes ()) (projectEntryEnv runtimeSrc coreSrc uri docs)
  | otherwise = docSchemes runtimeSrc coreSrc src

handleCompletion : String -> String -> Json -> Json -> Docs -> <IO> Unit
handleCompletion runtimeSrc coreSrc idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match docsGet uri docs
      None => JNull
      Some src => completionFor runtimeSrc coreSrc uri src params docs
  writeMessage (responseMsg idJson result)

-- ── textDocument/inlayHint ──────────────────────────────────────────────────
-- Mirror handle_inlay_hint (lib/lsp_server.ml:759): for each top-level decl that
-- binds a value (DFunDef, or the first name of a DLetGroup) AND has no explicit
-- DTypeSig in the program AND is in the typecheck env, emit one hint at the
-- column right after its name on its start line, labelled `: <ppScheme>` with
-- paddingLeft.  The self-host DeclPos has no column (the AST is location-
-- stripped), but every top-level decl starts at column 0, so the name-end column
-- is found by scanning the decl's start line from char 0 over identifier chars
-- (mirror column_after_name with loc.col = 0).

-- The binding name a decl introduces a value hint for, or None (mirror
-- decl_binding_name: only DFunDef + DLetGroup-first).
declBindingName : Decl -> Option String
declBindingName d = match innerDecl d
  DFunDef _ n _ _ => Some n
  DLetGroup _ binds => match binds
    (LetBind n _)::_ => Some n
    [] => None
  _ => None

-- Whether `prog` carries an explicit DTypeSig for `name` (mirror has_explicit_sig).
hasExplicitSig : List Decl -> String -> Bool
hasExplicitSig [] _ = False
hasExplicitSig (d::rest) name = match innerDecl d
  DTypeSig _ n _ => n == name || hasExplicitSig rest name
  _ => hasExplicitSig rest name

-- Column right after the name on the decl's start line (0-based `line`).  Scan
-- from char 0 over identifier chars; None if the line has no leading identifier.
columnAfterName : String -> Int -> Option Int
columnAfterName src line =
  let arr = stringToChars src
  let len = arrayLength arr
  match offsetOfLineStart arr len line
    None => None
    Some lineStart =>
      let endCol = identRunLen arr len lineStart 0
      if endCol == 0 then None else Some endCol

-- Length of the leading identifier run starting at byte `i` (stops at EOL/EOF).
identRunLen : Array Char -> Int -> Int -> Int -> Int
identRunLen arr len i acc
  | i >= len = acc
  | arrayGetUnsafe i arr == '\n' = acc
  | isIdentChar (arrayGetUnsafe i arr) = identRunLen arr len (i + 1) (acc + 1)
  | otherwise = acc

-- inlay hints for a buffer: zip parse decls with positions, filter to
-- unsignatured value bindings present in the env, place one hint each.
inlayHints : String -> String -> String -> List Json
inlayHints runtimeSrc coreSrc src = match docSchemes runtimeSrc coreSrc src
  None => []
  Some env => match parseWithPositionsOpt src
    None => []
    Some (decls, positions) =>
      inlayZip src decls decls (positionsDecls positions) env

-- decls passed twice: `allDecls` for the has-explicit-sig scan, `ds` walked.
inlayZip : String -> List Decl -> List Decl -> List DeclPos -> List (String, Scheme) -> List Json
inlayZip src allDecls (d::ds) (p::ps) env = match declBindingName d
  None => inlayZip src allDecls ds ps env
  Some name => if hasExplicitSig allDecls name then inlayZip src allDecls ds ps env
  else match lookupSchemeL name env
    None => inlayZip src allDecls ds ps env
    Some sch => match columnAfterName src (declPosLine p - 1)
      None => inlayZip src allDecls ds ps env
      Some col => jInlayHint (declPosLine p - 1) col (stringConcat [": ", ppSchemeNamed name sch]) :: inlayZip src allDecls ds ps env
inlayZip _ _ _ _ _ = []

-- One InlayHint { position, label, paddingLeft } (mirror the OCaml create).
jInlayHint : Int -> Int -> String -> Json
jInlayHint line col label = jObject
  [
    ("position", jPosition line col),
    ("label", JString label),
    ("paddingLeft", JBool True),
  ]

handleInlayHint : String -> String -> Json -> Json -> Docs -> <IO> Unit
handleInlayHint runtimeSrc coreSrc idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match docsGet uri docs
      None => JNull
      Some src => jArray (inlayHints runtimeSrc coreSrc src)
  writeMessage (responseMsg idJson result)

-- ── request-position helpers ────────────────────────────────────────────────
-- Pull params.position.{line,character} (0-based) from a request message.
positionLine : Json -> Option Int
positionLine params = match lookup "position" params
  Some pos => match lookup "line" pos
    Some v => asInt v
    None => None
  None => None

positionChar : Json -> Option Int
positionChar params = match lookup "position" params
  Some pos => match lookup "character" pos
    Some v => asInt v
    None => None
  None => None

-- params.textDocument.uri for a request.
requestUri : Json -> Option String
requestUri params = fieldStr "uri" (fieldOr "textDocument" params)

-- ── logging (crash diagnosis) ───────────────────────────────────────────────
--
-- Append-only session log so an unrecoverable panic leaves the CRASHING message
-- as the last line: each incoming body is logged BEFORE dispatch, and a
-- "handled" marker is logged AFTER dispatch returns.  A `recv` with no following
-- `handled` ⇒ the panic was in that message's dispatch.  Path: $MEDAKA_LSP_LOG,
-- else /tmp/medaka-lsp.log.  appendFile opens/appends/closes each call, so every
-- line is durable before the next step (no buffering to strand a pre-crash
-- entry).  Always on during the soak/dev phase; gate behind an env flag if noisy.
-- Each line is prefixed with the wall-clock epoch seconds (`wallTimeSec`, native
-- since the extern was wired) so log entries correlate to when a crash happened.
logFilePath : Unit -> <IO> String
logFilePath _ = match getEnv "MEDAKA_LSP_LOG"
  Some v => if v == "" then "/tmp/medaka-lsp.log" else v
  None => "/tmp/medaka-lsp.log"

logLine : String -> <IO> Unit
logLine s =
  let ts = wallTimeSec ()
  let _ = appendFile (logFilePath ()) (stringConcat [floatToString ts, " ", s, "\n"])
  ()

-- ── JSON-RPC framing ────────────────────────────────────────────────────────

-- Write a JSON value as a Content-Length-framed JSON-RPC packet to stdout,
-- then flush (the buffered stdout would otherwise strand the response).
writeMessage : Json -> <IO> Unit
writeMessage j =
  let body = stringify j
  let n = utf8Len body
  let header = stringConcat ["Content-Length: ", intToString n, "\r\n\r\n"]
  let _ = putStr header
  let _ = putStr body
  flushStdout ()

-- Content-Length counts BYTES on the wire, but `stringLength` counts Unicode
-- CODEPOINTS.  Medaka source routinely carries multibyte UTF-8 (em-dashes,
-- arrows, box-drawing in comments), and any response embedding that text (a
-- diagnostic, a documentSymbol body) would otherwise under-declare its length —
-- the client then reads too few bytes and the frame boundary slips ("Header must
-- provide a Content-Length property", server shutdown).  utf8Len / utf8CharWidth
-- moved to support/util.mdk (imported above).

-- A JSON-RPC response envelope: { jsonrpc, id, result }.
responseMsg : Json -> Json -> Json
responseMsg idJson result =
  jObject [("jsonrpc", JString "2.0"), ("id", idJson), ("result", result)]

-- A JSON-RPC notification envelope: { jsonrpc, method, params }.
notificationMsg : String -> Json -> Json
notificationMsg meth params = jObject
  [("jsonrpc", JString "2.0"), ("method", JString meth), ("params", params)]

-- ── header reading ──────────────────────────────────────────────────────────
--
-- Read header lines via readLineOpt until a blank line, accumulating the
-- Content-Length.  readLineOpt strips the trailing '\n'; a CRLF line therefore
-- arrives as "...\r", so we trim a trailing '\r'.  Returns the byte length, or
-- None at EOF (clean shutdown of the input stream).

public export data Headers = Headers Int

readHeaders : Int -> <IO> Option Int
readHeaders lenAcc = match readLineOpt ()
  None => None
  Some raw =>
    let line = stripCR raw
    if line == "" then Some lenAcc
    else
      let lenAcc2 = match parseContentLength line
        Some n => n
        None => lenAcc
      readHeaders lenAcc2
-- EOF mid-stream

-- blank line ends the header block

-- Parse "Content-Length: <n>" (case-sensitive, as clients emit it).  Returns
-- the integer N or None if this header line is something else.
parseContentLength : String -> Option Int
parseContentLength line =
  let prefix = "Content-Length:"
  let pn = stringLength prefix
  if stringLength line >= pn && stringSlice 0 pn line == prefix then
    parseDigits (stringToChars (stringSlice pn (stringLength line) line)) 0 (arrayLength (stringToChars (stringSlice pn (stringLength line) line))) 0 False
  else
    None

-- Parse a run of ASCII digits (skipping leading spaces) into an Int.  `seen`
-- tracks whether at least one digit was consumed.
parseDigits : Array Char -> Int -> Int -> Int -> Bool -> Option Int
parseDigits arr i n acc seen
  | i >= n = if seen then Some acc else None
  | arrayGetUnsafe i arr == ' ' && not seen = parseDigits arr (i + 1) n acc seen
  | isDigit (arrayGetUnsafe i arr) = parseDigits arr (i + 1) n (acc * 10 + (charCode (arrayGetUnsafe i arr) - 48)) True
  | otherwise = if seen then Some acc else None

{- ── textDocument/semanticTokens/full ────────────────────────────────────────

   Lexer-driven semantic highlighting.  The TextMate grammar in the VSCode
   extension is regex and can't parse, so the SAME type name colors
   inconsistently (e.g. in `f : List (Expr, Expr) -> Expr` the comma-followed
   `Expr` is mis-scoped vs the trailing one).  The lexer already disambiguates
   `TUpper` (type) from `TIdent` (variable), so server-emitted semantic tokens
   fix it deterministically.

   Legend (index = the `tokenType` int on the wire — keep in lockstep with
   `semanticLegend` / `semanticTokensOptions`):
     0 keyword  1 type  2 function  3 variable  4 string  5 number  6 operator

   Positions: `tokenizeWithOffsetPairs` gives each token a (startByte, endByte)
   char-offset pair; synthetic layout tokens (NEWLINE/INDENT/DEDENT/EOF) carry an
   EMPTY span (start == end) and are filtered.  `posOfOffset` turns an offset into
   a 0-based (line, char) — codepoint-based, which equals UTF-16 for BMP chars
   (incl. em-dashes); only astral/emoji positions would differ (DEFERRED — see
   the multiline/astral note in `semTokenLen`).  The wire format is delta-encoded:
   5 ints per token `[deltaLine, deltaChar, length, tokenType, tokenModifiers]`,
   tokens in start order (the lexer stream already is). -}

-- The legend, in index order.  These are standard semantic-token scope names;
-- the THEME maps them to colors.  Two are chosen for hue, not literal meaning, so
-- roles get real contrast in Cursor Dark (the most common case):
--   * type names → `class` (entity.name.type.class = blue #87c3ff), since plain
--     `type` shares the warm hue of `function` and would be indistinguishable.
--   * constructors → `macro` (#a8cc7c green), since `enumMember` is a near-default
--     light grey (#d6d6dd) that reads as plain text.
--   * typeclasses (interfaces) → `selfParameter` (#cc7c8a rose), so they read apart
--     from plain types (blue); `interface`/`enum` fall back to the warm `type` hue.
--   0 keyword  1 class(type)  2 macro(constructor)  3 function  4 property(field)
--   5 string   6 number  7 selfParameter(typeclass/interface)
semanticLegend : List String
semanticLegend = [
  "keyword",
  "class",
  "macro",
  "function",
  "property",
  "string",
  "number",
  "selfParameter",
]

semanticTokensOptions : Json
semanticTokensOptions = jObject
  [
    (
      "legend",
      jObject [
        ("tokenTypes", jArray (map JString semanticLegend)),
        ("tokenModifiers", jArray []),
      ],
    ),
    ("full", JBool True),
  ]

{- Token → semantic role, threaded with a small syntactic CONTEXT so the same
   token SHAPE colors by ROLE: an uppercase name is a `type` in type position but
   an `enumMember` (constructor) in expression/pattern position; a lowercase name
   is a `function` only at a definition head (top-level, line start) — references,
   locals and params stay default foreground.  No AST/parse is needed (the AST has
   no per-occurrence spans) and no parser changes: a single ordered pass over the
   token stream tracks indent depth, line-start, and a type/expr/data/record mode.
   Layout tokens (NEWLINE/INDENT/DEDENT) carry the depth/line-start signal and emit
   no token.  Robust on unparseable buffers (pure token walk). -}

-- Decides how an uppercase name (and record fields) is colored at this point.
data SMode =
  | MExpr
  | MType
  | MDataHead
  | MDataVariant
  | MDataPayload
  | MRecord
  | MIfaceOne
  | MIfaceMany

-- depth (indent nesting; 0 = top level), lineStart (next token begins a logical
-- line), mode.
data SemCtx = SemCtx Int Bool SMode

isKeywordTok : Token -> Bool
isKeywordTok TLet = True
isKeywordTok TRec = True
isKeywordTok TWith = True
isKeywordTok TMut = True
isKeywordTok TIn = True
isKeywordTok TIf = True
isKeywordTok TThen = True
isKeywordTok TElse = True
isKeywordTok TMatch = True
isKeywordTok TData = True
isKeywordTok TRecord = True
isKeywordTok TInterface = True
isKeywordTok TDefault = True
isKeywordTok TImpl = True
isKeywordTok TImport = True
isKeywordTok TExport = True
isKeywordTok TPublic = True
isKeywordTok TWhere = True
isKeywordTok TOf = True
isKeywordTok TRequires = True
isKeywordTok TDo = True
isKeywordTok TAs = True
isKeywordTok TExtern = True
isKeywordTok TDeriving = True
isKeywordTok TType = True
isKeywordTok TNewtype = True
isKeywordTok TProp = True
isKeywordTok TTest = True
isKeywordTok TBench = True
isKeywordTok TEffect = True
isKeywordTok TFunction = True
isKeywordTok _ = False

-- An uppercase name's role given the current mode: constructor in expr/variant
-- position, type otherwise.
upperRole : SMode -> Int
upperRole MExpr = 2
upperRole MDataVariant = 2
upperRole _ = 1

-- The legend index for a token (None = leave default fg), given depth/lineStart/mode.
roleOf : Token -> Int -> Bool -> SMode -> Option Int
roleOf (TUpper _) _ _ MIfaceOne = Some 7  -- interface/impl name → typeclass
roleOf (TUpper _) _ _ MIfaceMany = Some 7  -- requires/deriving names → typeclass
roleOf (TUpper _) _ _ mode = Some (upperRole mode)
roleOf (TIdent _) depth lineStart mode =
  if lineStart && (depth == 0) then Some 3      -- top-level definition head
  else match mode
    MRecord => Some 4                            -- record field name
    _ => None                                    -- local / param / reference
roleOf (TBacktickIdent _) _ _ _ = Some 3
roleOf (TString _) _ _ _ = Some 5
roleOf (TChar _) _ _ _ = Some 5
roleOf (TInterpOpen _) _ _ _ = Some 5
roleOf (TInterpMid _) _ _ _ = Some 5
roleOf (TInterpEnd _) _ _ _ = Some 5
roleOf (TInt _) _ _ _ = Some 6
roleOf (TFloat _) _ _ _ = Some 6
roleOf (TBool _) _ _ _ = Some 0
roleOf t _ _ _ = if isKeywordTok t then Some 0 else None

-- The mode AFTER consuming a token.
nextMode : Token -> SMode -> SMode
nextMode TData _ = MDataHead
nextMode TNewtype _ = MDataHead
nextMode TRecord _ = MRecord
nextMode TInterface _ = MIfaceOne
nextMode TImpl _ = MIfaceOne
nextMode TRequires _ = MIfaceMany
nextMode TDeriving _ = MIfaceMany
nextMode TExtern _ = MType
nextMode TType _ = MType
nextMode TOf _ = MType
nextMode TWhere _ = MExpr
nextMode (TUpper _) MIfaceOne = MType
nextMode TColon MRecord = MRecord
nextMode TColon _ = MType
nextMode TEqual MDataHead = MDataVariant
nextMode TEqual MRecord = MRecord
nextMode TEqual _ = MExpr
nextMode TPipe MDataVariant = MDataVariant
nextMode TPipe MDataPayload = MDataVariant
nextMode (TUpper _) MDataVariant = MDataPayload
nextMode _ mode = mode

{- A classified token ready for delta-encoding: absolute 0-based line + char,
   UTF-16 length, and the legend index. -}
public export data SemTok = SemTok Int Int Int Int

-- Classify one token: its role (None = emit nothing) + the updated context.
-- Layout tokens update depth/line-start; a real token may flip the mode and
-- always clears line-start.
classify : Token -> SemCtx -> (Option Int, SemCtx)
classify TIndent (SemCtx depth ls mode) = (None, SemCtx (depth + 1) ls mode)
classify TDedent (SemCtx depth ls mode) = (None, SemCtx (depth - 1) ls mode)
classify TNewline (SemCtx depth _ mode) =
  let mode2 = if depth <= 0 then MExpr else mode
  (None, SemCtx depth True mode2)
classify tok (SemCtx depth ls mode) =
  (roleOf tok depth ls mode, SemCtx depth False (nextMode tok mode))

{- Build the absolute SemTok list, threading the context.  Filters tokens with no
   role, empty/synthetic spans (start == end), and any token straddling a line
   boundary (LSP forbids multi-line tokens; only a triple-quoted string could, and
   those stay with TextMate). -}
semToksOf : Array Char -> List Token -> List (Int, Int) -> SemCtx -> List SemTok
semToksOf _ [] _ _ = []
semToksOf _ _ [] _ = []
semToksOf arr (t::ts) ((s, e)::ps) ctx = match classify t ctx
  (roleOpt, ctx2) => match roleOpt
    None => semToksOf arr ts ps ctx2
    Some ty => if s >= e then semToksOf arr ts ps ctx2
    else match (posOfOffset arr s, posOfOffset arr e)
      ((sl, sc), (el, ec)) =>
        if sl == el then
          SemTok sl sc (ec - sc) ty :: semToksOf arr ts ps ctx2
        else
          semToksOf arr ts ps ctx2

{- Delta-encode the (start-ordered) SemTok list into the flat 5-int LSP array.
   prevLine/prevChar start at 0, so the first token's deltaLine is its absolute
   line; deltaChar is relative to prevChar only when deltaLine == 0. -}
encodeSemToks : Int -> Int -> List SemTok -> List Int
encodeSemToks _ _ [] = []
encodeSemToks prevLine prevChar ((SemTok line ch len ty)::rest) =
  let dLine = line - prevLine
  let dChar = if dLine == 0 then ch - prevChar else ch
  dLine :: dChar :: len :: ty :: 0 :: encodeSemToks line ch rest

-- The full semantic-tokens `data` array (flat ints) for a source string.
semanticTokensData : String -> List Int
semanticTokensData src =
  let arr = stringToChars src
  match tokenizeWithOffsetPairs src
    (toks, pairs) =>
      encodeSemToks 0 0 (semToksOf arr toks pairs (SemCtx 0 True MExpr))

-- ── request dispatch ────────────────────────────────────────────────────────
--
-- The driver loops: read headers → read body → parse JSON → dispatch.  The
-- state threaded through the loop is the Docs store; the runtime/core prelude
-- sources are constants for the session.

-- The `initialize` result: serverInfo + the B.10 capability set.
-- textDocumentSync = 1 (Full).  B.10.3 adds the decl/textual providers:
-- formatting / documentSymbol / definition / documentHighlight (each a plain
-- `true`, mirroring lib/lsp_server.ml's `Bool true`).  The richer providers
-- (hover/completion/inlayHint) and ELoc expr-precise ranges are later slices.
initializeResult : Json
initializeResult = jObject
  [
    (
      "capabilities",
      jObject [
        ("textDocumentSync", JInt 1),
        ("documentFormattingProvider", JBool True),
        ("documentSymbolProvider", JBool True),
        ("definitionProvider", JBool True),
        ("documentHighlightProvider", JBool True),
        ("hoverProvider", JBool True),
        ("completionProvider", jObject []),
        ("inlayHintProvider", JBool True),
        ("semanticTokensProvider", semanticTokensOptions),
      ],
    ),
    (
      "serverInfo",
      jObject [("name", JString "medaka-lsp"), ("version", JString "0.1.0")],
    ),
  ]

-- Build + send a publishDiagnostics notification for one uri.
publishDiagnostics : String -> String -> String -> String -> <IO> Unit
publishDiagnostics runtimeSrc coreSrc uri src =
  let diags = diagnosticsFor runtimeSrc coreSrc src
  let params = jObject [("uri", JString uri), ("diagnostics", jArray diags)]
  writeMessage (notificationMsg "textDocument/publishDiagnostics" params)

-- ── B.10.5: project-wide (multi-file) diagnostics ───────────────────────────
--
-- When the edited buffer imports a sibling module, run analyzeProject over the
-- whole import graph (with the OPEN BUFFERS as unsaved-source overrides) and
-- publish one publishDiagnostics PER affected file — the self-hosted analog of
-- lib/lsp_server.ml's publish_project_diagnostics.  A buffer with no (non-core)
-- imports keeps the single-document path (publishDiagnostics above).
--
-- Simplifications vs the OCaml LSP (consistent with the single-root compiler
-- loader, which has no medaka.toml / multi-root support — see loader.mdk):
--   * project_dir = the DIRECTORY OF THE EDITED FILE (the loader's default root),
--     not a medaka.toml / .git walk-up (no Project_config port in compiler).
--   * last-good source cache is a SESSION-LIVED module Ref (projectCache), so a
--     buffer that currently fails to parse falls back to its last-parsed source
--     across didChange events (mirror analyze_project's last_good_source Hashtbl)
--     without threading extra state through the serve loop.

-- session-lived last-good-source cache (file path → last source that parsed).
projectCache : Ref (List (String, String))
projectCache = Ref []

-- session-lived parse memo (source string → located decls): lets an import-bearing
-- buffer's UNCHANGED dependency modules skip re-parsing on every didChange (the
-- ~80% cost of an import-bearing keystroke — see driver.loader.parseCachedLocated).
-- Shared by the diagnostics path AND the project-aware hover/completion path so
-- both reuse the same parsed deps.  Source-keyed (pure parse ⇒ equal source ⇒ equal
-- decls), bounded inside loadProgramFilesLocatedCached.
projectParseCache : Ref (List (String, List Decl))
projectParseCache = Ref []

-- file:// URI ↔ filesystem path.  LSP clients send `file://<abs-path>`; the
-- loader works in plain paths.  pathOfUri strips the scheme; uriOfPath re-adds
-- it (so a loader file path maps back to the Docs key for the read override).
pathOfUri : String -> String
pathOfUri uri =
  if stringLength uri >= 7 && stringSlice 0 7 uri == "file://" then
    stringSlice 7 (stringLength uri) uri
  else
    uri

uriOfPath : String -> String
uriOfPath path =
  if stringLength path >= 7 && stringSlice 0 7 path == "file://" then
    path
  else
    stringConcat ["file://", path]

-- directory of a path (everything before the last '/'; "." if none).
dirOfPath : String -> String
dirOfPath path = dirGo path (stringLength path)

dirGo : String -> Int -> String
dirGo path 0 = "."
-- Intentional cross-file duplicate of the same helper in path.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
dirGo path i =
  if stringSlice (i - 1) i path == "/" then
    stringSlice 0 (i - 1) path
  else
    dirGo path (i - 1)

-- True when the buffer has a non-core `import` (→ project / multi-file path).
bufferHasImports : String -> Bool
bufferHasImports src = match parseResult src
  Err _ => False
  Ok decls => anyImport decls
-- unparseable → single-doc path squiggles it

anyImport : List Decl -> Bool
anyImport [] = False
anyImport ((DUse _ path _)::rest) = not (isCoreImport path) || anyImport rest
anyImport (_::rest) = anyImport rest

-- core is the implicit prelude — an `import core.{…}` is not a sibling dep.
isCoreImport : UsePath -> Bool
isCoreImport p = useHead p == "core"

useHead : UsePath -> String
useHead (UseName ns) = headOr "" ns
useHead (UseGroup ns _) = headOr "" ns
useHead (UseWild ns) = headOr "" ns
useHead (UseAlias ns _) = headOr "" ns

headOr : String -> List String -> String
headOr d [] = d
headOr _ (x::_) = x

-- Run analyzeProject over the graph rooted at the edited file and publish one
-- notification per file in the result (clean files → []).  `docs` already holds
-- the just-edited buffer; the read override maps a loader file path back to the
-- Docs buffer for that uri (unsaved buffers shadow disk).
--
-- Roots mirror the build/run loader (`medaka_cli` runRunCmd): the edited file's
-- directory first (user modules shadow stdlib), then MEDAKA_ROOT/stdlib so an
-- `import json` / other stdlib module resolves (without this, a buffer importing
-- a stdlib module reports a spurious `UnknownModule`).
publishProjectDiagnostics : String -> String -> String -> Docs -> <IO> Unit
publishProjectDiagnostics runtimeSrc coreSrc uri docs =
  let rootFile = pathOfUri uri
  let projectDir = findProjectRoot (dirOfPath rootFile)
  let stdlibDir = lspMedakaRoot "." ++ "/stdlib"
  let read = path => docsGet (uriOfPath path) docs
  let results = analyzeProject projectCache projectParseCache read rootFile [projectDir, stdlibDir] runtimeSrc coreSrc
  publishEach results
-- Module root = nearest ancestor with medaka.toml (NOT the file's own dir), so
-- a nested module's imports (rooted at the project dir) resolve.  Falls back to
-- the file's dir when there's no medaka.toml.

-- MEDAKA_ROOT (where stdlib/ lives), or `dflt` when unset/empty.  Mirrors
-- build_cmd.envOr but kept local so the LSP graph doesn't pull in build_cmd.
lspMedakaRoot : String -> <IO> String
lspMedakaRoot dflt = match getEnv "MEDAKA_ROOT"
  Some v => if v == "" then dflt else v
  None => dflt

-- Publish a publishDiagnostics notification for each (file, diags) bucket,
-- mapping the loader file path back to a file:// uri (mirror DocumentUri.of_path).
publishEach : List (String, List Diag) -> <IO> Unit
publishEach [] = ()
publishEach ((file, ds)::rest) =
  let uri = uriOfPath file
  let params = jObject [("uri", JString uri), ("diagnostics", jArray (map (diagToJson "") ds))]
  let _ = writeMessage (notificationMsg "textDocument/publishDiagnostics" params)
  publishEach rest

-- Choose the single-document or project path for a freshly-edited buffer.
publishFor : String -> String -> String -> String -> Docs -> <IO> Unit
publishFor runtimeSrc coreSrc uri text docs =
  if bufferHasImports text then
    publishProjectDiagnostics runtimeSrc coreSrc uri docs
  else
    publishDiagnostics runtimeSrc coreSrc uri text

-- Extract a textDocument/{didOpen,didChange} uri + text and publish.
-- didOpen:   params.textDocument.{uri,text}
-- didChange: params.textDocument.uri + params.contentChanges[last].text
--            (Full sync: the last change replaces the whole document).
handleDidOpen : String -> String -> Json -> Docs -> <IO> Docs
handleDidOpen runtimeSrc coreSrc params docs = match fieldStr "uri" (fieldOr "textDocument" params)
  None => docs
  Some uri => match fieldStr "text" (fieldOr "textDocument" params)
    None => docs
    Some text =>
      let docs2 = docsPut uri text docs
      let _ = publishFor runtimeSrc coreSrc uri text docs2
      docs2

handleDidChange : String -> String -> Json -> Docs -> <IO> Docs
handleDidChange runtimeSrc coreSrc params docs = match fieldStr "uri" (fieldOr "textDocument" params)
  None => docs
  Some uri => match lastChangeText (fieldOr "contentChanges" params)
    None => docs
    Some text =>
      let docs2 = docsPut uri text docs
      let _ = publishFor runtimeSrc coreSrc uri text docs2
      docs2

-- ── B.10.3 request handlers ─────────────────────────────────────────────────
-- Each looks the doc up in the store and writes a JSON-RPC response.  A missing
-- doc / no-identifier-at-cursor yields the LSP "no result" — JNull (mirroring
-- the OCaml handlers returning None, which the rpc layer renders as null).

-- textDocument/formatting → TextEdit[] (or [] when already formatted).
handleFormatting : Json -> Json -> Docs -> <IO> Unit
handleFormatting idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match docsGet uri docs
      None => JNull
      Some src => jArray (formattingEdits src)
  writeMessage (responseMsg idJson result)

-- textDocument/documentSymbol → DocumentSymbol[].
handleDocumentSymbol : Json -> Json -> Docs -> <IO> Unit
handleDocumentSymbol idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match docsGet uri docs
      None => JNull
      Some src => jArray (documentSymbols src)
  writeMessage (responseMsg idJson result)

-- textDocument/definition → Location[] (singleton) or null.
handleDefinition : Json -> Json -> Docs -> <IO> Unit
handleDefinition idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match docsGet uri docs
      None => JNull
      Some src => definitionResult uri src params
  writeMessage (responseMsg idJson result)

definitionResult : String -> String -> Json -> Json
definitionResult uri src params = match (positionLine params, positionChar params)
  (Some line, Some col) => match identifierAt src line col
    None => JNull
    Some name => match definitionRange src name
      None => JNull
      Some range => jArray [jObject [("uri", JString uri), ("range", range)]]
  _ => JNull

-- textDocument/documentHighlight → DocumentHighlight[].
handleHighlight : Json -> Json -> Docs -> <IO> Unit
handleHighlight idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match docsGet uri docs
      None => JNull
      Some src => highlightResult src params
  writeMessage (responseMsg idJson result)

highlightResult : String -> Json -> Json
highlightResult src params = match (positionLine params, positionChar params)
  (Some line, Some col) => match identifierAt src line col
    None => JNull
    Some name => jArray (highlightRanges src name)
  _ => JNull

-- textDocument/semanticTokens/full → { data: [int] } (delta-encoded).
handleSemanticTokens : Json -> Json -> Docs -> <IO> Unit
handleSemanticTokens idJson params docs =
  let result = match requestUri params
    None => JNull
    Some uri => match docsGet uri docs
      None => JNull
      Some src => jObject [("data", jArray (map JInt (semanticTokensData src)))]
  writeMessage (responseMsg idJson result)

-- The `.text` of the LAST element of a contentChanges JArray (Full sync).
lastChangeText : Json -> Option String
lastChangeText (JArray arr)
  | arrayLength arr == 0 = None
  | otherwise = fieldStr "text" (arrayGetUnsafe (arrayLength arr - 1) arr)
lastChangeText _ = None

-- json field accessors specialized to the shapes we read.
fieldOr : String -> Json -> Json
fieldOr key j = match lookup key j
  Some v => v
  None => JNull

fieldStr : String -> Json -> Option String
fieldStr key j = match lookup key j
  Some v => asString v
  None => None

-- The request `id` (number or string), passed through verbatim into responses.
-- We keep it as the raw Json so a string id round-trips unchanged.
requestId : Json -> Json
requestId msg = fieldOr "id" msg

methodOf : Json -> Option String
methodOf msg = fieldStr "method" msg

-- Dispatch one decoded message.  Returns the (possibly updated) Docs store and
-- a flag: True = keep looping, False = `exit` was received (stop).
public export data Step = Step Docs Bool

dispatch : String -> String -> Json -> Docs -> <IO> Step
dispatch runtimeSrc coreSrc msg docs = match methodOf msg
  None => Step docs True
  Some meth => if meth == "initialize" then
    let _ = writeMessage (responseMsg (requestId msg) initializeResult)
    Step docs True
  else
    if meth == "initialized" then Step docs True
    else
      if meth == "textDocument/didOpen" then
        let docs2 = handleDidOpen runtimeSrc coreSrc (fieldOr "params" msg) docs
        Step docs2 True
      else
        if meth == "textDocument/didChange" then
          let docs2 = handleDidChange runtimeSrc coreSrc (fieldOr "params" msg) docs
          Step docs2 True
        else
          if meth == "textDocument/formatting" then
            let _ = handleFormatting (requestId msg) (fieldOr "params" msg) docs
            Step docs True
          else
            if meth == "textDocument/documentSymbol" then
              let _ = handleDocumentSymbol (requestId msg) (fieldOr "params" msg) docs
              Step docs True
            else
              if meth == "textDocument/definition" then
                let _ = handleDefinition (requestId msg) (fieldOr "params" msg) docs
                Step docs True
              else
                if meth == "textDocument/documentHighlight" then
                  let _ = handleHighlight (requestId msg) (fieldOr "params" msg) docs
                  Step docs True
                else
                  if meth == "textDocument/hover" then
                    let _ = handleHover runtimeSrc coreSrc (requestId msg) (fieldOr "params" msg) docs
                    Step docs True
                  else
                    if meth == "textDocument/completion" then
                      let _ = handleCompletion runtimeSrc coreSrc (requestId msg) (fieldOr "params" msg) docs
                      Step docs True
                    else
                      if meth == "textDocument/inlayHint" then
                        let _ = handleInlayHint runtimeSrc coreSrc (requestId msg) (fieldOr "params" msg) docs
                        Step docs True
                      else
                        if meth == "textDocument/semanticTokens/full" then
                          let _ = handleSemanticTokens (requestId msg) (fieldOr "params" msg) docs
                          Step docs True
                        else
                          if meth == "shutdown" then
                            let _ = writeMessage (responseMsg (requestId msg) JNull)
                            Step docs True
                          else
                            if meth == "exit" then
                              let _ = logLine "exit (clean shutdown)"
                              Step docs False
                            else Step docs True  -- unrecognized method — ignore
-- a response/unknown — ignore, keep going

-- stop the loop

-- ── the framed read/dispatch loop ───────────────────────────────────────────

-- Read one full message (headers + body), parse it, dispatch.  Returns the
-- next Step, or a terminal Step on EOF.
serveOnce : String -> String -> Docs -> <IO> Step
serveOnce runtimeSrc coreSrc docs = match readHeaders 0
  None => Step docs False
  Some len => match readExactly len
    None => Step docs False
    Some body =>
      let _ = logLine (stringConcat ["recv ", body])
      match parse body
        Err _ =>
          let _ = logLine "  parse-error: malformed JSON body (skipped)"
          Step docs True
        Ok msg =>
          let step = dispatch runtimeSrc coreSrc msg docs
          let _ = logLine "  handled"
          step
-- input stream closed

-- short read / EOF mid-body

-- malformed JSON body — skip, keep going

-- The session loop: serve messages until `exit` or EOF.
serve : String -> String -> Docs -> <IO> Unit
serve runtimeSrc coreSrc docs = match serveOnce runtimeSrc coreSrc docs
  Step _ False => unit
  Step docs2 True => serve runtimeSrc coreSrc docs2

-- Public entry point for the driver.
export runServer : String -> String -> <IO> Unit
runServer runtimeSrc coreSrc =
  let _ = logLine "=== medaka-lsp session start ==="
  serve runtimeSrc coreSrc emptyDocs

unit : Unit
unit = ()
# DESUGAR
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JNull" false) (mem "JBool" false) (mem "JInt" false) (mem "JString" false) (mem "JArray" false) (mem "JObject" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false) (mem "lookup" false) (mem "asString" false) (mem "asInt" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" false) (mem "Severity" false) (mem "SevError" false) (mem "SevWarning" false) (mem "analyzeLocated" false) (mem "analyzeProject" false) (mem "projectEntrySchemes" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "findProjectRoot" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "ParseError" false) (mem "parseResult" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false) (mem "parseWithPositions" false) (mem "parseWithPositionsOpt" false) (mem "positionsDecls" false) (mem "DeclPos" false) (mem "declPosLine" false) (mem "declPosEndLine" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Token" true) (mem "tokenizeWithOffsetPairs" false))))
(DUse false (UseGroup ("support" "char") ((mem "isIdentChar" false) (mem "isDigit" false))))
(DUse false (UseGroup ("support" "util") ((mem "maxI" false) (mem "utf8Len" false) (mem "joinWith" false))))
(DUse false (UseGroup ("io") ((mem "stripCR" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "checkProgramSchemes" false) (mem "checkProgramSchemesWithRuntime" false) (mem "ppSchemeNamed" false) (mem "Scheme" true) (mem "currentLocalSchemes" false) (mem "currentSeedSchemes" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSource" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DTypeSig" false) (mem "DExtern" false) (mem "DFunDef" false) (mem "DData" false) (mem "DUse" false) (mem "DEffect" false) (mem "DProp" false) (mem "DTest" false) (mem "DBench" false) (mem "DInterface" false) (mem "DImpl" false) (mem "DTypeAlias" false) (mem "DNewtype" false) (mem "DLetGroup" false) (mem "DAttrib" false) (mem "Ty" false) (mem "TyEffect" false) (mem "Loc" true) (mem "Variant" false) (mem "ConPayload" true) (mem "Field" false) (mem "IfaceMethod" false) (mem "ImplMethod" false) (mem "LetBind" false) (mem "UsePath" false) (mem "UseName" false) (mem "UseGroup" false) (mem "UseWild" false) (mem "UseAlias" false))))
(DData Public "Docs" () ((variant "Docs" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))) ())
(DTypeSig false "emptyDocs" (TyCon "Docs"))
(DFunDef false "emptyDocs" () (EApp (EVar "Docs") (EListLit)))
(DTypeSig false "docsPut" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyCon "Docs")))))
(DFunDef false "docsPut" ((PVar "uri") (PVar "src") (PCon "Docs" (PVar "xs"))) (EApp (EVar "Docs") (EBinOp "::" (ETuple (EVar "uri") (EVar "src")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "xs")))))
(DTypeSig false "docsRemove" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "docsRemove" (PWild (PList)) (EListLit))
(DFunDef false "docsRemove" ((PVar "uri") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "uri")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "jPosition" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "jPosition" ((PVar "line") (PVar "ch")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "ch"))))))
(DTypeSig false "jRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))))
(DFunDef false "jRange" ((PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "start")) (EApp (EApp (EVar "jPosition") (EVar "sl")) (EVar "sc"))) (ETuple (ELit (LString "end")) (EApp (EApp (EVar "jPosition") (EVar "el")) (EVar "ec"))))))
(DTypeSig false "jDiagnostic" (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "jDiagnostic" ((PVar "sev") (PVar "range") (PVar "msg")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EVar "range")) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (EVar "sev"))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "msg"))))))
(DTypeSig false "severityCode" (TyFun (TyCon "Severity") (TyCon "Int")))
(DFunDef false "severityCode" ((PCon "SevError")) (ELit (LInt 1)))
(DFunDef false "severityCode" ((PCon "SevWarning")) (ELit (LInt 2)))
(DTypeSig false "countLines" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "countLines" ((PVar "src")) (EApp (EApp (EApp (EVar "countLinesGo") (EApp (EVar "stringToChars") (EVar "src"))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "countLinesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "countLinesGo" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EVar "countLinesGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "countLinesGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "wholeDocRange" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "wholeDocRange" ((PVar "src")) (EApp (EApp (EApp (EApp (EVar "jRange") (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "countLines") (EVar "src"))) (ELit (LInt 0))))
(DTypeSig false "rangeOfLoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Json"))))
(DFunDef false "rangeOfLoc" ((PVar "src") (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EApp (EApp (EApp (EApp (EVar "jRange") (EBinOp "-" (EVar "sl") (ELit (LInt 1)))) (EVar "sc")) (EBinOp "-" (EVar "el") (ELit (LInt 1)))) (EVar "ec")))
(DFunDef false "rangeOfLoc" ((PVar "src") (PCon "None")) (EApp (EVar "wholeDocRange") (EVar "src")))
(DTypeSig false "diagToJson" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "Json"))))
(DFunDef false "diagToJson" ((PVar "src") (PCon "Diag" (PVar "sev") PWild (PVar "msg") (PVar "loc") PWild PWild)) (EApp (EApp (EApp (EVar "jDiagnostic") (EApp (EVar "severityCode") (EVar "sev"))) (EApp (EApp (EVar "rangeOfLoc") (EVar "src")) (EVar "loc"))) (EVar "msg")))
(DTypeSig false "diagnosticsFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "diagnosticsFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false (PVar "ln") (EApp (EApp (EVar "maxI") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "parseErrorLine") (EVar "e")) (ELit (LInt 1))))) (DoLet false false (PVar "col") (EApp (EApp (EVar "maxI") (ELit (LInt 0))) (EApp (EVar "parseErrorCol") (EVar "e")))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "ln")) (EVar "col")) (EVar "ln")) (EBinOp "+" (EVar "col") (ELit (LInt 1))))) (DoExpr (EListLit (EApp (EApp (EApp (EVar "jDiagnostic") (ELit (LInt 1))) (EVar "r")) (EApp (EVar "parseErrorMessage") (EVar "e"))))))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "map") (EApp (EVar "diagToJson") (EVar "src"))) (EApp (EApp (EApp (EVar "analyzeLocated") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src"))))))
(DTypeSig false "docsGet" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "docsGet" ((PVar "uri") (PCon "Docs" (PVar "xs"))) (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "xs")))
(DTypeSig false "docsLookup" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "docsLookup" (PWild (PList)) (EVar "None"))
(DFunDef false "docsLookup" ((PVar "uri") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "uri")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "fullDocRangeFmt" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "fullDocRangeFmt" ((PVar "src")) (EApp (EApp (EApp (EApp (EVar "jRange") (ELit (LInt 0))) (ELit (LInt 0))) (EBinOp "+" (EApp (EVar "countLines") (EVar "src")) (ELit (LInt 1)))) (ELit (LInt 0))))
(DTypeSig false "formattingEdits" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "formattingEdits" ((PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EListLit) (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EVar "fullDocRangeFmt") (EVar "src"))) (ETuple (ELit (LString "newText")) (EApp (EVar "JString") (EVar "formatted"))))))))))))
(DTypeSig false "offsetOfLineCol" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "offsetOfLineCol" ((PVar "arr") (PVar "line") (PVar "col")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "offsetGo") (EVar "arr")) (EApp (EVar "arrayLength") (EVar "arr"))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "line")) (EVar "col")))
(DTypeSig false "offsetGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))))))
(DFunDef false "offsetGo" ((PVar "arr") (PVar "len") (PVar "i") (PVar "curLine") (PVar "lineStart") (PVar "line") (PVar "col")) (EIf (EBinOp "==" (EVar "curLine") (EVar "line")) (EBlock (DoLet false false (PVar "pos") (EBinOp "+" (EVar "lineStart") (EVar "col"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "pos") (ELit (LInt 0))) (EBinOp "<" (EVar "pos") (EVar "len"))) (EApp (EVar "Some") (EVar "pos")) (EVar "None")))) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "offsetGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "curLine") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "line")) (EVar "col")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "offsetGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "curLine")) (EVar "lineStart")) (EVar "line")) (EVar "col")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "identStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "identStart" ((PVar "arr") (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EVar "identStart") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identStop" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "identStop" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EApp (EVar "identStop") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identifierAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "identifierAt" ((PVar "src") (PVar "line") (PVar "col")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "offsetOfLineCol") (EVar "arr")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "pos")) () (EIf (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EVar "arr")))) (EVar "None") (EBlock (DoLet false false (PVar "s") (EApp (EApp (EVar "identStart") (EVar "arr")) (EVar "pos"))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "identStop") (EVar "arr")) (EVar "len")) (EVar "pos"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EVar "s")) (EVar "e")) (EVar "src")))))))))))
(DTypeSig false "posOfOffset" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "posOfOffset" ((PVar "arr") (PVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "posOffGo") (EVar "arr")) (EVar "off")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "posOffGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int"))))))))
(DFunDef false "posOffGo" ((PVar "arr") (PVar "off") (PVar "i") (PVar "line") (PVar "lineStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "off")) (ETuple (EVar "line") (EBinOp "-" (EVar "off") (EVar "lineStart"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "posOffGo") (EVar "arr")) (EVar "off")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "posOffGo") (EVar "arr")) (EVar "off")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "line")) (EVar "lineStart")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "occurrences" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "occurrences" ((PVar "src") (PVar "name")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoLet false false (PVar "nlen") (EApp (EVar "stringLength") (EVar "name"))) (DoExpr (EIf (EBinOp "==" (EVar "nlen") (ELit (LInt 0))) (EListLit) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "occGo") (EVar "src")) (EVar "arr")) (EVar "len")) (EVar "name")) (EVar "nlen")) (ELit (LInt 0)))))))
(DTypeSig false "occGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "occGo" ((PVar "src") (PVar "arr") (PVar "len") (PVar "name") (PVar "nlen") (PVar "i")) (EIf (EBinOp ">" (EBinOp "+" (EVar "i") (EVar "nlen")) (EVar "len")) (EListLit) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "windowEq") (EVar "src")) (EVar "i")) (EVar "name")) (EVar "nlen")) (EBinOp "||" (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "arr")))))) (EBinOp "||" (EBinOp "==" (EBinOp "+" (EVar "i") (EVar "nlen")) (EVar "len")) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (EVar "nlen"))) (EVar "arr")))))) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "occGo") (EVar "src")) (EVar "arr")) (EVar "len")) (EVar "name")) (EVar "nlen")) (EBinOp "+" (EVar "i") (EVar "nlen")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "occGo") (EVar "src")) (EVar "arr")) (EVar "len")) (EVar "name")) (EVar "nlen")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "windowEq" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "windowEq" ((PVar "src") (PVar "i") (PVar "name") (PVar "nlen")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (EVar "nlen"))) (EVar "src")) (EVar "name")))
(DTypeSig false "highlightRanges" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json")))))
(DFunDef false "highlightRanges" ((PVar "src") (PVar "name")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "nlen") (EApp (EVar "stringLength") (EVar "name"))) (DoExpr (EApp (EApp (EVar "map") (EApp (EApp (EVar "occToHighlight") (EVar "arr")) (EVar "nlen"))) (EApp (EApp (EVar "occurrences") (EVar "src")) (EVar "name"))))))
(DTypeSig false "occToHighlight" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json")))))
(DFunDef false "occToHighlight" ((PVar "arr") (PVar "nlen") (PVar "off")) (EMatch (EApp (EApp (EVar "posOfOffset") (EVar "arr")) (EVar "off")) (arm (PTuple (PVar "sl") (PVar "sc")) () (EMatch (EApp (EApp (EVar "posOfOffset") (EVar "arr")) (EBinOp "+" (EVar "off") (EVar "nlen"))) (arm (PTuple (PVar "el") (PVar "ec")) () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec"))))))))))
(DTypeSig false "innerDecl" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "innerDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "innerDecl") (EVar "d")))
(DFunDef false "innerDecl" ((PVar "d")) (EVar "d"))
(DTypeSig false "jSymbol" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyCon "Json"))))))
(DFunDef false "jSymbol" ((PVar "name") (PVar "kind") (PVar "range") (PVar "children")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JInt") (EVar "kind"))) (ETuple (ELit (LString "range")) (EVar "range")) (ETuple (ELit (LString "selectionRange")) (EVar "range")) (ETuple (ELit (LString "children")) (EApp (EVar "jArray") (EVar "children"))))))
(DTypeSig false "jChild" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyCon "Json")))))
(DFunDef false "jChild" ((PVar "name") (PVar "kind") (PVar "range")) (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (EVar "kind")) (EVar "range")) (EListLit)))
(DTypeSig false "variantName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "fieldName" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldName" ((PCon "Field" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "variantSymChildren" (TyFun (TyCon "Json") (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyCon "Json")))))
(DFunDef false "variantSymChildren" ((PVar "range") (PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") (PCon "True")))) (EApp (EApp (EVar "map") (ELam ((PCon "Field" (PVar "fn") PWild)) (EApp (EApp (EApp (EVar "jChild") (EVar "fn")) (ELit (LInt 8))) (EVar "range")))) (EVar "fs")))
(DFunDef false "variantSymChildren" ((PVar "range") (PCon "Variant" (PVar "vn") PWild)) (EListLit (EApp (EApp (EApp (EVar "jChild") (EVar "vn")) (ELit (LInt 22))) (EVar "range"))))
(DTypeSig false "variantFieldNames" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "variantFieldNames" ((PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EApp (EVar "map") (EVar "fieldName")) (EVar "fs")))
(DFunDef false "variantFieldNames" ((PCon "Variant" PWild (PCon "ConPos" PWild))) (EListLit))
(DTypeSig false "ifaceMethodName" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodName" ((PCon "IfaceMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "implMethodName" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodName" ((PCon "ImplMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "symbolOfDecl" (TyFun (TyCon "Decl") (TyFun (TyCon "DeclPos") (TyApp (TyCon "Option") (TyCon "Json")))))
(DFunDef false "symbolOfDecl" ((PVar "d") (PVar "dp")) (EBlock (DoLet false false (PVar "range") (EApp (EApp (EApp (EApp (EVar "jRange") (EBinOp "-" (EApp (EVar "declPosLine") (EVar "dp")) (ELit (LInt 1)))) (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "declPosEndLine") (EVar "dp")) (ELit (LInt 1)))) (ELit (LInt 0)))) (DoExpr (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "name") PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 13))) (EVar "range")) (EListLit)))) (arm (PCon "DExtern" PWild (PVar "name") PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 12))) (EVar "range")) (EListLit)))) (arm (PCon "DFunDef" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 12))) (EVar "range")) (EListLit)))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EMatch (EVar "binds") (arm (PList) () (EVar "None")) (arm (PCons (PCon "LetBind" (PVar "n0") PWild) PWild) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EVar "map") (ELam ((PCon "LetBind" (PVar "n") PWild)) (EApp (EApp (EApp (EVar "jChild") (EVar "n")) (ELit (LInt 12))) (EVar "range")))) (EVar "binds"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "n0")) (ELit (LInt 12))) (EVar "range")) (EVar "kids")))))))) (arm (PCon "DData" PWild (PVar "name") PWild (PVar "variants") PWild) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EVar "flatMap") (EApp (EVar "variantSymChildren") (EVar "range"))) (EVar "variants"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 10))) (EVar "range")) (EVar "kids")))))) (arm (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" (PVar "ms"))) true) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EVar "map") (ELam ((PCon "IfaceMethod" (PVar "mn") PWild PWild)) (EApp (EApp (EApp (EVar "jChild") (EVar "mn")) (ELit (LInt 6))) (EVar "range")))) (EVar "ms"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "n")) (ELit (LInt 11))) (EVar "range")) (EVar "kids")))))) (arm (PRec "DImpl" ((rf "iface" (PVar "ifc")) (rf "methods" (PVar "ms"))) true) () (EBlock (DoLet false false (PVar "label") (EApp (EVar "implLabel") (EVar "ifc"))) (DoLet false false (PVar "kids") (EApp (EApp (EVar "map") (ELam ((PCon "ImplMethod" (PVar "mn") PWild PWild)) (EApp (EApp (EApp (EVar "jChild") (EVar "mn")) (ELit (LInt 6))) (EVar "range")))) (EVar "ms"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "label")) (ELit (LInt 5))) (EVar "range")) (EVar "kids")))))) (arm (PCon "DTypeAlias" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 26))) (EVar "range")) (EListLit)))) (arm (PCon "DNewtype" PWild (PVar "name") PWild PWild PWild PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 23))) (EVar "range")) (EListLit)))) (arm (PCon "DUse" PWild PWild PWild) () (EVar "None")) (arm (PCon "DProp" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 12))) (EVar "range")) (EListLit)))) (arm (PCon "DTest" PWild (PVar "name") PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 12))) (EVar "range")) (EListLit)))) (arm (PCon "DBench" PWild (PVar "name") PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 12))) (EVar "range")) (EListLit)))) (arm (PCon "DEffect" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 24))) (EVar "range")) (EListLit)))) (arm (PCon "DAttrib" PWild PWild) () (EVar "None"))))))
(DTypeSig false "implLabel" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "implLabel" ((PVar "iface")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "impl ")) (EVar "iface"))))
(DTypeSig false "documentSymbols" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "documentSymbols" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EApp (EApp (EVar "symbolsZip") (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))))))
(DTypeSig false "symbolsZip" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyCon "Json")))))
(DFunDef false "symbolsZip" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps"))) (EMatch (EApp (EApp (EVar "symbolOfDecl") (EVar "d")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EVar "symbolsZip") (EVar "ds")) (EVar "ps"))) (arm (PCon "Some" (PVar "s")) () (EBinOp "::" (EVar "s") (EApp (EApp (EVar "symbolsZip") (EVar "ds")) (EVar "ps"))))))
(DFunDef false "symbolsZip" (PWild PWild) (EListLit))
(DTypeSig false "declDefines" (TyFun (TyCon "Decl") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "declDefines" ((PVar "d") (PVar "name")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DExtern" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DFunDef" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EApp (EApp (EVar "anyName") (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds"))) (EVar "name"))) (arm (PCon "DData" PWild (PVar "n") PWild (PVar "vs") PWild) () (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EApp (EVar "anyName") (EApp (EApp (EVar "map") (EVar "variantName")) (EVar "vs"))) (EVar "name"))) (EApp (EApp (EVar "anyName") (EApp (EApp (EVar "flatMap") (EVar "variantFieldNames")) (EVar "vs"))) (EVar "name")))) (arm (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" (PVar "ms"))) true) () (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EApp (EVar "anyName") (EApp (EApp (EVar "map") (EVar "ifaceMethodName")) (EVar "ms"))) (EVar "name")))) (arm (PRec "DImpl" ((rf "methods" (PVar "ms"))) true) () (EApp (EApp (EVar "anyName") (EApp (EApp (EVar "map") (EVar "implMethodName")) (EVar "ms"))) (EVar "name"))) (arm (PCon "DTypeAlias" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DNewtype" PWild (PVar "n") PWild (PVar "c") PWild PWild) () (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "name")) (EBinOp "==" (EVar "c") (EVar "name")))) (arm (PCon "DUse" PWild PWild PWild) () (EVar "False")) (arm (PCon "DProp" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DTest" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DBench" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DEffect" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DAttrib" PWild PWild) () (EVar "False"))))
(DTypeSig false "anyName" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "anyName" ((PList) PWild) (EVar "False"))
(DFunDef false "anyName" ((PCons (PVar "x") (PVar "xs")) (PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "name")) (EApp (EApp (EVar "anyName") (EVar "xs")) (EVar "name"))))
(DTypeSig false "definitionRange" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Json")))))
(DFunDef false "definitionRange" ((PVar "src") (PVar "name")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EApp (EApp (EApp (EVar "defZip") (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))) (EVar "name")))))
(DTypeSig false "defZip" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Json"))))))
(DFunDef false "defZip" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PVar "name")) (EIf (EApp (EApp (EVar "declDefines") (EVar "d")) (EVar "name")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jRange") (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1)))) (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "declPosEndLine") (EVar "p")) (ELit (LInt 1)))) (ELit (LInt 0)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "defZip") (EVar "ds")) (EVar "ps")) (EVar "name")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "defZip" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "docSchemes" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "docSchemes" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "userRaw")) () (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugar") (EApp (EVar "unwrapDecls") (EApp (EVar "parseResult") (EVar "runtimeSrc"))))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugar") (EApp (EVar "unwrapDecls") (EApp (EVar "parseResult") (EVar "coreSrc"))))) (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EVar "userRaw"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EVar "checkProgramSchemesWithRuntime") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "userDecls"))))))))
(DTypeSig false "unwrapDecls" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "unwrapDecls" ((PCon "Ok" (PVar "ds"))) (EVar "ds"))
(DFunDef false "unwrapDecls" ((PCon "Err" PWild)) (EListLit))
(DTypeSig false "lookupSchemeL" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupSchemeL" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupSchemeL" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "n")) (EApp (EVar "Some") (EVar "s")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hoverFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "hoverFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "name")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "hoverEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "env")) () (EMatch (EApp (EApp (EVar "hoverScheme") (EVar "name")) (EVar "env")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "sch")) () (EBlock (DoLet false false (PVar "pfx") (EApp (EApp (EVar "sigLeadingEff") (EVar "name")) (EApp (EVar "unwrapDecls") (EApp (EVar "parseResult") (EVar "src"))))) (DoExpr (EApp (EApp (EVar "jHover") (EVar "name")) (EApp (EVar "stringConcat") (EListLit (EVar "pfx") (EApp (EApp (EVar "ppSchemeNamed") (EVar "name")) (EVar "sch")))))))))))))) (arm PWild () (EVar "JNull"))))
(DTypeSig false "hoverEnvFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))))
(DFunDef false "hoverEnvFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EIf (EApp (EVar "bufferHasImports") (EVar "src")) (EApp (EApp (EApp (EApp (EVar "projectEntryEnv") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "docs")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "docSchemes") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "projectEntryEnv" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))))
(DFunDef false "projectEntryEnv" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "docs")) (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRoot") (EApp (EVar "dirOfPath") (EVar "rootFile")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EApp (EVar "lspMedakaRoot") (ELit (LString "."))) (ELit (LString "/stdlib")))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectEntrySchemes") (EVar "projectCache")) (EVar "projectParseCache")) (EVar "read")) (EVar "rootFile")) (EListLit (EVar "projectDir") (EVar "stdlibDir"))) (EVar "runtimeSrc")) (EVar "coreSrc")))))
(DTypeSig false "hoverScheme" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "hoverScheme" ((PVar "name") (PVar "env")) (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EVar "env")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EApp (EVar "currentLocalSchemes") (ELit LUnit))) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EApp (EVar "currentSeedSchemes") (ELit LUnit))))))))
(DTypeSig false "sigLeadingEff" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))
(DFunDef false "sigLeadingEff" (PWild (PList)) (ELit (LString "")))
(DFunDef false "sigLeadingEff" ((PVar "name") (PCons (PVar "d") (PVar "ds"))) (EMatch (EApp (EApp (EVar "sigLeadingEffOne") (EVar "name")) (EVar "d")) (arm (PCon "Some" (PVar "pfx")) () (EVar "pfx")) (arm (PCon "None") () (EApp (EApp (EVar "sigLeadingEff") (EVar "name")) (EVar "ds")))))
(DTypeSig false "sigLeadingEffOne" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "sigLeadingEffOne" ((PVar "name") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "sigLeadingEffOne") (EVar "name")) (EVar "d")))
(DFunDef false "sigLeadingEffOne" ((PVar "name") (PCon "DTypeSig" PWild (PVar "n") (PVar "ty"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "leadingEffOf") (EVar "ty")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "sigLeadingEffOne" (PWild PWild) (EVar "None"))
(DTypeSig false "leadingEffOf" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "leadingEffOf" ((PCon "TyEffect" (PVar "labels") (PVar "tail") PWild)) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (EApp (EApp (EVar "renderEffRow") (EVar "labels")) (EVar "tail")) (ELit (LString " "))))))
(DFunDef false "leadingEffOf" (PWild) (EVar "None"))
(DTypeSig false "renderEffRow" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "renderEffRow" ((PVar "labels") (PVar "tail")) (EBlock (DoLet false false (PVar "lbls") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "renderEffAtom")) (EVar "labels")))) (DoLet false false (PVar "body") (EMatch (EVar "tail") (arm (PCon "None") () (EVar "lbls")) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "lbls") (ELit (LString ""))) (EVar "v") (EApp (EVar "stringConcat") (EListLit (EVar "lbls") (ELit (LString " | ")) (EVar "v"))))))) (DoExpr (EApp (EVar "stringConcat") (EListLit (ELit (LString "<")) (EVar "body") (ELit (LString ">")))))))
(DTypeSig false "renderEffAtom" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "renderEffAtom" ((PTuple (PVar "nm") (PCon "None"))) (EVar "nm"))
(DFunDef false "renderEffAtom" ((PTuple (PVar "nm") (PCon "Some" (PLit (LString "_"))))) (EApp (EVar "stringConcat") (EListLit (EVar "nm") (ELit (LString " _")))))
(DFunDef false "renderEffAtom" ((PTuple (PVar "nm") (PCon "Some" (PVar "p")))) (EApp (EVar "stringConcat") (EListLit (EVar "nm") (ELit (LString " \"")) (EVar "p") (ELit (LString "\"")))))
(DTypeSig false "jHover" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "jHover" ((PVar "name") (PVar "ty")) (EBlock (DoLet false false (PVar "value") (EApp (EVar "stringConcat") (EListLit (ELit (LString "```medaka\n")) (EVar "name") (ELit (LString " : ")) (EVar "ty") (ELit (LString "\n```"))))) (DoExpr (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "contents")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (ELit (LString "markdown")))) (ETuple (ELit (LString "value")) (EApp (EVar "JString") (EVar "value")))))))))))
(DTypeSig false "handleHover" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleHover" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hoverFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "prefixBefore" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "prefixBefore" ((PVar "src") (PVar "line") (PVar "col")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "offsetOfLineStart") (EVar "arr")) (EVar "len")) (EVar "line")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "lineStart")) () (EBlock (DoLet false false (PVar "stop") (EBinOp "-" (EBinOp "+" (EVar "lineStart") (EVar "col")) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<" (EVar "stop") (EVar "lineStart")) (ELit (LString "")) (EIf (EBinOp ">=" (EVar "stop") (EVar "len")) (ELit (LString "")) (EIf (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "stop")) (EVar "arr")))) (ELit (LString "")) (EBlock (DoLet false false (PVar "start") (EApp (EApp (EApp (EVar "prefixStart") (EVar "arr")) (EVar "lineStart")) (EVar "stop"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EBinOp "+" (EVar "stop") (ELit (LInt 1)))) (EVar "src"))))))))))))))
(DTypeSig false "offsetOfLineStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "offsetOfLineStart" ((PVar "arr") (PVar "len") (PVar "line")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineStartGo") (EVar "arr")) (EVar "len")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "line")))
(DTypeSig false "lineStartGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))))
(DFunDef false "lineStartGo" ((PVar "arr") (PVar "len") (PVar "i") (PVar "curLine") (PVar "lineStart") (PVar "line")) (EIf (EBinOp "==" (EVar "curLine") (EVar "line")) (EApp (EVar "Some") (EVar "lineStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineStartGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "curLine") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "line")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineStartGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "curLine")) (EVar "lineStart")) (EVar "line")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "prefixStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "prefixStart" ((PVar "arr") (PVar "lineStart") (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (EVar "lineStart")) (EVar "lineStart") (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EApp (EVar "prefixStart") (EVar "arr")) (EVar "lineStart")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "startsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "startsWith" ((PVar "p") (PVar "n")) (EBlock (DoLet false false (PVar "pl") (EApp (EVar "stringLength") (EVar "p"))) (DoExpr (EIf (EBinOp "==" (EVar "pl") (ELit (LInt 0))) (EVar "True") (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "n")) (EVar "pl")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "pl")) (EVar "n")) (EVar "p")))))))
(DTypeSig false "filterCompletions" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "filterCompletions" (PWild PWild (PList)) (EListLit))
(DFunDef false "filterCompletions" ((PVar "prefix") (PVar "seen") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "anyName") (EVar "seen")) (EVar "n")))) (EBinOp "::" (EApp (EApp (EVar "jCompletionItem") (EVar "n")) (EApp (EApp (EVar "ppSchemeNamed") (EVar "n")) (EVar "s"))) (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EBinOp "::" (EVar "n") (EVar "seen"))) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EVar "seen")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "jCompletionItem" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "jCompletionItem" ((PVar "label") (PVar "detail")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "label")) (EApp (EVar "JString") (EVar "label"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JInt") (ELit (LInt 3)))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EVar "detail"))))))
(DTypeSig false "completionFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "completionFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "completionEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "env")) () (EBlock (DoLet false false (PVar "prefix") (EApp (EApp (EApp (EVar "prefixBefore") (EVar "src")) (EVar "line")) (EVar "col"))) (DoExpr (EApp (EVar "jArray") (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EListLit)) (EVar "env")))))))) (arm PWild () (EVar "JNull"))))
(DTypeSig false "completionEnvFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))))
(DFunDef false "completionEnvFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EIf (EApp (EVar "bufferHasImports") (EVar "src")) (EApp (EApp (EVar "map") (ELam ((PVar "own")) (EBinOp "++" (EBinOp "++" (EVar "own") (EApp (EVar "currentLocalSchemes") (ELit LUnit))) (EApp (EVar "currentSeedSchemes") (ELit LUnit))))) (EApp (EApp (EApp (EApp (EVar "projectEntryEnv") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "docs"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "docSchemes") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "handleCompletion" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleCompletion" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "completionFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "declBindingName" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "declBindingName" ((PVar "d")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DFunDef" PWild (PVar "n") PWild PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EMatch (EVar "binds") (arm (PCons (PCon "LetBind" (PVar "n") PWild) PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PList) () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "hasExplicitSig" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasExplicitSig" ((PList) PWild) (EVar "False"))
(DFunDef false "hasExplicitSig" ((PCons (PVar "d") (PVar "rest")) (PVar "name")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "n") PWild) () (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EApp (EVar "hasExplicitSig") (EVar "rest")) (EVar "name")))) (arm PWild () (EApp (EApp (EVar "hasExplicitSig") (EVar "rest")) (EVar "name")))))
(DTypeSig false "columnAfterName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "columnAfterName" ((PVar "src") (PVar "line")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "offsetOfLineStart") (EVar "arr")) (EVar "len")) (EVar "line")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "lineStart")) () (EBlock (DoLet false false (PVar "endCol") (EApp (EApp (EApp (EApp (EVar "identRunLen") (EVar "arr")) (EVar "len")) (EVar "lineStart")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "==" (EVar "endCol") (ELit (LInt 0))) (EVar "None") (EApp (EVar "Some") (EVar "endCol"))))))))))
(DTypeSig false "identRunLen" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "identRunLen" ((PVar "arr") (PVar "len") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EVar "acc") (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EApp (EVar "identRunLen") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "inlayHints" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "inlayHints" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src")) (EMatch (EApp (EApp (EApp (EVar "docSchemes") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "env")) () (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "decls")) (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))) (EVar "env")))))))
(DTypeSig false "inlayZip" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyCon "Json"))))))))
(DFunDef false "inlayZip" ((PVar "src") (PVar "allDecls") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PVar "env")) (EMatch (EApp (EVar "declBindingName") (EVar "d")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PVar "name")) () (EIf (EApp (EApp (EVar "hasExplicitSig") (EVar "allDecls")) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env")) (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EVar "env")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PVar "sch")) () (EMatch (EApp (EApp (EVar "columnAfterName") (EVar "src")) (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1)))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PVar "col")) () (EBinOp "::" (EApp (EApp (EApp (EVar "jInlayHint") (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1)))) (EVar "col")) (EApp (EVar "stringConcat") (EListLit (ELit (LString ": ")) (EApp (EApp (EVar "ppSchemeNamed") (EVar "name")) (EVar "sch"))))) (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env")))))))))))
(DFunDef false "inlayZip" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "jInlayHint" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "jInlayHint" ((PVar "line") (PVar "col") (PVar "label")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EApp (EVar "jPosition") (EVar "line")) (EVar "col"))) (ETuple (ELit (LString "label")) (EApp (EVar "JString") (EVar "label"))) (ETuple (ELit (LString "paddingLeft")) (EApp (EVar "JBool") (EVar "True"))))))
(DTypeSig false "handleInlayHint" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleInlayHint" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jArray") (EApp (EApp (EApp (EVar "inlayHints") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "positionLine" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "positionLine" ((PVar "params")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "position"))) (EVar "params")) (arm (PCon "Some" (PVar "pos")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "line"))) (EVar "pos")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asInt") (EVar "v"))) (arm (PCon "None") () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "positionChar" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "positionChar" ((PVar "params")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "position"))) (EVar "params")) (arm (PCon "Some" (PVar "pos")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "character"))) (EVar "pos")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asInt") (EVar "v"))) (arm (PCon "None") () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "requestUri" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "requestUri" ((PVar "params")) (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))))
(DTypeSig false "logFilePath" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "logFilePath" (PWild) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_LSP_LOG"))) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (ELit (LString "/tmp/medaka-lsp.log")) (EVar "v"))) (arm (PCon "None") () (ELit (LString "/tmp/medaka-lsp.log")))))
(DTypeSig false "logLine" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "logLine" ((PVar "s")) (EBlock (DoLet false false (PVar "ts") (EApp (EVar "wallTimeSec") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "appendFile") (EApp (EVar "logFilePath") (ELit LUnit))) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "floatToString") (EVar "ts")) (ELit (LString " ")) (EVar "s") (ELit (LString "\n")))))) (DoExpr (ELit LUnit))))
(DTypeSig false "writeMessage" (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeMessage" ((PVar "j")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "stringify") (EVar "j"))) (DoLet false false (PVar "n") (EApp (EVar "utf8Len") (EVar "body"))) (DoLet false false (PVar "header") (EApp (EVar "stringConcat") (EListLit (ELit (LString "Content-Length: ")) (EApp (EVar "intToString") (EVar "n")) (ELit (LString "\r\n\r\n"))))) (DoLet false false PWild (EApp (EVar "putStr") (EVar "header"))) (DoLet false false PWild (EApp (EVar "putStr") (EVar "body"))) (DoExpr (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig false "responseMsg" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "responseMsg" ((PVar "idJson") (PVar "result")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "result")) (EVar "result")))))
(DTypeSig false "notificationMsg" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "notificationMsg" ((PVar "meth") (PVar "params")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (EVar "meth"))) (ETuple (ELit (LString "params")) (EVar "params")))))
(DData Public "Headers" () ((variant "Headers" (ConPos (TyCon "Int")))) ())
(DTypeSig false "readHeaders" (TyFun (TyCon "Int") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "readHeaders" ((PVar "lenAcc")) (EMatch (EApp (EVar "readLineOpt") (ELit LUnit)) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "raw")) () (EBlock (DoLet false false (PVar "line") (EApp (EVar "stripCR") (EVar "raw"))) (DoExpr (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EApp (EVar "Some") (EVar "lenAcc")) (EBlock (DoLet false false (PVar "lenAcc2") (EMatch (EApp (EVar "parseContentLength") (EVar "line")) (arm (PCon "Some" (PVar "n")) () (EVar "n")) (arm (PCon "None") () (EVar "lenAcc")))) (DoExpr (EApp (EVar "readHeaders") (EVar "lenAcc2"))))))))))
(DTypeSig false "parseContentLength" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "parseContentLength" ((PVar "line")) (EBlock (DoLet false false (PVar "prefix") (ELit (LString "Content-Length:"))) (DoLet false false (PVar "pn") (EApp (EVar "stringLength") (EVar "prefix"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "line")) (EVar "pn")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "pn")) (EVar "line")) (EVar "prefix"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EApp (EVar "stringToChars") (EApp (EApp (EApp (EVar "stringSlice") (EVar "pn")) (EApp (EVar "stringLength") (EVar "line"))) (EVar "line")))) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EApp (EApp (EApp (EVar "stringSlice") (EVar "pn")) (EApp (EVar "stringLength") (EVar "line"))) (EVar "line"))))) (ELit (LInt 0))) (EVar "False")) (EVar "None")))))
(DTypeSig false "parseDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "parseDigits" ((PVar "arr") (PVar "i") (PVar "n") (PVar "acc") (PVar "seen")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EIf (EVar "seen") (EApp (EVar "Some") (EVar "acc")) (EVar "None")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EVar "not") (EVar "seen"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "acc")) (EVar "seen")) (EIf (EApp (EVar "isDigit") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EBinOp "-" (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (ELit (LInt 48))))) (EVar "True")) (EIf (EVar "otherwise") (EIf (EVar "seen") (EApp (EVar "Some") (EVar "acc")) (EVar "None")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "semanticLegend" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "semanticLegend" () (EListLit (ELit (LString "keyword")) (ELit (LString "class")) (ELit (LString "macro")) (ELit (LString "function")) (ELit (LString "property")) (ELit (LString "string")) (ELit (LString "number")) (ELit (LString "selfParameter"))))
(DTypeSig false "semanticTokensOptions" (TyCon "Json"))
(DFunDef false "semanticTokensOptions" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "legend")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tokenTypes")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EVar "semanticLegend")))) (ETuple (ELit (LString "tokenModifiers")) (EApp (EVar "jArray") (EListLit)))))) (ETuple (ELit (LString "full")) (EApp (EVar "JBool") (EVar "True"))))))
(DData Private "SMode" () ((variant "MExpr" (ConPos)) (variant "MType" (ConPos)) (variant "MDataHead" (ConPos)) (variant "MDataVariant" (ConPos)) (variant "MDataPayload" (ConPos)) (variant "MRecord" (ConPos)) (variant "MIfaceOne" (ConPos)) (variant "MIfaceMany" (ConPos))) ())
(DData Private "SemCtx" () ((variant "SemCtx" (ConPos (TyCon "Int") (TyCon "Bool") (TyCon "SMode")))) ())
(DTypeSig false "isKeywordTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isKeywordTok" ((PCon "TLet")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TRec")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TWith")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TMut")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TIn")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TIf")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TThen")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TElse")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TMatch")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TData")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TRecord")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TInterface")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TDefault")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TImpl")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TImport")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TExport")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TPublic")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TWhere")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TOf")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TRequires")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TDo")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TAs")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TExtern")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TDeriving")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TType")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TNewtype")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TProp")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TTest")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TBench")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TEffect")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TFunction")) (EVar "True"))
(DFunDef false "isKeywordTok" (PWild) (EVar "False"))
(DTypeSig false "upperRole" (TyFun (TyCon "SMode") (TyCon "Int")))
(DFunDef false "upperRole" ((PCon "MExpr")) (ELit (LInt 2)))
(DFunDef false "upperRole" ((PCon "MDataVariant")) (ELit (LInt 2)))
(DFunDef false "upperRole" (PWild) (ELit (LInt 1)))
(DTypeSig false "roleOf" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "SMode") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "roleOf" ((PCon "TUpper" PWild) PWild PWild (PCon "MIfaceOne")) (EApp (EVar "Some") (ELit (LInt 7))))
(DFunDef false "roleOf" ((PCon "TUpper" PWild) PWild PWild (PCon "MIfaceMany")) (EApp (EVar "Some") (ELit (LInt 7))))
(DFunDef false "roleOf" ((PCon "TUpper" PWild) PWild PWild (PVar "mode")) (EApp (EVar "Some") (EApp (EVar "upperRole") (EVar "mode"))))
(DFunDef false "roleOf" ((PCon "TIdent" PWild) (PVar "depth") (PVar "lineStart") (PVar "mode")) (EIf (EBinOp "&&" (EVar "lineStart") (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EVar "Some") (ELit (LInt 3))) (EMatch (EVar "mode") (arm (PCon "MRecord") () (EApp (EVar "Some") (ELit (LInt 4)))) (arm PWild () (EVar "None")))))
(DFunDef false "roleOf" ((PCon "TBacktickIdent" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 3))))
(DFunDef false "roleOf" ((PCon "TString" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TChar" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpOpen" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpMid" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpEnd" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInt" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 6))))
(DFunDef false "roleOf" ((PCon "TFloat" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 6))))
(DFunDef false "roleOf" ((PCon "TBool" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 0))))
(DFunDef false "roleOf" ((PVar "t") PWild PWild PWild) (EIf (EApp (EVar "isKeywordTok") (EVar "t")) (EApp (EVar "Some") (ELit (LInt 0))) (EVar "None")))
(DTypeSig false "nextMode" (TyFun (TyCon "Token") (TyFun (TyCon "SMode") (TyCon "SMode"))))
(DFunDef false "nextMode" ((PCon "TData") PWild) (EVar "MDataHead"))
(DFunDef false "nextMode" ((PCon "TNewtype") PWild) (EVar "MDataHead"))
(DFunDef false "nextMode" ((PCon "TRecord") PWild) (EVar "MRecord"))
(DFunDef false "nextMode" ((PCon "TInterface") PWild) (EVar "MIfaceOne"))
(DFunDef false "nextMode" ((PCon "TImpl") PWild) (EVar "MIfaceOne"))
(DFunDef false "nextMode" ((PCon "TRequires") PWild) (EVar "MIfaceMany"))
(DFunDef false "nextMode" ((PCon "TDeriving") PWild) (EVar "MIfaceMany"))
(DFunDef false "nextMode" ((PCon "TExtern") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TType") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TOf") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TWhere") PWild) (EVar "MExpr"))
(DFunDef false "nextMode" ((PCon "TUpper" PWild) (PCon "MIfaceOne")) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TColon") (PCon "MRecord")) (EVar "MRecord"))
(DFunDef false "nextMode" ((PCon "TColon") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TEqual") (PCon "MDataHead")) (EVar "MDataVariant"))
(DFunDef false "nextMode" ((PCon "TEqual") (PCon "MRecord")) (EVar "MRecord"))
(DFunDef false "nextMode" ((PCon "TEqual") PWild) (EVar "MExpr"))
(DFunDef false "nextMode" ((PCon "TPipe") (PCon "MDataVariant")) (EVar "MDataVariant"))
(DFunDef false "nextMode" ((PCon "TPipe") (PCon "MDataPayload")) (EVar "MDataVariant"))
(DFunDef false "nextMode" ((PCon "TUpper" PWild) (PCon "MDataVariant")) (EVar "MDataPayload"))
(DFunDef false "nextMode" (PWild (PVar "mode")) (EVar "mode"))
(DData Public "SemTok" () ((variant "SemTok" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig false "classify" (TyFun (TyCon "Token") (TyFun (TyCon "SemCtx") (TyTuple (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "SemCtx")))))
(DFunDef false "classify" ((PCon "TIndent") (PCon "SemCtx" (PVar "depth") (PVar "ls") (PVar "mode"))) (ETuple (EVar "None") (EApp (EApp (EApp (EVar "SemCtx") (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "ls")) (EVar "mode"))))
(DFunDef false "classify" ((PCon "TDedent") (PCon "SemCtx" (PVar "depth") (PVar "ls") (PVar "mode"))) (ETuple (EVar "None") (EApp (EApp (EApp (EVar "SemCtx") (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "ls")) (EVar "mode"))))
(DFunDef false "classify" ((PCon "TNewline") (PCon "SemCtx" (PVar "depth") PWild (PVar "mode"))) (EBlock (DoLet false false (PVar "mode2") (EIf (EBinOp "<=" (EVar "depth") (ELit (LInt 0))) (EVar "MExpr") (EVar "mode"))) (DoExpr (ETuple (EVar "None") (EApp (EApp (EApp (EVar "SemCtx") (EVar "depth")) (EVar "True")) (EVar "mode2"))))))
(DFunDef false "classify" ((PVar "tok") (PCon "SemCtx" (PVar "depth") (PVar "ls") (PVar "mode"))) (ETuple (EApp (EApp (EApp (EApp (EVar "roleOf") (EVar "tok")) (EVar "depth")) (EVar "ls")) (EVar "mode")) (EApp (EApp (EApp (EVar "SemCtx") (EVar "depth")) (EVar "False")) (EApp (EApp (EVar "nextMode") (EVar "tok")) (EVar "mode")))))
(DTypeSig false "semToksOf" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "SemCtx") (TyApp (TyCon "List") (TyCon "SemTok")))))))
(DFunDef false "semToksOf" (PWild (PList) PWild PWild) (EListLit))
(DFunDef false "semToksOf" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "semToksOf" ((PVar "arr") (PCons (PVar "t") (PVar "ts")) (PCons (PTuple (PVar "s") (PVar "e")) (PVar "ps")) (PVar "ctx")) (EMatch (EApp (EApp (EVar "classify") (EVar "t")) (EVar "ctx")) (arm (PTuple (PVar "roleOpt") (PVar "ctx2")) () (EMatch (EVar "roleOpt") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2"))) (arm (PCon "Some" (PVar "ty")) () (EIf (EBinOp ">=" (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2")) (EMatch (ETuple (EApp (EApp (EVar "posOfOffset") (EVar "arr")) (EVar "s")) (EApp (EApp (EVar "posOfOffset") (EVar "arr")) (EVar "e"))) (arm (PTuple (PTuple (PVar "sl") (PVar "sc")) (PTuple (PVar "el") (PVar "ec"))) () (EIf (EBinOp "==" (EVar "sl") (EVar "el")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "SemTok") (EVar "sl")) (EVar "sc")) (EBinOp "-" (EVar "ec") (EVar "sc"))) (EVar "ty")) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2"))) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2")))))))))))
(DTypeSig false "encodeSemToks" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SemTok")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "encodeSemToks" (PWild PWild (PList)) (EListLit))
(DFunDef false "encodeSemToks" ((PVar "prevLine") (PVar "prevChar") (PCons (PCon "SemTok" (PVar "line") (PVar "ch") (PVar "len") (PVar "ty")) (PVar "rest"))) (EBlock (DoLet false false (PVar "dLine") (EBinOp "-" (EVar "line") (EVar "prevLine"))) (DoLet false false (PVar "dChar") (EIf (EBinOp "==" (EVar "dLine") (ELit (LInt 0))) (EBinOp "-" (EVar "ch") (EVar "prevChar")) (EVar "ch"))) (DoExpr (EBinOp "::" (EVar "dLine") (EBinOp "::" (EVar "dChar") (EBinOp "::" (EVar "len") (EBinOp "::" (EVar "ty") (EBinOp "::" (ELit (LInt 0)) (EApp (EApp (EApp (EVar "encodeSemToks") (EVar "line")) (EVar "ch")) (EVar "rest"))))))))))
(DTypeSig false "semanticTokensData" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "semanticTokensData" ((PVar "src")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoExpr (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "toks") (PVar "pairs")) () (EApp (EApp (EApp (EVar "encodeSemToks") (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "toks")) (EVar "pairs")) (EApp (EApp (EApp (EVar "SemCtx") (ELit (LInt 0))) (EVar "True")) (EVar "MExpr")))))))))
(DTypeSig false "initializeResult" (TyCon "Json"))
(DFunDef false "initializeResult" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "capabilities")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "textDocumentSync")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "documentFormattingProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "documentSymbolProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "definitionProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "documentHighlightProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "hoverProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "completionProvider")) (EApp (EVar "jObject") (EListLit))) (ETuple (ELit (LString "inlayHintProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "semanticTokensProvider")) (EVar "semanticTokensOptions"))))) (ETuple (ELit (LString "serverInfo")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (ELit (LString "medaka-lsp")))) (ETuple (ELit (LString "version")) (EApp (EVar "JString") (ELit (LString "0.1.0"))))))))))
(DTypeSig false "publishDiagnostics" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "publishDiagnostics" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src")) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EVar "diagnosticsFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src"))) (DoLet false false (PVar "params") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EVar "diags")))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "notificationMsg") (ELit (LString "textDocument/publishDiagnostics"))) (EVar "params"))))))
(DTypeSig false "projectCache" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "projectCache" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "projectParseCache" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "projectParseCache" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "pathOfUri" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "pathOfUri" ((PVar "uri")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "uri")) (ELit (LInt 7))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 7))) (EVar "uri")) (ELit (LString "file://")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 7))) (EApp (EVar "stringLength") (EVar "uri"))) (EVar "uri")) (EVar "uri")))
(DTypeSig false "uriOfPath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "uriOfPath" ((PVar "path")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "path")) (ELit (LInt 7))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 7))) (EVar "path")) (ELit (LString "file://")))) (EVar "path") (EApp (EVar "stringConcat") (EListLit (ELit (LString "file://")) (EVar "path")))))
(DTypeSig false "dirOfPath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirOfPath" ((PVar "path")) (EApp (EApp (EVar "dirGo") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "dirGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dirGo" ((PVar "path") (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "dirGo" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "dirGo") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "bufferHasImports" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "bufferHasImports" ((PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "False")) (arm (PCon "Ok" (PVar "decls")) () (EApp (EVar "anyImport") (EVar "decls")))))
(DTypeSig false "anyImport" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "anyImport" ((PList)) (EVar "False"))
(DFunDef false "anyImport" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isCoreImport") (EVar "path"))) (EApp (EVar "anyImport") (EVar "rest"))))
(DFunDef false "anyImport" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyImport") (EVar "rest")))
(DTypeSig false "isCoreImport" (TyFun (TyCon "UsePath") (TyCon "Bool")))
(DFunDef false "isCoreImport" ((PVar "p")) (EBinOp "==" (EApp (EVar "useHead") (EVar "p")) (ELit (LString "core"))))
(DTypeSig false "useHead" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "useHead" ((PCon "UseName" (PVar "ns"))) (EApp (EApp (EVar "headOr") (ELit (LString ""))) (EVar "ns")))
(DFunDef false "useHead" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EApp (EVar "headOr") (ELit (LString ""))) (EVar "ns")))
(DFunDef false "useHead" ((PCon "UseWild" (PVar "ns"))) (EApp (EApp (EVar "headOr") (ELit (LString ""))) (EVar "ns")))
(DFunDef false "useHead" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EApp (EVar "headOr") (ELit (LString ""))) (EVar "ns")))
(DTypeSig false "headOr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "headOr" ((PVar "d") (PList)) (EVar "d"))
(DFunDef false "headOr" (PWild (PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "publishProjectDiagnostics" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "publishProjectDiagnostics" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "docs")) (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRoot") (EApp (EVar "dirOfPath") (EVar "rootFile")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EApp (EVar "lspMedakaRoot") (ELit (LString "."))) (ELit (LString "/stdlib")))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "projectCache")) (EVar "projectParseCache")) (EVar "read")) (EVar "rootFile")) (EListLit (EVar "projectDir") (EVar "stdlibDir"))) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoExpr (EApp (EVar "publishEach") (EVar "results")))))
(DTypeSig false "lspMedakaRoot" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "lspMedakaRoot" ((PVar "dflt")) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_ROOT"))) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (EVar "dflt") (EVar "v"))) (arm (PCon "None") () (EVar "dflt"))))
(DTypeSig false "publishEach" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "publishEach" ((PList)) (ELit LUnit))
(DFunDef false "publishEach" ((PCons (PTuple (PVar "file") (PVar "ds")) (PVar "rest"))) (EBlock (DoLet false false (PVar "uri") (EApp (EVar "uriOfPath") (EVar "file"))) (DoLet false false (PVar "params") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EApp (EVar "diagToJson") (ELit (LString "")))) (EVar "ds"))))))) (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "notificationMsg") (ELit (LString "textDocument/publishDiagnostics"))) (EVar "params")))) (DoExpr (EApp (EVar "publishEach") (EVar "rest")))))
(DTypeSig false "publishFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "publishFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "text") (PVar "docs")) (EIf (EApp (EVar "bufferHasImports") (EVar "text")) (EApp (EApp (EApp (EApp (EVar "publishProjectDiagnostics") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "docs")) (EApp (EApp (EApp (EApp (EVar "publishDiagnostics") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text"))))
(DTypeSig false "handleDidOpen" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs")))))))
(DFunDef false "handleDidOpen" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "text"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "text")) () (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "text")) (EVar "docs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "publishFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "docs2"))) (DoExpr (EVar "docs2"))))))))
(DTypeSig false "handleDidChange" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs")))))))
(DFunDef false "handleDidChange" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EVar "lastChangeText") (EApp (EApp (EVar "fieldOr") (ELit (LString "contentChanges"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "text")) () (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "text")) (EVar "docs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "publishFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "docs2"))) (DoExpr (EVar "docs2"))))))))
(DTypeSig false "handleFormatting" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleFormatting" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jArray") (EApp (EVar "formattingEdits") (EVar "src")))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "handleDocumentSymbol" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleDocumentSymbol" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jArray") (EApp (EVar "documentSymbols") (EVar "src")))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "handleDefinition" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleDefinition" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EVar "definitionResult") (EVar "uri")) (EVar "src")) (EVar "params"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "definitionResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json")))))
(DFunDef false "definitionResult" ((PVar "uri") (PVar "src") (PVar "params")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "name")) () (EMatch (EApp (EApp (EVar "definitionRange") (EVar "src")) (EVar "name")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "range")) () (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "range")) (EVar "range"))))))))))) (arm PWild () (EVar "JNull"))))
(DTypeSig false "handleHighlight" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleHighlight" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "highlightResult") (EVar "src")) (EVar "params"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "highlightResult" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "highlightResult" ((PVar "src") (PVar "params")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "name")) () (EApp (EVar "jArray") (EApp (EApp (EVar "highlightRanges") (EVar "src")) (EVar "name")))))) (arm PWild () (EVar "JNull"))))
(DTypeSig false "handleSemanticTokens" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleSemanticTokens" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "data")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JInt")) (EApp (EVar "semanticTokensData") (EVar "src")))))))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "lastChangeText" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "lastChangeText" ((PCon "JArray" (PVar "arr"))) (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "fieldStr") (ELit (LString "text"))) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "lastChangeText" (PWild) (EVar "None"))
(DTypeSig false "fieldOr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "fieldOr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig false "fieldStr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "fieldStr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asString") (EVar "v"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "requestId" (TyFun (TyCon "Json") (TyCon "Json")))
(DFunDef false "requestId" ((PVar "msg")) (EApp (EApp (EVar "fieldOr") (ELit (LString "id"))) (EVar "msg")))
(DTypeSig false "methodOf" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "methodOf" ((PVar "msg")) (EApp (EApp (EVar "fieldStr") (ELit (LString "method"))) (EVar "msg")))
(DData Public "Step" () ((variant "Step" (ConPos (TyCon "Docs") (TyCon "Bool")))) ())
(DTypeSig false "dispatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Step")))))))
(DFunDef false "dispatch" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "msg") (PVar "docs")) (EMatch (EApp (EVar "methodOf") (EVar "msg")) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True"))) (arm (PCon "Some" (PVar "meth")) () (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialize"))) (EBlock (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EApp (EVar "requestId") (EVar "msg"))) (EVar "initializeResult")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialized"))) (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/didOpen"))) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EApp (EVar "handleDidOpen") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/didChange"))) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EApp (EVar "handleDidChange") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/formatting"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleFormatting") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/documentSymbol"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleDocumentSymbol") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/definition"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleDefinition") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/documentHighlight"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleHighlight") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/hover"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleHover") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/completion"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleCompletion") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/inlayHint"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleInlayHint") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/semanticTokens/full"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleSemanticTokens") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "shutdown"))) (EBlock (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EApp (EVar "requestId") (EVar "msg"))) (EVar "JNull")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "exit"))) (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "exit (clean shutdown)")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False")))) (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))))))))))))))))))
(DTypeSig false "serveOnce" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Step"))))))
(DFunDef false "serveOnce" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "docs")) (EMatch (EApp (EVar "readHeaders") (ELit (LInt 0))) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False"))) (arm (PCon "Some" (PVar "len")) () (EMatch (EApp (EVar "readExactly") (EVar "len")) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False"))) (arm (PCon "Some" (PVar "body")) () (EBlock (DoLet false false PWild (EApp (EVar "logLine") (EApp (EVar "stringConcat") (EListLit (ELit (LString "recv ")) (EVar "body"))))) (DoExpr (EMatch (EApp (EVar "parse") (EVar "body")) (arm (PCon "Err" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "  parse-error: malformed JSON body (skipped)")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True"))))) (arm (PCon "Ok" (PVar "msg")) () (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EApp (EVar "dispatch") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "msg")) (EVar "docs"))) (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "  handled")))) (DoExpr (EVar "step"))))))))))))
(DTypeSig false "serve" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "serve" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "docs")) (EMatch (EApp (EApp (EApp (EVar "serveOnce") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "docs")) (arm (PCon "Step" PWild (PCon "False")) () (EVar "unit")) (arm (PCon "Step" (PVar "docs2") (PCon "True")) () (EApp (EApp (EApp (EVar "serve") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "docs2")))))
(DTypeSig true "runServer" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "runServer" ((PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "=== medaka-lsp session start ===")))) (DoExpr (EApp (EApp (EApp (EVar "serve") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "emptyDocs")))))
(DTypeSig false "unit" (TyCon "Unit"))
(DFunDef false "unit" () (ELit LUnit))
# MARK
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JNull" false) (mem "JBool" false) (mem "JInt" false) (mem "JString" false) (mem "JArray" false) (mem "JObject" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false) (mem "lookup" false) (mem "asString" false) (mem "asInt" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" false) (mem "Severity" false) (mem "SevError" false) (mem "SevWarning" false) (mem "analyzeLocated" false) (mem "analyzeProject" false) (mem "projectEntrySchemes" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "findProjectRoot" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "ParseError" false) (mem "parseResult" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false) (mem "parseWithPositions" false) (mem "parseWithPositionsOpt" false) (mem "positionsDecls" false) (mem "DeclPos" false) (mem "declPosLine" false) (mem "declPosEndLine" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Token" true) (mem "tokenizeWithOffsetPairs" false))))
(DUse false (UseGroup ("support" "char") ((mem "isIdentChar" false) (mem "isDigit" false))))
(DUse false (UseGroup ("support" "util") ((mem "maxI" false) (mem "utf8Len" false) (mem "joinWith" false))))
(DUse false (UseGroup ("io") ((mem "stripCR" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "checkProgramSchemes" false) (mem "checkProgramSchemesWithRuntime" false) (mem "ppSchemeNamed" false) (mem "Scheme" true) (mem "currentLocalSchemes" false) (mem "currentSeedSchemes" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSource" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DTypeSig" false) (mem "DExtern" false) (mem "DFunDef" false) (mem "DData" false) (mem "DUse" false) (mem "DEffect" false) (mem "DProp" false) (mem "DTest" false) (mem "DBench" false) (mem "DInterface" false) (mem "DImpl" false) (mem "DTypeAlias" false) (mem "DNewtype" false) (mem "DLetGroup" false) (mem "DAttrib" false) (mem "Ty" false) (mem "TyEffect" false) (mem "Loc" true) (mem "Variant" false) (mem "ConPayload" true) (mem "Field" false) (mem "IfaceMethod" false) (mem "ImplMethod" false) (mem "LetBind" false) (mem "UsePath" false) (mem "UseName" false) (mem "UseGroup" false) (mem "UseWild" false) (mem "UseAlias" false))))
(DData Public "Docs" () ((variant "Docs" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))) ())
(DTypeSig false "emptyDocs" (TyCon "Docs"))
(DFunDef false "emptyDocs" () (EApp (EVar "Docs") (EListLit)))
(DTypeSig false "docsPut" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyCon "Docs")))))
(DFunDef false "docsPut" ((PVar "uri") (PVar "src") (PCon "Docs" (PVar "xs"))) (EApp (EVar "Docs") (EBinOp "::" (ETuple (EVar "uri") (EVar "src")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "xs")))))
(DTypeSig false "docsRemove" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "docsRemove" (PWild (PList)) (EListLit))
(DFunDef false "docsRemove" ((PVar "uri") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "uri")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EVar "docsRemove") (EVar "uri")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "jPosition" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "jPosition" ((PVar "line") (PVar "ch")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "ch"))))))
(DTypeSig false "jRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))))
(DFunDef false "jRange" ((PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "start")) (EApp (EApp (EVar "jPosition") (EVar "sl")) (EVar "sc"))) (ETuple (ELit (LString "end")) (EApp (EApp (EVar "jPosition") (EVar "el")) (EVar "ec"))))))
(DTypeSig false "jDiagnostic" (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "jDiagnostic" ((PVar "sev") (PVar "range") (PVar "msg")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EVar "range")) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (EVar "sev"))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "msg"))))))
(DTypeSig false "severityCode" (TyFun (TyCon "Severity") (TyCon "Int")))
(DFunDef false "severityCode" ((PCon "SevError")) (ELit (LInt 1)))
(DFunDef false "severityCode" ((PCon "SevWarning")) (ELit (LInt 2)))
(DTypeSig false "countLines" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "countLines" ((PVar "src")) (EApp (EApp (EApp (EVar "countLinesGo") (EApp (EVar "stringToChars") (EVar "src"))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "countLinesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "countLinesGo" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EVar "countLinesGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "countLinesGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "wholeDocRange" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "wholeDocRange" ((PVar "src")) (EApp (EApp (EApp (EApp (EVar "jRange") (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "countLines") (EVar "src"))) (ELit (LInt 0))))
(DTypeSig false "rangeOfLoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Json"))))
(DFunDef false "rangeOfLoc" ((PVar "src") (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EApp (EApp (EApp (EApp (EVar "jRange") (EBinOp "-" (EVar "sl") (ELit (LInt 1)))) (EVar "sc")) (EBinOp "-" (EVar "el") (ELit (LInt 1)))) (EVar "ec")))
(DFunDef false "rangeOfLoc" ((PVar "src") (PCon "None")) (EApp (EVar "wholeDocRange") (EVar "src")))
(DTypeSig false "diagToJson" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "Json"))))
(DFunDef false "diagToJson" ((PVar "src") (PCon "Diag" (PVar "sev") PWild (PVar "msg") (PVar "loc") PWild PWild)) (EApp (EApp (EApp (EVar "jDiagnostic") (EApp (EVar "severityCode") (EVar "sev"))) (EApp (EApp (EVar "rangeOfLoc") (EVar "src")) (EVar "loc"))) (EVar "msg")))
(DTypeSig false "diagnosticsFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "diagnosticsFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false (PVar "ln") (EApp (EApp (EVar "maxI") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "parseErrorLine") (EVar "e")) (ELit (LInt 1))))) (DoLet false false (PVar "col") (EApp (EApp (EVar "maxI") (ELit (LInt 0))) (EApp (EVar "parseErrorCol") (EVar "e")))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "ln")) (EVar "col")) (EVar "ln")) (EBinOp "+" (EVar "col") (ELit (LInt 1))))) (DoExpr (EListLit (EApp (EApp (EApp (EVar "jDiagnostic") (ELit (LInt 1))) (EVar "r")) (EApp (EVar "parseErrorMessage") (EVar "e"))))))) (arm (PCon "Ok" PWild) () (EApp (EApp (EMethodRef "map") (EApp (EVar "diagToJson") (EVar "src"))) (EApp (EApp (EApp (EVar "analyzeLocated") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src"))))))
(DTypeSig false "docsGet" (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "docsGet" ((PVar "uri") (PCon "Docs" (PVar "xs"))) (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "xs")))
(DTypeSig false "docsLookup" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "docsLookup" (PWild (PList)) (EVar "None"))
(DFunDef false "docsLookup" ((PVar "uri") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "uri")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "docsLookup") (EVar "uri")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "fullDocRangeFmt" (TyFun (TyCon "String") (TyCon "Json")))
(DFunDef false "fullDocRangeFmt" ((PVar "src")) (EApp (EApp (EApp (EApp (EVar "jRange") (ELit (LInt 0))) (ELit (LInt 0))) (EBinOp "+" (EApp (EVar "countLines") (EVar "src")) (ELit (LInt 1)))) (ELit (LInt 0))))
(DTypeSig false "formattingEdits" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "formattingEdits" ((PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EListLit) (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EVar "fullDocRangeFmt") (EVar "src"))) (ETuple (ELit (LString "newText")) (EApp (EVar "JString") (EVar "formatted"))))))))))))
(DTypeSig false "offsetOfLineCol" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "offsetOfLineCol" ((PVar "arr") (PVar "line") (PVar "col")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "offsetGo") (EVar "arr")) (EApp (EVar "arrayLength") (EVar "arr"))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "line")) (EVar "col")))
(DTypeSig false "offsetGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))))))
(DFunDef false "offsetGo" ((PVar "arr") (PVar "len") (PVar "i") (PVar "curLine") (PVar "lineStart") (PVar "line") (PVar "col")) (EIf (EBinOp "==" (EVar "curLine") (EVar "line")) (EBlock (DoLet false false (PVar "pos") (EBinOp "+" (EVar "lineStart") (EVar "col"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "pos") (ELit (LInt 0))) (EBinOp "<" (EVar "pos") (EVar "len"))) (EApp (EVar "Some") (EVar "pos")) (EVar "None")))) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "offsetGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "curLine") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "line")) (EVar "col")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "offsetGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "curLine")) (EVar "lineStart")) (EVar "line")) (EVar "col")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "identStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "identStart" ((PVar "arr") (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EVar "identStart") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identStop" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "identStop" ((PVar "arr") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EApp (EVar "identStop") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "identifierAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "identifierAt" ((PVar "src") (PVar "line") (PVar "col")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "offsetOfLineCol") (EVar "arr")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "pos")) () (EIf (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EVar "arr")))) (EVar "None") (EBlock (DoLet false false (PVar "s") (EApp (EApp (EVar "identStart") (EVar "arr")) (EVar "pos"))) (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "identStop") (EVar "arr")) (EVar "len")) (EVar "pos"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EVar "s")) (EVar "e")) (EVar "src")))))))))))
(DTypeSig false "posOfOffset" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "posOfOffset" ((PVar "arr") (PVar "off")) (EApp (EApp (EApp (EApp (EApp (EVar "posOffGo") (EVar "arr")) (EVar "off")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "posOffGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int"))))))))
(DFunDef false "posOffGo" ((PVar "arr") (PVar "off") (PVar "i") (PVar "line") (PVar "lineStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "off")) (ETuple (EVar "line") (EBinOp "-" (EVar "off") (EVar "lineStart"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "posOffGo") (EVar "arr")) (EVar "off")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "posOffGo") (EVar "arr")) (EVar "off")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "line")) (EVar "lineStart")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "occurrences" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "occurrences" ((PVar "src") (PVar "name")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoLet false false (PVar "nlen") (EApp (EVar "stringLength") (EVar "name"))) (DoExpr (EIf (EBinOp "==" (EVar "nlen") (ELit (LInt 0))) (EListLit) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "occGo") (EVar "src")) (EVar "arr")) (EVar "len")) (EVar "name")) (EVar "nlen")) (ELit (LInt 0)))))))
(DTypeSig false "occGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "occGo" ((PVar "src") (PVar "arr") (PVar "len") (PVar "name") (PVar "nlen") (PVar "i")) (EIf (EBinOp ">" (EBinOp "+" (EVar "i") (EVar "nlen")) (EVar "len")) (EListLit) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "windowEq") (EVar "src")) (EVar "i")) (EVar "name")) (EVar "nlen")) (EBinOp "||" (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "arr")))))) (EBinOp "||" (EBinOp "==" (EBinOp "+" (EVar "i") (EVar "nlen")) (EVar "len")) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (EVar "nlen"))) (EVar "arr")))))) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "occGo") (EVar "src")) (EVar "arr")) (EVar "len")) (EVar "name")) (EVar "nlen")) (EBinOp "+" (EVar "i") (EVar "nlen")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "occGo") (EVar "src")) (EVar "arr")) (EVar "len")) (EVar "name")) (EVar "nlen")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "windowEq" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "windowEq" ((PVar "src") (PVar "i") (PVar "name") (PVar "nlen")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (EVar "nlen"))) (EVar "src")) (EVar "name")))
(DTypeSig false "highlightRanges" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json")))))
(DFunDef false "highlightRanges" ((PVar "src") (PVar "name")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "nlen") (EApp (EVar "stringLength") (EVar "name"))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "occToHighlight") (EVar "arr")) (EVar "nlen"))) (EApp (EApp (EVar "occurrences") (EVar "src")) (EVar "name"))))))
(DTypeSig false "occToHighlight" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json")))))
(DFunDef false "occToHighlight" ((PVar "arr") (PVar "nlen") (PVar "off")) (EMatch (EApp (EApp (EVar "posOfOffset") (EVar "arr")) (EVar "off")) (arm (PTuple (PVar "sl") (PVar "sc")) () (EMatch (EApp (EApp (EVar "posOfOffset") (EVar "arr")) (EBinOp "+" (EVar "off") (EVar "nlen"))) (arm (PTuple (PVar "el") (PVar "ec")) () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec"))))))))))
(DTypeSig false "innerDecl" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "innerDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "innerDecl") (EVar "d")))
(DFunDef false "innerDecl" ((PVar "d")) (EVar "d"))
(DTypeSig false "jSymbol" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyCon "Json"))))))
(DFunDef false "jSymbol" ((PVar "name") (PVar "kind") (PVar "range") (PVar "children")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JInt") (EVar "kind"))) (ETuple (ELit (LString "range")) (EVar "range")) (ETuple (ELit (LString "selectionRange")) (EVar "range")) (ETuple (ELit (LString "children")) (EApp (EVar "jArray") (EVar "children"))))))
(DTypeSig false "jChild" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyCon "Json")))))
(DFunDef false "jChild" ((PVar "name") (PVar "kind") (PVar "range")) (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (EVar "kind")) (EVar "range")) (EListLit)))
(DTypeSig false "variantName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "fieldName" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldName" ((PCon "Field" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "variantSymChildren" (TyFun (TyCon "Json") (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyCon "Json")))))
(DFunDef false "variantSymChildren" ((PVar "range") (PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") (PCon "True")))) (EApp (EApp (EMethodRef "map") (ELam ((PCon "Field" (PVar "fn") PWild)) (EApp (EApp (EApp (EVar "jChild") (EVar "fn")) (ELit (LInt 8))) (EVar "range")))) (EVar "fs")))
(DFunDef false "variantSymChildren" ((PVar "range") (PCon "Variant" (PVar "vn") PWild)) (EListLit (EApp (EApp (EApp (EVar "jChild") (EVar "vn")) (ELit (LInt 22))) (EVar "range"))))
(DTypeSig false "variantFieldNames" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "variantFieldNames" ((PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EApp (EMethodRef "map") (EVar "fieldName")) (EVar "fs")))
(DFunDef false "variantFieldNames" ((PCon "Variant" PWild (PCon "ConPos" PWild))) (EListLit))
(DTypeSig false "ifaceMethodName" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodName" ((PCon "IfaceMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "implMethodName" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodName" ((PCon "ImplMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "symbolOfDecl" (TyFun (TyCon "Decl") (TyFun (TyCon "DeclPos") (TyApp (TyCon "Option") (TyCon "Json")))))
(DFunDef false "symbolOfDecl" ((PVar "d") (PVar "dp")) (EBlock (DoLet false false (PVar "range") (EApp (EApp (EApp (EApp (EVar "jRange") (EBinOp "-" (EApp (EVar "declPosLine") (EVar "dp")) (ELit (LInt 1)))) (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "declPosEndLine") (EVar "dp")) (ELit (LInt 1)))) (ELit (LInt 0)))) (DoExpr (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "name") PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 13))) (EVar "range")) (EListLit)))) (arm (PCon "DExtern" PWild (PVar "name") PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 12))) (EVar "range")) (EListLit)))) (arm (PCon "DFunDef" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 12))) (EVar "range")) (EListLit)))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EMatch (EVar "binds") (arm (PList) () (EVar "None")) (arm (PCons (PCon "LetBind" (PVar "n0") PWild) PWild) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EMethodRef "map") (ELam ((PCon "LetBind" (PVar "n") PWild)) (EApp (EApp (EApp (EVar "jChild") (EVar "n")) (ELit (LInt 12))) (EVar "range")))) (EVar "binds"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "n0")) (ELit (LInt 12))) (EVar "range")) (EVar "kids")))))))) (arm (PCon "DData" PWild (PVar "name") PWild (PVar "variants") PWild) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "variantSymChildren") (EVar "range"))) (EVar "variants"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 10))) (EVar "range")) (EVar "kids")))))) (arm (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" (PVar "ms"))) true) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EMethodRef "map") (ELam ((PCon "IfaceMethod" (PVar "mn") PWild PWild)) (EApp (EApp (EApp (EVar "jChild") (EVar "mn")) (ELit (LInt 6))) (EVar "range")))) (EVar "ms"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "n")) (ELit (LInt 11))) (EVar "range")) (EVar "kids")))))) (arm (PRec "DImpl" ((rf "iface" (PVar "ifc")) (rf "methods" (PVar "ms"))) true) () (EBlock (DoLet false false (PVar "label") (EApp (EVar "implLabel") (EVar "ifc"))) (DoLet false false (PVar "kids") (EApp (EApp (EMethodRef "map") (ELam ((PCon "ImplMethod" (PVar "mn") PWild PWild)) (EApp (EApp (EApp (EVar "jChild") (EVar "mn")) (ELit (LInt 6))) (EVar "range")))) (EVar "ms"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "label")) (ELit (LInt 5))) (EVar "range")) (EVar "kids")))))) (arm (PCon "DTypeAlias" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 26))) (EVar "range")) (EListLit)))) (arm (PCon "DNewtype" PWild (PVar "name") PWild PWild PWild PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 23))) (EVar "range")) (EListLit)))) (arm (PCon "DUse" PWild PWild PWild) () (EVar "None")) (arm (PCon "DProp" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 12))) (EVar "range")) (EListLit)))) (arm (PCon "DTest" PWild (PVar "name") PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 12))) (EVar "range")) (EListLit)))) (arm (PCon "DBench" PWild (PVar "name") PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 12))) (EVar "range")) (EListLit)))) (arm (PCon "DEffect" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (ELit (LInt 24))) (EVar "range")) (EListLit)))) (arm (PCon "DAttrib" PWild PWild) () (EVar "None"))))))
(DTypeSig false "implLabel" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "implLabel" ((PVar "iface")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "impl ")) (EVar "iface"))))
(DTypeSig false "documentSymbols" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "documentSymbols" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EApp (EApp (EVar "symbolsZip") (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))))))
(DTypeSig false "symbolsZip" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyCon "Json")))))
(DFunDef false "symbolsZip" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps"))) (EMatch (EApp (EApp (EVar "symbolOfDecl") (EVar "d")) (EVar "p")) (arm (PCon "None") () (EApp (EApp (EVar "symbolsZip") (EVar "ds")) (EVar "ps"))) (arm (PCon "Some" (PVar "s")) () (EBinOp "::" (EVar "s") (EApp (EApp (EVar "symbolsZip") (EVar "ds")) (EVar "ps"))))))
(DFunDef false "symbolsZip" (PWild PWild) (EListLit))
(DTypeSig false "declDefines" (TyFun (TyCon "Decl") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "declDefines" ((PVar "d") (PVar "name")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DExtern" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DFunDef" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EApp (EApp (EVar "anyName") (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds"))) (EVar "name"))) (arm (PCon "DData" PWild (PVar "n") PWild (PVar "vs") PWild) () (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EApp (EVar "anyName") (EApp (EApp (EMethodRef "map") (EVar "variantName")) (EVar "vs"))) (EVar "name"))) (EApp (EApp (EVar "anyName") (EApp (EApp (EDictApp "flatMap") (EVar "variantFieldNames")) (EVar "vs"))) (EVar "name")))) (arm (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" (PVar "ms"))) true) () (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EApp (EVar "anyName") (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodName")) (EVar "ms"))) (EVar "name")))) (arm (PRec "DImpl" ((rf "methods" (PVar "ms"))) true) () (EApp (EApp (EVar "anyName") (EApp (EApp (EMethodRef "map") (EVar "implMethodName")) (EVar "ms"))) (EVar "name"))) (arm (PCon "DTypeAlias" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DNewtype" PWild (PVar "n") PWild (PVar "c") PWild PWild) () (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "name")) (EBinOp "==" (EVar "c") (EVar "name")))) (arm (PCon "DUse" PWild PWild PWild) () (EVar "False")) (arm (PCon "DProp" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DTest" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DBench" PWild (PVar "n") PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DEffect" PWild (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "DAttrib" PWild PWild) () (EVar "False"))))
(DTypeSig false "anyName" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "anyName" ((PList) PWild) (EVar "False"))
(DFunDef false "anyName" ((PCons (PVar "x") (PVar "xs")) (PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "name")) (EApp (EApp (EVar "anyName") (EVar "xs")) (EVar "name"))))
(DTypeSig false "definitionRange" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Json")))))
(DFunDef false "definitionRange" ((PVar "src") (PVar "name")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EApp (EApp (EApp (EVar "defZip") (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))) (EVar "name")))))
(DTypeSig false "defZip" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Json"))))))
(DFunDef false "defZip" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PVar "name")) (EIf (EApp (EApp (EVar "declDefines") (EVar "d")) (EVar "name")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "jRange") (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1)))) (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "declPosEndLine") (EVar "p")) (ELit (LInt 1)))) (ELit (LInt 0)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "defZip") (EVar "ds")) (EVar "ps")) (EVar "name")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "defZip" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "docSchemes" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "docSchemes" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "userRaw")) () (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugar") (EApp (EVar "unwrapDecls") (EApp (EVar "parseResult") (EVar "runtimeSrc"))))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugar") (EApp (EVar "unwrapDecls") (EApp (EVar "parseResult") (EVar "coreSrc"))))) (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EVar "userRaw"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EVar "checkProgramSchemesWithRuntime") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "userDecls"))))))))
(DTypeSig false "unwrapDecls" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "unwrapDecls" ((PCon "Ok" (PVar "ds"))) (EVar "ds"))
(DFunDef false "unwrapDecls" ((PCon "Err" PWild)) (EListLit))
(DTypeSig false "lookupSchemeL" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupSchemeL" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupSchemeL" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "n")) (EApp (EVar "Some") (EVar "s")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hoverFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "hoverFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "name")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "hoverEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "env")) () (EMatch (EApp (EApp (EVar "hoverScheme") (EVar "name")) (EVar "env")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "sch")) () (EBlock (DoLet false false (PVar "pfx") (EApp (EApp (EVar "sigLeadingEff") (EVar "name")) (EApp (EVar "unwrapDecls") (EApp (EVar "parseResult") (EVar "src"))))) (DoExpr (EApp (EApp (EVar "jHover") (EVar "name")) (EApp (EVar "stringConcat") (EListLit (EVar "pfx") (EApp (EApp (EVar "ppSchemeNamed") (EVar "name")) (EVar "sch")))))))))))))) (arm PWild () (EVar "JNull"))))
(DTypeSig false "hoverEnvFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))))
(DFunDef false "hoverEnvFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EIf (EApp (EVar "bufferHasImports") (EVar "src")) (EApp (EApp (EApp (EApp (EVar "projectEntryEnv") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "docs")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "docSchemes") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "projectEntryEnv" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))))
(DFunDef false "projectEntryEnv" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "docs")) (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRoot") (EApp (EVar "dirOfPath") (EVar "rootFile")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EApp (EVar "lspMedakaRoot") (ELit (LString "."))) (ELit (LString "/stdlib")))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectEntrySchemes") (EVar "projectCache")) (EVar "projectParseCache")) (EVar "read")) (EVar "rootFile")) (EListLit (EVar "projectDir") (EVar "stdlibDir"))) (EVar "runtimeSrc")) (EVar "coreSrc")))))
(DTypeSig false "hoverScheme" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "hoverScheme" ((PVar "name") (PVar "env")) (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EVar "env")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EApp (EVar "currentLocalSchemes") (ELit LUnit))) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EApp (EVar "currentSeedSchemes") (ELit LUnit))))))))
(DTypeSig false "sigLeadingEff" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))
(DFunDef false "sigLeadingEff" (PWild (PList)) (ELit (LString "")))
(DFunDef false "sigLeadingEff" ((PVar "name") (PCons (PVar "d") (PVar "ds"))) (EMatch (EApp (EApp (EVar "sigLeadingEffOne") (EVar "name")) (EVar "d")) (arm (PCon "Some" (PVar "pfx")) () (EVar "pfx")) (arm (PCon "None") () (EApp (EApp (EVar "sigLeadingEff") (EVar "name")) (EVar "ds")))))
(DTypeSig false "sigLeadingEffOne" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "sigLeadingEffOne" ((PVar "name") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "sigLeadingEffOne") (EVar "name")) (EVar "d")))
(DFunDef false "sigLeadingEffOne" ((PVar "name") (PCon "DTypeSig" PWild (PVar "n") (PVar "ty"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "leadingEffOf") (EVar "ty")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "sigLeadingEffOne" (PWild PWild) (EVar "None"))
(DTypeSig false "leadingEffOf" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "leadingEffOf" ((PCon "TyEffect" (PVar "labels") (PVar "tail") PWild)) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (EApp (EApp (EVar "renderEffRow") (EVar "labels")) (EVar "tail")) (ELit (LString " "))))))
(DFunDef false "leadingEffOf" (PWild) (EVar "None"))
(DTypeSig false "renderEffRow" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "renderEffRow" ((PVar "labels") (PVar "tail")) (EBlock (DoLet false false (PVar "lbls") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "renderEffAtom")) (EVar "labels")))) (DoLet false false (PVar "body") (EMatch (EVar "tail") (arm (PCon "None") () (EVar "lbls")) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "lbls") (ELit (LString ""))) (EVar "v") (EApp (EVar "stringConcat") (EListLit (EVar "lbls") (ELit (LString " | ")) (EVar "v"))))))) (DoExpr (EApp (EVar "stringConcat") (EListLit (ELit (LString "<")) (EVar "body") (ELit (LString ">")))))))
(DTypeSig false "renderEffAtom" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "renderEffAtom" ((PTuple (PVar "nm") (PCon "None"))) (EVar "nm"))
(DFunDef false "renderEffAtom" ((PTuple (PVar "nm") (PCon "Some" (PLit (LString "_"))))) (EApp (EVar "stringConcat") (EListLit (EVar "nm") (ELit (LString " _")))))
(DFunDef false "renderEffAtom" ((PTuple (PVar "nm") (PCon "Some" (PVar "p")))) (EApp (EVar "stringConcat") (EListLit (EVar "nm") (ELit (LString " \"")) (EVar "p") (ELit (LString "\"")))))
(DTypeSig false "jHover" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "jHover" ((PVar "name") (PVar "ty")) (EBlock (DoLet false false (PVar "value") (EApp (EVar "stringConcat") (EListLit (ELit (LString "```medaka\n")) (EVar "name") (ELit (LString " : ")) (EVar "ty") (ELit (LString "\n```"))))) (DoExpr (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "contents")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (ELit (LString "markdown")))) (ETuple (ELit (LString "value")) (EApp (EVar "JString") (EVar "value")))))))))))
(DTypeSig false "handleHover" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleHover" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hoverFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "prefixBefore" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "prefixBefore" ((PVar "src") (PVar "line") (PVar "col")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "offsetOfLineStart") (EVar "arr")) (EVar "len")) (EVar "line")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "lineStart")) () (EBlock (DoLet false false (PVar "stop") (EBinOp "-" (EBinOp "+" (EVar "lineStart") (EVar "col")) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<" (EVar "stop") (EVar "lineStart")) (ELit (LString "")) (EIf (EBinOp ">=" (EVar "stop") (EVar "len")) (ELit (LString "")) (EIf (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "stop")) (EVar "arr")))) (ELit (LString "")) (EBlock (DoLet false false (PVar "start") (EApp (EApp (EApp (EVar "prefixStart") (EVar "arr")) (EVar "lineStart")) (EVar "stop"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EBinOp "+" (EVar "stop") (ELit (LInt 1)))) (EVar "src"))))))))))))))
(DTypeSig false "offsetOfLineStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "offsetOfLineStart" ((PVar "arr") (PVar "len") (PVar "line")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineStartGo") (EVar "arr")) (EVar "len")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "line")))
(DTypeSig false "lineStartGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))))
(DFunDef false "lineStartGo" ((PVar "arr") (PVar "len") (PVar "i") (PVar "curLine") (PVar "lineStart") (PVar "line")) (EIf (EBinOp "==" (EVar "curLine") (EVar "line")) (EApp (EVar "Some") (EVar "lineStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineStartGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "curLine") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "line")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lineStartGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "curLine")) (EVar "lineStart")) (EVar "line")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "prefixStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "prefixStart" ((PVar "arr") (PVar "lineStart") (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (EVar "lineStart")) (EVar "lineStart") (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EApp (EVar "prefixStart") (EVar "arr")) (EVar "lineStart")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "startsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "startsWith" ((PVar "p") (PVar "n")) (EBlock (DoLet false false (PVar "pl") (EApp (EVar "stringLength") (EVar "p"))) (DoExpr (EIf (EBinOp "==" (EVar "pl") (ELit (LInt 0))) (EVar "True") (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "n")) (EVar "pl")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "pl")) (EVar "n")) (EVar "p")))))))
(DTypeSig false "filterCompletions" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "filterCompletions" (PWild PWild (PList)) (EListLit))
(DFunDef false "filterCompletions" ((PVar "prefix") (PVar "seen") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "anyName") (EVar "seen")) (EVar "n")))) (EBinOp "::" (EApp (EApp (EVar "jCompletionItem") (EVar "n")) (EApp (EApp (EVar "ppSchemeNamed") (EVar "n")) (EVar "s"))) (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EBinOp "::" (EVar "n") (EVar "seen"))) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EVar "seen")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "jCompletionItem" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Json"))))
(DFunDef false "jCompletionItem" ((PVar "label") (PVar "detail")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "label")) (EApp (EVar "JString") (EVar "label"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JInt") (ELit (LInt 3)))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EVar "detail"))))))
(DTypeSig false "completionFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Json")))))))))
(DFunDef false "completionFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "params") (PVar "docs")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "completionEnvFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "env")) () (EBlock (DoLet false false (PVar "prefix") (EApp (EApp (EApp (EVar "prefixBefore") (EVar "src")) (EVar "line")) (EVar "col"))) (DoExpr (EApp (EVar "jArray") (EApp (EApp (EApp (EVar "filterCompletions") (EVar "prefix")) (EListLit)) (EVar "env")))))))) (arm PWild () (EVar "JNull"))))
(DTypeSig false "completionEnvFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))))
(DFunDef false "completionEnvFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src") (PVar "docs")) (EIf (EApp (EVar "bufferHasImports") (EVar "src")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "own")) (EBinOp "++" (EBinOp "++" (EVar "own") (EApp (EVar "currentLocalSchemes") (ELit LUnit))) (EApp (EVar "currentSeedSchemes") (ELit LUnit))))) (EApp (EApp (EApp (EApp (EVar "projectEntryEnv") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "docs"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "docSchemes") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "handleCompletion" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleCompletion" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "completionFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "src")) (EVar "params")) (EVar "docs"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "declBindingName" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "declBindingName" ((PVar "d")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DFunDef" PWild (PVar "n") PWild PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EMatch (EVar "binds") (arm (PCons (PCon "LetBind" (PVar "n") PWild) PWild) () (EApp (EVar "Some") (EVar "n"))) (arm (PList) () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "hasExplicitSig" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasExplicitSig" ((PList) PWild) (EVar "False"))
(DFunDef false "hasExplicitSig" ((PCons (PVar "d") (PVar "rest")) (PVar "name")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "n") PWild) () (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EApp (EVar "hasExplicitSig") (EVar "rest")) (EVar "name")))) (arm PWild () (EApp (EApp (EVar "hasExplicitSig") (EVar "rest")) (EVar "name")))))
(DTypeSig false "columnAfterName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "columnAfterName" ((PVar "src") (PVar "line")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "offsetOfLineStart") (EVar "arr")) (EVar "len")) (EVar "line")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "lineStart")) () (EBlock (DoLet false false (PVar "endCol") (EApp (EApp (EApp (EApp (EVar "identRunLen") (EVar "arr")) (EVar "len")) (EVar "lineStart")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "==" (EVar "endCol") (ELit (LInt 0))) (EVar "None") (EApp (EVar "Some") (EVar "endCol"))))))))))
(DTypeSig false "identRunLen" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "identRunLen" ((PVar "arr") (PVar "len") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\n"))) (EVar "acc") (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EApp (EVar "identRunLen") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "inlayHints" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "inlayHints" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src")) (EMatch (EApp (EApp (EApp (EVar "docSchemes") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "env")) () (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "decls")) (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions"))) (EVar "env")))))))
(DTypeSig false "inlayZip" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyCon "Json"))))))))
(DFunDef false "inlayZip" ((PVar "src") (PVar "allDecls") (PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps")) (PVar "env")) (EMatch (EApp (EVar "declBindingName") (EVar "d")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PVar "name")) () (EIf (EApp (EApp (EVar "hasExplicitSig") (EVar "allDecls")) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env")) (EMatch (EApp (EApp (EVar "lookupSchemeL") (EVar "name")) (EVar "env")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PVar "sch")) () (EMatch (EApp (EApp (EVar "columnAfterName") (EVar "src")) (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1)))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env"))) (arm (PCon "Some" (PVar "col")) () (EBinOp "::" (EApp (EApp (EApp (EVar "jInlayHint") (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1)))) (EVar "col")) (EApp (EVar "stringConcat") (EListLit (ELit (LString ": ")) (EApp (EApp (EVar "ppSchemeNamed") (EVar "name")) (EVar "sch"))))) (EApp (EApp (EApp (EApp (EApp (EVar "inlayZip") (EVar "src")) (EVar "allDecls")) (EVar "ds")) (EVar "ps")) (EVar "env")))))))))))
(DFunDef false "inlayZip" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "jInlayHint" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Json")))))
(DFunDef false "jInlayHint" ((PVar "line") (PVar "col") (PVar "label")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "position")) (EApp (EApp (EVar "jPosition") (EVar "line")) (EVar "col"))) (ETuple (ELit (LString "label")) (EApp (EVar "JString") (EVar "label"))) (ETuple (ELit (LString "paddingLeft")) (EApp (EVar "JBool") (EVar "True"))))))
(DTypeSig false "handleInlayHint" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "handleInlayHint" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jArray") (EApp (EApp (EApp (EVar "inlayHints") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src")))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "positionLine" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "positionLine" ((PVar "params")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "position"))) (EVar "params")) (arm (PCon "Some" (PVar "pos")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "line"))) (EVar "pos")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asInt") (EVar "v"))) (arm (PCon "None") () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "positionChar" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "positionChar" ((PVar "params")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "position"))) (EVar "params")) (arm (PCon "Some" (PVar "pos")) () (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "character"))) (EVar "pos")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asInt") (EVar "v"))) (arm (PCon "None") () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "requestUri" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "requestUri" ((PVar "params")) (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))))
(DTypeSig false "logFilePath" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "logFilePath" (PWild) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_LSP_LOG"))) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (ELit (LString "/tmp/medaka-lsp.log")) (EVar "v"))) (arm (PCon "None") () (ELit (LString "/tmp/medaka-lsp.log")))))
(DTypeSig false "logLine" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "logLine" ((PVar "s")) (EBlock (DoLet false false (PVar "ts") (EApp (EVar "wallTimeSec") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "appendFile") (EApp (EVar "logFilePath") (ELit LUnit))) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "floatToString") (EVar "ts")) (ELit (LString " ")) (EVar "s") (ELit (LString "\n")))))) (DoExpr (ELit LUnit))))
(DTypeSig false "writeMessage" (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeMessage" ((PVar "j")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "stringify") (EVar "j"))) (DoLet false false (PVar "n") (EApp (EVar "utf8Len") (EVar "body"))) (DoLet false false (PVar "header") (EApp (EVar "stringConcat") (EListLit (ELit (LString "Content-Length: ")) (EApp (EVar "intToString") (EVar "n")) (ELit (LString "\r\n\r\n"))))) (DoLet false false PWild (EApp (EVar "putStr") (EVar "header"))) (DoLet false false PWild (EApp (EVar "putStr") (EVar "body"))) (DoExpr (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig false "responseMsg" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "responseMsg" ((PVar "idJson") (PVar "result")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "id")) (EVar "idJson")) (ETuple (ELit (LString "result")) (EVar "result")))))
(DTypeSig false "notificationMsg" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "notificationMsg" ((PVar "meth") (PVar "params")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "jsonrpc")) (EApp (EVar "JString") (ELit (LString "2.0")))) (ETuple (ELit (LString "method")) (EApp (EVar "JString") (EVar "meth"))) (ETuple (ELit (LString "params")) (EVar "params")))))
(DData Public "Headers" () ((variant "Headers" (ConPos (TyCon "Int")))) ())
(DTypeSig false "readHeaders" (TyFun (TyCon "Int") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "readHeaders" ((PVar "lenAcc")) (EMatch (EApp (EVar "readLineOpt") (ELit LUnit)) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "raw")) () (EBlock (DoLet false false (PVar "line") (EApp (EVar "stripCR") (EVar "raw"))) (DoExpr (EIf (EBinOp "==" (EVar "line") (ELit (LString ""))) (EApp (EVar "Some") (EVar "lenAcc")) (EBlock (DoLet false false (PVar "lenAcc2") (EMatch (EApp (EVar "parseContentLength") (EVar "line")) (arm (PCon "Some" (PVar "n")) () (EVar "n")) (arm (PCon "None") () (EVar "lenAcc")))) (DoExpr (EApp (EVar "readHeaders") (EVar "lenAcc2"))))))))))
(DTypeSig false "parseContentLength" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "parseContentLength" ((PVar "line")) (EBlock (DoLet false false (PVar "prefix") (ELit (LString "Content-Length:"))) (DoLet false false (PVar "pn") (EApp (EVar "stringLength") (EVar "prefix"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "line")) (EVar "pn")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "pn")) (EVar "line")) (EVar "prefix"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EApp (EVar "stringToChars") (EApp (EApp (EApp (EVar "stringSlice") (EVar "pn")) (EApp (EVar "stringLength") (EVar "line"))) (EVar "line")))) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EApp (EApp (EApp (EVar "stringSlice") (EVar "pn")) (EApp (EVar "stringLength") (EVar "line"))) (EVar "line"))))) (ELit (LInt 0))) (EVar "False")) (EVar "None")))))
(DTypeSig false "parseDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "parseDigits" ((PVar "arr") (PVar "i") (PVar "n") (PVar "acc") (PVar "seen")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EIf (EVar "seen") (EApp (EVar "Some") (EVar "acc")) (EVar "None")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EVar "not") (EVar "seen"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "acc")) (EVar "seen")) (EIf (EApp (EVar "isDigit") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EBinOp "-" (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (ELit (LInt 48))))) (EVar "True")) (EIf (EVar "otherwise") (EIf (EVar "seen") (EApp (EVar "Some") (EVar "acc")) (EVar "None")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "semanticLegend" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "semanticLegend" () (EListLit (ELit (LString "keyword")) (ELit (LString "class")) (ELit (LString "macro")) (ELit (LString "function")) (ELit (LString "property")) (ELit (LString "string")) (ELit (LString "number")) (ELit (LString "selfParameter"))))
(DTypeSig false "semanticTokensOptions" (TyCon "Json"))
(DFunDef false "semanticTokensOptions" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "legend")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "tokenTypes")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EVar "semanticLegend")))) (ETuple (ELit (LString "tokenModifiers")) (EApp (EVar "jArray") (EListLit)))))) (ETuple (ELit (LString "full")) (EApp (EVar "JBool") (EVar "True"))))))
(DData Private "SMode" () ((variant "MExpr" (ConPos)) (variant "MType" (ConPos)) (variant "MDataHead" (ConPos)) (variant "MDataVariant" (ConPos)) (variant "MDataPayload" (ConPos)) (variant "MRecord" (ConPos)) (variant "MIfaceOne" (ConPos)) (variant "MIfaceMany" (ConPos))) ())
(DData Private "SemCtx" () ((variant "SemCtx" (ConPos (TyCon "Int") (TyCon "Bool") (TyCon "SMode")))) ())
(DTypeSig false "isKeywordTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isKeywordTok" ((PCon "TLet")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TRec")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TWith")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TMut")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TIn")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TIf")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TThen")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TElse")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TMatch")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TData")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TRecord")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TInterface")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TDefault")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TImpl")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TImport")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TExport")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TPublic")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TWhere")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TOf")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TRequires")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TDo")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TAs")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TExtern")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TDeriving")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TType")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TNewtype")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TProp")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TTest")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TBench")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TEffect")) (EVar "True"))
(DFunDef false "isKeywordTok" ((PCon "TFunction")) (EVar "True"))
(DFunDef false "isKeywordTok" (PWild) (EVar "False"))
(DTypeSig false "upperRole" (TyFun (TyCon "SMode") (TyCon "Int")))
(DFunDef false "upperRole" ((PCon "MExpr")) (ELit (LInt 2)))
(DFunDef false "upperRole" ((PCon "MDataVariant")) (ELit (LInt 2)))
(DFunDef false "upperRole" (PWild) (ELit (LInt 1)))
(DTypeSig false "roleOf" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "SMode") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "roleOf" ((PCon "TUpper" PWild) PWild PWild (PCon "MIfaceOne")) (EApp (EVar "Some") (ELit (LInt 7))))
(DFunDef false "roleOf" ((PCon "TUpper" PWild) PWild PWild (PCon "MIfaceMany")) (EApp (EVar "Some") (ELit (LInt 7))))
(DFunDef false "roleOf" ((PCon "TUpper" PWild) PWild PWild (PVar "mode")) (EApp (EVar "Some") (EApp (EVar "upperRole") (EVar "mode"))))
(DFunDef false "roleOf" ((PCon "TIdent" PWild) (PVar "depth") (PVar "lineStart") (PVar "mode")) (EIf (EBinOp "&&" (EVar "lineStart") (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EVar "Some") (ELit (LInt 3))) (EMatch (EVar "mode") (arm (PCon "MRecord") () (EApp (EVar "Some") (ELit (LInt 4)))) (arm PWild () (EVar "None")))))
(DFunDef false "roleOf" ((PCon "TBacktickIdent" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 3))))
(DFunDef false "roleOf" ((PCon "TString" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TChar" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpOpen" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpMid" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInterpEnd" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 5))))
(DFunDef false "roleOf" ((PCon "TInt" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 6))))
(DFunDef false "roleOf" ((PCon "TFloat" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 6))))
(DFunDef false "roleOf" ((PCon "TBool" PWild) PWild PWild PWild) (EApp (EVar "Some") (ELit (LInt 0))))
(DFunDef false "roleOf" ((PVar "t") PWild PWild PWild) (EIf (EApp (EVar "isKeywordTok") (EVar "t")) (EApp (EVar "Some") (ELit (LInt 0))) (EVar "None")))
(DTypeSig false "nextMode" (TyFun (TyCon "Token") (TyFun (TyCon "SMode") (TyCon "SMode"))))
(DFunDef false "nextMode" ((PCon "TData") PWild) (EVar "MDataHead"))
(DFunDef false "nextMode" ((PCon "TNewtype") PWild) (EVar "MDataHead"))
(DFunDef false "nextMode" ((PCon "TRecord") PWild) (EVar "MRecord"))
(DFunDef false "nextMode" ((PCon "TInterface") PWild) (EVar "MIfaceOne"))
(DFunDef false "nextMode" ((PCon "TImpl") PWild) (EVar "MIfaceOne"))
(DFunDef false "nextMode" ((PCon "TRequires") PWild) (EVar "MIfaceMany"))
(DFunDef false "nextMode" ((PCon "TDeriving") PWild) (EVar "MIfaceMany"))
(DFunDef false "nextMode" ((PCon "TExtern") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TType") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TOf") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TWhere") PWild) (EVar "MExpr"))
(DFunDef false "nextMode" ((PCon "TUpper" PWild) (PCon "MIfaceOne")) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TColon") (PCon "MRecord")) (EVar "MRecord"))
(DFunDef false "nextMode" ((PCon "TColon") PWild) (EVar "MType"))
(DFunDef false "nextMode" ((PCon "TEqual") (PCon "MDataHead")) (EVar "MDataVariant"))
(DFunDef false "nextMode" ((PCon "TEqual") (PCon "MRecord")) (EVar "MRecord"))
(DFunDef false "nextMode" ((PCon "TEqual") PWild) (EVar "MExpr"))
(DFunDef false "nextMode" ((PCon "TPipe") (PCon "MDataVariant")) (EVar "MDataVariant"))
(DFunDef false "nextMode" ((PCon "TPipe") (PCon "MDataPayload")) (EVar "MDataVariant"))
(DFunDef false "nextMode" ((PCon "TUpper" PWild) (PCon "MDataVariant")) (EVar "MDataPayload"))
(DFunDef false "nextMode" (PWild (PVar "mode")) (EVar "mode"))
(DData Public "SemTok" () ((variant "SemTok" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig false "classify" (TyFun (TyCon "Token") (TyFun (TyCon "SemCtx") (TyTuple (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "SemCtx")))))
(DFunDef false "classify" ((PCon "TIndent") (PCon "SemCtx" (PVar "depth") (PVar "ls") (PVar "mode"))) (ETuple (EVar "None") (EApp (EApp (EApp (EVar "SemCtx") (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "ls")) (EVar "mode"))))
(DFunDef false "classify" ((PCon "TDedent") (PCon "SemCtx" (PVar "depth") (PVar "ls") (PVar "mode"))) (ETuple (EVar "None") (EApp (EApp (EApp (EVar "SemCtx") (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "ls")) (EVar "mode"))))
(DFunDef false "classify" ((PCon "TNewline") (PCon "SemCtx" (PVar "depth") PWild (PVar "mode"))) (EBlock (DoLet false false (PVar "mode2") (EIf (EBinOp "<=" (EVar "depth") (ELit (LInt 0))) (EVar "MExpr") (EVar "mode"))) (DoExpr (ETuple (EVar "None") (EApp (EApp (EApp (EVar "SemCtx") (EVar "depth")) (EVar "True")) (EVar "mode2"))))))
(DFunDef false "classify" ((PVar "tok") (PCon "SemCtx" (PVar "depth") (PVar "ls") (PVar "mode"))) (ETuple (EApp (EApp (EApp (EApp (EVar "roleOf") (EVar "tok")) (EVar "depth")) (EVar "ls")) (EVar "mode")) (EApp (EApp (EApp (EVar "SemCtx") (EVar "depth")) (EVar "False")) (EApp (EApp (EVar "nextMode") (EVar "tok")) (EVar "mode")))))
(DTypeSig false "semToksOf" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "SemCtx") (TyApp (TyCon "List") (TyCon "SemTok")))))))
(DFunDef false "semToksOf" (PWild (PList) PWild PWild) (EListLit))
(DFunDef false "semToksOf" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "semToksOf" ((PVar "arr") (PCons (PVar "t") (PVar "ts")) (PCons (PTuple (PVar "s") (PVar "e")) (PVar "ps")) (PVar "ctx")) (EMatch (EApp (EApp (EVar "classify") (EVar "t")) (EVar "ctx")) (arm (PTuple (PVar "roleOpt") (PVar "ctx2")) () (EMatch (EVar "roleOpt") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2"))) (arm (PCon "Some" (PVar "ty")) () (EIf (EBinOp ">=" (EVar "s") (EVar "e")) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2")) (EMatch (ETuple (EApp (EApp (EVar "posOfOffset") (EVar "arr")) (EVar "s")) (EApp (EApp (EVar "posOfOffset") (EVar "arr")) (EVar "e"))) (arm (PTuple (PTuple (PVar "sl") (PVar "sc")) (PTuple (PVar "el") (PVar "ec"))) () (EIf (EBinOp "==" (EVar "sl") (EVar "el")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "SemTok") (EVar "sl")) (EVar "sc")) (EBinOp "-" (EVar "ec") (EVar "sc"))) (EVar "ty")) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2"))) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "ts")) (EVar "ps")) (EVar "ctx2")))))))))))
(DTypeSig false "encodeSemToks" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SemTok")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "encodeSemToks" (PWild PWild (PList)) (EListLit))
(DFunDef false "encodeSemToks" ((PVar "prevLine") (PVar "prevChar") (PCons (PCon "SemTok" (PVar "line") (PVar "ch") (PVar "len") (PVar "ty")) (PVar "rest"))) (EBlock (DoLet false false (PVar "dLine") (EBinOp "-" (EVar "line") (EVar "prevLine"))) (DoLet false false (PVar "dChar") (EIf (EBinOp "==" (EVar "dLine") (ELit (LInt 0))) (EBinOp "-" (EVar "ch") (EVar "prevChar")) (EVar "ch"))) (DoExpr (EBinOp "::" (EVar "dLine") (EBinOp "::" (EVar "dChar") (EBinOp "::" (EVar "len") (EBinOp "::" (EVar "ty") (EBinOp "::" (ELit (LInt 0)) (EApp (EApp (EApp (EVar "encodeSemToks") (EVar "line")) (EVar "ch")) (EVar "rest"))))))))))
(DTypeSig false "semanticTokensData" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "semanticTokensData" ((PVar "src")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "src"))) (DoExpr (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "toks") (PVar "pairs")) () (EApp (EApp (EApp (EVar "encodeSemToks") (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "semToksOf") (EVar "arr")) (EVar "toks")) (EVar "pairs")) (EApp (EApp (EApp (EVar "SemCtx") (ELit (LInt 0))) (EVar "True")) (EVar "MExpr")))))))))
(DTypeSig false "initializeResult" (TyCon "Json"))
(DFunDef false "initializeResult" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "capabilities")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "textDocumentSync")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "documentFormattingProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "documentSymbolProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "definitionProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "documentHighlightProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "hoverProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "completionProvider")) (EApp (EVar "jObject") (EListLit))) (ETuple (ELit (LString "inlayHintProvider")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "semanticTokensProvider")) (EVar "semanticTokensOptions"))))) (ETuple (ELit (LString "serverInfo")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (ELit (LString "medaka-lsp")))) (ETuple (ELit (LString "version")) (EApp (EVar "JString") (ELit (LString "0.1.0"))))))))))
(DTypeSig false "publishDiagnostics" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "publishDiagnostics" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "src")) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EVar "diagnosticsFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "src"))) (DoLet false false (PVar "params") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EVar "diags")))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "notificationMsg") (ELit (LString "textDocument/publishDiagnostics"))) (EVar "params"))))))
(DTypeSig false "projectCache" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "projectCache" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "projectParseCache" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "projectParseCache" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "pathOfUri" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "pathOfUri" ((PVar "uri")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "uri")) (ELit (LInt 7))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 7))) (EVar "uri")) (ELit (LString "file://")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 7))) (EApp (EVar "stringLength") (EVar "uri"))) (EVar "uri")) (EVar "uri")))
(DTypeSig false "uriOfPath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "uriOfPath" ((PVar "path")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "path")) (ELit (LInt 7))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 7))) (EVar "path")) (ELit (LString "file://")))) (EVar "path") (EApp (EVar "stringConcat") (EListLit (ELit (LString "file://")) (EVar "path")))))
(DTypeSig false "dirOfPath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirOfPath" ((PVar "path")) (EApp (EApp (EVar "dirGo") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "dirGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dirGo" ((PVar "path") (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "dirGo" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "dirGo") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "bufferHasImports" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "bufferHasImports" ((PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "False")) (arm (PCon "Ok" (PVar "decls")) () (EApp (EVar "anyImport") (EVar "decls")))))
(DTypeSig false "anyImport" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "anyImport" ((PList)) (EVar "False"))
(DFunDef false "anyImport" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isCoreImport") (EVar "path"))) (EApp (EVar "anyImport") (EVar "rest"))))
(DFunDef false "anyImport" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyImport") (EVar "rest")))
(DTypeSig false "isCoreImport" (TyFun (TyCon "UsePath") (TyCon "Bool")))
(DFunDef false "isCoreImport" ((PVar "p")) (EBinOp "==" (EApp (EVar "useHead") (EVar "p")) (ELit (LString "core"))))
(DTypeSig false "useHead" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "useHead" ((PCon "UseName" (PVar "ns"))) (EApp (EApp (EVar "headOr") (ELit (LString ""))) (EVar "ns")))
(DFunDef false "useHead" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EApp (EVar "headOr") (ELit (LString ""))) (EVar "ns")))
(DFunDef false "useHead" ((PCon "UseWild" (PVar "ns"))) (EApp (EApp (EVar "headOr") (ELit (LString ""))) (EVar "ns")))
(DFunDef false "useHead" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EApp (EVar "headOr") (ELit (LString ""))) (EVar "ns")))
(DTypeSig false "headOr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "headOr" ((PVar "d") (PList)) (EVar "d"))
(DFunDef false "headOr" (PWild (PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "publishProjectDiagnostics" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "publishProjectDiagnostics" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "docs")) (EBlock (DoLet false false (PVar "rootFile") (EApp (EVar "pathOfUri") (EVar "uri"))) (DoLet false false (PVar "projectDir") (EApp (EVar "findProjectRoot") (EApp (EVar "dirOfPath") (EVar "rootFile")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EApp (EVar "lspMedakaRoot") (ELit (LString "."))) (ELit (LString "/stdlib")))) (DoLet false false (PVar "read") (ELam ((PVar "path")) (EApp (EApp (EVar "docsGet") (EApp (EVar "uriOfPath") (EVar "path"))) (EVar "docs")))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "projectCache")) (EVar "projectParseCache")) (EVar "read")) (EVar "rootFile")) (EListLit (EVar "projectDir") (EVar "stdlibDir"))) (EVar "runtimeSrc")) (EVar "coreSrc"))) (DoExpr (EApp (EVar "publishEach") (EVar "results")))))
(DTypeSig false "lspMedakaRoot" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "lspMedakaRoot" ((PVar "dflt")) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_ROOT"))) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (EVar "dflt") (EVar "v"))) (arm (PCon "None") () (EVar "dflt"))))
(DTypeSig false "publishEach" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "publishEach" ((PList)) (ELit LUnit))
(DFunDef false "publishEach" ((PCons (PTuple (PVar "file") (PVar "ds")) (PVar "rest"))) (EBlock (DoLet false false (PVar "uri") (EApp (EVar "uriOfPath") (EVar "file"))) (DoLet false false (PVar "params") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EApp (EVar "diagToJson") (ELit (LString "")))) (EVar "ds"))))))) (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "notificationMsg") (ELit (LString "textDocument/publishDiagnostics"))) (EVar "params")))) (DoExpr (EApp (EVar "publishEach") (EVar "rest")))))
(DTypeSig false "publishFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "publishFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "uri") (PVar "text") (PVar "docs")) (EIf (EApp (EVar "bufferHasImports") (EVar "text")) (EApp (EApp (EApp (EApp (EVar "publishProjectDiagnostics") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "docs")) (EApp (EApp (EApp (EApp (EVar "publishDiagnostics") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text"))))
(DTypeSig false "handleDidOpen" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs")))))))
(DFunDef false "handleDidOpen" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "text"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "text")) () (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "text")) (EVar "docs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "publishFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "docs2"))) (DoExpr (EVar "docs2"))))))))
(DTypeSig false "handleDidChange" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Docs")))))))
(DFunDef false "handleDidChange" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "params") (PVar "docs")) (EMatch (EApp (EApp (EVar "fieldStr") (ELit (LString "uri"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "textDocument"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EVar "lastChangeText") (EApp (EApp (EVar "fieldOr") (ELit (LString "contentChanges"))) (EVar "params"))) (arm (PCon "None") () (EVar "docs")) (arm (PCon "Some" (PVar "text")) () (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EVar "docsPut") (EVar "uri")) (EVar "text")) (EVar "docs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "publishFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "uri")) (EVar "text")) (EVar "docs2"))) (DoExpr (EVar "docs2"))))))))
(DTypeSig false "handleFormatting" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleFormatting" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jArray") (EApp (EVar "formattingEdits") (EVar "src")))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "handleDocumentSymbol" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleDocumentSymbol" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jArray") (EApp (EVar "documentSymbols") (EVar "src")))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "handleDefinition" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleDefinition" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EVar "definitionResult") (EVar "uri")) (EVar "src")) (EVar "params"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "definitionResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json")))))
(DFunDef false "definitionResult" ((PVar "uri") (PVar "src") (PVar "params")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "name")) () (EMatch (EApp (EApp (EVar "definitionRange") (EVar "src")) (EVar "name")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "range")) () (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "range")) (EVar "range"))))))))))) (arm PWild () (EVar "JNull"))))
(DTypeSig false "handleHighlight" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleHighlight" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "highlightResult") (EVar "src")) (EVar "params"))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "highlightResult" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "highlightResult" ((PVar "src") (PVar "params")) (EMatch (ETuple (EApp (EVar "positionLine") (EVar "params")) (EApp (EVar "positionChar") (EVar "params"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EMatch (EApp (EApp (EApp (EVar "identifierAt") (EVar "src")) (EVar "line")) (EVar "col")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "name")) () (EApp (EVar "jArray") (EApp (EApp (EVar "highlightRanges") (EVar "src")) (EVar "name")))))) (arm PWild () (EVar "JNull"))))
(DTypeSig false "handleSemanticTokens" (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "handleSemanticTokens" ((PVar "idJson") (PVar "params") (PVar "docs")) (EBlock (DoLet false false (PVar "result") (EMatch (EApp (EVar "requestUri") (EVar "params")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "uri")) () (EMatch (EApp (EApp (EVar "docsGet") (EVar "uri")) (EVar "docs")) (arm (PCon "None") () (EVar "JNull")) (arm (PCon "Some" (PVar "src")) () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "data")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JInt")) (EApp (EVar "semanticTokensData") (EVar "src")))))))))))) (DoExpr (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EVar "idJson")) (EVar "result"))))))
(DTypeSig false "lastChangeText" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "lastChangeText" ((PCon "JArray" (PVar "arr"))) (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "fieldStr") (ELit (LString "text"))) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "lastChangeText" (PWild) (EVar "None"))
(DTypeSig false "fieldOr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyCon "Json"))))
(DFunDef false "fieldOr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EVar "JNull"))))
(DTypeSig false "fieldStr" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "fieldStr" ((PVar "key") (PVar "j")) (EMatch (EApp (EApp (EVar "lookup") (EVar "key")) (EVar "j")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "asString") (EVar "v"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "requestId" (TyFun (TyCon "Json") (TyCon "Json")))
(DFunDef false "requestId" ((PVar "msg")) (EApp (EApp (EVar "fieldOr") (ELit (LString "id"))) (EVar "msg")))
(DTypeSig false "methodOf" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "methodOf" ((PVar "msg")) (EApp (EApp (EVar "fieldStr") (ELit (LString "method"))) (EVar "msg")))
(DData Public "Step" () ((variant "Step" (ConPos (TyCon "Docs") (TyCon "Bool")))) ())
(DTypeSig false "dispatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Step")))))))
(DFunDef false "dispatch" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "msg") (PVar "docs")) (EMatch (EApp (EVar "methodOf") (EVar "msg")) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True"))) (arm (PCon "Some" (PVar "meth")) () (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialize"))) (EBlock (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EApp (EVar "requestId") (EVar "msg"))) (EVar "initializeResult")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "initialized"))) (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/didOpen"))) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EApp (EVar "handleDidOpen") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/didChange"))) (EBlock (DoLet false false (PVar "docs2") (EApp (EApp (EApp (EApp (EVar "handleDidChange") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs2")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/formatting"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleFormatting") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/documentSymbol"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleDocumentSymbol") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/definition"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleDefinition") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/documentHighlight"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleHighlight") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/hover"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleHover") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/completion"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleCompletion") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/inlayHint"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "handleInlayHint") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "textDocument/semanticTokens/full"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "handleSemanticTokens") (EApp (EVar "requestId") (EVar "msg"))) (EApp (EApp (EVar "fieldOr") (ELit (LString "params"))) (EVar "msg"))) (EVar "docs"))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "shutdown"))) (EBlock (DoLet false false PWild (EApp (EVar "writeMessage") (EApp (EApp (EVar "responseMsg") (EApp (EVar "requestId") (EVar "msg"))) (EVar "JNull")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))) (EIf (EBinOp "==" (EVar "meth") (ELit (LString "exit"))) (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "exit (clean shutdown)")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False")))) (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True")))))))))))))))))))
(DTypeSig false "serveOnce" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Step"))))))
(DFunDef false "serveOnce" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "docs")) (EMatch (EApp (EVar "readHeaders") (ELit (LInt 0))) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False"))) (arm (PCon "Some" (PVar "len")) () (EMatch (EApp (EVar "readExactly") (EVar "len")) (arm (PCon "None") () (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "False"))) (arm (PCon "Some" (PVar "body")) () (EBlock (DoLet false false PWild (EApp (EVar "logLine") (EApp (EVar "stringConcat") (EListLit (ELit (LString "recv ")) (EVar "body"))))) (DoExpr (EMatch (EApp (EVar "parse") (EVar "body")) (arm (PCon "Err" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "  parse-error: malformed JSON body (skipped)")))) (DoExpr (EApp (EApp (EVar "Step") (EVar "docs")) (EVar "True"))))) (arm (PCon "Ok" (PVar "msg")) () (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EApp (EVar "dispatch") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "msg")) (EVar "docs"))) (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "  handled")))) (DoExpr (EVar "step"))))))))))))
(DTypeSig false "serve" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Docs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "serve" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "docs")) (EMatch (EApp (EApp (EApp (EVar "serveOnce") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "docs")) (arm (PCon "Step" PWild (PCon "False")) () (EVar "unit")) (arm (PCon "Step" (PVar "docs2") (PCon "True")) () (EApp (EApp (EApp (EVar "serve") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "docs2")))))
(DTypeSig true "runServer" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "runServer" ((PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false PWild (EApp (EVar "logLine") (ELit (LString "=== medaka-lsp session start ===")))) (DoExpr (EApp (EApp (EApp (EVar "serve") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "emptyDocs")))))
(DTypeSig false "unit" (TyCon "Unit"))
(DFunDef false "unit" () (ELit LUnit))
