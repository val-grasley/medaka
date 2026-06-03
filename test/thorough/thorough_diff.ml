(* test/thorough/thorough_diff.ml — differential-testing harness (Phase 129).
   Validates that the OCaml reference pipeline produces output matching the
   committed golden files for each fixture in test/diff_fixtures/.

   Run standalone:
     DIFF_FIXTURES_DIR=test/diff_fixtures ./_build/default/test/thorough/thorough_diff.exe
   Run via @thorough alias (dune sets DIFF_FIXTURES_DIR automatically). *)

open Medaka_lib

(* ── pipeline helpers (mirrors gen_golden.ml) ─────────────────────────── *)

let parse src =
  Lexer.reset ();
  let lb = Lexing.from_string src in
  try Parser.program Lexer.token lb
  with Parser.Error ->
    let pos = lb.Lexing.lex_curr_p in
    failwith (Printf.sprintf "Parse error at %d:%d"
      pos.Lexing.pos_lnum (pos.Lexing.pos_cnum - pos.Lexing.pos_bol))

let capture_stdout f =
  let buf = Buffer.create 256 in
  let saved = !Eval.output_hook in
  Eval.output_hook := Buffer.add_string buf;
  (try f () with e -> Eval.output_hook := saved; raise e);
  Eval.output_hook := saved;
  Buffer.contents buf

let rstrip_nl s =
  let n = String.length s in
  let i = ref (n - 1) in
  while !i >= 0 && s.[!i] = '\n' do decr i done;
  if !i = n - 1 then s else String.sub s 0 (!i + 1)

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let buf = Bytes.create n in
  really_input ic buf 0 n;
  close_in ic;
  Bytes.to_string buf

(* ── section generator ────────────────────────────────────────────────── *)

let gen_tokens src =
  rstrip_nl (String.concat "\n" (Lexer.tokenize_string src))

let gen_ast src =
  let decls = parse src in
  rstrip_nl (Printer.program_to_string decls)

let gen_types src =
  let prog = Desugar.desugar_program (parse src) in
  let (env, _) = Typecheck.check_program prog in
  env
  |> List.filter (fun (n, _) ->
      String.length n > 0 && n.[0] <> '$'
      && not (String.length n > 4 && String.sub n 0 4 = "__dt"))
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  |> List.map (fun (n, s) -> n ^ " : " ^ Typecheck.pp_scheme s)
  |> String.concat "\n"

let gen_eval src =
  let prog = Desugar.desugar_program (parse src) in
  let (_marked, combined, _schemes, _warnings) = Elaborate.elaborate prog in
  let out = capture_stdout (fun () ->
    ignore (Eval.eval_program ~prelude:false combined)
  ) in
  rstrip_nl out

(* ── golden file parser ───────────────────────────────────────────────── *)

let is_header line =
  let n = String.length line in
  n >= 8 && String.sub line 0 4 = "=== " && String.sub line (n-4) 4 = " ==="

let header_name line = String.sub line 4 (String.length line - 8)

(* Returns (section_name, content) list; content has trailing newline stripped. *)
let split_sections content =
  let lines = String.split_on_char '\n' content in
  let result = ref [] in
  let cur_name = ref None in
  let cur_buf = Buffer.create 256 in
  let flush () =
    match !cur_name with
    | None -> ()
    | Some name ->
      let s = rstrip_nl (Buffer.contents cur_buf) in
      result := (name, s) :: !result;
      Buffer.clear cur_buf
  in
  List.iter (fun line ->
    if is_header line then begin
      flush ();
      cur_name := Some (header_name line)
    end else begin
      if !cur_name <> None then begin
        Buffer.add_string cur_buf line;
        Buffer.add_char cur_buf '\n'
      end
    end
  ) lines;
  flush ();
  List.rev !result

(* ── test builder ─────────────────────────────────────────────────────── *)

let make_fixture_tests fixture_dir mdk_name =
  let base = Filename.remove_extension mdk_name in
  let mdk_path = Filename.concat fixture_dir mdk_name in
  let golden_path = Filename.concat fixture_dir (base ^ ".golden") in

  let src = read_file mdk_path in
  let golden_content =
    if Sys.file_exists golden_path then read_file golden_path
    else failwith (Printf.sprintf "Missing golden file: %s" golden_path)
  in
  let expected = split_sections golden_content in

  let make_test section_name gen_fn =
    let expected_content =
      try List.assoc section_name expected
      with Not_found ->
        failwith (Printf.sprintf "Golden file %s missing section %s" base section_name)
    in
    Alcotest.test_case section_name `Quick (fun () ->
      let actual =
        try gen_fn src
        with exn -> failwith (Printf.sprintf "Pipeline error: %s" (Printexc.to_string exn))
      in
      if actual <> expected_content then
        Alcotest.fail
          (Printf.sprintf
             "Mismatch in %s / %s\n\nExpected:\n%s\n\nActual:\n%s"
             base section_name expected_content actual)
    )
  in

  ( base,
    [ make_test "TOKENS" gen_tokens
    ; make_test "AST"    gen_ast
    ; make_test "TYPES"  gen_types
    ; make_test "EVAL"   gen_eval
    ] )

let () =
  let fixture_dir =
    match Sys.getenv_opt "DIFF_FIXTURES_DIR" with
    | Some d -> d
    | None   -> "test/diff_fixtures"
  in
  let entries = Sys.readdir fixture_dir in
  Array.sort String.compare entries;
  let tests =
    Array.to_list entries
    |> List.filter (fun n -> Filename.check_suffix n ".mdk")
    |> List.map (make_fixture_tests fixture_dir)
  in
  Alcotest.run "diff" tests
