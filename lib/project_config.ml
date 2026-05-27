(* `medaka.toml` reader and project-root discovery.

   The schema is a fixed, minimal subset of TOML: a `[package]` table
   with three string fields.  Rather than depend on a full TOML library
   we parse just enough by hand. *)

type t = {
  name    : string;
  version : string;
  entry   : string;
}

exception Parse_error of string

(* ── Tiny TOML reader ──────────────────────────────── *)

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

(* Parse a `key = "value"` line.  Returns (key, value).  Raises
   Parse_error on malformed input. *)
let parse_kv line =
  match String.index_opt line '=' with
  | None -> raise (Parse_error (Printf.sprintf "expected `=` in: %s" line))
  | Some eq ->
    let key = trim (String.sub line 0 eq) in
    let rest = trim (String.sub line (eq + 1) (String.length line - eq - 1)) in
    let n = String.length rest in
    if n < 2 || rest.[0] <> '"' || rest.[n - 1] <> '"' then
      raise (Parse_error
               (Printf.sprintf "expected double-quoted string for key %S" key));
    let v = String.sub rest 1 (n - 2) in
    (key, v)

let parse_string src =
  let lines = String.split_on_char '\n' src in
  let section = ref "" in
  let kvs : (string * string) list ref = ref [] in
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
  let require k =
    match lookup k with
    | Some v -> v
    | None -> raise (Parse_error (Printf.sprintf "missing required key: %s" k))
  in
  let name    = require "name" in
  let version = require "version" in
  let entry   = require "entry" in
  (* One-line warning for unknown keys, so a typo is visible without
     being fatal. *)
  List.iter (fun (k, _) ->
    if k <> "name" && k <> "version" && k <> "entry" then
      Printf.eprintf "medaka.toml: warning: unknown key %S\n" k
  ) (List.rev !kvs);
  { name; version; entry }

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
