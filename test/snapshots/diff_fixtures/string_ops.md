# META
source_lines=13
stages=TOKENS,DESUGAR,MARK
# SOURCE
greet name = "Hello, " ++ name ++ "!"

repeat n s =
  match n
    0 => ""
    n => s ++ repeat (n - 1) s

main : <IO> Unit
main =
  println (greet "Medaka")
  println (repeat 3 "ab")
  let x = 42
  println "value: \{x}"
# TOKENS
IDENT "greet"
IDENT "name"
EQUAL
STRING "Hello, "
PLUSPLUS
IDENT "name"
PLUSPLUS
STRING "!"
NEWLINE
IDENT "repeat"
IDENT "n"
IDENT "s"
EQUAL
INDENT
MATCH
IDENT "n"
INDENT
INT 0
FAT_ARROW
STRING ""
NEWLINE
IDENT "n"
FAT_ARROW
IDENT "s"
PLUSPLUS
IDENT "repeat"
LPAREN
IDENT "n"
MINUS
INT 1
RPAREN
IDENT "s"
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
IDENT "greet"
STRING "Medaka"
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "repeat"
INT 3
STRING "ab"
RPAREN
NEWLINE
LET
IDENT "x"
EQUAL
INT 42
NEWLINE
IDENT "println"
INTERP_OPEN "value: "
IDENT "x"
INTERP_END ""
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "greet" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "Hello, ")) (EVar "name")) (ELit (LString "!"))))
(DFunDef false "repeat" ((PVar "n") (PVar "s")) (EMatch (EVar "n") (arm (PLit (LInt 0)) () (ELit (LString ""))) (arm (PVar "n") () (EBinOp "++" (EVar "s") (EApp (EApp (EVar "repeat") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s"))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EVar "greet") (ELit (LString "Medaka"))))) (DoExpr (EApp (EVar "println") (EApp (EApp (EVar "repeat") (ELit (LInt 3))) (ELit (LString "ab"))))) (DoLet false false (PVar "x") (ELit (LInt 42))) (DoExpr (EApp (EVar "println") (EBinOp "++" (EBinOp "++" (ELit (LString "value: ")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "")))))))
# MARK
(DFunDef false "greet" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "Hello, ")) (EVar "name")) (ELit (LString "!"))))
(DFunDef false "repeat" ((PVar "n") (PVar "s")) (EMatch (EVar "n") (arm (PLit (LInt 0)) () (ELit (LString ""))) (arm (PVar "n") () (EBinOp "++" (EVar "s") (EApp (EApp (EVar "repeat") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s"))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EVar "greet") (ELit (LString "Medaka"))))) (DoExpr (EApp (EDictApp "println") (EApp (EApp (EVar "repeat") (ELit (LInt 3))) (ELit (LString "ab"))))) (DoLet false false (PVar "x") (ELit (LInt 42))) (DoExpr (EApp (EDictApp "println") (EBinOp "++" (EBinOp "++" (ELit (LString "value: ")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "")))))))
