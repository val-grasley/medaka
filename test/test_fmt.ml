(* Tests for the `medaka fmt` formatter.

   Three properties matter:
   1. Idempotency  - formatting a formatted file is a no-op.
   2. Round-trip   - the formatted output reparses to the same AST.
   3. Comment preservation - line comments survive formatting at the
      right positions (before the declaration they preceded in source). *)

open Medaka_lib

let format src = Fmt.format_source ~filename:"<test>" src

let idempotent src () =
  let once = format src in
  let twice = format once in
  if once <> twice then
    failwith (Printf.sprintf
                "Not idempotent.\nFirst pass:\n%s\nSecond pass:\n%s\n"
                once twice)

let contains needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  let rec loop i =
    if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else loop (i + 1)
  in
  loop 0

let preserves comments src () =
  let out = format src in
  List.iter (fun c ->
    if not (contains c out) then
      failwith (Printf.sprintf
                  "Comment %S not preserved in output:\n%s" c out)
  ) comments

(* ── Idempotency ─────────────────────────────────── *)

let id_simple    = idempotent "x = 1\n"
let id_two_decls = idempotent "x = 1\n\ny = 2\n"
let id_data      = idempotent "data Color = Red | Green | Blue\n"
let id_match     = idempotent
  "describe x = match x\n  0 => \"zero\"\n  _ => \"other\"\n"
let id_with_comments =
  idempotent "-- header\nx = 1\n\n-- between\ny = 2\n"

(* ── Comment preservation ────────────────────────── *)

let cp_top =
  preserves ["-- top of file"]
    "-- top of file\nx = 1\n"

let cp_between =
  preserves ["-- between decls"]
    "x = 1\n\n-- between decls\ny = 2\n"

let cp_multiple =
  preserves ["-- first"; "-- second"; "-- third"]
    "-- first\n-- second\nx = 1\n\n-- third\ny = 2\n"

let cp_eof_trailing =
  preserves ["-- after last decl"]
    "x = 1\n\n-- after last decl\n"

let cp_block =
  preserves ["{- block -}"]
    "{- block -}\nx = 1\n"

let cp_block_multiline =
  preserves ["{- a\nb -}"]
    "{- a\nb -}\nx = 1\n"

let id_block_between =
  idempotent "x = 1\n\n{- between decls -}\ny = 2\n"

(* ── Round-trip safety net ───────────────────────── *)

(* If the formatter ever produces output whose AST differs from the
   input, [format_source] raises Failure. These tests verify the
   guard doesn't trip on real code. *)
let rt_stdlib_like () =
  let _ = format
    "export data Option a = Some a | None\n\
     map f opt = match opt\n  Some x => Some (f x)\n  None => None\n"
  in ()

(* Multi-param lambda should round-trip as `x y => x + y`, not `x => y => x + y`. *)
let rt_multi_param_lambda () =
  let src = "add = x y => x + y\n" in
  let out = format src in
  if not (contains "x y =>" out) then
    failwith (Printf.sprintf "Expected 'x y =>' in formatted output, got:\n%s" out)

(* Surface sugar must survive formatting rather than being printed as its
   desugared core form. *)
let id_guards   = idempotent
  "classify n\n  | n < 0 = \"neg\"\n  | otherwise = \"pos\"\n"
let id_section  = idempotent "f = map (+ 1) xs\n"
let id_function = idempotent "k =\n  function\n    0 => \"z\"\n    _ => \"nz\"\n"

(* Function guards stay as guard arms, not a desugared if/else chain. *)
let rt_guards_preserved () =
  let out = format "classify n\n  | n < 0 = \"neg\"\n  | otherwise = \"pos\"\n" in
  if contains "if " out || contains "Non-exhaustive" out then
    failwith (Printf.sprintf "Guards were desugared on format:\n%s" out);
  if not (contains "| n < 0 = " out) then
    failwith (Printf.sprintf "Guard arm not preserved:\n%s" out)

(* Sections stay as sections, not a lambda over a synthetic variable. *)
let rt_section_preserved () =
  let out = format "f = map (+ 1) xs\n" in
  if contains "_s" out || contains "=>" out then
    failwith (Printf.sprintf "Section was desugared on format:\n%s" out);
  if not (contains "(+ 1)" out) then
    failwith (Printf.sprintf "Section not preserved:\n%s" out)

(* `function` stays a function block, not a lambda + match. *)
let rt_function_preserved () =
  let out = format "k =\n  function\n    0 => \"z\"\n    _ => \"nz\"\n" in
  if contains "__fn_arg" out then
    failwith (Printf.sprintf "function keyword was desugared on format:\n%s" out);
  if not (contains "function" out) then
    failwith (Printf.sprintf "function keyword not preserved:\n%s" out)

(* An as-pattern in argument position must stay parenthesized as a whole
   (`g (acc@Some _) = acc`); a bare `acc@(Some _)` fails to reparse. *)
let rt_as_pattern_arg () =
  let _ = format
    "f xs = g xs where\n  g (acc@Some _) = acc\n  g None = None\n"
  in ()

let id_as_pattern_arg = idempotent
  "f xs = g xs where\n  g (acc@Some _) = acc\n  g None = None\n"

(* A negative (unary-minus) argument must be parenthesized: `randomInt (-1000) 1000`.
   Without parens it reparses as the binary `randomInt - 1000 1000`. *)
let rt_negative_arg () =
  let out = format "x = randomInt (-1000) 1000\n" in
  if not (contains "(-1000)" out) then
    failwith (Printf.sprintf "Negative arg lost its parens:\n%s" out)

let id_negative_arg = idempotent "x = randomInt (-1000) 1000\n"

(* impl_loc is a source position and must be ignored by the round-trip AST
   comparison: when a preceding decl reflows (here a single-line data decl
   expands to multiple lines), the impl moves to a different line. *)
let rt_impl_loc_reflow () =
  let _ = format
    "data Foo = A | B\nexport impl Eq Int where\n  eq a b = a == b\n"
  in ()

(* A constructor pattern in argument position parenthesizes exactly once:
   `f (Some x)`, never `f ((Some x))`. *)
let rt_no_double_paren_con () =
  let out = format "f (Some x) = x\nf None = 0\n" in
  if contains "((" out then
    failwith (Printf.sprintf "Constructor pattern double-parenthesized:\n%s" out)

let id_con_pattern_arg = idempotent "f (Some x) = x\nf None = 0\n"

(* A nested type application prints left-associatively: `Result e a`,
   never `(Result e) a`. *)
let rt_no_paren_type_app () =
  let out = format "g : Result e a -> Int\ng x = 0\n" in
  if contains "(Result" out then
    failwith (Printf.sprintf "Type application left operand parenthesized:\n%s" out)

let id_type_app = idempotent "g : Result e a -> Int\ng x = 0\n"

(* A short `data` declaration stays on one line rather than splitting to the
   one-variant-per-line form. *)
let rt_short_data_one_line () =
  let out = format "public export data Option a = Some a | None\n" in
  if contains "\n  |" out then
    failwith (Printf.sprintf "Short data decl was split to multiline:\n%s" out);
  if not (contains "data Option a = Some a | None" out) then
    failwith (Printf.sprintf "Single-line data form not produced:\n%s" out)

let id_short_data = idempotent "public export data Option a = Some a | None\n"

(* A short data decl with inline `deriving` also stays on one line. *)
let id_short_data_deriving =
  idempotent "data C = Red | RGB Int Int Int deriving (Generic)\n"

(* A data declaration too wide for one line splits to one variant per line. *)
let rt_wide_data_splits () =
  let out = format
    "data Rep = RCon String (List Rep) | RRecord String (List RField) \
     | RInt Int | RFloat Float | RString String | RBool Bool | RChar Char | RUnit\n"
  in
  (* Haskell-style: first variant introduced by `=`, the rest by `|`. *)
  if not (contains "\n  = RCon" out) then
    failwith (Printf.sprintf "Wide data decl was not split:\n%s" out);
  if not (contains "\n  | RRecord" out) then
    failwith (Printf.sprintf "Wide data decl rest-variants not piped:\n%s" out)

let id_wide_data = idempotent
  "data Rep = RCon String (List Rep) | RRecord String (List RField) \
   | RInt Int | RFloat Float | RString String | RBool Bool | RChar Char | RUnit\n"

(* The Haskell-style multiline block form (`= ` first, `| ` rest) parses and
   round-trips unchanged. *)
let id_block_data = idempotent
  "data Tree a\n  = Leaf\n  | Node (Tree a) a (Tree a)\n  | Tip Int Int Int Int Int Int Int Int\n"

(* ── Entry point ─────────────────────────────────── *)

let () =
  Alcotest.run "Medaka Fmt" [
    "idempotency", [
      Alcotest.test_case "simple"        `Quick id_simple;
      Alcotest.test_case "two decls"     `Quick id_two_decls;
      Alcotest.test_case "data type"     `Quick id_data;
      Alcotest.test_case "match expr"    `Quick id_match;
      Alcotest.test_case "with comments" `Quick id_with_comments;
      Alcotest.test_case "block between" `Quick id_block_between;
      Alcotest.test_case "guards"        `Quick id_guards;
      Alcotest.test_case "section"       `Quick id_section;
      Alcotest.test_case "function kw"   `Quick id_function;
      Alcotest.test_case "as-pattern arg" `Quick id_as_pattern_arg;
      Alcotest.test_case "negative arg"   `Quick id_negative_arg;
      Alcotest.test_case "con pattern arg" `Quick id_con_pattern_arg;
      Alcotest.test_case "type app"       `Quick id_type_app;
      Alcotest.test_case "short data"     `Quick id_short_data;
      Alcotest.test_case "short data deriving" `Quick id_short_data_deriving;
      Alcotest.test_case "wide data"      `Quick id_wide_data;
      Alcotest.test_case "block data"     `Quick id_block_data;
    ];
    "comment preservation", [
      Alcotest.test_case "top of file"   `Quick cp_top;
      Alcotest.test_case "between decls" `Quick cp_between;
      Alcotest.test_case "multiple"      `Quick cp_multiple;
      Alcotest.test_case "eof trailing"  `Quick cp_eof_trailing;
      Alcotest.test_case "block"         `Quick cp_block;
      Alcotest.test_case "block multiline" `Quick cp_block_multiline;
    ];
    "round-trip safety", [
      Alcotest.test_case "stdlib-like"       `Quick rt_stdlib_like;
      Alcotest.test_case "multi-param lambda" `Quick rt_multi_param_lambda;
      Alcotest.test_case "guards preserved"   `Quick rt_guards_preserved;
      Alcotest.test_case "section preserved"  `Quick rt_section_preserved;
      Alcotest.test_case "function preserved" `Quick rt_function_preserved;
      Alcotest.test_case "as-pattern arg"     `Quick rt_as_pattern_arg;
      Alcotest.test_case "negative arg"       `Quick rt_negative_arg;
      Alcotest.test_case "impl_loc reflow"    `Quick rt_impl_loc_reflow;
      Alcotest.test_case "no double paren con" `Quick rt_no_double_paren_con;
      Alcotest.test_case "no paren type app"  `Quick rt_no_paren_type_app;
      Alcotest.test_case "short data one line" `Quick rt_short_data_one_line;
      Alcotest.test_case "wide data splits"    `Quick rt_wide_data_splits;
    ];
  ]
