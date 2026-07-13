# META
source_lines=22
stages=DESUGAR,MARK
# SOURCE
-- Triple-quoted strings: `"""…"""` keeps single/double quotes literal and
-- dedents (strip_indent) when the content opens with a raw newline; `\{…}`
-- interpolates just like a normal string.

inline = """one "quoted" line"""

block = """
  first
    indented
  last
  """

interp name = """
  Hello, \{name}!
  Bye.
  """

main : <IO> Unit
main =
  println inline
  println block
  println (interp "Medaka")
# DESUGAR
(DFunDef false "inline" () (ELit (LString "one \"quoted\" line")))
(DFunDef false "block" () (ELit (LString "first\n  indented\nlast\n")))
(DFunDef false "interp" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "\n  Hello, ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "!\n  Bye.\n  "))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EVar "inline"))) (DoExpr (EApp (EVar "println") (EVar "block"))) (DoExpr (EApp (EVar "println") (EApp (EVar "interp") (ELit (LString "Medaka")))))))
# MARK
(DFunDef false "inline" () (ELit (LString "one \"quoted\" line")))
(DFunDef false "block" () (ELit (LString "first\n  indented\nlast\n")))
(DFunDef false "interp" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "\n  Hello, ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "!\n  Bye.\n  "))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EVar "inline"))) (DoExpr (EApp (EDictApp "println") (EVar "block"))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "interp") (ELit (LString "Medaka")))))))
