# META
source_lines=301
stages=DESUGAR,MARK
# SOURCE
-- annotate.mdk — Lexical-addressing EMISSION pass (STAGE2-DESIGN §2.0).
--
-- Extracted into its own lean module (imports only ast + util) so the eval
-- drivers can consume it without pulling all of resolve.mdk into their load
-- closure.  Rewrites every variable REFERENCE `EVar n` → `EVarAt n addr`, where
-- `addr` is the (frame, slot) position the slot-indexing eval reads.  The pass
-- is pure AST→AST and runs right before eval (after marker + typecheck
-- elaboration), so it sees `EMethodRef`/`EMethodAt`/`EDictApp`/`EDictAt` already
-- in place and leaves them untouched (passthrough).
--
-- The frame model mirrors `eval.mdk`'s `EvalEnv (List (List (String, Ref
-- Value)))` EXACTLY, so the emitted address is the one a slot-indexing lookup
-- would need:
--   * applyClosure CURRIES — one frame PER parameter, innermost = last param;
--   * a let-rec `let f = …`  pushes one frame `[f]` over both RHS and body;
--   * a non-rec let / match-arm pattern / do-let pushes one frame of the
--     pattern's bindings (even an empty frame for `_`, which still counts for
--     depth — eval `extendEnv env []` pushes an empty frame);
--   * each match-arm `GBind` guard pushes a further frame; `GBool` pushes none;
--   * an `ELetGroup` pushes one frame of all the group names;
--   * `DoAssign x` pushes a frame `[x]` (eval re-extends for reassignment).
-- Slot order within a frame = `patBindings` order, which is byte-identical to
-- the order `matchPat` accumulates binds (`b ++ bs` / `x :: binds`).
-- A name found in no local frame is `AGlobal` (top-level / prelude / extern):
-- eval resolves it by name, so no slot applies.  An `@Impl` hint stays a plain
-- `EVar` (eval short-circuits it to `VUnit`, it is not a variable lookup).
--
-- NOTE for the consumer: this pass does the PLAIN lexical resolution only.  The
-- Phase-112 `lookup_method` shadow-bypass is a CONSUMER concern — for the
-- self-hosted eval that reduces to: AGlobal stays a by-name scan (`lookupEnv`),
-- which already reaches a global method's VMulti past any local frame.

import frontend.ast.{
  Lit(..),
  Ty(..),
  Constraint(..),
  Addr(..),
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
import support.util.{reverseL}

-- ── self-contained helper copies (resolve.mdk keeps its own for its main pass) ─
patBindings : Pat -> List String
patBindings (PVar x) = [x]
patBindings PWild = []
patBindings (PLit _) = []
patBindings (PCon _ ps) = flatMap patBindings ps
patBindings (PCons a b) = patBindings a ++ patBindings b
patBindings (PTuple ps) = flatMap patBindings ps
patBindings (PList ps) = flatMap patBindings ps
patBindings (PAs x p) = x :: patBindings p
patBindings (PRng _ _ _) = []
patBindings (PRec _ fields _) = flatMap recFieldBindings fields

recFieldBindings : RecPatField -> List String
recFieldBindings (RecPatField fname None) = [fname]
recFieldBindings (RecPatField _ (Some p)) = patBindings p

startsWithAt : Array Char -> Bool
-- Intentional cross-file duplicate of the same helper in resolve.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
startsWithAt cs = arrayLength cs > 0 && arrayGetUnsafe 0 cs == '@'

isHint : String -> Bool
isHint n = startsWithAt (stringToChars n)

letBindName : LetBind -> String
letBindName (LetBind n _) = n

propParamName : PropParam -> String
propParamName (PropParam x _) = x

-- ── framed scope (innermost frame first; each frame its names in slot order) ──
-- per-parameter frames for a closure's params: applyClosure pushes one frame per
-- param, innermost = last, so reverse the left-to-right per-param binding lists
paramFrames : List Pat -> List (List String)
paramFrames pats = reverseL (map patBindings pats)

slotIn : List String -> String -> Int -> Option Int
slotIn [] _ _ = None
slotIn (m::rest) n i
  | m == n = Some i
  | otherwise = slotIn rest n (i + 1)

addrOf : List (List String) -> String -> Addr
addrOf frames n = addrOfGo frames n 0

addrOfGo : List (List String) -> String -> Int -> Addr
addrOfGo [] _ _ = AGlobal
addrOfGo (frame::rest) n depth = match slotIn frame n 0
  Some slot => ALocal depth slot
  None => addrOfGo rest n (depth + 1)

-- ── annotateExpr (scope = framed lexical environment) ─────────────────────
annotateExpr : List (List String) -> Expr -> Expr
annotateExpr _ (ELit l) = ELit l
annotateExpr _ (ENumLit n r d) = ENumLit n r d  -- PLAN.md #11: leaf, passthrough
annotateExpr _ (EMethodRef m) = EMethodRef m
annotateExpr _ (EDictApp d) = EDictApp d
annotateExpr _ (EMethodAt name r ir mr) = EMethodAt name r ir mr
annotateExpr _ (EDictAt name r) = EDictAt name r
annotateExpr _ (EVarAt n a) = EVarAt n a
annotateExpr fr (EVar n)
  | isHint n = EVar n
  | otherwise = EVarAt n (addrOf fr n)
annotateExpr fr (EApp f x) = EApp (annotateExpr fr f) (annotateExpr fr x)
annotateExpr fr (ELam pats body) =
  ELam pats (annotateExpr (paramFrames pats ++ fr) body)
annotateExpr fr (ELet m isRec pat e1 e2) = annotateLet fr m isRec pat e1 e2
annotateExpr fr (ELetGroup binds body) = annotateLetGroup fr binds body
annotateExpr fr (EMatch e0 arms) =
  EMatch (annotateExpr fr e0) (map (annotateArm fr) arms)
annotateExpr fr (EIf c t el) =
  EIf (annotateExpr fr c) (annotateExpr fr t) (annotateExpr fr el)
annotateExpr fr (EBinOp op a b r) =
  EBinOp op (annotateExpr fr a) (annotateExpr fr b) r
annotateExpr fr (EUnOp op a r) = EUnOp op (annotateExpr fr a) r
annotateExpr fr (EInfix op a b) =
  EInfix op (annotateExpr fr a) (annotateExpr fr b)
annotateExpr fr (EFieldAccess e0 f r) = EFieldAccess (annotateExpr fr e0) f r
annotateExpr fr (ETuple es) = ETuple (map (annotateExpr fr) es)
annotateExpr fr (EListLit es) = EListLit (map (annotateExpr fr) es)
annotateExpr fr (EArrayLit es) = EArrayLit (map (annotateExpr fr) es)
annotateExpr fr (ERangeList lo hi incl) =
  ERangeList (annotateExpr fr lo) (annotateExpr fr hi) incl
annotateExpr fr (ERangeArray lo hi incl) =
  ERangeArray (annotateExpr fr lo) (annotateExpr fr hi) incl
annotateExpr fr (ESlice e0 lo hi incl r) =
  ESlice (annotateExpr fr e0) (annotateExpr fr lo) (annotateExpr fr hi) incl r
annotateExpr fr (EIndex e0 i r) =
  EIndex (annotateExpr fr e0) (annotateExpr fr i) r
annotateExpr fr (EAnnot e0 t) = EAnnot (annotateExpr fr e0) t
annotateExpr fr (EHeadAnnot e0 t) = EHeadAnnot (annotateExpr fr e0) t
annotateExpr fr (EBlock stmts) = EBlock (annotateStmts fr stmts)
annotateExpr fr (EDo stmts) = EDo (annotateStmts fr stmts)
annotateExpr fr (EStringInterp parts) =
  EStringInterp (map (annotateInterp fr) parts)
annotateExpr fr (EGuards arms) = EGuards (map (annotateGuardArm fr) arms)
annotateExpr fr (ERecordCreate name fs) =
  ERecordCreate name (map (annotateFieldAssign fr) fs)
annotateExpr fr (ERecordUpdate e0 fs r) =
  ERecordUpdate (annotateExpr fr e0) (map (annotateFieldAssign fr) fs) r
annotateExpr fr (EVariantUpdate con e0 fs) =
  EVariantUpdate con (annotateExpr fr e0) (map (annotateFieldAssign fr) fs)
annotateExpr fr (EMapLit n kvs) = EMapLit n (map (annotateKv fr) kvs)
annotateExpr fr (ESetLit n es) = ESetLit n (map (annotateExpr fr) es)
annotateExpr fr (EAsPat x e0) = EAsPat x (annotateExpr fr e0)
annotateExpr fr (ESection s) = ESection (annotateSection fr s)
-- ELoc is transparent: preserve the loc, annotate the wrapped expr.
annotateExpr fr (ELoc l e) = ELoc l (annotateExpr fr e)
annotateExpr fr (EDoOrigin l e) = EDoOrigin l (annotateExpr fr e)

-- let-rec `let f = …` binds f in a fresh frame over BOTH the RHS and the body
-- (eval's evalRecLet pushFrame [f]); any other let evaluates the RHS in the
-- OUTER scope and pushes the pattern's bindings for the body only (evalLet).
annotateLet : List (List String) -> Bool -> Bool -> Pat -> Expr -> Expr -> Expr
annotateLet fr m True (PVar f) e1 e2 =
  let inner = [f]::fr
  ELet m True (PVar f) (annotateExpr inner e1) (annotateExpr inner e2)
annotateLet fr m isRec pat e1 e2 =
  ELet
    m
    isRec
    pat
    (annotateExpr fr e1)
    (annotateExpr (patBindings pat :: fr) e2)

-- where-group: one frame holds all the group names, in scope for every clause
-- body (under that clause's own per-param frames) and the result expression
annotateLetGroup : List (List String) -> List LetBind -> Expr -> Expr
annotateLetGroup fr binds body =
  let groupScope = map letBindName binds :: fr
  ELetGroup
    (map (annotateLetBind groupScope) binds)
    (annotateExpr groupScope body)

annotateLetBind : List (List String) -> LetBind -> LetBind
annotateLetBind groupScope (LetBind name clauses) =
  LetBind name (map (annotateClause groupScope) clauses)

annotateClause : List (List String) -> FunClause -> FunClause
annotateClause groupScope (FunClause pats body) =
  FunClause pats (annotateExpr (paramFrames pats ++ groupScope) body)

-- a match/function arm: the pattern pushes one frame; each GBind guard pushes a
-- further frame (GBool none); the body sees the fully-extended scope
annotateArm : List (List String) -> Arm -> Arm
annotateArm fr (Arm pat gs body) =
  let scope0 = patBindings pat :: fr
  let (gs2, scope2) = annotateGuards scope0 gs
  Arm pat gs2 (annotateExpr scope2 body)

annotateGuards : List (List String) -> List Guard -> (List Guard, List (List String))
annotateGuards scope [] = ([], scope)
annotateGuards scope ((GBool e)::rest) =
  let (rest2, scope2) = annotateGuards scope rest
  (GBool (annotateExpr scope e) :: rest2, scope2)
annotateGuards scope ((GBind p e)::rest) =
  let e2 = annotateExpr scope e
  let (rest2, scope2) = annotateGuards (patBindings p :: scope) rest
  (GBind p e2 :: rest2, scope2)

-- EGuards survive only pre-desugar; best-effort: each arm's GBind guards extend
-- the scope for the later guards and the body, mirroring annotateArm's threading
annotateGuardArm : List (List String) -> GuardArm -> GuardArm
annotateGuardArm fr (GuardArm gs body) =
  let (gs2, scope2) = annotateGuards fr gs
  GuardArm gs2 (annotateExpr scope2 body)

-- a bare block / do-block: each binding statement pushes a frame for the rest
annotateStmts : List (List String) -> List DoStmt -> List DoStmt
annotateStmts _ [] = []
annotateStmts fr ((DoExpr e)::rest) =
  DoExpr (annotateExpr fr e) :: annotateStmts fr rest
annotateStmts fr ((DoLet m r p e)::rest) =
  DoLet m r p (annotateExpr fr e) :: annotateStmts (patBindings p :: fr) rest
annotateStmts fr ((DoBind p e)::rest) =
  DoBind p (annotateExpr fr e) :: annotateStmts (patBindings p :: fr) rest
annotateStmts fr ((DoAssign x e)::rest) =
  DoAssign x (annotateExpr fr e) :: annotateStmts ([x]::fr) rest
annotateStmts fr ((DoFieldAssign x fs e)::rest) =
  DoFieldAssign x fs (annotateExpr fr e) :: annotateStmts fr rest

annotateInterp : List (List String) -> InterpPart -> InterpPart
annotateInterp _ (InterpStr s) = InterpStr s
annotateInterp fr (InterpExpr e) = InterpExpr (annotateExpr fr e)

annotateFieldAssign : List (List String) -> FieldAssign -> FieldAssign
annotateFieldAssign fr (FieldAssign n e) = FieldAssign n (annotateExpr fr e)

annotateKv : List (List String) -> (Expr, Expr) -> (Expr, Expr)
annotateKv fr (k, v) = (annotateExpr fr k, annotateExpr fr v)

annotateSection : List (List String) -> Section -> Section
annotateSection _ (SecBare op) = SecBare op
annotateSection fr (SecRight op e) = SecRight op (annotateExpr fr e)
annotateSection fr (SecLeft e op) = SecLeft (annotateExpr fr e) op

-- ── annotateDecl ──────────────────────────────────────────────────────────
-- a top-level function's params become per-parameter frames (the only local
-- scope; sibling top-level names resolve to AGlobal by-name)
annotateDecl : Decl -> Decl
annotateDecl (DFunDef p n pats body) =
  DFunDef p n pats (annotateExpr (paramFrames pats) body)
annotateDecl (DProp p n params body) =
  DProp p n params (annotateExpr [map propParamName params] body)
annotateDecl (DTest p n body) = DTest p n (annotateExpr [] body)
annotateDecl (DBench p n body) = DBench p n (annotateExpr [] body)
annotateDecl (DLetGroup p binds) =
  DLetGroup p (map (annotateLetBind (map letBindName binds :: [])) binds)
annotateDecl (DInterface { pub, def, name, typarams, supers, methods }) = DInterface { pub = pub, def = def, name = name, typarams = typarams, supers = supers, methods = map annotateIfaceMethod methods }
annotateDecl (DImpl { pub, iface, tys, reqs, methods }) = DImpl {
  pub = pub,
  iface = iface,
  tys = tys,
  reqs = reqs,
  methods = map annotateImplMethod methods,
}
annotateDecl (DAttrib attrs inner) = DAttrib attrs (annotateDecl inner)
annotateDecl d = d

annotateIfaceMethod : IfaceMethod -> IfaceMethod
annotateIfaceMethod (IfaceMethod nm ty None) = IfaceMethod nm ty None
annotateIfaceMethod (IfaceMethod nm ty (Some (MethodDefault pats body))) =
  IfaceMethod
    nm
    ty
    (Some (MethodDefault pats (annotateExpr (paramFrames pats) body)))

annotateImplMethod : ImplMethod -> ImplMethod
annotateImplMethod (ImplMethod nm pats body) =
  ImplMethod nm pats (annotateExpr (paramFrames pats) body)

-- EMIT the lexical addresses across a whole program.  The eval drivers run this
-- right before eval and the EVarAt arm in eval.mdk indexes frames by it.
export annotateProgram : List Decl -> List Decl
annotateProgram prog = map annotateDecl prog
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Ty" true) (mem "Constraint" true) (mem "Addr" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DTypeSig false "patBindings" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patBindings" ((PCon "PVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "patBindings" ((PCon "PWild")) (EListLit))
(DFunDef false "patBindings" ((PCon "PLit" PWild)) (EListLit))
(DFunDef false "patBindings" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "a")) (EApp (EVar "patBindings") (EVar "b"))))
(DFunDef false "patBindings" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PAs" (PVar "x") (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patBindings") (EVar "p"))))
(DFunDef false "patBindings" ((PCon "PRng" PWild PWild PWild)) (EListLit))
(DFunDef false "patBindings" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EVar "flatMap") (EVar "recFieldBindings")) (EVar "fields")))
(DTypeSig false "recFieldBindings" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recFieldBindings" ((PCon "RecPatField" (PVar "fname") (PCon "None"))) (EListLit (EVar "fname")))
(DFunDef false "recFieldBindings" ((PCon "RecPatField" PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patBindings") (EVar "p")))
(DTypeSig false "startsWithAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Bool")))
(DFunDef false "startsWithAt" ((PVar "cs")) (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")) (ELit (LChar "@")))))
(DTypeSig false "isHint" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isHint" ((PVar "n")) (EApp (EVar "startsWithAt") (EApp (EVar "stringToChars") (EVar "n"))))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "propParamName" (TyFun (TyCon "PropParam") (TyCon "String")))
(DFunDef false "propParamName" ((PCon "PropParam" (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "paramFrames" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "paramFrames" ((PVar "pats")) (EApp (EVar "reverseL") (EApp (EApp (EVar "map") (EVar "patBindings")) (EVar "pats"))))
(DTypeSig false "slotIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "slotIn" ((PList) PWild PWild) (EVar "None"))
(DFunDef false "slotIn" ((PCons (PVar "m") (PVar "rest")) (PVar "n") (PVar "i")) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "slotIn") (EVar "rest")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "addrOf" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "Addr"))))
(DFunDef false "addrOf" ((PVar "frames") (PVar "n")) (EApp (EApp (EApp (EVar "addrOfGo") (EVar "frames")) (EVar "n")) (ELit (LInt 0))))
(DTypeSig false "addrOfGo" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Addr")))))
(DFunDef false "addrOfGo" ((PList) PWild PWild) (EVar "AGlobal"))
(DFunDef false "addrOfGo" ((PCons (PVar "frame") (PVar "rest")) (PVar "n") (PVar "depth")) (EMatch (EApp (EApp (EApp (EVar "slotIn") (EVar "frame")) (EVar "n")) (ELit (LInt 0))) (arm (PCon "Some" (PVar "slot")) () (EApp (EApp (EVar "ALocal") (EVar "depth")) (EVar "slot"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "addrOfGo") (EVar "rest")) (EVar "n")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))))))
(DTypeSig false "annotateExpr" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "annotateExpr" (PWild (PCon "ELit" (PVar "l"))) (EApp (EVar "ELit") (EVar "l")))
(DFunDef false "annotateExpr" (PWild (PCon "ENumLit" (PVar "n") (PVar "r") (PVar "d"))) (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EVar "r")) (EVar "d")))
(DFunDef false "annotateExpr" (PWild (PCon "EMethodRef" (PVar "m"))) (EApp (EVar "EMethodRef") (EVar "m")))
(DFunDef false "annotateExpr" (PWild (PCon "EDictApp" (PVar "d"))) (EApp (EVar "EDictApp") (EVar "d")))
(DFunDef false "annotateExpr" (PWild (PCon "EMethodAt" (PVar "name") (PVar "r") (PVar "ir") (PVar "mr"))) (EApp (EApp (EApp (EApp (EVar "EMethodAt") (EVar "name")) (EVar "r")) (EVar "ir")) (EVar "mr")))
(DFunDef false "annotateExpr" (PWild (PCon "EDictAt" (PVar "name") (PVar "r"))) (EApp (EApp (EVar "EDictAt") (EVar "name")) (EVar "r")))
(DFunDef false "annotateExpr" (PWild (PCon "EVarAt" (PVar "n") (PVar "a"))) (EApp (EApp (EVar "EVarAt") (EVar "n")) (EVar "a")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EVar" (PVar "n"))) (EIf (EApp (EVar "isHint") (EVar "n")) (EApp (EVar "EVar") (EVar "n")) (EIf (EVar "otherwise") (EApp (EApp (EVar "EVarAt") (EVar "n")) (EApp (EApp (EVar "addrOf") (EVar "fr")) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "f"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "x"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "ELam") (EVar "pats")) (EApp (EApp (EVar "annotateExpr") (EBinOp "++" (EApp (EVar "paramFrames") (EVar "pats")) (EVar "fr"))) (EVar "body"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ELet" (PVar "m") (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "annotateLet") (EVar "fr")) (EVar "m")) (EVar "isRec")) (EVar "pat")) (EVar "e1")) (EVar "e2")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EVar "annotateLetGroup") (EVar "fr")) (EVar "binds")) (EVar "body")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EVar "annotateArm") (EVar "fr"))) (EVar "arms"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "c"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "t"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "el"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "a"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "b"))) (EVar "r")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "a"))) (EVar "r")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "a"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "b"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EFieldAccess" (PVar "e0") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))) (EVar "f")) (EVar "r")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EApp (EVar "annotateExpr") (EVar "fr"))) (EVar "es"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EApp (EVar "annotateExpr") (EVar "fr"))) (EVar "es"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EApp (EVar "annotateExpr") (EVar "fr"))) (EVar "es"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "lo"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "lo"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "incl") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "lo"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "hi"))) (EVar "incl")) (EVar "r")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EIndex" (PVar "e0") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "i"))) (EVar "r")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))) (EVar "t")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))) (EVar "t")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "annotateStmts") (EVar "fr")) (EVar "stmts"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EDo" (PVar "stmts"))) (EApp (EVar "EDo") (EApp (EApp (EVar "annotateStmts") (EVar "fr")) (EVar "stmts"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EApp (EVar "annotateInterp") (EVar "fr"))) (EVar "parts"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EApp (EVar "annotateGuardArm") (EVar "fr"))) (EVar "arms"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ERecordCreate" (PVar "name") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "annotateFieldAssign") (EVar "fr"))) (EVar "fs"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EVar "annotateFieldAssign") (EVar "fr"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EVariantUpdate" (PVar "con") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "con")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EVar "annotateFieldAssign") (EVar "fr"))) (EVar "fs"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "annotateKv") (EVar "fr"))) (EVar "kvs"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "annotateExpr") (EVar "fr"))) (EVar "es"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EAsPat" (PVar "x") (PVar "e0"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EApp (EVar "annotateSection") (EVar "fr")) (EVar "s"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))))
(DTypeSig false "annotateLet" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr"))))))))
(DFunDef false "annotateLet" ((PVar "fr") (PVar "m") (PCon "True") (PCon "PVar" (PVar "f")) (PVar "e1") (PVar "e2")) (EBlock (DoLet false false (PVar "inner") (EBinOp "::" (EListLit (EVar "f")) (EVar "fr"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "True")) (EApp (EVar "PVar") (EVar "f"))) (EApp (EApp (EVar "annotateExpr") (EVar "inner")) (EVar "e1"))) (EApp (EApp (EVar "annotateExpr") (EVar "inner")) (EVar "e2"))))))
(DFunDef false "annotateLet" ((PVar "fr") (PVar "m") (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2")) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isRec")) (EVar "pat")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e1"))) (EApp (EApp (EVar "annotateExpr") (EBinOp "::" (EApp (EVar "patBindings") (EVar "pat")) (EVar "fr"))) (EVar "e2"))))
(DTypeSig false "annotateLetGroup" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "annotateLetGroup" ((PVar "fr") (PVar "binds") (PVar "body")) (EBlock (DoLet false false (PVar "groupScope") (EBinOp "::" (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")) (EVar "fr"))) (DoExpr (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EApp (EVar "annotateLetBind") (EVar "groupScope"))) (EVar "binds"))) (EApp (EApp (EVar "annotateExpr") (EVar "groupScope")) (EVar "body"))))))
(DTypeSig false "annotateLetBind" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "annotateLetBind" ((PVar "groupScope") (PCon "LetBind" (PVar "name") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "annotateClause") (EVar "groupScope"))) (EVar "clauses"))))
(DTypeSig false "annotateClause" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "annotateClause" ((PVar "groupScope") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "pats")) (EApp (EApp (EVar "annotateExpr") (EBinOp "++" (EApp (EVar "paramFrames") (EVar "pats")) (EVar "groupScope"))) (EVar "body"))))
(DTypeSig false "annotateArm" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Arm") (TyCon "Arm"))))
(DFunDef false "annotateArm" ((PVar "fr") (PCon "Arm" (PVar "pat") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "scope0") (EBinOp "::" (EApp (EVar "patBindings") (EVar "pat")) (EVar "fr"))) (DoLet false false (PTuple (PVar "gs2") (PVar "scope2")) (EApp (EApp (EVar "annotateGuards") (EVar "scope0")) (EVar "gs"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EVar "gs2")) (EApp (EApp (EVar "annotateExpr") (EVar "scope2")) (EVar "body"))))))
(DTypeSig false "annotateGuards" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "Guard")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "annotateGuards" ((PVar "scope") (PList)) (ETuple (EListLit) (EVar "scope")))
(DFunDef false "annotateGuards" ((PVar "scope") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rest2") (PVar "scope2")) (EApp (EApp (EVar "annotateGuards") (EVar "scope")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "GBool") (EApp (EApp (EVar "annotateExpr") (EVar "scope")) (EVar "e"))) (EVar "rest2")) (EVar "scope2")))))
(DFunDef false "annotateGuards" ((PVar "scope") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EVar "annotateExpr") (EVar "scope")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "scope2")) (EApp (EApp (EVar "annotateGuards") (EBinOp "::" (EApp (EVar "patBindings") (EVar "p")) (EVar "scope"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GBind") (EVar "p")) (EVar "e2")) (EVar "rest2")) (EVar "scope2")))))
(DTypeSig false "annotateGuardArm" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))
(DFunDef false "annotateGuardArm" ((PVar "fr") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "gs2") (PVar "scope2")) (EApp (EApp (EVar "annotateGuards") (EVar "fr")) (EVar "gs"))) (DoExpr (EApp (EApp (EVar "GuardArm") (EVar "gs2")) (EApp (EApp (EVar "annotateExpr") (EVar "scope2")) (EVar "body"))))))
(DTypeSig false "annotateStmts" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "annotateStmts" (PWild (PList)) (EListLit))
(DFunDef false "annotateStmts" ((PVar "fr") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "DoExpr") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))) (EApp (EApp (EVar "annotateStmts") (EVar "fr")) (EVar "rest"))))
(DFunDef false "annotateStmts" ((PVar "fr") (PCons (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))) (EApp (EApp (EVar "annotateStmts") (EBinOp "::" (EApp (EVar "patBindings") (EVar "p")) (EVar "fr"))) (EVar "rest"))))
(DFunDef false "annotateStmts" ((PVar "fr") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))) (EApp (EApp (EVar "annotateStmts") (EBinOp "::" (EApp (EVar "patBindings") (EVar "p")) (EVar "fr"))) (EVar "rest"))))
(DFunDef false "annotateStmts" ((PVar "fr") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))) (EApp (EApp (EVar "annotateStmts") (EBinOp "::" (EListLit (EVar "x")) (EVar "fr"))) (EVar "rest"))))
(DFunDef false "annotateStmts" ((PVar "fr") (PCons (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))) (EApp (EApp (EVar "annotateStmts") (EVar "fr")) (EVar "rest"))))
(DTypeSig false "annotateInterp" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))
(DFunDef false "annotateInterp" (PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "annotateInterp" ((PVar "fr") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))))
(DTypeSig false "annotateFieldAssign" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))
(DFunDef false "annotateFieldAssign" ((PVar "fr") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))))
(DTypeSig false "annotateKv" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "annotateKv" ((PVar "fr") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "k")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "v"))))
(DTypeSig false "annotateSection" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Section") (TyCon "Section"))))
(DFunDef false "annotateSection" (PWild (PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "annotateSection" ((PVar "fr") (PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))))
(DFunDef false "annotateSection" ((PVar "fr") (PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))) (EVar "op")))
(DTypeSig false "annotateDecl" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "annotateDecl" ((PCon "DFunDef" (PVar "p") (PVar "n") (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "p")) (EVar "n")) (EVar "pats")) (EApp (EApp (EVar "annotateExpr") (EApp (EVar "paramFrames") (EVar "pats"))) (EVar "body"))))
(DFunDef false "annotateDecl" ((PCon "DProp" (PVar "p") (PVar "n") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "p")) (EVar "n")) (EVar "params")) (EApp (EApp (EVar "annotateExpr") (EListLit (EApp (EApp (EVar "map") (EVar "propParamName")) (EVar "params")))) (EVar "body"))))
(DFunDef false "annotateDecl" ((PCon "DTest" (PVar "p") (PVar "n") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "p")) (EVar "n")) (EApp (EApp (EVar "annotateExpr") (EListLit)) (EVar "body"))))
(DFunDef false "annotateDecl" ((PCon "DBench" (PVar "p") (PVar "n") (PVar "body"))) (EApp (EApp (EApp (EVar "DBench") (EVar "p")) (EVar "n")) (EApp (EApp (EVar "annotateExpr") (EListLit)) (EVar "body"))))
(DFunDef false "annotateDecl" ((PCon "DLetGroup" (PVar "p") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "p")) (EApp (EApp (EVar "map") (EApp (EVar "annotateLetBind") (EBinOp "::" (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")) (EListLit)))) (EVar "binds"))))
(DFunDef false "annotateDecl" ((PRec "DInterface" ((rf "pub" None) (rf "def" None) (rf "name" None) (rf "typarams" None) (rf "supers" None) (rf "methods" None)) false)) (ERecordCreate "DInterface" ((fa "pub" (EVar "pub")) (fa "def" (EVar "def")) (fa "name" (EVar "name")) (fa "typarams" (EVar "typarams")) (fa "supers" (EVar "supers")) (fa "methods" (EApp (EApp (EVar "map") (EVar "annotateIfaceMethod")) (EVar "methods"))))))
(DFunDef false "annotateDecl" ((PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (ERecordCreate "DImpl" ((fa "pub" (EVar "pub")) (fa "iface" (EVar "iface")) (fa "tys" (EVar "tys")) (fa "reqs" (EVar "reqs")) (fa "methods" (EApp (EApp (EVar "map") (EVar "annotateImplMethod")) (EVar "methods"))))))
(DFunDef false "annotateDecl" ((PCon "DAttrib" (PVar "attrs") (PVar "inner"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EVar "annotateDecl") (EVar "inner"))))
(DFunDef false "annotateDecl" ((PVar "d")) (EVar "d"))
(DTypeSig false "annotateIfaceMethod" (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod")))
(DFunDef false "annotateIfaceMethod" ((PCon "IfaceMethod" (PVar "nm") (PVar "ty") (PCon "None"))) (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "nm")) (EVar "ty")) (EVar "None")))
(DFunDef false "annotateIfaceMethod" ((PCon "IfaceMethod" (PVar "nm") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))))) (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "nm")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "pats")) (EApp (EApp (EVar "annotateExpr") (EApp (EVar "paramFrames") (EVar "pats"))) (EVar "body"))))))
(DTypeSig false "annotateImplMethod" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "annotateImplMethod" ((PCon "ImplMethod" (PVar "nm") (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "pats")) (EApp (EApp (EVar "annotateExpr") (EApp (EVar "paramFrames") (EVar "pats"))) (EVar "body"))))
(DTypeSig true "annotateProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "annotateProgram" ((PVar "prog")) (EApp (EApp (EVar "map") (EVar "annotateDecl")) (EVar "prog")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Ty" true) (mem "Constraint" true) (mem "Addr" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DTypeSig false "patBindings" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patBindings" ((PCon "PVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "patBindings" ((PCon "PWild")) (EListLit))
(DFunDef false "patBindings" ((PCon "PLit" PWild)) (EListLit))
(DFunDef false "patBindings" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "a")) (EApp (EVar "patBindings") (EVar "b"))))
(DFunDef false "patBindings" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PAs" (PVar "x") (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patBindings") (EVar "p"))))
(DFunDef false "patBindings" ((PCon "PRng" PWild PWild PWild)) (EListLit))
(DFunDef false "patBindings" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "recFieldBindings")) (EVar "fields")))
(DTypeSig false "recFieldBindings" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recFieldBindings" ((PCon "RecPatField" (PVar "fname") (PCon "None"))) (EListLit (EVar "fname")))
(DFunDef false "recFieldBindings" ((PCon "RecPatField" PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patBindings") (EVar "p")))
(DTypeSig false "startsWithAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Bool")))
(DFunDef false "startsWithAt" ((PVar "cs")) (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")) (ELit (LChar "@")))))
(DTypeSig false "isHint" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isHint" ((PVar "n")) (EApp (EVar "startsWithAt") (EApp (EVar "stringToChars") (EVar "n"))))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "propParamName" (TyFun (TyCon "PropParam") (TyCon "String")))
(DFunDef false "propParamName" ((PCon "PropParam" (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "paramFrames" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "paramFrames" ((PVar "pats")) (EApp (EVar "reverseL") (EApp (EApp (EMethodRef "map") (EVar "patBindings")) (EVar "pats"))))
(DTypeSig false "slotIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "slotIn" ((PList) PWild PWild) (EVar "None"))
(DFunDef false "slotIn" ((PCons (PVar "m") (PVar "rest")) (PVar "n") (PVar "i")) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "slotIn") (EVar "rest")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "addrOf" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "Addr"))))
(DFunDef false "addrOf" ((PVar "frames") (PVar "n")) (EApp (EApp (EApp (EVar "addrOfGo") (EVar "frames")) (EVar "n")) (ELit (LInt 0))))
(DTypeSig false "addrOfGo" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Addr")))))
(DFunDef false "addrOfGo" ((PList) PWild PWild) (EVar "AGlobal"))
(DFunDef false "addrOfGo" ((PCons (PVar "frame") (PVar "rest")) (PVar "n") (PVar "depth")) (EMatch (EApp (EApp (EApp (EVar "slotIn") (EVar "frame")) (EVar "n")) (ELit (LInt 0))) (arm (PCon "Some" (PVar "slot")) () (EApp (EApp (EVar "ALocal") (EVar "depth")) (EVar "slot"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "addrOfGo") (EVar "rest")) (EVar "n")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))))))
(DTypeSig false "annotateExpr" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "annotateExpr" (PWild (PCon "ELit" (PVar "l"))) (EApp (EVar "ELit") (EVar "l")))
(DFunDef false "annotateExpr" (PWild (PCon "ENumLit" (PVar "n") (PVar "r") (PVar "d"))) (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EVar "r")) (EVar "d")))
(DFunDef false "annotateExpr" (PWild (PCon "EMethodRef" (PVar "m"))) (EApp (EVar "EMethodRef") (EVar "m")))
(DFunDef false "annotateExpr" (PWild (PCon "EDictApp" (PVar "d"))) (EApp (EVar "EDictApp") (EVar "d")))
(DFunDef false "annotateExpr" (PWild (PCon "EMethodAt" (PVar "name") (PVar "r") (PVar "ir") (PVar "mr"))) (EApp (EApp (EApp (EApp (EVar "EMethodAt") (EVar "name")) (EVar "r")) (EVar "ir")) (EVar "mr")))
(DFunDef false "annotateExpr" (PWild (PCon "EDictAt" (PVar "name") (PVar "r"))) (EApp (EApp (EVar "EDictAt") (EVar "name")) (EVar "r")))
(DFunDef false "annotateExpr" (PWild (PCon "EVarAt" (PVar "n") (PVar "a"))) (EApp (EApp (EVar "EVarAt") (EVar "n")) (EVar "a")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EVar" (PVar "n"))) (EIf (EApp (EVar "isHint") (EVar "n")) (EApp (EVar "EVar") (EVar "n")) (EIf (EVar "otherwise") (EApp (EApp (EVar "EVarAt") (EVar "n")) (EApp (EApp (EVar "addrOf") (EVar "fr")) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "f"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "x"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "ELam") (EVar "pats")) (EApp (EApp (EVar "annotateExpr") (EBinOp "++" (EApp (EVar "paramFrames") (EVar "pats")) (EVar "fr"))) (EVar "body"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ELet" (PVar "m") (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "annotateLet") (EVar "fr")) (EVar "m")) (EVar "isRec")) (EVar "pat")) (EVar "e1")) (EVar "e2")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EVar "annotateLetGroup") (EVar "fr")) (EVar "binds")) (EVar "body")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "annotateArm") (EVar "fr"))) (EVar "arms"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "c"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "t"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "el"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "a"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "b"))) (EVar "r")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "a"))) (EVar "r")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "a"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "b"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EFieldAccess" (PVar "e0") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))) (EVar "f")) (EVar "r")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "annotateExpr") (EVar "fr"))) (EVar "es"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EApp (EVar "annotateExpr") (EVar "fr"))) (EVar "es"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EApp (EVar "annotateExpr") (EVar "fr"))) (EVar "es"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "lo"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "lo"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "incl") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "lo"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "hi"))) (EVar "incl")) (EVar "r")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EIndex" (PVar "e0") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "i"))) (EVar "r")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))) (EVar "t")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))) (EVar "t")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "annotateStmts") (EVar "fr")) (EVar "stmts"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EDo" (PVar "stmts"))) (EApp (EVar "EDo") (EApp (EApp (EVar "annotateStmts") (EVar "fr")) (EVar "stmts"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EApp (EVar "annotateInterp") (EVar "fr"))) (EVar "parts"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EApp (EVar "annotateGuardArm") (EVar "fr"))) (EVar "arms"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ERecordCreate" (PVar "name") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "annotateFieldAssign") (EVar "fr"))) (EVar "fs"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "annotateFieldAssign") (EVar "fr"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EVariantUpdate" (PVar "con") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "con")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "annotateFieldAssign") (EVar "fr"))) (EVar "fs"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "annotateKv") (EVar "fr"))) (EVar "kvs"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "annotateExpr") (EVar "fr"))) (EVar "es"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EAsPat" (PVar "x") (PVar "e0"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e0"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EApp (EVar "annotateSection") (EVar "fr")) (EVar "s"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))))
(DFunDef false "annotateExpr" ((PVar "fr") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))))
(DTypeSig false "annotateLet" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr"))))))))
(DFunDef false "annotateLet" ((PVar "fr") (PVar "m") (PCon "True") (PCon "PVar" (PVar "f")) (PVar "e1") (PVar "e2")) (EBlock (DoLet false false (PVar "inner") (EBinOp "::" (EListLit (EVar "f")) (EVar "fr"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "True")) (EApp (EVar "PVar") (EVar "f"))) (EApp (EApp (EVar "annotateExpr") (EVar "inner")) (EVar "e1"))) (EApp (EApp (EVar "annotateExpr") (EVar "inner")) (EVar "e2"))))))
(DFunDef false "annotateLet" ((PVar "fr") (PVar "m") (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2")) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isRec")) (EVar "pat")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e1"))) (EApp (EApp (EVar "annotateExpr") (EBinOp "::" (EApp (EVar "patBindings") (EVar "pat")) (EVar "fr"))) (EVar "e2"))))
(DTypeSig false "annotateLetGroup" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "annotateLetGroup" ((PVar "fr") (PVar "binds") (PVar "body")) (EBlock (DoLet false false (PVar "groupScope") (EBinOp "::" (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")) (EVar "fr"))) (DoExpr (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EApp (EVar "annotateLetBind") (EVar "groupScope"))) (EVar "binds"))) (EApp (EApp (EVar "annotateExpr") (EVar "groupScope")) (EVar "body"))))))
(DTypeSig false "annotateLetBind" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "annotateLetBind" ((PVar "groupScope") (PCon "LetBind" (PVar "name") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "annotateClause") (EVar "groupScope"))) (EVar "clauses"))))
(DTypeSig false "annotateClause" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "annotateClause" ((PVar "groupScope") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "pats")) (EApp (EApp (EVar "annotateExpr") (EBinOp "++" (EApp (EVar "paramFrames") (EVar "pats")) (EVar "groupScope"))) (EVar "body"))))
(DTypeSig false "annotateArm" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Arm") (TyCon "Arm"))))
(DFunDef false "annotateArm" ((PVar "fr") (PCon "Arm" (PVar "pat") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "scope0") (EBinOp "::" (EApp (EVar "patBindings") (EVar "pat")) (EVar "fr"))) (DoLet false false (PTuple (PVar "gs2") (PVar "scope2")) (EApp (EApp (EVar "annotateGuards") (EVar "scope0")) (EVar "gs"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EVar "gs2")) (EApp (EApp (EVar "annotateExpr") (EVar "scope2")) (EVar "body"))))))
(DTypeSig false "annotateGuards" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "Guard")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "annotateGuards" ((PVar "scope") (PList)) (ETuple (EListLit) (EVar "scope")))
(DFunDef false "annotateGuards" ((PVar "scope") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rest2") (PVar "scope2")) (EApp (EApp (EVar "annotateGuards") (EVar "scope")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "GBool") (EApp (EApp (EVar "annotateExpr") (EVar "scope")) (EVar "e"))) (EVar "rest2")) (EVar "scope2")))))
(DFunDef false "annotateGuards" ((PVar "scope") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EVar "annotateExpr") (EVar "scope")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "scope2")) (EApp (EApp (EVar "annotateGuards") (EBinOp "::" (EApp (EVar "patBindings") (EVar "p")) (EVar "scope"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GBind") (EVar "p")) (EVar "e2")) (EVar "rest2")) (EVar "scope2")))))
(DTypeSig false "annotateGuardArm" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))
(DFunDef false "annotateGuardArm" ((PVar "fr") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "gs2") (PVar "scope2")) (EApp (EApp (EVar "annotateGuards") (EVar "fr")) (EVar "gs"))) (DoExpr (EApp (EApp (EVar "GuardArm") (EVar "gs2")) (EApp (EApp (EVar "annotateExpr") (EVar "scope2")) (EVar "body"))))))
(DTypeSig false "annotateStmts" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "annotateStmts" (PWild (PList)) (EListLit))
(DFunDef false "annotateStmts" ((PVar "fr") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "DoExpr") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))) (EApp (EApp (EVar "annotateStmts") (EVar "fr")) (EVar "rest"))))
(DFunDef false "annotateStmts" ((PVar "fr") (PCons (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))) (EApp (EApp (EVar "annotateStmts") (EBinOp "::" (EApp (EVar "patBindings") (EVar "p")) (EVar "fr"))) (EVar "rest"))))
(DFunDef false "annotateStmts" ((PVar "fr") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))) (EApp (EApp (EVar "annotateStmts") (EBinOp "::" (EApp (EVar "patBindings") (EVar "p")) (EVar "fr"))) (EVar "rest"))))
(DFunDef false "annotateStmts" ((PVar "fr") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))) (EApp (EApp (EVar "annotateStmts") (EBinOp "::" (EListLit (EVar "x")) (EVar "fr"))) (EVar "rest"))))
(DFunDef false "annotateStmts" ((PVar "fr") (PCons (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))) (EApp (EApp (EVar "annotateStmts") (EVar "fr")) (EVar "rest"))))
(DTypeSig false "annotateInterp" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))
(DFunDef false "annotateInterp" (PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "annotateInterp" ((PVar "fr") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))))
(DTypeSig false "annotateFieldAssign" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))
(DFunDef false "annotateFieldAssign" ((PVar "fr") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))))
(DTypeSig false "annotateKv" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "annotateKv" ((PVar "fr") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "k")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "v"))))
(DTypeSig false "annotateSection" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Section") (TyCon "Section"))))
(DFunDef false "annotateSection" (PWild (PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "annotateSection" ((PVar "fr") (PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))))
(DFunDef false "annotateSection" ((PVar "fr") (PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EApp (EVar "annotateExpr") (EVar "fr")) (EVar "e"))) (EVar "op")))
(DTypeSig false "annotateDecl" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "annotateDecl" ((PCon "DFunDef" (PVar "p") (PVar "n") (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "p")) (EVar "n")) (EVar "pats")) (EApp (EApp (EVar "annotateExpr") (EApp (EVar "paramFrames") (EVar "pats"))) (EVar "body"))))
(DFunDef false "annotateDecl" ((PCon "DProp" (PVar "p") (PVar "n") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "p")) (EVar "n")) (EVar "params")) (EApp (EApp (EVar "annotateExpr") (EListLit (EApp (EApp (EMethodRef "map") (EVar "propParamName")) (EVar "params")))) (EVar "body"))))
(DFunDef false "annotateDecl" ((PCon "DTest" (PVar "p") (PVar "n") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "p")) (EVar "n")) (EApp (EApp (EVar "annotateExpr") (EListLit)) (EVar "body"))))
(DFunDef false "annotateDecl" ((PCon "DBench" (PVar "p") (PVar "n") (PVar "body"))) (EApp (EApp (EApp (EVar "DBench") (EVar "p")) (EVar "n")) (EApp (EApp (EVar "annotateExpr") (EListLit)) (EVar "body"))))
(DFunDef false "annotateDecl" ((PCon "DLetGroup" (PVar "p") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "p")) (EApp (EApp (EMethodRef "map") (EApp (EVar "annotateLetBind") (EBinOp "::" (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")) (EListLit)))) (EVar "binds"))))
(DFunDef false "annotateDecl" ((PRec "DInterface" ((rf "pub" None) (rf "def" None) (rf "name" None) (rf "typarams" None) (rf "supers" None) (rf "methods" None)) false)) (ERecordCreate "DInterface" ((fa "pub" (EVar "pub")) (fa "def" (EVar "def")) (fa "name" (EVar "name")) (fa "typarams" (EVar "typarams")) (fa "supers" (EVar "supers")) (fa "methods" (EApp (EApp (EMethodRef "map") (EVar "annotateIfaceMethod")) (EVar "methods"))))))
(DFunDef false "annotateDecl" ((PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (ERecordCreate "DImpl" ((fa "pub" (EVar "pub")) (fa "iface" (EVar "iface")) (fa "tys" (EVar "tys")) (fa "reqs" (EVar "reqs")) (fa "methods" (EApp (EApp (EMethodRef "map") (EVar "annotateImplMethod")) (EVar "methods"))))))
(DFunDef false "annotateDecl" ((PCon "DAttrib" (PVar "attrs") (PVar "inner"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EVar "annotateDecl") (EVar "inner"))))
(DFunDef false "annotateDecl" ((PVar "d")) (EVar "d"))
(DTypeSig false "annotateIfaceMethod" (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod")))
(DFunDef false "annotateIfaceMethod" ((PCon "IfaceMethod" (PVar "nm") (PVar "ty") (PCon "None"))) (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "nm")) (EVar "ty")) (EVar "None")))
(DFunDef false "annotateIfaceMethod" ((PCon "IfaceMethod" (PVar "nm") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))))) (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "nm")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "pats")) (EApp (EApp (EVar "annotateExpr") (EApp (EVar "paramFrames") (EVar "pats"))) (EVar "body"))))))
(DTypeSig false "annotateImplMethod" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "annotateImplMethod" ((PCon "ImplMethod" (PVar "nm") (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "pats")) (EApp (EApp (EVar "annotateExpr") (EApp (EVar "paramFrames") (EVar "pats"))) (EVar "body"))))
(DTypeSig true "annotateProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "annotateProgram" ((PVar "prog")) (EApp (EApp (EMethodRef "map") (EVar "annotateDecl")) (EVar "prog")))
