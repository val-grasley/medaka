(* Phase 69.x dictionary passing — definition side.

   Runs after typecheck (which filled every EMethodRef / EDictApp route in place)
   and before eval, on the *user* program tree.  Every occurrence of a
   constrained function is an EDictApp whose filled routes list has one entry per
   constraint; eval applies those dictionaries as leading arguments.  This pass
   adds the matching leading *parameters* to each such function's definition,
   named [Ast.dict_param_name fn slot] in the same slot order — so parameters and
   arguments line up by construction, and an EMethodRef stamped `RDict
   $dict_fn_slot` in the body reads the right one.

   The required dict-arity per function comes from one of two sources:
   - whole-program drivers (single-file / multi-module) read it straight off the
     tree — the length of the routes list on any EDictApp referring to that
     function (all references agree);
   - the REPL, where a function's definition and its uses arrive in separate
     batches, passes typecheck's `fun_constraints` explicitly, since the
     definition's batch may contain no reference to learn the arity from.
   Both agree by construction: a routes list has exactly one entry per
   fun_constraints constraint.  A function that is never referenced and isn't in
   fun_constraints gets no parameters, which is sound because eval never applies
   it.  Scope mirrors the marker — only top-level user functions, since the
   prelude runs unmarked and nested `where`-bound functions never become
   EDictApp. *)

open Ast

(* Collect name → dict-arity from the filled EDictApp / EMethodRef nodes across
   the tree.  EDictApp routes give a constrained function's arity; an
   EMethodRef's res_method_dicts (Phase 69.x-e) gives an interface method's
   method-level-constraint arity, so dict_pass adds matching leading params to
   that method's default body and impl clauses. *)
let collect_arities (prog : program) : (ident, int) Hashtbl.t =
  let tbl = Hashtbl.create 32 in
  let note e =
    (match e with
     | EDictApp (r, f) ->
       (match !r with
        | Some routes -> Hashtbl.replace tbl f (List.length routes)
        | None -> ())
     | EMethodRef (r, m) ->
       (match !r with
        | Some { Ast.res_method_dicts = (_ :: _ as ds); _ } ->
          Hashtbl.replace tbl m (List.length ds)
        | _ -> ())
     | _ -> ());
    e
  in
  let rec scan_decl d =
    match d with
    | DLetGroup (_, groups) ->
      List.iter (fun (_, clauses) ->
        List.iter (fun (_, body) -> ignore (Desugar.map_expr note body)) clauses)
        groups
    | DBench b -> ignore (Desugar.map_expr note b.bench_body)
    | DAttrib (_, inner) -> scan_decl inner
    | other -> ignore (Desugar.map_decl note other)
  in
  List.iter scan_decl prog;
  tbl

let dict_pats fname n =
  List.init n (fun slot -> PVar (dict_param_name fname slot))

let rec run_decl arities d =
  let arity_of n = match Hashtbl.find_opt arities n with Some k -> k | None -> 0 in
  match d with
  | DFunDef (pub, n, pats, body) ->
    let k = arity_of n in
    if k = 0 then d else DFunDef (pub, n, dict_pats n k @ pats, body)
  | DLetGroup (pub, bindings) ->
    DLetGroup (pub, List.map (fun (n, clauses) ->
      let k = arity_of n in
      if k = 0 then (n, clauses)
      else (n, List.map (fun (pats, body) -> (dict_pats n k @ pats, body)) clauses)
    ) bindings)
  (* Phase 69.x-e: a method with method-level constraints (e.g. foldMap) takes
     leading dict params on its default body and on every explicit impl clause,
     so call sites can apply the Monoid/Semigroup dictionaries as leading args.
     Params are named after the *method* (dict_param_name foldMap slot) to match
     the RDict routes stamped on the bodies' inner method refs. *)
  | DInterface ({ methods; _ } as i) ->
    DInterface { i with methods = List.map (fun m ->
      let k = arity_of m.method_name in
      if k = 0 then m
      else { m with method_default =
        Option.map (fun (pats, body) -> (dict_pats m.method_name k @ pats, body))
          m.method_default }
    ) methods }
  (* Phase 83/84: an impl with `requires` constraints (e.g.
     `impl Arbitrary (List a) requires Arbitrary a`) takes one leading dict param
     per requires on each of its *return-position* method clauses, after any
     method-level params, so a return-position ref in the body reads the impl's
     element dict.  Only return-position methods qualify — typecheck stamps an
     RDict route to `$dict_<method>_<slot>` only for those, so we add the params
     exactly when the body references one (arg-position methods like show/eq stay
     on arg-tag).  Params named `dict_param_name method (k_method + slot)` to
     match the routes and the order eval applies res_impl_dicts. *)
  | DImpl ({ methods; requires; _ } as i) ->
    let n_impl = List.length requires in
    DImpl { i with methods = List.map (fun (n, pats, body) ->
      let k = arity_of n in
      let impl_names = List.init n_impl (fun slot -> dict_param_name n (k + slot)) in
      let uses_impl_dict =
        n_impl > 0 &&
        (let found = ref false in
         let note e =
           (match e with
            | EMethodRef (r, _) ->
              (match !r with
               | Some { Ast.res_route = RDict d; _ } when List.mem d impl_names ->
                 found := true
               | _ -> ())
            | _ -> ()); e in
         ignore (Desugar.map_expr note body); !found) in
      let impl_pats = if uses_impl_dict then List.map (fun nm -> PVar nm) impl_names else [] in
      if k = 0 && not uses_impl_dict then (n, pats, body)
      else (n, dict_pats n k @ impl_pats @ pats, body)
    ) methods }
  | DAttrib (attrs, inner) -> DAttrib (attrs, run_decl arities inner)
  | other -> other

(* Build an arity map (fn → number of dict params) from typecheck's
   fun_constraints table. *)
let arities_of_fun_constraints (fc : (ident, (ident * int list) list) Hashtbl.t)
    : (ident, int) Hashtbl.t =
  let tbl = Hashtbl.create 32 in
  Hashtbl.iter (fun n cs -> Hashtbl.replace tbl n (List.length cs)) fc;
  tbl

let run ?fun_constraints ?method_constraints (prog : program) : program =
  let arities = match fun_constraints, method_constraints with
    | None, None -> collect_arities prog
    | _ ->
      (* REPL path: a definition's batch may hold no reference to learn arity
         from, so take it from typecheck's tables directly.  Method-level
         constraints (Phase 69.x-e) merge in alongside function-level ones. *)
      let tbl = match fun_constraints with
        | Some fc -> arities_of_fun_constraints fc
        | None -> Hashtbl.create 32
      in
      (match method_constraints with
       | Some mc -> Hashtbl.iter (fun n cs -> Hashtbl.replace tbl n (List.length cs)) mc
       | None -> ());
      tbl
  in
  List.map (run_decl arities) prog
