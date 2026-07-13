# META
source_lines=1810
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted pretty printer for Medaka — a port of lib/printer.ml, producing
-- parseable source from the self-host AST (compiler/ast.mdk).  Mirrors the
-- OCaml printer node-for-node: same precedence/parenthesization, operator and
-- keyword spelling, and the Wadler/Leijen document layout engine, so its output
-- is byte-identical to `Printer.program_to_string` on the same AST.
--
-- This is the Stage-4 foundation under the formatter, REPL echo, `medaka new`
-- scaffolding, and LSP hover.  The comment-interleaving `format_program` path
-- (lib/printer.ml's tail half) is NOT ported here — it depends on the lexer
-- comment side-channel and parser_state variant lines, which the self-host
-- parser does not yet surface.  This module covers the AST→source core
-- (`programToString` / `exprToString`).
--
-- Selfhost-AST notes vs lib/ast.ml:
--   * No ELoc wrapper — the self-host parser builds no location nodes, so
--     `stripLoc` is the identity and is elided.
--   * EMethodRef/EDictApp carry only a name (OCaml carries a key too); both
--     print transparently as that name.
--   * EVarAt/EMethodAt/EDictAt/EAnnot-internal nodes are typed-pipeline only and
--     never reach the printer from the parser; transparent fallbacks keep the
--     match total.

import frontend.ast.{
  Lit(..),
  Ty(..),
  Constraint(..),
  Pat(..),
  RecPatField(..),
  Guard(..),
  Arm(..),
  DoStmt(..),
  InterpPart(..),
  GuardArm(..),
  FieldAssign(..),
  Section(..),
  FunClause(..),
  LetBind(..),
  Expr(..),
  UseMember(..),
  UsePath(..),
  PropParam(..),
  MethodDefault(..),
  IfaceMethod(..),
  Super(..),
  Require(..),
  ImplMethod(..),
  DataVis(..),
  Field(..),
  ConPayload(..),
  Variant(..),
  Decl(..),
  Attr(..),
}
import support.util.{joinWith, listLen, allList, reverseL, isEmptyL}

-- ── Document algebra ──────────────────────────────
-- Mirror of lib/printer.ml's `doc` type and combinators.

public export data Doc =
  | Nil
  | Text String
  | Cat Doc Doc
  | Line
  -- flat: " "   broken: newline + indent
  | Softline
  -- flat: ""    broken: newline + indent
  | Hardline
  -- always newline + indent
  | Nest Int Doc
  | Group Doc
  | FlatGroup Doc
  -- FlatAlt a b: render `a` when the enclosing group is BROKEN, `b` when FLAT.
  -- A break-only trailing comma is `FlatAlt (text ",") Nil`.
  | FlatAlt Doc Doc
  -- LineComment text: a trailing `--` line comment anchored to the operand/
  -- statement it documents.  Renders inline as `"  " ++ text`; it ENDS the
  -- current output line (a `--` runs to EOL), so `fits` stops at it (returning
  -- True) and a preceding group is measured only up to the comment.  This is the
  -- Doc-IR node that lets comment placement survive width-driven reflow: it is
  -- anchored to its operand's Doc, so wherever the engine lays that operand the
  -- comment travels with it.  Commented chains/blocks put an unconditional
  -- `Hardline` after each unit, so nothing is ever packed after the comment.
  | LineComment String

text : String -> Doc
text s = Text s

group : Doc -> Doc
group d = Group d

flatGroup : Doc -> Doc
flatGroup d = FlatGroup d

-- a break-only doc: `a` when the enclosing group breaks, `b` when it stays flat.
flatAlt : Doc -> Doc -> Doc
flatAlt a b = FlatAlt a b

-- the break-only trailing comma for a delimited list: `,` when broken, nothing
-- when flat — but ONLY for ≥2 elements.  A single-element list never gets one:
-- it has no diff-churn benefit, and (load-bearing) it keeps a broken single
-- element as `[\n  x\n]`, the form the cold-bootstrap seed parser accepts, so a
-- formatter change need not be paired with a seed re-mint.
trailingCommaFor : List a -> Doc
trailingCommaFor [] = Nil
trailingCommaFor [_] = Nil
trailingCommaFor _ = flatAlt (text ",") Nil

-- one 2-space indent step
nest : Doc -> Doc
nest d = Nest 2 d

sepBy : Doc -> List Doc -> Doc
sepBy _ [] = Nil
sepBy _ [x] = x
sepBy sep (x::xs) = Cat x (Cat sep (sepBy sep xs))

concatD : List Doc -> Doc
concatD [] = Nil
concatD (d::ds) = Cat d (concatD ds)

-- A forced newline then the content indented one step (match/do/where/record/
-- interface/impl bodies).
indentBlock : Doc -> Doc
indentBlock d = Nest 2 (Cat Hardline d)

-- comma-separated sequence inside open/close delimiters, no inner padding.
delimited : String -> String -> List Doc -> Doc
delimited open_ close_ [] = Cat (text open_) (text close_)
delimited open_ close_ items =
  flatGroup (Cat
    (text open_)
    (Cat
      (nest (Cat
        Softline
        (Cat (sepBy (Cat (text ",") Line) items) (trailingCommaFor items))))
      (Cat Softline (text close_))))

-- like `delimited`, but width-triggered off the CURRENT column (`Group`, not
-- `FlatGroup`), so a wide group wraps even when its body alone would fit from
-- the indent.  Used for import member lists, which must break when the whole
-- `import mod.{…}` line overflows.
delimitedG : String -> String -> List Doc -> Doc
delimitedG open_ close_ [] = Cat (text open_) (text close_)
delimitedG open_ close_ items =
  group (Cat
    (text open_)
    (Cat
      (nest (Cat
        Softline
        (Cat (sepBy (Cat (text ",") Line) items) (trailingCommaFor items))))
      (Cat Softline (text close_))))

-- brace-delimited sequence with inner padding (record literals).
braced : List Doc -> Doc
braced [] = text "{}"
braced items =
  group (Cat
    (text "{")
    (Cat
      (nest (Cat
        Line
        (Cat (sepBy (Cat (text ",") Line) items) (trailingCommaFor items))))
      (Cat Line (text "}"))))

-- ── Layout engine ─────────────────────────────────
-- mode = Flat | Break ; a render item = (indent, mode, doc).

public export data Mode = Flat | Break

public export data Item = Item Int Mode Doc

defaultWidth : Int
defaultWidth = 80

-- Does the flat layout of `items` fit in `w` columns before a newline?
fits : Int -> List Item -> Bool
fits w _
  | w < 0 = False
fits _ [] = True
fits w ((Item _ _ Nil)::z) = fits w z
fits w ((Item i m (Cat a b))::z) = fits w (Item i m a :: Item i m b :: z)
fits w ((Item i m (Nest j d))::z) = fits w (Item (i + j) m d :: z)
fits w ((Item _ _ (Text s))::z) = fits (w - stringLength s) z
fits w ((Item _ Flat Line)::z) = fits (w - 1) z
fits w ((Item _ Flat Softline)::z) = fits w z
fits _ ((Item _ Break Line)::_) = True
fits _ ((Item _ Break Softline)::_) = True
fits _ ((Item _ Break Hardline)::_) = True
fits _ ((Item _ Flat Hardline)::_) = False
fits w ((Item i _ (Group d))::z) = fits w (Item i Flat d :: z)
fits w ((Item i _ (FlatGroup d))::z) = fits w (Item i Flat d :: z)
-- fits always measures a FLAT layout → take the flat alternative.
fits w ((Item i m (FlatAlt _ b))::z) = fits w (Item i m b :: z)
-- A line comment ENDS the current line (a `--` runs to EOL): everything up to
-- it fit, and nothing after it is on this line, so `fits` stops here with True.
-- (Commented chains/blocks are structured with unconditional `Hardline` breaks,
-- so a comment never needs to force an enclosing group broken via `fits`; this
-- arm just keeps a trailing comment from polluting a preceding group's measure.)
fits _ ((Item _ _ (LineComment _))::_) = True

-- `n` spaces.
spaces : Int -> String
-- Intentional cross-file duplicate of the same helper in diagnostics.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
spaces n
  | n <= 0 = ""
  | otherwise = " " ++ spaces (n - 1)

newlineStr : Int -> String
newlineStr i = "\n" ++ spaces i

-- The render loop: returns the accumulated output.  Pieces are collected into a
-- list and stringConcat'd once at the end (O(total), like util.joinWith).
go : Int -> List Item -> List String
go _ [] = []
go col ((Item _ _ Nil)::z) = go col z
go col ((Item i m (Cat a b))::z) = go col (Item i m a :: Item i m b :: z)
go col ((Item i m (Nest j d))::z) = go col (Item (i + j) m d :: z)
go col ((Item _ _ (Text s))::z) = s :: go (col + stringLength s) z
go col ((Item _ Flat Line)::z) = " " :: go (col + 1) z
go col ((Item _ Flat Softline)::z) = go col z
go _ ((Item i Break Line)::z) = newlineStr i :: go i z
go _ ((Item i Break Softline)::z) = newlineStr i :: go i z
go _ ((Item i _ Hardline)::z) = newlineStr i :: go i z
go col ((Item i _ (Group d))::z) =
  let flat = Item i Flat d :: z
  if col >= defaultWidth || fits (defaultWidth - col) flat then
    go col flat
  else
    go col (Item i Break d :: z)
go col ((Item i _ (FlatGroup d))::z) =
  let flat = Item i Flat d :: z
  if col >= defaultWidth || fits (defaultWidth - col) flat || fits (defaultWidth - i) [Item i Flat d] then
    go col flat
  else
    go col (Item i Break d :: z)
-- FlatAlt: in Flat mode render the flat alternative `b`; in Break mode render `a`.
go col ((Item i Flat (FlatAlt _ b))::z) = go col (Item i Flat b :: z)
go col ((Item i Break (FlatAlt a _))::z) = go col (Item i Break a :: z)
-- A line comment renders inline (two-space gap + text); it forced the group
-- broken via `fits`, so the following `Line`/`Hardline` will start the next
-- output line.  Mode-independent.
go col ((Item _ _ (LineComment s))::z) =
  "  " ++ s :: go (col + 2 + stringLength s) z

export render : Doc -> String
render doc = stringConcat (go 0 [Item 0 Break doc])

-- ── Literals ──────────────────────────────────────

escapeCharLit : String -> String
escapeCharLit c
  | c == "'" = "\\'"
  | c == "\\" = "\\\\"
  | c == "\n" = "\\n"
  | c == "\t" = "\\t"
  | c == "\r" = "\\r"
  | c == " " = "\\0"
  | otherwise = c

-- OCaml `%S`-style string-literal escaping: quote, backslash, \n \t \r, and a
-- leading/trailing double quote.  (Control/non-printable chars beyond these —
-- which OCaml renders as \b or \ddd — do not occur in the fixtures; see the
-- residual-gaps note in the header.)
escStringLit : String -> String
escStringLit s = "\"" ++ stringConcat (escSChars (stringToChars s) 0) ++ "\""

escSChars : Array Char -> Int -> List String
escSChars cs i
  | i >= arrayLength cs = []
  | otherwise = escSOne (arrayGetUnsafe i cs) :: escSChars cs (i + 1)

escSOne : Char -> String
-- Intentional cross-file duplicate of the same helper in util.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
escSOne c
  | c == '\\' = "\\\\"
  | c == '"' = "\\\""
  | c == '\n' = "\\n"
  | c == '\t' = "\\t"
  | c == '\r' = "\\r"
  | otherwise = charToStr c

printLit : Lit -> Doc
printLit (LInt n) = text (intToString n)
printLit (LFloat f) =
  let s = floatToString f
  let n = stringLength s
  text (if n > 0 && stringSlice (n - 1) n s == "." then s ++ "0" else s)
-- `floatToString` appends `.0` when the rendering has no `.`/`e`, BUT renders a
-- whole-valued float as `N.` (trailing dot, no fractional digit) — which is NOT a
-- parseable float literal (`1.`/`0.` fail to lex).  Append `0` in that case so fmt
-- round-trips (`1.0`/`0.0` print back as `1.0`/`0.0`).

printLit (LString s) = text (escStringLit s)
printLit (LChar c) = text ("'" ++ escapeCharLit c ++ "'")
printLit (LBool b) = text (if b then "True" else "False")
printLit LUnit = text "()"

-- A negative numeric literal renders starting with `-`.  In argument position
-- (after an app head) such an arg must be parenthesized: when fmt wraps a wide
-- application across lines, a bare `-1` at the start of a continuation line is
-- re-lexed as the infix `-` operator (subtraction), corrupting the parse.  Used
-- by exprPrec to give negative literals unary precedence so the printExpr
-- precedence guard parenthesizes them in postfix/app position.
isNegLit : Lit -> Bool
isNegLit (LInt n) = n < 0
isNegLit (LFloat f) =
  let s = floatToString f
  stringLength s > 0 && stringSlice 0 1 s == "-"
isNegLit _ = False

-- ── Types ─────────────────────────────────────────

-- The bare tuple type constructors round-trip as `(,)`/`(,,)`/… — the parser
-- lowers those to `TyCon "__tupleN__"`, so the printer must render that internal
-- name back to the surface spelling (else `medaka fmt` would emit the raw
-- `__tupleN__`, which re-parses as a type VARIABLE and corrupts the impl head).
tyConSurface : String -> String
tyConSurface "__tuple2__" = "(,)"
tyConSurface "__tuple3__" = "(,,)"
tyConSurface "__tuple4__" = "(,,,)"
tyConSurface "__tuple5__" = "(,,,,)"
tyConSurface n = n

printType : Ty -> Doc
printType (TyCon n _) = text (tyConSurface n)
printType (TyVar n) = text n
printType (TyApp a b) =
  Cat (printTypeAppLhs a) (Cat (text " ") (printTypeAtom b))
printType (TyFun a b) =
  Cat (printTypeFunLhs a) (Cat (text " -> ") (printType b))
printType (TyTuple ts) =
  Cat (text "(") (Cat (sepBy (text ", ") (map printType ts)) (text ")"))
printType (TyEffect es tail t) =
  let inside = effectInside es tail
  Cat (text "<") (Cat inside (Cat (text "> ") (printTypeAppLhs t)))
printType (TyConstrained cs t) =
  let csDoc = match cs
    [c] => printConstraint c
    _ => Cat (text "(") (Cat (sepBy (text ", ") (map printConstraint cs)) (text ")"))
  Cat csDoc (Cat (text " => ") (printType t))

effectInside : List (String, Option String) -> Option String -> Doc
effectInside es None = sepBy (text ", ") (map effAtomDoc es)
effectInside [] (Some v) = text v
effectInside es (Some v) =
  Cat (sepBy (text ", ") (map effAtomDoc es)) (Cat (text " | ") (text v))

-- one row atom as a Doc: the label, or label + space + quoted param.
effAtomDoc : (String, Option String) -> Doc
effAtomDoc (l, None) = text l
effAtomDoc (l, Some s) = text "\{l} \{escStringLit s}"

printConstraint : Constraint -> Doc
printConstraint (Constraint iface args) =
  Cat (text iface) (concatD (map (a => Cat (text " ") (printTypeAtom a)) args))

printTypeAtom : Ty -> Doc
printTypeAtom (TyCon n _) = text (tyConSurface n)
printTypeAtom (TyVar n) = text n
printTypeAtom (TyTuple ts) = printType (TyTuple ts)
printTypeAtom t = Cat (text "(") (Cat (printType t) (text ")"))

printTypeFunLhs : Ty -> Doc
printTypeFunLhs (TyFun a b) =
  Cat (text "(") (Cat (printType (TyFun a b)) (text ")"))
printTypeFunLhs t = printType t

-- Left operand of a TyApp: a nested TyApp prints bare; anything else as an atom.
printTypeAppLhs : Ty -> Doc
printTypeAppLhs (TyApp a b) = printType (TyApp a b)
printTypeAppLhs t = printTypeAtom t

-- ── Patterns ──────────────────────────────────────

printPat : Pat -> Doc
printPat (PVar x) = text x
printPat PWild = text "_"
printPat (PLit l) = printLit l
printPat (PCon c []) = text c
printPat (PCon c pats) = Cat
  (text "(")
  (Cat
    (text c)
    (Cat
      (concatD (map (p => Cat (text " ") (printPatAtom p)) pats))
      (text ")")))
printPat (PCons a b) = Cat (printPatAtom a) (Cat (text "::") (printPat b))
printPat (PTuple ps) =
  Cat (text "(") (Cat (sepBy (text ", ") (map printPatArm ps)) (text ")"))
printPat (PList ps) =
  Cat (text "[") (Cat (sepBy (text ", ") (map printPatArm ps)) (text "]"))
printPat (PAs x inner) = Cat (text x) (Cat (text "@") (printPatAtom inner))
printPat (PRec name fields rest) =
  let fieldDocs = map recPatFieldDoc fields
  let all = if rest then fieldDocs ++ [text "..."] else fieldDocs
  Cat (text name) (Cat (text " { ") (Cat (sepBy (text ", ") all) (text " }")))
printPat (PRng lo hi incl) =
  Cat (printLit lo) (Cat (text (if incl then "..=" else "..")) (printLit hi))

recPatFieldDoc : RecPatField -> Doc
recPatFieldDoc (RecPatField k None) = text k
recPatFieldDoc (RecPatField k (Some q)) =
  Cat (text k) (Cat (text " = ") (printPat q))

-- PCon with args already self-parenthesizes in printPat, so it is atom-safe.
-- A PRec with fields is NOT self-delimiting (`Con { .. }` binds as application),
-- so in atom position (e.g. a function-clause arg) it must be parenthesized.
printPatAtom : Pat -> Doc
printPatAtom (PVar x) = printPat (PVar x)
printPatAtom PWild = printPat PWild
printPatAtom (PLit l) = printPat (PLit l)
printPatAtom (PCon c ps) = printPat (PCon c ps)
printPatAtom (PTuple ps) = printPat (PTuple ps)
printPatAtom (PList ps) = printPat (PList ps)
printPatAtom (PRec n fs r) =
  Cat (text "(") (Cat (printPat (PRec n fs r)) (text ")"))
printPatAtom (PRng lo hi incl) = printPat (PRng lo hi incl)
printPatAtom p = Cat (text "(") (Cat (printPat p) (text ")"))

-- Top-of-a-match-arm pattern: an outer constructor application stands alone, so
-- `Some i =>` needs no parens; nested args still route through printPatAtom.
printPatArm : Pat -> Doc
printPatArm (PCon c (p::ps)) =
  Cat (text c) (concatD (map (q => Cat (text " ") (printPatAtom q)) (p::ps)))
printPatArm p = printPat p

-- ── Expression precedence ─────────────────────────

precTop : Int
precTop = 0
precAssign : Int
precAssign = 1
precPipe : Int
precPipe = 2
precCompose : Int
precCompose = 3
precOr : Int
precOr = 4
precAnd : Int
precAnd = 5
precCmp : Int
precCmp = 6
precCons : Int
precCons = 7
precAppend : Int
precAppend = 8
precAdd : Int
precAdd = 9
precMul : Int
precMul = 10
precInfix : Int
precInfix = 11
precApp : Int
precApp = 12
precUnary : Int
precUnary = 13
precPostfix : Int
precPostfix = 14
precAtom : Int
precAtom = 15

binopPrec : String -> Int
binopPrec op
  | op == ":=" = precAssign
  | op == "|>" = precPipe
  | op == ">>" = precCompose
  | op == "<<" = precCompose
  | op == "||" = precOr
  | op == "&&" = precAnd
  | op == "==" = precCmp
  | op == "!=" = precCmp
  | op == "<" = precCmp
  | op == ">" = precCmp
  | op == "<=" = precCmp
  | op == ">=" = precCmp
  | op == "::" = precCons
  | op == "++" = precAppend
  | op == "+" = precAdd
  | op == "-" = precAdd
  | op == "*" = precMul
  | op == "/" = precMul
  | otherwise = precInfix

isRightAssoc : String -> Bool
isRightAssoc "::" = True
isRightAssoc ":=" = True
isRightAssoc _ = False

isContinuationOp : String -> Bool
-- Intentional cross-file duplicate of the same helper in parser.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
isContinuationOp op = op == "|>"
  || op == ">>"
  || op == "<<"
  || op == "&&"
  || op == "||"
  || op == "++"

-- `::` is a constructor/structural operator; it binds tight (no surrounding
-- spaces) in both expression and pattern position.  All other binary operators
-- are spaced.
isConstructorOp : String -> Bool
isConstructorOp op = op == "::"

-- An "atom" operand for the `::` spacing heuristic: a variable, literal, index
-- access (`a.[i]`), field access (`r.x`), or a parenthesized/delimited atom
-- (tuple, list/array/map/set literal, record, range, section).  Applications and
-- binops are NOT atoms.  exprPrec already gives precAtom to the delimited atoms
-- and precPostfix to index/field access, so test by precedence.
isConsAtomOperand : Expr -> Bool
isConsAtomOperand e =
  let p = exprPrec e
  p == precAtom || p == precPostfix

-- `::` is tight (no surrounding spaces) ONLY when both operands are atoms;
-- spaced when either operand is an application or a binop, so the visual
-- grouping matches the parse (`bitAnd b 255 :: r.value`, not the misleading
-- `bitAnd b 255::r.value`).  All other operators are always spaced.
consTight : String -> Expr -> Expr -> Bool
consTight op l r = isConstructorOp op
  && isConsAtomOperand l
  && isConsAtomOperand r

-- Context-aware operator spacing: tight only for an all-atom `::`, else a space.
binopSpace : String -> Expr -> Expr -> Doc
binopSpace op l r = if consTight op l r then Nil else text " "

exprPrec : Expr -> Int
exprPrec (ELit l) = if isNegLit l then precUnary else precAtom
exprPrec (ENumLit n _ _) = if n < 0 then precUnary else precAtom
exprPrec (EVar _) = precAtom
exprPrec (EMethodRef _) = precAtom
exprPrec (EDictApp _) = precAtom
exprPrec (ETuple _) = precAtom
exprPrec (EArrayLit _) = precAtom
exprPrec (EListLit _) = precAtom
exprPrec (EMapLit _ _) = precAtom
exprPrec (ESetLit _ _) = precAtom
exprPrec (EStringInterp _) = precAtom
exprPrec (ERecordCreate _ _) = precAtom
exprPrec (ERecordUpdate _ _) = precAtom
exprPrec (EVariantUpdate _ _ _) = precAtom
exprPrec (ERangeList _ _ _) = precAtom
exprPrec (ERangeArray _ _ _) = precAtom
exprPrec (ESlice _ _ _ _ _) = precAtom
exprPrec (EFieldAccess _ _ _) = precPostfix
exprPrec (EIndex _ _ _) = precPostfix
exprPrec (EUnOp _ _ _) = precUnary
exprPrec (EApp _ _) = precApp
exprPrec (EInfix _ _ _) = precInfix
exprPrec (EBinOp op _ _ _) = binopPrec op
exprPrec (ESection _) = precAtom
exprPrec (EAsPat _ _) = precApp
exprPrec (ELam _ _) = precTop
exprPrec (ELet _ _ _ _ _) = precTop
exprPrec (ELetGroup _ _) = precTop
exprPrec (EIf _ _ _) = precTop
exprPrec (EMatch _ _) = precTop
exprPrec (EBlock _) = precTop
exprPrec (EDo _) = precTop
exprPrec (EAnnot _ _) = precTop
exprPrec (EHeadAnnot _ _) = precTop
exprPrec (EGuards _) = precTop
-- typed-pipeline-only nodes (never from the parser); give them atom precedence.
exprPrec (EVarAt _ _) = precAtom
exprPrec (EMethodAt _ _ _ _) = precAtom
exprPrec (EDictAt _ _) = precAtom
-- ELoc is transparent: the wrapper takes its child's precedence (mirror of
-- lib/printer.ml:323 `ELoc(_,e) -> expr_prec e`).
exprPrec (ELoc _ e) = exprPrec e

-- A body whose printed form spans multiple lines — block vs inline `=` RHS.
isBlockBody : Expr -> Bool
isBlockBody (ELoc _ e) = isBlockBody e
isBlockBody (EMatch _ _) = True
isBlockBody (EBlock _) = True
isBlockBody (EDo _) = True
isBlockBody (EGuards _) = True
isBlockBody (EIf _ t e) = isBlockBody t || isBlockBody e
isBlockBody _ = False

isUnitLit : Expr -> Bool
isUnitLit (ELit LUnit) = True
isUnitLit _ = False

-- A body eligible to break AT its `=`/`=>` separator (drop the whole body one
-- indent-line below when the `sep body` line is over-wide).  Excludes block
-- bodies (do/match/if/function/guards — they own their layout) and
-- continuation-op chains (`&&`/`||`/`|>`/… — they keep their head on the
-- separator line and break at their leading operators instead).
breakAtSepBody : Expr -> Bool
breakAtSepBody (ELoc _ e) = breakAtSepBody e
breakAtSepBody (EBinOp op _ _ _) = not (isContinuationOp op)
breakAtSepBody b = not (isBlockBody b)

-- ── Expressions ───────────────────────────────────

printExpr : Int -> Expr -> Doc
printExpr minPrec e =
  let ep = exprPrec e
  let d = printExprRaw e
  if ep < minPrec then Cat (text "(") (Cat d (text ")")) else d

printExprRaw : Expr -> Doc
printExprRaw (ELit l) = printLit l
-- ENumLit (a `Num a` expression-position integer; desugar lowers it before
-- eval/emit, but the formatter runs pre-desugar so it reaches the printer).
-- Renders as the bare integer, mirroring lib/printer.ml's `ENumLit (n,_,_)`.
printExprRaw (ENumLit n _ _) = text (intToString n)
printExprRaw (EVar n) = text n
printExprRaw (EMethodRef n) = text n
printExprRaw (EDictApp n) = text n
printExprRaw (EApp f x) =
  Cat (printExpr precApp f) (Cat (text " ") (printExpr precPostfix x))
printExprRaw (ELam pats body) =
  Cat
    (sepBy (text " ") (map printPatAtom pats))
    (Cat (text " => ") (printExpr precTop body))
printExprRaw (ELet isMut isf pat rhs e2) = printELet isMut isf pat rhs e2
printExprRaw (ELetGroup bindings body) =
  Cat
    (printExpr precTop body)
    (Nest
      2
      (Cat Hardline (Cat (text "where") (Nest 2 (letGroupClauses bindings)))))
printExprRaw (EIf c t e) = printEIf c t e
printExprRaw (EBinOp op l r _) =
  let prec = binopPrec op
  let ra = isRightAssoc op
  let sp = binopSpace op l r
  Cat
    (printExpr (if ra then prec + 1 else prec) l)
    (Cat
      sp
      (Cat (text op) (Cat sp (printExpr (if ra then prec else prec + 1) r))))
printExprRaw (EUnOp op e _) = Cat (text op) (printExpr precUnary e)
printExprRaw (EFieldAccess e f _) =
  Cat (printExpr precPostfix e) (Cat (text ".") (text f))
printExprRaw (ERecordCreate n fs) =
  Cat (text n) (Cat (text " ") (braced (map fieldAssignDoc fs)))
printExprRaw (ERecordUpdate e fs) =
  Cat
    (text "{ ")
    (Cat
      (printExpr precTop e)
      (Cat
        (text " | ")
        (Cat (sepBy (text ", ") (map fieldAssignDoc fs)) (text " }"))))
printExprRaw (EVariantUpdate c e fs) =
  Cat
    (text c)
    (Cat
      (text " { ")
      (Cat
        (printExpr precTop e)
        (Cat
          (text " | ")
          (Cat (sepBy (text ", ") (map fieldAssignDoc fs)) (text " }")))))
printExprRaw (EArrayLit es) = delimited "[|" "|]" (map (printExpr precTop) es)
printExprRaw (EListLit es) = delimited "[" "]" (map (printExpr precTop) es)
printExprRaw (EMapLit n kvs) =
  Cat
    (text n)
    (Cat (text " { ") (Cat (sepBy (text ", ") (map mapKvDoc kvs)) (text " }")))
printExprRaw (ESetLit n es) =
  Cat
    (text n)
    (Cat
      (text " { ")
      (Cat (sepBy (text ", ") (map (printExpr precTop) es)) (text " }")))
printExprRaw (ETuple es) = delimited "(" ")" (map (printExpr precTop) es)
printExprRaw (EIndex e i _) =
  Cat
    (printExpr precPostfix e)
    (Cat (text "[") (Cat (printExpr precTop i) (text "]")))
printExprRaw (EMatch sc arms) =
  Cat (text "match ") (Cat (printExpr precTop sc) (printMatchArms arms))
printExprRaw (EGuards arms) = printGuardArms arms
printExprRaw (ESection (SecBare op)) = Cat (text "(") (Cat (text op) (text ")"))
printExprRaw (ESection (SecRight op e)) =
  Cat
    (text "(")
    (Cat (text op) (Cat (text " ") (Cat (printExpr precTop e) (text ")"))))
printExprRaw (ESection (SecLeft e op)) =
  Cat
    (text "(")
    (Cat (printExpr precTop e) (Cat (text " ") (Cat (text op) (text " _)"))))
printExprRaw (EAsPat x e) = Cat (text x) (Cat (text "@") (printExpr precAtom e))
printExprRaw (EBlock stmts) =
  indentBlock (sepBy Hardline (map printDoStmt stmts))
printExprRaw (EDo stmts) =
  Cat (text "do") (indentBlock (sepBy Hardline (map printDoStmt stmts)))
printExprRaw (EAnnot e t) =
  Cat (printExpr precTop e) (Cat (text " : ") (printType t))
printExprRaw (EHeadAnnot e _) = printExpr precTop e
printExprRaw (EInfix op l r) =
  Cat
    (printExpr (precInfix + 1) l)
    (Cat
      (text " `")
      (Cat (text op) (Cat (text "` ") (printExpr (precInfix + 1) r))))
printExprRaw (EStringInterp parts) =
  Cat (text "\"") (Cat (concatD (map interpPartDoc parts)) (text "\""))
printExprRaw (ERangeList lo hi incl) = Cat
  (text "[")
  (Cat
    (printExpr precTop lo)
    (Cat
      (text (if incl then "..=" else ".."))
      (Cat (printExpr precTop hi) (text "]"))))
printExprRaw (ERangeArray lo hi incl) = Cat
  (text "[|")
  (Cat
    (printExpr precTop lo)
    (Cat
      (text (if incl then "..=" else ".."))
      (Cat (printExpr precTop hi) (text "|]"))))
printExprRaw (ESlice e lo hi incl _) = Cat
  (printExpr precPostfix e)
  (Cat
    (text ".[")
    (Cat
      (printExpr precTop lo)
      (Cat
        (text (if incl then "..=" else ".."))
        (Cat (printExpr precTop hi) (text "]")))))
-- typed-pipeline-only nodes: print the name / inner transparently (parser never
-- produces them, but keep the match total).
printExprRaw (EVarAt n _) = text n
printExprRaw (EMethodAt n _ _ _) = text n
printExprRaw (EDictAt n _) = text n
-- ELoc is transparent: print the wrapped expr (mirror of lib/printer.ml:502
-- `ELoc(_,e) -> print_expr_raw e`).
printExprRaw (ELoc _ e) = printExprRaw e

-- `let [isMut] f args = body in e2` — coalesce the lambda spine for `let f = …`.
printELet : Bool -> Bool -> Pat -> Expr -> Expr -> Doc
printELet isMut True (PVar f) rhs e2 =
  let argsBody = unwrapLams [] rhs
  match argsBody
    (args, body) => Cat (text (if isMut then "let mut " else "let ")) (Cat (text f) (Cat (concatD (map (p => Cat (text " ") (printPatAtom p)) args)) (Cat (text " = ") (Cat (printExpr precTop body) (Cat (text " in ") (printExpr precTop e2))))))
printELet isMut _ pat e1 e2 = Cat
  (text "let ")
  (Cat
    (if isMut then text "mut " else Nil)
    (Cat
      (printPat pat)
      (Cat
        (text " = ")
        (Cat
          (printExpr precTop e1)
          (Cat (text " in ") (printExpr precTop e2))))))

unwrapLams : List Pat -> Expr -> (List Pat, Expr)
unwrapLams acc (ELoc _ e) = unwrapLams acc e
unwrapLams acc (ELam pats body) = unwrapLams (acc ++ pats) body
unwrapLams acc body = (acc, body)

letGroupClauses : List LetBind -> Doc
letGroupClauses bindings = concatD (map letBindClauses bindings)

letBindClauses : LetBind -> Doc
letBindClauses (LetBind name clauses) =
  concatD (map (letGroupClause name) clauses)

letGroupClause : String -> FunClause -> Doc
letGroupClause name (FunClause pats rhs) = Cat
  Hardline
  (Cat
    (text name)
    (Cat
      (concatD (map (p => Cat (text " ") (printPatAtom p)) pats))
      (letGroupClauseRhs rhs)))

letGroupClauseRhs : Expr -> Doc
letGroupClauseRhs (EGuards arms) = printGuardArms arms
letGroupClauseRhs rhs = Cat (text " = ") (printExpr precTop rhs)

printEIf : Expr -> Expr -> Expr -> Doc
printEIf c t e
  | isBlockBody t || isBlockBody e = Cat (text "if ") (Cat (printExpr precTop c) (Cat (text " ") (Cat (ifBranch "then" t) (Cat Hardline (ifBranch "else" e)))))
  -- EXPRESSION position (nested arg, let..in rhs, record/tuple element): keep the
  -- if flat on one line.  Breaking here would inject newlines an inline context
  -- (a trailing `in`, a closing `)`) cannot absorb → unparseable output.  Width-
  -- aware breaking happens only in BODY/STATEMENT position via `printIfBody`.
  | otherwise = Cat (text "if ") (Cat (printExpr precTop c) (Cat (text " then ") (Cat (printExpr precTop t) (Cat (text " else ") (printExpr precTop e)))))

-- BODY/STATEMENT position `if c then t else e` (a function/lambda body, a do/
-- block statement, a `let x = if …` binding RHS): rendered in a group so the
-- whole thing collapses onto one line only when it fits the width budget at this
-- indent; otherwise `then`/`else` break onto their own lines.  Safe to break
-- because the if sits on its own line (no trailing inline context to misplace).
printIfBody : Expr -> Expr -> Expr -> Doc
printIfBody c t e
  | isBlockBody t || isBlockBody e = printEIf c t e
  -- Reuse the width-aware RHS laddering (`ifRhsBody`/`ifRhsElsePart`, shared
  -- with `printIfRhs`): a qualifying nested `if` in else position ladders into
  -- `else if …` with `Line`-based break points, so the whole cascade breaks
  -- uniformly under the enclosing `group` when it doesn't fit (rather than
  -- the old `else\n  if …` nesting, or a flat over-wide ladder).
  | otherwise = group (ifRhsBody c t (ifRhsElsePart (isUnitLit e) e))

-- A `do`/`match`/`function` block body keeps its keyword ADJACENT to the branch
-- keyword (`else do`, `else match sc`) with the body indented one step — the same
-- shape a `=`-RHS renders (`f x = do\n  …`), since `printExprBody` on those kinds
-- already emits `do\n  …`/`match sc\n  …`.  (peels ELoc.)
isDoMatchFnBody : Expr -> Bool
isDoMatchFnBody (ELoc _ e) = isDoMatchFnBody e
isDoMatchFnBody (EDo _) = True
isDoMatchFnBody (EMatch _ _) = True
isDoMatchFnBody _ = False

-- EBlock self-indents; a do/match body keeps its keyword adjacent (`else
-- do`); other block bodies indent onto their own line; a simple body inlines.
ifBranch : String -> Expr -> Doc
ifBranch kw (EBlock stmts) = Cat (text kw) (printExprBody (EBlock stmts))
ifBranch kw b
  | isDoMatchFnBody b = Cat (text kw) (Cat (text " ") (printExprBody b))
  | isBlockBody b = Cat (text kw) (indentBlock (printExprBody b))
  | otherwise = Cat (text kw) (Cat (text " ") (printExpr precTop b))

-- Tail position: a continuation-op chain may break; Match/Do uses its layout;
-- a too-wide application breaks its argument spine.  `wrapApp` False suppresses
-- the application-spine break (guard / match-arm bodies — see printMatchArms).
printExprBody : Expr -> Doc
printExprBody e = printExprBodyW True e

printExprBodyW : Bool -> Expr -> Doc
-- ELoc transparent (mirror of lib/printer.ml:516): peel so the body-shape
-- dispatch below sees the raw node kind.
printExprBodyW wrapApp (ELoc _ e) = printExprBodyW wrapApp e
printExprBodyW _ (EMatch sc arms) = printExprRaw (EMatch sc arms)
printExprBodyW _ (EBlock stmts) = printExprRaw (EBlock stmts)
printExprBodyW _ (EDo stmts) = printExprRaw (EDo stmts)
printExprBodyW wrapApp (EBinOp op l r rf)
  | isContinuationOp op = printChain op (EBinOp op l r rf)
  | otherwise = printExpr precTop (EBinOp op l r rf)
printExprBodyW True (EApp f x) = printAppSpine (EApp f x)
printExprBodyW wrapApp (EIf c t els)
  | isUnitLit els =
    let thenPart = elseLessThen t
    Cat (text "if ") (Cat (printExpr precTop c) (Cat (text " then") thenPart))
  | otherwise = printIfBody c t els
printExprBodyW _ e = printExpr precTop e

elseLessThen : Expr -> Doc
elseLessThen (ELoc _ e) = elseLessThen e
elseLessThen (EBlock stmts) = printExprBody (EBlock stmts)
elseLessThen t
  | isBlockBody t = indentBlock (printExprBody t)
  | otherwise = Cat (text " ") (printExpr precTop t)

-- Width-aware `if` RHS: Some doc when the `if` (and its branches) are simple;
-- None for non-`if` or block-branch `if` (handled elsewhere).
printIfRhs : Expr -> Option Doc
printIfRhs (ELoc _ e) = printIfRhs e
printIfRhs (EIf c t els) =
  let isUnit = isUnitLit els
  if not (isBlockBody t) && (isUnit || not (isBlockBody els)) then
    Some (group (nest (Cat Line (ifRhsBody c t (ifRhsElsePart isUnit els)))))
  else
    None
printIfRhs _ = None

ifRhsBody : Expr -> Expr -> Doc -> Doc
ifRhsBody c t elsePart =
  Cat
    (text "if ")
    (Cat
      (printExpr precTop c)
      (Cat
        (text " then")
        (Cat (nest (Cat Line (printExpr precTop t))) elsePart)))

ifRhsElsePart : Bool -> Expr -> Doc
ifRhsElsePart True _ = Nil
ifRhsElsePart False (ELoc _ els) = ifRhsElsePart False els
-- An `if` in else position laddering into an `else if … then …` cascade, kept in
-- the SAME enclosing group as the outer `if` so the width-fit decision (and thus
-- the line-breaking of every `then`/`else` line) is uniform — the cascade never
-- collapses onto one over-wide line.  Only flatten the chain when the nested `if`
-- itself qualifies for the flat ladder (simple, non-block branches); otherwise
-- fall back to a fresh `else` block with the nested `if` rendered on its own.
ifRhsElsePart False (EIf c2 t2 els2)
  | not (isBlockBody t2) && (isUnitLit els2 || not (isBlockBody els2)) = Cat Line (Cat (text "else if ") (Cat (printExpr precTop c2) (Cat (text " then") (Cat (nest (Cat Line (printExpr precTop t2))) (ifRhsElsePart (isUnitLit els2) els2)))))
ifRhsElsePart False els =
  Cat Line (Cat (text "else") (nest (Cat Line (printExpr precTop els))))

-- Flatten the same-operator left-assoc spine into one group; lead each
-- continuation line with the operator.
printChain : String -> Expr -> Doc
printChain op e =
  let prec = binopPrec op
  let headRights = collectChain op [] e
  match headRights
    (head, rights) =>
      let tail = concatD (map (or => chainItem prec or) rights)
      group (Nest 2 (Cat (printExpr prec head) tail))

chainItem : Int -> (String, Expr) -> Doc
chainItem prec (o, r) =
  Cat Line (Cat (text o) (Cat (text " ") (printExpr (prec + 1) r)))

collectChain : String -> List (String, Expr) -> Expr -> (Expr, List (String, Expr))
-- ELoc is transparent: peel so a parenthesized left sub-chain (which the parser
-- wraps in an ELoc atom) flattens into the same chain as its paren-free form.
-- Without this, `(a ++ b ++ c) ++ d` collects head = ELoc(a++b++c) and stops,
-- laying out differently from `a ++ b ++ c ++ d`; since fmt drops the redundant
-- parens, the two forms would otherwise never converge (non-idempotent).
collectChain op acc (ELoc _ e) = collectChain op acc e
collectChain op acc (EBinOp op2 l r rf)
  | op2 == op = collectChain op ((op2, r)::acc) l
  | otherwise = (EBinOp op2 l r rf, acc)
collectChain _ acc head = (head, acc)

-- ── Comment-interleaved continuation chains (finding "L") ──────────────────
-- `medaka fmt` routes a continuation-op chain RHS that carries per-operand
-- trailing comments here (via `printDeclChainCommented`).  Each operand's Doc is
-- anchored to its `LineComment`, so the comment rides with the operand across
-- any reflow.  A commented chain ALWAYS breaks (a `--` forces it), one operand
-- per line, with the head on its own indented line below `=`.
--
-- `comments` is one entry per operand in `collectChain` order (head first, then
-- each right in source order); `None` = that operand has no trailing comment.

-- Number of operands in a decl's continuation-chain body (0 if it is not one).
-- `medaka fmt` uses this to verify its per-operand comment list lines up with
-- the AST before taking the commented path.
export declChainLen : Decl -> Int
declChainLen (DAttrib _ inner) = declChainLen inner
declChainLen (DFunDef _ _ _ body) = chainLenBody body
declChainLen _ = 0

chainLenBody : Expr -> Int
chainLenBody (ELoc _ e) = chainLenBody e
chainLenBody (EBinOp op l r rf)
  | isContinuationOp op = match collectChain op [] (EBinOp op l r rf)
    (_, rights) => 1 + listLen rights
chainLenBody _ = 0

-- Render one operand's optional trailing comment as an anchored `LineComment`.
opCommentDoc : Option String -> Doc
opCommentDoc None = Nil
opCommentDoc (Some t) = LineComment t

-- One continuation line of a commented chain: `<Hardline>op <operand>  -- cmt`.
-- A commented chain always breaks (one operand per line), so the separators are
-- unconditional `Hardline`s; each operand's own groups still reflow internally.
chainItemCommented : Int -> (String, Expr) -> Option String -> Doc
chainItemCommented prec (o, r) cmt =
  Cat
    Hardline
    (Cat
      (text o)
      (Cat (text " ") (Cat (printExpr (prec + 1) r) (opCommentDoc cmt))))

-- Zip the chain's `rights` with the tail of the per-operand comment list.
chainTailCommented : Int -> List (String, Expr) -> List (Option String) -> Doc
chainTailCommented _ [] _ = Nil
chainTailCommented prec (r::rs) (c::cs) =
  Cat (chainItemCommented prec r c) (chainTailCommented prec rs cs)
chainTailCommented prec (r::rs) [] =
  Cat (chainItemCommented prec r None) (chainTailCommented prec rs [])

-- The RHS after `=` for a commented chain: break at `=` (head on its own line),
-- then each operand on its own line with its comment — unconditional `Hardline`s
-- (a commented chain always breaks), so operands still reflow internally.
printChainCommentedRhs : String -> Expr -> List (Option String) -> Doc
printChainCommentedRhs op e comments =
  let prec = binopPrec op
  match collectChain op [] e
    (head, rights) =>
      let headCmt = match comments
        h::_ => h
        [] => None
      let restCmts = match comments
        _::t => t
        [] => []
      let body = Cat (printExpr prec head) (Cat (opCommentDoc headCmt) (chainTailCommented prec rights restCmts))
      Cat (text " =") (Nest 2 (Cat Hardline body))

-- Print a whole DFunDef (optionally @attr-wrapped) whose body is a continuation
-- chain, interleaving `comments` (one per operand).  Falls back to the plain
-- `printDecl` for anything else (fmt only calls this for a verified chain decl).
export printDeclChainCommented : Decl -> List (Option String) -> Doc
printDeclChainCommented (DAttrib attrs inner) comments =
  Cat (concatD (map attrDoc attrs)) (printDeclChainCommented inner comments)
printDeclChainCommented (DFunDef pub n pats body) comments =
  let header = Cat (if pub then text "export " else Nil) (Cat (text n) (concatD (map (p => Cat (text " ") (printPatAtom p)) pats)))
  Cat header (printDefChainRhs body comments)
printDeclChainCommented d _ = printDecl d

printDefChainRhs : Expr -> List (Option String) -> Doc
printDefChainRhs (ELoc _ e) comments = printDefChainRhs e comments
printDefChainRhs (EBinOp op l r rf) comments
  | isContinuationOp op = printChainCommentedRhs op (EBinOp op l r rf) comments
printDefChainRhs body _ = printDefRhs body

-- ── Comment-interleaved block/do bodies (finding "L", Stage 5) ──────────────
-- A decl whose body is a top-level bare block (EBlock) or do-block (EDo) with a
-- trailing comment per statement.  Statements are already Hardline-separated
-- (one per line), so each comment is anchored to ITS statement's Doc as a
-- `LineComment` — rendering after the whole statement (even if the statement
-- reflows internally) and before the next Hardline.  `comments` is one entry per
-- statement in source order; `None` = no trailing comment.

-- Statement count of a decl's block/do body (0 if it is not one).
export declBlockLen : Decl -> Int
declBlockLen (DAttrib _ inner) = declBlockLen inner
declBlockLen (DFunDef _ _ _ body) = blockLenBody body
declBlockLen _ = 0

blockLenBody : Expr -> Int
blockLenBody (ELoc _ e) = blockLenBody e
blockLenBody (EBlock stmts) = listLen stmts
blockLenBody (EDo stmts) = listLen stmts
blockLenBody _ = 0

headOpt : List (Option String) -> Option String
headOpt (x::_) = x
headOpt [] = None

tailOpt : List (Option String) -> List (Option String)
tailOpt (_::t) = t
tailOpt [] = []

-- Hardline-separated statements (mirror of `sepBy Hardline (map printDoStmt …)`),
-- each with its trailing comment anchored.
stmtsCommented : List DoStmt -> List (Option String) -> Doc
stmtsCommented [] _ = Nil
stmtsCommented [st] cs = Cat (printDoStmt st) (opCommentDoc (headOpt cs))
stmtsCommented (st::rest) cs =
  Cat
    (Cat (printDoStmt st) (opCommentDoc (headOpt cs)))
    (Cat Hardline (stmtsCommented rest (tailOpt cs)))

-- RHS after `=` for a commented block/do body (mirror of the plain EBlock/EDo
-- render, with per-statement comments).
printBlockCommentedRhs : Expr -> List (Option String) -> Doc
printBlockCommentedRhs (ELoc _ e) comments = printBlockCommentedRhs e comments
printBlockCommentedRhs (EBlock stmts) comments =
  Cat (text " =") (indentBlock (stmtsCommented stmts comments))
printBlockCommentedRhs (EDo stmts) comments =
  Cat
    (text " = ")
    (Cat (text "do") (indentBlock (stmtsCommented stmts comments)))
printBlockCommentedRhs body _ = printDefRhs body

-- Print a whole DFunDef (optionally @attr-wrapped) whose body is a bare/do
-- block, interleaving `comments` (one per statement).  Falls back to `printDecl`
-- for anything else (fmt only calls this for a verified block decl).
export printDeclBlockCommented : Decl -> List (Option String) -> Doc
printDeclBlockCommented (DAttrib attrs inner) comments =
  Cat (concatD (map attrDoc attrs)) (printDeclBlockCommented inner comments)
printDeclBlockCommented (DFunDef pub n pats body) comments =
  let header = Cat (if pub then text "export " else Nil) (Cat (text n) (concatD (map (p => Cat (text " ") (printPatAtom p)) pats)))
  Cat header (printBlockCommentedRhs body comments)
printDeclBlockCommented d _ = printDecl d

-- Flatten the left-assoc application spine into one group; each arg on its own
-- indented line when broken.  Flat rendering matches the inline EApp arm.
printAppSpine : Expr -> Doc
printAppSpine e =
  let headArgs = collectApp [] e
  match headArgs
    (head, []) => printExpr precTop e
    -- A function/constructor head with a SINGLE argument: keep the head inline
    -- with the argument's opening (don't isolate the head on its own line) and
    -- break INSIDE the argument instead.  Only when the lone argument is itself
    -- breakable (a parenthesized lambda whose body can fold) — otherwise fall
    -- back to the generic spine (so a single unbreakable atom still hangs below
    -- the head when too wide).
    (head, [arg]) =>
      if isBreakableArg arg then
        Cat (printExpr precApp head) (Cat (text " ") (breakableArg arg))
      else
        group (Nest 2 (Cat (printExpr precApp head) (Cat Line (printExpr precPostfix arg))))
    (head, args) =>
      let tail = concatD (map (a => Cat Line (spineArg a)) args)
      group (Nest 2 (Cat (printExpr precApp head) tail))

-- A multi-arg-spine argument: a NESTED application is parenthesized and rendered
-- through printAppSpine so its own spine can break when over-width (otherwise a
-- wide nested-call argument would overflow its single line).  Anything else
-- renders flat at postfix precedence, unchanged.
spineArg : Expr -> Doc
spineArg (ELoc _ e) = spineArg e
spineArg (EApp f x) = Cat (text "(") (Cat (printAppSpine (EApp f x)) (text ")"))
spineArg e = printExpr precPostfix e

-- A single application argument worth keeping inline with its head: a lambda
-- (whose body we can fold across lines) or a nested application (its own spine
-- breaks).  ELoc-transparent.
isBreakableArg : Expr -> Bool
isBreakableArg (ELoc _ e) = isBreakableArg e
isBreakableArg (ELam _ _) = True
-- A nested application argument: keep the call head inline and break the
-- nested app's OWN spine (recursively), instead of dropping the head onto its
-- own line where the still-flat argument line keeps overflowing.  Only when the
-- nested app actually has arguments (a bare head has nothing to break).
isBreakableArg (EApp f x) = True
isBreakableArg _ = False

-- Render a single inline argument so its interior can break.  A lambda renders
-- parenthesized with its body folded through the body printer (app spines /
-- continuation chains break); the whole thing is a group so it stays flat until
-- it overflows.
breakableArg : Expr -> Doc
breakableArg (ELoc _ e) = breakableArg e
breakableArg (ELam pats body) =
  group (Cat
    (text "(")
    (Cat
      (sepBy (text " ") (map printPatAtom pats))
      (Cat
        (text " =>")
        (Cat (nest (Cat Line (printExprBody body))) (text ")")))))
-- A nested application: parenthesize and let printAppSpine break its own spine
-- so over-width nested calls wrap rather than overflowing a single arg line.
breakableArg (EApp f x) =
  Cat (text "(") (Cat (printAppSpine (EApp f x)) (text ")"))
breakableArg e = printExpr precPostfix e

collectApp : List Expr -> Expr -> (Expr, List Expr)
collectApp acc (EApp f x) = collectApp (x::acc) f
collectApp acc head = (head, acc)

-- Shared by EMatch and `function`: indented block of `pat [if guards] => body`.
printMatchArms : List Arm -> Doc
printMatchArms arms = indentBlock (sepBy Hardline (map matchArmDoc arms))

matchArmDoc : Arm -> Doc
matchArmDoc (Arm pat guards body) =
  Cat (printPatArm pat) (Cat (matchGuardsDoc guards) (matchBodyDoc body))

matchGuardsDoc : List Guard -> Doc
matchGuardsDoc [] = Nil
matchGuardsDoc guards =
  Cat (text " if ") (sepBy (text ", ") (map guardDoc guards))

matchBodyDoc : Expr -> Doc
matchBodyDoc body = match printIfRhs body
  Some g => Cat (text " =>") g
  None => matchBodyNoIf body

matchBodyNoIf : Expr -> Doc
matchBodyNoIf (ELoc _ e) = matchBodyNoIf e
matchBodyNoIf (EBlock stmts) =
  Cat (text " =>") (printExprBodyW False (EBlock stmts))
matchBodyNoIf body
  -- Offer break-at-`=>` (only when the body can then be one line — hangAtSep):
  -- an over-wide `pat => body` drops the whole body one indent-line below `=>`.
  | breakAtSepBody body = hangAtSep " =>" (printExprBodyW False body)
  | otherwise = Cat (text " => ") (printExprBodyW False body)

guardDoc : Guard -> Doc
guardDoc (GBool g) = printExpr precTop g
guardDoc (GBind gp g) =
  Cat (printPat gp) (Cat (text " <- ") (printExpr precTop g))

-- Function/where guard arms: indented block of `| guards = body`.
printGuardArms : List GuardArm -> Doc
printGuardArms arms = indentBlock (sepBy Hardline (map guardArmDoc arms))

guardArmDoc : GuardArm -> Doc
guardArmDoc (GuardArm guards body) =
  let hd = Cat (text "| ") (sepBy (text ", ") (map guardDoc guards))
  Cat hd (guardArmBodyDoc body)

guardArmBodyDoc : Expr -> Doc
guardArmBodyDoc body = match printIfRhs body
  Some g => Cat (text " =") g
  None => guardArmBodyNoIf body

guardArmBodyNoIf : Expr -> Doc
guardArmBodyNoIf (EBlock stmts) =
  Cat (text " =") (printExprBodyW False (EBlock stmts))
guardArmBodyNoIf body
  -- Offer break-at-`=` (only when the body can then be one line — hangAtSep):
  -- an over-wide `| guards = body` drops the body one indent-line below `=`.
  | breakAtSepBody body = hangAtSep " =" (printExprBodyW False body)
  | otherwise = Cat (text " = ") (printExprBodyW False body)

-- A `let pat = <rhs>` statement RHS (own line in a do/bare block): an `if` is
-- break-capable here (statement position), reusing the body-position renderer so
-- an over-width if breaks `then`/`else` instead of overflowing.  Everything else
-- renders flat at top precedence, unchanged.
doLetRhs : Expr -> Doc
doLetRhs (ELoc _ e) = doLetRhs e
doLetRhs (EIf c t els)
  | not (isUnitLit els) = printIfBody c t els
doLetRhs e = printExpr precTop e

printDoStmt : DoStmt -> Doc
printDoStmt (DoBind pat e) =
  Cat (printPat pat) (Cat (text " <- ") (printExpr precTop e))
printDoStmt (DoExpr e) = match e
  EIf c t els => if isUnitLit els then
    let thenPart = elseLessThen t
    Cat (text "if ") (Cat (printExpr precTop c) (Cat (text " then") thenPart))
  else printExprBody e
  _ => printExprBody e
printDoStmt (DoLet isMut _ pat e) = Cat
  (text "let ")
  (Cat
    (if isMut then text "mut " else Nil)
    (Cat (printPat pat) (Cat (text " = ") (doLetRhs e))))
printDoStmt (DoAssign x e) =
  Cat (text x) (Cat (text " = ") (printExpr precTop e))
printDoStmt (DoFieldAssign x fields e) =
  Cat
    (text x)
    (Cat
      (text ".")
      (Cat
        (text (joinWith "." fields))
        (Cat (text " = ") (printExpr precTop e))))

interpPartDoc : InterpPart -> Doc
interpPartDoc (InterpStr s) = text (stringEscaped s)
interpPartDoc (InterpExpr e) =
  Cat (text "\\{") (Cat (printExpr precTop e) (text "}"))

fieldAssignDoc : FieldAssign -> Doc
fieldAssignDoc (FieldAssign k v) =
  Cat (text k) (Cat (text " = ") (printExpr precTop v))

mapKvDoc : (Expr, Expr) -> Doc
mapKvDoc (k, v) =
  Cat (printExpr precTop k) (Cat (text " => ") (printExpr precTop v))

-- ── Declarations ──────────────────────────────────

-- OCaml `String.escaped`: backslash, quote, \n \t \r (printable passthrough).
-- Used for EStringInterp's InterpStr parts.
stringEscaped : String -> String
stringEscaped s = stringConcat (escEChars (stringToChars s) 0)

escEChars : Array Char -> Int -> List String
escEChars cs i
  | i >= arrayLength cs = []
  | otherwise = escSOne (arrayGetUnsafe i cs) :: escEChars cs (i + 1)

-- The RHS of `<header> = <body>`: `=` spaced for the body shape.
printDefRhs : Expr -> Doc
-- strip ELoc so the body-shape dispatch (EGuards/EBlock/EDo/EMatch/
-- EApp) sees the raw node — else a wrapped `do`/`match` body mis-renders as a
-- block on a fresh indented line instead of the inline `= do`/`= match` form.
printDefRhs (ELoc _ e) = printDefRhs e
printDefRhs (EGuards arms) = printGuardArms arms
printDefRhs (ELetGroup binds inner)
  | isGuardsBody inner = printExprBody (ELetGroup binds inner)
  | otherwise = printDefRhsGeneral (ELetGroup binds inner)
printDefRhs (EBlock stmts) = Cat (text " =") (printExprBody (EBlock stmts))
printDefRhs body = printDefRhsGeneral body

isGuardsBody : Expr -> Bool
isGuardsBody (EGuards _) = True
isGuardsBody _ = False

printDefRhsGeneral : Expr -> Doc
printDefRhsGeneral body = match printIfRhs body
  Some g => Cat (text " =") g
  None => match body
    EMatch sc arms => Cat (text " = ") (printExprBody (EMatch sc arms))
    EDo stmts => Cat (text " = ") (printExprBody (EDo stmts))
    -- Application body: hang one indent-line below `=` (head on its own line),
    -- then let the spine break THERE if it still overflows — instead of keeping
    -- the head on the `=` line with a mangled `head⏎  arg⏎  arg` spine.  EXCEPT a
    -- spine that delegates to a self-indenting argument (lambda/block/do/match/
    -- record/…): hanging that only adds a pointless indent line, so keep the
    -- conditional inline arm (`bodyBreakAtEq`) for it.
    EApp f x =>
      if appHasSelfIndentingArg (EApp f x) then
        bodyBreakAtEq (printAppSpine (EApp f x))
      else
        hangAlwaysAtSep " =" (printAppSpine (EApp f x))
    EBinOp op l r rf =>
      if isContinuationOp op then
        -- Continuation-op chain (`&&`/`||`/`|>`/…): head stays on the `=` line
        -- and the chain breaks at its leading operators (printChain).  Do NOT
        -- route this through break-at-`=`.
        Cat (text " = ") (printExprBody (EBinOp op l r rf))
      else
        Cat (text " =") (group (nest (Cat Line (printBinOpTrailing op l r))))
    _ =>
      if isBlockBody body then
        Cat (text " =") (indentBlock (printExprBody body))
      else
        -- Non-block, non-chain body (record / tuple / list / literal / …):
        -- offer break-at-`=` so an over-wide `= body` line drops the whole body
        -- to the next line (where a record/tuple may fit on one line) before
        -- exploding the body's own interior.
        bodyBreakAtEq (printExprBody body)

bodyBreakAtEq : Doc -> Doc
bodyBreakAtEq bodyDoc = hangAtSep " =" bodyDoc

-- Break AT the `=`/`=>` separator ONLY when the body can then be one line:
--   * `sep body` fits on the current line     → inline (unchanged);
--   * body fits flat on its own line (but the inline `sep body` does not)
--                                             → hang the body one indent-line
--                                               below `sep`;
--   * body cannot be one line at all          → `sep ` + body breaks its own
--     interior (the pre-existing inline form — the body's opener stays on the
--     `sep` line, so an inherently-multi-line list/record/lambda-app does NOT
--     gain a pointless extra hang line + deeper indent).
-- The outer `FlatGroup` flattens (→ the FlatAlt `b`/hang arm) exactly when the
-- body fits on one line at this indent (its cond-c `fits (width - i)` test);
-- otherwise it breaks (→ the FlatAlt `a`/inline-interior-break arm).  Inside the
-- hang arm, the inner `group` then picks inline-vs-hang by whether `sep body`
-- fits from the current column.
hangAtSep : String -> Doc -> Doc
hangAtSep sep bodyDoc =
  FlatGroup (FlatAlt
    (Cat (text sep) (Cat (text " ") bodyDoc))
    (Cat (text sep) (group (nest (Cat Line bodyDoc)))))

-- Like `hangAtSep` but UNCONDITIONALLY hangs the body one indent-line below the
-- separator (the hang arm above, without the outer FlatGroup/FlatAlt inline
-- escape).  The inner `group` still keeps `sep body` inline when it fits from
-- the current column; when it does not, the body drops below `sep` with its head
-- on its own line and its spine breaks THERE.  Used for a bare application-spine
-- body, whose inline interior-break would otherwise leave the head stranded on
-- the `sep` line (`f = g (h⏎  a⏎  b)`).
hangAlwaysAtSep : String -> Doc -> Doc
hangAlwaysAtSep sep bodyDoc = Cat (text sep) (group (nest (Cat Line bodyDoc)))

-- An argument that self-indents its own multi-line body when broken (lambda /
-- point-free / block / do / if / match / record / non-empty collection literal).
-- An application body that contains one (transitively down its spine) must NOT
-- be hung below `=`: hanging only adds a pointless indent line above the arg's
-- own self-indent (`wrapInParser g p = Parser (input pos => …)` stays inline).  A
-- pure atom/app spine (`encode b = stringFromChars (arrayFromList (encodeGo …)))`)
-- has none, so it hangs below `=` and breaks its spine THERE instead of stranding
-- the head on the `=` line.
isSelfIndentingArg : Expr -> Bool
isSelfIndentingArg (ELoc _ e) = isSelfIndentingArg e
isSelfIndentingArg (ELam _ _) = True
isSelfIndentingArg (EBlock _) = True
isSelfIndentingArg (EDo _) = True
isSelfIndentingArg (EMatch _ _) = True
isSelfIndentingArg (EIf _ _ _) = True
isSelfIndentingArg (ERecordCreate _ _) = True
isSelfIndentingArg (ERecordUpdate _ _) = True
isSelfIndentingArg (EVariantUpdate _ _ _) = True
isSelfIndentingArg (EListLit (_::_)) = True
isSelfIndentingArg (EArrayLit (_::_)) = True
isSelfIndentingArg (ETuple (_::_)) = True
isSelfIndentingArg (EMapLit _ (_::_)) = True
isSelfIndentingArg (ESetLit _ (_::_)) = True
isSelfIndentingArg (EApp f x) = appHasSelfIndentingArg (EApp f x)
isSelfIndentingArg _ = False

-- Does the transitive left-spine of this application contain a self-indenting
-- argument?  Walks head-ward through `EApp` nodes, testing each argument.
appHasSelfIndentingArg : Expr -> Bool
appHasSelfIndentingArg (ELoc _ e) = appHasSelfIndentingArg e
appHasSelfIndentingArg (EApp f x) = isSelfIndentingArg x
  || appHasSelfIndentingArg f
appHasSelfIndentingArg _ = False
-- Width cascade for a too-wide `=` binding RHS (Option B):
--   1. hang the RHS one line below `=` (the outer `group`/`Line`);
--   2. if still over width, break the OUTERMOST binop with the operator
--      TRAILING (`a ::` then the indented `b`) — relies on the lexer's
--      trailing-operator line continuation to re-parse.

-- Render `l op r` with the operator TRAILING when it must break: flat `l op r`,
-- broken `l op⏎  r` (the operator stays on the left line, the right operand
-- drops one further indent step).  Own `group` so step 2 fires only when the
-- hung RHS still overflows.  Operands keep their flat precedence-correct render;
-- an application operand may itself break its argument spine.
printBinOpTrailing : String -> Expr -> Expr -> Doc
printBinOpTrailing op l r =
  let prec = binopPrec op
  let ra = isRightAssoc op
  let lp = if ra then prec + 1 else prec
  let rp = if ra then prec else prec + 1
  -- constructor ops (::) are tight ONLY when both operands are atoms.
  let afterOp = if consTight op l r then Softline else Line
  group
    (nest (Cat (printOperand lp l) (Cat (binopSpace op l r) (Cat (text op) (Cat afterOp (printOperand rp r))))))

-- An operand of a trailing-break binop: an application breaks its own spine
-- (cascade step 3) when over-width; anything else renders at the given prec.
printOperand : Int -> Expr -> Doc
printOperand prec (ELoc _ e) = printOperand prec e
printOperand prec (EApp f x) =
  if exprPrec (EApp f x) < prec then
    Cat (text "(") (Cat (printAppSpine (EApp f x)) (text ")"))
  else
    printAppSpine (EApp f x)
printOperand prec e = printExpr prec e

printUsePath : UsePath -> Doc
printUsePath (UseName names) = text (joinWith "." names)
printUsePath (UseGroup names members) =
  Cat
    (text (joinWith "." names))
    (Cat (text ".") (delimitedG "{" "}" (map useMemberDoc members)))
printUsePath (UseWild names) = Cat (text (joinWith "." names)) (text ".*")
printUsePath (UseAlias names alias) =
  Cat (text (joinWith "." names)) (Cat (text " as ") (text alias))

useMemberDoc : UseMember -> Doc
useMemberDoc (UseMember n allCtors _ alias) =
  let base = if allCtors then Cat (text n) (text "(..)") else text n
  match alias
    Some a => Cat base (text " as \{a}")
    None => base

-- A single `data` variant (without the leading `| `).
printVariant : Variant -> Doc
printVariant (Variant name (ConPos tys)) =
  Cat (text name) (concatD (map (t => Cat (text " ") (printTypeAtom t)) tys))
-- Width-aware: stay inline `name { f0 : T0, f1 : T1 }` when the field list fits
-- the width budget at the current indent; otherwise break to one-field-per-line
-- BRACE-ON-NAME-LINE, TRAILING-COMMA style (mirrors `printNamedFieldData`'s field
-- format), so a wide single-variant record (e.g. `Select`'s 8 fields) wraps
-- instead of collapsing onto one ~200-char line:
--   name {
--     f0 : T0,
--     f1 : T1,
--   }
-- The `{` stays on the name line; each field (incl. the last) gets a TRAILING
-- comma; the `}` sits on its own line one step under the name.  `Line`/`FlatAlt`
-- switch each piece by group mode; the outer `nest` indents `{`/`}` one step
-- under the name, the inner `nest` indents the fields one step further.
-- `nameOmitted = True` prints the short anonymous-record form `{ … }` with no
-- ctor name (`data X = { … }`); the leading space is supplied by the ` = `
-- separator in `dataVariantDocs`.  False keeps the explicit `name { … }` form.
printVariant (Variant name (ConNamed fields nameOmitted)) =
  let sep = Cat (text ",") Line
  let trailing = FlatAlt (text ",") Nil
  let namePart = if nameOmitted then Nil else text name
  let braceOpen = if nameOmitted then text "{" else text " {"
  group (Cat
    namePart
    (nest (Cat
      braceOpen
      (Cat
        (nest (Cat Line (Cat (sepBy sep (map fieldTyDoc fields)) trailing)))
        (Cat Line (text "}"))))))

fieldTyDoc : Field -> Doc
fieldTyDoc (Field fn ft) = Cat (text fn) (Cat (text " : ") (printType ft))

-- A single-variant record-style data decl (`data X = X { f : T, ... }`) rendered
-- ONE FIELD PER LINE in brace-on-name-line, TRAILING-COMMA style:
--   data X = X {
--       f0 : T0,
--       f1 : T1,
--     }
-- The flat one-liner form (`printDecl`) collapses every field onto one line, so a
-- per-field trailing comment has no line to attach to and the comment-aware fmt
-- layer (fmt.mdk) orphans it below the decl.  fmt routes a *commented* such decl
-- through here instead: header (with `{`) on line 0, field i on line i+1, `}`
-- last — output lines align 1:1 with the source field lines, so fmt's generic
-- interior-comment splice re-attaches each field's trailing comment by source-line
-- index.  Falls back to the plain renderer for any non-single-ConNamed shape.
export printNamedFieldData : DataVis -> String -> List String -> List Variant -> List String -> Doc
printNamedFieldData vis n params [Variant cname (ConNamed fields nameOmitted)] derives =
  let eqPart = if nameOmitted then text " =" else Cat (text " = ") (text cname)
  let head = Cat (text "data ") (Cat (text n) (Cat (concatD (map (p => Cat (text " ") (text p)) params)) eqPart))
  let body = Cat (text " {") (Cat (Nest 4 (concatD (map (f => Cat Hardline (Cat (fieldTyDoc f) (text ","))) fields))) (indentBlock (text "}")))
  let deriveDoc = if isEmptyL derives then
    Nil
  else
    Cat Hardline (printDerives derives)
  Cat (visPrefix vis) (Cat head (Cat body deriveDoc))
printNamedFieldData vis n params variants derives =
  printDecl (DData vis n params variants derives)

printDerives : List String -> Doc
printDerives [] = Nil
printDerives derives =
  Cat (text "deriving (") (Cat (text (joinWith ", " derives)) (text ")"))

visPrefix : DataVis -> Doc
visPrefix VisPublic = text "public export "
visPrefix VisAbstract = text "export "
visPrefix VisPrivate = Nil

-- `data` body.  Flat: `= V1 | V2 | …`.  Broken (new multiline form): a
-- line-final `=` on the header line, then one `| Vn` per variant (the FIRST
-- variant also gets a leading `|`):
--   data Foo =
--     | Bar
--     | Baz
-- FlatAlt picks the per-variant separator by group mode (broken → `Line "| "`,
-- flat → `" "` for the first / `" | "` for the rest).  The `=` stays on the
-- header line (outside `nest`); the variants `nest` by 2.
dataVariantDocs : List Variant -> Doc
dataVariantDocs [] = Nil
dataVariantDocs (v::vs) = Cat
  (text " =")
  (nest (Cat
    (Cat (FlatAlt (Cat Line (text "| ")) (text " ")) (printVariant v))
    (concatD (map
      (v2 => Cat (FlatAlt (Cat Line (text "| ")) (text " | ")) (printVariant v2))
      vs))))

-- Render a `data` declaration with interior comments interleaved.  Mirror of
-- lib/printer.ml's `print_data_decl_commented`.  `vcomments` is parallel to
-- `variants`: entry i = (leading, trailing) lexemes for variant i — LEADING
-- comments render on their own line(s) above the variant, the TRAILING comment
-- stays inline after it (`| Field String  -- .foo`).  Any non-empty entry forces
-- the one-variant-per-line layout via `Hardline` (never the soft `Line`
-- `dataVariantDocs` uses), so a documented `data` is never reflowed flat.
export printDataDeclCommented : DataVis -> String -> List String -> List Variant -> List String -> List (List String, List String) -> Doc
printDataDeclCommented vis n params variants derives vcomments =
  let head = Cat (text "data ") (Cat (text n) (concatD (map (p => Cat (text " ") (text p)) params)))
  let variantDocs = dataVariantDocsCommented variants vcomments
  let deriveDoc = if isEmptyL derives then
    Nil
  else
    Cat Hardline (printDerives derives)
  Cat (visPrefix vis) (Cat head (Cat variantDocs deriveDoc))

-- One Hardline + comment text per leading comment of a variant.
commentLinesDoc : List String -> Doc
commentLinesDoc cs = concatD (map (c => Cat Hardline (text c)) cs)

-- Trailing comments rendered inline (each preceded by two spaces) after the
-- variant on the same line.
trailingCommentsDoc : List String -> Doc
trailingCommentsDoc cs = concatD (map (c => Cat (text "  ") (text c)) cs)

-- One variant line: its leading comments (own lines) + `| Variant` + any inline
-- trailing comment.
variantCommentedDoc : Variant -> (List String, List String) -> Doc
variantCommentedDoc v (leading, trailing) =
  Cat
    (commentLinesDoc leading)
    (Cat
      Hardline
      (Cat (text "| ") (Cat (printVariant v) (trailingCommentsDoc trailing))))

dataVariantDocsCommented : List Variant -> List (List String, List String) -> Doc
dataVariantDocsCommented [] _ = Nil
dataVariantDocsCommented _ [] = Nil
dataVariantDocsCommented (v::vs) (vc::vcs) =
  Cat
    (text " =")
    (nest (Cat
      (variantCommentedDoc v vc)
      (concatD (map2VariantComment vs vcs))))

-- Mirror of List.map2 (fun v vc -> variantCommentedDoc v vc).
map2VariantComment : List Variant -> List (List String, List String) -> List Doc
map2VariantComment [] _ = []
map2VariantComment _ [] = []
map2VariantComment (v::vs) (vc::vcs) =
  variantCommentedDoc v vc :: map2VariantComment vs vcs

export printDecl : Decl -> Doc
printDecl (DTypeSig pub n t) = Cat
  (if pub then text "export " else Nil)
  (Cat (text n) (Cat (text " : ") (printType t)))
printDecl (DExtern pub n t) = Cat
  (if pub then text "export " else Nil)
  (Cat (text "extern ") (Cat (text n) (Cat (text " : ") (printType t))))
printDecl (DFunDef pub n pats body) =
  let header = Cat (if pub then text "export " else Nil) (Cat (text n) (concatD (map (p => Cat (text " ") (printPatAtom p)) pats)))
  Cat header (printDefRhs body)
printDecl (DLetGroup pub bindings) =
  Cat (if pub then text "export " else Nil) (letGroupDecl bindings)
printDecl (DData vis n params variants derives) =
  let head = Cat (text "data ") (Cat (text n) (concatD (map (p => Cat (text " ") (text p)) params)))
  let variantDocs = dataVariantDocs variants
  let deriveDoc = if isEmptyL derives then
    Nil
  else
    Cat Line (printDerives derives)
  group (Cat (visPrefix vis) (Cat head (Cat variantDocs deriveDoc)))
printDecl (DTypeAlias pub n params rhs) = Cat
  (if pub then text "export " else Nil)
  (Cat
    (text "type ")
    (Cat
      (text n)
      (Cat
        (concatD (map (p => Cat (text " ") (text p)) params))
        (Cat (text " = ") (printType rhs)))))
printDecl (DNewtype pub n params con fty derives) = Cat
  (if pub then text "export " else Nil)
  (Cat
    (text "newtype ")
    (Cat
      (text n)
      (Cat
        (concatD (map (p => Cat (text " ") (text p)) params))
        (Cat
          (text " = ")
          (Cat
            (text con)
            (Cat
              (text " ")
              (Cat
                (printTypeAtom fty)
                (if isEmptyL derives then Nil else Cat (text " deriving (") (Cat (text (joinWith ", " derives)) (text ")"))))))))))
printDecl (DInterface { pub, def, name, typarams, supers, methods }) = Cat
  (if pub then text "export " else Nil)
  (Cat
    (if def then text "default " else Nil)
    (Cat
      (text "interface ")
      (Cat
        (text name)
        (Cat
          (concatD (map (p => Cat (text " ") (text p)) typarams))
          (Cat
            (superDoc supers)
            (Cat
              (text " where")
              (indentBlock (sepBy Hardline (map ifaceMethodDoc methods)))))))))
printDecl (DImpl { pub, iface, tys, reqs, methods }) = Cat
  (if pub then text "export " else Nil)
  (Cat
    (text "impl ")
    (Cat
      (implHead iface tys)
      (Cat
        (reqsDoc reqs)
        (Cat
          (text " where")
          (indentBlock (sepBy Hardline (map implMethodDoc methods)))))))
printDecl (DUse pub path _) = Cat
  (if pub then text "export " else Nil)
  (Cat (text "import ") (printUsePath path))
printDecl (DEffect pub name domain isInternal) =
  Cat (effDeclHead pub isInternal) (Cat (text name) (effDomainDoc domain))
printDecl (DProp pub propName propParams propBody) = Cat
  (if pub then text "export " else Nil)
  (Cat
    (text "prop ")
    (Cat
      (text (escStringLit propName))
      (Cat (concatD (map propParamDoc propParams)) (printDefRhs propBody))))
printDecl (DTest pub testName testBody) = Cat
  (if pub then text "export " else Nil)
  (Cat
    (text "test ")
    (Cat (text (escStringLit testName)) (printDefRhs testBody)))
printDecl (DBench pub benchName benchBody) = Cat
  (if pub then text "export " else Nil)
  (Cat
    (text "bench ")
    (Cat (text (escStringLit benchName)) (printDefRhs benchBody)))
printDecl (DAttrib attrs inner) =
  Cat (concatD (map attrDoc attrs)) (printDecl inner)

-- prop param: ` (name : ppTy ty)` — mirrors lib/ast.ml's pp_ty (a precedence
-- type printer distinct from printType — see ppTy below).
propParamDoc : PropParam -> Doc
propParamDoc (PropParam x ty) = text " (\{x} : \{ppTy ty})"

attrDoc : Attr -> Doc
attrDoc (AttrDeprecated msg) =
  Cat (text ("@deprecated " ++ escStringLit msg)) (text "\n")
attrDoc AttrInline = Cat (text "@inline") (text "\n")
attrDoc AttrMustUse = Cat (text "@must_use") (text "\n")

-- `let rec` for the first clause, `with` for the rest (across all bindings).
letGroupDecl : List LetBind -> Doc
letGroupDecl bindings =
  let docs = letGroupDeclGo True bindings
  concatD docs

letGroupDeclGo : Bool -> List LetBind -> List Doc
letGroupDeclGo _ [] = []
letGroupDeclGo first ((LetBind name clauses)::rest) =
  let r = letGroupBindClauses first name clauses
  match r
    (docs, nextFirst) => docs ++ letGroupDeclGo nextFirst rest

letGroupBindClauses : Bool -> String -> List FunClause -> (List Doc, Bool)
letGroupBindClauses first _ [] = ([], first)
letGroupBindClauses first name (c::cs) =
  let d = letGroupDeclClause first name c
  let r = letGroupBindClauses False name cs
  match r
    (rest, lastFirst) => (d::rest, lastFirst)

letGroupDeclClause : Bool -> String -> FunClause -> Doc
letGroupDeclClause first name (FunClause pats body) = Cat
  (if first then text "let rec " else Cat Hardline (text "with "))
  (Cat
    (text name)
    (Cat
      (concatD (map (p => Cat (text " ") (printPatAtom p)) pats))
      (Cat (text " =") (letGroupDeclClauseBody body))))

letGroupDeclClauseBody : Expr -> Doc
letGroupDeclClauseBody (ELoc _ e) = letGroupDeclClauseBody e
letGroupDeclClauseBody (EBlock stmts) = printExprBody (EBlock stmts)
letGroupDeclClauseBody body
  | isBlockBody body = indentBlock (printExprBody body)
  | otherwise = Cat (text " ") (printExprBody body)

superDoc : List Super -> Doc
superDoc [] = Nil
superDoc supers =
  Cat (text " requires ") (sepBy (text ", ") (map oneSuper supers))

oneSuper : Super -> Doc
oneSuper (Super n ps) =
  Cat (text n) (concatD (map (p => Cat (text " ") (text p)) ps))

ifaceMethodDoc : IfaceMethod -> Doc
ifaceMethodDoc (IfaceMethod n ty None) =
  Cat (text n) (Cat (text " : ") (printType ty))
ifaceMethodDoc (IfaceMethod n _ (Some (MethodDefault pats body))) = Cat
  (text n)
  (Cat
    (concatD (map (p => Cat (text " ") (printPatAtom p)) pats))
    (Cat (text " = ") (printExprBody body)))

implHead : String -> List Ty -> Doc
implHead iface tys =
  Cat (text iface) (concatD (map (t => Cat (text " ") (printTypeAtom t)) tys))

reqsDoc : List Require -> Doc
reqsDoc [] = Nil
reqsDoc reqs = Cat (text " requires ") (sepBy (text ", ") (map oneReq reqs))

oneReq : Require -> Doc
oneReq (Require iface args) =
  Cat (text iface) (concatD (map (t => Cat (text " ") (printTypeAtom t)) args))

implMethodDoc : ImplMethod -> Doc
implMethodDoc (ImplMethod n pats body) = Cat
  (text n)
  (Cat
    (concatD (map (p => Cat (text " ") (printPatAtom p)) pats))
    (printDefRhs body))

-- ── pp_ty (the precedence type printer used by prop params) ─────────
-- Mirror of lib/ast.ml's pp_ty_prec / pp_ty.  Distinct from printType: it
-- parenthesizes by precedence level (0 top, 1 fun-lhs, 2 app-arg), with no
-- leading space in app, etc.

ppTy : Ty -> String
ppTy t = ppTyPrec 0 t

ppTyPrec : Int -> Ty -> String
ppTyPrec _ (TyCon s _) = tyConSurface s
ppTyPrec _ (TyVar s) = s
ppTyPrec _ (TyTuple ts) = "(" ++ joinWith ", " (map (ppTyPrec 0) ts) ++ ")"
ppTyPrec p (TyApp f x) =
  let s = "\{ppTyPrec 1 f} \{ppTyPrec 2 x}"
  if p >= 2 then "(" ++ s ++ ")" else s
ppTyPrec p (TyFun a b) =
  let s = "\{ppTyPrec 1 a} -> \{ppTyPrec 0 b}"
  if p >= 1 then "(" ++ s ++ ")" else s
ppTyPrec p (TyEffect effs tail t) =
  let inside = ppEffInside effs tail
  let s = "<\{inside}> \{ppTyPrec 0 t}"
  if p >= 1 then "(" ++ s ++ ")" else s
ppTyPrec _ (TyConstrained cs t) =
  let csStr = match cs
    [c] => ppConstr c
    _ => "(" ++ joinWith ", " (map ppConstr cs) ++ ")"
  "\{csStr} => \{ppTyPrec 0 t}"

ppEffInside : List (String, Option String) -> Option String -> String
ppEffInside effs None = joinWith ", " (map ppEffAtom effs)
ppEffInside [] (Some v) = v
ppEffInside effs (Some v) = "\{joinWith ", " (map ppEffAtom effs)} | \{v}"

-- a row atom renders as the label, or label + space + quoted param,
-- byte-identical to lib/printer.ml TyEffect atom rendering.
ppEffAtom : (String, Option String) -> String
ppEffAtom (l, None) = l
ppEffAtom (l, Some s) = "\{l} \{escStringLit s}"

-- domain suffix for an effect declaration: space + name, or empty.
effDomainDoc : Option String -> Doc
effDomainDoc None = Nil
effDomainDoc (Some d) = Cat (text " ") (text d)

-- header for an effect declaration: internal/export/plain effect keyword.
effDeclHead : Bool -> Bool -> Doc
effDeclHead _ True = text "internal effect "
effDeclHead True False = text "export effect "
effDeclHead False False = text "effect "

ppConstr : Constraint -> String
ppConstr (Constraint iface args) =
  if isEmptyL args then
    iface
  else
    "\{iface} \{joinWith " " (map (ppTyPrec 2) args)}"

-- ── Public entry points ───────────────────────────

export exprToString : Expr -> String
exprToString e = render (printExpr precTop e)

export declToString : Decl -> String
declToString d = render (printDecl d)

-- program_to_string: each decl rendered + a trailing newline, concatenated.
export programToString : List Decl -> String
programToString decls = stringConcat (map declLine decls)

declLine : Decl -> String
declLine d = render (printDecl d) ++ "\n"
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Ty" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true) (mem "Attr" true))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "listLen" false) (mem "allList" false) (mem "reverseL" false) (mem "isEmptyL" false))))
(DData Public "Doc" () ((variant "Nil" (ConPos)) (variant "Text" (ConPos (TyCon "String"))) (variant "Cat" (ConPos (TyCon "Doc") (TyCon "Doc"))) (variant "Line" (ConPos)) (variant "Softline" (ConPos)) (variant "Hardline" (ConPos)) (variant "Nest" (ConPos (TyCon "Int") (TyCon "Doc"))) (variant "Group" (ConPos (TyCon "Doc"))) (variant "FlatGroup" (ConPos (TyCon "Doc"))) (variant "FlatAlt" (ConPos (TyCon "Doc") (TyCon "Doc"))) (variant "LineComment" (ConPos (TyCon "String")))) ())
(DTypeSig false "text" (TyFun (TyCon "String") (TyCon "Doc")))
(DFunDef false "text" ((PVar "s")) (EApp (EVar "Text") (EVar "s")))
(DTypeSig false "group" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "group" ((PVar "d")) (EApp (EVar "Group") (EVar "d")))
(DTypeSig false "flatGroup" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "flatGroup" ((PVar "d")) (EApp (EVar "FlatGroup") (EVar "d")))
(DTypeSig false "flatAlt" (TyFun (TyCon "Doc") (TyFun (TyCon "Doc") (TyCon "Doc"))))
(DFunDef false "flatAlt" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "FlatAlt") (EVar "a")) (EVar "b")))
(DTypeSig false "trailingCommaFor" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Doc")))
(DFunDef false "trailingCommaFor" ((PList)) (EVar "Nil"))
(DFunDef false "trailingCommaFor" ((PList PWild)) (EVar "Nil"))
(DFunDef false "trailingCommaFor" (PWild) (EApp (EApp (EVar "flatAlt") (EApp (EVar "text") (ELit (LString ",")))) (EVar "Nil")))
(DTypeSig false "nest" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "nest" ((PVar "d")) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EVar "d")))
(DTypeSig false "sepBy" (TyFun (TyCon "Doc") (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc"))))
(DFunDef false "sepBy" (PWild (PList)) (EVar "Nil"))
(DFunDef false "sepBy" (PWild (PList (PVar "x"))) (EVar "x"))
(DFunDef false "sepBy" ((PVar "sep") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "Cat") (EVar "x")) (EApp (EApp (EVar "Cat") (EVar "sep")) (EApp (EApp (EVar "sepBy") (EVar "sep")) (EVar "xs")))))
(DTypeSig false "concatD" (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc")))
(DFunDef false "concatD" ((PList)) (EVar "Nil"))
(DFunDef false "concatD" ((PCons (PVar "d") (PVar "ds"))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "concatD") (EVar "ds"))))
(DTypeSig false "indentBlock" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "indentBlock" ((PVar "d")) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EVar "d"))))
(DTypeSig false "delimited" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc")))))
(DFunDef false "delimited" ((PVar "open_") (PVar "close_") (PList)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EVar "text") (EVar "close_"))))
(DFunDef false "delimited" ((PVar "open_") (PVar "close_") (PVar "items")) (EApp (EVar "flatGroup") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Softline")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ",")))) (EVar "Line"))) (EVar "items"))) (EApp (EVar "trailingCommaFor") (EVar "items")))))) (EApp (EApp (EVar "Cat") (EVar "Softline")) (EApp (EVar "text") (EVar "close_")))))))
(DTypeSig false "delimitedG" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc")))))
(DFunDef false "delimitedG" ((PVar "open_") (PVar "close_") (PList)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EVar "text") (EVar "close_"))))
(DFunDef false "delimitedG" ((PVar "open_") (PVar "close_") (PVar "items")) (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Softline")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ",")))) (EVar "Line"))) (EVar "items"))) (EApp (EVar "trailingCommaFor") (EVar "items")))))) (EApp (EApp (EVar "Cat") (EVar "Softline")) (EApp (EVar "text") (EVar "close_")))))))
(DTypeSig false "braced" (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc")))
(DFunDef false "braced" ((PList)) (EApp (EVar "text") (ELit (LString "{}"))))
(DFunDef false "braced" ((PVar "items")) (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "{")))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ",")))) (EVar "Line"))) (EVar "items"))) (EApp (EVar "trailingCommaFor") (EVar "items")))))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "text") (ELit (LString "}"))))))))
(DData Public "Mode" () ((variant "Flat" (ConPos)) (variant "Break" (ConPos))) ())
(DData Public "Item" () ((variant "Item" (ConPos (TyCon "Int") (TyCon "Mode") (TyCon "Doc")))) ())
(DTypeSig false "defaultWidth" (TyCon "Int"))
(DFunDef false "defaultWidth" () (ELit (LInt 80)))
(DTypeSig false "fits" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Item")) (TyCon "Bool"))))
(DFunDef false "fits" ((PVar "w") PWild) (EIf (EBinOp "<" (EVar "w") (ELit (LInt 0))) (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "fits" (PWild (PList)) (EVar "True"))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" PWild PWild (PCon "Nil")) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EVar "z")))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Cat" (PVar "a") (PVar "b"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "a")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "b")) (EVar "z")))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Nest" (PVar "j") (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "m")) (EVar "d")) (EVar "z"))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" PWild PWild (PCon "Text" (PVar "s"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "w") (EApp (EVar "stringLength") (EVar "s")))) (EVar "z")))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Line")) (PVar "z"))) (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "w") (ELit (LInt 1)))) (EVar "z")))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Softline")) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EVar "z")))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Break") (PCon "Line")) PWild)) (EVar "True"))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Break") (PCon "Softline")) PWild)) (EVar "True"))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Break") (PCon "Hardline")) PWild)) (EVar "True"))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Hardline")) PWild)) (EVar "False"))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") PWild (PCon "Group" (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d")) (EVar "z"))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") PWild (PCon "FlatGroup" (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d")) (EVar "z"))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "FlatAlt" PWild (PVar "b"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "b")) (EVar "z"))))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild PWild (PCon "LineComment" PWild)) PWild)) (EVar "True"))
(DTypeSig false "spaces" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "spaces" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ELit (LString "")) (EIf (EVar "otherwise") (EBinOp "++" (ELit (LString " ")) (EApp (EVar "spaces") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "newlineStr" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "newlineStr" ((PVar "i")) (EBinOp "++" (ELit (LString "\n")) (EApp (EVar "spaces") (EVar "i"))))
(DTypeSig false "go" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Item")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "go" (PWild (PList)) (EListLit))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild PWild (PCon "Nil")) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EVar "z")))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Cat" (PVar "a") (PVar "b"))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "a")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "b")) (EVar "z")))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Nest" (PVar "j") (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "m")) (EVar "d")) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild PWild (PCon "Text" (PVar "s"))) (PVar "z"))) (EBinOp "::" (EVar "s") (EApp (EApp (EVar "go") (EBinOp "+" (EVar "col") (EApp (EVar "stringLength") (EVar "s")))) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Line")) (PVar "z"))) (EBinOp "::" (ELit (LString " ")) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "col") (ELit (LInt 1)))) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Softline")) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EVar "z")))
(DFunDef false "go" (PWild (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "Line")) (PVar "z"))) (EBinOp "::" (EApp (EVar "newlineStr") (EVar "i")) (EApp (EApp (EVar "go") (EVar "i")) (EVar "z"))))
(DFunDef false "go" (PWild (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "Softline")) (PVar "z"))) (EBinOp "::" (EApp (EVar "newlineStr") (EVar "i")) (EApp (EApp (EVar "go") (EVar "i")) (EVar "z"))))
(DFunDef false "go" (PWild (PCons (PCon "Item" (PVar "i") PWild (PCon "Hardline")) (PVar "z"))) (EBinOp "::" (EApp (EVar "newlineStr") (EVar "i")) (EApp (EApp (EVar "go") (EVar "i")) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") PWild (PCon "Group" (PVar "d"))) (PVar "z"))) (EBlock (DoLet false false (PVar "flat") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d")) (EVar "z"))) (DoExpr (EIf (EBinOp "||" (EBinOp ">=" (EVar "col") (EVar "defaultWidth")) (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "defaultWidth") (EVar "col"))) (EVar "flat"))) (EApp (EApp (EVar "go") (EVar "col")) (EVar "flat")) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "d")) (EVar "z")))))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") PWild (PCon "FlatGroup" (PVar "d"))) (PVar "z"))) (EBlock (DoLet false false (PVar "flat") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d")) (EVar "z"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp ">=" (EVar "col") (EVar "defaultWidth")) (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "defaultWidth") (EVar "col"))) (EVar "flat"))) (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "defaultWidth") (EVar "i"))) (EListLit (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d"))))) (EApp (EApp (EVar "go") (EVar "col")) (EVar "flat")) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "d")) (EVar "z")))))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Flat") (PCon "FlatAlt" PWild (PVar "b"))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "b")) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "FlatAlt" (PVar "a") PWild)) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "a")) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild PWild (PCon "LineComment" (PVar "s"))) (PVar "z"))) (EBinOp "::" (EBinOp "++" (ELit (LString "  ")) (EVar "s")) (EApp (EApp (EVar "go") (EBinOp "+" (EBinOp "+" (EVar "col") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "s")))) (EVar "z"))))
(DTypeSig true "render" (TyFun (TyCon "Doc") (TyCon "String")))
(DFunDef false "render" ((PVar "doc")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "go") (ELit (LInt 0))) (EListLit (EApp (EApp (EApp (EVar "Item") (ELit (LInt 0))) (EVar "Break")) (EVar "doc"))))))
(DTypeSig false "escapeCharLit" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escapeCharLit" ((PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "'"))) (ELit (LString "\\'")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\\"))) (ELit (LString "\\\\")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\n"))) (ELit (LString "\\n")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\t"))) (ELit (LString "\\t")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\r"))) (ELit (LString "\\r")) (EIf (EBinOp "==" (EVar "c") (ELit (LString " "))) (ELit (LString "\\0")) (EIf (EVar "otherwise") (EVar "c") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "escStringLit" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escStringLit" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "escSChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))))) (ELit (LString "\""))))
(DTypeSig false "escSChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "escSChars" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "escSOne") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EVar "escSChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "escSOne" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "escSOne" ((PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\\"))) (ELit (LString "\\\\")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (ELit (LString "\\\"")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\n"))) (ELit (LString "\\n")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\t"))) (ELit (LString "\\t")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\r"))) (ELit (LString "\\r")) (EIf (EVar "otherwise") (EApp (EVar "charToStr") (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "printLit" (TyFun (TyCon "Lit") (TyCon "Doc")))
(DFunDef false "printLit" ((PCon "LInt" (PVar "n"))) (EApp (EVar "text") (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "printLit" ((PCon "LFloat" (PVar "f"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "floatToString") (EVar "f"))) (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EApp (EVar "text") (EIf (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString ".")))) (EBinOp "++" (EVar "s") (ELit (LString "0"))) (EVar "s"))))))
(DFunDef false "printLit" ((PCon "LString" (PVar "s"))) (EApp (EVar "text") (EApp (EVar "escStringLit") (EVar "s"))))
(DFunDef false "printLit" ((PCon "LChar" (PVar "c"))) (EApp (EVar "text") (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "escapeCharLit") (EVar "c"))) (ELit (LString "'")))))
(DFunDef false "printLit" ((PCon "LBool" (PVar "b"))) (EApp (EVar "text") (EIf (EVar "b") (ELit (LString "True")) (ELit (LString "False")))))
(DFunDef false "printLit" ((PCon "LUnit")) (EApp (EVar "text") (ELit (LString "()"))))
(DTypeSig false "isNegLit" (TyFun (TyCon "Lit") (TyCon "Bool")))
(DFunDef false "isNegLit" ((PCon "LInt" (PVar "n"))) (EBinOp "<" (EVar "n") (ELit (LInt 0))))
(DFunDef false "isNegLit" ((PCon "LFloat" (PVar "f"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "floatToString") (EVar "f"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "-")))))))
(DFunDef false "isNegLit" (PWild) (EVar "False"))
(DTypeSig false "tyConSurface" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple2__"))) (ELit (LString "(,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple3__"))) (ELit (LString "(,,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple4__"))) (ELit (LString "(,,,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple5__"))) (ELit (LString "(,,,,)")))
(DFunDef false "tyConSurface" ((PVar "n")) (EVar "n"))
(DTypeSig false "printType" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "printType" ((PCon "TyCon" (PVar "n") PWild)) (EApp (EVar "text") (EApp (EVar "tyConSurface") (EVar "n"))))
(DFunDef false "printType" ((PCon "TyVar" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printType" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printTypeAppLhs") (EVar "a"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "b")))))
(DFunDef false "printType" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printTypeFunLhs") (EVar "a"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " -> ")))) (EApp (EVar "printType") (EVar "b")))))
(DFunDef false "printType" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "printType")) (EVar "ts")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printType" ((PCon "TyEffect" (PVar "es") (PVar "tail") (PVar "t"))) (EBlock (DoLet false false (PVar "inside") (EApp (EApp (EVar "effectInside") (EVar "es")) (EVar "tail"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "<")))) (EApp (EApp (EVar "Cat") (EVar "inside")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "> ")))) (EApp (EVar "printTypeAppLhs") (EVar "t"))))))))
(DFunDef false "printType" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBlock (DoLet false false (PVar "csDoc") (EMatch (EVar "cs") (arm (PList (PVar "c")) () (EApp (EVar "printConstraint") (EVar "c"))) (arm PWild () (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "printConstraint")) (EVar "cs")))) (EApp (EVar "text") (ELit (LString ")")))))))) (DoExpr (EApp (EApp (EVar "Cat") (EVar "csDoc")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " => ")))) (EApp (EVar "printType") (EVar "t")))))))
(DTypeSig false "effectInside" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Doc"))))
(DFunDef false "effectInside" ((PVar "es") (PCon "None")) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "effAtomDoc")) (EVar "es"))))
(DFunDef false "effectInside" ((PList) (PCon "Some" (PVar "v"))) (EApp (EVar "text") (EVar "v")))
(DFunDef false "effectInside" ((PVar "es") (PCon "Some" (PVar "v"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "effAtomDoc")) (EVar "es")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " | ")))) (EApp (EVar "text") (EVar "v")))))
(DTypeSig false "effAtomDoc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc")))
(DFunDef false "effAtomDoc" ((PTuple (PVar "l") (PCon "None"))) (EApp (EVar "text") (EVar "l")))
(DFunDef false "effAtomDoc" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EApp (EVar "text") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "l"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStringLit") (EVar "s")))) (ELit (LString "")))))
(DTypeSig false "printConstraint" (TyFun (TyCon "Constraint") (TyCon "Doc")))
(DFunDef false "printConstraint" ((PCon "Constraint" (PVar "iface") (PVar "args"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "iface"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "a"))))) (EVar "args")))))
(DTypeSig false "printTypeAtom" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "printTypeAtom" ((PCon "TyCon" (PVar "n") PWild)) (EApp (EVar "text") (EApp (EVar "tyConSurface") (EVar "n"))))
(DFunDef false "printTypeAtom" ((PCon "TyVar" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printTypeAtom" ((PCon "TyTuple" (PVar "ts"))) (EApp (EVar "printType") (EApp (EVar "TyTuple") (EVar "ts"))))
(DFunDef false "printTypeAtom" ((PVar "t")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printType") (EVar "t"))) (EApp (EVar "text") (ELit (LString ")"))))))
(DTypeSig false "printTypeFunLhs" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "printTypeFunLhs" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printType") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printTypeFunLhs" ((PVar "t")) (EApp (EVar "printType") (EVar "t")))
(DTypeSig false "printTypeAppLhs" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "printTypeAppLhs" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EVar "printType") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))))
(DFunDef false "printTypeAppLhs" ((PVar "t")) (EApp (EVar "printTypeAtom") (EVar "t")))
(DTypeSig false "printPat" (TyFun (TyCon "Pat") (TyCon "Doc")))
(DFunDef false "printPat" ((PCon "PVar" (PVar "x"))) (EApp (EVar "text") (EVar "x")))
(DFunDef false "printPat" ((PCon "PWild")) (EApp (EVar "text") (ELit (LString "_"))))
(DFunDef false "printPat" ((PCon "PLit" (PVar "l"))) (EApp (EVar "printLit") (EVar "l")))
(DFunDef false "printPat" ((PCon "PCon" (PVar "c") (PList))) (EApp (EVar "text") (EVar "c")))
(DFunDef false "printPat" ((PCon "PCon" (PVar "c") (PVar "pats"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))) (EApp (EVar "text") (ELit (LString ")")))))))
(DFunDef false "printPat" ((PCon "PCons" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPatAtom") (EVar "a"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "::")))) (EApp (EVar "printPat") (EVar "b")))))
(DFunDef false "printPat" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "printPatArm")) (EVar "ps")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printPat" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "[")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "printPatArm")) (EVar "ps")))) (EApp (EVar "text") (ELit (LString "]"))))))
(DFunDef false "printPat" ((PCon "PAs" (PVar "x") (PVar "inner"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "@")))) (EApp (EVar "printPatAtom") (EVar "inner")))))
(DFunDef false "printPat" ((PCon "PRec" (PVar "name") (PVar "fields") (PVar "rest"))) (EBlock (DoLet false false (PVar "fieldDocs") (EApp (EApp (EVar "map") (EVar "recPatFieldDoc")) (EVar "fields"))) (DoLet false false (PVar "all") (EIf (EVar "rest") (EBinOp "++" (EVar "fieldDocs") (EListLit (EApp (EVar "text") (ELit (LString "..."))))) (EVar "fieldDocs"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " { ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EVar "all"))) (EApp (EVar "text") (ELit (LString " }")))))))))
(DFunDef false "printPat" ((PCon "PRng" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printLit") (EVar "lo"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "incl") (ELit (LString "..=")) (ELit (LString ".."))))) (EApp (EVar "printLit") (EVar "hi")))))
(DTypeSig false "recPatFieldDoc" (TyFun (TyCon "RecPatField") (TyCon "Doc")))
(DFunDef false "recPatFieldDoc" ((PCon "RecPatField" (PVar "k") (PCon "None"))) (EApp (EVar "text") (EVar "k")))
(DFunDef false "recPatFieldDoc" ((PCon "RecPatField" (PVar "k") (PCon "Some" (PVar "q")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "k"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "printPat") (EVar "q")))))
(DTypeSig false "printPatAtom" (TyFun (TyCon "Pat") (TyCon "Doc")))
(DFunDef false "printPatAtom" ((PCon "PVar" (PVar "x"))) (EApp (EVar "printPat") (EApp (EVar "PVar") (EVar "x"))))
(DFunDef false "printPatAtom" ((PCon "PWild")) (EApp (EVar "printPat") (EVar "PWild")))
(DFunDef false "printPatAtom" ((PCon "PLit" (PVar "l"))) (EApp (EVar "printPat") (EApp (EVar "PLit") (EVar "l"))))
(DFunDef false "printPatAtom" ((PCon "PCon" (PVar "c") (PVar "ps"))) (EApp (EVar "printPat") (EApp (EApp (EVar "PCon") (EVar "c")) (EVar "ps"))))
(DFunDef false "printPatAtom" ((PCon "PTuple" (PVar "ps"))) (EApp (EVar "printPat") (EApp (EVar "PTuple") (EVar "ps"))))
(DFunDef false "printPatAtom" ((PCon "PList" (PVar "ps"))) (EApp (EVar "printPat") (EApp (EVar "PList") (EVar "ps"))))
(DFunDef false "printPatAtom" ((PCon "PRec" (PVar "n") (PVar "fs") (PVar "r"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EApp (EApp (EApp (EVar "PRec") (EVar "n")) (EVar "fs")) (EVar "r")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printPatAtom" ((PCon "PRng" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EVar "printPat") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "incl"))))
(DFunDef false "printPatAtom" ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "p"))) (EApp (EVar "text") (ELit (LString ")"))))))
(DTypeSig false "printPatArm" (TyFun (TyCon "Pat") (TyCon "Doc")))
(DFunDef false "printPatArm" ((PCon "PCon" (PVar "c") (PCons (PVar "p") (PVar "ps")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "c"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "q")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "q"))))) (EBinOp "::" (EVar "p") (EVar "ps"))))))
(DFunDef false "printPatArm" ((PVar "p")) (EApp (EVar "printPat") (EVar "p")))
(DTypeSig false "precTop" (TyCon "Int"))
(DFunDef false "precTop" () (ELit (LInt 0)))
(DTypeSig false "precAssign" (TyCon "Int"))
(DFunDef false "precAssign" () (ELit (LInt 1)))
(DTypeSig false "precPipe" (TyCon "Int"))
(DFunDef false "precPipe" () (ELit (LInt 2)))
(DTypeSig false "precCompose" (TyCon "Int"))
(DFunDef false "precCompose" () (ELit (LInt 3)))
(DTypeSig false "precOr" (TyCon "Int"))
(DFunDef false "precOr" () (ELit (LInt 4)))
(DTypeSig false "precAnd" (TyCon "Int"))
(DFunDef false "precAnd" () (ELit (LInt 5)))
(DTypeSig false "precCmp" (TyCon "Int"))
(DFunDef false "precCmp" () (ELit (LInt 6)))
(DTypeSig false "precCons" (TyCon "Int"))
(DFunDef false "precCons" () (ELit (LInt 7)))
(DTypeSig false "precAppend" (TyCon "Int"))
(DFunDef false "precAppend" () (ELit (LInt 8)))
(DTypeSig false "precAdd" (TyCon "Int"))
(DFunDef false "precAdd" () (ELit (LInt 9)))
(DTypeSig false "precMul" (TyCon "Int"))
(DFunDef false "precMul" () (ELit (LInt 10)))
(DTypeSig false "precInfix" (TyCon "Int"))
(DFunDef false "precInfix" () (ELit (LInt 11)))
(DTypeSig false "precApp" (TyCon "Int"))
(DFunDef false "precApp" () (ELit (LInt 12)))
(DTypeSig false "precUnary" (TyCon "Int"))
(DFunDef false "precUnary" () (ELit (LInt 13)))
(DTypeSig false "precPostfix" (TyCon "Int"))
(DFunDef false "precPostfix" () (ELit (LInt 14)))
(DTypeSig false "precAtom" (TyCon "Int"))
(DFunDef false "precAtom" () (ELit (LInt 15)))
(DTypeSig false "binopPrec" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "binopPrec" ((PVar "op")) (EIf (EBinOp "==" (EVar "op") (ELit (LString ":="))) (EVar "precAssign") (EIf (EBinOp "==" (EVar "op") (ELit (LString "|>"))) (EVar "precPipe") (EIf (EBinOp "==" (EVar "op") (ELit (LString ">>"))) (EVar "precCompose") (EIf (EBinOp "==" (EVar "op") (ELit (LString "<<"))) (EVar "precCompose") (EIf (EBinOp "==" (EVar "op") (ELit (LString "||"))) (EVar "precOr") (EIf (EBinOp "==" (EVar "op") (ELit (LString "&&"))) (EVar "precAnd") (EIf (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString "!="))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString "<"))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString "<="))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString ">="))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString "::"))) (EVar "precCons") (EIf (EBinOp "==" (EVar "op") (ELit (LString "++"))) (EVar "precAppend") (EIf (EBinOp "==" (EVar "op") (ELit (LString "+"))) (EVar "precAdd") (EIf (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EVar "precAdd") (EIf (EBinOp "==" (EVar "op") (ELit (LString "*"))) (EVar "precMul") (EIf (EBinOp "==" (EVar "op") (ELit (LString "/"))) (EVar "precMul") (EIf (EVar "otherwise") (EVar "precInfix") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))))))))))))
(DTypeSig false "isRightAssoc" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isRightAssoc" ((PLit (LString "::"))) (EVar "True"))
(DFunDef false "isRightAssoc" ((PLit (LString ":="))) (EVar "True"))
(DFunDef false "isRightAssoc" (PWild) (EVar "False"))
(DTypeSig false "isContinuationOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isContinuationOp" ((PVar "op")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "|>"))) (EBinOp "==" (EVar "op") (ELit (LString ">>")))) (EBinOp "==" (EVar "op") (ELit (LString "<<")))) (EBinOp "==" (EVar "op") (ELit (LString "&&")))) (EBinOp "==" (EVar "op") (ELit (LString "||")))) (EBinOp "==" (EVar "op") (ELit (LString "++")))))
(DTypeSig false "isConstructorOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isConstructorOp" ((PVar "op")) (EBinOp "==" (EVar "op") (ELit (LString "::"))))
(DTypeSig false "isConsAtomOperand" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isConsAtomOperand" ((PVar "e")) (EBlock (DoLet false false (PVar "p") (EApp (EVar "exprPrec") (EVar "e"))) (DoExpr (EBinOp "||" (EBinOp "==" (EVar "p") (EVar "precAtom")) (EBinOp "==" (EVar "p") (EVar "precPostfix"))))))
(DTypeSig false "consTight" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "consTight" ((PVar "op") (PVar "l") (PVar "r")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isConstructorOp") (EVar "op")) (EApp (EVar "isConsAtomOperand") (EVar "l"))) (EApp (EVar "isConsAtomOperand") (EVar "r"))))
(DTypeSig false "binopSpace" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc")))))
(DFunDef false "binopSpace" ((PVar "op") (PVar "l") (PVar "r")) (EIf (EApp (EApp (EApp (EVar "consTight") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "Nil") (EApp (EVar "text") (ELit (LString " ")))))
(DTypeSig false "exprPrec" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "exprPrec" ((PCon "ELit" (PVar "l"))) (EIf (EApp (EVar "isNegLit") (EVar "l")) (EVar "precUnary") (EVar "precAtom")))
(DFunDef false "exprPrec" ((PCon "ENumLit" (PVar "n") PWild PWild)) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EVar "precUnary") (EVar "precAtom")))
(DFunDef false "exprPrec" ((PCon "EVar" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EMethodRef" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EDictApp" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ETuple" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EArrayLit" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EListLit" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EMapLit" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ESetLit" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EStringInterp" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ERecordCreate" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ERecordUpdate" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EVariantUpdate" PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ERangeList" PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ERangeArray" PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ESlice" PWild PWild PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EFieldAccess" PWild PWild PWild)) (EVar "precPostfix"))
(DFunDef false "exprPrec" ((PCon "EIndex" PWild PWild PWild)) (EVar "precPostfix"))
(DFunDef false "exprPrec" ((PCon "EUnOp" PWild PWild PWild)) (EVar "precUnary"))
(DFunDef false "exprPrec" ((PCon "EApp" PWild PWild)) (EVar "precApp"))
(DFunDef false "exprPrec" ((PCon "EInfix" PWild PWild PWild)) (EVar "precInfix"))
(DFunDef false "exprPrec" ((PCon "EBinOp" (PVar "op") PWild PWild PWild)) (EApp (EVar "binopPrec") (EVar "op")))
(DFunDef false "exprPrec" ((PCon "ESection" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EAsPat" PWild PWild)) (EVar "precApp"))
(DFunDef false "exprPrec" ((PCon "ELam" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "ELet" PWild PWild PWild PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "ELetGroup" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EIf" PWild PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EMatch" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EBlock" PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EDo" PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EAnnot" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EHeadAnnot" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EGuards" PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EVarAt" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EMethodAt" PWild PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EDictAt" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "exprPrec") (EVar "e")))
(DTypeSig false "isBlockBody" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isBlockBody" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "isBlockBody") (EVar "e")))
(DFunDef false "isBlockBody" ((PCon "EMatch" PWild PWild)) (EVar "True"))
(DFunDef false "isBlockBody" ((PCon "EBlock" PWild)) (EVar "True"))
(DFunDef false "isBlockBody" ((PCon "EDo" PWild)) (EVar "True"))
(DFunDef false "isBlockBody" ((PCon "EGuards" PWild)) (EVar "True"))
(DFunDef false "isBlockBody" ((PCon "EIf" PWild (PVar "t") (PVar "e"))) (EBinOp "||" (EApp (EVar "isBlockBody") (EVar "t")) (EApp (EVar "isBlockBody") (EVar "e"))))
(DFunDef false "isBlockBody" (PWild) (EVar "False"))
(DTypeSig false "isUnitLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isUnitLit" ((PCon "ELit" (PCon "LUnit"))) (EVar "True"))
(DFunDef false "isUnitLit" (PWild) (EVar "False"))
(DTypeSig false "breakAtSepBody" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "breakAtSepBody" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "breakAtSepBody") (EVar "e")))
(DFunDef false "breakAtSepBody" ((PCon "EBinOp" (PVar "op") PWild PWild PWild)) (EApp (EVar "not") (EApp (EVar "isContinuationOp") (EVar "op"))))
(DFunDef false "breakAtSepBody" ((PVar "b")) (EApp (EVar "not") (EApp (EVar "isBlockBody") (EVar "b"))))
(DTypeSig false "printExpr" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "printExpr" ((PVar "minPrec") (PVar "e")) (EBlock (DoLet false false (PVar "ep") (EApp (EVar "exprPrec") (EVar "e"))) (DoLet false false (PVar "d") (EApp (EVar "printExprRaw") (EVar "e"))) (DoExpr (EIf (EBinOp "<" (EVar "ep") (EVar "minPrec")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "text") (ELit (LString ")"))))) (EVar "d")))))
(DTypeSig false "printExprRaw" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printExprRaw" ((PCon "ELit" (PVar "l"))) (EApp (EVar "printLit") (EVar "l")))
(DFunDef false "printExprRaw" ((PCon "ENumLit" (PVar "n") PWild PWild)) (EApp (EVar "text") (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "printExprRaw" ((PCon "EVar" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" ((PCon "EMethodRef" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" ((PCon "EDictApp" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precApp")) (EVar "f"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "x")))))
(DFunDef false "printExprRaw" ((PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "map") (EVar "printPatAtom")) (EVar "pats")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " => ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "body")))))
(DFunDef false "printExprRaw" ((PCon "ELet" (PVar "isMut") (PVar "isf") (PVar "pat") (PVar "rhs") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "printELet") (EVar "isMut")) (EVar "isf")) (EVar "pat")) (EVar "rhs")) (EVar "e2")))
(DFunDef false "printExprRaw" ((PCon "ELetGroup" (PVar "bindings") (PVar "body"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "body"))) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "where")))) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EVar "letGroupClauses") (EVar "bindings"))))))))
(DFunDef false "printExprRaw" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "printEIf") (EVar "c")) (EVar "t")) (EVar "e")))
(DFunDef false "printExprRaw" ((PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") PWild)) (EBlock (DoLet false false (PVar "prec") (EApp (EVar "binopPrec") (EVar "op"))) (DoLet false false (PVar "ra") (EApp (EVar "isRightAssoc") (EVar "op"))) (DoLet false false (PVar "sp") (EApp (EApp (EApp (EVar "binopSpace") (EVar "op")) (EVar "l")) (EVar "r"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EIf (EVar "ra") (EBinOp "+" (EVar "prec") (ELit (LInt 1))) (EVar "prec"))) (EVar "l"))) (EApp (EApp (EVar "Cat") (EVar "sp")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EApp (EVar "Cat") (EVar "sp")) (EApp (EApp (EVar "printExpr") (EIf (EVar "ra") (EVar "prec") (EBinOp "+" (EVar "prec") (ELit (LInt 1))))) (EVar "r")))))))))
(DFunDef false "printExprRaw" ((PCon "EUnOp" (PVar "op") (PVar "e") PWild)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EApp (EVar "printExpr") (EVar "precUnary")) (EVar "e"))))
(DFunDef false "printExprRaw" ((PCon "EFieldAccess" (PVar "e") (PVar "f") PWild)) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ".")))) (EApp (EVar "text") (EVar "f")))))
(DFunDef false "printExprRaw" ((PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "braced") (EApp (EApp (EVar "map") (EVar "fieldAssignDoc")) (EVar "fs"))))))
(DFunDef false "printExprRaw" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "{ ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " | ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "fieldAssignDoc")) (EVar "fs")))) (EApp (EVar "text") (ELit (LString " }"))))))))
(DFunDef false "printExprRaw" ((PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " { ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " | ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "fieldAssignDoc")) (EVar "fs")))) (EApp (EVar "text") (ELit (LString " }")))))))))
(DFunDef false "printExprRaw" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EApp (EVar "delimited") (ELit (LString "[|"))) (ELit (LString "|]"))) (EApp (EApp (EVar "map") (EApp (EVar "printExpr") (EVar "precTop"))) (EVar "es"))))
(DFunDef false "printExprRaw" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EApp (EVar "delimited") (ELit (LString "["))) (ELit (LString "]"))) (EApp (EApp (EVar "map") (EApp (EVar "printExpr") (EVar "precTop"))) (EVar "es"))))
(DFunDef false "printExprRaw" ((PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " { ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "mapKvDoc")) (EVar "kvs")))) (EApp (EVar "text") (ELit (LString " }")))))))
(DFunDef false "printExprRaw" ((PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " { ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EApp (EVar "printExpr") (EVar "precTop"))) (EVar "es")))) (EApp (EVar "text") (ELit (LString " }")))))))
(DFunDef false "printExprRaw" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EApp (EVar "delimited") (ELit (LString "("))) (ELit (LString ")"))) (EApp (EApp (EVar "map") (EApp (EVar "printExpr") (EVar "precTop"))) (EVar "es"))))
(DFunDef false "printExprRaw" ((PCon "EIndex" (PVar "e") (PVar "i") PWild)) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "[")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "i"))) (EApp (EVar "text") (ELit (LString "]")))))))
(DFunDef false "printExprRaw" ((PCon "EMatch" (PVar "sc") (PVar "arms"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "match ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "sc"))) (EApp (EVar "printMatchArms") (EVar "arms")))))
(DFunDef false "printExprRaw" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "printGuardArms") (EVar "arms")))
(DFunDef false "printExprRaw" ((PCon "ESection" (PCon "SecBare" (PVar "op")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printExprRaw" ((PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EVar "text") (ELit (LString ")"))))))))
(DFunDef false "printExprRaw" ((PCon "ESection" (PCon "SecLeft" (PVar "e") (PVar "op")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EVar "text") (ELit (LString " _)"))))))))
(DFunDef false "printExprRaw" ((PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "@")))) (EApp (EApp (EVar "printExpr") (EVar "precAtom")) (EVar "e")))))
(DFunDef false "printExprRaw" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "indentBlock") (EApp (EApp (EVar "sepBy") (EVar "Hardline")) (EApp (EApp (EVar "map") (EVar "printDoStmt")) (EVar "stmts")))))
(DFunDef false "printExprRaw" ((PCon "EDo" (PVar "stmts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "do")))) (EApp (EVar "indentBlock") (EApp (EApp (EVar "sepBy") (EVar "Hardline")) (EApp (EApp (EVar "map") (EVar "printDoStmt")) (EVar "stmts"))))))
(DFunDef false "printExprRaw" ((PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "printType") (EVar "t")))))
(DFunDef false "printExprRaw" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))
(DFunDef false "printExprRaw" ((PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EBinOp "+" (EVar "precInfix") (ELit (LInt 1)))) (EVar "l"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " `")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "` ")))) (EApp (EApp (EVar "printExpr") (EBinOp "+" (EVar "precInfix") (ELit (LInt 1)))) (EVar "r")))))))
(DFunDef false "printExprRaw" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "\"")))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (EVar "interpPartDoc")) (EVar "parts")))) (EApp (EVar "text") (ELit (LString "\""))))))
(DFunDef false "printExprRaw" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "[")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "lo"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "incl") (ELit (LString "..=")) (ELit (LString ".."))))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "hi"))) (EApp (EVar "text") (ELit (LString "]"))))))))
(DFunDef false "printExprRaw" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "[|")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "lo"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "incl") (ELit (LString "..=")) (ELit (LString ".."))))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "hi"))) (EApp (EVar "text") (ELit (LString "|]"))))))))
(DFunDef false "printExprRaw" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "incl") PWild)) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ".[")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "lo"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "incl") (ELit (LString "..=")) (ELit (LString ".."))))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "hi"))) (EApp (EVar "text") (ELit (LString "]")))))))))
(DFunDef false "printExprRaw" ((PCon "EVarAt" (PVar "n") PWild)) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" ((PCon "EMethodAt" (PVar "n") PWild PWild PWild)) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" ((PCon "EDictAt" (PVar "n") PWild)) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "printExprRaw") (EVar "e")))
(DTypeSig false "printELet" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc")))))))
(DFunDef false "printELet" ((PVar "isMut") (PCon "True") (PCon "PVar" (PVar "f")) (PVar "rhs") (PVar "e2")) (EBlock (DoLet false false (PVar "argsBody") (EApp (EApp (EVar "unwrapLams") (EListLit)) (EVar "rhs"))) (DoExpr (EMatch (EVar "argsBody") (arm (PTuple (PVar "args") (PVar "body")) () (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "isMut") (ELit (LString "let mut ")) (ELit (LString "let "))))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "f"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "args")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "body"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " in ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e2")))))))))))))
(DFunDef false "printELet" ((PVar "isMut") PWild (PVar "pat") (PVar "e1") (PVar "e2")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "let ")))) (EApp (EApp (EVar "Cat") (EIf (EVar "isMut") (EApp (EVar "text") (ELit (LString "mut "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "pat"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e1"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " in ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e2")))))))))
(DTypeSig false "unwrapLams" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "unwrapLams" ((PVar "acc") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "unwrapLams") (EVar "acc")) (EVar "e")))
(DFunDef false "unwrapLams" ((PVar "acc") (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "unwrapLams") (EBinOp "++" (EVar "acc") (EVar "pats"))) (EVar "body")))
(DFunDef false "unwrapLams" ((PVar "acc") (PVar "body")) (ETuple (EVar "acc") (EVar "body")))
(DTypeSig false "letGroupClauses" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Doc")))
(DFunDef false "letGroupClauses" ((PVar "bindings")) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (EVar "letBindClauses")) (EVar "bindings"))))
(DTypeSig false "letBindClauses" (TyFun (TyCon "LetBind") (TyCon "Doc")))
(DFunDef false "letBindClauses" ((PCon "LetBind" (PVar "name") (PVar "clauses"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (EApp (EVar "letGroupClause") (EVar "name"))) (EVar "clauses"))))
(DTypeSig false "letGroupClause" (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyCon "Doc"))))
(DFunDef false "letGroupClause" ((PVar "name") (PCon "FunClause" (PVar "pats") (PVar "rhs"))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))) (EApp (EVar "letGroupClauseRhs") (EVar "rhs"))))))
(DTypeSig false "letGroupClauseRhs" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "letGroupClauseRhs" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "printGuardArms") (EVar "arms")))
(DFunDef false "letGroupClauseRhs" ((PVar "rhs")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "rhs"))))
(DTypeSig false "printEIf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc")))))
(DFunDef false "printEIf" ((PVar "c") (PVar "t") (PVar "e")) (EIf (EBinOp "||" (EApp (EVar "isBlockBody") (EVar "t")) (EApp (EVar "isBlockBody") (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "if ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "ifBranch") (ELit (LString "then"))) (EVar "t"))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "ifBranch") (ELit (LString "else"))) (EVar "e"))))))) (EIf (EVar "otherwise") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "if ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " then ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "t"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " else ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "printIfBody" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc")))))
(DFunDef false "printIfBody" ((PVar "c") (PVar "t") (PVar "e")) (EIf (EBinOp "||" (EApp (EVar "isBlockBody") (EVar "t")) (EApp (EVar "isBlockBody") (EVar "e"))) (EApp (EApp (EApp (EVar "printEIf") (EVar "c")) (EVar "t")) (EVar "e")) (EIf (EVar "otherwise") (EApp (EVar "group") (EApp (EApp (EApp (EVar "ifRhsBody") (EVar "c")) (EVar "t")) (EApp (EApp (EVar "ifRhsElsePart") (EApp (EVar "isUnitLit") (EVar "e"))) (EVar "e")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isDoMatchFnBody" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isDoMatchFnBody" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "isDoMatchFnBody") (EVar "e")))
(DFunDef false "isDoMatchFnBody" ((PCon "EDo" PWild)) (EVar "True"))
(DFunDef false "isDoMatchFnBody" ((PCon "EMatch" PWild PWild)) (EVar "True"))
(DFunDef false "isDoMatchFnBody" (PWild) (EVar "False"))
(DTypeSig false "ifBranch" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "ifBranch" ((PVar "kw") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "kw"))) (EApp (EVar "printExprBody") (EApp (EVar "EBlock") (EVar "stmts")))))
(DFunDef false "ifBranch" ((PVar "kw") (PVar "b")) (EIf (EApp (EVar "isDoMatchFnBody") (EVar "b")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "kw"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printExprBody") (EVar "b")))) (EIf (EApp (EVar "isBlockBody") (EVar "b")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "kw"))) (EApp (EVar "indentBlock") (EApp (EVar "printExprBody") (EVar "b")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "kw"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "b")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "printExprBody" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printExprBody" ((PVar "e")) (EApp (EApp (EVar "printExprBodyW") (EVar "True")) (EVar "e")))
(DTypeSig false "printExprBodyW" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "printExprBodyW" ((PVar "wrapApp") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "printExprBodyW") (EVar "wrapApp")) (EVar "e")))
(DFunDef false "printExprBodyW" (PWild (PCon "EMatch" (PVar "sc") (PVar "arms"))) (EApp (EVar "printExprRaw") (EApp (EApp (EVar "EMatch") (EVar "sc")) (EVar "arms"))))
(DFunDef false "printExprBodyW" (PWild (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "printExprRaw") (EApp (EVar "EBlock") (EVar "stmts"))))
(DFunDef false "printExprBodyW" (PWild (PCon "EDo" (PVar "stmts"))) (EApp (EVar "printExprRaw") (EApp (EVar "EDo") (EVar "stmts"))))
(DFunDef false "printExprBodyW" ((PVar "wrapApp") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "rf"))) (EIf (EApp (EVar "isContinuationOp") (EVar "op")) (EApp (EApp (EVar "printChain") (EVar "op")) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "rf"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "rf"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "printExprBodyW" ((PCon "True") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "printAppSpine") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))))
(DFunDef false "printExprBodyW" ((PVar "wrapApp") (PCon "EIf" (PVar "c") (PVar "t") (PVar "els"))) (EIf (EApp (EVar "isUnitLit") (EVar "els")) (EBlock (DoLet false false (PVar "thenPart") (EApp (EVar "elseLessThen") (EVar "t"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "if ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " then")))) (EVar "thenPart")))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "printIfBody") (EVar "c")) (EVar "t")) (EVar "els")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "printExprBodyW" (PWild (PVar "e")) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))
(DTypeSig false "elseLessThen" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "elseLessThen" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "elseLessThen") (EVar "e")))
(DFunDef false "elseLessThen" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "printExprBody") (EApp (EVar "EBlock") (EVar "stmts"))))
(DFunDef false "elseLessThen" ((PVar "t")) (EIf (EApp (EVar "isBlockBody") (EVar "t")) (EApp (EVar "indentBlock") (EApp (EVar "printExprBody") (EVar "t"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "t"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "printIfRhs" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Doc"))))
(DFunDef false "printIfRhs" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "printIfRhs") (EVar "e")))
(DFunDef false "printIfRhs" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "els"))) (EBlock (DoLet false false (PVar "isUnit") (EApp (EVar "isUnitLit") (EVar "els"))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isBlockBody") (EVar "t"))) (EBinOp "||" (EVar "isUnit") (EApp (EVar "not") (EApp (EVar "isBlockBody") (EVar "els"))))) (EApp (EVar "Some") (EApp (EVar "group") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EApp (EVar "ifRhsBody") (EVar "c")) (EVar "t")) (EApp (EApp (EVar "ifRhsElsePart") (EVar "isUnit")) (EVar "els"))))))) (EVar "None")))))
(DFunDef false "printIfRhs" (PWild) (EVar "None"))
(DTypeSig false "ifRhsBody" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Doc") (TyCon "Doc")))))
(DFunDef false "ifRhsBody" ((PVar "c") (PVar "t") (PVar "elsePart")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "if ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " then")))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "t"))))) (EVar "elsePart"))))))
(DTypeSig false "ifRhsElsePart" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "ifRhsElsePart" ((PCon "True") PWild) (EVar "Nil"))
(DFunDef false "ifRhsElsePart" ((PCon "False") (PCon "ELoc" PWild (PVar "els"))) (EApp (EApp (EVar "ifRhsElsePart") (EVar "False")) (EVar "els")))
(DFunDef false "ifRhsElsePart" ((PCon "False") (PCon "EIf" (PVar "c2") (PVar "t2") (PVar "els2"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isBlockBody") (EVar "t2"))) (EBinOp "||" (EApp (EVar "isUnitLit") (EVar "els2")) (EApp (EVar "not") (EApp (EVar "isBlockBody") (EVar "els2"))))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "else if ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "c2"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " then")))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "t2"))))) (EApp (EApp (EVar "ifRhsElsePart") (EApp (EVar "isUnitLit") (EVar "els2"))) (EVar "els2"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "ifRhsElsePart" ((PCon "False") (PVar "els")) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "else")))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "els")))))))
(DTypeSig false "printChain" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "printChain" ((PVar "op") (PVar "e")) (EBlock (DoLet false false (PVar "prec") (EApp (EVar "binopPrec") (EVar "op"))) (DoLet false false (PVar "headRights") (EApp (EApp (EApp (EVar "collectChain") (EVar "op")) (EListLit)) (EVar "e"))) (DoExpr (EMatch (EVar "headRights") (arm (PTuple (PVar "head") (PVar "rights")) () (EBlock (DoLet false false (PVar "tail") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "or")) (EApp (EApp (EVar "chainItem") (EVar "prec")) (EVar "or")))) (EVar "rights")))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "prec")) (EVar "head"))) (EVar "tail")))))))))))
(DTypeSig false "chainItem" (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "String") (TyCon "Expr")) (TyCon "Doc"))))
(DFunDef false "chainItem" ((PVar "prec") (PTuple (PVar "o") (PVar "r"))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "o"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "printExpr") (EBinOp "+" (EVar "prec") (ELit (LInt 1)))) (EVar "r"))))))
(DTypeSig false "collectChain" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr"))))))))
(DFunDef false "collectChain" ((PVar "op") (PVar "acc") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EApp (EVar "collectChain") (EVar "op")) (EVar "acc")) (EVar "e")))
(DFunDef false "collectChain" ((PVar "op") (PVar "acc") (PCon "EBinOp" (PVar "op2") (PVar "l") (PVar "r") (PVar "rf"))) (EIf (EBinOp "==" (EVar "op2") (EVar "op")) (EApp (EApp (EApp (EVar "collectChain") (EVar "op")) (EBinOp "::" (ETuple (EVar "op2") (EVar "r")) (EVar "acc"))) (EVar "l")) (EIf (EVar "otherwise") (ETuple (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op2")) (EVar "l")) (EVar "r")) (EVar "rf")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "collectChain" (PWild (PVar "acc") (PVar "head")) (ETuple (EVar "head") (EVar "acc")))
(DTypeSig true "declChainLen" (TyFun (TyCon "Decl") (TyCon "Int")))
(DFunDef false "declChainLen" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "declChainLen") (EVar "inner")))
(DFunDef false "declChainLen" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "chainLenBody") (EVar "body")))
(DFunDef false "declChainLen" (PWild) (ELit (LInt 0)))
(DTypeSig false "chainLenBody" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "chainLenBody" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "chainLenBody") (EVar "e")))
(DFunDef false "chainLenBody" ((PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "rf"))) (EIf (EApp (EVar "isContinuationOp") (EVar "op")) (EMatch (EApp (EApp (EApp (EVar "collectChain") (EVar "op")) (EListLit)) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "rf"))) (arm (PTuple PWild (PVar "rights")) () (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "listLen") (EVar "rights"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "chainLenBody" (PWild) (ELit (LInt 0)))
(DTypeSig false "opCommentDoc" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Doc")))
(DFunDef false "opCommentDoc" ((PCon "None")) (EVar "Nil"))
(DFunDef false "opCommentDoc" ((PCon "Some" (PVar "t"))) (EApp (EVar "LineComment") (EVar "t")))
(DTypeSig false "chainItemCommented" (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "String") (TyCon "Expr")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Doc")))))
(DFunDef false "chainItemCommented" ((PVar "prec") (PTuple (PVar "o") (PVar "r")) (PVar "cmt")) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "o"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EBinOp "+" (EVar "prec") (ELit (LInt 1)))) (EVar "r"))) (EApp (EVar "opCommentDoc") (EVar "cmt")))))))
(DTypeSig false "chainTailCommented" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc")))))
(DFunDef false "chainTailCommented" (PWild (PList) PWild) (EVar "Nil"))
(DFunDef false "chainTailCommented" ((PVar "prec") (PCons (PVar "r") (PVar "rs")) (PCons (PVar "c") (PVar "cs"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EApp (EVar "chainItemCommented") (EVar "prec")) (EVar "r")) (EVar "c"))) (EApp (EApp (EApp (EVar "chainTailCommented") (EVar "prec")) (EVar "rs")) (EVar "cs"))))
(DFunDef false "chainTailCommented" ((PVar "prec") (PCons (PVar "r") (PVar "rs")) (PList)) (EApp (EApp (EVar "Cat") (EApp (EApp (EApp (EVar "chainItemCommented") (EVar "prec")) (EVar "r")) (EVar "None"))) (EApp (EApp (EApp (EVar "chainTailCommented") (EVar "prec")) (EVar "rs")) (EListLit))))
(DTypeSig false "printChainCommentedRhs" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc")))))
(DFunDef false "printChainCommentedRhs" ((PVar "op") (PVar "e") (PVar "comments")) (EBlock (DoLet false false (PVar "prec") (EApp (EVar "binopPrec") (EVar "op"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "collectChain") (EVar "op")) (EListLit)) (EVar "e")) (arm (PTuple (PVar "head") (PVar "rights")) () (EBlock (DoLet false false (PVar "headCmt") (EMatch (EVar "comments") (arm (PCons (PVar "h") PWild) () (EVar "h")) (arm (PList) () (EVar "None")))) (DoLet false false (PVar "restCmts") (EMatch (EVar "comments") (arm (PCons PWild (PVar "t")) () (EVar "t")) (arm (PList) () (EListLit)))) (DoLet false false (PVar "body") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "prec")) (EVar "head"))) (EApp (EApp (EVar "Cat") (EApp (EVar "opCommentDoc") (EVar "headCmt"))) (EApp (EApp (EApp (EVar "chainTailCommented") (EVar "prec")) (EVar "rights")) (EVar "restCmts"))))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EVar "body")))))))))))
(DTypeSig true "printDeclChainCommented" (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc"))))
(DFunDef false "printDeclChainCommented" ((PCon "DAttrib" (PVar "attrs") (PVar "inner")) (PVar "comments")) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (EVar "attrDoc")) (EVar "attrs")))) (EApp (EApp (EVar "printDeclChainCommented") (EVar "inner")) (EVar "comments"))))
(DFunDef false "printDeclChainCommented" ((PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "pats") (PVar "body")) (PVar "comments")) (EBlock (DoLet false false (PVar "header") (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))))) (DoExpr (EApp (EApp (EVar "Cat") (EVar "header")) (EApp (EApp (EVar "printDefChainRhs") (EVar "body")) (EVar "comments"))))))
(DFunDef false "printDeclChainCommented" ((PVar "d") PWild) (EApp (EVar "printDecl") (EVar "d")))
(DTypeSig false "printDefChainRhs" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc"))))
(DFunDef false "printDefChainRhs" ((PCon "ELoc" PWild (PVar "e")) (PVar "comments")) (EApp (EApp (EVar "printDefChainRhs") (EVar "e")) (EVar "comments")))
(DFunDef false "printDefChainRhs" ((PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "rf")) (PVar "comments")) (EIf (EApp (EVar "isContinuationOp") (EVar "op")) (EApp (EApp (EApp (EVar "printChainCommentedRhs") (EVar "op")) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "rf"))) (EVar "comments")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "printDefChainRhs" ((PVar "body") PWild) (EApp (EVar "printDefRhs") (EVar "body")))
(DTypeSig true "declBlockLen" (TyFun (TyCon "Decl") (TyCon "Int")))
(DFunDef false "declBlockLen" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "declBlockLen") (EVar "inner")))
(DFunDef false "declBlockLen" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "blockLenBody") (EVar "body")))
(DFunDef false "declBlockLen" (PWild) (ELit (LInt 0)))
(DTypeSig false "blockLenBody" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "blockLenBody" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "blockLenBody") (EVar "e")))
(DFunDef false "blockLenBody" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "listLen") (EVar "stmts")))
(DFunDef false "blockLenBody" ((PCon "EDo" (PVar "stmts"))) (EApp (EVar "listLen") (EVar "stmts")))
(DFunDef false "blockLenBody" (PWild) (ELit (LInt 0)))
(DTypeSig false "headOpt" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headOpt" ((PCons (PVar "x") PWild)) (EVar "x"))
(DFunDef false "headOpt" ((PList)) (EVar "None"))
(DTypeSig false "tailOpt" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "tailOpt" ((PCons PWild (PVar "t"))) (EVar "t"))
(DFunDef false "tailOpt" ((PList)) (EListLit))
(DTypeSig false "stmtsCommented" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc"))))
(DFunDef false "stmtsCommented" ((PList) PWild) (EVar "Nil"))
(DFunDef false "stmtsCommented" ((PList (PVar "st")) (PVar "cs")) (EApp (EApp (EVar "Cat") (EApp (EVar "printDoStmt") (EVar "st"))) (EApp (EVar "opCommentDoc") (EApp (EVar "headOpt") (EVar "cs")))))
(DFunDef false "stmtsCommented" ((PCons (PVar "st") (PVar "rest")) (PVar "cs")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "Cat") (EApp (EVar "printDoStmt") (EVar "st"))) (EApp (EVar "opCommentDoc") (EApp (EVar "headOpt") (EVar "cs"))))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "stmtsCommented") (EVar "rest")) (EApp (EVar "tailOpt") (EVar "cs"))))))
(DTypeSig false "printBlockCommentedRhs" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc"))))
(DFunDef false "printBlockCommentedRhs" ((PCon "ELoc" PWild (PVar "e")) (PVar "comments")) (EApp (EApp (EVar "printBlockCommentedRhs") (EVar "e")) (EVar "comments")))
(DFunDef false "printBlockCommentedRhs" ((PCon "EBlock" (PVar "stmts")) (PVar "comments")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "indentBlock") (EApp (EApp (EVar "stmtsCommented") (EVar "stmts")) (EVar "comments")))))
(DFunDef false "printBlockCommentedRhs" ((PCon "EDo" (PVar "stmts")) (PVar "comments")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "do")))) (EApp (EVar "indentBlock") (EApp (EApp (EVar "stmtsCommented") (EVar "stmts")) (EVar "comments"))))))
(DFunDef false "printBlockCommentedRhs" ((PVar "body") PWild) (EApp (EVar "printDefRhs") (EVar "body")))
(DTypeSig true "printDeclBlockCommented" (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc"))))
(DFunDef false "printDeclBlockCommented" ((PCon "DAttrib" (PVar "attrs") (PVar "inner")) (PVar "comments")) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (EVar "attrDoc")) (EVar "attrs")))) (EApp (EApp (EVar "printDeclBlockCommented") (EVar "inner")) (EVar "comments"))))
(DFunDef false "printDeclBlockCommented" ((PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "pats") (PVar "body")) (PVar "comments")) (EBlock (DoLet false false (PVar "header") (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))))) (DoExpr (EApp (EApp (EVar "Cat") (EVar "header")) (EApp (EApp (EVar "printBlockCommentedRhs") (EVar "body")) (EVar "comments"))))))
(DFunDef false "printDeclBlockCommented" ((PVar "d") PWild) (EApp (EVar "printDecl") (EVar "d")))
(DTypeSig false "printAppSpine" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printAppSpine" ((PVar "e")) (EBlock (DoLet false false (PVar "headArgs") (EApp (EApp (EVar "collectApp") (EListLit)) (EVar "e"))) (DoExpr (EMatch (EVar "headArgs") (arm (PTuple (PVar "head") (PList)) () (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (arm (PTuple (PVar "head") (PList (PVar "arg"))) () (EIf (EApp (EVar "isBreakableArg") (EVar "arg")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precApp")) (EVar "head"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "breakableArg") (EVar "arg")))) (EApp (EVar "group") (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precApp")) (EVar "head"))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "arg")))))))) (arm (PTuple (PVar "head") (PVar "args")) () (EBlock (DoLet false false (PVar "tail") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "spineArg") (EVar "a"))))) (EVar "args")))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precApp")) (EVar "head"))) (EVar "tail")))))))))))
(DTypeSig false "spineArg" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "spineArg" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "spineArg") (EVar "e")))
(DFunDef false "spineArg" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printAppSpine") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "spineArg" ((PVar "e")) (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "e")))
(DTypeSig false "isBreakableArg" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isBreakableArg" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "isBreakableArg") (EVar "e")))
(DFunDef false "isBreakableArg" ((PCon "ELam" PWild PWild)) (EVar "True"))
(DFunDef false "isBreakableArg" ((PCon "EApp" (PVar "f") (PVar "x"))) (EVar "True"))
(DFunDef false "isBreakableArg" (PWild) (EVar "False"))
(DTypeSig false "breakableArg" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "breakableArg" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "breakableArg") (EVar "e")))
(DFunDef false "breakableArg" ((PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "map") (EVar "printPatAtom")) (EVar "pats")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =>")))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "printExprBody") (EVar "body"))))) (EApp (EVar "text") (ELit (LString ")")))))))))
(DFunDef false "breakableArg" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printAppSpine") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "breakableArg" ((PVar "e")) (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "e")))
(DTypeSig false "collectApp" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "collectApp" ((PVar "acc") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "collectApp") (EBinOp "::" (EVar "x") (EVar "acc"))) (EVar "f")))
(DFunDef false "collectApp" ((PVar "acc") (PVar "head")) (ETuple (EVar "head") (EVar "acc")))
(DTypeSig false "printMatchArms" (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Doc")))
(DFunDef false "printMatchArms" ((PVar "arms")) (EApp (EVar "indentBlock") (EApp (EApp (EVar "sepBy") (EVar "Hardline")) (EApp (EApp (EVar "map") (EVar "matchArmDoc")) (EVar "arms")))))
(DTypeSig false "matchArmDoc" (TyFun (TyCon "Arm") (TyCon "Doc")))
(DFunDef false "matchArmDoc" ((PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPatArm") (EVar "pat"))) (EApp (EApp (EVar "Cat") (EApp (EVar "matchGuardsDoc") (EVar "guards"))) (EApp (EVar "matchBodyDoc") (EVar "body")))))
(DTypeSig false "matchGuardsDoc" (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "Doc")))
(DFunDef false "matchGuardsDoc" ((PList)) (EVar "Nil"))
(DFunDef false "matchGuardsDoc" ((PVar "guards")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " if ")))) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "guardDoc")) (EVar "guards")))))
(DTypeSig false "matchBodyDoc" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "matchBodyDoc" ((PVar "body")) (EMatch (EApp (EVar "printIfRhs") (EVar "body")) (arm (PCon "Some" (PVar "g")) () (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =>")))) (EVar "g"))) (arm (PCon "None") () (EApp (EVar "matchBodyNoIf") (EVar "body")))))
(DTypeSig false "matchBodyNoIf" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "matchBodyNoIf" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "matchBodyNoIf") (EVar "e")))
(DFunDef false "matchBodyNoIf" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =>")))) (EApp (EApp (EVar "printExprBodyW") (EVar "False")) (EApp (EVar "EBlock") (EVar "stmts")))))
(DFunDef false "matchBodyNoIf" ((PVar "body")) (EIf (EApp (EVar "breakAtSepBody") (EVar "body")) (EApp (EApp (EVar "hangAtSep") (ELit (LString " =>"))) (EApp (EApp (EVar "printExprBodyW") (EVar "False")) (EVar "body"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " => ")))) (EApp (EApp (EVar "printExprBodyW") (EVar "False")) (EVar "body"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "guardDoc" (TyFun (TyCon "Guard") (TyCon "Doc")))
(DFunDef false "guardDoc" ((PCon "GBool" (PVar "g"))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "g")))
(DFunDef false "guardDoc" ((PCon "GBind" (PVar "gp") (PVar "g"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "gp"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " <- ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "g")))))
(DTypeSig false "printGuardArms" (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyCon "Doc")))
(DFunDef false "printGuardArms" ((PVar "arms")) (EApp (EVar "indentBlock") (EApp (EApp (EVar "sepBy") (EVar "Hardline")) (EApp (EApp (EVar "map") (EVar "guardArmDoc")) (EVar "arms")))))
(DTypeSig false "guardArmDoc" (TyFun (TyCon "GuardArm") (TyCon "Doc")))
(DFunDef false "guardArmDoc" ((PCon "GuardArm" (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PVar "hd") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "| ")))) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "guardDoc")) (EVar "guards"))))) (DoExpr (EApp (EApp (EVar "Cat") (EVar "hd")) (EApp (EVar "guardArmBodyDoc") (EVar "body"))))))
(DTypeSig false "guardArmBodyDoc" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "guardArmBodyDoc" ((PVar "body")) (EMatch (EApp (EVar "printIfRhs") (EVar "body")) (arm (PCon "Some" (PVar "g")) () (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EVar "g"))) (arm (PCon "None") () (EApp (EVar "guardArmBodyNoIf") (EVar "body")))))
(DTypeSig false "guardArmBodyNoIf" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "guardArmBodyNoIf" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EApp (EVar "printExprBodyW") (EVar "False")) (EApp (EVar "EBlock") (EVar "stmts")))))
(DFunDef false "guardArmBodyNoIf" ((PVar "body")) (EIf (EApp (EVar "breakAtSepBody") (EVar "body")) (EApp (EApp (EVar "hangAtSep") (ELit (LString " ="))) (EApp (EApp (EVar "printExprBodyW") (EVar "False")) (EVar "body"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "printExprBodyW") (EVar "False")) (EVar "body"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "doLetRhs" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "doLetRhs" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "doLetRhs") (EVar "e")))
(DFunDef false "doLetRhs" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "els"))) (EIf (EApp (EVar "not") (EApp (EVar "isUnitLit") (EVar "els"))) (EApp (EApp (EApp (EVar "printIfBody") (EVar "c")) (EVar "t")) (EVar "els")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "doLetRhs" ((PVar "e")) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))
(DTypeSig false "printDoStmt" (TyFun (TyCon "DoStmt") (TyCon "Doc")))
(DFunDef false "printDoStmt" ((PCon "DoBind" (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "pat"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " <- ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))))
(DFunDef false "printDoStmt" ((PCon "DoExpr" (PVar "e"))) (EMatch (EVar "e") (arm (PCon "EIf" (PVar "c") (PVar "t") (PVar "els")) () (EIf (EApp (EVar "isUnitLit") (EVar "els")) (EBlock (DoLet false false (PVar "thenPart") (EApp (EVar "elseLessThen") (EVar "t"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "if ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " then")))) (EVar "thenPart")))))) (EApp (EVar "printExprBody") (EVar "e")))) (arm PWild () (EApp (EVar "printExprBody") (EVar "e")))))
(DFunDef false "printDoStmt" ((PCon "DoLet" (PVar "isMut") PWild (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "let ")))) (EApp (EApp (EVar "Cat") (EIf (EVar "isMut") (EApp (EVar "text") (ELit (LString "mut "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "pat"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "doLetRhs") (EVar "e")))))))
(DFunDef false "printDoStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))))
(DFunDef false "printDoStmt" ((PCon "DoFieldAssign" (PVar "x") (PVar "fields") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ".")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "fields")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))))))
(DTypeSig false "interpPartDoc" (TyFun (TyCon "InterpPart") (TyCon "Doc")))
(DFunDef false "interpPartDoc" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "text") (EApp (EVar "stringEscaped") (EVar "s"))))
(DFunDef false "interpPartDoc" ((PCon "InterpExpr" (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "\\{")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EVar "text") (ELit (LString "}"))))))
(DTypeSig false "fieldAssignDoc" (TyFun (TyCon "FieldAssign") (TyCon "Doc")))
(DFunDef false "fieldAssignDoc" ((PCon "FieldAssign" (PVar "k") (PVar "v"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "k"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "v")))))
(DTypeSig false "mapKvDoc" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyCon "Doc")))
(DFunDef false "mapKvDoc" ((PTuple (PVar "k") (PVar "v"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "k"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " => ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "v")))))
(DTypeSig false "stringEscaped" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stringEscaped" ((PVar "s")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "escEChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0)))))
(DTypeSig false "escEChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "escEChars" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "escSOne") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EVar "escEChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "printDefRhs" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printDefRhs" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "printDefRhs") (EVar "e")))
(DFunDef false "printDefRhs" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "printGuardArms") (EVar "arms")))
(DFunDef false "printDefRhs" ((PCon "ELetGroup" (PVar "binds") (PVar "inner"))) (EIf (EApp (EVar "isGuardsBody") (EVar "inner")) (EApp (EVar "printExprBody") (EApp (EApp (EVar "ELetGroup") (EVar "binds")) (EVar "inner"))) (EIf (EVar "otherwise") (EApp (EVar "printDefRhsGeneral") (EApp (EApp (EVar "ELetGroup") (EVar "binds")) (EVar "inner"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "printDefRhs" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "printExprBody") (EApp (EVar "EBlock") (EVar "stmts")))))
(DFunDef false "printDefRhs" ((PVar "body")) (EApp (EVar "printDefRhsGeneral") (EVar "body")))
(DTypeSig false "isGuardsBody" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isGuardsBody" ((PCon "EGuards" PWild)) (EVar "True"))
(DFunDef false "isGuardsBody" (PWild) (EVar "False"))
(DTypeSig false "printDefRhsGeneral" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printDefRhsGeneral" ((PVar "body")) (EMatch (EApp (EVar "printIfRhs") (EVar "body")) (arm (PCon "Some" (PVar "g")) () (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EVar "g"))) (arm (PCon "None") () (EMatch (EVar "body") (arm (PCon "EMatch" (PVar "sc") (PVar "arms")) () (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "printExprBody") (EApp (EApp (EVar "EMatch") (EVar "sc")) (EVar "arms"))))) (arm (PCon "EDo" (PVar "stmts")) () (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "printExprBody") (EApp (EVar "EDo") (EVar "stmts"))))) (arm (PCon "EApp" (PVar "f") (PVar "x")) () (EIf (EApp (EVar "appHasSelfIndentingArg") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EApp (EVar "bodyBreakAtEq") (EApp (EVar "printAppSpine") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (EApp (EApp (EVar "hangAlwaysAtSep") (ELit (LString " ="))) (EApp (EVar "printAppSpine") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))))) (arm (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "rf")) () (EIf (EApp (EVar "isContinuationOp") (EVar "op")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "printExprBody") (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "rf")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "group") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EApp (EVar "printBinOpTrailing") (EVar "op")) (EVar "l")) (EVar "r")))))))) (arm PWild () (EIf (EApp (EVar "isBlockBody") (EVar "body")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "indentBlock") (EApp (EVar "printExprBody") (EVar "body")))) (EApp (EVar "bodyBreakAtEq") (EApp (EVar "printExprBody") (EVar "body")))))))))
(DTypeSig false "bodyBreakAtEq" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "bodyBreakAtEq" ((PVar "bodyDoc")) (EApp (EApp (EVar "hangAtSep") (ELit (LString " ="))) (EVar "bodyDoc")))
(DTypeSig false "hangAtSep" (TyFun (TyCon "String") (TyFun (TyCon "Doc") (TyCon "Doc"))))
(DFunDef false "hangAtSep" ((PVar "sep") (PVar "bodyDoc")) (EApp (EVar "FlatGroup") (EApp (EApp (EVar "FlatAlt") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "sep"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EVar "bodyDoc")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "sep"))) (EApp (EVar "group") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EVar "bodyDoc"))))))))
(DTypeSig false "hangAlwaysAtSep" (TyFun (TyCon "String") (TyFun (TyCon "Doc") (TyCon "Doc"))))
(DFunDef false "hangAlwaysAtSep" ((PVar "sep") (PVar "bodyDoc")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "sep"))) (EApp (EVar "group") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EVar "bodyDoc"))))))
(DTypeSig false "isSelfIndentingArg" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isSelfIndentingArg" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "isSelfIndentingArg") (EVar "e")))
(DFunDef false "isSelfIndentingArg" ((PCon "ELam" PWild PWild)) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EBlock" PWild)) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EDo" PWild)) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EMatch" PWild PWild)) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EIf" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "ERecordCreate" PWild PWild)) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "ERecordUpdate" PWild PWild)) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EVariantUpdate" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EListLit" (PCons PWild PWild))) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EArrayLit" (PCons PWild PWild))) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "ETuple" (PCons PWild PWild))) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EMapLit" PWild (PCons PWild PWild))) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "ESetLit" PWild (PCons PWild PWild))) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "appHasSelfIndentingArg") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))))
(DFunDef false "isSelfIndentingArg" (PWild) (EVar "False"))
(DTypeSig false "appHasSelfIndentingArg" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "appHasSelfIndentingArg" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appHasSelfIndentingArg") (EVar "e")))
(DFunDef false "appHasSelfIndentingArg" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "||" (EApp (EVar "isSelfIndentingArg") (EVar "x")) (EApp (EVar "appHasSelfIndentingArg") (EVar "f"))))
(DFunDef false "appHasSelfIndentingArg" (PWild) (EVar "False"))
(DTypeSig false "printBinOpTrailing" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc")))))
(DFunDef false "printBinOpTrailing" ((PVar "op") (PVar "l") (PVar "r")) (EBlock (DoLet false false (PVar "prec") (EApp (EVar "binopPrec") (EVar "op"))) (DoLet false false (PVar "ra") (EApp (EVar "isRightAssoc") (EVar "op"))) (DoLet false false (PVar "lp") (EIf (EVar "ra") (EBinOp "+" (EVar "prec") (ELit (LInt 1))) (EVar "prec"))) (DoLet false false (PVar "rp") (EIf (EVar "ra") (EVar "prec") (EBinOp "+" (EVar "prec") (ELit (LInt 1))))) (DoLet false false (PVar "afterOp") (EIf (EApp (EApp (EApp (EVar "consTight") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "Softline") (EVar "Line"))) (DoExpr (EApp (EVar "group") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printOperand") (EVar "lp")) (EVar "l"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EApp (EVar "binopSpace") (EVar "op")) (EVar "l")) (EVar "r"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EApp (EVar "Cat") (EVar "afterOp")) (EApp (EApp (EVar "printOperand") (EVar "rp")) (EVar "r")))))))))))
(DTypeSig false "printOperand" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "printOperand" ((PVar "prec") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "printOperand") (EVar "prec")) (EVar "e")))
(DFunDef false "printOperand" ((PVar "prec") (PCon "EApp" (PVar "f") (PVar "x"))) (EIf (EBinOp "<" (EApp (EVar "exprPrec") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EVar "prec")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printAppSpine") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (EApp (EVar "text") (ELit (LString ")"))))) (EApp (EVar "printAppSpine") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))))
(DFunDef false "printOperand" ((PVar "prec") (PVar "e")) (EApp (EApp (EVar "printExpr") (EVar "prec")) (EVar "e")))
(DTypeSig false "printUsePath" (TyFun (TyCon "UsePath") (TyCon "Doc")))
(DFunDef false "printUsePath" ((PCon "UseName" (PVar "names"))) (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "names"))))
(DFunDef false "printUsePath" ((PCon "UseGroup" (PVar "names") (PVar "members"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "names")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ".")))) (EApp (EApp (EApp (EVar "delimitedG") (ELit (LString "{"))) (ELit (LString "}"))) (EApp (EApp (EVar "map") (EVar "useMemberDoc")) (EVar "members"))))))
(DFunDef false "printUsePath" ((PCon "UseWild" (PVar "names"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "names")))) (EApp (EVar "text") (ELit (LString ".*")))))
(DFunDef false "printUsePath" ((PCon "UseAlias" (PVar "names") (PVar "alias"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "names")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " as ")))) (EApp (EVar "text") (EVar "alias")))))
(DTypeSig false "useMemberDoc" (TyFun (TyCon "UseMember") (TyCon "Doc")))
(DFunDef false "useMemberDoc" ((PCon "UseMember" (PVar "n") (PVar "allCtors") PWild (PVar "alias"))) (EBlock (DoLet false false (PVar "base") (EIf (EVar "allCtors") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "text") (ELit (LString "(..)")))) (EApp (EVar "text") (EVar "n")))) (DoExpr (EMatch (EVar "alias") (arm (PCon "Some" (PVar "a")) () (EApp (EApp (EVar "Cat") (EVar "base")) (EApp (EVar "text") (EBinOp "++" (EBinOp "++" (ELit (LString " as ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))))) (arm (PCon "None") () (EVar "base"))))))
(DTypeSig false "printVariant" (TyFun (TyCon "Variant") (TyCon "Doc")))
(DFunDef false "printVariant" ((PCon "Variant" (PVar "name") (PCon "ConPos" (PVar "tys")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "t")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "t"))))) (EVar "tys")))))
(DFunDef false "printVariant" ((PCon "Variant" (PVar "name") (PCon "ConNamed" (PVar "fields") (PVar "nameOmitted")))) (EBlock (DoLet false false (PVar "sep") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ",")))) (EVar "Line"))) (DoLet false false (PVar "trailing") (EApp (EApp (EVar "FlatAlt") (EApp (EVar "text") (ELit (LString ",")))) (EVar "Nil"))) (DoLet false false (PVar "namePart") (EIf (EVar "nameOmitted") (EVar "Nil") (EApp (EVar "text") (EVar "name")))) (DoLet false false (PVar "braceOpen") (EIf (EVar "nameOmitted") (EApp (EVar "text") (ELit (LString "{"))) (EApp (EVar "text") (ELit (LString " {"))))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EVar "namePart")) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "braceOpen")) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EVar "sep")) (EApp (EApp (EVar "map") (EVar "fieldTyDoc")) (EVar "fields")))) (EVar "trailing"))))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "text") (ELit (LString "}"))))))))))))
(DTypeSig false "fieldTyDoc" (TyFun (TyCon "Field") (TyCon "Doc")))
(DFunDef false "fieldTyDoc" ((PCon "Field" (PVar "fn") (PVar "ft"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "fn"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "printType") (EVar "ft")))))
(DTypeSig true "printNamedFieldData" (TyFun (TyCon "DataVis") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Doc")))))))
(DFunDef false "printNamedFieldData" ((PVar "vis") (PVar "n") (PVar "params") (PList (PCon "Variant" (PVar "cname") (PCon "ConNamed" (PVar "fields") (PVar "nameOmitted")))) (PVar "derives")) (EBlock (DoLet false false (PVar "eqPart") (EIf (EVar "nameOmitted") (EApp (EVar "text") (ELit (LString " ="))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "text") (EVar "cname"))))) (DoLet false false (PVar "head") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "data ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "p"))))) (EVar "params")))) (EVar "eqPart"))))) (DoLet false false (PVar "body") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " {")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "Nest") (ELit (LInt 4))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "f")) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EVar "fieldTyDoc") (EVar "f"))) (EApp (EVar "text") (ELit (LString ","))))))) (EVar "fields"))))) (EApp (EVar "indentBlock") (EApp (EVar "text") (ELit (LString "}"))))))) (DoLet false false (PVar "deriveDoc") (EIf (EApp (EVar "isEmptyL") (EVar "derives")) (EVar "Nil") (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "printDerives") (EVar "derives"))))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "visPrefix") (EVar "vis"))) (EApp (EApp (EVar "Cat") (EVar "head")) (EApp (EApp (EVar "Cat") (EVar "body")) (EVar "deriveDoc")))))))
(DFunDef false "printNamedFieldData" ((PVar "vis") (PVar "n") (PVar "params") (PVar "variants") (PVar "derives")) (EApp (EVar "printDecl") (EApp (EApp (EApp (EApp (EApp (EVar "DData") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "variants")) (EVar "derives"))))
(DTypeSig false "printDerives" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Doc")))
(DFunDef false "printDerives" ((PList)) (EVar "Nil"))
(DFunDef false "printDerives" ((PVar "derives")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "deriving (")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "derives")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DTypeSig false "visPrefix" (TyFun (TyCon "DataVis") (TyCon "Doc")))
(DFunDef false "visPrefix" ((PCon "VisPublic")) (EApp (EVar "text") (ELit (LString "public export "))))
(DFunDef false "visPrefix" ((PCon "VisAbstract")) (EApp (EVar "text") (ELit (LString "export "))))
(DFunDef false "visPrefix" ((PCon "VisPrivate")) (EVar "Nil"))
(DTypeSig false "dataVariantDocs" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Doc")))
(DFunDef false "dataVariantDocs" ((PList)) (EVar "Nil"))
(DFunDef false "dataVariantDocs" ((PCons (PVar "v") (PVar "vs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "FlatAlt") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "text") (ELit (LString "| "))))) (EApp (EVar "text") (ELit (LString " "))))) (EApp (EVar "printVariant") (EVar "v")))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "v2")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "FlatAlt") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "text") (ELit (LString "| "))))) (EApp (EVar "text") (ELit (LString " | "))))) (EApp (EVar "printVariant") (EVar "v2"))))) (EVar "vs")))))))
(DTypeSig true "printDataDeclCommented" (TyFun (TyCon "DataVis") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Doc"))))))))
(DFunDef false "printDataDeclCommented" ((PVar "vis") (PVar "n") (PVar "params") (PVar "variants") (PVar "derives") (PVar "vcomments")) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "data ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "p"))))) (EVar "params")))))) (DoLet false false (PVar "variantDocs") (EApp (EApp (EVar "dataVariantDocsCommented") (EVar "variants")) (EVar "vcomments"))) (DoLet false false (PVar "deriveDoc") (EIf (EApp (EVar "isEmptyL") (EVar "derives")) (EVar "Nil") (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "printDerives") (EVar "derives"))))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "visPrefix") (EVar "vis"))) (EApp (EApp (EVar "Cat") (EVar "head")) (EApp (EApp (EVar "Cat") (EVar "variantDocs")) (EVar "deriveDoc")))))))
(DTypeSig false "commentLinesDoc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Doc")))
(DFunDef false "commentLinesDoc" ((PVar "cs")) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "text") (EVar "c"))))) (EVar "cs"))))
(DTypeSig false "trailingCommentsDoc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Doc")))
(DFunDef false "trailingCommentsDoc" ((PVar "cs")) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "  ")))) (EApp (EVar "text") (EVar "c"))))) (EVar "cs"))))
(DTypeSig false "variantCommentedDoc" (TyFun (TyCon "Variant") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Doc"))))
(DFunDef false "variantCommentedDoc" ((PVar "v") (PTuple (PVar "leading") (PVar "trailing"))) (EApp (EApp (EVar "Cat") (EApp (EVar "commentLinesDoc") (EVar "leading"))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "| ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printVariant") (EVar "v"))) (EApp (EVar "trailingCommentsDoc") (EVar "trailing")))))))
(DTypeSig false "dataVariantDocsCommented" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Doc"))))
(DFunDef false "dataVariantDocsCommented" ((PList) PWild) (EVar "Nil"))
(DFunDef false "dataVariantDocsCommented" (PWild (PList)) (EVar "Nil"))
(DFunDef false "dataVariantDocsCommented" ((PCons (PVar "v") (PVar "vs")) (PCons (PVar "vc") (PVar "vcs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "variantCommentedDoc") (EVar "v")) (EVar "vc"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map2VariantComment") (EVar "vs")) (EVar "vcs")))))))
(DTypeSig false "map2VariantComment" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "Doc")))))
(DFunDef false "map2VariantComment" ((PList) PWild) (EListLit))
(DFunDef false "map2VariantComment" (PWild (PList)) (EListLit))
(DFunDef false "map2VariantComment" ((PCons (PVar "v") (PVar "vs")) (PCons (PVar "vc") (PVar "vcs"))) (EBinOp "::" (EApp (EApp (EVar "variantCommentedDoc") (EVar "v")) (EVar "vc")) (EApp (EApp (EVar "map2VariantComment") (EVar "vs")) (EVar "vcs"))))
(DTypeSig true "printDecl" (TyFun (TyCon "Decl") (TyCon "Doc")))
(DFunDef false "printDecl" ((PCon "DTypeSig" (PVar "pub") (PVar "n") (PVar "t"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "printType") (EVar "t"))))))
(DFunDef false "printDecl" ((PCon "DExtern" (PVar "pub") (PVar "n") (PVar "t"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "extern ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "printType") (EVar "t")))))))
(DFunDef false "printDecl" ((PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "header") (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))))) (DoExpr (EApp (EApp (EVar "Cat") (EVar "header")) (EApp (EVar "printDefRhs") (EVar "body"))))))
(DFunDef false "printDecl" ((PCon "DLetGroup" (PVar "pub") (PVar "bindings"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EVar "letGroupDecl") (EVar "bindings"))))
(DFunDef false "printDecl" ((PCon "DData" (PVar "vis") (PVar "n") (PVar "params") (PVar "variants") (PVar "derives"))) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "data ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "p"))))) (EVar "params")))))) (DoLet false false (PVar "variantDocs") (EApp (EVar "dataVariantDocs") (EVar "variants"))) (DoLet false false (PVar "deriveDoc") (EIf (EApp (EVar "isEmptyL") (EVar "derives")) (EVar "Nil") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "printDerives") (EVar "derives"))))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "visPrefix") (EVar "vis"))) (EApp (EApp (EVar "Cat") (EVar "head")) (EApp (EApp (EVar "Cat") (EVar "variantDocs")) (EVar "deriveDoc"))))))))
(DFunDef false "printDecl" ((PCon "DTypeAlias" (PVar "pub") (PVar "n") (PVar "params") (PVar "rhs"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "type ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "p"))))) (EVar "params")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "printType") (EVar "rhs"))))))))
(DFunDef false "printDecl" ((PCon "DNewtype" (PVar "pub") (PVar "n") (PVar "params") (PVar "con") (PVar "fty") (PVar "derives"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "newtype ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "p"))))) (EVar "params")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "con"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printTypeAtom") (EVar "fty"))) (EIf (EApp (EVar "isEmptyL") (EVar "derives")) (EVar "Nil") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " deriving (")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "derives")))) (EApp (EVar "text") (ELit (LString ")")))))))))))))))
(DFunDef false "printDecl" ((PRec "DInterface" ((rf "pub" None) (rf "def" None) (rf "name" None) (rf "typarams" None) (rf "supers" None) (rf "methods" None)) false)) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EIf (EVar "def") (EApp (EVar "text") (ELit (LString "default "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "interface ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "p"))))) (EVar "typarams")))) (EApp (EApp (EVar "Cat") (EApp (EVar "superDoc") (EVar "supers"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " where")))) (EApp (EVar "indentBlock") (EApp (EApp (EVar "sepBy") (EVar "Hardline")) (EApp (EApp (EVar "map") (EVar "ifaceMethodDoc")) (EVar "methods"))))))))))))
(DFunDef false "printDecl" ((PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "impl ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "implHead") (EVar "iface")) (EVar "tys"))) (EApp (EApp (EVar "Cat") (EApp (EVar "reqsDoc") (EVar "reqs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " where")))) (EApp (EVar "indentBlock") (EApp (EApp (EVar "sepBy") (EVar "Hardline")) (EApp (EApp (EVar "map") (EVar "implMethodDoc")) (EVar "methods"))))))))))
(DFunDef false "printDecl" ((PCon "DUse" (PVar "pub") (PVar "path") PWild)) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "import ")))) (EApp (EVar "printUsePath") (EVar "path")))))
(DFunDef false "printDecl" ((PCon "DEffect" (PVar "pub") (PVar "name") (PVar "domain") (PVar "isInternal"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "effDeclHead") (EVar "pub")) (EVar "isInternal"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EVar "effDomainDoc") (EVar "domain")))))
(DFunDef false "printDecl" ((PCon "DProp" (PVar "pub") (PVar "propName") (PVar "propParams") (PVar "propBody"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "prop ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "escStringLit") (EVar "propName")))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (EVar "propParamDoc")) (EVar "propParams")))) (EApp (EVar "printDefRhs") (EVar "propBody")))))))
(DFunDef false "printDecl" ((PCon "DTest" (PVar "pub") (PVar "testName") (PVar "testBody"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "test ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "escStringLit") (EVar "testName")))) (EApp (EVar "printDefRhs") (EVar "testBody"))))))
(DFunDef false "printDecl" ((PCon "DBench" (PVar "pub") (PVar "benchName") (PVar "benchBody"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "bench ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "escStringLit") (EVar "benchName")))) (EApp (EVar "printDefRhs") (EVar "benchBody"))))))
(DFunDef false "printDecl" ((PCon "DAttrib" (PVar "attrs") (PVar "inner"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (EVar "attrDoc")) (EVar "attrs")))) (EApp (EVar "printDecl") (EVar "inner"))))
(DTypeSig false "propParamDoc" (TyFun (TyCon "PropParam") (TyCon "Doc")))
(DFunDef false "propParamDoc" ((PCon "PropParam" (PVar "x") (PVar "ty"))) (EApp (EVar "text") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EVar "display") (EVar "x"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppTy") (EVar "ty")))) (ELit (LString ")")))))
(DTypeSig false "attrDoc" (TyFun (TyCon "Attr") (TyCon "Doc")))
(DFunDef false "attrDoc" ((PCon "AttrDeprecated" (PVar "msg"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EBinOp "++" (ELit (LString "@deprecated ")) (EApp (EVar "escStringLit") (EVar "msg"))))) (EApp (EVar "text") (ELit (LString "\n")))))
(DFunDef false "attrDoc" ((PCon "AttrInline")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "@inline")))) (EApp (EVar "text") (ELit (LString "\n")))))
(DFunDef false "attrDoc" ((PCon "AttrMustUse")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "@must_use")))) (EApp (EVar "text") (ELit (LString "\n")))))
(DTypeSig false "letGroupDecl" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Doc")))
(DFunDef false "letGroupDecl" ((PVar "bindings")) (EBlock (DoLet false false (PVar "docs") (EApp (EApp (EVar "letGroupDeclGo") (EVar "True")) (EVar "bindings"))) (DoExpr (EApp (EVar "concatD") (EVar "docs")))))
(DTypeSig false "letGroupDeclGo" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyCon "Doc")))))
(DFunDef false "letGroupDeclGo" (PWild (PList)) (EListLit))
(DFunDef false "letGroupDeclGo" ((PVar "first") (PCons (PCon "LetBind" (PVar "name") (PVar "clauses")) (PVar "rest"))) (EBlock (DoLet false false (PVar "r") (EApp (EApp (EApp (EVar "letGroupBindClauses") (EVar "first")) (EVar "name")) (EVar "clauses"))) (DoExpr (EMatch (EVar "r") (arm (PTuple (PVar "docs") (PVar "nextFirst")) () (EBinOp "++" (EVar "docs") (EApp (EApp (EVar "letGroupDeclGo") (EVar "nextFirst")) (EVar "rest"))))))))
(DTypeSig false "letGroupBindClauses" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyTuple (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Bool"))))))
(DFunDef false "letGroupBindClauses" ((PVar "first") PWild (PList)) (ETuple (EListLit) (EVar "first")))
(DFunDef false "letGroupBindClauses" ((PVar "first") (PVar "name") (PCons (PVar "c") (PVar "cs"))) (EBlock (DoLet false false (PVar "d") (EApp (EApp (EApp (EVar "letGroupDeclClause") (EVar "first")) (EVar "name")) (EVar "c"))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EVar "letGroupBindClauses") (EVar "False")) (EVar "name")) (EVar "cs"))) (DoExpr (EMatch (EVar "r") (arm (PTuple (PVar "rest") (PVar "lastFirst")) () (ETuple (EBinOp "::" (EVar "d") (EVar "rest")) (EVar "lastFirst")))))))
(DTypeSig false "letGroupDeclClause" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyCon "Doc")))))
(DFunDef false "letGroupDeclClause" ((PVar "first") (PVar "name") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "Cat") (EIf (EVar "first") (EApp (EVar "text") (ELit (LString "let rec "))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "text") (ELit (LString "with ")))))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "letGroupDeclClauseBody") (EVar "body")))))))
(DTypeSig false "letGroupDeclClauseBody" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "letGroupDeclClauseBody" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "letGroupDeclClauseBody") (EVar "e")))
(DFunDef false "letGroupDeclClauseBody" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "printExprBody") (EApp (EVar "EBlock") (EVar "stmts"))))
(DFunDef false "letGroupDeclClauseBody" ((PVar "body")) (EIf (EApp (EVar "isBlockBody") (EVar "body")) (EApp (EVar "indentBlock") (EApp (EVar "printExprBody") (EVar "body"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printExprBody") (EVar "body"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "superDoc" (TyFun (TyApp (TyCon "List") (TyCon "Super")) (TyCon "Doc")))
(DFunDef false "superDoc" ((PList)) (EVar "Nil"))
(DFunDef false "superDoc" ((PVar "supers")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " requires ")))) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "oneSuper")) (EVar "supers")))))
(DTypeSig false "oneSuper" (TyFun (TyCon "Super") (TyCon "Doc")))
(DFunDef false "oneSuper" ((PCon "Super" (PVar "n") (PVar "ps"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "p"))))) (EVar "ps")))))
(DTypeSig false "ifaceMethodDoc" (TyFun (TyCon "IfaceMethod") (TyCon "Doc")))
(DFunDef false "ifaceMethodDoc" ((PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "printType") (EVar "ty")))))
(DFunDef false "ifaceMethodDoc" ((PCon "IfaceMethod" (PVar "n") PWild (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "printExprBody") (EVar "body"))))))
(DTypeSig false "implHead" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Doc"))))
(DFunDef false "implHead" ((PVar "iface") (PVar "tys")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "iface"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "t")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "t"))))) (EVar "tys")))))
(DTypeSig false "reqsDoc" (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyCon "Doc")))
(DFunDef false "reqsDoc" ((PList)) (EVar "Nil"))
(DFunDef false "reqsDoc" ((PVar "reqs")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " requires ")))) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "oneReq")) (EVar "reqs")))))
(DTypeSig false "oneReq" (TyFun (TyCon "Require") (TyCon "Doc")))
(DFunDef false "oneReq" ((PCon "Require" (PVar "iface") (PVar "args"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "iface"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "t")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "t"))))) (EVar "args")))))
(DTypeSig false "implMethodDoc" (TyFun (TyCon "ImplMethod") (TyCon "Doc")))
(DFunDef false "implMethodDoc" ((PCon "ImplMethod" (PVar "n") (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))) (EApp (EVar "printDefRhs") (EVar "body")))))
(DTypeSig false "ppTy" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTy" ((PVar "t")) (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 0))) (EVar "t")))
(DTypeSig false "ppTyPrec" (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "ppTyPrec" (PWild (PCon "TyCon" (PVar "s") PWild)) (EApp (EVar "tyConSurface") (EVar "s")))
(DFunDef false "ppTyPrec" (PWild (PCon "TyVar" (PVar "s"))) (EVar "s"))
(DFunDef false "ppTyPrec" (PWild (PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EApp (EVar "ppTyPrec") (ELit (LInt 0)))) (EVar "ts")))) (ELit (LString ")"))))
(DFunDef false "ppTyPrec" ((PVar "p") (PCon "TyApp" (PVar "f") (PVar "x"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 1))) (EVar "f")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 2))) (EVar "x")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 2))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyPrec" ((PVar "p") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 1))) (EVar "a")))) (ELit (LString " -> "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 0))) (EVar "b")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyPrec" ((PVar "p") (PCon "TyEffect" (PVar "effs") (PVar "tail") (PVar "t"))) (EBlock (DoLet false false (PVar "inside") (EApp (EApp (EVar "ppEffInside") (EVar "effs")) (EVar "tail"))) (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EVar "inside"))) (ELit (LString "> "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 0))) (EVar "t")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyPrec" (PWild (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBlock (DoLet false false (PVar "csStr") (EMatch (EVar "cs") (arm (PList (PVar "c")) () (EApp (EVar "ppConstr") (EVar "c"))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "ppConstr")) (EVar "cs")))) (ELit (LString ")")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "csStr"))) (ELit (LString " => "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 0))) (EVar "t")))) (ELit (LString ""))))))
(DTypeSig false "ppEffInside" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "ppEffInside" ((PVar "effs") (PCon "None")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "ppEffAtom")) (EVar "effs"))))
(DFunDef false "ppEffInside" ((PList) (PCon "Some" (PVar "v"))) (EVar "v"))
(DFunDef false "ppEffInside" ((PVar "effs") (PCon "Some" (PVar "v"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "ppEffAtom")) (EVar "effs"))))) (ELit (LString " | "))) (EApp (EVar "display") (EVar "v"))) (ELit (LString ""))))
(DTypeSig false "ppEffAtom" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "ppEffAtom" ((PTuple (PVar "l") (PCon "None"))) (EVar "l"))
(DFunDef false "ppEffAtom" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "l"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStringLit") (EVar "s")))) (ELit (LString ""))))
(DTypeSig false "effDomainDoc" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Doc")))
(DFunDef false "effDomainDoc" ((PCon "None")) (EVar "Nil"))
(DFunDef false "effDomainDoc" ((PCon "Some" (PVar "d"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "d"))))
(DTypeSig false "effDeclHead" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Doc"))))
(DFunDef false "effDeclHead" (PWild (PCon "True")) (EApp (EVar "text") (ELit (LString "internal effect "))))
(DFunDef false "effDeclHead" ((PCon "True") (PCon "False")) (EApp (EVar "text") (ELit (LString "export effect "))))
(DFunDef false "effDeclHead" ((PCon "False") (PCon "False")) (EApp (EVar "text") (ELit (LString "effect "))))
(DTypeSig false "ppConstr" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "ppConstr" ((PCon "Constraint" (PVar "iface") (PVar "args"))) (EIf (EApp (EVar "isEmptyL") (EVar "args")) (EVar "iface") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EApp (EVar "ppTyPrec") (ELit (LInt 2)))) (EVar "args"))))) (ELit (LString "")))))
(DTypeSig true "exprToString" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "exprToString" ((PVar "e")) (EApp (EVar "render") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))))
(DTypeSig true "declToString" (TyFun (TyCon "Decl") (TyCon "String")))
(DFunDef false "declToString" ((PVar "d")) (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "d"))))
(DTypeSig true "programToString" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "programToString" ((PVar "decls")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "map") (EVar "declLine")) (EVar "decls"))))
(DTypeSig false "declLine" (TyFun (TyCon "Decl") (TyCon "String")))
(DFunDef false "declLine" ((PVar "d")) (EBinOp "++" (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "d"))) (ELit (LString "\n"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Ty" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true) (mem "Attr" true))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "listLen" false) (mem "allList" false) (mem "reverseL" false) (mem "isEmptyL" false))))
(DData Public "Doc" () ((variant "Nil" (ConPos)) (variant "Text" (ConPos (TyCon "String"))) (variant "Cat" (ConPos (TyCon "Doc") (TyCon "Doc"))) (variant "Line" (ConPos)) (variant "Softline" (ConPos)) (variant "Hardline" (ConPos)) (variant "Nest" (ConPos (TyCon "Int") (TyCon "Doc"))) (variant "Group" (ConPos (TyCon "Doc"))) (variant "FlatGroup" (ConPos (TyCon "Doc"))) (variant "FlatAlt" (ConPos (TyCon "Doc") (TyCon "Doc"))) (variant "LineComment" (ConPos (TyCon "String")))) ())
(DTypeSig false "text" (TyFun (TyCon "String") (TyCon "Doc")))
(DFunDef false "text" ((PVar "s")) (EApp (EVar "Text") (EVar "s")))
(DTypeSig false "group" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "group" ((PVar "d")) (EApp (EVar "Group") (EVar "d")))
(DTypeSig false "flatGroup" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "flatGroup" ((PVar "d")) (EApp (EVar "FlatGroup") (EVar "d")))
(DTypeSig false "flatAlt" (TyFun (TyCon "Doc") (TyFun (TyCon "Doc") (TyCon "Doc"))))
(DFunDef false "flatAlt" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "FlatAlt") (EVar "a")) (EVar "b")))
(DTypeSig false "trailingCommaFor" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Doc")))
(DFunDef false "trailingCommaFor" ((PList)) (EVar "Nil"))
(DFunDef false "trailingCommaFor" ((PList PWild)) (EVar "Nil"))
(DFunDef false "trailingCommaFor" (PWild) (EApp (EApp (EVar "flatAlt") (EApp (EVar "text") (ELit (LString ",")))) (EVar "Nil")))
(DTypeSig false "nest" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "nest" ((PVar "d")) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EVar "d")))
(DTypeSig false "sepBy" (TyFun (TyCon "Doc") (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc"))))
(DFunDef false "sepBy" (PWild (PList)) (EVar "Nil"))
(DFunDef false "sepBy" (PWild (PList (PVar "x"))) (EVar "x"))
(DFunDef false "sepBy" ((PVar "sep") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "Cat") (EVar "x")) (EApp (EApp (EVar "Cat") (EVar "sep")) (EApp (EApp (EVar "sepBy") (EVar "sep")) (EVar "xs")))))
(DTypeSig false "concatD" (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc")))
(DFunDef false "concatD" ((PList)) (EVar "Nil"))
(DFunDef false "concatD" ((PCons (PVar "d") (PVar "ds"))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "concatD") (EVar "ds"))))
(DTypeSig false "indentBlock" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "indentBlock" ((PVar "d")) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EVar "d"))))
(DTypeSig false "delimited" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc")))))
(DFunDef false "delimited" ((PVar "open_") (PVar "close_") (PList)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EVar "text") (EVar "close_"))))
(DFunDef false "delimited" ((PVar "open_") (PVar "close_") (PVar "items")) (EApp (EVar "flatGroup") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Softline")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ",")))) (EVar "Line"))) (EVar "items"))) (EApp (EVar "trailingCommaFor") (EVar "items")))))) (EApp (EApp (EVar "Cat") (EVar "Softline")) (EApp (EVar "text") (EVar "close_")))))))
(DTypeSig false "delimitedG" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc")))))
(DFunDef false "delimitedG" ((PVar "open_") (PVar "close_") (PList)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EVar "text") (EVar "close_"))))
(DFunDef false "delimitedG" ((PVar "open_") (PVar "close_") (PVar "items")) (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Softline")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ",")))) (EVar "Line"))) (EVar "items"))) (EApp (EVar "trailingCommaFor") (EVar "items")))))) (EApp (EApp (EVar "Cat") (EVar "Softline")) (EApp (EVar "text") (EVar "close_")))))))
(DTypeSig false "braced" (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc")))
(DFunDef false "braced" ((PList)) (EApp (EVar "text") (ELit (LString "{}"))))
(DFunDef false "braced" ((PVar "items")) (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "{")))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ",")))) (EVar "Line"))) (EVar "items"))) (EApp (EVar "trailingCommaFor") (EVar "items")))))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "text") (ELit (LString "}"))))))))
(DData Public "Mode" () ((variant "Flat" (ConPos)) (variant "Break" (ConPos))) ())
(DData Public "Item" () ((variant "Item" (ConPos (TyCon "Int") (TyCon "Mode") (TyCon "Doc")))) ())
(DTypeSig false "defaultWidth" (TyCon "Int"))
(DFunDef false "defaultWidth" () (ELit (LInt 80)))
(DTypeSig false "fits" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Item")) (TyCon "Bool"))))
(DFunDef false "fits" ((PVar "w") PWild) (EIf (EBinOp "<" (EVar "w") (ELit (LInt 0))) (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "fits" (PWild (PList)) (EVar "True"))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" PWild PWild (PCon "Nil")) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EVar "z")))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Cat" (PVar "a") (PVar "b"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "a")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "b")) (EVar "z")))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Nest" (PVar "j") (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "m")) (EVar "d")) (EVar "z"))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" PWild PWild (PCon "Text" (PVar "s"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "w") (EApp (EVar "stringLength") (EVar "s")))) (EVar "z")))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Line")) (PVar "z"))) (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "w") (ELit (LInt 1)))) (EVar "z")))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Softline")) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EVar "z")))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Break") (PCon "Line")) PWild)) (EVar "True"))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Break") (PCon "Softline")) PWild)) (EVar "True"))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Break") (PCon "Hardline")) PWild)) (EVar "True"))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Hardline")) PWild)) (EVar "False"))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") PWild (PCon "Group" (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d")) (EVar "z"))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") PWild (PCon "FlatGroup" (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d")) (EVar "z"))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "FlatAlt" PWild (PVar "b"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "b")) (EVar "z"))))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild PWild (PCon "LineComment" PWild)) PWild)) (EVar "True"))
(DTypeSig false "spaces" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "spaces" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ELit (LString "")) (EIf (EVar "otherwise") (EBinOp "++" (ELit (LString " ")) (EApp (EVar "spaces") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "newlineStr" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "newlineStr" ((PVar "i")) (EBinOp "++" (ELit (LString "\n")) (EApp (EVar "spaces") (EVar "i"))))
(DTypeSig false "go" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Item")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "go" (PWild (PList)) (EListLit))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild PWild (PCon "Nil")) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EVar "z")))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Cat" (PVar "a") (PVar "b"))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "a")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "b")) (EVar "z")))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Nest" (PVar "j") (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "m")) (EVar "d")) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild PWild (PCon "Text" (PVar "s"))) (PVar "z"))) (EBinOp "::" (EVar "s") (EApp (EApp (EVar "go") (EBinOp "+" (EVar "col") (EApp (EVar "stringLength") (EVar "s")))) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Line")) (PVar "z"))) (EBinOp "::" (ELit (LString " ")) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "col") (ELit (LInt 1)))) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Softline")) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EVar "z")))
(DFunDef false "go" (PWild (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "Line")) (PVar "z"))) (EBinOp "::" (EApp (EVar "newlineStr") (EVar "i")) (EApp (EApp (EVar "go") (EVar "i")) (EVar "z"))))
(DFunDef false "go" (PWild (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "Softline")) (PVar "z"))) (EBinOp "::" (EApp (EVar "newlineStr") (EVar "i")) (EApp (EApp (EVar "go") (EVar "i")) (EVar "z"))))
(DFunDef false "go" (PWild (PCons (PCon "Item" (PVar "i") PWild (PCon "Hardline")) (PVar "z"))) (EBinOp "::" (EApp (EVar "newlineStr") (EVar "i")) (EApp (EApp (EVar "go") (EVar "i")) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") PWild (PCon "Group" (PVar "d"))) (PVar "z"))) (EBlock (DoLet false false (PVar "flat") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d")) (EVar "z"))) (DoExpr (EIf (EBinOp "||" (EBinOp ">=" (EVar "col") (EVar "defaultWidth")) (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "defaultWidth") (EVar "col"))) (EDictApp "flat"))) (EApp (EApp (EVar "go") (EVar "col")) (EDictApp "flat")) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "d")) (EVar "z")))))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") PWild (PCon "FlatGroup" (PVar "d"))) (PVar "z"))) (EBlock (DoLet false false (PVar "flat") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d")) (EVar "z"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp ">=" (EVar "col") (EVar "defaultWidth")) (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "defaultWidth") (EVar "col"))) (EDictApp "flat"))) (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "defaultWidth") (EVar "i"))) (EListLit (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d"))))) (EApp (EApp (EVar "go") (EVar "col")) (EDictApp "flat")) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "d")) (EVar "z")))))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Flat") (PCon "FlatAlt" PWild (PVar "b"))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "b")) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "FlatAlt" (PVar "a") PWild)) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "a")) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild PWild (PCon "LineComment" (PVar "s"))) (PVar "z"))) (EBinOp "::" (EBinOp "++" (ELit (LString "  ")) (EVar "s")) (EApp (EApp (EVar "go") (EBinOp "+" (EBinOp "+" (EVar "col") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "s")))) (EVar "z"))))
(DTypeSig true "render" (TyFun (TyCon "Doc") (TyCon "String")))
(DFunDef false "render" ((PVar "doc")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "go") (ELit (LInt 0))) (EListLit (EApp (EApp (EApp (EVar "Item") (ELit (LInt 0))) (EVar "Break")) (EVar "doc"))))))
(DTypeSig false "escapeCharLit" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escapeCharLit" ((PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "'"))) (ELit (LString "\\'")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\\"))) (ELit (LString "\\\\")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\n"))) (ELit (LString "\\n")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\t"))) (ELit (LString "\\t")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\r"))) (ELit (LString "\\r")) (EIf (EBinOp "==" (EVar "c") (ELit (LString " "))) (ELit (LString "\\0")) (EIf (EVar "otherwise") (EVar "c") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "escStringLit" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escStringLit" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "escSChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))))) (ELit (LString "\""))))
(DTypeSig false "escSChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "escSChars" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "escSOne") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EVar "escSChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "escSOne" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "escSOne" ((PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\\"))) (ELit (LString "\\\\")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (ELit (LString "\\\"")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\n"))) (ELit (LString "\\n")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\t"))) (ELit (LString "\\t")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\r"))) (ELit (LString "\\r")) (EIf (EVar "otherwise") (EApp (EVar "charToStr") (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "printLit" (TyFun (TyCon "Lit") (TyCon "Doc")))
(DFunDef false "printLit" ((PCon "LInt" (PVar "n"))) (EApp (EVar "text") (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "printLit" ((PCon "LFloat" (PVar "f"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "floatToString") (EVar "f"))) (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EApp (EVar "text") (EIf (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString ".")))) (EBinOp "++" (EVar "s") (ELit (LString "0"))) (EVar "s"))))))
(DFunDef false "printLit" ((PCon "LString" (PVar "s"))) (EApp (EVar "text") (EApp (EVar "escStringLit") (EVar "s"))))
(DFunDef false "printLit" ((PCon "LChar" (PVar "c"))) (EApp (EVar "text") (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "escapeCharLit") (EVar "c"))) (ELit (LString "'")))))
(DFunDef false "printLit" ((PCon "LBool" (PVar "b"))) (EApp (EVar "text") (EIf (EVar "b") (ELit (LString "True")) (ELit (LString "False")))))
(DFunDef false "printLit" ((PCon "LUnit")) (EApp (EVar "text") (ELit (LString "()"))))
(DTypeSig false "isNegLit" (TyFun (TyCon "Lit") (TyCon "Bool")))
(DFunDef false "isNegLit" ((PCon "LInt" (PVar "n"))) (EBinOp "<" (EVar "n") (ELit (LInt 0))))
(DFunDef false "isNegLit" ((PCon "LFloat" (PVar "f"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "floatToString") (EVar "f"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "-")))))))
(DFunDef false "isNegLit" (PWild) (EVar "False"))
(DTypeSig false "tyConSurface" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple2__"))) (ELit (LString "(,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple3__"))) (ELit (LString "(,,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple4__"))) (ELit (LString "(,,,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple5__"))) (ELit (LString "(,,,,)")))
(DFunDef false "tyConSurface" ((PVar "n")) (EVar "n"))
(DTypeSig false "printType" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "printType" ((PCon "TyCon" (PVar "n") PWild)) (EApp (EVar "text") (EApp (EVar "tyConSurface") (EVar "n"))))
(DFunDef false "printType" ((PCon "TyVar" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printType" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printTypeAppLhs") (EVar "a"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "b")))))
(DFunDef false "printType" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printTypeFunLhs") (EVar "a"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " -> ")))) (EApp (EVar "printType") (EVar "b")))))
(DFunDef false "printType" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "printType")) (EVar "ts")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printType" ((PCon "TyEffect" (PVar "es") (PVar "tail") (PVar "t"))) (EBlock (DoLet false false (PVar "inside") (EApp (EApp (EVar "effectInside") (EVar "es")) (EVar "tail"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "<")))) (EApp (EApp (EVar "Cat") (EVar "inside")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "> ")))) (EApp (EVar "printTypeAppLhs") (EVar "t"))))))))
(DFunDef false "printType" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBlock (DoLet false false (PVar "csDoc") (EMatch (EVar "cs") (arm (PList (PVar "c")) () (EApp (EVar "printConstraint") (EVar "c"))) (arm PWild () (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "printConstraint")) (EVar "cs")))) (EApp (EVar "text") (ELit (LString ")")))))))) (DoExpr (EApp (EApp (EVar "Cat") (EVar "csDoc")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " => ")))) (EApp (EVar "printType") (EVar "t")))))))
(DTypeSig false "effectInside" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Doc"))))
(DFunDef false "effectInside" ((PVar "es") (PCon "None")) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "effAtomDoc")) (EVar "es"))))
(DFunDef false "effectInside" ((PList) (PCon "Some" (PVar "v"))) (EApp (EVar "text") (EVar "v")))
(DFunDef false "effectInside" ((PVar "es") (PCon "Some" (PVar "v"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "effAtomDoc")) (EVar "es")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " | ")))) (EApp (EVar "text") (EVar "v")))))
(DTypeSig false "effAtomDoc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc")))
(DFunDef false "effAtomDoc" ((PTuple (PVar "l") (PCon "None"))) (EApp (EVar "text") (EVar "l")))
(DFunDef false "effAtomDoc" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EApp (EVar "text") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStringLit") (EVar "s")))) (ELit (LString "")))))
(DTypeSig false "printConstraint" (TyFun (TyCon "Constraint") (TyCon "Doc")))
(DFunDef false "printConstraint" ((PCon "Constraint" (PVar "iface") (PVar "args"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "iface"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "a"))))) (EVar "args")))))
(DTypeSig false "printTypeAtom" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "printTypeAtom" ((PCon "TyCon" (PVar "n") PWild)) (EApp (EVar "text") (EApp (EVar "tyConSurface") (EVar "n"))))
(DFunDef false "printTypeAtom" ((PCon "TyVar" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printTypeAtom" ((PCon "TyTuple" (PVar "ts"))) (EApp (EVar "printType") (EApp (EVar "TyTuple") (EVar "ts"))))
(DFunDef false "printTypeAtom" ((PVar "t")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printType") (EVar "t"))) (EApp (EVar "text") (ELit (LString ")"))))))
(DTypeSig false "printTypeFunLhs" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "printTypeFunLhs" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printType") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printTypeFunLhs" ((PVar "t")) (EApp (EVar "printType") (EVar "t")))
(DTypeSig false "printTypeAppLhs" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "printTypeAppLhs" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EVar "printType") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))))
(DFunDef false "printTypeAppLhs" ((PVar "t")) (EApp (EVar "printTypeAtom") (EVar "t")))
(DTypeSig false "printPat" (TyFun (TyCon "Pat") (TyCon "Doc")))
(DFunDef false "printPat" ((PCon "PVar" (PVar "x"))) (EApp (EVar "text") (EVar "x")))
(DFunDef false "printPat" ((PCon "PWild")) (EApp (EVar "text") (ELit (LString "_"))))
(DFunDef false "printPat" ((PCon "PLit" (PVar "l"))) (EApp (EVar "printLit") (EVar "l")))
(DFunDef false "printPat" ((PCon "PCon" (PVar "c") (PList))) (EApp (EVar "text") (EVar "c")))
(DFunDef false "printPat" ((PCon "PCon" (PVar "c") (PVar "pats"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))) (EApp (EVar "text") (ELit (LString ")")))))))
(DFunDef false "printPat" ((PCon "PCons" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPatAtom") (EVar "a"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "::")))) (EApp (EVar "printPat") (EVar "b")))))
(DFunDef false "printPat" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "printPatArm")) (EVar "ps")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printPat" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "[")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "printPatArm")) (EVar "ps")))) (EApp (EVar "text") (ELit (LString "]"))))))
(DFunDef false "printPat" ((PCon "PAs" (PVar "x") (PVar "inner"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "@")))) (EApp (EVar "printPatAtom") (EVar "inner")))))
(DFunDef false "printPat" ((PCon "PRec" (PVar "name") (PVar "fields") (PVar "rest"))) (EBlock (DoLet false false (PVar "fieldDocs") (EApp (EApp (EMethodRef "map") (EVar "recPatFieldDoc")) (EVar "fields"))) (DoLet false false (PVar "all") (EIf (EVar "rest") (EBinOp "++" (EVar "fieldDocs") (EListLit (EApp (EVar "text") (ELit (LString "..."))))) (EVar "fieldDocs"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " { ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EDictApp "all"))) (EApp (EVar "text") (ELit (LString " }")))))))))
(DFunDef false "printPat" ((PCon "PRng" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printLit") (EVar "lo"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "incl") (ELit (LString "..=")) (ELit (LString ".."))))) (EApp (EVar "printLit") (EVar "hi")))))
(DTypeSig false "recPatFieldDoc" (TyFun (TyCon "RecPatField") (TyCon "Doc")))
(DFunDef false "recPatFieldDoc" ((PCon "RecPatField" (PVar "k") (PCon "None"))) (EApp (EVar "text") (EVar "k")))
(DFunDef false "recPatFieldDoc" ((PCon "RecPatField" (PVar "k") (PCon "Some" (PVar "q")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "k"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "printPat") (EVar "q")))))
(DTypeSig false "printPatAtom" (TyFun (TyCon "Pat") (TyCon "Doc")))
(DFunDef false "printPatAtom" ((PCon "PVar" (PVar "x"))) (EApp (EVar "printPat") (EApp (EVar "PVar") (EVar "x"))))
(DFunDef false "printPatAtom" ((PCon "PWild")) (EApp (EVar "printPat") (EVar "PWild")))
(DFunDef false "printPatAtom" ((PCon "PLit" (PVar "l"))) (EApp (EVar "printPat") (EApp (EVar "PLit") (EVar "l"))))
(DFunDef false "printPatAtom" ((PCon "PCon" (PVar "c") (PVar "ps"))) (EApp (EVar "printPat") (EApp (EApp (EVar "PCon") (EVar "c")) (EVar "ps"))))
(DFunDef false "printPatAtom" ((PCon "PTuple" (PVar "ps"))) (EApp (EVar "printPat") (EApp (EVar "PTuple") (EVar "ps"))))
(DFunDef false "printPatAtom" ((PCon "PList" (PVar "ps"))) (EApp (EVar "printPat") (EApp (EVar "PList") (EVar "ps"))))
(DFunDef false "printPatAtom" ((PCon "PRec" (PVar "n") (PVar "fs") (PVar "r"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EApp (EApp (EApp (EVar "PRec") (EVar "n")) (EVar "fs")) (EVar "r")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printPatAtom" ((PCon "PRng" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EVar "printPat") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "incl"))))
(DFunDef false "printPatAtom" ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "p"))) (EApp (EVar "text") (ELit (LString ")"))))))
(DTypeSig false "printPatArm" (TyFun (TyCon "Pat") (TyCon "Doc")))
(DFunDef false "printPatArm" ((PCon "PCon" (PVar "c") (PCons (PVar "p") (PVar "ps")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "c"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "q")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "q"))))) (EBinOp "::" (EVar "p") (EVar "ps"))))))
(DFunDef false "printPatArm" ((PVar "p")) (EApp (EVar "printPat") (EVar "p")))
(DTypeSig false "precTop" (TyCon "Int"))
(DFunDef false "precTop" () (ELit (LInt 0)))
(DTypeSig false "precAssign" (TyCon "Int"))
(DFunDef false "precAssign" () (ELit (LInt 1)))
(DTypeSig false "precPipe" (TyCon "Int"))
(DFunDef false "precPipe" () (ELit (LInt 2)))
(DTypeSig false "precCompose" (TyCon "Int"))
(DFunDef false "precCompose" () (ELit (LInt 3)))
(DTypeSig false "precOr" (TyCon "Int"))
(DFunDef false "precOr" () (ELit (LInt 4)))
(DTypeSig false "precAnd" (TyCon "Int"))
(DFunDef false "precAnd" () (ELit (LInt 5)))
(DTypeSig false "precCmp" (TyCon "Int"))
(DFunDef false "precCmp" () (ELit (LInt 6)))
(DTypeSig false "precCons" (TyCon "Int"))
(DFunDef false "precCons" () (ELit (LInt 7)))
(DTypeSig false "precAppend" (TyCon "Int"))
(DFunDef false "precAppend" () (ELit (LInt 8)))
(DTypeSig false "precAdd" (TyCon "Int"))
(DFunDef false "precAdd" () (ELit (LInt 9)))
(DTypeSig false "precMul" (TyCon "Int"))
(DFunDef false "precMul" () (ELit (LInt 10)))
(DTypeSig false "precInfix" (TyCon "Int"))
(DFunDef false "precInfix" () (ELit (LInt 11)))
(DTypeSig false "precApp" (TyCon "Int"))
(DFunDef false "precApp" () (ELit (LInt 12)))
(DTypeSig false "precUnary" (TyCon "Int"))
(DFunDef false "precUnary" () (ELit (LInt 13)))
(DTypeSig false "precPostfix" (TyCon "Int"))
(DFunDef false "precPostfix" () (ELit (LInt 14)))
(DTypeSig false "precAtom" (TyCon "Int"))
(DFunDef false "precAtom" () (ELit (LInt 15)))
(DTypeSig false "binopPrec" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "binopPrec" ((PVar "op")) (EIf (EBinOp "==" (EVar "op") (ELit (LString ":="))) (EVar "precAssign") (EIf (EBinOp "==" (EVar "op") (ELit (LString "|>"))) (EVar "precPipe") (EIf (EBinOp "==" (EVar "op") (ELit (LString ">>"))) (EVar "precCompose") (EIf (EBinOp "==" (EVar "op") (ELit (LString "<<"))) (EVar "precCompose") (EIf (EBinOp "==" (EVar "op") (ELit (LString "||"))) (EVar "precOr") (EIf (EBinOp "==" (EVar "op") (ELit (LString "&&"))) (EVar "precAnd") (EIf (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString "!="))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString "<"))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString "<="))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString ">="))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString "::"))) (EVar "precCons") (EIf (EBinOp "==" (EVar "op") (ELit (LString "++"))) (EVar "precAppend") (EIf (EBinOp "==" (EVar "op") (ELit (LString "+"))) (EVar "precAdd") (EIf (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EVar "precAdd") (EIf (EBinOp "==" (EVar "op") (ELit (LString "*"))) (EVar "precMul") (EIf (EBinOp "==" (EVar "op") (ELit (LString "/"))) (EVar "precMul") (EIf (EVar "otherwise") (EVar "precInfix") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))))))))))))
(DTypeSig false "isRightAssoc" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isRightAssoc" ((PLit (LString "::"))) (EVar "True"))
(DFunDef false "isRightAssoc" ((PLit (LString ":="))) (EVar "True"))
(DFunDef false "isRightAssoc" (PWild) (EVar "False"))
(DTypeSig false "isContinuationOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isContinuationOp" ((PVar "op")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "|>"))) (EBinOp "==" (EVar "op") (ELit (LString ">>")))) (EBinOp "==" (EVar "op") (ELit (LString "<<")))) (EBinOp "==" (EVar "op") (ELit (LString "&&")))) (EBinOp "==" (EVar "op") (ELit (LString "||")))) (EBinOp "==" (EVar "op") (ELit (LString "++")))))
(DTypeSig false "isConstructorOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isConstructorOp" ((PVar "op")) (EBinOp "==" (EVar "op") (ELit (LString "::"))))
(DTypeSig false "isConsAtomOperand" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isConsAtomOperand" ((PVar "e")) (EBlock (DoLet false false (PVar "p") (EApp (EVar "exprPrec") (EVar "e"))) (DoExpr (EBinOp "||" (EBinOp "==" (EVar "p") (EVar "precAtom")) (EBinOp "==" (EVar "p") (EVar "precPostfix"))))))
(DTypeSig false "consTight" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "consTight" ((PVar "op") (PVar "l") (PVar "r")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isConstructorOp") (EVar "op")) (EApp (EVar "isConsAtomOperand") (EVar "l"))) (EApp (EVar "isConsAtomOperand") (EVar "r"))))
(DTypeSig false "binopSpace" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc")))))
(DFunDef false "binopSpace" ((PVar "op") (PVar "l") (PVar "r")) (EIf (EApp (EApp (EApp (EVar "consTight") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "Nil") (EApp (EVar "text") (ELit (LString " ")))))
(DTypeSig false "exprPrec" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "exprPrec" ((PCon "ELit" (PVar "l"))) (EIf (EApp (EVar "isNegLit") (EVar "l")) (EVar "precUnary") (EVar "precAtom")))
(DFunDef false "exprPrec" ((PCon "ENumLit" (PVar "n") PWild PWild)) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EVar "precUnary") (EVar "precAtom")))
(DFunDef false "exprPrec" ((PCon "EVar" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EMethodRef" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EDictApp" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ETuple" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EArrayLit" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EListLit" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EMapLit" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ESetLit" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EStringInterp" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ERecordCreate" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ERecordUpdate" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EVariantUpdate" PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ERangeList" PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ERangeArray" PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ESlice" PWild PWild PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EFieldAccess" PWild PWild PWild)) (EVar "precPostfix"))
(DFunDef false "exprPrec" ((PCon "EIndex" PWild PWild PWild)) (EVar "precPostfix"))
(DFunDef false "exprPrec" ((PCon "EUnOp" PWild PWild PWild)) (EVar "precUnary"))
(DFunDef false "exprPrec" ((PCon "EApp" PWild PWild)) (EVar "precApp"))
(DFunDef false "exprPrec" ((PCon "EInfix" PWild PWild PWild)) (EVar "precInfix"))
(DFunDef false "exprPrec" ((PCon "EBinOp" (PVar "op") PWild PWild PWild)) (EApp (EVar "binopPrec") (EVar "op")))
(DFunDef false "exprPrec" ((PCon "ESection" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EAsPat" PWild PWild)) (EVar "precApp"))
(DFunDef false "exprPrec" ((PCon "ELam" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "ELet" PWild PWild PWild PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "ELetGroup" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EIf" PWild PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EMatch" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EBlock" PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EDo" PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EAnnot" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EHeadAnnot" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EGuards" PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EVarAt" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EMethodAt" PWild PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EDictAt" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "exprPrec") (EVar "e")))
(DTypeSig false "isBlockBody" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isBlockBody" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "isBlockBody") (EVar "e")))
(DFunDef false "isBlockBody" ((PCon "EMatch" PWild PWild)) (EVar "True"))
(DFunDef false "isBlockBody" ((PCon "EBlock" PWild)) (EVar "True"))
(DFunDef false "isBlockBody" ((PCon "EDo" PWild)) (EVar "True"))
(DFunDef false "isBlockBody" ((PCon "EGuards" PWild)) (EVar "True"))
(DFunDef false "isBlockBody" ((PCon "EIf" PWild (PVar "t") (PVar "e"))) (EBinOp "||" (EApp (EVar "isBlockBody") (EVar "t")) (EApp (EVar "isBlockBody") (EVar "e"))))
(DFunDef false "isBlockBody" (PWild) (EVar "False"))
(DTypeSig false "isUnitLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isUnitLit" ((PCon "ELit" (PCon "LUnit"))) (EVar "True"))
(DFunDef false "isUnitLit" (PWild) (EVar "False"))
(DTypeSig false "breakAtSepBody" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "breakAtSepBody" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "breakAtSepBody") (EVar "e")))
(DFunDef false "breakAtSepBody" ((PCon "EBinOp" (PVar "op") PWild PWild PWild)) (EApp (EVar "not") (EApp (EVar "isContinuationOp") (EVar "op"))))
(DFunDef false "breakAtSepBody" ((PVar "b")) (EApp (EVar "not") (EApp (EVar "isBlockBody") (EVar "b"))))
(DTypeSig false "printExpr" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "printExpr" ((PVar "minPrec") (PVar "e")) (EBlock (DoLet false false (PVar "ep") (EApp (EVar "exprPrec") (EVar "e"))) (DoLet false false (PVar "d") (EApp (EVar "printExprRaw") (EVar "e"))) (DoExpr (EIf (EBinOp "<" (EVar "ep") (EVar "minPrec")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "text") (ELit (LString ")"))))) (EVar "d")))))
(DTypeSig false "printExprRaw" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printExprRaw" ((PCon "ELit" (PVar "l"))) (EApp (EVar "printLit") (EVar "l")))
(DFunDef false "printExprRaw" ((PCon "ENumLit" (PVar "n") PWild PWild)) (EApp (EVar "text") (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "printExprRaw" ((PCon "EVar" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" ((PCon "EMethodRef" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" ((PCon "EDictApp" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precApp")) (EVar "f"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "x")))))
(DFunDef false "printExprRaw" ((PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EMethodRef "map") (EVar "printPatAtom")) (EVar "pats")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " => ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "body")))))
(DFunDef false "printExprRaw" ((PCon "ELet" (PVar "isMut") (PVar "isf") (PVar "pat") (PVar "rhs") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "printELet") (EVar "isMut")) (EVar "isf")) (EVar "pat")) (EVar "rhs")) (EVar "e2")))
(DFunDef false "printExprRaw" ((PCon "ELetGroup" (PVar "bindings") (PVar "body"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "body"))) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "where")))) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EVar "letGroupClauses") (EVar "bindings"))))))))
(DFunDef false "printExprRaw" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "printEIf") (EVar "c")) (EVar "t")) (EVar "e")))
(DFunDef false "printExprRaw" ((PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") PWild)) (EBlock (DoLet false false (PVar "prec") (EApp (EVar "binopPrec") (EVar "op"))) (DoLet false false (PVar "ra") (EApp (EVar "isRightAssoc") (EVar "op"))) (DoLet false false (PVar "sp") (EApp (EApp (EApp (EVar "binopSpace") (EVar "op")) (EVar "l")) (EVar "r"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EIf (EVar "ra") (EBinOp "+" (EVar "prec") (ELit (LInt 1))) (EVar "prec"))) (EVar "l"))) (EApp (EApp (EVar "Cat") (EVar "sp")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EApp (EVar "Cat") (EVar "sp")) (EApp (EApp (EVar "printExpr") (EIf (EVar "ra") (EVar "prec") (EBinOp "+" (EVar "prec") (ELit (LInt 1))))) (EVar "r")))))))))
(DFunDef false "printExprRaw" ((PCon "EUnOp" (PVar "op") (PVar "e") PWild)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EApp (EVar "printExpr") (EVar "precUnary")) (EVar "e"))))
(DFunDef false "printExprRaw" ((PCon "EFieldAccess" (PVar "e") (PVar "f") PWild)) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ".")))) (EApp (EVar "text") (EVar "f")))))
(DFunDef false "printExprRaw" ((PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "braced") (EApp (EApp (EMethodRef "map") (EVar "fieldAssignDoc")) (EVar "fs"))))))
(DFunDef false "printExprRaw" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "{ ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " | ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "fieldAssignDoc")) (EVar "fs")))) (EApp (EVar "text") (ELit (LString " }"))))))))
(DFunDef false "printExprRaw" ((PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " { ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " | ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "fieldAssignDoc")) (EVar "fs")))) (EApp (EVar "text") (ELit (LString " }")))))))))
(DFunDef false "printExprRaw" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EApp (EVar "delimited") (ELit (LString "[|"))) (ELit (LString "|]"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "printExpr") (EVar "precTop"))) (EVar "es"))))
(DFunDef false "printExprRaw" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EApp (EVar "delimited") (ELit (LString "["))) (ELit (LString "]"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "printExpr") (EVar "precTop"))) (EVar "es"))))
(DFunDef false "printExprRaw" ((PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " { ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "mapKvDoc")) (EVar "kvs")))) (EApp (EVar "text") (ELit (LString " }")))))))
(DFunDef false "printExprRaw" ((PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " { ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EApp (EVar "printExpr") (EVar "precTop"))) (EVar "es")))) (EApp (EVar "text") (ELit (LString " }")))))))
(DFunDef false "printExprRaw" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EApp (EVar "delimited") (ELit (LString "("))) (ELit (LString ")"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "printExpr") (EVar "precTop"))) (EVar "es"))))
(DFunDef false "printExprRaw" ((PCon "EIndex" (PVar "e") (PVar "i") PWild)) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "[")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "i"))) (EApp (EVar "text") (ELit (LString "]")))))))
(DFunDef false "printExprRaw" ((PCon "EMatch" (PVar "sc") (PVar "arms"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "match ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "sc"))) (EApp (EVar "printMatchArms") (EVar "arms")))))
(DFunDef false "printExprRaw" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "printGuardArms") (EVar "arms")))
(DFunDef false "printExprRaw" ((PCon "ESection" (PCon "SecBare" (PVar "op")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printExprRaw" ((PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EVar "text") (ELit (LString ")"))))))))
(DFunDef false "printExprRaw" ((PCon "ESection" (PCon "SecLeft" (PVar "e") (PVar "op")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EVar "text") (ELit (LString " _)"))))))))
(DFunDef false "printExprRaw" ((PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "@")))) (EApp (EApp (EVar "printExpr") (EVar "precAtom")) (EVar "e")))))
(DFunDef false "printExprRaw" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "indentBlock") (EApp (EApp (EVar "sepBy") (EVar "Hardline")) (EApp (EApp (EMethodRef "map") (EVar "printDoStmt")) (EVar "stmts")))))
(DFunDef false "printExprRaw" ((PCon "EDo" (PVar "stmts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "do")))) (EApp (EVar "indentBlock") (EApp (EApp (EVar "sepBy") (EVar "Hardline")) (EApp (EApp (EMethodRef "map") (EVar "printDoStmt")) (EVar "stmts"))))))
(DFunDef false "printExprRaw" ((PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "printType") (EVar "t")))))
(DFunDef false "printExprRaw" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))
(DFunDef false "printExprRaw" ((PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EBinOp "+" (EVar "precInfix") (ELit (LInt 1)))) (EVar "l"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " `")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "` ")))) (EApp (EApp (EVar "printExpr") (EBinOp "+" (EVar "precInfix") (ELit (LInt 1)))) (EVar "r")))))))
(DFunDef false "printExprRaw" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "\"")))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (EVar "interpPartDoc")) (EVar "parts")))) (EApp (EVar "text") (ELit (LString "\""))))))
(DFunDef false "printExprRaw" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "[")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "lo"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "incl") (ELit (LString "..=")) (ELit (LString ".."))))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "hi"))) (EApp (EVar "text") (ELit (LString "]"))))))))
(DFunDef false "printExprRaw" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "[|")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "lo"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "incl") (ELit (LString "..=")) (ELit (LString ".."))))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "hi"))) (EApp (EVar "text") (ELit (LString "|]"))))))))
(DFunDef false "printExprRaw" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "incl") PWild)) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ".[")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "lo"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "incl") (ELit (LString "..=")) (ELit (LString ".."))))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "hi"))) (EApp (EVar "text") (ELit (LString "]")))))))))
(DFunDef false "printExprRaw" ((PCon "EVarAt" (PVar "n") PWild)) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" ((PCon "EMethodAt" (PVar "n") PWild PWild PWild)) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" ((PCon "EDictAt" (PVar "n") PWild)) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "printExprRaw") (EVar "e")))
(DTypeSig false "printELet" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc")))))))
(DFunDef false "printELet" ((PVar "isMut") (PCon "True") (PCon "PVar" (PVar "f")) (PVar "rhs") (PVar "e2")) (EBlock (DoLet false false (PVar "argsBody") (EApp (EApp (EVar "unwrapLams") (EListLit)) (EVar "rhs"))) (DoExpr (EMatch (EVar "argsBody") (arm (PTuple (PVar "args") (PVar "body")) () (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "isMut") (ELit (LString "let mut ")) (ELit (LString "let "))))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "f"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "args")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "body"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " in ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e2")))))))))))))
(DFunDef false "printELet" ((PVar "isMut") PWild (PVar "pat") (PVar "e1") (PVar "e2")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "let ")))) (EApp (EApp (EVar "Cat") (EIf (EVar "isMut") (EApp (EVar "text") (ELit (LString "mut "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "pat"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e1"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " in ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e2")))))))))
(DTypeSig false "unwrapLams" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "unwrapLams" ((PVar "acc") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "unwrapLams") (EVar "acc")) (EVar "e")))
(DFunDef false "unwrapLams" ((PVar "acc") (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "unwrapLams") (EBinOp "++" (EVar "acc") (EVar "pats"))) (EVar "body")))
(DFunDef false "unwrapLams" ((PVar "acc") (PVar "body")) (ETuple (EVar "acc") (EVar "body")))
(DTypeSig false "letGroupClauses" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Doc")))
(DFunDef false "letGroupClauses" ((PVar "bindings")) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (EVar "letBindClauses")) (EVar "bindings"))))
(DTypeSig false "letBindClauses" (TyFun (TyCon "LetBind") (TyCon "Doc")))
(DFunDef false "letBindClauses" ((PCon "LetBind" (PVar "name") (PVar "clauses"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (EApp (EVar "letGroupClause") (EVar "name"))) (EVar "clauses"))))
(DTypeSig false "letGroupClause" (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyCon "Doc"))))
(DFunDef false "letGroupClause" ((PVar "name") (PCon "FunClause" (PVar "pats") (PVar "rhs"))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))) (EApp (EVar "letGroupClauseRhs") (EVar "rhs"))))))
(DTypeSig false "letGroupClauseRhs" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "letGroupClauseRhs" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "printGuardArms") (EVar "arms")))
(DFunDef false "letGroupClauseRhs" ((PVar "rhs")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "rhs"))))
(DTypeSig false "printEIf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc")))))
(DFunDef false "printEIf" ((PVar "c") (PVar "t") (PVar "e")) (EIf (EBinOp "||" (EApp (EVar "isBlockBody") (EVar "t")) (EApp (EVar "isBlockBody") (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "if ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "ifBranch") (ELit (LString "then"))) (EVar "t"))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "ifBranch") (ELit (LString "else"))) (EVar "e"))))))) (EIf (EVar "otherwise") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "if ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " then ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "t"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " else ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "printIfBody" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc")))))
(DFunDef false "printIfBody" ((PVar "c") (PVar "t") (PVar "e")) (EIf (EBinOp "||" (EApp (EVar "isBlockBody") (EVar "t")) (EApp (EVar "isBlockBody") (EVar "e"))) (EApp (EApp (EApp (EVar "printEIf") (EVar "c")) (EVar "t")) (EVar "e")) (EIf (EVar "otherwise") (EApp (EVar "group") (EApp (EApp (EApp (EVar "ifRhsBody") (EVar "c")) (EVar "t")) (EApp (EApp (EVar "ifRhsElsePart") (EApp (EVar "isUnitLit") (EVar "e"))) (EVar "e")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isDoMatchFnBody" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isDoMatchFnBody" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "isDoMatchFnBody") (EVar "e")))
(DFunDef false "isDoMatchFnBody" ((PCon "EDo" PWild)) (EVar "True"))
(DFunDef false "isDoMatchFnBody" ((PCon "EMatch" PWild PWild)) (EVar "True"))
(DFunDef false "isDoMatchFnBody" (PWild) (EVar "False"))
(DTypeSig false "ifBranch" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "ifBranch" ((PVar "kw") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "kw"))) (EApp (EVar "printExprBody") (EApp (EVar "EBlock") (EVar "stmts")))))
(DFunDef false "ifBranch" ((PVar "kw") (PVar "b")) (EIf (EApp (EVar "isDoMatchFnBody") (EVar "b")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "kw"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printExprBody") (EVar "b")))) (EIf (EApp (EVar "isBlockBody") (EVar "b")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "kw"))) (EApp (EVar "indentBlock") (EApp (EVar "printExprBody") (EVar "b")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "kw"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "b")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "printExprBody" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printExprBody" ((PVar "e")) (EApp (EApp (EVar "printExprBodyW") (EVar "True")) (EVar "e")))
(DTypeSig false "printExprBodyW" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "printExprBodyW" ((PVar "wrapApp") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "printExprBodyW") (EVar "wrapApp")) (EVar "e")))
(DFunDef false "printExprBodyW" (PWild (PCon "EMatch" (PVar "sc") (PVar "arms"))) (EApp (EVar "printExprRaw") (EApp (EApp (EVar "EMatch") (EVar "sc")) (EVar "arms"))))
(DFunDef false "printExprBodyW" (PWild (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "printExprRaw") (EApp (EVar "EBlock") (EVar "stmts"))))
(DFunDef false "printExprBodyW" (PWild (PCon "EDo" (PVar "stmts"))) (EApp (EVar "printExprRaw") (EApp (EVar "EDo") (EVar "stmts"))))
(DFunDef false "printExprBodyW" ((PVar "wrapApp") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "rf"))) (EIf (EApp (EVar "isContinuationOp") (EVar "op")) (EApp (EApp (EVar "printChain") (EVar "op")) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "rf"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "rf"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "printExprBodyW" ((PCon "True") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "printAppSpine") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))))
(DFunDef false "printExprBodyW" ((PVar "wrapApp") (PCon "EIf" (PVar "c") (PVar "t") (PVar "els"))) (EIf (EApp (EVar "isUnitLit") (EVar "els")) (EBlock (DoLet false false (PVar "thenPart") (EApp (EVar "elseLessThen") (EVar "t"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "if ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " then")))) (EVar "thenPart")))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "printIfBody") (EVar "c")) (EVar "t")) (EVar "els")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "printExprBodyW" (PWild (PVar "e")) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))
(DTypeSig false "elseLessThen" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "elseLessThen" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "elseLessThen") (EVar "e")))
(DFunDef false "elseLessThen" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "printExprBody") (EApp (EVar "EBlock") (EVar "stmts"))))
(DFunDef false "elseLessThen" ((PVar "t")) (EIf (EApp (EVar "isBlockBody") (EVar "t")) (EApp (EVar "indentBlock") (EApp (EVar "printExprBody") (EVar "t"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "t"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "printIfRhs" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Doc"))))
(DFunDef false "printIfRhs" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "printIfRhs") (EVar "e")))
(DFunDef false "printIfRhs" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "els"))) (EBlock (DoLet false false (PVar "isUnit") (EApp (EVar "isUnitLit") (EVar "els"))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isBlockBody") (EVar "t"))) (EBinOp "||" (EVar "isUnit") (EApp (EVar "not") (EApp (EVar "isBlockBody") (EVar "els"))))) (EApp (EVar "Some") (EApp (EVar "group") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EApp (EVar "ifRhsBody") (EVar "c")) (EVar "t")) (EApp (EApp (EVar "ifRhsElsePart") (EVar "isUnit")) (EVar "els"))))))) (EVar "None")))))
(DFunDef false "printIfRhs" (PWild) (EVar "None"))
(DTypeSig false "ifRhsBody" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Doc") (TyCon "Doc")))))
(DFunDef false "ifRhsBody" ((PVar "c") (PVar "t") (PVar "elsePart")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "if ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " then")))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "t"))))) (EVar "elsePart"))))))
(DTypeSig false "ifRhsElsePart" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "ifRhsElsePart" ((PCon "True") PWild) (EVar "Nil"))
(DFunDef false "ifRhsElsePart" ((PCon "False") (PCon "ELoc" PWild (PVar "els"))) (EApp (EApp (EVar "ifRhsElsePart") (EVar "False")) (EVar "els")))
(DFunDef false "ifRhsElsePart" ((PCon "False") (PCon "EIf" (PVar "c2") (PVar "t2") (PVar "els2"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isBlockBody") (EVar "t2"))) (EBinOp "||" (EApp (EVar "isUnitLit") (EVar "els2")) (EApp (EVar "not") (EApp (EVar "isBlockBody") (EVar "els2"))))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "else if ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "c2"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " then")))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "t2"))))) (EApp (EApp (EVar "ifRhsElsePart") (EApp (EVar "isUnitLit") (EVar "els2"))) (EVar "els2"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "ifRhsElsePart" ((PCon "False") (PVar "els")) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "else")))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "els")))))))
(DTypeSig false "printChain" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "printChain" ((PVar "op") (PVar "e")) (EBlock (DoLet false false (PVar "prec") (EApp (EVar "binopPrec") (EVar "op"))) (DoLet false false (PVar "headRights") (EApp (EApp (EApp (EVar "collectChain") (EVar "op")) (EListLit)) (EVar "e"))) (DoExpr (EMatch (EVar "headRights") (arm (PTuple (PVar "head") (PVar "rights")) () (EBlock (DoLet false false (PVar "tail") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "or")) (EApp (EApp (EVar "chainItem") (EVar "prec")) (EVar "or")))) (EVar "rights")))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "prec")) (EVar "head"))) (EVar "tail")))))))))))
(DTypeSig false "chainItem" (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "String") (TyCon "Expr")) (TyCon "Doc"))))
(DFunDef false "chainItem" ((PVar "prec") (PTuple (PVar "o") (PVar "r"))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "o"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "printExpr") (EBinOp "+" (EVar "prec") (ELit (LInt 1)))) (EVar "r"))))))
(DTypeSig false "collectChain" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr"))))))))
(DFunDef false "collectChain" ((PVar "op") (PVar "acc") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EApp (EVar "collectChain") (EVar "op")) (EVar "acc")) (EVar "e")))
(DFunDef false "collectChain" ((PVar "op") (PVar "acc") (PCon "EBinOp" (PVar "op2") (PVar "l") (PVar "r") (PVar "rf"))) (EIf (EBinOp "==" (EVar "op2") (EVar "op")) (EApp (EApp (EApp (EVar "collectChain") (EVar "op")) (EBinOp "::" (ETuple (EVar "op2") (EVar "r")) (EVar "acc"))) (EVar "l")) (EIf (EVar "otherwise") (ETuple (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op2")) (EVar "l")) (EVar "r")) (EVar "rf")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "collectChain" (PWild (PVar "acc") (PVar "head")) (ETuple (EVar "head") (EVar "acc")))
(DTypeSig true "declChainLen" (TyFun (TyCon "Decl") (TyCon "Int")))
(DFunDef false "declChainLen" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "declChainLen") (EVar "inner")))
(DFunDef false "declChainLen" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "chainLenBody") (EVar "body")))
(DFunDef false "declChainLen" (PWild) (ELit (LInt 0)))
(DTypeSig false "chainLenBody" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "chainLenBody" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "chainLenBody") (EVar "e")))
(DFunDef false "chainLenBody" ((PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "rf"))) (EIf (EApp (EVar "isContinuationOp") (EVar "op")) (EMatch (EApp (EApp (EApp (EVar "collectChain") (EVar "op")) (EListLit)) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "rf"))) (arm (PTuple PWild (PVar "rights")) () (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "listLen") (EVar "rights"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "chainLenBody" (PWild) (ELit (LInt 0)))
(DTypeSig false "opCommentDoc" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Doc")))
(DFunDef false "opCommentDoc" ((PCon "None")) (EVar "Nil"))
(DFunDef false "opCommentDoc" ((PCon "Some" (PVar "t"))) (EApp (EVar "LineComment") (EVar "t")))
(DTypeSig false "chainItemCommented" (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "String") (TyCon "Expr")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Doc")))))
(DFunDef false "chainItemCommented" ((PVar "prec") (PTuple (PVar "o") (PVar "r")) (PVar "cmt")) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "o"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EBinOp "+" (EVar "prec") (ELit (LInt 1)))) (EVar "r"))) (EApp (EVar "opCommentDoc") (EVar "cmt")))))))
(DTypeSig false "chainTailCommented" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc")))))
(DFunDef false "chainTailCommented" (PWild (PList) PWild) (EVar "Nil"))
(DFunDef false "chainTailCommented" ((PVar "prec") (PCons (PVar "r") (PVar "rs")) (PCons (PVar "c") (PVar "cs"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EApp (EVar "chainItemCommented") (EVar "prec")) (EVar "r")) (EVar "c"))) (EApp (EApp (EApp (EVar "chainTailCommented") (EVar "prec")) (EVar "rs")) (EVar "cs"))))
(DFunDef false "chainTailCommented" ((PVar "prec") (PCons (PVar "r") (PVar "rs")) (PList)) (EApp (EApp (EVar "Cat") (EApp (EApp (EApp (EVar "chainItemCommented") (EVar "prec")) (EVar "r")) (EVar "None"))) (EApp (EApp (EApp (EVar "chainTailCommented") (EVar "prec")) (EVar "rs")) (EListLit))))
(DTypeSig false "printChainCommentedRhs" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc")))))
(DFunDef false "printChainCommentedRhs" ((PVar "op") (PVar "e") (PVar "comments")) (EBlock (DoLet false false (PVar "prec") (EApp (EVar "binopPrec") (EVar "op"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "collectChain") (EVar "op")) (EListLit)) (EVar "e")) (arm (PTuple (PVar "head") (PVar "rights")) () (EBlock (DoLet false false (PVar "headCmt") (EMatch (EVar "comments") (arm (PCons (PVar "h") PWild) () (EVar "h")) (arm (PList) () (EVar "None")))) (DoLet false false (PVar "restCmts") (EMatch (EVar "comments") (arm (PCons PWild (PVar "t")) () (EVar "t")) (arm (PList) () (EListLit)))) (DoLet false false (PVar "body") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "prec")) (EVar "head"))) (EApp (EApp (EVar "Cat") (EApp (EVar "opCommentDoc") (EVar "headCmt"))) (EApp (EApp (EApp (EVar "chainTailCommented") (EVar "prec")) (EVar "rights")) (EVar "restCmts"))))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EVar "body")))))))))))
(DTypeSig true "printDeclChainCommented" (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc"))))
(DFunDef false "printDeclChainCommented" ((PCon "DAttrib" (PVar "attrs") (PVar "inner")) (PVar "comments")) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (EVar "attrDoc")) (EVar "attrs")))) (EApp (EApp (EVar "printDeclChainCommented") (EVar "inner")) (EVar "comments"))))
(DFunDef false "printDeclChainCommented" ((PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "pats") (PVar "body")) (PVar "comments")) (EBlock (DoLet false false (PVar "header") (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))))) (DoExpr (EApp (EApp (EVar "Cat") (EVar "header")) (EApp (EApp (EVar "printDefChainRhs") (EVar "body")) (EVar "comments"))))))
(DFunDef false "printDeclChainCommented" ((PVar "d") PWild) (EApp (EVar "printDecl") (EVar "d")))
(DTypeSig false "printDefChainRhs" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc"))))
(DFunDef false "printDefChainRhs" ((PCon "ELoc" PWild (PVar "e")) (PVar "comments")) (EApp (EApp (EVar "printDefChainRhs") (EVar "e")) (EVar "comments")))
(DFunDef false "printDefChainRhs" ((PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "rf")) (PVar "comments")) (EIf (EApp (EVar "isContinuationOp") (EVar "op")) (EApp (EApp (EApp (EVar "printChainCommentedRhs") (EVar "op")) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "rf"))) (EVar "comments")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "printDefChainRhs" ((PVar "body") PWild) (EApp (EVar "printDefRhs") (EVar "body")))
(DTypeSig true "declBlockLen" (TyFun (TyCon "Decl") (TyCon "Int")))
(DFunDef false "declBlockLen" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "declBlockLen") (EVar "inner")))
(DFunDef false "declBlockLen" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "blockLenBody") (EVar "body")))
(DFunDef false "declBlockLen" (PWild) (ELit (LInt 0)))
(DTypeSig false "blockLenBody" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "blockLenBody" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "blockLenBody") (EVar "e")))
(DFunDef false "blockLenBody" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "listLen") (EVar "stmts")))
(DFunDef false "blockLenBody" ((PCon "EDo" (PVar "stmts"))) (EApp (EVar "listLen") (EVar "stmts")))
(DFunDef false "blockLenBody" (PWild) (ELit (LInt 0)))
(DTypeSig false "headOpt" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headOpt" ((PCons (PVar "x") PWild)) (EVar "x"))
(DFunDef false "headOpt" ((PList)) (EVar "None"))
(DTypeSig false "tailOpt" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "tailOpt" ((PCons PWild (PVar "t"))) (EVar "t"))
(DFunDef false "tailOpt" ((PList)) (EListLit))
(DTypeSig false "stmtsCommented" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc"))))
(DFunDef false "stmtsCommented" ((PList) PWild) (EVar "Nil"))
(DFunDef false "stmtsCommented" ((PList (PVar "st")) (PVar "cs")) (EApp (EApp (EVar "Cat") (EApp (EVar "printDoStmt") (EVar "st"))) (EApp (EVar "opCommentDoc") (EApp (EVar "headOpt") (EVar "cs")))))
(DFunDef false "stmtsCommented" ((PCons (PVar "st") (PVar "rest")) (PVar "cs")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "Cat") (EApp (EVar "printDoStmt") (EVar "st"))) (EApp (EVar "opCommentDoc") (EApp (EVar "headOpt") (EVar "cs"))))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "stmtsCommented") (EVar "rest")) (EApp (EVar "tailOpt") (EVar "cs"))))))
(DTypeSig false "printBlockCommentedRhs" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc"))))
(DFunDef false "printBlockCommentedRhs" ((PCon "ELoc" PWild (PVar "e")) (PVar "comments")) (EApp (EApp (EVar "printBlockCommentedRhs") (EVar "e")) (EVar "comments")))
(DFunDef false "printBlockCommentedRhs" ((PCon "EBlock" (PVar "stmts")) (PVar "comments")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "indentBlock") (EApp (EApp (EVar "stmtsCommented") (EVar "stmts")) (EVar "comments")))))
(DFunDef false "printBlockCommentedRhs" ((PCon "EDo" (PVar "stmts")) (PVar "comments")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "do")))) (EApp (EVar "indentBlock") (EApp (EApp (EVar "stmtsCommented") (EVar "stmts")) (EVar "comments"))))))
(DFunDef false "printBlockCommentedRhs" ((PVar "body") PWild) (EApp (EVar "printDefRhs") (EVar "body")))
(DTypeSig true "printDeclBlockCommented" (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc"))))
(DFunDef false "printDeclBlockCommented" ((PCon "DAttrib" (PVar "attrs") (PVar "inner")) (PVar "comments")) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (EVar "attrDoc")) (EVar "attrs")))) (EApp (EApp (EVar "printDeclBlockCommented") (EVar "inner")) (EVar "comments"))))
(DFunDef false "printDeclBlockCommented" ((PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "pats") (PVar "body")) (PVar "comments")) (EBlock (DoLet false false (PVar "header") (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))))) (DoExpr (EApp (EApp (EVar "Cat") (EVar "header")) (EApp (EApp (EVar "printBlockCommentedRhs") (EVar "body")) (EVar "comments"))))))
(DFunDef false "printDeclBlockCommented" ((PVar "d") PWild) (EApp (EVar "printDecl") (EVar "d")))
(DTypeSig false "printAppSpine" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printAppSpine" ((PVar "e")) (EBlock (DoLet false false (PVar "headArgs") (EApp (EApp (EVar "collectApp") (EListLit)) (EVar "e"))) (DoExpr (EMatch (EVar "headArgs") (arm (PTuple (PVar "head") (PList)) () (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (arm (PTuple (PVar "head") (PList (PVar "arg"))) () (EIf (EApp (EVar "isBreakableArg") (EVar "arg")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precApp")) (EVar "head"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "breakableArg") (EVar "arg")))) (EApp (EVar "group") (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precApp")) (EVar "head"))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "arg")))))))) (arm (PTuple (PVar "head") (PVar "args")) () (EBlock (DoLet false false (PVar "tail") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "spineArg") (EVar "a"))))) (EVar "args")))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precApp")) (EVar "head"))) (EVar "tail")))))))))))
(DTypeSig false "spineArg" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "spineArg" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "spineArg") (EVar "e")))
(DFunDef false "spineArg" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printAppSpine") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "spineArg" ((PVar "e")) (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "e")))
(DTypeSig false "isBreakableArg" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isBreakableArg" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "isBreakableArg") (EVar "e")))
(DFunDef false "isBreakableArg" ((PCon "ELam" PWild PWild)) (EVar "True"))
(DFunDef false "isBreakableArg" ((PCon "EApp" (PVar "f") (PVar "x"))) (EVar "True"))
(DFunDef false "isBreakableArg" (PWild) (EVar "False"))
(DTypeSig false "breakableArg" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "breakableArg" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "breakableArg") (EVar "e")))
(DFunDef false "breakableArg" ((PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EMethodRef "map") (EVar "printPatAtom")) (EVar "pats")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =>")))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "printExprBody") (EVar "body"))))) (EApp (EVar "text") (ELit (LString ")")))))))))
(DFunDef false "breakableArg" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printAppSpine") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "breakableArg" ((PVar "e")) (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "e")))
(DTypeSig false "collectApp" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "collectApp" ((PVar "acc") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "collectApp") (EBinOp "::" (EVar "x") (EVar "acc"))) (EVar "f")))
(DFunDef false "collectApp" ((PVar "acc") (PVar "head")) (ETuple (EVar "head") (EVar "acc")))
(DTypeSig false "printMatchArms" (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Doc")))
(DFunDef false "printMatchArms" ((PVar "arms")) (EApp (EVar "indentBlock") (EApp (EApp (EVar "sepBy") (EVar "Hardline")) (EApp (EApp (EMethodRef "map") (EVar "matchArmDoc")) (EVar "arms")))))
(DTypeSig false "matchArmDoc" (TyFun (TyCon "Arm") (TyCon "Doc")))
(DFunDef false "matchArmDoc" ((PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPatArm") (EVar "pat"))) (EApp (EApp (EVar "Cat") (EApp (EVar "matchGuardsDoc") (EVar "guards"))) (EApp (EVar "matchBodyDoc") (EVar "body")))))
(DTypeSig false "matchGuardsDoc" (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "Doc")))
(DFunDef false "matchGuardsDoc" ((PList)) (EVar "Nil"))
(DFunDef false "matchGuardsDoc" ((PVar "guards")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " if ")))) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "guardDoc")) (EVar "guards")))))
(DTypeSig false "matchBodyDoc" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "matchBodyDoc" ((PVar "body")) (EMatch (EApp (EVar "printIfRhs") (EVar "body")) (arm (PCon "Some" (PVar "g")) () (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =>")))) (EVar "g"))) (arm (PCon "None") () (EApp (EVar "matchBodyNoIf") (EVar "body")))))
(DTypeSig false "matchBodyNoIf" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "matchBodyNoIf" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "matchBodyNoIf") (EVar "e")))
(DFunDef false "matchBodyNoIf" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =>")))) (EApp (EApp (EVar "printExprBodyW") (EVar "False")) (EApp (EVar "EBlock") (EVar "stmts")))))
(DFunDef false "matchBodyNoIf" ((PVar "body")) (EIf (EApp (EVar "breakAtSepBody") (EVar "body")) (EApp (EApp (EVar "hangAtSep") (ELit (LString " =>"))) (EApp (EApp (EVar "printExprBodyW") (EVar "False")) (EVar "body"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " => ")))) (EApp (EApp (EVar "printExprBodyW") (EVar "False")) (EVar "body"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "guardDoc" (TyFun (TyCon "Guard") (TyCon "Doc")))
(DFunDef false "guardDoc" ((PCon "GBool" (PVar "g"))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "g")))
(DFunDef false "guardDoc" ((PCon "GBind" (PVar "gp") (PVar "g"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "gp"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " <- ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "g")))))
(DTypeSig false "printGuardArms" (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyCon "Doc")))
(DFunDef false "printGuardArms" ((PVar "arms")) (EApp (EVar "indentBlock") (EApp (EApp (EVar "sepBy") (EVar "Hardline")) (EApp (EApp (EMethodRef "map") (EVar "guardArmDoc")) (EVar "arms")))))
(DTypeSig false "guardArmDoc" (TyFun (TyCon "GuardArm") (TyCon "Doc")))
(DFunDef false "guardArmDoc" ((PCon "GuardArm" (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PVar "hd") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "| ")))) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "guardDoc")) (EVar "guards"))))) (DoExpr (EApp (EApp (EVar "Cat") (EVar "hd")) (EApp (EVar "guardArmBodyDoc") (EVar "body"))))))
(DTypeSig false "guardArmBodyDoc" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "guardArmBodyDoc" ((PVar "body")) (EMatch (EApp (EVar "printIfRhs") (EVar "body")) (arm (PCon "Some" (PVar "g")) () (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EVar "g"))) (arm (PCon "None") () (EApp (EVar "guardArmBodyNoIf") (EVar "body")))))
(DTypeSig false "guardArmBodyNoIf" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "guardArmBodyNoIf" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EApp (EVar "printExprBodyW") (EVar "False")) (EApp (EVar "EBlock") (EVar "stmts")))))
(DFunDef false "guardArmBodyNoIf" ((PVar "body")) (EIf (EApp (EVar "breakAtSepBody") (EVar "body")) (EApp (EApp (EVar "hangAtSep") (ELit (LString " ="))) (EApp (EApp (EVar "printExprBodyW") (EVar "False")) (EVar "body"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "printExprBodyW") (EVar "False")) (EVar "body"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "doLetRhs" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "doLetRhs" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "doLetRhs") (EVar "e")))
(DFunDef false "doLetRhs" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "els"))) (EIf (EApp (EVar "not") (EApp (EVar "isUnitLit") (EVar "els"))) (EApp (EApp (EApp (EVar "printIfBody") (EVar "c")) (EVar "t")) (EVar "els")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "doLetRhs" ((PVar "e")) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))
(DTypeSig false "printDoStmt" (TyFun (TyCon "DoStmt") (TyCon "Doc")))
(DFunDef false "printDoStmt" ((PCon "DoBind" (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "pat"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " <- ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))))
(DFunDef false "printDoStmt" ((PCon "DoExpr" (PVar "e"))) (EMatch (EVar "e") (arm (PCon "EIf" (PVar "c") (PVar "t") (PVar "els")) () (EIf (EApp (EVar "isUnitLit") (EVar "els")) (EBlock (DoLet false false (PVar "thenPart") (EApp (EVar "elseLessThen") (EVar "t"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "if ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " then")))) (EVar "thenPart")))))) (EApp (EVar "printExprBody") (EVar "e")))) (arm PWild () (EApp (EVar "printExprBody") (EVar "e")))))
(DFunDef false "printDoStmt" ((PCon "DoLet" (PVar "isMut") PWild (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "let ")))) (EApp (EApp (EVar "Cat") (EIf (EVar "isMut") (EApp (EVar "text") (ELit (LString "mut "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "pat"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "doLetRhs") (EVar "e")))))))
(DFunDef false "printDoStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))))
(DFunDef false "printDoStmt" ((PCon "DoFieldAssign" (PVar "x") (PVar "fields") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ".")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "fields")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))))))
(DTypeSig false "interpPartDoc" (TyFun (TyCon "InterpPart") (TyCon "Doc")))
(DFunDef false "interpPartDoc" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "text") (EApp (EVar "stringEscaped") (EVar "s"))))
(DFunDef false "interpPartDoc" ((PCon "InterpExpr" (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "\\{")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EVar "text") (ELit (LString "}"))))))
(DTypeSig false "fieldAssignDoc" (TyFun (TyCon "FieldAssign") (TyCon "Doc")))
(DFunDef false "fieldAssignDoc" ((PCon "FieldAssign" (PVar "k") (PVar "v"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "k"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "v")))))
(DTypeSig false "mapKvDoc" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyCon "Doc")))
(DFunDef false "mapKvDoc" ((PTuple (PVar "k") (PVar "v"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "k"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " => ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "v")))))
(DTypeSig false "stringEscaped" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stringEscaped" ((PVar "s")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "escEChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0)))))
(DTypeSig false "escEChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "escEChars" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "escSOne") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EVar "escEChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "printDefRhs" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printDefRhs" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "printDefRhs") (EVar "e")))
(DFunDef false "printDefRhs" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "printGuardArms") (EVar "arms")))
(DFunDef false "printDefRhs" ((PCon "ELetGroup" (PVar "binds") (PVar "inner"))) (EIf (EApp (EVar "isGuardsBody") (EVar "inner")) (EApp (EVar "printExprBody") (EApp (EApp (EVar "ELetGroup") (EVar "binds")) (EVar "inner"))) (EIf (EVar "otherwise") (EApp (EVar "printDefRhsGeneral") (EApp (EApp (EVar "ELetGroup") (EVar "binds")) (EVar "inner"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "printDefRhs" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "printExprBody") (EApp (EVar "EBlock") (EVar "stmts")))))
(DFunDef false "printDefRhs" ((PVar "body")) (EApp (EVar "printDefRhsGeneral") (EVar "body")))
(DTypeSig false "isGuardsBody" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isGuardsBody" ((PCon "EGuards" PWild)) (EVar "True"))
(DFunDef false "isGuardsBody" (PWild) (EVar "False"))
(DTypeSig false "printDefRhsGeneral" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printDefRhsGeneral" ((PVar "body")) (EMatch (EApp (EVar "printIfRhs") (EVar "body")) (arm (PCon "Some" (PVar "g")) () (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EVar "g"))) (arm (PCon "None") () (EMatch (EVar "body") (arm (PCon "EMatch" (PVar "sc") (PVar "arms")) () (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "printExprBody") (EApp (EApp (EVar "EMatch") (EVar "sc")) (EVar "arms"))))) (arm (PCon "EDo" (PVar "stmts")) () (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "printExprBody") (EApp (EVar "EDo") (EVar "stmts"))))) (arm (PCon "EApp" (PVar "f") (PVar "x")) () (EIf (EApp (EVar "appHasSelfIndentingArg") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EApp (EVar "bodyBreakAtEq") (EApp (EVar "printAppSpine") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (EApp (EApp (EVar "hangAlwaysAtSep") (ELit (LString " ="))) (EApp (EVar "printAppSpine") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))))) (arm (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "rf")) () (EIf (EApp (EVar "isContinuationOp") (EVar "op")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "printExprBody") (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "rf")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "group") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EApp (EVar "printBinOpTrailing") (EVar "op")) (EVar "l")) (EVar "r")))))))) (arm PWild () (EIf (EApp (EVar "isBlockBody") (EVar "body")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "indentBlock") (EApp (EVar "printExprBody") (EVar "body")))) (EApp (EVar "bodyBreakAtEq") (EApp (EVar "printExprBody") (EVar "body")))))))))
(DTypeSig false "bodyBreakAtEq" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "bodyBreakAtEq" ((PVar "bodyDoc")) (EApp (EApp (EVar "hangAtSep") (ELit (LString " ="))) (EVar "bodyDoc")))
(DTypeSig false "hangAtSep" (TyFun (TyCon "String") (TyFun (TyCon "Doc") (TyCon "Doc"))))
(DFunDef false "hangAtSep" ((PVar "sep") (PVar "bodyDoc")) (EApp (EVar "FlatGroup") (EApp (EApp (EVar "FlatAlt") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "sep"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EVar "bodyDoc")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "sep"))) (EApp (EVar "group") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EVar "bodyDoc"))))))))
(DTypeSig false "hangAlwaysAtSep" (TyFun (TyCon "String") (TyFun (TyCon "Doc") (TyCon "Doc"))))
(DFunDef false "hangAlwaysAtSep" ((PVar "sep") (PVar "bodyDoc")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "sep"))) (EApp (EVar "group") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EVar "bodyDoc"))))))
(DTypeSig false "isSelfIndentingArg" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isSelfIndentingArg" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "isSelfIndentingArg") (EVar "e")))
(DFunDef false "isSelfIndentingArg" ((PCon "ELam" PWild PWild)) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EBlock" PWild)) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EDo" PWild)) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EMatch" PWild PWild)) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EIf" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "ERecordCreate" PWild PWild)) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "ERecordUpdate" PWild PWild)) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EVariantUpdate" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EListLit" (PCons PWild PWild))) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EArrayLit" (PCons PWild PWild))) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "ETuple" (PCons PWild PWild))) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EMapLit" PWild (PCons PWild PWild))) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "ESetLit" PWild (PCons PWild PWild))) (EVar "True"))
(DFunDef false "isSelfIndentingArg" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "appHasSelfIndentingArg") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))))
(DFunDef false "isSelfIndentingArg" (PWild) (EVar "False"))
(DTypeSig false "appHasSelfIndentingArg" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "appHasSelfIndentingArg" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appHasSelfIndentingArg") (EVar "e")))
(DFunDef false "appHasSelfIndentingArg" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "||" (EApp (EVar "isSelfIndentingArg") (EVar "x")) (EApp (EVar "appHasSelfIndentingArg") (EVar "f"))))
(DFunDef false "appHasSelfIndentingArg" (PWild) (EVar "False"))
(DTypeSig false "printBinOpTrailing" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc")))))
(DFunDef false "printBinOpTrailing" ((PVar "op") (PVar "l") (PVar "r")) (EBlock (DoLet false false (PVar "prec") (EApp (EVar "binopPrec") (EVar "op"))) (DoLet false false (PVar "ra") (EApp (EVar "isRightAssoc") (EVar "op"))) (DoLet false false (PVar "lp") (EIf (EVar "ra") (EBinOp "+" (EVar "prec") (ELit (LInt 1))) (EVar "prec"))) (DoLet false false (PVar "rp") (EIf (EVar "ra") (EVar "prec") (EBinOp "+" (EVar "prec") (ELit (LInt 1))))) (DoLet false false (PVar "afterOp") (EIf (EApp (EApp (EApp (EVar "consTight") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "Softline") (EVar "Line"))) (DoExpr (EApp (EVar "group") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printOperand") (EVar "lp")) (EVar "l"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EApp (EVar "binopSpace") (EVar "op")) (EVar "l")) (EVar "r"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EApp (EVar "Cat") (EVar "afterOp")) (EApp (EApp (EVar "printOperand") (EVar "rp")) (EVar "r")))))))))))
(DTypeSig false "printOperand" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "printOperand" ((PVar "prec") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "printOperand") (EVar "prec")) (EVar "e")))
(DFunDef false "printOperand" ((PVar "prec") (PCon "EApp" (PVar "f") (PVar "x"))) (EIf (EBinOp "<" (EApp (EVar "exprPrec") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EVar "prec")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printAppSpine") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (EApp (EVar "text") (ELit (LString ")"))))) (EApp (EVar "printAppSpine") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))))
(DFunDef false "printOperand" ((PVar "prec") (PVar "e")) (EApp (EApp (EVar "printExpr") (EVar "prec")) (EVar "e")))
(DTypeSig false "printUsePath" (TyFun (TyCon "UsePath") (TyCon "Doc")))
(DFunDef false "printUsePath" ((PCon "UseName" (PVar "names"))) (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "names"))))
(DFunDef false "printUsePath" ((PCon "UseGroup" (PVar "names") (PVar "members"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "names")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ".")))) (EApp (EApp (EApp (EVar "delimitedG") (ELit (LString "{"))) (ELit (LString "}"))) (EApp (EApp (EMethodRef "map") (EVar "useMemberDoc")) (EVar "members"))))))
(DFunDef false "printUsePath" ((PCon "UseWild" (PVar "names"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "names")))) (EApp (EVar "text") (ELit (LString ".*")))))
(DFunDef false "printUsePath" ((PCon "UseAlias" (PVar "names") (PVar "alias"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "names")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " as ")))) (EApp (EVar "text") (EVar "alias")))))
(DTypeSig false "useMemberDoc" (TyFun (TyCon "UseMember") (TyCon "Doc")))
(DFunDef false "useMemberDoc" ((PCon "UseMember" (PVar "n") (PVar "allCtors") PWild (PVar "alias"))) (EBlock (DoLet false false (PVar "base") (EIf (EVar "allCtors") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "text") (ELit (LString "(..)")))) (EApp (EVar "text") (EVar "n")))) (DoExpr (EMatch (EVar "alias") (arm (PCon "Some" (PVar "a")) () (EApp (EApp (EVar "Cat") (EVar "base")) (EApp (EVar "text") (EBinOp "++" (EBinOp "++" (ELit (LString " as ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))))) (arm (PCon "None") () (EVar "base"))))))
(DTypeSig false "printVariant" (TyFun (TyCon "Variant") (TyCon "Doc")))
(DFunDef false "printVariant" ((PCon "Variant" (PVar "name") (PCon "ConPos" (PVar "tys")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "t"))))) (EVar "tys")))))
(DFunDef false "printVariant" ((PCon "Variant" (PVar "name") (PCon "ConNamed" (PVar "fields") (PVar "nameOmitted")))) (EBlock (DoLet false false (PVar "sep") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ",")))) (EVar "Line"))) (DoLet false false (PVar "trailing") (EApp (EApp (EVar "FlatAlt") (EApp (EVar "text") (ELit (LString ",")))) (EVar "Nil"))) (DoLet false false (PVar "namePart") (EIf (EVar "nameOmitted") (EVar "Nil") (EApp (EVar "text") (EVar "name")))) (DoLet false false (PVar "braceOpen") (EIf (EVar "nameOmitted") (EApp (EVar "text") (ELit (LString "{"))) (EApp (EVar "text") (ELit (LString " {"))))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EVar "namePart")) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "braceOpen")) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EVar "sep")) (EApp (EApp (EMethodRef "map") (EVar "fieldTyDoc")) (EVar "fields")))) (EVar "trailing"))))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "text") (ELit (LString "}"))))))))))))
(DTypeSig false "fieldTyDoc" (TyFun (TyCon "Field") (TyCon "Doc")))
(DFunDef false "fieldTyDoc" ((PCon "Field" (PVar "fn") (PVar "ft"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "fn"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "printType") (EVar "ft")))))
(DTypeSig true "printNamedFieldData" (TyFun (TyCon "DataVis") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Doc")))))))
(DFunDef false "printNamedFieldData" ((PVar "vis") (PVar "n") (PVar "params") (PList (PCon "Variant" (PVar "cname") (PCon "ConNamed" (PVar "fields") (PVar "nameOmitted")))) (PVar "derives")) (EBlock (DoLet false false (PVar "eqPart") (EIf (EVar "nameOmitted") (EApp (EVar "text") (ELit (LString " ="))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "text") (EVar "cname"))))) (DoLet false false (PVar "head") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "data ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "p"))))) (EVar "params")))) (EVar "eqPart"))))) (DoLet false false (PVar "body") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " {")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "Nest") (ELit (LInt 4))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EVar "fieldTyDoc") (EVar "f"))) (EApp (EVar "text") (ELit (LString ","))))))) (EVar "fields"))))) (EApp (EVar "indentBlock") (EApp (EVar "text") (ELit (LString "}"))))))) (DoLet false false (PVar "deriveDoc") (EIf (EApp (EVar "isEmptyL") (EVar "derives")) (EVar "Nil") (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "printDerives") (EVar "derives"))))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "visPrefix") (EVar "vis"))) (EApp (EApp (EVar "Cat") (EVar "head")) (EApp (EApp (EVar "Cat") (EVar "body")) (EVar "deriveDoc")))))))
(DFunDef false "printNamedFieldData" ((PVar "vis") (PVar "n") (PVar "params") (PVar "variants") (PVar "derives")) (EApp (EVar "printDecl") (EApp (EApp (EApp (EApp (EApp (EVar "DData") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "variants")) (EVar "derives"))))
(DTypeSig false "printDerives" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Doc")))
(DFunDef false "printDerives" ((PList)) (EVar "Nil"))
(DFunDef false "printDerives" ((PVar "derives")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "deriving (")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "derives")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DTypeSig false "visPrefix" (TyFun (TyCon "DataVis") (TyCon "Doc")))
(DFunDef false "visPrefix" ((PCon "VisPublic")) (EApp (EVar "text") (ELit (LString "public export "))))
(DFunDef false "visPrefix" ((PCon "VisAbstract")) (EApp (EVar "text") (ELit (LString "export "))))
(DFunDef false "visPrefix" ((PCon "VisPrivate")) (EVar "Nil"))
(DTypeSig false "dataVariantDocs" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Doc")))
(DFunDef false "dataVariantDocs" ((PList)) (EVar "Nil"))
(DFunDef false "dataVariantDocs" ((PCons (PVar "v") (PVar "vs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "FlatAlt") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "text") (ELit (LString "| "))))) (EApp (EVar "text") (ELit (LString " "))))) (EApp (EVar "printVariant") (EVar "v")))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "v2")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "FlatAlt") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "text") (ELit (LString "| "))))) (EApp (EVar "text") (ELit (LString " | "))))) (EApp (EVar "printVariant") (EVar "v2"))))) (EVar "vs")))))))
(DTypeSig true "printDataDeclCommented" (TyFun (TyCon "DataVis") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Doc"))))))))
(DFunDef false "printDataDeclCommented" ((PVar "vis") (PVar "n") (PVar "params") (PVar "variants") (PVar "derives") (PVar "vcomments")) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "data ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "p"))))) (EVar "params")))))) (DoLet false false (PVar "variantDocs") (EApp (EApp (EVar "dataVariantDocsCommented") (EVar "variants")) (EVar "vcomments"))) (DoLet false false (PVar "deriveDoc") (EIf (EApp (EVar "isEmptyL") (EVar "derives")) (EVar "Nil") (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "printDerives") (EVar "derives"))))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "visPrefix") (EVar "vis"))) (EApp (EApp (EVar "Cat") (EVar "head")) (EApp (EApp (EVar "Cat") (EVar "variantDocs")) (EVar "deriveDoc")))))))
(DTypeSig false "commentLinesDoc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Doc")))
(DFunDef false "commentLinesDoc" ((PVar "cs")) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "text") (EVar "c"))))) (EVar "cs"))))
(DTypeSig false "trailingCommentsDoc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Doc")))
(DFunDef false "trailingCommentsDoc" ((PVar "cs")) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "  ")))) (EApp (EVar "text") (EVar "c"))))) (EVar "cs"))))
(DTypeSig false "variantCommentedDoc" (TyFun (TyCon "Variant") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Doc"))))
(DFunDef false "variantCommentedDoc" ((PVar "v") (PTuple (PVar "leading") (PVar "trailing"))) (EApp (EApp (EVar "Cat") (EApp (EVar "commentLinesDoc") (EVar "leading"))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "| ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printVariant") (EVar "v"))) (EApp (EVar "trailingCommentsDoc") (EVar "trailing")))))))
(DTypeSig false "dataVariantDocsCommented" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Doc"))))
(DFunDef false "dataVariantDocsCommented" ((PList) PWild) (EVar "Nil"))
(DFunDef false "dataVariantDocsCommented" (PWild (PList)) (EVar "Nil"))
(DFunDef false "dataVariantDocsCommented" ((PCons (PVar "v") (PVar "vs")) (PCons (PVar "vc") (PVar "vcs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "variantCommentedDoc") (EVar "v")) (EVar "vc"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map2VariantComment") (EVar "vs")) (EVar "vcs")))))))
(DTypeSig false "map2VariantComment" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "Doc")))))
(DFunDef false "map2VariantComment" ((PList) PWild) (EListLit))
(DFunDef false "map2VariantComment" (PWild (PList)) (EListLit))
(DFunDef false "map2VariantComment" ((PCons (PVar "v") (PVar "vs")) (PCons (PVar "vc") (PVar "vcs"))) (EBinOp "::" (EApp (EApp (EVar "variantCommentedDoc") (EVar "v")) (EVar "vc")) (EApp (EApp (EVar "map2VariantComment") (EVar "vs")) (EVar "vcs"))))
(DTypeSig true "printDecl" (TyFun (TyCon "Decl") (TyCon "Doc")))
(DFunDef false "printDecl" ((PCon "DTypeSig" (PVar "pub") (PVar "n") (PVar "t"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "printType") (EVar "t"))))))
(DFunDef false "printDecl" ((PCon "DExtern" (PVar "pub") (PVar "n") (PVar "t"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "extern ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "printType") (EVar "t")))))))
(DFunDef false "printDecl" ((PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "header") (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))))) (DoExpr (EApp (EApp (EVar "Cat") (EVar "header")) (EApp (EVar "printDefRhs") (EVar "body"))))))
(DFunDef false "printDecl" ((PCon "DLetGroup" (PVar "pub") (PVar "bindings"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EVar "letGroupDecl") (EVar "bindings"))))
(DFunDef false "printDecl" ((PCon "DData" (PVar "vis") (PVar "n") (PVar "params") (PVar "variants") (PVar "derives"))) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "data ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "p"))))) (EVar "params")))))) (DoLet false false (PVar "variantDocs") (EApp (EVar "dataVariantDocs") (EVar "variants"))) (DoLet false false (PVar "deriveDoc") (EIf (EApp (EVar "isEmptyL") (EVar "derives")) (EVar "Nil") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "printDerives") (EVar "derives"))))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "visPrefix") (EVar "vis"))) (EApp (EApp (EVar "Cat") (EVar "head")) (EApp (EApp (EVar "Cat") (EVar "variantDocs")) (EVar "deriveDoc"))))))))
(DFunDef false "printDecl" ((PCon "DTypeAlias" (PVar "pub") (PVar "n") (PVar "params") (PVar "rhs"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "type ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "p"))))) (EVar "params")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "printType") (EVar "rhs"))))))))
(DFunDef false "printDecl" ((PCon "DNewtype" (PVar "pub") (PVar "n") (PVar "params") (PVar "con") (PVar "fty") (PVar "derives"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "newtype ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "p"))))) (EVar "params")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "con"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printTypeAtom") (EVar "fty"))) (EIf (EApp (EVar "isEmptyL") (EVar "derives")) (EVar "Nil") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " deriving (")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "derives")))) (EApp (EVar "text") (ELit (LString ")")))))))))))))))
(DFunDef false "printDecl" ((PRec "DInterface" ((rf "pub" None) (rf "def" None) (rf "name" None) (rf "typarams" None) (rf "supers" None) (rf "methods" None)) false)) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EIf (EVar "def") (EApp (EVar "text") (ELit (LString "default "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "interface ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "p"))))) (EVar "typarams")))) (EApp (EApp (EVar "Cat") (EApp (EVar "superDoc") (EVar "supers"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " where")))) (EApp (EVar "indentBlock") (EApp (EApp (EVar "sepBy") (EVar "Hardline")) (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodDoc")) (EVar "methods"))))))))))))
(DFunDef false "printDecl" ((PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "impl ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "implHead") (EVar "iface")) (EVar "tys"))) (EApp (EApp (EVar "Cat") (EApp (EVar "reqsDoc") (EVar "reqs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " where")))) (EApp (EVar "indentBlock") (EApp (EApp (EVar "sepBy") (EVar "Hardline")) (EApp (EApp (EMethodRef "map") (EVar "implMethodDoc")) (EVar "methods"))))))))))
(DFunDef false "printDecl" ((PCon "DUse" (PVar "pub") (PVar "path") PWild)) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "import ")))) (EApp (EVar "printUsePath") (EVar "path")))))
(DFunDef false "printDecl" ((PCon "DEffect" (PVar "pub") (PVar "name") (PVar "domain") (PVar "isInternal"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "effDeclHead") (EVar "pub")) (EVar "isInternal"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EVar "effDomainDoc") (EVar "domain")))))
(DFunDef false "printDecl" ((PCon "DProp" (PVar "pub") (PVar "propName") (PVar "propParams") (PVar "propBody"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "prop ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "escStringLit") (EVar "propName")))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (EVar "propParamDoc")) (EVar "propParams")))) (EApp (EVar "printDefRhs") (EVar "propBody")))))))
(DFunDef false "printDecl" ((PCon "DTest" (PVar "pub") (PVar "testName") (PVar "testBody"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "test ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "escStringLit") (EVar "testName")))) (EApp (EVar "printDefRhs") (EVar "testBody"))))))
(DFunDef false "printDecl" ((PCon "DBench" (PVar "pub") (PVar "benchName") (PVar "benchBody"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "bench ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "escStringLit") (EVar "benchName")))) (EApp (EVar "printDefRhs") (EVar "benchBody"))))))
(DFunDef false "printDecl" ((PCon "DAttrib" (PVar "attrs") (PVar "inner"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (EVar "attrDoc")) (EVar "attrs")))) (EApp (EVar "printDecl") (EVar "inner"))))
(DTypeSig false "propParamDoc" (TyFun (TyCon "PropParam") (TyCon "Doc")))
(DFunDef false "propParamDoc" ((PCon "PropParam" (PVar "x") (PVar "ty"))) (EApp (EVar "text") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppTy") (EVar "ty")))) (ELit (LString ")")))))
(DTypeSig false "attrDoc" (TyFun (TyCon "Attr") (TyCon "Doc")))
(DFunDef false "attrDoc" ((PCon "AttrDeprecated" (PVar "msg"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EBinOp "++" (ELit (LString "@deprecated ")) (EApp (EVar "escStringLit") (EVar "msg"))))) (EApp (EVar "text") (ELit (LString "\n")))))
(DFunDef false "attrDoc" ((PCon "AttrInline")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "@inline")))) (EApp (EVar "text") (ELit (LString "\n")))))
(DFunDef false "attrDoc" ((PCon "AttrMustUse")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "@must_use")))) (EApp (EVar "text") (ELit (LString "\n")))))
(DTypeSig false "letGroupDecl" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Doc")))
(DFunDef false "letGroupDecl" ((PVar "bindings")) (EBlock (DoLet false false (PVar "docs") (EApp (EApp (EVar "letGroupDeclGo") (EVar "True")) (EVar "bindings"))) (DoExpr (EApp (EVar "concatD") (EVar "docs")))))
(DTypeSig false "letGroupDeclGo" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyCon "Doc")))))
(DFunDef false "letGroupDeclGo" (PWild (PList)) (EListLit))
(DFunDef false "letGroupDeclGo" ((PVar "first") (PCons (PCon "LetBind" (PVar "name") (PVar "clauses")) (PVar "rest"))) (EBlock (DoLet false false (PVar "r") (EApp (EApp (EApp (EVar "letGroupBindClauses") (EVar "first")) (EVar "name")) (EVar "clauses"))) (DoExpr (EMatch (EVar "r") (arm (PTuple (PVar "docs") (PVar "nextFirst")) () (EBinOp "++" (EVar "docs") (EApp (EApp (EVar "letGroupDeclGo") (EVar "nextFirst")) (EVar "rest"))))))))
(DTypeSig false "letGroupBindClauses" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyTuple (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Bool"))))))
(DFunDef false "letGroupBindClauses" ((PVar "first") PWild (PList)) (ETuple (EListLit) (EVar "first")))
(DFunDef false "letGroupBindClauses" ((PVar "first") (PVar "name") (PCons (PVar "c") (PVar "cs"))) (EBlock (DoLet false false (PVar "d") (EApp (EApp (EApp (EVar "letGroupDeclClause") (EVar "first")) (EVar "name")) (EVar "c"))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EVar "letGroupBindClauses") (EVar "False")) (EVar "name")) (EVar "cs"))) (DoExpr (EMatch (EVar "r") (arm (PTuple (PVar "rest") (PVar "lastFirst")) () (ETuple (EBinOp "::" (EVar "d") (EVar "rest")) (EVar "lastFirst")))))))
(DTypeSig false "letGroupDeclClause" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyCon "Doc")))))
(DFunDef false "letGroupDeclClause" ((PVar "first") (PVar "name") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "Cat") (EIf (EVar "first") (EApp (EVar "text") (ELit (LString "let rec "))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "text") (ELit (LString "with ")))))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "letGroupDeclClauseBody") (EVar "body")))))))
(DTypeSig false "letGroupDeclClauseBody" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "letGroupDeclClauseBody" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "letGroupDeclClauseBody") (EVar "e")))
(DFunDef false "letGroupDeclClauseBody" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "printExprBody") (EApp (EVar "EBlock") (EVar "stmts"))))
(DFunDef false "letGroupDeclClauseBody" ((PVar "body")) (EIf (EApp (EVar "isBlockBody") (EVar "body")) (EApp (EVar "indentBlock") (EApp (EVar "printExprBody") (EVar "body"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printExprBody") (EVar "body"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "superDoc" (TyFun (TyApp (TyCon "List") (TyCon "Super")) (TyCon "Doc")))
(DFunDef false "superDoc" ((PList)) (EVar "Nil"))
(DFunDef false "superDoc" ((PVar "supers")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " requires ")))) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "oneSuper")) (EVar "supers")))))
(DTypeSig false "oneSuper" (TyFun (TyCon "Super") (TyCon "Doc")))
(DFunDef false "oneSuper" ((PCon "Super" (PVar "n") (PVar "ps"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "p"))))) (EVar "ps")))))
(DTypeSig false "ifaceMethodDoc" (TyFun (TyCon "IfaceMethod") (TyCon "Doc")))
(DFunDef false "ifaceMethodDoc" ((PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "printType") (EVar "ty")))))
(DFunDef false "ifaceMethodDoc" ((PCon "IfaceMethod" (PVar "n") PWild (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "printExprBody") (EVar "body"))))))
(DTypeSig false "implHead" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Doc"))))
(DFunDef false "implHead" ((PVar "iface") (PVar "tys")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "iface"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "t"))))) (EVar "tys")))))
(DTypeSig false "reqsDoc" (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyCon "Doc")))
(DFunDef false "reqsDoc" ((PList)) (EVar "Nil"))
(DFunDef false "reqsDoc" ((PVar "reqs")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " requires ")))) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "oneReq")) (EVar "reqs")))))
(DTypeSig false "oneReq" (TyFun (TyCon "Require") (TyCon "Doc")))
(DFunDef false "oneReq" ((PCon "Require" (PVar "iface") (PVar "args"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "iface"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "t"))))) (EVar "args")))))
(DTypeSig false "implMethodDoc" (TyFun (TyCon "ImplMethod") (TyCon "Doc")))
(DFunDef false "implMethodDoc" ((PCon "ImplMethod" (PVar "n") (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))) (EApp (EVar "printDefRhs") (EVar "body")))))
(DTypeSig false "ppTy" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTy" ((PVar "t")) (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 0))) (EVar "t")))
(DTypeSig false "ppTyPrec" (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "ppTyPrec" (PWild (PCon "TyCon" (PVar "s") PWild)) (EApp (EVar "tyConSurface") (EVar "s")))
(DFunDef false "ppTyPrec" (PWild (PCon "TyVar" (PVar "s"))) (EVar "s"))
(DFunDef false "ppTyPrec" (PWild (PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ppTyPrec") (ELit (LInt 0)))) (EVar "ts")))) (ELit (LString ")"))))
(DFunDef false "ppTyPrec" ((PVar "p") (PCon "TyApp" (PVar "f") (PVar "x"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 1))) (EVar "f")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 2))) (EVar "x")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 2))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyPrec" ((PVar "p") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 1))) (EVar "a")))) (ELit (LString " -> "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 0))) (EVar "b")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyPrec" ((PVar "p") (PCon "TyEffect" (PVar "effs") (PVar "tail") (PVar "t"))) (EBlock (DoLet false false (PVar "inside") (EApp (EApp (EVar "ppEffInside") (EVar "effs")) (EVar "tail"))) (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EVar "inside"))) (ELit (LString "> "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 0))) (EVar "t")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyPrec" (PWild (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBlock (DoLet false false (PVar "csStr") (EMatch (EVar "cs") (arm (PList (PVar "c")) () (EApp (EVar "ppConstr") (EVar "c"))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "ppConstr")) (EVar "cs")))) (ELit (LString ")")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "csStr"))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 0))) (EVar "t")))) (ELit (LString ""))))))
(DTypeSig false "ppEffInside" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "ppEffInside" ((PVar "effs") (PCon "None")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "ppEffAtom")) (EVar "effs"))))
(DFunDef false "ppEffInside" ((PList) (PCon "Some" (PVar "v"))) (EVar "v"))
(DFunDef false "ppEffInside" ((PVar "effs") (PCon "Some" (PVar "v"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "ppEffAtom")) (EVar "effs"))))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString ""))))
(DTypeSig false "ppEffAtom" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "ppEffAtom" ((PTuple (PVar "l") (PCon "None"))) (EVar "l"))
(DFunDef false "ppEffAtom" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStringLit") (EVar "s")))) (ELit (LString ""))))
(DTypeSig false "effDomainDoc" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Doc")))
(DFunDef false "effDomainDoc" ((PCon "None")) (EVar "Nil"))
(DFunDef false "effDomainDoc" ((PCon "Some" (PVar "d"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "d"))))
(DTypeSig false "effDeclHead" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Doc"))))
(DFunDef false "effDeclHead" (PWild (PCon "True")) (EApp (EVar "text") (ELit (LString "internal effect "))))
(DFunDef false "effDeclHead" ((PCon "True") (PCon "False")) (EApp (EVar "text") (ELit (LString "export effect "))))
(DFunDef false "effDeclHead" ((PCon "False") (PCon "False")) (EApp (EVar "text") (ELit (LString "effect "))))
(DTypeSig false "ppConstr" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "ppConstr" ((PCon "Constraint" (PVar "iface") (PVar "args"))) (EIf (EApp (EVar "isEmptyL") (EVar "args")) (EVar "iface") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ppTyPrec") (ELit (LInt 2)))) (EVar "args"))))) (ELit (LString "")))))
(DTypeSig true "exprToString" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "exprToString" ((PVar "e")) (EApp (EVar "render") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))))
(DTypeSig true "declToString" (TyFun (TyCon "Decl") (TyCon "String")))
(DFunDef false "declToString" ((PVar "d")) (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "d"))))
(DTypeSig true "programToString" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "programToString" ((PVar "decls")) (EApp (EVar "stringConcat") (EApp (EApp (EMethodRef "map") (EVar "declLine")) (EVar "decls"))))
(DTypeSig false "declLine" (TyFun (TyCon "Decl") (TyCon "String")))
(DFunDef false "declLine" ((PVar "d")) (EBinOp "++" (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "d"))) (ELit (LString "\n"))))
