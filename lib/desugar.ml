open Ast

(* Left-fold string concatenations: e0 ++ e1 ++ ... *)
let concat_strings parts =
  match parts with
  | [] -> ELit (LString "")
  | [x] -> x
  | first :: rest ->
    List.fold_left (fun acc e -> EBinOp ("++", acc, e)) first rest

(* Left-fold &&: e0 && e1 && ... *)
let and_all = function
  | [] -> EVar "True"
  | first :: rest ->
    List.fold_left (fun acc e -> EBinOp ("&&", acc, e)) first rest

(* Apply compare to two expressions; wrap same-constructor fields
   in a lexicographic cascade:
     match compare e0a e0b of Eq => (match compare e1a e1b of ...) | c => c *)
let rec lex_compare_exprs = function
  | [] -> EVar "Eq"
  | [(ea, eb)] -> EApp (EApp (EVar "compare", ea), eb)
  | (ea, eb) :: rest ->
    EMatch (
      EApp (EApp (EVar "compare", ea), eb),
      [ (PCon ("Eq", []), None, lex_compare_exprs rest)
      ; (PVar "__c",      None, EVar "__c")
      ]
    )

(* ------------------------------------------------------------------ *)
(* Derive Eq                                                           *)
(* ------------------------------------------------------------------ *)

let derive_eq_data type_name variants =
  (* One arm per constructor: same-constructor case compares fields pairwise.
     Final wildcard arm returns False for any cross-constructor pair. *)
  let same_con_arms = List.map (fun v ->
    let n = List.length v.con_fields in
    let avars = List.init n (fun i -> Printf.sprintf "__a%d" i) in
    let bvars = List.init n (fun i -> Printf.sprintf "__b%d" i) in
    let apat = PCon (v.con_name, List.map (fun x -> PVar x) avars) in
    let bpat = PCon (v.con_name, List.map (fun x -> PVar x) bvars) in
    let body =
      if n = 0 then EVar "True"
      else
        and_all (List.map2 (fun a b ->
          EApp (EApp (EVar "eq", EVar a), EVar b)
        ) avars bvars)
    in
    (PTuple [apat; bpat], None, body)
  ) variants in
  let wild_arm = (PTuple [PWild; PWild], None, EVar "False") in
  let body = EMatch (ETuple [EVar "__x"; EVar "__y"], same_con_arms @ [wild_arm]) in
  DImpl {
    is_pub     = true;
    is_default = false;
    iface_name = "Eq";
    type_args  = [TyCon type_name];
    impl_name  = None;
    requires   = [];
    methods    = [("eq", [PVar "__x"; PVar "__y"], body)];
  }

let derive_eq_record type_name fields =
  let body =
    if fields = [] then EVar "True"
    else
      and_all (List.map (fun f ->
        EApp (EApp (EVar "eq",
          EFieldAccess (EVar "__a", f.field_name)),
          EFieldAccess (EVar "__b", f.field_name))
      ) fields)
  in
  DImpl {
    is_pub     = true;
    is_default = false;
    iface_name = "Eq";
    type_args  = [TyCon type_name];
    impl_name  = None;
    requires   = [];
    methods    = [("eq", [PVar "__a"; PVar "__b"], body)];
  }

(* ------------------------------------------------------------------ *)
(* Derive Show                                                         *)
(* ------------------------------------------------------------------ *)

let derive_show_data type_name variants =
  let arms = List.map (fun v ->
    let n = List.length v.con_fields in
    let vars = List.init n (fun i -> Printf.sprintf "__a%d" i) in
    let pat =
      if n = 0 then PCon (v.con_name, [])
      else PCon (v.con_name, List.map (fun x -> PVar x) vars)
    in
    let body =
      if n = 0 then ELit (LString v.con_name)
      else
        (* "ConName " ++ show a0 ++ " " ++ show a1 ++ ... *)
        let parts =
          ELit (LString (v.con_name ^ " ")) ::
          (List.concat_map (fun (i, var) ->
            if i = 0 then [EApp (EVar "show", EVar var)]
            else [ELit (LString " "); EApp (EVar "show", EVar var)]
          ) (List.mapi (fun i v -> (i, v)) vars))
        in
        concat_strings parts
    in
    (pat, None, body)
  ) variants in
  let body = EMatch (EVar "__x", arms) in
  DImpl {
    is_pub     = true;
    is_default = false;
    iface_name = "Show";
    type_args  = [TyCon type_name];
    impl_name  = None;
    requires   = [];
    methods    = [("show", [PVar "__x"], body)];
  }

let derive_show_record type_name fields =
  let parts =
    [ELit (LString (type_name ^ " {"))]
    @ (List.concat_map (fun (i, f) ->
        let prefix = if i = 0 then " " else ", " in
        [ ELit (LString (prefix ^ f.field_name ^ " = "))
        ; EApp (EVar "show", EFieldAccess (EVar "__r", f.field_name))
        ]
      ) (List.mapi (fun i f -> (i, f)) fields))
    @ [ELit (LString " }")]
  in
  let body = concat_strings parts in
  DImpl {
    is_pub     = true;
    is_default = false;
    iface_name = "Show";
    type_args  = [TyCon type_name];
    impl_name  = None;
    requires   = [];
    methods    = [("show", [PVar "__r"], body)];
  }

(* ------------------------------------------------------------------ *)
(* Derive Ord                                                          *)
(* ------------------------------------------------------------------ *)

let derive_ord_data type_name variants =
  (* Generate one arm for every (i, vi) × (j, vj) constructor pair.
     Different constructors compare by their declaration order.
     Same constructor compares fields lexicographically. *)
  let indexed = List.mapi (fun i v -> (i, v)) variants in
  let arms = List.concat_map (fun (i, vi) ->
    List.map (fun (j, vj) ->
      let ni = List.length vi.con_fields in
      let nj = List.length vj.con_fields in
      let avars = List.init ni (fun k -> Printf.sprintf "__a%d" k) in
      let bvars = List.init nj (fun k -> Printf.sprintf "__b%d" k) in
      let apat = PCon (vi.con_name, List.map (fun x -> PVar x) avars) in
      let bpat = PCon (vj.con_name, List.map (fun x -> PVar x) bvars) in
      let body =
        if i < j then EVar "Lt"
        else if i > j then EVar "Gt"
        else lex_compare_exprs (List.map2 (fun a b -> (EVar a, EVar b)) avars bvars)
      in
      (PTuple [apat; bpat], None, body)
    ) indexed
  ) indexed in
  let body = EMatch (ETuple [EVar "__x"; EVar "__y"], arms) in
  DImpl {
    is_pub     = true;
    is_default = false;
    iface_name = "Ord";
    type_args  = [TyCon type_name];
    impl_name  = None;
    requires   = [];
    methods    = [("compare", [PVar "__x"; PVar "__y"], body)];
  }

let derive_ord_record type_name fields =
  let pairs = List.map (fun f ->
    ( EFieldAccess (EVar "__a", f.field_name)
    , EFieldAccess (EVar "__b", f.field_name) )
  ) fields in
  let body = lex_compare_exprs pairs in
  DImpl {
    is_pub     = true;
    is_default = false;
    iface_name = "Ord";
    type_args  = [TyCon type_name];
    impl_name  = None;
    requires   = [];
    methods    = [("compare", [PVar "__a"; PVar "__b"], body)];
  }

(* ------------------------------------------------------------------ *)
(* Dispatch                                                            *)
(* ------------------------------------------------------------------ *)

let derive_for_data type_name variants iface =
  match iface with
  | "Eq"   -> Some (derive_eq_data   type_name variants)
  | "Show" -> Some (derive_show_data type_name variants)
  | "Ord"  -> Some (derive_ord_data  type_name variants)
  | _      -> None  (* unknown derive ignored — typecheck will catch it *)

let derive_for_record type_name fields iface =
  match iface with
  | "Eq"   -> Some (derive_eq_record   type_name fields)
  | "Show" -> Some (derive_show_record type_name fields)
  | "Ord"  -> Some (derive_ord_record  type_name fields)
  | _      -> None

(* ------------------------------------------------------------------ *)
(* Derive Num for newtypes                                             *)
(* ------------------------------------------------------------------ *)

let derive_num_newtype type_name con_name =
  let wrap e = EApp (EVar con_name, e) in
  let bin op name =
    (name,
     [PCon (con_name, [PVar "__a"]); PCon (con_name, [PVar "__b"])],
     wrap (EBinOp (op, EVar "__a", EVar "__b")))
  in
  let abs_method =
    ("abs",
     [PCon (con_name, [PVar "__a"])],
     wrap (EIf (
       EBinOp ("<", EVar "__a", ELit (LInt 0)),
       EUnOp ("-", EVar "__a"),
       EVar "__a")))
  in
  let signum_method =
    ("signum",
     [PCon (con_name, [PVar "__a"])],
     wrap (EIf (
       EBinOp ("<", EVar "__a", ELit (LInt 0)),
       ELit (LInt (-1)),
       EIf (
         EBinOp (">", EVar "__a", ELit (LInt 0)),
         ELit (LInt 1),
         ELit (LInt 0)))))
  in
  let from_int_method =
    ("fromInt", [PVar "__n"], wrap (EVar "__n"))
  in
  DImpl {
    is_pub     = true;
    is_default = false;
    iface_name = "Num";
    type_args  = [TyCon type_name];
    impl_name  = None;
    requires   = [];
    methods    = [ bin "+" "add"; bin "-" "sub"; bin "*" "mul"; bin "/" "div"
                 ; ("negate", [PCon (con_name, [PVar "__a"])],
                    wrap (EUnOp ("-", EVar "__a")))
                 ; abs_method; signum_method; from_int_method ];
  }

let derive_for_newtype type_name con_name iface =
  match iface with
  | "Num" -> Some (derive_num_newtype type_name con_name)
  | _     -> None

(* Expand a single decl into itself plus any generated impls. *)
let expand_decl = function
  | DData (pub, name, params, variants, derives) ->
    let impls = List.filter_map (derive_for_data name variants) derives in
    DData (pub, name, params, variants, []) :: impls
  | DRecord (pub, name, params, fields, derives) ->
    let impls = List.filter_map (derive_for_record name fields) derives in
    DRecord (pub, name, params, fields, []) :: impls
  | DNewtype (pub, name, params, con, fty, derives) ->
    let impls = List.filter_map (derive_for_newtype name con) derives in
    DNewtype (pub, name, params, con, fty, []) :: impls
  | d -> [d]

(* ── Record field pun desugaring ─────────────────────────────────────────
   `Name { a, b, c }` where Name is a record type and all items are bare
   variable references is syntactic sugar for `Name { a = a, b = b, c = c }`.
   The parser emits ESetLit for these (no IDENT = expr markers), so we rewrite
   them here after collecting record type names from DRecord declarations. *)

let strip_loc = function ELoc (_, e) -> e | e -> e
let is_var e = match strip_loc e with EVar _ -> true | _ -> false
let var_name e = match strip_loc e with EVar n -> n | _ -> assert false

let rec map_expr f e =
  let e' = match e with
    | ELoc (loc, inner)       -> ELoc (loc, map_expr f inner)
    | EApp (e1, e2)           -> EApp (map_expr f e1, map_expr f e2)
    | ELam (ps, body)         -> ELam (ps, map_expr f body)
    | ELet (m, p, e1, e2)    -> ELet (m, p, map_expr f e1, map_expr f e2)
    | EMatch (e0, arms)       ->
        EMatch (map_expr f e0,
          List.map (fun (p, g, b) -> (p, Option.map (map_expr f) g, map_expr f b)) arms)
    | EIf (c, t, el)          -> EIf (map_expr f c, map_expr f t, map_expr f el)
    | EBinOp (op, e1, e2)    -> EBinOp (op, map_expr f e1, map_expr f e2)
    | EUnOp (op, e0)          -> EUnOp (op, map_expr f e0)
    | EFieldAccess (e0, n)    -> EFieldAccess (map_expr f e0, n)
    | ERecordCreate (n, flds) -> ERecordCreate (n, List.map (fun (k,v) -> (k, map_expr f v)) flds)
    | ERecordUpdate (e0, flds)-> ERecordUpdate (map_expr f e0, List.map (fun (k,v) -> (k, map_expr f v)) flds)
    | EArrayLit es            -> EArrayLit (List.map (map_expr f) es)
    | EListLit es             -> EListLit (List.map (map_expr f) es)
    | ETuple es               -> ETuple (List.map (map_expr f) es)
    | EMapLit (n, kvs)        -> EMapLit (n, List.map (fun (k,v) -> (map_expr f k, map_expr f v)) kvs)
    | ESetLit (n, es)         -> ESetLit (n, List.map (map_expr f) es)
    | EIndex (e0, i)          -> EIndex (map_expr f e0, map_expr f i)
    | EDo stmts               -> EDo (List.map (map_do_stmt f) stmts)
    | EAnnot (e0, t)          -> EAnnot (map_expr f e0, t)
    | EInfix (op, e1, e2)    -> EInfix (op, map_expr f e1, map_expr f e2)
    | EListComp (body, quals) ->
        EListComp (map_expr f body, List.map (map_lc_qual f) quals)
    | e0                      -> e0
  in
  f e'

and map_lc_qual f = function
  | LCGen (p, e)    -> LCGen (p, map_expr f e)
  | LCGuard e       -> LCGuard (map_expr f e)
  | LCLet (m, p, e) -> LCLet (m, p, map_expr f e)

and map_do_stmt f = function
  | DoBind (p, e)   -> DoBind (p, map_expr f e)
  | DoExpr e        -> DoExpr (map_expr f e)
  | DoLet (m, p, e) -> DoLet (m, p, map_expr f e)
  | DoAssign (x, e)         -> DoAssign (x, map_expr f e)
  | DoFieldAssign (x, fld, e) -> DoFieldAssign (x, fld, map_expr f e)

let map_decl f = function
  | DFunDef (pub, n, ps, e)    -> DFunDef (pub, n, ps, map_expr f e)
  | DInterface iface           ->
      DInterface { iface with methods =
        List.map (fun m ->
          { m with method_default =
            Option.map (fun (ps, e) -> (ps, map_expr f e)) m.method_default })
        iface.methods }
  | DImpl impl                 ->
      DImpl { impl with methods =
        List.map (fun (n, ps, e) -> (n, ps, map_expr f e)) impl.methods }
  | d -> d

(* Rewrite ESetLit(name, [EVar n; ...]) → ERecordCreate when name is a record type *)
let desugar_record_puns record_names prog =
  let is_record n = List.mem n record_names in
  let rewrite = function
    | ESetLit (name, items)
      when is_record name && items <> [] && List.for_all is_var items ->
        ERecordCreate (name, List.map (fun e -> let n = var_name e in (n, EVar n)) items)
    | e -> e
  in
  List.map (map_decl rewrite) prog

(* ── List comprehension desugaring ──────────────────────────────────────────
   [body | x <- xs, guard, let p = e, ...]
   desugars right-to-left into nested andThen / if-else / let calls. *)

let desugar_list_comp body quals =
  List.fold_right (fun qual acc ->
    match qual with
    | LCGen (pat, xs) ->
        (* andThen xs (pat => acc) *)
        EApp (EApp (EVar "andThen", xs), ELam ([pat], acc))
    | LCGuard cond ->
        EIf (cond, acc, EListLit [])
    | LCLet (mut, pat, e) ->
        ELet (mut, pat, e, acc)
  ) quals (EListLit [body])

let desugar_list_comps prog =
  let rewrite = function
    | EListComp (body, quals) -> desugar_list_comp body quals
    | e -> e
  in
  List.map (map_decl rewrite) prog

let desugar_program (prog : program) : program =
  let expanded = List.concat_map expand_decl prog in
  let record_names = List.filter_map (function
    | DRecord (_, name, _, _, _) -> Some name
    | _ -> None) expanded in
  let after_puns = desugar_record_puns record_names expanded in
  desugar_list_comps after_puns
