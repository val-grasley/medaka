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
   annotation).  See PLAN-ARCHIVE.md §5 for the full list. *)

open Ast

module StringSet = Set.Make(String)

(* ── Types ──────────────────────────────────────── *)

type level = int

type effect_set = string list  (* sorted, deduplicated set of concrete effect labels *)

type tyvar_info =
  | Unbound of int * level
  | Link    of mono

and mono =
  | TVar   of tyvar_info ref
  | TCon   of string
  | TApp   of mono * mono
  | TFun   of mono * effrow * mono    (* arg -> effect row -> result *)
  | TTuple of mono list

(* An effect row (Phase 79): a set of concrete effect labels plus an optional
   tail variable.
     tail = None    ⇒ closed row, exactly [labels].
     tail = Some ρ  ⇒ open row <labels | ρ>: ρ can absorb further effects.
   Inference-synthesized arrows use open rows so the effect-subsumption
   discipline survives *equality* unification; user annotations are closed
   unless they explicitly name a tail (`<IO | e>`). *)
and effrow = { labels : effect_set; tail : effvar option }
and effvar_info =
  | EUnbound of int * level
  | ELink    of effrow
and effvar = effvar_info ref

(* A type scheme: forall <tyvar ids> <effvar ids>. mono. The bound ids are tyvar
   IDs and effect-var IDs that occur free in `mono`. *)
type scheme = Forall of int list * int list * mono

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
  iface_supers : (ident * int list) list;
    (* superinterface obligations (`interface Ord a requires Eq a`): each entry
       is (super_iface, [param_ids]) where the ids index into iface_param_ids.
       Phase 64: enforced at impl sites by check_superinterface_obligations. *)
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
  impl_loc        : Ast.loc option;  (* source loc of the impl decl, for
                                        Phase 68 coherence-error reporting *)
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
  te_types     : ident list;  (* public data/record/newtype/alias type-constructor names *)
  te_fun_constraints : (ident * (ident * int list) list) list;
    (* Phase 69.x: public constrained functions' constraints, so importers wrap
       their occurrences in EDictApp and dict_pass gives them dict parameters.
       Bound var ids are the same ones in the exported te_schemes entry. *)
  te_method_constraints : (ident * (ident * int list) list) list;
    (* Phase 69.x-e: public interface methods' own method-level constraints
       (super-expanded), so importers can stamp res_method_dicts at call sites
       and dict_pass gives the method bodies matching dict parameters. *)
  te_inferred_constraints : (ident * (ident * int list) list) list;
    (* Phase 83: public unsignatured functions' *inferred* constraints, so an
       importer's missing-impl check still fires.  Obligation-checking only (no
       dict routing) — see the inferred_constraints env field. *)
}

(* ── Effects ─────────────────────────────────────── *)

(* ── Errors ─────────────────────────────────────── *)

type type_error =
  | TypeMismatch   of mono * mono
  | InfiniteType   of int * mono
  | UnboundVar     of ident
  | UnknownCtor    of ident
  | ArityMismatch  of ident * int * int   (* name, expected, got *)
  | UnboundTypeVar of ident * ident        (* tyvar, declaring type name *)
  | UnknownRecord  of ident
  | UnknownField   of ident * ident       (* field, record *)
  | AmbiguousField of ident * ident list   (* field, candidate records — type unknown *)
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
  | OrphanImpl         of ident * mono list * string option * string option
    (* iface_name, head type args, defining module of iface (if known),
       defining module of a head type (if known) — orphan-instance check *)
  | MissingSuperImpl   of ident * ident * mono list  (* iface_name, super_iface, concrete super args *)
  | MissingImplRequirement of ident * mono list * ident * mono list
    (* selected iface + its concrete args, required iface + its concrete args *)
  | UnsatisfiedConstraint of ident * ident
    (* Phase 83: binding name + interface its body needs on a polymorphic value
       that its declared signature (and supers) does not provide *)
  | ImmutableAssignment of ident                   (* assignment to a non-mut binding *)
  | MutLetInDo          of ident                   (* let mut inside a do block (only allowed in EBlock) *)
  | MutLetRequiresBlock of ident                   (* let mut in inline `let ... in ...` position; needs a block *)
  | BindOutsideDo                                  (* `<-` used in a bare block, not a do block *)
  | AssignInDo          of ident                   (* `x = e` reassignment inside a do block *)
  | FieldAssignInDo     of ident * ident           (* `x.field = e` inside a do block *)
  | NotARecord          of ident                   (* field assignment on non-record type *)
  | RecursiveTypeAlias  of ident                   (* type alias that expands to itself *)
  | TypeAliasArity      of ident * int * int        (* alias, expected params, got args *)
  | AnnotationTooGeneral of Ast.ty                  (* annotation claims more polymorphism than expr has *)
  | LetRecNonFunction   of ident                   (* `let rec x = ...` where RHS isn't a lambda *)
  | InternalError       of string                   (* a broken compiler invariant, surfaced as a diagnostic *)
  | CannotShadowPrelude of ident                    (* Phase 78a: redefining a prelude fn the stdlib uses internally *)
  | Other              of string

exception Type_error of type_error * Ast.loc option

let current_loc : Ast.loc option ref = ref None
let current_impl_hint : string option ref = ref None
(* Phase 69: the EMethodRef ref of the method occurrence currently being
   inferred, if any.  Set by infer's EMethodRef case and consumed once by the
   EVar method branch (which records it in method_usages so check_method_usages
   can fill it with the resolved impl key).  Mirrors current_impl_hint. *)
let current_method_ref : Ast.resolved option ref option ref = ref None
(* Phase 69.x: the EDictApp routes-ref of the constrained-function occurrence
   currently being inferred, if any.  Set by infer's EDictApp case and consumed
   once by the EVar non-method branch (which records it in dict_app_usages so
   resolve_dict_apps can fill it with one route per constraint).  Mirrors
   current_method_ref. *)
let current_dict_ref : Ast.res_route list option ref option ref = ref None
(* Phase 136: the top-level function whose body is currently being inferred, set
   by process_letrec_group around each member's body inference.  A constrained
   self-/mutual-recursive call captures it (into dict_app_usages /
   recursive_promoted_usages) so resolve_dict_apps can tell find_enclosing_dict
   *which* member encloses the occurrence: a merged mutual-recursion group's
   members share one constraint var id, so id-matching alone can't distinguish
   them and would forward a sibling's `$dict_<fn>_<slot>` param. *)
let current_fn : Ast.ident option ref = ref None

let fail e = raise (Type_error (e, !current_loc))

(* Like [fail] but reports at an explicitly-captured location instead of the
   global [!current_loc].  Used by the post-HM instance/constraint passes, which
   run after the whole module is walked — by then [!current_loc] is stale, so
   the call-site loc captured at record time must be threaded through. *)
let fail_at loc e = raise (Type_error (e, loc))

(* ── State: fresh vars + current level ──────────── *)

let tyvar_counter = ref 0
let effvar_counter = ref 0
let current_level = ref 0

(* Phase 79d: the latent effect of the function body currently being inferred.
   `infer`'s effect-performing arms (application) widen it; entering a lambda
   saves and reopens it, and the accumulated row becomes that lambda's arrow
   effect.  A closed (tail=None) ambient is a *sink* that discards effects —
   the state at the top level, where a value binding's effects are dropped. *)
let cur_effect : effrow ref = ref { labels = []; tail = None }

let reset_state () =
  tyvar_counter := 0;
  effvar_counter := 0;
  current_level := 0;
  cur_effect := { labels = []; tail = None }

let fresh_var () =
  incr tyvar_counter;
  TVar (ref (Unbound (!tyvar_counter, !current_level)))

let enter_level () = incr current_level
let exit_level  () = decr current_level

(* ── Effect rows (Phase 79) ─────────────────────── *)

(* The empty closed row — a pure arrow. *)
let pure_row = { labels = []; tail = None }

(* A closed row over the given concrete labels. *)
let closed_row labels = { labels = List.sort_uniq String.compare labels; tail = None }

(* Follow ELink tails (merging labels along the way) to a canonical row whose
   tail, if present, is an unbound effvar. *)
let rec effrow_norm r =
  match r.tail with
  | Some { contents = ELink r' } ->
    let r' = effrow_norm r' in
    { labels = List.sort_uniq String.compare (r.labels @ r'.labels); tail = r'.tail }
  | _ -> r

(* The concrete labels currently known for a row (ignores the open tail). *)
let effrow_labels r = (effrow_norm r).labels

let fresh_effvar () =
  incr effvar_counter;
  ref (EUnbound (!effvar_counter, !current_level))

let fresh_effvar_at level =
  incr effvar_counter;
  ref (EUnbound (!effvar_counter, level))

(* An open row with a fresh tail variable — the effect signature of an arrow
   whose latent effect is still being inferred.  The open tail lets a
   pure-looking inference arrow absorb effects when it unifies against an
   effectful one, which is what preserves the effect-subsumption discipline
   under equality unification. *)
let open_row () = { labels = []; tail = Some (fresh_effvar ()) }

let effvar_level v = match !v with EUnbound (_, l) -> l | ELink _ -> 0

(* Lower row r's (normalized) tail effvar level to <= [level], so an effvar
   captured by an outer binding can't be generalized one scope out.  Mirrors the
   level-lowering occurs_adjust performs for type variables. *)
let lower_row_levels level r =
  match (effrow_norm r).tail with
  | Some v ->
    (match !v with
     | EUnbound (id, lvl) -> if lvl > level then v := EUnbound (id, level)
     | ELink _ -> ())
  | None -> ()

(* Record that the current context performs the effects of row [eff], widening
   the ambient row [cur] to include them WITHOUT closing its tail (so the next
   performed effect can still be absorbed).  A closed ambient is a sink and
   discards.  An open [eff] is tied to the ambient through a shared fresh tail
   so labels resolved into it later (e.g. a polymorphic callback's effect) also
   surface in the ambient. *)
let perform_effect cur eff =
  let cur_r = effrow_norm !cur in
  match cur_r.tail with
  | None -> ()                       (* sink: discard *)
  | Some ct ->
    let eff_r = effrow_norm eff in
    cur := { labels = List.sort_uniq String.compare (cur_r.labels @ eff_r.labels);
             tail = Some ct };
    (match eff_r.tail with
     | Some et when et != ct ->
       let v3 = fresh_effvar_at (min (effvar_level ct) (effvar_level et)) in
       ct := ELink { labels = []; tail = Some v3 };
       et := ELink { labels = []; tail = Some v3 }
     | _ -> ())

(* Build a curried arrow `p1 -> p2 -> … -> <eff> ret` carrying the body's latent
   effect [eff] on the LAST arrow only: partial application of a curried
   function performs nothing, so the intermediate arrows stay pure-open. *)
let rec arrows_with_last_effect pats eff ret = match pats with
  | []        -> ret
  | [pt]      -> TFun (pt, eff, ret)
  | pt :: rest -> TFun (pt, open_row (), arrows_with_last_effect rest eff ret)

(* The declared concrete effect set of a signature: the labels on the first
   `<…>` reached walking down the return side.  `String -> <IO> Unit` → ["IO"];
   `<IO, Rand> Unit` (a value binding's effect) → ["IO"; "Rand"].  The Phase 79e
   binding-boundary escape check compares the inferred body effects against this. *)
let rec declared_effects : Ast.ty -> effect_set = function
  | Ast.TyFun (_, ret) -> declared_effects ret
  | Ast.TyEffect (effs, _, _) -> List.sort_uniq String.compare effs
  | Ast.TyConstrained (_, t) -> declared_effects t
  | _ -> []

(* Build an effect row from an arrow's return-position AST type.  A named tail
   variable (`<IO | e>`) is resolved through [etbl] so the same source name
   shares one effvar across the whole signature — that shared effvar is what
   links a HOF's callback effect to its result effect. *)
let ast_effrow etbl = function
  | Ast.TyEffect (es, tl, _) ->
    let tail = Option.map (fun name ->
      match Hashtbl.find_opt etbl name with
      | Some v -> v
      | None -> let v = fresh_effvar () in Hashtbl.add etbl name v; v) tl
    in
    { labels = List.sort_uniq String.compare es; tail }
  | _ -> pure_row

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
  | TApp (a, b) -> occurs_adjust id level a; occurs_adjust id level b
  | TFun (a, r, b) ->
    (* A type var can never appear inside an effect row (rows hold only effvars
       and concrete labels), so there is no occurs hazard — but an effvar in the
       row must still have its level lowered alongside the tyvar being bound. *)
    occurs_adjust id level a; lower_row_levels level r; occurs_adjust id level b
  | TTuple ts ->
    List.iter (occurs_adjust id level) ts

(* ── Effect-row unification (Phase 79c) ──────────── *)

(* Unify two effect rows.  An open row (one with a tail variable) absorbs the
   other side's labels by binding its tail; two open rows are routed through one
   shared fresh tail so future additions to either flow to both.  This is the
   plumbing effect inference needs.

   It is deliberately PERMISSIVE: an open row whose own labels exceed a closed
   annotation, and two differing closed rows, are left as-is rather than raising.
   Effect-escape detection stays with the post-HM effects pass until it moves to
   the binding boundary in Phase 79e; keeping unify_row quiet here avoids
   double-reporting and any new errors on existing code. *)
let unify_row r1 r2 =
  let r1 = effrow_norm r1 and r2 = effrow_norm r2 in
  let diff a b = List.filter (fun x -> not (List.mem x b)) a in
  match r1.tail, r2.tail with
  | Some v1, Some v2 when v1 == v2 -> ()
  | Some v1, Some v2 ->
    (* both open: route both tails through one shared fresh tail carrying the
       union of labels (so each side ends up as <labels1 ∪ labels2 | v3>) *)
    let v3 = fresh_effvar_at (min (effvar_level v1) (effvar_level v2)) in
    v1 := ELink { labels = diff r2.labels r1.labels; tail = Some v3 };
    v2 := ELink { labels = diff r1.labels r2.labels; tail = Some v3 }
  | Some v1, None ->
    (* r1 open, r2 closed: close r1, absorbing r2's extra labels *)
    v1 := ELink { labels = diff r2.labels r1.labels; tail = None }
  | None, Some v2 ->
    v2 := ELink { labels = diff r1.labels r2.labels; tail = None }
  | None, None -> ()

(* ── Unification ────────────────────────────────── *)

let rec unify t1 t2 =
  let t1 = normalize t1 in
  let t2 = normalize t2 in
  match t1, t2 with
  | TVar v1, TVar v2 when v1 == v2 -> ()
  | TVar v, t | t, TVar v ->
    (match !v with
     | Link _ -> fail (InternalError "unify: Link survived normalize")
     | Unbound (id, level) ->
       occurs_adjust id level t;
       v := Link t)
  | TCon n1, TCon n2 when n1 = n2 -> ()
  | TApp (a1, b1), TApp (a2, b2) ->
    unify a1 a2; unify b1 b2
  | TFun (a1, r1, b1), TFun (a2, r2, b2) ->
    unify a1 a2; unify_row r1 r2; unify b1 b2
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

(* Free generalizable effect variables: a row's tail effvar at a level deeper
   than the current scope.  Collected alongside [free_unbound]'s tyvars so a
   polymorphic HOF quantifies over its callback's effect. *)
let rec free_effvars acc = function
  | TVar v ->
    (match !v with Link t -> free_effvars acc t | Unbound _ -> acc)
  | TCon _ -> acc
  | TApp (a, b) -> free_effvars (free_effvars acc a) b
  | TFun (a, r, b) ->
    let acc = free_effvars acc a in
    let acc =
      match (effrow_norm r).tail with
      | Some v ->
        (match !v with
         | EUnbound (id, level) when level > !current_level && not (List.mem id acc) -> id :: acc
         | _ -> acc)
      | None -> acc
    in
    free_effvars acc b
  | TTuple ts -> List.fold_left free_effvars acc ts

let generalize t = Forall (free_unbound [] t, free_effvars [] t, t)

(* Replace a row's bound tail effvar with its fresh instance from [esub] (the
   per-instantiation substitution), so each call site of a polymorphic HOF gets
   its own effect variable rather than sharing the scheme's. *)
let subst_row esub r =
  let r = effrow_norm r in
  match r.tail with
  | Some v ->
    (match !v with
     | EUnbound (id, _) ->
       (match List.assoc_opt id esub with Some v' -> { r with tail = Some v' } | None -> r)
     | ELink _ -> r)
  | None -> r

let instantiate_raw (Forall (vars, evars, t)) =
  let sub = List.map (fun id -> (id, fresh_var ())) vars in
  let esub = List.map (fun id -> (id, fresh_effvar ())) evars in
  let rec walk t = match normalize t with
    | TVar v ->
      (match !v with
       | Unbound (id, _) -> (try List.assoc id sub with Not_found -> TVar v)
       | Link _ -> fail (InternalError "instantiate: Link survived normalize"))
    | TCon _ as t -> t
    | TApp (a, b)  -> TApp (walk a, walk b)
    | TFun (a, r, b) -> TFun (walk a, subst_row esub r, walk b)
    | TTuple ts    -> TTuple (List.map walk ts)
  in
  (sub, walk t)

let instantiate s = snd (instantiate_raw s)

let monotype t = Forall ([], [], t)

(* Phase 74 follow-up: find the live (still-unbound) tyvar carrying [id] inside a
   mono type, if present.  instantiate_raw produces an empty substitution for a
   monomorphic recursive placeholder, so a self/mutual-recursive constrained
   call can't map its constraint var ids through `sub`; instead the var is one of
   the enclosing function's own live tyvars, recoverable by id from the
   occurrence's type. *)
let rec find_tvar_in_mono t id =
  match normalize t with
  | TVar { contents = Unbound (id', _) } as v -> if id' = id then Some v else None
  | TVar _ -> None
  | TCon _ -> None
  | TApp (a, b) | TFun (a, _, b) ->
    (match find_tvar_in_mono a id with Some _ as r -> r | None -> find_tvar_in_mono b id)
  | TTuple ts ->
    List.fold_left
      (fun acc t -> match acc with Some _ -> acc | None -> find_tvar_in_mono t id)
      None ts

(* ── Value restriction (Phase 66) ───────────────── *)

(* A syntactically non-expansive (value) expression may be generalized; every
   other RHS is value-restricted (bound monomorphically) to close the classic
   polymorphic-reference hole: `r = Ref []` must NOT get `forall a. Ref (List a)`.
   `Ref` is a constructor here, so — like SML/OCaml's `ref` — ALL applications
   (constructor or otherwise) are treated as expansive. ELoc/EAnnot are
   transparent. Lists are immutable cons-lists (value if their elements are);
   arrays, records, maps and sets are potentially mutable, hence expansive. *)
let rec is_nonexpansive = function
  | ELit _ | EVar _ | ELam _      -> true
  | ELoc (_, e) | EAnnot (e, _)   -> is_nonexpansive e
  | ETuple es | EListLit es       -> List.for_all is_nonexpansive es
  | _                             -> false

(* Lower every unbound var in t at level > current down to current_level, so a
   value-restricted (non-generalized) binding's vars can't be picked up by an
   enclosing let's generalize. Mirrors the lowering `unify tp t1` performs in
   the non-PVar pattern path via occurs_adjust. *)
let rec lower_to_current t = match normalize t with
  | TVar v ->
    (match !v with
     | Link t -> lower_to_current t
     | Unbound (id, level) ->
       if level > !current_level then v := Unbound (id, !current_level))
  | TCon _ -> ()
  | TApp (a, b) -> lower_to_current a; lower_to_current b
  | TFun (a, r, b) ->
    lower_to_current a; lower_row_levels !current_level r; lower_to_current b
  | TTuple ts -> List.iter lower_to_current ts

(* Generalize a value RHS; value-restrict (monomorphize, lowering free vars)
   otherwise. *)
let gen_restricted is_value t =
  if is_value then generalize t
  else (lower_to_current t; monotype t)

(* Like instantiate, but maps specific bound IDs to provided monos instead of
   always creating fresh vars.  Used by check_impl to substitute the impl's
   concrete type args for the interface's type-parameter IDs. *)
let instantiate_with (Forall (vars, evars, t)) (subs : (int * mono) list) =
  let sub = List.map (fun id ->
    (id, try List.assoc id subs with Not_found -> fresh_var ())
  ) vars in
  let esub = List.map (fun id -> (id, fresh_effvar ())) evars in
  let rec walk t = match normalize t with
    | TVar v ->
      (match !v with
       | Unbound (id, _) -> (try List.assoc id sub with Not_found -> TVar v)
       | Link _ -> fail (InternalError "instantiate: Link survived normalize"))
    | TCon _ as t -> t
    | TApp (a, b)  -> TApp (walk a, walk b)
    | TFun (a, r, b) -> TFun (walk a, subst_row esub r, walk b)
    | TTuple ts    -> TTuple (List.map walk ts)
  in
  walk t

(* Like instantiate, but also returns the fresh TVar refs corresponding to
   specific bound IDs (the interface's iface_param_ids) and the full sub
   mapping bound IDs to fresh monos. Used to track which concrete types a
   method call is dispatching on (for impl resolution) and to expand
   per-method extra constraint arguments (for constraint checking). *)
let instantiate_method (Forall (vars, evars, t)) track_ids =
  let sub = List.map (fun id -> (id, fresh_var ())) vars in
  let esub = List.map (fun id -> (id, fresh_effvar ())) evars in
  let rec walk t = match normalize t with
    | TVar v ->
      (match !v with
       | Unbound (id, _) -> (try List.assoc id sub with Not_found -> TVar v)
       | Link _ -> fail (InternalError "instantiate: Link survived normalize"))
    | TCon _ as t -> t
    | TApp (a, b)  -> TApp (walk a, walk b)
    | TFun (a, r, b) -> TFun (walk a, subst_row esub r, walk b)
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

(* A naming context: a shared table + counter so the same tyvar gets the same
   printed name across every type rendered against this context.  Pass one
   context to several [pp_mono_in] calls (e.g. both sides of a mismatch) so two
   distinct vars never collide on the same letter. *)
let new_name_ctx () = (Hashtbl.create 8, ref 0)

let pp_mono_in (names, counter) t =
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
       (* Unreachable after normalize; never raise from a rendering path
          (this runs while formatting an error message). *)
       | Link _ -> "_"
       | Unbound (id, _) -> name_of id)
    | TCon n -> n
    | TApp (a, b) ->
      (* let-bind to force left-to-right evaluation so names track reading order *)
      let sa = go 2 a in
      let sb = go 3 b in
      let s = sa ^ " " ^ sb in
      if prec > 2 then "(" ^ s ^ ")" else s
    | TFun (a, effs, b) ->
      (* Empty-open rows render as pure: a generalized/unconstrained effect tail
         carries no information for the reader, and printing it would churn every
         existing golden type string. *)
      let labels = effrow_labels effs in
      let eff_str = if labels = [] then ""
                    else Printf.sprintf "<%s> " (String.concat ", " labels) in
      let sa = go 2 a in
      let sb = go 1 b in
      let s = sa ^ " -> " ^ eff_str ^ sb in
      if prec > 1 then "(" ^ s ^ ")" else s
    | TTuple ts ->
      Printf.sprintf "(%s)" (String.concat ", " (List.map (go 0) ts))
  in
  go 0 t

let pp_mono t = pp_mono_in (new_name_ctx ()) t

(* Render two types against one shared naming context, so a var that appears in
   both prints identically and two distinct vars never share a letter. *)
let pp_mono_pair a b =
  let ctx = new_name_ctx () in
  let sa = pp_mono_in ctx a in
  let sb = pp_mono_in ctx b in
  (sa, sb)

(* Render a list of types space-separated, sharing one naming context across
   the whole list (so distinct vars in an arg list don't all become "a"). *)
let pp_monos args =
  let ctx = new_name_ctx () in
  String.concat " " (List.map (pp_mono_in ctx) args)

(* Render two arg lists against one shared context, returning the two
   space-separated strings — for errors that name two related impl heads. *)
let pp_monos_pair args1 args2 =
  let ctx = new_name_ctx () in
  let s1 = String.concat " " (List.map (pp_mono_in ctx) args1) in
  let s2 = String.concat " " (List.map (pp_mono_in ctx) args2) in
  (s1, s2)

let pp_scheme (Forall (_vars, _evars, t)) = pp_mono t

let pp_error = function
  | TypeMismatch (a, b) ->
    let sa, sb = pp_mono_pair a b in
    Printf.sprintf "Type mismatch: %s vs %s" sa sb
  | InfiniteType (_, t) ->
    Printf.sprintf "Cannot construct infinite type involving %s" (pp_mono t)
  | UnboundVar n   -> Printf.sprintf "Unbound variable: %s" n
  | UnknownCtor n  -> Printf.sprintf "Unknown constructor: %s" n
  | ArityMismatch (n, exp, got) ->
    Printf.sprintf "Constructor %s expects %d args, got %d" n exp got
  | UnboundTypeVar (v, tname) ->
    Printf.sprintf
      "Unbound type variable '%s' in the definition of '%s' — every type variable in a payload must appear in the type's parameter list (e.g. 'data %s %s = ...')"
      v tname tname v
  | UnknownRecord r -> Printf.sprintf "Unknown record type: %s" r
  | UnknownField (f, r) ->
    Printf.sprintf "Field %s does not belong to record %s" f r
  | AmbiguousField (f, rs) ->
    Printf.sprintf
      "Ambiguous field access: '.%s' is declared by %s. I can't tell which record this value is — add a type annotation on it (e.g. '(r : %s).%s')."
      f (String.concat ", " rs) (List.hd rs) f
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
    let se, sa = pp_mono_pair expected actual in
    Printf.sprintf "Method '%s': expected type %s but got %s"
      m se sa
  | ImplArityMismatch (iface, expected, got) ->
    Printf.sprintf "Interface %s has %d type parameter(s) but impl provides %d type argument(s)"
      iface expected got
  | NoImplFound (iface, args) ->
    Printf.sprintf "No impl of %s for %s"
      iface (pp_monos args)
  | AmbiguousImpl (iface, args) ->
    Printf.sprintf "Ambiguous: multiple impls of %s for %s — use @ImplName to disambiguate"
      iface (pp_monos args)
  | UnknownImplName (iface, name, args) ->
    Printf.sprintf "No impl named '%s' found for %s %s"
      name iface (pp_monos args)
  | MultipleDefaultImpls (iface, args) ->
    Printf.sprintf "Multiple default impls of %s for %s — at most one default allowed"
      iface (pp_monos args)
  | OverlappingImpls (iface, args1, args2) ->
    let s1, s2 = pp_monos_pair args1 args2 in
    Printf.sprintf
      "Overlapping impls of %s: %s and %s can match the same type — mark the more general one `default impl`, or make them disjoint"
      iface s1 s2
  | OrphanImpl (iface, args, iface_mod, type_mod) ->
    let where =
      match iface_mod, type_mod with
      | Some im, Some tm ->
        Printf.sprintf " — declare it in module '%s' (which defines %s) or module '%s' (which defines the type)"
          im iface tm
      | Some im, None ->
        Printf.sprintf " — declare it in module '%s' (which defines %s)" im iface
      | None, Some tm ->
        Printf.sprintf " — declare it in module '%s' (which defines the type)" tm
      | None, None -> ""
    in
    Printf.sprintf
      "Orphan impl of %s for %s: an impl must be declared in the module that defines the interface or one of its head types%s, or wrap the type in a local newtype"
      iface (pp_monos args) where
  | MissingSuperImpl (iface, super, args) ->
    let s = pp_monos args in
    Printf.sprintf
      "impl %s %s requires a superinterface impl 'impl %s %s', which is missing"
      iface s super s
  | MissingImplRequirement (iface, args, req_iface, req_args) ->
    let s1, s2 = pp_monos_pair args req_args in
    Printf.sprintf
      "impl %s %s requires '%s %s', which has no impl"
      iface s1 req_iface s2
  | UnsatisfiedConstraint (name, iface) ->
    Printf.sprintf
      "'%s' uses interface %s on a polymorphic value but its type signature does not require it — add '%s a =>' to the signature, or drop the signature to let the constraint be inferred"
      name iface iface
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
  | TypeAliasArity (n, exp, got) ->
    Printf.sprintf
      "Type alias '%s' expects %d type argument(s) but got %d — type aliases must be fully applied"
      n exp got
  | AnnotationTooGeneral t ->
    Printf.sprintf
      "Type annotation '%s' is more polymorphic than the expression — a type variable in the annotation is actually a specific type (or two annotation variables are the same type)"
      (Ast.pp_ty t)
  | LetRecNonFunction n ->
    Printf.sprintf
      "'%s' is bound by 'let rec' but its right-hand side is not a function. Recursive value bindings must have a lambda right-hand side; cyclic data structures are not supported."
      n
  | InternalError msg ->
    Printf.sprintf "Internal type-checker error: %s (this is a compiler bug — please report it)" msg
  | CannotShadowPrelude n ->
    Printf.sprintf
      "Cannot redefine '%s': it is a standard-library function the prelude uses \
       internally, so it cannot be shadowed. Rename your definition to a \
       different name."
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
  standalone_values : (ident, unit) Hashtbl.t;
    (* Phase 112: names that are BOTH an explicitly-imported/local top-level
       value AND an interface method (e.g. map's exported `toList`/`isEmpty`,
       which collide with Foldable's methods).  When such a name is applied to a
       concrete receiver whose type has no impl of the interface, the new
       method-head application arm in `infer` types the call against the
       standalone (via `lookup_var`) instead of failing `NoImplFound`.  Empty on
       the single-file path (no imports to fall back to). *)
  impls         : impl_entry list ref;          (* all registered impls *)
  method_usages : (ident * ident * tyvar_info ref list * string option * (ident * mono list) list * Ast.resolved option ref option * Ast.loc option * ident option) list ref;  (* (method, iface, param_var_refs, impl_hint, method_dict_args, method_occurrence_ref, call_site_loc, enclosing_fn) — enclosing_fn (Phase 136) picks the right dict among merged mutual-recursion siblings sharing a constraint var id *)
  fun_constraints : (ident, (ident * int list) list) Hashtbl.t;
    (* fn_name → [(iface_name, [bound_var_ids_in_scheme])] *)
  inferred_constraints : (ident, (ident * int list) list) Hashtbl.t;
    (* Phase 83: same shape as fun_constraints, but for constraints *inferred*
       from an unsignatured binding's body rather than declared via `=>`.  These
       drive only call-site obligation recording (so a polymorphic wrapper's
       missing-impl error fires and propagates transitively).  They are
       DELIBERATELY invisible to find_enclosing_dict / dict_pass: the marker runs
       before inference and never wraps these calls in EDictApp, so routing an
       inner method to a `$dict_<fn>_<slot>` param dict_pass never creates would
       crash at eval.  Inner methods in such bodies dispatch by runtime arg tag
       instead — full dict-threading is a deferred follow-up. *)
  method_constraints : (ident, (ident * int list) list) Hashtbl.t;
    (* Phase 69.x-e: interface-method name → its *own* method-level constraints
       (e.g. foldMap → [(Monoid,[m_id]); (Semigroup,[m_id])]), super-expanded,
       with scheme-level var ids.  Drives the leading dict params dict_pass adds
       to the method's bodies, the dict routes stamped on each call site's
       res_method_dicts, and the slot order all three sides agree on. *)
  method_dict_routes : (ident, (ident * int list) list) Hashtbl.t;
    (* Phase 69.x-e: like method_constraints but keyed by the *instantiated*
       constraint var ids as seen inside the method's default body, so
       find_enclosing_dict routes an in-body method ref (e.g. `empty`/`++` inside
       foldMap's default) to the enclosing method's `$dict_<method>_<slot>`. *)
  impl_dict_routes : (ident, (string * (ident * int list) list) list) Hashtbl.t;
    (* Phase 83/84: method name → per-impl `(impl_key, [(req_iface, ids)])` for
       each impl that defines the method and carries `requires`.  `ids` are the
       impl head's type-param ids as instantiated inside *this* impl's body, so
       find_enclosing_dict routes an in-body return-position ref (e.g. the element
       `arbitrary` inside `impl Arbitrary (List a) requires Arbitrary a`) to that
       impl method's `$dict_<method>_<slot>`.  Slots are impl-local (index within
       one impl's list); keyed per impl_key so a method defined by several impls
       doesn't collide and a REPL re-check replaces rather than accumulates. *)
  dict_app_usages : (ident * (ident * mono list) list * Ast.res_route list option ref * Ast.loc option * ident option) list ref;
    (* Phase 69.x: (fn_name, [(constraint_iface, instantiated_args)] in slot order,
       EDictApp_routes_ref, call_site_loc, enclosing_fn).  Recorded at each
       constrained-function occurrence; resolve_dict_apps turns each constraint
       into an RKey/RDict route.  enclosing_fn (Phase 136) is the top-level member
       whose body holds the occurrence — used to pick the right enclosing dict
       when merged mutual-recursion siblings share a constraint var id. *)
  recursive_promoted_usages : (ident * mono * Ast.res_route list option ref * Ast.loc option * ident option) list ref;
    (* Phase 115 (#2): a self-/mutually-recursive call to a *promoted* unsignatured
       wrapper (in env.promoted), inferred during Pass B before its fun_constraints
       entry is registered (post-inference).  The normal recorder would skip it
       (None branch) and its EDictApp routes would stay None → eval applies no dict
       → closure/mis-dispatch.  Defer it: store the live occurrence [mono] (whose
       discriminating TVar refs resolve once the body unifies) and the routes ref,
       then realize_recursive_dict_apps (run before resolve_dict_apps, once
       fun_constraints is populated) recovers each constraint's args from [mono] via
       find_tvar_in_mono and pushes a normal dict_app_usages entry — routing the
       recursive call's dict to the wrapper's own `$dict_<fn>_<slot>` param. *)
  constraint_obligations : (ident * mono list * Ast.loc option) list ref;
    (* (iface_name, mono_args, call_site_loc) accumulated at call sites, verified post-HM *)
  type_ctors    : (ident, ident list) Hashtbl.t;  (* type name → ctor names in order *)
  ctor_fields   : (ident, (ident * mono) list) Hashtbl.t;  (* named-field ctor → ordered (field, mono_ty) *)
  aliases       : (ident, ident list * Ast.ty) Hashtbl.t;  (* type alias name → (params, rhs) *)
  warnings        : string list ref;           (* accumulated warning messages *)
  mut_vars        : StringSet.t;               (* bindings declared with let mut *)
  locals          : StringSet.t;
    (* Phase 95: names bound by *local* binders inside `infer` (lambda / let /
       do-bind / pattern arms) — as opposed to top-level / imported bindings.
       The constraint-table lookups in the EVar branch (method_iface,
       fun_constraints, inferred_constraints) key off the bare name in global
       hashtables that are not scope-aware; a local that shadows a top-level or
       imported constrained name must NOT inherit its constraints.  Gate those
       lookups on `not (StringSet.mem x locals)`.  Locals never have legitimate
       entries in those tables (only process_letrec_group populates them, only
       for top-level groups), so the gate removes only spurious behavior. *)
  deprecated_fns  : (ident, string) Hashtbl.t; (* name → deprecation message *)
  must_use_fns    : (ident, unit) Hashtbl.t;   (* names whose return values must be used *)
  promoted        : (ident, unit) Hashtbl.t;
    (* Phase 84: names of unsignatured bindings whose *inferred* constraints
       should be made dict-routable on this pass — registered in fun_constraints
       (not inferred_constraints) so find_enclosing_dict / dict_pass thread a
       dictionary into the body.  Empty on pass 1 (discovery) and on the
       single-pass callers (LSP / diagnostics); populated on pass 2 of the
       two-pass elaboration with the names pass 1 found in inferred_constraints,
       so a polymorphic-monad do-block's `pure` routes by the caller's monad
       instead of arg-tag "first impl wins". *)
}

let empty_env () = {
  vars          = [];
  ctors         = Hashtbl.create 16;
  records       = Hashtbl.create 8;
  field_owners  = Hashtbl.create 16;
  interfaces    = Hashtbl.create 8;
  method_iface  = Hashtbl.create 16;
  standalone_values = Hashtbl.create 8;
  impls         = ref [];
  method_usages = ref [];
  fun_constraints        = Hashtbl.create 8;
  inferred_constraints   = Hashtbl.create 8;
  method_constraints     = Hashtbl.create 8;
  method_dict_routes     = Hashtbl.create 8;
  impl_dict_routes       = Hashtbl.create 8;
  constraint_obligations = ref [];
  dict_app_usages        = ref [];
  recursive_promoted_usages = ref [];
  type_ctors    = Hashtbl.create 8;
  ctor_fields   = Hashtbl.create 4;
  aliases       = Hashtbl.create 4;
  warnings        = ref [];
  mut_vars        = StringSet.empty;
  locals          = StringSet.empty;
  deprecated_fns  = Hashtbl.create 8;
  must_use_fns    = Hashtbl.create 8;
  promoted        = Hashtbl.create 8;
}

let lookup_var env x =
  try List.assoc x env.vars
  with Not_found -> fail (UnboundVar x)

let extend_var env x s = { env with vars = (x, s) :: env.vars }

let extend_vars env bindings =
  List.fold_left (fun e (n, s) -> extend_var e n s) env bindings

(* Phase 95: mark names as locally-bound (lambda/let/do-bind/pattern binders),
   so the EVar branch's bare-name constraint-table lookups skip them — a local
   that shadows a top-level/imported constrained name must not inherit its
   constraints.  Use this at *body-local* binder sites in `infer`, never for the
   top-level driver's extend_var calls. *)
let mark_locals env names =
  { env with locals = List.fold_left (fun s n -> StringSet.add n s) env.locals names }

(* Extend env with local bindings AND register them as locals. *)
let extend_locals env bindings =
  mark_locals (extend_vars env bindings) (List.map fst bindings)

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
     | Some (params, _) ->
       (* A parametric alias used bare (zero args) is under-applied. *)
       raise (Type_error (TypeAliasArity (n, List.length params, 0), None))
     | None -> t)
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
              | Ast.TyEffect (es, tl, u) -> Ast.TyEffect (es, tl, apply_subst s u)
              | Ast.TyConstrained (cs, u) ->
                Ast.TyConstrained (
                  List.map (fun (iface, as_) -> (iface, List.map (apply_subst s) as_)) cs,
                  apply_subst s u)
            in
            expand_aliases ~seen:seen' aliases (apply_subst subst rhs)
        | Some (params, _) ->
          (* Known alias applied to the wrong number of arguments: a partially-
             applied (or over-applied) alias would otherwise be left as a raw
             TyApp and surface later as a confusing TCon mismatch. *)
          raise (Type_error
            (TypeAliasArity (n, List.length params, List.length args), None))
        | None ->
          List.fold_left (fun acc arg -> Ast.TyApp (acc, arg)) (go head) args)
     | other ->
       List.fold_left (fun acc arg -> Ast.TyApp (acc, arg)) (go other) args)
  | Ast.TyFun (a, b)    -> Ast.TyFun (go a, go b)
  | Ast.TyTuple ts       -> Ast.TyTuple (List.map go ts)
  | Ast.TyEffect (es, tl, u) -> Ast.TyEffect (es, tl, go u)
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
let from_ast_type ?(aliases=Hashtbl.create 0) ?(tbl=Hashtbl.create 4)
                  ?(etbl=Hashtbl.create 4) t =
  let t = expand_aliases aliases t in
  let env = tbl in
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
      let bm = match b with Ast.TyEffect (_, _, t) -> go t | t -> go t in
      TFun (go a, ast_effrow etbl b, bm)
    | Ast.TyTuple ts -> TTuple (List.map go ts)
    | Ast.TyEffect (_, _, t) -> go t
    | Ast.TyConstrained (_, inner) -> go inner  (* constraints handled by from_ast_type_with_constraints *)
  in
  go t

(* Like from_ast_type, but also extracts constraint annotations from TyConstrained.
   Uses a shared TVar table so constraint type-variable names (e.g. the `a` in
   `Eq a`) map to the same fresh TVar as the same name in the inner function type. *)
let from_ast_type_with_constraints ?(aliases=Hashtbl.create 0) ast_ty =
  let ast_ty = expand_aliases aliases ast_ty in
  let tbl = Hashtbl.create 4 in
  let etbl = Hashtbl.create 4 in
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
      let bm = match b with Ast.TyEffect (_, _, t) -> go t | t -> go t in
      TFun (go a, ast_effrow etbl b, bm)
    | Ast.TyTuple ts          -> TTuple (List.map go ts)
    | Ast.TyEffect (_, _, t)  -> go t
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
   only for syntactic specials (Bool literals, List's [] / (::) sugar; the
   synthetic per-arity __tupleN__ singletons are recognized in the exhaust
   oracle by name, not pre-registered). *)
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
  Hashtbl.replace env.type_ctors "Unit"      ["Unit"];
  (* Generalize: vars are now at level 1, current_level = 0, so they get quantified *)
  Hashtbl.filter_map_inplace
    (fun _name s ->
       match s with
       | Forall (_, _, t) -> Some (generalize t))
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
       | Link _ -> fail (InternalError "instantiate_record: Link survived normalize"))
    | TCon _ as t -> t
    | TApp (a, b)  -> TApp (walk a, walk b)
    | TFun (a, effs, b) -> TFun (walk a, effs, walk b)
    | TTuple ts    -> TTuple (List.map walk ts)
  in
  let result = walk info.rec_result in
  let fields = List.map (fun (n, t) -> (n, walk t)) info.rec_fields in
  (result, fields)

(* The head type-constructor of a mono, peeling the TApp spine: `Result e` →
   "Result", `Int` → "Int", a bare TVar → None.  Mirrors eval's AST `head_tycon`
   so the string a `RHeadKey` carries matches the head tag eval stamps on a
   `VTypedImpl`. *)
let rec head_tycon_mono m = match normalize m with
  | TCon n -> Some n
  | TApp (a, _) -> head_tycon_mono a
  | _ -> None

(* Phase 112: does any registered impl of [iface_name] cover a receiver whose
   head tycon is [recv_head]?  Only single-param interfaces participate (one
   element in impl_type_mono), so the head tycon alone discriminates — the same
   granularity eval's RHeadKey dispatch and `try_head_key` use.  Drives the
   method-head application arm in `infer`: when this is false for a concrete
   receiver and the method name also has a standalone binding, the call routes
   to the standalone instead of failing `NoImplFound`. *)
let impl_exists_for_head env iface_name recv_head =
  List.exists (fun e ->
    e.impl_iface = iface_name &&
    (match e.impl_type_mono with
     | [m] -> (match head_tycon_mono m with Some h -> h = recv_head | None -> false)
     | _   -> false)
  ) !(env.impls)

(* Phase 112: peel ELoc wrappers to expose an interface-method occurrence in
   function position (`toList`/`isEmpty` in `toList m`).  Returns the method
   occurrence's resolved-ref and its name when the head is one. *)
let rec peel_method_head = function
  | EMethodRef (r, x) -> Some (r, x)
  | ELoc (_, e)       -> peel_method_head e
  | _                 -> None

(* Phase 72: [field_owners] is a multimap (field name → every record that
   declares it).  Insert (field, record) only if absent so per-module prelude
   re-registration and export seeding stay idempotent. *)
let add_field_owner tbl field record =
  if not (List.mem record (Hashtbl.find_all tbl field)) then
    Hashtbl.add tbl field record

(* All records that declare [field], in unspecified order. *)
let field_candidates env field = Hashtbl.find_all env.field_owners field

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
    (* Arity check before unification: a constructor's instantiated type is a
       spine of arrows ending in its (non-function) result type, so the number
       of leading arrows is its arity.  Catching a wrong-arity pattern here
       gives a precise ArityMismatch instead of a confusing "T vs a -> b". *)
    let rec arrow_arity t = match normalize t with
      | TFun (_, _, r) -> 1 + arrow_arity r
      | _ -> 0
    in
    let expected_arity = arrow_arity ctor_t in
    let got_arity = List.length args in
    if got_arity <> expected_arity then
      fail (ArityMismatch (c, expected_arity, got_arity));
    let typed_args = List.map (type_pat env) args in
    let arg_types = List.map fst typed_args in
    let bindings  = List.concat_map snd typed_args in
    let result_t  = fresh_var () in
    let expected  = List.fold_right (fun at acc -> TFun (at, pure_row, acc))
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
         unify !result_t (TFun (ftype, pure_row, ret));
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

(* The constructor oracle that [Exhaust] needs for coverage analysis, backed by
   the typechecker's [env.type_ctors]/[env.ctors] (so it sees both user and
   prelude types).  The synthetic per-arity tuple constructors (`__tupleN__`,
   used both for the parameter-list/scrutinee wrapper and for genuine nested
   tuple patterns) are recognized by name via [Exhaust.tuple_arity_of_name], so
   their arity comes from the name rather than a side channel — distinct tuple
   widths are distinct singleton types (Phase 119).  Shared by the [EMatch]
   branch and [process_letrec_group]'s multi-clause check. *)
let exhaust_oracle env =
  let get_ctors tname =
    match Exhaust.tuple_arity_of_name tname with
    | Some _ -> Some [tname]
    | None   -> Hashtbl.find_opt env.type_ctors tname in
  let get_arity c =
    match Exhaust.tuple_arity_of_name c with
    | Some n -> n
    | None ->
      match Hashtbl.find_opt env.ctors c with
      | None -> (match c with "Cons" -> 2 | _ -> 0)
      | Some (Forall (_, _, t)) ->
        let rec count = function
          | TFun (_, _, r) -> 1 + count r
          | TVar v -> (match !v with Link t' -> count t' | _ -> 0)
          | _ -> 0
        in
        count t
  in
  let get_ctor_type c =
    match Exhaust.tuple_arity_of_name c with
    | Some _ -> Some c
    | None ->
      match Hashtbl.find_opt env.ctors c with
      | None ->
        (match c with
         | "Cons" | "Nil"   -> Some "List"
         | "True" | "False" -> Some "Bool"
         | "Unit"           -> Some "Unit"
         | _                -> None)
      | Some (Forall (_, _, t)) ->
        let rec result_type = function
          | TFun (_, _, r) -> result_type r
          | TApp (f, _) -> result_type f
          | TCon n      -> Some n
          | TVar v      -> (match !v with Link t' -> result_type t' | _ -> None)
          | _           -> None
        in
        result_type t
  in
  (get_ctors, get_arity, get_ctor_type)

let rec infer env = function
  | ELoc (l, e) ->
    current_loc := Some l;
    infer env e

  (* Phase 69: resolved method occurrence.  Stash the ref so the EVar method
     branch records it in method_usages; check_method_usages fills it with the
     resolved impl key once the call site's type args are ground. *)
  | EMethodRef (r, x) -> current_method_ref := Some r; infer env (EVar x)

  (* Phase 69.x: constrained-function occurrence.  Stash the routes ref so the
     EVar non-method branch records its per-constraint instantiated args in
     dict_app_usages; resolve_dict_apps fills the routes once the call site's
     constraint args are ground (RKey) or recognized as an enclosing function's
     constraint var (RDict). *)
  | EDictApp (r, x) -> current_dict_ref := Some r; infer env (EVar x)

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
      (* Phase 95: a locally-bound name shadowing a method/constrained-fn name
         is an ordinary variable — skip the scope-blind global tables. *)
      let is_local = StringSet.mem x env.locals in
      match (if is_local then None else Hashtbl.find_opt env.method_iface x) with
      | Some iface_name ->
        current_dict_ref := None;  (* a method name is never a constrained fn *)
        let info =
          try Hashtbl.find env.interfaces iface_name
          with Not_found -> fail (UnknownInterface iface_name)
        in
        (* Phase 103: type the method occurrence by its *interface* scheme, whose
           bound ids are info.iface_param_ids — not the scheme `lookup_var`
           returned, which may be a standalone top-level binding shadowing the
           method name (e.g. array.mdk's `empty : Array a` shadowing Monoid's
           `empty`). Instantiating the shadow scheme against Monoid's track_ids
           yields param_vars=[], so check_method_usages skips route-stamping and
           dispatch silently falls to the first impl. *)
        let method_scheme =
          match List.assoc_opt x info.iface_methods with
          | Some s -> s
          | None   -> scheme  (* defensive: a method_iface name should be here *)
        in
        let (t, param_vars, sub) = instantiate_method method_scheme info.iface_param_ids in
        let hint = !current_impl_hint in
        current_impl_hint := None;
        let mref = !current_method_ref in
        current_method_ref := None;
        (* Phase 69.x-e: this method's own method-level constraints, instantiated
           at this occurrence (one entry per slot, in method_constraints order).
           Emitted as obligations *and* carried on the usage so a post-pass can
           resolve each to a dict route (RKey/RDict) for res_method_dicts. *)
        let method_dict_args =
          match Hashtbl.find_opt env.method_constraints x with
          | None -> []
          | Some cs ->
            List.map (fun (iface, var_ids) ->
              (iface, List.filter_map (fun id -> List.assoc_opt id sub) var_ids)) cs
        in
        env.method_usages := (x, iface_name, param_vars, hint, method_dict_args, mref, !current_loc, !current_fn) :: !(env.method_usages);
        (* Emit obligations for any extra method-level constraints
           (e.g. the `Monoid m` in `foldMap : Monoid m => (a -> m) -> t a -> m`). *)
        List.iter (fun (iface, args) ->
          if args <> [] then
            env.constraint_obligations := (iface, args, !current_loc) :: !(env.constraint_obligations)
        ) method_dict_args;
        t
      | None ->
        current_method_ref := None;  (* not a method occurrence; don't leak the ref *)
        let dref = !current_dict_ref in
        current_dict_ref := None;
        let (sub, mono) = instantiate_raw scheme in
        (match (if is_local then None else Hashtbl.find_opt env.fun_constraints x) with
         | None ->
           (* Phase 83: an inferred-constrained callee records its obligations so
              the caller's missing-impl check fires (and propagates), but never a
              dict_app_usage — these have no dict route (see inferred_constraints). *)
           (match (if is_local then None else Hashtbl.find_opt env.inferred_constraints x) with
            | None -> ()
            | Some constraints ->
              let resolve_arg id =
                match List.assoc_opt id sub with
                | Some _ as r -> r
                | None -> find_tvar_in_mono mono id
              in
              List.iter (fun (iface, var_ids) ->
                let args = List.filter_map resolve_arg var_ids in
                if args <> [] then
                  env.constraint_obligations :=
                    (iface, args, !current_loc) :: !(env.constraint_obligations)
              ) constraints);
           (* Phase 115 (#2): a recursive call to a *promoted* unsignatured wrapper,
              inferred (Pass B) before its fun_constraints entry exists.  Its
              EDictApp routes would stay None → eval drops the dict → closure.
              Defer it with the live occurrence [mono]; realize_recursive_dict_apps
              recovers the args once fun_constraints is populated post-inference. *)
           (match dref with
            | Some r when (not is_local) && Hashtbl.mem env.promoted x ->
              env.recursive_promoted_usages :=
                (x, mono, r, !current_loc, !current_fn) :: !(env.recursive_promoted_usages)
            | _ -> ())
         | Some constraints ->
           (* Map a constraint's tyvar id to its type at this occurrence.  For a
              normal (generalized) callee that's the fresh instantiation var from
              `sub`.  For a self/mutual-recursive call the callee is the group's
              monomorphic placeholder, so `sub` is empty and the constraint var
              is one of the *enclosing* function's own live tyvars — recover it
              from `mono` so resolve_dict_apps routes it to that function's own
              dictionary (RDict) instead of dropping it (Phase 74 follow-up). *)
           let resolve_arg id =
             match List.assoc_opt id sub with
             | Some _ as r -> r
             | None -> find_tvar_in_mono mono id
           in
           List.iter (fun (iface, var_ids) ->
             let args = List.filter_map resolve_arg var_ids in
             if args <> [] then
               env.constraint_obligations := (iface, args, !current_loc) :: !(env.constraint_obligations)
           ) constraints;
           (* Phase 69.x: if this occurrence was wrapped in an EDictApp, record
              the per-constraint instantiated args (one entry per constraint, in
              slot order) so resolve_dict_apps can fill the routes ref.  Slot
              order must match dict_pass's parameter order — both iterate this
              same fun_constraints list. *)
           (match dref with
            | None -> ()
            | Some r ->
              let per_constraint = List.map (fun (iface, var_ids) ->
                (iface, List.filter_map resolve_arg var_ids))
                constraints in
              env.dict_app_usages :=
                (x, per_constraint, r, !current_loc, !current_fn) :: !(env.dict_app_usages)));
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

  (* Phase 112: an interface method applied directly to a single argument
     (`toList m` / `isEmpty m`).  If that method's name ALSO has an explicitly-
     imported/local standalone binding (`env.standalone_values`) and the concrete
     receiver's type has NO impl of the interface, type the call against the
     standalone and route eval to it (RLocal) — instead of dispatching through
     the interface and failing `NoImplFound`.  Scoped to single-parameter
     interfaces where the sole argument is the receiver; everything else (impl
     exists, polymorphic receiver, hinted call, multi-arg method) falls through
     to ordinary method dispatch, byte-identical to the generic arm below. *)
  | EApp (f, x)
    when (match peel_method_head f with
          | Some (_, mname) ->
            not (StringSet.mem mname env.locals) &&
            Hashtbl.mem env.standalone_values mname &&
            (match Hashtbl.find_opt env.method_iface mname with
             | Some iface_name ->
               (match Hashtbl.find_opt env.interfaces iface_name with
                | Some info -> List.length info.iface_param_ids = 1
                | None -> false)
             | None -> false)
          | None -> false) ->
    let (mref, mname) = (match peel_method_head f with Some p -> p | None -> assert false) in
    let iface_name = Hashtbl.find env.method_iface mname in
    (* Infer the receiver first so we know whether an impl applies. *)
    let tx = infer env x in
    (match head_tycon_mono tx with
     | Some recv_head when not (impl_exists_for_head env iface_name recv_head) ->
       (* Fallback: no impl for this concrete receiver → use the standalone. *)
       let (_, mono) = instantiate_raw (lookup_var env mname) in
       let tr  = fresh_var () in
       let eff = open_row () in
       unify mono (TFun (tx, eff, tr));
       perform_effect cur_effect eff;
       mref := Some { Ast.res_iface = iface_name; res_route = Ast.RLocal;
                      res_method_dicts = []; res_impl_dicts = [] };
       tr
     | _ ->
       (* Impl exists, or receiver head not concrete → ordinary method dispatch.
          Infer the method head now so it records its method_usage. *)
       let tf  = infer env f in
       let tr  = fresh_var () in
       let eff = open_row () in
       unify tf (TFun (tx, eff, tr));
       perform_effect cur_effect eff;
       tr)

  | EApp (f, x) ->
    let tf = infer env f in
    let tx = infer env x in
    let tr = fresh_var () in
    let eff = open_row () in
    unify tf (TFun (tx, eff, tr));
    (* applying f to x performs f's latent (arrow) effect in the current context *)
    perform_effect cur_effect eff;
    tr

  | ELam (pats, body) ->
    let typed_pats = List.map (type_pat env) pats in
    let pat_types  = List.map fst typed_pats in
    let bindings   = List.concat_map snd typed_pats in
    let env' = extend_locals env bindings in
    (* The body's latent effect becomes this lambda's arrow effect; building the
       closure itself performs nothing, so save/restore the enclosing ambient. *)
    let saved = !cur_effect in
    cur_effect := open_row ();
    let tb = infer env' body in
    let body_eff = !cur_effect in
    cur_effect := saved;
    arrows_with_last_effect pat_types body_eff tb

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
       let env_self = mark_locals (extend_var env x (monotype placeholder)) [x] in
       let t1 = infer env_self e1 in
       unify placeholder t1;
       exit_level ();
       let s = generalize t1 in
       let env' = mark_locals (extend_var env x s) [x] in
       let env' = if mut then { env' with mut_vars = StringSet.add x env'.mut_vars } else env' in
       infer env' e2
     | _ ->
       enter_level ();
       let t1 = infer env e1 in
       exit_level ();
       (match pat with
        | PVar x ->
          let s = gen_restricted (is_nonexpansive e1) t1 in
          let env' = mark_locals (extend_var env x s) [x] in
          let env' = if mut then { env' with mut_vars = StringSet.add x env'.mut_vars } else env' in
          infer env' e2
        | _ ->
          (* Non-trivial pattern: no generalization (value restriction-like) *)
          let tp, bindings = type_pat env pat in
          unify tp t1;
          infer (extend_locals env bindings) e2))

  | ELetGroup (bindings, body) ->
    enter_level ();
    let placeholders = List.map (fun (n, _) -> (n, fresh_var ())) bindings in
    let env' = mark_locals
      (List.fold_left (fun e (n, t) -> extend_var e n (monotype t)) env placeholders)
      (List.map fst placeholders) in
    List.iter (fun (n, clauses) ->
      let ph = List.assoc n placeholders in
      List.iter (fun clause ->
        unify (infer env' (clause_to_expr clause)) ph
      ) clauses
    ) bindings;
    exit_level ();
    (* Generalize per binding by value restriction: a binding with parameters
       is a function (value); a zero-arg binding is gated on its RHS. *)
    let env'' = List.fold_left (fun e (n, clauses) ->
      let t = List.assoc n placeholders in
      let is_val =
        List.for_all (fun (pats, rhs) -> pats <> [] || is_nonexpansive rhs) clauses in
      mark_locals (extend_var e n (gen_restricted is_val t)) [n]) env bindings in
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
    (* Negation is a `Num a` operation (dispatches to Num.negate), so it works
       for Int, Float, and any user Num impl — not Int-only. *)
    let a = fresh_var () in
    let r = match a with TVar r -> r | _ -> fail (InternalError "fresh_var did not yield a TVar") in
    unify te a;
    env.method_usages :=
      ("negate", "Num", [r], None, [], None, !current_loc, !current_fn) :: !(env.method_usages);
    a
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
      let env' = extend_locals env bindings in
      (* Thread guard qualifiers left-to-right; pattern binds extend the env
         for later qualifiers and the body. *)
      let env_body = List.fold_left (fun env_cur q ->
        match q with
        | GBool g -> unify (infer env_cur g) t_bool; env_cur
        | GBind (p, e) ->
          let te = infer env_cur e in
          let tp', binds = type_pat env_cur p in
          unify tp' te;
          extend_locals env_cur binds
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
        (* Tuples have no TCon head; treat them as a synthetic per-arity
           singleton type whose arity is the scrutinee's tuple width. *)
        (match follow tsc with
         | TTuple ts -> Some (Exhaust.tuple_ctor_name (List.length ts))
         | _         -> None)
    in
    let (get_ctors, get_arity, get_ctor_type) = exhaust_oracle env in
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

  | EMapLit _ ->
    fail (InternalError "EMapLit survived desugar (Phase 108)")

  | ESetLit _ ->
    fail (InternalError "ESetLit survived desugar (Phase 108)")

  | EStringInterp parts ->
    List.iter (function
      | InterpStr _  -> ()
      | InterpExpr e -> unify (infer env e) (TCon "String")
    ) parts;
    TCon "String"

  | EAnnot (e, ast_t) ->
    let te = infer env e in
    let tbl = Hashtbl.create 4 in
    let ta = from_ast_type ~aliases:env.aliases ~tbl ast_t in
    unify te ta;
    (* Skolemization-by-identity check: each type variable named in the
       annotation asserts polymorphism, so after unification it must still be a
       *distinct, unbound* variable.  If one ground to a concrete type, or two
       annotation variables collapsed to the same variable, the expression is
       less polymorphic than the annotation claims — e.g. `(intId : a -> a)`
       where intId : Int -> Int grounds `a := Int`.  (Equivalent to skolemizing
       the annotation vars and checking none escaped to a non-variable.) *)
    let resolved = Hashtbl.fold (fun _ v acc -> normalize v :: acc) tbl [] in
    let rec all_distinct_tvars seen = function
      | [] -> true
      | TVar r :: rest ->
        if List.memq r seen then false else all_distinct_tvars (r :: seen) rest
      | _ -> false
    in
    if not (all_distinct_tvars [] resolved) then
      fail (AnnotationTooGeneral ast_t);
    te

  | EHeadAnnot (e, ast_t) ->
    (* Phase 108: like EAnnot but WITHOUT the skolemization-by-identity check —
       the pin's type variables are *meant* to ground (the literal's element
       types).  It fixes only the head tycon of `e`'s type to the named
       container, which is what lets `fromEntries`'s return-position dispatch
       resolve to that container's impl.

       Phase 114: ignore the *arity* the lowering happened to supply and apply
       the head tycon to its *declared* arity of fresh vars.  The parser can't
       tell empty `Map { }` from `Set { }` (no `=>` marker → both lower to a
       unary `ESetLit name []` pin), so for `Map { }` the supplied `Map _a` is
       the wrong arity and fails to unify with `Map k v`.  Looking the arity up
       by the head tycon makes empty literals work regardless of the lowering's
       guess; element vars stay free and ground via inference as before. *)
    let te = infer env e in
    (* Peel TyApp down to the leftmost TyCon — the head tycon name. *)
    let rec head_tycon = function
      | Ast.TyApp (f, _) -> head_tycon f
      | Ast.TyCon n      -> Some n
      | _                -> None
    in
    (* Declared arity of a tycon, read off any of its constructors' result
       type: strip the ctor-argument arrows, then count TApp nesting on the
       head.  All ctors of a type share the same result head/arity. *)
    let tycon_arity name =
      match Hashtbl.find_opt env.type_ctors name with
      | Some (cn :: _) ->
        (match Hashtbl.find_opt env.ctors cn with
         | Some (Forall (_, _, t)) ->
           let rec strip_fun = function TFun (_, _, r) -> strip_fun r | t -> t in
           let rec app_arity = function
             | TApp (f, _)             -> 1 + app_arity f
             | TVar { contents = Link t } -> app_arity t
             | _                       -> 0
           in
           Some (app_arity (strip_fun t))
         | None -> None)
      | _ -> None
    in
    let ta =
      match head_tycon ast_t with
      | Some name ->
        (match tycon_arity name with
         | Some n ->
           let rec build acc k =
             if k = 0 then acc else build (TApp (acc, fresh_var ())) (k - 1) in
           build (TCon name) n
         | None -> from_ast_type ~aliases:env.aliases ~tbl:(Hashtbl.create 4) ast_t)
      | None -> from_ast_type ~aliases:env.aliases ~tbl:(Hashtbl.create 4) ast_t
    in
    unify te ta;
    te

  | EInfix (op, l, r) ->
    let tf = instantiate (lookup_var env op) in
    let tl = infer env l in
    let tr = infer env r in
    let result = fresh_var () in
    let eff1 = open_row () in
    let eff2 = open_row () in
    unify tf (TFun (tl, eff1, TFun (tr, eff2, result)));
    (* `a `f` b` is `f a b`: applying op to both args performs each arrow's
       latent effect in the current context, mirroring the EApp arm. *)
    perform_effect cur_effect eff1;
    perform_effect cur_effect eff2;
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
      | EDictApp (_, x) -> Some x
      | EApp (f, _) -> head_fn_name f
      | _ -> None
    in
    let rec type_block env = function
      | [] -> fail (InternalError "type_block: empty block (should be guarded earlier)")
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
            let env' = mark_locals (extend_var env x (gen_restricted (is_nonexpansive e) t1)) [x] in
            if mut then { env' with mut_vars = StringSet.add x env'.mut_vars } else env'
          | _ ->
            let tp, bindings = type_pat env pat in
            unify tp t1;
            extend_locals env bindings
        in
        type_block env' rest
      | DoAssign (x, e) :: rest ->
        let tx = instantiate (lookup_var env x) in
        let te = infer env e in
        unify tx te;
        if not (StringSet.mem x env.mut_vars) then
          fail (ImmutableAssignment x);
        (* Reassigning a `let mut` binding is a mutation. *)
        perform_effect cur_effect (closed_row ["Mut"]);
        type_block env rest
      | DoFieldAssign (x, fields, e) :: rest ->
        if not (StringSet.mem x env.mut_vars) then
          fail (ImmutableAssignment x);
        (* Resolve one field off a record / Ref type, returning the field's type.
           Folded over the path so `a.b.c` walks record→record→field. *)
        let field_type_of t field =
          match normalize t with
          | TApp (TCon "Ref", inner) when field = "value" -> inner
          | TCon r | TApp (TCon r, _) ->
            (match Hashtbl.find_opt env.records r with
             | None -> fail (UnknownRecord r)
             | Some info ->
               let (_result_t, field_types) = instantiate_record info in
               (match List.assoc_opt field field_types with
                | None -> fail (UnknownField (field, r))
                | Some ft -> ft))
          | _ -> fail (NotARecord x)
        in
        let tx = instantiate (lookup_var env x) in
        let field_t = List.fold_left field_type_of tx fields in
        let te = infer env e in
        unify field_t te;
        (* Mutating a record field / Ref cell is a mutation. *)
        perform_effect cur_effect (closed_row ["Mut"]);
        type_block env rest
      | DoLetElse (pat, e, alt) :: rest ->
        let te = infer env e in
        let tp, bindings = type_pat env pat in
        unify tp te;
        let _ = infer env alt in
        type_block (extend_locals env bindings) rest
    in
    type_block env stmts

  | EDo _ ->
    (* Phase 99: monadic do-blocks are lowered to nested andThen/pure by
       Desugar.lower_do_blocks (before method_marker + typecheck), so the
       Thenable obligation now rides the lowered `andThen`'s constraint and
       bind dispatch flows through the normal dictionary elaboration.  An EDo
       reaching typecheck means the desugar pass was skipped — a pipeline bug. *)
    fail (InternalError "EDo survived desugar (Phase 99)")

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
         unify !result_t (TFun (ftype, pure_row, ret));
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
    let nte = normalize te in
    (* Special case: (Ref a).value → a *)
    (match nte, field with
     | TApp (TCon "Ref", inner), "value" -> inner
     | _ ->
       (* Resolve [field] inside a known record: instantiate, unify the receiver
          against it, return the field's type. *)
       let resolve_in record_name =
         let info =
           try Hashtbl.find env.records record_name
           with Not_found -> fail (UnknownRecord record_name)
         in
         let (result_t, field_types) = instantiate_record info in
         unify te result_t;
         (try List.assoc field field_types
          with Not_found -> fail (UnknownField (field, record_name)))
       in
       (* Phase 72: resolve by the receiver's inferred record type when known;
          otherwise fall back to the field's candidate owners. *)
       (match head_tycon_mono nte with
        | Some r when Hashtbl.mem env.records r -> resolve_in r
        | _ ->
          (match nte with
           | TVar { contents = Unbound _ } ->
             (match field_candidates env field with
              | []  -> fail (UnknownField (field, "<unknown>"))
              | [r] -> resolve_in r
              | rs  -> fail (AmbiguousField (field, List.sort_uniq compare rs)))
           | _ ->
             (* Receiver is a concrete non-record type: unify against any
                candidate so the existing TypeMismatch surfaces. *)
             (match field_candidates env field with
              | []     -> fail (UnknownField (field, "<unknown>"))
              | r :: _ -> resolve_in r)))
    )

  | ERecordUpdate (e, updated) ->
    let te = infer env e in
    if updated = [] then te
    else begin
      let resolve_in record_name =
        let info =
          try Hashtbl.find env.records record_name
          with Not_found -> fail (UnknownRecord record_name)
        in
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
      in
      let first_field = fst (List.hd updated) in
      let nte = normalize te in
      (match head_tycon_mono nte with
       | Some r when Hashtbl.mem env.records r -> resolve_in r
       | _ ->
         (match nte with
          | TVar { contents = Unbound _ } ->
            (match field_candidates env first_field with
             | []  -> fail (UnknownField (first_field, "<unknown>"))
             | [r] -> resolve_in r
             | rs  -> fail (AmbiguousField (first_field, List.sort_uniq compare rs)))
          | _ ->
            (match field_candidates env first_field with
             | []     -> fail (UnknownField (first_field, "<unknown>"))
             | r :: _ -> resolve_in r)))
    end

  | EIndex (arr, idx) ->
    let ta = infer env arr in
    unify (infer env idx) t_int;
    (* Index preserves container element type: Array a -> a, List a -> a, and
       String -> Char (codepoint, Phase 77).  Branch on the normalized head like
       ESlice does, rather than a single destructive unify against Array. *)
    let elem = fresh_var () in
    (match normalize ta with
     | TCon "String"          -> t_char                  (* String -> Char *)
     | TApp (TCon "Array", _) -> unify ta (t_array elem); elem
     | TApp (TCon "List", _)  -> unify ta (t_list elem); elem
     | TVar _ -> unify ta (t_array elem); elem           (* undetermined: default Array *)
     | _      -> unify ta (t_array elem); elem)          (* clean Array mismatch *)

  (* The following node shapes are removed by the desugar pass before typecheck;
     reaching one means the desugar pass was skipped (a pipeline-wiring bug), so
     surface a diagnostic rather than crashing with Assert_failure. *)
  | EListComp _ ->
    fail (InternalError "EListComp reached typecheck — desugar pass was not run")

  | EGuards _ | EFunction _ | ESection _ ->
    fail (InternalError "guard/function/section reached typecheck — desugar pass was not run")

  | EQuestion _ ->
    fail (InternalError "EQuestion reached typecheck — desugar pass was not run")

  | EAsPat _ ->
    (* Valid as-patterns are lowered to PAs by the parser; a surviving EAsPat is
       a misplaced as-pattern that resolve already rejected (so typecheck is
       skipped for such programs). *)
    fail (InternalError "EAsPat reached typecheck — should be lowered to PAs or rejected by resolve")

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
    (* Slice preserves container type: Array a, List a, or String.  Branch on
       the normalized container type rather than trying destructive unifications
       in a `try ... with _` cascade: a failed trial unify left `te` partially
       mutated and the catch-all swallowed non-unification exceptions too.  Here
       the single unify per branch only refines the element type and cannot fail
       on the head; the non-container case produces one clean mismatch. *)
    let elem = fresh_var () in
    (match normalize te with
     | TCon "String"            -> te
     | TApp (TCon "Array", _)   -> unify te (t_array elem); te
     | TApp (TCon "List", _)    -> unify te (t_list elem); te
     | TVar _ ->
       (* Container type not yet determined; default to Array (a slice most
          often targets an array).  A wrong guess surfaces as an ordinary
          mismatch where the value is later used at a different type. *)
       unify te (t_array elem); te
     | _ ->
       (* Not a sliceable container: report a clean mismatch against one of the
          three valid container types instead of a corrupted-state type. *)
       unify te t_string; te)

and binop_type env op l r =
  let tl = infer env l in
  let tr = infer env r in
  (* Record a usage of `method` (an entry from Builtins.operator_iface) at the
     type variable [r], so check_method_usages can verify that a matching impl
     exists once [r] is grounded.  Returns [r] wrapped back as a TVar's ref. *)
  let record_iface_usage iface_name method_name tl tr =
    let a = fresh_var () in
    let r = match a with TVar r -> r | _ -> fail (InternalError "fresh_var did not yield a TVar") in
    unify tl a; unify tr a;
    env.method_usages := (method_name, iface_name, [r], None, [], None, !current_loc, !current_fn) :: !(env.method_usages);
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
    (* Modulo is not a distinct Num method, but it requires its operands to be a
       numeric type; recording a `Num a` usage lets it work on Int and Float
       (and any user Num impl) instead of being Int-only.  The method name is
       ignored by constraint resolution, which keys on the interface. *)
    record_iface_usage "Num" "mod" tl tr
  | "&&" | "||" ->
    unify tl t_bool; unify tr t_bool; t_bool
  | "::" ->
    unify tr (t_list tl); tr
  | "++" ->
    let (i, m) = iface_and_method_of op in record_iface_usage i m tl tr
  | "|>" ->
    (* x |> f  :  a -> (a -> b) -> b *)
    let b = fresh_var () in
    unify tr (TFun (tl, open_row (), b)); b
  | ">>" ->
    (* f >> g  :  (a -> b) -> (b -> c) -> (a -> c) *)
    let a = fresh_var () in
    let b = fresh_var () in
    let c = fresh_var () in
    unify tl (TFun (a, open_row (), b)); unify tr (TFun (b, open_row (), c)); TFun (a, open_row (), c)
  | "<<" ->
    (* f << g  :  (b -> c) -> (a -> b) -> (a -> c) *)
    let a = fresh_var () in
    let b = fresh_var () in
    let c = fresh_var () in
    unify tl (TFun (b, open_row (), c)); unify tr (TFun (a, open_row (), b)); TFun (a, open_row (), c)
  | _ ->
    fail (Other ("Unknown binop: " ^ op))

(* ── Top-level processing ───────────────────────── *)

(* Reorder top-level groups so that a group's *non-cyclic* callees are processed
   (and generalized) before it.

   Why this matters (see PLAN-ARCHIVE.md §2.9): every top-level name is pre-bound as a
   monomorphic placeholder var, and a forward reference to a not-yet-processed
   name unifies with that placeholder rather than instantiating a real scheme.
   That is the right treatment for genuine mutual recursion, but for a plain
   forward reference (caller defined before a callee it does not recurse with)
   it shares a live inference var between the caller's body and the callee's
   placeholder.  Once the caller is generalized and the callee is later unified
   against its own signature, that shared var can be re-linked underneath the
   caller's *already-generalized* scheme — silently monomorphizing a polymorphic
   HOF (e.g. `sortBy` getting pinned to a tuple element type by an unrelated
   `sortOn`-style use).  Processing callees first means the caller instantiates a
   proper generalized scheme and never shares the placeholder.

   True mutual-recursion cycles can't be linearized, so we keep each SCC's
   members adjacent and in source order: their existing placeholder-based
   handling is unchanged.  References are over-approximated (every
   EVar/EMethodRef/EDictApp name, ignoring shadowing) — a spurious edge can only
   merge groups into a larger SCC (falling back to today's behavior), never
   produce a wrong type.  Tarjan emits SCCs in reverse-topological order, i.e.
   dependencies-first, which is exactly the order we want. *)
let order_groups_by_deps groups =
  let arr = Array.of_list groups in
  let n = Array.length arr in
  if n <= 1 then groups else begin
    (* name -> index of the group that defines it *)
    let owner = Hashtbl.create 256 in
    Array.iteri (fun i (_, members) ->
      List.iter (fun (name, _, _) -> Hashtbl.replace owner name i) members) arr;
    (* deps.(i) = sorted list of group indices group i references (i excluded) *)
    let deps = Array.map (fun (_, members) ->
      let s = ref [] in
      let note j = if not (List.mem j !s) then s := j :: !s in
      List.iter (fun (_, _, clauses) ->
        List.iter (fun (_pats, body) ->
          ignore (Desugar.map_expr (fun e ->
            (match e with
             (* EInfix carries its callee as the operator *string* (backtick
                infix `a `f` b` looks `f` up as an ordinary value — see infer),
                so it is a real dependency edge too.  Missing it left a signed
                recursive HOF (`sortBy cmp xs = … `helper` …`) sharing a live
                placeholder with its callee, so a later tuple-typed use
                monomorphized it — the §2.9 bug, surfacing only through backtick
                infix (Phase 90 residual). *)
             | EVar x | EMethodRef (_, x) | EDictApp (_, x) | EInfix (x, _, _) ->
               (match Hashtbl.find_opt owner x with Some j -> note j | None -> ())
             | _ -> ());
            e) body)
        ) clauses
      ) members;
      List.sort compare !s
    ) arr in
    (* Tarjan's strongly-connected-components. *)
    let index = Array.make n (-1) in
    let lowlink = Array.make n 0 in
    let onstack = Array.make n false in
    let stack = ref [] in
    let counter = ref 0 in
    let out = ref [] in
    let rec strongconnect v =
      index.(v) <- !counter; lowlink.(v) <- !counter; incr counter;
      stack := v :: !stack; onstack.(v) <- true;
      List.iter (fun w ->
        if w = v then ()
        else if index.(w) = -1 then begin
          strongconnect w;
          lowlink.(v) <- min lowlink.(v) lowlink.(w)
        end else if onstack.(w) then
          lowlink.(v) <- min lowlink.(v) index.(w)
      ) deps.(v);
      if lowlink.(v) = index.(v) then begin
        let scc = ref [] in
        let stop = ref false in
        while not !stop do
          match !stack with
          | w :: rest ->
            stack := rest; onstack.(w) <- false; scc := w :: !scc;
            if w = v then stop := true
          | [] -> stop := true
        done;
        (* members in source order within the SCC *)
        out := List.sort compare !scc :: !out
      end
    in
    for v = 0 to n - 1 do
      if index.(v) = -1 then strongconnect v
    done;
    (* !out holds SCCs in reverse pop order; pop order is dependencies-first. *)
    let sccs = List.rev !out in
    (* A multi-member SCC is genuine mutual recursion: merge its groups into one
       so process_letrec_group infers every body and generalizes every member
       within a single level bracket.  Flattening them into sequential singletons
       (the old [concat_map]) re-links a quantified var of the first-processed
       member while inferring the second, demoting the first member's scheme to
       monomorphic — Phase 136 (this is exactly the §2.9 hazard above, which the
       callee-first reorder fixes for plain forward references but not for a true
       cycle).  A singleton SCC (incl. plain self-recursion) is returned
       unchanged.  [is_letrec] is the OR of the merged groups' flags: a
       DFunDef-only cycle stays [false], so value restriction and the
       LetRecNonFunction guard behave exactly as in the old singleton path. *)
    List.map (fun scc ->
      match List.map (fun i -> arr.(i)) scc with
      | [g] -> g
      | gs  -> (List.exists fst gs, List.concat_map snd gs)
    ) sccs
  end

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
  |> order_groups_by_deps

(* Flatten the grouped output for callers that just want a (name, sig, clauses) list. *)
let flatten_groups groups =
  List.concat_map snd groups

(* Phase 69.x: append the *direct* superinterface obligations of each constraint
   in [cs] as extra constraint entries, mapping each super's declaration param
   ids to this constraint's instantiated ids positionally.  Used so a body that
   calls a superinterface method (e.g. foldMap's default calls Semigroup's `++`
   while only `Monoid m` is declared) gets an honest super dict in its own slot.
   Appended after the declared constraints, so existing slot indices are
   unchanged, and de-duplicated.  One level deep — transitive supers fall out
   because each interface's own [iface_supers] already records its direct ones. *)
let expand_supers interfaces (cs : (ident * int list) list) : (ident * int list) list =
  let seen = Hashtbl.create 8 in
  List.iter (fun key -> Hashtbl.replace seen key ()) cs;
  let supers = List.concat_map (fun (iface, ids) ->
    match Hashtbl.find_opt interfaces iface with
    | Some info when List.length info.iface_param_ids = List.length ids ->
      let subst = List.combine info.iface_param_ids ids in
      List.filter_map (fun (super, super_decl_ids) ->
        let super_ids =
          List.filter_map (fun d -> List.assoc_opt d subst) super_decl_ids in
        if List.length super_ids = List.length super_decl_ids
        then Some (super, super_ids) else None
      ) info.iface_supers
    | _ -> []
  ) cs in
  let extra = List.filter (fun key ->
    if Hashtbl.mem seen key then false else (Hashtbl.replace seen key (); true)
  ) supers in
  cs @ extra

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
  (* Pass A: parse each member's signature, unify it into the placeholder, and
     PRE-REGISTER its fun_constraints entry *before* any body is inferred.  A
     self- or mutually-recursive constrained call in a body (Pass B) looks the
     callee up in fun_constraints to record its dictionary route and obligation;
     without this the group's own names aren't there yet (they were registered
     only after the bodies), so the recursive call silently dropped its
     dictionary — wrong arity / mis-dispatch at eval (Phase 74 follow-up).  The
     authoritative post-inference pass below replaces or clears this entry once
     the real generalized constraint set is known. *)
  let prepared = List.map (fun (name, sig_opt, clauses) ->
    let placeholder = List.assoc name placeholders in
    let (cs_monos, sig_t_opt) =
      match sig_opt with
      | None -> ([], None)
      | Some sig_ast ->
        let (cs, sig_t) = from_ast_type_with_constraints
                            ~aliases:(!env_ref).aliases sig_ast in
        unify placeholder sig_t;
        (cs, Some sig_t)
    in
    (* Mirror the post-inference registration below, minus its bound-ids filter
       (nothing is generalized yet): a top-level member generalizes all its arg
       tyvars, so the ids agree. *)
    let extract_id m = match normalize m with
      | TVar { contents = Unbound (id, _) } -> Some id
      | _ -> None in
    let pre_cs = List.filter_map (fun (iface, arg_monos) ->
      let ids = List.filter_map extract_id arg_monos in
      if ids <> [] then Some (iface, ids) else None) cs_monos in
    let pre_cs = expand_supers (!env_ref).interfaces pre_cs in
    if pre_cs <> [] then
      Hashtbl.replace (!env_ref).fun_constraints name pre_cs;
    (name, cs_monos, sig_t_opt, sig_opt, clauses)
  ) members in
  (* Pass B: infer the bodies now that every member's constraints are visible. *)
  (* Phase 83: snapshot the obligation *and* method-usage accumulators so the
     entries prepended while inferring this group's bodies can be harvested below.
     A constraint the body imposes comes from two sources: a call to another
     constrained function (constraint_obligations) or a direct interface-method
     call like `eq`/`debug` (method_usages, carrying the interface + its
     instantiated param vars).  When the discriminating var lands in a binding's
     generalized [bound_ids] the constraint is polymorphic in that scheme —
     inferred for an unsignatured binding, and checked for sufficiency against a
     declared signature. *)
  let obl_ref = (!env_ref).constraint_obligations in
  let oblig_n0 = List.length !obl_ref in
  let mu_ref = (!env_ref).method_usages in
  let mu_n0 = List.length !mu_ref in
  let cs_monos_list = List.map (fun (name, cs_monos, sig_t_opt, sig_opt, clauses) ->
    let placeholder = List.assoc name placeholders in
    (* Phase 136: mark this member as the enclosing function so a constrained
       self-/mutual-recursive call in its body captures it (find_enclosing_dict
       disambiguates merged siblings sharing one constraint var id by it). *)
    current_fn := Some name;
    if is_letrec then
      List.iter (fun (pats, rhs) ->
        if pats = [] && not (is_syntactic_lambda rhs) then begin
          current_loc := first_loc rhs;
          fail (LetRecNonFunction name)
        end
      ) clauses;
    (* Phase 79e: accumulate the concrete effects the body performs (across all
       clauses), for the binding-boundary escape check below. *)
    let inferred_eff = ref [] in
    let add_eff row =
      inferred_eff := List.sort_uniq String.compare (!inferred_eff @ effrow_labels row)
    in
    List.iter (fun (pats, body) ->
      let t =
        match sig_t_opt with
        | Some sig_t when pats <> [] ->
          (* Phase 73: signature-driven parameter typing (bidirectional check).
             Push the signature's argument types into the parameter patterns
             *before* inferring the body, so the body sees concrete parameter
             types — this lets a shared record field (`f : Point -> Int; f p =
             p.x`) and other type-directed expressions (`ESlice` container) be
             resolved by the signature alone.  Purely additive: the final
             `unify placeholder t` below imposes the same equalities anyway, so
             the solution is unchanged; we only make them available earlier.
             Mirrors the `ELam` branch (type the pats, extend the env, infer the
             body) plus the pre-unification against the peeled arrow domains. *)
          let typed_pats = List.map (type_pat !env_ref) pats in
          let pat_types  = List.map fst typed_pats in
          let bindings   = List.concat_map snd typed_pats in
          (* Peel up to one arrow per parameter.  A signature with fewer arrows
             than the clause has params (`f : Int; f x = …`) stops early and
             pushes nothing — the mismatch then surfaces at the final unify. *)
          let rec peel n t =
            if n = 0 then ([], t)
            else match normalize t with
              | TFun (a, _, b) -> let (args, ret) = peel (n - 1) b in (a :: args, ret)
              | _ -> ([], t)
          in
          let (sig_args, _sig_ret) = peel (List.length pats) sig_t in
          (* Unify the equal-length prefix; sig_args may be shorter than the
             parameter list (see above). *)
          let rec zip_unify ps qs = match ps, qs with
            | p :: ps', q :: qs' -> unify p q; zip_unify ps' qs'
            | _ -> ()
          in
          zip_unify pat_types sig_args;
          let saved = !cur_effect in
          cur_effect := open_row ();
          let body_t = infer (extend_locals !env_ref bindings) body in
          let body_eff = !cur_effect in
          cur_effect := saved;
          add_eff body_eff;
          arrows_with_last_effect pat_types body_eff body_t
        | Some _ ->
          (* Value binding (no parameters) with a signature: infer the body in a
             fresh ambient so its effects can be checked against the declared
             effect, then discard (a 0-arg binding has no arrow to carry it). *)
          let saved = !cur_effect in
          cur_effect := open_row ();
          let t = infer !env_ref (clause_to_expr (pats, body)) in
          add_eff !cur_effect;
          cur_effect := saved;
          t
        | None ->
          infer !env_ref (clause_to_expr (pats, body))
      in
      unify placeholder t
    ) clauses;
    (* Phase 79e: effect-escape check at the binding boundary, replacing the
       post-HM infer_and_check_effects pass.  An annotated binding's body must
       not perform a concrete effect its signature doesn't declare; effect
       *variables* (polymorphic `<e>`) carry no labels and so never escape. *)
    (match sig_opt with
     | Some sig_ast ->
       let declared = declared_effects sig_ast in
       let extras = List.filter (fun e -> not (List.mem e declared)) !inferred_eff in
       if extras <> [] then fail (EffectEscape (name, declared, extras))
     | None -> ());
    (* Value restriction (Phase 66): a let-rec member is always a function;
       a non-letrec zero-arg binding is gated on its RHS so e.g. `r = Ref []`
       is not over-generalized. *)
    (* Phase 89: a point-free *signed* binding whose declared type is a function
       (`maximum : (Foldable t, …) => t a -> Option a; maximum = fold step None`)
       is expansive (its RHS is an application) yet must be generalized per its
       signature, or one downstream use monomorphizes it and a second use at a
       different container type-errors (`Array vs List`).  This is sound where
       the binding's type is a function: a closure is immutable, and `generalize`
       still respects levels, so a *captured* monomorphic cell's var (at the base
       level) is not over-quantified.  The arrow guard is what preserves the
       classic protection — a non-function expansive binding like `r : Ref (List
       a); r = Ref []` keeps the value restriction and stays monomorphic. *)
    let plain_val = is_letrec
      || List.for_all (fun (pats, rhs) -> pats <> [] || is_nonexpansive rhs) clauses in
    let sig_is_fun = match sig_t_opt with
      | Some _ -> (match normalize placeholder with TFun _ -> true | _ -> false)
      | None -> false in
    let is_val = plain_val || sig_is_fun in
    (* [relaxed]: generalized *only* because of the Phase 89 point-free rule.
       Such a binding dispatches its body's methods (and its callers' obligations)
       by runtime arg tag, not dict passing — so its constraints go in
       inferred_constraints, not fun_constraints (see the registration below).
       The marker never filled an EDictApp route for it (the body's `fold` etc.
       carry no `$dict_<fn>_<slot>` param dict_pass would have to bind), so
       routing it through fun_constraints would crash at eval with an unbound
       `$dict_…` — exactly the inferred_constraints rationale from Phase 83. *)
    let relaxed = sig_is_fun && not plain_val in
    current_fn := None;
    (name, cs_monos, is_val, sig_opt <> None, relaxed)
  ) prepared in
  exit_level ();
  (* Phase 102: plain multi-clause exhaustiveness.  Every clause's bodies are
     inferred and unified above, so this is a purely read-only pass over the
     clause patterns — it never [fail]s, so it can't leak the level bracket we
     just exited.  Running here (rather than via [check_match]) covers every
     entry point at once: [check_program_impl], [typecheck_module], and the REPL
     all funnel through [process_letrec_group]. *)
  List.iter (fun (_name, _sig, clauses) ->
    match clauses with
    | [] -> ()
    | (pats0, _) :: _ ->
      let arity = List.length pats0 in
      if arity > 0 then begin
        let (get_ctors, get_arity, get_ctor_type) =
          exhaust_oracle !env_ref in
        let loc = match Exhaust.first_loc (snd (List.hd clauses)) with
          | Some l -> Some l
          | None   -> !current_loc in
        Exhaust.check_clauses ~get_ctors ~get_arity ~get_ctor_type
          ~warnings:(!env_ref).warnings ~loc ~arity
          (List.map fst clauses)
      end
  ) members;
  (* Phase 83: the obligations / method usages this group's bodies generated
     (prepended after the Pass-B snapshot above; new entries are at the front). *)
  let rec take n = function
    | x :: xs when n > 0 -> x :: take (n - 1) xs
    | _ -> []
  in
  let added_obligs  = take (List.length !obl_ref - oblig_n0) !obl_ref in
  let added_methods = take (List.length !mu_ref - mu_n0) !mu_ref in
  List.map (fun (name, cs_monos, is_val, has_sig, relaxed) ->
    let placeholder = List.assoc name placeholders in
    let scheme = gen_restricted is_val placeholder in
    (match scheme with
     | Forall (bound_ids, _, _) ->
       let extract_id m = match normalize m with
         | TVar {contents = Unbound (id, _)} when List.mem id bound_ids -> Some id
         | _ -> None
       in
       (* Constraints the body actually requires on *this* scheme's own
          quantified vars (Phase 83): an obligation/method-usage whose
          discriminating var lands in bound_ids is polymorphic here; concrete
          ones (no overlap) are left to the post-HM obligation/method passes. *)
       let body_cs =
         List.filter_map (fun (iface, mono_args, loc) ->
           let ids = List.filter_map extract_id mono_args in
           if ids = [] then None else Some (iface, ids, loc)
         ) added_obligs
         @ List.filter_map (fun (_m, iface_name, param_vars, _h, _mda, _mr, loc, _enc) ->
             let ids = List.filter_map (fun r -> extract_id (TVar r)) param_vars in
             if ids = [] then None else Some (iface_name, ids, loc)
           ) added_methods
       in
       (* Declared constraints (explicit signature) surviving generalization. *)
       let declared_cs =
         List.filter_map (fun (iface, arg_monos) ->
           let ids = List.filter_map extract_id arg_monos in
           if ids <> [] then Some (iface, ids) else None
         ) cs_monos
       in
       (* Phase 69.x-c: [expand_supers] appends a dictionary slot for each direct
          superinterface of a constraint (`when : Thenable m =>` body calls
          `pure`, an Applicative method — Thenable requires Applicative).  Making
          the super a real fun_constraints entry means find_enclosing_dict
          resolves the inner method to an honest super dict, and dict_pass / the
          EDictApp recorder give it a matching slot — all three read this same
          list.  The superinterface impl is guaranteed to exist by the Phase-64
          obligation check, so callers can always supply it. *)
       if has_sig then begin
         (* Phase 83: the signature is authoritative, but must be *sufficient*
            for the body — each required constraint must be entailed by the
            declared set (incl. superinterfaces). *)
         let declared_closed = expand_supers (!env_ref).interfaces declared_cs in
         List.iter (fun (iface, ids, loc) ->
           let entailed =
             List.exists (fun (di, dids) ->
               di = iface && List.exists (fun id -> List.mem id dids) ids)
               declared_closed
           in
           if not entailed then fail_at loc (UnsatisfiedConstraint (name, iface))
         ) body_cs;
         (* Phase 89: a point-free binding generalized only by the relaxed rule
            dispatches by arg tag, not dict passing (the marker filled no EDictApp
            route for its body's methods).  Route its declared constraints through
            inferred_constraints — call-site obligations still fire, but
            find_enclosing_dict / dict_pass stay out of it, so no unbound
            `$dict_…` at eval.  Must also clear Pass A's fun_constraints
            pre-registration. *)
         if relaxed then begin
           Hashtbl.remove (!env_ref).fun_constraints name;
           if declared_closed <> [] then
             Hashtbl.replace (!env_ref).inferred_constraints name declared_closed
           else
             Hashtbl.remove (!env_ref).inferred_constraints name
         end
         (* Declared constraints drive dict passing — registered in
            fun_constraints (the marker already wrapped `=>`-signatured calls). *)
         else if declared_closed <> [] then
           Hashtbl.replace (!env_ref).fun_constraints name declared_closed
         else
           (* No surviving constraints (e.g. the var was pinned by an outer
              monomorphic scope): undo Pass A's pre-registration so this function
              gets no phantom dict parameter. *)
           Hashtbl.remove (!env_ref).fun_constraints name
       end else begin
         (* No signature: infer the body's required constraints (deduped on
            (iface, ids), since a constraint is re-recorded per call site) and
            register them in inferred_constraints — obligation checking only, no
            dict routing (see the inferred_constraints field comment). *)
         let inferred =
           List.fold_left (fun acc (iface, ids, _loc) ->
             if List.mem (iface, ids) acc then acc else acc @ [(iface, ids)]
           ) [] body_cs
         in
         let inferred = expand_supers (!env_ref).interfaces inferred in
         (* Phase 84: on pass 2 of the two-pass elaboration, a name pass 1 found
            to carry inferred constraints is in [promoted].  Register such a
            binding's inferred constraints in fun_constraints (route-bearing) so
            find_enclosing_dict / dict_pass thread a dictionary into its body —
            e.g. a polymorphic-monad do-block's `pure`.  Always record in
            inferred_constraints too, so promoted_out (read from that table) and
            cross-module export stay complete regardless of routing. *)
         if inferred <> [] then begin
           Hashtbl.replace (!env_ref).inferred_constraints name inferred;
           if Hashtbl.mem (!env_ref).promoted name then
             Hashtbl.replace (!env_ref).fun_constraints name inferred
         end else begin
           Hashtbl.remove (!env_ref).inferred_constraints name;
           Hashtbl.remove (!env_ref).fun_constraints name
         end
       end);
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
    let etbl = Hashtbl.create 4 in
    let rec go = function
      | Ast.TyCon n ->
        (try List.assoc n param_vars
         with Not_found -> TCon n)
      | Ast.TyVar n ->
        (try List.assoc n param_vars
         with Not_found ->
           (* A payload type variable not bound by the type's parameter list is
              an error (no existential quantification): reject it instead of
              silently minting a fresh var and over-generalizing the ctor. *)
           fail (UnboundTypeVar (n, name)))
      | Ast.TyApp (a, b) -> TApp (go a, go b)
      | Ast.TyFun (a, b) ->
        let bm = match b with Ast.TyEffect (_, _, t) -> go t | t -> go t in
        TFun (go a, ast_effrow etbl b, bm)
      | Ast.TyTuple ts -> TTuple (List.map go ts)
      | Ast.TyEffect (_, _, t) -> go t
      | Ast.TyConstrained (_, inner) -> go inner
    in
    let arg_types = match v.Ast.con_payload with
      | Ast.ConPos tys    -> List.map (fun f -> go (expand_aliases aliases f)) tys
      | Ast.ConNamed flds ->
        let monos = List.map (fun f -> (f.Ast.field_name, go (expand_aliases aliases f.Ast.field_type))) flds in
        (* Register field ownership (multimap — a field name may be shared across
           records/ctors, Phase 72) and the ordered field list for
           pattern/construction. *)
        List.iter (fun (fn, _) ->
          add_field_owner env.field_owners fn v.Ast.con_name
        ) monos;
        Hashtbl.replace env.ctor_fields v.Ast.con_name monos;
        List.map snd monos
    in
    let ctor_t =
      List.fold_right (fun a acc -> TFun (a, pure_row, acc)) arg_types result_t
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
    let etbl = Hashtbl.create 4 in
    let rec go = function
      | Ast.TyCon n ->
        (try List.assoc n param_vars with Not_found -> TCon n)
      | Ast.TyVar n ->
        (try List.assoc n param_vars
         with Not_found -> fail (UnboundTypeVar (n, name)))
      | Ast.TyApp (a, b)  -> TApp (go a, go b)
      | Ast.TyFun (a, b)  ->
        let bm = match b with Ast.TyEffect (_, _, t) -> go t | t -> go t in
        TFun (go a, ast_effrow etbl b, bm)
      | Ast.TyTuple ts    -> TTuple (List.map go ts)
      | Ast.TyEffect (_, _, t) -> go t
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
  (* Phase 72: field_owners is a multimap — two record types may share a field
     name, and field access resolves by the receiver's inferred type.
     add_field_owner dedups, so per-module prelude re-registration and export
     seeding stay idempotent. *)
  List.iter (fun (fname, _) ->
    add_field_owner env.field_owners fname name
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
let register_interface ?(aliases=Hashtbl.create 0) env (iface_name, type_params, methods, super) =
  enter_level ();
  let param_vars = List.map (fun p -> (p, fresh_var ())) type_params in
  (* Each call to go_ty gets its own memoization table for method-level tvars.
     This ensures that occurrences of the same name within one method type
     (e.g., both `a`s in `(a -> b) -> f a -> f b`) resolve to the same TVar,
     while still being independent across different methods. *)
  let go_ty ast_ty =
    let ast_ty = expand_aliases aliases ast_ty in
    let method_vars = Hashtbl.create 4 in
    let etbl = Hashtbl.create 4 in
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
        let bm = match b with Ast.TyEffect (_, _, t) -> go t | t -> go t in
        TFun (go a, ast_effrow etbl b, bm)
      | Ast.TyTuple ts    -> TTuple (List.map go ts)
      | Ast.TyEffect (_, _, t) -> go t
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
      | TVar r ->
        (match !r with
         | Unbound (id, _) -> id
         | Link _ -> fail (InternalError "interface param: Link survived normalize"))
      | _ -> fail (InternalError "interface type parameter was unexpectedly constrained to a concrete type")
    ) param_vars
  in
  let method_schemes =
    List.map (fun (n, mt) -> (n, generalize mt)) method_monos
  in
  let defaults = List.filter_map (fun m ->
    if m.Ast.method_default <> None then Some m.Ast.method_name else None
  ) methods in
  (* Phase 69.x-e: each method's *own* method-level constraints (scheme-level var
     ids), super-expanded so a default body that calls a superinterface method
     (foldMap's `++`, a Semigroup method, under a declared `Monoid m`) gets a
     slot.  Computed before the default-body loop so we can map these scheme ids
     through each default's instantiation into method_dict_routes (below). *)
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
        if cs' = [] then None
        else Some (name, expand_supers env.interfaces cs')
      end
    ) method_results
  in
  List.iter (fun (name, cs) ->
    Hashtbl.replace env.method_constraints name cs
  ) iface_method_constraints;
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
      let (sub, expected_t) = instantiate_raw mscheme in
      (* Phase 69.x-e: record, per slot, the *instantiated* id of each
         method-level constraint var as it appears in this default body, so an
         in-body method ref unified to it (e.g. `empty`/`++` against foldMap's
         `m`) routes via find_enclosing_dict to `$dict_<method>_<slot>`. *)
      (match List.assoc_opt m.Ast.method_name iface_method_constraints with
       | None -> ()
       | Some cs ->
         let inst_id id = match List.assoc_opt id sub with
           | Some t -> (match normalize t with
                        | TVar {contents = Unbound (iid, _)} -> Some iid | _ -> None)
           | None -> None
         in
         let inst_cs = List.map (fun (iface, ids) ->
           (iface, List.filter_map inst_id ids)) cs in
         Hashtbl.replace env.method_dict_routes m.Ast.method_name inst_cs);
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
  (* Resolve each superinterface obligation's type-arg names to the bound ids of
     the interface's own params, so check_superinterface_obligations can later
     substitute an impl's concrete type args positionally. *)
  let param_id_of_name = List.combine type_params param_ids in
  let iface_supers =
    List.map (fun (super_name, super_args) ->
      let ids = List.filter_map
        (fun n -> List.assoc_opt n param_id_of_name) super_args in
      (super_name, ids)
    ) super
  in
  let info = {
    iface_param_ids = param_ids;
    iface_methods   = method_schemes;
    iface_defaults  = defaults;
    iface_method_constraints;
    iface_supers;
  } in
  Hashtbl.replace env.interfaces iface_name info;
  List.iter (fun m ->
    Hashtbl.replace env.method_iface m.Ast.method_name iface_name
  ) methods;
  method_schemes

(* Phase 83/84: ids of all still-unbound type vars in a mono (local copy; the
   top-level mono_unbound_ids is defined later in the file). *)
let rec mono_ids_tc m = match normalize m with
  | TVar { contents = Unbound (id, _) } -> [id]
  | TVar _ | TCon _ -> []
  | TApp (a, b) | TFun (a, _, b) -> mono_ids_tc a @ mono_ids_tc b
  | TTuple ts -> List.concat_map mono_ids_tc ts

(* Phase 83/84: does an interface param appear in an *argument* position of this
   method's type?  If so the method dispatches on a value argument — arg-tag
   dispatch handles it (including nested containers) and it must NOT get
   instance-dict threading.  Only return-position methods (the param solely in
   the result, e.g. `arbitrary : Unit -> <Rand> a`) need the impl's element dict,
   because their in-body element ref produces — rather than consumes — a value of
   the param type and so can't be arg-tag-dispatched. *)
let method_param_in_arg_position (Forall (_, _, mt)) (param_ids : int list) : bool =
  let rec arg_ids t = match normalize t with
    | TFun (a, _, b) -> mono_ids_tc a @ arg_ids b
    | _ -> [] in
  let aids = arg_ids mt in
  List.exists (fun p -> List.mem p aids) param_ids

(* Validate a DImpl declaration against the registered interface.
   Instantiates each method's scheme with the impl's concrete type args and
   type-checks the provided method body against the resulting expected type. *)
let check_impl env (decl : decl) = match decl with
  | DImpl { iface_name; type_args; methods; impl_name; requires; _ } ->
    let info =
      try Hashtbl.find env.interfaces iface_name
      with Not_found -> fail (UnknownInterface iface_name)
    in
    let n_params = List.length info.iface_param_ids in
    let n_args   = List.length type_args in
    if n_params <> n_args then
      fail (ImplArityMismatch (iface_name, n_params, n_args));
    (* Share one TVar table across the head and the `requires` clause (as
       register_impl does) so a head param (`a` in `impl Arbitrary (List a)
       requires Arbitrary a`) is the *same* TVar in both.  The body's inner
       return-position ref (the element `arbitrary`) unifies its discriminating
       var against that head TVar, so registering the requires' ids here lets
       find_enclosing_dict route it to this impl method's dict param. *)
    let tbl = Hashtbl.create 4 in
    let concrete = List.map (from_ast_type ~aliases:env.aliases ~tbl) type_args in
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
    (* Phase 83/84: register this impl's `requires` constraints (per method it
       defines) so return-position refs inside the bodies route to the impl's
       `$dict_<method>_<slot>` params (added by dict_pass).  Done *after* body
       inference and via `normalize`, so the recorded ids are the post-unification
       survivors — the same representatives the in-body method occurrence carries
       (unify picks which var survives; registering the pre-unification id would
       miss).  The requires share `tbl` with the head (the head param `a` is the
       same TVar the body unified against).  Keyed per impl_key so peer impls of
       the same method don't collide and REPL re-checks replace, not accumulate. *)
    let impl_inst_cs =
      List.map (fun (riface, rargs) ->
        let ids = List.concat_map
          (fun a -> mono_ids_tc (from_ast_type ~aliases:env.aliases ~tbl a)) rargs in
        (riface, ids)) requires
    in
    if impl_inst_cs <> [] then begin
      let this_key = Ast.impl_key ~iface:iface_name ~type_args ~name:impl_name in
      (* Only return-position methods need the dict; arg-position methods
         (debug/eq/compare) stay on arg-tag dispatch, which handles nesting. *)
      List.iter (fun (n, _, _) ->
        match List.assoc_opt n info.iface_methods with
        | Some msc when not (method_param_in_arg_position msc info.iface_param_ids) ->
          let prev = Option.value ~default:[]
                       (Hashtbl.find_opt env.impl_dict_routes n) in
          Hashtbl.replace env.impl_dict_routes n
            ((this_key, impl_inst_cs) :: List.remove_assoc this_key prev)
        | _ -> ()
      ) methods
    end;
    (* Check for extra methods that are not part of the interface *)
    List.iter (fun (n, _, _) ->
      if not (List.mem_assoc n info.iface_methods) then
        fail (ExtraMethod (iface_name, n))
    ) methods
  | _ -> ()

(* Record an impl declaration in env.impls so call-site constraint checking
   can find it.  Must run after register_interface so the interface exists. *)
let register_impl ?(seeded=false) env = function
  | DImpl { iface_name; type_args; impl_name; is_default; requires; impl_loc; _ } ->
    if not (Hashtbl.mem env.interfaces iface_name) then
      fail (UnknownInterface iface_name);
    (* Share one TVar table across the head and the `requires` clause so that a
       type variable (`a` in `impl Eq (Box a) requires Eq a`) maps to the same
       fresh TVar in both — Phase 65 correlates them to discharge the
       requirement at concrete call sites. *)
    let tbl = Hashtbl.create 4 in
    let entry = {
      impl_iface      = iface_name;
      impl_name;
      impl_is_default = is_default;
      impl_type_mono  = List.map (from_ast_type ~aliases:env.aliases ~tbl) type_args;
      impl_key        = Ast.impl_key ~iface:iface_name ~type_args ~name:impl_name;
      impl_requires   = List.map (fun (iface, args) ->
                          (iface, List.map (from_ast_type ~aliases:env.aliases ~tbl) args)) requires;
      impl_seeded     = seeded;
      impl_loc;
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

(* One-directional cousin of [impls_overlap]: is [specific] an instance of
   [general]?  Only the *general* side's TVars may be bound (they act as
   wildcards); the *specific* side's TVars are rigid and match only the same id.
   Binding is *consistent* — a general TVar bound twice must see structurally
   equal types — so `subsumes ~general:[a; a] ~specific:[Int; Bool]` is false,
   while `subsumes ~general:[List a] ~specific:[List Int]` is true.  This orders
   overlapping impls by specificity (Phase 68 most-specific-wins). *)
let subsumes ~(general : mono list) ~(specific : mono list) : bool =
  let subst : (int, mono) Hashtbl.t = Hashtbl.create 8 in
  let rec eq t1 t2 = match normalize t1, normalize t2 with
    | TVar { contents = Unbound (i1, _) }, TVar { contents = Unbound (i2, _) } ->
      i1 = i2
    | TCon a, TCon b -> a = b
    | TApp (f1, a1), TApp (f2, a2) -> eq f1 f2 && eq a1 a2
    | TFun (a1, _, b1), TFun (a2, _, b2) -> eq a1 a2 && eq b1 b2
    | TTuple a, TTuple b -> List.length a = List.length b && List.for_all2 eq a b
    | _ -> false
  in
  let rec go g s = match normalize g, normalize s with
    | TVar { contents = Unbound (id, _) }, s ->
      (match Hashtbl.find_opt subst id with
       | Some prev -> eq prev s
       | None -> Hashtbl.replace subst id s; true)
    | TCon a, TCon b -> a = b
    | TApp (f1, a1), TApp (f2, a2) -> go f1 f2 && go a1 a2
    | TFun (a1, _, b1), TFun (a2, _, b2) -> go a1 a2 && go b1 b2
    | TTuple a, TTuple b -> List.length a = List.length b && List.for_all2 go a b
    | _ -> false
  in
  List.length general = List.length specific && List.for_all2 go general specific

(* [a] is *strictly* more specific than [b] when [b] subsumes [a] but not vice
   versa.  Equal heads (mutual subsumption, e.g. `List a` / `List b`) and
   incomparable partial overlaps (`Conv Int a` / `Conv a Bool`, neither way)
   are *not* strict — so they remain genuine coherence conflicts. *)
let strictly_more_specific (a : mono list) (b : mono list) : bool =
  subsumes ~general:b ~specific:a && not (subsumes ~general:a ~specific:b)

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
(* Best source location for a coherence conflict: prefer the second (later-
   declared) impl, which is usually the offending duplicate/specialization; fall
   back to the first, then to None when neither carries a loc. *)
let coherence_loc e1 e2 =
  match e2.impl_loc with Some _ as l -> l | None -> e1.impl_loc

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
            fail_at (coherence_loc e1 e2)
              (MultipleDefaultImpls (e1.impl_iface, e1.impl_type_mono))
          | false, false when e1.impl_name = None && e2.impl_name = None ->
            (* Phase 68 most-specific-wins: a strict specialization (one head an
               instance of the other, e.g. `List Int` vs `List a`) is coherent —
               check_method_usages commits the most specific at each call site,
               and Phase 69 dispatch honors that choice.  Only equal duplicates
               and incomparable partial overlaps stay unresolvable. *)
            if strictly_more_specific e1.impl_type_mono e2.impl_type_mono
            || strictly_more_specific e2.impl_type_mono e1.impl_type_mono
            then ()
            else fail_at (coherence_loc e1 e2)
                   (OverlappingImpls
                      (e1.impl_iface, e1.impl_type_mono, e2.impl_type_mono))
          | _ -> ()  (* exactly one default, or a named impl disambiguates *)
      ) rest;
      pairs rest
  in
  pairs user_impls

(* Orphan-instance check (Phase 68).  An impl declared in the current module is
   an *orphan* when it lives in neither the interface's module nor any head
   type's module.  Since the impl is checked *in the module that declares it*,
   "impl is in the interface's module" reduces to "the interface is declared
   locally", and likewise for the head types — so the check needs only local
   knowledge plus the names exported by *imported user modules* (the prelude
   `core` is never a known-module — the loader skips it — so prelude/runtime
   names like Eq/Array are never "imported", which keeps the stdlib's
   `impl Eq (Array a)` and single-file prelude overrides out of scope).

   Rule: an *anonymous* impl `impl Iface T1 T2 …` is an orphan iff
     (1) Iface is not declared locally, and
     (2) no head-type constructor is declared locally, and
     (3) Iface — or some head-type constructor — comes from an imported user
         module.
   Named (`@Name`) impls are an explicit opt-in escape hatch and are exempt. *)
let rec tycons_of (t : Ast.ty) : ident list =
  match t with
  | Ast.TyCon n -> [n]
  | Ast.TyVar _ -> []
  | Ast.TyApp (f, a) -> tycons_of f @ tycons_of a
  | Ast.TyFun (a, b) -> tycons_of a @ tycons_of b
  | Ast.TyTuple ts -> List.concat_map tycons_of ts
  | Ast.TyEffect (_, _, t) -> tycons_of t
  | Ast.TyConstrained (cs, t) ->
    List.concat_map (fun (_, args) -> List.concat_map tycons_of args) cs
    @ tycons_of t

(* Interface and type names declared by the implicit prelude (core).  Used to
   strip prelude entries that leak into every module's te_interfaces (built from
   the prelude-prepended `prog`): otherwise a module that merely *imports* a user
   module would see Debug/Eq/etc. attributed to it, and a legitimate prelude
   override like `impl Debug Int` would be mis-flagged as an orphan. *)
let iface_names_of_decls decls =
  List.filter_map (fun d -> match Ast.inner_decl d with
    | DInterface { iface_name; _ } -> Some iface_name | _ -> None) decls
let type_names_of_decls decls =
  List.filter_map (fun d -> match Ast.inner_decl d with
    | DData (_, n, _, _, _) | DRecord (_, n, _, _, _)
    | DNewtype (_, n, _, _, _, _) | DTypeAlias (_, n, _, _) -> Some n
    | _ -> None) decls

let check_orphans ~known_modules ~user_prog env =
  let prelude_ifaces = iface_names_of_decls Prelude.program in
  let prelude_types  = type_names_of_decls Prelude.program in
  (* names declared in this module *)
  let local_ifaces = iface_names_of_decls user_prog in
  let local_types  = type_names_of_decls user_prog in
  (* name -> defining module, over imported user modules only (prelude excluded) *)
  let iface_origin = List.concat_map (fun te ->
    List.filter_map (fun (n, _) ->
      if List.mem n prelude_ifaces then None else Some (n, te.te_mod_id))
      te.te_interfaces) known_modules in
  let type_origin = List.concat_map (fun te ->
    List.filter_map (fun n ->
      if List.mem n prelude_types then None else Some (n, te.te_mod_id))
      te.te_types) known_modules in
  List.iter (fun d -> match Ast.inner_decl d with
    | DImpl { iface_name; type_args; impl_name = None; impl_loc; _ } ->
      let heads = List.concat_map tycons_of type_args in
      let iface_local = List.mem iface_name local_ifaces in
      let type_local  = List.exists (fun c -> List.mem c local_types) heads in
      let iface_imported = List.assoc_opt iface_name iface_origin in
      let type_imported  = List.find_map (fun c -> List.assoc_opt c type_origin) heads in
      if (not iface_local) && (not type_local)
         && (iface_imported <> None || type_imported <> None)
      then
        fail_at impl_loc
          (OrphanImpl
             (iface_name,
              List.map (from_ast_type ~aliases:env.aliases) type_args,
              iface_imported, type_imported))
    | _ -> ()
  ) user_prog

(* Push hardcoded impl_entry records for primitive types satisfying Num, Ord,
   and Semigroup.  These have no AST counterpart (so they don't go through
   check_impl) and exist only so operator constraints — e.g. `Num Int` raised
   by `1 + 2` — find a matching entry in env.impls.  The interfaces themselves
   are declared by the prelude (stdlib/core.mdk); we just supply the ground
   instances the evaluator handles via OCaml-side primitive operations. *)
(* ── Constraint checking ─────────────────────────── *)

(* A mono is concrete when it has no unbound TVars — i.e. inference has ground
   it fully.  Constraint/obligation passes defer non-concrete types until a
   concrete call site grounds them. *)
let rec is_concrete = function
  | TVar v -> (match !v with Unbound _ -> false | Link t -> is_concrete t)
  | TCon _ -> true
  | TApp (a, b) | TFun (a, _, b) -> is_concrete a && is_concrete b
  | TTuple ts -> List.for_all is_concrete ts

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

(* Impls in env.impls whose head matches (iface_name, concrete_args), after the
   Phase 45.9 preference (user impls trump seeded built-ins).  Shared by the
   constraint-obligation and superinterface-obligation passes. *)
let matching_impls env iface_name concrete_args =
  let matching = List.filter (fun e ->
    e.impl_iface = iface_name &&
    List.length e.impl_type_mono = List.length concrete_args &&
    List.for_all2
      (fun p c -> mono_matches ~pattern:p ~concrete:c)
      e.impl_type_mono concrete_args
  ) !(env.impls) in
  if List.exists (fun e -> not e.impl_seeded) matching
  then List.filter (fun e -> not e.impl_seeded) matching
  else matching

(* Phase 65: build the substitution mapping an impl head's TVars to the concrete
   sub-types it was selected for.  Patterns come from `impl_type_mono`; concrete
   args are fully ground (the caller checked `is_concrete`).  Models the
   id-keyed `subst` idiom of `impls_overlap`.  Returns None if the head doesn't
   structurally match — defensive only; selection already guaranteed a match. *)
let impl_head_subst (patterns : mono list) (concrete : mono list)
  : (int, mono) Hashtbl.t option =
  let subst : (int, mono) Hashtbl.t = Hashtbl.create 8 in
  let rec go p c = match normalize p, normalize c with
    | TVar { contents = Unbound (id, _) }, c -> Hashtbl.replace subst id c; true
    | TCon a, TCon b -> a = b
    | TApp (f1, a1), TApp (f2, a2) -> go f1 f2 && go a1 a2
    | TFun (a1, _, b1), TFun (a2, _, b2) -> go a1 a2 && go b1 b2
    | TTuple a, TTuple b -> List.length a = List.length b && List.for_all2 go a b
    | _ -> false
  in
  if List.length patterns = List.length concrete
     && List.for_all2 go patterns concrete
  then Some subst else None

(* Apply an `impl_head_subst` substitution to a mono, non-destructively (impl
   entries are shared across call sites, so we must not Link their TVars). *)
let rec subst_apply subst m = match normalize m with
  | TVar { contents = Unbound (id, _) } as tv ->
    (match Hashtbl.find_opt subst id with Some t -> t | None -> tv)
  | TVar _ as tv -> tv
  | TCon _ as t -> t
  | TApp (a, b) -> TApp (subst_apply subst a, subst_apply subst b)
  | TFun (a, e, b) -> TFun (subst_apply subst a, e, subst_apply subst b)
  | TTuple ts -> TTuple (List.map (subst_apply subst) ts)

(* Phase 65: discharge an impl's `requires` constraints.  Given an `entry`
   selected for ground `concrete_args`, substitute the head TVars into each
   `requires` clause and verify a matching impl exists — recursively, so the
   chosen sub-impl's own requires are checked too (e.g. `Eq (List (List Int))`
   → `Eq (List Int)` → `Eq Int`).  Recursion terminates because each step
   strictly shrinks the type structurally.  Non-ground requirements are deferred
   like the other constraint passes.  Blames `loc` (the call site, Phase 62). *)
let rec check_entry_requires env loc entry concrete_args =
  match impl_head_subst entry.impl_type_mono concrete_args with
  | None -> ()
  | Some subst ->
    List.iter (fun (req_iface, req_args) ->
      let req_concrete =
        List.map (fun a -> normalize (subst_apply subst a)) req_args in
      if List.for_all is_concrete req_concrete then
        match matching_impls env req_iface req_concrete with
        | [] ->
          fail_at loc
            (MissingImplRequirement
               (entry.impl_iface, concrete_args, req_iface, req_concrete))
        | e' :: _ -> check_entry_requires env loc e' req_concrete
    ) entry.impl_requires

(* Phase 69.x: extract the ids of all still-unbound type variables in a mono. *)
let rec mono_unbound_ids m =
  match normalize m with
  | TVar {contents = Unbound (id, _)} -> [id]
  | TVar _ -> []
  | TCon _ -> []
  | TApp (a, b) | TFun (a, _, b) -> mono_unbound_ids a @ mono_unbound_ids b
  | TTuple ts -> List.concat_map mono_unbound_ids ts

(* Phase 69.x: a method/dict occurrence whose discriminating type is still a
   type variable may be one of the *enclosing* constrained function's type
   variables.  Search fun_constraints for an entry of interface [iface] whose
   bound ids include one of [ids_present]; return the synthetic dict-param name
   to read at runtime (dict_pass binds it on that function).  tyvar ids are
   globally unique, so at most one (function, slot) matches — *except* across a
   merged mutual-recursion group, whose members share one constraint var id
   (Phase 136).  There the [enclosing] hint (the member whose body holds this
   occurrence, captured at record time) disambiguates: prefer its own dict param,
   falling back to the global scan only when the enclosing function has no
   matching constraint (the dict comes from an enclosing method/impl instead). *)
let find_enclosing_dict ?enclosing env iface (ids_present : int list) : Ast.ident option =
  let result = ref None in
  let match_in fname constraints =
    List.iteri (fun slot (ci, cids) ->
      if !result = None && ci = iface
         && List.exists (fun id -> List.mem id cids) ids_present
      then result := Some (Ast.dict_param_name fname slot)
    ) constraints
  in
  let search table =
    Hashtbl.iter (fun fname constraints ->
      if !result = None then match_in fname constraints) table
  in
  (match enclosing with
   | Some f ->
     (match Hashtbl.find_opt env.fun_constraints f with
      | Some cs -> match_in f cs
      | None -> ())
   | None -> ());
  if !result = None then search env.fun_constraints;
  (* Phase 69.x-e: also the enclosing *method's* own constraints, so an in-body
     ref inside a default method body (e.g. `empty`/`++` in foldMap's default)
     reads `$dict_<method>_<slot>`.  Keyed by the instantiated default-body ids. *)
  if !result = None then search env.method_dict_routes;
  (* Phase 83/84: also the enclosing *impl's* `requires`, so a return-position
     ref inside a parametric impl body (e.g. the element `arbitrary` in
     `impl Arbitrary (List a) requires Arbitrary a`) reads the impl method's
     `$dict_<method>_<slot>`.  Slots are impl-local — the index within one
     impl's constraint list — matching the params dict_pass prepends. *)
  if !result = None then
    Hashtbl.iter (fun mname impls ->
      (* Impl-requires params follow the method's own method-level params, so
         offset the impl-local slot by that count (0 for Arbitrary/Eq/Ord/Debug). *)
      let method_off = match Hashtbl.find_opt env.method_constraints mname with
        | Some cs -> List.length cs | None -> 0 in
      if !result = None then
        List.iter (fun (_impl_key, constraints) ->
          if !result = None then
            List.iteri (fun slot (ci, cids) ->
              if !result = None && ci = iface
                 && List.exists (fun id -> List.mem id cids) ids_present
              then result := Some (Ast.dict_param_name mname (method_off + slot))
            ) constraints
        ) impls
    ) env.impl_dict_routes;
  !result

(* After HM inference, check every recorded method call site against the impl
   registry.  Skips usages where types are still polymorphic or where the method
   scheme doesn't mention all interface params (uncommon). *)

(* Phase 83/84 (#4): route a constraint whose single dispatch arg is
   *head-concrete* but args-free (`Result e` — head `Result`, `e` unbound) by its
   head tycon.  Only for a single-param interface, where the head alone picks the
   impl; returns the head tag iff at least one (non-seeded, if any) impl head
   matches — eval's select_impl_by_head enforces uniqueness or falls back to
   arg-tag.  Shared by the method-occurrence path (try_head_key) and the
   dict-application path (resolve_one_route). *)
let head_key_route env iface_name args : string option =
  let n = match Hashtbl.find_opt env.interfaces iface_name with
    | Some info -> List.length info.iface_param_ids
    | None -> 0 in
  if n <> 1 then None else
  match args with
  | [arg] ->
    (match head_tycon_mono arg with
     | None -> None  (* head is a bare TVar — not head-concrete *)
     | Some h ->
       let matching = List.filter (fun e ->
         e.impl_iface = iface_name &&
         List.length e.impl_type_mono = 1 &&
         List.for_all2
           (fun p c -> mono_matches ~pattern:p ~concrete:c)
           e.impl_type_mono [arg]
       ) !(env.impls) in
       let matching =
         if List.exists (fun e -> not e.impl_seeded) matching
         then List.filter (fun e -> not e.impl_seeded) matching
         else matching in
       if matching <> [] then Some h else None)
  | _ -> None

let check_method_usages env =
  (* An interface recorded in a usage but absent from env.interfaces would be an
     internal inconsistency; degrade to 0 (which skips this usage's check below)
     rather than crashing the REPL with a raw Not_found. *)
  let n_iface_params iface_name =
    match Hashtbl.find_opt env.interfaces iface_name with
    | Some info -> List.length info.iface_param_ids
    | None -> 0
  in
  List.iter (fun (method_name, iface_name, param_vars, hint_opt, _method_dict_args, occ_ref, loc, enclosing) ->
    let n = n_iface_params iface_name in
    (* Phase 69: stamp the resolved impl's route onto this method occurrence (if
       it carries an EMethodRef) so eval routes return-position / multi-param
       dispatch to the impl the checker actually picked.  res_method_dicts is
       filled later by resolve_method_dicts (needs pick_dispatch_impl). *)
    let set_route route =
      match occ_ref with
      | Some cell ->
        cell := Some { Ast.res_iface = iface_name; res_route = route;
                       res_method_dicts = []; res_impl_dicts = [] }
      | None -> ()
    in
    if n = 0 || List.length param_vars <> n then ()
    else begin
      let concrete_args = List.map (fun r -> normalize (TVar r)) param_vars in
      (* Phase 83/84: resolve a committed impl's `requires` (substituted by the
         call's concrete head args) to dict routes, so eval applies them as
         leading args to the selected impl method (matching the params dict_pass
         prepends).  The site is ground here, so each requires resolves to the
         matching impl's RKey (mirrors pick_dispatch_impl, which is defined later
         in the file).  `resolve_one_route` is not yet in scope at this point. *)
      let impl_requires_routes entry =
        match impl_head_subst entry.impl_type_mono concrete_args with
        | None -> []
        | Some subst ->
          List.map (fun (req_iface, req_args) ->
            let args = List.map (fun a -> normalize (subst_apply subst a)) req_args in
            if args <> [] && List.for_all is_concrete args then
              match matching_impls env req_iface args with
              | [] -> Ast.RKey ""
              | entries ->
                let ms = List.filter (fun e ->
                  List.for_all (fun e' -> e == e' ||
                    subsumes ~general:e'.impl_type_mono ~specific:e.impl_type_mono)
                    entries) entries in
                (match ms with
                 | [e] -> Ast.RKey e.impl_key
                 | _ ->
                   (match List.filter (fun e -> e.impl_is_default) entries with
                    | [e] -> Ast.RKey e.impl_key
                    | _ -> Ast.RKey ""))
            else Ast.RKey ""
          ) entry.impl_requires
      in
      (* Phase 65: committing to an impl also verifies its `requires` hold. *)
      (* Only stamp impl dicts for return-position methods — the same gate as
         check_impl's registration and dict_pass's param insertion, so the dicts
         eval applies match the params on the impl clause. Arg-position methods
         (debug/eq/compare) stay on arg-tag dispatch. *)
      let method_is_return_pos =
        match Hashtbl.find_opt env.interfaces iface_name with
        | Some info ->
          (match List.assoc_opt method_name info.iface_methods with
           | Some msc -> not (method_param_in_arg_position msc info.iface_param_ids)
           | None -> false)
        | None -> false
      in
      let commit entry =
        set_route (Ast.RKey entry.impl_key);
        check_entry_requires env loc entry concrete_args;
        (match entry.impl_requires, occ_ref with
         | (_ :: _), Some cell when method_is_return_pos ->
           let routes = impl_requires_routes entry in
           (match !cell with
            | Some r -> cell := Some { r with Ast.res_impl_dicts = routes }
            | None -> ())
         | _ -> ())
      in
      if not (List.for_all is_concrete concrete_args) then begin
        (* Not ground at this site.  Two ways to still route it:
           - Phase 69.x-c: the discriminating type is *head-concrete* (head tycon
             fixed, args free — `pure x : Result e a`, or a do-block `pure`).  For
             a single-param interface the head uniquely picks an impl, so stamp
             RHeadKey and let eval narrow by head tag.
           - Phase 69.x-a/b: the discriminating var is the enclosing constrained
             function's type variable — route to its runtime dictionary. *)
        let try_head_key () = head_key_route env iface_name concrete_args in
        match occ_ref with
        | Some _ ->
          (match try_head_key () with
           | Some h -> set_route (Ast.RHeadKey h)
           | None ->
             let ids = List.concat_map mono_unbound_ids concrete_args in
             (match find_enclosing_dict ?enclosing env iface_name ids with
              | Some dvar -> set_route (Ast.RDict dvar)
              | None -> ()))
        | None -> ()
      end
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
        if matching = [] then fail_at loc (NoImplFound (iface_name, concrete_args))
        else match hint_opt with
        | None ->
          (match matching with
          | [e] -> commit e
          | entries ->
            (* Phase 68 most-specific-wins: commit the unique impl that every
               other matching impl subsumes (the most specific one).  A `default`
               impl is only the tiebreaker of last resort, when no unique
               most-specific exists (incomparable overlap). *)
            let most_specific = List.filter (fun e ->
              List.for_all (fun e' ->
                e == e' ||
                subsumes ~general:e'.impl_type_mono ~specific:e.impl_type_mono
              ) entries) entries in
            (match most_specific with
             | [e] -> commit e
             | _ ->
               (match List.filter (fun e -> e.impl_is_default) entries with
                | [e] -> commit e
                | _ -> fail_at loc (AmbiguousImpl (iface_name, concrete_args)))))
        | Some name ->
          let named = List.filter (fun e -> e.impl_name = Some name) matching in
          (match named with
          | [] -> fail_at loc (UnknownImplName (iface_name, name, concrete_args))
          | [e] -> commit e
          | _ -> fail_at loc (AmbiguousImpl (iface_name, concrete_args)))
      end
    end
  ) !(env.method_usages)

(* Verify that every constraint obligation emitted at call sites has a
   matching impl.  Skips obligations where the concrete type is still a
   polymorphic TVar — those are correctly left unchecked until a concrete
   call site grounds the type. *)
let check_constraint_obligations env =
  List.iter (fun (iface_name, mono_args, loc) ->
    let concrete = List.map normalize mono_args in
    if not (List.for_all is_concrete concrete) then ()
    else match matching_impls env iface_name concrete with
      | [] -> fail_at loc (NoImplFound (iface_name, concrete))
      (* Phase 65: the matched impl's own `requires` must hold too. *)
      | e :: _ -> check_entry_requires env loc e concrete
  ) !(env.constraint_obligations)

(* Phase 69.x: among the impls matching a ground constraint, pick the one eval
   should dispatch into — the unique most-specific (Phase 68), else the unique
   default, else none.  Mirrors check_method_usages's selection so the dict key
   we pass agrees with the impl the checker would have committed at a concrete
   site. *)
let pick_dispatch_impl env iface concrete : impl_entry option =
  match matching_impls env iface concrete with
  | [] -> None
  | [e] -> Some e
  | entries ->
    let most_specific = List.filter (fun e ->
      List.for_all (fun e' ->
        e == e' || subsumes ~general:e'.impl_type_mono ~specific:e.impl_type_mono
      ) entries) entries in
    (match most_specific with
     | [e] -> Some e
     | _ ->
       (match List.filter (fun e -> e.impl_is_default) entries with
        | [e] -> Some e
        | _ -> None))

(* Phase 69.x: turn each recorded constrained-function occurrence into a list of
   dictionary routes (one per constraint, in slot order) and fill its EDictApp
   ref, so eval applies the right dictionaries as leading arguments.

   - All args ground → the matching impl's canonical key (RKey); eval narrows
     the function's internal-method VMultis to that impl.
   - Args carry the enclosing function's constraint var → that function's dict
     param (RDict pass-through); the caller's dictionary flows transitively in.
   - Anything else (e.g. a polymorphic use inside an *unsignatured* caller, which
     has no dict param) → a sentinel empty key, so eval still supplies a
     dictionary for arity but select_impl_by_key falls back to arg-tag dispatch —
     never worse than pre-69.x behaviour. *)
(* Resolve one constraint occurrence (iface + instantiated args) to its dict
   route — shared by constrained-function occurrences (resolve_dict_apps) and
   method-level-constraint occurrences (resolve_method_dicts, Phase 69.x-e). *)
let resolve_one_route ?enclosing env (iface, args) =
  let args = List.map normalize args in
  if args <> [] && List.for_all is_concrete args then
    (match pick_dispatch_impl env iface args with
     | Some e -> Ast.RKey e.impl_key
     | None -> Ast.RKey "")
  else
    let ids = List.concat_map mono_unbound_ids args in
    (match find_enclosing_dict ?enclosing env iface ids with
     | Some dvar -> Ast.RDict dvar
     | None ->
       (* Phase 83/84 (#4): no enclosing dict, but a head-concrete args-free
          dispatch type (`Result e`) can still route by its head tycon — eval
          carries it as a VDictHead and narrows by head tag.  Otherwise the
          sentinel empty key (arg-tag fallback, never worse than pre-69.x). *)
       (match head_key_route env iface args with
        | Some h -> Ast.RHeadKey h
        | None -> Ast.RKey ""))

(* Phase 115 (#2): turn each deferred recursive-promoted usage into a normal
   dict_app_usages entry, now that the wrapper's fun_constraints entry has been
   registered (post-inference).  For each constraint of the callee, recover the
   args from the live occurrence mono (its discriminating TVar refs resolved when
   the body unified) via find_tvar_in_mono — one entry per constraint, in slot
   order, matching dict_pass's param order.  Run before resolve_dict_apps. *)
let realize_recursive_dict_apps env =
  List.iter (fun (fname, mono, routes_ref, loc, enclosing) ->
    match Hashtbl.find_opt env.fun_constraints fname with
    | None -> ()  (* not actually routable: leave routes None (dict_pass adds no param) *)
    | Some constraints ->
      let per_constraint = List.map (fun (iface, var_ids) ->
        (iface, List.filter_map (fun id -> find_tvar_in_mono mono id) var_ids))
        constraints in
      env.dict_app_usages := (fname, per_constraint, routes_ref, loc, enclosing) :: !(env.dict_app_usages)
  ) !(env.recursive_promoted_usages)

let resolve_dict_apps env =
  List.iter (fun (_fname, per_constraint, routes_ref, _loc, enclosing) ->
    routes_ref := Some (List.map (resolve_one_route ?enclosing env) per_constraint)
  ) !(env.dict_app_usages)

(* Phase 69.x-e: fill res_method_dicts on each method occurrence whose interface
   method carries method-level constraints (e.g. foldMap's `Monoid m`).  One
   route per slot, in method_constraints order, so eval applies them as leading
   dictionaries to the method binding (alongside its arg-tag t-dispatch) and the
   default/impl bodies — given matching `$dict_<method>_<slot>` params by
   dict_pass — read them.  Runs after check_method_usages has stamped res_route. *)
let resolve_method_dicts env =
  List.iter (fun (_m, _iface, _pv, _hint, method_dict_args, occ_ref, _loc, enclosing) ->
    match occ_ref, method_dict_args with
    | Some cell, (_ :: _) ->
      let routes = List.map (resolve_one_route ?enclosing env) method_dict_args in
      (match !cell with
       | Some r -> cell := Some { r with Ast.res_method_dicts = routes }
       | None ->
         (* check_method_usages left no t-route (polymorphic/non-ground site);
            still carry the method dicts so eval can supply them. *)
         cell := Some { Ast.res_iface = _iface; res_route = Ast.RKey "";
                        res_method_dicts = routes; res_impl_dicts = [] })
    | _ -> ()
  ) !(env.method_usages)

(* Phase 64: enforce superinterface (`requires`) obligations at impl sites.
   For `interface Ord a requires Eq a`, every concrete `impl Ord T` must be
   accompanied by an `impl Eq T`.  We check each registered impl's *direct*
   supers: transitivity falls out for free, because the existence of `impl B T`
   already implies B's own super check (`impl A T`) ran when B's impl was
   declared.  Runs as a post-pass over !(env.impls), so declaration order is
   irrelevant — every impl is registered before any obligation is checked.

   Impls with non-concrete heads (e.g. `impl Ord (List a)`) are deferred, like
   the other constraint passes: their super obligation carries the impl's own
   TVars, which a concrete call site grounds.  At that call site `Ord [T]` is
   checked, and this pass already guaranteed the matching concrete `Eq [T]`
   impl exists — which is also why a generic `Ord a => … eq …` body is sound
   without any extra constraint-solver work (the deferred `Eq a` obligation is
   entailed by the enforced `Ord` impl). *)
let check_superinterface_obligations env =
  List.iter (fun entry ->
    match Hashtbl.find_opt env.interfaces entry.impl_iface with
    | None -> ()  (* unknown interface already reported by register_impl *)
    | Some info ->
      if List.length info.iface_param_ids <> List.length entry.impl_type_mono
      then ()  (* arity mismatch already reported by check_impl *)
      else begin
        let subst = List.combine info.iface_param_ids entry.impl_type_mono in
        List.iter (fun (super_name, param_ids) ->
          let concrete = List.filter_map
            (fun id -> List.assoc_opt id subst) param_ids in
          if List.length concrete = List.length param_ids
             && List.for_all is_concrete (List.map normalize concrete)
             && matching_impls env super_name concrete = []
          then fail (MissingSuperImpl (entry.impl_iface, super_name, concrete))
        ) info.iface_supers
      end
  ) !(env.impls)

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

(* Phase 84 / 87 / 115: does [iface] have at least one *return-position* method
   — i.e. one whose interface param appears solely in the result type (`pure`,
   `decode`, `arbitrary`), so an in-body occurrence produces rather than consumes
   a value of that type and cannot be arg-tag-dispatched?  Such a constraint, when
   inferred on an unsignatured wrapper, must be promoted to a dictionary or its
   return-position ref mis-dispatches under arg-tag fallback.  Interfaces whose
   params are all arg-position (`Eq`/`Ord`/`Debug`/`Num`/`Mappable`) need no
   promotion — arg tag already dispatches them correctly. *)
let iface_has_return_position_method (env : env) (iface : ident) : bool =
  match Hashtbl.find_opt env.interfaces iface with
  | Some info ->
    List.exists
      (fun (_, msc) -> not (method_param_in_arg_position msc info.iface_param_ids))
      info.iface_methods
  | None -> false

(* Phase 84 / 87 / 115: given an env whose inferred_constraints are already
   populated (post-typecheck) and the *user* declarations of this pass, return the
   names that should be promoted to dict-routable on a re-elaboration pass.  Two
   filters, each guarding a concrete hazard (see check_program_impl's call site):
   defined in [user_prog] (keys line up), and constraint set mentions an interface
   with a *return-position* method (Phase 115 generalized this from the hard-coded
   `Applicative`: the do-block `pure` was just the prelude instance — user
   return-position interfaces like `Tag`/`Decode` need it too; argument-dispatched
   wrappers stay on arg tag).  The non-recursive guard was dropped in Phase 115
   (#2): a promoted wrapper's own recursive EDictApp call is now routed via
   env.recursive_promoted_usages / realize_recursive_dict_apps.  Shared by the
   single-file driver, the multi-module driver, and the REPL. *)
let promotable_from (env : env) (user_prog : program) : (ident, unit) Hashtbl.t =
  let user_names = Hashtbl.create 16 in
  List.iter (fun d -> match Ast.inner_decl d with
    | DFunDef (_, n, _, _) -> Hashtbl.replace user_names n ()
    | DLetGroup (_, bs)    -> List.iter (fun (n, _) -> Hashtbl.replace user_names n ()) bs
    | _ -> ()) user_prog;
  let out = Hashtbl.create 8 in
  Hashtbl.iter (fun k cs ->
    if Hashtbl.mem user_names k
       && List.exists (fun (iface, _) -> iface_has_return_position_method env iface) cs
    then Hashtbl.replace out k ())
    env.inferred_constraints;
  out

let check_program_impl ?(promoted : (ident, unit) Hashtbl.t option)
    (prog : program)
    : (ident * scheme) list * string list * (ident, unit) Hashtbl.t =
  reset_state ();
  current_loc := None;
  current_impl_hint := None;
  let env = initial_env () in
  (* Phase 84: seed the dict-routable-promotion set for this pass.  Pass 1 passes
     none (discovery); pass 2 passes the names pass 1 found in inferred_constraints
     so process_letrec_group registers their inferred constraints in
     fun_constraints (route-bearing) instead.  env.promoted is a shared Hashtbl —
     extend_var copies only [vars], so every derived env sees these. *)
  (match promoted with
   | Some p -> Hashtbl.iter (fun k () -> Hashtbl.replace env.promoted k ()) p
   | None -> ());

  (* Prepend core stdlib so its data types, interfaces, and impls are in scope
     for all user code.  Prelude declarations are processed through the same
     Phase 1–5 pipeline as user code.  Impl entries for primitive types
     (Num/Ord/Eq on Int/Float/etc.) come from core.mdk declarations.
     Skip prepending when type-checking core.mdk itself (would duplicate). *)
  let user_prog = prog in
  (* Phase 78a: prepend the prelude with any plain function [user_prog] shadows
     dropped, so the user's definition isn't coalesced with the prelude's. *)
  let prog = if program_is_core prog then prog else Method_marker.prelude_for user_prog @ prog in

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
    | DInterface { iface_name; type_params; methods; super; _ } ->
      let ms = register_interface ~aliases:env.aliases env (iface_name, type_params, methods, super) in
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
    List.iter (fun d -> register_impl ~seeded:true  env (Ast.inner_decl d)) Method_marker.marked_prelude;
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

  (* Phase 4.55: type-check prop/test declarations *)
  List.iter (fun d -> match Ast.inner_decl d with
    | DProp { prop_params; prop_body; _ } ->
      let local_env = List.fold_left (fun e (x, ast_ty) ->
        let mono = from_ast_type ~aliases:e.aliases ast_ty in
        extend_var e x (monotype mono)
      ) !env prop_params in
      let body_ty = infer local_env prop_body in
      unify body_ty t_bool
    | DTest { test_body; _ } ->
      ignore (infer !env test_body)
    | DBench { bench_body; _ } ->
      ignore (infer !env bench_body)
    | _ -> ()
  ) prog;

  (* Phase 4.6: verify method call sites have matching impls and constraints *)
  check_method_usages !env;
  check_constraint_obligations !env;
  realize_recursive_dict_apps !env;
  resolve_dict_apps !env;
  resolve_method_dicts !env;
  check_superinterface_obligations !env;

  (* Phase 5 (effect escape checking) now happens inline at each binding's
     boundary in process_letrec_group; the old post-HM pass is retired. *)

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
  (* Phase 78b: report a renamed shadowing binding under its original name, so
     `length` (not the internal `length#shadow`) appears in the returned env.
     The user binding sits in [results] (ahead of the prelude method's scheme in
     iface_method_schemes), so a name lookup still resolves to the user's. *)
  let unshadow (n, s) = (Method_marker.strip_shadow n, s) in
  (* Phase 84 / 115: report which *user* bindings should be promoted to
     dict-routable on a re-elaboration pass — those whose inferred constraints make
     their body's return-position method dispatch (a polymorphic-monad do-block's
     `pure`, a `Tag`/`Decode` wrapper) fail under arg-tag fallback.  Two filters,
     each guarding a concrete hazard:

     - Defined in [user_prog] (the same shadow-renamed tree this call received, so
       keys line up).  Promoting a prelude helper would add a dict param dict_pass
       can't match — the prelude marker (marked_prelude) never wraps its call
       sites in EDictApp — crashing at eval with an arity mismatch.
     - Constraint set mentions an interface with a *return-position* method (Phase
       115 generalized this from the hard-coded `Applicative`/`pure`).
       Argument-dispatched wrappers (e.g. an inferred `Eq a` over `eq`) already
       dispatch correctly by arg tag, so leave them untouched — the blast radius
       stays at return-position dispatch.

     The old non-recursive filter was dropped in Phase 115 (#2): a promoted
     wrapper's own self-/mutually-recursive EDictApp call is routed via
     env.recursive_promoted_usages / realize_recursive_dict_apps, so it no longer
     goes unrouted (which used to arity-crash → it was excluded). *)
  let promoted_out = promotable_from final_env user_prog in
  (List.map unshadow (results @ !iface_method_schemes @ !extern_schemes),
   List.rev !(final_env.warnings),
   promoted_out)

(* Phase 78a: a user binding may shadow a prelude *plain* function.  Droppable
   ones (no internal prelude use) are removed by [prelude_for] and shadow
   cleanly.  A *non*-droppable one (used internally, so it can't be dropped)
   coalesces the user clause with the prelude's; if that merge fails to
   type-check it errors *inside* the prelude — a confusing message that blames
   core.mdk.  A well-formed user program never legitimately errors at a prelude
   location, so when one does and the program shadows such a name, re-blame the
   user's own definition with an actionable message.  Compatible merges (which
   type-check) are untouched — they still work as before. *)
(* Phase 84: the promotion-aware entry point.  [promoted] names have their
   inferred constraints registered in fun_constraints (dict-routable); the
   returned third component is the set of user bindings that acquired inferred
   constraints this pass.  The two-pass elaboration (see Method_marker /
   the eval drivers) calls this once with no promotion to discover the set, then
   again with that set promoted. *)
let check_program_promoting ?(promoted : (ident, unit) Hashtbl.t option)
    (prog : program)
    : (ident * scheme) list * string list * (ident, unit) Hashtbl.t =
  (* Phase 78b: rename safe user bindings that shadow a prelude interface method
     to internal names, so they type-check as ordinary functions.  Done here so
     every typecheck caller is consistent — including LSP and diagnostics, which
     don't go through mark_with_prelude.  mark_with_prelude applies the same
     (idempotent) rename to the program the drivers later eval, keeping the two
     in step. *)
  let prog = if program_is_core prog then prog else Method_marker.shadow_rename prog in
  let shadow =
    if program_is_core prog then None
    else Method_marker.nondroppable_shadow prog in
  match shadow with
  | None -> check_program_impl ?promoted prog
  | Some (name, uloc) ->
    (try check_program_impl ?promoted prog
     with Type_error (_, Some l) when l.Ast.file = "core.mdk" ->
       fail_at uloc (CannotShadowPrelude name))

(* Single-pass entry point, unchanged for LSP / diagnostics / non-eval callers:
   no promotion, drops the discovery set. *)
let check_program (prog : program) : (ident * scheme) list * string list =
  let (schemes, warnings, _) = check_program_promoting prog in
  (schemes, warnings)

(* Multi-module type-checking entry point.
   Accepts public type exports of all previously-processed modules;
   seeds the env with imported names from use-declarations;
   returns this module's public type exports. *)
let typecheck_module
    ?(promoted : (ident, unit) Hashtbl.t option)
    ?(promoted_out : (ident, unit) Hashtbl.t option)
    (known_modules : module_type_exports list)
    (mod_id        : string)
    (prog          : program)
    : module_type_exports * (ident * scheme) list * string list =
  reset_state ();
  current_loc := None;
  current_impl_hint := None;
  let env = initial_env () in
  (* Phase 88: pass-2 promotion (mirrors check_program_impl).  [promoted] names —
     discovered across all modules on pass 1 — have their inferred constraints
     registered in fun_constraints (dict-routable) by process_letrec_group, so a
     polymorphic-monad do-block's `pure` routes by the caller's monad instead of
     arg-tag "first impl wins". *)
  (match promoted with
   | Some p -> Hashtbl.iter (fun k () -> Hashtbl.replace env.promoted k ()) p
   | None -> ());

  (* Core stdlib is always available in every module.
     Skip when this module itself IS core (avoid duplicates).
     Keep a reference to the user-only decls for export filtering — otherwise
     prelude impls would leak into every module's te_impls. *)
  let user_prog = prog in
  (* Phase 117: mirror check_program_impl's prelude_for shadow-drop on the
     multi-module path.  A module that redefines a *droppable* prelude standalone
     (e.g. string.mdk's `count`) would otherwise coalesce with the prelude's
     same-named binding in one letrec group and corrupt core's own definition
     ("core.mdk: Type mismatch").  prelude_for drops exactly those standalones and
     returns marked_prelude unchanged (same decl objects, shared in-place
     EMethodRef/EDictApp refs) when nothing is shadowed — a no-op for normal
     modules. *)
  let prog = if program_is_core prog then prog else Method_marker.prelude_for user_prog @ prog in

  register_attrs env prog;

  (* Seed env with all known module exports *)
  List.iter (fun te ->
    List.iter (fun (n, s) -> Hashtbl.replace env.ctors n s) te.te_ctors;
    (* Phase 105: rebuild env.type_ctors for imported types so the multi-clause
       exhaustiveness oracle (exhaust_oracle) can enumerate them.  te_ctors
       carries every public constructor's scheme; group by each constructor's
       result type name (a public `data` export is all-or-nothing, so this
       reconstructs the full, in-order constructor list).  Without this, a
       function totally covering an imported ADT falsely warns "non-exhaustive
       clauses". *)
    List.iter (fun (cn, Forall (_, _, t)) ->
      let rec result_type = function
        | TFun (_, _, r) -> result_type r
        | TApp (f, _)    -> result_type f
        | TCon n         -> Some n
        | TVar v         -> (match !v with Link t' -> result_type t' | _ -> None)
        | _              -> None
      in
      match result_type t with
      | Some rt ->
        let prev = match Hashtbl.find_opt env.type_ctors rt with
          | Some cs -> cs | None -> [] in
        Hashtbl.replace env.type_ctors rt (prev @ [cn])
      | None -> ()
    ) te.te_ctors;
    List.iter (fun (n, ri) -> Hashtbl.replace env.records n ri) te.te_records;
    List.iter (fun (n, _) ->
      List.iter (fun (fn, _) ->
        add_field_owner env.field_owners fn n
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
    (* Phase 69.x: import constrained-function constraints so occurrences here are
       recorded as dict applications and dict_pass agrees on their arity. *)
    List.iter (fun (n, cs) -> Hashtbl.replace env.fun_constraints n cs)
      te.te_fun_constraints;
    (* Phase 69.x-e: import method-level constraints likewise. *)
    List.iter (fun (n, cs) -> Hashtbl.replace env.method_constraints n cs)
      te.te_method_constraints;
    (* Phase 83: import inferred constraints so occurrences here record
       obligations (obligation-checking only, no dict routing). *)
    List.iter (fun (n, cs) -> Hashtbl.replace env.inferred_constraints n cs)
      te.te_inferred_constraints;
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
           | UseGroup (_, ms) -> List.map fst ms
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
    | DInterface { iface_name; type_params; methods; super; _ } ->
      let ms = register_interface ~aliases:env.aliases env (iface_name, type_params, methods, super) in
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
    List.iter (fun d -> register_impl ~seeded:true  env (Ast.inner_decl d)) Method_marker.marked_prelude;
    List.iter (fun d -> register_impl ~seeded:false env (Ast.inner_decl d)) user_prog
  end;
  check_coherence env;
  check_orphans ~known_modules ~user_prog env;

  (* Phase 112: a name imported as a value (use_schemes) that ALSO names an
     interface method is a standalone-shadowing-a-method (e.g. map's `toList`/
     `isEmpty` vs Foldable's).  Record it so the method-head application arm can
     fall back to the standalone when the receiver type has no impl. *)
  List.iter (fun (n, _) ->
    if Hashtbl.mem env.method_iface n then
      Hashtbl.replace env.standalone_values n ()
  ) !use_schemes;

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
    | DTest { test_body; _ } ->
      ignore (infer !env test_body)
    | DBench { bench_body; _ } ->
      ignore (infer !env bench_body)
    | _ -> ()
  ) prog;
  check_method_usages !env;
  check_constraint_obligations !env;
  realize_recursive_dict_apps !env;
  resolve_dict_apps !env;
  resolve_method_dicts !env;
  check_superinterface_obligations !env;
  (* Effect escape checking is done inline at the binding boundary (Phase 79e). *)

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
       a spurious "Multiple default impls" error.

       Match each surviving impl to a public DImpl in *this* module's
       user_prog by its full impl_key (iface + head type + name), not just
       the iface name.  Matching by iface name alone leaked impls from
       unrelated sibling modules: known_modules accumulates EVERY
       previously-typechecked module (not only this module's imports), so
       env.impls already holds e.g. map.mdk's `Semigroup (Map k v)` when
       array.mdk is typechecked.  If array.mdk also declares any `Semigroup`
       impl, an iface-name match re-exported the foreign `Semigroup (Map k v)`
       too — and a consumer importing both map and array then registered that
       impl twice, tripping the "Multiple default impls" coherence check. *)
    te_impls     = List.filter (fun ie ->
      not ie.impl_seeded
      && List.exists (fun d -> match Ast.inner_decl d with
        | DImpl { is_pub = true; iface_name; type_args; impl_name; _ } ->
          ie.impl_key = Ast.impl_key ~iface:iface_name ~type_args ~name:impl_name
        | _ -> false) user_prog
    ) !(!env.impls);
    te_aliases   = pub_aliases;
    (* User-declared type-constructor names of this module (prelude excluded
       since they come from user_prog) — consumed by the orphan-instance check
       to tell whether an impl's head type originates in an imported module. *)
    te_types     = type_names_of_decls user_prog;
    (* Phase 69.x: export constraints of public functions so importers route
       and parameterize them.  Keyed off the exported schemes' names. *)
    te_fun_constraints =
      List.filter_map (fun (n, _) ->
        match Hashtbl.find_opt (!env).fun_constraints n with
        | Some cs -> Some (n, cs)
        | None -> None) pub_schemes;
    (* Phase 69.x-e: export public methods' method-level constraints similarly. *)
    te_method_constraints =
      List.filter_map (fun (n, _) ->
        match Hashtbl.find_opt (!env).method_constraints n with
        | Some cs -> Some (n, cs)
        | None -> None) pub_schemes;
    (* Phase 83: export inferred constraints of public unsignatured functions. *)
    te_inferred_constraints =
      List.filter_map (fun (n, _) ->
        match Hashtbl.find_opt (!env).inferred_constraints n with
        | Some cs -> Some (n, cs)
        | None -> None) pub_schemes;
  } in
  (* Phase 88: report this module's promotable names (do-block wrappers whose
     inferred Applicative should become dict-routable on pass 2).  Collected by
     the driver across all modules and fed back as [promoted]. *)
  (match promoted_out with
   | Some out ->
     Hashtbl.iter (fun k () -> Hashtbl.replace out k ())
       (promotable_from !env user_prog)
   | None -> ());
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
  standalone_values = Hashtbl.copy e.standalone_values;
  impls         = ref !(e.impls);
  method_usages = ref !(e.method_usages);
  fun_constraints        = Hashtbl.copy e.fun_constraints;
  inferred_constraints   = Hashtbl.copy e.inferred_constraints;
  method_constraints     = Hashtbl.copy e.method_constraints;
  method_dict_routes     = Hashtbl.copy e.method_dict_routes;
  impl_dict_routes       = Hashtbl.copy e.impl_dict_routes;
  constraint_obligations = ref !(e.constraint_obligations);
  dict_app_usages        = ref !(e.dict_app_usages);
  recursive_promoted_usages = ref !(e.recursive_promoted_usages);
  type_ctors    = Hashtbl.copy e.type_ctors;
  ctor_fields   = Hashtbl.copy e.ctor_fields;
  aliases       = Hashtbl.copy e.aliases;
  warnings        = ref !(e.warnings);
  mut_vars        = e.mut_vars;                (* persistent set *)
  locals          = e.locals;
  deprecated_fns  = Hashtbl.copy e.deprecated_fns;
  must_use_fns    = Hashtbl.copy e.must_use_fns;
  promoted        = Hashtbl.copy e.promoted;
}

(* Type-check one or more declarations against an existing env.
   Updates env in place and returns (new_bindings, warnings).
   ~seeded:true marks any registered impls as prelude-seeded so that later
   user-defined impls for the same (iface, ty) take priority without ambiguity. *)
let check_repl_decl ?(seeded=false)
    ?(promoted : (ident, unit) Hashtbl.t option)
    (env : env ref) (decls : decl list)
    : (ident * scheme) list * string list =
  current_loc := None;
  current_impl_hint := None;
  (* Phase 87: env persists across REPL inputs, so clear last input's promotion
     set and install this one's.  [promoted] names have their inferred
     constraints registered in fun_constraints (dict-routable) by
     process_letrec_group — pass 2 of the REPL's two-pass elaboration, mirroring
     check_program_impl for the single-file driver. *)
  Hashtbl.reset (!env).promoted;
  (match promoted with
   | Some p -> Hashtbl.iter (fun k () -> Hashtbl.replace (!env).promoted k ()) p
   | None -> ());
  (* Phase 71: the REPL deliberately keeps the TVar counter across inputs (so it
     doesn't call reset_state), but a prior input that failed *between* an
     enter_level/exit_level pair would leave current_level > 0 and corrupt
     generalization for every later input.  Reset just the level at each input
     boundary; a completed check always balances its own brackets. *)
  current_level := 0;
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
    | DInterface { iface_name; type_params; methods; super; _ } ->
      let ms = register_interface ~aliases:(!env).aliases !env (iface_name, type_params, methods, super) in
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
    | DTest { test_body; _ } ->
      ignore (infer !env test_body)
    | DBench { bench_body; _ } ->
      ignore (infer !env bench_body)
    | _ -> ()
  ) decls;
  check_method_usages !env;
  check_constraint_obligations !env;
  realize_recursive_dict_apps !env;
  resolve_dict_apps !env;
  resolve_method_dicts !env;
  check_superinterface_obligations !env;
  (* Effect escape checking is done inline at the binding boundary (Phase 79e). *)
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
  let _ = check_repl_decl ~seeded:true env_ref Method_marker.marked_prelude in
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
  realize_recursive_dict_apps env;
  resolve_dict_apps env;
  resolve_method_dicts env;
  let scheme = generalize t in
  let (Forall (_, _, mono)) = scheme in
  (mono, List.rev !(env.warnings))
