open Ast

let con_arity v = match v.con_payload with
  | ConPos tys   -> List.length tys
  | ConNamed fls -> List.length fls

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

(* Type applied to its params: Box a => TyApp (TyCon "Box", TyVar "a");
   Pair a b => TyApp (TyApp (TyCon "Pair", TyVar "a"), TyVar "b").
   With params = [], returns exactly TyCon type_name. *)
let applied_head type_name params =
  List.fold_left (fun acc p -> TyApp (acc, TyVar p)) (TyCon type_name) params

(* requires Iface p for each param p — empty when non-parametric. *)
let param_requires iface params =
  List.map (fun p -> (iface, [TyVar p])) params

(* Rewrite a freshly-built derived impl's head/constraints for the type's
   params, so `data Box a deriving (Eq)` yields `impl Eq (Box a) requires Eq a`
   instead of a malformed nullary `impl Eq Box`. *)
let apply_derive_params type_name params = function
  | DImpl r ->
    DImpl { r with
            type_args = [applied_head type_name params];
            requires  = param_requires r.iface_name params }
  | d -> d

(* Apply compare to two expressions; wrap same-constructor fields
   in a lexicographic cascade:
     match compare e0a e0b of Eq => (match compare e1a e1b of ...) | c => c *)
let rec lex_compare_exprs = function
  | [] -> EVar "Eq"
  | [(ea, eb)] -> EApp (EApp (EVar "compare", ea), eb)
  | (ea, eb) :: rest ->
    EMatch (
      EApp (EApp (EVar "compare", ea), eb),
      [ (PCon ("Eq", []), [], lex_compare_exprs rest)
      ; (PVar "__c",      [], EVar "__c")
      ]
    )

(* ------------------------------------------------------------------ *)
(* Derive Eq                                                           *)
(* ------------------------------------------------------------------ *)

let derive_eq_data type_name variants =
  (* One arm per constructor: same-constructor case compares fields pairwise.
     Final wildcard arm returns False for any cross-constructor pair. *)
  let same_con_arms = List.map (fun v ->
    let n = con_arity v in
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
    (PTuple [apat; bpat], [], body)
  ) variants in
  let wild_arm = (PTuple [PWild; PWild], [], EVar "False") in
  let body = EMatch (ETuple [EVar "__x"; EVar "__y"], same_con_arms @ [wild_arm]) in
  DImpl {
    is_pub     = true;
    is_default = false;
    impl_loc   = None;
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
    impl_loc   = None;
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
    let n = con_arity v in
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
    (pat, [], body)
  ) variants in
  let body = EMatch (EVar "__x", arms) in
  DImpl {
    is_pub     = true;
    is_default = false;
    impl_loc   = None;
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
    impl_loc   = None;
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
      let ni = con_arity vi in
      let nj = con_arity vj in
      let avars = List.init ni (fun k -> Printf.sprintf "__a%d" k) in
      let bvars = List.init nj (fun k -> Printf.sprintf "__b%d" k) in
      let apat = PCon (vi.con_name, List.map (fun x -> PVar x) avars) in
      let bpat = PCon (vj.con_name, List.map (fun x -> PVar x) bvars) in
      let body =
        if i < j then EVar "Lt"
        else if i > j then EVar "Gt"
        else lex_compare_exprs (List.map2 (fun a b -> (EVar a, EVar b)) avars bvars)
      in
      (PTuple [apat; bpat], [], body)
    ) indexed
  ) indexed in
  let body = EMatch (ETuple [EVar "__x"; EVar "__y"], arms) in
  DImpl {
    is_pub     = true;
    is_default = false;
    impl_loc   = None;
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
    impl_loc   = None;
    iface_name = "Ord";
    type_args  = [TyCon type_name];
    impl_name  = None;
    requires   = [];
    methods    = [("compare", [PVar "__a"; PVar "__b"], body)];
  }

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
    impl_loc   = None;
    iface_name = "Num";
    type_args  = [TyCon type_name];
    impl_name  = None;
    requires   = [];
    methods    = [ bin "+" "add"; bin "-" "sub"; bin "*" "mul"; bin "/" "div"
                 ; ("negate", [PCon (con_name, [PVar "__a"])],
                    wrap (EUnOp ("-", EVar "__a")))
                 ; abs_method; signum_method; from_int_method ];
  }

(* ------------------------------------------------------------------ *)
(* Derive Generic — structural `to_rep : a -> Rep`                     *)
(* ------------------------------------------------------------------ *)

(* `RCon "Name" [to_rep a0; to_rep a1; ...]` — name + positional field reps. *)
let generic_rcon con_name vars =
  let field_reps = List.map (fun x -> EApp (EVar "to_rep", EVar x)) vars in
  EApp (EApp (EVar "RCon", ELit (LString con_name)), EListLit field_reps)

let derive_generic_data type_name variants =
  (* One arm per constructor; named-field constructors are matched
     positionally, consistent with derive_eq_data/derive_show_data. *)
  let arms = List.map (fun v ->
    let n = con_arity v in
    let vars = List.init n (fun i -> Printf.sprintf "__a%d" i) in
    let pat =
      if n = 0 then PCon (v.con_name, [])
      else PCon (v.con_name, List.map (fun x -> PVar x) vars)
    in
    (pat, [], generic_rcon v.con_name vars)
  ) variants in
  DImpl {
    is_pub     = true;
    is_default = false;
    impl_loc   = None;
    iface_name = "Generic";
    type_args  = [TyCon type_name];
    impl_name  = None;
    requires   = [];
    methods    = [("to_rep", [PVar "__x"], EMatch (EVar "__x", arms))];
  }

let derive_generic_record type_name fields =
  let field_reps = List.map (fun f ->
    ERecordCreate ("RField",
      [ ("fld_name", ELit (LString f.field_name))
      ; ("fld_rep",  EApp (EVar "to_rep", EFieldAccess (EVar "__r", f.field_name))) ])
  ) fields in
  let body = EApp (EApp (EVar "RRecord", ELit (LString type_name)), EListLit field_reps) in
  DImpl {
    is_pub     = true;
    is_default = false;
    impl_loc   = None;
    iface_name = "Generic";
    type_args  = [TyCon type_name];
    impl_name  = None;
    requires   = [];
    methods    = [("to_rep", [PVar "__r"], body)];
  }

let derive_generic_newtype type_name con_name =
  DImpl {
    is_pub     = true;
    is_default = false;
    impl_loc   = None;
    iface_name = "Generic";
    type_args  = [TyCon type_name];
    impl_name  = None;
    requires   = [];
    methods    = [("to_rep", [PCon (con_name, [PVar "__a"])],
                   generic_rcon con_name ["__a"])];
  }

let derive_for_newtype type_name params con_name iface =
  let mk f = Some (apply_derive_params type_name params (f type_name con_name)) in
  match iface with
  | "Num"     -> mk derive_num_newtype
  | "Generic" -> mk derive_generic_newtype
  | _         -> None

(* ── Derive Arbitrary ─────────────────────────────────────────────────── *)

(* Map a field type to a random-value expression using specific rand externs. *)
let rec arbitrary_expr_for_ty = function
  | TyCon "Int"    -> EApp (EApp (EVar "randomInt", EUnOp ("-", ELit (LInt 1000))), ELit (LInt 1000))
  | TyCon "Bool"   -> EApp (EVar "randomBool", ELit LUnit)
  | TyCon "Float"  -> EApp (EVar "randomFloat", ELit LUnit)
  | TyCon "Char"   -> EApp (EVar "randomChar", ELit LUnit)
  | TyCon "String" ->
    (* Generate a short random string via concatenation of random chars *)
    EApp (EVar "arbitraryString", ELit LUnit)
  | TyVar _ ->
    (* Type variable: call arbitrary () and hope dispatch works *)
    EApp (EVar "arbitrary", ELit LUnit)
  | TyApp (TyCon "List", t) ->
    (* Build a list of up to 5 elements *)
    EApp (EApp (EVar "arbitraryList",
      arbitrary_expr_for_ty t),
      EApp (EApp (EVar "randomInt", ELit (LInt 0)), ELit (LInt 5)))
  | TyApp (TyCon "Option", t) ->
    EIf (EApp (EVar "randomBool", ELit LUnit),
      EApp (EVar "Some", arbitrary_expr_for_ty t),
      EVar "None")
  | _ ->
    (* Unknown type: fall back to calling arbitrary () *)
    EApp (EVar "arbitrary", ELit LUnit)

(* Generate `impl Arbitrary TypeName` for an enum-like data type. *)
let derive_arbitrary_data type_name variants =
  let n_ctors = List.length variants in
  (* Build match arms: 0 → Ctor0, 1 → Ctor1, ..., n-1 → CtorLast *)
  let arms =
    List.mapi (fun i v ->
      let pat = if i = n_ctors - 1 then PWild else PLit (LInt i) in
      let body =
        match v.con_payload with
        | ConPos [] -> EVar v.con_name
        | ConPos field_tys ->
          List.fold_left (fun acc field_ty ->
            EApp (acc, arbitrary_expr_for_ty field_ty)
          ) (EVar v.con_name) field_tys
        | ConNamed named_fields ->
          let field_exprs = List.map (fun f ->
            (f.field_name, arbitrary_expr_for_ty f.field_type)
          ) named_fields in
          ERecordCreate (v.con_name, field_exprs)
      in
      (pat, [], body)
    ) variants
  in
  let gen_body =
    EMatch (
      EApp (EApp (EVar "randomInt", ELit (LInt 0)), ELit (LInt (n_ctors - 1))),
      arms)
  in
  DImpl {
    is_pub     = true;
    is_default = false;
    impl_loc   = None;
    iface_name = "Arbitrary";
    type_args  = [TyCon type_name];
    impl_name  = None;
    requires   = [];
    methods    = [("arbitrary", [PLit LUnit], gen_body)];
  }

(* Generate `impl Arbitrary TypeName` for a record type. *)
let derive_arbitrary_record type_name fields =
  let field_exprs = List.map (fun f ->
    (f.field_name, arbitrary_expr_for_ty f.field_type)
  ) fields in
  let gen_body = ERecordCreate (type_name, field_exprs) in
  DImpl {
    is_pub     = true;
    is_default = false;
    impl_loc   = None;
    iface_name = "Arbitrary";
    type_args  = [TyCon type_name];
    impl_name  = None;
    requires   = [];
    methods    = [("arbitrary", [PLit LUnit], gen_body)];
  }

let derive_for_data type_name params variants iface =
  let mk f = Some (apply_derive_params type_name params (f type_name variants)) in
  match iface with
  | "Eq"        -> mk derive_eq_data
  | "Show"      -> mk derive_show_data
  | "Ord"       -> mk derive_ord_data
  | "Arbitrary" -> mk derive_arbitrary_data
  | "Generic"   -> mk derive_generic_data
  | _           -> None  (* unknown derive ignored — typecheck will catch it *)

let derive_for_record type_name params fields iface =
  let mk f = Some (apply_derive_params type_name params (f type_name fields)) in
  match iface with
  | "Eq"        -> mk derive_eq_record
  | "Show"      -> mk derive_show_record
  | "Ord"       -> mk derive_ord_record
  | "Arbitrary" -> mk derive_arbitrary_record
  | "Generic"   -> mk derive_generic_record
  | _           -> None

(* Expand a single decl into itself plus any generated impls. *)
let rec expand_decl = function
  | DData (vis, name, params, variants, derives) ->
    let impls = List.filter_map (derive_for_data name params variants) derives in
    DData (vis, name, params, variants, []) :: impls
  | DRecord (vis, name, params, fields, derives) ->
    let impls = List.filter_map (derive_for_record name params fields) derives in
    DRecord (vis, name, params, fields, []) :: impls
  | DNewtype (pub, name, params, con, fty, derives) ->
    let impls = List.filter_map (derive_for_newtype name params con) derives in
    DNewtype (pub, name, params, con, fty, []) :: impls
  | DAttrib (attrs, d) ->
    (match expand_decl d with
     | [] -> []
     | first :: rest -> DAttrib (attrs, first) :: rest)
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
    | ELet (m, r, p, e1, e2) -> ELet (m, r, p, map_expr f e1, map_expr f e2)
    | ELetGroup (bs, e2)      ->
      ELetGroup (
        List.map (fun (n, clauses) ->
          (n, List.map (fun (ps, body) -> (ps, map_expr f body)) clauses)
        ) bs,
        map_expr f e2)
    | EMatch (e0, arms)       ->
        let map_qual = function
          | GBool g      -> GBool (map_expr f g)
          | GBind (p, g) -> GBind (p, map_expr f g)
        in
        EMatch (map_expr f e0,
          List.map (fun (p, gs, b) -> (p, List.map map_qual gs, map_expr f b)) arms)
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
    | ERangeList (lo, hi, incl)  -> ERangeList  (map_expr f lo, map_expr f hi, incl)
    | ERangeArray (lo, hi, incl) -> ERangeArray (map_expr f lo, map_expr f hi, incl)
    | ESlice (e0, lo, hi, incl)  -> ESlice (map_expr f e0, map_expr f lo, map_expr f hi, incl)
    | EBlock stmts            -> EBlock (List.map (map_do_stmt f) stmts)
    | EDo (tag, stmts)        -> EDo (tag, List.map (map_do_stmt f) stmts)
    | EAnnot (e0, t)          -> EAnnot (map_expr f e0, t)
    | EInfix (op, e1, e2)    -> EInfix (op, map_expr f e1, map_expr f e2)
    | EListComp (body, quals) ->
        EListComp (map_expr f body, List.map (map_lc_qual f) quals)
    | EQuestion e0            -> EQuestion (map_expr f e0)
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
  | DoLetElse (p, e, alt)   -> DoLetElse (p, map_expr f e, map_expr f alt)

let rec map_decl f = function
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
  | DProp p -> DProp { p with prop_body = map_expr f p.prop_body }
  | DAttrib (attrs, d) -> DAttrib (attrs, map_decl f d)
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

let rec is_refutable = function
  | PVar _     -> false
  | PWild      -> false
  | PLit _     -> true
  | PCon _     -> true
  | PCons _    -> true
  | PList _    -> true
  | PRng _     -> true
  | PRec _     -> true
  | PTuple ps  -> List.exists is_refutable ps
  | PAs (_, p) -> is_refutable p

let desugar_list_comp body quals =
  List.fold_right (fun qual acc ->
    match qual with
    | LCGen (pat, xs) ->
        let lam =
          if is_refutable pat then
            ELam ([PVar "__lc_x"],
                  EMatch (EVar "__lc_x",
                          [(pat,  [], acc);
                           (PWild, [], EListLit [])]))
          else
            ELam ([pat], acc)
        in
        EApp (EApp (EVar "andThen", xs), lam)
    | LCGuard cond ->
        EIf (cond, acc, EListLit [])
    | LCLet (mut, pat, e) ->
        ELet (mut, false, pat, e, acc)
  ) quals (EListLit [body])

let desugar_list_comps prog =
  let rewrite = function
    | EListComp (body, quals) -> desugar_list_comp body quals
    | e -> e
  in
  List.map (map_decl rewrite) prog

(* ── ? operator desugaring ────────────────────────────────────────────────
   `let pat = e ? in rest` rewrites to `andThen e (pat => rest)`.
   The runtime semantics fall out of `andThen`'s short-circuit on Err / None.

   Inside a do-block, the indent-based block parses as DoLet/DoBind/DoExpr
   stmts.  `let pat = e ?` becomes a DoLet, which we rewrite to DoBind —
   the do-block already dispatches DoBind through the Thenable VMulti, which
   short-circuits identically.

   Misplaced `?` (anywhere else) survives this pass as a raw EQuestion node
   and is flagged by resolve.ml. *)

let rewrite_question_expr = function
  | ELet (mut, is_fun, pat, e1, e2) ->
    (match strip_loc e1 with
     | EQuestion inner ->
       EApp (EApp (EVar "andThen", inner), ELam ([pat], e2))
     | _ -> ELet (mut, is_fun, pat, e1, e2))
  | EDo (tag, stmts) ->
    let rewrite_stmt = function
      | DoLet (_, pat, e) as s ->
        (match strip_loc e with
         | EQuestion inner -> DoBind (pat, inner)
         | _ -> s)
      | s -> s
    in
    EDo (tag, List.map rewrite_stmt stmts)
  | EBlock stmts ->
    (* If any DoLet has `?` on its RHS, the whole block is implicitly monadic
       (Result/Option chaining via `andThen`).  Promote the EBlock to an EDo
       and rewrite the `?` stmts to DoBind, so the existing EDo dispatch
       (which sets current_monad_type) handles `pure` correctly inside. *)
    let has_question =
      List.exists (function
        | DoLet (_, _, e) ->
          (match strip_loc e with EQuestion _ -> true | _ -> false)
        | _ -> false
      ) stmts
    in
    if has_question then
      let rewrite_stmt = function
        | DoLet (_, pat, e) as s ->
          (match strip_loc e with
           | EQuestion inner -> DoBind (pat, inner)
           | _ -> s)
        | s -> s
      in
      EDo (ref None, List.map rewrite_stmt stmts)
    else
      EBlock stmts
  | e -> e

let desugar_questions prog =
  List.map (map_decl rewrite_question_expr) prog

(* Coalesce interface method entries that the parser splits in two: a signature
   line `f : T` (method_default = None) and a default-clause line `f p = body`
   (method_type = TyVar "_", method_default = Some) become a single entry that
   carries both the declared type and the default body.  Without this, the lone
   `TyVar "_"` default entry makes register_interface re-generalize a
   level-0-instantiated body type to Forall[] (clobbering the real scheme) and
   makes the evaluator's record_iface_dispatch overwrite the method's dispatch
   positions with []. *)
let merge_iface_methods (methods : iface_method list) : iface_method list =
  let order = ref [] in
  let tbl : (string, iface_method) Hashtbl.t = Hashtbl.create 8 in
  List.iter (fun m ->
    match Hashtbl.find_opt tbl m.method_name with
    | None ->
      order := m.method_name :: !order;
      Hashtbl.replace tbl m.method_name m
    | Some prev ->
      let typed = match prev.method_type with TyVar "_" -> m.method_type | t -> t in
      let default =
        match prev.method_default with Some d -> Some d | None -> m.method_default
      in
      Hashtbl.replace tbl m.method_name
        { method_name = m.method_name; method_type = typed; method_default = default }
  ) methods;
  List.rev_map (fun n -> Hashtbl.find tbl n) !order

let merge_iface_defaults prog =
  List.map (function
    | DInterface iface ->
      DInterface { iface with methods = merge_iface_methods iface.methods }
    | d -> d
  ) prog

let desugar_program (prog : program) : program =
  let prog = merge_iface_defaults prog in
  let expanded = List.concat_map expand_decl prog in
  let record_names = List.filter_map (function
    | DRecord (_, name, _, _, _) -> Some name
    | _ -> None) expanded in
  let after_puns = desugar_record_puns record_names expanded in
  let after_lc   = desugar_list_comps after_puns in
  desugar_questions after_lc

(* Desugar a standalone expression (e.g. a REPL ReplExpr).  Applies the
   passes that don't require program-level context: list-comp rewrites and
   `?` rewrites.  Record-pun desugaring needs the list of record-type names,
   which is only available at program scope, so it's skipped here. *)
let desugar_expr (e : expr) : expr =
  let rewrite_lc = function
    | EListComp (body, quals) -> desugar_list_comp body quals
    | e -> e
  in
  map_expr rewrite_question_expr (map_expr rewrite_lc e)

let desugar_repl_item (item : repl_item) : repl_item =
  match item with
  | ReplDecl decls -> ReplDecl (desugar_program decls)
  | ReplExpr e     -> ReplExpr (desugar_expr e)
