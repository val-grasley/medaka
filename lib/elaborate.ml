(* Phase 84: two-pass elaboration shared by the typed eval drivers.

   The method marker runs *before* typecheck and only wraps statically
   `=>`-signatured functions in EDictApp; a method occurrence's dict route is
   filled *during* typecheck.  So making an *inferred* constraint dict-routable
   (e.g. the `Applicative m` a polymorphic-monad do-block infers for its enclosing
   function, whose return-position `pure` otherwise arg-tag-dispatches to the
   wrong monad) needs a second elaboration once the first pass has discovered
   which functions carry such constraints:

     pass 1: mark → typecheck  → discover the promotable names (inferred_constraints)
     pass 2: re-mark(original, ~promoted) → typecheck(~promoted)
             → those names' inferred constraints land in fun_constraints,
               find_enclosing_dict / dict_pass thread a dictionary into the body,
               and calls to them become EDictApp supplying the dictionary.

   When pass 1 finds nothing to promote (the common case) pass 2 is skipped, so
   well-typed programs without polymorphic-monad wrappers pay a single pass.

   Returns the marked tree pass 2 typechecked (its EMethodRef/EDictApp refs filled
   in place — use for prop/coverage that run on the pre-dict-pass tree), the
   dict-passed [combined] tree ready for `Eval.eval_program ~prelude:false`, the
   top-level schemes, and the warnings.  Raises Typecheck.Type_error like
   check_program — the driver's existing handler catches it. *)

open Ast

let elaborate (prog : program)
    : program * program * (ident * Typecheck.scheme) list * string list =
  let m1 = Method_marker.mark_with_prelude prog in
  let (schemes1, warnings1, promoted) = Typecheck.check_program_promoting m1 in
  let (marked, schemes, warnings) =
    if Hashtbl.length promoted = 0 then (m1, schemes1, warnings1)
    else begin
      let m2 = Method_marker.mark_with_prelude ~promoted prog in
      let (schemes2, warnings2, _) = Typecheck.check_program_promoting ~promoted m2 in
      (m2, schemes2, warnings2)
    end
  in
  let combined = Dict_pass.run (Method_marker.prelude_for prog @ marked) in
  (marked, combined, schemes, warnings)
