# META
source_lines=300
stages=DESUGAR,MARK
# SOURCE
{- bits64.mdk — 64-bit-unsigned arithmetic over the 63-bit `Int` fixnum.

   Medaka's `Int` is a 63-bit fixnum that WRAPS on overflow, so it cannot hold
   a `uint64` value (let alone a `uint64` product mod 2^64).  This module
   emulates a `uint64` as a 4-tuple of 16-bit limbs `(l0, l1, l2, l3)`,
   least-significant first — exactly the representation the compiler itself
   hand-rolled in `compiler/eval/eval.mdk` to reproduce SplitMix64 / FNV-1a
   faithfully while fixing issue #98.  The algorithms here mirror that proven
   implementation.

   Why a tuple and not a fresh `data` type: tuple instances (`Eq`, `Debug`, …)
   already live in the prelude (`core.mdk`), so this module drags no new
   instance surface and imports near-free (see `docs/stdlib/STDLIB.md`).

   Every intermediate stays well under the 63-bit range: a limb < 2^16, a
   16×16 partial product < 2^32, and a column sum of four such products plus a
   carry < 2^35 — so no native op ever overflows during a computation.

   Use it for hashing, PRNGs, checksums, and binary/wire formats — anything
   that needs the C `unsigned long long` overflow / bit semantics.  All ops are
   modulo 2^64 (they wrap), matching C's unsigned arithmetic. -}

-- Several bodies here are byte-for-byte the limb helpers `compiler/eval/eval.mdk`
-- hand-rolled for SplitMix64/FNV-1a (issue #98); mirroring that proven code is
-- the whole point of this module (issue #223).  The `rule-duplicate-body` fix —
-- "consolidate into a shared module" — is NOT available: the compiler cannot
-- import this stdlib module without a seed re-mint + fixpoint re-validation and
-- the extra always-typechecked surface (see AGENTS.md "Dogfooding"/Traps), so
-- eval.mdk keeps its own copy on purpose.
-- lint-disable-file rule-duplicate-body

import core.{Ordering}

-- A `uint64` as four 16-bit limbs, least-significant first: the value is
-- `l0 + l1*2^16 + l2*2^32 + l3*2^48`, each limb in `[0, 2^16)`.
export type U64 = (Int, Int, Int, Int)

-- ── Construction ────────────────────────────────────────────────────────

-- The all-zero `uint64`.
export zero : U64
zero = (0, 0, 0, 0)

-- The `uint64` value 1.
export one : U64
one = (1, 0, 0, 0)

{- | Split a Medaka `Int` into `uint64` limbs, masking to the low 64 bits.

   Because each 16-bit window is masked immediately, this reproduces C's
   `(unsigned long long)n` for negatives too (the two's-complement bits of a
   window are the same under either shift convention).

   (Named `ofInt`, not `fromInt`, on purpose: `fromInt` is the `Num` interface
   method in `core.mdk`, and a top-level binding of that name is absorbed as a
   method definition and poisons inference for the whole module.)

   > ofInt 1
   (1, 0, 0, 0)
   > ofInt 65536
   (0, 1, 0, 0)
   > ofInt 4294967296
   (0, 0, 1, 0) -}
export ofInt : Int -> U64
ofInt n = (
  bitAnd n 65535,
  bitAnd (shiftRight n 16) 65535,
  bitAnd (shiftRight n 32) 65535,
  bitAnd (shiftRight n 48) 65535,
)

-- ── Predicates ──────────────────────────────────────────────────────────

{- | Is this `uint64` zero?

   > isZero (ofInt 0)
   True
   > isZero (ofInt 5)
   False -}
export isZero : U64 -> Bool
isZero (a0, a1, a2, a3) = a0 == 0 && a1 == 0 && a2 == 0 && a3 == 0

{- | Compare two `uint64` values (unsigned).

   > cmp64 (ofInt 1) (ofInt 2)
   Lt
   > cmp64 (ofInt 2) (ofInt 2)
   Eq
   > cmp64 (ofInt 3) (ofInt 2)
   Gt
   > cmp64 (0, 0, 0, 1) (65535, 65535, 65535, 0)
   Gt -}
export cmp64 : U64 -> U64 -> Ordering
cmp64 (a0, a1, a2, a3) (b0, b1, b2, b3) =
  if a3 != b3 then
    if a3 > b3 then Gt else Lt
  else if a2 != b2 then
    if a2 > b2 then Gt else Lt
  else if a1 != b1 then
    if a1 > b1 then Gt else Lt
  else if a0 != b0 then
    if a0 > b0 then Gt else Lt
  else
    Eq

-- ── Arithmetic ──────────────────────────────────────────────────────────

{- | Addition mod 2^64 (wraps on overflow).

   > add64 (ofInt 1) (ofInt 2)
   (3, 0, 0, 0)
   > add64 (ofInt 65535) (ofInt 1)
   (0, 1, 0, 0)
   > add64 (65535, 65535, 65535, 65535) (ofInt 1)
   (0, 0, 0, 0) -}
export add64 : U64 -> U64 -> U64
add64 (a0, a1, a2, a3) (b0, b1, b2, b3) =
  let s0 = a0 + b0
  let s1 = a1 + b1 + shiftRight s0 16
  let s2 = a2 + b2 + shiftRight s1 16
  let s3 = a3 + b3 + shiftRight s2 16
  (bitAnd s0 65535, bitAnd s1 65535, bitAnd s2 65535, bitAnd s3 65535)

{- | Subtraction mod 2^64: `a - b`, wrapping when `b > a`.

   A negative limb difference masks to its low 16 bits (`+65536`), which IS
   the borrow into the next limb.

   > sub64 (ofInt 5) (ofInt 3)
   (2, 0, 0, 0)
   > sub64 (ofInt 0) (ofInt 1)
   (65535, 65535, 65535, 65535) -}
export sub64 : U64 -> U64 -> U64
sub64 (a0, a1, a2, a3) (b0, b1, b2, b3) =
  let d0 = a0 - b0
  let d1 = a1 - b1 - (if d0 < 0 then 1 else 0)
  let d2 = a2 - b2 - (if d1 < 0 then 1 else 0)
  let d3 = a3 - b3 - (if d2 < 0 then 1 else 0)
  (bitAnd d0 65535, bitAnd d1 65535, bitAnd d2 65535, bitAnd d3 65535)

{- | Low 64 bits of the product `a * b` (i.e. `a * b mod 2^64`) — schoolbook
   multiply keeping only the low four limbs.

   > mulLow64 (ofInt 7) (ofInt 6)
   (42, 0, 0, 0)
   > mulLow64 (ofInt 65536) (ofInt 65536)
   (0, 0, 1, 0)
   > mulLow64 (0, 0, 0, 1) (0, 1, 0, 0)
   (0, 0, 0, 0) -}
export mulLow64 : U64 -> U64 -> U64
mulLow64 (a0, a1, a2, a3) (b0, b1, b2, b3) =
  let c0 = a0 * b0
  let c1 = a0 * b1 + a1 * b0 + shiftRight c0 16
  let c2 = a0 * b2 + a1 * b1 + a2 * b0 + shiftRight c1 16
  let c3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0 + shiftRight c2 16
  (bitAnd c0 65535, bitAnd c1 65535, bitAnd c2 65535, bitAnd c3 65535)

-- ── Bitwise ─────────────────────────────────────────────────────────────

{- | Bitwise AND.

   > and64 (ofInt 12) (ofInt 10)
   (8, 0, 0, 0) -}
export and64 : U64 -> U64 -> U64
and64 (a0, a1, a2, a3) (b0, b1, b2, b3) =
  (bitAnd a0 b0, bitAnd a1 b1, bitAnd a2 b2, bitAnd a3 b3)

{- | Bitwise OR.

   > or64 (ofInt 12) (ofInt 10)
   (14, 0, 0, 0) -}
export or64 : U64 -> U64 -> U64
or64 (a0, a1, a2, a3) (b0, b1, b2, b3) =
  (bitOr a0 b0, bitOr a1 b1, bitOr a2 b2, bitOr a3 b3)

{- | Bitwise XOR.

   > xor64 (ofInt 12) (ofInt 10)
   (6, 0, 0, 0) -}
export xor64 : U64 -> U64 -> U64
xor64 (a0, a1, a2, a3) (b0, b1, b2, b3) =
  (bitXor a0 b0, bitXor a1 b1, bitXor a2 b2, bitXor a3 b3)

-- Limb `i` of a `uint64` (0 for `i < 0` or `i > 3`).
limbAt : U64 -> Int -> Int
limbAt (a0, a1, a2, a3) i =
  if i == 0 then
    a0
  else if i == 1 then
    a1
  else if i == 2 then
    a2
  else if i == 3 then
    a3
  else
    0

-- Whole-limb offset for a shift of `n` bits (n in [0, 63]).
shiftWords : Int -> Int
shiftWords n =
  if n >= 48 then
    3
  else if n >= 32 then
    2
  else if n >= 16 then
    1
  else
    0

-- One output limb of a logical right shift: low bits of limb `(i+ws)` plus the
-- carried-in low bits of limb `(i+ws+1)`.
shrLimb : U64 -> Int -> Int -> Int -> Int
shrLimb u ws bs i =
  bitAnd
    (bitOr
      (shiftRight (limbAt u (i + ws)) bs)
      (shiftLeft (limbAt u (i + ws + 1)) (16 - bs)))
    65535

{- | Logical right shift by `n` bits, `n` in `[0, 63]`.  Vacated high bits are
   filled with zeros (unsigned shift).

   > shr64 (ofInt 256) 4
   (16, 0, 0, 0)
   > shr64 (ofInt 65536) 16
   (1, 0, 0, 0)
   > shr64 (0, 0, 0, 32768) 63
   (1, 0, 0, 0) -}
export shr64 : U64 -> Int -> U64
shr64 u n =
  let ws = shiftWords n
  let bs = n - ws * 16
  (shrLimb u ws bs 0, shrLimb u ws bs 1, shrLimb u ws bs 2, shrLimb u ws bs 3)

-- One output limb of a left shift: high bits of limb `(i-ws)` plus the
-- carried-in high bits of limb `(i-ws-1)`.
shlLimb : U64 -> Int -> Int -> Int -> Int
shlLimb u ws bs i =
  bitAnd
    (bitOr
      (shiftLeft (limbAt u (i - ws)) bs)
      (shiftRight (limbAt u (i - ws - 1)) (16 - bs)))
    65535

{- | Logical left shift by `n` bits, `n` in `[0, 63]`.  Bits shifted past bit
   63 are dropped (mod 2^64).

   > shl64 (ofInt 1) 4
   (16, 0, 0, 0)
   > shl64 (ofInt 1) 16
   (0, 1, 0, 0)
   > shl64 (ofInt 1) 63
   (0, 0, 0, 32768) -}
export shl64 : U64 -> Int -> U64
shl64 u n =
  let ws = shiftWords n
  let bs = n - ws * 16
  (shlLimb u ws bs 0, shlLimb u ws bs 1, shlLimb u ws bs 2, shlLimb u ws bs 3)

-- ── Division ────────────────────────────────────────────────────────────

-- Bit `i` (0 = LSB) of a `uint64`.
bitAt : U64 -> Int -> Int
bitAt u i = bitAnd (limbAt (shr64 u i) 0) 1

-- Schoolbook bit-by-bit long division, MSB first, kept entirely inside the
-- limb rep so nothing overflows a bare 63-bit Int.  Accumulates the remainder.
modGo : U64 -> U64 -> U64 -> Int -> U64
modGo dividend divisor rem i =
  if i < 0 then rem
  else
    let shifted = add64 rem rem
    let bit = bitAt dividend i
    let rem2 = (
      bitOr (limbAt shifted 0) bit,
      limbAt shifted 1,
      limbAt shifted 2,
      limbAt shifted 3,
    )
    let rem3 = match cmp64 rem2 divisor
      Lt => rem2
      _ => sub64 rem2 divisor
    modGo dividend divisor rem3 (i - 1)

{- | Exact `uint64` modulo: `dividend mod divisor`, correct for any nonzero
   divisor up to 2^64 - 1 (a running-remainder shortcut would be wrong for
   large divisors).  A zero divisor is a caller error and yields `dividend`.

   > mod64 (ofInt 17) (ofInt 5)
   (2, 0, 0, 0)
   > mod64 (65535, 65535, 65535, 65535) (ofInt 10)
   (5, 0, 0, 0)
   > mod64 (0, 0, 0, 32768) (ofInt 3)
   (2, 0, 0, 0) -}
export mod64 : U64 -> U64 -> U64
mod64 dividend divisor =
  if isZero divisor then
    dividend
  else
    modGo dividend divisor zero 63
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Ordering" false))))
(DTypeAlias true "U64" () (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))
(DTypeSig true "zero" (TyCon "U64"))
(DFunDef false "zero" () (ETuple (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0))))
(DTypeSig true "one" (TyCon "U64"))
(DFunDef false "one" () (ETuple (ELit (LInt 1)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0))))
(DTypeSig true "ofInt" (TyFun (TyCon "Int") (TyCon "U64")))
(DFunDef false "ofInt" ((PVar "n")) (ETuple (EApp (EApp (EVar "bitAnd") (EVar "n")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 16)))) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 32)))) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 48)))) (ELit (LInt 65535)))))
(DTypeSig true "isZero" (TyFun (TyCon "U64") (TyCon "Bool")))
(DFunDef false "isZero" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "a0") (ELit (LInt 0))) (EBinOp "==" (EVar "a1") (ELit (LInt 0)))) (EBinOp "==" (EVar "a2") (ELit (LInt 0)))) (EBinOp "==" (EVar "a3") (ELit (LInt 0)))))
(DTypeSig true "cmp64" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "Ordering"))))
(DFunDef false "cmp64" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PTuple (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EIf (EBinOp "!=" (EVar "a3") (EVar "b3")) (EIf (EBinOp ">" (EVar "a3") (EVar "b3")) (EVar "Gt") (EVar "Lt")) (EIf (EBinOp "!=" (EVar "a2") (EVar "b2")) (EIf (EBinOp ">" (EVar "a2") (EVar "b2")) (EVar "Gt") (EVar "Lt")) (EIf (EBinOp "!=" (EVar "a1") (EVar "b1")) (EIf (EBinOp ">" (EVar "a1") (EVar "b1")) (EVar "Gt") (EVar "Lt")) (EIf (EBinOp "!=" (EVar "a0") (EVar "b0")) (EIf (EBinOp ">" (EVar "a0") (EVar "b0")) (EVar "Gt") (EVar "Lt")) (EVar "Eq"))))))
(DTypeSig true "add64" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "add64" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PTuple (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EBlock (DoLet false false (PVar "s0") (EBinOp "+" (EVar "a0") (EVar "b0"))) (DoLet false false (PVar "s1") (EBinOp "+" (EBinOp "+" (EVar "a1") (EVar "b1")) (EApp (EApp (EVar "shiftRight") (EVar "s0")) (ELit (LInt 16))))) (DoLet false false (PVar "s2") (EBinOp "+" (EBinOp "+" (EVar "a2") (EVar "b2")) (EApp (EApp (EVar "shiftRight") (EVar "s1")) (ELit (LInt 16))))) (DoLet false false (PVar "s3") (EBinOp "+" (EBinOp "+" (EVar "a3") (EVar "b3")) (EApp (EApp (EVar "shiftRight") (EVar "s2")) (ELit (LInt 16))))) (DoExpr (ETuple (EApp (EApp (EVar "bitAnd") (EVar "s0")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "s1")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "s2")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "s3")) (ELit (LInt 65535)))))))
(DTypeSig true "sub64" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "sub64" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PTuple (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EBlock (DoLet false false (PVar "d0") (EBinOp "-" (EVar "a0") (EVar "b0"))) (DoLet false false (PVar "d1") (EBinOp "-" (EBinOp "-" (EVar "a1") (EVar "b1")) (EIf (EBinOp "<" (EVar "d0") (ELit (LInt 0))) (ELit (LInt 1)) (ELit (LInt 0))))) (DoLet false false (PVar "d2") (EBinOp "-" (EBinOp "-" (EVar "a2") (EVar "b2")) (EIf (EBinOp "<" (EVar "d1") (ELit (LInt 0))) (ELit (LInt 1)) (ELit (LInt 0))))) (DoLet false false (PVar "d3") (EBinOp "-" (EBinOp "-" (EVar "a3") (EVar "b3")) (EIf (EBinOp "<" (EVar "d2") (ELit (LInt 0))) (ELit (LInt 1)) (ELit (LInt 0))))) (DoExpr (ETuple (EApp (EApp (EVar "bitAnd") (EVar "d0")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "d1")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "d2")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "d3")) (ELit (LInt 65535)))))))
(DTypeSig true "mulLow64" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "mulLow64" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PTuple (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EBlock (DoLet false false (PVar "c0") (EBinOp "*" (EVar "a0") (EVar "b0"))) (DoLet false false (PVar "c1") (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "a0") (EVar "b1")) (EBinOp "*" (EVar "a1") (EVar "b0"))) (EApp (EApp (EVar "shiftRight") (EVar "c0")) (ELit (LInt 16))))) (DoLet false false (PVar "c2") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "a0") (EVar "b2")) (EBinOp "*" (EVar "a1") (EVar "b1"))) (EBinOp "*" (EVar "a2") (EVar "b0"))) (EApp (EApp (EVar "shiftRight") (EVar "c1")) (ELit (LInt 16))))) (DoLet false false (PVar "c3") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "a0") (EVar "b3")) (EBinOp "*" (EVar "a1") (EVar "b2"))) (EBinOp "*" (EVar "a2") (EVar "b1"))) (EBinOp "*" (EVar "a3") (EVar "b0"))) (EApp (EApp (EVar "shiftRight") (EVar "c2")) (ELit (LInt 16))))) (DoExpr (ETuple (EApp (EApp (EVar "bitAnd") (EVar "c0")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "c1")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "c2")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "c3")) (ELit (LInt 65535)))))))
(DTypeSig true "and64" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "and64" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PTuple (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (ETuple (EApp (EApp (EVar "bitAnd") (EVar "a0")) (EVar "b0")) (EApp (EApp (EVar "bitAnd") (EVar "a1")) (EVar "b1")) (EApp (EApp (EVar "bitAnd") (EVar "a2")) (EVar "b2")) (EApp (EApp (EVar "bitAnd") (EVar "a3")) (EVar "b3"))))
(DTypeSig true "or64" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "or64" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PTuple (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (ETuple (EApp (EApp (EVar "bitOr") (EVar "a0")) (EVar "b0")) (EApp (EApp (EVar "bitOr") (EVar "a1")) (EVar "b1")) (EApp (EApp (EVar "bitOr") (EVar "a2")) (EVar "b2")) (EApp (EApp (EVar "bitOr") (EVar "a3")) (EVar "b3"))))
(DTypeSig true "xor64" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "xor64" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PTuple (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (ETuple (EApp (EApp (EVar "bitXor") (EVar "a0")) (EVar "b0")) (EApp (EApp (EVar "bitXor") (EVar "a1")) (EVar "b1")) (EApp (EApp (EVar "bitXor") (EVar "a2")) (EVar "b2")) (EApp (EApp (EVar "bitXor") (EVar "a3")) (EVar "b3"))))
(DTypeSig false "limbAt" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "limbAt" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PVar "i")) (EIf (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EVar "a0") (EIf (EBinOp "==" (EVar "i") (ELit (LInt 1))) (EVar "a1") (EIf (EBinOp "==" (EVar "i") (ELit (LInt 2))) (EVar "a2") (EIf (EBinOp "==" (EVar "i") (ELit (LInt 3))) (EVar "a3") (ELit (LInt 0)))))))
(DTypeSig false "shiftWords" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "shiftWords" ((PVar "n")) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 48))) (ELit (LInt 3)) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 32))) (ELit (LInt 2)) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 16))) (ELit (LInt 1)) (ELit (LInt 0))))))
(DTypeSig false "shrLimb" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "shrLimb" ((PVar "u") (PVar "ws") (PVar "bs") (PVar "i")) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftRight") (EApp (EApp (EVar "limbAt") (EVar "u")) (EBinOp "+" (EVar "i") (EVar "ws")))) (EVar "bs"))) (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "limbAt") (EVar "u")) (EBinOp "+" (EBinOp "+" (EVar "i") (EVar "ws")) (ELit (LInt 1))))) (EBinOp "-" (ELit (LInt 16)) (EVar "bs"))))) (ELit (LInt 65535))))
(DTypeSig true "shr64" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyCon "U64"))))
(DFunDef false "shr64" ((PVar "u") (PVar "n")) (EBlock (DoLet false false (PVar "ws") (EApp (EVar "shiftWords") (EVar "n"))) (DoLet false false (PVar "bs") (EBinOp "-" (EVar "n") (EBinOp "*" (EVar "ws") (ELit (LInt 16))))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "shrLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "shrLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 1))) (EApp (EApp (EApp (EApp (EVar "shrLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 2))) (EApp (EApp (EApp (EApp (EVar "shrLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 3)))))))
(DTypeSig false "shlLimb" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "shlLimb" ((PVar "u") (PVar "ws") (PVar "bs") (PVar "i")) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "limbAt") (EVar "u")) (EBinOp "-" (EVar "i") (EVar "ws")))) (EVar "bs"))) (EApp (EApp (EVar "shiftRight") (EApp (EApp (EVar "limbAt") (EVar "u")) (EBinOp "-" (EBinOp "-" (EVar "i") (EVar "ws")) (ELit (LInt 1))))) (EBinOp "-" (ELit (LInt 16)) (EVar "bs"))))) (ELit (LInt 65535))))
(DTypeSig true "shl64" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyCon "U64"))))
(DFunDef false "shl64" ((PVar "u") (PVar "n")) (EBlock (DoLet false false (PVar "ws") (EApp (EVar "shiftWords") (EVar "n"))) (DoLet false false (PVar "bs") (EBinOp "-" (EVar "n") (EBinOp "*" (EVar "ws") (ELit (LInt 16))))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "shlLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "shlLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 1))) (EApp (EApp (EApp (EApp (EVar "shlLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 2))) (EApp (EApp (EApp (EApp (EVar "shlLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 3)))))))
(DTypeSig false "bitAt" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "bitAt" ((PVar "u") (PVar "i")) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "limbAt") (EApp (EApp (EVar "shr64") (EVar "u")) (EVar "i"))) (ELit (LInt 0)))) (ELit (LInt 1))))
(DTypeSig false "modGo" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyCon "U64"))))))
(DFunDef false "modGo" ((PVar "dividend") (PVar "divisor") (PVar "rem") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "rem") (EBlock (DoLet false false (PVar "shifted") (EApp (EApp (EVar "add64") (EVar "rem")) (EVar "rem"))) (DoLet false false (PVar "bit") (EApp (EApp (EVar "bitAt") (EVar "dividend")) (EVar "i"))) (DoLet false false (PVar "rem2") (ETuple (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "limbAt") (EVar "shifted")) (ELit (LInt 0)))) (EVar "bit")) (EApp (EApp (EVar "limbAt") (EVar "shifted")) (ELit (LInt 1))) (EApp (EApp (EVar "limbAt") (EVar "shifted")) (ELit (LInt 2))) (EApp (EApp (EVar "limbAt") (EVar "shifted")) (ELit (LInt 3))))) (DoLet false false (PVar "rem3") (EMatch (EApp (EApp (EVar "cmp64") (EVar "rem2")) (EVar "divisor")) (arm (PCon "Lt") () (EVar "rem2")) (arm PWild () (EApp (EApp (EVar "sub64") (EVar "rem2")) (EVar "divisor"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "modGo") (EVar "dividend")) (EVar "divisor")) (EVar "rem3")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig true "mod64" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "mod64" ((PVar "dividend") (PVar "divisor")) (EIf (EApp (EVar "isZero") (EVar "divisor")) (EVar "dividend") (EApp (EApp (EApp (EApp (EVar "modGo") (EVar "dividend")) (EVar "divisor")) (EVar "zero")) (ELit (LInt 63)))))
# MARK
(DUse false (UseGroup ("core") ((mem "Ordering" false))))
(DTypeAlias true "U64" () (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))
(DTypeSig true "zero" (TyCon "U64"))
(DFunDef false "zero" () (ETuple (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0))))
(DTypeSig true "one" (TyCon "U64"))
(DFunDef false "one" () (ETuple (ELit (LInt 1)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0))))
(DTypeSig true "ofInt" (TyFun (TyCon "Int") (TyCon "U64")))
(DFunDef false "ofInt" ((PVar "n")) (ETuple (EApp (EApp (EVar "bitAnd") (EVar "n")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 16)))) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 32)))) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 48)))) (ELit (LInt 65535)))))
(DTypeSig true "isZero" (TyFun (TyCon "U64") (TyCon "Bool")))
(DFunDef false "isZero" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "a0") (ELit (LInt 0))) (EBinOp "==" (EVar "a1") (ELit (LInt 0)))) (EBinOp "==" (EVar "a2") (ELit (LInt 0)))) (EBinOp "==" (EVar "a3") (ELit (LInt 0)))))
(DTypeSig true "cmp64" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "Ordering"))))
(DFunDef false "cmp64" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PTuple (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EIf (EBinOp "!=" (EVar "a3") (EVar "b3")) (EIf (EBinOp ">" (EVar "a3") (EVar "b3")) (EVar "Gt") (EVar "Lt")) (EIf (EBinOp "!=" (EVar "a2") (EVar "b2")) (EIf (EBinOp ">" (EVar "a2") (EVar "b2")) (EVar "Gt") (EVar "Lt")) (EIf (EBinOp "!=" (EVar "a1") (EVar "b1")) (EIf (EBinOp ">" (EVar "a1") (EVar "b1")) (EVar "Gt") (EVar "Lt")) (EIf (EBinOp "!=" (EVar "a0") (EVar "b0")) (EIf (EBinOp ">" (EVar "a0") (EVar "b0")) (EVar "Gt") (EVar "Lt")) (EVar "Eq"))))))
(DTypeSig true "add64" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "add64" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PTuple (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EBlock (DoLet false false (PVar "s0") (EBinOp "+" (EVar "a0") (EVar "b0"))) (DoLet false false (PVar "s1") (EBinOp "+" (EBinOp "+" (EVar "a1") (EVar "b1")) (EApp (EApp (EVar "shiftRight") (EVar "s0")) (ELit (LInt 16))))) (DoLet false false (PVar "s2") (EBinOp "+" (EBinOp "+" (EVar "a2") (EVar "b2")) (EApp (EApp (EVar "shiftRight") (EVar "s1")) (ELit (LInt 16))))) (DoLet false false (PVar "s3") (EBinOp "+" (EBinOp "+" (EVar "a3") (EVar "b3")) (EApp (EApp (EVar "shiftRight") (EVar "s2")) (ELit (LInt 16))))) (DoExpr (ETuple (EApp (EApp (EVar "bitAnd") (EVar "s0")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "s1")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "s2")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "s3")) (ELit (LInt 65535)))))))
(DTypeSig true "sub64" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "sub64" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PTuple (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EBlock (DoLet false false (PVar "d0") (EBinOp "-" (EVar "a0") (EVar "b0"))) (DoLet false false (PVar "d1") (EBinOp "-" (EBinOp "-" (EVar "a1") (EVar "b1")) (EIf (EBinOp "<" (EVar "d0") (ELit (LInt 0))) (ELit (LInt 1)) (ELit (LInt 0))))) (DoLet false false (PVar "d2") (EBinOp "-" (EBinOp "-" (EVar "a2") (EVar "b2")) (EIf (EBinOp "<" (EVar "d1") (ELit (LInt 0))) (ELit (LInt 1)) (ELit (LInt 0))))) (DoLet false false (PVar "d3") (EBinOp "-" (EBinOp "-" (EVar "a3") (EVar "b3")) (EIf (EBinOp "<" (EVar "d2") (ELit (LInt 0))) (ELit (LInt 1)) (ELit (LInt 0))))) (DoExpr (ETuple (EApp (EApp (EVar "bitAnd") (EVar "d0")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "d1")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "d2")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "d3")) (ELit (LInt 65535)))))))
(DTypeSig true "mulLow64" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "mulLow64" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PTuple (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EBlock (DoLet false false (PVar "c0") (EBinOp "*" (EVar "a0") (EVar "b0"))) (DoLet false false (PVar "c1") (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "a0") (EVar "b1")) (EBinOp "*" (EVar "a1") (EVar "b0"))) (EApp (EApp (EVar "shiftRight") (EVar "c0")) (ELit (LInt 16))))) (DoLet false false (PVar "c2") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "a0") (EVar "b2")) (EBinOp "*" (EVar "a1") (EVar "b1"))) (EBinOp "*" (EVar "a2") (EVar "b0"))) (EApp (EApp (EVar "shiftRight") (EVar "c1")) (ELit (LInt 16))))) (DoLet false false (PVar "c3") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "a0") (EVar "b3")) (EBinOp "*" (EVar "a1") (EVar "b2"))) (EBinOp "*" (EVar "a2") (EVar "b1"))) (EBinOp "*" (EVar "a3") (EVar "b0"))) (EApp (EApp (EVar "shiftRight") (EVar "c2")) (ELit (LInt 16))))) (DoExpr (ETuple (EApp (EApp (EVar "bitAnd") (EVar "c0")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "c1")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "c2")) (ELit (LInt 65535))) (EApp (EApp (EVar "bitAnd") (EVar "c3")) (ELit (LInt 65535)))))))
(DTypeSig true "and64" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "and64" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PTuple (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (ETuple (EApp (EApp (EVar "bitAnd") (EVar "a0")) (EVar "b0")) (EApp (EApp (EVar "bitAnd") (EVar "a1")) (EVar "b1")) (EApp (EApp (EVar "bitAnd") (EVar "a2")) (EVar "b2")) (EApp (EApp (EVar "bitAnd") (EVar "a3")) (EVar "b3"))))
(DTypeSig true "or64" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "or64" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PTuple (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (ETuple (EApp (EApp (EVar "bitOr") (EVar "a0")) (EVar "b0")) (EApp (EApp (EVar "bitOr") (EVar "a1")) (EVar "b1")) (EApp (EApp (EVar "bitOr") (EVar "a2")) (EVar "b2")) (EApp (EApp (EVar "bitOr") (EVar "a3")) (EVar "b3"))))
(DTypeSig true "xor64" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "xor64" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PTuple (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (ETuple (EApp (EApp (EVar "bitXor") (EVar "a0")) (EVar "b0")) (EApp (EApp (EVar "bitXor") (EVar "a1")) (EVar "b1")) (EApp (EApp (EVar "bitXor") (EVar "a2")) (EVar "b2")) (EApp (EApp (EVar "bitXor") (EVar "a3")) (EVar "b3"))))
(DTypeSig false "limbAt" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "limbAt" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PVar "i")) (EIf (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EVar "a0") (EIf (EBinOp "==" (EVar "i") (ELit (LInt 1))) (EVar "a1") (EIf (EBinOp "==" (EVar "i") (ELit (LInt 2))) (EVar "a2") (EIf (EBinOp "==" (EVar "i") (ELit (LInt 3))) (EVar "a3") (ELit (LInt 0)))))))
(DTypeSig false "shiftWords" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "shiftWords" ((PVar "n")) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 48))) (ELit (LInt 3)) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 32))) (ELit (LInt 2)) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 16))) (ELit (LInt 1)) (ELit (LInt 0))))))
(DTypeSig false "shrLimb" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "shrLimb" ((PVar "u") (PVar "ws") (PVar "bs") (PVar "i")) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftRight") (EApp (EApp (EVar "limbAt") (EVar "u")) (EBinOp "+" (EVar "i") (EVar "ws")))) (EVar "bs"))) (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "limbAt") (EVar "u")) (EBinOp "+" (EBinOp "+" (EVar "i") (EVar "ws")) (ELit (LInt 1))))) (EBinOp "-" (ELit (LInt 16)) (EVar "bs"))))) (ELit (LInt 65535))))
(DTypeSig true "shr64" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyCon "U64"))))
(DFunDef false "shr64" ((PVar "u") (PVar "n")) (EBlock (DoLet false false (PVar "ws") (EApp (EVar "shiftWords") (EVar "n"))) (DoLet false false (PVar "bs") (EBinOp "-" (EVar "n") (EBinOp "*" (EVar "ws") (ELit (LInt 16))))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "shrLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "shrLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 1))) (EApp (EApp (EApp (EApp (EVar "shrLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 2))) (EApp (EApp (EApp (EApp (EVar "shrLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 3)))))))
(DTypeSig false "shlLimb" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "shlLimb" ((PVar "u") (PVar "ws") (PVar "bs") (PVar "i")) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "limbAt") (EVar "u")) (EBinOp "-" (EVar "i") (EVar "ws")))) (EVar "bs"))) (EApp (EApp (EVar "shiftRight") (EApp (EApp (EVar "limbAt") (EVar "u")) (EBinOp "-" (EBinOp "-" (EVar "i") (EVar "ws")) (ELit (LInt 1))))) (EBinOp "-" (ELit (LInt 16)) (EVar "bs"))))) (ELit (LInt 65535))))
(DTypeSig true "shl64" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyCon "U64"))))
(DFunDef false "shl64" ((PVar "u") (PVar "n")) (EBlock (DoLet false false (PVar "ws") (EApp (EVar "shiftWords") (EVar "n"))) (DoLet false false (PVar "bs") (EBinOp "-" (EVar "n") (EBinOp "*" (EVar "ws") (ELit (LInt 16))))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "shlLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "shlLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 1))) (EApp (EApp (EApp (EApp (EVar "shlLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 2))) (EApp (EApp (EApp (EApp (EVar "shlLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 3)))))))
(DTypeSig false "bitAt" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "bitAt" ((PVar "u") (PVar "i")) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "limbAt") (EApp (EApp (EVar "shr64") (EVar "u")) (EVar "i"))) (ELit (LInt 0)))) (ELit (LInt 1))))
(DTypeSig false "modGo" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyCon "U64"))))))
(DFunDef false "modGo" ((PVar "dividend") (PVar "divisor") (PVar "rem") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "rem") (EBlock (DoLet false false (PVar "shifted") (EApp (EApp (EVar "add64") (EVar "rem")) (EVar "rem"))) (DoLet false false (PVar "bit") (EApp (EApp (EVar "bitAt") (EVar "dividend")) (EVar "i"))) (DoLet false false (PVar "rem2") (ETuple (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "limbAt") (EVar "shifted")) (ELit (LInt 0)))) (EVar "bit")) (EApp (EApp (EVar "limbAt") (EVar "shifted")) (ELit (LInt 1))) (EApp (EApp (EVar "limbAt") (EVar "shifted")) (ELit (LInt 2))) (EApp (EApp (EVar "limbAt") (EVar "shifted")) (ELit (LInt 3))))) (DoLet false false (PVar "rem3") (EMatch (EApp (EApp (EVar "cmp64") (EVar "rem2")) (EVar "divisor")) (arm (PCon "Lt") () (EVar "rem2")) (arm PWild () (EApp (EApp (EVar "sub64") (EVar "rem2")) (EVar "divisor"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "modGo") (EVar "dividend")) (EVar "divisor")) (EVar "rem3")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig true "mod64" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "mod64" ((PVar "dividend") (PVar "divisor")) (EIf (EApp (EVar "isZero") (EVar "divisor")) (EVar "dividend") (EApp (EApp (EApp (EApp (EVar "modGo") (EVar "dividend")) (EVar "divisor")) (EVar "zero")) (ELit (LInt 63)))))
