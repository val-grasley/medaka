open Ast

(* Canonical registry of all built-in values.  Every entry matches what an
   `extern` declaration in a .med source file would say.  resolve.ml and
   typecheck.ml derive their built-in tables from this list — no primitive
   name appears as a bare string literal in either file outside this module. *)
let entries : (string * ty) list = [
  (* pure : forall m a. a -> m a *)
  ("pure",    TyFun (TyVar "a", TyApp (TyVar "m", TyVar "a")));
  (* print : forall a. a -> <IO> Unit *)
  ("print",   TyFun (TyVar "a", TyEffect (["IO"],  TyCon "Unit")));
  (* println : forall a. a -> <IO> Unit *)
  ("println", TyFun (TyVar "a", TyEffect (["IO"],  TyCon "Unit")));
  (* Ref : forall a. a -> Ref a *)
  ("Ref",     TyFun (TyVar "a", TyApp (TyCon "Ref", TyVar "a")));
  (* set_ref : forall a. Ref a -> a -> <Mut> Unit *)
  ("set_ref", TyFun (TyApp (TyCon "Ref", TyVar "a"),
                TyFun (TyVar "a", TyEffect (["Mut"], TyCon "Unit"))));
  (* map : forall a b. (a -> b) -> List a -> List b *)
  ("map",     TyFun (TyFun (TyVar "a", TyVar "b"),
                TyFun (TyApp (TyCon "List", TyVar "a"),
                             TyApp (TyCon "List", TyVar "b"))));
  (* filter : forall a. (a -> Bool) -> List a -> List a *)
  ("filter",  TyFun (TyFun (TyVar "a", TyCon "Bool"),
                TyFun (TyApp (TyCon "List", TyVar "a"),
                             TyApp (TyCon "List", TyVar "a"))));
  (* fold : forall a b. (b -> a -> b) -> b -> List a -> b *)
  ("fold",    TyFun (TyFun (TyVar "b", TyFun (TyVar "a", TyVar "b")),
                TyFun (TyVar "b",
                  TyFun (TyApp (TyCon "List", TyVar "a"), TyVar "b"))));
  (* pi : Float *)
  ("pi",      TyCon "Float");
  (* e : Float *)
  ("e",       TyCon "Float");
]

let names : string list = List.map fst entries
