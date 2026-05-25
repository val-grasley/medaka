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

(* Check whether a program has any DUse declarations *)
let has_use_decls prog =
  List.exists (function Medaka_lib.Ast.DUse _ -> true | _ -> false) prog

let () =
  let mode, filename = match Sys.argv with
    | [| _; "repl" |] | [| _ |] -> Medaka_lib.Repl.run (); exit 0
    | [| _; "check"; file |] -> `Check, file
    | [| _; "run";   file |] -> `Run,   file
    | [| _; file |]           -> `Run,   file
    | _ -> print_endline "Usage: medaka [check|run|repl] <file.mdk>"; exit 1
  in
  let project_dir = Filename.dirname filename in

  (* Single-file fast path: no use declarations → bypass loader *)
  let source = read_file filename in
  let lexbuf = Lexing.from_string source in
  lexbuf.Lexing.lex_curr_p <- { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = filename };
  Medaka_lib.Lexer.reset ();
  let root_program =
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

  if not (has_use_decls root_program) then begin
    (* ── Single-file mode (legacy) ── *)
    let resolve_errs = Medaka_lib.Resolve.resolve_program root_program in
    if resolve_errs <> [] then begin
      List.iter (fun (err, loc_opt) ->
        Printf.eprintf "%s: %s\n" (pp_loc loc_opt) (Medaka_lib.Resolve.pp_error err);
        show_snippet source loc_opt
      ) resolve_errs;
      exit 1
    end;
    (try
      let (env, warnings) = Medaka_lib.Typecheck.check_program root_program in
      List.iter (fun w -> Printf.eprintf "%s\n" w) warnings;
      (match mode with
       | `Check ->
         Printf.printf "OK — %d bindings\n" (List.length env)
       | `Run ->
         (try
           let top_env = Medaka_lib.Eval.eval_program root_program in
           if not (List.mem_assoc "main" top_env) then begin
             Printf.eprintf "error: program has no 'main' binding\n"; exit 1
           end
         with Medaka_lib.Eval.Eval_error (msg, loc_opt) ->
           Printf.eprintf "%s: panic: %s\n" (pp_loc loc_opt) msg;
           show_snippet source loc_opt;
           exit 1))
    with Medaka_lib.Typecheck.Type_error (e, loc_opt) ->
      Printf.eprintf "%s: %s\n" (pp_loc loc_opt) (Medaka_lib.Typecheck.pp_error e);
      show_snippet source loc_opt;
      exit 1)
  end else begin
    (* ── Multi-file mode ── *)
    let modules =
      (try Medaka_lib.Loader.load_program filename project_dir
       with
       | Medaka_lib.Loader.LoadError (Medaka_lib.Loader.FileNotFound f) ->
         Printf.eprintf "error: file not found: %s\n" f; exit 1
       | Medaka_lib.Loader.LoadError (Medaka_lib.Loader.CyclicDependency cycle) ->
         Printf.eprintf "error: cyclic dependency: %s\n"
           (String.concat " → " cycle); exit 1
       | Medaka_lib.Loader.LoadError (Medaka_lib.Loader.UnknownModule m) ->
         Printf.eprintf "error: unknown module: %s\n" m; exit 1
       | Failure msg ->
         Printf.eprintf "error: %s\n" msg; exit 1)
    in

    (* Resolve all modules in dependency order *)
    let resolve_exports = ref [] in
    List.iter (fun (mod_id, file_path, prog) ->
      let file_source =
        if file_path = filename then source
        else (try read_file file_path
              with Sys_error _ -> "")
      in
      let (exports, errs) =
        Medaka_lib.Resolve.resolve_module !resolve_exports mod_id prog
      in
      if errs <> [] then begin
        List.iter (fun (err, loc_opt) ->
          Printf.eprintf "%s: %s\n" (pp_loc loc_opt) (Medaka_lib.Resolve.pp_error err);
          show_snippet file_source loc_opt
        ) errs;
        exit 1
      end;
      resolve_exports := exports :: !resolve_exports
    ) modules;

    (* Typecheck all modules in dependency order *)
    let type_exports = ref [] in
    let final_schemes = ref [] in
    let all_warnings = ref [] in
    List.iter (fun (mod_id, _file_path, prog) ->
      (try
        let (te, schemes, warnings) =
          Medaka_lib.Typecheck.typecheck_module !type_exports mod_id prog
        in
        type_exports := te :: !type_exports;
        final_schemes := schemes;
        all_warnings := !all_warnings @ warnings
       with Medaka_lib.Typecheck.Type_error (e, loc_opt) ->
         Printf.eprintf "%s: %s\n" (pp_loc loc_opt) (Medaka_lib.Typecheck.pp_error e);
         show_snippet source loc_opt;
         exit 1)
    ) modules;
    List.iter (fun w -> Printf.eprintf "%s\n" w) !all_warnings;

    (match mode with
     | `Check ->
       Printf.printf "OK — %d bindings\n" (List.length !final_schemes)
     | `Run ->
       (* Evaluate all modules; later modules' eval envs shadow earlier ones *)
       let combined_program = List.concat_map (fun (_, _, prog) -> prog) modules in
       (try
         let top_env = Medaka_lib.Eval.eval_program combined_program in
         if not (List.mem_assoc "main" top_env) then begin
           Printf.eprintf "error: program has no 'main' binding\n"; exit 1
         end
       with Medaka_lib.Eval.Eval_error (msg, loc_opt) ->
         Printf.eprintf "%s: panic: %s\n" (pp_loc loc_opt) msg;
         show_snippet source loc_opt;
         exit 1))
  end
