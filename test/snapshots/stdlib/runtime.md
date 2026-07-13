# META
source_lines=233
stages=DESUGAR,MARK
# SOURCE
-- Built-in extern declarations.
-- Every name here must have a matching OCaml implementation in lib/eval.ml.
-- To add a new primitive: add an extern line here, add its OCaml impl in
-- eval.ml's `primitives` list, and (if non-pure) its effect annotation here
-- ensures eff_env is seeded automatically.
--
-- `pure` and `map` are *not* externs: they're interface methods of
-- Applicative and Mappable declared in stdlib/core.mdk, and dispatched
-- through user-written impl bodies.

-- Raw string output (Phase 111).  `print`/`println` are *not* externs anymore:
-- they're Medaka functions in core.mdk that render via `Display` and call these.
extern putStr : String -> <Stdout> Unit
extern putStrLn : String -> <Stdout> Unit
extern Ref : a -> Ref a
extern setRef : Ref a -> a -> <Mut> Unit
-- Per-type Hashable hashers — SPECIFIED deterministic algorithms, byte-identical
-- in lib/eval.ml (oracle) and runtime/medaka_rt.c (native): hashInt/hashChar/
-- hashFloat = SplitMix64-finalizer mix, hashString = FNV-1a, hashBool = 0/1; all
-- masked to [0, 2^30) (non-negative).  Replaced the old structural __hashRaw,
-- which the type-erased native runtime cannot replicate.  Called by the primitive
-- `Hashable` impls in core.mdk; derived/compound impls compose them via `hash`.
extern hashInt : Int -> Int
extern hashFloat : Float -> Int
extern hashString : String -> Int
extern hashChar : Char -> Int
extern hashBool : Bool -> Int
extern pi : Float
extern e : Float
extern readLine : Unit -> <Stdin> String
extern readFile : String -> <FileRead "_"> Result String String
-- Read a file as RAW BYTES (no UTF-8 decode): Ok (Array Int) of byte values
-- 0..255, or Err msg on failure.  Mirrors readFile but builds an Array of
-- tagged ints instead of a String.  For SQLite/binary read paths.
extern readFileBytes : String -> <FileRead "_"> Result String (Array Int)
-- Bitwise / shift primitives (PURE).  Defined on the 63-bit Int rep; native
-- (C) == OCaml for NON-NEGATIVE operands (the binary-decoding case).
-- shiftRight is LOGICAL (unsigned): OCaml lsr, C >> on the untagged value.
extern bitAnd : Int -> Int -> Int
extern bitOr : Int -> Int -> Int
extern bitXor : Int -> Int -> Int
extern shiftLeft : Int -> Int -> Int
extern shiftRight : Int -> Int -> Int
extern bitNot : Int -> Int
extern writeFile : String -> String -> <FileWrite "_"> Result String Unit
-- Write raw bytes (Array Int, values 0..255) to a file, truncating.  The
-- byte-clean write counterpart of readFileBytes.  Returns Ok () on success
-- or Err msg on failure.
extern writeFileBytes : String -> Array Int -> <FileWrite "_"> Result String Unit
-- Run a subprocess: prog args -> Ok (exitCode, stdout, stderr) | Err osError.
-- Return type: Result String (Int, String, String) (Result e a: e=error, a=ok).
-- stdout and stderr are captured as strings.  On spawn failure (e.g. ENOENT)
-- returns Err with the OS error message; exit-code non-zero is still Ok.
-- Used by a Medaka-hosted medaka build to invoke clang and the emitter.
extern runCommand : String -> List String -> <Exec "_"> Result String (Int, String, String)
extern exit : Int -> <Panic> Unit
extern panic : String -> a
-- Coded-OOB abort, for a container's own `Index`/`IndexMut` impl to raise on
-- out-of-bounds access.  Reuses the existing E-INDEX-OOB abort machinery every
-- backend already has for the built-in index paths (native @mdk_oob, wasm's
-- E-INDEX-OOB trap) -- unlike `panic`, which is always coded E-PANIC.
extern indexError : String -> a

-- io Module 7.  Higher-level ergonomics (eprint/eprintln/readLines) live in
-- stdlib/io.mdk; these are the irreducible host primitives.
extern args : Unit -> <Env> List String  -- program args after the script name
extern getEnv : String -> <Env "_"> Option String  -- environment variable, or None
-- Absolute path of the running executable (realpath-resolved).  Lets a
-- relocated `medaka` binary derive an exe-relative default MEDAKA_ROOT instead
-- of assuming it runs inside the repo (DISTRIBUTION-DESIGN.md D1).
extern executablePath : Unit -> <Env> String
extern fileExists : String -> <FileRead "_"> Bool
extern canonicalizePath : String -> <FileRead "_"> String  -- realpath(3): resolve ./../symlinks to an absolute path; input unchanged on failure
extern appendFile : String -> String -> <FileWrite "_"> Result String Unit
extern listDir : String -> <FileRead "_"> Result String (List String)  -- directory entries (names)
extern makeDir : String -> <FileWrite "_"> Result String Unit  -- create directory (mkdir 0o755)
extern removeFile : String -> <FileWrite "_"> Result String Unit  -- unlink(2): delete a file.  Err (strerror) on failure
extern rename : String -> String -> <FileWrite "_"> Result String Unit  -- rename(2) old new: move/rename a path.  Err (strerror) on failure
extern removeDir : String -> <FileWrite "_"> Result String Unit  -- rmdir(2): remove an EMPTY directory only.  Err (strerror) on failure
-- stat(2): (sizeBytes, isDir, isFile, mtimeSeconds).  Err (strerror) if the path
-- does not exist / cannot be stat'd.  Mirrors runCommand's tuple-return shape.
extern statFile : String -> <FileRead "_"> Result String (Int, Bool, Bool, Float)
-- Networking (native-only; unbound under `medaka run`, rejected by --target wasm).
-- Raw tagged-Int fds at the extern boundary; abstract Socket/Listener/Connection
-- newtypes are a stdlib concern (stdlib/net.mdk).  See NET-DESIGN.md.
extern netResolve : String -> <Net "_"> Result String (List String)  -- getaddrinfo: hostname -> numeric IP strings
extern netTcpConnect : String -> Int -> <Net "_"> Result String Int  -- host, port -> connected fd (does DNS internally)
extern netTcpListen : String -> Int -> <Net "_"> Result String Int  -- bind addr, port (0=ephemeral) -> listening fd
extern netListenPort : Int -> <Net "_"> Result String Int  -- listening fd -> actual bound port (for port 0)
extern netTcpAccept : Int -> <Net "_"> Result String Int  -- listening fd -> accepted connection fd (blocks)
extern netSend : Int -> Array Int -> <Net "_"> Result String Int  -- fd, bytes -> count actually written (may be < len)
extern netRecv : Int -> Int -> <Net "_"> Result String (Array Int)  -- fd, maxBytes -> bytes read (empty Array = EOF)
extern netShutdown : Int -> Int -> <Net "_"> Result String Unit  -- fd, how (0=read,1=write,2=both) -> shutdown(2)
extern netClose : Int -> <Net "_"> Result String Unit  -- fd -> close(2); idempotent-safe in the C shim
extern netSetTimeout : Int -> Int -> <Net "_"> Result String Unit  -- fd, milliseconds (0=blocking) -> SO_RCVTIMEO+SO_SNDTIMEO
extern ePutStr : String -> <Stderr> Unit  -- raw stderr output
extern ePutStrLn : String -> <Stderr> Unit
extern readLineOpt : Unit -> <Stdin> Option String  -- one stdin line, None at EOF
extern readAll : Unit -> <Stdin> String  -- all of stdin
extern readExactly : Int -> <Stdin> Option String  -- read exactly N bytes; None at EOF or short read
extern flushStdout : Unit -> <Stdout> Unit  -- flush buffered stdout (LSP stdio framing)
extern wallTimeSec : Unit -> <Clock> Float  -- wall-clock time in seconds (gettimeofday)
extern monotonicSec : Unit -> <Clock> Float  -- monotonic clock in seconds (clock_gettime CLOCK_MONOTONIC); for measuring intervals
extern sleepMs : Int -> <Clock> Unit  -- sleep for N milliseconds (nanosleep)
extern allocBytes : Unit -> <IO> Float  -- total GC-allocated bytes since process start (Gc.allocated_bytes proxy)
-- Internal: the terminator of a desugared guard chain (Phase 91).  Raises the
-- same "no clause matched" signal as a failed pattern, so when a function
-- clause's guards all fail, dispatch falls through to the next pattern clause
-- (Haskell semantics) instead of aborting.  Not meant for direct use.
extern __fallthrough__ : Unit -> a
extern randomInt : Int -> Int -> <Rand> Int
extern randomBool : Unit -> <Rand> Bool
extern randomFloat : Unit -> <Rand> Float
extern randomChar : Unit -> <Rand> Char
extern setSeed : Int -> <Rand> Unit
extern charToStr : Char -> String
extern intToFloat : Int -> Float
extern floatToInt : Float -> Int
-- floatRem a b = a - b * trunc(a/b)  (C fmod == LLVM frem == OCaml Float.rem).
-- Backs the `Float % Float` operator in the interpreter so `run` matches `build`
-- (which emits `frem` inline) EXACTLY.  Pure.
extern floatRem : Float -> Float -> Float
-- ── libm math externs (native/LLVM only) ────────────────────────────────
-- One-arg and two-arg transcendental / root / rounding functions, each a
-- direct call into the C runtime's math.h shim (mirrors floatRem/fmod).
-- All pure.  NOTE: wasm does NOT port these (they trap on wasm, like every
-- non-ported float extern); native/LLVM is the only backend.
extern sqrt : Float -> Float
extern cbrt : Float -> Float
extern exp : Float -> Float
extern log : Float -> Float
extern log2 : Float -> Float
extern log10 : Float -> Float
extern sin : Float -> Float
extern cos : Float -> Float
extern tan : Float -> Float
extern asin : Float -> Float
extern acos : Float -> Float
extern atan : Float -> Float
extern sinh : Float -> Float
extern cosh : Float -> Float
extern tanh : Float -> Float
extern floor : Float -> Float
extern ceil : Float -> Float
extern round : Float -> Float
extern trunc : Float -> Float
extern pow : Float -> Float -> Float
extern atan2 : Float -> Float -> Float
extern hypot : Float -> Float -> Float
-- Bit-level reinterpretation of a 64-bit Int as an IEEE 754 double.
-- Inverse of Int64.bits_of_float / C memcpy(&bits,&d,8).  Pure.
extern intBitsToFloat : Int -> Float
-- Read 8 bytes big-endian from `arr` starting at byte index `off` and
-- reinterpret as an IEEE 754 double.  Bytes in `arr` are Int values 0..255.
-- Pure (no IO; the array is read-only).
extern bytesToFloat64 : Array Int -> Int -> Float
-- Inverse of `bytesToFloat64`: encode a Float as 8 big-endian IEEE 754 bytes
-- and return them as an Array of 8 Ints (each 0..255).  Pure.
extern floatToBytes64 : Float -> Array Int
-- Platform bounds backing `impl Bounded Int`/`Bounded Char` in core.mdk.
-- Int bounds are the 63-bit OCaml `int` limits; Char bounds are U+0000 / U+10FFFF.
extern intMinBound : Int
extern intMaxBound : Int
extern charMinBound : Char
extern charMaxBound : Char
-- Leaf renderers backing the `Debug` impls in core.mdk / string.mdk.  These
-- expose the same OCaml formatting `pp_value` uses, so `debug` agrees with
-- `println` on numbers.  `debugStringLit`/`debugCharLit` produce the *quoted,
-- escaped* literal form (round-trippable into source), so `debug` on a String
-- intentionally differs from `println` (cf. Haskell `show` vs `putStr`).
extern intToString : Int -> String
extern floatToString : Float -> String
extern debugStringLit : String -> String
extern debugCharLit : Char -> String
extern assertSnapshot : String -> String -> <IO> Unit

-- Array primitives.  These are the minimal kernel; stdlib/array.mdk is
-- built on top.  *Unsafe variants skip the bounds check — they're used by
-- stdlib internals where the surrounding loop already enforces validity.
-- Public, bounds-checked indexing goes through `arr[i]` (panics on OOB).
extern arrayLength : Array a -> Int
extern arrayMake : Int -> a -> Array a
extern arrayMakeWith : Int -> (Int -> a) -> Array a
extern arrayGetUnsafe : Int -> Array a -> a
extern arraySetUnsafe : Int -> a -> Array a -> <Mut> Unit
extern arrayCopy : Array a -> Array a
extern arrayBlit : Array a -> Int -> Array a -> Int -> Int -> <Mut> Unit
extern arrayFill : a -> Array a -> <Mut> Unit
extern arraySortInPlaceBy : (a -> a -> Ordering) -> Array a -> <Mut> Unit
-- Pure wrappers.  Encapsulate "alloc + locally mutate + return fresh" so
-- the <Mut> doesn't leak into pure callers (Medaka has no effect masking).
extern arraySortBy : (a -> a -> Ordering) -> Array a -> Array a
extern arrayFromList : List a -> Array a

-- String/Char kernel (Phase 75).  String is a sequence of Unicode codepoints,
-- UTF-8 backed; Char is one codepoint.  The bridge to Array Char + the few
-- codepoint-aware perf externs below are the minimal host surface; the bulk of
-- stdlib/string.mdk is written in Medaka on top.  Unicode classification/case
-- folding (charIs*/charTo*, needs a Unicode database) lands separately.
extern stringToChars : String -> Array Char
extern stringFromChars : Array Char -> String
-- UTF-8 codec (BOTH directions).  stringToUtf8Bytes exposes the String's raw
-- UTF-8 backing as Int bytes 0..255 (O(n) copy, NO codepoint re-encode);
-- stringFromUtf8Bytes blits Int bytes (low 8 bits each) back into a String.
-- Decode is PERMISSIVE (bytes are blitted verbatim; the cached codepoint count
-- is recomputed by the standard non-continuation-byte rule).  For valid UTF-8
-- (e.g. SQLite text) `fromUtf8 (toUtf8 s) == s` byte-for-byte.
extern stringToUtf8Bytes : String -> Array Int
extern stringFromUtf8Bytes : Array Int -> String
extern charCode : Char -> Int
extern charFromCode : Int -> Option Char
extern stringLength : String -> Int
extern stringSlice : Int -> Int -> String -> String
extern stringConcat : List String -> String
extern stringIndexOf : String -> String -> Option Int
extern stringCompare : String -> String -> Ordering
extern stringToFloat : String -> Option Float

-- Unicode classification & case folding (Phase 75).  Backed by the Unicode
-- character database (uucp) in the host; this is part of the runtime contract
-- every self-hosting host must re-provide, like floatToString.  charToUpper/
-- charToLower are Char -> Char and are the *identity* where a Unicode case
-- mapping would expand to several codepoints (e.g. ß); full-fidelity case
-- folding lives in stringToUpper/stringToLower, which expand 1 -> N.
extern charIsAlpha : Char -> Bool
extern charIsSpace : Char -> Bool
extern charIsUpper : Char -> Bool
extern charIsLower : Char -> Bool
extern charIsPunct : Char -> Bool
extern charToUpper : Char -> Char
extern charToLower : Char -> Char
extern stringToUpper : String -> String
extern stringToLower : String -> String
# DESUGAR
(DExtern false "putStr" (TyFun (TyCon "String") (TyEffect ("Stdout") None (TyCon "Unit"))))
(DExtern false "putStrLn" (TyFun (TyCon "String") (TyEffect ("Stdout") None (TyCon "Unit"))))
(DExtern false "Ref" (TyFun (TyVar "a") (TyApp (TyCon "Ref") (TyVar "a"))))
(DExtern false "setRef" (TyFun (TyApp (TyCon "Ref") (TyVar "a")) (TyFun (TyVar "a") (TyEffect ("Mut") None (TyCon "Unit")))))
(DExtern false "hashInt" (TyFun (TyCon "Int") (TyCon "Int")))
(DExtern false "hashFloat" (TyFun (TyCon "Float") (TyCon "Int")))
(DExtern false "hashString" (TyFun (TyCon "String") (TyCon "Int")))
(DExtern false "hashChar" (TyFun (TyCon "Char") (TyCon "Int")))
(DExtern false "hashBool" (TyFun (TyCon "Bool") (TyCon "Int")))
(DExtern false "pi" (TyCon "Float"))
(DExtern false "e" (TyCon "Float"))
(DExtern false "readLine" (TyFun (TyCon "Unit") (TyEffect ("Stdin") None (TyCon "String"))))
(DExtern false "readFile" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DExtern false "readFileBytes" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int"))))))
(DExtern false "bitAnd" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DExtern false "bitOr" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DExtern false "bitXor" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DExtern false "shiftLeft" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DExtern false "shiftRight" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DExtern false "bitNot" (TyFun (TyCon "Int") (TyCon "Int")))
(DExtern false "writeFile" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DExtern false "writeFileBytes" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DExtern false "runCommand" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "Exec")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Int") (TyCon "String") (TyCon "String")))))))
(DExtern false "exit" (TyFun (TyCon "Int") (TyEffect ("Panic") None (TyCon "Unit"))))
(DExtern false "panic" (TyFun (TyCon "String") (TyVar "a")))
(DExtern false "indexError" (TyFun (TyCon "String") (TyVar "a")))
(DExtern false "args" (TyFun (TyCon "Unit") (TyEffect ("Env") None (TyApp (TyCon "List") (TyCon "String")))))
(DExtern false "getEnv" (TyFun (TyCon "String") (TyEffect ((hole "Env")) None (TyApp (TyCon "Option") (TyCon "String")))))
(DExtern false "executablePath" (TyFun (TyCon "Unit") (TyEffect ("Env") None (TyCon "String"))))
(DExtern false "fileExists" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyCon "Bool"))))
(DExtern false "canonicalizePath" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyCon "String"))))
(DExtern false "appendFile" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DExtern false "listDir" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DExtern false "makeDir" (TyFun (TyCon "String") (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DExtern false "removeFile" (TyFun (TyCon "String") (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DExtern false "rename" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DExtern false "removeDir" (TyFun (TyCon "String") (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DExtern false "statFile" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Int") (TyCon "Bool") (TyCon "Bool") (TyCon "Float"))))))
(DExtern false "netResolve" (TyFun (TyCon "String") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DExtern false "netTcpConnect" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DExtern false "netTcpListen" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DExtern false "netListenPort" (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DExtern false "netTcpAccept" (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DExtern false "netSend" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DExtern false "netRecv" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))))
(DExtern false "netShutdown" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DExtern false "netClose" (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DExtern false "netSetTimeout" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DExtern false "ePutStr" (TyFun (TyCon "String") (TyEffect ("Stderr") None (TyCon "Unit"))))
(DExtern false "ePutStrLn" (TyFun (TyCon "String") (TyEffect ("Stderr") None (TyCon "Unit"))))
(DExtern false "readLineOpt" (TyFun (TyCon "Unit") (TyEffect ("Stdin") None (TyApp (TyCon "Option") (TyCon "String")))))
(DExtern false "readAll" (TyFun (TyCon "Unit") (TyEffect ("Stdin") None (TyCon "String"))))
(DExtern false "readExactly" (TyFun (TyCon "Int") (TyEffect ("Stdin") None (TyApp (TyCon "Option") (TyCon "String")))))
(DExtern false "flushStdout" (TyFun (TyCon "Unit") (TyEffect ("Stdout") None (TyCon "Unit"))))
(DExtern false "wallTimeSec" (TyFun (TyCon "Unit") (TyEffect ("Clock") None (TyCon "Float"))))
(DExtern false "monotonicSec" (TyFun (TyCon "Unit") (TyEffect ("Clock") None (TyCon "Float"))))
(DExtern false "sleepMs" (TyFun (TyCon "Int") (TyEffect ("Clock") None (TyCon "Unit"))))
(DExtern false "allocBytes" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Float"))))
(DExtern false "__fallthrough__" (TyFun (TyCon "Unit") (TyVar "a")))
(DExtern false "randomInt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("Rand") None (TyCon "Int")))))
(DExtern false "randomBool" (TyFun (TyCon "Unit") (TyEffect ("Rand") None (TyCon "Bool"))))
(DExtern false "randomFloat" (TyFun (TyCon "Unit") (TyEffect ("Rand") None (TyCon "Float"))))
(DExtern false "randomChar" (TyFun (TyCon "Unit") (TyEffect ("Rand") None (TyCon "Char"))))
(DExtern false "setSeed" (TyFun (TyCon "Int") (TyEffect ("Rand") None (TyCon "Unit"))))
(DExtern false "charToStr" (TyFun (TyCon "Char") (TyCon "String")))
(DExtern false "intToFloat" (TyFun (TyCon "Int") (TyCon "Float")))
(DExtern false "floatToInt" (TyFun (TyCon "Float") (TyCon "Int")))
(DExtern false "floatRem" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float"))))
(DExtern false "sqrt" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "cbrt" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "exp" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "log" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "log2" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "log10" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "sin" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "cos" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "tan" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "asin" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "acos" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "atan" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "sinh" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "cosh" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "tanh" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "floor" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "ceil" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "round" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "trunc" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "pow" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float"))))
(DExtern false "atan2" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float"))))
(DExtern false "hypot" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float"))))
(DExtern false "intBitsToFloat" (TyFun (TyCon "Int") (TyCon "Float")))
(DExtern false "bytesToFloat64" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Float"))))
(DExtern false "floatToBytes64" (TyFun (TyCon "Float") (TyApp (TyCon "Array") (TyCon "Int"))))
(DExtern false "intMinBound" (TyCon "Int"))
(DExtern false "intMaxBound" (TyCon "Int"))
(DExtern false "charMinBound" (TyCon "Char"))
(DExtern false "charMaxBound" (TyCon "Char"))
(DExtern false "intToString" (TyFun (TyCon "Int") (TyCon "String")))
(DExtern false "floatToString" (TyFun (TyCon "Float") (TyCon "String")))
(DExtern false "debugStringLit" (TyFun (TyCon "String") (TyCon "String")))
(DExtern false "debugCharLit" (TyFun (TyCon "Char") (TyCon "String")))
(DExtern false "assertSnapshot" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DExtern false "arrayLength" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Int")))
(DExtern false "arrayMake" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyApp (TyCon "Array") (TyVar "a")))))
(DExtern false "arrayMakeWith" (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "Int") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a")))))
(DExtern false "arrayGetUnsafe" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyVar "a"))))
(DExtern false "arraySetUnsafe" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect ("Mut") None (TyCon "Unit"))))))
(DExtern false "arrayCopy" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DExtern false "arrayBlit" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("Mut") None (TyCon "Unit"))))))))
(DExtern false "arrayFill" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect ("Mut") None (TyCon "Unit")))))
(DExtern false "arraySortInPlaceBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Ordering"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect ("Mut") None (TyCon "Unit")))))
(DExtern false "arraySortBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Ordering"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a")))))
(DExtern false "arrayFromList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DExtern false "stringToChars" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Char"))))
(DExtern false "stringFromChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "String")))
(DExtern false "stringToUtf8Bytes" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))
(DExtern false "stringFromUtf8Bytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DExtern false "charCode" (TyFun (TyCon "Char") (TyCon "Int")))
(DExtern false "charFromCode" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Char"))))
(DExtern false "stringLength" (TyFun (TyCon "String") (TyCon "Int")))
(DExtern false "stringSlice" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))
(DExtern false "stringConcat" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DExtern false "stringIndexOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DExtern false "stringCompare" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Ordering"))))
(DExtern false "stringToFloat" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Float"))))
(DExtern false "charIsAlpha" (TyFun (TyCon "Char") (TyCon "Bool")))
(DExtern false "charIsSpace" (TyFun (TyCon "Char") (TyCon "Bool")))
(DExtern false "charIsUpper" (TyFun (TyCon "Char") (TyCon "Bool")))
(DExtern false "charIsLower" (TyFun (TyCon "Char") (TyCon "Bool")))
(DExtern false "charIsPunct" (TyFun (TyCon "Char") (TyCon "Bool")))
(DExtern false "charToUpper" (TyFun (TyCon "Char") (TyCon "Char")))
(DExtern false "charToLower" (TyFun (TyCon "Char") (TyCon "Char")))
(DExtern false "stringToUpper" (TyFun (TyCon "String") (TyCon "String")))
(DExtern false "stringToLower" (TyFun (TyCon "String") (TyCon "String")))
# MARK
(DExtern false "putStr" (TyFun (TyCon "String") (TyEffect ("Stdout") None (TyCon "Unit"))))
(DExtern false "putStrLn" (TyFun (TyCon "String") (TyEffect ("Stdout") None (TyCon "Unit"))))
(DExtern false "Ref" (TyFun (TyVar "a") (TyApp (TyCon "Ref") (TyVar "a"))))
(DExtern false "setRef" (TyFun (TyApp (TyCon "Ref") (TyVar "a")) (TyFun (TyVar "a") (TyEffect ("Mut") None (TyCon "Unit")))))
(DExtern false "hashInt" (TyFun (TyCon "Int") (TyCon "Int")))
(DExtern false "hashFloat" (TyFun (TyCon "Float") (TyCon "Int")))
(DExtern false "hashString" (TyFun (TyCon "String") (TyCon "Int")))
(DExtern false "hashChar" (TyFun (TyCon "Char") (TyCon "Int")))
(DExtern false "hashBool" (TyFun (TyCon "Bool") (TyCon "Int")))
(DExtern false "pi" (TyCon "Float"))
(DExtern false "e" (TyCon "Float"))
(DExtern false "readLine" (TyFun (TyCon "Unit") (TyEffect ("Stdin") None (TyCon "String"))))
(DExtern false "readFile" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DExtern false "readFileBytes" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int"))))))
(DExtern false "bitAnd" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DExtern false "bitOr" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DExtern false "bitXor" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DExtern false "shiftLeft" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DExtern false "shiftRight" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DExtern false "bitNot" (TyFun (TyCon "Int") (TyCon "Int")))
(DExtern false "writeFile" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DExtern false "writeFileBytes" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DExtern false "runCommand" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "Exec")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Int") (TyCon "String") (TyCon "String")))))))
(DExtern false "exit" (TyFun (TyCon "Int") (TyEffect ("Panic") None (TyCon "Unit"))))
(DExtern false "panic" (TyFun (TyCon "String") (TyVar "a")))
(DExtern false "indexError" (TyFun (TyCon "String") (TyVar "a")))
(DExtern false "args" (TyFun (TyCon "Unit") (TyEffect ("Env") None (TyApp (TyCon "List") (TyCon "String")))))
(DExtern false "getEnv" (TyFun (TyCon "String") (TyEffect ((hole "Env")) None (TyApp (TyCon "Option") (TyCon "String")))))
(DExtern false "executablePath" (TyFun (TyCon "Unit") (TyEffect ("Env") None (TyCon "String"))))
(DExtern false "fileExists" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyCon "Bool"))))
(DExtern false "canonicalizePath" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyCon "String"))))
(DExtern false "appendFile" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DExtern false "listDir" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DExtern false "makeDir" (TyFun (TyCon "String") (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DExtern false "removeFile" (TyFun (TyCon "String") (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DExtern false "rename" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DExtern false "removeDir" (TyFun (TyCon "String") (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DExtern false "statFile" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "Int") (TyCon "Bool") (TyCon "Bool") (TyCon "Float"))))))
(DExtern false "netResolve" (TyFun (TyCon "String") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DExtern false "netTcpConnect" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DExtern false "netTcpListen" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DExtern false "netListenPort" (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DExtern false "netTcpAccept" (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DExtern false "netSend" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DExtern false "netRecv" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Array") (TyCon "Int")))))))
(DExtern false "netShutdown" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DExtern false "netClose" (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DExtern false "netSetTimeout" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ((hole "Net")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DExtern false "ePutStr" (TyFun (TyCon "String") (TyEffect ("Stderr") None (TyCon "Unit"))))
(DExtern false "ePutStrLn" (TyFun (TyCon "String") (TyEffect ("Stderr") None (TyCon "Unit"))))
(DExtern false "readLineOpt" (TyFun (TyCon "Unit") (TyEffect ("Stdin") None (TyApp (TyCon "Option") (TyCon "String")))))
(DExtern false "readAll" (TyFun (TyCon "Unit") (TyEffect ("Stdin") None (TyCon "String"))))
(DExtern false "readExactly" (TyFun (TyCon "Int") (TyEffect ("Stdin") None (TyApp (TyCon "Option") (TyCon "String")))))
(DExtern false "flushStdout" (TyFun (TyCon "Unit") (TyEffect ("Stdout") None (TyCon "Unit"))))
(DExtern false "wallTimeSec" (TyFun (TyCon "Unit") (TyEffect ("Clock") None (TyCon "Float"))))
(DExtern false "monotonicSec" (TyFun (TyCon "Unit") (TyEffect ("Clock") None (TyCon "Float"))))
(DExtern false "sleepMs" (TyFun (TyCon "Int") (TyEffect ("Clock") None (TyCon "Unit"))))
(DExtern false "allocBytes" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Float"))))
(DExtern false "__fallthrough__" (TyFun (TyCon "Unit") (TyVar "a")))
(DExtern false "randomInt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("Rand") None (TyCon "Int")))))
(DExtern false "randomBool" (TyFun (TyCon "Unit") (TyEffect ("Rand") None (TyCon "Bool"))))
(DExtern false "randomFloat" (TyFun (TyCon "Unit") (TyEffect ("Rand") None (TyCon "Float"))))
(DExtern false "randomChar" (TyFun (TyCon "Unit") (TyEffect ("Rand") None (TyCon "Char"))))
(DExtern false "setSeed" (TyFun (TyCon "Int") (TyEffect ("Rand") None (TyCon "Unit"))))
(DExtern false "charToStr" (TyFun (TyCon "Char") (TyCon "String")))
(DExtern false "intToFloat" (TyFun (TyCon "Int") (TyCon "Float")))
(DExtern false "floatToInt" (TyFun (TyCon "Float") (TyCon "Int")))
(DExtern false "floatRem" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float"))))
(DExtern false "sqrt" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "cbrt" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "exp" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "log" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "log2" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "log10" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "sin" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "cos" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "tan" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "asin" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "acos" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "atan" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "sinh" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "cosh" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "tanh" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "floor" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "ceil" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "round" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "trunc" (TyFun (TyCon "Float") (TyCon "Float")))
(DExtern false "pow" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float"))))
(DExtern false "atan2" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float"))))
(DExtern false "hypot" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Float"))))
(DExtern false "intBitsToFloat" (TyFun (TyCon "Int") (TyCon "Float")))
(DExtern false "bytesToFloat64" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Float"))))
(DExtern false "floatToBytes64" (TyFun (TyCon "Float") (TyApp (TyCon "Array") (TyCon "Int"))))
(DExtern false "intMinBound" (TyCon "Int"))
(DExtern false "intMaxBound" (TyCon "Int"))
(DExtern false "charMinBound" (TyCon "Char"))
(DExtern false "charMaxBound" (TyCon "Char"))
(DExtern false "intToString" (TyFun (TyCon "Int") (TyCon "String")))
(DExtern false "floatToString" (TyFun (TyCon "Float") (TyCon "String")))
(DExtern false "debugStringLit" (TyFun (TyCon "String") (TyCon "String")))
(DExtern false "debugCharLit" (TyFun (TyCon "Char") (TyCon "String")))
(DExtern false "assertSnapshot" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DExtern false "arrayLength" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Int")))
(DExtern false "arrayMake" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyApp (TyCon "Array") (TyVar "a")))))
(DExtern false "arrayMakeWith" (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "Int") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a")))))
(DExtern false "arrayGetUnsafe" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyVar "a"))))
(DExtern false "arraySetUnsafe" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect ("Mut") None (TyCon "Unit"))))))
(DExtern false "arrayCopy" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DExtern false "arrayBlit" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("Mut") None (TyCon "Unit"))))))))
(DExtern false "arrayFill" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect ("Mut") None (TyCon "Unit")))))
(DExtern false "arraySortInPlaceBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Ordering"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect ("Mut") None (TyCon "Unit")))))
(DExtern false "arraySortBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Ordering"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a")))))
(DExtern false "arrayFromList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DExtern false "stringToChars" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Char"))))
(DExtern false "stringFromChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "String")))
(DExtern false "stringToUtf8Bytes" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))
(DExtern false "stringFromUtf8Bytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DExtern false "charCode" (TyFun (TyCon "Char") (TyCon "Int")))
(DExtern false "charFromCode" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Char"))))
(DExtern false "stringLength" (TyFun (TyCon "String") (TyCon "Int")))
(DExtern false "stringSlice" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))
(DExtern false "stringConcat" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DExtern false "stringIndexOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DExtern false "stringCompare" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Ordering"))))
(DExtern false "stringToFloat" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Float"))))
(DExtern false "charIsAlpha" (TyFun (TyCon "Char") (TyCon "Bool")))
(DExtern false "charIsSpace" (TyFun (TyCon "Char") (TyCon "Bool")))
(DExtern false "charIsUpper" (TyFun (TyCon "Char") (TyCon "Bool")))
(DExtern false "charIsLower" (TyFun (TyCon "Char") (TyCon "Bool")))
(DExtern false "charIsPunct" (TyFun (TyCon "Char") (TyCon "Bool")))
(DExtern false "charToUpper" (TyFun (TyCon "Char") (TyCon "Char")))
(DExtern false "charToLower" (TyFun (TyCon "Char") (TyCon "Char")))
(DExtern false "stringToUpper" (TyFun (TyCon "String") (TyCon "String")))
(DExtern false "stringToLower" (TyFun (TyCon "String") (TyCon "String")))
