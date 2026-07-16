# META
source_lines=90
stages=DESUGAR,MARK
# SOURCE
-- Tarjan's strongly-connected-components algorithm, extracted from
-- types/typecheck.mdk (PR1 of #158).  Self-contained: it references only
-- String/Int/Bool/List and the OrdMap wrappers, plus the `reverseL`/`minI`
-- helpers from support.util.  The sole consumer is `processTopGroups` in
-- typecheck.mdk, which uses it to order top-level letrec groups.
--
-- The six `tj*` module-level Refs are private scratch state; `tarjanSCCs`
-- resets all of them at entry, so it is re-entrant across calls (processing
-- is sequential per module, matching the surrounding compiler idiom).  Every
-- initial value is a nullary constant (`Ref 0`, `Ref []`, `Ref omEmpty`), so
-- the move carries no polymorphic-empty generalization hazard.

import support.ordmap.{OrdMap, omEmpty, omInsert, omLookup}
import support.util.{reverseL, minI}

tjCounter : Ref Int
tjCounter = Ref 0
tjStack : Ref (List String)
tjStack = Ref []
tjIndex : Ref (OrdMap Int)
tjIndex = Ref omEmpty
tjLow : Ref (OrdMap Int)
tjLow = Ref omEmpty
tjOn : Ref (OrdMap Bool)
tjOn = Ref omEmpty
tjOut : Ref (List (List String))
tjOut = Ref []

tjLowOf : String -> Int
tjLowOf x = fromOption 0 (omLookup x tjLow.value)
tjOnStack : String -> Bool
tjOnStack x = fromOption False (omLookup x tjOn.value)

export tarjanSCCs : List String -> OrdMap (List String) -> List (List String)
tarjanSCCs names adj =
  let _ = setRef tjCounter 0
  let _ = setRef tjStack []
  let _ = setRef tjIndex omEmpty
  let _ = setRef tjLow omEmpty
  let _ = setRef tjOn omEmpty
  let _ = setRef tjOut []
  let _ = tarjanAll names adj
  reverseL tjOut.value

tarjanAll : List String -> OrdMap (List String) -> Unit
tarjanAll [] _ = ()
tarjanAll (v::rest) adj =
  let _ = tjVisit v adj
  tarjanAll rest adj

tjVisit : String -> OrdMap (List String) -> Unit
tjVisit v adj = match omLookup v tjIndex.value
  Some _ => ()
  None => strongconnect v adj

strongconnect : String -> OrdMap (List String) -> Unit
strongconnect v adj =
  let idx = tjCounter.value
  let _ = setRef tjIndex (omInsert v idx tjIndex.value)
  let _ = setRef tjLow (omInsert v idx tjLow.value)
  let _ = setRef tjCounter (idx + 1)
  let _ = setRef tjStack (v::tjStack.value)
  let _ = setRef tjOn (omInsert v True tjOn.value)
  let _ = scEdges v (fromOption [] (omLookup v adj)) adj
  if tjLowOf v == idx then tjPop v [] else ()

scEdges : String -> List String -> OrdMap (List String) -> Unit
scEdges v [] adj = ()
scEdges v (w::ws) adj =
  let _ = scEdge v w adj
  scEdges v ws adj

scEdge : String -> String -> OrdMap (List String) -> Unit
scEdge v w adj = match omLookup w tjIndex.value
  None =>
    let _ = strongconnect w adj
    setRef tjLow (omInsert v (minI (tjLowOf v) (tjLowOf w)) tjLow.value)
  Some iw =>
    if tjOnStack w then
      setRef tjLow (omInsert v (minI (tjLowOf v) iw) tjLow.value)
    else
      ()

tjPop : String -> List String -> Unit
tjPop v acc = match tjStack.value
  [] => setRef tjOut (acc::tjOut.value)
  w::rest =>
    let _ = setRef tjStack rest
    let _ = setRef tjOn (omInsert w False tjOn.value)
    if w == v then setRef tjOut ((w::acc) :: tjOut.value) else tjPop v (w::acc)
# DESUGAR
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "minI" false))))
(DTypeSig false "tjCounter" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "tjCounter" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig false "tjStack" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tjStack" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "tjIndex" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Int"))))
(DFunDef false "tjIndex" () (EApp (EVar "Ref") (EVar "omEmpty")))
(DTypeSig false "tjLow" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Int"))))
(DFunDef false "tjLow" () (EApp (EVar "Ref") (EVar "omEmpty")))
(DTypeSig false "tjOn" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Bool"))))
(DFunDef false "tjOn" () (EApp (EVar "Ref") (EVar "omEmpty")))
(DTypeSig false "tjOut" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tjOut" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "tjLowOf" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "tjLowOf" ((PVar "x")) (EApp (EApp (EVar "fromOption") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "x")) (EFieldAccess (EVar "tjLow") "value"))))
(DTypeSig false "tjOnStack" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "tjOnStack" ((PVar "x")) (EApp (EApp (EVar "fromOption") (EVar "False")) (EApp (EApp (EVar "omLookup") (EVar "x")) (EFieldAccess (EVar "tjOn") "value"))))
(DTypeSig true "tarjanSCCs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tarjanSCCs" ((PVar "names") (PVar "adj")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjCounter")) (ELit (LInt 0)))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjStack")) (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjIndex")) (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjLow")) (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjOn")) (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjOut")) (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "tarjanAll") (EVar "names")) (EVar "adj"))) (DoExpr (EApp (EVar "reverseL") (EFieldAccess (EVar "tjOut") "value")))))
(DTypeSig false "tarjanAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "tarjanAll" ((PList) PWild) (ELit LUnit))
(DFunDef false "tarjanAll" ((PCons (PVar "v") (PVar "rest")) (PVar "adj")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "tjVisit") (EVar "v")) (EVar "adj"))) (DoExpr (EApp (EApp (EVar "tarjanAll") (EVar "rest")) (EVar "adj")))))
(DTypeSig false "tjVisit" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "tjVisit" ((PVar "v") (PVar "adj")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "v")) (EFieldAccess (EVar "tjIndex") "value")) (arm (PCon "Some" PWild) () (ELit LUnit)) (arm (PCon "None") () (EApp (EApp (EVar "strongconnect") (EVar "v")) (EVar "adj")))))
(DTypeSig false "strongconnect" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "strongconnect" ((PVar "v") (PVar "adj")) (EBlock (DoLet false false (PVar "idx") (EFieldAccess (EVar "tjCounter") "value")) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjIndex")) (EApp (EApp (EApp (EVar "omInsert") (EVar "v")) (EVar "idx")) (EFieldAccess (EVar "tjIndex") "value")))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjLow")) (EApp (EApp (EApp (EVar "omInsert") (EVar "v")) (EVar "idx")) (EFieldAccess (EVar "tjLow") "value")))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjCounter")) (EBinOp "+" (EVar "idx") (ELit (LInt 1))))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjStack")) (EBinOp "::" (EVar "v") (EFieldAccess (EVar "tjStack") "value")))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjOn")) (EApp (EApp (EApp (EVar "omInsert") (EVar "v")) (EVar "True")) (EFieldAccess (EVar "tjOn") "value")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "scEdges") (EVar "v")) (EApp (EApp (EVar "fromOption") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "v")) (EVar "adj")))) (EVar "adj"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "tjLowOf") (EVar "v")) (EVar "idx")) (EApp (EApp (EVar "tjPop") (EVar "v")) (EListLit)) (ELit LUnit)))))
(DTypeSig false "scEdges" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "scEdges" ((PVar "v") (PList) (PVar "adj")) (ELit LUnit))
(DFunDef false "scEdges" ((PVar "v") (PCons (PVar "w") (PVar "ws")) (PVar "adj")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "scEdge") (EVar "v")) (EVar "w")) (EVar "adj"))) (DoExpr (EApp (EApp (EApp (EVar "scEdges") (EVar "v")) (EVar "ws")) (EVar "adj")))))
(DTypeSig false "scEdge" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "scEdge" ((PVar "v") (PVar "w") (PVar "adj")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "w")) (EFieldAccess (EVar "tjIndex") "value")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EApp (EVar "strongconnect") (EVar "w")) (EVar "adj"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "tjLow")) (EApp (EApp (EApp (EVar "omInsert") (EVar "v")) (EApp (EApp (EVar "minI") (EApp (EVar "tjLowOf") (EVar "v"))) (EApp (EVar "tjLowOf") (EVar "w")))) (EFieldAccess (EVar "tjLow") "value")))))) (arm (PCon "Some" (PVar "iw")) () (EIf (EApp (EVar "tjOnStack") (EVar "w")) (EApp (EApp (EVar "setRef") (EVar "tjLow")) (EApp (EApp (EApp (EVar "omInsert") (EVar "v")) (EApp (EApp (EVar "minI") (EApp (EVar "tjLowOf") (EVar "v"))) (EVar "iw"))) (EFieldAccess (EVar "tjLow") "value"))) (ELit LUnit)))))
(DTypeSig false "tjPop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "tjPop" ((PVar "v") (PVar "acc")) (EMatch (EFieldAccess (EVar "tjStack") "value") (arm (PList) () (EApp (EApp (EVar "setRef") (EVar "tjOut")) (EBinOp "::" (EVar "acc") (EFieldAccess (EVar "tjOut") "value")))) (arm (PCons (PVar "w") (PVar "rest")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjStack")) (EVar "rest"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjOn")) (EApp (EApp (EApp (EVar "omInsert") (EVar "w")) (EVar "False")) (EFieldAccess (EVar "tjOn") "value")))) (DoExpr (EIf (EBinOp "==" (EVar "w") (EVar "v")) (EApp (EApp (EVar "setRef") (EVar "tjOut")) (EBinOp "::" (EBinOp "::" (EVar "w") (EVar "acc")) (EFieldAccess (EVar "tjOut") "value"))) (EApp (EApp (EVar "tjPop") (EVar "v")) (EBinOp "::" (EVar "w") (EVar "acc")))))))))
# MARK
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "minI" false))))
(DTypeSig false "tjCounter" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "tjCounter" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig false "tjStack" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tjStack" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "tjIndex" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Int"))))
(DFunDef false "tjIndex" () (EApp (EVar "Ref") (EVar "omEmpty")))
(DTypeSig false "tjLow" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Int"))))
(DFunDef false "tjLow" () (EApp (EVar "Ref") (EVar "omEmpty")))
(DTypeSig false "tjOn" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Bool"))))
(DFunDef false "tjOn" () (EApp (EVar "Ref") (EVar "omEmpty")))
(DTypeSig false "tjOut" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tjOut" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "tjLowOf" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "tjLowOf" ((PVar "x")) (EApp (EApp (EVar "fromOption") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "x")) (EFieldAccess (EVar "tjLow") "value"))))
(DTypeSig false "tjOnStack" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "tjOnStack" ((PVar "x")) (EApp (EApp (EVar "fromOption") (EVar "False")) (EApp (EApp (EVar "omLookup") (EVar "x")) (EFieldAccess (EVar "tjOn") "value"))))
(DTypeSig true "tarjanSCCs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tarjanSCCs" ((PVar "names") (PVar "adj")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjCounter")) (ELit (LInt 0)))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjStack")) (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjIndex")) (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjLow")) (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjOn")) (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjOut")) (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "tarjanAll") (EVar "names")) (EVar "adj"))) (DoExpr (EApp (EVar "reverseL") (EFieldAccess (EVar "tjOut") "value")))))
(DTypeSig false "tarjanAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "tarjanAll" ((PList) PWild) (ELit LUnit))
(DFunDef false "tarjanAll" ((PCons (PVar "v") (PVar "rest")) (PVar "adj")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "tjVisit") (EVar "v")) (EVar "adj"))) (DoExpr (EApp (EApp (EVar "tarjanAll") (EVar "rest")) (EVar "adj")))))
(DTypeSig false "tjVisit" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "tjVisit" ((PVar "v") (PVar "adj")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "v")) (EFieldAccess (EVar "tjIndex") "value")) (arm (PCon "Some" PWild) () (ELit LUnit)) (arm (PCon "None") () (EApp (EApp (EVar "strongconnect") (EVar "v")) (EVar "adj")))))
(DTypeSig false "strongconnect" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "strongconnect" ((PVar "v") (PVar "adj")) (EBlock (DoLet false false (PVar "idx") (EFieldAccess (EVar "tjCounter") "value")) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjIndex")) (EApp (EApp (EApp (EVar "omInsert") (EVar "v")) (EVar "idx")) (EFieldAccess (EVar "tjIndex") "value")))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjLow")) (EApp (EApp (EApp (EVar "omInsert") (EVar "v")) (EVar "idx")) (EFieldAccess (EVar "tjLow") "value")))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjCounter")) (EBinOp "+" (EVar "idx") (ELit (LInt 1))))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjStack")) (EBinOp "::" (EVar "v") (EFieldAccess (EVar "tjStack") "value")))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjOn")) (EApp (EApp (EApp (EVar "omInsert") (EVar "v")) (EVar "True")) (EFieldAccess (EVar "tjOn") "value")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "scEdges") (EVar "v")) (EApp (EApp (EVar "fromOption") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "v")) (EVar "adj")))) (EVar "adj"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "tjLowOf") (EVar "v")) (EVar "idx")) (EApp (EApp (EVar "tjPop") (EVar "v")) (EListLit)) (ELit LUnit)))))
(DTypeSig false "scEdges" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "scEdges" ((PVar "v") (PList) (PVar "adj")) (ELit LUnit))
(DFunDef false "scEdges" ((PVar "v") (PCons (PVar "w") (PVar "ws")) (PVar "adj")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "scEdge") (EVar "v")) (EVar "w")) (EVar "adj"))) (DoExpr (EApp (EApp (EApp (EVar "scEdges") (EVar "v")) (EVar "ws")) (EVar "adj")))))
(DTypeSig false "scEdge" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "scEdge" ((PVar "v") (PVar "w") (PVar "adj")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "w")) (EFieldAccess (EVar "tjIndex") "value")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EApp (EVar "strongconnect") (EVar "w")) (EVar "adj"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "tjLow")) (EApp (EApp (EApp (EVar "omInsert") (EVar "v")) (EApp (EApp (EVar "minI") (EApp (EVar "tjLowOf") (EVar "v"))) (EApp (EVar "tjLowOf") (EVar "w")))) (EFieldAccess (EVar "tjLow") "value")))))) (arm (PCon "Some" (PVar "iw")) () (EIf (EApp (EVar "tjOnStack") (EVar "w")) (EApp (EApp (EVar "setRef") (EVar "tjLow")) (EApp (EApp (EApp (EVar "omInsert") (EVar "v")) (EApp (EApp (EVar "minI") (EApp (EVar "tjLowOf") (EVar "v"))) (EVar "iw"))) (EFieldAccess (EVar "tjLow") "value"))) (ELit LUnit)))))
(DTypeSig false "tjPop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "tjPop" ((PVar "v") (PVar "acc")) (EMatch (EFieldAccess (EVar "tjStack") "value") (arm (PList) () (EApp (EApp (EVar "setRef") (EVar "tjOut")) (EBinOp "::" (EVar "acc") (EFieldAccess (EVar "tjOut") "value")))) (arm (PCons (PVar "w") (PVar "rest")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjStack")) (EVar "rest"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "tjOn")) (EApp (EApp (EApp (EVar "omInsert") (EVar "w")) (EVar "False")) (EFieldAccess (EVar "tjOn") "value")))) (DoExpr (EIf (EBinOp "==" (EVar "w") (EVar "v")) (EApp (EApp (EVar "setRef") (EVar "tjOut")) (EBinOp "::" (EBinOp "::" (EVar "w") (EVar "acc")) (EFieldAccess (EVar "tjOut") "value"))) (EApp (EApp (EVar "tjPop") (EVar "v")) (EBinOp "::" (EVar "w") (EVar "acc")))))))))
