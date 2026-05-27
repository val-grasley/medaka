(* Tests for `lib/new_cmd.ml`. *)

open Medaka_lib

let with_temp_cwd f =
  let base = Filename.get_temp_dir_name () in
  let tmp = Filename.concat base (Printf.sprintf "medaka_new_%d" (Random.bits ())) in
  Unix.mkdir tmp 0o755;
  let prev = Sys.getcwd () in
  Sys.chdir tmp;
  let cleanup () =
    Sys.chdir prev;
    let rec rm path =
      if Sys.is_directory path then begin
        Array.iter (fun e -> rm (Filename.concat path e)) (Sys.readdir path);
        Unix.rmdir path
      end else
        Sys.remove path
    in
    try rm tmp with _ -> ()
  in
  try let r = f () in cleanup (); r
  with e -> cleanup (); raise e

let read path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = Bytes.create n in
  really_input ic s 0 n;
  close_in ic;
  Bytes.to_string s

let contains needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  let rec loop i =
    if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else loop (i + 1)
  in
  loop 0

let scaffold_creates_files () =
  with_temp_cwd (fun () ->
    let rc = New_cmd.run [|"demo"|] in
    if rc <> 0 then failwith (Printf.sprintf "expected exit 0, got %d" rc);
    List.iter (fun rel ->
      let p = Filename.concat "demo" rel in
      if not (Sys.file_exists p) then
        failwith (Printf.sprintf "missing scaffolded file: %s" rel)
    ) ["medaka.toml"; "main.mdk"; ".gitignore"; "README.md"];
    let toml = read "demo/medaka.toml" in
    if not (contains "name = \"demo\"" toml) then
      failwith ("toml lacks project name; got:\n" ^ toml);
    (* The scaffolded toml must be parseable by our own reader. *)
    let cfg = Project_config.parse_string toml in
    if cfg.name <> "demo" then failwith "round-trip name mismatch")

let scaffold_refuses_existing () =
  with_temp_cwd (fun () ->
    Unix.mkdir "demo" 0o755;
    let rc = New_cmd.run [|"demo"|] in
    if rc = 0 then failwith "expected nonzero exit when path exists")

let scaffold_rejects_bad_name () =
  with_temp_cwd (fun () ->
    let rc = New_cmd.run [|"a/b"|] in
    if rc = 0 then failwith "expected nonzero exit for name with slash")

let scaffold_rejects_no_args () =
  with_temp_cwd (fun () ->
    let rc = New_cmd.run [||] in
    if rc = 0 then failwith "expected nonzero exit when no name given")

let () =
  Random.self_init ();
  Alcotest.run "New_cmd" [
    "scaffold", [
      Alcotest.test_case "creates files"     `Quick scaffold_creates_files;
      Alcotest.test_case "refuses existing"  `Quick scaffold_refuses_existing;
      Alcotest.test_case "rejects bad name"  `Quick scaffold_rejects_bad_name;
      Alcotest.test_case "rejects no args"   `Quick scaffold_rejects_no_args;
    ];
  ]
