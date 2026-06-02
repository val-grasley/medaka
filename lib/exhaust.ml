(* Exhaustiveness and redundancy checking for match expressions.
   Algorithm: Maranget, "Warnings for pattern matching" (2007).

   The public entry point is [check_match].  It is called from typecheck.ml
   after each EMatch is typed, so the scrutinee's type is already known.

   All pattern desugaring happens here so the rest of the algorithm only
   sees a small canonical subset of [Ast.pat]. *)

open Ast

(* ── Pattern desugaring ─────────────────────────────── *)

(* Desugar one pattern into the canonical form used by the matrix algorithm.
   After desugaring the only constructors are:
     PCon(c, args)  — data constructor or synthetic ones below
     PWild          — wildcard (PVar is also treated as wildcard)
     PLit l         — literal (open types: Int, Float, String, Char)

   Synthetic constructor names:
     "__tuple__"  — tuple patterns (always a singleton constructor)
     "Cons"/"Nil" — list cons / empty-list
     "True"/"False"/"Unit" — bool/unit literals *)
let rec desugar = function
  | PWild         -> PWild
  | PVar _        -> PWild             (* treat bound vars as wildcards *)
  | PLit (LBool true)  -> PCon ("True",  [])
  | PLit (LBool false) -> PCon ("False", [])
  | PLit  LUnit        -> PCon ("Unit",  [])
  | PLit l             -> PLit l       (* Int / Float / String / Char stay open *)
  | PTuple ps          -> PCon ("__tuple__", List.map desugar ps)
  | PCon (c, args)     -> PCon (c, List.map desugar args)
  | PCons (h, t)       -> PCon ("Cons", [desugar h; desugar t])
  | PList []           -> PCon ("Nil",  [])
  | PList (h :: rest)  -> PCon ("Cons", [desugar h; desugar (PList rest)])
  | PAs (_, p)         -> desugar p
  | PRec (_, _, true)  -> PWild
    (* `{ ... }` — matches any record; treat as wildcard for exhaustiveness *)
  | PRec (name, _, false) ->
    PLit (LString ("__partial_rec_" ^ name ^ "__"))
    (* Partial match without rest — open "literal" so non-exhaustiveness
       warnings still fire when no catch-all arm follows *)
  | PRng _ -> PWild
    (* Range patterns cover an open set of values — treated as wildcard so a
       sole range arm satisfies exhaustiveness for its type.  Precise interval
       coverage analysis is not implemented. *)

(* ── Matrix types ───────────────────────────────────── *)

(* A pattern vector is one row of the matrix (one pattern per column). *)
type pvec = pat list
(* A pattern matrix is a list of rows. *)
type pmat = pvec list

(* ── Matrix operations ──────────────────────────────── *)

(* S(c, P): specialize the matrix for constructor c with given arity.
   - Rows whose first element is PCon(c, args): replace first col with args.
   - Rows whose first element is PWild: replace with [arity] wildcards.
   - All other rows: drop. *)
let specialize_con c arity pmat =
  List.filter_map (fun row ->
    match row with
    | [] -> None
    | PCon (c', args) :: rest when c' = c ->
      Some (args @ rest)
    | PWild :: rest ->
      Some (List.init arity (fun _ -> PWild) @ rest)
    | _ -> None
  ) pmat

(* Specialize for a literal value.
   - Rows starting with that literal: keep (drop first col).
   - Rows starting with PWild: keep (drop first col).
   - All other rows: drop. *)
let specialize_lit l pmat =
  List.filter_map (fun row ->
    match row with
    | [] -> None
    | PLit l' :: rest when l' = l -> Some rest
    | PWild    :: rest             -> Some rest
    | _                            -> None
  ) pmat

(* D(P): default matrix — keep only rows whose first pattern is a wildcard,
   dropping that first column.  Used when the type is open or not all
   constructors are covered. *)
let default_matrix pmat =
  List.filter_map (fun row ->
    match row with
    | [] -> None
    | PWild :: rest -> Some rest
    | _             -> None
  ) pmat

(* The set of constructors that appear explicitly as the head of column 0. *)
let head_ctors pmat =
  List.filter_map (fun row ->
    match row with
    | PCon (c, _) :: _ -> Some c
    | _                -> None
  ) pmat

(* ── Type inference for column 0 ────────────────────── *)

(* When we don't know the type of column 0 statically, look at the
   constructor names actually present and ask [get_ctor_type] for their
   parent type.  Returns the first answer found. *)
let infer_col0_type get_ctor_type pmat =
  let ctors = head_ctors pmat in
  let rec try_each = function
    | []      -> None
    | c :: cs ->
      (match get_ctor_type c with
       | Some _ as t -> t
       | None        -> try_each cs)
  in
  try_each ctors

(* ── Usefulness (the Maranget recursion) ────────────── *)

(* [useful ~get_ctors ~get_arity ~get_ctor_type col0_type pmat pvec]
   returns true if [pvec] is useful given the rows already in [pmat].

   [col0_type] is the known type name for column 0 (can be None; we'll
   try to infer it from the matrix when needed). *)
let rec useful ~get_ctors ~get_arity ~get_ctor_type col0_type pmat pvec =
  match pmat, pvec with
  (* P is empty: nothing is matched yet, so q is trivially useful. *)
  | [], _ -> true
  (* q is empty but P is non-empty: q is already covered. *)
  | _ :: _, [] -> false
  | _, (h :: rest_q) ->
    match h with
    (* ── Constructor head ── *)
    | PCon (c, args) ->
      let a = List.length args in
      useful ~get_ctors ~get_arity ~get_ctor_type None
        (specialize_con c a pmat) (args @ rest_q)

    (* ── Literal head ── *)
    | PLit l ->
      (* A literal is like a constructor from an infinite open type.
         It matches if: the specific literal row fires, OR the default
         (wildcard) row fires. *)
      useful ~get_ctors ~get_arity ~get_ctor_type None
        (specialize_lit l pmat) rest_q
      || useful ~get_ctors ~get_arity ~get_ctor_type None
           (default_matrix pmat) rest_q

    (* ── Wildcard / variable head ── *)
    | _ ->
      (* Determine the type of column 0. *)
      let col0_t =
        match col0_type with
        | Some _ as t -> t
        | None        -> infer_col0_type get_ctor_type pmat
      in
      (match Option.bind col0_t get_ctors with
       | None ->
         (* Open type (Int, String, …) or unknown: fall through to default. *)
         useful ~get_ctors ~get_arity ~get_ctor_type None
           (default_matrix pmat) rest_q
       | Some ctors ->
         let present = head_ctors pmat in
         (* Is every constructor of the type explicitly covered in col 0? *)
         let all_covered =
           List.for_all (fun c -> List.mem c present) ctors
         in
         if not all_covered then
           (* Some constructor is missing; the wildcard can reach it.
              Use the default matrix to decide if the wildcard is useful
              for the wildcard rows already in P. *)
           useful ~get_ctors ~get_arity ~get_ctor_type None
             (default_matrix pmat) rest_q
         else
           (* All constructors are explicitly covered; branch on each one. *)
           List.exists (fun c ->
             let a = get_arity c in
             useful ~get_ctors ~get_arity ~get_ctor_type None
               (specialize_con c a pmat)
               (List.init a (fun _ -> PWild) @ rest_q)
           ) ctors)

(* ── Public entry point ─────────────────────────────── *)

(* [check_match ~get_ctors ~get_arity ~get_ctor_type ~warnings ~col0_type
                ~match_loc arms]

   Checks a single match expression for:
   - redundant arms (each arm is useful given the arms before it)
   - non-exhaustiveness (a wildcard is useful given all non-guarded arms)

   [arms] is a list of [(pattern, has_guard)].
   Guarded arms are excluded from the exhaustiveness matrix (the guard may
   fail at runtime) and are not themselves checked for redundancy
   (we conservatively assume the guard makes them non-redundant).

   Warnings are appended to [warnings]. *)
let pp_loc = function
  | None   -> ""
  | Some l -> Printf.sprintf "%s:%d:%d: " l.file l.line l.col

let check_match ~get_ctors ~get_arity ~get_ctor_type ~warnings ~col0_type
                ~match_loc arms =
  let u = useful ~get_ctors ~get_arity ~get_ctor_type in
  (* Work with desugared patterns. *)
  let arms_ds = List.map (fun (p, has_guard) -> (desugar p, has_guard)) arms in

  (* ── Redundancy pass ── *)
  (* Build the "definite" matrix incrementally from non-guarded arms seen so far. *)
  let matrix = ref [] in
  List.iter (fun (p, has_guard) ->
    if not has_guard then begin
      (* Check if this arm is dominated by the arms before it. *)
      if not (u col0_type !matrix [p]) then
        warnings := (pp_loc match_loc ^
          "Warning: redundant arm — this pattern is already covered") :: !warnings;
      (* Add this arm to the matrix for subsequent checks. *)
      matrix := !matrix @ [[p]]
    end
  ) arms_ds;

  (* ── Exhaustiveness pass ── *)
  (* Matrix of all non-guarded arms (already built above). *)
  let full_matrix = !matrix in
  if u col0_type full_matrix [PWild] then
    warnings := (pp_loc match_loc ^
      "Warning: non-exhaustive match — some values may not be covered") :: !warnings

(* Phase 102: coverage check for a plain multi-clause dispatch group (`f Nil =
   ..` / `f (Cons x xs) = ..`).  Such a group never becomes an [EMatch] — each
   clause is inferred as its own lambda and packaged as a `VMulti` at eval — so
   [check_match] above never sees it; an uncovered case only surfaces at runtime
   as a non-exhaustive-match error.  We run this from typecheck (where the oracle
   is type-aware and sees prelude types, unlike the Phase 91(2) lint below) by
   wrapping each clause's whole parameter list as one synthetic `__tuple__`
   column — exactly the multi-parameter reduction [check_group] uses — and asking
   whether an all-wildcard input is still useful (i.e. unmatched).

   Guards are already desugared away by the time typecheck runs, so every clause
   pattern counts as covering its shape regardless of any guard; guard
   fall-through is Phase 91(2)'s separate concern, not this.  [arity = 0] (value
   bindings) is skipped — there is nothing to be non-exhaustive over. *)
let check_clauses ~get_ctors ~get_arity ~get_ctor_type ~warnings ~loc ~arity
                  (clause_pats : pat list list) =
  if arity > 0 then begin
    let rows = List.map (fun pats -> [ desugar (PTuple pats) ]) clause_pats in
    let query = [ desugar (PTuple (List.init arity (fun _ -> PWild))) ] in
    if useful ~get_ctors ~get_arity ~get_ctor_type (Some "__tuple__") rows query
    then
      warnings := (pp_loc loc ^
        "Warning: non-exhaustive clauses — some inputs are not matched")
        :: !warnings
  end

(* ── Phase 91 (2): conservative non-exhaustive-guard detection ─────────────
   Function-clause / where-binding guards (`f n | n > 0 = ..`) desugar to nested
   `EIf` chains terminated by `__fallthrough__ ()` *before* typecheck, so they
   never reach [check_match] above.  This standalone pass runs on the *raw*
   (pre-desugar) program and warns when a guard chain may fall through with no
   clause guaranteed to produce a value.

   Guards are arbitrary `Bool`, so coverage is only decidable for `| otherwise`,
   literal `| True`, and irrefutable binds — that is the realistic target.  We
   reuse the pattern-matrix [useful] machinery to *excuse* a partial guard chain
   when its sibling clauses' patterns already cover every input (so the
   fall-through is unreachable, e.g. a final `f _ = ..` catch-all clause). *)

let rec is_irrefutable_pat = function
  | PVar _ | PWild     -> true
  | PTuple ps          -> List.for_all is_irrefutable_pat ps
  | PAs (_, p)         -> is_irrefutable_pat p
  | PRec (_, fields, _) ->
    (* A record pattern matches any value of its (single-constructor) type;
       irrefutable iff every bound sub-pattern is. *)
    List.for_all (fun (_, po) ->
      match po with None -> true | Some p -> is_irrefutable_pat p) fields
  | _ -> false

let strip_eloc = function ELoc (_, e) -> e | e -> e

(* A guard chain always succeeds iff every qualifier always succeeds: a boolean
   that is syntactically true, or an irrefutable pattern-bind. *)
let guards_decidably_exhaustive (quals : guard_qual list) : bool =
  let bool_always_true e = match strip_eloc e with
    | EVar "otherwise" | EVar "True" -> true
    | ELit (LBool true)              -> true   (* defensive; the lexer emits EVar "True" *)
    | _                              -> false
  in
  List.for_all (function
    | GBool e      -> bool_always_true e
    | GBind (p, _) -> is_irrefutable_pat p) quals

(* An `EGuards` clause body is decidably total iff some arm's chain always fires. *)
let guard_arms_total arms =
  List.exists (fun (gs, _) -> guards_decidably_exhaustive gs) arms

(* A clause `(pats, body)` is decidably total — guaranteed to produce a value for
   every input its patterns match — iff its guards (if any) are decidably
   exhaustive.  (Pattern coverage across clauses is handled by the matrix below;
   here we only judge whether *this* clause can fall through on guard grounds.) *)
let clause_guards_total (_pats, body) =
  match strip_eloc body with
  | EGuards arms -> guard_arms_total arms
  | _            -> true

let clause_is_guarded_partial (_pats, body) =
  match strip_eloc body with
  | EGuards arms -> not (guard_arms_total arms)
  | _            -> false

(* Best-effort source location: the innermost-leftmost `ELoc` inside [e]. *)
let first_loc e =
  let r = ref None in
  let _ = Desugar.map_expr
      (fun e' -> (match e' with ELoc (l, _) when !r = None -> r := Some l | _ -> ()); e') e in
  !r

(* Build a constructor oracle from the raw program's data declarations plus the
   syntactic builtins, mirroring [initial_env]/the [check_match] call site in
   typecheck.ml.  Closed prelude types (Option/Result/Ordering) are *not* in a
   user file's AST, so guard chains discriminating on them can't be excused by
   coverage — they conservatively warn (an accepted limitation of the type-free
   pass). *)
let build_oracle (prog : program) =
  let type_ctors = Hashtbl.create 32 in
  let ctor_arity = Hashtbl.create 64 in
  let ctor_type  = Hashtbl.create 64 in
  Hashtbl.replace type_ctors "Bool" ["True"; "False"];
  Hashtbl.replace type_ctors "List" ["Cons"; "Nil"];
  Hashtbl.replace type_ctors "Unit" ["Unit"];
  List.iter (fun (c, a, t) ->
      Hashtbl.replace ctor_arity c a; Hashtbl.replace ctor_type c t)
    [ ("True", 0, "Bool"); ("False", 0, "Bool");
      ("Cons", 2, "List"); ("Nil", 0, "List"); ("Unit", 0, "Unit") ];
  let rec scan d = match d with
    | DAttrib (_, d) -> scan d
    | DData (_, tyname, _, variants, _) ->
      Hashtbl.replace type_ctors tyname (List.map (fun v -> v.con_name) variants);
      List.iter (fun v ->
        let arity = match v.con_payload with
          | ConPos tys  -> List.length tys
          | ConNamed fs -> List.length fs in
        Hashtbl.replace ctor_arity v.con_name arity;
        Hashtbl.replace ctor_type v.con_name tyname) variants
    | DRecord (_, tyname, _, fields, _) ->
      Hashtbl.replace type_ctors tyname [tyname];
      Hashtbl.replace ctor_arity tyname (List.length fields);
      Hashtbl.replace ctor_type tyname tyname
    | DNewtype (_, tyname, _, conname, _, _) ->
      Hashtbl.replace type_ctors tyname [conname];
      Hashtbl.replace ctor_arity conname 1;
      Hashtbl.replace ctor_type conname tyname
    | _ -> ()
  in
  List.iter scan prog;
  (type_ctors, ctor_arity, ctor_type)

(* Check one group of clauses sharing a name (multi-clause dispatch unit).  Warn
   once if some clause's guards may fall through AND the non-falling-through
   clauses' patterns don't already cover every input. *)
let check_group ~type_ctors ~ctor_arity ~ctor_type warnings clauses =
  if List.exists clause_is_guarded_partial clauses then begin
    let group_arity = match clauses with
      | (pats, _) :: _ -> List.length pats
      | []             -> 0 in
    let get_ctors t = Hashtbl.find_opt type_ctors t in
    let get_ctor_type c =
      if c = "__tuple__" then Some "__tuple__" else Hashtbl.find_opt ctor_type c in
    let get_arity c =
      if c = "__tuple__" then group_arity
      else match Hashtbl.find_opt ctor_arity c with Some a -> a | None -> 0 in
    (* Wrap each clause's parameter list as a synthetic tuple so multi-parameter
       coverage reduces to a single __tuple__ column.  Guarded-partial clauses
       are excluded — their guard might fail at runtime. *)
    let rows =
      List.filter_map (fun c ->
        if clause_guards_total c then Some [ desugar (PTuple (fst c)) ] else None)
        clauses in
    if useful ~get_ctors ~get_arity ~get_ctor_type
         (Some "__tuple__") rows [ desugar (PTuple (List.init group_arity (fun _ -> PWild))) ]
    then begin
      let loc =
        List.find_map (fun c ->
          if clause_is_guarded_partial c then first_loc (snd c) else None) clauses in
      warnings := (pp_loc loc ^ "Warning: guards may not be exhaustive") :: !warnings
    end
  end

(* Group same-name (name, clause) pairs into clause lists, preserving the order
   names are first seen. *)
let group_by_name (items : (ident * (pat list * expr)) list) : (pat list * expr) list list =
  let tbl = Hashtbl.create 16 in
  let order = ref [] in
  List.iter (fun (n, clause) ->
    (match Hashtbl.find_opt tbl n with
     | None    -> order := n :: !order; Hashtbl.replace tbl n [clause]
     | Some cs -> Hashtbl.replace tbl n (clause :: cs))) items;
  List.rev_map (fun n -> List.rev (Hashtbl.find tbl n)) !order

let check_guard_exhaustiveness (prog : program) : string list =
  let warnings = ref [] in
  let (type_ctors, ctor_arity, ctor_type) = build_oracle prog in
  let check = check_group ~type_ctors ~ctor_arity ~ctor_type warnings in
  (* Nested where/let groups (ELetGroup) reached anywhere inside an expression. *)
  let visit_expr e =
    (match e with
     | ELetGroup (groups, _) -> List.iter (fun (_, clauses) -> check clauses) groups
     | _ -> ()); e
  in
  let recurse_body e = ignore (Desugar.map_expr visit_expr e) in
  (* Top-level same-name function clauses. *)
  group_by_name (List.filter_map (fun d ->
      match inner_decl d with
      | DFunDef (_, n, pats, body) -> Some (n, (pats, body))
      | _ -> None) prog)
  |> List.iter check;
  (* All other clause sources + recursion into every expression body. *)
  List.iter (fun d ->
    match inner_decl d with
    | DFunDef (_, _, _, body) -> recurse_body body
    | DLetGroup (_, groups) ->
      List.iter (fun (_, clauses) ->
        check clauses;
        List.iter (fun (_, b) -> recurse_body b) clauses) groups
    | DImpl impl ->
      group_by_name (List.map (fun (n, ps, b) -> (n, (ps, b))) impl.methods)
      |> List.iter check;
      List.iter (fun (_, _, b) -> recurse_body b) impl.methods
    | DInterface iface ->
      List.iter (fun m ->
        match m.method_default with
        | Some (_, b) -> recurse_body b
        | None -> ()) iface.methods
    | DProp p  -> recurse_body p.prop_body
    | DBench b -> recurse_body b.bench_body
    | _ -> ()) prog;
  List.rev !warnings
