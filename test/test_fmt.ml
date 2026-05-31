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
    ];
  ]
