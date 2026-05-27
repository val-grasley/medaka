(* Thorough stdlib tests — exercise stdlib/core.mdk functions and
   interface impls across edge cases.  list.mdk / array.mdk / string.mdk
   are excluded for now because they live in separate files and need
   the multi-file loader; we focus on what core.mdk provides since it
   is auto-prepended as the prelude. *)

open Medaka_lib.Eval
open Thorough_helpers

(* =====================================================================
   1. Mappable
   ===================================================================== *)

let t_map_list = assert_val "r = map (x => x + 1) [1, 2, 3]\n"
  "r" (VList [VInt 2; VInt 3; VInt 4])

let t_map_list_empty = assert_val "r = map (x => x + 1) []\n"
  "r" (VList [])

let t_map_list_singleton = assert_val "r = map (x => x * 2) [5]\n"
  "r" (VList [VInt 10])

let t_map_option_some = assert_val "r = map (x => x + 1) (Some 5)\n"
  "r" (VCon ("Some", [VInt 6]))

let t_map_option_none = assert_val "r = map (x => x + 1) None\n"
  "r" (VCon ("None", []))

let t_map_result_ok = assert_val "r = map (x => x + 1) (Ok 5)\n"
  "r" (VCon ("Ok", [VInt 6]))

let t_map_result_err = assert_val "r = map (x => x + 1) (Err \"e\")\n"
  "r" (VCon ("Err", [VString "e"]))

(* =====================================================================
   2. Foldable — fold, foldRight, foldMap, toList, length, isEmpty
   ===================================================================== *)

let t_fold_list = assert_val
  "r = fold (a => b => a + b) 0 [1, 2, 3, 4]\n"
  "r" (VInt 10)

let t_fold_list_empty = assert_val
  "r = fold (a => b => a + b) 99 []\n"
  "r" (VInt 99)

let t_fold_right = assert_val
  {|r = foldRight (x => acc => x - acc) 0 [1, 2, 3]
|}
  "r" (VInt 2)
(* foldRight (-) 0 [1,2,3] = 1 - (2 - (3 - 0)) = 1 - (2 - 3) = 1 - (-1) = 2 *)

let t_length_empty = assert_val "r = length []\n" "r" (VInt 0)
let t_length_three = assert_val "r = length [1, 2, 3]\n" "r" (VInt 3)
let t_length_long  = assert_val "r = length [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]\n" "r" (VInt 10)

let t_isEmpty_empty = assert_val "r = isEmpty []\n" "r" (VBool true)
let t_isEmpty_nonempty = assert_val "r = isEmpty [1]\n" "r" (VBool false)

let t_foldmap_string = assert_val
  {|r = foldMap (s => s) ["a", "b", "c"]
|}
  "r" (VString "abc")

let t_foldmap_list = assert_val
  {|r = foldMap (x => [x, x]) [1, 2, 3]
|}
  "r" (VList [VInt 1; VInt 1; VInt 2; VInt 2; VInt 3; VInt 3])

(* =====================================================================
   3. filter / any / all / find / count
   ===================================================================== *)

let t_filter_positive = assert_val
  "r = filter (x => x > 0) [-1, 2, -3, 4]\n"
  "r" (VList [VInt 2; VInt 4])

let t_filter_all_match = assert_val
  "r = filter (x => x > 0) [1, 2, 3]\n"
  "r" (VList [VInt 1; VInt 2; VInt 3])

let t_filter_none_match = assert_val
  "r = filter (x => x < 0) [1, 2, 3]\n"
  "r" (VList [])

let t_filter_empty = assert_val
  "r = filter (x => x > 0) []\n"
  "r" (VList [])

let t_any_true = assert_val
  "r = any (x => x > 5) [1, 2, 6, 3]\n"
  "r" (VBool true)

let t_any_false = assert_val
  "r = any (x => x > 100) [1, 2, 3]\n"
  "r" (VBool false)

let t_any_empty = assert_val
  "r = any (x => x > 0) []\n"
  "r" (VBool false)

let t_all_true = assert_val
  "r = all (x => x > 0) [1, 2, 3]\n"
  "r" (VBool true)

let t_all_false = assert_val
  "r = all (x => x > 0) [1, -1, 3]\n"
  "r" (VBool false)

let t_all_empty_vacuous = assert_val
  "r = all (x => x > 0) []\n"
  "r" (VBool true)

let t_find_match = assert_val
  "r = find (x => x > 2) [1, 2, 3, 4]\n"
  "r" (VCon ("Some", [VInt 3]))

let t_find_no_match = assert_val
  "r = find (x => x > 100) [1, 2, 3]\n"
  "r" (VCon ("None", []))

let t_find_first_match = assert_val
  "r = find (x => x > 0) [-1, 5, -2, 7]\n"
  "r" (VCon ("Some", [VInt 5]))

let t_count_some = assert_val
  "r = count (x => x > 0) [-1, 2, -3, 4, 5]\n"
  "r" (VInt 3)

let t_count_none = assert_val
  "r = count (x => x > 100) [1, 2, 3]\n"
  "r" (VInt 0)

let t_count_empty = assert_val
  "r = count (x => x > 0) []\n"
  "r" (VInt 0)

(* =====================================================================
   4. Boolean helpers
   ===================================================================== *)

let t_not_true  = assert_val "r = not True\n"  "r" (VBool false)
let t_not_false = assert_val "r = not False\n" "r" (VBool true)
let t_otherwise = assert_val "r = otherwise\n" "r" (VBool true)

let t_and_tt = assert_val "r = and True True\n"   "r" (VBool true)
let t_and_tf = assert_val "r = and True False\n"  "r" (VBool false)
let t_and_ft = assert_val "r = and False True\n"  "r" (VBool false)
let t_and_ff = assert_val "r = and False False\n" "r" (VBool false)

let t_or_tt = assert_val "r = or True True\n"   "r" (VBool true)
let t_or_tf = assert_val "r = or True False\n"  "r" (VBool true)
let t_or_ft = assert_val "r = or False True\n"  "r" (VBool true)
let t_or_ff = assert_val "r = or False False\n" "r" (VBool false)

let t_xor_tt = assert_val "r = xor True True\n"   "r" (VBool false)
let t_xor_tf = assert_val "r = xor True False\n"  "r" (VBool true)
let t_xor_ft = assert_val "r = xor False True\n"  "r" (VBool true)
let t_xor_ff = assert_val "r = xor False False\n" "r" (VBool false)

(* =====================================================================
   5. Option helpers
   ===================================================================== *)

let t_isSome_some = assert_val "r = isSome (Some 5)\n" "r" (VBool true)
let t_isSome_none = assert_val "r = isSome None\n"     "r" (VBool false)
let t_isNone_some = assert_val "r = isNone (Some 5)\n" "r" (VBool false)
let t_isNone_none = assert_val "r = isNone None\n"     "r" (VBool true)

let t_fromOption_default =
  assert_val "r = fromOption 99 None\n" "r" (VInt 99)
let t_fromOption_some =
  assert_val "r = fromOption 99 (Some 42)\n" "r" (VInt 42)

let t_toResult_some =
  assert_val "r = toResult \"e\" (Some 5)\n" "r" (VCon ("Ok", [VInt 5]))
let t_toResult_none =
  assert_val "r = toResult \"e\" None\n" "r" (VCon ("Err", [VString "e"]))

(* =====================================================================
   6. Result helpers
   ===================================================================== *)

let t_isOk_ok = assert_val "r = isOk (Ok 5)\n" "r" (VBool true)
let t_isOk_err = assert_val "r = isOk (Err \"e\")\n" "r" (VBool false)
let t_isErr_ok = assert_val "r = isErr (Ok 5)\n" "r" (VBool false)
let t_isErr_err = assert_val "r = isErr (Err \"e\")\n" "r" (VBool true)

(* =====================================================================
   7. Utility combinators
   ===================================================================== *)

let t_identity_int = assert_val "r = identity 42\n" "r" (VInt 42)
let t_identity_str = assert_val "r = identity \"hi\"\n" "r" (VString "hi")

let t_const_int = assert_val "r = const 5 99\n" "r" (VInt 5)
let t_const_drop_second = assert_val "r = const \"keep\" \"drop\"\n" "r" (VString "keep")

let t_flip_sub =
  (* flip subtract: flip (-) 1 10 = 10 - 1 = 9 *)
  assert_val
    {|sub a b = a - b
r = flip sub 1 10
|}
    "r" (VInt 9)

let t_compose_basic =
  assert_val
    {|inc x = x + 1
dbl x = x * 2
r = compose dbl inc 5
|}
    "r" (VInt 12)
(* compose dbl inc 5 = dbl (inc 5) = dbl 6 = 12 *)

let t_pipe_basic =
  assert_val
    {|inc x = x + 1
dbl x = x * 2
r = pipe inc dbl 5
|}
    "r" (VInt 12)
(* pipe inc dbl 5 = dbl (inc 5) = 12 *)

let t_apply_basic =
  assert_val
    {|inc x = x + 1
r = apply inc 5
|}
    "r" (VInt 6)

(* =====================================================================
   8. Thenable: andThen, flatMap, flat, when, unless
   ===================================================================== *)

let t_andThen_option_some =
  assert_val
    "r = andThen (Some 5) (x => Some (x + 1))\n"
    "r" (VCon ("Some", [VInt 6]))

let t_andThen_option_none =
  assert_val
    "r = andThen None (x => Some (x + 1))\n"
    "r" (VCon ("None", []))

let t_andThen_result_chain =
  assert_val
    "r = andThen (Ok 10) (x => Ok (x * 2))\n"
    "r" (VCon ("Ok", [VInt 20]))

let t_flatMap_option =
  assert_val
    "r = flatMap (x => Some (x + 1)) (Some 5)\n"
    "r" (VCon ("Some", [VInt 6]))

let t_flat_option =
  assert_val
    "r = flat (Some (Some 5))\n"
    "r" (VCon ("Some", [VInt 5]))

let t_flat_option_inner_none =
  assert_val
    "r = flat (Some None)\n"
    "r" (VCon ("None", []))

let t_flat_option_outer_none =
  assert_val
    "r = flat None\n"
    "r" (VCon ("None", []))

(* =====================================================================
   9. Applicative — ap, pure
   ===================================================================== *)

let t_ap_option =
  assert_val
    "r = ap (Some (x => x + 1)) (Some 5)\n"
    "r" (VCon ("Some", [VInt 6]))

let t_ap_option_left_none =
  assert_val
    "r = ap None (Some 5)\n"
    "r" (VCon ("None", []))

let t_ap_option_right_none =
  assert_val
    "r = ap (Some (x => x + 1)) None\n"
    "r" (VCon ("None", []))

(* pure outside of a do-block: monad context unknown, returns value. *)
let t_pure_no_context =
  assert_val "r = pure 5\n" "r" (VInt 5)

(* pure inside do-block dispatches to the right monad. *)
let t_pure_in_option_do =
  assert_val
    {|r = do
  x <- Some 1
  pure (x + 10)
|}
    "r" (VCon ("Some", [VInt 11]))

(* =====================================================================
   10. Eq for List (the only stdlib-provided generic Eq impl)
   ===================================================================== *)

let t_eq_list_int =
  assert_val
    {|impl Eq Int where
  eq x y = x == y
r = eq [1, 2, 3] [1, 2, 3]
|}
    "r" (VBool true)

let t_eq_list_int_neg =
  assert_val
    {|impl Eq Int where
  eq x y = x == y
r = eq [1, 2, 3] [1, 2, 4]
|}
    "r" (VBool false)

let t_eq_list_empty =
  assert_val
    {|impl Eq Int where
  eq x y = x == y
r = eq ([] : List Int) ([] : List Int)
|}
    "r" (VBool true)
(* NOTE: annotation needed to resolve the polymorphic List a *)

let t_eq_list_length_diff =
  assert_val
    {|impl Eq Int where
  eq x y = x == y
r = eq [1, 2, 3] [1, 2]
|}
    "r" (VBool false)

(* =====================================================================
   11. Semigroup / Monoid
   ===================================================================== *)

let t_semigroup_list =
  assert_val "r = [1, 2] ++ [3, 4]\n"
    "r" (VList [VInt 1; VInt 2; VInt 3; VInt 4])

let t_semigroup_string =
  assert_val {|r = "foo" ++ "bar"
|} "r" (VString "foobar")

(* `r = empty` with `r : String` leaves the value as a VMulti dispatch
   because runtime dispatch requires an argument with a type tag —
   nullary methods like `empty` can't be dispatched by type annotation
   alone (types are erased at runtime).  Force dispatch via use:
   `"x" ++ empty` selects the String semigroup impl. *)
let t_monoid_string_empty =
  assert_val {|r = "x" ++ empty
|} "r" (VString "x")

(* And the original behavior — `empty` alone stays as VMulti pending
   dispatch.  Pin via pp_value, not as a clean value. *)
let t_monoid_empty_unresolved =
  let v = run {|r : String
r = empty
|} "r" in
  fun () ->
    match v with
    | VMulti _ -> ()
    | other ->
      failwith (Printf.sprintf
        "Expected VMulti (empty stays as dispatch until used), got %s"
        (pp_value other))

(* =====================================================================
   12. when / unless (require monad context)
   ===================================================================== *)

let t_when_true =
  assert_val
    {|r = do
  _ <- Some ()
  when True (pure ())
  pure 42
|}
    "r" (VCon ("Some", [VInt 42]))

let t_when_false =
  assert_val
    {|r = do
  _ <- Some ()
  when False (pure ())
  pure 99
|}
    "r" (VCon ("Some", [VInt 99]))

let t_unless_true =
  assert_val
    {|r = do
  _ <- Some ()
  unless True (pure ())
  pure 1
|}
    "r" (VCon ("Some", [VInt 1]))

let t_unless_false =
  assert_val
    {|r = do
  _ <- Some ()
  unless False (pure ())
  pure 2
|}
    "r" (VCon ("Some", [VInt 2]))

(* =====================================================================
   Test registration
   ===================================================================== *)

let () =
  let open Alcotest in
  run "thorough stdlib"
    [
      ( "Mappable",
        [ test_case "map List"           `Quick t_map_list
        ; test_case "map [] empty"       `Quick t_map_list_empty
        ; test_case "map singleton"      `Quick t_map_list_singleton
        ; test_case "map (Some x)"       `Quick t_map_option_some
        ; test_case "map None"           `Quick t_map_option_none
        ; test_case "map (Ok x)"         `Quick t_map_result_ok
        ; test_case "map (Err x)"        `Quick t_map_result_err
        ] );
      ( "Foldable",
        [ test_case "fold sum"           `Quick t_fold_list
        ; test_case "fold empty"         `Quick t_fold_list_empty
        ; test_case "foldRight"          `Quick t_fold_right
        ; test_case "length []"          `Quick t_length_empty
        ; test_case "length [1..3]"      `Quick t_length_three
        ; test_case "length 10-elem"     `Quick t_length_long
        ; test_case "isEmpty []"         `Quick t_isEmpty_empty
        ; test_case "isEmpty [1]"        `Quick t_isEmpty_nonempty
        ; test_case "foldMap String"     `Quick t_foldmap_string
        ; test_case "foldMap List"       `Quick t_foldmap_list
        ] );
      ( "filter/any/all/find/count",
        [ test_case "filter positives"   `Quick t_filter_positive
        ; test_case "filter all"         `Quick t_filter_all_match
        ; test_case "filter none"        `Quick t_filter_none_match
        ; test_case "filter []"          `Quick t_filter_empty
        ; test_case "any true"           `Quick t_any_true
        ; test_case "any false"          `Quick t_any_false
        ; test_case "any []"             `Quick t_any_empty
        ; test_case "all true"           `Quick t_all_true
        ; test_case "all false"          `Quick t_all_false
        ; test_case "all [] vacuous"     `Quick t_all_empty_vacuous
        ; test_case "find match"         `Quick t_find_match
        ; test_case "find no match"      `Quick t_find_no_match
        ; test_case "find first"         `Quick t_find_first_match
        ; test_case "count some"         `Quick t_count_some
        ; test_case "count none"         `Quick t_count_none
        ; test_case "count []"           `Quick t_count_empty
        ] );
      ( "booleans",
        [ test_case "not True"           `Quick t_not_true
        ; test_case "not False"          `Quick t_not_false
        ; test_case "otherwise"          `Quick t_otherwise
        ; test_case "and TT"             `Quick t_and_tt
        ; test_case "and TF"             `Quick t_and_tf
        ; test_case "and FT"             `Quick t_and_ft
        ; test_case "and FF"             `Quick t_and_ff
        ; test_case "or TT"              `Quick t_or_tt
        ; test_case "or TF"              `Quick t_or_tf
        ; test_case "or FT"              `Quick t_or_ft
        ; test_case "or FF"              `Quick t_or_ff
        ; test_case "xor TT"             `Quick t_xor_tt
        ; test_case "xor TF"             `Quick t_xor_tf
        ; test_case "xor FT"             `Quick t_xor_ft
        ; test_case "xor FF"             `Quick t_xor_ff
        ] );
      ( "Option helpers",
        [ test_case "isSome Some"        `Quick t_isSome_some
        ; test_case "isSome None"        `Quick t_isSome_none
        ; test_case "isNone Some"        `Quick t_isNone_some
        ; test_case "isNone None"        `Quick t_isNone_none
        ; test_case "fromOption default" `Quick t_fromOption_default
        ; test_case "fromOption Some"    `Quick t_fromOption_some
        ; test_case "toResult Some"      `Quick t_toResult_some
        ; test_case "toResult None"      `Quick t_toResult_none
        ] );
      ( "Result helpers",
        [ test_case "isOk Ok"            `Quick t_isOk_ok
        ; test_case "isOk Err"           `Quick t_isOk_err
        ; test_case "isErr Ok"           `Quick t_isErr_ok
        ; test_case "isErr Err"          `Quick t_isErr_err
        ] );
      ( "combinators",
        [ test_case "identity Int"       `Quick t_identity_int
        ; test_case "identity String"    `Quick t_identity_str
        ; test_case "const value"        `Quick t_const_int
        ; test_case "const drop second"  `Quick t_const_drop_second
        ; test_case "flip sub"           `Quick t_flip_sub
        ; test_case "compose dbl inc"    `Quick t_compose_basic
        ; test_case "pipe inc dbl"       `Quick t_pipe_basic
        ; test_case "apply"              `Quick t_apply_basic
        ] );
      ( "Thenable",
        [ test_case "andThen Some Some"  `Quick t_andThen_option_some
        ; test_case "andThen None _"     `Quick t_andThen_option_none
        ; test_case "andThen Ok chain"   `Quick t_andThen_result_chain
        ; test_case "flatMap Option"     `Quick t_flatMap_option
        ; test_case "flat Some Some"     `Quick t_flat_option
        ; test_case "flat Some None"     `Quick t_flat_option_inner_none
        ; test_case "flat None"          `Quick t_flat_option_outer_none
        ] );
      ( "Applicative",
        [ test_case "ap Some Some"       `Quick t_ap_option
        ; test_case "ap None _"          `Quick t_ap_option_left_none
        ; test_case "ap Some None"       `Quick t_ap_option_right_none
        ; test_case "pure no context"    `Quick t_pure_no_context
        ; test_case "pure in Option do"  `Quick t_pure_in_option_do
        ] );
      ( "Eq for List",
        [ test_case "eq [1,2,3] [1,2,3]" `Quick t_eq_list_int
        ; test_case "eq [1,2,3] [1,2,4]" `Quick t_eq_list_int_neg
        ; test_case "eq [] []"           `Quick t_eq_list_empty
        ; test_case "eq length diff"     `Quick t_eq_list_length_diff
        ] );
      ( "Semigroup / Monoid",
        [ test_case "List ++ List"       `Quick t_semigroup_list
        ; test_case "String ++ String"   `Quick t_semigroup_string
        ; test_case "Monoid String ε via use" `Quick t_monoid_string_empty
        ; test_case "empty unresolved (VMulti)" `Quick t_monoid_empty_unresolved
        ] );
      ( "when / unless",
        [ test_case "when True"          `Quick t_when_true
        ; test_case "when False"         `Quick t_when_false
        ; test_case "unless True"        `Quick t_unless_true
        ; test_case "unless False"       `Quick t_unless_false
        ] );
    ]
