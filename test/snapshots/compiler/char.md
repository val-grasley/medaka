# META
source_lines=51
stages=DESUGAR,MARK
# SOURCE
-- Shared ASCII Char -> Bool predicates for the self-hosted compiler stages.
-- compiler deliberately avoids the standard library, so the small character
-- classification helpers the lexer/parser/lsp need live here once instead of
-- being re-implemented per file.  Impls match lib/lexer.mll's char classes.

export isSp : Char -> Bool
isSp c = c == ' '

export isTab : Char -> Bool
isTab c = c == '\t'

export isNL : Char -> Bool
isNL c = c == '\n'

export isCR : Char -> Bool
isCR c = c == '\r'

export isQuote : Char -> Bool
isQuote c = c == '"'

export isApos : Char -> Bool
isApos c = c == '\''

export isBackslash : Char -> Bool
isBackslash c = c == '\\'

export isBacktick : Char -> Bool
isBacktick c = c == '`'

export isSpace : Char -> Bool
isSpace c = isSp c || isTab c

export isDigit : Char -> Bool
isDigit c = c >= '0' && c <= '9'

export isLower : Char -> Bool
isLower c = c >= 'a' && c <= 'z'

export isUpper : Char -> Bool
isUpper c = c >= 'A' && c <= 'Z'

export isAlnum : Char -> Bool
isAlnum c = isLower c || isUpper c || isDigit c || c == '_' || isApos c

export isHexDigit : Char -> Bool
isHexDigit c = isDigit c || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'

-- Identifier-continuation char (a-z A-Z 0-9 _ ').  Mirrors
-- lib/lsp_server.ml's is_ident_char.
export isIdentChar : Char -> Bool
isIdentChar c = isAlnum c
# DESUGAR
(DTypeSig true "isSp" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isSp" ((PVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar " "))))
(DTypeSig true "isTab" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isTab" ((PVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "\t"))))
(DTypeSig true "isNL" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isNL" ((PVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "\n"))))
(DTypeSig true "isCR" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isCR" ((PVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "\r"))))
(DTypeSig true "isQuote" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isQuote" ((PVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "\""))))
(DTypeSig true "isApos" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isApos" ((PVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "'"))))
(DTypeSig true "isBackslash" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isBackslash" ((PVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "\\"))))
(DTypeSig true "isBacktick" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isBacktick" ((PVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "`"))))
(DTypeSig true "isSpace" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isSpace" ((PVar "c")) (EBinOp "||" (EApp (EVar "isSp") (EVar "c")) (EApp (EVar "isTab") (EVar "c"))))
(DTypeSig true "isDigit" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isDigit" ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "9")))))
(DTypeSig true "isLower" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isLower" ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "z")))))
(DTypeSig true "isUpper" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isUpper" ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "A"))) (EBinOp "<=" (EVar "c") (ELit (LChar "Z")))))
(DTypeSig true "isAlnum" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isAlnum" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isLower") (EVar "c")) (EApp (EVar "isUpper") (EVar "c"))) (EApp (EVar "isDigit") (EVar "c"))) (EBinOp "==" (EVar "c") (ELit (LChar "_")))) (EApp (EVar "isApos") (EVar "c"))))
(DTypeSig true "isHexDigit" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isHexDigit" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EApp (EVar "isDigit") (EVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "f"))))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "A"))) (EBinOp "<=" (EVar "c") (ELit (LChar "F"))))))
(DTypeSig true "isIdentChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isIdentChar" ((PVar "c")) (EApp (EVar "isAlnum") (EVar "c")))
# MARK
(DTypeSig true "isSp" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isSp" ((PVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar " "))))
(DTypeSig true "isTab" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isTab" ((PVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "\t"))))
(DTypeSig true "isNL" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isNL" ((PVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "\n"))))
(DTypeSig true "isCR" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isCR" ((PVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "\r"))))
(DTypeSig true "isQuote" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isQuote" ((PVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "\""))))
(DTypeSig true "isApos" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isApos" ((PVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "'"))))
(DTypeSig true "isBackslash" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isBackslash" ((PVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "\\"))))
(DTypeSig true "isBacktick" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isBacktick" ((PVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "`"))))
(DTypeSig true "isSpace" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isSpace" ((PVar "c")) (EBinOp "||" (EApp (EVar "isSp") (EVar "c")) (EApp (EVar "isTab") (EVar "c"))))
(DTypeSig true "isDigit" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isDigit" ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "9")))))
(DTypeSig true "isLower" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isLower" ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "z")))))
(DTypeSig true "isUpper" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isUpper" ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "A"))) (EBinOp "<=" (EVar "c") (ELit (LChar "Z")))))
(DTypeSig true "isAlnum" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isAlnum" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isLower") (EVar "c")) (EApp (EVar "isUpper") (EVar "c"))) (EApp (EVar "isDigit") (EVar "c"))) (EBinOp "==" (EVar "c") (ELit (LChar "_")))) (EApp (EVar "isApos") (EVar "c"))))
(DTypeSig true "isHexDigit" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isHexDigit" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EApp (EVar "isDigit") (EVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "f"))))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "A"))) (EBinOp "<=" (EVar "c") (ELit (LChar "F"))))))
(DTypeSig true "isIdentChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isIdentChar" ((PVar "c")) (EApp (EVar "isAlnum") (EVar "c")))
