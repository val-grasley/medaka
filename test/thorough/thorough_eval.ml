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
   21. Shadowing — let-bound and lambda-param shadowing
   ===================================================================== *)

let t_shadow_let =
  assert_val {|x = 5
y = let x = 10 in x + 1
r = (x, y)
|} "r" (VTuple [VInt 5; VInt 11])

let t_shadow_lambda =
  assert_val {|x = 5
y = (x => x * 2) 10
r = (x, y)
|} "r" (VTuple [VInt 5; VInt 20])

(* =====================================================================
   22. Equality across types
   ===================================================================== *)

let t_eq_empty_string = assert_val {|r = "" == ""
|} "r" (VBool true)

let t_eq_tuple = assert_val {|r = (1, "x") == (1, "x")
|} "r" (VBool true)

let t_eq_tuple_diff = assert_val {|r = (1, "x") == (1, "y")
|} "r" (VBool false)

let t_eq_unit = assert_val "r = () == ()\n" "r" (VBool true)

let t_eq_int_neg = assert_val "r = -5 == -5\n" "r" (VBool true)

(* =====================================================================
   23. Mutually-referencing record types
   ===================================================================== *)

let t_mutual_records =
  assert_val
    {|record A
  b : Int
record B
  a : Int
x : A
x = A { b = 5 }
y : B
y = B { a = 10 }
r = x.b + y.a
|}
    "r" (VInt 15)

(* Self-referential record (via Option).  The match expression must
   be parenthesized to bind correctly under `+`. *)
let t_self_ref_record =
  assert_val
    {|record Node
  val : Int
  next : Option Node
n = Node { val = 1, next = Some (Node { val = 2, next = None }) }
nextVal = match n.next
  Some n2 => n2.val
  None => 0
r = n.val + nextVal
|}
    "r" (VInt 3)

(* =====================================================================
   24. Match arm bodies via explicit do
   ===================================================================== *)

let t_match_arm_do =
  assert_val
    {|f xs = match xs
  [] => 0
  (x :: _) => do
    let doubled = x * 2
    doubled + 1
r = f [10]
|}
    "r" (VInt 21)

(* =====================================================================
   25. Single-constructor data type
   ===================================================================== *)

let t_single_ctor_data =
  assert_val {|data Singleton = Only
r = match Only
  Only => 42
|} "r" (VInt 42)

(* =====================================================================
   26. Collection literals — Map / Set / HashMap
   ===================================================================== *)

(* Map literal currently evaluates to a VCon wrapping a VList of pairs:
   `Map.fromList [(k, v), ...]` is the runtime shape (per Phase 16).
   The actual collection runtime types (Map, Set, HashMap) are not yet
   defined as stdlib types — pin via pp_value. *)
let t_map_literal_pp () =
  let v = run {|r = Map { 1 => "one", 2 => "two" }
|} "r" in
  let s = pp_value v in
  if s <> "Map.fromList [(1, one), (2, two)]" then
    failwith (Printf.sprintf "Got pp_value: %s" s)

let t_set_literal_pp () =
  let v = run {|r = Set { 1, 2, 3 }
|} "r" in
  let s = pp_value v in
  if s <> "Set.fromList [1, 2, 3]" then
    failwith (Printf.sprintf "Got pp_value: %s" s)

(* =====================================================================
   27. Unicode in strings and chars
   ===================================================================== *)

(* Multi-byte chars are stored as VString with the UTF-8 byte sequence. *)
let t_unicode_string =
  assert_val {|r = "héllo"
|} "r" (VString "h\195\169llo")
(* é = U+00E9 = bytes c3 a9 = "\195\169" in OCaml *)

let t_unicode_escape_snowman =
  assert_val {|r = "\u{2603}"
|} "r" (VString "\xe2\x98\x83")

(* =====================================================================
   28. Records with function-typed fields
   ===================================================================== *)

let t_record_function_field =
  assert_val
    {|record Calc
  add : Int -> Int -> Int
c = Calc { add = (x => y => x + y) }
r = c.add 3 4
|}
    "r" (VInt 7)

(* =====================================================================
   29. let mut outside do (preserves value)
   ===================================================================== *)

let t_let_mut_outside_do =
  assert_val
    {|f =
  let mut x = 5
  x
r = f
|}
    "r" (VInt 5)

(* =====================================================================
   30. Negative integer comparisons
   ===================================================================== *)

let t_compare_negative =
  assert_val "r = (-5 < 0, -5 > -10)\n" "r"
    (VTuple [VBool true; VBool true])

let t_compare_neg_eq =
  assert_val "r = -5 == -5\n" "r" (VBool true)

(* Mod with negatives *)
let t_mod_neg_combinations =
  assert_val
    "r = ((-7) % 3, 7 % (-3), (-7) % (-3))\n"
    "r" (VTuple [VInt (-1); VInt 1; VInt (-1)])

(* =====================================================================
   31. print / println outputs
   ===================================================================== *)

let t_print_int =
  assert_stdout
    {|main : <IO> Unit
main = print 5
|}
    "5"

let t_print_tuple =
  assert_stdout
    {|main : <IO> Unit
main = print (1, "x", True)
|}
    "(1, x, true)"

let t_println_list =
  assert_stdout
    {|main : <IO> Unit
main = println [1, 2, 3]
|}
    "[1, 2, 3]\n"

(* =====================================================================
   32. Deep nesting
   ===================================================================== *)

let t_deep_list_literal =
  assert_val
    "r = [[[1, 2], [3, 4]], [[5, 6], [7, 8]]]\n"
    "r" (VList [
      VList [VList [VInt 1; VInt 2]; VList [VInt 3; VInt 4]];
      VList [VList [VInt 5; VInt 6]; VList [VInt 7; VInt 8]]
    ])

(* =====================================================================
   33. Recursive function with where helper (accumulator)
   ===================================================================== *)

let t_rec_with_where_acc =
  assert_val
    {|len xs = go 0 xs where
  go acc [] = acc
  go acc (_::rest) = go (acc + 1) rest
r = len [1, 2, 3, 4, 5]
|}
    "r" (VInt 5)

(* =====================================================================
   34. List monad in do — KNOWN LIMITATION (PLAN.md §5)
   ===================================================================== *)

(* Per PLAN.md §5: "do-block monad dispatch in eval.ml is a runtime
   heuristic ... (b) the List monad is not supported".  Concretely:
   `do { x <- [1,2,3]; pure (x*2) }` does NOT iterate — instead x
   binds to the whole VList because VList values don't carry a VCon
   tag that monadic_ctors recognizes.  Pin the (broken) behavior so
   the eventual fix is detectable. *)
let t_list_monad_in_do_broken =
  assert_runtime_err
    {|r = do
  x <- [1, 2, 3]
  pure (x * 2)
|}
    "r"

(* Direct `andThen` works for Lists when the body returns a list. *)
let t_andThen_list_direct =
  assert_val
    {|r = andThen [1, 2, 3] (x => [x, x])
|}
    "r" (VList [VInt 1; VInt 1; VInt 2; VInt 2; VInt 3; VInt 3])

(* List comprehension is the right replacement for List-monad do. *)
let t_list_comp_as_list_monad =
  assert_val
    {|r = [x * 2 | x <- [1, 2, 3]]
|}
    "r" (VList [VInt 2; VInt 4; VInt 6])

(* =====================================================================
   35. Empty record pattern
   ===================================================================== *)

let t_empty_record_pat =
  assert_val
    {|record P
  x : Int
  y : Int
f p = match p
  P { ... } => "any"
r = f (P { x = 1, y = 2 })
|}
    "r" (VString "any")

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
      ( "shadowing",
        [ test_case "shadow let"            `Quick t_shadow_let
        ; test_case "shadow lambda"         `Quick t_shadow_lambda
        ] );
      ( "equality",
        [ test_case "empty string =="       `Quick t_eq_empty_string
        ; test_case "tuple eq"              `Quick t_eq_tuple
        ; test_case "tuple neq"             `Quick t_eq_tuple_diff
        ; test_case "() == ()"              `Quick t_eq_unit
        ; test_case "neg int eq"            `Quick t_eq_int_neg
        ] );
      ( "record types",
        [ test_case "mutual records"        `Quick t_mutual_records
        ; test_case "self-ref via Option"   `Quick t_self_ref_record
        ] );
      ( "match arm do",
        [ test_case "list arm with do"      `Quick t_match_arm_do
        ] );
      ( "single-constructor data",
        [ test_case "data Singleton"        `Quick t_single_ctor_data
        ] );
      ( "collection literals",
        [ test_case "Map literal pp"        `Quick t_map_literal_pp
        ; test_case "Set literal pp"        `Quick t_set_literal_pp
        ] );
      ( "unicode",
        [ test_case "héllo (UTF-8)"          `Quick t_unicode_string
        ; test_case "\\u{2603} snowman"      `Quick t_unicode_escape_snowman
        ] );
      ( "record function field",
        [ test_case "Calc.add"              `Quick t_record_function_field
        ] );
      ( "let mut outside do",
        [ test_case "preserves value"       `Quick t_let_mut_outside_do
        ] );
      ( "negative comparisons",
        [ test_case "< and >"               `Quick t_compare_negative
        ; test_case "-5 == -5"              `Quick t_compare_neg_eq
        ; test_case "mod combos"            `Quick t_mod_neg_combinations
        ] );
      ( "print / println",
        [ test_case "print 5"               `Quick t_print_int
        ; test_case "print tuple"           `Quick t_print_tuple
        ; test_case "println list"          `Quick t_println_list
        ] );
      ( "deep nesting",
        [ test_case "list of lists of lists" `Quick t_deep_list_literal
        ] );
      ( "rec where helper",
        [ test_case "len with go acc"       `Quick t_rec_with_where_acc
        ] );
      ( "List monad in do",
        [ test_case "broken: x*2 on whole list" `Quick t_list_monad_in_do_broken
        ; test_case "andThen direct works"      `Quick t_andThen_list_direct
        ; test_case "list-comp as replacement"  `Quick t_list_comp_as_list_monad
        ] );
      ( "empty record pat",
        [ test_case "P { ... }"             `Quick t_empty_record_pat
        ] );
    ]
