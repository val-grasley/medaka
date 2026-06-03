(* Shared helpers for the thorough test suite.
   Pattern mirrors test/test_typecheck.ml and test/test_eval.ml: every
   assertion embeds the source on failure so diagnosis doesn't require
   re-running the test by hand. *)

open Medaka_lib

(* ── Shared parse ───────────────────────────────────────────────────────── *)

let parse src =
  Lexer.reset ();
  let lexbuf = Lexing.from_string src in
  try Parser.program Lexer.token lexbuf
  with Parser.Error ->
    let pos = lexbuf.Lexing.lex_curr_p in
    failwith
      (Printf.sprintf "Parse error at line %d col %d in:\n%s"
         pos.Lexing.pos_lnum
         (pos.Lexing.pos_cnum - pos.Lexing.pos_bol)
         src)

(* ── Typecheck helpers ──────────────────────────────────────────────────── *)

let check src =
  try Ok (fst (Typecheck.check_program (Desugar.desugar_program (parse src))))
  with Typecheck.Type_error (e, _) -> Error e

let check_with_warns src =
  try Ok (Typecheck.check_program (Desugar.desugar_program (parse src)))
  with Typecheck.Type_error (e, _) -> Error e

(* assert_type src name expected — check that `name` in `src` types as `expected` *)
let assert_type src name expected () =
  match check src with
  | Error e ->
    failwith
      (Printf.sprintf
         "Expected program to type-check, but got error:\n  %s\n\nSource:\n%s"
         (Typecheck.pp_error e) src)
  | Ok env ->
    let actual =
      try Typecheck.pp_scheme (List.assoc name env)
      with Not_found ->
        failwith
          (Printf.sprintf "Name %s not in env. Env contains: %s" name
             (String.concat ", " (List.map fst env)))
    in
    if actual <> expected then
      failwith
        (Printf.sprintf
           "Expected type for %s:\n  %s\nGot:\n  %s\n\nSource:\n%s" name
           expected actual src)

(* assert_err src — check that src fails to type-check *)
let assert_err src () =
  match check src with
  | Error _ -> ()
  | Ok env ->
    let summary =
      String.concat ", "
        (List.map (fun (n, s) -> n ^ " : " ^ Typecheck.pp_scheme s) env)
    in
    failwith
      (Printf.sprintf
         "Expected type error, but program type-checked.\n\nEnv: %s\n\nSource:\n%s"
         summary src)

(* assert_err_matches src substr — check that src fails with an error message
   containing `substr`.  Useful for distinguishing UnificationError vs.
   UnboundVar vs. NoImplFound when they would all satisfy assert_err. *)
let assert_err_matches src substr () =
  match check src with
  | Ok _ ->
    failwith
      (Printf.sprintf "Expected type error containing %S, but program type-checked.\n\nSource:\n%s"
         substr src)
  | Error e ->
    let msg = Typecheck.pp_error e in
    let contains s sub =
      let ls = String.length s and lb = String.length sub in
      let rec loop i = i + lb <= ls && (String.sub s i lb = sub || loop (i+1)) in
      lb = 0 || loop 0
    in
    if not (contains msg substr) then
      failwith
        (Printf.sprintf
           "Expected error containing %S, got:\n  %s\n\nSource:\n%s"
           substr msg src)

(* assert_warns / assert_no_warns: drive exhaustiveness + redundancy checks *)
let assert_warns src () =
  match check_with_warns src with
  | Error e ->
    failwith
      (Printf.sprintf "Expected warnings, got type error:\n  %s\n\nSource:\n%s"
         (Typecheck.pp_error e) src)
  | Ok (_, []) ->
    failwith (Printf.sprintf "Expected warnings but got none.\nSource:\n%s" src)
  | Ok _ -> ()

let assert_no_warns src () =
  match check_with_warns src with
  | Error e ->
    failwith
      (Printf.sprintf "Expected no warnings, got type error:\n  %s\n\nSource:\n%s"
         (Typecheck.pp_error e) src)
  | Ok (_, []) -> ()
  | Ok (_, ws) ->
    failwith
      (Printf.sprintf "Expected no warnings, got %d:\n  %s\n\nSource:\n%s"
         (List.length ws) (String.concat "\n  " ws) src)

(* ── Eval helpers ───────────────────────────────────────────────────────── *)

open Eval

let run src name =
  let prog = Desugar.desugar_program (parse src) in
  let env = eval_program prog in
  match List.assoc_opt name env with
  | Some v -> v
  | None ->
    failwith
      (Printf.sprintf "Name '%s' not in env.\nEnv: %s\nSource:\n%s" name
         (String.concat ", " (List.map fst env))
         src)

(* Typed eval (Phase 69.x-c): return-position methods (`pure`, `when`,
   `unless`, derived/dispatched Show, …) need the impl the typechecker chose,
   stamped on their EMethodRef.  The untyped `run` above falls back to arg-tag
   "first impl wins" and so mis-dispatches `pure` (wraps in List, not the
   caller's monad).  This runner mirrors the real run-mode pipeline
   (mark → typecheck → dict-pass the marked prelude with user code → eval
   without re-prepending the raw prelude), exactly as test_eval.ml's run_typed. *)
let run_typed src name =
  let prog = Desugar.desugar_program (parse src) in
  (match Resolve.resolve_program prog with
   | [] -> ()
   | (err, _) :: _ -> failwith ("resolve error: " ^ Resolve.pp_error err));
  let (_marked, combined, _schemes, _warnings) = Elaborate.elaborate prog in
  let env = eval_program ~prelude:false combined in
  match List.assoc_opt name env with
  | Some v -> v
  | None ->
    failwith
      (Printf.sprintf "Name '%s' not in env.\nEnv: %s\nSource:\n%s" name
         (String.concat ", " (List.map fst env))
         src)

(* assert_val: check that name evaluates to expected *)
let assert_val src name expected () =
  let actual =
    try run src name
    with Eval_error (msg, _) ->
      failwith
        (Printf.sprintf "Expected %s = %s, got runtime error:\n  %s\n\nSource:\n%s"
           name (pp_value expected) msg src)
  in
  if actual <> expected then
    failwith
      (Printf.sprintf "Expected %s = %s\nGot: %s\n\nSource:\n%s" name
         (pp_value expected) (pp_value actual) src)

(* Like assert_val but through the typed pipeline (return-position dispatch). *)
let assert_val_typed src name expected () =
  let actual =
    try run_typed src name
    with Eval_error (msg, _) ->
      failwith
        (Printf.sprintf "Expected %s = %s, got runtime error:\n  %s\n\nSource:\n%s"
           name (pp_value expected) msg src)
  in
  if actual <> expected then
    failwith
      (Printf.sprintf "Expected %s = %s\nGot: %s\n\nSource:\n%s" name
         (pp_value expected) (pp_value actual) src)

(* assert_runtime_err: expect Eval_error during evaluation *)
let assert_runtime_err src name () =
  match try Some (run src name) with Eval_error _ -> None with
  | None -> ()
  | Some v ->
    failwith
      (Printf.sprintf "Expected runtime error, but got: %s\n\nSource:\n%s"
         (pp_value v) src)

(* assert_runtime_err_matches: expect Eval_error whose message contains substr *)
let assert_runtime_err_matches src name substr () =
  let contains s sub =
    let ls = String.length s and lb = String.length sub in
    let rec loop i = i + lb <= ls && (String.sub s i lb = sub || loop (i+1)) in
    lb = 0 || loop 0
  in
  match try Ok (run src name) with Eval_error (m, _) -> Error m with
  | Ok v ->
    failwith
      (Printf.sprintf "Expected runtime error containing %S, got: %s\n\nSource:\n%s"
         substr (pp_value v) src)
  | Error msg ->
    if not (contains msg substr) then
      failwith
        (Printf.sprintf "Expected error containing %S, got: %s\n\nSource:\n%s"
           substr msg src)

(* assert_stdout: capture program output via Eval.output_hook *)
let assert_stdout src expected () =
  let buf = Buffer.create 64 in
  let saved = !Eval.output_hook in
  Eval.output_hook := (fun s -> Buffer.add_string buf s);
  let cleanup () = Eval.output_hook := saved in
  (try
     let prog = Desugar.desugar_program (parse src) in
     let _ = eval_program prog in
     cleanup ()
   with e -> cleanup (); raise e);
  let actual = Buffer.contents buf in
  if actual <> expected then
    failwith
      (Printf.sprintf "Expected stdout:\n%s\nGot:\n%s\n\nSource:\n%s"
         expected actual src)

(* Round-trip helper: parse -> typecheck -> eval -> assert.
   Useful when you want a single source through the entire pipeline.  Evaluation
   uses the untyped `run` (arg-tag dispatch), which is correct for arg-position
   methods and named (`@Impl`) dispatch.  Tests that need *return-position*
   dispatch (`pure`, `when`, …) use assert_val_typed instead. *)
let assert_typed_val src name ty expected () =
  assert_type src name ty ();
  assert_val src name expected ()
