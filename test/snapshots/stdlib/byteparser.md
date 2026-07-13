# META
source_lines=391
stages=DESUGAR,MARK
# SOURCE
-- | byteparser — a binary parser-combinator library for Medaka.
--
-- A structural transcription of `parsec/lib/parser.mdk` with `Array Char`
-- replaced by `Array Int` (bytes), `Char` replaced by `Int`, and
-- char-specific helpers replaced by byte/binary-specific primitives.
--
-- A `ByteParser a` wraps a function from (byte array + position) to a
-- `BResult a`, which is either success (value + new position) or failure
-- (message + position).  Position threading is EXPLICIT — there is no hidden
-- state monad; every primitive returns the position it consumed up to.
--
-- The type is given `Mappable` / `Applicative` / `Thenable` instances so that
-- `do`-notation sequences parsers, and an `Alternative` instance whose
-- `orElse` is LEFT-BIASED with FULL BACKTRACKING: `orElse p q` tries `p` at
-- the current position; if `p` fails it runs `q` at the SAME position (the
-- input is immutable and we never mutate the position on failure, so
-- backtracking is automatic).
--
-- Binary-specific primitives:
--   `beUint n`  — big-endian unsigned n-byte integer
--   `beSint n`  — big-endian signed n-byte integer (two's-complement)
--   `beFloat64` — 64-bit IEEE 754 big-endian float
--   `leUint n`  — little-endian unsigned n-byte integer
--   `leSint n`  — little-endian signed n-byte integer (two's-complement)
--   `leFloat64` — 64-bit IEEE 754 little-endian float

import list.{reverse}

-- ---------------------------------------------------------------------------
-- Result and parser types
-- ---------------------------------------------------------------------------

-- | Parse result: success carries the value and the position just past what
--   was consumed; failure carries an error message and the failure position.
--   `public export` so downstream modules (e.g. a SQLite record decoder) can
--   pattern-match `BOk`/`BErr` directly when they need byte-precise position
--   control beyond what the monadic combinators give.
public export data BResult a = BOk a Int | BErr String Int

-- | A byte-level parser is a function from (byte array, position) to BResult.
public export data ByteParser a = ByteParser (Array Int -> Int -> BResult a)

-- | Run the wrapped function directly.
export runBP : ByteParser a -> Array Int -> Int -> BResult a
runBP (ByteParser f) input pos = f input pos

-- ---------------------------------------------------------------------------
-- BResult helpers
-- ---------------------------------------------------------------------------

-- | Mappable instance for BResult: map over the success value; pass errors
--   through unchanged.  Higher-kinded impl uses the BARE head `BResult`.
export impl Mappable BResult where
  map f (BOk a p) = BOk (f a) p
  map _ (BErr m p) = BErr m p

-- | Position-threading bind for BResult.  On success, passes the value and
--   the new position to the continuation; on failure, short-circuits.
--
--   Lets callers chain position-threading steps without repeating the
--   `BErr m ep => BErr m ep` pass-through boilerplate.
export onOk : BResult a -> (a -> Int -> BResult b) -> BResult b
onOk (BErr m ep) _ = BErr m ep
onOk (BOk a pos) k = k a pos

-- ---------------------------------------------------------------------------
-- Typeclass instances
-- ---------------------------------------------------------------------------
--
-- Higher-kinded impls use the BARE constructor head: `ByteParser`, not
-- `ByteParser a`.

export impl Mappable ByteParser where
  map g p =
    ByteParser (input pos => onOk (runBP p input pos) (a p2 => BOk (g a) p2))

export impl Applicative ByteParser where
  pure a = ByteParser (_ pos => BOk a pos)
  ap pf pa = ByteParser (input pos =>
    onOk
      (runBP pf input pos)
      (f p2 => onOk (runBP pa input p2) (a p3 => BOk (f a) p3)))

export impl Thenable ByteParser where
  andThen p k = ByteParser (input pos =>
    onOk (runBP p input pos) (a p2 => runBP (k a) input p2))

-- | Left-biased, full-backtracking alternative.
--   `noMatch` always fails; `orElse p q` tries `p`, and on failure re-runs
--   `q` from the ORIGINAL position.
export impl Alternative ByteParser where
  noMatch = ByteParser (_ pos => BErr "noMatch" pos)
  orElse p q = ByteParser (input pos =>
    match runBP p input pos
      BOk a pos2 => BOk a pos2
      BErr _ _ => runBP q input pos)

-- ---------------------------------------------------------------------------
-- Primitives
-- ---------------------------------------------------------------------------

-- | Fail unconditionally with a message.
export failWith : String -> ByteParser a
failWith msg = ByteParser (_ pos => BErr msg pos)

-- | Consume one byte if it satisfies the predicate.
--
-- > runByteParser (satisfy (b => b == 65)) (arrayFromList [65, 66, 67])
-- Ok 65
-- > runByteParser (satisfy (b => b == 65)) (arrayFromList [99])
-- Err "unexpected byte at byte 0"
export satisfy : (Int -> Bool) -> ByteParser Int
satisfy pred = ByteParser (satisfyStep pred)

satisfyStep : (Int -> Bool) -> Array Int -> Int -> BResult Int
satisfyStep pred input pos
  | pos >= arrayLength input = BErr "unexpected end of input" pos
  | pred input.[pos] = BOk input.[pos] (pos + 1)
  | otherwise = BErr "unexpected byte" pos

-- | Consume any single byte.
--
-- > runByteParser anyByte (arrayFromList [42])
-- Ok 42
export anyByte : ByteParser Int
anyByte = satisfy (_ => True)

-- | Consume exactly the given byte value.
--
-- > runByteParser (byte 0xFF) (arrayFromList [255, 0])
-- Ok 255
-- > runByteParser (byte 0x00) (arrayFromList [1])
-- Err "unexpected byte at byte 0"
export byte : Int -> ByteParser Int
byte b = satisfy (== b)

-- | Match the end of input.  Yields Unit; consumes nothing.
--
-- > runByteParser eof (arrayFromList [])
-- Ok ()
-- > runByteParser eof (arrayFromList [1])
-- Err "expected end of input at byte 0"
export eof : ByteParser Unit
eof = ByteParser eofStep

eofStep : Array Int -> Int -> BResult Unit
eofStep input pos
  | pos >= arrayLength input = BOk () pos
  | otherwise = BErr "expected end of input" pos

-- | Peek at the current byte without consuming it.
export peek : ByteParser Int
peek = ByteParser (input pos =>
  if pos >= arrayLength input then
    BErr "unexpected end of input" pos
  else
    BOk input.[pos] pos)

-- ---------------------------------------------------------------------------
-- Combinators
-- ---------------------------------------------------------------------------

-- | Zero-or-more.  Uses explicit position threading (a loop), since `many`
--   of a parser that consumes nothing must terminate.
--
-- > runByteParser (many (byte 1)) (arrayFromList [1, 1, 1, 2])
-- Ok [1, 1, 1]
export many : ByteParser a -> ByteParser (List a)
many p = ByteParser (input pos => manyGo p input pos [])

manyGo : ByteParser a -> Array Int -> Int -> List a -> BResult (List a)
manyGo p input pos acc = match runBP p input pos
  BErr _ _ => BOk (reverse acc) pos
  BOk a pos2 =>
    if pos2 == pos then
      BOk (reverse acc) pos2  -- no progress: stop to avoid infinite loop
    else
      manyGo p input pos2 (a::acc)

-- | One-or-more.
--
-- > runByteParser (some (byte 2)) (arrayFromList [2, 2, 3])
-- Ok [2, 2]
-- > runByteParser (some (byte 2)) (arrayFromList [3])
-- Err "unexpected byte at byte 0"
export some : ByteParser a -> ByteParser (List a)
some p = do
  x <- p
  xs <- many p
  pure (x::xs)

-- | Alias for `some`.
export many1 : ByteParser a -> ByteParser (List a)
many1 p = some p

-- | One-or-more `p` separated by `sep`.
export sepBy1 : ByteParser a -> ByteParser b -> ByteParser (List a)
sepBy1 p sep = do
  x <- p
  xs <- many (do
    _ <- sep
    p)
  pure (x::xs)

-- | Zero-or-more `p` separated by `sep`.
export sepBy : ByteParser a -> ByteParser b -> ByteParser (List a)
sepBy p sep = orElse (sepBy1 p sep) (pure [])

-- | Try `p`; produce `Some` on success, `None` (consuming nothing) on failure.
--
-- > runByteParser (optional (byte 5)) (arrayFromList [5])
-- Ok Some 5
-- > runByteParser (optional (byte 5)) (arrayFromList [9])
-- Ok None
export optional : ByteParser a -> ByteParser (Option a)
optional p = orElse (map Some p) (pure None)

-- | `between open close p` parses `open`, then `p`, then `close`, yielding `p`.
export between : ByteParser open -> ByteParser close -> ByteParser a -> ByteParser a
between open close p = do
  _ <- open
  x <- p
  _ <- close
  pure x

-- | First successful parser in the list; fails if all fail.
export choice : List (ByteParser a) -> ByteParser a
choice [] = failWith "choice: no alternatives"
choice (q::rest) = orElse q (choice rest)

-- | Left-associative chaining of `p` separated by operator parser `op`
--   whose value is a binary function.
-- Structurally identical to compiler/frontend/parser.mdk's chainl1, but over
-- a different parser type (ByteParser vs token Parser) — not soundly
-- shareable without a generic Monad/Alternative abstraction.
export chainl1 : ByteParser a -> ByteParser (a -> a -> a) -> ByteParser a
-- lint-disable-next-line rule-duplicate-body
chainl1 p op = do
  x <- p
  chainl1Rest p op x

chainl1Rest : ByteParser a -> ByteParser (a -> a -> a) -> a -> ByteParser a
chainl1Rest p op acc = orElse
  (do
    f <- op
    y <- p
    chainl1Rest p op (f acc y))
  (pure acc)

-- | Read exactly N bytes, returning them as a List Int.
--
-- > runByteParser (takeBytes 3) (arrayFromList [10, 20, 30, 40])
-- Ok [10, 20, 30]
export takeBytes : Int -> ByteParser (List Int)
takeBytes n = ByteParser (takeBytesGo n [])

takeBytesGo : Int -> List Int -> Array Int -> Int -> BResult (List Int)
takeBytesGo n acc input pos
  | n <= 0 = BOk (reverse acc) pos
  | pos >= arrayLength input = BErr "unexpected end of input" pos
  | otherwise = takeBytesGo (n - 1) (input.[pos]::acc) input (pos + 1)

-- | Read exactly N bytes, returning them as an Array Int slice.
export takeSlice : Int -> ByteParser (Array Int)
takeSlice n = map arrayFromList (takeBytes n)

-- ---------------------------------------------------------------------------
-- Binary-specific primitives
-- ---------------------------------------------------------------------------

-- | Read a big-endian unsigned integer of exactly N bytes (N in 1..8).
--
-- Examples (big-endian 2-byte: [0x01, 0x02] → 258):
-- > runByteParser (beUint 2) (arrayFromList [1, 2])
-- Ok 258
-- > runByteParser (beUint 1) (arrayFromList [255])
-- Ok 255
-- > runByteParser (beUint 4) (arrayFromList [0, 0, 1, 0])
-- Ok 256
export beUint : Int -> ByteParser Int
beUint n = ByteParser (beUintGo n 0)

beUintGo : Int -> Int -> Array Int -> Int -> BResult Int
beUintGo n acc input pos
  | n <= 0 = BOk acc pos
  | pos >= arrayLength input = BErr "unexpected end of input" pos
  | otherwise = beUintGo (n - 1) (acc * 256 + input.[pos]) input (pos + 1)

-- | Read a big-endian SIGNED integer of exactly N bytes (N in 1..8),
--   two's-complement.
--
-- The sign bit is the MSB of the first byte.  For an N-byte integer the sign
-- threshold is 128 * 256^(N-1) = 2^(8*N-1).
--
-- > runByteParser (beSint 1) (arrayFromList [255])
-- Ok -1
-- > runByteParser (beSint 1) (arrayFromList [127])
-- Ok 127
-- > runByteParser (beSint 2) (arrayFromList [255, 255])
-- Ok -1
-- > runByteParser (beSint 2) (arrayFromList [0, 1])
-- Ok 1
export beSint : Int -> ByteParser Int
beSint n = do
  u <- beUint n
  let threshold = pow2 (8 * n - 1)
  pure (if u >= threshold then u - threshold * 2 else u)

-- | 2^n implemented with left-shift (works for n in 0..62 on 63-bit Int).
pow2 : Int -> Int
pow2 n = shiftLeft 1 n

-- | Read a 64-bit IEEE 754 big-endian float as a Medaka Float.
-- Consumes exactly 8 bytes in big-endian order and reinterprets their bit
-- pattern as an IEEE 754 double via `bytesToFloat64`.
--
-- > runByteParser beFloat64 (arrayFromList [63, 248, 0, 0, 0, 0, 0, 0])
-- Ok 1.5
-- > runByteParser beFloat64 (arrayFromList [192, 0, 0, 0, 0, 0, 0, 0])
-- Ok -2.0
export beFloat64 : ByteParser Float
beFloat64 = do
  arr <- takeSlice 8
  pure (bytesToFloat64 arr 0)

-- | Read a little-endian unsigned integer of exactly N bytes (N in 1..8).
--   Least-significant byte first (mirror of `beUint`).
--
-- Examples (little-endian 2-byte: [0x02, 0x01] → 258):
-- > runByteParser (leUint 2) (arrayFromList [2, 1])
-- Ok 258
-- > runByteParser (leUint 1) (arrayFromList [255])
-- Ok 255
-- > runByteParser (leUint 4) (arrayFromList [0, 1, 0, 0])
-- Ok 256
export leUint : Int -> ByteParser Int
leUint n = ByteParser (leUintGo n 0 0)

leUintGo : Int -> Int -> Int -> Array Int -> Int -> BResult Int
leUintGo n shift acc input pos
  | n <= 0 = BOk acc pos
  | pos >= arrayLength input = BErr "unexpected end of input" pos
  | otherwise = leUintGo (n - 1) (shift + 8) (acc + input.[pos] * pow2 shift) input (pos + 1)

-- | Read a little-endian SIGNED integer of exactly N bytes (N in 1..8),
--   two's-complement.  Mirror of `beSint`: least-significant byte first,
--   with the sign bit in the MSB of the LAST byte.
--
-- > runByteParser (leSint 1) (arrayFromList [255])
-- Ok -1
-- > runByteParser (leSint 1) (arrayFromList [127])
-- Ok 127
-- > runByteParser (leSint 2) (arrayFromList [255, 255])
-- Ok -1
-- > runByteParser (leSint 2) (arrayFromList [1, 0])
-- Ok 1
export leSint : Int -> ByteParser Int
leSint n = do
  u <- leUint n
  let threshold = pow2 (8 * n - 1)
  pure (if u >= threshold then u - threshold * 2 else u)

-- | Read a 64-bit IEEE 754 little-endian float as a Medaka Float.
--   Consumes exactly 8 bytes in little-endian order; reverses them before
--   reinterpreting the bit pattern via `bytesToFloat64` (which expects
--   big-endian byte order).
--
-- > runByteParser leFloat64 (arrayFromList [0, 0, 0, 0, 0, 0, 248, 63])
-- Ok 1.5
-- > runByteParser leFloat64 (arrayFromList [0, 0, 0, 0, 0, 0, 0, 192])
-- Ok -2.0
export leFloat64 : ByteParser Float
leFloat64 = do
  bytes <- takeBytes 8
  pure (bytesToFloat64 (arrayFromList (reverse bytes)) 0)

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

-- | Run a `ByteParser` over the full byte array starting at position 0.
--   Reports the success value or a positioned error message.
--
-- > runByteParser (byte 42) (arrayFromList [42])
-- Ok 42
-- > runByteParser (byte 42) (arrayFromList [7])
-- Err "unexpected byte at byte 0"
export runByteParser : ByteParser a -> Array Int -> Result String a
runByteParser p bytes = match runBP p bytes 0
  BOk a _ => Ok a
  BErr m pos => Err "\{m} at byte \{pos}"
# DESUGAR
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DData Public "BResult" ("a") ((variant "BOk" (ConPos (TyVar "a") (TyCon "Int"))) (variant "BErr" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DData Public "ByteParser" ("a") ((variant "ByteParser" (ConPos (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyVar "a"))))))) ())
(DTypeSig true "runBP" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyVar "a"))))))
(DFunDef false "runBP" ((PCon "ByteParser" (PVar "f")) (PVar "input") (PVar "pos")) (EApp (EApp (EVar "f") (EVar "input")) (EVar "pos")))
(DImpl true "Mappable" ((TyCon "BResult")) () ((im "map" ((PVar "f") (PCon "BOk" (PVar "a") (PVar "p"))) (EApp (EApp (EVar "BOk") (EApp (EVar "f") (EVar "a"))) (EVar "p"))) (im "map" (PWild (PCon "BErr" (PVar "m") (PVar "p"))) (EApp (EApp (EVar "BErr") (EVar "m")) (EVar "p")))))
(DTypeSig true "onOk" (TyFun (TyApp (TyCon "BResult") (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyVar "b")))) (TyApp (TyCon "BResult") (TyVar "b")))))
(DFunDef false "onOk" ((PCon "BErr" (PVar "m") (PVar "ep")) PWild) (EApp (EApp (EVar "BErr") (EVar "m")) (EVar "ep")))
(DFunDef false "onOk" ((PCon "BOk" (PVar "a") (PVar "pos")) (PVar "k")) (EApp (EApp (EVar "k") (EVar "a")) (EVar "pos")))
(DImpl true "Mappable" ((TyCon "ByteParser")) () ((im "map" ((PVar "g") (PVar "p")) (EApp (EVar "ByteParser") (ELam ((PVar "input") (PVar "pos")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos"))) (ELam ((PVar "a") (PVar "p2")) (EApp (EApp (EVar "BOk") (EApp (EVar "g") (EVar "a"))) (EVar "p2")))))))))
(DImpl true "Applicative" ((TyCon "ByteParser")) () ((im "pure" ((PVar "a")) (EApp (EVar "ByteParser") (ELam (PWild (PVar "pos")) (EApp (EApp (EVar "BOk") (EVar "a")) (EVar "pos"))))) (im "ap" ((PVar "pf") (PVar "pa")) (EApp (EVar "ByteParser") (ELam ((PVar "input") (PVar "pos")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EVar "runBP") (EVar "pf")) (EVar "input")) (EVar "pos"))) (ELam ((PVar "f") (PVar "p2")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EVar "runBP") (EVar "pa")) (EVar "input")) (EVar "p2"))) (ELam ((PVar "a") (PVar "p3")) (EApp (EApp (EVar "BOk") (EApp (EVar "f") (EVar "a"))) (EVar "p3")))))))))))
(DImpl true "Thenable" ((TyCon "ByteParser")) () ((im "andThen" ((PVar "p") (PVar "k")) (EApp (EVar "ByteParser") (ELam ((PVar "input") (PVar "pos")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos"))) (ELam ((PVar "a") (PVar "p2")) (EApp (EApp (EApp (EVar "runBP") (EApp (EVar "k") (EVar "a"))) (EVar "input")) (EVar "p2")))))))))
(DImpl true "Alternative" ((TyCon "ByteParser")) () ((im "noMatch" () (EApp (EVar "ByteParser") (ELam (PWild (PVar "pos")) (EApp (EApp (EVar "BErr") (ELit (LString "noMatch"))) (EVar "pos"))))) (im "orElse" ((PVar "p") (PVar "q")) (EApp (EVar "ByteParser") (ELam ((PVar "input") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos")) (arm (PCon "BOk" (PVar "a") (PVar "pos2")) () (EApp (EApp (EVar "BOk") (EVar "a")) (EVar "pos2"))) (arm (PCon "BErr" PWild PWild) () (EApp (EApp (EApp (EVar "runBP") (EVar "q")) (EVar "input")) (EVar "pos")))))))))
(DTypeSig true "failWith" (TyFun (TyCon "String") (TyApp (TyCon "ByteParser") (TyVar "a"))))
(DFunDef false "failWith" ((PVar "msg")) (EApp (EVar "ByteParser") (ELam (PWild (PVar "pos")) (EApp (EApp (EVar "BErr") (EVar "msg")) (EVar "pos")))))
(DTypeSig true "satisfy" (TyFun (TyFun (TyCon "Int") (TyCon "Bool")) (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "satisfy" ((PVar "pred")) (EApp (EVar "ByteParser") (EApp (EVar "satisfyStep") (EVar "pred"))))
(DTypeSig false "satisfyStep" (TyFun (TyFun (TyCon "Int") (TyCon "Bool")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Int"))))))
(DFunDef false "satisfyStep" ((PVar "pred") (PVar "input") (PVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EApp (EVar "pred") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))) (EApp (EApp (EVar "BOk") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EVar "BErr") (ELit (LString "unexpected byte"))) (EVar "pos")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "anyByte" (TyApp (TyCon "ByteParser") (TyCon "Int")))
(DFunDef false "anyByte" () (EApp (EVar "satisfy") (ELam (PWild) (EVar "True"))))
(DTypeSig true "byte" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "byte" ((PVar "b")) (EApp (EVar "satisfy") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "b")))))
(DTypeSig true "eof" (TyApp (TyCon "ByteParser") (TyCon "Unit")))
(DFunDef false "eof" () (EApp (EVar "ByteParser") (EVar "eofStep")))
(DTypeSig false "eofStep" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Unit")))))
(DFunDef false "eofStep" ((PVar "input") (PVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BOk") (ELit LUnit)) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EVar "BErr") (ELit (LString "expected end of input"))) (EVar "pos")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "peek" (TyApp (TyCon "ByteParser") (TyCon "Int")))
(DFunDef false "peek" () (EApp (EVar "ByteParser") (ELam ((PVar "input") (PVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EApp (EApp (EVar "BOk") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))) (EVar "pos"))))))
(DTypeSig true "many" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "many" ((PVar "p")) (EApp (EVar "ByteParser") (ELam ((PVar "input") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "input")) (EVar "pos")) (EListLit)))))
(DTypeSig false "manyGo" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "BResult") (TyApp (TyCon "List") (TyVar "a"))))))))
(DFunDef false "manyGo" ((PVar "p") (PVar "input") (PVar "pos") (PVar "acc")) (EMatch (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos")) (arm (PCon "BErr" PWild PWild) () (EApp (EApp (EVar "BOk") (EApp (EVar "reverse") (EVar "acc"))) (EVar "pos"))) (arm (PCon "BOk" (PVar "a") (PVar "pos2")) () (EIf (EBinOp "==" (EVar "pos2") (EVar "pos")) (EApp (EApp (EVar "BOk") (EApp (EVar "reverse") (EVar "acc"))) (EVar "pos2")) (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "input")) (EVar "pos2")) (EBinOp "::" (EVar "a") (EVar "acc")))))))
(DTypeSig true "some" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "some" ((PVar "p")) (EApp (EApp (EVar "andThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "p"))) (ELam ((PVar "xs")) (EApp (EVar "pure") (EBinOp "::" (EVar "x") (EVar "xs"))))))))
(DTypeSig true "many1" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "many1" ((PVar "p")) (EApp (EVar "some") (EVar "p")))
(DTypeSig true "sepBy1" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "ByteParser") (TyVar "b")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sepBy1" ((PVar "p") (PVar "sep")) (EApp (EApp (EVar "andThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EApp (EApp (EVar "andThen") (EVar "sep")) (ELam (PWild) (EVar "p"))))) (ELam ((PVar "xs")) (EApp (EVar "pure") (EBinOp "::" (EVar "x") (EVar "xs"))))))))
(DTypeSig true "sepBy" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "ByteParser") (TyVar "b")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sepBy" ((PVar "p") (PVar "sep")) (EApp (EApp (EVar "orElse") (EApp (EApp (EVar "sepBy1") (EVar "p")) (EVar "sep"))) (EApp (EVar "pure") (EListLit))))
(DTypeSig true "optional" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "optional" ((PVar "p")) (EApp (EApp (EVar "orElse") (EApp (EApp (EVar "map") (EVar "Some")) (EVar "p"))) (EApp (EVar "pure") (EVar "None"))))
(DTypeSig true "between" (TyFun (TyApp (TyCon "ByteParser") (TyVar "open")) (TyFun (TyApp (TyCon "ByteParser") (TyVar "close")) (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyVar "a"))))))
(DFunDef false "between" ((PVar "open") (PVar "close") (PVar "p")) (EApp (EApp (EVar "andThen") (EVar "open")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EVar "andThen") (EVar "close")) (ELam (PWild) (EApp (EVar "pure") (EVar "x")))))))))
(DTypeSig true "choice" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "ByteParser") (TyVar "a"))) (TyApp (TyCon "ByteParser") (TyVar "a"))))
(DFunDef false "choice" ((PList)) (EApp (EVar "failWith") (ELit (LString "choice: no alternatives"))))
(DFunDef false "choice" ((PCons (PVar "q") (PVar "rest"))) (EApp (EApp (EVar "orElse") (EVar "q")) (EApp (EVar "choice") (EVar "rest"))))
(DTypeSig true "chainl1" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "ByteParser") (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a")))) (TyApp (TyCon "ByteParser") (TyVar "a")))))
(DFunDef false "chainl1" ((PVar "p") (PVar "op")) (EApp (EApp (EVar "andThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EApp (EVar "chainl1Rest") (EVar "p")) (EVar "op")) (EVar "x")))))
(DTypeSig false "chainl1Rest" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "ByteParser") (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a")))) (TyFun (TyVar "a") (TyApp (TyCon "ByteParser") (TyVar "a"))))))
(DFunDef false "chainl1Rest" ((PVar "p") (PVar "op") (PVar "acc")) (EApp (EApp (EVar "orElse") (EApp (EApp (EVar "andThen") (EVar "op")) (ELam ((PVar "f")) (EApp (EApp (EVar "andThen") (EVar "p")) (ELam ((PVar "y")) (EApp (EApp (EApp (EVar "chainl1Rest") (EVar "p")) (EVar "op")) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "y")))))))) (EApp (EVar "pure") (EVar "acc"))))
(DTypeSig true "takeBytes" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "takeBytes" ((PVar "n")) (EApp (EVar "ByteParser") (EApp (EApp (EVar "takeBytesGo") (EVar "n")) (EListLit))))
(DTypeSig false "takeBytesGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "takeBytesGo" ((PVar "n") (PVar "acc") (PVar "input") (PVar "pos")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EApp (EVar "reverse") (EVar "acc"))) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "takeBytesGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (EVar "acc"))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "takeSlice" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "takeSlice" ((PVar "n")) (EApp (EApp (EVar "map") (EVar "arrayFromList")) (EApp (EVar "takeBytes") (EVar "n"))))
(DTypeSig true "beUint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "beUint" ((PVar "n")) (EApp (EVar "ByteParser") (EApp (EApp (EVar "beUintGo") (EVar "n")) (ELit (LInt 0)))))
(DTypeSig false "beUintGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Int")))))))
(DFunDef false "beUintGo" ((PVar "n") (PVar "acc") (PVar "input") (PVar "pos")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EVar "acc")) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "beUintGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 256))) (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "beSint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "beSint" ((PVar "n")) (EApp (EApp (EVar "andThen") (EApp (EVar "beUint") (EVar "n"))) (ELam ((PVar "u")) (ELet false (PVar "threshold") (EApp (EVar "pow2") (EBinOp "-" (EBinOp "*" (ELit (LInt 8)) (EVar "n")) (ELit (LInt 1)))) (EApp (EVar "pure") (EIf (EBinOp ">=" (EVar "u") (EVar "threshold")) (EBinOp "-" (EVar "u") (EBinOp "*" (EVar "threshold") (ELit (LInt 2)))) (EVar "u")))))))
(DTypeSig false "pow2" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "pow2" ((PVar "n")) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "n")))
(DTypeSig true "beFloat64" (TyApp (TyCon "ByteParser") (TyCon "Float")))
(DFunDef false "beFloat64" () (EApp (EApp (EVar "andThen") (EApp (EVar "takeSlice") (ELit (LInt 8)))) (ELam ((PVar "arr")) (EApp (EVar "pure") (EApp (EApp (EVar "bytesToFloat64") (EVar "arr")) (ELit (LInt 0)))))))
(DTypeSig true "leUint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "leUint" ((PVar "n")) (EApp (EVar "ByteParser") (EApp (EApp (EApp (EVar "leUintGo") (EVar "n")) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig false "leUintGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Int"))))))))
(DFunDef false "leUintGo" ((PVar "n") (PVar "shift") (PVar "acc") (PVar "input") (PVar "pos")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EVar "acc")) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "leUintGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EVar "shift") (ELit (LInt 8)))) (EBinOp "+" (EVar "acc") (EBinOp "*" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (EApp (EVar "pow2") (EVar "shift"))))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "leSint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "leSint" ((PVar "n")) (EApp (EApp (EVar "andThen") (EApp (EVar "leUint") (EVar "n"))) (ELam ((PVar "u")) (ELet false (PVar "threshold") (EApp (EVar "pow2") (EBinOp "-" (EBinOp "*" (ELit (LInt 8)) (EVar "n")) (ELit (LInt 1)))) (EApp (EVar "pure") (EIf (EBinOp ">=" (EVar "u") (EVar "threshold")) (EBinOp "-" (EVar "u") (EBinOp "*" (EVar "threshold") (ELit (LInt 2)))) (EVar "u")))))))
(DTypeSig true "leFloat64" (TyApp (TyCon "ByteParser") (TyCon "Float")))
(DFunDef false "leFloat64" () (EApp (EApp (EVar "andThen") (EApp (EVar "takeBytes") (ELit (LInt 8)))) (ELam ((PVar "bytes")) (EApp (EVar "pure") (EApp (EApp (EVar "bytesToFloat64") (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "bytes")))) (ELit (LInt 0)))))))
(DTypeSig true "runByteParser" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))))
(DFunDef false "runByteParser" ((PVar "p") (PVar "bytes")) (EMatch (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "bytes")) (ELit (LInt 0))) (arm (PCon "BOk" (PVar "a") PWild) () (EApp (EVar "Ok") (EVar "a"))) (arm (PCon "BErr" (PVar "m") (PVar "pos")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "m"))) (ELit (LString " at byte "))) (EApp (EVar "display") (EVar "pos"))) (ELit (LString "")))))))
# MARK
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DData Public "BResult" ("a") ((variant "BOk" (ConPos (TyVar "a") (TyCon "Int"))) (variant "BErr" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DData Public "ByteParser" ("a") ((variant "ByteParser" (ConPos (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyVar "a"))))))) ())
(DTypeSig true "runBP" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyVar "a"))))))
(DFunDef false "runBP" ((PCon "ByteParser" (PVar "f")) (PVar "input") (PVar "pos")) (EApp (EApp (EVar "f") (EVar "input")) (EVar "pos")))
(DImpl true "Mappable" ((TyCon "BResult")) () ((im "map" ((PVar "f") (PCon "BOk" (PVar "a") (PVar "p"))) (EApp (EApp (EVar "BOk") (EApp (EVar "f") (EVar "a"))) (EVar "p"))) (im "map" (PWild (PCon "BErr" (PVar "m") (PVar "p"))) (EApp (EApp (EVar "BErr") (EVar "m")) (EVar "p")))))
(DTypeSig true "onOk" (TyFun (TyApp (TyCon "BResult") (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyVar "b")))) (TyApp (TyCon "BResult") (TyVar "b")))))
(DFunDef false "onOk" ((PCon "BErr" (PVar "m") (PVar "ep")) PWild) (EApp (EApp (EVar "BErr") (EVar "m")) (EVar "ep")))
(DFunDef false "onOk" ((PCon "BOk" (PVar "a") (PVar "pos")) (PVar "k")) (EApp (EApp (EVar "k") (EVar "a")) (EVar "pos")))
(DImpl true "Mappable" ((TyCon "ByteParser")) () ((im "map" ((PVar "g") (PVar "p")) (EApp (EVar "ByteParser") (ELam ((PVar "input") (PVar "pos")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos"))) (ELam ((PVar "a") (PVar "p2")) (EApp (EApp (EVar "BOk") (EApp (EVar "g") (EVar "a"))) (EVar "p2")))))))))
(DImpl true "Applicative" ((TyCon "ByteParser")) () ((im "pure" ((PVar "a")) (EApp (EVar "ByteParser") (ELam (PWild (PVar "pos")) (EApp (EApp (EVar "BOk") (EVar "a")) (EVar "pos"))))) (im "ap" ((PVar "pf") (PVar "pa")) (EApp (EVar "ByteParser") (ELam ((PVar "input") (PVar "pos")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EVar "runBP") (EVar "pf")) (EVar "input")) (EVar "pos"))) (ELam ((PVar "f") (PVar "p2")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EVar "runBP") (EVar "pa")) (EVar "input")) (EVar "p2"))) (ELam ((PVar "a") (PVar "p3")) (EApp (EApp (EVar "BOk") (EApp (EVar "f") (EVar "a"))) (EVar "p3")))))))))))
(DImpl true "Thenable" ((TyCon "ByteParser")) () ((im "andThen" ((PVar "p") (PVar "k")) (EApp (EVar "ByteParser") (ELam ((PVar "input") (PVar "pos")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos"))) (ELam ((PVar "a") (PVar "p2")) (EApp (EApp (EApp (EVar "runBP") (EApp (EVar "k") (EVar "a"))) (EVar "input")) (EVar "p2")))))))))
(DImpl true "Alternative" ((TyCon "ByteParser")) () ((im "noMatch" () (EApp (EVar "ByteParser") (ELam (PWild (PVar "pos")) (EApp (EApp (EVar "BErr") (ELit (LString "noMatch"))) (EVar "pos"))))) (im "orElse" ((PVar "p") (PVar "q")) (EApp (EVar "ByteParser") (ELam ((PVar "input") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos")) (arm (PCon "BOk" (PVar "a") (PVar "pos2")) () (EApp (EApp (EVar "BOk") (EVar "a")) (EVar "pos2"))) (arm (PCon "BErr" PWild PWild) () (EApp (EApp (EApp (EVar "runBP") (EVar "q")) (EVar "input")) (EVar "pos")))))))))
(DTypeSig true "failWith" (TyFun (TyCon "String") (TyApp (TyCon "ByteParser") (TyVar "a"))))
(DFunDef false "failWith" ((PVar "msg")) (EApp (EVar "ByteParser") (ELam (PWild (PVar "pos")) (EApp (EApp (EVar "BErr") (EVar "msg")) (EVar "pos")))))
(DTypeSig true "satisfy" (TyFun (TyFun (TyCon "Int") (TyCon "Bool")) (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "satisfy" ((PVar "pred")) (EApp (EVar "ByteParser") (EApp (EVar "satisfyStep") (EVar "pred"))))
(DTypeSig false "satisfyStep" (TyFun (TyFun (TyCon "Int") (TyCon "Bool")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Int"))))))
(DFunDef false "satisfyStep" ((PVar "pred") (PVar "input") (PVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EApp (EVar "pred") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))) (EApp (EApp (EVar "BOk") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EVar "BErr") (ELit (LString "unexpected byte"))) (EVar "pos")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "anyByte" (TyApp (TyCon "ByteParser") (TyCon "Int")))
(DFunDef false "anyByte" () (EApp (EVar "satisfy") (ELam (PWild) (EVar "True"))))
(DTypeSig true "byte" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "byte" ((PVar "b")) (EApp (EVar "satisfy") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "b")))))
(DTypeSig true "eof" (TyApp (TyCon "ByteParser") (TyCon "Unit")))
(DFunDef false "eof" () (EApp (EVar "ByteParser") (EVar "eofStep")))
(DTypeSig false "eofStep" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Unit")))))
(DFunDef false "eofStep" ((PVar "input") (PVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BOk") (ELit LUnit)) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EVar "BErr") (ELit (LString "expected end of input"))) (EVar "pos")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "peek" (TyApp (TyCon "ByteParser") (TyCon "Int")))
(DFunDef false "peek" () (EApp (EVar "ByteParser") (ELam ((PVar "input") (PVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EApp (EApp (EVar "BOk") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))) (EVar "pos"))))))
(DTypeSig true "many" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "many" ((PVar "p")) (EApp (EVar "ByteParser") (ELam ((PVar "input") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "input")) (EVar "pos")) (EListLit)))))
(DTypeSig false "manyGo" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "BResult") (TyApp (TyCon "List") (TyVar "a"))))))))
(DFunDef false "manyGo" ((PVar "p") (PVar "input") (PVar "pos") (PVar "acc")) (EMatch (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos")) (arm (PCon "BErr" PWild PWild) () (EApp (EApp (EVar "BOk") (EApp (EVar "reverse") (EVar "acc"))) (EVar "pos"))) (arm (PCon "BOk" (PVar "a") (PVar "pos2")) () (EIf (EBinOp "==" (EVar "pos2") (EVar "pos")) (EApp (EApp (EVar "BOk") (EApp (EVar "reverse") (EVar "acc"))) (EVar "pos2")) (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "input")) (EVar "pos2")) (EBinOp "::" (EVar "a") (EVar "acc")))))))
(DTypeSig true "some" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "some" ((PVar "p")) (EApp (EApp (EMethodRef "andThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "p"))) (ELam ((PVar "xs")) (EApp (EMethodRef "pure") (EBinOp "::" (EVar "x") (EVar "xs"))))))))
(DTypeSig true "many1" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "many1" ((PVar "p")) (EApp (EVar "some") (EVar "p")))
(DTypeSig true "sepBy1" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "ByteParser") (TyVar "b")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sepBy1" ((PVar "p") (PVar "sep")) (EApp (EApp (EMethodRef "andThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EApp (EApp (EMethodRef "andThen") (EVar "sep")) (ELam (PWild) (EVar "p"))))) (ELam ((PVar "xs")) (EApp (EMethodRef "pure") (EBinOp "::" (EVar "x") (EVar "xs"))))))))
(DTypeSig true "sepBy" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "ByteParser") (TyVar "b")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sepBy" ((PVar "p") (PVar "sep")) (EApp (EApp (EMethodRef "orElse") (EApp (EApp (EVar "sepBy1") (EVar "p")) (EVar "sep"))) (EApp (EMethodRef "pure") (EListLit))))
(DTypeSig true "optional" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "optional" ((PVar "p")) (EApp (EApp (EMethodRef "orElse") (EApp (EApp (EMethodRef "map") (EVar "Some")) (EVar "p"))) (EApp (EMethodRef "pure") (EVar "None"))))
(DTypeSig true "between" (TyFun (TyApp (TyCon "ByteParser") (TyVar "open")) (TyFun (TyApp (TyCon "ByteParser") (TyVar "close")) (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyVar "a"))))))
(DFunDef false "between" ((PVar "open") (PVar "close") (PVar "p")) (EApp (EApp (EMethodRef "andThen") (EVar "open")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EVar "close")) (ELam (PWild) (EApp (EMethodRef "pure") (EVar "x")))))))))
(DTypeSig true "choice" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "ByteParser") (TyVar "a"))) (TyApp (TyCon "ByteParser") (TyVar "a"))))
(DFunDef false "choice" ((PList)) (EApp (EVar "failWith") (ELit (LString "choice: no alternatives"))))
(DFunDef false "choice" ((PCons (PVar "q") (PVar "rest"))) (EApp (EApp (EMethodRef "orElse") (EVar "q")) (EApp (EVar "choice") (EVar "rest"))))
(DTypeSig true "chainl1" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "ByteParser") (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a")))) (TyApp (TyCon "ByteParser") (TyVar "a")))))
(DFunDef false "chainl1" ((PVar "p") (PVar "op")) (EApp (EApp (EMethodRef "andThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EApp (EVar "chainl1Rest") (EVar "p")) (EVar "op")) (EVar "x")))))
(DTypeSig false "chainl1Rest" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "ByteParser") (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a")))) (TyFun (TyVar "a") (TyApp (TyCon "ByteParser") (TyVar "a"))))))
(DFunDef false "chainl1Rest" ((PVar "p") (PVar "op") (PVar "acc")) (EApp (EApp (EMethodRef "orElse") (EApp (EApp (EMethodRef "andThen") (EVar "op")) (ELam ((PVar "f")) (EApp (EApp (EMethodRef "andThen") (EVar "p")) (ELam ((PVar "y")) (EApp (EApp (EApp (EVar "chainl1Rest") (EVar "p")) (EVar "op")) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "y")))))))) (EApp (EMethodRef "pure") (EVar "acc"))))
(DTypeSig true "takeBytes" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "takeBytes" ((PVar "n")) (EApp (EVar "ByteParser") (EApp (EApp (EVar "takeBytesGo") (EVar "n")) (EListLit))))
(DTypeSig false "takeBytesGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "takeBytesGo" ((PVar "n") (PVar "acc") (PVar "input") (PVar "pos")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EApp (EVar "reverse") (EVar "acc"))) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "takeBytesGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (EVar "acc"))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "takeSlice" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "takeSlice" ((PVar "n")) (EApp (EApp (EMethodRef "map") (EVar "arrayFromList")) (EApp (EVar "takeBytes") (EVar "n"))))
(DTypeSig true "beUint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "beUint" ((PVar "n")) (EApp (EVar "ByteParser") (EApp (EApp (EVar "beUintGo") (EVar "n")) (ELit (LInt 0)))))
(DTypeSig false "beUintGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Int")))))))
(DFunDef false "beUintGo" ((PVar "n") (PVar "acc") (PVar "input") (PVar "pos")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EVar "acc")) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "beUintGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 256))) (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "beSint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "beSint" ((PVar "n")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "beUint") (EVar "n"))) (ELam ((PVar "u")) (ELet false (PVar "threshold") (EApp (EVar "pow2") (EBinOp "-" (EBinOp "*" (ELit (LInt 8)) (EVar "n")) (ELit (LInt 1)))) (EApp (EMethodRef "pure") (EIf (EBinOp ">=" (EVar "u") (EVar "threshold")) (EBinOp "-" (EVar "u") (EBinOp "*" (EVar "threshold") (ELit (LInt 2)))) (EVar "u")))))))
(DTypeSig false "pow2" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "pow2" ((PVar "n")) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "n")))
(DTypeSig true "beFloat64" (TyApp (TyCon "ByteParser") (TyCon "Float")))
(DFunDef false "beFloat64" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "takeSlice") (ELit (LInt 8)))) (ELam ((PVar "arr")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "bytesToFloat64") (EVar "arr")) (ELit (LInt 0)))))))
(DTypeSig true "leUint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "leUint" ((PVar "n")) (EApp (EVar "ByteParser") (EApp (EApp (EApp (EVar "leUintGo") (EVar "n")) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig false "leUintGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Int"))))))))
(DFunDef false "leUintGo" ((PVar "n") (PVar "shift") (PVar "acc") (PVar "input") (PVar "pos")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EVar "acc")) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "leUintGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EVar "shift") (ELit (LInt 8)))) (EBinOp "+" (EVar "acc") (EBinOp "*" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (EApp (EVar "pow2") (EVar "shift"))))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "leSint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "leSint" ((PVar "n")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "leUint") (EVar "n"))) (ELam ((PVar "u")) (ELet false (PVar "threshold") (EApp (EVar "pow2") (EBinOp "-" (EBinOp "*" (ELit (LInt 8)) (EVar "n")) (ELit (LInt 1)))) (EApp (EMethodRef "pure") (EIf (EBinOp ">=" (EVar "u") (EVar "threshold")) (EBinOp "-" (EVar "u") (EBinOp "*" (EVar "threshold") (ELit (LInt 2)))) (EVar "u")))))))
(DTypeSig true "leFloat64" (TyApp (TyCon "ByteParser") (TyCon "Float")))
(DFunDef false "leFloat64" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "takeBytes") (ELit (LInt 8)))) (ELam ((PVar "bytes")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "bytesToFloat64") (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "bytes")))) (ELit (LInt 0)))))))
(DTypeSig true "runByteParser" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))))
(DFunDef false "runByteParser" ((PVar "p") (PVar "bytes")) (EMatch (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "bytes")) (ELit (LInt 0))) (arm (PCon "BOk" (PVar "a") PWild) () (EApp (EVar "Ok") (EVar "a"))) (arm (PCon "BErr" (PVar "m") (PVar "pos")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString " at byte "))) (EApp (EMethodRef "display") (EVar "pos"))) (ELit (LString "")))))))
