(* Thorough tests for language features added in recent phases.
   Kept separate from the topic-organized [thorough_eval / thorough_typecheck
   / thorough_interactions] files so the "what broke around phase X" view
   stays clear when something regresses.

   Phases covered:
     - 56:   Multi-level nested record updates
     - 57:   let rec for value and mutually-recursive bindings
     - 58:   List-comprehension refutable-pattern filtering
     - 59:   Bare operator sections (op)
     - 59.5: Top-level binding order doesn't matter
     - 59.6: Multi-variable lambdas (x y => body)
     - VMulti dispatch on non-determining args
     - Module 4 / resolver gap closures *)

open Medaka_lib.Eval
open Thorough_helpers

(* =====================================================================
   Phase 59.6 — Multi-variable lambdas
   ===================================================================== *)

let t_multi_arg_lam_basic =
  assert_typed_val
    {|add = x y => x + y
r = add 3 4
|}
    "r" "Int" (VInt 7)

let t_multi_arg_lam_three =
  assert_typed_val
    {|sum3 = x y z => x + y + z
r = sum3 1 2 3
|}
    "r" "Int" (VInt 6)

let t_multi_arg_lam_partial_application =
  assert_val
    {|f = x y => x + y
addTen = f 10
r = addTen 5
|}
    "r" (VInt 15)

(* The lambda body is just a normal expression — pipelines and HOFs
   should compose naturally. *)
let t_multi_arg_lam_in_hof =
  assert_val
    {|r = foldRight (x acc => x + acc) 0 [1, 2, 3, 4, 5]
|}
    "r" (VInt 15)

(* =====================================================================
   Phase 59 — Operator sections `(op)`
   ===================================================================== *)

let t_op_section_plus =
  assert_val
    {|f = (+)
r = f 3 4
|}
    "r" (VInt 7)

let t_op_section_times =
  assert_val
    {|r = foldRight (*) 1 [2, 3, 4]
|}
    "r" (VInt 24)

let t_op_section_cons =
  assert_val
    {|prepend = (::)
r = prepend 1 [2, 3]
|}
    "r" (VList [VInt 1; VInt 2; VInt 3])

(* Unary minus is preserved: (-5) stays as a negative-int literal, while
   the bare section (- ) means subtraction. *)
let t_op_section_minus_unary_safe =
  assert_val
    {|sub = (-)
r = sub 10 (-3)
|}
    "r" (VInt 13)

(* =====================================================================
   Phase 57 — `let rec` and mutual recursion (top-level)
   ===================================================================== *)

(* Zero-arg `let rec` requires a lambda RHS — Medaka's strict evaluator
   rejects cyclic data (e.g. `let rec ones = 1 :: ones`).  A
   recursive-function value is fine because the lambda defers
   evaluation. *)
let t_let_rec_lambda_value_self =
  assert_val
    {|let rec countdown = n => if n == 0 then 0 else n + countdown (n - 1)
r = countdown 5
|}
    "r" (VInt 15)

let t_let_rec_mutual_top_level =
  assert_val
    {|let rec isEven n = if n == 0 then True else isOdd (n - 1)
with    isOdd  n = if n == 0 then False else isEven (n - 1)
r = isEven 6
|}
    "r" (VBool true)

(* =====================================================================
   Phase 59.5 — Top-level binding order doesn't matter
   ===================================================================== *)

let t_forward_reference_top_level =
  assert_val
    {|r = double 21
double x = x + x
|}
    "r" (VInt 42)

let t_mutual_top_level_no_rec =
  assert_val
    {|isEvenN n = if n == 0 then True else isOddN (n - 1)
isOddN  n = if n == 0 then False else isEvenN (n - 1)
r = (isEvenN 4, isOddN 3)
|}
    "r" (VTuple [VBool true; VBool true])

(* =====================================================================
   Phase 58 — List-comp refutable patterns silently filter
   ===================================================================== *)

let t_list_comp_filter_just =
  assert_val
    {|data Maybe a = Just a | Nothing
keepJust xs = [x | Just x <- xs]
r = keepJust [Just 1, Nothing, Just 2, Nothing, Just 3]
|}
    "r" (VList [VInt 1; VInt 2; VInt 3])

let t_list_comp_filter_with_guard =
  assert_val
    {|data Maybe a = Just a | Nothing
keepPos xs = [x | Just x <- xs, x > 0]
r = keepPos [Just (-1), Just 2, Nothing, Just (-3), Just 4]
|}
    "r" (VList [VInt 2; VInt 4])

(* =====================================================================
   Phase 56 — Multi-level nested record updates
   ===================================================================== *)

let t_nested_record_update_two_levels =
  assert_val
    {|record Inner
  v : Int
record Outer
  i : Inner
o = Outer { i = Inner { v = 1 } }
o2 = { o | i.v = 42 }
r = o2.i.v
|}
    "r" (VInt 42)

let t_nested_record_update_three_levels =
  assert_val
    {|record A
  n : Int
record B
  a : A
record C
  b : B
c = C { b = B { a = A { n = 0 } } }
c2 = { c | b.a.n = 99 }
r = c2.b.a.n
|}
    "r" (VInt 99)

(* The original record is unchanged after an update (records are
   value semantics): the original o.i.v stays at 1, while the
   updated copy holds 99. *)
let t_nested_record_update_immutable =
  assert_val
    {|record Inner
  v : Int
record Outer
  i : Inner
o = Outer { i = Inner { v = 1 } }
o2 = { o | i.v = 99 }
r = (o.i.v, o2.i.v)
|}
    "r" (VTuple [VInt 1; VInt 99])

(* =====================================================================
   VMulti — dispatch by non-determining argument shouldn't poison
   ===================================================================== *)

(* The fix in a6a41b3: applying a Foldable method (`fold`) with a value
   whose runtime tag matches a registered Foldable impl as the
   ACCUMULATOR shouldn't pre-commit dispatch to that impl.  Only the
   argument whose declared type mentions the interface parameter (the
   container, here) should drive dispatch.  `fold (+) (None) [1, 2, 3]`
   used to misdispatch to Foldable Option because `None`'s tag is
   "Option". *)
let t_vmulti_non_determining_accumulator =
  assert_val
    {|data Box a = Box a
unbox (Box x) = x
r = fold (acc x => acc + x) 0 [1, 2, 3, 4]
|}
    "r" (VInt 10)

(* Sister test using the prelude-seeded Foldable Option directly:
   `fold (+) None [1, 2, 3]` used to misdispatch to Foldable Option
   because the accumulator's runtime tag was "Option".  After the
   non-determining-arg fix the list scrutinee drives dispatch and the
   accumulator just rides along — the call should fail at the type
   level (since `0 :: None` can't unify), not silently run the wrong
   impl.  We check it indirectly by passing a Some-tagged accumulator
   that the type checker WILL accept (Option Int), and confirm the
   list impl runs to completion. *)
let t_vmulti_option_acc_through_list_fold =
  assert_val
    {|r = fold (acc x => Some (fromOption 0 acc + x)) (Some 0) [1, 2, 3]
|}
    "r" (VCon ("Some", [VInt 6]))

(* =====================================================================
   Module 4 — resolver / typecheck gap closures (regressions)
   ===================================================================== *)

(* Resolver gap 1: interface method names (max, min, ...) now resolve
   from user files because prelude_values pulls them in from
   DInterface, not just from existing impls. *)
let t_resolve_interface_method_names_work =
  assert_typed_val
    {|r = (max 3 4, min 3 4)
|}
    "r" "(Int, Int)" (VTuple [VInt 4; VInt 3])

(* Typecheck gap 3: TyConstrained needs unwrapping when reading
   declared effects.  `Ord a => a -> a -> <Mut> Unit` should be read
   as performing <Mut> (not as a pure function), so no diagnostic
   about "performs <Mut> but declared with <>" fires.  The rendered
   scheme drops the printed constraint (no use site pins `a`) but
   what we really care about is that the program type-checks. *)
let t_constrained_with_effect =
  assert_type
    {|swapIfGreater : Ord a => a -> a -> <Mut> Unit
swapIfGreater x y = ()
|}
    "swapIfGreater" "a -> a -> <Mut> Unit"

(* =====================================================================
   Entry
   ===================================================================== *)

let () =
  let open Alcotest in
  run "thorough recent"
    [ "multi-arg lambdas (Phase 59.6)",
      [ test_case "two-arg add"           `Quick t_multi_arg_lam_basic
      ; test_case "three-arg sum"         `Quick t_multi_arg_lam_three
      ; test_case "partial application"   `Quick t_multi_arg_lam_partial_application
      ; test_case "in HOF (foldRight)"    `Quick t_multi_arg_lam_in_hof
      ]
    ; "operator sections (Phase 59)",
      [ test_case "(+) as value"          `Quick t_op_section_plus
      ; test_case "(*) in fold"           `Quick t_op_section_times
      ; test_case "(::) cons"             `Quick t_op_section_cons
      ; test_case "(-) subtraction"       `Quick t_op_section_minus_unary_safe
      ]
    ; "let rec (Phase 57)",
      [ test_case "recursive lambda value"  `Quick t_let_rec_lambda_value_self
      ; test_case "mutual at top level"     `Quick t_let_rec_mutual_top_level
      ]
    ; "binding order (Phase 59.5)",
      [ test_case "forward reference"     `Quick t_forward_reference_top_level
      ; test_case "mutual without rec kw" `Quick t_mutual_top_level_no_rec
      ]
    ; "list-comp filter (Phase 58)",
      [ test_case "Just-only keeps"       `Quick t_list_comp_filter_just
      ; test_case "filter + guard"        `Quick t_list_comp_filter_with_guard
      ]
    ; "nested record updates (Phase 56)",
      [ test_case "two levels"            `Quick t_nested_record_update_two_levels
      ; test_case "three levels"          `Quick t_nested_record_update_three_levels
      ; test_case "original unchanged"    `Quick t_nested_record_update_immutable
      ]
    ; "VMulti dispatch",
      [ test_case "non-determining acc"   `Quick t_vmulti_non_determining_accumulator
      ; test_case "Option accumulator routes through list fold" `Quick t_vmulti_option_acc_through_list_fold
      ]
    ; "resolver / typecheck gaps",
      [ test_case "iface method names"    `Quick t_resolve_interface_method_names_work
      ; test_case "constrained + Mut"     `Quick t_constrained_with_effect
      ]
    ]
