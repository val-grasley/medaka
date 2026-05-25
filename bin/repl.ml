open Medaka_lib

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

(* True when the last non-empty line is indented and no blank line was entered.
   A successful parse while still indented means the user may have more match arms
   to add; we keep collecting (Python-style: blank line commits). *)
let ends_indented source =
  let len = String.length source in
  if len >= 2 && source.[len-2] = '\n' then false  (* blank line → flush *)
  else
    let lines = String.split_on_char '\n' source in
    let non_empty = List.filter (fun l -> String.trim l <> "") lines in
    match List.rev non_empty with
    | [] -> false
    | last :: _ -> String.length last > 0 && (last.[0] = ' ' || last.[0] = '\t')

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

let process_item source resolve_env tc_env eval_state pending_sigs item =
  let resolve_errs = Resolve.resolve_repl_item resolve_env item in
  if resolve_errs <> [] then
    List.iter (fun (err, loc_opt) ->
      Printf.eprintf "%s: %s\n%!" (pp_loc loc_opt) (Resolve.pp_error err);
      show_snippet source loc_opt
    ) resolve_errs
  else
    match item with
    | Ast.ReplDecl decls ->
      (* Augment with pending type sigs from prior inputs, then update the list *)
      let defined_names = List.filter_map
        (function Ast.DFunDef (n,_,_) -> Some n | _ -> None) decls in
      let relevant_sigs = List.filter
        (function Ast.DTypeSig (n, _) -> List.mem n defined_names | _ -> false)
        !pending_sigs
      in
      let new_pending_sigs = List.filter
        (function Ast.DTypeSig (n, _) -> not (List.mem n defined_names) | _ -> true)
        !pending_sigs
      in
      let standalone_sigs = List.filter
        (function Ast.DTypeSig (n, _) -> not (List.mem n defined_names) | _ -> false)
        decls
      in
      pending_sigs := new_pending_sigs @ standalone_sigs;
      let augmented_decls = relevant_sigs @ decls in
      (try
         let (bindings, warnings) = Typecheck.check_repl_decl tc_env augmented_decls in
         List.iter (fun w -> Printf.eprintf "%s\n%!" w) warnings;
         List.iter (Eval.eval_repl_decl eval_state) decls;
         List.iter (fun (name, scheme) ->
           Printf.printf "val %s : %s\n%!" name (Typecheck.pp_scheme scheme)
         ) bindings;
         List.iter (fun decl ->
           match decl with
           | Ast.DData (n, _, _)     -> Printf.printf "type %s\n%!" n
           | Ast.DRecord (n, _, _)   -> Printf.printf "record %s\n%!" n
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

let run () =
  let resolve_env = Resolve.make_repl_resolve_env () in
  let tc_env      = Typecheck.make_repl_tc_env () in
  let eval_state  = Eval.make_repl_eval_state () in
  let pending_sigs : Ast.decl list ref = ref [] in
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
          pending_sigs := [];
          Printf.printf "Session reset.\n%!"
        end else if String.length trimmed >= 5 &&
                    String.sub trimmed 0 5 = ":type" then begin
          let rest = String.trim (String.sub trimmed 5 (String.length trimmed - 5)) in
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
          Printf.eprintf "Unknown command: %s  (try :type, :reset, :quit)\n%!" trimmed;
        cont := false
      end else begin
        (* Normal input *)
        match try_parse source with
        | Ok item ->
          Buffer.clear buf; cont := false;
          process_item source resolve_env tc_env eval_state pending_sigs item
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
        process_item source resolve_env tc_env eval_state pending_sigs item
      | Error true ->
        ()
      | Error false ->
        Buffer.clear buf; cont := false;
        Printf.eprintf "Parse error\n%!"
    end
  done
  with Exit | End_of_file -> ()
