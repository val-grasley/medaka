(* Multi-module / dict-pass probe — not part of the test suite.

   Runs a program through the *whole* multi-module pipeline in-process
   (loader → desugar → method-marker → typecheck_module → eval_modules), the way
   `medaka run` does, and additionally:
     - dumps the dict-passed user decls (so you can read what Dict_pass produced
       and diff it against the single-file path), and
     - evaluates the same dict-passed program through BOTH the per-module driver
       (`Eval.eval_modules`, the real loader path) and the flat driver
       (`Eval.eval_program`, the single-file path), printing each output or panic.

   This is the tool that localized Phase 125: an identical typechecked+dict-passed
   tree printed `6` through `eval_program` but panicked through `eval_modules`,
   pinning the bug to the evaluator's module driver rather than typecheck/dict_pass.

   Usage:
     dune build --root . && ./_build/default/dev/module_debug.exe [entry.mdk [root ...]]
   With no argument it writes the Phase-125 repro to a temp dir and runs that. *)

open Medaka_lib

(* Build the marked, typechecked module list exactly like bin/main.ml's Run path
   (single typecheck pass — enough for arg-tag-dispatched relaxed wrappers; the
   promotion second pass is the do-block case and is omitted here for clarity). *)
let pipeline entry roots : (string * string * Ast.program) list =
  let modules = Loader.load_program entry roots in
  let modules =
    List.map (fun (mid, fp, p) -> (mid, fp, Desugar.desugar_program p)) modules in
  let method_names =
    Method_marker.interface_method_names
      (Prelude.program :: List.map (fun (_, _, p) -> p) modules) in
  let constrained =
    Method_marker.constrained_fn_names
      (Prelude.program :: List.map (fun (_, _, p) -> p) modules) in
  let modules =
    List.map (fun (mid, fp, p) ->
      (mid, fp, Method_marker.mark_program method_names constrained p)) modules in
  let te_acc = ref [] in
  List.iter (fun (mid, _, p) ->
    let (te, _, _) = Typecheck.typecheck_module !te_acc mid p in
    te_acc := te :: !te_acc) modules;
  modules

let capture f =
  let buf = Buffer.create 64 in
  let saved_out = !Eval.output_hook and saved_err = !Eval.error_hook in
  Eval.output_hook := Buffer.add_string buf;
  Eval.error_hook := Buffer.add_string buf;
  let restore () = Eval.output_hook := saved_out; Eval.error_hook := saved_err in
  (match Fun.protect ~finally:restore f with
   | () -> ()
   | exception Eval.Eval_error (msg, loc) ->
     let l = match loc with
       | Some { Ast.line; col; _ } -> Printf.sprintf " @ %d:%d" line col
       | None -> "" in
     Buffer.add_string buf (Printf.sprintf "<PANIC%s: %s>\n" l msg));
  Buffer.contents buf

let () =
  let (entry, roots) =
    match Array.to_list Sys.argv with
    | _ :: e :: rest -> (e, (match rest with [] -> [Filename.dirname e] | r -> r))
    | _ ->
      (* default: write the Phase-125 repro to a temp dir *)
      let dir = Filename.temp_file "medaka_dbg" "" in
      Sys.remove dir; Unix.mkdir dir 0o755;
      let w name s =
        let oc = open_out (Filename.concat dir name) in
        output_string oc s; close_out oc in
      w "cont.mdk"
        "public export data Bag a = Bag (List a)\n\n\
         export impl Foldable Bag where\n\
        \  fold f z (Bag xs) = fold f z xs\n\
        \  foldRight f z (Bag xs) = foldRight f z xs\n\
        \  toList (Bag xs) = xs\n\n\
         export fromL : List a -> Bag a\n\
         fromL xs = Bag xs\n";
      w "main.mdk"
        "import cont.{Bag, fromL}\n\n\
         main : <IO> Unit\n\
         main =\n\
        \  println (show (sum (fromL [1, 2, 3])))\n\
        \  println (show (maximum (fromL [3, 1, 2])))\n";
      (Filename.concat dir "main.mdk", [dir])
  in
  let modules = pipeline entry roots in

  Printf.printf "=== dict-passed user decls ===\n";
  List.iter (fun (mid, _, p) ->
    Printf.printf "-- module %s --\n%s\n" mid (Printer.program_to_string p)) modules;

  (* The flat path needs the prelude + every module's decls dict-passed jointly,
     then evaluated as one program — mirroring eval_modules' internal Dict_pass.run
     but flattened into a single frame. *)
  let joint =
    Method_marker.marked_prelude @ List.concat_map (fun (_, _, p) -> p) modules in
  let flat = Dict_pass.run joint in

  Printf.printf "\n=== eval_modules (per-module driver, the loader path) ===\n%s"
    (capture (fun () -> ignore (Eval.eval_modules modules)));
  Printf.printf "\n=== eval_program (flat driver, the single-file path) ===\n%s"
    (capture (fun () -> ignore (Eval.eval_program ~prelude:false flat)))
