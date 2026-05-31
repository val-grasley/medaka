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

let print_usage () =
  print_endline {|medaka — language for thinking out loud

Usage:
  medaka                    Start the REPL.
  medaka repl               Start the REPL.
  medaka run <file.mdk>     Type-check and run a program.
  medaka check <file.mdk>   Type-check without running.
  medaka test [file.mdk]    Run doctests + prop tests.
  medaka bench [file.mdk]   Run bench declarations.
  medaka fmt [paths...]     Format .mdk files in place (or --check).
  medaka new <name>         Scaffold a new project directory.
  medaka lsp                Run the language server over stdio.
  medaka help               Show this message.

Run inside a project (medaka.toml) and the file argument may be
omitted: medaka run / check / test will use the [package].entry.|}

let () =
  (* Permissive subcommand match: tolerate trailing args from clients
     that pass --stdio or similar flags. *)
  let argv = Sys.argv in
  let argc = Array.length argv in
  let has_sub s = argc >= 2 && argv.(1) = s in
  let is_help_flag () =
    argc >= 2
    && (argv.(1) = "help" || argv.(1) = "--help" || argv.(1) = "-h")
  in
  if is_help_flag () then begin print_usage (); exit 0 end;
  if argc = 1 || has_sub "repl" then begin
    Medaka_lib.Repl.run (); exit 0
  end;
  if has_sub "lsp" then begin
    Medaka_lib.Lsp_server.run (); exit 0
  end;
  if has_sub "fmt" then begin
    let rest = Array.sub argv 2 (argc - 2) in
    exit (Medaka_lib.Fmt.run rest)
  end;
  if has_sub "new" then begin
    let rest = Array.sub argv 2 (argc - 2) in
    exit (Medaka_lib.New_cmd.run rest)
  end;
  if has_sub "test" then begin
    let rest_list = Array.to_list (Array.sub argv 2 (argc - 2)) in
    let use_coverage     = List.mem "--coverage"         rest_list in
    let update_snapshots = List.mem "--update-snapshots" rest_list in
    let rest = Array.of_list
      (List.filter (fun s -> s <> "--coverage" && s <> "--update-snapshots") rest_list) in
    if use_coverage then Medaka_lib.Coverage.enable ();
    (* Configure snapshot state before any doctest or prop run. *)
    Medaka_lib.Eval.snapshot_update := update_snapshots;
    (let snap_root =
       if Array.length rest >= 1 then
         let probe = rest.(0) in
         (match Medaka_lib.Project_config.find_project_root probe with
          | Some r -> r | None -> Filename.dirname probe)
       else
         let cwd = Sys.getcwd () in
         let probe = Filename.concat cwd "_probe_.mdk" in
         (match Medaka_lib.Project_config.find_project_root probe with
          | Some r -> r | None -> cwd)
     in
     Medaka_lib.Eval.snapshot_dir := Filename.concat snap_root "snapshots");
    (* Run doctests (Phase 41) *)
    let doctest_ok = Medaka_lib.Test_cmd.run rest = 0 in
    (* Run prop tests (Phase 42) *)
    let filename =
      if Array.length rest >= 1 then rest.(0)
      else begin
        let cwd = Sys.getcwd () in
        let probe = Filename.concat cwd "_probe_.mdk" in
        match Medaka_lib.Project_config.find_project_root probe with
        | None ->
          Printf.eprintf "error: no file given and no medaka.toml found\n"; exit 1
        | Some root ->
          (match Medaka_lib.Project_config.load_from_dir root with
           | None ->
             Printf.eprintf "error: no entry in medaka.toml\n"; exit 1
           | Some cfg ->
             (match cfg.Medaka_lib.Project_config.entry with
              | Some e -> Filename.concat root e
              | None ->
                Printf.eprintf "error: workspace root has no [package] entry\n"; exit 1))
      end
    in
    let source = read_file filename in
    let lexbuf = Lexing.from_string source in
    lexbuf.Lexing.lex_curr_p <- { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = filename };
    Medaka_lib.Lexer.reset ();
    let program =
      (try Medaka_lib.Parser.program Medaka_lib.Lexer.token lexbuf
       with
       | Failure msg -> Printf.eprintf "Error: %s\n" msg; exit 1
       | Medaka_lib.Parser.Error ->
         let pos = lexbuf.Lexing.lex_curr_p in
         Printf.eprintf "%s:%d:%d: Parse error\n"
           pos.Lexing.pos_fname pos.Lexing.pos_lnum
           (pos.Lexing.pos_cnum - pos.Lexing.pos_bol);
         exit 1)
    in
    let program = Medaka_lib.Desugar.desugar_program program in
    let resolve_errs = Medaka_lib.Resolve.resolve_program program in
    if resolve_errs <> [] then begin
      List.iter (fun (err, loc_opt) ->
        Printf.eprintf "%s: %s\n" (pp_loc loc_opt) (Medaka_lib.Resolve.pp_error err);
        show_snippet source loc_opt
      ) resolve_errs;
      exit 1
    end;
    let program = Medaka_lib.Method_marker.mark_with_prelude program in
    (try
       let (_env, warnings) = Medaka_lib.Typecheck.check_program program in
       List.iter (fun w -> Printf.eprintf "%s\n" w) warnings
     with Medaka_lib.Typecheck.Type_error (e, loc_opt) ->
       Printf.eprintf "%s: %s\n" (pp_loc loc_opt) (Medaka_lib.Typecheck.pp_error e);
       show_snippet source loc_opt;
       exit 1);
    let program = Medaka_lib.Dict_pass.run program in  (* Phase 69.x: dict params *)
    let prop_ok =
      (try
         let eval_env = Medaka_lib.Eval.eval_program program in
         Medaka_lib.Prop_runner.run_all eval_env program
       with Medaka_lib.Eval.Eval_error (msg, loc_opt) ->
         Printf.eprintf "%s: panic: %s\n" (pp_loc loc_opt) msg;
         show_snippet source loc_opt;
         exit 1)
    in
    if use_coverage then begin
      let exec_lines = Medaka_lib.Coverage.collect_executable program in
      Medaka_lib.Coverage.pp_report exec_lines
    end;
    exit (if doctest_ok && prop_ok then 0 else 1)
  end;
  if has_sub "bench" then begin
    let filename =
      if argc >= 3 then argv.(2)
      else begin
        let cwd = Sys.getcwd () in
        let probe = Filename.concat cwd "_probe_.mdk" in
        match Medaka_lib.Project_config.find_project_root probe with
        | None ->
          Printf.eprintf "error: no file given and no medaka.toml found\n"; exit 1
        | Some root ->
          (match Medaka_lib.Project_config.load_from_dir root with
           | None ->
             Printf.eprintf "error: no entry in medaka.toml\n"; exit 1
           | Some cfg ->
             (match cfg.Medaka_lib.Project_config.entry with
              | Some e -> Filename.concat root e
              | None ->
                Printf.eprintf "error: workspace root has no [package] entry\n"; exit 1))
      end
    in
    let source = read_file filename in
    let lexbuf = Lexing.from_string source in
    lexbuf.Lexing.lex_curr_p <- { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = filename };
    Medaka_lib.Lexer.reset ();
    let program =
      (try Medaka_lib.Parser.program Medaka_lib.Lexer.token lexbuf
       with
       | Failure msg -> Printf.eprintf "Error: %s\n" msg; exit 1
       | Medaka_lib.Parser.Error ->
         let pos = lexbuf.Lexing.lex_curr_p in
         Printf.eprintf "%s:%d:%d: Parse error\n"
           pos.Lexing.pos_fname pos.Lexing.pos_lnum
           (pos.Lexing.pos_cnum - pos.Lexing.pos_bol);
         exit 1)
    in
    let program = Medaka_lib.Desugar.desugar_program program in
    let resolve_errs = Medaka_lib.Resolve.resolve_program program in
    if resolve_errs <> [] then begin
      List.iter (fun (err, loc_opt) ->
        Printf.eprintf "%s: %s\n" (pp_loc loc_opt) (Medaka_lib.Resolve.pp_error err);
        show_snippet source loc_opt
      ) resolve_errs;
      exit 1
    end;
    let program = Medaka_lib.Method_marker.mark_with_prelude program in
    (try
       let (_env, warnings) = Medaka_lib.Typecheck.check_program program in
       List.iter (fun w -> Printf.eprintf "%s\n" w) warnings
     with Medaka_lib.Typecheck.Type_error (e, loc_opt) ->
       Printf.eprintf "%s: %s\n" (pp_loc loc_opt) (Medaka_lib.Typecheck.pp_error e);
       show_snippet source loc_opt;
       exit 1);
    let program = Medaka_lib.Dict_pass.run program in  (* Phase 69.x: dict params *)
    (try
       let eval_env = Medaka_lib.Eval.eval_program program in
       Medaka_lib.Bench_runner.run_all eval_env program
     with Medaka_lib.Eval.Eval_error (msg, loc_opt) ->
       Printf.eprintf "%s: panic: %s\n" (pp_loc loc_opt) msg;
       show_snippet source loc_opt;
       exit 1);
    exit 0
  end;
  (* Resolve a zero-arg `run`/`check` against `medaka.toml` in the cwd
     (walking up).  Returns the entry file path, or None if no config
     is found.  Raises WS_root when the nearest config is a workspace-only
     root (no [package] entry). *)
  let module WS = struct exception Root of string end in
  let entry_from_cwd_config () =
    let cwd = Sys.getcwd () in
    let probe = Filename.concat cwd "_probe_.mdk" in
    match Medaka_lib.Project_config.find_project_root probe with
    | None -> None
    | Some root ->
      (match Medaka_lib.Project_config.load_from_dir root with
       | None -> None
       | Some cfg ->
         match cfg.Medaka_lib.Project_config.entry with
         | Some e -> Some (Filename.concat root e)
         | None ->
           if cfg.Medaka_lib.Project_config.workspace <> None then
             raise (WS.Root root)
           else None)
  in
  (* Run type-check on all members of a workspace and report errors per-member.
     Returns true if all members passed. *)
  let workspace_check root =
    let members =
      try Medaka_lib.Project_config.load_workspace_members root
      with Medaka_lib.Project_config.Parse_error msg ->
        Printf.eprintf "error: workspace config: %s\n" msg; exit 1
    in
    let member_roots = List.map fst members in
    let all_ok = ref true in
    List.iter (fun (member_dir, member_cfg) ->
      match member_cfg.Medaka_lib.Project_config.entry with
      | None ->
        Printf.eprintf "warning: member %s has no [package], skipping\n" member_dir
      | Some entry ->
        let entry_file = Filename.concat member_dir entry in
        let msource =
          (try read_file entry_file
           with Sys_error msg ->
             Printf.eprintf "error: %s\n" msg; all_ok := false; "")
        in
        if msource = "" then ()
        else begin
          let lexbuf = Lexing.from_string msource in
          lexbuf.Lexing.lex_curr_p <-
            { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = entry_file };
          Medaka_lib.Lexer.reset ();
          let prog =
            (try Medaka_lib.Parser.program Medaka_lib.Lexer.token lexbuf
             with
             | Failure msg ->
               Printf.eprintf "%s: %s\n" entry_file msg; all_ok := false; []
             | Medaka_lib.Parser.Error ->
               let pos = lexbuf.Lexing.lex_curr_p in
               Printf.eprintf "%s:%d:%d: Parse error\n"
                 pos.Lexing.pos_fname pos.Lexing.pos_lnum
                 (pos.Lexing.pos_cnum - pos.Lexing.pos_bol);
               all_ok := false; [])
          in
          if prog = [] then ()
          else begin
            let modules =
              (try Medaka_lib.Loader.load_program entry_file member_roots
               with
               | Medaka_lib.Loader.LoadError
                   (Medaka_lib.Loader.FileNotFound f) ->
                 Printf.eprintf "error: file not found: %s\n" f;
                 all_ok := false; []
               | Medaka_lib.Loader.LoadError
                   (Medaka_lib.Loader.CyclicDependency cycle) ->
                 Printf.eprintf "error: cyclic dependency: %s\n"
                   (String.concat " → " cycle);
                 all_ok := false; []
               | Medaka_lib.Loader.LoadError
                   (Medaka_lib.Loader.UnknownModule { mod_id; _ }) ->
                 Printf.eprintf "error: unknown module: %s\n" mod_id;
                 all_ok := false; []
               | Medaka_lib.Loader.LoadError
                   (Medaka_lib.Loader.AmbiguousModule { mod_id; found_in }) ->
                 Printf.eprintf "error: ambiguous module '%s' found in: %s\n"
                   mod_id (String.concat ", " found_in);
                 all_ok := false; []
               | Medaka_lib.Loader.LoadError
                   (Medaka_lib.Loader.ParseError { file; line; col; message }) ->
                 Printf.eprintf "%s:%d:%d: %s\n" file line col message;
                 all_ok := false; []
               | Failure msg ->
                 Printf.eprintf "error: %s\n" msg; all_ok := false; [])
            in
            if modules = [] then ()
            else begin
              let modules = List.map (fun (mid, fp, p) ->
                (mid, fp, Medaka_lib.Desugar.desugar_program p)) modules in
              let resolve_exports = ref [] in
              let resolve_ok = ref true in
              List.iter (fun (mod_id, file_path, p) ->
                let fsrc =
                  if file_path = entry_file then msource
                  else (try read_file file_path with Sys_error _ -> "")
                in
                let (exports, errs) =
                  Medaka_lib.Resolve.resolve_module !resolve_exports mod_id p
                in
                List.iter (fun (err, loc_opt) ->
                  Printf.eprintf "%s: %s\n"
                    (pp_loc loc_opt) (Medaka_lib.Resolve.pp_error err);
                  show_snippet fsrc loc_opt;
                  resolve_ok := false; all_ok := false
                ) errs;
                resolve_exports := exports :: !resolve_exports
              ) modules;
              if !resolve_ok then begin
                let type_exports = ref [] in
                List.iter (fun (mod_id, _fp, p) ->
                  (try
                    let (te, _schemes, warnings) =
                      Medaka_lib.Typecheck.typecheck_module !type_exports mod_id p
                    in
                    type_exports := te :: !type_exports;
                    List.iter (fun w -> Printf.eprintf "%s\n" w) warnings
                   with Medaka_lib.Typecheck.Type_error (e, loc_opt) ->
                     Printf.eprintf "%s: %s\n"
                       (pp_loc loc_opt) (Medaka_lib.Typecheck.pp_error e);
                     show_snippet msource loc_opt;
                     all_ok := false)
                ) modules
              end
            end
          end
        end
    ) members;
    !all_ok
  in
  let mode, filename =
    if has_sub "check" && argc >= 3 then `Check, argv.(2)
    else if has_sub "run" && argc >= 3 then `Run, argv.(2)
    else if (has_sub "check" || has_sub "run") && argc = 2 then begin
      match entry_from_cwd_config () with
      | Some f -> (if has_sub "check" then `Check else `Run), f
      | None ->
        Printf.eprintf "error: no file given and no medaka.toml found\n"; exit 1
      | exception WS.Root root when has_sub "check" ->
        exit (if workspace_check root then 0 else 1)
      | exception WS.Root _ ->
        Printf.eprintf "error: workspace root has no [package] entry; \
cd into a member or specify a file\n"; exit 1
    end
    else if argc = 2 then `Run, argv.(1)
    else begin
      print_usage (); exit 1
    end
  in
  let project_dir =
    match Medaka_lib.Project_config.find_project_root filename with
    | Some d -> d
    | None   -> Filename.dirname filename
  in

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

  let root_program = Medaka_lib.Desugar.desugar_program root_program in

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
    let root_program = Medaka_lib.Method_marker.mark_with_prelude root_program in
    (try
      let (env, warnings) = Medaka_lib.Typecheck.check_program root_program in
      List.iter (fun w -> Printf.eprintf "%s\n" w) warnings;
      (match mode with
       | `Check ->
         Printf.printf "OK — %d bindings\n" (List.length env)
       | `Run ->
         (try
           (* Phase 69.x: insert dictionary parameters on constrained functions
              (their refs were filled in place by check_program above) so eval
              routes polymorphic methods by the dictionaries EDictApp passes. *)
           let root_program = Medaka_lib.Dict_pass.run root_program in
           let top_env = Medaka_lib.Eval.eval_program root_program in
           if not (List.mem_assoc "main" top_env) then begin
             Printf.eprintf "error: program has no 'main' binding\n"; exit 1
           end
         with
         | Medaka_lib.Eval.Eval_error (msg, loc_opt) ->
           Printf.eprintf "%s: panic: %s\n" (pp_loc loc_opt) msg;
           show_snippet source loc_opt;
           exit 1
         | Medaka_lib.Eval.Impl_no_match ->
           Printf.eprintf "%s: panic: non-exhaustive match\n" (pp_loc !Medaka_lib.Eval.current_loc);
           exit 1))
    with Medaka_lib.Typecheck.Type_error (e, loc_opt) ->
      Printf.eprintf "%s: %s\n" (pp_loc loc_opt) (Medaka_lib.Typecheck.pp_error e);
      show_snippet source loc_opt;
      exit 1)
  end else begin
    (* ── Multi-file mode ── *)
    let modules =
      (try Medaka_lib.Loader.load_program filename [project_dir]
       with
       | Medaka_lib.Loader.LoadError (Medaka_lib.Loader.FileNotFound f) ->
         Printf.eprintf "error: file not found: %s\n" f; exit 1
       | Medaka_lib.Loader.LoadError (Medaka_lib.Loader.CyclicDependency cycle) ->
         Printf.eprintf "error: cyclic dependency: %s\n"
           (String.concat " → " cycle); exit 1
       | Medaka_lib.Loader.LoadError (Medaka_lib.Loader.UnknownModule { mod_id; _ }) ->
         Printf.eprintf "error: unknown module: %s\n" mod_id; exit 1
       | Medaka_lib.Loader.LoadError
           (Medaka_lib.Loader.AmbiguousModule { mod_id; found_in }) ->
         Printf.eprintf "error: ambiguous module '%s' found in: %s\n"
           mod_id (String.concat ", " found_in); exit 1
       | Medaka_lib.Loader.LoadError
           (Medaka_lib.Loader.ParseError { file; line; col; message }) ->
         Printf.eprintf "%s:%d:%d: %s\n" file line col message; exit 1
       | Failure msg ->
         Printf.eprintf "error: %s\n" msg; exit 1)
    in
    let modules = List.map (fun (mid, fp, prog) ->
      (mid, fp, Medaka_lib.Desugar.desugar_program prog)
    ) modules in

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

    (* Phase 69: mark interface-method occurrences across every module (against
       the union of all modules' + the prelude's interface methods) so the
       typechecker can stamp each resolved impl and eval can route by it.  Runs
       after resolve — which only validates the bare names — and rebinds
       `modules` so both the typecheck loop and the concatenated eval program
       below consume the same marked trees. *)
    let method_names =
      Medaka_lib.Method_marker.interface_method_names
        (Medaka_lib.Prelude.program :: List.map (fun (_, _, p) -> p) modules)
    in
    (* Phase 69.x: constrained functions may be referenced across modules, so
       wrap occurrences against the union of every user module's constrained
       signatures (the prelude is excluded — its constrained fns stay arg-tag). *)
    let constrained_names =
      Medaka_lib.Method_marker.constrained_fn_names
        (List.map (fun (_, _, p) -> p) modules)
    in
    let modules = List.map (fun (mid, fp, prog) ->
      (mid, fp, Medaka_lib.Method_marker.mark_program method_names constrained_names prog)
    ) modules in

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
       (* Phase 69.x: insert dictionary parameters on constrained functions
          across all modules (EDictApp refs were filled by typecheck_module). *)
       let combined_program = Medaka_lib.Dict_pass.run combined_program in
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
