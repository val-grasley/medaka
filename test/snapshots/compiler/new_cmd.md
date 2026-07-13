# META
source_lines=64
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted implementation of `medaka new <name>`.
-- Mirrors lib/new_cmd.ml exactly: same files, same byte content, same error
-- messages and exit codes.
--
-- Usage (from new_main.mdk):
--   newProject name  ->  exit code Int

-- True if the name contains character c.
nameContainsChar : Char -> String -> Bool
nameContainsChar c name = isSome (stringIndexOf (charToStr c) name)

-- True if the project name is invalid.
invalidName : String -> Bool
invalidName name = name == ""
  || name == "."
  || name == ".."
  || nameContainsChar '/' name
  || nameContainsChar '\\' name

-- File templates, interpolating the project name where needed.
tomlTemplate : String -> String
tomlTemplate name = stringConcat
  [
    "[package]\nname = \"",
    name,
    "\"\nversion = \"0.1.0\"\nentry = \"main.mdk\"\n",
  ]

mainTemplate : String
mainTemplate = "main : <IO> Unit\nmain = println \"Hello, Medaka\"\n"

gitignoreTemplate : String
gitignoreTemplate = "_build/\n"

readmeTemplate : String -> String
readmeTemplate name = stringConcat ["# ", name, "\n\nA new Medaka project.\n"]

-- Write a file; panic on unexpected error (directory was just created).
writeProjectFile : String -> String -> <IO> Unit
writeProjectFile path contents = match writeFile path contents
  Ok _ => ()
  Err msg => panic ("medaka new: writeFile failed: " ++ msg)

-- Scaffold the project.  Returns the exit code.
export newProject : String -> <IO> Int
newProject name =
  if invalidName name then
    let _ = ePutStrLn ("medaka new: invalid project name: \"" ++ name ++ "\"")
    2
  else
    if fileExists name then
      let _ = ePutStrLn ("medaka new: path already exists: " ++ name)
      1
    else match makeDir name
      Err msg =>
        let _ = ePutStrLn ("medaka new: mkdir failed: " ++ msg)
        1
      Ok _ =>
        let _ = writeProjectFile (name ++ "/medaka.toml") (tomlTemplate name)
        let _ = writeProjectFile (name ++ "/main.mdk") mainTemplate
        let _ = writeProjectFile (name ++ "/.gitignore") gitignoreTemplate
        let _ = writeProjectFile (name ++ "/README.md") (readmeTemplate name)
        let _ = putStrLn ("Created " ++ name ++ "/")
        0
# DESUGAR
(DTypeSig false "nameContainsChar" (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "nameContainsChar" ((PVar "c") (PVar "name")) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (EApp (EVar "charToStr") (EVar "c"))) (EVar "name"))))
(DTypeSig false "invalidName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "invalidName" ((PVar "name")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString ""))) (EBinOp "==" (EVar "name") (ELit (LString ".")))) (EBinOp "==" (EVar "name") (ELit (LString "..")))) (EApp (EApp (EVar "nameContainsChar") (ELit (LChar "/"))) (EVar "name"))) (EApp (EApp (EVar "nameContainsChar") (ELit (LChar "\\"))) (EVar "name"))))
(DTypeSig false "tomlTemplate" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "tomlTemplate" ((PVar "name")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "[package]\nname = \"")) (EVar "name") (ELit (LString "\"\nversion = \"0.1.0\"\nentry = \"main.mdk\"\n")))))
(DTypeSig false "mainTemplate" (TyCon "String"))
(DFunDef false "mainTemplate" () (ELit (LString "main : <IO> Unit\nmain = println \"Hello, Medaka\"\n")))
(DTypeSig false "gitignoreTemplate" (TyCon "String"))
(DFunDef false "gitignoreTemplate" () (ELit (LString "_build/\n")))
(DTypeSig false "readmeTemplate" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "readmeTemplate" ((PVar "name")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "# ")) (EVar "name") (ELit (LString "\n\nA new Medaka project.\n")))))
(DTypeSig false "writeProjectFile" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "writeProjectFile" ((PVar "path") (PVar "contents")) (EMatch (EApp (EApp (EVar "writeFile") (EVar "path")) (EVar "contents")) (arm (PCon "Ok" PWild) () (ELit LUnit)) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "medaka new: writeFile failed: ")) (EVar "msg"))))))
(DTypeSig true "newProject" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Int"))))
(DFunDef false "newProject" ((PVar "name")) (EIf (EApp (EVar "invalidName") (EVar "name")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka new: invalid project name: \"")) (EVar "name")) (ELit (LString "\""))))) (DoExpr (ELit (LInt 2)))) (EIf (EApp (EVar "fileExists") (EVar "name")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (ELit (LString "medaka new: path already exists: ")) (EVar "name")))) (DoExpr (ELit (LInt 1)))) (EMatch (EApp (EVar "makeDir") (EVar "name")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (ELit (LString "medaka new: mkdir failed: ")) (EVar "msg")))) (DoExpr (ELit (LInt 1))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "writeProjectFile") (EBinOp "++" (EVar "name") (ELit (LString "/medaka.toml")))) (EApp (EVar "tomlTemplate") (EVar "name")))) (DoLet false false PWild (EApp (EApp (EVar "writeProjectFile") (EBinOp "++" (EVar "name") (ELit (LString "/main.mdk")))) (EVar "mainTemplate"))) (DoLet false false PWild (EApp (EApp (EVar "writeProjectFile") (EBinOp "++" (EVar "name") (ELit (LString "/.gitignore")))) (EVar "gitignoreTemplate"))) (DoLet false false PWild (EApp (EApp (EVar "writeProjectFile") (EBinOp "++" (EVar "name") (ELit (LString "/README.md")))) (EApp (EVar "readmeTemplate") (EVar "name")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "Created ")) (EVar "name")) (ELit (LString "/"))))) (DoExpr (ELit (LInt 0)))))))))
# MARK
(DTypeSig false "nameContainsChar" (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "nameContainsChar" ((PVar "c") (PVar "name")) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (EApp (EVar "charToStr") (EVar "c"))) (EVar "name"))))
(DTypeSig false "invalidName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "invalidName" ((PVar "name")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString ""))) (EBinOp "==" (EVar "name") (ELit (LString ".")))) (EBinOp "==" (EVar "name") (ELit (LString "..")))) (EApp (EApp (EVar "nameContainsChar") (ELit (LChar "/"))) (EVar "name"))) (EApp (EApp (EVar "nameContainsChar") (ELit (LChar "\\"))) (EVar "name"))))
(DTypeSig false "tomlTemplate" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "tomlTemplate" ((PVar "name")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "[package]\nname = \"")) (EVar "name") (ELit (LString "\"\nversion = \"0.1.0\"\nentry = \"main.mdk\"\n")))))
(DTypeSig false "mainTemplate" (TyCon "String"))
(DFunDef false "mainTemplate" () (ELit (LString "main : <IO> Unit\nmain = println \"Hello, Medaka\"\n")))
(DTypeSig false "gitignoreTemplate" (TyCon "String"))
(DFunDef false "gitignoreTemplate" () (ELit (LString "_build/\n")))
(DTypeSig false "readmeTemplate" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "readmeTemplate" ((PVar "name")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "# ")) (EVar "name") (ELit (LString "\n\nA new Medaka project.\n")))))
(DTypeSig false "writeProjectFile" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "writeProjectFile" ((PVar "path") (PVar "contents")) (EMatch (EApp (EApp (EVar "writeFile") (EVar "path")) (EVar "contents")) (arm (PCon "Ok" PWild) () (ELit LUnit)) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "medaka new: writeFile failed: ")) (EVar "msg"))))))
(DTypeSig true "newProject" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Int"))))
(DFunDef false "newProject" ((PVar "name")) (EIf (EApp (EVar "invalidName") (EVar "name")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka new: invalid project name: \"")) (EVar "name")) (ELit (LString "\""))))) (DoExpr (ELit (LInt 2)))) (EIf (EApp (EVar "fileExists") (EVar "name")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (ELit (LString "medaka new: path already exists: ")) (EVar "name")))) (DoExpr (ELit (LInt 1)))) (EMatch (EApp (EVar "makeDir") (EVar "name")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (ELit (LString "medaka new: mkdir failed: ")) (EVar "msg")))) (DoExpr (ELit (LInt 1))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "writeProjectFile") (EBinOp "++" (EVar "name") (ELit (LString "/medaka.toml")))) (EApp (EVar "tomlTemplate") (EVar "name")))) (DoLet false false PWild (EApp (EApp (EVar "writeProjectFile") (EBinOp "++" (EVar "name") (ELit (LString "/main.mdk")))) (EVar "mainTemplate"))) (DoLet false false PWild (EApp (EApp (EVar "writeProjectFile") (EBinOp "++" (EVar "name") (ELit (LString "/.gitignore")))) (EVar "gitignoreTemplate"))) (DoLet false false PWild (EApp (EApp (EVar "writeProjectFile") (EBinOp "++" (EVar "name") (ELit (LString "/README.md")))) (EApp (EVar "readmeTemplate") (EVar "name")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "Created ")) (EVar "name")) (ELit (LString "/"))))) (DoExpr (ELit (LInt 0)))))))))
