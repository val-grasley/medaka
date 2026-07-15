# META
source_lines=49
stages=TOKENS,DESUGAR,MARK
# SOURCE
addN : Int -> Int -> Int
addN x y = x + y

arith : Int -> Int -> Int
arith a b = a +
  b *
  2

sub : Int -> Int -> Int
sub a b = a -
  b

divmod : Int -> Int -> Int
divmod a b = a /
  b %
  3

cmp : Int -> Int -> Bool
cmp a b = a ==
  b

cmp2 : Int -> Int -> Bool
cmp2 a b = a <
  b

logic : Bool -> Bool -> Bool
logic p q = p &&
  q ||
  False

listcat : List Int -> List Int -> List Int
listcat xs ys = xs ++
  ys

cons : Int -> List Int -> List Int
cons h t = h ::
  t

pipeline : Int -> Int
pipeline x = x |>
  addN 1

composeR : Int -> Int
composeR x = (addN 1 >> addN 2) x

composeL : Int -> Int
composeL x = (addN 1 << addN 2) x

main = println (arith 3 4)
# TOKENS
IDENT "addN"
COLON
UPPER "Int"
ARROW
UPPER "Int"
ARROW
UPPER "Int"
NEWLINE
IDENT "addN"
IDENT "x"
IDENT "y"
EQUAL
IDENT "x"
PLUS
IDENT "y"
NEWLINE
IDENT "arith"
COLON
UPPER "Int"
ARROW
UPPER "Int"
ARROW
UPPER "Int"
NEWLINE
IDENT "arith"
IDENT "a"
IDENT "b"
EQUAL
IDENT "a"
PLUS
IDENT "b"
STAR
INT 2
NEWLINE
IDENT "sub"
COLON
UPPER "Int"
ARROW
UPPER "Int"
ARROW
UPPER "Int"
NEWLINE
IDENT "sub"
IDENT "a"
IDENT "b"
EQUAL
IDENT "a"
MINUS
IDENT "b"
NEWLINE
IDENT "divmod"
COLON
UPPER "Int"
ARROW
UPPER "Int"
ARROW
UPPER "Int"
NEWLINE
IDENT "divmod"
IDENT "a"
IDENT "b"
EQUAL
IDENT "a"
SLASH
IDENT "b"
MOD
INT 3
NEWLINE
IDENT "cmp"
COLON
UPPER "Int"
ARROW
UPPER "Int"
ARROW
UPPER "Bool"
NEWLINE
IDENT "cmp"
IDENT "a"
IDENT "b"
EQUAL
IDENT "a"
EQ_EQ
IDENT "b"
NEWLINE
IDENT "cmp2"
COLON
UPPER "Int"
ARROW
UPPER "Int"
ARROW
UPPER "Bool"
NEWLINE
IDENT "cmp2"
IDENT "a"
IDENT "b"
EQUAL
IDENT "a"
LT
IDENT "b"
NEWLINE
IDENT "logic"
COLON
UPPER "Bool"
ARROW
UPPER "Bool"
ARROW
UPPER "Bool"
NEWLINE
IDENT "logic"
IDENT "p"
IDENT "q"
EQUAL
IDENT "p"
AND
IDENT "q"
OR
UPPER "False"
NEWLINE
IDENT "listcat"
COLON
UPPER "List"
UPPER "Int"
ARROW
UPPER "List"
UPPER "Int"
ARROW
UPPER "List"
UPPER "Int"
NEWLINE
IDENT "listcat"
IDENT "xs"
IDENT "ys"
EQUAL
IDENT "xs"
PLUSPLUS
IDENT "ys"
NEWLINE
IDENT "cons"
COLON
UPPER "Int"
ARROW
UPPER "List"
UPPER "Int"
ARROW
UPPER "List"
UPPER "Int"
NEWLINE
IDENT "cons"
IDENT "h"
IDENT "t"
EQUAL
IDENT "h"
CONS
IDENT "t"
NEWLINE
IDENT "pipeline"
COLON
UPPER "Int"
ARROW
UPPER "Int"
NEWLINE
IDENT "pipeline"
IDENT "x"
EQUAL
IDENT "x"
PIPE_RIGHT
IDENT "addN"
INT 1
NEWLINE
IDENT "composeR"
COLON
UPPER "Int"
ARROW
UPPER "Int"
NEWLINE
IDENT "composeR"
IDENT "x"
EQUAL
LPAREN
IDENT "addN"
INT 1
RCOMPOSE
IDENT "addN"
INT 2
RPAREN
IDENT "x"
NEWLINE
IDENT "composeL"
COLON
UPPER "Int"
ARROW
UPPER "Int"
NEWLINE
IDENT "composeL"
IDENT "x"
EQUAL
LPAREN
IDENT "addN"
INT 1
LCOMPOSE
IDENT "addN"
INT 2
RPAREN
IDENT "x"
NEWLINE
IDENT "main"
EQUAL
IDENT "println"
LPAREN
IDENT "arith"
INT 3
INT 4
RPAREN
NEWLINE
NEWLINE
EOF
# DESUGAR
(DTypeSig false "addN" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "addN" ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))
(DTypeSig false "arith" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "arith" ((PVar "a") (PVar "b")) (EBinOp "+" (EVar "a") (EBinOp "*" (EVar "b") (ELit (LInt 2)))))
(DTypeSig false "sub" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "sub" ((PVar "a") (PVar "b")) (EBinOp "-" (EVar "a") (EVar "b")))
(DTypeSig false "divmod" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "divmod" ((PVar "a") (PVar "b")) (EBinOp "%" (EBinOp "/" (EVar "a") (EVar "b")) (ELit (LInt 3))))
(DTypeSig false "cmp" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "cmp" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))
(DTypeSig false "cmp2" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "cmp2" ((PVar "a") (PVar "b")) (EBinOp "<" (EVar "a") (EVar "b")))
(DTypeSig false "logic" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "logic" ((PVar "p") (PVar "q")) (EBinOp "||" (EBinOp "&&" (EVar "p") (EVar "q")) (EVar "False")))
(DTypeSig false "listcat" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "listcat" ((PVar "xs") (PVar "ys")) (EBinOp "++" (EVar "xs") (EVar "ys")))
(DTypeSig false "cons" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "cons" ((PVar "h") (PVar "t")) (EBinOp "::" (EVar "h") (EVar "t")))
(DTypeSig false "pipeline" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "pipeline" ((PVar "x")) (EBinOp "|>" (EVar "x") (EApp (EVar "addN") (ELit (LInt 1)))))
(DTypeSig false "composeR" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "composeR" ((PVar "x")) (EApp (EBinOp ">>" (EApp (EVar "addN") (ELit (LInt 1))) (EApp (EVar "addN") (ELit (LInt 2)))) (EVar "x")))
(DTypeSig false "composeL" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "composeL" ((PVar "x")) (EApp (EBinOp "<<" (EApp (EVar "addN") (ELit (LInt 1))) (EApp (EVar "addN") (ELit (LInt 2)))) (EVar "x")))
(DFunDef false "main" () (EApp (EVar "println") (EApp (EApp (EVar "arith") (ELit (LInt 3))) (ELit (LInt 4)))))
# MARK
(DTypeSig false "addN" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "addN" ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))
(DTypeSig false "arith" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "arith" ((PVar "a") (PVar "b")) (EBinOp "+" (EVar "a") (EBinOp "*" (EVar "b") (ELit (LInt 2)))))
(DTypeSig false "sub#shadow" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "sub#shadow" ((PVar "a") (PVar "b")) (EBinOp "-" (EVar "a") (EVar "b")))
(DTypeSig false "divmod" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "divmod" ((PVar "a") (PVar "b")) (EBinOp "%" (EBinOp "/" (EVar "a") (EVar "b")) (ELit (LInt 3))))
(DTypeSig false "cmp" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "cmp" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))
(DTypeSig false "cmp2" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "cmp2" ((PVar "a") (PVar "b")) (EBinOp "<" (EVar "a") (EVar "b")))
(DTypeSig false "logic" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "logic" ((PVar "p") (PVar "q")) (EBinOp "||" (EBinOp "&&" (EVar "p") (EVar "q")) (EVar "False")))
(DTypeSig false "listcat" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "listcat" ((PVar "xs") (PVar "ys")) (EBinOp "++" (EVar "xs") (EVar "ys")))
(DTypeSig false "cons" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "cons" ((PVar "h") (PVar "t")) (EBinOp "::" (EVar "h") (EVar "t")))
(DTypeSig false "pipeline" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "pipeline" ((PVar "x")) (EBinOp "|>" (EVar "x") (EApp (EVar "addN") (ELit (LInt 1)))))
(DTypeSig false "composeR" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "composeR" ((PVar "x")) (EApp (EBinOp ">>" (EApp (EVar "addN") (ELit (LInt 1))) (EApp (EVar "addN") (ELit (LInt 2)))) (EVar "x")))
(DTypeSig false "composeL" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "composeL" ((PVar "x")) (EApp (EBinOp "<<" (EApp (EVar "addN") (ELit (LInt 1))) (EApp (EVar "addN") (ELit (LInt 2)))) (EVar "x")))
(DFunDef false "main" () (EApp (EDictApp "println") (EApp (EApp (EVar "arith") (ELit (LInt 3))) (ELit (LInt 4)))))
