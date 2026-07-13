# META
source_lines=66
stages=DESUGAR,MARK
# SOURCE
-- Shared filesystem-path string operations for the self-hosted compiler.
-- compiler deliberately avoids the standard library, so the POSIX-"/" path
-- helpers (dirname / basename / chop-extension / join) the module-entry mains
-- and the build/test drivers need live here once instead of per file.

-- dirname: the path up to (not including) the final "/"; "." if none.
export dirOf : String -> String
dirOf path = dirGo path (stringLength path)

dirGo : String -> Int -> String
dirGo _ 0 = "."
-- Intentional cross-file duplicate of the same helper in lsp.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
dirGo path i =
  if stringSlice (i - 1) i path == "/" then
    stringSlice 0 (i - 1) path
  else
    dirGo path (i - 1)

-- basename: the text after the final "/" (whole string if none).
export baseOf : String -> String
baseOf path = baseGo path (stringLength path) (stringLength path)

baseGo : String -> Int -> Int -> String
baseGo path end 0 = stringSlice 0 end path
baseGo path end i =
  if stringSlice (i - 1) i path == "/" then
    stringSlice i end path
  else
    baseGo path end (i - 1)

-- Alias of baseOf (kept for call sites that read more naturally as baseName).
export baseName : String -> String
baseName path = baseOf path

-- Drop a trailing ".ext" from the basename (no-op if the dot is before a "/").
export chopExt : String -> String
chopExt path = chopGo path (stringLength path)

chopGo : String -> Int -> String
chopGo path 0 = path
chopGo path i =
  let c = stringSlice (i - 1) i path
  if c == "/" then
    path
  else if c == "." then
    stringSlice 0 (i - 1) path
  else
    chopGo path (i - 1)
-- no extension in the basename

export joinPath : String -> String -> String
joinPath a b = "\{a}/\{b}"

-- Drop a trailing ".mdk".
export stripMdk : String -> String
stripMdk s =
  let n = stringLength s
  if n >= 4 && stringSlice (n - 4) n s == ".mdk" then
    stringSlice 0 (n - 4) s
  else
    s

-- Module id from a path: basename with the ".mdk" extension stripped.
export modIdOf : String -> String
modIdOf path = stripMdk (baseName path)
# DESUGAR
(DTypeSig true "dirOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirOf" ((PVar "path")) (EApp (EApp (EVar "dirGo") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "dirGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dirGo" (PWild (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "dirGo" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "dirGo") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "baseOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "baseOf" ((PVar "path")) (EApp (EApp (EApp (EVar "baseGo") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "baseGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "baseGo" ((PVar "path") (PVar "end") (PLit (LInt 0))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "end")) (EVar "path")))
(DFunDef false "baseGo" ((PVar "path") (PVar "end") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EVar "end")) (EVar "path")) (EApp (EApp (EApp (EVar "baseGo") (EVar "path")) (EVar "end")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "baseName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "baseName" ((PVar "path")) (EApp (EVar "baseOf") (EVar "path")))
(DTypeSig true "chopExt" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "chopExt" ((PVar "path")) (EApp (EApp (EVar "chopGo") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "chopGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "chopGo" ((PVar "path") (PLit (LInt 0))) (EVar "path"))
(DFunDef false "chopGo" ((PVar "path") (PVar "i")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LString "/"))) (EVar "path") (EIf (EBinOp "==" (EVar "c") (ELit (LString "."))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "chopGo") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))))))))
(DTypeSig true "joinPath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "joinPath" ((PVar "a") (PVar "b")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "b"))) (ELit (LString ""))))
(DTypeSig true "stripMdk" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripMdk" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 4)))) (EVar "n")) (EVar "s")) (ELit (LString ".mdk")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 4)))) (EVar "s")) (EVar "s")))))
(DTypeSig true "modIdOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "modIdOf" ((PVar "path")) (EApp (EVar "stripMdk") (EApp (EVar "baseName") (EVar "path"))))
# MARK
(DTypeSig true "dirOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirOf" ((PVar "path")) (EApp (EApp (EVar "dirGo") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "dirGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dirGo" (PWild (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "dirGo" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "dirGo") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "baseOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "baseOf" ((PVar "path")) (EApp (EApp (EApp (EVar "baseGo") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "baseGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "baseGo" ((PVar "path") (PVar "end") (PLit (LInt 0))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "end")) (EVar "path")))
(DFunDef false "baseGo" ((PVar "path") (PVar "end") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EVar "end")) (EVar "path")) (EApp (EApp (EApp (EVar "baseGo") (EVar "path")) (EVar "end")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "baseName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "baseName" ((PVar "path")) (EApp (EVar "baseOf") (EVar "path")))
(DTypeSig true "chopExt" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "chopExt" ((PVar "path")) (EApp (EApp (EVar "chopGo") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "chopGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "chopGo" ((PVar "path") (PLit (LInt 0))) (EVar "path"))
(DFunDef false "chopGo" ((PVar "path") (PVar "i")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LString "/"))) (EVar "path") (EIf (EBinOp "==" (EVar "c") (ELit (LString "."))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "chopGo") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))))))))
(DTypeSig true "joinPath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "joinPath" ((PVar "a") (PVar "b")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString ""))))
(DTypeSig true "stripMdk" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripMdk" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 4)))) (EVar "n")) (EVar "s")) (ELit (LString ".mdk")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 4)))) (EVar "s")) (EVar "s")))))
(DTypeSig true "modIdOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "modIdOf" ((PVar "path")) (EApp (EVar "stripMdk") (EApp (EVar "baseName") (EVar "path"))))
