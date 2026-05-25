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
      "pub map f xs =\n  match xs\n    [] => []\n    h::t => (f h) :: (map f t)\n"
    in
    let main_path = write_file dir "main.mdk"
      "use list.{map}\ndouble x = x * 2\nmain : <IO> Unit\nmain =\n  do\n    let r = map double [1, 2, 3]\n    pure ()\n"
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
    let _ = write_file dir "a.mdk" "use b.{foo}\nx = 1\n" in
    let a_path = write_file dir "b.mdk" "use a.{x}\nfoo = 2\n" in
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
      "use nonexistent.{foo}\nmain : <IO> Unit\nmain = pure ()\n"
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
      "internal_helper x = x + 1\npub map f xs = []\n"
    in
    let main_path = write_file dir "main.mdk"
      "use list.{internal_helper}\nmain : <IO> Unit\nmain = pure ()\n"
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

let test_pub_parsing () =
  Lexer.reset ();
  let lexbuf = Lexing.from_string "pub map f xs = []\n" in
  let prog = Parser.program Lexer.token lexbuf in
  match prog with
  | [Ast.DFunDef (true, "map", _, _)] -> ()
  | _ -> failwith "expected pub DFunDef"

let test_pub_data_parsing () =
  Lexer.reset ();
  let lexbuf = Lexing.from_string "pub data Color = Red | Green | Blue\n" in
  let prog = Parser.program Lexer.token lexbuf in
  match prog with
  | [Ast.DData (true, "Color", [], _)] -> ()
  | _ -> failwith "expected pub DData"

let test_pub_round_trip () =
  Lexer.reset ();
  let src = "pub map f xs = []\n" in
  let lexbuf = Lexing.from_string src in
  let prog = Parser.program Lexer.token lexbuf in
  let printed = Printer.program_to_string prog in
  if not (String.sub printed 0 4 = "pub ") then
    failwith (Printf.sprintf "expected 'pub ' prefix in printed output, got: %s" printed)

(* ── Runner ──────────────────────────────────────── *)

let () =
  let open Alcotest in
  run "Medaka Loader" [
    "module ID derivation", [
      test_case "path to module id"  `Quick test_module_id_of_path;
    ];
    "pub keyword parsing", [
      test_case "pub fun_def"    `Quick test_pub_parsing;
      test_case "pub data decl"  `Quick test_pub_data_parsing;
      test_case "pub round-trip" `Quick test_pub_round_trip;
    ];
    "loader", [
      test_case "single file"      `Quick test_single_file;
      test_case "happy path"       `Quick test_happy_path;
      test_case "cycle detection"  `Quick test_cycle_detection;
      test_case "missing file"     `Quick test_missing_file;
      test_case "privacy violation" `Quick test_privacy_violation;
    ];
  ]
