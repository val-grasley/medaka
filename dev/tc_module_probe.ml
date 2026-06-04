(* Multi-module typecheck oracle for the self-hosted bootstrap front-end.
 *
 *   dev/tc_module_probe.exe <entry.mdk> [root ...]
 *
 * Loads <entry.mdk> and its transitive imports via the real Loader, desugars +
 * method-marks each module, then threads Typecheck.typecheck_module over them in
 * dependency-first order (each module sees the prior modules' exports).  Prints
 * the ENTRY module's own user bindings as `name : <pp_scheme>`, sorted by name —
 * the same per-binding format dev/tc_probe.exe uses for the single-file path, so
 * the self-hosted multi-module front-end can be validated against it.
 *
 * This is the multi-module analog of tc_probe: it isolates cross-module name
 * resolution + per-module env scoping (imported ctors / schemes / interfaces /
 * impls seeded from known_modules) the way tc_probe isolates the HM engine.
 *
 * Internal bindings ($-prefixed, __dt doctest synth) are filtered out. *)

open Medaka_lib

let is_internal n =
  String.length n = 0
  || n.[0] = '$'
  || (String.length n >= 4 && String.sub n 0 4 = "__dt")

(* The names a program binds at top level — used to keep only the entry module's
   OWN bindings in the output (typecheck_module returns the prepended prelude's
   schemes too, since they share one letrec-group pass). *)
let module_binding_names (prog : Ast.program) : string list =
  List.concat_map (fun d -> match Ast.inner_decl d with
    | Ast.DFunDef (_, n, _, _) -> [n]
    | Ast.DLetGroup (_, bs)    -> List.map fst bs
    | Ast.DTypeSig (_, n, _)   -> [n]
    | Ast.DExtern (_, n, _)    -> [n]
    | Ast.DInterface { methods; _ } ->
      List.map (fun m -> m.Ast.method_name) methods
    | _ -> []
  ) prog

let () =
  let (entry, roots) =
    match Array.to_list Sys.argv with
    | _ :: e :: rest -> (e, (match rest with [] -> [Filename.dirname e] | r -> r))
    | _ -> prerr_endline "usage: tc_module_probe <entry.mdk> [root ...]"; exit 2
  in
  let entry_id = Loader.module_id_of_path roots entry in
  match
    let modules = Loader.load_program entry roots in
    let modules =
      List.map (fun (mid, fp, p) -> (mid, fp, Desugar.desugar_program p)) modules in
    let progs = Prelude.program :: List.map (fun (_, _, p) -> p) modules in
    let method_names = Method_marker.interface_method_names progs in
    let constrained  = Method_marker.constrained_fn_names progs in
    let modules =
      List.map (fun (mid, fp, p) ->
        (mid, fp, Method_marker.mark_program method_names constrained p)) modules in
    let te_acc = ref [] in
    let entry_schemes = ref [] in
    List.iter (fun (mid, _, p) ->
      let (te, schemes, _warnings) = Typecheck.typecheck_module !te_acc mid p in
      if mid = entry_id then begin
        let own = module_binding_names p in
        entry_schemes := List.filter (fun (n, _) -> List.mem n own) schemes
      end;
      te_acc := te :: !te_acc) modules;
    !entry_schemes
  with
  | schemes ->
    schemes
    |> List.filter (fun (n, _) -> not (is_internal n))
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
    |> List.iter (fun (n, s) -> Printf.printf "%s : %s\n" n (Typecheck.pp_scheme s))
  | exception Typecheck.Type_error (e, _) ->
    Printf.printf "TYPE ERROR: %s\n" (Typecheck.pp_error e)
  | exception Loader.LoadError err ->
    Printf.printf "LOAD ERROR: %s\n"
      (match err with
       | Loader.FileNotFound f -> "file not found: " ^ f
       | Loader.CyclicDependency ms -> "cyclic dependency: " ^ String.concat " -> " ms
       | Loader.UnknownModule { mod_id; _ } -> "unknown module: " ^ mod_id
       | Loader.AmbiguousModule { mod_id; _ } -> "ambiguous module: " ^ mod_id
       | Loader.ParseError { file; line; col; message } ->
         Printf.sprintf "%s:%d:%d: %s" file line col message)
