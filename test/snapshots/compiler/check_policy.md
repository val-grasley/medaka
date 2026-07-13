# META
source_lines=728
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/check_policy.mdk — the native `medaka check-policy` capability
-- policy checker (WS-1a of EFFECTS-CONFORMANCE-ROADMAP.md).
--
-- A faithful port of bin/main.ml's `check-policy` arm (the §7c "minimal wow demo"
-- from CAPABILITY-PLATFORM.md), byte-identical accept/reject output.  Given a
-- plugin file, a policy (`--allow L1,L2,…`) and an entry function (`--fn name`):
--   1. parse + desugar the file;
--   2. build a call graph (name → set of called top-level names) from the
--      DESUGARED AST (conservative EVar collection, like collect_evars);
--   3. typecheck single-file (checkProgramSchemesWithRuntime, the same path
--      doc.mdk uses) for inferred schemes;
--   4. read each fn's inferred effect row → its concrete labels
--      (effrowLabels/atomLabel — the native analog of OCaml's effrow_labels);
--   5. policy compare: a label is forbidden iff it is NOT in the policy set
--      (WS-1a = BARE-LABEL compare — see the `-- WS-1b:` seam below; parameter-
--      level compare `--allow 'Net=host/*'` is the later WS-1b task);
--   6. if any forbidden label → REJECT with the call chain that introduces the
--      first forbidden effect; else ACCEPT and run the plugin on a sample
--      request with stub platform capabilities (cacheGet/cacheSet/logEvent).
--
-- Divergence note vs the OCaml oracle: OCaml runs the accepted plugin via
-- Eval.extra_prims (host-injected VPrim stubs for cacheGet/cacheSet/logEvent).
-- compiler's externBindings is fixed and user-declared `extern`s get no eval
-- cell, so we instead SYNTHESIZE Medaka stub funDefs (parsed from a tiny source
-- string) that shadow those names, prepend them to the prelude, and drive
-- evalModulesRootEnv + apply.  The stubbed `logEvent` writes the `   [LOG] …`
-- line directly to the captured output buffer (eval's outputRef), reproducing
-- OCaml's log-then-result ordering byte-for-byte.

import frontend.ast.{
  Decl(..),
  Expr(..),
  Pat(..),
  Lit(..),
  Arm(..),
  Guard(..),
  DoStmt(..),
  LetBind(..),
  FunClause(..),
  FieldAssign(..),
}
import frontend.parser.{parse}
import frontend.desugar.{desugar}
import types.typecheck.{
  Scheme(..),
  Mono(..),
  EffRow(..),
  Atom(..),
  Param(..),
  checkProgramSchemesWithRuntime,
  normalize,
  tupleSpine,
  effrowLabels,
  atomLabel,
  atomParam,
  dsub,
  drender,
  decodeProductParam,
  decodeSetParam,
}
import eval.eval.{Value(..), evalModulesRootEnv, apply, outputRef, ppValue}
import support.util.{sortUniqS, joinWith, reverseL, escStr}

-- ── policy-arg parsing ──────────────────────────────────────────────────────
-- Mirror bin/main.ml's parse_args: --allow / --fn carry a value; the first bare
-- positional is the file.  Defaults: allow "Cache,Log", fn "transform".
public export data PolicyArgs = PolicyArgs (Option String) String String

export parsePolicyArgs : List String -> PolicyArgs
parsePolicyArgs argv = parsePolicyGo argv None "Cache,Log" "transform"

parsePolicyGo : List String -> Option String -> String -> String -> PolicyArgs
parsePolicyGo [] file allow fn = PolicyArgs file allow fn
parsePolicyGo ("--allow"::v::rest) file _ fn = parsePolicyGo rest file v fn
parsePolicyGo ("--fn"::v::rest) file allow _ = parsePolicyGo rest file allow v
parsePolicyGo (f::rest) None allow fn = parsePolicyGo rest (Some f) allow fn
parsePolicyGo (f::rest) (file@(Some _)) allow fn =
  parsePolicyGo rest file allow fn

-- Split the --allow value on ',', dropping empties (mirror String.split_on_char
-- ',' then filter (<> "")).
splitComma : String -> List String
splitComma s =
  filterNonEmpty (splitCommaGo
    (stringToChars s)
    (arrayLength (stringToChars s))
    0
    0
    0)

-- WS-4: brace-depth-aware label split.  Commas INSIDE `{…}` (a product Method
-- set, e.g. `Method={GET,POST}`) do NOT separate policy labels.  `depth` tracks
-- nesting; a top-level comma (depth 0) splits.  Backward-compat: existing
-- brace-free policies have depth 0 throughout ⇒ identical to the old split.
splitCommaGo : Array Char -> Int -> Int -> Int -> Int -> List String
splitCommaGo cs n start i depth
  | i >= n = [sliceStr cs start n]
  | arrayGetUnsafe i cs == '{' = splitCommaGo cs n start (i + 1) (depth + 1)
  | arrayGetUnsafe i cs == '}' = splitCommaGo cs n start (i + 1) (depth - 1)
  | arrayGetUnsafe i cs == ',' && depth == 0 =
    sliceStr cs start i :: splitCommaGo cs n (i + 1) (i + 1) depth
  | otherwise = splitCommaGo cs n start (i + 1) depth

sliceStr : Array Char -> Int -> Int -> String
sliceStr cs a b = stringFromChars (arrayFromList (sliceGo cs a b))

sliceGo : Array Char -> Int -> Int -> List Char
sliceGo cs a b
  | a >= b = []
  | otherwise = arrayGetUnsafe a cs :: sliceGo cs (a + 1) b

filterNonEmpty : List String -> List String
filterNonEmpty [] = []
filterNonEmpty (x::xs) =
  if x == "" then
    filterNonEmpty xs
  else
    x :: filterNonEmpty xs

-- ── WS-1b: policy as (label, param) ─────────────────────────────────────────
-- Each comma-separated token is either a bare label `L` (→ policy param ⊤ =
-- PPrefix None, identical to the WS-1a membership test) or `L=rhs` (→ policy
-- param PPrefix (Some rhs); a written `<Net "pat">` is PPrefix (Some pat), so a
-- policy RHS maps directly).  One entry per label (last wins via lookup order).
parsePolicy : String -> List (String, Param)
parsePolicy s = map parsePolicyTok (splitComma s)

parsePolicyTok : String -> (String, Param)
parsePolicyTok tok = match splitOnFirstEq (stringToChars tok) (arrayLength (stringToChars tok)) 0
  None => (tok, PPrefix None)
  Some i =>
    let cs = stringToChars tok
    let n = arrayLength cs
    let label = sliceStr cs 0 i
    let rhs = sliceStr cs (i + 1) n
    -- WS-4: a PRODUCT policy rhs (`Host="…";Method={…}`) carries an axis `=`.
    -- Detect it and decode via the shared `decodeProductParam` (wrapping in the
    -- carrier sentinel `@P{…}`), so the policy compare reaches `dsub` over a
    -- `PProduct` — pointwise subsumption is inherited.  A plain prefix rhs
    -- (`a.com/*`, no axis `=`) stays `PPrefix (Some rhs)`, byte-identical to WS-1b.
    if rhsIsProduct rhs
    then (label, decodeProductParam ("@P{" ++ rhs ++ "}"))
    else if rhsIsSet rhs
    then (label, PSet (Some (decodeSetParam rhs)))
    else (label, PPrefix (Some rhs))

-- a policy rhs is a product when it contains an axis assignment `=` (after the
-- label `=` already consumed) — e.g. `Host="…"` / `Method={…}`.  A bare prefix
-- pattern (`a.com/*`) has no `=`.
rhsIsProduct : String -> Bool
rhsIsProduct rhs = match splitOnFirstEq (stringToChars rhs) (arrayLength (stringToChars rhs)) 0
  None => False
  Some _ => True

-- a policy rhs is a top-level Set-domain literal when it is brace-delimited
-- (`Env={HOME,PATH}`) with no axis `=` inside (that's the product case, already
-- routed above) — mirrors the written-annotation carrier `decodeSetParam` decodes
-- (`atomOfWritten`/`decodeAxisVal` in types.typecheck).
rhsIsSet : String -> Bool
rhsIsSet rhs =
  let n = stringLength rhs
  n >= 2 && stringSlice 0 1 rhs == "{" && stringSlice (n - 1) n rhs == "}"

-- Index of the first '=' in the char array, or None.
splitOnFirstEq : Array Char -> Int -> Int -> Option Int
splitOnFirstEq cs n i
  | i >= n = None
  | arrayGetUnsafe i cs == '=' = Some i
  | otherwise = splitOnFirstEq cs n (i + 1)

-- The bare-label list of a policy (for the reject report's `{…}` rendering,
-- byte-identical to WS-1a: a bare entry renders as the label; a parameterized
-- entry renders `L "pat"`).
policyLabels : List (String, Param) -> List String
policyLabels [] = []
policyLabels ((l, p)::rest) = l ++ drender p :: policyLabels rest

lookupParam : String -> List (String, Param) -> Option Param
lookupParam _ [] = None
lookupParam k ((l, p)::rest) = if k == l then Some p else lookupParam k rest

-- ── 2. call graph from the desugared AST ────────────────────────────────────
-- collectEVars: every EVar name referenced in an expression (conservative —
-- includes non-call uses, safe for the chain heuristic).  Mirror collect_evars
-- in bin/main.ml; the desugared tree has no EGuards/ESection/EBlock
-- surface sugar, so those arms are omitted (already lowered).
collectEVars : Expr -> List String
collectEVars (EVar n) = [n]
collectEVars (ELoc _ e) = collectEVars e
collectEVars (EMethodRef n) = [n]
collectEVars (EDictApp n) = [n]
collectEVars (EApp f x) = collectEVars f ++ collectEVars x
collectEVars (ELam _ body) = collectEVars body
collectEVars (ELet _ _ _ v body) = collectEVars v ++ collectEVars body
collectEVars (ELetGroup binds body) = concatMapCP collectBind binds
  ++ collectEVars body
collectEVars (EMatch e arms) = collectEVars e ++ concatMapCP collectArm arms
collectEVars (EIf c t f) = collectEVars c ++ collectEVars t ++ collectEVars f
collectEVars (EBinOp _ a b _) = collectEVars a ++ collectEVars b
collectEVars (EUnOp _ e _) = collectEVars e
collectEVars (EInfix _ a b) = collectEVars a ++ collectEVars b
collectEVars (EAnnot e _) = collectEVars e
collectEVars (EHeadAnnot e _) = collectEVars e
collectEVars (EFieldAccess e _ _) = collectEVars e
collectEVars (ERecordCreate _ flds) = concatMapCP collectFieldAssign flds
collectEVars (ERecordUpdate e flds _) = collectEVars e
  ++ concatMapCP collectFieldAssign flds
collectEVars (EVariantUpdate _ e flds) = collectEVars e
  ++ concatMapCP collectFieldAssign flds
collectEVars (ETuple es) = concatMapCP collectEVars es
collectEVars (EListLit es) = concatMapCP collectEVars es
collectEVars (EArrayLit es) = concatMapCP collectEVars es
collectEVars (ERangeList a b _) = collectEVars a ++ collectEVars b
collectEVars (ERangeArray a b _) = collectEVars a ++ collectEVars b
collectEVars (ESlice a b c _ _) = collectEVars a
  ++ collectEVars b
  ++ collectEVars c
collectEVars (EIndex a b _) = collectEVars a ++ collectEVars b
collectEVars (EBlock stmts) = concatMapCP collectStmt stmts
collectEVars (EDo stmts) = concatMapCP collectStmt stmts
collectEVars _ = []

collectBind : LetBind -> List String
collectBind (LetBind _ clauses) = concatMapCP collectClause clauses

collectClause : FunClause -> List String
collectClause (FunClause _ body) = collectEVars body

collectArm : Arm -> List String
collectArm (Arm _ guards body) = concatMapCP collectGuard guards
  ++ collectEVars body

collectGuard : Guard -> List String
collectGuard (GBool e) = collectEVars e
collectGuard (GBind _ e) = collectEVars e

collectFieldAssign : FieldAssign -> List String
collectFieldAssign (FieldAssign _ e) = collectEVars e

collectStmt : DoStmt -> List String
collectStmt (DoExpr e) = collectEVars e
collectStmt (DoBind _ e) = collectEVars e
collectStmt (DoLet _ _ _ e) = collectEVars e
collectStmt (DoAssign _ e) = collectEVars e
collectStmt (DoFieldAssign _ _ e) = collectEVars e

concatMapCP : (a -> List b) -> List a -> List b
concatMapCP _ [] = []
concatMapCP f (x::xs) = f x ++ concatMapCP f xs

-- A top-level name (DFunDef or DExtern), peeling DAttrib.  Mirror inner_decl +
-- the DFunDef/DExtern match in the OCaml call-graph builder.
topName : Decl -> Option String
topName (DFunDef _ n _ _) = Some n
topName (DExtern _ n _) = Some n
topName (DAttrib _ d) = topName d
topName _ = None

-- (name, body-EVars) for each top-level DFunDef (externs have no body).
fnBody : Decl -> Option (String, List String)
fnBody (DFunDef _ n _ body) = Some (n, collectEVars body)
fnBody (DAttrib _ d) = fnBody d
fnBody _ = None

-- The call graph: name → callees restricted to top-level names.  `assoc list`.
buildCallGraph : List Decl -> List (String, List String)
buildCallGraph decls =
  let tops = collectOpts (map topName decls)
  let bodies = collectOpts (map fnBody decls)
  map (restrictBody tops) bodies

restrictBody : List String -> (String, List String) -> (String, List String)
restrictBody tops (n, refs) = (n, intersectStr refs tops)

intersectStr : List String -> List String -> List String
intersectStr xs ys = filterMember xs ys

filterMember : List String -> List String -> List String
filterMember [] _ = []
filterMember (x::xs) ys =
  if memberStr x ys then
    x :: filterMember xs ys
  else
    filterMember xs ys

collectOpts : List (Option a) -> List a
collectOpts [] = []
collectOpts (None::rest) = collectOpts rest
collectOpts ((Some x)::rest) = x :: collectOpts rest

memberStr : String -> List String -> Bool
memberStr _ [] = False
memberStr x (y::ys) = if x == y then True else memberStr x ys

lookupAssocL : String -> List (String, a) -> Option a
lookupAssocL _ [] = None
lookupAssocL k ((n, v)::rest) = if k == n then Some v else lookupAssocL k rest

-- ── 4. effect ATOMS from a scheme (WS-1b: keep the param, not just the label) ─
-- Walk the normalized mono: at each TFun, collect the row's atoms (effrowLabels
-- already returns Atoms), recurse into the result; at TApp recurse into both
-- sides.  Deduped/sorted by label.  Mirror mono_effects / scheme_effects, but
-- the threaded representation is now `Atom` so the param survives to the compare.
monoEffects : Mono -> List Atom
monoEffects m = match normalize m
  TFun _ row result =>
    let atoms = effrowLabels row
    sortUniqAtoms (atoms ++ monoEffects result)
  -- Fork C (Stage 1 preservation): a tuple TYPE is now a `__tupleN__`-headed
  -- `TApp` spine rather than the old atomic `Mono.TTuple`.  The old code sent
  -- `TTuple` to the catch-all `_ => []` (element effects ignored); reproduce
  -- that exactly here instead of letting the generic `TApp` arm recurse in.
  TApp a b => match tupleSpine (TApp a b)
    Some _ => []
    None => sortUniqAtoms (monoEffects a ++ monoEffects b)
  _ => []

schemeEffects : Scheme -> List Atom
schemeEffects (Forall _ _ mono) = monoEffects mono

-- Sort atoms by label and drop label-duplicates (first atom of a label wins;
-- in practice a row carries one atom per label after normalization).
sortUniqAtoms : List Atom -> List Atom
sortUniqAtoms atoms = dedupAtoms (sortAtoms atoms)

sortAtoms : List Atom -> List Atom
sortAtoms [] = []
sortAtoms (x::xs) = insertAtom x (sortAtoms xs)

insertAtom : Atom -> List Atom -> List Atom
insertAtom x [] = [x]
insertAtom x (y::ys) =
  if stringLeq (atomLabel x) (atomLabel y) then
    x :: y::ys
  else
    y :: insertAtom x ys

stringLeq : String -> String -> Bool
stringLeq a b = match stringCompare a b
  Gt => False
  _ => True

dedupAtoms : List Atom -> List Atom
dedupAtoms [] = []
dedupAtoms [x] = [x]
dedupAtoms (x::y::rest) =
  if atomLabel x == atomLabel y then
    dedupAtoms (x::rest)
  else
    x :: dedupAtoms (y::rest)

-- The label view of an atom list (for header rendering + chain keys).  Each atom
-- renders `label` (⊤ param) or `label "pat"` (concrete) via drender — byte-
-- identical to WS-1a for ⊤ params (drender ⊤ = "").
atomLabels : List Atom -> List String
atomLabels [] = []
atomLabels (a::rest) = atomLabel a ++ drender (atomParam a) :: atomLabels rest

-- (name, effect-atoms) for every fn whose scheme carries a non-empty effect set.
fnEffectsTable : List (String, Scheme) -> List (String, List Atom)
fnEffectsTable [] = []
fnEffectsTable ((name, sch)::rest) = match schemeEffects sch
  [] => fnEffectsTable rest
  effs => (name, effs) :: fnEffectsTable rest

-- Does fn `name` carry an atom whose LABEL is `label`?  (Chain reconstruction
-- stays label-keyed — the param does not participate in the call-graph trace.)
fnHasEffect : List (String, List Atom) -> String -> String -> Bool
fnHasEffect table name label = match lookupAssocL name table
  None => False
  Some effs => memberStr label (map atomLabel effs)

-- ── 6. call-chain reconstruction ────────────────────────────────────────────
-- find_chain: from `start`, repeatedly hop to the lexicographically-smallest
-- callee that carries `forbiddenLabel`, stopping at a leaf or a revisit (mirror
-- SS.find_first_opt over the sorted callee set + the `visited` cutoff).
findChain : List (String, List String) -> List (String, List Atom) -> String -> String -> List String
findChain callGraph effTable start forbiddenLabel =
  traceChain callGraph effTable forbiddenLabel start [start]

traceChain : List (String, List String) -> List (String, List Atom) -> String -> String -> List String -> List String
traceChain callGraph effTable forbiddenLabel fn visited =
  let callees = match lookupAssocL fn callGraph
    None => []
    Some s => s
  -- SS.find_first_opt picks the SMALLEST name; sortUniqS the callees, take first
  -- carrying the forbidden effect.
  match firstWithEffect effTable forbiddenLabel (sortUniqS callees)
    None => [fn]
    Some c => if memberStr c visited then [fn, c]
      else fn :: traceChain callGraph effTable forbiddenLabel c (c :: visited)

firstWithEffect : List (String, List Atom) -> String -> List String -> Option String
firstWithEffect _ _ [] = None
firstWithEffect effTable label (c::rest) =
  if fnHasEffect effTable c label then
    Some c
  else
    firstWithEffect effTable label rest

-- ── 5. policy filtering (WS-1b: parameter-level compare via dsub) ────────────
-- An atom is FORBIDDEN iff EITHER its label is absent from the policy, OR (label
-- present with policy param `pp`) `dsub inferredParam pp` is FALSE — i.e. the
-- inferred authority is NOT within the policy's authority.  Returns the offending
-- LABELS (the chain trace + reject report stay label-keyed).  Bare `--allow Net`
-- ⟹ policy param ⊤ (PPrefix None) ⟹ `dsub _ ⊤` = True ⟹ identical to WS-1a's
-- membership test.  Reuse `dsub` — do NOT reimplement the prefix logic.
forbiddenLabels : List Atom -> List (String, Param) -> List String
forbiddenLabels effs policy = filterForbidden effs policy

filterForbidden : List Atom -> List (String, Param) -> List String
filterForbidden [] _ = []
filterForbidden (a::rest) policy =
  if atomPermitted a policy then
    filterForbidden rest policy
  else
    atomLabel a :: filterForbidden rest policy

-- Permitted iff the label is in the policy AND the inferred param is ⊑ the
-- policy param.
atomPermitted : Atom -> List (String, Param) -> Bool
atomPermitted a policy = match lookupParam (atomLabel a) policy
  None => False
  Some pp => dsub (atomParam a) pp

-- ── 7. accept: run the plugin on a sample request with stub capabilities ─────
-- Synthetic stub funDefs that shadow the user-declared platform externs.  Parsed
-- from source so we don't hand-build the `stringConcat`/literal AST.  `logEvent`
-- writes the OCaml-format `   [LOG] <s>\n` line straight to the captured output
-- buffer (eval forces putStr → outputRef), so the log lines land BEFORE the
-- transform-result line we print afterward — matching the oracle's ordering.
--
-- The stdlib platform externs (getEnv/runCommand/readFile/writeFile/… — the
-- file/net/env catalog declared in stdlib/runtime.mdk) are native-only: they
-- have NO binding under the tree-walk interpreter, so a plugin that reaches one
-- during this accept-path demo run would panic `unbound identifier: getEnv`,
-- leaking a stray runtime-error line before the (correct, statically-derived)
-- verdict.  We stub them here as effectful NO-OPS returning a benign placeholder
-- (`None` / `Err ""` / `[]`), so the demo run completes cleanly.  This ONLY
-- affects check-policy's accept demo; `medaka run` never touches these stubs and
-- keeps its native-only behaviour.  These bodies are eval'd but never
-- typechecked, so `Err ""` serves for EVERY `Result _ a`-returning extern
-- regardless of the Ok payload type.
stubSource : String
stubSource = stringConcat
  [
    "cacheGet req = \"\"\n",
    "cacheSet req result = ()\n",
    "logEvent s = putStr (stringConcat [\"   [LOG] \", s, \"\\n\"])\n",
    -- env
    "getEnv k = None\n",
    "args u = []\n",
    "executablePath u = \"\"\n",
    -- file read
    "readFile p = Err \"\"\n",
    "readFileBytes p = Err \"\"\n",
    "fileExists p = False\n",
    "canonicalizePath p = p\n",
    "listDir p = Err \"\"\n",
    "statFile p = Err \"\"\n",
    -- file write
    "writeFile p c = Err \"\"\n",
    "writeFileBytes p b = Err \"\"\n",
    "appendFile p c = Err \"\"\n",
    "makeDir p = Err \"\"\n",
    "removeFile p = Err \"\"\n",
    "rename o n = Err \"\"\n",
    "removeDir p = Err \"\"\n",
    -- exec
    "runCommand cmd a = Err \"\"\n",
    -- net
    "netResolve h = Err \"\"\n",
    "netTcpConnect h p = Err \"\"\n",
    "netTcpListen h p = Err \"\"\n",
    "netListenPort fd = Err \"\"\n",
    "netTcpAccept fd = Err \"\"\n",
    "netSend fd b = Err \"\"\n",
    "netRecv fd n = Err \"\"\n",
    "netShutdown fd how = Err \"\"\n",
    "netClose fd = Err \"\"\n",
    "netSetTimeout fd ms = Err \"\"\n",
  ]

-- Run `fn` on the sample request "X-Forwarded-For: 192.168.1.1" with stub
-- platform impls, returning the captured stdout (LOG lines) ++ the transform
-- line.  Mirror the OCaml accept-path eval block.
runPlugin : String -> List Decl -> List Decl -> List Decl -> <Mut> String
runPlugin fnName rtD coreD userD =
  let stubD = desugar (parse stubSource)
  let prelude = coreD ++ stubD
  let _ = setRef outputRef ""
  let rootEnv = evalModulesRootEnv prelude [("__plugin__", userD)]
  match lookupValue fnName rootEnv
    None => "   (no '" ++ fnName ++ "' binding in output)\n"
    Some fnVal =>
      let sample = "X-Forwarded-For: 192.168.1.1"
      let result = apply fnVal (VString sample)
      let logged = outputRef.value
      "\{logged}   transform \{escStr sample} = \{ppValue result}\n"

lookupValue : String -> List (String, Value e) -> Option (Value e)
lookupValue _ [] = None
lookupValue k ((n, v)::rest) = if k == n then Some v else lookupValue k rest

-- ── driver ──────────────────────────────────────────────────────────────────
-- runCheckPolicy returns (report, accepted?): the caller prints the report and
-- sets the exit code (0 accept / 1 reject) — mirroring the OCaml arm's exit
-- behaviour while keeping IO at the CLI boundary.  rtSrc/coreSrc are the prelude
-- sources (runtime.mdk/core.mdk); src is the plugin file.
-- The outcome of a policy check.  Accept carries the header and the desugared
-- decls needed to RUN the plugin (deferred so the CLI can print the header to
-- stdout BEFORE the run — which may panic on an unstubbed extern, exactly like
-- the OCaml arm prints the accept line then lets the eval panic hit stderr).
-- Reject carries the full report; the run never happens.
public export data PolicyOutcome =
  | PolicyAccept String String (List Decl) (List Decl) (List Decl)  -- header fn coreD rtD userD
  | PolicyReject String

export runCheckPolicy : String -> String -> String -> String -> String -> <Mut> PolicyOutcome
runCheckPolicy rtSrc coreSrc src allowStr fnName =
  let policy = parsePolicy allowStr
  let rawUser = parse src
  let userD = desugar rawUser
  let rtD = desugar (parse rtSrc)
  let coreD = desugar (parse coreSrc)
  let callGraph = buildCallGraph userD
  let schemes = checkProgramSchemesWithRuntime rtD (coreD ++ userD)
  let effTable = fnEffectsTable schemes
  let fnEffects = match lookupAssocL fnName effTable
    None => []
    Some e => e
  let forbidden = forbiddenLabels fnEffects policy
  match forbidden
    [] =>
      let effStr = if listIsEmpty fnEffects then
        "pure"
      else
        "<" ++ joinWith ", " (atomLabels fnEffects) ++ ">"
      let header = "accepted. \{fnName} requires only \{effStr}\n"
      PolicyAccept header fnName coreD rtD userD
    _ =>
      let chain = findChain callGraph effTable fnName (firstOf forbidden)
      let header = "rejected. \{fnName} requires <\{joinWith ", " (atomLabels fnEffects)}>. Not permitted by policy {\{joinWith ", " (policyLabels policy)}}\n"
      let via = "   reached via: " ++ joinWith " → " chain ++ "\n"
      PolicyReject (header ++ via)

-- Run the accepted plugin and return the captured run output (LOG lines + the
-- transform-result line).  Called by the CLI AFTER it has printed the accept
-- header, so a panic on an unstubbed extern surfaces post-header (oracle parity).
export runAcceptedPlugin : String -> List Decl -> List Decl -> List Decl -> <Mut> String
runAcceptedPlugin fnName coreD rtD userD = runPlugin fnName rtD coreD userD

firstOf : List String -> String
firstOf [] = ""
firstOf (x::_) = x

listIsEmpty : List a -> Bool
listIsEmpty [] = True
listIsEmpty _ = False

-- ── WS-1c: capability manifest emission ─────────────────────────────────────
-- Emit a module's verified capability manifest as a TOML artifact.
-- M(module) = filter_security(verified-row of the entry point) — §7 of
-- EFFECTS-SEMANTICS.md.
--
-- Security/internal classification (§7, lines ~441-466):
--   internal: Mut, Panic (purity/divergence tracking; no host counterpart)
--   security: everything else (all ioAlias labels + every user `effect Foo`)
-- Rule: isSecurity l = not (l == "Mut" || l == "Panic")
--
-- TOML value rendering:
--   PPrefix (Some s) → key = "s"   (concrete prefix/param as a string value)
--   PUnit / PPrefix None → key = true  (bare ⊤ grant — host decides scope)
--
-- Output order: labels sorted ascending (stable/gateable).
-- Labels already arrive sorted from monoEffects/sortUniqAtoms.
--
-- WS-1c (deferred): Wasm custom section — would embed M(module) into the
-- compiled .wasm binary as a custom section.  Touches wasm_emit.mdk; left
-- as a seam.  Add a `-- WS-1c wasm: encode M as custom section bytes` marker
-- in backend/wasm_emit.mdk when that work is picked up.

-- Is a label a security label (goes in the manifest)?
-- All labels except Mut and Panic are security.  User-declared `effect Foo`
-- defaults to security (no host override path exists yet), so the rule is
-- simply: drop the two known internal labels.
isSecurity : String -> Bool
isSecurity l = not (l == "Mut" || l == "Panic")

-- Render one atom as a TOML key-value line.
-- PPrefix (Some s) → 'Label = "s"'
-- PUnit / PPrefix None → 'Label = true'
atomToToml : Atom -> String
atomToToml a =
  let label = atomLabel a
  match atomParam a
    PPrefix (Some s) => "\{label} = \"\{s}\""
    PSet (Some xs) => "\{label} = [\{joinWith ", " (map quoteTok xs)}]"
    PProduct ax => "\{label} = { \{productTomlInline ax} }"   -- WS-4 inline table
    _ => label ++ " = true"

-- WS-4: render a product's axes as a TOML inline-table body: a Prefix axis →
-- `host = "…"`, a Set axis → `method = ["GET", "POST"]` (TOML keys lowercased
-- by convention).  Comma-joined.
productTomlInline : List (String, Param) -> String
productTomlInline ax = joinWith ", " (map axisToToml ax)

axisToToml : (String, Param) -> String
axisToToml (name, PPrefix (Some s)) = "\{lowerFirst name} = \"\{s}\""
axisToToml (name, PSet (Some xs)) =
  "\{lowerFirst name} = [\{joinWith ", " (map quoteTok xs)}]"
axisToToml (name, _) = lowerFirst name ++ " = true"

quoteTok : String -> String
quoteTok s = "\"" ++ s ++ "\""

-- lowercase the first char of an axis name (Host → host) for TOML-key convention.
lowerFirst : String -> String
lowerFirst s =
  let n = stringLength s
  if n == 0 then s else lowerChar (stringSlice 0 1 s) ++ stringSlice 1 n s

lowerChar : String -> String
lowerChar "H" = "h"
lowerChar "M" = "m"
lowerChar "S" = "s"
lowerChar "P" = "p"
lowerChar c = c

-- Filter atoms to security labels only, then render TOML.
-- Returns the full TOML block (empty string if no security effects).
export manifestToml : List Atom -> String
manifestToml atoms =
  let secAtoms = filterSecurity atoms
  match secAtoms
    [] => "[package.capabilities]\n"
    _ =>
      let lines = map atomToToml secAtoms
      "[package.capabilities]\n" ++ joinTomlLines lines

joinTomlLines : List String -> String
joinTomlLines [] = ""
joinTomlLines (x::xs) = "\{x}\n\{joinTomlLines xs}"

filterSecurity : List Atom -> List Atom
filterSecurity [] = []
filterSecurity (a::rest) =
  if isSecurity (atomLabel a) then
    a :: filterSecurity rest
  else
    filterSecurity rest

-- Parse args for `medaka manifest <file.mdk> [--fn name]`.
-- Default fn name: "main" (the conventional entry point for manifest extraction;
-- differs from check-policy's "transform" which is the plugin convention).
public export data ManifestArgs = ManifestArgs (Option String) String

export parseManifestArgs : List String -> ManifestArgs
parseManifestArgs argv = parseManifestGo argv None "main"

parseManifestGo : List String -> Option String -> String -> ManifestArgs
parseManifestGo [] file fn = ManifestArgs file fn
parseManifestGo ("--fn"::v::rest) file _ = parseManifestGo rest file v
parseManifestGo (f::rest) None fn = parseManifestGo rest (Some f) fn
parseManifestGo (f::rest) (file@(Some _)) fn = parseManifestGo rest file fn

-- Run manifest extraction: typecheck the file, read the named fn's inferred
-- effect row, filter to security labels, return TOML.
-- Returns (toml, fnEffects) so the caller can also drive round-trip validation.
export runManifest : String -> String -> String -> String -> <Mut> String
runManifest rtSrc coreSrc src fnName =
  let rawUser = parse src
  let userD = desugar rawUser
  let rtD = desugar (parse rtSrc)
  let coreD = desugar (parse coreSrc)
  let schemes = checkProgramSchemesWithRuntime rtD (coreD ++ userD)
  let effTable = fnEffectsTable schemes
  let fnEffects = match lookupAssocL fnName effTable
    None => []
    Some e => e
  manifestToml fnEffects

-- Render the manifest as --allow tokens for round-trip through check-policy.
-- PPrefix (Some s) → "Label=s"
-- PUnit / PPrefix None → "Label"
-- Returns a comma-joined string suitable for --allow.
export manifestToAllowStr : List Atom -> String
manifestToAllowStr atoms =
  let secAtoms = filterSecurity atoms
  let toks = map atomToAllowTok secAtoms
  joinWith "," toks

atomToAllowTok : Atom -> String
atomToAllowTok a =
  let label = atomLabel a
  match atomParam a
    PPrefix (Some s) => "\{label}=\{s}"
    PSet (Some xs) => "\{label}={\{joinWith "," xs}}"
    PProduct ax => "\{label}=\{productAllowRhs ax}"   -- WS-4 round-trip form
    _ => label

-- WS-4: render product axes as a policy `--allow` rhs `Host="…";Method={…}` —
-- `;`-separated so it round-trips through `parsePolicyTok`/`splitComma` (the
-- brace-depth-aware comma split keeps `{…}` intact).
productAllowRhs : List (String, Param) -> String
productAllowRhs ax = joinSemiTok (map axisToAllow ax)

axisToAllow : (String, Param) -> String
axisToAllow (name, PPrefix (Some s)) = "\{name}=\"\{s}\""
axisToAllow (name, PSet (Some xs)) = "\{name}={\{joinWith "," xs}}"
axisToAllow (name, _) = name ++ "=true"

joinSemiTok : List String -> String
joinSemiTok xs = joinWith ";" xs

-- Full manifest extraction returning the atom list (for round-trip gate).
export runManifestAtoms : String -> String -> String -> String -> <Mut> List Atom
runManifestAtoms rtSrc coreSrc src fnName =
  let rawUser = parse src
  let userD = desugar rawUser
  let rtD = desugar (parse rtSrc)
  let coreD = desugar (parse coreSrc)
  let schemes = checkProgramSchemesWithRuntime rtD (coreD ++ userD)
  let effTable = fnEffectsTable schemes
  let fnEffects = match lookupAssocL fnName effTable
    None => []
    Some e => e
  filterSecurity fnEffects
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Pat" true) (mem "Lit" true) (mem "Arm" true) (mem "Guard" true) (mem "DoStmt" true) (mem "LetBind" true) (mem "FunClause" true) (mem "FieldAssign" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "Scheme" true) (mem "Mono" true) (mem "EffRow" true) (mem "Atom" true) (mem "Param" true) (mem "checkProgramSchemesWithRuntime" false) (mem "normalize" false) (mem "tupleSpine" false) (mem "effrowLabels" false) (mem "atomLabel" false) (mem "atomParam" false) (mem "dsub" false) (mem "drender" false) (mem "decodeProductParam" false) (mem "decodeSetParam" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "evalModulesRootEnv" false) (mem "apply" false) (mem "outputRef" false) (mem "ppValue" false))))
(DUse false (UseGroup ("support" "util") ((mem "sortUniqS" false) (mem "joinWith" false) (mem "reverseL" false) (mem "escStr" false))))
(DData Public "PolicyArgs" () ((variant "PolicyArgs" (ConPos (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String") (TyCon "String")))) ())
(DTypeSig true "parsePolicyArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "PolicyArgs")))
(DFunDef false "parsePolicyArgs" ((PVar "argv")) (EApp (EApp (EApp (EApp (EVar "parsePolicyGo") (EVar "argv")) (EVar "None")) (ELit (LString "Cache,Log"))) (ELit (LString "transform"))))
(DTypeSig false "parsePolicyGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "PolicyArgs"))))))
(DFunDef false "parsePolicyGo" ((PList) (PVar "file") (PVar "allow") (PVar "fn")) (EApp (EApp (EApp (EVar "PolicyArgs") (EVar "file")) (EVar "allow")) (EVar "fn")))
(DFunDef false "parsePolicyGo" ((PCons (PLit (LString "--allow")) (PCons (PVar "v") (PVar "rest"))) (PVar "file") PWild (PVar "fn")) (EApp (EApp (EApp (EApp (EVar "parsePolicyGo") (EVar "rest")) (EVar "file")) (EVar "v")) (EVar "fn")))
(DFunDef false "parsePolicyGo" ((PCons (PLit (LString "--fn")) (PCons (PVar "v") (PVar "rest"))) (PVar "file") (PVar "allow") PWild) (EApp (EApp (EApp (EApp (EVar "parsePolicyGo") (EVar "rest")) (EVar "file")) (EVar "allow")) (EVar "v")))
(DFunDef false "parsePolicyGo" ((PCons (PVar "f") (PVar "rest")) (PCon "None") (PVar "allow") (PVar "fn")) (EApp (EApp (EApp (EApp (EVar "parsePolicyGo") (EVar "rest")) (EApp (EVar "Some") (EVar "f"))) (EVar "allow")) (EVar "fn")))
(DFunDef false "parsePolicyGo" ((PCons (PVar "f") (PVar "rest")) (PAs "file" (PCon "Some" PWild)) (PVar "allow") (PVar "fn")) (EApp (EApp (EApp (EApp (EVar "parsePolicyGo") (EVar "rest")) (EVar "file")) (EVar "allow")) (EVar "fn")))
(DTypeSig false "splitComma" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitComma" ((PVar "s")) (EApp (EVar "filterNonEmpty") (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EApp (EVar "stringToChars") (EVar "s"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "s")))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig false "splitCommaGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitCommaGo" ((PVar "cs") (PVar "n") (PVar "start") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EVar "start")) (EVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "{"))) (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "}"))) (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar ","))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EBinOp "::" (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EVar "start")) (EVar "i")) (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "sliceStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "sliceStr" ((PVar "cs") (PVar "a") (PVar "b")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "sliceGo") (EVar "cs")) (EVar "a")) (EVar "b")))))
(DTypeSig false "sliceGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "sliceGo" ((PVar "cs") (PVar "a") (PVar "b")) (EIf (EBinOp ">=" (EVar "a") (EVar "b")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "a")) (EVar "cs")) (EApp (EApp (EApp (EVar "sliceGo") (EVar "cs")) (EBinOp "+" (EVar "a") (ELit (LInt 1)))) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "filterNonEmpty" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "filterNonEmpty" ((PList)) (EListLit))
(DFunDef false "filterNonEmpty" ((PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "==" (EVar "x") (ELit (LString ""))) (EApp (EVar "filterNonEmpty") (EVar "xs")) (EBinOp "::" (EVar "x") (EApp (EVar "filterNonEmpty") (EVar "xs")))))
(DTypeSig false "parsePolicy" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))
(DFunDef false "parsePolicy" ((PVar "s")) (EApp (EApp (EVar "map") (EVar "parsePolicyTok")) (EApp (EVar "splitComma") (EVar "s"))))
(DTypeSig false "parsePolicyTok" (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "Param"))))
(DFunDef false "parsePolicyTok" ((PVar "tok")) (EMatch (EApp (EApp (EApp (EVar "splitOnFirstEq") (EApp (EVar "stringToChars") (EVar "tok"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "tok")))) (ELit (LInt 0))) (arm (PCon "None") () (ETuple (EVar "tok") (EApp (EVar "PPrefix") (EVar "None")))) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "tok"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoLet false false (PVar "label") (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (ELit (LInt 0))) (EVar "i"))) (DoLet false false (PVar "rhs") (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (DoExpr (EIf (EApp (EVar "rhsIsProduct") (EVar "rhs")) (ETuple (EVar "label") (EApp (EVar "decodeProductParam") (EBinOp "++" (EBinOp "++" (ELit (LString "@P{")) (EVar "rhs")) (ELit (LString "}"))))) (EIf (EApp (EVar "rhsIsSet") (EVar "rhs")) (ETuple (EVar "label") (EApp (EVar "PSet") (EApp (EVar "Some") (EApp (EVar "decodeSetParam") (EVar "rhs"))))) (ETuple (EVar "label") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "rhs")))))))))))
(DTypeSig false "rhsIsProduct" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "rhsIsProduct" ((PVar "rhs")) (EMatch (EApp (EApp (EApp (EVar "splitOnFirstEq") (EApp (EVar "stringToChars") (EVar "rhs"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "rhs")))) (ELit (LInt 0))) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" PWild) () (EVar "True"))))
(DTypeSig false "rhsIsSet" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "rhsIsSet" ((PVar "rhs")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "rhs"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "rhs")) (ELit (LString "{")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "rhs")) (ELit (LString "}")))))))
(DTypeSig false "splitOnFirstEq" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "splitOnFirstEq" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "="))) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "splitOnFirstEq") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "policyLabels" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "policyLabels" ((PList)) (EListLit))
(DFunDef false "policyLabels" ((PCons (PTuple (PVar "l") (PVar "p")) (PVar "rest"))) (EBinOp "::" (EBinOp "++" (EVar "l") (EApp (EVar "drender") (EVar "p"))) (EApp (EVar "policyLabels") (EVar "rest"))))
(DTypeSig false "lookupParam" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "Option") (TyCon "Param")))))
(DFunDef false "lookupParam" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupParam" ((PVar "k") (PCons (PTuple (PVar "l") (PVar "p")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "l")) (EApp (EVar "Some") (EVar "p")) (EApp (EApp (EVar "lookupParam") (EVar "k")) (EVar "rest"))))
(DTypeSig false "collectEVars" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectEVars" ((PCon "EVar" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EMethodRef" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "EDictApp" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "f")) (EApp (EVar "collectEVars") (EVar "x"))))
(DFunDef false "collectEVars" ((PCon "ELam" PWild (PVar "body"))) (EApp (EVar "collectEVars") (EVar "body")))
(DFunDef false "collectEVars" ((PCon "ELet" PWild PWild PWild (PVar "v") (PVar "body"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "v")) (EApp (EVar "collectEVars") (EVar "body"))))
(DFunDef false "collectEVars" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "concatMapCP") (EVar "collectBind")) (EVar "binds")) (EApp (EVar "collectEVars") (EVar "body"))))
(DFunDef false "collectEVars" ((PCon "EMatch" (PVar "e") (PVar "arms"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectArm")) (EVar "arms"))))
(DFunDef false "collectEVars" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectEVars") (EVar "c")) (EApp (EVar "collectEVars") (EVar "t"))) (EApp (EVar "collectEVars") (EVar "f"))))
(DFunDef false "collectEVars" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EUnOp" PWild (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "ERecordCreate" PWild (PVar "flds"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds")))
(DFunDef false "collectEVars" ((PCon "ERecordUpdate" (PVar "e") (PVar "flds") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds"))))
(DFunDef false "collectEVars" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "flds"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds"))))
(DFunDef false "collectEVars" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "ERangeList" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "ERangeArray" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "ESlice" (PVar "a") (PVar "b") (PVar "c") PWild PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))) (EApp (EVar "collectEVars") (EVar "c"))))
(DFunDef false "collectEVars" ((PCon "EIndex" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectStmt")) (EVar "stmts")))
(DFunDef false "collectEVars" ((PCon "EDo" (PVar "stmts"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectStmt")) (EVar "stmts")))
(DFunDef false "collectEVars" (PWild) (EListLit))
(DTypeSig false "collectBind" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectBind" ((PCon "LetBind" PWild (PVar "clauses"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectClause")) (EVar "clauses")))
(DTypeSig false "collectClause" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectClause" ((PCon "FunClause" PWild (PVar "body"))) (EApp (EVar "collectEVars") (EVar "body")))
(DTypeSig false "collectArm" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectArm" ((PCon "Arm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "concatMapCP") (EVar "collectGuard")) (EVar "guards")) (EApp (EVar "collectEVars") (EVar "body"))))
(DTypeSig false "collectGuard" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectGuard" ((PCon "GBind" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "collectFieldAssign" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectFieldAssign" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "collectStmt" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoLet" PWild PWild PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "concatMapCP" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "concatMapCP" (PWild (PList)) (EListLit))
(DFunDef false "concatMapCP" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "concatMapCP") (EVar "f")) (EVar "xs"))))
(DTypeSig false "topName" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "topName" ((PCon "DFunDef" PWild (PVar "n") PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "topName" ((PCon "DExtern" PWild (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "topName" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topName") (EVar "d")))
(DFunDef false "topName" (PWild) (EVar "None"))
(DTypeSig false "fnBody" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "fnBody" ((PCon "DFunDef" PWild (PVar "n") PWild (PVar "body"))) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EVar "collectEVars") (EVar "body")))))
(DFunDef false "fnBody" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "fnBody") (EVar "d")))
(DFunDef false "fnBody" (PWild) (EVar "None"))
(DTypeSig false "buildCallGraph" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "buildCallGraph" ((PVar "decls")) (EBlock (DoLet false false (PVar "tops") (EApp (EVar "collectOpts") (EApp (EApp (EVar "map") (EVar "topName")) (EVar "decls")))) (DoLet false false (PVar "bodies") (EApp (EVar "collectOpts") (EApp (EApp (EVar "map") (EVar "fnBody")) (EVar "decls")))) (DoExpr (EApp (EApp (EVar "map") (EApp (EVar "restrictBody") (EVar "tops"))) (EVar "bodies")))))
(DTypeSig false "restrictBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "restrictBody" ((PVar "tops") (PTuple (PVar "n") (PVar "refs"))) (ETuple (EVar "n") (EApp (EApp (EVar "intersectStr") (EVar "refs")) (EVar "tops"))))
(DTypeSig false "intersectStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "intersectStr" ((PVar "xs") (PVar "ys")) (EApp (EApp (EVar "filterMember") (EVar "xs")) (EVar "ys")))
(DTypeSig false "filterMember" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterMember" ((PList) PWild) (EListLit))
(DFunDef false "filterMember" ((PCons (PVar "x") (PVar "xs")) (PVar "ys")) (EIf (EApp (EApp (EVar "memberStr") (EVar "x")) (EVar "ys")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "filterMember") (EVar "xs")) (EVar "ys"))) (EApp (EApp (EVar "filterMember") (EVar "xs")) (EVar "ys"))))
(DTypeSig false "collectOpts" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "collectOpts" ((PList)) (EListLit))
(DFunDef false "collectOpts" ((PCons (PCon "None") (PVar "rest"))) (EApp (EVar "collectOpts") (EVar "rest")))
(DFunDef false "collectOpts" ((PCons (PCon "Some" (PVar "x")) (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "collectOpts") (EVar "rest"))))
(DTypeSig false "memberStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "memberStr" (PWild (PList)) (EVar "False"))
(DFunDef false "memberStr" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EApp (EApp (EVar "memberStr") (EVar "x")) (EVar "ys"))))
(DTypeSig false "lookupAssocL" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "lookupAssocL" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupAssocL" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupAssocL") (EVar "k")) (EVar "rest"))))
(DTypeSig false "monoEffects" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "monoEffects" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" PWild (PVar "row") (PVar "result")) () (EBlock (DoLet false false (PVar "atoms") (EApp (EVar "effrowLabels") (EVar "row"))) (DoExpr (EApp (EVar "sortUniqAtoms") (EBinOp "++" (EVar "atoms") (EApp (EVar "monoEffects") (EVar "result"))))))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EMatch (EApp (EVar "tupleSpine") (EApp (EApp (EVar "TApp") (EVar "a")) (EVar "b"))) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EApp (EVar "sortUniqAtoms") (EBinOp "++" (EApp (EVar "monoEffects") (EVar "a")) (EApp (EVar "monoEffects") (EVar "b"))))))) (arm PWild () (EListLit))))
(DTypeSig false "schemeEffects" (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "schemeEffects" ((PCon "Forall" PWild PWild (PVar "mono"))) (EApp (EVar "monoEffects") (EVar "mono")))
(DTypeSig false "sortUniqAtoms" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "sortUniqAtoms" ((PVar "atoms")) (EApp (EVar "dedupAtoms") (EApp (EVar "sortAtoms") (EVar "atoms"))))
(DTypeSig false "sortAtoms" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "sortAtoms" ((PList)) (EListLit))
(DFunDef false "sortAtoms" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "insertAtom") (EVar "x")) (EApp (EVar "sortAtoms") (EVar "xs"))))
(DTypeSig false "insertAtom" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "insertAtom" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "insertAtom" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EApp (EApp (EVar "stringLeq") (EApp (EVar "atomLabel") (EVar "x"))) (EApp (EVar "atomLabel") (EVar "y"))) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EBinOp "::" (EVar "y") (EApp (EApp (EVar "insertAtom") (EVar "x")) (EVar "ys")))))
(DTypeSig false "stringLeq" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "stringLeq" ((PVar "a") (PVar "b")) (EMatch (EApp (EApp (EVar "stringCompare") (EVar "a")) (EVar "b")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True"))))
(DTypeSig false "dedupAtoms" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "dedupAtoms" ((PList)) (EListLit))
(DFunDef false "dedupAtoms" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "dedupAtoms" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest")))) (EIf (EBinOp "==" (EApp (EVar "atomLabel") (EVar "x")) (EApp (EVar "atomLabel") (EVar "y"))) (EApp (EVar "dedupAtoms") (EBinOp "::" (EVar "x") (EVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "dedupAtoms") (EBinOp "::" (EVar "y") (EVar "rest"))))))
(DTypeSig false "atomLabels" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "atomLabels" ((PList)) (EListLit))
(DFunDef false "atomLabels" ((PCons (PVar "a") (PVar "rest"))) (EBinOp "::" (EBinOp "++" (EApp (EVar "atomLabel") (EVar "a")) (EApp (EVar "drender") (EApp (EVar "atomParam") (EVar "a")))) (EApp (EVar "atomLabels") (EVar "rest"))))
(DTypeSig false "fnEffectsTable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "fnEffectsTable" ((PList)) (EListLit))
(DFunDef false "fnEffectsTable" ((PCons (PTuple (PVar "name") (PVar "sch")) (PVar "rest"))) (EMatch (EApp (EVar "schemeEffects") (EVar "sch")) (arm (PList) () (EApp (EVar "fnEffectsTable") (EVar "rest"))) (arm (PVar "effs") () (EBinOp "::" (ETuple (EVar "name") (EVar "effs")) (EApp (EVar "fnEffectsTable") (EVar "rest"))))))
(DTypeSig false "fnHasEffect" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "fnHasEffect" ((PVar "table") (PVar "name") (PVar "label")) (EMatch (EApp (EApp (EVar "lookupAssocL") (EVar "name")) (EVar "table")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "effs")) () (EApp (EApp (EVar "memberStr") (EVar "label")) (EApp (EApp (EVar "map") (EVar "atomLabel")) (EVar "effs"))))))
(DTypeSig false "findChain" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "findChain" ((PVar "callGraph") (PVar "effTable") (PVar "start") (PVar "forbiddenLabel")) (EApp (EApp (EApp (EApp (EApp (EVar "traceChain") (EVar "callGraph")) (EVar "effTable")) (EVar "forbiddenLabel")) (EVar "start")) (EListLit (EVar "start"))))
(DTypeSig false "traceChain" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "traceChain" ((PVar "callGraph") (PVar "effTable") (PVar "forbiddenLabel") (PVar "fn") (PVar "visited")) (EBlock (DoLet false false (PVar "callees") (EMatch (EApp (EApp (EVar "lookupAssocL") (EVar "fn")) (EVar "callGraph")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "s")) () (EVar "s")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "firstWithEffect") (EVar "effTable")) (EVar "forbiddenLabel")) (EApp (EVar "sortUniqS") (EVar "callees"))) (arm (PCon "None") () (EListLit (EVar "fn"))) (arm (PCon "Some" (PVar "c")) () (EIf (EApp (EApp (EVar "memberStr") (EVar "c")) (EVar "visited")) (EListLit (EVar "fn") (EVar "c")) (EBinOp "::" (EVar "fn") (EApp (EApp (EApp (EApp (EApp (EVar "traceChain") (EVar "callGraph")) (EVar "effTable")) (EVar "forbiddenLabel")) (EVar "c")) (EBinOp "::" (EVar "c") (EVar "visited"))))))))))
(DTypeSig false "firstWithEffect" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "firstWithEffect" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstWithEffect" ((PVar "effTable") (PVar "label") (PCons (PVar "c") (PVar "rest"))) (EIf (EApp (EApp (EApp (EVar "fnHasEffect") (EVar "effTable")) (EVar "c")) (EVar "label")) (EApp (EVar "Some") (EVar "c")) (EApp (EApp (EApp (EVar "firstWithEffect") (EVar "effTable")) (EVar "label")) (EVar "rest"))))
(DTypeSig false "forbiddenLabels" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "forbiddenLabels" ((PVar "effs") (PVar "policy")) (EApp (EApp (EVar "filterForbidden") (EVar "effs")) (EVar "policy")))
(DTypeSig false "filterForbidden" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterForbidden" ((PList) PWild) (EListLit))
(DFunDef false "filterForbidden" ((PCons (PVar "a") (PVar "rest")) (PVar "policy")) (EIf (EApp (EApp (EVar "atomPermitted") (EVar "a")) (EVar "policy")) (EApp (EApp (EVar "filterForbidden") (EVar "rest")) (EVar "policy")) (EBinOp "::" (EApp (EVar "atomLabel") (EVar "a")) (EApp (EApp (EVar "filterForbidden") (EVar "rest")) (EVar "policy")))))
(DTypeSig false "atomPermitted" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "Bool"))))
(DFunDef false "atomPermitted" ((PVar "a") (PVar "policy")) (EMatch (EApp (EApp (EVar "lookupParam") (EApp (EVar "atomLabel") (EVar "a"))) (EVar "policy")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "pp")) () (EApp (EApp (EVar "dsub") (EApp (EVar "atomParam") (EVar "a"))) (EVar "pp")))))
(DTypeSig false "stubSource" (TyCon "String"))
(DFunDef false "stubSource" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "cacheGet req = \"\"\n")) (ELit (LString "cacheSet req result = ()\n")) (ELit (LString "logEvent s = putStr (stringConcat [\"   [LOG] \", s, \"\\n\"])\n")) (ELit (LString "getEnv k = None\n")) (ELit (LString "args u = []\n")) (ELit (LString "executablePath u = \"\"\n")) (ELit (LString "readFile p = Err \"\"\n")) (ELit (LString "readFileBytes p = Err \"\"\n")) (ELit (LString "fileExists p = False\n")) (ELit (LString "canonicalizePath p = p\n")) (ELit (LString "listDir p = Err \"\"\n")) (ELit (LString "statFile p = Err \"\"\n")) (ELit (LString "writeFile p c = Err \"\"\n")) (ELit (LString "writeFileBytes p b = Err \"\"\n")) (ELit (LString "appendFile p c = Err \"\"\n")) (ELit (LString "makeDir p = Err \"\"\n")) (ELit (LString "removeFile p = Err \"\"\n")) (ELit (LString "rename o n = Err \"\"\n")) (ELit (LString "removeDir p = Err \"\"\n")) (ELit (LString "runCommand cmd a = Err \"\"\n")) (ELit (LString "netResolve h = Err \"\"\n")) (ELit (LString "netTcpConnect h p = Err \"\"\n")) (ELit (LString "netTcpListen h p = Err \"\"\n")) (ELit (LString "netListenPort fd = Err \"\"\n")) (ELit (LString "netTcpAccept fd = Err \"\"\n")) (ELit (LString "netSend fd b = Err \"\"\n")) (ELit (LString "netRecv fd n = Err \"\"\n")) (ELit (LString "netShutdown fd how = Err \"\"\n")) (ELit (LString "netClose fd = Err \"\"\n")) (ELit (LString "netSetTimeout fd ms = Err \"\"\n")))))
(DTypeSig false "runPlugin" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("Mut") None (TyCon "String")))))))
(DFunDef false "runPlugin" ((PVar "fnName") (PVar "rtD") (PVar "coreD") (PVar "userD")) (EBlock (DoLet false false (PVar "stubD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "stubSource")))) (DoLet false false (PVar "prelude") (EBinOp "++" (EVar "coreD") (EVar "stubD"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "outputRef")) (ELit (LString "")))) (DoLet false false (PVar "rootEnv") (EApp (EApp (EVar "evalModulesRootEnv") (EVar "prelude")) (EListLit (ETuple (ELit (LString "__plugin__")) (EVar "userD"))))) (DoExpr (EMatch (EApp (EApp (EVar "lookupValue") (EVar "fnName")) (EVar "rootEnv")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "   (no '")) (EVar "fnName")) (ELit (LString "' binding in output)\n")))) (arm (PCon "Some" (PVar "fnVal")) () (EBlock (DoLet false false (PVar "sample") (ELit (LString "X-Forwarded-For: 192.168.1.1"))) (DoLet false false (PVar "result") (EApp (EApp (EVar "apply") (EVar "fnVal")) (EApp (EVar "VString") (EVar "sample")))) (DoLet false false (PVar "logged") (EFieldAccess (EVar "outputRef") "value")) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "logged"))) (ELit (LString "   transform "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "sample")))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EVar "ppValue") (EVar "result")))) (ELit (LString "\n"))))))))))
(DTypeSig false "lookupValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "lookupValue" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupValue" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupValue") (EVar "k")) (EVar "rest"))))
(DData Public "PolicyOutcome" () ((variant "PolicyAccept" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))) (variant "PolicyReject" (ConPos (TyCon "String")))) ())
(DTypeSig true "runCheckPolicy" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "PolicyOutcome"))))))))
(DFunDef false "runCheckPolicy" ((PVar "rtSrc") (PVar "coreSrc") (PVar "src") (PVar "allowStr") (PVar "fnName")) (EBlock (DoLet false false (PVar "policy") (EApp (EVar "parsePolicy") (EVar "allowStr"))) (DoLet false false (PVar "rawUser") (EApp (EVar "parse") (EVar "src"))) (DoLet false false (PVar "userD") (EApp (EVar "desugar") (EVar "rawUser"))) (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rtSrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "coreSrc")))) (DoLet false false (PVar "callGraph") (EApp (EVar "buildCallGraph") (EVar "userD"))) (DoLet false false (PVar "schemes") (EApp (EApp (EVar "checkProgramSchemesWithRuntime") (EVar "rtD")) (EBinOp "++" (EVar "coreD") (EVar "userD")))) (DoLet false false (PVar "effTable") (EApp (EVar "fnEffectsTable") (EVar "schemes"))) (DoLet false false (PVar "fnEffects") (EMatch (EApp (EApp (EVar "lookupAssocL") (EVar "fnName")) (EVar "effTable")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "e")) () (EVar "e")))) (DoLet false false (PVar "forbidden") (EApp (EApp (EVar "forbiddenLabels") (EVar "fnEffects")) (EVar "policy"))) (DoExpr (EMatch (EVar "forbidden") (arm (PList) () (EBlock (DoLet false false (PVar "effStr") (EIf (EApp (EVar "listIsEmpty") (EVar "fnEffects")) (ELit (LString "pure")) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "atomLabels") (EVar "fnEffects")))) (ELit (LString ">"))))) (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "accepted. ")) (EApp (EVar "display") (EVar "fnName"))) (ELit (LString " requires only "))) (EApp (EVar "display") (EVar "effStr"))) (ELit (LString "\n")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "PolicyAccept") (EVar "header")) (EVar "fnName")) (EVar "coreD")) (EVar "rtD")) (EVar "userD"))))) (arm PWild () (EBlock (DoLet false false (PVar "chain") (EApp (EApp (EApp (EApp (EVar "findChain") (EVar "callGraph")) (EVar "effTable")) (EVar "fnName")) (EApp (EVar "firstOf") (EVar "forbidden")))) (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "rejected. ")) (EApp (EVar "display") (EVar "fnName"))) (ELit (LString " requires <"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "atomLabels") (EVar "fnEffects"))))) (ELit (LString ">. Not permitted by policy {"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "policyLabels") (EVar "policy"))))) (ELit (LString "}\n")))) (DoLet false false (PVar "via") (EBinOp "++" (EBinOp "++" (ELit (LString "   reached via: ")) (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EVar "chain"))) (ELit (LString "\n")))) (DoExpr (EApp (EVar "PolicyReject") (EBinOp "++" (EVar "header") (EVar "via"))))))))))
(DTypeSig true "runAcceptedPlugin" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("Mut") None (TyCon "String")))))))
(DFunDef false "runAcceptedPlugin" ((PVar "fnName") (PVar "coreD") (PVar "rtD") (PVar "userD")) (EApp (EApp (EApp (EApp (EVar "runPlugin") (EVar "fnName")) (EVar "rtD")) (EVar "coreD")) (EVar "userD")))
(DTypeSig false "firstOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "firstOf" ((PList)) (ELit (LString "")))
(DFunDef false "firstOf" ((PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "listIsEmpty" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "listIsEmpty" ((PList)) (EVar "True"))
(DFunDef false "listIsEmpty" (PWild) (EVar "False"))
(DTypeSig false "isSecurity" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isSecurity" ((PVar "l")) (EApp (EVar "not") (EBinOp "||" (EBinOp "==" (EVar "l") (ELit (LString "Mut"))) (EBinOp "==" (EVar "l") (ELit (LString "Panic"))))))
(DTypeSig false "atomToToml" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "atomToToml" ((PVar "a")) (EBlock (DoLet false false (PVar "label") (EApp (EVar "atomLabel") (EVar "a"))) (DoExpr (EMatch (EApp (EVar "atomParam") (EVar "a")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString " = \""))) (EApp (EVar "display") (EVar "s"))) (ELit (LString "\"")))) (arm (PCon "PSet" (PCon "Some" (PVar "xs"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString " = ["))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "quoteTok")) (EVar "xs"))))) (ELit (LString "]")))) (arm (PCon "PProduct" (PVar "ax")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString " = { "))) (EApp (EVar "display") (EApp (EVar "productTomlInline") (EVar "ax")))) (ELit (LString " }")))) (arm PWild () (EBinOp "++" (EVar "label") (ELit (LString " = true"))))))))
(DTypeSig false "productTomlInline" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "productTomlInline" ((PVar "ax")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "axisToToml")) (EVar "ax"))))
(DTypeSig false "axisToToml" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyCon "String")))
(DFunDef false "axisToToml" ((PTuple (PVar "name") (PCon "PPrefix" (PCon "Some" (PVar "s"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "lowerFirst") (EVar "name")))) (ELit (LString " = \""))) (EApp (EVar "display") (EVar "s"))) (ELit (LString "\""))))
(DFunDef false "axisToToml" ((PTuple (PVar "name") (PCon "PSet" (PCon "Some" (PVar "xs"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "lowerFirst") (EVar "name")))) (ELit (LString " = ["))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "quoteTok")) (EVar "xs"))))) (ELit (LString "]"))))
(DFunDef false "axisToToml" ((PTuple (PVar "name") PWild)) (EBinOp "++" (EApp (EVar "lowerFirst") (EVar "name")) (ELit (LString " = true"))))
(DTypeSig false "quoteTok" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoteTok" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\""))))
(DTypeSig false "lowerFirst" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "lowerFirst" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "s") (EBinOp "++" (EApp (EVar "lowerChar") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EVar "n")) (EVar "s")))))))
(DTypeSig false "lowerChar" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "lowerChar" ((PLit (LString "H"))) (ELit (LString "h")))
(DFunDef false "lowerChar" ((PLit (LString "M"))) (ELit (LString "m")))
(DFunDef false "lowerChar" ((PLit (LString "S"))) (ELit (LString "s")))
(DFunDef false "lowerChar" ((PLit (LString "P"))) (ELit (LString "p")))
(DFunDef false "lowerChar" ((PVar "c")) (EVar "c"))
(DTypeSig true "manifestToml" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "manifestToml" ((PVar "atoms")) (EBlock (DoLet false false (PVar "secAtoms") (EApp (EVar "filterSecurity") (EVar "atoms"))) (DoExpr (EMatch (EVar "secAtoms") (arm (PList) () (ELit (LString "[package.capabilities]\n"))) (arm PWild () (EBlock (DoLet false false (PVar "lines") (EApp (EApp (EVar "map") (EVar "atomToToml")) (EVar "secAtoms"))) (DoExpr (EBinOp "++" (ELit (LString "[package.capabilities]\n")) (EApp (EVar "joinTomlLines") (EVar "lines"))))))))))
(DTypeSig false "joinTomlLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinTomlLines" ((PList)) (ELit (LString "")))
(DFunDef false "joinTomlLines" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "joinTomlLines") (EVar "xs")))) (ELit (LString ""))))
(DTypeSig false "filterSecurity" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "filterSecurity" ((PList)) (EListLit))
(DFunDef false "filterSecurity" ((PCons (PVar "a") (PVar "rest"))) (EIf (EApp (EVar "isSecurity") (EApp (EVar "atomLabel") (EVar "a"))) (EBinOp "::" (EVar "a") (EApp (EVar "filterSecurity") (EVar "rest"))) (EApp (EVar "filterSecurity") (EVar "rest"))))
(DData Public "ManifestArgs" () ((variant "ManifestArgs" (ConPos (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))) ())
(DTypeSig true "parseManifestArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "ManifestArgs")))
(DFunDef false "parseManifestArgs" ((PVar "argv")) (EApp (EApp (EApp (EVar "parseManifestGo") (EVar "argv")) (EVar "None")) (ELit (LString "main"))))
(DTypeSig false "parseManifestGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "ManifestArgs")))))
(DFunDef false "parseManifestGo" ((PList) (PVar "file") (PVar "fn")) (EApp (EApp (EVar "ManifestArgs") (EVar "file")) (EVar "fn")))
(DFunDef false "parseManifestGo" ((PCons (PLit (LString "--fn")) (PCons (PVar "v") (PVar "rest"))) (PVar "file") PWild) (EApp (EApp (EApp (EVar "parseManifestGo") (EVar "rest")) (EVar "file")) (EVar "v")))
(DFunDef false "parseManifestGo" ((PCons (PVar "f") (PVar "rest")) (PCon "None") (PVar "fn")) (EApp (EApp (EApp (EVar "parseManifestGo") (EVar "rest")) (EApp (EVar "Some") (EVar "f"))) (EVar "fn")))
(DFunDef false "parseManifestGo" ((PCons (PVar "f") (PVar "rest")) (PAs "file" (PCon "Some" PWild)) (PVar "fn")) (EApp (EApp (EApp (EVar "parseManifestGo") (EVar "rest")) (EVar "file")) (EVar "fn")))
(DTypeSig true "runManifest" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "String")))))))
(DFunDef false "runManifest" ((PVar "rtSrc") (PVar "coreSrc") (PVar "src") (PVar "fnName")) (EBlock (DoLet false false (PVar "rawUser") (EApp (EVar "parse") (EVar "src"))) (DoLet false false (PVar "userD") (EApp (EVar "desugar") (EVar "rawUser"))) (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rtSrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "coreSrc")))) (DoLet false false (PVar "schemes") (EApp (EApp (EVar "checkProgramSchemesWithRuntime") (EVar "rtD")) (EBinOp "++" (EVar "coreD") (EVar "userD")))) (DoLet false false (PVar "effTable") (EApp (EVar "fnEffectsTable") (EVar "schemes"))) (DoLet false false (PVar "fnEffects") (EMatch (EApp (EApp (EVar "lookupAssocL") (EVar "fnName")) (EVar "effTable")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "e")) () (EVar "e")))) (DoExpr (EApp (EVar "manifestToml") (EVar "fnEffects")))))
(DTypeSig true "manifestToAllowStr" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "manifestToAllowStr" ((PVar "atoms")) (EBlock (DoLet false false (PVar "secAtoms") (EApp (EVar "filterSecurity") (EVar "atoms"))) (DoLet false false (PVar "toks") (EApp (EApp (EVar "map") (EVar "atomToAllowTok")) (EVar "secAtoms"))) (DoExpr (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "toks")))))
(DTypeSig false "atomToAllowTok" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "atomToAllowTok" ((PVar "a")) (EBlock (DoLet false false (PVar "label") (EApp (EVar "atomLabel") (EVar "a"))) (DoExpr (EMatch (EApp (EVar "atomParam") (EVar "a")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "="))) (EApp (EVar "display") (EVar "s"))) (ELit (LString "")))) (arm (PCon "PSet" (PCon "Some" (PVar "xs"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "={"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "xs")))) (ELit (LString "}")))) (arm (PCon "PProduct" (PVar "ax")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "="))) (EApp (EVar "display") (EApp (EVar "productAllowRhs") (EVar "ax")))) (ELit (LString "")))) (arm PWild () (EVar "label"))))))
(DTypeSig false "productAllowRhs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "productAllowRhs" ((PVar "ax")) (EApp (EVar "joinSemiTok") (EApp (EApp (EVar "map") (EVar "axisToAllow")) (EVar "ax"))))
(DTypeSig false "axisToAllow" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyCon "String")))
(DFunDef false "axisToAllow" ((PTuple (PVar "name") (PCon "PPrefix" (PCon "Some" (PVar "s"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "=\""))) (EApp (EVar "display") (EVar "s"))) (ELit (LString "\""))))
(DFunDef false "axisToAllow" ((PTuple (PVar "name") (PCon "PSet" (PCon "Some" (PVar "xs"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "={"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "xs")))) (ELit (LString "}"))))
(DFunDef false "axisToAllow" ((PTuple (PVar "name") PWild)) (EBinOp "++" (EVar "name") (ELit (LString "=true"))))
(DTypeSig false "joinSemiTok" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSemiTok" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString ";"))) (EVar "xs")))
(DTypeSig true "runManifestAtoms" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("Mut") None (TyApp (TyCon "List") (TyCon "Atom"))))))))
(DFunDef false "runManifestAtoms" ((PVar "rtSrc") (PVar "coreSrc") (PVar "src") (PVar "fnName")) (EBlock (DoLet false false (PVar "rawUser") (EApp (EVar "parse") (EVar "src"))) (DoLet false false (PVar "userD") (EApp (EVar "desugar") (EVar "rawUser"))) (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rtSrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "coreSrc")))) (DoLet false false (PVar "schemes") (EApp (EApp (EVar "checkProgramSchemesWithRuntime") (EVar "rtD")) (EBinOp "++" (EVar "coreD") (EVar "userD")))) (DoLet false false (PVar "effTable") (EApp (EVar "fnEffectsTable") (EVar "schemes"))) (DoLet false false (PVar "fnEffects") (EMatch (EApp (EApp (EVar "lookupAssocL") (EVar "fnName")) (EVar "effTable")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "e")) () (EVar "e")))) (DoExpr (EApp (EVar "filterSecurity") (EVar "fnEffects")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Pat" true) (mem "Lit" true) (mem "Arm" true) (mem "Guard" true) (mem "DoStmt" true) (mem "LetBind" true) (mem "FunClause" true) (mem "FieldAssign" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "Scheme" true) (mem "Mono" true) (mem "EffRow" true) (mem "Atom" true) (mem "Param" true) (mem "checkProgramSchemesWithRuntime" false) (mem "normalize" false) (mem "tupleSpine" false) (mem "effrowLabels" false) (mem "atomLabel" false) (mem "atomParam" false) (mem "dsub" false) (mem "drender" false) (mem "decodeProductParam" false) (mem "decodeSetParam" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "evalModulesRootEnv" false) (mem "apply" false) (mem "outputRef" false) (mem "ppValue" false))))
(DUse false (UseGroup ("support" "util") ((mem "sortUniqS" false) (mem "joinWith" false) (mem "reverseL" false) (mem "escStr" false))))
(DData Public "PolicyArgs" () ((variant "PolicyArgs" (ConPos (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String") (TyCon "String")))) ())
(DTypeSig true "parsePolicyArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "PolicyArgs")))
(DFunDef false "parsePolicyArgs" ((PVar "argv")) (EApp (EApp (EApp (EApp (EVar "parsePolicyGo") (EVar "argv")) (EVar "None")) (ELit (LString "Cache,Log"))) (ELit (LString "transform"))))
(DTypeSig false "parsePolicyGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "PolicyArgs"))))))
(DFunDef false "parsePolicyGo" ((PList) (PVar "file") (PVar "allow") (PVar "fn")) (EApp (EApp (EApp (EVar "PolicyArgs") (EVar "file")) (EVar "allow")) (EVar "fn")))
(DFunDef false "parsePolicyGo" ((PCons (PLit (LString "--allow")) (PCons (PVar "v") (PVar "rest"))) (PVar "file") PWild (PVar "fn")) (EApp (EApp (EApp (EApp (EVar "parsePolicyGo") (EVar "rest")) (EVar "file")) (EVar "v")) (EVar "fn")))
(DFunDef false "parsePolicyGo" ((PCons (PLit (LString "--fn")) (PCons (PVar "v") (PVar "rest"))) (PVar "file") (PVar "allow") PWild) (EApp (EApp (EApp (EApp (EVar "parsePolicyGo") (EVar "rest")) (EVar "file")) (EVar "allow")) (EVar "v")))
(DFunDef false "parsePolicyGo" ((PCons (PVar "f") (PVar "rest")) (PCon "None") (PVar "allow") (PVar "fn")) (EApp (EApp (EApp (EApp (EVar "parsePolicyGo") (EVar "rest")) (EApp (EVar "Some") (EVar "f"))) (EVar "allow")) (EVar "fn")))
(DFunDef false "parsePolicyGo" ((PCons (PVar "f") (PVar "rest")) (PAs "file" (PCon "Some" PWild)) (PVar "allow") (PVar "fn")) (EApp (EApp (EApp (EApp (EVar "parsePolicyGo") (EVar "rest")) (EVar "file")) (EVar "allow")) (EVar "fn")))
(DTypeSig false "splitComma" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitComma" ((PVar "s")) (EApp (EVar "filterNonEmpty") (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EApp (EVar "stringToChars") (EVar "s"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "s")))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig false "splitCommaGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitCommaGo" ((PVar "cs") (PVar "n") (PVar "start") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EVar "start")) (EVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "{"))) (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "}"))) (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar ","))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EBinOp "::" (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EVar "start")) (EVar "i")) (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "sliceStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "sliceStr" ((PVar "cs") (PVar "a") (PVar "b")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "sliceGo") (EVar "cs")) (EVar "a")) (EVar "b")))))
(DTypeSig false "sliceGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "sliceGo" ((PVar "cs") (PVar "a") (PVar "b")) (EIf (EBinOp ">=" (EVar "a") (EVar "b")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "a")) (EVar "cs")) (EApp (EApp (EApp (EVar "sliceGo") (EVar "cs")) (EBinOp "+" (EVar "a") (ELit (LInt 1)))) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "filterNonEmpty" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "filterNonEmpty" ((PList)) (EListLit))
(DFunDef false "filterNonEmpty" ((PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "==" (EVar "x") (ELit (LString ""))) (EApp (EVar "filterNonEmpty") (EVar "xs")) (EBinOp "::" (EVar "x") (EApp (EVar "filterNonEmpty") (EVar "xs")))))
(DTypeSig false "parsePolicy" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))
(DFunDef false "parsePolicy" ((PVar "s")) (EApp (EApp (EMethodRef "map") (EVar "parsePolicyTok")) (EApp (EVar "splitComma") (EVar "s"))))
(DTypeSig false "parsePolicyTok" (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "Param"))))
(DFunDef false "parsePolicyTok" ((PVar "tok")) (EMatch (EApp (EApp (EApp (EVar "splitOnFirstEq") (EApp (EVar "stringToChars") (EVar "tok"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "tok")))) (ELit (LInt 0))) (arm (PCon "None") () (ETuple (EVar "tok") (EApp (EVar "PPrefix") (EVar "None")))) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "tok"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoLet false false (PVar "label") (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (ELit (LInt 0))) (EVar "i"))) (DoLet false false (PVar "rhs") (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (DoExpr (EIf (EApp (EVar "rhsIsProduct") (EVar "rhs")) (ETuple (EVar "label") (EApp (EVar "decodeProductParam") (EBinOp "++" (EBinOp "++" (ELit (LString "@P{")) (EVar "rhs")) (ELit (LString "}"))))) (EIf (EApp (EVar "rhsIsSet") (EVar "rhs")) (ETuple (EVar "label") (EApp (EVar "PSet") (EApp (EVar "Some") (EApp (EVar "decodeSetParam") (EVar "rhs"))))) (ETuple (EVar "label") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "rhs")))))))))))
(DTypeSig false "rhsIsProduct" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "rhsIsProduct" ((PVar "rhs")) (EMatch (EApp (EApp (EApp (EVar "splitOnFirstEq") (EApp (EVar "stringToChars") (EVar "rhs"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "rhs")))) (ELit (LInt 0))) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" PWild) () (EVar "True"))))
(DTypeSig false "rhsIsSet" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "rhsIsSet" ((PVar "rhs")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "rhs"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "rhs")) (ELit (LString "{")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "rhs")) (ELit (LString "}")))))))
(DTypeSig false "splitOnFirstEq" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "splitOnFirstEq" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "="))) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "splitOnFirstEq") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "policyLabels" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "policyLabels" ((PList)) (EListLit))
(DFunDef false "policyLabels" ((PCons (PTuple (PVar "l") (PVar "p")) (PVar "rest"))) (EBinOp "::" (EBinOp "++" (EVar "l") (EApp (EVar "drender") (EVar "p"))) (EApp (EVar "policyLabels") (EVar "rest"))))
(DTypeSig false "lookupParam" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "Option") (TyCon "Param")))))
(DFunDef false "lookupParam" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupParam" ((PVar "k") (PCons (PTuple (PVar "l") (PVar "p")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "l")) (EApp (EVar "Some") (EVar "p")) (EApp (EApp (EVar "lookupParam") (EVar "k")) (EVar "rest"))))
(DTypeSig false "collectEVars" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectEVars" ((PCon "EVar" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EMethodRef" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "EDictApp" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "f")) (EApp (EVar "collectEVars") (EVar "x"))))
(DFunDef false "collectEVars" ((PCon "ELam" PWild (PVar "body"))) (EApp (EVar "collectEVars") (EVar "body")))
(DFunDef false "collectEVars" ((PCon "ELet" PWild PWild PWild (PVar "v") (PVar "body"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "v")) (EApp (EVar "collectEVars") (EVar "body"))))
(DFunDef false "collectEVars" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "concatMapCP") (EVar "collectBind")) (EVar "binds")) (EApp (EVar "collectEVars") (EVar "body"))))
(DFunDef false "collectEVars" ((PCon "EMatch" (PVar "e") (PVar "arms"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectArm")) (EVar "arms"))))
(DFunDef false "collectEVars" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectEVars") (EVar "c")) (EApp (EVar "collectEVars") (EVar "t"))) (EApp (EVar "collectEVars") (EVar "f"))))
(DFunDef false "collectEVars" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EUnOp" PWild (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "ERecordCreate" PWild (PVar "flds"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds")))
(DFunDef false "collectEVars" ((PCon "ERecordUpdate" (PVar "e") (PVar "flds") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds"))))
(DFunDef false "collectEVars" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "flds"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds"))))
(DFunDef false "collectEVars" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "ERangeList" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "ERangeArray" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "ESlice" (PVar "a") (PVar "b") (PVar "c") PWild PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))) (EApp (EVar "collectEVars") (EVar "c"))))
(DFunDef false "collectEVars" ((PCon "EIndex" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectStmt")) (EVar "stmts")))
(DFunDef false "collectEVars" ((PCon "EDo" (PVar "stmts"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectStmt")) (EVar "stmts")))
(DFunDef false "collectEVars" (PWild) (EListLit))
(DTypeSig false "collectBind" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectBind" ((PCon "LetBind" PWild (PVar "clauses"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectClause")) (EVar "clauses")))
(DTypeSig false "collectClause" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectClause" ((PCon "FunClause" PWild (PVar "body"))) (EApp (EVar "collectEVars") (EVar "body")))
(DTypeSig false "collectArm" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectArm" ((PCon "Arm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "concatMapCP") (EVar "collectGuard")) (EVar "guards")) (EApp (EVar "collectEVars") (EVar "body"))))
(DTypeSig false "collectGuard" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectGuard" ((PCon "GBind" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "collectFieldAssign" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectFieldAssign" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "collectStmt" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoLet" PWild PWild PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "concatMapCP" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "concatMapCP" (PWild (PList)) (EListLit))
(DFunDef false "concatMapCP" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "concatMapCP") (EVar "f")) (EVar "xs"))))
(DTypeSig false "topName" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "topName" ((PCon "DFunDef" PWild (PVar "n") PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "topName" ((PCon "DExtern" PWild (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "topName" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topName") (EVar "d")))
(DFunDef false "topName" (PWild) (EVar "None"))
(DTypeSig false "fnBody" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "fnBody" ((PCon "DFunDef" PWild (PVar "n") PWild (PVar "body"))) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EVar "collectEVars") (EVar "body")))))
(DFunDef false "fnBody" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "fnBody") (EVar "d")))
(DFunDef false "fnBody" (PWild) (EVar "None"))
(DTypeSig false "buildCallGraph" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "buildCallGraph" ((PVar "decls")) (EBlock (DoLet false false (PVar "tops") (EApp (EVar "collectOpts") (EApp (EApp (EMethodRef "map") (EVar "topName")) (EVar "decls")))) (DoLet false false (PVar "bodies") (EApp (EVar "collectOpts") (EApp (EApp (EMethodRef "map") (EVar "fnBody")) (EVar "decls")))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EVar "restrictBody") (EVar "tops"))) (EVar "bodies")))))
(DTypeSig false "restrictBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "restrictBody" ((PVar "tops") (PTuple (PVar "n") (PVar "refs"))) (ETuple (EVar "n") (EApp (EApp (EVar "intersectStr") (EVar "refs")) (EVar "tops"))))
(DTypeSig false "intersectStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "intersectStr" ((PVar "xs") (PVar "ys")) (EApp (EApp (EVar "filterMember") (EVar "xs")) (EVar "ys")))
(DTypeSig false "filterMember" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterMember" ((PList) PWild) (EListLit))
(DFunDef false "filterMember" ((PCons (PVar "x") (PVar "xs")) (PVar "ys")) (EIf (EApp (EApp (EVar "memberStr") (EVar "x")) (EVar "ys")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "filterMember") (EVar "xs")) (EVar "ys"))) (EApp (EApp (EVar "filterMember") (EVar "xs")) (EVar "ys"))))
(DTypeSig false "collectOpts" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "collectOpts" ((PList)) (EListLit))
(DFunDef false "collectOpts" ((PCons (PCon "None") (PVar "rest"))) (EApp (EVar "collectOpts") (EVar "rest")))
(DFunDef false "collectOpts" ((PCons (PCon "Some" (PVar "x")) (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "collectOpts") (EVar "rest"))))
(DTypeSig false "memberStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "memberStr" (PWild (PList)) (EVar "False"))
(DFunDef false "memberStr" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EApp (EApp (EVar "memberStr") (EVar "x")) (EVar "ys"))))
(DTypeSig false "lookupAssocL" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "lookupAssocL" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupAssocL" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupAssocL") (EVar "k")) (EVar "rest"))))
(DTypeSig false "monoEffects" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "monoEffects" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" PWild (PVar "row") (PVar "result")) () (EBlock (DoLet false false (PVar "atoms") (EApp (EVar "effrowLabels") (EVar "row"))) (DoExpr (EApp (EVar "sortUniqAtoms") (EBinOp "++" (EVar "atoms") (EApp (EVar "monoEffects") (EVar "result"))))))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EMatch (EApp (EVar "tupleSpine") (EApp (EApp (EVar "TApp") (EVar "a")) (EVar "b"))) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EApp (EVar "sortUniqAtoms") (EBinOp "++" (EApp (EVar "monoEffects") (EVar "a")) (EApp (EVar "monoEffects") (EVar "b"))))))) (arm PWild () (EListLit))))
(DTypeSig false "schemeEffects" (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "schemeEffects" ((PCon "Forall" PWild PWild (PVar "mono"))) (EApp (EVar "monoEffects") (EVar "mono")))
(DTypeSig false "sortUniqAtoms" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "sortUniqAtoms" ((PVar "atoms")) (EApp (EVar "dedupAtoms") (EApp (EVar "sortAtoms") (EVar "atoms"))))
(DTypeSig false "sortAtoms" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "sortAtoms" ((PList)) (EListLit))
(DFunDef false "sortAtoms" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "insertAtom") (EVar "x")) (EApp (EVar "sortAtoms") (EVar "xs"))))
(DTypeSig false "insertAtom" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "insertAtom" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "insertAtom" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EApp (EApp (EVar "stringLeq") (EApp (EVar "atomLabel") (EVar "x"))) (EApp (EVar "atomLabel") (EVar "y"))) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EBinOp "::" (EVar "y") (EApp (EApp (EVar "insertAtom") (EVar "x")) (EVar "ys")))))
(DTypeSig false "stringLeq" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "stringLeq" ((PVar "a") (PVar "b")) (EMatch (EApp (EApp (EVar "stringCompare") (EVar "a")) (EVar "b")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True"))))
(DTypeSig false "dedupAtoms" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "dedupAtoms" ((PList)) (EListLit))
(DFunDef false "dedupAtoms" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "dedupAtoms" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest")))) (EIf (EBinOp "==" (EApp (EVar "atomLabel") (EVar "x")) (EApp (EVar "atomLabel") (EVar "y"))) (EApp (EVar "dedupAtoms") (EBinOp "::" (EVar "x") (EVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "dedupAtoms") (EBinOp "::" (EVar "y") (EVar "rest"))))))
(DTypeSig false "atomLabels" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "atomLabels" ((PList)) (EListLit))
(DFunDef false "atomLabels" ((PCons (PVar "a") (PVar "rest"))) (EBinOp "::" (EBinOp "++" (EApp (EVar "atomLabel") (EVar "a")) (EApp (EVar "drender") (EApp (EVar "atomParam") (EVar "a")))) (EApp (EVar "atomLabels") (EVar "rest"))))
(DTypeSig false "fnEffectsTable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "fnEffectsTable" ((PList)) (EListLit))
(DFunDef false "fnEffectsTable" ((PCons (PTuple (PVar "name") (PVar "sch")) (PVar "rest"))) (EMatch (EApp (EVar "schemeEffects") (EVar "sch")) (arm (PList) () (EApp (EVar "fnEffectsTable") (EVar "rest"))) (arm (PVar "effs") () (EBinOp "::" (ETuple (EVar "name") (EVar "effs")) (EApp (EVar "fnEffectsTable") (EVar "rest"))))))
(DTypeSig false "fnHasEffect" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "fnHasEffect" ((PVar "table") (PVar "name") (PVar "label")) (EMatch (EApp (EApp (EVar "lookupAssocL") (EVar "name")) (EVar "table")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "effs")) () (EApp (EApp (EVar "memberStr") (EVar "label")) (EApp (EApp (EMethodRef "map") (EVar "atomLabel")) (EVar "effs"))))))
(DTypeSig false "findChain" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "findChain" ((PVar "callGraph") (PVar "effTable") (PVar "start") (PVar "forbiddenLabel")) (EApp (EApp (EApp (EApp (EApp (EVar "traceChain") (EVar "callGraph")) (EVar "effTable")) (EVar "forbiddenLabel")) (EVar "start")) (EListLit (EVar "start"))))
(DTypeSig false "traceChain" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "traceChain" ((PVar "callGraph") (PVar "effTable") (PVar "forbiddenLabel") (PVar "fn") (PVar "visited")) (EBlock (DoLet false false (PVar "callees") (EMatch (EApp (EApp (EVar "lookupAssocL") (EVar "fn")) (EVar "callGraph")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "s")) () (EVar "s")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "firstWithEffect") (EVar "effTable")) (EVar "forbiddenLabel")) (EApp (EVar "sortUniqS") (EVar "callees"))) (arm (PCon "None") () (EListLit (EVar "fn"))) (arm (PCon "Some" (PVar "c")) () (EIf (EApp (EApp (EVar "memberStr") (EVar "c")) (EVar "visited")) (EListLit (EVar "fn") (EVar "c")) (EBinOp "::" (EVar "fn") (EApp (EApp (EApp (EApp (EApp (EVar "traceChain") (EVar "callGraph")) (EVar "effTable")) (EVar "forbiddenLabel")) (EVar "c")) (EBinOp "::" (EVar "c") (EVar "visited"))))))))))
(DTypeSig false "firstWithEffect" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "firstWithEffect" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstWithEffect" ((PVar "effTable") (PVar "label") (PCons (PVar "c") (PVar "rest"))) (EIf (EApp (EApp (EApp (EVar "fnHasEffect") (EVar "effTable")) (EVar "c")) (EVar "label")) (EApp (EVar "Some") (EVar "c")) (EApp (EApp (EApp (EVar "firstWithEffect") (EVar "effTable")) (EVar "label")) (EVar "rest"))))
(DTypeSig false "forbiddenLabels" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "forbiddenLabels" ((PVar "effs") (PVar "policy")) (EApp (EApp (EVar "filterForbidden") (EVar "effs")) (EVar "policy")))
(DTypeSig false "filterForbidden" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterForbidden" ((PList) PWild) (EListLit))
(DFunDef false "filterForbidden" ((PCons (PVar "a") (PVar "rest")) (PVar "policy")) (EIf (EApp (EApp (EVar "atomPermitted") (EVar "a")) (EVar "policy")) (EApp (EApp (EVar "filterForbidden") (EVar "rest")) (EVar "policy")) (EBinOp "::" (EApp (EVar "atomLabel") (EVar "a")) (EApp (EApp (EVar "filterForbidden") (EVar "rest")) (EVar "policy")))))
(DTypeSig false "atomPermitted" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "Bool"))))
(DFunDef false "atomPermitted" ((PVar "a") (PVar "policy")) (EMatch (EApp (EApp (EVar "lookupParam") (EApp (EVar "atomLabel") (EVar "a"))) (EVar "policy")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "pp")) () (EApp (EApp (EVar "dsub") (EApp (EVar "atomParam") (EVar "a"))) (EVar "pp")))))
(DTypeSig false "stubSource" (TyCon "String"))
(DFunDef false "stubSource" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "cacheGet req = \"\"\n")) (ELit (LString "cacheSet req result = ()\n")) (ELit (LString "logEvent s = putStr (stringConcat [\"   [LOG] \", s, \"\\n\"])\n")) (ELit (LString "getEnv k = None\n")) (ELit (LString "args u = []\n")) (ELit (LString "executablePath u = \"\"\n")) (ELit (LString "readFile p = Err \"\"\n")) (ELit (LString "readFileBytes p = Err \"\"\n")) (ELit (LString "fileExists p = False\n")) (ELit (LString "canonicalizePath p = p\n")) (ELit (LString "listDir p = Err \"\"\n")) (ELit (LString "statFile p = Err \"\"\n")) (ELit (LString "writeFile p c = Err \"\"\n")) (ELit (LString "writeFileBytes p b = Err \"\"\n")) (ELit (LString "appendFile p c = Err \"\"\n")) (ELit (LString "makeDir p = Err \"\"\n")) (ELit (LString "removeFile p = Err \"\"\n")) (ELit (LString "rename o n = Err \"\"\n")) (ELit (LString "removeDir p = Err \"\"\n")) (ELit (LString "runCommand cmd a = Err \"\"\n")) (ELit (LString "netResolve h = Err \"\"\n")) (ELit (LString "netTcpConnect h p = Err \"\"\n")) (ELit (LString "netTcpListen h p = Err \"\"\n")) (ELit (LString "netListenPort fd = Err \"\"\n")) (ELit (LString "netTcpAccept fd = Err \"\"\n")) (ELit (LString "netSend fd b = Err \"\"\n")) (ELit (LString "netRecv fd n = Err \"\"\n")) (ELit (LString "netShutdown fd how = Err \"\"\n")) (ELit (LString "netClose fd = Err \"\"\n")) (ELit (LString "netSetTimeout fd ms = Err \"\"\n")))))
(DTypeSig false "runPlugin" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("Mut") None (TyCon "String")))))))
(DFunDef false "runPlugin" ((PVar "fnName") (PVar "rtD") (PVar "coreD") (PVar "userD")) (EBlock (DoLet false false (PVar "stubD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "stubSource")))) (DoLet false false (PVar "prelude") (EBinOp "++" (EVar "coreD") (EVar "stubD"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "outputRef")) (ELit (LString "")))) (DoLet false false (PVar "rootEnv") (EApp (EApp (EVar "evalModulesRootEnv") (EVar "prelude")) (EListLit (ETuple (ELit (LString "__plugin__")) (EVar "userD"))))) (DoExpr (EMatch (EApp (EApp (EVar "lookupValue") (EVar "fnName")) (EVar "rootEnv")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "   (no '")) (EVar "fnName")) (ELit (LString "' binding in output)\n")))) (arm (PCon "Some" (PVar "fnVal")) () (EBlock (DoLet false false (PVar "sample") (ELit (LString "X-Forwarded-For: 192.168.1.1"))) (DoLet false false (PVar "result") (EApp (EApp (EVar "apply") (EVar "fnVal")) (EApp (EVar "VString") (EVar "sample")))) (DoLet false false (PVar "logged") (EFieldAccess (EVar "outputRef") "value")) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "logged"))) (ELit (LString "   transform "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "sample")))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EVar "ppValue") (EVar "result")))) (ELit (LString "\n"))))))))))
(DTypeSig false "lookupValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "lookupValue" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupValue" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupValue") (EVar "k")) (EVar "rest"))))
(DData Public "PolicyOutcome" () ((variant "PolicyAccept" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))) (variant "PolicyReject" (ConPos (TyCon "String")))) ())
(DTypeSig true "runCheckPolicy" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "PolicyOutcome"))))))))
(DFunDef false "runCheckPolicy" ((PVar "rtSrc") (PVar "coreSrc") (PVar "src") (PVar "allowStr") (PVar "fnName")) (EBlock (DoLet false false (PVar "policy") (EApp (EVar "parsePolicy") (EVar "allowStr"))) (DoLet false false (PVar "rawUser") (EApp (EVar "parse") (EVar "src"))) (DoLet false false (PVar "userD") (EApp (EVar "desugar") (EVar "rawUser"))) (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rtSrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "coreSrc")))) (DoLet false false (PVar "callGraph") (EApp (EVar "buildCallGraph") (EVar "userD"))) (DoLet false false (PVar "schemes") (EApp (EApp (EVar "checkProgramSchemesWithRuntime") (EVar "rtD")) (EBinOp "++" (EVar "coreD") (EVar "userD")))) (DoLet false false (PVar "effTable") (EApp (EVar "fnEffectsTable") (EVar "schemes"))) (DoLet false false (PVar "fnEffects") (EMatch (EApp (EApp (EVar "lookupAssocL") (EVar "fnName")) (EVar "effTable")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "e")) () (EVar "e")))) (DoLet false false (PVar "forbidden") (EApp (EApp (EVar "forbiddenLabels") (EVar "fnEffects")) (EVar "policy"))) (DoExpr (EMatch (EVar "forbidden") (arm (PList) () (EBlock (DoLet false false (PVar "effStr") (EIf (EApp (EVar "listIsEmpty") (EVar "fnEffects")) (ELit (LString "pure")) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "atomLabels") (EVar "fnEffects")))) (ELit (LString ">"))))) (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "accepted. ")) (EApp (EMethodRef "display") (EVar "fnName"))) (ELit (LString " requires only "))) (EApp (EMethodRef "display") (EVar "effStr"))) (ELit (LString "\n")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "PolicyAccept") (EVar "header")) (EVar "fnName")) (EVar "coreD")) (EVar "rtD")) (EVar "userD"))))) (arm PWild () (EBlock (DoLet false false (PVar "chain") (EApp (EApp (EApp (EApp (EVar "findChain") (EVar "callGraph")) (EVar "effTable")) (EVar "fnName")) (EApp (EVar "firstOf") (EVar "forbidden")))) (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "rejected. ")) (EApp (EMethodRef "display") (EVar "fnName"))) (ELit (LString " requires <"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "atomLabels") (EVar "fnEffects"))))) (ELit (LString ">. Not permitted by policy {"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "policyLabels") (EVar "policy"))))) (ELit (LString "}\n")))) (DoLet false false (PVar "via") (EBinOp "++" (EBinOp "++" (ELit (LString "   reached via: ")) (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EVar "chain"))) (ELit (LString "\n")))) (DoExpr (EApp (EVar "PolicyReject") (EBinOp "++" (EVar "header") (EVar "via"))))))))))
(DTypeSig true "runAcceptedPlugin" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("Mut") None (TyCon "String")))))))
(DFunDef false "runAcceptedPlugin" ((PVar "fnName") (PVar "coreD") (PVar "rtD") (PVar "userD")) (EApp (EApp (EApp (EApp (EVar "runPlugin") (EVar "fnName")) (EVar "rtD")) (EVar "coreD")) (EVar "userD")))
(DTypeSig false "firstOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "firstOf" ((PList)) (ELit (LString "")))
(DFunDef false "firstOf" ((PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "listIsEmpty" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "listIsEmpty" ((PList)) (EVar "True"))
(DFunDef false "listIsEmpty" (PWild) (EVar "False"))
(DTypeSig false "isSecurity" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isSecurity" ((PVar "l")) (EApp (EVar "not") (EBinOp "||" (EBinOp "==" (EVar "l") (ELit (LString "Mut"))) (EBinOp "==" (EVar "l") (ELit (LString "Panic"))))))
(DTypeSig false "atomToToml" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "atomToToml" ((PVar "a")) (EBlock (DoLet false false (PVar "label") (EApp (EVar "atomLabel") (EVar "a"))) (DoExpr (EMatch (EApp (EVar "atomParam") (EVar "a")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " = \""))) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString "\"")))) (arm (PCon "PSet" (PCon "Some" (PVar "xs"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " = ["))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "quoteTok")) (EVar "xs"))))) (ELit (LString "]")))) (arm (PCon "PProduct" (PVar "ax")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " = { "))) (EApp (EMethodRef "display") (EApp (EVar "productTomlInline") (EVar "ax")))) (ELit (LString " }")))) (arm PWild () (EBinOp "++" (EVar "label") (ELit (LString " = true"))))))))
(DTypeSig false "productTomlInline" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "productTomlInline" ((PVar "ax")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "axisToToml")) (EVar "ax"))))
(DTypeSig false "axisToToml" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyCon "String")))
(DFunDef false "axisToToml" ((PTuple (PVar "name") (PCon "PPrefix" (PCon "Some" (PVar "s"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "lowerFirst") (EVar "name")))) (ELit (LString " = \""))) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString "\""))))
(DFunDef false "axisToToml" ((PTuple (PVar "name") (PCon "PSet" (PCon "Some" (PVar "xs"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "lowerFirst") (EVar "name")))) (ELit (LString " = ["))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "quoteTok")) (EVar "xs"))))) (ELit (LString "]"))))
(DFunDef false "axisToToml" ((PTuple (PVar "name") PWild)) (EBinOp "++" (EApp (EVar "lowerFirst") (EVar "name")) (ELit (LString " = true"))))
(DTypeSig false "quoteTok" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoteTok" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\""))))
(DTypeSig false "lowerFirst" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "lowerFirst" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "s") (EBinOp "++" (EApp (EVar "lowerChar") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EVar "n")) (EVar "s")))))))
(DTypeSig false "lowerChar" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "lowerChar" ((PLit (LString "H"))) (ELit (LString "h")))
(DFunDef false "lowerChar" ((PLit (LString "M"))) (ELit (LString "m")))
(DFunDef false "lowerChar" ((PLit (LString "S"))) (ELit (LString "s")))
(DFunDef false "lowerChar" ((PLit (LString "P"))) (ELit (LString "p")))
(DFunDef false "lowerChar" ((PVar "c")) (EVar "c"))
(DTypeSig true "manifestToml" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "manifestToml" ((PVar "atoms")) (EBlock (DoLet false false (PVar "secAtoms") (EApp (EVar "filterSecurity") (EVar "atoms"))) (DoExpr (EMatch (EVar "secAtoms") (arm (PList) () (ELit (LString "[package.capabilities]\n"))) (arm PWild () (EBlock (DoLet false false (PVar "lines") (EApp (EApp (EMethodRef "map") (EVar "atomToToml")) (EVar "secAtoms"))) (DoExpr (EBinOp "++" (ELit (LString "[package.capabilities]\n")) (EApp (EVar "joinTomlLines") (EVar "lines"))))))))))
(DTypeSig false "joinTomlLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinTomlLines" ((PList)) (ELit (LString "")))
(DFunDef false "joinTomlLines" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "joinTomlLines") (EVar "xs")))) (ELit (LString ""))))
(DTypeSig false "filterSecurity" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "filterSecurity" ((PList)) (EListLit))
(DFunDef false "filterSecurity" ((PCons (PVar "a") (PVar "rest"))) (EIf (EApp (EVar "isSecurity") (EApp (EVar "atomLabel") (EVar "a"))) (EBinOp "::" (EVar "a") (EApp (EVar "filterSecurity") (EVar "rest"))) (EApp (EVar "filterSecurity") (EVar "rest"))))
(DData Public "ManifestArgs" () ((variant "ManifestArgs" (ConPos (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))) ())
(DTypeSig true "parseManifestArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "ManifestArgs")))
(DFunDef false "parseManifestArgs" ((PVar "argv")) (EApp (EApp (EApp (EVar "parseManifestGo") (EVar "argv")) (EVar "None")) (ELit (LString "main"))))
(DTypeSig false "parseManifestGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "ManifestArgs")))))
(DFunDef false "parseManifestGo" ((PList) (PVar "file") (PVar "fn")) (EApp (EApp (EVar "ManifestArgs") (EVar "file")) (EVar "fn")))
(DFunDef false "parseManifestGo" ((PCons (PLit (LString "--fn")) (PCons (PVar "v") (PVar "rest"))) (PVar "file") PWild) (EApp (EApp (EApp (EVar "parseManifestGo") (EVar "rest")) (EVar "file")) (EVar "v")))
(DFunDef false "parseManifestGo" ((PCons (PVar "f") (PVar "rest")) (PCon "None") (PVar "fn")) (EApp (EApp (EApp (EVar "parseManifestGo") (EVar "rest")) (EApp (EVar "Some") (EVar "f"))) (EVar "fn")))
(DFunDef false "parseManifestGo" ((PCons (PVar "f") (PVar "rest")) (PAs "file" (PCon "Some" PWild)) (PVar "fn")) (EApp (EApp (EApp (EVar "parseManifestGo") (EVar "rest")) (EVar "file")) (EVar "fn")))
(DTypeSig true "runManifest" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "String")))))))
(DFunDef false "runManifest" ((PVar "rtSrc") (PVar "coreSrc") (PVar "src") (PVar "fnName")) (EBlock (DoLet false false (PVar "rawUser") (EApp (EVar "parse") (EVar "src"))) (DoLet false false (PVar "userD") (EApp (EVar "desugar") (EVar "rawUser"))) (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rtSrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "coreSrc")))) (DoLet false false (PVar "schemes") (EApp (EApp (EVar "checkProgramSchemesWithRuntime") (EVar "rtD")) (EBinOp "++" (EVar "coreD") (EVar "userD")))) (DoLet false false (PVar "effTable") (EApp (EVar "fnEffectsTable") (EVar "schemes"))) (DoLet false false (PVar "fnEffects") (EMatch (EApp (EApp (EVar "lookupAssocL") (EVar "fnName")) (EVar "effTable")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "e")) () (EVar "e")))) (DoExpr (EApp (EVar "manifestToml") (EVar "fnEffects")))))
(DTypeSig true "manifestToAllowStr" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "manifestToAllowStr" ((PVar "atoms")) (EBlock (DoLet false false (PVar "secAtoms") (EApp (EVar "filterSecurity") (EVar "atoms"))) (DoLet false false (PVar "toks") (EApp (EApp (EMethodRef "map") (EVar "atomToAllowTok")) (EVar "secAtoms"))) (DoExpr (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "toks")))))
(DTypeSig false "atomToAllowTok" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "atomToAllowTok" ((PVar "a")) (EBlock (DoLet false false (PVar "label") (EApp (EVar "atomLabel") (EVar "a"))) (DoExpr (EMatch (EApp (EVar "atomParam") (EVar "a")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "="))) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString "")))) (arm (PCon "PSet" (PCon "Some" (PVar "xs"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "={"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "xs")))) (ELit (LString "}")))) (arm (PCon "PProduct" (PVar "ax")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "="))) (EApp (EMethodRef "display") (EApp (EVar "productAllowRhs") (EVar "ax")))) (ELit (LString "")))) (arm PWild () (EVar "label"))))))
(DTypeSig false "productAllowRhs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "productAllowRhs" ((PVar "ax")) (EApp (EVar "joinSemiTok") (EApp (EApp (EMethodRef "map") (EVar "axisToAllow")) (EVar "ax"))))
(DTypeSig false "axisToAllow" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyCon "String")))
(DFunDef false "axisToAllow" ((PTuple (PVar "name") (PCon "PPrefix" (PCon "Some" (PVar "s"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "=\""))) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString "\""))))
(DFunDef false "axisToAllow" ((PTuple (PVar "name") (PCon "PSet" (PCon "Some" (PVar "xs"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "={"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "xs")))) (ELit (LString "}"))))
(DFunDef false "axisToAllow" ((PTuple (PVar "name") PWild)) (EBinOp "++" (EVar "name") (ELit (LString "=true"))))
(DTypeSig false "joinSemiTok" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSemiTok" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString ";"))) (EVar "xs")))
(DTypeSig true "runManifestAtoms" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("Mut") None (TyApp (TyCon "List") (TyCon "Atom"))))))))
(DFunDef false "runManifestAtoms" ((PVar "rtSrc") (PVar "coreSrc") (PVar "src") (PVar "fnName")) (EBlock (DoLet false false (PVar "rawUser") (EApp (EVar "parse") (EVar "src"))) (DoLet false false (PVar "userD") (EApp (EVar "desugar") (EVar "rawUser"))) (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rtSrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "coreSrc")))) (DoLet false false (PVar "schemes") (EApp (EApp (EVar "checkProgramSchemesWithRuntime") (EVar "rtD")) (EBinOp "++" (EVar "coreD") (EVar "userD")))) (DoLet false false (PVar "effTable") (EApp (EVar "fnEffectsTable") (EVar "schemes"))) (DoLet false false (PVar "fnEffects") (EMatch (EApp (EApp (EVar "lookupAssocL") (EVar "fnName")) (EVar "effTable")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "e")) () (EVar "e")))) (DoExpr (EApp (EVar "filterSecurity") (EVar "fnEffects")))))
