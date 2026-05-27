(* Thorough cross-feature interaction tests.

   These exercise combinations of features that usually pass independently
   but might break in combination.  Categories:

   1. Records ⊗ interfaces — deriving and impl over a record type
   2. Newtypes ⊗ interfaces — deriving and method dispatch
   3. ADTs ⊗ pattern matching ⊗ exhaustiveness — nested + named-field
   4. Do-blocks ⊗ records — building records inside a monadic context
   5. Where clauses ⊗ polymorphism ⊗ mutual recursion
   6. Pipe / compose ⊗ HOFs ⊗ polymorphism
   7. List comprehensions ⊗ ADT scrutinee
   8. @Name dispatch ⊗ multiple impl candidates
   9. Typecheck-eval skew — programs accepted by one but rejected by
      the other (a smoke test for the divide-and-conquer test
      organization that hides these gaps).
   10. Interpolation ⊗ records / show

   Each test runs the full pipeline (typecheck + eval) where possible,
   making it strict: a regression in either layer is caught. *)

open Medaka_lib.Eval
open Thorough_helpers

(* =====================================================================
   1. Records ⊗ interfaces
   ===================================================================== *)

(* Phase 45.6 FIXED — VRecord now carries its type name, so VMulti
   dispatch on a method like `show` routes to the correct impl even
   when another impl with a wildcard pattern (like `impl Show Int
   where show x = "I"`) is in scope. *)

(* Custom Show Int + derived Show Point: each dispatches correctly. *)
let t_record_show_with_int_show =
  assert_val
    {|impl Show Int where
  show x = "I"
record Point
  x : Int
  y : Int
deriving (Show)
p = Point { x = 3, y = 4 }
intShow = show 5
recShow = show p
r = (intShow, recShow)
|}
    "r" (VTuple [VString "I"; VString "Point { x = I, y = I }"])

(* Simple derived Show case (single impl in scope). *)
let t_record_deriving_show_no_other_impl =
  assert_val
    {|record Point
  x : Int
  y : Int
deriving (Show)
p = Point { x = 3, y = 4 }
r = match p
  Point { x = 0, y = 0 } => "origin"
  _ => "somewhere"
|}
    "r" (VString "somewhere")

(* deriving Eq on a record — still fails because there's no Eq impl
   for the Int fields, but for a different reason (constraint
   solving), not the VRecord type-tag bug. *)
let e_record_deriving_eq_no_int_impl =
  assert_err
    {|record Point
  x : Int
  y : Int
deriving (Eq)
p1 = Point { x = 1, y = 2 }
p2 = Point { x = 1, y = 2 }
r = eq p1 p2
|}

(* With a user-provided Eq Int impl, deriving Eq on a record works. *)
let t_record_deriving_eq_with_int_eq =
  assert_val
    {|impl Eq Int where
  eq a b = a == b
record Point
  x : Int
  y : Int
deriving (Eq)
p1 = Point { x = 1, y = 2 }
p2 = Point { x = 1, y = 2 }
p3 = Point { x = 1, y = 3 }
r = (eq p1 p2, eq p1 p3)
|}
    "r" (VTuple [VBool true; VBool false])

(* User-defined impl over a record. *)
let t_record_user_impl =
  assert_typed_val
    {|record Box
  weight : Int
interface Heavy a where
  isHeavy : a -> Bool
impl Heavy Box where
  isHeavy b = b.weight > 10
r = isHeavy (Box { weight = 15 })
|}
    "r" "Bool" (VBool true)

(* =====================================================================
   2. Newtypes ⊗ interfaces
   ===================================================================== *)

let t_newtype_deriving_num =
  assert_typed_val
    {|newtype Dollars = Dollars Int deriving (Num)
total : Dollars
total = add (Dollars 5) (Dollars 10)
unwrap (Dollars n) = n
r = unwrap total
|}
    "r" "Int" (VInt 15)

let t_newtype_user_impl =
  assert_typed_val
    {|newtype Mass = Mass Int
interface Describe a where
  describe : a -> String
impl Describe Mass where
  describe (Mass n) = "mass=" ++ "kg"
r = describe (Mass 42)
|}
    "r" "String" (VString "mass=kg")

(* =====================================================================
   3. ADTs ⊗ pattern matching ⊗ exhaustiveness
   ===================================================================== *)

(* Three-way ADT with named-field + positional constructors.  The
   multi-line block form puts each `| Ctor` on its own line with no
   leading `=`. *)
let t_adt_mixed_ctors =
  assert_typed_val
    {|data Shape
  | Circle Int
  | Rect { width : Int, height : Int }
  | Triangle Int Int Int
area s = match s
  Circle r => r * r * 3
  Rect { width = w, height = h } => w * h
  Triangle a b c => (a + b + c) / 2
r = area (Rect { width = 4, height = 5 })
|}
    "r" "Int" (VInt 20)

let t_adt_mixed_circle =
  assert_val
    {|data Shape
  | Circle Int
  | Rect { width : Int, height : Int }
  | Triangle Int Int Int
area s = match s
  Circle r => r * r * 3
  Rect { width = w, height = h } => w * h
  Triangle a b c => (a + b + c) / 2
r = area (Circle 5)
|}
    "r" (VInt 75)

(* Pun in record pattern *)
let t_adt_pun_in_pat =
  assert_val
    {|data Shape = Rect { width : Int, height : Int }
area s = match s
  Rect { width, height } => width * height
r = area (Rect { width = 3, height = 7 })
|}
    "r" (VInt 21)

(* Rest-pattern in record pattern *)
let t_adt_rest_in_pat =
  assert_val
    {|data Shape = Rect { width : Int, height : Int, color : String }
area s = match s
  Rect { width, ... } => width
r = area (Rect { width = 3, height = 7, color = "red" })
|}
    "r" (VInt 3)

(* =====================================================================
   4. Do-blocks ⊗ records
   ===================================================================== *)

let t_do_build_record =
  assert_val
    {|record P
  a : Int
  b : Int
r = do
  x <- Some 5
  y <- Some 7
  pure (P { a = x, b = y })
|}
    "r" (VCon ("Some", [VRecord ("P", [("a", VInt 5); ("b", VInt 7)])]))

let t_do_record_field_in_pat =
  assert_val
    {|record P
  v : Int
r = do
  p <- Some (P { v = 42 })
  pure p.v
|}
    "r" (VCon ("Some", [VInt 42]))

(* =====================================================================
   5. Where clauses ⊗ polymorphism ⊗ mutual recursion
   ===================================================================== *)

let t_where_poly_and_mutual =
  assert_typed_val
    {|alternate xs ys = a xs ys where
  a [] ys = ys
  a (x::rest) ys = x :: b rest ys
  b xs [] = xs
  b xs (y::rest) = y :: a xs rest
r = alternate [1, 3, 5] [2, 4, 6]
|}
    "r" "List Int"
    (VList [VInt 1; VInt 2; VInt 3; VInt 4; VInt 5; VInt 6])

(* =====================================================================
   6. Pipe / compose ⊗ HOFs ⊗ polymorphism
   ===================================================================== *)

let t_pipe_into_map =
  assert_typed_val
    {|inc x = x + 1
r = [1, 2, 3] |> map inc
|}
    "r" "List Int" (VList [VInt 2; VInt 3; VInt 4])

let t_compose_then_apply =
  assert_typed_val
    {|inc x = x + 1
dbl x = x * 2
f = map (inc >> dbl)
r = f [1, 2, 3]
|}
    "r" "List Int" (VList [VInt 4; VInt 6; VInt 8])

(* =====================================================================
   7. List comprehensions ⊗ ADT scrutinee
   ===================================================================== *)

(* DIVERGENCE: in Haskell, `[x | Just x <- xs]` silently filters out
   Nothing values.  Medaka desugars `pat <- xs` to
   `andThen xs (pat => ...)`, which raises a non-exhaustive match
   panic when `pat` doesn't match.  Document the current behavior:
   the comprehension generator pattern MUST be irrefutable.  Listed
   as a divergence from Haskell that may warrant a design decision. *)
let t_list_comp_with_ctor_pin =
  assert_runtime_err
    {|data Maybe a = Just a | Nothing
keepJust xs = [x | Just x <- xs]
r = keepJust [Just 1, Nothing, Just 2, Nothing, Just 3]
|}
    "r"

(* Irrefutable variant: tuple pattern always matches on a tuple list. *)
let t_list_comp_with_irrefutable =
  assert_val
    {|r = [a + b | (a, b) <- [(1, 2), (3, 4), (5, 6)]]
|}
    "r" (VList [VInt 3; VInt 7; VInt 11])

(* =====================================================================
   8. @Name dispatch ⊗ multiple impl candidates
   ===================================================================== *)

let t_named_dispatch_among_three =
  assert_typed_val
    {|interface Combine a where
  combine : a -> a -> a
impl First of Combine Int where
  combine x y = x
impl Last of Combine Int where
  combine x y = y
impl Sum of Combine Int where
  combine x y = x + y
a = combine @First 3 4
b = combine @Last 3 4
c = combine @Sum 3 4
r = (a, b, c)
|}
    "r" "(Int, Int, Int)"
    (VTuple [VInt 3; VInt 4; VInt 7])

(* =====================================================================
   9. Typecheck/eval skew — found via this very test suite
   ===================================================================== *)

(* The string-interpolation `\{Int}` case: typecheck rejects, eval
   accepts.  See thorough_typecheck.ml::e_interp_int_hole and
   thorough_eval.ml::t_string_interp_int. *)
let tc_eval_skew_interp_int_hole_tc =
  (* The TYPECHECKER rejects this program. *)
  assert_err {|x = "v=\{1 + 1}"
|}

(* If the typechecker is fixed to allow this via implicit Show, this
   test will fail and we'll know to update the documented skew. *)

(* =====================================================================
   10. Interpolation ⊗ records / show
   ===================================================================== *)

(* show on a record (deriving Show) used inside an interpolation hole.
   The hole expects String, and `show p` returns String — should work. *)
(* With Phase 45.6 fixed, `show p` on a record dispatches correctly
   when other Show impls are in scope.  This test combines a custom
   Show Int impl, deriving (Show) on the record, and interpolation. *)
let t_interp_with_show_record =
  assert_typed_val
    {|impl Show Int where
  show x = "I"
record P
  x : Int
  y : Int
deriving (Show)
p = P { x = 1, y = 2 }
r = "point: \{show p}"
|}
    "r" "String"
    (VString "point: P { x = I, y = I }")

let t_interp_with_show_string =
  assert_typed_val
    {|n = "Alice"
r = "name: \{n}"
|}
    "r" "String" (VString "name: Alice")

(* =====================================================================
   11. Effects ⊗ do-blocks ⊗ control flow
   ===================================================================== *)

(* if-then-else in do-block body with IO effect annotation *)
let t_do_if_in_io =
  assert_stdout
    {|main : <IO> Unit
main = do
  let x = 3
  if x > 0 then println "pos" else println "neg"
|}
    "pos\n"

(* let mut + DoAssign + IO *)
let t_do_let_mut_assign =
  assert_stdout
    {|main : <IO> Unit
main = do
  let mut x = 0
  x = x + 10
  x = x + 5
  println x
|}
    "15\n"

(* =====================================================================
   12. Where clause inside an impl method
   ===================================================================== *)

let t_impl_with_where =
  assert_typed_val
    {|interface Size a where
  sz : a -> Int
data Bag a = Bag (List a)
impl Size (Bag a) where
  sz (Bag xs) = countList xs where
    countList [] = 0
    countList (_::rest) = 1 + countList rest
r = sz (Bag [1, 2, 3, 4])
|}
    "r" "Int" (VInt 4)

(* =====================================================================
   13. Big composition: foldMap with custom Monoid
   ===================================================================== *)

let t_foldmap_user_monoid =
  assert_typed_val
    {|data Sum = MkSum Int
impl Semigroup Sum where
  append (MkSum a) (MkSum b) = MkSum (a + b)
impl Monoid Sum where
  empty = MkSum 0
unwrap (MkSum n) = n
r = unwrap (foldMap MkSum [1, 2, 3, 4, 5])
|}
    "r" "Int" (VInt 15)

(* =====================================================================
   14. Range ⊗ pattern + fold + comprehension
   ===================================================================== *)

let t_range_pipeline =
  assert_val
    {|r = [x * x | x <- [1..=5], x > 2]
|}
    "r" (VList [VInt 9; VInt 16; VInt 25])

(* =====================================================================
   15. Polymorphic constructor + match — fold over a tree
   ===================================================================== *)

let t_tree_sum =
  assert_typed_val
    {|data Tree a = Leaf | Node (Tree a) a (Tree a)
sumTree t = match t
  Leaf => 0
  Node l v r => v + sumTree l + sumTree r
t = Node (Node Leaf 1 Leaf) 2 (Node Leaf 3 (Node Leaf 4 Leaf))
r = sumTree t
|}
    "r" "Int" (VInt 10)

(* =====================================================================
   16. Application discipline / partial application
   ===================================================================== *)

let t_curry_then_pipe =
  assert_typed_val
    {|add x y = x + y
r = 1 |> (add 10) |> (add 20)
|}
    "r" "Int" (VInt 31)

(* =====================================================================
   17. Multi-clause function definitions
   ===================================================================== *)

let t_multi_clause_literal =
  assert_typed_val
    {|describe 0 = "zero"
describe 1 = "one"
describe _ = "many"
r = (describe 0, describe 1, describe 5)
|}
    "r" "(String, String, String)"
    (VTuple [VString "zero"; VString "one"; VString "many"])

let t_multi_clause_ctor =
  assert_typed_val
    {|unwrap (Some n) = n
unwrap None = 0
r = (unwrap (Some 42), unwrap None)
|}
    "r" "(Int, Int)"
    (VTuple [VInt 42; VInt 0])

let t_multi_clause_with_guard =
  assert_typed_val
    {|classify n
  | n < 0 = "neg"
  | n > 0 = "pos"
  | True  = "zero"
r = (classify 5, classify (-3), classify 0)
|}
    "r" "(String, String, String)"
    (VTuple [VString "pos"; VString "neg"; VString "zero"])

(* =====================================================================
   18. End-to-end: a small real-ish program
   ===================================================================== *)

(* Word count over a list of strings, using stdlib HOFs *)
let t_program_word_count =
  assert_typed_val
    {|wordCount xs = fold (acc => s => acc + 1) 0 xs
r = wordCount ["the", "quick", "brown", "fox"]
|}
    "r" "Int" (VInt 4)

(* FizzBuzz-style classification.  Uses single-line if-else-if because
   multi-line if-else-if doesn't parse (Phase 45.7 in PLAN.md). *)
let t_program_fizz =
  assert_typed_val
    {|fizz n = if n % 15 == 0 then "FizzBuzz" else if n % 3 == 0 then "Fizz" else if n % 5 == 0 then "Buzz" else "n"
r = (fizz 15, fizz 9, fizz 25, fizz 7)
|}
    "r" "(String, String, String, String)"
    (VTuple [VString "FizzBuzz"; VString "Fizz"; VString "Buzz"; VString "n"])

(* Binary tree: insert + flatten.  Match-arm bodies use single-line
   if-else (Phase 45.7) and the helper `chooseInsert` for clarity. *)
let t_program_bst_inorder =
  assert_typed_val
    {|data Tree = Leaf | Node Tree Int Tree
insert t v = match t
  Leaf => Node Leaf v Leaf
  Node l x rest => if v < x then Node (insert l v) x rest else if v > x then Node l x (insert rest v) else t
flatten t = match t
  Leaf => []
  Node l x rest => flatten l ++ [x] ++ flatten rest
t = insert (insert (insert (insert Leaf 5) 2) 8) 3
r = flatten t
|}
    "r" "List Int"
    (VList [VInt 2; VInt 3; VInt 5; VInt 8])

(* Pipeline: filter + map + fold.  Pipe operators must stay on the
   same line as the preceding expression (newline-broken pipe chains
   don't parse, also Phase 45.7-area). *)
let t_program_pipeline =
  assert_typed_val
    {|r = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] |> filter (x => x % 2 == 0) |> map (x => x * x) |> fold (a => b => a + b) 0
|}
    "r" "Int" (VInt 220)
(* squares of [2,4,6,8,10] = [4,16,36,64,100] sum = 220 *)

(* =====================================================================
   19. Recursive impl methods
   ===================================================================== *)

(* A `Sized` interface impl on a recursive Tree type — the impl method
   is allowed to call itself.  Tests the resolver/typechecker handling
   of impl-method recursion. *)
let t_recursive_impl_method =
  assert_typed_val
    {|data Tree = Leaf | Node Tree Tree
interface Sized t where
  sz : t -> Int
impl Sized Tree where
  sz Leaf = 0
  sz (Node l r) = 1 + sz l + sz r
r = sz (Node (Node Leaf Leaf) Leaf)
|}
    "r" "Int" (VInt 2)

(* =====================================================================
   20. User-defined Foldable impl
   ===================================================================== *)

let t_user_foldable =
  assert_typed_val
    {|data Wrap a = Wrap (List a)
impl Foldable Wrap where
  fold f acc (Wrap xs) = fold f acc xs
  foldRight f acc (Wrap xs) = foldRight f acc xs
  toList (Wrap xs) = xs
  isEmpty (Wrap xs) = isEmpty xs
  length (Wrap xs) = length xs
r = fold (a => b => a + b) 0 (Wrap [10, 20, 30])
|}
    "r" "Int" (VInt 60)

(* =====================================================================
   21. Nested do-blocks
   ===================================================================== *)

let t_nested_do =
  assert_val
    {|r = do
  x <- Some 5
  inner <- do
    y <- Some 10
    pure (x + y)
  pure inner
|}
    "r" (VCon ("Some", [VInt 15]))

(* =====================================================================
   22. Constructor as function value
   ===================================================================== *)

let t_ctor_as_function =
  assert_val
    {|f = Some
r = f 42
|}
    "r" (VCon ("Some", [VInt 42]))

let t_ctor_in_pipe =
  assert_val
    {|r = 5 |> Some
|}
    "r" (VCon ("Some", [VInt 5]))

let t_ctor_in_map =
  assert_val
    {|r = map Some [1, 2, 3]
|}
    "r" (VList [VCon ("Some", [VInt 1]); VCon ("Some", [VInt 2]); VCon ("Some", [VInt 3])])

(* =====================================================================
   23. Field access chained with function call
   ===================================================================== *)

let t_field_then_call =
  assert_val
    {|record P
  v : List Int
p = P { v = [1, 2, 3] }
r = length p.v
|}
    "r" (VInt 3)

(* =====================================================================
   24. Where-clause shadowing
   ===================================================================== *)

(* In where clauses, the where binding shadows outer bindings of the
   same name within the function body. *)
let t_where_shadow =
  assert_val
    {|x = 10
r = x where
  x = 20
|}
    "r" (VInt 20)

(* =====================================================================
   25. Multi-method interface constraint usage
   ===================================================================== *)

let t_multi_method_constraint =
  assert_typed_val
    {|interface Container c where
  isEmpty : c a -> Bool
  size : c a -> Int
impl Container List where
  isEmpty [] = True
  isEmpty _ = False
  size = length
both : Container c => c a -> (Bool, Int)
both x = (isEmpty x, size x)
r = both [1, 2, 3]
|}
    "r" "(Bool, Int)"
    (VTuple [VBool false; VInt 3])

(* =====================================================================
   26. Nested ADT — Expr evaluator
   ===================================================================== *)

let t_nested_adt_expr =
  assert_typed_val
    {|data Expr
  | Lit Int
  | Add Expr Expr
  | Mul Expr Expr
evalExpr e = match e
  Lit n => n
  Add a b => evalExpr a + evalExpr b
  Mul a b => evalExpr a * evalExpr b
r = evalExpr (Mul (Add (Lit 1) (Lit 2)) (Lit 3))
|}
    "r" "Int" (VInt 9)

(* =====================================================================
   27. Default impl declaration via `default impl`
   ===================================================================== *)

let t_default_impl =
  assert_val
    {|interface Show2 a where
  show2 : a -> String
data D = MkD
default impl Show2 D where
  show2 _ = "D"
r = show2 MkD
|}
    "r" (VString "D")

(* =====================================================================
   28. if-let with else binding via pair test
   ===================================================================== *)

let t_if_let_else_pair =
  assert_val
    {|f opt = if let Some n = opt then n else 0
r = (f (Some 5), f None)
|}
    "r" (VTuple [VInt 5; VInt 0])

(* =====================================================================
   29. Pair lambda
   ===================================================================== *)

let t_pair_lambda =
  assert_val
    {|swap = ((a, b) => (b, a))
r = swap (1, "x")
|}
    "r" (VTuple [VString "x"; VInt 1])

(* =====================================================================
   Test registration
   ===================================================================== *)

let () =
  let open Alcotest in
  run "thorough interactions"
    [
      ( "records + interfaces",
        [ test_case "Show dispatches by type"   `Quick t_record_show_with_int_show
        ; test_case "deriving Show (sole impl)" `Quick t_record_deriving_show_no_other_impl
        ; test_case "err: deriving Eq no Int Eq" `Quick e_record_deriving_eq_no_int_impl
        ; test_case "deriving Eq w/ Int Eq"     `Quick t_record_deriving_eq_with_int_eq
        ; test_case "user impl over record"     `Quick t_record_user_impl
        ] );
      ( "newtypes + interfaces",
        [ test_case "deriving Num"          `Quick t_newtype_deriving_num
        ; test_case "user impl"             `Quick t_newtype_user_impl
        ] );
      ( "ADTs + match + exhaust",
        [ test_case "mixed ctors: rect"     `Quick t_adt_mixed_ctors
        ; test_case "mixed ctors: circle"   `Quick t_adt_mixed_circle
        ; test_case "pun in record pat"     `Quick t_adt_pun_in_pat
        ; test_case "rest in record pat"    `Quick t_adt_rest_in_pat
        ] );
      ( "do + records",
        [ test_case "build record in do"    `Quick t_do_build_record
        ; test_case "access field in do"    `Quick t_do_record_field_in_pat
        ] );
      ( "where + poly + mutual",
        [ test_case "alternate via mutual"  `Quick t_where_poly_and_mutual
        ] );
      ( "pipe/compose + HOF",
        [ test_case "[..] |> map"           `Quick t_pipe_into_map
        ; test_case "map (f >> g)"          `Quick t_compose_then_apply
        ] );
      ( "list-comp + ADT",
        [ test_case "refutable pat -> err"  `Quick t_list_comp_with_ctor_pin
        ; test_case "irrefutable tuple ok"  `Quick t_list_comp_with_irrefutable
        ] );
      ( "@Name across three impls",
        [ test_case "First/Last/Sum"        `Quick t_named_dispatch_among_three
        ] );
      ( "tc/eval skew",
        [ test_case "interp int hole: tc rejects" `Quick tc_eval_skew_interp_int_hole_tc
        ] );
      ( "interp + show",
        [ test_case "record via show"       `Quick t_interp_with_show_record
        ; test_case "string hole"           `Quick t_interp_with_show_string
        ] );
      ( "effects + do",
        [ test_case "if in do <IO>"         `Quick t_do_if_in_io
        ; test_case "let mut + assign"      `Quick t_do_let_mut_assign
        ] );
      ( "impl with where helper",
        [ test_case "Size (Bag a)"          `Quick t_impl_with_where
        ] );
      ( "foldMap user Monoid",
        [ test_case "Sum of [1..5]"         `Quick t_foldmap_user_monoid
        ] );
      ( "range pipeline",
        [ test_case "[x*x | x<-..]"         `Quick t_range_pipeline
        ] );
      ( "tree sum",
        [ test_case "sumTree small"         `Quick t_tree_sum
        ] );
      ( "curry + pipe",
        [ test_case "1 |> add 10 |> add 20" `Quick t_curry_then_pipe
        ] );
      ( "multi-clause defs",
        [ test_case "by literal"     `Quick t_multi_clause_literal
        ; test_case "by ctor"        `Quick t_multi_clause_ctor
        ; test_case "with guard"     `Quick t_multi_clause_with_guard
        ] );
      ( "end-to-end programs",
        [ test_case "word count"     `Quick t_program_word_count
        ; test_case "fizz/buzz"      `Quick t_program_fizz
        ; test_case "BST inorder"    `Quick t_program_bst_inorder
        ; test_case "filter|map|fold" `Quick t_program_pipeline
        ] );
      ( "recursive impl methods",
        [ test_case "Sized over Tree" `Quick t_recursive_impl_method
        ] );
      ( "user Foldable",
        [ test_case "Wrap List + fold" `Quick t_user_foldable
        ] );
      ( "nested do",
        [ test_case "Option in Option" `Quick t_nested_do
        ] );
      ( "constructor as value",
        [ test_case "Some bound directly" `Quick t_ctor_as_function
        ; test_case "Some in pipe"        `Quick t_ctor_in_pipe
        ; test_case "Some in map"         `Quick t_ctor_in_map
        ] );
      ( "field then call",
        [ test_case "length p.v"     `Quick t_field_then_call
        ] );
      ( "where shadow",
        [ test_case "binding shadows outer" `Quick t_where_shadow
        ] );
      ( "multi-method constraint",
        [ test_case "Container [List]"   `Quick t_multi_method_constraint
        ] );
      ( "nested ADT",
        [ test_case "Expr evaluator"     `Quick t_nested_adt_expr
        ] );
      ( "default impl",
        [ test_case "Show2 D default"    `Quick t_default_impl
        ] );
      ( "if-let",
        [ test_case "with else pair"     `Quick t_if_let_else_pair
        ] );
      ( "pair lambda",
        [ test_case "swap"               `Quick t_pair_lambda
        ] );
    ]
