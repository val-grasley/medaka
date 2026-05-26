open Medaka_lib
open Eval

let parse src =
  Lexer.reset ();
  let lexbuf = Lexing.from_string src in
  try Parser.program Lexer.token lexbuf
  with Parser.Error ->
    let pos = lexbuf.Lexing.lex_curr_p in
    failwith (Printf.sprintf "Parse error at line %d col %d in:\n%s"
                pos.Lexing.pos_lnum
                (pos.Lexing.pos_cnum - pos.Lexing.pos_bol)
                src)

(* Run src and return the value bound to name *)
let run src name =
  let prog = parse src in
  let env  = eval_program prog in
  match List.assoc_opt name env with
  | Some v -> v
  | None ->
    failwith (Printf.sprintf "Name '%s' not in env.\nEnv: %s\nSource:\n%s"
                name
                (String.concat ", " (List.map fst env))
                src)

(* Assert that name evaluates to the expected value *)
let assert_val src name expected () =
  let actual = run src name in
  if actual <> expected then
    failwith (Printf.sprintf
      "Expected %s = %s\nGot: %s\n\nSource:\n%s"
      name (pp_value expected) (pp_value actual) src)

(* Assert that evaluation raises Eval_error *)
let assert_runtime_err src name () =
  match (try Some (run src name) with Eval_error _ -> None) with
  | None -> ()
  | Some v ->
    failwith (Printf.sprintf
      "Expected runtime error, but got: %s\n\nSource:\n%s"
      (pp_value v) src)

(* ── Constants ──────────────────────────────────────────────────────────── *)

let t_int    = assert_val "x = 42\n"      "x" (VInt 42)
let t_float  = assert_val "x = 3.14\n"   "x" (VFloat 3.14)
let t_string = assert_val "x = \"hi\"\n" "x" (VString "hi")
let t_bool   = assert_val "x = True\n"   "x" (VBool true)
let t_unit   = assert_val "x = ()\n"     "x" VUnit

(* ── Arithmetic ─────────────────────────────────────────────────────────── *)

let t_add  = assert_val "x = 2 + 3\n"  "x" (VInt 5)
let t_sub  = assert_val "x = 10 - 4\n" "x" (VInt 6)
let t_mul  = assert_val "x = 3 * 4\n"  "x" (VInt 12)
let t_div  = assert_val "x = 10 / 2\n" "x" (VInt 5)
let t_neg  = assert_val "x = -(5)\n"   "x" (VInt (-5))

let t_concat = assert_val {|x = "hello" <> " world"
|} "x" (VString "hello world")

(* ── If / let ───────────────────────────────────────────────────────────── *)

let t_if_true  = assert_val "x = if True  then 1 else 2\n" "x" (VInt 1)
let t_if_false = assert_val "x = if False then 1 else 2\n" "x" (VInt 2)

let t_let = assert_val {|x =
  let a = 3
  let b = 4
  a + b
|} "x" (VInt 7)

(* ── Lambdas ────────────────────────────────────────────────────────────── *)

let t_id = assert_val {|id x = x
r = id 42
|} "r" (VInt 42)

let t_const = assert_val {|const x _ = x
r = const 7 99
|} "r" (VInt 7)

let t_partial = assert_val {|add x y = x + y
add3 = add 3
r = add3 4
|} "r" (VInt 7)

(* ── Recursion ──────────────────────────────────────────────────────────── *)

let t_factorial = assert_val {|fact n =
  if n <= 1 then 1 else n * fact (n - 1)
r = fact 5
|} "r" (VInt 120)

let t_list_len = assert_val {|len xs =
  match xs
    [] => 0
    (x :: rest) => 1 + len rest
r = len ([1, 2, 3, 4])
|} "r" (VInt 4)

(* ── Pattern matching ───────────────────────────────────────────────────── *)

let t_match_lit = assert_val {|classify n =
  match n
    0 => "zero"
    1 => "one"
    _ => "other"
r = classify 1
|} "r" (VString "one")

let t_match_tuple = assert_val {|swap p =
  match p
    (a, b) => (b, a)
r = swap (1, 2)
|} "r" (VTuple [VInt 2; VInt 1])

let t_match_guard = assert_val {|sign n =
  match n
    x if x > 0 => 1
    x if x < 0 => -1
    _ => 0
r = sign (-3)
|} "r" (VInt (-1))

let t_match_constructor = assert_val {|data Shape = Circle Int | Square Int
area s =
  match s
    Circle r => r * r
    Square w => w * w
r = area (Circle 5)
|} "r" (VInt 25)

let t_match_list_head = assert_val {|head_or_zero xs =
  match xs
    [] => 0
    (x :: _) => x
r = head_or_zero ([10, 20, 30])
|} "r" (VInt 10)

let t_as_pattern_head = assert_val {|first_and_all xs =
  match xs
    ys@(x::_) => (x, ys)
    ys@[] => (0, ys)
r = first_and_all ([10, 20, 30])
|} "r" (VTuple [VInt 10; VList [VInt 10; VInt 20; VInt 30]])

let t_as_pattern_empty = assert_val {|first_and_all xs =
  match xs
    ys@(x::_) => (x, ys)
    ys@[] => (0, ys)
r = first_and_all ([])
|} "r" (VTuple [VInt 0; VList []])

(* ── Records ────────────────────────────────────────────────────────────── *)

let t_record = assert_val {|record Point
  x : Int
  y : Int
p = Point { x = 3, y = 4 }
r = p.x + p.y
|} "r" (VInt 7)

let t_record_update = assert_val {|record Point
  x : Int
  y : Int
p = Point { x = 3, y = 4 }
p2 = { p | x = 10 }
r = p2.x
|} "r" (VInt 10)

(* ── Tuples ─────────────────────────────────────────────────────────────── *)

let t_tuple = assert_val {|r = (1, "hello", True)
|} "r" (VTuple [VInt 1; VString "hello"; VBool true])

(* ── Lists ──────────────────────────────────────────────────────────────── *)

let t_list_lit  = assert_val "r = [1, 2, 3]\n" "r" (VList [VInt 1; VInt 2; VInt 3])
let t_list_cons = assert_val "r = 0 :: ([1, 2])\n" "r" (VList [VInt 0; VInt 1; VInt 2])

let t_map = assert_val {|double x = x * 2
r = map double ([1, 2, 3])
|} "r" (VList [VInt 2; VInt 4; VInt 6])

let t_filter = assert_val {|is_even x = x == 0 || x == 2 || x == 4 || x == 6
r = filter is_even ([1, 2, 3, 4, 5, 6])
|} "r" (VList [VInt 2; VInt 4; VInt 6])

let t_fold = assert_val {|r = fold (x => y => x + y) 0 ([1, 2, 3, 4, 5])
|} "r" (VInt 15)

(* ── Pipe operator ──────────────────────────────────────────────────────── *)

let t_pipe = assert_val {|double x = x * 2
r = 5 |> double
|} "r" (VInt 10)

let t_compose = assert_val {|double x = x * 2
inc x = x + 1
double_then_inc = double >> inc
r = double_then_inc 3
|} "r" (VInt 7)

(* ── do-block: Option monad ─────────────────────────────────────────────── *)

let t_do_option_some = assert_val {|r = do
  x <- Some 5
  y <- Some 3
  pure (x + y)
|} "r" (VCon ("Some", [VInt 8]))

let t_do_option_none = assert_val {|r = do
  x <- Some 5
  _ <- None
  pure x
|} "r" (VCon ("None", []))

(* ── do-block: Result monad ─────────────────────────────────────────────── *)

let t_do_result_ok = assert_val {|r = do
  x <- Ok 10
  y <- Ok 5
  pure (x - y)
|} "r" (VCon ("Ok", [VInt 5]))

let t_do_result_err = assert_val {|r = do
  x <- Ok 10
  _ <- Err "oops"
  pure x
|} "r" (VCon ("Err", [VString "oops"]))

(* ── Ref mutation ───────────────────────────────────────────────────────── *)

(* Use an Option bind to establish monad context so pure wraps the result *)
let t_ref = assert_val {|r = do
  _ <- Some ()
  let mut count = Ref 0
  set_ref count 42
  pure count.value
|} "r" (VCon ("Some", [VInt 42]))

(* ── Runtime errors ─────────────────────────────────────────────────────── *)

(* ── Phase 17: Float arithmetic and modulo ──────────────────────────── *)
let t_float_add = assert_val "x = 1.5 + 2.0\n" "x" (VFloat 3.5)
let t_float_mul = assert_val "x = 3.0 * 2.0\n" "x" (VFloat 6.0)
let t_int_mod   = assert_val "x = 10 % 3\n"    "x" (VInt 1)

let t_div_by_zero = assert_runtime_err "x = 1 / 0\n" "x"
let t_match_fail  = assert_runtime_err {|r =
  match 5
    0 => "zero"
|} "r"

(* ── Where clauses ──────────────────────────────────────────────────────── *)

let t_where_single = assert_val {|r = double 5 where
    double x = x * 2
|} "r" (VInt 10)

let t_where_multi = assert_val {|r = double 5 + triple 5 where
    double x = x * 2
    triple x = x * 3
|} "r" (VInt 25)

let t_where_sequential = assert_val {|r = result where
    base = 10
    result = base + 5
|} "r" (VInt 15)

let t_where_nested = assert_val {|r = outer 3 where
    outer n = inner n + 1 where
        inner k = k * 2
|} "r" (VInt 7)

(* ── Top-level function guards ──────────────────────────────────────────── *)

let t_guard_basic_neg = assert_val {|
classify n
  | n < 0 = "neg"
  | n > 0 = "pos"
  | True = "zero"
r = classify (-3)
|} "r" (VString "neg")

let t_guard_basic_pos = assert_val {|
classify n
  | n < 0 = "neg"
  | n > 0 = "pos"
  | True = "zero"
r = classify 5
|} "r" (VString "pos")

let t_guard_basic_zero = assert_val {|
classify n
  | n < 0 = "neg"
  | n > 0 = "pos"
  | True = "zero"
r = classify 0
|} "r" (VString "zero")

let t_guard_non_exhaustive = assert_runtime_err {|
f x
  | x > 0 = 1
r = f 0
|} "r"

(* ── Multi-impl dispatch (VMulti) ───────────────────────────────────────── *)

(* Three impls for the same interface method 'describe'.
   Each impl uses constructor-specific patterns (no bare wildcards) that are
   structurally disjoint across types, mirroring how stdlib impls are written. *)

let dispatch_iface = {|
interface Describable f where
    describe : f -> String

impl Describable (List a) where
    describe [] = "empty-list"
    describe (_::_) = "list"

impl Describable (Option a) where
    describe None = "none"
    describe (Some _) = "some"
|}

let t_dispatch_list = assert_val (dispatch_iface ^ {|
r = describe ([1, 2, 3])
|}) "r" (VString "list")

let t_dispatch_option_some = assert_val (dispatch_iface ^ {|
r = describe (Some 42)
|}) "r" (VString "some")

let t_dispatch_option_none = assert_val (dispatch_iface ^ {|
r = describe (None)
|}) "r" (VString "none")

let t_dispatch_list_empty = assert_val (dispatch_iface ^ {|
r = describe ([])
|}) "r" (VString "empty-list")

(* ── Test registration ──────────────────────────────────────────────────── *)

let () =
  let open Alcotest in
  run "eval" [
    "constants", [
      test_case "int"    `Quick t_int;
      test_case "float"  `Quick t_float;
      test_case "string" `Quick t_string;
      test_case "bool"   `Quick t_bool;
      test_case "unit"   `Quick t_unit;
    ];
    "arithmetic", [
      test_case "add"    `Quick t_add;
      test_case "sub"    `Quick t_sub;
      test_case "mul"    `Quick t_mul;
      test_case "div"    `Quick t_div;
      test_case "neg"    `Quick t_neg;
      test_case "concat" `Quick t_concat;
    ];
    "control flow", [
      test_case "if_true"  `Quick t_if_true;
      test_case "if_false" `Quick t_if_false;
      test_case "let"      `Quick t_let;
    ];
    "lambdas", [
      test_case "identity" `Quick t_id;
      test_case "const"    `Quick t_const;
      test_case "partial"  `Quick t_partial;
    ];
    "recursion", [
      test_case "factorial" `Quick t_factorial;
      test_case "list_len"  `Quick t_list_len;
    ];
    "pattern match", [
      test_case "literal"     `Quick t_match_lit;
      test_case "tuple"       `Quick t_match_tuple;
      test_case "guard"       `Quick t_match_guard;
      test_case "constructor" `Quick t_match_constructor;
      test_case "list_head"       `Quick t_match_list_head;
      test_case "as-pattern cons" `Quick t_as_pattern_head;
      test_case "as-pattern nil"  `Quick t_as_pattern_empty;
    ];
    "records", [
      test_case "create" `Quick t_record;
      test_case "update" `Quick t_record_update;
    ];
    "tuples", [
      test_case "create" `Quick t_tuple;
    ];
    "lists", [
      test_case "literal" `Quick t_list_lit;
      test_case "cons"    `Quick t_list_cons;
      test_case "map"     `Quick t_map;
      test_case "filter"  `Quick t_filter;
      test_case "fold"    `Quick t_fold;
    ];
    "pipe/compose", [
      test_case "pipe"    `Quick t_pipe;
      test_case "compose" `Quick t_compose;
    ];
    "do Option", [
      test_case "some" `Quick t_do_option_some;
      test_case "none" `Quick t_do_option_none;
    ];
    "do Result", [
      test_case "ok"  `Quick t_do_result_ok;
      test_case "err" `Quick t_do_result_err;
    ];
    "ref mutation", [
      test_case "ref_set_read" `Quick t_ref;
    ];
    "runtime errors", [
      test_case "div_by_zero" `Quick t_div_by_zero;
      test_case "match_fail"  `Quick t_match_fail;
    ];
    "float arithmetic and modulo (Phase 17)", [
      test_case "1.5 + 2.0"  `Quick t_float_add;
      test_case "3.0 * 2.0"  `Quick t_float_mul;
      test_case "10 % 3"     `Quick t_int_mod;
    ];
    "where clauses", [
      test_case "single helper"     `Quick t_where_single;
      test_case "multiple helpers"  `Quick t_where_multi;
      test_case "sequential"        `Quick t_where_sequential;
      test_case "nested"            `Quick t_where_nested;
    ];
    "top-level function guards", [
      test_case "neg branch"        `Quick t_guard_basic_neg;
      test_case "pos branch"        `Quick t_guard_basic_pos;
      test_case "zero branch"       `Quick t_guard_basic_zero;
      test_case "non-exhaustive"    `Quick t_guard_non_exhaustive;
    ];
    "multi-impl dispatch (VMulti)", [
      test_case "list non-empty"    `Quick t_dispatch_list;
      test_case "option Some"       `Quick t_dispatch_option_some;
      test_case "option None"       `Quick t_dispatch_option_none;
      test_case "list empty"        `Quick t_dispatch_list_empty;
    ];
  ]
