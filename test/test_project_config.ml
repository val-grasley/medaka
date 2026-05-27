(* Tests for `lib/project_config.ml`: TOML parser + project-root walk. *)

open Medaka_lib

let check_cfg ~name ~version ~entry (cfg : Project_config.t) =
  if cfg.name <> Some name then
    failwith (Printf.sprintf "name: expected %S, got %s" name
      (Option.value cfg.name ~default:"(none)"));
  if cfg.version <> Some version then
    failwith (Printf.sprintf "version: expected %S, got %s" version
      (Option.value cfg.version ~default:"(none)"));
  if cfg.entry <> Some entry then
    failwith (Printf.sprintf "entry: expected %S, got %s" entry
      (Option.value cfg.entry ~default:"(none)"))

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

(* ── Workspace TOML parsing ────────────────────────── *)

let parse_workspace_only () =
  let src =
{|[workspace]
members = ["packages/core", "packages/cli"]
|}
  in
  let cfg = Project_config.parse_string src in
  if cfg.name <> None then
    failwith (Printf.sprintf "expected name=None, got %s"
      (Option.value cfg.name ~default:"(none)"));
  if cfg.entry <> None then failwith "expected entry=None";
  match cfg.workspace with
  | None -> failwith "expected workspace to be Some"
  | Some ws ->
    if ws.Project_config.ws_members <> ["packages/core"; "packages/cli"] then
      failwith (Printf.sprintf "wrong members: [%s]"
        (String.concat "; " ws.Project_config.ws_members))

let parse_workspace_and_package () =
  let src =
{|[package]
name = "root"
version = "0.1.0"
entry = "main.mdk"

[workspace]
members = ["a", "b"]
|}
  in
  let cfg = Project_config.parse_string src in
  check_cfg ~name:"root" ~version:"0.1.0" ~entry:"main.mdk" cfg;
  match cfg.workspace with
  | None -> failwith "expected workspace to be Some"
  | Some ws ->
    if ws.Project_config.ws_members <> ["a"; "b"] then
      failwith "wrong workspace members"

let parse_empty_members () =
  let src = "[workspace]\nmembers = []\n" in
  let cfg = Project_config.parse_string src in
  match cfg.workspace with
  | None -> failwith "expected workspace to be Some"
  | Some ws ->
    if ws.Project_config.ws_members <> [] then
      failwith "expected empty members"

let package_missing_entry_with_workspace () =
  (* [package] present but entry missing → Parse_error *)
  let src = "[package]\nname = \"x\"\nversion = \"1\"\n" in
  match Project_config.parse_string src with
  | _ -> failwith "expected Parse_error"
  | exception Project_config.Parse_error msg ->
    if not (let n = String.length "entry" in
            let h = String.length msg in
            let rec ok i = i + n <= h &&
              (String.sub msg i n = "entry" || ok (i+1)) in ok 0)
    then failwith (Printf.sprintf "error %S did not mention 'entry'" msg)

(* ── find_workspace_root ──────────────────────────── *)

let find_workspace_root_walks_up () =
  with_temp_dir (fun tmp ->
    let sub = Filename.concat tmp "packages/app" in
    Unix.mkdir (Filename.concat tmp "packages") 0o755;
    Unix.mkdir sub 0o755;
    let oc = open_out (Filename.concat tmp "medaka.toml") in
    output_string oc "[workspace]\nmembers = [\"packages/app\"]\n";
    close_out oc;
    let file = Filename.concat sub "main.mdk" in
    match Project_config.find_workspace_root file with
    | Some d when d = tmp -> ()
    | Some d -> failwith ("wrong root: " ^ d)
    | None -> failwith "expected Some")

let find_workspace_root_none_without_workspace () =
  with_temp_dir (fun tmp ->
    (* medaka.toml with only [package] — not a workspace root *)
    let oc = open_out (Filename.concat tmp "medaka.toml") in
    output_string oc "[package]\nname=\"x\"\nversion=\"0\"\nentry=\"m.mdk\"\n";
    close_out oc;
    let file = Filename.concat tmp "x.mdk" in
    match Project_config.find_workspace_root file with
    | None -> ()
    | Some d -> failwith ("expected None, got " ^ d))

(* ── load_workspace_members ──────────────────────── *)

let load_workspace_members_happy () =
  with_temp_dir (fun tmp ->
    let core_dir = Filename.concat tmp "packages/core" in
    let app_dir  = Filename.concat tmp "packages/app" in
    Unix.mkdir (Filename.concat tmp "packages") 0o755;
    Unix.mkdir core_dir 0o755;
    Unix.mkdir app_dir  0o755;
    let write_toml dir n v e =
      let oc = open_out (Filename.concat dir "medaka.toml") in
      output_string oc (Printf.sprintf
        "[package]\nname = \"%s\"\nversion = \"%s\"\nentry = \"%s\"\n" n v e);
      close_out oc
    in
    let oc = open_out (Filename.concat tmp "medaka.toml") in
    output_string oc "[workspace]\nmembers = [\"packages/core\", \"packages/app\"]\n";
    close_out oc;
    write_toml core_dir "core" "0.1.0" "main.mdk";
    write_toml app_dir  "app"  "0.1.0" "main.mdk";
    let members = Project_config.load_workspace_members tmp in
    if List.length members <> 2 then
      failwith (Printf.sprintf "expected 2 members, got %d" (List.length members));
    let (d1, c1) = List.nth members 0 in
    let (d2, c2) = List.nth members 1 in
    if d1 <> core_dir then failwith ("wrong member[0] dir: " ^ d1);
    if d2 <> app_dir  then failwith ("wrong member[1] dir: " ^ d2);
    if c1.Project_config.name <> Some "core" then failwith "wrong core name";
    if c2.Project_config.name <> Some "app"  then failwith "wrong app name")

let load_workspace_members_missing_dir () =
  with_temp_dir (fun tmp ->
    let oc = open_out (Filename.concat tmp "medaka.toml") in
    output_string oc "[workspace]\nmembers = [\"nonexistent\"]\n";
    close_out oc;
    match Project_config.load_workspace_members tmp with
    | _ -> failwith "expected Parse_error for missing member dir"
    | exception Project_config.Parse_error _ -> ())

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
    "workspace parse", [
      Alcotest.test_case "workspace only"          `Quick parse_workspace_only;
      Alcotest.test_case "workspace + package"     `Quick parse_workspace_and_package;
      Alcotest.test_case "empty members array"     `Quick parse_empty_members;
      Alcotest.test_case "package missing entry"   `Quick package_missing_entry_with_workspace;
    ];
    "find_workspace_root", [
      Alcotest.test_case "walks up"                `Quick find_workspace_root_walks_up;
      Alcotest.test_case "none without workspace"  `Quick find_workspace_root_none_without_workspace;
    ];
    "load_workspace_members", [
      Alcotest.test_case "happy path"     `Quick load_workspace_members_happy;
      Alcotest.test_case "missing dir"    `Quick load_workspace_members_missing_dir;
    ];
  ]
