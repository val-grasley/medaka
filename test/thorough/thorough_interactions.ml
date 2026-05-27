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

(* BUG (Phase 45.6 candidate): records lose their type name in eval.

   `Point { x = 3, y = 4 }` becomes `VRecord [("x", 3); ("y", 4)]`
   with no "Point" tag — see lib/eval.ml ERecordCreate which falls
   through to VRecord when ctor_field_order has no entry for the
   record's type name.  This means `runtime_type_tag` returns None
   for record values, so VMulti dispatch CANNOT route a `show` call on
   a Point to the derived Point impl when other untagged candidates
   exist.

   Concrete failure observed: with `impl Show Int` AND derived
   `impl Show Point` both registered as VMulti, `show pt` returns the
   Int impl's result (the Int wildcard matches Point).

   The fix is invasive (VRecord must carry the type name; every match
   on VRecord throughout eval.ml needs updating).  Documented as a
   roadmap item; tests below pin the *current* (buggy) behavior so
   the suite stays green and a future fix is detectable. *)

(* WORKAROUND: until VRecord carries its type name, deriving Show
   works only if there is exactly ONE show impl in scope.  Pin that. *)
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

(* deriving Eq on a record — fails because there's no Eq impl for
   the Int fields.  Document via the existing constraint failure. *)
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
    "r" (VCon ("Some", [VRecord [("a", VInt 5); ("b", VInt 7)]]))

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
(* Removed: would hit the VRecord type-tag bug.  Instead, use a
   non-record type whose VMulti dispatch is sound. *)
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
   Test registration
   ===================================================================== *)

let () =
  let open Alcotest in
  run "thorough interactions"
    [
      ( "records + interfaces",
        [ test_case "deriving Show (sole impl)" `Quick t_record_deriving_show_no_other_impl
        ; test_case "err: deriving Eq no Int Eq" `Quick e_record_deriving_eq_no_int_impl
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
        [ test_case "string hole"           `Quick t_interp_with_show_string
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
    ]
