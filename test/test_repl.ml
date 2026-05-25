open Medaka_lib

(* ── Helpers ──────────────────────────────────────────────────────────────── *)

let make_state () =
  let r  = Resolve.make_repl_resolve_env () in
  let tc = Typecheck.make_repl_tc_env () in
  let ev = Eval.make_repl_eval_state () in
  let ps = ref [] in
  let ub = ref [] in
  (r, tc, ev, ps, ub)

(* Run source text through the REPL, returning user_bindings. *)
let process_src src =
  let (r, tc, ev, ps, ub) = make_state () in
  (match Repl.try_parse src with
   | Ok item -> Repl.process_item src r tc ev ps ub item
   | Error _ -> failwith ("parse failed for: " ^ src));
  !ub

let binding_names ub = List.map fst ub |> List.sort String.compare

let write_tmp contents =
  let path = Filename.temp_file "test_repl" ".mdk" in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  path

(* ── process_item: basic declaration and expression ───────────────────────── *)

let t_decl_adds_binding () =
  let ub = process_src "f x = x + 1\n" in
  if not (List.mem_assoc "f" ub) then
    failwith (Printf.sprintf "Expected 'f' in bindings, got: %s"
                (String.concat ", " (List.map fst ub)))

let t_expr_no_binding () =
  (* A bare expression does not add to user_bindings *)
  let ub = process_src "1 + 1\n" in
  if ub <> [] then
    failwith (Printf.sprintf "Expected no bindings, got: %s"
                (String.concat ", " (List.map fst ub)))

(* ── :load success ────────────────────────────────────────────────────────── *)

let t_load_success () =
  let path = write_tmp "double x = x * 2\n" in
  let (r, tc, ev, ps, ub) = make_state () in
  (try Repl.load_file path r tc ev ps ub
   with Exit -> failwith "load_file raised Exit unexpectedly");
  let names = binding_names !ub in
  if not (List.mem "double" names) then
    failwith (Printf.sprintf "Expected 'double' after load, got: %s"
                (String.concat ", " names));
  Sys.remove path

let t_load_multiple_bindings () =
  let path = write_tmp "add x y = x + y\nsub x y = x - y\n" in
  let (r, tc, ev, ps, ub) = make_state () in
  (try Repl.load_file path r tc ev ps ub
   with Exit -> failwith "load_file raised Exit unexpectedly");
  let names = binding_names !ub in
  if not (List.mem "add" names && List.mem "sub" names) then
    failwith (Printf.sprintf "Expected add+sub after load, got: %s"
                (String.concat ", " names));
  Sys.remove path

(* ── :load error rolls back state ─────────────────────────────────────────── *)

let t_load_type_error_rollback () =
  let path = write_tmp "bad = 1 + \"oops\"\n" in
  let (r, tc, ev, ps, ub) = make_state () in
  (* Capture stderr to suppress error output *)
  let old_err = Unix.dup Unix.stderr in
  let dev_null = Unix.openfile "/dev/null" [Unix.O_WRONLY] 0 in
  Unix.dup2 dev_null Unix.stderr; Unix.close dev_null;
  (try Repl.load_file path r tc ev ps ub with Exit -> ());
  Unix.dup2 old_err Unix.stderr; Unix.close old_err;
  (* After failed load, user_bindings should still be empty *)
  if !ub <> [] then
    failwith (Printf.sprintf "Expected empty bindings after failed load, got: %s"
                (String.concat ", " (List.map fst !ub)));
  (* Session should still be usable *)
  (match Repl.try_parse "x = 42\n" with
   | Ok item -> Repl.process_item "x = 42\n" r tc ev ps ub item
   | _ -> failwith "parse failed after rollback");
  if not (List.mem_assoc "x" !ub) then
    failwith "Session not functional after failed load";
  Sys.remove path

(* ── :load rejects use declarations ──────────────────────────────────────── *)

let t_load_rejects_use () =
  let path = write_tmp "use foo.bar\nf x = x\n" in
  let (r, tc, ev, ps, ub) = make_state () in
  let old_err = Unix.dup Unix.stderr in
  let dev_null = Unix.openfile "/dev/null" [Unix.O_WRONLY] 0 in
  Unix.dup2 dev_null Unix.stderr; Unix.close dev_null;
  (try Repl.load_file path r tc ev ps ub with Exit -> ());
  Unix.dup2 old_err Unix.stderr; Unix.close old_err;
  (* 'f' should NOT have been loaded *)
  if List.mem_assoc "f" !ub then
    failwith "Expected 'f' to be absent after rejected load";
  Sys.remove path

(* ── :load missing file ────────────────────────────────────────────────────── *)

let t_load_missing_file () =
  let (r, tc, ev, ps, ub) = make_state () in
  let old_err = Unix.dup Unix.stderr in
  let dev_null = Unix.openfile "/dev/null" [Unix.O_WRONLY] 0 in
  Unix.dup2 dev_null Unix.stderr; Unix.close dev_null;
  (try Repl.load_file "/nonexistent/path/nope.mdk" r tc ev ps ub
   with Exit -> ());
  Unix.dup2 old_err Unix.stderr; Unix.close old_err;
  if !ub <> [] then
    failwith "Expected empty bindings after missing file load"

(* ── :browse (user_bindings accumulation) ─────────────────────────────────── *)

let t_browse_accumulates () =
  let (r, tc, ev, ps, ub) = make_state () in
  let run src =
    match Repl.try_parse src with
    | Ok item -> Repl.process_item src r tc ev ps ub item
    | _ -> failwith ("parse failed: " ^ src)
  in
  run "x = 42\n";
  run "double n = n * 2\n";
  let names = binding_names !ub in
  if not (List.mem "x" names && List.mem "double" names) then
    failwith (Printf.sprintf "Expected x+double in user_bindings, got: %s"
                (String.concat ", " names))

(* ── :load + subsequent REPL interaction ─────────────────────────────────── *)

let t_load_then_use () =
  let path = write_tmp "greet name = \"Hello, \" ++ name\n" in
  let (r, tc, ev, ps, ub) = make_state () in
  (try Repl.load_file path r tc ev ps ub
   with Exit -> failwith "load_file raised Exit");
  (* After load, greet should be callable from the REPL *)
  let item_src = "greet \"world\"\n" in
  (match Repl.try_parse item_src with
   | Ok item ->
     (try Repl.process_item item_src r tc ev ps ub item
      with Typecheck.Type_error (err, _) ->
        failwith (Printf.sprintf "Type error after load: %s" (Typecheck.pp_error err)))
   | _ -> failwith "parse failed for greet call");
  Sys.remove path

(* ── Suite ────────────────────────────────────────────────────────────────── *)

let () = Alcotest.run "Repl"
  [ ("process_item", [
      "decl adds binding", `Quick, t_decl_adds_binding;
      "expr no binding",   `Quick, t_expr_no_binding;
    ]);
    ("load success", [
      "load one binding",       `Quick, t_load_success;
      "load multiple bindings", `Quick, t_load_multiple_bindings;
      "load then use",          `Quick, t_load_then_use;
    ]);
    ("load error handling", [
      "type error rollback",  `Quick, t_load_type_error_rollback;
      "rejects use decls",    `Quick, t_load_rejects_use;
      "missing file",         `Quick, t_load_missing_file;
    ]);
    ("browse", [
      "accumulates bindings", `Quick, t_browse_accumulates;
    ]);
  ]
