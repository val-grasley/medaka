(* `medaka.toml` reader and project-root discovery.

   A config can hold a [package] table, a [workspace] table, or both.
   [package] requires name, version, entry (all strings).
   [workspace] requires members (array of relative paths to member dirs).
   Workspace-only configs have name/version/entry = None. *)

type workspace = { ws_members : string list }

type t = {
  name      : string option;
  version   : string option;
  entry     : string option;
  workspace : workspace option;
}

exception Parse_error of string

(* ── Tiny TOML reader ──────────────────────────────── *)

type toml_value = Str of string | Arr of string list

(* Strip a `#` comment from a line, respecting double-quoted strings so
   `entry = "foo#bar"` is preserved. *)
let strip_comment line =
  let n = String.length line in
  let buf = Buffer.create n in
  let in_str = ref false in
  let i = ref 0 in
  let stop = ref false in
  while not !stop && !i < n do
    let c = line.[!i] in
    if c = '"' then begin
      in_str := not !in_str;
      Buffer.add_char buf c
    end else if c = '#' && not !in_str then
      stop := true
    else
      Buffer.add_char buf c;
    incr i
  done;
  Buffer.contents buf

let trim s = String.trim s

let is_header s =
  let s = trim s in
  String.length s >= 2 && s.[0] = '[' && s.[String.length s - 1] = ']'

let header_name s =
  let s = trim s in
  String.sub s 1 (String.length s - 2) |> trim

(* Parse a double-quoted string starting at buf.[i]; return (value, next_i). *)
let parse_quoted_string buf start =
  assert (buf.[start] = '"');
  let n = String.length buf in
  let i = ref (start + 1) in
  let acc = Buffer.create 16 in
  let finished = ref false in
  while not !finished && !i < n do
    let c = buf.[!i] in
    if c = '"' then (incr i; finished := true)
    else (Buffer.add_char acc c; incr i)
  done;
  if not !finished then
    raise (Parse_error "unterminated string in medaka.toml");
  (Buffer.contents acc, !i)

(* Parse a TOML array of strings: ["a", "b", "c"].
   Expects the leading '[' at buf.[start]. *)
let parse_array_value buf start =
  assert (buf.[start] = '[');
  let n = String.length buf in
  let i = ref (start + 1) in
  let items = ref [] in
  let done_ = ref false in
  while not !done_ && !i < n do
    while !i < n && (buf.[!i] = ' ' || buf.[!i] = '\t' || buf.[!i] = ',') do
      incr i
    done;
    if !i >= n then raise (Parse_error "unterminated array in medaka.toml")
    else if buf.[!i] = ']' then (incr i; done_ := true)
    else if buf.[!i] = '"' then begin
      let (s, next_i) = parse_quoted_string buf !i in
      items := s :: !items;
      i := next_i
    end else
      raise (Parse_error (Printf.sprintf "unexpected character in array: %c" buf.[!i]))
  done;
  Arr (List.rev !items)

(* Parse a `key = value` line where value is a quoted string or an array.
   Returns (key, toml_value).  Raises Parse_error on malformed input. *)
let parse_kv line =
  match String.index_opt line '=' with
  | None -> raise (Parse_error (Printf.sprintf "expected `=` in: %s" line))
  | Some eq ->
    let key = trim (String.sub line 0 eq) in
    let rest = trim (String.sub line (eq + 1) (String.length line - eq - 1)) in
    let n = String.length rest in
    if n = 0 then
      raise (Parse_error (Printf.sprintf "missing value for key %S" key));
    let value =
      if rest.[0] = '[' then
        parse_array_value rest 0
      else if rest.[0] = '"' then begin
        if rest.[n - 1] <> '"' then
          raise (Parse_error (Printf.sprintf "expected double-quoted string for key %S" key));
        let v = String.sub rest 1 (n - 2) in
        Str v
      end else
        raise (Parse_error (Printf.sprintf "expected double-quoted string or array for key %S" key))
    in
    (key, value)

let parse_string src =
  let lines = String.split_on_char '\n' src in
  let section = ref "" in
  let kvs : (string * toml_value) list ref = ref [] in
  List.iter (fun raw ->
    let line = trim (strip_comment raw) in
    if line = "" then ()
    else if is_header line then section := header_name line
    else begin
      let (k, v) = parse_kv line in
      let qualified =
        if !section = "" || !section = "package" then k
        else !section ^ "." ^ k
      in
      kvs := (qualified, v) :: !kvs
    end
  ) lines;
  let lookup k =
    try Some (List.assoc k !kvs) with Not_found -> None
  in
  let opt_str k =
    match lookup k with
    | None -> None
    | Some (Str s) -> Some s
    | Some (Arr _) ->
      raise (Parse_error (Printf.sprintf "expected string for key %S, got array" k))
  in
  let require_str k =
    match opt_str k with
    | Some s -> s
    | None -> raise (Parse_error (Printf.sprintf "missing required key: %s" k))
  in
  let opt_arr k =
    match lookup k with
    | None -> None
    | Some (Arr a) -> Some a
    | Some (Str _) ->
      raise (Parse_error (Printf.sprintf "expected array for key %S, got string" k))
  in
  (* If any [package] key is present, all three are required. *)
  let has_package =
    List.exists (fun (k, _) -> k = "name" || k = "version" || k = "entry") !kvs
  in
  let (name, version, entry) =
    if has_package then
      (Some (require_str "name"),
       Some (require_str "version"),
       Some (require_str "entry"))
    else
      (None, None, None)
  in
  (* Warn on unknown top-level keys — allow package and workspace sub-keys. *)
  let known_keys = ["name"; "version"; "entry"; "workspace.members"] in
  List.iter (fun (k, _) ->
    if not (List.mem k known_keys) then
      Printf.eprintf "medaka.toml: warning: unknown key %S\n" k
  ) (List.rev !kvs);
  let workspace =
    match opt_arr "workspace.members" with
    | Some ms -> Some { ws_members = ms }
    | None -> None
  in
  { name; version; entry; workspace }

(* ── Filesystem helpers ────────────────────────────── *)

let toml_filename = "medaka.toml"

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = Bytes.create n in
  really_input ic s 0 n;
  close_in ic;
  Bytes.to_string s

let load_from_dir dir =
  let path = Filename.concat dir toml_filename in
  if Sys.file_exists path then
    try Some (parse_string (read_file path))
    with Parse_error _ as e -> raise e
  else None

let find_project_root file_path =
  let start = Filename.dirname file_path in
  let rec walk dir =
    if Sys.file_exists (Filename.concat dir toml_filename) then Some dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then None
      else walk parent
  in
  walk start

(* Like find_project_root, but only stops at a config with a [workspace] table. *)
let find_workspace_root file_path =
  let start = Filename.dirname file_path in
  let rec walk dir =
    let path = Filename.concat dir toml_filename in
    if Sys.file_exists path then begin
      let cfg_opt =
        try Some (parse_string (read_file path))
        with Parse_error _ -> None
      in
      match cfg_opt with
      | Some cfg when cfg.workspace <> None -> Some dir
      | _ ->
        let parent = Filename.dirname dir in
        if parent = dir then None else walk parent
    end else begin
      let parent = Filename.dirname dir in
      if parent = dir then None else walk parent
    end
  in
  walk start

(* Load (member_dir, config) for each member listed in a workspace config.
   Raises Parse_error if a member directory is missing or has no medaka.toml. *)
let load_workspace_members root =
  match load_from_dir root with
  | None -> []
  | Some cfg ->
    match cfg.workspace with
    | None -> []
    | Some ws ->
      List.map (fun rel_path ->
        let member_dir = Filename.concat root rel_path in
        if not (Sys.file_exists member_dir && Sys.is_directory member_dir) then
          raise (Parse_error
            (Printf.sprintf "workspace member directory not found: %s" member_dir));
        match load_from_dir member_dir with
        | None ->
          raise (Parse_error
            (Printf.sprintf "workspace member has no medaka.toml: %s" member_dir))
        | Some member_cfg -> (member_dir, member_cfg)
      ) ws.ws_members
