# META
source_lines=663
stages=DESUGAR,MARK
# SOURCE
-- string.mdk — operations on String and Char
-- See STDLIB.md (Module 3) for the full implementation plan.
--
-- Design notes
-- ────────────
-- String is an immutable sequence of Unicode codepoints (scalar values),
-- UTF-8 backed; Char is one codepoint.  This module is a thin Medaka layer
-- over the kernel externs in stdlib/runtime.mdk.
--
-- Performance posture (Medaka is a *practical* functional language): under the
-- hood we favour what the machine likes — contiguous `Array Char` with O(1)
-- indexing and the direct string externs (`stringSlice`/`stringConcat`/
-- `stringCompare`/`stringLength`) — over a `List Char` of cons cells.  Three
-- tiers, fastest first:
--   1. operate on the String directly (no char materialization): `take`/`drop`/
--      `sliceClamped`, `startsWith`/`endsWith` (slice + `==`), `concat`/`join`/`repeat`,
--      and substring search via the host `stringIndexOf` — `indexOf`, and
--      `contains`/`split`/`replace*` derived from it;
--   2. decode once to `Array Char`, scan by index, rebuild via `stringFromChars`
--      or carve out `stringSlice`s: `trim*`, `words`, `reverse`, `capitalize`,
--      `toInt`;
--   3. `List Char` is avoided internally.
-- The user-facing signatures stay conventional; the array/index machinery is an
-- implementation detail.
--
-- Naming choices (this file holds *both* Char and String utilities, so some
-- short names would collide):
--   • `toUpper`/`toLower` here are the *String* versions — ASCII-only
--     byte-wise case mapping (issue #417): "Straße" → "STRAßE", not
--     "STRASSE".  For a single Char, call the kernel externs
--     `charToUpper`/`charToLower` (Char → Char, also ASCII-only — identity on
--     any non-ASCII codepoint).
--   • `length`/`isEmpty` are *not* defined: they'd clash with the `Foldable`
--     methods of the same name.  Use the global `stringLength`, or `s == ""`.
--   • Integer rendering is the global `intToString` (clashes with `Num.fromInt`
--     otherwise); `toInt`/`toFloat` parse, `stringToFloat` is the float extern.
--
-- Containers: the collection functions (`split`/`words`/`lines`/`concat`/
-- `join`/`unlines`/`unwords`) are `List`-typed — the conventional, pattern-
-- matchable form.  `toChars` is the one `Array` function (element decomposition,
-- where indexing/perf matter).  No List/Array duals: `List → Array` is the
-- global `arrayFromList` (no import) and `Array → List` is `Array.toList`, so a
-- caller who prefers the other container converts in one call rather than us
-- doubling the API surface.

import core.{Eq, Ord, Debug, Foldable, Mappable, Option, Ordering}

-- ── Rendering ─────────────────────────────────────────────────────────────
-- `Debug String` and `Debug Char` now live in the core prelude (`core.mdk`)
-- alongside the other primitive `Debug` impls, so `debug`-ing a String/Char
-- resolves without importing `string` (Phase 92).  Both render a quoted,
-- escaped, round-trippable literal — `debug "hi"` is `"hi"`, `debug 'a'` is `'a'`
-- — distinct from `println`, which emits the raw characters.

-- ── Char operations ─────────────────────────────────────────────────────────
-- ASCII-exact predicates (isDigit/digitToInt/intToDigit) compute on the
-- codepoint directly; the classification wrappers below (isAlpha/isSpace/…)
-- wrap ASCII-only kernel externs (issue #417 — no Unicode tables exist).

{- | True for the ASCII decimal digits `'0'`..`'9'`.

   > isDigit '7'
   True
   > isDigit 'x'
   False -}
export isDigit : Char -> Bool
isDigit c = charCode c >= 48 && charCode c <= 57

-- | True for any Unicode letter.
export isAlpha : Char -> Bool
isAlpha c = charIsAlpha c

-- | True for a Unicode letter or an ASCII digit.
export isAlphaNum : Char -> Bool
isAlphaNum c = charIsAlpha c || isDigit c

-- | True for any Unicode whitespace.
export isSpace : Char -> Bool
isSpace c = charIsSpace c

-- | True for an uppercase letter.
export isUpper : Char -> Bool
isUpper c = charIsUpper c

-- | True for a lowercase letter.
export isLower : Char -> Bool
isLower c = charIsLower c

-- | True for a Unicode punctuation character.
export isPunct : Char -> Bool
isPunct c = charIsPunct c

{- | `'0'`..`'9'` → `Some 0`..`Some 9`, `'a'`..`'f'`/`'A'`..`'F'` →
   `Some 10`..`Some 15`, anything else `None`.

   > digitToInt '7'
   Some 7
   > digitToInt 'f'
   Some 15
   > digitToInt 'z'
   None -}
export digitToInt : Char -> Option Int
digitToInt c = digitVal (charCode c)

digitVal : Int -> Option Int
digitVal n
  | n >= 48 && n <= 57 = Some (n - 48)
  | n >= 97 && n <= 102 = Some (n - 87)
  | n >= 65 && n <= 70 = Some (n - 55)
  | otherwise = None

{- | Inverse of `digitToInt` for `0`..`15` (lowercase hex); `None` otherwise.

   > intToDigit 7
   Some '7'
   > intToDigit 12
   Some 'c'
   > intToDigit 42
   None -}
export intToDigit : Int -> Option Char
intToDigit n
  | n >= 0 && n <= 9 = charFromCode (n + 48)
  | n >= 10 && n <= 15 = charFromCode (n + 87)
  | otherwise = None

-- ── Conversion ──────────────────────────────────────────────────────────────

-- | A one-character string.
export fromChar : Char -> String
fromChar c = charToStr c

{- | The codepoints of a string as an array (not grapheme clusters).  Returns
   the native `Array Char` — call `Array.toList` if you want a `List Char`, so
   the list conversion is opt-in rather than forced.

   > arrayLength (toChars "héllo→")
   6 -}
export toChars : String -> Array Char
toChars s = stringToChars s

{- | Build a string from a `List Char`.  For an `Array Char` (e.g. the result
   of `toChars`), use the kernel `stringFromChars` directly.

   > fromChars ['h', 'i']
   "hi" -}
export fromChars : List Char -> String
fromChars cs = stringFromChars (arrayFromList cs)

{- | The raw UTF-8 bytes of a string as an `Array Int` (each 0..255), in order.
   This is the encoded byte stream, NOT the codepoints — a multi-byte codepoint
   contributes several bytes (`toChars` gives codepoints instead).

   > arrayLength (toUtf8 "héllo")
   6 -}
export toUtf8 : String -> Array Int
toUtf8 s = stringToUtf8Bytes s

{- | Rebuild a string from a UTF-8 `Array Int` byte stream (low 8 bits of each).
   The inverse of `toUtf8` on valid UTF-8: `fromUtf8 (toUtf8 s) == s`.

   > fromUtf8 (toUtf8 "héllo→")
   "héllo→" -}
export fromUtf8 : Array Int -> String
fromUtf8 bytes = stringFromUtf8Bytes bytes

{- | The number of UTF-8 bytes a string encodes to (>= its codepoint count).

   > utf8ByteLength "héllo"
   6 -}
export utf8ByteLength : String -> Int
utf8ByteLength s = arrayLength (toUtf8 s)

{- | Parse a decimal integer, an optional leading `-`/`+` allowed; `None` on
   any other character, the empty string, or a magnitude outside the `Int`
   range (`intMinBound`..`intMaxBound`) — out-of-range input is rejected
   rather than silently wrapping.

   > toInt "42"
   Some 42
   > toInt "-7"
   Some -7
   > toInt "12x"
   None
   > toInt "4611686018427387903"
   Some 4611686018427387903
   > toInt "4611686018427387904"
   None
   > toInt "-4611686018427387904"
   Some -4611686018427387904
   > toInt "-4611686018427387905"
   None
   > toInt "99999999999999999999"
   None -}
export toInt : String -> Option Int
toInt s =
  let a = toChars s
  parseInt a (arrayLength a)

parseInt : Array Char -> Int -> Option Int
parseInt a n = if n == 0 then None else parseSign a n (arrayGetUnsafe 0 a)

parseSign : Array Char -> Int -> Char -> Option Int
parseSign a n c
  | c == '-' = parseDigits a n 1 0 False True
  | c == '+' = parseDigits a n 1 0 False False
  | otherwise = parseDigits a n 0 0 False False

{- Accumulates a NON-POSITIVE running magnitude (`acc <= 0`) regardless of
   the parsed sign, and detects overflow before every multiply/add rather
   than after (`Int` wraps by design, so a post-hoc check can't see it).
   Negative accumulation — not positive-then-negate — is deliberate:
   `intMinBound`'s magnitude (2^62) is one larger than `intMaxBound`'s
   (2^62 - 1), so only the negative side can hold it without overflowing;
   `finishInt` negates back to positive only when the source had no `-`. -}
parseDigits : Array Char -> Int -> Int -> Int -> Bool -> Bool -> Option Int
parseDigits a n i acc seen negative
  | i >= n = finishInt seen acc negative
  | otherwise = parseDigitStep a n i acc seen negative (arrayGetUnsafe i a)

parseDigitStep : Array Char -> Int -> Int -> Int -> Bool -> Bool -> Char -> Option Int
parseDigitStep a n i acc seen negative c =
  if isDigit c then
    let d = charCode c - 48
    let limit = if negative then intMinBound else 0 - intMaxBound
    let multMin = limit / 10
    if acc < multMin then None
    else
      let acc2 = acc * 10
      if acc2 < limit + d then
        None
      else
        parseDigits a n (i + 1) (acc2 - d) True negative
  else None

finishInt : Bool -> Int -> Bool -> Option Int
finishInt seen acc negative =
  if not seen then
    None
  else if negative then
    Some acc
  else
    Some (0 - acc)

{- | Parse a decimal float; `None` on failure.

   > toFloat "3.5"
   Some 3.5
   > toFloat "nope"
   None -}
export toFloat : String -> Option Float
toFloat s = stringToFloat s

-- ── Inspection ──────────────────────────────────────────────────────────────
-- `length`/`isEmpty` intentionally omitted (see header) — use `stringLength`.

{- | True when `s` begins with `prefix`.  Tier 1: a slice + compare, no char
   decoding.

   > startsWith "he" "hello"
   True
   > startsWith "lo" "hello"
   False -}
export startsWith : String -> String -> Bool
startsWith prefix s = stringSlice 0 (stringLength prefix) s == prefix

{- | True when `s` ends with `suffix`.

   > endsWith "lo" "hello"
   True -}
export endsWith : String -> String -> Bool
endsWith suffix s =
  stringSlice (stringLength s - stringLength suffix) (stringLength s) s ==
    suffix

{- | Remove `prefix` from the front of `s`, or `None` when `s` doesn't start
   with it.  The `Option` is the point: unlike `drop (length prefix)` it tells
   you whether the prefix was actually there.

   > stripPrefix "he" "hello"
   Some "llo"
   > stripPrefix "xy" "hello"
   None
   > stripPrefix "" "hi"
   Some "hi"
   > stripPrefix "hello" "hello"
   Some "" -}
export stripPrefix : String -> String -> Option String
stripPrefix prefix s =
  if startsWith prefix s then
    Some (stringSlice (stringLength prefix) (stringLength s) s)
  else
    None

{- | Remove `suffix` from the end of `s`, or `None` when `s` doesn't end with
   it.

   > stripSuffix "lo" "hello"
   Some "hel"
   > stripSuffix "xy" "hello"
   None
   > stripSuffix "" "hi"
   Some "hi" -}
export stripSuffix : String -> String -> Option String
stripSuffix suffix s =
  if endsWith suffix s then
    Some (stringSlice 0 (stringLength s - stringLength suffix) s)
  else
    None

{- | True when `needle` occurs anywhere in `haystack` (the empty string is
   contained in everything).

   > contains "ell" "hello"
   True
   > contains "xyz" "hello"
   False -}
export contains : String -> String -> Bool
contains needle haystack = isSome (indexOf needle haystack)

{- | Codepoint index of the first occurrence of `needle` in `haystack`, or
   `None`.  Host-backed byte search (`stringIndexOf`) reported as a codepoint
   index — no interpreted per-char scan.

   > indexOf "lo" "hello"
   Some 3
   > indexOf "z" "hello"
   None -}
export indexOf : String -> String -> Option Int
indexOf needle haystack = stringIndexOf needle haystack

{- | Codepoint index of the *last* occurrence of `needle` in `haystack`, or
   `None`.  Walks forward from each hit (advancing one codepoint so overlapping
   matches still count), keeping the latest.

   > lastIndexOf "l" "hello"
   Some 3
   > lastIndexOf "z" "hello"
   None -}
export lastIndexOf : String -> String -> Option Int
lastIndexOf needle haystack
  | needle == "" = Some (stringLength haystack)
  | otherwise = lastIndexOfGo needle haystack 0 None

lastIndexOfGo : String -> String -> Int -> Option Int -> Option Int
lastIndexOfGo needle haystack from acc = match indexOf needle (stringSlice from (stringLength haystack) haystack)
  None => acc
  Some i => lastIndexOfGo needle haystack (from + i + 1) (Some (from + i))

{- | Number of non-overlapping occurrences of `needle` in `haystack` (`0` for
   the empty needle).

   > countOccurrences "l" "hello"
   2
   > countOccurrences "ll" "lllll"
   2 -}
export countOccurrences : String -> String -> Int
countOccurrences needle haystack
  | needle == "" = 0
  | otherwise = countGo needle (stringLength needle) haystack 0

countGo : String -> Int -> String -> Int -> Int
countGo needle nlen haystack acc = match indexOf needle haystack
  None => acc
  Some i => countGo needle nlen (stringSlice (i + nlen) (stringLength haystack) haystack) (acc + 1)

-- ── Transformation ──────────────────────────────────────────────────────────

-- | Prepend a prefix; `flip` of `Semigroup.append`.
export prepend : String -> String -> String
prepend pre s = pre ++ s

{- | Concatenate all strings in order.

   > concat ["a", "bc", "d"]
   "abcd" -}
export concat : List String -> String
concat parts = stringConcat parts

{- | Concatenate with `sep` between each adjacent pair.

   > join ", " ["a", "b", "c"]
   "a, b, c" -}
export join : String -> List String -> String
join sep parts = stringConcat (intersperse sep parts)

intersperse : a -> List a -> List a
intersperse _ [] = []
intersperse _ (x::[]) = [x]
intersperse sep (x::xs) = x :: sep :: intersperse sep xs

{- | Repeat the string `n` times (empty when `n <= 0`).

   > repeat 3 "ab"
   "ababab" -}
export repeat : Int -> String -> String
repeat n s = stringConcat (replic n s)

replic : Int -> a -> List a
replic n x = if n <= 0 then [] else x :: replic (n - 1) x

{- | Reverse the codepoints of a string.

   > reverse "abc"
   "cba" -}
export reverse : String -> String
reverse s =
  let a = toChars s
  stringFromChars (reverseArr a (arrayLength a))

reverseArr : Array Char -> Int -> Array Char
reverseArr a n = arrayMakeWith n (i => arrayGetUnsafe (n - 1 - i) a)

{- | Strip leading whitespace.  Finds the first non-space codepoint index, then
   slices — no rebuild. -}
export trimLeft : String -> String
trimLeft s =
  let a = toChars s
  stringSlice (firstNonSpace a 0 (arrayLength a)) (stringLength s) s

-- | Strip trailing whitespace.
export trimRight : String -> String
trimRight s =
  let a = toChars s
  stringSlice 0 (lastNonSpace a (arrayLength a - 1) + 1) s

{- | Strip whitespace from both ends.

   > trim "  hi  "
   "hi" -}
export trim : String -> String
trim s =
  let a = toChars s
  let n = arrayLength a
  stringSlice (firstNonSpace a 0 n) (lastNonSpace a (n - 1) + 1) s

firstNonSpace : Array Char -> Int -> Int -> Int
firstNonSpace a i n
  | i >= n = n
  | isSpace (arrayGetUnsafe i a) = firstNonSpace a (i + 1) n
  | otherwise = i

lastNonSpace : Array Char -> Int -> Int
lastNonSpace a i
  | i < 0 = -1
  | isSpace (arrayGetUnsafe i a) = lastNonSpace a (i - 1)
  | otherwise = i

firstSpace : Array Char -> Int -> Int -> Int
firstSpace a i n
  | i >= n = n
  | isSpace (arrayGetUnsafe i a) = i
  | otherwise = firstSpace a (i + 1) n

{- | Uppercase every character. **ASCII-only** (issue #417): a non-ASCII byte
   passes through unchanged, so this is byte-wise `'a'..'z'` mapping, not
   Unicode case folding — it never expands 1→N (`ß` stays `ß`, not `SS`).

   > toUpper "Straße"
   "STRAßE" -}
export toUpper : String -> String
toUpper s = stringToUpper s

{- | Lowercase every character. **ASCII-only** (issue #417): a non-ASCII byte
   passes through unchanged.

   > toLower "HÉLLO"
   "hÉllo" -}
export toLower : String -> String
toLower s = stringToLower s

{- | Uppercase the first character, leave the rest alone.

   > capitalize "hello"
   "Hello" -}
export capitalize : String -> String
capitalize s =
  let a = toChars s
  if arrayLength a == 0 then
    ""
  else
    charToStr (charToUpper (arrayGetUnsafe 0 a)) ++ stringSlice 1 (stringLength s) s

{- | Replace the first occurrence of `old` with `new`; unchanged if absent or
   if `old` is empty.

   > replace "l" "L" "hello"
   "heLlo" -}
export replace : String -> String -> String -> String
replace old new s = if old == "" then s else replaceFirst old new s

replaceFirst : String -> String -> String -> String
replaceFirst old new s = match indexOf old s
  None => s
  Some i => spliceAt i (stringLength old) new s

spliceAt : Int -> Int -> String -> String -> String
spliceAt i oldLen new s = stringSlice 0 i s
  ++ new
  ++ stringSlice (i + oldLen) (stringLength s) s

{- | Replace every non-overlapping occurrence of `old` with `new`.

   > replaceAll "l" "L" "hello"
   "heLLo" -}
export replaceAll : String -> String -> String -> String
replaceAll old new s =
  if old == "" then
    s
  else
    replaceAllGo (stringLength old) old new s

replaceAllGo : Int -> String -> String -> String -> String
replaceAllGo oldLen old new s = match indexOf old s
  None => s
  Some i => stringSlice 0 i s
    ++ new
    ++ replaceAllGo oldLen old new (stringSlice (i + oldLen) (stringLength s) s)

-- ── Slicing and splitting ────────────────────────────────────────────────────

{- | Substring `[lo, hi)` by codepoint, clamped to the string bounds (never
   panics; use `s.[lo..hi]` to panic on OOB instead).

   > sliceClamped 1 4 "hello"
   "ell" -}
export sliceClamped : Int -> Int -> String -> String
sliceClamped lo hi s = stringSlice lo hi s

{- | First `n` codepoints (fewer if shorter).

   > take 3 "hello"
   "hel" -}
export take : Int -> String -> String
take n s = stringSlice 0 n s

{- | Drop the first `n` codepoints.

   > drop 3 "hello"
   "lo" -}
export drop : Int -> String -> String
drop n s = stringSlice n (stringLength s) s

{- | `(take n s, drop n s)`.

   > splitAt 2 "hello"
   ("he", "llo") -}
export splitAt : Int -> String -> (String, String)
splitAt n s = (take n s, drop n s)

{- | Split on `sep`, dropping the separators.  An empty `sep` yields `[s]`.

   > split "," "a,b,c"
   ["a", "b", "c"]
   > split "," "abc"
   ["abc"] -}
export split : String -> String -> List String
split sep s = if sep == "" then [s] else splitGo (stringLength sep) sep s

splitGo : Int -> String -> String -> List String
splitGo sepLen sep s = match indexOf sep s
  None => [s]
  Some i => stringSlice 0 i s :: splitGo sepLen sep (stringSlice (i + sepLen) (stringLength s) s)

{- | Split into lines on `\n`, also stripping a trailing `\r` (so `\r\n` works).

   > lines "a\nb\nc"
   ["a", "b", "c"] -}
export lines : String -> List String
lines s = map stripCR (split nl s)

stripCR : String -> String
stripCR line =
  if endsWith "\r" line then
    stringSlice 0 (stringLength line - 1) line
  else
    line

{- | Split on runs of whitespace, dropping empty fields.  Each word is a
   `stringSlice` of the original — no per-char rebuild.

   > words "  hello   world "
   ["hello", "world"] -}
export words : String -> List String
words s =
  let a = toChars s
  let n = arrayLength a
  wordsFrom a n s (firstNonSpace a 0 n)

wordsFrom : Array Char -> Int -> String -> Int -> List String
wordsFrom a n s start =
  if start >= n then
    []
  else
    wordsEmit a n s start (firstSpace a start n)

wordsEmit : Array Char -> Int -> String -> Int -> Int -> List String
wordsEmit a n s start e =
  stringSlice start e s :: wordsFrom a n s (firstNonSpace a e n)

{- | Join with `\n` and append a trailing newline.

   > unlines ["a", "b"]
   "a\nb\n" -}
export unlines : List String -> String
unlines parts = stringConcat (map addNL parts)

addNL : String -> String
addNL p = p ++ nl

{- A single newline. -}
nl : String
nl = "\n"

{- | Join with single spaces.

   > unwords ["a", "b", "c"]
   "a b c" -}
export unwords : List String -> String
unwords parts = join " " parts

-- ── Padding ──────────────────────────────────────────────────────────────────

{- | Left-pad with `c` up to total length `n` (unchanged if already `>= n`).

   > padLeft 5 '.' "ab"
   "...ab" -}
export padLeft : Int -> Char -> String -> String
padLeft n c s =
  if stringLength s >= n then
    s
  else
    stringConcat (replic (n - stringLength s) (charToStr c)) ++ s

{- | Right-pad with `c` up to total length `n`.

   > padRight 5 '.' "ab"
   "ab..." -}
export padRight : Int -> Char -> String -> String
padRight n c s =
  if stringLength s >= n then
    s
  else
    s ++ stringConcat (replic (n - stringLength s) (charToStr c))

{- | Center the string in width `n`, padding with `c`; any odd extra goes on
   the right.

   > center 5 '.' "ab"
   ".ab.." -}
export center : Int -> Char -> String -> String
center n c s =
  if stringLength s >= n then
    s
  else
    centerPad (half (n - stringLength s)) (n - stringLength s - half (n - stringLength s)) c s

centerPad : Int -> Int -> Char -> String -> String
centerPad l r c s = stringConcat (replic l (charToStr c))
  ++ s
  ++ stringConcat (replic r (charToStr c))

half : Int -> Int
half k = if k <= 1 then 0 else 1 + half (k - 2)
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Debug" false) (mem "Foldable" false) (mem "Mappable" false) (mem "Option" false) (mem "Ordering" false))))
(DTypeSig true "isDigit" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isDigit" ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48))) (EBinOp "<=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 57)))))
(DTypeSig true "isAlpha" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isAlpha" ((PVar "c")) (EApp (EVar "charIsAlpha") (EVar "c")))
(DTypeSig true "isAlphaNum" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isAlphaNum" ((PVar "c")) (EBinOp "||" (EApp (EVar "charIsAlpha") (EVar "c")) (EApp (EVar "isDigit") (EVar "c"))))
(DTypeSig true "isSpace" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isSpace" ((PVar "c")) (EApp (EVar "charIsSpace") (EVar "c")))
(DTypeSig true "isUpper" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isUpper" ((PVar "c")) (EApp (EVar "charIsUpper") (EVar "c")))
(DTypeSig true "isLower" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isLower" ((PVar "c")) (EApp (EVar "charIsLower") (EVar "c")))
(DTypeSig true "isPunct" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isPunct" ((PVar "c")) (EApp (EVar "charIsPunct") (EVar "c")))
(DTypeSig true "digitToInt" (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "digitToInt" ((PVar "c")) (EApp (EVar "digitVal") (EApp (EVar "charCode") (EVar "c"))))
(DTypeSig false "digitVal" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "digitVal" ((PVar "n")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 48))) (EBinOp "<=" (EVar "n") (ELit (LInt 57)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 48)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 97))) (EBinOp "<=" (EVar "n") (ELit (LInt 102)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 87)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 65))) (EBinOp "<=" (EVar "n") (ELit (LInt 70)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 55)))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "intToDigit" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Char"))))
(DFunDef false "intToDigit" ((PVar "n")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 0))) (EBinOp "<=" (EVar "n") (ELit (LInt 9)))) (EApp (EVar "charFromCode") (EBinOp "+" (EVar "n") (ELit (LInt 48)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 10))) (EBinOp "<=" (EVar "n") (ELit (LInt 15)))) (EApp (EVar "charFromCode") (EBinOp "+" (EVar "n") (ELit (LInt 87)))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "fromChar" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "fromChar" ((PVar "c")) (EApp (EVar "charToStr") (EVar "c")))
(DTypeSig true "toChars" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Char"))))
(DFunDef false "toChars" ((PVar "s")) (EApp (EVar "stringToChars") (EVar "s")))
(DTypeSig true "fromChars" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyCon "String")))
(DFunDef false "fromChars" ((PVar "cs")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EVar "cs"))))
(DTypeSig true "toUtf8" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toUtf8" ((PVar "s")) (EApp (EVar "stringToUtf8Bytes") (EVar "s")))
(DTypeSig true "fromUtf8" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DFunDef false "fromUtf8" ((PVar "bytes")) (EApp (EVar "stringFromUtf8Bytes") (EVar "bytes")))
(DTypeSig true "utf8ByteLength" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "utf8ByteLength" ((PVar "s")) (EApp (EVar "arrayLength") (EApp (EVar "toUtf8") (EVar "s"))))
(DTypeSig true "toInt" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "toInt" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoExpr (EApp (EApp (EVar "parseInt") (EVar "a")) (EApp (EVar "arrayLength") (EVar "a"))))))
(DTypeSig false "parseInt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "parseInt" ((PVar "a") (PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "None") (EApp (EApp (EApp (EVar "parseSign") (EVar "a")) (EVar "n")) (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "a")))))
(DTypeSig false "parseSign" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "parseSign" ((PVar "a") (PVar "n") (PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "-"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "a")) (EVar "n")) (ELit (LInt 1))) (ELit (LInt 0))) (EVar "False")) (EVar "True")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "+"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "a")) (EVar "n")) (ELit (LInt 1))) (ELit (LInt 0))) (EVar "False")) (EVar "False")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "a")) (EVar "n")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "False")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Int")))))))))
(DFunDef false "parseDigits" ((PVar "a") (PVar "n") (PVar "i") (PVar "acc") (PVar "seen") (PVar "negative")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EApp (EApp (EVar "finishInt") (EVar "seen")) (EVar "acc")) (EVar "negative")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseDigitStep") (EVar "a")) (EVar "n")) (EVar "i")) (EVar "acc")) (EVar "seen")) (EVar "negative")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseDigitStep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Int"))))))))))
(DFunDef false "parseDigitStep" ((PVar "a") (PVar "n") (PVar "i") (PVar "acc") (PVar "seen") (PVar "negative") (PVar "c")) (EIf (EApp (EVar "isDigit") (EVar "c")) (EBlock (DoLet false false (PVar "d") (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48)))) (DoLet false false (PVar "limit") (EIf (EVar "negative") (EVar "intMinBound") (EBinOp "-" (ELit (LInt 0)) (EVar "intMaxBound")))) (DoLet false false (PVar "multMin") (EBinOp "/" (EVar "limit") (ELit (LInt 10)))) (DoExpr (EIf (EBinOp "<" (EVar "acc") (EVar "multMin")) (EVar "None") (EBlock (DoLet false false (PVar "acc2") (EBinOp "*" (EVar "acc") (ELit (LInt 10)))) (DoExpr (EIf (EBinOp "<" (EVar "acc2") (EBinOp "+" (EVar "limit") (EVar "d"))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "a")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "acc2") (EVar "d"))) (EVar "True")) (EVar "negative")))))))) (EVar "None")))
(DTypeSig false "finishInt" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "finishInt" ((PVar "seen") (PVar "acc") (PVar "negative")) (EIf (EApp (EVar "not") (EVar "seen")) (EVar "None") (EIf (EVar "negative") (EApp (EVar "Some") (EVar "acc")) (EApp (EVar "Some") (EBinOp "-" (ELit (LInt 0)) (EVar "acc"))))))
(DTypeSig true "toFloat" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Float"))))
(DFunDef false "toFloat" ((PVar "s")) (EApp (EVar "stringToFloat") (EVar "s")))
(DTypeSig true "startsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "startsWith" ((PVar "prefix") (PVar "s")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "prefix"))) (EVar "s")) (EVar "prefix")))
(DTypeSig true "endsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "endsWith" ((PVar "suffix") (PVar "s")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (EApp (EVar "stringLength") (EVar "suffix")))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "suffix")))
(DTypeSig true "stripPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "stripPrefix" ((PVar "prefix") (PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "s")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))) (EVar "None")))
(DTypeSig true "stripSuffix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "stripSuffix" ((PVar "suffix") (PVar "s")) (EIf (EApp (EApp (EVar "endsWith") (EVar "suffix")) (EVar "s")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (EApp (EVar "stringLength") (EVar "suffix")))) (EVar "s"))) (EVar "None")))
(DTypeSig true "contains" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "contains" ((PVar "needle") (PVar "haystack")) (EApp (EVar "isSome") (EApp (EApp (EVar "indexOf") (EVar "needle")) (EVar "haystack"))))
(DTypeSig true "indexOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "indexOf" ((PVar "needle") (PVar "haystack")) (EApp (EApp (EVar "stringIndexOf") (EVar "needle")) (EVar "haystack")))
(DTypeSig true "lastIndexOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "lastIndexOf" ((PVar "needle") (PVar "haystack")) (EIf (EBinOp "==" (EVar "needle") (ELit (LString ""))) (EApp (EVar "Some") (EApp (EVar "stringLength") (EVar "haystack"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "lastIndexOfGo") (EVar "needle")) (EVar "haystack")) (ELit (LInt 0))) (EVar "None")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "lastIndexOfGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "lastIndexOfGo" ((PVar "needle") (PVar "haystack") (PVar "from") (PVar "acc")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "needle")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "from")) (EApp (EVar "stringLength") (EVar "haystack"))) (EVar "haystack"))) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EApp (EVar "lastIndexOfGo") (EVar "needle")) (EVar "haystack")) (EBinOp "+" (EBinOp "+" (EVar "from") (EVar "i")) (ELit (LInt 1)))) (EApp (EVar "Some") (EBinOp "+" (EVar "from") (EVar "i")))))))
(DTypeSig true "countOccurrences" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "countOccurrences" ((PVar "needle") (PVar "haystack")) (EIf (EBinOp "==" (EVar "needle") (ELit (LString ""))) (ELit (LInt 0)) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "countGo") (EVar "needle")) (EApp (EVar "stringLength") (EVar "needle"))) (EVar "haystack")) (ELit (LInt 0))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "countGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "countGo" ((PVar "needle") (PVar "nlen") (PVar "haystack") (PVar "acc")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "needle")) (EVar "haystack")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EApp (EVar "countGo") (EVar "needle")) (EVar "nlen")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (EVar "nlen"))) (EApp (EVar "stringLength") (EVar "haystack"))) (EVar "haystack"))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))))))
(DTypeSig true "prepend" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "prepend" ((PVar "pre") (PVar "s")) (EBinOp "++" (EVar "pre") (EVar "s")))
(DTypeSig true "concat" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "concat" ((PVar "parts")) (EApp (EVar "stringConcat") (EVar "parts")))
(DTypeSig true "join" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "join" ((PVar "sep") (PVar "parts")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "intersperse") (EVar "sep")) (EVar "parts"))))
(DTypeSig false "intersperse" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "intersperse" (PWild (PList)) (EListLit))
(DFunDef false "intersperse" (PWild (PCons (PVar "x") (PList))) (EListLit (EVar "x")))
(DFunDef false "intersperse" ((PVar "sep") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "sep") (EApp (EApp (EVar "intersperse") (EVar "sep")) (EVar "xs")))))
(DTypeSig true "repeat" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "repeat" ((PVar "n") (PVar "s")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "replic") (EVar "n")) (EVar "s"))))
(DTypeSig false "replic" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "replic" ((PVar "n") (PVar "x")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "replic") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "x")))))
(DTypeSig true "reverse" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "reverse" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoExpr (EApp (EVar "stringFromChars") (EApp (EApp (EVar "reverseArr") (EVar "a")) (EApp (EVar "arrayLength") (EVar "a")))))))
(DTypeSig false "reverseArr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Char")))))
(DFunDef false "reverseArr" ((PVar "a") (PVar "n")) (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EBinOp "-" (EVar "n") (ELit (LInt 1))) (EVar "i"))) (EVar "a")))))
(DTypeSig true "trimLeft" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "trimLeft" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EApp (EApp (EApp (EVar "firstNonSpace") (EVar "a")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "a")))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))))
(DTypeSig true "trimRight" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "trimRight" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "+" (EApp (EApp (EVar "lastNonSpace") (EVar "a")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "a")) (ELit (LInt 1)))) (ELit (LInt 1)))) (EVar "s")))))
(DTypeSig true "trim" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "trim" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "a"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EApp (EApp (EApp (EVar "firstNonSpace") (EVar "a")) (ELit (LInt 0))) (EVar "n"))) (EBinOp "+" (EApp (EApp (EVar "lastNonSpace") (EVar "a")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (ELit (LInt 1)))) (EVar "s")))))
(DTypeSig false "firstNonSpace" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstNonSpace" ((PVar "a") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EApp (EVar "isSpace") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EApp (EApp (EVar "firstNonSpace") (EVar "a")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "lastNonSpace" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lastNonSpace" ((PVar "a") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EUnOp "-" (ELit (LInt 1))) (EIf (EApp (EVar "isSpace") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EApp (EVar "lastNonSpace") (EVar "a")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "firstSpace" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstSpace" ((PVar "a") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EApp (EVar "isSpace") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstSpace") (EVar "a")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "toUpper" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "toUpper" ((PVar "s")) (EApp (EVar "stringToUpper") (EVar "s")))
(DTypeSig true "toLower" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "toLower" ((PVar "s")) (EApp (EVar "stringToLower") (EVar "s")))
(DTypeSig true "capitalize" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "capitalize" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "a")) (ELit (LInt 0))) (ELit (LString "")) (EBinOp "++" (EApp (EVar "charToStr") (EApp (EVar "charToUpper") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "a")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))))))
(DTypeSig true "replace" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replace" ((PVar "old") (PVar "new") (PVar "s")) (EIf (EBinOp "==" (EVar "old") (ELit (LString ""))) (EVar "s") (EApp (EApp (EApp (EVar "replaceFirst") (EVar "old")) (EVar "new")) (EVar "s"))))
(DTypeSig false "replaceFirst" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replaceFirst" ((PVar "old") (PVar "new") (PVar "s")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "old")) (EVar "s")) (arm (PCon "None") () (EVar "s")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EApp (EVar "spliceAt") (EVar "i")) (EApp (EVar "stringLength") (EVar "old"))) (EVar "new")) (EVar "s")))))
(DTypeSig false "spliceAt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "spliceAt" ((PVar "i") (PVar "oldLen") (PVar "new") (PVar "s")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "s")) (EVar "new")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (EVar "oldLen"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))))
(DTypeSig true "replaceAll" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replaceAll" ((PVar "old") (PVar "new") (PVar "s")) (EIf (EBinOp "==" (EVar "old") (ELit (LString ""))) (EVar "s") (EApp (EApp (EApp (EApp (EVar "replaceAllGo") (EApp (EVar "stringLength") (EVar "old"))) (EVar "old")) (EVar "new")) (EVar "s"))))
(DTypeSig false "replaceAllGo" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "replaceAllGo" ((PVar "oldLen") (PVar "old") (PVar "new") (PVar "s")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "old")) (EVar "s")) (arm (PCon "None") () (EVar "s")) (arm (PCon "Some" (PVar "i")) () (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "s")) (EVar "new")) (EApp (EApp (EApp (EApp (EVar "replaceAllGo") (EVar "oldLen")) (EVar "old")) (EVar "new")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (EVar "oldLen"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))))))
(DTypeSig true "sliceClamped" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "sliceClamped" ((PVar "lo") (PVar "hi") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EVar "hi")) (EVar "s")))
(DTypeSig true "take" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "take" ((PVar "n") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "n")) (EVar "s")))
(DTypeSig true "drop" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "drop" ((PVar "n") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "n")) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))
(DTypeSig true "splitAt" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "splitAt" ((PVar "n") (PVar "s")) (ETuple (EApp (EApp (EVar "take") (EVar "n")) (EVar "s")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "s"))))
(DTypeSig true "split" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "split" ((PVar "sep") (PVar "s")) (EIf (EBinOp "==" (EVar "sep") (ELit (LString ""))) (EListLit (EVar "s")) (EApp (EApp (EApp (EVar "splitGo") (EApp (EVar "stringLength") (EVar "sep"))) (EVar "sep")) (EVar "s"))))
(DTypeSig false "splitGo" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "splitGo" ((PVar "sepLen") (PVar "sep") (PVar "s")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "sep")) (EVar "s")) (arm (PCon "None") () (EListLit (EVar "s"))) (arm (PCon "Some" (PVar "i")) () (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "s")) (EApp (EApp (EApp (EVar "splitGo") (EVar "sepLen")) (EVar "sep")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (EVar "sepLen"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))))))
(DTypeSig true "lines" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "lines" ((PVar "s")) (EApp (EApp (EVar "map") (EVar "stripCR")) (EApp (EApp (EVar "split") (EVar "nl")) (EVar "s"))))
(DTypeSig false "stripCR" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripCR" ((PVar "line")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "\r"))) (EVar "line")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "line")) (ELit (LInt 1)))) (EVar "line")) (EVar "line")))
(DTypeSig true "words" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "words" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "a"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "wordsFrom") (EVar "a")) (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EVar "firstNonSpace") (EVar "a")) (ELit (LInt 0))) (EVar "n"))))))
(DTypeSig false "wordsFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "wordsFrom" ((PVar "a") (PVar "n") (PVar "s") (PVar "start")) (EIf (EBinOp ">=" (EVar "start") (EVar "n")) (EListLit) (EApp (EApp (EApp (EApp (EApp (EVar "wordsEmit") (EVar "a")) (EVar "n")) (EVar "s")) (EVar "start")) (EApp (EApp (EApp (EVar "firstSpace") (EVar "a")) (EVar "start")) (EVar "n")))))
(DTypeSig false "wordsEmit" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "wordsEmit" ((PVar "a") (PVar "n") (PVar "s") (PVar "start") (PVar "e")) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "e")) (EVar "s")) (EApp (EApp (EApp (EApp (EVar "wordsFrom") (EVar "a")) (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EVar "firstNonSpace") (EVar "a")) (EVar "e")) (EVar "n")))))
(DTypeSig true "unlines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "unlines" ((PVar "parts")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "map") (EVar "addNL")) (EVar "parts"))))
(DTypeSig false "addNL" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "addNL" ((PVar "p")) (EBinOp "++" (EVar "p") (EVar "nl")))
(DTypeSig false "nl" (TyCon "String"))
(DFunDef false "nl" () (ELit (LString "\n")))
(DTypeSig true "unwords" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "unwords" ((PVar "parts")) (EApp (EApp (EVar "join") (ELit (LString " "))) (EVar "parts")))
(DTypeSig true "padLeft" (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "padLeft" ((PVar "n") (PVar "c") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "n")) (EVar "s") (EBinOp "++" (EApp (EVar "stringConcat") (EApp (EApp (EVar "replic") (EBinOp "-" (EVar "n") (EApp (EVar "stringLength") (EVar "s")))) (EApp (EVar "charToStr") (EVar "c")))) (EVar "s"))))
(DTypeSig true "padRight" (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "padRight" ((PVar "n") (PVar "c") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "n")) (EVar "s") (EBinOp "++" (EVar "s") (EApp (EVar "stringConcat") (EApp (EApp (EVar "replic") (EBinOp "-" (EVar "n") (EApp (EVar "stringLength") (EVar "s")))) (EApp (EVar "charToStr") (EVar "c")))))))
(DTypeSig true "center" (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "center" ((PVar "n") (PVar "c") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "n")) (EVar "s") (EApp (EApp (EApp (EApp (EVar "centerPad") (EApp (EVar "half") (EBinOp "-" (EVar "n") (EApp (EVar "stringLength") (EVar "s"))))) (EBinOp "-" (EBinOp "-" (EVar "n") (EApp (EVar "stringLength") (EVar "s"))) (EApp (EVar "half") (EBinOp "-" (EVar "n") (EApp (EVar "stringLength") (EVar "s")))))) (EVar "c")) (EVar "s"))))
(DTypeSig false "centerPad" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "centerPad" ((PVar "l") (PVar "r") (PVar "c") (PVar "s")) (EBinOp "++" (EBinOp "++" (EApp (EVar "stringConcat") (EApp (EApp (EVar "replic") (EVar "l")) (EApp (EVar "charToStr") (EVar "c")))) (EVar "s")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "replic") (EVar "r")) (EApp (EVar "charToStr") (EVar "c"))))))
(DTypeSig false "half" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "half" ((PVar "k")) (EIf (EBinOp "<=" (EVar "k") (ELit (LInt 1))) (ELit (LInt 0)) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "half") (EBinOp "-" (EVar "k") (ELit (LInt 2)))))))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Debug" false) (mem "Foldable" false) (mem "Mappable" false) (mem "Option" false) (mem "Ordering" false))))
(DTypeSig true "isDigit" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isDigit" ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48))) (EBinOp "<=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 57)))))
(DTypeSig true "isAlpha" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isAlpha" ((PVar "c")) (EApp (EVar "charIsAlpha") (EVar "c")))
(DTypeSig true "isAlphaNum" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isAlphaNum" ((PVar "c")) (EBinOp "||" (EApp (EVar "charIsAlpha") (EVar "c")) (EApp (EVar "isDigit") (EVar "c"))))
(DTypeSig true "isSpace" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isSpace" ((PVar "c")) (EApp (EVar "charIsSpace") (EVar "c")))
(DTypeSig true "isUpper" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isUpper" ((PVar "c")) (EApp (EVar "charIsUpper") (EVar "c")))
(DTypeSig true "isLower" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isLower" ((PVar "c")) (EApp (EVar "charIsLower") (EVar "c")))
(DTypeSig true "isPunct" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isPunct" ((PVar "c")) (EApp (EVar "charIsPunct") (EVar "c")))
(DTypeSig true "digitToInt" (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "digitToInt" ((PVar "c")) (EApp (EVar "digitVal") (EApp (EVar "charCode") (EVar "c"))))
(DTypeSig false "digitVal" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "digitVal" ((PVar "n")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 48))) (EBinOp "<=" (EVar "n") (ELit (LInt 57)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 48)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 97))) (EBinOp "<=" (EVar "n") (ELit (LInt 102)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 87)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 65))) (EBinOp "<=" (EVar "n") (ELit (LInt 70)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 55)))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "intToDigit" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Char"))))
(DFunDef false "intToDigit" ((PVar "n")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 0))) (EBinOp "<=" (EVar "n") (ELit (LInt 9)))) (EApp (EVar "charFromCode") (EBinOp "+" (EVar "n") (ELit (LInt 48)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 10))) (EBinOp "<=" (EVar "n") (ELit (LInt 15)))) (EApp (EVar "charFromCode") (EBinOp "+" (EVar "n") (ELit (LInt 87)))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "fromChar" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "fromChar" ((PVar "c")) (EApp (EVar "charToStr") (EVar "c")))
(DTypeSig true "toChars" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Char"))))
(DFunDef false "toChars" ((PVar "s")) (EApp (EVar "stringToChars") (EVar "s")))
(DTypeSig true "fromChars" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyCon "String")))
(DFunDef false "fromChars" ((PVar "cs")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EVar "cs"))))
(DTypeSig true "toUtf8" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toUtf8" ((PVar "s")) (EApp (EVar "stringToUtf8Bytes") (EVar "s")))
(DTypeSig true "fromUtf8" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DFunDef false "fromUtf8" ((PVar "bytes")) (EApp (EVar "stringFromUtf8Bytes") (EVar "bytes")))
(DTypeSig true "utf8ByteLength" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "utf8ByteLength" ((PVar "s")) (EApp (EVar "arrayLength") (EApp (EVar "toUtf8") (EVar "s"))))
(DTypeSig true "toInt" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "toInt" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoExpr (EApp (EApp (EVar "parseInt") (EVar "a")) (EApp (EVar "arrayLength") (EVar "a"))))))
(DTypeSig false "parseInt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "parseInt" ((PVar "a") (PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "None") (EApp (EApp (EApp (EVar "parseSign") (EVar "a")) (EVar "n")) (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "a")))))
(DTypeSig false "parseSign" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "parseSign" ((PVar "a") (PVar "n") (PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "-"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "a")) (EVar "n")) (ELit (LInt 1))) (ELit (LInt 0))) (EVar "False")) (EVar "True")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "+"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "a")) (EVar "n")) (ELit (LInt 1))) (ELit (LInt 0))) (EVar "False")) (EVar "False")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "a")) (EVar "n")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "False")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Int")))))))))
(DFunDef false "parseDigits" ((PVar "a") (PVar "n") (PVar "i") (PVar "acc") (PVar "seen") (PVar "negative")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EApp (EApp (EVar "finishInt") (EVar "seen")) (EVar "acc")) (EVar "negative")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseDigitStep") (EVar "a")) (EVar "n")) (EVar "i")) (EVar "acc")) (EVar "seen")) (EVar "negative")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseDigitStep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Int"))))))))))
(DFunDef false "parseDigitStep" ((PVar "a") (PVar "n") (PVar "i") (PVar "acc") (PVar "seen") (PVar "negative") (PVar "c")) (EIf (EApp (EVar "isDigit") (EVar "c")) (EBlock (DoLet false false (PVar "d") (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48)))) (DoLet false false (PVar "limit") (EIf (EVar "negative") (EVar "intMinBound") (EBinOp "-" (ELit (LInt 0)) (EVar "intMaxBound")))) (DoLet false false (PVar "multMin") (EBinOp "/" (EVar "limit") (ELit (LInt 10)))) (DoExpr (EIf (EBinOp "<" (EVar "acc") (EVar "multMin")) (EVar "None") (EBlock (DoLet false false (PVar "acc2") (EBinOp "*" (EVar "acc") (ELit (LInt 10)))) (DoExpr (EIf (EBinOp "<" (EVar "acc2") (EBinOp "+" (EVar "limit") (EVar "d"))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "parseDigits") (EVar "a")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "acc2") (EVar "d"))) (EVar "True")) (EVar "negative")))))))) (EVar "None")))
(DTypeSig false "finishInt" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "finishInt" ((PVar "seen") (PVar "acc") (PVar "negative")) (EIf (EApp (EVar "not") (EVar "seen")) (EVar "None") (EIf (EVar "negative") (EApp (EVar "Some") (EVar "acc")) (EApp (EVar "Some") (EBinOp "-" (ELit (LInt 0)) (EVar "acc"))))))
(DTypeSig true "toFloat" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Float"))))
(DFunDef false "toFloat" ((PVar "s")) (EApp (EVar "stringToFloat") (EVar "s")))
(DTypeSig true "startsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "startsWith" ((PVar "prefix") (PVar "s")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "prefix"))) (EVar "s")) (EVar "prefix")))
(DTypeSig true "endsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "endsWith" ((PVar "suffix") (PVar "s")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (EApp (EVar "stringLength") (EVar "suffix")))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "suffix")))
(DTypeSig true "stripPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "stripPrefix" ((PVar "prefix") (PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "s")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))) (EVar "None")))
(DTypeSig true "stripSuffix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "stripSuffix" ((PVar "suffix") (PVar "s")) (EIf (EApp (EApp (EVar "endsWith") (EVar "suffix")) (EVar "s")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (EApp (EVar "stringLength") (EVar "suffix")))) (EVar "s"))) (EVar "None")))
(DTypeSig true "contains" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "contains" ((PVar "needle") (PVar "haystack")) (EApp (EVar "isSome") (EApp (EApp (EVar "indexOf") (EVar "needle")) (EVar "haystack"))))
(DTypeSig true "indexOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "indexOf" ((PVar "needle") (PVar "haystack")) (EApp (EApp (EVar "stringIndexOf") (EVar "needle")) (EVar "haystack")))
(DTypeSig true "lastIndexOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "lastIndexOf" ((PVar "needle") (PVar "haystack")) (EIf (EBinOp "==" (EVar "needle") (ELit (LString ""))) (EApp (EVar "Some") (EApp (EVar "stringLength") (EVar "haystack"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "lastIndexOfGo") (EVar "needle")) (EVar "haystack")) (ELit (LInt 0))) (EVar "None")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "lastIndexOfGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "lastIndexOfGo" ((PVar "needle") (PVar "haystack") (PVar "from") (PVar "acc")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "needle")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "from")) (EApp (EVar "stringLength") (EVar "haystack"))) (EVar "haystack"))) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EApp (EVar "lastIndexOfGo") (EVar "needle")) (EVar "haystack")) (EBinOp "+" (EBinOp "+" (EVar "from") (EVar "i")) (ELit (LInt 1)))) (EApp (EVar "Some") (EBinOp "+" (EVar "from") (EVar "i")))))))
(DTypeSig true "countOccurrences" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "countOccurrences" ((PVar "needle") (PVar "haystack")) (EIf (EBinOp "==" (EVar "needle") (ELit (LString ""))) (ELit (LInt 0)) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "countGo") (EVar "needle")) (EApp (EVar "stringLength") (EVar "needle"))) (EVar "haystack")) (ELit (LInt 0))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "countGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "countGo" ((PVar "needle") (PVar "nlen") (PVar "haystack") (PVar "acc")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "needle")) (EVar "haystack")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EApp (EVar "countGo") (EVar "needle")) (EVar "nlen")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (EVar "nlen"))) (EApp (EVar "stringLength") (EVar "haystack"))) (EVar "haystack"))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))))))
(DTypeSig true "prepend" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "prepend" ((PVar "pre") (PVar "s")) (EBinOp "++" (EVar "pre") (EVar "s")))
(DTypeSig true "concat" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "concat" ((PVar "parts")) (EApp (EVar "stringConcat") (EVar "parts")))
(DTypeSig true "join" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "join" ((PVar "sep") (PVar "parts")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "intersperse") (EVar "sep")) (EVar "parts"))))
(DTypeSig false "intersperse" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "intersperse" (PWild (PList)) (EListLit))
(DFunDef false "intersperse" (PWild (PCons (PVar "x") (PList))) (EListLit (EVar "x")))
(DFunDef false "intersperse" ((PVar "sep") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "sep") (EApp (EApp (EVar "intersperse") (EVar "sep")) (EVar "xs")))))
(DTypeSig true "repeat" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "repeat" ((PVar "n") (PVar "s")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "replic") (EVar "n")) (EVar "s"))))
(DTypeSig false "replic" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "replic" ((PVar "n") (PVar "x")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "replic") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "x")))))
(DTypeSig true "reverse" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "reverse" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoExpr (EApp (EVar "stringFromChars") (EApp (EApp (EVar "reverseArr") (EVar "a")) (EApp (EVar "arrayLength") (EVar "a")))))))
(DTypeSig false "reverseArr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Char")))))
(DFunDef false "reverseArr" ((PVar "a") (PVar "n")) (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EBinOp "-" (EVar "n") (ELit (LInt 1))) (EVar "i"))) (EVar "a")))))
(DTypeSig true "trimLeft" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "trimLeft" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EApp (EApp (EApp (EVar "firstNonSpace") (EVar "a")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "a")))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))))
(DTypeSig true "trimRight" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "trimRight" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "+" (EApp (EApp (EVar "lastNonSpace") (EVar "a")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "a")) (ELit (LInt 1)))) (ELit (LInt 1)))) (EVar "s")))))
(DTypeSig true "trim" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "trim" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "a"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EApp (EApp (EApp (EVar "firstNonSpace") (EVar "a")) (ELit (LInt 0))) (EVar "n"))) (EBinOp "+" (EApp (EApp (EVar "lastNonSpace") (EVar "a")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (ELit (LInt 1)))) (EVar "s")))))
(DTypeSig false "firstNonSpace" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstNonSpace" ((PVar "a") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EApp (EVar "isSpace") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EApp (EApp (EVar "firstNonSpace") (EVar "a")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "lastNonSpace" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lastNonSpace" ((PVar "a") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EUnOp "-" (ELit (LInt 1))) (EIf (EApp (EVar "isSpace") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EApp (EVar "lastNonSpace") (EVar "a")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "firstSpace" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstSpace" ((PVar "a") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EApp (EVar "isSpace") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstSpace") (EVar "a")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "toUpper" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "toUpper" ((PVar "s")) (EApp (EVar "stringToUpper") (EVar "s")))
(DTypeSig true "toLower" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "toLower" ((PVar "s")) (EApp (EVar "stringToLower") (EVar "s")))
(DTypeSig true "capitalize" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "capitalize" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "a")) (ELit (LInt 0))) (ELit (LString "")) (EBinOp "++" (EApp (EVar "charToStr") (EApp (EVar "charToUpper") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "a")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))))))
(DTypeSig true "replace" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replace" ((PVar "old") (PVar "new") (PVar "s")) (EIf (EBinOp "==" (EVar "old") (ELit (LString ""))) (EVar "s") (EApp (EApp (EApp (EVar "replaceFirst") (EVar "old")) (EVar "new")) (EVar "s"))))
(DTypeSig false "replaceFirst" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replaceFirst" ((PVar "old") (PVar "new") (PVar "s")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "old")) (EVar "s")) (arm (PCon "None") () (EVar "s")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EApp (EVar "spliceAt") (EVar "i")) (EApp (EVar "stringLength") (EVar "old"))) (EVar "new")) (EVar "s")))))
(DTypeSig false "spliceAt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "spliceAt" ((PVar "i") (PVar "oldLen") (PVar "new") (PVar "s")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "s")) (EVar "new")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (EVar "oldLen"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))))
(DTypeSig true "replaceAll" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replaceAll" ((PVar "old") (PVar "new") (PVar "s")) (EIf (EBinOp "==" (EVar "old") (ELit (LString ""))) (EVar "s") (EApp (EApp (EApp (EApp (EVar "replaceAllGo") (EApp (EVar "stringLength") (EVar "old"))) (EVar "old")) (EVar "new")) (EVar "s"))))
(DTypeSig false "replaceAllGo" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "replaceAllGo" ((PVar "oldLen") (PVar "old") (PVar "new") (PVar "s")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "old")) (EVar "s")) (arm (PCon "None") () (EVar "s")) (arm (PCon "Some" (PVar "i")) () (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "s")) (EVar "new")) (EApp (EApp (EApp (EApp (EVar "replaceAllGo") (EVar "oldLen")) (EVar "old")) (EVar "new")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (EVar "oldLen"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))))))
(DTypeSig true "sliceClamped" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "sliceClamped" ((PVar "lo") (PVar "hi") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EVar "hi")) (EVar "s")))
(DTypeSig true "take" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "take" ((PVar "n") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "n")) (EVar "s")))
(DTypeSig true "drop" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "drop" ((PVar "n") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "n")) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))
(DTypeSig true "splitAt" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "splitAt" ((PVar "n") (PVar "s")) (ETuple (EApp (EApp (EVar "take") (EVar "n")) (EVar "s")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "s"))))
(DTypeSig true "split" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "split" ((PVar "sep") (PVar "s")) (EIf (EBinOp "==" (EVar "sep") (ELit (LString ""))) (EListLit (EVar "s")) (EApp (EApp (EApp (EVar "splitGo") (EApp (EVar "stringLength") (EVar "sep"))) (EVar "sep")) (EVar "s"))))
(DTypeSig false "splitGo" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "splitGo" ((PVar "sepLen") (PVar "sep") (PVar "s")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "sep")) (EVar "s")) (arm (PCon "None") () (EListLit (EVar "s"))) (arm (PCon "Some" (PVar "i")) () (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "s")) (EApp (EApp (EApp (EVar "splitGo") (EVar "sepLen")) (EVar "sep")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (EVar "sepLen"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))))))
(DTypeSig true "lines" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "lines" ((PVar "s")) (EApp (EApp (EMethodRef "map") (EVar "stripCR")) (EApp (EApp (EVar "split") (EVar "nl")) (EVar "s"))))
(DTypeSig false "stripCR" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripCR" ((PVar "line")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "\r"))) (EVar "line")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "line")) (ELit (LInt 1)))) (EVar "line")) (EVar "line")))
(DTypeSig true "words" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "words" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "a"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "wordsFrom") (EVar "a")) (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EVar "firstNonSpace") (EVar "a")) (ELit (LInt 0))) (EVar "n"))))))
(DTypeSig false "wordsFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "wordsFrom" ((PVar "a") (PVar "n") (PVar "s") (PVar "start")) (EIf (EBinOp ">=" (EVar "start") (EVar "n")) (EListLit) (EApp (EApp (EApp (EApp (EApp (EVar "wordsEmit") (EVar "a")) (EVar "n")) (EVar "s")) (EVar "start")) (EApp (EApp (EApp (EVar "firstSpace") (EVar "a")) (EVar "start")) (EVar "n")))))
(DTypeSig false "wordsEmit" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "wordsEmit" ((PVar "a") (PVar "n") (PVar "s") (PVar "start") (PVar "e")) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "e")) (EVar "s")) (EApp (EApp (EApp (EApp (EVar "wordsFrom") (EVar "a")) (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EVar "firstNonSpace") (EVar "a")) (EVar "e")) (EVar "n")))))
(DTypeSig true "unlines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "unlines" ((PVar "parts")) (EApp (EVar "stringConcat") (EApp (EApp (EMethodRef "map") (EVar "addNL")) (EVar "parts"))))
(DTypeSig false "addNL" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "addNL" ((PVar "p")) (EBinOp "++" (EVar "p") (EVar "nl")))
(DTypeSig false "nl" (TyCon "String"))
(DFunDef false "nl" () (ELit (LString "\n")))
(DTypeSig true "unwords" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "unwords" ((PVar "parts")) (EApp (EApp (EVar "join") (ELit (LString " "))) (EVar "parts")))
(DTypeSig true "padLeft" (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "padLeft" ((PVar "n") (PVar "c") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "n")) (EVar "s") (EBinOp "++" (EApp (EVar "stringConcat") (EApp (EApp (EVar "replic") (EBinOp "-" (EVar "n") (EApp (EVar "stringLength") (EVar "s")))) (EApp (EVar "charToStr") (EVar "c")))) (EVar "s"))))
(DTypeSig true "padRight" (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "padRight" ((PVar "n") (PVar "c") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "n")) (EVar "s") (EBinOp "++" (EVar "s") (EApp (EVar "stringConcat") (EApp (EApp (EVar "replic") (EBinOp "-" (EVar "n") (EApp (EVar "stringLength") (EVar "s")))) (EApp (EVar "charToStr") (EVar "c")))))))
(DTypeSig true "center" (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "center" ((PVar "n") (PVar "c") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "n")) (EVar "s") (EApp (EApp (EApp (EApp (EVar "centerPad") (EApp (EVar "half") (EBinOp "-" (EVar "n") (EApp (EVar "stringLength") (EVar "s"))))) (EBinOp "-" (EBinOp "-" (EVar "n") (EApp (EVar "stringLength") (EVar "s"))) (EApp (EVar "half") (EBinOp "-" (EVar "n") (EApp (EVar "stringLength") (EVar "s")))))) (EVar "c")) (EVar "s"))))
(DTypeSig false "centerPad" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "centerPad" ((PVar "l") (PVar "r") (PVar "c") (PVar "s")) (EBinOp "++" (EBinOp "++" (EApp (EVar "stringConcat") (EApp (EApp (EVar "replic") (EVar "l")) (EApp (EVar "charToStr") (EVar "c")))) (EVar "s")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "replic") (EVar "r")) (EApp (EVar "charToStr") (EVar "c"))))))
(DTypeSig false "half" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "half" ((PVar "k")) (EIf (EBinOp "<=" (EVar "k") (ELit (LInt 1))) (ELit (LInt 0)) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "half") (EBinOp "-" (EVar "k") (ELit (LInt 2)))))))
