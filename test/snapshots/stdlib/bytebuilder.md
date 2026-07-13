# META
source_lines=367
stages=DESUGAR,MARK
# SOURCE
-- | bytebuilder — a byte-level output builder for Medaka.
--
-- Symmetric inverse of `byteparser`: where `byteparser` DECODES byte arrays
-- into values, `bytebuilder` ENCODES values INTO byte arrays.  Backed by a
-- `MutArray Int` (growable, amortised-O(1) `push`); `buildArray` freezes the
-- live range into a fixed-size `Array Int` in emission order — no reverse pass.
--
-- All `emit*` functions write bytes in the byte order that `byteparser`'s
-- matching decoder expects, so a round-trip `encode → decode` reproduces the
-- original value exactly.

import byteparser.{runByteParser, beUint, beSint, leUint, leSint, takeBytes}
import mut_array.{MutArray, new, push, toArray}
import list.{reverse}

-- ---------------------------------------------------------------------------
-- Builder type
-- ---------------------------------------------------------------------------

-- | A byte output buffer backed by a growable `MutArray Int`.
--   Bytes are appended in O(1) (amortised); `buildArray` snapshots to a
--   fixed-size `Array Int` in emission order.
--   The constructor is not exported — use `newBuilder`/`emit*`/`buildArray`.
export data Builder = Builder (MutArray Int)

-- | Create a new, empty builder.
export newBuilder : Unit -> Builder
newBuilder _ = Builder (new ())

-- ---------------------------------------------------------------------------
-- Emit primitives
-- ---------------------------------------------------------------------------

-- | Emit one byte (masked to low 8 bits).
export emitU8 : Int -> Builder -> <Mut> Unit
emitU8 b (Builder a) = push (bitAnd b 255) a

-- | Emit a big-endian 2-byte unsigned integer.
--   Inverse of `beUint 2`.
export emitU16BE : Int -> Builder -> <Mut> Unit
emitU16BE v buf =
  emitU8 (bitAnd (shiftRight v 8) 255) buf
  emitU8 (bitAnd v 255) buf

-- | Emit a big-endian 3-byte unsigned integer.
--   Inverse of `beUint 3`.
export emitU24BE : Int -> Builder -> <Mut> Unit
emitU24BE v buf =
  emitU8 (bitAnd (shiftRight v 16) 255) buf
  emitU8 (bitAnd (shiftRight v 8) 255) buf
  emitU8 (bitAnd v 255) buf

-- | Emit a big-endian 4-byte unsigned integer.
--   Inverse of `beUint 4`.
export emitU32BE : Int -> Builder -> <Mut> Unit
emitU32BE v buf =
  emitU8 (bitAnd (shiftRight v 24) 255) buf
  emitU8 (bitAnd (shiftRight v 16) 255) buf
  emitU8 (bitAnd (shiftRight v 8) 255) buf
  emitU8 (bitAnd v 255) buf

-- | Emit a little-endian 2-byte unsigned integer.
--   Inverse of `leUint 2`.  Byte order is the reverse of `emitU16BE`.
export emitU16LE : Int -> Builder -> <Mut> Unit
emitU16LE v buf =
  emitU8 (bitAnd v 255) buf
  emitU8 (bitAnd (shiftRight v 8) 255) buf

-- | Emit a little-endian 3-byte unsigned integer.
--   Inverse of `leUint 3`.  Byte order is the reverse of `emitU24BE`.
export emitU24LE : Int -> Builder -> <Mut> Unit
emitU24LE v buf =
  emitU8 (bitAnd v 255) buf
  emitU8 (bitAnd (shiftRight v 8) 255) buf
  emitU8 (bitAnd (shiftRight v 16) 255) buf

-- | Emit a little-endian 4-byte unsigned integer.
--   Inverse of `leUint 4`.  Byte order is the reverse of `emitU32BE`.
export emitU32LE : Int -> Builder -> <Mut> Unit
emitU32LE v buf =
  emitU8 (bitAnd v 255) buf
  emitU8 (bitAnd (shiftRight v 8) 255) buf
  emitU8 (bitAnd (shiftRight v 16) 255) buf
  emitU8 (bitAnd (shiftRight v 24) 255) buf

-- | Emit a list of byte values, each masked to low 8 bits.
--   Inverse of `takeBytes (length xs)`.
export emitBytes : List Int -> Builder -> <Mut> Unit
emitBytes [] _ = ()
emitBytes (b::rest) buf =
  emitU8 b buf
  emitBytes rest buf

-- ---------------------------------------------------------------------------
-- Big-endian signed integer encoder
-- ---------------------------------------------------------------------------
--
-- `beSint n` reads `n` bytes as unsigned, then if the value >= 2^(8n-1)
-- (sign bit set) subtracts 2^(8n) to get the negative.
--
-- Inverse: for v >= 0, emit as unsigned.
--          for v < 0, emit (v + 2^(8*nbytes)) as unsigned.
--          This is the standard two's-complement encoding.

-- | Emit an `nbytes`-wide big-endian two's-complement signed integer.
--   Inverse of `beSint nbytes`.
export emitBeSint : Int -> Int -> Builder -> <Mut> Unit
emitBeSint nbytes v buf =
  let unsigned = if v >= 0 then v else v + shiftLeft 1 (8 * nbytes)
  emitBeUint nbytes unsigned buf

-- | Emit exactly `nbytes` bytes of a non-negative integer in big-endian order.
--   Inverse of `beUint nbytes`.
--   The unsigned mirror of `emitBeSint`; useful when the value is always
--   non-negative and you want to choose the width dynamically at runtime.
export emitBeUint : Int -> Int -> Builder -> <Mut> Unit
emitBeUint 0 _ _ = ()
emitBeUint n v buf =
  emitBeUint (n - 1) (shiftRight v 8) buf
  emitU8 (bitAnd v 255) buf

-- ---------------------------------------------------------------------------
-- Little-endian signed integer encoder
-- ---------------------------------------------------------------------------
--
-- Mirror of `emitBeSint`/`emitBeUint`: same two's-complement masking, but
-- bytes are emitted least-significant-first.

-- | Emit an `nbytes`-wide little-endian two's-complement signed integer.
--   Inverse of `leSint nbytes`.
export emitLeSint : Int -> Int -> Builder -> <Mut> Unit
emitLeSint nbytes v buf =
  let unsigned = if v >= 0 then v else v + shiftLeft 1 (8 * nbytes)
  emitLeUint nbytes unsigned buf

-- | Emit exactly `nbytes` bytes of a non-negative integer in little-endian
--   order.  Inverse of `leUint nbytes`.  The unsigned mirror of `emitLeSint`.
export emitLeUint : Int -> Int -> Builder -> <Mut> Unit
emitLeUint 0 _ _ = ()
emitLeUint n v buf =
  emitU8 (bitAnd v 255) buf
  emitLeUint (n - 1) (shiftRight v 8) buf

-- ---------------------------------------------------------------------------
-- Finalise
-- ---------------------------------------------------------------------------

-- | Extract the accumulated bytes as a fixed-size `Array Int`.
--   Bytes are already in emission order (no reverse pass needed).
export buildArray : Builder -> Array Int
buildArray (Builder a) = toArray a

-- ---------------------------------------------------------------------------
-- Doctest helpers
-- ---------------------------------------------------------------------------

-- | Build bytes by running an emit action on a fresh builder and return the
--   resulting `Array Int`.  Used in round-trip doctests below.
build1 : (Builder -> <Mut> Unit) -> <Mut> Array Int
build1 f =
  let buf = newBuilder ()
  f buf
  buildArray buf

-- ---------------------------------------------------------------------------
-- Doctests — round-trip: emit → buildArray → runByteParser decoder == value
-- ---------------------------------------------------------------------------

-- emitU8 ↔ beUint 1
-- > runByteParser (beUint 1) (build1 (emitU8 0))
-- Ok 0
-- > runByteParser (beUint 1) (build1 (emitU8 255))
-- Ok 255
-- > runByteParser (beUint 1) (build1 (emitU8 127))
-- Ok 127

-- emitU16BE ↔ beUint 2
-- > runByteParser (beUint 2) (build1 (emitU16BE 0))
-- Ok 0
-- > runByteParser (beUint 2) (build1 (emitU16BE 256))
-- Ok 256
-- > runByteParser (beUint 2) (build1 (emitU16BE 65535))
-- Ok 65535
-- > runByteParser (beUint 2) (build1 (emitU16BE 258))
-- Ok 258

-- emitU24BE ↔ beUint 3
-- > runByteParser (beUint 3) (build1 (emitU24BE 0))
-- Ok 0
-- > runByteParser (beUint 3) (build1 (emitU24BE 16777215))
-- Ok 16777215
-- > runByteParser (beUint 3) (build1 (emitU24BE 65536))
-- Ok 65536

-- emitU32BE ↔ beUint 4
-- > runByteParser (beUint 4) (build1 (emitU32BE 0))
-- Ok 0
-- > runByteParser (beUint 4) (build1 (emitU32BE 4294967295))
-- Ok 4294967295
-- > runByteParser (beUint 4) (build1 (emitU32BE 1048576))
-- Ok 1048576

-- emitU16LE ↔ leUint 2
-- > runByteParser (leUint 2) (build1 (emitU16LE 0))
-- Ok 0
-- > runByteParser (leUint 2) (build1 (emitU16LE 256))
-- Ok 256
-- > runByteParser (leUint 2) (build1 (emitU16LE 65535))
-- Ok 65535
-- > runByteParser (leUint 2) (build1 (emitU16LE 258))
-- Ok 258

-- emitU24LE ↔ leUint 3
-- > runByteParser (leUint 3) (build1 (emitU24LE 0))
-- Ok 0
-- > runByteParser (leUint 3) (build1 (emitU24LE 16777215))
-- Ok 16777215
-- > runByteParser (leUint 3) (build1 (emitU24LE 65536))
-- Ok 65536

-- emitU32LE ↔ leUint 4
-- > runByteParser (leUint 4) (build1 (emitU32LE 0))
-- Ok 0
-- > runByteParser (leUint 4) (build1 (emitU32LE 4294967295))
-- Ok 4294967295
-- > runByteParser (leUint 4) (build1 (emitU32LE 1048576))
-- Ok 1048576

-- LE emits the reverse byte sequence of the matching BE emit:
-- emitU16LE 0x0102 -> [2, 1]; emitU16BE 0x0102 -> [1, 2].
-- > runByteParser (takeBytes 2) (build1 (emitU16LE 0x0102))
-- Ok [2, 1]
-- > runByteParser (takeBytes 2) (build1 (emitU16BE 0x0102))
-- Ok [1, 2]
-- > runByteParser (takeBytes 4) (build1 (emitU32LE 0x01020304))
-- Ok [4, 3, 2, 1]
-- > runByteParser (takeBytes 4) (build1 (emitU32BE 0x01020304))
-- Ok [1, 2, 3, 4]

-- emitBytes ↔ takeBytes
-- > runByteParser (takeBytes 3) (build1 (emitBytes [10, 20, 30]))
-- Ok [10, 20, 30]
-- > runByteParser (takeBytes 0) (build1 (emitBytes []))
-- Ok []
-- > runByteParser (takeBytes 4) (build1 (emitBytes [0, 128, 255, 1]))
-- Ok [0, 128, 255, 1]

-- The SQLite varint round-trip doctests moved to sqlite/lib/varint.mdk
-- (the SQLite varint codec is no longer part of the generic byteparser libs).

-- emitBeSint ↔ beSint  (1-byte)
-- > runByteParser (beSint 1) (build1 (emitBeSint 1 127))
-- Ok 127
-- > runByteParser (beSint 1) (build1 (emitBeSint 1 (-1)))
-- Ok -1
-- > runByteParser (beSint 1) (build1 (emitBeSint 1 (-128)))
-- Ok -128
-- > runByteParser (beSint 1) (build1 (emitBeSint 1 0))
-- Ok 0

-- emitBeSint ↔ beSint  (2-byte)
-- > runByteParser (beSint 2) (build1 (emitBeSint 2 32767))
-- Ok 32767
-- > runByteParser (beSint 2) (build1 (emitBeSint 2 (-32768)))
-- Ok -32768
-- > runByteParser (beSint 2) (build1 (emitBeSint 2 (-1)))
-- Ok -1

-- emitBeSint ↔ beSint  (4-byte)
-- > runByteParser (beSint 4) (build1 (emitBeSint 4 2147483647))
-- Ok 2147483647
-- > runByteParser (beSint 4) (build1 (emitBeSint 4 (-2147483648)))
-- Ok -2147483648
-- > runByteParser (beSint 4) (build1 (emitBeSint 4 (-1)))
-- Ok -1

-- emitBeUint ↔ beUint  (variable-width unsigned)
-- > runByteParser (beUint 1) (build1 (emitBeUint 1 0))
-- Ok 0
-- > runByteParser (beUint 1) (build1 (emitBeUint 1 255))
-- Ok 255
-- > runByteParser (beUint 2) (build1 (emitBeUint 2 256))
-- Ok 256
-- > runByteParser (beUint 3) (build1 (emitBeUint 3 65536))
-- Ok 65536
-- > runByteParser (beUint 4) (build1 (emitBeUint 4 4294967295))
-- Ok 4294967295

-- emitLeSint ↔ leSint  (1-byte)
-- > runByteParser (leSint 1) (build1 (emitLeSint 1 127))
-- Ok 127
-- > runByteParser (leSint 1) (build1 (emitLeSint 1 (-1)))
-- Ok -1
-- > runByteParser (leSint 1) (build1 (emitLeSint 1 (-128)))
-- Ok -128
-- > runByteParser (leSint 1) (build1 (emitLeSint 1 0))
-- Ok 0

-- emitLeSint ↔ leSint  (2-byte)
-- > runByteParser (leSint 2) (build1 (emitLeSint 2 32767))
-- Ok 32767
-- > runByteParser (leSint 2) (build1 (emitLeSint 2 (-32768)))
-- Ok -32768
-- > runByteParser (leSint 2) (build1 (emitLeSint 2 (-1)))
-- Ok -1

-- emitLeSint ↔ leSint  (4-byte)
-- > runByteParser (leSint 4) (build1 (emitLeSint 4 2147483647))
-- Ok 2147483647
-- > runByteParser (leSint 4) (build1 (emitLeSint 4 (-2147483648)))
-- Ok -2147483648
-- > runByteParser (leSint 4) (build1 (emitLeSint 4 (-1)))
-- Ok -1

-- emitLeUint ↔ leUint  (variable-width unsigned)
-- > runByteParser (leUint 1) (build1 (emitLeUint 1 0))
-- Ok 0
-- > runByteParser (leUint 1) (build1 (emitLeUint 1 255))
-- Ok 255
-- > runByteParser (leUint 2) (build1 (emitLeUint 2 256))
-- Ok 256
-- > runByteParser (leUint 3) (build1 (emitLeUint 3 65536))
-- Ok 65536
-- > runByteParser (leUint 4) (build1 (emitLeUint 4 4294967295))
-- Ok 4294967295

-- ---------------------------------------------------------------------------
-- Cross round-trip props — LE emit/parse agree with each other and with BE
-- ---------------------------------------------------------------------------
--
-- Values are kept in-width (0..65535 for 16-bit, signed range for the signed
-- prop) to avoid masking surprises from out-of-range inputs.

-- | emitU16LE → leUint 2 recovers the original value.
prop "emitU16LE/leUint 2 round-trip" (v : Int) =
  let w = bitAnd v 65535
  match runByteParser (leUint 2) (build1 (emitU16LE w))
    Ok got => got == w
    Err _ => False

-- | emitU32LE → leUint 4 recovers the original value.
prop "emitU32LE/leUint 4 round-trip" (v : Int) =
  let w = bitAnd v 4294967295
  match runByteParser (leUint 4) (build1 (emitU32LE w))
    Ok got => got == w
    Err _ => False

-- | emitLeSint 2 → leSint 2 recovers a value clamped to the 16-bit signed
--   two's-complement range.
prop "emitLeSint 2/leSint 2 round-trip" (v : Int) =
  let w = bitAnd v 65535 - 32768
  match runByteParser (leSint 2) (build1 (emitLeSint 2 w))
    Ok got => got == w
    Err _ => False

-- | BE emit followed by byte-reversal then LE parse agrees with a direct BE
--   parse of the same bytes — i.e. reversing a BE encoding and reading it LE
--   reproduces the original value (16-bit width).
prop "emitU16BE reversed bytes, leUint agrees with beUint" (v : Int) =
  let w = bitAnd v 65535
  match runByteParser (takeBytes 2) (build1 (emitU16BE w))
    Err _ => False
    Ok bytes =>
      let reversedArr = arrayFromList (reverse bytes)
      match runByteParser (leUint 2) reversedArr
        Ok got => got == w
        Err _ => False
# DESUGAR
(DUse false (UseGroup ("byteparser") ((mem "runByteParser" false) (mem "beUint" false) (mem "beSint" false) (mem "leUint" false) (mem "leSint" false) (mem "takeBytes" false))))
(DUse false (UseGroup ("mut_array") ((mem "MutArray" false) (mem "new" false) (mem "push" false) (mem "toArray" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DData Abstract "Builder" () ((variant "Builder" (ConPos (TyApp (TyCon "MutArray") (TyCon "Int"))))) ())
(DTypeSig true "newBuilder" (TyFun (TyCon "Unit") (TyCon "Builder")))
(DFunDef false "newBuilder" (PWild) (EApp (EVar "Builder") (EApp (EVar "new") (ELit LUnit))))
(DTypeSig true "emitU8" (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit")))))
(DFunDef false "emitU8" ((PVar "b") (PCon "Builder" (PVar "a"))) (EApp (EApp (EVar "push") (EApp (EApp (EVar "bitAnd") (EVar "b")) (ELit (LInt 255)))) (EVar "a")))
(DTypeSig true "emitU16BE" (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit")))))
(DFunDef false "emitU16BE" ((PVar "v") (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 8)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 255)))) (EVar "buf")))))
(DTypeSig true "emitU24BE" (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit")))))
(DFunDef false "emitU24BE" ((PVar "v") (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 16)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 8)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 255)))) (EVar "buf")))))
(DTypeSig true "emitU32BE" (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit")))))
(DFunDef false "emitU32BE" ((PVar "v") (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 24)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 16)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 8)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 255)))) (EVar "buf")))))
(DTypeSig true "emitU16LE" (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit")))))
(DFunDef false "emitU16LE" ((PVar "v") (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 8)))) (ELit (LInt 255)))) (EVar "buf")))))
(DTypeSig true "emitU24LE" (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit")))))
(DFunDef false "emitU24LE" ((PVar "v") (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 8)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 16)))) (ELit (LInt 255)))) (EVar "buf")))))
(DTypeSig true "emitU32LE" (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit")))))
(DFunDef false "emitU32LE" ((PVar "v") (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 8)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 16)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 24)))) (ELit (LInt 255)))) (EVar "buf")))))
(DTypeSig true "emitBytes" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit")))))
(DFunDef false "emitBytes" ((PList) PWild) (ELit LUnit))
(DFunDef false "emitBytes" ((PCons (PVar "b") (PVar "rest")) (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EVar "b")) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitBytes") (EVar "rest")) (EVar "buf")))))
(DTypeSig true "emitBeSint" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit"))))))
(DFunDef false "emitBeSint" ((PVar "nbytes") (PVar "v") (PVar "buf")) (EBlock (DoLet false false (PVar "unsigned") (EIf (EBinOp ">=" (EVar "v") (ELit (LInt 0))) (EVar "v") (EBinOp "+" (EVar "v") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EBinOp "*" (ELit (LInt 8)) (EVar "nbytes")))))) (DoExpr (EApp (EApp (EApp (EVar "emitBeUint") (EVar "nbytes")) (EVar "unsigned")) (EVar "buf")))))
(DTypeSig true "emitBeUint" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit"))))))
(DFunDef false "emitBeUint" ((PLit (LInt 0)) PWild PWild) (ELit LUnit))
(DFunDef false "emitBeUint" ((PVar "n") (PVar "v") (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "emitBeUint") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 8)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 255)))) (EVar "buf")))))
(DTypeSig true "emitLeSint" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit"))))))
(DFunDef false "emitLeSint" ((PVar "nbytes") (PVar "v") (PVar "buf")) (EBlock (DoLet false false (PVar "unsigned") (EIf (EBinOp ">=" (EVar "v") (ELit (LInt 0))) (EVar "v") (EBinOp "+" (EVar "v") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EBinOp "*" (ELit (LInt 8)) (EVar "nbytes")))))) (DoExpr (EApp (EApp (EApp (EVar "emitLeUint") (EVar "nbytes")) (EVar "unsigned")) (EVar "buf")))))
(DTypeSig true "emitLeUint" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit"))))))
(DFunDef false "emitLeUint" ((PLit (LInt 0)) PWild PWild) (ELit LUnit))
(DFunDef false "emitLeUint" ((PVar "n") (PVar "v") (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EApp (EVar "emitLeUint") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 8)))) (EVar "buf")))))
(DTypeSig true "buildArray" (TyFun (TyCon "Builder") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "buildArray" ((PCon "Builder" (PVar "a"))) (EApp (EVar "toArray") (EVar "a")))
(DTypeSig false "build1" (TyFun (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit"))) (TyEffect ("Mut") None (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "build1" ((PVar "f")) (EBlock (DoLet false false (PVar "buf") (EApp (EVar "newBuilder") (ELit LUnit))) (DoExpr (EApp (EVar "f") (EVar "buf"))) (DoExpr (EApp (EVar "buildArray") (EVar "buf")))))
(DProp false "emitU16LE/leUint 2 round-trip" ((pp "v" (TyCon "Int"))) (EBlock (DoLet false false (PVar "w") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 65535)))) (DoExpr (EMatch (EApp (EApp (EVar "runByteParser") (EApp (EVar "leUint") (ELit (LInt 2)))) (EApp (EVar "build1") (EApp (EVar "emitU16LE") (EVar "w")))) (arm (PCon "Ok" (PVar "got")) () (EBinOp "==" (EVar "got") (EVar "w"))) (arm (PCon "Err" PWild) () (EVar "False"))))))
(DProp false "emitU32LE/leUint 4 round-trip" ((pp "v" (TyCon "Int"))) (EBlock (DoLet false false (PVar "w") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 4294967295)))) (DoExpr (EMatch (EApp (EApp (EVar "runByteParser") (EApp (EVar "leUint") (ELit (LInt 4)))) (EApp (EVar "build1") (EApp (EVar "emitU32LE") (EVar "w")))) (arm (PCon "Ok" (PVar "got")) () (EBinOp "==" (EVar "got") (EVar "w"))) (arm (PCon "Err" PWild) () (EVar "False"))))))
(DProp false "emitLeSint 2/leSint 2 round-trip" ((pp "v" (TyCon "Int"))) (EBlock (DoLet false false (PVar "w") (EBinOp "-" (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 65535))) (ELit (LInt 32768)))) (DoExpr (EMatch (EApp (EApp (EVar "runByteParser") (EApp (EVar "leSint") (ELit (LInt 2)))) (EApp (EVar "build1") (EApp (EApp (EVar "emitLeSint") (ELit (LInt 2))) (EVar "w")))) (arm (PCon "Ok" (PVar "got")) () (EBinOp "==" (EVar "got") (EVar "w"))) (arm (PCon "Err" PWild) () (EVar "False"))))))
(DProp false "emitU16BE reversed bytes, leUint agrees with beUint" ((pp "v" (TyCon "Int"))) (EBlock (DoLet false false (PVar "w") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 65535)))) (DoExpr (EMatch (EApp (EApp (EVar "runByteParser") (EApp (EVar "takeBytes") (ELit (LInt 2)))) (EApp (EVar "build1") (EApp (EVar "emitU16BE") (EVar "w")))) (arm (PCon "Err" PWild) () (EVar "False")) (arm (PCon "Ok" (PVar "bytes")) () (EBlock (DoLet false false (PVar "reversedArr") (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "bytes")))) (DoExpr (EMatch (EApp (EApp (EVar "runByteParser") (EApp (EVar "leUint") (ELit (LInt 2)))) (EVar "reversedArr")) (arm (PCon "Ok" (PVar "got")) () (EBinOp "==" (EVar "got") (EVar "w"))) (arm (PCon "Err" PWild) () (EVar "False"))))))))))
# MARK
(DUse false (UseGroup ("byteparser") ((mem "runByteParser" false) (mem "beUint" false) (mem "beSint" false) (mem "leUint" false) (mem "leSint" false) (mem "takeBytes" false))))
(DUse false (UseGroup ("mut_array") ((mem "MutArray" false) (mem "new" false) (mem "push" false) (mem "toArray" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DData Abstract "Builder" () ((variant "Builder" (ConPos (TyApp (TyCon "MutArray") (TyCon "Int"))))) ())
(DTypeSig true "newBuilder" (TyFun (TyCon "Unit") (TyCon "Builder")))
(DFunDef false "newBuilder" (PWild) (EApp (EVar "Builder") (EApp (EVar "new") (ELit LUnit))))
(DTypeSig true "emitU8" (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit")))))
(DFunDef false "emitU8" ((PVar "b") (PCon "Builder" (PVar "a"))) (EApp (EApp (EVar "push") (EApp (EApp (EVar "bitAnd") (EVar "b")) (ELit (LInt 255)))) (EVar "a")))
(DTypeSig true "emitU16BE" (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit")))))
(DFunDef false "emitU16BE" ((PVar "v") (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 8)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 255)))) (EVar "buf")))))
(DTypeSig true "emitU24BE" (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit")))))
(DFunDef false "emitU24BE" ((PVar "v") (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 16)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 8)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 255)))) (EVar "buf")))))
(DTypeSig true "emitU32BE" (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit")))))
(DFunDef false "emitU32BE" ((PVar "v") (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 24)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 16)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 8)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 255)))) (EVar "buf")))))
(DTypeSig true "emitU16LE" (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit")))))
(DFunDef false "emitU16LE" ((PVar "v") (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 8)))) (ELit (LInt 255)))) (EVar "buf")))))
(DTypeSig true "emitU24LE" (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit")))))
(DFunDef false "emitU24LE" ((PVar "v") (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 8)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 16)))) (ELit (LInt 255)))) (EVar "buf")))))
(DTypeSig true "emitU32LE" (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit")))))
(DFunDef false "emitU32LE" ((PVar "v") (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 8)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 16)))) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 24)))) (ELit (LInt 255)))) (EVar "buf")))))
(DTypeSig true "emitBytes" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit")))))
(DFunDef false "emitBytes" ((PList) PWild) (ELit LUnit))
(DFunDef false "emitBytes" ((PCons (PVar "b") (PVar "rest")) (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EVar "b")) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitBytes") (EVar "rest")) (EVar "buf")))))
(DTypeSig true "emitBeSint" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit"))))))
(DFunDef false "emitBeSint" ((PVar "nbytes") (PVar "v") (PVar "buf")) (EBlock (DoLet false false (PVar "unsigned") (EIf (EBinOp ">=" (EVar "v") (ELit (LInt 0))) (EVar "v") (EBinOp "+" (EVar "v") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EBinOp "*" (ELit (LInt 8)) (EVar "nbytes")))))) (DoExpr (EApp (EApp (EApp (EVar "emitBeUint") (EVar "nbytes")) (EVar "unsigned")) (EVar "buf")))))
(DTypeSig true "emitBeUint" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit"))))))
(DFunDef false "emitBeUint" ((PLit (LInt 0)) PWild PWild) (ELit LUnit))
(DFunDef false "emitBeUint" ((PVar "n") (PVar "v") (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "emitBeUint") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 8)))) (EVar "buf"))) (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 255)))) (EVar "buf")))))
(DTypeSig true "emitLeSint" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit"))))))
(DFunDef false "emitLeSint" ((PVar "nbytes") (PVar "v") (PVar "buf")) (EBlock (DoLet false false (PVar "unsigned") (EIf (EBinOp ">=" (EVar "v") (ELit (LInt 0))) (EVar "v") (EBinOp "+" (EVar "v") (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EBinOp "*" (ELit (LInt 8)) (EVar "nbytes")))))) (DoExpr (EApp (EApp (EApp (EVar "emitLeUint") (EVar "nbytes")) (EVar "unsigned")) (EVar "buf")))))
(DTypeSig true "emitLeUint" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit"))))))
(DFunDef false "emitLeUint" ((PLit (LInt 0)) PWild PWild) (ELit LUnit))
(DFunDef false "emitLeUint" ((PVar "n") (PVar "v") (PVar "buf")) (EBlock (DoExpr (EApp (EApp (EVar "emitU8") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 255)))) (EVar "buf"))) (DoExpr (EApp (EApp (EApp (EVar "emitLeUint") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EApp (EVar "shiftRight") (EVar "v")) (ELit (LInt 8)))) (EVar "buf")))))
(DTypeSig true "buildArray" (TyFun (TyCon "Builder") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "buildArray" ((PCon "Builder" (PVar "a"))) (EApp (EVar "toArray") (EVar "a")))
(DTypeSig false "build1" (TyFun (TyFun (TyCon "Builder") (TyEffect ("Mut") None (TyCon "Unit"))) (TyEffect ("Mut") None (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "build1" ((PVar "f")) (EBlock (DoLet false false (PVar "buf") (EApp (EVar "newBuilder") (ELit LUnit))) (DoExpr (EApp (EVar "f") (EVar "buf"))) (DoExpr (EApp (EVar "buildArray") (EVar "buf")))))
(DProp false "emitU16LE/leUint 2 round-trip" ((pp "v" (TyCon "Int"))) (EBlock (DoLet false false (PVar "w") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 65535)))) (DoExpr (EMatch (EApp (EApp (EVar "runByteParser") (EApp (EVar "leUint") (ELit (LInt 2)))) (EApp (EVar "build1") (EApp (EVar "emitU16LE") (EVar "w")))) (arm (PCon "Ok" (PVar "got")) () (EBinOp "==" (EVar "got") (EVar "w"))) (arm (PCon "Err" PWild) () (EVar "False"))))))
(DProp false "emitU32LE/leUint 4 round-trip" ((pp "v" (TyCon "Int"))) (EBlock (DoLet false false (PVar "w") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 4294967295)))) (DoExpr (EMatch (EApp (EApp (EVar "runByteParser") (EApp (EVar "leUint") (ELit (LInt 4)))) (EApp (EVar "build1") (EApp (EVar "emitU32LE") (EVar "w")))) (arm (PCon "Ok" (PVar "got")) () (EBinOp "==" (EVar "got") (EVar "w"))) (arm (PCon "Err" PWild) () (EVar "False"))))))
(DProp false "emitLeSint 2/leSint 2 round-trip" ((pp "v" (TyCon "Int"))) (EBlock (DoLet false false (PVar "w") (EBinOp "-" (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 65535))) (ELit (LInt 32768)))) (DoExpr (EMatch (EApp (EApp (EVar "runByteParser") (EApp (EVar "leSint") (ELit (LInt 2)))) (EApp (EVar "build1") (EApp (EApp (EVar "emitLeSint") (ELit (LInt 2))) (EVar "w")))) (arm (PCon "Ok" (PVar "got")) () (EBinOp "==" (EVar "got") (EVar "w"))) (arm (PCon "Err" PWild) () (EVar "False"))))))
(DProp false "emitU16BE reversed bytes, leUint agrees with beUint" ((pp "v" (TyCon "Int"))) (EBlock (DoLet false false (PVar "w") (EApp (EApp (EVar "bitAnd") (EVar "v")) (ELit (LInt 65535)))) (DoExpr (EMatch (EApp (EApp (EVar "runByteParser") (EApp (EVar "takeBytes") (ELit (LInt 2)))) (EApp (EVar "build1") (EApp (EVar "emitU16BE") (EVar "w")))) (arm (PCon "Err" PWild) () (EVar "False")) (arm (PCon "Ok" (PVar "bytes")) () (EBlock (DoLet false false (PVar "reversedArr") (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "bytes")))) (DoExpr (EMatch (EApp (EApp (EVar "runByteParser") (EApp (EVar "leUint") (ELit (LInt 2)))) (EVar "reversedArr")) (arm (PCon "Ok" (PVar "got")) () (EBinOp "==" (EVar "got") (EVar "w"))) (arm (PCon "Err" PWild) () (EVar "False"))))))))))
