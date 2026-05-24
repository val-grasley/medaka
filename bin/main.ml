let read_file filename =
  let ic = open_in filename in
  let n = in_channel_length ic in
  let s = Bytes.create n in
  really_input ic s 0 n;
  close_in ic;
  Bytes.to_string s

let pp_loc = function
  | None   -> "<unknown location>"
  | Some l ->
    Printf.sprintf "%s:%d:%d" l.Medaka_lib.Ast.file l.Medaka_lib.Ast.line l.Medaka_lib.Ast.col

let show_snippet source loc_opt =
  match loc_opt with
  | None -> ()
  | Some l ->
    let lines = String.split_on_char '\n' source in
    (match List.nth_opt lines (l.Medaka_lib.Ast.line - 1) with
     | None -> ()
     | Some text ->
       Printf.eprintf "  |\n%d | %s\n  | %s^\n"
         l.Medaka_lib.Ast.line text
         (String.make l.Medaka_lib.Ast.col ' '))

let () =
  let filename =
    if Array.length Sys.argv > 1 then Sys.argv.(1)
    else (print_endline "Usage: medaka <file.mdk>"; exit 1)
  in
  let source = read_file filename in
  let lexbuf = Lexing.from_string source in
  lexbuf.Lexing.lex_curr_p <- { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = filename };
  Medaka_lib.Lexer.reset ();
  let program =
    (try Medaka_lib.Parser.program Medaka_lib.Lexer.token lexbuf
     with
     | Failure msg ->
       Printf.eprintf "Error: %s\n" msg; exit 1
     | Medaka_lib.Parser.Error ->
       let pos = lexbuf.Lexing.lex_curr_p in
       Printf.eprintf "%s:%d:%d: Parse error\n"
         pos.Lexing.pos_fname pos.Lexing.pos_lnum
         (pos.Lexing.pos_cnum - pos.Lexing.pos_bol);
       exit 1)
  in
  let resolve_errs = Medaka_lib.Resolve.resolve_program program in
  if resolve_errs <> [] then begin
    List.iter (fun (err, loc_opt) ->
      Printf.eprintf "%s: %s\n" (pp_loc loc_opt) (Medaka_lib.Resolve.pp_error err);
      show_snippet source loc_opt
    ) resolve_errs;
    exit 1
  end;
  (try
    let (env, warnings) = Medaka_lib.Typecheck.check_program program in
    List.iter (fun w -> Printf.eprintf "%s\n" w) warnings;
    Printf.printf "OK — %d bindings\n" (List.length env)
  with Medaka_lib.Typecheck.Type_error (e, loc_opt) ->
    Printf.eprintf "%s: %s\n" (pp_loc loc_opt) (Medaka_lib.Typecheck.pp_error e);
    show_snippet source loc_opt;
    exit 1)
