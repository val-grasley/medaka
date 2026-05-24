(* Pretty printer for Medaka. Produces parseable source from an AST. *)

open Ast

type t = {
  buf : Buffer.t;
  mutable indent : int;  (* in units of indent step (2 spaces) *)
}

let create () = { buf = Buffer.create 256; indent = 0 }
let contents p = Buffer.contents p.buf
let write p s = Buffer.add_string p.buf s

let newline p =
  Buffer.add_char p.buf '\n';
  for _ = 1 to p.indent do Buffer.add_string p.buf "  " done

let indented p f =
  p.indent <- p.indent + 1;
  newline p;
  f ();
  p.indent <- p.indent - 1

(* ── Literals ────────────────────────────────────── *)

let print_lit p = function
  | LInt n    -> write p (string_of_int n)
  | LFloat f  ->
    let s = Printf.sprintf "%g" f in
    (* Force a decimal point so the lexer reads it as FLOAT, not INT *)
    write p (if String.contains s '.' || String.contains s 'e' then s else s ^ ".0")
  | LString s -> write p (Printf.sprintf "%S" s)
  | LChar c   -> write p (Printf.sprintf "'%s'" c)
  | LBool b   -> write p (if b then "True" else "False")
  | LUnit     -> write p "()"

(* ── Types ───────────────────────────────────────── *)

let rec print_type p t = match t with
  | TyCon n | TyVar n -> write p n
  | TyApp (a, b) ->
    print_type_atom p a;
    write p " ";
    print_type_atom p b
  | TyFun (a, b) ->
    print_type_fun_lhs p a;
    write p " -> ";
    print_type p b
  | TyTuple ts ->
    write p "(";
    List.iteri (fun i ty ->
      if i > 0 then write p ", ";
      print_type p ty
    ) ts;
    write p ")"
  | TyEffect (es, t) ->
    write p "<";
    List.iteri (fun i e ->
      if i > 0 then write p ", ";
      write p e
    ) es;
    write p "> ";
    print_type_atom p t

and print_type_atom p t = match t with
  | TyCon _ | TyVar _ | TyTuple _ -> print_type p t
  | _ -> write p "("; print_type p t; write p ")"

and print_type_fun_lhs p t = match t with
  | TyFun _ -> write p "("; print_type p t; write p ")"
  | _ -> print_type p t

(* ── Patterns ────────────────────────────────────── *)

let rec print_pat p = function
  | PVar x -> write p x
  | PWild  -> write p "_"
  | PLit l -> print_lit p l
  | PCon (c, []) -> write p c
  | PCon (c, pats) ->
    write p "("; write p c;
    List.iter (fun pat -> write p " "; print_pat_atom p pat) pats;
    write p ")"
  | PCons (a, b) ->
    print_pat_atom p a;
    write p "::";
    print_pat p b  (* right-assoc *)
  | PTuple ps ->
    write p "(";
    List.iteri (fun i pat -> if i > 0 then write p ", "; print_pat p pat) ps;
    write p ")"
  | PList ps ->
    write p "[";
    List.iteri (fun i pat -> if i > 0 then write p ", "; print_pat p pat) ps;
    write p "]"

and print_pat_atom p pat = match pat with
  | PVar _ | PWild | PLit _ | PCon (_, []) | PTuple _ | PList _ -> print_pat p pat
  | _ -> write p "("; print_pat p pat; write p ")"

(* ── Expressions ─────────────────────────────────── *)

(* Precedence: higher binds tighter. *)
let prec_top     = 0
let prec_pipe    = 1   (* |>  *)
let prec_compose = 2   (* >>  << *)
let prec_or      = 3
let prec_and     = 4
let prec_cmp     = 5
let prec_cons    = 6
let prec_append  = 7
let prec_add     = 8
let prec_mul     = 9
let prec_infix   = 10
let prec_app     = 11
let prec_unary   = 12
let prec_postfix = 13
let prec_atom    = 14

let binop_prec = function
  | "|>"          -> prec_pipe
  | ">>" | "<<"   -> prec_compose
  | "||"          -> prec_or
  | "&&"          -> prec_and
  | "==" | "!=" | "<" | ">" | "<=" | ">=" -> prec_cmp
  | "::"          -> prec_cons
  | "++"          -> prec_append
  | "+" | "-"     -> prec_add
  | "*" | "/"     -> prec_mul
  | _             -> prec_infix

let is_right_assoc = function "::" -> true | _ -> false

let rec expr_prec = function
  | ELit _ | EVar _ | ETuple _ | EArrayLit _ | EListLit _
  | ERecordCreate _ | ERecordUpdate _ -> prec_atom
  | EFieldAccess _ | EIndex _          -> prec_postfix
  | EUnOp _                            -> prec_unary
  | EApp _                             -> prec_app
  | EInfix _                           -> prec_infix
  | EBinOp (op, _, _)                  -> binop_prec op
  | ELam _ | ELet _ | EIf _
  | EMatch _ | EDo _ | EAnnot _        -> prec_top
  | ELoc (_, e)                        -> expr_prec e

let rec print_expr p min_prec e =
  let ep = expr_prec e in
  let need_parens = ep < min_prec in
  if need_parens then write p "(";
  print_expr_raw p e;
  if need_parens then write p ")"

and print_expr_raw p = function
  | ELit l -> print_lit p l
  | EVar n -> write p n
  | EApp (f, x) ->
    print_expr p prec_app f;
    write p " ";
    print_expr p (prec_app + 1) x
  | ELam (pats, body) ->
    (* Print as curried if multiple pats, though parser only produces one *)
    List.iteri (fun i pat ->
      if i > 0 then write p " => ";
      print_pat_atom p pat
    ) pats;
    write p " => ";
    print_expr p prec_top body
  | ELet (mut, pat, e1, e2) ->
    write p "let ";
    if mut then write p "mut ";
    print_pat p pat;
    write p " = ";
    print_expr p prec_top e1;
    write p " in ";
    print_expr p prec_top e2
  | EIf (c, t, e) ->
    write p "if ";
    print_expr p prec_top c;
    write p " then ";
    print_expr p prec_top t;
    write p " else ";
    print_expr p prec_top e
  | EBinOp (op, l, r) ->
    let prec = binop_prec op in
    let ra = is_right_assoc op in
    print_expr p (if ra then prec + 1 else prec) l;
    write p " "; write p op; write p " ";
    print_expr p (if ra then prec else prec + 1) r
  | EUnOp (op, e) ->
    write p op;
    print_expr p prec_unary e
  | EFieldAccess (e, f) ->
    print_expr p prec_postfix e;
    write p "."; write p f
  | ERecordCreate (n, fs) ->
    write p n; write p " { ";
    List.iteri (fun i (k, v) ->
      if i > 0 then write p ", ";
      write p k; write p " = "; print_expr p prec_top v
    ) fs;
    write p " }"
  | ERecordUpdate (e, fs) ->
    write p "{ ";
    print_expr p prec_top e;
    write p " | ";
    List.iteri (fun i (k, v) ->
      if i > 0 then write p ", ";
      write p k; write p " = "; print_expr p prec_top v
    ) fs;
    write p " }"
  | EArrayLit es ->
    write p "[|";
    List.iteri (fun i e -> if i > 0 then write p ", "; print_expr p prec_top e) es;
    write p "|]"
  | EListLit es ->
    write p "[";
    List.iteri (fun i e -> if i > 0 then write p ", "; print_expr p prec_top e) es;
    write p "]"
  | ETuple es ->
    write p "(";
    List.iteri (fun i e -> if i > 0 then write p ", "; print_expr p prec_top e) es;
    write p ")"
  | EIndex (e, i) ->
    print_expr p prec_postfix e;
    write p "[";
    print_expr p prec_top i;
    write p "]"
  | EMatch (sc, arms) ->
    write p "match ";
    print_expr p prec_top sc;
    indented p (fun () ->
      List.iteri (fun i (pat, guard, body) ->
        if i > 0 then newline p;
        print_pat p pat;
        (match guard with
         | None -> ()
         | Some g -> write p " if "; print_expr p prec_top g);
        write p " => ";
        print_expr_body p body
      ) arms
    )
  | EDo stmts ->
    write p "do";
    indented p (fun () ->
      List.iteri (fun i s ->
        if i > 0 then newline p;
        print_do_stmt p s
      ) stmts
    )
  | EAnnot (e, t) ->
    print_expr p prec_top e;
    write p " : ";
    print_type p t
  | EInfix (op, l, r) ->
    print_expr p (prec_infix + 1) l;
    write p " `"; write p op; write p "` ";
    print_expr p (prec_infix + 1) r
  | ELoc (_, e) -> print_expr_raw p e

(* Body position: a Match/Do can use its natural multi-line layout
   without surrounding parens. *)
and print_expr_body p e = match e with
  | EMatch _ | EDo _ -> print_expr_raw p e
  | ELoc (_, e')     -> print_expr_body p e'
  | _ -> print_expr p prec_top e

and print_do_stmt p = function
  | DoBind (pat, e) ->
    print_pat p pat;
    write p " <- ";
    print_expr p prec_top e
  | DoExpr e -> print_expr_body p e
  | DoLet (mut, pat, e) ->
    write p "let ";
    if mut then write p "mut ";
    print_pat p pat;
    write p " = ";
    print_expr p prec_top e
  | DoAssign (x, e) ->
    write p x;
    write p " = ";
    print_expr p prec_top e

(* ── Declarations ────────────────────────────────── *)

let rec is_block_body = function
  | EMatch _ | EDo _ -> true
  | ELoc (_, e)      -> is_block_body e
  | _ -> false

let print_use_path p = function
  | UseName names ->
    write p (String.concat "." names)
  | UseGroup (names, members) ->
    write p (String.concat "." names);
    write p ".{";
    List.iteri (fun i m -> if i > 0 then write p ", "; write p m) members;
    write p "}"
  | UseWild names ->
    write p (String.concat "." names);
    write p ".*"
  | UseAlias (names, alias) ->
    write p (String.concat "." names);
    write p " as "; write p alias

let print_decl p = function
  | DTypeSig (n, t) ->
    write p n; write p " : "; print_type p t

  | DFunDef (n, pats, body) ->
    write p n;
    List.iter (fun pat -> write p " "; print_pat_atom p pat) pats;
    write p " =";
    if is_block_body body then
      indented p (fun () -> print_expr_body p body)
    else begin
      write p " ";
      print_expr p prec_top body
    end

  | DData (n, params, variants) ->
    write p "data "; write p n;
    List.iter (fun pa -> write p " "; write p pa) params;
    indented p (fun () ->
      List.iteri (fun i v ->
        if i > 0 then newline p;
        write p "| "; write p v.con_name;
        List.iter (fun t -> write p " "; print_type_atom p t) v.con_fields
      ) variants
    )

  | DRecord (n, params, fields) ->
    write p "record "; write p n;
    List.iter (fun pa -> write p " "; write p pa) params;
    indented p (fun () ->
      List.iteri (fun i f ->
        if i > 0 then newline p;
        write p f.field_name;
        write p " : ";
        print_type p f.field_type
      ) fields
    )

  | DInterface { is_default; iface_name; type_params; super; methods } ->
    if is_default then write p "default ";
    write p "interface "; write p iface_name;
    List.iter (fun pa -> write p " "; write p pa) type_params;
    if super <> [] then begin
      write p " of ";
      List.iteri (fun i (n, ps) ->
        if i > 0 then write p ", ";
        write p n;
        List.iter (fun pa -> write p " "; write p pa) ps
      ) super
    end;
    write p " where";
    indented p (fun () ->
      List.iteri (fun i m ->
        if i > 0 then newline p;
        write p m.method_name;
        match m.method_default with
        | None ->
          write p " : ";
          print_type p m.method_type
        | Some (pats, body) ->
          List.iter (fun pat -> write p " "; print_pat_atom p pat) pats;
          write p " = ";
          print_expr p prec_top body
      ) methods
    )

  | DImpl { is_default; iface_name; type_args; impl_name; methods } ->
    if is_default then write p "default ";
    write p "impl ";
    (match impl_name with
     | None ->
       write p iface_name;
       List.iter (fun t -> write p " "; print_type_atom p t) type_args
     | Some name ->
       write p name; write p " of "; write p iface_name;
       List.iter (fun t -> write p " "; print_type_atom p t) type_args);
    write p " where";
    indented p (fun () ->
      List.iteri (fun i (n, pats, body) ->
        if i > 0 then newline p;
        write p n;
        List.iter (fun pat -> write p " "; print_pat_atom p pat) pats;
        write p " = ";
        print_expr p prec_top body
      ) methods
    )

  | DUse (pub, path) ->
    if pub then write p "pub ";
    write p "use ";
    print_use_path p path

let print_program p decls =
  List.iter (fun d ->
    print_decl p d;
    write p "\n"
  ) decls

(* ── Public entry points ─────────────────────────── *)

let program_to_string decls =
  let p = create () in
  print_program p decls;
  contents p

let expr_to_string e =
  let p = create () in
  print_expr p prec_top e;
  contents p
