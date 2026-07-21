# META
source_lines=11
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
-- #812: an `@`-pattern binds TIGHTER than `::`.  `t@(A _)::rest` must parse as
-- `PCons (PAs t (A _)) rest` (t bound to the HEAD element), not
-- `PAs t (PCons (A _) rest)` (t bound to the whole list).  Covers the head
-- position (function clause + match arm) and the tail position.

headAsCons ((t@(A _))::rest) = t
tailAsCons (x::t@(y::_)) = t

matchHeadAs xs = match xs
  (t@(A _))::rest => t
  _ => xs
# PARSE
(DFunDef false "headAsCons" ((PCons (PAs "t" (PCon "A" PWild)) (PVar "rest"))) (EVar "t"))
(DFunDef false "tailAsCons" ((PCons (PVar "x") (PAs "t" (PCons (PVar "y") PWild)))) (EVar "t"))
(DFunDef false "matchHeadAs" ((PVar "xs")) (EMatch (EVar "xs") (arm (PCons (PAs "t" (PCon "A" PWild)) (PVar "rest")) () (EVar "t")) (arm PWild () (EVar "xs"))))
# PRINTER
headAsCons ((t@(A _))::rest) = t
tailAsCons (x::t@(y::_)) = t
matchHeadAs xs = match xs
  (t@(A _))::rest => t
  _ => xs
# DESUGAR
(DFunDef false "headAsCons" ((PCons (PAs "t" (PCon "A" PWild)) (PVar "rest"))) (EVar "t"))
(DFunDef false "tailAsCons" ((PCons (PVar "x") (PAs "t" (PCons (PVar "y") PWild)))) (EVar "t"))
(DFunDef false "matchHeadAs" ((PVar "xs")) (EMatch (EVar "xs") (arm (PCons (PAs "t" (PCon "A" PWild)) (PVar "rest")) () (EVar "t")) (arm PWild () (EVar "xs"))))
# MARK
(DFunDef false "headAsCons" ((PCons (PAs "t" (PCon "A" PWild)) (PVar "rest"))) (EVar "t"))
(DFunDef false "tailAsCons" ((PCons (PVar "x") (PAs "t" (PCons (PVar "y") PWild)))) (EVar "t"))
(DFunDef false "matchHeadAs" ((PVar "xs")) (EMatch (EVar "xs") (arm (PCons (PAs "t" (PCon "A" PWild)) (PVar "rest")) () (EVar "t")) (arm PWild () (EVar "xs"))))
