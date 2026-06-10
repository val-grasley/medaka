(* dev/comment_dump.ml — dump the OCaml lexer's comment side channel for a
   file, the reference the self-hosted lexer's comment channel is validated
   against (selfhost/lex_comments_main.mdk via test/diff_selfhost_comments.sh).
   Usage: comment_dump <file.mdk>

   Format: one comment per line, "<line>:<col>:<text>" where <line> is 1-based,
   <col> 0-based, and <text> the full lexeme (`--…` / `{- … -}`, delimiters
   included).  Newlines inside a block comment are escaped to `\n` so each
   comment stays on one line — matching the selfhost driver's `escNl`.

   `Lexer.tokenize_string` resets the comment accumulator and lexes to EOF,
   populating `Lexer.comments`; `Lexer.take_comments ()` then returns them in
   source order (it reverses the accumulator). *)

open Medaka_lib

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let buf = Bytes.create n in
  really_input ic buf 0 n;
  close_in ic;
  Bytes.to_string buf

let esc_nl s =
  let b = Buffer.create (String.length s) in
  String.iter (fun c -> if c = '\n' then Buffer.add_string b "\\n"
                        else Buffer.add_char b c) s;
  Buffer.contents b

let () =
  let path = Sys.argv.(1) in
  let src = read_file path in
  let _ = Lexer.tokenize_string src in
  let comments = Lexer.take_comments () in
  let line (c : Lexer.comment) =
    Printf.sprintf "%d:%d:%s" c.c_line c.c_col (esc_nl c.c_text)
  in
  print_string (String.concat "\n" (List.map line comments))
