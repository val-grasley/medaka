# META
source_lines=236
stages=DESUGAR,MARK
# SOURCE
{- base64.mdk — RFC 4648 base64 encoding/decoding of raw bytes.

   Bytes are `Array Int` (each element `0..255`), the same convention used by
   `readFileBytes`/`writeFileBytes` (stdlib/runtime.mdk) and the
   `byteparser`/`bytebuilder` codecs.

   **Decode strictness.**  `decode` is strict, matching Python's `b64decode`
   default: the input length must be a multiple of 4, only the standard
   alphabet (`A-Z a-z 0-9 + /`) plus `=` padding is accepted, padding may only
   appear in the final 4-character group (as `""`, `"X=="`, or `"XX="`... i.e.
   0, 1, or 2 trailing `=`), and any other arrangement (bad char, misplaced
   `=`, wrong length) is `Err`.  Whitespace is NOT skipped — embedded
   whitespace is an error, it must be stripped by the caller first.

   `encodeUrlSafe`/`decodeUrlSafe` are the RFC 4648 §5 URL-and-filename-safe
   variant (`-`/`_` in place of `+`/`/`); padding is still emitted/required,
   for symmetry with the standard variant above. -}

-- base64/hex codec wrappers over a module-local decode share identical wrapper bodies by design.
-- lint-disable-file rule-duplicate-body

import array.{get, fromList}
import string.{toUtf8, fromUtf8, toChars}

-- | In-bounds indexing via the safe `Array.get`, panicking on a miss.  Every
--   call site below only ever indexes within the array's own known length,
--   so the `None` arm is unreachable — this avoids the internal-only
--   `arrayGetUnsafe` primitive.
byteAt : Int -> Array Int -> Int
byteAt i arr = match get i arr
  Some b => b
  None => panic "base64: index out of bounds"

charAt : Int -> Array Char -> Char
charAt i arr = match get i arr
  Some c => c
  None => panic "base64: index out of bounds"

-- ── Alphabet ──────────────────────────────────────────────────────────────

-- | 0..63 → base64 char.  `urlSafe` picks `-`/`_` (RFC 4648 §5) vs `+`/`/`.
b64Char : Int -> Bool -> Char
b64Char n urlSafe
  | n < 26 = charOrFallback (charFromCode (n + 65))
  | n < 52 = charOrFallback (charFromCode (n + 97 - 26))
  | n < 62 = charOrFallback (charFromCode (n + 48 - 52))
  | n == 62 = if urlSafe then '-' else '+'
  | otherwise = if urlSafe then '_' else '/'

charOrFallback : Option Char -> Char
charOrFallback (Some c) = c
charOrFallback None = '?'

-- | Base64 char → 0..63, or `None` if not in the (given-variant) alphabet.
b64Val : Char -> Bool -> Option Int
b64Val c urlSafe =
  let n = charCode c
  if n >= 65 && n <= 90 then Some (n - 65)          -- 'A'..'Z'
  else if n >= 97 && n <= 122 then Some (n - 97 + 26) -- 'a'..'z'
  else if n >= 48 && n <= 57 then Some (n - 48 + 52)  -- '0'..'9'
  else if urlSafe && c == '-' then Some 62
  else if urlSafe && c == '_' then Some 63
  else if not urlSafe && c == '+' then Some 62
  else if not urlSafe && c == '/' then Some 63
  else None

-- ── Encode ──────────────────────────────────────────────────────────────────

encodeGo : Array Int -> Int -> Int -> Bool -> List Char -> List Char
encodeGo bytes i n urlSafe acc
  | i >= n = acc
  | otherwise =
    let remain = n - i
    let b0 = byteAt i bytes
    let b1 = if remain > 1 then byteAt (i + 1) bytes else 0
    let b2 = if remain > 2 then byteAt (i + 2) bytes else 0
    let c0 = shiftRight b0 2
    let c1 = bitOr (shiftLeft (bitAnd b0 3) 4) (shiftRight b1 4)
    let c2 = bitOr (shiftLeft (bitAnd b1 15) 2) (shiftRight b2 6)
    let c3 = bitAnd b2 63
    let ch0 = b64Char c0 urlSafe
    let ch1 = b64Char c1 urlSafe
    let ch2 = if remain > 1 then b64Char c2 urlSafe else '='
    let ch3 = if remain > 2 then b64Char c3 urlSafe else '='
    encodeGo bytes (i + 3) n urlSafe (acc ++ [ch0, ch1, ch2, ch3])

{- | Bytes → standard base64 string, `=`-padded.  RFC 4648 test vectors
   (input is the UTF-8 bytes of the ASCII string):

   > encode (toUtf8 "")
   ""
   > encode (toUtf8 "f")
   "Zg=="
   > encode (toUtf8 "fo")
   "Zm8="
   > encode (toUtf8 "foo")
   "Zm9v"
   > encode (toUtf8 "foob")
   "Zm9vYg=="
   > encode (toUtf8 "fooba")
   "Zm9vYmE="
   > encode (toUtf8 "foobar")
   "Zm9vYmFy" -}
export encode : Array Int -> String
encode bytes =
  stringFromChars (arrayFromList (encodeGo
    bytes
    0
    (arrayLength bytes)
    False
    []))

{- | Bytes → URL-and-filename-safe base64 (`-`/`_`, still `=`-padded).

   > encodeUrlSafe (fromList [255, 239, 191])
   "_--_" -}
export encodeUrlSafe : Array Int -> String
encodeUrlSafe bytes =
  stringFromChars (arrayFromList (encodeGo bytes 0 (arrayLength bytes) True []))

-- ── Decode ──────────────────────────────────────────────────────────────────

-- | Ternary classification of a char in the two trailing group positions:
--   a real alphabet char (`TokVal code`), literal `=` padding (`TokPad`), or
--   anything else (`TokBad`, e.g. a stray non-alphabet character) — kept
--   distinct from `TokPad` so a bad char is never mistaken for padding.
data Tok = TokVal Int | TokPad | TokBad

tok : Char -> Bool -> Tok
tok c urlSafe =
  if c == '=' then TokPad
  else match b64Val c urlSafe
    Some v => TokVal v
    None => TokBad

-- | Decode one 4-char group.  `isLast` gates whether `=` padding is legal
--   here (only the final group of a well-formed input may be padded).
decodeQuad : Char -> Char -> Char -> Char -> Bool -> Bool -> Result String (List Int)
decodeQuad c0 c1 c2 c3 urlSafe isLast = match (b64Val c0 urlSafe, b64Val c1 urlSafe, tok c2 urlSafe, tok c3 urlSafe)
  (Some a, Some b, TokVal c, TokVal d) => Ok [
    bitOr (shiftLeft a 2) (shiftRight b 4),
    bitOr (shiftLeft (bitAnd b 15) 4) (shiftRight c 2),
    bitOr (shiftLeft (bitAnd c 3) 6) d,
  ]
  (Some a, Some b, TokVal c, TokPad) =>
    if isLast then
      Ok [
        bitOr (shiftLeft a 2) (shiftRight b 4),
        bitOr (shiftLeft (bitAnd b 15) 4) (shiftRight c 2),
      ]
    else
      Err "base64.decode: misplaced padding"
  (Some a, Some b, TokPad, TokPad) =>
    if isLast then
      Ok [bitOr (shiftLeft a 2) (shiftRight b 4)]
    else
      Err "base64.decode: misplaced padding"
  _ => Err "base64.decode: invalid character or padding"

decodeGo : Array Char -> Int -> Int -> Bool -> List Int -> Result String (List Int)
decodeGo chars i n urlSafe acc
  | i >= n = Ok acc
  | otherwise =
    let isLast = i + 4 == n
    match decodeQuad (charAt i chars) (charAt (i + 1) chars) (charAt (i + 2) chars) (charAt (i + 3) chars) urlSafe isLast
      Err e => Err e
      Ok bytes => decodeGo chars (i + 4) n urlSafe (acc ++ bytes)

decodeWith : String -> Bool -> Result String (Array Int)
decodeWith s urlSafe =
  let chars = toChars s
  let n = arrayLength chars
  if n % 4 != 0 then
    Err "base64.decode: length not a multiple of 4"
  else
    map arrayFromList (decodeGo chars 0 n urlSafe [])

{- | Standard base64 → bytes.  Strict: `Err` on bad length, invalid
   character, or misplaced padding.

   > decode ""
   Ok [||]
   > decode "Zg=="
   Ok [|102|]
   > decode "Zm8="
   Ok [|102, 111|]
   > decode "Zm9v"
   Ok [|102, 111, 111|]
   > decode "Zm9vYmFy"
   Ok [|102, 111, 111, 98, 97, 114|]
   > decode "Zg="
   Err "base64.decode: length not a multiple of 4"
   > decode "Z@=="
   Err "base64.decode: invalid character or padding" -}
export decode : String -> Result String (Array Int)
decode s = decodeWith s False

{- | URL-and-filename-safe base64 → bytes.

   > decodeUrlSafe "_--_"
   Ok [|255, 239, 191|] -}
export decodeUrlSafe : String -> Result String (Array Int)
decodeUrlSafe s = decodeWith s True

-- ── String convenience ───────────────────────────────────────────────────────

{- | UTF-8 bytes of `s` → standard base64 string.

   > encodeString "foo"
   "Zm9v" -}
export encodeString : String -> String
encodeString s = encode (toUtf8 s)

{- | Standard base64 → UTF-8-decoded String.

   > decodeString "Zm9v"
   Ok "foo" -}
export decodeString : String -> Result String String
decodeString s = map fromUtf8 (decode s)

-- ── Properties ──────────────────────────────────────────────────────────────

toByteArray : List Int -> Array Int
toByteArray xs = arrayFromList (map (b => (b % 256 + 256) % 256) xs)

prop "base64 round-trip: decode (encode bs) == Ok bs" (xs : List Int) =
  let bs = toByteArray xs
  decode (encode bs) == Ok bs

prop "base64 url-safe round-trip: decodeUrlSafe (encodeUrlSafe bs) == Ok bs" (xs : List Int) =
  let bs = toByteArray xs
  decodeUrlSafe (encodeUrlSafe bs) == Ok bs

prop "base64 encoded length is a multiple of 4" (xs : List Int) =
  let bs = toByteArray xs
  stringLength (encode bs) % 4 == 0
# DESUGAR
(DUse false (UseGroup ("array") ((mem "get" false) (mem "fromList" false))))
(DUse false (UseGroup ("string") ((mem "toUtf8" false) (mem "fromUtf8" false) (mem "toChars" false))))
(DTypeSig false "byteAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "byteAt" ((PVar "i") (PVar "arr")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PVar "b")) () (EVar "b")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "base64: index out of bounds"))))))
(DTypeSig false "charAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Char"))))
(DFunDef false "charAt" ((PVar "i") (PVar "arr")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "base64: index out of bounds"))))))
(DTypeSig false "b64Char" (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Char"))))
(DFunDef false "b64Char" ((PVar "n") (PVar "urlSafe")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 26))) (EApp (EVar "charOrFallback") (EApp (EVar "charFromCode") (EBinOp "+" (EVar "n") (ELit (LInt 65))))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 52))) (EApp (EVar "charOrFallback") (EApp (EVar "charFromCode") (EBinOp "-" (EBinOp "+" (EVar "n") (ELit (LInt 97))) (ELit (LInt 26))))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 62))) (EApp (EVar "charOrFallback") (EApp (EVar "charFromCode") (EBinOp "-" (EBinOp "+" (EVar "n") (ELit (LInt 48))) (ELit (LInt 52))))) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 62))) (EIf (EVar "urlSafe") (ELit (LChar "-")) (ELit (LChar "+"))) (EIf (EVar "otherwise") (EIf (EVar "urlSafe") (ELit (LChar "_")) (ELit (LChar "/"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "charOrFallback" (TyFun (TyApp (TyCon "Option") (TyCon "Char")) (TyCon "Char")))
(DFunDef false "charOrFallback" ((PCon "Some" (PVar "c"))) (EVar "c"))
(DFunDef false "charOrFallback" ((PCon "None")) (ELit (LChar "?")))
(DTypeSig false "b64Val" (TyFun (TyCon "Char") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "b64Val" ((PVar "c") (PVar "urlSafe")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "charCode") (EVar "c"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 65))) (EBinOp "<=" (EVar "n") (ELit (LInt 90)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 65)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 97))) (EBinOp "<=" (EVar "n") (ELit (LInt 122)))) (EApp (EVar "Some") (EBinOp "+" (EBinOp "-" (EVar "n") (ELit (LInt 97))) (ELit (LInt 26)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 48))) (EBinOp "<=" (EVar "n") (ELit (LInt 57)))) (EApp (EVar "Some") (EBinOp "+" (EBinOp "-" (EVar "n") (ELit (LInt 48))) (ELit (LInt 52)))) (EIf (EBinOp "&&" (EVar "urlSafe") (EBinOp "==" (EVar "c") (ELit (LChar "-")))) (EApp (EVar "Some") (ELit (LInt 62))) (EIf (EBinOp "&&" (EVar "urlSafe") (EBinOp "==" (EVar "c") (ELit (LChar "_")))) (EApp (EVar "Some") (ELit (LInt 63))) (EIf (EBinOp "&&" (EApp (EVar "not") (EVar "urlSafe")) (EBinOp "==" (EVar "c") (ELit (LChar "+")))) (EApp (EVar "Some") (ELit (LInt 62))) (EIf (EBinOp "&&" (EApp (EVar "not") (EVar "urlSafe")) (EBinOp "==" (EVar "c") (ELit (LChar "/")))) (EApp (EVar "Some") (ELit (LInt 63))) (EVar "None")))))))))))
(DTypeSig false "encodeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "List") (TyCon "Char"))))))))
(DFunDef false "encodeGo" ((PVar "bytes") (PVar "i") (PVar "n") (PVar "urlSafe") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "remain") (EBinOp "-" (EVar "n") (EVar "i"))) (DoLet false false (PVar "b0") (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "bytes"))) (DoLet false false (PVar "b1") (EIf (EBinOp ">" (EVar "remain") (ELit (LInt 1))) (EApp (EApp (EVar "byteAt") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "bytes")) (ELit (LInt 0)))) (DoLet false false (PVar "b2") (EIf (EBinOp ">" (EVar "remain") (ELit (LInt 2))) (EApp (EApp (EVar "byteAt") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "bytes")) (ELit (LInt 0)))) (DoLet false false (PVar "c0") (EApp (EApp (EVar "shiftRight") (EVar "b0")) (ELit (LInt 2)))) (DoLet false false (PVar "c1") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "bitAnd") (EVar "b0")) (ELit (LInt 3)))) (ELit (LInt 4)))) (EApp (EApp (EVar "shiftRight") (EVar "b1")) (ELit (LInt 4))))) (DoLet false false (PVar "c2") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "bitAnd") (EVar "b1")) (ELit (LInt 15)))) (ELit (LInt 2)))) (EApp (EApp (EVar "shiftRight") (EVar "b2")) (ELit (LInt 6))))) (DoLet false false (PVar "c3") (EApp (EApp (EVar "bitAnd") (EVar "b2")) (ELit (LInt 63)))) (DoLet false false (PVar "ch0") (EApp (EApp (EVar "b64Char") (EVar "c0")) (EVar "urlSafe"))) (DoLet false false (PVar "ch1") (EApp (EApp (EVar "b64Char") (EVar "c1")) (EVar "urlSafe"))) (DoLet false false (PVar "ch2") (EIf (EBinOp ">" (EVar "remain") (ELit (LInt 1))) (EApp (EApp (EVar "b64Char") (EVar "c2")) (EVar "urlSafe")) (ELit (LChar "=")))) (DoLet false false (PVar "ch3") (EIf (EBinOp ">" (EVar "remain") (ELit (LInt 2))) (EApp (EApp (EVar "b64Char") (EVar "c3")) (EVar "urlSafe")) (ELit (LChar "=")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "encodeGo") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 3)))) (EVar "n")) (EVar "urlSafe")) (EBinOp "++" (EVar "acc") (EListLit (EVar "ch0") (EVar "ch1") (EVar "ch2") (EVar "ch3")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "encode" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DFunDef false "encode" ((PVar "bytes")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EApp (EVar "encodeGo") (EVar "bytes")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "False")) (EListLit)))))
(DTypeSig true "encodeUrlSafe" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DFunDef false "encodeUrlSafe" ((PVar "bytes")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EApp (EVar "encodeGo") (EVar "bytes")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "True")) (EListLit)))))
(DData Private "Tok" () ((variant "TokVal" (ConPos (TyCon "Int"))) (variant "TokPad" (ConPos)) (variant "TokBad" (ConPos))) ())
(DTypeSig false "tok" (TyFun (TyCon "Char") (TyFun (TyCon "Bool") (TyCon "Tok"))))
(DFunDef false "tok" ((PVar "c") (PVar "urlSafe")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "="))) (EVar "TokPad") (EMatch (EApp (EApp (EVar "b64Val") (EVar "c")) (EVar "urlSafe")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "TokVal") (EVar "v"))) (arm (PCon "None") () (EVar "TokBad")))))
(DTypeSig false "decodeQuad" (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))))))
(DFunDef false "decodeQuad" ((PVar "c0") (PVar "c1") (PVar "c2") (PVar "c3") (PVar "urlSafe") (PVar "isLast")) (EMatch (ETuple (EApp (EApp (EVar "b64Val") (EVar "c0")) (EVar "urlSafe")) (EApp (EApp (EVar "b64Val") (EVar "c1")) (EVar "urlSafe")) (EApp (EApp (EVar "tok") (EVar "c2")) (EVar "urlSafe")) (EApp (EApp (EVar "tok") (EVar "c3")) (EVar "urlSafe"))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b")) (PCon "TokVal" (PVar "c")) (PCon "TokVal" (PVar "d"))) () (EApp (EVar "Ok") (EListLit (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EVar "a")) (ELit (LInt 2)))) (EApp (EApp (EVar "shiftRight") (EVar "b")) (ELit (LInt 4)))) (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "bitAnd") (EVar "b")) (ELit (LInt 15)))) (ELit (LInt 4)))) (EApp (EApp (EVar "shiftRight") (EVar "c")) (ELit (LInt 2)))) (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "bitAnd") (EVar "c")) (ELit (LInt 3)))) (ELit (LInt 6)))) (EVar "d"))))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b")) (PCon "TokVal" (PVar "c")) (PCon "TokPad")) () (EIf (EVar "isLast") (EApp (EVar "Ok") (EListLit (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EVar "a")) (ELit (LInt 2)))) (EApp (EApp (EVar "shiftRight") (EVar "b")) (ELit (LInt 4)))) (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "bitAnd") (EVar "b")) (ELit (LInt 15)))) (ELit (LInt 4)))) (EApp (EApp (EVar "shiftRight") (EVar "c")) (ELit (LInt 2)))))) (EApp (EVar "Err") (ELit (LString "base64.decode: misplaced padding"))))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b")) (PCon "TokPad") (PCon "TokPad")) () (EIf (EVar "isLast") (EApp (EVar "Ok") (EListLit (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EVar "a")) (ELit (LInt 2)))) (EApp (EApp (EVar "shiftRight") (EVar "b")) (ELit (LInt 4)))))) (EApp (EVar "Err") (ELit (LString "base64.decode: misplaced padding"))))) (arm PWild () (EApp (EVar "Err") (ELit (LString "base64.decode: invalid character or padding"))))))
(DTypeSig false "decodeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "decodeGo" ((PVar "chars") (PVar "i") (PVar "n") (PVar "urlSafe") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EVar "acc")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "isLast") (EBinOp "==" (EBinOp "+" (EVar "i") (ELit (LInt 4))) (EVar "n"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "decodeQuad") (EApp (EApp (EVar "charAt") (EVar "i")) (EVar "chars"))) (EApp (EApp (EVar "charAt") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "chars"))) (EApp (EApp (EVar "charAt") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "chars"))) (EApp (EApp (EVar "charAt") (EBinOp "+" (EVar "i") (ELit (LInt 3)))) (EVar "chars"))) (EVar "urlSafe")) (EVar "isLast")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "bytes")) () (EApp (EApp (EApp (EApp (EApp (EVar "decodeGo") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 4)))) (EVar "n")) (EVar "urlSafe")) (EBinOp "++" (EVar "acc") (EVar "bytes"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "decodeWith" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int"))))))
(DFunDef false "decodeWith" ((PVar "s") (PVar "urlSafe")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "toChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "chars"))) (DoExpr (EIf (EBinOp "!=" (EBinOp "%" (EVar "n") (ELit (LInt 4))) (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "base64.decode: length not a multiple of 4"))) (EApp (EApp (EVar "map") (EVar "arrayFromList")) (EApp (EApp (EApp (EApp (EApp (EVar "decodeGo") (EVar "chars")) (ELit (LInt 0))) (EVar "n")) (EVar "urlSafe")) (EListLit)))))))
(DTypeSig true "decode" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "decode" ((PVar "s")) (EApp (EApp (EVar "decodeWith") (EVar "s")) (EVar "False")))
(DTypeSig true "decodeUrlSafe" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "decodeUrlSafe" ((PVar "s")) (EApp (EApp (EVar "decodeWith") (EVar "s")) (EVar "True")))
(DTypeSig true "encodeString" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "encodeString" ((PVar "s")) (EApp (EVar "encode") (EApp (EVar "toUtf8") (EVar "s"))))
(DTypeSig true "decodeString" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))
(DFunDef false "decodeString" ((PVar "s")) (EApp (EApp (EVar "map") (EVar "fromUtf8")) (EApp (EVar "decode") (EVar "s"))))
(DTypeSig false "toByteArray" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toByteArray" ((PVar "xs")) (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "b") (ELit (LInt 256))) (ELit (LInt 256))) (ELit (LInt 256))))) (EVar "xs"))))
(DProp false "base64 round-trip: decode (encode bs) == Ok bs" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "bs") (EApp (EVar "toByteArray") (EVar "xs"))) (DoExpr (EBinOp "==" (EApp (EVar "decode") (EApp (EVar "encode") (EVar "bs"))) (EApp (EVar "Ok") (EVar "bs"))))))
(DProp false "base64 url-safe round-trip: decodeUrlSafe (encodeUrlSafe bs) == Ok bs" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "bs") (EApp (EVar "toByteArray") (EVar "xs"))) (DoExpr (EBinOp "==" (EApp (EVar "decodeUrlSafe") (EApp (EVar "encodeUrlSafe") (EVar "bs"))) (EApp (EVar "Ok") (EVar "bs"))))))
(DProp false "base64 encoded length is a multiple of 4" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "bs") (EApp (EVar "toByteArray") (EVar "xs"))) (DoExpr (EBinOp "==" (EBinOp "%" (EApp (EVar "stringLength") (EApp (EVar "encode") (EVar "bs"))) (ELit (LInt 4))) (ELit (LInt 0))))))
# MARK
(DUse false (UseGroup ("array") ((mem "get" false) (mem "fromList" false))))
(DUse false (UseGroup ("string") ((mem "toUtf8" false) (mem "fromUtf8" false) (mem "toChars" false))))
(DTypeSig false "byteAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "byteAt" ((PVar "i") (PVar "arr")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PVar "b")) () (EVar "b")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "base64: index out of bounds"))))))
(DTypeSig false "charAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Char"))))
(DFunDef false "charAt" ((PVar "i") (PVar "arr")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "base64: index out of bounds"))))))
(DTypeSig false "b64Char" (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Char"))))
(DFunDef false "b64Char" ((PVar "n") (PVar "urlSafe")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 26))) (EApp (EVar "charOrFallback") (EApp (EVar "charFromCode") (EBinOp "+" (EVar "n") (ELit (LInt 65))))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 52))) (EApp (EVar "charOrFallback") (EApp (EVar "charFromCode") (EBinOp "-" (EBinOp "+" (EVar "n") (ELit (LInt 97))) (ELit (LInt 26))))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 62))) (EApp (EVar "charOrFallback") (EApp (EVar "charFromCode") (EBinOp "-" (EBinOp "+" (EVar "n") (ELit (LInt 48))) (ELit (LInt 52))))) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 62))) (EIf (EVar "urlSafe") (ELit (LChar "-")) (ELit (LChar "+"))) (EIf (EVar "otherwise") (EIf (EVar "urlSafe") (ELit (LChar "_")) (ELit (LChar "/"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "charOrFallback" (TyFun (TyApp (TyCon "Option") (TyCon "Char")) (TyCon "Char")))
(DFunDef false "charOrFallback" ((PCon "Some" (PVar "c"))) (EVar "c"))
(DFunDef false "charOrFallback" ((PCon "None")) (ELit (LChar "?")))
(DTypeSig false "b64Val" (TyFun (TyCon "Char") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "b64Val" ((PVar "c") (PVar "urlSafe")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "charCode") (EVar "c"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 65))) (EBinOp "<=" (EVar "n") (ELit (LInt 90)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 65)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 97))) (EBinOp "<=" (EVar "n") (ELit (LInt 122)))) (EApp (EVar "Some") (EBinOp "+" (EBinOp "-" (EVar "n") (ELit (LInt 97))) (ELit (LInt 26)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 48))) (EBinOp "<=" (EVar "n") (ELit (LInt 57)))) (EApp (EVar "Some") (EBinOp "+" (EBinOp "-" (EVar "n") (ELit (LInt 48))) (ELit (LInt 52)))) (EIf (EBinOp "&&" (EVar "urlSafe") (EBinOp "==" (EVar "c") (ELit (LChar "-")))) (EApp (EVar "Some") (ELit (LInt 62))) (EIf (EBinOp "&&" (EVar "urlSafe") (EBinOp "==" (EVar "c") (ELit (LChar "_")))) (EApp (EVar "Some") (ELit (LInt 63))) (EIf (EBinOp "&&" (EApp (EVar "not") (EVar "urlSafe")) (EBinOp "==" (EVar "c") (ELit (LChar "+")))) (EApp (EVar "Some") (ELit (LInt 62))) (EIf (EBinOp "&&" (EApp (EVar "not") (EVar "urlSafe")) (EBinOp "==" (EVar "c") (ELit (LChar "/")))) (EApp (EVar "Some") (ELit (LInt 63))) (EVar "None")))))))))))
(DTypeSig false "encodeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "List") (TyCon "Char"))))))))
(DFunDef false "encodeGo" ((PVar "bytes") (PVar "i") (PVar "n") (PVar "urlSafe") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "remain") (EBinOp "-" (EVar "n") (EVar "i"))) (DoLet false false (PVar "b0") (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "bytes"))) (DoLet false false (PVar "b1") (EIf (EBinOp ">" (EVar "remain") (ELit (LInt 1))) (EApp (EApp (EVar "byteAt") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "bytes")) (ELit (LInt 0)))) (DoLet false false (PVar "b2") (EIf (EBinOp ">" (EVar "remain") (ELit (LInt 2))) (EApp (EApp (EVar "byteAt") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "bytes")) (ELit (LInt 0)))) (DoLet false false (PVar "c0") (EApp (EApp (EVar "shiftRight") (EVar "b0")) (ELit (LInt 2)))) (DoLet false false (PVar "c1") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "bitAnd") (EVar "b0")) (ELit (LInt 3)))) (ELit (LInt 4)))) (EApp (EApp (EVar "shiftRight") (EVar "b1")) (ELit (LInt 4))))) (DoLet false false (PVar "c2") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "bitAnd") (EVar "b1")) (ELit (LInt 15)))) (ELit (LInt 2)))) (EApp (EApp (EVar "shiftRight") (EVar "b2")) (ELit (LInt 6))))) (DoLet false false (PVar "c3") (EApp (EApp (EVar "bitAnd") (EVar "b2")) (ELit (LInt 63)))) (DoLet false false (PVar "ch0") (EApp (EApp (EVar "b64Char") (EVar "c0")) (EVar "urlSafe"))) (DoLet false false (PVar "ch1") (EApp (EApp (EVar "b64Char") (EVar "c1")) (EVar "urlSafe"))) (DoLet false false (PVar "ch2") (EIf (EBinOp ">" (EVar "remain") (ELit (LInt 1))) (EApp (EApp (EVar "b64Char") (EVar "c2")) (EVar "urlSafe")) (ELit (LChar "=")))) (DoLet false false (PVar "ch3") (EIf (EBinOp ">" (EVar "remain") (ELit (LInt 2))) (EApp (EApp (EVar "b64Char") (EVar "c3")) (EVar "urlSafe")) (ELit (LChar "=")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "encodeGo") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 3)))) (EVar "n")) (EVar "urlSafe")) (EBinOp "++" (EVar "acc") (EListLit (EVar "ch0") (EVar "ch1") (EVar "ch2") (EVar "ch3")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "encode" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DFunDef false "encode" ((PVar "bytes")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EApp (EVar "encodeGo") (EVar "bytes")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "False")) (EListLit)))))
(DTypeSig true "encodeUrlSafe" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DFunDef false "encodeUrlSafe" ((PVar "bytes")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EApp (EVar "encodeGo") (EVar "bytes")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "bytes"))) (EVar "True")) (EListLit)))))
(DData Private "Tok" () ((variant "TokVal" (ConPos (TyCon "Int"))) (variant "TokPad" (ConPos)) (variant "TokBad" (ConPos))) ())
(DTypeSig false "tok" (TyFun (TyCon "Char") (TyFun (TyCon "Bool") (TyCon "Tok"))))
(DFunDef false "tok" ((PVar "c") (PVar "urlSafe")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "="))) (EVar "TokPad") (EMatch (EApp (EApp (EVar "b64Val") (EVar "c")) (EVar "urlSafe")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "TokVal") (EVar "v"))) (arm (PCon "None") () (EVar "TokBad")))))
(DTypeSig false "decodeQuad" (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyFun (TyCon "Char") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))))))
(DFunDef false "decodeQuad" ((PVar "c0") (PVar "c1") (PVar "c2") (PVar "c3") (PVar "urlSafe") (PVar "isLast")) (EMatch (ETuple (EApp (EApp (EVar "b64Val") (EVar "c0")) (EVar "urlSafe")) (EApp (EApp (EVar "b64Val") (EVar "c1")) (EVar "urlSafe")) (EApp (EApp (EVar "tok") (EVar "c2")) (EVar "urlSafe")) (EApp (EApp (EVar "tok") (EVar "c3")) (EVar "urlSafe"))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b")) (PCon "TokVal" (PVar "c")) (PCon "TokVal" (PVar "d"))) () (EApp (EVar "Ok") (EListLit (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EVar "a")) (ELit (LInt 2)))) (EApp (EApp (EVar "shiftRight") (EVar "b")) (ELit (LInt 4)))) (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "bitAnd") (EVar "b")) (ELit (LInt 15)))) (ELit (LInt 4)))) (EApp (EApp (EVar "shiftRight") (EVar "c")) (ELit (LInt 2)))) (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "bitAnd") (EVar "c")) (ELit (LInt 3)))) (ELit (LInt 6)))) (EVar "d"))))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b")) (PCon "TokVal" (PVar "c")) (PCon "TokPad")) () (EIf (EVar "isLast") (EApp (EVar "Ok") (EListLit (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EVar "a")) (ELit (LInt 2)))) (EApp (EApp (EVar "shiftRight") (EVar "b")) (ELit (LInt 4)))) (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "bitAnd") (EVar "b")) (ELit (LInt 15)))) (ELit (LInt 4)))) (EApp (EApp (EVar "shiftRight") (EVar "c")) (ELit (LInt 2)))))) (EApp (EVar "Err") (ELit (LString "base64.decode: misplaced padding"))))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b")) (PCon "TokPad") (PCon "TokPad")) () (EIf (EVar "isLast") (EApp (EVar "Ok") (EListLit (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EVar "a")) (ELit (LInt 2)))) (EApp (EApp (EVar "shiftRight") (EVar "b")) (ELit (LInt 4)))))) (EApp (EVar "Err") (ELit (LString "base64.decode: misplaced padding"))))) (arm PWild () (EApp (EVar "Err") (ELit (LString "base64.decode: invalid character or padding"))))))
(DTypeSig false "decodeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "decodeGo" ((PVar "chars") (PVar "i") (PVar "n") (PVar "urlSafe") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EVar "acc")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "isLast") (EBinOp "==" (EBinOp "+" (EVar "i") (ELit (LInt 4))) (EVar "n"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "decodeQuad") (EApp (EApp (EVar "charAt") (EVar "i")) (EVar "chars"))) (EApp (EApp (EVar "charAt") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "chars"))) (EApp (EApp (EVar "charAt") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "chars"))) (EApp (EApp (EVar "charAt") (EBinOp "+" (EVar "i") (ELit (LInt 3)))) (EVar "chars"))) (EVar "urlSafe")) (EVar "isLast")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "bytes")) () (EApp (EApp (EApp (EApp (EApp (EVar "decodeGo") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 4)))) (EVar "n")) (EVar "urlSafe")) (EBinOp "++" (EVar "acc") (EVar "bytes"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "decodeWith" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int"))))))
(DFunDef false "decodeWith" ((PVar "s") (PVar "urlSafe")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "toChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "chars"))) (DoExpr (EIf (EBinOp "!=" (EBinOp "%" (EVar "n") (ELit (LInt 4))) (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "base64.decode: length not a multiple of 4"))) (EApp (EApp (EMethodRef "map") (EVar "arrayFromList")) (EApp (EApp (EApp (EApp (EApp (EVar "decodeGo") (EVar "chars")) (ELit (LInt 0))) (EVar "n")) (EVar "urlSafe")) (EListLit)))))))
(DTypeSig true "decode" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "decode" ((PVar "s")) (EApp (EApp (EVar "decodeWith") (EVar "s")) (EVar "False")))
(DTypeSig true "decodeUrlSafe" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "decodeUrlSafe" ((PVar "s")) (EApp (EApp (EVar "decodeWith") (EVar "s")) (EVar "True")))
(DTypeSig true "encodeString" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "encodeString" ((PVar "s")) (EApp (EVar "encode") (EApp (EVar "toUtf8") (EVar "s"))))
(DTypeSig true "decodeString" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))
(DFunDef false "decodeString" ((PVar "s")) (EApp (EApp (EMethodRef "map") (EVar "fromUtf8")) (EApp (EVar "decode") (EVar "s"))))
(DTypeSig false "toByteArray" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toByteArray" ((PVar "xs")) (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "b") (ELit (LInt 256))) (ELit (LInt 256))) (ELit (LInt 256))))) (EVar "xs"))))
(DProp false "base64 round-trip: decode (encode bs) == Ok bs" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "bs") (EApp (EVar "toByteArray") (EVar "xs"))) (DoExpr (EBinOp "==" (EApp (EVar "decode") (EApp (EVar "encode") (EVar "bs"))) (EApp (EVar "Ok") (EVar "bs"))))))
(DProp false "base64 url-safe round-trip: decodeUrlSafe (encodeUrlSafe bs) == Ok bs" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "bs") (EApp (EVar "toByteArray") (EVar "xs"))) (DoExpr (EBinOp "==" (EApp (EVar "decodeUrlSafe") (EApp (EVar "encodeUrlSafe") (EVar "bs"))) (EApp (EVar "Ok") (EVar "bs"))))))
(DProp false "base64 encoded length is a multiple of 4" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "bs") (EApp (EVar "toByteArray") (EVar "xs"))) (DoExpr (EBinOp "==" (EBinOp "%" (EApp (EVar "stringLength") (EApp (EVar "encode") (EVar "bs"))) (ELit (LInt 4))) (ELit (LInt 0))))))
