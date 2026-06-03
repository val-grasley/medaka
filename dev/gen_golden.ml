(* dev/gen_golden.ml — regenerate golden files for the differential-testing harness.
   Usage: ./_build/default/dev/gen_golden.exe [fixture_dir]
   Default fixture_dir: test/diff_fixtures (relative to cwd)

   For each *.mdk in fixture_dir, writes <name>.golden with three sections:
     === AST ===   canonical round-trip of the parsed AST
     === TYPES === alphabetically-sorted top-level type schemes
     === EVAL ===  captured stdout from the typed eval pipeline *)

open Medaka_lib

let parse src =
  Lexer.reset ();
  let lb = Lexing.from_string src in
  try Parser.program Lexer.token lb
  with Parser.Error ->
    let pos = lb.Lexing.lex_curr_p in
    failwith (Printf.sprintf "Parse error at %d:%d"
      pos.Lexing.pos_lnum (pos.Lexing.pos_cnum - pos.Lexing.pos_bol))

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let buf = Bytes.create n in
  really_input ic buf 0 n;
  close_in ic;
  Bytes.to_string buf

let capture_stdout f =
  let buf = Buffer.create 256 in
  let saved = !Eval.output_hook in
  Eval.output_hook := Buffer.add_string buf;
  (try f () with e -> Eval.output_hook := saved; raise e);
  Eval.output_hook := saved;
  Buffer.contents buf

(* Strip trailing newlines so section content is stored consistently. *)
let rstrip_nl s =
  let n = String.length s in
  let i = ref (n - 1) in
  while !i >= 0 && s.[!i] = '\n' do decr i done;
  if !i = n - 1 then s else String.sub s 0 (!i + 1)

let generate_golden src_file =
  let golden_file = Filename.remove_extension src_file ^ ".golden" in
  let src = read_file src_file in

  (* ── Tokens section: raw lexer token stream (one per line) ───────────── *)
  let tokens_str = String.concat "\n" (Lexer.tokenize_string src) in

  (* ── AST section: parse only → canonical round-trip printer ─────────── *)
  let ast_str =
    let decls = parse src in
    rstrip_nl (Printer.program_to_string decls)
  in

  (* ── Types section: desugar → check_program → alphabetic type env ───── *)
  let types_str =
    let prog = Desugar.desugar_program (parse src) in
    let (env, _warnings) =
      try Typecheck.check_program prog
      with Typecheck.Type_error (e, _) ->
        failwith ("type error: " ^ Typecheck.pp_error e)
    in
    env
    |> List.filter (fun (n, _) ->
        String.length n > 0 && n.[0] <> '$' && not (String.length n > 4 && String.sub n 0 4 = "__dt"))
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
    |> List.map (fun (n, s) -> n ^ " : " ^ Typecheck.pp_scheme s)
    |> String.concat "\n"
  in

  (* ── Eval section: elaborate → eval ~prelude:false ───────────────────── *)
  let eval_str =
    let prog = Desugar.desugar_program (parse src) in
    let (_marked, combined, _schemes, _warnings) =
      try Elaborate.elaborate prog
      with Typecheck.Type_error (e, _) ->
        failwith ("elaborate error: " ^ Typecheck.pp_error e)
    in
    capture_stdout (fun () ->
      ignore (Eval.eval_program ~prelude:false combined)
    )
  in

  let oc = open_out golden_file in
  Printf.fprintf oc
    "=== TOKENS ===\n%s\n=== AST ===\n%s\n=== TYPES ===\n%s\n=== EVAL ===\n%s\n"
    tokens_str ast_str types_str (rstrip_nl eval_str);
  close_out oc;
  Printf.printf "  wrote %s\n%!" (Filename.basename golden_file)

let () =
  let dir =
    if Array.length Sys.argv > 1 then Sys.argv.(1)
    else "test/diff_fixtures"
  in
  Printf.printf "Generating golden files in %s/\n%!" dir;
  let entries = Sys.readdir dir in
  Array.sort String.compare entries;
  let errors = ref 0 in
  Array.iter (fun name ->
    if Filename.check_suffix name ".mdk" then begin
      let path = Filename.concat dir name in
      (try generate_golden path
       with Failure msg ->
         Printf.eprintf "ERROR in %s: %s\n%!" name msg;
         incr errors)
    end
  ) entries;
  if !errors > 0 then
    (Printf.eprintf "%d fixture(s) failed\n%!" !errors; exit 1)
  else
    Printf.printf "Done.\n%!"
