(* `medaka fmt` — code formatter.
   Reads a Medaka source file, parses it, and re-prints it through the
   comment-preserving pretty printer.  Supports in-place rewrite (default),
   `--check` (report-only with nonzero exit if any file is unformatted),
   `--stdout` (print to stdout), and recursive directory walking. *)

type mode = Write | Check | Stdout

type args = {
  mode : mode;
  paths : string list;
}

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = Bytes.create n in
  really_input ic s 0 n;
  close_in ic;
  Bytes.to_string s

let write_file_atomic path contents =
  let tmp = path ^ ".medaka-fmt.tmp" in
  let oc = open_out tmp in
  output_string oc contents;
  close_out oc;
  Sys.rename tmp path

(* Token wrapper that snapshots the line of the last content token into
   `Parser_state.last_content_line`.  The parser is LR(1), so a semantic
   action fires only after one token of lookahead has already been read;
   if we updated `last_content_line` directly on every content token, the
   value seen by the action would be from the lookahead (one decl too
   far).  Instead we keep a running line and only commit it into
   `last_content_line` when a NEWLINE is observed - the boundary that
   separates a declaration from the next decl's lookahead token. *)
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

(* Format a source string.  Returns the formatted output on success;
   raises [Failure msg] on parse error or round-trip safety failure. *)
let format_source ~filename src =
  Lexer.reset ();
  running_content_line := 0;
  let lexbuf = Lexing.from_string src in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = filename };
  let ast =
    try Parser.program tracking_token lexbuf
    with Parser.Error ->
      let pos = lexbuf.Lexing.lex_curr_p in
      failwith (Printf.sprintf "%s:%d:%d: parse error"
                  filename pos.Lexing.pos_lnum
                  (pos.Lexing.pos_cnum - pos.Lexing.pos_bol))
  in
  let decl_locs = Parser_state.take_decl_positions () in
  let comments = Lexer.take_comments () in
  let formatted = Printer.format_program ast decl_locs comments in
  (* Round-trip safety net: re-parse the formatted output and require it
     to produce a structurally equivalent AST (ignoring locations).  This
     guards against printer bugs that would otherwise silently corrupt
     the file. *)
  Lexer.reset ();
  let lexbuf2 = Lexing.from_string formatted in
  lexbuf2.Lexing.lex_curr_p <-
    { lexbuf2.Lexing.lex_curr_p with Lexing.pos_fname = filename };
  let ast2 =
    try Parser.program Lexer.token lexbuf2
    with Parser.Error ->
      let pos = lexbuf2.Lexing.lex_curr_p in
      failwith (Printf.sprintf
                  "%s: formatter produced unparseable output (re-parse failed at %d:%d). \
                   This is a formatter bug; the file was not modified."
                  filename pos.Lexing.pos_lnum
                  (pos.Lexing.pos_cnum - pos.Lexing.pos_bol))
  in
  if Ast.strip_locs_program ast <> Ast.strip_locs_program ast2 then
    failwith (Printf.sprintf
                "%s: formatter changed the program's AST. \
                 This is a formatter bug; the file was not modified."
                filename);
  formatted

let has_mdk_ext path = Filename.check_suffix path ".mdk"

let rec collect_paths acc path =
  if Sys.is_directory path then
    let entries =
      try Sys.readdir path
      with Sys_error _ -> [||]
    in
    Array.sort compare entries;
    Array.fold_left (fun acc name ->
      let full = Filename.concat path name in
      collect_paths acc full
    ) acc entries
  else if has_mdk_ext path then path :: acc
  else acc

let collect_files paths =
  List.rev (List.fold_left collect_paths [] paths)

(* Process a single file.  Returns:
   - [`Ok unchanged]   — file already formatted
   - [`Ok changed]     — file was (or would be) reformatted
   - [`Error msg]      — parse error or round-trip failure *)
let process_file mode file =
  match read_file file with
  | exception Sys_error msg ->
    `Error (Printf.sprintf "%s: %s" file msg)
  | src ->
    match format_source ~filename:file src with
    | exception Failure msg -> `Error msg
    | formatted ->
      let changed = formatted <> src in
      (match mode with
       | Stdout ->
         print_string formatted;
         `Ok changed
       | Check ->
         `Ok changed
       | Write ->
         if changed then write_file_atomic file formatted;
         `Ok changed)

let parse_args argv =
  let mode = ref Write in
  let paths = ref [] in
  let i = ref 0 in
  let n = Array.length argv in
  while !i < n do
    (match argv.(!i) with
     | "--check"  -> mode := Check
     | "--stdout" -> mode := Stdout
     | "-w" | "--write" -> mode := Write
     | s when String.length s > 0 && s.[0] = '-' ->
       failwith (Printf.sprintf "unknown flag: %s" s)
     | s -> paths := s :: !paths);
    incr i
  done;
  { mode = !mode; paths = List.rev !paths }

let usage () =
  prerr_endline
    "Usage: medaka fmt [--check | --stdout | --write] <path>...\n\
    \  --check    Report files that need formatting; do not modify them. Exit 1 if any.\n\
    \  --stdout   Print formatted output to stdout (requires exactly one file).\n\
    \  --write    Rewrite each file in place (default).\n\
    \n\
    \  <path> may be a .mdk file or a directory (recursed for .mdk files)."

(* Entry point.  Returns the process exit code. *)
let run argv =
  let args =
    try parse_args argv
    with Failure msg ->
      Printf.eprintf "medaka fmt: %s\n" msg; usage (); exit 2
  in
  if args.paths = [] then begin
    usage (); exit 2
  end;
  let files = collect_files args.paths in
  if files = [] then begin
    Printf.eprintf "medaka fmt: no .mdk files found\n"; exit 2
  end;
  if args.mode = Stdout && List.length files <> 1 then begin
    Printf.eprintf "medaka fmt: --stdout requires exactly one file\n"; exit 2
  end;
  let unformatted = ref [] in
  let errors = ref 0 in
  List.iter (fun file ->
    match process_file args.mode file with
    | `Error msg ->
      incr errors;
      Printf.eprintf "%s\n" msg
    | `Ok changed ->
      if changed then unformatted := file :: !unformatted
  ) files;
  match args.mode with
  | Stdout -> if !errors > 0 then 1 else 0
  | Write  ->
    if !errors > 0 then 1 else 0
  | Check  ->
    if !errors > 0 then 1
    else if !unformatted <> [] then begin
      List.iter (fun f -> Printf.eprintf "would reformat: %s\n" f)
        (List.rev !unformatted);
      1
    end else 0
