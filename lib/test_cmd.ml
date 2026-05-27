(* `medaka test` — run doctests from a source file or the project entry point. *)

let pp_result_line filename (ex : Doctest.example) (result : Doctest.example_result) =
  let loc = Printf.sprintf "%s:%d" filename ex.src_line in
  match result with
  | Doctest.Pass ->
    Printf.printf "  ok   %s: %s\n" loc ex.input
  | Doctest.Fail { expected; actual } ->
    Printf.printf "  FAIL %s: %s\n" loc ex.input;
    Printf.printf "       expected: %s\n" expected;
    Printf.printf "         actual: %s\n" actual
  | Doctest.Error msg ->
    Printf.printf "  ERROR %s: %s\n" loc ex.input;
    Printf.printf "        %s\n" msg

let run_one filename =
  Printf.printf "running doctests in %s\n" filename;
  let r =
    try Doctest.run_file filename
    with Failure msg ->
      Printf.eprintf "medaka test: error loading %s: %s\n" filename msg;
      exit 1
  in
  if r.Doctest.total = 0 then begin
    Printf.printf "  (no doctests found)\n";
    true
  end else begin
    List.iter (fun (ex, res) ->
      pp_result_line filename ex res
    ) r.Doctest.details;
    Printf.printf "\n%s: %d/%d passed" filename r.Doctest.passed r.Doctest.total;
    if r.Doctest.failed > 0 || r.Doctest.errors > 0 then
      Printf.printf " (%d failed, %d errors)" r.Doctest.failed r.Doctest.errors;
    Printf.printf "\n";
    r.Doctest.failed = 0 && r.Doctest.errors = 0
  end

let run (argv : string array) : int =
  let files =
    match Array.to_list argv with
    | [] ->
      let cwd = Sys.getcwd () in
      let probe = Filename.concat cwd "_probe_.mdk" in
      (match Project_config.find_project_root probe with
       | None ->
         Printf.eprintf "medaka test: no file given and no medaka.toml found\n";
         exit 1
       | Some root ->
         (match Project_config.load_from_dir root with
          | None ->
            Printf.eprintf "medaka test: no medaka.toml in %s\n" root; exit 1
          | Some cfg ->
            (match cfg.Project_config.entry with
             | Some e -> [Filename.concat root e]
             | None ->
               Printf.eprintf "medaka test: workspace root has no [package] entry\n";
               exit 1)))
    | fs -> fs
  in
  let all_ok = List.for_all run_one files in
  if all_ok then 0 else 1
