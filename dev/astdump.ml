(* dev/astdump.ml — dump a canonical, location-stripped S-expression of the
   parsed AST for a file: the structural reference the self-hosted parser is
   validated against (the Phase-131 token_to_string analog for the AST).
   Usage: astdump <file.mdk>

   Format: one top-level decl per line, each a single S-expression.  Tags are the
   OCaml constructor names so this and selfhost/sexp.mdk stay in lockstep.
   Strings use a fixed minimal escaping (backslash, quote, n, t, r) -- NOT OCaml
   %S -- so the two hosts agree.  Floats are rendered loosely and normalized away
   by the diff script (host %g vs floatToString), same as the lexer FLOAT.

   All Expr constructors are now explicitly matched (exhaustive). *)

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

let rec sexp_pat = function
  | PVar x        -> node "PVar" [esc_str x]
  | PWild         -> "PWild"
  | PLit l        -> node "PLit" [sexp_lit l]
  | PCon (c, ps)  -> node "PCon" (esc_str c :: List.map sexp_pat ps)
  | PCons (a, b)  -> node "PCons" [sexp_pat a; sexp_pat b]
  | PTuple ps     -> node "PTuple" (List.map sexp_pat ps)
  | PList ps      -> node "PList" (List.map sexp_pat ps)
  | PAs (x, p)    -> node "PAs" [esc_str x; sexp_pat p]
  | PRec (name, fields, rest) ->
      node "PRec" [esc_str name; slist (List.map sexp_recpatfield fields); string_of_bool rest]
  | PRng (lo, hi, incl) -> node "PRng" [sexp_lit lo; sexp_lit hi; string_of_bool incl]

and sexp_recpatfield (f, popt) =
  node "rf" [esc_str f; (match popt with Some p -> sexp_pat p | None -> "None")]

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
  | EListComp (body, quals) -> node "EListComp" [sexp_expr body; slist (List.map sexp_lc_qual quals)]
  | EArrayLit es       -> node "EArrayLit" (List.map sexp_expr es)
  | ERangeList (lo, hi, incl) -> node "ERangeList" [sexp_expr lo; sexp_expr hi; string_of_bool incl]
  | ELetGroup (binds, body) -> node "ELetGroup" [slist (List.map sexp_letbind binds); sexp_expr body]
  | ESection (SecBare op)      -> node "ESection" [node "SecBare" [esc_str op]]
  | ESection (SecRight (op, e))-> node "ESection" [node "SecRight" [esc_str op; sexp_expr e]]
  | ESection (SecLeft (e, op)) -> node "ESection" [node "SecLeft" [sexp_expr e; esc_str op]]
  | EIndex (a, i)      -> node "EIndex" [sexp_expr a; sexp_expr i]
  | EQuestion e        -> node "EQuestion" [sexp_expr e]
  | ERangeArray (lo, hi, incl) -> node "ERangeArray" [sexp_expr lo; sexp_expr hi; string_of_bool incl]
  | ESlice (e, lo, hi, incl)   -> node "ESlice" [sexp_expr e; sexp_expr lo; sexp_expr hi; string_of_bool incl]
  | EFunction arms     -> node "EFunction" (List.map sexp_arm arms)
  (* Method_marker output (refs unfilled until typecheck): the discriminating
     content is just the marked name + which marker it is. *)
  | EMethodRef (_, x)  -> node "EMethodRef" [esc_str x]
  | EDictApp (_, x)    -> node "EDictApp" [esc_str x]
  | EHeadAnnot (e, t)  -> node "EHeadAnnot" [sexp_expr e; sexp_ty t]
  | EAnnot (e, t)      -> node "EAnnot" [sexp_expr e; sexp_ty t]
  | EBlock stmts       -> node "EBlock" (List.map sexp_dostmt stmts)
  | EDo (_, stmts)     -> node "EDo" (List.map sexp_dostmt stmts)
  | EStringInterp parts -> node "EStringInterp" (List.map sexp_interp parts)
  | EGuards arms       -> node "EGuards" (List.map sexp_garm arms)
  | ERecordCreate (n, fs) -> node "ERecordCreate" [esc_str n; slist (List.map sexp_fassign fs)]
  | ERecordUpdate (e, fs) -> node "ERecordUpdate" [sexp_expr e; slist (List.map sexp_fassign fs)]
  | EVariantUpdate (c, e, fs) -> node "EVariantUpdate" [esc_str c; sexp_expr e; slist (List.map sexp_fassign fs)]
  | EMapLit (n, kvs)   -> node "EMapLit" [esc_str n; slist (List.map (fun (k, v) -> node "kv" [sexp_expr k; sexp_expr v]) kvs)]
  | ESetLit (n, es)    -> node "ESetLit" [esc_str n; slist (List.map sexp_expr es)]
  | EAsPat (x, e)      -> node "EAsPat" [esc_str x; sexp_expr e]

and sexp_interp = function
  | InterpStr s  -> node "InterpStr" [esc_str s]
  | InterpExpr e -> node "InterpExpr" [sexp_expr e]

and sexp_garm (guards, body) =
  node "garm" [slist (List.map sexp_guard guards); sexp_expr body]

and sexp_lc_qual = function
  | LCGen (p, e)    -> node "LCGen" [sexp_pat p; sexp_expr e]
  | LCGuard e       -> node "LCGuard" [sexp_expr e]
  | LCLet (m, p, e) -> node "LCLet" [string_of_bool m; sexp_pat p; sexp_expr e]

and sexp_letbind (name, clauses) = node "lgb" (esc_str name :: List.map sexp_clause clauses)

and sexp_clause (pats, body) = node "clause" [slist (List.map sexp_pat pats); sexp_expr body]

and sexp_fassign (n, e) = node "fa" [esc_str n; sexp_expr e]

and sexp_dostmt = function
  | DoExpr e        -> node "DoExpr" [sexp_expr e]
  | DoBind (p, e)   -> node "DoBind" [sexp_pat p; sexp_expr e]
  | DoLet (m, r, p, e) -> node "DoLet" [string_of_bool m; string_of_bool r; sexp_pat p; sexp_expr e]
  | DoAssign (x, e) -> node "DoAssign" [esc_str x; sexp_expr e]
  | DoFieldAssign (x, fs, e) -> node "DoFieldAssign" [esc_str x; slist (List.map esc_str fs); sexp_expr e]
  | DoLetElse (p, e, alt)    -> node "DoLetElse" [sexp_pat p; sexp_expr e; sexp_expr alt]

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

let sexp_opt_str = function Some s -> node "Some" [esc_str s] | None -> "None"

let sexp_method_default = function
  | Some (pats, body) -> node "mdef" [slist (List.map sexp_pat pats); sexp_expr body]
  | None              -> "None"

let sexp_iface_method { method_name; method_type; method_default } =
  node "imethod" [esc_str method_name; sexp_ty method_type; sexp_method_default method_default]

let sexp_super (iface, params) = node "super" [esc_str iface; slist (List.map esc_str params)]
let sexp_require (iface, tys) = node "req" [esc_str iface; slist (List.map sexp_ty tys)]
let sexp_impl_method (name, pats, body) =
  node "im" [esc_str name; slist (List.map sexp_pat pats); sexp_expr body]

let sexp_attr = function
  | AttrDeprecated s -> node "AttrDeprecated" [esc_str s]
  | AttrInline       -> "AttrInline"
  | AttrMustUse      -> "AttrMustUse"

let rec sexp_decl = function
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
  | DEffect (p, n)          -> node "DEffect" [string_of_bool p; esc_str n]
  | DTypeAlias (p, n, ps, t) ->
      node "DTypeAlias" [string_of_bool p; esc_str n; slist (List.map esc_str ps); sexp_ty t]
  | DNewtype (p, n, ps, con, fty, derives) ->
      node "DNewtype" [string_of_bool p; esc_str n; slist (List.map esc_str ps);
                       esc_str con; sexp_ty fty; slist (List.map esc_str derives)]
  | DLetGroup (p, binds) ->
      node "DLetGroup" [string_of_bool p; slist (List.map sexp_letbind binds)]
  | DAttrib (attrs, d) ->
      node "DAttrib" [slist (List.map sexp_attr attrs); sexp_decl d]
  | DProp { is_pub; prop_name; prop_params; prop_body } ->
      node "DProp" [string_of_bool is_pub; esc_str prop_name;
                    slist (List.map (fun (n, t) -> node "pp" [esc_str n; sexp_ty t]) prop_params);
                    sexp_expr prop_body]
  | DTest { is_pub; test_name; test_body } ->
      node "DTest" [string_of_bool is_pub; esc_str test_name; sexp_expr test_body]
  | DBench { is_pub; bench_name; bench_body } ->
      node "DBench" [string_of_bool is_pub; esc_str bench_name; sexp_expr bench_body]
  | DInterface { is_pub; is_default; iface_name; type_params; super; methods } ->
      node "DInterface" [string_of_bool is_pub; string_of_bool is_default; esc_str iface_name;
        slist (List.map esc_str type_params); slist (List.map sexp_super super);
        slist (List.map sexp_iface_method methods)]
  | DImpl { is_pub; is_default; iface_name; type_args; impl_name; requires; methods; _ } ->
      node "DImpl" [string_of_bool is_pub; string_of_bool is_default; esc_str iface_name;
        slist (List.map sexp_ty type_args); sexp_opt_str impl_name;
        slist (List.map sexp_require requires); slist (List.map sexp_impl_method methods)]

(* Stage selector: dump the AST at a chosen pipeline point so the self-hosted
   stage can be diffed against the reference (parse-only by default; --desugar
   after Desugar; --mark after Desugar+Method_marker). *)
type stage = Parse | Desugar | Mark

let () =
  let stage = ref Parse and file = ref None in
  Array.iteri (fun i a ->
    if i = 0 then ()
    else match a with
      | "--desugar" -> stage := Desugar
      | "--mark"    -> stage := Mark
      | "--parse"   -> stage := Parse
      | _           -> file := Some a) Sys.argv;
  let path = match !file with
    | Some p -> p
    | None -> prerr_endline "usage: astdump [--parse|--desugar|--mark] <file>"; exit 2 in
  let src = read_file path in
  Lexer.reset ();
  let lb = Lexing.from_string src in
  let prog =
    try Parser.program Lexer.token lb
    with Parser.Error ->
      let p = lb.Lexing.lex_curr_p in
      failwith (Printf.sprintf "parse error %d:%d" p.Lexing.pos_lnum
        (p.Lexing.pos_cnum - p.Lexing.pos_bol))
  in
  let prog = match !stage with
    | Parse   -> prog
    | Desugar -> Desugar.desugar_program prog
    | Mark    -> Method_marker.mark_with_prelude (Desugar.desugar_program prog)
  in
  let prog = List.map Ast.strip_locs_decl prog in
  print_string (String.concat "\n" (List.map sexp_decl prog))
