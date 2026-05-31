(* Hindley-Milner type inference with let-polymorphism.

   Covered: ADTs (`data`), records, type aliases, newtypes, pattern matching,
   exhaustiveness/usefulness (via [Exhaust]), interfaces with named instances,
   constraint solving at call sites, `Eq a => ...` constraint syntax in signatures,
   effect tracking (`TFun` carries effect_set; separate `eff_env` post-pass reads
   it to detect higher-order effectful callbacks), `Ref a` and `<Mut>` for
   shared mutable state, multi-module type-checking.

   Uses Rémy-style level-based generalization (no env scan needed).

   Not yet covered: `@Name` impl selection at runtime; constraint inference
   (callers of a constrained function must carry the explicit constraint
   annotation).  See PLAN.md §5 for the full list. *)

open Ast

module StringSet = Set.Make(String)

(* ── Types ──────────────────────────────────────── *)

type level = int

type effect_set = string list  (* sorted, deduplicated *)

type tyvar_info =
  | Unbound of int * level
  | Link    of mono

and mono =
  | TVar   of tyvar_info ref
  | TCon   of string
  | TApp   of mono * mono
  | TFun   of mono * effect_set * mono
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
  iface_method_constraints : (ident * (ident * int list) list) list;
    (* method name → extra method-level constraints (besides the iface's own) *)
}

(* Per-impl metadata used for constraint checking at call sites. *)
type impl_entry = {
  impl_iface      : ident;
  impl_name       : ident option;
  impl_is_default : bool;
  impl_type_mono  : mono list;  (* from_ast_type of each type_arg *)
  impl_key        : string;     (* canonical Ast.impl_key from the AST type_args;
                                   matched against eval's VTypedImpl key (Phase 69) *)
  impl_requires   : (ident * mono list) list;  (* constraint: iface, type args *)
  impl_seeded     : bool;  (* True for impls registered from the prelude
                              (Prelude.program), false for user-defined.
                              Used by typecheck_module's te_impls filter
                              so prelude impls aren't leaked across modules. *)
}

(* Public type-level interface of a processed module *)
type module_type_exports = {
  te_mod_id    : string;
  te_schemes   : (ident * scheme) list;   (* public value+method schemes *)
  te_records   : (ident * record_info) list;
  te_ctors     : (ident * scheme) list;   (* public constructor schemes *)
  te_interfaces : (ident * iface_info) list;
  te_impls     : impl_entry list;
  te_aliases   : (ident * (ident list * Ast.ty)) list;  (* public type alias expansions *)
}

(* ── Effects ─────────────────────────────────────── *)

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
  | EffectEscape   of ident * effect_set * effect_set  (* fn, declared, undeclared extras *)
  | UnknownInterface   of ident               (* impl references unknown interface *)
  | ExtraMethod        of ident * ident       (* iface_name, method not in interface *)
  | MissingMethod      of ident * ident       (* iface_name, missing required method *)
  | MethodTypeMismatch of ident * mono * mono (* method_name, expected, actual *)
  | ImplArityMismatch  of ident * int * int   (* iface_name, expected params, got type_args *)
  | NoImplFound        of ident * mono list        (* iface_name, concrete type args *)
  | AmbiguousImpl      of ident * mono list        (* iface_name, concrete type args *)
  | UnknownImplName    of ident * ident * mono list (* iface_name, hint_name, concrete type args *)
  | MultipleDefaultImpls of ident * mono list      (* iface_name, concrete type args *)
  | OverlappingImpls   of ident * mono list * mono list  (* iface_name, type args of each conflicting impl *)
  | ImmutableAssignment of ident                   (* assignment to a non-mut binding *)
  | MutLetInDo          of ident                   (* let mut inside a do block (only allowed in EBlock) *)
  | MutLetRequiresBlock of ident                   (* let mut in inline `let ... in ...` position; needs a block *)
  | BindOutsideDo                                  (* `<-` used in a bare block, not a do block *)
  | AssignInDo          of ident                   (* `x = e` reassignment inside a do block *)
  | FieldAssignInDo     of ident * ident           (* `x.field = e` inside a do block *)
  | NotARecord          of ident                   (* field assignment on non-record type *)
  | RecursiveTypeAlias  of ident                   (* type alias that expands to itself *)
  | LetRecNonFunction   of ident                   (* `let rec x = ...` where RHS isn't a lambda *)
  | Other              of string

exception Type_error of type_error * Ast.loc option

let current_loc : Ast.loc option ref = ref None
let current_impl_hint : string option ref = ref None
(* Phase 69: the EMethodRef ref of the method occurrence currently being
   inferred, if any.  Set by infer's EMethodRef case and consumed once by the
   EVar method branch (which records it in method_usages so check_method_usages
   can fill it with the resolved impl key).  Mirrors current_impl_hint. *)
let current_method_ref : Ast.resolved option ref option ref = ref None

let fail e = raise (Type_error (e, !current_loc))

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
  | TApp (a, b) | TFun (a, _, b) ->
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
  | TFun (a1, _, b1), TFun (a2, _, b2) ->
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
  | TApp (a, b) | TFun (a, _, b) ->
    free_unbound (free_unbound acc a) b
  | TTuple ts ->
    List.fold_left free_unbound acc ts

let generalize t = Forall (free_unbound [] t, t)

let instantiate_raw (Forall (vars, t)) =
  let sub = List.map (fun id -> (id, fresh_var ())) vars in
  let rec walk t = match normalize t with
    | TVar v ->
      (match !v with
       | Unbound (id, _) -> (try List.assoc id sub with Not_found -> TVar v)
       | Link _ -> assert false)
    | TCon _ as t -> t
    | TApp (a, b)  -> TApp (walk a, walk b)
    | TFun (a, effs, b) -> TFun (walk a, effs, walk b)
    | TTuple ts    -> TTuple (List.map walk ts)
  in
  (sub, walk t)

let instantiate s = snd (instantiate_raw s)

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
    | TFun (a, effs, b) -> TFun (walk a, effs, walk b)
    | TTuple ts    -> TTuple (List.map walk ts)
  in
  walk t

(* Like instantiate, but also returns the fresh TVar refs corresponding to
   specific bound IDs (the interface's iface_param_ids) and the full sub
   mapping bound IDs to fresh monos. Used to track which concrete types a
   method call is dispatching on (for impl resolution) and to expand
   per-method extra constraint arguments (for constraint checking). *)
let instantiate_method (Forall (vars, t)) track_ids =
  let sub = List.map (fun id -> (id, fresh_var ())) vars in
  let rec walk t = match normalize t with
    | TVar v ->
      (match !v with
       | Unbound (id, _) -> (try List.assoc id sub with Not_found -> TVar v)
       | Link _ -> assert false)
    | TCon _ as t -> t
    | TApp (a, b)  -> TApp (walk a, walk b)
    | TFun (a, effs, b) -> TFun (walk a, effs, walk b)
    | TTuple ts    -> TTuple (List.map walk ts)
  in
  let result = walk t in
  let tracked = List.filter_map (fun id ->
    match List.assoc_opt id sub with
    | Some (TVar r) -> Some r
    | _ -> None  (* param not present in this method's scheme: skip *)
  ) track_ids in
  (result, tracked, sub)

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
        if n < 26 then String.make 1 (Char.chr (Char.code 'a' + n))
        else Printf.sprintf "t%d" n
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
    | TFun (a, effs, b) ->
      let eff_str = if effs = [] then ""
                    else Printf.sprintf "<%s> " (String.concat ", " effs) in
      let sa = go 2 a in
      let sb = go 1 b in
      let s = sa ^ " -> " ^ eff_str ^ sb in
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
  | NoImplFound (iface, args) ->
    Printf.sprintf "No impl of %s for %s"
      iface (String.concat " " (List.map pp_mono args))
  | AmbiguousImpl (iface, args) ->
    Printf.sprintf "Ambiguous: multiple impls of %s for %s — use @ImplName to disambiguate"
      iface (String.concat " " (List.map pp_mono args))
  | UnknownImplName (iface, name, args) ->
    Printf.sprintf "No impl named '%s' found for %s %s"
      name iface (String.concat " " (List.map pp_mono args))
  | MultipleDefaultImpls (iface, args) ->
    Printf.sprintf "Multiple default impls of %s for %s — at most one default allowed"
      iface (String.concat " " (List.map pp_mono args))
  | OverlappingImpls (iface, args1, args2) ->
    Printf.sprintf
      "Overlapping impls of %s: %s and %s can match the same type — mark the more general one `default impl`, or make them disjoint"
      iface
      (String.concat " " (List.map pp_mono args1))
      (String.concat " " (List.map pp_mono args2))
  | ImmutableAssignment x ->
    Printf.sprintf "Assignment to immutable binding '%s' (declare with 'let mut')" x
  | MutLetInDo x ->
    Printf.sprintf "'let mut %s' is not allowed inside a `do` block; do blocks are for monadic composition. Use a bare sequential block instead." x
  | MutLetRequiresBlock x ->
    Printf.sprintf "'let mut %s' must be inside an indented block; reassignment is only possible in sequential blocks, not inline `let ... in ...` expressions" x
  | BindOutsideDo ->
    "monadic bind `<-` is only allowed inside a `do` block; prefix this block with the `do` keyword"
  | AssignInDo x ->
    Printf.sprintf "reassignment '%s = ...' is not allowed inside a `do` block; do blocks are for monadic composition, not mutation" x
  | FieldAssignInDo (x, f) ->
    Printf.sprintf "field assignment '%s.%s = ...' is not allowed inside a `do` block; do blocks are for monadic composition, not mutation" x f
  | NotARecord x ->
    Printf.sprintf "Field assignment on '%s': type is not a record or Ref" x
  | RecursiveTypeAlias n ->
    Printf.sprintf "Recursive type alias: '%s' expands to itself" n
  | LetRecNonFunction n ->
    Printf.sprintf
      "'%s' is bound by 'let rec' but its right-hand side is not a function. Recursive value bindings must have a lambda right-hand side; cyclic data structures are not supported."
      n
  | Other msg -> msg

(* ── Environment ────────────────────────────────── *)

type env = {
  vars          : (ident * scheme) list;
  ctors         : (ident, scheme) Hashtbl.t;   (* constructor name → scheme *)
  records       : (ident, record_info) Hashtbl.t;  (* record name → info *)
  field_owners  : (ident, ident) Hashtbl.t;    (* field name → record name *)
  interfaces    : (ident, iface_info) Hashtbl.t;  (* interface name → info *)
  method_iface  : (ident, ident) Hashtbl.t;    (* method name → interface name *)
  impls         : impl_entry list ref;          (* all registered impls *)
  method_usages : (ident * ident * tyvar_info ref list * string option * Ast.resolved option ref option) list ref;  (* (method, iface, param_var_refs, impl_hint, method_occurrence_ref) *)
  fun_constraints : (ident, (ident * int list) list) Hashtbl.t;
    (* fn_name → [(iface_name, [bound_var_ids_in_scheme])] *)
  constraint_obligations : (ident * mono list) list ref;
    (* (iface_name, mono_args) accumulated at call sites, verified post-HM *)
  type_ctors    : (ident, ident list) Hashtbl.t;  (* type name → ctor names in order *)
  ctor_fields   : (ident, (ident * mono) list) Hashtbl.t;  (* named-field ctor → ordered (field, mono_ty) *)
  aliases       : (ident, ident list * Ast.ty) Hashtbl.t;  (* type alias name → (params, rhs) *)
  warnings        : string list ref;           (* accumulated warning messages *)
  mut_vars        : StringSet.t;               (* bindings declared with let mut *)
  deprecated_fns  : (ident, string) Hashtbl.t; (* name → deprecation message *)
  must_use_fns    : (ident, unit) Hashtbl.t;   (* names whose return values must be used *)
}

let empty_env () = {
  vars          = [];
  ctors         = Hashtbl.create 16;
  records       = Hashtbl.create 8;
  field_owners  = Hashtbl.create 16;
  interfaces    = Hashtbl.create 8;
  method_iface  = Hashtbl.create 16;
  impls         = ref [];
  method_usages = ref [];
  fun_constraints        = Hashtbl.create 8;
  constraint_obligations = ref [];
  type_ctors    = Hashtbl.create 8;
  ctor_fields   = Hashtbl.create 4;
  aliases       = Hashtbl.create 4;
  warnings        = ref [];
  mut_vars        = StringSet.empty;
  deprecated_fns  = Hashtbl.create 8;
  must_use_fns    = Hashtbl.create 8;
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
let t_map  k v = TApp (TApp (TCon "Map",  k), v)
let t_set  e   = TApp (TCon "Set",  e)
(* `Option` and `Result` are declared as data in stdlib/core.mdk and registered
   via the regular DData pipeline.  Their TApp-encoded type expressions are
   only needed where compiler code explicitly references those types, of which
   there are currently no callers — the helpers are kept for clarity. *)
let t_option t = TApp (TCon "Option", t)
let t_result a b = TApp (TApp (TCon "Result", a), b)
let _ = t_option
let _ = t_result

(* Expand type aliases in an AST type.  Collects the argument spine of a
   TyApp chain (e.g. `Parser Int` → head=TyCon "Parser", args=[TyCon "Int"]),
   checks whether the head is a known alias, and if so substitutes.
   Non-alias TyCon references are left untouched. *)
let rec expand_aliases ?(seen=StringSet.empty) aliases t =
  let go t = expand_aliases ~seen aliases t in
  match t with
  | Ast.TyCon n ->
    (match Hashtbl.find_opt aliases n with
     | Some ([], rhs) ->
       if StringSet.mem n seen then
         raise (Type_error (RecursiveTypeAlias n, None))
       else
         expand_aliases ~seen:(StringSet.add n seen) aliases rhs
     | _ -> t)
  | Ast.TyApp _ ->
    (* Collect the application spine *)
    let rec spine acc = function
      | Ast.TyApp (f, x) -> spine (go x :: acc) f
      | other -> (other, acc)
    in
    let (head, args) = spine [] t in
    (match head with
     | Ast.TyCon n ->
       (match Hashtbl.find_opt aliases n with
        | Some (params, rhs) when List.length params = List.length args ->
          if StringSet.mem n seen then
            raise (Type_error (RecursiveTypeAlias n, None))
          else
            let seen' = StringSet.add n seen in
            let subst = List.combine params args in
            let rec apply_subst s = function
              | Ast.TyVar v ->
                (match List.assoc_opt v s with Some t -> t | None -> Ast.TyVar v)
              | Ast.TyCon _ as c -> expand_aliases ~seen:seen' aliases c
              | Ast.TyApp (a, b) ->
                expand_aliases ~seen:seen' aliases
                  (Ast.TyApp (apply_subst s a, apply_subst s b))
              | Ast.TyFun (a, b) -> Ast.TyFun (apply_subst s a, apply_subst s b)
              | Ast.TyTuple ts   -> Ast.TyTuple (List.map (apply_subst s) ts)
              | Ast.TyEffect (es, u) -> Ast.TyEffect (es, apply_subst s u)
              | Ast.TyConstrained (cs, u) ->
                Ast.TyConstrained (
                  List.map (fun (iface, as_) -> (iface, List.map (apply_subst s) as_)) cs,
                  apply_subst s u)
            in
            expand_aliases ~seen:seen' aliases (apply_subst subst rhs)
        | _ ->
          List.fold_left (fun acc arg -> Ast.TyApp (acc, arg)) (go head) args)
     | other ->
       List.fold_left (fun acc arg -> Ast.TyApp (acc, arg)) (go other) args)
  | Ast.TyFun (a, b)    -> Ast.TyFun (go a, go b)
  | Ast.TyTuple ts       -> Ast.TyTuple (List.map go ts)
  | Ast.TyEffect (es, u) -> Ast.TyEffect (es, go u)
  | Ast.TyConstrained (cs, u) ->
    Ast.TyConstrained (
      List.map (fun (iface, as_) -> (iface, List.map go as_)) cs,
      go u)
  | Ast.TyVar _ -> t

(* Translate an AST type to a mono for use in type signatures and externs.
   Each TyVar is canonicalized per-call via a local hashtable so that the
   same name maps to the same fresh TVar within one type.
   TyEffect wrappers are stripped — effects are tracked separately.
   If ~aliases is provided, type alias names are expanded before conversion. *)
let from_ast_type ?(aliases=Hashtbl.create 0) t =
  let t = expand_aliases aliases t in
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
    | Ast.TyFun (a, b) ->
      let effs = match b with Ast.TyEffect (es, _) -> List.sort_uniq String.compare es | _ -> [] in
      let bm   = match b with Ast.TyEffect (_, t)  -> go t | t -> go t in
      TFun (go a, effs, bm)
    | Ast.TyTuple ts -> TTuple (List.map go ts)
    | Ast.TyEffect (_, t) -> go t
    | Ast.TyConstrained (_, inner) -> go inner  (* constraints handled by from_ast_type_with_constraints *)
  in
  go t

(* Like from_ast_type, but also extracts constraint annotations from TyConstrained.
   Uses a shared TVar table so constraint type-variable names (e.g. the `a` in
   `Eq a`) map to the same fresh TVar as the same name in the inner function type. *)
let from_ast_type_with_constraints ?(aliases=Hashtbl.create 0) ast_ty =
  let ast_ty = expand_aliases aliases ast_ty in
  let tbl = Hashtbl.create 4 in
  let lookup n =
    match Hashtbl.find_opt tbl n with
    | Some v -> v
    | None ->
      let v = fresh_var () in
      Hashtbl.add tbl n v;
      v
  in
  let rec go = function
    | Ast.TyCon n             -> TCon n
    | Ast.TyVar n             -> lookup n
    | Ast.TyApp (a, b)        -> TApp (go a, go b)
    | Ast.TyFun (a, b)        ->
      let effs = match b with Ast.TyEffect (es, _) -> List.sort_uniq String.compare es | _ -> [] in
      let bm   = match b with Ast.TyEffect (_, t)  -> go t | t -> go t in
      TFun (go a, effs, bm)
    | Ast.TyTuple ts          -> TTuple (List.map go ts)
    | Ast.TyEffect (_, t)     -> go t
    | Ast.TyConstrained (_, inner) -> go inner
  in
  match ast_ty with
  | Ast.TyConstrained (cs, inner) ->
    let mono = go inner in
    let constraints = List.map (fun (iface, args) -> (iface, List.map go args)) cs in
    (constraints, mono)
  | other -> ([], go other)

(* Build the initial environment with the few built-ins the prelude can't
   declare itself.  Option / Result / Ordering and their constructors come
   from stdlib/core.mdk via the regular DData pipeline; the seeds below are
   only for syntactic specials (Bool literals, List's [] / (::) sugar, and
   the synthetic __tuple__ singleton). *)
let initial_env () =
  let env = empty_env () in
  enter_level ();
  (* True/False: the lexer turns these into BOOL literals (not UPPER tokens),
     and the evaluator stores them as VBool — but exhaustiveness checking and
     a few pattern-matching paths still treat them as a closed two-ctor type. *)
  Hashtbl.replace env.ctors "True"  (monotype t_bool);
  Hashtbl.replace env.ctors "False" (monotype t_bool);
  exit_level ();
  (* type_ctors: closed types the exhaustiveness checker can enumerate.
     Int, Float, String, Char intentionally absent (open types).  Option,
     Result, Ordering are registered by the prelude's DData; we only seed
     types whose constructors aren't declared in stdlib/core.mdk. *)
  Hashtbl.replace env.type_ctors "Bool"      ["True"; "False"];
  Hashtbl.replace env.type_ctors "List"      ["Cons"; "Nil"];
  Hashtbl.replace env.type_ctors "__tuple__" ["__tuple__"];
  (* Generalize: vars are now at level 1, current_level = 0, so they get quantified *)
  Hashtbl.filter_map_inplace
    (fun _name s ->
       match s with
       | Forall (_, t) -> Some (generalize t))
    env.ctors;
  (* Primitives from the runtime registry.
     from_ast_type now populates the TFun effect slot from TyEffect return-type
     annotations, so `print : String -> <IO> Unit` gets TFun(String,["IO"],Unit). *)
  let env = List.fold_left (fun env (name, ast_ty) ->
    let scheme =
      enter_level ();
      let mono = from_ast_type ast_ty in
      exit_level ();
      generalize mono
    in
    extend_var env name scheme
  ) env Runtime.entries in
  env

(* ── Translating AST types to mono ──────────────── *)

(* Used for type sigs and explicit annotations. Each TyVar is treated as
   universally quantified at the outer level (generalized after the whole
   sig is built). *)
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
    | TFun (a, effs, b) -> TFun (walk a, effs, walk b)
    | TTuple ts    -> TTuple (List.map walk ts)
  in
  let result = walk info.rec_result in
  let fields = List.map (fun (n, t) -> (n, walk t)) info.rec_fields in
  (result, fields)

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
    let expected  = List.fold_right (fun at acc -> TFun (at, [], acc))
                      arg_types result_t in
    unify ctor_t expected;
    (result_t, bindings)
  | PAs (x, p) ->
    let (t, bindings) = type_pat env p in
    (t, (x, monotype t) :: bindings)
  | PRng (LInt _, LInt _, _)   -> (t_int,  [])
  | PRng (LChar _, LChar _, _) -> (t_char, [])
  | PRng _ -> fail (TypeMismatch (t_int, t_char))  (* only Int and Char ranges are valid *)
  | PRec (name, fields, _rest) ->
    (match Hashtbl.find_opt env.ctor_fields name with
     | Some field_monos ->
       (* Named-field constructor pattern *)
       let field_types = List.map (fun (fn, mono) ->
         let tv = fresh_var () in
         unify tv mono;
         (fn, tv)
       ) field_monos in
       let scheme =
         try Hashtbl.find env.ctors name
         with Not_found -> fail (UnknownCtor name)
       in
       let ctor_t = instantiate scheme in
       let result_t = ref ctor_t in
       List.iter (fun (_, ftype) ->
         let ret = fresh_var () in
         unify !result_t (TFun (ftype, [], ret));
         result_t := ret
       ) field_types;
       let bindings =
         List.concat_map (fun (fname, pat_opt) ->
           let field_t =
             match List.assoc_opt fname field_types with
             | Some t -> t
             | None   -> fail (UnknownField (fname, name))
           in
           match pat_opt with
           | None ->
             let v = fresh_var () in
             unify v field_t;
             [(fname, monotype v)]
           | Some q ->
             let (pt, bs) = type_pat env q in
             unify pt field_t;
             bs
         ) fields
       in
       (!result_t, bindings)
     | None ->
       let info =
         try Hashtbl.find env.records name
         with Not_found -> fail (UnknownRecord name)
       in
       let (result_t, field_types) = instantiate_record info in
       let bindings =
         List.concat_map (fun (fname, pat_opt) ->
           let field_t =
             match List.assoc_opt fname field_types with
             | Some t -> t
             | None   -> fail (UnknownField (fname, name))
           in
           match pat_opt with
           | None ->
             let v = fresh_var () in
             unify v field_t;
             [(fname, monotype v)]
           | Some q ->
             let (pt, bs) = type_pat env q in
             unify pt field_t;
             bs
         ) fields
       in
       (result_t, bindings))

(* ── Expression typing ──────────────────────────── *)

(* Build a clause's expression form: nested lambdas if there are args. Used
   by both the top-level multi-clause grouping below and the ELetGroup
   inference for multi-clause `where` bindings. *)
let clause_to_expr (pats, body) =
  if pats = [] then body
  else List.fold_right (fun p acc -> ELam ([p], acc)) pats body

let rec infer env = function
  | ELoc (l, e) ->
    current_loc := Some l;
    infer env e

  (* Phase 69: resolved method occurrence.  Stash the ref so the EVar method
     branch records it in method_usages; check_method_usages fills it with the
     resolved impl key once the call site's type args are ground. *)
  | EMethodRef (r, x) -> current_method_ref := Some r; infer env (EVar x)

  | ELit l -> type_lit l

  | EVar x ->
    if String.length x > 0 && x.[0] = '@' then
      t_unit
    else begin
      (match Hashtbl.find_opt env.deprecated_fns x with
       | Some msg ->
         let loc_str = match !current_loc with
           | Some l -> Printf.sprintf "%s:%d: " l.file l.line
           | None -> ""
         in
         env.warnings := (loc_str ^ "'" ^ x ^ "' is deprecated: " ^ msg) :: !(env.warnings)
       | None -> ());
      let scheme =
        try Hashtbl.find env.ctors x
        with Not_found -> lookup_var env x
      in
      match Hashtbl.find_opt env.method_iface x with
      | Some iface_name ->
        let info = Hashtbl.find env.interfaces iface_name in
        let (t, param_vars, sub) = instantiate_method scheme info.iface_param_ids in
        let hint = !current_impl_hint in
        current_impl_hint := None;
        let mref = !current_method_ref in
        current_method_ref := None;
        env.method_usages := (x, iface_name, param_vars, hint, mref) :: !(env.method_usages);
        (* Emit obligations for any extra method-level constraints
           (e.g. the `Monoid m` in `foldMap : Monoid m => (a -> m) -> t a -> m`). *)
        (match List.assoc_opt x info.iface_method_constraints with
         | None -> ()
         | Some cs ->
           List.iter (fun (iface, var_ids) ->
             let args = List.filter_map (fun id -> List.assoc_opt id sub) var_ids in
             if args <> [] then
               env.constraint_obligations := (iface, args) :: !(env.constraint_obligations)
           ) cs);
        t
      | None ->
        current_method_ref := None;  (* not a method occurrence; don't leak the ref *)
        let (sub, mono) = instantiate_raw scheme in
        (match Hashtbl.find_opt env.fun_constraints x with
         | None -> ()
         | Some constraints ->
           List.iter (fun (iface, var_ids) ->
             let args = List.filter_map (fun id -> List.assoc_opt id sub) var_ids in
             if args <> [] then
               env.constraint_obligations := (iface, args) :: !(env.constraint_obligations)
           ) constraints);
        mono
    end

  | EApp (f, EVar hint) when String.length hint > 0 && hint.[0] = '@' ->
    (* @ImplName is a disambiguation hint — set it as a pending impl name so
       the next method usage records it, then drop the arg from f's type. *)
    current_impl_hint := Some (String.sub hint 1 (String.length hint - 1));
    let t = infer env f in
    current_impl_hint := None;   (* clear if f wasn't a method call *)
    t
  | EApp (f, ELoc (_, EVar hint)) when String.length hint > 0 && hint.[0] = '@' ->
    current_impl_hint := Some (String.sub hint 1 (String.length hint - 1));
    let t = infer env f in
    current_impl_hint := None;
    t

  | EApp (f, x) ->
    let tf = infer env f in
    let tx = infer env x in
    let tr = fresh_var () in
    unify tf (TFun (tx, [], tr));
    tr

  | ELam (pats, body) ->
    let typed_pats = List.map (type_pat env) pats in
    let pat_types  = List.map fst typed_pats in
    let bindings   = List.concat_map snd typed_pats in
    let env' = extend_vars env bindings in
    let tb = infer env' body in
    List.fold_right (fun pt acc -> TFun (pt, [], acc)) pat_types tb

  | ELet (mut, is_fun, pat, e1, e2) ->
    (if mut then
       let name = (match pat with PVar x -> x | _ -> "_") in
       raise (Type_error (MutLetRequiresBlock name, !current_loc)));
    (match is_fun, pat with
     | true, PVar x ->
       (* Self-recursive: pre-bind x with a monomorphic placeholder so the
          RHS can reference x; generalize after unification. *)
       enter_level ();
       let placeholder = fresh_var () in
       let env_self = extend_var env x (monotype placeholder) in
       let t1 = infer env_self e1 in
       unify placeholder t1;
       exit_level ();
       let s = generalize t1 in
       let env' = extend_var env x s in
       let env' = if mut then { env' with mut_vars = StringSet.add x env'.mut_vars } else env' in
       infer env' e2
     | _ ->
       enter_level ();
       let t1 = infer env e1 in
       exit_level ();
       (match pat with
        | PVar x ->
          let s = generalize t1 in
          let env' = extend_var env x s in
          let env' = if mut then { env' with mut_vars = StringSet.add x env'.mut_vars } else env' in
          infer env' e2
        | _ ->
          (* Non-trivial pattern: no generalization (value restriction-like) *)
          let tp, bindings = type_pat env pat in
          unify tp t1;
          infer (extend_vars env bindings) e2))

  | ELetGroup (bindings, body) ->
    enter_level ();
    let placeholders = List.map (fun (n, _) -> (n, fresh_var ())) bindings in
    let env' = List.fold_left
      (fun e (n, t) -> extend_var e n (monotype t)) env placeholders in
    List.iter (fun (n, clauses) ->
      let ph = List.assoc n placeholders in
      List.iter (fun clause ->
        unify (infer env' (clause_to_expr clause)) ph
      ) clauses
    ) bindings;
    exit_level ();
    let env'' = List.fold_left
      (fun e (n, t) -> extend_var e n (generalize t)) env placeholders in
    infer env'' body

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
    List.iter (fun (pat, guards, body) ->
      let tp, bindings = type_pat env pat in
      unify tp tsc;
      let env' = extend_vars env bindings in
      (* Thread guard qualifiers left-to-right; pattern binds extend the env
         for later qualifiers and the body. *)
      let env_body = List.fold_left (fun env_cur q ->
        match q with
        | GBool g -> unify (infer env_cur g) t_bool; env_cur
        | GBind (p, e) ->
          let te = infer env_cur e in
          let tp', binds = type_pat env_cur p in
          unify tp' te;
          extend_vars env_cur binds
      ) env' guards in
      unify (infer env_body body) result
    ) arms;
    (* Phase 6: exhaustiveness + redundancy checking *)
    let rec follow t = match t with
      | TVar v -> (match !v with Link t' -> follow t' | _ -> t)
      | _ -> t
    in
    let rec type_head t = match t with
      | TCon n     -> Some n
      | TApp (f,_) -> type_head f
      | TVar v     -> (match !v with Link t' -> type_head t' | _ -> None)
      | _          -> None
    in
    let col0_type =
      match type_head tsc with
      | Some _ as t -> t
      | None ->
        (* Tuples have no TCon head; treat them as a synthetic singleton type. *)
        (match follow tsc with TTuple _ -> Some "__tuple__" | _ -> None)
    in
    let get_ctors tname = Hashtbl.find_opt env.type_ctors tname in
    let get_arity c =
      if c = "__tuple__" then
        (match follow tsc with TTuple ts -> List.length ts | _ -> 0)
      else
        match Hashtbl.find_opt env.ctors c with
        | None -> (match c with "Cons" -> 2 | _ -> 0)
        | Some (Forall (_, t)) ->
          let rec count = function
            | TFun (_, _, r) -> 1 + count r
            | TVar v -> (match !v with Link t' -> count t' | _ -> 0)
            | _ -> 0
          in
          count t
    in
    (* get_ctor_type: given a constructor name, return its parent type name.
       Used by exhaust.ml to infer the type of a column when it is unknown. *)
    let get_ctor_type c =
      if c = "__tuple__" then Some "__tuple__"
      else
        match Hashtbl.find_opt env.ctors c with
        | None ->
          (match c with
           | "Cons" | "Nil"   -> Some "List"
           | "True" | "False" -> Some "Bool"
           | "Unit"           -> Some "Unit"
           | _                -> None)
        | Some (Forall (_, t)) ->
          let rec result_type = function
            | TFun (_, _, r) -> result_type r
            | TApp (f, _) -> result_type f
            | TCon n      -> Some n
            | TVar v      -> (match !v with Link t' -> result_type t' | _ -> None)
            | _           -> None
          in
          result_type t
    in
    Exhaust.check_match
      ~get_ctors ~get_arity ~get_ctor_type
      ~warnings:env.warnings
      ~col0_type
      ~match_loc:!current_loc
      (List.map (fun (p, gs, _) -> (p, gs <> [])) arms);
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

  | EMapLit (_, kvs) ->
    let kt = fresh_var () and vt = fresh_var () in
    List.iter (fun (k, v) ->
      unify (infer env k) kt;
      unify (infer env v) vt
    ) kvs;
    t_map kt vt

  | ESetLit (_, es) ->
    let et = fresh_var () in
    List.iter (fun e -> unify (infer env e) et) es;
    t_set et

  | EStringInterp parts ->
    List.iter (function
      | InterpStr _  -> ()
      | InterpExpr e -> unify (infer env e) (TCon "String")
    ) parts;
    TCon "String"

  | EAnnot (e, ast_t) ->
    let te = infer env e in
    let ta = from_ast_type ~aliases:env.aliases ast_t in
    unify te ta;
    te

  | EInfix (op, l, r) ->
    let tf = instantiate (lookup_var env op) in
    let tl = infer env l in
    let tr = infer env r in
    let result = fresh_var () in
    unify tf (TFun (tl, [], TFun (tr, [], result)));
    result

  | EBlock stmts ->
    (* Bare sequential indented block.  No monad constraint — stmts are
       executed in order, value of the last stmt is the block's result.
       Allowed: DoLet (incl. mut), DoExpr, DoAssign, DoFieldAssign, DoLetElse.
       Forbidden: DoBind. *)
    if stmts = [] then fail (Other "Empty block");
    let rec head_fn_name = function
      | ELoc (_, e) -> head_fn_name e
      | EVar x -> Some x
      | EMethodRef (_, x) -> Some x
      | EApp (f, _) -> head_fn_name f
      | _ -> None
    in
    let rec type_block env = function
      | [] -> assert false
      | [DoBind _] -> fail BindOutsideDo
      | [DoExpr e] -> infer env e
      | [DoLet _] -> fail (Other "block cannot end with a let binding")
      | [DoAssign _] -> fail (Other "block cannot end with an assignment")
      | [DoFieldAssign _] -> fail (Other "block cannot end with a field assignment")
      | [DoLetElse _] -> fail (Other "block cannot end with a let-else binding")
      | DoBind _ :: _ -> fail BindOutsideDo
      | DoExpr e :: rest ->
        let _ = infer env e in
        (match head_fn_name e with
         | Some f when Hashtbl.mem env.must_use_fns f ->
           let loc_str = match !current_loc with
             | Some l -> Printf.sprintf "%s:%d: " l.file l.line
             | None -> ""
           in
           env.warnings := (loc_str ^ "return value of '" ^ f ^ "' is unused (marked @must_use)")
                           :: !(env.warnings)
         | _ -> ());
        type_block env rest
      | DoLet (mut, pat, e) :: rest ->
        enter_level ();
        let t1 = infer env e in
        exit_level ();
        let env' = match pat with
          | PVar x ->
            let env' = extend_var env x (generalize t1) in
            if mut then { env' with mut_vars = StringSet.add x env'.mut_vars } else env'
          | _ ->
            let tp, bindings = type_pat env pat in
            unify tp t1;
            extend_vars env bindings
        in
        type_block env' rest
      | DoAssign (x, e) :: rest ->
        let tx = instantiate (lookup_var env x) in
        let te = infer env e in
        unify tx te;
        if not (StringSet.mem x env.mut_vars) then
          fail (ImmutableAssignment x);
        type_block env rest
      | DoFieldAssign (x, field, e) :: rest ->
        if not (StringSet.mem x env.mut_vars) then
          fail (ImmutableAssignment x);
        let tx = instantiate (lookup_var env x) in
        let field_t =
          match normalize tx with
          | TApp (TCon "Ref", inner) when field = "value" -> inner
          | TCon r ->
            (match Hashtbl.find_opt env.records r with
             | None -> fail (UnknownRecord r)
             | Some info ->
               let (_result_t, field_types) = instantiate_record info in
               (match List.assoc_opt field field_types with
                | None -> fail (UnknownField (field, r))
                | Some ft -> ft))
          | TApp (TCon r, _) ->
            (match Hashtbl.find_opt env.records r with
             | None -> fail (UnknownRecord r)
             | Some info ->
               let (_result_t, field_types) = instantiate_record info in
               (match List.assoc_opt field field_types with
                | None -> fail (UnknownField (field, r))
                | Some ft -> ft))
          | _ -> fail (NotARecord x)
        in
        let te = infer env e in
        unify field_t te;
        type_block env rest
      | DoLetElse (pat, e, alt) :: rest ->
        let te = infer env e in
        let tp, bindings = type_pat env pat in
        unify tp te;
        let _ = infer env alt in
        type_block (extend_vars env bindings) rest
    in
    type_block env stmts

  | EDo (monad_tag_ref, stmts) ->
    (* Monadic do-block (introduced by the `do` keyword).  Always introduces
       a per-block monad tyvar `m`; every DoExpr and DoBind RHS must be `m a`.
       The last stmt's type determines the block result.
       Forbidden: DoLet with mut, DoAssign, DoFieldAssign. *)
    if stmts = [] then fail (Other "Empty do block");
    let m = fresh_var () in
    let unify_monadic te =
      let inner = fresh_var () in
      unify te (TApp (m, inner));
      inner
    in
    let rec head_fn_name = function
      | ELoc (_, e) -> head_fn_name e
      | EVar x -> Some x
      | EMethodRef (_, x) -> Some x
      | EApp (f, _) -> head_fn_name f
      | _ -> None
    in
    let rec type_stmts env = function
      | [] -> assert false
      | [DoExpr e] ->
        let te = infer env e in
        let _ = unify_monadic te in
        te
      | [DoBind (pat, e)] ->
        (* Trailing bind discards the bound variable; result is m Unit *)
        let te = infer env e in
        let inner = unify_monadic te in
        let tp, _ = type_pat env pat in
        unify tp inner;
        TApp (m, t_unit)
      | [DoLet _] ->
        fail (Other "do block cannot end with a let binding")
      | [DoAssign _] ->
        fail (Other "do block cannot end with an assignment")
      | [DoFieldAssign _] ->
        fail (Other "do block cannot end with a field assignment")
      | [DoLetElse _] ->
        fail (Other "do block cannot end with a let-else binding")
      | DoExpr e :: rest ->
        let te = infer env e in
        let _ = unify_monadic te in
        (match head_fn_name e with
         | Some f when Hashtbl.mem env.must_use_fns f ->
           let loc_str = match !current_loc with
             | Some l -> Printf.sprintf "%s:%d: " l.file l.line
             | None -> ""
           in
           env.warnings := (loc_str ^ "return value of '" ^ f ^ "' is unused (marked @must_use)")
                           :: !(env.warnings)
         | _ -> ());
        type_stmts env rest
      | DoBind (pat, e) :: rest ->
        let te = infer env e in
        let inner = unify_monadic te in
        let tp, bindings = type_pat env pat in
        unify tp inner;
        type_stmts (extend_vars env bindings) rest
      | DoLet (mut, pat, e) :: rest ->
        if mut then begin
          let name = (match pat with PVar x -> x | _ -> "_") in
          fail (MutLetInDo name)
        end;
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
      | DoAssign (x, _) :: _ ->
        fail (AssignInDo x)
      | DoFieldAssign (x, field, _) :: _ ->
        fail (FieldAssignInDo (x, field))
      | DoLetElse (pat, e, alt) :: rest ->
        let te = infer env e in
        let tp, bindings = type_pat env pat in
        unify tp te;
        let _ = infer env alt in  (* no divergence check in v1 *)
        type_stmts (extend_vars env bindings) rest
    in
    let result = type_stmts env stmts in
    monad_tag_ref := (match normalize m with
      | TApp (TCon tname, _) -> Some tname
      | TCon tname           -> Some tname
      | _                    -> None);
    result

  | ERecordCreate (name, provided) ->
    (match Hashtbl.find_opt env.ctor_fields name with
     | Some field_monos ->
       (* Named-field constructor: instantiate fresh copies of field mono types *)
       let field_types = List.map (fun (fn, mono) ->
         let tv = fresh_var () in
         unify tv mono;
         (fn, tv)
       ) field_monos in
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
       (* Return the constructor's result type via its scheme *)
       let scheme =
         try Hashtbl.find env.ctors name
         with Not_found -> fail (UnknownCtor name)
       in
       let ctor_t = instantiate scheme in
       (* ctor_t is TFun (arg1, [], TFun (arg2, [], ..., result_t)) — strip args *)
       let result_t = ref ctor_t in
       List.iter (fun (_, ftype) ->
         let ret = fresh_var () in
         unify !result_t (TFun (ftype, [], ret));
         result_t := ret
       ) field_types;
       !result_t
     | None ->
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
       result_t)

  | EFieldAccess (e, field) ->
    let te = infer env e in
    (* Special case: (Ref a).value → a *)
    (match normalize te, field with
     | TApp (TCon "Ref", inner), "value" -> inner
     | _ ->
       let record_name =
         try Hashtbl.find env.field_owners field
         with Not_found -> fail (UnknownField (field, "<unknown>"))
       in
       let info = Hashtbl.find env.records record_name in
       let (result_t, field_types) = instantiate_record info in
       unify te result_t;
       (try List.assoc field field_types
        with Not_found -> assert false)  (* field_owners guarantees this exists *)
    )

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

  | EListComp _ -> assert false (* eliminated by desugar_list_comps *)

  | EQuestion _ -> assert false (* eliminated by desugar_questions; misplaced uses caught by resolve *)

  | ERangeList (lo, hi, _) ->
    unify (infer env lo) t_int;
    unify (infer env hi) t_int;
    t_list t_int

  | ERangeArray (lo, hi, _) ->
    unify (infer env lo) t_int;
    unify (infer env hi) t_int;
    t_array t_int

  | ESlice (e, lo, hi, _) ->
    let te = infer env e in
    unify (infer env lo) t_int;
    unify (infer env hi) t_int;
    (* Slice preserves container type: Array a, List a, or String *)
    let elem = fresh_var () in
    (try unify te (t_array elem); te
     with _ ->
       try unify te (t_list elem); te
       with _ ->
         unify te t_string; te)

and binop_type env op l r =
  let tl = infer env l in
  let tr = infer env r in
  (* Record a usage of `method` (an entry from Builtins.operator_iface) at the
     type variable [r], so check_method_usages can verify that a matching impl
     exists once [r] is grounded.  Returns [r] wrapped back as a TVar's ref. *)
  let record_iface_usage iface_name method_name tl tr =
    let a = fresh_var () in
    let r = match a with TVar r -> r | _ -> assert false in
    unify tl a; unify tr a;
    env.method_usages := (method_name, iface_name, [r], None, None) :: !(env.method_usages);
    a
  in
  let iface_and_method_of op =
    let (_, i, m) = List.find (fun (o, _, _) -> o = op) Builtins.operator_iface in
    (i, m)
  in
  match op with
  | "+" | "-" | "*" | "/" ->
    let (i, m) = iface_and_method_of op in record_iface_usage i m tl tr
  | "==" | "!=" ->
    let _ = record_iface_usage "Eq" "eq" tl tr in
    t_bool
  | "<" | ">" | "<=" | ">=" ->
    let (i, m) = iface_and_method_of op in
    let _ = record_iface_usage i m tl tr in
    t_bool
  | "%" ->
    unify tl t_int; unify tr t_int; t_int
  | "&&" | "||" ->
    unify tl t_bool; unify tr t_bool; t_bool
  | "::" ->
    unify tr (t_list tl); tr
  | "++" ->
    let (i, m) = iface_and_method_of op in record_iface_usage i m tl tr
  | "|>" ->
    (* x |> f  :  a -> (a -> b) -> b *)
    let b = fresh_var () in
    unify tr (TFun (tl, [], b)); b
  | ">>" ->
    (* f >> g  :  (a -> b) -> (b -> c) -> (a -> c) *)
    let a = fresh_var () in
    let b = fresh_var () in
    let c = fresh_var () in
    unify tl (TFun (a, [], b)); unify tr (TFun (b, [], c)); TFun (a, [], c)
  | "<<" ->
    (* f << g  :  (b -> c) -> (a -> b) -> (a -> c) *)
    let a = fresh_var () in
    let b = fresh_var () in
    let c = fresh_var () in
    unify tl (TFun (b, [], c)); unify tr (TFun (a, [], b)); TFun (a, [], c)
  | _ ->
    fail (Other ("Unknown binop: " ^ op))

(* ── Top-level processing ───────────────────────── *)

(* Group fn defs by name, preserving first-appearance order in source.
   Order matters for type-checking — later defs can use earlier defs at
   polymorphic types only if earlier defs are processed (and generalized)
   first.

   Result: list of "letrec groups" — each group is a list of (name, sig_opt,
   clauses) that must be type-checked together as a mutual-recursion unit.
   `is_letrec` is true when the group came from `DLetGroup` (let rec ...).
   `DFunDef`s become singleton groups (is_letrec = false). *)
let group_fundefs decls
  : (bool * (string * Ast.ty option * (pat list * expr) list) list) list
  =
  let sigs = Hashtbl.create 16 in
  List.iter (fun d -> match Ast.inner_decl d with
    | DTypeSig (_, n, t) -> Hashtbl.replace sigs n t
    | _ -> ()
  ) decls;
  (* Single-fn clauses get coalesced by name, preserving source order. *)
  let single_clauses = Hashtbl.create 16 in
  let groups_in_order = ref [] in
  let push_single n =
    if not (Hashtbl.mem single_clauses n) then
      groups_in_order := `Single n :: !groups_in_order
  in
  List.iter (fun d -> match Ast.inner_decl d with
    | DFunDef (_, n, pats, body) ->
      push_single n;
      let existing = try Hashtbl.find single_clauses n with Not_found -> [] in
      Hashtbl.replace single_clauses n (existing @ [(pats, body)])
    | DLetGroup (_, bindings) ->
      let members = List.map (fun (n, clauses) ->
        let sig_opt = try Some (Hashtbl.find sigs n) with Not_found -> None in
        (n, sig_opt, clauses)
      ) bindings in
      groups_in_order := `Letrec members :: !groups_in_order
    | _ -> ()
  ) decls;
  let lookup_sig n =
    try Some (Hashtbl.find sigs n) with Not_found -> None
  in
  List.rev_map (function
    | `Single n ->
      let cs = try Hashtbl.find single_clauses n with Not_found -> [] in
      (false, [(n, lookup_sig n, cs)])
    | `Letrec members ->
      (true, members)
  ) !groups_in_order
  |> List.filter (fun (_, members) ->
    List.for_all (fun (_, _, cs) -> cs <> []) members)

(* Flatten the grouped output for callers that just want a (name, sig, clauses) list. *)
let flatten_groups groups =
  List.concat_map snd groups

(* Recognize syntactic lambdas, peeling location wrappers. *)
let rec is_syntactic_lambda = function
  | ELam _      -> true
  | ELoc (_, e) -> is_syntactic_lambda e
  | _           -> false

(* Find the first source-location annotation in an expression — used to attach
   a position to diagnostics raised outside the normal inference walk. *)
let rec first_loc = function
  | ELoc (l, _)        -> Some l
  | EApp (f, _)        -> first_loc f
  | ELam (_, body)     -> first_loc body
  | EBinOp (_, l, _)   -> first_loc l
  | EUnOp (_, e)       -> first_loc e
  | EIf (c, _, _)      -> first_loc c
  | EFieldAccess (e, _) -> first_loc e
  | EAnnot (e, _)      -> first_loc e
  | _                  -> None

(* Type-check one letrec group (a list of name/sig/clauses entries).
   Pre-bound placeholders for all names must already live in `!env_ref`.
   On a let-rec group (is_letrec = true), zero-arg clauses are required to
   have a lambda RHS — strict-evaluation rules out cyclic non-function data. *)
let process_letrec_group env_ref placeholders (is_letrec, members) =
  enter_level ();
  let cs_monos_list = List.map (fun (name, sig_opt, clauses) ->
    let placeholder = List.assoc name placeholders in
    let cs_monos =
      match sig_opt with
      | None -> []
      | Some sig_ast ->
        let (cs, sig_t) = from_ast_type_with_constraints
                            ~aliases:(!env_ref).aliases sig_ast in
        unify placeholder sig_t;
        cs
    in
    if is_letrec then
      List.iter (fun (pats, rhs) ->
        if pats = [] && not (is_syntactic_lambda rhs) then begin
          current_loc := first_loc rhs;
          fail (LetRecNonFunction name)
        end
      ) clauses;
    List.iter (fun clause ->
      let t = infer !env_ref (clause_to_expr clause) in
      unify placeholder t
    ) clauses;
    (name, cs_monos)
  ) members in
  exit_level ();
  List.map (fun (name, cs_monos) ->
    let placeholder = List.assoc name placeholders in
    let scheme = generalize placeholder in
    (match scheme with
     | Forall (bound_ids, _) when cs_monos <> [] ->
       let extract_id m = match normalize m with
         | TVar {contents = Unbound (id, _)} when List.mem id bound_ids -> Some id
         | _ -> None
       in
       let cs = List.filter_map (fun (iface, arg_monos) ->
         let ids = List.filter_map extract_id arg_monos in
         if ids <> [] then Some (iface, ids) else None
       ) cs_monos in
       if cs <> [] then
         Hashtbl.replace (!env_ref).fun_constraints name cs
     | _ -> ());
    env_ref := extend_var !env_ref name scheme;
    (name, scheme)
  ) cs_monos_list

(* Register data type constructors in env *)
let register_data ?(aliases=Hashtbl.create 0) env (name, params, variants) =
  (* Build a fresh tyvar per param.  We enter a level so the freshly created
     vars sit at level (current + 1); after exit_level the surrounding scope
     drops back to current_level and `generalize` can quantify them. *)
  enter_level ();
  let param_vars = List.map (fun p -> (p, fresh_var ())) params in
  let result_t =
    List.fold_left
      (fun acc (_, v) -> TApp (acc, v))
      (TCon name)
      param_vars
  in
  let ctor_monos = List.map (fun v ->
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
      | Ast.TyFun (a, b) ->
        let effs = match b with Ast.TyEffect (es, _) -> List.sort_uniq String.compare es | _ -> [] in
        let bm   = match b with Ast.TyEffect (_, t)  -> go t | t -> go t in
        TFun (go a, effs, bm)
      | Ast.TyTuple ts -> TTuple (List.map go ts)
      | Ast.TyEffect (_, t) -> go t
      | Ast.TyConstrained (_, inner) -> go inner
    in
    let arg_types = match v.Ast.con_payload with
      | Ast.ConPos tys    -> List.map (fun f -> go (expand_aliases aliases f)) tys
      | Ast.ConNamed flds ->
        let monos = List.map (fun f -> (f.Ast.field_name, go (expand_aliases aliases f.Ast.field_type))) flds in
        (* Register field ownership and ordered field list for pattern/construction *)
        List.iter (fun (fn, _) ->
          if Hashtbl.mem env.field_owners fn then
            fail (Other (Printf.sprintf
              "Field name collision: '%s' is already declared by another type" fn));
          Hashtbl.replace env.field_owners fn v.Ast.con_name
        ) monos;
        Hashtbl.replace env.ctor_fields v.Ast.con_name monos;
        List.map snd monos
    in
    let ctor_t =
      List.fold_right (fun a acc -> TFun (a, [], acc)) arg_types result_t
    in
    (v.Ast.con_name, ctor_t)
  ) variants in
  Hashtbl.replace env.type_ctors name (List.map (fun v -> v.con_name) variants);
  exit_level ();
  (* Generalize after dropping back to the outer level so the parameter TVars
     get quantified into the constructor schemes. *)
  List.iter (fun (cname, ct) ->
    Hashtbl.replace env.ctors cname (generalize ct)
  ) ctor_monos

(* Register a record declaration in env.  Mirrors register_data.
   Errors on field-name collision (the resolver should have caught it first,
   but we guard defensively). *)
let register_record ?(aliases=Hashtbl.create 0) env (name, params, fields) =
  enter_level ();
  let param_vars = List.map (fun p -> (p, fresh_var ())) params in
  let result_t =
    List.fold_left
      (fun acc (_, v) -> TApp (acc, v))
      (TCon name)
      param_vars
  in
  let go_ty ast_ty =
    let ast_ty = expand_aliases aliases ast_ty in
    let rec go = function
      | Ast.TyCon n ->
        (try List.assoc n param_vars with Not_found -> TCon n)
      | Ast.TyVar n ->
        (try List.assoc n param_vars with Not_found -> fresh_var ())
      | Ast.TyApp (a, b)  -> TApp (go a, go b)
      | Ast.TyFun (a, b)  ->
        let effs = match b with Ast.TyEffect (es, _) -> List.sort_uniq String.compare es | _ -> [] in
        let bm   = match b with Ast.TyEffect (_, t)  -> go t | t -> go t in
        TFun (go a, effs, bm)
      | Ast.TyTuple ts    -> TTuple (List.map go ts)
      | Ast.TyEffect (_, t) -> go t
      | Ast.TyConstrained (_, inner) -> go inner
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
    (* A genuine collision is the same field owned by a *different* record.
       Re-registering the same record (prelude prepended per-module in the
       multi-file path, plus seeded from module exports) is idempotent. *)
    (match Hashtbl.find_opt env.field_owners fname with
     | Some owner when owner <> name ->
       fail (Other (Printf.sprintf
         "Field name collision: '%s' is already declared by another record" fname))
     | _ -> ());
    Hashtbl.replace env.field_owners fname name
  ) field_monos

let register_alias env (name, params, rhs) =
  Hashtbl.replace env.aliases name (params, rhs)

(* clause_to_expr is defined above, before `infer`, so the ELetGroup case
   can reuse it for multi-clause `where` bindings. *)

(* Register an interface declaration.
   Creates fresh tvars for the type parameters at level 1, converts each
   method's AST type to mono, then generalizes — yielding a fully polymorphic
   scheme per method.  Returns the method scheme list so check_program can
   bind them in the env before typing top-level functions. *)
let register_interface ?(aliases=Hashtbl.create 0) env (iface_name, type_params, methods) =
  enter_level ();
  let param_vars = List.map (fun p -> (p, fresh_var ())) type_params in
  (* Each call to go_ty gets its own memoization table for method-level tvars.
     This ensures that occurrences of the same name within one method type
     (e.g., both `a`s in `(a -> b) -> f a -> f b`) resolve to the same TVar,
     while still being independent across different methods. *)
  let go_ty ast_ty =
    let ast_ty = expand_aliases aliases ast_ty in
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
      | Ast.TyFun (a, b)  ->
        let effs = match b with Ast.TyEffect (es, _) -> List.sort_uniq String.compare es | _ -> [] in
        let bm   = match b with Ast.TyEffect (_, t)  -> go t | t -> go t in
        TFun (go a, effs, bm)
      | Ast.TyTuple ts    -> TTuple (List.map go ts)
      | Ast.TyEffect (_, t) -> go t
      | Ast.TyConstrained (_, inner) -> go inner
    in
    (* Extract per-method extra constraints. Constraint args share TVar refs
       with the inner type via the same method_vars table, so the bound IDs
       line up after generalize. *)
    let (cs_ast, inner_ast) = match ast_ty with
      | Ast.TyConstrained (cs, inner) -> (cs, inner)
      | _ -> ([], ast_ty)
    in
    let inner_mono = go inner_ast in
    let cs_monos =
      List.map (fun (iface, args) -> (iface, List.map go args)) cs_ast
    in
    (inner_mono, cs_monos)
  in
  let method_results = List.map (fun m ->
    let (mono, cs) = go_ty m.Ast.method_type in
    (m.Ast.method_name, mono, cs)
  ) methods in
  let method_monos =
    List.map (fun (n, t, _) -> (n, t)) method_results
  in
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
  (* Type-check each default method body.  Build a temporary env that includes
     all interface methods so a default can call peer methods.
     For methods whose type was inferred (TyVar "_"), update the scheme to the
     inferred type so callers see the real type rather than a naked TVar. *)
  let method_schemes = ref method_schemes in
  (* Default bodies may call methods from previously-registered interfaces
     (e.g. Foldable.foldMap's default calls Monoid.append/empty).  Pull every
     prior method scheme out of env.interfaces so they're visible too. *)
  let prior_method_schemes () =
    Hashtbl.fold (fun mname iname acc ->
      match Hashtbl.find_opt env.interfaces iname with
      | Some info ->
        (match List.assoc_opt mname info.iface_methods with
         | Some s -> (mname, s) :: acc
         | None -> acc)
      | None -> acc
    ) env.method_iface []
  in
  let env_with_methods () =
    let with_prior =
      List.fold_right (fun (n, s) e -> extend_var e n s) (prior_method_schemes ()) env
    in
    List.fold_right (fun (n, s) e -> extend_var e n s) !method_schemes with_prior
  in
  List.iter (fun m ->
    match m.Ast.method_default with
    | None -> ()
    | Some (pats, body) ->
      let mscheme = List.assoc m.Ast.method_name !method_schemes in
      let expected_t = instantiate mscheme in
      enter_level ();
      let actual_t = infer (env_with_methods ()) (clause_to_expr (pats, body)) in
      exit_level ();
      (try unify expected_t actual_t
       with
       | Type_error (TypeMismatch (a, b), _) ->
         fail (MethodTypeMismatch (m.Ast.method_name, a, b))
       | Type_error (InfiniteType _ as e, _) -> fail e);
      (* When no explicit type annotation was given, upgrade the scheme from the
         generic placeholder to the actual inferred type. *)
      (match m.Ast.method_type with
       | Ast.TyVar "_" ->
         let inferred_scheme = generalize (normalize actual_t) in
         method_schemes := List.map (fun (n, s) ->
           if n = m.Ast.method_name then (n, inferred_scheme) else (n, s)
         ) !method_schemes
       | _ -> ())
  ) methods;
  let method_schemes = !method_schemes in
  let iface_method_constraints =
    List.filter_map (fun (name, _mono, cs) ->
      if cs = [] then None
      else begin
        let extract_id m = match normalize m with
          | TVar {contents = Unbound (id, _)} -> Some id
          | _ -> None
        in
        let cs' = List.filter_map (fun (iface, args) ->
          let ids = List.filter_map extract_id args in
          if ids <> [] then Some (iface, ids) else None
        ) cs in
        if cs' = [] then None else Some (name, cs')
      end
    ) method_results
  in
  let info = {
    iface_param_ids = param_ids;
    iface_methods   = method_schemes;
    iface_defaults  = defaults;
    iface_method_constraints;
  } in
  Hashtbl.replace env.interfaces iface_name info;
  List.iter (fun m ->
    Hashtbl.replace env.method_iface m.Ast.method_name iface_name
  ) methods;
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
    let concrete = List.map (from_ast_type ~aliases:env.aliases) type_args in
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
         with
         | Type_error (TypeMismatch (a, b), _) ->
           fail (MethodTypeMismatch (mname, a, b))
         | Type_error (InfiniteType _ as e, _) ->
           fail e)
    ) info.iface_methods;
    (* Check for extra methods that are not part of the interface *)
    List.iter (fun (n, _, _) ->
      if not (List.mem_assoc n info.iface_methods) then
        fail (ExtraMethod (iface_name, n))
    ) methods
  | _ -> ()

(* Record an impl declaration in env.impls so call-site constraint checking
   can find it.  Must run after register_interface so the interface exists. *)
let register_impl ?(seeded=false) env = function
  | DImpl { iface_name; type_args; impl_name; is_default; requires; _ } ->
    if not (Hashtbl.mem env.interfaces iface_name) then
      fail (UnknownInterface iface_name);
    let entry = {
      impl_iface      = iface_name;
      impl_name;
      impl_is_default = is_default;
      impl_type_mono  = List.map (from_ast_type ~aliases:env.aliases) type_args;
      impl_key        = Ast.impl_key ~iface:iface_name ~type_args ~name:impl_name;
      impl_requires   = List.map (fun (iface, args) ->
                          (iface, List.map (from_ast_type ~aliases:env.aliases) args)) requires;
      impl_seeded     = seeded;
    } in
    env.impls := entry :: !(env.impls)
  | _ -> ()

(* Do the head types of two impls share a common instance?  Treats every
   TVar in either impl as a unification variable (a wildcard), so the two
   overlap iff there is one substitution unifying them position-by-position.
   This catches partial overlap — `(List Int)` vs `(List a)` unify via a:=Int —
   which the old structural-string key could not.  Var sharing *within* an impl
   (e.g. `Convert a a`) is respected because the same source var is the same
   ref/id; vars from different impls have distinct ids, so they never alias. *)
let impls_overlap (xs : mono list) (ys : mono list) : bool =
  let subst : (int, mono) Hashtbl.t = Hashtbl.create 8 in
  let rec resolve t = match normalize t with
    | TVar { contents = Unbound (id, _) } as tv ->
      (match Hashtbl.find_opt subst id with Some t' -> resolve t' | None -> tv)
    | t -> t
  in
  let rec go t1 t2 = match resolve t1, resolve t2 with
    | TVar { contents = Unbound (id1, _) }, TVar { contents = Unbound (id2, _) }
      when id1 = id2 -> true
    | TVar { contents = Unbound (id, _) }, t
    | t, TVar { contents = Unbound (id, _) } -> Hashtbl.replace subst id t; true
    | TCon a, TCon b -> a = b
    | TApp (f1, a1), TApp (f2, a2) -> go f1 f2 && go a1 a2
    | TFun (a1, _, b1), TFun (a2, _, b2) -> go a1 a2 && go b1 b2
    | TTuple a, TTuple b ->
      List.length a = List.length b && List.for_all2 go a b
    | _ -> false
  in
  List.length xs = List.length ys && List.for_all2 go xs ys

(* After all impls are registered, reject incoherent impl sets at declaration
   time.  Two impls for the same interface whose head types can match the same
   concrete type (see [impls_overlap]) are a problem only when the overlap is
   *unresolvable*.  An overlap is fine when the user has a disambiguation path:

   - exactly one is a `default impl` — the explicitly-blessed fallback that a
     more specific impl may override (Phase 68, conservative policy;
     most-specific-wins is deferred to Phase 69's dispatch work);
   - at least one is a *named* impl — the user selects it with `@Name` at the
     call site (Phase 32).  (An ambiguous unhinted use is still caught lazily
     at that call site by check_method_usages.)

   The genuinely incoherent configurations, flagged here:
   - two overlapping `default` impls — ambiguous fallback (MultipleDefaultImpls);
   - two overlapping *anonymous, non-default* impls — no way to ever pick one
     (OverlappingImpls).  This is the accidental duplicate / partial-overlap
     case the stdlib's anonymous impls are prone to.

   Seeded (prelude) impls are excluded: user impls are *meant* to overlap and
   override them (Phase 45.9), and the same prelude impl can appear more than
   once via multi-module imports. *)
let check_coherence env =
  let user_impls =
    List.filter (fun e -> not e.impl_seeded) !(env.impls) in
  let rec pairs = function
    | [] | [_] -> ()
    | e1 :: rest ->
      List.iter (fun e2 ->
        if e1.impl_iface = e2.impl_iface
           && impls_overlap e1.impl_type_mono e2.impl_type_mono
        then match e1.impl_is_default, e2.impl_is_default with
          | true, true ->
            fail (MultipleDefaultImpls (e1.impl_iface, e1.impl_type_mono))
          | false, false when e1.impl_name = None && e2.impl_name = None ->
            fail (OverlappingImpls
                    (e1.impl_iface, e1.impl_type_mono, e2.impl_type_mono))
          | _ -> ()  (* exactly one default, or a named impl disambiguates *)
      ) rest;
      pairs rest
  in
  pairs user_impls

(* Push hardcoded impl_entry records for primitive types satisfying Num, Ord,
   and Semigroup.  These have no AST counterpart (so they don't go through
   check_impl) and exist only so operator constraints — e.g. `Num Int` raised
   by `1 + 2` — find a matching entry in env.impls.  The interfaces themselves
   are declared by the prelude (stdlib/core.mdk); we just supply the ground
   instances the evaluator handles via OCaml-side primitive operations. *)
(* ── Constraint checking ─────────────────────────── *)

(* One-directional structural matching: pattern (from impl type_args) may
   contain unbound TVars that act as wildcards; concrete must be fully resolved. *)
let rec mono_matches ~pattern ~concrete =
  match normalize pattern, normalize concrete with
  | TVar _, _ -> true
  | TCon a, TCon b -> a = b
  | TApp (f1, a1), TApp (f2, a2) ->
    mono_matches ~pattern:f1 ~concrete:f2 &&
    mono_matches ~pattern:a1 ~concrete:a2
  | TFun (a1, _, b1), TFun (a2, _, b2) ->
    mono_matches ~pattern:a1 ~concrete:a2 &&
    mono_matches ~pattern:b1 ~concrete:b2
  | TTuple ps, TTuple cs when List.length ps = List.length cs ->
    List.for_all2 (fun p c -> mono_matches ~pattern:p ~concrete:c) ps cs
  | _ -> false

(* After HM inference, check every recorded method call site against the impl
   registry.  Skips usages where types are still polymorphic or where the method
   scheme doesn't mention all interface params (uncommon). *)
let check_method_usages env =
  let n_iface_params iface_name =
    List.length (Hashtbl.find env.interfaces iface_name).iface_param_ids
  in
  let rec is_concrete = function
    | TVar v -> (match !v with Unbound _ -> false | Link t -> is_concrete t)
    | TCon _ -> true
    | TApp (a, b) | TFun (a, _, b) -> is_concrete a && is_concrete b
    | TTuple ts -> List.for_all is_concrete ts
  in
  List.iter (fun (_method_name, iface_name, param_vars, hint_opt, occ_ref) ->
    let n = n_iface_params iface_name in
    (* Phase 69: stamp the resolved impl's canonical key onto this method
       occurrence (if it carries an EMethodRef) so eval routes return-position
       / multi-param dispatch to the impl the checker actually picked. *)
    let resolved_to entry =
      match occ_ref with
      | Some cell ->
        cell := Some { Ast.res_iface = iface_name; res_key = entry.impl_key }
      | None -> ()
    in
    if n = 0 || List.length param_vars <> n then ()
    else begin
      let concrete_args = List.map (fun r -> normalize (TVar r)) param_vars in
      if not (List.for_all is_concrete concrete_args) then ()
      else begin
        let matching = List.filter (fun e ->
          e.impl_iface = iface_name &&
          List.length e.impl_type_mono = n &&
          List.for_all2
            (fun p c -> mono_matches ~pattern:p ~concrete:c)
            e.impl_type_mono concrete_args
        ) !(env.impls) in
        (* If any user-defined impls match, drop the seeded built-in
           impls so the user can override built-in primitives without
           an ambiguity error.  (Phase 45.9.) *)
        let matching =
          if List.exists (fun e -> not e.impl_seeded) matching
          then List.filter (fun e -> not e.impl_seeded) matching
          else matching
        in
        if matching = [] then fail (NoImplFound (iface_name, concrete_args))
        else match hint_opt with
        | None ->
          (match matching with
          | [e] -> resolved_to e
          | entries ->
            let defaults = List.filter (fun e -> e.impl_is_default) entries in
            (match defaults with
             | [e] -> resolved_to e
             | _ -> fail (AmbiguousImpl (iface_name, concrete_args))))
        | Some name ->
          let named = List.filter (fun e -> e.impl_name = Some name) matching in
          (match named with
          | [] -> fail (UnknownImplName (iface_name, name, concrete_args))
          | [e] -> resolved_to e
          | _ -> fail (AmbiguousImpl (iface_name, concrete_args)))
      end
    end
  ) !(env.method_usages)

(* Verify that every constraint obligation emitted at call sites has a
   matching impl.  Skips obligations where the concrete type is still a
   polymorphic TVar — those are correctly left unchecked until a concrete
   call site grounds the type. *)
let check_constraint_obligations env =
  let rec is_concrete = function
    | TVar v -> (match !v with Unbound _ -> false | Link t -> is_concrete t)
    | TCon _ -> true
    | TApp (a, b) | TFun (a, _, b) -> is_concrete a && is_concrete b
    | TTuple ts -> List.for_all is_concrete ts
  in
  List.iter (fun (iface_name, mono_args) ->
    let concrete = List.map normalize mono_args in
    if not (List.for_all is_concrete concrete) then ()
    else begin
      let matching = List.filter (fun e ->
        e.impl_iface = iface_name &&
        List.length e.impl_type_mono = List.length concrete &&
        List.for_all2
          (fun p c -> mono_matches ~pattern:p ~concrete:c)
          e.impl_type_mono concrete
      ) !(env.impls) in
      (* Same Phase 45.9 preference: user impls trump seeded built-ins. *)
      let matching =
        if List.exists (fun e -> not e.impl_seeded) matching
        then List.filter (fun e -> not e.impl_seeded) matching
        else matching
      in
      if matching = [] then fail (NoImplFound (iface_name, concrete))
    end
  ) !(env.constraint_obligations)

(* ── Effect inference ────────────────────────────── *)

let effect_union a b = List.sort_uniq String.compare (a @ b)

(* Extract the declared effect set from an AST type signature.
   Follows TyFun arrows right-most; the first TyEffect on the return side
   is the function's declared effect.  `String -> <IO> Unit` → ["IO"]. *)
let rec declared_effects : Ast.ty -> effect_set = function
  | Ast.TyFun (_, ret) -> declared_effects ret
  | Ast.TyEffect (effs, _) -> List.sort_uniq String.compare effs
  (* A constraint wrapper around the signature is transparent for the
     purposes of effect detection — `Ord a => Array a -> <Mut> Unit`
     still performs <Mut>. *)
  | Ast.TyConstrained (_, t) -> declared_effects t
  | _ -> []

(* Compute the effect set that evaluating expression `e` produces.
   Direct calls (EApp, |>) contribute the callee's known effect set.
   Lambda bodies propagate their effects conservatively (lambdas may be called).
   Composition (>>, <<) includes effects of both composed functions.
   `scheme_env` is the HM-inferred scheme list; it lets us read the effect_set
   embedded in TFun types so that passing an effectful function as an argument
   to a HOF propagates those effects to the call site.
   `bound` tracks names locally bound by lambdas / let / match / do, so we
   don't confuse a local parameter with a global function of the same name. *)
let expr_effects
    (eff_env    : (string, effect_set) Hashtbl.t)
    (scheme_env : (ident * scheme) list)
    (e : expr) : effect_set =
  let call name = try Hashtbl.find eff_env name with Not_found -> [] in
  let pat_names p = Resolve.pat_bindings p in
  let add_pats ps bound =
    List.fold_left (fun s p ->
      List.fold_left (fun s n -> StringSet.add n s) s (pat_names p)
    ) bound ps
  in
  let rec go (bound : StringSet.t) e : effect_set =
    let sub e = go bound e in
    (* Effects of a named function when used as a value (not yet called).
       Skip locally-bound names — a parameter `p` is not the global `p`. *)
    let fn_effects_of n =
      if StringSet.mem n bound then []
      else
        let from_scheme = match List.assoc_opt n scheme_env with
          | Some (Forall (_, t)) ->
            (match normalize t with
             | TFun (_, effs, _) -> effs
             | _ -> [])
          | None -> []
        in
        let from_eff = try Hashtbl.find eff_env n with Not_found -> [] in
        effect_union from_scheme from_eff
    in
    (* Effects from calling `e` as a function — if it's a bare name we can look
       it up directly; otherwise fall back to the expression's own effects.
       Locally-bound names contribute nothing (their effects are unknown here). *)
    let rec call_effs = function
      | EVar n -> if StringSet.mem n bound then [] else call n
      | EMethodRef (_, n) -> if StringSet.mem n bound then [] else call n
      | ELoc (_, e) -> call_effs e
      | e -> sub e
    in
    match e with
    | ELit _ | EVar _ | EMethodRef _ -> []
    | EApp (f, x) ->
      (* If the argument is a named effectful function, those effects propagate:
         the HOF may call it, so we conservatively include them at the call site. *)
      let x_fn_effs = match x with
        | EVar n | ELoc (_, EVar n) -> fn_effects_of n
        | _ -> []
      in
      effect_union (call_effs f) (effect_union (sub f) (effect_union (sub x) x_fn_effs))
    | ELam (pats, body) ->
      go (add_pats pats bound) body  (* conservative: include body effects *)
    | ELet (_, _, pat, e1, e2) ->
      effect_union (sub e1) (go (add_pats [pat] bound) e2)
    | ELetGroup (bs, e2) ->
      let bound' = List.fold_left (fun s (n, _) -> StringSet.add n s) bound bs in
      List.fold_left (fun a (_, clauses) ->
        List.fold_left (fun acc (pats, body) ->
          effect_union acc (go (add_pats pats bound') body)
        ) a clauses
      ) (go bound' e2) bs
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
        (fun acc (pat, guards, body) ->
          let bound0 = add_pats [pat] bound in
          let (bound', ge) = List.fold_left (fun (b, eff) q ->
            match q with
            | GBool g      -> (b, effect_union eff (go b g))
            | GBind (p, e) -> (add_pats [p] b, effect_union eff (go b e)))
            (bound0, []) guards in
          effect_union acc (effect_union ge (go bound' body)))
        (sub sc) arms
    | EBlock stmts | EDo (_, stmts) ->
      let _, effs = List.fold_left (fun (b, acc) s ->
        let (b', e) = do_stmt_effects b s in
        (b', effect_union acc e)
      ) (bound, []) stmts in
      effs
    | EFieldAccess (e, _)      -> sub e
    | ERecordCreate (_, fs)    -> List.fold_left (fun a (_, v) -> effect_union a (sub v)) [] fs
    | ERecordUpdate (e, fs)    -> List.fold_left (fun a (_, v) -> effect_union a (sub v)) (sub e) fs
    | EArrayLit es | EListLit es | ESetLit (_, es) ->
      List.fold_left (fun a e -> effect_union a (sub e)) [] es
    | EMapLit (_, kvs) ->
      List.fold_left (fun a (k, v) -> effect_union a (effect_union (sub k) (sub v))) [] kvs
    | EStringInterp parts ->
      List.fold_left (fun a -> function
        | InterpStr _  -> a
        | InterpExpr e -> effect_union a (sub e)
      ) [] parts
    | ETuple es               -> List.fold_left (fun a e -> effect_union a (sub e)) [] es
    | EIndex (e, i)           -> effect_union (sub e) (sub i)
    | ERangeList (lo, hi, _)  -> effect_union (sub lo) (sub hi)
    | ERangeArray (lo, hi, _) -> effect_union (sub lo) (sub hi)
    | ESlice (e, lo, hi, _)   -> effect_union (sub e) (effect_union (sub lo) (sub hi))
    | EAnnot (e, _)           -> sub e
    | EInfix (_, l, r)        -> effect_union (sub l) (sub r)
    | ELoc (_, e)             -> sub e
    | EListComp _             -> assert false (* eliminated by desugar_list_comps *)
    | EQuestion _             -> assert false (* eliminated by desugar_questions *)

  and do_stmt_effects (bound : StringSet.t) = function
    | DoExpr e             -> (bound, go bound e)
    | DoBind (pat, e)      -> (add_pats [pat] bound, go bound e)
    | DoLet (_, pat, e)    -> (add_pats [pat] bound, go bound e)
    | DoAssign (_, e)         -> (bound, effect_union ["Mut"] (go bound e))
    | DoFieldAssign (_, _, e) -> (bound, effect_union ["Mut"] (go bound e))
    | DoLetElse (pat, e, alt) -> (add_pats [pat] bound, effect_union (go bound e) (go bound alt))
  in
  go StringSet.empty e

(* Process each function group in declaration order:
     1. Infer its effect set (union of all clause bodies).
     2. Store it in eff_env so later definitions see it.
     3. Check against the declared signature; raise Type_error on violation.

   Purity rule: a function with NO effect annotation must infer the empty set.
   Annotation rule: declared effects must be a superset of inferred effects. *)
let infer_and_check_effects ~extern_decls ~scheme_env groups =
  let eff_env = Hashtbl.create 16 in
  (* Seed eff_env from runtime registry entries *)
  List.iter (fun (name, ast_ty) ->
    let effs = declared_effects ast_ty in
    if effs <> [] then Hashtbl.add eff_env name effs
  ) Runtime.entries;
  (* Also seed from user-written extern declarations in the source program *)
  List.iter (fun (name, ast_ty) ->
    let effs = declared_effects ast_ty in
    if effs <> [] then Hashtbl.replace eff_env name effs
  ) extern_decls;
  List.iter (fun (name, sig_opt, clauses) ->
    let inferred =
      List.fold_left
        (fun acc clause ->
          effect_union acc (expr_effects eff_env scheme_env (clause_to_expr clause)))
        [] clauses
    in
    Hashtbl.replace eff_env name inferred;
    (match sig_opt with
     | None -> ()
     | Some sig_ty ->
       let decl = declared_effects sig_ty in
       let extras = List.filter (fun e -> not (List.mem e decl)) inferred in
       if extras <> [] then fail (EffectEscape (name, decl, extras)))
  ) groups

(* Register DAttrib attribute metadata (deprecated_fns, must_use_fns) into env. *)
let register_attrs env decls =
  let decl_name d = match d with
    | DFunDef (_, n, _, _) -> Some n
    | DExtern  (_, n, _)   -> Some n
    (* DLetGroup binds multiple names; @attrs on a let-rec apply to the first
       member, mirroring how multi-clause attrs work. *)
    | DLetGroup (_, ((n, _) :: _)) -> Some n
    | _                    -> None
  in
  List.iter (function
    | DAttrib (attrs, inner) ->
      (match decl_name (Ast.inner_decl inner) with
       | None -> ()
       | Some name ->
         List.iter (function
           | AttrDeprecated msg -> Hashtbl.replace env.deprecated_fns name msg
           | AttrMustUse        -> Hashtbl.replace env.must_use_fns name ()
           | AttrInline         -> ()
         ) attrs)
    | _ -> ()
  ) decls

(* Type-check a whole program; return a (name → scheme) list.

   Strategy: pre-bind every top-level name with an unbound placeholder at
   level 1, then process each group ONE AT A TIME — typing its body at
   level 1, exiting to level 0, generalizing, and replacing the env binding
   with the generalized scheme before moving to the next group.

   This lets ungrouped definitions become polymorphic between uses (so
   `id x = x` then `a = id 5` then `b = id "hi"` works), while mutual
   recursion still type-checks because the forward reference unifies with
   the (still-monomorphic) placeholder. *)
(* If the program redefines a unique pair of core.mdk declarations, assume
   it IS core.mdk being type-checked standalone and skip prelude prepending to
   avoid duplicate declarations.  The pair (data Ordering + interface Foldable)
   is specific enough that user code would not normally trigger it. *)
let program_is_core (prog : program) : bool =
  let has_ordering = List.exists (function
    | DData (_, "Ordering", _, _, _) -> true | _ -> false) prog in
  let has_foldable = List.exists (function
    | DInterface { iface_name = "Foldable"; _ } -> true | _ -> false) prog in
  has_ordering && has_foldable

let check_program (prog : program) : (ident * scheme) list * string list =
  reset_state ();
  current_loc := None;
  current_impl_hint := None;
  let env = initial_env () in

  (* Prepend core stdlib so its data types, interfaces, and impls are in scope
     for all user code.  Prelude declarations are processed through the same
     Phase 1–5 pipeline as user code.  Impl entries for primitive types
     (Num/Ord/Eq on Int/Float/etc.) come from core.mdk declarations.
     Skip prepending when type-checking core.mdk itself (would duplicate). *)
  let user_prog = prog in
  let prog = if program_is_core prog then prog else Prelude.program @ prog in

  register_attrs env prog;

  (* Phase 1: register data, record, interface, impl, and extern declarations *)
  (* First sub-pass: collect all type aliases so they are available for expansion *)
  List.iter (fun d -> match Ast.inner_decl d with
    | DTypeAlias (_, n, ps, rhs) -> register_alias env (n, ps, rhs)
    | _ -> ()
  ) prog;
  let iface_method_schemes = ref [] in
  let extern_schemes = ref [] in
  List.iter (fun d -> match Ast.inner_decl d with
    | DTypeAlias _ -> ()  (* already handled *)
    | DNewtype (_, n, ps, con, fty, _) ->
      register_data ~aliases:env.aliases env (n, ps, [{ Ast.con_name = con; con_payload = Ast.ConPos [fty] }])
    | DData (_, n, ps, vs, _) -> register_data ~aliases:env.aliases env (n, ps, vs)
    | DRecord (_, n, ps, fs, _) -> register_record ~aliases:env.aliases env (n, ps, fs)
    | DInterface { iface_name; type_params; methods; _ } ->
      let ms = register_interface ~aliases:env.aliases env (iface_name, type_params, methods) in
      (* Prepend so later (user-side) declarations come first in the list:
         List.assoc on the returned env finds them, and the fold_right below
         pushes them onto env.vars last (i.e., at the front), so name lookups
         during type-checking also resolve to the user's version. *)
      iface_method_schemes := ms @ !iface_method_schemes
    | DExtern (_, name, ast_ty) ->
      let scheme =
        enter_level ();
        let mono = from_ast_type ~aliases:env.aliases ast_ty in
        exit_level ();
        generalize mono
      in
      extern_schemes := (name, scheme) :: !extern_schemes
    | _ -> ()
  ) prog;
  (* register_impl runs after all interfaces are registered.
     Prelude impls are marked seeded=true so user redefinitions take priority
     (same semantics as the old seed_builtin_impls fallback mechanism). *)
  if program_is_core user_prog then
    List.iter (fun d -> register_impl env (Ast.inner_decl d)) prog
  else begin
    List.iter (fun d -> register_impl ~seeded:true  env (Ast.inner_decl d)) Prelude.program;
    List.iter (fun d -> register_impl ~seeded:false env (Ast.inner_decl d)) user_prog
  end;
  check_coherence env;

  (* Phase 2: collect type sigs and fn clause groups *)
  let groups = group_fundefs prog in

  (* Phase 3: pre-bind every top-level name with a placeholder at level 1.
     Also bind all interface methods so they are visible in function bodies. *)
  enter_level ();
  let placeholders = List.concat_map (fun (_, members) ->
    List.map (fun (n, _, _) -> (n, fresh_var ())) members
  ) groups in
  exit_level ();
  let env = ref (
    let e = List.fold_left
      (fun e (n, t) -> extend_var e n (monotype t))
      env placeholders in
    let e = List.fold_right (fun (n, s) e -> extend_var e n s) !iface_method_schemes e in
    List.fold_left (fun e (n, s) -> extend_var e n s) e !extern_schemes
  ) in

  (* Phase 4: process each letrec group as a batch (singleton DFunDefs included). *)
  let results = List.concat_map
    (process_letrec_group env placeholders) groups in

  (* Phase 4.5: validate impl method bodies against their interfaces *)
  List.iter (fun d -> match Ast.inner_decl d with
    | DImpl _ as d -> check_impl !env d
    | _ -> ()
  ) prog;

  (* Phase 4.55: type-check prop declarations *)
  List.iter (fun d -> match Ast.inner_decl d with
    | DProp { prop_params; prop_body; _ } ->
      let local_env = List.fold_left (fun e (x, ast_ty) ->
        let mono = from_ast_type ~aliases:e.aliases ast_ty in
        extend_var e x (monotype mono)
      ) !env prop_params in
      let body_ty = infer local_env prop_body in
      unify body_ty t_bool
    | DBench { bench_body; _ } ->
      ignore (infer !env bench_body)
    | _ -> ()
  ) prog;

  (* Phase 4.6: verify method call sites have matching impls and constraints *)
  check_method_usages !env;
  check_constraint_obligations !env;

  (* Phase 5: effect inference and checking *)
  let user_extern_decls =
    List.filter_map (fun d -> match Ast.inner_decl d with
      | DExtern (_, n, t) -> Some (n, t)
      | _ -> None) prog
  in
  infer_and_check_effects ~extern_decls:user_extern_decls ~scheme_env:results (flatten_groups groups);

  (* Validate the built-in registry against what the prelude loaded.
     This is a compiler-build invariant: if any expected stdlib name is
     absent the stdlib was edited in a breaking way. *)
  List.iter (fun (role : Builtins.iface_role) ->
    if not (Hashtbl.mem (!env).interfaces role.iface) then
      failwith (Printf.sprintf
        "Builtins registry error: interface '%s' (role '%s') not found after \
         loading core.mdk" role.iface role.role)
  ) Builtins.ifaces;
  List.iter (fun (role : Builtins.ctor_role) ->
    if not (Hashtbl.mem (!env).ctors role.ctor) then
      failwith (Printf.sprintf
        "Builtins registry error: constructor '%s' (role '%s') not found after \
         loading core.mdk" role.ctor role.role)
  ) Builtins.ctors;

  (* Include interface methods and extern schemes in the returned env *)
  let final_env = !env in
  (results @ !iface_method_schemes @ !extern_schemes, List.rev !(final_env.warnings))

(* Multi-module type-checking entry point.
   Accepts public type exports of all previously-processed modules;
   seeds the env with imported names from use-declarations;
   returns this module's public type exports. *)
let typecheck_module
    (known_modules : module_type_exports list)
    (mod_id        : string)
    (prog          : program)
    : module_type_exports * (ident * scheme) list * string list =
  reset_state ();
  current_loc := None;
  current_impl_hint := None;
  let env = initial_env () in

  (* Core stdlib is always available in every module.
     Skip when this module itself IS core (avoid duplicates).
     Keep a reference to the user-only decls for export filtering — otherwise
     prelude impls would leak into every module's te_impls. *)
  let user_prog = prog in
  let prog = if program_is_core prog then prog else Prelude.program @ prog in

  register_attrs env prog;

  (* Seed env with all known module exports *)
  List.iter (fun te ->
    List.iter (fun (n, s) -> Hashtbl.replace env.ctors n s) te.te_ctors;
    List.iter (fun (n, ri) -> Hashtbl.replace env.records n ri) te.te_records;
    List.iter (fun (n, _) ->
      List.iter (fun (fn, _) ->
        Hashtbl.replace env.field_owners fn n
      ) (try (Hashtbl.find env.records n).rec_fields with Not_found -> [])
    ) te.te_records;
    List.iter (fun (n, ii) ->
      Hashtbl.replace env.interfaces n ii;
      (* Register imported interface methods so call sites in this module are
         recognized as method occurrences (records method_usages, enabling
         Phase 69 impl resolution) rather than treated as ordinary functions. *)
      List.iter (fun (mname, _) -> Hashtbl.replace env.method_iface mname n)
        ii.iface_methods
    ) te.te_interfaces;
    env.impls := te.te_impls @ !(env.impls);
  ) known_modules;

  (* Build the set of module-imported schemes from DUse decls *)
  let use_schemes = ref [] in
  List.iter (function
    | DUse (_, path) ->
      let mod_id_ref =
        let parts = match path with
          | UseName ns -> if List.length ns > 1
              then String.concat "." (List.rev (List.tl (List.rev ns)))
              else List.hd ns
          | UseGroup (ns, _) | UseWild ns | UseAlias (ns, _) ->
              String.concat "." ns
        in parts
      in
      (match List.find_opt (fun te -> te.te_mod_id = mod_id_ref) known_modules with
       | None -> ()
       | Some te ->
         let imported_names = match path with
           | UseName ns ->
             if List.length ns > 1 then [List.hd (List.rev ns)]
             else [] (* alias only *)
           | UseGroup (_, ms) -> ms
           | UseWild _ -> List.map fst te.te_schemes
           | UseAlias _ -> [] (* alias: don't auto-import names *)
         in
         List.iter (fun n ->
           match List.assoc_opt n te.te_schemes with
           | Some s -> use_schemes := (n, s) :: !use_schemes
           | None -> ()
         ) imported_names)
    | _ -> ()
  ) prog;

  (* First sub-pass: collect all type aliases *)
  List.iter (fun d -> match Ast.inner_decl d with
    | DTypeAlias (_, n, ps, rhs) -> register_alias env (n, ps, rhs)
    | _ -> ()
  ) prog;
  (* Also seed aliases from imported modules *)
  List.iter (fun te ->
    List.iter (fun (n, (ps, rhs)) -> register_alias env (n, ps, rhs)) te.te_aliases
  ) known_modules;
  let iface_method_schemes = ref [] in
  let extern_schemes = ref [] in
  List.iter (fun d -> match Ast.inner_decl d with
    | DTypeAlias _ -> ()  (* already handled *)
    | DNewtype (_, n, ps, con, fty, _) ->
      register_data ~aliases:env.aliases env (n, ps, [{ Ast.con_name = con; con_payload = Ast.ConPos [fty] }])
    | DData (_, n, ps, vs, _) -> register_data ~aliases:env.aliases env (n, ps, vs)
    | DRecord (_, n, ps, fs, _) -> register_record ~aliases:env.aliases env (n, ps, fs)
    | DInterface { iface_name; type_params; methods; _ } ->
      let ms = register_interface ~aliases:env.aliases env (iface_name, type_params, methods) in
      iface_method_schemes := ms @ !iface_method_schemes
    | DExtern (_, name, ast_ty) ->
      let scheme =
        enter_level ();
        let mono = from_ast_type ~aliases:env.aliases ast_ty in
        exit_level ();
        generalize mono
      in
      extern_schemes := (name, scheme) :: !extern_schemes
    | _ -> ()
  ) prog;
  if program_is_core user_prog then
    List.iter (fun d -> register_impl env (Ast.inner_decl d)) prog
  else begin
    List.iter (fun d -> register_impl ~seeded:true  env (Ast.inner_decl d)) Prelude.program;
    List.iter (fun d -> register_impl ~seeded:false env (Ast.inner_decl d)) user_prog
  end;
  check_coherence env;

  let groups = group_fundefs prog in
  enter_level ();
  let placeholders = List.concat_map (fun (_, members) ->
    List.map (fun (n, _, _) -> (n, fresh_var ())) members) groups in
  exit_level ();
  let env = ref (
    let e = List.fold_left (fun e (n, t) -> extend_var e n (monotype t)) env placeholders in
    let e = List.fold_right (fun (n, s) e -> extend_var e n s) !iface_method_schemes e in
    let e = List.fold_left (fun e (n, s) -> extend_var e n s) e !extern_schemes in
    List.fold_left (fun e (n, s) -> extend_var e n s) e !use_schemes
  ) in

  let results = List.concat_map (process_letrec_group env placeholders) groups in

  List.iter (fun d -> match Ast.inner_decl d with DImpl _ as d -> check_impl !env d | _ -> ()) prog;
  List.iter (fun d -> match Ast.inner_decl d with
    | DProp { prop_params; prop_body; _ } ->
      let local_env = List.fold_left (fun e (x, ast_ty) ->
        let mono = from_ast_type ~aliases:e.aliases ast_ty in
        extend_var e x (monotype mono)
      ) !env prop_params in
      let body_ty = infer local_env prop_body in
      unify body_ty t_bool
    | DBench { bench_body; _ } ->
      ignore (infer !env bench_body)
    | _ -> ()
  ) prog;
  check_method_usages !env;
  check_constraint_obligations !env;
  let user_extern_decls =
    List.filter_map (fun d -> match Ast.inner_decl d with DExtern (_, n, t) -> Some (n, t) | _ -> None) prog
  in
  infer_and_check_effects ~extern_decls:user_extern_decls ~scheme_env:results (flatten_groups groups);

  let all_schemes = results @ !iface_method_schemes @ !extern_schemes in
  let warnings = List.rev !(!env.warnings) in

  (* Build this module's public exports *)
  let pub_schemes = List.concat_map (fun d ->
    let pick n = match List.assoc_opt n all_schemes with
      | Some s -> [(n, s)]
      | None   -> []
    in
    match Ast.inner_decl d with
    | DFunDef (true, n, _, _) -> pick n
    | DLetGroup (true, bs)    -> List.concat_map (fun (n, _) -> pick n) bs
    | DTypeSig (true, n, _)   -> pick n
    | DExtern (true, n, _)    -> pick n
    | _                       -> []
  ) prog in
  (* Interface methods from pub interfaces are also exported *)
  let pub_iface_schemes = List.filter_map (fun d ->
    match Ast.inner_decl d with
    | DInterface { is_pub = true; _ } ->
      Some (List.filter (fun (n, _) -> List.mem_assoc n !iface_method_schemes) all_schemes)
    | _ -> None
  ) prog |> List.concat in
  let pub_ctors = List.filter_map (fun d ->
    match Ast.inner_decl d with
    | DNewtype (true, _, _, con, _, _) ->
      (match Hashtbl.find_opt (!env).ctors con with
       | Some s -> Some [(con, s)]
       | None -> None)
    | DData (DataPublic, _, _, vs, _) ->
      Some (List.filter_map (fun v ->
        match Hashtbl.find_opt (!env).ctors v.Ast.con_name with
        | Some s -> Some (v.Ast.con_name, s)
        | None -> None
      ) vs)
    | _ -> None
  ) prog |> List.concat in
  let pub_records = List.filter_map (fun d ->
    match Ast.inner_decl d with
    | DRecord (DataPublic, n, _, _, _) ->
      (match Hashtbl.find_opt (!env).records n with
       | Some ri -> Some (n, ri)
       | None -> None)
    | _ -> None
  ) prog in
  let pub_interfaces = List.filter_map (fun d ->
    match Ast.inner_decl d with
    | DInterface { is_pub = true; iface_name; _ } ->
      (match Hashtbl.find_opt (!env).interfaces iface_name with
       | Some ii -> Some (iface_name, ii)
       | None -> None)
    | _ -> None
  ) prog in
  let pub_aliases = List.filter_map (fun d ->
    match Ast.inner_decl d with
    | DTypeAlias (true, n, _, _) ->
      (match Hashtbl.find_opt (!env).aliases n with
       | Some v -> Some (n, v)
       | None -> None)
    | _ -> None
  ) prog in
  let te = {
    te_mod_id    = mod_id;
    te_schemes   = pub_schemes @ pub_iface_schemes;
    te_records   = pub_records;
    te_ctors     = pub_ctors;
    te_interfaces = pub_interfaces;
    (* Filter out prelude-seeded impls (those registered via Prelude.program
       at line ~2429, not from user_prog).  Otherwise downstream modules
       re-register them via env.impls := te.te_impls @ ..., then re-add
       them via their own Prelude prepend, and check_coherence fires
       a spurious "Multiple default impls" error. *)
    te_impls     = List.filter (fun ie ->
      not ie.impl_seeded
      && List.exists (fun d -> match Ast.inner_decl d with
        | DImpl { is_pub = true; iface_name; _ } -> ie.impl_iface = iface_name
        | _ -> false) user_prog
    ) !(!env.impls);
    te_aliases   = pub_aliases;
  } in
  (te, all_schemes, warnings)

(* ── REPL incremental interface ──────────────── *)

(* Create a fresh typecheck env seeded with built-ins.
   Does NOT call reset_state so the TVar counter is shared across REPL inputs. *)
(* Deep-copy an env: all hashtable fields get fresh copies, list refs get fresh
   refs.  Used by the REPL's :load command for atomic snapshot/restore. *)
let copy_tc_env (e : env) : env = {
  vars          = e.vars;                      (* persistent list *)
  ctors         = Hashtbl.copy e.ctors;
  records       = Hashtbl.copy e.records;
  field_owners  = Hashtbl.copy e.field_owners;
  interfaces    = Hashtbl.copy e.interfaces;
  method_iface  = Hashtbl.copy e.method_iface;
  impls         = ref !(e.impls);
  method_usages = ref !(e.method_usages);
  fun_constraints        = Hashtbl.copy e.fun_constraints;
  constraint_obligations = ref !(e.constraint_obligations);
  type_ctors    = Hashtbl.copy e.type_ctors;
  ctor_fields   = Hashtbl.copy e.ctor_fields;
  aliases       = Hashtbl.copy e.aliases;
  warnings        = ref !(e.warnings);
  mut_vars        = e.mut_vars;                (* persistent set *)
  deprecated_fns  = Hashtbl.copy e.deprecated_fns;
  must_use_fns    = Hashtbl.copy e.must_use_fns;
}

(* Type-check one or more declarations against an existing env.
   Updates env in place and returns (new_bindings, warnings).
   ~seeded:true marks any registered impls as prelude-seeded so that later
   user-defined impls for the same (iface, ty) take priority without ambiguity. *)
let check_repl_decl ?(seeded=false) (env : env ref) (decls : decl list)
    : (ident * scheme) list * string list =
  current_loc := None;
  current_impl_hint := None;
  register_attrs !env decls;
  (* First sub-pass: collect all type aliases *)
  List.iter (fun d -> match Ast.inner_decl d with
    | DTypeAlias (_, n, ps, rhs) -> register_alias !env (n, ps, rhs)
    | _ -> ()
  ) decls;
  let iface_method_schemes = ref [] in
  let extern_schemes = ref [] in
  List.iter (fun d -> match Ast.inner_decl d with
    | DTypeAlias _ -> ()  (* already handled *)
    | DNewtype (_, n, ps, con, fty, _) ->
      register_data ~aliases:(!env).aliases !env (n, ps, [{ Ast.con_name = con; con_payload = Ast.ConPos [fty] }])
    | DData (_, n, ps, vs, _) -> register_data ~aliases:(!env).aliases !env (n, ps, vs)
    | DRecord (_, n, ps, fs, _) -> register_record ~aliases:(!env).aliases !env (n, ps, fs)
    | DInterface { iface_name; type_params; methods; _ } ->
      let ms = register_interface ~aliases:(!env).aliases !env (iface_name, type_params, methods) in
      iface_method_schemes := ms @ !iface_method_schemes
    | DExtern (_, name, ast_ty) ->
      let scheme =
        enter_level ();
        let mono = from_ast_type ~aliases:(!env).aliases ast_ty in
        exit_level ();
        generalize mono
      in
      extern_schemes := (name, scheme) :: !extern_schemes
    | _ -> ()
  ) decls;
  List.iter (fun d -> register_impl ~seeded !env (Ast.inner_decl d)) decls;
  check_coherence !env;
  let groups = group_fundefs decls in
  enter_level ();
  let placeholders = List.concat_map (fun (_, members) ->
    List.map (fun (n, _, _) -> (n, fresh_var ())) members) groups in
  exit_level ();
  env := (
    let e = List.fold_left
      (fun e (n, t) -> extend_var e n (monotype t))
      !env placeholders in
    let e = List.fold_right (fun (n, s) e -> extend_var e n s) !iface_method_schemes e in
    List.fold_left (fun e (n, s) -> extend_var e n s) e !extern_schemes
  );
  let results = List.concat_map (process_letrec_group env placeholders) groups in
  List.iter (fun d -> match Ast.inner_decl d with
    | DImpl _ as d -> check_impl !env d
    | _ -> ()
  ) decls;
  List.iter (fun d -> match Ast.inner_decl d with
    | DProp { prop_params; prop_body; _ } ->
      let local_env = List.fold_left (fun e (x, ast_ty) ->
        let mono = from_ast_type ~aliases:e.aliases ast_ty in
        extend_var e x (monotype mono)
      ) !env prop_params in
      let body_ty = infer local_env prop_body in
      unify body_ty t_bool
    | DBench { bench_body; _ } ->
      ignore (infer !env bench_body)
    | _ -> ()
  ) decls;
  check_method_usages !env;
  check_constraint_obligations !env;
  let user_extern_decls =
    List.filter_map (fun d -> match Ast.inner_decl d with DExtern (_, n, t) -> Some (n, t) | _ -> None) decls
  in
  infer_and_check_effects ~extern_decls:user_extern_decls ~scheme_env:results (flatten_groups groups);
  (results @ !iface_method_schemes @ !extern_schemes,
   List.rev !(!env.warnings))

(* Build a fresh REPL type-checking env with the prelude already loaded.
   Processes Prelude.program through check_repl_decl so core.mdk's data
   types, interfaces, and impls — and crucially, env.method_iface bindings
   for operator methods like add/sub/lt — are in scope for subsequent
   incremental REPL input. *)
let make_repl_tc_env () : env ref =
  let env = initial_env () in
  let env_ref = ref env in
  let _ = check_repl_decl ~seeded:true env_ref Prelude.program in
  env_ref

(* Infer the type of a bare expression without updating the env.
   Returns (mono_type, warnings). *)
let infer_repl_expr (env : env) (e : expr) : mono * string list =
  current_loc := None;
  current_impl_hint := None;
  enter_level ();
  let t = infer env e in
  exit_level ();
  (* Phase 69: resolve method occurrences so EMethodRef refs in [e] get stamped
     with the chosen impl key before eval runs on the same tree.  Mirrors
     check_repl_decl; like there, usages accumulate in the persistent env and
     are re-checked idempotently (concrete usages re-fill to the same key). *)
  check_method_usages env;
  let scheme = generalize t in
  let (Forall (_, mono)) = scheme in
  (mono, List.rev !(env.warnings))
