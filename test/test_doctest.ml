open Medaka_lib

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let mk_comment line text : Lexer.comment =
  { c_line = line; c_col = 0; c_text = text }

let with_tmp_file contents f =
  let path = Filename.temp_file "test_doctest" ".mdk" in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  let result = (try f path with e -> Sys.remove path; raise e) in
  Sys.remove path;
  result

(* ── Extraction unit tests ───────────────────────────────────────────────── *)

let t_no_doctests () =
  let comments = [mk_comment 1 "-- hello"; mk_comment 2 "-- world"] in
  let result = Doctest.extract_doctests "f.mdk" comments in
  if result <> [] then failwith "expected no doctests from prose comments"

let t_single_input_no_expected () =
  let comments = [mk_comment 5 "-- > 1 + 1"] in
  let result = Doctest.extract_doctests "f.mdk" comments in
  match result with
  | [{ dt_examples = [ex]; _ }] ->
    if ex.input <> "1 + 1" then failwith ("wrong input: " ^ ex.input);
    if ex.expected <> None then failwith "expected None";
    if ex.src_line <> 5 then failwith (Printf.sprintf "wrong line: %d" ex.src_line)
  | _ -> failwith (Printf.sprintf "expected 1 doctest with 1 example, got %d" (List.length result))

let t_input_with_expected () =
  let comments = [mk_comment 3 "-- > 1 + 1"; mk_comment 4 "-- 2"] in
  let result = Doctest.extract_doctests "f.mdk" comments in
  match result with
  | [{ dt_examples = [ex]; _ }] ->
    if ex.input <> "1 + 1" then failwith ("wrong input: " ^ ex.input);
    if ex.expected <> Some "2" then failwith "expected Some \"2\""
  | _ -> failwith "expected 1 doctest with 1 example"

let t_multiline_expected () =
  let comments = [
    mk_comment 3 "-- > myTuple";
    mk_comment 4 "-- (1,";
    mk_comment 5 "-- 2)";
  ] in
  let result = Doctest.extract_doctests "f.mdk" comments in
  match result with
  | [{ dt_examples = [ex]; _ }] ->
    if ex.expected <> Some "(1,\n2)" then
      failwith (Printf.sprintf "wrong expected: %s"
                  (match ex.expected with None -> "None" | Some s -> s))
  | _ -> failwith "expected 1 doctest with 1 example"

let t_two_consecutive_pairs () =
  let comments = [
    mk_comment 3 "-- > 1 + 1";
    mk_comment 4 "-- 2";
    mk_comment 5 "-- > 2 + 2";
    mk_comment 6 "-- 4";
  ] in
  let result = Doctest.extract_doctests "f.mdk" comments in
  match result with
  | [{ dt_examples = [ex1; ex2]; _ }] ->
    if ex1.input <> "1 + 1" then failwith ("wrong first input: " ^ ex1.input);
    if ex1.expected <> Some "2" then failwith "wrong first expected";
    if ex2.input <> "2 + 2" then failwith ("wrong second input: " ^ ex2.input);
    if ex2.expected <> Some "4" then failwith "wrong second expected"
  | _ ->
    failwith (Printf.sprintf "expected 1 doctest with 2 examples, got %d doctests" (List.length result))

let t_gap_creates_two_groups () =
  let comments = [
    mk_comment 3 "-- > 1 + 1";
    mk_comment 4 "-- 2";
    (* gap: line 7 is not adjacent to line 4 *)
    mk_comment 7 "-- > 3 + 3";
    mk_comment 8 "-- 6";
  ] in
  let result = Doctest.extract_doctests "f.mdk" comments in
  if List.length result <> 2 then
    failwith (Printf.sprintf "expected 2 doctest groups, got %d" (List.length result))

let t_blank_comment_ends_block () =
  let comments = [
    mk_comment 3 "-- > 1 + 1";
    mk_comment 4 "-- 2";
    mk_comment 5 "--";             (* blank comment line *)
    mk_comment 6 "-- > 3 + 3";
    mk_comment 7 "-- 6";
  ] in
  let result = Doctest.extract_doctests "f.mdk" comments in
  if List.length result <> 2 then
    failwith (Printf.sprintf "expected 2 groups (blank splits them), got %d" (List.length result))

let t_prose_before_input_ignored () =
  let comments = [
    mk_comment 1 "-- Some prose";
    mk_comment 2 "-- more prose";
    mk_comment 3 "-- > 1 + 1";
    mk_comment 4 "-- 2";
  ] in
  let result = Doctest.extract_doctests "f.mdk" comments in
  match result with
  | [{ dt_examples = [ex]; _ }] ->
    if ex.input <> "1 + 1" then failwith ("wrong input: " ^ ex.input);
    if ex.expected <> Some "2" then failwith "wrong expected"
  | _ -> failwith (Printf.sprintf "expected 1 doctest with 1 example, got %d" (List.length result))

(* A block comment is captured by the lexer as one record with embedded
   newlines; the extractor expands it so inner `> expr`/result lines become
   doctests, and the leading `| prose` and blank line are ignored. *)
let t_block_comment_extraction () =
  let text = "{- | double it.\n\n   > 1 + 1\n   2\n-}" in
  let comments = [mk_comment 3 text] in
  let result = Doctest.extract_doctests "f.mdk" comments in
  match result with
  | [{ dt_examples = [ex]; _ }] ->
    if ex.input <> "1 + 1" then failwith ("wrong input: " ^ ex.input);
    if ex.expected <> Some "2" then
      failwith (Printf.sprintf "wrong expected: %s"
                  (match ex.expected with None -> "None" | Some s -> s))
  | _ ->
    failwith (Printf.sprintf "expected 1 example from block comment, got %d groups"
                (List.length result))

let t_block_comment_two_examples () =
  let text = "{-\n   > 1 + 1\n   2\n   > 2 + 2\n   4\n-}" in
  let comments = [mk_comment 10 text] in
  let result = Doctest.extract_doctests "f.mdk" comments in
  match result with
  | [{ dt_examples = [ex1; ex2]; _ }] ->
    if ex1.expected <> Some "2" then failwith "wrong first expected";
    if ex2.input <> "2 + 2" then failwith ("wrong second input: " ^ ex2.input)
  | _ ->
    failwith (Printf.sprintf "expected 1 group with 2 examples, got %d groups"
                (List.length result))

(* ── Integration tests ───────────────────────────────────────────────────── *)

let t_all_pass () =
  let src = {|-- > 1 + 2
-- 3
x = 42
|} in
  with_tmp_file src (fun path ->
    let r = Doctest.run_file path in
    if r.passed <> 1 || r.failed <> 0 then
      failwith (Printf.sprintf "expected 1 pass, got passed=%d failed=%d"
                  r.passed r.failed))

let t_one_fail () =
  let src = {|-- > 1 + 2
-- 99
x = 42
|} in
  with_tmp_file src (fun path ->
    let r = Doctest.run_file path in
    if r.failed <> 1 then
      failwith (Printf.sprintf "expected 1 failure, got %d" r.failed))

let t_references_file_binding () =
  let src = {|double x = x * 2
-- > double 5
-- 10
|} in
  with_tmp_file src (fun path ->
    let r = Doctest.run_file path in
    if r.passed <> 1 || r.failed <> 0 then
      failwith (Printf.sprintf "expected pass using file binding, got passed=%d failed=%d"
                  r.passed r.failed))

(* Phase 92: a doctest whose result is a String renders via `show`, which needs
   `Show String`.  That impl now lives in the core prelude (moved from
   string.mdk), so the doctest resolves without importing `string`.  Before the
   move this errored ("No impl of Show for String" → arg-tag fallback to
   intToString), and the all-or-nothing harness failed every example. *)
let t_string_result_resolves () =
  let src = {|greet name = "hi " ++ name
-- > greet "bob"
-- "hi bob"
|} in
  with_tmp_file src (fun path ->
    let r = Doctest.run_file path in
    if r.passed <> 1 || r.failed <> 0 || r.errors <> 0 then
      failwith (Printf.sprintf
        "expected String-result doctest to pass, got passed=%d failed=%d errors=%d"
        r.passed r.failed r.errors))

(* …and a Char result likewise (`Show Char` also moved to core). *)
let t_char_result_resolves () =
  let src = {|first c = c
-- > first 'a'
-- 'a'
|} in
  with_tmp_file src (fun path ->
    let r = Doctest.run_file path in
    if r.passed <> 1 || r.failed <> 0 || r.errors <> 0 then
      failwith (Printf.sprintf
        "expected Char-result doctest to pass, got passed=%d failed=%d errors=%d"
        r.passed r.failed r.errors))

let t_no_expected_passes () =
  let src = {|-- > 1 + 2
x = 42
|} in
  with_tmp_file src (fun path ->
    let r = Doctest.run_file path in
    if r.passed <> 1 then
      failwith (Printf.sprintf "expected 1 pass (no expected = crash-free), got %d" r.passed))

let t_block_comment_run () =
  let src = "double x = x * 2\n{- | doubles its argument.\n\n   > double 5\n   10\n-}\n" in
  with_tmp_file src (fun path ->
    let r = Doctest.run_file path in
    if r.passed <> 1 || r.failed <> 0 then
      failwith (Printf.sprintf "expected block-comment doctest to pass, got passed=%d failed=%d errors=%d"
                  r.passed r.failed r.errors))

(* Phase 70: doctests now run mark + typecheck before eval, so a return-position
   method call with a result-type annotation dispatches to the impl the checker
   chose.  Without that, `decode` would fall back to "first impl wins" (String)
   and the example would evaluate to "S" instead of True. *)
let t_return_position_dispatch () =
  let src = {|interface Decode a where
  decode : Int -> a

impl Decode String where
  decode n = "S"

impl Decode Bool where
  decode n = n > 0

-- > (decode 1 : Bool)
-- True
|} in
  with_tmp_file src (fun path ->
    let r = Doctest.run_file path in
    if r.passed <> 1 || r.failed <> 0 then
      failwith (Printf.sprintf
        "expected return-position dispatch doctest to pass, got passed=%d failed=%d errors=%d"
        r.passed r.failed r.errors))

let t_parse_error_example () =
  let src = {|-- > let ??? broken
x = 0
|} in
  with_tmp_file src (fun path ->
    let r = Doctest.run_file path in
    if r.errors <> 1 then
      failwith (Printf.sprintf "expected 1 error for unparseable example, got %d" r.errors))

let t_no_doctests_in_file () =
  let src = {|-- just a comment
x = 42
|} in
  with_tmp_file src (fun path ->
    let r = Doctest.run_file path in
    if r.total <> 0 then
      failwith (Printf.sprintf "expected 0 doctests, got %d" r.total))

let t_multiple_examples () =
  let src = {|double x = x * 2
-- > double 3
-- 6
-- > double 0
-- 0
-- > double (-1)
-- -2
|} in
  with_tmp_file src (fun path ->
    let r = Doctest.run_file path in
    if r.total <> 3 || r.passed <> 3 then
      failwith (Printf.sprintf "expected 3 passes, got total=%d passed=%d"
                  r.total r.passed))

(* Smoke test for `medaka test stdlib/core.mdk`: the real prelude's own doctests
   must run cleanly through `Doctest.run_file` (the exact path the CLI uses).
   When the file under test is itself the prelude (`program_is_core` true) the
   harness must NOT prepend the prelude — doing so duplicates every top-level
   decl, and the prelude's top-level constrained `showListItems` helper then has
   two copies, which (in `medaka test stdlib/core.mdk`) made `show` on a list
   element resolve to an ambiguous VMulti, sending `++` into the `append` method
   and looping forever.  Using the embedded `core.mdk` keeps this CWD-independent
   and in lock-step with the actual prelude (its `filter`/etc. examples render
   lists via `Show (List a)`, exercising the constrained helper end-to-end). *)
let t_prelude_self_doctest_no_duplication () =
  with_tmp_file Prelude_content.core_mdk (fun path ->
    let r = Doctest.run_file path in
    if r.passed = 0 || r.failed <> 0 || r.errors <> 0 then
      failwith (Printf.sprintf
        "expected prelude self-doctest to pass cleanly (no prelude duplication), \
         got passed=%d failed=%d errors=%d" r.passed r.failed r.errors))

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "doctest" [
    "extraction", [
      Alcotest.test_case "no doctests"                `Quick t_no_doctests;
      Alcotest.test_case "single input no expected"   `Quick t_single_input_no_expected;
      Alcotest.test_case "input with expected"        `Quick t_input_with_expected;
      Alcotest.test_case "multiline expected"         `Quick t_multiline_expected;
      Alcotest.test_case "two consecutive pairs"      `Quick t_two_consecutive_pairs;
      Alcotest.test_case "gap creates two groups"     `Quick t_gap_creates_two_groups;
      Alcotest.test_case "blank comment ends block"   `Quick t_blank_comment_ends_block;
      Alcotest.test_case "prose before input ignored" `Quick t_prose_before_input_ignored;
      Alcotest.test_case "block comment extraction"    `Quick t_block_comment_extraction;
      Alcotest.test_case "block comment two examples"  `Quick t_block_comment_two_examples;
    ];
    "runner", [
      Alcotest.test_case "all pass"                   `Quick t_all_pass;
      Alcotest.test_case "one fail"                   `Quick t_one_fail;
      Alcotest.test_case "references file binding"    `Quick t_references_file_binding;
      Alcotest.test_case "String result resolves (Phase 92)" `Quick t_string_result_resolves;
      Alcotest.test_case "Char result resolves (Phase 92)"   `Quick t_char_result_resolves;
      Alcotest.test_case "no expected = crash-free"   `Quick t_no_expected_passes;
      Alcotest.test_case "block comment doctest runs"  `Quick t_block_comment_run;
      Alcotest.test_case "return-position dispatch"   `Quick t_return_position_dispatch;
      Alcotest.test_case "prelude self-doctest no dup" `Quick t_prelude_self_doctest_no_duplication;
      Alcotest.test_case "parse error example"        `Quick t_parse_error_example;
      Alcotest.test_case "no doctests in file"        `Quick t_no_doctests_in_file;
      Alcotest.test_case "multiple examples"          `Quick t_multiple_examples;
    ];
  ]
