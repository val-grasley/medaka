# META
source_lines=595
stages=DESUGAR,MARK
# SOURCE
{- json.mdk — a JSON value type with a parser and serializer.

   A from-scratch recursive-descent JSON implementation, written to exercise a
   wide cross-section of the stdlib: a recursive ADT, `Array`-backed storage,
   `Char`/`String` kernel handling, `Thenable`/`do`-notation error threading,
   and the `Eq`/`Debug`/`Display` interfaces.

   **Value model.**
   ```
   data Json = JNull | JBool Bool | JInt Int | JFloat Float | JString String
             | JArray (Array Json) | JObject (Array (String, Json))
   ```
   Numbers split into `JInt`/`JFloat` so `3` round-trips as `3` (not `3.0`) and
   the parser must classify int-vs-float. Arrays and objects are **`Array`-backed**
   (not `List`): JSON payloads are often large, and a contiguous `Array` gives
   O(1) indexing and compact, cache-friendly storage where a cons-list would cost
   O(n) access and per-cell overhead. Objects are an `Array` of `(key, value)`
   pairs — assoc-style (no `Map` dependency), so insertion order is preserved and
   round-trips exactly; key lookup is linear.

   **Parsing** uses `Thenable (Result e)` and `do` notation to thread the
   `(value, position)` pair through each parse step — `do { (v, j) <- step ;
   next v j }` desugars to the `andThen` short-circuit on `Err` automatically.

   Built on the stdlib it exists to exercise: `list.reverse`, `string.join`/
   `fromChars`/`isDigit`/`toInt`, the `Thenable` monad interface, `do`
   notation, plus the global `array*`/`string*`/`char*` externs. Equality is
   hand-rolled element-wise (so the `Json` `Eq` recurses
   through the `Array` fields without an `Eq (Array a)` dependency) and is
   **positional** for objects (two objects with the same pairs in a different
   order compare unequal — fine for round-tripping, which preserves order).

   **Not handled (v1):** `\uXXXX` surrogate pairs (astral codepoints); strict
   leading-zero / number-grammar rejection (the number scan is lenient). -}

import core.{Eq, Debug, Display, Option, Result, Thenable, map}
import list.{reverse}
import array
import string.{join, fromChars, isDigit, toInt}

public export data Json =
  | JNull
  | JBool Bool
  | JInt Int
  | JFloat Float
  | JString String
  | JArray (Array Json)
  | JObject (Array (String, Json))

-- ── Construction helpers ────────────────────────────────────────────────

{- | Build a `JArray` from a list (stored as a contiguous `Array`).

   > stringify (jArray [JInt 1, JInt 2, JInt 3]) == "[1,2,3]"
   True
   > stringify (jArray []) == "[]"
   True -}
export jArray : List Json -> Json
jArray xs = JArray (arrayFromList xs)

{- | Build a `JObject` from a list of key/value pairs (order preserved).

   > stringify (jObject [("a", JInt 1), ("b", JBool True)]) == "{\"a\":1,\"b\":true}"
   True
   > stringify (jObject []) == "{}"
   True -}
export jObject : List (String, Json) -> Json
jObject xs = JObject (arrayFromList xs)

-- A codepoint to a `Char` (the `\u` escape target is always valid here).
charOfCode : Int -> Char
charOfCode k = match charFromCode k
  Some c => c
  None => ' '

-- ── Serialization ───────────────────────────────────────────────────────

-- `floatToString` can emit a trailing-dot form (e.g. `1000.0` → "1000.") which
-- is not valid JSON (a number needs a digit after the point).  Append a `0` in
-- that case so serialized floats always re-parse.
renderFloat : Float -> String
renderFloat f = fixTrailingDot (floatToString f)

fixTrailingDot : String -> String
fixTrailingDot s = fixTrailingDotGo s (stringToChars s)

fixTrailingDotGo : String -> Array Char -> String
fixTrailingDotGo s arr
  | arrayLength arr > 0 && charCode (arrayGetUnsafe (arrayLength arr - 1) arr) == 46 = stringConcat [s, "0"]
  | otherwise = s

hexDigit : Int -> String
hexDigit d = stringSlice d (d + 1) "0123456789abcdef"

-- A control char (< 0x20) as a `\u00XX` escape.
unicodeEscape : Int -> String
unicodeEscape code =
  stringConcat ["\\u00", hexDigit (code / 16), hexDigit (code % 16)]

-- One source char as its JSON-escaped piece.
escapeChar : Char -> String
escapeChar c
  | charCode c == 34 = "\\\""
  | charCode c == 92 = "\\\\"
  | charCode c == 8 = "\\b"
  | charCode c == 9 = "\\t"
  | charCode c == 10 = "\\n"
  | charCode c == 12 = "\\f"
  | charCode c == 13 = "\\r"
  | charCode c < 32 = unicodeEscape (charCode c)
  | otherwise = charToStr c

escapeGo : Array Char -> Int -> List String -> List String
escapeGo arr i acc
  | i < 0 = acc
  | otherwise = escapeGo arr (i - 1) (escapeChar (arrayGetUnsafe i arr) :: acc)

-- A `String` as a quoted, escaped JSON string literal.  Exported so callers
-- outside this module (e.g. compiler/tools/mcp.mdk's opt-in call log) can
-- safely embed an arbitrary, client-controlled String in a single-line
-- record without it splitting across lines on an embedded '\n'/'\t'.
export escapeString : String -> String
escapeString s =
  let arr = stringToChars s
  let pieces = escapeGo arr (arrayLength arr - 1) []
  stringConcat (["\""] ++ pieces ++ ["\""])

elemStrings : Array Json -> Int -> List String -> List String
elemStrings arr i acc
  | i < 0 = acc
  | otherwise =
    elemStrings arr (i - 1) (stringify (arrayGetUnsafe i arr) :: acc)

memberStrings : Array (String, Json) -> Int -> List String -> List String
memberStrings pairs i acc
  | i < 0 = acc
  | otherwise =
    let p = arrayGetUnsafe i pairs
    let s = stringConcat [escapeString (fst p), ":", stringify (snd p)]
    memberStrings pairs (i - 1) (s::acc)

{- | Serialize a `Json` to compact JSON text (no insignificant whitespace).

   > stringify JNull == "null"
   True
   > stringify (JArray (arrayFromList [JInt 1, JBool True])) == "[1,true]"
   True
   > stringify (jObject [("a", JInt 1), ("b", JString "hi")]) == "{\"a\":1,\"b\":\"hi\"}"
   True
   > stringify (JFloat 1000.0) == "1000.0"
   True -}
export stringify : Json -> String
stringify JNull = "null"
stringify (JBool True) = "true"
stringify (JBool False) = "false"
stringify (JInt n) = intToString n
stringify (JFloat f) = renderFloat f
stringify (JString s) = escapeString s
stringify (JArray arr) =
  let body = join "," (elemStrings arr (arrayLength arr - 1) [])
  stringConcat ["[", body, "]"]
stringify (JObject pairs) =
  let body = join "," (memberStrings pairs (arrayLength pairs - 1) [])
  stringConcat ["{", body, "}"]

-- ── Parsing (recursive descent over an Array Char + position) ────────────

-- JSON whitespace is *exactly* space, tab, LF, CR — stricter than
-- `string.isSpace` (which accepts other Unicode space chars), so it stays local.
-- Same predicate as sqlite/lib/sqlite.mdk's isSpaceChar; not consolidated since
-- sqlite shouldn't need to import all of json for one char check.
isWs : Char -> Bool
-- lint-disable-next-line rule-duplicate-body
isWs c = charCode c == 32
  || charCode c == 9
  || charCode c == 10
  || charCode c == 13

skipWs : Array Char -> Int -> Int
skipWs arr i
  | i < arrayLength arr && isWs (arrayGetUnsafe i arr) = skipWs arr (i + 1)
  | otherwise = i

-- String body (i points just past the opening quote; acc is reversed chars).
parseStr : Array Char -> Int -> List Char -> Result String (String, Int)
parseStr arr i acc
  | i >= arrayLength arr = Err "unterminated string"
  | otherwise = parseStrChar arr i acc (arrayGetUnsafe i arr)

parseStrChar : Array Char -> Int -> List Char -> Char -> Result String (String, Int)
parseStrChar arr i acc c
  | charCode c == 34 = Ok (fromChars (reverse acc), i + 1)
  | charCode c == 92 = parseEsc arr (i + 1) acc
  | otherwise = parseStr arr (i + 1) (c::acc)

parseEsc : Array Char -> Int -> List Char -> Result String (String, Int)
parseEsc arr i acc
  | i >= arrayLength arr = Err "unterminated escape"
  | otherwise = parseEscChar arr i acc (arrayGetUnsafe i arr)

parseEscChar : Array Char -> Int -> List Char -> Char -> Result String (String, Int)
parseEscChar arr i acc c
  | charCode c == 34 = parseStr arr (i + 1) (c::acc)
  | charCode c == 92 = parseStr arr (i + 1) (c::acc)
  | charCode c == 47 = parseStr arr (i + 1) (c::acc)
  | c == 'n' = parseStr arr (i + 1) (charOfCode 10 :: acc)
  | c == 't' = parseStr arr (i + 1) (charOfCode 9 :: acc)
  | c == 'r' = parseStr arr (i + 1) (charOfCode 13 :: acc)
  | c == 'b' = parseStr arr (i + 1) (charOfCode 8 :: acc)
  | c == 'f' = parseStr arr (i + 1) (charOfCode 12 :: acc)
  | c == 'u' = parseUnicode arr (i + 1) acc
  | otherwise = Err "invalid escape sequence"

hexVal : Char -> Option Int
hexVal c
  | charCode c >= 48 && charCode c <= 57 = Some (charCode c - 48)
  | charCode c >= 97 && charCode c <= 102 = Some (charCode c - 87)
  | charCode c >= 65 && charCode c <= 70 = Some (charCode c - 55)
  | otherwise = None

-- Four hex digits at [i, i+4) → a codepoint (BMP only; no surrogate pairing).
hex4 : Array Char -> Int -> Option Int
hex4 arr i = match hexVal (arrayGetUnsafe i arr)
  None => None
  Some h0 => hex4From arr i h0

hex4From : Array Char -> Int -> Int -> Option Int
hex4From arr i h0 = match hexVal (arrayGetUnsafe (i + 1) arr)
  None => None
  Some h1 => hex4From2 arr i (h0 * 16 + h1)

hex4From2 : Array Char -> Int -> Int -> Option Int
hex4From2 arr i acc = match hexVal (arrayGetUnsafe (i + 2) arr)
  None => None
  Some h2 => hex4From3 arr i (acc * 16 + h2)

hex4From3 : Array Char -> Int -> Int -> Option Int
hex4From3 arr i acc = map (acc * 16 + _) (hexVal (arrayGetUnsafe (i + 3) arr))

parseUnicode : Array Char -> Int -> List Char -> Result String (String, Int)
parseUnicode arr i acc
  | i + 4 > arrayLength arr = Err "invalid \\u escape"
  | otherwise = parseUnicodeAt arr i acc (hex4 arr i)

parseUnicodeAt : Array Char -> Int -> List Char -> Option Int -> Result String (String, Int)
parseUnicodeAt arr i acc None = Err "invalid \\u escape"
parseUnicodeAt arr i acc (Some k) = parseStr arr (i + 4) (charOfCode k :: acc)

-- Numbers: scan the token, classify int vs float, build the value.
skipSign : Array Char -> Int -> Int
skipSign arr i
  | i < arrayLength arr && arrayGetUnsafe i arr == '-' = i + 1
  | otherwise = i

skipDigits : Array Char -> Int -> Int
skipDigits arr i
  | i < arrayLength arr && isDigit (arrayGetUnsafe i arr) =
    skipDigits arr (i + 1)
  | otherwise = i

-- (newPosition, sawFraction)
skipFrac : Array Char -> Int -> (Int, Bool)
skipFrac arr i
  | i < arrayLength arr && arrayGetUnsafe i arr == '.' =
    (skipDigits arr (i + 1), True)
  | otherwise = (i, False)

skipExp : Array Char -> Int -> (Int, Bool)
skipExp arr i
  | i < arrayLength arr && isExpChar (arrayGetUnsafe i arr) =
    (skipDigits arr (skipSign arr (i + 1)), True)
  | otherwise = (i, False)

isExpChar : Char -> Bool
isExpChar c = c == 'e' || c == 'E'

subString : Array Char -> Int -> Int -> String
subString arr start end = stringFromChars (arrayMakeWith
  (end - start)
  (k => arrayGetUnsafe (start + k) arr))

parseNumber : Array Char -> Int -> Result String (Json, Int)
parseNumber arr start =
  let afterSign = skipSign arr start
  let afterInt = skipDigits arr afterSign
  let fracR = skipFrac arr afterInt
  let expR = skipExp arr (fst fracR)
  finishNumber arr start afterSign afterInt (fst expR) (snd fracR || snd expR)

finishNumber : Array Char -> Int -> Int -> Int -> Int -> Bool -> Result String (Json, Int)
finishNumber arr start afterSign afterInt end isFloat
  | afterInt == afterSign = Err "invalid number: no digits"
  | isFloat = finishFloat (subString arr start end) end
  | otherwise = finishInt (subString arr start end) end

finishInt : String -> Int -> Result String (Json, Int)
finishInt tok end = match toInt tok
  Some n => Ok (JInt n, end)
  None => Err "invalid number"

finishFloat : String -> Int -> Result String (Json, Int)
finishFloat tok end = match stringToFloat tok
  Some f => Ok (JFloat f, end)
  None => Err "invalid number"

-- Keyword literals (true/false/null).
matchLit : Array Char -> Int -> Array Char -> Int -> Int -> Bool
matchLit arr j litArr k m
  | k >= m = True
  | j + k >= arrayLength arr = False
  | arrayGetUnsafe (j + k) arr == arrayGetUnsafe k litArr =
    matchLit arr j litArr (k + 1) m
  | otherwise = False

parseLit : Array Char -> Int -> String -> Json -> Result String (Json, Int)
parseLit arr j lit val =
  let litArr = stringToChars lit
  parseLitGo arr j litArr (arrayLength litArr) lit val

parseLitGo : Array Char -> Int -> Array Char -> Int -> String -> Json -> Result String (Json, Int)
parseLitGo arr j litArr m lit val
  | matchLit arr j litArr 0 m = Ok (val, j + m)
  | otherwise = Err (stringConcat ["invalid literal, expected '", lit, "'"])

-- Arrays and objects.
parseArray : Array Char -> Int -> Result String (Json, Int)
parseArray arr i = parseArrayAt arr (skipWs arr i)

parseArrayAt : Array Char -> Int -> Result String (Json, Int)
parseArrayAt arr j
  | j < arrayLength arr && arrayGetUnsafe j arr == ']' =
    Ok (JArray (arrayFromList []), j + 1)
  | otherwise = do
    (xs, k) <- parseElems arr j []
    Ok (JArray (arrayFromList (reverse xs)), k)

parseElems : Array Char -> Int -> List Json -> Result String (List Json, Int)
parseElems arr i acc = do
  (v, j) <- parseValue arr i
  parseElemsCont arr (skipWs arr j) (v::acc)

parseElemsCont : Array Char -> Int -> List Json -> Result String (List Json, Int)
parseElemsCont arr k acc
  | k >= arrayLength arr = Err "unterminated array"
  | arrayGetUnsafe k arr == ',' = parseElems arr (k + 1) acc
  | arrayGetUnsafe k arr == ']' = Ok (acc, k + 1)
  | otherwise = Err "expected ',' or ']' in array"

parseObject : Array Char -> Int -> Result String (Json, Int)
parseObject arr i = parseObjectAt arr (skipWs arr i)

parseObjectAt : Array Char -> Int -> Result String (Json, Int)
parseObjectAt arr j
  | j < arrayLength arr && arrayGetUnsafe j arr == '}' =
    Ok (JObject (arrayFromList []), j + 1)
  | otherwise = do
    (ms, k) <- parseMembers arr j []
    Ok (JObject (arrayFromList (reverse ms)), k)

parseMembers : Array Char -> Int -> List (String, Json) -> Result String (List (String, Json), Int)
parseMembers arr i acc = parseMemberStart arr (skipWs arr i) acc

parseMemberStart : Array Char -> Int -> List (String, Json) -> Result String (List (String, Json), Int)
parseMemberStart arr j acc
  | j >= arrayLength arr = Err "unterminated object"
  | arrayGetUnsafe j arr == '"' = do
    (key, k) <- parseStr arr (j + 1) []
    parseAfterKey arr (skipWs arr k) key acc
  | otherwise = Err "expected string key in object"

parseAfterKey : Array Char -> Int -> String -> List (String, Json) -> Result String (List (String, Json), Int)
parseAfterKey arr k key acc
  | k >= arrayLength arr = Err "unterminated object"
  | arrayGetUnsafe k arr == ':' = do
    (v, m) <- parseValue arr (k + 1)
    parseMemberCont arr (skipWs arr m) ((key, v)::acc)
  | otherwise = Err "expected ':' after object key"

parseMemberCont : Array Char -> Int -> List (String, Json) -> Result String (List (String, Json), Int)
parseMemberCont arr m acc
  | m >= arrayLength arr = Err "unterminated object"
  | arrayGetUnsafe m arr == ',' = parseMembers arr (m + 1) acc
  | arrayGetUnsafe m arr == '}' = Ok (acc, m + 1)
  | otherwise = Err "expected ',' or '}' in object"

-- Value dispatch.
parseValue : Array Char -> Int -> Result String (Json, Int)
parseValue arr i = parseValueAt arr (skipWs arr i)

parseValueAt : Array Char -> Int -> Result String (Json, Int)
parseValueAt arr j
  | j >= arrayLength arr = Err "unexpected end of input"
  | otherwise = dispatchValue arr j (arrayGetUnsafe j arr)

dispatchValue : Array Char -> Int -> Char -> Result String (Json, Int)
dispatchValue arr j c
  | c == '{' = parseObject arr (j + 1)
  | c == '[' = parseArray arr (j + 1)
  | c == '"' = do
    (s, k) <- parseStr arr (j + 1) []
    Ok (JString s, k)
  | c == 't' = parseLit arr j "true" (JBool True)
  | c == 'f' = parseLit arr j "false" (JBool False)
  | c == 'n' = parseLit arr j "null" JNull
  | c == '-' = parseNumber arr j
  | isDigit c = parseNumber arr j
  | otherwise = Err (stringConcat ["unexpected character '", charToStr c, "'"])

{- | Parse JSON text into a `Json`, or an error message.

   > parse "null" == Ok JNull
   True
   > parse "[1, 2, 3]" == Ok (jArray [JInt 1, JInt 2, JInt 3])
   True
   > parse "  {\"k\": true}  " == Ok (jObject [("k", JBool True)])
   True
   > parse "nope"
   Err "invalid literal, expected 'null'" -}
export parse : String -> Result String Json
parse s = parseTop (stringToChars s)

parseTop : Array Char -> Result String Json
parseTop arr = do
  (v, j) <- parseValue arr 0
  ensureEnd arr (skipWs arr j) v

ensureEnd : Array Char -> Int -> Json -> Result String Json
ensureEnd arr j v
  | j >= arrayLength arr = Ok v
  | otherwise = Err "trailing characters after JSON value"

-- ── Accessors ───────────────────────────────────────────────────────────

{- | Value at a key in a `JObject` (linear scan), or `None`.

   > lookup "b" (jObject [("a", JInt 1), ("b", JInt 2)]) == Some (JInt 2)
   True
   > lookup "z" (jObject [("a", JInt 1)]) == None
   True -}
export lookup : String -> Json -> Option Json
lookup key (JObject pairs) = lookupGo key pairs 0 (arrayLength pairs)
lookup _ _ = None

lookupGo : String -> Array (String, Json) -> Int -> Int -> Option Json
lookupGo key pairs i n
  | i >= n = None
  | fst (arrayGetUnsafe i pairs) == key = Some (snd (arrayGetUnsafe i pairs))
  | otherwise = lookupGo key pairs (i + 1) n

{- | Element at an index in a `JArray` (O(1)), or `None`.

   > at 1 (jArray [JInt 10, JInt 20, JInt 30]) == Some (JInt 20)
   True
   > at 5 (jArray [JInt 10]) == None
   True
   > at 0 (JInt 1) == None
   True -}
export at : Int -> Json -> Option Json
at k (JArray arr)
  | k >= 0 && k < arrayLength arr = Some (arrayGetUnsafe k arr)
  | otherwise = None
at _ _ = None

{- | The `String` inside a `JString`, or `None`.

   > asString (JString "hi") == Some "hi"
   True
   > asString (JInt 1) == None
   True -}
export asString : Json -> Option String
asString (JString s) = Some s
asString _ = None

{- | The `Int` inside a `JInt`, or `None`.

   > asInt (JInt 7) == Some 7
   True
   > asInt JNull == None
   True -}
export asInt : Json -> Option Int
asInt (JInt n) = Some n
asInt _ = None

{- | The `Float` inside a `JFloat`, or `None`.

   > asFloat (JFloat 1.5) == Some 1.5
   True
   > asFloat (JInt 1) == None
   True -}
export asFloat : Json -> Option Float
asFloat (JFloat f) = Some f
asFloat _ = None

{- | The `Bool` inside a `JBool`, or `None`.

   > asBool (JBool True) == Some True
   True
   > asBool JNull == None
   True -}
export asBool : Json -> Option Bool
asBool (JBool b) = Some b
asBool _ = None

{- | The backing `Array` of a `JArray`, or `None`.  (Re-wrap the result in
   `JArray` with `map` to compare it as a `Json` — there is no `Eq (Array Json)`
   in scope here.)

   > map JArray (asArray (jArray [JInt 1, JInt 2])) == Some (jArray [JInt 1, JInt 2])
   True
   > asArray (JInt 1) == None
   True -}
export asArray : Json -> Option (Array Json)
asArray (JArray a) = Some a
asArray _ = None

-- ── Instances ───────────────────────────────────────────────────────────

arrEqJson : Array Json -> Array Json -> Int -> Bool
arrEqJson a b i
  | i >= arrayLength a = True
  | otherwise = eq (arrayGetUnsafe i a) (arrayGetUnsafe i b)
    && arrEqJson a b (i + 1)

objEqJson : Array (String, Json) -> Array (String, Json) -> Int -> Bool
objEqJson a b i
  | i >= arrayLength a = True
  | otherwise =
    let pa = arrayGetUnsafe i a
    let pb = arrayGetUnsafe i b
    fst pa == fst pb && eq (snd pa) (snd pb) && objEqJson a b (i + 1)

{- | Structural equality. Objects compare **positionally** (same pairs in the
   same order), which is what `parse-then-stringify` preserves.

   > eq (parse "[1, 2]") (Ok (jArray [JInt 1, JInt 2]))
   True -}
export impl Eq Json where
  eq JNull JNull = True
  eq (JBool a) (JBool b) = a == b
  eq (JInt a) (JInt b) = a == b
  eq (JFloat a) (JFloat b) = a == b
  eq (JString a) (JString b) = a == b
  eq (JArray a) (JArray b) = arrayLength a == arrayLength b && arrEqJson a b 0
  eq (JObject a) (JObject b) = arrayLength a == arrayLength b && objEqJson a b 0
  eq _ _ = False

{- | `debug` renders compact JSON text (same as `stringify`). -}
export impl Debug Json where
  debug j = stringify j

{- | `display`/`\{…}` also render compact JSON text. -}
export impl Display Json where
  display j = stringify j

-- ── Property tests ───────────────────────────────────────────────────────
-- `parse` is a left inverse of `stringify` for every value `stringify` emits.
-- (`Json` has no `Arbitrary` instance, so each prop builds representative
-- values from generated `Int`/`String`/`Bool` inputs.)  A generative float
-- round-trip is intentionally omitted: `floatToString`/`stringToFloat` lose
-- subnormal floats (e.g. 1.7e-311), which is a number-formatting limitation,
-- not a JSON bug — fixed-float round-tripping is covered by the `1000.0` and
-- `1.5` doctests instead.

prop "parse-then-stringify round-trips a JInt" (n : Int) =
  parse (stringify (JInt n)) == Ok (JInt n)

prop "parse-then-stringify round-trips a JString (exercises escaping)" (s : String) = parse (stringify (JString s)) == Ok (JString s)

prop "parse-then-stringify round-trips a JBool" (b : Bool) =
  parse (stringify (JBool b)) == Ok (JBool b)

prop "parse-then-stringify round-trips an int JArray" (xs : List Int) =
  let j = jArray (map JInt xs)
  parse (stringify j) == Ok j

prop "parse-then-stringify round-trips a JObject" (xs : List Int) =
  let j = jObject (map (n => (intToString n, JInt n)) xs)
  parse (stringify j) == Ok j

prop "asInt (JInt n) == Some n" (n : Int) = asInt (JInt n) == Some n
prop "asString (JString s) == Some s" (s : String) =
  asString (JString s) == Some s
prop "asBool (JBool b) == Some b" (b : Bool) = asBool (JBool b) == Some b
prop "asFloat (JFloat f) == Some f" (f : Float) = asFloat (JFloat f) == Some f

prop "asArray recovers a built JArray" (xs : List Int) =
  let arr = map JInt xs
  map JArray (asArray (jArray arr)) == Some (jArray arr)

prop "at k recovers the k-th element of a JArray" (n : Int) =
  let k = if n < 0 then 0 - n else n
  at k (jArray (map JInt [0..=k])) == Some (JInt k)

prop "lookup finds an inserted key" (k : Int) (v : Int) =
  lookup (intToString k) (jObject [(intToString k, JInt v)]) == Some (JInt v)
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Debug" false) (mem "Display" false) (mem "Option" false) (mem "Result" false) (mem "Thenable" false) (mem "map" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseName ("array")))
(DUse false (UseGroup ("string") ((mem "join" false) (mem "fromChars" false) (mem "isDigit" false) (mem "toInt" false))))
(DData Public "Json" () ((variant "JNull" (ConPos)) (variant "JBool" (ConPos (TyCon "Bool"))) (variant "JInt" (ConPos (TyCon "Int"))) (variant "JFloat" (ConPos (TyCon "Float"))) (variant "JString" (ConPos (TyCon "String"))) (variant "JArray" (ConPos (TyApp (TyCon "Array") (TyCon "Json")))) (variant "JObject" (ConPos (TyApp (TyCon "Array") (TyTuple (TyCon "String") (TyCon "Json")))))) ())
(DTypeSig true "jArray" (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyCon "Json")))
(DFunDef false "jArray" ((PVar "xs")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EVar "xs"))))
(DTypeSig true "jObject" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyCon "Json")))
(DFunDef false "jObject" ((PVar "xs")) (EApp (EVar "JObject") (EApp (EVar "arrayFromList") (EVar "xs"))))
(DTypeSig false "charOfCode" (TyFun (TyCon "Int") (TyCon "Char")))
(DFunDef false "charOfCode" ((PVar "k")) (EMatch (EApp (EVar "charFromCode") (EVar "k")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (ELit (LChar " ")))))
(DTypeSig false "renderFloat" (TyFun (TyCon "Float") (TyCon "String")))
(DFunDef false "renderFloat" ((PVar "f")) (EApp (EVar "fixTrailingDot") (EApp (EVar "floatToString") (EVar "f"))))
(DTypeSig false "fixTrailingDot" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "fixTrailingDot" ((PVar "s")) (EApp (EApp (EVar "fixTrailingDotGo") (EVar "s")) (EApp (EVar "stringToChars") (EVar "s"))))
(DTypeSig false "fixTrailingDotGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "String"))))
(DFunDef false "fixTrailingDotGo" ((PVar "s") (PVar "arr")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 0))) (EBinOp "==" (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "arr"))) (ELit (LInt 46)))) (EApp (EVar "stringConcat") (EListLit (EVar "s") (ELit (LString "0")))) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hexDigit" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "hexDigit" ((PVar "d")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "d")) (EBinOp "+" (EVar "d") (ELit (LInt 1)))) (ELit (LString "0123456789abcdef"))))
(DTypeSig false "unicodeEscape" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "unicodeEscape" ((PVar "code")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "\\u00")) (EApp (EVar "hexDigit") (EBinOp "/" (EVar "code") (ELit (LInt 16)))) (EApp (EVar "hexDigit") (EBinOp "%" (EVar "code") (ELit (LInt 16)))))))
(DTypeSig false "escapeChar" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "escapeChar" ((PVar "c")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 34))) (ELit (LString "\\\"")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 92))) (ELit (LString "\\\\")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 8))) (ELit (LString "\\b")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 9))) (ELit (LString "\\t")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 10))) (ELit (LString "\\n")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 12))) (ELit (LString "\\f")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 13))) (ELit (LString "\\r")) (EIf (EBinOp "<" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 32))) (EApp (EVar "unicodeEscape") (EApp (EVar "charCode") (EVar "c"))) (EIf (EVar "otherwise") (EApp (EVar "charToStr") (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))
(DTypeSig false "escapeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "escapeGo" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "escapeGo") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "escapeChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "escapeString" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escapeString" ((PVar "s")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "pieces") (EApp (EApp (EApp (EVar "escapeGo") (EVar "arr")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EListLit))) (DoExpr (EApp (EVar "stringConcat") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "\""))) (EVar "pieces")) (EListLit (ELit (LString "\""))))))))
(DTypeSig false "elemStrings" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "elemStrings" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "elemStrings") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "stringify") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "memberStrings" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "String") (TyCon "Json"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "memberStrings" ((PVar "pairs") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "p") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "pairs"))) (DoLet false false (PVar "s") (EApp (EVar "stringConcat") (EListLit (EApp (EVar "escapeString") (EApp (EVar "fst") (EVar "p"))) (ELit (LString ":")) (EApp (EVar "stringify") (EApp (EVar "snd") (EVar "p")))))) (DoExpr (EApp (EApp (EApp (EVar "memberStrings") (EVar "pairs")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "s") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "stringify" (TyFun (TyCon "Json") (TyCon "String")))
(DFunDef false "stringify" ((PCon "JNull")) (ELit (LString "null")))
(DFunDef false "stringify" ((PCon "JBool" (PCon "True"))) (ELit (LString "true")))
(DFunDef false "stringify" ((PCon "JBool" (PCon "False"))) (ELit (LString "false")))
(DFunDef false "stringify" ((PCon "JInt" (PVar "n"))) (EApp (EVar "intToString") (EVar "n")))
(DFunDef false "stringify" ((PCon "JFloat" (PVar "f"))) (EApp (EVar "renderFloat") (EVar "f")))
(DFunDef false "stringify" ((PCon "JString" (PVar "s"))) (EApp (EVar "escapeString") (EVar "s")))
(DFunDef false "stringify" ((PCon "JArray" (PVar "arr"))) (EBlock (DoLet false false (PVar "body") (EApp (EApp (EVar "join") (ELit (LString ","))) (EApp (EApp (EApp (EVar "elemStrings") (EVar "arr")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EListLit)))) (DoExpr (EApp (EVar "stringConcat") (EListLit (ELit (LString "[")) (EVar "body") (ELit (LString "]")))))))
(DFunDef false "stringify" ((PCon "JObject" (PVar "pairs"))) (EBlock (DoLet false false (PVar "body") (EApp (EApp (EVar "join") (ELit (LString ","))) (EApp (EApp (EApp (EVar "memberStrings") (EVar "pairs")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "pairs")) (ELit (LInt 1)))) (EListLit)))) (DoExpr (EApp (EVar "stringConcat") (EListLit (ELit (LString "{")) (EVar "body") (ELit (LString "}")))))))
(DTypeSig false "isWs" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isWs" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 32))) (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 9)))) (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 10)))) (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 13)))))
(DTypeSig false "skipWs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "skipWs" ((PVar "arr") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "isWs") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "parseStr" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated string"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "parseStrChar") (EVar "arr")) (EVar "i")) (EVar "acc")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseStrChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Char") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "parseStrChar" ((PVar "arr") (PVar "i") (PVar "acc") (PVar "c")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 34))) (EApp (EVar "Ok") (ETuple (EApp (EVar "fromChars") (EApp (EVar "reverse") (EVar "acc"))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 92))) (EApp (EApp (EApp (EVar "parseEsc") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "c") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseEsc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "parseEsc" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated escape"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "parseEscChar") (EVar "arr")) (EVar "i")) (EVar "acc")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseEscChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Char") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "parseEscChar" ((PVar "arr") (PVar "i") (PVar "acc") (PVar "c")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 34))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "c") (EVar "acc"))) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 92))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "c") (EVar "acc"))) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 47))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "c") (EVar "acc"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "n"))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "charOfCode") (ELit (LInt 10))) (EVar "acc"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "t"))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "charOfCode") (ELit (LInt 9))) (EVar "acc"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "r"))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "charOfCode") (ELit (LInt 13))) (EVar "acc"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "b"))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "charOfCode") (ELit (LInt 8))) (EVar "acc"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "f"))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "charOfCode") (ELit (LInt 12))) (EVar "acc"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "u"))) (EApp (EApp (EApp (EVar "parseUnicode") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "invalid escape sequence"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))))
(DTypeSig false "hexVal" (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "hexVal" ((PVar "c")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48))) (EBinOp "<=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 57)))) (EApp (EVar "Some") (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48)))) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 97))) (EBinOp "<=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 102)))) (EApp (EVar "Some") (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 87)))) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 65))) (EBinOp "<=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 70)))) (EApp (EVar "Some") (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 55)))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "hex4" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "hex4" ((PVar "arr") (PVar "i")) (EMatch (EApp (EVar "hexVal") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "h0")) () (EApp (EApp (EApp (EVar "hex4From") (EVar "arr")) (EVar "i")) (EVar "h0")))))
(DTypeSig false "hex4From" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "hex4From" ((PVar "arr") (PVar "i") (PVar "h0")) (EMatch (EApp (EVar "hexVal") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "h1")) () (EApp (EApp (EApp (EVar "hex4From2") (EVar "arr")) (EVar "i")) (EBinOp "+" (EBinOp "*" (EVar "h0") (ELit (LInt 16))) (EVar "h1"))))))
(DTypeSig false "hex4From2" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "hex4From2" ((PVar "arr") (PVar "i") (PVar "acc")) (EMatch (EApp (EVar "hexVal") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "arr"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "h2")) () (EApp (EApp (EApp (EVar "hex4From3") (EVar "arr")) (EVar "i")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 16))) (EVar "h2"))))))
(DTypeSig false "hex4From3" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "hex4From3" ((PVar "arr") (PVar "i") (PVar "acc")) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 16))) (EVar "_s")))) (EApp (EVar "hexVal") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 3)))) (EVar "arr")))))
(DTypeSig false "parseUnicode" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "parseUnicode" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">" (EBinOp "+" (EVar "i") (ELit (LInt 4))) (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "invalid \\u escape"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "parseUnicodeAt") (EVar "arr")) (EVar "i")) (EVar "acc")) (EApp (EApp (EVar "hex4") (EVar "arr")) (EVar "i"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseUnicodeAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "parseUnicodeAt" ((PVar "arr") (PVar "i") (PVar "acc") (PCon "None")) (EApp (EVar "Err") (ELit (LString "invalid \\u escape"))))
(DFunDef false "parseUnicodeAt" ((PVar "arr") (PVar "i") (PVar "acc") (PCon "Some" (PVar "k"))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 4)))) (EBinOp "::" (EApp (EVar "charOfCode") (EVar "k")) (EVar "acc"))))
(DTypeSig false "skipSign" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "skipSign" ((PVar "arr") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "-")))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "skipDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "skipDigits" ((PVar "arr") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "isDigit") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (EApp (EApp (EVar "skipDigits") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "skipFrac" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "skipFrac" ((PVar "arr") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar ".")))) (ETuple (EApp (EApp (EVar "skipDigits") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "True")) (EIf (EVar "otherwise") (ETuple (EVar "i") (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "skipExp" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "skipExp" ((PVar "arr") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "isExpChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (ETuple (EApp (EApp (EVar "skipDigits") (EVar "arr")) (EApp (EApp (EVar "skipSign") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EVar "True")) (EIf (EVar "otherwise") (ETuple (EVar "i") (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isExpChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isExpChar" ((PVar "c")) (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "e"))) (EBinOp "==" (EVar "c") (ELit (LChar "E")))))
(DTypeSig false "subString" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "subString" ((PVar "arr") (PVar "start") (PVar "end")) (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "end") (EVar "start"))) (ELam ((PVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "start") (EVar "k"))) (EVar "arr"))))))
(DTypeSig false "parseNumber" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "parseNumber" ((PVar "arr") (PVar "start")) (EBlock (DoLet false false (PVar "afterSign") (EApp (EApp (EVar "skipSign") (EVar "arr")) (EVar "start"))) (DoLet false false (PVar "afterInt") (EApp (EApp (EVar "skipDigits") (EVar "arr")) (EVar "afterSign"))) (DoLet false false (PVar "fracR") (EApp (EApp (EVar "skipFrac") (EVar "arr")) (EVar "afterInt"))) (DoLet false false (PVar "expR") (EApp (EApp (EVar "skipExp") (EVar "arr")) (EApp (EVar "fst") (EVar "fracR")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "finishNumber") (EVar "arr")) (EVar "start")) (EVar "afterSign")) (EVar "afterInt")) (EApp (EVar "fst") (EVar "expR"))) (EBinOp "||" (EApp (EVar "snd") (EVar "fracR")) (EApp (EVar "snd") (EVar "expR")))))))
(DTypeSig false "finishNumber" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))))))
(DFunDef false "finishNumber" ((PVar "arr") (PVar "start") (PVar "afterSign") (PVar "afterInt") (PVar "end") (PVar "isFloat")) (EIf (EBinOp "==" (EVar "afterInt") (EVar "afterSign")) (EApp (EVar "Err") (ELit (LString "invalid number: no digits"))) (EIf (EVar "isFloat") (EApp (EApp (EVar "finishFloat") (EApp (EApp (EApp (EVar "subString") (EVar "arr")) (EVar "start")) (EVar "end"))) (EVar "end")) (EIf (EVar "otherwise") (EApp (EApp (EVar "finishInt") (EApp (EApp (EApp (EVar "subString") (EVar "arr")) (EVar "start")) (EVar "end"))) (EVar "end")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "finishInt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "finishInt" ((PVar "tok") (PVar "end")) (EMatch (EApp (EVar "toInt") (EVar "tok")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (ETuple (EApp (EVar "JInt") (EVar "n")) (EVar "end")))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "invalid number"))))))
(DTypeSig false "finishFloat" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "finishFloat" ((PVar "tok") (PVar "end")) (EMatch (EApp (EVar "stringToFloat") (EVar "tok")) (arm (PCon "Some" (PVar "f")) () (EApp (EVar "Ok") (ETuple (EApp (EVar "JFloat") (EVar "f")) (EVar "end")))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "invalid number"))))))
(DTypeSig false "matchLit" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "matchLit" ((PVar "arr") (PVar "j") (PVar "litArr") (PVar "k") (PVar "m")) (EIf (EBinOp ">=" (EVar "k") (EVar "m")) (EVar "True") (EIf (EBinOp ">=" (EBinOp "+" (EVar "j") (EVar "k")) (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "j") (EVar "k"))) (EVar "arr")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "litArr"))) (EApp (EApp (EApp (EApp (EApp (EVar "matchLit") (EVar "arr")) (EVar "j")) (EVar "litArr")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "m")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseLit" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))))
(DFunDef false "parseLit" ((PVar "arr") (PVar "j") (PVar "lit") (PVar "val")) (EBlock (DoLet false false (PVar "litArr") (EApp (EVar "stringToChars") (EVar "lit"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseLitGo") (EVar "arr")) (EVar "j")) (EVar "litArr")) (EApp (EVar "arrayLength") (EVar "litArr"))) (EVar "lit")) (EVar "val")))))
(DTypeSig false "parseLitGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))))))
(DFunDef false "parseLitGo" ((PVar "arr") (PVar "j") (PVar "litArr") (PVar "m") (PVar "lit") (PVar "val")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "matchLit") (EVar "arr")) (EVar "j")) (EVar "litArr")) (ELit (LInt 0))) (EVar "m")) (EApp (EVar "Ok") (ETuple (EVar "val") (EBinOp "+" (EVar "j") (EVar "m")))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "invalid literal, expected '")) (EVar "lit") (ELit (LString "'"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseArray" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "parseArray" ((PVar "arr") (PVar "i")) (EApp (EApp (EVar "parseArrayAt") (EVar "arr")) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EVar "i"))))
(DTypeSig false "parseArrayAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "parseArrayAt" ((PVar "arr") (PVar "j")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "j") (EApp (EVar "arrayLength") (EVar "arr"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "arr")) (ELit (LChar "]")))) (EApp (EVar "Ok") (ETuple (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EListLit))) (EBinOp "+" (EVar "j") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "parseElems") (EVar "arr")) (EVar "j")) (EListLit))) (ELam ((PTuple (PVar "xs") (PVar "k"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "xs")))) (EVar "k"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseElems" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Json")) (TyCon "Int")))))))
(DFunDef false "parseElems" ((PVar "arr") (PVar "i") (PVar "acc")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "parseValue") (EVar "arr")) (EVar "i"))) (ELam ((PTuple (PVar "v") (PVar "j"))) (EApp (EApp (EApp (EVar "parseElemsCont") (EVar "arr")) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EVar "j"))) (EBinOp "::" (EVar "v") (EVar "acc"))))))
(DTypeSig false "parseElemsCont" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Json")) (TyCon "Int")))))))
(DFunDef false "parseElemsCont" ((PVar "arr") (PVar "k") (PVar "acc")) (EIf (EBinOp ">=" (EVar "k") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated array"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr")) (ELit (LChar ","))) (EApp (EApp (EApp (EVar "parseElems") (EVar "arr")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr")) (ELit (LChar "]"))) (EApp (EVar "Ok") (ETuple (EVar "acc") (EBinOp "+" (EVar "k") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected ',' or ']' in array"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseObject" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "parseObject" ((PVar "arr") (PVar "i")) (EApp (EApp (EVar "parseObjectAt") (EVar "arr")) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EVar "i"))))
(DTypeSig false "parseObjectAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "parseObjectAt" ((PVar "arr") (PVar "j")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "j") (EApp (EVar "arrayLength") (EVar "arr"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "arr")) (ELit (LChar "}")))) (EApp (EVar "Ok") (ETuple (EApp (EVar "JObject") (EApp (EVar "arrayFromList") (EListLit))) (EBinOp "+" (EVar "j") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "parseMembers") (EVar "arr")) (EVar "j")) (EListLit))) (ELam ((PTuple (PVar "ms") (PVar "k"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "JObject") (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "ms")))) (EVar "k"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseMembers" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyCon "Int")))))))
(DFunDef false "parseMembers" ((PVar "arr") (PVar "i") (PVar "acc")) (EApp (EApp (EApp (EVar "parseMemberStart") (EVar "arr")) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EVar "i"))) (EVar "acc")))
(DTypeSig false "parseMemberStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyCon "Int")))))))
(DFunDef false "parseMemberStart" ((PVar "arr") (PVar "j") (PVar "acc")) (EIf (EBinOp ">=" (EVar "j") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated object"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EListLit))) (ELam ((PTuple (PVar "key") (PVar "k"))) (EApp (EApp (EApp (EApp (EVar "parseAfterKey") (EVar "arr")) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EVar "k"))) (EVar "key")) (EVar "acc")))) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected string key in object"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseAfterKey" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyCon "Int"))))))))
(DFunDef false "parseAfterKey" ((PVar "arr") (PVar "k") (PVar "key") (PVar "acc")) (EIf (EBinOp ">=" (EVar "k") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated object"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr")) (ELit (LChar ":"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "parseValue") (EVar "arr")) (EBinOp "+" (EVar "k") (ELit (LInt 1))))) (ELam ((PTuple (PVar "v") (PVar "m"))) (EApp (EApp (EApp (EVar "parseMemberCont") (EVar "arr")) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EVar "m"))) (EBinOp "::" (ETuple (EVar "key") (EVar "v")) (EVar "acc"))))) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected ':' after object key"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseMemberCont" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyCon "Int")))))))
(DFunDef false "parseMemberCont" ((PVar "arr") (PVar "m") (PVar "acc")) (EIf (EBinOp ">=" (EVar "m") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated object"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "m")) (EVar "arr")) (ELit (LChar ","))) (EApp (EApp (EApp (EVar "parseMembers") (EVar "arr")) (EBinOp "+" (EVar "m") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "m")) (EVar "arr")) (ELit (LChar "}"))) (EApp (EVar "Ok") (ETuple (EVar "acc") (EBinOp "+" (EVar "m") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected ',' or '}' in object"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseValue" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "parseValue" ((PVar "arr") (PVar "i")) (EApp (EApp (EVar "parseValueAt") (EVar "arr")) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EVar "i"))))
(DTypeSig false "parseValueAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "parseValueAt" ((PVar "arr") (PVar "j")) (EIf (EBinOp ">=" (EVar "j") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unexpected end of input"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "dispatchValue") (EVar "arr")) (EVar "j")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dispatchValue" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int")))))))
(DFunDef false "dispatchValue" ((PVar "arr") (PVar "j") (PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "{"))) (EApp (EApp (EVar "parseObject") (EVar "arr")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "["))) (EApp (EApp (EVar "parseArray") (EVar "arr")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EListLit))) (ELam ((PTuple (PVar "s") (PVar "k"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "JString") (EVar "s")) (EVar "k"))))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "t"))) (EApp (EApp (EApp (EApp (EVar "parseLit") (EVar "arr")) (EVar "j")) (ELit (LString "true"))) (EApp (EVar "JBool") (EVar "True"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "f"))) (EApp (EApp (EApp (EApp (EVar "parseLit") (EVar "arr")) (EVar "j")) (ELit (LString "false"))) (EApp (EVar "JBool") (EVar "False"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "n"))) (EApp (EApp (EApp (EApp (EVar "parseLit") (EVar "arr")) (EVar "j")) (ELit (LString "null"))) (EVar "JNull")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "-"))) (EApp (EApp (EVar "parseNumber") (EVar "arr")) (EVar "j")) (EIf (EApp (EVar "isDigit") (EVar "c")) (EApp (EApp (EVar "parseNumber") (EVar "arr")) (EVar "j")) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "unexpected character '")) (EApp (EVar "charToStr") (EVar "c")) (ELit (LString "'"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))
(DTypeSig true "parse" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Json"))))
(DFunDef false "parse" ((PVar "s")) (EApp (EVar "parseTop") (EApp (EVar "stringToChars") (EVar "s"))))
(DTypeSig false "parseTop" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Json"))))
(DFunDef false "parseTop" ((PVar "arr")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "parseValue") (EVar "arr")) (ELit (LInt 0)))) (ELam ((PTuple (PVar "v") (PVar "j"))) (EApp (EApp (EApp (EVar "ensureEnd") (EVar "arr")) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EVar "j"))) (EVar "v")))))
(DTypeSig false "ensureEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Json"))))))
(DFunDef false "ensureEnd" ((PVar "arr") (PVar "j") (PVar "v")) (EIf (EBinOp ">=" (EVar "j") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Ok") (EVar "v")) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "trailing characters after JSON value"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "lookup" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Json")))))
(DFunDef false "lookup" ((PVar "key") (PCon "JObject" (PVar "pairs"))) (EApp (EApp (EApp (EApp (EVar "lookupGo") (EVar "key")) (EVar "pairs")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "pairs"))))
(DFunDef false "lookup" (PWild PWild) (EVar "None"))
(DTypeSig false "lookupGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "String") (TyCon "Json"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Json")))))))
(DFunDef false "lookupGo" ((PVar "key") (PVar "pairs") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EBinOp "==" (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "pairs"))) (EVar "key")) (EApp (EVar "Some") (EApp (EVar "snd") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "pairs")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "lookupGo") (EVar "key")) (EVar "pairs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "at" (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Json")))))
(DFunDef false "at" ((PVar "k") (PCon "JArray" (PVar "arr"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "k") (ELit (LInt 0))) (EBinOp "<" (EVar "k") (EApp (EVar "arrayLength") (EVar "arr")))) (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "at" (PWild PWild) (EVar "None"))
(DTypeSig true "asString" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "asString" ((PCon "JString" (PVar "s"))) (EApp (EVar "Some") (EVar "s")))
(DFunDef false "asString" (PWild) (EVar "None"))
(DTypeSig true "asInt" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "asInt" ((PCon "JInt" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "asInt" (PWild) (EVar "None"))
(DTypeSig true "asFloat" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Float"))))
(DFunDef false "asFloat" ((PCon "JFloat" (PVar "f"))) (EApp (EVar "Some") (EVar "f")))
(DFunDef false "asFloat" (PWild) (EVar "None"))
(DTypeSig true "asBool" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Bool"))))
(DFunDef false "asBool" ((PCon "JBool" (PVar "b"))) (EApp (EVar "Some") (EVar "b")))
(DFunDef false "asBool" (PWild) (EVar "None"))
(DTypeSig true "asArray" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Json")))))
(DFunDef false "asArray" ((PCon "JArray" (PVar "a"))) (EApp (EVar "Some") (EVar "a")))
(DFunDef false "asArray" (PWild) (EVar "None"))
(DTypeSig false "arrEqJson" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "arrEqJson" ((PVar "a") (PVar "b") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "a"))) (EVar "True") (EIf (EVar "otherwise") (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "b"))) (EApp (EApp (EApp (EVar "arrEqJson") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "objEqJson" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "String") (TyCon "Json"))) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "String") (TyCon "Json"))) (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "objEqJson" ((PVar "a") (PVar "b") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "a"))) (EVar "True") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "pa") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (DoLet false false (PVar "pb") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "b"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "pa")) (EApp (EVar "fst") (EVar "pb"))) (EApp (EApp (EVar "eq") (EApp (EVar "snd") (EVar "pa"))) (EApp (EVar "snd") (EVar "pb")))) (EApp (EApp (EApp (EVar "objEqJson") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Eq" ((TyCon "Json")) () ((im "eq" ((PCon "JNull") (PCon "JNull")) (EVar "True")) (im "eq" ((PCon "JBool" (PVar "a")) (PCon "JBool" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b"))) (im "eq" ((PCon "JInt" (PVar "a")) (PCon "JInt" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b"))) (im "eq" ((PCon "JFloat" (PVar "a")) (PCon "JFloat" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b"))) (im "eq" ((PCon "JString" (PVar "a")) (PCon "JString" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b"))) (im "eq" ((PCon "JArray" (PVar "a")) (PCon "JArray" (PVar "b"))) (EBinOp "&&" (EBinOp "==" (EApp (EVar "arrayLength") (EVar "a")) (EApp (EVar "arrayLength") (EVar "b"))) (EApp (EApp (EApp (EVar "arrEqJson") (EVar "a")) (EVar "b")) (ELit (LInt 0))))) (im "eq" ((PCon "JObject" (PVar "a")) (PCon "JObject" (PVar "b"))) (EBinOp "&&" (EBinOp "==" (EApp (EVar "arrayLength") (EVar "a")) (EApp (EVar "arrayLength") (EVar "b"))) (EApp (EApp (EApp (EVar "objEqJson") (EVar "a")) (EVar "b")) (ELit (LInt 0))))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl true "Debug" ((TyCon "Json")) () ((im "debug" ((PVar "j")) (EApp (EVar "stringify") (EVar "j")))))
(DImpl true "Display" ((TyCon "Json")) () ((im "display" ((PVar "j")) (EApp (EVar "stringify") (EVar "j")))))
(DProp false "parse-then-stringify round-trips a JInt" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parse") (EApp (EVar "stringify") (EApp (EVar "JInt") (EVar "n")))) (EApp (EVar "Ok") (EApp (EVar "JInt") (EVar "n")))))
(DProp false "parse-then-stringify round-trips a JString (exercises escaping)" ((pp "s" (TyCon "String"))) (EBinOp "==" (EApp (EVar "parse") (EApp (EVar "stringify") (EApp (EVar "JString") (EVar "s")))) (EApp (EVar "Ok") (EApp (EVar "JString") (EVar "s")))))
(DProp false "parse-then-stringify round-trips a JBool" ((pp "b" (TyCon "Bool"))) (EBinOp "==" (EApp (EVar "parse") (EApp (EVar "stringify") (EApp (EVar "JBool") (EVar "b")))) (EApp (EVar "Ok") (EApp (EVar "JBool") (EVar "b")))))
(DProp false "parse-then-stringify round-trips an int JArray" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "j") (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JInt")) (EVar "xs")))) (DoExpr (EBinOp "==" (EApp (EVar "parse") (EApp (EVar "stringify") (EVar "j"))) (EApp (EVar "Ok") (EVar "j"))))))
(DProp false "parse-then-stringify round-trips a JObject" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "j") (EApp (EVar "jObject") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EApp (EVar "intToString") (EVar "n")) (EApp (EVar "JInt") (EVar "n"))))) (EVar "xs")))) (DoExpr (EBinOp "==" (EApp (EVar "parse") (EApp (EVar "stringify") (EVar "j"))) (EApp (EVar "Ok") (EVar "j"))))))
(DProp false "asInt (JInt n) == Some n" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "asInt") (EApp (EVar "JInt") (EVar "n"))) (EApp (EVar "Some") (EVar "n"))))
(DProp false "asString (JString s) == Some s" ((pp "s" (TyCon "String"))) (EBinOp "==" (EApp (EVar "asString") (EApp (EVar "JString") (EVar "s"))) (EApp (EVar "Some") (EVar "s"))))
(DProp false "asBool (JBool b) == Some b" ((pp "b" (TyCon "Bool"))) (EBinOp "==" (EApp (EVar "asBool") (EApp (EVar "JBool") (EVar "b"))) (EApp (EVar "Some") (EVar "b"))))
(DProp false "asFloat (JFloat f) == Some f" ((pp "f" (TyCon "Float"))) (EBinOp "==" (EApp (EVar "asFloat") (EApp (EVar "JFloat") (EVar "f"))) (EApp (EVar "Some") (EVar "f"))))
(DProp false "asArray recovers a built JArray" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EApp (EVar "map") (EVar "JInt")) (EVar "xs"))) (DoExpr (EBinOp "==" (EApp (EApp (EVar "map") (EVar "JArray")) (EApp (EVar "asArray") (EApp (EVar "jArray") (EVar "arr")))) (EApp (EVar "Some") (EApp (EVar "jArray") (EVar "arr")))))))
(DProp false "at k recovers the k-th element of a JArray" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "k") (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n"))) (DoExpr (EBinOp "==" (EApp (EApp (EVar "at") (EVar "k")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JInt")) (ERangeList (ELit (LInt 0)) (EVar "k") true)))) (EApp (EVar "Some") (EApp (EVar "JInt") (EVar "k")))))))
(DProp false "lookup finds an inserted key" ((pp "k" (TyCon "Int")) (pp "v" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "lookup") (EApp (EVar "intToString") (EVar "k"))) (EApp (EVar "jObject") (EListLit (ETuple (EApp (EVar "intToString") (EVar "k")) (EApp (EVar "JInt") (EVar "v")))))) (EApp (EVar "Some") (EApp (EVar "JInt") (EVar "v")))))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Debug" false) (mem "Display" false) (mem "Option" false) (mem "Result" false) (mem "Thenable" false) (mem "map" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseName ("array")))
(DUse false (UseGroup ("string") ((mem "join" false) (mem "fromChars" false) (mem "isDigit" false) (mem "toInt" false))))
(DData Public "Json" () ((variant "JNull" (ConPos)) (variant "JBool" (ConPos (TyCon "Bool"))) (variant "JInt" (ConPos (TyCon "Int"))) (variant "JFloat" (ConPos (TyCon "Float"))) (variant "JString" (ConPos (TyCon "String"))) (variant "JArray" (ConPos (TyApp (TyCon "Array") (TyCon "Json")))) (variant "JObject" (ConPos (TyApp (TyCon "Array") (TyTuple (TyCon "String") (TyCon "Json")))))) ())
(DTypeSig true "jArray" (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyCon "Json")))
(DFunDef false "jArray" ((PVar "xs")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EVar "xs"))))
(DTypeSig true "jObject" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyCon "Json")))
(DFunDef false "jObject" ((PVar "xs")) (EApp (EVar "JObject") (EApp (EVar "arrayFromList") (EVar "xs"))))
(DTypeSig false "charOfCode" (TyFun (TyCon "Int") (TyCon "Char")))
(DFunDef false "charOfCode" ((PVar "k")) (EMatch (EApp (EVar "charFromCode") (EVar "k")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (ELit (LChar " ")))))
(DTypeSig false "renderFloat" (TyFun (TyCon "Float") (TyCon "String")))
(DFunDef false "renderFloat" ((PVar "f")) (EApp (EVar "fixTrailingDot") (EApp (EVar "floatToString") (EVar "f"))))
(DTypeSig false "fixTrailingDot" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "fixTrailingDot" ((PVar "s")) (EApp (EApp (EVar "fixTrailingDotGo") (EVar "s")) (EApp (EVar "stringToChars") (EVar "s"))))
(DTypeSig false "fixTrailingDotGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "String"))))
(DFunDef false "fixTrailingDotGo" ((PVar "s") (PVar "arr")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 0))) (EBinOp "==" (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "arr"))) (ELit (LInt 46)))) (EApp (EVar "stringConcat") (EListLit (EVar "s") (ELit (LString "0")))) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hexDigit" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "hexDigit" ((PVar "d")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "d")) (EBinOp "+" (EVar "d") (ELit (LInt 1)))) (ELit (LString "0123456789abcdef"))))
(DTypeSig false "unicodeEscape" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "unicodeEscape" ((PVar "code")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "\\u00")) (EApp (EVar "hexDigit") (EBinOp "/" (EVar "code") (ELit (LInt 16)))) (EApp (EVar "hexDigit") (EBinOp "%" (EVar "code") (ELit (LInt 16)))))))
(DTypeSig false "escapeChar" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "escapeChar" ((PVar "c")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 34))) (ELit (LString "\\\"")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 92))) (ELit (LString "\\\\")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 8))) (ELit (LString "\\b")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 9))) (ELit (LString "\\t")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 10))) (ELit (LString "\\n")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 12))) (ELit (LString "\\f")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 13))) (ELit (LString "\\r")) (EIf (EBinOp "<" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 32))) (EApp (EVar "unicodeEscape") (EApp (EVar "charCode") (EVar "c"))) (EIf (EVar "otherwise") (EApp (EVar "charToStr") (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))
(DTypeSig false "escapeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "escapeGo" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "escapeGo") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "escapeChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "escapeString" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escapeString" ((PVar "s")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "pieces") (EApp (EApp (EApp (EVar "escapeGo") (EVar "arr")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EListLit))) (DoExpr (EApp (EVar "stringConcat") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "\""))) (EVar "pieces")) (EListLit (ELit (LString "\""))))))))
(DTypeSig false "elemStrings" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "elemStrings" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "elemStrings") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "stringify") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "memberStrings" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "String") (TyCon "Json"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "memberStrings" ((PVar "pairs") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "p") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "pairs"))) (DoLet false false (PVar "s") (EApp (EVar "stringConcat") (EListLit (EApp (EVar "escapeString") (EApp (EVar "fst") (EVar "p"))) (ELit (LString ":")) (EApp (EVar "stringify") (EApp (EVar "snd") (EVar "p")))))) (DoExpr (EApp (EApp (EApp (EVar "memberStrings") (EVar "pairs")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "s") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "stringify" (TyFun (TyCon "Json") (TyCon "String")))
(DFunDef false "stringify" ((PCon "JNull")) (ELit (LString "null")))
(DFunDef false "stringify" ((PCon "JBool" (PCon "True"))) (ELit (LString "true")))
(DFunDef false "stringify" ((PCon "JBool" (PCon "False"))) (ELit (LString "false")))
(DFunDef false "stringify" ((PCon "JInt" (PVar "n"))) (EApp (EVar "intToString") (EVar "n")))
(DFunDef false "stringify" ((PCon "JFloat" (PVar "f"))) (EApp (EVar "renderFloat") (EVar "f")))
(DFunDef false "stringify" ((PCon "JString" (PVar "s"))) (EApp (EVar "escapeString") (EVar "s")))
(DFunDef false "stringify" ((PCon "JArray" (PVar "arr"))) (EBlock (DoLet false false (PVar "body") (EApp (EApp (EVar "join") (ELit (LString ","))) (EApp (EApp (EApp (EVar "elemStrings") (EVar "arr")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EListLit)))) (DoExpr (EApp (EVar "stringConcat") (EListLit (ELit (LString "[")) (EVar "body") (ELit (LString "]")))))))
(DFunDef false "stringify" ((PCon "JObject" (PVar "pairs"))) (EBlock (DoLet false false (PVar "body") (EApp (EApp (EVar "join") (ELit (LString ","))) (EApp (EApp (EApp (EVar "memberStrings") (EVar "pairs")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "pairs")) (ELit (LInt 1)))) (EListLit)))) (DoExpr (EApp (EVar "stringConcat") (EListLit (ELit (LString "{")) (EVar "body") (ELit (LString "}")))))))
(DTypeSig false "isWs" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isWs" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 32))) (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 9)))) (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 10)))) (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 13)))))
(DTypeSig false "skipWs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "skipWs" ((PVar "arr") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "isWs") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "parseStr" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated string"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "parseStrChar") (EVar "arr")) (EVar "i")) (EVar "acc")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseStrChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Char") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "parseStrChar" ((PVar "arr") (PVar "i") (PVar "acc") (PVar "c")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 34))) (EApp (EVar "Ok") (ETuple (EApp (EVar "fromChars") (EApp (EVar "reverse") (EVar "acc"))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 92))) (EApp (EApp (EApp (EVar "parseEsc") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "c") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseEsc" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "parseEsc" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated escape"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "parseEscChar") (EVar "arr")) (EVar "i")) (EVar "acc")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseEscChar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Char") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "parseEscChar" ((PVar "arr") (PVar "i") (PVar "acc") (PVar "c")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 34))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "c") (EVar "acc"))) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 92))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "c") (EVar "acc"))) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 47))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "c") (EVar "acc"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "n"))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "charOfCode") (ELit (LInt 10))) (EVar "acc"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "t"))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "charOfCode") (ELit (LInt 9))) (EVar "acc"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "r"))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "charOfCode") (ELit (LInt 13))) (EVar "acc"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "b"))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "charOfCode") (ELit (LInt 8))) (EVar "acc"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "f"))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "charOfCode") (ELit (LInt 12))) (EVar "acc"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "u"))) (EApp (EApp (EApp (EVar "parseUnicode") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "invalid escape sequence"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))))
(DTypeSig false "hexVal" (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "hexVal" ((PVar "c")) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48))) (EBinOp "<=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 57)))) (EApp (EVar "Some") (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48)))) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 97))) (EBinOp "<=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 102)))) (EApp (EVar "Some") (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 87)))) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 65))) (EBinOp "<=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 70)))) (EApp (EVar "Some") (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 55)))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "hex4" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "hex4" ((PVar "arr") (PVar "i")) (EMatch (EApp (EVar "hexVal") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "h0")) () (EApp (EApp (EApp (EVar "hex4From") (EVar "arr")) (EVar "i")) (EVar "h0")))))
(DTypeSig false "hex4From" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "hex4From" ((PVar "arr") (PVar "i") (PVar "h0")) (EMatch (EApp (EVar "hexVal") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "h1")) () (EApp (EApp (EApp (EVar "hex4From2") (EVar "arr")) (EVar "i")) (EBinOp "+" (EBinOp "*" (EVar "h0") (ELit (LInt 16))) (EVar "h1"))))))
(DTypeSig false "hex4From2" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "hex4From2" ((PVar "arr") (PVar "i") (PVar "acc")) (EMatch (EApp (EVar "hexVal") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "arr"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "h2")) () (EApp (EApp (EApp (EVar "hex4From3") (EVar "arr")) (EVar "i")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 16))) (EVar "h2"))))))
(DTypeSig false "hex4From3" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "hex4From3" ((PVar "arr") (PVar "i") (PVar "acc")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 16))) (EVar "_s")))) (EApp (EVar "hexVal") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 3)))) (EVar "arr")))))
(DTypeSig false "parseUnicode" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "parseUnicode" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">" (EBinOp "+" (EVar "i") (ELit (LInt 4))) (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "invalid \\u escape"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "parseUnicodeAt") (EVar "arr")) (EVar "i")) (EVar "acc")) (EApp (EApp (EVar "hex4") (EVar "arr")) (EVar "i"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseUnicodeAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "parseUnicodeAt" ((PVar "arr") (PVar "i") (PVar "acc") (PCon "None")) (EApp (EVar "Err") (ELit (LString "invalid \\u escape"))))
(DFunDef false "parseUnicodeAt" ((PVar "arr") (PVar "i") (PVar "acc") (PCon "Some" (PVar "k"))) (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 4)))) (EBinOp "::" (EApp (EVar "charOfCode") (EVar "k")) (EVar "acc"))))
(DTypeSig false "skipSign" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "skipSign" ((PVar "arr") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "-")))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "skipDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "skipDigits" ((PVar "arr") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "isDigit") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (EApp (EApp (EVar "skipDigits") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "skipFrac" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "skipFrac" ((PVar "arr") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar ".")))) (ETuple (EApp (EApp (EVar "skipDigits") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "True")) (EIf (EVar "otherwise") (ETuple (EVar "i") (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "skipExp" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "skipExp" ((PVar "arr") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "isExpChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (ETuple (EApp (EApp (EVar "skipDigits") (EVar "arr")) (EApp (EApp (EVar "skipSign") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EVar "True")) (EIf (EVar "otherwise") (ETuple (EVar "i") (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isExpChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isExpChar" ((PVar "c")) (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "e"))) (EBinOp "==" (EVar "c") (ELit (LChar "E")))))
(DTypeSig false "subString" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "subString" ((PVar "arr") (PVar "start") (PVar "end")) (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "end") (EVar "start"))) (ELam ((PVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "start") (EVar "k"))) (EVar "arr"))))))
(DTypeSig false "parseNumber" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "parseNumber" ((PVar "arr") (PVar "start")) (EBlock (DoLet false false (PVar "afterSign") (EApp (EApp (EVar "skipSign") (EVar "arr")) (EVar "start"))) (DoLet false false (PVar "afterInt") (EApp (EApp (EVar "skipDigits") (EVar "arr")) (EVar "afterSign"))) (DoLet false false (PVar "fracR") (EApp (EApp (EVar "skipFrac") (EVar "arr")) (EVar "afterInt"))) (DoLet false false (PVar "expR") (EApp (EApp (EVar "skipExp") (EVar "arr")) (EApp (EVar "fst") (EVar "fracR")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "finishNumber") (EVar "arr")) (EVar "start")) (EVar "afterSign")) (EVar "afterInt")) (EApp (EVar "fst") (EVar "expR"))) (EBinOp "||" (EApp (EVar "snd") (EVar "fracR")) (EApp (EVar "snd") (EVar "expR")))))))
(DTypeSig false "finishNumber" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))))))
(DFunDef false "finishNumber" ((PVar "arr") (PVar "start") (PVar "afterSign") (PVar "afterInt") (PVar "end") (PVar "isFloat")) (EIf (EBinOp "==" (EVar "afterInt") (EVar "afterSign")) (EApp (EVar "Err") (ELit (LString "invalid number: no digits"))) (EIf (EVar "isFloat") (EApp (EApp (EVar "finishFloat") (EApp (EApp (EApp (EVar "subString") (EVar "arr")) (EVar "start")) (EVar "end"))) (EVar "end")) (EIf (EVar "otherwise") (EApp (EApp (EVar "finishInt") (EApp (EApp (EApp (EVar "subString") (EVar "arr")) (EVar "start")) (EVar "end"))) (EVar "end")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "finishInt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "finishInt" ((PVar "tok") (PVar "end")) (EMatch (EApp (EVar "toInt") (EVar "tok")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (ETuple (EApp (EVar "JInt") (EVar "n")) (EVar "end")))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "invalid number"))))))
(DTypeSig false "finishFloat" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "finishFloat" ((PVar "tok") (PVar "end")) (EMatch (EApp (EVar "stringToFloat") (EVar "tok")) (arm (PCon "Some" (PVar "f")) () (EApp (EVar "Ok") (ETuple (EApp (EVar "JFloat") (EVar "f")) (EVar "end")))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "invalid number"))))))
(DTypeSig false "matchLit" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "matchLit" ((PVar "arr") (PVar "j") (PVar "litArr") (PVar "k") (PVar "m")) (EIf (EBinOp ">=" (EVar "k") (EVar "m")) (EVar "True") (EIf (EBinOp ">=" (EBinOp "+" (EVar "j") (EVar "k")) (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "j") (EVar "k"))) (EVar "arr")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "litArr"))) (EApp (EApp (EApp (EApp (EApp (EVar "matchLit") (EVar "arr")) (EVar "j")) (EVar "litArr")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "m")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseLit" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))))
(DFunDef false "parseLit" ((PVar "arr") (PVar "j") (PVar "lit") (PVar "val")) (EBlock (DoLet false false (PVar "litArr") (EApp (EVar "stringToChars") (EVar "lit"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseLitGo") (EVar "arr")) (EVar "j")) (EVar "litArr")) (EApp (EVar "arrayLength") (EVar "litArr"))) (EVar "lit")) (EVar "val")))))
(DTypeSig false "parseLitGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))))))
(DFunDef false "parseLitGo" ((PVar "arr") (PVar "j") (PVar "litArr") (PVar "m") (PVar "lit") (PVar "val")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "matchLit") (EVar "arr")) (EVar "j")) (EVar "litArr")) (ELit (LInt 0))) (EVar "m")) (EApp (EVar "Ok") (ETuple (EVar "val") (EBinOp "+" (EVar "j") (EVar "m")))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "invalid literal, expected '")) (EVar "lit") (ELit (LString "'"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseArray" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "parseArray" ((PVar "arr") (PVar "i")) (EApp (EApp (EVar "parseArrayAt") (EVar "arr")) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EVar "i"))))
(DTypeSig false "parseArrayAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "parseArrayAt" ((PVar "arr") (PVar "j")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "j") (EApp (EVar "arrayLength") (EVar "arr"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "arr")) (ELit (LChar "]")))) (EApp (EVar "Ok") (ETuple (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EListLit))) (EBinOp "+" (EVar "j") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "parseElems") (EVar "arr")) (EVar "j")) (EListLit))) (ELam ((PTuple (PVar "xs") (PVar "k"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "xs")))) (EVar "k"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseElems" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Json")) (TyCon "Int")))))))
(DFunDef false "parseElems" ((PVar "arr") (PVar "i") (PVar "acc")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "parseValue") (EVar "arr")) (EVar "i"))) (ELam ((PTuple (PVar "v") (PVar "j"))) (EApp (EApp (EApp (EVar "parseElemsCont") (EVar "arr")) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EVar "j"))) (EBinOp "::" (EVar "v") (EVar "acc"))))))
(DTypeSig false "parseElemsCont" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Json")) (TyCon "Int")))))))
(DFunDef false "parseElemsCont" ((PVar "arr") (PVar "k") (PVar "acc")) (EIf (EBinOp ">=" (EVar "k") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated array"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr")) (ELit (LChar ","))) (EApp (EApp (EApp (EVar "parseElems") (EVar "arr")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr")) (ELit (LChar "]"))) (EApp (EVar "Ok") (ETuple (EVar "acc") (EBinOp "+" (EVar "k") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected ',' or ']' in array"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseObject" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "parseObject" ((PVar "arr") (PVar "i")) (EApp (EApp (EVar "parseObjectAt") (EVar "arr")) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EVar "i"))))
(DTypeSig false "parseObjectAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "parseObjectAt" ((PVar "arr") (PVar "j")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "j") (EApp (EVar "arrayLength") (EVar "arr"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "arr")) (ELit (LChar "}")))) (EApp (EVar "Ok") (ETuple (EApp (EVar "JObject") (EApp (EVar "arrayFromList") (EListLit))) (EBinOp "+" (EVar "j") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "parseMembers") (EVar "arr")) (EVar "j")) (EListLit))) (ELam ((PTuple (PVar "ms") (PVar "k"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "JObject") (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "ms")))) (EVar "k"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseMembers" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyCon "Int")))))))
(DFunDef false "parseMembers" ((PVar "arr") (PVar "i") (PVar "acc")) (EApp (EApp (EApp (EVar "parseMemberStart") (EVar "arr")) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EVar "i"))) (EVar "acc")))
(DTypeSig false "parseMemberStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyCon "Int")))))))
(DFunDef false "parseMemberStart" ((PVar "arr") (PVar "j") (PVar "acc")) (EIf (EBinOp ">=" (EVar "j") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated object"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EListLit))) (ELam ((PTuple (PVar "key") (PVar "k"))) (EApp (EApp (EApp (EApp (EVar "parseAfterKey") (EVar "arr")) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EVar "k"))) (EVar "key")) (EVar "acc")))) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected string key in object"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseAfterKey" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyCon "Int"))))))))
(DFunDef false "parseAfterKey" ((PVar "arr") (PVar "k") (PVar "key") (PVar "acc")) (EIf (EBinOp ">=" (EVar "k") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated object"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr")) (ELit (LChar ":"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "parseValue") (EVar "arr")) (EBinOp "+" (EVar "k") (ELit (LInt 1))))) (ELam ((PTuple (PVar "v") (PVar "m"))) (EApp (EApp (EApp (EVar "parseMemberCont") (EVar "arr")) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EVar "m"))) (EBinOp "::" (ETuple (EVar "key") (EVar "v")) (EVar "acc"))))) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected ':' after object key"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseMemberCont" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))) (TyCon "Int")))))))
(DFunDef false "parseMemberCont" ((PVar "arr") (PVar "m") (PVar "acc")) (EIf (EBinOp ">=" (EVar "m") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated object"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "m")) (EVar "arr")) (ELit (LChar ","))) (EApp (EApp (EApp (EVar "parseMembers") (EVar "arr")) (EBinOp "+" (EVar "m") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "m")) (EVar "arr")) (ELit (LChar "}"))) (EApp (EVar "Ok") (ETuple (EVar "acc") (EBinOp "+" (EVar "m") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected ',' or '}' in object"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseValue" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "parseValue" ((PVar "arr") (PVar "i")) (EApp (EApp (EVar "parseValueAt") (EVar "arr")) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EVar "i"))))
(DTypeSig false "parseValueAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int"))))))
(DFunDef false "parseValueAt" ((PVar "arr") (PVar "j")) (EIf (EBinOp ">=" (EVar "j") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unexpected end of input"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "dispatchValue") (EVar "arr")) (EVar "j")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dispatchValue" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Json") (TyCon "Int")))))))
(DFunDef false "dispatchValue" ((PVar "arr") (PVar "j") (PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "{"))) (EApp (EApp (EVar "parseObject") (EVar "arr")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "["))) (EApp (EApp (EVar "parseArray") (EVar "arr")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "parseStr") (EVar "arr")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EListLit))) (ELam ((PTuple (PVar "s") (PVar "k"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "JString") (EVar "s")) (EVar "k"))))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "t"))) (EApp (EApp (EApp (EApp (EVar "parseLit") (EVar "arr")) (EVar "j")) (ELit (LString "true"))) (EApp (EVar "JBool") (EVar "True"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "f"))) (EApp (EApp (EApp (EApp (EVar "parseLit") (EVar "arr")) (EVar "j")) (ELit (LString "false"))) (EApp (EVar "JBool") (EVar "False"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "n"))) (EApp (EApp (EApp (EApp (EVar "parseLit") (EVar "arr")) (EVar "j")) (ELit (LString "null"))) (EVar "JNull")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "-"))) (EApp (EApp (EVar "parseNumber") (EVar "arr")) (EVar "j")) (EIf (EApp (EVar "isDigit") (EVar "c")) (EApp (EApp (EVar "parseNumber") (EVar "arr")) (EVar "j")) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "unexpected character '")) (EApp (EVar "charToStr") (EVar "c")) (ELit (LString "'"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))
(DTypeSig true "parse" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Json"))))
(DFunDef false "parse" ((PVar "s")) (EApp (EVar "parseTop") (EApp (EVar "stringToChars") (EVar "s"))))
(DTypeSig false "parseTop" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Json"))))
(DFunDef false "parseTop" ((PVar "arr")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "parseValue") (EVar "arr")) (ELit (LInt 0)))) (ELam ((PTuple (PVar "v") (PVar "j"))) (EApp (EApp (EApp (EVar "ensureEnd") (EVar "arr")) (EApp (EApp (EVar "skipWs") (EVar "arr")) (EVar "j"))) (EVar "v")))))
(DTypeSig false "ensureEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Json"))))))
(DFunDef false "ensureEnd" ((PVar "arr") (PVar "j") (PVar "v")) (EIf (EBinOp ">=" (EVar "j") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Ok") (EVar "v")) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "trailing characters after JSON value"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "lookup" (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Json")))))
(DFunDef false "lookup" ((PVar "key") (PCon "JObject" (PVar "pairs"))) (EApp (EApp (EApp (EApp (EVar "lookupGo") (EVar "key")) (EVar "pairs")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "pairs"))))
(DFunDef false "lookup" (PWild PWild) (EVar "None"))
(DTypeSig false "lookupGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "String") (TyCon "Json"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Json")))))))
(DFunDef false "lookupGo" ((PVar "key") (PVar "pairs") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EBinOp "==" (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "pairs"))) (EVar "key")) (EApp (EVar "Some") (EApp (EVar "snd") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "pairs")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "lookupGo") (EVar "key")) (EVar "pairs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "at" (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Json")))))
(DFunDef false "at" ((PVar "k") (PCon "JArray" (PVar "arr"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "k") (ELit (LInt 0))) (EBinOp "<" (EVar "k") (EApp (EVar "arrayLength") (EVar "arr")))) (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "at" (PWild PWild) (EVar "None"))
(DTypeSig true "asString" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "asString" ((PCon "JString" (PVar "s"))) (EApp (EVar "Some") (EVar "s")))
(DFunDef false "asString" (PWild) (EVar "None"))
(DTypeSig true "asInt" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "asInt" ((PCon "JInt" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "asInt" (PWild) (EVar "None"))
(DTypeSig true "asFloat" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Float"))))
(DFunDef false "asFloat" ((PCon "JFloat" (PVar "f"))) (EApp (EVar "Some") (EVar "f")))
(DFunDef false "asFloat" (PWild) (EVar "None"))
(DTypeSig true "asBool" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Bool"))))
(DFunDef false "asBool" ((PCon "JBool" (PVar "b"))) (EApp (EVar "Some") (EVar "b")))
(DFunDef false "asBool" (PWild) (EVar "None"))
(DTypeSig true "asArray" (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Json")))))
(DFunDef false "asArray" ((PCon "JArray" (PVar "a"))) (EApp (EVar "Some") (EVar "a")))
(DFunDef false "asArray" (PWild) (EVar "None"))
(DTypeSig false "arrEqJson" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "arrEqJson" ((PVar "a") (PVar "b") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "a"))) (EVar "True") (EIf (EVar "otherwise") (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "b"))) (EApp (EApp (EApp (EVar "arrEqJson") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "objEqJson" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "String") (TyCon "Json"))) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "String") (TyCon "Json"))) (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "objEqJson" ((PVar "a") (PVar "b") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "a"))) (EVar "True") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "pa") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (DoLet false false (PVar "pb") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "b"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "pa")) (EApp (EVar "fst") (EVar "pb"))) (EApp (EApp (EMethodRef "eq") (EApp (EVar "snd") (EVar "pa"))) (EApp (EVar "snd") (EVar "pb")))) (EApp (EApp (EApp (EVar "objEqJson") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Eq" ((TyCon "Json")) () ((im "eq" ((PCon "JNull") (PCon "JNull")) (EVar "True")) (im "eq" ((PCon "JBool" (PVar "a")) (PCon "JBool" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b"))) (im "eq" ((PCon "JInt" (PVar "a")) (PCon "JInt" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b"))) (im "eq" ((PCon "JFloat" (PVar "a")) (PCon "JFloat" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b"))) (im "eq" ((PCon "JString" (PVar "a")) (PCon "JString" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b"))) (im "eq" ((PCon "JArray" (PVar "a")) (PCon "JArray" (PVar "b"))) (EBinOp "&&" (EBinOp "==" (EApp (EVar "arrayLength") (EVar "a")) (EApp (EVar "arrayLength") (EVar "b"))) (EApp (EApp (EApp (EVar "arrEqJson") (EVar "a")) (EVar "b")) (ELit (LInt 0))))) (im "eq" ((PCon "JObject" (PVar "a")) (PCon "JObject" (PVar "b"))) (EBinOp "&&" (EBinOp "==" (EApp (EVar "arrayLength") (EVar "a")) (EApp (EVar "arrayLength") (EVar "b"))) (EApp (EApp (EApp (EVar "objEqJson") (EVar "a")) (EVar "b")) (ELit (LInt 0))))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl true "Debug" ((TyCon "Json")) () ((im "debug" ((PVar "j")) (EApp (EVar "stringify") (EVar "j")))))
(DImpl true "Display" ((TyCon "Json")) () ((im "display" ((PVar "j")) (EApp (EVar "stringify") (EVar "j")))))
(DProp false "parse-then-stringify round-trips a JInt" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parse") (EApp (EVar "stringify") (EApp (EVar "JInt") (EVar "n")))) (EApp (EVar "Ok") (EApp (EVar "JInt") (EVar "n")))))
(DProp false "parse-then-stringify round-trips a JString (exercises escaping)" ((pp "s" (TyCon "String"))) (EBinOp "==" (EApp (EVar "parse") (EApp (EVar "stringify") (EApp (EVar "JString") (EVar "s")))) (EApp (EVar "Ok") (EApp (EVar "JString") (EVar "s")))))
(DProp false "parse-then-stringify round-trips a JBool" ((pp "b" (TyCon "Bool"))) (EBinOp "==" (EApp (EVar "parse") (EApp (EVar "stringify") (EApp (EVar "JBool") (EVar "b")))) (EApp (EVar "Ok") (EApp (EVar "JBool") (EVar "b")))))
(DProp false "parse-then-stringify round-trips an int JArray" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "j") (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JInt")) (EVar "xs")))) (DoExpr (EBinOp "==" (EApp (EVar "parse") (EApp (EVar "stringify") (EVar "j"))) (EApp (EVar "Ok") (EVar "j"))))))
(DProp false "parse-then-stringify round-trips a JObject" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "j") (EApp (EVar "jObject") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EApp (EVar "intToString") (EVar "n")) (EApp (EVar "JInt") (EVar "n"))))) (EVar "xs")))) (DoExpr (EBinOp "==" (EApp (EVar "parse") (EApp (EVar "stringify") (EVar "j"))) (EApp (EVar "Ok") (EVar "j"))))))
(DProp false "asInt (JInt n) == Some n" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "asInt") (EApp (EVar "JInt") (EVar "n"))) (EApp (EVar "Some") (EVar "n"))))
(DProp false "asString (JString s) == Some s" ((pp "s" (TyCon "String"))) (EBinOp "==" (EApp (EVar "asString") (EApp (EVar "JString") (EVar "s"))) (EApp (EVar "Some") (EVar "s"))))
(DProp false "asBool (JBool b) == Some b" ((pp "b" (TyCon "Bool"))) (EBinOp "==" (EApp (EVar "asBool") (EApp (EVar "JBool") (EVar "b"))) (EApp (EVar "Some") (EVar "b"))))
(DProp false "asFloat (JFloat f) == Some f" ((pp "f" (TyCon "Float"))) (EBinOp "==" (EApp (EVar "asFloat") (EApp (EVar "JFloat") (EVar "f"))) (EApp (EVar "Some") (EVar "f"))))
(DProp false "asArray recovers a built JArray" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EApp (EMethodRef "map") (EVar "JInt")) (EVar "xs"))) (DoExpr (EBinOp "==" (EApp (EApp (EMethodRef "map") (EVar "JArray")) (EApp (EVar "asArray") (EApp (EVar "jArray") (EVar "arr")))) (EApp (EVar "Some") (EApp (EVar "jArray") (EVar "arr")))))))
(DProp false "at k recovers the k-th element of a JArray" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "k") (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n"))) (DoExpr (EBinOp "==" (EApp (EApp (EVar "at") (EVar "k")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JInt")) (ERangeList (ELit (LInt 0)) (EVar "k") true)))) (EApp (EVar "Some") (EApp (EVar "JInt") (EVar "k")))))))
(DProp false "lookup finds an inserted key" ((pp "k" (TyCon "Int")) (pp "v" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "lookup") (EApp (EVar "intToString") (EVar "k"))) (EApp (EVar "jObject") (EListLit (ETuple (EApp (EVar "intToString") (EVar "k")) (EApp (EVar "JInt") (EVar "v")))))) (EApp (EVar "Some") (EApp (EVar "JInt") (EVar "v")))))
