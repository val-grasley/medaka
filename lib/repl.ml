let starts_with prefix s =
  String.length s >= String.length prefix &&
  String.sub s 0 (String.length prefix) = prefix

let pp_loc = function
  | None   -> "<repl>"
  | Some l -> Printf.sprintf "<repl>:%d:%d" l.Ast.line l.Ast.col

let show_snippet source loc_opt =
  match loc_opt with
  | None -> ()
  | Some l ->
    let lines = String.split_on_char '\n' source in
    (match List.nth_opt lines (l.Ast.line - 1) with
     | None -> ()
     | Some text ->
       Printf.eprintf "  |\n%d | %s\n  | %s^\n"
         l.Ast.line text (String.make l.Ast.col ' '))

(* Try to parse `source`.  Returns:
     `Ok item`    — success
     `Error true` — parse error at EOF (incomplete input, need more lines)
     `Error false`— hard parse error *)
let at_or_past_eof pos source =
  pos.Lexing.pos_cnum >= String.length source

let is_ident_char c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9') || c = '_'

(* True when the trimmed [line] ends with the keyword [kw] as a whole word
   (so "where" matches but "elsewhere" does not). *)
let ends_with_keyword line kw =
  let s = String.trim line in
  let ls = String.length s and lk = String.length kw in
  ls >= lk
  && String.sub s (ls - lk) lk = kw
  && (ls = lk || not (is_ident_char s.[ls - lk - 1]))

(* True when the input should keep collecting lines and no blank line was
   entered.  Two cases (Python-style: a blank line always commits):
   - the last non-empty line is indented — the user may have more match arms /
     methods to add;
   - the last non-empty line ends with `where`, which opens a layout block.
     `interface X where` / `impl T X where` each parse as a *complete*
     zero-method declaration (marker-interface / empty-impl grammar forms), so
     without this the REPL would commit the header and parse the indented body
     lines below it as separate top-level declarations. *)
let ends_indented source =
  let len = String.length source in
  if len >= 2 && source.[len-2] = '\n' then false  (* blank line → flush *)
  else
    let lines = String.split_on_char '\n' source in
    let non_empty = List.filter (fun l -> String.trim l <> "") lines in
    match List.rev non_empty with
    | [] -> false
    | last :: _ ->
      (String.length last > 0 && (last.[0] = ' ' || last.[0] = '\t'))
      || ends_with_keyword last "where"

let try_parse source =
  (* First attempt: parse as a program (declarations) *)
  let lexbuf1 = Lexing.from_string source in
  lexbuf1.Lexing.lex_curr_p <-
    { lexbuf1.Lexing.lex_curr_p with Lexing.pos_fname = "<repl>" };
  Lexer.reset ();
  match Parser.program Lexer.token lexbuf1 with
  | decls ->
    if ends_indented source then Error true
    else Ok (Ast.ReplDecl decls)
  | exception Failure msg ->
    Printf.eprintf "Error: %s\n%!" msg; Error false
  | exception Parser.Error ->
    let prog_at_eof = at_or_past_eof lexbuf1.Lexing.lex_curr_p source in
    (* Second attempt: parse as a bare expression — always try this *)
    let lexbuf2 = Lexing.from_string source in
    lexbuf2.Lexing.lex_curr_p <-
      { lexbuf2.Lexing.lex_curr_p with Lexing.pos_fname = "<repl>" };
    Lexer.reset ();
    (match Parser.repl_expr Lexer.token lexbuf2 with
     | e -> Ok (Ast.ReplExpr e)
     | exception Failure msg ->
       Printf.eprintf "Error: %s\n%!" msg; Error false
     | exception Parser.Error ->
       let expr_at_eof = at_or_past_eof lexbuf2.Lexing.lex_curr_p source in
       (* Incomplete if either parser reached end of input *)
       Error (prog_at_eof || expr_at_eof))

let process_item source resolve_env tc_env eval_state pending_sigs user_bindings item =
  let item = Desugar.desugar_repl_item item in
  let resolve_errs = Resolve.resolve_repl_item resolve_env item in
  if resolve_errs <> [] then
    List.iter (fun (err, loc_opt) ->
      Printf.eprintf "%s: %s\n%!" (pp_loc loc_opt) (Resolve.pp_error err);
      show_snippet source loc_opt
    ) resolve_errs
  else
    (* Phase 69: mark interface-method occurrences so typecheck can stamp the
       resolved impl and eval routes by it.  The method-name set is the session's
       known methods (tc_env.method_iface — prelude + interfaces from prior
       inputs) plus any this item itself declares. *)
    let item =
      let item_progs = match item with
        | Ast.ReplDecl decls -> [decls]
        | Ast.ReplExpr _ -> []
      in
      let methods =
        let tbl = Method_marker.interface_method_names item_progs in
        Hashtbl.iter (fun m _ -> Hashtbl.replace tbl m ())
          (!tc_env).Typecheck.method_iface;
        tbl
      in
      (* Constrained functions: this item's own constrained signatures plus any
         declared on prior inputs (fun_constraints accrues across the session). *)
      let constrained =
        let tbl = Method_marker.constrained_fn_names item_progs in
        Hashtbl.iter (fun f _ -> Hashtbl.replace tbl f ())
          (!tc_env).Typecheck.fun_constraints;
        tbl
      in
      Method_marker.mark_repl_item methods constrained item
    in
    match item with
    | Ast.ReplDecl decls -> (* already desugared above *)
      (* Augment with pending type sigs from prior inputs, then update the list *)
      let defined_names = List.filter_map
        (function Ast.DFunDef (_,n,_,_) -> Some n | _ -> None) decls in
      let relevant_sigs = List.filter
        (function Ast.DTypeSig (_, n, _) -> List.mem n defined_names | _ -> false)
        !pending_sigs
      in
      let new_pending_sigs = List.filter
        (function Ast.DTypeSig (_, n, _) -> not (List.mem n defined_names) | _ -> true)
        !pending_sigs
      in
      let standalone_sigs = List.filter
        (function Ast.DTypeSig (_, n, _) -> not (List.mem n defined_names) | _ -> false)
        decls
      in
      pending_sigs := new_pending_sigs @ standalone_sigs;
      let augmented_decls = relevant_sigs @ decls in
      (try
         let (bindings, warnings) = Typecheck.check_repl_decl tc_env augmented_decls in
         List.iter (fun w -> Printf.eprintf "%s\n%!" w) warnings;
         (* Phase 69.x: add dictionary parameters to any constrained functions
            defined here (arity from fun_constraints, since this batch may hold no
            reference to learn it from) before eval registers their closures. *)
         let decls = Dict_pass.run ~fun_constraints:(!tc_env).Typecheck.fun_constraints decls in
         List.iter (Eval.eval_repl_decl eval_state) decls;
         user_bindings := !user_bindings @ bindings;
         List.iter (fun (name, scheme) ->
           Printf.printf "val %s : %s\n%!" name (Typecheck.pp_scheme scheme)
         ) bindings;
         List.iter (fun decl ->
           match decl with
           | Ast.DData (_, n, _, _, _)   -> Printf.printf "type %s\n%!" n
           | Ast.DRecord (_, n, _, _, _) -> Printf.printf "record %s\n%!" n
           | Ast.DInterface { iface_name; _ } ->
             Printf.printf "interface %s\n%!" iface_name
           | _ -> ()
         ) decls
       with
       | Typecheck.Type_error (err, loc_opt) ->
         Printf.eprintf "%s: %s\n%!" (pp_loc loc_opt) (Typecheck.pp_error err);
         show_snippet source loc_opt
       | Eval.Eval_error (msg, loc_opt) ->
         Printf.eprintf "%s: panic: %s\n%!" (pp_loc loc_opt) msg;
         show_snippet source loc_opt)
    | Ast.ReplExpr e ->
      (try
         let (t, warnings) = Typecheck.infer_repl_expr !tc_env e in
         List.iter (fun w -> Printf.eprintf "%s\n%!" w) warnings;
         let v = Eval.eval_repl_expr eval_state e in
         Printf.printf "%s : %s\n%!" (Eval.pp_value v) (Typecheck.pp_mono t)
       with
       | Typecheck.Type_error (err, loc_opt) ->
         Printf.eprintf "%s: %s\n%!" (pp_loc loc_opt) (Typecheck.pp_error err);
         show_snippet source loc_opt
       | Eval.Eval_error (msg, loc_opt) ->
         Printf.eprintf "%s: panic: %s\n%!" (pp_loc loc_opt) msg;
         show_snippet source loc_opt)

let copy_ht src dst =
  Hashtbl.reset dst;
  Hashtbl.iter (Hashtbl.replace dst) src

let reset_session resolve_env tc_env eval_state =
  let fresh_r = Resolve.make_repl_resolve_env () in
  copy_ht fresh_r.Resolve.values        resolve_env.Resolve.values;
  copy_ht fresh_r.Resolve.types         resolve_env.Resolve.types;
  copy_ht fresh_r.Resolve.constructors  resolve_env.Resolve.constructors;
  copy_ht fresh_r.Resolve.fields        resolve_env.Resolve.fields;
  copy_ht fresh_r.Resolve.field_owners  resolve_env.Resolve.field_owners;
  copy_ht fresh_r.Resolve.interfaces    resolve_env.Resolve.interfaces;
  copy_ht fresh_r.Resolve.iface_methods resolve_env.Resolve.iface_methods;
  copy_ht fresh_r.Resolve.imported      resolve_env.Resolve.imported;
  tc_env := !(Typecheck.make_repl_tc_env ());
  let fresh_e = Eval.make_repl_eval_state () in
  eval_state.Eval.top_frame := !(fresh_e.Eval.top_frame);
  eval_state.Eval.eval_env  := !(fresh_e.Eval.eval_env)

(* Parse source text as a program, with pos_fname set to path. *)
let parse_file_source path source =
  let lexbuf = Lexing.from_string source in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = path };
  Lexer.reset ();
  match Parser.program Lexer.token lexbuf with
  | decls -> Ok decls
  | exception Failure msg -> Error (Printf.sprintf "Error: %s" msg)
  | exception Parser.Error ->
    let pos = lexbuf.Lexing.lex_curr_p in
    Error (Printf.sprintf "%s:%d:%d: Parse error" path pos.Lexing.pos_lnum
             (pos.Lexing.pos_cnum - pos.Lexing.pos_bol))

(* Atomically load a file into the current REPL session.
   On any error: restore the env to its pre-load state. *)
let load_file path resolve_env tc_env eval_state pending_sigs user_bindings =
  (* snapshot resolve_env hashtables *)
  let snap_values      = Hashtbl.copy resolve_env.Resolve.values in
  let snap_types       = Hashtbl.copy resolve_env.Resolve.types in
  let snap_constructors= Hashtbl.copy resolve_env.Resolve.constructors in
  let snap_fields      = Hashtbl.copy resolve_env.Resolve.fields in
  let snap_field_owners= Hashtbl.copy resolve_env.Resolve.field_owners in
  let snap_interfaces  = Hashtbl.copy resolve_env.Resolve.interfaces in
  let snap_iface_meth  = Hashtbl.copy resolve_env.Resolve.iface_methods in
  let snap_imported    = Hashtbl.copy resolve_env.Resolve.imported in
  (* snapshot tc_env and eval_state *)
  let snap_tc   = Typecheck.copy_tc_env !tc_env in
  let snap_top  = !(eval_state.Eval.top_frame) in
  let snap_eval = !(eval_state.Eval.eval_env) in
  let snap_sigs = !pending_sigs in
  let snap_ub   = !user_bindings in
  let restore () =
    copy_ht snap_values       resolve_env.Resolve.values;
    copy_ht snap_types        resolve_env.Resolve.types;
    copy_ht snap_constructors resolve_env.Resolve.constructors;
    copy_ht snap_fields       resolve_env.Resolve.fields;
    copy_ht snap_field_owners resolve_env.Resolve.field_owners;
    copy_ht snap_interfaces   resolve_env.Resolve.interfaces;
    copy_ht snap_iface_meth   resolve_env.Resolve.iface_methods;
    copy_ht snap_imported     resolve_env.Resolve.imported;
    tc_env := snap_tc;
    eval_state.Eval.top_frame := snap_top;
    eval_state.Eval.eval_env  := snap_eval;
    pending_sigs  := snap_sigs;
    user_bindings := snap_ub
  in
  (* read file *)
  let source =
    match (try Ok (
      let ic = open_in path in
      let n = in_channel_length ic in
      let s = Bytes.create n in
      really_input ic s 0 n; close_in ic;
      Bytes.to_string s) with Sys_error msg -> Error msg)
    with
    | Error msg -> Printf.eprintf "Error: %s\n%!" msg; restore (); raise Exit
    | Ok s -> s
  in
  (* parse *)
  let program =
    match parse_file_source path source with
    | Error msg -> Printf.eprintf "%s\n%!" msg; restore (); raise Exit
    | Ok p -> Desugar.desugar_program p
  in
  (* reject use decls — need Phase 14 *)
  if List.exists (function Ast.DUse _ -> true | _ -> false) program then begin
    Printf.eprintf
      "Error: '%s' contains 'use' declarations; module imports require Phase 14\n%!" path;
    restore (); raise Exit
  end;
  (* attempt resolve + typecheck + eval *)
  let ok = ref true in
  let resolve_errs =
    Resolve.resolve_repl_item resolve_env (Ast.ReplDecl program) in
  if resolve_errs <> [] then begin
    ok := false;
    List.iter (fun (err, loc_opt) ->
      let file_loc = match loc_opt with
        | None   -> path
        | Some l -> Printf.sprintf "%s:%d:%d" path l.Ast.line l.Ast.col
      in
      Printf.eprintf "%s: %s\n%!" file_loc (Resolve.pp_error err)
    ) resolve_errs
  end else begin
    (try
       (* Phase 69: mark method occurrences (against session methods + this
          file's own interfaces) so check_repl_decl stamps resolved impls and
          eval — running on the same marked tree — routes by them. *)
       let program =
         let methods = Method_marker.interface_method_names [program] in
         Hashtbl.iter (fun m _ -> Hashtbl.replace methods m ())
           (!tc_env).Typecheck.method_iface;
         let constrained = Method_marker.constrained_fn_names [program] in
         Hashtbl.iter (fun f _ -> Hashtbl.replace constrained f ())
           (!tc_env).Typecheck.fun_constraints;
         Method_marker.mark_program methods constrained program
       in
       let (bindings, warnings) = Typecheck.check_repl_decl tc_env program in
       List.iter (fun w -> Printf.eprintf "%s\n%!" w) warnings;
       let program = Dict_pass.run ~fun_constraints:(!tc_env).Typecheck.fun_constraints program in
       List.iter (Eval.eval_repl_decl eval_state) program;
       user_bindings := !user_bindings @ bindings;
       let n = List.length bindings in
       Printf.printf "Loaded %s (%d binding%s)\n%!" path n
         (if n = 1 then "" else "s")
     with
     | Typecheck.Type_error (err, loc_opt) ->
       ok := false;
       let file_loc = match loc_opt with
         | None   -> path
         | Some l -> Printf.sprintf "%s:%d:%d" path l.Ast.line l.Ast.col
       in
       Printf.eprintf "%s: %s\n%!" file_loc (Typecheck.pp_error err)
     | Eval.Eval_error (msg, loc_opt) ->
       ok := false;
       let file_loc = match loc_opt with
         | None   -> path
         | Some l -> Printf.sprintf "%s:%d:%d" path l.Ast.line l.Ast.col
       in
       Printf.eprintf "%s: panic: %s\n%!" file_loc msg)
  end;
  if not !ok then restore ()

let run () =
  let resolve_env = Resolve.make_repl_resolve_env () in
  let tc_env      = Typecheck.make_repl_tc_env () in
  let eval_state  = Eval.make_repl_eval_state () in
  let pending_sigs  : Ast.decl list ref = ref [] in
  let user_bindings : (Ast.ident * Typecheck.scheme) list ref = ref [] in
  let last_load     : string option ref = ref None in
  let buf = Buffer.create 64 in
  let cont = ref false in
  Printf.printf "medaka repl  (:quit to exit, :reset to clear session)\n%!";
  try while true do
    print_string (if !cont then "  " else "> ");
    flush stdout;
    let line =
      try input_line stdin
      with End_of_file -> raise Exit
    in
    Buffer.add_string buf line;
    Buffer.add_char buf '\n';
    let source = Buffer.contents buf in
    (* Handle meta-commands only at the start of a fresh input *)
    if not !cont then begin
      let trimmed = String.trim line in
      if String.length trimmed > 0 && trimmed.[0] = ':' then begin
        Buffer.clear buf;
        if trimmed = ":quit" || trimmed = ":q" then exit 0
        else if trimmed = ":reset" then begin
          reset_session resolve_env tc_env eval_state;
          pending_sigs  := [];
          user_bindings := [];
          (* last_load preserved intentionally — :r after :reset re-loads *)
          Printf.printf "Session reset.\n%!"
        end else if starts_with ":load" trimmed then begin
          let path = String.trim
            (String.sub trimmed 5 (String.length trimmed - 5)) in
          if path = "" then
            Printf.eprintf ":load requires a file path\n%!"
          else begin
            (try load_file path resolve_env tc_env eval_state
                   pending_sigs user_bindings
             with Exit -> ());
            last_load := Some path
          end
        end else if trimmed = ":reload" || trimmed = ":r" then begin
          (match !last_load with
           | None ->
             Printf.eprintf "No file loaded yet — use :load <path> first\n%!"
           | Some path ->
             (try load_file path resolve_env tc_env eval_state
                    pending_sigs user_bindings
              with Exit -> ()))
        end else if trimmed = ":browse" || trimmed = ":env" then begin
          let sorted =
            List.sort (fun (a,_) (b,_) -> String.compare a b) !user_bindings in
          if sorted = [] then
            Printf.printf "(no user-defined bindings)\n%!"
          else
            List.iter (fun (name, scheme) ->
              Printf.printf "val %s : %s\n%!" name (Typecheck.pp_scheme scheme)
            ) sorted
        end else if starts_with ":type" trimmed || starts_with ":t " trimmed then begin
          let prefix_len =
            if starts_with ":type" trimmed then 5 else 3 in
          let rest = String.trim
            (String.sub trimmed prefix_len (String.length trimmed - prefix_len)) in
          let lexbuf = Lexing.from_string (rest ^ "\n") in
          lexbuf.Lexing.lex_curr_p <-
            { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = "<repl>" };
          Lexer.reset ();
          (match Parser.repl_expr Lexer.token lexbuf with
           | e ->
             (try
                let (t, _) = Typecheck.infer_repl_expr !tc_env e in
                Printf.printf "%s\n%!" (Typecheck.pp_mono t)
              with Typecheck.Type_error (err, loc_opt) ->
                Printf.eprintf "%s: %s\n%!" (pp_loc loc_opt)
                  (Typecheck.pp_error err))
           | exception Parser.Error ->
             Printf.eprintf ":type: parse error\n%!"
           | exception Failure msg ->
             Printf.eprintf "Error: %s\n%!" msg)
        end else
          Printf.eprintf
            "Unknown command: %s  (try :load, :reload, :browse, :type, :reset, :quit)\n%!"
            trimmed;
        cont := false
      end else begin
        (* Normal input *)
        match try_parse source with
        | Ok item ->
          Buffer.clear buf; cont := false;
          process_item source resolve_env tc_env eval_state pending_sigs
            user_bindings item
        | Error true ->
          cont := true
        | Error false ->
          Buffer.clear buf; cont := false;
          Printf.eprintf "Parse error\n%!"
      end
    end else begin
      (* Continuation line *)
      match try_parse source with
      | Ok item ->
        Buffer.clear buf; cont := false;
        process_item source resolve_env tc_env eval_state pending_sigs
          user_bindings item
      | Error true ->
        ()
      | Error false ->
        Buffer.clear buf; cont := false;
        Printf.eprintf "Parse error\n%!"
    end
  done
  with Exit | End_of_file -> ()
