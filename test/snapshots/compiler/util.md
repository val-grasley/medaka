# META
source_lines=454
stages=DESUGAR,MARK
# SOURCE
-- Shared internal helpers for the self-hosted compiler stages.  compiler
-- deliberately avoids the standard library (see AGENTS.md for why), so the small
-- list/string/option utilities every stage needs live here once instead of being
-- re-implemented per file.  All stages — typecheck.mdk included — import from here;
-- when you need a generic helper, add it here rather than hand-rolling a local copy.
-- Companion themed modules: support/char.mdk (ASCII char predicates),
-- support/path.mdk (filesystem path string ops), support/ordmap.mdk (OrdMap).

import support.ordmap.{OrdMap, omLookup, omInsert, omEmpty}
import list.{reverse, zip}
import string.{join}

export contains : String -> List String -> Bool
contains _ [] = False
contains x (y::ys) = x == y || contains x ys

export listLen : List a -> Int
listLen [] = 0
listLen (_::xs) = 1 + listLen xs

export reverseL : List a -> List a
reverseL xs = reverse xs

export anyList : (a -> Bool) -> List a -> Bool
anyList _ [] = False
anyList p (x::xs) = p x || anyList p xs

export allList : (a -> Bool) -> List a -> Bool
allList _ [] = True
allList p (x::xs) = p x && allList p xs

-- first value bound to a String key in an association list
export lookupAssoc : String -> List (String, b) -> Option b
lookupAssoc _ [] = None
lookupAssoc k ((k2, v)::rest)
  | k == k2 = Some v
  | otherwise = lookupAssoc k rest

-- Join string pieces with a separator.  Delegates to stdlib `string.join`
-- (`stringConcat (intersperse sep parts)` — the same O(total length) one-pass
-- build util used to hand-roll via intersperseStr).  Kept as a named export so
-- the compiler consumers stay unedited.  Importing `string` is near-free here:
-- String's instances live in `core` (always-present prelude), so the import adds
-- no new instance surface — only `join` itself (2026-06-30 util migration note).
export joinWith : String -> List String -> String
joinWith sep xs = join sep xs

export joinNl : List String -> String
joinNl xs = joinWith "\n" xs

-- Split a string on '\n' into its lines.  No newline is retained; a trailing
-- '\n' yields a final empty string, and the empty string yields [""].  Inverse
-- of joinNl on newline-free pieces.  (Centralizes the latent splitNl cluster —
-- see HELPER-CENSUS.md — used by the formatter to interleave inner-block
-- trailing comments into a rendered decl's output lines.)
export splitNl : String -> List String
splitNl s =
  let chars = stringToChars s
  splitNlGo chars (arrayLength chars) 0 0

splitNlGo : Array Char -> Int -> Int -> Int -> List String
splitNlGo chars n start i
  | i >= n = [stringFromChars (arraySubChars chars start n)]
  | arrayGetUnsafe i chars == '\n' = stringFromChars (arraySubChars chars start i) :: splitNlGo chars n (i + 1) (i + 1)
  | otherwise = splitNlGo chars n start (i + 1)

-- Split a string on a given character.  Like splitNl but parameterised on the
-- separator.  An empty string yields [""] (one empty segment); a trailing
-- separator yields a final empty string.
export splitOnChar : Char -> String -> List String
splitOnChar sep s =
  let chars = stringToChars s
  splitOnCharGo chars sep (arrayLength chars) 0 0

splitOnCharGo : Array Char -> Char -> Int -> Int -> Int -> List String
splitOnCharGo chars sep n start i
  | i >= n = [stringFromChars (arraySubChars chars start n)]
  | arrayGetUnsafe i chars == sep = stringFromChars (arraySubChars chars start i) :: splitOnCharGo chars sep n (i + 1) (i + 1)
  | otherwise = splitOnCharGo chars sep n start (i + 1)

-- Join dotted path components with "." in O(total length) (see joinWith).
export joinDot : List String -> String
joinDot xs = joinWith "." xs

-- canonical for #242/#243: order-preserving dedup keeping the FIRST occurrence
-- (NOT sorted), generalized over a String key projection.  Uses the shared
-- support.ordmap weight-balanced tree as a `seen` set for O(log n) membership →
-- O(n·log n) overall, vs the naive O(n²) list-scan copies the stages carry.
-- This is the shared migration target other stages route their dedup/dedupBy
-- clones through.  Keep it monomorphic (no prelude Foldable delegation) — `dedup`
-- runs on HOT paths.
export dedupBy : (a -> String) -> List a -> List a
dedupBy key xs = dedupByGo key xs omEmpty

dedupByGo : (a -> String) -> List a -> OrdMap Unit -> List a
dedupByGo _ [] _ = []
dedupByGo key (x::xs) seen = match omLookup (key x) seen
  Some _ => dedupByGo key xs seen
  None => x :: dedupByGo key xs (omInsert (key x) () seen)

-- canonical for #242/#243: the String-identity specialization of `dedupBy`.
-- Kept so existing `dedup` callers are unchanged.
export dedup : List String -> List String
dedup xs = dedupBy identity xs

-- Split a list into its leading prefix and final element: Some (init, last),
-- or None for the empty list.  (Was duplicated byte-identically across ~10
-- entry mains.)
export splitLast : List a -> Option (List a, a)
splitLast [] = None
splitLast [x] = Some ([], x)
splitLast (x::rest) = map ((init, lst) => (x::init, lst)) (splitLast rest)

-- minimal string escaping for the structural / diagnostic dumps (matches
-- dev/astdump.ml's esc_str and dev/diagdump.ml): backslash, quote, \n \t \r.
export escStr : String -> String
escStr s = "\"" ++ stringConcat (escFrom (stringToChars s) 0) ++ "\""

-- Collect the per-character escapes into a list and let `stringConcat` join
-- them in one pass, rather than the old per-char `escOne c ++ escFrom …` that
-- re-copied the growing tail (O(n^2) in the escaped length).
escFrom : Array Char -> Int -> List String
escFrom cs i
  | i >= arrayLength cs = []
  | otherwise = escOne (arrayGetUnsafe i cs) :: escFrom cs (i + 1)

escOne : Char -> String
-- Escapes NUL and every other C0 control char rather than passing it through raw.
-- Its twin in printer.mdk did NOT, and `medaka fmt` consequently wrote a literal NUL
-- byte into printer.mdk's own source — which made the file BINARY to grep, so
-- `grep printDecl printer.mdk` silently found nothing on a file with 34 matches.
-- See the long note at printer.mdk's escStringLit. Keep these two in lockstep.
--
-- Intentional cross-file duplicate of the same helper in printer.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
escOne c
  | c == '\\' = "\\\\"
  | c == '"' = "\\\""
  | c == '\n' = "\\n"
  | c == '\t' = "\\t"
  | c == '\r' = "\\r"
  | c == '\0' = "\\0"
  | charCode c < 32 = "\\u{\{escOneHex2 (charCode c)}}"
  | otherwise = charToStr c

-- Shared with printer.mdk's escSOne (which imports it). escOne/escSOne are a
-- deliberate divergent-by-design pair, but the hex digits are not — one copy.
export escOneHex2 : Int -> String
escOneHex2 b = escOneHexDigit (b / 16) ++ escOneHexDigit (b % 16)

escOneHexDigit : Int -> String
escOneHexDigit d
  | d < 10 = intToString d
  | d == 10 = "a"
  | d == 11 = "b"
  | d == 12 = "c"
  | d == 13 = "d"
  | d == 14 = "e"
  | otherwise = "f"

-- ── More generic list/option/string/int helpers ───────────────────────────

export isEmptyL : List a -> Bool
isEmptyL [] = True
isEmptyL _ = False

export isNonEmptyL : List a -> Bool
isNonEmptyL xs = not (isEmptyL xs)

export filterList : (a -> Bool) -> List a -> List a
filterList _ [] = []
filterList p (x::xs)
  | p x = x :: filterList p xs
  | otherwise = filterList p xs

export initList : List a -> List a
initList [] = []
initList [_] = []
initList (x::xs) = x :: initList xs

export zipL : List a -> List b -> List (a, b)
zipL xs ys = zip xs ys

export maxI : Int -> Int -> Int
-- Intentional: this IS the compiler's hot monomorphic Int max (AGENTS.md
-- anti-pattern: don't delegate hot inner-loop helpers to the dict-passed
-- prelude Ord method).
-- lint-disable-next-line rule-if-max-min
maxI a b = if a >= b then a else b

export minI : Int -> Int -> Int
-- Intentional: see maxI above.
-- lint-disable-next-line rule-if-max-min
minI a b = if a <= b then a else b

-- Levenshtein edit distance between two strings (unit insert/delete/substitute
-- cost).  Classic two-row dynamic-programming over the target chars — O(|a|·|b|)
-- time, O(|b|) space.  Used by resolve.mdk to suggest a near "did you mean"
-- name for an unbound reference.
export editDistance : String -> String -> Int
editDistance a b =
  let bs = arrCharList (stringToChars b) 0
  editLastInt (editLoop
    (arrCharList (stringToChars a) 0)
    bs
    1
    (editInitRow 0 bs))

-- stringToChars yields an Array Char; the DP below walks lists, so materialize
arrCharList : Array Char -> Int -> List Char
arrCharList cs i
  | i >= arrayLength cs = []
  | otherwise = arrayGetUnsafe i cs :: arrCharList cs (i + 1)

-- prev-row seed: [0, 1, 2, …, |bs|]
editInitRow : Int -> List Char -> List Int
editInitRow k [] = [k]
editInitRow k (_::cs) = k :: editInitRow (k + 1) cs

-- fold each source char over the previous row, producing the next row
editLoop : List Char -> List Char -> Int -> List Int -> List Int
editLoop [] _ _ prev = prev
editLoop (ac::acs) bs i (p0::prest) =
  editLoop acs bs (i + 1) (i :: editRow ac bs i p0 prest)
editLoop (_::_) _ _ [] = []

-- build one new row: `left` = newRow[j-1], `diag` = prev[j-1], `prevRest` = prev[j..]
editRow : Char -> List Char -> Int -> Int -> List Int -> List Int
editRow ac (bc::bcs) left diag (pj::pjs) =
  let cost = if ac == bc then 0 else 1
  let v = minI (minI (left + 1) (pj + 1)) (diag + cost)
  v :: editRow ac bcs v pj pjs
editRow _ _ _ _ _ = []

editLastInt : List Int -> Int
editLastInt [] = 0
editLastInt [x] = x
editLastInt (_::xs) = editLastInt xs

-- prefix/suffix tests: (prefix/suffix, string) argument order.
export startsWith : String -> String -> Bool
startsWith pre s =
  let n = stringLength pre
  n <= stringLength s && stringSlice 0 n s == pre

export endsWith : String -> String -> Bool
endsWith suf s =
  let n = stringLength s
  let k = stringLength suf
  k <= n && stringSlice (n - k) n s == suf

-- ── scheme-dump line head ────────────────────────────────────────────────
-- The name a `"name : scheme"` dump line binds: everything before the FIRST
-- " : " separator, or None when the line has none (e.g. a blank line).
--
-- An identifier can never contain a space, so this head is the ONLY name for
-- which `startsWith "\{name} : " line` could hold.  That lets a caller test
-- "does this line name one of my bindings?" with a single set lookup instead
-- of scanning every candidate name per line — see medaka_cli's userSchemeLines,
-- which was O(lines × names) before.  Linear in the line's length.
export schemeLineName : String -> Option String
schemeLineName l = schemeLineNameGo l 0 (stringLength l)

schemeLineNameGo : String -> Int -> Int -> Option String
schemeLineNameGo l i n
  | i + 3 > n = None
  | stringSlice i (i + 3) l == " : " = Some (stringSlice 0 i l)
  | otherwise = schemeLineNameGo l (i + 1) n

-- NOTE (#243): this `isSome` duplicates the prelude's `isSome` (stdlib/core.mdk)
-- byte-identically and is a deletion candidate — BUT the LOCKED typecheck.mdk
-- imports it by name (`import support.util.{… isSome …}`, typecheck.mdk:94), so
-- deleting it here breaks that import.  Blocked on the ws:typecheck arc (#160)
-- dropping `isSome` from typecheck.mdk's import list first; then delete this.
export isSome : Option a -> Bool
isSome (Some _) = True
isSome None = False

export mapOption : (a -> b) -> Option a -> Option b
mapOption _ None = None
mapOption f (Some x) = Some (f x)

export orElseOpt : Option a -> Option a -> Option a
orElseOpt (Some x) _ = Some x
orElseOpt None y = y

-- ── Whitespace trim (O(n) char-array scan) ────────────────────────────────
-- Strip leading + trailing ASCII whitespace (space/tab/newline/CR).  Scans the
-- backing char array once per side rather than recursing on stringSlice (which
-- re-copies the shrinking string each step, O(n^2)).

isWs : String -> Bool
isWs " " = True
isWs "\t" = True
isWs "\n" = True
isWs "\r" = True
isWs _ = False

arraySubChars : Array Char -> Int -> Int -> Array Char
arraySubChars chars lo hi =
  arrayMakeWith (hi - lo) (i => arrayGetUnsafe (lo + i) chars)

trimLeftGo : Array Char -> Int -> Int -> String
trimLeftGo chars i len
  | i >= len = ""
  | isWs (charToStr (arrayGetUnsafe i chars)) = trimLeftGo chars (i + 1) len
  | otherwise = stringFromChars (arraySubChars chars i len)

trimRightGo : Array Char -> Int -> String
trimRightGo chars end
  | end <= 0 = ""
  | isWs (charToStr (arrayGetUnsafe (end - 1) chars)) =
    trimRightGo chars (end - 1)
  | otherwise = stringFromChars (arraySubChars chars 0 end)

export stringTrimLeft : String -> String
stringTrimLeft s =
  let chars = stringToChars s
  let len = arrayLength chars
  trimLeftGo chars 0 len

export stringTrimRight : String -> String
stringTrimRight s =
  let chars = stringToChars s
  let len = arrayLength chars
  trimRightGo chars len

export stringTrim : String -> String
stringTrim s = stringTrimRight (stringTrimLeft s)

-- ── sorted-unique String list (insertion sort, dedups equal keys) ─────────
export sortUniqS : List String -> List String
sortUniqS xs = sortUniqSGo xs []

sortUniqSGo : List String -> List String -> List String
sortUniqSGo [] acc = acc
sortUniqSGo (x::xs) acc = sortUniqSGo xs (sortInsertS x acc)

sortInsertS : String -> List String -> List String
sortInsertS x [] = [x]
sortInsertS x (y::ys) = match stringCompare x y
  Lt => x :: y::ys
  Eq => y::ys
  Gt => y :: sortInsertS x ys

-- ── UTF-8 byte width ──────────────────────────────────────────────────────
-- Content-Length frames count bytes; strings count codepoints — sum each
-- codepoint's encoded width.
export utf8CharWidth : Int -> Int
utf8CharWidth cp
  | cp < 128 = 1
  | cp < 2048 = 2
  | cp < 65536 = 3
  | otherwise = 4

utf8LenGo : Array Char -> Int -> Int -> Int -> Int
utf8LenGo arr len i acc
  | i >= len = acc
  | otherwise = utf8LenGo arr len (i + 1) (acc + utf8CharWidth (charCode (arrayGetUnsafe i arr)))

export utf8Len : String -> Int
utf8Len s =
  let arr = stringToChars s
  utf8LenGo arr (arrayLength arr) 0 0

-- ── Decimal-integer magnitude compare + overflow-checked parse ────────────
-- The 63-bit tagged `Int` (runtime/medaka_rt.c) WRAPS on overflow, so a literal
-- consumer cannot detect an out-of-range value by parsing it — the arithmetic
-- silently wraps.  These helpers work on the digit STRING instead: compare
-- magnitudes without arithmetic, and parse only after that compare proves the
-- value fits.  Both assume ASCII decimal digits '0'..'9' (`parseDecChecked` also
-- skips '_' group separators); neither validates non-digit input.

-- Index of the first significant digit (leading zeros skipped), but never past
-- the last char, so an all-zero string normalizes to a single "0".
decMagFirstSig : Array Char -> Int -> Int -> Int
decMagFirstSig cs n i
  | i + 1 >= n = i
  | arrayGetUnsafe i cs == '0' = decMagFirstSig cs n (i + 1)
  | otherwise = i

decMagNorm : String -> String
decMagNorm s =
  let cs = stringToChars s
  let n = arrayLength cs
  stringFromChars (arraySubChars cs (decMagFirstSig cs n 0) n)

{- | Compare two decimal digit strings by numeric magnitude, ignoring leading
     zeros.  At equal significant length ASCII order coincides with numeric
     order, so this needs no arithmetic and therefore never wraps.

     > compareDecMag "42" "9"
     Gt
     > compareDecMag "007" "7"
     Eq
     > compareDecMag "123" "1230"
     Lt -}
export compareDecMag : String -> String -> Ordering
compareDecMag a b =
  let na = decMagNorm a
  let nb = decMagNorm b
  let la = stringLength na
  let lb = stringLength nb
  if la < lb then Lt else if la > lb then Gt else stringCompare na nb

decDigitsNoUs : Array Char -> Int -> Int -> List Char
decDigitsNoUs cs n i
  | i >= n = []
  | arrayGetUnsafe i cs == '_' = decDigitsNoUs cs n (i + 1)
  | otherwise = arrayGetUnsafe i cs :: decDigitsNoUs cs n (i + 1)

decFold : List Char -> Int -> Int
decFold [] acc = acc
decFold (c::cs) acc = decFold cs (acc * 10 + (charCode c - 48))

{- | Parse a decimal integer string to `Int`, or `None` when its magnitude
     exceeds the positive `Int` maximum (2^62 - 1 = 4611686018427387903) — the
     range in which naive accumulation would silently WRAP.  '_' group separators
     and leading zeros are accepted; the input is assumed ASCII digits otherwise.

     > parseDecChecked "1_000"
     Some 1000
     > parseDecChecked "007"
     Some 7
     > parseDecChecked "4611686018427387903"
     Some 4611686018427387903
     > parseDecChecked "4611686018427387904"
     None -}
export parseDecChecked : String -> Option Int
parseDecChecked s =
  let cs = stringToChars s
  let n = arrayLength cs
  let digs = decDigitsNoUs cs n 0
  let ds = stringFromChars (arrayFromList digs)
  if compareDecMag ds "4611686018427387903" == Gt then
    None
  else
    Some (decFold digs 0)

-- ── Canonical compiler-internal names ─────────────────────────────────────
-- Names produced in one stage and consumed in another (cross-module contract);
-- defined once here so the stages can't silently drift out of agreement.

-- The guard-desugar fallthrough sentinel: desugar emits `EVar fallthroughName`
-- as a non-exhaustive-match trap, eval binds it to a VFallthrough prim, and the
-- emitter intercepts it in emitApp.  All three MUST use the same string.
export fallthroughName : String
fallthroughName = "__fallthrough__"

-- Default head-tag for a None with no resolved type-constructor head; both the
-- interpreter (eval) and the IR lowering compute dispatch off it, so they must
-- agree on the literal.
export noneHeadTag : String
noneHeadTag = "__none__"
# DESUGAR
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omLookup" false) (mem "omInsert" false) (mem "omEmpty" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false) (mem "zip" false))))
(DUse false (UseGroup ("string") ((mem "join" false))))
(DTypeSig true "contains" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "contains" (PWild (PList)) (EVar "False"))
(DFunDef false "contains" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "contains") (EVar "x")) (EVar "ys"))))
(DTypeSig true "listLen" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")))
(DFunDef false "listLen" ((PList)) (ELit (LInt 0)))
(DFunDef false "listLen" ((PCons PWild (PVar "xs"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "listLen") (EVar "xs"))))
(DTypeSig true "reverseL" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "reverseL" ((PVar "xs")) (EApp (EVar "reverse") (EVar "xs")))
(DTypeSig true "anyList" (TyFun (TyFun (TyVar "a") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "anyList" (PWild (PList)) (EVar "False"))
(DFunDef false "anyList" ((PVar "p") (PCons (PVar "x") (PVar "xs"))) (EBinOp "||" (EApp (EVar "p") (EVar "x")) (EApp (EApp (EVar "anyList") (EVar "p")) (EVar "xs"))))
(DTypeSig true "allList" (TyFun (TyFun (TyVar "a") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "allList" (PWild (PList)) (EVar "True"))
(DFunDef false "allList" ((PVar "p") (PCons (PVar "x") (PVar "xs"))) (EBinOp "&&" (EApp (EVar "p") (EVar "x")) (EApp (EApp (EVar "allList") (EVar "p")) (EVar "xs"))))
(DTypeSig true "lookupAssoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "b"))) (TyApp (TyCon "Option") (TyVar "b")))))
(DFunDef false "lookupAssoc" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupAssoc" ((PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "k2")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupAssoc") (EVar "k")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "joinWith" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "joinWith" ((PVar "sep") (PVar "xs")) (EApp (EApp (EVar "join") (EVar "sep")) (EVar "xs")))
(DTypeSig true "joinNl" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinNl" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "xs")))
(DTypeSig true "splitNl" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitNl" ((PVar "s")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "splitNlGo") (EVar "chars")) (EApp (EVar "arrayLength") (EVar "chars"))) (ELit (LInt 0))) (ELit (LInt 0))))))
(DTypeSig false "splitNlGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "splitNlGo" ((PVar "chars") (PVar "n") (PVar "start") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "arraySubChars") (EVar "chars")) (EVar "start")) (EVar "n")))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (ELit (LChar "\n"))) (EBinOp "::" (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "arraySubChars") (EVar "chars")) (EVar "start")) (EVar "i"))) (EApp (EApp (EApp (EApp (EVar "splitNlGo") (EVar "chars")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "splitNlGo") (EVar "chars")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "splitOnChar" (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "splitOnChar" ((PVar "sep") (PVar "s")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "splitOnCharGo") (EVar "chars")) (EVar "sep")) (EApp (EVar "arrayLength") (EVar "chars"))) (ELit (LInt 0))) (ELit (LInt 0))))))
(DTypeSig false "splitOnCharGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Char") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitOnCharGo" ((PVar "chars") (PVar "sep") (PVar "n") (PVar "start") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "arraySubChars") (EVar "chars")) (EVar "start")) (EVar "n")))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (EVar "sep")) (EBinOp "::" (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "arraySubChars") (EVar "chars")) (EVar "start")) (EVar "i"))) (EApp (EApp (EApp (EApp (EApp (EVar "splitOnCharGo") (EVar "chars")) (EVar "sep")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "splitOnCharGo") (EVar "chars")) (EVar "sep")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "joinDot" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinDot" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "xs")))
(DTypeSig true "dedupBy" (TyFun (TyFun (TyVar "a") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "dedupBy" ((PVar "key") (PVar "xs")) (EApp (EApp (EApp (EVar "dedupByGo") (EVar "key")) (EVar "xs")) (EVar "omEmpty")))
(DTypeSig false "dedupByGo" (TyFun (TyFun (TyVar "a") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "dedupByGo" (PWild (PList) PWild) (EListLit))
(DFunDef false "dedupByGo" ((PVar "key") (PCons (PVar "x") (PVar "xs")) (PVar "seen")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "key") (EVar "x"))) (EVar "seen")) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EVar "dedupByGo") (EVar "key")) (EVar "xs")) (EVar "seen"))) (arm (PCon "None") () (EBinOp "::" (EVar "x") (EApp (EApp (EApp (EVar "dedupByGo") (EVar "key")) (EVar "xs")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "key") (EVar "x"))) (ELit LUnit)) (EVar "seen")))))))
(DTypeSig true "dedup" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dedup" ((PVar "xs")) (EApp (EApp (EVar "dedupBy") (EVar "identity")) (EVar "xs")))
(DTypeSig true "splitLast" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyVar "a")))))
(DFunDef false "splitLast" ((PList)) (EVar "None"))
(DFunDef false "splitLast" ((PList (PVar "x"))) (EApp (EVar "Some") (ETuple (EListLit) (EVar "x"))))
(DFunDef false "splitLast" ((PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "init") (PVar "lst"))) (ETuple (EBinOp "::" (EVar "x") (EVar "init")) (EVar "lst")))) (EApp (EVar "splitLast") (EVar "rest"))))
(DTypeSig true "escStr" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escStr" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "escFrom") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))))) (ELit (LString "\""))))
(DTypeSig false "escFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "escFrom" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "escOne") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EVar "escFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "escOne" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "escOne" ((PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\\"))) (ELit (LString "\\\\")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (ELit (LString "\\\"")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\n"))) (ELit (LString "\\n")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\t"))) (ELit (LString "\\t")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\r"))) (ELit (LString "\\r")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\0"))) (ELit (LString "\\0")) (EIf (EBinOp "<" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 32))) (EBinOp "++" (EBinOp "++" (ELit (LString "\\u{")) (EApp (EVar "display") (EApp (EVar "escOneHex2") (EApp (EVar "charCode") (EVar "c"))))) (ELit (LString "}"))) (EIf (EVar "otherwise") (EApp (EVar "charToStr") (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig true "escOneHex2" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "escOneHex2" ((PVar "b")) (EBinOp "++" (EApp (EVar "escOneHexDigit") (EBinOp "/" (EVar "b") (ELit (LInt 16)))) (EApp (EVar "escOneHexDigit") (EBinOp "%" (EVar "b") (ELit (LInt 16))))))
(DTypeSig false "escOneHexDigit" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "escOneHexDigit" ((PVar "d")) (EIf (EBinOp "<" (EVar "d") (ELit (LInt 10))) (EApp (EVar "intToString") (EVar "d")) (EIf (EBinOp "==" (EVar "d") (ELit (LInt 10))) (ELit (LString "a")) (EIf (EBinOp "==" (EVar "d") (ELit (LInt 11))) (ELit (LString "b")) (EIf (EBinOp "==" (EVar "d") (ELit (LInt 12))) (ELit (LString "c")) (EIf (EBinOp "==" (EVar "d") (ELit (LInt 13))) (ELit (LString "d")) (EIf (EBinOp "==" (EVar "d") (ELit (LInt 14))) (ELit (LString "e")) (EIf (EVar "otherwise") (ELit (LString "f")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig true "isEmptyL" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isEmptyL" ((PList)) (EVar "True"))
(DFunDef false "isEmptyL" (PWild) (EVar "False"))
(DTypeSig true "isNonEmptyL" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isNonEmptyL" ((PVar "xs")) (EApp (EVar "not") (EApp (EVar "isEmptyL") (EVar "xs"))))
(DTypeSig true "filterList" (TyFun (TyFun (TyVar "a") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "filterList" (PWild (PList)) (EListLit))
(DFunDef false "filterList" ((PVar "p") (PCons (PVar "x") (PVar "xs"))) (EIf (EApp (EVar "p") (EVar "x")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "filterList") (EVar "p")) (EVar "xs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterList") (EVar "p")) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "initList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "initList" ((PList)) (EListLit))
(DFunDef false "initList" ((PList PWild)) (EListLit))
(DFunDef false "initList" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EApp (EVar "initList") (EVar "xs"))))
(DTypeSig true "zipL" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b"))))))
(DFunDef false "zipL" ((PVar "xs") (PVar "ys")) (EApp (EApp (EVar "zip") (EVar "xs")) (EVar "ys")))
(DTypeSig true "maxI" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "maxI" ((PVar "a") (PVar "b")) (EIf (EBinOp ">=" (EVar "a") (EVar "b")) (EVar "a") (EVar "b")))
(DTypeSig true "minI" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "minI" ((PVar "a") (PVar "b")) (EIf (EBinOp "<=" (EVar "a") (EVar "b")) (EVar "a") (EVar "b")))
(DTypeSig true "editDistance" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "editDistance" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "bs") (EApp (EApp (EVar "arrCharList") (EApp (EVar "stringToChars") (EVar "b"))) (ELit (LInt 0)))) (DoExpr (EApp (EVar "editLastInt") (EApp (EApp (EApp (EApp (EVar "editLoop") (EApp (EApp (EVar "arrCharList") (EApp (EVar "stringToChars") (EVar "a"))) (ELit (LInt 0)))) (EVar "bs")) (ELit (LInt 1))) (EApp (EApp (EVar "editInitRow") (ELit (LInt 0))) (EVar "bs")))))))
(DTypeSig false "arrCharList" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char")))))
(DFunDef false "arrCharList" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (EApp (EApp (EVar "arrCharList") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "editInitRow" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "editInitRow" ((PVar "k") (PList)) (EListLit (EVar "k")))
(DFunDef false "editInitRow" ((PVar "k") (PCons PWild (PVar "cs"))) (EBinOp "::" (EVar "k") (EApp (EApp (EVar "editInitRow") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "cs"))))
(DTypeSig false "editLoop" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "editLoop" ((PList) PWild PWild (PVar "prev")) (EVar "prev"))
(DFunDef false "editLoop" ((PCons (PVar "ac") (PVar "acs")) (PVar "bs") (PVar "i") (PCons (PVar "p0") (PVar "prest"))) (EApp (EApp (EApp (EApp (EVar "editLoop") (EVar "acs")) (EVar "bs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EApp (EApp (EVar "editRow") (EVar "ac")) (EVar "bs")) (EVar "i")) (EVar "p0")) (EVar "prest")))))
(DFunDef false "editLoop" ((PCons PWild PWild) PWild PWild (PList)) (EListLit))
(DTypeSig false "editRow" (TyFun (TyCon "Char") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "editRow" ((PVar "ac") (PCons (PVar "bc") (PVar "bcs")) (PVar "left") (PVar "diag") (PCons (PVar "pj") (PVar "pjs"))) (EBlock (DoLet false false (PVar "cost") (EIf (EBinOp "==" (EVar "ac") (EVar "bc")) (ELit (LInt 0)) (ELit (LInt 1)))) (DoLet false false (PVar "v") (EApp (EApp (EVar "minI") (EApp (EApp (EVar "minI") (EBinOp "+" (EVar "left") (ELit (LInt 1)))) (EBinOp "+" (EVar "pj") (ELit (LInt 1))))) (EBinOp "+" (EVar "diag") (EVar "cost")))) (DoExpr (EBinOp "::" (EVar "v") (EApp (EApp (EApp (EApp (EApp (EVar "editRow") (EVar "ac")) (EVar "bcs")) (EVar "v")) (EVar "pj")) (EVar "pjs"))))))
(DFunDef false "editRow" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "editLastInt" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "editLastInt" ((PList)) (ELit (LInt 0)))
(DFunDef false "editLastInt" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "editLastInt" ((PCons PWild (PVar "xs"))) (EApp (EVar "editLastInt") (EVar "xs")))
(DTypeSig true "startsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "startsWith" ((PVar "pre") (PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "pre"))) (DoExpr (EBinOp "&&" (EBinOp "<=" (EVar "n") (EApp (EVar "stringLength") (EVar "s"))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "n")) (EVar "s")) (EVar "pre"))))))
(DTypeSig true "endsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "endsWith" ((PVar "suf") (PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoLet false false (PVar "k") (EApp (EVar "stringLength") (EVar "suf"))) (DoExpr (EBinOp "&&" (EBinOp "<=" (EVar "k") (EVar "n")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (EVar "k"))) (EVar "n")) (EVar "s")) (EVar "suf"))))))
(DTypeSig true "schemeLineName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "schemeLineName" ((PVar "l")) (EApp (EApp (EApp (EVar "schemeLineNameGo") (EVar "l")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "l"))))
(DTypeSig false "schemeLineNameGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "schemeLineNameGo" ((PVar "l") (PVar "i") (PVar "n")) (EIf (EBinOp ">" (EBinOp "+" (EVar "i") (ELit (LInt 3))) (EVar "n")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 3)))) (EVar "l")) (ELit (LString " : "))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "l"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "schemeLineNameGo") (EVar "l")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "isSome" (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isSome" ((PCon "Some" PWild)) (EVar "True"))
(DFunDef false "isSome" ((PCon "None")) (EVar "False"))
(DTypeSig true "mapOption" (TyFun (TyFun (TyVar "a") (TyVar "b")) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "b")))))
(DFunDef false "mapOption" (PWild (PCon "None")) (EVar "None"))
(DFunDef false "mapOption" ((PVar "f") (PCon "Some" (PVar "x"))) (EApp (EVar "Some") (EApp (EVar "f") (EVar "x"))))
(DTypeSig true "orElseOpt" (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "orElseOpt" ((PCon "Some" (PVar "x")) PWild) (EApp (EVar "Some") (EVar "x")))
(DFunDef false "orElseOpt" ((PCon "None") (PVar "y")) (EVar "y"))
(DTypeSig false "isWs" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isWs" ((PLit (LString " "))) (EVar "True"))
(DFunDef false "isWs" ((PLit (LString "\t"))) (EVar "True"))
(DFunDef false "isWs" ((PLit (LString "\n"))) (EVar "True"))
(DFunDef false "isWs" ((PLit (LString "\r"))) (EVar "True"))
(DFunDef false "isWs" (PWild) (EVar "False"))
(DTypeSig false "arraySubChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Char"))))))
(DFunDef false "arraySubChars" ((PVar "chars") (PVar "lo") (PVar "hi")) (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "hi") (EVar "lo"))) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "lo") (EVar "i"))) (EVar "chars")))))
(DTypeSig false "trimLeftGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "trimLeftGo" ((PVar "chars") (PVar "i") (PVar "len")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (ELit (LString "")) (EIf (EApp (EVar "isWs") (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")))) (EApp (EApp (EApp (EVar "trimLeftGo") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EIf (EVar "otherwise") (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "arraySubChars") (EVar "chars")) (EVar "i")) (EVar "len"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "trimRightGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "trimRightGo" ((PVar "chars") (PVar "end")) (EIf (EBinOp "<=" (EVar "end") (ELit (LInt 0))) (ELit (LString "")) (EIf (EApp (EVar "isWs") (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "end") (ELit (LInt 1)))) (EVar "chars")))) (EApp (EApp (EVar "trimRightGo") (EVar "chars")) (EBinOp "-" (EVar "end") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "arraySubChars") (EVar "chars")) (ELit (LInt 0))) (EVar "end"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "stringTrimLeft" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stringTrimLeft" ((PVar "s")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "chars"))) (DoExpr (EApp (EApp (EApp (EVar "trimLeftGo") (EVar "chars")) (ELit (LInt 0))) (EVar "len")))))
(DTypeSig true "stringTrimRight" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stringTrimRight" ((PVar "s")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "chars"))) (DoExpr (EApp (EApp (EVar "trimRightGo") (EVar "chars")) (EVar "len")))))
(DTypeSig true "stringTrim" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stringTrim" ((PVar "s")) (EApp (EVar "stringTrimRight") (EApp (EVar "stringTrimLeft") (EVar "s"))))
(DTypeSig true "sortUniqS" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "sortUniqS" ((PVar "xs")) (EApp (EApp (EVar "sortUniqSGo") (EVar "xs")) (EListLit)))
(DTypeSig false "sortUniqSGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "sortUniqSGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "sortUniqSGo" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "sortUniqSGo") (EVar "xs")) (EApp (EApp (EVar "sortInsertS") (EVar "x")) (EVar "acc"))))
(DTypeSig false "sortInsertS" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "sortInsertS" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "sortInsertS" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EMatch (EApp (EApp (EVar "stringCompare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys")))) (arm (PCon "Eq") () (EBinOp "::" (EVar "y") (EVar "ys"))) (arm (PCon "Gt") () (EBinOp "::" (EVar "y") (EApp (EApp (EVar "sortInsertS") (EVar "x")) (EVar "ys"))))))
(DTypeSig true "utf8CharWidth" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "utf8CharWidth" ((PVar "cp")) (EIf (EBinOp "<" (EVar "cp") (ELit (LInt 128))) (ELit (LInt 1)) (EIf (EBinOp "<" (EVar "cp") (ELit (LInt 2048))) (ELit (LInt 2)) (EIf (EBinOp "<" (EVar "cp") (ELit (LInt 65536))) (ELit (LInt 3)) (EIf (EVar "otherwise") (ELit (LInt 4)) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "utf8LenGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "utf8LenGo" ((PVar "arr") (PVar "len") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "utf8LenGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (EApp (EVar "utf8CharWidth") (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "utf8Len" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "utf8Len" ((PVar "s")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "utf8LenGo") (EVar "arr")) (EApp (EVar "arrayLength") (EVar "arr"))) (ELit (LInt 0))) (ELit (LInt 0))))))
(DTypeSig false "decMagFirstSig" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "decMagFirstSig" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EVar "i") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "0"))) (EApp (EApp (EApp (EVar "decMagFirstSig") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "decMagNorm" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "decMagNorm" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "arraySubChars") (EVar "cs")) (EApp (EApp (EApp (EVar "decMagFirstSig") (EVar "cs")) (EVar "n")) (ELit (LInt 0)))) (EVar "n"))))))
(DTypeSig true "compareDecMag" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Ordering"))))
(DFunDef false "compareDecMag" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "na") (EApp (EVar "decMagNorm") (EVar "a"))) (DoLet false false (PVar "nb") (EApp (EVar "decMagNorm") (EVar "b"))) (DoLet false false (PVar "la") (EApp (EVar "stringLength") (EVar "na"))) (DoLet false false (PVar "lb") (EApp (EVar "stringLength") (EVar "nb"))) (DoExpr (EIf (EBinOp "<" (EVar "la") (EVar "lb")) (EVar "Lt") (EIf (EBinOp ">" (EVar "la") (EVar "lb")) (EVar "Gt") (EApp (EApp (EVar "stringCompare") (EVar "na")) (EVar "nb")))))))
(DTypeSig false "decDigitsNoUs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "decDigitsNoUs" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "_"))) (EApp (EApp (EApp (EVar "decDigitsNoUs") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (EApp (EApp (EApp (EVar "decDigitsNoUs") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "decFold" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "decFold" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "decFold" ((PCons (PVar "c") (PVar "cs")) (PVar "acc")) (EApp (EApp (EVar "decFold") (EVar "cs")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48))))))
(DTypeSig true "parseDecChecked" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "parseDecChecked" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoLet false false (PVar "digs") (EApp (EApp (EApp (EVar "decDigitsNoUs") (EVar "cs")) (EVar "n")) (ELit (LInt 0)))) (DoLet false false (PVar "ds") (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EVar "digs")))) (DoExpr (EIf (EBinOp "==" (EApp (EApp (EVar "compareDecMag") (EVar "ds")) (ELit (LString "4611686018427387903"))) (EVar "Gt")) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "decFold") (EVar "digs")) (ELit (LInt 0))))))))
(DTypeSig true "fallthroughName" (TyCon "String"))
(DFunDef false "fallthroughName" () (ELit (LString "__fallthrough__")))
(DTypeSig true "noneHeadTag" (TyCon "String"))
(DFunDef false "noneHeadTag" () (ELit (LString "__none__")))
# MARK
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omLookup" false) (mem "omInsert" false) (mem "omEmpty" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false) (mem "zip" false))))
(DUse false (UseGroup ("string") ((mem "join" false))))
(DTypeSig true "contains" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "contains" (PWild (PList)) (EVar "False"))
(DFunDef false "contains" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "contains") (EVar "x")) (EVar "ys"))))
(DTypeSig true "listLen" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")))
(DFunDef false "listLen" ((PList)) (ELit (LInt 0)))
(DFunDef false "listLen" ((PCons PWild (PVar "xs"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "listLen") (EVar "xs"))))
(DTypeSig true "reverseL" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "reverseL" ((PVar "xs")) (EApp (EVar "reverse") (EVar "xs")))
(DTypeSig true "anyList" (TyFun (TyFun (TyVar "a") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "anyList" (PWild (PList)) (EVar "False"))
(DFunDef false "anyList" ((PVar "p") (PCons (PVar "x") (PVar "xs"))) (EBinOp "||" (EApp (EVar "p") (EVar "x")) (EApp (EApp (EVar "anyList") (EVar "p")) (EVar "xs"))))
(DTypeSig true "allList" (TyFun (TyFun (TyVar "a") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "allList" (PWild (PList)) (EVar "True"))
(DFunDef false "allList" ((PVar "p") (PCons (PVar "x") (PVar "xs"))) (EBinOp "&&" (EApp (EVar "p") (EVar "x")) (EApp (EApp (EVar "allList") (EVar "p")) (EVar "xs"))))
(DTypeSig true "lookupAssoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "b"))) (TyApp (TyCon "Option") (TyVar "b")))))
(DFunDef false "lookupAssoc" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupAssoc" ((PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "k2")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupAssoc") (EVar "k")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "joinWith" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "joinWith" ((PVar "sep") (PVar "xs")) (EApp (EApp (EVar "join") (EVar "sep")) (EVar "xs")))
(DTypeSig true "joinNl" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinNl" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "xs")))
(DTypeSig true "splitNl" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitNl" ((PVar "s")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "splitNlGo") (EVar "chars")) (EApp (EVar "arrayLength") (EVar "chars"))) (ELit (LInt 0))) (ELit (LInt 0))))))
(DTypeSig false "splitNlGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "splitNlGo" ((PVar "chars") (PVar "n") (PVar "start") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "arraySubChars") (EVar "chars")) (EVar "start")) (EVar "n")))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (ELit (LChar "\n"))) (EBinOp "::" (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "arraySubChars") (EVar "chars")) (EVar "start")) (EVar "i"))) (EApp (EApp (EApp (EApp (EVar "splitNlGo") (EVar "chars")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "splitNlGo") (EVar "chars")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "splitOnChar" (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "splitOnChar" ((PVar "sep") (PVar "s")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "splitOnCharGo") (EVar "chars")) (EVar "sep")) (EApp (EVar "arrayLength") (EVar "chars"))) (ELit (LInt 0))) (ELit (LInt 0))))))
(DTypeSig false "splitOnCharGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Char") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitOnCharGo" ((PVar "chars") (PVar "sep") (PVar "n") (PVar "start") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "arraySubChars") (EVar "chars")) (EVar "start")) (EVar "n")))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (EVar "sep")) (EBinOp "::" (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "arraySubChars") (EVar "chars")) (EVar "start")) (EVar "i"))) (EApp (EApp (EApp (EApp (EApp (EVar "splitOnCharGo") (EVar "chars")) (EVar "sep")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "splitOnCharGo") (EVar "chars")) (EVar "sep")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "joinDot" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinDot" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "xs")))
(DTypeSig true "dedupBy" (TyFun (TyFun (TyVar "a") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "dedupBy" ((PVar "key") (PVar "xs")) (EApp (EApp (EApp (EVar "dedupByGo") (EVar "key")) (EVar "xs")) (EVar "omEmpty")))
(DTypeSig false "dedupByGo" (TyFun (TyFun (TyVar "a") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "dedupByGo" (PWild (PList) PWild) (EListLit))
(DFunDef false "dedupByGo" ((PVar "key") (PCons (PVar "x") (PVar "xs")) (PVar "seen")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "key") (EVar "x"))) (EVar "seen")) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EVar "dedupByGo") (EVar "key")) (EVar "xs")) (EVar "seen"))) (arm (PCon "None") () (EBinOp "::" (EVar "x") (EApp (EApp (EApp (EVar "dedupByGo") (EVar "key")) (EVar "xs")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "key") (EVar "x"))) (ELit LUnit)) (EVar "seen")))))))
(DTypeSig true "dedup" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dedup" ((PVar "xs")) (EApp (EApp (EVar "dedupBy") (EVar "identity")) (EVar "xs")))
(DTypeSig true "splitLast" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyVar "a")))))
(DFunDef false "splitLast" ((PList)) (EVar "None"))
(DFunDef false "splitLast" ((PList (PVar "x"))) (EApp (EVar "Some") (ETuple (EListLit) (EVar "x"))))
(DFunDef false "splitLast" ((PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "init") (PVar "lst"))) (ETuple (EBinOp "::" (EVar "x") (EVar "init")) (EVar "lst")))) (EApp (EVar "splitLast") (EVar "rest"))))
(DTypeSig true "escStr" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escStr" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "escFrom") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))))) (ELit (LString "\""))))
(DTypeSig false "escFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "escFrom" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "escOne") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EVar "escFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "escOne" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "escOne" ((PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\\"))) (ELit (LString "\\\\")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (ELit (LString "\\\"")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\n"))) (ELit (LString "\\n")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\t"))) (ELit (LString "\\t")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\r"))) (ELit (LString "\\r")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\0"))) (ELit (LString "\\0")) (EIf (EBinOp "<" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 32))) (EBinOp "++" (EBinOp "++" (ELit (LString "\\u{")) (EApp (EMethodRef "display") (EApp (EVar "escOneHex2") (EApp (EVar "charCode") (EVar "c"))))) (ELit (LString "}"))) (EIf (EVar "otherwise") (EApp (EVar "charToStr") (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig true "escOneHex2" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "escOneHex2" ((PVar "b")) (EBinOp "++" (EApp (EVar "escOneHexDigit") (EBinOp "/" (EVar "b") (ELit (LInt 16)))) (EApp (EVar "escOneHexDigit") (EBinOp "%" (EVar "b") (ELit (LInt 16))))))
(DTypeSig false "escOneHexDigit" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "escOneHexDigit" ((PVar "d")) (EIf (EBinOp "<" (EVar "d") (ELit (LInt 10))) (EApp (EVar "intToString") (EVar "d")) (EIf (EBinOp "==" (EVar "d") (ELit (LInt 10))) (ELit (LString "a")) (EIf (EBinOp "==" (EVar "d") (ELit (LInt 11))) (ELit (LString "b")) (EIf (EBinOp "==" (EVar "d") (ELit (LInt 12))) (ELit (LString "c")) (EIf (EBinOp "==" (EVar "d") (ELit (LInt 13))) (ELit (LString "d")) (EIf (EBinOp "==" (EVar "d") (ELit (LInt 14))) (ELit (LString "e")) (EIf (EVar "otherwise") (ELit (LString "f")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig true "isEmptyL" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isEmptyL" ((PList)) (EVar "True"))
(DFunDef false "isEmptyL" (PWild) (EVar "False"))
(DTypeSig true "isNonEmptyL" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isNonEmptyL" ((PVar "xs")) (EApp (EVar "not") (EApp (EVar "isEmptyL") (EVar "xs"))))
(DTypeSig true "filterList" (TyFun (TyFun (TyVar "a") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "filterList" (PWild (PList)) (EListLit))
(DFunDef false "filterList" ((PVar "p") (PCons (PVar "x") (PVar "xs"))) (EIf (EApp (EVar "p") (EVar "x")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "filterList") (EVar "p")) (EVar "xs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterList") (EVar "p")) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "initList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "initList" ((PList)) (EListLit))
(DFunDef false "initList" ((PList PWild)) (EListLit))
(DFunDef false "initList" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EApp (EVar "initList") (EVar "xs"))))
(DTypeSig true "zipL" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b"))))))
(DFunDef false "zipL" ((PVar "xs") (PVar "ys")) (EApp (EApp (EVar "zip") (EVar "xs")) (EVar "ys")))
(DTypeSig true "maxI" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "maxI" ((PVar "a") (PVar "b")) (EIf (EBinOp ">=" (EVar "a") (EVar "b")) (EVar "a") (EVar "b")))
(DTypeSig true "minI" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "minI" ((PVar "a") (PVar "b")) (EIf (EBinOp "<=" (EVar "a") (EVar "b")) (EVar "a") (EVar "b")))
(DTypeSig true "editDistance" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "editDistance" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "bs") (EApp (EApp (EVar "arrCharList") (EApp (EVar "stringToChars") (EVar "b"))) (ELit (LInt 0)))) (DoExpr (EApp (EVar "editLastInt") (EApp (EApp (EApp (EApp (EVar "editLoop") (EApp (EApp (EVar "arrCharList") (EApp (EVar "stringToChars") (EVar "a"))) (ELit (LInt 0)))) (EVar "bs")) (ELit (LInt 1))) (EApp (EApp (EVar "editInitRow") (ELit (LInt 0))) (EVar "bs")))))))
(DTypeSig false "arrCharList" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char")))))
(DFunDef false "arrCharList" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (EApp (EApp (EVar "arrCharList") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "editInitRow" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "editInitRow" ((PVar "k") (PList)) (EListLit (EVar "k")))
(DFunDef false "editInitRow" ((PVar "k") (PCons PWild (PVar "cs"))) (EBinOp "::" (EVar "k") (EApp (EApp (EVar "editInitRow") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "cs"))))
(DTypeSig false "editLoop" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "editLoop" ((PList) PWild PWild (PVar "prev")) (EVar "prev"))
(DFunDef false "editLoop" ((PCons (PVar "ac") (PVar "acs")) (PVar "bs") (PVar "i") (PCons (PVar "p0") (PVar "prest"))) (EApp (EApp (EApp (EApp (EVar "editLoop") (EVar "acs")) (EVar "bs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EApp (EApp (EVar "editRow") (EVar "ac")) (EVar "bs")) (EVar "i")) (EVar "p0")) (EVar "prest")))))
(DFunDef false "editLoop" ((PCons PWild PWild) PWild PWild (PList)) (EListLit))
(DTypeSig false "editRow" (TyFun (TyCon "Char") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "editRow" ((PVar "ac") (PCons (PVar "bc") (PVar "bcs")) (PVar "left") (PVar "diag") (PCons (PVar "pj") (PVar "pjs"))) (EBlock (DoLet false false (PVar "cost") (EIf (EBinOp "==" (EVar "ac") (EVar "bc")) (ELit (LInt 0)) (ELit (LInt 1)))) (DoLet false false (PVar "v") (EApp (EApp (EVar "minI") (EApp (EApp (EVar "minI") (EBinOp "+" (EVar "left") (ELit (LInt 1)))) (EBinOp "+" (EVar "pj") (ELit (LInt 1))))) (EBinOp "+" (EVar "diag") (EVar "cost")))) (DoExpr (EBinOp "::" (EVar "v") (EApp (EApp (EApp (EApp (EApp (EVar "editRow") (EVar "ac")) (EVar "bcs")) (EVar "v")) (EVar "pj")) (EVar "pjs"))))))
(DFunDef false "editRow" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "editLastInt" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "editLastInt" ((PList)) (ELit (LInt 0)))
(DFunDef false "editLastInt" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "editLastInt" ((PCons PWild (PVar "xs"))) (EApp (EVar "editLastInt") (EVar "xs")))
(DTypeSig true "startsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "startsWith" ((PVar "pre") (PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "pre"))) (DoExpr (EBinOp "&&" (EBinOp "<=" (EVar "n") (EApp (EVar "stringLength") (EVar "s"))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "n")) (EVar "s")) (EVar "pre"))))))
(DTypeSig true "endsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "endsWith" ((PVar "suf") (PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoLet false false (PVar "k") (EApp (EVar "stringLength") (EVar "suf"))) (DoExpr (EBinOp "&&" (EBinOp "<=" (EVar "k") (EVar "n")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (EVar "k"))) (EVar "n")) (EVar "s")) (EVar "suf"))))))
(DTypeSig true "schemeLineName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "schemeLineName" ((PVar "l")) (EApp (EApp (EApp (EVar "schemeLineNameGo") (EVar "l")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "l"))))
(DTypeSig false "schemeLineNameGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "schemeLineNameGo" ((PVar "l") (PVar "i") (PVar "n")) (EIf (EBinOp ">" (EBinOp "+" (EVar "i") (ELit (LInt 3))) (EVar "n")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 3)))) (EVar "l")) (ELit (LString " : "))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "l"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "schemeLineNameGo") (EVar "l")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "isSome" (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isSome" ((PCon "Some" PWild)) (EVar "True"))
(DFunDef false "isSome" ((PCon "None")) (EVar "False"))
(DTypeSig true "mapOption" (TyFun (TyFun (TyVar "a") (TyVar "b")) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "b")))))
(DFunDef false "mapOption" (PWild (PCon "None")) (EVar "None"))
(DFunDef false "mapOption" ((PVar "f") (PCon "Some" (PVar "x"))) (EApp (EVar "Some") (EApp (EVar "f") (EVar "x"))))
(DTypeSig true "orElseOpt" (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "orElseOpt" ((PCon "Some" (PVar "x")) PWild) (EApp (EVar "Some") (EVar "x")))
(DFunDef false "orElseOpt" ((PCon "None") (PVar "y")) (EVar "y"))
(DTypeSig false "isWs" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isWs" ((PLit (LString " "))) (EVar "True"))
(DFunDef false "isWs" ((PLit (LString "\t"))) (EVar "True"))
(DFunDef false "isWs" ((PLit (LString "\n"))) (EVar "True"))
(DFunDef false "isWs" ((PLit (LString "\r"))) (EVar "True"))
(DFunDef false "isWs" (PWild) (EVar "False"))
(DTypeSig false "arraySubChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Char"))))))
(DFunDef false "arraySubChars" ((PVar "chars") (PVar "lo") (PVar "hi")) (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "hi") (EVar "lo"))) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "lo") (EVar "i"))) (EVar "chars")))))
(DTypeSig false "trimLeftGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "trimLeftGo" ((PVar "chars") (PVar "i") (PVar "len")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (ELit (LString "")) (EIf (EApp (EVar "isWs") (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")))) (EApp (EApp (EApp (EVar "trimLeftGo") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EIf (EVar "otherwise") (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "arraySubChars") (EVar "chars")) (EVar "i")) (EVar "len"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "trimRightGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "trimRightGo" ((PVar "chars") (PVar "end")) (EIf (EBinOp "<=" (EVar "end") (ELit (LInt 0))) (ELit (LString "")) (EIf (EApp (EVar "isWs") (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "end") (ELit (LInt 1)))) (EVar "chars")))) (EApp (EApp (EVar "trimRightGo") (EVar "chars")) (EBinOp "-" (EVar "end") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "arraySubChars") (EVar "chars")) (ELit (LInt 0))) (EVar "end"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "stringTrimLeft" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stringTrimLeft" ((PVar "s")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "chars"))) (DoExpr (EApp (EApp (EApp (EVar "trimLeftGo") (EVar "chars")) (ELit (LInt 0))) (EVar "len")))))
(DTypeSig true "stringTrimRight" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stringTrimRight" ((PVar "s")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "chars"))) (DoExpr (EApp (EApp (EVar "trimRightGo") (EVar "chars")) (EVar "len")))))
(DTypeSig true "stringTrim" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stringTrim" ((PVar "s")) (EApp (EVar "stringTrimRight") (EApp (EVar "stringTrimLeft") (EVar "s"))))
(DTypeSig true "sortUniqS" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "sortUniqS" ((PVar "xs")) (EApp (EApp (EVar "sortUniqSGo") (EVar "xs")) (EListLit)))
(DTypeSig false "sortUniqSGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "sortUniqSGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "sortUniqSGo" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "sortUniqSGo") (EVar "xs")) (EApp (EApp (EVar "sortInsertS") (EVar "x")) (EVar "acc"))))
(DTypeSig false "sortInsertS" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "sortInsertS" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "sortInsertS" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EMatch (EApp (EApp (EVar "stringCompare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys")))) (arm (PCon "Eq") () (EBinOp "::" (EVar "y") (EVar "ys"))) (arm (PCon "Gt") () (EBinOp "::" (EVar "y") (EApp (EApp (EVar "sortInsertS") (EVar "x")) (EVar "ys"))))))
(DTypeSig true "utf8CharWidth" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "utf8CharWidth" ((PVar "cp")) (EIf (EBinOp "<" (EVar "cp") (ELit (LInt 128))) (ELit (LInt 1)) (EIf (EBinOp "<" (EVar "cp") (ELit (LInt 2048))) (ELit (LInt 2)) (EIf (EBinOp "<" (EVar "cp") (ELit (LInt 65536))) (ELit (LInt 3)) (EIf (EVar "otherwise") (ELit (LInt 4)) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "utf8LenGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "utf8LenGo" ((PVar "arr") (PVar "len") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "utf8LenGo") (EVar "arr")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (EApp (EVar "utf8CharWidth") (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "utf8Len" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "utf8Len" ((PVar "s")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "utf8LenGo") (EVar "arr")) (EApp (EVar "arrayLength") (EVar "arr"))) (ELit (LInt 0))) (ELit (LInt 0))))))
(DTypeSig false "decMagFirstSig" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "decMagFirstSig" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EVar "i") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "0"))) (EApp (EApp (EApp (EVar "decMagFirstSig") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "decMagNorm" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "decMagNorm" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EApp (EVar "stringFromChars") (EApp (EApp (EApp (EVar "arraySubChars") (EVar "cs")) (EApp (EApp (EApp (EVar "decMagFirstSig") (EVar "cs")) (EVar "n")) (ELit (LInt 0)))) (EVar "n"))))))
(DTypeSig true "compareDecMag" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Ordering"))))
(DFunDef false "compareDecMag" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "na") (EApp (EVar "decMagNorm") (EVar "a"))) (DoLet false false (PVar "nb") (EApp (EVar "decMagNorm") (EVar "b"))) (DoLet false false (PVar "la") (EApp (EVar "stringLength") (EVar "na"))) (DoLet false false (PVar "lb") (EApp (EVar "stringLength") (EVar "nb"))) (DoExpr (EIf (EBinOp "<" (EVar "la") (EVar "lb")) (EVar "Lt") (EIf (EBinOp ">" (EVar "la") (EVar "lb")) (EVar "Gt") (EApp (EApp (EVar "stringCompare") (EVar "na")) (EVar "nb")))))))
(DTypeSig false "decDigitsNoUs" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "decDigitsNoUs" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "_"))) (EApp (EApp (EApp (EVar "decDigitsNoUs") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (EApp (EApp (EApp (EVar "decDigitsNoUs") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "decFold" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "decFold" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "decFold" ((PCons (PVar "c") (PVar "cs")) (PVar "acc")) (EApp (EApp (EVar "decFold") (EVar "cs")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48))))))
(DTypeSig true "parseDecChecked" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "parseDecChecked" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoLet false false (PVar "digs") (EApp (EApp (EApp (EVar "decDigitsNoUs") (EVar "cs")) (EVar "n")) (ELit (LInt 0)))) (DoLet false false (PVar "ds") (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EVar "digs")))) (DoExpr (EIf (EBinOp "==" (EApp (EApp (EVar "compareDecMag") (EVar "ds")) (ELit (LString "4611686018427387903"))) (EVar "Gt")) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "decFold") (EVar "digs")) (ELit (LInt 0))))))))
(DTypeSig true "fallthroughName" (TyCon "String"))
(DFunDef false "fallthroughName" () (ELit (LString "__fallthrough__")))
(DTypeSig true "noneHeadTag" (TyCon "String"))
(DFunDef false "noneHeadTag" () (ELit (LString "__none__")))
