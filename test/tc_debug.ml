(* Quick type-check probe — not part of the test suite.
   Edit src below and run:  dune exec test/tc_debug.exe *)

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

let () =
  let src = {|
f x =
  do
    y <- x
    pure (y + 1)
|} in
  match check_program (parse src) with
  | (result, warnings) ->
    List.iter (fun w -> Printf.printf "Warning: %s\n" w) warnings;
    List.iter (fun (n, s) ->
      Printf.printf "%s : %s\n" n (pp_scheme s)) result
  | exception Type_error (e, _) ->
    Printf.printf "Error: %s\n" (pp_error e)
