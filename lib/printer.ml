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
  | TyConstrained (cs, t) ->
    let pp_c (iface, args) =
      write p iface;
      List.iter (fun a -> write p " "; print_type_atom p a) args
    in
    (match cs with
     | [c] -> pp_c c
     | _ ->
       write p "(";
       List.iteri (fun i c -> if i > 0 then write p ", "; pp_c c) cs;
       write p ")");
    write p " => ";
    print_type p t

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
  | PAs (x, inner) ->
    write p x; write p "@"; print_pat_atom p inner
  | PRec (name, fields, rest) ->
    write p name; write p " { ";
    List.iteri (fun i (k, pat_opt) ->
      if i > 0 then write p ", ";
      match pat_opt with
      | None   -> write p k
      | Some q -> write p k; write p " = "; print_pat p q
    ) fields;
    if rest then begin
      if fields <> [] then write p ", ";
      write p "..."
    end;
    write p " }"
  | PRng (lo, hi, incl) ->
    print_lit p lo;
    write p (if incl then "..=" else "..");
    print_lit p hi

and print_pat_atom p pat = match pat with
  | PVar _ | PWild | PLit _ | PCon (_, []) | PTuple _ | PList _ | PRec _ | PRng _ ->
    print_pat p pat
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
  | "++" | "<>"   -> prec_append
  | "+" | "-"     -> prec_add
  | "*" | "/"     -> prec_mul
  | _             -> prec_infix

let is_right_assoc = function "::" -> true | _ -> false

let rec expr_prec = function
  | ELit _ | EVar _ | EMethodRef _ | ETuple _ | EArrayLit _ | EListLit _ | EListComp _
  | EMapLit _ | ESetLit _ | EStringInterp _
  | ERecordCreate _ | ERecordUpdate _
  | ERangeList _ | ERangeArray _ | ESlice _ -> prec_atom
  | EFieldAccess _ | EIndex _
  | EQuestion _                        -> prec_postfix
  | EUnOp _                            -> prec_unary
  | EApp _                             -> prec_app
  | EInfix _                           -> prec_infix
  | EBinOp (op, _, _)                  -> binop_prec op
  | ELam _ | ELet _ | ELetGroup _ | EIf _
  | EMatch _ | EBlock _ | EDo (_, _) | EAnnot _   -> prec_top
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
  | EMethodRef (_, n) -> write p n
  | EApp (f, x) ->
    print_expr p prec_app f;
    write p " ";
    print_expr p (prec_app + 1) x
  | ELam (pats, body) ->
    List.iteri (fun i pat ->
      if i > 0 then write p " ";
      print_pat_atom p pat
    ) pats;
    write p " => ";
    print_expr p prec_top body
  | ELet (mut, true, PVar f, rhs, e2) ->
    let rec unwrap_lams acc = function
      | ELam (pats, body) -> unwrap_lams (acc @ pats) body
      | ELoc (_, e)       -> unwrap_lams acc e
      | body              -> (acc, body)
    in
    let (args, body) = unwrap_lams [] rhs in
    write p (if mut then "let mut " else "let ");
    write p f;
    List.iter (fun pat -> write p " "; print_pat p pat) args;
    write p " = ";
    print_expr p prec_top body;
    write p " in ";
    print_expr p prec_top e2
  | ELet (mut, _, pat, e1, e2) ->
    write p "let ";
    if mut then write p "mut ";
    print_pat p pat;
    write p " = ";
    print_expr p prec_top e1;
    write p " in ";
    print_expr p prec_top e2
  | ELetGroup (bindings, body) ->
    print_expr p prec_top body;
    write p " where";
    List.iter (fun (name, clauses) ->
      List.iter (fun (pats, rhs) ->
        write p "\n    "; write p name;
        List.iter (fun pat ->
          write p " "; print_pat p pat
        ) pats;
        write p " = ";
        print_expr p prec_top rhs
      ) clauses
    ) bindings
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
  | EQuestion e ->
    print_expr p prec_postfix e;
    write p " ?"
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
  | EMapLit (n, kvs) ->
    write p n; write p " { ";
    List.iteri (fun i (k, v) ->
      if i > 0 then write p ", ";
      print_expr p prec_top k; write p " => "; print_expr p prec_top v
    ) kvs;
    write p " }"
  | ESetLit (n, es) ->
    write p n; write p " { ";
    List.iteri (fun i e -> if i > 0 then write p ", "; print_expr p prec_top e) es;
    write p " }"
  | ETuple es ->
    write p "(";
    List.iteri (fun i e -> if i > 0 then write p ", "; print_expr p prec_top e) es;
    write p ")"
  | EIndex (e, i) ->
    print_expr p prec_postfix e;
    write p ".[";
    print_expr p prec_top i;
    write p "]"
  | EMatch (sc, arms) ->
    write p "match ";
    print_expr p prec_top sc;
    indented p (fun () ->
      List.iteri (fun i (pat, guards, body) ->
        if i > 0 then newline p;
        print_pat p pat;
        (match guards with
         | [] -> ()
         | _ ->
           write p " if ";
           List.iteri (fun j q ->
             if j > 0 then write p ", ";
             match q with
             | GBool g      -> print_expr p prec_top g
             | GBind (gp, g) ->
               print_pat p gp; write p " <- "; print_expr p prec_top g
           ) guards);
        write p " => ";
        print_expr_body p body
      ) arms
    )
  | EBlock stmts ->
    (* Bare block: no `do` prefix, just an indented stmt list. *)
    indented p (fun () ->
      List.iteri (fun i s ->
        if i > 0 then newline p;
        print_do_stmt p s
      ) stmts
    )
  | EDo (_, stmts) ->
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
  | EStringInterp parts ->
    write p "\"";
    List.iter (function
      | InterpStr s  -> write p (String.escaped s)
      | InterpExpr e -> write p "\\{"; print_expr p prec_top e; write p "}"
    ) parts;
    write p "\""
  | EListComp (body, quals) ->
    write p "[";
    print_expr p prec_top body;
    write p " | ";
    List.iteri (fun i qual ->
      if i > 0 then write p ", ";
      match qual with
      | LCGen (pat, xs) ->
        print_pat p pat; write p " <- "; print_expr p prec_top xs
      | LCGuard cond ->
        print_expr p prec_top cond
      | LCLet (mut, pat, e) ->
        write p "let "; if mut then write p "mut ";
        print_pat p pat; write p " = "; print_expr p prec_top e
    ) quals;
    write p "]"
  | ERangeList (lo, hi, incl) ->
    write p "[";
    print_expr p prec_top lo;
    write p (if incl then "..=" else "..");
    print_expr p prec_top hi;
    write p "]"
  | ERangeArray (lo, hi, incl) ->
    write p "[|";
    print_expr p prec_top lo;
    write p (if incl then "..=" else "..");
    print_expr p prec_top hi;
    write p "|]"
  | ESlice (e, lo, hi, incl) ->
    print_expr p prec_postfix e;
    write p ".[";
    print_expr p prec_top lo;
    write p (if incl then "..=" else "..");
    print_expr p prec_top hi;
    write p "]"
  | ELoc (_, e) -> print_expr_raw p e

(* Body position: a Match/Do can use its natural multi-line layout
   without surrounding parens. *)
and print_expr_body p e = match e with
  | EMatch _ | EBlock _ | EDo _ -> print_expr_raw p e
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
  | DoFieldAssign (x, field, e) ->
    write p x;
    write p ".";
    write p field;
    write p " = ";
    print_expr p prec_top e
  | DoLetElse (pat, e, alt) ->
    write p "let ";
    print_pat p pat;
    write p " = ";
    print_expr p prec_top e;
    write p " else ";
    print_expr p prec_top alt

(* ── Declarations ────────────────────────────────── *)

let rec is_block_body = function
  | EMatch _ | EBlock _ | EDo _ -> true
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

let rec print_decl p = function
  | DTypeSig (pub, n, t) ->
    if pub then write p "export ";
    write p n; write p " : "; print_type p t

  | DExtern (pub, n, t) ->
    if pub then write p "export ";
    write p "extern "; write p n; write p " : "; print_type p t

  | DFunDef (pub, n, pats, body) ->
    if pub then write p "export ";
    write p n;
    List.iter (fun pat -> write p " "; print_pat_atom p pat) pats;
    write p " =";
    if is_block_body body then
      indented p (fun () -> print_expr_body p body)
    else begin
      write p " ";
      print_expr p prec_top body
    end

  | DLetGroup (pub, bindings) ->
    if pub then write p "export ";
    let first = ref true in
    List.iter (fun (name, clauses) ->
      List.iter (fun (pats, body) ->
        if !first then begin write p "let rec "; first := false end
        else begin newline p; write p "with " end;
        write p name;
        List.iter (fun pat -> write p " "; print_pat_atom p pat) pats;
        write p " =";
        if is_block_body body then
          indented p (fun () -> print_expr_body p body)
        else begin
          write p " ";
          print_expr p prec_top body
        end
      ) clauses
    ) bindings

  | DData (vis, n, params, variants, derives) ->
    (match vis with
     | Ast.DataPublic   -> write p "public export "
     | Ast.DataAbstract -> write p "export "
     | Ast.DataPrivate  -> ());
    write p "data "; write p n;
    List.iter (fun pa -> write p " "; write p pa) params;
    indented p (fun () ->
      List.iteri (fun i v ->
        if i > 0 then newline p;
        write p "| "; write p v.con_name;
        (match v.con_payload with
         | Ast.ConPos tys ->
           List.iter (fun t -> write p " "; print_type_atom p t) tys
         | Ast.ConNamed fields ->
           write p " { ";
           List.iteri (fun i f ->
             if i > 0 then write p ", ";
             write p f.Ast.field_name; write p " : ";
             print_type p f.Ast.field_type
           ) fields;
           write p " }")
      ) variants
    );
    if derives <> [] then begin
      newline p;
      write p "deriving (";
      write p (String.concat ", " derives);
      write p ")"
    end

  | DRecord (vis, n, params, fields, derives) ->
    (match vis with
     | Ast.DataPublic   -> write p "public export "
     | Ast.DataAbstract -> write p "export "
     | Ast.DataPrivate  -> ());
    write p "record "; write p n;
    List.iter (fun pa -> write p " "; write p pa) params;
    indented p (fun () ->
      List.iteri (fun i f ->
        if i > 0 then newline p;
        write p f.field_name;
        write p " : ";
        print_type p f.field_type
      ) fields
    );
    if derives <> [] then begin
      newline p;
      write p "deriving (";
      write p (String.concat ", " derives);
      write p ")"
    end

  | DTypeAlias (pub, n, params, rhs) ->
    if pub then write p "export ";
    write p "type "; write p n;
    List.iter (fun pa -> write p " "; write p pa) params;
    write p " = ";
    print_type p rhs

  | DNewtype (pub, n, params, con, fty, derives) ->
    if pub then write p "export ";
    write p "newtype "; write p n;
    List.iter (fun pa -> write p " "; write p pa) params;
    write p " = "; write p con; write p " ";
    print_type_atom p fty;
    if derives <> [] then begin
      write p " deriving (";
      write p (String.concat ", " derives);
      write p ")"
    end

  | DInterface { is_pub; is_default; iface_name; type_params; super; methods } ->
    if is_pub then write p "export ";
    if is_default then write p "default ";
    write p "interface "; write p iface_name;
    List.iter (fun pa -> write p " "; write p pa) type_params;
    if super <> [] then begin
      write p " requires ";
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

  | DImpl { is_pub; is_default; iface_name; type_args; impl_name; requires; methods } ->
    if is_pub then write p "export ";
    if is_default then write p "default ";
    write p "impl ";
    (match impl_name with
     | None ->
       write p iface_name;
       List.iter (fun t -> write p " "; print_type_atom p t) type_args
     | Some name ->
       write p name; write p " of "; write p iface_name;
       List.iter (fun t -> write p " "; print_type_atom p t) type_args);
    (match requires with
     | [] -> ()
     | cs ->
       write p " requires ";
       let pp_entry i (iface, args) =
         if i > 0 then write p ", ";
         write p iface;
         List.iter (fun t -> write p " "; print_type_atom p t) args
       in
       List.iteri pp_entry cs);
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
    if pub then write p "export ";
    write p "import ";
    print_use_path p path

  | DProp { is_pub; prop_name; prop_params; prop_body } ->
    if is_pub then write p "export\n";
    write p "prop ";
    write p (Printf.sprintf "%S" prop_name);
    List.iter (fun (x, ty) ->
      write p (Printf.sprintf " (%s : %s)" x (Ast.pp_ty ty))
    ) prop_params;
    write p " = ";
    print_expr p prec_top prop_body
  | DBench { is_pub; bench_name; bench_body } ->
    if is_pub then write p "export\n";
    write p "bench ";
    write p (Printf.sprintf "%S" bench_name);
    write p " = ";
    print_expr p prec_top bench_body

  | DAttrib (attrs, inner) ->
    List.iter (fun a ->
      (match a with
       | AttrDeprecated msg -> write p (Printf.sprintf "@deprecated %S" msg)
       | AttrInline         -> write p "@inline"
       | AttrMustUse        -> write p "@must_use");
      write p "\n"
    ) attrs;
    print_decl p inner

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

(* ── Comment-preserving formatter ────────────────── *)

(* Format a program, interleaving captured line comments at their original
   source positions.  `decl_locs` is parallel to `decls` (one location per
   top-level declaration, in source order — produced by the parser's
   side-channel; see lib/parser_state.ml).  `comments` is the lexer's
   captured comment list, also in source order.

   If `decl_locs` is empty but `decls` is not, falls back to the plain
   [program_to_string] (no position info available). *)
let format_program decls decl_locs (comments : Lexer.comment list) =
  if List.length decl_locs <> List.length decls then
    program_to_string decls
  else begin
    let p = create () in
    let cs = ref comments in
    let cursor = ref 0 in       (* last consumed source line *)
    let started = ref false in
    let blank_line_if_needed target_line =
      if !started && target_line - !cursor >= 2 then
        Buffer.add_char p.buf '\n'
    in
    let emit_comment (c : Lexer.comment) =
      blank_line_if_needed c.c_line;
      write p c.c_text;
      Buffer.add_char p.buf '\n';
      let nls = String.fold_left (fun n ch -> if ch = '\n' then n + 1 else n) 0 c.c_text in
      cursor := c.c_line + nls;
      started := true
    in
    let flush_before line =
      let rec loop () =
        match !cs with
        | c :: rest when c.c_line < line ->
          cs := rest; emit_comment c; loop ()
        | _ -> ()
      in
      loop ()
    in
    List.iter2 (fun decl (loc : Ast.loc) ->
      flush_before loc.line;
      blank_line_if_needed loc.line;
      print_decl p decl;
      Buffer.add_char p.buf '\n';
      cursor := loc.end_line;
      started := true
    ) decls decl_locs;
    flush_before max_int;
    contents p
  end
