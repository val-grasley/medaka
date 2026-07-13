# META
source_lines=148
stages=DESUGAR,MARK
# SOURCE
{- hex.mdk — hex (base16) encoding/decoding of raw bytes.

   Bytes are `Array Int` (each element `0..255`), matching the convention
   used by `readFileBytes`/`writeFileBytes` (stdlib/runtime.mdk) and the
   `byteparser`/`bytebuilder` codecs: two hex digits per byte, most
   significant nibble first.

   **Decode strictness.**  `decode` rejects (`Err`) an odd-length input and
   any non-hex-digit character.  Whitespace is NOT skipped — a string with
   embedded spaces/newlines is an error.  Both uppercase and lowercase hex
   digits are accepted on decode (mirrors `string.digitToInt`, which already
   treats `'a'..'f'`/`'A'..'F'` uniformly); `encode` always produces
   lowercase, `encodeUpper` uppercase. -}

-- hex/base64 codec wrappers over a module-local decode share identical wrapper bodies by design.
-- lint-disable-file rule-duplicate-body

import array.{get, fromList}
import string.{digitToInt, intToDigit, toUtf8, fromUtf8, toChars}

-- | In-bounds indexing via the safe `Array.get`, panicking on a miss.  Every
--   call site below only ever indexes within the array's own known length,
--   so the `None` arm is unreachable — this just avoids the internal-only
--   `arrayGetUnsafe` primitive (stdlib code may still use it, but a plain
--   `Array.get` reads just as well here and keeps this file simple).
byteAt : Int -> Array Int -> Int
byteAt i arr = match get i arr
  Some b => b
  None => panic "hex: index out of bounds"

charAt : Int -> Array Char -> Char
charAt i arr = match get i arr
  Some c => c
  None => panic "hex: index out of bounds"

-- ── Encode ──────────────────────────────────────────────────────────────────

digitChar : Int -> Bool -> Char
digitChar n upper =
  if upper then match intToDigit n
    Some c => charToUpper c
    None => '?'
  else match intToDigit n
    Some c => c
    None => '?'

byteToHexChars : Int -> Bool -> (Char, Char)
byteToHexChars b upper =
  let masked = bitAnd b 255
  let hi = shiftRight masked 4
  let lo = bitAnd masked 15
  (digitChar hi upper, digitChar lo upper)

encodeGo : Array Int -> Int -> Bool -> List Char -> List Char
encodeGo bytes i upper acc
  | i < 0 = acc
  | otherwise =
    let (hi, lo) = byteToHexChars (byteAt i bytes) upper
    encodeGo bytes (i - 1) upper (hi :: lo::acc)

{- | Bytes → lowercase hex string, two characters per byte, most-significant
   nibble first.

   > encode (fromList [255, 0, 16])
   "ff0010"
   > encode ([||] : Array Int)
   ""
   > encode (fromList [0])
   "00" -}
export encode : Array Int -> String
encode bytes =
  stringFromChars (arrayFromList (encodeGo
    bytes
    (arrayLength bytes - 1)
    False
    []))

{- | Bytes → uppercase hex string.

   > encodeUpper (fromList [255, 0, 16])
   "FF0010" -}
export encodeUpper : Array Int -> String
encodeUpper bytes =
  stringFromChars (arrayFromList (encodeGo
    bytes
    (arrayLength bytes - 1)
    True
    []))

{- | UTF-8 bytes of `s` → lowercase hex string.

   > encodeString "Hello"
   "48656c6c6f" -}
export encodeString : String -> String
encodeString s = encode (toUtf8 s)

-- ── Decode ──────────────────────────────────────────────────────────────────

decodeGo : Array Char -> Int -> Int -> List Int -> Result String (List Int)
decodeGo chars i n acc
  | i >= n = Ok acc
  | otherwise = match digitToInt (charAt i chars)
    None => Err "hex.decode: invalid hex digit"
    Some hi => match digitToInt (charAt (i + 1) chars)
      None => Err "hex.decode: invalid hex digit"
      Some lo => decodeGo chars (i + 2) n (acc ++ [hi * 16 + lo])

{- | Hex string → bytes.  `Err` on odd length or any non-hex-digit character
   (uppercase and lowercase digits both accepted; no whitespace skipping).

   > decode "ff0010"
   Ok [|255, 0, 16|]
   > decode "FF0010"
   Ok [|255, 0, 16|]
   > decode ""
   Ok [||]
   > decode "f"
   Err "hex.decode: odd-length input"
   > decode "zz"
   Err "hex.decode: invalid hex digit" -}
export decode : String -> Result String (Array Int)
decode s =
  let chars = toChars s
  let n = arrayLength chars
  if isOdd n then
    Err "hex.decode: odd-length input"
  else
    map arrayFromList (decodeGo chars 0 n [])

{- | Hex string → UTF-8-decoded String.

   > decodeString "48656c6c6f"
   Ok "Hello" -}
export decodeString : String -> Result String String
decodeString s = map fromUtf8 (decode s)

-- ── Properties ──────────────────────────────────────────────────────────────

toByteArray : List Int -> Array Int
toByteArray xs = arrayFromList (map (b => (b % 256 + 256) % 256) xs)

prop "hex round-trip: decode (encode bs) == Ok bs" (xs : List Int) =
  let bs = toByteArray xs
  decode (encode bs) == Ok bs

prop "hex encode length is 2x byte length" (xs : List Int) =
  let bs = toByteArray xs
  stringLength (encode bs) == 2 * arrayLength bs
# DESUGAR
(DUse false (UseGroup ("array") ((mem "get" false) (mem "fromList" false))))
(DUse false (UseGroup ("string") ((mem "digitToInt" false) (mem "intToDigit" false) (mem "toUtf8" false) (mem "fromUtf8" false) (mem "toChars" false))))
(DTypeSig false "byteAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "byteAt" ((PVar "i") (PVar "arr")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PVar "b")) () (EVar "b")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "hex: index out of bounds"))))))
(DTypeSig false "charAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Char"))))
(DFunDef false "charAt" ((PVar "i") (PVar "arr")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "hex: index out of bounds"))))))
(DTypeSig false "digitChar" (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Char"))))
(DFunDef false "digitChar" ((PVar "n") (PVar "upper")) (EIf (EVar "upper") (EMatch (EApp (EVar "intToDigit") (EVar "n")) (arm (PCon "Some" (PVar "c")) () (EApp (EVar "charToUpper") (EVar "c"))) (arm (PCon "None") () (ELit (LChar "?")))) (EMatch (EApp (EVar "intToDigit") (EVar "n")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (ELit (LChar "?"))))))
(DTypeSig false "byteToHexChars" (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyTuple (TyCon "Char") (TyCon "Char")))))
(DFunDef false "byteToHexChars" ((PVar "b") (PVar "upper")) (EBlock (DoLet false false (PVar "masked") (EApp (EApp (EVar "bitAnd") (EVar "b")) (ELit (LInt 255)))) (DoLet false false (PVar "hi") (EApp (EApp (EVar "shiftRight") (EVar "masked")) (ELit (LInt 4)))) (DoLet false false (PVar "lo") (EApp (EApp (EVar "bitAnd") (EVar "masked")) (ELit (LInt 15)))) (DoExpr (ETuple (EApp (EApp (EVar "digitChar") (EVar "hi")) (EVar "upper")) (EApp (EApp (EVar "digitChar") (EVar "lo")) (EVar "upper"))))))
(DTypeSig false "encodeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "List") (TyCon "Char")))))))
(DFunDef false "encodeGo" ((PVar "bytes") (PVar "i") (PVar "upper") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EIf (EVar "otherwise") (EBlock (DoLet false false (PTuple (PVar "hi") (PVar "lo")) (EApp (EApp (EVar "byteToHexChars") (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "bytes"))) (EVar "upper"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "encodeGo") (EVar "bytes")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "upper")) (EBinOp "::" (EVar "hi") (EBinOp "::" (EVar "lo") (EVar "acc")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "encode" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DFunDef false "encode" ((PVar "bytes")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EVar "encodeGo") (EVar "bytes")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "bytes")) (ELit (LInt 1)))) (EVar "False")) (EListLit)))))
(DTypeSig true "encodeUpper" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DFunDef false "encodeUpper" ((PVar "bytes")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EVar "encodeGo") (EVar "bytes")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "bytes")) (ELit (LInt 1)))) (EVar "True")) (EListLit)))))
(DTypeSig true "encodeString" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "encodeString" ((PVar "s")) (EApp (EVar "encode") (EApp (EVar "toUtf8") (EVar "s"))))
(DTypeSig false "decodeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "decodeGo" ((PVar "chars") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EVar "acc")) (EIf (EVar "otherwise") (EMatch (EApp (EVar "digitToInt") (EApp (EApp (EVar "charAt") (EVar "i")) (EVar "chars"))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "hex.decode: invalid hex digit")))) (arm (PCon "Some" (PVar "hi")) () (EMatch (EApp (EVar "digitToInt") (EApp (EApp (EVar "charAt") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "chars"))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "hex.decode: invalid hex digit")))) (arm (PCon "Some" (PVar "lo")) () (EApp (EApp (EApp (EApp (EVar "decodeGo") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "n")) (EBinOp "++" (EVar "acc") (EListLit (EBinOp "+" (EBinOp "*" (EVar "hi") (ELit (LInt 16))) (EVar "lo"))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "decode" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "decode" ((PVar "s")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "toChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "chars"))) (DoExpr (EIf (EApp (EVar "isOdd") (EVar "n")) (EApp (EVar "Err") (ELit (LString "hex.decode: odd-length input"))) (EApp (EApp (EVar "map") (EVar "arrayFromList")) (EApp (EApp (EApp (EApp (EVar "decodeGo") (EVar "chars")) (ELit (LInt 0))) (EVar "n")) (EListLit)))))))
(DTypeSig true "decodeString" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))
(DFunDef false "decodeString" ((PVar "s")) (EApp (EApp (EVar "map") (EVar "fromUtf8")) (EApp (EVar "decode") (EVar "s"))))
(DTypeSig false "toByteArray" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toByteArray" ((PVar "xs")) (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "b") (ELit (LInt 256))) (ELit (LInt 256))) (ELit (LInt 256))))) (EVar "xs"))))
(DProp false "hex round-trip: decode (encode bs) == Ok bs" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "bs") (EApp (EVar "toByteArray") (EVar "xs"))) (DoExpr (EBinOp "==" (EApp (EVar "decode") (EApp (EVar "encode") (EVar "bs"))) (EApp (EVar "Ok") (EVar "bs"))))))
(DProp false "hex encode length is 2x byte length" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "bs") (EApp (EVar "toByteArray") (EVar "xs"))) (DoExpr (EBinOp "==" (EApp (EVar "stringLength") (EApp (EVar "encode") (EVar "bs"))) (EBinOp "*" (ELit (LInt 2)) (EApp (EVar "arrayLength") (EVar "bs")))))))
# MARK
(DUse false (UseGroup ("array") ((mem "get" false) (mem "fromList" false))))
(DUse false (UseGroup ("string") ((mem "digitToInt" false) (mem "intToDigit" false) (mem "toUtf8" false) (mem "fromUtf8" false) (mem "toChars" false))))
(DTypeSig false "byteAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "byteAt" ((PVar "i") (PVar "arr")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PVar "b")) () (EVar "b")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "hex: index out of bounds"))))))
(DTypeSig false "charAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Char"))))
(DFunDef false "charAt" ((PVar "i") (PVar "arr")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "hex: index out of bounds"))))))
(DTypeSig false "digitChar" (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Char"))))
(DFunDef false "digitChar" ((PVar "n") (PVar "upper")) (EIf (EVar "upper") (EMatch (EApp (EVar "intToDigit") (EVar "n")) (arm (PCon "Some" (PVar "c")) () (EApp (EVar "charToUpper") (EVar "c"))) (arm (PCon "None") () (ELit (LChar "?")))) (EMatch (EApp (EVar "intToDigit") (EVar "n")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (ELit (LChar "?"))))))
(DTypeSig false "byteToHexChars" (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyTuple (TyCon "Char") (TyCon "Char")))))
(DFunDef false "byteToHexChars" ((PVar "b") (PVar "upper")) (EBlock (DoLet false false (PVar "masked") (EApp (EApp (EVar "bitAnd") (EVar "b")) (ELit (LInt 255)))) (DoLet false false (PVar "hi") (EApp (EApp (EVar "shiftRight") (EVar "masked")) (ELit (LInt 4)))) (DoLet false false (PVar "lo") (EApp (EApp (EVar "bitAnd") (EVar "masked")) (ELit (LInt 15)))) (DoExpr (ETuple (EApp (EApp (EVar "digitChar") (EVar "hi")) (EVar "upper")) (EApp (EApp (EVar "digitChar") (EVar "lo")) (EVar "upper"))))))
(DTypeSig false "encodeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "List") (TyCon "Char")))))))
(DFunDef false "encodeGo" ((PVar "bytes") (PVar "i") (PVar "upper") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EIf (EVar "otherwise") (EBlock (DoLet false false (PTuple (PVar "hi") (PVar "lo")) (EApp (EApp (EVar "byteToHexChars") (EApp (EApp (EVar "byteAt") (EVar "i")) (EVar "bytes"))) (EVar "upper"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "encodeGo") (EVar "bytes")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "upper")) (EBinOp "::" (EVar "hi") (EBinOp "::" (EVar "lo") (EVar "acc")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "encode" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DFunDef false "encode" ((PVar "bytes")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EVar "encodeGo") (EVar "bytes")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "bytes")) (ELit (LInt 1)))) (EVar "False")) (EListLit)))))
(DTypeSig true "encodeUpper" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DFunDef false "encodeUpper" ((PVar "bytes")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EVar "encodeGo") (EVar "bytes")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "bytes")) (ELit (LInt 1)))) (EVar "True")) (EListLit)))))
(DTypeSig true "encodeString" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "encodeString" ((PVar "s")) (EApp (EVar "encode") (EApp (EVar "toUtf8") (EVar "s"))))
(DTypeSig false "decodeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "decodeGo" ((PVar "chars") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EVar "acc")) (EIf (EVar "otherwise") (EMatch (EApp (EVar "digitToInt") (EApp (EApp (EVar "charAt") (EVar "i")) (EVar "chars"))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "hex.decode: invalid hex digit")))) (arm (PCon "Some" (PVar "hi")) () (EMatch (EApp (EVar "digitToInt") (EApp (EApp (EVar "charAt") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "chars"))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "hex.decode: invalid hex digit")))) (arm (PCon "Some" (PVar "lo")) () (EApp (EApp (EApp (EApp (EVar "decodeGo") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "n")) (EBinOp "++" (EVar "acc") (EListLit (EBinOp "+" (EBinOp "*" (EVar "hi") (ELit (LInt 16))) (EVar "lo"))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "decode" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "decode" ((PVar "s")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "toChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "chars"))) (DoExpr (EIf (EApp (EVar "isOdd") (EVar "n")) (EApp (EVar "Err") (ELit (LString "hex.decode: odd-length input"))) (EApp (EApp (EMethodRef "map") (EVar "arrayFromList")) (EApp (EApp (EApp (EApp (EVar "decodeGo") (EVar "chars")) (ELit (LInt 0))) (EVar "n")) (EListLit)))))))
(DTypeSig true "decodeString" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))
(DFunDef false "decodeString" ((PVar "s")) (EApp (EApp (EMethodRef "map") (EVar "fromUtf8")) (EApp (EVar "decode") (EVar "s"))))
(DTypeSig false "toByteArray" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toByteArray" ((PVar "xs")) (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "b") (ELit (LInt 256))) (ELit (LInt 256))) (ELit (LInt 256))))) (EVar "xs"))))
(DProp false "hex round-trip: decode (encode bs) == Ok bs" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "bs") (EApp (EVar "toByteArray") (EVar "xs"))) (DoExpr (EBinOp "==" (EApp (EVar "decode") (EApp (EVar "encode") (EVar "bs"))) (EApp (EVar "Ok") (EVar "bs"))))))
(DProp false "hex encode length is 2x byte length" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "bs") (EApp (EVar "toByteArray") (EVar "xs"))) (DoExpr (EBinOp "==" (EApp (EVar "stringLength") (EApp (EVar "encode") (EVar "bs"))) (EBinOp "*" (ELit (LInt 2)) (EApp (EVar "arrayLength") (EVar "bs")))))))
