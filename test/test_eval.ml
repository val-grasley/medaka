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
  let prog = Desugar.desugar_program (parse src) in
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
let t_string       = assert_val "x = \"hi\"\n" "x" (VString "hi")
let t_triple_string = assert_val {|x = """hi"""
|} "x" (VString "hi")
let t_triple_multiline = assert_val ("x = \"\"\"\n  hello\n  world\n  \"\"\"\n") "x" (VString "hello\nworld\n")
let t_bool   = assert_val "x = True\n"   "x" (VBool true)
let t_unit   = assert_val "x = ()\n"     "x" VUnit

(* ── Arithmetic ─────────────────────────────────────────────────────────── *)

let t_add  = assert_val "x = 2 + 3\n"  "x" (VInt 5)
let t_sub  = assert_val "x = 10 - 4\n" "x" (VInt 6)
let t_mul  = assert_val "x = 3 * 4\n"  "x" (VInt 12)
let t_div  = assert_val "x = 10 / 2\n" "x" (VInt 5)
let t_neg  = assert_val "x = -(5)\n"   "x" (VInt (-5))

let t_concat = assert_val {|x = "hello" ++ " world"
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

let t_left_section_mul = assert_val "r = (2 * _) 5\n" "r" (VInt 10)
let t_left_section_sub = assert_val "r = (10 - _) 3\n" "r" (VInt 7)
let t_left_section_map = assert_val
  "r = map (2 * _) [1, 2, 3]\n" "r" (VList [VInt 2; VInt 4; VInt 6])

let t_bare_section_plus     = assert_val "r = (+) 2 3\n"      "r" (VInt 5)
let t_bare_section_minus    = assert_val "r = (-) 10 4\n"     "r" (VInt 6)
let t_bare_section_eq_true  = assert_val "r = (==) 1 1\n"     "r" (VBool true)
let t_bare_section_eq_false = assert_val "r = (==) 1 2\n"     "r" (VBool false)
let t_bare_section_cons     = assert_val "r = (::) 1 [2, 3]\n"
  "r" (VList [VInt 1; VInt 2; VInt 3])
let t_bare_section_fold     = assert_val
  "r = fold (+) 0 [1, 2, 3, 4]\n" "r" (VInt 10)

let t_multi_param_lambda_two  = assert_val "r = (x y => x + y) 1 2\n" "r" (VInt 3)
let t_multi_param_lambda_three = assert_val "r = (f a b => f a + b) (x => x * 2) 3 4\n" "r" (VInt 10)

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

let t_record_update_nested = assert_val {|record Address
  city : String
record Person
  name : String
  address : Address
addr = Address { city = "Cambridge" }
p = Person { name = "Alice", address = addr }
p2 = { p | address.city = "Boston" }
r = p2.address.city
|} "r" (VString "Boston")

let t_record_update_nested_deep = assert_val {|record Country
  code : String
record Address
  country : Country
record Person
  name : String
  address : Address
c = Country { code = "UK" }
addr = Address { country = c }
p = Person { name = "Alice", address = addr }
p2 = { p | address.country.code = "US" }
r = p2.address.country.code
|} "r" (VString "US")

let t_record_update_nested_unchanged = assert_val {|record Address
  city : String
record Person
  name : String
  address : Address
addr = Address { city = "Cambridge" }
p = Person { name = "Alice", address = addr }
p2 = { p | address.city = "Boston" }
r = p2.name
|} "r" (VString "Alice")

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

(* foldMap uses Foldable's default impl with the String Monoid:
   concatenates the mapped strings via ++. *)
let t_foldmap_string = assert_val
  {|r = foldMap (s => s) ["a", "b", "c"]
|} "r" (VString "abc")

(* foldMap with the List Monoid: results concatenate. *)
let t_foldmap_list = assert_val
  {|r = foldMap (x => [x, x]) [1, 2, 3]
|} "r" (VList [VInt 1; VInt 1; VInt 2; VInt 2; VInt 3; VInt 3])

(* foldMap with a user-defined Monoid: exercises the VCon → ctor_to_type
   path in runtime_type_tag, not just the built-in VString/VList tags. *)
let t_foldmap_user_monoid = assert_val
  {|data Sum = MkSum Int

impl Semigroup Sum where
    append (MkSum a) (MkSum b) = MkSum (a + b)

impl Monoid Sum where
    empty = MkSum 0

unwrap (MkSum n) = n

r = unwrap (foldMap MkSum [1, 2, 3, 4])
|} "r" (VInt 10)

let t_list_comp_guard = assert_val
  {|r = [x * 2 | x <- [1, 2, 3, 4, 5], x > 2]
|} "r" (VList [VInt 6; VInt 8; VInt 10])

let t_list_comp_multi_gen = assert_val
  {|r = [(x, y) | x <- [1, 2], y <- [3, 4]]
|} "r" (VList [VTuple [VInt 1; VInt 3]; VTuple [VInt 1; VInt 4];
               VTuple [VInt 2; VInt 3]; VTuple [VInt 2; VInt 4]])

let t_list_comp_let = assert_val
  {|r = [y | x <- [1, 2, 3], let y = x * x, y > 2]
|} "r" (VList [VInt 4; VInt 9])

let t_list_comp_refutable_con = assert_val
  {|r = [x | Some x <- [Some 1, None, Some 2, None, Some 3]]
|} "r" (VList [VInt 1; VInt 2; VInt 3])

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

(* ── `?` operator: desugars to andThen ──────────────────────────────────── *)

let t_question_ok = assert_val {|r =
  let x = Ok 5 ?
  pure (x + 1)
|} "r" (VCon ("Ok", [VInt 6]))

let t_question_err = assert_val {|r =
  let x = Err "bad" ?
  pure (x + 1)
|} "r" (VCon ("Err", [VString "bad"]))

let t_question_some = assert_val {|r =
  let x = Some 42 ?
  pure (x + 1)
|} "r" (VCon ("Some", [VInt 43]))

let t_question_none = assert_val {|r =
  let x = None ?
  pure 99
|} "r" (VCon ("None", []))

(* Multiple ?-binds chain via nested andThen *)
let t_question_chain = assert_val {|r =
  let x = Ok 10 ?
  let y = Ok 5 ?
  pure (x - y)
|} "r" (VCon ("Ok", [VInt 5]))

(* Short-circuit hits the second ? *)
let t_question_chain_err = assert_val {|r =
  let x = Ok 10 ?
  let y = Err "stop" ?
  pure (x - y)
|} "r" (VCon ("Err", [VString "stop"]))

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

let t_where_mutual_recursion = assert_val {|r = isEven 4 where
    isEven n = if n == 0 then True else isOdd (n - 1)
    isOdd  n = if n == 0 then False else isEven (n - 1)
|} "r" (VBool true)

let t_where_match_arm = assert_val {|classify n = match n
  x => doubled x where
      doubled y = y * 2
r = classify 5
|} "r" (VInt 10)

(* Guards inside a where binding (count-style). *)
let t_where_guards = assert_val {|countPos xs = fold g 0 xs where
    g acc x
        | x > 0 = acc + 1
        | otherwise = acc
r = countPos [(-1), 2, (-3), 4]
|} "r" (VInt 2)

(* Multi-clause where binding (find-style: dispatch on pattern). *)
let t_where_multi_clause = assert_val {|findGt n xs = fold g None xs where
    g (Some a) _ = Some a
    g None x = if x > n then Some x else None
r = findGt 2 [1, 2, 3, 4]
|} "r" (VCon ("Some", [VInt 3]))

(* Multi-clause + guards in the same where binding (full find pattern). *)
let t_where_multi_clause_with_guards = assert_val {|findFirst f xs = fold g None xs where
    g (acc@Some _) _ = acc
    g None x
        | f x = Some x
        | otherwise = None
r = findFirst (x => x > 10) [1, 5, 20, 30]
|} "r" (VCon ("Some", [VInt 20]))

(* Top-level multi-clause function definition: two same-named DFunDefs
   should dispatch via VMulti just like impl methods. *)
let t_toplevel_multi_clause = assert_val {|describe 0 = "zero"
describe _ = "other"
r = (describe 0, describe 7)
|} "r" (VTuple [VString "zero"; VString "other"])

(* Haskell-style: `where` on its own line, indented under the body. *)
let t_where_on_new_line = assert_val {|findFirst f xs = fold g None xs
    where
        g (acc@Some _) _ = acc
        g None x
            | f x = Some x
            | otherwise = None
r = findFirst (x => x > 10) [1, 5, 20, 30]
|} "r" (VCon ("Some", [VInt 20]))

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

(* ── Pattern guards (boolean + pattern-bind qualifiers) ─────────────────── *)

(* Pattern-bind that matches takes its arm. *)
let t_pguard_bind_match = assert_val {|
classify o
  | Some y <- o, y > 0 = "pos"
  | Some y <- o        = "nonpos"
  | otherwise          = "missing"
r = classify (Some 7)
|} "r" (VString "pos")

(* First arm's boolean qualifier fails, falls through to second arm. *)
let t_pguard_bind_fallthrough = assert_val {|
classify o
  | Some y <- o, y > 0 = "pos"
  | Some y <- o        = "nonpos"
  | otherwise          = "missing"
r = classify (Some (-2))
|} "r" (VString "nonpos")

(* Pattern-bind itself fails (None), falls through to catch-all. *)
let t_pguard_bind_fail = assert_val {|
classify o
  | Some y <- o, y > 0 = "pos"
  | Some y <- o        = "nonpos"
  | otherwise          = "missing"
r = classify None
|} "r" (VString "missing")

(* filterMap-style: pattern-bind guards over a list (the list.mdk trigger). *)
let t_pguard_filter_map = assert_val {|
keepPos [] = []
keepPos (x::xs)
  | Some y <- x = y::(keepPos xs)
  | None  <- x  = keepPos xs
r = keepPos [Some 1, None, Some 3]
|} "r" (VList [VInt 1; VInt 3])

(* Pattern bind in a match-arm guard, with fallthrough between arms. *)
let t_pguard_match_arm = assert_val {|
describe o =
  match o
    n if Some y <- n, y > 0 => "some-pos"
    n if Some _ <- n        => "some-nonpos"
    _                       => "none"
r = describe (Some (-1))
|} "r" (VString "some-nonpos")

(* ── Newtype tests ──────────────────────────────────────────────────── *)

let t_newtype_wrap =
  assert_val "newtype Foo = Foo Int\nx = Foo 5\n" "x" (VCon ("Foo", [VInt 5]))

let t_newtype_unwrap =
  assert_val {|newtype Foo = Foo Int
unwrap (Foo n) = n
r = unwrap (Foo 42)
|} "r" (VInt 42)

let t_newtype_deriving_num_add =
  assert_val
    {|newtype Dist = Dist Int deriving (Num)
r : Dist
r = add (Dist 3) (Dist 4)
|}
    "r" (VCon ("Dist", [VInt 7]))

let t_newtype_deriving_num_mul =
  assert_val
    {|newtype Dist = Dist Int deriving (Num)
r : Dist
r = mul (Dist 3) (Dist 4)
|}
    "r" (VCon ("Dist", [VInt 12]))

(* ── Generic deriving (structural to_rep) ────────────────────────────────── *)

let rint n = VCon ("RInt", [VInt n])

let t_generic_data_positional =
  assert_val
    {|data Color = Red | RGB Int Int Int deriving (Generic)
r = to_rep (RGB 1 2 3)
|}
    "r" (VCon ("RCon", [VString "RGB"; VList [rint 1; rint 2; rint 3]]))

let t_generic_data_nullary =
  assert_val
    {|data Color = Red | RGB Int Int Int deriving (Generic)
r = to_rep Red
|}
    "r" (VCon ("RCon", [VString "Red"; VList []]))

let t_generic_record =
  assert_val
    {|record Point
  x : Int
  y : Int
deriving (Generic)
r = to_rep (Point { x = 1, y = 2 })
|}
    "r" (VCon ("RRecord",
      [ VString "Point"
      ; VList
          [ VRecord ("RField", [("fld_name", VString "x"); ("fld_rep", rint 1)])
          ; VRecord ("RField", [("fld_name", VString "y"); ("fld_rep", rint 2)]) ] ]))

let t_generic_newtype =
  assert_val
    {|newtype Wrap = Wrap Int deriving (Generic)
r = to_rep (Wrap 5)
|}
    "r" (VCon ("RCon", [VString "Wrap"; VList [rint 5]]))

(* End-to-end: derive Generic once, write one function over Rep, and get a
   ToJson instance for any deriving type (a data type and a record).  Uses
   String/Bool fields only since the prelude has no Int Show yet. *)
let t_generic_tojson_loop =
  assert_val
    {|interface ToJson a where
    to_json : a -> String

strJson : String -> String
strJson s = "\"" ++ s ++ "\""

rep_to_json : Rep -> String
rep_to_json r = match r
    RString s => strJson s
    RBool b => if b then "true" else "false"
    RCon name fields => "{" ++ strJson "tag" ++ ": " ++ strJson name ++ ", " ++ strJson "fields" ++ ": [" ++ joinReps fields ++ "]}"
    RRecord _ fields => "{" ++ joinFields fields ++ "}"
    _ => "null"

joinReps : List Rep -> String
joinReps [] = ""
joinReps [r] = rep_to_json r
joinReps (r :: rs) = rep_to_json r ++ ", " ++ joinReps rs

joinFields : List RField -> String
joinFields [] = ""
joinFields [f] = strJson f.fld_name ++ ": " ++ rep_to_json f.fld_rep
joinFields (f :: fs) = strJson f.fld_name ++ ": " ++ rep_to_json f.fld_rep ++ ", " ++ joinFields fs

data Shape = Circle String deriving (Generic)

record User
  name : String
  active : Bool
deriving (Generic)

impl ToJson Shape where
    to_json x = rep_to_json (to_rep x)

impl ToJson User where
    to_json x = rep_to_json (to_rep x)

shapeJson = to_json (Circle "red")
userJson  = to_json (User { name = "ann", active = True })
r = (shapeJson, userJson)
|}
    "r" (VTuple
      [ VString {|{"tag": "Circle", "fields": ["red"]}|}
      ; VString {|{"name": "ann", "active": true}|} ])

(* ── Phase 22: Semigroup / Monoid ────────────────────────────────────────── *)

let t_list_semigroup =
  assert_val "x = [1,2] ++ [3,4]\n" "x" (VList [VInt 1; VInt 2; VInt 3; VInt 4])

let t_string_semigroup =
  assert_val {|x = "hello" ++ " world"
|} "x" (VString "hello world")

let t_user_semigroup_dispatch =
  assert_val
    {|interface Semigroup a where
    append : a -> a -> a
data Sum = Sum Int
impl Semigroup Sum where
    append (Sum a) (Sum b) = Sum (a + b)
x = Sum 1 ++ Sum 2
|}
    "x" (VCon ("Sum", [VInt 3]))

(* ── Numeric literal extensions ─────────────────────────────────────────── *)

let t_hex_lit = assert_val "x = 0xFF\n" "x" (VInt 255)
let t_bin_lit = assert_val "x = 0b1010\n" "x" (VInt 10)
let t_oct_lit = assert_val "x = 0o17\n" "x" (VInt 15)
let t_int_underscores = assert_val "x = 1_000_000\n" "x" (VInt 1000000)
let t_int_underscore_arith = assert_val "x = 1_000 + 2_000\n" "x" (VInt 3000)

(* ── String interpolation ─────────────────────────────────────────────── *)

let t_interp_basic =
  assert_val
    "name = \"world\"\nx = \"Hello, \\{name}!\"\n"
    "x" (VString "Hello, world!")

let t_interp_two_holes =
  assert_val
    "a = \"foo\"\nb = \"bar\"\nx = \"\\{a} and \\{b}\"\n"
    "x" (VString "foo and bar")

let t_interp_expr =
  assert_val
    "n = \"Alice\"\ngreeting = \"Hi\"\nx = \"\\{greeting}, \\{n}! Welcome.\"\n"
    "x" (VString "Hi, Alice! Welcome.")

let t_interp_triple_basic =
  assert_val
    "name = \"world\"\nx = \"\"\"Hello, \\{name}!\"\"\"\n"
    "x" (VString "Hello, world!")

let t_interp_triple_two_holes =
  assert_val
    "a = \"foo\"\nb = \"bar\"\nx = \"\"\"\\{a} and \\{b}\"\"\"\n"
    "x" (VString "foo and bar")

(* Assert that lexing src raises Failure with a message containing substr *)
let string_contains haystack needle =
  let hn = String.length haystack and nn = String.length needle in
  if nn = 0 then true
  else if nn > hn then false
  else
    let found = ref false in
    for i = 0 to hn - nn do
      if not !found && String.sub haystack i nn = needle then found := true
    done;
    !found

let assert_lex_err substr src () =
  match (try ignore (parse src); None
         with Failure msg -> Some msg) with
  | Some msg when string_contains msg substr -> ()
  | Some msg ->
    failwith (Printf.sprintf
      "Expected lex error containing %S, got: %s\nSource:\n%s" substr msg src)
  | None ->
    failwith (Printf.sprintf
      "Expected lex error containing %S, but no error was raised\nSource:\n%s"
      substr src)

let t_int_overflow =
  assert_lex_err "overflows"
    "x = 99999999999999999999\n"

(* ── Unary operators ────────────────────────────────────────────────────── *)

let t_bang_true  = assert_val "r = !True\n"  "r" (VBool false)
let t_bang_false = assert_val "r = !False\n" "r" (VBool true)
let t_bang_chain = assert_val "r = !(!True)\n" "r" (VBool true)

(* ── String escape sequences ───────────────────────────────────────────── *)

let t_escape_newline = assert_val "x = \"a\\nb\"\n" "x" (VString "a\nb")
let t_escape_tab     = assert_val "x = \"a\\tb\"\n" "x" (VString "a\tb")
let t_escape_quote   = assert_val "x = \"a\\\"b\"\n" "x" (VString "a\"b")
let t_escape_null    = assert_val "x = \"a\\0b\"\n" "x" (VString "a\000b")
let t_escape_cr      = assert_val "x = \"a\\rb\"\n" "x" (VString "a\rb")
(* \u{2603} → ☃ (encoded as 3 UTF-8 bytes "\xe2\x98\x83") *)
let t_escape_unicode = assert_val "x = \"\\u{2603}\"\n" "x" (VString "\xe2\x98\x83")

(* ── @Name impl selection (Phase 30) ───────────────────────────────────── *)

(* Two named impls for the same interface method — @Name picks one explicitly. *)
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

(* @Name hint used standalone evaluates to VUnit (matches typechecker's Unit inference) *)
let t_at_name_standalone =
  assert_val "r = @Foo\n" "r" VUnit

(* @Name hint that matches no named impl raises Eval_error *)
let t_named_unknown =
  assert_runtime_err (named_impl_src ^ "r = combine @Unknown 3 4\n") "r"

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

(* ── Mixed-Foldable dispatch (positional dispatch metadata) ─────────────

   Regression coverage for the eval-side dispatch fix.  All three Foldable
   impls — List, Option, Result — coexist in the prelude; generic helpers
   like `find` / `count` / `fold` use an Option-typed accumulator (`None`)
   whose runtime tag would, under the old "filter at every arg" logic,
   prematurely commit dispatch to `Foldable Option` before the data arg
   arrived.  These tests pin behaviour for the three container shapes and
   for `Mappable` (whose dispatching arg is the second one, the data). *)

let t_find_on_list_mixed = assert_val
  "r = find (x => x > 2) [1, 2, 3, 4]\n"
  "r" (VCon ("Some", [VInt 3]))

let t_find_on_option_some = assert_val
  "r = find (x => x > 0) (Some 5)\n"
  "r" (VCon ("Some", [VInt 5]))

let t_find_on_option_none = assert_val
  "r : Option Int\nr = find (x => x > 0) None\n"
  "r" (VCon ("None", []))

let t_count_on_list_mixed = assert_val
  "r = count (x => x > 0) [1, 2, 3]\n"
  "r" (VInt 3)

let t_fold_on_some = assert_val
  "r = fold (acc x => acc + x) 0 (Some 10)\n"
  "r" (VInt 10)

let t_fold_on_none = assert_val
  "r : Int\nr = fold (acc x => acc + x) 0 (None : Option Int)\n"
  "r" (VInt 0)

let t_fold_on_ok = assert_val
  "r = fold (acc x => acc + x) 0 (Ok 7 : Result String Int)\n"
  "r" (VInt 7)

let t_length_some = assert_val
  "r = length (Some 5)\n"
  "r" (VInt 1)

let t_length_none = assert_val
  "r = length (None : Option Int)\n"
  "r" (VInt 0)

(* `Mappable` dispatches on position 1 (the container), not 0 (the function).
   With `Mappable List`, `Mappable Option`, `Mappable (Result e)` all in scope,
   both arms must route to the right impl. *)
let t_map_on_list_mixed = assert_val
  "r = map (x => x + 1) [1, 2, 3]\n"
  "r" (VList [VInt 2; VInt 3; VInt 4])

let t_map_on_some_mixed = assert_val
  "r = map (x => x + 1) (Some 5)\n"
  "r" (VCon ("Some", [VInt 6]))

(* ── Local let-rec (Phase 27) ─────────────────────────────────────────── *)

let t_let_rec_fact = assert_val
  "result = let fact n = if n <= 0 then 1 else n * fact (n - 1) in fact 5\n"
  "result" (VInt 120)

let t_let_rec_acc = assert_val
  "result = let go acc n = if n <= 0 then acc else go (acc + n) (n - 1) in go 0 5\n"
  "result" (VInt 15)

let t_where_self_rec = assert_val
  {|sumTo n = go 0 n where
    go acc k = if k <= 0 then acc else go (acc + k) (k - 1)
result = sumTo 5
|}
  "result" (VInt 15)

(* ── Phase 28: field assignment ─────────────────────────────────────────── *)

let person_src = {|record Person
  name : String
  age  : Int

|}

(* Assign a record field and read it back *)
let t_field_assign_record = assert_val
  (person_src ^ {|result =
  do
    let mut p = Person { name = "Alice", age = 30 }
    p.age = 31
    pure p.age
|})
  "result" (VInt 31)

(* Multiple sequential field assignments *)
let t_field_assign_multi = assert_val
  (person_src ^ {|result =
  do
    let mut p = Person { name = "Alice", age = 30 }
    p.age = 99
    p.name = "Bob"
    pure p.name
|})
  "result" (VString "Bob")

(* Ref .value assignment via DoFieldAssign *)
let t_field_assign_ref_value = assert_val
  {|result =
  do
    let mut r = Ref 0
    r.value = 42
    pure r.value
|}
  "result" (VInt 42)

(* ── Record pattern tests (Phase 31) ────────────────────────────────────── *)

let t_rec_pat_pun = assert_val
  (person_src ^ {|result =
  match Person { name = "Alice", age = 30 }
    Person { name } => name
|})
  "result" (VString "Alice")

let t_rec_pat_explicit = assert_val
  (person_src ^ {|result =
  match Person { name = "Alice", age = 30 }
    Person { age = 30 } => 1
    Person { ... } => 0
|})
  "result" (VInt 1)

let t_rec_pat_rest = assert_val
  (person_src ^ {|result =
  match Person { name = "Bob", age = 25 }
    Person { name = "Alice" } => 1
    Person { ... } => 99
|})
  "result" (VInt 99)

(* ── Named-field variants (Phase 39) ───────────────────────────────────── *)

let named_event_src = {|data Event
  | Click { x : Int, y : Int }
  | Scroll Int
|}

let t_named_ctor_create_eval = assert_val
  (named_event_src ^ "result = Click { x = 10, y = 20 }\n")
  "result" (VCon ("Click", [VInt 10; VInt 20]))

let t_named_ctor_pat_eval = assert_val
  (named_event_src ^ {|result =
  match Click { x = 5, y = 7 }
    Click { x, y } => x
    Scroll _ => 0
|})
  "result" (VInt 5)

let t_named_ctor_field_order_eval = assert_val
  (named_event_src ^ {|result =
  match Click { y = 99, x = 3 }
    Click { x, y } => y
    Scroll _ => 0
|})
  "result" (VInt 99)

(* ── Interface default method bodies (Phase 33) ─────────────────────────── *)

(* Default method runs when the impl doesn't override it *)
let t_iface_default_runs = assert_val
  {|interface Greet a where
  name : a -> String
  hello x = "Hello " ++ name x

impl Greet Int where
  name _ = "World"

result = hello 0
|}
  "result" (VString "Hello World")

(* Default method with a where helper runs correctly *)
let t_iface_default_where_runs = assert_val
  {|interface Greet a where
  name : a -> String
  hello x = prefix ++ name x where
    prefix = "Hi "

impl Greet Int where
  name _ = "there"

result = hello 42
|}
  "result" (VString "Hi there")

(* ── if let / let else (Phase 38) ─────────────────────────────────────── *)

let t_if_let_match =
  assert_val "r = if let Some x = Some 5 then x else 0\n" "r" (VInt 5)

let t_if_let_no_match =
  assert_val "r = if let Some x = None then x else 0\n" "r" (VInt 0)

(* Establish Option monad context via DoBind so pure wraps the result *)
let t_let_else_match = assert_val
  {|r = do
  _ <- Some ()
  let Some x = Some 42 else None
  pure x
|}
  "r" (VCon ("Some", [VInt 42]))

let t_let_else_no_match = assert_val
  {|r = do
  _ <- Some ()
  let Some x = None else None
  pure 1
|}
  "r" (VCon ("None", []))

(* ── Range literals (Phase 40) ──────────────────────────────────────────── *)

let t_range_list_half_open =
  assert_val "r = [1..5]\n" "r"
    (VList [VInt 1; VInt 2; VInt 3; VInt 4])

let t_range_list_inclusive =
  assert_val "r = [1..=5]\n" "r"
    (VList [VInt 1; VInt 2; VInt 3; VInt 4; VInt 5])

let t_range_list_empty =
  assert_val "r = [5..3]\n" "r" (VList [])

let t_range_array_half_open =
  assert_val "r = [|0..3|]\n" "r"
    (VArray [| VInt 0; VInt 1; VInt 2 |])

let t_range_array_inclusive =
  assert_val "r = [|1..=3|]\n" "r"
    (VArray [| VInt 1; VInt 2; VInt 3 |])

(* ── Array primitives (stdlib/runtime.mdk externs) ─────────────────────── *)

let t_array_length = assert_val
  "r = arrayLength [|10, 20, 30|]\n" "r" (VInt 3)

let t_array_length_empty = assert_val
  "r = arrayLength [||]\n" "r" (VInt 0)

let t_array_make = assert_val
  "r = arrayMake 4 7\n" "r" (VArray [| VInt 7; VInt 7; VInt 7; VInt 7 |])

let t_array_make_with = assert_val
  "r = arrayMakeWith 5 (i => i * i)\n" "r"
  (VArray [| VInt 0; VInt 1; VInt 4; VInt 9; VInt 16 |])

let t_array_get_unsafe = assert_val
  "r = arrayGetUnsafe 2 [|10, 20, 30, 40|]\n" "r" (VInt 30)

let t_array_set_unsafe = assert_val
  {|r =
  let mut a = [|1, 2, 3|]
  arraySetUnsafe 1 99 a
  arrayGetUnsafe 1 a
|}
  "r" (VInt 99)

let t_array_copy = assert_val
  {|r =
  let a = [|1, 2, 3|]
  let b = arrayCopy a
  arraySetUnsafe 0 999 b
  arrayGetUnsafe 0 a
|}
  "r" (VInt 1)

let t_array_blit = assert_val
  {|r =
  let mut dst = [|0, 0, 0, 0, 0|]
  arrayBlit [|10, 20, 30|] 0 dst 1 3
  dst
|}
  "r" (VArray [| VInt 0; VInt 10; VInt 20; VInt 30; VInt 0 |])

let t_array_fill = assert_val
  {|r =
  let mut a = [|1, 2, 3|]
  arrayFill 42 a
  a
|}
  "r" (VArray [| VInt 42; VInt 42; VInt 42 |])

let t_array_sort_in_place = assert_val
  {|r =
  let mut a = [|3, 1, 4, 1, 5, 9, 2, 6|]
  arraySortInPlaceBy compare a
  a
|}
  "r" (VArray [| VInt 1; VInt 1; VInt 2; VInt 3; VInt 4; VInt 5; VInt 6; VInt 9 |])

let t_array_sort_by_pure = assert_val
  {|r =
  let a = [|3, 1, 4, 1, 5|]
  let b = arraySortBy compare a
  arrayGetUnsafe 0 b
|}
  "r" (VInt 1)

(* `arraySortBy` returns a *fresh* sorted array; the input must be untouched. *)
let t_array_sort_by_pure_no_mutate = assert_val
  {|r =
  let a = [|3, 1, 4|]
  let _ = arraySortBy compare a
  arrayGetUnsafe 0 a
|}
  "r" (VInt 3)

let t_array_from_list = assert_val
  "r = arrayFromList [10, 20, 30]\n" "r"
  (VArray [| VInt 10; VInt 20; VInt 30 |])

let t_array_from_list_empty = assert_val
  "r = arrayFromList []\n" "r" (VArray [||])

let t_range_pat_int_hit =
  assert_val
    "f n =\n  match n\n    1..9 => True\n    _ => False\nresult = f 5\n"
    "result" (VBool true)

let t_range_pat_int_miss =
  assert_val
    "f n =\n  match n\n    1..9 => True\n    _ => False\nresult = f 9\n"
    "result" (VBool false)

let t_range_pat_int_inclusive_boundary =
  assert_val
    "f n =\n  match n\n    1..=9 => True\n    _ => False\nresult = f 9\n"
    "result" (VBool true)

let t_range_pat_char_hit =
  assert_val
    "isLower c =\n  match c\n    'a'..='z' => True\n    _ => False\nresult = isLower 'g'\n"
    "result" (VBool true)

let t_range_pat_char_miss =
  assert_val
    "isLower c =\n  match c\n    'a'..='z' => True\n    _ => False\nresult = isLower 'G'\n"
    "result" (VBool false)

(* ── function keyword (Phase 44) ────────────────────────────────────────── *)

let t_function_eval =
  assert_val
    {|classify =
  function
    0 => "zero"
    _ => "nonzero"
result = classify 0
|}
    "result" (VString "zero")

let t_function_guard_eval =
  assert_val
    {|sign =
  function
    n if n > 0 => 1
    n if n < 0 => -1
    _ => 0
result = sign (-5)
|}
    "result" (VInt (-1))

(* ── Phase 57: let rec ────────────────────────────────────────────────── *)

let t_letrec_top_fact = assert_val
  "let rec fact = n => if n == 0 then 1 else n * fact (n - 1)\n\
   r = fact 5\n"
  "r" (VInt 120)

let t_letrec_top_mutual = assert_val
  "let rec is_even = n => if n == 0 then True else is_odd (n - 1)\n\
   with is_odd = n => if n == 0 then False else is_even (n - 1)\n\
   r = is_even 8\n"
  "r" (VBool true)

let t_letrec_inline = assert_val
  "r = let rec fact = n => if n == 0 then 1 else n * fact (n - 1) in fact 6\n"
  "r" (VInt 720)

let t_letrec_inline_mutual = assert_val
  "r = let rec is_even = n => if n == 0 then True else is_odd (n - 1) with is_odd = n => if n == 0 then False else is_even (n - 1) in is_even 6\n"
  "r" (VBool true)

(* ── Top-level binding order (Phase 59.5) ──────────────────────────────── *)

(* Zero-param binding before the function it calls (which has params). *)
let t_order_zero_param_before_fun =
  assert_val
    "x = f 0\nf n = n + 1\n"
    "x" (VInt 1)

(* Zero-param binding before the impl that provides the method it calls. *)
let t_order_zero_param_before_impl =
  assert_val
    {|interface Tag a where
  tag : a -> Int

x = tag True

impl Tag Bool where
  tag _ = 99
|}
    "x" (VInt 99)

(* Two zero-param bindings where the first references the second. *)
let t_order_zero_param_chain =
  assert_val
    "x = y + 1\ny = 41\n"
    "x" (VInt 42)

(* Genuine unbound name should still produce a clear error, not "applied
   non-function: ()" from an unresolved VUnit placeholder. *)
let t_order_unbound_is_clear_error =
  assert_runtime_err
    "x = noSuchThing\n"
    "x"

(* ── Test registration ──────────────────────────────────────────────────── *)

let () =
  let open Alcotest in
  run "eval" [
    "constants", [
      test_case "int"    `Quick t_int;
      test_case "float"  `Quick t_float;
      test_case "string"          `Quick t_string;
      test_case "triple string"   `Quick t_triple_string;
      test_case "triple multiline"`Quick t_triple_multiline;
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
      test_case "identity"              `Quick t_id;
      test_case "const"                 `Quick t_const;
      test_case "partial"               `Quick t_partial;
      test_case "left section (2 * _)"  `Quick t_left_section_mul;
      test_case "left section (10 - _)" `Quick t_left_section_sub;
      test_case "left section map"      `Quick t_left_section_map;
      test_case "bare section (+)"      `Quick t_bare_section_plus;
      test_case "bare section (-)"      `Quick t_bare_section_minus;
      test_case "bare section (==) T"   `Quick t_bare_section_eq_true;
      test_case "bare section (==) F"   `Quick t_bare_section_eq_false;
      test_case "bare section (::)"     `Quick t_bare_section_cons;
      test_case "bare section fold (+)" `Quick t_bare_section_fold;
      test_case "multi-param lambda 2"  `Quick t_multi_param_lambda_two;
      test_case "multi-param lambda 3"  `Quick t_multi_param_lambda_three;
    ];
    "recursion", [
      test_case "factorial" `Quick t_factorial;
      test_case "list_len"  `Quick t_list_len;
      test_case "let rec top fact"        `Quick t_letrec_top_fact;
      test_case "let rec top mutual"      `Quick t_letrec_top_mutual;
      test_case "let rec inline"          `Quick t_letrec_inline;
      test_case "let rec inline mutual"   `Quick t_letrec_inline_mutual;
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
      test_case "update nested"           `Quick t_record_update_nested;
      test_case "update nested deep"      `Quick t_record_update_nested_deep;
      test_case "update nested unchanged" `Quick t_record_update_nested_unchanged;
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
      test_case "foldMap string" `Quick t_foldmap_string;
      test_case "foldMap list"   `Quick t_foldmap_list;
      test_case "foldMap user monoid" `Quick t_foldmap_user_monoid;
    ];
    "list comprehensions", [
      test_case "guard"              `Quick t_list_comp_guard;
      test_case "multi_gen"          `Quick t_list_comp_multi_gen;
      test_case "let_binding"        `Quick t_list_comp_let;
      test_case "refutable_con"      `Quick t_list_comp_refutable_con;
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
    "? operator", [
      test_case "Ok unwraps"          `Quick t_question_ok;
      test_case "Err short-circuits"  `Quick t_question_err;
      test_case "Some unwraps"        `Quick t_question_some;
      test_case "None short-circuits" `Quick t_question_none;
      test_case "chain Ok/Ok"         `Quick t_question_chain;
      test_case "chain Ok/Err"        `Quick t_question_chain_err;
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
      test_case "mutual recursion"  `Quick t_where_mutual_recursion;
      test_case "match arm"         `Quick t_where_match_arm;
      test_case "guards in where"   `Quick t_where_guards;
      test_case "multi-clause"      `Quick t_where_multi_clause;
      test_case "multi-clause + guards" `Quick t_where_multi_clause_with_guards;
      test_case "top-level multi-clause" `Quick t_toplevel_multi_clause;
      test_case "where on new line"      `Quick t_where_on_new_line;
    ];
    "top-level function guards", [
      test_case "neg branch"        `Quick t_guard_basic_neg;
      test_case "pos branch"        `Quick t_guard_basic_pos;
      test_case "zero branch"       `Quick t_guard_basic_zero;
      test_case "non-exhaustive"    `Quick t_guard_non_exhaustive;
      test_case "pguard bind match"       `Quick t_pguard_bind_match;
      test_case "pguard bind fallthrough" `Quick t_pguard_bind_fallthrough;
      test_case "pguard bind fail"        `Quick t_pguard_bind_fail;
      test_case "pguard filterMap"        `Quick t_pguard_filter_map;
      test_case "pguard match arm"        `Quick t_pguard_match_arm;
    ];
    "newtype declarations", [
      test_case "wrap value"        `Quick t_newtype_wrap;
      test_case "pattern unwrap"    `Quick t_newtype_unwrap;
      test_case "deriving Num add"  `Quick t_newtype_deriving_num_add;
      test_case "deriving Num mul"  `Quick t_newtype_deriving_num_mul;
    ];
    "Generic deriving (to_rep)", [
      test_case "data positional"   `Quick t_generic_data_positional;
      test_case "data nullary"      `Quick t_generic_data_nullary;
      test_case "record"            `Quick t_generic_record;
      test_case "newtype"           `Quick t_generic_newtype;
      test_case "ToJson end-to-end" `Quick t_generic_tojson_loop;
    ];
    "Semigroup / Monoid (Phase 22)", [
      test_case "List ++ List"              `Quick t_list_semigroup;
      test_case "String ++ String"          `Quick t_string_semigroup;
      test_case "user-defined dispatch"     `Quick t_user_semigroup_dispatch;
    ];
    "numeric literal extensions", [
      test_case "hex literal"         `Quick t_hex_lit;
      test_case "binary literal"      `Quick t_bin_lit;
      test_case "octal literal"       `Quick t_oct_lit;
      test_case "int underscores"     `Quick t_int_underscores;
      test_case "int underscore arith" `Quick t_int_underscore_arith;
    ];
    "string interpolation", [
      test_case "basic hole"          `Quick t_interp_basic;
      test_case "two holes"           `Quick t_interp_two_holes;
      test_case "greeting expr"       `Quick t_interp_expr;
      test_case "triple basic"        `Quick t_interp_triple_basic;
      test_case "triple two holes"    `Quick t_interp_triple_two_holes;
    ];
    "int literal errors", [
      test_case "overflow" `Quick t_int_overflow;
    ];
    "@Name impl selection (Phase 30)", [
      test_case "@Additive selects +"       `Quick t_named_additive;
      test_case "@Multiplicative selects *" `Quick t_named_multiplicative;
      test_case "@Name standalone = Unit"   `Quick t_at_name_standalone;
      test_case "@Unknown raises error"     `Quick t_named_unknown;
    ];
    "multi-impl dispatch (VMulti)", [
      test_case "list non-empty"    `Quick t_dispatch_list;
      test_case "option Some"       `Quick t_dispatch_option_some;
      test_case "option None"       `Quick t_dispatch_option_none;
      test_case "list empty"        `Quick t_dispatch_list_empty;
    ];
    "mixed-Foldable dispatch", [
      test_case "find on List"      `Quick t_find_on_list_mixed;
      test_case "find on Some"      `Quick t_find_on_option_some;
      test_case "find on None"      `Quick t_find_on_option_none;
      test_case "count on List"     `Quick t_count_on_list_mixed;
      test_case "fold on Some"      `Quick t_fold_on_some;
      test_case "fold on None"      `Quick t_fold_on_none;
      test_case "fold on Ok"        `Quick t_fold_on_ok;
      test_case "length (Some _)"   `Quick t_length_some;
      test_case "length None"       `Quick t_length_none;
      test_case "map on List"       `Quick t_map_on_list_mixed;
      test_case "map on Some"       `Quick t_map_on_some_mixed;
    ];
    "unary operators", [
      test_case "!True"        `Quick t_bang_true;
      test_case "!False"       `Quick t_bang_false;
      test_case "double negation" `Quick t_bang_chain;
    ];
    "string escape sequences", [
      test_case "\\n"          `Quick t_escape_newline;
      test_case "\\t"          `Quick t_escape_tab;
      test_case "\\\""         `Quick t_escape_quote;
      test_case "\\0"          `Quick t_escape_null;
      test_case "\\r"          `Quick t_escape_cr;
      test_case "\\u{2603}"    `Quick t_escape_unicode;
    ];
    "local let-rec (Phase 27)", [
      test_case "factorial"        `Quick t_let_rec_fact;
      test_case "accumulator"      `Quick t_let_rec_acc;
      test_case "where self-rec"   `Quick t_where_self_rec;
    ];
    "field assignment (Phase 28)", [
      test_case "record field update"         `Quick t_field_assign_record;
      test_case "multiple field updates"      `Quick t_field_assign_multi;
      test_case "Ref .value assign"           `Quick t_field_assign_ref_value;
    ];
    "record patterns (Phase 31)", [
      test_case "pun binds field"            `Quick t_rec_pat_pun;
      test_case "explicit pattern match"     `Quick t_rec_pat_explicit;
      test_case "wildcard rest catch-all"    `Quick t_rec_pat_rest;
    ];
    "named-field variants (Phase 39)", [
      test_case "construction"               `Quick t_named_ctor_create_eval;
      test_case "pattern binding"            `Quick t_named_ctor_pat_eval;
      test_case "field order in match"       `Quick t_named_ctor_field_order_eval;
    ];
    "interface default methods (Phase 33)", [
      test_case "default method runs"         `Quick t_iface_default_runs;
      test_case "default with where helper"   `Quick t_iface_default_where_runs;
    ];
    "if let / let else (Phase 38)", [
      test_case "if let match"         `Quick t_if_let_match;
      test_case "if let no match"      `Quick t_if_let_no_match;
      test_case "let else match"       `Quick t_let_else_match;
      test_case "let else no match"    `Quick t_let_else_no_match;
    ];
    "range literals (Phase 40)", [
      test_case "list [1..5] = [1,2,3,4]"          `Quick t_range_list_half_open;
      test_case "list [1..=5] = [1,2,3,4,5]"       `Quick t_range_list_inclusive;
      test_case "list empty when lo > hi"            `Quick t_range_list_empty;
      test_case "array [|0..3|] = |0,1,2|"          `Quick t_range_array_half_open;
      test_case "array [|1..=3|] = |1,2,3|"         `Quick t_range_array_inclusive;
      test_case "arrayLength"                        `Quick t_array_length;
      test_case "arrayLength empty"                  `Quick t_array_length_empty;
      test_case "arrayMake fills constant"           `Quick t_array_make;
      test_case "arrayMakeWith calls per-index"      `Quick t_array_make_with;
      test_case "arrayGetUnsafe"                     `Quick t_array_get_unsafe;
      test_case "arraySetUnsafe mutates"             `Quick t_array_set_unsafe;
      test_case "arrayCopy is independent"           `Quick t_array_copy;
      test_case "arrayBlit range copy"               `Quick t_array_blit;
      test_case "arrayFill overwrites all"           `Quick t_array_fill;
      test_case "arraySortInPlaceBy"                 `Quick t_array_sort_in_place;
      test_case "arraySortBy returns sorted"         `Quick t_array_sort_by_pure;
      test_case "arraySortBy doesn't mutate input"   `Quick t_array_sort_by_pure_no_mutate;
      test_case "arrayFromList"                      `Quick t_array_from_list;
      test_case "arrayFromList empty"                `Quick t_array_from_list_empty;
      test_case "pat int hit (5 in 1..9)"            `Quick t_range_pat_int_hit;
      test_case "pat int miss (9 not in 1..9)"       `Quick t_range_pat_int_miss;
      test_case "pat int inclusive boundary (9 in 1..=9)" `Quick t_range_pat_int_inclusive_boundary;
      test_case "pat char hit ('g' in 'a'..'z')"    `Quick t_range_pat_char_hit;
      test_case "pat char miss ('G' not in 'a'..'z')" `Quick t_range_pat_char_miss;
    ];
    "function keyword (Phase 44)", [
      test_case "classify 0 = zero"          `Quick t_function_eval;
      test_case "sign (-5) = -1 with guard"  `Quick t_function_guard_eval;
    ];
    "top-level binding order (Phase 59.5)", [
      test_case "zero-param before fun"        `Quick t_order_zero_param_before_fun;
      test_case "zero-param before impl"       `Quick t_order_zero_param_before_impl;
      test_case "zero-param chain"             `Quick t_order_zero_param_chain;
      test_case "unbound gives clear error"    `Quick t_order_unbound_is_clear_error;
    ];
  ]
