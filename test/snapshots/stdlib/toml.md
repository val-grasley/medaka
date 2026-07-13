# META
source_lines=448
stages=DESUGAR,MARK
# SOURCE
{- toml.mdk — a minimal TOML subset sufficient to parse `medaka.toml`.

   **Supported subset** (mirrors `lib/project_config.ml`):
   - Top-level `[section]` headers (not nested tables or inline tables)
   - `key = "string"` values (double-quoted; backslash is passed through as-is)
   - `key = ["array", "of", "strings"]` values
   - `#` line comments (stripped before parsing, respecting quoted strings)
   - Blank lines ignored

   **Not supported** (not needed by `medaka.toml`):
   - Integer, float, bool, datetime values
   - Multiline strings (`"""…"""` / `'''…'''`)
   - Inline tables (`{k = v}`)
   - Dotted keys (`a.b = v`) — use table headers instead
   - Array of tables (`[[t]]`)
   - String escape sequences (backslash is literal)

   **Value model.**
   ```
   data TomlValue = TStr String | TArr (List String)
   ```
   The parsed document is a flat association list of `(qualifiedKey, value)` pairs.
   Keys under `[package]` are stored bare (e.g. `"name"`); keys under any other
   section `[s]` are stored as `"s.key"` (e.g. `"workspace.members"`).
   This exactly mirrors the qualification logic in `lib/project_config.ml`. -}

import string.{trim, lines}

-- ── Value type ──────────────────────────────────────────────────────────────

public export data TomlValue = TStr String | TArr (List String)

-- | A parsed TOML document: a flat list of (qualifiedKey, value) pairs.
public export data Toml = Toml (List (String, TomlValue))

-- ── Helpers ──────────────────────────────────────────────────────────────────

listReverse : List a -> List a
listReverse = listRevGo []

listRevGo : List a -> List a -> List a
listRevGo acc [] = acc
listRevGo acc (x::xs) = listRevGo (x::acc) xs

-- ── Comment stripping ────────────────────────────────────────────────────────

-- Strip a `#` comment from a line, respecting double-quoted strings so
-- `entry = "foo#bar"` is preserved.
stripComment : String -> String
stripComment s =
  let arr = stringToChars s
  let n = arrayLength arr
  stripCommentGo arr 0 n False []

stripCommentGo : Array Char -> Int -> Int -> Bool -> List Char -> String
stripCommentGo arr i n inStr acc
  | i >= n = stringFromChars (arrayFromList (listReverse acc))
  | otherwise = stripCommentStep arr i n inStr acc (arrayGetUnsafe i arr)

stripCommentStep : Array Char -> Int -> Int -> Bool -> List Char -> Char -> String
stripCommentStep arr i n inStr acc c
  | charCode c == 34 = stripCommentGo arr (i + 1) n (not inStr) (c::acc)
  | charCode c == 35 && not inStr =
    stringFromChars (arrayFromList (listReverse acc))
  | otherwise = stripCommentGo arr (i + 1) n inStr (c::acc)

-- ── String value parser ──────────────────────────────────────────────────────

-- Parse a double-quoted string from an Array Char starting at position i.
-- Returns Ok (value, nextIndex) or Err message.
parseQuotedStr : Array Char -> Int -> Result String (String, Int)
parseQuotedStr arr i
  | i >= arrayLength arr = Err "unexpected end of input"
  | arrayGetUnsafe i arr == '"' = parseQuotedBody arr (i + 1) []
  | otherwise = Err "expected '\"'"

parseQuotedBody : Array Char -> Int -> List Char -> Result String (String, Int)
parseQuotedBody arr i acc
  | i >= arrayLength arr = Err "unterminated string"
  | arrayGetUnsafe i arr == '"' =
    Ok (stringFromChars (arrayFromList (listReverse acc)), i + 1)
  | otherwise = parseQuotedBody arr (i + 1) (arrayGetUnsafe i arr :: acc)

-- ── Array value parser ───────────────────────────────────────────────────────

-- Parse a `["str1", "str2"]` array starting at position `i` (must point at `[`).
parseArrayValue : Array Char -> Int -> Result String (List String, Int)
parseArrayValue arr i
  | i >= arrayLength arr = Err "unexpected end of input"
  | arrayGetUnsafe i arr == '[' = parseArrayItems arr (i + 1) []
  | otherwise = Err "expected '['"

-- Skip spaces/commas and parse string items until `]`.
parseArrayItems : Array Char -> Int -> List String -> Result String (List String, Int)
parseArrayItems arr i acc
  | i >= arrayLength arr = Err "unterminated array"
  | arrayGetUnsafe i arr == ']' = Ok (listReverse acc, i + 1)
  | arrayGetUnsafe i arr == ' ' = parseArrayItems arr (i + 1) acc
  | arrayGetUnsafe i arr == '\t' = parseArrayItems arr (i + 1) acc
  | arrayGetUnsafe i arr == ',' = parseArrayItems arr (i + 1) acc
  | arrayGetUnsafe i arr == '"' = parseArrayItemStr arr i acc
  | otherwise = Err (stringConcat ["unexpected char in array: '", charToStr (arrayGetUnsafe i arr), "'"])

parseArrayItemStr : Array Char -> Int -> List String -> Result String (List String, Int)
parseArrayItemStr arr i acc = match parseQuotedStr arr i
  Err e => Err e
  Ok (s, j) => parseArrayItems arr j (s::acc)

-- ── Key-value line parser ────────────────────────────────────────────────────

skipSpaces : Array Char -> Int -> Int -> Int
skipSpaces arr i n
  | i >= n = n
  | arrayGetUnsafe i arr == ' ' = skipSpaces arr (i + 1) n
  | arrayGetUnsafe i arr == '\t' = skipSpaces arr (i + 1) n
  | otherwise = i

-- Parse `key = value` where value is a quoted string or array.
parseKv : String -> Result String (String, TomlValue)
parseKv line =
  let arr = stringToChars line
  let n = arrayLength arr
  findEq arr n 0

findEq : Array Char -> Int -> Int -> Result String (String, TomlValue)
findEq arr n i
  | i >= n = Err (stringConcat ["expected '=' in: ", stringFromChars arr])
  | arrayGetUnsafe i arr == '=' = parseKvAfterEq arr n i
  | otherwise = findEq arr n (i + 1)

parseKvAfterEq : Array Char -> Int -> Int -> Result String (String, TomlValue)
parseKvAfterEq arr n eq =
  let keyRaw = stringFromChars (arrayMakeWith eq (k => arrayGetUnsafe k arr))
  let key = trim keyRaw
  let valStart = skipSpaces arr (eq + 1) n
  parseKvValue arr n valStart key

parseKvValue : Array Char -> Int -> Int -> String -> Result String (String, TomlValue)
parseKvValue arr n i key
  | i >= n = Err (stringConcat ["missing value for key: ", key])
  | arrayGetUnsafe i arr == '"' = parseKvStr arr i key
  | arrayGetUnsafe i arr == '[' = parseKvArr arr i key
  | otherwise = Err (stringConcat ["expected '\"' or '[' for key: ", key])

parseKvStr : Array Char -> Int -> String -> Result String (String, TomlValue)
parseKvStr arr i key = map ((s, _) => (key, TStr s)) (parseQuotedStr arr i)

parseKvArr : Array Char -> Int -> String -> Result String (String, TomlValue)
parseKvArr arr i key = map ((xs, _) => (key, TArr xs)) (parseArrayValue arr i)

-- ── Document parser ──────────────────────────────────────────────────────────

-- Detect a section header `[name]` and extract the name, or return None.
parseHeader : String -> Option String
parseHeader s =
  let n = stringLength s
  if n >= 2 && stringSlice 0 1 s == "[" && stringSlice (n - 1) n s == "]" then
    Some (trim (stringSlice 1 (n - 1) s))
  else
    None

-- Qualify a key relative to the current section.
-- Keys in [package] stay bare; keys in any other section get "section." prefix.
qualifyKey : String -> String -> String
qualifyKey section key
  | section == "" = key
  | section == "package" = key
  | otherwise = stringConcat [section, ".", key]

parseLinesAcc : List String -> String -> List (String, TomlValue) -> Result String (List (String, TomlValue))
parseLinesAcc [] _ acc = Ok (listReverse acc)
parseLinesAcc (l::ls) section acc =
  let trimmed = trim (stripComment l)
  if trimmed == "" then parseLinesAcc ls section acc
  else match parseHeader trimmed
    Some hdr => parseLinesAcc ls hdr acc
    None => match parseKv trimmed
      Err e => Err e
      Ok (k, v) => parseLinesAcc ls section ((qualifyKey section k, v)::acc)

{- | Parse a TOML string (supported subset) into a `Toml` document, or an
   error message describing the first parse failure.

   A `[package]` section:

   > parse "[package]\nname = \"hello\"\nversion = \"0.1.0\"\nentry = \"main.mdk\"" == Ok (Toml [("name", TStr "hello"), ("version", TStr "0.1.0"), ("entry", TStr "main.mdk")])
   True

   A `[workspace]` section with a string array:

   > parse "[workspace]\nmembers = [\"pkg-a\", \"pkg-b\"]" == Ok (Toml [("workspace.members", TArr ["pkg-a", "pkg-b"])])
   True

   Comments and blank lines are ignored:

   > parse "# just a comment\n\nname = \"x\"" == Ok (Toml [("name", TStr "x")])
   True

   Inline `#` after a value is stripped:

   > parse "name = \"hello\" # a comment" == Ok (Toml [("name", TStr "hello")])
   True -}
export parse : String -> Result String Toml
parse s = map Toml (parseLinesAcc (lines s) "" [])

-- Parse-error cases: a line with no `=` and a missing value both produce Err.

{- > parse "bad line no equals"
   Err "expected '=' in: bad line no equals"

   > parse "[package]\nname = unterminated"
   Err "expected '\"' or '[' for key: name" -}

-- ── Accessors ────────────────────────────────────────────────────────────────

lookupKvs : String -> List (String, TomlValue) -> Option TomlValue
lookupKvs _ [] = None
lookupKvs key ((k, v)::rest)
  | k == key = Some v
  | otherwise = lookupKvs key rest

-- Private helpers: parse a TOML string and look up one field (used in doctests).
parseGetStr : String -> String -> Option String
parseGetStr field src = match parse src
  Err _ => None
  Ok doc => getString field doc

parseGetArr : String -> String -> Option (List String)
parseGetArr field src = match parse src
  Err _ => None
  Ok doc => getArray field doc

-- Private helpers: parse a TOML string and apply one exported convenience
-- accessor, so the accessors themselves are exercised by doctests/props.
parsePackageName : String -> Option String
parsePackageName src = match parse src
  Err _ => None
  Ok doc => packageName doc

parsePackageVersion : String -> Option String
parsePackageVersion src = match parse src
  Err _ => None
  Ok doc => packageVersion doc

parsePackageEntry : String -> Option String
parsePackageEntry src = match parse src
  Err _ => None
  Ok doc => packageEntry doc

parseWorkspaceMembers : String -> Option (List String)
parseWorkspaceMembers src = match parse src
  Err _ => None
  Ok doc => workspaceMembers doc

{- | Look up a string value by (qualified) key.  Returns `None` if the key is
   absent or holds an array.

   > parseGetStr "name" "[package]\nname = \"medaka\"\nversion = \"1.0.0\"\nentry = \"main.mdk\""
   Some "medaka"

   Returns `None` for an array-valued key:

   > parseGetStr "workspace.members" "[workspace]\nmembers = [\"a\"]"
   None

   Returns `None` for an absent key:

   > parseGetStr "missing" "[package]\nname = \"x\""
   None

   Returns `None` when the table itself is absent:

   > parseGetStr "server.host" "[package]\nname = \"x\""
   None -}
export getString : String -> Toml -> Option String
getString key (Toml kvs) = match lookupKvs key kvs
  None => None
  Some (TStr s) => Some s
  Some (TArr _) => None

{- | Look up an array-of-strings value by (qualified) key.  Returns `None` if
   the key is absent or holds a string.

   > parseGetArr "workspace.members" "[workspace]\nmembers = [\"pkg-a\", \"pkg-b\"]"
   Some ["pkg-a", "pkg-b"]

   Returns `None` for a string-valued key:

   > parseGetArr "name" "[package]\nname = \"x\"\nversion = \"0.1.0\"\nentry = \"main.mdk\""
   None

   Returns `None` for an absent key:

   > parseGetArr "workspace.members" "[package]\nname = \"x\""
   None

   An empty array yields `Some []`:

   > parseGetArr "workspace.members" "[workspace]\nmembers = []"
   Some [] -}
export getArray : String -> Toml -> Option (List String)
getArray key (Toml kvs) = match lookupKvs key kvs
  None => None
  Some (TArr xs) => Some xs
  Some (TStr _) => None

-- ── Convenience accessors for `medaka.toml` fields ──────────────────────────

{- | Extract `name` from a parsed `[package]` section.

   > parsePackageName "[package]\nname = \"my-project\"\nversion = \"0.1.0\"\nentry = \"main.mdk\""
   Some "my-project"

   `None` when `name` is absent:

   > parsePackageName "[package]\nversion = \"0.1.0\""
   None -}
export packageName : Toml -> Option String
packageName doc = getString "name" doc

{- | Extract `version` from a parsed `[package]` section.

   > parsePackageVersion "[package]\nname = \"x\"\nversion = \"2.3.4\"\nentry = \"main.mdk\""
   Some "2.3.4"

   `None` when `version` is absent:

   > parsePackageVersion "[package]\nname = \"x\""
   None -}
export packageVersion : Toml -> Option String
packageVersion doc = getString "version" doc

{- | Extract `entry` from a parsed `[package]` section.

   > parsePackageEntry "[package]\nname = \"x\"\nversion = \"0.1.0\"\nentry = \"src/main.mdk\""
   Some "src/main.mdk"

   `None` when `entry` is absent:

   > parsePackageEntry "[package]\nname = \"x\""
   None -}
export packageEntry : Toml -> Option String
packageEntry doc = getString "entry" doc

{- | Extract `members` from a parsed `[workspace]` section.

   > parseWorkspaceMembers "[workspace]\nmembers = [\"pkgs/core\", \"pkgs/net\"]"
   Some ["pkgs/core", "pkgs/net"]

   `None` when there is no `[workspace]` section:

   > parseWorkspaceMembers "[package]\nname = \"x\""
   None -}
export workspaceMembers : Toml -> Option (List String)
workspaceMembers doc = getArray "workspace.members" doc

-- ── Eq and Debug instances ──────────────────────────────────────────────────

{- | Structural equality on `TomlValue`.

   > eqTomlValue (TStr "a") (TStr "a")
   True

   > eqTomlValue (TArr ["a", "b"]) (TArr ["a", "b"])
   True

   Different constructors never compare equal:

   > eqTomlValue (TStr "a") (TArr ["a"])
   False -}
eqTomlValue : TomlValue -> TomlValue -> Bool
eqTomlValue (TStr a) (TStr b) = a == b
eqTomlValue (TArr a) (TArr b) = eqStrLists a b
eqTomlValue _ _ = False

eqStrLists : List String -> List String -> Bool
eqStrLists [] [] = True
eqStrLists (x::xs) (y::ys) = x == y && eqStrLists xs ys
eqStrLists _ _ = False

eqKvList : List (String, TomlValue) -> List (String, TomlValue) -> Bool
eqKvList [] [] = True
eqKvList ((k1, v1)::rest1) ((k2, v2)::rest2) = k1 == k2
  && eqTomlValue v1 v2
  && eqKvList rest1 rest2
eqKvList _ _ = False

export impl Eq TomlValue where
  eq = eqTomlValue

export impl Eq Toml where
  eq (Toml a) (Toml b) = eqKvList a b

{- | Render a `TomlValue` for debugging.

   > debugTomlValue (TStr "hi")
   "TStr \"hi\""

   > debugTomlValue (TArr ["a", "b"])
   "TArr [\"a\", \"b\"]" -}
debugTomlValue : TomlValue -> String
debugTomlValue (TStr s) = stringConcat ["TStr ", debug s]
debugTomlValue (TArr xs) = stringConcat ["TArr ", debugStrList xs]

debugStrList : List String -> String
debugStrList xs = stringConcat ["[", joinDebugStrs xs, "]"]

joinDebugStrs : List String -> String
joinDebugStrs [] = ""
joinDebugStrs (x::[]) = debug x
joinDebugStrs (x::xs) = stringConcat [debug x, ", ", joinDebugStrs xs]

debugKvPair : (String, TomlValue) -> String
debugKvPair (k, v) = stringConcat ["(", debug k, ", ", debugTomlValue v, ")"]

debugKvList : List (String, TomlValue) -> String
debugKvList [] = ""
debugKvList (p::[]) = debugKvPair p
debugKvList (p::ps) = stringConcat [debugKvPair p, ", ", debugKvList ps]

export impl Debug TomlValue where
  debug = debugTomlValue

export impl Debug Toml where
  debug (Toml kvs) = stringConcat ["Toml [", debugKvList kvs, "]"]

-- ── Property tests ───────────────────────────────────────────────────────────

-- Build a `[package]` document whose `version` is the given (safely-quotable)
-- string.  Used by the round-trip properties below.
mkPackage : String -> String
mkPackage v = stringConcat ["[package]\nname = \"demo\"\nversion = \"", v, "\""]

-- `intToString n` only ever yields characters in `[-0-9]`, none of which are
-- TOML-significant, so embedding it in a quoted value is safe.

prop "packageVersion round-trips an Int-derived version" (n : Int) =
  parsePackageVersion (mkPackage (intToString n)) == Some (intToString n)

prop "packageName is stable regardless of the version value" (n : Int) =
  parsePackageName (mkPackage (intToString n)) == Some "demo"

prop "packageVersion agrees with getString version" (n : Int) =
  parsePackageVersion (mkPackage (intToString n)) ==
    parseGetStr "version" (mkPackage (intToString n))

prop "parse is deterministic" (n : Int) =
  parse (mkPackage (intToString n)) == parse (mkPackage (intToString n))
# DESUGAR
(DUse false (UseGroup ("string") ((mem "trim" false) (mem "lines" false))))
(DData Public "TomlValue" () ((variant "TStr" (ConPos (TyCon "String"))) (variant "TArr" (ConPos (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Public "Toml" () ((variant "Toml" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue")))))) ())
(DTypeSig false "listReverse" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "listReverse" () (EApp (EVar "listRevGo") (EListLit)))
(DTypeSig false "listRevGo" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "listRevGo" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "listRevGo" ((PVar "acc") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "listRevGo") (EBinOp "::" (EVar "x") (EVar "acc"))) (EVar "xs")))
(DTypeSig false "stripComment" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripComment" ((PVar "s")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (ELit (LInt 0))) (EVar "n")) (EVar "False")) (EListLit)))))
(DTypeSig false "stripCommentGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyCon "String")))))))
(DFunDef false "stripCommentGo" ((PVar "arr") (PVar "i") (PVar "n") (PVar "inStr") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "listReverse") (EVar "acc")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentStep") (EVar "arr")) (EVar "i")) (EVar "n")) (EVar "inStr")) (EVar "acc")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "stripCommentStep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Char") (TyCon "String"))))))))
(DFunDef false "stripCommentStep" ((PVar "arr") (PVar "i") (PVar "n") (PVar "inStr") (PVar "acc") (PVar "c")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 34))) (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "not") (EVar "inStr"))) (EBinOp "::" (EVar "c") (EVar "acc"))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 35))) (EApp (EVar "not") (EVar "inStr"))) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "listReverse") (EVar "acc")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "inStr")) (EBinOp "::" (EVar "c") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseQuotedStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "parseQuotedStr" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unexpected end of input"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseQuotedBody") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EListLit)) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected '\"'"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseQuotedBody" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "parseQuotedBody" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated string"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EVar "Ok") (ETuple (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "listReverse") (EVar "acc")))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "parseQuotedBody") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseArrayValue" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "parseArrayValue" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unexpected end of input"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "["))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EListLit)) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected '['"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseArrayItems" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "parseArrayItems" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated array"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "]"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "listReverse") (EVar "acc")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\t"))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar ","))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseArrayItemStr") (EVar "arr")) (EVar "i")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "unexpected char in array: '")) (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (ELit (LString "'"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "parseArrayItemStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "parseArrayItemStr" ((PVar "arr") (PVar "i") (PVar "acc")) (EMatch (EApp (EApp (EVar "parseQuotedStr") (EVar "arr")) (EVar "i")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "s") (PVar "j"))) () (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EVar "j")) (EBinOp "::" (EVar "s") (EVar "acc"))))))
(DTypeSig false "skipSpaces" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipSpaces" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\t"))) (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseKv" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))
(DFunDef false "parseKv" ((PVar "line")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "line"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "findEq") (EVar "arr")) (EVar "n")) (ELit (LInt 0))))))
(DTypeSig false "findEq" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "findEq" ((PVar "arr") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "expected '=' in: ")) (EApp (EVar "stringFromChars") (EVar "arr"))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "="))) (EApp (EApp (EApp (EVar "parseKvAfterEq") (EVar "arr")) (EVar "n")) (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "findEq") (EVar "arr")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseKvAfterEq" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvAfterEq" ((PVar "arr") (PVar "n") (PVar "eq")) (EBlock (DoLet false false (PVar "keyRaw") (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EVar "eq")) (ELam ((PVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr")))))) (DoLet false false (PVar "key") (EApp (EVar "trim") (EVar "keyRaw"))) (DoLet false false (PVar "valStart") (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EVar "eq") (ELit (LInt 1)))) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "parseKvValue") (EVar "arr")) (EVar "n")) (EVar "valStart")) (EVar "key")))))
(DTypeSig false "parseKvValue" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue"))))))))
(DFunDef false "parseKvValue" ((PVar "arr") (PVar "n") (PVar "i") (PVar "key")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "missing value for key: ")) (EVar "key")))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseKvStr") (EVar "arr")) (EVar "i")) (EVar "key")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "["))) (EApp (EApp (EApp (EVar "parseKvArr") (EVar "arr")) (EVar "i")) (EVar "key")) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "expected '\"' or '[' for key: ")) (EVar "key")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseKvStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvStr" ((PVar "arr") (PVar "i") (PVar "key")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "s") PWild)) (ETuple (EVar "key") (EApp (EVar "TStr") (EVar "s"))))) (EApp (EApp (EVar "parseQuotedStr") (EVar "arr")) (EVar "i"))))
(DTypeSig false "parseKvArr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvArr" ((PVar "arr") (PVar "i") (PVar "key")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "xs") PWild)) (ETuple (EVar "key") (EApp (EVar "TArr") (EVar "xs"))))) (EApp (EApp (EVar "parseArrayValue") (EVar "arr")) (EVar "i"))))
(DTypeSig false "parseHeader" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "parseHeader" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "[")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "]")))) (EApp (EVar "Some") (EApp (EVar "trim") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s")))) (EVar "None")))))
(DTypeSig false "qualifyKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "qualifyKey" ((PVar "section") (PVar "key")) (EIf (EBinOp "==" (EVar "section") (ELit (LString ""))) (EVar "key") (EIf (EBinOp "==" (EVar "section") (ELit (LString "package"))) (EVar "key") (EIf (EVar "otherwise") (EApp (EVar "stringConcat") (EListLit (EVar "section") (ELit (LString ".")) (EVar "key"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseLinesAcc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))))))))
(DFunDef false "parseLinesAcc" ((PList) PWild (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "listReverse") (EVar "acc"))))
(DFunDef false "parseLinesAcc" ((PCons (PVar "l") (PVar "ls")) (PVar "section") (PVar "acc")) (EBlock (DoLet false false (PVar "trimmed") (EApp (EVar "trim") (EApp (EVar "stripComment") (EVar "l")))) (DoExpr (EIf (EBinOp "==" (EVar "trimmed") (ELit (LString ""))) (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "section")) (EVar "acc")) (EMatch (EApp (EVar "parseHeader") (EVar "trimmed")) (arm (PCon "Some" (PVar "hdr")) () (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "hdr")) (EVar "acc"))) (arm (PCon "None") () (EMatch (EApp (EVar "parseKv") (EVar "trimmed")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "k") (PVar "v"))) () (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "section")) (EBinOp "::" (ETuple (EApp (EApp (EVar "qualifyKey") (EVar "section")) (EVar "k")) (EVar "v")) (EVar "acc")))))))))))
(DTypeSig true "parse" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Toml"))))
(DFunDef false "parse" ((PVar "s")) (EApp (EApp (EVar "map") (EVar "Toml")) (EApp (EApp (EApp (EVar "parseLinesAcc") (EApp (EVar "lines") (EVar "s"))) (ELit (LString ""))) (EListLit))))
(DTypeSig false "lookupKvs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyApp (TyCon "Option") (TyCon "TomlValue")))))
(DFunDef false "lookupKvs" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupKvs" ((PVar "key") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "key")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseGetStr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "parseGetStr" ((PVar "field") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EVar "getString") (EVar "field")) (EVar "doc")))))
(DTypeSig false "parseGetArr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "parseGetArr" ((PVar "field") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EVar "getArray") (EVar "field")) (EVar "doc")))))
(DTypeSig false "parsePackageName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "parsePackageName" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EVar "packageName") (EVar "doc")))))
(DTypeSig false "parsePackageVersion" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "parsePackageVersion" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EVar "packageVersion") (EVar "doc")))))
(DTypeSig false "parsePackageEntry" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "parsePackageEntry" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EVar "packageEntry") (EVar "doc")))))
(DTypeSig false "parseWorkspaceMembers" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "parseWorkspaceMembers" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EVar "workspaceMembers") (EVar "doc")))))
(DTypeSig true "getString" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "getString" ((PVar "key") (PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "kvs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PCon "TStr" (PVar "s"))) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "Some" (PCon "TArr" PWild)) () (EVar "None"))))
(DTypeSig true "getArray" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "getArray" ((PVar "key") (PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "kvs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PCon "TArr" (PVar "xs"))) () (EApp (EVar "Some") (EVar "xs"))) (arm (PCon "Some" (PCon "TStr" PWild)) () (EVar "None"))))
(DTypeSig true "packageName" (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "packageName" ((PVar "doc")) (EApp (EApp (EVar "getString") (ELit (LString "name"))) (EVar "doc")))
(DTypeSig true "packageVersion" (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "packageVersion" ((PVar "doc")) (EApp (EApp (EVar "getString") (ELit (LString "version"))) (EVar "doc")))
(DTypeSig true "packageEntry" (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "packageEntry" ((PVar "doc")) (EApp (EApp (EVar "getString") (ELit (LString "entry"))) (EVar "doc")))
(DTypeSig true "workspaceMembers" (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "workspaceMembers" ((PVar "doc")) (EApp (EApp (EVar "getArray") (ELit (LString "workspace.members"))) (EVar "doc")))
(DTypeSig false "eqTomlValue" (TyFun (TyCon "TomlValue") (TyFun (TyCon "TomlValue") (TyCon "Bool"))))
(DFunDef false "eqTomlValue" ((PCon "TStr" (PVar "a")) (PCon "TStr" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "eqTomlValue" ((PCon "TArr" (PVar "a")) (PCon "TArr" (PVar "b"))) (EApp (EApp (EVar "eqStrLists") (EVar "a")) (EVar "b")))
(DFunDef false "eqTomlValue" (PWild PWild) (EVar "False"))
(DTypeSig false "eqStrLists" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "eqStrLists" ((PList) (PList)) (EVar "True"))
(DFunDef false "eqStrLists" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "&&" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "eqStrLists") (EVar "xs")) (EVar "ys"))))
(DFunDef false "eqStrLists" (PWild PWild) (EVar "False"))
(DTypeSig false "eqKvList" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyCon "Bool"))))
(DFunDef false "eqKvList" ((PList) (PList)) (EVar "True"))
(DFunDef false "eqKvList" ((PCons (PTuple (PVar "k1") (PVar "v1")) (PVar "rest1")) (PCons (PTuple (PVar "k2") (PVar "v2")) (PVar "rest2"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "k1") (EVar "k2")) (EApp (EApp (EVar "eqTomlValue") (EVar "v1")) (EVar "v2"))) (EApp (EApp (EVar "eqKvList") (EVar "rest1")) (EVar "rest2"))))
(DFunDef false "eqKvList" (PWild PWild) (EVar "False"))
(DImpl true "Eq" ((TyCon "TomlValue")) () ((im "eq" () (EVar "eqTomlValue"))))
(DImpl true "Eq" ((TyCon "Toml")) () ((im "eq" ((PCon "Toml" (PVar "a")) (PCon "Toml" (PVar "b"))) (EApp (EApp (EVar "eqKvList") (EVar "a")) (EVar "b")))))
(DTypeSig false "debugTomlValue" (TyFun (TyCon "TomlValue") (TyCon "String")))
(DFunDef false "debugTomlValue" ((PCon "TStr" (PVar "s"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "TStr ")) (EApp (EVar "debug") (EVar "s")))))
(DFunDef false "debugTomlValue" ((PCon "TArr" (PVar "xs"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "TArr ")) (EApp (EVar "debugStrList") (EVar "xs")))))
(DTypeSig false "debugStrList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "debugStrList" ((PVar "xs")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "[")) (EApp (EVar "joinDebugStrs") (EVar "xs")) (ELit (LString "]")))))
(DTypeSig false "joinDebugStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinDebugStrs" ((PList)) (ELit (LString "")))
(DFunDef false "joinDebugStrs" ((PCons (PVar "x") (PList))) (EApp (EVar "debug") (EVar "x")))
(DFunDef false "joinDebugStrs" ((PCons (PVar "x") (PVar "xs"))) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "debug") (EVar "x")) (ELit (LString ", ")) (EApp (EVar "joinDebugStrs") (EVar "xs")))))
(DTypeSig false "debugKvPair" (TyFun (TyTuple (TyCon "String") (TyCon "TomlValue")) (TyCon "String")))
(DFunDef false "debugKvPair" ((PTuple (PVar "k") (PVar "v"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "(")) (EApp (EVar "debug") (EVar "k")) (ELit (LString ", ")) (EApp (EVar "debugTomlValue") (EVar "v")) (ELit (LString ")")))))
(DTypeSig false "debugKvList" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyCon "String")))
(DFunDef false "debugKvList" ((PList)) (ELit (LString "")))
(DFunDef false "debugKvList" ((PCons (PVar "p") (PList))) (EApp (EVar "debugKvPair") (EVar "p")))
(DFunDef false "debugKvList" ((PCons (PVar "p") (PVar "ps"))) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "debugKvPair") (EVar "p")) (ELit (LString ", ")) (EApp (EVar "debugKvList") (EVar "ps")))))
(DImpl true "Debug" ((TyCon "TomlValue")) () ((im "debug" () (EVar "debugTomlValue"))))
(DImpl true "Debug" ((TyCon "Toml")) () ((im "debug" ((PCon "Toml" (PVar "kvs"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Toml [")) (EApp (EVar "debugKvList") (EVar "kvs")) (ELit (LString "]")))))))
(DTypeSig false "mkPackage" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "mkPackage" ((PVar "v")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "[package]\nname = \"demo\"\nversion = \"")) (EVar "v") (ELit (LString "\"")))))
(DProp false "packageVersion round-trips an Int-derived version" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parsePackageVersion") (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "Some") (EApp (EVar "intToString") (EVar "n")))))
(DProp false "packageName is stable regardless of the version value" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parsePackageName") (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "Some") (ELit (LString "demo")))))
(DProp false "packageVersion agrees with getString version" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parsePackageVersion") (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n")))) (EApp (EApp (EVar "parseGetStr") (ELit (LString "version"))) (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n"))))))
(DProp false "parse is deterministic" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parse") (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "parse") (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n"))))))
# MARK
(DUse false (UseGroup ("string") ((mem "trim" false) (mem "lines" false))))
(DData Public "TomlValue" () ((variant "TStr" (ConPos (TyCon "String"))) (variant "TArr" (ConPos (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Public "Toml" () ((variant "Toml" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue")))))) ())
(DTypeSig false "listReverse" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "listReverse" () (EApp (EVar "listRevGo") (EListLit)))
(DTypeSig false "listRevGo" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "listRevGo" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "listRevGo" ((PVar "acc") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "listRevGo") (EBinOp "::" (EVar "x") (EVar "acc"))) (EVar "xs")))
(DTypeSig false "stripComment" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripComment" ((PVar "s")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (ELit (LInt 0))) (EVar "n")) (EVar "False")) (EListLit)))))
(DTypeSig false "stripCommentGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyCon "String")))))))
(DFunDef false "stripCommentGo" ((PVar "arr") (PVar "i") (PVar "n") (PVar "inStr") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "listReverse") (EVar "acc")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentStep") (EVar "arr")) (EVar "i")) (EVar "n")) (EVar "inStr")) (EVar "acc")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "stripCommentStep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Char") (TyCon "String"))))))))
(DFunDef false "stripCommentStep" ((PVar "arr") (PVar "i") (PVar "n") (PVar "inStr") (PVar "acc") (PVar "c")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 34))) (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "not") (EVar "inStr"))) (EBinOp "::" (EVar "c") (EVar "acc"))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 35))) (EApp (EVar "not") (EVar "inStr"))) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "listReverse") (EVar "acc")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "inStr")) (EBinOp "::" (EVar "c") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseQuotedStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "parseQuotedStr" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unexpected end of input"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseQuotedBody") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EListLit)) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected '\"'"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseQuotedBody" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "parseQuotedBody" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated string"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EVar "Ok") (ETuple (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "listReverse") (EVar "acc")))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "parseQuotedBody") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseArrayValue" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "parseArrayValue" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unexpected end of input"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "["))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EListLit)) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected '['"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseArrayItems" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "parseArrayItems" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated array"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "]"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "listReverse") (EVar "acc")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\t"))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar ","))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseArrayItemStr") (EVar "arr")) (EVar "i")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "unexpected char in array: '")) (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (ELit (LString "'"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "parseArrayItemStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "parseArrayItemStr" ((PVar "arr") (PVar "i") (PVar "acc")) (EMatch (EApp (EApp (EVar "parseQuotedStr") (EVar "arr")) (EVar "i")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "s") (PVar "j"))) () (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EVar "j")) (EBinOp "::" (EVar "s") (EVar "acc"))))))
(DTypeSig false "skipSpaces" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipSpaces" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\t"))) (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseKv" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))
(DFunDef false "parseKv" ((PVar "line")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "line"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "findEq") (EVar "arr")) (EVar "n")) (ELit (LInt 0))))))
(DTypeSig false "findEq" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "findEq" ((PVar "arr") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "expected '=' in: ")) (EApp (EVar "stringFromChars") (EVar "arr"))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "="))) (EApp (EApp (EApp (EVar "parseKvAfterEq") (EVar "arr")) (EVar "n")) (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "findEq") (EVar "arr")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseKvAfterEq" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvAfterEq" ((PVar "arr") (PVar "n") (PVar "eq")) (EBlock (DoLet false false (PVar "keyRaw") (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EMethodRef "eq")) (ELam ((PVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr")))))) (DoLet false false (PVar "key") (EApp (EVar "trim") (EVar "keyRaw"))) (DoLet false false (PVar "valStart") (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EMethodRef "eq") (ELit (LInt 1)))) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "parseKvValue") (EVar "arr")) (EVar "n")) (EVar "valStart")) (EVar "key")))))
(DTypeSig false "parseKvValue" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue"))))))))
(DFunDef false "parseKvValue" ((PVar "arr") (PVar "n") (PVar "i") (PVar "key")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "missing value for key: ")) (EVar "key")))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseKvStr") (EVar "arr")) (EVar "i")) (EVar "key")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "["))) (EApp (EApp (EApp (EVar "parseKvArr") (EVar "arr")) (EVar "i")) (EVar "key")) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "expected '\"' or '[' for key: ")) (EVar "key")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseKvStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvStr" ((PVar "arr") (PVar "i") (PVar "key")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "s") PWild)) (ETuple (EVar "key") (EApp (EVar "TStr") (EVar "s"))))) (EApp (EApp (EVar "parseQuotedStr") (EVar "arr")) (EVar "i"))))
(DTypeSig false "parseKvArr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvArr" ((PVar "arr") (PVar "i") (PVar "key")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "xs") PWild)) (ETuple (EVar "key") (EApp (EVar "TArr") (EVar "xs"))))) (EApp (EApp (EVar "parseArrayValue") (EVar "arr")) (EVar "i"))))
(DTypeSig false "parseHeader" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "parseHeader" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "[")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "]")))) (EApp (EVar "Some") (EApp (EVar "trim") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s")))) (EVar "None")))))
(DTypeSig false "qualifyKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "qualifyKey" ((PVar "section") (PVar "key")) (EIf (EBinOp "==" (EVar "section") (ELit (LString ""))) (EVar "key") (EIf (EBinOp "==" (EVar "section") (ELit (LString "package"))) (EVar "key") (EIf (EVar "otherwise") (EApp (EVar "stringConcat") (EListLit (EVar "section") (ELit (LString ".")) (EVar "key"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseLinesAcc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))))))))
(DFunDef false "parseLinesAcc" ((PList) PWild (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "listReverse") (EVar "acc"))))
(DFunDef false "parseLinesAcc" ((PCons (PVar "l") (PVar "ls")) (PVar "section") (PVar "acc")) (EBlock (DoLet false false (PVar "trimmed") (EApp (EVar "trim") (EApp (EVar "stripComment") (EVar "l")))) (DoExpr (EIf (EBinOp "==" (EVar "trimmed") (ELit (LString ""))) (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "section")) (EVar "acc")) (EMatch (EApp (EVar "parseHeader") (EVar "trimmed")) (arm (PCon "Some" (PVar "hdr")) () (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "hdr")) (EVar "acc"))) (arm (PCon "None") () (EMatch (EApp (EVar "parseKv") (EVar "trimmed")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "k") (PVar "v"))) () (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "section")) (EBinOp "::" (ETuple (EApp (EApp (EVar "qualifyKey") (EVar "section")) (EVar "k")) (EVar "v")) (EVar "acc")))))))))))
(DTypeSig true "parse" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Toml"))))
(DFunDef false "parse" ((PVar "s")) (EApp (EApp (EMethodRef "map") (EVar "Toml")) (EApp (EApp (EApp (EVar "parseLinesAcc") (EApp (EVar "lines") (EVar "s"))) (ELit (LString ""))) (EListLit))))
(DTypeSig false "lookupKvs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyApp (TyCon "Option") (TyCon "TomlValue")))))
(DFunDef false "lookupKvs" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupKvs" ((PVar "key") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "key")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseGetStr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "parseGetStr" ((PVar "field") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EVar "getString") (EVar "field")) (EVar "doc")))))
(DTypeSig false "parseGetArr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "parseGetArr" ((PVar "field") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EVar "getArray") (EVar "field")) (EVar "doc")))))
(DTypeSig false "parsePackageName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "parsePackageName" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EVar "packageName") (EVar "doc")))))
(DTypeSig false "parsePackageVersion" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "parsePackageVersion" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EVar "packageVersion") (EVar "doc")))))
(DTypeSig false "parsePackageEntry" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "parsePackageEntry" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EVar "packageEntry") (EVar "doc")))))
(DTypeSig false "parseWorkspaceMembers" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "parseWorkspaceMembers" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EVar "workspaceMembers") (EVar "doc")))))
(DTypeSig true "getString" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "getString" ((PVar "key") (PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "kvs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PCon "TStr" (PVar "s"))) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "Some" (PCon "TArr" PWild)) () (EVar "None"))))
(DTypeSig true "getArray" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "getArray" ((PVar "key") (PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "kvs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PCon "TArr" (PVar "xs"))) () (EApp (EVar "Some") (EVar "xs"))) (arm (PCon "Some" (PCon "TStr" PWild)) () (EVar "None"))))
(DTypeSig true "packageName" (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "packageName" ((PVar "doc")) (EApp (EApp (EVar "getString") (ELit (LString "name"))) (EVar "doc")))
(DTypeSig true "packageVersion" (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "packageVersion" ((PVar "doc")) (EApp (EApp (EVar "getString") (ELit (LString "version"))) (EVar "doc")))
(DTypeSig true "packageEntry" (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "packageEntry" ((PVar "doc")) (EApp (EApp (EVar "getString") (ELit (LString "entry"))) (EVar "doc")))
(DTypeSig true "workspaceMembers" (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "workspaceMembers" ((PVar "doc")) (EApp (EApp (EVar "getArray") (ELit (LString "workspace.members"))) (EVar "doc")))
(DTypeSig false "eqTomlValue" (TyFun (TyCon "TomlValue") (TyFun (TyCon "TomlValue") (TyCon "Bool"))))
(DFunDef false "eqTomlValue" ((PCon "TStr" (PVar "a")) (PCon "TStr" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "eqTomlValue" ((PCon "TArr" (PVar "a")) (PCon "TArr" (PVar "b"))) (EApp (EApp (EVar "eqStrLists") (EVar "a")) (EVar "b")))
(DFunDef false "eqTomlValue" (PWild PWild) (EVar "False"))
(DTypeSig false "eqStrLists" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "eqStrLists" ((PList) (PList)) (EVar "True"))
(DFunDef false "eqStrLists" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "&&" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "eqStrLists") (EVar "xs")) (EVar "ys"))))
(DFunDef false "eqStrLists" (PWild PWild) (EVar "False"))
(DTypeSig false "eqKvList" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyCon "Bool"))))
(DFunDef false "eqKvList" ((PList) (PList)) (EVar "True"))
(DFunDef false "eqKvList" ((PCons (PTuple (PVar "k1") (PVar "v1")) (PVar "rest1")) (PCons (PTuple (PVar "k2") (PVar "v2")) (PVar "rest2"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "k1") (EVar "k2")) (EApp (EApp (EVar "eqTomlValue") (EVar "v1")) (EVar "v2"))) (EApp (EApp (EVar "eqKvList") (EVar "rest1")) (EVar "rest2"))))
(DFunDef false "eqKvList" (PWild PWild) (EVar "False"))
(DImpl true "Eq" ((TyCon "TomlValue")) () ((im "eq" () (EVar "eqTomlValue"))))
(DImpl true "Eq" ((TyCon "Toml")) () ((im "eq" ((PCon "Toml" (PVar "a")) (PCon "Toml" (PVar "b"))) (EApp (EApp (EVar "eqKvList") (EVar "a")) (EVar "b")))))
(DTypeSig false "debugTomlValue" (TyFun (TyCon "TomlValue") (TyCon "String")))
(DFunDef false "debugTomlValue" ((PCon "TStr" (PVar "s"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "TStr ")) (EApp (EMethodRef "debug") (EVar "s")))))
(DFunDef false "debugTomlValue" ((PCon "TArr" (PVar "xs"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "TArr ")) (EApp (EVar "debugStrList") (EVar "xs")))))
(DTypeSig false "debugStrList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "debugStrList" ((PVar "xs")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "[")) (EApp (EVar "joinDebugStrs") (EVar "xs")) (ELit (LString "]")))))
(DTypeSig false "joinDebugStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinDebugStrs" ((PList)) (ELit (LString "")))
(DFunDef false "joinDebugStrs" ((PCons (PVar "x") (PList))) (EApp (EMethodRef "debug") (EVar "x")))
(DFunDef false "joinDebugStrs" ((PCons (PVar "x") (PVar "xs"))) (EApp (EVar "stringConcat") (EListLit (EApp (EMethodRef "debug") (EVar "x")) (ELit (LString ", ")) (EApp (EVar "joinDebugStrs") (EVar "xs")))))
(DTypeSig false "debugKvPair" (TyFun (TyTuple (TyCon "String") (TyCon "TomlValue")) (TyCon "String")))
(DFunDef false "debugKvPair" ((PTuple (PVar "k") (PVar "v"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "(")) (EApp (EMethodRef "debug") (EVar "k")) (ELit (LString ", ")) (EApp (EVar "debugTomlValue") (EVar "v")) (ELit (LString ")")))))
(DTypeSig false "debugKvList" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyCon "String")))
(DFunDef false "debugKvList" ((PList)) (ELit (LString "")))
(DFunDef false "debugKvList" ((PCons (PVar "p") (PList))) (EApp (EVar "debugKvPair") (EVar "p")))
(DFunDef false "debugKvList" ((PCons (PVar "p") (PVar "ps"))) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "debugKvPair") (EVar "p")) (ELit (LString ", ")) (EApp (EVar "debugKvList") (EVar "ps")))))
(DImpl true "Debug" ((TyCon "TomlValue")) () ((im "debug" () (EVar "debugTomlValue"))))
(DImpl true "Debug" ((TyCon "Toml")) () ((im "debug" ((PCon "Toml" (PVar "kvs"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Toml [")) (EApp (EVar "debugKvList") (EVar "kvs")) (ELit (LString "]")))))))
(DTypeSig false "mkPackage" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "mkPackage" ((PVar "v")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "[package]\nname = \"demo\"\nversion = \"")) (EVar "v") (ELit (LString "\"")))))
(DProp false "packageVersion round-trips an Int-derived version" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parsePackageVersion") (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "Some") (EApp (EVar "intToString") (EVar "n")))))
(DProp false "packageName is stable regardless of the version value" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parsePackageName") (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "Some") (ELit (LString "demo")))))
(DProp false "packageVersion agrees with getString version" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parsePackageVersion") (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n")))) (EApp (EApp (EVar "parseGetStr") (ELit (LString "version"))) (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n"))))))
(DProp false "parse is deterministic" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parse") (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "parse") (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n"))))))
