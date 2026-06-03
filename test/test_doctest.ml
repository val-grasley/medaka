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

(* Phase 92: write several named modules into one fresh temp dir and run the
   harness on [root], so the loader can find the siblings via the dir as its
   search root (the multi-module doctest path). *)
let with_tmp_modules (files : (string * string) list) root f =
  let dir = Filename.temp_file "test_doctest_dir" "" in
  Sys.remove dir;
  Sys.mkdir dir 0o755;
  let paths = List.map (fun (name, contents) ->
    let p = Filename.concat dir name in
    let oc = open_out p in
    output_string oc contents;
    close_out oc;
    p
  ) files in
  let cleanup () =
    List.iter (fun p -> try Sys.remove p with _ -> ()) paths;
    (try Sys.rmdir dir with _ -> ())
  in
  let result =
    (try f (Filename.concat dir root) with e -> cleanup (); raise e) in
  cleanup ();
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

(* Phase 92: a doctest whose result is a String renders via `debug`, which needs
   `Debug String`.  That impl now lives in the core prelude (moved from
   string.mdk), so the doctest resolves without importing `string`.  Before the
   move this errored ("No impl of Debug for String" → arg-tag fallback to
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

(* …and a Char result likewise (`Debug Char` also moved to core). *)
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
   two copies, which (in `medaka test stdlib/core.mdk`) made `debug` on a list
   element resolve to an ambiguous VMulti, sending `++` into the `append` method
   and looping forever.  Using the embedded `core.mdk` keeps this CWD-independent
   and in lock-step with the actual prelude (its `filter`/etc. examples render
   lists via `Debug (List a)`, exercising the constrained helper end-to-end). *)
let t_prelude_self_doctest_no_duplication () =
  with_tmp_file Prelude_content.core_mdk (fun path ->
    let r = Doctest.run_file path in
    if r.passed = 0 || r.failed <> 0 || r.errors <> 0 then
      failwith (Printf.sprintf
        "expected prelude self-doctest to pass cleanly (no prelude duplication), \
         got passed=%d failed=%d errors=%d" r.passed r.failed r.errors))

(* A sibling module exporting a type, a smart constructor, and a `Debug` impl.
   `widget` needs no imports of its own — the prelude (`Debug`/`Semigroup
   String`) is prepended in the multi-module typecheck. *)
let widget_module = {|export
data Widget = Widget Int

export
mkWidget : Int -> Widget
mkWidget n = Widget n

export
impl Debug Widget where
  debug (Widget n) = "W" ++ debug n
|}

(* Phase 92: a doctest in a file that imports a *real* sibling module resolves
   the sibling's `Debug Widget` instance through the multi-module typecheck path.
   The single-file path (file + prelude only) never loads `widget`, so the impl
   is invisible and the example would error. *)
let t_cross_module_instance_resolves () =
  let main = {|import widget.{mkWidget}
-- > debug (mkWidget 5)
-- "W5"
|} in
  with_tmp_modules [("widget.mdk", widget_module); ("main.mdk", main)] "main.mdk"
    (fun path ->
      let r = Doctest.run_file path in
      if r.passed <> 1 || r.failed <> 0 || r.errors <> 0 then
        failwith (Printf.sprintf
          "expected cross-module instance doctest to pass, got passed=%d failed=%d errors=%d"
          r.passed r.failed r.errors))

(* Phase 92: in the multi-module path a whole-file typecheck failure is reported
   honestly — the example ERRORs rather than silently degrading to arg-tag eval.
   Here `mkWidget` expects an Int but the doctest applies it to a String. *)
let t_cross_module_typecheck_failure_is_honest () =
  let main = {|import widget.{mkWidget}
-- > debug (mkWidget "oops")
-- "W?"
|} in
  with_tmp_modules [("widget.mdk", widget_module); ("main.mdk", main)] "main.mdk"
    (fun path ->
      let r = Doctest.run_file path in
      if r.errors <> 1 || r.passed <> 0 then
        failwith (Printf.sprintf
          "expected honest typecheck-failure error, got passed=%d failed=%d errors=%d"
          r.passed r.failed r.errors))

(* Phase 103 facet (a): a module that defines a nullary return-position method
   (Monoid-like `mt`) with a List-like impl declared FIRST, plus a standalone
   top-level binding shadowing the method name — mirroring array.mdk's
   `empty : Array a` next to `impl Monoid (Array a)`. The standalone is defined
   before the impls so the impl `VMulti` overwrites it at eval (as in array.mdk).
   A consumer importing the shadow binding used to instantiate the *shadow*
   scheme for the method occurrence, yielding param_vars=[] so route-stamping was
   skipped and `(mt : Box)` mis-dispatched to the first impl (the List-like one),
   producing a non-Box value. The annotation must select the `Box` impl. *)
let shadow_module = {|export
data Box = Box Int

export interface Sg a where
  appnd : a -> a -> a
export interface Mn a requires Sg a where
  mt : a

export
isBox : Box -> Bool
isBox (Box _) = True

export
mt : Box
mt = Box 0

export impl Sg (List a) where
  appnd x y = x ++ y
export impl Mn (List a) where
  mt = []

export impl Sg Box where
  appnd a b = a
export impl Mn Box where
  mt = Box 0
|}

let t_nullary_shadowed_method_routes_by_annotation () =
  let main = {|import shadow.{Box, isBox, mt}
-- > isBox (mt : Box)
-- True
|} in
  with_tmp_modules [("shadow.mdk", shadow_module); ("main.mdk", main)] "main.mdk"
    (fun path ->
      let r = Doctest.run_file path in
      if r.passed <> 1 || r.failed <> 0 || r.errors <> 0 then
        failwith (Printf.sprintf
          "expected annotated nullary method to route to the Box impl, got passed=%d failed=%d errors=%d"
          r.passed r.failed r.errors))

(* Phase 110: the doctest multi-module path (run_file_multi → eval_modules) must
   isolate same-named top-level functions per module.  `mapmod.singleton` is
   2-arg and called by `mapmod.wrap`; `arrmod.singleton` is 1-arg.  Under the old
   flat eval they merged and `wrap 3 4` panicked; per-module frames keep them
   distinct so both doctests pass. *)
let p110_mapmod = {|export
wrap : Int -> Int -> Int
wrap x y = singleton x y

export
singleton : Int -> Int -> Int
singleton x y = x + y
|}

let p110_arrmod = {|export
singleton : Int -> Int
singleton x = x * 100
|}

let t_module_isolation_doctest () =
  let main = {|import mapmod.{wrap}
import arrmod.{singleton}
-- > wrap 3 4
-- 7
-- > singleton 5
-- 500
|} in
  with_tmp_modules
    [("mapmod.mdk", p110_mapmod); ("arrmod.mdk", p110_arrmod); ("main.mdk", main)]
    "main.mdk"
    (fun path ->
      let r = Doctest.run_file path in
      if r.passed <> 2 || r.failed <> 0 || r.errors <> 0 then
        failwith (Printf.sprintf
          "expected per-module isolated doctests to pass, got passed=%d failed=%d errors=%d"
          r.passed r.failed r.errors))

(* Phase 126: the `medaka test` prop phase must reach names imported from sibling
   modules.  Both phases share `Doctest.assemble_marked_modules`; drive it through
   eval_modules → Prop_runner.run_all exactly as bin/main.ml's prop branch does. *)
let p126_helper = {|export
triple : Int -> Int
triple x = x + x + x
|}

let run_props_multi path =
  match Doctest.assemble_marked_modules path with
  | None -> failwith "expected multi-module load (>1 module)"
  | Some (_, Some msg) -> failwith ("unexpected typecheck error: " ^ msg)
  | Some (marked_modules, None) ->
    let eval_env = Eval.eval_modules_root_env marked_modules in
    let root_decls =
      match List.find_opt (fun (_, fp, _) -> fp = path) marked_modules with
      | Some (_, _, p) -> p
      | None -> failwith "root module not found in marked modules"
    in
    Prop_runner.run_all eval_env root_decls

let t_prop_imports_sibling_passes () =
  let main = {|import helper.{triple}
prop "triple is 3x" (x : Int) = triple x == x * 3
|} in
  with_tmp_modules
    [("helper.mdk", p126_helper); ("main.mdk", main)]
    "main.mdk"
    (fun path ->
      if not (run_props_multi path) then
        failwith "expected import-bearing prop to pass via the multi-module path")

let t_prop_imports_sibling_falsifiable () =
  let main = {|import helper.{triple}
prop "triple equals identity (false)" (x : Int) = triple x == x
|} in
  with_tmp_modules
    [("helper.mdk", p126_helper); ("main.mdk", main)]
    "main.mdk"
    (fun path ->
      if run_props_multi path then
        failwith "expected falsifiable import-bearing prop to fail")

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
      Alcotest.test_case "cross-module instance (Phase 92)" `Quick t_cross_module_instance_resolves;
      Alcotest.test_case "cross-module tc failure honest (Phase 92)" `Quick t_cross_module_typecheck_failure_is_honest;
      Alcotest.test_case "nullary method routes by annotation (Phase 103a)" `Quick t_nullary_shadowed_method_routes_by_annotation;
      Alcotest.test_case "per-module eval isolation (Phase 110)" `Quick t_module_isolation_doctest;
      Alcotest.test_case "prop imports sibling passes (Phase 126)" `Quick t_prop_imports_sibling_passes;
      Alcotest.test_case "prop imports sibling falsifiable (Phase 126)" `Quick t_prop_imports_sibling_falsifiable;
    ];
  ]
