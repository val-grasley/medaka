# META
source_lines=188
stages=DESUGAR,MARK
# SOURCE
{- math.mdk — floating-point math: roots, transcendentals, rounding, and a
   handful of pure integer helpers.

   See STDLIB.md for the module plan.

   This is a thin pure-Medaka layer over the libm externs declared in
   stdlib/runtime.mdk (`sqrt`/`exp`/`log`/`sin`/… — 22 one- and two-arg
   Float functions, each a direct call into the C runtime's math.h shim).
   The externs themselves are globally in scope (like every runtime
   primitive); this module adds the derived conveniences on top of them.

   Constants `pi` and `e` are runtime externs (see runtime.mdk) and are
   available unqualified everywhere — this module just documents them here.

   ── Backend scope ──────────────────────────────────────────────────────
   The math externs are NATIVE / LLVM only.  Wasm currently ports only five
   float externs; every other float extern (including this batch AND the
   pre-existing `floatRem`) routes to a trap on the WasmGC backend.  Wasm
   math is a native-only residual: the transcendentals need a host-import
   seam or a polyfill and are DEFERRED.  On native (`medaka run` / `build`)
   everything here works.

   ── What is NOT here (already generic in the prelude) ──────────────────
   • `abs` / `signum` — `Num Float` methods in core (use them directly).
   • `min` / `max` / `clamp` — `Ord`-generic in core; `clamp lo hi x`
     already works for Float, so there is no Float-specific `clampF`. -}

-- ── Angle conversion ────────────────────────────────────────────────────

-- | Convert degrees to radians.
--
-- > toRadians 0.0
-- 0.0
export toRadians : Float -> Float
toRadians deg = deg * pi / 180.0

-- | Convert radians to degrees.
--
-- > toDegrees 0.0
-- 0.0
export toDegrees : Float -> Float
toDegrees rad = rad * 180.0 / pi

-- ── Float predicates ────────────────────────────────────────────────────

-- | True iff the argument is NaN (the only value not equal to itself).
--
-- > isNaN 1.0
-- False
export isNaN : Float -> Bool
isNaN x = x != x

-- | True iff the argument is positive or negative infinity.  A finite `x`
--   has `x - x == 0.0`; an infinite `x` has `x - x == NaN`.
--
-- > isInfinite 1.0
-- False
export isInfinite : Float -> Bool
isInfinite x = not (isNaN x) && isNaN (x - x)

-- ── Logarithms ──────────────────────────────────────────────────────────

-- | Logarithm of `x` in an arbitrary base: `logBase b x = log x / log b`.
--
-- > logBase 2.0 8.0
-- 3.0
-- > logBase 10.0 1000.0
-- 3.0
export logBase : Float -> Float -> Float
logBase base x = log x / log base

-- ── Pure integer helpers ────────────────────────────────────────────────

-- | Greatest common divisor via the Euclidean algorithm, on absolute
--   values so the result is non-negative.  `gcdInt 0 0 = 0`.
--
-- > gcdInt 12 18
-- 6
-- > gcdInt 17 5
-- 1
export gcdInt : Int -> Int -> Int
gcdInt a b = gcdGo (absInt a) (absInt b)

gcdGo : Int -> Int -> Int
gcdGo a 0 = a
gcdGo a b = gcdGo b (a % b)

-- | Least common multiple, non-negative.  `lcmInt _ 0 = 0`.
--
-- > lcmInt 4 6
-- 12
-- > lcmInt 3 5
-- 15
export lcmInt : Int -> Int -> Int
lcmInt 0 _ = 0
lcmInt _ 0 = 0
lcmInt a b = absInt (a / gcdInt a b * b)

-- | Integer exponentiation by squaring.  A non-positive exponent yields 1
--   (the empty product); `powInt b 0 = 1` for any `b`.
--
-- > powInt 2 10
-- 1024
-- > powInt 3 0
-- 1
-- > powInt 5 3
-- 125
export powInt : Int -> Int -> Int
powInt _ 0 = 1
powInt b n = if n < 0 then 1 else powGo b n 1

powGo : Int -> Int -> Int -> Int
powGo _ 0 acc = acc
powGo b n acc =
  let acc2 = if n % 2 == 1 then acc * b else acc
  powGo (b * b) (n / 2) acc2

-- Absolute value on Int (local helper — core's `abs` is a Num method but a
-- monomorphic helper keeps the fast integer path here self-contained).
absInt : Int -> Int
absInt n = if n < 0 then 0 - n else n

-- ── Doctests for a sample of the raw libm externs (native only) ─────────
-- These externs come straight from runtime.mdk; a representative sample is
-- doctested here since being in this module's scope re-exposes them.
--
-- > sqrt 4.0
-- 2.0
-- > sqrt 9.0
-- 3.0
-- > cbrt 27.0
-- 3.0
-- > exp 0.0
-- 1.0
-- > log e
-- 1.0
-- > log2 8.0
-- 3.0
-- > log10 1000.0
-- 3.0
-- > sin 0.0
-- 0.0
-- > cos 0.0
-- 1.0
-- > tan 0.0
-- 0.0
-- > asin 0.0
-- 0.0
-- > acos 1.0
-- 0.0
-- > atan 0.0
-- 0.0
-- > sinh 0.0
-- 0.0
-- > cosh 0.0
-- 1.0
-- > tanh 0.0
-- 0.0
-- > floor 3.7
-- 3.0
-- > ceil 3.2
-- 4.0
-- > round 2.5
-- 3.0
-- > trunc 3.9
-- 3.0
-- > pow 2.0 3.0
-- 8.0
-- > atan2 0.0 1.0
-- 0.0
-- > hypot 3.0 4.0
-- 5.0

-- ── Property tests (integer helpers — exact, sign-safe) ─────────────────

prop "gcdInt is commutative" (a : Int) (b : Int) = eq (gcdInt a b) (gcdInt b a)

prop "gcdInt divides both arguments (when nonzero)" (a : Int) (b : Int) =
  let g = gcdInt a b
  eq g 0 || a % g == 0 && b % g == 0

prop "lcmInt is commutative" (a : Int) (b : Int) = eq (lcmInt a b) (lcmInt b a)

prop "powInt b 2 equals b * b" (b : Int) = eq (powInt b 2) (b * b)

prop "powInt b 1 equals b" (b : Int) = eq (powInt b 1) b

prop "powInt b 0 equals 1" (b : Int) = eq (powInt b 0) 1
# DESUGAR
(DTypeSig true "toRadians" (TyFun (TyCon "Float") (TyCon "Float")))
(DFunDef false "toRadians" ((PVar "deg")) (EBinOp "/" (EBinOp "*" (EVar "deg") (EVar "pi")) (ELit (LFloat 180.0))))
(DTypeSig true "toDegrees" (TyFun (TyCon "Float") (TyCon "Float")))
(DFunDef false "toDegrees" ((PVar "rad")) (EBinOp "/" (EBinOp "*" (EVar "rad") (ELit (LFloat 180.0))) (EVar "pi")))
(DTypeSig true "isNaN" (TyFun (TyCon "Float") (TyCon "Bool")))
(DFunDef false "isNaN" ((PVar "x")) (EBinOp "!=" (EVar "x") (EVar "x")))
(DTypeSig true "isInfinite" (TyFun (TyCon "Float") (TyCon "Bool")))
(DFunDef false "isInfinite" ((PVar "x")) (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isNaN") (EVar "x"))) (EApp (EVar "isNaN") (EBinOp "-" (EVar "x") (EVar "x")))))
(DTypeSig true "logBase" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float"))))
(DFunDef false "logBase" ((PVar "base") (PVar "x")) (EBinOp "/" (EApp (EVar "log") (EVar "x")) (EApp (EVar "log") (EVar "base"))))
(DTypeSig true "gcdInt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "gcdInt" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "gcdGo") (EApp (EVar "absInt") (EVar "a"))) (EApp (EVar "absInt") (EVar "b"))))
(DTypeSig false "gcdGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "gcdGo" ((PVar "a") (PLit (LInt 0))) (EVar "a"))
(DFunDef false "gcdGo" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "gcdGo") (EVar "b")) (EBinOp "%" (EVar "a") (EVar "b"))))
(DTypeSig true "lcmInt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lcmInt" ((PLit (LInt 0)) PWild) (ELit (LInt 0)))
(DFunDef false "lcmInt" (PWild (PLit (LInt 0))) (ELit (LInt 0)))
(DFunDef false "lcmInt" ((PVar "a") (PVar "b")) (EApp (EVar "absInt") (EBinOp "*" (EBinOp "/" (EVar "a") (EApp (EApp (EVar "gcdInt") (EVar "a")) (EVar "b"))) (EVar "b"))))
(DTypeSig true "powInt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "powInt" (PWild (PLit (LInt 0))) (ELit (LInt 1)))
(DFunDef false "powInt" ((PVar "b") (PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (ELit (LInt 1)) (EApp (EApp (EApp (EVar "powGo") (EVar "b")) (EVar "n")) (ELit (LInt 1)))))
(DTypeSig false "powGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "powGo" (PWild (PLit (LInt 0)) (PVar "acc")) (EVar "acc"))
(DFunDef false "powGo" ((PVar "b") (PVar "n") (PVar "acc")) (EBlock (DoLet false false (PVar "acc2") (EIf (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 1))) (EBinOp "*" (EVar "acc") (EVar "b")) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EVar "powGo") (EBinOp "*" (EVar "b") (EVar "b"))) (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (EVar "acc2")))))
(DTypeSig false "absInt" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "absInt" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")))
(DProp false "gcdInt is commutative" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "gcdInt") (EVar "a")) (EVar "b"))) (EApp (EApp (EVar "gcdInt") (EVar "b")) (EVar "a"))))
(DProp false "gcdInt divides both arguments (when nonzero)" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EBlock (DoLet false false (PVar "g") (EApp (EApp (EVar "gcdInt") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "||" (EApp (EApp (EVar "eq") (EVar "g")) (ELit (LInt 0))) (EBinOp "&&" (EBinOp "==" (EBinOp "%" (EVar "a") (EVar "g")) (ELit (LInt 0))) (EBinOp "==" (EBinOp "%" (EVar "b") (EVar "g")) (ELit (LInt 0))))))))
(DProp false "lcmInt is commutative" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "lcmInt") (EVar "a")) (EVar "b"))) (EApp (EApp (EVar "lcmInt") (EVar "b")) (EVar "a"))))
(DProp false "powInt b 2 equals b * b" ((pp "b" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 2)))) (EBinOp "*" (EVar "b") (EVar "b"))))
(DProp false "powInt b 1 equals b" ((pp "b" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 1)))) (EVar "b")))
(DProp false "powInt b 0 equals 1" ((pp "b" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 0)))) (ELit (LInt 1))))
# MARK
(DTypeSig true "toRadians" (TyFun (TyCon "Float") (TyCon "Float")))
(DFunDef false "toRadians" ((PVar "deg")) (EBinOp "/" (EBinOp "*" (EVar "deg") (EVar "pi")) (ELit (LFloat 180.0))))
(DTypeSig true "toDegrees" (TyFun (TyCon "Float") (TyCon "Float")))
(DFunDef false "toDegrees" ((PVar "rad")) (EBinOp "/" (EBinOp "*" (EVar "rad") (ELit (LFloat 180.0))) (EVar "pi")))
(DTypeSig true "isNaN" (TyFun (TyCon "Float") (TyCon "Bool")))
(DFunDef false "isNaN" ((PVar "x")) (EBinOp "!=" (EVar "x") (EVar "x")))
(DTypeSig true "isInfinite" (TyFun (TyCon "Float") (TyCon "Bool")))
(DFunDef false "isInfinite" ((PVar "x")) (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isNaN") (EVar "x"))) (EApp (EVar "isNaN") (EBinOp "-" (EVar "x") (EVar "x")))))
(DTypeSig true "logBase" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float"))))
(DFunDef false "logBase" ((PVar "base") (PVar "x")) (EBinOp "/" (EApp (EVar "log") (EVar "x")) (EApp (EVar "log") (EVar "base"))))
(DTypeSig true "gcdInt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "gcdInt" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "gcdGo") (EApp (EVar "absInt") (EVar "a"))) (EApp (EVar "absInt") (EVar "b"))))
(DTypeSig false "gcdGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "gcdGo" ((PVar "a") (PLit (LInt 0))) (EVar "a"))
(DFunDef false "gcdGo" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "gcdGo") (EVar "b")) (EBinOp "%" (EVar "a") (EVar "b"))))
(DTypeSig true "lcmInt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lcmInt" ((PLit (LInt 0)) PWild) (ELit (LInt 0)))
(DFunDef false "lcmInt" (PWild (PLit (LInt 0))) (ELit (LInt 0)))
(DFunDef false "lcmInt" ((PVar "a") (PVar "b")) (EApp (EVar "absInt") (EBinOp "*" (EBinOp "/" (EVar "a") (EApp (EApp (EVar "gcdInt") (EVar "a")) (EVar "b"))) (EVar "b"))))
(DTypeSig true "powInt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "powInt" (PWild (PLit (LInt 0))) (ELit (LInt 1)))
(DFunDef false "powInt" ((PVar "b") (PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (ELit (LInt 1)) (EApp (EApp (EApp (EVar "powGo") (EVar "b")) (EVar "n")) (ELit (LInt 1)))))
(DTypeSig false "powGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "powGo" (PWild (PLit (LInt 0)) (PVar "acc")) (EVar "acc"))
(DFunDef false "powGo" ((PVar "b") (PVar "n") (PVar "acc")) (EBlock (DoLet false false (PVar "acc2") (EIf (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 1))) (EBinOp "*" (EVar "acc") (EVar "b")) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EVar "powGo") (EBinOp "*" (EVar "b") (EVar "b"))) (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (EVar "acc2")))))
(DTypeSig false "absInt" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "absInt" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")))
(DProp false "gcdInt is commutative" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "gcdInt") (EVar "a")) (EVar "b"))) (EApp (EApp (EVar "gcdInt") (EVar "b")) (EVar "a"))))
(DProp false "gcdInt divides both arguments (when nonzero)" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EBlock (DoLet false false (PVar "g") (EApp (EApp (EVar "gcdInt") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "||" (EApp (EApp (EMethodRef "eq") (EVar "g")) (ELit (LInt 0))) (EBinOp "&&" (EBinOp "==" (EBinOp "%" (EVar "a") (EVar "g")) (ELit (LInt 0))) (EBinOp "==" (EBinOp "%" (EVar "b") (EVar "g")) (ELit (LInt 0))))))))
(DProp false "lcmInt is commutative" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "lcmInt") (EVar "a")) (EVar "b"))) (EApp (EApp (EVar "lcmInt") (EVar "b")) (EVar "a"))))
(DProp false "powInt b 2 equals b * b" ((pp "b" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 2)))) (EBinOp "*" (EVar "b") (EVar "b"))))
(DProp false "powInt b 1 equals b" ((pp "b" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 1)))) (EVar "b")))
(DProp false "powInt b 0 equals 1" ((pp "b" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "powInt") (EVar "b")) (ELit (LInt 0)))) (ELit (LInt 1))))
