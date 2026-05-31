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

(* Collect fn_name → dict-arity from the filled EDictApp nodes across the tree. *)
let collect_arities (prog : program) : (ident, int) Hashtbl.t =
  let tbl = Hashtbl.create 32 in
  let note e =
    (match e with
     | EDictApp (r, f) ->
       (match !r with
        | Some routes -> Hashtbl.replace tbl f (List.length routes)
        | None -> ())
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
  | DAttrib (attrs, inner) -> DAttrib (attrs, run_decl arities inner)
  | other -> other

(* Build an arity map (fn → number of dict params) from typecheck's
   fun_constraints table. *)
let arities_of_fun_constraints (fc : (ident, (ident * int list) list) Hashtbl.t)
    : (ident, int) Hashtbl.t =
  let tbl = Hashtbl.create 32 in
  Hashtbl.iter (fun n cs -> Hashtbl.replace tbl n (List.length cs)) fc;
  tbl

let run ?fun_constraints (prog : program) : program =
  let arities = match fun_constraints with
    | Some fc -> arities_of_fun_constraints fc
    | None -> collect_arities prog
  in
  List.map (run_decl arities) prog
