# META
source_lines=15
stages=TOKENS,DESUGAR,MARK
# SOURCE
safeDiv n d =
  match d
    0 => None
    _ => Some (n / d)

showResult r =
  match r
    None => "error"
    Some x => "ok: \{x}"

main : <IO> Unit
main =
  println (showResult (safeDiv 10 2))
  println (showResult (safeDiv 10 0))
  println (showResult (safeDiv 7 3))
# TOKENS
IDENT "safeDiv"
IDENT "n"
IDENT "d"
EQUAL
INDENT
MATCH
IDENT "d"
INDENT
INT 0
FAT_ARROW
UPPER "None"
NEWLINE
UNDERSCORE
FAT_ARROW
UPPER "Some"
LPAREN
IDENT "n"
SLASH
IDENT "d"
RPAREN
NEWLINE
DEDENT
NEWLINE
DEDENT
NEWLINE
IDENT "showResult"
IDENT "r"
EQUAL
INDENT
MATCH
IDENT "r"
INDENT
UPPER "None"
FAT_ARROW
STRING "error"
NEWLINE
UPPER "Some"
IDENT "x"
FAT_ARROW
INTERP_OPEN "ok: "
IDENT "x"
INTERP_END ""
NEWLINE
DEDENT
NEWLINE
DEDENT
NEWLINE
IDENT "main"
COLON
LT
UPPER "IO"
GT
UPPER "Unit"
NEWLINE
IDENT "main"
EQUAL
INDENT
IDENT "println"
LPAREN
IDENT "showResult"
LPAREN
IDENT "safeDiv"
INT 10
INT 2
RPAREN
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "showResult"
LPAREN
IDENT "safeDiv"
INT 10
INT 0
RPAREN
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "showResult"
LPAREN
IDENT "safeDiv"
INT 7
INT 3
RPAREN
RPAREN
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "safeDiv" ((PVar "n") (PVar "d")) (EMatch (EVar "d") (arm (PLit (LInt 0)) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EBinOp "/" (EVar "n") (EVar "d"))))))
(DFunDef false "showResult" ((PVar "r")) (EMatch (EVar "r") (arm (PCon "None") () (ELit (LString "error"))) (arm (PCon "Some" (PVar "x")) () (EBinOp "++" (EBinOp "++" (ELit (LString "ok: ")) (EApp (EVar "display") (EVar "x"))) (ELit (LString ""))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EVar "showResult") (EApp (EApp (EVar "safeDiv") (ELit (LInt 10))) (ELit (LInt 2)))))) (DoExpr (EApp (EVar "println") (EApp (EVar "showResult") (EApp (EApp (EVar "safeDiv") (ELit (LInt 10))) (ELit (LInt 0)))))) (DoExpr (EApp (EVar "println") (EApp (EVar "showResult") (EApp (EApp (EVar "safeDiv") (ELit (LInt 7))) (ELit (LInt 3))))))))
# MARK
(DFunDef false "safeDiv" ((PVar "n") (PVar "d")) (EMatch (EVar "d") (arm (PLit (LInt 0)) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EBinOp "/" (EVar "n") (EVar "d"))))))
(DFunDef false "showResult" ((PVar "r")) (EMatch (EVar "r") (arm (PCon "None") () (ELit (LString "error"))) (arm (PCon "Some" (PVar "x")) () (EBinOp "++" (EBinOp "++" (ELit (LString "ok: ")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString ""))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EVar "showResult") (EApp (EApp (EVar "safeDiv") (ELit (LInt 10))) (ELit (LInt 2)))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "showResult") (EApp (EApp (EVar "safeDiv") (ELit (LInt 10))) (ELit (LInt 0)))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "showResult") (EApp (EApp (EVar "safeDiv") (ELit (LInt 7))) (ELit (LInt 3))))))))
