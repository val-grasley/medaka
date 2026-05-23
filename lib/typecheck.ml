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

(* ── Errors ─────────────────────────────────────── *)

type type_error =
  | TypeMismatch  of mono * mono
  | InfiniteType  of int * mono
  | UnboundVar    of ident
  | UnknownCtor   of ident
  | ArityMismatch of ident * int * int  (* name, expected, got *)
  | UnknownRecord of ident
  | UnknownField  of ident * ident      (* field, record *)
  | MissingField  of ident * ident      (* field, record *)
  | Other         of string

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
  | Other msg -> msg

(* ── Environment ────────────────────────────────── *)

type env = {
  vars         : (ident * scheme) list;
  ctors        : (ident, scheme) Hashtbl.t;   (* constructor name → scheme *)
  records      : (ident, record_info) Hashtbl.t;  (* record name → info *)
  field_owners : (ident, ident) Hashtbl.t;    (* field name → record name *)
}

let empty_env () = {
  vars         = [];
  ctors        = Hashtbl.create 16;
  records      = Hashtbl.create 8;
  field_owners = Hashtbl.create 16;
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
  (* A couple of primitives to write tests *)
  let env = extend_var env "pure"
              (let a = fresh_var () in generalize (TFun (a, a))) in
  let env = extend_var env "print"
              (let a = fresh_var () in generalize (TFun (a, t_unit))) in
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

  | EDo _stmts ->
    (* Defer monadic do-typing; for now infer as if `pure`/`bind` were generic.
       Type the body sequence with a placeholder. *)
    fail (Other "Do notation typing not yet implemented")

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

  (* Phase 1: register data and record declarations *)
  List.iter (function
    | DData (n, ps, vs) -> register_data env (n, ps, vs)
    | DRecord (n, ps, fs) -> register_record env (n, ps, fs)
    | _ -> ()
  ) prog;

  (* Phase 2: collect type sigs and fn clause groups *)
  let groups = group_fundefs prog in

  (* Phase 3: pre-bind every top-level name with a placeholder at level 1. *)
  enter_level ();
  let placeholders = List.map (fun (n, _, _) -> (n, fresh_var ())) groups in
  exit_level ();
  let env = ref (List.fold_left
                   (fun e (n, t) -> extend_var e n (monotype t))
                   env placeholders) in

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
  results
