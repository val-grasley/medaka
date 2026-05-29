(* Loader: parse a program's transitive file dependencies and return them
   in topological (dependency-first) order.

   Module ID derivation: given a list of search roots and a file path, try
   each root as a prefix, take the first match, strip the .mdk suffix, then
   replace / with dots.
   Example: roots=["/p/src"], file=/p/src/list/core.mdk → "list.core"

   Multi-root (workspace) mode: pass one root per workspace member.  A module
   ID is ambiguous if it resolves to a file in two or more roots — this raises
   AmbiguousModule. *)

type load_error =
  | FileNotFound     of string          (* file path *)
  | CyclicDependency of string list     (* module path forming the cycle *)
  | UnknownModule    of { mod_id: string; importer_file: string option }
  | AmbiguousModule  of { mod_id: string; found_in: string list }
  | ParseError       of { file: string; line: int; col: int; message: string }

exception LoadError of load_error

(* ── Path / module-ID utilities ───────────────────── *)

let normalize_path p =
  (* Remove trailing slash from directory *)
  if String.length p > 0 && p.[String.length p - 1] = '/' then
    String.sub p 0 (String.length p - 1)
  else p

(* Derive the module ID for a file by trying each root as a prefix.
   Falls back to the bare filename (no extension) if no root matches. *)
let module_id_of_path roots file_path =
  let file_path = normalize_path file_path in
  let rel = List.find_map (fun root ->
    let root = normalize_path root in
    let prefix = root ^ "/" in
    if String.length file_path > String.length prefix
       && String.sub file_path 0 (String.length prefix) = prefix
    then Some (String.sub file_path (String.length prefix)
                 (String.length file_path - String.length prefix))
    else None
  ) roots in
  let rel = match rel with
    | Some r -> r
    | None -> Filename.basename file_path
  in
  (* Strip .mdk suffix *)
  let rel =
    if Filename.check_suffix rel ".mdk"
    then Filename.chop_suffix rel ".mdk"
    else rel
  in
  (* Replace path separators with dots *)
  String.concat "." (String.split_on_char '/' rel)

(* Compute the file path for a module ID under a single root (no existence check). *)
let file_of_module_id project_dir mod_id =
  let project_dir = normalize_path project_dir in
  let rel = String.concat "/" (String.split_on_char '.' mod_id) ^ ".mdk" in
  project_dir ^ "/" ^ rel

(* ── Parsing ──────────────────────────────────────── *)

(* read_file ~read path: try the buffer-override callback first; if it
   returns Some s use that, else fall back to disk.  The LSP injects
   `read` to surface unsaved buffer content; the CLI passes None. *)
let read_file ?(read : (string -> string option) option) path =
  let buffered =
    match read with
    | Some f -> f path
    | None   -> None
  in
  match buffered with
  | Some s -> s
  | None ->
    if not (Sys.file_exists path) then raise (LoadError (FileNotFound path));
    let ic = open_in path in
    let n = in_channel_length ic in
    let s = Bytes.create n in
    really_input ic s 0 n;
    close_in ic;
    Bytes.to_string s

let parse_file ?read path =
  let source = read_file ?read path in
  let lexbuf = Lexing.from_string source in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = path };
  Lexer.reset ();
  let raise_parse_error message =
    let pos = lexbuf.Lexing.lex_curr_p in
    raise (LoadError (ParseError {
      file = path;
      line = pos.Lexing.pos_lnum;
      col  = pos.Lexing.pos_cnum - pos.Lexing.pos_bol;
      message;
    }))
  in
  try Parser.program Lexer.token lexbuf
  with
  | Parser.Error -> raise_parse_error "Parse error"
  | Failure msg  -> raise_parse_error msg

(* ── Dependency extraction ────────────────────────── *)

(* "core" is the implicit prelude — its declarations are prepended automatically
   by the type-checker and evaluator.  An `import core.{...}` is a no-op
   (the names are already in scope); the loader must skip "core" so it doesn't
   end up duplicating the prelude when a user file imports from it. *)
let is_prelude_module = function
  | "core" -> true
  | _      -> false

(* Extract the module IDs that a program directly imports via `use` *)
let direct_imports (prog : Ast.program) : string list =
  List.filter_map (function
    | Ast.DUse (_, path) ->
      let parts = match path with
        | Ast.UseName  ns      -> ns
        | Ast.UseGroup (ns, _) -> ns
        | Ast.UseWild  ns      -> ns
        | Ast.UseAlias (ns, _) -> ns
      in
      (* Module ID is the dotted path minus the last segment when UseName
         refers to a specific name rather than a module. For all other forms
         the path IS the module, so take it directly. *)
      let mid =
        match path with
        | Ast.UseName ns when List.length ns > 1 ->
          (* use foo.bar → module is "foo", name is "bar" *)
          String.concat "." (List.rev (List.tl (List.rev ns)))
        | Ast.UseName [single] ->
          (* use foo → module is "foo" *)
          single
        | _ ->
          String.concat "." parts
      in
      if is_prelude_module mid then None else Some mid
    | _ -> None
  ) prog

(* ── Topological sort (DFS) ──────────────────────── *)

type node_state = Unvisited | InStack | Done

(* A file is "available" if the buffer override has content for it OR
   the file exists on disk.  Used when discovering a dependency. *)
let file_available ?read path =
  let buffered =
    match read with
    | Some f -> f path
    | None   -> None
  in
  match buffered with
  | Some _ -> true
  | None   -> Sys.file_exists path

(* Find all candidate file paths for a module ID across multiple search roots.
   Returns a list of existing paths (0 = not found, 1 = unique, 2+ = ambiguous). *)
let find_module_files ?read roots mod_id =
  List.filter_map (fun root ->
    let path = file_of_module_id root mod_id in
    if file_available ?read path then Some path else None
  ) roots

(* Returns modules in dependency-first order (leaves before roots) *)
let topo_sort
    ?read
    (roots      : string list)
    (root_id    : string)
    (root_path  : string)
    (root_prog  : Ast.program)
  : (string * string * Ast.program) list =
  (* module_id → (file_path, program) *)
  let loaded : (string, string * Ast.program) Hashtbl.t = Hashtbl.create 8 in
  let state  : (string, node_state) Hashtbl.t = Hashtbl.create 8 in
  let result : (string * string * Ast.program) list ref = ref [] in

  Hashtbl.replace loaded root_id (root_path, root_prog);

  let rec visit ~stack ~importer mod_id =
    match Hashtbl.find_opt state mod_id with
    | Some Done -> ()
    | Some InStack ->
      (* Cycle: collect everything on the stack back to the repeated node *)
      let rec take_until acc = function
        | [] -> List.rev acc
        | m :: _ when m = mod_id -> List.rev (m :: acc)
        | m :: rest -> take_until (m :: acc) rest
      in
      let cycle = take_until [mod_id] stack in
      raise (LoadError (CyclicDependency cycle))
    | None | Some Unvisited ->
      Hashtbl.replace state mod_id InStack;
      let (file_path, prog) =
        match Hashtbl.find_opt loaded mod_id with
        | Some p -> p
        | None ->
          let candidates = find_module_files ?read roots mod_id in
          (match candidates with
           | [] ->
             raise (LoadError (UnknownModule { mod_id; importer_file = importer }))
           | [path] ->
             let prog = parse_file ?read path in
             Hashtbl.replace loaded mod_id (path, prog);
             (path, prog)
           | paths ->
             raise (LoadError (AmbiguousModule { mod_id; found_in = paths })))
      in
      List.iter (fun dep_id ->
        visit ~stack:(mod_id :: stack) ~importer:(Some file_path) dep_id
      ) (direct_imports prog);
      Hashtbl.replace state mod_id Done;
      result := (mod_id, file_path, prog) :: !result
  in
  visit ~stack:[] ~importer:None root_id;
  List.rev !result

(* ── Public entry point ───────────────────────────── *)

(* Load a root .mdk file and all its transitive dependencies.
   roots is a list of directories used to resolve module IDs to file paths.
   For single-package projects pass [project_dir]; for workspaces pass one
   entry per member directory.
   Returns (module_id, file_path, program) list in dependency-first order. *)
let load_program ?read root_file roots =
  let root_id   = module_id_of_path roots root_file in
  let root_prog = parse_file ?read root_file in
  topo_sort ?read roots root_id root_file root_prog
