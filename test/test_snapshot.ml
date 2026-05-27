open Medaka_lib
open Eval

(* ── Helpers ──────────────────────────────────────────────────────────────── *)

let parse src =
  Lexer.reset ();
  let lexbuf = Lexing.from_string src in
  try Parser.program Lexer.token lexbuf
  with Parser.Error ->
    let pos = lexbuf.Lexing.lex_curr_p in
    failwith (Printf.sprintf "Parse error at %d:%d"
                pos.Lexing.pos_lnum (pos.Lexing.pos_cnum - pos.Lexing.pos_bol))

(* Run a Medaka program with snapshot_dir pointed at [dir] and
   snapshot_update set to [update]. Returns the value of the last top-level
   binding, or raises Eval_error on failure. *)
let run_in_dir ?(update = false) dir src =
  let saved_dir    = !snapshot_dir in
  let saved_update = !snapshot_update in
  snapshot_dir    := dir;
  snapshot_update := update;
  let result =
    try
      let prog = parse src in
      let _ = eval_program prog in
      Ok ()
    with
    | Eval_error (msg, _) -> Error msg
  in
  snapshot_dir    := saved_dir;
  snapshot_update := saved_update;
  result

let make_tmp_dir () =
  let path = Filename.temp_file "medaka_snap_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let read_snap dir name =
  let path = Filename.concat dir (name ^ ".snap") in
  In_channel.input_all (open_in path)

(* ── Tests ───────────────────────────────────────────────────────────────── *)

(* First call: no .snap file → file is created, call returns VUnit. *)
let t_snapshot_creates_on_first_run () =
  let tmp = make_tmp_dir () in
  let snap_dir = Filename.concat tmp "snapshots" in
  let src = {|main : <IO> Unit
main = assert_snapshot "first" "hello"
|} in
  (match run_in_dir snap_dir src with
   | Error msg -> failwith ("unexpected error: " ^ msg)
   | Ok () -> ());
  let stored = read_snap snap_dir "first" in
  if stored <> "hello" then
    failwith (Printf.sprintf "expected stored='hello', got=%S" stored)

(* Second call with same value: passes without modifying the file. *)
let t_snapshot_passes_on_match () =
  let tmp = make_tmp_dir () in
  let snap_dir = Filename.concat tmp "snapshots" in
  let src = {|main : <IO> Unit
main = assert_snapshot "match" "same"
|} in
  (* create *)
  (match run_in_dir snap_dir src with
   | Error msg -> failwith ("first run error: " ^ msg)
   | Ok () -> ());
  (* verify match *)
  (match run_in_dir snap_dir src with
   | Error msg -> failwith ("second run error: " ^ msg)
   | Ok () -> ())

(* Different value with existing snapshot → Eval_error raised. *)
let t_snapshot_fails_on_mismatch () =
  let tmp = make_tmp_dir () in
  let snap_dir = Filename.concat tmp "snapshots" in
  (* create snapshot with "old" *)
  let src_old = {|main : <IO> Unit
main = assert_snapshot "mismatch" "old"
|} in
  (match run_in_dir snap_dir src_old with
   | Error msg -> failwith ("create error: " ^ msg)
   | Ok () -> ());
  (* run with "new" — should fail *)
  let src_new = {|main : <IO> Unit
main = assert_snapshot "mismatch" "new"
|} in
  (match run_in_dir snap_dir src_new with
   | Ok () -> failwith "expected Eval_error for mismatch but got Ok"
   | Error msg ->
     if not (String.length msg > 0) then
       failwith "error message was empty")

(* update mode: mismatch → file is overwritten, call returns VUnit. *)
let t_snapshot_update_mode () =
  let tmp = make_tmp_dir () in
  let snap_dir = Filename.concat tmp "snapshots" in
  let src_v1 = {|main : <IO> Unit
main = assert_snapshot "upd" "v1"
|} in
  (match run_in_dir snap_dir src_v1 with
   | Error msg -> failwith ("create error: " ^ msg)
   | Ok () -> ());
  let src_v2 = {|main : <IO> Unit
main = assert_snapshot "upd" "v2"
|} in
  (* without update → error *)
  (match run_in_dir snap_dir src_v2 with
   | Ok () -> failwith "expected error without update flag"
   | Error _ -> ());
  (* with update → success and file is rewritten *)
  (match run_in_dir ~update:true snap_dir src_v2 with
   | Error msg -> failwith ("update error: " ^ msg)
   | Ok () -> ());
  let stored = read_snap snap_dir "upd" in
  if stored <> "v2" then
    failwith (Printf.sprintf "expected stored='v2', got=%S" stored)

(* Snapshot names with spaces/slashes become underscores in the filename. *)
let t_snapshot_name_sanitized () =
  let tmp = make_tmp_dir () in
  let snap_dir = Filename.concat tmp "snapshots" in
  let src = {|main : <IO> Unit
main = assert_snapshot "my value/test" "42"
|} in
  (match run_in_dir snap_dir src with
   | Error msg -> failwith ("error: " ^ msg)
   | Ok () -> ());
  (* should exist as my_value_test.snap *)
  let path = Filename.concat snap_dir "my_value_test.snap" in
  if not (Sys.file_exists path) then
    failwith (Printf.sprintf "expected file %s to exist" path)

(* Snapshot inside a doctest: assert_snapshot "..." (show x) => ()
   The doctest runner evaluates the expression and the result is VUnit,
   which prints as "()" — matching the expected line. *)
let t_snapshot_doctest_integration () =
  let tmp = make_tmp_dir () in
  let snap_dir = Filename.concat tmp "snapshots" in
  (* Write a .mdk source file *)
  let mdk_path = Filename.concat tmp "sample.mdk" in
  let mdk_src = {|greeting : String
greeting = "hello world"

-- > assert_snapshot "greet" greeting
-- ()
|} in
  let oc = open_out mdk_path in
  output_string oc mdk_src;
  close_out oc;
  let saved_dir    = !snapshot_dir in
  let saved_update = !snapshot_update in
  snapshot_dir    := snap_dir;
  snapshot_update := false;
  let result =
    try
      let r = Doctest.run_file mdk_path in
      Ok r
    with Failure msg -> Error msg
  in
  snapshot_dir    := saved_dir;
  snapshot_update := saved_update;
  match result with
  | Error msg -> failwith ("doctest run error: " ^ msg)
  | Ok r ->
    if r.Doctest.failed > 0 || r.Doctest.errors > 0 then
      failwith (Printf.sprintf "doctest failures: %d failed, %d errors"
                  r.Doctest.failed r.Doctest.errors)

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () = Alcotest.run "Snapshot"
  [("snapshot", [
    "creates on first run",   `Quick, t_snapshot_creates_on_first_run;
    "passes on match",        `Quick, t_snapshot_passes_on_match;
    "fails on mismatch",      `Quick, t_snapshot_fails_on_mismatch;
    "update mode",            `Quick, t_snapshot_update_mode;
    "name sanitized",         `Quick, t_snapshot_name_sanitized;
    "doctest integration",    `Quick, t_snapshot_doctest_integration;
  ])]
