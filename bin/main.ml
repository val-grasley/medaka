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

(* Desugar, reporting a Phase 99 do-block well-formedness error cleanly instead
   of crashing with an uncaught exception. *)
let desugar_or_die ?(source = "") program =
  try Medaka_lib.Desugar.desugar_program program
  with Medaka_lib.Desugar.Do_error (msg, loc_opt) ->
    Printf.eprintf "%s: %s\n" (pp_loc loc_opt) msg;
    (if source <> "" then show_snippet source loc_opt);
    exit 1

(* Check whether a program has any DUse declarations *)
let has_use_decls prog =
  List.exists (function Medaka_lib.Ast.DUse _ -> true | _ -> false) prog

let print_usage () =
  print_endline {|medaka — language for thinking out loud

Usage:
  medaka                    Start the REPL.
  medaka repl               Start the REPL.
  medaka run [--release] <file.mdk>   Type-check and run a program.
  medaka check [--json] <file.mdk>    Type-check without running.
  medaka test [file.mdk]    Run doctests + prop tests.
  medaka bench [file.mdk]   Run bench declarations.
  medaka doc [file.mdk]     Generate Markdown documentation.
  medaka fmt [paths...]     Format .mdk files in place (or --check).
  medaka new <name>         Scaffold a new project directory.
  medaka lsp                Run the language server over stdio.
  medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]
                            Verify a plugin's effect row against a policy.
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
    let program = desugar_or_die ~source program in
    (* The prop phase resolves/elaborates the file *single-file*, which cannot
       see sibling-module imports.  Props only actually run if the file declares
       any (`Prop_runner.run_all` short-circuits on none), so when there are no
       prop decls — and we are not collecting coverage, which needs the
       elaborated tree — skip the single-file pipeline entirely.  This lets an
       import-bearing file with doctests but no props (e.g. `stdlib/json.mdk`,
       which imports `list`/`string`) pass `medaka test` instead of failing at
       the single-file resolve on the imported names.  (An import-bearing file
       that *does* declare props still needs a multi-module prop path — tracked
       as a follow-up.) *)
    let has_props =
      List.exists (function Medaka_lib.Ast.DProp _ -> true | _ -> false) program
    in
    (* Single-file prop/coverage path: resolve + elaborate the target file alone.
       Used when the file has no sibling imports, and as the ≤1-module fallback. *)
    let run_single_file () =
      let resolve_errs = Medaka_lib.Resolve.resolve_program program in
      if resolve_errs <> [] then begin
        List.iter (fun (err, loc_opt) ->
          Printf.eprintf "%s: %s\n" (pp_loc loc_opt) (Medaka_lib.Resolve.pp_error err);
          show_snippet source loc_opt
        ) resolve_errs;
        exit 1
      end;
      (* Phase 84: two-pass elaboration (see Elaborate).  Prop/coverage keep the
         pre-dict-pass marked `program`; [combined] is the dict-passed eval tree. *)
      let (program, combined, _env, warnings) =
        (try Medaka_lib.Elaborate.elaborate program
         with Medaka_lib.Typecheck.Type_error (e, loc_opt) ->
           Printf.eprintf "%s: %s\n" (pp_loc loc_opt) (Medaka_lib.Typecheck.pp_error e);
           show_snippet source loc_opt;
           exit 1) in
      List.iter (fun w -> Printf.eprintf "%s\n" w) warnings;
      let ok =
        (try
           let eval_env = Medaka_lib.Eval.eval_program ~prelude:false combined in
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
      ok
    in
    let prop_ok =
      if (not use_coverage) && not has_props then true
      else if Medaka_lib.Doctest.has_use_decls program then begin
        (* Phase 126: import-bearing file — route the prop phase through the same
           multi-module loader doctests use, so props/coverage can see names
           imported from sibling modules (the single-file path can't). *)
        match
          (try Medaka_lib.Doctest.assemble_marked_modules filename
           with Failure msg -> Printf.eprintf "error: %s\n" msg; exit 1)
        with
        | None -> run_single_file ()           (* only prelude imports; fall back *)
        | Some (_, Some msg) ->                 (* deferred typecheck error *)
          Printf.eprintf "error: %s\n" msg; exit 1
        | Some (marked_modules, None) ->
          (* Full root env (local ∪ imports ∪ global): a prop body references
             imported names and prelude operators, and Prop_runner evaluates it
             against this single frame after eval returns. *)
          let eval_env = Medaka_lib.Eval.eval_modules_root_env marked_modules in
          (* Root module's marked (pre-dict-pass) decls — the right `program` arg
             for run_all (props + build_tydefs) and coverage, mirroring the
             single-file path.  Limitation: build_tydefs sees only the root's
             DData, so a prop generator needing an imported type won't find its
             constructors (same scope as the single-file path). *)
          let root_decls =
            match List.find_opt (fun (_, fp, _) -> fp = filename) marked_modules with
            | Some (_, _, p) -> p
            | None -> []
          in
          let ok =
            (try Medaka_lib.Prop_runner.run_all eval_env root_decls
             with Medaka_lib.Eval.Eval_error (msg, loc_opt) ->
               Printf.eprintf "%s: panic: %s\n" (pp_loc loc_opt) msg;
               show_snippet source loc_opt;
               exit 1)
          in
          if use_coverage then begin
            let exec_lines = Medaka_lib.Coverage.collect_executable root_decls in
            Medaka_lib.Coverage.pp_report exec_lines
          end;
          ok
      end
      else run_single_file ()
    in
    (* Run unit tests (Phase 127) *)
    let has_tests =
      List.exists (function Medaka_lib.Ast.DTest _ -> true | _ -> false) program
    in
    let test_ok =
      if not has_tests then true
      else begin
        (* Build __tests__ = [("n1", () => body1), …] and __test_run__ = runTests __tests__ *)
        let test_decls = List.filter_map (fun d ->
          match Medaka_lib.Ast.inner_decl d with
          | Medaka_lib.Ast.DTest { test_name; test_body; _ } -> Some (test_name, test_body)
          | _ -> None
        ) program in
        let synth_tests =
          Medaka_lib.Ast.DFunDef (false, "__tests__", [],
            Medaka_lib.Ast.EListLit (
              List.map (fun (test_name, test_body) ->
                Medaka_lib.Ast.ETuple [
                  Medaka_lib.Ast.ELit (Medaka_lib.Ast.LString test_name);
                  Medaka_lib.Ast.ELam ([Medaka_lib.Ast.PWild], test_body)
                ]
              ) test_decls
            )
          )
        in
        let synth_run =
          Medaka_lib.Ast.DFunDef (false, "__test_run__", [],
            Medaka_lib.Ast.EApp (Medaka_lib.Ast.EVar "runTests", Medaka_lib.Ast.EVar "__tests__"))
        in
        let inject fp prog =
          if fp = filename then prog @ [synth_tests; synth_run] else prog
        in
        match
          (try Medaka_lib.Doctest.assemble_marked_modules ~inject filename
           with Failure msg -> Printf.eprintf "error: %s\n" msg; exit 1)
        with
        | None ->
          Printf.eprintf "error: unit tests require 'import test.{runTests, …}' (no sibling module found)\n";
          false
        | Some (_, Some msg) ->
          Printf.eprintf "error: %s\n" msg; false
        | Some (marked_modules, None) ->
          let eval_env = Medaka_lib.Eval.eval_modules_root_env marked_modules in
          let base_frame = List.map (fun (k, v) -> (k, ref v)) eval_env in
          let env = [Medaka_lib.Eval.FTable (Medaka_lib.Eval.table_of_assoc base_frame)] in
          (try
            match Medaka_lib.Eval.eval env (Medaka_lib.Ast.EVar "__test_run__") with
            | Medaka_lib.Eval.VBool b -> b
            | _ -> Printf.eprintf "error: runTests did not return Bool\n"; false
           with Medaka_lib.Eval.Eval_error (msg, loc_opt) ->
             Printf.eprintf "%s: panic: %s\n" (pp_loc loc_opt) msg;
             show_snippet source loc_opt; false)
      end
    in
    exit (if doctest_ok && prop_ok && test_ok then 0 else 1)
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
    let program = desugar_or_die ~source program in
    let resolve_errs = Medaka_lib.Resolve.resolve_program program in
    if resolve_errs <> [] then begin
      List.iter (fun (err, loc_opt) ->
        Printf.eprintf "%s: %s\n" (pp_loc loc_opt) (Medaka_lib.Resolve.pp_error err);
        show_snippet source loc_opt
      ) resolve_errs;
      exit 1
    end;
    let (program, combined, _env, warnings) =
      (try Medaka_lib.Elaborate.elaborate program
       with Medaka_lib.Typecheck.Type_error (e, loc_opt) ->
         Printf.eprintf "%s: %s\n" (pp_loc loc_opt) (Medaka_lib.Typecheck.pp_error e);
         show_snippet source loc_opt;
         exit 1) in
    List.iter (fun w -> Printf.eprintf "%s\n" w) warnings;
    (try
       let eval_env = Medaka_lib.Eval.eval_program ~prelude:false combined in
       Medaka_lib.Bench_runner.run_all eval_env program
     with Medaka_lib.Eval.Eval_error (msg, loc_opt) ->
       Printf.eprintf "%s: panic: %s\n" (pp_loc loc_opt) msg;
       show_snippet source loc_opt;
       exit 1);
    exit 0
  end;
  if has_sub "doc" then begin
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
    (* Capture comment and decl-position side channels before any reset. *)
    let comments = Medaka_lib.Lexer.take_comments () in
    let positions = Medaka_lib.Parser_state.take_decl_positions () in
    (* Get inferred schemes via the single-file typecheck path.  On type errors
       we still produce docs — just without inferred types for failing names. *)
    let schemes =
      let desugared = desugar_or_die ~source program in
      match (try
               let marked = Medaka_lib.Method_marker.mark_with_prelude desugared in
               let (sc, _) = Medaka_lib.Typecheck.check_program marked in
               Some sc
             with _ -> None)
      with
      | Some sc -> sc
      | None    -> []
    in
    let module_name = Filename.basename (Filename.remove_extension filename) in
    let entries = Medaka_lib.Doc.extract_entries program positions schemes comments in
    print_string (Medaka_lib.Doc.render_markdown module_name entries);
    exit 0
  end;
  (* ── check-policy subcommand ─────────────────────────────────────────────
     medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]

     Type-checks a plugin file, reads the named function's inferred effect row,
     checks it is a subset of the policy, and either accepts (+ runs on a sample
     input) or rejects with the call chain that introduces the forbidden effect.
     Implements the §7c "minimal wow demo" from CAPABILITY-PLATFORM.md. *)
  if has_sub "check-policy" then begin
    let rest = Array.to_list (Array.sub argv 2 (argc - 2)) in
    let file      = ref None in
    let allow_str = ref "Cache,Log" in
    let check_fn  = ref "transform" in
    let rec parse_args = function
      | []                   -> ()
      | "--allow" :: v :: tl -> allow_str := v; parse_args tl
      | "--fn"    :: v :: tl -> check_fn  := v; parse_args tl
      | f          :: tl     -> file := Some f; parse_args tl
    in
    parse_args rest;
    let filename = match !file with
      | Some f -> f
      | None ->
        Printf.eprintf
          "usage: medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]\n";
        exit 1
    in
    let policy =
      List.filter (fun s -> s <> "")
        (String.split_on_char ',' !allow_str)
    in

    (* ── 1. Parse + desugar ───────────────────────────────────────────── *)
    let source = read_file filename in
    let lexbuf = Lexing.from_string source in
    lexbuf.Lexing.lex_curr_p <-
      { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = filename };
    Medaka_lib.Lexer.reset ();
    let program =
      try Medaka_lib.Parser.program Medaka_lib.Lexer.token lexbuf
      with
      | Failure msg ->
        Printf.eprintf "parse error: %s\n" msg; exit 1
      | Medaka_lib.Parser.Error ->
        let pos = lexbuf.Lexing.lex_curr_p in
        Printf.eprintf "%s:%d:%d: parse error\n"
          pos.Lexing.pos_fname pos.Lexing.pos_lnum
          (pos.Lexing.pos_cnum - pos.Lexing.pos_bol);
        exit 1
    in
    let program = desugar_or_die ~source program in

    (* ── 2. Build call graph from the desugared AST ───────────────────── *)
    let module SS = Set.Make(String) in
    (* Collect all EVar names referenced in an expression (conservative —
       includes non-call uses, but safe for the chain-tracing heuristic). *)
    let rec collect_evars e =
      let open Medaka_lib.Ast in
      match e with
      | EVar n                     -> SS.singleton n
      | EApp (f, x)                -> SS.union (collect_evars f) (collect_evars x)
      | ELam (_, body)             -> collect_evars body
      | ELet (_, _, _, v, body)    -> SS.union (collect_evars v) (collect_evars body)
      | ELetGroup (groups, body)   ->
        let g = List.fold_left (fun acc (_, clauses) ->
          List.fold_left (fun a (_, b) -> SS.union a (collect_evars b)) acc clauses
        ) SS.empty groups in
        SS.union g (collect_evars body)
      | EMatch (e, arms)           ->
        List.fold_left (fun acc (_, gs, body) ->
          let gacc = List.fold_left (fun a gq ->
            match gq with
            | GBool ge        -> SS.union a (collect_evars ge)
            | GBind (_, ge)   -> SS.union a (collect_evars ge)
          ) acc gs in
          SS.union gacc (collect_evars body)
        ) (collect_evars e) arms
      | EIf (c, t, f)              ->
        SS.union (collect_evars c) (SS.union (collect_evars t) (collect_evars f))
      | EBinOp (_, a, b)           -> SS.union (collect_evars a) (collect_evars b)
      | EUnOp (_, e)               -> collect_evars e
      | EAnnot (e, _)
      | EHeadAnnot (e, _)
      | EFieldAccess (e, _)        -> collect_evars e
      | ERecordCreate (_, flds)    ->
        List.fold_left (fun a (_, v) -> SS.union a (collect_evars v)) SS.empty flds
      | ERecordUpdate (e, flds)    ->
        List.fold_left (fun a (_, v) -> SS.union a (collect_evars v))
          (collect_evars e) flds
      | ETuple es | EListLit es | EArrayLit es ->
        List.fold_left (fun a e -> SS.union a (collect_evars e)) SS.empty es
      | EBlock stmts               ->
        List.fold_left (fun acc stmt ->
          let open Medaka_lib.Ast in
          match stmt with
          | DoExpr e            -> SS.union acc (collect_evars e)
          | DoBind (_, e)       -> SS.union acc (collect_evars e)
          | DoLet (_, _, _, e)  -> SS.union acc (collect_evars e)
          | DoAssign (_, e)     -> SS.union acc (collect_evars e)
          | DoFieldAssign (_, _, e) -> SS.union acc (collect_evars e)
          | DoLetElse (_, e1, e2)   ->
            SS.union acc (SS.union (collect_evars e1) (collect_evars e2))
        ) SS.empty stmts
      | EInfix (_, a, b)           -> SS.union (collect_evars a) (collect_evars b)
      | EIndex (a, b)              -> SS.union (collect_evars a) (collect_evars b)
      | EMethodRef (_, n)
      | EDictApp (_, n)            -> SS.singleton n
      | ELoc (_, e)                -> collect_evars e
      | _                          -> SS.empty
    in
    (* fn_name → set of EVar names used in its body *)
    let fn_bodies : (string * SS.t) list ref = ref [] in
    let top_names : SS.t ref = ref SS.empty in
    List.iter (fun decl ->
      match Medaka_lib.Ast.inner_decl decl with
      | Medaka_lib.Ast.DFunDef (_, name, _, body) ->
        top_names := SS.add name !top_names;
        fn_bodies := (name, collect_evars body) :: !fn_bodies
      | Medaka_lib.Ast.DExtern (_, name, _) ->
        top_names := SS.add name !top_names
      | _ -> ()
    ) program;
    (* Restrict each callset to top-level names only *)
    let call_graph : (string * SS.t) list =
      List.map (fun (n, refs) -> (n, SS.inter refs !top_names)) !fn_bodies
    in

    (* ── 3. Resolve + typecheck ───────────────────────────────────────── *)
    let resolve_errs = Medaka_lib.Resolve.resolve_program program in
    if resolve_errs <> [] then begin
      List.iter (fun (err, loc_opt) ->
        Printf.eprintf "%s: %s\n"
          (pp_loc loc_opt) (Medaka_lib.Resolve.pp_error err);
        show_snippet source loc_opt
      ) resolve_errs;
      exit 1
    end;
    let (schemes, warnings) =
      try Medaka_lib.Typecheck.check_program program
      with Medaka_lib.Typecheck.Type_error (e, loc_opt) ->
        Printf.eprintf "%s: %s\n"
          (pp_loc loc_opt) (Medaka_lib.Typecheck.pp_error e);
        show_snippet source loc_opt;
        exit 1
    in
    List.iter (fun w -> Printf.eprintf "%s\n" w) warnings;

    (* ── 4. Extract effect labels from a scheme ───────────────────────── *)
    let rec mono_effects mono =
      match Medaka_lib.Typecheck.normalize mono with
      | Medaka_lib.Typecheck.TFun (_, row, result) ->
        let labels = Medaka_lib.Typecheck.effrow_labels row in
        List.sort_uniq String.compare (labels @ mono_effects result)
      | Medaka_lib.Typecheck.TApp (a, b) ->
        List.sort_uniq String.compare (mono_effects a @ mono_effects b)
      | _ -> []
    in
    let scheme_effects (Medaka_lib.Typecheck.Forall (_, _, mono)) =
      mono_effects mono
    in
    let fn_effects : (string * string list) list =
      List.filter_map (fun (name, scheme) ->
        match scheme_effects scheme with
        | [] -> None
        | effs -> Some (name, effs)
      ) schemes
    in
    let fn_has_effect name label =
      match List.assoc_opt name fn_effects with
      | None -> false
      | Some effs -> List.mem label effs
    in

    (* ── 5. Policy check ─────────────────────────────────────────────── *)
    let transform_effects =
      Option.value ~default:[] (List.assoc_opt !check_fn fn_effects)
    in
    let forbidden =
      List.filter (fun l -> not (List.mem l policy)) transform_effects
    in

    (* ── 6. Call-chain reconstruction ────────────────────────────────── *)
    let get_callees fn =
      match List.assoc_opt fn call_graph with
      | None -> SS.empty
      | Some s -> s
    in
    let find_chain start forbidden_label =
      let rec trace fn visited =
        let callee =
          SS.find_first_opt (fun c -> fn_has_effect c forbidden_label)
            (get_callees fn)
        in
        match callee with
        | None -> [fn]
        | Some c ->
          if SS.mem c visited then [fn; c]
          else fn :: trace c (SS.add c visited)
      in
      trace start (SS.singleton start)
    in

    let labels_str ls = String.concat ", " ls in

    (* ── 7. Accept or reject ─────────────────────────────────────────── *)
    if forbidden = [] then begin
      let eff_str = if transform_effects = [] then "pure"
                    else "<" ^ labels_str transform_effects ^ ">" in
      Printf.printf "✅ accepted — %s requires only %s\n" !check_fn eff_str;
      (* Run the plugin on a sample request with stub platform implementations *)
      let open Medaka_lib.Eval in
      let log_buf : string list ref = ref [] in
      extra_prims := [
        ("cacheGet", VPrim (fun _ -> VString ""));
        ("cacheSet", VPrim (fun _ -> VPrim (fun _ -> VUnit)));
        ("logEvent", VPrim (fun v ->
          (match v with
           | VString s -> log_buf := s :: !log_buf
           | _ -> ());
          VUnit));
      ];
      (try
        let (_marked, combined, _env, _warns) = Medaka_lib.Elaborate.elaborate program in
        let top_env = eval_program ~prelude:false combined in
        extra_prims := [];
        let sample = "X-Forwarded-For: 192.168.1.1" in
        (match List.assoc_opt !check_fn top_env with
         | None ->
           Printf.printf "   (no '%s' binding in output)\n" !check_fn
         | Some fn_val ->
           let result = Medaka_lib.Eval.apply fn_val (VString sample) in
           List.iter (fun msg ->
             Printf.printf "   [LOG] %s\n" msg
           ) (List.rev !log_buf);
           Printf.printf "   transform %S = %s\n" sample (pp_value result))
       with
       | Eval_error (msg, loc_opt) ->
         extra_prims := [];
         Printf.eprintf "%s: panic: %s\n" (pp_loc loc_opt) msg
       | Medaka_lib.Typecheck.Type_error (e, loc_opt) ->
         extra_prims := [];
         Printf.eprintf "%s: %s\n" (pp_loc loc_opt)
           (Medaka_lib.Typecheck.pp_error e));
      exit 0
    end else begin
      let first_forbidden = List.hd forbidden in
      let chain = find_chain !check_fn first_forbidden in
      Printf.printf "❌ rejected — %s requires <%s> — not permitted by policy {%s}\n"
        !check_fn (labels_str transform_effects) (labels_str policy);
      Printf.printf "   reached via: %s\n" (String.concat " → " chain);
      exit 1
    end
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
                (mid, fp, desugar_or_die p)) modules in
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
  (* Phase 82: extract check/run flags and rebuild a flag-free argv so the
     positional parsing below finds the file regardless of flag position.
     `--release` is accepted but currently a no-op alias for `run` (no optimizer
     yet); `--json` selects machine-readable diagnostics for `check`. *)
  let raw_args = Array.to_list argv in
  let json_mode = List.mem "--json" raw_args in
  let _release  = List.mem "--release" raw_args in
  let argv =
    Array.of_list
      (List.filter (fun s -> s <> "--json" && s <> "--release") raw_args)
  in
  let argc = Array.length argv in
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
  (* io Module 7: expose the program's own args to the `args` extern.
     `medaka run FILE a b c` → the program sees ["a"; "b"; "c"]. (Only the
     explicit `run FILE …` form carries trailing args; the bare/config forms
     pass none.) *)
  Medaka_lib.Eval.program_args :=
    (if has_sub "run" && argc >= 3
     then Array.to_list (Array.sub argv 3 (argc - 3))
     else []);
  let project_dir =
    match Medaka_lib.Project_config.find_project_root filename with
    | Some d -> d
    | None   -> Filename.dirname filename
  in

  (* Single-file fast path: no use declarations → bypass loader *)
  let source = read_file filename in

  (* Phase 82: `check --json` — accumulate every diagnostic (not exit-on-first)
     and emit the LSP diagnostic shape as JSON on stdout.  Routes through the
     multi-file loader (`analyze_project`) so a file with `import`s resolves its
     dependencies instead of spuriously erroring on them; output is a top-level
     "files" array, one entry per module in the import graph (a no-import file is
     simply a one-element array). *)
  (if mode = `Check && json_mode then begin
    let results =
      Medaka_lib.Diagnostics.analyze_project
        ~root_file:filename ~project_dir ~read:(fun _ -> None) ()
    in
    print_endline (Medaka_lib.Lsp_server.all_diagnostics_to_json results);
    let has_err =
      List.exists
        (fun (_file, diags) ->
           List.exists
             (fun (d : Medaka_lib.Diagnostics.diagnostic) ->
                d.severity = Medaka_lib.Diagnostics.Error)
             diags)
        results
    in
    exit (if has_err then 1 else 0)
  end);

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

  (* Phase 91 (2): guard-exhaustiveness warnings on the raw root program. *)
  List.iter (fun w -> Printf.eprintf "%s\n" w)
    (Medaka_lib.Exhaust.check_guard_exhaustiveness root_program);

  let root_program = desugar_or_die ~source root_program in

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
      (* Phase 84: two-pass elaboration — mark, typecheck, and (when a
         polymorphic-monad do-block infers a promotable constraint) re-mark +
         re-typecheck so the dict-passed [combined] routes return-position
         methods like `pure` by the caller's monad.  [combined] is ready for eval;
         dict_pass only alters DFunDef arities. *)
      let (_marked, combined, env, warnings) =
        Medaka_lib.Elaborate.elaborate root_program in
      List.iter (fun w -> Printf.eprintf "%s\n" w) warnings;
      (match mode with
       | `Check ->
         Printf.printf "OK — %d bindings\n" (List.length env)
       | `Run ->
         (try
           let top_env = Medaka_lib.Eval.eval_program ~prelude:false combined in
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
      (* Phase 91 (2): guard-exhaustiveness warnings, per raw module. *)
      List.iter (fun w -> Printf.eprintf "%s\n" w)
        (Medaka_lib.Exhaust.check_guard_exhaustiveness prog);
      (mid, fp, desugar_or_die prog)
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
       signatures.  Phase 69.x-c: include the prelude's constrained fns (e.g.
       `when`/`unless`) so cross-module references to them become EDictApp. *)
    let constrained_names =
      Medaka_lib.Method_marker.constrained_fn_names
        (Medaka_lib.Prelude.program :: List.map (fun (_, _, p) -> p) modules)
    in
    (* Phase 88: two-pass elaboration across modules, mirroring the single-file
       Elaborate.elaborate and the REPL (Phase 87).  Pass 1 marks against the
       static constrained signatures and type-checks every module, collecting any
       unsignatured do-block wrapper whose inferred Applicative should become
       dict-routable (so its return-position `pure` routes by the caller's monad,
       not arg-tag "first impl wins").  If any qualify, re-mark every module with
       those names treated as constrained and re-type-check with them promoted —
       so their inferred constraints land in fun_constraints and dict_pass threads
       a dictionary in.  Nothing promotable (the common case) ⇒ one pass. *)
    let base_modules = modules in
    let typecheck_all ~constrained ?promoted () =
      let marked = List.map (fun (mid, fp, prog) ->
        (mid, fp, Medaka_lib.Method_marker.mark_program method_names constrained prog)
      ) base_modules in
      let type_exports = ref [] in
      let final_schemes = ref [] in
      let all_warnings = ref [] in
      let promoted_out = Hashtbl.create 8 in
      List.iter (fun (mod_id, _file_path, prog) ->
        (try
          let (te, schemes, warnings) =
            Medaka_lib.Typecheck.typecheck_module ?promoted ~promoted_out
              !type_exports mod_id prog
          in
          type_exports := te :: !type_exports;
          final_schemes := schemes;
          all_warnings := !all_warnings @ warnings
         with Medaka_lib.Typecheck.Type_error (e, loc_opt) ->
           Printf.eprintf "%s: %s\n" (pp_loc loc_opt) (Medaka_lib.Typecheck.pp_error e);
           show_snippet source loc_opt;
           exit 1)
      ) marked;
      (marked, !final_schemes, !all_warnings, promoted_out)
    in
    let (modules1, schemes1, warnings1, promoted) =
      typecheck_all ~constrained:constrained_names () in
    let (modules, final_schemes, all_warnings) =
      if Hashtbl.length promoted = 0 then (modules1, ref schemes1, ref warnings1)
      else begin
        let constrained2 = Hashtbl.copy constrained_names in
        Hashtbl.iter (fun k () -> Hashtbl.replace constrained2 k ()) promoted;
        let (m2, s2, w2, _) =
          typecheck_all ~constrained:constrained2 ~promoted () in
        (m2, ref s2, ref w2)
      end
    in
    List.iter (fun w -> Printf.eprintf "%s\n" w) !all_warnings;

    (match mode with
     | `Check ->
       Printf.printf "OK — %d bindings\n" (List.length !final_schemes)
     | `Run ->
       (* Phase 110: evaluate each module in its own name scope (per-module
          frames over a shared global frame), so same-named top-level functions
          in different modules don't merge into one VMulti and mis-dispatch.
          eval_modules dict-passes the marked prelude + all modules internally
          (Phase 69.x) and threads the prelude through the global frame. *)
       (try
         let top_env = Medaka_lib.Eval.eval_modules modules in
         if not (List.mem_assoc "main" top_env) then begin
           Printf.eprintf "error: program has no 'main' binding\n"; exit 1
         end
       with Medaka_lib.Eval.Eval_error (msg, loc_opt) ->
         Printf.eprintf "%s: panic: %s\n" (pp_loc loc_opt) msg;
         show_snippet source loc_opt;
         exit 1))
  end
