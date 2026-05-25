open Medaka_lib
open Eval

let parse src =
  Lexer.reset ();
  let lexbuf = Lexing.from_string src in
  try Parser.program Lexer.token lexbuf
  with Parser.Error ->
    let pos = lexbuf.Lexing.lex_curr_p in
    failwith (Printf.sprintf "Parse error at %d:%d"
                pos.Lexing.pos_lnum (pos.Lexing.pos_cnum - pos.Lexing.pos_bol))

let capture_run src =
  let prog = parse src in
  let buf = Buffer.create 64 in
  output_hook := Buffer.add_string buf;
  (try ignore (eval_program prog)
   with e -> output_hook := print_string; raise e);
  output_hook := print_string;
  Buffer.contents buf

let assert_output src expected () =
  let actual = capture_run src in
  if actual <> expected then
    failwith (Printf.sprintf "Expected:\n%s\nGot:\n%s\n\nSource:\n%s"
                expected actual src)

let assert_run_err src () =
  match (try Some (capture_run src) with Eval_error _ -> None) with
  | None -> ()
  | Some out ->
    failwith (Printf.sprintf "Expected runtime error but got:\n%s\n\nSource:\n%s" out src)

(* ── Hello world ─────────────────────────────────────────────────────────── *)

let t_hello = assert_output
  {|main : <IO> Unit
main = println "Hello, world!"
|}
  "Hello, world!\n"

(* ── Recursion + integer arithmetic ──────────────────────────────────────── *)

let t_factorial = assert_output
  {|factorial n =
  match n
    0 => 1
    n => n * factorial (n - 1)

main : <IO> Unit
main = println (factorial 10)
|}
  "3628800\n"

(* ── ADT construction, match, println ────────────────────────────────────── *)

let t_adt_match = assert_output
  {|data Color
  | Red
  | Green
  | Blue

name c =
  match c
    Red   => "red"
    Green => "green"
    Blue  => "blue"

main : <IO> Unit
main = println (name Green)
|}
  "green\n"

(* ── Multiple prints in a do-block ───────────────────────────────────────── *)

let t_multi_print = assert_output
  {|main : <IO> Unit
main =
  do
    println "one"
    println "two"
    println "three"
|}
  "one\ntwo\nthree\n"

(* ── let mut + DoAssign reassignment ─────────────────────────────────────── *)

let t_let_mut = assert_output
  {|main : <IO> Unit
main =
  do
    let mut x = 0
    x = x + 1
    x = x + 1
    println x
|}
  "2\n"

(* ── Runtime error: non-exhaustive match ─────────────────────────────────── *)

let t_runtime_err = assert_run_err
  {|f n =
  match n
    1 => "one"
    2 => "two"

main : <IO> Unit
main = println (f 99)
|}

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () = Alcotest.run "Run"
  [("run", [
    "hello world",   `Quick, t_hello;
    "factorial",     `Quick, t_factorial;
    "adt match",     `Quick, t_adt_match;
    "multi print",   `Quick, t_multi_print;
    "let mut",       `Quick, t_let_mut;
    "runtime error", `Quick, t_runtime_err;
  ])]
