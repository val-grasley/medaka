(* Round-trip tests: parse source → pretty-print → parse again → check ASTs match.
   The printed source need not be byte-identical to the original; what matters
   is that re-parsing yields the same AST. *)

open Medaka_lib

let parse src =
  Lexer.reset ();
  let lexbuf = Lexing.from_string src in
  try Parser.program Lexer.token lexbuf
  with
  | Parser.Error ->
    let pos = lexbuf.Lexing.lex_curr_p in
    failwith (Printf.sprintf "Parse error at line %d col %d in:\n%s"
                pos.Lexing.pos_lnum
                (pos.Lexing.pos_cnum - pos.Lexing.pos_bol)
                src)

let roundtrip src =
  let ast1 = parse src in
  let printed = Printer.program_to_string ast1 in
  let ast2 =
    try parse printed
    with Failure msg ->
      failwith (Printf.sprintf
        "Re-parse of printed output failed: %s\n\nOriginal:\n%s\nPrinted:\n%s"
        msg src printed)
  in
  if ast1 <> ast2 then
    failwith (Printf.sprintf
      "AST mismatch on round-trip.\n\nOriginal source:\n%s\nPrinted:\n%s\n\
       AST1 has %d decls, AST2 has %d decls."
      src printed (List.length ast1) (List.length ast2))

(* ── Test cases ──────────────────────────────────── *)

let mk src () = roundtrip src

(* Type signatures *)
let ts_simple    = mk "add : Int -> Int -> Int\n"
let ts_typevar   = mk "id : a -> a\n"
let ts_effect    = mk "readFile : String -> <IO> String\n"
let ts_multieff  = mk "fetch : String -> <Async, IO> String\n"
let ts_typeapp   = mk "head : List a -> Option a\n"
let ts_nested    = mk "foo : List (Option a) -> Option (List a)\n"
let ts_funarg    = mk "apply : (a -> b) -> a -> b\n"
let ts_tuple     = mk "swap : (a, b) -> (b, a)\n"

(* Function definitions *)
let fd_const     = mk "answer = 42\n"
let fd_one_arg   = mk "double x = x + x\n"
let fd_pat_lit   = mk "factorial 0 = 1\n"
let fd_wildcard  = mk "const x _ = x\n"
let fd_cons_pat  = mk "head (x::_) = x\n"
let fd_con_pat   = mk "unwrap (Some x) = x\n"

(* Expressions in fn bodies *)
let ex_lambda    = mk "f = x => x + 1\n"
let ex_lam_tup   = mk "add = (x, y) => x + y\n"
let ex_let       = mk "f = let x = 5 in x + 1\n"
let ex_let_mut   = mk "f = let mut x = 5 in x\n"
let ex_if        = mk "abs x = if x > 0 then x else -x\n"
let ex_app       = mk "v = f x y\n"
let ex_infix     = mk "v = x `div` y\n"
let ex_list      = mk "xs = [1, 2, 3]\n"
let ex_array     = mk "xs = [|1, 2, 3|]\n"
let ex_tuple     = mk "p = (1, \"hello\")\n"
let ex_field     = mk "name = person.name\n"
let ex_rec_new   = mk "alice = Person { name = \"Alice\", age = 30 }\n"
let ex_rec_upd   = mk "older p = { p | age = 31 }\n"
let ex_index     = mk "first arr = arr[0]\n"
let ex_annot     = mk "x = (5 : Int)\n"
let ex_nested    = mk "compute x y = (x + y) * (x - y)\n"
let ex_neg       = mk "neg x = -x\n"

(* Match expressions *)
let m_basic = mk
{|f x =
  match x
    0 => "zero"
    _ => "nonzero"
|}

let m_guard = mk
{|sign x =
  match x
    n if n > 0 => 1
    n if n < 0 => -1
    _ => 0
|}

let m_constructor = mk
{|extract opt =
  match opt
    Some x => x
    None => 0
|}

(* Data types *)
let d_inline     = mk "data Bool = True | False\n"
let d_param      = mk "data Option a = Some a | None\n"
let d_block      = mk
{|data Shape
  | Circle Float
  | Rectangle Float Float
|}

(* Records *)
let r_simple = mk
{|record Person
  name : String
  age : Int
|}

(* Do notation *)
let do_basic = mk
{|result =
  do
    x <- foo
    y <- bar x
    pure (x + y)
|}

let do_with_let = mk
{|main =
  do
    let x = 5
    y <- compute x
    pure y
|}

(* Use declarations *)
let u_simple  = mk "use utils.greet\n"
let u_group   = mk "use utils.{greet, helper}\n"
let u_pub     = mk "pub use list.{map, filter}\n"
let u_alias   = mk "use collections.HashMap as HM\n"
let u_wild    = mk "use utils.*\n"

(* Multiple declarations *)
let multi = mk
{|x : Int
x = 42

factorial : Int -> Int
factorial 0 = 1
factorial n = n * factorial (n - 1)
|}

(* Interface and impl (not covered by test_parser but valid in grammar) *)
let iface_basic = mk
{|interface Eq a where
  eq : a -> a -> Bool
|}

let impl_basic = mk
{|impl Eq Int where
  eq x y = x == y
|}

(* ── Test runner ─────────────────────────────────── *)

let () =
  let open Alcotest in
  run "Medaka Round-Trip" [
    "type signatures", [
      test_case "simple"          `Quick ts_simple;
      test_case "type var"        `Quick ts_typevar;
      test_case "effect"          `Quick ts_effect;
      test_case "multi-effect"    `Quick ts_multieff;
      test_case "type app"        `Quick ts_typeapp;
      test_case "nested app"      `Quick ts_nested;
      test_case "function arg"    `Quick ts_funarg;
      test_case "tuple"           `Quick ts_tuple;
    ];
    "function definitions", [
      test_case "constant"         `Quick fd_const;
      test_case "one arg"          `Quick fd_one_arg;
      test_case "literal pat"      `Quick fd_pat_lit;
      test_case "wildcard"         `Quick fd_wildcard;
      test_case "cons pat"         `Quick fd_cons_pat;
      test_case "constructor pat"  `Quick fd_con_pat;
    ];
    "expressions", [
      test_case "lambda"           `Quick ex_lambda;
      test_case "lambda tuple"     `Quick ex_lam_tup;
      test_case "let"              `Quick ex_let;
      test_case "let mut"          `Quick ex_let_mut;
      test_case "if-then-else"     `Quick ex_if;
      test_case "application"      `Quick ex_app;
      test_case "infix backtick"   `Quick ex_infix;
      test_case "list"             `Quick ex_list;
      test_case "array"            `Quick ex_array;
      test_case "tuple"            `Quick ex_tuple;
      test_case "field access"     `Quick ex_field;
      test_case "record create"    `Quick ex_rec_new;
      test_case "record update"    `Quick ex_rec_upd;
      test_case "index"            `Quick ex_index;
      test_case "type annot"       `Quick ex_annot;
      test_case "nested binops"    `Quick ex_nested;
      test_case "negate"           `Quick ex_neg;
    ];
    "match", [
      test_case "basic"            `Quick m_basic;
      test_case "with guard"       `Quick m_guard;
      test_case "constructor arms" `Quick m_constructor;
    ];
    "data types", [
      test_case "inline"           `Quick d_inline;
      test_case "parametric"       `Quick d_param;
      test_case "block"            `Quick d_block;
    ];
    "records", [
      test_case "simple"           `Quick r_simple;
    ];
    "do notation", [
      test_case "basic"            `Quick do_basic;
      test_case "with let"         `Quick do_with_let;
    ];
    "use", [
      test_case "simple"           `Quick u_simple;
      test_case "group"            `Quick u_group;
      test_case "pub"              `Quick u_pub;
      test_case "alias"            `Quick u_alias;
      test_case "wildcard"         `Quick u_wild;
    ];
    "multi-decl", [
      test_case "mixed"            `Quick multi;
    ];
    "interface/impl", [
      test_case "interface basic"  `Quick iface_basic;
      test_case "impl basic"       `Quick impl_basic;
    ];
  ]
