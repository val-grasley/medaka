# META
source_lines=24
stages=PARSE,DESUGAR,MARK
# SOURCE
sum = fold (+) 0

product = fold (*) 1

addOne = map (+ 1)

keywordOrIdent "let" = TLet
keywordOrIdent "rec" = TRec
keywordOrIdent other = TIdent other

classify 'a' = Vowel
classify c = Other

unitArg () = 0

negArg = randomInt (-1000) 1000

-- negative integer range patterns (G8 case 2)
rangeClassify n =
  match n
    -10..-1 => "negative"
    0 => "zero"
    1..10 => "positive"
    _ => "large"
# PARSE
(DFunDef false "sum" () (EApp (EApp (EVar "fold") (ESection (SecBare "+"))) (ELit (LInt 0))))
(DFunDef false "product" () (EApp (EApp (EVar "fold") (ESection (SecBare "*"))) (ELit (LInt 1))))
(DFunDef false "addOne" () (EApp (EVar "map") (ESection (SecRight "+" (ELit (LInt 1))))))
(DFunDef false "keywordOrIdent" ((PLit (LString "let"))) (EVar "TLet"))
(DFunDef false "keywordOrIdent" ((PLit (LString "rec"))) (EVar "TRec"))
(DFunDef false "keywordOrIdent" ((PVar "other")) (EApp (EVar "TIdent") (EVar "other")))
(DFunDef false "classify" ((PLit (LChar "a"))) (EVar "Vowel"))
(DFunDef false "classify" ((PVar "c")) (EVar "Other"))
(DFunDef false "unitArg" ((PLit LUnit)) (ELit (LInt 0)))
(DFunDef false "negArg" () (EApp (EApp (EVar "randomInt") (EUnOp "-" (ELit (LInt 1000)))) (ELit (LInt 1000))))
(DFunDef false "rangeClassify" ((PVar "n")) (EMatch (EVar "n") (arm (PRng (LInt -10) (LInt -1) false) () (ELit (LString "negative"))) (arm (PLit (LInt 0)) () (ELit (LString "zero"))) (arm (PRng (LInt 1) (LInt 10) false) () (ELit (LString "positive"))) (arm PWild () (ELit (LString "large")))))
# DESUGAR
(DFunDef false "sum" () (EApp (EApp (EVar "fold") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "+" (EVar "_a") (EVar "_b")))) (ELit (LInt 0))))
(DFunDef false "product" () (EApp (EApp (EVar "fold") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "*" (EVar "_a") (EVar "_b")))) (ELit (LInt 1))))
(DFunDef false "addOne" () (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "+" (EVar "_s") (ELit (LInt 1))))))
(DFunDef false "keywordOrIdent" ((PLit (LString "let"))) (EVar "TLet"))
(DFunDef false "keywordOrIdent" ((PLit (LString "rec"))) (EVar "TRec"))
(DFunDef false "keywordOrIdent" ((PVar "other")) (EApp (EVar "TIdent") (EVar "other")))
(DFunDef false "classify" ((PLit (LChar "a"))) (EVar "Vowel"))
(DFunDef false "classify" ((PVar "c")) (EVar "Other"))
(DFunDef false "unitArg" ((PLit LUnit)) (ELit (LInt 0)))
(DFunDef false "negArg" () (EApp (EApp (EVar "randomInt") (EUnOp "-" (ELit (LInt 1000)))) (ELit (LInt 1000))))
(DFunDef false "rangeClassify" ((PVar "n")) (EMatch (EVar "n") (arm (PRng (LInt -10) (LInt -1) false) () (ELit (LString "negative"))) (arm (PLit (LInt 0)) () (ELit (LString "zero"))) (arm (PRng (LInt 1) (LInt 10) false) () (ELit (LString "positive"))) (arm PWild () (ELit (LString "large")))))
# MARK
(DFunDef false "sum" () (EApp (EApp (EMethodRef "fold") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "+" (EVar "_a") (EVar "_b")))) (ELit (LInt 0))))
(DFunDef false "product" () (EApp (EApp (EMethodRef "fold") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "*" (EVar "_a") (EVar "_b")))) (ELit (LInt 1))))
(DFunDef false "addOne" () (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "+" (EVar "_s") (ELit (LInt 1))))))
(DFunDef false "keywordOrIdent" ((PLit (LString "let"))) (EVar "TLet"))
(DFunDef false "keywordOrIdent" ((PLit (LString "rec"))) (EVar "TRec"))
(DFunDef false "keywordOrIdent" ((PVar "other")) (EApp (EVar "TIdent") (EVar "other")))
(DFunDef false "classify" ((PLit (LChar "a"))) (EVar "Vowel"))
(DFunDef false "classify" ((PVar "c")) (EVar "Other"))
(DFunDef false "unitArg" ((PLit LUnit)) (ELit (LInt 0)))
(DFunDef false "negArg" () (EApp (EApp (EVar "randomInt") (EUnOp "-" (ELit (LInt 1000)))) (ELit (LInt 1000))))
(DFunDef false "rangeClassify" ((PVar "n")) (EMatch (EVar "n") (arm (PRng (LInt -10) (LInt -1) false) () (ELit (LString "negative"))) (arm (PLit (LInt 0)) () (ELit (LString "zero"))) (arm (PRng (LInt 1) (LInt 10) false) () (ELit (LString "positive"))) (arm PWild () (ELit (LString "large")))))
