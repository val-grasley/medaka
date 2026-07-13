# META
source_lines=93
stages=DESUGAR,MARK
# SOURCE
{- fs.mdk — a filesystem convenience layer over the host file externs.

   The irreducible host primitives are `extern`s in stdlib/runtime.mdk, so they
   are **global** (no import needed): `readFile`/`writeFile`/`appendFile`,
   `readFileBytes`/`writeFileBytes`, `fileExists`, `listDir`, `makeDir`,
   `removeFile`/`rename`/`removeDir`, `statFile`, `canonicalizePath`. This
   module (`import fs`) adds the ergonomic layer on top — a `FileStat` record
   wrapping `statFile`'s raw tuple, plus composed helpers (`copyFile`,
   `mkdirAll`, `walkDir`, `isDir`/`isFile`/`fileSize`).

   Conventions (mirroring stdlib/io.mdk): file ops return `Result String _`
   with the host error message (errno strerror) in `Err`. There is no IO monad —
   an action runs when it is evaluated, so you can `match copyFile src dst`
   directly.

   Scope: NATIVE/LLVM. Like every file extern, these execute only through the
   compiled (`medaka build`) path, not the tree-walking interpreter. -}

import core.{Result, Ok, Err}
import path.{dirname, joinPath}
import string.{contains}

-- ── FileStat: a named view of statFile's (Int, Bool, Bool, Float) tuple ──────

{- | The metadata `statFile` (stat(2)) returns for a path:
     `size` in bytes, `isDir`/`isFile` type flags, and `mtime` (modification
     time, seconds since the Unix epoch). -}
public export data FileStat =
  | FileStat { size : Int, isDir : Bool, isFile : Bool, mtime : Float }

{- | `stat path` — like `statFile`, but wraps the raw tuple in a `FileStat`.
     `Err` (strerror) if the path cannot be stat'd (e.g. does not exist). -}
export stat : String -> <FileRead "_"> Result String FileStat
stat p = map
  ((sz, d, f, m) => FileStat { size = sz, isDir = d, isFile = f, mtime = m })
  (statFile p)

-- ── Composed helpers ─────────────────────────────────────────────────────────

{- | `copyFile src dst` — byte-clean copy: read `src`'s raw bytes, write them to
     `dst` (truncating). Threads the `Result`, so a read failure short-circuits
     before any write. -}
export copyFile : String -> String -> <FileRead "_", FileWrite "_"> Result String Unit
copyFile src dst = match readFileBytes src
  Ok bytes => writeFileBytes dst bytes
  Err e => Err e

{- | `mkdirAll path` — create `path` and every missing parent directory (like
     `mkdir -p`). Recurses on `path.dirname`, so parents are created first. An
     already-existing directory (an `EEXIST`/"File exists" error from `makeDir`)
     is ignored; any other failure (e.g. permission denied) is reported. Stays
     `<FileWrite _>` — it never reads the filesystem, only writes. -}
export mkdirAll : String -> <FileWrite "_"> Result String Unit
mkdirAll path =
  if path == "" || path == "." || path == "/" then Ok ()
  else match mkdirAll (dirname path)
    Err e => Err e
    Ok _ => match makeDir path
      Ok _ => Ok ()
      -- EEXIST (strerror "File exists") is success; other errors propagate.
      Err e2 => if contains "exists" e2 then Ok () else Err e2

{- | `walkDir root` — recursively list everything under `root`. Returns FULL
     paths (each prefixed with `root` via `path.joinPath`), depth-first, and
     includes BOTH files and subdirectories. `Err` (strerror) on the first
     directory that cannot be read or entry that cannot be stat'd. -}
export walkDir : String -> <FileRead "_"> Result String (List String)
walkDir root = match listDir root
  Err e => Err e
  Ok entries => walkEntries root entries []

walkEntries : String -> List String -> List String -> <FileRead "_"> Result String (List String)
walkEntries _ [] acc = Ok acc
walkEntries root (name::rest) acc =
  let full = joinPath root name
  match stat full
    Err e => Err e
    Ok st => if st.isDir then match walkDir full
      Err e => Err e
      Ok sub => walkEntries root rest (acc ++ (full::sub))
    else walkEntries root rest (acc ++ [full])

{- | `isDir path` — `Ok True` if `path` exists and is a directory. -}
export isDir : String -> <FileRead "_"> Result String Bool
isDir p = map (st => st.isDir) (stat p)

{- | `isFile path` — `Ok True` if `path` exists and is a regular file. -}
export isFile : String -> <FileRead "_"> Result String Bool
isFile p = map (st => st.isFile) (stat p)

{- | `fileSize path` — the size of `path` in bytes. -}
export fileSize : String -> <FileRead "_"> Result String Int
fileSize p = map (st => st.size) (stat p)
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Result" false) (mem "Ok" false) (mem "Err" false))))
(DUse false (UseGroup ("path") ((mem "dirname" false) (mem "joinPath" false))))
(DUse false (UseGroup ("string") ((mem "contains" false))))
(DData Public "FileStat" () ((variant "FileStat" (ConNamed (field "size" (TyCon "Int")) (field "isDir" (TyCon "Bool")) (field "isFile" (TyCon "Bool")) (field "mtime" (TyCon "Float"))))) ())
(DTypeSig true "stat" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "FileStat")))))
(DFunDef false "stat" ((PVar "p")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "sz") (PVar "d") (PVar "f") (PVar "m"))) (ERecordCreate "FileStat" ((fa "size" (EVar "sz")) (fa "isDir" (EVar "d")) (fa "isFile" (EVar "f")) (fa "mtime" (EVar "m")))))) (EApp (EVar "statFile") (EVar "p"))))
(DTypeSig true "copyFile" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ((hole "FileRead") (hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "copyFile" ((PVar "src") (PVar "dst")) (EMatch (EApp (EVar "readFileBytes") (EVar "src")) (arm (PCon "Ok" (PVar "bytes")) () (EApp (EApp (EVar "writeFileBytes") (EVar "dst")) (EVar "bytes"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig true "mkdirAll" (TyFun (TyCon "String") (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "mkdirAll" ((PVar "path")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "path") (ELit (LString ""))) (EBinOp "==" (EVar "path") (ELit (LString ".")))) (EBinOp "==" (EVar "path") (ELit (LString "/")))) (EApp (EVar "Ok") (ELit LUnit)) (EMatch (EApp (EVar "mkdirAll") (EApp (EVar "dirname") (EVar "path"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EVar "makeDir") (EVar "path")) (arm (PCon "Ok" PWild) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PCon "Err" (PVar "e2")) () (EIf (EApp (EApp (EVar "contains") (ELit (LString "exists"))) (EVar "e2")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EVar "e2")))))))))
(DTypeSig true "walkDir" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "walkDir" ((PVar "root")) (EMatch (EApp (EVar "listDir") (EVar "root")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "entries")) (EListLit)))))
(DTypeSig false "walkEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "walkEntries" (PWild (PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "walkEntries" ((PVar "root") (PCons (PVar "name") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "stat") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "st")) () (EIf (EFieldAccess (EVar "st") "isDir") (EMatch (EApp (EVar "walkDir") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "sub")) () (EApp (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "rest")) (EBinOp "++" (EVar "acc") (EBinOp "::" (EVar "full") (EVar "sub")))))) (EApp (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "rest")) (EBinOp "++" (EVar "acc") (EListLit (EVar "full"))))))))))
(DTypeSig true "isDir" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "isDir" ((PVar "p")) (EApp (EApp (EVar "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "isDir"))) (EApp (EVar "stat") (EVar "p"))))
(DTypeSig true "isFile" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "isFile" ((PVar "p")) (EApp (EApp (EVar "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "isFile"))) (EApp (EVar "stat") (EVar "p"))))
(DTypeSig true "fileSize" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "fileSize" ((PVar "p")) (EApp (EApp (EVar "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "size"))) (EApp (EVar "stat") (EVar "p"))))
# MARK
(DUse false (UseGroup ("core") ((mem "Result" false) (mem "Ok" false) (mem "Err" false))))
(DUse false (UseGroup ("path") ((mem "dirname" false) (mem "joinPath" false))))
(DUse false (UseGroup ("string") ((mem "contains" false))))
(DData Public "FileStat" () ((variant "FileStat" (ConNamed (field "size" (TyCon "Int")) (field "isDir" (TyCon "Bool")) (field "isFile" (TyCon "Bool")) (field "mtime" (TyCon "Float"))))) ())
(DTypeSig true "stat" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "FileStat")))))
(DFunDef false "stat" ((PVar "p")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "sz") (PVar "d") (PVar "f") (PVar "m"))) (ERecordCreate "FileStat" ((fa "size" (EVar "sz")) (fa "isDir" (EVar "d")) (fa "isFile" (EVar "f")) (fa "mtime" (EVar "m")))))) (EApp (EVar "statFile") (EVar "p"))))
(DTypeSig true "copyFile" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ((hole "FileRead") (hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "copyFile" ((PVar "src") (PVar "dst")) (EMatch (EApp (EVar "readFileBytes") (EVar "src")) (arm (PCon "Ok" (PVar "bytes")) () (EApp (EApp (EVar "writeFileBytes") (EVar "dst")) (EVar "bytes"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig true "mkdirAll" (TyFun (TyCon "String") (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "mkdirAll" ((PVar "path")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "path") (ELit (LString ""))) (EBinOp "==" (EVar "path") (ELit (LString ".")))) (EBinOp "==" (EVar "path") (ELit (LString "/")))) (EApp (EVar "Ok") (ELit LUnit)) (EMatch (EApp (EVar "mkdirAll") (EApp (EVar "dirname") (EVar "path"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EVar "makeDir") (EVar "path")) (arm (PCon "Ok" PWild) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PCon "Err" (PVar "e2")) () (EIf (EApp (EApp (EVar "contains") (ELit (LString "exists"))) (EVar "e2")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EVar "e2")))))))))
(DTypeSig true "walkDir" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "walkDir" ((PVar "root")) (EMatch (EApp (EVar "listDir") (EVar "root")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "entries")) (EListLit)))))
(DTypeSig false "walkEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "walkEntries" (PWild (PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "walkEntries" ((PVar "root") (PCons (PVar "name") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "stat") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "st")) () (EIf (EFieldAccess (EVar "st") "isDir") (EMatch (EApp (EVar "walkDir") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "sub")) () (EApp (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "rest")) (EBinOp "++" (EVar "acc") (EBinOp "::" (EVar "full") (EMethodRef "sub")))))) (EApp (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "rest")) (EBinOp "++" (EVar "acc") (EListLit (EVar "full"))))))))))
(DTypeSig true "isDir" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "isDir" ((PVar "p")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "isDir"))) (EApp (EVar "stat") (EVar "p"))))
(DTypeSig true "isFile" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "isFile" ((PVar "p")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "isFile"))) (EApp (EVar "stat") (EVar "p"))))
(DTypeSig true "fileSize" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "fileSize" ((PVar "p")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "size"))) (EApp (EVar "stat") (EVar "p"))))
