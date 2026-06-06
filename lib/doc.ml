(* lib/doc.ml — `medaka doc` documentation extractor.
   Harvests doc comments from the lexer's side-channel, matches them to
   top-level public declarations by position, looks up inferred types from
   the type-checker, and renders Markdown. *)

type doc_entry = {
  de_name : string;
  de_sig  : string;   (* signature string, never empty *)
  de_doc  : string;   (* stripped doc prose, may be "" *)
}

(* ── Comment-text extraction ──────────────────────────────────────────────── *)

(* Strip the `-- ` prefix from a line-comment text, returning the bare prose. *)
let comment_body (t : string) : string =
  if t = "--" then ""
  else if String.length t >= 3 && String.sub t 0 3 = "-- " then
    String.sub t 3 (String.length t - 3)
  else if String.length t > 2 then
    String.sub t 2 (String.length t - 2)
  else ""

(* Expand a comment record into a list of (line, text) pairs.
   Block comments are expanded to one entry per inner line (like doctest.ml's
   expand_block), so the comment table maps every line they span. *)
let expand_comment (c : Lexer.comment) : (int * string) list =
  let t = c.Lexer.c_text in
  if String.length t >= 2 && String.sub t 0 2 = "{-" then
    let n = String.length t in
    let inner = if n >= 4 then String.sub t 2 (n - 4) else "" in
    String.split_on_char '\n' inner
    |> List.mapi (fun i line -> (c.Lexer.c_line + i, String.trim line))
  else
    [(c.Lexer.c_line, comment_body t)]

(* Build a line→text hashtable from the comment list. *)
let build_comment_tbl (comments : Lexer.comment list) : (int, string) Hashtbl.t =
  let tbl = Hashtbl.create 64 in
  List.iter (fun c ->
    List.iter (fun (line, text) ->
      Hashtbl.replace tbl line text
    ) (expand_comment c)
  ) comments;
  tbl

(* Return the doc prose for the decl at [start_line]: the maximal consecutive
   block of comments immediately above it (no line gap between last comment and
   the decl).  Result is newline-joined and trimmed; "" if no comments found. *)
let find_doc_for_line (tbl : (int, string) Hashtbl.t) (start_line : int) : string =
  (* Collect backwards; accumulator ends up in ascending line order. *)
  let rec collect acc line =
    match Hashtbl.find_opt tbl line with
    | None      -> acc
    | Some text -> collect (text :: acc) (line - 1)
  in
  String.concat "\n" (collect [] (start_line - 1)) |> String.trim

(* ── Signature rendering ──────────────────────────────────────────────────── *)

let pp_data_variant (v : Ast.data_variant) : string =
  match v.Ast.con_payload with
  | Ast.ConPos []   -> v.Ast.con_name
  | Ast.ConPos tys  ->
    v.Ast.con_name ^ " " ^ String.concat " " (List.map (Ast.pp_ty_prec 2) tys)
  | Ast.ConNamed fs ->
    v.Ast.con_name ^ " { " ^
    String.concat ", " (List.map (fun f ->
      f.Ast.field_name ^ " : " ^ Ast.pp_ty f.Ast.field_type) fs) ^
    " }"

let pp_record_fields (fields : Ast.record_field list) : string =
  "{ " ^ String.concat ", " (List.map (fun f ->
    f.Ast.field_name ^ " : " ^ Ast.pp_ty f.Ast.field_type) fields) ^ " }"

let pp_requires (rs : (Ast.ident * Ast.ty list) list) : string =
  match rs with
  | [] -> ""
  | _  ->
    " requires " ^ String.concat ", " (List.map (fun (iface, tys) ->
      if tys = [] then iface
      else iface ^ " " ^ String.concat " " (List.map (Ast.pp_ty_prec 2) tys)
    ) rs)

(* Look up the inferred scheme for [name]; fall back to the AST type annotation
   when typecheck didn't produce a scheme for this name (shouldn't happen for
   well-typed programs, but we don't want to crash on partial results). *)
let value_sig name schemes fallback_ty =
  match List.assoc_opt name schemes with
  | Some s -> name ^ " : " ^ Typecheck.pp_scheme s
  | None   ->
    match fallback_ty with
    | Some ty -> name ^ " : " ^ Ast.pp_ty ty
    | None    -> name

(* Compute the signature string for a public decl, or [None] to skip it. *)
let render_sig (d : Ast.decl) (schemes : (string * Typecheck.scheme) list)
    : (string * string) option =
  (* Returns (name, sig_string) or None *)
  match Ast.inner_decl d with
  | Ast.DTypeSig (true, name, ty) ->
    (* Include the type sig decl — it carries the doc comment when placed
       above a DFunDef.  Use the inferred scheme so the rendered type is
       consistent with what the checker proved. *)
    Some (name, value_sig name schemes (Some ty))

  | Ast.DFunDef (true, name, _, _) ->
    Some (name, value_sig name schemes None)

  | Ast.DExtern (true, name, ty) ->
    Some (name, value_sig name schemes (Some ty))

  | Ast.DLetGroup (true, bindings) ->
    (* Mutual-recursion group: document each name as its own entry.
       We'll return the FIRST name here; the caller handles the full group. *)
    (match bindings with
     | (name, _) :: _ -> Some (name, value_sig name schemes None)
     | []             -> None)

  | Ast.DData (vis, name, params, variants, _) when vis <> Ast.DataPrivate ->
    let head = String.concat " " (name :: params) in
    let body = match variants with
      | [] -> ""
      | _  ->
        "\n  = " ^ String.concat "\n  | " (List.map pp_data_variant variants)
    in
    Some (name, "data " ^ head ^ body)

  | Ast.DRecord (vis, name, params, fields, _) when vis <> Ast.DataPrivate ->
    let head = String.concat " " (name :: params) in
    Some (name, "record " ^ head ^ " " ^ pp_record_fields fields)

  | Ast.DInterface { is_pub = true; iface_name; type_params; methods; _ } ->
    let head = String.concat " " (iface_name :: type_params) in
    let ms   = List.map (fun m ->
      "  " ^ m.Ast.method_name ^ " : " ^ Ast.pp_ty m.Ast.method_type
    ) methods in
    let body = if ms = [] then "" else "\n" ^ String.concat "\n" ms in
    Some (iface_name, "interface " ^ head ^ body)

  | Ast.DTypeAlias (true, name, params, ty) ->
    let head = String.concat " " (name :: params) in
    Some (name, "type " ^ head ^ " = " ^ Ast.pp_ty ty)

  | Ast.DNewtype (true, name, params, ctor, ty, _) ->
    let head = String.concat " " (name :: params) in
    Some (name, "newtype " ^ head ^ " = " ^ ctor ^ " " ^ Ast.pp_ty_prec 2 ty)

  | Ast.DImpl { is_pub = true; iface_name; type_args; requires; _ } ->
    let args = match type_args with
      | [] -> ""
      | _  -> " " ^ String.concat " " (List.map (Ast.pp_ty_prec 2) type_args)
    in
    Some (iface_name ^ args, "impl " ^ iface_name ^ args ^ pp_requires requires)

  | _ -> None

(* ── Entry extraction ────────────────────────────────────────────────────── *)

(* Also expand DLetGroup into one entry per name. *)
let all_letgroup_entries
    (is_pub : bool)
    (bindings : (Ast.ident * (Ast.pat list * Ast.expr) list) list)
    (loc : Ast.loc)
    (schemes : (string * Typecheck.scheme) list)
    (tbl : (int, string) Hashtbl.t)
    : (string * doc_entry) list =
  if not is_pub then []
  else begin
    let doc = find_doc_for_line tbl loc.Ast.line in
    List.filter_map (fun (name, _) ->
      let sig_str = value_sig name schemes None in
      Some (name, { de_name = name; de_sig = sig_str; de_doc = doc })
    ) bindings
  end

let extract_entries
    (decls    : Ast.decl list)
    (positions: Ast.loc list)
    (schemes  : (string * Typecheck.scheme) list)
    (comments : Lexer.comment list)
    : doc_entry list =
  let tbl  = build_comment_tbl comments in
  let seen : (string, unit) Hashtbl.t = Hashtbl.create 32 in
  let unseen name = not (Hashtbl.mem seen name) in
  let mark  name = Hashtbl.replace seen name () in
  let pairs = List.combine decls positions in
  let rev_entries = List.fold_left (fun acc (decl, loc) ->
    match Ast.inner_decl decl with
    | Ast.DLetGroup (is_pub, bindings) ->
      let extras = all_letgroup_entries is_pub bindings loc schemes tbl in
      List.fold_left (fun a (name, e) ->
        if unseen name then begin mark name; e :: a end else a
      ) acc extras
    | _ ->
      (match render_sig decl schemes with
       | None -> acc
       | Some (name, sig_str) ->
         if unseen name then begin
           mark name;
           let doc = find_doc_for_line tbl loc.Ast.line in
           { de_name = name; de_sig = sig_str; de_doc = doc } :: acc
         end else acc)
  ) [] pairs in
  List.rev rev_entries

(* ── Markdown rendering ──────────────────────────────────────────────────── *)

let render_markdown (module_name : string) (entries : doc_entry list) : string =
  let buf = Buffer.create 1024 in
  Buffer.add_string buf (Printf.sprintf "# %s\n\n" module_name);
  List.iter (fun e ->
    Buffer.add_string buf (Printf.sprintf "## `%s`\n\n" e.de_name);
    Buffer.add_string buf (Printf.sprintf "```\n%s\n```\n" e.de_sig);
    if e.de_doc <> "" then begin
      Buffer.add_char buf '\n';
      Buffer.add_string buf e.de_doc;
      Buffer.add_char buf '\n'
    end;
    Buffer.add_char buf '\n'
  ) entries;
  Buffer.contents buf
