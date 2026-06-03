(* dev/lextok.ml — dump the OCaml reference lexer's token stream for a file.
   Usage: ./_build/default/dev/lextok.exe <file.mdk>
   Prints one token per line in the canonical `Lexer.token_to_string` form —
   the same format selfhost/lex_main.mdk produces — so the two can be diffed
   to validate the self-hosted lexer against the reference on real source. *)

open Medaka_lib

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let buf = Bytes.create n in
  really_input ic buf 0 n;
  close_in ic;
  Bytes.to_string buf

let () =
  if Array.length Sys.argv < 2 then (prerr_endline "usage: lextok <file>"; exit 2);
  let src = read_file Sys.argv.(1) in
  (* No trailing newline — matches selfhost/lex_main.mdk's putStr output. *)
  print_string (String.concat "\n" (Lexer.tokenize_string src))
