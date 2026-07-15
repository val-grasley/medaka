# META
source_lines=64
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
-- Rare/under-exercised grammar constructs, gathered so the self-hosted parser
-- (compiler/parser.mdk) still exercises these paths even though stdlib/compiler
-- barely use them. Validated byte-for-byte against the OCaml reference by
-- test/diff_compiler_parse.sh.
--
-- Covered here: operator sections, unary not, a
-- point-free one-arg match `x => match x { … }` (incl. an `if` arm guard), array
-- ranges `[|lo..hi|]`, array slices/index `e.[lo..hi]` / `e.[i]`, range
-- patterns (int + char), `Ref` + `:=` write, field assignment,
-- a do-block function-let, and record patterns `C { f = p, … }` / `C { .. }`.
-- (Other rares already live in the corpus: inclusive/exclusive list ranges +
-- array literals in where_ranges, bare/right +/* sections in sections_litpats,
-- record update in records, backtick infix in interfaces.)
--
-- Deliberately ABSENT — no AST node in compiler yet (would break the harness):
-- nested string interpolation and triple-quoted strings (lexer-side only).

leftSection = (2 * _)

cmpSection = (== 0)

notFlag b = !b

classify = x => match x
  0 => "zero"
  n if n < 0 => "neg"
  n => "pos"

arrRange = [|1..5|]

arrRangeIncl = [|0..=9|]

sliceIt xs = xs.[1..3]

sliceInclIt xs = xs.[1..=3]

indexIt xs = xs.[0]

grade n = match n
  0..59 => "F"
  60..=100 => "P"

vowelKind c = match c
  'a'..'z' => "lower"
  _ => "other"

counter =
  let a = Ref 0
  a := a.value + 1
  a.value

setField r =
  r.x = 1
  r.pos.y = 2

doFunLet =
  let twice = n => n + n
  twice 21

shape s = match s
  Point { x = px, y = py } => px + py
  Circle { radius } => radius
  Box { w, ... } => w
  Empty { ... } => 0
# PARSE
(DFunDef false "leftSection" () (ESection (SecLeft (ELit (LInt 2)) "*")))
(DFunDef false "cmpSection" () (ESection (SecRight "==" (ELit (LInt 0)))))
(DFunDef false "notFlag" ((PVar "b")) (EUnOp "!" (EVar "b")))
(DFunDef false "classify" () (ELam ((PVar "x")) (EMatch (EVar "x") (arm (PLit (LInt 0)) () (ELit (LString "zero"))) (arm (PVar "n") ((GBool (EBinOp "<" (EVar "n") (ELit (LInt 0))))) (ELit (LString "neg"))) (arm (PVar "n") () (ELit (LString "pos"))))))
(DFunDef false "arrRange" () (ERangeArray (ELit (LInt 1)) (ELit (LInt 5)) false))
(DFunDef false "arrRangeIncl" () (ERangeArray (ELit (LInt 0)) (ELit (LInt 9)) true))
(DFunDef false "sliceIt" ((PVar "xs")) (ESlice (EVar "xs") (ELit (LInt 1)) (ELit (LInt 3)) false))
(DFunDef false "sliceInclIt" ((PVar "xs")) (ESlice (EVar "xs") (ELit (LInt 1)) (ELit (LInt 3)) true))
(DFunDef false "indexIt" ((PVar "xs")) (EIndex (EVar "xs") (ELit (LInt 0))))
(DFunDef false "grade" ((PVar "n")) (EMatch (EVar "n") (arm (PRng (LInt 0) (LInt 59) false) () (ELit (LString "F"))) (arm (PRng (LInt 60) (LInt 100) true) () (ELit (LString "P")))))
(DFunDef false "vowelKind" ((PVar "c")) (EMatch (EVar "c") (arm (PRng (LChar "a") (LChar "z") false) () (ELit (LString "lower"))) (arm PWild () (ELit (LString "other")))))
(DFunDef false "counter" () (EBlock (DoLet false false (PVar "a") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoExpr (EBinOp ":=" (EVar "a") (EBinOp "+" (EFieldAccess (EVar "a") "value") (ELit (LInt 1))))) (DoExpr (EFieldAccess (EVar "a") "value"))))
(DFunDef false "setField" ((PVar "r")) (EBlock (DoFieldAssign "r" ("x") (ELit (LInt 1))) (DoFieldAssign "r" ("pos" "y") (ELit (LInt 2)))))
(DFunDef false "doFunLet" () (EBlock (DoLet false false (PVar "twice") (ELam ((PVar "n")) (EBinOp "+" (EVar "n") (EVar "n")))) (DoExpr (EApp (EVar "twice") (ELit (LInt 21))))))
(DFunDef false "shape" ((PVar "s")) (EMatch (EVar "s") (arm (PRec "Point" ((rf "x" (PVar "px")) (rf "y" (PVar "py"))) false) () (EBinOp "+" (EVar "px") (EVar "py"))) (arm (PRec "Circle" ((rf "radius" None)) false) () (EVar "radius")) (arm (PRec "Box" ((rf "w" None)) true) () (EVar "w")) (arm (PRec "Empty" () true) () (ELit (LInt 0)))))
# PRINTER
leftSection = (2 * _)
cmpSection = (== 0)
notFlag b = !b
classify = x => match x
  0 => "zero"
  n if n < 0 => "neg"
  n => "pos"
arrRange = [|1..5|]
arrRangeIncl = [|0..=9|]
sliceIt xs = xs.[1..3]
sliceInclIt xs = xs.[1..=3]
indexIt xs = xs[0]
grade n = match n
  0..59 => "F"
  60..=100 => "P"
vowelKind c = match c
  'a'..'z' => "lower"
  _ => "other"
counter =
  let a = Ref 0
  a := a.value + 1
  a.value
setField r =
  r.x = 1
  r.pos.y = 2
doFunLet =
  let twice = n => n + n
  twice 21
shape s = match s
  Point { x = px, y = py } => px + py
  Circle { radius } => radius
  Box { w, ... } => w
  Empty { ... } => 0
# DESUGAR
(DFunDef false "leftSection" () (ELam ((PVar "_s")) (EBinOp "*" (ELit (LInt 2)) (EVar "_s"))))
(DFunDef false "cmpSection" () (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (ELit (LInt 0)))))
(DFunDef false "notFlag" ((PVar "b")) (EUnOp "!" (EVar "b")))
(DFunDef false "classify" () (ELam ((PVar "x")) (EMatch (EVar "x") (arm (PLit (LInt 0)) () (ELit (LString "zero"))) (arm (PVar "n") ((GBool (EBinOp "<" (EVar "n") (ELit (LInt 0))))) (ELit (LString "neg"))) (arm (PVar "n") () (ELit (LString "pos"))))))
(DFunDef false "arrRange" () (ERangeArray (ELit (LInt 1)) (ELit (LInt 5)) false))
(DFunDef false "arrRangeIncl" () (ERangeArray (ELit (LInt 0)) (ELit (LInt 9)) true))
(DFunDef false "sliceIt" ((PVar "xs")) (ESlice (EVar "xs") (ELit (LInt 1)) (ELit (LInt 3)) false))
(DFunDef false "sliceInclIt" ((PVar "xs")) (ESlice (EVar "xs") (ELit (LInt 1)) (ELit (LInt 3)) true))
(DFunDef false "indexIt" ((PVar "xs")) (EApp (EApp (EVar "index") (EVar "xs")) (ELit (LInt 0))))
(DFunDef false "grade" ((PVar "n")) (EMatch (EVar "n") (arm (PRng (LInt 0) (LInt 59) false) () (ELit (LString "F"))) (arm (PRng (LInt 60) (LInt 100) true) () (ELit (LString "P")))))
(DFunDef false "vowelKind" ((PVar "c")) (EMatch (EVar "c") (arm (PRng (LChar "a") (LChar "z") false) () (ELit (LString "lower"))) (arm PWild () (ELit (LString "other")))))
(DFunDef false "counter" () (EBlock (DoLet false false (PVar "a") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "a")) (EBinOp "+" (EFieldAccess (EVar "a") "value") (ELit (LInt 1))))) (DoExpr (EFieldAccess (EVar "a") "value"))))
(DFunDef false "setField" ((PVar "r")) (EBlock (DoFieldAssign "r" ("x") (ELit (LInt 1))) (DoFieldAssign "r" ("pos" "y") (ELit (LInt 2)))))
(DFunDef false "doFunLet" () (EBlock (DoLet false false (PVar "twice") (ELam ((PVar "n")) (EBinOp "+" (EVar "n") (EVar "n")))) (DoExpr (EApp (EVar "twice") (ELit (LInt 21))))))
(DFunDef false "shape" ((PVar "s")) (EMatch (EVar "s") (arm (PRec "Point" ((rf "x" (PVar "px")) (rf "y" (PVar "py"))) false) () (EBinOp "+" (EVar "px") (EVar "py"))) (arm (PRec "Circle" ((rf "radius" None)) false) () (EVar "radius")) (arm (PRec "Box" ((rf "w" None)) true) () (EVar "w")) (arm (PRec "Empty" () true) () (ELit (LInt 0)))))
# MARK
(DFunDef false "leftSection" () (ELam ((PVar "_s")) (EBinOp "*" (ELit (LInt 2)) (EVar "_s"))))
(DFunDef false "cmpSection" () (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (ELit (LInt 0)))))
(DFunDef false "notFlag" ((PVar "b")) (EUnOp "!" (EVar "b")))
(DFunDef false "classify" () (ELam ((PVar "x")) (EMatch (EVar "x") (arm (PLit (LInt 0)) () (ELit (LString "zero"))) (arm (PVar "n") ((GBool (EBinOp "<" (EVar "n") (ELit (LInt 0))))) (ELit (LString "neg"))) (arm (PVar "n") () (ELit (LString "pos"))))))
(DFunDef false "arrRange" () (ERangeArray (ELit (LInt 1)) (ELit (LInt 5)) false))
(DFunDef false "arrRangeIncl" () (ERangeArray (ELit (LInt 0)) (ELit (LInt 9)) true))
(DFunDef false "sliceIt" ((PVar "xs")) (ESlice (EVar "xs") (ELit (LInt 1)) (ELit (LInt 3)) false))
(DFunDef false "sliceInclIt" ((PVar "xs")) (ESlice (EVar "xs") (ELit (LInt 1)) (ELit (LInt 3)) true))
(DFunDef false "indexIt" ((PVar "xs")) (EApp (EApp (EMethodRef "index") (EVar "xs")) (ELit (LInt 0))))
(DFunDef false "grade" ((PVar "n")) (EMatch (EVar "n") (arm (PRng (LInt 0) (LInt 59) false) () (ELit (LString "F"))) (arm (PRng (LInt 60) (LInt 100) true) () (ELit (LString "P")))))
(DFunDef false "vowelKind" ((PVar "c")) (EMatch (EVar "c") (arm (PRng (LChar "a") (LChar "z") false) () (ELit (LString "lower"))) (arm PWild () (ELit (LString "other")))))
(DFunDef false "counter" () (EBlock (DoLet false false (PVar "a") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "a")) (EBinOp "+" (EFieldAccess (EVar "a") "value") (ELit (LInt 1))))) (DoExpr (EFieldAccess (EVar "a") "value"))))
(DFunDef false "setField" ((PVar "r")) (EBlock (DoFieldAssign "r" ("x") (ELit (LInt 1))) (DoFieldAssign "r" ("pos" "y") (ELit (LInt 2)))))
(DFunDef false "doFunLet" () (EBlock (DoLet false false (PVar "twice") (ELam ((PVar "n")) (EBinOp "+" (EVar "n") (EVar "n")))) (DoExpr (EApp (EVar "twice") (ELit (LInt 21))))))
(DFunDef false "shape" ((PVar "s")) (EMatch (EVar "s") (arm (PRec "Point" ((rf "x" (PVar "px")) (rf "y" (PVar "py"))) false) () (EBinOp "+" (EVar "px") (EVar "py"))) (arm (PRec "Circle" ((rf "radius" None)) false) () (EVar "radius")) (arm (PRec "Box" ((rf "w" None)) true) () (EVar "w")) (arm (PRec "Empty" () true) () (ELit (LInt 0)))))
