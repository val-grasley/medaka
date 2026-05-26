open Ast

(* Left-fold string concatenations: e0 ++ e1 ++ ... *)
let concat_strings parts =
  match parts with
  | [] -> ELit (LString "")
  | [x] -> x
  | first :: rest ->
    List.fold_left (fun acc e -> EBinOp ("<>", acc, e)) first rest

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

(* Expand a single decl into itself plus any generated impls. *)
let expand_decl = function
  | DData (pub, name, params, variants, derives) ->
    let impls = List.filter_map (derive_for_data name variants) derives in
    DData (pub, name, params, variants, []) :: impls
  | DRecord (pub, name, params, fields, derives) ->
    let impls = List.filter_map (derive_for_record name fields) derives in
    DRecord (pub, name, params, fields, []) :: impls
  | d -> [d]

let desugar_program (prog : program) : program =
  List.concat_map expand_decl prog
