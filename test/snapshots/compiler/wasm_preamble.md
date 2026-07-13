# META
source_lines=1413
stages=DESUGAR,MARK
# SOURCE
-- WasmGC module PREAMBLE — the fixed lines that head every emitted WAT module
-- (WASMGC-DESIGN.md §3 type-section + §6 host-import seam).  Peer of
-- `backend.llvm_preamble` (the `declare @mdk_…` block): PURE DATA, identical for
-- every program, so it carries no dependency on the emitter's state.  Kept in its
-- own module to avoid a circular import (wasm_emit iterates this list).
--
-- ── W2 SCOPE (WASMGC-DESIGN §9 slice 2 — immediates + arithmetic) ────────────
--   * The value rep for the SCALAR subset is raw `i32` (the §3.2 recommendation:
--     "for monomorphic Int arithmetic keep values as raw i32").  Ints/Bools are
--     `i32`.  The i31ref/`(ref eq)` unitype + boxing (§3.1/§3.2) is exercised by
--     W3 (ADTs) — see `recGroupLines` below + the §3.4 per-type struct emission in
--     wasm_emit's `emitTypeSection`.
--
-- ── W3 SCOPE (WASMGC-DESIGN §9 slice 3 — ADTs + match) ───────────────────────
-- A program that uses NO ADTs (no `data` decl, no `match`) emits exactly the W2
-- scalar shape (raw i32, the 15 W2 fixtures stay byte-identical).  A program that
-- DOES use an ADT switches to the §8.6 uniform `(ref eq)` value rep: every value
-- slot is `(ref eq)`, scalars/Bool/Unit/nullary-ctors are `i31ref` immediates
-- (`ref.i31`), payload constructors are per-ctor `struct`s with an explicit i32
-- discriminant field 0 (§3.4 — defends against WasmGC structural-subtyping
-- collapse) under a per-datatype root struct.  The type section's `rec` group is
-- emitted DYNAMICALLY by wasm_emit (`emitTypeSection`) since it depends on the
-- program's `data` decls; this preamble carries only the FIXED header + imports.
--
-- ── Output ABI (§6 IO / §10 fork e) ──────────────────────────────────────────
-- The emitter auto-prints the scalar `main` result (the LLVM gate's value-main
-- auto-print contract, mirrored), routed by static type:
--   - `env.mdk_write_int(i32)`  — write the int as decimal + newline
--   - `env.mdk_write_bool(i32)` — write "true"/"false" + newline
-- The JS runner (`test/wasm/run.js`) does the int→decimal / bool→text + newline
-- formatting.  This is a TEMPORARY scaffold the W6 string slice replaces.  The
-- bytes it produces are exactly the native-compiled oracle's `pp_value`.
--
-- Order is load-bearing: emitted WAT is assembled by `wasm-tools parse` and the
-- program's stdout is diffed byte-for-byte against the oracle, so these lines stay
-- in EXACTLY this order.  The module is CLOSED by the emitter (it appends the type
-- section, function defs, `(start)`, and the trailing `)`), so this preamble
-- deliberately leaves the `(module` paren OPEN.

export preambleHeadLines : List String
preambleHeadLines = [
  ";; Medaka WasmGC backend (Stage 2.4c) — emitted WAT.",
  ";; Value rep: WASMGC-DESIGN.md §3 / §8.6.  W2 = scalar i32; W3 = (ref eq) + i31/structs.",
  "(module",
]

-- the §6 host-import IO seam (emitted AFTER the type section, since some engines /
-- the binary format want imports grouped, but WAT order here is fine either way —
-- kept after the rec group for readability of the emitted module).
export importLines : List String
importLines = [
  "  ;; ── §6 host-import IO seam (§10 fork e — custom import) ──",
  "  (import \"env\" \"mdk_write_int\" (func $mdk_write_int (param i32)))",
  "  (import \"env\" \"mdk_write_bool\" (func $mdk_write_bool (param i32)))",
]

-- ── W4 closure / TCO preamble (WASMGC-DESIGN §4) ─────────────────────────────
-- The closure ABI types + the universal apply runtime.  Emitted (by wasm_emit's
-- `emitTypeSection`) only when a program uses closures / higher-order application
-- (`progUseClos`).  The closure layout carries ARITY IN THE STRUCT (§11) so every
-- application site reads arity from the value — never a name-keyed side table —
-- which kills the native backend's table-miss miscompile class by construction.
--
--   $argarr  = (array (mut (ref null eq)))  — args / captured-env vector
--   $codety  = (func (param $self (ref eq)) (param $args (ref $argarr))
--                     (result (ref eq)))    — ONE uniform code signature (no
--                     per-arity funcref type; over/under/exact stay uniform)
--   $clos    = (struct $code $arity $env)   — funcref + arity + spill/env array
--
-- A lifted lambda reads its captures from `self`'s $env array and its params from
-- the $args array.  A capture-free top-level fn used as a VALUE gets a wrapper
-- closure (arity = param count, env = []).  Direct saturated top-level calls stay
-- a plain `call` (the fast path) and never touch this machinery.
export closTypeLines : List String
closTypeLines = [
  "    ;; ── §4 closure ABI (arity-in-struct, uniform code sig) ──",
  "    (type $argarr (array (mut (ref null eq))))",
  "    (type $codety (func (param (ref eq)) (param (ref $argarr)) (result (ref eq))))",
  "    (type $clos (sub (struct (field $code (ref $codety)) (field $arity i32) (field $env (ref $argarr)))))",
]

-- the universal apply runtime (emitted once, after the function defs).  `$__mdk_apply`
-- takes a closure value + an args array and dispatches on the closure's arity:
--   exact  (argc == arity) → return_call_ref the code (guaranteed-tail);
--   under  (argc <  arity) → build a PAP closure (env = [orig, partialArgs…],
--                            code = $mdk_pap) with the REMAINING arity;
--   over   (argc >  arity) → saturate the first `arity` args (call_ref), then
--                            return_call $__mdk_apply on the result with the surplus.
-- `$mdk_pap` is the PAP code: env[0] is the original closure, env[1..] the saved
-- partial args; it concatenates saved + incoming and re-applies the original.
export closApplyLines : List String
closApplyLines = [
  "  ;; ── §4 universal apply runtime (exact / under-PAP / over-saturate) ──",
  "  (func $mdk_pap (type $codety) (param $self (ref eq)) (param $args (ref $argarr)) (result (ref eq))",
  "    (local $c (ref $clos)) (local $env (ref $argarr)) (local $orig (ref eq))",
  "    (local $ne i32) (local $na i32) (local $total (ref $argarr)) (local $i i32)",
  "    (local.set $c (ref.cast (ref $clos) (local.get $self)))",
  "    (local.set $env (struct.get $clos $env (local.get $c)))",
  "    (local.set $orig (ref.as_non_null (array.get $argarr (local.get $env) (i32.const 0))))",
  "    (local.set $ne (i32.sub (array.len (local.get $env)) (i32.const 1)))",
  "    (local.set $na (array.len (local.get $args)))",
  "    (local.set $total (array.new $argarr (ref.null eq) (i32.add (local.get $ne) (local.get $na))))",
  "    (local.set $i (i32.const 0))",
  "    (block $pd (loop $pl",
  "      (br_if $pd (i32.ge_s (local.get $i) (local.get $ne)))",
  "      (array.set $argarr (local.get $total) (local.get $i)",
  "        (array.get $argarr (local.get $env) (i32.add (local.get $i) (i32.const 1))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $pl)))",
  "    (local.set $i (i32.const 0))",
  "    (block $pd2 (loop $pl2",
  "      (br_if $pd2 (i32.ge_s (local.get $i) (local.get $na)))",
  "      (array.set $argarr (local.get $total) (i32.add (local.get $ne) (local.get $i))",
  "        (array.get $argarr (local.get $args) (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $pl2)))",
  "    (return_call $__mdk_apply (local.get $orig) (local.get $total)))",
  "  (func $__mdk_apply (param $f (ref eq)) (param $args (ref $argarr)) (result (ref eq))",
  "    (local $c (ref $clos)) (local $ar i32) (local $na i32)",
  "    (local $sat (ref $argarr)) (local $surplus (ref $argarr)) (local $i i32) (local $r (ref eq))",
  "    (local $penv (ref $argarr))",
  "    (local.set $c (ref.cast (ref $clos) (local.get $f)))",
  "    (local.set $ar (struct.get $clos $arity (local.get $c)))",
  "    (local.set $na (array.len (local.get $args)))",
  "    (if (result (ref eq)) (i32.eq (local.get $na) (local.get $ar))",
  "      (then (return_call_ref $codety (local.get $f) (local.get $args) (struct.get $clos $code (local.get $c))))",
  "      (else",
  "        (if (result (ref eq)) (i32.lt_s (local.get $na) (local.get $ar))",
  "          (then",
  "            (local.set $penv (array.new $argarr (ref.null eq) (i32.add (local.get $na) (i32.const 1))))",
  "            (array.set $argarr (local.get $penv) (i32.const 0) (local.get $f))",
  "            (local.set $i (i32.const 0))",
  "            (block $ud (loop $ul",
  "              (br_if $ud (i32.ge_s (local.get $i) (local.get $na)))",
  "              (array.set $argarr (local.get $penv) (i32.add (local.get $i) (i32.const 1))",
  "                (array.get $argarr (local.get $args) (local.get $i)))",
  "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $ul)))",
  "            (struct.new $clos (ref.func $mdk_pap) (i32.sub (local.get $ar) (local.get $na)) (local.get $penv)))",
  "          (else",
  "            (local.set $sat (array.new $argarr (ref.null eq) (local.get $ar)))",
  "            (local.set $i (i32.const 0))",
  "            (block $sd (loop $sl",
  "              (br_if $sd (i32.ge_s (local.get $i) (local.get $ar)))",
  "              (array.set $argarr (local.get $sat) (local.get $i)",
  "                (array.get $argarr (local.get $args) (local.get $i)))",
  "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $sl)))",
  "            (local.set $r (call_ref $codety (local.get $f) (local.get $sat) (struct.get $clos $code (local.get $c))))",
  "            (local.set $surplus (array.new $argarr (ref.null eq) (i32.sub (local.get $na) (local.get $ar))))",
  "            (local.set $i (i32.const 0))",
  "            (block $od (loop $ol",
  "              (br_if $od (i32.ge_s (local.get $i) (i32.sub (local.get $na) (local.get $ar))))",
  "              (array.set $argarr (local.get $surplus) (local.get $i)",
  "                (array.get $argarr (local.get $args) (i32.add (local.get $i) (local.get $ar))))",
  "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $ol)))",
  "            (return_call $__mdk_apply (local.get $r) (local.get $surplus)))))))",
]

-- the SCALAR-only preamble (no ADTs in the program): the W2 shape verbatim — an
-- empty forward-compat rec group + the imports.  Kept byte-identical to the W2
-- output so the 15 scalar fixtures do not move.
export preambleScalarLines : List String
preambleScalarLines = preambleHeadLines
  ++ [
    "  ;; ── §3 type section (one rec group, iso-recursive / nominal-modulo-canon) ──",
    "  ;; This program uses no ADTs — the scalar subset computes in raw i32 and only",
    "  ;; the print boundary is reached; the unitype scaffolding is declared unused.",
    "  (rec",
    "    ;; boxed Int outside the i31 range (§3.2) — declared, unused.",
    "    (type $boxint (sub (struct (field i64))))",
    "    ;; boxed Float (§3.3) — declared, unused until a Float fixture needs it.",
    "    (type $float (sub (struct (field f64))))",
    "  )",
  ]
  ++ importLines

-- ── W6 byte-level IO seam (§6 / §10 fork e) ──────────────────────────────────
-- The scaffold-collapse: instead of importing `mdk_write_int`/`mdk_write_bool` (which
-- made the JS runner do the decimal / true|false / newline FORMATTING), the module
-- now produces the bytes ITSELF (real intToString/string codegen, this slice) and
-- writes them one byte at a time through ONE custom host import — the §6 stdout seam,
-- engine-portable (no GC-array↔JS interop needed).  The JS runner just accumulates
-- raw bytes and UTF-8-decodes them.
export ioByteImportLines : List String
ioByteImportLines = [
  "  ;; ── §6 host-import IO seam (§10 fork e — byte-level custom import) ──",
  "  (import \"env\" \"mdk_write_byte\" (func $mdk_write_byte (param i32)))",
]

-- the §3.3 String aggregate types — emitted into the rec group only when a program
-- uses strings (`useStrRef`).  `$str` caches the codepoint count so `stringLength`
-- is O(1) (RUNTIME-DESIGN §7 decision 2 / §5 INTRINSIC).  `$u8arr` is the UTF-8 byte
-- backing store (mutable so `array.new_data` / `array.new` can fill it).
export strTypeLines : List String
strTypeLines = [
  "    ;; ── §3.3 String aggregate (UTF-8 bytes + cached codepoint count) ──",
  "    (type $u8arr (array (mut i8)))",
  "    (type $str (sub (struct (field $cp_count i32) (field $bytes (ref $u8arr)))))",
]

-- the byte-write print runtime (emitted once, after the function defs, when the
-- program does any IO / value-main auto-print).  Self-contained WAT — no host help
-- beyond `$mdk_write_byte`.
--   $mdk_print_str  — write a $str's UTF-8 bytes verbatim (no newline; putStr).
--   $mdk_print_strln— write a $str's bytes + a trailing '\n' (putStrLn / String main).
--   $mdk_print_int  — render an i64 in decimal (sign + digits) and byte-write it + '\n'
--                     (matches medaka_rt.c mdk_int_to_string's "%lld" + mdk_print_int's
--                     trailing newline).
--   $mdk_print_bool — write "True"/"False" + '\n' (value-main Bool auto-print;
--                     matches native's `println`/`display` Debug rendering — the
--                     composite-main autoprint wrap renders Bool as `True`/`False`,
--                     so the WasmGC direct value-main auto-print must agree).
--   $mdk_int_to_str — render an i64 in decimal into a fresh $str (intToString; the
--                     LEAF extern).  cp_count == byte_len (all ASCII digits/sign).
export ioRuntimeLines : List String
ioRuntimeLines = [
  "  ;; ── §2.1 Int representation seam: i31 fast path / $boxint i64 box ──",
  "  ;; layer-17 SOUNDNESS: Ints in [-2^30, 2^30) are i31ref immediates; outside that",
  "  ;; range they box into (struct (field i64)) ($boxint).  ALL Int arithmetic unboxes",
  "  ;; both operands to i64 via $mdk_unbox_int, computes in i64, and re-boxes via",
  "  ;; $mdk_box_int — so >2^30 values no longer truncate to 31 bits.",
  "  (func $mdk_unbox_int (param $v (ref eq)) (result i64)",
  "    (if (result i64) (ref.test (ref i31) (local.get $v))",
  "      (then (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $v)))))",
  "      (else (struct.get $boxint 0 (ref.cast (ref $boxint) (local.get $v))))))",
  "  ;; box an i64 Int: in [-2^30, 2^30) -> i31 immediate; else -> $boxint struct.",
  "  (func $mdk_box_int (param $n i64) (result (ref eq))",
  "    (if (result (ref eq))",
  "        (i32.and (i64.ge_s (local.get $n) (i64.const -1073741824))",
  "                 (i64.lt_s (local.get $n) (i64.const 1073741824)))",
  "      (then (ref.i31 (i32.wrap_i64 (local.get $n))))",
  "      (else (struct.new $boxint (local.get $n)))))",
  "  ;; ── §6 byte-write print runtime (decimal int / bool text) ──",
  "  ;; write the decimal digits of a NON-NEGATIVE i64 (most-significant first).",
  "  (func $mdk_write_digits (param $n i64)",
  "    (if (i64.ge_s (local.get $n) (i64.const 10))",
  "      (then (call $mdk_write_digits (i64.div_s (local.get $n) (i64.const 10)))))",
  "    (call $mdk_write_byte",
  "      (i32.add (i32.const 48)",
  "        (i32.wrap_i64 (i64.rem_s (local.get $n) (i64.const 10))))))",
  "  ;; render an i64 in decimal to stdout + a trailing newline (value-main Int).",
  "  (func $mdk_print_int (param $n i64)",
  "    (if (i64.lt_s (local.get $n) (i64.const 0))",
  "      (then",
  "        (call $mdk_write_byte (i32.const 45))",
  "        (call $mdk_write_digits (i64.sub (i64.const 0) (local.get $n))))",
  "      (else (call $mdk_write_digits (local.get $n))))",
  "    (call $mdk_write_byte (i32.const 10)))",
  "  (func $mdk_print_bool (param $b i32)",
  "    (if (local.get $b)",
  "      (then",
  "        (call $mdk_write_byte (i32.const 84)) (call $mdk_write_byte (i32.const 114))",
  "        (call $mdk_write_byte (i32.const 117)) (call $mdk_write_byte (i32.const 101)))",
  "      (else",
  "        (call $mdk_write_byte (i32.const 70)) (call $mdk_write_byte (i32.const 97))",
  "        (call $mdk_write_byte (i32.const 108)) (call $mdk_write_byte (i32.const 115))",
  "        (call $mdk_write_byte (i32.const 101))))",
  "    (call $mdk_write_byte (i32.const 10)))",
]

-- the STRING-dependent byte-write runtime (references `$str`/`$u8arr`) — emitted only
-- when the program uses strings (`useStrRef`), so a string-free module never names
-- the absent `$str` type.
--   $mdk_print_str  — write a $str's UTF-8 bytes verbatim (no newline; putStr).
--   $mdk_print_strln— write a $str's bytes + a trailing '\n' (putStrLn / String main).
--   $mdk_int_to_str — render an i64 in decimal into a fresh $str (intToString; the
--                     LEAF extern).  cp_count == byte_len (all ASCII digits/sign).
export ioStrRuntimeLines : List String
ioStrRuntimeLines = [
  "  ;; ── §6 string byte-write runtime ($str-dependent) ──",
  "  (func $mdk_print_str (param $s (ref $str))",
  "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $i (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (call $mdk_write_byte (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))))",
  "  (func $mdk_print_strln (param $s (ref $str))",
  "    (call $mdk_print_str (local.get $s))",
  "    (call $mdk_write_byte (i32.const 10)))",
  "  ;; intToString : render an i64 in decimal into a fresh $str (cp_count == byte len).",
  "  (func $mdk_int_to_str (param $n i64) (result (ref $str))",
  "    (local $neg i32) (local $m i64) (local $len i32) (local $i i32)",
  "    (local $buf (ref $u8arr)) (local $d i32)",
  "    (local.set $neg (i64.lt_s (local.get $n) (i64.const 0)))",
  "    (local.set $m (if (result i64) (local.get $neg)",
  "      (then (i64.sub (i64.const 0) (local.get $n))) (else (local.get $n))))",
  "    ;; count digits",
  "    (local.set $len (i32.const 1))",
  "    (block $cd (loop $cl",
  "      (br_if $cd (i64.lt_s (local.get $m) (i64.const 10)))",
  "      (local.set $len (i32.add (local.get $len) (i32.const 1)))",
  "      (local.set $m (i64.div_s (local.get $m) (i64.const 10)))",
  "      (br $cl)))",
  "    (local.set $m (if (result i64) (local.get $neg)",
  "      (then (i64.sub (i64.const 0) (local.get $n))) (else (local.get $n))))",
  "    (if (local.get $neg) (then (local.set $len (i32.add (local.get $len) (i32.const 1)))))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $len)))",
  "    ;; fill digits from least-significant (end) backward",
  "    (local.set $i (i32.sub (local.get $len) (i32.const 1)))",
  "    (block $fd (loop $fl",
  "      (array.set $u8arr (local.get $buf) (local.get $i)",
  "        (i32.add (i32.const 48) (i32.wrap_i64 (i64.rem_s (local.get $m) (i64.const 10)))))",
  "      (local.set $m (i64.div_s (local.get $m) (i64.const 10)))",
  "      (local.set $i (i32.sub (local.get $i) (i32.const 1)))",
  "      (br_if $fd (i64.eq (local.get $m) (i64.const 0)))",
  "      (br $fl)))",
  "    (if (local.get $neg) (then (array.set $u8arr (local.get $buf) (i32.const 0) (i32.const 45))))",
  "    (struct.new $str (local.get $len) (local.get $buf)))",
]

-- ── W8 stderr byte-write seam (§6 — ePutStr/ePutStrLn) ───────────────────────
-- A second host import for stderr, parallel to `mdk_write_byte`.  Emitted only when
-- the program uses `ePutStr`/`ePutStrLn` (`useEPutRef`).  The native oracle
-- (`mdk_eputstr`) writes a String's UTF-8 bytes to fd 2; the JS runner accumulates
-- these into a separate buffer it prints on `process.stderr` (the diff gate compares
-- STDOUT only, so a stderr-only fixture's stdout matches on both sides).
export stderrByteImportLines : List String
stderrByteImportLines = [
  "  (import \"env\" \"mdk_write_err_byte\" (func $mdk_write_err_byte (param i32)))"
]

-- the stderr byte-write runtime ($str-dependent).  Peer of $mdk_print_str/_strln but
-- routing each byte through $mdk_write_err_byte (matches medaka_rt.c mdk_eputstr /
-- mdk_eputstrln: payload bytes verbatim, optional trailing '\n').
export stderrRuntimeLines : List String
stderrRuntimeLines = [
  "  ;; ── W8 stderr byte-write runtime (ePutStr / ePutStrLn) ──",
  "  (func $mdk_eprint_str (param $s (ref $str))",
  "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $i (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (call $mdk_write_err_byte (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))))",
  "  (func $mdk_eprint_strln (param $s (ref $str))",
  "    (call $mdk_eprint_str (local.get $s))",
  "    (call $mdk_write_err_byte (i32.const 10)))",
]

-- ── W8 pure-WasmGC string LEAF ops (RUNTIME-DESIGN §5 LEAF / WASMGC-DESIGN §6) ──
-- All operate over the §3.3 `$str` ($cp_count i32 + $bytes (ref $u8arr)) rep and are
-- byte-identical to medaka_rt.c.  Emitted only when the program uses strings
-- (`useStrRef`) AND a leaf string op (`useStrLeafRef`).
--   $mdk_str_append   — binary `++`: concat two $str, recompute cp_count (== sum of
--                       both cp_counts, since UTF-8 concat preserves codepoints).
--   $mdk_char_to_str  — encode one codepoint (i32) to a fresh 1..4-byte $str
--                       (mdk_utf8_encode + cp_count 1).
--   $mdk_str_slice    — codepoint-indexed [lo,hi) slice, clamped, UTF-8 byte-walk
--                       (mdk_string_slice).
--   $mdk_str_upper /
--   $mdk_str_lower    — ASCII-only case map over BYTES (mdk_string_to_upper/lower).
--   $mdk_cp_count     — count codepoints in a byte range (UTF-8 non-continuation bytes).
export strLeafRuntimeLines : List String
strLeafRuntimeLines = [
  "  ;; ── W8 string LEAF ops (byte-identical to medaka_rt.c) ──",
  "  ;; count UTF-8 codepoints in a $u8arr over [0,n): every non-continuation byte.",
  "  (func $mdk_cp_count (param $b (ref $u8arr)) (param $n i32) (result i32)",
  "    (local $i i32) (local $c i32) (local $byte i32)",
  "    (local.set $i (i32.const 0)) (local.set $c (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $byte (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      ;; a continuation byte has top bits 10xxxxxx, i.e. (byte & 0xC0) == 0x80.",
  "      (if (i32.ne (i32.and (local.get $byte) (i32.const 192)) (i32.const 128))",
  "        (then (local.set $c (i32.add (local.get $c) (i32.const 1)))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (local.get $c))",
  "  ;; codepoint index `cpi` -> byte offset into a $u8arr of byte length `n`.",
  "  (func $mdk_byte_off (param $b (ref $u8arr)) (param $n i32) (param $cpi i32) (result i32)",
  "    (local $bo i32) (local $c i32)",
  "    (local.set $bo (i32.const 0)) (local.set $c (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $bo) (local.get $n)))",
  "      (br_if $d (i32.ge_s (local.get $c) (local.get $cpi)))",
  "      (local.set $bo (i32.add (local.get $bo) (i32.const 1)))",
  "      (block $sd (loop $sl",
  "        (br_if $sd (i32.ge_s (local.get $bo) (local.get $n)))",
  "        (br_if $sd (i32.ne (i32.and (array.get_u $u8arr (local.get $b) (local.get $bo)) (i32.const 192)) (i32.const 128)))",
  "        (local.set $bo (i32.add (local.get $bo) (i32.const 1))) (br $sl)))",
  "      (local.set $c (i32.add (local.get $c) (i32.const 1))) (br $l)))",
  "    (local.get $bo))",
  "  ;; binary string concat (`++`).  cp_count(a++b) == cp_count(a)+cp_count(b).",
  "  (func $mdk_str_append (param $a (ref $str)) (param $b (ref $str)) (result (ref $str))",
  "    (local $ab (ref $u8arr)) (local $bb (ref $u8arr)) (local $al i32) (local $bl i32)",
  "    (local $buf (ref $u8arr)) (local $cpc i32)",
  "    (local.set $ab (struct.get $str $bytes (local.get $a)))",
  "    (local.set $bb (struct.get $str $bytes (local.get $b)))",
  "    (local.set $al (array.len (local.get $ab)))",
  "    (local.set $bl (array.len (local.get $bb)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (i32.add (local.get $al) (local.get $bl))))",
  "    (array.copy $u8arr $u8arr (local.get $buf) (i32.const 0) (local.get $ab) (i32.const 0) (local.get $al))",
  "    (array.copy $u8arr $u8arr (local.get $buf) (local.get $al) (local.get $bb) (i32.const 0) (local.get $bl))",
  "    (local.set $cpc (i32.add (struct.get $str $cp_count (local.get $a)) (struct.get $str $cp_count (local.get $b))))",
  "    (struct.new $str (local.get $cpc) (local.get $buf)))",
  "  ;; encode one Unicode codepoint to a fresh $str (1..4 UTF-8 bytes, cp_count 1).",
  "  (func $mdk_char_to_str (param $cp i32) (result (ref $str))",
  "    (local $buf (ref $u8arr))",
  "    (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 128))",
  "      (then",
  "        (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 1)))",
  "        (array.set $u8arr (local.get $buf) (i32.const 0) (local.get $cp))",
  "        (struct.new $str (i32.const 1) (local.get $buf)))",
  "      (else (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 2048))",
  "        (then",
  "          (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 2)))",
  "          (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 192) (i32.shr_u (local.get $cp) (i32.const 6))))",
  "          (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))",
  "          (struct.new $str (i32.const 1) (local.get $buf)))",
  "        (else (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 65536))",
  "          (then",
  "            (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 3)))",
  "            (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 224) (i32.shr_u (local.get $cp) (i32.const 12))))",
  "            (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))",
  "            (array.set $u8arr (local.get $buf) (i32.const 2) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))",
  "            (struct.new $str (i32.const 1) (local.get $buf)))",
  "          (else",
  "            (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 4)))",
  "            (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 240) (i32.shr_u (local.get $cp) (i32.const 18))))",
  "            (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 63))))",
  "            (array.set $u8arr (local.get $buf) (i32.const 2) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))",
  "            (array.set $u8arr (local.get $buf) (i32.const 3) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))",
  "            (struct.new $str (i32.const 1) (local.get $buf)))",
  "          )",
  "        )",
  "      )",
  "    )",
  "  ))",
  "  ;; codepoint-indexed [lo,hi) slice, clamped to [0,cp_count].",
  "  (func $mdk_str_slice (param $lo i32) (param $hi i32) (param $s (ref $str)) (result (ref $str))",
  "    (local $b (ref $u8arr)) (local $n i32) (local $cpc i32) (local $blo i32) (local $bhi i32)",
  "    (local $len i32) (local $buf (ref $u8arr))",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $cpc (struct.get $str $cp_count (local.get $s)))",
  "    (if (i32.lt_s (local.get $lo) (i32.const 0)) (then (local.set $lo (i32.const 0)))",
  "      (else (if (i32.gt_s (local.get $lo) (local.get $cpc)) (then (local.set $lo (local.get $cpc))))))",
  "    (if (i32.lt_s (local.get $hi) (local.get $lo)) (then (local.set $hi (local.get $lo)))",
  "      (else (if (i32.gt_s (local.get $hi) (local.get $cpc)) (then (local.set $hi (local.get $cpc))))))",
  "    (local.set $blo (call $mdk_byte_off (local.get $b) (local.get $n) (local.get $lo)))",
  "    (local.set $bhi (call $mdk_byte_off (local.get $b) (local.get $n) (local.get $hi)))",
  "    (local.set $len (i32.sub (local.get $bhi) (local.get $blo)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $len)))",
  "    (array.copy $u8arr $u8arr (local.get $buf) (i32.const 0) (local.get $b) (local.get $blo) (local.get $len))",
  "    (struct.new $str (i32.sub (local.get $hi) (local.get $lo)) (local.get $buf)))",
  "  ;; ASCII upper/lower over BYTES (non-ASCII bytes pass through unchanged).",
  "  (func $mdk_str_upper (param $s (ref $str)) (result (ref $str))",
  "    (local $b (ref $u8arr)) (local $n i32) (local $buf (ref $u8arr)) (local $i i32) (local $c i32)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))",
  "    (local.set $i (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (if (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))",
  "        (then (local.set $c (i32.sub (local.get $c) (i32.const 32)))))",
  "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $c))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (struct.new $str (struct.get $str $cp_count (local.get $s)) (local.get $buf)))",
  "  (func $mdk_str_lower (param $s (ref $str)) (result (ref $str))",
  "    (local $b (ref $u8arr)) (local $n i32) (local $buf (ref $u8arr)) (local $i i32) (local $c i32)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))",
  "    (local.set $i (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (if (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))",
  "        (then (local.set $c (i32.add (local.get $c) (i32.const 32)))))",
  "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $c))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (struct.new $str (struct.get $str $cp_count (local.get $s)) (local.get $buf)))",
  "  ;; ── W9 debug-literal quoting (byte-identical to lib/eval.ml escape_string_lit) ──",
  "  ;; Map ONE source byte to its escaped form, appending into $buf at $bo; returns the",
  "  ;; next write offset.  Specials: \" / ' (whichever == $q) / \\ / \\n / \\t / \\r / NUL.",
  "  ;; All escapes are <backslash><ascii>, so 2 bytes; everything else copies verbatim.",
  "  (func $mdk_dbg_esc_byte (param $buf (ref $u8arr)) (param $bo i32) (param $c i32) (param $q i32) (result i32)",
  "    (local $r i32)",
  "    ;; $r = the char AFTER the backslash for an escaped byte, else -1 (copy verbatim).",
  "    (local.set $r (i32.const -1))",
  "    (if (i32.eq (local.get $c) (local.get $q)) (then (local.set $r (local.get $q))))",
  "    (if (i32.eq (local.get $c) (i32.const 92)) (then (local.set $r (i32.const 92))))",
  "    (if (i32.eq (local.get $c) (i32.const 10)) (then (local.set $r (i32.const 110))))",
  "    (if (i32.eq (local.get $c) (i32.const 9))  (then (local.set $r (i32.const 116))))",
  "    (if (i32.eq (local.get $c) (i32.const 13)) (then (local.set $r (i32.const 114))))",
  "    (if (i32.eq (local.get $c) (i32.const 0))  (then (local.set $r (i32.const 48))))",
  "    (if (result i32) (i32.eq (local.get $r) (i32.const -1))",
  "      (then",
  "        (array.set $u8arr (local.get $buf) (local.get $bo) (local.get $c))",
  "        (i32.add (local.get $bo) (i32.const 1)))",
  "      (else",
  "        (array.set $u8arr (local.get $buf) (local.get $bo) (i32.const 92))",
  "        (array.set $u8arr (local.get $buf) (i32.add (local.get $bo) (i32.const 1)) (local.get $r))",
  "        (i32.add (local.get $bo) (i32.const 2)))))",
  "  ;; Quote+escape a $str with quote byte $q ('\"' for String, ''' for Char).  Two-pass:",
  "  ;; count escaped output bytes, alloc exact, fill; cp_count via $mdk_cp_count.",
  "  (func $mdk_dbg_quote (param $s (ref $str)) (param $q i32) (result (ref $str))",
  "    (local $b (ref $u8arr)) (local $n i32) (local $i i32) (local $c i32)",
  "    (local $out i32) (local $buf (ref $u8arr)) (local $bo i32)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    ;; pass 1: total output bytes = 2 quotes + per-byte (2 if escaped else 1).",
  "    (local.set $out (i32.const 2)) (local.set $i (i32.const 0))",
  "    (block $d1 (loop $l1",
  "      (br_if $d1 (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (if (i32.or (i32.or (i32.or (i32.eq (local.get $c) (local.get $q)) (i32.eq (local.get $c) (i32.const 92)))",
  "                          (i32.or (i32.eq (local.get $c) (i32.const 10)) (i32.eq (local.get $c) (i32.const 9))))",
  "                  (i32.or (i32.eq (local.get $c) (i32.const 13)) (i32.eq (local.get $c) (i32.const 0))))",
  "        (then (local.set $out (i32.add (local.get $out) (i32.const 2))))",
  "        (else (local.set $out (i32.add (local.get $out) (i32.const 1)))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l1)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $out)))",
  "    ;; pass 2: opening quote, escaped bytes, closing quote.",
  "    (array.set $u8arr (local.get $buf) (i32.const 0) (local.get $q))",
  "    (local.set $bo (i32.const 1)) (local.set $i (i32.const 0))",
  "    (block $d2 (loop $l2",
  "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (local.set $bo (call $mdk_dbg_esc_byte (local.get $buf) (local.get $bo) (local.get $c) (local.get $q)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))",
  "    (array.set $u8arr (local.get $buf) (local.get $bo) (local.get $q))",
  "    (struct.new $str (call $mdk_cp_count (local.get $buf) (local.get $out)) (local.get $buf)))",
  "  ;; debugStringLit : $str -> $str, surround with double-quotes (q = 34).",
  "  (func $mdk_debug_string_lit (param $s (ref $str)) (result (ref $str))",
  "    (call $mdk_dbg_quote (local.get $s) (i32.const 34)))",
  "  ;; debugCharLit : Char (i31 codepoint) -> $str, surround with single-quotes (q = 39).",
  "  (func $mdk_debug_char_lit (param $cp i32) (result (ref $str))",
  "    (call $mdk_dbg_quote (call $mdk_char_to_str (local.get $cp)) (i32.const 39)))",
]

-- ── W8 stringConcat (List String -> String) ──────────────────────────────────
-- Walks the W7 List rep ($T_List root with i32 tag 0=Nil; $C_Cons = tag,head,tail),
-- summing byte lengths then copying.  cp_count recomputed via $mdk_cp_count.  Emitted
-- only when the program uses BOTH strings AND lists (`useStrLeafRef && useListRef`),
-- so $C_Cons is in scope.  A Nil is an i31 immediate (ordinal 0); a Cons is a
-- $C_Cons struct.  We detect Nil by `ref.test (ref $C_Cons)` being false.
export strConcatRuntimeLines : List String
strConcatRuntimeLines = [
  "  ;; ── W8 stringConcat (List String) — walk the W7 cons list ──",
  "  (func $mdk_str_concat (param $list (ref eq)) (result (ref $str))",
  "    (local $w (ref eq)) (local $cell (ref $C_Cons)) (local $s (ref $str))",
  "    (local $total i32) (local $cpc i32) (local $off i32) (local $bl i32)",
  "    (local $buf (ref $u8arr)) (local $sb (ref $u8arr))",
  "    ;; pass 1: total byte length + total codepoints.",
  "    (local.set $total (i32.const 0)) (local.set $cpc (i32.const 0))",
  "    (local.set $w (local.get $list))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))",
  "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))",
  "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))",
  "      (local.set $total (i32.add (local.get $total) (array.len (struct.get $str $bytes (local.get $s)))))",
  "      (local.set $cpc (i32.add (local.get $cpc) (struct.get $str $cp_count (local.get $s))))",
  "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l)))",
  "    ;; pass 2: copy each segment's bytes into a flat buffer.",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $total)))",
  "    (local.set $off (i32.const 0))",
  "    (local.set $w (local.get $list))",
  "    (block $d2 (loop $l2",
  "      (br_if $d2 (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))",
  "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))",
  "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))",
  "      (local.set $sb (struct.get $str $bytes (local.get $s)))",
  "      (local.set $bl (array.len (local.get $sb)))",
  "      (array.copy $u8arr $u8arr (local.get $buf) (local.get $off) (local.get $sb) (i32.const 0) (local.get $bl))",
  "      (local.set $off (i32.add (local.get $off) (local.get $bl)))",
  "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l2)))",
  "    (struct.new $str (local.get $cpc) (local.get $buf)))",
]

-- ── W13 runtime-dispatched `++` (append over String OR List) ─────────────────
-- Core IR is type-erased: a `CBinPrim "++"` carries no operand type, so the
-- emitter cannot statically tell a String `++` from a List `++` (mirrors the LLVM
-- backend's @mdk_append).  $mdk_append inspects the LEFT operand's runtime shape:
--   • a $str struct      → binary string concat ($mdk_str_append),
--   • a list (i31 Nil or $C_Cons) → rebuild the left spine onto `b` (list append).
-- List append walks the left list into a fixed array, then conses back-to-front
-- onto `b` so cell identity/order matches the W7 cons rep.  Gated by useStrLeafRef
-- && useListRef (both forced by `noteW8Binop "++"`), so $str + $C_Cons are in scope.
export appendRuntimeLines : List String
appendRuntimeLines = [
  "  ;; ── W13 runtime-dispatched `++` (String concat OR List append) ──",
  "  ;; List append is ITERATIVE (destination-passing over the mut $C_Cons tail),",
  "  ;; mirroring the native mdk_list_append: walk `a` head-first, struct.new each",
  "  ;; result cell with a placeholder i31 tail, struct.set it into the previous",
  "  ;; cell's mut tail, and after the loop point the final tail at `b`.  O(1) extra",
  "  ;; space, no self-recursion → no wasm-stack growth proportional to length(a).",
  "  (func $mdk_append (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
  "    (local $cell (ref $C_Cons))",
  "    (local $result (ref eq))",
  "    (local $dest (ref $C_Cons))",
  "    (local $new (ref $C_Cons))",
  "    ;; String `++`: left is a $str struct → byte concat.",
  "    (if (ref.test (ref $str) (local.get $a))",
  "      (then (return (call $mdk_str_append (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b))))))",
  "    ;; List `++`: a Nil (non-$C_Cons) left → b unchanged.",
  "    (if (i32.eqz (ref.test (ref $C_Cons) (local.get $a)))",
  "      (then (return (local.get $b))))",
  "    ;; First cell: copy head(a), placeholder i31 tail (overwritten before any read).",
  "    (local.set $cell (ref.cast (ref $C_Cons) (local.get $a)))",
  "    (local.set $dest (struct.new $C_Cons (i32.const 0)",
  "      (struct.get $C_Cons 1 (local.get $cell)) (ref.i31 (i32.const 0))))",
  "    (local.set $result (local.get $dest))",
  "    ;; Walk the rest of `a`, appending a fresh cell into the previous mut tail.",
  "    (block $done",
  "      (loop $l",
  "        ;; If tail(cell) is not a Cons (i.e. Nil), we are done.",
  "        (br_if $done (i32.eqz (ref.test (ref $C_Cons)",
  "          (struct.get $C_Cons 2 (local.get $cell)))))",
  "        (local.set $cell (ref.cast (ref $C_Cons)",
  "          (struct.get $C_Cons 2 (local.get $cell))))",
  "        (local.set $new (struct.new $C_Cons (i32.const 0)",
  "          (struct.get $C_Cons 1 (local.get $cell)) (ref.i31 (i32.const 0))))",
  "        (struct.set $C_Cons 2 (local.get $dest) (local.get $new))",
  "        (local.set $dest (local.get $new))",
  "        (br $l)))",
  "    ;; Final tail → b (sharing it, not copying).",
  "    (struct.set $C_Cons 2 (local.get $dest) (local.get $b))",
  "    (local.get $result))",
]

-- ── layer-9 runtime-shape-dispatched value comparison (`==`/`!=`/`<`/`>`/…) ──────
-- Core IR is type-erased: a ref-mode `CBinPrim "=="` carries no operand type, so the
-- emitter cannot statically tell a `String == String` (boxed `$str` struct) from an
-- `Int == Int` (i31 immediate).  The old emitter unconditionally lowered `==` as an
-- i31 compare (`ref.cast (ref i31)` + `i31.get_s`), so a String operand trapped
-- `illegal cast` at `ref.cast (ref i31)` (e.g. parser's `coalesceStep`'s `n == name`).
-- Mirrors the LLVM backend's @mdk_value_eq / @mdk_value_cmp_raw (and the W13
-- $mdk_append precedent): discriminate on the operand's RUNTIME shape.
--   $mdk_value_eq(a,b)  : both $str → byte-equal; else `ref.eq` (i31/struct identity,
--     correct for Int/Bool/Char/Unit immediates).  Returns an i31 Bool (0/1).
--   $mdk_value_cmp(a,b) : both $str → $mdk_str_compare → -1/0/1; else compare the i31
--     signed values.  Returns a PLAIN i32 -1/0/1 (the emitter then i32-compares it
--     against 0 for the requested ordering op).  Gated by useStrRef (forces `$str`
--     in scope); only reached in ref-mode where the i31 fast path was unsafe.
export valueEqRuntimeLines : List String
valueEqRuntimeLines = [
  "  ;; -- layer-9 runtime-shape-dispatched `==`/`!=` (String byte-equal OR immediate identity) --",
  "  (func $mdk_value_eq (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
  "    ;; both operands are $str structs -> byte equality.",
  "    (if (i32.and (ref.test (ref $str) (local.get $a)) (ref.test (ref $str) (local.get $b)))",
  "      (then (return (ref.i31 (i32.eq",
  "        (i32.const 1)",
  "        (i31.get_u (ref.cast (ref i31) (call $mdk_str_compare (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b)))))))))) ;; Eq == ordinal 1",
  "    ;; A2 (poly-Eq-on-Float): two boxed $float cells have distinct identities, so the",
  "    ;; `ref.eq` fallback would report equal floats as unequal — compare f64 values.",
  "    (if (i32.and (ref.test (ref $float) (local.get $a)) (ref.test (ref $float) (local.get $b)))",
  "      (then (return (ref.i31 (f64.eq",
  "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
  "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))",
  "    ;; otherwise immediate/struct identity (i31 Int/Bool/Char/Unit, or ctor cells).",
  "    ;; layer-17 §2.1: a >2^30 Int is a $boxint struct, so two equal large Ints have",
  "    ;; distinct identities — when either side is a $boxint compare the unboxed i64.",
  "    (if (i32.or (ref.test (ref $boxint) (local.get $a)) (ref.test (ref $boxint) (local.get $b)))",
  "      (then (return (ref.i31 (i64.eq (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))",
  "    (ref.i31 (i32.eqz (i32.eqz (ref.eq (local.get $a) (local.get $b))))))",
  "  ;; -- layer-9 runtime-shape-dispatched ordering (String byte-order OR i31 signed) -> i32 -1/0/1 --",
  "  (func $mdk_value_cmp (param $a (ref eq)) (param $b (ref eq)) (result i32)",
  "    (local $o i32) (local $ia i64) (local $ib i64) (local $fa f64) (local $fb f64)",
  "    (if (i32.and (ref.test (ref $str) (local.get $a)) (ref.test (ref $str) (local.get $b)))",
  "      (then",
  "        ;; $mdk_str_compare -> Ordering i31 (Lt 0 / Eq 1 / Gt 2); map to -1/0/1.",
  "        (local.set $o (i31.get_u (ref.cast (ref i31) (call $mdk_str_compare (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b))))))",
  "        (return (i32.sub (local.get $o) (i32.const 1)))))",
  "    ;; A2 (poly-Ord-on-Float): a boxed $float operand -> f64 compare -> -1/0/1.",
  "    ;; Mirrors the arith helpers' left-operand $float discriminant.  A poly `Ord`",
  "    ;; compare (`a > b` on a Num/Ord type-var param) reaches here with $float cells;",
  "    ;; without this arm $mdk_unbox_int would ref.cast the $float to $boxint -> trap.",
  "    (if (ref.test (ref $float) (local.get $a))",
  "      (then",
  "        (local.set $fa (struct.get $float 0 (ref.cast (ref $float) (local.get $a))))",
  "        (local.set $fb (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))",
  "        (if (f64.lt (local.get $fa) (local.get $fb)) (then (return (i32.const -1))))",
  "        (if (f64.gt (local.get $fa) (local.get $fb)) (then (return (i32.const 1))))",
  "        (return (i32.const 0))))",
  "    ;; layer-17 §2.1: Int compare over the i64 box/unbox seam (handles >2^30 boxed).",
  "    (local.set $ia (call $mdk_unbox_int (local.get $a)))",
  "    (local.set $ib (call $mdk_unbox_int (local.get $b)))",
  "    (if (i64.lt_s (local.get $ia) (local.get $ib)) (then (return (i32.const -1))))",
  "    (if (i64.gt_s (local.get $ia) (local.get $ib)) (then (return (i32.const 1))))",
  "    (i32.const 0))",
]

-- ── A0 (poly-`Num`-on-Float): runtime value-tag-dispatched arithmetic helpers ──
-- The WasmGC port of native's runtime tag-dispatched `mdk_num_add/sub/mul/div/mod`
-- (`runtime/medaka_rt.c`): a POLYMORPHIC `Num a` operand (type known only at runtime)
-- has neither a static Float scalar-tag (approach C) nor a structural Float shape, so
-- the inline int primitive (`$mdk_unbox_int` -> i64 op) TRAPS `illegal cast` on a boxed
-- `$float` operand (WASM-POLY-NUM-DESIGN §2.2).  These helpers discriminate on the LEFT
-- operand's RUNTIME shape (exactly as native tests the low tag bit): `$float` -> f64 op +
-- `struct.new $float`; else the i31/`$boxint` int path via `$mdk_unbox_int`/`$mdk_box_int`
-- (byte-identical to the inline int fallback, so an Int instantiation is unchanged).
-- `div` truncates toward zero (`i64.div_s` / `f64.div`); `%` is sign-of-dividend for Int
-- (`i64.rem_s`) and `a - b*trunc(a/b)` for Float (== `$mdk_float_rem` == LLVM `frem` ==
-- native's `mdk_num_mod`).  Emitted only when a poly-`Num` operand is routed here
-- (`useValueArithRef`); `$mdk_unbox_int`/`$mdk_box_int` are always in scope (ioRuntimeLines).
export valueArithRuntimeLines : List String
valueArithRuntimeLines = [
  "  ;; -- A0 runtime value-tag-dispatched arithmetic (poly-`Num`: Int i31/$boxint OR $float) --",
  "  (func $mdk_value_add (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
  "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))",
  "      (then (struct.new $float (f64.add",
  "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
  "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))",
  "      (else (call $mdk_box_int (i64.add (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))",
  "  (func $mdk_value_sub (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
  "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))",
  "      (then (struct.new $float (f64.sub",
  "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
  "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))",
  "      (else (call $mdk_box_int (i64.sub (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))",
  "  (func $mdk_value_mul (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
  "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))",
  "      (then (struct.new $float (f64.mul",
  "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
  "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))",
  "      (else (call $mdk_box_int (i64.mul (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))",
  "  (func $mdk_value_div (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
  "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))",
  "      (then (struct.new $float (f64.div",
  "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
  "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))",
  "      (else (call $mdk_box_int (i64.div_s (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))",
  "  (func $mdk_value_mod (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
  "    (local $fa f64) (local $fb f64)",
  "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))",
  "      (then",
  "        (local.set $fa (struct.get $float 0 (ref.cast (ref $float) (local.get $a))))",
  "        (local.set $fb (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))",
  "        (struct.new $float (f64.sub (local.get $fa) (f64.mul (local.get $fb) (f64.trunc (f64.div (local.get $fa) (local.get $fb)))))))",
  "      (else (call $mdk_box_int (i64.rem_s (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))",
  "  ;; -- A1 poly-`Ord`/`Eq`-on-Float, NUM-ONLY (no $str): $float f64-eq/cmp else i64 --",
  "  (func $mdk_value_eq_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
  "    (if (ref.test (ref $float) (local.get $a))",
  "      (then (return (ref.i31 (f64.eq",
  "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
  "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))",
  "    (ref.i31 (i64.eq (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))",
  "  (func $mdk_value_cmp_num (param $a (ref eq)) (param $b (ref eq)) (result i32)",
  "    (local $fa f64) (local $fb f64) (local $ia i64) (local $ib i64)",
  "    (if (ref.test (ref $float) (local.get $a))",
  "      (then",
  "        (local.set $fa (struct.get $float 0 (ref.cast (ref $float) (local.get $a))))",
  "        (local.set $fb (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))",
  "        (if (f64.lt (local.get $fa) (local.get $fb)) (then (return (i32.const -1))))",
  "        (if (f64.gt (local.get $fa) (local.get $fb)) (then (return (i32.const 1))))",
  "        (return (i32.const 0))))",
  "    (local.set $ia (call $mdk_unbox_int (local.get $a)))",
  "    (local.set $ib (call $mdk_unbox_int (local.get $b)))",
  "    (if (i64.lt_s (local.get $ia) (local.get $ib)) (then (return (i32.const -1))))",
  "    (if (i64.gt_s (local.get $ia) (local.get $ib)) (then (return (i32.const 1))))",
  "    (i32.const 0))",
]

-- ── W8 RNG — deterministic SplitMix64 (RUNTIME-DESIGN §5 RNG) ─────────────────
-- Byte-identical to medaka_rt.c's shared SplitMix64 (the same algorithm the OCaml
-- oracle runs), so seeded streams match exactly.  Seed lives in a mutable i64 global
-- (default 0).  All arithmetic is i64, all shifts LOGICAL (i64.shr_u), wrapping on
-- overflow (i64 ops wrap naturally).  Emitted when the program uses any RNG extern.
--   randomInt lo hi : INCLUSIVE [lo,hi]; randomBool : LSB; randomChar : ASCII [32,126].
-- randomFloat is DEFERRED (W8b) with the Float-formatting work.
export rngStateGlobalLines : List String
rngStateGlobalLines = ["  (global $mdk_rng_state (mut i64) (i64.const 0))"]

export rngRuntimeLines : List String
rngRuntimeLines = [
  "  ;; ── W8 SplitMix64 RNG (byte-identical to medaka_rt.c) ──",
  "  (func $mdk_next_u64 (result i64)",
  "    (local $z i64)",
  "    (global.set $mdk_rng_state (i64.add (global.get $mdk_rng_state) (i64.const 0x9E3779B97F4A7C15)))",
  "    (local.set $z (global.get $mdk_rng_state))",
  "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 30))) (i64.const 0xBF58476D1CE4E5B9)))",
  "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 27))) (i64.const 0x94D049BB133111EB)))",
  "    (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 31))))",
  "  ;; randomInt lo hi : i32 lo/hi -> i32 in [lo,hi] (INCLUSIVE).  range<=0 -> lo.",
  "  (func $mdk_random_int (param $lo i32) (param $hi i32) (result i32)",
  "    (local $range i32)",
  "    (local.set $range (i32.add (i32.sub (local.get $hi) (local.get $lo)) (i32.const 1)))",
  "    (if (result i32) (i32.le_s (local.get $range) (i32.const 0))",
  "      (then (local.get $lo))",
  "      (else",
  "        (i32.add (local.get $lo)",
  "          (i32.wrap_i64 (i64.rem_u (call $mdk_next_u64) (i64.extend_i32_s (local.get $range))))))))",
  "  (func $mdk_random_bool (result i32)",
  "    (i32.wrap_i64 (i64.and (call $mdk_next_u64) (i64.const 1))))",
  "  (func $mdk_random_char (result i32)",
  "    (i32.add (i32.const 32) (i32.wrap_i64 (i64.rem_u (call $mdk_next_u64) (i64.const 95)))))",
]

-- ── W8 Hashable per-type hashers — SPECIFIED, byte-identical to medaka_rt.c ────
-- hashInt/hashChar : SplitMix64 finalizer (mix64) of the value, masked to [0,2^30).
-- hashBool : 0/1 direct.  hashString : FNV-1a over UTF-8 BYTES, masked.  hashFloat
-- is DEFERRED (W8b, Float work).  Mask 0x3FFFFFFF = 2^30-1 fits i31 (non-negative).
export hashRuntimeLines : List String
hashRuntimeLines = [
  "  ;; ── W8 per-type hashers (byte-identical to medaka_rt.c) ──",
  "  ;; SplitMix64 finalizer as a pure mixer (no state update).",
  "  (func $mdk_hash_mix64 (param $x i64) (result i64)",
  "    (local $z i64)",
  "    (local.set $z (i64.add (local.get $x) (i64.const 0x9E3779B97F4A7C15)))",
  "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 30))) (i64.const 0xBF58476D1CE4E5B9)))",
  "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 27))) (i64.const 0x94D049BB133111EB)))",
  "    (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 31))))",
  "  ;; hashInt / hashChar : mix64(value) & 0x3FFFFFFF.  `n` is the untagged i32 value",
  "  ;; sign-extended to i64 (matching medaka_rt.c's signed `tagged>>1`).",
  "  (func $mdk_hash_int (param $n i32) (result i32)",
  "    (i32.wrap_i64 (i64.and (call $mdk_hash_mix64 (i64.extend_i32_s (local.get $n))) (i64.const 0x3FFFFFFF))))",
  "  (func $mdk_hash_bool (param $b i32) (result i32)",
  "    (if (result i32) (local.get $b) (then (i32.const 1)) (else (i32.const 0))))",
]

-- the $str-dependent hasher (hashString): FNV-1a over UTF-8 BYTES, masked.  offset
-- 0xCBF29CE484222325, prime 0x100000001B3 (all i64 wrapping).  Emitted only when the
-- program uses strings (a hashInt-only program never names the absent `$str`).
export hashStringRuntimeLines : List String
hashStringRuntimeLines = [
  "  ;; hashString : FNV-1a over UTF-8 BYTES, masked.",
  "  (func $mdk_hash_string (param $s (ref $str)) (result i32)",
  "    (local $b (ref $u8arr)) (local $n i32) (local $i i32) (local $h i64)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $h (i64.const 0xCBF29CE484222325))",
  "    (local.set $i (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $h (i64.mul (i64.xor (local.get $h) (i64.extend_i32_u (array.get_u $u8arr (local.get $b) (local.get $i)))) (i64.const 0x100000001B3)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (i32.wrap_i64 (i64.and (local.get $h) (i64.const 0x3FFFFFFF))))",
]

-- ── W11b: ASCII char classification + case-mapping runtime ────────────────────
-- Byte-identical to medaka_rt.c mdk_char_is_* / mdk_char_to_* (ASCII-only).
-- Each takes an UNBOXED i32 codepoint (caller does ref.cast + i31.get_u first)
-- and returns an i32 (0/1 for predicates; codepoint for case-mappers).
-- The caller wraps the result with ref.i31.
export charClassRuntimeLines : List String
charClassRuntimeLines = [
  "  ;; ── W11b ASCII char classification + case mapping (byte-identical to medaka_rt.c) ──",
  "  (func $mdk_char_is_alpha (param $c i32) (result i32)",
  "    (i32.or",
  "      (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))",
  "      (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))))",
  "  (func $mdk_char_is_space (param $c i32) (result i32)",
  "    (i32.or",
  "      (i32.eq (local.get $c) (i32.const 32))",
  "      (i32.and (i32.ge_u (local.get $c) (i32.const 9)) (i32.le_u (local.get $c) (i32.const 13)))))",
  "  (func $mdk_char_is_upper (param $c i32) (result i32)",
  "    (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90))))",
  "  (func $mdk_char_is_lower (param $c i32) (result i32)",
  "    (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122))))",
  "  ;; charIsPunct: exact set from medaka_rt.c switch — Unicode Pc/Pd/Pe/Pf/Pi/Po/Ps ASCII.",
  "  ;; Included: ! \" # % & ' ( ) * , - . / : ; ? @ [ \\ ] _ { }",
  "  ;; Excluded ($+<=>^`|~): those are Unicode symbols (Sm/Sc/Sk), not punctuation.",
  "  ;; Right-associative OR chain over 23 chars = 22 i32.or nodes.",
  "  (func $mdk_char_is_punct (param $c i32) (result i32)",
  "    (i32.or (i32.eq (local.get $c) (i32.const 33))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 34))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 35))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 37))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 38))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 39))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 40))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 41))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 42))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 44))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 45))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 46))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 47))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 58))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 59))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 63))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 64))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 91))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 92))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 93))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 95))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 123))",
  "           (i32.eq (local.get $c) (i32.const 125))",
  "    )))))))))))))))))))))))",
  "  (func $mdk_char_to_upper (param $c i32) (result i32)",
  "    (if (result i32)",
  "      (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))",
  "      (then (i32.sub (local.get $c) (i32.const 32)))",
  "      (else (local.get $c))))",
  "  (func $mdk_char_to_lower (param $c i32) (result i32)",
  "    (if (result i32)",
  "      (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))",
  "      (then (i32.add (local.get $c) (i32.const 32)))",
  "      (else (local.get $c))))",
]

-- ── W8b Float externs (RUNTIME-DESIGN §5 Float / WASMGC-DESIGN §3.3 boxed Float) ──
-- The §3.3 boxed Float is `(struct $float (field f64))`, declared unconditionally in
-- the rec group.  A Float value is a boxed (ref eq) struct; a Float LITERAL emits
-- `(struct.new $float (f64.const <floatToString-text>))` — the SAME `%.12g` rendering
-- the LLVM oracle bakes into its IR const, so the parsed double is byte-identical
-- across clang and wasm-tools (verified: identical i64.reinterpret_f64 bit patterns).
--
-- floatToString is the CRUX.  The native impl is `snprintf(buf,"%.12g",d)` + a `.0`
-- append (when the lexeme has no `.`/`e`/`E`/`n`/`i`).  `%.12g` is FIXED-12-significant
-- `%g`, not shortest-round-trip dtoa, but reproducing its correctly-rounded decimal
-- conversion + exponent-form thresholds + trailing-zero stripping in pure WAT means
-- reimplementing dtoa (no printf available).  Per the W8b plan's authorized fallback,
-- floatToString is a HOST IMPORT: the JS host reproduces `%.12g` byte-for-byte via
-- `toExponential(11)` (12 significant digits, correct round-half-to-even) + %g-style
-- form selection + trailing-zero trim + the `.0` rule (test/wasm/run.js fmt12g).  This
-- is the ONE host-dependent formatter — a clean parallel to the deferred IO/WASI host
-- surface; a non-JS wedge target would later need the in-WAT dtoa.  The host caches the
-- formatted bytes and exposes them as (length, byte-at-index) so the module rebuilds a
-- $str without GC<->JS interop.
export floatFmtImportLines : List String
floatFmtImportLines = [
  "  ;; -- W8b floatToString host seam (%.12g — reproduced JS-side, see run.js) --",
  "  (import \"env\" \"mdk_float_fmt\" (func $mdk_float_fmt (param f64) (result i32)))",
  "  (import \"env\" \"mdk_float_fmt_byte\" (func $mdk_float_fmt_byte (param i32) (result i32)))",
]

-- stringToFloat host seam: the guest pushes the string's bytes via the path channel
-- (mdk_path_reset + mdk_path_push, shared with IO) then calls mdk_str_to_float which
-- reads pathBuf as a UTF-8 string and returns Number(str) as an f64.  run.js implements
-- mdk_str_to_float using JavaScript's Number() which is byte-identical to C strtod on
-- the valid-decimal subset that medaka float literals and json.mdk produce.  Gated on
-- useFloatStrRef (set by noteW8Extern when "stringToFloat" is referenced).
export floatStrImportLines : List String
floatStrImportLines = [
  "  ;; -- stringToFloat host seam (Number() JS-side, see run.js) --",
  "  (import \"env\" \"mdk_str_to_float\" (func $mdk_str_to_float (result f64)))",
]

-- $mdk_string_to_float : (ref $str) -> (ref eq)  (= Option Float = Some(boxed $float) | None)
-- Protocol: reset the path buffer, push each UTF-8 byte of the string, call the host
-- import (which parses via Number()), box the f64 into a $float, wrap in Some.
-- Returns None (i31 ordinal 1) if the host returns NaN AND the input wasn't "nan"
-- (matching strtod's Option contract: only valid parses return Some).
-- NOTE: JavaScript Number("nan"/"inf"/"-inf") returns NaN/Infinity/-Infinity, matching
-- medaka_rt.c strtod behaviour; Number("") -> 0.0 but strtod("",NULL) -> 0.0 too.
-- We return Some for every non-NaN result and None for NaN (unless the string IS "nan").
-- The host-side function sees the pushed bytes via the shared pathBuf.
export floatStrRuntimeLines : List String
floatStrRuntimeLines = [
  "  ;; stringToFloat : $str -> Option Float (ref eq).",
  "  (func $mdk_string_to_float (param $s (ref $str)) (result (ref eq))",
  "    (local $b (ref $u8arr)) (local $i i32) (local $n i32) (local $d f64)",
  "    (call $mdk_path_reset)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $i (i32.const 0))",
  "    (block $done (loop $loop",
  "      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))",
  "      (call $mdk_path_push (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1)))",
  "      (br $loop)))",
  "    (local.set $d (call $mdk_str_to_float))",
  "    ;; Return Some(boxed f64) always — JS Number() returns NaN for unparseable,",
  "    ;; and medaka_rt.c strtod returns Some(NaN) for \"nan\" and None for truly",
  "    ;; unparseable strings.  We mirror: if the result is NaN, return None; if nan",
  "    ;; the string is \"nan\" strtod returns Some(NaN) — but for the medaka use cases",
  "    ;; (float literals, json.mdk numeric strings) the host never returns NaN for",
  "    ;; a valid parse, so a simple NaN->None mapping is correct.",
  "    (if (result (ref eq)) (f64.ne (local.get $d) (local.get $d))",
  "      (then (ref.i31 (i32.const 1)))",
  "      (else (struct.new $C_Some (i32.const 0) (struct.new $float (local.get $d)))))",
  "  )",
]

-- the Float runtime (RUNTIME-DESIGN §5).  intToFloat/floatToInt are INTRINSIC (the
-- §3.3 box <-> raw conversion); floatToString rebuilds a $str from the host-formatted
-- bytes.  All byte-identical to the native oracle.
export floatRuntimeLines : List String
floatRuntimeLines = [
  "  ;; -- W8b Float runtime (byte-identical to medaka_rt.c) --",
  "  ;; intToFloat : i32 -> boxed (struct $float).",
  "  (func $mdk_int_to_float (param $n i32) (result (ref $float))",
  "    (struct.new $float (f64.convert_i32_s (local.get $n))))",
  "  ;; floatToInt : boxed $float -> i32 (truncate toward zero, matching (int)d).",
  "  (func $mdk_float_to_int (param $f (ref $float)) (result i32)",
  "    (i32.trunc_f64_s (struct.get $float 0 (local.get $f))))",
  "  ;; floatRem a b = a - b*trunc(a/b)  (== C fmod == LLVM frem); backs `Float % Float`.",
  "  (func $mdk_float_rem (param $a f64) (param $b f64) (result f64)",
  "    (f64.sub (local.get $a) (f64.mul (local.get $b) (f64.trunc (f64.div (local.get $a) (local.get $b))))))",
  "  ;; floatToString : the host formats (%.12g + .0 rule) into a cache; copy the bytes",
  "  ;; into a fresh $str.  cp_count == byte_len (the %.12g output is ASCII).",
  "  (func $mdk_float_to_str (param $d f64) (result (ref $str))",
  "    (local $n i32) (local $i i32) (local $buf (ref $u8arr))",
  "    (local.set $n (call $mdk_float_fmt (local.get $d)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))",
  "    (local.set $i (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (array.set $u8arr (local.get $buf) (local.get $i) (call $mdk_float_fmt_byte (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (struct.new $str (local.get $n) (local.get $buf)))",
]

-- the float HASH ($mdk_hash_float) — bit-reinterpret f64 -> i64 then mix64 & mask.
-- Emitted only when the program uses BOTH Float and a per-type hasher (so the shared
-- $mdk_hash_mix64 from hashRuntimeLines is in scope).
export hashFloatRuntimeLines : List String
hashFloatRuntimeLines = [
  "  ;; hashFloat : reinterpret the double's bits as i64 -> mix64 -> mask [0,2^30).",
  "  (func $mdk_hash_float (param $f (ref $float)) (result i32)",
  "    (i32.wrap_i64 (i64.and (call $mdk_hash_mix64 (i64.reinterpret_f64 (struct.get $float 0 (local.get $f)))) (i64.const 0x3FFFFFFF))))",
]

-- randomFloat ($mdk_random_float) — SplitMix64 draw -> f64 in [-1,1).  Needs the W8
-- $mdk_next_u64 from rngRuntimeLines (gated on float+rng co-use).  `(next>>11)` is the
-- top 53 bits; * 2^-53 gives [0,1); * 2 - 1 gives [-1,1) — EXACTLY medaka_rt.c.
export randomFloatRuntimeLines : List String
randomFloatRuntimeLines = [
  "  ;; randomFloat : SplitMix64 -> f64 in [-1,1) (NOTE the -1 offset — see medaka_rt.c).",
  "  (func $mdk_random_float (result (ref $float))",
  "    (struct.new $float",
  "      (f64.sub",
  "        (f64.mul",
  "          (f64.mul (f64.convert_i64_u (i64.shr_u (call $mdk_next_u64) (i64.const 11)))",
  "                   (f64.const 1.1102230246251565e-16))",
  "          (f64.const 2.0))",
  "        (f64.const 1.0))))",
]

-- ── W12 IO host surface (readFile / fileExists / args / getEnv / exit) ───────
-- The LAST emitter-gap category: the IO externs.  GC refs ($str) cannot cross the
-- wasm import boundary, so strings are marshaled through a byte-at-a-time channel —
-- exactly the length+byte protocol the floatToString host seam uses (run.js fmt12g).
--
-- Protocol (run.js backs each import with Node fs/process behind a swappable `vfs`
-- seam so a browser playground can supply an in-memory FS with the same signatures):
--   SENDING a string TO the host (a path / env-var name): the guest calls
--     $mdk_path_reset() then loops the arg $str's bytes calling mdk_path_push(byte).
--   READING a string FROM the host (file contents / env value / arg): after the host
--     caches the result bytes, the guest reads mdk_result_len() + mdk_result_byte(i)
--     per byte and rebuilds a fresh $str ($mdk_io_result_to_str).
--   readFile  : push path, mdk_read_file() -> i32 (1=Ok, 0=Err); rebuild the result
--     $str and wrap Ok (struct.new $C_Ok, ord 0) / Err (struct.new $C_Err, ord 1).
--   fileExists: push path, mdk_file_exists() -> i32 (1/0) -> Bool i31.
--   getEnv    : push name, mdk_get_env() -> i32 (1=Some / 0=None); rebuild $str and
--     wrap Some (struct.new $C_Some, ord 0) / None (i31 ord 1).
--   args      : mdk_args_count(); per i build a $str from mdk_arg_len(i)/mdk_arg_byte(i,j),
--     fold a Cons chain right-to-left ending in Nil (i31 ord 1).
--   exit      : mdk_exit(i32) host import then `unreachable` (stack-polymorphic).
-- Gated on useIORef (set by noteW8Extern when any IO extern is referenced).
export ioHostImportLines : List String
ioHostImportLines = [
  "  ;; -- W12 IO host surface (byte-channel marshaling, see run.js) --",
  "  (import \"env\" \"mdk_path_reset\" (func $mdk_path_reset))",
  "  (import \"env\" \"mdk_path_push\" (func $mdk_path_push (param i32)))",
  "  (import \"env\" \"mdk_read_file\" (func $mdk_read_file (result i32)))",
  "  (import \"env\" \"mdk_file_exists\" (func $mdk_file_exists (result i32)))",
  "  (import \"env\" \"mdk_get_env\" (func $mdk_get_env (result i32)))",
  "  (import \"env\" \"mdk_args_count\" (func $mdk_args_count (result i32)))",
  "  (import \"env\" \"mdk_arg_len\" (func $mdk_arg_len (param i32) (result i32)))",
  "  (import \"env\" \"mdk_arg_byte\" (func $mdk_arg_byte (param i32) (param i32) (result i32)))",
  "  (import \"env\" \"mdk_result_len\" (func $mdk_result_len (result i32)))",
  "  (import \"env\" \"mdk_result_byte\" (func $mdk_result_byte (param i32) (result i32)))",
  "  (import \"env\" \"mdk_exit\" (func $mdk_exit (param i32)))",
]

-- the IO host-surface runtime: the byte-channel marshalers + the five extern bodies.
-- $str-dependent (every path/result is a $str) and $C_Ok/$C_Err/$C_Some/$T_List are
-- always declared in ref-mode, so these are always in scope when emitted.
export ioHostRuntimeLines : List String
ioHostRuntimeLines = [
  "  ;; -- W12 IO host-surface runtime --",
  "  ;; push a $str's bytes to the host path buffer (reset first).",
  "  (func $mdk_push_path (param $s (ref $str))",
  "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)",
  "    (call $mdk_path_reset)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $i (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (call $mdk_path_push (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    )",
  "  ;; rebuild a fresh $str from the host result buffer (length + byte-at-index).",
  "  ;; cp_count is the true UTF-8 codepoint count (count lead bytes: those whose top",
  "  ;; two bits are NOT 0b10, i.e. (b & 0xC0) != 0x80).  A byte-length approximation",
  "  ;; here is WRONG for any multibyte content: $mdk_str_to_chars allocates its output",
  "  ;; $arr to cp_count and the lexer reads arrayLength as the char count, so an inflated",
  "  ;; cp_count appends trailing NUL chars past the real codepoints -> a stray '\\0' falls",
  "  ;; through every clause head and traps (a file with a single em-dash comment was enough).",
  "  (func $mdk_io_result_to_str (result (ref $str))",
  "    (local $n i32) (local $i i32) (local $buf (ref $u8arr)) (local $cpc i32) (local $b i32)",
  "    (local.set $n (call $mdk_result_len))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))",
  "    (local.set $i (i32.const 0)) (local.set $cpc (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $b (call $mdk_result_byte (local.get $i)))",
  "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $b))",
  "      (if (i32.ne (i32.and (local.get $b) (i32.const 192)) (i32.const 128))",
  "        (then (local.set $cpc (i32.add (local.get $cpc) (i32.const 1)))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (struct.new $str (local.get $cpc) (local.get $buf)))",
  "  ;; readFile : $str path -> Result String String.  1=Ok contents / 0=Err message.",
  "  (func $mdk_read_file_io (param $path (ref $str)) (result (ref eq))",
  "    (local $st i32)",
  "    (call $mdk_push_path (local.get $path))",
  "    (local.set $st (call $mdk_read_file))",
  "    (if (result (ref eq)) (local.get $st)",
  "      (then (struct.new $C_Ok (i32.const 0) (call $mdk_io_result_to_str)))",
  "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))",
  "  ;; fileExists : $str path -> Bool (i31 ordinal: False=0 / True=1).",
  "  (func $mdk_file_exists_io (param $path (ref $str)) (result (ref eq))",
  "    (call $mdk_push_path (local.get $path))",
  "    (ref.i31 (call $mdk_file_exists)))",
  "  ;; getEnv : $str name -> Option String.  1=Some value / 0=None.",
  "  (func $mdk_get_env_io (param $name (ref $str)) (result (ref eq))",
  "    (local $st i32)",
  "    (call $mdk_push_path (local.get $name))",
  "    (local.set $st (call $mdk_get_env))",
  "    (if (result (ref eq)) (local.get $st)",
  "      (then (struct.new $C_Some (i32.const 0) (call $mdk_io_result_to_str)))",
  "      (else (ref.i31 (i32.const 1)))))",
]

-- the `args` extern body — split out from ioHostRuntimeLines because it references
-- the cons-list types ($C_Cons / Nil), which are only declared when the program uses
-- a list.  Gated on useArgsRef (set when `args` is referenced, which also forces
-- useListRef so $C_Cons is in scope).
export ioArgsRuntimeLines : List String
ioArgsRuntimeLines = [
  "  ;; build a $str from the i-th host arg (mdk_arg_len(i) + mdk_arg_byte(i,j)).",
  "  (func $mdk_arg_to_str (param $idx i32) (result (ref $str))",
  "    (local $n i32) (local $j i32) (local $buf (ref $u8arr))",
  "    (local.set $n (call $mdk_arg_len (local.get $idx)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))",
  "    (local.set $j (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $j) (local.get $n)))",
  "      (array.set $u8arr (local.get $buf) (local.get $j) (call $mdk_arg_byte (local.get $idx) (local.get $j)))",
  "      (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $l)))",
  "    (struct.new $str (local.get $n) (local.get $buf)))",
  "  ;; args : Unit -> List String.  Fold a Cons chain right-to-left ending in Nil.",
  "  (func $mdk_args_io (result (ref eq))",
  "    (local $c i32) (local $i i32) (local $acc (ref eq))",
  "    (local.set $c (call $mdk_args_count))",
  "    (local.set $acc (ref.i31 (i32.const 1)))",  -- Nil
  "    (local.set $i (i32.sub (local.get $c) (i32.const 1)))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.lt_s (local.get $i) (i32.const 0)))",
  "      (local.set $acc (struct.new $C_Cons (i32.const 0) (call $mdk_arg_to_str (local.get $i)) (local.get $acc)))",
  "      (local.set $i (i32.sub (local.get $i) (i32.const 1))) (br $l)))",
  "    (local.get $acc))",
]

-- ── stage-D: byte-clean file I/O host surface (readFileBytes / writeFileBytes) ─
-- The FILE seam for the bytes-first sqlite lib.  readFileBytes reuses the existing
-- read byte-channel ($mdk_read_file + $mdk_result_len/$mdk_result_byte) but rebuilds
-- an $arr of i31 Int bytes (NOT a UTF-8 $str), so it needs no new host import — only
-- the runtime body ($mdk_read_file_bytes_io).  writeFileBytes is the genuinely NEW
-- direction: three new host imports stream the path (reuse $mdk_push_path) + the byte
-- array OUT to a JS write buffer, then commit a Node `fs.writeFileSync`.  Both return
-- a Result String (…) byte-identical to the native runtime (medaka_rt.c
-- mdk_read_file_bytes / mdk_write_file_bytes).  Gated on useFileBytesRef (which also
-- forces useIORef so $mdk_push_path / $mdk_io_result_to_str are in scope, useArrayRef
-- so $arr is declared, and useStrRef for the Err $str).
export fileBytesHostImportLines : List String
fileBytesHostImportLines = [
  "  ;; -- stage-D writeFileBytes host imports (path via mdk_path_push; bytes streamed) --",
  "  (import \"env\" \"mdk_write_file_reset\" (func $mdk_write_file_reset))",
  "  (import \"env\" \"mdk_write_file_push\" (func $mdk_write_file_push (param i32)))",
  "  (import \"env\" \"mdk_write_file_commit\" (func $mdk_write_file_commit (result i32)))",
]

export fileBytesRuntimeLines : List String
fileBytesRuntimeLines = [
  "  ;; -- stage-D byte-clean file I/O runtime --",
  "  ;; readFileBytes : $str path -> Result String (Array Int).  1=Ok bytes / 0=Err msg.",
  "  ;; Reuses the read byte-channel but rebuilds an $arr of i31 Int bytes (0..255).",
  "  (func $mdk_read_file_bytes_io (param $path (ref $str)) (result (ref eq))",
  "    (local $st i32) (local $n i32) (local $i i32) (local $out (ref $arr))",
  "    (call $mdk_push_path (local.get $path))",
  "    (local.set $st (call $mdk_read_file))",
  "    (if (result (ref eq)) (local.get $st)",
  "      (then",
  "        (local.set $n (call $mdk_result_len))",
  "        (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $n)))",
  "        (local.set $i (i32.const 0))",
  "        (block $d (loop $l",
  "          (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "          (array.set $arr (local.get $out) (local.get $i) (ref.i31 (call $mdk_result_byte (local.get $i))))",
  "          (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "        (struct.new $C_Ok (i32.const 0) (local.get $out)))",
  "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))",
  "  ;; writeFileBytes : $str path -> $arr bytes -> Result String Unit.  1=Ok () / 0=Err msg.",
  "  ;; Stream each i31 byte (masked to 0..255) to the host, then commit fs.writeFileSync.",
  "  (func $mdk_write_file_bytes_io (param $path (ref $str)) (param $ba (ref $arr)) (result (ref eq))",
  "    (local $st i32) (local $n i32) (local $i i32)",
  "    (call $mdk_push_path (local.get $path))",
  "    (call $mdk_write_file_reset)",
  "    (local.set $n (array.len (local.get $ba)))",
  "    (local.set $i (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (call $mdk_write_file_push (i32.and (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $ba) (local.get $i)))) (i32.const 255)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (local.set $st (call $mdk_write_file_commit))",
  "    (if (result (ref eq)) (local.get $st)",
  "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))",
  "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))",
]

-- ── W8b string index-of / compare ($str-dependent) ───────────────────────────
-- $mdk_str_index_of(needle, hay) -> Option Int (ref eq): the first BYTE-level match's
-- codepoint index as `Some idx`, or `None` if absent (empty needle -> Some 0).  Builds
-- the reserved Option ctors directly: None = `ref.i31 1`, Some = struct.new $C_Some
-- (tag 0 + the i31 index).  ($C_Some / the Option root are emitted unconditionally in
-- ref-mode.)  $mdk_str_compare(a, b) -> Ordering (ref eq): memcmp the common prefix,
-- tie-break by length, return Lt/Eq/Gt (i31 0/1/2).  Both byte-identical to medaka_rt.c
-- (mdk_string_index_of / mdk_string_compare).  Needs $mdk_cp_count from strLeafRuntime.
export strSearchRuntimeLines : List String
strSearchRuntimeLines = [
  "  ;; -- W8b stringIndexOf / stringCompare (byte-identical to medaka_rt.c) --",
  "  (func $mdk_str_index_of (param $needle (ref $str)) (param $hay (ref $str)) (result (ref eq))",
  "    (local $nb (ref $u8arr)) (local $hb (ref $u8arr)) (local $nl i32) (local $hl i32)",
  "    (local $b i32) (local $j i32) (local $ok i32)",
  "    (local.set $nb (struct.get $str $bytes (local.get $needle)))",
  "    (local.set $hb (struct.get $str $bytes (local.get $hay)))",
  "    (local.set $nl (array.len (local.get $nb)))",
  "    (local.set $hl (array.len (local.get $hb)))",
  "    ;; empty needle -> Some 0 (codepoint index 0).",
  "    (if (i32.eqz (local.get $nl))",
  "      (then (return (struct.new $C_Some (i32.const 0) (ref.i31 (i32.const 0))))))",
  "    (local.set $b (i32.const 0))",
  "    (block $done (loop $scan",
  "      ;; while b + nl <= hl",
  "      (br_if $done (i32.gt_s (i32.add (local.get $b) (local.get $nl)) (local.get $hl)))",
  "      (local.set $ok (i32.const 1))",
  "      (local.set $j (i32.const 0))",
  "      (block $cmpd (loop $cmpl",
  "        (br_if $cmpd (i32.ge_s (local.get $j) (local.get $nl)))",
  "        (if (i32.ne (array.get_u $u8arr (local.get $hb) (i32.add (local.get $b) (local.get $j)))",
  "                    (array.get_u $u8arr (local.get $nb) (local.get $j)))",
  "          (then (local.set $ok (i32.const 0)) (br $cmpd)))",
  "        (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $cmpl)))",
  "      (if (local.get $ok)",
  "        (then (return (struct.new $C_Some (i32.const 0)",
  "          (ref.i31 (call $mdk_cp_count (local.get $hb) (local.get $b)))))))",
  "      (local.set $b (i32.add (local.get $b) (i32.const 1))) (br $scan)))",
  "    ;; not found -> None (i31 ordinal 1).",
  "    (ref.i31 (i32.const 1)))",
  "  (func $mdk_str_compare (param $a (ref $str)) (param $b (ref $str)) (result (ref eq))",
  "    (local $ab (ref $u8arr)) (local $bb (ref $u8arr)) (local $al i32) (local $bl i32)",
  "    (local $m i32) (local $i i32) (local $ca i32) (local $cb i32)",
  "    (local.set $ab (struct.get $str $bytes (local.get $a)))",
  "    (local.set $bb (struct.get $str $bytes (local.get $b)))",
  "    (local.set $al (array.len (local.get $ab)))",
  "    (local.set $bl (array.len (local.get $bb)))",
  "    (local.set $m (if (result i32) (i32.lt_s (local.get $al) (local.get $bl))",
  "      (then (local.get $al)) (else (local.get $bl))))",
  "    (local.set $i (i32.const 0))",
  "    (block $done (loop $l",
  "      (br_if $done (i32.ge_s (local.get $i) (local.get $m)))",
  "      (local.set $ca (array.get_u $u8arr (local.get $ab) (local.get $i)))",
  "      (local.set $cb (array.get_u $u8arr (local.get $bb) (local.get $i)))",
  "      ;; byte less -> Lt (i31 0); byte greater -> Gt (i31 2).",
  "      (if (i32.lt_u (local.get $ca) (local.get $cb)) (then (return (ref.i31 (i32.const 0)))))",
  "      (if (i32.gt_u (local.get $ca) (local.get $cb)) (then (return (ref.i31 (i32.const 2)))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    ;; common prefix equal: shorter < longer; equal length -> Eq.",
  "    (if (i32.lt_s (local.get $al) (local.get $bl)) (then (return (ref.i31 (i32.const 0)))))",
  "    (if (i32.gt_s (local.get $al) (local.get $bl)) (then (return (ref.i31 (i32.const 2)))))",
  "    (ref.i31 (i32.const 1)))",
]

-- ── W11b UTF-8 codec: stringToChars / stringFromChars ($str <-> Array Char) ──────
-- Byte-identical to medaka_rt.c (mdk_string_to_chars / mdk_string_from_chars +
-- mdk_utf8_decode / mdk_utf8_encode).  A Char is an i31 codepoint; an `Array Char` is
-- the §3.3 $arr = (array (mut (ref eq))) holding `cp_count` i31s.  Emitted when the
-- program uses stringToChars/stringFromChars (`useStrCodecRef`); needs the $str rep
-- ($u8arr) AND the $arr rep (both forced by noteW8Extern).
--   $mdk_str_to_chars : decode each UTF-8 codepoint (lead byte <0x80 → 1B; <0xE0 → 2B
--     & 0x1F; <0xF0 → 3B & 0x0F; else 4B & 0x07; each continuation byte & 0x3F, shift
--     << 6 and OR), pushing `ref.i31 cp` into a fresh $arr of length cp_count.
--   $mdk_utf8_nbytes : bytes a codepoint encodes to (1..4) — the encoder's pass-1.
--   $mdk_chars_to_str : two-pass — sum encoded byte length, alloc $u8arr, encode each
--     codepoint in place (same lead/continuation masks as $mdk_char_to_str), cp_count
--     = array.len.
export strCodecRuntimeLines : List String
strCodecRuntimeLines = [
  "  ;; -- W11b UTF-8 codec (byte-identical to medaka_rt.c) --",
  "  ;; decode a $str's UTF-8 bytes into a fresh $arr of cp_count i31 Char codepoints.",
  "  (func $mdk_str_to_chars (param $s (ref $str)) (result (ref $arr))",
  "    (local $b (ref $u8arr)) (local $n i32) (local $cpc i32) (local $out (ref $arr))",
  "    (local $bo i32) (local $oi i32) (local $lead i32) (local $cp i32) (local $k i32) (local $w i32)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $cpc (struct.get $str $cp_count (local.get $s)))",
  "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $cpc)))",
  "    (local.set $bo (i32.const 0)) (local.set $oi (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $bo) (local.get $n)))",
  "      (local.set $lead (array.get_u $u8arr (local.get $b) (local.get $bo)))",
  "      ;; lead-byte class → codepoint seed bits + total byte width.",
  "      (if (i32.lt_u (local.get $lead) (i32.const 128))",
  "        (then (local.set $cp (local.get $lead)) (local.set $w (i32.const 1)))",
  "        (else (if (i32.lt_u (local.get $lead) (i32.const 224))",
  "          (then (local.set $cp (i32.and (local.get $lead) (i32.const 31))) (local.set $w (i32.const 2)))",
  "          (else (if (i32.lt_u (local.get $lead) (i32.const 240))",
  "            (then (local.set $cp (i32.and (local.get $lead) (i32.const 15))) (local.set $w (i32.const 3)))",
  "            (else (local.set $cp (i32.and (local.get $lead) (i32.const 7))) (local.set $w (i32.const 4))))))))",
  "      ;; fold in (w-1) continuation bytes: cp = (cp << 6) | (byte & 0x3F).",
  "      (local.set $k (i32.const 1))",
  "      (block $cd (loop $cl",
  "        (br_if $cd (i32.ge_s (local.get $k) (local.get $w)))",
  "        (local.set $cp (i32.or (i32.shl (local.get $cp) (i32.const 6))",
  "          (i32.and (array.get_u $u8arr (local.get $b) (i32.add (local.get $bo) (local.get $k))) (i32.const 63))))",
  "        (local.set $k (i32.add (local.get $k) (i32.const 1))) (br $cl)))",
  "      (array.set $arr (local.get $out) (local.get $oi) (ref.i31 (local.get $cp)))",
  "      (local.set $oi (i32.add (local.get $oi) (i32.const 1)))",
  "      (local.set $bo (i32.add (local.get $bo) (local.get $w))) (br $l)))",
  "    (local.get $out))",
  "  ;; number of UTF-8 bytes a codepoint encodes to (1..4).",
  "  (func $mdk_utf8_nbytes (param $cp i32) (result i32)",
  "    (if (result i32) (i32.lt_u (local.get $cp) (i32.const 128)) (then (i32.const 1))",
  "      (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 2048)) (then (i32.const 2))",
  "        (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 65536)) (then (i32.const 3))",
  "          (else (i32.const 4))))))))",
  "  ;; encode one codepoint into $buf at offset $off; return the next offset.",
  "  (func $mdk_utf8_emit_at (param $buf (ref $u8arr)) (param $off i32) (param $cp i32) (result i32)",
  "    (if (result i32) (i32.lt_u (local.get $cp) (i32.const 128))",
  "      (then",
  "        (array.set $u8arr (local.get $buf) (local.get $off) (local.get $cp))",
  "        (i32.add (local.get $off) (i32.const 1)))",
  "      (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 2048))",
  "        (then",
  "          (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 192) (i32.shr_u (local.get $cp) (i32.const 6))))",
  "          (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))",
  "          (i32.add (local.get $off) (i32.const 2)))",
  "        (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 65536))",
  "          (then",
  "            (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 224) (i32.shr_u (local.get $cp) (i32.const 12))))",
  "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))",
  "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 2)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))",
  "            (i32.add (local.get $off) (i32.const 3)))",
  "          (else",
  "            (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 240) (i32.shr_u (local.get $cp) (i32.const 18))))",
  "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 63))))",
  "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 2)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))",
  "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 3)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))",
  "            (i32.add (local.get $off) (i32.const 4))))))))",
  "  )",
  "  ;; encode an $arr of i31 Char codepoints into a fresh $str (UTF-8); cp_count = len.",
  "  (func $mdk_chars_to_str (param $a (ref $arr)) (result (ref $str))",
  "    (local $n i32) (local $i i32) (local $total i32) (local $off i32)",
  "    (local $buf (ref $u8arr)) (local $cp i32)",
  "    (local.set $n (array.len (local.get $a)))",
  "    ;; pass 1: total encoded byte length.",
  "    (local.set $i (i32.const 0)) (local.set $total (i32.const 0))",
  "    (block $d1 (loop $l1",
  "      (br_if $d1 (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $cp (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))))",
  "      (local.set $total (i32.add (local.get $total) (call $mdk_utf8_nbytes (local.get $cp))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l1)))",
  "    ;; pass 2: encode into the buffer.",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $total)))",
  "    (local.set $i (i32.const 0)) (local.set $off (i32.const 0))",
  "    (block $d2 (loop $l2",
  "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $cp (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))))",
  "      (local.set $off (call $mdk_utf8_emit_at (local.get $buf) (local.get $off) (local.get $cp)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))",
  "    (struct.new $str (local.get $n) (local.get $buf)))",
  "  ;; stringToUtf8Bytes: copy the $str's $u8arr backing into a fresh $arr of i31 Int bytes.",
  "  (func $mdk_str_to_utf8_bytes (param $s (ref $str)) (result (ref $arr))",
  "    (local $b (ref $u8arr)) (local $n i32) (local $out (ref $arr)) (local $i i32)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $n)))",
  "    (local.set $i (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (array.set $arr (local.get $out) (local.get $i) (ref.i31 (array.get_u $u8arr (local.get $b) (local.get $i))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (local.get $out))",
  "  ;; stringFromUtf8Bytes: blit the low 8 bits of each i31 Int into a $u8arr; recompute",
  "  ;; cp_count by the non-continuation-byte rule (byte-identical to medaka_rt.c mdk_str_lit).",
  "  (func $mdk_utf8_bytes_to_str (param $a (ref $arr)) (result (ref $str))",
  "    (local $n i32) (local $buf (ref $u8arr)) (local $i i32) (local $cpc i32) (local $byte i32)",
  "    (local.set $n (array.len (local.get $a)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))",
  "    (local.set $i (i32.const 0)) (local.set $cpc (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $byte (i32.and (i31.get_u (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))) (i32.const 255)))",
  "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $byte))",
  "      (if (i32.ne (i32.and (local.get $byte) (i32.const 192)) (i32.const 128))",
  "        (then (local.set $cpc (i32.add (local.get $cpc) (i32.const 1)))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (struct.new $str (local.get $cpc) (local.get $buf)))",
]

-- ── W11b charFromCode : Int -> Option Char ───────────────────────────────────────
-- Range-check the i32 codepoint (valid = 0..0x10FFFF EXCLUDING surrogates 0xD800..
-- 0xDFFF, byte-identical to medaka_rt.c mdk_char_from_code) → Some <char i31>
-- (struct.new $C_Some ordinal 0 + the i31 codepoint) / None (i31 ordinal 1).  The
-- reserved Option ctors ($C_Some / the Option root) are emitted unconditionally in
-- ref-mode.  Gated independently (`useCharFromCodeRef`) — needs no $str/$arr.
export charFromCodeRuntimeLines : List String
charFromCodeRuntimeLines = [
  "  ;; -- W11b charFromCode (byte-identical to medaka_rt.c mdk_char_from_code) --",
  "  (func $mdk_char_from_code (param $cp i32) (result (ref eq))",
  "    ;; valid: 0 <= cp <= 0x10FFFF and not (0xD800 <= cp <= 0xDFFF).",
  "    (if (i32.and (i32.and (i32.ge_s (local.get $cp) (i32.const 0)) (i32.le_s (local.get $cp) (i32.const 1114111)))",
  "                 (i32.eqz (i32.and (i32.ge_s (local.get $cp) (i32.const 55296)) (i32.le_s (local.get $cp) (i32.const 57343)))))",
  "      (then (return (struct.new $C_Some (i32.const 0) (ref.i31 (local.get $cp))))))",
  "    (ref.i31 (i32.const 1)))",
]
# DESUGAR
(DTypeSig true "preambleHeadLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "preambleHeadLines" () (EListLit (ELit (LString ";; Medaka WasmGC backend (Stage 2.4c) — emitted WAT.")) (ELit (LString ";; Value rep: WASMGC-DESIGN.md §3 / §8.6.  W2 = scalar i32; W3 = (ref eq) + i31/structs.")) (ELit (LString "(module"))))
(DTypeSig true "importLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "importLines" () (EListLit (ELit (LString "  ;; ── §6 host-import IO seam (§10 fork e — custom import) ──")) (ELit (LString "  (import \"env\" \"mdk_write_int\" (func $mdk_write_int (param i32)))")) (ELit (LString "  (import \"env\" \"mdk_write_bool\" (func $mdk_write_bool (param i32)))"))))
(DTypeSig true "closTypeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "closTypeLines" () (EListLit (ELit (LString "    ;; ── §4 closure ABI (arity-in-struct, uniform code sig) ──")) (ELit (LString "    (type $argarr (array (mut (ref null eq))))")) (ELit (LString "    (type $codety (func (param (ref eq)) (param (ref $argarr)) (result (ref eq))))")) (ELit (LString "    (type $clos (sub (struct (field $code (ref $codety)) (field $arity i32) (field $env (ref $argarr)))))"))))
(DTypeSig true "closApplyLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "closApplyLines" () (EListLit (ELit (LString "  ;; ── §4 universal apply runtime (exact / under-PAP / over-saturate) ──")) (ELit (LString "  (func $mdk_pap (type $codety) (param $self (ref eq)) (param $args (ref $argarr)) (result (ref eq))")) (ELit (LString "    (local $c (ref $clos)) (local $env (ref $argarr)) (local $orig (ref eq))")) (ELit (LString "    (local $ne i32) (local $na i32) (local $total (ref $argarr)) (local $i i32)")) (ELit (LString "    (local.set $c (ref.cast (ref $clos) (local.get $self)))")) (ELit (LString "    (local.set $env (struct.get $clos $env (local.get $c)))")) (ELit (LString "    (local.set $orig (ref.as_non_null (array.get $argarr (local.get $env) (i32.const 0))))")) (ELit (LString "    (local.set $ne (i32.sub (array.len (local.get $env)) (i32.const 1)))")) (ELit (LString "    (local.set $na (array.len (local.get $args)))")) (ELit (LString "    (local.set $total (array.new $argarr (ref.null eq) (i32.add (local.get $ne) (local.get $na))))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $pd (loop $pl")) (ELit (LString "      (br_if $pd (i32.ge_s (local.get $i) (local.get $ne)))")) (ELit (LString "      (array.set $argarr (local.get $total) (local.get $i)")) (ELit (LString "        (array.get $argarr (local.get $env) (i32.add (local.get $i) (i32.const 1))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $pl)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $pd2 (loop $pl2")) (ELit (LString "      (br_if $pd2 (i32.ge_s (local.get $i) (local.get $na)))")) (ELit (LString "      (array.set $argarr (local.get $total) (i32.add (local.get $ne) (local.get $i))")) (ELit (LString "        (array.get $argarr (local.get $args) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $pl2)))")) (ELit (LString "    (return_call $__mdk_apply (local.get $orig) (local.get $total)))")) (ELit (LString "  (func $__mdk_apply (param $f (ref eq)) (param $args (ref $argarr)) (result (ref eq))")) (ELit (LString "    (local $c (ref $clos)) (local $ar i32) (local $na i32)")) (ELit (LString "    (local $sat (ref $argarr)) (local $surplus (ref $argarr)) (local $i i32) (local $r (ref eq))")) (ELit (LString "    (local $penv (ref $argarr))")) (ELit (LString "    (local.set $c (ref.cast (ref $clos) (local.get $f)))")) (ELit (LString "    (local.set $ar (struct.get $clos $arity (local.get $c)))")) (ELit (LString "    (local.set $na (array.len (local.get $args)))")) (ELit (LString "    (if (result (ref eq)) (i32.eq (local.get $na) (local.get $ar))")) (ELit (LString "      (then (return_call_ref $codety (local.get $f) (local.get $args) (struct.get $clos $code (local.get $c))))")) (ELit (LString "      (else")) (ELit (LString "        (if (result (ref eq)) (i32.lt_s (local.get $na) (local.get $ar))")) (ELit (LString "          (then")) (ELit (LString "            (local.set $penv (array.new $argarr (ref.null eq) (i32.add (local.get $na) (i32.const 1))))")) (ELit (LString "            (array.set $argarr (local.get $penv) (i32.const 0) (local.get $f))")) (ELit (LString "            (local.set $i (i32.const 0))")) (ELit (LString "            (block $ud (loop $ul")) (ELit (LString "              (br_if $ud (i32.ge_s (local.get $i) (local.get $na)))")) (ELit (LString "              (array.set $argarr (local.get $penv) (i32.add (local.get $i) (i32.const 1))")) (ELit (LString "                (array.get $argarr (local.get $args) (local.get $i)))")) (ELit (LString "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $ul)))")) (ELit (LString "            (struct.new $clos (ref.func $mdk_pap) (i32.sub (local.get $ar) (local.get $na)) (local.get $penv)))")) (ELit (LString "          (else")) (ELit (LString "            (local.set $sat (array.new $argarr (ref.null eq) (local.get $ar)))")) (ELit (LString "            (local.set $i (i32.const 0))")) (ELit (LString "            (block $sd (loop $sl")) (ELit (LString "              (br_if $sd (i32.ge_s (local.get $i) (local.get $ar)))")) (ELit (LString "              (array.set $argarr (local.get $sat) (local.get $i)")) (ELit (LString "                (array.get $argarr (local.get $args) (local.get $i)))")) (ELit (LString "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $sl)))")) (ELit (LString "            (local.set $r (call_ref $codety (local.get $f) (local.get $sat) (struct.get $clos $code (local.get $c))))")) (ELit (LString "            (local.set $surplus (array.new $argarr (ref.null eq) (i32.sub (local.get $na) (local.get $ar))))")) (ELit (LString "            (local.set $i (i32.const 0))")) (ELit (LString "            (block $od (loop $ol")) (ELit (LString "              (br_if $od (i32.ge_s (local.get $i) (i32.sub (local.get $na) (local.get $ar))))")) (ELit (LString "              (array.set $argarr (local.get $surplus) (local.get $i)")) (ELit (LString "                (array.get $argarr (local.get $args) (i32.add (local.get $i) (local.get $ar))))")) (ELit (LString "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $ol)))")) (ELit (LString "            (return_call $__mdk_apply (local.get $r) (local.get $surplus)))))))"))))
(DTypeSig true "preambleScalarLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "preambleScalarLines" () (EBinOp "++" (EBinOp "++" (EVar "preambleHeadLines") (EListLit (ELit (LString "  ;; ── §3 type section (one rec group, iso-recursive / nominal-modulo-canon) ──")) (ELit (LString "  ;; This program uses no ADTs — the scalar subset computes in raw i32 and only")) (ELit (LString "  ;; the print boundary is reached; the unitype scaffolding is declared unused.")) (ELit (LString "  (rec")) (ELit (LString "    ;; boxed Int outside the i31 range (§3.2) — declared, unused.")) (ELit (LString "    (type $boxint (sub (struct (field i64))))")) (ELit (LString "    ;; boxed Float (§3.3) — declared, unused until a Float fixture needs it.")) (ELit (LString "    (type $float (sub (struct (field f64))))")) (ELit (LString "  )")))) (EVar "importLines")))
(DTypeSig true "ioByteImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioByteImportLines" () (EListLit (ELit (LString "  ;; ── §6 host-import IO seam (§10 fork e — byte-level custom import) ──")) (ELit (LString "  (import \"env\" \"mdk_write_byte\" (func $mdk_write_byte (param i32)))"))))
(DTypeSig true "strTypeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strTypeLines" () (EListLit (ELit (LString "    ;; ── §3.3 String aggregate (UTF-8 bytes + cached codepoint count) ──")) (ELit (LString "    (type $u8arr (array (mut i8)))")) (ELit (LString "    (type $str (sub (struct (field $cp_count i32) (field $bytes (ref $u8arr)))))"))))
(DTypeSig true "ioRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioRuntimeLines" () (EListLit (ELit (LString "  ;; ── §2.1 Int representation seam: i31 fast path / $boxint i64 box ──")) (ELit (LString "  ;; layer-17 SOUNDNESS: Ints in [-2^30, 2^30) are i31ref immediates; outside that")) (ELit (LString "  ;; range they box into (struct (field i64)) ($boxint).  ALL Int arithmetic unboxes")) (ELit (LString "  ;; both operands to i64 via $mdk_unbox_int, computes in i64, and re-boxes via")) (ELit (LString "  ;; $mdk_box_int — so >2^30 values no longer truncate to 31 bits.")) (ELit (LString "  (func $mdk_unbox_int (param $v (ref eq)) (result i64)")) (ELit (LString "    (if (result i64) (ref.test (ref i31) (local.get $v))")) (ELit (LString "      (then (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $v)))))")) (ELit (LString "      (else (struct.get $boxint 0 (ref.cast (ref $boxint) (local.get $v))))))")) (ELit (LString "  ;; box an i64 Int: in [-2^30, 2^30) -> i31 immediate; else -> $boxint struct.")) (ELit (LString "  (func $mdk_box_int (param $n i64) (result (ref eq))")) (ELit (LString "    (if (result (ref eq))")) (ELit (LString "        (i32.and (i64.ge_s (local.get $n) (i64.const -1073741824))")) (ELit (LString "                 (i64.lt_s (local.get $n) (i64.const 1073741824)))")) (ELit (LString "      (then (ref.i31 (i32.wrap_i64 (local.get $n))))")) (ELit (LString "      (else (struct.new $boxint (local.get $n)))))")) (ELit (LString "  ;; ── §6 byte-write print runtime (decimal int / bool text) ──")) (ELit (LString "  ;; write the decimal digits of a NON-NEGATIVE i64 (most-significant first).")) (ELit (LString "  (func $mdk_write_digits (param $n i64)")) (ELit (LString "    (if (i64.ge_s (local.get $n) (i64.const 10))")) (ELit (LString "      (then (call $mdk_write_digits (i64.div_s (local.get $n) (i64.const 10)))))")) (ELit (LString "    (call $mdk_write_byte")) (ELit (LString "      (i32.add (i32.const 48)")) (ELit (LString "        (i32.wrap_i64 (i64.rem_s (local.get $n) (i64.const 10))))))")) (ELit (LString "  ;; render an i64 in decimal to stdout + a trailing newline (value-main Int).")) (ELit (LString "  (func $mdk_print_int (param $n i64)")) (ELit (LString "    (if (i64.lt_s (local.get $n) (i64.const 0))")) (ELit (LString "      (then")) (ELit (LString "        (call $mdk_write_byte (i32.const 45))")) (ELit (LString "        (call $mdk_write_digits (i64.sub (i64.const 0) (local.get $n))))")) (ELit (LString "      (else (call $mdk_write_digits (local.get $n))))")) (ELit (LString "    (call $mdk_write_byte (i32.const 10)))")) (ELit (LString "  (func $mdk_print_bool (param $b i32)")) (ELit (LString "    (if (local.get $b)")) (ELit (LString "      (then")) (ELit (LString "        (call $mdk_write_byte (i32.const 84)) (call $mdk_write_byte (i32.const 114))")) (ELit (LString "        (call $mdk_write_byte (i32.const 117)) (call $mdk_write_byte (i32.const 101)))")) (ELit (LString "      (else")) (ELit (LString "        (call $mdk_write_byte (i32.const 70)) (call $mdk_write_byte (i32.const 97))")) (ELit (LString "        (call $mdk_write_byte (i32.const 108)) (call $mdk_write_byte (i32.const 115))")) (ELit (LString "        (call $mdk_write_byte (i32.const 101))))")) (ELit (LString "    (call $mdk_write_byte (i32.const 10)))"))))
(DTypeSig true "ioStrRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioStrRuntimeLines" () (EListLit (ELit (LString "  ;; ── §6 string byte-write runtime ($str-dependent) ──")) (ELit (LString "  (func $mdk_print_str (param $s (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_byte (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))))")) (ELit (LString "  (func $mdk_print_strln (param $s (ref $str))")) (ELit (LString "    (call $mdk_print_str (local.get $s))")) (ELit (LString "    (call $mdk_write_byte (i32.const 10)))")) (ELit (LString "  ;; intToString : render an i64 in decimal into a fresh $str (cp_count == byte len).")) (ELit (LString "  (func $mdk_int_to_str (param $n i64) (result (ref $str))")) (ELit (LString "    (local $neg i32) (local $m i64) (local $len i32) (local $i i32)")) (ELit (LString "    (local $buf (ref $u8arr)) (local $d i32)")) (ELit (LString "    (local.set $neg (i64.lt_s (local.get $n) (i64.const 0)))")) (ELit (LString "    (local.set $m (if (result i64) (local.get $neg)")) (ELit (LString "      (then (i64.sub (i64.const 0) (local.get $n))) (else (local.get $n))))")) (ELit (LString "    ;; count digits")) (ELit (LString "    (local.set $len (i32.const 1))")) (ELit (LString "    (block $cd (loop $cl")) (ELit (LString "      (br_if $cd (i64.lt_s (local.get $m) (i64.const 10)))")) (ELit (LString "      (local.set $len (i32.add (local.get $len) (i32.const 1)))")) (ELit (LString "      (local.set $m (i64.div_s (local.get $m) (i64.const 10)))")) (ELit (LString "      (br $cl)))")) (ELit (LString "    (local.set $m (if (result i64) (local.get $neg)")) (ELit (LString "      (then (i64.sub (i64.const 0) (local.get $n))) (else (local.get $n))))")) (ELit (LString "    (if (local.get $neg) (then (local.set $len (i32.add (local.get $len) (i32.const 1)))))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $len)))")) (ELit (LString "    ;; fill digits from least-significant (end) backward")) (ELit (LString "    (local.set $i (i32.sub (local.get $len) (i32.const 1)))")) (ELit (LString "    (block $fd (loop $fl")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i)")) (ELit (LString "        (i32.add (i32.const 48) (i32.wrap_i64 (i64.rem_s (local.get $m) (i64.const 10)))))")) (ELit (LString "      (local.set $m (i64.div_s (local.get $m) (i64.const 10)))")) (ELit (LString "      (local.set $i (i32.sub (local.get $i) (i32.const 1)))")) (ELit (LString "      (br_if $fd (i64.eq (local.get $m) (i64.const 0)))")) (ELit (LString "      (br $fl)))")) (ELit (LString "    (if (local.get $neg) (then (array.set $u8arr (local.get $buf) (i32.const 0) (i32.const 45))))")) (ELit (LString "    (struct.new $str (local.get $len) (local.get $buf)))"))))
(DTypeSig true "stderrByteImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "stderrByteImportLines" () (EListLit (ELit (LString "  (import \"env\" \"mdk_write_err_byte\" (func $mdk_write_err_byte (param i32)))"))))
(DTypeSig true "stderrRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "stderrRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 stderr byte-write runtime (ePutStr / ePutStrLn) ──")) (ELit (LString "  (func $mdk_eprint_str (param $s (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_err_byte (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))))")) (ELit (LString "  (func $mdk_eprint_strln (param $s (ref $str))")) (ELit (LString "    (call $mdk_eprint_str (local.get $s))")) (ELit (LString "    (call $mdk_write_err_byte (i32.const 10)))"))))
(DTypeSig true "strLeafRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strLeafRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 string LEAF ops (byte-identical to medaka_rt.c) ──")) (ELit (LString "  ;; count UTF-8 codepoints in a $u8arr over [0,n): every non-continuation byte.")) (ELit (LString "  (func $mdk_cp_count (param $b (ref $u8arr)) (param $n i32) (result i32)")) (ELit (LString "    (local $i i32) (local $c i32) (local $byte i32)")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $c (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $byte (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      ;; a continuation byte has top bits 10xxxxxx, i.e. (byte & 0xC0) == 0x80.")) (ELit (LString "      (if (i32.ne (i32.and (local.get $byte) (i32.const 192)) (i32.const 128))")) (ELit (LString "        (then (local.set $c (i32.add (local.get $c) (i32.const 1)))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $c))")) (ELit (LString "  ;; codepoint index `cpi` -> byte offset into a $u8arr of byte length `n`.")) (ELit (LString "  (func $mdk_byte_off (param $b (ref $u8arr)) (param $n i32) (param $cpi i32) (result i32)")) (ELit (LString "    (local $bo i32) (local $c i32)")) (ELit (LString "    (local.set $bo (i32.const 0)) (local.set $c (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $bo) (local.get $n)))")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $c) (local.get $cpi)))")) (ELit (LString "      (local.set $bo (i32.add (local.get $bo) (i32.const 1)))")) (ELit (LString "      (block $sd (loop $sl")) (ELit (LString "        (br_if $sd (i32.ge_s (local.get $bo) (local.get $n)))")) (ELit (LString "        (br_if $sd (i32.ne (i32.and (array.get_u $u8arr (local.get $b) (local.get $bo)) (i32.const 192)) (i32.const 128)))")) (ELit (LString "        (local.set $bo (i32.add (local.get $bo) (i32.const 1))) (br $sl)))")) (ELit (LString "      (local.set $c (i32.add (local.get $c) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $bo))")) (ELit (LString "  ;; binary string concat (`++`).  cp_count(a++b) == cp_count(a)+cp_count(b).")) (ELit (LString "  (func $mdk_str_append (param $a (ref $str)) (param $b (ref $str)) (result (ref $str))")) (ELit (LString "    (local $ab (ref $u8arr)) (local $bb (ref $u8arr)) (local $al i32) (local $bl i32)")) (ELit (LString "    (local $buf (ref $u8arr)) (local $cpc i32)")) (ELit (LString "    (local.set $ab (struct.get $str $bytes (local.get $a)))")) (ELit (LString "    (local.set $bb (struct.get $str $bytes (local.get $b)))")) (ELit (LString "    (local.set $al (array.len (local.get $ab)))")) (ELit (LString "    (local.set $bl (array.len (local.get $bb)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (i32.add (local.get $al) (local.get $bl))))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $buf) (i32.const 0) (local.get $ab) (i32.const 0) (local.get $al))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $buf) (local.get $al) (local.get $bb) (i32.const 0) (local.get $bl))")) (ELit (LString "    (local.set $cpc (i32.add (struct.get $str $cp_count (local.get $a)) (struct.get $str $cp_count (local.get $b))))")) (ELit (LString "    (struct.new $str (local.get $cpc) (local.get $buf)))")) (ELit (LString "  ;; encode one Unicode codepoint to a fresh $str (1..4 UTF-8 bytes, cp_count 1).")) (ELit (LString "  (func $mdk_char_to_str (param $cp i32) (result (ref $str))")) (ELit (LString "    (local $buf (ref $u8arr))")) (ELit (LString "    (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 128))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 1)))")) (ELit (LString "        (array.set $u8arr (local.get $buf) (i32.const 0) (local.get $cp))")) (ELit (LString "        (struct.new $str (i32.const 1) (local.get $buf)))")) (ELit (LString "      (else (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 2048))")) (ELit (LString "        (then")) (ELit (LString "          (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 2)))")) (ELit (LString "          (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 192) (i32.shr_u (local.get $cp) (i32.const 6))))")) (ELit (LString "          (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "          (struct.new $str (i32.const 1) (local.get $buf)))")) (ELit (LString "        (else (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 65536))")) (ELit (LString "          (then")) (ELit (LString "            (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 3)))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 224) (i32.shr_u (local.get $cp) (i32.const 12))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 2) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "            (struct.new $str (i32.const 1) (local.get $buf)))")) (ELit (LString "          (else")) (ELit (LString "            (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 4)))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 240) (i32.shr_u (local.get $cp) (i32.const 18))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 2) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 3) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "            (struct.new $str (i32.const 1) (local.get $buf)))")) (ELit (LString "          )")) (ELit (LString "        )")) (ELit (LString "      )")) (ELit (LString "    )")) (ELit (LString "  ))")) (ELit (LString "  ;; codepoint-indexed [lo,hi) slice, clamped to [0,cp_count].")) (ELit (LString "  (func $mdk_str_slice (param $lo i32) (param $hi i32) (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $cpc i32) (local $blo i32) (local $bhi i32)")) (ELit (LString "    (local $len i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $cpc (struct.get $str $cp_count (local.get $s)))")) (ELit (LString "    (if (i32.lt_s (local.get $lo) (i32.const 0)) (then (local.set $lo (i32.const 0)))")) (ELit (LString "      (else (if (i32.gt_s (local.get $lo) (local.get $cpc)) (then (local.set $lo (local.get $cpc))))))")) (ELit (LString "    (if (i32.lt_s (local.get $hi) (local.get $lo)) (then (local.set $hi (local.get $lo)))")) (ELit (LString "      (else (if (i32.gt_s (local.get $hi) (local.get $cpc)) (then (local.set $hi (local.get $cpc))))))")) (ELit (LString "    (local.set $blo (call $mdk_byte_off (local.get $b) (local.get $n) (local.get $lo)))")) (ELit (LString "    (local.set $bhi (call $mdk_byte_off (local.get $b) (local.get $n) (local.get $hi)))")) (ELit (LString "    (local.set $len (i32.sub (local.get $bhi) (local.get $blo)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $len)))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $buf) (i32.const 0) (local.get $b) (local.get $blo) (local.get $len))")) (ELit (LString "    (struct.new $str (i32.sub (local.get $hi) (local.get $lo)) (local.get $buf)))")) (ELit (LString "  ;; ASCII upper/lower over BYTES (non-ASCII bytes pass through unchanged).")) (ELit (LString "  (func $mdk_str_upper (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $buf (ref $u8arr)) (local $i i32) (local $c i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (if (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))")) (ELit (LString "        (then (local.set $c (i32.sub (local.get $c) (i32.const 32)))))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $c))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (struct.get $str $cp_count (local.get $s)) (local.get $buf)))")) (ELit (LString "  (func $mdk_str_lower (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $buf (ref $u8arr)) (local $i i32) (local $c i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (if (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))")) (ELit (LString "        (then (local.set $c (i32.add (local.get $c) (i32.const 32)))))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $c))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (struct.get $str $cp_count (local.get $s)) (local.get $buf)))")) (ELit (LString "  ;; ── W9 debug-literal quoting (byte-identical to lib/eval.ml escape_string_lit) ──")) (ELit (LString "  ;; Map ONE source byte to its escaped form, appending into $buf at $bo; returns the")) (ELit (LString "  ;; next write offset.  Specials: \" / ' (whichever == $q) / \\ / \\n / \\t / \\r / NUL.")) (ELit (LString "  ;; All escapes are <backslash><ascii>, so 2 bytes; everything else copies verbatim.")) (ELit (LString "  (func $mdk_dbg_esc_byte (param $buf (ref $u8arr)) (param $bo i32) (param $c i32) (param $q i32) (result i32)")) (ELit (LString "    (local $r i32)")) (ELit (LString "    ;; $r = the char AFTER the backslash for an escaped byte, else -1 (copy verbatim).")) (ELit (LString "    (local.set $r (i32.const -1))")) (ELit (LString "    (if (i32.eq (local.get $c) (local.get $q)) (then (local.set $r (local.get $q))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 92)) (then (local.set $r (i32.const 92))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 10)) (then (local.set $r (i32.const 110))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 9))  (then (local.set $r (i32.const 116))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 13)) (then (local.set $r (i32.const 114))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 0))  (then (local.set $r (i32.const 48))))")) (ELit (LString "    (if (result i32) (i32.eq (local.get $r) (i32.const -1))")) (ELit (LString "      (then")) (ELit (LString "        (array.set $u8arr (local.get $buf) (local.get $bo) (local.get $c))")) (ELit (LString "        (i32.add (local.get $bo) (i32.const 1)))")) (ELit (LString "      (else")) (ELit (LString "        (array.set $u8arr (local.get $buf) (local.get $bo) (i32.const 92))")) (ELit (LString "        (array.set $u8arr (local.get $buf) (i32.add (local.get $bo) (i32.const 1)) (local.get $r))")) (ELit (LString "        (i32.add (local.get $bo) (i32.const 2)))))")) (ELit (LString "  ;; Quote+escape a $str with quote byte $q ('\"' for String, ''' for Char).  Two-pass:")) (ELit (LString "  ;; count escaped output bytes, alloc exact, fill; cp_count via $mdk_cp_count.")) (ELit (LString "  (func $mdk_dbg_quote (param $s (ref $str)) (param $q i32) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $i i32) (local $c i32)")) (ELit (LString "    (local $out i32) (local $buf (ref $u8arr)) (local $bo i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    ;; pass 1: total output bytes = 2 quotes + per-byte (2 if escaped else 1).")) (ELit (LString "    (local.set $out (i32.const 2)) (local.set $i (i32.const 0))")) (ELit (LString "    (block $d1 (loop $l1")) (ELit (LString "      (br_if $d1 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (if (i32.or (i32.or (i32.or (i32.eq (local.get $c) (local.get $q)) (i32.eq (local.get $c) (i32.const 92)))")) (ELit (LString "                          (i32.or (i32.eq (local.get $c) (i32.const 10)) (i32.eq (local.get $c) (i32.const 9))))")) (ELit (LString "                  (i32.or (i32.eq (local.get $c) (i32.const 13)) (i32.eq (local.get $c) (i32.const 0))))")) (ELit (LString "        (then (local.set $out (i32.add (local.get $out) (i32.const 2))))")) (ELit (LString "        (else (local.set $out (i32.add (local.get $out) (i32.const 1)))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l1)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $out)))")) (ELit (LString "    ;; pass 2: opening quote, escaped bytes, closing quote.")) (ELit (LString "    (array.set $u8arr (local.get $buf) (i32.const 0) (local.get $q))")) (ELit (LString "    (local.set $bo (i32.const 1)) (local.set $i (i32.const 0))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $bo (call $mdk_dbg_esc_byte (local.get $buf) (local.get $bo) (local.get $c) (local.get $q)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))")) (ELit (LString "    (array.set $u8arr (local.get $buf) (local.get $bo) (local.get $q))")) (ELit (LString "    (struct.new $str (call $mdk_cp_count (local.get $buf) (local.get $out)) (local.get $buf)))")) (ELit (LString "  ;; debugStringLit : $str -> $str, surround with double-quotes (q = 34).")) (ELit (LString "  (func $mdk_debug_string_lit (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (call $mdk_dbg_quote (local.get $s) (i32.const 34)))")) (ELit (LString "  ;; debugCharLit : Char (i31 codepoint) -> $str, surround with single-quotes (q = 39).")) (ELit (LString "  (func $mdk_debug_char_lit (param $cp i32) (result (ref $str))")) (ELit (LString "    (call $mdk_dbg_quote (call $mdk_char_to_str (local.get $cp)) (i32.const 39)))"))))
(DTypeSig true "strConcatRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strConcatRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 stringConcat (List String) — walk the W7 cons list ──")) (ELit (LString "  (func $mdk_str_concat (param $list (ref eq)) (result (ref $str))")) (ELit (LString "    (local $w (ref eq)) (local $cell (ref $C_Cons)) (local $s (ref $str))")) (ELit (LString "    (local $total i32) (local $cpc i32) (local $off i32) (local $bl i32)")) (ELit (LString "    (local $buf (ref $u8arr)) (local $sb (ref $u8arr))")) (ELit (LString "    ;; pass 1: total byte length + total codepoints.")) (ELit (LString "    (local.set $total (i32.const 0)) (local.set $cpc (i32.const 0))")) (ELit (LString "    (local.set $w (local.get $list))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))")) (ELit (LString "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))")) (ELit (LString "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))")) (ELit (LString "      (local.set $total (i32.add (local.get $total) (array.len (struct.get $str $bytes (local.get $s)))))")) (ELit (LString "      (local.set $cpc (i32.add (local.get $cpc) (struct.get $str $cp_count (local.get $s))))")) (ELit (LString "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l)))")) (ELit (LString "    ;; pass 2: copy each segment's bytes into a flat buffer.")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $total)))")) (ELit (LString "    (local.set $off (i32.const 0))")) (ELit (LString "    (local.set $w (local.get $list))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))")) (ELit (LString "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))")) (ELit (LString "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))")) (ELit (LString "      (local.set $sb (struct.get $str $bytes (local.get $s)))")) (ELit (LString "      (local.set $bl (array.len (local.get $sb)))")) (ELit (LString "      (array.copy $u8arr $u8arr (local.get $buf) (local.get $off) (local.get $sb) (i32.const 0) (local.get $bl))")) (ELit (LString "      (local.set $off (i32.add (local.get $off) (local.get $bl)))")) (ELit (LString "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l2)))")) (ELit (LString "    (struct.new $str (local.get $cpc) (local.get $buf)))"))))
(DTypeSig true "appendRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "appendRuntimeLines" () (EListLit (ELit (LString "  ;; ── W13 runtime-dispatched `++` (String concat OR List append) ──")) (ELit (LString "  ;; List append is ITERATIVE (destination-passing over the mut $C_Cons tail),")) (ELit (LString "  ;; mirroring the native mdk_list_append: walk `a` head-first, struct.new each")) (ELit (LString "  ;; result cell with a placeholder i31 tail, struct.set it into the previous")) (ELit (LString "  ;; cell's mut tail, and after the loop point the final tail at `b`.  O(1) extra")) (ELit (LString "  ;; space, no self-recursion → no wasm-stack growth proportional to length(a).")) (ELit (LString "  (func $mdk_append (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (local $cell (ref $C_Cons))")) (ELit (LString "    (local $result (ref eq))")) (ELit (LString "    (local $dest (ref $C_Cons))")) (ELit (LString "    (local $new (ref $C_Cons))")) (ELit (LString "    ;; String `++`: left is a $str struct → byte concat.")) (ELit (LString "    (if (ref.test (ref $str) (local.get $a))")) (ELit (LString "      (then (return (call $mdk_str_append (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b))))))")) (ELit (LString "    ;; List `++`: a Nil (non-$C_Cons) left → b unchanged.")) (ELit (LString "    (if (i32.eqz (ref.test (ref $C_Cons) (local.get $a)))")) (ELit (LString "      (then (return (local.get $b))))")) (ELit (LString "    ;; First cell: copy head(a), placeholder i31 tail (overwritten before any read).")) (ELit (LString "    (local.set $cell (ref.cast (ref $C_Cons) (local.get $a)))")) (ELit (LString "    (local.set $dest (struct.new $C_Cons (i32.const 0)")) (ELit (LString "      (struct.get $C_Cons 1 (local.get $cell)) (ref.i31 (i32.const 0))))")) (ELit (LString "    (local.set $result (local.get $dest))")) (ELit (LString "    ;; Walk the rest of `a`, appending a fresh cell into the previous mut tail.")) (ELit (LString "    (block $done")) (ELit (LString "      (loop $l")) (ELit (LString "        ;; If tail(cell) is not a Cons (i.e. Nil), we are done.")) (ELit (LString "        (br_if $done (i32.eqz (ref.test (ref $C_Cons)")) (ELit (LString "          (struct.get $C_Cons 2 (local.get $cell)))))")) (ELit (LString "        (local.set $cell (ref.cast (ref $C_Cons)")) (ELit (LString "          (struct.get $C_Cons 2 (local.get $cell))))")) (ELit (LString "        (local.set $new (struct.new $C_Cons (i32.const 0)")) (ELit (LString "          (struct.get $C_Cons 1 (local.get $cell)) (ref.i31 (i32.const 0))))")) (ELit (LString "        (struct.set $C_Cons 2 (local.get $dest) (local.get $new))")) (ELit (LString "        (local.set $dest (local.get $new))")) (ELit (LString "        (br $l)))")) (ELit (LString "    ;; Final tail → b (sharing it, not copying).")) (ELit (LString "    (struct.set $C_Cons 2 (local.get $dest) (local.get $b))")) (ELit (LString "    (local.get $result))"))))
(DTypeSig true "valueEqRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "valueEqRuntimeLines" () (EListLit (ELit (LString "  ;; -- layer-9 runtime-shape-dispatched `==`/`!=` (String byte-equal OR immediate identity) --")) (ELit (LString "  (func $mdk_value_eq (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    ;; both operands are $str structs -> byte equality.")) (ELit (LString "    (if (i32.and (ref.test (ref $str) (local.get $a)) (ref.test (ref $str) (local.get $b)))")) (ELit (LString "      (then (return (ref.i31 (i32.eq")) (ELit (LString "        (i32.const 1)")) (ELit (LString "        (i31.get_u (ref.cast (ref i31) (call $mdk_str_compare (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b)))))))))) ;; Eq == ordinal 1")) (ELit (LString "    ;; A2 (poly-Eq-on-Float): two boxed $float cells have distinct identities, so the")) (ELit (LString "    ;; `ref.eq` fallback would report equal floats as unequal — compare f64 values.")) (ELit (LString "    (if (i32.and (ref.test (ref $float) (local.get $a)) (ref.test (ref $float) (local.get $b)))")) (ELit (LString "      (then (return (ref.i31 (f64.eq")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    ;; otherwise immediate/struct identity (i31 Int/Bool/Char/Unit, or ctor cells).")) (ELit (LString "    ;; layer-17 §2.1: a >2^30 Int is a $boxint struct, so two equal large Ints have")) (ELit (LString "    ;; distinct identities — when either side is a $boxint compare the unboxed i64.")) (ELit (LString "    (if (i32.or (ref.test (ref $boxint) (local.get $a)) (ref.test (ref $boxint) (local.get $b)))")) (ELit (LString "      (then (return (ref.i31 (i64.eq (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))")) (ELit (LString "    (ref.i31 (i32.eqz (i32.eqz (ref.eq (local.get $a) (local.get $b))))))")) (ELit (LString "  ;; -- layer-9 runtime-shape-dispatched ordering (String byte-order OR i31 signed) -> i32 -1/0/1 --")) (ELit (LString "  (func $mdk_value_cmp (param $a (ref eq)) (param $b (ref eq)) (result i32)")) (ELit (LString "    (local $o i32) (local $ia i64) (local $ib i64) (local $fa f64) (local $fb f64)")) (ELit (LString "    (if (i32.and (ref.test (ref $str) (local.get $a)) (ref.test (ref $str) (local.get $b)))")) (ELit (LString "      (then")) (ELit (LString "        ;; $mdk_str_compare -> Ordering i31 (Lt 0 / Eq 1 / Gt 2); map to -1/0/1.")) (ELit (LString "        (local.set $o (i31.get_u (ref.cast (ref i31) (call $mdk_str_compare (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b))))))")) (ELit (LString "        (return (i32.sub (local.get $o) (i32.const 1)))))")) (ELit (LString "    ;; A2 (poly-Ord-on-Float): a boxed $float operand -> f64 compare -> -1/0/1.")) (ELit (LString "    ;; Mirrors the arith helpers' left-operand $float discriminant.  A poly `Ord`")) (ELit (LString "    ;; compare (`a > b` on a Num/Ord type-var param) reaches here with $float cells;")) (ELit (LString "    ;; without this arm $mdk_unbox_int would ref.cast the $float to $boxint -> trap.")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $fa (struct.get $float 0 (ref.cast (ref $float) (local.get $a))))")) (ELit (LString "        (local.set $fb (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))")) (ELit (LString "        (if (f64.lt (local.get $fa) (local.get $fb)) (then (return (i32.const -1))))")) (ELit (LString "        (if (f64.gt (local.get $fa) (local.get $fb)) (then (return (i32.const 1))))")) (ELit (LString "        (return (i32.const 0))))")) (ELit (LString "    ;; layer-17 §2.1: Int compare over the i64 box/unbox seam (handles >2^30 boxed).")) (ELit (LString "    (local.set $ia (call $mdk_unbox_int (local.get $a)))")) (ELit (LString "    (local.set $ib (call $mdk_unbox_int (local.get $b)))")) (ELit (LString "    (if (i64.lt_s (local.get $ia) (local.get $ib)) (then (return (i32.const -1))))")) (ELit (LString "    (if (i64.gt_s (local.get $ia) (local.get $ib)) (then (return (i32.const 1))))")) (ELit (LString "    (i32.const 0))"))))
(DTypeSig true "valueArithRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "valueArithRuntimeLines" () (EListLit (ELit (LString "  ;; -- A0 runtime value-tag-dispatched arithmetic (poly-`Num`: Int i31/$boxint OR $float) --")) (ELit (LString "  (func $mdk_value_add (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (f64.add")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else (call $mdk_box_int (i64.add (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))")) (ELit (LString "  (func $mdk_value_sub (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (f64.sub")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else (call $mdk_box_int (i64.sub (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))")) (ELit (LString "  (func $mdk_value_mul (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (f64.mul")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else (call $mdk_box_int (i64.mul (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))")) (ELit (LString "  (func $mdk_value_div (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (f64.div")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else (call $mdk_box_int (i64.div_s (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))")) (ELit (LString "  (func $mdk_value_mod (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (local $fa f64) (local $fb f64)")) (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $fa (struct.get $float 0 (ref.cast (ref $float) (local.get $a))))")) (ELit (LString "        (local.set $fb (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))")) (ELit (LString "        (struct.new $float (f64.sub (local.get $fa) (f64.mul (local.get $fb) (f64.trunc (f64.div (local.get $fa) (local.get $fb)))))))")) (ELit (LString "      (else (call $mdk_box_int (i64.rem_s (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))")) (ELit (LString "  ;; -- A1 poly-`Ord`/`Eq`-on-Float, NUM-ONLY (no $str): $float f64-eq/cmp else i64 --")) (ELit (LString "  (func $mdk_value_eq_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.eq")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i64.eq (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))")) (ELit (LString "  (func $mdk_value_cmp_num (param $a (ref eq)) (param $b (ref eq)) (result i32)")) (ELit (LString "    (local $fa f64) (local $fb f64) (local $ia i64) (local $ib i64)")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $fa (struct.get $float 0 (ref.cast (ref $float) (local.get $a))))")) (ELit (LString "        (local.set $fb (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))")) (ELit (LString "        (if (f64.lt (local.get $fa) (local.get $fb)) (then (return (i32.const -1))))")) (ELit (LString "        (if (f64.gt (local.get $fa) (local.get $fb)) (then (return (i32.const 1))))")) (ELit (LString "        (return (i32.const 0))))")) (ELit (LString "    (local.set $ia (call $mdk_unbox_int (local.get $a)))")) (ELit (LString "    (local.set $ib (call $mdk_unbox_int (local.get $b)))")) (ELit (LString "    (if (i64.lt_s (local.get $ia) (local.get $ib)) (then (return (i32.const -1))))")) (ELit (LString "    (if (i64.gt_s (local.get $ia) (local.get $ib)) (then (return (i32.const 1))))")) (ELit (LString "    (i32.const 0))"))))
(DTypeSig true "rngStateGlobalLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "rngStateGlobalLines" () (EListLit (ELit (LString "  (global $mdk_rng_state (mut i64) (i64.const 0))"))))
(DTypeSig true "rngRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "rngRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 SplitMix64 RNG (byte-identical to medaka_rt.c) ──")) (ELit (LString "  (func $mdk_next_u64 (result i64)")) (ELit (LString "    (local $z i64)")) (ELit (LString "    (global.set $mdk_rng_state (i64.add (global.get $mdk_rng_state) (i64.const 0x9E3779B97F4A7C15)))")) (ELit (LString "    (local.set $z (global.get $mdk_rng_state))")) (ELit (LString "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 30))) (i64.const 0xBF58476D1CE4E5B9)))")) (ELit (LString "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 27))) (i64.const 0x94D049BB133111EB)))")) (ELit (LString "    (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 31))))")) (ELit (LString "  ;; randomInt lo hi : i32 lo/hi -> i32 in [lo,hi] (INCLUSIVE).  range<=0 -> lo.")) (ELit (LString "  (func $mdk_random_int (param $lo i32) (param $hi i32) (result i32)")) (ELit (LString "    (local $range i32)")) (ELit (LString "    (local.set $range (i32.add (i32.sub (local.get $hi) (local.get $lo)) (i32.const 1)))")) (ELit (LString "    (if (result i32) (i32.le_s (local.get $range) (i32.const 0))")) (ELit (LString "      (then (local.get $lo))")) (ELit (LString "      (else")) (ELit (LString "        (i32.add (local.get $lo)")) (ELit (LString "          (i32.wrap_i64 (i64.rem_u (call $mdk_next_u64) (i64.extend_i32_s (local.get $range))))))))")) (ELit (LString "  (func $mdk_random_bool (result i32)")) (ELit (LString "    (i32.wrap_i64 (i64.and (call $mdk_next_u64) (i64.const 1))))")) (ELit (LString "  (func $mdk_random_char (result i32)")) (ELit (LString "    (i32.add (i32.const 32) (i32.wrap_i64 (i64.rem_u (call $mdk_next_u64) (i64.const 95)))))"))))
(DTypeSig true "hashRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "hashRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 per-type hashers (byte-identical to medaka_rt.c) ──")) (ELit (LString "  ;; SplitMix64 finalizer as a pure mixer (no state update).")) (ELit (LString "  (func $mdk_hash_mix64 (param $x i64) (result i64)")) (ELit (LString "    (local $z i64)")) (ELit (LString "    (local.set $z (i64.add (local.get $x) (i64.const 0x9E3779B97F4A7C15)))")) (ELit (LString "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 30))) (i64.const 0xBF58476D1CE4E5B9)))")) (ELit (LString "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 27))) (i64.const 0x94D049BB133111EB)))")) (ELit (LString "    (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 31))))")) (ELit (LString "  ;; hashInt / hashChar : mix64(value) & 0x3FFFFFFF.  `n` is the untagged i32 value")) (ELit (LString "  ;; sign-extended to i64 (matching medaka_rt.c's signed `tagged>>1`).")) (ELit (LString "  (func $mdk_hash_int (param $n i32) (result i32)")) (ELit (LString "    (i32.wrap_i64 (i64.and (call $mdk_hash_mix64 (i64.extend_i32_s (local.get $n))) (i64.const 0x3FFFFFFF))))")) (ELit (LString "  (func $mdk_hash_bool (param $b i32) (result i32)")) (ELit (LString "    (if (result i32) (local.get $b) (then (i32.const 1)) (else (i32.const 0))))"))))
(DTypeSig true "hashStringRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "hashStringRuntimeLines" () (EListLit (ELit (LString "  ;; hashString : FNV-1a over UTF-8 BYTES, masked.")) (ELit (LString "  (func $mdk_hash_string (param $s (ref $str)) (result i32)")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $i i32) (local $h i64)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $h (i64.const 0xCBF29CE484222325))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $h (i64.mul (i64.xor (local.get $h) (i64.extend_i32_u (array.get_u $u8arr (local.get $b) (local.get $i)))) (i64.const 0x100000001B3)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (i32.wrap_i64 (i64.and (local.get $h) (i64.const 0x3FFFFFFF))))"))))
(DTypeSig true "charClassRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "charClassRuntimeLines" () (EListLit (ELit (LString "  ;; ── W11b ASCII char classification + case mapping (byte-identical to medaka_rt.c) ──")) (ELit (LString "  (func $mdk_char_is_alpha (param $c i32) (result i32)")) (ELit (LString "    (i32.or")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))))")) (ELit (LString "  (func $mdk_char_is_space (param $c i32) (result i32)")) (ELit (LString "    (i32.or")) (ELit (LString "      (i32.eq (local.get $c) (i32.const 32))")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 9)) (i32.le_u (local.get $c) (i32.const 13)))))")) (ELit (LString "  (func $mdk_char_is_upper (param $c i32) (result i32)")) (ELit (LString "    (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90))))")) (ELit (LString "  (func $mdk_char_is_lower (param $c i32) (result i32)")) (ELit (LString "    (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122))))")) (ELit (LString "  ;; charIsPunct: exact set from medaka_rt.c switch — Unicode Pc/Pd/Pe/Pf/Pi/Po/Ps ASCII.")) (ELit (LString "  ;; Included: ! \" # % & ' ( ) * , - . / : ; ? @ [ \\ ] _ { }")) (ELit (LString "  ;; Excluded ($+<=>^`|~): those are Unicode symbols (Sm/Sc/Sk), not punctuation.")) (ELit (LString "  ;; Right-associative OR chain over 23 chars = 22 i32.or nodes.")) (ELit (LString "  (func $mdk_char_is_punct (param $c i32) (result i32)")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 33))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 34))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 35))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 37))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 38))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 39))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 40))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 41))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 42))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 44))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 45))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 46))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 47))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 58))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 59))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 63))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 64))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 91))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 92))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 93))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 95))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 123))")) (ELit (LString "           (i32.eq (local.get $c) (i32.const 125))")) (ELit (LString "    )))))))))))))))))))))))")) (ELit (LString "  (func $mdk_char_to_upper (param $c i32) (result i32)")) (ELit (LString "    (if (result i32)")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))")) (ELit (LString "      (then (i32.sub (local.get $c) (i32.const 32)))")) (ELit (LString "      (else (local.get $c))))")) (ELit (LString "  (func $mdk_char_to_lower (param $c i32) (result i32)")) (ELit (LString "    (if (result i32)")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))")) (ELit (LString "      (then (i32.add (local.get $c) (i32.const 32)))")) (ELit (LString "      (else (local.get $c))))"))))
(DTypeSig true "floatFmtImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "floatFmtImportLines" () (EListLit (ELit (LString "  ;; -- W8b floatToString host seam (%.12g — reproduced JS-side, see run.js) --")) (ELit (LString "  (import \"env\" \"mdk_float_fmt\" (func $mdk_float_fmt (param f64) (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_float_fmt_byte\" (func $mdk_float_fmt_byte (param i32) (result i32)))"))))
(DTypeSig true "floatStrImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "floatStrImportLines" () (EListLit (ELit (LString "  ;; -- stringToFloat host seam (Number() JS-side, see run.js) --")) (ELit (LString "  (import \"env\" \"mdk_str_to_float\" (func $mdk_str_to_float (result f64)))"))))
(DTypeSig true "floatStrRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "floatStrRuntimeLines" () (EListLit (ELit (LString "  ;; stringToFloat : $str -> Option Float (ref eq).")) (ELit (LString "  (func $mdk_string_to_float (param $s (ref $str)) (result (ref eq))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32) (local $d f64)")) (ELit (LString "    (call $mdk_path_reset)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $done (loop $loop")) (ELit (LString "      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_path_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1)))")) (ELit (LString "      (br $loop)))")) (ELit (LString "    (local.set $d (call $mdk_str_to_float))")) (ELit (LString "    ;; Return Some(boxed f64) always — JS Number() returns NaN for unparseable,")) (ELit (LString "    ;; and medaka_rt.c strtod returns Some(NaN) for \"nan\" and None for truly")) (ELit (LString "    ;; unparseable strings.  We mirror: if the result is NaN, return None; if nan")) (ELit (LString "    ;; the string is \"nan\" strtod returns Some(NaN) — but for the medaka use cases")) (ELit (LString "    ;; (float literals, json.mdk numeric strings) the host never returns NaN for")) (ELit (LString "    ;; a valid parse, so a simple NaN->None mapping is correct.")) (ELit (LString "    (if (result (ref eq)) (f64.ne (local.get $d) (local.get $d))")) (ELit (LString "      (then (ref.i31 (i32.const 1)))")) (ELit (LString "      (else (struct.new $C_Some (i32.const 0) (struct.new $float (local.get $d)))))")) (ELit (LString "  )"))))
(DTypeSig true "floatRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "floatRuntimeLines" () (EListLit (ELit (LString "  ;; -- W8b Float runtime (byte-identical to medaka_rt.c) --")) (ELit (LString "  ;; intToFloat : i32 -> boxed (struct $float).")) (ELit (LString "  (func $mdk_int_to_float (param $n i32) (result (ref $float))")) (ELit (LString "    (struct.new $float (f64.convert_i32_s (local.get $n))))")) (ELit (LString "  ;; floatToInt : boxed $float -> i32 (truncate toward zero, matching (int)d).")) (ELit (LString "  (func $mdk_float_to_int (param $f (ref $float)) (result i32)")) (ELit (LString "    (i32.trunc_f64_s (struct.get $float 0 (local.get $f))))")) (ELit (LString "  ;; floatRem a b = a - b*trunc(a/b)  (== C fmod == LLVM frem); backs `Float % Float`.")) (ELit (LString "  (func $mdk_float_rem (param $a f64) (param $b f64) (result f64)")) (ELit (LString "    (f64.sub (local.get $a) (f64.mul (local.get $b) (f64.trunc (f64.div (local.get $a) (local.get $b))))))")) (ELit (LString "  ;; floatToString : the host formats (%.12g + .0 rule) into a cache; copy the bytes")) (ELit (LString "  ;; into a fresh $str.  cp_count == byte_len (the %.12g output is ASCII).")) (ELit (LString "  (func $mdk_float_to_str (param $d f64) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $i i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $n (call $mdk_float_fmt (local.get $d)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (call $mdk_float_fmt_byte (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (local.get $n) (local.get $buf)))"))))
(DTypeSig true "hashFloatRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "hashFloatRuntimeLines" () (EListLit (ELit (LString "  ;; hashFloat : reinterpret the double's bits as i64 -> mix64 -> mask [0,2^30).")) (ELit (LString "  (func $mdk_hash_float (param $f (ref $float)) (result i32)")) (ELit (LString "    (i32.wrap_i64 (i64.and (call $mdk_hash_mix64 (i64.reinterpret_f64 (struct.get $float 0 (local.get $f)))) (i64.const 0x3FFFFFFF))))"))))
(DTypeSig true "randomFloatRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "randomFloatRuntimeLines" () (EListLit (ELit (LString "  ;; randomFloat : SplitMix64 -> f64 in [-1,1) (NOTE the -1 offset — see medaka_rt.c).")) (ELit (LString "  (func $mdk_random_float (result (ref $float))")) (ELit (LString "    (struct.new $float")) (ELit (LString "      (f64.sub")) (ELit (LString "        (f64.mul")) (ELit (LString "          (f64.mul (f64.convert_i64_u (i64.shr_u (call $mdk_next_u64) (i64.const 11)))")) (ELit (LString "                   (f64.const 1.1102230246251565e-16))")) (ELit (LString "          (f64.const 2.0))")) (ELit (LString "        (f64.const 1.0))))"))))
(DTypeSig true "ioHostImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioHostImportLines" () (EListLit (ELit (LString "  ;; -- W12 IO host surface (byte-channel marshaling, see run.js) --")) (ELit (LString "  (import \"env\" \"mdk_path_reset\" (func $mdk_path_reset))")) (ELit (LString "  (import \"env\" \"mdk_path_push\" (func $mdk_path_push (param i32)))")) (ELit (LString "  (import \"env\" \"mdk_read_file\" (func $mdk_read_file (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_file_exists\" (func $mdk_file_exists (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_get_env\" (func $mdk_get_env (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_args_count\" (func $mdk_args_count (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_arg_len\" (func $mdk_arg_len (param i32) (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_arg_byte\" (func $mdk_arg_byte (param i32) (param i32) (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_result_len\" (func $mdk_result_len (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_result_byte\" (func $mdk_result_byte (param i32) (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_exit\" (func $mdk_exit (param i32)))"))))
(DTypeSig true "ioHostRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioHostRuntimeLines" () (EListLit (ELit (LString "  ;; -- W12 IO host-surface runtime --")) (ELit (LString "  ;; push a $str's bytes to the host path buffer (reset first).")) (ELit (LString "  (func $mdk_push_path (param $s (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (call $mdk_path_reset)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_path_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    )")) (ELit (LString "  ;; rebuild a fresh $str from the host result buffer (length + byte-at-index).")) (ELit (LString "  ;; cp_count is the true UTF-8 codepoint count (count lead bytes: those whose top")) (ELit (LString "  ;; two bits are NOT 0b10, i.e. (b & 0xC0) != 0x80).  A byte-length approximation")) (ELit (LString "  ;; here is WRONG for any multibyte content: $mdk_str_to_chars allocates its output")) (ELit (LString "  ;; $arr to cp_count and the lexer reads arrayLength as the char count, so an inflated")) (ELit (LString "  ;; cp_count appends trailing NUL chars past the real codepoints -> a stray '\\0' falls")) (ELit (LString "  ;; through every clause head and traps (a file with a single em-dash comment was enough).")) (ELit (LString "  (func $mdk_io_result_to_str (result (ref $str))")) (ELit (LString "    (local $n i32) (local $i i32) (local $buf (ref $u8arr)) (local $cpc i32) (local $b i32)")) (ELit (LString "    (local.set $n (call $mdk_result_len))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $cpc (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $b (call $mdk_result_byte (local.get $i)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $b))")) (ELit (LString "      (if (i32.ne (i32.and (local.get $b) (i32.const 192)) (i32.const 128))")) (ELit (LString "        (then (local.set $cpc (i32.add (local.get $cpc) (i32.const 1)))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (local.get $cpc) (local.get $buf)))")) (ELit (LString "  ;; readFile : $str path -> Result String String.  1=Ok contents / 0=Err message.")) (ELit (LString "  (func $mdk_read_file_io (param $path (ref $str)) (result (ref eq))")) (ELit (LString "    (local $st i32)")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (local.set $st (call $mdk_read_file))")) (ELit (LString "    (if (result (ref eq)) (local.get $st)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (call $mdk_io_result_to_str)))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))")) (ELit (LString "  ;; fileExists : $str path -> Bool (i31 ordinal: False=0 / True=1).")) (ELit (LString "  (func $mdk_file_exists_io (param $path (ref $str)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (ref.i31 (call $mdk_file_exists)))")) (ELit (LString "  ;; getEnv : $str name -> Option String.  1=Some value / 0=None.")) (ELit (LString "  (func $mdk_get_env_io (param $name (ref $str)) (result (ref eq))")) (ELit (LString "    (local $st i32)")) (ELit (LString "    (call $mdk_push_path (local.get $name))")) (ELit (LString "    (local.set $st (call $mdk_get_env))")) (ELit (LString "    (if (result (ref eq)) (local.get $st)")) (ELit (LString "      (then (struct.new $C_Some (i32.const 0) (call $mdk_io_result_to_str)))")) (ELit (LString "      (else (ref.i31 (i32.const 1)))))"))))
(DTypeSig true "ioArgsRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioArgsRuntimeLines" () (EListLit (ELit (LString "  ;; build a $str from the i-th host arg (mdk_arg_len(i) + mdk_arg_byte(i,j)).")) (ELit (LString "  (func $mdk_arg_to_str (param $idx i32) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $j i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $n (call $mdk_arg_len (local.get $idx)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $j (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $j) (local.get $n)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $j) (call $mdk_arg_byte (local.get $idx) (local.get $j)))")) (ELit (LString "      (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (local.get $n) (local.get $buf)))")) (ELit (LString "  ;; args : Unit -> List String.  Fold a Cons chain right-to-left ending in Nil.")) (ELit (LString "  (func $mdk_args_io (result (ref eq))")) (ELit (LString "    (local $c i32) (local $i i32) (local $acc (ref eq))")) (ELit (LString "    (local.set $c (call $mdk_args_count))")) (ELit (LString "    (local.set $acc (ref.i31 (i32.const 1)))")) (ELit (LString "    (local.set $i (i32.sub (local.get $c) (i32.const 1)))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.lt_s (local.get $i) (i32.const 0)))")) (ELit (LString "      (local.set $acc (struct.new $C_Cons (i32.const 0) (call $mdk_arg_to_str (local.get $i)) (local.get $acc)))")) (ELit (LString "      (local.set $i (i32.sub (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $acc))"))))
(DTypeSig true "fileBytesHostImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "fileBytesHostImportLines" () (EListLit (ELit (LString "  ;; -- stage-D writeFileBytes host imports (path via mdk_path_push; bytes streamed) --")) (ELit (LString "  (import \"env\" \"mdk_write_file_reset\" (func $mdk_write_file_reset))")) (ELit (LString "  (import \"env\" \"mdk_write_file_push\" (func $mdk_write_file_push (param i32)))")) (ELit (LString "  (import \"env\" \"mdk_write_file_commit\" (func $mdk_write_file_commit (result i32)))"))))
(DTypeSig true "fileBytesRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "fileBytesRuntimeLines" () (EListLit (ELit (LString "  ;; -- stage-D byte-clean file I/O runtime --")) (ELit (LString "  ;; readFileBytes : $str path -> Result String (Array Int).  1=Ok bytes / 0=Err msg.")) (ELit (LString "  ;; Reuses the read byte-channel but rebuilds an $arr of i31 Int bytes (0..255).")) (ELit (LString "  (func $mdk_read_file_bytes_io (param $path (ref $str)) (result (ref eq))")) (ELit (LString "    (local $st i32) (local $n i32) (local $i i32) (local $out (ref $arr))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (local.set $st (call $mdk_read_file))")) (ELit (LString "    (if (result (ref eq)) (local.get $st)")) (ELit (LString "      (then")) (ELit (LString "        (local.set $n (call $mdk_result_len))")) (ELit (LString "        (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $n)))")) (ELit (LString "        (local.set $i (i32.const 0))")) (ELit (LString "        (block $d (loop $l")) (ELit (LString "          (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "          (array.set $arr (local.get $out) (local.get $i) (ref.i31 (call $mdk_result_byte (local.get $i))))")) (ELit (LString "          (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "        (struct.new $C_Ok (i32.const 0) (local.get $out)))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))")) (ELit (LString "  ;; writeFileBytes : $str path -> $arr bytes -> Result String Unit.  1=Ok () / 0=Err msg.")) (ELit (LString "  ;; Stream each i31 byte (masked to 0..255) to the host, then commit fs.writeFileSync.")) (ELit (LString "  (func $mdk_write_file_bytes_io (param $path (ref $str)) (param $ba (ref $arr)) (result (ref eq))")) (ELit (LString "    (local $st i32) (local $n i32) (local $i i32)")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (call $mdk_write_file_reset)")) (ELit (LString "    (local.set $n (array.len (local.get $ba)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_file_push (i32.and (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $ba) (local.get $i)))) (i32.const 255)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.set $st (call $mdk_write_file_commit))")) (ELit (LString "    (if (result (ref eq)) (local.get $st)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig true "strSearchRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strSearchRuntimeLines" () (EListLit (ELit (LString "  ;; -- W8b stringIndexOf / stringCompare (byte-identical to medaka_rt.c) --")) (ELit (LString "  (func $mdk_str_index_of (param $needle (ref $str)) (param $hay (ref $str)) (result (ref eq))")) (ELit (LString "    (local $nb (ref $u8arr)) (local $hb (ref $u8arr)) (local $nl i32) (local $hl i32)")) (ELit (LString "    (local $b i32) (local $j i32) (local $ok i32)")) (ELit (LString "    (local.set $nb (struct.get $str $bytes (local.get $needle)))")) (ELit (LString "    (local.set $hb (struct.get $str $bytes (local.get $hay)))")) (ELit (LString "    (local.set $nl (array.len (local.get $nb)))")) (ELit (LString "    (local.set $hl (array.len (local.get $hb)))")) (ELit (LString "    ;; empty needle -> Some 0 (codepoint index 0).")) (ELit (LString "    (if (i32.eqz (local.get $nl))")) (ELit (LString "      (then (return (struct.new $C_Some (i32.const 0) (ref.i31 (i32.const 0))))))")) (ELit (LString "    (local.set $b (i32.const 0))")) (ELit (LString "    (block $done (loop $scan")) (ELit (LString "      ;; while b + nl <= hl")) (ELit (LString "      (br_if $done (i32.gt_s (i32.add (local.get $b) (local.get $nl)) (local.get $hl)))")) (ELit (LString "      (local.set $ok (i32.const 1))")) (ELit (LString "      (local.set $j (i32.const 0))")) (ELit (LString "      (block $cmpd (loop $cmpl")) (ELit (LString "        (br_if $cmpd (i32.ge_s (local.get $j) (local.get $nl)))")) (ELit (LString "        (if (i32.ne (array.get_u $u8arr (local.get $hb) (i32.add (local.get $b) (local.get $j)))")) (ELit (LString "                    (array.get_u $u8arr (local.get $nb) (local.get $j)))")) (ELit (LString "          (then (local.set $ok (i32.const 0)) (br $cmpd)))")) (ELit (LString "        (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $cmpl)))")) (ELit (LString "      (if (local.get $ok)")) (ELit (LString "        (then (return (struct.new $C_Some (i32.const 0)")) (ELit (LString "          (ref.i31 (call $mdk_cp_count (local.get $hb) (local.get $b)))))))")) (ELit (LString "      (local.set $b (i32.add (local.get $b) (i32.const 1))) (br $scan)))")) (ELit (LString "    ;; not found -> None (i31 ordinal 1).")) (ELit (LString "    (ref.i31 (i32.const 1)))")) (ELit (LString "  (func $mdk_str_compare (param $a (ref $str)) (param $b (ref $str)) (result (ref eq))")) (ELit (LString "    (local $ab (ref $u8arr)) (local $bb (ref $u8arr)) (local $al i32) (local $bl i32)")) (ELit (LString "    (local $m i32) (local $i i32) (local $ca i32) (local $cb i32)")) (ELit (LString "    (local.set $ab (struct.get $str $bytes (local.get $a)))")) (ELit (LString "    (local.set $bb (struct.get $str $bytes (local.get $b)))")) (ELit (LString "    (local.set $al (array.len (local.get $ab)))")) (ELit (LString "    (local.set $bl (array.len (local.get $bb)))")) (ELit (LString "    (local.set $m (if (result i32) (i32.lt_s (local.get $al) (local.get $bl))")) (ELit (LString "      (then (local.get $al)) (else (local.get $bl))))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $done (loop $l")) (ELit (LString "      (br_if $done (i32.ge_s (local.get $i) (local.get $m)))")) (ELit (LString "      (local.set $ca (array.get_u $u8arr (local.get $ab) (local.get $i)))")) (ELit (LString "      (local.set $cb (array.get_u $u8arr (local.get $bb) (local.get $i)))")) (ELit (LString "      ;; byte less -> Lt (i31 0); byte greater -> Gt (i31 2).")) (ELit (LString "      (if (i32.lt_u (local.get $ca) (local.get $cb)) (then (return (ref.i31 (i32.const 0)))))")) (ELit (LString "      (if (i32.gt_u (local.get $ca) (local.get $cb)) (then (return (ref.i31 (i32.const 2)))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    ;; common prefix equal: shorter < longer; equal length -> Eq.")) (ELit (LString "    (if (i32.lt_s (local.get $al) (local.get $bl)) (then (return (ref.i31 (i32.const 0)))))")) (ELit (LString "    (if (i32.gt_s (local.get $al) (local.get $bl)) (then (return (ref.i31 (i32.const 2)))))")) (ELit (LString "    (ref.i31 (i32.const 1)))"))))
(DTypeSig true "strCodecRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strCodecRuntimeLines" () (EListLit (ELit (LString "  ;; -- W11b UTF-8 codec (byte-identical to medaka_rt.c) --")) (ELit (LString "  ;; decode a $str's UTF-8 bytes into a fresh $arr of cp_count i31 Char codepoints.")) (ELit (LString "  (func $mdk_str_to_chars (param $s (ref $str)) (result (ref $arr))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $cpc i32) (local $out (ref $arr))")) (ELit (LString "    (local $bo i32) (local $oi i32) (local $lead i32) (local $cp i32) (local $k i32) (local $w i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $cpc (struct.get $str $cp_count (local.get $s)))")) (ELit (LString "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $cpc)))")) (ELit (LString "    (local.set $bo (i32.const 0)) (local.set $oi (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $bo) (local.get $n)))")) (ELit (LString "      (local.set $lead (array.get_u $u8arr (local.get $b) (local.get $bo)))")) (ELit (LString "      ;; lead-byte class → codepoint seed bits + total byte width.")) (ELit (LString "      (if (i32.lt_u (local.get $lead) (i32.const 128))")) (ELit (LString "        (then (local.set $cp (local.get $lead)) (local.set $w (i32.const 1)))")) (ELit (LString "        (else (if (i32.lt_u (local.get $lead) (i32.const 224))")) (ELit (LString "          (then (local.set $cp (i32.and (local.get $lead) (i32.const 31))) (local.set $w (i32.const 2)))")) (ELit (LString "          (else (if (i32.lt_u (local.get $lead) (i32.const 240))")) (ELit (LString "            (then (local.set $cp (i32.and (local.get $lead) (i32.const 15))) (local.set $w (i32.const 3)))")) (ELit (LString "            (else (local.set $cp (i32.and (local.get $lead) (i32.const 7))) (local.set $w (i32.const 4))))))))")) (ELit (LString "      ;; fold in (w-1) continuation bytes: cp = (cp << 6) | (byte & 0x3F).")) (ELit (LString "      (local.set $k (i32.const 1))")) (ELit (LString "      (block $cd (loop $cl")) (ELit (LString "        (br_if $cd (i32.ge_s (local.get $k) (local.get $w)))")) (ELit (LString "        (local.set $cp (i32.or (i32.shl (local.get $cp) (i32.const 6))")) (ELit (LString "          (i32.and (array.get_u $u8arr (local.get $b) (i32.add (local.get $bo) (local.get $k))) (i32.const 63))))")) (ELit (LString "        (local.set $k (i32.add (local.get $k) (i32.const 1))) (br $cl)))")) (ELit (LString "      (array.set $arr (local.get $out) (local.get $oi) (ref.i31 (local.get $cp)))")) (ELit (LString "      (local.set $oi (i32.add (local.get $oi) (i32.const 1)))")) (ELit (LString "      (local.set $bo (i32.add (local.get $bo) (local.get $w))) (br $l)))")) (ELit (LString "    (local.get $out))")) (ELit (LString "  ;; number of UTF-8 bytes a codepoint encodes to (1..4).")) (ELit (LString "  (func $mdk_utf8_nbytes (param $cp i32) (result i32)")) (ELit (LString "    (if (result i32) (i32.lt_u (local.get $cp) (i32.const 128)) (then (i32.const 1))")) (ELit (LString "      (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 2048)) (then (i32.const 2))")) (ELit (LString "        (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 65536)) (then (i32.const 3))")) (ELit (LString "          (else (i32.const 4))))))))")) (ELit (LString "  ;; encode one codepoint into $buf at offset $off; return the next offset.")) (ELit (LString "  (func $mdk_utf8_emit_at (param $buf (ref $u8arr)) (param $off i32) (param $cp i32) (result i32)")) (ELit (LString "    (if (result i32) (i32.lt_u (local.get $cp) (i32.const 128))")) (ELit (LString "      (then")) (ELit (LString "        (array.set $u8arr (local.get $buf) (local.get $off) (local.get $cp))")) (ELit (LString "        (i32.add (local.get $off) (i32.const 1)))")) (ELit (LString "      (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 2048))")) (ELit (LString "        (then")) (ELit (LString "          (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 192) (i32.shr_u (local.get $cp) (i32.const 6))))")) (ELit (LString "          (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "          (i32.add (local.get $off) (i32.const 2)))")) (ELit (LString "        (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 65536))")) (ELit (LString "          (then")) (ELit (LString "            (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 224) (i32.shr_u (local.get $cp) (i32.const 12))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 2)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "            (i32.add (local.get $off) (i32.const 3)))")) (ELit (LString "          (else")) (ELit (LString "            (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 240) (i32.shr_u (local.get $cp) (i32.const 18))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 2)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 3)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "            (i32.add (local.get $off) (i32.const 4))))))))")) (ELit (LString "  )")) (ELit (LString "  ;; encode an $arr of i31 Char codepoints into a fresh $str (UTF-8); cp_count = len.")) (ELit (LString "  (func $mdk_chars_to_str (param $a (ref $arr)) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $i i32) (local $total i32) (local $off i32)")) (ELit (LString "    (local $buf (ref $u8arr)) (local $cp i32)")) (ELit (LString "    (local.set $n (array.len (local.get $a)))")) (ELit (LString "    ;; pass 1: total encoded byte length.")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $total (i32.const 0))")) (ELit (LString "    (block $d1 (loop $l1")) (ELit (LString "      (br_if $d1 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $cp (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))))")) (ELit (LString "      (local.set $total (i32.add (local.get $total) (call $mdk_utf8_nbytes (local.get $cp))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l1)))")) (ELit (LString "    ;; pass 2: encode into the buffer.")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $total)))")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $off (i32.const 0))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $cp (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))))")) (ELit (LString "      (local.set $off (call $mdk_utf8_emit_at (local.get $buf) (local.get $off) (local.get $cp)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))")) (ELit (LString "    (struct.new $str (local.get $n) (local.get $buf)))")) (ELit (LString "  ;; stringToUtf8Bytes: copy the $str's $u8arr backing into a fresh $arr of i31 Int bytes.")) (ELit (LString "  (func $mdk_str_to_utf8_bytes (param $s (ref $str)) (result (ref $arr))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $out (ref $arr)) (local $i i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $arr (local.get $out) (local.get $i) (ref.i31 (array.get_u $u8arr (local.get $b) (local.get $i))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $out))")) (ELit (LString "  ;; stringFromUtf8Bytes: blit the low 8 bits of each i31 Int into a $u8arr; recompute")) (ELit (LString "  ;; cp_count by the non-continuation-byte rule (byte-identical to medaka_rt.c mdk_str_lit).")) (ELit (LString "  (func $mdk_utf8_bytes_to_str (param $a (ref $arr)) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $buf (ref $u8arr)) (local $i i32) (local $cpc i32) (local $byte i32)")) (ELit (LString "    (local.set $n (array.len (local.get $a)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $cpc (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $byte (i32.and (i31.get_u (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))) (i32.const 255)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $byte))")) (ELit (LString "      (if (i32.ne (i32.and (local.get $byte) (i32.const 192)) (i32.const 128))")) (ELit (LString "        (then (local.set $cpc (i32.add (local.get $cpc) (i32.const 1)))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (local.get $cpc) (local.get $buf)))"))))
(DTypeSig true "charFromCodeRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "charFromCodeRuntimeLines" () (EListLit (ELit (LString "  ;; -- W11b charFromCode (byte-identical to medaka_rt.c mdk_char_from_code) --")) (ELit (LString "  (func $mdk_char_from_code (param $cp i32) (result (ref eq))")) (ELit (LString "    ;; valid: 0 <= cp <= 0x10FFFF and not (0xD800 <= cp <= 0xDFFF).")) (ELit (LString "    (if (i32.and (i32.and (i32.ge_s (local.get $cp) (i32.const 0)) (i32.le_s (local.get $cp) (i32.const 1114111)))")) (ELit (LString "                 (i32.eqz (i32.and (i32.ge_s (local.get $cp) (i32.const 55296)) (i32.le_s (local.get $cp) (i32.const 57343)))))")) (ELit (LString "      (then (return (struct.new $C_Some (i32.const 0) (ref.i31 (local.get $cp))))))")) (ELit (LString "    (ref.i31 (i32.const 1)))"))))
# MARK
(DTypeSig true "preambleHeadLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "preambleHeadLines" () (EListLit (ELit (LString ";; Medaka WasmGC backend (Stage 2.4c) — emitted WAT.")) (ELit (LString ";; Value rep: WASMGC-DESIGN.md §3 / §8.6.  W2 = scalar i32; W3 = (ref eq) + i31/structs.")) (ELit (LString "(module"))))
(DTypeSig true "importLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "importLines" () (EListLit (ELit (LString "  ;; ── §6 host-import IO seam (§10 fork e — custom import) ──")) (ELit (LString "  (import \"env\" \"mdk_write_int\" (func $mdk_write_int (param i32)))")) (ELit (LString "  (import \"env\" \"mdk_write_bool\" (func $mdk_write_bool (param i32)))"))))
(DTypeSig true "closTypeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "closTypeLines" () (EListLit (ELit (LString "    ;; ── §4 closure ABI (arity-in-struct, uniform code sig) ──")) (ELit (LString "    (type $argarr (array (mut (ref null eq))))")) (ELit (LString "    (type $codety (func (param (ref eq)) (param (ref $argarr)) (result (ref eq))))")) (ELit (LString "    (type $clos (sub (struct (field $code (ref $codety)) (field $arity i32) (field $env (ref $argarr)))))"))))
(DTypeSig true "closApplyLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "closApplyLines" () (EListLit (ELit (LString "  ;; ── §4 universal apply runtime (exact / under-PAP / over-saturate) ──")) (ELit (LString "  (func $mdk_pap (type $codety) (param $self (ref eq)) (param $args (ref $argarr)) (result (ref eq))")) (ELit (LString "    (local $c (ref $clos)) (local $env (ref $argarr)) (local $orig (ref eq))")) (ELit (LString "    (local $ne i32) (local $na i32) (local $total (ref $argarr)) (local $i i32)")) (ELit (LString "    (local.set $c (ref.cast (ref $clos) (local.get $self)))")) (ELit (LString "    (local.set $env (struct.get $clos $env (local.get $c)))")) (ELit (LString "    (local.set $orig (ref.as_non_null (array.get $argarr (local.get $env) (i32.const 0))))")) (ELit (LString "    (local.set $ne (i32.sub (array.len (local.get $env)) (i32.const 1)))")) (ELit (LString "    (local.set $na (array.len (local.get $args)))")) (ELit (LString "    (local.set $total (array.new $argarr (ref.null eq) (i32.add (local.get $ne) (local.get $na))))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $pd (loop $pl")) (ELit (LString "      (br_if $pd (i32.ge_s (local.get $i) (local.get $ne)))")) (ELit (LString "      (array.set $argarr (local.get $total) (local.get $i)")) (ELit (LString "        (array.get $argarr (local.get $env) (i32.add (local.get $i) (i32.const 1))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $pl)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $pd2 (loop $pl2")) (ELit (LString "      (br_if $pd2 (i32.ge_s (local.get $i) (local.get $na)))")) (ELit (LString "      (array.set $argarr (local.get $total) (i32.add (local.get $ne) (local.get $i))")) (ELit (LString "        (array.get $argarr (local.get $args) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $pl2)))")) (ELit (LString "    (return_call $__mdk_apply (local.get $orig) (local.get $total)))")) (ELit (LString "  (func $__mdk_apply (param $f (ref eq)) (param $args (ref $argarr)) (result (ref eq))")) (ELit (LString "    (local $c (ref $clos)) (local $ar i32) (local $na i32)")) (ELit (LString "    (local $sat (ref $argarr)) (local $surplus (ref $argarr)) (local $i i32) (local $r (ref eq))")) (ELit (LString "    (local $penv (ref $argarr))")) (ELit (LString "    (local.set $c (ref.cast (ref $clos) (local.get $f)))")) (ELit (LString "    (local.set $ar (struct.get $clos $arity (local.get $c)))")) (ELit (LString "    (local.set $na (array.len (local.get $args)))")) (ELit (LString "    (if (result (ref eq)) (i32.eq (local.get $na) (local.get $ar))")) (ELit (LString "      (then (return_call_ref $codety (local.get $f) (local.get $args) (struct.get $clos $code (local.get $c))))")) (ELit (LString "      (else")) (ELit (LString "        (if (result (ref eq)) (i32.lt_s (local.get $na) (local.get $ar))")) (ELit (LString "          (then")) (ELit (LString "            (local.set $penv (array.new $argarr (ref.null eq) (i32.add (local.get $na) (i32.const 1))))")) (ELit (LString "            (array.set $argarr (local.get $penv) (i32.const 0) (local.get $f))")) (ELit (LString "            (local.set $i (i32.const 0))")) (ELit (LString "            (block $ud (loop $ul")) (ELit (LString "              (br_if $ud (i32.ge_s (local.get $i) (local.get $na)))")) (ELit (LString "              (array.set $argarr (local.get $penv) (i32.add (local.get $i) (i32.const 1))")) (ELit (LString "                (array.get $argarr (local.get $args) (local.get $i)))")) (ELit (LString "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $ul)))")) (ELit (LString "            (struct.new $clos (ref.func $mdk_pap) (i32.sub (local.get $ar) (local.get $na)) (local.get $penv)))")) (ELit (LString "          (else")) (ELit (LString "            (local.set $sat (array.new $argarr (ref.null eq) (local.get $ar)))")) (ELit (LString "            (local.set $i (i32.const 0))")) (ELit (LString "            (block $sd (loop $sl")) (ELit (LString "              (br_if $sd (i32.ge_s (local.get $i) (local.get $ar)))")) (ELit (LString "              (array.set $argarr (local.get $sat) (local.get $i)")) (ELit (LString "                (array.get $argarr (local.get $args) (local.get $i)))")) (ELit (LString "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $sl)))")) (ELit (LString "            (local.set $r (call_ref $codety (local.get $f) (local.get $sat) (struct.get $clos $code (local.get $c))))")) (ELit (LString "            (local.set $surplus (array.new $argarr (ref.null eq) (i32.sub (local.get $na) (local.get $ar))))")) (ELit (LString "            (local.set $i (i32.const 0))")) (ELit (LString "            (block $od (loop $ol")) (ELit (LString "              (br_if $od (i32.ge_s (local.get $i) (i32.sub (local.get $na) (local.get $ar))))")) (ELit (LString "              (array.set $argarr (local.get $surplus) (local.get $i)")) (ELit (LString "                (array.get $argarr (local.get $args) (i32.add (local.get $i) (local.get $ar))))")) (ELit (LString "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $ol)))")) (ELit (LString "            (return_call $__mdk_apply (local.get $r) (local.get $surplus)))))))"))))
(DTypeSig true "preambleScalarLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "preambleScalarLines" () (EBinOp "++" (EBinOp "++" (EVar "preambleHeadLines") (EListLit (ELit (LString "  ;; ── §3 type section (one rec group, iso-recursive / nominal-modulo-canon) ──")) (ELit (LString "  ;; This program uses no ADTs — the scalar subset computes in raw i32 and only")) (ELit (LString "  ;; the print boundary is reached; the unitype scaffolding is declared unused.")) (ELit (LString "  (rec")) (ELit (LString "    ;; boxed Int outside the i31 range (§3.2) — declared, unused.")) (ELit (LString "    (type $boxint (sub (struct (field i64))))")) (ELit (LString "    ;; boxed Float (§3.3) — declared, unused until a Float fixture needs it.")) (ELit (LString "    (type $float (sub (struct (field f64))))")) (ELit (LString "  )")))) (EVar "importLines")))
(DTypeSig true "ioByteImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioByteImportLines" () (EListLit (ELit (LString "  ;; ── §6 host-import IO seam (§10 fork e — byte-level custom import) ──")) (ELit (LString "  (import \"env\" \"mdk_write_byte\" (func $mdk_write_byte (param i32)))"))))
(DTypeSig true "strTypeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strTypeLines" () (EListLit (ELit (LString "    ;; ── §3.3 String aggregate (UTF-8 bytes + cached codepoint count) ──")) (ELit (LString "    (type $u8arr (array (mut i8)))")) (ELit (LString "    (type $str (sub (struct (field $cp_count i32) (field $bytes (ref $u8arr)))))"))))
(DTypeSig true "ioRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioRuntimeLines" () (EListLit (ELit (LString "  ;; ── §2.1 Int representation seam: i31 fast path / $boxint i64 box ──")) (ELit (LString "  ;; layer-17 SOUNDNESS: Ints in [-2^30, 2^30) are i31ref immediates; outside that")) (ELit (LString "  ;; range they box into (struct (field i64)) ($boxint).  ALL Int arithmetic unboxes")) (ELit (LString "  ;; both operands to i64 via $mdk_unbox_int, computes in i64, and re-boxes via")) (ELit (LString "  ;; $mdk_box_int — so >2^30 values no longer truncate to 31 bits.")) (ELit (LString "  (func $mdk_unbox_int (param $v (ref eq)) (result i64)")) (ELit (LString "    (if (result i64) (ref.test (ref i31) (local.get $v))")) (ELit (LString "      (then (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $v)))))")) (ELit (LString "      (else (struct.get $boxint 0 (ref.cast (ref $boxint) (local.get $v))))))")) (ELit (LString "  ;; box an i64 Int: in [-2^30, 2^30) -> i31 immediate; else -> $boxint struct.")) (ELit (LString "  (func $mdk_box_int (param $n i64) (result (ref eq))")) (ELit (LString "    (if (result (ref eq))")) (ELit (LString "        (i32.and (i64.ge_s (local.get $n) (i64.const -1073741824))")) (ELit (LString "                 (i64.lt_s (local.get $n) (i64.const 1073741824)))")) (ELit (LString "      (then (ref.i31 (i32.wrap_i64 (local.get $n))))")) (ELit (LString "      (else (struct.new $boxint (local.get $n)))))")) (ELit (LString "  ;; ── §6 byte-write print runtime (decimal int / bool text) ──")) (ELit (LString "  ;; write the decimal digits of a NON-NEGATIVE i64 (most-significant first).")) (ELit (LString "  (func $mdk_write_digits (param $n i64)")) (ELit (LString "    (if (i64.ge_s (local.get $n) (i64.const 10))")) (ELit (LString "      (then (call $mdk_write_digits (i64.div_s (local.get $n) (i64.const 10)))))")) (ELit (LString "    (call $mdk_write_byte")) (ELit (LString "      (i32.add (i32.const 48)")) (ELit (LString "        (i32.wrap_i64 (i64.rem_s (local.get $n) (i64.const 10))))))")) (ELit (LString "  ;; render an i64 in decimal to stdout + a trailing newline (value-main Int).")) (ELit (LString "  (func $mdk_print_int (param $n i64)")) (ELit (LString "    (if (i64.lt_s (local.get $n) (i64.const 0))")) (ELit (LString "      (then")) (ELit (LString "        (call $mdk_write_byte (i32.const 45))")) (ELit (LString "        (call $mdk_write_digits (i64.sub (i64.const 0) (local.get $n))))")) (ELit (LString "      (else (call $mdk_write_digits (local.get $n))))")) (ELit (LString "    (call $mdk_write_byte (i32.const 10)))")) (ELit (LString "  (func $mdk_print_bool (param $b i32)")) (ELit (LString "    (if (local.get $b)")) (ELit (LString "      (then")) (ELit (LString "        (call $mdk_write_byte (i32.const 84)) (call $mdk_write_byte (i32.const 114))")) (ELit (LString "        (call $mdk_write_byte (i32.const 117)) (call $mdk_write_byte (i32.const 101)))")) (ELit (LString "      (else")) (ELit (LString "        (call $mdk_write_byte (i32.const 70)) (call $mdk_write_byte (i32.const 97))")) (ELit (LString "        (call $mdk_write_byte (i32.const 108)) (call $mdk_write_byte (i32.const 115))")) (ELit (LString "        (call $mdk_write_byte (i32.const 101))))")) (ELit (LString "    (call $mdk_write_byte (i32.const 10)))"))))
(DTypeSig true "ioStrRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioStrRuntimeLines" () (EListLit (ELit (LString "  ;; ── §6 string byte-write runtime ($str-dependent) ──")) (ELit (LString "  (func $mdk_print_str (param $s (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_byte (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))))")) (ELit (LString "  (func $mdk_print_strln (param $s (ref $str))")) (ELit (LString "    (call $mdk_print_str (local.get $s))")) (ELit (LString "    (call $mdk_write_byte (i32.const 10)))")) (ELit (LString "  ;; intToString : render an i64 in decimal into a fresh $str (cp_count == byte len).")) (ELit (LString "  (func $mdk_int_to_str (param $n i64) (result (ref $str))")) (ELit (LString "    (local $neg i32) (local $m i64) (local $len i32) (local $i i32)")) (ELit (LString "    (local $buf (ref $u8arr)) (local $d i32)")) (ELit (LString "    (local.set $neg (i64.lt_s (local.get $n) (i64.const 0)))")) (ELit (LString "    (local.set $m (if (result i64) (local.get $neg)")) (ELit (LString "      (then (i64.sub (i64.const 0) (local.get $n))) (else (local.get $n))))")) (ELit (LString "    ;; count digits")) (ELit (LString "    (local.set $len (i32.const 1))")) (ELit (LString "    (block $cd (loop $cl")) (ELit (LString "      (br_if $cd (i64.lt_s (local.get $m) (i64.const 10)))")) (ELit (LString "      (local.set $len (i32.add (local.get $len) (i32.const 1)))")) (ELit (LString "      (local.set $m (i64.div_s (local.get $m) (i64.const 10)))")) (ELit (LString "      (br $cl)))")) (ELit (LString "    (local.set $m (if (result i64) (local.get $neg)")) (ELit (LString "      (then (i64.sub (i64.const 0) (local.get $n))) (else (local.get $n))))")) (ELit (LString "    (if (local.get $neg) (then (local.set $len (i32.add (local.get $len) (i32.const 1)))))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $len)))")) (ELit (LString "    ;; fill digits from least-significant (end) backward")) (ELit (LString "    (local.set $i (i32.sub (local.get $len) (i32.const 1)))")) (ELit (LString "    (block $fd (loop $fl")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i)")) (ELit (LString "        (i32.add (i32.const 48) (i32.wrap_i64 (i64.rem_s (local.get $m) (i64.const 10)))))")) (ELit (LString "      (local.set $m (i64.div_s (local.get $m) (i64.const 10)))")) (ELit (LString "      (local.set $i (i32.sub (local.get $i) (i32.const 1)))")) (ELit (LString "      (br_if $fd (i64.eq (local.get $m) (i64.const 0)))")) (ELit (LString "      (br $fl)))")) (ELit (LString "    (if (local.get $neg) (then (array.set $u8arr (local.get $buf) (i32.const 0) (i32.const 45))))")) (ELit (LString "    (struct.new $str (local.get $len) (local.get $buf)))"))))
(DTypeSig true "stderrByteImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "stderrByteImportLines" () (EListLit (ELit (LString "  (import \"env\" \"mdk_write_err_byte\" (func $mdk_write_err_byte (param i32)))"))))
(DTypeSig true "stderrRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "stderrRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 stderr byte-write runtime (ePutStr / ePutStrLn) ──")) (ELit (LString "  (func $mdk_eprint_str (param $s (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_err_byte (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))))")) (ELit (LString "  (func $mdk_eprint_strln (param $s (ref $str))")) (ELit (LString "    (call $mdk_eprint_str (local.get $s))")) (ELit (LString "    (call $mdk_write_err_byte (i32.const 10)))"))))
(DTypeSig true "strLeafRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strLeafRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 string LEAF ops (byte-identical to medaka_rt.c) ──")) (ELit (LString "  ;; count UTF-8 codepoints in a $u8arr over [0,n): every non-continuation byte.")) (ELit (LString "  (func $mdk_cp_count (param $b (ref $u8arr)) (param $n i32) (result i32)")) (ELit (LString "    (local $i i32) (local $c i32) (local $byte i32)")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $c (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $byte (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      ;; a continuation byte has top bits 10xxxxxx, i.e. (byte & 0xC0) == 0x80.")) (ELit (LString "      (if (i32.ne (i32.and (local.get $byte) (i32.const 192)) (i32.const 128))")) (ELit (LString "        (then (local.set $c (i32.add (local.get $c) (i32.const 1)))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $c))")) (ELit (LString "  ;; codepoint index `cpi` -> byte offset into a $u8arr of byte length `n`.")) (ELit (LString "  (func $mdk_byte_off (param $b (ref $u8arr)) (param $n i32) (param $cpi i32) (result i32)")) (ELit (LString "    (local $bo i32) (local $c i32)")) (ELit (LString "    (local.set $bo (i32.const 0)) (local.set $c (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $bo) (local.get $n)))")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $c) (local.get $cpi)))")) (ELit (LString "      (local.set $bo (i32.add (local.get $bo) (i32.const 1)))")) (ELit (LString "      (block $sd (loop $sl")) (ELit (LString "        (br_if $sd (i32.ge_s (local.get $bo) (local.get $n)))")) (ELit (LString "        (br_if $sd (i32.ne (i32.and (array.get_u $u8arr (local.get $b) (local.get $bo)) (i32.const 192)) (i32.const 128)))")) (ELit (LString "        (local.set $bo (i32.add (local.get $bo) (i32.const 1))) (br $sl)))")) (ELit (LString "      (local.set $c (i32.add (local.get $c) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $bo))")) (ELit (LString "  ;; binary string concat (`++`).  cp_count(a++b) == cp_count(a)+cp_count(b).")) (ELit (LString "  (func $mdk_str_append (param $a (ref $str)) (param $b (ref $str)) (result (ref $str))")) (ELit (LString "    (local $ab (ref $u8arr)) (local $bb (ref $u8arr)) (local $al i32) (local $bl i32)")) (ELit (LString "    (local $buf (ref $u8arr)) (local $cpc i32)")) (ELit (LString "    (local.set $ab (struct.get $str $bytes (local.get $a)))")) (ELit (LString "    (local.set $bb (struct.get $str $bytes (local.get $b)))")) (ELit (LString "    (local.set $al (array.len (local.get $ab)))")) (ELit (LString "    (local.set $bl (array.len (local.get $bb)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (i32.add (local.get $al) (local.get $bl))))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $buf) (i32.const 0) (local.get $ab) (i32.const 0) (local.get $al))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $buf) (local.get $al) (local.get $bb) (i32.const 0) (local.get $bl))")) (ELit (LString "    (local.set $cpc (i32.add (struct.get $str $cp_count (local.get $a)) (struct.get $str $cp_count (local.get $b))))")) (ELit (LString "    (struct.new $str (local.get $cpc) (local.get $buf)))")) (ELit (LString "  ;; encode one Unicode codepoint to a fresh $str (1..4 UTF-8 bytes, cp_count 1).")) (ELit (LString "  (func $mdk_char_to_str (param $cp i32) (result (ref $str))")) (ELit (LString "    (local $buf (ref $u8arr))")) (ELit (LString "    (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 128))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 1)))")) (ELit (LString "        (array.set $u8arr (local.get $buf) (i32.const 0) (local.get $cp))")) (ELit (LString "        (struct.new $str (i32.const 1) (local.get $buf)))")) (ELit (LString "      (else (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 2048))")) (ELit (LString "        (then")) (ELit (LString "          (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 2)))")) (ELit (LString "          (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 192) (i32.shr_u (local.get $cp) (i32.const 6))))")) (ELit (LString "          (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "          (struct.new $str (i32.const 1) (local.get $buf)))")) (ELit (LString "        (else (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 65536))")) (ELit (LString "          (then")) (ELit (LString "            (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 3)))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 224) (i32.shr_u (local.get $cp) (i32.const 12))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 2) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "            (struct.new $str (i32.const 1) (local.get $buf)))")) (ELit (LString "          (else")) (ELit (LString "            (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 4)))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 240) (i32.shr_u (local.get $cp) (i32.const 18))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 2) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 3) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "            (struct.new $str (i32.const 1) (local.get $buf)))")) (ELit (LString "          )")) (ELit (LString "        )")) (ELit (LString "      )")) (ELit (LString "    )")) (ELit (LString "  ))")) (ELit (LString "  ;; codepoint-indexed [lo,hi) slice, clamped to [0,cp_count].")) (ELit (LString "  (func $mdk_str_slice (param $lo i32) (param $hi i32) (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $cpc i32) (local $blo i32) (local $bhi i32)")) (ELit (LString "    (local $len i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $cpc (struct.get $str $cp_count (local.get $s)))")) (ELit (LString "    (if (i32.lt_s (local.get $lo) (i32.const 0)) (then (local.set $lo (i32.const 0)))")) (ELit (LString "      (else (if (i32.gt_s (local.get $lo) (local.get $cpc)) (then (local.set $lo (local.get $cpc))))))")) (ELit (LString "    (if (i32.lt_s (local.get $hi) (local.get $lo)) (then (local.set $hi (local.get $lo)))")) (ELit (LString "      (else (if (i32.gt_s (local.get $hi) (local.get $cpc)) (then (local.set $hi (local.get $cpc))))))")) (ELit (LString "    (local.set $blo (call $mdk_byte_off (local.get $b) (local.get $n) (local.get $lo)))")) (ELit (LString "    (local.set $bhi (call $mdk_byte_off (local.get $b) (local.get $n) (local.get $hi)))")) (ELit (LString "    (local.set $len (i32.sub (local.get $bhi) (local.get $blo)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $len)))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $buf) (i32.const 0) (local.get $b) (local.get $blo) (local.get $len))")) (ELit (LString "    (struct.new $str (i32.sub (local.get $hi) (local.get $lo)) (local.get $buf)))")) (ELit (LString "  ;; ASCII upper/lower over BYTES (non-ASCII bytes pass through unchanged).")) (ELit (LString "  (func $mdk_str_upper (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $buf (ref $u8arr)) (local $i i32) (local $c i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (if (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))")) (ELit (LString "        (then (local.set $c (i32.sub (local.get $c) (i32.const 32)))))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $c))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (struct.get $str $cp_count (local.get $s)) (local.get $buf)))")) (ELit (LString "  (func $mdk_str_lower (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $buf (ref $u8arr)) (local $i i32) (local $c i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (if (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))")) (ELit (LString "        (then (local.set $c (i32.add (local.get $c) (i32.const 32)))))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $c))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (struct.get $str $cp_count (local.get $s)) (local.get $buf)))")) (ELit (LString "  ;; ── W9 debug-literal quoting (byte-identical to lib/eval.ml escape_string_lit) ──")) (ELit (LString "  ;; Map ONE source byte to its escaped form, appending into $buf at $bo; returns the")) (ELit (LString "  ;; next write offset.  Specials: \" / ' (whichever == $q) / \\ / \\n / \\t / \\r / NUL.")) (ELit (LString "  ;; All escapes are <backslash><ascii>, so 2 bytes; everything else copies verbatim.")) (ELit (LString "  (func $mdk_dbg_esc_byte (param $buf (ref $u8arr)) (param $bo i32) (param $c i32) (param $q i32) (result i32)")) (ELit (LString "    (local $r i32)")) (ELit (LString "    ;; $r = the char AFTER the backslash for an escaped byte, else -1 (copy verbatim).")) (ELit (LString "    (local.set $r (i32.const -1))")) (ELit (LString "    (if (i32.eq (local.get $c) (local.get $q)) (then (local.set $r (local.get $q))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 92)) (then (local.set $r (i32.const 92))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 10)) (then (local.set $r (i32.const 110))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 9))  (then (local.set $r (i32.const 116))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 13)) (then (local.set $r (i32.const 114))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 0))  (then (local.set $r (i32.const 48))))")) (ELit (LString "    (if (result i32) (i32.eq (local.get $r) (i32.const -1))")) (ELit (LString "      (then")) (ELit (LString "        (array.set $u8arr (local.get $buf) (local.get $bo) (local.get $c))")) (ELit (LString "        (i32.add (local.get $bo) (i32.const 1)))")) (ELit (LString "      (else")) (ELit (LString "        (array.set $u8arr (local.get $buf) (local.get $bo) (i32.const 92))")) (ELit (LString "        (array.set $u8arr (local.get $buf) (i32.add (local.get $bo) (i32.const 1)) (local.get $r))")) (ELit (LString "        (i32.add (local.get $bo) (i32.const 2)))))")) (ELit (LString "  ;; Quote+escape a $str with quote byte $q ('\"' for String, ''' for Char).  Two-pass:")) (ELit (LString "  ;; count escaped output bytes, alloc exact, fill; cp_count via $mdk_cp_count.")) (ELit (LString "  (func $mdk_dbg_quote (param $s (ref $str)) (param $q i32) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $i i32) (local $c i32)")) (ELit (LString "    (local $out i32) (local $buf (ref $u8arr)) (local $bo i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    ;; pass 1: total output bytes = 2 quotes + per-byte (2 if escaped else 1).")) (ELit (LString "    (local.set $out (i32.const 2)) (local.set $i (i32.const 0))")) (ELit (LString "    (block $d1 (loop $l1")) (ELit (LString "      (br_if $d1 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (if (i32.or (i32.or (i32.or (i32.eq (local.get $c) (local.get $q)) (i32.eq (local.get $c) (i32.const 92)))")) (ELit (LString "                          (i32.or (i32.eq (local.get $c) (i32.const 10)) (i32.eq (local.get $c) (i32.const 9))))")) (ELit (LString "                  (i32.or (i32.eq (local.get $c) (i32.const 13)) (i32.eq (local.get $c) (i32.const 0))))")) (ELit (LString "        (then (local.set $out (i32.add (local.get $out) (i32.const 2))))")) (ELit (LString "        (else (local.set $out (i32.add (local.get $out) (i32.const 1)))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l1)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $out)))")) (ELit (LString "    ;; pass 2: opening quote, escaped bytes, closing quote.")) (ELit (LString "    (array.set $u8arr (local.get $buf) (i32.const 0) (local.get $q))")) (ELit (LString "    (local.set $bo (i32.const 1)) (local.set $i (i32.const 0))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $bo (call $mdk_dbg_esc_byte (local.get $buf) (local.get $bo) (local.get $c) (local.get $q)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))")) (ELit (LString "    (array.set $u8arr (local.get $buf) (local.get $bo) (local.get $q))")) (ELit (LString "    (struct.new $str (call $mdk_cp_count (local.get $buf) (local.get $out)) (local.get $buf)))")) (ELit (LString "  ;; debugStringLit : $str -> $str, surround with double-quotes (q = 34).")) (ELit (LString "  (func $mdk_debug_string_lit (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (call $mdk_dbg_quote (local.get $s) (i32.const 34)))")) (ELit (LString "  ;; debugCharLit : Char (i31 codepoint) -> $str, surround with single-quotes (q = 39).")) (ELit (LString "  (func $mdk_debug_char_lit (param $cp i32) (result (ref $str))")) (ELit (LString "    (call $mdk_dbg_quote (call $mdk_char_to_str (local.get $cp)) (i32.const 39)))"))))
(DTypeSig true "strConcatRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strConcatRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 stringConcat (List String) — walk the W7 cons list ──")) (ELit (LString "  (func $mdk_str_concat (param $list (ref eq)) (result (ref $str))")) (ELit (LString "    (local $w (ref eq)) (local $cell (ref $C_Cons)) (local $s (ref $str))")) (ELit (LString "    (local $total i32) (local $cpc i32) (local $off i32) (local $bl i32)")) (ELit (LString "    (local $buf (ref $u8arr)) (local $sb (ref $u8arr))")) (ELit (LString "    ;; pass 1: total byte length + total codepoints.")) (ELit (LString "    (local.set $total (i32.const 0)) (local.set $cpc (i32.const 0))")) (ELit (LString "    (local.set $w (local.get $list))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))")) (ELit (LString "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))")) (ELit (LString "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))")) (ELit (LString "      (local.set $total (i32.add (local.get $total) (array.len (struct.get $str $bytes (local.get $s)))))")) (ELit (LString "      (local.set $cpc (i32.add (local.get $cpc) (struct.get $str $cp_count (local.get $s))))")) (ELit (LString "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l)))")) (ELit (LString "    ;; pass 2: copy each segment's bytes into a flat buffer.")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $total)))")) (ELit (LString "    (local.set $off (i32.const 0))")) (ELit (LString "    (local.set $w (local.get $list))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))")) (ELit (LString "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))")) (ELit (LString "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))")) (ELit (LString "      (local.set $sb (struct.get $str $bytes (local.get $s)))")) (ELit (LString "      (local.set $bl (array.len (local.get $sb)))")) (ELit (LString "      (array.copy $u8arr $u8arr (local.get $buf) (local.get $off) (local.get $sb) (i32.const 0) (local.get $bl))")) (ELit (LString "      (local.set $off (i32.add (local.get $off) (local.get $bl)))")) (ELit (LString "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l2)))")) (ELit (LString "    (struct.new $str (local.get $cpc) (local.get $buf)))"))))
(DTypeSig true "appendRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "appendRuntimeLines" () (EListLit (ELit (LString "  ;; ── W13 runtime-dispatched `++` (String concat OR List append) ──")) (ELit (LString "  ;; List append is ITERATIVE (destination-passing over the mut $C_Cons tail),")) (ELit (LString "  ;; mirroring the native mdk_list_append: walk `a` head-first, struct.new each")) (ELit (LString "  ;; result cell with a placeholder i31 tail, struct.set it into the previous")) (ELit (LString "  ;; cell's mut tail, and after the loop point the final tail at `b`.  O(1) extra")) (ELit (LString "  ;; space, no self-recursion → no wasm-stack growth proportional to length(a).")) (ELit (LString "  (func $mdk_append (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (local $cell (ref $C_Cons))")) (ELit (LString "    (local $result (ref eq))")) (ELit (LString "    (local $dest (ref $C_Cons))")) (ELit (LString "    (local $new (ref $C_Cons))")) (ELit (LString "    ;; String `++`: left is a $str struct → byte concat.")) (ELit (LString "    (if (ref.test (ref $str) (local.get $a))")) (ELit (LString "      (then (return (call $mdk_str_append (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b))))))")) (ELit (LString "    ;; List `++`: a Nil (non-$C_Cons) left → b unchanged.")) (ELit (LString "    (if (i32.eqz (ref.test (ref $C_Cons) (local.get $a)))")) (ELit (LString "      (then (return (local.get $b))))")) (ELit (LString "    ;; First cell: copy head(a), placeholder i31 tail (overwritten before any read).")) (ELit (LString "    (local.set $cell (ref.cast (ref $C_Cons) (local.get $a)))")) (ELit (LString "    (local.set $dest (struct.new $C_Cons (i32.const 0)")) (ELit (LString "      (struct.get $C_Cons 1 (local.get $cell)) (ref.i31 (i32.const 0))))")) (ELit (LString "    (local.set $result (local.get $dest))")) (ELit (LString "    ;; Walk the rest of `a`, appending a fresh cell into the previous mut tail.")) (ELit (LString "    (block $done")) (ELit (LString "      (loop $l")) (ELit (LString "        ;; If tail(cell) is not a Cons (i.e. Nil), we are done.")) (ELit (LString "        (br_if $done (i32.eqz (ref.test (ref $C_Cons)")) (ELit (LString "          (struct.get $C_Cons 2 (local.get $cell)))))")) (ELit (LString "        (local.set $cell (ref.cast (ref $C_Cons)")) (ELit (LString "          (struct.get $C_Cons 2 (local.get $cell))))")) (ELit (LString "        (local.set $new (struct.new $C_Cons (i32.const 0)")) (ELit (LString "          (struct.get $C_Cons 1 (local.get $cell)) (ref.i31 (i32.const 0))))")) (ELit (LString "        (struct.set $C_Cons 2 (local.get $dest) (local.get $new))")) (ELit (LString "        (local.set $dest (local.get $new))")) (ELit (LString "        (br $l)))")) (ELit (LString "    ;; Final tail → b (sharing it, not copying).")) (ELit (LString "    (struct.set $C_Cons 2 (local.get $dest) (local.get $b))")) (ELit (LString "    (local.get $result))"))))
(DTypeSig true "valueEqRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "valueEqRuntimeLines" () (EListLit (ELit (LString "  ;; -- layer-9 runtime-shape-dispatched `==`/`!=` (String byte-equal OR immediate identity) --")) (ELit (LString "  (func $mdk_value_eq (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    ;; both operands are $str structs -> byte equality.")) (ELit (LString "    (if (i32.and (ref.test (ref $str) (local.get $a)) (ref.test (ref $str) (local.get $b)))")) (ELit (LString "      (then (return (ref.i31 (i32.eq")) (ELit (LString "        (i32.const 1)")) (ELit (LString "        (i31.get_u (ref.cast (ref i31) (call $mdk_str_compare (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b)))))))))) ;; Eq == ordinal 1")) (ELit (LString "    ;; A2 (poly-Eq-on-Float): two boxed $float cells have distinct identities, so the")) (ELit (LString "    ;; `ref.eq` fallback would report equal floats as unequal — compare f64 values.")) (ELit (LString "    (if (i32.and (ref.test (ref $float) (local.get $a)) (ref.test (ref $float) (local.get $b)))")) (ELit (LString "      (then (return (ref.i31 (f64.eq")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    ;; otherwise immediate/struct identity (i31 Int/Bool/Char/Unit, or ctor cells).")) (ELit (LString "    ;; layer-17 §2.1: a >2^30 Int is a $boxint struct, so two equal large Ints have")) (ELit (LString "    ;; distinct identities — when either side is a $boxint compare the unboxed i64.")) (ELit (LString "    (if (i32.or (ref.test (ref $boxint) (local.get $a)) (ref.test (ref $boxint) (local.get $b)))")) (ELit (LString "      (then (return (ref.i31 (i64.eq (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))")) (ELit (LString "    (ref.i31 (i32.eqz (i32.eqz (ref.eq (local.get $a) (local.get $b))))))")) (ELit (LString "  ;; -- layer-9 runtime-shape-dispatched ordering (String byte-order OR i31 signed) -> i32 -1/0/1 --")) (ELit (LString "  (func $mdk_value_cmp (param $a (ref eq)) (param $b (ref eq)) (result i32)")) (ELit (LString "    (local $o i32) (local $ia i64) (local $ib i64) (local $fa f64) (local $fb f64)")) (ELit (LString "    (if (i32.and (ref.test (ref $str) (local.get $a)) (ref.test (ref $str) (local.get $b)))")) (ELit (LString "      (then")) (ELit (LString "        ;; $mdk_str_compare -> Ordering i31 (Lt 0 / Eq 1 / Gt 2); map to -1/0/1.")) (ELit (LString "        (local.set $o (i31.get_u (ref.cast (ref i31) (call $mdk_str_compare (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b))))))")) (ELit (LString "        (return (i32.sub (local.get $o) (i32.const 1)))))")) (ELit (LString "    ;; A2 (poly-Ord-on-Float): a boxed $float operand -> f64 compare -> -1/0/1.")) (ELit (LString "    ;; Mirrors the arith helpers' left-operand $float discriminant.  A poly `Ord`")) (ELit (LString "    ;; compare (`a > b` on a Num/Ord type-var param) reaches here with $float cells;")) (ELit (LString "    ;; without this arm $mdk_unbox_int would ref.cast the $float to $boxint -> trap.")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $fa (struct.get $float 0 (ref.cast (ref $float) (local.get $a))))")) (ELit (LString "        (local.set $fb (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))")) (ELit (LString "        (if (f64.lt (local.get $fa) (local.get $fb)) (then (return (i32.const -1))))")) (ELit (LString "        (if (f64.gt (local.get $fa) (local.get $fb)) (then (return (i32.const 1))))")) (ELit (LString "        (return (i32.const 0))))")) (ELit (LString "    ;; layer-17 §2.1: Int compare over the i64 box/unbox seam (handles >2^30 boxed).")) (ELit (LString "    (local.set $ia (call $mdk_unbox_int (local.get $a)))")) (ELit (LString "    (local.set $ib (call $mdk_unbox_int (local.get $b)))")) (ELit (LString "    (if (i64.lt_s (local.get $ia) (local.get $ib)) (then (return (i32.const -1))))")) (ELit (LString "    (if (i64.gt_s (local.get $ia) (local.get $ib)) (then (return (i32.const 1))))")) (ELit (LString "    (i32.const 0))"))))
(DTypeSig true "valueArithRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "valueArithRuntimeLines" () (EListLit (ELit (LString "  ;; -- A0 runtime value-tag-dispatched arithmetic (poly-`Num`: Int i31/$boxint OR $float) --")) (ELit (LString "  (func $mdk_value_add (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (f64.add")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else (call $mdk_box_int (i64.add (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))")) (ELit (LString "  (func $mdk_value_sub (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (f64.sub")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else (call $mdk_box_int (i64.sub (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))")) (ELit (LString "  (func $mdk_value_mul (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (f64.mul")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else (call $mdk_box_int (i64.mul (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))")) (ELit (LString "  (func $mdk_value_div (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (f64.div")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else (call $mdk_box_int (i64.div_s (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))")) (ELit (LString "  (func $mdk_value_mod (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (local $fa f64) (local $fb f64)")) (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $fa (struct.get $float 0 (ref.cast (ref $float) (local.get $a))))")) (ELit (LString "        (local.set $fb (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))")) (ELit (LString "        (struct.new $float (f64.sub (local.get $fa) (f64.mul (local.get $fb) (f64.trunc (f64.div (local.get $fa) (local.get $fb)))))))")) (ELit (LString "      (else (call $mdk_box_int (i64.rem_s (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))")) (ELit (LString "  ;; -- A1 poly-`Ord`/`Eq`-on-Float, NUM-ONLY (no $str): $float f64-eq/cmp else i64 --")) (ELit (LString "  (func $mdk_value_eq_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.eq")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i64.eq (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))")) (ELit (LString "  (func $mdk_value_cmp_num (param $a (ref eq)) (param $b (ref eq)) (result i32)")) (ELit (LString "    (local $fa f64) (local $fb f64) (local $ia i64) (local $ib i64)")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $fa (struct.get $float 0 (ref.cast (ref $float) (local.get $a))))")) (ELit (LString "        (local.set $fb (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))")) (ELit (LString "        (if (f64.lt (local.get $fa) (local.get $fb)) (then (return (i32.const -1))))")) (ELit (LString "        (if (f64.gt (local.get $fa) (local.get $fb)) (then (return (i32.const 1))))")) (ELit (LString "        (return (i32.const 0))))")) (ELit (LString "    (local.set $ia (call $mdk_unbox_int (local.get $a)))")) (ELit (LString "    (local.set $ib (call $mdk_unbox_int (local.get $b)))")) (ELit (LString "    (if (i64.lt_s (local.get $ia) (local.get $ib)) (then (return (i32.const -1))))")) (ELit (LString "    (if (i64.gt_s (local.get $ia) (local.get $ib)) (then (return (i32.const 1))))")) (ELit (LString "    (i32.const 0))"))))
(DTypeSig true "rngStateGlobalLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "rngStateGlobalLines" () (EListLit (ELit (LString "  (global $mdk_rng_state (mut i64) (i64.const 0))"))))
(DTypeSig true "rngRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "rngRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 SplitMix64 RNG (byte-identical to medaka_rt.c) ──")) (ELit (LString "  (func $mdk_next_u64 (result i64)")) (ELit (LString "    (local $z i64)")) (ELit (LString "    (global.set $mdk_rng_state (i64.add (global.get $mdk_rng_state) (i64.const 0x9E3779B97F4A7C15)))")) (ELit (LString "    (local.set $z (global.get $mdk_rng_state))")) (ELit (LString "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 30))) (i64.const 0xBF58476D1CE4E5B9)))")) (ELit (LString "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 27))) (i64.const 0x94D049BB133111EB)))")) (ELit (LString "    (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 31))))")) (ELit (LString "  ;; randomInt lo hi : i32 lo/hi -> i32 in [lo,hi] (INCLUSIVE).  range<=0 -> lo.")) (ELit (LString "  (func $mdk_random_int (param $lo i32) (param $hi i32) (result i32)")) (ELit (LString "    (local $range i32)")) (ELit (LString "    (local.set $range (i32.add (i32.sub (local.get $hi) (local.get $lo)) (i32.const 1)))")) (ELit (LString "    (if (result i32) (i32.le_s (local.get $range) (i32.const 0))")) (ELit (LString "      (then (local.get $lo))")) (ELit (LString "      (else")) (ELit (LString "        (i32.add (local.get $lo)")) (ELit (LString "          (i32.wrap_i64 (i64.rem_u (call $mdk_next_u64) (i64.extend_i32_s (local.get $range))))))))")) (ELit (LString "  (func $mdk_random_bool (result i32)")) (ELit (LString "    (i32.wrap_i64 (i64.and (call $mdk_next_u64) (i64.const 1))))")) (ELit (LString "  (func $mdk_random_char (result i32)")) (ELit (LString "    (i32.add (i32.const 32) (i32.wrap_i64 (i64.rem_u (call $mdk_next_u64) (i64.const 95)))))"))))
(DTypeSig true "hashRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "hashRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 per-type hashers (byte-identical to medaka_rt.c) ──")) (ELit (LString "  ;; SplitMix64 finalizer as a pure mixer (no state update).")) (ELit (LString "  (func $mdk_hash_mix64 (param $x i64) (result i64)")) (ELit (LString "    (local $z i64)")) (ELit (LString "    (local.set $z (i64.add (local.get $x) (i64.const 0x9E3779B97F4A7C15)))")) (ELit (LString "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 30))) (i64.const 0xBF58476D1CE4E5B9)))")) (ELit (LString "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 27))) (i64.const 0x94D049BB133111EB)))")) (ELit (LString "    (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 31))))")) (ELit (LString "  ;; hashInt / hashChar : mix64(value) & 0x3FFFFFFF.  `n` is the untagged i32 value")) (ELit (LString "  ;; sign-extended to i64 (matching medaka_rt.c's signed `tagged>>1`).")) (ELit (LString "  (func $mdk_hash_int (param $n i32) (result i32)")) (ELit (LString "    (i32.wrap_i64 (i64.and (call $mdk_hash_mix64 (i64.extend_i32_s (local.get $n))) (i64.const 0x3FFFFFFF))))")) (ELit (LString "  (func $mdk_hash_bool (param $b i32) (result i32)")) (ELit (LString "    (if (result i32) (local.get $b) (then (i32.const 1)) (else (i32.const 0))))"))))
(DTypeSig true "hashStringRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "hashStringRuntimeLines" () (EListLit (ELit (LString "  ;; hashString : FNV-1a over UTF-8 BYTES, masked.")) (ELit (LString "  (func $mdk_hash_string (param $s (ref $str)) (result i32)")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $i i32) (local $h i64)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $h (i64.const 0xCBF29CE484222325))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $h (i64.mul (i64.xor (local.get $h) (i64.extend_i32_u (array.get_u $u8arr (local.get $b) (local.get $i)))) (i64.const 0x100000001B3)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (i32.wrap_i64 (i64.and (local.get $h) (i64.const 0x3FFFFFFF))))"))))
(DTypeSig true "charClassRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "charClassRuntimeLines" () (EListLit (ELit (LString "  ;; ── W11b ASCII char classification + case mapping (byte-identical to medaka_rt.c) ──")) (ELit (LString "  (func $mdk_char_is_alpha (param $c i32) (result i32)")) (ELit (LString "    (i32.or")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))))")) (ELit (LString "  (func $mdk_char_is_space (param $c i32) (result i32)")) (ELit (LString "    (i32.or")) (ELit (LString "      (i32.eq (local.get $c) (i32.const 32))")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 9)) (i32.le_u (local.get $c) (i32.const 13)))))")) (ELit (LString "  (func $mdk_char_is_upper (param $c i32) (result i32)")) (ELit (LString "    (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90))))")) (ELit (LString "  (func $mdk_char_is_lower (param $c i32) (result i32)")) (ELit (LString "    (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122))))")) (ELit (LString "  ;; charIsPunct: exact set from medaka_rt.c switch — Unicode Pc/Pd/Pe/Pf/Pi/Po/Ps ASCII.")) (ELit (LString "  ;; Included: ! \" # % & ' ( ) * , - . / : ; ? @ [ \\ ] _ { }")) (ELit (LString "  ;; Excluded ($+<=>^`|~): those are Unicode symbols (Sm/Sc/Sk), not punctuation.")) (ELit (LString "  ;; Right-associative OR chain over 23 chars = 22 i32.or nodes.")) (ELit (LString "  (func $mdk_char_is_punct (param $c i32) (result i32)")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 33))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 34))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 35))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 37))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 38))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 39))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 40))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 41))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 42))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 44))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 45))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 46))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 47))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 58))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 59))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 63))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 64))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 91))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 92))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 93))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 95))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 123))")) (ELit (LString "           (i32.eq (local.get $c) (i32.const 125))")) (ELit (LString "    )))))))))))))))))))))))")) (ELit (LString "  (func $mdk_char_to_upper (param $c i32) (result i32)")) (ELit (LString "    (if (result i32)")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))")) (ELit (LString "      (then (i32.sub (local.get $c) (i32.const 32)))")) (ELit (LString "      (else (local.get $c))))")) (ELit (LString "  (func $mdk_char_to_lower (param $c i32) (result i32)")) (ELit (LString "    (if (result i32)")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))")) (ELit (LString "      (then (i32.add (local.get $c) (i32.const 32)))")) (ELit (LString "      (else (local.get $c))))"))))
(DTypeSig true "floatFmtImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "floatFmtImportLines" () (EListLit (ELit (LString "  ;; -- W8b floatToString host seam (%.12g — reproduced JS-side, see run.js) --")) (ELit (LString "  (import \"env\" \"mdk_float_fmt\" (func $mdk_float_fmt (param f64) (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_float_fmt_byte\" (func $mdk_float_fmt_byte (param i32) (result i32)))"))))
(DTypeSig true "floatStrImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "floatStrImportLines" () (EListLit (ELit (LString "  ;; -- stringToFloat host seam (Number() JS-side, see run.js) --")) (ELit (LString "  (import \"env\" \"mdk_str_to_float\" (func $mdk_str_to_float (result f64)))"))))
(DTypeSig true "floatStrRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "floatStrRuntimeLines" () (EListLit (ELit (LString "  ;; stringToFloat : $str -> Option Float (ref eq).")) (ELit (LString "  (func $mdk_string_to_float (param $s (ref $str)) (result (ref eq))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32) (local $d f64)")) (ELit (LString "    (call $mdk_path_reset)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $done (loop $loop")) (ELit (LString "      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_path_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1)))")) (ELit (LString "      (br $loop)))")) (ELit (LString "    (local.set $d (call $mdk_str_to_float))")) (ELit (LString "    ;; Return Some(boxed f64) always — JS Number() returns NaN for unparseable,")) (ELit (LString "    ;; and medaka_rt.c strtod returns Some(NaN) for \"nan\" and None for truly")) (ELit (LString "    ;; unparseable strings.  We mirror: if the result is NaN, return None; if nan")) (ELit (LString "    ;; the string is \"nan\" strtod returns Some(NaN) — but for the medaka use cases")) (ELit (LString "    ;; (float literals, json.mdk numeric strings) the host never returns NaN for")) (ELit (LString "    ;; a valid parse, so a simple NaN->None mapping is correct.")) (ELit (LString "    (if (result (ref eq)) (f64.ne (local.get $d) (local.get $d))")) (ELit (LString "      (then (ref.i31 (i32.const 1)))")) (ELit (LString "      (else (struct.new $C_Some (i32.const 0) (struct.new $float (local.get $d)))))")) (ELit (LString "  )"))))
(DTypeSig true "floatRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "floatRuntimeLines" () (EListLit (ELit (LString "  ;; -- W8b Float runtime (byte-identical to medaka_rt.c) --")) (ELit (LString "  ;; intToFloat : i32 -> boxed (struct $float).")) (ELit (LString "  (func $mdk_int_to_float (param $n i32) (result (ref $float))")) (ELit (LString "    (struct.new $float (f64.convert_i32_s (local.get $n))))")) (ELit (LString "  ;; floatToInt : boxed $float -> i32 (truncate toward zero, matching (int)d).")) (ELit (LString "  (func $mdk_float_to_int (param $f (ref $float)) (result i32)")) (ELit (LString "    (i32.trunc_f64_s (struct.get $float 0 (local.get $f))))")) (ELit (LString "  ;; floatRem a b = a - b*trunc(a/b)  (== C fmod == LLVM frem); backs `Float % Float`.")) (ELit (LString "  (func $mdk_float_rem (param $a f64) (param $b f64) (result f64)")) (ELit (LString "    (f64.sub (local.get $a) (f64.mul (local.get $b) (f64.trunc (f64.div (local.get $a) (local.get $b))))))")) (ELit (LString "  ;; floatToString : the host formats (%.12g + .0 rule) into a cache; copy the bytes")) (ELit (LString "  ;; into a fresh $str.  cp_count == byte_len (the %.12g output is ASCII).")) (ELit (LString "  (func $mdk_float_to_str (param $d f64) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $i i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $n (call $mdk_float_fmt (local.get $d)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (call $mdk_float_fmt_byte (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (local.get $n) (local.get $buf)))"))))
(DTypeSig true "hashFloatRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "hashFloatRuntimeLines" () (EListLit (ELit (LString "  ;; hashFloat : reinterpret the double's bits as i64 -> mix64 -> mask [0,2^30).")) (ELit (LString "  (func $mdk_hash_float (param $f (ref $float)) (result i32)")) (ELit (LString "    (i32.wrap_i64 (i64.and (call $mdk_hash_mix64 (i64.reinterpret_f64 (struct.get $float 0 (local.get $f)))) (i64.const 0x3FFFFFFF))))"))))
(DTypeSig true "randomFloatRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "randomFloatRuntimeLines" () (EListLit (ELit (LString "  ;; randomFloat : SplitMix64 -> f64 in [-1,1) (NOTE the -1 offset — see medaka_rt.c).")) (ELit (LString "  (func $mdk_random_float (result (ref $float))")) (ELit (LString "    (struct.new $float")) (ELit (LString "      (f64.sub")) (ELit (LString "        (f64.mul")) (ELit (LString "          (f64.mul (f64.convert_i64_u (i64.shr_u (call $mdk_next_u64) (i64.const 11)))")) (ELit (LString "                   (f64.const 1.1102230246251565e-16))")) (ELit (LString "          (f64.const 2.0))")) (ELit (LString "        (f64.const 1.0))))"))))
(DTypeSig true "ioHostImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioHostImportLines" () (EListLit (ELit (LString "  ;; -- W12 IO host surface (byte-channel marshaling, see run.js) --")) (ELit (LString "  (import \"env\" \"mdk_path_reset\" (func $mdk_path_reset))")) (ELit (LString "  (import \"env\" \"mdk_path_push\" (func $mdk_path_push (param i32)))")) (ELit (LString "  (import \"env\" \"mdk_read_file\" (func $mdk_read_file (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_file_exists\" (func $mdk_file_exists (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_get_env\" (func $mdk_get_env (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_args_count\" (func $mdk_args_count (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_arg_len\" (func $mdk_arg_len (param i32) (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_arg_byte\" (func $mdk_arg_byte (param i32) (param i32) (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_result_len\" (func $mdk_result_len (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_result_byte\" (func $mdk_result_byte (param i32) (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_exit\" (func $mdk_exit (param i32)))"))))
(DTypeSig true "ioHostRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioHostRuntimeLines" () (EListLit (ELit (LString "  ;; -- W12 IO host-surface runtime --")) (ELit (LString "  ;; push a $str's bytes to the host path buffer (reset first).")) (ELit (LString "  (func $mdk_push_path (param $s (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (call $mdk_path_reset)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_path_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    )")) (ELit (LString "  ;; rebuild a fresh $str from the host result buffer (length + byte-at-index).")) (ELit (LString "  ;; cp_count is the true UTF-8 codepoint count (count lead bytes: those whose top")) (ELit (LString "  ;; two bits are NOT 0b10, i.e. (b & 0xC0) != 0x80).  A byte-length approximation")) (ELit (LString "  ;; here is WRONG for any multibyte content: $mdk_str_to_chars allocates its output")) (ELit (LString "  ;; $arr to cp_count and the lexer reads arrayLength as the char count, so an inflated")) (ELit (LString "  ;; cp_count appends trailing NUL chars past the real codepoints -> a stray '\\0' falls")) (ELit (LString "  ;; through every clause head and traps (a file with a single em-dash comment was enough).")) (ELit (LString "  (func $mdk_io_result_to_str (result (ref $str))")) (ELit (LString "    (local $n i32) (local $i i32) (local $buf (ref $u8arr)) (local $cpc i32) (local $b i32)")) (ELit (LString "    (local.set $n (call $mdk_result_len))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $cpc (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $b (call $mdk_result_byte (local.get $i)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $b))")) (ELit (LString "      (if (i32.ne (i32.and (local.get $b) (i32.const 192)) (i32.const 128))")) (ELit (LString "        (then (local.set $cpc (i32.add (local.get $cpc) (i32.const 1)))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (local.get $cpc) (local.get $buf)))")) (ELit (LString "  ;; readFile : $str path -> Result String String.  1=Ok contents / 0=Err message.")) (ELit (LString "  (func $mdk_read_file_io (param $path (ref $str)) (result (ref eq))")) (ELit (LString "    (local $st i32)")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (local.set $st (call $mdk_read_file))")) (ELit (LString "    (if (result (ref eq)) (local.get $st)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (call $mdk_io_result_to_str)))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))")) (ELit (LString "  ;; fileExists : $str path -> Bool (i31 ordinal: False=0 / True=1).")) (ELit (LString "  (func $mdk_file_exists_io (param $path (ref $str)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (ref.i31 (call $mdk_file_exists)))")) (ELit (LString "  ;; getEnv : $str name -> Option String.  1=Some value / 0=None.")) (ELit (LString "  (func $mdk_get_env_io (param $name (ref $str)) (result (ref eq))")) (ELit (LString "    (local $st i32)")) (ELit (LString "    (call $mdk_push_path (local.get $name))")) (ELit (LString "    (local.set $st (call $mdk_get_env))")) (ELit (LString "    (if (result (ref eq)) (local.get $st)")) (ELit (LString "      (then (struct.new $C_Some (i32.const 0) (call $mdk_io_result_to_str)))")) (ELit (LString "      (else (ref.i31 (i32.const 1)))))"))))
(DTypeSig true "ioArgsRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioArgsRuntimeLines" () (EListLit (ELit (LString "  ;; build a $str from the i-th host arg (mdk_arg_len(i) + mdk_arg_byte(i,j)).")) (ELit (LString "  (func $mdk_arg_to_str (param $idx i32) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $j i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $n (call $mdk_arg_len (local.get $idx)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $j (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $j) (local.get $n)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $j) (call $mdk_arg_byte (local.get $idx) (local.get $j)))")) (ELit (LString "      (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (local.get $n) (local.get $buf)))")) (ELit (LString "  ;; args : Unit -> List String.  Fold a Cons chain right-to-left ending in Nil.")) (ELit (LString "  (func $mdk_args_io (result (ref eq))")) (ELit (LString "    (local $c i32) (local $i i32) (local $acc (ref eq))")) (ELit (LString "    (local.set $c (call $mdk_args_count))")) (ELit (LString "    (local.set $acc (ref.i31 (i32.const 1)))")) (ELit (LString "    (local.set $i (i32.sub (local.get $c) (i32.const 1)))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.lt_s (local.get $i) (i32.const 0)))")) (ELit (LString "      (local.set $acc (struct.new $C_Cons (i32.const 0) (call $mdk_arg_to_str (local.get $i)) (local.get $acc)))")) (ELit (LString "      (local.set $i (i32.sub (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $acc))"))))
(DTypeSig true "fileBytesHostImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "fileBytesHostImportLines" () (EListLit (ELit (LString "  ;; -- stage-D writeFileBytes host imports (path via mdk_path_push; bytes streamed) --")) (ELit (LString "  (import \"env\" \"mdk_write_file_reset\" (func $mdk_write_file_reset))")) (ELit (LString "  (import \"env\" \"mdk_write_file_push\" (func $mdk_write_file_push (param i32)))")) (ELit (LString "  (import \"env\" \"mdk_write_file_commit\" (func $mdk_write_file_commit (result i32)))"))))
(DTypeSig true "fileBytesRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "fileBytesRuntimeLines" () (EListLit (ELit (LString "  ;; -- stage-D byte-clean file I/O runtime --")) (ELit (LString "  ;; readFileBytes : $str path -> Result String (Array Int).  1=Ok bytes / 0=Err msg.")) (ELit (LString "  ;; Reuses the read byte-channel but rebuilds an $arr of i31 Int bytes (0..255).")) (ELit (LString "  (func $mdk_read_file_bytes_io (param $path (ref $str)) (result (ref eq))")) (ELit (LString "    (local $st i32) (local $n i32) (local $i i32) (local $out (ref $arr))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (local.set $st (call $mdk_read_file))")) (ELit (LString "    (if (result (ref eq)) (local.get $st)")) (ELit (LString "      (then")) (ELit (LString "        (local.set $n (call $mdk_result_len))")) (ELit (LString "        (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $n)))")) (ELit (LString "        (local.set $i (i32.const 0))")) (ELit (LString "        (block $d (loop $l")) (ELit (LString "          (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "          (array.set $arr (local.get $out) (local.get $i) (ref.i31 (call $mdk_result_byte (local.get $i))))")) (ELit (LString "          (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "        (struct.new $C_Ok (i32.const 0) (local.get $out)))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))")) (ELit (LString "  ;; writeFileBytes : $str path -> $arr bytes -> Result String Unit.  1=Ok () / 0=Err msg.")) (ELit (LString "  ;; Stream each i31 byte (masked to 0..255) to the host, then commit fs.writeFileSync.")) (ELit (LString "  (func $mdk_write_file_bytes_io (param $path (ref $str)) (param $ba (ref $arr)) (result (ref eq))")) (ELit (LString "    (local $st i32) (local $n i32) (local $i i32)")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (call $mdk_write_file_reset)")) (ELit (LString "    (local.set $n (array.len (local.get $ba)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_file_push (i32.and (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $ba) (local.get $i)))) (i32.const 255)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.set $st (call $mdk_write_file_commit))")) (ELit (LString "    (if (result (ref eq)) (local.get $st)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig true "strSearchRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strSearchRuntimeLines" () (EListLit (ELit (LString "  ;; -- W8b stringIndexOf / stringCompare (byte-identical to medaka_rt.c) --")) (ELit (LString "  (func $mdk_str_index_of (param $needle (ref $str)) (param $hay (ref $str)) (result (ref eq))")) (ELit (LString "    (local $nb (ref $u8arr)) (local $hb (ref $u8arr)) (local $nl i32) (local $hl i32)")) (ELit (LString "    (local $b i32) (local $j i32) (local $ok i32)")) (ELit (LString "    (local.set $nb (struct.get $str $bytes (local.get $needle)))")) (ELit (LString "    (local.set $hb (struct.get $str $bytes (local.get $hay)))")) (ELit (LString "    (local.set $nl (array.len (local.get $nb)))")) (ELit (LString "    (local.set $hl (array.len (local.get $hb)))")) (ELit (LString "    ;; empty needle -> Some 0 (codepoint index 0).")) (ELit (LString "    (if (i32.eqz (local.get $nl))")) (ELit (LString "      (then (return (struct.new $C_Some (i32.const 0) (ref.i31 (i32.const 0))))))")) (ELit (LString "    (local.set $b (i32.const 0))")) (ELit (LString "    (block $done (loop $scan")) (ELit (LString "      ;; while b + nl <= hl")) (ELit (LString "      (br_if $done (i32.gt_s (i32.add (local.get $b) (local.get $nl)) (local.get $hl)))")) (ELit (LString "      (local.set $ok (i32.const 1))")) (ELit (LString "      (local.set $j (i32.const 0))")) (ELit (LString "      (block $cmpd (loop $cmpl")) (ELit (LString "        (br_if $cmpd (i32.ge_s (local.get $j) (local.get $nl)))")) (ELit (LString "        (if (i32.ne (array.get_u $u8arr (local.get $hb) (i32.add (local.get $b) (local.get $j)))")) (ELit (LString "                    (array.get_u $u8arr (local.get $nb) (local.get $j)))")) (ELit (LString "          (then (local.set $ok (i32.const 0)) (br $cmpd)))")) (ELit (LString "        (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $cmpl)))")) (ELit (LString "      (if (local.get $ok)")) (ELit (LString "        (then (return (struct.new $C_Some (i32.const 0)")) (ELit (LString "          (ref.i31 (call $mdk_cp_count (local.get $hb) (local.get $b)))))))")) (ELit (LString "      (local.set $b (i32.add (local.get $b) (i32.const 1))) (br $scan)))")) (ELit (LString "    ;; not found -> None (i31 ordinal 1).")) (ELit (LString "    (ref.i31 (i32.const 1)))")) (ELit (LString "  (func $mdk_str_compare (param $a (ref $str)) (param $b (ref $str)) (result (ref eq))")) (ELit (LString "    (local $ab (ref $u8arr)) (local $bb (ref $u8arr)) (local $al i32) (local $bl i32)")) (ELit (LString "    (local $m i32) (local $i i32) (local $ca i32) (local $cb i32)")) (ELit (LString "    (local.set $ab (struct.get $str $bytes (local.get $a)))")) (ELit (LString "    (local.set $bb (struct.get $str $bytes (local.get $b)))")) (ELit (LString "    (local.set $al (array.len (local.get $ab)))")) (ELit (LString "    (local.set $bl (array.len (local.get $bb)))")) (ELit (LString "    (local.set $m (if (result i32) (i32.lt_s (local.get $al) (local.get $bl))")) (ELit (LString "      (then (local.get $al)) (else (local.get $bl))))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $done (loop $l")) (ELit (LString "      (br_if $done (i32.ge_s (local.get $i) (local.get $m)))")) (ELit (LString "      (local.set $ca (array.get_u $u8arr (local.get $ab) (local.get $i)))")) (ELit (LString "      (local.set $cb (array.get_u $u8arr (local.get $bb) (local.get $i)))")) (ELit (LString "      ;; byte less -> Lt (i31 0); byte greater -> Gt (i31 2).")) (ELit (LString "      (if (i32.lt_u (local.get $ca) (local.get $cb)) (then (return (ref.i31 (i32.const 0)))))")) (ELit (LString "      (if (i32.gt_u (local.get $ca) (local.get $cb)) (then (return (ref.i31 (i32.const 2)))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    ;; common prefix equal: shorter < longer; equal length -> Eq.")) (ELit (LString "    (if (i32.lt_s (local.get $al) (local.get $bl)) (then (return (ref.i31 (i32.const 0)))))")) (ELit (LString "    (if (i32.gt_s (local.get $al) (local.get $bl)) (then (return (ref.i31 (i32.const 2)))))")) (ELit (LString "    (ref.i31 (i32.const 1)))"))))
(DTypeSig true "strCodecRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strCodecRuntimeLines" () (EListLit (ELit (LString "  ;; -- W11b UTF-8 codec (byte-identical to medaka_rt.c) --")) (ELit (LString "  ;; decode a $str's UTF-8 bytes into a fresh $arr of cp_count i31 Char codepoints.")) (ELit (LString "  (func $mdk_str_to_chars (param $s (ref $str)) (result (ref $arr))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $cpc i32) (local $out (ref $arr))")) (ELit (LString "    (local $bo i32) (local $oi i32) (local $lead i32) (local $cp i32) (local $k i32) (local $w i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $cpc (struct.get $str $cp_count (local.get $s)))")) (ELit (LString "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $cpc)))")) (ELit (LString "    (local.set $bo (i32.const 0)) (local.set $oi (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $bo) (local.get $n)))")) (ELit (LString "      (local.set $lead (array.get_u $u8arr (local.get $b) (local.get $bo)))")) (ELit (LString "      ;; lead-byte class → codepoint seed bits + total byte width.")) (ELit (LString "      (if (i32.lt_u (local.get $lead) (i32.const 128))")) (ELit (LString "        (then (local.set $cp (local.get $lead)) (local.set $w (i32.const 1)))")) (ELit (LString "        (else (if (i32.lt_u (local.get $lead) (i32.const 224))")) (ELit (LString "          (then (local.set $cp (i32.and (local.get $lead) (i32.const 31))) (local.set $w (i32.const 2)))")) (ELit (LString "          (else (if (i32.lt_u (local.get $lead) (i32.const 240))")) (ELit (LString "            (then (local.set $cp (i32.and (local.get $lead) (i32.const 15))) (local.set $w (i32.const 3)))")) (ELit (LString "            (else (local.set $cp (i32.and (local.get $lead) (i32.const 7))) (local.set $w (i32.const 4))))))))")) (ELit (LString "      ;; fold in (w-1) continuation bytes: cp = (cp << 6) | (byte & 0x3F).")) (ELit (LString "      (local.set $k (i32.const 1))")) (ELit (LString "      (block $cd (loop $cl")) (ELit (LString "        (br_if $cd (i32.ge_s (local.get $k) (local.get $w)))")) (ELit (LString "        (local.set $cp (i32.or (i32.shl (local.get $cp) (i32.const 6))")) (ELit (LString "          (i32.and (array.get_u $u8arr (local.get $b) (i32.add (local.get $bo) (local.get $k))) (i32.const 63))))")) (ELit (LString "        (local.set $k (i32.add (local.get $k) (i32.const 1))) (br $cl)))")) (ELit (LString "      (array.set $arr (local.get $out) (local.get $oi) (ref.i31 (local.get $cp)))")) (ELit (LString "      (local.set $oi (i32.add (local.get $oi) (i32.const 1)))")) (ELit (LString "      (local.set $bo (i32.add (local.get $bo) (local.get $w))) (br $l)))")) (ELit (LString "    (local.get $out))")) (ELit (LString "  ;; number of UTF-8 bytes a codepoint encodes to (1..4).")) (ELit (LString "  (func $mdk_utf8_nbytes (param $cp i32) (result i32)")) (ELit (LString "    (if (result i32) (i32.lt_u (local.get $cp) (i32.const 128)) (then (i32.const 1))")) (ELit (LString "      (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 2048)) (then (i32.const 2))")) (ELit (LString "        (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 65536)) (then (i32.const 3))")) (ELit (LString "          (else (i32.const 4))))))))")) (ELit (LString "  ;; encode one codepoint into $buf at offset $off; return the next offset.")) (ELit (LString "  (func $mdk_utf8_emit_at (param $buf (ref $u8arr)) (param $off i32) (param $cp i32) (result i32)")) (ELit (LString "    (if (result i32) (i32.lt_u (local.get $cp) (i32.const 128))")) (ELit (LString "      (then")) (ELit (LString "        (array.set $u8arr (local.get $buf) (local.get $off) (local.get $cp))")) (ELit (LString "        (i32.add (local.get $off) (i32.const 1)))")) (ELit (LString "      (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 2048))")) (ELit (LString "        (then")) (ELit (LString "          (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 192) (i32.shr_u (local.get $cp) (i32.const 6))))")) (ELit (LString "          (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "          (i32.add (local.get $off) (i32.const 2)))")) (ELit (LString "        (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 65536))")) (ELit (LString "          (then")) (ELit (LString "            (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 224) (i32.shr_u (local.get $cp) (i32.const 12))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 2)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "            (i32.add (local.get $off) (i32.const 3)))")) (ELit (LString "          (else")) (ELit (LString "            (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 240) (i32.shr_u (local.get $cp) (i32.const 18))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 2)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 3)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "            (i32.add (local.get $off) (i32.const 4))))))))")) (ELit (LString "  )")) (ELit (LString "  ;; encode an $arr of i31 Char codepoints into a fresh $str (UTF-8); cp_count = len.")) (ELit (LString "  (func $mdk_chars_to_str (param $a (ref $arr)) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $i i32) (local $total i32) (local $off i32)")) (ELit (LString "    (local $buf (ref $u8arr)) (local $cp i32)")) (ELit (LString "    (local.set $n (array.len (local.get $a)))")) (ELit (LString "    ;; pass 1: total encoded byte length.")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $total (i32.const 0))")) (ELit (LString "    (block $d1 (loop $l1")) (ELit (LString "      (br_if $d1 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $cp (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))))")) (ELit (LString "      (local.set $total (i32.add (local.get $total) (call $mdk_utf8_nbytes (local.get $cp))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l1)))")) (ELit (LString "    ;; pass 2: encode into the buffer.")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $total)))")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $off (i32.const 0))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $cp (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))))")) (ELit (LString "      (local.set $off (call $mdk_utf8_emit_at (local.get $buf) (local.get $off) (local.get $cp)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))")) (ELit (LString "    (struct.new $str (local.get $n) (local.get $buf)))")) (ELit (LString "  ;; stringToUtf8Bytes: copy the $str's $u8arr backing into a fresh $arr of i31 Int bytes.")) (ELit (LString "  (func $mdk_str_to_utf8_bytes (param $s (ref $str)) (result (ref $arr))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $out (ref $arr)) (local $i i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $arr (local.get $out) (local.get $i) (ref.i31 (array.get_u $u8arr (local.get $b) (local.get $i))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $out))")) (ELit (LString "  ;; stringFromUtf8Bytes: blit the low 8 bits of each i31 Int into a $u8arr; recompute")) (ELit (LString "  ;; cp_count by the non-continuation-byte rule (byte-identical to medaka_rt.c mdk_str_lit).")) (ELit (LString "  (func $mdk_utf8_bytes_to_str (param $a (ref $arr)) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $buf (ref $u8arr)) (local $i i32) (local $cpc i32) (local $byte i32)")) (ELit (LString "    (local.set $n (array.len (local.get $a)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $cpc (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $byte (i32.and (i31.get_u (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))) (i32.const 255)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $byte))")) (ELit (LString "      (if (i32.ne (i32.and (local.get $byte) (i32.const 192)) (i32.const 128))")) (ELit (LString "        (then (local.set $cpc (i32.add (local.get $cpc) (i32.const 1)))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (local.get $cpc) (local.get $buf)))"))))
(DTypeSig true "charFromCodeRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "charFromCodeRuntimeLines" () (EListLit (ELit (LString "  ;; -- W11b charFromCode (byte-identical to medaka_rt.c mdk_char_from_code) --")) (ELit (LString "  (func $mdk_char_from_code (param $cp i32) (result (ref eq))")) (ELit (LString "    ;; valid: 0 <= cp <= 0x10FFFF and not (0xD800 <= cp <= 0xDFFF).")) (ELit (LString "    (if (i32.and (i32.and (i32.ge_s (local.get $cp) (i32.const 0)) (i32.le_s (local.get $cp) (i32.const 1114111)))")) (ELit (LString "                 (i32.eqz (i32.and (i32.ge_s (local.get $cp) (i32.const 55296)) (i32.le_s (local.get $cp) (i32.const 57343)))))")) (ELit (LString "      (then (return (struct.new $C_Some (i32.const 0) (ref.i31 (local.get $cp))))))")) (ELit (LString "    (ref.i31 (i32.const 1)))"))))
