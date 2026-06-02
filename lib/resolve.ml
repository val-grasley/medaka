(* Name resolution: walk the AST after parsing, verify that every
   identifier reference resolves to a binding. Produces a list of errors;
   does not modify the AST. *)

open Ast

(* ── Errors ────────────────────────────────────── *)

type error =
  | UnboundVariable      of ident
  | UnknownConstructor   of ident
  | UnknownType          of ident
  | UnknownEffect        of ident
  | UnknownField         of ident          (* field name not declared in any record *)
  | FieldNotInRecord     of ident * ident  (* field, record — field exists but not in this record *)
  | DuplicateDefinition  of string * ident  (* kind, name *)
  | UnknownInterface     of ident           (* impl references an unknown interface *)
  | MethodNotInInterface of ident * ident   (* method name, interface name *)
  | ExternWithBody       of ident           (* extern name also has a fun_def *)
  | PrivateNameAccess    of ident * string  (* name, owning module *)
  | UnknownModule        of ident           (* use references a module that can't be found *)
  | QuestionMisplaced                       (* `?` outside `let pat = e ?` position *)
  | NonRecursiveValueLet of ident           (* `let x = ... x ...` (no `rec`) where x is in scope on RHS *)

let current_loc : Ast.loc option ref = ref None

let pp_error = function
  | UnboundVariable n      -> Printf.sprintf "Unbound variable: %s" n
  | UnknownConstructor n   -> Printf.sprintf "Unknown constructor: %s" n
  | UnknownType n          -> Printf.sprintf "Unknown type: %s" n
  | UnknownEffect n        -> Printf.sprintf "Unknown effect: %s" n
  | UnknownField n         -> Printf.sprintf "Unknown field: %s" n
  | FieldNotInRecord (f, r)-> Printf.sprintf "Field %s does not belong to record %s" f r
  | DuplicateDefinition (k, n) -> Printf.sprintf "Duplicate %s: %s" k n
  | UnknownInterface n     -> Printf.sprintf "Unknown interface: %s" n
  | MethodNotInInterface (m, iface) ->
    Printf.sprintf "Method '%s' is not part of interface %s" m iface
  | ExternWithBody n ->
    Printf.sprintf "extern '%s' must not have a definition body" n
  | PrivateNameAccess (n, m) ->
    Printf.sprintf "'%s' is private to module %s" n m
  | UnknownModule n ->
    Printf.sprintf "Unknown module: %s" n
  | QuestionMisplaced ->
    "`?` is only allowed as the right-hand side of a `let` binding, \
     e.g. `let x = expr ?`. Use `<-` inside do-blocks."
  | NonRecursiveValueLet n ->
    Printf.sprintf
      "'%s' is not in scope on the right-hand side of its own binding. \
       Non-function `let` bindings are not recursive — write `let rec %s = ...` \
       to opt in to recursion (the RHS must be a lambda)."
      n n

(* ── Built-ins ─────────────────────────────────── *)

(* Until the stdlib exists, these are baked in. *)

(* Built-in primitive types not declared in stdlib/core.mdk.  Option/Result/
   Ordering live in core.mdk and flow in via prelude_types — they must not
   appear here, otherwise type-checking core.mdk standalone reports a duplicate
   (see program_is_core handling below). *)
let primitive_types = [
  "Int"; "Float"; "String"; "Char"; "Bool"; "Unit";
  "List"; "Ref";
  "Array"; "MutArray"; "Map"; "HashMap"; "Set"; "HashSet";
]

(* True/False are lexer keywords, not declared in stdlib/core.mdk like the
   rest of the constructors (Some/None/Ok/Err/Lt/Eq/Gt — those flow in via
   prelude_constructors below). *)
let primitive_constructors = [
  "True"; "False";
]

let primitive_values = Runtime.names

let built_in_effects = [
  "IO"; "Mut"; "Async"; "Panic"; "Rand"; "Time";
]

(* Names derived once from the parsed prelude (stdlib/core.mdk). *)
let prelude_types : string list =
  List.filter_map (function
    | Ast.DData (_, n, _, _, _) | Ast.DRecord (_, n, _, _, _)
    | Ast.DNewtype (_, n, _, _, _, _) -> Some n
    | _ -> None) Prelude.program

let prelude_constructors : string list =
  List.concat_map (function
    | Ast.DData (_, _, _, vs, _) -> List.map (fun v -> v.Ast.con_name) vs
    | Ast.DNewtype (_, _, _, con, _, _) -> [con]
    | _ -> []) Prelude.program

let prelude_interfaces : (string * string list) list =
  List.filter_map (function
    | Ast.DInterface { iface_name; methods; _ } ->
      Some (iface_name, List.map (fun m -> m.Ast.method_name) methods)
    | _ -> None) Prelude.program

let prelude_values : string list =
  List.concat_map (function
    | Ast.DFunDef (_, n, _, _) -> [n]
    | Ast.DLetGroup (_, bs)    -> List.map fst bs
    | Ast.DTypeSig (_, n, _)   -> [n]
    | Ast.DImpl { methods; _ } -> List.map (fun (n, _, _) -> n) methods
    (* Interface methods become global identifiers — `max`, `min`, `show`
       etc. need to resolve in user files even when no impl in core
       provides them (the interface default suffices at runtime).  This
       mirrors what build_env does for interface decls in the user
       program (see the DInterface case below). *)
    | Ast.DInterface { methods; _ } ->
      List.map (fun m -> m.Ast.method_name) methods
    | _ -> []) Prelude.program

(* Record (and named-field constructor) fields from the prelude, mapped to
   their owning type/constructor.  Without this, field access and record
   construction for prelude records (e.g. `RField`, used by derived
   `Generic` impls) fail resolution. *)
let prelude_field_owners : (string * string) list =
  List.concat_map (function
    | Ast.DRecord (_, n, _, fs, _) ->
      List.map (fun f -> (f.Ast.field_name, n)) fs
    | Ast.DData (_, _, _, vs, _) ->
      List.concat_map (fun v -> match v.Ast.con_payload with
        | Ast.ConNamed fs -> List.map (fun f -> (f.Ast.field_name, v.Ast.con_name)) fs
        | Ast.ConPos _ -> []) vs
    | _ -> []) Prelude.program

(* Phase 72: field_owners is a multimap — a field name may belong to several
   record/ctor types, and access resolves by the receiver's inferred type in the
   type checker.  These helpers keep insertion idempotent and read membership. *)
let add_field_owner tbl field owner =
  if not (List.mem owner (Hashtbl.find_all tbl field)) then
    Hashtbl.add tbl field owner

let field_belongs tbl field owner = List.mem owner (Hashtbl.find_all tbl field)
let field_known   tbl field = Hashtbl.find_all tbl field <> []

(* ── Module exports (public interface of a resolved module) ── *)

type module_exports = {
  exp_mod_id          : string;
  exp_values          : (ident, unit) Hashtbl.t;
  exp_types           : (ident, unit) Hashtbl.t;
  exp_constructors    : (ident, unit) Hashtbl.t;
  exp_fields          : (ident, unit) Hashtbl.t;
  exp_field_owners    : (ident, string) Hashtbl.t;
  exp_interfaces      : (ident, unit) Hashtbl.t;
  exp_iface_methods   : (ident, ident list) Hashtbl.t;
}

(* ── Module environment ────────────────────────── *)

type module_env = {
  values         : (ident, unit) Hashtbl.t;
  types          : (ident, unit) Hashtbl.t;
  constructors   : (ident, unit) Hashtbl.t;
  fields         : (ident, unit) Hashtbl.t;
  field_owners   : (ident, string) Hashtbl.t;  (* field name → record type name *)
  interfaces     : (ident, unit) Hashtbl.t;
  iface_methods  : (ident, ident list) Hashtbl.t;  (* iface name → method names *)
  imported       : (ident, unit) Hashtbl.t;
  (* Alias map: for `use foo as F` or qualified `use foo`, F/foo → module_exports *)
  module_aliases : (ident, module_exports) Hashtbl.t;
}

let create_env ?(with_prelude=true) () =
  let env = {
    values         = Hashtbl.create 32;
    types          = Hashtbl.create 16;
    constructors   = Hashtbl.create 16;
    fields         = Hashtbl.create 16;
    field_owners   = Hashtbl.create 16;
    interfaces     = Hashtbl.create 8;
    iface_methods  = Hashtbl.create 8;
    imported       = Hashtbl.create 8;
    module_aliases = Hashtbl.create 4;
  } in
  List.iter (fun n -> Hashtbl.replace env.types n ()) primitive_types;
  List.iter (fun n -> Hashtbl.replace env.constructors n ()) primitive_constructors;
  List.iter (fun n -> Hashtbl.replace env.values n ()) primitive_values;
  if with_prelude then begin
    (* Seed names from the core stdlib prelude *)
    List.iter (fun n -> Hashtbl.replace env.types n ()) prelude_types;
    List.iter (fun n -> Hashtbl.replace env.constructors n ()) prelude_constructors;
    List.iter (fun (iface, methods) ->
      Hashtbl.replace env.interfaces iface ();
      Hashtbl.replace env.iface_methods iface methods
    ) prelude_interfaces;
    List.iter (fun n -> Hashtbl.replace env.values n ()) prelude_values;
    List.iter (fun (fname, owner) ->
      Hashtbl.replace env.fields fname ();
      add_field_owner env.field_owners fname owner
    ) prelude_field_owners
  end;
  env

(* When the program itself is core.mdk (detected by the simultaneous presence
   of `data Ordering` and `interface Foldable`), avoid pre-seeding prelude
   names so the user-side declarations don't collide with them. *)
let program_is_core (prog : program) : bool =
  let has_ordering = List.exists (function
    | Ast.DData (_, "Ordering", _, _, _) -> true | _ -> false) prog in
  let has_foldable = List.exists (function
    | Ast.DInterface { iface_name = "Foldable"; _ } -> true | _ -> false) prog in
  has_ordering && has_foldable

(* ── Pattern utilities ─────────────────────────── *)

let rec pat_bindings = function
  | PVar x       -> [x]
  | PWild        -> []
  | PLit _       -> []
  | PCon (_, ps) -> List.concat_map pat_bindings ps
  | PCons (a, b) -> pat_bindings a @ pat_bindings b
  | PTuple ps    -> List.concat_map pat_bindings ps
  | PList ps     -> List.concat_map pat_bindings ps
  | PAs (x, p)  -> x :: pat_bindings p
  | PRec (_, fields, _) ->
    List.concat_map (fun (fname, pat_opt) ->
      match pat_opt with
      | None   -> [fname]
      | Some p -> pat_bindings p
    ) fields
  | PRng _ -> []

(* ── Phase 1: build env from top-level decls ──── *)

(* Resolve a use_path against known module exports, returning the module_id
   that the path refers to. *)
let use_path_module_id = function
  | UseName ns ->
    (* use foo.bar → module "foo", name "bar";  use foo → module "foo" (alias) *)
    if List.length ns > 1 then
      String.concat "." (List.rev (List.tl (List.rev ns)))
    else
      List.hd ns
  | UseGroup (ns, _) -> String.concat "." ns
  | UseWild  ns      -> String.concat "." ns
  | UseAlias (ns, _) -> String.concat "." ns

(* Names introduced into scope by a use_path, given the referenced module's exports.
   Returns (values, types) lists to add. *)
let imported_names (path : use_path) (exp : module_exports)
    (report : error -> unit) =
  let add_val   n = Hashtbl.mem exp.exp_values   n in
  let add_type  n = Hashtbl.mem exp.exp_types    n in
  let add_ctor  n = Hashtbl.mem exp.exp_constructors n in
  let is_pub    n = add_val n || add_type n || add_ctor n
                    || Hashtbl.mem exp.exp_interfaces n in
  let check_pub n =
    if not (is_pub n) then
      report (PrivateNameAccess (n, exp.exp_mod_id))
  in
  match path with
  | UseName ns ->
    (* use foo.bar: bring "bar" into scope if public *)
    if List.length ns > 1 then begin
      let name = List.hd (List.rev ns) in
      check_pub name;
      [name]
    end else
      (* use foo alone: just register alias, no individual names *)
      []
  | UseGroup (_, members) ->
    List.iter check_pub members;
    members
  | UseWild _ ->
    (* bring all public names *)
    let names = ref [] in
    Hashtbl.iter (fun n () -> names := n :: !names) exp.exp_values;
    Hashtbl.iter (fun n () -> names := n :: !names) exp.exp_types;
    Hashtbl.iter (fun n () -> names := n :: !names) exp.exp_constructors;
    !names
  | UseAlias (_, alias) ->
    (* alias only; the alias itself is in module_aliases, no individual names *)
    [alias]

let build_env ?(known_modules : module_exports list = [])
    (prog : program) : module_env * (error * Ast.loc option) list =
  let env = create_env ~with_prelude:(not (program_is_core prog)) () in
  let errors = ref [] in
  let report e = errors := (e, None) :: !errors in
  let add_unique tbl kind name =
    if Hashtbl.mem tbl name then
      report (DuplicateDefinition (kind, name))
    else
      Hashtbl.replace tbl name ()
  in
  let add_or_skip tbl name = Hashtbl.replace tbl name () in
  (* Pre-collect extern names so DFunDef can check for conflicts in any order *)
  let extern_names =
    List.filter_map (fun d -> match Ast.inner_decl d with
      | DExtern (_, n, _) -> Some n | _ -> None) prog
  in
  List.iter (fun d ->
    match Ast.inner_decl d with
    | DTypeSig (_, n, _) ->
      (* Type sig pairs with later fun_def; either order works *)
      add_or_skip env.values n
    | DExtern (_, n, _) ->
      add_or_skip env.values n
    | DFunDef (_, n, _, _) ->
      if List.mem n extern_names then report (ExternWithBody n);
      (* Multi-clause definitions add the same name repeatedly *)
      add_or_skip env.values n
    | DLetGroup (_, bs) ->
      List.iter (fun (n, _) ->
        if List.mem n extern_names then report (ExternWithBody n);
        add_or_skip env.values n
      ) bs
    | DTypeAlias (_, n, _, _) ->
      add_unique env.types "type" n
    | DNewtype (_, n, _, con, _, _) ->
      add_unique env.types "type" n;
      add_unique env.constructors "constructor" con
    | DData (_, n, _, vs, _) ->
      add_unique env.types "type" n;
      List.iter (fun v ->
        add_unique env.constructors "constructor" v.con_name;
        (match v.con_payload with
         | ConNamed fields ->
           List.iter (fun f ->
             add_or_skip env.fields f.field_name;
             add_field_owner env.field_owners f.field_name v.con_name
           ) fields
         | ConPos _ -> ())
      ) vs
    | DRecord (_, n, _, fs, _) ->
      add_unique env.types "type" n;
      List.iter (fun f ->
        add_or_skip env.fields f.field_name;
        add_field_owner env.field_owners f.field_name n
      ) fs
    | DInterface { iface_name; methods; _ } ->
      add_unique env.interfaces "interface" iface_name;
      List.iter (fun m -> add_or_skip env.values m.method_name) methods;
      Hashtbl.replace env.iface_methods iface_name
        (List.map (fun m -> m.method_name) methods)
    | DImpl _ -> ()
    | DProp _ -> ()
    | DBench _ -> ()
    | DUse (_, path) ->
      let mod_id = use_path_module_id path in
      (* "core" is the implicit prelude — `import core.{...}` is a no-op
         since the names are already in scope through the prelude. *)
      if mod_id = "core" then () else
      (match List.find_opt (fun e -> e.exp_mod_id = mod_id) known_modules with
       | None ->
         if known_modules <> [] then
           (* Only report if we're in multi-module mode *)
           report (UnknownModule mod_id)
         else begin
           (* Single-file mode: stub (legacy behaviour) *)
           let names = match path with
             | UseName ns       -> [List.hd (List.rev ns)]
             | UseGroup (_, ms) -> ms
             | UseWild _        -> []
             | UseAlias (_, a)  -> [a]
           in
           List.iter (fun n ->
             add_or_skip env.imported n;
             add_or_skip env.values n;
             add_or_skip env.types n
           ) names
         end
       | Some exp ->
         (* Import names from the module's public exports *)
         let names = imported_names path exp (fun e -> report e) in
         List.iter (fun n ->
           add_or_skip env.imported n;
           (* Add to values/types/constructors as appropriate *)
           if Hashtbl.mem exp.exp_values n then add_or_skip env.values n;
           if Hashtbl.mem exp.exp_types  n then add_or_skip env.types  n;
           if Hashtbl.mem exp.exp_constructors n then
             add_or_skip env.constructors n;
           if Hashtbl.mem exp.exp_interfaces n then
             add_or_skip env.interfaces n
         ) names;
         (* Copy field ownership for imported record types and named-field ctors *)
         Hashtbl.iter (fun field owner ->
           if Hashtbl.mem exp.exp_types owner
           || Hashtbl.mem exp.exp_constructors owner then begin
             add_or_skip env.fields field;
             add_field_owner env.field_owners field owner
           end
         ) exp.exp_field_owners;
         (* Register module alias / qualified-access name *)
         let alias = match path with
           | UseAlias (_, a)      -> Some a
           | UseName [single]     -> Some single  (* use foo → foo.x syntax *)
           | _                    -> None
         in
         (match alias with
          | Some a -> Hashtbl.replace env.module_aliases a exp
          | None   -> ()))
    | DAttrib _ -> ()
  ) prog;
  env, List.rev !errors

(* ── Phase 2: walk decls checking references ──── *)

let lookup_value env scope name =
  List.mem name scope
  || Hashtbl.mem env.values name
  || Hashtbl.mem env.constructors name
  || Hashtbl.mem env.imported name

let emit errors e = errors := (e, !current_loc) :: !errors

let rec check_pat env errors p =
  match p with
  | PVar _ | PWild | PLit _ -> ()
  | PCon (c, ps) ->
    if not (Hashtbl.mem env.constructors c || Hashtbl.mem env.imported c) then
      emit errors (UnknownConstructor c);
    List.iter (check_pat env errors) ps
  | PCons (a, b) ->
    check_pat env errors a;
    check_pat env errors b
  | PTuple ps | PList ps ->
    List.iter (check_pat env errors) ps
  | PAs (_, p) -> check_pat env errors p
  | PRng _ -> ()   (* literal bounds need no resolution *)
  | PRec (name, fields, _rest) ->
    (* name can be a record type (DRecord) or a named-field constructor (DData ConNamed) *)
    let is_record = Hashtbl.mem env.types name in
    let is_named_ctor = (not is_record) && Hashtbl.mem env.constructors name in
    if not is_record && not is_named_ctor then
      emit errors (UnknownType name);
    List.iter (fun (fname, pat_opt) ->
      (* Phase 72: a field name may be owned by several records; accept it iff
         the named record/ctor is among the owners. *)
      if not (field_known env.field_owners fname) then
        emit errors (UnknownField fname)
      else if not (field_belongs env.field_owners fname name) then
        emit errors (FieldNotInRecord (fname, name));
      match pat_opt with
      | None   -> ()
      | Some q -> check_pat env errors q
    ) fields

let rec check_type env errors t =
  match t with
  | TyCon n ->
    if not (Hashtbl.mem env.types n || Hashtbl.mem env.imported n) then
      emit errors (UnknownType n)
  | TyVar _ -> ()
  | TyApp (a, b) | TyFun (a, b) ->
    check_type env errors a; check_type env errors b
  | TyTuple ts ->
    List.iter (check_type env errors) ts
  | TyEffect (es, _tail, t) ->
    (* labels are validated against the known effects; the optional tail is a
       lowercase effect *variable* (Phase 79) and needs no such check. *)
    List.iter (fun e ->
      if not (List.mem e built_in_effects) then
        emit errors (UnknownEffect e)
    ) es;
    check_type env errors t
  | TyConstrained (cs, t) ->
    List.iter (fun (iface, args) ->
      if not (Hashtbl.mem env.interfaces iface) then
        emit errors (UnknownInterface iface);
      List.iter (check_type env errors) args
    ) cs;
    check_type env errors t

let rec check_expr env scope errors e =
  match e with
  | ELoc (l, e') ->
    current_loc := Some l;
    check_expr env scope errors e'
  | ELit _ -> ()
  | EMethodRef _ -> ()  (* marker pass runs after resolve; method already bound *)
  | EDictApp _ -> ()    (* marker pass runs after resolve; name already bound *)
  | EVar n ->
    if not (lookup_value env scope n) then
      emit errors (UnboundVariable n)
  | EApp (f, x) ->
    check_expr env scope errors f;
    check_expr env scope errors x
  | ELam (pats, body) ->
    List.iter (check_pat env errors) pats;
    let scope' = List.concat_map pat_bindings pats @ scope in
    check_expr env scope' errors body
  | ELet (_, true, PVar f, e1, e2) ->
    (* Self-recursive: f is in scope in its own RHS *)
    let scope_rec = f :: scope in
    check_expr env scope_rec errors e1;
    check_expr env scope_rec errors e2
  | ELet (_, _, pat, e1, e2) ->
    check_pat env errors pat;
    let bound = pat_bindings pat in
    let pre_count = List.length !errors in
    check_expr env scope errors e1;
    (* Rewrite any UnboundVariable error that hit one of this let's pattern
       bindings into a targeted NonRecursiveValueLet diagnostic — the user
       likely forgot `rec`. *)
    let new_count = List.length !errors - pre_count in
    errors := List.mapi (fun i (e, l) ->
      if i < new_count then
        match e with
        | UnboundVariable n when List.mem n bound -> (NonRecursiveValueLet n, l)
        | _ -> (e, l)
      else (e, l)
    ) !errors;
    let scope' = bound @ scope in
    check_expr env scope' errors e2
  | ELetGroup (bindings, body) ->
    let scope' = List.map fst bindings @ scope in
    List.iter (fun (_, clauses) ->
      List.iter (fun (pats, rhs) ->
        List.iter (check_pat env errors) pats;
        let clause_scope = List.concat_map pat_bindings pats @ scope' in
        check_expr env clause_scope errors rhs
      ) clauses
    ) bindings;
    check_expr env scope' errors body
  | EMatch (sc, arms) ->
    check_expr env scope errors sc;
    List.iter (fun (pat, guards, body) ->
      check_pat env errors pat;
      let scope0 = pat_bindings pat @ scope in
      (* Resolve qualifiers in order; pattern binds bring their vars into
         scope for later qualifiers and the body. *)
      let scope' = List.fold_left (fun sc_cur q ->
        match q with
        | GBool g -> check_expr env sc_cur errors g; sc_cur
        | GBind (p, e) ->
          check_expr env sc_cur errors e;
          check_pat env errors p;
          pat_bindings p @ sc_cur
      ) scope0 guards in
      check_expr env scope' errors body
    ) arms
  | EIf (c, t, e) ->
    check_expr env scope errors c;
    check_expr env scope errors t;
    check_expr env scope errors e
  | EBinOp (_, l, r) ->
    check_expr env scope errors l;
    check_expr env scope errors r
  | EUnOp (_, e) ->
    check_expr env scope errors e
  | EFieldAccess (e, _) ->
    (* Field name validation deferred to the type checker *)
    check_expr env scope errors e
  | ERecordCreate (name, fs) ->
    let is_record = Hashtbl.mem env.types name || Hashtbl.mem env.imported name in
    let is_ctor   = Hashtbl.mem env.constructors name in
    if not is_record && not is_ctor then
      emit errors (UnknownType name)
    else begin
      (* Each field must belong to the named record or named-field constructor.
         Phase 72: a field name may have several owners; accept iff [name] is one. *)
      List.iter (fun (fname, _) ->
        if not (field_known env.field_owners fname) then
          emit errors (UnknownField fname)
        else if not (field_belongs env.field_owners fname name) then
          emit errors (FieldNotInRecord (fname, name))
      ) fs
    end;
    List.iter (fun (_, v) -> check_expr env scope errors v) fs
  | ERecordUpdate (e, fs) ->
    check_expr env scope errors e;
    (* Phase 72: with shared field names the receiver's record type can no longer
       be pinned from a field name alone, so the "all fields belong to the same
       record" consistency check moves to the type checker (which resolves by the
       receiver's inferred type).  Here we only flag a field unknown to every
       record. *)
    List.iter (fun (fname, v) ->
      check_expr env scope errors v;
      if not (field_known env.field_owners fname) then
        emit errors (UnknownField fname)
    ) fs
  | EArrayLit es | EListLit es | ETuple es ->
    List.iter (check_expr env scope errors) es
  | EMapLit (_, kvs) ->
    List.iter (fun (k, v) -> check_expr env scope errors k; check_expr env scope errors v) kvs
  | ESetLit (_, es) ->
    List.iter (check_expr env scope errors) es
  | EStringInterp parts ->
    List.iter (function
      | InterpStr _  -> ()
      | InterpExpr e -> check_expr env scope errors e
    ) parts
  | EIndex (e, i) ->
    check_expr env scope errors e;
    check_expr env scope errors i
  | ERangeList (lo, hi, _) | ERangeArray (lo, hi, _) ->
    check_expr env scope errors lo;
    check_expr env scope errors hi
  | ESlice (e, lo, hi, _) ->
    check_expr env scope errors e;
    check_expr env scope errors lo;
    check_expr env scope errors hi
  | EBlock stmts | EDo (_, stmts) ->
    let _final_scope =
      List.fold_left (fun scope stmt ->
        match stmt with
        | DoBind (pat, e) ->
          check_pat env errors pat;
          check_expr env scope errors e;
          pat_bindings pat @ scope
        | DoExpr e ->
          check_expr env scope errors e;
          scope
        | DoLet (_, pat, e) ->
          check_pat env errors pat;
          check_expr env scope errors e;
          pat_bindings pat @ scope
        | DoAssign (x, e) ->
          if not (lookup_value env scope x) then
            emit errors (UnboundVariable x);
          check_expr env scope errors e;
          scope
        | DoFieldAssign (x, _fields, e) ->
          if not (lookup_value env scope x) then
            emit errors (UnboundVariable x);
          check_expr env scope errors e;
          scope
        | DoLetElse (pat, e, alt) ->
          check_pat env errors pat;
          check_expr env scope errors e;
          check_expr env scope errors alt;
          pat_bindings pat @ scope
      ) scope stmts
    in ()
  | EAnnot (e, t) ->
    check_expr env scope errors e;
    check_type env errors t
  | EInfix (op, l, r) ->
    if not (lookup_value env scope op) then
      emit errors (UnboundVariable op);
    check_expr env scope errors l;
    check_expr env scope errors r
  | EListComp _ -> assert false (* eliminated by desugar_list_comps *)
  | EGuards _ | EFunction _ | ESection _ ->
    assert false (* eliminated by desugar_sugar *)
  | EQuestion e ->
    emit errors QuestionMisplaced;
    check_expr env scope errors e

let rec check_decl env errors = function
  | DFunDef (_, _, pats, body) ->
    List.iter (check_pat env errors) pats;
    let scope = List.concat_map pat_bindings pats in
    check_expr env scope errors body
  | DLetGroup (_, bindings) ->
    (* All group names are pre-bound; each clause's RHS can see all of them. *)
    let group_names = List.map fst bindings in
    List.iter (fun (_, clauses) ->
      List.iter (fun (pats, rhs) ->
        List.iter (check_pat env errors) pats;
        let scope = List.concat_map pat_bindings pats @ group_names in
        check_expr env scope errors rhs
      ) clauses
    ) bindings
  | DTypeSig (_, _, t) ->
    check_type env errors t
  | DExtern (_, _, t) ->
    check_type env errors t
  | DTypeAlias (_, _, _, rhs) ->
    check_type env errors rhs
  | DNewtype (_, _, _, _, fty, _) ->
    check_type env errors fty
  | DData (_, _, _, vs, _) ->
    List.iter (fun v ->
      match v.con_payload with
      | ConPos tys   -> List.iter (check_type env errors) tys
      | ConNamed flds -> List.iter (fun f -> check_type env errors f.field_type) flds
    ) vs
  | DRecord (_, _, _, fs, _) ->
    List.iter (fun f -> check_type env errors f.field_type) fs
  | DUse _ -> ()
  | DProp { prop_params; prop_body; _ } ->
    let scope = List.map (fun (x, ty) ->
      check_type env errors ty;
      x
    ) prop_params in
    check_expr env scope errors prop_body
  | DBench { bench_body; _ } ->
    check_expr env [] errors bench_body
  | DInterface { super; methods; _ } ->
    List.iter (fun (super_iface, _params) ->
      if not (Hashtbl.mem env.interfaces super_iface) then
        emit errors (UnknownInterface super_iface)
    ) super;
    List.iter (fun m ->
      check_type env errors m.method_type;
      match m.method_default with
      | None -> ()
      | Some (pats, body) ->
        List.iter (check_pat env errors) pats;
        let scope = List.concat_map pat_bindings pats in
        check_expr env scope errors body
    ) methods
  | DImpl { iface_name; type_args; requires; methods; _ } ->
    List.iter (check_type env errors) type_args;
    List.iter (fun (req_iface, req_tys) ->
      if not (Hashtbl.mem env.interfaces req_iface) then
        emit errors (UnknownInterface req_iface);
      List.iter (check_type env errors) req_tys
    ) requires;
    List.iter (fun (_, pats, body) ->
      List.iter (check_pat env errors) pats;
      let scope = List.concat_map pat_bindings pats in
      check_expr env scope errors body
    ) methods;
    if not (Hashtbl.mem env.interfaces iface_name) then
      emit errors (UnknownInterface iface_name)
    else begin
      let known_methods =
        try Hashtbl.find env.iface_methods iface_name with Not_found -> []
      in
      List.iter (fun (mname, _, _) ->
        if not (List.mem mname known_methods) then
          emit errors (MethodNotInInterface (mname, iface_name))
      ) methods
    end

  | DAttrib (_, inner) -> check_decl env errors inner

(* ── Build module exports from a resolved env ─── *)

(* Collect all public names from a program into module_exports *)
let build_exports ?(known_modules : module_exports list = [])
    (mod_id : string) (prog : program) (env : module_env)
    : module_exports =
  let exp = {
    exp_mod_id        = mod_id;
    exp_values        = Hashtbl.create 16;
    exp_types         = Hashtbl.create 8;
    exp_constructors  = Hashtbl.create 8;
    exp_fields        = Hashtbl.create 8;
    exp_field_owners  = Hashtbl.create 8;
    exp_interfaces    = Hashtbl.create 4;
    exp_iface_methods = Hashtbl.create 4;
  } in
  (* Re-export one name from a source module's exports *)
  let reexport_name src_exp name =
    if Hashtbl.mem src_exp.exp_values name then
      Hashtbl.replace exp.exp_values name ();
    if Hashtbl.mem src_exp.exp_types name then
      Hashtbl.replace exp.exp_types name ();
    if Hashtbl.mem src_exp.exp_constructors name then
      Hashtbl.replace exp.exp_constructors name ();
    if Hashtbl.mem src_exp.exp_interfaces name then begin
      Hashtbl.replace exp.exp_interfaces name ();
      (* Also re-export the interface's methods *)
      (match Hashtbl.find_opt src_exp.exp_iface_methods name with
       | Some methods ->
         Hashtbl.replace exp.exp_iface_methods name methods;
         List.iter (fun mn ->
           if Hashtbl.mem src_exp.exp_values mn then
             Hashtbl.replace exp.exp_values mn ()
         ) methods
       | None -> ())
    end
  in
  (* Re-export all fields for any re-exported record type *)
  let reexport_fields src_exp =
    Hashtbl.iter (fun field owner ->
      if Hashtbl.mem exp.exp_types owner then begin
        Hashtbl.replace exp.exp_fields field ();
        add_field_owner exp.exp_field_owners field owner
      end
    ) src_exp.exp_field_owners
  in
  List.iter (fun d ->
    match Ast.inner_decl d with
    | DTypeSig (true, n, _) ->
      Hashtbl.replace exp.exp_values n ()
    | DExtern (true, n, _) ->
      Hashtbl.replace exp.exp_values n ()
    | DFunDef (true, n, _, _) ->
      Hashtbl.replace exp.exp_values n ()
    | DNewtype (true, n, _, con, _, _) ->
      Hashtbl.replace exp.exp_types n ();
      Hashtbl.replace exp.exp_constructors con ()
    | DData (DataPublic, n, _, vs, _) ->
      Hashtbl.replace exp.exp_types n ();
      List.iter (fun v ->
        Hashtbl.replace exp.exp_constructors v.con_name ();
        (match v.con_payload with
         | ConNamed fields ->
           List.iter (fun f ->
             Hashtbl.replace exp.exp_fields f.field_name ();
             add_field_owner exp.exp_field_owners f.field_name v.con_name
           ) fields
         | ConPos _ -> ())
      ) vs
    | DData (DataAbstract, n, _, _, _) ->
      Hashtbl.replace exp.exp_types n ()
    | DRecord (DataPublic, n, _, fs, _) ->
      Hashtbl.replace exp.exp_types n ();
      List.iter (fun f ->
        Hashtbl.replace exp.exp_fields f.field_name ();
        add_field_owner exp.exp_field_owners f.field_name n
      ) fs
    | DRecord (DataAbstract, n, _, _, _) ->
      Hashtbl.replace exp.exp_types n ()
    | DInterface { is_pub = true; iface_name; methods; _ } ->
      Hashtbl.replace exp.exp_interfaces iface_name ();
      Hashtbl.replace exp.exp_iface_methods iface_name
        (List.map (fun m -> m.method_name) methods)
    | DImpl { is_pub = true; _ } ->
      (* Impl declarations export their methods via the interface's methods;
         we don't need to separately export the impl itself. *)
      ()
    | DUse (true, path) ->
      let src_mod_id = use_path_module_id path in
      (match List.find_opt (fun e -> e.exp_mod_id = src_mod_id) known_modules with
       | None -> ()
       | Some src_exp ->
         (match path with
          | UseName ns when List.length ns > 1 ->
            let name = List.hd (List.rev ns) in
            reexport_name src_exp name;
            reexport_fields src_exp
          | UseName _ ->
            (* use foo alone as re-export: no individual names, alias only — skip *)
            ()
          | UseGroup (_, members) ->
            List.iter (reexport_name src_exp) members;
            reexport_fields src_exp
          | UseWild _ ->
            (* Re-export everything from the source module *)
            Hashtbl.iter (fun n () -> Hashtbl.replace exp.exp_values n ()) src_exp.exp_values;
            Hashtbl.iter (fun n () -> Hashtbl.replace exp.exp_types n ()) src_exp.exp_types;
            Hashtbl.iter (fun n () -> Hashtbl.replace exp.exp_constructors n ()) src_exp.exp_constructors;
            Hashtbl.iter (fun n () -> Hashtbl.replace exp.exp_interfaces n ()) src_exp.exp_interfaces;
            Hashtbl.iter (fun n ms -> Hashtbl.replace exp.exp_iface_methods n ms) src_exp.exp_iface_methods;
            Hashtbl.iter (fun f () -> Hashtbl.replace exp.exp_fields f ()) src_exp.exp_fields;
            Hashtbl.iter (fun f owner -> add_field_owner exp.exp_field_owners f owner) src_exp.exp_field_owners
          | UseAlias _ ->
            (* export import foo as F: module-alias re-export not yet supported *)
            ()))
    | _ -> ()
  ) prog;
  (* Also export interface method names whose interface is public *)
  Hashtbl.iter (fun iface_name methods ->
    if Hashtbl.mem exp.exp_interfaces iface_name then
      List.iter (fun mn ->
        if Hashtbl.mem env.values mn then
          Hashtbl.replace exp.exp_values mn ()
      ) methods
  ) exp.exp_iface_methods;
  exp

(* ── Public entry points ──────────────────────── *)

let resolve_program (prog : program) : (error * Ast.loc option) list =
  current_loc := None;
  let env, build_errors = build_env prog in
  let errors = ref build_errors in
  List.iter (check_decl env errors) prog;
  List.rev !errors

(* Multi-module entry point: resolve one module given previously-resolved exports.
   Returns (module_exports, errors). *)
let resolve_module
    (known_modules : module_exports list)
    (mod_id        : string)
    (prog          : program)
    : module_exports * (error * Ast.loc option) list =
  current_loc := None;
  let env, build_errors = build_env ~known_modules prog in
  let errors = ref build_errors in
  List.iter (check_decl env errors) prog;
  let exports = build_exports ~known_modules mod_id prog env in
  (exports, List.rev !errors)

(* ── REPL incremental interface ──────────────── *)

let make_repl_resolve_env () : module_env = create_env ()

(* Add declarations from `decls` into an existing `env` in place, then check
   references.  Returns any errors found. *)
let resolve_repl_item (env : module_env) (item : Ast.repl_item)
    : (error * Ast.loc option) list =
  current_loc := None;
  let errors = ref [] in
  let report e = errors := (e, None) :: !errors in
  let add_unique tbl kind name =
    if Hashtbl.mem tbl name then report (DuplicateDefinition (kind, name))
    else Hashtbl.replace tbl name ()
  in
  let add_or_skip tbl name = Hashtbl.replace tbl name () in
  let decls = match item with
    | Ast.ReplDecl ds -> ds
    | Ast.ReplExpr _ -> []
  in
  let extern_names =
    List.filter_map (fun d -> match Ast.inner_decl d with
      | Ast.DExtern (_, n, _) -> Some n | _ -> None) decls
  in
  List.iter (fun d ->
    match Ast.inner_decl d with
    | Ast.DTypeSig (_, n, _) -> add_or_skip env.values n
    | Ast.DExtern (_, n, _)  -> add_or_skip env.values n
    | Ast.DFunDef (_, n, _, _) ->
      if List.mem n extern_names then report (ExternWithBody n);
      add_or_skip env.values n
    | Ast.DLetGroup (_, bs) ->
      List.iter (fun (n, _) ->
        if List.mem n extern_names then report (ExternWithBody n);
        add_or_skip env.values n
      ) bs
    | Ast.DData (_, n, _, vs, _) ->
      add_unique env.types "type" n;
      List.iter (fun v -> add_unique env.constructors "constructor" v.Ast.con_name) vs
    | Ast.DRecord (_, n, _, fs, _) ->
      add_unique env.types "type" n;
      List.iter (fun f ->
        add_or_skip env.fields f.Ast.field_name;
        add_field_owner env.field_owners f.Ast.field_name n
      ) fs
    | Ast.DInterface { iface_name; methods; _ } ->
      add_unique env.interfaces "interface" iface_name;
      List.iter (fun m -> add_or_skip env.values m.Ast.method_name) methods;
      Hashtbl.replace env.iface_methods iface_name
        (List.map (fun m -> m.Ast.method_name) methods)
    | Ast.DImpl _ | Ast.DUse _ | Ast.DTypeAlias _ | Ast.DNewtype _ | Ast.DProp _ | Ast.DBench _
    | Ast.DAttrib _ -> ()
  ) decls;
  (match item with
   | Ast.ReplDecl ds -> List.iter (check_decl env errors) ds
   | Ast.ReplExpr e  -> check_expr env [] errors e);
  List.rev !errors
