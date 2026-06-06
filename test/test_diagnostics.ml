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
                    ~read:no_override () in
    let dm = diags_for results main in
    let dd = diags_for results dep in
    if dm <> [] || dd <> [] then
      failwith (Printf.sprintf
        "Expected clean, got:\n%s" (pp_results results))
  )

(* Regression for `medaka check --json` on a file with `import`s (Phase 82
   follow-up): the single-file `analyze` path spuriously reports the imported
   name as unbound, while `analyze_project` — which the CLI's --json path now
   routes through — resolves the import and reports nothing.  Captures the exact
   bug the CLI rewrite fixed. *)
let t_check_json_imports_resolve () =
  with_tmp_dir (fun dir ->
    let _dep = write_file dir "dep.mdk" "export double x = x * 2\n" in
    let main_src =
      "import dep.{double}\nmain : <IO> Unit\nmain = print (double 3)\n" in
    let main = write_file dir "main.mdk" main_src in
    (* Precondition: the old single-file path spuriously errors on the import
       (use the unshadowed Diagnostics.analyze). *)
    let single = Diagnostics.analyze ~file:main ~source:main_src in
    if not (List.exists (fun d -> is_error d && msg_contains "double" d) single)
    then
      failwith (Printf.sprintf
        "precondition: expected single-file analyze to spuriously error on the \
         import, got: [%s]"
        (String.concat "; " (List.map pp_diagnostic single)));
    (* Fix: the multi-file path the CLI now uses resolves the import cleanly. *)
    let results =
      analyze_project ~root_file:main ~project_dir:dir ~read:no_override () in
    let dm = diags_for results main in
    if List.exists is_error dm then
      failwith (Printf.sprintf
        "expected clean multi-file analysis of an import-bearing file, got:\n%s"
        (pp_results results)))

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
                    ~read:no_override () in
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
                    ~read:no_override () in
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
                    ~read:no_override () in
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
                    ~read () in
    let dm = diags_for results main_path in
    let dd = diags_for results dep_path in
    if dm <> [] || dd <> [] then
      failwith (Printf.sprintf
        "Expected clean with override, got:\n%s" (pp_results results))
  )

(* ── Pathological inputs: no exception escapes ──

   The LSP runs `analyze` and `analyze_project` on every keystroke, so an
   uncaught exception kills the language server.  These tests feed a small
   corpus of malformed/edge-case sources through both entry points and
   assert that they return a diagnostic list without raising. *)

let pathological_sources = [
  "empty", "";
  "whitespace only", "   \n\n   \n";
  "unterminated string", "f = \"hello";
  "unterminated interpolation", "f = \"hi ${1 + ";
  "unterminated nested interp", "f = \"a${\"b${1";
  "deeply nested parens", "f = " ^ String.make 200 '(' ^ "1" ^ String.make 200 ')';
  "unmatched open paren", "f = (1 + 2";
  "unmatched close paren", "f = 1 + 2)";
  "unmatched open brace", "f = { x = 1";
  "unmatched open bracket", "f = [1, 2, 3";
  "random punctuation", "@#$%^&*~`?!|\\";
  "lone backslash", "\\";
  "null bytes", "f = \x00\x00\x00";
  "high-bit bytes", "f = \xff\xfe\xfd";
  "very long ident",
    "f = " ^ String.make 5000 'a';
  "many decls all broken",
    String.concat "\n" (List.init 50 (fun i ->
      Printf.sprintf "f%d = nope%d +" i i));
  "mismatched indent", "f x =\n    1\n  2\n      3\n 4\n";
  "tabs and spaces mixed", "f x =\n\t  1\n  \t2\n";
  "trailing operator", "f x = x +\n";
  "leading operator", "f = + 1\n";
  "comment unterminated", "(* this never closes\nf = 1\n";
  "binding with no body", "f =\n";
  "import malformed", "import ...\nf = 1\n";
  "double equals", "f == 1\n";
  "unicode salad", "f = \xe2\x98\x83\xe2\x9c\xa8";  (* ☃✨ *)
]

let t_analyze_no_escape () =
  List.iter (fun (label, src) ->
    try
      let _ : diagnostic list = analyze src in
      ()
    with e ->
      failwith (Printf.sprintf
        "analyze raised on %S: %s\nSource:\n%s"
        label (Printexc.to_string e) src)
  ) pathological_sources

let t_analyze_project_no_escape () =
  List.iter (fun (label, src) ->
    with_tmp_dir (fun dir ->
      let path = write_file dir "main.mdk" src in
      try
        let _ : (string * diagnostic list) list =
          analyze_project ~root_file:path ~project_dir:dir ~read:no_override ()
        in
        ()
      with e ->
        failwith (Printf.sprintf
          "analyze_project raised on %S: %s\nSource:\n%s"
          label (Printexc.to_string e) src)
    )
  ) pathological_sources

(* Cyclic imports with malformed sources — combines two failure modes. *)
let t_cyclic_with_garbage_no_escape () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "a.mdk" "import b.{y}\nexport x = ((( nope\n" in
    let b = write_file dir "b.mdk" "import a.{x}\nexport y = \"unterminated\n" in
    try
      let _ = analyze_project ~root_file:b ~project_dir:dir ~read:no_override () in
      ()
    with e ->
      failwith (Printf.sprintf
        "analyze_project raised on cycle+garbage: %s"
        (Printexc.to_string e))
  )

(* ── Last-good-source cache ──────────────────

   When the active buffer currently has a parse error but [last_good_source]
   has a prior parseable version, [analyze_project] substitutes the cached
   source for Loader so downstream stages keep producing useful diagnostics.
   The actual parse error is still reported on the file being edited. *)

let t_cache_fallback_single_file () =
  with_tmp_dir (fun dir ->
    let path = write_file dir "main.mdk" "f = 1\n" in
    let cache : (string, string) Hashtbl.t = Hashtbl.create 1 in

    (* Round 1: valid buffer — populates cache. *)
    let read_valid p =
      if p = path then Some "f = 1\n" else None
    in
    let r1 = analyze_project ~root_file:path ~project_dir:dir
               ~read:read_valid ~last_good_source:cache () in
    let d1 = diags_for r1 path in
    if d1 <> [] then
      failwith (Printf.sprintf
        "Round 1 expected clean, got:\n%s" (pp_results r1));
    if not (Hashtbl.mem cache path) then
      failwith "Cache not populated after clean parse";

    (* Round 2: broken buffer, warm cache.
       Expect: parse-error diagnostic on the file, NO internal-error
       diagnostic (the substitution kept Loader happy). *)
    let read_broken p =
      if p = path then Some "f =" else None
    in
    let r2 = analyze_project ~root_file:path ~project_dir:dir
               ~read:read_broken ~last_good_source:cache () in
    let d2 = diags_for r2 path in
    if not (List.exists (fun d ->
      is_error d && msg_contains "Parse" d) d2) then
      failwith (Printf.sprintf
        "Round 2 expected parse error, got:\n%s" (pp_results r2));
    if List.exists (fun d ->
      msg_contains "Internal error" d) d2 then
      failwith (Printf.sprintf
        "Round 2 should not have internal-error diag, got:\n%s"
        (pp_results r2))
  )

let t_cache_preserves_cross_file_diags () =
  with_tmp_dir (fun dir ->
    let dep_path  = Filename.concat dir "dep.mdk"  in
    let main_path = Filename.concat dir "main.mdk" in
    let _ = write_file dir "dep.mdk"
              "export double x = x * 2\n" in
    let _ = write_file dir "main.mdk"
              "import dep.{double}\nfoo = double 3\nbar = nope\n" in
    let cache : (string, string) Hashtbl.t = Hashtbl.create 2 in

    (* Round 1: both valid (but main references `nope`).  Cache populates,
       and main gets its Unbound diagnostic. *)
    let read_valid p =
      if p = dep_path  then Some "export double x = x * 2\n"
      else if p = main_path then
        Some "import dep.{double}\nfoo = double 3\nbar = nope\n"
      else None
    in
    let r1 = analyze_project ~root_file:main_path ~project_dir:dir
               ~read:read_valid ~last_good_source:cache () in
    let dm1 = diags_for r1 main_path in
    let has_nope_unbound ds =
      List.exists (fun d ->
        is_error d && msg_contains "Unbound" d && msg_contains "nope" d
      ) ds
    in
    if not (has_nope_unbound dm1) then
      failwith (Printf.sprintf
        "Round 1 expected Unbound 'nope' on main, got:\n%s"
        (pp_results r1));

    (* Round 2: dep buffer is now broken (parse error); cache still has
       the parseable version.  Expect:
       - dep gets its parse-error diagnostic
       - main's existing Unbound 'nope' diagnostic still appears
       - main does NOT get a spurious 'Unknown module dep' cascade *)
    let read_broken_dep p =
      if p = dep_path  then Some "export double x = x *"  (* parse error *)
      else if p = main_path then
        Some "import dep.{double}\nfoo = double 3\nbar = nope\n"
      else None
    in
    let r2 = analyze_project ~root_file:main_path ~project_dir:dir
               ~read:read_broken_dep ~last_good_source:cache () in
    let dd2 = diags_for r2 dep_path in
    let dm2 = diags_for r2 main_path in
    if not (List.exists (fun d ->
      is_error d && msg_contains "Parse" d) dd2) then
      failwith (Printf.sprintf
        "Round 2 expected parse error on dep, got:\n%s" (pp_results r2));
    if not (has_nope_unbound dm2) then
      failwith (Printf.sprintf
        "Round 2 expected main's Unbound 'nope' to still appear, got:\n%s"
        (pp_results r2));
    if List.exists (fun d ->
      msg_contains "Unknown module" d || msg_contains "Internal error" d
    ) dm2 then
      failwith (Printf.sprintf
        "Round 2 main should not have cascade/internal errors, got:\n%s"
        (pp_results r2))
  )

let t_cache_no_entry_no_crash () =
  with_tmp_dir (fun dir ->
    let path = write_file dir "main.mdk" "f =" in  (* broken on disk *)
    let cache : (string, string) Hashtbl.t = Hashtbl.create 1 in
    let read p = if p = path then Some "f =" else None in
    try
      let _ = analyze_project ~root_file:path ~project_dir:dir
                ~read ~last_good_source:cache () in
      ()
    with e ->
      failwith (Printf.sprintf
        "analyze_project raised with empty cache + broken source: %s"
        (Printexc.to_string e))
  )

(* Parse error in a dependency file (with no last-good cache) is reported
   as a proper parse diagnostic attributed to the dep — not as a generic
   "Internal error in loader". *)
let t_project_parse_error_in_dep () =
  with_tmp_dir (fun dir ->
    let dep_path = write_file dir "dep.mdk" "export broken = (" in
    let main_path = write_file dir "main.mdk"
      "import dep.{broken}\nmain = broken\n"
    in
    let results = analyze_project ~root_file:main_path ~project_dir:dir
                    ~read:no_override () in
    let dd = diags_for results dep_path in
    if not (List.exists (fun d ->
      is_error d && msg_contains "Parse" d) dd) then
      failwith (Printf.sprintf
        "Expected parse-error diagnostic on dep, got:\n%s" (pp_results results));
    List.iter (fun (_, ds) ->
      List.iter (fun d ->
        if msg_contains "Internal error" d then
          failwith (Printf.sprintf
            "Unexpected internal-error diagnostic:\n%s" (pp_results results))
      ) ds
    ) results
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
      test_case "imports resolve (check --json)" `Quick t_check_json_imports_resolve;
      test_case "error in dep"        `Quick t_project_error_in_dep;
      test_case "unknown module"      `Quick t_project_unknown_module;
      test_case "cyclic dependency"   `Quick t_project_cycle;
      test_case "buffered override"   `Quick t_project_buffered_override;
      test_case "parse error in dep"  `Quick t_project_parse_error_in_dep;
    ];
    "resilience", [
      test_case "analyze: no exception escapes"
        `Quick t_analyze_no_escape;
      test_case "analyze_project: no exception escapes"
        `Quick t_analyze_project_no_escape;
      test_case "cyclic + garbage: no exception escapes"
        `Quick t_cyclic_with_garbage_no_escape;
    ];
    "last-good-source", [
      test_case "fallback on single file"
        `Quick t_cache_fallback_single_file;
      test_case "preserves cross-file diagnostics"
        `Quick t_cache_preserves_cross_file_diags;
      test_case "empty cache: no crash"
        `Quick t_cache_no_entry_no_crash;
    ];
  ]
