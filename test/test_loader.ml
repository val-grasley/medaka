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
  let f = Loader.module_id_of_path ["/proj/src"] "/proj/src/list.mdk" in
  if f <> "list" then
    failwith (Printf.sprintf "expected 'list', got '%s'" f);
  let g = Loader.module_id_of_path ["/proj/src"] "/proj/src/utils/text.mdk" in
  if g <> "utils.text" then
    failwith (Printf.sprintf "expected 'utils.text', got '%s'" g)

let test_single_file () =
  with_tmp_dir (fun dir ->
    let path = write_file dir "hello.mdk" "answer = 42\n" in
    let modules = Loader.load_program path [dir] in
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
    let modules = Loader.load_program main_path [dir] in
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
      let _ = Loader.load_program a_path [dir] in
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
      let _ = Loader.load_program main_path [dir] in
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
    let modules = Loader.load_program main_path [dir] in
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
    let modules = Loader.load_program main [dir] in
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
    let modules = Loader.load_program main [dir] in
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
    let modules = Loader.load_program main [dir] in
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
    let modules = Loader.load_program main [dir] in
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
    let modules = Loader.load_program main [dir] in
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
    let modules = Loader.load_program main [dir] in
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
    let modules = Loader.load_program main [dir] in
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
    let modules = Loader.load_program main [dir] in
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
    let modules = Loader.load_program main [dir] in
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
    let modules = Loader.load_program ~read main_path [dir] in
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
    let modules = Loader.load_program main [dir] in
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
    let modules = Loader.load_program main [dir] in
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
    let modules = Loader.load_program main [dir] in
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
    let modules = Loader.load_program main [dir] in
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
    let modules = Loader.load_program main [dir] in
    let (_exports, errors) = resolve_all modules in
    if errors <> [] then
      failwith "unexpected errors for public export constructor"
  )

(* Phase 100: `import a.{Color(..)}` brings the type + all ctors into scope *)
let test_import_group_ctors_allowed () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "a.mdk" "public export data Color = Red | Green | Blue\n" in
    let main = write_file dir "main.mdk"
      "import a.{Color(..)}\nfavorite : Color\nfavorite = Green\n" in
    let modules = Loader.load_program main [dir] in
    let (_exports, errors) = resolve_all modules in
    if errors <> [] then
      failwith "unexpected errors for Color(..) bulk-constructor import"
  )

(* Phase 100: `Color(..)` on an abstractly-exported type → NoExportedConstructors *)
let test_import_group_ctors_abstract () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "a.mdk" "export data Color = Red | Green | Blue\n" in
    let main = write_file dir "main.mdk" "import a.{Color(..)}\nfavorite = 1\n" in
    let modules = Loader.load_program main [dir] in
    let (_exports, errors) = resolve_all modules in
    let all_errs = List.concat_map snd errors in
    let has_err = List.exists (function
      | (Resolve.NoExportedConstructors ("Color", "a"), _) -> true
      | _ -> false) all_errs in
    if not has_err then
      failwith "expected NoExportedConstructors(Color, a) for abstract Color(..)"
  )

(* Phase 100: `export import a.{Color(..)}` re-exports the type + all ctors *)
let test_reexport_group_ctors () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "a.mdk" "public export data Color = Red | Green | Blue\n" in
    let _ = write_file dir "b.mdk" "export import a.{Color(..)}\n" in
    let main = write_file dir "main.mdk" "import b.{Color, Red}\nfavorite = Red\n" in
    let modules = Loader.load_program main [dir] in
    let (exports, errors) = resolve_all modules in
    if errors <> [] then failwith "unexpected resolve errors";
    let b_exp = find_exp exports "b" in
    if not (Hashtbl.mem b_exp.Resolve.exp_types "Color") then
      failwith "expected 'Color' in b's exports";
    List.iter (fun c ->
      if not (Hashtbl.mem b_exp.Resolve.exp_constructors c) then
        failwith (Printf.sprintf "expected '%s' in b's re-exported constructors" c))
      ["Red"; "Green"; "Blue"]
  )

(* ── Workspace / multi-root tests ───────────────── *)

(* Create a nested directory structure for workspace tests *)
let with_workspace_dirs f =
  with_tmp_dir (fun ws ->
    let core_dir = Filename.concat ws "packages/core" in
    let app_dir  = Filename.concat ws "packages/app" in
    Unix.mkdir (Filename.concat ws "packages") 0o755;
    Unix.mkdir core_dir 0o755;
    Unix.mkdir app_dir  0o755;
    f ws core_dir app_dir)

(* Cross-member import: app imports a module defined in core *)
let test_workspace_cross_member_import () =
  with_workspace_dirs (fun _ws core_dir app_dir ->
    (* core has utils.mdk *)
    let _ = write_file core_dir "utils.mdk"
      "export helper x = x + 1\n"
    in
    (* app/main.mdk imports utils from the core member *)
    let main = write_file app_dir "main.mdk"
      "import utils.{helper}\nresult = helper 10\n"
    in
    let roots = [core_dir; app_dir] in
    let modules = Loader.load_program main roots in
    let ids = List.map (fun (id, _, _) -> id) modules in
    (* utils must appear before main *)
    (match ids with
     | ["utils"; "main"] -> ()
     | _ -> failwith (Printf.sprintf "wrong order: [%s]" (String.concat ", " ids))))

(* Ambiguous module: same module ID exists in two roots *)
let test_workspace_ambiguous_module () =
  with_workspace_dirs (fun _ws core_dir app_dir ->
    (* Both roots have utils.mdk *)
    let _ = write_file core_dir "utils.mdk" "export a = 1\n" in
    let _ = write_file app_dir  "utils.mdk" "export b = 2\n" in
    let main = write_file app_dir "main.mdk"
      "import utils.{a}\nresult = a\n"
    in
    let roots = [core_dir; app_dir] in
    (try
      let _ = Loader.load_program main roots in
      failwith "expected AmbiguousModule error"
     with
     | Loader.LoadError (Loader.AmbiguousModule { mod_id; _ }) ->
       if mod_id <> "utils" then
         failwith (Printf.sprintf "wrong mod_id in AmbiguousModule: %s" mod_id)
     | Loader.LoadError _ -> failwith "wrong load error type"))

(* Single-element roots list behaves identically to old project_dir API *)
let test_single_root_compat () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "lib.mdk" "export f x = x * 2\n" in
    let main = write_file dir "main.mdk"
      "import lib.{f}\nresult = f 21\n"
    in
    let modules = Loader.load_program main [dir] in
    let ids = List.map (fun (id, _, _) -> id) modules in
    (match ids with
     | ["lib"; "main"] -> ()
     | _ -> failwith (Printf.sprintf "unexpected order: [%s]"
                        (String.concat ", " ids))))

(* ── Multi-file typecheck (regression) ───────────── *)

(* Reproduces the bug where a non-leaf module defining an impl of a
   Mappable/Foldable/etc. class would cause downstream modules to see
   the prelude's default impls duplicated, surfacing as a spurious
   "Multiple default impls" error.  Fix: filter prelude-seeded impls
   out of te_impls so they only ever enter env via the explicit
   Prelude prepend. *)
let typecheck_module_chain modules =
  let resolved =
    List.fold_left (fun acc (mod_id, prog) ->
      let (te, _) = Resolve.resolve_module acc mod_id prog in
      te :: acc) [] modules
  in
  ignore resolved;
  let tc_acc = ref [] in
  List.iter (fun (mod_id, prog) ->
    let (te, _, _) = Typecheck.typecheck_module !tc_acc mod_id prog in
    tc_acc := te :: !tc_acc
  ) modules

let test_typecheck_impl_in_dep_module () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "arr.mdk"
      "export impl Mappable Array where\n  map f arr = arrayMakeWith (arrayLength arr) (i => f (arrayGetUnsafe i arr))\n"
    in
    let main_path = write_file dir "main.mdk"
      "import arr\nresult = 42\n"
    in
    let modules = Loader.load_program main_path [dir] in
    let modules = List.map (fun (mid, _fp, prog) ->
      (mid, Desugar.desugar_program prog)) modules
    in
    (* Should NOT raise "Multiple default impls of Mappable for Result a" *)
    try
      typecheck_module_chain modules
    with Typecheck.Type_error (e, _) ->
      failwith ("unexpected type error: " ^ Typecheck.pp_error e)
  )

(* Regression: even when the impl is for a type the prelude already has
   a non-default impl for, downstream typecheck must not double-count. *)
let test_typecheck_impl_list_in_dep_module () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "lib.mdk"
      "data Wrapper a = Wrapper a\nexport impl Mappable Wrapper where\n  map f (Wrapper x) = Wrapper (f x)\n"
    in
    let main_path = write_file dir "main.mdk"
      "import lib.{Wrapper}\nresult = 42\n"
    in
    let modules = Loader.load_program main_path [dir] in
    let modules = List.map (fun (mid, _fp, prog) ->
      (mid, Desugar.desugar_program prog)) modules
    in
    try
      typecheck_module_chain modules
    with Typecheck.Type_error (e, _) ->
      failwith ("unexpected type error: " ^ Typecheck.pp_error e)
  )

(* Phase 69.x: dictionary passing across module boundaries.  A constrained
   function `mk` defined and exported in one module must, when imported and
   called at two concrete result types in another, dispatch to the right impl.
   This mirrors bin/main.ml's multi-file pipeline: mark (with the constrained-fn
   set) → typecheck chain (threads fun_constraints through type exports) →
   Dict_pass over the combined program → eval. *)
let test_eval_dict_passing_cross_module () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "tagmod.mdk"
      "export interface Tag a where\n\
      \  tag : Int -> a\n\n\
       export impl Tag String where\n\
      \  tag n = \"S\"\n\n\
       export impl Tag Bool where\n\
      \  tag n = n > 0\n\n\
       export mk : Tag a => Int -> a\n\
       mk n = tag n\n" in
    let main_path = write_file dir "main.mdk"
      "import tagmod.{Tag, tag, mk}\n\n\
       main : <IO> Unit\n\
       main =\n\
      \  println (mk 5 : String)\n\
      \  if (mk 5 : Bool) then println \"T\" else println \"F\"\n" in
    let modules = Loader.load_program main_path [dir] in
    let modules = List.map (fun (mid, fp, prog) ->
      (mid, fp, Desugar.desugar_program prog)) modules in
    let method_names = Method_marker.interface_method_names
      (Prelude.program :: List.map (fun (_, _, p) -> p) modules) in
    let constrained = Method_marker.constrained_fn_names
      (List.map (fun (_, _, p) -> p) modules) in
    let modules = List.map (fun (mid, fp, prog) ->
      (mid, fp, Method_marker.mark_program method_names constrained prog)) modules in
    let te_acc = ref [] in
    List.iter (fun (mid, _, prog) ->
      let (te, _, _) = Typecheck.typecheck_module !te_acc mid prog in
      te_acc := te :: !te_acc) modules;
    let combined = List.concat_map (fun (_, _, p) -> p) modules in
    let combined = Dict_pass.run combined in
    let buf = Buffer.create 32 in
    let saved = !Eval.output_hook in
    Eval.output_hook := Buffer.add_string buf;
    Fun.protect ~finally:(fun () -> Eval.output_hook := saved) (fun () ->
      ignore (Eval.eval_program combined));
    let out = Buffer.contents buf in
    if out <> "S\nT\n" then
      failwith (Printf.sprintf "Expected \"S\\nT\\n\" from cross-module dispatch, got %S" out)
  )

(* Phase 69.x-c: per-super dictionary passing across module boundaries.  `mk`
   is constrained on `Sub m` but calls the direct-super method `base`; the super
   dict slot appended to `mk`'s constraints must survive the te_fun_constraints
   export so the importing module supplies a `Base` dict.  `Bag` impls first, so
   "first impl wins" would print Bag without the super dict. *)
let test_eval_super_dict_cross_module () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "submod.mdk"
      "export data Box a = Box a\n\
       export data Bag a = Bag a\n\n\
       export interface Base f where\n\
      \  base : a -> f a\n\n\
       export interface Sub f requires Base f where\n\
      \  same : f a -> f a\n\n\
       export impl Base Bag where\n\
      \  base x = Bag x\n\
       export impl Sub Bag where\n\
      \  same x = x\n\n\
       export impl Base Box where\n\
      \  base x = Box x\n\
       export impl Sub Box where\n\
      \  same x = x\n\n\
       export mk : Sub m => a -> m a\n\
       mk x = same (base x)\n" in
    let main_path = write_file dir "main.mdk"
      "import submod.{Box, Bag, Base, Sub, base, same, mk}\n\n\
       main : <IO> Unit\n\
       main =\n\
      \  println (mk 5 : Box Int)\n\
      \  println (mk 7 : Bag Int)\n" in
    let modules = Loader.load_program main_path [dir] in
    let modules = List.map (fun (mid, fp, prog) ->
      (mid, fp, Desugar.desugar_program prog)) modules in
    let method_names = Method_marker.interface_method_names
      (Prelude.program :: List.map (fun (_, _, p) -> p) modules) in
    let constrained = Method_marker.constrained_fn_names
      (List.map (fun (_, _, p) -> p) modules) in
    let modules = List.map (fun (mid, fp, prog) ->
      (mid, fp, Method_marker.mark_program method_names constrained prog)) modules in
    let te_acc = ref [] in
    List.iter (fun (mid, _, prog) ->
      let (te, _, _) = Typecheck.typecheck_module !te_acc mid prog in
      te_acc := te :: !te_acc) modules;
    let combined = List.concat_map (fun (_, _, p) -> p) modules in
    let combined = Dict_pass.run combined in
    let buf = Buffer.create 32 in
    let saved = !Eval.output_hook in
    Eval.output_hook := Buffer.add_string buf;
    Fun.protect ~finally:(fun () -> Eval.output_hook := saved) (fun () ->
      ignore (Eval.eval_program combined));
    let out = Buffer.contents buf in
    if out <> "Box 5\nBag 7\n" then
      failwith (Printf.sprintf "Expected \"Box 5\\nBag 7\\n\" from cross-module super dispatch, got %S" out)
  )

(* Phase 69.x-e: method-level-constraint dictionary passing across modules.  A
   user `Monoid`/`Semigroup` impl (for `Sum`) lives in one module; `foldMap`
   (a prelude Foldable method carrying `Monoid m`) is used in another.  Mirrors
   bin/main.ml's multi-module pipeline: mark → typecheck chain → Dict_pass over
   `marked_prelude @ modules` → eval ~prelude:false, so foldMap's default body
   gets its dict param and `empty` resolves to the imported Sum monoid. *)
let test_eval_method_dict_cross_module () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "summod.mdk"
      "public export data Sum = MkSum Int\n\n\
       export impl Semigroup Sum where\n\
      \  append (MkSum a) (MkSum b) = MkSum (a + b)\n\n\
       export impl Monoid Sum where\n\
      \  empty = MkSum 0\n\n\
       export unwrap : Sum -> Int\n\
       unwrap (MkSum n) = n\n" in
    let main_path = write_file dir "main.mdk"
      "import summod.{Sum, MkSum, unwrap}\n\n\
       main : <IO> Unit\n\
       main =\n\
      \  let r = foldMap MkSum [1, 2, 3, 4]\n\
      \  if unwrap r == 10 then println \"OK\" else println \"BAD\"\n" in
    let modules = Loader.load_program main_path [dir] in
    let modules = List.map (fun (mid, fp, prog) ->
      (mid, fp, Desugar.desugar_program prog)) modules in
    let method_names = Method_marker.interface_method_names
      (Prelude.program :: List.map (fun (_, _, p) -> p) modules) in
    let constrained = Method_marker.constrained_fn_names
      (List.map (fun (_, _, p) -> p) modules) in
    let modules = List.map (fun (mid, fp, prog) ->
      (mid, fp, Method_marker.mark_program method_names constrained prog)) modules in
    let te_acc = ref [] in
    List.iter (fun (mid, _, prog) ->
      let (te, _, _) = Typecheck.typecheck_module !te_acc mid prog in
      te_acc := te :: !te_acc) modules;
    let combined = List.concat_map (fun (_, _, p) -> p) modules in
    let combined = Dict_pass.run (Method_marker.marked_prelude @ combined) in
    let buf = Buffer.create 32 in
    let saved = !Eval.output_hook in
    Eval.output_hook := Buffer.add_string buf;
    Fun.protect ~finally:(fun () -> Eval.output_hook := saved) (fun () ->
      ignore (Eval.eval_program ~prelude:false combined));
    let out = Buffer.contents buf in
    if out <> "OK\n" then
      failwith (Printf.sprintf "Expected \"OK\\n\" from cross-module foldMap method dict, got %S" out)
  )

(* Phase 110: per-module eval name-isolation.  Two modules define a top-level
   function of the same name with different arities — `mapmod.singleton` takes 2
   args, `arrmod.singleton` takes 1 — exactly the stdlib map/array collision.
   `mapmod.wrap` calls its *own* 2-arg `singleton`.  Under the old flat eval the
   two `singleton`s merged into one VMulti, the 1-arg clause matched first, and
   `wrap 3 4` panicked `applied non-function`.  `Eval.eval_modules` evaluates
   each module in its own frame, so `wrap` sees mapmod's `singleton` and main
   sees arrmod's.  Mirrors bin/main.ml's `Run` driver. *)
let test_eval_module_isolation () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "mapmod.mdk"
      "export wrap : Int -> Int -> Int\n\
       wrap x y = singleton x y\n\n\
       export singleton : Int -> Int -> Int\n\
       singleton x y = x + y\n" in
    let _ = write_file dir "arrmod.mdk"
      "export singleton : Int -> Int\n\
       singleton x = x * 100\n" in
    let main_path = write_file dir "main.mdk"
      "import mapmod.{wrap}\n\
       import arrmod.{singleton}\n\n\
       main : <IO> Unit\n\
       main =\n\
      \  println (wrap 3 4)\n\
      \  println (singleton 5)\n" in
    let modules = Loader.load_program main_path [dir] in
    let modules = List.map (fun (mid, fp, prog) ->
      (mid, fp, Desugar.desugar_program prog)) modules in
    let method_names = Method_marker.interface_method_names
      (Prelude.program :: List.map (fun (_, _, p) -> p) modules) in
    let constrained = Method_marker.constrained_fn_names
      (List.map (fun (_, _, p) -> p) modules) in
    let modules = List.map (fun (mid, fp, prog) ->
      (mid, fp, Method_marker.mark_program method_names constrained prog)) modules in
    let te_acc = ref [] in
    List.iter (fun (mid, _, prog) ->
      let (te, _, _) = Typecheck.typecheck_module !te_acc mid prog in
      te_acc := te :: !te_acc) modules;
    let buf = Buffer.create 32 in
    let saved = !Eval.output_hook in
    Eval.output_hook := Buffer.add_string buf;
    Fun.protect ~finally:(fun () -> Eval.output_hook := saved) (fun () ->
      ignore (Eval.eval_modules modules));
    let out = Buffer.contents buf in
    if out <> "7\n500\n" then
      failwith (Printf.sprintf
        "Expected \"7\\n500\\n\" from per-module isolated singleton, got %S" out)
  )

(* Phase 88: two-pass elaboration across modules.  A polymorphic-monad do-block
   wrapper (`h m = do { x <- m; pure x }`) defined in the main module of a
   multi-module program must dispatch its return-position `pure` by the caller's
   monad, like the single-file driver (Phase 84) and the REPL (Phase 87).  Mirrors
   bin/main.ml's multi-module pipeline: pass 1 mark+typecheck discovers `h` as
   promotable; pass 2 re-marks with it constrained and re-typechecks ~promoted so
   `pure` routes via a threaded dictionary.  Without the second pass `h (Some 5)`
   renders as `[5]` (arg-tag "first impl wins" → List). *)
let test_eval_poly_monad_cross_module () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "dep.mdk"
      "export id2 : a -> a\nid2 x = x\n" in
    let main_path = write_file dir "main.mdk"
      "import dep.{id2}\n\n\
       h m = do\n\
      \  x <- m\n\
      \  pure x\n\n\
       main : <IO> Unit\n\
       main = println (show (h (Some (id2 5))))\n" in
    let modules = Loader.load_program main_path [dir] in
    let modules = List.map (fun (mid, fp, prog) ->
      (mid, fp, Desugar.desugar_program prog)) modules in
    let method_names = Method_marker.interface_method_names
      (Prelude.program :: List.map (fun (_, _, p) -> p) modules) in
    let constrained = Method_marker.constrained_fn_names
      (Prelude.program :: List.map (fun (_, _, p) -> p) modules) in
    let typecheck_all ~constrained ?promoted () =
      let marked = List.map (fun (mid, fp, prog) ->
        (mid, fp, Method_marker.mark_program method_names constrained prog)) modules in
      let te_acc = ref [] in
      let promoted_out = Hashtbl.create 8 in
      List.iter (fun (mid, _, prog) ->
        let (te, _, _) =
          Typecheck.typecheck_module ?promoted ~promoted_out !te_acc mid prog in
        te_acc := te :: !te_acc) marked;
      (marked, promoted_out)
    in
    let (m1, promoted) = typecheck_all ~constrained () in
    let final =
      if Hashtbl.length promoted = 0 then m1
      else begin
        let c2 = Hashtbl.copy constrained in
        Hashtbl.iter (fun k () -> Hashtbl.replace c2 k ()) promoted;
        fst (typecheck_all ~constrained:c2 ~promoted ())
      end in
    let combined = List.concat_map (fun (_, _, p) -> p) final in
    let combined = Dict_pass.run (Method_marker.marked_prelude @ combined) in
    let buf = Buffer.create 32 in
    let saved = !Eval.output_hook in
    Eval.output_hook := Buffer.add_string buf;
    Fun.protect ~finally:(fun () -> Eval.output_hook := saved) (fun () ->
      ignore (Eval.eval_program ~prelude:false combined));
    let out = Buffer.contents buf in
    if out <> "Some 5\n" then
      failwith (Printf.sprintf
        "Expected \"Some 5\\n\" from cross-module poly-monad `pure` dispatch, got %S" out)
  )

(* Phase 95: the same poly-monad `pure` wrapper, but defined in an *imported*
   (non-main) module — the cross-module exported-wrapper case Phase 88 left open.
   It used to fail to type-check with a spurious prelude error: `flatMap f ma =
   andThen ma f` has parameters named `f`/`ma`; the imported wrapper's name
   collided with one of them, so the scope-blind EVar lookup wrongly attributed
   the import's inferred `Mappable` constraint to flatMap's parameter, and the
   Phase-83 entailment check rejected `flatMap` ("uses interface Mappable …").
   The fix makes those lookups local-shadow-aware.  Asserts (a) no spurious type
   error and (b) the imported wrapper dispatches `pure` by the caller's monad. *)
let test_eval_poly_monad_imported_module () =
  with_tmp_dir (fun dir ->
    let _ = write_file dir "dep.mdk"
      "export\nf m = do\n  x <- m\n  pure x\n" in
    let main_path = write_file dir "main.mdk"
      "import dep.{f}\n\n\
       main : <IO> Unit\n\
       main = println (show (f (Some 5)))\n" in
    let modules = Loader.load_program main_path [dir] in
    let modules = List.map (fun (mid, fp, prog) ->
      (mid, fp, Desugar.desugar_program prog)) modules in
    let method_names = Method_marker.interface_method_names
      (Prelude.program :: List.map (fun (_, _, p) -> p) modules) in
    let constrained = Method_marker.constrained_fn_names
      (Prelude.program :: List.map (fun (_, _, p) -> p) modules) in
    let typecheck_all ~constrained ?promoted () =
      let marked = List.map (fun (mid, fp, prog) ->
        (mid, fp, Method_marker.mark_program method_names constrained prog)) modules in
      let te_acc = ref [] in
      let promoted_out = Hashtbl.create 8 in
      List.iter (fun (mid, _, prog) ->
        let (te, _, _) =
          Typecheck.typecheck_module ?promoted ~promoted_out !te_acc mid prog in
        te_acc := te :: !te_acc) marked;
      (marked, promoted_out)
    in
    (* Pass 1 used to raise the spurious flatMap/Mappable error here. *)
    let (m1, promoted) =
      try typecheck_all ~constrained ()
      with Typecheck.Type_error (e, _) ->
        failwith ("unexpected type error: " ^ Typecheck.pp_error e)
    in
    let final =
      if Hashtbl.length promoted = 0 then m1
      else begin
        let c2 = Hashtbl.copy constrained in
        Hashtbl.iter (fun k () -> Hashtbl.replace c2 k ()) promoted;
        fst (typecheck_all ~constrained:c2 ~promoted ())
      end in
    let combined = List.concat_map (fun (_, _, p) -> p) final in
    let combined = Dict_pass.run (Method_marker.marked_prelude @ combined) in
    let buf = Buffer.create 32 in
    let saved = !Eval.output_hook in
    Eval.output_hook := Buffer.add_string buf;
    Fun.protect ~finally:(fun () -> Eval.output_hook := saved) (fun () ->
      ignore (Eval.eval_program ~prelude:false combined));
    let out = Buffer.contents buf in
    if out <> "Some 5\n" then
      failwith (Printf.sprintf
        "Expected \"Some 5\\n\" from imported poly-monad `pure` wrapper, got %S" out)
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
      test_case "import T(..): ctors allowed"          `Quick test_import_group_ctors_allowed;
      test_case "import T(..): abstract rejected"      `Quick test_import_group_ctors_abstract;
      test_case "re-export T(..): ctors re-exported"   `Quick test_reexport_group_ctors;
    ];
    "multi-file typecheck", [
      test_case "impl Mappable Array in dep module" `Quick test_typecheck_impl_in_dep_module;
      test_case "impl Mappable Wrapper in dep module" `Quick test_typecheck_impl_list_in_dep_module;
    ];
    "multi-file dictionary passing (Phase 69.x)", [
      test_case "cross-module constrained dispatch" `Quick test_eval_dict_passing_cross_module;
      test_case "cross-module super dispatch" `Quick test_eval_super_dict_cross_module;
      test_case "cross-module method-level dict (foldMap)" `Quick test_eval_method_dict_cross_module;
    ];
    "per-module eval isolation (Phase 110)", [
      test_case "same-named fn, different arity" `Quick test_eval_module_isolation;
    ];
    "two-pass elaboration (Phase 88)", [
      test_case "cross-module poly-monad pure dispatch" `Quick test_eval_poly_monad_cross_module;
    ];
    "local-shadow constraint attribution (Phase 95)", [
      test_case "imported poly-monad wrapper" `Quick test_eval_poly_monad_imported_module;
    ];
    "workspace / multi-root", [
      test_case "cross-member import"    `Quick test_workspace_cross_member_import;
      test_case "ambiguous module"       `Quick test_workspace_ambiguous_module;
      test_case "single-root compat"     `Quick test_single_root_compat;
    ];
  ]
