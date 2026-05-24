(* Hindley-Milner type inference with let-polymorphism, ADTs, and pattern matching.
   Uses Rémy-style level-based generalization (no environment scan needed).

   Not yet: records, effects, interfaces, exhaustiveness checking. *)

open Ast

(* ── Types ──────────────────────────────────────── *)

type level = int

type tyvar_info =
  | Unbound of int * level
  | Link    of mono

and mono =
  | TVar   of tyvar_info ref
  | TCon   of string
  | TApp   of mono * mono
  | TFun   of mono * mono
  | TTuple of mono list

(* A type scheme: forall <ids>. mono. The bound ids are tyvar IDs from `mono`. *)
type scheme = Forall of int list * mono

(* Per-record metadata used for creation, access, and update typing.
   The TVars in rec_result / rec_fields are the same refs as those in
   rec_params, so substituting one set substitutes all. *)
type record_info = {
  rec_params : int list;              (* quantified tyvar IDs *)
  rec_result : mono;                  (* TCon R applied to param TVars *)
  rec_fields : (ident * mono) list;  (* field name → field type (shares param TVars) *)
}

(* Per-interface metadata. iface_param_ids are the bound tyvar IDs for the
   interface's type parameters; used in check_impl to build a directed
   substitution (id → concrete mono) when validating a specific impl. *)
type iface_info = {
  iface_param_ids : int list;
  iface_methods   : (ident * scheme) list;  (* method name → general scheme *)
  iface_defaults  : ident list;             (* method names that have default impls *)
}

(* ── Effects ─────────────────────────────────────── *)

type effect_set = string list  (* sorted, deduplicated *)

(* ── Errors ─────────────────────────────────────── *)

type type_error =
  | TypeMismatch   of mono * mono
  | InfiniteType   of int * mono
  | UnboundVar     of ident
  | UnknownCtor    of ident
  | ArityMismatch  of ident * int * int   (* name, expected, got *)
  | UnknownRecord  of ident
  | UnknownField   of ident * ident       (* field, record *)
  | MissingField   of ident * ident       (* field, record *)
  | ImpureFunction of ident * effect_set  (* unannotated fn with inferred effects *)
  | EffectEscape   of ident * effect_set * effect_set  (* fn, declared, undeclared extras *)
  | UnknownInterface   of ident               (* impl references unknown interface *)
  | ExtraMethod        of ident * ident       (* iface_name, method not in interface *)
  | MissingMethod      of ident * ident       (* iface_name, missing required method *)
  | MethodTypeMismatch of ident * mono * mono (* method_name, expected, actual *)
  | ImplArityMismatch  of ident * int * int   (* iface_name, expected params, got type_args *)
  | Other          of string

exception Type_error of type_error

let fail e = raise (Type_error e)

(* ── State: fresh vars + current level ──────────── *)

let tyvar_counter = ref 0
let current_level = ref 0

let reset_state () =
  tyvar_counter := 0;
  current_level := 0

let fresh_var () =
  incr tyvar_counter;
  TVar (ref (Unbound (!tyvar_counter, !current_level)))

let enter_level () = incr current_level
let exit_level  () = decr current_level

(* ── Following links and union-find compaction ──── *)

let rec normalize = function
  | TVar { contents = Link t } -> normalize t
  | t -> t

(* ── Occurs check + level adjustment ────────────── *)

(* When unifying var v (at level L) with type t, every unbound var in t at
   level > L must have its level lowered to L (so it doesn't get generalized
   prematurely). Also fails if v itself appears in t. *)
let rec occurs_adjust id level = function
  | TVar v ->
    (match !v with
     | Link t -> occurs_adjust id level t
     | Unbound (id', level') ->
       if id = id' then fail (InfiniteType (id, TVar v))
       else if level' > level then
         v := Unbound (id', level))
  | TCon _ -> ()
  | TApp (a, b) | TFun (a, b) ->
    occurs_adjust id level a; occurs_adjust id level b
  | TTuple ts ->
    List.iter (occurs_adjust id level) ts

(* ── Unification ────────────────────────────────── *)

let rec unify t1 t2 =
  let t1 = normalize t1 in
  let t2 = normalize t2 in
  match t1, t2 with
  | TVar v1, TVar v2 when v1 == v2 -> ()
  | TVar v, t | t, TVar v ->
    (match !v with
     | Link _ -> assert false
     | Unbound (id, level) ->
       occurs_adjust id level t;
       v := Link t)
  | TCon n1, TCon n2 when n1 = n2 -> ()
  | TApp (a1, b1), TApp (a2, b2) ->
    unify a1 a2; unify b1 b2
  | TFun (a1, b1), TFun (a2, b2) ->
    unify a1 a2; unify b1 b2
  | TTuple ts1, TTuple ts2 when List.length ts1 = List.length ts2 ->
    List.iter2 unify ts1 ts2
  | _ ->
    fail (TypeMismatch (t1, t2))

(* ── Generalization & instantiation ─────────────── *)

let rec free_unbound acc = function
  | TVar v ->
    (match !v with
     | Link t -> free_unbound acc t
     | Unbound (id, level) ->
       if level > !current_level && not (List.mem id acc) then id :: acc
       else acc)
  | TCon _ -> acc
  | TApp (a, b) | TFun (a, b) ->
    free_unbound (free_unbound acc a) b
  | TTuple ts ->
    List.fold_left free_unbound acc ts

let generalize t = Forall (free_unbound [] t, t)

let instantiate (Forall (vars, t)) =
  let sub = List.map (fun id -> (id, fresh_var ())) vars in
  let rec walk t = match normalize t with
    | TVar v ->
      (match !v with
       | Unbound (id, _) -> (try List.assoc id sub with Not_found -> TVar v)
       | Link _ -> assert false)
    | TCon _ as t -> t
    | TApp (a, b)  -> TApp (walk a, walk b)
    | TFun (a, b)  -> TFun (walk a, walk b)
    | TTuple ts    -> TTuple (List.map walk ts)
  in
  walk t

let monotype t = Forall ([], t)

(* Like instantiate, but maps specific bound IDs to provided monos instead of
   always creating fresh vars.  Used by check_impl to substitute the impl's
   concrete type args for the interface's type-parameter IDs. *)
let instantiate_with (Forall (vars, t)) (subs : (int * mono) list) =
  let sub = List.map (fun id ->
    (id, try List.assoc id subs with Not_found -> fresh_var ())
  ) vars in
  let rec walk t = match normalize t with
    | TVar v ->
      (match !v with
       | Unbound (id, _) -> (try List.assoc id sub with Not_found -> TVar v)
       | Link _ -> assert false)
    | TCon _ as t -> t
    | TApp (a, b)  -> TApp (walk a, walk b)
    | TFun (a, b)  -> TFun (walk a, walk b)
    | TTuple ts    -> TTuple (List.map walk ts)
  in
  walk t

(* ── Pretty printing ────────────────────────────── *)

let pp_mono t =
  let names = Hashtbl.create 8 in
  let counter = ref 0 in
  let name_of id =
    try Hashtbl.find names id
    with Not_found ->
      let n = !counter in
      incr counter;
      let s =
        if n < 26 then Printf.sprintf "'%c" (Char.chr (Char.code 'a' + n))
        else Printf.sprintf "'t%d" n
      in
      Hashtbl.add names id s;
      s
  in
  let rec go prec t = match normalize t with
    | TVar v ->
      (match !v with
       | Link _ -> assert false
       | Unbound (id, _) -> name_of id)
    | TCon n -> n
    | TApp (a, b) ->
      (* let-bind to force left-to-right evaluation so names track reading order *)
      let sa = go 2 a in
      let sb = go 3 b in
      let s = sa ^ " " ^ sb in
      if prec > 2 then "(" ^ s ^ ")" else s
    | TFun (a, b) ->
      let sa = go 2 a in
      let sb = go 1 b in
      let s = sa ^ " -> " ^ sb in
      if prec > 1 then "(" ^ s ^ ")" else s
    | TTuple ts ->
      Printf.sprintf "(%s)" (String.concat ", " (List.map (go 0) ts))
  in
  go 0 t

let pp_scheme (Forall (_vars, t)) = pp_mono t

let pp_error = function
  | TypeMismatch (a, b) ->
    Printf.sprintf "Type mismatch: %s vs %s" (pp_mono a) (pp_mono b)
  | InfiniteType (_, t) ->
    Printf.sprintf "Cannot construct infinite type involving %s" (pp_mono t)
  | UnboundVar n   -> Printf.sprintf "Unbound variable: %s" n
  | UnknownCtor n  -> Printf.sprintf "Unknown constructor: %s" n
  | ArityMismatch (n, exp, got) ->
    Printf.sprintf "Constructor %s expects %d args, got %d" n exp got
  | UnknownRecord r -> Printf.sprintf "Unknown record type: %s" r
  | UnknownField (f, r) ->
    Printf.sprintf "Field %s does not belong to record %s" f r
  | MissingField (f, r) ->
    Printf.sprintf "Missing field %s in construction of record %s" f r
  | ImpureFunction (name, effs) ->
    Printf.sprintf "Function '%s' has no effect annotation but performs <%s>"
      name (String.concat ", " effs)
  | EffectEscape (name, declared, extras) ->
    Printf.sprintf "Function '%s' declared with <%s> but also performs <%s>"
      name (String.concat ", " declared) (String.concat ", " extras)
  | UnknownInterface n ->
    Printf.sprintf "Unknown interface: %s" n
  | ExtraMethod (iface, m) ->
    Printf.sprintf "Method '%s' is not part of interface %s" m iface
  | MissingMethod (iface, m) ->
    Printf.sprintf "Interface %s requires method '%s' but it is not provided" iface m
  | MethodTypeMismatch (m, expected, actual) ->
    Printf.sprintf "Method '%s': expected type %s but got %s"
      m (pp_mono expected) (pp_mono actual)
  | ImplArityMismatch (iface, expected, got) ->
    Printf.sprintf "Interface %s has %d type parameter(s) but impl provides %d type argument(s)"
      iface expected got
  | Other msg -> msg

(* ── Environment ────────────────────────────────── *)

type env = {
  vars         : (ident * scheme) list;
  ctors        : (ident, scheme) Hashtbl.t;   (* constructor name → scheme *)
  records      : (ident, record_info) Hashtbl.t;  (* record name → info *)
  field_owners : (ident, ident) Hashtbl.t;    (* field name → record name *)
  interfaces   : (ident, iface_info) Hashtbl.t;  (* interface name → info *)
}

let empty_env () = {
  vars         = [];
  ctors        = Hashtbl.create 16;
  records      = Hashtbl.create 8;
  field_owners = Hashtbl.create 16;
  interfaces   = Hashtbl.create 8;
}

let lookup_var env x =
  try List.assoc x env.vars
  with Not_found -> fail (UnboundVar x)

let extend_var env x s = { env with vars = (x, s) :: env.vars }

let extend_vars env bindings =
  List.fold_left (fun e (n, s) -> extend_var e n s) env bindings

(* ── Built-in types & primitives ────────────────── *)

let t_int    = TCon "Int"
let t_float  = TCon "Float"
let t_string = TCon "String"
let t_char   = TCon "Char"
let t_bool   = TCon "Bool"
let t_unit   = TCon "Unit"

let t_list   t = TApp (TCon "List",   t)
let t_array  t = TApp (TCon "Array",  t)
let t_option t = TApp (TCon "Option", t)
let t_result a b = TApp (TApp (TCon "Result", a), b)

(* Build the initial environment with built-in constructors and a few primitives.
   These let our test programs compile without a stdlib in place. *)
let initial_env () =
  let env = empty_env () in
  (* Option *)
  let a = fresh_var () in
  Hashtbl.replace env.ctors "Some" (Forall ([], TFun (a, t_option a)));
  let a = fresh_var () in
  Hashtbl.replace env.ctors "None" (Forall ([], t_option a));
  (* Result *)
  let a = fresh_var () in
  let b = fresh_var () in
  Hashtbl.replace env.ctors "Ok"  (Forall ([], TFun (a, t_result a b)));
  let a = fresh_var () in
  let b = fresh_var () in
  Hashtbl.replace env.ctors "Err" (Forall ([], TFun (b, t_result a b)));
  (* Bool *)
  Hashtbl.replace env.ctors "True"  (monotype t_bool);
  Hashtbl.replace env.ctors "False" (monotype t_bool);
  (* Generalize all the fresh vars introduced above by resetting level state *)
  Hashtbl.filter_map_inplace
    (fun _name s ->
       match s with
       | Forall (_, t) -> Some (generalize t))
    env.ctors;
  (* A couple of primitives to write tests.
     Each is created at level 1 so generalize can quantify the vars. *)
  let mk_scheme f =
    enter_level ();
    let t = f () in
    exit_level ();
    generalize t
  in
  (* pure : forall m a. a -> m a   (HKT: m is a tyvar for a type constructor) *)
  let env = extend_var env "pure"
              (mk_scheme (fun () ->
                 let a = fresh_var () in
                 let m = fresh_var () in
                 TFun (a, TApp (m, a)))) in
  let env = extend_var env "print"
              (mk_scheme (fun () ->
                 let a = fresh_var () in TFun (a, t_unit))) in
  env

(* ── Translating AST types to mono ──────────────── *)

(* Used for type sigs and explicit annotations. Each TyVar is treated as
   universally quantified at the outer level (generalized after the whole
   sig is built). *)
let from_ast_type t =
  let env = Hashtbl.create 4 in
  let rec go = function
    | Ast.TyCon n -> TCon n
    | Ast.TyVar n ->
      (try Hashtbl.find env n
       with Not_found ->
         let v = fresh_var () in
         Hashtbl.add env n v;
         v)
    | Ast.TyApp (a, b) -> TApp (go a, go b)
    | Ast.TyFun (a, b) -> TFun (go a, go b)
    | Ast.TyTuple ts -> TTuple (List.map go ts)
    | Ast.TyEffect (_effs, t) -> go t  (* effects ignored for now *)
  in
  go t

(* ── Pattern typing ─────────────────────────────── *)

let type_lit = function
  | LInt _    -> t_int
  | LFloat _  -> t_float
  | LString _ -> t_string
  | LChar _   -> t_char
  | LBool _   -> t_bool
  | LUnit     -> t_unit

(* type_pat env p ⇒ (type of p, bindings p introduces) *)
let rec type_pat env = function
  | PVar x ->
    let v = fresh_var () in
    (v, [(x, monotype v)])
  | PWild ->
    (fresh_var (), [])
  | PLit l ->
    (type_lit l, [])
  | PTuple ps ->
    let typed = List.map (type_pat env) ps in
    (TTuple (List.map fst typed), List.concat_map snd typed)
  | PList ps ->
    let elem = fresh_var () in
    let bindings = List.concat_map (fun p ->
      let pt, b = type_pat env p in
      unify pt elem; b
    ) ps in
    (t_list elem, bindings)
  | PCons (h, t) ->
    let th, bh = type_pat env h in
    let tt, bt = type_pat env t in
    unify tt (t_list th);
    (t_list th, bh @ bt)
  | PCon (c, args) ->
    let scheme =
      try Hashtbl.find env.ctors c
      with Not_found -> fail (UnknownCtor c)
    in
    let ctor_t = instantiate scheme in
    let typed_args = List.map (type_pat env) args in
    let arg_types = List.map fst typed_args in
    let bindings  = List.concat_map snd typed_args in
    let result_t  = fresh_var () in
    let expected  = List.fold_right (fun at acc -> TFun (at, acc))
                      arg_types result_t in
    unify ctor_t expected;
    (result_t, bindings)

(* ── Record instantiation ───────────────────────── *)

(* Instantiate a record_info: substitute quantified param IDs with fresh vars,
   returning (concrete result type, concrete field list). *)
let instantiate_record info =
  let sub = List.map (fun id -> (id, fresh_var ())) info.rec_params in
  let rec walk t = match normalize t with
    | TVar v ->
      (match !v with
       | Unbound (id, _) ->
         (try List.assoc id sub with Not_found -> TVar v)
       | Link _ -> assert false)
    | TCon _ as t -> t
    | TApp (a, b)  -> TApp (walk a, walk b)
    | TFun (a, b)  -> TFun (walk a, walk b)
    | TTuple ts    -> TTuple (List.map walk ts)
  in
  let result = walk info.rec_result in
  let fields = List.map (fun (n, t) -> (n, walk t)) info.rec_fields in
  (result, fields)

(* ── Expression typing ──────────────────────────── *)

let rec infer env = function
  | ELit l -> type_lit l

  | EVar x ->
    if String.length x > 0 && x.[0] = '@' then
      (* @ImplName is a disambiguation hint — treated as Unit for now;
         full impl selection is Phase 4.2. *)
      t_unit
    else
      (try instantiate (Hashtbl.find env.ctors x)
       with Not_found -> instantiate (lookup_var env x))

  | EApp (f, x) ->
    let tf = infer env f in
    let tx = infer env x in
    let tr = fresh_var () in
    unify tf (TFun (tx, tr));
    tr

  | ELam (pats, body) ->
    let typed_pats = List.map (type_pat env) pats in
    let pat_types  = List.map fst typed_pats in
    let bindings   = List.concat_map snd typed_pats in
    let env' = extend_vars env bindings in
    let tb = infer env' body in
    List.fold_right (fun pt acc -> TFun (pt, acc)) pat_types tb

  | ELet (_mut, pat, e1, e2) ->
    enter_level ();
    let t1 = infer env e1 in
    exit_level ();
    (match pat with
     | PVar x ->
       let s = generalize t1 in
       infer (extend_var env x s) e2
     | _ ->
       (* Non-trivial pattern: no generalization (value restriction-like) *)
       let tp, bindings = type_pat env pat in
       unify tp t1;
       infer (extend_vars env bindings) e2)

  | EIf (c, t, e) ->
    unify (infer env c) t_bool;
    let tt = infer env t in
    let te = infer env e in
    unify tt te;
    tt

  | EBinOp (op, l, r) ->
    binop_type env op l r

  | EUnOp ("-", e) ->
    let te = infer env e in
    (* Allow Int or Float — pick Int for now *)
    unify te t_int; t_int
  | EUnOp ("!", e) ->
    unify (infer env e) t_bool; t_bool
  | EUnOp (op, _) ->
    fail (Other ("Unknown unary op: " ^ op))

  | EMatch (sc, arms) ->
    let tsc = infer env sc in
    let result = fresh_var () in
    List.iter (fun (pat, guard, body) ->
      let tp, bindings = type_pat env pat in
      unify tp tsc;
      let env' = extend_vars env bindings in
      (match guard with
       | None -> ()
       | Some g -> unify (infer env' g) t_bool);
      unify (infer env' body) result
    ) arms;
    result

  | ETuple es ->
    TTuple (List.map (infer env) es)

  | EListLit es ->
    let elem = fresh_var () in
    List.iter (fun e -> unify (infer env e) elem) es;
    t_list elem

  | EArrayLit es ->
    let elem = fresh_var () in
    List.iter (fun e -> unify (infer env e) elem) es;
    t_array elem

  | EAnnot (e, ast_t) ->
    let te = infer env e in
    let ta = from_ast_type ast_t in
    unify te ta;
    te

  | EInfix (op, l, r) ->
    let tf = instantiate (lookup_var env op) in
    let tl = infer env l in
    let tr = infer env r in
    let result = fresh_var () in
    unify tf (TFun (tl, TFun (tr, result)));
    result

  | EDo stmts ->
    (* Approach (b): introduce one per-block monad tyvar `m`.
       DoBind(pat, e) : e must be `m a`; pat binds `a`.
       DoExpr e       : e must be `m _` (value discarded).
       DoLet(pat, e)  : plain let — no monadic wrapping.
       The last statement determines the result type. *)
    if stmts = [] then fail (Other "Empty do block");
    let m = fresh_var () in
    let rec type_stmts env = function
      | [] -> assert false
      | [DoExpr e] ->
        let te = infer env e in
        let inner = fresh_var () in
        unify te (TApp (m, inner));
        te
      | [DoBind (pat, e)] ->
        (* Trailing bind discards the bound variable; result is m Unit *)
        let te = infer env e in
        let inner = fresh_var () in
        unify te (TApp (m, inner));
        let tp, _ = type_pat env pat in
        unify tp inner;
        TApp (m, t_unit)
      | [DoLet _] ->
        fail (Other "do block cannot end with a let binding")
      | DoExpr e :: rest ->
        let te = infer env e in
        let inner = fresh_var () in
        unify te (TApp (m, inner));
        type_stmts env rest
      | DoBind (pat, e) :: rest ->
        let te = infer env e in
        let inner = fresh_var () in
        unify te (TApp (m, inner));
        let tp, bindings = type_pat env pat in
        unify tp inner;
        type_stmts (extend_vars env bindings) rest
      | DoLet (_mut, pat, e) :: rest ->
        enter_level ();
        let t1 = infer env e in
        exit_level ();
        let env' = match pat with
          | PVar x -> extend_var env x (generalize t1)
          | _ ->
            let tp, bindings = type_pat env pat in
            unify tp t1;
            extend_vars env bindings
        in
        type_stmts env' rest
    in
    type_stmts env stmts

  | ERecordCreate (name, provided) ->
    let info =
      try Hashtbl.find env.records name
      with Not_found -> fail (UnknownRecord name)
    in
    let (result_t, field_types) = instantiate_record info in
    (* Every declared field must be supplied. *)
    List.iter (fun (fname, ftype) ->
      match List.assoc_opt fname provided with
      | None -> fail (MissingField (fname, name))
      | Some expr -> unify (infer env expr) ftype
    ) field_types;
    (* No extra (unknown) fields. *)
    List.iter (fun (fname, _) ->
      if not (List.mem_assoc fname field_types) then
        fail (UnknownField (fname, name))
    ) provided;
    result_t

  | EFieldAccess (e, field) ->
    let te = infer env e in
    let record_name =
      try Hashtbl.find env.field_owners field
      with Not_found -> fail (UnknownField (field, "<unknown>"))
    in
    let info = Hashtbl.find env.records record_name in
    let (result_t, field_types) = instantiate_record info in
    unify te result_t;
    (try List.assoc field field_types
     with Not_found -> assert false)  (* field_owners guarantees this exists *)

  | ERecordUpdate (e, updated) ->
    let te = infer env e in
    if updated = [] then te
    else begin
      let first_field = fst (List.hd updated) in
      let record_name =
        try Hashtbl.find env.field_owners first_field
        with Not_found -> fail (UnknownField (first_field, "<unknown>"))
      in
      let info = Hashtbl.find env.records record_name in
      let (result_t, field_types) = instantiate_record info in
      unify te result_t;
      List.iter (fun (fname, expr) ->
        let ftype =
          try List.assoc fname field_types
          with Not_found -> fail (UnknownField (fname, record_name))
        in
        unify (infer env expr) ftype
      ) updated;
      result_t
    end

  | EIndex (arr, idx) ->
    let ta = infer env arr in
    let ti = infer env idx in
    let elem = fresh_var () in
    unify ta (t_array elem);
    unify ti t_int;
    elem

and binop_type env op l r =
  let tl = infer env l in
  let tr = infer env r in
  match op with
  | "+" | "-" | "*" | "/" ->
    unify tl t_int; unify tr t_int; t_int
  | "==" | "!=" ->
    unify tl tr; t_bool
  | "<" | ">" | "<=" | ">=" ->
    unify tl t_int; unify tr t_int; t_bool
  | "&&" | "||" ->
    unify tl t_bool; unify tr t_bool; t_bool
  | "::" ->
    unify tr (t_list tl); tr
  | "++" ->
    let elem = fresh_var () in
    let lt = t_list elem in
    unify tl lt; unify tr lt; lt
  | "|>" ->
    (* x |> f  :  a -> (a -> b) -> b *)
    let b = fresh_var () in
    unify tr (TFun (tl, b)); b
  | ">>" ->
    (* f >> g  :  (a -> b) -> (b -> c) -> (a -> c) *)
    let a = fresh_var () in
    let b = fresh_var () in
    let c = fresh_var () in
    unify tl (TFun (a, b)); unify tr (TFun (b, c)); TFun (a, c)
  | "<<" ->
    (* f << g  :  (b -> c) -> (a -> b) -> (a -> c) *)
    let a = fresh_var () in
    let b = fresh_var () in
    let c = fresh_var () in
    unify tl (TFun (b, c)); unify tr (TFun (a, b)); TFun (a, c)
  | _ ->
    fail (Other ("Unknown binop: " ^ op))

(* ── Top-level processing ───────────────────────── *)

(* Group fn defs by name, preserving first-appearance order in source.
   Order matters for type-checking — later defs can use earlier defs at
   polymorphic types only if earlier defs are processed (and generalized)
   first. *)
let group_fundefs decls =
  let sigs = Hashtbl.create 16 in
  let clauses = Hashtbl.create 16 in
  let order = ref [] in
  List.iter (function
    | DTypeSig (n, t) ->
      if not (Hashtbl.mem clauses n) && not (Hashtbl.mem sigs n) then
        order := n :: !order;
      Hashtbl.replace sigs n t
    | DFunDef (n, pats, body) ->
      if not (Hashtbl.mem clauses n) then begin
        if not (Hashtbl.mem sigs n) then order := n :: !order
      end;
      let existing = try Hashtbl.find clauses n with Not_found -> [] in
      Hashtbl.replace clauses n (existing @ [(pats, body)])
    | _ -> ()
  ) decls;
  List.rev_map (fun n ->
    let cs = try Hashtbl.find clauses n with Not_found -> [] in
    let sg = try Some (Hashtbl.find sigs n) with Not_found -> None in
    (n, sg, cs)
  ) !order
  |> List.filter (fun (_, _, cs) -> cs <> [])  (* skip sigs with no def *)

(* Register data type constructors in env *)
let register_data env (name, params, variants) =
  (* Build a fresh tyvar per param *)
  enter_level ();
  let param_vars = List.map (fun p -> (p, fresh_var ())) params in
  let result_t =
    List.fold_left
      (fun acc (_, v) -> TApp (acc, v))
      (TCon name)
      param_vars
  in
  List.iter (fun v ->
    let rec go = function
      | Ast.TyCon n ->
        (try List.assoc n param_vars
         with Not_found -> TCon n)
      | Ast.TyVar n ->
        (try List.assoc n param_vars
         with Not_found ->
           (* unknown type var; treat as fresh *)
           fresh_var ())
      | Ast.TyApp (a, b) -> TApp (go a, go b)
      | Ast.TyFun (a, b) -> TFun (go a, go b)
      | Ast.TyTuple ts -> TTuple (List.map go ts)
      | Ast.TyEffect (_, t) -> go t
    in
    let arg_types = List.map go v.con_fields in
    let ctor_t =
      List.fold_right (fun a acc -> TFun (a, acc)) arg_types result_t
    in
    Hashtbl.replace env.ctors v.con_name (generalize ctor_t)
  ) variants;
  exit_level ()

(* Register a record declaration in env.  Mirrors register_data.
   Errors on field-name collision (the resolver should have caught it first,
   but we guard defensively). *)
let register_record env (name, params, fields) =
  enter_level ();
  let param_vars = List.map (fun p -> (p, fresh_var ())) params in
  let result_t =
    List.fold_left
      (fun acc (_, v) -> TApp (acc, v))
      (TCon name)
      param_vars
  in
  let go_ty ast_ty =
    let rec go = function
      | Ast.TyCon n ->
        (try List.assoc n param_vars with Not_found -> TCon n)
      | Ast.TyVar n ->
        (try List.assoc n param_vars with Not_found -> fresh_var ())
      | Ast.TyApp (a, b)  -> TApp (go a, go b)
      | Ast.TyFun (a, b)  -> TFun (go a, go b)
      | Ast.TyTuple ts    -> TTuple (List.map go ts)
      | Ast.TyEffect (_, t) -> go t
    in
    go ast_ty
  in
  let field_monos =
    List.map (fun f -> (f.Ast.field_name, go_ty f.Ast.field_type)) fields
  in
  (* exit_level BEFORE free_unbound so vars at level 1 satisfy level > 0 and
     get included in rec_params. This is what makes instantiate_record create
     fresh copies — without it every use would share the same TVar refs. *)
  exit_level ();
  let rec_params = free_unbound [] result_t in
  let info = { rec_params; rec_result = result_t; rec_fields = field_monos } in
  Hashtbl.replace env.records name info;
  List.iter (fun (fname, _) ->
    if Hashtbl.mem env.field_owners fname then
      fail (Other (Printf.sprintf
        "Field name collision: '%s' is already declared by another record" fname));
    Hashtbl.replace env.field_owners fname name
  ) field_monos

(* Build the clause's expression form: nested lambdas if there are args. *)
let clause_to_expr (pats, body) =
  if pats = [] then body
  else List.fold_right (fun p acc -> ELam ([p], acc)) pats body

(* Register an interface declaration.
   Creates fresh tvars for the type parameters at level 1, converts each
   method's AST type to mono, then generalizes — yielding a fully polymorphic
   scheme per method.  Returns the method scheme list so check_program can
   bind them in the env before typing top-level functions. *)
let register_interface env (iface_name, type_params, methods) =
  enter_level ();
  let param_vars = List.map (fun p -> (p, fresh_var ())) type_params in
  (* Each call to go_ty gets its own memoization table for method-level tvars.
     This ensures that occurrences of the same name within one method type
     (e.g., both `a`s in `(a -> b) -> f a -> f b`) resolve to the same TVar,
     while still being independent across different methods. *)
  let go_ty ast_ty =
    let method_vars = Hashtbl.create 4 in
    let rec go = function
      | Ast.TyCon n ->
        (try List.assoc n param_vars with Not_found -> TCon n)
      | Ast.TyVar n ->
        (match List.assoc_opt n param_vars with
         | Some v -> v
         | None ->
           (try Hashtbl.find method_vars n
            with Not_found ->
              let v = fresh_var () in
              Hashtbl.add method_vars n v;
              v))
      | Ast.TyApp (a, b)  -> TApp (go a, go b)
      | Ast.TyFun (a, b)  -> TFun (go a, go b)
      | Ast.TyTuple ts    -> TTuple (List.map go ts)
      | Ast.TyEffect (_, t) -> go t
    in
    go ast_ty
  in
  let method_monos = List.map (fun m ->
    (m.Ast.method_name, go_ty m.Ast.method_type)
  ) methods in
  (* exit_level BEFORE generalizing so param tvars (at level 1) satisfy
     level > current_level (0) and get quantified. *)
  exit_level ();
  let param_ids =
    List.map (fun (_, v) ->
      match normalize v with
      | TVar r -> (match !r with Unbound (id, _) -> id | _ -> assert false)
      | _ -> assert false
    ) param_vars
  in
  let method_schemes =
    List.map (fun (n, mt) -> (n, generalize mt)) method_monos
  in
  let defaults = List.filter_map (fun m ->
    if m.Ast.method_default <> None then Some m.Ast.method_name else None
  ) methods in
  let info = {
    iface_param_ids = param_ids;
    iface_methods   = method_schemes;
    iface_defaults  = defaults;
  } in
  Hashtbl.replace env.interfaces iface_name info;
  method_schemes

(* Validate a DImpl declaration against the registered interface.
   Instantiates each method's scheme with the impl's concrete type args and
   type-checks the provided method body against the resulting expected type. *)
let check_impl env (decl : decl) = match decl with
  | DImpl { iface_name; type_args; methods; _ } ->
    let info =
      try Hashtbl.find env.interfaces iface_name
      with Not_found -> fail (UnknownInterface iface_name)
    in
    let n_params = List.length info.iface_param_ids in
    let n_args   = List.length type_args in
    if n_params <> n_args then
      fail (ImplArityMismatch (iface_name, n_params, n_args));
    let concrete = List.map from_ast_type type_args in
    let subs = List.combine info.iface_param_ids concrete in
    (* Verify each required method is present and has the right type *)
    List.iter (fun (mname, mscheme) ->
      let expected_t = instantiate_with mscheme subs in
      match List.find_opt (fun (n, _, _) -> n = mname) methods with
      | None ->
        if not (List.mem mname info.iface_defaults) then
          fail (MissingMethod (iface_name, mname))
      | Some (_, pats, body) ->
        let impl_expr = clause_to_expr (pats, body) in
        enter_level ();
        let actual_t = infer env impl_expr in
        exit_level ();
        (try unify expected_t actual_t
         with Type_error (TypeMismatch (a, b)) ->
           fail (MethodTypeMismatch (mname, a, b)))
    ) info.iface_methods;
    (* Check for extra methods that are not part of the interface *)
    List.iter (fun (n, _, _) ->
      if not (List.mem_assoc n info.iface_methods) then
        fail (ExtraMethod (iface_name, n))
    ) methods
  | _ -> ()

(* ── Effect inference ────────────────────────────── *)

let effect_union a b = List.sort_uniq String.compare (a @ b)

(* Extract the declared effect set from an AST type signature.
   Follows TyFun arrows right-most; the first TyEffect on the return side
   is the function's declared effect.  `String -> <IO> Unit` → ["IO"]. *)
let rec declared_effects : Ast.ty -> effect_set = function
  | Ast.TyFun (_, ret) -> declared_effects ret
  | Ast.TyEffect (effs, _) -> List.sort_uniq String.compare effs
  | _ -> []

(* Compute the effect set that evaluating expression `e` produces.
   Direct calls (EApp, |>) contribute the callee's known effect set.
   Lambda bodies propagate their effects conservatively (lambdas may be called).
   Composition (>>, <<) includes effects of both composed functions. *)
let rec expr_effects (eff_env : (string, effect_set) Hashtbl.t) (e : expr) : effect_set =
  let call name = try Hashtbl.find eff_env name with Not_found -> [] in
  let sub e   = expr_effects eff_env e in
  (* Effects from calling `e` as a function — if it's a bare name we can look
     it up directly; otherwise fall back to the expression's own effects. *)
  let call_effs = function
    | EVar n -> call n
    | e -> sub e
  in
  match e with
  | ELit _ | EVar _ -> []
  | EApp (f, x) ->
    effect_union (call_effs f) (effect_union (sub f) (sub x))
  | ELam (_, body) ->
    sub body  (* conservative: include body effects in enclosing fn *)
  | ELet (_, _, e1, e2) -> effect_union (sub e1) (sub e2)
  | EIf (c, t, f)       -> effect_union (sub c) (effect_union (sub t) (sub f))
  | EBinOp ("|>", x, f) ->
    (* x |> f  ≡  f x — calling f contributes its effects *)
    effect_union (call_effs f) (sub x)
  | EBinOp (">>", f, g) | EBinOp ("<<", f, g) ->
    (* Composition — both functions may be called later; include both *)
    effect_union (call_effs f) (call_effs g)
  | EBinOp (_, l, r)    -> effect_union (sub l) (sub r)
  | EUnOp (_, e)         -> sub e
  | EMatch (sc, arms)    ->
    List.fold_left
      (fun acc (_, guard, body) ->
        let ge = match guard with None -> [] | Some g -> sub g in
        effect_union acc (effect_union ge (sub body)))
      (sub sc) arms
  | EDo stmts ->
    List.fold_left
      (fun acc s -> effect_union acc (do_stmt_effects eff_env s))
      [] stmts
  | EFieldAccess (e, _)      -> sub e
  | ERecordCreate (_, fs)    -> List.fold_left (fun a (_, v) -> effect_union a (sub v)) [] fs
  | ERecordUpdate (e, fs)    -> List.fold_left (fun a (_, v) -> effect_union a (sub v)) (sub e) fs
  | EArrayLit es | EListLit es ->
    List.fold_left (fun a e -> effect_union a (sub e)) [] es
  | ETuple es               -> List.fold_left (fun a e -> effect_union a (sub e)) [] es
  | EIndex (e, i)           -> effect_union (sub e) (sub i)
  | EAnnot (e, _)           -> sub e
  | EInfix (_, l, r)        -> effect_union (sub l) (sub r)

and do_stmt_effects eff_env = function
  | DoBind (_, e) | DoExpr e | DoLet (_, _, e) -> expr_effects eff_env e

(* Process each function group in declaration order:
     1. Infer its effect set (union of all clause bodies).
     2. Store it in eff_env so later definitions see it.
     3. Check against the declared signature; raise Type_error on violation.

   Purity rule: a function with NO effect annotation must infer the empty set.
   Annotation rule: declared effects must be a superset of inferred effects. *)
let infer_and_check_effects groups =
  let eff_env = Hashtbl.create 16 in
  Hashtbl.add eff_env "print" ["IO"];
  List.iter (fun (name, sig_opt, clauses) ->
    let inferred =
      List.fold_left
        (fun acc clause ->
          effect_union acc (expr_effects eff_env (clause_to_expr clause)))
        [] clauses
    in
    Hashtbl.replace eff_env name inferred;
    (match sig_opt with
     | None ->
       if inferred <> [] then fail (ImpureFunction (name, inferred))
     | Some sig_ty ->
       let decl = declared_effects sig_ty in
       let extras = List.filter (fun e -> not (List.mem e decl)) inferred in
       if extras <> [] then fail (EffectEscape (name, decl, extras)))
  ) groups

(* Type-check a whole program; return a (name → scheme) list.

   Strategy: pre-bind every top-level name with an unbound placeholder at
   level 1, then process each group ONE AT A TIME — typing its body at
   level 1, exiting to level 0, generalizing, and replacing the env binding
   with the generalized scheme before moving to the next group.

   This lets ungrouped definitions become polymorphic between uses (so
   `id x = x` then `a = id 5` then `b = id "hi"` works), while mutual
   recursion still type-checks because the forward reference unifies with
   the (still-monomorphic) placeholder. *)
let check_program (prog : program) : (ident * scheme) list =
  reset_state ();
  let env = initial_env () in

  (* Phase 1: register data, record, and interface declarations *)
  let iface_method_schemes = ref [] in
  List.iter (function
    | DData (n, ps, vs) -> register_data env (n, ps, vs)
    | DRecord (n, ps, fs) -> register_record env (n, ps, fs)
    | DInterface { iface_name; type_params; methods; _ } ->
      let ms = register_interface env (iface_name, type_params, methods) in
      iface_method_schemes := ms @ !iface_method_schemes
    | _ -> ()
  ) prog;

  (* Phase 2: collect type sigs and fn clause groups *)
  let groups = group_fundefs prog in

  (* Phase 3: pre-bind every top-level name with a placeholder at level 1.
     Also bind all interface methods so they are visible in function bodies. *)
  enter_level ();
  let placeholders = List.map (fun (n, _, _) -> (n, fresh_var ())) groups in
  exit_level ();
  let env = ref (
    let e = List.fold_left
      (fun e (n, t) -> extend_var e n (monotype t))
      env placeholders in
    List.fold_left (fun e (n, s) -> extend_var e n s) e !iface_method_schemes
  ) in

  (* Phase 4: process each group sequentially. *)
  let results = List.map (fun (name, sig_opt, clauses) ->
    let placeholder = List.assoc name placeholders in
    enter_level ();
    (match sig_opt with
     | None -> ()
     | Some sig_ast ->
       let sig_t = from_ast_type sig_ast in
       unify placeholder sig_t);
    List.iter (fun clause ->
      let t = infer !env (clause_to_expr clause) in
      unify placeholder t
    ) clauses;
    exit_level ();
    let scheme = generalize placeholder in
    env := extend_var !env name scheme;
    (name, scheme)
  ) groups in

  (* Phase 4.5: validate impl method bodies against their interfaces *)
  List.iter (function
    | DImpl _ as d -> check_impl !env d
    | _ -> ()
  ) prog;

  (* Phase 5: effect inference and checking *)
  infer_and_check_effects groups;

  (* Include interface methods in the returned env so callers can inspect them *)
  results @ !iface_method_schemes
