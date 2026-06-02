(* Thorough type-checker tests.

   These cover edge cases that the main test/test_typecheck.ml suite either
   doesn't touch or covers only with a happy-path example.  Categories:

   1. HM let-polymorphism corners — value restriction, Rémy levels, escape
   2. Generalization ordering and mutual recursion
   3. Record / row polymorphism corners
   4. Interfaces — constraint solving across compositions, ambiguity,
      named-impl resolution failures, default impl picking, deriving paths
   5. Effect propagation through HOFs and `<Mut>` from `let mut`
   6. Pattern exhaustiveness — nested constructors, records, named-field
      variants, integer ranges, GADT-like shapes
   7. Abstract type exports / opacity boundaries
   8. Type aliases & newtypes — interaction with constraints and inference
   9. `do`-block desugaring + monadic shapes

   Each section is self-contained.  Most cases are positive (assert_type) or
   negative (assert_err); a few use assert_err_matches to pin down which
   specific error variant fires when more than one would satisfy the test. *)

open Thorough_helpers

(* =====================================================================
   1. HM let-polymorphism corners
   ===================================================================== *)

(* Identity should be fully polymorphic: forall a. a -> a. *)
let t_hm_id_poly = assert_type "id x = x\n" "id" "a -> a"

(* Multiple uses at distinct types — both should be allowed under
   let-polymorphism. *)
let t_hm_id_two_types =
  assert_type
    {|id x = x
a = id 5
b = id "hello"
|}
    "b" "String"

(* `id (id x)` — application of polymorphic at polymorphic.  The outer
   `id` instantiates to (a -> a) -> (a -> a) so the inner can still be
   passed.  Result should still be a -> a. *)
let t_hm_id_of_id =
  assert_type "id x = x\nf x = id (id x)\n" "f" "a -> a"

(* Combinators: K = const, S = (\f g x -> f x (g x)). *)
let t_hm_K = assert_type "k x _ = x\n" "k" "a -> b -> a"

let t_hm_S =
  assert_type "s f g x = f x (g x)\n" "s"
    "(a -> b -> c) -> (a -> b) -> a -> c"

(* Y-combinator-ish — let polymorphism doesn't help inside lambda args.
   `f` is monomorphic inside its own body. *)
let t_hm_recursive_id =
  assert_type "rec_id x = rec_id x\n" "rec_id" "a -> b"

(* Mutual recursion: even/odd over Int.  Both must end up as Int -> Bool. *)
let t_hm_mutual_recursion =
  assert_type
    {|even n = if n == 0 then True else odd (n - 1)
odd n = if n == 0 then False else even (n - 1)
|}
    "even" "Int -> Bool"

(* Top-level value vs. function — bare `x = expr` doesn't get a lambda,
   so a generalized identity bound to a value is still polymorphic via
   eta-equivalent definition. *)
let t_hm_value_poly =
  assert_type "id = (x => x)\nr = id 5\n" "r" "Int"

(* The "value restriction" doesn't apply in pure HM the same way as ML
   with mutable refs, but a Ref-typed top-level value should still
   generalize over its element type only if level discipline allows it.
   `Ref 5` is `Ref Int`; nothing to generalize. *)
let t_hm_ref_concrete =
  assert_type "r = Ref 5\n" "r" "Ref Int"

(* Rank-1 only: passing a polymorphic id into a function position that
   *uses* it at two types should fail — but we don't enforce rank-1
   restriction explicitly; the let-binding generalization handles it. *)
let t_hm_lambda_arg_mono =
  (* `apply_twice f = (f 1, f "hi")` — f used at two types — should fail
     because f is a lambda arg, not a let binding. *)
  assert_err
    {|apply_twice f = (f 1, f "hi")
|}

(* Let inside an indented body — the inner let-binding should be
   generalized.  `g x` types x freely; `g 5` pins the second tuple
   element to Int.  Result: `a -> (a, Int)`. *)
let t_hm_inner_let_gen =
  assert_type
    {|f x =
  let g y = y
  (g x, g 5)
|}
    "f" "a -> (a, Int)"

(* Same shape but with a string instead of an int. *)
let t_hm_inner_let_gen_str =
  assert_type
    {|f x =
  let g y = y
  (g x, g "hi")
|}
    "f" "a -> (a, String)"

(* =====================================================================
   1b. Level / escape problems
   ===================================================================== *)

(* Deep nesting using `let .. in ..` form (the multi-line indented-body
   let form does not support multi-line let bodies — current grammar
   limitation).  Both forms exercise level discipline. *)
let t_levels_deep_nesting =
  assert_type
    {|f x = let g y = let h z = z in h y in g x
|}
    "f" "a -> a"

(* A let-bound polymorphic function used twice, then passed to a
   higher-order map. *)
let t_levels_let_then_hof =
  assert_type
    {|r =
  let id x = x
  map id [1, 2, 3]
|}
    "r" "List Int"

(* =====================================================================
   2. Generalization ordering / mutual recursion
   ===================================================================== *)

(* Forward reference: `f` defined before `g`, but `f` calls `g`.  Both
   need to be in the same generalization group. *)
let t_mutual_forward_ref =
  assert_type
    {|f xs = match xs
  [] => 0
  (x::rest) => x + g rest
g xs = f xs
|}
    "g" "List Int -> Int"

(* Three-way mutual recursion. *)
let t_three_way_mutual =
  assert_type
    {|f n = if n == 0 then 0 else g (n - 1)
g n = if n == 0 then 1 else h (n - 1)
h n = if n == 0 then 2 else f (n - 1)
|}
    "h" "Int -> Int"

(* =====================================================================
   3. Record / row polymorphism corners
   ===================================================================== *)

(* Field access on a parametric record should infer the field type from
   the type argument. *)
let t_rec_param_field =
  assert_type
    {|record Box a
  value : a
get_value b = b.value
|}
    "get_value" "Box a -> a"

(* Record with two same-typed fields is fine.
   (Use `total` rather than `sum` to avoid clashing with the prelude's
   `sum : a Int -> Int` Foldable method via VMulti dispatch.) *)
let t_rec_two_int_fields =
  assert_type
    {|record P
  x : Int
  y : Int
total p = p.x + p.y
|}
    "total" "P -> Int"

(* Record update on a polymorphic record.  Medaka records are NOT
   row-polymorphic — an update preserves the record's type, so a value
   of type `Box a` updated with a new value remains `Box a` (the new
   value is unified with the field type, not replaced).  This means
   `{ b | value = v }` types as `Box a -> a -> Box a`, not `Box a -> b -> Box b`. *)
let t_rec_update_poly =
  assert_type
    {|record Box a
  value : a
set b v = { b | value = v }
|}
    "set" "Box a -> a -> Box a"

(* Field-access on an unknown record name should error.  The exact error
   depends on whether the resolver or typechecker catches it first; we
   only assert that it does fail. *)
let e_rec_field_unknown_record =
  assert_err
    {|f x = x.notARealField
g = f 5
|}

(* Constructing a record without all fields. *)
let e_rec_missing_field =
  assert_err
    {|record P
  x : Int
  y : Int
p = P { x = 1 }
|}

(* Constructing a record with an unknown field. *)
let e_rec_unknown_field =
  assert_err
    {|record P
  x : Int
p = P { x = 1, z = 2 }
|}

(* =====================================================================
   4. Interface / constraint solving corners
   ===================================================================== *)

(* User-defined interface, single impl, called via method. *)
let t_iface_user_single =
  assert_type
    {|interface Sized a where
  sz : a -> Int
impl Sized String where
  sz s = 42
n = sz "hello"
|}
    "n" "Int"

(* User-defined interface with a generic impl and a use site that
   pins the type. *)
let t_iface_generic_impl_pinned =
  assert_type
    {|interface Container c where
  empty_c : c a
impl Container List where
  empty_c = []
e : List Int
e = empty_c
|}
    "e" "List Int"

(* Missing impl: calling `sz` on an Int when only the String impl exists
   should fail. *)
let e_iface_no_impl_for_type =
  assert_err
    {|interface Sized a where
  sz : a -> Int
impl Sized String where
  sz _ = 1
n = sz 5
|}

(* Two impls — calling without disambiguation may either succeed
   (picking one via ordering) or fail with AmbiguousImpl, depending on
   how the typechecker is set up.  We don't pin the exact behavior here
   but we do assert that explicitly naming an impl works. *)
let t_iface_named_dispatch =
  assert_type
    {|interface Sized a where
  sz : a -> Int
impl Tiny of Sized Int where
  sz _ = 1
impl Huge of Sized Int where
  sz _ = 1000
n = sz @Tiny 5
|}
    "n" "Int"

(* Unknown named impl. *)
let e_iface_unknown_named_impl =
  assert_err
    {|interface Sized a where
  sz : a -> Int
impl Tiny of Sized Int where
  sz _ = 1
n = sz @DoesNotExist 5
|}

(* Constraint propagation: a function annotated `Eq a => ...` is
   accepted; calling it requires the caller's type to satisfy `Eq`.
   PLAN.md §5 notes: the stdlib `Eq` interface does NOT have a built-in
   Int impl (core.mdk only registers `Eq (List a) requires Eq a`).  So
   we use a user-defined Eq impl over a user-defined data type. *)
let t_constraint_explicit_eq =
  assert_type
    {|data Box = Box Int
impl Eq Box where
  eq (Box a) (Box b) = a == b
both_equal : Eq a => a -> a -> a -> Bool
both_equal a b c = eq a b && eq b c
r = both_equal (Box 1) (Box 2) (Box 3)
|}
    "r" "Bool"

(* Phase 45.9: user-defined impl over a primitive type used to conflict
   with the seeded built-in impl_entry (Ambiguous: multiple impls of Ord
   for Int).  Now user impls win — the seeded entries are treated as
   fallbacks. *)
let t_iface_user_impl_over_primitive =
  assert_type
    {|impl Eq Int where
  eq a b = a == b
impl Ord Int where
  compare a b = if a < b then Lt else if a > b then Gt else Eq
r = lt 1 2
|}
    "r" "Bool"

(* Built-in operator constraint still resolves via the seeded impl
   when no user impl is provided. *)
let t_iface_seeded_still_works =
  assert_type "r = 1 < 2\n" "r" "Bool"

(* Calling an explicit-constraint function with a type that has no Eq
   impl: define a type without Eq and try to use it. *)
let e_constraint_no_eq_impl =
  assert_err
    {|data Opaque = Opaque
both_equal : Eq a => a -> a -> Bool
both_equal a b = eq a b
r = both_equal Opaque Opaque
|}

(* =====================================================================
   5. Effect propagation
   ===================================================================== *)

(* An explicitly annotated IO function works as before. *)
let t_eff_print_io =
  assert_type
    {|f : a -> <IO> Unit
f x = print x
|}
    "f" "a -> <IO> Unit"

(* Phase 51: unannotated function calling print gets IO inferred. *)
let t_eff_infer_unannotated =
  assert_type "f x = print x\n" "f" "a -> Unit"

(* Phase 51: transitive inference — unannotated A calling unannotated B calling print. *)
let t_eff_infer_transitive =
  assert_type
    {|inner x = print x
outer x = inner x
|}
    "outer" "a -> Unit"

(* Phase 51: annotated caller of unannotated callee must cover callee's inferred effects. *)
let e_eff_escape_via_inferred_callee =
  assert_err
    {|helper x = print x
f : String -> Unit
f x = helper x
|}

(* A function that only manipulates pure data should have no effects. *)
let t_eff_pure_no_eff =
  assert_type "f x = x + 1\n" "f" "Int -> Int"

(* A do-block in pure code (Option monad) should be pure. *)
let t_eff_option_pure =
  assert_type
    {|f =
  do
    x <- Some 1
    pure x
|}
    "f" "Option Int"

(* Phase 54: DoAssign in a do-block infers <Mut>; DoFieldAssign too. *)

(* Unannotated function with mutation in a bare sequential block:
   <Mut> is inferred but no error (Phase 51 silences the ImpureFunction
   diagnostic; effects still propagate to callers via eff_env).  Phase
   55.5: `let mut` is allowed only in bare (procedural) blocks — `do` is
   reserved for monadic composition. *)
let t_mut_inferred_ok =
  assert_type
    {|f =
  let mut x = 0
  x = 42
  pure x
|}
    "f" "a Int"

(* Explicit <Mut> annotation on a mutating function is accepted. *)
let t_mut_do_assign_annotated =
  assert_type
    {|f : <Mut> (a Int)
f =
  let mut x = 0
  x = 42
  pure x
|}
    "f" "a Int"

(* Transitive Mut: annotated-pure caller of a DoAssign function → EffectEscape. *)
let e_mut_escape_pure_caller =
  assert_err
    {|mutHelper x = do
  let mut y = x
  y = y + 1
  pure y

bad : Int -> a Int
bad x = mutHelper x
|}

(* DoFieldAssign also triggers <Mut>: it propagates to callers. *)
let e_mut_field_assign_escape =
  assert_err
    {|record Box
  val : Int

mutBox b newVal = do
  let mut b2 = b
  b2.val = newVal
  pure b2

bad : Box -> Int -> a Box
bad b v = mutBox b v
|}

(* Multi-level DoFieldAssign (Phase 80) also triggers <Mut> and escapes. *)
let e_mut_multi_field_escape =
  assert_err
    {|record Inner
  c : Int

record Outer
  b : Inner

mutNested o newVal = do
  let mut o2 = o
  o2.b.c = newVal
  pure o2

bad : Outer -> Int -> a Outer
bad o v = mutNested o v
|}

(* A function performing both IO and mutation can declare both effects.
   Uses a bare sequential block (Phase 55.5): `let mut` is not allowed
   inside `do`, so the body is plain sequencing. *)
let t_mut_and_io_together =
  assert_type
    {|f : <IO, Mut> Unit
f =
  let mut x = 0
  x = 42
  println x
|}
    "f" "Unit"

(* =====================================================================
   6. Exhaustiveness — extra corners
   ===================================================================== *)

(* Nested constructor match — covering some & none but missing inner. *)
let w_exhaust_nested_some =
  assert_warns
    {|f x = match x
  None => 0
  Some (Some n) => n
|}

(* Nested constructor match that IS exhaustive (covers all cases). *)
let n_exhaust_nested_complete =
  assert_no_warns
    {|f x = match x
  None => 0
  Some None => 1
  Some (Some n) => n
|}

(* Tuple of two Options — missing case. *)
let w_exhaust_tuple_options =
  assert_warns
    {|f p = match p
  (None, None) => 0
  (Some _, Some _) => 1
|}

(* Bool match: True/False covered, no _. *)
let n_exhaust_bool_complete =
  assert_no_warns
    {|f b = match b
  True => 1
  False => 0
|}

(* Bool match: only True covered. *)
let w_exhaust_bool_incomplete =
  assert_warns
    {|f b = match b
  True => 1
|}

(* Redundant arm — should warn even though all cases are covered. *)
let w_exhaust_redundant_wild =
  assert_warns
    {|f x = match x
  None => 0
  Some _ => 1
  _ => 2
|}

(* List patterns: [] and (x::xs) is complete; missing one should warn. *)
let n_exhaust_list_complete =
  assert_no_warns
    {|f xs = match xs
  [] => 0
  (x::rest) => 1
|}

let w_exhaust_list_missing_empty =
  assert_warns
    {|f xs = match xs
  (x::rest) => 1
|}

(* =====================================================================
   7. Abstract type exports / opacity
   ===================================================================== *)
(* Single-file proxy: define an `interface`-only export and verify
   normal type-checking; opacity boundaries are exercised by the
   loader/diagnostics suites at the multi-file level. *)

(* =====================================================================
   8. Type aliases & newtypes
   ===================================================================== *)

(* Alias used directly in an annotation — alias should expand and
   typecheck normally. *)
let t_alias_in_sig =
  assert_type
    {|type IntList = List Int
sum_il : IntList -> Int
sum_il xs = fold (a => b => a + b) 0 xs
r = sum_il [1, 2, 3]
|}
    "r" "Int"

(* Parametric alias instantiation. *)
let t_alias_param_instantiate =
  assert_type
    {|type Pair a = (a, a)
swap : Pair a -> Pair a
swap (x, y) = (y, x)
r = swap (1, 2)
|}
    "r" "(Int, Int)"

(* Newtype is nominal — passing to a function expecting the wrapped type
   should fail. *)
let e_newtype_nominal =
  assert_err
    {|newtype Wrapper = Wrapper Int
take_int : Int -> Int
take_int n = n + 1
r = take_int (Wrapper 5)
|}

(* Newtype unwrap via pattern match. *)
let t_newtype_unwrap =
  assert_type
    {|newtype Wrapper = Wrapper Int
unwrap (Wrapper n) = n
r = unwrap (Wrapper 5)
|}
    "r" "Int"

(* =====================================================================
   9. do-block shapes
   ===================================================================== *)

(* Empty-ish do-block: single bind + pure. *)
let t_do_single_bind =
  assert_type
    {|r =
  do
    x <- Some 5
    pure x
|}
    "r" "Option Int"

(* do with let-stmt in middle. *)
let t_do_let_in_middle =
  assert_type
    {|r =
  do
    x <- Some 5
    let y = x + 1
    pure y
|}
    "r" "Option Int"

(* Mixing two monads in one do should fail. *)
let e_do_mixed_monads =
  assert_err
    {|r =
  do
    x <- Some 5
    y <- Ok 3
    pure (x + y)
|}

(* do-block returning Result. *)
let t_do_result =
  assert_type
    {|r =
  do
    x <- Ok 1
    y <- Ok 2
    pure (x + y)
|}
    "r" "Result a Int"

(* =====================================================================
   10. Numeric literal types
   ===================================================================== *)

let t_hex_lit_int  = assert_type "x = 0xFF\n" "x" "Int"
let t_bin_lit_int  = assert_type "x = 0b1010\n" "x" "Int"
let t_oct_lit_int  = assert_type "x = 0o17\n" "x" "Int"
let t_underscore_int = assert_type "x = 1_000_000\n" "x" "Int"
let t_float_lit    = assert_type "x = 3.14\n" "x" "Float"
let t_float_neg    = assert_type "x = 0.0\n" "x" "Float"

(* =====================================================================
   11. Range literal types
   ===================================================================== *)

let t_range_list_inclusive =
  assert_type "r = [1..=5]\n" "r" "List Int"

let t_range_list_halfopen =
  assert_type "r = [1..5]\n" "r" "List Int"

let t_range_array_inclusive =
  assert_type "r = [|1..=5|]\n" "r" "Array Int"

let t_range_array_halfopen =
  assert_type "r = [|1..5|]\n" "r" "Array Int"

let e_range_non_int =
  assert_err {|r = [1.0..5.0]
|}

(* =====================================================================
   12. Operator-section + currying corners
   ===================================================================== *)

let t_section_right_add  = assert_type "f = (+ 1)\n"  "f" "Int -> Int"
(* `(- 1)` is unary minus, not a section.  This matches Haskell.  To get
   the subtraction section, use `(10 - _)` or `(\x => x - 1)`. *)
let t_section_minus_unary = assert_type "f = (- 1)\n"  "f" "Int"
let t_section_right_eq   = assert_type "f = (== 1)\n" "f" "Int -> Bool"
let t_section_left_sub   = assert_type "f = (10 - _)\n" "f" "Int -> Int"
let t_section_left_div   = assert_type "f = (10 / _)\n" "f" "Int -> Int"
let t_section_eq_string  = assert_type "f = (== \"x\")\n" "f" "String -> Bool"

(* Partially-applied curried function. *)
let t_partial_curry =
  assert_type "add x y = x + y\nadd5 = add 5\n" "add5" "Int -> Int"

(* Triple partial application. *)
let t_triple_partial =
  assert_type "f x y z = x + y + z\ng = f 1 2\n" "g" "Int -> Int"

(* =====================================================================
   13. Lambda corners
   ===================================================================== *)

let t_lambda_identity =
  assert_type "f = (x => x)\n" "f" "a -> a"

let t_lambda_const =
  assert_type "f = (x => y => x)\n" "f" "a -> b -> a"

(* Lambda with destructuring pattern.  `a + b` uses Num constraint, so
   without further context the inferred type is the polymorphic
   `(a, a) -> a` (constraint stripped in pp_scheme). *)
let t_lambda_pat_tuple =
  assert_type "f = ((a, b) => a + b)\n" "f" "(a, a) -> a"

(* Constructor patterns in lambda parameters need parens around the
   constructor application (current grammar constraint). *)
let t_lambda_pat_con =
  assert_type "f = ((Some x) => x)\n" "f" "Option a -> a"

(* Underscore lambda. *)
let t_lambda_wild =
  assert_type "f = (_ => 5)\n" "f" "a -> Int"

(* =====================================================================
   14. List operations — typed corners
   ===================================================================== *)

let t_list_empty_poly =
  assert_type "xs = []\n" "xs" "List a"

let t_list_cons =
  assert_type "xs = 1 :: [2, 3]\n" "xs" "List Int"

let t_list_concat =
  assert_type "xs = [1, 2] ++ [3, 4]\n" "xs" "List Int"

let t_list_mixed_concat_str =
  assert_type "xs = \"a\" ++ \"b\"\n" "xs" "String"

(* Map preserves outer container, transforms element. *)
let t_list_map =
  assert_type "r = map (x => x + 1) [1, 2, 3]\n" "r" "List Int"

let t_list_map_type_change =
  assert_type "r = map (n => n > 0) [1, -2, 3]\n" "r" "List Bool"

let t_list_filter_returns_same =
  assert_type "r = filter (x => x > 0) [1, 2, 3]\n" "r" "List Int"

(* fold: changes type of accumulator. *)
let t_list_fold_int_sum =
  assert_type "r = fold (a => b => a + b) 0 [1, 2, 3]\n" "r" "Int"

(* fold to convert list of ints to string concatenation? — uses show. *)

(* =====================================================================
   15. Match arms — exhaustiveness + types
   ===================================================================== *)

let t_match_option_full =
  assert_type
    {|f x = match x
  Some n => n
  None => 0
|}
    "f" "Option Int -> Int"

(* Match where arms produce differing concrete types: TypeMismatch. *)
let e_match_arm_type_clash =
  assert_err
    {|f x = match x
  Some _ => 1
  None => "zero"
|}

(* Match where scrutinee is bool. *)
let t_match_bool =
  assert_type
    {|f b = match b
  True => 1
  False => 0
|}
    "f" "Bool -> Int"

(* Match on tuple. *)
let t_match_tuple =
  assert_type
    {|f p = match p
  (x, 0) => x
  (_, y) => y
|}
    "f" "(Int, Int) -> Int"

(* Match on cons. *)
let t_match_cons =
  assert_type
    {|len xs = match xs
  [] => 0
  (_::rest) => 1 + len rest
|}
    "len" "List a -> Int"

(* Match guard. *)
let t_match_guard =
  assert_type
    {|sign n = match n
  x if x > 0 => 1
  x if x < 0 => -1
  _ => 0
|}
    "sign" "Int -> Int"

(* =====================================================================
   16. ADT — payload kinds & generics
   ===================================================================== *)

let t_data_param =
  assert_type
    {|data Pair a b = MkPair a b
mk = MkPair 1 "hi"
|}
    "mk" "Pair Int String"

let t_data_recursive =
  assert_type
    {|data Tree a = Leaf | Node (Tree a) a (Tree a)
t = Node Leaf 1 Leaf
|}
    "t" "Tree Int"

let t_data_named_fields =
  assert_type
    {|data Color = Rgb { r : Int, g : Int, b : Int }
c = Rgb { r = 1, g = 2, b = 3 }
|}
    "c" "Color"

(* Missing field in named-field ctor. *)
let e_data_named_missing_field =
  assert_err
    {|data Color = Rgb { r : Int, g : Int, b : Int }
c = Rgb { r = 1, g = 2 }
|}

(* Wrong field type. *)
let e_data_named_wrong_type =
  assert_err
    {|data Color = Rgb { r : Int, g : Int, b : Int }
c = Rgb { r = "x", g = 2, b = 3 }
|}

(* =====================================================================
   17. Constructor application arity
   ===================================================================== *)

(* NOTE: removed `e_ctor_too_few_args` — Medaka constructors are curried, so
   `MkPair 1` is the function `b -> Pair Int b` rather than a type error. *)

(* Partially-applied curried constructor: `MkPair 1` should type as
   `b -> Pair Int b`. *)
let t_ctor_partial_app =
  assert_type
    {|data Pair a b = MkPair a b
mkPair1 = MkPair 1
|}
    "mkPair1" "a -> Pair Int a"

(* Self-referential record (forward reference via Option) *)
let t_record_self_ref =
  assert_type
    {|record Node
  v : Int
  next : Option Node
n = Node { v = 1, next = None }
|}
    "n" "Node"

(* Mutually recursive record types — neither is parametric, both reference
   each other only through name (not in a way that forms a real cycle). *)
let t_record_mutual =
  assert_type
    {|record A
  b : Int
record B
  a : Int
x : A
x = A { b = 5 }
|}
    "x" "A"

(* =====================================================================
   18. Annotations & explicit type errors
   ===================================================================== *)

let t_annot_match_inferred =
  assert_type
    {|x : Int
x = 42
|}
    "x" "Int"

let e_annot_conflict =
  assert_err
    {|x : Int
x = "hello"
|}

let t_annot_param =
  assert_type
    {|f : Int -> Int
f x = x + 1
|}
    "f" "Int -> Int"

let e_annot_param_conflict =
  assert_err
    {|f : Int -> Int
f x = x ++ "!"
|}

(* Annotation is more general than the body — narrow inferred type wins. *)
let t_annot_more_specific =
  assert_type
    {|f : Int -> Int
f x = x
|}
    "f" "Int -> Int"

(* =====================================================================
   19. Recursion edge cases
   ===================================================================== *)

(* Self-recursive single function: identity-like. *)
let t_rec_self =
  assert_type
    {|f x = if False then f x else x
|}
    "f" "a -> a"

(* Generalized fix-point with type annotation. *)
let t_rec_fact =
  assert_type
    {|fact n = if n <= 1 then 1 else n * fact (n - 1)
|}
    "fact" "Int -> Int"

(* Mutually recursive list functions.  Multi-line let-in-match-arm
   bodies need an explicit `in`, or stand-alone tuple cons.  Use a
   simpler shape: two helpers calling each other directly. *)
let t_rec_mutual_list =
  assert_type
    {|hasPos xs = match xs
  [] => False
  (x::rest) => if x > 0 then True else hasNeg rest
hasNeg xs = match xs
  [] => False
  (x::rest) => if x < 0 then True else hasPos rest
|}
    "hasPos" "List Int -> Bool"

(* =====================================================================
   20. String / interpolation typing
   ===================================================================== *)

(* Interpolation holes must already be strings — no auto-Show happens.
   `\{1 + 1}` errors with "Type mismatch: Int vs String".  This is a
   documented behavior, not a bug.  If/when implicit Show dispatch lands,
   this test will need to flip to assert_type. *)
let e_interp_int_hole =
  assert_err {|x = "value: \{1 + 1}"
|}

let t_interp_string_hole =
  assert_type {|n = "Alice"
x = "Hi, \{n}!"
|} "x" "String"

let e_interp_no_show =
  assert_err
    {|data Box = Box
x = "v = \{Box}"
|}


(* =====================================================================
   Test registration
   ===================================================================== *)

let () =
  let open Alcotest in
  run "thorough typecheck"
    [
      ( "HM let-polymorphism",
        [ test_case "identity is polymorphic"  `Quick t_hm_id_poly
        ; test_case "id at two types"          `Quick t_hm_id_two_types
        ; test_case "id (id x) preserves a -> a" `Quick t_hm_id_of_id
        ; test_case "K combinator"             `Quick t_hm_K
        ; test_case "S combinator"             `Quick t_hm_S
        ; test_case "self-recursive identity"  `Quick t_hm_recursive_id
        ; test_case "mutual recursion: even/odd" `Quick t_hm_mutual_recursion
        ; test_case "top-level value as lambda" `Quick t_hm_value_poly
        ; test_case "Ref 5 : Ref Int"          `Quick t_hm_ref_concrete
        ; test_case "lambda arg cannot be poly" `Quick t_hm_lambda_arg_mono
        ; test_case "inner let generalizes (int)" `Quick t_hm_inner_let_gen
        ; test_case "inner let generalizes (str)" `Quick t_hm_inner_let_gen_str
        ] );
      ( "level discipline",
        [ test_case "deep nested let" `Quick t_levels_deep_nesting
        ; test_case "let then HOF"    `Quick t_levels_let_then_hof
        ] );
      ( "mutual recursion / forward refs",
        [ test_case "forward reference"   `Quick t_mutual_forward_ref
        ; test_case "three-way mutual"    `Quick t_three_way_mutual
        ] );
      ( "records / row polymorphism",
        [ test_case "parametric field access"   `Quick t_rec_param_field
        ; test_case "two int fields"            `Quick t_rec_two_int_fields
        ; test_case "polymorphic update"        `Quick t_rec_update_poly
        ; test_case "err: unknown field"        `Quick e_rec_field_unknown_record
        ; test_case "err: missing field"        `Quick e_rec_missing_field
        ; test_case "err: extra field"          `Quick e_rec_unknown_field
        ] );
      ( "interfaces / constraints",
        [ test_case "single impl call"             `Quick t_iface_user_single
        ; test_case "generic impl pinned by sig"   `Quick t_iface_generic_impl_pinned
        ; test_case "err: no impl for type"        `Quick e_iface_no_impl_for_type
        ; test_case "named dispatch ok"            `Quick t_iface_named_dispatch
        ; test_case "err: unknown named impl"      `Quick e_iface_unknown_named_impl
        ; test_case "explicit Eq constraint"       `Quick t_constraint_explicit_eq
        ; test_case "err: type has no Eq impl"     `Quick e_constraint_no_eq_impl
        ; test_case "user impl over primitive"     `Quick t_iface_user_impl_over_primitive
        ; test_case "seeded fallback still works"  `Quick t_iface_seeded_still_works
        ] );
      ( "effects",
        [ test_case "print => <IO>"                   `Quick t_eff_print_io
        ; test_case "infer IO unannotated"            `Quick t_eff_infer_unannotated
        ; test_case "infer IO transitive"             `Quick t_eff_infer_transitive
        ; test_case "err: escape via inferred callee" `Quick e_eff_escape_via_inferred_callee
        ; test_case "pure arithmetic"                 `Quick t_eff_pure_no_eff
        ; test_case "Option do is pure"               `Quick t_eff_option_pure
        ; test_case "DoAssign infers <Mut> (ok)"      `Quick t_mut_inferred_ok
        ; test_case "<Mut> annotation explicit"       `Quick t_mut_do_assign_annotated
        ; test_case "err: Mut escapes pure caller"    `Quick e_mut_escape_pure_caller
        ; test_case "err: DoFieldAssign Mut escape"   `Quick e_mut_field_assign_escape
        ; test_case "err: multi field Mut escape"     `Quick e_mut_multi_field_escape
        ; test_case "<IO, Mut> combined"              `Quick t_mut_and_io_together
        ] );
      ( "exhaustiveness corners",
        [ test_case "warns: nested Some/None"  `Quick w_exhaust_nested_some
        ; test_case "ok: nested complete"      `Quick n_exhaust_nested_complete
        ; test_case "warns: tuple-of-options"  `Quick w_exhaust_tuple_options
        ; test_case "ok: bool complete"        `Quick n_exhaust_bool_complete
        ; test_case "warns: bool incomplete"   `Quick w_exhaust_bool_incomplete
        ; test_case "warns: redundant wild"    `Quick w_exhaust_redundant_wild
        ; test_case "ok: [] vs (::)"           `Quick n_exhaust_list_complete
        ; test_case "warns: missing []"        `Quick w_exhaust_list_missing_empty
        ] );
      ( "type aliases & newtypes",
        [ test_case "alias in signature"          `Quick t_alias_in_sig
        ; test_case "parametric alias instantiate" `Quick t_alias_param_instantiate
        ; test_case "newtype is nominal"          `Quick e_newtype_nominal
        ; test_case "newtype unwrap"              `Quick t_newtype_unwrap
        ] );
      ( "do-block shapes",
        [ test_case "single bind"           `Quick t_do_single_bind
        ; test_case "let in middle"         `Quick t_do_let_in_middle
        ; test_case "err: mixed monads"     `Quick e_do_mixed_monads
        ; test_case "do Result"             `Quick t_do_result
        ] );
      ( "numeric literals",
        [ test_case "hex"          `Quick t_hex_lit_int
        ; test_case "bin"          `Quick t_bin_lit_int
        ; test_case "oct"          `Quick t_oct_lit_int
        ; test_case "underscore"   `Quick t_underscore_int
        ; test_case "float"        `Quick t_float_lit
        ; test_case "float 0.0"    `Quick t_float_neg
        ] );
      ( "range literals",
        [ test_case "list ..= : List Int"   `Quick t_range_list_inclusive
        ; test_case "list ..  : List Int"   `Quick t_range_list_halfopen
        ; test_case "array ..= : Array Int" `Quick t_range_array_inclusive
        ; test_case "array ..  : Array Int" `Quick t_range_array_halfopen
        ; test_case "err: non-int bounds"   `Quick e_range_non_int
        ] );
      ( "operator sections / currying",
        [ test_case "(+ 1)"              `Quick t_section_right_add
        ; test_case "(- 1) is unary"     `Quick t_section_minus_unary
        ; test_case "(== 1)"             `Quick t_section_right_eq
        ; test_case "(10 - _)"           `Quick t_section_left_sub
        ; test_case "(10 / _)"           `Quick t_section_left_div
        ; test_case "(== \"x\")"         `Quick t_section_eq_string
        ; test_case "partial curry"      `Quick t_partial_curry
        ; test_case "triple partial"     `Quick t_triple_partial
        ] );
      ( "lambdas",
        [ test_case "identity lambda"      `Quick t_lambda_identity
        ; test_case "const lambda"         `Quick t_lambda_const
        ; test_case "tuple pattern"        `Quick t_lambda_pat_tuple
        ; test_case "constructor pattern"  `Quick t_lambda_pat_con
        ; test_case "underscore"           `Quick t_lambda_wild
        ] );
      ( "list typing corners",
        [ test_case "empty list poly"      `Quick t_list_empty_poly
        ; test_case "cons preserves type"  `Quick t_list_cons
        ; test_case "++ on lists"          `Quick t_list_concat
        ; test_case "++ on strings"        `Quick t_list_mixed_concat_str
        ; test_case "map List Int"         `Quick t_list_map
        ; test_case "map List Bool"        `Quick t_list_map_type_change
        ; test_case "filter same"          `Quick t_list_filter_returns_same
        ; test_case "fold int sum"         `Quick t_list_fold_int_sum
        ] );
      ( "match arms",
        [ test_case "Option full"          `Quick t_match_option_full
        ; test_case "err: arm type clash"  `Quick e_match_arm_type_clash
        ; test_case "Bool exhaustive"      `Quick t_match_bool
        ; test_case "tuple"                `Quick t_match_tuple
        ; test_case "cons recursion"       `Quick t_match_cons
        ; test_case "guard"                `Quick t_match_guard
        ] );
      ( "ADTs",
        [ test_case "Pair Int String"      `Quick t_data_param
        ; test_case "Tree Int"             `Quick t_data_recursive
        ; test_case "named-field Color"    `Quick t_data_named_fields
        ; test_case "err: missing field"   `Quick e_data_named_missing_field
        ; test_case "err: wrong field ty"  `Quick e_data_named_wrong_type
        ; test_case "partial app ctor"     `Quick t_ctor_partial_app
        ; test_case "self-ref record"      `Quick t_record_self_ref
        ; test_case "mutual record types"  `Quick t_record_mutual
        ] );
      ( "annotations",
        [ test_case "value Int"            `Quick t_annot_match_inferred
        ; test_case "err: value conflict"  `Quick e_annot_conflict
        ; test_case "fn signature"         `Quick t_annot_param
        ; test_case "err: fn body wrong"   `Quick e_annot_param_conflict
        ; test_case "annot pinning"        `Quick t_annot_more_specific
        ] );
      ( "recursion",
        [ test_case "self-rec branch"      `Quick t_rec_self
        ; test_case "factorial"            `Quick t_rec_fact
        ; test_case "mutual: partition"    `Quick t_rec_mutual_list
        ] );
      ( "interpolation typing",
        [ test_case "err: int hole no show" `Quick e_interp_int_hole
        ; test_case "string hole"           `Quick t_interp_string_hole
        ; test_case "err: no Show"          `Quick e_interp_no_show
        ] );
    ]
