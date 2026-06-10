(* dev/print_probe.ml — the OCaml printer oracle for the self-hosted
   selfhost/printer.mdk port.  Parses a file and emits
   [Printer.program_to_string] (the AST→source core, WITHOUT the
   comment-interleaving [format_program] path), so it can be diffed
   byte-for-byte against `medaka run selfhost/printer_main.mdk <file>`.
   Usage: print_probe <file.mdk> *)

open Medaka_lib

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let buf = Bytes.create n in
  really_input ic buf 0 n;
  close_in ic;
  Bytes.to_string buf

let () =
  let path = Sys.argv.(1) in
  let src = read_file path in
  Lexer.reset ();
  let lb = Lexing.from_string src in
  let prog =
    try Parser.program Lexer.token lb
    with Parser.Error ->
      let p = lb.Lexing.lex_curr_p in
      failwith (Printf.sprintf "parse error %d:%d" p.Lexing.pos_lnum
        (p.Lexing.pos_cnum - p.Lexing.pos_bol))
  in
  print_string (Printer.program_to_string prog)
