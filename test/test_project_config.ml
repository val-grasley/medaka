(* Tests for `lib/project_config.ml`: TOML parser + project-root walk. *)

open Medaka_lib

let check_cfg ~name ~version ~entry (cfg : Project_config.t) =
  if cfg.name <> name then
    failwith (Printf.sprintf "name: expected %S, got %S" name cfg.name);
  if cfg.version <> version then
    failwith (Printf.sprintf "version: expected %S, got %S" version cfg.version);
  if cfg.entry <> entry then
    failwith (Printf.sprintf "entry: expected %S, got %S" entry cfg.entry)

let parse_valid () =
  let src =
{|[package]
name = "demo"
version = "0.1.0"
entry = "main.mdk"
|}
  in
  let cfg = Project_config.parse_string src in
  check_cfg ~name:"demo" ~version:"0.1.0" ~entry:"main.mdk" cfg

let parse_with_comments () =
  let src =
{|# top-of-file note
[package]   # the only section
name    = "demo"
# blank lines and comments should be ignored

version = "0.1.0"
entry   = "src/main.mdk"  # entry path
|}
  in
  let cfg = Project_config.parse_string src in
  check_cfg ~name:"demo" ~version:"0.1.0" ~entry:"src/main.mdk" cfg

let parse_no_header () =
  let src = "name = \"x\"\nversion = \"1\"\nentry = \"e.mdk\"\n" in
  let cfg = Project_config.parse_string src in
  check_cfg ~name:"x" ~version:"1" ~entry:"e.mdk" cfg

let expect_parse_error ?(substr = "") src () =
  match Project_config.parse_string src with
  | _ -> failwith "expected Parse_error"
  | exception Project_config.Parse_error msg ->
    if substr <> "" then
      let nlen = String.length substr in
      let hlen = String.length msg in
      let rec ok i =
        if i + nlen > hlen then false
        else if String.sub msg i nlen = substr then true
        else ok (i + 1)
      in
      if not (ok 0) then
        failwith (Printf.sprintf "error %S did not mention %S" msg substr)

let missing_required_field =
  expect_parse_error ~substr:"entry"
    "[package]\nname = \"x\"\nversion = \"1\"\n"

let malformed_value =
  expect_parse_error ~substr:"quoted"
    "[package]\nname = no-quotes\nversion = \"1\"\nentry = \"e\"\n"

(* ── find_project_root ─────────────────────────────────── *)

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let tmp = Filename.concat base (Printf.sprintf "medaka_pc_%d" (Random.bits ())) in
  Unix.mkdir tmp 0o755;
  let finally () =
    let rec rm path =
      if Sys.is_directory path then begin
        Array.iter (fun e -> rm (Filename.concat path e)) (Sys.readdir path);
        Unix.rmdir path
      end else
        Sys.remove path
    in
    try rm tmp with _ -> ()
  in
  try let r = f tmp in finally (); r
  with e -> finally (); raise e

let find_root_walks_up () =
  with_temp_dir (fun tmp ->
    let nested = Filename.concat tmp "a/b" in
    Unix.mkdir (Filename.concat tmp "a") 0o755;
    Unix.mkdir nested 0o755;
    let oc = open_out (Filename.concat tmp "medaka.toml") in
    output_string oc "[package]\nname=\"x\"\nversion=\"0\"\nentry=\"m.mdk\"\n";
    close_out oc;
    let file = Filename.concat nested "deep.mdk" in
    match Project_config.find_project_root file with
    | Some d when d = tmp -> ()
    | Some d -> failwith ("wrong root: " ^ d)
    | None -> failwith "expected Some")

let find_root_none () =
  with_temp_dir (fun tmp ->
    let file = Filename.concat tmp "x.mdk" in
    match Project_config.find_project_root file with
    | None -> ()
    | Some d -> failwith ("expected None, got " ^ d))

let () =
  Random.self_init ();
  Alcotest.run "Project_config" [
    "parse", [
      Alcotest.test_case "valid"          `Quick parse_valid;
      Alcotest.test_case "with comments"  `Quick parse_with_comments;
      Alcotest.test_case "no header"      `Quick parse_no_header;
      Alcotest.test_case "missing field"  `Quick missing_required_field;
      Alcotest.test_case "malformed val"  `Quick malformed_value;
    ];
    "find_project_root", [
      Alcotest.test_case "walks up"       `Quick find_root_walks_up;
      Alcotest.test_case "none"           `Quick find_root_none;
    ];
  ]
