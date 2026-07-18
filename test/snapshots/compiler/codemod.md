# META
source_lines=685
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/codemod.mdk — the `medaka codemod` framework + registry.
--
-- A codemod is a NAMED, source-preserving AST transform: parse a `.mdk` file
-- (WITH positions + comments), rewrite its declarations, and re-render through
-- the comment-preserving formatter (`tools.fmt.formatProgram`).  The registry
-- mirrors `tools.lint`'s `Rule` pattern — adding a codemod is ONE constructor
-- function + ONE entry in `allCodemods`.  The CLI layer (medaka_cli.mdk) never
-- touches the record fields directly; it goes through the exported accessors
-- (`codemodName`/`codemodMk`/`codemodWarnDecls`/…) exactly as it does for lint.
--
-- ── Position/comment invariant (why re-render is safe) ──────────────────────
-- `codemodSource` threads the parser's position side-channels
-- (`positionsDecls`/`positionsVariantLines`/`positionsChainLines`/
-- `positionsLastContentLine`) BACK INTO `formatProgram` UNCHANGED.  That is only
-- sound because a codemod transform NEVER adds, removes, or reorders a decl, a
-- `data` variant, or a continuation-chain operand — it only rewrites TYPES in
-- place.  A transform that violates that (e.g. one that splices a new decl) would
-- desynchronise the side-channels and MUST NOT reuse this core.
--
-- ⚠️ VERBATIM SAFETY-NET CAVEAT.  `formatProgram`'s Option-C net (fmt.mdk:336-417)
-- re-emits a NON-data decl's ORIGINAL source lines verbatim whenever that decl
-- carries an INTERIOR single-line comment the chain/block paths can't anchor.
-- For such a decl the type rewrite is present in the AST but SILENTLY DISCARDED
-- from the rendered output (the original text wins).  Callers doing a bulk strip
-- MUST grep for residue afterwards (the PR-1 harness does exactly this).  Data
-- decls are exempt (their comments are placed per-variant, a reflow-safe path).
--
-- No stdlib imports (compiler isolation): generic helpers come from
-- support.util; the total Expr traversal is hand-rolled here (rather than reusing
-- desugar's `Expr -> Expr` engine) precisely so the CHANGED flag threads purely
-- (an in-place mutable-cell approach would leak a host capability into the
-- transform's otherwise-pure type).

import frontend.ast.{
  Ty(..),
  Constraint(..),
  Expr(..),
  Section(..),
  Arm(..),
  Guard(..),
  DoStmt(..),
  InterpPart(..),
  GuardArm(..),
  FieldAssign(..),
  LetBind(..),
  FunClause(..),
  PropParam(..),
  IfaceMethod(..),
  MethodDefault(..),
  Require(..),
  ImplMethod(..),
  Variant(..),
  ConPayload(..),
  Field(..),
  Decl(..),
}
import frontend.parser.{
  parseResult,
  ParseError,
  parseWithPositions,
  positionsDecls,
  positionsVariantLines,
  positionsChainLines,
  positionsLastContentLine,
}
import frontend.lexer.{collectComments}
import tools.fmt.{formatProgram}
import support.util.{
  reverseL,
  listLen,
  lookupAssoc,
  splitOnChar,
  joinNl,
  anyList,
}

-- ── public types ───────────────────────────────────────────────────────────

-- A registered codemod.  `mk` parses the codemod-specific CLI arguments and
-- returns EITHER an error message OR the per-decl transform `Decl -> (Decl,
-- Bool)` (the Bool = "this decl changed").  `warn`, given the same args plus a
-- file's decls, returns advisory stderr lines the transform can't express (the
-- pure transform can't do IO) — e.g. "you asked to strip a label a `DEffect`
-- here declares".  Most codemods leave `warn` returning `[]`.
public export data Codemod =
  | Codemod {
      name : String,
      descr : String,
      argHelp : String,
      mk : List String -> Result String (Decl -> (Decl, Bool)),
      warn : List String -> List Decl -> List String,
    }

-- ── registry ────────────────────────────────────────────────────────────────
-- Adding a codemod = one `mkX`/`warnX` pair + one entry here.
export allCodemods : List Codemod
allCodemods = [effectLabelsCodemod]

effectLabelsCodemod : Codemod
effectLabelsCodemod = Codemod {
  name = "effect-labels",
  descr = "strip and/or rename effect-row labels (e.g. <Rand>, <Net>, …)",
  argHelp = "--strip L1,L2   --rename Old=New   (repeatable)",
  mk = mkEffectLabels,
  warn = warnEffectLabels,
}

-- ── accessors (the CLI uses these; never the record fields) ──────────────────
export codemodName : Codemod -> String
codemodName (Codemod { name, ... }) = name

export codemodDescr : Codemod -> String
codemodDescr (Codemod { descr, ... }) = descr

export codemodArgHelp : Codemod -> String
codemodArgHelp (Codemod { argHelp, ... }) = argHelp

export codemodMk : Codemod -> List String -> Result String (Decl -> (Decl, Bool))
codemodMk (Codemod { mk, ... }) args = mk args

export codemodWarnDecls : Codemod -> List String -> List Decl -> List String
codemodWarnDecls (Codemod { warn, ... }) args decls = warn args decls

export findCodemod : String -> Option Codemod
findCodemod name = findCodemodGo name allCodemods

findCodemodGo : String -> List Codemod -> Option Codemod
findCodemodGo _ [] = None
findCodemodGo name (c::rest) =
  if codemodName c == name then
    Some c
  else
    findCodemodGo name rest

-- Registry listing for the bare `medaka codemod` invocation.
export codemodListing : String
codemodListing = joinNl (map codemodListingLine allCodemods)

codemodListingLine : Codemod -> String
codemodListingLine c =
  "  \{codemodName c} — \{codemodDescr c}\n    \{codemodArgHelp c}"

-- ── pure core ────────────────────────────────────────────────────────────────
-- Parse `src`, run the transform over every decl (OR-folding the change flags),
-- and — ONLY when something changed — re-render through the comment-preserving
-- formatter.  `None` = nothing changed (the caller MUST NOT write: this keeps a
-- codemod from doubling as `fmt` and keeps it off non-fmt-clean or #51 float
-- files that carry no target label).  Parse errors surface as `Err ParseError`
-- so the CLI reports them through the shared `ppParseError` path.
export codemodSource : (Decl -> (Decl, Bool)) -> String -> Result ParseError (Option String)
codemodSource xf src = match parseResult src
  Err e => Err e
  Ok _ =>
    -- parseResult already proved the source parses, so parseWithPositions
    -- (which panics on failure) is safe here.
    let (decls, pos) = parseWithPositions src
    let (decls2, changed) = mapDeclsChanged xf decls
    if not changed then Ok None
    else
      let comments = collectComments src
      Ok (Some (formatProgram
        decls2
        (positionsDecls pos)
        (positionsVariantLines pos)
        (positionsChainLines pos)
        comments
        (positionsLastContentLine pos)
        src))

mapDeclsChanged : (Decl -> (Decl, Bool)) -> List Decl -> (List Decl, Bool)
mapDeclsChanged _ [] = ([], False)
mapDeclsChanged xf (d::ds) =
  let (d2, c1) = xf d
  let (ds2, c2) = mapDeclsChanged xf ds
  (d2::ds2, c1 || c2)

-- ── generic Ty traversal ─────────────────────────────────────────────────────
-- `mapTyFull f t` applies `f` to EVERY Ty node in `t`, post-order (children
-- first, then the rebuilt node), OR-folding the change flags.  Effect rows nest,
-- so recursing the carried type of a `TyEffect` BEFORE applying `f` at that node
-- is what lets a transform see an already-rewritten inner row.
mapTyFull : (Ty -> (Ty, Bool)) -> Ty -> (Ty, Bool)
mapTyFull f ty =
  let (ty1, c1) = mapTyKids f ty
  let (ty2, c2) = f ty1
  (ty2, c1 || c2)

mapTyKids : (Ty -> (Ty, Bool)) -> Ty -> (Ty, Bool)
mapTyKids _ (TyCon n l) = (TyCon n l, False)
mapTyKids _ (TyVar n) = (TyVar n, False)
mapTyKids f (TyApp a b) =
  let (a2, ca) = mapTyFull f a
  let (b2, cb) = mapTyFull f b
  (TyApp a2 b2, ca || cb)
mapTyKids f (TyFun a b) =
  let (a2, ca) = mapTyFull f a
  let (b2, cb) = mapTyFull f b
  (TyFun a2 b2, ca || cb)
mapTyKids f (TyTuple ts) =
  let (ts2, c) = mapTyListB f ts
  (TyTuple ts2, c)
mapTyKids f (TyEffect es tail t) =
  let (t2, c) = mapTyFull f t
  (TyEffect es tail t2, c)
mapTyKids f (TyConstrained cs t) =
  let (cs2, cc) = mapConstraintsB f cs
  let (t2, ct) = mapTyFull f t
  (TyConstrained cs2 t2, cc || ct)

mapTyListB : (Ty -> (Ty, Bool)) -> List Ty -> (List Ty, Bool)
mapTyListB _ [] = ([], False)
mapTyListB f (t::ts) =
  let (t2, c1) = mapTyFull f t
  let (ts2, c2) = mapTyListB f ts
  (t2::ts2, c1 || c2)

mapConstraintsB : (Ty -> (Ty, Bool)) -> List Constraint -> (List Constraint, Bool)
mapConstraintsB _ [] = ([], False)
mapConstraintsB f ((Constraint iface tys)::rest) =
  let (tys2, c1) = mapTyListB f tys
  let (rest2, c2) = mapConstraintsB f rest
  (Constraint iface tys2 :: rest2, c1 || c2)

-- ── generic Decl traversal ───────────────────────────────────────────────────
-- Threads `f` through EVERY Ty position of a decl (verified against ast.mdk):
-- signatures, externs, `data` variant payloads, prop params, interface method
-- sigs (+ their default bodies' Exprs), impl heads + requires (+ method Exprs),
-- type aliases, newtypes, let-groups, and `@attr`-wrapped decls.  `DEffect`
-- decls carry no Ty and are left untouched (the effect-labels codemod warns
-- about them separately).
export mapTyInDecl : (Ty -> (Ty, Bool)) -> Decl -> (Decl, Bool)
mapTyInDecl f (DTypeSig pub n t) =
  let (t2, c) = mapTyFull f t
  (DTypeSig pub n t2, c)
mapTyInDecl f (DExtern pub n t) =
  let (t2, c) = mapTyFull f t
  (DExtern pub n t2, c)
mapTyInDecl f (DFunDef pub n ps e) =
  let (e2, c) = mapTyInExpr f e
  (DFunDef pub n ps e2, c)
mapTyInDecl f (DData vis n tps variants ders) =
  let (vs2, c) = mapVariantsB f variants
  (DData vis n tps vs2 ders, c)
mapTyInDecl _ (DUse pub path loc) = (DUse pub path loc, False)
mapTyInDecl _ (DEffect pub n dom) = (DEffect pub n dom, False)
mapTyInDecl f (DProp pub n params body) =
  let (params2, c1) = mapPropParamsB f params
  let (body2, c2) = mapTyInExpr f body
  (DProp pub n params2 body2, c1 || c2)
mapTyInDecl f (DTest pub n body) =
  let (b2, c) = mapTyInExpr f body
  (DTest pub n b2, c)
mapTyInDecl f (DBench pub n body) =
  let (b2, c) = mapTyInExpr f body
  (DBench pub n b2, c)
mapTyInDecl f (d@(DInterface { methods, ... })) =
  let (ms2, c) = mapIfaceMethodsB f methods
  (DInterface { d | methods = ms2 }, c)
mapTyInDecl f (d@(DImpl { tys, reqs, methods, ... })) =
  let (tys2, c1) = mapTyListB f tys
  let (reqs2, c2) = mapRequiresB f reqs
  let (ms2, c3) = mapImplMethodsB f methods
  (DImpl { d | tys = tys2, reqs = reqs2, methods = ms2 }, c1 || c2 || c3)
mapTyInDecl f (DTypeAlias pub n tps t) =
  let (t2, c) = mapTyFull f t
  (DTypeAlias pub n tps t2, c)
mapTyInDecl f (DNewtype pub n tps cn t ders) =
  let (t2, c) = mapTyFull f t
  (DNewtype pub n tps cn t2 ders, c)
mapTyInDecl f (DLetGroup pub binds) =
  let (bs2, c) = mapLetBindsB f binds
  (DLetGroup pub bs2, c)
mapTyInDecl f (DAttrib attrs d) =
  let (d2, c) = mapTyInDecl f d
  (DAttrib attrs d2, c)

mapVariantsB : (Ty -> (Ty, Bool)) -> List Variant -> (List Variant, Bool)
mapVariantsB _ [] = ([], False)
mapVariantsB f (v::vs) =
  let (v2, c1) = mapVariantB f v
  let (vs2, c2) = mapVariantsB f vs
  (v2::vs2, c1 || c2)

mapVariantB : (Ty -> (Ty, Bool)) -> Variant -> (Variant, Bool)
mapVariantB f (Variant n (ConPos tys)) =
  let (tys2, c) = mapTyListB f tys
  (Variant n (ConPos tys2), c)
mapVariantB f (Variant n (ConNamed fields omitted)) =
  let (fs2, c) = mapFieldsB f fields
  (Variant n (ConNamed fs2 omitted), c)

mapFieldsB : (Ty -> (Ty, Bool)) -> List Field -> (List Field, Bool)
mapFieldsB _ [] = ([], False)
mapFieldsB f ((Field n t)::rest) =
  let (t2, c1) = mapTyFull f t
  let (rest2, c2) = mapFieldsB f rest
  (Field n t2 :: rest2, c1 || c2)

mapPropParamsB : (Ty -> (Ty, Bool)) -> List PropParam -> (List PropParam, Bool)
mapPropParamsB _ [] = ([], False)
mapPropParamsB f ((PropParam n t)::rest) =
  let (t2, c1) = mapTyFull f t
  let (rest2, c2) = mapPropParamsB f rest
  (PropParam n t2 :: rest2, c1 || c2)

mapIfaceMethodsB : (Ty -> (Ty, Bool)) -> List IfaceMethod -> (List IfaceMethod, Bool)
mapIfaceMethodsB _ [] = ([], False)
mapIfaceMethodsB f (m::ms) =
  let (m2, c1) = mapIfaceMethodB f m
  let (ms2, c2) = mapIfaceMethodsB f ms
  (m2::ms2, c1 || c2)

mapIfaceMethodB : (Ty -> (Ty, Bool)) -> IfaceMethod -> (IfaceMethod, Bool)
mapIfaceMethodB f (IfaceMethod n ty None) =
  let (ty2, c) = mapTyFull f ty
  (IfaceMethod n ty2 None, c)
mapIfaceMethodB f (IfaceMethod n ty (Some (MethodDefault ps e))) =
  let (ty2, c1) = mapTyFull f ty
  let (e2, c2) = mapTyInExpr f e
  (IfaceMethod n ty2 (Some (MethodDefault ps e2)), c1 || c2)

mapRequiresB : (Ty -> (Ty, Bool)) -> List Require -> (List Require, Bool)
mapRequiresB _ [] = ([], False)
mapRequiresB f ((Require iface tys)::rest) =
  let (tys2, c1) = mapTyListB f tys
  let (rest2, c2) = mapRequiresB f rest
  (Require iface tys2 :: rest2, c1 || c2)

mapImplMethodsB : (Ty -> (Ty, Bool)) -> List ImplMethod -> (List ImplMethod, Bool)
mapImplMethodsB _ [] = ([], False)
mapImplMethodsB f ((ImplMethod n ps e)::rest) =
  let (e2, c1) = mapTyInExpr f e
  let (rest2, c2) = mapImplMethodsB f rest
  (ImplMethod n ps e2 :: rest2, c1 || c2)

mapLetBindsB : (Ty -> (Ty, Bool)) -> List LetBind -> (List LetBind, Bool)
mapLetBindsB _ [] = ([], False)
mapLetBindsB f ((LetBind n clauses)::rest) =
  let (cs2, c1) = mapFunClausesB f clauses
  let (rest2, c2) = mapLetBindsB f rest
  (LetBind n cs2 :: rest2, c1 || c2)

mapFunClausesB : (Ty -> (Ty, Bool)) -> List FunClause -> (List FunClause, Bool)
mapFunClausesB _ [] = ([], False)
mapFunClausesB f ((FunClause ps e)::rest) =
  let (e2, c1) = mapTyInExpr f e
  let (rest2, c2) = mapFunClausesB f rest
  (FunClause ps e2 :: rest2, c1 || c2)

-- ── generic Expr traversal (TOTAL over ast.mdk's Expr) ───────────────────────
-- Ty appears in an Expr ONLY at `EAnnot`/`EHeadAnnot`, but every Expr-carrying
-- constructor must be walked to REACH them.  This mirrors desugar.mdk's `mapKids`
-- constructor-for-constructor (kept in lockstep with the AST — a new Expr node
-- there makes THIS match non-exhaustive, a loud build error), but threads the
-- change flag purely.  Ref-typed fields (EBinOp/EUnOp/EFieldAccess/ESlice/EIndex
-- /ERecordUpdate/EMethodAt/EDictAt/ENumLit) are carried through unchanged.
export mapTyInExpr : (Ty -> (Ty, Bool)) -> Expr -> (Expr, Bool)
mapTyInExpr _ (ELit l) = (ELit l, False)
mapTyInExpr _ (EVar n) = (EVar n, False)
mapTyInExpr f (EApp a b) =
  let (a2, ca) = mapTyInExpr f a
  let (b2, cb) = mapTyInExpr f b
  (EApp a2 b2, ca || cb)
mapTyInExpr f (ELam ps b) =
  let (b2, c) = mapTyInExpr f b
  (ELam ps b2, c)
mapTyInExpr f (ELet m r p e1 e2) =
  let (e1b, c1) = mapTyInExpr f e1
  let (e2b, c2) = mapTyInExpr f e2
  (ELet m r p e1b e2b, c1 || c2)
mapTyInExpr f (EMatch e0 arms) =
  let (e0b, c1) = mapTyInExpr f e0
  let (arms2, c2) = mapArmsB f arms
  (EMatch e0b arms2, c1 || c2)
mapTyInExpr f (EIf c t el) =
  let (cb, c1) = mapTyInExpr f c
  let (tb, c2) = mapTyInExpr f t
  let (elb, c3) = mapTyInExpr f el
  (EIf cb tb elb, c1 || c2 || c3)
mapTyInExpr f (EBinOp op a b r) =
  let (a2, ca) = mapTyInExpr f a
  let (b2, cb) = mapTyInExpr f b
  (EBinOp op a2 b2 r, ca || cb)
mapTyInExpr f (EUnOp op a r) =
  let (a2, c) = mapTyInExpr f a
  (EUnOp op a2 r, c)
mapTyInExpr f (EInfix op a b) =
  let (a2, ca) = mapTyInExpr f a
  let (b2, cb) = mapTyInExpr f b
  (EInfix op a2 b2, ca || cb)
mapTyInExpr f (EFieldAccess e0 n r) =
  let (e0b, c) = mapTyInExpr f e0
  (EFieldAccess e0b n r, c)
mapTyInExpr f (ETuple es) =
  let (es2, c) = mapExprsB f es
  (ETuple es2, c)
mapTyInExpr f (EListLit es) =
  let (es2, c) = mapExprsB f es
  (EListLit es2, c)
mapTyInExpr f (EArrayLit es) =
  let (es2, c) = mapExprsB f es
  (EArrayLit es2, c)
mapTyInExpr f (ERangeList lo hi incl) =
  let (lo2, c1) = mapTyInExpr f lo
  let (hi2, c2) = mapTyInExpr f hi
  (ERangeList lo2 hi2 incl, c1 || c2)
mapTyInExpr f (ERangeArray lo hi incl) =
  let (lo2, c1) = mapTyInExpr f lo
  let (hi2, c2) = mapTyInExpr f hi
  (ERangeArray lo2 hi2 incl, c1 || c2)
mapTyInExpr f (ESlice e0 lo hi incl r) =
  let (e0b, c1) = mapTyInExpr f e0
  let (lo2, c2) = mapTyInExpr f lo
  let (hi2, c3) = mapTyInExpr f hi
  (ESlice e0b lo2 hi2 incl r, c1 || c2 || c3)
mapTyInExpr f (ELetGroup binds e2) =
  let (bs2, c1) = mapLetBindsB f binds
  let (e2b, c2) = mapTyInExpr f e2
  (ELetGroup bs2 e2b, c1 || c2)
mapTyInExpr _ (ESection (SecBare op)) = (ESection (SecBare op), False)
mapTyInExpr f (ESection (SecRight op e0)) =
  let (e0b, c) = mapTyInExpr f e0
  (ESection (SecRight op e0b), c)
mapTyInExpr f (ESection (SecLeft e0 op)) =
  let (e0b, c) = mapTyInExpr f e0
  (ESection (SecLeft e0b op), c)
mapTyInExpr f (EIndex e0 i r) =
  let (e0b, c1) = mapTyInExpr f e0
  let (i2, c2) = mapTyInExpr f i
  (EIndex e0b i2 r, c1 || c2)
mapTyInExpr f (EAnnot e0 t) =
  let (e0b, c1) = mapTyInExpr f e0
  let (t2, c2) = mapTyFull f t
  (EAnnot e0b t2, c1 || c2)
mapTyInExpr f (EHeadAnnot e0 t) =
  let (e0b, c1) = mapTyInExpr f e0
  let (t2, c2) = mapTyFull f t
  (EHeadAnnot e0b t2, c1 || c2)
mapTyInExpr f (EBlock stmts) =
  let (ss2, c) = mapDoStmtsB f stmts
  (EBlock ss2, c)
mapTyInExpr f (EDo stmts) =
  let (ss2, c) = mapDoStmtsB f stmts
  (EDo ss2, c)
mapTyInExpr f (EStringInterp parts) =
  let (ps2, c) = mapInterpsB f parts
  (EStringInterp ps2, c)
mapTyInExpr f (EGuards arms) =
  let (as2, c) = mapGuardArmsB f arms
  (EGuards as2, c)
mapTyInExpr f (ERecordCreate n fs) =
  let (fs2, c) = mapFieldAssignsB f fs
  (ERecordCreate n fs2, c)
mapTyInExpr f (ERecordUpdate e0 fs r) =
  let (e0b, c1) = mapTyInExpr f e0
  let (fs2, c2) = mapFieldAssignsB f fs
  (ERecordUpdate e0b fs2 r, c1 || c2)
mapTyInExpr f (EVariantUpdate cn e0 fs) =
  let (e0b, c1) = mapTyInExpr f e0
  let (fs2, c2) = mapFieldAssignsB f fs
  (EVariantUpdate cn e0b fs2, c1 || c2)
mapTyInExpr f (EMapLit n kvs) =
  let (kvs2, c) = mapKvsB f kvs
  (EMapLit n kvs2, c)
mapTyInExpr f (ESetLit n es) =
  let (es2, c) = mapExprsB f es
  (ESetLit n es2, c)
mapTyInExpr f (EAsPat n e0) =
  let (e0b, c) = mapTyInExpr f e0
  (EAsPat n e0b, c)
mapTyInExpr _ (EMethodRef n) = (EMethodRef n, False)
mapTyInExpr _ (EDictApp n) = (EDictApp n, False)
mapTyInExpr _ (EVarAt n a) = (EVarAt n a, False)
mapTyInExpr _ (EMethodAt n r1 r2 r3) = (EMethodAt n r1 r2 r3, False)
mapTyInExpr _ (EDictAt n r) = (EDictAt n r, False)
mapTyInExpr f (ELoc l e) =
  let (e2, c) = mapTyInExpr f e
  (ELoc l e2, c)
mapTyInExpr f (EDoOrigin l e) =
  let (e2, c) = mapTyInExpr f e
  (EDoOrigin l e2, c)
mapTyInExpr _ (ENumLit n rf rr lx) = (ENumLit n rf rr lx, False)

mapExprsB : (Ty -> (Ty, Bool)) -> List Expr -> (List Expr, Bool)
mapExprsB _ [] = ([], False)
mapExprsB f (e::es) =
  let (e2, c1) = mapTyInExpr f e
  let (es2, c2) = mapExprsB f es
  (e2::es2, c1 || c2)

mapArmsB : (Ty -> (Ty, Bool)) -> List Arm -> (List Arm, Bool)
mapArmsB _ [] = ([], False)
mapArmsB f ((Arm p gs b)::rest) =
  let (gs2, c1) = mapGuardsB f gs
  let (b2, c2) = mapTyInExpr f b
  let (rest2, c3) = mapArmsB f rest
  (Arm p gs2 b2 :: rest2, c1 || c2 || c3)

mapGuardsB : (Ty -> (Ty, Bool)) -> List Guard -> (List Guard, Bool)
mapGuardsB _ [] = ([], False)
mapGuardsB f ((GBool g)::rest) =
  let (g2, c1) = mapTyInExpr f g
  let (rest2, c2) = mapGuardsB f rest
  (GBool g2 :: rest2, c1 || c2)
mapGuardsB f ((GBind p g)::rest) =
  let (g2, c1) = mapTyInExpr f g
  let (rest2, c2) = mapGuardsB f rest
  (GBind p g2 :: rest2, c1 || c2)

mapGuardArmsB : (Ty -> (Ty, Bool)) -> List GuardArm -> (List GuardArm, Bool)
mapGuardArmsB _ [] = ([], False)
mapGuardArmsB f ((GuardArm gs b)::rest) =
  let (gs2, c1) = mapGuardsB f gs
  let (b2, c2) = mapTyInExpr f b
  let (rest2, c3) = mapGuardArmsB f rest
  (GuardArm gs2 b2 :: rest2, c1 || c2 || c3)

mapDoStmtsB : (Ty -> (Ty, Bool)) -> List DoStmt -> (List DoStmt, Bool)
mapDoStmtsB _ [] = ([], False)
mapDoStmtsB f (s::ss) =
  let (s2, c1) = mapDoStmtB f s
  let (ss2, c2) = mapDoStmtsB f ss
  (s2::ss2, c1 || c2)

mapDoStmtB : (Ty -> (Ty, Bool)) -> DoStmt -> (DoStmt, Bool)
mapDoStmtB f (DoExpr e) =
  let (e2, c) = mapTyInExpr f e
  (DoExpr e2, c)
mapDoStmtB f (DoBind p e) =
  let (e2, c) = mapTyInExpr f e
  (DoBind p e2, c)
mapDoStmtB f (DoLet m r p e) =
  let (e2, c) = mapTyInExpr f e
  (DoLet m r p e2, c)
mapDoStmtB f (DoAssign x e) =
  let (e2, c) = mapTyInExpr f e
  (DoAssign x e2, c)
mapDoStmtB f (DoFieldAssign x fs e) =
  let (e2, c) = mapTyInExpr f e
  (DoFieldAssign x fs e2, c)

mapInterpsB : (Ty -> (Ty, Bool)) -> List InterpPart -> (List InterpPart, Bool)
mapInterpsB _ [] = ([], False)
mapInterpsB f (InterpStr s :: rest0) =
  -- InterpStr carries no Expr; recurse the rest with the real transform.
  let (rest2, c) = mapInterpsB f rest0
  (InterpStr s :: rest2, c)
mapInterpsB f ((InterpExpr e)::rest) =
  let (e2, c1) = mapTyInExpr f e
  let (rest2, c2) = mapInterpsB f rest
  (InterpExpr e2 :: rest2, c1 || c2)

mapFieldAssignsB : (Ty -> (Ty, Bool)) -> List FieldAssign -> (List FieldAssign, Bool)
mapFieldAssignsB _ [] = ([], False)
mapFieldAssignsB f ((FieldAssign n v)::rest) =
  let (v2, c1) = mapTyInExpr f v
  let (rest2, c2) = mapFieldAssignsB f rest
  (FieldAssign n v2 :: rest2, c1 || c2)

mapKvsB : (Ty -> (Ty, Bool)) -> List (Expr, Expr) -> (List (Expr, Expr), Bool)
mapKvsB _ [] = ([], False)
mapKvsB f ((k, v)::rest) =
  let (k2, c1) = mapTyInExpr f k
  let (v2, c2) = mapTyInExpr f v
  let (rest2, c3) = mapKvsB f rest
  ((k2, v2)::rest2, c1 || c2 || c3)

-- ── the `effect-labels` transform ────────────────────────────────────────────
-- Per-label action, parsed from `--strip`/`--rename`.
data EffAction = ADrop | ARename String

mkEffectLabels : List String -> Result String (Decl -> (Decl, Bool))
mkEffectLabels args = match parseEffectArgs args []
  Err msg => Err msg
  Ok [] => Err "need at least one --strip <labels> or --rename Old=New"
  Ok acts => Ok (mapTyInDecl (effTyNode acts))

-- Parse the codemod-specific args into a (label -> action) table.  `--strip`
-- and `--rename` each consume a following value (the CLI's generic flag/value
-- splitter has already paired them).
parseEffectArgs : List String -> List (String, EffAction) -> Result String (List (String, EffAction))
parseEffectArgs [] acc = Ok (reverseL acc)
parseEffectArgs ("--strip"::v::rest) acc =
  parseEffectArgs rest (prependDrops (splitOnChar ',' v) acc)
parseEffectArgs ("--rename"::v::rest) acc = match splitOnChar '=' v
  [old, nw] =>
    if old == "" || nw == "" then
      Err "--rename expects Old=New, got '\{v}'"
    else
      parseEffectArgs rest ((old, ARename nw)::acc)
  _ => Err "--rename expects Old=New, got '\{v}'"
parseEffectArgs ["--strip"] _ =
  Err "--strip requires a value (e.g. --strip Rand,Net)"
parseEffectArgs ["--rename"] _ =
  Err "--rename requires a value (e.g. --rename Old=New)"
parseEffectArgs (x::_) _ = Err "unknown argument '\{x}'"

prependDrops : List String -> List (String, EffAction) -> List (String, EffAction)
prependDrops [] acc = acc
prependDrops (n::ns) acc =
  if n == "" then
    prependDrops ns acc
  else
    prependDrops ns ((n, ADrop)::acc)

-- Apply the action table at one Ty node.  Only `TyEffect` nodes are affected;
-- everything else passes through unchanged.  (The child type was already
-- rewritten by mapTyFull's post-order recursion.)
effTyNode : List (String, EffAction) -> Ty -> (Ty, Bool)
effTyNode acts (TyEffect es tail t) = rewriteRow acts es tail t
effTyNode _ ty = (ty, False)

rewriteRow : List (String, EffAction) -> List (String, Option String) -> Option String -> Ty -> (Ty, Bool)
rewriteRow acts es tail t =
  let stepped = map (applyAtom acts) es
  let anyChanged = anyList sndB stepped
  let kept = collectKept stepped
  let deduped = dedupeAtoms kept
  let dedupChanged = listLen deduped != listLen kept
  let changed = anyChanged || dedupChanged
  match deduped
    [] => match tail
      -- fully-stripped, no tail → an unannotated (pure) arrow: drop the node.
      None => if changed then (t, True) else (TyEffect [] None t, False)
      -- an open row with no atoms still prints (`<v>`) and round-trips.
      Some v => (TyEffect [] (Some v) t, changed)
    _ => (TyEffect deduped tail t, changed)

applyAtom : List (String, EffAction) -> (String, Option String) -> (Option (String, Option String), Bool)
applyAtom acts (label, dom) = match lookupAssoc label acts
  None => (Some (label, dom), False)
  Some ADrop => (None, True)
  Some (ARename nw) => (Some (nw, dom), True)

sndB : (a, Bool) -> Bool
sndB (_, b) = b

collectKept : List (Option (String, Option String), Bool) -> List (String, Option String)
collectKept [] = []
collectKept ((None, _)::rest) = collectKept rest
collectKept ((Some a, _)::rest) = a :: collectKept rest

-- Order-preserving dedupe (keep first) — a rename can make two atoms identical.
dedupeAtoms : List (String, Option String) -> List (String, Option String)
dedupeAtoms xs = dedupeGo xs []

dedupeGo : List (String, Option String) -> List (String, Option String) -> List (String, Option String)
dedupeGo [] _ = []
dedupeGo (a::rest) seen =
  if atomElem a seen then
    dedupeGo rest seen
  else
    a :: dedupeGo rest (a::seen)

atomElem : (String, Option String) -> List (String, Option String) -> Bool
atomElem _ [] = False
atomElem a (b::bs) = atomEq a b || atomElem a bs

atomEq : (String, Option String) -> (String, Option String) -> Bool
atomEq (l1, d1) (l2, d2) = l1 == l2 && domEq d1 d2

domEq : Option String -> Option String -> Bool
domEq None None = True
domEq (Some x) (Some y) = x == y
domEq _ _ = False

-- Advisory warnings: a `DEffect` that DECLARES a targeted label is left
-- untouched (the codemod only rewrites row USES), so flag it for the operator.
warnEffectLabels : List String -> List Decl -> List String
warnEffectLabels args decls = match parseEffectArgs args []
  Err _ => []
  Ok acts => declEffectWarns acts decls

declEffectWarns : List (String, EffAction) -> List Decl -> List String
declEffectWarns _ [] = []
declEffectWarns acts (d::ds) = declEffectWarn acts d ++ declEffectWarns acts ds

declEffectWarn : List (String, EffAction) -> Decl -> List String
declEffectWarn acts (DEffect _ name _) = match lookupAssoc name acts
  None => []
  Some _ => [
    "'effect \{name}' is declared here but effect-labels targets \{name}; the declaration is left untouched"
  ]
declEffectWarn acts (DAttrib _ d) = declEffectWarn acts d
declEffectWarn _ _ = []
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" true) (mem "Constraint" true) (mem "Expr" true) (mem "Section" true) (mem "Arm" true) (mem "Guard" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true) (mem "PropParam" true) (mem "IfaceMethod" true) (mem "MethodDefault" true) (mem "Require" true) (mem "ImplMethod" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Field" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseResult" false) (mem "ParseError" false) (mem "parseWithPositions" false) (mem "positionsDecls" false) (mem "positionsVariantLines" false) (mem "positionsChainLines" false) (mem "positionsLastContentLine" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "collectComments" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatProgram" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "splitOnChar" false) (mem "joinNl" false) (mem "anyList" false))))
(DData Public "Codemod" () ((variant "Codemod" (ConNamed (field "name" (TyCon "String")) (field "descr" (TyCon "String")) (field "argHelp" (TyCon "String")) (field "mk" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool")))))) (field "warn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))))) ())
(DTypeSig true "allCodemods" (TyApp (TyCon "List") (TyCon "Codemod")))
(DFunDef false "allCodemods" () (EListLit (EVar "effectLabelsCodemod")))
(DTypeSig false "effectLabelsCodemod" (TyCon "Codemod"))
(DFunDef false "effectLabelsCodemod" () (ERecordCreate "Codemod" ((fa "name" (ELit (LString "effect-labels"))) (fa "descr" (ELit (LString "strip and/or rename effect-row labels (e.g. <Rand>, <Net>, …)"))) (fa "argHelp" (ELit (LString "--strip L1,L2   --rename Old=New   (repeatable)"))) (fa "mk" (EVar "mkEffectLabels")) (fa "warn" (EVar "warnEffectLabels")))))
(DTypeSig true "codemodName" (TyFun (TyCon "Codemod") (TyCon "String")))
(DFunDef false "codemodName" ((PRec "Codemod" ((rf "name" None)) true)) (EVar "name"))
(DTypeSig true "codemodDescr" (TyFun (TyCon "Codemod") (TyCon "String")))
(DFunDef false "codemodDescr" ((PRec "Codemod" ((rf "descr" None)) true)) (EVar "descr"))
(DTypeSig true "codemodArgHelp" (TyFun (TyCon "Codemod") (TyCon "String")))
(DFunDef false "codemodArgHelp" ((PRec "Codemod" ((rf "argHelp" None)) true)) (EVar "argHelp"))
(DTypeSig true "codemodMk" (TyFun (TyCon "Codemod") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool")))))))
(DFunDef false "codemodMk" ((PRec "Codemod" ((rf "mk" None)) true) (PVar "args")) (EApp (EVar "mk") (EVar "args")))
(DTypeSig true "codemodWarnDecls" (TyFun (TyCon "Codemod") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "codemodWarnDecls" ((PRec "Codemod" ((rf "warn" None)) true) (PVar "args") (PVar "decls")) (EApp (EApp (EVar "warn") (EVar "args")) (EVar "decls")))
(DTypeSig true "findCodemod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Codemod"))))
(DFunDef false "findCodemod" ((PVar "name")) (EApp (EApp (EVar "findCodemodGo") (EVar "name")) (EVar "allCodemods")))
(DTypeSig false "findCodemodGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Codemod")) (TyApp (TyCon "Option") (TyCon "Codemod")))))
(DFunDef false "findCodemodGo" (PWild (PList)) (EVar "None"))
(DFunDef false "findCodemodGo" ((PVar "name") (PCons (PVar "c") (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "codemodName") (EVar "c")) (EVar "name")) (EApp (EVar "Some") (EVar "c")) (EApp (EApp (EVar "findCodemodGo") (EVar "name")) (EVar "rest"))))
(DTypeSig true "codemodListing" (TyCon "String"))
(DFunDef false "codemodListing" () (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "codemodListingLine")) (EVar "allCodemods"))))
(DTypeSig false "codemodListingLine" (TyFun (TyCon "Codemod") (TyCon "String")))
(DFunDef false "codemodListingLine" ((PVar "c")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EApp (EVar "codemodName") (EVar "c")))) (ELit (LString " — "))) (EApp (EVar "display") (EApp (EVar "codemodDescr") (EVar "c")))) (ELit (LString "\n    "))) (EApp (EVar "display") (EApp (EVar "codemodArgHelp") (EVar "c")))) (ELit (LString ""))))
(DTypeSig true "codemodSource" (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "codemodSource" ((PVar "xf") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PTuple (PVar "decls2") (PVar "changed")) (EApp (EApp (EVar "mapDeclsChanged") (EVar "xf")) (EVar "decls"))) (DoExpr (EIf (EApp (EVar "not") (EVar "changed")) (EApp (EVar "Ok") (EVar "None")) (EBlock (DoLet false false (PVar "comments") (EApp (EVar "collectComments") (EVar "src"))) (DoExpr (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "formatProgram") (EVar "decls2")) (EApp (EVar "positionsDecls") (EVar "pos"))) (EApp (EVar "positionsVariantLines") (EVar "pos"))) (EApp (EVar "positionsChainLines") (EVar "pos"))) (EVar "comments")) (EApp (EVar "positionsLastContentLine") (EVar "pos"))) (EVar "src"))))))))))))
(DTypeSig false "mapDeclsChanged" (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))))
(DFunDef false "mapDeclsChanged" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapDeclsChanged" ((PVar "xf") (PCons (PVar "d") (PVar "ds"))) (EBlock (DoLet false false (PTuple (PVar "d2") (PVar "c1")) (EApp (EVar "xf") (EVar "d"))) (DoLet false false (PTuple (PVar "ds2") (PVar "c2")) (EApp (EApp (EVar "mapDeclsChanged") (EVar "xf")) (EVar "ds"))) (DoExpr (ETuple (EBinOp "::" (EVar "d2") (EVar "ds2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapTyFull" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "mapTyFull" ((PVar "f") (PVar "ty")) (EBlock (DoLet false false (PTuple (PVar "ty1") (PVar "c1")) (EApp (EApp (EVar "mapTyKids") (EVar "f")) (EVar "ty"))) (DoLet false false (PTuple (PVar "ty2") (PVar "c2")) (EApp (EVar "f") (EVar "ty1"))) (DoExpr (ETuple (EVar "ty2") (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapTyKids" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "mapTyKids" (PWild (PCon "TyCon" (PVar "n") (PVar "l"))) (ETuple (EApp (EApp (EVar "TyCon") (EVar "n")) (EVar "l")) (EVar "False")))
(DFunDef false "mapTyKids" (PWild (PCon "TyVar" (PVar "n"))) (ETuple (EApp (EVar "TyVar") (EVar "n")) (EVar "False")))
(DFunDef false "mapTyKids" ((PVar "f") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PTuple (PVar "a2") (PVar "ca")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "a"))) (DoLet false false (PTuple (PVar "b2") (PVar "cb")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "b"))) (DoExpr (ETuple (EApp (EApp (EVar "TyApp") (EVar "a2")) (EVar "b2")) (EBinOp "||" (EVar "ca") (EVar "cb"))))))
(DFunDef false "mapTyKids" ((PVar "f") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PTuple (PVar "a2") (PVar "ca")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "a"))) (DoLet false false (PTuple (PVar "b2") (PVar "cb")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "b"))) (DoExpr (ETuple (EApp (EApp (EVar "TyFun") (EVar "a2")) (EVar "b2")) (EBinOp "||" (EVar "ca") (EVar "cb"))))))
(DFunDef false "mapTyKids" ((PVar "f") (PCon "TyTuple" (PVar "ts"))) (EBlock (DoLet false false (PTuple (PVar "ts2") (PVar "c")) (EApp (EApp (EVar "mapTyListB") (EVar "f")) (EVar "ts"))) (DoExpr (ETuple (EApp (EVar "TyTuple") (EVar "ts2")) (EVar "c")))))
(DFunDef false "mapTyKids" ((PVar "f") (PCon "TyEffect" (PVar "es") (PVar "tail") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "t2") (PVar "c")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "TyEffect") (EVar "es")) (EVar "tail")) (EVar "t2")) (EVar "c")))))
(DFunDef false "mapTyKids" ((PVar "f") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "cs2") (PVar "cc")) (EApp (EApp (EVar "mapConstraintsB") (EVar "f")) (EVar "cs"))) (DoLet false false (PTuple (PVar "t2") (PVar "ct")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoExpr (ETuple (EApp (EApp (EVar "TyConstrained") (EVar "cs2")) (EVar "t2")) (EBinOp "||" (EVar "cc") (EVar "ct"))))))
(DTypeSig false "mapTyListB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool")))))
(DFunDef false "mapTyListB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapTyListB" ((PVar "f") (PCons (PVar "t") (PVar "ts"))) (EBlock (DoLet false false (PTuple (PVar "t2") (PVar "c1")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoLet false false (PTuple (PVar "ts2") (PVar "c2")) (EApp (EApp (EVar "mapTyListB") (EVar "f")) (EVar "ts"))) (DoExpr (ETuple (EBinOp "::" (EVar "t2") (EVar "ts2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapConstraintsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyTuple (TyApp (TyCon "List") (TyCon "Constraint")) (TyCon "Bool")))))
(DFunDef false "mapConstraintsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapConstraintsB" ((PVar "f") (PCons (PCon "Constraint" (PVar "iface") (PVar "tys")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "tys2") (PVar "c1")) (EApp (EApp (EVar "mapTyListB") (EVar "f")) (EVar "tys"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapConstraintsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "Constraint") (EVar "iface")) (EVar "tys2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig true "mapTyInDecl" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DTypeSig" (PVar "pub") (PVar "n") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "t2") (PVar "c")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "DTypeSig") (EVar "pub")) (EVar "n")) (EVar "t2")) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DExtern" (PVar "pub") (PVar "n") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "t2") (PVar "c")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "DExtern") (EVar "pub")) (EVar "n")) (EVar "t2")) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EVar "e2")) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DData" (PVar "vis") (PVar "n") (PVar "tps") (PVar "variants") (PVar "ders"))) (EBlock (DoLet false false (PTuple (PVar "vs2") (PVar "c")) (EApp (EApp (EVar "mapVariantsB") (EVar "f")) (EVar "variants"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "DData") (EVar "vis")) (EVar "n")) (EVar "tps")) (EVar "vs2")) (EVar "ders")) (EVar "c")))))
(DFunDef false "mapTyInDecl" (PWild (PCon "DUse" (PVar "pub") (PVar "path") (PVar "loc"))) (ETuple (EApp (EApp (EApp (EVar "DUse") (EVar "pub")) (EVar "path")) (EVar "loc")) (EVar "False")))
(DFunDef false "mapTyInDecl" (PWild (PCon "DEffect" (PVar "pub") (PVar "n") (PVar "dom"))) (ETuple (EApp (EApp (EApp (EVar "DEffect") (EVar "pub")) (EVar "n")) (EVar "dom")) (EVar "False")))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DProp" (PVar "pub") (PVar "n") (PVar "params") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "params2") (PVar "c1")) (EApp (EApp (EVar "mapPropParamsB") (EVar "f")) (EVar "params"))) (DoLet false false (PTuple (PVar "body2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "body"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "n")) (EVar "params2")) (EVar "body2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DTest" (PVar "pub") (PVar "n") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "b2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "body"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "n")) (EVar "b2")) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DBench" (PVar "pub") (PVar "n") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "b2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "body"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "DBench") (EVar "pub")) (EVar "n")) (EVar "b2")) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EBlock (DoLet false false (PTuple (PVar "ms2") (PVar "c")) (EApp (EApp (EVar "mapIfaceMethodsB") (EVar "f")) (EVar "methods"))) (DoExpr (ETuple (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EVar "ms2")))) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PAs "d" (PRec "DImpl" ((rf "tys" None) (rf "reqs" None) (rf "methods" None)) true))) (EBlock (DoLet false false (PTuple (PVar "tys2") (PVar "c1")) (EApp (EApp (EVar "mapTyListB") (EVar "f")) (EVar "tys"))) (DoLet false false (PTuple (PVar "reqs2") (PVar "c2")) (EApp (EApp (EVar "mapRequiresB") (EVar "f")) (EVar "reqs"))) (DoLet false false (PTuple (PVar "ms2") (PVar "c3")) (EApp (EApp (EVar "mapImplMethodsB") (EVar "f")) (EVar "methods"))) (DoExpr (ETuple (EVariantUpdate "DImpl" (EVar "d") ((fa "tys" (EVar "tys2")) (fa "reqs" (EVar "reqs2")) (fa "methods" (EVar "ms2")))) (EBinOp "||" (EBinOp "||" (EVar "c1") (EVar "c2")) (EVar "c3"))))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DTypeAlias" (PVar "pub") (PVar "n") (PVar "tps") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "t2") (PVar "c")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "DTypeAlias") (EVar "pub")) (EVar "n")) (EVar "tps")) (EVar "t2")) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DNewtype" (PVar "pub") (PVar "n") (PVar "tps") (PVar "cn") (PVar "t") (PVar "ders"))) (EBlock (DoLet false false (PTuple (PVar "t2") (PVar "c")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DNewtype") (EVar "pub")) (EVar "n")) (EVar "tps")) (EVar "cn")) (EVar "t2")) (EVar "ders")) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EBlock (DoLet false false (PTuple (PVar "bs2") (PVar "c")) (EApp (EApp (EVar "mapLetBindsB") (EVar "f")) (EVar "binds"))) (DoExpr (ETuple (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EVar "bs2")) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EBlock (DoLet false false (PTuple (PVar "d2") (PVar "c")) (EApp (EApp (EVar "mapTyInDecl") (EVar "f")) (EVar "d"))) (DoExpr (ETuple (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EVar "d2")) (EVar "c")))))
(DTypeSig false "mapVariantsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyTuple (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Bool")))))
(DFunDef false "mapVariantsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapVariantsB" ((PVar "f") (PCons (PVar "v") (PVar "vs"))) (EBlock (DoLet false false (PTuple (PVar "v2") (PVar "c1")) (EApp (EApp (EVar "mapVariantB") (EVar "f")) (EVar "v"))) (DoLet false false (PTuple (PVar "vs2") (PVar "c2")) (EApp (EApp (EVar "mapVariantsB") (EVar "f")) (EVar "vs"))) (DoExpr (ETuple (EBinOp "::" (EVar "v2") (EVar "vs2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapVariantB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyCon "Variant") (TyTuple (TyCon "Variant") (TyCon "Bool")))))
(DFunDef false "mapVariantB" ((PVar "f") (PCon "Variant" (PVar "n") (PCon "ConPos" (PVar "tys")))) (EBlock (DoLet false false (PTuple (PVar "tys2") (PVar "c")) (EApp (EApp (EVar "mapTyListB") (EVar "f")) (EVar "tys"))) (DoExpr (ETuple (EApp (EApp (EVar "Variant") (EVar "n")) (EApp (EVar "ConPos") (EVar "tys2"))) (EVar "c")))))
(DFunDef false "mapVariantB" ((PVar "f") (PCon "Variant" (PVar "n") (PCon "ConNamed" (PVar "fields") (PVar "omitted")))) (EBlock (DoLet false false (PTuple (PVar "fs2") (PVar "c")) (EApp (EApp (EVar "mapFieldsB") (EVar "f")) (EVar "fields"))) (DoExpr (ETuple (EApp (EApp (EVar "Variant") (EVar "n")) (EApp (EApp (EVar "ConNamed") (EVar "fs2")) (EVar "omitted"))) (EVar "c")))))
(DTypeSig false "mapFieldsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyTuple (TyApp (TyCon "List") (TyCon "Field")) (TyCon "Bool")))))
(DFunDef false "mapFieldsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapFieldsB" ((PVar "f") (PCons (PCon "Field" (PVar "n") (PVar "t")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "t2") (PVar "c1")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapFieldsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "Field") (EVar "n")) (EVar "t2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapPropParamsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyTuple (TyApp (TyCon "List") (TyCon "PropParam")) (TyCon "Bool")))))
(DFunDef false "mapPropParamsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapPropParamsB" ((PVar "f") (PCons (PCon "PropParam" (PVar "n") (PVar "t")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "t2") (PVar "c1")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapPropParamsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "PropParam") (EVar "n")) (EVar "t2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapIfaceMethodsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyTuple (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyCon "Bool")))))
(DFunDef false "mapIfaceMethodsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapIfaceMethodsB" ((PVar "f") (PCons (PVar "m") (PVar "ms"))) (EBlock (DoLet false false (PTuple (PVar "m2") (PVar "c1")) (EApp (EApp (EVar "mapIfaceMethodB") (EVar "f")) (EVar "m"))) (DoLet false false (PTuple (PVar "ms2") (PVar "c2")) (EApp (EApp (EVar "mapIfaceMethodsB") (EVar "f")) (EVar "ms"))) (DoExpr (ETuple (EBinOp "::" (EVar "m2") (EVar "ms2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapIfaceMethodB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyCon "IfaceMethod") (TyTuple (TyCon "IfaceMethod") (TyCon "Bool")))))
(DFunDef false "mapIfaceMethodB" ((PVar "f") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None"))) (EBlock (DoLet false false (PTuple (PVar "ty2") (PVar "c")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "ty"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty2")) (EVar "None")) (EVar "c")))))
(DFunDef false "mapIfaceMethodB" ((PVar "f") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "e"))))) (EBlock (DoLet false false (PTuple (PVar "ty2") (PVar "c1")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "ty"))) (DoLet false false (PTuple (PVar "e2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty2")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "ps")) (EVar "e2")))) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapRequiresB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyTuple (TyApp (TyCon "List") (TyCon "Require")) (TyCon "Bool")))))
(DFunDef false "mapRequiresB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapRequiresB" ((PVar "f") (PCons (PCon "Require" (PVar "iface") (PVar "tys")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "tys2") (PVar "c1")) (EApp (EApp (EVar "mapTyListB") (EVar "f")) (EVar "tys"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapRequiresB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "Require") (EVar "iface")) (EVar "tys2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapImplMethodsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyTuple (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyCon "Bool")))))
(DFunDef false "mapImplMethodsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapImplMethodsB" ((PVar "f") (PCons (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapImplMethodsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps")) (EVar "e2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapLetBindsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyTuple (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Bool")))))
(DFunDef false "mapLetBindsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapLetBindsB" ((PVar "f") (PCons (PCon "LetBind" (PVar "n") (PVar "clauses")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "cs2") (PVar "c1")) (EApp (EApp (EVar "mapFunClausesB") (EVar "f")) (EVar "clauses"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapLetBindsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "LetBind") (EVar "n")) (EVar "cs2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapFunClausesB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyTuple (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Bool")))))
(DFunDef false "mapFunClausesB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapFunClausesB" ((PVar "f") (PCons (PCon "FunClause" (PVar "ps") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapFunClausesB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "e2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig true "mapTyInExpr" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyCon "Expr") (TyTuple (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "mapTyInExpr" (PWild (PCon "ELit" (PVar "l"))) (ETuple (EApp (EVar "ELit") (EVar "l")) (EVar "False")))
(DFunDef false "mapTyInExpr" (PWild (PCon "EVar" (PVar "n"))) (ETuple (EApp (EVar "EVar") (EVar "n")) (EVar "False")))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EApp" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PTuple (PVar "a2") (PVar "ca")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "a"))) (DoLet false false (PTuple (PVar "b2") (PVar "cb")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "b"))) (DoExpr (ETuple (EApp (EApp (EVar "EApp") (EVar "a2")) (EVar "b2")) (EBinOp "||" (EVar "ca") (EVar "cb"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ELam" (PVar "ps") (PVar "b"))) (EBlock (DoLet false false (PTuple (PVar "b2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "b"))) (DoExpr (ETuple (EApp (EApp (EVar "ELam") (EVar "ps")) (EVar "b2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ELet" (PVar "m") (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PTuple (PVar "e1b") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e1"))) (DoLet false false (PTuple (PVar "e2b") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e2"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EVar "p")) (EVar "e1b")) (EVar "e2b")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoLet false false (PTuple (PVar "arms2") (PVar "c2")) (EApp (EApp (EVar "mapArmsB") (EVar "f")) (EVar "arms"))) (DoExpr (ETuple (EApp (EApp (EVar "EMatch") (EVar "e0b")) (EVar "arms2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EBlock (DoLet false false (PTuple (PVar "cb") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "c"))) (DoLet false false (PTuple (PVar "tb") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "t"))) (DoLet false false (PTuple (PVar "elb") (PVar "c3")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "el"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "EIf") (EVar "cb")) (EVar "tb")) (EVar "elb")) (EBinOp "||" (EBinOp "||" (EVar "c1") (EVar "c2")) (EVar "c3"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EBlock (DoLet false false (PTuple (PVar "a2") (PVar "ca")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "a"))) (DoLet false false (PTuple (PVar "b2") (PVar "cb")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "b"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "a2")) (EVar "b2")) (EVar "r")) (EBinOp "||" (EVar "ca") (EVar "cb"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EBlock (DoLet false false (PTuple (PVar "a2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "a"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EVar "a2")) (EVar "r")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PTuple (PVar "a2") (PVar "ca")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "a"))) (DoLet false false (PTuple (PVar "b2") (PVar "cb")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "b"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EVar "a2")) (EVar "b2")) (EBinOp "||" (EVar "ca") (EVar "cb"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EFieldAccess" (PVar "e0") (PVar "n") (PVar "r"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "EFieldAccess") (EVar "e0b")) (EVar "n")) (EVar "r")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ETuple" (PVar "es"))) (EBlock (DoLet false false (PTuple (PVar "es2") (PVar "c")) (EApp (EApp (EVar "mapExprsB") (EVar "f")) (EVar "es"))) (DoExpr (ETuple (EApp (EVar "ETuple") (EVar "es2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EListLit" (PVar "es"))) (EBlock (DoLet false false (PTuple (PVar "es2") (PVar "c")) (EApp (EApp (EVar "mapExprsB") (EVar "f")) (EVar "es"))) (DoExpr (ETuple (EApp (EVar "EListLit") (EVar "es2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EArrayLit" (PVar "es"))) (EBlock (DoLet false false (PTuple (PVar "es2") (PVar "c")) (EApp (EApp (EVar "mapExprsB") (EVar "f")) (EVar "es"))) (DoExpr (ETuple (EApp (EVar "EArrayLit") (EVar "es2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EBlock (DoLet false false (PTuple (PVar "lo2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "lo"))) (DoLet false false (PTuple (PVar "hi2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "hi"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "ERangeList") (EVar "lo2")) (EVar "hi2")) (EVar "incl")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EBlock (DoLet false false (PTuple (PVar "lo2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "lo"))) (DoLet false false (PTuple (PVar "hi2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "hi"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "ERangeArray") (EVar "lo2")) (EVar "hi2")) (EVar "incl")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "incl") (PVar "r"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoLet false false (PTuple (PVar "lo2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "lo"))) (DoLet false false (PTuple (PVar "hi2") (PVar "c3")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "hi"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EVar "e0b")) (EVar "lo2")) (EVar "hi2")) (EVar "incl")) (EVar "r")) (EBinOp "||" (EBinOp "||" (EVar "c1") (EVar "c2")) (EVar "c3"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ELetGroup" (PVar "binds") (PVar "e2"))) (EBlock (DoLet false false (PTuple (PVar "bs2") (PVar "c1")) (EApp (EApp (EVar "mapLetBindsB") (EVar "f")) (EVar "binds"))) (DoLet false false (PTuple (PVar "e2b") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e2"))) (DoExpr (ETuple (EApp (EApp (EVar "ELetGroup") (EVar "bs2")) (EVar "e2b")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" (PWild (PCon "ESection" (PCon "SecBare" (PVar "op")))) (ETuple (EApp (EVar "ESection") (EApp (EVar "SecBare") (EVar "op"))) (EVar "False")))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e0")))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoExpr (ETuple (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EVar "e0b"))) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ESection" (PCon "SecLeft" (PVar "e0") (PVar "op")))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoExpr (ETuple (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EVar "e0b")) (EVar "op"))) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EIndex" (PVar "e0") (PVar "i") (PVar "r"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoLet false false (PTuple (PVar "i2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "i"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "EIndex") (EVar "e0b")) (EVar "i2")) (EVar "r")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoLet false false (PTuple (PVar "t2") (PVar "c2")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoExpr (ETuple (EApp (EApp (EVar "EAnnot") (EVar "e0b")) (EVar "t2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoLet false false (PTuple (PVar "t2") (PVar "c2")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoExpr (ETuple (EApp (EApp (EVar "EHeadAnnot") (EVar "e0b")) (EVar "t2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EBlock" (PVar "stmts"))) (EBlock (DoLet false false (PTuple (PVar "ss2") (PVar "c")) (EApp (EApp (EVar "mapDoStmtsB") (EVar "f")) (EVar "stmts"))) (DoExpr (ETuple (EApp (EVar "EBlock") (EVar "ss2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EDo" (PVar "stmts"))) (EBlock (DoLet false false (PTuple (PVar "ss2") (PVar "c")) (EApp (EApp (EVar "mapDoStmtsB") (EVar "f")) (EVar "stmts"))) (DoExpr (ETuple (EApp (EVar "EDo") (EVar "ss2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EStringInterp" (PVar "parts"))) (EBlock (DoLet false false (PTuple (PVar "ps2") (PVar "c")) (EApp (EApp (EVar "mapInterpsB") (EVar "f")) (EVar "parts"))) (DoExpr (ETuple (EApp (EVar "EStringInterp") (EVar "ps2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EGuards" (PVar "arms"))) (EBlock (DoLet false false (PTuple (PVar "as2") (PVar "c")) (EApp (EApp (EVar "mapGuardArmsB") (EVar "f")) (EVar "arms"))) (DoExpr (ETuple (EApp (EVar "EGuards") (EVar "as2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EBlock (DoLet false false (PTuple (PVar "fs2") (PVar "c")) (EApp (EApp (EVar "mapFieldAssignsB") (EVar "f")) (EVar "fs"))) (DoExpr (ETuple (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EVar "fs2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "r"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoLet false false (PTuple (PVar "fs2") (PVar "c2")) (EApp (EApp (EVar "mapFieldAssignsB") (EVar "f")) (EVar "fs"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "ERecordUpdate") (EVar "e0b")) (EVar "fs2")) (EVar "r")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EVariantUpdate" (PVar "cn") (PVar "e0") (PVar "fs"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoLet false false (PTuple (PVar "fs2") (PVar "c2")) (EApp (EApp (EVar "mapFieldAssignsB") (EVar "f")) (EVar "fs"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "cn")) (EVar "e0b")) (EVar "fs2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EBlock (DoLet false false (PTuple (PVar "kvs2") (PVar "c")) (EApp (EApp (EVar "mapKvsB") (EVar "f")) (EVar "kvs"))) (DoExpr (ETuple (EApp (EApp (EVar "EMapLit") (EVar "n")) (EVar "kvs2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EBlock (DoLet false false (PTuple (PVar "es2") (PVar "c")) (EApp (EApp (EVar "mapExprsB") (EVar "f")) (EVar "es"))) (DoExpr (ETuple (EApp (EApp (EVar "ESetLit") (EVar "n")) (EVar "es2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EAsPat" (PVar "n") (PVar "e0"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoExpr (ETuple (EApp (EApp (EVar "EAsPat") (EVar "n")) (EVar "e0b")) (EVar "c")))))
(DFunDef false "mapTyInExpr" (PWild (PCon "EMethodRef" (PVar "n"))) (ETuple (EApp (EVar "EMethodRef") (EVar "n")) (EVar "False")))
(DFunDef false "mapTyInExpr" (PWild (PCon "EDictApp" (PVar "n"))) (ETuple (EApp (EVar "EDictApp") (EVar "n")) (EVar "False")))
(DFunDef false "mapTyInExpr" (PWild (PCon "EVarAt" (PVar "n") (PVar "a"))) (ETuple (EApp (EApp (EVar "EVarAt") (EVar "n")) (EVar "a")) (EVar "False")))
(DFunDef false "mapTyInExpr" (PWild (PCon "EMethodAt" (PVar "n") (PVar "r1") (PVar "r2") (PVar "r3"))) (ETuple (EApp (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (EVar "r1")) (EVar "r2")) (EVar "r3")) (EVar "False")))
(DFunDef false "mapTyInExpr" (PWild (PCon "EDictAt" (PVar "n") (PVar "r"))) (ETuple (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "r")) (EVar "False")))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ELoc" (PVar "l") (PVar "e"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EApp (EVar "ELoc") (EVar "l")) (EVar "e2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EVar "e2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" (PWild (PCon "ENumLit" (PVar "n") (PVar "rf") (PVar "rr") (PVar "lx"))) (ETuple (EApp (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EVar "rf")) (EVar "rr")) (EVar "lx")) (EVar "False")))
(DTypeSig false "mapExprsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyTuple (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool")))))
(DFunDef false "mapExprsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapExprsB" ((PVar "f") (PCons (PVar "e") (PVar "es"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoLet false false (PTuple (PVar "es2") (PVar "c2")) (EApp (EApp (EVar "mapExprsB") (EVar "f")) (EVar "es"))) (DoExpr (ETuple (EBinOp "::" (EVar "e2") (EVar "es2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapArmsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyTuple (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Bool")))))
(DFunDef false "mapArmsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapArmsB" ((PVar "f") (PCons (PCon "Arm" (PVar "p") (PVar "gs") (PVar "b")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "gs2") (PVar "c1")) (EApp (EApp (EVar "mapGuardsB") (EVar "f")) (EVar "gs"))) (DoLet false false (PTuple (PVar "b2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "b"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c3")) (EApp (EApp (EVar "mapArmsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EVar "gs2")) (EVar "b2")) (EVar "rest2")) (EBinOp "||" (EBinOp "||" (EVar "c1") (EVar "c2")) (EVar "c3"))))))
(DTypeSig false "mapGuardsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "Bool")))))
(DFunDef false "mapGuardsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapGuardsB" ((PVar "f") (PCons (PCon "GBool" (PVar "g")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "g2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "g"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapGuardsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "GBool") (EVar "g2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapGuardsB" ((PVar "f") (PCons (PCon "GBind" (PVar "p") (PVar "g")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "g2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "g"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapGuardsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GBind") (EVar "p")) (EVar "g2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapGuardArmsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyTuple (TyApp (TyCon "List") (TyCon "GuardArm")) (TyCon "Bool")))))
(DFunDef false "mapGuardArmsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapGuardArmsB" ((PVar "f") (PCons (PCon "GuardArm" (PVar "gs") (PVar "b")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "gs2") (PVar "c1")) (EApp (EApp (EVar "mapGuardsB") (EVar "f")) (EVar "gs"))) (DoLet false false (PTuple (PVar "b2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "b"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c3")) (EApp (EApp (EVar "mapGuardArmsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GuardArm") (EVar "gs2")) (EVar "b2")) (EVar "rest2")) (EBinOp "||" (EBinOp "||" (EVar "c1") (EVar "c2")) (EVar "c3"))))))
(DTypeSig false "mapDoStmtsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Bool")))))
(DFunDef false "mapDoStmtsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapDoStmtsB" ((PVar "f") (PCons (PVar "s") (PVar "ss"))) (EBlock (DoLet false false (PTuple (PVar "s2") (PVar "c1")) (EApp (EApp (EVar "mapDoStmtB") (EVar "f")) (EVar "s"))) (DoLet false false (PTuple (PVar "ss2") (PVar "c2")) (EApp (EApp (EVar "mapDoStmtsB") (EVar "f")) (EVar "ss"))) (DoExpr (ETuple (EBinOp "::" (EVar "s2") (EVar "ss2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapDoStmtB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyCon "DoStmt") (TyTuple (TyCon "DoStmt") (TyCon "Bool")))))
(DFunDef false "mapDoStmtB" ((PVar "f") (PCon "DoExpr" (PVar "e"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EVar "DoExpr") (EVar "e2")) (EVar "c")))))
(DFunDef false "mapDoStmtB" ((PVar "f") (PCon "DoBind" (PVar "p") (PVar "e"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EApp (EVar "DoBind") (EVar "p")) (EVar "e2")) (EVar "c")))))
(DFunDef false "mapDoStmtB" ((PVar "f") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EVar "e2")) (EVar "c")))))
(DFunDef false "mapDoStmtB" ((PVar "f") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EApp (EVar "DoAssign") (EVar "x")) (EVar "e2")) (EVar "c")))))
(DFunDef false "mapDoStmtB" ((PVar "f") (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EVar "e2")) (EVar "c")))))
(DTypeSig false "mapInterpsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "InterpPart")) (TyTuple (TyApp (TyCon "List") (TyCon "InterpPart")) (TyCon "Bool")))))
(DFunDef false "mapInterpsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapInterpsB" ((PVar "f") (PCons (PCon "InterpStr" (PVar "s")) (PVar "rest0"))) (EBlock (DoLet false false (PTuple (PVar "rest2") (PVar "c")) (EApp (EApp (EVar "mapInterpsB") (EVar "f")) (EVar "rest0"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "InterpStr") (EVar "s")) (EVar "rest2")) (EVar "c")))))
(DFunDef false "mapInterpsB" ((PVar "f") (PCons (PCon "InterpExpr" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapInterpsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "InterpExpr") (EVar "e2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapFieldAssignsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyTuple (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyCon "Bool")))))
(DFunDef false "mapFieldAssignsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapFieldAssignsB" ((PVar "f") (PCons (PCon "FieldAssign" (PVar "n") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "v2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "v"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapFieldAssignsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EVar "v2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapKvsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr"))) (TyCon "Bool")))))
(DFunDef false "mapKvsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapKvsB" ((PVar "f") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "k2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "k"))) (DoLet false false (PTuple (PVar "v2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "v"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c3")) (EApp (EApp (EVar "mapKvsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (ETuple (EVar "k2") (EVar "v2")) (EVar "rest2")) (EBinOp "||" (EBinOp "||" (EVar "c1") (EVar "c2")) (EVar "c3"))))))
(DData Private "EffAction" () ((variant "ADrop" (ConPos)) (variant "ARename" (ConPos (TyCon "String")))) ())
(DTypeSig false "mkEffectLabels" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))))))
(DFunDef false "mkEffectLabels" ((PVar "args")) (EMatch (EApp (EApp (EVar "parseEffectArgs") (EVar "args")) (EListLit)) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "Ok" (PList)) () (EApp (EVar "Err") (ELit (LString "need at least one --strip <labels> or --rename Old=New")))) (arm (PCon "Ok" (PVar "acts")) () (EApp (EVar "Ok") (EApp (EVar "mapTyInDecl") (EApp (EVar "effTyNode") (EVar "acts")))))))
(DTypeSig false "parseEffectArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction")))))))
(DFunDef false "parseEffectArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "parseEffectArgs" ((PCons (PLit (LString "--strip")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseEffectArgs") (EVar "rest")) (EApp (EApp (EVar "prependDrops") (EApp (EApp (EVar "splitOnChar") (ELit (LChar ","))) (EVar "v"))) (EVar "acc"))))
(DFunDef false "parseEffectArgs" ((PCons (PLit (LString "--rename")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar "="))) (EVar "v")) (arm (PList (PVar "old") (PVar "nw")) () (EIf (EBinOp "||" (EBinOp "==" (EVar "old") (ELit (LString ""))) (EBinOp "==" (EVar "nw") (ELit (LString "")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "--rename expects Old=New, got '")) (EApp (EVar "display") (EVar "v"))) (ELit (LString "'")))) (EApp (EApp (EVar "parseEffectArgs") (EVar "rest")) (EBinOp "::" (ETuple (EVar "old") (EApp (EVar "ARename") (EVar "nw"))) (EVar "acc"))))) (arm PWild () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "--rename expects Old=New, got '")) (EApp (EVar "display") (EVar "v"))) (ELit (LString "'")))))))
(DFunDef false "parseEffectArgs" ((PList (PLit (LString "--strip"))) PWild) (EApp (EVar "Err") (ELit (LString "--strip requires a value (e.g. --strip Rand,Net)"))))
(DFunDef false "parseEffectArgs" ((PList (PLit (LString "--rename"))) PWild) (EApp (EVar "Err") (ELit (LString "--rename requires a value (e.g. --rename Old=New)"))))
(DFunDef false "parseEffectArgs" ((PCons (PVar "x") PWild) PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown argument '")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "'")))))
(DTypeSig false "prependDrops" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))))))
(DFunDef false "prependDrops" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "prependDrops" ((PCons (PVar "n") (PVar "ns")) (PVar "acc")) (EIf (EBinOp "==" (EVar "n") (ELit (LString ""))) (EApp (EApp (EVar "prependDrops") (EVar "ns")) (EVar "acc")) (EApp (EApp (EVar "prependDrops") (EVar "ns")) (EBinOp "::" (ETuple (EVar "n") (EVar "ADrop")) (EVar "acc")))))
(DTypeSig false "effTyNode" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "effTyNode" ((PVar "acts") (PCon "TyEffect" (PVar "es") (PVar "tail") (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "rewriteRow") (EVar "acts")) (EVar "es")) (EVar "tail")) (EVar "t")))
(DFunDef false "effTyNode" (PWild (PVar "ty")) (ETuple (EVar "ty") (EVar "False")))
(DTypeSig false "rewriteRow" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool")))))))
(DFunDef false "rewriteRow" ((PVar "acts") (PVar "es") (PVar "tail") (PVar "t")) (EBlock (DoLet false false (PVar "stepped") (EApp (EApp (EVar "map") (EApp (EVar "applyAtom") (EVar "acts"))) (EVar "es"))) (DoLet false false (PVar "anyChanged") (EApp (EApp (EVar "anyList") (EVar "sndB")) (EVar "stepped"))) (DoLet false false (PVar "kept") (EApp (EVar "collectKept") (EVar "stepped"))) (DoLet false false (PVar "deduped") (EApp (EVar "dedupeAtoms") (EVar "kept"))) (DoLet false false (PVar "dedupChanged") (EBinOp "!=" (EApp (EVar "listLen") (EVar "deduped")) (EApp (EVar "listLen") (EVar "kept")))) (DoLet false false (PVar "changed") (EBinOp "||" (EVar "anyChanged") (EVar "dedupChanged"))) (DoExpr (EMatch (EVar "deduped") (arm (PList) () (EMatch (EVar "tail") (arm (PCon "None") () (EIf (EVar "changed") (ETuple (EVar "t") (EVar "True")) (ETuple (EApp (EApp (EApp (EVar "TyEffect") (EListLit)) (EVar "None")) (EVar "t")) (EVar "False")))) (arm (PCon "Some" (PVar "v")) () (ETuple (EApp (EApp (EApp (EVar "TyEffect") (EListLit)) (EApp (EVar "Some") (EVar "v"))) (EVar "t")) (EVar "changed"))))) (arm PWild () (ETuple (EApp (EApp (EApp (EVar "TyEffect") (EVar "deduped")) (EVar "tail")) (EVar "t")) (EVar "changed")))))))
(DTypeSig false "applyAtom" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyTuple (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyCon "Bool")))))
(DFunDef false "applyAtom" ((PVar "acts") (PTuple (PVar "label") (PVar "dom"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "label")) (EVar "acts")) (arm (PCon "None") () (ETuple (EApp (EVar "Some") (ETuple (EVar "label") (EVar "dom"))) (EVar "False"))) (arm (PCon "Some" (PCon "ADrop")) () (ETuple (EVar "None") (EVar "True"))) (arm (PCon "Some" (PCon "ARename" (PVar "nw"))) () (ETuple (EApp (EVar "Some") (ETuple (EVar "nw") (EVar "dom"))) (EVar "True")))))
(DTypeSig false "sndB" (TyFun (TyTuple (TyVar "a") (TyCon "Bool")) (TyCon "Bool")))
(DFunDef false "sndB" ((PTuple PWild (PVar "b"))) (EVar "b"))
(DTypeSig false "collectKept" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyCon "Bool"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "collectKept" ((PList)) (EListLit))
(DFunDef false "collectKept" ((PCons (PTuple (PCon "None") PWild) (PVar "rest"))) (EApp (EVar "collectKept") (EVar "rest")))
(DFunDef false "collectKept" ((PCons (PTuple (PCon "Some" (PVar "a")) PWild) (PVar "rest"))) (EBinOp "::" (EVar "a") (EApp (EVar "collectKept") (EVar "rest"))))
(DTypeSig false "dedupeAtoms" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "dedupeAtoms" ((PVar "xs")) (EApp (EApp (EVar "dedupeGo") (EVar "xs")) (EListLit)))
(DTypeSig false "dedupeGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "dedupeGo" ((PList) PWild) (EListLit))
(DFunDef false "dedupeGo" ((PCons (PVar "a") (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "atomElem") (EVar "a")) (EVar "seen")) (EApp (EApp (EVar "dedupeGo") (EVar "rest")) (EVar "seen")) (EBinOp "::" (EVar "a") (EApp (EApp (EVar "dedupeGo") (EVar "rest")) (EBinOp "::" (EVar "a") (EVar "seen"))))))
(DTypeSig false "atomElem" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyCon "Bool"))))
(DFunDef false "atomElem" (PWild (PList)) (EVar "False"))
(DFunDef false "atomElem" ((PVar "a") (PCons (PVar "b") (PVar "bs"))) (EBinOp "||" (EApp (EApp (EVar "atomEq") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "atomElem") (EVar "a")) (EVar "bs"))))
(DTypeSig false "atomEq" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Bool"))))
(DFunDef false "atomEq" ((PTuple (PVar "l1") (PVar "d1")) (PTuple (PVar "l2") (PVar "d2"))) (EBinOp "&&" (EBinOp "==" (EVar "l1") (EVar "l2")) (EApp (EApp (EVar "domEq") (EVar "d1")) (EVar "d2"))))
(DTypeSig false "domEq" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "domEq" ((PCon "None") (PCon "None")) (EVar "True"))
(DFunDef false "domEq" ((PCon "Some" (PVar "x")) (PCon "Some" (PVar "y"))) (EBinOp "==" (EVar "x") (EVar "y")))
(DFunDef false "domEq" (PWild PWild) (EVar "False"))
(DTypeSig false "warnEffectLabels" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "warnEffectLabels" ((PVar "args") (PVar "decls")) (EMatch (EApp (EApp (EVar "parseEffectArgs") (EVar "args")) (EListLit)) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "acts")) () (EApp (EApp (EVar "declEffectWarns") (EVar "acts")) (EVar "decls")))))
(DTypeSig false "declEffectWarns" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declEffectWarns" (PWild (PList)) (EListLit))
(DFunDef false "declEffectWarns" ((PVar "acts") (PCons (PVar "d") (PVar "ds"))) (EBinOp "++" (EApp (EApp (EVar "declEffectWarn") (EVar "acts")) (EVar "d")) (EApp (EApp (EVar "declEffectWarns") (EVar "acts")) (EVar "ds"))))
(DTypeSig false "declEffectWarn" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declEffectWarn" ((PVar "acts") (PCon "DEffect" PWild (PVar "name") PWild)) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "acts")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" PWild) () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'effect ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' is declared here but effect-labels targets "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "; the declaration is left untouched")))))))
(DFunDef false "declEffectWarn" ((PVar "acts") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declEffectWarn") (EVar "acts")) (EVar "d")))
(DFunDef false "declEffectWarn" (PWild PWild) (EListLit))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" true) (mem "Constraint" true) (mem "Expr" true) (mem "Section" true) (mem "Arm" true) (mem "Guard" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true) (mem "PropParam" true) (mem "IfaceMethod" true) (mem "MethodDefault" true) (mem "Require" true) (mem "ImplMethod" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Field" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseResult" false) (mem "ParseError" false) (mem "parseWithPositions" false) (mem "positionsDecls" false) (mem "positionsVariantLines" false) (mem "positionsChainLines" false) (mem "positionsLastContentLine" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "collectComments" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatProgram" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "splitOnChar" false) (mem "joinNl" false) (mem "anyList" false))))
(DData Public "Codemod" () ((variant "Codemod" (ConNamed (field "name" (TyCon "String")) (field "descr" (TyCon "String")) (field "argHelp" (TyCon "String")) (field "mk" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool")))))) (field "warn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))))) ())
(DTypeSig true "allCodemods" (TyApp (TyCon "List") (TyCon "Codemod")))
(DFunDef false "allCodemods" () (EListLit (EVar "effectLabelsCodemod")))
(DTypeSig false "effectLabelsCodemod" (TyCon "Codemod"))
(DFunDef false "effectLabelsCodemod" () (ERecordCreate "Codemod" ((fa "name" (ELit (LString "effect-labels"))) (fa "descr" (ELit (LString "strip and/or rename effect-row labels (e.g. <Rand>, <Net>, …)"))) (fa "argHelp" (ELit (LString "--strip L1,L2   --rename Old=New   (repeatable)"))) (fa "mk" (EVar "mkEffectLabels")) (fa "warn" (EVar "warnEffectLabels")))))
(DTypeSig true "codemodName" (TyFun (TyCon "Codemod") (TyCon "String")))
(DFunDef false "codemodName" ((PRec "Codemod" ((rf "name" None)) true)) (EVar "name"))
(DTypeSig true "codemodDescr" (TyFun (TyCon "Codemod") (TyCon "String")))
(DFunDef false "codemodDescr" ((PRec "Codemod" ((rf "descr" None)) true)) (EVar "descr"))
(DTypeSig true "codemodArgHelp" (TyFun (TyCon "Codemod") (TyCon "String")))
(DFunDef false "codemodArgHelp" ((PRec "Codemod" ((rf "argHelp" None)) true)) (EVar "argHelp"))
(DTypeSig true "codemodMk" (TyFun (TyCon "Codemod") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool")))))))
(DFunDef false "codemodMk" ((PRec "Codemod" ((rf "mk" None)) true) (PVar "args")) (EApp (EVar "mk") (EVar "args")))
(DTypeSig true "codemodWarnDecls" (TyFun (TyCon "Codemod") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "codemodWarnDecls" ((PRec "Codemod" ((rf "warn" None)) true) (PVar "args") (PVar "decls")) (EApp (EApp (EVar "warn") (EVar "args")) (EVar "decls")))
(DTypeSig true "findCodemod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Codemod"))))
(DFunDef false "findCodemod" ((PVar "name")) (EApp (EApp (EVar "findCodemodGo") (EVar "name")) (EVar "allCodemods")))
(DTypeSig false "findCodemodGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Codemod")) (TyApp (TyCon "Option") (TyCon "Codemod")))))
(DFunDef false "findCodemodGo" (PWild (PList)) (EVar "None"))
(DFunDef false "findCodemodGo" ((PVar "name") (PCons (PVar "c") (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "codemodName") (EVar "c")) (EVar "name")) (EApp (EVar "Some") (EVar "c")) (EApp (EApp (EVar "findCodemodGo") (EVar "name")) (EVar "rest"))))
(DTypeSig true "codemodListing" (TyCon "String"))
(DFunDef false "codemodListing" () (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "codemodListingLine")) (EVar "allCodemods"))))
(DTypeSig false "codemodListingLine" (TyFun (TyCon "Codemod") (TyCon "String")))
(DFunDef false "codemodListingLine" ((PVar "c")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EApp (EVar "codemodName") (EVar "c")))) (ELit (LString " — "))) (EApp (EMethodRef "display") (EApp (EVar "codemodDescr") (EVar "c")))) (ELit (LString "\n    "))) (EApp (EMethodRef "display") (EApp (EVar "codemodArgHelp") (EVar "c")))) (ELit (LString ""))))
(DTypeSig true "codemodSource" (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "codemodSource" ((PVar "xf") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PTuple (PVar "decls2") (PVar "changed")) (EApp (EApp (EVar "mapDeclsChanged") (EVar "xf")) (EVar "decls"))) (DoExpr (EIf (EApp (EVar "not") (EVar "changed")) (EApp (EVar "Ok") (EVar "None")) (EBlock (DoLet false false (PVar "comments") (EApp (EVar "collectComments") (EVar "src"))) (DoExpr (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "formatProgram") (EVar "decls2")) (EApp (EVar "positionsDecls") (EVar "pos"))) (EApp (EVar "positionsVariantLines") (EVar "pos"))) (EApp (EVar "positionsChainLines") (EVar "pos"))) (EVar "comments")) (EApp (EVar "positionsLastContentLine") (EVar "pos"))) (EVar "src"))))))))))))
(DTypeSig false "mapDeclsChanged" (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))))
(DFunDef false "mapDeclsChanged" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapDeclsChanged" ((PVar "xf") (PCons (PVar "d") (PVar "ds"))) (EBlock (DoLet false false (PTuple (PVar "d2") (PVar "c1")) (EApp (EVar "xf") (EVar "d"))) (DoLet false false (PTuple (PVar "ds2") (PVar "c2")) (EApp (EApp (EVar "mapDeclsChanged") (EVar "xf")) (EVar "ds"))) (DoExpr (ETuple (EBinOp "::" (EVar "d2") (EVar "ds2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapTyFull" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "mapTyFull" ((PVar "f") (PVar "ty")) (EBlock (DoLet false false (PTuple (PVar "ty1") (PVar "c1")) (EApp (EApp (EVar "mapTyKids") (EVar "f")) (EVar "ty"))) (DoLet false false (PTuple (PVar "ty2") (PVar "c2")) (EApp (EVar "f") (EVar "ty1"))) (DoExpr (ETuple (EVar "ty2") (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapTyKids" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "mapTyKids" (PWild (PCon "TyCon" (PVar "n") (PVar "l"))) (ETuple (EApp (EApp (EVar "TyCon") (EVar "n")) (EVar "l")) (EVar "False")))
(DFunDef false "mapTyKids" (PWild (PCon "TyVar" (PVar "n"))) (ETuple (EApp (EVar "TyVar") (EVar "n")) (EVar "False")))
(DFunDef false "mapTyKids" ((PVar "f") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PTuple (PVar "a2") (PVar "ca")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "a"))) (DoLet false false (PTuple (PVar "b2") (PVar "cb")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "b"))) (DoExpr (ETuple (EApp (EApp (EVar "TyApp") (EVar "a2")) (EVar "b2")) (EBinOp "||" (EVar "ca") (EVar "cb"))))))
(DFunDef false "mapTyKids" ((PVar "f") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PTuple (PVar "a2") (PVar "ca")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "a"))) (DoLet false false (PTuple (PVar "b2") (PVar "cb")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "b"))) (DoExpr (ETuple (EApp (EApp (EVar "TyFun") (EVar "a2")) (EVar "b2")) (EBinOp "||" (EVar "ca") (EVar "cb"))))))
(DFunDef false "mapTyKids" ((PVar "f") (PCon "TyTuple" (PVar "ts"))) (EBlock (DoLet false false (PTuple (PVar "ts2") (PVar "c")) (EApp (EApp (EVar "mapTyListB") (EVar "f")) (EVar "ts"))) (DoExpr (ETuple (EApp (EVar "TyTuple") (EVar "ts2")) (EVar "c")))))
(DFunDef false "mapTyKids" ((PVar "f") (PCon "TyEffect" (PVar "es") (PVar "tail") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "t2") (PVar "c")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "TyEffect") (EVar "es")) (EVar "tail")) (EVar "t2")) (EVar "c")))))
(DFunDef false "mapTyKids" ((PVar "f") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "cs2") (PVar "cc")) (EApp (EApp (EVar "mapConstraintsB") (EVar "f")) (EVar "cs"))) (DoLet false false (PTuple (PVar "t2") (PVar "ct")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoExpr (ETuple (EApp (EApp (EVar "TyConstrained") (EVar "cs2")) (EVar "t2")) (EBinOp "||" (EVar "cc") (EVar "ct"))))))
(DTypeSig false "mapTyListB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool")))))
(DFunDef false "mapTyListB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapTyListB" ((PVar "f") (PCons (PVar "t") (PVar "ts"))) (EBlock (DoLet false false (PTuple (PVar "t2") (PVar "c1")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoLet false false (PTuple (PVar "ts2") (PVar "c2")) (EApp (EApp (EVar "mapTyListB") (EVar "f")) (EVar "ts"))) (DoExpr (ETuple (EBinOp "::" (EVar "t2") (EVar "ts2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapConstraintsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyTuple (TyApp (TyCon "List") (TyCon "Constraint")) (TyCon "Bool")))))
(DFunDef false "mapConstraintsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapConstraintsB" ((PVar "f") (PCons (PCon "Constraint" (PVar "iface") (PVar "tys")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "tys2") (PVar "c1")) (EApp (EApp (EVar "mapTyListB") (EVar "f")) (EVar "tys"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapConstraintsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "Constraint") (EVar "iface")) (EVar "tys2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig true "mapTyInDecl" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DTypeSig" (PVar "pub") (PVar "n") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "t2") (PVar "c")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "DTypeSig") (EVar "pub")) (EVar "n")) (EVar "t2")) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DExtern" (PVar "pub") (PVar "n") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "t2") (PVar "c")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "DExtern") (EVar "pub")) (EVar "n")) (EVar "t2")) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EVar "e2")) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DData" (PVar "vis") (PVar "n") (PVar "tps") (PVar "variants") (PVar "ders"))) (EBlock (DoLet false false (PTuple (PVar "vs2") (PVar "c")) (EApp (EApp (EVar "mapVariantsB") (EVar "f")) (EVar "variants"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "DData") (EVar "vis")) (EVar "n")) (EVar "tps")) (EVar "vs2")) (EVar "ders")) (EVar "c")))))
(DFunDef false "mapTyInDecl" (PWild (PCon "DUse" (PVar "pub") (PVar "path") (PVar "loc"))) (ETuple (EApp (EApp (EApp (EVar "DUse") (EVar "pub")) (EVar "path")) (EVar "loc")) (EVar "False")))
(DFunDef false "mapTyInDecl" (PWild (PCon "DEffect" (PVar "pub") (PVar "n") (PVar "dom"))) (ETuple (EApp (EApp (EApp (EVar "DEffect") (EVar "pub")) (EVar "n")) (EVar "dom")) (EVar "False")))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DProp" (PVar "pub") (PVar "n") (PVar "params") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "params2") (PVar "c1")) (EApp (EApp (EVar "mapPropParamsB") (EVar "f")) (EVar "params"))) (DoLet false false (PTuple (PVar "body2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "body"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "n")) (EVar "params2")) (EVar "body2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DTest" (PVar "pub") (PVar "n") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "b2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "body"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "n")) (EVar "b2")) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DBench" (PVar "pub") (PVar "n") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "b2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "body"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "DBench") (EVar "pub")) (EVar "n")) (EVar "b2")) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EBlock (DoLet false false (PTuple (PVar "ms2") (PVar "c")) (EApp (EApp (EVar "mapIfaceMethodsB") (EVar "f")) (EVar "methods"))) (DoExpr (ETuple (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EVar "ms2")))) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PAs "d" (PRec "DImpl" ((rf "tys" None) (rf "reqs" None) (rf "methods" None)) true))) (EBlock (DoLet false false (PTuple (PVar "tys2") (PVar "c1")) (EApp (EApp (EVar "mapTyListB") (EVar "f")) (EVar "tys"))) (DoLet false false (PTuple (PVar "reqs2") (PVar "c2")) (EApp (EApp (EVar "mapRequiresB") (EVar "f")) (EVar "reqs"))) (DoLet false false (PTuple (PVar "ms2") (PVar "c3")) (EApp (EApp (EVar "mapImplMethodsB") (EVar "f")) (EVar "methods"))) (DoExpr (ETuple (EVariantUpdate "DImpl" (EVar "d") ((fa "tys" (EVar "tys2")) (fa "reqs" (EVar "reqs2")) (fa "methods" (EVar "ms2")))) (EBinOp "||" (EBinOp "||" (EVar "c1") (EVar "c2")) (EVar "c3"))))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DTypeAlias" (PVar "pub") (PVar "n") (PVar "tps") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "t2") (PVar "c")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "DTypeAlias") (EVar "pub")) (EVar "n")) (EVar "tps")) (EVar "t2")) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DNewtype" (PVar "pub") (PVar "n") (PVar "tps") (PVar "cn") (PVar "t") (PVar "ders"))) (EBlock (DoLet false false (PTuple (PVar "t2") (PVar "c")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DNewtype") (EVar "pub")) (EVar "n")) (EVar "tps")) (EVar "cn")) (EVar "t2")) (EVar "ders")) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EBlock (DoLet false false (PTuple (PVar "bs2") (PVar "c")) (EApp (EApp (EVar "mapLetBindsB") (EVar "f")) (EVar "binds"))) (DoExpr (ETuple (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EVar "bs2")) (EVar "c")))))
(DFunDef false "mapTyInDecl" ((PVar "f") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EBlock (DoLet false false (PTuple (PVar "d2") (PVar "c")) (EApp (EApp (EVar "mapTyInDecl") (EVar "f")) (EVar "d"))) (DoExpr (ETuple (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EVar "d2")) (EVar "c")))))
(DTypeSig false "mapVariantsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyTuple (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Bool")))))
(DFunDef false "mapVariantsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapVariantsB" ((PVar "f") (PCons (PVar "v") (PVar "vs"))) (EBlock (DoLet false false (PTuple (PVar "v2") (PVar "c1")) (EApp (EApp (EVar "mapVariantB") (EVar "f")) (EVar "v"))) (DoLet false false (PTuple (PVar "vs2") (PVar "c2")) (EApp (EApp (EVar "mapVariantsB") (EVar "f")) (EVar "vs"))) (DoExpr (ETuple (EBinOp "::" (EVar "v2") (EVar "vs2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapVariantB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyCon "Variant") (TyTuple (TyCon "Variant") (TyCon "Bool")))))
(DFunDef false "mapVariantB" ((PVar "f") (PCon "Variant" (PVar "n") (PCon "ConPos" (PVar "tys")))) (EBlock (DoLet false false (PTuple (PVar "tys2") (PVar "c")) (EApp (EApp (EVar "mapTyListB") (EVar "f")) (EVar "tys"))) (DoExpr (ETuple (EApp (EApp (EVar "Variant") (EVar "n")) (EApp (EVar "ConPos") (EVar "tys2"))) (EVar "c")))))
(DFunDef false "mapVariantB" ((PVar "f") (PCon "Variant" (PVar "n") (PCon "ConNamed" (PVar "fields") (PVar "omitted")))) (EBlock (DoLet false false (PTuple (PVar "fs2") (PVar "c")) (EApp (EApp (EVar "mapFieldsB") (EVar "f")) (EVar "fields"))) (DoExpr (ETuple (EApp (EApp (EVar "Variant") (EVar "n")) (EApp (EApp (EVar "ConNamed") (EVar "fs2")) (EVar "omitted"))) (EVar "c")))))
(DTypeSig false "mapFieldsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyTuple (TyApp (TyCon "List") (TyCon "Field")) (TyCon "Bool")))))
(DFunDef false "mapFieldsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapFieldsB" ((PVar "f") (PCons (PCon "Field" (PVar "n") (PVar "t")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "t2") (PVar "c1")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapFieldsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "Field") (EVar "n")) (EVar "t2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapPropParamsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyTuple (TyApp (TyCon "List") (TyCon "PropParam")) (TyCon "Bool")))))
(DFunDef false "mapPropParamsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapPropParamsB" ((PVar "f") (PCons (PCon "PropParam" (PVar "n") (PVar "t")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "t2") (PVar "c1")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapPropParamsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "PropParam") (EVar "n")) (EVar "t2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapIfaceMethodsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyTuple (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyCon "Bool")))))
(DFunDef false "mapIfaceMethodsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapIfaceMethodsB" ((PVar "f") (PCons (PVar "m") (PVar "ms"))) (EBlock (DoLet false false (PTuple (PVar "m2") (PVar "c1")) (EApp (EApp (EVar "mapIfaceMethodB") (EVar "f")) (EVar "m"))) (DoLet false false (PTuple (PVar "ms2") (PVar "c2")) (EApp (EApp (EVar "mapIfaceMethodsB") (EVar "f")) (EVar "ms"))) (DoExpr (ETuple (EBinOp "::" (EVar "m2") (EVar "ms2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapIfaceMethodB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyCon "IfaceMethod") (TyTuple (TyCon "IfaceMethod") (TyCon "Bool")))))
(DFunDef false "mapIfaceMethodB" ((PVar "f") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None"))) (EBlock (DoLet false false (PTuple (PVar "ty2") (PVar "c")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "ty"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty2")) (EVar "None")) (EVar "c")))))
(DFunDef false "mapIfaceMethodB" ((PVar "f") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "e"))))) (EBlock (DoLet false false (PTuple (PVar "ty2") (PVar "c1")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "ty"))) (DoLet false false (PTuple (PVar "e2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty2")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "ps")) (EVar "e2")))) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapRequiresB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyTuple (TyApp (TyCon "List") (TyCon "Require")) (TyCon "Bool")))))
(DFunDef false "mapRequiresB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapRequiresB" ((PVar "f") (PCons (PCon "Require" (PVar "iface") (PVar "tys")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "tys2") (PVar "c1")) (EApp (EApp (EVar "mapTyListB") (EVar "f")) (EVar "tys"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapRequiresB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "Require") (EVar "iface")) (EVar "tys2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapImplMethodsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyTuple (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyCon "Bool")))))
(DFunDef false "mapImplMethodsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapImplMethodsB" ((PVar "f") (PCons (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapImplMethodsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps")) (EVar "e2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapLetBindsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyTuple (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Bool")))))
(DFunDef false "mapLetBindsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapLetBindsB" ((PVar "f") (PCons (PCon "LetBind" (PVar "n") (PVar "clauses")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "cs2") (PVar "c1")) (EApp (EApp (EVar "mapFunClausesB") (EVar "f")) (EVar "clauses"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapLetBindsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "LetBind") (EVar "n")) (EVar "cs2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapFunClausesB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyTuple (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Bool")))))
(DFunDef false "mapFunClausesB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapFunClausesB" ((PVar "f") (PCons (PCon "FunClause" (PVar "ps") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapFunClausesB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "e2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig true "mapTyInExpr" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyCon "Expr") (TyTuple (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "mapTyInExpr" (PWild (PCon "ELit" (PVar "l"))) (ETuple (EApp (EVar "ELit") (EVar "l")) (EVar "False")))
(DFunDef false "mapTyInExpr" (PWild (PCon "EVar" (PVar "n"))) (ETuple (EApp (EVar "EVar") (EVar "n")) (EVar "False")))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EApp" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PTuple (PVar "a2") (PVar "ca")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "a"))) (DoLet false false (PTuple (PVar "b2") (PVar "cb")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "b"))) (DoExpr (ETuple (EApp (EApp (EVar "EApp") (EVar "a2")) (EVar "b2")) (EBinOp "||" (EVar "ca") (EVar "cb"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ELam" (PVar "ps") (PVar "b"))) (EBlock (DoLet false false (PTuple (PVar "b2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "b"))) (DoExpr (ETuple (EApp (EApp (EVar "ELam") (EVar "ps")) (EVar "b2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ELet" (PVar "m") (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PTuple (PVar "e1b") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e1"))) (DoLet false false (PTuple (PVar "e2b") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e2"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EVar "p")) (EVar "e1b")) (EVar "e2b")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoLet false false (PTuple (PVar "arms2") (PVar "c2")) (EApp (EApp (EVar "mapArmsB") (EVar "f")) (EVar "arms"))) (DoExpr (ETuple (EApp (EApp (EVar "EMatch") (EVar "e0b")) (EVar "arms2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EBlock (DoLet false false (PTuple (PVar "cb") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "c"))) (DoLet false false (PTuple (PVar "tb") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "t"))) (DoLet false false (PTuple (PVar "elb") (PVar "c3")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "el"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "EIf") (EVar "cb")) (EVar "tb")) (EVar "elb")) (EBinOp "||" (EBinOp "||" (EVar "c1") (EVar "c2")) (EVar "c3"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EBlock (DoLet false false (PTuple (PVar "a2") (PVar "ca")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "a"))) (DoLet false false (PTuple (PVar "b2") (PVar "cb")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "b"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "a2")) (EVar "b2")) (EVar "r")) (EBinOp "||" (EVar "ca") (EVar "cb"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EBlock (DoLet false false (PTuple (PVar "a2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "a"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EVar "a2")) (EVar "r")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PTuple (PVar "a2") (PVar "ca")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "a"))) (DoLet false false (PTuple (PVar "b2") (PVar "cb")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "b"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EVar "a2")) (EVar "b2")) (EBinOp "||" (EVar "ca") (EVar "cb"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EFieldAccess" (PVar "e0") (PVar "n") (PVar "r"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "EFieldAccess") (EVar "e0b")) (EVar "n")) (EVar "r")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ETuple" (PVar "es"))) (EBlock (DoLet false false (PTuple (PVar "es2") (PVar "c")) (EApp (EApp (EVar "mapExprsB") (EVar "f")) (EVar "es"))) (DoExpr (ETuple (EApp (EVar "ETuple") (EVar "es2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EListLit" (PVar "es"))) (EBlock (DoLet false false (PTuple (PVar "es2") (PVar "c")) (EApp (EApp (EVar "mapExprsB") (EVar "f")) (EVar "es"))) (DoExpr (ETuple (EApp (EVar "EListLit") (EVar "es2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EArrayLit" (PVar "es"))) (EBlock (DoLet false false (PTuple (PVar "es2") (PVar "c")) (EApp (EApp (EVar "mapExprsB") (EVar "f")) (EVar "es"))) (DoExpr (ETuple (EApp (EVar "EArrayLit") (EVar "es2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EBlock (DoLet false false (PTuple (PVar "lo2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "lo"))) (DoLet false false (PTuple (PVar "hi2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "hi"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "ERangeList") (EVar "lo2")) (EVar "hi2")) (EVar "incl")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EBlock (DoLet false false (PTuple (PVar "lo2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "lo"))) (DoLet false false (PTuple (PVar "hi2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "hi"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "ERangeArray") (EVar "lo2")) (EVar "hi2")) (EVar "incl")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "incl") (PVar "r"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoLet false false (PTuple (PVar "lo2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "lo"))) (DoLet false false (PTuple (PVar "hi2") (PVar "c3")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "hi"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EVar "e0b")) (EVar "lo2")) (EVar "hi2")) (EVar "incl")) (EVar "r")) (EBinOp "||" (EBinOp "||" (EVar "c1") (EVar "c2")) (EVar "c3"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ELetGroup" (PVar "binds") (PVar "e2"))) (EBlock (DoLet false false (PTuple (PVar "bs2") (PVar "c1")) (EApp (EApp (EVar "mapLetBindsB") (EVar "f")) (EVar "binds"))) (DoLet false false (PTuple (PVar "e2b") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e2"))) (DoExpr (ETuple (EApp (EApp (EVar "ELetGroup") (EVar "bs2")) (EVar "e2b")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" (PWild (PCon "ESection" (PCon "SecBare" (PVar "op")))) (ETuple (EApp (EVar "ESection") (EApp (EVar "SecBare") (EVar "op"))) (EVar "False")))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e0")))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoExpr (ETuple (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EVar "e0b"))) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ESection" (PCon "SecLeft" (PVar "e0") (PVar "op")))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoExpr (ETuple (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EVar "e0b")) (EVar "op"))) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EIndex" (PVar "e0") (PVar "i") (PVar "r"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoLet false false (PTuple (PVar "i2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "i"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "EIndex") (EVar "e0b")) (EVar "i2")) (EVar "r")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoLet false false (PTuple (PVar "t2") (PVar "c2")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoExpr (ETuple (EApp (EApp (EVar "EAnnot") (EVar "e0b")) (EVar "t2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoLet false false (PTuple (PVar "t2") (PVar "c2")) (EApp (EApp (EVar "mapTyFull") (EVar "f")) (EVar "t"))) (DoExpr (ETuple (EApp (EApp (EVar "EHeadAnnot") (EVar "e0b")) (EVar "t2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EBlock" (PVar "stmts"))) (EBlock (DoLet false false (PTuple (PVar "ss2") (PVar "c")) (EApp (EApp (EVar "mapDoStmtsB") (EVar "f")) (EVar "stmts"))) (DoExpr (ETuple (EApp (EVar "EBlock") (EVar "ss2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EDo" (PVar "stmts"))) (EBlock (DoLet false false (PTuple (PVar "ss2") (PVar "c")) (EApp (EApp (EVar "mapDoStmtsB") (EVar "f")) (EVar "stmts"))) (DoExpr (ETuple (EApp (EVar "EDo") (EVar "ss2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EStringInterp" (PVar "parts"))) (EBlock (DoLet false false (PTuple (PVar "ps2") (PVar "c")) (EApp (EApp (EVar "mapInterpsB") (EVar "f")) (EVar "parts"))) (DoExpr (ETuple (EApp (EVar "EStringInterp") (EVar "ps2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EGuards" (PVar "arms"))) (EBlock (DoLet false false (PTuple (PVar "as2") (PVar "c")) (EApp (EApp (EVar "mapGuardArmsB") (EVar "f")) (EVar "arms"))) (DoExpr (ETuple (EApp (EVar "EGuards") (EVar "as2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EBlock (DoLet false false (PTuple (PVar "fs2") (PVar "c")) (EApp (EApp (EVar "mapFieldAssignsB") (EVar "f")) (EVar "fs"))) (DoExpr (ETuple (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EVar "fs2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "r"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoLet false false (PTuple (PVar "fs2") (PVar "c2")) (EApp (EApp (EVar "mapFieldAssignsB") (EVar "f")) (EVar "fs"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "ERecordUpdate") (EVar "e0b")) (EVar "fs2")) (EVar "r")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EVariantUpdate" (PVar "cn") (PVar "e0") (PVar "fs"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoLet false false (PTuple (PVar "fs2") (PVar "c2")) (EApp (EApp (EVar "mapFieldAssignsB") (EVar "f")) (EVar "fs"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "cn")) (EVar "e0b")) (EVar "fs2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EBlock (DoLet false false (PTuple (PVar "kvs2") (PVar "c")) (EApp (EApp (EVar "mapKvsB") (EVar "f")) (EVar "kvs"))) (DoExpr (ETuple (EApp (EApp (EVar "EMapLit") (EVar "n")) (EVar "kvs2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EBlock (DoLet false false (PTuple (PVar "es2") (PVar "c")) (EApp (EApp (EVar "mapExprsB") (EVar "f")) (EVar "es"))) (DoExpr (ETuple (EApp (EApp (EVar "ESetLit") (EVar "n")) (EVar "es2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EAsPat" (PVar "n") (PVar "e0"))) (EBlock (DoLet false false (PTuple (PVar "e0b") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e0"))) (DoExpr (ETuple (EApp (EApp (EVar "EAsPat") (EVar "n")) (EVar "e0b")) (EVar "c")))))
(DFunDef false "mapTyInExpr" (PWild (PCon "EMethodRef" (PVar "n"))) (ETuple (EApp (EVar "EMethodRef") (EVar "n")) (EVar "False")))
(DFunDef false "mapTyInExpr" (PWild (PCon "EDictApp" (PVar "n"))) (ETuple (EApp (EVar "EDictApp") (EVar "n")) (EVar "False")))
(DFunDef false "mapTyInExpr" (PWild (PCon "EVarAt" (PVar "n") (PVar "a"))) (ETuple (EApp (EApp (EVar "EVarAt") (EVar "n")) (EVar "a")) (EVar "False")))
(DFunDef false "mapTyInExpr" (PWild (PCon "EMethodAt" (PVar "n") (PVar "r1") (PVar "r2") (PVar "r3"))) (ETuple (EApp (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (EVar "r1")) (EVar "r2")) (EVar "r3")) (EVar "False")))
(DFunDef false "mapTyInExpr" (PWild (PCon "EDictAt" (PVar "n") (PVar "r"))) (ETuple (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "r")) (EVar "False")))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "ELoc" (PVar "l") (PVar "e"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EApp (EVar "ELoc") (EVar "l")) (EVar "e2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" ((PVar "f") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EVar "e2")) (EVar "c")))))
(DFunDef false "mapTyInExpr" (PWild (PCon "ENumLit" (PVar "n") (PVar "rf") (PVar "rr") (PVar "lx"))) (ETuple (EApp (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EVar "rf")) (EVar "rr")) (EVar "lx")) (EVar "False")))
(DTypeSig false "mapExprsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyTuple (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool")))))
(DFunDef false "mapExprsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapExprsB" ((PVar "f") (PCons (PVar "e") (PVar "es"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoLet false false (PTuple (PVar "es2") (PVar "c2")) (EApp (EApp (EVar "mapExprsB") (EVar "f")) (EVar "es"))) (DoExpr (ETuple (EBinOp "::" (EVar "e2") (EVar "es2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapArmsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyTuple (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Bool")))))
(DFunDef false "mapArmsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapArmsB" ((PVar "f") (PCons (PCon "Arm" (PVar "p") (PVar "gs") (PVar "b")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "gs2") (PVar "c1")) (EApp (EApp (EVar "mapGuardsB") (EVar "f")) (EVar "gs"))) (DoLet false false (PTuple (PVar "b2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "b"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c3")) (EApp (EApp (EVar "mapArmsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EVar "gs2")) (EVar "b2")) (EVar "rest2")) (EBinOp "||" (EBinOp "||" (EVar "c1") (EVar "c2")) (EVar "c3"))))))
(DTypeSig false "mapGuardsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "Bool")))))
(DFunDef false "mapGuardsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapGuardsB" ((PVar "f") (PCons (PCon "GBool" (PVar "g")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "g2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "g"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapGuardsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "GBool") (EVar "g2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DFunDef false "mapGuardsB" ((PVar "f") (PCons (PCon "GBind" (PVar "p") (PVar "g")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "g2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "g"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapGuardsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GBind") (EVar "p")) (EVar "g2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapGuardArmsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyTuple (TyApp (TyCon "List") (TyCon "GuardArm")) (TyCon "Bool")))))
(DFunDef false "mapGuardArmsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapGuardArmsB" ((PVar "f") (PCons (PCon "GuardArm" (PVar "gs") (PVar "b")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "gs2") (PVar "c1")) (EApp (EApp (EVar "mapGuardsB") (EVar "f")) (EVar "gs"))) (DoLet false false (PTuple (PVar "b2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "b"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c3")) (EApp (EApp (EVar "mapGuardArmsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GuardArm") (EVar "gs2")) (EVar "b2")) (EVar "rest2")) (EBinOp "||" (EBinOp "||" (EVar "c1") (EVar "c2")) (EVar "c3"))))))
(DTypeSig false "mapDoStmtsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Bool")))))
(DFunDef false "mapDoStmtsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapDoStmtsB" ((PVar "f") (PCons (PVar "s") (PVar "ss"))) (EBlock (DoLet false false (PTuple (PVar "s2") (PVar "c1")) (EApp (EApp (EVar "mapDoStmtB") (EVar "f")) (EVar "s"))) (DoLet false false (PTuple (PVar "ss2") (PVar "c2")) (EApp (EApp (EVar "mapDoStmtsB") (EVar "f")) (EVar "ss"))) (DoExpr (ETuple (EBinOp "::" (EVar "s2") (EVar "ss2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapDoStmtB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyCon "DoStmt") (TyTuple (TyCon "DoStmt") (TyCon "Bool")))))
(DFunDef false "mapDoStmtB" ((PVar "f") (PCon "DoExpr" (PVar "e"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EVar "DoExpr") (EVar "e2")) (EVar "c")))))
(DFunDef false "mapDoStmtB" ((PVar "f") (PCon "DoBind" (PVar "p") (PVar "e"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EApp (EVar "DoBind") (EVar "p")) (EVar "e2")) (EVar "c")))))
(DFunDef false "mapDoStmtB" ((PVar "f") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EVar "e2")) (EVar "c")))))
(DFunDef false "mapDoStmtB" ((PVar "f") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EApp (EVar "DoAssign") (EVar "x")) (EVar "e2")) (EVar "c")))))
(DFunDef false "mapDoStmtB" ((PVar "f") (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EVar "e2")) (EVar "c")))))
(DTypeSig false "mapInterpsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "InterpPart")) (TyTuple (TyApp (TyCon "List") (TyCon "InterpPart")) (TyCon "Bool")))))
(DFunDef false "mapInterpsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapInterpsB" ((PVar "f") (PCons (PCon "InterpStr" (PVar "s")) (PVar "rest0"))) (EBlock (DoLet false false (PTuple (PVar "rest2") (PVar "c")) (EApp (EApp (EVar "mapInterpsB") (EVar "f")) (EVar "rest0"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "InterpStr") (EVar "s")) (EVar "rest2")) (EVar "c")))))
(DFunDef false "mapInterpsB" ((PVar "f") (PCons (PCon "InterpExpr" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "e2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapInterpsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "InterpExpr") (EVar "e2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapFieldAssignsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyTuple (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyCon "Bool")))))
(DFunDef false "mapFieldAssignsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapFieldAssignsB" ((PVar "f") (PCons (PCon "FieldAssign" (PVar "n") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "v2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "v"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c2")) (EApp (EApp (EVar "mapFieldAssignsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EVar "v2")) (EVar "rest2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DTypeSig false "mapKvsB" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr"))) (TyCon "Bool")))))
(DFunDef false "mapKvsB" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapKvsB" ((PVar "f") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "k2") (PVar "c1")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "k"))) (DoLet false false (PTuple (PVar "v2") (PVar "c2")) (EApp (EApp (EVar "mapTyInExpr") (EVar "f")) (EVar "v"))) (DoLet false false (PTuple (PVar "rest2") (PVar "c3")) (EApp (EApp (EVar "mapKvsB") (EVar "f")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (ETuple (EVar "k2") (EVar "v2")) (EVar "rest2")) (EBinOp "||" (EBinOp "||" (EVar "c1") (EVar "c2")) (EVar "c3"))))))
(DData Private "EffAction" () ((variant "ADrop" (ConPos)) (variant "ARename" (ConPos (TyCon "String")))) ())
(DTypeSig false "mkEffectLabels" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))))))
(DFunDef false "mkEffectLabels" ((PVar "args")) (EMatch (EApp (EApp (EVar "parseEffectArgs") (EVar "args")) (EListLit)) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "Ok" (PList)) () (EApp (EVar "Err") (ELit (LString "need at least one --strip <labels> or --rename Old=New")))) (arm (PCon "Ok" (PVar "acts")) () (EApp (EVar "Ok") (EApp (EVar "mapTyInDecl") (EApp (EVar "effTyNode") (EVar "acts")))))))
(DTypeSig false "parseEffectArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction")))))))
(DFunDef false "parseEffectArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "parseEffectArgs" ((PCons (PLit (LString "--strip")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseEffectArgs") (EVar "rest")) (EApp (EApp (EVar "prependDrops") (EApp (EApp (EVar "splitOnChar") (ELit (LChar ","))) (EVar "v"))) (EVar "acc"))))
(DFunDef false "parseEffectArgs" ((PCons (PLit (LString "--rename")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar "="))) (EVar "v")) (arm (PList (PVar "old") (PVar "nw")) () (EIf (EBinOp "||" (EBinOp "==" (EVar "old") (ELit (LString ""))) (EBinOp "==" (EVar "nw") (ELit (LString "")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "--rename expects Old=New, got '")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "'")))) (EApp (EApp (EVar "parseEffectArgs") (EVar "rest")) (EBinOp "::" (ETuple (EVar "old") (EApp (EVar "ARename") (EVar "nw"))) (EVar "acc"))))) (arm PWild () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "--rename expects Old=New, got '")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "'")))))))
(DFunDef false "parseEffectArgs" ((PList (PLit (LString "--strip"))) PWild) (EApp (EVar "Err") (ELit (LString "--strip requires a value (e.g. --strip Rand,Net)"))))
(DFunDef false "parseEffectArgs" ((PList (PLit (LString "--rename"))) PWild) (EApp (EVar "Err") (ELit (LString "--rename requires a value (e.g. --rename Old=New)"))))
(DFunDef false "parseEffectArgs" ((PCons (PVar "x") PWild) PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown argument '")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "'")))))
(DTypeSig false "prependDrops" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))))))
(DFunDef false "prependDrops" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "prependDrops" ((PCons (PVar "n") (PVar "ns")) (PVar "acc")) (EIf (EBinOp "==" (EVar "n") (ELit (LString ""))) (EApp (EApp (EVar "prependDrops") (EVar "ns")) (EVar "acc")) (EApp (EApp (EVar "prependDrops") (EVar "ns")) (EBinOp "::" (ETuple (EVar "n") (EVar "ADrop")) (EVar "acc")))))
(DTypeSig false "effTyNode" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "effTyNode" ((PVar "acts") (PCon "TyEffect" (PVar "es") (PVar "tail") (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "rewriteRow") (EVar "acts")) (EVar "es")) (EVar "tail")) (EVar "t")))
(DFunDef false "effTyNode" (PWild (PVar "ty")) (ETuple (EVar "ty") (EVar "False")))
(DTypeSig false "rewriteRow" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool")))))))
(DFunDef false "rewriteRow" ((PVar "acts") (PVar "es") (PVar "tail") (PVar "t")) (EBlock (DoLet false false (PVar "stepped") (EApp (EApp (EMethodRef "map") (EApp (EVar "applyAtom") (EVar "acts"))) (EVar "es"))) (DoLet false false (PVar "anyChanged") (EApp (EApp (EVar "anyList") (EVar "sndB")) (EVar "stepped"))) (DoLet false false (PVar "kept") (EApp (EVar "collectKept") (EVar "stepped"))) (DoLet false false (PVar "deduped") (EApp (EVar "dedupeAtoms") (EVar "kept"))) (DoLet false false (PVar "dedupChanged") (EBinOp "!=" (EApp (EVar "listLen") (EVar "deduped")) (EApp (EVar "listLen") (EVar "kept")))) (DoLet false false (PVar "changed") (EBinOp "||" (EVar "anyChanged") (EVar "dedupChanged"))) (DoExpr (EMatch (EVar "deduped") (arm (PList) () (EMatch (EVar "tail") (arm (PCon "None") () (EIf (EVar "changed") (ETuple (EVar "t") (EVar "True")) (ETuple (EApp (EApp (EApp (EVar "TyEffect") (EListLit)) (EVar "None")) (EVar "t")) (EVar "False")))) (arm (PCon "Some" (PVar "v")) () (ETuple (EApp (EApp (EApp (EVar "TyEffect") (EListLit)) (EApp (EVar "Some") (EVar "v"))) (EVar "t")) (EVar "changed"))))) (arm PWild () (ETuple (EApp (EApp (EApp (EVar "TyEffect") (EVar "deduped")) (EVar "tail")) (EVar "t")) (EVar "changed")))))))
(DTypeSig false "applyAtom" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyTuple (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyCon "Bool")))))
(DFunDef false "applyAtom" ((PVar "acts") (PTuple (PVar "label") (PVar "dom"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "label")) (EVar "acts")) (arm (PCon "None") () (ETuple (EApp (EVar "Some") (ETuple (EVar "label") (EVar "dom"))) (EVar "False"))) (arm (PCon "Some" (PCon "ADrop")) () (ETuple (EVar "None") (EVar "True"))) (arm (PCon "Some" (PCon "ARename" (PVar "nw"))) () (ETuple (EApp (EVar "Some") (ETuple (EVar "nw") (EVar "dom"))) (EVar "True")))))
(DTypeSig false "sndB" (TyFun (TyTuple (TyVar "a") (TyCon "Bool")) (TyCon "Bool")))
(DFunDef false "sndB" ((PTuple PWild (PVar "b"))) (EVar "b"))
(DTypeSig false "collectKept" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyCon "Bool"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "collectKept" ((PList)) (EListLit))
(DFunDef false "collectKept" ((PCons (PTuple (PCon "None") PWild) (PVar "rest"))) (EApp (EVar "collectKept") (EVar "rest")))
(DFunDef false "collectKept" ((PCons (PTuple (PCon "Some" (PVar "a")) PWild) (PVar "rest"))) (EBinOp "::" (EVar "a") (EApp (EVar "collectKept") (EVar "rest"))))
(DTypeSig false "dedupeAtoms" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "dedupeAtoms" ((PVar "xs")) (EApp (EApp (EVar "dedupeGo") (EVar "xs")) (EListLit)))
(DTypeSig false "dedupeGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "dedupeGo" ((PList) PWild) (EListLit))
(DFunDef false "dedupeGo" ((PCons (PVar "a") (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "atomElem") (EVar "a")) (EVar "seen")) (EApp (EApp (EVar "dedupeGo") (EVar "rest")) (EVar "seen")) (EBinOp "::" (EVar "a") (EApp (EApp (EVar "dedupeGo") (EVar "rest")) (EBinOp "::" (EVar "a") (EVar "seen"))))))
(DTypeSig false "atomElem" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyCon "Bool"))))
(DFunDef false "atomElem" (PWild (PList)) (EVar "False"))
(DFunDef false "atomElem" ((PVar "a") (PCons (PVar "b") (PVar "bs"))) (EBinOp "||" (EApp (EApp (EVar "atomEq") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "atomElem") (EVar "a")) (EVar "bs"))))
(DTypeSig false "atomEq" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Bool"))))
(DFunDef false "atomEq" ((PTuple (PVar "l1") (PVar "d1")) (PTuple (PVar "l2") (PVar "d2"))) (EBinOp "&&" (EBinOp "==" (EVar "l1") (EVar "l2")) (EApp (EApp (EVar "domEq") (EVar "d1")) (EVar "d2"))))
(DTypeSig false "domEq" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "domEq" ((PCon "None") (PCon "None")) (EVar "True"))
(DFunDef false "domEq" ((PCon "Some" (PVar "x")) (PCon "Some" (PVar "y"))) (EBinOp "==" (EVar "x") (EVar "y")))
(DFunDef false "domEq" (PWild PWild) (EVar "False"))
(DTypeSig false "warnEffectLabels" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "warnEffectLabels" ((PVar "args") (PVar "decls")) (EMatch (EApp (EApp (EVar "parseEffectArgs") (EVar "args")) (EListLit)) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "acts")) () (EApp (EApp (EVar "declEffectWarns") (EVar "acts")) (EVar "decls")))))
(DTypeSig false "declEffectWarns" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declEffectWarns" (PWild (PList)) (EListLit))
(DFunDef false "declEffectWarns" ((PVar "acts") (PCons (PVar "d") (PVar "ds"))) (EBinOp "++" (EApp (EApp (EVar "declEffectWarn") (EVar "acts")) (EVar "d")) (EApp (EApp (EVar "declEffectWarns") (EVar "acts")) (EVar "ds"))))
(DTypeSig false "declEffectWarn" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declEffectWarn" ((PVar "acts") (PCon "DEffect" PWild (PVar "name") PWild)) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "acts")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" PWild) () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'effect ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' is declared here but effect-labels targets "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "; the declaration is left untouched")))))))
(DFunDef false "declEffectWarn" ((PVar "acts") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declEffectWarn") (EVar "acts")) (EVar "d")))
(DFunDef false "declEffectWarn" (PWild PWild) (EListLit))
