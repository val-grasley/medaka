# META
source_lines=309
stages=DESUGAR,MARK
# SOURCE
{- path.mdk — POSIX ("/"-separated) path manipulation.

   Pure string work: no filesystem access, no effects, no `IO`. Every function
   here treats a path as opaque text and reasons about it lexically, exactly
   like Go's `path` package or Python's `posixpath` — it never looks at the
   filesystem, so `normalize`/`dirname`/etc. can't tell a real directory from
   a dangling symlink.

   **Extension convention (documented choice).** `extname` returns the
   extension **including** the leading dot (`extname "a.txt" == ".txt"`),
   matching Go's `path.Ext` and Python's `os.path.splitext` (whose second
   element also keeps the dot). `extname "a" == ""` (no dot ⇒ no extension),
   and a leading-dot-only basename is treated as a hidden file with no
   extension (`extname ".bashrc" == ""`, `extname "..." == ""`) — the dot must
   have at least one non-dot character before it within the basename.

   **`normalize` convention** mirrors Go's `path.Clean`:
   - Collapse repeated `/`.
   - Eliminate `.` segments (except when the whole path is `.`).
   - Eliminate `..` together with the preceding non-`..` segment; a leading
     `..` on a relative path is kept (can't be resolved without a root);
     `..` at the root of an absolute path is dropped (`/..` → `/`).
   - The empty path normalizes to `"."`.
   - A trailing `/` is dropped unless the result is `/` itself.

   This module is the public-API sibling of the compiler-private
   `compiler/support/path.mdk` (which stays a minimal internal helper used by
   the self-hosted compiler's own module loader) — the two are not merged
   because `compiler/` deliberately avoids depending on `stdlib/`'s heavier
   surface for its own bootstrap path. -}

import string.{split, startsWith, endsWith, contains}

-- ── Components ───────────────────────────────────────────────────────────

{- | Directory portion of a path — everything up to (not including) the final
   `/`. `"."` if the path has no `/`. A trailing `/` is ignored (the last
   segment before it is still stripped as the basename).

   > dirname "a/b/c.txt"
   "a/b"

   > dirname "c.txt"
   "." -}
export dirname : String -> String
dirname path = dirnameGo path (stringLength path)

dirnameGo : String -> Int -> String
dirnameGo _ 0 = "."
dirnameGo path i =
  if stringSlice (i - 1) i path == "/" then
    let head = stringSlice 0 (i - 1) path
    if head == "" then "/" else head
  else dirnameGo path (i - 1)

{- | Final path component — the text after the last `/` (the whole string if
   there is none). A trailing `/` yields `""`, matching `path.Base`'s sibling
   `path.Split` semantics (use `normalize` first if you want `basename` to
   ignore a trailing slash).

   > basename "a/b/c.txt"
   "c.txt"

   > basename "c.txt"
   "c.txt"

   > basename "a/b/"
   "" -}
export basename : String -> String
basename path = basenameGo path (stringLength path) (stringLength path)

basenameGo : String -> Int -> Int -> String
basenameGo path end 0 = stringSlice 0 end path
basenameGo path end i =
  if stringSlice (i - 1) i path == "/" then
    stringSlice i end path
  else
    basenameGo path end (i - 1)

{- | Extension of the final component, dot included (`""` if none). See the
   module doc-comment for the exact dotfile convention.

   > extname "a/b/c.txt"
   ".txt"

   > extname "README"
   ""

   > extname ".bashrc"
   "" -}
export extname : String -> String
extname path =
  let b = basename path
  extnameGo b (stringLength b)

extnameGo : String -> Int -> String
extnameGo _ 0 = ""
extnameGo b i =
  if stringSlice (i - 1) i b == "." then
    if i - 1 == 0 then "" else stringSlice (i - 1) (stringLength b) b
  else
    extnameGo b (i - 1)

{- | Final component with its extension removed (the module-doc convention's
   `""` extension leaves `stem` unchanged, e.g. dotfiles).

   > stem "a/b/c.txt"
   "c"

   > stem ".bashrc"
   ".bashrc" -}
export stem : String -> String
stem path =
  let b = basename path
  let e = extname path
  if e == "" then b else stringSlice 0 (stringLength b - stringLength e) b

{- | `True` if the final component has extension `ext` (leading dot optional
   on either side — `hasExtension "txt"` and `hasExtension ".txt"` both match).

   > hasExtension "txt" "a/b.txt"
   True

   > hasExtension ".md" "a/b.txt"
   False -}
export hasExtension : String -> String -> Bool
hasExtension ext path = normalizeExt (extname path) == normalizeExt ext

normalizeExt : String -> String
normalizeExt e = if startsWith "." e || e == "" then e else "." ++ e

{- | Replace the final component's extension with `ext` (leading dot on `ext`
   is optional). If the path has no extension, `ext` is appended.

   > withExtension ".md" "a/b.txt"
   "a/b.md"

   > withExtension "md" "a/b"
   "a/b.md" -}
export withExtension : String -> String -> String
withExtension ext path =
  let base = basename path
  let e = extname path
  let newBase = (if e == "" then base else stringSlice 0 (stringLength base - stringLength e) base) ++ normalizeExt ext
  if contains "/" path then joinPath (dirname path) newBase else newBase

-- ── Joining & splitting ─────────────────────────────────────────────────────

{- | Join two path segments with a single `/`, collapsing any slashes already
   present at the boundary. An empty first (or second) segment is skipped.

   > joinPath "a/b" "c.txt"
   "a/b/c.txt"

   > joinPath "a/b/" "/c.txt"
   "a/b/c.txt"

   > joinPath "" "c.txt"
   "c.txt" -}
export joinPath : String -> String -> String
joinPath a b =
  if a == "" then
    b
  else if b == "" then
    a
  else
    "\{stripTrailingSlash a}/\{stripLeadingSlash b}"

stripTrailingSlash : String -> String
stripTrailingSlash s =
  if endsWith "/" s then
    stringSlice 0 (stringLength s - 1) s
  else
    s

stripLeadingSlash : String -> String
stripLeadingSlash s =
  if startsWith "/" s then
    stringSlice 1 (stringLength s) s
  else
    s

{- | Join every segment in order with `joinPath`; `""` for the empty list.

   > joinAll ["a", "b", "c.txt"]
   "a/b/c.txt"

   > joinAll []
   "" -}
export joinAll : List String -> String
joinAll [] = ""
joinAll (s::rest) = joinAllGo s rest

joinAllGo : String -> List String -> String
joinAllGo acc [] = acc
joinAllGo acc (s::rest) = joinAllGo (joinPath acc s) rest

{- | Split a path into its non-empty `/`-separated components (no `.`/`..`
   resolution — use `normalize` first if you want those collapsed).

   > segments "a/b/c.txt"
   ["a", "b", "c.txt"]

   > segments "/a//b/"
   ["a", "b"] -}
export segments : String -> List String
segments path = filterEmpty (split "/" path)

filterEmpty : List String -> List String
filterEmpty [] = []
filterEmpty (s::rest) =
  if s == "" then
    filterEmpty rest
  else
    s :: filterEmpty rest

-- ── Predicates ───────────────────────────────────────────────────────────

{- | `True` if the path starts with `/`.

   > isAbsolute "/a/b"
   True

   > isAbsolute "a/b"
   False -}
export isAbsolute : String -> Bool
isAbsolute path = startsWith "/" path

{- | Drop `prefix` from the front of `path` if `path` starts with it as a
   whole component boundary (i.e. right after `prefix` comes either the end
   of the string or a `/`); returns `path` unchanged otherwise.

   > stripPrefix "a/b" "a/b/c.txt"
   "c.txt"

   > stripPrefix "a/x" "a/b/c.txt"
   "a/b/c.txt" -}
export stripPrefix : String -> String -> String
stripPrefix prefix path =
  let plen = stringLength prefix
  if prefix == "" then
    path
  else if not (startsWith prefix path) then
    path
  else if stringLength path == plen then
    ""
  else if stringSlice plen (plen + 1) path == "/" then
    stringSlice (plen + 1) (stringLength path) path
  else
    path

-- ── Normalization ────────────────────────────────────────────────────────

{- | Lexically simplify a path (Go `path.Clean` semantics — see the module
   doc-comment): collapses repeated `/`, drops `.` segments, resolves `..`
   against a preceding real segment, and drops a trailing `/`. The empty path
   becomes `"."`.

   > normalize "a//b/./c/../d"
   "a/b/d"

   > normalize "../a/../../b"
   "../../b"

   > normalize "/../a"
   "/a"

   > normalize ""
   "." -}
export normalize : String -> String
normalize path =
  let abs = isAbsolute path
  let cleaned = normGo abs (segments path) []
  let body = joinAll (reverse cleaned)
  if abs then "/" ++ body else if body == "" then "." else body

-- `abs`: on an absolute path, a `..` with nothing left to cancel is above the
-- root and is simply dropped; on a relative path it has no target to cancel
-- against, so it is kept (e.g. `../../b`).
normGo : Bool -> List String -> List String -> List String
normGo _ [] acc = acc
normGo abs ("."::rest) acc = normGo abs rest acc
normGo abs (".."::rest) [] =
  if abs then
    normGo abs rest []
  else
    normGo abs rest [".."]
normGo abs (".."::rest) (top::acc2) =
  if top == ".." then
    normGo abs rest (".." :: ".."::acc2)
  else
    normGo abs rest acc2
normGo abs (s::rest) acc = normGo abs rest (s::acc)

reverse : List a -> List a
reverse xs = reverseGo xs []

reverseGo : List a -> List a -> List a
reverseGo [] acc = acc
reverseGo (x::rest) acc = reverseGo rest (x::acc)

-- ── Properties ───────────────────────────────────────────────────────────

prop "normalize is idempotent" (p : String) =
  normalize (normalize p) == normalize p

prop "joinPath then split recovers both non-empty segments" (a : String) (b : String) = if a == "" || b == "" || contains "/" a || contains "/" b then True else segments (joinPath a b) == [a, b]

prop "dirname ++ / ++ basename normalizes back to the original absolute path" (p : String) = if p == "" || not (isAbsolute p) then True else normalize (joinPath (dirname p) (basename p)) == normalize p
# DESUGAR
(DUse false (UseGroup ("string") ((mem "split" false) (mem "startsWith" false) (mem "endsWith" false) (mem "contains" false))))
(DTypeSig true "dirname" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirname" ((PVar "path")) (EApp (EApp (EVar "dirnameGo") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "dirnameGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dirnameGo" (PWild (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "dirnameGo" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "head") (ELit (LString ""))) (ELit (LString "/")) (EVar "head")))) (EApp (EApp (EVar "dirnameGo") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "basename" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "basename" ((PVar "path")) (EApp (EApp (EApp (EVar "basenameGo") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "basenameGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "basenameGo" ((PVar "path") (PVar "end") (PLit (LInt 0))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "end")) (EVar "path")))
(DFunDef false "basenameGo" ((PVar "path") (PVar "end") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EVar "end")) (EVar "path")) (EApp (EApp (EApp (EVar "basenameGo") (EVar "path")) (EVar "end")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "extname" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "extname" ((PVar "path")) (EBlock (DoLet false false (PVar "b") (EApp (EVar "basename") (EVar "path"))) (DoExpr (EApp (EApp (EVar "extnameGo") (EVar "b")) (EApp (EVar "stringLength") (EVar "b"))))))
(DTypeSig false "extnameGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "extnameGo" (PWild (PLit (LInt 0))) (ELit (LString "")))
(DFunDef false "extnameGo" ((PVar "b") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "b")) (ELit (LString "."))) (EIf (EBinOp "==" (EBinOp "-" (EVar "i") (ELit (LInt 1))) (ELit (LInt 0))) (ELit (LString "")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "b"))) (EVar "b"))) (EApp (EApp (EVar "extnameGo") (EVar "b")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "stem" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stem" ((PVar "path")) (EBlock (DoLet false false (PVar "b") (EApp (EVar "basename") (EVar "path"))) (DoLet false false (PVar "e") (EApp (EVar "extname") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "e") (ELit (LString ""))) (EVar "b") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "b")) (EApp (EVar "stringLength") (EVar "e")))) (EVar "b"))))))
(DTypeSig true "hasExtension" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasExtension" ((PVar "ext") (PVar "path")) (EBinOp "==" (EApp (EVar "normalizeExt") (EApp (EVar "extname") (EVar "path"))) (EApp (EVar "normalizeExt") (EVar "ext"))))
(DTypeSig false "normalizeExt" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "normalizeExt" ((PVar "e")) (EIf (EBinOp "||" (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "e")) (EBinOp "==" (EVar "e") (ELit (LString "")))) (EVar "e") (EBinOp "++" (ELit (LString ".")) (EVar "e"))))
(DTypeSig true "withExtension" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "withExtension" ((PVar "ext") (PVar "path")) (EBlock (DoLet false false (PVar "base") (EApp (EVar "basename") (EVar "path"))) (DoLet false false (PVar "e") (EApp (EVar "extname") (EVar "path"))) (DoLet false false (PVar "newBase") (EBinOp "++" (EIf (EBinOp "==" (EVar "e") (ELit (LString ""))) (EVar "base") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "base")) (EApp (EVar "stringLength") (EVar "e")))) (EVar "base"))) (EApp (EVar "normalizeExt") (EVar "ext")))) (DoExpr (EIf (EApp (EApp (EVar "contains") (ELit (LString "/"))) (EVar "path")) (EApp (EApp (EVar "joinPath") (EApp (EVar "dirname") (EVar "path"))) (EVar "newBase")) (EVar "newBase")))))
(DTypeSig true "joinPath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "joinPath" ((PVar "a") (PVar "b")) (EIf (EBinOp "==" (EVar "a") (ELit (LString ""))) (EVar "b") (EIf (EBinOp "==" (EVar "b") (ELit (LString ""))) (EVar "a") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "stripTrailingSlash") (EVar "a")))) (ELit (LString "/"))) (EApp (EVar "display") (EApp (EVar "stripLeadingSlash") (EVar "b")))) (ELit (LString ""))))))
(DTypeSig false "stripTrailingSlash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripTrailingSlash" ((PVar "s")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 1)))) (EVar "s")) (EVar "s")))
(DTypeSig false "stripLeadingSlash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripLeadingSlash" ((PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "s")))
(DTypeSig true "joinAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinAll" ((PList)) (ELit (LString "")))
(DFunDef false "joinAll" ((PCons (PVar "s") (PVar "rest"))) (EApp (EApp (EVar "joinAllGo") (EVar "s")) (EVar "rest")))
(DTypeSig false "joinAllGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "joinAllGo" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "joinAllGo" ((PVar "acc") (PCons (PVar "s") (PVar "rest"))) (EApp (EApp (EVar "joinAllGo") (EApp (EApp (EVar "joinPath") (EVar "acc")) (EVar "s"))) (EVar "rest")))
(DTypeSig true "segments" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "segments" ((PVar "path")) (EApp (EVar "filterEmpty") (EApp (EApp (EVar "split") (ELit (LString "/"))) (EVar "path"))))
(DTypeSig false "filterEmpty" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "filterEmpty" ((PList)) (EListLit))
(DFunDef false "filterEmpty" ((PCons (PVar "s") (PVar "rest"))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EVar "filterEmpty") (EVar "rest")) (EBinOp "::" (EVar "s") (EApp (EVar "filterEmpty") (EVar "rest")))))
(DTypeSig true "isAbsolute" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isAbsolute" ((PVar "path")) (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "path")))
(DTypeSig true "stripPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "stripPrefix" ((PVar "prefix") (PVar "path")) (EBlock (DoLet false false (PVar "plen") (EApp (EVar "stringLength") (EVar "prefix"))) (DoExpr (EIf (EBinOp "==" (EVar "prefix") (ELit (LString ""))) (EVar "path") (EIf (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "path"))) (EVar "path") (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "path")) (EVar "plen")) (ELit (LString "")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "plen")) (EBinOp "+" (EVar "plen") (ELit (LInt 1)))) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "plen") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "path"))) (EVar "path")) (EVar "path"))))))))
(DTypeSig true "normalize" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "normalize" ((PVar "path")) (EBlock (DoLet false false (PVar "abs") (EApp (EVar "isAbsolute") (EVar "path"))) (DoLet false false (PVar "cleaned") (EApp (EApp (EApp (EVar "normGo") (EVar "abs")) (EApp (EVar "segments") (EVar "path"))) (EListLit))) (DoLet false false (PVar "body") (EApp (EVar "joinAll") (EApp (EVar "reverse") (EVar "cleaned")))) (DoExpr (EIf (EVar "abs") (EBinOp "++" (ELit (LString "/")) (EVar "body")) (EIf (EBinOp "==" (EVar "body") (ELit (LString ""))) (ELit (LString ".")) (EVar "body"))))))
(DTypeSig false "normGo" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "normGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "normGo" ((PVar "abs") (PCons (PLit (LString ".")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "normGo") (EVar "abs")) (EVar "rest")) (EVar "acc")))
(DFunDef false "normGo" ((PVar "abs") (PCons (PLit (LString "..")) (PVar "rest")) (PList)) (EIf (EVar "abs") (EApp (EApp (EApp (EVar "normGo") (EVar "abs")) (EVar "rest")) (EListLit)) (EApp (EApp (EApp (EVar "normGo") (EVar "abs")) (EVar "rest")) (EListLit (ELit (LString ".."))))))
(DFunDef false "normGo" ((PVar "abs") (PCons (PLit (LString "..")) (PVar "rest")) (PCons (PVar "top") (PVar "acc2"))) (EIf (EBinOp "==" (EVar "top") (ELit (LString ".."))) (EApp (EApp (EApp (EVar "normGo") (EVar "abs")) (EVar "rest")) (EBinOp "::" (ELit (LString "..")) (EBinOp "::" (ELit (LString "..")) (EVar "acc2")))) (EApp (EApp (EApp (EVar "normGo") (EVar "abs")) (EVar "rest")) (EVar "acc2"))))
(DFunDef false "normGo" ((PVar "abs") (PCons (PVar "s") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "normGo") (EVar "abs")) (EVar "rest")) (EBinOp "::" (EVar "s") (EVar "acc"))))
(DTypeSig false "reverse" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "reverse" ((PVar "xs")) (EApp (EApp (EVar "reverseGo") (EVar "xs")) (EListLit)))
(DTypeSig false "reverseGo" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "reverseGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseGo" ((PCons (PVar "x") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "reverseGo") (EVar "rest")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DProp false "normalize is idempotent" ((pp "p" (TyCon "String"))) (EBinOp "==" (EApp (EVar "normalize") (EApp (EVar "normalize") (EVar "p"))) (EApp (EVar "normalize") (EVar "p"))))
(DProp false "joinPath then split recovers both non-empty segments" ((pp "a" (TyCon "String")) (pp "b" (TyCon "String"))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "a") (ELit (LString ""))) (EBinOp "==" (EVar "b") (ELit (LString "")))) (EApp (EApp (EVar "contains") (ELit (LString "/"))) (EVar "a"))) (EApp (EApp (EVar "contains") (ELit (LString "/"))) (EVar "b"))) (EVar "True") (EBinOp "==" (EApp (EVar "segments") (EApp (EApp (EVar "joinPath") (EVar "a")) (EVar "b"))) (EListLit (EVar "a") (EVar "b")))))
(DProp false "dirname ++ / ++ basename normalizes back to the original absolute path" ((pp "p" (TyCon "String"))) (EIf (EBinOp "||" (EBinOp "==" (EVar "p") (ELit (LString ""))) (EApp (EVar "not") (EApp (EVar "isAbsolute") (EVar "p")))) (EVar "True") (EBinOp "==" (EApp (EVar "normalize") (EApp (EApp (EVar "joinPath") (EApp (EVar "dirname") (EVar "p"))) (EApp (EVar "basename") (EVar "p")))) (EApp (EVar "normalize") (EVar "p")))))
# MARK
(DUse false (UseGroup ("string") ((mem "split" false) (mem "startsWith" false) (mem "endsWith" false) (mem "contains" false))))
(DTypeSig true "dirname" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirname" ((PVar "path")) (EApp (EApp (EVar "dirnameGo") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "dirnameGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dirnameGo" (PWild (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "dirnameGo" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "head") (ELit (LString ""))) (ELit (LString "/")) (EVar "head")))) (EApp (EApp (EVar "dirnameGo") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "basename" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "basename" ((PVar "path")) (EApp (EApp (EApp (EVar "basenameGo") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "basenameGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "basenameGo" ((PVar "path") (PVar "end") (PLit (LInt 0))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "end")) (EVar "path")))
(DFunDef false "basenameGo" ((PVar "path") (PVar "end") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EVar "end")) (EVar "path")) (EApp (EApp (EApp (EVar "basenameGo") (EVar "path")) (EVar "end")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "extname" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "extname" ((PVar "path")) (EBlock (DoLet false false (PVar "b") (EApp (EVar "basename") (EVar "path"))) (DoExpr (EApp (EApp (EVar "extnameGo") (EVar "b")) (EApp (EVar "stringLength") (EVar "b"))))))
(DTypeSig false "extnameGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "extnameGo" (PWild (PLit (LInt 0))) (ELit (LString "")))
(DFunDef false "extnameGo" ((PVar "b") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "b")) (ELit (LString "."))) (EIf (EBinOp "==" (EBinOp "-" (EVar "i") (ELit (LInt 1))) (ELit (LInt 0))) (ELit (LString "")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "b"))) (EVar "b"))) (EApp (EApp (EVar "extnameGo") (EVar "b")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "stem" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stem" ((PVar "path")) (EBlock (DoLet false false (PVar "b") (EApp (EVar "basename") (EVar "path"))) (DoLet false false (PVar "e") (EApp (EVar "extname") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "e") (ELit (LString ""))) (EVar "b") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "b")) (EApp (EVar "stringLength") (EVar "e")))) (EVar "b"))))))
(DTypeSig true "hasExtension" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasExtension" ((PVar "ext") (PVar "path")) (EBinOp "==" (EApp (EVar "normalizeExt") (EApp (EVar "extname") (EVar "path"))) (EApp (EVar "normalizeExt") (EVar "ext"))))
(DTypeSig false "normalizeExt" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "normalizeExt" ((PVar "e")) (EIf (EBinOp "||" (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "e")) (EBinOp "==" (EVar "e") (ELit (LString "")))) (EVar "e") (EBinOp "++" (ELit (LString ".")) (EVar "e"))))
(DTypeSig true "withExtension" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "withExtension" ((PVar "ext") (PVar "path")) (EBlock (DoLet false false (PVar "base") (EApp (EVar "basename") (EVar "path"))) (DoLet false false (PVar "e") (EApp (EVar "extname") (EVar "path"))) (DoLet false false (PVar "newBase") (EBinOp "++" (EIf (EBinOp "==" (EVar "e") (ELit (LString ""))) (EVar "base") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "base")) (EApp (EVar "stringLength") (EVar "e")))) (EVar "base"))) (EApp (EVar "normalizeExt") (EVar "ext")))) (DoExpr (EIf (EApp (EApp (EVar "contains") (ELit (LString "/"))) (EVar "path")) (EApp (EApp (EVar "joinPath") (EApp (EVar "dirname") (EVar "path"))) (EVar "newBase")) (EVar "newBase")))))
(DTypeSig true "joinPath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "joinPath" ((PVar "a") (PVar "b")) (EIf (EBinOp "==" (EVar "a") (ELit (LString ""))) (EVar "b") (EIf (EBinOp "==" (EVar "b") (ELit (LString ""))) (EVar "a") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "stripTrailingSlash") (EVar "a")))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EApp (EVar "stripLeadingSlash") (EVar "b")))) (ELit (LString ""))))))
(DTypeSig false "stripTrailingSlash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripTrailingSlash" ((PVar "s")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 1)))) (EVar "s")) (EVar "s")))
(DTypeSig false "stripLeadingSlash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripLeadingSlash" ((PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "s")))
(DTypeSig true "joinAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinAll" ((PList)) (ELit (LString "")))
(DFunDef false "joinAll" ((PCons (PVar "s") (PVar "rest"))) (EApp (EApp (EVar "joinAllGo") (EVar "s")) (EVar "rest")))
(DTypeSig false "joinAllGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "joinAllGo" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "joinAllGo" ((PVar "acc") (PCons (PVar "s") (PVar "rest"))) (EApp (EApp (EVar "joinAllGo") (EApp (EApp (EVar "joinPath") (EVar "acc")) (EVar "s"))) (EVar "rest")))
(DTypeSig true "segments" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "segments" ((PVar "path")) (EApp (EVar "filterEmpty") (EApp (EApp (EVar "split") (ELit (LString "/"))) (EVar "path"))))
(DTypeSig false "filterEmpty" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "filterEmpty" ((PList)) (EListLit))
(DFunDef false "filterEmpty" ((PCons (PVar "s") (PVar "rest"))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EVar "filterEmpty") (EVar "rest")) (EBinOp "::" (EVar "s") (EApp (EVar "filterEmpty") (EVar "rest")))))
(DTypeSig true "isAbsolute" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isAbsolute" ((PVar "path")) (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "path")))
(DTypeSig true "stripPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "stripPrefix" ((PVar "prefix") (PVar "path")) (EBlock (DoLet false false (PVar "plen") (EApp (EVar "stringLength") (EVar "prefix"))) (DoExpr (EIf (EBinOp "==" (EVar "prefix") (ELit (LString ""))) (EVar "path") (EIf (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "path"))) (EVar "path") (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "path")) (EVar "plen")) (ELit (LString "")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "plen")) (EBinOp "+" (EVar "plen") (ELit (LInt 1)))) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "plen") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "path"))) (EVar "path")) (EVar "path"))))))))
(DTypeSig true "normalize" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "normalize" ((PVar "path")) (EBlock (DoLet false false (PVar "abs") (EApp (EVar "isAbsolute") (EVar "path"))) (DoLet false false (PVar "cleaned") (EApp (EApp (EApp (EVar "normGo") (EMethodRef "abs")) (EApp (EVar "segments") (EVar "path"))) (EListLit))) (DoLet false false (PVar "body") (EApp (EVar "joinAll") (EApp (EVar "reverse") (EVar "cleaned")))) (DoExpr (EIf (EMethodRef "abs") (EBinOp "++" (ELit (LString "/")) (EVar "body")) (EIf (EBinOp "==" (EVar "body") (ELit (LString ""))) (ELit (LString ".")) (EVar "body"))))))
(DTypeSig false "normGo" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "normGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "normGo" ((PVar "abs") (PCons (PLit (LString ".")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "normGo") (EMethodRef "abs")) (EVar "rest")) (EVar "acc")))
(DFunDef false "normGo" ((PVar "abs") (PCons (PLit (LString "..")) (PVar "rest")) (PList)) (EIf (EMethodRef "abs") (EApp (EApp (EApp (EVar "normGo") (EMethodRef "abs")) (EVar "rest")) (EListLit)) (EApp (EApp (EApp (EVar "normGo") (EMethodRef "abs")) (EVar "rest")) (EListLit (ELit (LString ".."))))))
(DFunDef false "normGo" ((PVar "abs") (PCons (PLit (LString "..")) (PVar "rest")) (PCons (PVar "top") (PVar "acc2"))) (EIf (EBinOp "==" (EVar "top") (ELit (LString ".."))) (EApp (EApp (EApp (EVar "normGo") (EMethodRef "abs")) (EVar "rest")) (EBinOp "::" (ELit (LString "..")) (EBinOp "::" (ELit (LString "..")) (EVar "acc2")))) (EApp (EApp (EApp (EVar "normGo") (EMethodRef "abs")) (EVar "rest")) (EVar "acc2"))))
(DFunDef false "normGo" ((PVar "abs") (PCons (PVar "s") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "normGo") (EMethodRef "abs")) (EVar "rest")) (EBinOp "::" (EVar "s") (EVar "acc"))))
(DTypeSig false "reverse" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "reverse" ((PVar "xs")) (EApp (EApp (EVar "reverseGo") (EVar "xs")) (EListLit)))
(DTypeSig false "reverseGo" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "reverseGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseGo" ((PCons (PVar "x") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "reverseGo") (EVar "rest")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DProp false "normalize is idempotent" ((pp "p" (TyCon "String"))) (EBinOp "==" (EApp (EVar "normalize") (EApp (EVar "normalize") (EVar "p"))) (EApp (EVar "normalize") (EVar "p"))))
(DProp false "joinPath then split recovers both non-empty segments" ((pp "a" (TyCon "String")) (pp "b" (TyCon "String"))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "a") (ELit (LString ""))) (EBinOp "==" (EVar "b") (ELit (LString "")))) (EApp (EApp (EVar "contains") (ELit (LString "/"))) (EVar "a"))) (EApp (EApp (EVar "contains") (ELit (LString "/"))) (EVar "b"))) (EVar "True") (EBinOp "==" (EApp (EVar "segments") (EApp (EApp (EVar "joinPath") (EVar "a")) (EVar "b"))) (EListLit (EVar "a") (EVar "b")))))
(DProp false "dirname ++ / ++ basename normalizes back to the original absolute path" ((pp "p" (TyCon "String"))) (EIf (EBinOp "||" (EBinOp "==" (EVar "p") (ELit (LString ""))) (EApp (EVar "not") (EApp (EVar "isAbsolute") (EVar "p")))) (EVar "True") (EBinOp "==" (EApp (EVar "normalize") (EApp (EApp (EVar "joinPath") (EApp (EVar "dirname") (EVar "p"))) (EApp (EVar "basename") (EVar "p")))) (EApp (EVar "normalize") (EVar "p")))))
