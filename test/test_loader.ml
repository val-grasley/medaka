open Medaka_lib

(* ── Helpers ─────────────────────────────────────── *)

(* Write a temporary .mdk file and return its path *)
let with_tmp_dir f =
  let dir = Filename.temp_dir "medaka_test_" "" in
  Fun.protect
    ~finally:(fun () ->
      (* Remove all files in dir, then dir itself *)
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

(* ── Tests ───────────────────────────────────────── *)

let test_module_id_of_path () =
  let f = Loader.module_id_of_path "/proj/src" "/proj/src/list.mdk" in
  if f <> "list" then
    failwith (Printf.sprintf "expected 'list', got '%s'" f);
  let g = Loader.module_id_of_path "/proj/src" "/proj/src/utils/text.mdk" in
  if g <> "utils.text" then
    failwith (Printf.sprintf "expected 'utils.text', got '%s'" g)

let test_single_file () =
  with_tmp_dir (fun dir ->
    let path = write_file dir "hello.mdk" "answer = 42\n" in
    let modules = Loader.load_program path dir in
    match modules with
    | [(mod_id, _, prog)] ->
      if mod_id <> "hello" then
        failwith (Printf.sprintf "expected mod_id 'hello', got '%s'" mod_id);
      (match prog with
       | [Ast.DFunDef (false, "answer", [], _)] -> ()
       | _ -> failwith "unexpected program")
    | _ -> failwith (Printf.sprintf "expected 1 module, got %d" (List.length modules))
  )

let test_happy_path () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "list.mdk"
      "export map f xs =\n  match xs\n    [] => []\n    h::t => (f h) :: (map f t)\n"
    in
    let main_path = write_file dir "main.mdk"
      "import list.{map}\ndouble x = x * 2\nmain : <IO> Unit\nmain =\n  do\n    let r = map double [1, 2, 3]\n    pure ()\n"
    in
    let modules = Loader.load_program main_path dir in
    let ids = List.map (fun (id, _, _) -> id) modules in
    (* list must appear before main *)
    (match ids with
     | ["list"; "main"] -> ()
     | _ -> failwith (Printf.sprintf "wrong order: %s" (String.concat ", " ids)))
  )

let test_cycle_detection () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "a.mdk" "import b.{foo}\nx = 1\n" in
    let a_path = write_file dir "b.mdk" "import a.{x}\nfoo = 2\n" in
    try
      let _ = Loader.load_program a_path dir in
      failwith "expected CyclicDependency error"
    with
    | Loader.LoadError (Loader.CyclicDependency _cycle) -> ()
    | Loader.LoadError _ -> failwith "wrong load error"
  )

let test_missing_file () =
  with_tmp_dir (fun dir ->
    let main_path = write_file dir "main.mdk"
      "import nonexistent.{foo}\nmain : <IO> Unit\nmain = pure ()\n"
    in
    try
      let _ = Loader.load_program main_path dir in
      failwith "expected UnknownModule error"
    with
    | Loader.LoadError (Loader.UnknownModule _) -> ()
    | Loader.LoadError (Loader.FileNotFound _) -> ()
    | Loader.LoadError _ -> failwith "wrong load error type"
  )

let test_privacy_violation () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "list.mdk"
      "internal_helper x = x + 1\nexport map f xs = []\n"
    in
    let main_path = write_file dir "main.mdk"
      "import list.{internal_helper}\nmain : <IO> Unit\nmain = pure ()\n"
    in
    let modules = Loader.load_program main_path dir in
    (* Load succeeds; privacy violation is caught at resolve time *)
    let resolve_exports = ref [] in
    let has_error = ref false in
    List.iter (fun (mod_id, _, prog) ->
      let (exports, errs) =
        Resolve.resolve_module !resolve_exports mod_id prog
      in
      if errs <> [] then has_error := true;
      resolve_exports := exports :: !resolve_exports
    ) modules;
    if not !has_error then
      failwith "expected PrivateNameAccess error but got none"
  )

let test_export_parsing () =
  Lexer.reset ();
  let lexbuf = Lexing.from_string "export map f xs = []\n" in
  let prog = Parser.program Lexer.token lexbuf in
  match prog with
  | [Ast.DFunDef (true, "map", _, _)] -> ()
  | _ -> failwith "expected exported DFunDef"

let test_export_data_parsing () =
  Lexer.reset ();
  let lexbuf = Lexing.from_string "export data Color = Red | Green | Blue\n" in
  let prog = Parser.program Lexer.token lexbuf in
  match prog with
  | [Ast.DData (Ast.DataAbstract, "Color", [], _, _)] -> ()
  | _ -> failwith "expected exported DData"

let test_export_round_trip () =
  Lexer.reset ();
  let src = "export map f xs = []\n" in
  let lexbuf = Lexing.from_string src in
  let prog = Parser.program Lexer.token lexbuf in
  let printed = Printer.program_to_string prog in
  if not (String.sub printed 0 7 = "export ") then
    failwith (Printf.sprintf "expected 'export ' prefix in printed output, got: %s" printed)

(* ── Re-export helpers ───────────────────────────── *)

(* Resolve all modules in load order and return per-module exports list. *)
let resolve_all modules =
  let resolve_exports = ref [] in
  let errors = ref [] in
  List.iter (fun (mod_id, _, prog) ->
    let (exp, errs) = Resolve.resolve_module !resolve_exports mod_id prog in
    resolve_exports := exp :: !resolve_exports;
    if errs <> [] then errors := (mod_id, errs) :: !errors
  ) modules;
  (List.rev !resolve_exports, !errors)

let find_exp exports mod_id =
  match List.find_opt (fun e -> e.Resolve.exp_mod_id = mod_id) exports with
  | Some e -> e
  | None -> failwith (Printf.sprintf "module '%s' not found in exports" mod_id)

(* ── Re-export tests ──────────────────────────────── *)

(* export import a.foo (UseName) re-exports a single value *)
let test_reexport_value_selective () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "a.mdk" "export foo = 42\n" in
    let _ = write_file dir "b.mdk" "export import a.foo\n" in
    let main = write_file dir "main.mdk" "import b.{foo}\nresult = foo\n" in
    let modules = Loader.load_program main dir in
    let (exports, errors) = resolve_all modules in
    if errors <> [] then failwith "unexpected resolve errors";
    let b_exp = find_exp exports "b" in
    if not (Hashtbl.mem b_exp.Resolve.exp_values "foo") then
      failwith "expected 'foo' in b's exports"
  )

(* export import a.{x, y} (UseGroup) re-exports selected names *)
let test_reexport_group () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "a.mdk" "export foo = 1\nexport bar = 2\nexport baz = 3\n" in
    let _ = write_file dir "b.mdk" "export import a.{foo, bar}\n" in
    let main = write_file dir "main.mdk" "import b.{foo}\nimport b.{bar}\nresult = foo\n" in
    let modules = Loader.load_program main dir in
    let (exports, errors) = resolve_all modules in
    if errors <> [] then failwith "unexpected resolve errors";
    let b_exp = find_exp exports "b" in
    if not (Hashtbl.mem b_exp.Resolve.exp_values "foo") then
      failwith "expected 'foo' in b's exports";
    if not (Hashtbl.mem b_exp.Resolve.exp_values "bar") then
      failwith "expected 'bar' in b's exports";
    if Hashtbl.mem b_exp.Resolve.exp_values "baz" then
      failwith "did not expect 'baz' in b's exports"
  )

(* export import a.* (UseWild) re-exports all public names *)
let test_reexport_wildcard () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "a.mdk" "export foo = 1\nexport bar = 2\nprivate_val = 3\n" in
    let _ = write_file dir "b.mdk" "export import a.*\n" in
    let main = write_file dir "main.mdk" "import b.{foo}\nimport b.{bar}\nresult = foo\n" in
    let modules = Loader.load_program main dir in
    let (exports, errors) = resolve_all modules in
    if errors <> [] then failwith "unexpected resolve errors";
    let b_exp = find_exp exports "b" in
    if not (Hashtbl.mem b_exp.Resolve.exp_values "foo") then
      failwith "expected 'foo' in b's exports";
    if not (Hashtbl.mem b_exp.Resolve.exp_values "bar") then
      failwith "expected 'bar' in b's exports";
    if Hashtbl.mem b_exp.Resolve.exp_values "private_val" then
      failwith "did not expect 'private_val' in b's exports"
  )

(* wildcard re-export includes data types and their constructors *)
let test_reexport_data_wildcard () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "a.mdk" "public export data Color = Red | Green | Blue\n" in
    let _ = write_file dir "b.mdk" "export import a.*\n" in
    let main = write_file dir "main.mdk"
      "import b.{Color, Red, Green, Blue}\nfavorite : Color\nfavorite = Red\n" in
    let modules = Loader.load_program main dir in
    let (exports, errors) = resolve_all modules in
    if errors <> [] then failwith "unexpected resolve errors";
    let b_exp = find_exp exports "b" in
    if not (Hashtbl.mem b_exp.Resolve.exp_types "Color") then
      failwith "expected 'Color' in b's exports";
    if not (Hashtbl.mem b_exp.Resolve.exp_constructors "Red") then
      failwith "expected 'Red' in b's exports"
  )

(* group re-export includes named constructors *)
let test_reexport_data_group () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "a.mdk" "public export data Color = Red | Green | Blue\n" in
    let _ = write_file dir "b.mdk" "export import a.{Color, Red, Green, Blue}\n" in
    let main = write_file dir "main.mdk"
      "import b.{Color, Red}\nfavorite : Color\nfavorite = Red\n" in
    let modules = Loader.load_program main dir in
    let (exports, errors) = resolve_all modules in
    if errors <> [] then failwith "unexpected resolve errors";
    let b_exp = find_exp exports "b" in
    if not (Hashtbl.mem b_exp.Resolve.exp_types "Color") then
      failwith "expected 'Color' in b's exports";
    if not (Hashtbl.mem b_exp.Resolve.exp_constructors "Red") then
      failwith "expected 'Red' in b's exports"
  )

(* wildcard re-export includes interfaces and their methods *)
let test_reexport_interface () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "a.mdk"
      "export interface Pretty a where\n  pretty : a -> String\n" in
    let _ = write_file dir "b.mdk" "export import a.*\n" in
    let main = write_file dir "main.mdk"
      "import b.{Pretty, pretty}\ndisplay : Pretty a => a -> String\ndisplay x = pretty x\n" in
    let modules = Loader.load_program main dir in
    let (exports, errors) = resolve_all modules in
    if errors <> [] then failwith "unexpected resolve errors";
    let b_exp = find_exp exports "b" in
    if not (Hashtbl.mem b_exp.Resolve.exp_interfaces "Pretty") then
      failwith "expected 'Pretty' in b's exports";
    if not (Hashtbl.mem b_exp.Resolve.exp_values "pretty") then
      failwith "expected 'pretty' method in b's exports"
  )

(* group re-export of an interface includes its methods *)
let test_reexport_interface_group () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "a.mdk"
      "export interface Pretty a where\n  pretty : a -> String\n" in
    let _ = write_file dir "b.mdk" "export import a.{Pretty}\n" in
    let main = write_file dir "main.mdk"
      "import b.{Pretty, pretty}\ndisplay : Pretty a => a -> String\ndisplay x = pretty x\n" in
    let modules = Loader.load_program main dir in
    let (exports, errors) = resolve_all modules in
    if errors <> [] then failwith "unexpected resolve errors";
    let b_exp = find_exp exports "b" in
    if not (Hashtbl.mem b_exp.Resolve.exp_interfaces "Pretty") then
      failwith "expected 'Pretty' in b's exports";
    if not (Hashtbl.mem b_exp.Resolve.exp_values "pretty") then
      failwith "expected 'pretty' method in b's exports"
  )

(* chained re-exports: A -> B -> C -> D *)
let test_reexport_chained () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "a.mdk" "export foo = 42\n" in
    let _ = write_file dir "b.mdk" "export import a.foo\n" in
    let _ = write_file dir "c.mdk" "export import b.foo\n" in
    let main = write_file dir "main.mdk" "import c.{foo}\nresult = foo\n" in
    let modules = Loader.load_program main dir in
    let (exports, errors) = resolve_all modules in
    if errors <> [] then failwith "unexpected resolve errors";
    let c_exp = find_exp exports "c" in
    if not (Hashtbl.mem c_exp.Resolve.exp_values "foo") then
      failwith "expected 'foo' in c's exports"
  )

(* private import (no export) is not visible to third modules *)
let test_private_import_not_reexported () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "a.mdk" "export foo = 42\n" in
    let _ = write_file dir "b.mdk" "import a.foo\n" in
    let main = write_file dir "main.mdk" "import b.{foo}\nresult = foo\n" in
    let modules = Loader.load_program main dir in
    let (_exports, errors) = resolve_all modules in
    if errors = [] then
      failwith "expected PrivateNameAccess error but got none"
  )

(* The ?read buffer-override parameter takes precedence over disk
   content.  Used by the LSP to surface unsaved editor buffers. *)
let test_read_override () =
  with_tmp_dir (fun dir ->
    (* Disk has one definition... *)
    let main_path = write_file dir "main.mdk" "answer = 42\n" in
    (* ...but the override returns a different one. *)
    let read path =
      if path = main_path then Some "answer = 99\n" else None
    in
    let modules = Loader.load_program ~read main_path dir in
    match modules with
    | [(_mid, _fp, prog)] ->
      (match prog with
       | [Ast.DFunDef (false, "answer", [], body)] ->
         (* Check it picked up the override (99), not disk (42). *)
         let rec find_int = function
           | Ast.ELoc (_, e) -> find_int e
           | Ast.ELit (Ast.LInt n) -> Some n
           | _ -> None
         in
         (match find_int body with
          | Some 99 -> ()
          | Some n -> failwith (Printf.sprintf
                        "loader used disk content (%d), not override" n)
          | None   -> failwith "couldn't find int literal in body")
       | _ -> failwith "unexpected program shape")
    | _ -> failwith "expected exactly 1 module"
  )

(* `import core.{...}` is a no-op: core is the implicit prelude, so the
   loader must not try to find core.mdk on disk.  This test deliberately
   uses a project dir without a core.mdk file. *)
let test_import_core_is_noop () =
  with_tmp_dir (fun dir ->
    let main = write_file dir "main.mdk"
      "import core.{identity}\nx = identity 5\n" in
    let modules = Loader.load_program main dir in
    let ids = List.map (fun (id, _, _) -> id) modules in
    match ids with
    | ["main"] -> ()
    | _ -> failwith (Printf.sprintf
            "expected ['main'], got %s" (String.concat ", " ids))
  )

(* ── Abstract type export tests ─────────────────── *)

(* export data → type in exp_types, constructors NOT in exp_constructors *)
let test_abstract_export_type_only () =
  with_tmp_dir (fun dir ->
    let main = write_file dir "a.mdk" "export data Color = Red | Green | Blue\n" in
    let modules = Loader.load_program main dir in
    let (exports, errors) = resolve_all modules in
    if errors <> [] then failwith "unexpected resolve errors";
    let a_exp = find_exp exports "a" in
    if not (Hashtbl.mem a_exp.Resolve.exp_types "Color") then
      failwith "expected 'Color' in exp_types";
    if Hashtbl.mem a_exp.Resolve.exp_constructors "Red" then
      failwith "expected 'Red' NOT in exp_constructors (abstract export)"
  )

(* public export data → type AND constructors in export tables *)
let test_public_export_ctors_visible () =
  with_tmp_dir (fun dir ->
    let main = write_file dir "a.mdk" "public export data Color = Red | Green | Blue\n" in
    let modules = Loader.load_program main dir in
    let (exports, errors) = resolve_all modules in
    if errors <> [] then failwith "unexpected resolve errors";
    let a_exp = find_exp exports "a" in
    if not (Hashtbl.mem a_exp.Resolve.exp_types "Color") then
      failwith "expected 'Color' in exp_types";
    if not (Hashtbl.mem a_exp.Resolve.exp_constructors "Red") then
      failwith "expected 'Red' in exp_constructors"
  )

(* importing abstract type and using constructor → UnknownConstructor *)
let test_import_abstract_ctor_rejected () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "a.mdk" "export data Color = Red | Green | Blue\n" in
    let main = write_file dir "main.mdk"
      "import a.{Color}\nfavorite : Color\nfavorite = Red\n" in
    let modules = Loader.load_program main dir in
    let (_exports, errors) = resolve_all modules in
    let all_errs = List.concat_map snd errors in
    let has_unbound = List.exists (function
      | (Resolve.UnboundVariable "Red", _) -> true
      | _ -> false) all_errs in
    if not has_unbound then
      failwith "expected UnboundVariable(Red) error for abstract constructor"
  )

(* importing public export type and using constructor → no error *)
let test_import_public_ctor_allowed () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "a.mdk" "public export data Color = Red | Green | Blue\n" in
    let main = write_file dir "main.mdk"
      "import a.{Color, Red}\nfavorite : Color\nfavorite = Red\n" in
    let modules = Loader.load_program main dir in
    let (_exports, errors) = resolve_all modules in
    if errors <> [] then
      failwith "unexpected errors for public export constructor"
  )

(* ── Runner ──────────────────────────────────────── *)

let () =
  let open Alcotest in
  run "Medaka Loader" [
    "module ID derivation", [
      test_case "path to module id"  `Quick test_module_id_of_path;
    ];
    "export keyword parsing", [
      test_case "export fun_def"    `Quick test_export_parsing;
      test_case "export data decl"  `Quick test_export_data_parsing;
      test_case "export round-trip" `Quick test_export_round_trip;
    ];
    "loader", [
      test_case "single file"      `Quick test_single_file;
      test_case "happy path"       `Quick test_happy_path;
      test_case "cycle detection"  `Quick test_cycle_detection;
      test_case "missing file"     `Quick test_missing_file;
      test_case "privacy violation" `Quick test_privacy_violation;
      test_case "import core no-op" `Quick test_import_core_is_noop;
      test_case "?read override"    `Quick test_read_override;
    ];
    "re-exports", [
      test_case "selective (UseName)"          `Quick test_reexport_value_selective;
      test_case "group (UseGroup)"             `Quick test_reexport_group;
      test_case "wildcard (UseWild)"           `Quick test_reexport_wildcard;
      test_case "data type wildcard"           `Quick test_reexport_data_wildcard;
      test_case "data type group"              `Quick test_reexport_data_group;
      test_case "interface wildcard"           `Quick test_reexport_interface;
      test_case "interface group"              `Quick test_reexport_interface_group;
      test_case "chained A->B->C"              `Quick test_reexport_chained;
      test_case "private import not reexported" `Quick test_private_import_not_reexported;
    ];
    "abstract type exports", [
      test_case "export data: type only in exports"  `Quick test_abstract_export_type_only;
      test_case "public export: ctors visible"        `Quick test_public_export_ctors_visible;
      test_case "import abstract: ctor rejected"      `Quick test_import_abstract_ctor_rejected;
      test_case "import public export: ctor allowed"  `Quick test_import_public_ctor_allowed;
    ];
  ]
