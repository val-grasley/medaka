(* dev/positions_dump.ml — dump the OCaml parser/lexer POSITION side channels
   (lib/parser_state.ml) for a file: the reference the self-hosted parser's
   position channel is validated against (selfhost/positions_main.mdk via
   test/diff_selfhost_positions.sh).
   Usage: positions_dump <file.mdk>

   This is the prerequisite metadata `medaka fmt`'s comment-interleaving engine
   (lib/printer.ml `format_program`) buckets comments against.  Three channels:
     decls    — one per top-level decl, "<line>:<end_line>"
     variants — start line of each `data` variant, flat across the file
     lastline — `last_content_line` (the line where the last decl's last
                non-trivia token sat)

   Parsing goes through the SAME `tracking_token` wrapper `lib/fmt.ml` uses, so
   `last_content_line` (and the per-decl `end_line` fixup it drives) match what
   `medaka fmt` sees.  Output format (consumed by the diff harness):

     === DECLS ===
     <line>:<end_line>
     ...
     === VARIANTS ===
     <line>
     ...
     === LASTLINE ===
     <n>
*)

open Medaka_lib

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let buf = Bytes.create n in
  really_input ic buf 0 n;
  close_in ic;
  Bytes.to_string buf

(* Mirror lib/fmt.ml's tracking_token: snapshot the last content token's line
   into Parser_state.last_content_line at each NEWLINE boundary. *)
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

let () =
  let path = Sys.argv.(1) in
  let src = read_file path in
  Lexer.reset ();
  running_content_line := 0;
  let lb = Lexing.from_string src in
  let _prog =
    try Parser.program tracking_token lb
    with Parser.Error ->
      let p = lb.Lexing.lex_curr_p in
      failwith (Printf.sprintf "parse error %d:%d" p.Lexing.pos_lnum
        (p.Lexing.pos_cnum - p.Lexing.pos_bol))
  in
  let decl_locs = Parser_state.take_decl_positions () in
  let vlines = Parser_state.take_variant_lines () in
  let last = !Parser_state.last_content_line in
  let buf = Buffer.create 256 in
  Buffer.add_string buf "=== DECLS ===\n";
  List.iter (fun (l : Ast.loc) ->
    Buffer.add_string buf (Printf.sprintf "%d:%d\n" l.line l.end_line))
    decl_locs;
  Buffer.add_string buf "=== VARIANTS ===\n";
  List.iter (fun ln -> Buffer.add_string buf (Printf.sprintf "%d\n" ln)) vlines;
  Buffer.add_string buf "=== LASTLINE ===\n";
  Buffer.add_string buf (Printf.sprintf "%d\n" last);
  print_string (Buffer.contents buf)
