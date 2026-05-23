open Medaka_lib
open Typecheck

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

let check src =
  try Ok (check_program (parse src))
  with Type_error e -> Error e

(* assert_type src name expected — check that `name` in `src` types as `expected` *)
let assert_type src name expected () =
  match check src with
  | Error e ->
    failwith (Printf.sprintf "Expected program to type-check, but got error:\n  %s\n\nSource:\n%s"
                (pp_error e) src)
  | Ok env ->
    let actual =
      try pp_scheme (List.assoc name env)
      with Not_found ->
        failwith (Printf.sprintf "Name %s not in env. Env contains: %s"
                    name
                    (String.concat ", " (List.map fst env)))
    in
    if actual <> expected then
      failwith (Printf.sprintf
        "Expected type for %s:\n  %s\nGot:\n  %s\n\nSource:\n%s"
        name expected actual src)

(* assert_err src — check that src fails to type-check *)
let assert_err src () =
  match check src with
  | Error _ -> ()
  | Ok env ->
    let summary = String.concat ", "
      (List.map (fun (n, s) -> n ^ " : " ^ pp_scheme s) env) in
    failwith (Printf.sprintf
      "Expected type error, but program type-checked.\n\nEnv: %s\n\nSource:\n%s"
      summary src)

(* ── Basic types ────────────────────────────────── *)

let t_const_int    = assert_type "x = 42\n"     "x" "Int"
let t_const_str    = assert_type "x = \"hi\"\n" "x" "String"
let t_const_bool   = assert_type "x = True\n"   "x" "Bool"
let t_const_unit   = assert_type "x = ()\n"     "x" "Unit"

(* ── Function inference ─────────────────────────── *)

let t_identity   = assert_type "id x = x\n"           "id"   "'a -> 'a"
let t_const_fn   = assert_type "const x _ = x\n"      "const" "'a -> 'b -> 'a"
let t_double     = assert_type "double x = x + x\n"   "double" "Int -> Int"
let t_inc        = assert_type "inc x = x + 1\n"      "inc"  "Int -> Int"
let t_apply      = assert_type "apply f x = f x\n"    "apply" "('a -> 'b) -> 'a -> 'b"
let t_compose    = assert_type "compose f g x = f (g x)\n"  "compose"
                     "('a -> 'b) -> ('c -> 'a) -> 'c -> 'b"

(* ── Polymorphism in use ────────────────────────── *)

let t_use_id_twice = assert_type
  "id x = x\nresult = id (id 5)\n" "result" "Int"

let t_id_at_two_types = assert_type
  {|id x = x
a = id 5
b = id "hi"
|} "a" "Int"

let t_id_at_two_types_b = assert_type
  {|id x = x
a = id 5
b = id "hi"
|} "b" "String"

(* ── If-then-else ───────────────────────────────── *)

let t_if = assert_type
  "abs x = if x < 0 then -x else x\n" "abs" "Int -> Int"

(* ── Type signatures ────────────────────────────── *)

let t_sig_simple = assert_type
  "f : Int -> Int\nf x = x + 1\n" "f" "Int -> Int"

let t_sig_poly = assert_type
  "id : a -> a\nid x = x\n" "id" "'a -> 'a"

(* ── Recursion ──────────────────────────────────── *)

let t_factorial = assert_type
  "fact n = if n == 0 then 1 else n * fact (n - 1)\n"
  "fact" "Int -> Int"

let t_mutual_rec = assert_type
  {|isEven n = if n == 0 then True else isOdd (n - 1)
isOdd n = if n == 0 then False else isEven (n - 1)
|} "isEven" "Int -> Bool"

(* ── ADTs and pattern matching ──────────────────── *)

let t_option_default = assert_type
  {|withDefault d opt =
  match opt
    Some x => x
    None => d
|} "withDefault" "'a -> Option 'a -> 'a"

let t_some_int = assert_type
  "x = Some 5\n" "x" "Option Int"

let t_user_adt = assert_type
  {|data Tree a
  | Leaf
  | Node (Tree a) a (Tree a)

singleton x = Node Leaf x Leaf
|} "singleton" "'a -> Tree 'a"

let t_size = assert_type
  {|data Tree a
  | Leaf
  | Node (Tree a) a (Tree a)

size t =
  match t
    Leaf => 0
    Node l _ r => 1 + size l + size r
|} "size" "Tree 'a -> Int"

(* ── Lists ──────────────────────────────────────── *)

let t_list_int = assert_type "xs = [1, 2, 3]\n" "xs" "List Int"

let t_list_empty = assert_type "xs = []\n" "xs" "List 'a"

let t_length = assert_type
  {|len xs =
  match xs
    [] => 0
    _ :: rest => 1 + len rest
|} "len" "List 'a -> Int"

let t_map = assert_type
  {|map f xs =
  match xs
    [] => []
    x :: rest => f x :: map f rest
|} "map" "('a -> 'b) -> List 'a -> List 'b"

(* ── Tuples ─────────────────────────────────────── *)

let t_swap = assert_type
  {|swap p =
  match p
    (a, b) => (b, a)
|} "swap" "('a, 'b) -> ('b, 'a)"

let t_pair = assert_type "p = (1, \"hello\")\n" "p" "(Int, String)"

(* ── Let-polymorphism ───────────────────────────── *)

let t_let_poly = assert_type
  {|f = let id = (x => x) in (id 5, id "hi")
|} "f" "(Int, String)"

(* ── Errors ─────────────────────────────────────── *)

let e_int_plus_string  = assert_err "x = 5 + \"hi\"\n"
let e_if_non_bool      = assert_err "x = if 5 then 1 else 0\n"
let e_branches_differ  = assert_err "x = if True then 1 else \"hi\"\n"
let e_apply_non_fn     = assert_err "x = 5 1\n"
let e_unbound          = assert_err "f = y\n"
let e_unknown_ctor     = assert_err "f = Banana 5\n"
let e_pattern_mismatch = assert_err
  {|f x =
  match x
    Some y => y
    True => 0
|}
let e_recursive_mismatch = assert_err
  {|bad n = if n == 0 then "zero" else bad (n - 1) + 1
|}
let e_sig_mismatch = assert_err
  "f : Int -> Int\nf x = x + \"hi\"\n"

(* ── Runner ─────────────────────────────────────── *)

let () =
  let open Alcotest in
  run "Typecheck" [
    "literals", [
      test_case "Int"    `Quick t_const_int;
      test_case "String" `Quick t_const_str;
      test_case "Bool"   `Quick t_const_bool;
      test_case "Unit"   `Quick t_const_unit;
    ];
    "function inference", [
      test_case "identity"            `Quick t_identity;
      test_case "const"               `Quick t_const_fn;
      test_case "double"              `Quick t_double;
      test_case "inc"                 `Quick t_inc;
      test_case "apply"               `Quick t_apply;
      test_case "compose"             `Quick t_compose;
    ];
    "polymorphism", [
      test_case "id twice"            `Quick t_use_id_twice;
      test_case "id @ Int"            `Quick t_id_at_two_types;
      test_case "id @ String"         `Quick t_id_at_two_types_b;
      test_case "let-poly"            `Quick t_let_poly;
    ];
    "control flow", [
      test_case "if"                  `Quick t_if;
    ];
    "type sigs", [
      test_case "monomorphic"         `Quick t_sig_simple;
      test_case "polymorphic"         `Quick t_sig_poly;
    ];
    "recursion", [
      test_case "factorial"           `Quick t_factorial;
      test_case "mutual"              `Quick t_mutual_rec;
    ];
    "ADTs", [
      test_case "default opt"         `Quick t_option_default;
      test_case "Some Int"            `Quick t_some_int;
      test_case "user Tree"           `Quick t_user_adt;
      test_case "Tree size"           `Quick t_size;
    ];
    "lists", [
      test_case "list of Int"         `Quick t_list_int;
      test_case "empty list"          `Quick t_list_empty;
      test_case "length"              `Quick t_length;
      test_case "map"                 `Quick t_map;
    ];
    "tuples", [
      test_case "pair"                `Quick t_pair;
      test_case "swap"                `Quick t_swap;
    ];
    "errors", [
      test_case "Int + String"        `Quick e_int_plus_string;
      test_case "if non-bool"         `Quick e_if_non_bool;
      test_case "branches differ"     `Quick e_branches_differ;
      test_case "apply non-fn"        `Quick e_apply_non_fn;
      test_case "unbound var"         `Quick e_unbound;
      test_case "unknown ctor"        `Quick e_unknown_ctor;
      test_case "pat type mismatch"   `Quick e_pattern_mismatch;
      test_case "recursive mismatch"  `Quick e_recursive_mismatch;
      test_case "sig mismatch"        `Quick e_sig_mismatch;
    ];
  ]
