# META
source_lines=386
stages=DESUGAR,MARK
# SOURCE
-- Round-trip deserializer for the Core IR S-expression format produced by
-- core_ir_sexp.mdk.  Parses the output of cprogramToSexp back into a CProgram
-- so the round-trip gate can evaluate it and compare against the original.
--
-- The format is fully-parenthesized S-expressions (the same style sexp.mdk
-- emits for the AST).  Every node is `(Tag fields...)` where fields are
-- sub-sexps or quoted atoms.  Bare (unparenthesized) atoms are: AGlobal,
-- CTFail, HCons, HNil, HUnit, RNone, true, false, LUnit, PWild.

import frontend.ast.{Lit(..), Pat(..), RecPatField(..), Addr(..), Route(..)}
import ir.core_ir.{
  CExpr(..),
  CArm(..),
  CGuard(..),
  CStmt(..),
  CField(..),
  CBind(..),
  CClause(..),
  CImplEntry(..),
  CImplBody(..),
  CProgram(..),
  CTree(..),
  CTBranch(..),
  CHead(..),
}
import support.util.{reverseL}

-- ── tokenizer ─────────────────────────────────────────────────────────────────

public export data SToken = TOpen | TClose | TAtom String

tokenize : String -> List SToken
tokenize s = tokFrom (stringToChars s) 0

-- build the slice [start..end) from the char array as a String
buildSlice : Array Char -> Int -> Int -> String
buildSlice cs i end = stringConcat (sliceChars cs i end)

sliceChars : Array Char -> Int -> Int -> List String
sliceChars cs i end
  | i >= end = []
  | otherwise = charToStr (arrayGetUnsafe i cs) :: sliceChars cs (i + 1) end

isSpaceChar : Char -> Bool
isSpaceChar ' ' = True
isSpaceChar '\n' = True
isSpaceChar '\t' = True
isSpaceChar '\r' = True
isSpaceChar _ = False

tokFrom : Array Char -> Int -> List SToken
tokFrom cs i
  | i >= arrayLength cs = []
  | otherwise =
    let c = arrayGetUnsafe i cs
    if c == '(' then
      TOpen :: tokFrom cs (i + 1)
    else if c == ')' then
      TClose :: tokFrom cs (i + 1)
    else if c == '"' then
      tokQuoted cs (i + 1) []
    else if isSpaceChar c then
      tokFrom cs (i + 1)
    else
      tokWord cs i (i + 1)

tokWord : Array Char -> Int -> Int -> List SToken
tokWord cs start i
  | i >= arrayLength cs = [TAtom (buildSlice cs start i)]
  | otherwise =
    let c = arrayGetUnsafe i cs
    if c == '(' then
      TAtom (buildSlice cs start i) :: TOpen :: tokFrom cs (i + 1)
    else if c == ')' then
      TAtom (buildSlice cs start i) :: TClose :: tokFrom cs (i + 1)
    else if isSpaceChar c then
      TAtom (buildSlice cs start i) :: tokFrom cs (i + 1)
    else
      tokWord cs start (i + 1)

-- tokQuoted: accumulate a quoted string (without the outer quotes, which we
-- add back so unquote can strip them; this preserves the escStr-escaped form).
tokQuoted : Array Char -> Int -> List String -> List SToken
tokQuoted cs i acc
  | i >= arrayLength cs = [TAtom ("\"" ++ stringConcat (reverseL acc) ++ "\"")]
  | otherwise =
    let c = arrayGetUnsafe i cs
    if c == '"' then TAtom ("\"" ++ stringConcat (reverseL acc) ++ "\"") :: tokFrom cs (i + 1)
    else
      if c == '\\' && i + 1 < arrayLength cs then
        let next = arrayGetUnsafe (i + 1) cs
        tokQuoted cs (i + 2) (escPair next :: acc)
      else tokQuoted cs (i + 1) (charToStr c :: acc)

escPair : Char -> String
escPair 'n' = "\\n"
escPair 't' = "\\t"
escPair 'r' = "\\r"
escPair '"' = "\\\""
escPair '\\' = "\\\\"
escPair c = charToStr c

-- ── generic S-expression tree ─────────────────────────────────────────────────

public export data SExp = SAtom String | SList (List SExp)

parseSexp : List SToken -> (SExp, List SToken)
parseSexp (TOpen::rest) =
  let (children, rest2) = parseList rest
  (SList children, rest2)
parseSexp ((TAtom s)::rest) = (SAtom s, rest)
parseSexp (TClose::_) = panic "core_ir_sexp_parse: unexpected ')'"
parseSexp [] = panic "core_ir_sexp_parse: unexpected end of input"

parseList : List SToken -> (List SExp, List SToken)
parseList (TClose::rest) = ([], rest)
parseList ts =
  let (s, rest) = parseSexp ts
  let (more, rest2) = parseList rest
  (s::more, rest2)

parseAll : String -> SExp
parseAll s = match parseSexp (tokenize s)
  (sexp, _) => sexp

-- ── string unescaping ─────────────────────────────────────────────────────────
-- The serializer wraps strings with `escStr`, producing `"..."` with backslash
-- escapes.  unquote strips the outer `"..."` and decodes the escapes.

unquote : String -> String
unquote s =
  let cs = stringToChars s
  let n = arrayLength cs
  if n < 2 then s else stringConcat (unqFrom cs 1 (n - 1))

unqFrom : Array Char -> Int -> Int -> List String
unqFrom cs i lim
  | i >= lim = []
  | otherwise =
    let c = arrayGetUnsafe i cs
    if c == '\\' && i + 1 < lim then
      let next = arrayGetUnsafe (i + 1) cs
      unescOne next :: unqFrom cs (i + 2) lim
    else charToStr c :: unqFrom cs (i + 1) lim

unescOne : Char -> String
unescOne 'n' = "\n"
unescOne 't' = "\t"
unescOne 'r' = "\r"
unescOne '"' = "\""
unescOne '\\' = "\\"
unescOne c = charToStr c

-- ── typed converters: SExp → Core IR types ───────────────────────────────────

toStr : SExp -> String
toStr (SAtom s) = unquote s
toStr other =
  panic ("core_ir_sexp_parse: expected atom, got list: " ++ sexprToStr other)

toBool : SExp -> Bool
toBool (SAtom "true") = True
toBool (SAtom "false") = False
toBool other = panic ("core_ir_sexp_parse: expected bool: " ++ sexprToStr other)

-- parse a decimal integer (possibly negative) from a string
parseIntStr : String -> Int
parseIntStr s =
  let cs = stringToChars s
  let n = arrayLength cs
  if n == 0 then
    panic "core_ir_sexp_parse: empty int"
  else if arrayGetUnsafe 0 cs == '-' then
    0 - parseDigits cs 1 n 0
  else
    parseDigits cs 0 n 0

parseDigits : Array Char -> Int -> Int -> Int -> Int
parseDigits cs i n acc
  | i >= n = acc
  | otherwise = parseDigits cs (i + 1) n (acc * 10 + charCode (arrayGetUnsafe i cs) - charCode '0')

toInt : SExp -> Int
toInt (SAtom s) = parseIntStr s
toInt other =
  panic ("core_ir_sexp_parse: expected int atom: " ++ sexprToStr other)

toLit : SExp -> Lit
toLit (SList ((SAtom "LInt")::[n])) = LInt (toInt n)
toLit (SList ((SAtom "LFloat")::[f])) = match stringToFloat (toStr f)
  Some x => LFloat x
  None => panic "core_ir_sexp_parse: bad float"
toLit (SList ((SAtom "LString")::[s])) = LString (toStr s)
toLit (SList ((SAtom "LChar")::[c])) = LChar (toStr c)
toLit (SList ((SAtom "LBool")::[b])) = LBool (toBool b)
toLit (SAtom "LUnit") = LUnit
toLit other = panic ("core_ir_sexp_parse: bad Lit: " ++ sexprToStr other)

toRecPatField : SExp -> RecPatField
toRecPatField (SList ((SAtom "rf")::[f, SAtom "None"])) =
  RecPatField (toStr f) None
toRecPatField (SList ((SAtom "rf")::[f, p])) =
  RecPatField (toStr f) (Some (toPat p))
toRecPatField other =
  panic ("core_ir_sexp_parse: bad RecPatField: " ++ sexprToStr other)

toPat : SExp -> Pat
toPat (SList ((SAtom "PVar")::[n])) = PVar (toStr n)
toPat (SAtom "PWild") = PWild
toPat (SList ((SAtom "PLit")::[l])) = PLit (toLit l)
toPat (SList ((SAtom "PCon")::name::args)) = PCon (toStr name) (map toPat args)
toPat (SList ((SAtom "PCons")::[h, t])) = PCons (toPat h) (toPat t)
toPat (SList ((SAtom "PTuple")::ps)) = PTuple (map toPat ps)
toPat (SList ((SAtom "PList")::ps)) = PList (map toPat ps)
toPat (SList ((SAtom "PAs")::[n, p])) = PAs (toStr n) (toPat p)
toPat (SList ((SAtom "PRng")::[lo, hi, incl])) =
  PRng (toLit lo) (toLit hi) (toBool incl)
toPat (SList ((SAtom "PRec")::[name, SList fields, rest])) =
  PRec (toStr name) (map toRecPatField fields) (toBool rest)
toPat other = panic ("core_ir_sexp_parse: bad Pat: " ++ sexprToStr other)

toAddr : SExp -> Addr
toAddr (SAtom "AGlobal") = AGlobal
toAddr (SList ((SAtom "ALocal")::[frame, slot])) =
  ALocal (toInt frame) (toInt slot)
toAddr other = panic ("core_ir_sexp_parse: bad Addr: " ++ sexprToStr other)

toRoute : SExp -> Route
toRoute (SAtom "RNone") = RNone
toRoute (SAtom "RLocal") = RLocal "" []
toRoute (SList ((SAtom "RLocal")::[s])) = RLocal (toStr s) []
toRoute (SList ((SAtom "RKey")::[k])) = RKey (toStr k) []
toRoute (SList ((SAtom "RDict")::[d])) = RDict (toStr d)
toRoute (SList ((SAtom "RDictFwd")::[d])) = RDictFwd (toStr d)
toRoute (SList ((SAtom "RScalar")::[s])) = RScalar (toStr s)
toRoute other = panic ("core_ir_sexp_parse: bad Route: " ++ sexprToStr other)

toCField : SExp -> CField
toCField (SList ((SAtom "cf")::[name, e])) = CField (toStr name) (toCExpr e)
toCField other = panic ("core_ir_sexp_parse: bad CField: " ++ sexprToStr other)

toCGuard : SExp -> CGuard
toCGuard (SList ((SAtom "CGBool")::[e])) = CGBool (toCExpr e)
toCGuard (SList ((SAtom "CGBind")::[p, e])) = CGBind (toPat p) (toCExpr e)
toCGuard other = panic ("core_ir_sexp_parse: bad CGuard: " ++ sexprToStr other)

toArm : SExp -> CArm
toArm (SList ((SAtom "arm")::[pat, SList guards, body])) =
  CArm (toPat pat) (map toCGuard guards) (toCExpr body)
toArm other = panic ("core_ir_sexp_parse: bad CArm: " ++ sexprToStr other)

toCStmt : SExp -> CStmt
toCStmt (SList ((SAtom "CSExpr")::[e])) = CSExpr (toCExpr e)
toCStmt (SList ((SAtom "CSLet")::[isRec, pat, e])) =
  CSLet (toBool isRec) (toPat pat) (toCExpr e)
toCStmt (SList ((SAtom "CSAssign")::[x, e])) = CSAssign (toStr x) (toCExpr e)
toCStmt other = panic ("core_ir_sexp_parse: bad CStmt: " ++ sexprToStr other)

toCHead : SExp -> CHead
toCHead (SList ((SAtom "HCon")::[name, arity])) =
  HCon (toStr name) (toInt arity)
toCHead (SList ((SAtom "HTuple")::[arity])) = HTuple (toInt arity)
toCHead (SAtom "HCons") = HCons
toCHead (SAtom "HNil") = HNil
toCHead (SAtom "HUnit") = HUnit
toCHead (SList ((SAtom "HLit")::[l])) = HLit (toLit l)
toCHead other = panic ("core_ir_sexp_parse: bad CHead: " ++ sexprToStr other)

toCTree : SExp -> CTree
toCTree (SAtom "CTFail") = CTFail
toCTree (SList ((SAtom "CTLeaf")::[i])) = CTLeaf (toInt i)
toCTree (SList ((SAtom "CTGuard")::[i, fail])) =
  CTGuard (toInt i) (toCTree fail)
toCTree (SList ((SAtom "CTSwitch")::[SList branches, dflt])) =
  CTSwitch (map toCTBranch branches) (toCTree dflt)
toCTree (SList ((SAtom "CTDrop")::[tree])) = CTDrop (toCTree tree)
toCTree other = panic ("core_ir_sexp_parse: bad CTree: " ++ sexprToStr other)

toCTBranch : SExp -> CTBranch
toCTBranch (SList ((SAtom "CTBranch")::[head, tree])) =
  CTBranch (toCHead head) (toCTree tree)
toCTBranch other =
  panic ("core_ir_sexp_parse: bad CTBranch: " ++ sexprToStr other)

toCExpr : SExp -> CExpr
toCExpr (SList ((SAtom "CLit")::[l])) = CLit (toLit l)
toCExpr (SList ((SAtom "CVar")::[name, addr])) = CVar (toStr name) (toAddr addr)
toCExpr (SList ((SAtom "CApp")::[f, x])) = CApp (toCExpr f) (toCExpr x)
toCExpr (SList ((SAtom "CLam")::[SList pats, body])) =
  CLam (map toPat pats) (toCExpr body)
toCExpr (SList ((SAtom "CLet")::[isRec, pat, e1, e2])) =
  CLet (toBool isRec) (toPat pat) (toCExpr e1) (toCExpr e2)
toCExpr (SList ((SAtom "CLetGroup")::[SList binds, body])) =
  CLetGroup (map toCBind binds) (toCExpr body)
toCExpr (SList ((SAtom "CMatch")::scrut::arms)) =
  CMatch (toCExpr scrut) (map toArm arms)
toCExpr (SList ((SAtom "CDecision")::[scrut, SList arms, tree])) =
  CDecision (toCExpr scrut) (map toArm arms) (toCTree tree)
toCExpr (SList ((SAtom "CIf")::[c, t, e])) =
  CIf (toCExpr c) (toCExpr t) (toCExpr e)
toCExpr (SList ((SAtom "CBinPrim")::[op, l, r])) =
  CBinPrim (toStr op) (toCExpr l) (toCExpr r) ""
toCExpr (SList ((SAtom "CBinPrim")::[op, l, r, tag])) =
  CBinPrim (toStr op) (toCExpr l) (toCExpr r) (toStr tag)
toCExpr (SList ((SAtom "CUnOp")::[op, e])) = CUnOp (toStr op) (toCExpr e)
toCExpr (SList ((SAtom "CTuple")::es)) = CTuple (map toCExpr es)
toCExpr (SList ((SAtom "CList")::es)) = CList (map toCExpr es)
toCExpr (SList ((SAtom "CRecord")::name::fields)) =
  CRecord (toStr name) (map toCField fields)
toCExpr (SList ((SAtom "CFieldAccess")::[e, f, n])) =
  CFieldAccess (toCExpr e) (toStr f) (toStr n)
toCExpr (SList ((SAtom "CRecordUpdate")::base::fields)) =
  CRecordUpdate (toCExpr base) (map toCField fields)
toCExpr (SList ((SAtom "CVariantUpdate")::con::base::fields)) =
  CVariantUpdate (toStr con) (toCExpr base) (map toCField fields)
toCExpr (SList ((SAtom "CArray")::es)) = CArray (map toCExpr es)
toCExpr (SList ((SAtom "CRangeList")::[lo, hi, incl])) =
  CRangeList (toCExpr lo) (toCExpr hi) (toBool incl)
toCExpr (SList ((SAtom "CRangeArray")::[lo, hi, incl])) =
  CRangeArray (toCExpr lo) (toCExpr hi) (toBool incl)
toCExpr (SList ((SAtom "CIndex")::[a, i])) = CIndex (toCExpr a) (toCExpr i)
toCExpr (SList ((SAtom "CSlice")::[a, lo, hi, incl])) =
  CSlice (toCExpr a) (toCExpr lo) (toCExpr hi) (toBool incl)
toCExpr (SList ((SAtom "CStringIndex")::[a, i])) =
  CStringIndex (toCExpr a) (toCExpr i)
toCExpr (SList ((SAtom "CStringSlice")::[a, lo, hi, incl])) =
  CStringSlice (toCExpr a) (toCExpr lo) (toCExpr hi) (toBool incl)
toCExpr (SList ((SAtom "CListIndex")::[a, i])) =
  CListIndex (toCExpr a) (toCExpr i)
toCExpr (SList ((SAtom "CListSlice")::[a, lo, hi, incl])) =
  CListSlice (toCExpr a) (toCExpr lo) (toCExpr hi) (toBool incl)
toCExpr (SList ((SAtom "CBlock")::stmts)) = CBlock (map toCStmt stmts)
toCExpr (SList ((SAtom "CMethod")::[name, route, SList implRoutes, SList methRoutes])) = CMethod (toStr name) (toRoute route) (map toRoute implRoutes) (map toRoute methRoutes)
toCExpr (SList ((SAtom "CDict")::[name, SList routes])) =
  CDict (toStr name) (map toRoute routes)
toCExpr other = panic ("core_ir_sexp_parse: bad CExpr: " ++ sexprToStr other)

toCClause : SExp -> CClause
toCClause (SList ((SAtom "CClause")::[SList pats, body])) =
  CClause (map toPat pats) (toCExpr body)
toCClause other =
  panic ("core_ir_sexp_parse: bad CClause: " ++ sexprToStr other)

toCBind : SExp -> CBind
toCBind (SList ((SAtom "CBind")::name::clauses)) =
  CBind (toStr name) (map toCClause clauses)
toCBind other = panic ("core_ir_sexp_parse: bad CBind: " ++ sexprToStr other)

toCImplBody : SExp -> CImplBody
toCImplBody (SList ((SAtom "CImplTagged")::[tag, key, iface, SList positions, SList pats, body])) = CImplTagged (toStr tag) (toStr key) (toStr iface) (map toInt positions) (map toPat pats) (toCExpr body)
toCImplBody (SList ((SAtom "CImplDefault")::[SList pats, body])) =
  CImplDefault (map toPat pats) (toCExpr body)
toCImplBody other =
  panic ("core_ir_sexp_parse: bad CImplBody: " ++ sexprToStr other)

toCImplEntry : SExp -> CImplEntry
toCImplEntry (SList ((SAtom "CImplEntry")::[name, score, body])) =
  CImplEntry (toStr name) (toInt score) (toCImplBody body)
toCImplEntry other =
  panic ("core_ir_sexp_parse: bad CImplEntry: " ++ sexprToStr other)

toCtorArity : SExp -> (String, Int)
toCtorArity (SList ((SAtom "ca")::[name, arity])) = (toStr name, toInt arity)
toCtorArity other =
  panic ("core_ir_sexp_parse: bad ctor-arity: " ++ sexprToStr other)

toCtorType : SExp -> (String, String)
toCtorType (SList ((SAtom "ct")::[ctor, ty])) = (toStr ctor, toStr ty)
toCtorType other =
  panic ("core_ir_sexp_parse: bad ctor-type: " ++ sexprToStr other)

export parseCProgram : String -> CProgram
parseCProgram s = match parseAll s
  SList ((SAtom "CProgram")::[SList binds, SList ctorArities, SList ctorTypes, SList impls]) => CProgram (map toCBind binds) (map toCtorArity ctorArities) (map toCtorType ctorTypes) (map toCImplEntry impls)
  other => panic ("core_ir_sexp_parse: bad CProgram: " ++ sexprToStr other)

-- ── debug helper ─────────────────────────────────────────────────────────────

sexprToStr : SExp -> String
sexprToStr (SAtom s) = s
sexprToStr (SList xs) = "(" ++ joinSexps xs ++ ")"

joinSexps : List SExp -> String
joinSexps [] = ""
joinSexps [x] = sexprToStr x
joinSexps (x::rest) = "\{sexprToStr x} \{joinSexps rest}"
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Addr" true) (mem "Route" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CProgram" true) (mem "CTree" true) (mem "CTBranch" true) (mem "CHead" true))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DData Public "SToken" () ((variant "TOpen" (ConPos)) (variant "TClose" (ConPos)) (variant "TAtom" (ConPos (TyCon "String")))) ())
(DTypeSig false "tokenize" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "SToken"))))
(DFunDef false "tokenize" ((PVar "s")) (EApp (EApp (EVar "tokFrom") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))))
(DTypeSig false "buildSlice" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "buildSlice" ((PVar "cs") (PVar "i") (PVar "end")) (EApp (EVar "stringConcat") (EApp (EApp (EApp (EVar "sliceChars") (EVar "cs")) (EVar "i")) (EVar "end"))))
(DTypeSig false "sliceChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "sliceChars" ((PVar "cs") (PVar "i") (PVar "end")) (EIf (EBinOp ">=" (EVar "i") (EVar "end")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "sliceChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "end"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isSpaceChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isSpaceChar" ((PLit (LChar " "))) (EVar "True"))
(DFunDef false "isSpaceChar" ((PLit (LChar "\n"))) (EVar "True"))
(DFunDef false "isSpaceChar" ((PLit (LChar "\t"))) (EVar "True"))
(DFunDef false "isSpaceChar" ((PLit (LChar "\r"))) (EVar "True"))
(DFunDef false "isSpaceChar" (PWild) (EVar "False"))
(DTypeSig false "tokFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "SToken")))))
(DFunDef false "tokFrom" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LChar "("))) (EBinOp "::" (EVar "TOpen") (EApp (EApp (EVar "tokFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar ")"))) (EBinOp "::" (EVar "TClose") (EApp (EApp (EVar "tokFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "tokQuoted") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EListLit)) (EIf (EApp (EVar "isSpaceChar") (EVar "c")) (EApp (EApp (EVar "tokFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "tokWord") (EVar "cs")) (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tokWord" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "SToken"))))))
(DFunDef false "tokWord" ((PVar "cs") (PVar "start") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit (EApp (EVar "TAtom") (EApp (EApp (EApp (EVar "buildSlice") (EVar "cs")) (EVar "start")) (EVar "i")))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LChar "("))) (EBinOp "::" (EApp (EVar "TAtom") (EApp (EApp (EApp (EVar "buildSlice") (EVar "cs")) (EVar "start")) (EVar "i"))) (EBinOp "::" (EVar "TOpen") (EApp (EApp (EVar "tokFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar ")"))) (EBinOp "::" (EApp (EVar "TAtom") (EApp (EApp (EApp (EVar "buildSlice") (EVar "cs")) (EVar "start")) (EVar "i"))) (EBinOp "::" (EVar "TClose") (EApp (EApp (EVar "tokFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EIf (EApp (EVar "isSpaceChar") (EVar "c")) (EBinOp "::" (EApp (EVar "TAtom") (EApp (EApp (EApp (EVar "buildSlice") (EVar "cs")) (EVar "start")) (EVar "i"))) (EApp (EApp (EVar "tokFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EApp (EApp (EVar "tokWord") (EVar "cs")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tokQuoted" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "SToken"))))))
(DFunDef false "tokQuoted" ((PVar "cs") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit (EApp (EVar "TAtom") (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "stringConcat") (EApp (EVar "reverseL") (EVar "acc")))) (ELit (LString "\""))))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (EBinOp "::" (EApp (EVar "TAtom") (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "stringConcat") (EApp (EVar "reverseL") (EVar "acc")))) (ELit (LString "\"")))) (EApp (EApp (EVar "tokFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "\\"))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "cs")))) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs"))) (DoExpr (EApp (EApp (EApp (EVar "tokQuoted") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EBinOp "::" (EApp (EVar "escPair") (EVar "next")) (EVar "acc"))))) (EApp (EApp (EApp (EVar "tokQuoted") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "charToStr") (EVar "c")) (EVar "acc"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "escPair" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "escPair" ((PLit (LChar "n"))) (ELit (LString "\\n")))
(DFunDef false "escPair" ((PLit (LChar "t"))) (ELit (LString "\\t")))
(DFunDef false "escPair" ((PLit (LChar "r"))) (ELit (LString "\\r")))
(DFunDef false "escPair" ((PLit (LChar "\""))) (ELit (LString "\\\"")))
(DFunDef false "escPair" ((PLit (LChar "\\"))) (ELit (LString "\\\\")))
(DFunDef false "escPair" ((PVar "c")) (EApp (EVar "charToStr") (EVar "c")))
(DData Public "SExp" () ((variant "SAtom" (ConPos (TyCon "String"))) (variant "SList" (ConPos (TyApp (TyCon "List") (TyCon "SExp"))))) ())
(DTypeSig false "parseSexp" (TyFun (TyApp (TyCon "List") (TyCon "SToken")) (TyTuple (TyCon "SExp") (TyApp (TyCon "List") (TyCon "SToken")))))
(DFunDef false "parseSexp" ((PCons (PCon "TOpen") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "children") (PVar "rest2")) (EApp (EVar "parseList") (EVar "rest"))) (DoExpr (ETuple (EApp (EVar "SList") (EVar "children")) (EVar "rest2")))))
(DFunDef false "parseSexp" ((PCons (PCon "TAtom" (PVar "s")) (PVar "rest"))) (ETuple (EApp (EVar "SAtom") (EVar "s")) (EVar "rest")))
(DFunDef false "parseSexp" ((PCons (PCon "TClose") PWild)) (EApp (EVar "panic") (ELit (LString "core_ir_sexp_parse: unexpected ')'"))))
(DFunDef false "parseSexp" ((PList)) (EApp (EVar "panic") (ELit (LString "core_ir_sexp_parse: unexpected end of input"))))
(DTypeSig false "parseList" (TyFun (TyApp (TyCon "List") (TyCon "SToken")) (TyTuple (TyApp (TyCon "List") (TyCon "SExp")) (TyApp (TyCon "List") (TyCon "SToken")))))
(DFunDef false "parseList" ((PCons (PCon "TClose") (PVar "rest"))) (ETuple (EListLit) (EVar "rest")))
(DFunDef false "parseList" ((PVar "ts")) (EBlock (DoLet false false (PTuple (PVar "s") (PVar "rest")) (EApp (EVar "parseSexp") (EVar "ts"))) (DoLet false false (PTuple (PVar "more") (PVar "rest2")) (EApp (EVar "parseList") (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "s") (EVar "more")) (EVar "rest2")))))
(DTypeSig false "parseAll" (TyFun (TyCon "String") (TyCon "SExp")))
(DFunDef false "parseAll" ((PVar "s")) (EMatch (EApp (EVar "parseSexp") (EApp (EVar "tokenize") (EVar "s"))) (arm (PTuple (PVar "sexp") PWild) () (EVar "sexp"))))
(DTypeSig false "unquote" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unquote" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EIf (EBinOp "<" (EVar "n") (ELit (LInt 2))) (EVar "s") (EApp (EVar "stringConcat") (EApp (EApp (EApp (EVar "unqFrom") (EVar "cs")) (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))))))))
(DTypeSig false "unqFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "unqFrom" ((PVar "cs") (PVar "i") (PVar "lim")) (EIf (EBinOp ">=" (EVar "i") (EVar "lim")) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "\\"))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "lim"))) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs"))) (DoExpr (EBinOp "::" (EApp (EVar "unescOne") (EVar "next")) (EApp (EApp (EApp (EVar "unqFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "lim"))))) (EBinOp "::" (EApp (EVar "charToStr") (EVar "c")) (EApp (EApp (EApp (EVar "unqFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "lim")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "unescOne" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "unescOne" ((PLit (LChar "n"))) (ELit (LString "\n")))
(DFunDef false "unescOne" ((PLit (LChar "t"))) (ELit (LString "\t")))
(DFunDef false "unescOne" ((PLit (LChar "r"))) (ELit (LString "\r")))
(DFunDef false "unescOne" ((PLit (LChar "\""))) (ELit (LString "\"")))
(DFunDef false "unescOne" ((PLit (LChar "\\"))) (ELit (LString "\\")))
(DFunDef false "unescOne" ((PVar "c")) (EApp (EVar "charToStr") (EVar "c")))
(DTypeSig false "toStr" (TyFun (TyCon "SExp") (TyCon "String")))
(DFunDef false "toStr" ((PCon "SAtom" (PVar "s"))) (EApp (EVar "unquote") (EVar "s")))
(DFunDef false "toStr" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: expected atom, got list: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toBool" (TyFun (TyCon "SExp") (TyCon "Bool")))
(DFunDef false "toBool" ((PCon "SAtom" (PLit (LString "true")))) (EVar "True"))
(DFunDef false "toBool" ((PCon "SAtom" (PLit (LString "false")))) (EVar "False"))
(DFunDef false "toBool" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: expected bool: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "parseIntStr" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "parseIntStr" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "core_ir_sexp_parse: empty int"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")) (ELit (LChar "-"))) (EBinOp "-" (ELit (LInt 0)) (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "cs")) (ELit (LInt 1))) (EVar "n")) (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "cs")) (ELit (LInt 0))) (EVar "n")) (ELit (LInt 0))))))))
(DTypeSig false "parseDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "parseDigits" ((PVar "cs") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "-" (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")))) (EApp (EVar "charCode") (ELit (LChar "0"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "toInt" (TyFun (TyCon "SExp") (TyCon "Int")))
(DFunDef false "toInt" ((PCon "SAtom" (PVar "s"))) (EApp (EVar "parseIntStr") (EVar "s")))
(DFunDef false "toInt" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: expected int atom: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toLit" (TyFun (TyCon "SExp") (TyCon "Lit")))
(DFunDef false "toLit" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "LInt"))) (PList (PVar "n"))))) (EApp (EVar "LInt") (EApp (EVar "toInt") (EVar "n"))))
(DFunDef false "toLit" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "LFloat"))) (PList (PVar "f"))))) (EMatch (EApp (EVar "stringToFloat") (EApp (EVar "toStr") (EVar "f"))) (arm (PCon "Some" (PVar "x")) () (EApp (EVar "LFloat") (EVar "x"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "core_ir_sexp_parse: bad float"))))))
(DFunDef false "toLit" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "LString"))) (PList (PVar "s"))))) (EApp (EVar "LString") (EApp (EVar "toStr") (EVar "s"))))
(DFunDef false "toLit" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "LChar"))) (PList (PVar "c"))))) (EApp (EVar "LChar") (EApp (EVar "toStr") (EVar "c"))))
(DFunDef false "toLit" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "LBool"))) (PList (PVar "b"))))) (EApp (EVar "LBool") (EApp (EVar "toBool") (EVar "b"))))
(DFunDef false "toLit" ((PCon "SAtom" (PLit (LString "LUnit")))) (EVar "LUnit"))
(DFunDef false "toLit" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad Lit: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toRecPatField" (TyFun (TyCon "SExp") (TyCon "RecPatField")))
(DFunDef false "toRecPatField" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "rf"))) (PList (PVar "f") (PCon "SAtom" (PLit (LString "None"))))))) (EApp (EApp (EVar "RecPatField") (EApp (EVar "toStr") (EVar "f"))) (EVar "None")))
(DFunDef false "toRecPatField" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "rf"))) (PList (PVar "f") (PVar "p"))))) (EApp (EApp (EVar "RecPatField") (EApp (EVar "toStr") (EVar "f"))) (EApp (EVar "Some") (EApp (EVar "toPat") (EVar "p")))))
(DFunDef false "toRecPatField" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad RecPatField: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toPat" (TyFun (TyCon "SExp") (TyCon "Pat")))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PVar"))) (PList (PVar "n"))))) (EApp (EVar "PVar") (EApp (EVar "toStr") (EVar "n"))))
(DFunDef false "toPat" ((PCon "SAtom" (PLit (LString "PWild")))) (EVar "PWild"))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PLit"))) (PList (PVar "l"))))) (EApp (EVar "PLit") (EApp (EVar "toLit") (EVar "l"))))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PCon"))) (PCons (PVar "name") (PVar "args"))))) (EApp (EApp (EVar "PCon") (EApp (EVar "toStr") (EVar "name"))) (EApp (EApp (EVar "map") (EVar "toPat")) (EVar "args"))))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PCons"))) (PList (PVar "h") (PVar "t"))))) (EApp (EApp (EVar "PCons") (EApp (EVar "toPat") (EVar "h"))) (EApp (EVar "toPat") (EVar "t"))))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PTuple"))) (PVar "ps")))) (EApp (EVar "PTuple") (EApp (EApp (EVar "map") (EVar "toPat")) (EVar "ps"))))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PList"))) (PVar "ps")))) (EApp (EVar "PList") (EApp (EApp (EVar "map") (EVar "toPat")) (EVar "ps"))))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PAs"))) (PList (PVar "n") (PVar "p"))))) (EApp (EApp (EVar "PAs") (EApp (EVar "toStr") (EVar "n"))) (EApp (EVar "toPat") (EVar "p"))))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PRng"))) (PList (PVar "lo") (PVar "hi") (PVar "incl"))))) (EApp (EApp (EApp (EVar "PRng") (EApp (EVar "toLit") (EVar "lo"))) (EApp (EVar "toLit") (EVar "hi"))) (EApp (EVar "toBool") (EVar "incl"))))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PRec"))) (PList (PVar "name") (PCon "SList" (PVar "fields")) (PVar "rest"))))) (EApp (EApp (EApp (EVar "PRec") (EApp (EVar "toStr") (EVar "name"))) (EApp (EApp (EVar "map") (EVar "toRecPatField")) (EVar "fields"))) (EApp (EVar "toBool") (EVar "rest"))))
(DFunDef false "toPat" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad Pat: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toAddr" (TyFun (TyCon "SExp") (TyCon "Addr")))
(DFunDef false "toAddr" ((PCon "SAtom" (PLit (LString "AGlobal")))) (EVar "AGlobal"))
(DFunDef false "toAddr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "ALocal"))) (PList (PVar "frame") (PVar "slot"))))) (EApp (EApp (EVar "ALocal") (EApp (EVar "toInt") (EVar "frame"))) (EApp (EVar "toInt") (EVar "slot"))))
(DFunDef false "toAddr" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad Addr: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toRoute" (TyFun (TyCon "SExp") (TyCon "Route")))
(DFunDef false "toRoute" ((PCon "SAtom" (PLit (LString "RNone")))) (EVar "RNone"))
(DFunDef false "toRoute" ((PCon "SAtom" (PLit (LString "RLocal")))) (EApp (EApp (EVar "RLocal") (ELit (LString ""))) (EListLit)))
(DFunDef false "toRoute" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "RLocal"))) (PList (PVar "s"))))) (EApp (EApp (EVar "RLocal") (EApp (EVar "toStr") (EVar "s"))) (EListLit)))
(DFunDef false "toRoute" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "RKey"))) (PList (PVar "k"))))) (EApp (EApp (EVar "RKey") (EApp (EVar "toStr") (EVar "k"))) (EListLit)))
(DFunDef false "toRoute" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "RDict"))) (PList (PVar "d"))))) (EApp (EVar "RDict") (EApp (EVar "toStr") (EVar "d"))))
(DFunDef false "toRoute" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "RDictFwd"))) (PList (PVar "d"))))) (EApp (EVar "RDictFwd") (EApp (EVar "toStr") (EVar "d"))))
(DFunDef false "toRoute" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "RScalar"))) (PList (PVar "s"))))) (EApp (EVar "RScalar") (EApp (EVar "toStr") (EVar "s"))))
(DFunDef false "toRoute" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad Route: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCField" (TyFun (TyCon "SExp") (TyCon "CField")))
(DFunDef false "toCField" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "cf"))) (PList (PVar "name") (PVar "e"))))) (EApp (EApp (EVar "CField") (EApp (EVar "toStr") (EVar "name"))) (EApp (EVar "toCExpr") (EVar "e"))))
(DFunDef false "toCField" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CField: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCGuard" (TyFun (TyCon "SExp") (TyCon "CGuard")))
(DFunDef false "toCGuard" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CGBool"))) (PList (PVar "e"))))) (EApp (EVar "CGBool") (EApp (EVar "toCExpr") (EVar "e"))))
(DFunDef false "toCGuard" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CGBind"))) (PList (PVar "p") (PVar "e"))))) (EApp (EApp (EVar "CGBind") (EApp (EVar "toPat") (EVar "p"))) (EApp (EVar "toCExpr") (EVar "e"))))
(DFunDef false "toCGuard" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CGuard: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toArm" (TyFun (TyCon "SExp") (TyCon "CArm")))
(DFunDef false "toArm" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "arm"))) (PList (PVar "pat") (PCon "SList" (PVar "guards")) (PVar "body"))))) (EApp (EApp (EApp (EVar "CArm") (EApp (EVar "toPat") (EVar "pat"))) (EApp (EApp (EVar "map") (EVar "toCGuard")) (EVar "guards"))) (EApp (EVar "toCExpr") (EVar "body"))))
(DFunDef false "toArm" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CArm: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCStmt" (TyFun (TyCon "SExp") (TyCon "CStmt")))
(DFunDef false "toCStmt" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CSExpr"))) (PList (PVar "e"))))) (EApp (EVar "CSExpr") (EApp (EVar "toCExpr") (EVar "e"))))
(DFunDef false "toCStmt" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CSLet"))) (PList (PVar "isRec") (PVar "pat") (PVar "e"))))) (EApp (EApp (EApp (EVar "CSLet") (EApp (EVar "toBool") (EVar "isRec"))) (EApp (EVar "toPat") (EVar "pat"))) (EApp (EVar "toCExpr") (EVar "e"))))
(DFunDef false "toCStmt" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CSAssign"))) (PList (PVar "x") (PVar "e"))))) (EApp (EApp (EVar "CSAssign") (EApp (EVar "toStr") (EVar "x"))) (EApp (EVar "toCExpr") (EVar "e"))))
(DFunDef false "toCStmt" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CStmt: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCHead" (TyFun (TyCon "SExp") (TyCon "CHead")))
(DFunDef false "toCHead" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "HCon"))) (PList (PVar "name") (PVar "arity"))))) (EApp (EApp (EVar "HCon") (EApp (EVar "toStr") (EVar "name"))) (EApp (EVar "toInt") (EVar "arity"))))
(DFunDef false "toCHead" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "HTuple"))) (PList (PVar "arity"))))) (EApp (EVar "HTuple") (EApp (EVar "toInt") (EVar "arity"))))
(DFunDef false "toCHead" ((PCon "SAtom" (PLit (LString "HCons")))) (EVar "HCons"))
(DFunDef false "toCHead" ((PCon "SAtom" (PLit (LString "HNil")))) (EVar "HNil"))
(DFunDef false "toCHead" ((PCon "SAtom" (PLit (LString "HUnit")))) (EVar "HUnit"))
(DFunDef false "toCHead" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "HLit"))) (PList (PVar "l"))))) (EApp (EVar "HLit") (EApp (EVar "toLit") (EVar "l"))))
(DFunDef false "toCHead" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CHead: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCTree" (TyFun (TyCon "SExp") (TyCon "CTree")))
(DFunDef false "toCTree" ((PCon "SAtom" (PLit (LString "CTFail")))) (EVar "CTFail"))
(DFunDef false "toCTree" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CTLeaf"))) (PList (PVar "i"))))) (EApp (EVar "CTLeaf") (EApp (EVar "toInt") (EVar "i"))))
(DFunDef false "toCTree" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CTGuard"))) (PList (PVar "i") (PVar "fail"))))) (EApp (EApp (EVar "CTGuard") (EApp (EVar "toInt") (EVar "i"))) (EApp (EVar "toCTree") (EVar "fail"))))
(DFunDef false "toCTree" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CTSwitch"))) (PList (PCon "SList" (PVar "branches")) (PVar "dflt"))))) (EApp (EApp (EVar "CTSwitch") (EApp (EApp (EVar "map") (EVar "toCTBranch")) (EVar "branches"))) (EApp (EVar "toCTree") (EVar "dflt"))))
(DFunDef false "toCTree" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CTDrop"))) (PList (PVar "tree"))))) (EApp (EVar "CTDrop") (EApp (EVar "toCTree") (EVar "tree"))))
(DFunDef false "toCTree" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CTree: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCTBranch" (TyFun (TyCon "SExp") (TyCon "CTBranch")))
(DFunDef false "toCTBranch" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CTBranch"))) (PList (PVar "head") (PVar "tree"))))) (EApp (EApp (EVar "CTBranch") (EApp (EVar "toCHead") (EVar "head"))) (EApp (EVar "toCTree") (EVar "tree"))))
(DFunDef false "toCTBranch" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CTBranch: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCExpr" (TyFun (TyCon "SExp") (TyCon "CExpr")))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CLit"))) (PList (PVar "l"))))) (EApp (EVar "CLit") (EApp (EVar "toLit") (EVar "l"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CVar"))) (PList (PVar "name") (PVar "addr"))))) (EApp (EApp (EVar "CVar") (EApp (EVar "toStr") (EVar "name"))) (EApp (EVar "toAddr") (EVar "addr"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CApp"))) (PList (PVar "f") (PVar "x"))))) (EApp (EApp (EVar "CApp") (EApp (EVar "toCExpr") (EVar "f"))) (EApp (EVar "toCExpr") (EVar "x"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CLam"))) (PList (PCon "SList" (PVar "pats")) (PVar "body"))))) (EApp (EApp (EVar "CLam") (EApp (EApp (EVar "map") (EVar "toPat")) (EVar "pats"))) (EApp (EVar "toCExpr") (EVar "body"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CLet"))) (PList (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2"))))) (EApp (EApp (EApp (EApp (EVar "CLet") (EApp (EVar "toBool") (EVar "isRec"))) (EApp (EVar "toPat") (EVar "pat"))) (EApp (EVar "toCExpr") (EVar "e1"))) (EApp (EVar "toCExpr") (EVar "e2"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CLetGroup"))) (PList (PCon "SList" (PVar "binds")) (PVar "body"))))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EVar "map") (EVar "toCBind")) (EVar "binds"))) (EApp (EVar "toCExpr") (EVar "body"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CMatch"))) (PCons (PVar "scrut") (PVar "arms"))))) (EApp (EApp (EVar "CMatch") (EApp (EVar "toCExpr") (EVar "scrut"))) (EApp (EApp (EVar "map") (EVar "toArm")) (EVar "arms"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CDecision"))) (PList (PVar "scrut") (PCon "SList" (PVar "arms")) (PVar "tree"))))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EVar "toCExpr") (EVar "scrut"))) (EApp (EApp (EVar "map") (EVar "toArm")) (EVar "arms"))) (EApp (EVar "toCTree") (EVar "tree"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CIf"))) (PList (PVar "c") (PVar "t") (PVar "e"))))) (EApp (EApp (EApp (EVar "CIf") (EApp (EVar "toCExpr") (EVar "c"))) (EApp (EVar "toCExpr") (EVar "t"))) (EApp (EVar "toCExpr") (EVar "e"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CBinPrim"))) (PList (PVar "op") (PVar "l") (PVar "r"))))) (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EApp (EVar "toStr") (EVar "op"))) (EApp (EVar "toCExpr") (EVar "l"))) (EApp (EVar "toCExpr") (EVar "r"))) (ELit (LString ""))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CBinPrim"))) (PList (PVar "op") (PVar "l") (PVar "r") (PVar "tag"))))) (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EApp (EVar "toStr") (EVar "op"))) (EApp (EVar "toCExpr") (EVar "l"))) (EApp (EVar "toCExpr") (EVar "r"))) (EApp (EVar "toStr") (EVar "tag"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CUnOp"))) (PList (PVar "op") (PVar "e"))))) (EApp (EApp (EVar "CUnOp") (EApp (EVar "toStr") (EVar "op"))) (EApp (EVar "toCExpr") (EVar "e"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CTuple"))) (PVar "es")))) (EApp (EVar "CTuple") (EApp (EApp (EVar "map") (EVar "toCExpr")) (EVar "es"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CList"))) (PVar "es")))) (EApp (EVar "CList") (EApp (EApp (EVar "map") (EVar "toCExpr")) (EVar "es"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CRecord"))) (PCons (PVar "name") (PVar "fields"))))) (EApp (EApp (EVar "CRecord") (EApp (EVar "toStr") (EVar "name"))) (EApp (EApp (EVar "map") (EVar "toCField")) (EVar "fields"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CFieldAccess"))) (PList (PVar "e") (PVar "f") (PVar "n"))))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EVar "toCExpr") (EVar "e"))) (EApp (EVar "toStr") (EVar "f"))) (EApp (EVar "toStr") (EVar "n"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CRecordUpdate"))) (PCons (PVar "base") (PVar "fields"))))) (EApp (EApp (EVar "CRecordUpdate") (EApp (EVar "toCExpr") (EVar "base"))) (EApp (EApp (EVar "map") (EVar "toCField")) (EVar "fields"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CVariantUpdate"))) (PCons (PVar "con") (PCons (PVar "base") (PVar "fields")))))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EApp (EVar "toStr") (EVar "con"))) (EApp (EVar "toCExpr") (EVar "base"))) (EApp (EApp (EVar "map") (EVar "toCField")) (EVar "fields"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CArray"))) (PVar "es")))) (EApp (EVar "CArray") (EApp (EApp (EVar "map") (EVar "toCExpr")) (EVar "es"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CRangeList"))) (PList (PVar "lo") (PVar "hi") (PVar "incl"))))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EVar "toCExpr") (EVar "lo"))) (EApp (EVar "toCExpr") (EVar "hi"))) (EApp (EVar "toBool") (EVar "incl"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CRangeArray"))) (PList (PVar "lo") (PVar "hi") (PVar "incl"))))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EVar "toCExpr") (EVar "lo"))) (EApp (EVar "toCExpr") (EVar "hi"))) (EApp (EVar "toBool") (EVar "incl"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CIndex"))) (PList (PVar "a") (PVar "i"))))) (EApp (EApp (EVar "CIndex") (EApp (EVar "toCExpr") (EVar "a"))) (EApp (EVar "toCExpr") (EVar "i"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CSlice"))) (PList (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EVar "toCExpr") (EVar "a"))) (EApp (EVar "toCExpr") (EVar "lo"))) (EApp (EVar "toCExpr") (EVar "hi"))) (EApp (EVar "toBool") (EVar "incl"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CStringIndex"))) (PList (PVar "a") (PVar "i"))))) (EApp (EApp (EVar "CStringIndex") (EApp (EVar "toCExpr") (EVar "a"))) (EApp (EVar "toCExpr") (EVar "i"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CStringSlice"))) (PList (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EVar "toCExpr") (EVar "a"))) (EApp (EVar "toCExpr") (EVar "lo"))) (EApp (EVar "toCExpr") (EVar "hi"))) (EApp (EVar "toBool") (EVar "incl"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CListIndex"))) (PList (PVar "a") (PVar "i"))))) (EApp (EApp (EVar "CListIndex") (EApp (EVar "toCExpr") (EVar "a"))) (EApp (EVar "toCExpr") (EVar "i"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CListSlice"))) (PList (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EVar "toCExpr") (EVar "a"))) (EApp (EVar "toCExpr") (EVar "lo"))) (EApp (EVar "toCExpr") (EVar "hi"))) (EApp (EVar "toBool") (EVar "incl"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CBlock"))) (PVar "stmts")))) (EApp (EVar "CBlock") (EApp (EApp (EVar "map") (EVar "toCStmt")) (EVar "stmts"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CMethod"))) (PList (PVar "name") (PVar "route") (PCon "SList" (PVar "implRoutes")) (PCon "SList" (PVar "methRoutes")))))) (EApp (EApp (EApp (EApp (EVar "CMethod") (EApp (EVar "toStr") (EVar "name"))) (EApp (EVar "toRoute") (EVar "route"))) (EApp (EApp (EVar "map") (EVar "toRoute")) (EVar "implRoutes"))) (EApp (EApp (EVar "map") (EVar "toRoute")) (EVar "methRoutes"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CDict"))) (PList (PVar "name") (PCon "SList" (PVar "routes")))))) (EApp (EApp (EVar "CDict") (EApp (EVar "toStr") (EVar "name"))) (EApp (EApp (EVar "map") (EVar "toRoute")) (EVar "routes"))))
(DFunDef false "toCExpr" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CExpr: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCClause" (TyFun (TyCon "SExp") (TyCon "CClause")))
(DFunDef false "toCClause" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CClause"))) (PList (PCon "SList" (PVar "pats")) (PVar "body"))))) (EApp (EApp (EVar "CClause") (EApp (EApp (EVar "map") (EVar "toPat")) (EVar "pats"))) (EApp (EVar "toCExpr") (EVar "body"))))
(DFunDef false "toCClause" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CClause: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCBind" (TyFun (TyCon "SExp") (TyCon "CBind")))
(DFunDef false "toCBind" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CBind"))) (PCons (PVar "name") (PVar "clauses"))))) (EApp (EApp (EVar "CBind") (EApp (EVar "toStr") (EVar "name"))) (EApp (EApp (EVar "map") (EVar "toCClause")) (EVar "clauses"))))
(DFunDef false "toCBind" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CBind: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCImplBody" (TyFun (TyCon "SExp") (TyCon "CImplBody")))
(DFunDef false "toCImplBody" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CImplTagged"))) (PList (PVar "tag") (PVar "key") (PVar "iface") (PCon "SList" (PVar "positions")) (PCon "SList" (PVar "pats")) (PVar "body"))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EApp (EVar "toStr") (EVar "tag"))) (EApp (EVar "toStr") (EVar "key"))) (EApp (EVar "toStr") (EVar "iface"))) (EApp (EApp (EVar "map") (EVar "toInt")) (EVar "positions"))) (EApp (EApp (EVar "map") (EVar "toPat")) (EVar "pats"))) (EApp (EVar "toCExpr") (EVar "body"))))
(DFunDef false "toCImplBody" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CImplDefault"))) (PList (PCon "SList" (PVar "pats")) (PVar "body"))))) (EApp (EApp (EVar "CImplDefault") (EApp (EApp (EVar "map") (EVar "toPat")) (EVar "pats"))) (EApp (EVar "toCExpr") (EVar "body"))))
(DFunDef false "toCImplBody" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CImplBody: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCImplEntry" (TyFun (TyCon "SExp") (TyCon "CImplEntry")))
(DFunDef false "toCImplEntry" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CImplEntry"))) (PList (PVar "name") (PVar "score") (PVar "body"))))) (EApp (EApp (EApp (EVar "CImplEntry") (EApp (EVar "toStr") (EVar "name"))) (EApp (EVar "toInt") (EVar "score"))) (EApp (EVar "toCImplBody") (EVar "body"))))
(DFunDef false "toCImplEntry" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CImplEntry: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCtorArity" (TyFun (TyCon "SExp") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "toCtorArity" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "ca"))) (PList (PVar "name") (PVar "arity"))))) (ETuple (EApp (EVar "toStr") (EVar "name")) (EApp (EVar "toInt") (EVar "arity"))))
(DFunDef false "toCtorArity" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad ctor-arity: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCtorType" (TyFun (TyCon "SExp") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "toCtorType" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "ct"))) (PList (PVar "ctor") (PVar "ty"))))) (ETuple (EApp (EVar "toStr") (EVar "ctor")) (EApp (EVar "toStr") (EVar "ty"))))
(DFunDef false "toCtorType" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad ctor-type: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig true "parseCProgram" (TyFun (TyCon "String") (TyCon "CProgram")))
(DFunDef false "parseCProgram" ((PVar "s")) (EMatch (EApp (EVar "parseAll") (EVar "s")) (arm (PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CProgram"))) (PList (PCon "SList" (PVar "binds")) (PCon "SList" (PVar "ctorArities")) (PCon "SList" (PVar "ctorTypes")) (PCon "SList" (PVar "impls"))))) () (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EVar "map") (EVar "toCBind")) (EVar "binds"))) (EApp (EApp (EVar "map") (EVar "toCtorArity")) (EVar "ctorArities"))) (EApp (EApp (EVar "map") (EVar "toCtorType")) (EVar "ctorTypes"))) (EApp (EApp (EVar "map") (EVar "toCImplEntry")) (EVar "impls")))) (arm (PVar "other") () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CProgram: ")) (EApp (EVar "sexprToStr") (EVar "other")))))))
(DTypeSig false "sexprToStr" (TyFun (TyCon "SExp") (TyCon "String")))
(DFunDef false "sexprToStr" ((PCon "SAtom" (PVar "s"))) (EVar "s"))
(DFunDef false "sexprToStr" ((PCon "SList" (PVar "xs"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "joinSexps") (EVar "xs"))) (ELit (LString ")"))))
(DTypeSig false "joinSexps" (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyCon "String")))
(DFunDef false "joinSexps" ((PList)) (ELit (LString "")))
(DFunDef false "joinSexps" ((PList (PVar "x"))) (EApp (EVar "sexprToStr") (EVar "x")))
(DFunDef false "joinSexps" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "sexprToStr") (EVar "x")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "joinSexps") (EVar "rest")))) (ELit (LString ""))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Addr" true) (mem "Route" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CProgram" true) (mem "CTree" true) (mem "CTBranch" true) (mem "CHead" true))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DData Public "SToken" () ((variant "TOpen" (ConPos)) (variant "TClose" (ConPos)) (variant "TAtom" (ConPos (TyCon "String")))) ())
(DTypeSig false "tokenize" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "SToken"))))
(DFunDef false "tokenize" ((PVar "s")) (EApp (EApp (EVar "tokFrom") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))))
(DTypeSig false "buildSlice" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "buildSlice" ((PVar "cs") (PVar "i") (PVar "end")) (EApp (EVar "stringConcat") (EApp (EApp (EApp (EVar "sliceChars") (EVar "cs")) (EVar "i")) (EVar "end"))))
(DTypeSig false "sliceChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "sliceChars" ((PVar "cs") (PVar "i") (PVar "end")) (EIf (EBinOp ">=" (EVar "i") (EVar "end")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "sliceChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "end"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isSpaceChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isSpaceChar" ((PLit (LChar " "))) (EVar "True"))
(DFunDef false "isSpaceChar" ((PLit (LChar "\n"))) (EVar "True"))
(DFunDef false "isSpaceChar" ((PLit (LChar "\t"))) (EVar "True"))
(DFunDef false "isSpaceChar" ((PLit (LChar "\r"))) (EVar "True"))
(DFunDef false "isSpaceChar" (PWild) (EVar "False"))
(DTypeSig false "tokFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "SToken")))))
(DFunDef false "tokFrom" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LChar "("))) (EBinOp "::" (EVar "TOpen") (EApp (EApp (EVar "tokFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar ")"))) (EBinOp "::" (EVar "TClose") (EApp (EApp (EVar "tokFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "tokQuoted") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EListLit)) (EIf (EApp (EVar "isSpaceChar") (EVar "c")) (EApp (EApp (EVar "tokFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "tokWord") (EVar "cs")) (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tokWord" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "SToken"))))))
(DFunDef false "tokWord" ((PVar "cs") (PVar "start") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit (EApp (EVar "TAtom") (EApp (EApp (EApp (EVar "buildSlice") (EVar "cs")) (EVar "start")) (EVar "i")))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LChar "("))) (EBinOp "::" (EApp (EVar "TAtom") (EApp (EApp (EApp (EVar "buildSlice") (EVar "cs")) (EVar "start")) (EVar "i"))) (EBinOp "::" (EVar "TOpen") (EApp (EApp (EVar "tokFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar ")"))) (EBinOp "::" (EApp (EVar "TAtom") (EApp (EApp (EApp (EVar "buildSlice") (EVar "cs")) (EVar "start")) (EVar "i"))) (EBinOp "::" (EVar "TClose") (EApp (EApp (EVar "tokFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EIf (EApp (EVar "isSpaceChar") (EVar "c")) (EBinOp "::" (EApp (EVar "TAtom") (EApp (EApp (EApp (EVar "buildSlice") (EVar "cs")) (EVar "start")) (EVar "i"))) (EApp (EApp (EVar "tokFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EApp (EApp (EVar "tokWord") (EVar "cs")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tokQuoted" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "SToken"))))))
(DFunDef false "tokQuoted" ((PVar "cs") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit (EApp (EVar "TAtom") (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "stringConcat") (EApp (EVar "reverseL") (EVar "acc")))) (ELit (LString "\""))))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (EBinOp "::" (EApp (EVar "TAtom") (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "stringConcat") (EApp (EVar "reverseL") (EVar "acc")))) (ELit (LString "\"")))) (EApp (EApp (EVar "tokFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "\\"))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "cs")))) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs"))) (DoExpr (EApp (EApp (EApp (EVar "tokQuoted") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EBinOp "::" (EApp (EVar "escPair") (EVar "next")) (EVar "acc"))))) (EApp (EApp (EApp (EVar "tokQuoted") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "charToStr") (EVar "c")) (EVar "acc"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "escPair" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "escPair" ((PLit (LChar "n"))) (ELit (LString "\\n")))
(DFunDef false "escPair" ((PLit (LChar "t"))) (ELit (LString "\\t")))
(DFunDef false "escPair" ((PLit (LChar "r"))) (ELit (LString "\\r")))
(DFunDef false "escPair" ((PLit (LChar "\""))) (ELit (LString "\\\"")))
(DFunDef false "escPair" ((PLit (LChar "\\"))) (ELit (LString "\\\\")))
(DFunDef false "escPair" ((PVar "c")) (EApp (EVar "charToStr") (EVar "c")))
(DData Public "SExp" () ((variant "SAtom" (ConPos (TyCon "String"))) (variant "SList" (ConPos (TyApp (TyCon "List") (TyCon "SExp"))))) ())
(DTypeSig false "parseSexp" (TyFun (TyApp (TyCon "List") (TyCon "SToken")) (TyTuple (TyCon "SExp") (TyApp (TyCon "List") (TyCon "SToken")))))
(DFunDef false "parseSexp" ((PCons (PCon "TOpen") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "children") (PVar "rest2")) (EApp (EVar "parseList") (EVar "rest"))) (DoExpr (ETuple (EApp (EVar "SList") (EVar "children")) (EVar "rest2")))))
(DFunDef false "parseSexp" ((PCons (PCon "TAtom" (PVar "s")) (PVar "rest"))) (ETuple (EApp (EVar "SAtom") (EVar "s")) (EVar "rest")))
(DFunDef false "parseSexp" ((PCons (PCon "TClose") PWild)) (EApp (EVar "panic") (ELit (LString "core_ir_sexp_parse: unexpected ')'"))))
(DFunDef false "parseSexp" ((PList)) (EApp (EVar "panic") (ELit (LString "core_ir_sexp_parse: unexpected end of input"))))
(DTypeSig false "parseList" (TyFun (TyApp (TyCon "List") (TyCon "SToken")) (TyTuple (TyApp (TyCon "List") (TyCon "SExp")) (TyApp (TyCon "List") (TyCon "SToken")))))
(DFunDef false "parseList" ((PCons (PCon "TClose") (PVar "rest"))) (ETuple (EListLit) (EVar "rest")))
(DFunDef false "parseList" ((PVar "ts")) (EBlock (DoLet false false (PTuple (PVar "s") (PVar "rest")) (EApp (EVar "parseSexp") (EVar "ts"))) (DoLet false false (PTuple (PVar "more") (PVar "rest2")) (EApp (EVar "parseList") (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "s") (EVar "more")) (EVar "rest2")))))
(DTypeSig false "parseAll" (TyFun (TyCon "String") (TyCon "SExp")))
(DFunDef false "parseAll" ((PVar "s")) (EMatch (EApp (EVar "parseSexp") (EApp (EVar "tokenize") (EVar "s"))) (arm (PTuple (PVar "sexp") PWild) () (EVar "sexp"))))
(DTypeSig false "unquote" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unquote" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EIf (EBinOp "<" (EVar "n") (ELit (LInt 2))) (EVar "s") (EApp (EVar "stringConcat") (EApp (EApp (EApp (EVar "unqFrom") (EVar "cs")) (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))))))))
(DTypeSig false "unqFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "unqFrom" ((PVar "cs") (PVar "i") (PVar "lim")) (EIf (EBinOp ">=" (EVar "i") (EVar "lim")) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "\\"))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "lim"))) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs"))) (DoExpr (EBinOp "::" (EApp (EVar "unescOne") (EVar "next")) (EApp (EApp (EApp (EVar "unqFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "lim"))))) (EBinOp "::" (EApp (EVar "charToStr") (EVar "c")) (EApp (EApp (EApp (EVar "unqFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "lim")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "unescOne" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "unescOne" ((PLit (LChar "n"))) (ELit (LString "\n")))
(DFunDef false "unescOne" ((PLit (LChar "t"))) (ELit (LString "\t")))
(DFunDef false "unescOne" ((PLit (LChar "r"))) (ELit (LString "\r")))
(DFunDef false "unescOne" ((PLit (LChar "\""))) (ELit (LString "\"")))
(DFunDef false "unescOne" ((PLit (LChar "\\"))) (ELit (LString "\\")))
(DFunDef false "unescOne" ((PVar "c")) (EApp (EVar "charToStr") (EVar "c")))
(DTypeSig false "toStr" (TyFun (TyCon "SExp") (TyCon "String")))
(DFunDef false "toStr" ((PCon "SAtom" (PVar "s"))) (EApp (EVar "unquote") (EVar "s")))
(DFunDef false "toStr" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: expected atom, got list: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toBool" (TyFun (TyCon "SExp") (TyCon "Bool")))
(DFunDef false "toBool" ((PCon "SAtom" (PLit (LString "true")))) (EVar "True"))
(DFunDef false "toBool" ((PCon "SAtom" (PLit (LString "false")))) (EVar "False"))
(DFunDef false "toBool" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: expected bool: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "parseIntStr" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "parseIntStr" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "core_ir_sexp_parse: empty int"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")) (ELit (LChar "-"))) (EBinOp "-" (ELit (LInt 0)) (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "cs")) (ELit (LInt 1))) (EVar "n")) (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "cs")) (ELit (LInt 0))) (EVar "n")) (ELit (LInt 0))))))))
(DTypeSig false "parseDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "parseDigits" ((PVar "cs") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "-" (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")))) (EApp (EVar "charCode") (ELit (LChar "0"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "toInt" (TyFun (TyCon "SExp") (TyCon "Int")))
(DFunDef false "toInt" ((PCon "SAtom" (PVar "s"))) (EApp (EVar "parseIntStr") (EVar "s")))
(DFunDef false "toInt" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: expected int atom: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toLit" (TyFun (TyCon "SExp") (TyCon "Lit")))
(DFunDef false "toLit" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "LInt"))) (PList (PVar "n"))))) (EApp (EVar "LInt") (EApp (EVar "toInt") (EVar "n"))))
(DFunDef false "toLit" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "LFloat"))) (PList (PVar "f"))))) (EMatch (EApp (EVar "stringToFloat") (EApp (EVar "toStr") (EVar "f"))) (arm (PCon "Some" (PVar "x")) () (EApp (EVar "LFloat") (EVar "x"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "core_ir_sexp_parse: bad float"))))))
(DFunDef false "toLit" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "LString"))) (PList (PVar "s"))))) (EApp (EVar "LString") (EApp (EVar "toStr") (EVar "s"))))
(DFunDef false "toLit" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "LChar"))) (PList (PVar "c"))))) (EApp (EVar "LChar") (EApp (EVar "toStr") (EVar "c"))))
(DFunDef false "toLit" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "LBool"))) (PList (PVar "b"))))) (EApp (EVar "LBool") (EApp (EVar "toBool") (EVar "b"))))
(DFunDef false "toLit" ((PCon "SAtom" (PLit (LString "LUnit")))) (EVar "LUnit"))
(DFunDef false "toLit" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad Lit: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toRecPatField" (TyFun (TyCon "SExp") (TyCon "RecPatField")))
(DFunDef false "toRecPatField" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "rf"))) (PList (PVar "f") (PCon "SAtom" (PLit (LString "None"))))))) (EApp (EApp (EVar "RecPatField") (EApp (EVar "toStr") (EVar "f"))) (EVar "None")))
(DFunDef false "toRecPatField" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "rf"))) (PList (PVar "f") (PVar "p"))))) (EApp (EApp (EVar "RecPatField") (EApp (EVar "toStr") (EVar "f"))) (EApp (EVar "Some") (EApp (EVar "toPat") (EVar "p")))))
(DFunDef false "toRecPatField" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad RecPatField: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toPat" (TyFun (TyCon "SExp") (TyCon "Pat")))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PVar"))) (PList (PVar "n"))))) (EApp (EVar "PVar") (EApp (EVar "toStr") (EVar "n"))))
(DFunDef false "toPat" ((PCon "SAtom" (PLit (LString "PWild")))) (EVar "PWild"))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PLit"))) (PList (PVar "l"))))) (EApp (EVar "PLit") (EApp (EVar "toLit") (EVar "l"))))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PCon"))) (PCons (PVar "name") (PVar "args"))))) (EApp (EApp (EVar "PCon") (EApp (EVar "toStr") (EVar "name"))) (EApp (EApp (EMethodRef "map") (EVar "toPat")) (EVar "args"))))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PCons"))) (PList (PVar "h") (PVar "t"))))) (EApp (EApp (EVar "PCons") (EApp (EVar "toPat") (EVar "h"))) (EApp (EVar "toPat") (EVar "t"))))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PTuple"))) (PVar "ps")))) (EApp (EVar "PTuple") (EApp (EApp (EMethodRef "map") (EVar "toPat")) (EVar "ps"))))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PList"))) (PVar "ps")))) (EApp (EVar "PList") (EApp (EApp (EMethodRef "map") (EVar "toPat")) (EVar "ps"))))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PAs"))) (PList (PVar "n") (PVar "p"))))) (EApp (EApp (EVar "PAs") (EApp (EVar "toStr") (EVar "n"))) (EApp (EVar "toPat") (EVar "p"))))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PRng"))) (PList (PVar "lo") (PVar "hi") (PVar "incl"))))) (EApp (EApp (EApp (EVar "PRng") (EApp (EVar "toLit") (EVar "lo"))) (EApp (EVar "toLit") (EVar "hi"))) (EApp (EVar "toBool") (EVar "incl"))))
(DFunDef false "toPat" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "PRec"))) (PList (PVar "name") (PCon "SList" (PVar "fields")) (PVar "rest"))))) (EApp (EApp (EApp (EVar "PRec") (EApp (EVar "toStr") (EVar "name"))) (EApp (EApp (EMethodRef "map") (EVar "toRecPatField")) (EVar "fields"))) (EApp (EVar "toBool") (EVar "rest"))))
(DFunDef false "toPat" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad Pat: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toAddr" (TyFun (TyCon "SExp") (TyCon "Addr")))
(DFunDef false "toAddr" ((PCon "SAtom" (PLit (LString "AGlobal")))) (EVar "AGlobal"))
(DFunDef false "toAddr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "ALocal"))) (PList (PVar "frame") (PVar "slot"))))) (EApp (EApp (EVar "ALocal") (EApp (EVar "toInt") (EVar "frame"))) (EApp (EVar "toInt") (EVar "slot"))))
(DFunDef false "toAddr" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad Addr: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toRoute" (TyFun (TyCon "SExp") (TyCon "Route")))
(DFunDef false "toRoute" ((PCon "SAtom" (PLit (LString "RNone")))) (EVar "RNone"))
(DFunDef false "toRoute" ((PCon "SAtom" (PLit (LString "RLocal")))) (EApp (EApp (EVar "RLocal") (ELit (LString ""))) (EListLit)))
(DFunDef false "toRoute" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "RLocal"))) (PList (PVar "s"))))) (EApp (EApp (EVar "RLocal") (EApp (EVar "toStr") (EVar "s"))) (EListLit)))
(DFunDef false "toRoute" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "RKey"))) (PList (PVar "k"))))) (EApp (EApp (EVar "RKey") (EApp (EVar "toStr") (EVar "k"))) (EListLit)))
(DFunDef false "toRoute" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "RDict"))) (PList (PVar "d"))))) (EApp (EVar "RDict") (EApp (EVar "toStr") (EVar "d"))))
(DFunDef false "toRoute" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "RDictFwd"))) (PList (PVar "d"))))) (EApp (EVar "RDictFwd") (EApp (EVar "toStr") (EVar "d"))))
(DFunDef false "toRoute" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "RScalar"))) (PList (PVar "s"))))) (EApp (EVar "RScalar") (EApp (EVar "toStr") (EVar "s"))))
(DFunDef false "toRoute" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad Route: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCField" (TyFun (TyCon "SExp") (TyCon "CField")))
(DFunDef false "toCField" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "cf"))) (PList (PVar "name") (PVar "e"))))) (EApp (EApp (EVar "CField") (EApp (EVar "toStr") (EVar "name"))) (EApp (EVar "toCExpr") (EVar "e"))))
(DFunDef false "toCField" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CField: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCGuard" (TyFun (TyCon "SExp") (TyCon "CGuard")))
(DFunDef false "toCGuard" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CGBool"))) (PList (PVar "e"))))) (EApp (EVar "CGBool") (EApp (EVar "toCExpr") (EVar "e"))))
(DFunDef false "toCGuard" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CGBind"))) (PList (PVar "p") (PVar "e"))))) (EApp (EApp (EVar "CGBind") (EApp (EVar "toPat") (EVar "p"))) (EApp (EVar "toCExpr") (EVar "e"))))
(DFunDef false "toCGuard" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CGuard: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toArm" (TyFun (TyCon "SExp") (TyCon "CArm")))
(DFunDef false "toArm" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "arm"))) (PList (PVar "pat") (PCon "SList" (PVar "guards")) (PVar "body"))))) (EApp (EApp (EApp (EVar "CArm") (EApp (EVar "toPat") (EVar "pat"))) (EApp (EApp (EMethodRef "map") (EVar "toCGuard")) (EVar "guards"))) (EApp (EVar "toCExpr") (EVar "body"))))
(DFunDef false "toArm" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CArm: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCStmt" (TyFun (TyCon "SExp") (TyCon "CStmt")))
(DFunDef false "toCStmt" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CSExpr"))) (PList (PVar "e"))))) (EApp (EVar "CSExpr") (EApp (EVar "toCExpr") (EVar "e"))))
(DFunDef false "toCStmt" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CSLet"))) (PList (PVar "isRec") (PVar "pat") (PVar "e"))))) (EApp (EApp (EApp (EVar "CSLet") (EApp (EVar "toBool") (EVar "isRec"))) (EApp (EVar "toPat") (EVar "pat"))) (EApp (EVar "toCExpr") (EVar "e"))))
(DFunDef false "toCStmt" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CSAssign"))) (PList (PVar "x") (PVar "e"))))) (EApp (EApp (EVar "CSAssign") (EApp (EVar "toStr") (EVar "x"))) (EApp (EVar "toCExpr") (EVar "e"))))
(DFunDef false "toCStmt" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CStmt: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCHead" (TyFun (TyCon "SExp") (TyCon "CHead")))
(DFunDef false "toCHead" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "HCon"))) (PList (PVar "name") (PVar "arity"))))) (EApp (EApp (EVar "HCon") (EApp (EVar "toStr") (EVar "name"))) (EApp (EVar "toInt") (EVar "arity"))))
(DFunDef false "toCHead" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "HTuple"))) (PList (PVar "arity"))))) (EApp (EVar "HTuple") (EApp (EVar "toInt") (EVar "arity"))))
(DFunDef false "toCHead" ((PCon "SAtom" (PLit (LString "HCons")))) (EVar "HCons"))
(DFunDef false "toCHead" ((PCon "SAtom" (PLit (LString "HNil")))) (EVar "HNil"))
(DFunDef false "toCHead" ((PCon "SAtom" (PLit (LString "HUnit")))) (EVar "HUnit"))
(DFunDef false "toCHead" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "HLit"))) (PList (PVar "l"))))) (EApp (EVar "HLit") (EApp (EVar "toLit") (EVar "l"))))
(DFunDef false "toCHead" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CHead: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCTree" (TyFun (TyCon "SExp") (TyCon "CTree")))
(DFunDef false "toCTree" ((PCon "SAtom" (PLit (LString "CTFail")))) (EVar "CTFail"))
(DFunDef false "toCTree" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CTLeaf"))) (PList (PVar "i"))))) (EApp (EVar "CTLeaf") (EApp (EVar "toInt") (EVar "i"))))
(DFunDef false "toCTree" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CTGuard"))) (PList (PVar "i") (PVar "fail"))))) (EApp (EApp (EVar "CTGuard") (EApp (EVar "toInt") (EVar "i"))) (EApp (EVar "toCTree") (EVar "fail"))))
(DFunDef false "toCTree" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CTSwitch"))) (PList (PCon "SList" (PVar "branches")) (PVar "dflt"))))) (EApp (EApp (EVar "CTSwitch") (EApp (EApp (EMethodRef "map") (EVar "toCTBranch")) (EVar "branches"))) (EApp (EVar "toCTree") (EVar "dflt"))))
(DFunDef false "toCTree" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CTDrop"))) (PList (PVar "tree"))))) (EApp (EVar "CTDrop") (EApp (EVar "toCTree") (EVar "tree"))))
(DFunDef false "toCTree" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CTree: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCTBranch" (TyFun (TyCon "SExp") (TyCon "CTBranch")))
(DFunDef false "toCTBranch" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CTBranch"))) (PList (PVar "head") (PVar "tree"))))) (EApp (EApp (EVar "CTBranch") (EApp (EVar "toCHead") (EVar "head"))) (EApp (EVar "toCTree") (EVar "tree"))))
(DFunDef false "toCTBranch" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CTBranch: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCExpr" (TyFun (TyCon "SExp") (TyCon "CExpr")))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CLit"))) (PList (PVar "l"))))) (EApp (EVar "CLit") (EApp (EVar "toLit") (EVar "l"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CVar"))) (PList (PVar "name") (PVar "addr"))))) (EApp (EApp (EVar "CVar") (EApp (EVar "toStr") (EVar "name"))) (EApp (EVar "toAddr") (EVar "addr"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CApp"))) (PList (PVar "f") (PVar "x"))))) (EApp (EApp (EVar "CApp") (EApp (EVar "toCExpr") (EVar "f"))) (EApp (EVar "toCExpr") (EVar "x"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CLam"))) (PList (PCon "SList" (PVar "pats")) (PVar "body"))))) (EApp (EApp (EVar "CLam") (EApp (EApp (EMethodRef "map") (EVar "toPat")) (EVar "pats"))) (EApp (EVar "toCExpr") (EVar "body"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CLet"))) (PList (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2"))))) (EApp (EApp (EApp (EApp (EVar "CLet") (EApp (EVar "toBool") (EVar "isRec"))) (EApp (EVar "toPat") (EVar "pat"))) (EApp (EVar "toCExpr") (EVar "e1"))) (EApp (EVar "toCExpr") (EVar "e2"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CLetGroup"))) (PList (PCon "SList" (PVar "binds")) (PVar "body"))))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EMethodRef "map") (EVar "toCBind")) (EVar "binds"))) (EApp (EVar "toCExpr") (EVar "body"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CMatch"))) (PCons (PVar "scrut") (PVar "arms"))))) (EApp (EApp (EVar "CMatch") (EApp (EVar "toCExpr") (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EVar "toArm")) (EVar "arms"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CDecision"))) (PList (PVar "scrut") (PCon "SList" (PVar "arms")) (PVar "tree"))))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EVar "toCExpr") (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EVar "toArm")) (EVar "arms"))) (EApp (EVar "toCTree") (EVar "tree"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CIf"))) (PList (PVar "c") (PVar "t") (PVar "e"))))) (EApp (EApp (EApp (EVar "CIf") (EApp (EVar "toCExpr") (EVar "c"))) (EApp (EVar "toCExpr") (EVar "t"))) (EApp (EVar "toCExpr") (EVar "e"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CBinPrim"))) (PList (PVar "op") (PVar "l") (PVar "r"))))) (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EApp (EVar "toStr") (EVar "op"))) (EApp (EVar "toCExpr") (EVar "l"))) (EApp (EVar "toCExpr") (EVar "r"))) (ELit (LString ""))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CBinPrim"))) (PList (PVar "op") (PVar "l") (PVar "r") (PVar "tag"))))) (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EApp (EVar "toStr") (EVar "op"))) (EApp (EVar "toCExpr") (EVar "l"))) (EApp (EVar "toCExpr") (EVar "r"))) (EApp (EVar "toStr") (EVar "tag"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CUnOp"))) (PList (PVar "op") (PVar "e"))))) (EApp (EApp (EVar "CUnOp") (EApp (EVar "toStr") (EVar "op"))) (EApp (EVar "toCExpr") (EVar "e"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CTuple"))) (PVar "es")))) (EApp (EVar "CTuple") (EApp (EApp (EMethodRef "map") (EVar "toCExpr")) (EVar "es"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CList"))) (PVar "es")))) (EApp (EVar "CList") (EApp (EApp (EMethodRef "map") (EVar "toCExpr")) (EVar "es"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CRecord"))) (PCons (PVar "name") (PVar "fields"))))) (EApp (EApp (EVar "CRecord") (EApp (EVar "toStr") (EVar "name"))) (EApp (EApp (EMethodRef "map") (EVar "toCField")) (EVar "fields"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CFieldAccess"))) (PList (PVar "e") (PVar "f") (PVar "n"))))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EVar "toCExpr") (EVar "e"))) (EApp (EVar "toStr") (EVar "f"))) (EApp (EVar "toStr") (EVar "n"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CRecordUpdate"))) (PCons (PVar "base") (PVar "fields"))))) (EApp (EApp (EVar "CRecordUpdate") (EApp (EVar "toCExpr") (EVar "base"))) (EApp (EApp (EMethodRef "map") (EVar "toCField")) (EVar "fields"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CVariantUpdate"))) (PCons (PVar "con") (PCons (PVar "base") (PVar "fields")))))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EApp (EVar "toStr") (EVar "con"))) (EApp (EVar "toCExpr") (EVar "base"))) (EApp (EApp (EMethodRef "map") (EVar "toCField")) (EVar "fields"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CArray"))) (PVar "es")))) (EApp (EVar "CArray") (EApp (EApp (EMethodRef "map") (EVar "toCExpr")) (EVar "es"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CRangeList"))) (PList (PVar "lo") (PVar "hi") (PVar "incl"))))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EVar "toCExpr") (EVar "lo"))) (EApp (EVar "toCExpr") (EVar "hi"))) (EApp (EVar "toBool") (EVar "incl"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CRangeArray"))) (PList (PVar "lo") (PVar "hi") (PVar "incl"))))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EVar "toCExpr") (EVar "lo"))) (EApp (EVar "toCExpr") (EVar "hi"))) (EApp (EVar "toBool") (EVar "incl"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CIndex"))) (PList (PVar "a") (PVar "i"))))) (EApp (EApp (EVar "CIndex") (EApp (EVar "toCExpr") (EVar "a"))) (EApp (EVar "toCExpr") (EVar "i"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CSlice"))) (PList (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EVar "toCExpr") (EVar "a"))) (EApp (EVar "toCExpr") (EVar "lo"))) (EApp (EVar "toCExpr") (EVar "hi"))) (EApp (EVar "toBool") (EVar "incl"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CStringIndex"))) (PList (PVar "a") (PVar "i"))))) (EApp (EApp (EVar "CStringIndex") (EApp (EVar "toCExpr") (EVar "a"))) (EApp (EVar "toCExpr") (EVar "i"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CStringSlice"))) (PList (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EVar "toCExpr") (EVar "a"))) (EApp (EVar "toCExpr") (EVar "lo"))) (EApp (EVar "toCExpr") (EVar "hi"))) (EApp (EVar "toBool") (EVar "incl"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CListIndex"))) (PList (PVar "a") (PVar "i"))))) (EApp (EApp (EVar "CListIndex") (EApp (EVar "toCExpr") (EVar "a"))) (EApp (EVar "toCExpr") (EVar "i"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CListSlice"))) (PList (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EVar "toCExpr") (EVar "a"))) (EApp (EVar "toCExpr") (EVar "lo"))) (EApp (EVar "toCExpr") (EVar "hi"))) (EApp (EVar "toBool") (EVar "incl"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CBlock"))) (PVar "stmts")))) (EApp (EVar "CBlock") (EApp (EApp (EMethodRef "map") (EVar "toCStmt")) (EVar "stmts"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CMethod"))) (PList (PVar "name") (PVar "route") (PCon "SList" (PVar "implRoutes")) (PCon "SList" (PVar "methRoutes")))))) (EApp (EApp (EApp (EApp (EVar "CMethod") (EApp (EVar "toStr") (EVar "name"))) (EApp (EVar "toRoute") (EVar "route"))) (EApp (EApp (EMethodRef "map") (EVar "toRoute")) (EVar "implRoutes"))) (EApp (EApp (EMethodRef "map") (EVar "toRoute")) (EVar "methRoutes"))))
(DFunDef false "toCExpr" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CDict"))) (PList (PVar "name") (PCon "SList" (PVar "routes")))))) (EApp (EApp (EVar "CDict") (EApp (EVar "toStr") (EVar "name"))) (EApp (EApp (EMethodRef "map") (EVar "toRoute")) (EVar "routes"))))
(DFunDef false "toCExpr" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CExpr: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCClause" (TyFun (TyCon "SExp") (TyCon "CClause")))
(DFunDef false "toCClause" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CClause"))) (PList (PCon "SList" (PVar "pats")) (PVar "body"))))) (EApp (EApp (EVar "CClause") (EApp (EApp (EMethodRef "map") (EVar "toPat")) (EVar "pats"))) (EApp (EVar "toCExpr") (EVar "body"))))
(DFunDef false "toCClause" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CClause: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCBind" (TyFun (TyCon "SExp") (TyCon "CBind")))
(DFunDef false "toCBind" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CBind"))) (PCons (PVar "name") (PVar "clauses"))))) (EApp (EApp (EVar "CBind") (EApp (EVar "toStr") (EVar "name"))) (EApp (EApp (EMethodRef "map") (EVar "toCClause")) (EVar "clauses"))))
(DFunDef false "toCBind" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CBind: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCImplBody" (TyFun (TyCon "SExp") (TyCon "CImplBody")))
(DFunDef false "toCImplBody" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CImplTagged"))) (PList (PVar "tag") (PVar "key") (PVar "iface") (PCon "SList" (PVar "positions")) (PCon "SList" (PVar "pats")) (PVar "body"))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EApp (EVar "toStr") (EVar "tag"))) (EApp (EVar "toStr") (EVar "key"))) (EApp (EVar "toStr") (EVar "iface"))) (EApp (EApp (EMethodRef "map") (EVar "toInt")) (EVar "positions"))) (EApp (EApp (EMethodRef "map") (EVar "toPat")) (EVar "pats"))) (EApp (EVar "toCExpr") (EVar "body"))))
(DFunDef false "toCImplBody" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CImplDefault"))) (PList (PCon "SList" (PVar "pats")) (PVar "body"))))) (EApp (EApp (EVar "CImplDefault") (EApp (EApp (EMethodRef "map") (EVar "toPat")) (EVar "pats"))) (EApp (EVar "toCExpr") (EVar "body"))))
(DFunDef false "toCImplBody" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CImplBody: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCImplEntry" (TyFun (TyCon "SExp") (TyCon "CImplEntry")))
(DFunDef false "toCImplEntry" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CImplEntry"))) (PList (PVar "name") (PVar "score") (PVar "body"))))) (EApp (EApp (EApp (EVar "CImplEntry") (EApp (EVar "toStr") (EVar "name"))) (EApp (EVar "toInt") (EVar "score"))) (EApp (EVar "toCImplBody") (EVar "body"))))
(DFunDef false "toCImplEntry" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CImplEntry: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCtorArity" (TyFun (TyCon "SExp") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "toCtorArity" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "ca"))) (PList (PVar "name") (PVar "arity"))))) (ETuple (EApp (EVar "toStr") (EVar "name")) (EApp (EVar "toInt") (EVar "arity"))))
(DFunDef false "toCtorArity" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad ctor-arity: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig false "toCtorType" (TyFun (TyCon "SExp") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "toCtorType" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "ct"))) (PList (PVar "ctor") (PVar "ty"))))) (ETuple (EApp (EVar "toStr") (EVar "ctor")) (EApp (EVar "toStr") (EVar "ty"))))
(DFunDef false "toCtorType" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad ctor-type: ")) (EApp (EVar "sexprToStr") (EVar "other")))))
(DTypeSig true "parseCProgram" (TyFun (TyCon "String") (TyCon "CProgram")))
(DFunDef false "parseCProgram" ((PVar "s")) (EMatch (EApp (EVar "parseAll") (EVar "s")) (arm (PCon "SList" (PCons (PCon "SAtom" (PLit (LString "CProgram"))) (PList (PCon "SList" (PVar "binds")) (PCon "SList" (PVar "ctorArities")) (PCon "SList" (PVar "ctorTypes")) (PCon "SList" (PVar "impls"))))) () (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EMethodRef "map") (EVar "toCBind")) (EVar "binds"))) (EApp (EApp (EMethodRef "map") (EVar "toCtorArity")) (EVar "ctorArities"))) (EApp (EApp (EMethodRef "map") (EVar "toCtorType")) (EVar "ctorTypes"))) (EApp (EApp (EMethodRef "map") (EVar "toCImplEntry")) (EVar "impls")))) (arm (PVar "other") () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir_sexp_parse: bad CProgram: ")) (EApp (EVar "sexprToStr") (EVar "other")))))))
(DTypeSig false "sexprToStr" (TyFun (TyCon "SExp") (TyCon "String")))
(DFunDef false "sexprToStr" ((PCon "SAtom" (PVar "s"))) (EVar "s"))
(DFunDef false "sexprToStr" ((PCon "SList" (PVar "xs"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "joinSexps") (EVar "xs"))) (ELit (LString ")"))))
(DTypeSig false "joinSexps" (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyCon "String")))
(DFunDef false "joinSexps" ((PList)) (ELit (LString "")))
(DFunDef false "joinSexps" ((PList (PVar "x"))) (EApp (EVar "sexprToStr") (EVar "x")))
(DFunDef false "joinSexps" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "sexprToStr") (EVar "x")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "joinSexps") (EVar "rest")))) (ELit (LString ""))))
