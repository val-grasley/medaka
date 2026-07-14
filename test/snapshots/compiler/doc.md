# META
source_lines=404
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/doc.mdk — the native `medaka doc` documentation extractor.
--
-- A faithful port of lib/doc.ml (the OCaml oracle), byte-identical output.
-- Harvests doc comments from the lexer's side-channel (collectComments),
-- matches them to top-level PUBLIC declarations by source position, looks up
-- inferred types from the typechecker (checkProgramSchemesWithRuntime, the same
-- single-file path lsp.mdk uses), and renders Markdown.
--
-- Mirrors lib/doc.ml exactly:
--   • comment_body / expand_comment / build_comment_tbl / find_doc_for_line
--   • value_sig / pp_data_variant / pp_record_fields / pp_requires / render_sig
--   • all_letgroup_entries / extract_entries / render_markdown
-- and the pre-desugar `pp_ty_prec` (lib/ast.ml) used for AST-rendered sigs —
-- compiler's types/typecheck.ppTy DROPS effect rows, so doc carries its own
-- precise ppTyP that renders <eff> like OCaml's pp_ty_prec.

import frontend.lexer.{Comment, collectComments, commentLine, commentText}
import frontend.parser.{
  parseWithPositions,
  Positions,
  DeclPos,
  positionsDecls,
  declPosLine,
}
import frontend.ast.{
  Decl(..),
  Ty(..),
  Constraint(..),
  DataVis(..),
  Variant(..),
  ConPayload(..),
  Field(..),
  IfaceMethod(..),
  Require(..),
  LetBind(..),
}
import frontend.desugar.{desugar}
import types.typecheck.{Scheme(..), ppScheme, checkProgramSchemesWithRuntime}
import support.util.{joinWith, reverseL, escStr, stringTrim}
import support.path.{baseOf, chopExt}

-- ── doc_entry ──────────────────────────────────────────────────────────────
-- de_name / de_sig (never empty) / de_doc (stripped doc prose, may be "").
data DocEntry = DocEntry String String String

-- ── small string helpers (builtins; mirror doctest's local wrappers) ────────
dlen : String -> Int
dlen s = stringLength s

-- stringSlice a b = chars [a, b)
dsub : Int -> Int -> String -> String
dsub a b s = stringSlice a b s

-- ── pre-desugar type rendering (mirror lib/ast.ml pp_ty_prec) ───────────────
-- NOTE: types/typecheck.ppTy drops `TyEffect` rows; OCaml pp_ty_prec renders
-- them, and interface method types carry effect rows.  So we mirror pp_ty_prec
-- here directly, precedence-passing.

ppTyP : Int -> Ty -> String
ppTyP _ (TyCon s _) = s
ppTyP _ (TyVar s) = s
ppTyP _ (TyTuple ts) = "(" ++ joinWith ", " (map (ppTyP 0) ts) ++ ")"
ppTyP p (TyApp f x) =
  let s = "\{ppTyP 1 f} \{ppTyP 2 x}"
  if p >= 2 then "(" ++ s ++ ")" else s
ppTyP p (TyFun a b) =
  let s = "\{ppTyP 1 a} -> \{ppTyP 0 b}"
  if p >= 1 then "(" ++ s ++ ")" else s
ppTyP p (TyEffect effs tail t) =
  let labs = map ppEffAtomDoc effs
  let inside = match tail
    None => joinWith ", " labs
    Some v => match effs
      [] => v
      _ => "\{joinWith ", " labs} | \{v}"
  let s = "<\{inside}> \{ppTyP 0 t}"
  if p >= 1 then "(" ++ s ++ ")" else s
ppTyP _ (TyConstrained cs t) =
  let csStr = match cs
    [c] => ppConstrDoc c
    _ => "(" ++ joinWith ", " (map ppConstrDoc cs) ++ ")"
  "\{csStr} => \{ppTyP 0 t}"

-- effect atom: `l` | `l _` (inferred hole) | `l "dom"` (domain-carrying).
-- Mirror pp_atom in pp_ty_prec: None=>l, Some "_" => l ++ " _", Some s => l ++ " " ++ %S
ppEffAtomDoc : (String, Option String) -> String
ppEffAtomDoc (l, None) = l
-- Intentional cross-file duplicate of the same helper in typecheck.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
ppEffAtomDoc (l, Some s) = if s == "_" then l ++ " _" else "\{l} \{escStr s}"

-- a constraint `Iface arg…` (mirror pp_c inside TyConstrained / pp_requires).
ppConstrDoc : Constraint -> String
ppConstrDoc (Constraint iface args) = match args
  [] => iface
  _ => "\{iface} \{joinWith " " (map (ppTyP 2) args)}"

ppTyDoc : Ty -> String
ppTyDoc t = ppTyP 0 t

-- ── Comment-text extraction (mirror lib/doc.ml) ─────────────────────────────

-- Strip the `-- ` prefix from a line-comment text, returning the bare prose.
--   "--"            -> ""
--   "-- foo"        -> "foo"   (3-char `-- ` prefix)
--   "--foo"         -> "foo"   (len>2, drop first 2)
commentBody : String -> String
commentBody t =
  if t == "--" then
    ""
  else if dlen t >= 3 && dsub 0 3 t == "-- " then
    dsub 3 (dlen t) t
  else if dlen t > 2 then
    dsub 2 (dlen t) t
  else
    ""

-- Expand a comment into (line, text) pairs.  Block comments expand to one entry
-- per inner line (bare trimmed, like lib/doc.ml expand_comment — NOT the
-- doctest `-- ` reshape).  Line comments → [(line, commentBody text)].
expandComment : Comment -> List (Int, String)
expandComment c =
  let t = commentText c
  if dlen t >= 2 && dsub 0 2 t == "{-" then
    let n = dlen t
    -- OCaml String.sub t 2 (n-4): start 2, LENGTH n-4 → end index n-2.
    -- stringSlice takes (start, end), so end = n-2 (drops the 2-char `-}`).
    let inner = if n >= 4 then dsub 2 (n - 2) t else ""
    expandBlockLines (commentLine c) 0 (splitNlDoc inner)
  else
    [(commentLine c, commentBody t)]

expandBlockLines : Int -> Int -> List String -> List (Int, String)
expandBlockLines _ _ [] = []
expandBlockLines baseLine i (line::rest) =
  (baseLine + i, stringTrim line) :: expandBlockLines baseLine (i + 1) rest

-- Split a string on '\n' (mirror doctest splitNl; String.split_on_char '\n').
splitNlDoc : String -> List String
splitNlDoc s =
  let cs = stringToChars s
  splitNlGoDoc cs (arrayLength cs) 0 0

splitNlGoDoc : Array Char -> Int -> Int -> Int -> List String
splitNlGoDoc cs n start i
  | i >= n = [charsSliceDoc cs start n]
  | arrayGetUnsafe i cs == '\n' =
    charsSliceDoc cs start i :: splitNlGoDoc cs n (i + 1) (i + 1)
  | otherwise = splitNlGoDoc cs n start (i + 1)

charsSliceDoc : Array Char -> Int -> Int -> String
charsSliceDoc cs a b = stringFromChars (arrayFromList (charsSliceGoDoc cs a b))

charsSliceGoDoc : Array Char -> Int -> Int -> List Char
charsSliceGoDoc cs a b
  | a >= b = []
  | otherwise = arrayGetUnsafe a cs :: charsSliceGoDoc cs (a + 1) b

-- ── comment table: line -> text (assoc list; later entries win, like
-- Hashtbl.replace which keeps the last inserted for a key) ──────────────────
-- We build an assoc list, then look up by line.  build_comment_tbl iterates
-- comments in order, replacing per line; for lookup we want the LAST text set
-- for a line.  We keep insertion order and `lookupLast` returns the last match.

buildCommentTbl : List Comment -> List (Int, String)
buildCommentTbl comments = concatMapDoc expandComment comments

concatMapDoc : (a -> List b) -> List a -> List b
concatMapDoc _ [] = []
concatMapDoc f (x::xs) = f x ++ concatMapDoc f xs

-- Find the LAST (line,text) pair whose line matches (mirrors Hashtbl.replace
-- semantics: the last insertion for a key wins).
lookupLineLast : List (Int, String) -> Int -> Option String
lookupLineLast tbl line = lookupLineLastGo tbl line None

lookupLineLastGo : List (Int, String) -> Int -> Option String -> Option String
lookupLineLastGo [] _ acc = acc
lookupLineLastGo ((l, t)::rest) line acc =
  if l == line then
    lookupLineLastGo rest line (Some t)
  else
    lookupLineLastGo rest line acc

-- Return doc prose for the decl at [startLine]: the maximal consecutive block
-- of comments immediately above it (no line gap).  Newline-joined + trimmed.
findDocForLine : List (Int, String) -> Int -> String
findDocForLine tbl startLine =
  stringTrim (joinWith "\n" (collectDocLines tbl (startLine - 1) []))

-- Collect backwards; accumulator ends up in ascending line order.
collectDocLines : List (Int, String) -> Int -> List String -> List String
collectDocLines tbl line acc = match lookupLineLast tbl line
  None => acc
  Some text => collectDocLines tbl (line - 1) (text::acc)

-- ── signature rendering (mirror lib/doc.ml) ─────────────────────────────────

ppDataVariant : Variant -> String
ppDataVariant (Variant name (ConPos [])) = name
ppDataVariant (Variant name (ConPos tys)) =
  "\{name} \{joinWith " " (map (ppTyP 2) tys)}"
ppDataVariant (Variant name (ConNamed fs _)) =
  "\{name} { \{joinWith ", " (map ppFieldDoc fs)} }"

ppFieldDoc : Field -> String
ppFieldDoc (Field fn ft) = "\{fn} : \{ppTyDoc ft}"

ppRequiresDoc : List Require -> String
ppRequiresDoc [] = ""
ppRequiresDoc rs = " requires " ++ joinWith ", " (map ppRequireOne rs)

ppRequireOne : Require -> String
ppRequireOne (Require iface tys) = match tys
  [] => iface
  _ => "\{iface} \{joinWith " " (map (ppTyP 2) tys)}"

-- Look up the inferred scheme for [name]; fall back to the AST annotation when
-- typecheck produced no scheme (partial results).  Mirror value_sig.
valueSig : String -> List (String, Scheme) -> Option Ty -> String
valueSig name schemes fallbackTy = match lookupScheme name schemes
  Some s => "\{name} : \{ppScheme s}"
  None => match fallbackTy
    Some ty => "\{name} : \{ppTyDoc ty}"
    None => name

-- Last match wins: checkProgramSeeded returns globalS ++ topSchemes, so the
-- user's top-level binding appears LAST (after any same-named interface method
-- scheme from the prelude).  OCaml check_program_impl returns results first
-- and uses List.assoc_opt (first match on a user-first list), so the two
-- are equivalent.  A last-match here mirrors OCaml's user-binding preference.
lookupScheme : String -> List (String, Scheme) -> Option Scheme
lookupScheme name schemes = lookupSchemeGo name schemes None

lookupSchemeGo : String -> List (String, Scheme) -> Option Scheme -> Option Scheme
lookupSchemeGo _ [] acc = acc
lookupSchemeGo name ((n, s)::rest) acc =
  if name == n then
    lookupSchemeGo name rest (Some s)
  else
    lookupSchemeGo name rest acc

-- A rendered interface method line: `  name : ty`.
ppIfaceMethod : IfaceMethod -> String
ppIfaceMethod (IfaceMethod mname mty _) = "  \{mname} : \{ppTyDoc mty}"

-- Compute (name, sig) for a public decl, or None to skip it.  Mirror render_sig.
renderSig : Decl -> List (String, Scheme) -> Option (String, String)
renderSig (DTypeSig True name ty) schemes =
  Some (name, valueSig name schemes (Some ty))
renderSig (DFunDef True name _ _) schemes =
  Some (name, valueSig name schemes None)
renderSig (DExtern True name ty) schemes =
  Some (name, valueSig name schemes (Some ty))
renderSig (DLetGroup True bindings) schemes = match bindings
  (LetBind name _)::_ => Some (name, valueSig name schemes None)
  [] => None
renderSig (DData vis name params variants _) _
  | not (dataVisPrivate vis) =
    let head = joinWith " " (name::params)
    let body = match variants
      [] => ""
      _ => "\n  = " ++ joinWith "\n  | " (map ppDataVariant variants)
    Some (name, "data \{head}\{body}")
renderSig (DInterface { pub = True, name, typarams, methods }) _ =
  let head = joinWith " " (name::typarams)
  let ms = map ppIfaceMethod methods
  let body = match ms
    [] => ""
    _ => "\n" ++ joinWith "\n" ms
  Some (name, "interface \{head}\{body}")
renderSig (DTypeAlias True name params ty) _ =
  let head = joinWith " " (name::params)
  Some (name, "type \{head} = \{ppTyDoc ty}")
renderSig (DNewtype True name params ctor ty _) _ =
  let head = joinWith " " (name::params)
  Some (name, "newtype \{head} = \{ctor} \{ppTyP 2 ty}")
renderSig (DImpl { pub = True, iface, tys, reqs }) _ =
  let args = match tys
    [] => ""
    _ => " " ++ joinWith " " (map (ppTyP 2) tys)
  Some (iface ++ args, "impl \{iface}\{args}\{ppRequiresDoc reqs}")
renderSig _ _ = None

dataVisPrivate : DataVis -> Bool
dataVisPrivate VisPrivate = True
dataVisPrivate _ = False

-- ── entry extraction (mirror lib/doc.ml) ────────────────────────────────────

-- Expand a public DLetGroup into one (name, DocEntry) per binding.
allLetgroupEntries : Bool -> List LetBind -> Int -> List (String, Scheme) -> List (Int, String) -> List (String, DocEntry)
allLetgroupEntries False _ _ _ _ = []
allLetgroupEntries True bindings line schemes tbl =
  let doc = findDocForLine tbl line
  letgroupEntriesGo bindings schemes doc

letgroupEntriesGo : List LetBind -> List (String, Scheme) -> String -> List (String, DocEntry)
letgroupEntriesGo [] _ _ = []
letgroupEntriesGo ((LetBind name _)::rest) schemes doc =
  let sigStr = valueSig name schemes None
  (name, DocEntry name sigStr doc) :: letgroupEntriesGo rest schemes doc

-- The driver: zip decls with their positions, fold collecting entries, dedup by
-- name (first wins), emit in source order.  Mirror extract_entries.
extractEntries : List Decl -> List DeclPos -> List (String, Scheme) -> List Comment -> List DocEntry
extractEntries decls positions schemes comments =
  let tbl = buildCommentTbl comments
  let pairs = zipDoc decls positions
  let result = extractFold pairs schemes tbl [] []
  reverseL (fst result)

-- Fold over (decl, pos) pairs.  State: (revEntries, seenNames).  Returns it.
extractFold : List (Decl, DeclPos) -> List (String, Scheme) -> List (Int, String) -> List DocEntry -> List String -> (List DocEntry, List String)
extractFold [] _ _ revEntries seen = (revEntries, seen)
extractFold ((decl, dp)::rest) schemes tbl revEntries seen =
  let line = declPosLine dp
  match letgroupOf decl
    Some (isPub, bindings) =>
      let extras = allLetgroupEntries isPub bindings line schemes tbl
      let acc = foldExtras extras revEntries seen
      extractFold rest schemes tbl (fst acc) (snd acc)
    None => match renderSig decl schemes
      None => extractFold rest schemes tbl revEntries seen
      Some (name, sigStr) => if memberStr name seen then extractFold rest schemes tbl revEntries seen
      else
        let doc = findDocForLine tbl line
        extractFold
          rest
          schemes
          tbl
          (DocEntry name sigStr doc :: revEntries)
          (name::seen)

-- Add each letgroup extra if its name is unseen (first wins).
foldExtras : List (String, DocEntry) -> List DocEntry -> List String -> (List DocEntry, List String)
foldExtras [] revEntries seen = (revEntries, seen)
foldExtras ((name, e)::rest) revEntries seen =
  if memberStr name seen then
    foldExtras rest revEntries seen
  else
    foldExtras rest (e::revEntries) (name::seen)

-- Match a DLetGroup, returning (is_pub, bindings) or None.
letgroupOf : Decl -> Option (Bool, List LetBind)
letgroupOf (DLetGroup isPub bindings) = Some (isPub, bindings)
letgroupOf _ = None

memberStr : String -> List String -> Bool
memberStr _ [] = False
memberStr x (y::ys)
  | x == y = True
  | otherwise = memberStr x ys

zipDoc : List a -> List b -> List (a, b)
zipDoc [] _ = []
zipDoc _ [] = []
zipDoc (x::xs) (y::ys) = (x, y) :: zipDoc xs ys

-- ── Markdown rendering (mirror render_markdown) ─────────────────────────────

renderMarkdown : String -> List DocEntry -> String
renderMarkdown moduleName entries =
  stringConcat ("# " ++ moduleName ++ "\n\n" :: map renderEntry entries)

renderEntry : DocEntry -> String
renderEntry (DocEntry name sig doc) =
  let header = "## `" ++ name ++ "`\n\n"
  let sigBlock = "```\n" ++ sig ++ "\n```\n"
  let docBlock = if doc == "" then "" else "\n" ++ doc ++ "\n"
  "\{header}\{sigBlock}\{docBlock}\n"

-- ── top-level driver ────────────────────────────────────────────────────────
-- Mirror bin/main.ml's `doc` arm: parse (capturing positions + comments),
-- typecheck a desugared copy for schemes ([] on type error), extract entries
-- from the RAW (pre-desugar) program + positions, render Markdown.
--
-- runtimeSrc / coreSrc are the prelude sources (runtime.mdk + core.mdk), read
-- by the caller from MEDAKA_ROOT; src is the target file; filename gives the
-- module-name basename.
export runDoc : String -> String -> String -> String -> String
runDoc runtimeSrc coreSrc src filename =
  let parsed = parseWithPositions src
  let rawDecls = fst parsed
  let positions = positionsDecls (snd parsed)
  let comments = collectComments src
  let schemes = docSchemesFor runtimeSrc coreSrc rawDecls
  let moduleName = chopExt (baseOf filename)
  let entries = extractEntries rawDecls positions schemes comments
  renderMarkdown moduleName entries

-- Inferred schemes via the single-file typecheck path (mirror lsp.docSchemes /
-- bin/main.ml: desugar prelude + user, checkProgramSchemesWithRuntime).  The
-- typechecker reports errors in-band rather than raising; compiler
-- checkProgramSchemesWithRuntime still returns the schemes it inferred, so doc
-- gets inferred types for the names that DID typecheck (OCaml falls to [] on a
-- hard error — divergence only for files with type errors, which are not the
-- doc happy path).
docSchemesFor : String -> String -> List Decl -> List (String, Scheme)
docSchemesFor runtimeSrc coreSrc rawUser =
  let runtimeDecls = desugar (fst (parseWithPositions runtimeSrc))
  let coreDecls = desugar (fst (parseWithPositions coreSrc))
  let userDecls = desugar rawUser
  checkProgramSchemesWithRuntime runtimeDecls coreDecls userDecls
# DESUGAR
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "collectComments" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseWithPositions" false) (mem "Positions" false) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Ty" true) (mem "Constraint" true) (mem "DataVis" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Field" true) (mem "IfaceMethod" true) (mem "Require" true) (mem "LetBind" true))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "Scheme" true) (mem "ppScheme" false) (mem "checkProgramSchemesWithRuntime" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "reverseL" false) (mem "escStr" false) (mem "stringTrim" false))))
(DUse false (UseGroup ("support" "path") ((mem "baseOf" false) (mem "chopExt" false))))
(DData Private "DocEntry" () ((variant "DocEntry" (ConPos (TyCon "String") (TyCon "String") (TyCon "String")))) ())
(DTypeSig false "dlen" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "dlen" ((PVar "s")) (EApp (EVar "stringLength") (EVar "s")))
(DTypeSig false "dsub" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "dsub" ((PVar "a") (PVar "b") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "a")) (EVar "b")) (EVar "s")))
(DTypeSig false "ppTyP" (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "ppTyP" (PWild (PCon "TyCon" (PVar "s") PWild)) (EVar "s"))
(DFunDef false "ppTyP" (PWild (PCon "TyVar" (PVar "s"))) (EVar "s"))
(DFunDef false "ppTyP" (PWild (PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EApp (EVar "ppTyP") (ELit (LInt 0)))) (EVar "ts")))) (ELit (LString ")"))))
(DFunDef false "ppTyP" ((PVar "p") (PCon "TyApp" (PVar "f") (PVar "x"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 1))) (EVar "f")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 2))) (EVar "x")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 2))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyP" ((PVar "p") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 1))) (EVar "a")))) (ELit (LString " -> "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "b")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyP" ((PVar "p") (PCon "TyEffect" (PVar "effs") (PVar "tail") (PVar "t"))) (EBlock (DoLet false false (PVar "labs") (EApp (EApp (EVar "map") (EVar "ppEffAtomDoc")) (EVar "effs"))) (DoLet false false (PVar "inside") (EMatch (EVar "tail") (arm (PCon "None") () (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "labs"))) (arm (PCon "Some" (PVar "v")) () (EMatch (EVar "effs") (arm (PList) () (EVar "v")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "labs")))) (ELit (LString " | "))) (EApp (EVar "display") (EVar "v"))) (ELit (LString "")))))))) (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EVar "inside"))) (ELit (LString "> "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "t")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyP" (PWild (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBlock (DoLet false false (PVar "csStr") (EMatch (EVar "cs") (arm (PList (PVar "c")) () (EApp (EVar "ppConstrDoc") (EVar "c"))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "ppConstrDoc")) (EVar "cs")))) (ELit (LString ")")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "csStr"))) (ELit (LString " => "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "t")))) (ELit (LString ""))))))
(DTypeSig false "ppEffAtomDoc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "ppEffAtomDoc" ((PTuple (PVar "l") (PCon "None"))) (EVar "l"))
(DFunDef false "ppEffAtomDoc" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EIf (EBinOp "==" (EVar "s") (ELit (LString "_"))) (EBinOp "++" (EVar "l") (ELit (LString " _"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "l"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "s")))) (ELit (LString "")))))
(DTypeSig false "ppConstrDoc" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "ppConstrDoc" ((PCon "Constraint" (PVar "iface") (PVar "args"))) (EMatch (EVar "args") (arm (PList) () (EVar "iface")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "args"))))) (ELit (LString ""))))))
(DTypeSig false "ppTyDoc" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTyDoc" ((PVar "t")) (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "t")))
(DTypeSig false "commentBody" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "commentBody" ((PVar "t")) (EIf (EBinOp "==" (EVar "t") (ELit (LString "--"))) (ELit (LString "")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 3))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 3))) (EVar "t")) (ELit (LString "-- ")))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 3))) (EApp (EVar "dlen") (EVar "t"))) (EVar "t")) (EIf (EBinOp ">" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EApp (EVar "dlen") (EVar "t"))) (EVar "t")) (ELit (LString ""))))))
(DTypeSig false "expandComment" (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))
(DFunDef false "expandComment" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "commentText") (EVar "c"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "t")) (ELit (LString "{-")))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "dlen") (EVar "t"))) (DoLet false false (PVar "inner") (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "t")) (ELit (LString "")))) (DoExpr (EApp (EApp (EApp (EVar "expandBlockLines") (EApp (EVar "commentLine") (EVar "c"))) (ELit (LInt 0))) (EApp (EVar "splitNlDoc") (EVar "inner"))))) (EListLit (ETuple (EApp (EVar "commentLine") (EVar "c")) (EApp (EVar "commentBody") (EVar "t"))))))))
(DTypeSig false "expandBlockLines" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))))
(DFunDef false "expandBlockLines" (PWild PWild (PList)) (EListLit))
(DFunDef false "expandBlockLines" ((PVar "baseLine") (PVar "i") (PCons (PVar "line") (PVar "rest"))) (EBinOp "::" (ETuple (EBinOp "+" (EVar "baseLine") (EVar "i")) (EApp (EVar "stringTrim") (EVar "line"))) (EApp (EApp (EApp (EVar "expandBlockLines") (EVar "baseLine")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "splitNlDoc" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitNlDoc" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "splitNlGoDoc") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))) (ELit (LInt 0))))))
(DTypeSig false "splitNlGoDoc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "splitNlGoDoc" ((PVar "cs") (PVar "n") (PVar "start") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "charsSliceDoc") (EVar "cs")) (EVar "start")) (EVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\n"))) (EBinOp "::" (EApp (EApp (EApp (EVar "charsSliceDoc") (EVar "cs")) (EVar "start")) (EVar "i")) (EApp (EApp (EApp (EApp (EVar "splitNlGoDoc") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "splitNlGoDoc") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "charsSliceDoc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "charsSliceDoc" ((PVar "cs") (PVar "a") (PVar "b")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "charsSliceGoDoc") (EVar "cs")) (EVar "a")) (EVar "b")))))
(DTypeSig false "charsSliceGoDoc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "charsSliceGoDoc" ((PVar "cs") (PVar "a") (PVar "b")) (EIf (EBinOp ">=" (EVar "a") (EVar "b")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "a")) (EVar "cs")) (EApp (EApp (EApp (EVar "charsSliceGoDoc") (EVar "cs")) (EBinOp "+" (EVar "a") (ELit (LInt 1)))) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "buildCommentTbl" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))
(DFunDef false "buildCommentTbl" ((PVar "comments")) (EApp (EApp (EVar "concatMapDoc") (EVar "expandComment")) (EVar "comments")))
(DTypeSig false "concatMapDoc" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "concatMapDoc" (PWild (PList)) (EListLit))
(DFunDef false "concatMapDoc" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "concatMapDoc") (EVar "f")) (EVar "xs"))))
(DTypeSig false "lookupLineLast" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lookupLineLast" ((PVar "tbl") (PVar "line")) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "tbl")) (EVar "line")) (EVar "None")))
(DTypeSig false "lookupLineLastGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "lookupLineLastGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "lookupLineLastGo" ((PCons (PTuple (PVar "l") (PVar "t")) (PVar "rest")) (PVar "line") (PVar "acc")) (EIf (EBinOp "==" (EVar "l") (EVar "line")) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "rest")) (EVar "line")) (EApp (EVar "Some") (EVar "t"))) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "rest")) (EVar "line")) (EVar "acc"))))
(DTypeSig false "findDocForLine" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "findDocForLine" ((PVar "tbl") (PVar "startLine")) (EApp (EVar "stringTrim") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EApp (EVar "collectDocLines") (EVar "tbl")) (EBinOp "-" (EVar "startLine") (ELit (LInt 1)))) (EListLit)))))
(DTypeSig false "collectDocLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectDocLines" ((PVar "tbl") (PVar "line") (PVar "acc")) (EMatch (EApp (EApp (EVar "lookupLineLast") (EVar "tbl")) (EVar "line")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "text")) () (EApp (EApp (EApp (EVar "collectDocLines") (EVar "tbl")) (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (EBinOp "::" (EVar "text") (EVar "acc"))))))
(DTypeSig false "ppDataVariant" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "ppDataVariant" ((PCon "Variant" (PVar "name") (PCon "ConPos" (PList)))) (EVar "name"))
(DFunDef false "ppDataVariant" ((PCon "Variant" (PVar "name") (PCon "ConPos" (PVar "tys")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "tys"))))) (ELit (LString ""))))
(DFunDef false "ppDataVariant" ((PCon "Variant" (PVar "name") (PCon "ConNamed" (PVar "fs") PWild))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " { "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "ppFieldDoc")) (EVar "fs"))))) (ELit (LString " }"))))
(DTypeSig false "ppFieldDoc" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "ppFieldDoc" ((PCon "Field" (PVar "fn") (PVar "ft"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "fn"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppTyDoc") (EVar "ft")))) (ELit (LString ""))))
(DTypeSig false "ppRequiresDoc" (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyCon "String")))
(DFunDef false "ppRequiresDoc" ((PList)) (ELit (LString "")))
(DFunDef false "ppRequiresDoc" ((PVar "rs")) (EBinOp "++" (ELit (LString " requires ")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "ppRequireOne")) (EVar "rs")))))
(DTypeSig false "ppRequireOne" (TyFun (TyCon "Require") (TyCon "String")))
(DFunDef false "ppRequireOne" ((PCon "Require" (PVar "iface") (PVar "tys"))) (EMatch (EVar "tys") (arm (PList) () (EVar "iface")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "tys"))))) (ELit (LString ""))))))
(DTypeSig false "valueSig" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "Option") (TyCon "Ty")) (TyCon "String")))))
(DFunDef false "valueSig" ((PVar "name") (PVar "schemes") (PVar "fallbackTy")) (EMatch (EApp (EApp (EVar "lookupScheme") (EVar "name")) (EVar "schemes")) (arm (PCon "Some" (PVar "s")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppScheme") (EVar "s")))) (ELit (LString "")))) (arm (PCon "None") () (EMatch (EVar "fallbackTy") (arm (PCon "Some" (PVar "ty")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppTyDoc") (EVar "ty")))) (ELit (LString "")))) (arm (PCon "None") () (EVar "name"))))))
(DTypeSig false "lookupScheme" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupScheme" ((PVar "name") (PVar "schemes")) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "schemes")) (EVar "None")))
(DTypeSig false "lookupSchemeGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "Option") (TyCon "Scheme")) (TyApp (TyCon "Option") (TyCon "Scheme"))))))
(DFunDef false "lookupSchemeGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "lookupSchemeGo" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest")) (PVar "acc")) (EIf (EBinOp "==" (EVar "name") (EVar "n")) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "rest")) (EApp (EVar "Some") (EVar "s"))) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "rest")) (EVar "acc"))))
(DTypeSig false "ppIfaceMethod" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ppIfaceMethod" ((PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "mname"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppTyDoc") (EVar "mty")))) (ELit (LString ""))))
(DTypeSig false "renderSig" (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "renderSig" ((PCon "DTypeSig" (PCon "True") (PVar "name") (PVar "ty")) (PVar "schemes")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EApp (EVar "Some") (EVar "ty"))))))
(DFunDef false "renderSig" ((PCon "DFunDef" (PCon "True") (PVar "name") PWild PWild) (PVar "schemes")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None")))))
(DFunDef false "renderSig" ((PCon "DExtern" (PCon "True") (PVar "name") (PVar "ty")) (PVar "schemes")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EApp (EVar "Some") (EVar "ty"))))))
(DFunDef false "renderSig" ((PCon "DLetGroup" (PCon "True") (PVar "bindings")) (PVar "schemes")) (EMatch (EVar "bindings") (arm (PCons (PCon "LetBind" (PVar "name") PWild) PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None"))))) (arm (PList) () (EVar "None"))))
(DFunDef false "renderSig" ((PCon "DData" (PVar "vis") (PVar "name") (PVar "params") (PVar "variants") PWild) PWild) (EIf (EApp (EVar "not") (EApp (EVar "dataVisPrivate") (EVar "vis"))) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EVar "params")))) (DoLet false false (PVar "body") (EMatch (EVar "variants") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString "\n  = ")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n  | "))) (EApp (EApp (EVar "map") (EVar "ppDataVariant")) (EVar "variants"))))))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "data ")) (EApp (EVar "display") (EVar "head"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "body"))) (ELit (LString ""))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "renderSig" ((PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" None) (rf "typarams" None) (rf "methods" None)) false) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EVar "typarams")))) (DoLet false false (PVar "ms") (EApp (EApp (EVar "map") (EVar "ppIfaceMethod")) (EVar "methods"))) (DoLet false false (PVar "body") (EMatch (EVar "ms") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString "\n")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "ms")))))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "interface ")) (EApp (EVar "display") (EVar "head"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "body"))) (ELit (LString ""))))))))
(DFunDef false "renderSig" ((PCon "DTypeAlias" (PCon "True") (PVar "name") (PVar "params") (PVar "ty")) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EVar "params")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type ")) (EApp (EVar "display") (EVar "head"))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EVar "ppTyDoc") (EVar "ty")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" ((PCon "DNewtype" (PCon "True") (PVar "name") (PVar "params") (PVar "ctor") (PVar "ty") PWild) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EVar "params")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "newtype ")) (EApp (EVar "display") (EVar "head"))) (ELit (LString " = "))) (EApp (EVar "display") (EVar "ctor"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 2))) (EVar "ty")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" ((PRec "DImpl" ((rf "pub" (PCon "True")) (rf "iface" None) (rf "tys" None) (rf "reqs" None)) false) PWild) (EBlock (DoLet false false (PVar "args") (EMatch (EVar "tys") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString " ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "tys"))))))) (DoExpr (EApp (EVar "Some") (ETuple (EBinOp "++" (EVar "iface") (EVar "args")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "args"))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "ppRequiresDoc") (EVar "reqs")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" (PWild PWild) (EVar "None"))
(DTypeSig false "dataVisPrivate" (TyFun (TyCon "DataVis") (TyCon "Bool")))
(DFunDef false "dataVisPrivate" ((PCon "VisPrivate")) (EVar "True"))
(DFunDef false "dataVisPrivate" (PWild) (EVar "False"))
(DTypeSig false "allLetgroupEntries" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))))
(DFunDef false "allLetgroupEntries" ((PCon "False") PWild PWild PWild PWild) (EListLit))
(DFunDef false "allLetgroupEntries" ((PCon "True") (PVar "bindings") (PVar "line") (PVar "schemes") (PVar "tbl")) (EBlock (DoLet false false (PVar "doc") (EApp (EApp (EVar "findDocForLine") (EVar "tbl")) (EVar "line"))) (DoExpr (EApp (EApp (EApp (EVar "letgroupEntriesGo") (EVar "bindings")) (EVar "schemes")) (EVar "doc")))))
(DTypeSig false "letgroupEntriesGo" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))
(DFunDef false "letgroupEntriesGo" ((PList) PWild PWild) (EListLit))
(DFunDef false "letgroupEntriesGo" ((PCons (PCon "LetBind" (PVar "name") PWild) (PVar "rest")) (PVar "schemes") (PVar "doc")) (EBlock (DoLet false false (PVar "sigStr") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None"))) (DoExpr (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EApp (EVar "DocEntry") (EVar "name")) (EVar "sigStr")) (EVar "doc"))) (EApp (EApp (EApp (EVar "letgroupEntriesGo") (EVar "rest")) (EVar "schemes")) (EVar "doc"))))))
(DTypeSig false "extractEntries" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "DocEntry")))))))
(DFunDef false "extractEntries" ((PVar "decls") (PVar "positions") (PVar "schemes") (PVar "comments")) (EBlock (DoLet false false (PVar "tbl") (EApp (EVar "buildCommentTbl") (EVar "comments"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "zipDoc") (EVar "decls")) (EVar "positions"))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "pairs")) (EVar "schemes")) (EVar "tbl")) (EListLit)) (EListLit))) (DoExpr (EApp (EVar "reverseL") (EApp (EVar "fst") (EVar "result"))))))
(DTypeSig false "extractFold" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "extractFold" ((PList) PWild PWild (PVar "revEntries") (PVar "seen")) (ETuple (EVar "revEntries") (EVar "seen")))
(DFunDef false "extractFold" ((PCons (PTuple (PVar "decl") (PVar "dp")) (PVar "rest")) (PVar "schemes") (PVar "tbl") (PVar "revEntries") (PVar "seen")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "declPosLine") (EVar "dp"))) (DoExpr (EMatch (EApp (EVar "letgroupOf") (EVar "decl")) (arm (PCon "Some" (PTuple (PVar "isPub") (PVar "bindings"))) () (EBlock (DoLet false false (PVar "extras") (EApp (EApp (EApp (EApp (EApp (EVar "allLetgroupEntries") (EVar "isPub")) (EVar "bindings")) (EVar "line")) (EVar "schemes")) (EVar "tbl"))) (DoLet false false (PVar "acc") (EApp (EApp (EApp (EVar "foldExtras") (EVar "extras")) (EVar "revEntries")) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "rest")) (EVar "schemes")) (EVar "tbl")) (EApp (EVar "fst") (EVar "acc"))) (EApp (EVar "snd") (EVar "acc")))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "renderSig") (EVar "decl")) (EVar "schemes")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "rest")) (EVar "schemes")) (EVar "tbl")) (EVar "revEntries")) (EVar "seen"))) (arm (PCon "Some" (PTuple (PVar "name") (PVar "sigStr"))) () (EIf (EApp (EApp (EVar "memberStr") (EVar "name")) (EVar "seen")) (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "rest")) (EVar "schemes")) (EVar "tbl")) (EVar "revEntries")) (EVar "seen")) (EBlock (DoLet false false (PVar "doc") (EApp (EApp (EVar "findDocForLine") (EVar "tbl")) (EVar "line"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "rest")) (EVar "schemes")) (EVar "tbl")) (EBinOp "::" (EApp (EApp (EApp (EVar "DocEntry") (EVar "name")) (EVar "sigStr")) (EVar "doc")) (EVar "revEntries"))) (EBinOp "::" (EVar "name") (EVar "seen")))))))))))))
(DTypeSig false "foldExtras" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry"))) (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "foldExtras" ((PList) (PVar "revEntries") (PVar "seen")) (ETuple (EVar "revEntries") (EVar "seen")))
(DFunDef false "foldExtras" ((PCons (PTuple (PVar "name") (PVar "e")) (PVar "rest")) (PVar "revEntries") (PVar "seen")) (EIf (EApp (EApp (EVar "memberStr") (EVar "name")) (EVar "seen")) (EApp (EApp (EApp (EVar "foldExtras") (EVar "rest")) (EVar "revEntries")) (EVar "seen")) (EApp (EApp (EApp (EVar "foldExtras") (EVar "rest")) (EBinOp "::" (EVar "e") (EVar "revEntries"))) (EBinOp "::" (EVar "name") (EVar "seen")))))
(DTypeSig false "letgroupOf" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LetBind"))))))
(DFunDef false "letgroupOf" ((PCon "DLetGroup" (PVar "isPub") (PVar "bindings"))) (EApp (EVar "Some") (ETuple (EVar "isPub") (EVar "bindings"))))
(DFunDef false "letgroupOf" (PWild) (EVar "None"))
(DTypeSig false "memberStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "memberStr" (PWild (PList)) (EVar "False"))
(DFunDef false "memberStr" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "memberStr") (EVar "x")) (EVar "ys")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "zipDoc" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b"))))))
(DFunDef false "zipDoc" ((PList) PWild) (EListLit))
(DFunDef false "zipDoc" (PWild (PList)) (EListLit))
(DFunDef false "zipDoc" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "::" (ETuple (EVar "x") (EVar "y")) (EApp (EApp (EVar "zipDoc") (EVar "xs")) (EVar "ys"))))
(DTypeSig false "renderMarkdown" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String"))))
(DFunDef false "renderMarkdown" ((PVar "moduleName") (PVar "entries")) (EApp (EVar "stringConcat") (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "# ")) (EVar "moduleName")) (ELit (LString "\n\n"))) (EApp (EApp (EVar "map") (EVar "renderEntry")) (EVar "entries")))))
(DTypeSig false "renderEntry" (TyFun (TyCon "DocEntry") (TyCon "String")))
(DFunDef false "renderEntry" ((PCon "DocEntry" (PVar "name") (PVar "sig") (PVar "doc"))) (EBlock (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (ELit (LString "## `")) (EVar "name")) (ELit (LString "`\n\n")))) (DoLet false false (PVar "sigBlock") (EBinOp "++" (EBinOp "++" (ELit (LString "```\n")) (EVar "sig")) (ELit (LString "\n```\n")))) (DoLet false false (PVar "docBlock") (EIf (EBinOp "==" (EVar "doc") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EVar "doc")) (ELit (LString "\n"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "header"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "sigBlock"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "docBlock"))) (ELit (LString "\n"))))))
(DTypeSig true "runDoc" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "runDoc" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src") (PVar "filename")) (EBlock (DoLet false false (PVar "parsed") (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PVar "rawDecls") (EApp (EVar "fst") (EVar "parsed"))) (DoLet false false (PVar "positions") (EApp (EVar "positionsDecls") (EApp (EVar "snd") (EVar "parsed")))) (DoLet false false (PVar "comments") (EApp (EVar "collectComments") (EVar "src"))) (DoLet false false (PVar "schemes") (EApp (EApp (EApp (EVar "docSchemesFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "rawDecls"))) (DoLet false false (PVar "moduleName") (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "filename")))) (DoLet false false (PVar "entries") (EApp (EApp (EApp (EApp (EVar "extractEntries") (EVar "rawDecls")) (EVar "positions")) (EVar "schemes")) (EVar "comments"))) (DoExpr (EApp (EApp (EVar "renderMarkdown") (EVar "moduleName")) (EVar "entries")))))
(DTypeSig false "docSchemesFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "docSchemesFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "rawUser")) (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugar") (EApp (EVar "fst") (EApp (EVar "parseWithPositions") (EVar "runtimeSrc"))))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugar") (EApp (EVar "fst") (EApp (EVar "parseWithPositions") (EVar "coreSrc"))))) (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EVar "rawUser"))) (DoExpr (EApp (EApp (EApp (EVar "checkProgramSchemesWithRuntime") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "userDecls")))))
# MARK
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "collectComments" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseWithPositions" false) (mem "Positions" false) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Ty" true) (mem "Constraint" true) (mem "DataVis" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Field" true) (mem "IfaceMethod" true) (mem "Require" true) (mem "LetBind" true))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "Scheme" true) (mem "ppScheme" false) (mem "checkProgramSchemesWithRuntime" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "reverseL" false) (mem "escStr" false) (mem "stringTrim" false))))
(DUse false (UseGroup ("support" "path") ((mem "baseOf" false) (mem "chopExt" false))))
(DData Private "DocEntry" () ((variant "DocEntry" (ConPos (TyCon "String") (TyCon "String") (TyCon "String")))) ())
(DTypeSig false "dlen" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "dlen" ((PVar "s")) (EApp (EVar "stringLength") (EVar "s")))
(DTypeSig false "dsub" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "dsub" ((PVar "a") (PVar "b") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "a")) (EVar "b")) (EVar "s")))
(DTypeSig false "ppTyP" (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "ppTyP" (PWild (PCon "TyCon" (PVar "s") PWild)) (EVar "s"))
(DFunDef false "ppTyP" (PWild (PCon "TyVar" (PVar "s"))) (EVar "s"))
(DFunDef false "ppTyP" (PWild (PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ppTyP") (ELit (LInt 0)))) (EVar "ts")))) (ELit (LString ")"))))
(DFunDef false "ppTyP" ((PVar "p") (PCon "TyApp" (PVar "f") (PVar "x"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 1))) (EVar "f")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 2))) (EVar "x")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 2))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyP" ((PVar "p") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 1))) (EVar "a")))) (ELit (LString " -> "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "b")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyP" ((PVar "p") (PCon "TyEffect" (PVar "effs") (PVar "tail") (PVar "t"))) (EBlock (DoLet false false (PVar "labs") (EApp (EApp (EMethodRef "map") (EVar "ppEffAtomDoc")) (EVar "effs"))) (DoLet false false (PVar "inside") (EMatch (EVar "tail") (arm (PCon "None") () (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "labs"))) (arm (PCon "Some" (PVar "v")) () (EMatch (EVar "effs") (arm (PList) () (EVar "v")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "labs")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "")))))))) (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EVar "inside"))) (ELit (LString "> "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "t")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyP" (PWild (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBlock (DoLet false false (PVar "csStr") (EMatch (EVar "cs") (arm (PList (PVar "c")) () (EApp (EVar "ppConstrDoc") (EVar "c"))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "ppConstrDoc")) (EVar "cs")))) (ELit (LString ")")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "csStr"))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "t")))) (ELit (LString ""))))))
(DTypeSig false "ppEffAtomDoc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "ppEffAtomDoc" ((PTuple (PVar "l") (PCon "None"))) (EVar "l"))
(DFunDef false "ppEffAtomDoc" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EIf (EBinOp "==" (EVar "s") (ELit (LString "_"))) (EBinOp "++" (EVar "l") (ELit (LString " _"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "s")))) (ELit (LString "")))))
(DTypeSig false "ppConstrDoc" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "ppConstrDoc" ((PCon "Constraint" (PVar "iface") (PVar "args"))) (EMatch (EVar "args") (arm (PList) () (EVar "iface")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "args"))))) (ELit (LString ""))))))
(DTypeSig false "ppTyDoc" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTyDoc" ((PVar "t")) (EApp (EApp (EVar "ppTyP") (ELit (LInt 0))) (EVar "t")))
(DTypeSig false "commentBody" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "commentBody" ((PVar "t")) (EIf (EBinOp "==" (EVar "t") (ELit (LString "--"))) (ELit (LString "")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 3))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 3))) (EVar "t")) (ELit (LString "-- ")))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 3))) (EApp (EVar "dlen") (EVar "t"))) (EVar "t")) (EIf (EBinOp ">" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EApp (EVar "dlen") (EVar "t"))) (EVar "t")) (ELit (LString ""))))))
(DTypeSig false "expandComment" (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))
(DFunDef false "expandComment" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "commentText") (EVar "c"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "dlen") (EVar "t")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "t")) (ELit (LString "{-")))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "dlen") (EVar "t"))) (DoLet false false (PVar "inner") (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EApp (EApp (EApp (EVar "dsub") (ELit (LInt 2))) (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "t")) (ELit (LString "")))) (DoExpr (EApp (EApp (EApp (EVar "expandBlockLines") (EApp (EVar "commentLine") (EVar "c"))) (ELit (LInt 0))) (EApp (EVar "splitNlDoc") (EVar "inner"))))) (EListLit (ETuple (EApp (EVar "commentLine") (EVar "c")) (EApp (EVar "commentBody") (EVar "t"))))))))
(DTypeSig false "expandBlockLines" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))))
(DFunDef false "expandBlockLines" (PWild PWild (PList)) (EListLit))
(DFunDef false "expandBlockLines" ((PVar "baseLine") (PVar "i") (PCons (PVar "line") (PVar "rest"))) (EBinOp "::" (ETuple (EBinOp "+" (EVar "baseLine") (EVar "i")) (EApp (EVar "stringTrim") (EVar "line"))) (EApp (EApp (EApp (EVar "expandBlockLines") (EVar "baseLine")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "splitNlDoc" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitNlDoc" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "splitNlGoDoc") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))) (ELit (LInt 0))))))
(DTypeSig false "splitNlGoDoc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "splitNlGoDoc" ((PVar "cs") (PVar "n") (PVar "start") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "charsSliceDoc") (EVar "cs")) (EVar "start")) (EVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\n"))) (EBinOp "::" (EApp (EApp (EApp (EVar "charsSliceDoc") (EVar "cs")) (EVar "start")) (EVar "i")) (EApp (EApp (EApp (EApp (EVar "splitNlGoDoc") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "splitNlGoDoc") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "charsSliceDoc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "charsSliceDoc" ((PVar "cs") (PVar "a") (PVar "b")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "charsSliceGoDoc") (EVar "cs")) (EVar "a")) (EVar "b")))))
(DTypeSig false "charsSliceGoDoc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "charsSliceGoDoc" ((PVar "cs") (PVar "a") (PVar "b")) (EIf (EBinOp ">=" (EVar "a") (EVar "b")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "a")) (EVar "cs")) (EApp (EApp (EApp (EVar "charsSliceGoDoc") (EVar "cs")) (EBinOp "+" (EVar "a") (ELit (LInt 1)))) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "buildCommentTbl" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))))
(DFunDef false "buildCommentTbl" ((PVar "comments")) (EApp (EApp (EVar "concatMapDoc") (EVar "expandComment")) (EVar "comments")))
(DTypeSig false "concatMapDoc" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "concatMapDoc" (PWild (PList)) (EListLit))
(DFunDef false "concatMapDoc" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "concatMapDoc") (EVar "f")) (EVar "xs"))))
(DTypeSig false "lookupLineLast" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lookupLineLast" ((PVar "tbl") (PVar "line")) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "tbl")) (EVar "line")) (EVar "None")))
(DTypeSig false "lookupLineLastGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "lookupLineLastGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "lookupLineLastGo" ((PCons (PTuple (PVar "l") (PVar "t")) (PVar "rest")) (PVar "line") (PVar "acc")) (EIf (EBinOp "==" (EVar "l") (EVar "line")) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "rest")) (EVar "line")) (EApp (EVar "Some") (EVar "t"))) (EApp (EApp (EApp (EVar "lookupLineLastGo") (EVar "rest")) (EVar "line")) (EVar "acc"))))
(DTypeSig false "findDocForLine" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "findDocForLine" ((PVar "tbl") (PVar "startLine")) (EApp (EVar "stringTrim") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EApp (EVar "collectDocLines") (EVar "tbl")) (EBinOp "-" (EVar "startLine") (ELit (LInt 1)))) (EListLit)))))
(DTypeSig false "collectDocLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectDocLines" ((PVar "tbl") (PVar "line") (PVar "acc")) (EMatch (EApp (EApp (EVar "lookupLineLast") (EVar "tbl")) (EVar "line")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "text")) () (EApp (EApp (EApp (EVar "collectDocLines") (EVar "tbl")) (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (EBinOp "::" (EVar "text") (EVar "acc"))))))
(DTypeSig false "ppDataVariant" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "ppDataVariant" ((PCon "Variant" (PVar "name") (PCon "ConPos" (PList)))) (EVar "name"))
(DFunDef false "ppDataVariant" ((PCon "Variant" (PVar "name") (PCon "ConPos" (PVar "tys")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "tys"))))) (ELit (LString ""))))
(DFunDef false "ppDataVariant" ((PCon "Variant" (PVar "name") (PCon "ConNamed" (PVar "fs") PWild))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " { "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "ppFieldDoc")) (EVar "fs"))))) (ELit (LString " }"))))
(DTypeSig false "ppFieldDoc" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "ppFieldDoc" ((PCon "Field" (PVar "fn") (PVar "ft"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "fn"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppTyDoc") (EVar "ft")))) (ELit (LString ""))))
(DTypeSig false "ppRequiresDoc" (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyCon "String")))
(DFunDef false "ppRequiresDoc" ((PList)) (ELit (LString "")))
(DFunDef false "ppRequiresDoc" ((PVar "rs")) (EBinOp "++" (ELit (LString " requires ")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "ppRequireOne")) (EVar "rs")))))
(DTypeSig false "ppRequireOne" (TyFun (TyCon "Require") (TyCon "String")))
(DFunDef false "ppRequireOne" ((PCon "Require" (PVar "iface") (PVar "tys"))) (EMatch (EVar "tys") (arm (PList) () (EVar "iface")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "tys"))))) (ELit (LString ""))))))
(DTypeSig false "valueSig" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "Option") (TyCon "Ty")) (TyCon "String")))))
(DFunDef false "valueSig" ((PVar "name") (PVar "schemes") (PVar "fallbackTy")) (EMatch (EApp (EApp (EVar "lookupScheme") (EVar "name")) (EVar "schemes")) (arm (PCon "Some" (PVar "s")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppScheme") (EVar "s")))) (ELit (LString "")))) (arm (PCon "None") () (EMatch (EVar "fallbackTy") (arm (PCon "Some" (PVar "ty")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppTyDoc") (EVar "ty")))) (ELit (LString "")))) (arm (PCon "None") () (EVar "name"))))))
(DTypeSig false "lookupScheme" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupScheme" ((PVar "name") (PVar "schemes")) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "schemes")) (EVar "None")))
(DTypeSig false "lookupSchemeGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "Option") (TyCon "Scheme")) (TyApp (TyCon "Option") (TyCon "Scheme"))))))
(DFunDef false "lookupSchemeGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "lookupSchemeGo" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest")) (PVar "acc")) (EIf (EBinOp "==" (EVar "name") (EVar "n")) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "rest")) (EApp (EVar "Some") (EVar "s"))) (EApp (EApp (EApp (EVar "lookupSchemeGo") (EVar "name")) (EVar "rest")) (EVar "acc"))))
(DTypeSig false "ppIfaceMethod" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ppIfaceMethod" ((PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "mname"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppTyDoc") (EVar "mty")))) (ELit (LString ""))))
(DTypeSig false "renderSig" (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "renderSig" ((PCon "DTypeSig" (PCon "True") (PVar "name") (PVar "ty")) (PVar "schemes")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EApp (EVar "Some") (EVar "ty"))))))
(DFunDef false "renderSig" ((PCon "DFunDef" (PCon "True") (PVar "name") PWild PWild) (PVar "schemes")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None")))))
(DFunDef false "renderSig" ((PCon "DExtern" (PCon "True") (PVar "name") (PVar "ty")) (PVar "schemes")) (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EApp (EVar "Some") (EVar "ty"))))))
(DFunDef false "renderSig" ((PCon "DLetGroup" (PCon "True") (PVar "bindings")) (PVar "schemes")) (EMatch (EVar "bindings") (arm (PCons (PCon "LetBind" (PVar "name") PWild) PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None"))))) (arm (PList) () (EVar "None"))))
(DFunDef false "renderSig" ((PCon "DData" (PVar "vis") (PVar "name") (PVar "params") (PVar "variants") PWild) PWild) (EIf (EApp (EVar "not") (EApp (EVar "dataVisPrivate") (EVar "vis"))) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EVar "params")))) (DoLet false false (PVar "body") (EMatch (EVar "variants") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString "\n  = ")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n  | "))) (EApp (EApp (EMethodRef "map") (EVar "ppDataVariant")) (EVar "variants"))))))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "data ")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "body"))) (ELit (LString ""))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "renderSig" ((PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" None) (rf "typarams" None) (rf "methods" None)) false) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EVar "typarams")))) (DoLet false false (PVar "ms") (EApp (EApp (EMethodRef "map") (EVar "ppIfaceMethod")) (EVar "methods"))) (DoLet false false (PVar "body") (EMatch (EVar "ms") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString "\n")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "ms")))))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "interface ")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "body"))) (ELit (LString ""))))))))
(DFunDef false "renderSig" ((PCon "DTypeAlias" (PCon "True") (PVar "name") (PVar "params") (PVar "ty")) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EVar "params")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type ")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EVar "ppTyDoc") (EVar "ty")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" ((PCon "DNewtype" (PCon "True") (PVar "name") (PVar "params") (PVar "ctor") (PVar "ty") PWild) PWild) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "name") (EVar "params")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "newtype ")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EVar "ctor"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyP") (ELit (LInt 2))) (EVar "ty")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" ((PRec "DImpl" ((rf "pub" (PCon "True")) (rf "iface" None) (rf "tys" None) (rf "reqs" None)) false) PWild) (EBlock (DoLet false false (PVar "args") (EMatch (EVar "tys") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBinOp "++" (ELit (LString " ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ppTyP") (ELit (LInt 2)))) (EVar "tys"))))))) (DoExpr (EApp (EVar "Some") (ETuple (EBinOp "++" (EVar "iface") (EVar "args")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "args"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "ppRequiresDoc") (EVar "reqs")))) (ELit (LString ""))))))))
(DFunDef false "renderSig" (PWild PWild) (EVar "None"))
(DTypeSig false "dataVisPrivate" (TyFun (TyCon "DataVis") (TyCon "Bool")))
(DFunDef false "dataVisPrivate" ((PCon "VisPrivate")) (EVar "True"))
(DFunDef false "dataVisPrivate" (PWild) (EVar "False"))
(DTypeSig false "allLetgroupEntries" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))))
(DFunDef false "allLetgroupEntries" ((PCon "False") PWild PWild PWild PWild) (EListLit))
(DFunDef false "allLetgroupEntries" ((PCon "True") (PVar "bindings") (PVar "line") (PVar "schemes") (PVar "tbl")) (EBlock (DoLet false false (PVar "doc") (EApp (EApp (EVar "findDocForLine") (EVar "tbl")) (EVar "line"))) (DoExpr (EApp (EApp (EApp (EVar "letgroupEntriesGo") (EVar "bindings")) (EVar "schemes")) (EVar "doc")))))
(DTypeSig false "letgroupEntriesGo" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry")))))))
(DFunDef false "letgroupEntriesGo" ((PList) PWild PWild) (EListLit))
(DFunDef false "letgroupEntriesGo" ((PCons (PCon "LetBind" (PVar "name") PWild) (PVar "rest")) (PVar "schemes") (PVar "doc")) (EBlock (DoLet false false (PVar "sigStr") (EApp (EApp (EApp (EVar "valueSig") (EVar "name")) (EVar "schemes")) (EVar "None"))) (DoExpr (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EApp (EVar "DocEntry") (EVar "name")) (EVar "sigStr")) (EVar "doc"))) (EApp (EApp (EApp (EVar "letgroupEntriesGo") (EVar "rest")) (EVar "schemes")) (EVar "doc"))))))
(DTypeSig false "extractEntries" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "DocEntry")))))))
(DFunDef false "extractEntries" ((PVar "decls") (PVar "positions") (PVar "schemes") (PVar "comments")) (EBlock (DoLet false false (PVar "tbl") (EApp (EVar "buildCommentTbl") (EVar "comments"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "zipDoc") (EVar "decls")) (EVar "positions"))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "pairs")) (EVar "schemes")) (EVar "tbl")) (EListLit)) (EListLit))) (DoExpr (EApp (EVar "reverseL") (EApp (EVar "fst") (EVar "result"))))))
(DTypeSig false "extractFold" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "extractFold" ((PList) PWild PWild (PVar "revEntries") (PVar "seen")) (ETuple (EVar "revEntries") (EVar "seen")))
(DFunDef false "extractFold" ((PCons (PTuple (PVar "decl") (PVar "dp")) (PVar "rest")) (PVar "schemes") (PVar "tbl") (PVar "revEntries") (PVar "seen")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "declPosLine") (EVar "dp"))) (DoExpr (EMatch (EApp (EVar "letgroupOf") (EVar "decl")) (arm (PCon "Some" (PTuple (PVar "isPub") (PVar "bindings"))) () (EBlock (DoLet false false (PVar "extras") (EApp (EApp (EApp (EApp (EApp (EVar "allLetgroupEntries") (EVar "isPub")) (EVar "bindings")) (EVar "line")) (EVar "schemes")) (EVar "tbl"))) (DoLet false false (PVar "acc") (EApp (EApp (EApp (EVar "foldExtras") (EVar "extras")) (EVar "revEntries")) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "rest")) (EVar "schemes")) (EVar "tbl")) (EApp (EVar "fst") (EVar "acc"))) (EApp (EVar "snd") (EVar "acc")))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "renderSig") (EVar "decl")) (EVar "schemes")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "rest")) (EVar "schemes")) (EVar "tbl")) (EVar "revEntries")) (EVar "seen"))) (arm (PCon "Some" (PTuple (PVar "name") (PVar "sigStr"))) () (EIf (EApp (EApp (EVar "memberStr") (EVar "name")) (EVar "seen")) (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "rest")) (EVar "schemes")) (EVar "tbl")) (EVar "revEntries")) (EVar "seen")) (EBlock (DoLet false false (PVar "doc") (EApp (EApp (EVar "findDocForLine") (EVar "tbl")) (EVar "line"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "extractFold") (EVar "rest")) (EVar "schemes")) (EVar "tbl")) (EBinOp "::" (EApp (EApp (EApp (EVar "DocEntry") (EVar "name")) (EVar "sigStr")) (EVar "doc")) (EVar "revEntries"))) (EBinOp "::" (EVar "name") (EVar "seen")))))))))))))
(DTypeSig false "foldExtras" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DocEntry"))) (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "DocEntry")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "foldExtras" ((PList) (PVar "revEntries") (PVar "seen")) (ETuple (EVar "revEntries") (EVar "seen")))
(DFunDef false "foldExtras" ((PCons (PTuple (PVar "name") (PVar "e")) (PVar "rest")) (PVar "revEntries") (PVar "seen")) (EIf (EApp (EApp (EVar "memberStr") (EVar "name")) (EVar "seen")) (EApp (EApp (EApp (EVar "foldExtras") (EVar "rest")) (EVar "revEntries")) (EVar "seen")) (EApp (EApp (EApp (EVar "foldExtras") (EVar "rest")) (EBinOp "::" (EVar "e") (EVar "revEntries"))) (EBinOp "::" (EVar "name") (EVar "seen")))))
(DTypeSig false "letgroupOf" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LetBind"))))))
(DFunDef false "letgroupOf" ((PCon "DLetGroup" (PVar "isPub") (PVar "bindings"))) (EApp (EVar "Some") (ETuple (EVar "isPub") (EVar "bindings"))))
(DFunDef false "letgroupOf" (PWild) (EVar "None"))
(DTypeSig false "memberStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "memberStr" (PWild (PList)) (EVar "False"))
(DFunDef false "memberStr" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "memberStr") (EVar "x")) (EVar "ys")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "zipDoc" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b"))))))
(DFunDef false "zipDoc" ((PList) PWild) (EListLit))
(DFunDef false "zipDoc" (PWild (PList)) (EListLit))
(DFunDef false "zipDoc" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "::" (ETuple (EVar "x") (EVar "y")) (EApp (EApp (EVar "zipDoc") (EVar "xs")) (EVar "ys"))))
(DTypeSig false "renderMarkdown" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DocEntry")) (TyCon "String"))))
(DFunDef false "renderMarkdown" ((PVar "moduleName") (PVar "entries")) (EApp (EVar "stringConcat") (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "# ")) (EVar "moduleName")) (ELit (LString "\n\n"))) (EApp (EApp (EMethodRef "map") (EVar "renderEntry")) (EVar "entries")))))
(DTypeSig false "renderEntry" (TyFun (TyCon "DocEntry") (TyCon "String")))
(DFunDef false "renderEntry" ((PCon "DocEntry" (PVar "name") (PVar "sig") (PVar "doc"))) (EBlock (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (ELit (LString "## `")) (EVar "name")) (ELit (LString "`\n\n")))) (DoLet false false (PVar "sigBlock") (EBinOp "++" (EBinOp "++" (ELit (LString "```\n")) (EVar "sig")) (ELit (LString "\n```\n")))) (DoLet false false (PVar "docBlock") (EIf (EBinOp "==" (EVar "doc") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EVar "doc")) (ELit (LString "\n"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "header"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "sigBlock"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "docBlock"))) (ELit (LString "\n"))))))
(DTypeSig true "runDoc" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "runDoc" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "src") (PVar "filename")) (EBlock (DoLet false false (PVar "parsed") (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PVar "rawDecls") (EApp (EVar "fst") (EVar "parsed"))) (DoLet false false (PVar "positions") (EApp (EVar "positionsDecls") (EApp (EVar "snd") (EVar "parsed")))) (DoLet false false (PVar "comments") (EApp (EVar "collectComments") (EVar "src"))) (DoLet false false (PVar "schemes") (EApp (EApp (EApp (EVar "docSchemesFor") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "rawDecls"))) (DoLet false false (PVar "moduleName") (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "filename")))) (DoLet false false (PVar "entries") (EApp (EApp (EApp (EApp (EVar "extractEntries") (EVar "rawDecls")) (EVar "positions")) (EVar "schemes")) (EVar "comments"))) (DoExpr (EApp (EApp (EVar "renderMarkdown") (EVar "moduleName")) (EVar "entries")))))
(DTypeSig false "docSchemesFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "docSchemesFor" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "rawUser")) (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugar") (EApp (EVar "fst") (EApp (EVar "parseWithPositions") (EVar "runtimeSrc"))))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugar") (EApp (EVar "fst") (EApp (EVar "parseWithPositions") (EVar "coreSrc"))))) (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EVar "rawUser"))) (DoExpr (EApp (EApp (EApp (EVar "checkProgramSchemesWithRuntime") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "userDecls")))))
