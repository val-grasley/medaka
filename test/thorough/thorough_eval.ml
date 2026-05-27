(* Thorough evaluator tests.

   Focus areas not covered by test/test_eval.ml's happy-path:

   1. Arithmetic edge cases — overflow, division by zero, negation
   2. Pattern matching corners — nested ctors, deep destructuring,
      guards with side-effect-free expressions, as-patterns over
      nested shapes
   3. Recursion / tail calls — deep recursion, mutual recursion
   4. Closures — capture by reference vs by value, closure over
      mutable bindings, escape from scope
   5. Ref semantics — aliasing, equality, deref under update
   6. Do-block semantics across all monads in stdlib
   7. Range evaluation (List Int, List Char, Array Int)
   8. List comprehension corners
   9. String operations — escapes, interpolation evaluation,
      concatenation across edge cases
   10. Newtypes — pattern unwrap, deriving Num round-trip
   11. Records — update preserves field order; nested update
   12. Where-clauses — full ELetGroup mutual recursion
   13. @Name dispatch + multi-impl fallthrough at runtime
   14. Higher-order: partial application + currying observable behavior *)

open Medaka_lib.Eval
open Thorough_helpers

(* =====================================================================
   1. Arithmetic edge cases
   ===================================================================== *)

let t_arith_zero = assert_val "x = 0 + 0\n" "x" (VInt 0)
let t_arith_neg  = assert_val "x = 0 - 5\n" "x" (VInt (-5))
let t_arith_neg_neg = assert_val "x = -(-5)\n" "x" (VInt 5)
let t_arith_unary_negate = assert_val "x = -(7)\n" "x" (VInt (-7))
let t_arith_mod_zero =
  (* a mod 0 should panic at runtime *)
  assert_runtime_err "x = 5 % 0\n" "x"
let t_arith_div_zero = assert_runtime_err "x = 5 / 0\n" "x"
let t_arith_mod_neg  = assert_val "x = -7 % 3\n" "x" (VInt (-1))
let t_arith_mul_zero = assert_val "x = 12345 * 0\n" "x" (VInt 0)

(* Float operations *)
let t_float_add      = assert_val "x = 1.5 + 2.0\n" "x" (VFloat 3.5)
let t_float_sub      = assert_val "x = 5.5 - 1.5\n" "x" (VFloat 4.0)
let t_float_mul      = assert_val "x = 2.5 * 4.0\n" "x" (VFloat 10.0)
let t_float_div      = assert_val "x = 10.0 / 4.0\n" "x" (VFloat 2.5)
let t_float_div_zero =
  (* float division by zero may yield infinity rather than error;
     pin the actual observable behavior. *)
  assert_val "x = 1.0 / 0.0\n" "x" (VFloat infinity)

(* =====================================================================
   2. Pattern matching corners
   ===================================================================== *)

let t_match_nested_some =
  assert_val
    {|f x = match x
  None => 0
  Some None => 1
  Some (Some n) => n
r = f (Some (Some 42))
|}
    "r" (VInt 42)

let t_match_nested_some_outer_none =
  assert_val
    {|f x = match x
  None => 0
  Some None => 1
  Some (Some n) => n
r = f None
|}
    "r" (VInt 0)

let t_match_nested_some_inner_none =
  assert_val
    {|f x = match x
  None => 0
  Some None => 1
  Some (Some n) => n
r = f (Some None)
|}
    "r" (VInt 1)

(* Deep tuple destructuring *)
let t_match_deep_tuple =
  assert_val
    {|f p = match p
  ((a, b), (c, d)) => a + b + c + d
r = f ((1, 2), (3, 4))
|}
    "r" (VInt 10)

(* Pattern match on a list of tuples *)
let t_match_list_of_tuples =
  assert_val
    {|f xs = match xs
  [] => 0
  ((a, b) :: _) => a + b
r = f [(1, 2), (3, 4)]
|}
    "r" (VInt 3)

(* As-pattern over nested shape *)
let t_match_as_nested =
  assert_val
    {|f x = match x
  whole@(Some n) => (whole, n)
  None => (None, 0)
r = f (Some 42)
|}
    "r" (VTuple [VCon ("Some", [VInt 42]); VInt 42])

(* Guard with non-trivial expression *)
let t_match_guard_complex =
  assert_val
    {|classify p = match p
  (x, y) if x > 0 && y > 0 => "both positive"
  (x, y) if x < 0 && y < 0 => "both negative"
  _ => "mixed"
r = classify (-3, -5)
|}
    "r" (VString "both negative")

let t_match_guard_mixed =
  assert_val
    {|classify p = match p
  (x, y) if x > 0 && y > 0 => "both positive"
  (x, y) if x < 0 && y < 0 => "both negative"
  _ => "mixed"
r = classify (3, -5)
|}
    "r" (VString "mixed")

(* String literal in pattern *)
let t_match_string_lit =
  assert_val
    {|greet name = match name
  "Alice" => "Hi, Alice"
  "Bob" => "Hey, Bob"
  _ => "Hello, stranger"
r = greet "Bob"
|}
    "r" (VString "Hey, Bob")

(* Char literal in pattern *)
let t_match_char =
  assert_val
    {|classify c = match c
  'a' => 1
  'b' => 2
  _ => 0
r = classify 'b'
|}
    "r" (VInt 2)

(* Range pattern *)
let t_match_range =
  assert_val
    {|grade n = match n
  90..=100 => "A"
  80..=89 => "B"
  70..=79 => "C"
  _ => "F"
r = grade 85
|}
    "r" (VString "B")

let t_match_range_boundary =
  assert_val
    {|grade n = match n
  90..=100 => "A"
  80..=89 => "B"
  _ => "F"
r = grade 89
|}
    "r" (VString "B")

let t_match_range_outside =
  assert_val
    {|grade n = match n
  90..=100 => "A"
  80..=89 => "B"
  _ => "F"
r = grade 50
|}
    "r" (VString "F")

(* =====================================================================
   3. Recursion / tail calls
   ===================================================================== *)

(* Moderately deep self-recursion *)
let t_rec_sum_1000 =
  assert_val
    {|sumTo n = if n <= 0 then 0 else n + sumTo (n - 1)
r = sumTo 1000
|}
    "r" (VInt 500500)

(* Mutual recursion: even/odd *)
let t_mutual_even =
  assert_val
    {|isEven n = if n == 0 then True else isOdd (n - 1)
isOdd n = if n == 0 then False else isEven (n - 1)
r = isEven 50
|}
    "r" (VBool true)

let t_mutual_odd =
  assert_val
    {|isEven n = if n == 0 then True else isOdd (n - 1)
isOdd n = if n == 0 then False else isEven (n - 1)
r = isOdd 51
|}
    "r" (VBool true)

(* Tail-recursive accumulator *)
let t_tail_rec_acc =
  assert_val
    {|sumAcc acc n = if n <= 0 then acc else sumAcc (acc + n) (n - 1)
r = sumAcc 0 100
|}
    "r" (VInt 5050)

(* Where-bound recursion *)
let t_where_rec =
  assert_val
    {|r = go 5 where
  go n = if n <= 0 then 0 else n + go (n - 1)
|}
    "r" (VInt 15)

(* =====================================================================
   4. Closures
   ===================================================================== *)

let t_closure_basic =
  assert_val
    {|makeAdder n = (x => x + n)
add5 = makeAdder 5
r = add5 3
|}
    "r" (VInt 8)

let t_closure_two =
  assert_val
    {|makeAdder n = (x => x + n)
add5 = makeAdder 5
add7 = makeAdder 7
r = (add5 3, add7 3)
|}
    "r" (VTuple [VInt 8; VInt 10])

(* Closure capturing two variables *)
let t_closure_two_capture =
  assert_val
    {|makeOp a b = (x => x + a + b)
f = makeOp 3 4
r = f 5
|}
    "r" (VInt 12)

(* =====================================================================
   5. Ref semantics
   ===================================================================== *)

let t_ref_basic =
  assert_val
    {|r = do
  _ <- Some ()
  let mut x = Ref 0
  set_ref x 42
  pure x.value
|}
    "r" (VCon ("Some", [VInt 42]))

let t_ref_increment_loop =
  assert_val
    {|r = do
  _ <- Some ()
  let mut x = Ref 0
  set_ref x (x.value + 1)
  set_ref x (x.value + 1)
  set_ref x (x.value + 1)
  pure x.value
|}
    "r" (VCon ("Some", [VInt 3]))

(* =====================================================================
   6. Do-block monads
   ===================================================================== *)

let t_do_option_some_some =
  assert_val
    {|r = do
  x <- Some 5
  y <- Some 7
  pure (x + y)
|}
    "r" (VCon ("Some", [VInt 12]))

let t_do_option_first_none =
  assert_val
    {|r = do
  x <- None
  y <- Some 7
  pure (x + y)
|}
    "r" (VCon ("None", []))

let t_do_option_middle_none =
  assert_val
    {|r = do
  x <- Some 1
  _ <- None
  pure x
|}
    "r" (VCon ("None", []))

let t_do_result_ok_chain =
  assert_val
    {|r = do
  x <- Ok 10
  y <- Ok 5
  z <- Ok 1
  pure (x - y - z)
|}
    "r" (VCon ("Ok", [VInt 4]))

let t_do_result_err_first =
  assert_val
    {|r = do
  x <- Err "fail"
  pure x
|}
    "r" (VCon ("Err", [VString "fail"]))

let t_do_result_err_short_circuit =
  assert_val
    {|r = do
  x <- Ok 1
  _ <- Err "stop"
  pure x
|}
    "r" (VCon ("Err", [VString "stop"]))

(* =====================================================================
   7. Range evaluation
   ===================================================================== *)

let t_range_list_inclusive =
  assert_val "r = [1..=5]\n" "r"
    (VList [VInt 1; VInt 2; VInt 3; VInt 4; VInt 5])

let t_range_list_halfopen =
  assert_val "r = [1..5]\n" "r"
    (VList [VInt 1; VInt 2; VInt 3; VInt 4])

let t_range_list_single =
  assert_val "r = [3..=3]\n" "r" (VList [VInt 3])

let t_range_list_empty =
  assert_val "r = [5..5]\n" "r" (VList [])

let t_range_list_descending_empty =
  (* Descending range yields empty list, no error. *)
  assert_val "r = [5..1]\n" "r" (VList [])

let t_range_array_inclusive =
  assert_val "r = [|1..=3|]\n" "r" (VArray [| VInt 1; VInt 2; VInt 3 |])

(* =====================================================================
   8. List comprehensions
   ===================================================================== *)

let t_list_comp_simple =
  assert_val
    "r = [x * 2 | x <- [1, 2, 3]]\n"
    "r" (VList [VInt 2; VInt 4; VInt 6])

let t_list_comp_filter =
  assert_val
    "r = [x | x <- [1, 2, 3, 4, 5], x > 2]\n"
    "r" (VList [VInt 3; VInt 4; VInt 5])

let t_list_comp_let =
  assert_val
    "r = [y | x <- [1, 2, 3], let y = x * x]\n"
    "r" (VList [VInt 1; VInt 4; VInt 9])

let t_list_comp_cartesian =
  assert_val
    "r = [(x, y) | x <- [1, 2], y <- [10, 20]]\n"
    "r" (VList [
      VTuple [VInt 1; VInt 10]; VTuple [VInt 1; VInt 20];
      VTuple [VInt 2; VInt 10]; VTuple [VInt 2; VInt 20]
    ])

let t_list_comp_empty_gen =
  assert_val "r = [x | x <- []]\n" "r" (VList [])

(* =====================================================================
   9. String operations
   ===================================================================== *)

let t_string_concat = assert_val {|x = "a" ++ "b" ++ "c"
|} "x" (VString "abc")

let t_string_empty_concat = assert_val {|x = "" ++ "hi" ++ ""
|} "x" (VString "hi")

(* DIVERGENCE: the typechecker REJECTS `"value: \{1 + 1}"` with
   "Type mismatch: Int vs String", but the evaluator silently
   auto-coerces (the result is "value: 2").  Eval and typecheck
   disagree here — see thorough_interactions.ml::tc_eval_skew.
   For now: pin the observed eval behavior; the typecheck side is
   pinned by thorough_typecheck.ml::e_interp_int_hole. *)
let t_string_interp_int =
  assert_val {|x = "value: \{1 + 1}"
|} "x" (VString "value: 2")

let t_string_interp_three_holes =
  assert_val
    {|a = "x"
b = "y"
c = "z"
r = "\{a}-\{b}-\{c}"
|}
    "r" (VString "x-y-z")

let t_string_escapes =
  assert_val
    {|r = "a\nb\tc\\d\"e"
|}
    "r" (VString "a\nb\tc\\d\"e")

let t_char_value =
  assert_val "r = 'A'\n" "r" (VChar "A")

(* =====================================================================
   10. Newtypes
   ===================================================================== *)

let t_newtype_unwrap =
  assert_val
    {|newtype Foo = Foo Int
unwrap (Foo n) = n
r = unwrap (Foo 42)
|}
    "r" (VInt 42)

let t_newtype_deriving_num_add =
  assert_val
    {|newtype Dist = Dist Int deriving (Num)
r : Dist
r = add (Dist 3) (Dist 4)
|}
    "r" (VCon ("Dist", [VInt 7]))

let t_newtype_pattern_in_match =
  assert_val
    {|newtype Foo = Foo Int
double (Foo n) = Foo (n * 2)
r = match double (Foo 5)
  Foo m => m
|}
    "r" (VInt 10)

(* =====================================================================
   11. Records — including nested update
   ===================================================================== *)

let t_record_create_and_access =
  assert_val
    {|record P
  x : Int
  y : Int
p = P { x = 3, y = 4 }
r = p.x + p.y
|}
    "r" (VInt 7)

let t_record_update_single =
  assert_val
    {|record P
  x : Int
  y : Int
p = P { x = 1, y = 2 }
q = { p | x = 100 }
r = q.x
|}
    "r" (VInt 100)

let t_record_update_other_unchanged =
  assert_val
    {|record P
  x : Int
  y : Int
p = P { x = 1, y = 2 }
q = { p | x = 100 }
r = q.y
|}
    "r" (VInt 2)

let t_record_update_nested =
  assert_val
    {|record Address
  city : String
record Person
  name : String
  addr : Address
a = Address { city = "Boston" }
p = Person { name = "Alice", addr = a }
q = { p | addr.city = "NYC" }
r = q.addr.city
|}
    "r" (VString "NYC")

let t_record_update_nested_outer_unchanged =
  assert_val
    {|record Address
  city : String
record Person
  name : String
  addr : Address
a = Address { city = "Boston" }
p = Person { name = "Alice", addr = a }
q = { p | addr.city = "NYC" }
r = q.name
|}
    "r" (VString "Alice")

(* =====================================================================
   12. Where-clauses — mutual recursion
   ===================================================================== *)

let t_where_mutual_rec =
  assert_val
    {|r = isEven 10 where
  isEven n = if n == 0 then True else isOdd (n - 1)
  isOdd n = if n == 0 then False else isEven (n - 1)
|}
    "r" (VBool true)

(* =====================================================================
   13. @Name dispatch + multi-impl fallthrough
   ===================================================================== *)

let named_impl_src = {|
interface Combine a where
    combine : a -> a -> a
impl Additive of Combine Int where
    combine x y = x + y
impl Multiplicative of Combine Int where
    combine x y = x * y
|}

let t_named_additive =
  assert_val (named_impl_src ^ "r = combine @Additive 3 4\n")
    "r" (VInt 7)

let t_named_multiplicative =
  assert_val (named_impl_src ^ "r = combine @Multiplicative 3 4\n")
    "r" (VInt 12)

let t_named_unknown =
  assert_runtime_err (named_impl_src ^ "r = combine @Unknown 3 4\n") "r"

(* =====================================================================
   14. Higher-order: partial application
   ===================================================================== *)

let t_partial_app_three =
  assert_val
    {|f a b c = a + b * c
g = f 1 2
r = g 10
|}
    "r" (VInt 21)

let t_compose_chain =
  assert_val
    {|inc x = x + 1
dbl x = x * 2
neg x = 0 - x
f = inc >> dbl >> neg
r = f 5
|}
    "r" (VInt (-12))

let t_pipe_chain =
  assert_val
    {|inc x = x + 1
dbl x = x * 2
r = 5 |> inc |> dbl |> (n => n - 1)
|}
    "r" (VInt 11)

(* =====================================================================
   15. Polymorphism observable through eval
   ===================================================================== *)

(* identity used on multiple types should not introduce confusion *)
let t_poly_id_two_types =
  assert_val
    {|id x = x
r = (id 5, id "hi")
|}
    "r" (VTuple [VInt 5; VString "hi"])

(* map over different element types *)
let t_poly_map_string_length =
  assert_val
    {|len s = match s
  "" => 0
  _ => 1
r = map len ["", "x", "yy"]
|}
    "r" (VList [VInt 0; VInt 1; VInt 1])

(* =====================================================================
   16. Boolean short-circuit
   ===================================================================== *)

(* `&&` should not evaluate RHS when LHS is false *)
let t_and_short_circuit =
  assert_val
    {|safeDivCheck n d = d != 0 && (n / d) > 0
r = safeDivCheck 10 0
|}
    "r" (VBool false)

(* `||` should not evaluate RHS when LHS is true *)
let t_or_short_circuit =
  assert_val
    {|fastTrue x = True || (x / 0) > 0
r = fastTrue 5
|}
    "r" (VBool true)

(* =====================================================================
   17. if-let and let-else
   ===================================================================== *)

let t_if_let_match =
  assert_val
    {|f x = if let Some n = x then n + 1 else 0
r = f (Some 5)
|}
    "r" (VInt 6)

let t_if_let_no_match =
  assert_val
    {|f x = if let Some n = x then n + 1 else 0
r = f None
|}
    "r" (VInt 0)

(* =====================================================================
   18. Empty data / unit types
   ===================================================================== *)

let t_unit_value = assert_val "r = ()\n" "r" VUnit

let t_unit_in_tuple =
  assert_val "r = (1, (), \"x\")\n" "r"
    (VTuple [VInt 1; VUnit; VString "x"])

(* =====================================================================
   19. Question operator
   ===================================================================== *)

let t_question_ok_chain =
  assert_val
    {|r =
  let x = Ok 10 ?
  let y = Ok 5 ?
  pure (x - y)
|}
    "r" (VCon ("Ok", [VInt 5]))

let t_question_short_circuit =
  assert_val
    {|r =
  let x = Ok 10 ?
  let y = Err "stop" ?
  pure (x - y)
|}
    "r" (VCon ("Err", [VString "stop"]))

(* =====================================================================
   20. Numeric literal forms
   ===================================================================== *)

let t_hex_lit = assert_val "x = 0xFF\n" "x" (VInt 255)
let t_bin_lit = assert_val "x = 0b1010\n" "x" (VInt 10)
let t_oct_lit = assert_val "x = 0o17\n" "x" (VInt 15)
let t_underscore_lit = assert_val "x = 1_000_000\n" "x" (VInt 1000000)
let t_hex_arith = assert_val "x = 0xFF + 0x01\n" "x" (VInt 256)

(* =====================================================================
   Test registration
   ===================================================================== *)

let () =
  let open Alcotest in
  run "thorough eval"
    [
      ( "arithmetic",
        [ test_case "0 + 0"                 `Quick t_arith_zero
        ; test_case "0 - 5"                 `Quick t_arith_neg
        ; test_case "-(-5)"                 `Quick t_arith_neg_neg
        ; test_case "-(7)"                  `Quick t_arith_unary_negate
        ; test_case "5 % 0"                 `Quick t_arith_mod_zero
        ; test_case "5 / 0"                 `Quick t_arith_div_zero
        ; test_case "-7 % 3"                `Quick t_arith_mod_neg
        ; test_case "12345 * 0"             `Quick t_arith_mul_zero
        ; test_case "float add"             `Quick t_float_add
        ; test_case "float sub"             `Quick t_float_sub
        ; test_case "float mul"             `Quick t_float_mul
        ; test_case "float div"             `Quick t_float_div
        ; test_case "1.0 / 0.0 -> inf"      `Quick t_float_div_zero
        ] );
      ( "pattern matching",
        [ test_case "nested Some (Some)"    `Quick t_match_nested_some
        ; test_case "nested outer None"     `Quick t_match_nested_some_outer_none
        ; test_case "nested inner None"     `Quick t_match_nested_some_inner_none
        ; test_case "deep tuple"            `Quick t_match_deep_tuple
        ; test_case "list of tuples"        `Quick t_match_list_of_tuples
        ; test_case "as-pattern nested"     `Quick t_match_as_nested
        ; test_case "guard both neg"        `Quick t_match_guard_complex
        ; test_case "guard mixed"           `Quick t_match_guard_mixed
        ; test_case "string literal"        `Quick t_match_string_lit
        ; test_case "char literal"          `Quick t_match_char
        ; test_case "range match"           `Quick t_match_range
        ; test_case "range boundary"        `Quick t_match_range_boundary
        ; test_case "range outside"         `Quick t_match_range_outside
        ] );
      ( "recursion",
        [ test_case "sumTo 1000"            `Quick t_rec_sum_1000
        ; test_case "mutual: even 50"       `Quick t_mutual_even
        ; test_case "mutual: odd 51"        `Quick t_mutual_odd
        ; test_case "tail rec acc 100"      `Quick t_tail_rec_acc
        ; test_case "where rec sumTo 5"     `Quick t_where_rec
        ] );
      ( "closures",
        [ test_case "makeAdder 5"           `Quick t_closure_basic
        ; test_case "two adders"            `Quick t_closure_two
        ; test_case "two-arg capture"       `Quick t_closure_two_capture
        ] );
      ( "Ref semantics",
        [ test_case "set_ref + read"        `Quick t_ref_basic
        ; test_case "increment three times" `Quick t_ref_increment_loop
        ] );
      ( "do monads",
        [ test_case "Option Some + Some"    `Quick t_do_option_some_some
        ; test_case "Option first None"     `Quick t_do_option_first_none
        ; test_case "Option middle None"    `Quick t_do_option_middle_none
        ; test_case "Result Ok chain"       `Quick t_do_result_ok_chain
        ; test_case "Result first Err"      `Quick t_do_result_err_first
        ; test_case "Result Err short-circ" `Quick t_do_result_err_short_circuit
        ] );
      ( "ranges",
        [ test_case "[1..=5]"               `Quick t_range_list_inclusive
        ; test_case "[1..5]"                `Quick t_range_list_halfopen
        ; test_case "[3..=3] singleton"     `Quick t_range_list_single
        ; test_case "[5..5] empty"          `Quick t_range_list_empty
        ; test_case "[5..1] descending"     `Quick t_range_list_descending_empty
        ; test_case "[|1..=3|] array"       `Quick t_range_array_inclusive
        ] );
      ( "list comprehensions",
        [ test_case "simple map"            `Quick t_list_comp_simple
        ; test_case "with filter"           `Quick t_list_comp_filter
        ; test_case "with let"              `Quick t_list_comp_let
        ; test_case "cartesian product"     `Quick t_list_comp_cartesian
        ; test_case "empty generator"       `Quick t_list_comp_empty_gen
        ] );
      ( "strings",
        [ test_case "concat triple"         `Quick t_string_concat
        ; test_case "concat with empty"     `Quick t_string_empty_concat
        ; test_case "interp int hole (runtime)" `Quick t_string_interp_int
        ; test_case "interp three holes"    `Quick t_string_interp_three_holes
        ; test_case "all escapes"           `Quick t_string_escapes
        ; test_case "char value"            `Quick t_char_value
        ] );
      ( "newtypes",
        [ test_case "unwrap"                `Quick t_newtype_unwrap
        ; test_case "deriving Num add"      `Quick t_newtype_deriving_num_add
        ; test_case "pattern in match"      `Quick t_newtype_pattern_in_match
        ] );
      ( "records",
        [ test_case "create + access"       `Quick t_record_create_and_access
        ; test_case "update single field"   `Quick t_record_update_single
        ; test_case "update other unchanged" `Quick t_record_update_other_unchanged
        ; test_case "nested update"         `Quick t_record_update_nested
        ; test_case "nested update outer"   `Quick t_record_update_nested_outer_unchanged
        ] );
      ( "where mutual recursion",
        [ test_case "isEven 10"             `Quick t_where_mutual_rec
        ] );
      ( "@Name dispatch",
        [ test_case "Additive"              `Quick t_named_additive
        ; test_case "Multiplicative"        `Quick t_named_multiplicative
        ; test_case "Unknown -> err"        `Quick t_named_unknown
        ] );
      ( "higher-order",
        [ test_case "partial app 3-arg"     `Quick t_partial_app_three
        ; test_case "compose chain"         `Quick t_compose_chain
        ; test_case "pipe chain"            `Quick t_pipe_chain
        ] );
      ( "polymorphism via eval",
        [ test_case "id at int+string"      `Quick t_poly_id_two_types
        ; test_case "map len over strings"  `Quick t_poly_map_string_length
        ] );
      ( "short-circuit",
        [ test_case "&& shortcuts /0"       `Quick t_and_short_circuit
        ; test_case "|| shortcuts /0"       `Quick t_or_short_circuit
        ] );
      ( "if-let",
        [ test_case "match Some"            `Quick t_if_let_match
        ; test_case "no match"              `Quick t_if_let_no_match
        ] );
      ( "unit",
        [ test_case "()"                    `Quick t_unit_value
        ; test_case "() inside tuple"       `Quick t_unit_in_tuple
        ] );
      ( "? operator",
        [ test_case "Ok chain"              `Quick t_question_ok_chain
        ; test_case "short circuit on Err"  `Quick t_question_short_circuit
        ] );
      ( "numeric literal forms",
        [ test_case "0xFF"                  `Quick t_hex_lit
        ; test_case "0b1010"                `Quick t_bin_lit
        ; test_case "0o17"                  `Quick t_oct_lit
        ; test_case "1_000_000"             `Quick t_underscore_lit
        ; test_case "hex arith"             `Quick t_hex_arith
        ] );
    ]
