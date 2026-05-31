let enabled : bool ref = ref false
let hit : (string * int, unit) Hashtbl.t = Hashtbl.create 64

let reset () =
  enabled := false;
  Hashtbl.clear hit

let enable () =
  enabled := true

let record_hit file line =
  if !enabled then
    Hashtbl.replace hit (file, line) ()

(* ── AST walker ─────────────────────────────────────────────────────────── *)

let rec collect_expr acc = function
  | Ast.ELoc (loc, e) ->
    let key = (loc.Ast.file, loc.Ast.line) in
    let acc' = if List.mem key acc then acc else key :: acc in
    collect_expr acc' e
  | Ast.ELit _ | Ast.EVar _ | Ast.EMethodRef _ | Ast.EDictApp _ -> acc
  | Ast.EApp (f, x) -> collect_expr (collect_expr acc f) x
  | Ast.ELam (_, e) -> collect_expr acc e
  | Ast.ELet (_, _, _, e1, e2) -> collect_expr (collect_expr acc e1) e2
  | Ast.ELetGroup (bs, e) ->
    let acc' = List.fold_left (fun a (_, clauses) ->
      List.fold_left (fun a' (_, body) -> collect_expr a' body) a clauses
    ) acc bs in
    collect_expr acc' e
  | Ast.EMatch (e, arms) ->
    let acc' = collect_expr acc e in
    List.fold_left (fun a (_, guards, body) ->
      let a' = List.fold_left (fun a q ->
        match q with
        | Ast.GBool g      -> collect_expr a g
        | Ast.GBind (_, g) -> collect_expr a g) a guards in
      collect_expr a' body
    ) acc' arms
  | Ast.EIf (c, t, e) -> collect_expr (collect_expr (collect_expr acc c) t) e
  | Ast.EBinOp (_, l, r) | Ast.EInfix (_, l, r) ->
    collect_expr (collect_expr acc l) r
  | Ast.EUnOp (_, e) | Ast.EFieldAccess (e, _) | Ast.EAnnot (e, _)
  | Ast.EQuestion e -> collect_expr acc e
  | Ast.ERecordCreate (_, fs) ->
    List.fold_left (fun a (_, e) -> collect_expr a e) acc fs
  | Ast.ERecordUpdate (e, fs) ->
    List.fold_left (fun a (_, e') -> collect_expr a e') (collect_expr acc e) fs
  | Ast.EArrayLit es | Ast.EListLit es | Ast.ETuple es | Ast.ESetLit (_, es) ->
    List.fold_left collect_expr acc es
  | Ast.EMapLit (_, kvs) ->
    List.fold_left (fun a (k, v) -> collect_expr (collect_expr a k) v) acc kvs
  | Ast.EIndex (e, i) -> collect_expr (collect_expr acc e) i
  | Ast.EBlock stmts | Ast.EDo (_, stmts) ->
    List.fold_left (fun a stmt -> collect_do_stmt a stmt) acc stmts
  | Ast.EStringInterp parts ->
    List.fold_left (fun a p -> match p with
      | Ast.InterpExpr e -> collect_expr a e
      | Ast.InterpStr _ -> a
    ) acc parts
  | Ast.EListComp (e, quals) ->
    let acc' = collect_expr acc e in
    List.fold_left (fun a q -> match q with
      | Ast.LCGen (_, e') | Ast.LCGuard e' -> collect_expr a e'
      | Ast.LCLet (_, _, e') -> collect_expr a e'
    ) acc' quals
  | Ast.ERangeList (lo, hi, _) | Ast.ERangeArray (lo, hi, _) ->
    collect_expr (collect_expr acc lo) hi
  | Ast.ESlice (e, lo, hi, _) ->
    collect_expr (collect_expr (collect_expr acc e) lo) hi
  | Ast.EGuards arms ->
    List.fold_left (fun a (guards, body) ->
      let a' = List.fold_left (fun a q -> match q with
        | Ast.GBool g | Ast.GBind (_, g) -> collect_expr a g) a guards in
      collect_expr a' body
    ) acc arms
  | Ast.EFunction arms ->
    List.fold_left (fun a (_, guards, body) ->
      let a' = List.fold_left (fun a q -> match q with
        | Ast.GBool g | Ast.GBind (_, g) -> collect_expr a g) a guards in
      collect_expr a' body
    ) acc arms
  | Ast.ESection (Ast.SecRight (_, e)) | Ast.ESection (Ast.SecLeft (e, _)) ->
    collect_expr acc e
  | Ast.ESection (Ast.SecBare _) -> acc

and collect_do_stmt acc = function
  | Ast.DoBind (_, e) | Ast.DoExpr e | Ast.DoLet (_, _, e)
  | Ast.DoAssign (_, e) | Ast.DoFieldAssign (_, _, e) -> collect_expr acc e
  | Ast.DoLetElse (_, e, alt) -> collect_expr (collect_expr acc e) alt

let rec collect_decl acc = function
  | Ast.DFunDef (_, _, _, body) -> collect_expr acc body
  | Ast.DImpl { methods; _ } ->
    List.fold_left (fun a (_, _, body) -> collect_expr a body) acc methods
  | Ast.DInterface { methods; _ } ->
    List.fold_left (fun a m ->
      match m.Ast.method_default with
      | None -> a
      | Some (_, body) -> collect_expr a body
    ) acc methods
  | Ast.DProp { prop_body; _ } -> collect_expr acc prop_body
  | Ast.DBench { bench_body; _ } -> collect_expr acc bench_body
  | Ast.DAttrib (_, d) -> collect_decl acc d
  | _ -> acc

let collect_executable (program : Ast.decl list) : (string * int) list =
  List.fold_left collect_decl [] program

(* ── Report ─────────────────────────────────────────────────────────────── *)

let group_by_file lines =
  let tbl : (string, int list) Hashtbl.t = Hashtbl.create 4 in
  List.iter (fun (file, line) ->
    let existing = Option.value ~default:[] (Hashtbl.find_opt tbl file) in
    Hashtbl.replace tbl file (line :: existing)
  ) lines;
  Hashtbl.fold (fun file lns acc ->
    (file, List.sort_uniq compare lns) :: acc
  ) tbl []

let pp_report (executable : (string * int) list) =
  if executable = [] then ()
  else begin
    let by_file = List.sort (fun (a, _) (b, _) -> String.compare a b)
                    (group_by_file executable) in
    List.iter (fun (file, lines) ->
      let total = List.length lines in
      let covered = List.length (List.filter (fun line ->
        Hashtbl.mem hit (file, line)) lines) in
      let pct = if total = 0 then 100.0
                else 100.0 *. float_of_int covered /. float_of_int total in
      Printf.printf "coverage: %s \xe2\x80\x94 %d/%d lines (%.1f%%)\n"
        file covered total pct;
      let uncovered = List.filter (fun line ->
        not (Hashtbl.mem hit (file, line))) lines in
      if uncovered <> [] then
        Printf.printf "  uncovered lines: %s\n"
          (String.concat ", " (List.map string_of_int uncovered))
    ) by_file
  end
