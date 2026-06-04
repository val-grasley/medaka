(* dev/astdump.ml — dump a canonical, location-stripped S-expression of the
   parsed AST for a file: the structural reference the self-hosted parser is
   validated against (the Phase-131 token_to_string analog for the AST).
   Usage: astdump <file.mdk>

   Format: one top-level decl per line, each a single S-expression.  Tags are the
   OCaml constructor names so this and selfhost/sexp.mdk stay in lockstep.
   Strings use a fixed minimal escaping (backslash, quote, n, t, r) -- NOT OCaml
   %S -- so the two hosts agree.  Floats are rendered loosely and normalized away
   by the diff script (host %g vs floatToString), same as the lexer FLOAT.

   Coverage grows with the parser port; nodes not yet covered render as a TODO
   placeholder on both sides. *)

open Medaka_lib
open Ast

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let buf = Bytes.create n in
  really_input ic buf 0 n;
  close_in ic;
  Bytes.to_string buf

(* Shared minimal string escaping (must match selfhost/sexp.mdk's escStr). *)
let esc_str s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter (fun c ->
    match c with
    | '\\' -> Buffer.add_string b "\\\\"
    | '"'  -> Buffer.add_string b "\\\""
    | '\n' -> Buffer.add_string b "\\n"
    | '\t' -> Buffer.add_string b "\\t"
    | '\r' -> Buffer.add_string b "\\r"
    | c    -> Buffer.add_char b c) s;
  Buffer.add_char b '"';
  Buffer.contents b

let node tag parts = "(" ^ String.concat " " (tag :: parts) ^ ")"
let slist xs = "(" ^ String.concat " " xs ^ ")"

let sexp_lit = function
  | LInt n    -> node "LInt" [string_of_int n]
  | LFloat f  -> node "LFloat" [Printf.sprintf "%g" f]
  | LString s -> node "LString" [esc_str s]
  | LChar s   -> node "LChar" [esc_str s]
  | LBool b   -> node "LBool" [string_of_bool b]
  | LUnit     -> "LUnit"

let todo tag = node "TODO" [tag]

let rec sexp_pat = function
  | PVar x        -> node "PVar" [esc_str x]
  | PWild         -> "PWild"
  | PLit l        -> node "PLit" [sexp_lit l]
  | PCon (c, ps)  -> node "PCon" (esc_str c :: List.map sexp_pat ps)
  | PCons (a, b)  -> node "PCons" [sexp_pat a; sexp_pat b]
  | PTuple ps     -> node "PTuple" (List.map sexp_pat ps)
  | PList ps      -> node "PList" (List.map sexp_pat ps)
  | PAs (x, p)    -> node "PAs" [esc_str x; sexp_pat p]
  | PRec _        -> todo "PRec"
  | PRng _        -> todo "PRng"

let rec sexp_expr e =
  match e with
  | ELoc (_, e)        -> sexp_expr e
  | ELit l             -> node "ELit" [sexp_lit l]
  | EVar x             -> node "EVar" [esc_str x]
  | EApp (f, x)        -> node "EApp" [sexp_expr f; sexp_expr x]
  | ELam (ps, b)       -> node "ELam" [slist (List.map sexp_pat ps); sexp_expr b]
  | ELet (m, _, p, e1, e2) ->
      node "ELet" [string_of_bool m; sexp_pat p; sexp_expr e1; sexp_expr e2]
  | EMatch (s, arms)   -> node "EMatch" (sexp_expr s :: List.map sexp_arm arms)
  | EIf (c, t, e)      -> node "EIf" [sexp_expr c; sexp_expr t; sexp_expr e]
  | EBinOp (op, a, b)  -> node "EBinOp" [esc_str op; sexp_expr a; sexp_expr b]
  | EUnOp (op, a)      -> node "EUnOp" [esc_str op; sexp_expr a]
  | EInfix (op, a, b)  -> node "EInfix" [esc_str op; sexp_expr a; sexp_expr b]
  | EFieldAccess (e, f)-> node "EFieldAccess" [sexp_expr e; esc_str f]
  | ETuple es          -> node "ETuple" (List.map sexp_expr es)
  | EListLit es        -> node "EListLit" (List.map sexp_expr es)
  | EArrayLit es       -> node "EArrayLit" (List.map sexp_expr es)
  | ERangeList (lo, hi, incl) -> node "ERangeList" [sexp_expr lo; sexp_expr hi; string_of_bool incl]
  | ELetGroup (binds, body) -> node "ELetGroup" [slist (List.map sexp_letbind binds); sexp_expr body]
  | EIndex (a, i)      -> node "EIndex" [sexp_expr a; sexp_expr i]
  | EAnnot (e, t)      -> node "EAnnot" [sexp_expr e; sexp_ty t]
  | EBlock stmts       -> node "EBlock" (List.map sexp_dostmt stmts)
  | EDo (_, stmts)     -> node "EDo" (List.map sexp_dostmt stmts)
  | EStringInterp parts -> node "EStringInterp" (List.map sexp_interp parts)
  | EGuards arms       -> node "EGuards" (List.map sexp_garm arms)
  | ERecordCreate (n, fs) -> node "ERecordCreate" [esc_str n; slist (List.map sexp_fassign fs)]
  | ERecordUpdate (e, fs) -> node "ERecordUpdate" [sexp_expr e; slist (List.map sexp_fassign fs)]
  | _                  -> todo "expr"

and sexp_interp = function
  | InterpStr s  -> node "InterpStr" [esc_str s]
  | InterpExpr e -> node "InterpExpr" [sexp_expr e]

and sexp_garm (guards, body) =
  node "garm" [slist (List.map sexp_guard guards); sexp_expr body]

and sexp_letbind (name, clauses) = node "lgb" (esc_str name :: List.map sexp_clause clauses)

and sexp_clause (pats, body) = node "clause" [slist (List.map sexp_pat pats); sexp_expr body]

and sexp_fassign (n, e) = node "fa" [esc_str n; sexp_expr e]

and sexp_dostmt = function
  | DoExpr e        -> node "DoExpr" [sexp_expr e]
  | DoBind (p, e)   -> node "DoBind" [sexp_pat p; sexp_expr e]
  | DoLet (m, p, e) -> node "DoLet" [string_of_bool m; sexp_pat p; sexp_expr e]
  | DoAssign (x, e) -> node "DoAssign" [esc_str x; sexp_expr e]
  | DoFieldAssign _ -> todo "DoFieldAssign"
  | DoLetElse _     -> todo "DoLetElse"

and sexp_arm (p, guards, body) =
  node "arm" [sexp_pat p; slist (List.map sexp_guard guards); sexp_expr body]

and sexp_guard = function
  | GBool e      -> node "GBool" [sexp_expr e]
  | GBind (p, e) -> node "GBind" [sexp_pat p; sexp_expr e]

and sexp_ty = function
  | TyCon c        -> node "TyCon" [esc_str c]
  | TyVar v        -> node "TyVar" [esc_str v]
  | TyApp (a, b)   -> node "TyApp" [sexp_ty a; sexp_ty b]
  | TyFun (a, b)   -> node "TyFun" [sexp_ty a; sexp_ty b]
  | TyTuple ts     -> node "TyTuple" (List.map sexp_ty ts)
  | TyEffect (labels, tail, t) ->
      let tl = (match tail with Some s -> node "Some" [esc_str s] | None -> "None") in
      node "TyEffect" [slist (List.map esc_str labels); tl; sexp_ty t]
  | TyConstrained (cs, t) ->
      node "TyConstrained" [slist (List.map sexp_constraint cs); sexp_ty t]

and sexp_constraint (iface, args) = node "cstr" (esc_str iface :: List.map sexp_ty args)

let sexp_vis = function
  | DataPrivate  -> "Private"
  | DataAbstract -> "Abstract"
  | DataPublic   -> "Public"

let sexp_field { field_name; field_type } =
  node "field" [esc_str field_name; sexp_ty field_type]

let sexp_payload = function
  | ConPos tys      -> node "ConPos" (List.map sexp_ty tys)
  | ConNamed fields -> node "ConNamed" (List.map sexp_field fields)

let sexp_variant { con_name; con_payload } =
  node "variant" [esc_str con_name; sexp_payload con_payload]

let sexp_member (n, b) = node "mem" [esc_str n; string_of_bool b]

let sexp_use_path = function
  | UseName ids          -> node "UseName" [slist (List.map esc_str ids)]
  | UseGroup (ids, ms)   -> node "UseGroup" [slist (List.map esc_str ids); slist (List.map sexp_member ms)]
  | UseWild ids          -> node "UseWild" [slist (List.map esc_str ids)]
  | UseAlias (ids, a)    -> node "UseAlias" [slist (List.map esc_str ids); esc_str a]

let sexp_decl = function
  | DTypeSig (p, n, t)      -> node "DTypeSig" [string_of_bool p; esc_str n; sexp_ty t]
  | DExtern (p, n, t)       -> node "DExtern" [string_of_bool p; esc_str n; sexp_ty t]
  | DFunDef (p, n, ps, b)   ->
      node "DFunDef" [string_of_bool p; esc_str n; slist (List.map sexp_pat ps); sexp_expr b]
  | DData (vis, n, ps, variants, derives) ->
      node "DData" [sexp_vis vis; esc_str n; slist (List.map esc_str ps);
                    slist (List.map sexp_variant variants); slist (List.map esc_str derives)]
  | DRecord (vis, n, ps, fields, derives) ->
      node "DRecord" [sexp_vis vis; esc_str n; slist (List.map esc_str ps);
                      slist (List.map sexp_field fields); slist (List.map esc_str derives)]
  | DUse (p, path)          -> node "DUse" [string_of_bool p; sexp_use_path path]
  | _                       -> todo "decl"

let () =
  if Array.length Sys.argv < 2 then (prerr_endline "usage: astdump <file>"; exit 2);
  let src = read_file Sys.argv.(1) in
  Lexer.reset ();
  let lb = Lexing.from_string src in
  let prog =
    try Parser.program Lexer.token lb
    with Parser.Error ->
      let p = lb.Lexing.lex_curr_p in
      failwith (Printf.sprintf "parse error %d:%d" p.Lexing.pos_lnum
        (p.Lexing.pos_cnum - p.Lexing.pos_bol))
  in
  let prog = List.map Ast.strip_locs_decl prog in
  print_string (String.concat "\n" (List.map sexp_decl prog))
