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
