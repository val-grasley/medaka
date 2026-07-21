# META
source_lines=22
stages=TOKENS,DESUGAR,MARK
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
# TOKENS
NEWLINE
IDENT "inline"
EQUAL
STRING "one \"quoted\" line"
NEWLINE
IDENT "block"
EQUAL
STRING "first\n  indented\nlast\n"
NEWLINE
IDENT "interp"
IDENT "name"
EQUAL
INTERP_OPEN "Hello, "
IDENT "name"
INTERP_END "!\nBye.\n"
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
IDENT "inline"
NEWLINE
IDENT "println"
IDENT "block"
NEWLINE
IDENT "println"
LPAREN
IDENT "interp"
STRING "Medaka"
RPAREN
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "inline" () (ELit (LString "one \"quoted\" line")))
(DFunDef false "block" () (ELit (LString "first\n  indented\nlast\n")))
(DFunDef false "interp" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "Hello, ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "!\nBye.\n"))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EVar "inline"))) (DoExpr (EApp (EVar "println") (EVar "block"))) (DoExpr (EApp (EVar "println") (EApp (EVar "interp") (ELit (LString "Medaka")))))))
# MARK
(DFunDef false "inline" () (ELit (LString "one \"quoted\" line")))
(DFunDef false "block" () (ELit (LString "first\n  indented\nlast\n")))
(DFunDef false "interp" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "Hello, ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "!\nBye.\n"))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EVar "inline"))) (DoExpr (EApp (EDictApp "println") (EVar "block"))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "interp") (ELit (LString "Medaka")))))))
