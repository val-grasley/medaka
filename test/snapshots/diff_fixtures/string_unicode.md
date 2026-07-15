# META
source_lines=11
stages=TOKENS,DESUGAR,MARK
# SOURCE
-- `\u{…}` unicode escapes inside string literals (Stage 1 lexer hardening).
-- ASCII-range codepoints only, so the `%S`/`debugStringLit` debug rendering of
-- the STRING token agrees byte-for-byte between the OCaml reference and the
-- self-hosted lexer.  `\u{48}` = 'H', `\u{69}` = 'i', `\u{21}` = '!'.
greeting : String
greeting = "\u{48}\u{69}"

shout : String
shout = "\{greeting}\u{21}"

main = println shout
# TOKENS
NEWLINE
IDENT "greeting"
COLON
UPPER "String"
NEWLINE
IDENT "greeting"
EQUAL
STRING "Hi"
NEWLINE
IDENT "shout"
COLON
UPPER "String"
NEWLINE
IDENT "shout"
EQUAL
INTERP_OPEN ""
IDENT "greeting"
INTERP_END "!"
NEWLINE
IDENT "main"
EQUAL
IDENT "println"
IDENT "shout"
NEWLINE
NEWLINE
EOF
# DESUGAR
(DTypeSig false "greeting" (TyCon "String"))
(DFunDef false "greeting" () (ELit (LString "Hi")))
(DTypeSig false "shout" (TyCon "String"))
(DFunDef false "shout" () (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "greeting"))) (ELit (LString "!"))))
(DFunDef false "main" () (EApp (EVar "println") (EVar "shout")))
# MARK
(DTypeSig false "greeting" (TyCon "String"))
(DFunDef false "greeting" () (ELit (LString "Hi")))
(DTypeSig false "shout" (TyCon "String"))
(DFunDef false "shout" () (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "greeting"))) (ELit (LString "!"))))
(DFunDef false "main" () (EApp (EDictApp "println") (EVar "shout")))
