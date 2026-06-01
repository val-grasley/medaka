(* Dev probe: dump Printer.format_program output WITHOUT the round-trip
   safety check, and bisect which top-level decl's reprint differs from the
   original after a parse/reprint/reparse cycle. *)

open Medaka_lib

let running_content_line = ref 0

let tracking_token lexbuf =
  let tok = Lexer.token lexbuf in
  (match tok with
   | Parser.NEWLINE ->
     Parser_state.last_content_line := !running_content_line
   | Parser.INDENT | Parser.DEDENT -> ()
   | _ ->
     running_content_line := lexbuf.Lexing.lex_curr_p.Lexing.pos_lnum);
  tok

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = Bytes.create n in
  really_input ic s 0 n;
  close_in ic;
  Bytes.to_string s

let parse ~track src =
  Lexer.reset ();
  running_content_line := 0;
  let lexbuf = Lexing.from_string src in
  let tok = if track then tracking_token else Lexer.token in
  Parser.program tok lexbuf

let () =
  let path = Sys.argv.(1) in
  let src = read_file path in
  let ast = parse ~track:true src in
  let decl_locs = Parser_state.take_decl_positions () in
  let comments = Lexer.take_comments () in
  let formatted = Printer.format_program ast decl_locs comments in
  (if Array.length Sys.argv > 2 && Sys.argv.(2) = "--print" then begin
     print_string formatted; exit 0
   end);
  let ast2 = parse ~track:false formatted in
  let a = Ast.strip_locs_program ast in
  let b = Ast.strip_locs_program ast2 in
  Printf.printf "orig decls: %d, reparsed decls: %d\n"
    (List.length a) (List.length b);
  let src_of_decl d = Printer.format_program [d] [] [] in
  let rec loop i xs ys =
    match xs, ys with
    | [], [] -> Printf.printf "no decl mismatch found\n"
    | x :: xs', y :: ys' ->
      if x <> y then begin
        Printf.printf "FIRST MISMATCH at decl index %d\n" i;
        Printf.printf "=== ORIG (reprinted) ===\n%s\n" (src_of_decl x);
        Printf.printf "=== REPARSED (reprinted) ===\n%s\n" (src_of_decl y)
      end else loop (i + 1) xs' ys'
    | _ -> Printf.printf "length mismatch at index %d\n" i
  in
  loop 0 a b
