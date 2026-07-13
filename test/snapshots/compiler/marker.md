# META
source_lines=506
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted method_marker stage — Stage 1 port of `lib/method_marker.ml`.
-- Runs after desugar, before typecheck.  Rewrites every interface-method
-- occurrence `EVar m` to `EMethodRef m`, and every user constrained-function
-- occurrence `EVar f` (signature carries `=>`) to `EDictApp f` (the typecheck-
-- filled ref the reference carries is irrelevant pre-typecheck, so the
-- self-host nodes hold just the name).  Backtick infix `a \`f\` b` (EInfix) with
-- a marked operator lowers to the prefix application of the marked reference.
--
-- Both name sets are unioned over the prelude (core.mdk, passed in) and the
-- target program, mirroring the reference's `[Prelude.program; prog]`.  The
-- bottom-up traversal engine is reused from desugar (mapProg).
--
-- Validated byte-for-byte against `dev/astdump.exe --mark` (test/diff_compiler_mark.sh).
-- NOTE: the prelude-shadowing logic (Phase 78a/78b) is not yet ported — it is
-- added incrementally for the corpus files that shadow prelude names.

import frontend.ast.{
  Lit(..),
  Ty(..),
  Constraint(..),
  Pat(..),
  RecPatField(..),
  Guard(..),
  Arm(..),
  DoStmt(..),
  InterpPart(..),
  GuardArm(..),
  FieldAssign(..),
  Section(..),
  FunClause(..),
  LetBind(..),
  Route(..),
  Expr(..),
  UseMember(..),
  UsePath(..),
  PropParam(..),
  MethodDefault(..),
  IfaceMethod(..),
  Super(..),
  Require(..),
  ImplMethod(..),
  DataVis(..),
  Field(..),
  ConPayload(..),
  Variant(..),
  Decl(..),
}
import frontend.desugar.{mapProg, mapExpr, mapDecl}
import support.util.{contains}

-- ── Name-set collection ───────────────────────────────────────────────────
-- Interface method names declared across the decls (DInterface methods).
interfaceMethodNames : List Decl -> List String
interfaceMethodNames [] = []
interfaceMethodNames ((DInterface { methods, ... })::rest) = map ifaceMethodName methods
  ++ interfaceMethodNames rest
interfaceMethodNames (_::rest) = interfaceMethodNames rest

ifaceMethodName : IfaceMethod -> String
ifaceMethodName (IfaceMethod n _ _) = n

-- Names of functions whose declared signature carries a constraint (`Foo a =>`).
constrainedFnNames : List Decl -> List String
constrainedFnNames [] = []
constrainedFnNames ((DTypeSig _ name ty)::rest) =
  constrainedAdd name ty (constrainedFnNames rest)
constrainedFnNames (_::rest) = constrainedFnNames rest

constrainedAdd : String -> Ty -> List String -> List String
constrainedAdd name (TyConstrained _ _) acc = name::acc
constrainedAdd _ _ acc = acc

-- ── The marking rewrite ───────────────────────────────────────────────────
-- Method names take precedence over constrained-function names.
markNode : List String -> List String -> Expr -> Expr
markNode methods constrained (EVar x) = markVar methods constrained x
markNode methods constrained (EInfix op l r) =
  markInfix methods constrained op l r
markNode _ _ e = e

markVar : List String -> List String -> String -> Expr
markVar methods constrained x
  | contains x methods = EMethodRef x
  | contains x constrained = EDictApp x
  | otherwise = EVar x

markInfix : List String -> List String -> String -> Expr -> Expr -> Expr
markInfix methods constrained op l r
  | contains op methods = EApp (EApp (EMethodRef op) l) r
  | contains op constrained = EApp (EApp (EDictApp op) l) r
  | otherwise = EInfix op l r

markProgram : List String -> List String -> List Decl -> List Decl
markProgram methods constrained prog = map (markDecl methods constrained) prog

-- desugar.mapDecl's catch-all SKIPS DLetGroup (and DBench) bodies, so a
-- constrained-fn reference or interface-method occurrence inside a top-level
-- `let rec … with …` body would never be marked → its call site never gets a
-- dict route → the dict-passed callee is under-applied.  Mirror lib/method_marker.ml's
-- dedicated mark_decl: handle DLetGroup/DAttrib here, delegate everything else to
-- mapDecl (whose expr recursion is complete).
markDecl : List String -> List String -> Decl -> Decl
markDecl methods constrained (DLetGroup pub binds) =
  let f = markNode methods constrained
  DLetGroup pub (map (markLetBind f) binds)
markDecl methods constrained (DAttrib attrs inner) =
  DAttrib attrs (markDecl methods constrained inner)
markDecl methods constrained d = mapDecl (markNode methods constrained) d

markLetBind : (Expr -> Expr) -> LetBind -> LetBind
markLetBind f (LetBind n clauses) = LetBind n (map (markFunClause f) clauses)

markFunClause : (Expr -> Expr) -> FunClause -> FunClause
markFunClause f (FunClause pats body) = FunClause pats (mapExpr f body)

-- ── Phase 78b: shadow_rename ──────────────────────────────────────────────
-- A user top-level function whose name collides with a prelude interface method
-- (e.g. map.mdk's standalone `isEmpty` vs `Foldable.isEmpty`) is renamed to
-- `name#shadow` at its definition + reference sites, so its uses aren't marked
-- as the interface method.  (The reference also excludes names that are locally
-- rebound elsewhere — a method name that is ALSO bound by a local pattern
-- (let/lambda/match binder) is excluded from the rename, because shadowRename's
-- plain substitution renames the top-level def + reference sites but NOT the
-- local binder, so a body reference under the local `let name = …` would
-- mis-resolve to the renamed top-level def instead of the in-scope local.
-- Mirrors lib/method_marker.ml's `not (Hashtbl.mem locals n)` guard.)
shadowRename : List String -> List Decl -> List Decl
shadowRename preludeMethods prog =
  applyRenames (shadowRenames preludeMethods prog) prog

shadowRenames : List String -> List Decl -> List String
shadowRenames preludeMethods prog =
  keepNotIn (localBoundNames prog) (keepIn preludeMethods (userValueNames prog))

userValueNames : List Decl -> List String
userValueNames [] = []
userValueNames ((DFunDef _ n _ _)::rest) = n :: userValueNames rest
userValueNames (_::rest) = userValueNames rest

keepIn : List String -> List String -> List String
keepIn _ [] = []
keepIn pool (x::xs)
  | contains x pool = x :: keepIn pool xs
  | otherwise = keepIn pool xs

applyRenames : List String -> List Decl -> List Decl
applyRenames [] prog = prog
applyRenames renames prog = map (renameDecl renames) prog

renameDecl : List String -> Decl -> Decl
renameDecl renames (DFunDef pub n ps body) =
  DFunDef pub (subName renames n) ps (mapExpr (renameVar renames) body)
renameDecl renames (DTypeSig pub n t) = DTypeSig pub (subName renames n) t
renameDecl renames d = mapDecl (renameVar renames) d

renameVar : List String -> Expr -> Expr
renameVar renames (EVar x) = EVar (subName renames x)
renameVar renames (EMethodRef x) = EMethodRef (subName renames x)
renameVar renames (EDictApp x) = EDictApp (subName renames x)
renameVar _ e = e

subName : List String -> String -> String
subName renames x
  | contains x renames = x ++ "#shadow"
  | otherwise = x

-- ── Phase 78a: prelude plain-function shadow → drop from constrained set ──
-- A prelude *constrained* plain function (e.g. `count : Foldable t => …`) that
-- a user file shadows with its own (unconstrained) definition must NOT mark the
-- user's references as EDictApp.  Mirror of mark_with_prelude's adjustment:
-- remove from the constrained set any *droppable* prelude plain-fn name the user
-- shadows and does not itself re-declare constrained.  "Droppable" = not
-- referenced by any other prelude decl: count/find (mut_array/array) are
-- droppable and get removed; clamp (used in a core prop) is NOT, so guards.mdk's
-- shadow doesn't remove it and its `clamp` references stay marked.
preludePlainFnNames : List Decl -> List String
preludePlainFnNames prelude =
  keepNotIn (interfaceMethodNames prelude) (allFunDefNames prelude)

allFunDefNames : List Decl -> List String
allFunDefNames [] = []
allFunDefNames ((DFunDef _ n _ _)::rest) = n :: allFunDefNames rest
allFunDefNames (_::rest) = allFunDefNames rest

-- keep the names in the second list that are NOT in the first
keepNotIn : List String -> List String -> List String
keepNotIn _ [] = []
keepNotIn pool (x::xs)
  | contains x pool = keepNotIn pool xs
  | otherwise = x :: keepNotIn pool xs

-- A prelude plain fn is *droppable* only if no OTHER prelude decl references it
-- (dropping one the prelude uses internally — e.g. `clamp`, used in a core prop —
-- would silently rebind those uses).  droppable = plain fns − externally-referenced.
droppablePreludeFns : List Decl -> List String
droppablePreludeFns prelude =
  keepNotIn (externalRefs prelude) (preludePlainFnNames prelude)

externalRefs : List Decl -> List String
externalRefs prelude = flatMap declExternalRefs prelude

declExternalRefs : Decl -> List String
declExternalRefs d = keepNotIn (declDefines d) (declRefs d)

declDefines : Decl -> List String
declDefines (DFunDef _ n _ _) = [n]
declDefines (DImpl { methods, ... }) = map implMethodNameOf methods
declDefines (DInterface { methods, ... }) = map ifaceMethodName methods
declDefines _ = []

implMethodNameOf : ImplMethod -> String
implMethodNameOf (ImplMethod n _ _) = n

export declRefs : Decl -> List String
declRefs d = flatMap collectVars (declBodies d)

export declBodies : Decl -> List Expr
declBodies (DFunDef _ _ _ body) = [body]
declBodies (DImpl { methods, ... }) = map implMethodBody methods
declBodies (DInterface { methods, ... }) = flatMap ifaceMethodBodies methods
declBodies (DProp _ _ _ body) = [body]
declBodies (DTest _ _ body) = [body]
declBodies (DBench _ _ body) = [body]
-- OBS5: a `@attr…`-wrapped decl carries its body in the INNER decl; without this
-- arm declRefs of e.g. `@inline f = … helper …` is [] → a helper referenced ONLY
-- through an attributed function would be DCE'd (unbound-variable miscompile).
declBodies (DAttrib _ d) = declBodies d
-- OBS5: a top-level `let rec … with …` group's clause bodies carry references;
-- DCE keeps the group whole (non-DFunDef) but must still seed reachability from
-- its refs, or a binding used ONLY inside a top-level let-group is dropped.
declBodies (DLetGroup _ binds) = flatMap letBindBodies binds
declBodies _ = []

letBindBodies : LetBind -> List Expr
letBindBodies (LetBind _ clauses) = map funClauseBody clauses

funClauseBody : FunClause -> Expr
funClauseBody (FunClause _ body) = body

implMethodBody : ImplMethod -> Expr
implMethodBody (ImplMethod _ _ body) = body

ifaceMethodBodies : IfaceMethod -> List Expr
ifaceMethodBodies (IfaceMethod _ _ (Some (MethodDefault _ body))) = [body]
ifaceMethodBodies (IfaceMethod _ _ None) = []

-- all referenced names (EVar/EMethodRef/EDictApp) in an expr tree
collectVars : Expr -> List String
collectVars (EVar x) = [x]
collectVars (EMethodRef x) = [x]
collectVars (EDictApp x) = [x]
collectVars (EApp a b) = collectVars a ++ collectVars b
collectVars (ELam _ b) = collectVars b
collectVars (ELet _ _ _ e1 e2) = collectVars e1 ++ collectVars e2
collectVars (ELetGroup bs e2) = flatMap letBindVars bs ++ collectVars e2
collectVars (EMatch e0 arms) = collectVars e0 ++ flatMap armVars arms
collectVars (EIf c t el) = collectVars c ++ collectVars t ++ collectVars el
collectVars (EBinOp _ a b _) = collectVars a ++ collectVars b
collectVars (EUnOp _ a _) = collectVars a
-- The operator name IS a reference: a backtick infix `a `divide` b` names the
-- plain top-level function `divide` (marker leaves it EInfix when `divide` is
-- neither a method nor a constrained fn), so DCE must see `divide` as reachable
-- or it drops the def and the emitter hits `unbound variable 'divide'`. Built-in
-- operator symbols (`+`/`==`) never name a DFunDef, so adding them is inert.
collectVars (EInfix op a b) = op :: collectVars a ++ collectVars b
collectVars (EFieldAccess e0 _ _) = collectVars e0
collectVars (ERecordCreate _ fs) = flatMap fieldAssignVars fs
collectVars (ERecordUpdate e0 fs _) = collectVars e0
  ++ flatMap fieldAssignVars fs
collectVars (EVariantUpdate _ e0 fs) = collectVars e0
  ++ flatMap fieldAssignVars fs
collectVars (EArrayLit es) = flatMap collectVars es
collectVars (EListLit es) = flatMap collectVars es
collectVars (ETuple es) = flatMap collectVars es
collectVars (EIndex e0 i _) = collectVars e0 ++ collectVars i
collectVars (ERangeList lo hi _) = collectVars lo ++ collectVars hi
collectVars (ERangeArray lo hi _) = collectVars lo ++ collectVars hi
collectVars (ESlice e0 lo hi _ _) = collectVars e0
  ++ collectVars lo
  ++ collectVars hi
collectVars (EBlock stmts) = flatMap doStmtVars stmts
collectVars (EDo stmts) = flatMap doStmtVars stmts
collectVars (EAnnot e0 _) = collectVars e0
collectVars (EStringInterp parts) = flatMap interpVars parts
collectVars (EGuards arms) = flatMap guardArmVars arms
collectVars (ESection (SecRight _ e0)) = collectVars e0
collectVars (ESection (SecLeft e0 _)) = collectVars e0
-- Post-typecheck elaborated reference nodes (EVarAt/EMethodAt/EDictAt all carry
-- the referenced name as their first field).  These never appear in marker's own
-- pre-elaboration input, so adding them is inert for marking — but it makes
-- collectVars a sound reference walk for POST-elaboration consumers (DCE runs on
-- the elaborated tree, where return-position methods are EMethodAt, constrained
-- fns EDictAt, and resolved vars EVarAt).  Missing one here would silently drop a
-- still-reachable binding.
collectVars (EVarAt x _) = [x]
-- P0-18: a definer-shadow EMethodAt carries the BARE dispatch name `x` AND, in its
-- resolved route, the MANGLED standalone symbol `<mid>__x` (RLocal fallback).  Emit
-- BOTH as references so DCE keeps the standalone define alive — else the `RLocal`
-- emit calls an eliminated `@mdk_<mid>__x` (undefined-symbol link error).  Reading
-- the route ref is pure (same as `lower`).  "" (un-mangled path) contributes nothing.
collectVars (EMethodAt x routeRef _ _) = x :: routeExtraRefs routeRef.value
collectVars (EDictAt x _) = [x]
-- Remaining reference-bearing forms (for soundness as a DCE reference walk; some
-- are desugared away before the prelude reaches DCE, but the user program may
-- still carry them).  Missing one risks dropping a reachable binding.
collectVars (EHeadAnnot e0 _) = collectVars e0
collectVars (EAsPat _ e0) = collectVars e0
collectVars (EMapLit _ kvs) = flatMap mapLitPairVars kvs
collectVars (ESetLit _ es) = flatMap collectVars es
collectVars (ELoc _ e) = collectVars e
collectVars (EDoOrigin _ e) = collectVars e
collectVars _ = []

-- P0-18: the extra symbol a resolved EMethodAt route references beyond its bare
-- name — the mangled standalone symbol carried by an `RLocal <sym>` fallback.
routeExtraRefs : Route -> List String
routeExtraRefs (RLocal "") = []
routeExtraRefs (RLocal s) = [s]
routeExtraRefs _ = []

letBindVars : LetBind -> List String
letBindVars (LetBind _ clauses) = flatMap funClauseVars clauses

funClauseVars : FunClause -> List String
funClauseVars (FunClause _ body) = collectVars body

armVars : Arm -> List String
armVars (Arm _ gs body) = flatMap guardVars gs ++ collectVars body

guardVars : Guard -> List String
guardVars (GBool e) = collectVars e
guardVars (GBind _ e) = collectVars e

guardArmVars : GuardArm -> List String
guardArmVars (GuardArm gs body) = flatMap guardVars gs ++ collectVars body

fieldAssignVars : FieldAssign -> List String
fieldAssignVars (FieldAssign _ e) = collectVars e

doStmtVars : DoStmt -> List String
doStmtVars (DoExpr e) = collectVars e
doStmtVars (DoBind _ e) = collectVars e
doStmtVars (DoLet _ _ _ e) = collectVars e
doStmtVars (DoAssign _ e) = collectVars e
doStmtVars (DoFieldAssign _ _ e) = collectVars e

interpVars : InterpPart -> List String
interpVars (InterpStr _) = []
interpVars (InterpExpr e) = collectVars e

mapLitPairVars : (Expr, Expr) -> List String
mapLitPairVars (k, v) = collectVars k ++ collectVars v

-- ── Local-binder collection (mirror of lib/method_marker.ml local_bound_names) ─
-- Every name bound by a *local* pattern anywhere in the program: clause/lambda
-- params, let/match/do/comprehension/guard binders.  A prelude-method name in
-- this set is rebound locally somewhere, so shadowRename's plain substitution
-- would mis-capture it (rename the top-level def + reference but NOT the local
-- binder → the body reference points at the renamed top-level def instead of the
-- in-scope local).  Excluding such names from the rename set leaves lexical scope
-- to resolve them, exactly as the OCaml oracle does.

patBindings : Pat -> List String
patBindings (PVar x) = [x]
patBindings (PCon _ ps) = flatMap patBindings ps
patBindings (PCons a b) = patBindings a ++ patBindings b
patBindings (PTuple ps) = flatMap patBindings ps
patBindings (PList ps) = flatMap patBindings ps
patBindings (PAs x p) = x :: patBindings p
patBindings (PRec _ fields _) = flatMap recFieldBindings fields
patBindings _ = []

recFieldBindings : RecPatField -> List String
recFieldBindings (RecPatField fname None) = [fname]
recFieldBindings (RecPatField _ (Some p)) = patBindings p

-- Names bound by local patterns *within* an expression tree.
localBoundExpr : Expr -> List String
localBoundExpr (ELam ps b) = flatMap patBindings ps ++ localBoundExpr b
localBoundExpr (ELet _ _ p e1 e2) = patBindings p
  ++ localBoundExpr e1
  ++ localBoundExpr e2
localBoundExpr (ELetGroup bs e2) = flatMap letBindBound bs ++ localBoundExpr e2
localBoundExpr (EMatch e0 arms) = localBoundExpr e0 ++ flatMap armBound arms
localBoundExpr (EApp a b) = localBoundExpr a ++ localBoundExpr b
localBoundExpr (EIf c t el) = localBoundExpr c
  ++ localBoundExpr t
  ++ localBoundExpr el
localBoundExpr (EBinOp _ a b _) = localBoundExpr a ++ localBoundExpr b
localBoundExpr (EUnOp _ a _) = localBoundExpr a
localBoundExpr (EInfix _ a b) = localBoundExpr a ++ localBoundExpr b
localBoundExpr (EFieldAccess e0 _ _) = localBoundExpr e0
localBoundExpr (ERecordCreate _ fs) = flatMap fieldAssignBound fs
localBoundExpr (ERecordUpdate e0 fs _) = localBoundExpr e0
  ++ flatMap fieldAssignBound fs
localBoundExpr (EVariantUpdate _ e0 fs) = localBoundExpr e0
  ++ flatMap fieldAssignBound fs
localBoundExpr (EArrayLit es) = flatMap localBoundExpr es
localBoundExpr (EListLit es) = flatMap localBoundExpr es
localBoundExpr (ETuple es) = flatMap localBoundExpr es
localBoundExpr (EIndex e0 i _) = localBoundExpr e0 ++ localBoundExpr i
localBoundExpr (ERangeList lo hi _) = localBoundExpr lo ++ localBoundExpr hi
localBoundExpr (ERangeArray lo hi _) = localBoundExpr lo ++ localBoundExpr hi
localBoundExpr (ESlice e0 lo hi _ _) = localBoundExpr e0
  ++ localBoundExpr lo
  ++ localBoundExpr hi
localBoundExpr (EBlock stmts) = flatMap doStmtBound stmts
localBoundExpr (EDo stmts) = flatMap doStmtBound stmts
localBoundExpr (EAnnot e0 _) = localBoundExpr e0
localBoundExpr (EStringInterp parts) = flatMap interpBound parts
localBoundExpr (EGuards arms) = flatMap guardArmBound arms
localBoundExpr (ESection (SecRight _ e0)) = localBoundExpr e0
localBoundExpr (ESection (SecLeft e0 _)) = localBoundExpr e0
localBoundExpr (EHeadAnnot e0 _) = localBoundExpr e0
localBoundExpr (EAsPat _ e0) = localBoundExpr e0
localBoundExpr (EMapLit _ kvs) = flatMap mapLitPairBound kvs
localBoundExpr (ESetLit _ es) = flatMap localBoundExpr es
localBoundExpr (ELoc _ e) = localBoundExpr e
localBoundExpr (EDoOrigin _ e) = localBoundExpr e
localBoundExpr _ = []

letBindBound : LetBind -> List String
letBindBound (LetBind _ clauses) = flatMap funClauseBound clauses

funClauseBound : FunClause -> List String
funClauseBound (FunClause ps body) = flatMap patBindings ps
  ++ localBoundExpr body

armBound : Arm -> List String
armBound (Arm p gs body) = patBindings p
  ++ flatMap guardBound gs
  ++ localBoundExpr body

guardBound : Guard -> List String
guardBound (GBool e) = localBoundExpr e
guardBound (GBind p e) = patBindings p ++ localBoundExpr e

guardArmBound : GuardArm -> List String
guardArmBound (GuardArm gs body) = flatMap guardBound gs ++ localBoundExpr body

fieldAssignBound : FieldAssign -> List String
fieldAssignBound (FieldAssign _ e) = localBoundExpr e

doStmtBound : DoStmt -> List String
doStmtBound (DoExpr e) = localBoundExpr e
doStmtBound (DoBind p e) = patBindings p ++ localBoundExpr e
doStmtBound (DoLet _ _ p e) = patBindings p ++ localBoundExpr e
doStmtBound (DoAssign _ e) = localBoundExpr e
doStmtBound (DoFieldAssign _ _ e) = localBoundExpr e

interpBound : InterpPart -> List String
interpBound (InterpStr _) = []
interpBound (InterpExpr e) = localBoundExpr e

mapLitPairBound : (Expr, Expr) -> List String
mapLitPairBound (k, v) = localBoundExpr k ++ localBoundExpr v

-- Names bound by local patterns across a whole declaration: its own params
-- (DFunDef/DImpl method/DInterface default/DLetGroup clauses) plus every binder
-- in its body expressions.
declLocalBound : Decl -> List String
declLocalBound (DFunDef _ _ ps body) = flatMap patBindings ps
  ++ localBoundExpr body
declLocalBound (DAttrib _ d) = declLocalBound d
declLocalBound (DLetGroup _ binds) = flatMap letBindBound binds
declLocalBound d = flatMap localBoundExpr (declBodies d)

export localBoundNames : List Decl -> List String
localBoundNames prog = flatMap declLocalBound prog

-- ── Top-level entry ───────────────────────────────────────────────────────
-- `preludeProg` is the desugared prelude (core.mdk); `prog` the desugared
-- target.  shadow_rename (78b) first, then mark against the union of prelude +
-- (renamed) target names, with the 78a constrained-set adjustment.
-- Mark `prog` given the prelude-derived name sets already computed.  Splitting
-- this out lets a batch caller compute the prelude sets ONCE (via markerFor) and
-- reuse them across many target files instead of rescanning the prelude per file.
markWith : List String -> List String -> List String -> List Decl -> List Decl
markWith preludeMethods preludeDroppable preludeConstrained prog =
  let prog2 = shadowRename preludeMethods prog
  let methods = preludeMethods ++ interfaceMethodNames prog2
  let shadowed = keepIn preludeDroppable (userValueNames prog2)
  let userConstrained = constrainedFnNames prog2
  let toRemove = keepNotIn userConstrained shadowed
  let constrained = keepNotIn toRemove (preludeConstrained ++ userConstrained)
  markProgram methods constrained prog2

export markWithPrelude : List Decl -> List Decl -> List Decl
markWithPrelude preludeProg prog =
  markWith
    (interfaceMethodNames preludeProg)
    (droppablePreludeFns preludeProg)
    (constrainedFnNames preludeProg)
    prog

-- Curried marker: scans the (fixed) prelude ONCE and returns a closure that
-- marks each target file.  A batch harness that marks many files against one
-- prelude should `let mark = markerFor preludeProg` once and call `mark` per
-- file — the prelude scans (interfaceMethodNames/droppablePreludeFns/
-- constrainedFnNames) then happen once instead of per file.
export markerFor : List Decl -> List Decl -> List Decl
markerFor preludeProg =
  let preludeMethods = interfaceMethodNames preludeProg
  let preludeDroppable = droppablePreludeFns preludeProg
  let preludeConstrained = constrainedFnNames preludeProg
  prog => markWith preludeMethods preludeDroppable preludeConstrained prog
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Ty" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Route" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapProg" false) (mem "mapExpr" false) (mem "mapDecl" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false))))
(DTypeSig false "interfaceMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "interfaceMethodNames" ((PList)) (EListLit))
(DFunDef false "interfaceMethodNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "ifaceMethodName")) (EVar "methods")) (EApp (EVar "interfaceMethodNames") (EVar "rest"))))
(DFunDef false "interfaceMethodNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "interfaceMethodNames") (EVar "rest")))
(DTypeSig false "ifaceMethodName" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodName" ((PCon "IfaceMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "constrainedFnNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constrainedFnNames" ((PList)) (EListLit))
(DFunDef false "constrainedFnNames" ((PCons (PCon "DTypeSig" PWild (PVar "name") (PVar "ty")) (PVar "rest"))) (EApp (EApp (EApp (EVar "constrainedAdd") (EVar "name")) (EVar "ty")) (EApp (EVar "constrainedFnNames") (EVar "rest"))))
(DFunDef false "constrainedFnNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "constrainedFnNames") (EVar "rest")))
(DTypeSig false "constrainedAdd" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "constrainedAdd" ((PVar "name") (PCon "TyConstrained" PWild PWild) (PVar "acc")) (EBinOp "::" (EVar "name") (EVar "acc")))
(DFunDef false "constrainedAdd" (PWild PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "markNode" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "markNode" ((PVar "methods") (PVar "constrained") (PCon "EVar" (PVar "x"))) (EApp (EApp (EApp (EVar "markVar") (EVar "methods")) (EVar "constrained")) (EVar "x")))
(DFunDef false "markNode" ((PVar "methods") (PVar "constrained") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "markInfix") (EVar "methods")) (EVar "constrained")) (EVar "op")) (EVar "l")) (EVar "r")))
(DFunDef false "markNode" (PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "markVar" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Expr")))))
(DFunDef false "markVar" ((PVar "methods") (PVar "constrained") (PVar "x")) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "methods")) (EApp (EVar "EMethodRef") (EVar "x")) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "constrained")) (EApp (EVar "EDictApp") (EVar "x")) (EIf (EVar "otherwise") (EApp (EVar "EVar") (EVar "x")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "markInfix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))))
(DFunDef false "markInfix" ((PVar "methods") (PVar "constrained") (PVar "op") (PVar "l") (PVar "r")) (EIf (EApp (EApp (EVar "contains") (EVar "op")) (EVar "methods")) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EMethodRef") (EVar "op"))) (EVar "l"))) (EVar "r")) (EIf (EApp (EApp (EVar "contains") (EVar "op")) (EVar "constrained")) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EDictApp") (EVar "op"))) (EVar "l"))) (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "markProgram" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "markProgram" ((PVar "methods") (PVar "constrained") (PVar "prog")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "markDecl") (EVar "methods")) (EVar "constrained"))) (EVar "prog")))
(DTypeSig false "markDecl" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Decl")))))
(DFunDef false "markDecl" ((PVar "methods") (PVar "constrained") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EBlock (DoLet false false (PVar "f") (EApp (EApp (EVar "markNode") (EVar "methods")) (EVar "constrained"))) (DoExpr (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EVar "map") (EApp (EVar "markLetBind") (EVar "f"))) (EVar "binds"))))))
(DFunDef false "markDecl" ((PVar "methods") (PVar "constrained") (PCon "DAttrib" (PVar "attrs") (PVar "inner"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EApp (EVar "markDecl") (EVar "methods")) (EVar "constrained")) (EVar "inner"))))
(DFunDef false "markDecl" ((PVar "methods") (PVar "constrained") (PVar "d")) (EApp (EApp (EVar "mapDecl") (EApp (EApp (EVar "markNode") (EVar "methods")) (EVar "constrained"))) (EVar "d")))
(DTypeSig false "markLetBind" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "markLetBind" ((PVar "f") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "markFunClause") (EVar "f"))) (EVar "clauses"))))
(DTypeSig false "markFunClause" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "markFunClause" ((PVar "f") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "pats")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "body"))))
(DTypeSig false "shadowRename" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "shadowRename" ((PVar "preludeMethods") (PVar "prog")) (EApp (EApp (EVar "applyRenames") (EApp (EApp (EVar "shadowRenames") (EVar "preludeMethods")) (EVar "prog"))) (EVar "prog")))
(DTypeSig false "shadowRenames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "shadowRenames" ((PVar "preludeMethods") (PVar "prog")) (EApp (EApp (EVar "keepNotIn") (EApp (EVar "localBoundNames") (EVar "prog"))) (EApp (EApp (EVar "keepIn") (EVar "preludeMethods")) (EApp (EVar "userValueNames") (EVar "prog")))))
(DTypeSig false "userValueNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "userValueNames" ((PList)) (EListLit))
(DFunDef false "userValueNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "userValueNames") (EVar "rest")))
(DTypeSig false "keepIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "keepIn" (PWild (PList)) (EListLit))
(DFunDef false "keepIn" ((PVar "pool") (PCons (PVar "x") (PVar "xs"))) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "pool")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "keepIn") (EVar "pool")) (EVar "xs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "keepIn") (EVar "pool")) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyRenames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "applyRenames" ((PList) (PVar "prog")) (EVar "prog"))
(DFunDef false "applyRenames" ((PVar "renames") (PVar "prog")) (EApp (EApp (EVar "map") (EApp (EVar "renameDecl") (EVar "renames"))) (EVar "prog")))
(DTypeSig false "renameDecl" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "renameDecl" ((PVar "renames") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EApp (EApp (EVar "subName") (EVar "renames")) (EVar "n"))) (EVar "ps")) (EApp (EApp (EVar "mapExpr") (EApp (EVar "renameVar") (EVar "renames"))) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "renames") (PCon "DTypeSig" (PVar "pub") (PVar "n") (PVar "t"))) (EApp (EApp (EApp (EVar "DTypeSig") (EVar "pub")) (EApp (EApp (EVar "subName") (EVar "renames")) (EVar "n"))) (EVar "t")))
(DFunDef false "renameDecl" ((PVar "renames") (PVar "d")) (EApp (EApp (EVar "mapDecl") (EApp (EVar "renameVar") (EVar "renames"))) (EVar "d")))
(DTypeSig false "renameVar" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "renameVar" ((PVar "renames") (PCon "EVar" (PVar "x"))) (EApp (EVar "EVar") (EApp (EApp (EVar "subName") (EVar "renames")) (EVar "x"))))
(DFunDef false "renameVar" ((PVar "renames") (PCon "EMethodRef" (PVar "x"))) (EApp (EVar "EMethodRef") (EApp (EApp (EVar "subName") (EVar "renames")) (EVar "x"))))
(DFunDef false "renameVar" ((PVar "renames") (PCon "EDictApp" (PVar "x"))) (EApp (EVar "EDictApp") (EApp (EApp (EVar "subName") (EVar "renames")) (EVar "x"))))
(DFunDef false "renameVar" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "subName" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "subName" ((PVar "renames") (PVar "x")) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "renames")) (EBinOp "++" (EVar "x") (ELit (LString "#shadow"))) (EIf (EVar "otherwise") (EVar "x") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "preludePlainFnNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "preludePlainFnNames" ((PVar "prelude")) (EApp (EApp (EVar "keepNotIn") (EApp (EVar "interfaceMethodNames") (EVar "prelude"))) (EApp (EVar "allFunDefNames") (EVar "prelude"))))
(DTypeSig false "allFunDefNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "allFunDefNames" ((PList)) (EListLit))
(DFunDef false "allFunDefNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "allFunDefNames") (EVar "rest"))))
(DFunDef false "allFunDefNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "allFunDefNames") (EVar "rest")))
(DTypeSig false "keepNotIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "keepNotIn" (PWild (PList)) (EListLit))
(DFunDef false "keepNotIn" ((PVar "pool") (PCons (PVar "x") (PVar "xs"))) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "pool")) (EApp (EApp (EVar "keepNotIn") (EVar "pool")) (EVar "xs")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "keepNotIn") (EVar "pool")) (EVar "xs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "droppablePreludeFns" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "droppablePreludeFns" ((PVar "prelude")) (EApp (EApp (EVar "keepNotIn") (EApp (EVar "externalRefs") (EVar "prelude"))) (EApp (EVar "preludePlainFnNames") (EVar "prelude"))))
(DTypeSig false "externalRefs" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "externalRefs" ((PVar "prelude")) (EApp (EApp (EVar "flatMap") (EVar "declExternalRefs")) (EVar "prelude")))
(DTypeSig false "declExternalRefs" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declExternalRefs" ((PVar "d")) (EApp (EApp (EVar "keepNotIn") (EApp (EVar "declDefines") (EVar "d"))) (EApp (EVar "declRefs") (EVar "d"))))
(DTypeSig false "declDefines" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declDefines" ((PCon "DFunDef" PWild (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "declDefines" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "map") (EVar "implMethodNameOf")) (EVar "methods")))
(DFunDef false "declDefines" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EVar "map") (EVar "ifaceMethodName")) (EVar "methods")))
(DFunDef false "declDefines" (PWild) (EListLit))
(DTypeSig false "implMethodNameOf" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodNameOf" ((PCon "ImplMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig true "declRefs" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declRefs" ((PVar "d")) (EApp (EApp (EVar "flatMap") (EVar "collectVars")) (EApp (EVar "declBodies") (EVar "d"))))
(DTypeSig true "declBodies" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "declBodies" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EListLit (EVar "body")))
(DFunDef false "declBodies" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "map") (EVar "implMethodBody")) (EVar "methods")))
(DFunDef false "declBodies" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EVar "ifaceMethodBodies")) (EVar "methods")))
(DFunDef false "declBodies" ((PCon "DProp" PWild PWild PWild (PVar "body"))) (EListLit (EVar "body")))
(DFunDef false "declBodies" ((PCon "DTest" PWild PWild (PVar "body"))) (EListLit (EVar "body")))
(DFunDef false "declBodies" ((PCon "DBench" PWild PWild (PVar "body"))) (EListLit (EVar "body")))
(DFunDef false "declBodies" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declBodies") (EVar "d")))
(DFunDef false "declBodies" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EVar "flatMap") (EVar "letBindBodies")) (EVar "binds")))
(DFunDef false "declBodies" (PWild) (EListLit))
(DTypeSig false "letBindBodies" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "letBindBodies" ((PCon "LetBind" PWild (PVar "clauses"))) (EApp (EApp (EVar "map") (EVar "funClauseBody")) (EVar "clauses")))
(DTypeSig false "funClauseBody" (TyFun (TyCon "FunClause") (TyCon "Expr")))
(DFunDef false "funClauseBody" ((PCon "FunClause" PWild (PVar "body"))) (EVar "body"))
(DTypeSig false "implMethodBody" (TyFun (TyCon "ImplMethod") (TyCon "Expr")))
(DFunDef false "implMethodBody" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EVar "body"))
(DTypeSig false "ifaceMethodBodies" (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "ifaceMethodBodies" ((PCon "IfaceMethod" PWild PWild (PCon "Some" (PCon "MethodDefault" PWild (PVar "body"))))) (EListLit (EVar "body")))
(DFunDef false "ifaceMethodBodies" ((PCon "IfaceMethod" PWild PWild (PCon "None"))) (EListLit))
(DTypeSig false "collectVars" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectVars" ((PCon "EVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "collectVars" ((PCon "EMethodRef" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "collectVars" ((PCon "EDictApp" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "collectVars" ((PCon "EApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "collectVars") (EVar "a")) (EApp (EVar "collectVars") (EVar "b"))))
(DFunDef false "collectVars" ((PCon "ELam" PWild (PVar "b"))) (EApp (EVar "collectVars") (EVar "b")))
(DFunDef false "collectVars" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EBinOp "++" (EApp (EVar "collectVars") (EVar "e1")) (EApp (EVar "collectVars") (EVar "e2"))))
(DFunDef false "collectVars" ((PCon "ELetGroup" (PVar "bs") (PVar "e2"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "letBindVars")) (EVar "bs")) (EApp (EVar "collectVars") (EVar "e2"))))
(DFunDef false "collectVars" ((PCon "EMatch" (PVar "e0") (PVar "arms"))) (EBinOp "++" (EApp (EVar "collectVars") (EVar "e0")) (EApp (EApp (EVar "flatMap") (EVar "armVars")) (EVar "arms"))))
(DFunDef false "collectVars" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectVars") (EVar "c")) (EApp (EVar "collectVars") (EVar "t"))) (EApp (EVar "collectVars") (EVar "el"))))
(DFunDef false "collectVars" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectVars") (EVar "a")) (EApp (EVar "collectVars") (EVar "b"))))
(DFunDef false "collectVars" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EVar "collectVars") (EVar "a")))
(DFunDef false "collectVars" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EBinOp "::" (EVar "op") (EBinOp "++" (EApp (EVar "collectVars") (EVar "a")) (EApp (EVar "collectVars") (EVar "b")))))
(DFunDef false "collectVars" ((PCon "EFieldAccess" (PVar "e0") PWild PWild)) (EApp (EVar "collectVars") (EVar "e0")))
(DFunDef false "collectVars" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "flatMap") (EVar "fieldAssignVars")) (EVar "fs")))
(DFunDef false "collectVars" ((PCon "ERecordUpdate" (PVar "e0") (PVar "fs") PWild)) (EBinOp "++" (EApp (EVar "collectVars") (EVar "e0")) (EApp (EApp (EVar "flatMap") (EVar "fieldAssignVars")) (EVar "fs"))))
(DFunDef false "collectVars" ((PCon "EVariantUpdate" PWild (PVar "e0") (PVar "fs"))) (EBinOp "++" (EApp (EVar "collectVars") (EVar "e0")) (EApp (EApp (EVar "flatMap") (EVar "fieldAssignVars")) (EVar "fs"))))
(DFunDef false "collectVars" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "collectVars")) (EVar "es")))
(DFunDef false "collectVars" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "collectVars")) (EVar "es")))
(DFunDef false "collectVars" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "collectVars")) (EVar "es")))
(DFunDef false "collectVars" ((PCon "EIndex" (PVar "e0") (PVar "i") PWild)) (EBinOp "++" (EApp (EVar "collectVars") (EVar "e0")) (EApp (EVar "collectVars") (EVar "i"))))
(DFunDef false "collectVars" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "collectVars") (EVar "lo")) (EApp (EVar "collectVars") (EVar "hi"))))
(DFunDef false "collectVars" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "collectVars") (EVar "lo")) (EApp (EVar "collectVars") (EVar "hi"))))
(DFunDef false "collectVars" ((PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectVars") (EVar "e0")) (EApp (EVar "collectVars") (EVar "lo"))) (EApp (EVar "collectVars") (EVar "hi"))))
(DFunDef false "collectVars" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "doStmtVars")) (EVar "stmts")))
(DFunDef false "collectVars" ((PCon "EDo" (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "doStmtVars")) (EVar "stmts")))
(DFunDef false "collectVars" ((PCon "EAnnot" (PVar "e0") PWild)) (EApp (EVar "collectVars") (EVar "e0")))
(DFunDef false "collectVars" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "flatMap") (EVar "interpVars")) (EVar "parts")))
(DFunDef false "collectVars" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "flatMap") (EVar "guardArmVars")) (EVar "arms")))
(DFunDef false "collectVars" ((PCon "ESection" (PCon "SecRight" PWild (PVar "e0")))) (EApp (EVar "collectVars") (EVar "e0")))
(DFunDef false "collectVars" ((PCon "ESection" (PCon "SecLeft" (PVar "e0") PWild))) (EApp (EVar "collectVars") (EVar "e0")))
(DFunDef false "collectVars" ((PCon "EVarAt" (PVar "x") PWild)) (EListLit (EVar "x")))
(DFunDef false "collectVars" ((PCon "EMethodAt" (PVar "x") (PVar "routeRef") PWild PWild)) (EBinOp "::" (EVar "x") (EApp (EVar "routeExtraRefs") (EFieldAccess (EVar "routeRef") "value"))))
(DFunDef false "collectVars" ((PCon "EDictAt" (PVar "x") PWild)) (EListLit (EVar "x")))
(DFunDef false "collectVars" ((PCon "EHeadAnnot" (PVar "e0") PWild)) (EApp (EVar "collectVars") (EVar "e0")))
(DFunDef false "collectVars" ((PCon "EAsPat" PWild (PVar "e0"))) (EApp (EVar "collectVars") (EVar "e0")))
(DFunDef false "collectVars" ((PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EVar "flatMap") (EVar "mapLitPairVars")) (EVar "kvs")))
(DFunDef false "collectVars" ((PCon "ESetLit" PWild (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "collectVars")) (EVar "es")))
(DFunDef false "collectVars" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DFunDef false "collectVars" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DFunDef false "collectVars" (PWild) (EListLit))
(DTypeSig false "routeExtraRefs" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "routeExtraRefs" ((PCon "RLocal" (PLit (LString "")))) (EListLit))
(DFunDef false "routeExtraRefs" ((PCon "RLocal" (PVar "s"))) (EListLit (EVar "s")))
(DFunDef false "routeExtraRefs" (PWild) (EListLit))
(DTypeSig false "letBindVars" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "letBindVars" ((PCon "LetBind" PWild (PVar "clauses"))) (EApp (EApp (EVar "flatMap") (EVar "funClauseVars")) (EVar "clauses")))
(DTypeSig false "funClauseVars" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "funClauseVars" ((PCon "FunClause" PWild (PVar "body"))) (EApp (EVar "collectVars") (EVar "body")))
(DTypeSig false "armVars" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "armVars" ((PCon "Arm" PWild (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "guardVars")) (EVar "gs")) (EApp (EVar "collectVars") (EVar "body"))))
(DTypeSig false "guardVars" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "guardVars" ((PCon "GBool" (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DFunDef false "guardVars" ((PCon "GBind" PWild (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DTypeSig false "guardArmVars" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "guardArmVars" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "guardVars")) (EVar "gs")) (EApp (EVar "collectVars") (EVar "body"))))
(DTypeSig false "fieldAssignVars" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fieldAssignVars" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DTypeSig false "doStmtVars" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "doStmtVars" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DFunDef false "doStmtVars" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DFunDef false "doStmtVars" ((PCon "DoLet" PWild PWild PWild (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DFunDef false "doStmtVars" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DFunDef false "doStmtVars" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DTypeSig false "interpVars" (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "interpVars" ((PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "interpVars" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DTypeSig false "mapLitPairVars" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "mapLitPairVars" ((PTuple (PVar "k") (PVar "v"))) (EBinOp "++" (EApp (EVar "collectVars") (EVar "k")) (EApp (EVar "collectVars") (EVar "v"))))
(DTypeSig false "patBindings" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patBindings" ((PCon "PVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "patBindings" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "a")) (EApp (EVar "patBindings") (EVar "b"))))
(DFunDef false "patBindings" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PAs" (PVar "x") (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patBindings") (EVar "p"))))
(DFunDef false "patBindings" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EVar "flatMap") (EVar "recFieldBindings")) (EVar "fields")))
(DFunDef false "patBindings" (PWild) (EListLit))
(DTypeSig false "recFieldBindings" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recFieldBindings" ((PCon "RecPatField" (PVar "fname") (PCon "None"))) (EListLit (EVar "fname")))
(DFunDef false "recFieldBindings" ((PCon "RecPatField" PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patBindings") (EVar "p")))
(DTypeSig false "localBoundExpr" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "localBoundExpr" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "patBindings")) (EVar "ps")) (EApp (EVar "localBoundExpr") (EVar "b"))))
(DFunDef false "localBoundExpr" ((PCon "ELet" PWild PWild (PVar "p") (PVar "e1") (PVar "e2"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EApp (EVar "localBoundExpr") (EVar "e1"))) (EApp (EVar "localBoundExpr") (EVar "e2"))))
(DFunDef false "localBoundExpr" ((PCon "ELetGroup" (PVar "bs") (PVar "e2"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "letBindBound")) (EVar "bs")) (EApp (EVar "localBoundExpr") (EVar "e2"))))
(DFunDef false "localBoundExpr" ((PCon "EMatch" (PVar "e0") (PVar "arms"))) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "e0")) (EApp (EApp (EVar "flatMap") (EVar "armBound")) (EVar "arms"))))
(DFunDef false "localBoundExpr" ((PCon "EApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "a")) (EApp (EVar "localBoundExpr") (EVar "b"))))
(DFunDef false "localBoundExpr" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "c")) (EApp (EVar "localBoundExpr") (EVar "t"))) (EApp (EVar "localBoundExpr") (EVar "el"))))
(DFunDef false "localBoundExpr" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "a")) (EApp (EVar "localBoundExpr") (EVar "b"))))
(DFunDef false "localBoundExpr" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EVar "localBoundExpr") (EVar "a")))
(DFunDef false "localBoundExpr" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "a")) (EApp (EVar "localBoundExpr") (EVar "b"))))
(DFunDef false "localBoundExpr" ((PCon "EFieldAccess" (PVar "e0") PWild PWild)) (EApp (EVar "localBoundExpr") (EVar "e0")))
(DFunDef false "localBoundExpr" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "flatMap") (EVar "fieldAssignBound")) (EVar "fs")))
(DFunDef false "localBoundExpr" ((PCon "ERecordUpdate" (PVar "e0") (PVar "fs") PWild)) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "e0")) (EApp (EApp (EVar "flatMap") (EVar "fieldAssignBound")) (EVar "fs"))))
(DFunDef false "localBoundExpr" ((PCon "EVariantUpdate" PWild (PVar "e0") (PVar "fs"))) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "e0")) (EApp (EApp (EVar "flatMap") (EVar "fieldAssignBound")) (EVar "fs"))))
(DFunDef false "localBoundExpr" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "localBoundExpr")) (EVar "es")))
(DFunDef false "localBoundExpr" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "localBoundExpr")) (EVar "es")))
(DFunDef false "localBoundExpr" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "localBoundExpr")) (EVar "es")))
(DFunDef false "localBoundExpr" ((PCon "EIndex" (PVar "e0") (PVar "i") PWild)) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "e0")) (EApp (EVar "localBoundExpr") (EVar "i"))))
(DFunDef false "localBoundExpr" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "lo")) (EApp (EVar "localBoundExpr") (EVar "hi"))))
(DFunDef false "localBoundExpr" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "lo")) (EApp (EVar "localBoundExpr") (EVar "hi"))))
(DFunDef false "localBoundExpr" ((PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "e0")) (EApp (EVar "localBoundExpr") (EVar "lo"))) (EApp (EVar "localBoundExpr") (EVar "hi"))))
(DFunDef false "localBoundExpr" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "doStmtBound")) (EVar "stmts")))
(DFunDef false "localBoundExpr" ((PCon "EDo" (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "doStmtBound")) (EVar "stmts")))
(DFunDef false "localBoundExpr" ((PCon "EAnnot" (PVar "e0") PWild)) (EApp (EVar "localBoundExpr") (EVar "e0")))
(DFunDef false "localBoundExpr" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "flatMap") (EVar "interpBound")) (EVar "parts")))
(DFunDef false "localBoundExpr" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "flatMap") (EVar "guardArmBound")) (EVar "arms")))
(DFunDef false "localBoundExpr" ((PCon "ESection" (PCon "SecRight" PWild (PVar "e0")))) (EApp (EVar "localBoundExpr") (EVar "e0")))
(DFunDef false "localBoundExpr" ((PCon "ESection" (PCon "SecLeft" (PVar "e0") PWild))) (EApp (EVar "localBoundExpr") (EVar "e0")))
(DFunDef false "localBoundExpr" ((PCon "EHeadAnnot" (PVar "e0") PWild)) (EApp (EVar "localBoundExpr") (EVar "e0")))
(DFunDef false "localBoundExpr" ((PCon "EAsPat" PWild (PVar "e0"))) (EApp (EVar "localBoundExpr") (EVar "e0")))
(DFunDef false "localBoundExpr" ((PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EVar "flatMap") (EVar "mapLitPairBound")) (EVar "kvs")))
(DFunDef false "localBoundExpr" ((PCon "ESetLit" PWild (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "localBoundExpr")) (EVar "es")))
(DFunDef false "localBoundExpr" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "localBoundExpr") (EVar "e")))
(DFunDef false "localBoundExpr" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "localBoundExpr") (EVar "e")))
(DFunDef false "localBoundExpr" (PWild) (EListLit))
(DTypeSig false "letBindBound" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "letBindBound" ((PCon "LetBind" PWild (PVar "clauses"))) (EApp (EApp (EVar "flatMap") (EVar "funClauseBound")) (EVar "clauses")))
(DTypeSig false "funClauseBound" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "funClauseBound" ((PCon "FunClause" (PVar "ps") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "patBindings")) (EVar "ps")) (EApp (EVar "localBoundExpr") (EVar "body"))))
(DTypeSig false "armBound" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "armBound" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EApp (EApp (EVar "flatMap") (EVar "guardBound")) (EVar "gs"))) (EApp (EVar "localBoundExpr") (EVar "body"))))
(DTypeSig false "guardBound" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "guardBound" ((PCon "GBool" (PVar "e"))) (EApp (EVar "localBoundExpr") (EVar "e")))
(DFunDef false "guardBound" ((PCon "GBind" (PVar "p") (PVar "e"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EApp (EVar "localBoundExpr") (EVar "e"))))
(DTypeSig false "guardArmBound" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "guardArmBound" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "guardBound")) (EVar "gs")) (EApp (EVar "localBoundExpr") (EVar "body"))))
(DTypeSig false "fieldAssignBound" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fieldAssignBound" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "localBoundExpr") (EVar "e")))
(DTypeSig false "doStmtBound" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "doStmtBound" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "localBoundExpr") (EVar "e")))
(DFunDef false "doStmtBound" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EApp (EVar "localBoundExpr") (EVar "e"))))
(DFunDef false "doStmtBound" ((PCon "DoLet" PWild PWild (PVar "p") (PVar "e"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EApp (EVar "localBoundExpr") (EVar "e"))))
(DFunDef false "doStmtBound" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "localBoundExpr") (EVar "e")))
(DFunDef false "doStmtBound" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "localBoundExpr") (EVar "e")))
(DTypeSig false "interpBound" (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "interpBound" ((PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "interpBound" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "localBoundExpr") (EVar "e")))
(DTypeSig false "mapLitPairBound" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "mapLitPairBound" ((PTuple (PVar "k") (PVar "v"))) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "k")) (EApp (EVar "localBoundExpr") (EVar "v"))))
(DTypeSig false "declLocalBound" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declLocalBound" ((PCon "DFunDef" PWild PWild (PVar "ps") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "patBindings")) (EVar "ps")) (EApp (EVar "localBoundExpr") (EVar "body"))))
(DFunDef false "declLocalBound" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declLocalBound") (EVar "d")))
(DFunDef false "declLocalBound" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EVar "flatMap") (EVar "letBindBound")) (EVar "binds")))
(DFunDef false "declLocalBound" ((PVar "d")) (EApp (EApp (EVar "flatMap") (EVar "localBoundExpr")) (EApp (EVar "declBodies") (EVar "d"))))
(DTypeSig true "localBoundNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "localBoundNames" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "declLocalBound")) (EVar "prog")))
(DTypeSig false "markWith" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "markWith" ((PVar "preludeMethods") (PVar "preludeDroppable") (PVar "preludeConstrained") (PVar "prog")) (EBlock (DoLet false false (PVar "prog2") (EApp (EApp (EVar "shadowRename") (EVar "preludeMethods")) (EVar "prog"))) (DoLet false false (PVar "methods") (EBinOp "++" (EVar "preludeMethods") (EApp (EVar "interfaceMethodNames") (EVar "prog2")))) (DoLet false false (PVar "shadowed") (EApp (EApp (EVar "keepIn") (EVar "preludeDroppable")) (EApp (EVar "userValueNames") (EVar "prog2")))) (DoLet false false (PVar "userConstrained") (EApp (EVar "constrainedFnNames") (EVar "prog2"))) (DoLet false false (PVar "toRemove") (EApp (EApp (EVar "keepNotIn") (EVar "userConstrained")) (EVar "shadowed"))) (DoLet false false (PVar "constrained") (EApp (EApp (EVar "keepNotIn") (EVar "toRemove")) (EBinOp "++" (EVar "preludeConstrained") (EVar "userConstrained")))) (DoExpr (EApp (EApp (EApp (EVar "markProgram") (EVar "methods")) (EVar "constrained")) (EVar "prog2")))))
(DTypeSig true "markWithPrelude" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "markWithPrelude" ((PVar "preludeProg") (PVar "prog")) (EApp (EApp (EApp (EApp (EVar "markWith") (EApp (EVar "interfaceMethodNames") (EVar "preludeProg"))) (EApp (EVar "droppablePreludeFns") (EVar "preludeProg"))) (EApp (EVar "constrainedFnNames") (EVar "preludeProg"))) (EVar "prog")))
(DTypeSig true "markerFor" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "markerFor" ((PVar "preludeProg")) (EBlock (DoLet false false (PVar "preludeMethods") (EApp (EVar "interfaceMethodNames") (EVar "preludeProg"))) (DoLet false false (PVar "preludeDroppable") (EApp (EVar "droppablePreludeFns") (EVar "preludeProg"))) (DoLet false false (PVar "preludeConstrained") (EApp (EVar "constrainedFnNames") (EVar "preludeProg"))) (DoExpr (ELam ((PVar "prog")) (EApp (EApp (EApp (EApp (EVar "markWith") (EVar "preludeMethods")) (EVar "preludeDroppable")) (EVar "preludeConstrained")) (EVar "prog"))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Ty" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Route" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapProg" false) (mem "mapExpr" false) (mem "mapDecl" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false))))
(DTypeSig false "interfaceMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "interfaceMethodNames" ((PList)) (EListLit))
(DFunDef false "interfaceMethodNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodName")) (EVar "methods")) (EApp (EVar "interfaceMethodNames") (EVar "rest"))))
(DFunDef false "interfaceMethodNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "interfaceMethodNames") (EVar "rest")))
(DTypeSig false "ifaceMethodName" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodName" ((PCon "IfaceMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "constrainedFnNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constrainedFnNames" ((PList)) (EListLit))
(DFunDef false "constrainedFnNames" ((PCons (PCon "DTypeSig" PWild (PVar "name") (PVar "ty")) (PVar "rest"))) (EApp (EApp (EApp (EVar "constrainedAdd") (EVar "name")) (EVar "ty")) (EApp (EVar "constrainedFnNames") (EVar "rest"))))
(DFunDef false "constrainedFnNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "constrainedFnNames") (EVar "rest")))
(DTypeSig false "constrainedAdd" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "constrainedAdd" ((PVar "name") (PCon "TyConstrained" PWild PWild) (PVar "acc")) (EBinOp "::" (EVar "name") (EVar "acc")))
(DFunDef false "constrainedAdd" (PWild PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "markNode" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "markNode" ((PVar "methods") (PVar "constrained") (PCon "EVar" (PVar "x"))) (EApp (EApp (EApp (EVar "markVar") (EVar "methods")) (EVar "constrained")) (EVar "x")))
(DFunDef false "markNode" ((PVar "methods") (PVar "constrained") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "markInfix") (EVar "methods")) (EVar "constrained")) (EVar "op")) (EVar "l")) (EVar "r")))
(DFunDef false "markNode" (PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "markVar" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Expr")))))
(DFunDef false "markVar" ((PVar "methods") (PVar "constrained") (PVar "x")) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "methods")) (EApp (EVar "EMethodRef") (EVar "x")) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "constrained")) (EApp (EVar "EDictApp") (EVar "x")) (EIf (EVar "otherwise") (EApp (EVar "EVar") (EVar "x")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "markInfix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))))
(DFunDef false "markInfix" ((PVar "methods") (PVar "constrained") (PVar "op") (PVar "l") (PVar "r")) (EIf (EApp (EApp (EVar "contains") (EVar "op")) (EVar "methods")) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EMethodRef") (EVar "op"))) (EVar "l"))) (EVar "r")) (EIf (EApp (EApp (EVar "contains") (EVar "op")) (EVar "constrained")) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EDictApp") (EVar "op"))) (EVar "l"))) (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "markProgram" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "markProgram" ((PVar "methods") (PVar "constrained") (PVar "prog")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "markDecl") (EVar "methods")) (EVar "constrained"))) (EVar "prog")))
(DTypeSig false "markDecl" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Decl")))))
(DFunDef false "markDecl" ((PVar "methods") (PVar "constrained") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EBlock (DoLet false false (PVar "f") (EApp (EApp (EVar "markNode") (EVar "methods")) (EVar "constrained"))) (DoExpr (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EMethodRef "map") (EApp (EVar "markLetBind") (EVar "f"))) (EVar "binds"))))))
(DFunDef false "markDecl" ((PVar "methods") (PVar "constrained") (PCon "DAttrib" (PVar "attrs") (PVar "inner"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EApp (EVar "markDecl") (EVar "methods")) (EVar "constrained")) (EVar "inner"))))
(DFunDef false "markDecl" ((PVar "methods") (PVar "constrained") (PVar "d")) (EApp (EApp (EVar "mapDecl") (EApp (EApp (EVar "markNode") (EVar "methods")) (EVar "constrained"))) (EVar "d")))
(DTypeSig false "markLetBind" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "markLetBind" ((PVar "f") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "markFunClause") (EVar "f"))) (EVar "clauses"))))
(DTypeSig false "markFunClause" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "markFunClause" ((PVar "f") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "pats")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "body"))))
(DTypeSig false "shadowRename" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "shadowRename" ((PVar "preludeMethods") (PVar "prog")) (EApp (EApp (EVar "applyRenames") (EApp (EApp (EVar "shadowRenames") (EVar "preludeMethods")) (EVar "prog"))) (EVar "prog")))
(DTypeSig false "shadowRenames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "shadowRenames" ((PVar "preludeMethods") (PVar "prog")) (EApp (EApp (EVar "keepNotIn") (EApp (EVar "localBoundNames") (EVar "prog"))) (EApp (EApp (EVar "keepIn") (EVar "preludeMethods")) (EApp (EVar "userValueNames") (EVar "prog")))))
(DTypeSig false "userValueNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "userValueNames" ((PList)) (EListLit))
(DFunDef false "userValueNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "userValueNames") (EVar "rest")))
(DTypeSig false "keepIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "keepIn" (PWild (PList)) (EListLit))
(DFunDef false "keepIn" ((PVar "pool") (PCons (PVar "x") (PVar "xs"))) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "pool")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "keepIn") (EVar "pool")) (EVar "xs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "keepIn") (EVar "pool")) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyRenames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "applyRenames" ((PList) (PVar "prog")) (EVar "prog"))
(DFunDef false "applyRenames" ((PVar "renames") (PVar "prog")) (EApp (EApp (EMethodRef "map") (EApp (EVar "renameDecl") (EVar "renames"))) (EVar "prog")))
(DTypeSig false "renameDecl" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "renameDecl" ((PVar "renames") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EApp (EApp (EVar "subName") (EVar "renames")) (EVar "n"))) (EVar "ps")) (EApp (EApp (EVar "mapExpr") (EApp (EVar "renameVar") (EVar "renames"))) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "renames") (PCon "DTypeSig" (PVar "pub") (PVar "n") (PVar "t"))) (EApp (EApp (EApp (EVar "DTypeSig") (EVar "pub")) (EApp (EApp (EVar "subName") (EVar "renames")) (EVar "n"))) (EVar "t")))
(DFunDef false "renameDecl" ((PVar "renames") (PVar "d")) (EApp (EApp (EVar "mapDecl") (EApp (EVar "renameVar") (EVar "renames"))) (EVar "d")))
(DTypeSig false "renameVar" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "renameVar" ((PVar "renames") (PCon "EVar" (PVar "x"))) (EApp (EVar "EVar") (EApp (EApp (EVar "subName") (EVar "renames")) (EVar "x"))))
(DFunDef false "renameVar" ((PVar "renames") (PCon "EMethodRef" (PVar "x"))) (EApp (EVar "EMethodRef") (EApp (EApp (EVar "subName") (EVar "renames")) (EVar "x"))))
(DFunDef false "renameVar" ((PVar "renames") (PCon "EDictApp" (PVar "x"))) (EApp (EVar "EDictApp") (EApp (EApp (EVar "subName") (EVar "renames")) (EVar "x"))))
(DFunDef false "renameVar" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "subName" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "subName" ((PVar "renames") (PVar "x")) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "renames")) (EBinOp "++" (EVar "x") (ELit (LString "#shadow"))) (EIf (EVar "otherwise") (EVar "x") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "preludePlainFnNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "preludePlainFnNames" ((PVar "prelude")) (EApp (EApp (EVar "keepNotIn") (EApp (EVar "interfaceMethodNames") (EVar "prelude"))) (EApp (EVar "allFunDefNames") (EVar "prelude"))))
(DTypeSig false "allFunDefNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "allFunDefNames" ((PList)) (EListLit))
(DFunDef false "allFunDefNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "allFunDefNames") (EVar "rest"))))
(DFunDef false "allFunDefNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "allFunDefNames") (EVar "rest")))
(DTypeSig false "keepNotIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "keepNotIn" (PWild (PList)) (EListLit))
(DFunDef false "keepNotIn" ((PVar "pool") (PCons (PVar "x") (PVar "xs"))) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "pool")) (EApp (EApp (EVar "keepNotIn") (EVar "pool")) (EVar "xs")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "keepNotIn") (EVar "pool")) (EVar "xs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "droppablePreludeFns" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "droppablePreludeFns" ((PVar "prelude")) (EApp (EApp (EVar "keepNotIn") (EApp (EVar "externalRefs") (EVar "prelude"))) (EApp (EVar "preludePlainFnNames") (EVar "prelude"))))
(DTypeSig false "externalRefs" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "externalRefs" ((PVar "prelude")) (EApp (EApp (EDictApp "flatMap") (EVar "declExternalRefs")) (EVar "prelude")))
(DTypeSig false "declExternalRefs" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declExternalRefs" ((PVar "d")) (EApp (EApp (EVar "keepNotIn") (EApp (EVar "declDefines") (EVar "d"))) (EApp (EVar "declRefs") (EVar "d"))))
(DTypeSig false "declDefines" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declDefines" ((PCon "DFunDef" PWild (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "declDefines" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (EVar "implMethodNameOf")) (EVar "methods")))
(DFunDef false "declDefines" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodName")) (EVar "methods")))
(DFunDef false "declDefines" (PWild) (EListLit))
(DTypeSig false "implMethodNameOf" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodNameOf" ((PCon "ImplMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig true "declRefs" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declRefs" ((PVar "d")) (EApp (EApp (EDictApp "flatMap") (EVar "collectVars")) (EApp (EVar "declBodies") (EVar "d"))))
(DTypeSig true "declBodies" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "declBodies" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EListLit (EVar "body")))
(DFunDef false "declBodies" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (EVar "implMethodBody")) (EVar "methods")))
(DFunDef false "declBodies" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EVar "ifaceMethodBodies")) (EVar "methods")))
(DFunDef false "declBodies" ((PCon "DProp" PWild PWild PWild (PVar "body"))) (EListLit (EVar "body")))
(DFunDef false "declBodies" ((PCon "DTest" PWild PWild (PVar "body"))) (EListLit (EVar "body")))
(DFunDef false "declBodies" ((PCon "DBench" PWild PWild (PVar "body"))) (EListLit (EVar "body")))
(DFunDef false "declBodies" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declBodies") (EVar "d")))
(DFunDef false "declBodies" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EDictApp "flatMap") (EVar "letBindBodies")) (EVar "binds")))
(DFunDef false "declBodies" (PWild) (EListLit))
(DTypeSig false "letBindBodies" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "letBindBodies" ((PCon "LetBind" PWild (PVar "clauses"))) (EApp (EApp (EMethodRef "map") (EVar "funClauseBody")) (EVar "clauses")))
(DTypeSig false "funClauseBody" (TyFun (TyCon "FunClause") (TyCon "Expr")))
(DFunDef false "funClauseBody" ((PCon "FunClause" PWild (PVar "body"))) (EVar "body"))
(DTypeSig false "implMethodBody" (TyFun (TyCon "ImplMethod") (TyCon "Expr")))
(DFunDef false "implMethodBody" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EVar "body"))
(DTypeSig false "ifaceMethodBodies" (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "ifaceMethodBodies" ((PCon "IfaceMethod" PWild PWild (PCon "Some" (PCon "MethodDefault" PWild (PVar "body"))))) (EListLit (EVar "body")))
(DFunDef false "ifaceMethodBodies" ((PCon "IfaceMethod" PWild PWild (PCon "None"))) (EListLit))
(DTypeSig false "collectVars" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectVars" ((PCon "EVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "collectVars" ((PCon "EMethodRef" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "collectVars" ((PCon "EDictApp" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "collectVars" ((PCon "EApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "collectVars") (EVar "a")) (EApp (EVar "collectVars") (EVar "b"))))
(DFunDef false "collectVars" ((PCon "ELam" PWild (PVar "b"))) (EApp (EVar "collectVars") (EVar "b")))
(DFunDef false "collectVars" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EBinOp "++" (EApp (EVar "collectVars") (EVar "e1")) (EApp (EVar "collectVars") (EVar "e2"))))
(DFunDef false "collectVars" ((PCon "ELetGroup" (PVar "bs") (PVar "e2"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "letBindVars")) (EVar "bs")) (EApp (EVar "collectVars") (EVar "e2"))))
(DFunDef false "collectVars" ((PCon "EMatch" (PVar "e0") (PVar "arms"))) (EBinOp "++" (EApp (EVar "collectVars") (EVar "e0")) (EApp (EApp (EDictApp "flatMap") (EVar "armVars")) (EVar "arms"))))
(DFunDef false "collectVars" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectVars") (EVar "c")) (EApp (EVar "collectVars") (EVar "t"))) (EApp (EVar "collectVars") (EVar "el"))))
(DFunDef false "collectVars" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectVars") (EVar "a")) (EApp (EVar "collectVars") (EVar "b"))))
(DFunDef false "collectVars" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EVar "collectVars") (EVar "a")))
(DFunDef false "collectVars" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EBinOp "::" (EVar "op") (EBinOp "++" (EApp (EVar "collectVars") (EVar "a")) (EApp (EVar "collectVars") (EVar "b")))))
(DFunDef false "collectVars" ((PCon "EFieldAccess" (PVar "e0") PWild PWild)) (EApp (EVar "collectVars") (EVar "e0")))
(DFunDef false "collectVars" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EDictApp "flatMap") (EVar "fieldAssignVars")) (EVar "fs")))
(DFunDef false "collectVars" ((PCon "ERecordUpdate" (PVar "e0") (PVar "fs") PWild)) (EBinOp "++" (EApp (EVar "collectVars") (EVar "e0")) (EApp (EApp (EDictApp "flatMap") (EVar "fieldAssignVars")) (EVar "fs"))))
(DFunDef false "collectVars" ((PCon "EVariantUpdate" PWild (PVar "e0") (PVar "fs"))) (EBinOp "++" (EApp (EVar "collectVars") (EVar "e0")) (EApp (EApp (EDictApp "flatMap") (EVar "fieldAssignVars")) (EVar "fs"))))
(DFunDef false "collectVars" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "collectVars")) (EVar "es")))
(DFunDef false "collectVars" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "collectVars")) (EVar "es")))
(DFunDef false "collectVars" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "collectVars")) (EVar "es")))
(DFunDef false "collectVars" ((PCon "EIndex" (PVar "e0") (PVar "i") PWild)) (EBinOp "++" (EApp (EVar "collectVars") (EVar "e0")) (EApp (EVar "collectVars") (EVar "i"))))
(DFunDef false "collectVars" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "collectVars") (EVar "lo")) (EApp (EVar "collectVars") (EVar "hi"))))
(DFunDef false "collectVars" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "collectVars") (EVar "lo")) (EApp (EVar "collectVars") (EVar "hi"))))
(DFunDef false "collectVars" ((PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectVars") (EVar "e0")) (EApp (EVar "collectVars") (EVar "lo"))) (EApp (EVar "collectVars") (EVar "hi"))))
(DFunDef false "collectVars" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "doStmtVars")) (EVar "stmts")))
(DFunDef false "collectVars" ((PCon "EDo" (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "doStmtVars")) (EVar "stmts")))
(DFunDef false "collectVars" ((PCon "EAnnot" (PVar "e0") PWild)) (EApp (EVar "collectVars") (EVar "e0")))
(DFunDef false "collectVars" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EDictApp "flatMap") (EVar "interpVars")) (EVar "parts")))
(DFunDef false "collectVars" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EDictApp "flatMap") (EVar "guardArmVars")) (EVar "arms")))
(DFunDef false "collectVars" ((PCon "ESection" (PCon "SecRight" PWild (PVar "e0")))) (EApp (EVar "collectVars") (EVar "e0")))
(DFunDef false "collectVars" ((PCon "ESection" (PCon "SecLeft" (PVar "e0") PWild))) (EApp (EVar "collectVars") (EVar "e0")))
(DFunDef false "collectVars" ((PCon "EVarAt" (PVar "x") PWild)) (EListLit (EVar "x")))
(DFunDef false "collectVars" ((PCon "EMethodAt" (PVar "x") (PVar "routeRef") PWild PWild)) (EBinOp "::" (EVar "x") (EApp (EVar "routeExtraRefs") (EFieldAccess (EVar "routeRef") "value"))))
(DFunDef false "collectVars" ((PCon "EDictAt" (PVar "x") PWild)) (EListLit (EVar "x")))
(DFunDef false "collectVars" ((PCon "EHeadAnnot" (PVar "e0") PWild)) (EApp (EVar "collectVars") (EVar "e0")))
(DFunDef false "collectVars" ((PCon "EAsPat" PWild (PVar "e0"))) (EApp (EVar "collectVars") (EVar "e0")))
(DFunDef false "collectVars" ((PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EDictApp "flatMap") (EVar "mapLitPairVars")) (EVar "kvs")))
(DFunDef false "collectVars" ((PCon "ESetLit" PWild (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "collectVars")) (EVar "es")))
(DFunDef false "collectVars" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DFunDef false "collectVars" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DFunDef false "collectVars" (PWild) (EListLit))
(DTypeSig false "routeExtraRefs" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "routeExtraRefs" ((PCon "RLocal" (PLit (LString "")))) (EListLit))
(DFunDef false "routeExtraRefs" ((PCon "RLocal" (PVar "s"))) (EListLit (EVar "s")))
(DFunDef false "routeExtraRefs" (PWild) (EListLit))
(DTypeSig false "letBindVars" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "letBindVars" ((PCon "LetBind" PWild (PVar "clauses"))) (EApp (EApp (EDictApp "flatMap") (EVar "funClauseVars")) (EVar "clauses")))
(DTypeSig false "funClauseVars" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "funClauseVars" ((PCon "FunClause" PWild (PVar "body"))) (EApp (EVar "collectVars") (EVar "body")))
(DTypeSig false "armVars" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "armVars" ((PCon "Arm" PWild (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "guardVars")) (EVar "gs")) (EApp (EVar "collectVars") (EVar "body"))))
(DTypeSig false "guardVars" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "guardVars" ((PCon "GBool" (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DFunDef false "guardVars" ((PCon "GBind" PWild (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DTypeSig false "guardArmVars" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "guardArmVars" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "guardVars")) (EVar "gs")) (EApp (EVar "collectVars") (EVar "body"))))
(DTypeSig false "fieldAssignVars" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fieldAssignVars" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DTypeSig false "doStmtVars" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "doStmtVars" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DFunDef false "doStmtVars" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DFunDef false "doStmtVars" ((PCon "DoLet" PWild PWild PWild (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DFunDef false "doStmtVars" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DFunDef false "doStmtVars" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DTypeSig false "interpVars" (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "interpVars" ((PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "interpVars" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "collectVars") (EVar "e")))
(DTypeSig false "mapLitPairVars" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "mapLitPairVars" ((PTuple (PVar "k") (PVar "v"))) (EBinOp "++" (EApp (EVar "collectVars") (EVar "k")) (EApp (EVar "collectVars") (EVar "v"))))
(DTypeSig false "patBindings" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patBindings" ((PCon "PVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "patBindings" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "a")) (EApp (EVar "patBindings") (EVar "b"))))
(DFunDef false "patBindings" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PAs" (PVar "x") (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patBindings") (EVar "p"))))
(DFunDef false "patBindings" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "recFieldBindings")) (EVar "fields")))
(DFunDef false "patBindings" (PWild) (EListLit))
(DTypeSig false "recFieldBindings" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recFieldBindings" ((PCon "RecPatField" (PVar "fname") (PCon "None"))) (EListLit (EVar "fname")))
(DFunDef false "recFieldBindings" ((PCon "RecPatField" PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patBindings") (EVar "p")))
(DTypeSig false "localBoundExpr" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "localBoundExpr" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "patBindings")) (EVar "ps")) (EApp (EVar "localBoundExpr") (EVar "b"))))
(DFunDef false "localBoundExpr" ((PCon "ELet" PWild PWild (PVar "p") (PVar "e1") (PVar "e2"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EApp (EVar "localBoundExpr") (EVar "e1"))) (EApp (EVar "localBoundExpr") (EVar "e2"))))
(DFunDef false "localBoundExpr" ((PCon "ELetGroup" (PVar "bs") (PVar "e2"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "letBindBound")) (EVar "bs")) (EApp (EVar "localBoundExpr") (EVar "e2"))))
(DFunDef false "localBoundExpr" ((PCon "EMatch" (PVar "e0") (PVar "arms"))) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "e0")) (EApp (EApp (EDictApp "flatMap") (EVar "armBound")) (EVar "arms"))))
(DFunDef false "localBoundExpr" ((PCon "EApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "a")) (EApp (EVar "localBoundExpr") (EVar "b"))))
(DFunDef false "localBoundExpr" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "c")) (EApp (EVar "localBoundExpr") (EVar "t"))) (EApp (EVar "localBoundExpr") (EVar "el"))))
(DFunDef false "localBoundExpr" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "a")) (EApp (EVar "localBoundExpr") (EVar "b"))))
(DFunDef false "localBoundExpr" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EVar "localBoundExpr") (EVar "a")))
(DFunDef false "localBoundExpr" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "a")) (EApp (EVar "localBoundExpr") (EVar "b"))))
(DFunDef false "localBoundExpr" ((PCon "EFieldAccess" (PVar "e0") PWild PWild)) (EApp (EVar "localBoundExpr") (EVar "e0")))
(DFunDef false "localBoundExpr" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EDictApp "flatMap") (EVar "fieldAssignBound")) (EVar "fs")))
(DFunDef false "localBoundExpr" ((PCon "ERecordUpdate" (PVar "e0") (PVar "fs") PWild)) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "e0")) (EApp (EApp (EDictApp "flatMap") (EVar "fieldAssignBound")) (EVar "fs"))))
(DFunDef false "localBoundExpr" ((PCon "EVariantUpdate" PWild (PVar "e0") (PVar "fs"))) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "e0")) (EApp (EApp (EDictApp "flatMap") (EVar "fieldAssignBound")) (EVar "fs"))))
(DFunDef false "localBoundExpr" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "localBoundExpr")) (EVar "es")))
(DFunDef false "localBoundExpr" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "localBoundExpr")) (EVar "es")))
(DFunDef false "localBoundExpr" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "localBoundExpr")) (EVar "es")))
(DFunDef false "localBoundExpr" ((PCon "EIndex" (PVar "e0") (PVar "i") PWild)) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "e0")) (EApp (EVar "localBoundExpr") (EVar "i"))))
(DFunDef false "localBoundExpr" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "lo")) (EApp (EVar "localBoundExpr") (EVar "hi"))))
(DFunDef false "localBoundExpr" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "lo")) (EApp (EVar "localBoundExpr") (EVar "hi"))))
(DFunDef false "localBoundExpr" ((PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "e0")) (EApp (EVar "localBoundExpr") (EVar "lo"))) (EApp (EVar "localBoundExpr") (EVar "hi"))))
(DFunDef false "localBoundExpr" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "doStmtBound")) (EVar "stmts")))
(DFunDef false "localBoundExpr" ((PCon "EDo" (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "doStmtBound")) (EVar "stmts")))
(DFunDef false "localBoundExpr" ((PCon "EAnnot" (PVar "e0") PWild)) (EApp (EVar "localBoundExpr") (EVar "e0")))
(DFunDef false "localBoundExpr" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EDictApp "flatMap") (EVar "interpBound")) (EVar "parts")))
(DFunDef false "localBoundExpr" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EDictApp "flatMap") (EVar "guardArmBound")) (EVar "arms")))
(DFunDef false "localBoundExpr" ((PCon "ESection" (PCon "SecRight" PWild (PVar "e0")))) (EApp (EVar "localBoundExpr") (EVar "e0")))
(DFunDef false "localBoundExpr" ((PCon "ESection" (PCon "SecLeft" (PVar "e0") PWild))) (EApp (EVar "localBoundExpr") (EVar "e0")))
(DFunDef false "localBoundExpr" ((PCon "EHeadAnnot" (PVar "e0") PWild)) (EApp (EVar "localBoundExpr") (EVar "e0")))
(DFunDef false "localBoundExpr" ((PCon "EAsPat" PWild (PVar "e0"))) (EApp (EVar "localBoundExpr") (EVar "e0")))
(DFunDef false "localBoundExpr" ((PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EDictApp "flatMap") (EVar "mapLitPairBound")) (EVar "kvs")))
(DFunDef false "localBoundExpr" ((PCon "ESetLit" PWild (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "localBoundExpr")) (EVar "es")))
(DFunDef false "localBoundExpr" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "localBoundExpr") (EVar "e")))
(DFunDef false "localBoundExpr" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "localBoundExpr") (EVar "e")))
(DFunDef false "localBoundExpr" (PWild) (EListLit))
(DTypeSig false "letBindBound" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "letBindBound" ((PCon "LetBind" PWild (PVar "clauses"))) (EApp (EApp (EDictApp "flatMap") (EVar "funClauseBound")) (EVar "clauses")))
(DTypeSig false "funClauseBound" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "funClauseBound" ((PCon "FunClause" (PVar "ps") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "patBindings")) (EVar "ps")) (EApp (EVar "localBoundExpr") (EVar "body"))))
(DTypeSig false "armBound" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "armBound" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EApp (EApp (EDictApp "flatMap") (EVar "guardBound")) (EVar "gs"))) (EApp (EVar "localBoundExpr") (EVar "body"))))
(DTypeSig false "guardBound" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "guardBound" ((PCon "GBool" (PVar "e"))) (EApp (EVar "localBoundExpr") (EVar "e")))
(DFunDef false "guardBound" ((PCon "GBind" (PVar "p") (PVar "e"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EApp (EVar "localBoundExpr") (EVar "e"))))
(DTypeSig false "guardArmBound" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "guardArmBound" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "guardBound")) (EVar "gs")) (EApp (EVar "localBoundExpr") (EVar "body"))))
(DTypeSig false "fieldAssignBound" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fieldAssignBound" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "localBoundExpr") (EVar "e")))
(DTypeSig false "doStmtBound" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "doStmtBound" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "localBoundExpr") (EVar "e")))
(DFunDef false "doStmtBound" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EApp (EVar "localBoundExpr") (EVar "e"))))
(DFunDef false "doStmtBound" ((PCon "DoLet" PWild PWild (PVar "p") (PVar "e"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EApp (EVar "localBoundExpr") (EVar "e"))))
(DFunDef false "doStmtBound" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "localBoundExpr") (EVar "e")))
(DFunDef false "doStmtBound" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "localBoundExpr") (EVar "e")))
(DTypeSig false "interpBound" (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "interpBound" ((PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "interpBound" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "localBoundExpr") (EVar "e")))
(DTypeSig false "mapLitPairBound" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "mapLitPairBound" ((PTuple (PVar "k") (PVar "v"))) (EBinOp "++" (EApp (EVar "localBoundExpr") (EVar "k")) (EApp (EVar "localBoundExpr") (EVar "v"))))
(DTypeSig false "declLocalBound" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declLocalBound" ((PCon "DFunDef" PWild PWild (PVar "ps") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "patBindings")) (EVar "ps")) (EApp (EVar "localBoundExpr") (EVar "body"))))
(DFunDef false "declLocalBound" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declLocalBound") (EVar "d")))
(DFunDef false "declLocalBound" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EDictApp "flatMap") (EVar "letBindBound")) (EVar "binds")))
(DFunDef false "declLocalBound" ((PVar "d")) (EApp (EApp (EDictApp "flatMap") (EVar "localBoundExpr")) (EApp (EVar "declBodies") (EVar "d"))))
(DTypeSig true "localBoundNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "localBoundNames" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "declLocalBound")) (EVar "prog")))
(DTypeSig false "markWith" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "markWith" ((PVar "preludeMethods") (PVar "preludeDroppable") (PVar "preludeConstrained") (PVar "prog")) (EBlock (DoLet false false (PVar "prog2") (EApp (EApp (EVar "shadowRename") (EVar "preludeMethods")) (EVar "prog"))) (DoLet false false (PVar "methods") (EBinOp "++" (EVar "preludeMethods") (EApp (EVar "interfaceMethodNames") (EVar "prog2")))) (DoLet false false (PVar "shadowed") (EApp (EApp (EVar "keepIn") (EVar "preludeDroppable")) (EApp (EVar "userValueNames") (EVar "prog2")))) (DoLet false false (PVar "userConstrained") (EApp (EVar "constrainedFnNames") (EVar "prog2"))) (DoLet false false (PVar "toRemove") (EApp (EApp (EVar "keepNotIn") (EVar "userConstrained")) (EVar "shadowed"))) (DoLet false false (PVar "constrained") (EApp (EApp (EVar "keepNotIn") (EVar "toRemove")) (EBinOp "++" (EVar "preludeConstrained") (EVar "userConstrained")))) (DoExpr (EApp (EApp (EApp (EVar "markProgram") (EVar "methods")) (EVar "constrained")) (EVar "prog2")))))
(DTypeSig true "markWithPrelude" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "markWithPrelude" ((PVar "preludeProg") (PVar "prog")) (EApp (EApp (EApp (EApp (EVar "markWith") (EApp (EVar "interfaceMethodNames") (EVar "preludeProg"))) (EApp (EVar "droppablePreludeFns") (EVar "preludeProg"))) (EApp (EVar "constrainedFnNames") (EVar "preludeProg"))) (EVar "prog")))
(DTypeSig true "markerFor" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "markerFor" ((PVar "preludeProg")) (EBlock (DoLet false false (PVar "preludeMethods") (EApp (EVar "interfaceMethodNames") (EVar "preludeProg"))) (DoLet false false (PVar "preludeDroppable") (EApp (EVar "droppablePreludeFns") (EVar "preludeProg"))) (DoLet false false (PVar "preludeConstrained") (EApp (EVar "constrainedFnNames") (EVar "preludeProg"))) (DoExpr (ELam ((PVar "prog")) (EApp (EApp (EApp (EApp (EVar "markWith") (EVar "preludeMethods")) (EVar "preludeDroppable")) (EVar "preludeConstrained")) (EVar "prog"))))))
