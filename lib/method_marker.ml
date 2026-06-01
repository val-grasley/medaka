(* Phase 69 marker pass.  Runs after resolve / desugar and before typecheck,
   on the tree shared by both typecheck and eval.  Rewrites every interface-
   method occurrence `EVar m` into `EMethodRef (ref None, m)` so the typechecker
   can record (in place) which impl each call site resolves to, and eval can
   route VMulti dispatch by that choice — fixing return-position and multi-param
   dispatch.  The ref is filled in place during typechecking; because the marked
   tree is the same value eval runs, no return-threading is needed.

   Phase 69.x extends this: every occurrence of a *constrained function* (one
   whose signature carries `=>`) becomes `EDictApp (ref None, f)`, the dual node
   for dictionary passing.  Typecheck fills its routes (one per constraint) and
   eval applies the resolved dictionaries as leading arguments — the dicts that
   dict_pass prepends as parameters on the function's definition.  Only
   *user-defined* constrained functions are wrapped (mirroring Phase 69's
   user-code-only scope); references to prelude constrained functions stay bare
   and use arg-tag dispatch as before. *)

open Ast

(* Collect the names of all interface methods declared across the given
   programs (e.g. the prelude plus the user program).  Method names are global
   identifiers in Medaka, so a flat name set is enough to identify occurrences. *)
let interface_method_names (programs : program list) : (ident, unit) Hashtbl.t =
  let tbl = Hashtbl.create 64 in
  let scan_decl d =
    match inner_decl d with
    | DInterface { methods; _ } ->
      List.iter (fun m -> Hashtbl.replace tbl m.method_name ()) methods
    | _ -> ()
  in
  List.iter (fun prog -> List.iter scan_decl prog) programs;
  tbl

(* Collect the names of functions whose declared signature carries a constraint
   (`Foo a => …`).  These are exactly the functions typecheck records in
   `fun_constraints` and dict_pass gives dictionary parameters, so their
   occurrences must be wrapped in EDictApp.  Scoped to the program(s) given —
   callers pass the user program only, so prelude constrained functions are not
   wrapped. *)
let constrained_fn_names (programs : program list) : (ident, unit) Hashtbl.t =
  let tbl = Hashtbl.create 32 in
  let is_constrained = function
    | TyConstrained _ -> true
    | _ -> false
  in
  let scan_decl d =
    match inner_decl d with
    | DTypeSig (_, name, ty) when is_constrained ty -> Hashtbl.replace tbl name ()
    | _ -> ()
  in
  List.iter (fun prog -> List.iter scan_decl prog) programs;
  tbl

(* Rewrite a single expression node: a bare method-name variable becomes an
   EMethodRef carrying a fresh, unfilled ref; a constrained-function-name
   variable becomes an EDictApp.  `@Name` hint vars start with '@' and are
   neither, so they pass through untouched.  Method names take precedence (a
   name is never both an interface method and a constrained top-level fn). *)
let mark_node (methods : (ident, unit) Hashtbl.t)
              (constrained : (ident, unit) Hashtbl.t) = function
  | EVar x when Hashtbl.mem methods x     -> EMethodRef (ref None, x)
  | EVar x when Hashtbl.mem constrained x -> EDictApp (ref None, x)
  | e -> e

(* Map over every expression in a declaration.  Desugar.map_decl skips
   DLetGroup and DBench bodies (its catch-all), so we handle those here and
   delegate the rest — including interface defaults and impl method bodies —
   to Desugar.map_decl, whose expr recursion is complete. *)
let rec mark_decl methods constrained d =
  let f = mark_node methods constrained in
  match d with
  | DLetGroup (pub, groups) ->
    DLetGroup (pub, List.map (fun (n, clauses) ->
      (n, List.map (fun (ps, body) -> (ps, Desugar.map_expr f body)) clauses))
      groups)
  | DBench b -> DBench { b with bench_body = Desugar.map_expr f b.bench_body }
  | DAttrib (attrs, inner) -> DAttrib (attrs, mark_decl methods constrained inner)
  | other -> Desugar.map_decl f other

let mark_program (methods : (ident, unit) Hashtbl.t)
                 (constrained : (ident, unit) Hashtbl.t) (prog : program) : program =
  List.map (mark_decl methods constrained) prog

(* Phase 69.x-c: the prelude, marked against its own interface methods and
   constrained functions, computed once.  typecheck prepends *this* tree (so it
   fills each prelude EMethodRef/EDictApp ref in place) and the typed eval
   drivers prepend the same value before dict_pass, so a prelude function like
   `when b m = if b then m else pure ()` routes its return-position `pure`
   through the dictionary mechanism instead of the legacy monad-tag workaround.
   Structurally identical to `Prelude.program` (same decls), so impl/iface/type
   scans are unaffected; only expression bodies carry the marker nodes.  Its
   body refs are refilled idempotently on each typecheck (prelude resolution is
   program-independent), and dict_pass never mutates it in place. *)
let marked_prelude : program =
  let methods = interface_method_names [Prelude.program] in
  let constrained = constrained_fn_names [Prelude.program] in
  mark_program methods constrained Prelude.program

(* ── Phase 78a: prelude plain-function shadowing ───────────────────────────
   A user module may define a top-level function whose name collides with a
   prelude *plain function* (a standalone `DFunDef`, e.g. `count`).  The prelude
   is prepended source, so without intervention the user clause coalesces with
   the prelude clause — `group_fundefs`/`fundef_acc` key by name — yielding a
   bogus merged multi-clause function and a type error reported inside the
   prelude.  The fix: when the user shadows such a name, drop the prelude's
   definition of it so the user's wins.  Restricted to standalone `DFunDef`s
   that no *other* prelude declaration references — dropping a name the prelude
   uses internally would silently rebind those uses to the user's function.
   (Interface-method shadowing — `length`/`isEmpty`/`toList` etc. — is Phase
   78b; those need dispatch-aware handling, not a plain drop.) *)

(* Top-level names a declaration binds (used to exclude self-references). *)
let decl_defined_names (d : decl) : ident list =
  match inner_decl d with
  | DFunDef (_, n, _, _)   -> [n]
  | DLetGroup (_, gs)      -> List.map fst gs
  | DImpl { methods; _ }   -> List.map (fun (n, _, _) -> n) methods
  | DInterface { methods; _ } -> List.map (fun m -> m.method_name) methods
  | _ -> []

(* Names referenced (EVar / EMethodRef / EDictApp) anywhere in a declaration's
   expression bodies.  Mirrors mark_decl's coverage of DLetGroup/DBench, which
   Desugar.map_decl skips. *)
let decl_referenced_names (acc : (ident, unit) Hashtbl.t) (d : decl) : unit =
  let f e =
    (match e with
     | EVar x | EMethodRef (_, x) | EDictApp (_, x) -> Hashtbl.replace acc x ()
     | _ -> ());
    e
  in
  let rec go = function
    | DLetGroup (_, gs) ->
      List.iter (fun (_, clauses) ->
        List.iter (fun (_, body) -> ignore (Desugar.map_expr f body)) clauses) gs
    | DBench b -> ignore (Desugar.map_expr f b.bench_body)
    | DAttrib (_, inner) -> go inner
    | other -> ignore (Desugar.map_decl f other)
  in
  go d

(* Prelude plain-function names: standalone DFunDefs that are not interface
   methods.  These are the names a user module can collide with — droppable or
   not.  Computed once (the prelude is program-independent). *)
let prelude_plain_fn_names : (ident, unit) Hashtbl.t =
  let methods = interface_method_names [Prelude.program] in
  let tbl = Hashtbl.create 64 in
  List.iter (fun d -> match inner_decl d with
    | DFunDef (_, n, _, _) when not (Hashtbl.mem methods n) ->
      Hashtbl.replace tbl n ()
    | _ -> ()
  ) Prelude.program;
  tbl

(* The subset safe to let a user shadow: a prelude plain function not referenced
   by any *other* prelude declaration.  Dropping one the prelude uses internally
   would silently rebind those uses to the user's function, so it is excluded. *)
let droppable_prelude_fns : (ident, unit) Hashtbl.t =
  let candidates = Hashtbl.copy prelude_plain_fn_names in
  List.iter (fun d ->
    let defines = decl_defined_names d in
    let refs = Hashtbl.create 16 in
    decl_referenced_names refs d;
    Hashtbl.iter (fun r () ->
      if not (List.mem r defines) then Hashtbl.remove candidates r
    ) refs
  ) Prelude.program;
  candidates

(* User top-level value names that could shadow a prelude binding. *)
let user_value_names (prog : program) : (ident, unit) Hashtbl.t =
  let tbl = Hashtbl.create 32 in
  List.iter (fun d -> match inner_decl d with
    | DFunDef (_, n, _, _) -> Hashtbl.replace tbl n ()
    | DLetGroup (_, gs)    -> List.iter (fun (n, _) -> Hashtbl.replace tbl n ()) gs
    | _ -> ()
  ) prog;
  tbl

(* The droppable prelude plain functions this user program actually shadows. *)
let shadowed_prelude_fns (prog : program) : (ident, unit) Hashtbl.t =
  let users = user_value_names prog in
  let tbl = Hashtbl.create 8 in
  Hashtbl.iter (fun n () ->
    if Hashtbl.mem droppable_prelude_fns n then Hashtbl.replace tbl n ()
  ) users;
  tbl

(* The first user binding (if any) that shadows a prelude plain function the
   prelude references internally — so it is *not* droppable and would otherwise
   coalesce into a confusing prelude-internal type mismatch.  Returns the name
   and the location of the user's definition for a clear diagnostic.  Phase 78a
   supports shadowing only prelude functions with no internal uses; this lets a
   driver reject the rest up front. *)
let nondroppable_shadow (prog : program) : (ident * Ast.loc option) option =
  (* Any location within the body — its subexpressions all sit on the
     definition's line(s), so the outermost ELoc seen (map_expr applies f
     bottom-up, parent last) points at the user's definition. *)
  let body_loc body =
    let found = ref None in
    let f node = (match node with ELoc (l, _) -> found := Some l | _ -> ()); node in
    ignore (Desugar.map_expr f body);
    !found
  in
  let offends n = Hashtbl.mem prelude_plain_fn_names n
                  && not (Hashtbl.mem droppable_prelude_fns n) in
  let rec find = function
    | [] -> None
    | d :: rest ->
      let hit = match inner_decl d with
        | DFunDef (_, n, _, body) when offends n -> Some (n, body_loc body)
        | DLetGroup (_, gs) ->
          List.fold_left (fun acc (n, clauses) ->
            match acc with
            | Some _ -> acc
            | None when offends n ->
              Some (n, match clauses with (_, body) :: _ -> body_loc body | [] -> None)
            | None -> None
          ) None gs
        | _ -> None
      in
      (match hit with Some _ -> hit | None -> find rest)
  in
  find prog

(* The prelude to prepend ahead of [prog]: [marked_prelude] with the plain
   functions [prog] shadows (and their type signatures) removed.  Returns
   [marked_prelude] unchanged when nothing is shadowed, and otherwise the same
   surviving decl objects (List.filter preserves identity), so the in-place
   EMethodRef/EDictApp refs typecheck fills remain shared with eval. *)
let prelude_for (prog : program) : program =
  let drop = shadowed_prelude_fns prog in
  if Hashtbl.length drop = 0 then marked_prelude
  else List.filter (fun d -> match inner_decl d with
    | DFunDef (_, n, _, _) | DTypeSig (_, n, _) -> not (Hashtbl.mem drop n)
    | _ -> true
  ) marked_prelude

(* Convenience: mark a user program against the prelude's interface methods
   plus its own, and against the prelude's *and* its own constrained functions
   (so a user reference to a prelude constrained fn like `when` becomes an
   EDictApp that supplies its dictionaries).  Used by the single-file drivers. *)
let mark_with_prelude (prog : program) : program =
  let methods = interface_method_names [Prelude.program; prog] in
  let constrained = constrained_fn_names [Prelude.program; prog] in
  (* Phase 78a: a prelude plain function the user shadows is no longer the
     prelude's constrained function — the user's (possibly unconstrained)
     definition wins.  Drop it from the constrained set unless the user
     re-declared it constrained, so the user reference stays a bare EVar that
     resolves to their own binding rather than an EDictApp with no dictionaries. *)
  let shadowed = shadowed_prelude_fns prog in
  if Hashtbl.length shadowed > 0 then begin
    let user_constrained = constrained_fn_names [prog] in
    Hashtbl.iter (fun n () ->
      if not (Hashtbl.mem user_constrained n) then Hashtbl.remove constrained n
    ) shadowed
  end;
  mark_program methods constrained prog

(* Mark a single repl item against a pre-built method-name set (the session's
   known interface methods plus any the item itself declares) and a
   constrained-function-name set.  The repl can't use the program-list helpers
   because interfaces and signatures accrue across inputs. *)
let mark_repl_item (methods : (ident, unit) Hashtbl.t)
                   (constrained : (ident, unit) Hashtbl.t) (item : repl_item) : repl_item =
  match item with
  | ReplDecl decls -> ReplDecl (mark_program methods constrained decls)
  | ReplExpr e -> ReplExpr (Desugar.map_expr (mark_node methods constrained) e)
