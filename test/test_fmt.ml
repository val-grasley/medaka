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

(* ── Round-trip safety net ───────────────────────── *)

(* If the formatter ever produces output whose AST differs from the
   input, [format_source] raises Failure. These tests verify the
   guard doesn't trip on real code. *)
let rt_stdlib_like () =
  let _ = format
    "export data Option a = Some a | None\n\
     map f opt = match opt\n  Some x => Some (f x)\n  None => None\n"
  in ()

(* ── Entry point ─────────────────────────────────── *)

let () =
  Alcotest.run "Medaka Fmt" [
    "idempotency", [
      Alcotest.test_case "simple"        `Quick id_simple;
      Alcotest.test_case "two decls"     `Quick id_two_decls;
      Alcotest.test_case "data type"     `Quick id_data;
      Alcotest.test_case "match expr"    `Quick id_match;
      Alcotest.test_case "with comments" `Quick id_with_comments;
    ];
    "comment preservation", [
      Alcotest.test_case "top of file"   `Quick cp_top;
      Alcotest.test_case "between decls" `Quick cp_between;
      Alcotest.test_case "multiple"      `Quick cp_multiple;
      Alcotest.test_case "eof trailing"  `Quick cp_eof_trailing;
    ];
    "round-trip safety", [
      Alcotest.test_case "stdlib-like"   `Quick rt_stdlib_like;
    ];
  ]
