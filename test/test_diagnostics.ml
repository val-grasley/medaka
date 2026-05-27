open Medaka_lib
open Diagnostics

let analyze src = analyze ~file:"<test>" ~source:src

let pp_diags ds =
  String.concat "\n  " (List.map pp_diagnostic ds)

(* ── Assertion helpers ─────────────────────────── *)

let assert_clean src () =
  let ds = analyze src in
  if ds <> [] then
    failwith (Printf.sprintf
      "Expected no diagnostics, got:\n  %s\n\nSource:\n%s"
      (pp_diags ds) src)

let assert_any pred src () =
  let ds = analyze src in
  if not (List.exists pred ds) then
    failwith (Printf.sprintf
      "Expected matching diagnostic, got:\n  %s\n\nSource:\n%s"
      (pp_diags ds) src)

let has_substr needle hay =
  let n = String.length needle and h = String.length hay in
  if n > h then false
  else
    let rec loop i =
      if i + n > h then false
      else if String.sub hay i n = needle then true
      else loop (i + 1)
    in loop 0

let msg_contains needle d = has_substr needle d.message
let is_error d = d.severity = Error

(* ── Single-file tests ─────────────────────────── *)

let t_clean_ok = assert_clean
  "f x = x + 1\nmain = f 5\n"

let t_parse_error = assert_any
  (fun d -> is_error d && msg_contains "Parse" d)
  "f x = x +\n"

let t_unbound_var = assert_any
  (fun d -> is_error d && msg_contains "Unbound" d)
  "f = nope\n"

let t_type_mismatch = assert_any
  (fun d -> is_error d && msg_contains "Type mismatch" d)
  "f : Int -> String\nf x = x + 1\n"

let t_multiple_resolve_errors () =
  let ds = analyze "f = nope1\ng = nope2\nh = nope3\n" in
  let errs = List.filter (fun d ->
    is_error d && msg_contains "Unbound" d) ds in
  if List.length errs < 3 then
    failwith (Printf.sprintf
      "Expected at least 3 unbound errors, got %d:\n  %s"
      (List.length errs) (pp_diags ds))

let t_loc_has_end () =
  let ds = analyze "f = nope\n" in
  match List.find_opt (fun d ->
    is_error d && msg_contains "Unbound" d) ds
  with
  | None -> failwith "Expected an Unbound error"
  | Some d ->
    if d.loc.end_line < d.loc.line ||
       (d.loc.end_line = d.loc.line && d.loc.end_col < d.loc.col) then
      failwith (Printf.sprintf
        "Diagnostic end position (%d:%d) precedes start (%d:%d)"
        d.loc.end_line d.loc.end_col d.loc.line d.loc.col)

(* ── Multi-file helpers ────────────────────────── *)

let with_tmp_dir f =
  let dir = Filename.temp_dir "medaka_diag_test_" "" in
  Fun.protect
    ~finally:(fun () ->
      (try
         let files = Sys.readdir dir in
         Array.iter (fun fn ->
           try Unix.unlink (Filename.concat dir fn) with _ -> ()
         ) files;
         Unix.rmdir dir
       with _ -> ()))
    (fun () -> f dir)

let write_file dir name content =
  let path = Filename.concat dir name in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  path

let no_override (_ : string) : string option = None

let diags_for results path =
  match List.assoc_opt path results with
  | Some ds -> ds
  | None ->
    failwith (Printf.sprintf
      "no entry for %s in results: [%s]"
      path
      (String.concat ", " (List.map fst results)))

let pp_results results =
  String.concat "\n" (List.map (fun (f, ds) ->
    Printf.sprintf "  %s: [%s]" f
      (String.concat "; " (List.map pp_diagnostic ds))
  ) results)

(* ── Multi-file tests ──────────────────────────── *)

(* Clean two-file project: both files return empty diag lists. *)
let t_project_clean () =
  with_tmp_dir (fun dir ->
    let dep = write_file dir "dep.mdk"
      "export double x = x * 2\n"
    in
    let main = write_file dir "main.mdk"
      "import dep.{double}\nmain : <IO> Unit\nmain = print (double 3)\n"
    in
    let results = analyze_project ~root_file:main ~project_dir:dir
                    ~read:no_override in
    let dm = diags_for results main in
    let dd = diags_for results dep in
    if dm <> [] || dd <> [] then
      failwith (Printf.sprintf
        "Expected clean, got:\n%s" (pp_results results))
  )

(* Error in dep file is bucketed under the dep path, not the root. *)
let t_project_error_in_dep () =
  with_tmp_dir (fun dir ->
    let dep = write_file dir "dep.mdk"
      "export broken = undefinedThing\n"
    in
    let main = write_file dir "main.mdk"
      "import dep.{broken}\nmain : <IO> Unit\nmain = print broken\n"
    in
    let results = analyze_project ~root_file:main ~project_dir:dir
                    ~read:no_override in
    let dd = diags_for results dep in
    if not (List.exists (fun d ->
      is_error d && msg_contains "Unbound" d) dd) then
      failwith (Printf.sprintf
        "Expected Unbound error on dep, got:\n%s" (pp_results results))
  )

(* Unknown module: diagnostic on root, loc points at import keyword. *)
let t_project_unknown_module () =
  with_tmp_dir (fun dir ->
    let main = write_file dir "main.mdk"
      "import nope.{foo}\nmain : <IO> Unit\nmain = print foo\n"
    in
    let results = analyze_project ~root_file:main ~project_dir:dir
                    ~read:no_override in
    let dm = diags_for results main in
    match List.find_opt (fun d ->
      is_error d && msg_contains "Unknown module" d) dm
    with
    | None -> failwith (Printf.sprintf
                "Expected Unknown module error, got:\n%s" (pp_results results))
    | Some d ->
      (* loc should point at the import line (line 1), not the dummy_loc. *)
      if d.loc.line <> 1 then
        failwith (Printf.sprintf
          "Expected loc on import line, got line %d" d.loc.line);
      if not (msg_contains "nope" d) then
        failwith (Printf.sprintf
          "Expected message to mention 'nope', got: %s" d.message)
  )

(* Cycle A↔B: emit a cycle diagnostic. *)
let t_project_cycle () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "a.mdk" "import b.{y}\nexport x = 1\n" in
    let b = write_file dir "b.mdk" "import a.{x}\nexport y = 2\n" in
    let results = analyze_project ~root_file:b ~project_dir:dir
                    ~read:no_override in
    let any_cycle =
      List.exists (fun (_, ds) ->
        List.exists (fun d -> msg_contains "Cyclic" d) ds
      ) results
    in
    if not any_cycle then
      failwith (Printf.sprintf
        "Expected cycle diagnostic, got:\n%s" (pp_results results))
  )

(* Buffer override: disk has broken source, override has clean source.
   Loader uses the override. *)
let t_project_buffered_override () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "dep.mdk"
      "export broken = undefinedThing\n"  (* disk: broken *)
    in
    let main_path = write_file dir "main.mdk"
      "import dep.{ok}\nresult = ok\n"
    in
    let dep_path = Filename.concat dir "dep.mdk" in
    let read path =
      if path = dep_path then
        Some "export ok = 42\n"   (* override: clean *)
      else None
    in
    let results = analyze_project ~root_file:main_path ~project_dir:dir
                    ~read in
    let dm = diags_for results main_path in
    let dd = diags_for results dep_path in
    if dm <> [] || dd <> [] then
      failwith (Printf.sprintf
        "Expected clean with override, got:\n%s" (pp_results results))
  )

(* ── Runner ─────────────────────────────────── *)

let () =
  let open Alcotest in
  run "Diagnostics" [
    "valid", [
      test_case "clean source"        `Quick t_clean_ok;
    ];
    "errors", [
      test_case "parse error"         `Quick t_parse_error;
      test_case "unbound variable"    `Quick t_unbound_var;
      test_case "type mismatch"       `Quick t_type_mismatch;
      test_case "multiple resolve"    `Quick t_multiple_resolve_errors;
      test_case "loc has end pos"     `Quick t_loc_has_end;
    ];
    "multi-file", [
      test_case "clean project"       `Quick t_project_clean;
      test_case "error in dep"        `Quick t_project_error_in_dep;
      test_case "unknown module"      `Quick t_project_unknown_module;
      test_case "cyclic dependency"   `Quick t_project_cycle;
      test_case "buffered override"   `Quick t_project_buffered_override;
    ];
  ]
