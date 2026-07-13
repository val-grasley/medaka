# META
source_lines=28
stages=PARSE,DESUGAR,MARK
# SOURCE
data Bool = True | False

data Option a = Some a | None

data Shape = Circle Int | Rect Int Int deriving (Display)

public export data Tree a = Leaf | Node (Tree a) a (Tree a)

export data Color = Red | Green | Blue

data Shape2
  = Sphere Int
  | Box Int Int Int

data Shape3
  = Disc Int
  | Tri Int Int
  deriving (Eq, Debug)

data Shape4
  = Dot Int
  | Seg Int Int deriving (Eq, Debug)

data Point = { x : Int, y : Int }

data Tagged = { label : Int } deriving (Eq, Debug)

data Event = Click { x : Int, y : Int } | Scroll Int
# PARSE
(DData Private "Bool" () ((variant "True" (ConPos)) (variant "False" (ConPos))) ())
(DData Private "Option" ("a") ((variant "Some" (ConPos (TyVar "a"))) (variant "None" (ConPos))) ())
(DData Private "Shape" () ((variant "Circle" (ConPos (TyCon "Int"))) (variant "Rect" (ConPos (TyCon "Int") (TyCon "Int")))) ("Display"))
(DData Public "Tree" ("a") ((variant "Leaf" (ConPos)) (variant "Node" (ConPos (TyApp (TyCon "Tree") (TyVar "a")) (TyVar "a") (TyApp (TyCon "Tree") (TyVar "a"))))) ())
(DData Abstract "Color" () ((variant "Red" (ConPos)) (variant "Green" (ConPos)) (variant "Blue" (ConPos))) ())
(DData Private "Shape2" () ((variant "Sphere" (ConPos (TyCon "Int"))) (variant "Box" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DData Private "Shape3" () ((variant "Disc" (ConPos (TyCon "Int"))) (variant "Tri" (ConPos (TyCon "Int") (TyCon "Int")))) ("Eq" "Debug"))
(DData Private "Shape4" () ((variant "Dot" (ConPos (TyCon "Int"))) (variant "Seg" (ConPos (TyCon "Int") (TyCon "Int")))) ("Eq" "Debug"))
(DData Private "Point" () ((variant "Point" (ConNamed (field "x" (TyCon "Int")) (field "y" (TyCon "Int"))))) ())
(DData Private "Tagged" () ((variant "Tagged" (ConNamed (field "label" (TyCon "Int"))))) ("Eq" "Debug"))
(DData Private "Event" () ((variant "Click" (ConNamed (field "x" (TyCon "Int")) (field "y" (TyCon "Int")))) (variant "Scroll" (ConPos (TyCon "Int")))) ())
# DESUGAR
(DData Private "Bool" () ((variant "True" (ConPos)) (variant "False" (ConPos))) ())
(DData Private "Option" ("a") ((variant "Some" (ConPos (TyVar "a"))) (variant "None" (ConPos))) ())
(DData Private "Shape" () ((variant "Circle" (ConPos (TyCon "Int"))) (variant "Rect" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DImpl true "Display" ((TyCon "Shape")) () ((im "display" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Circle" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Circle ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a0"))))) (arm (PCon "Rect" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Rect ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a1")))))))))
(DData Public "Tree" ("a") ((variant "Leaf" (ConPos)) (variant "Node" (ConPos (TyApp (TyCon "Tree") (TyVar "a")) (TyVar "a") (TyApp (TyCon "Tree") (TyVar "a"))))) ())
(DData Abstract "Color" () ((variant "Red" (ConPos)) (variant "Green" (ConPos)) (variant "Blue" (ConPos))) ())
(DData Private "Shape2" () ((variant "Sphere" (ConPos (TyCon "Int"))) (variant "Box" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DData Private "Shape3" () ((variant "Disc" (ConPos (TyCon "Int"))) (variant "Tri" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "Shape3")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Disc" (PVar "__a0")) (PCon "Disc" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "Tri" (PVar "__a0") (PVar "__a1")) (PCon "Tri" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Shape3")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Disc" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Disc ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "Tri" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Tri ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))))))))
(DData Private "Shape4" () ((variant "Dot" (ConPos (TyCon "Int"))) (variant "Seg" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "Shape4")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Dot" (PVar "__a0")) (PCon "Dot" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "Seg" (PVar "__a0") (PVar "__a1")) (PCon "Seg" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Shape4")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Dot" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Dot ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "Seg" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Seg ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))))))))
(DData Private "Point" () ((variant "Point" (ConNamed (field "x" (TyCon "Int")) (field "y" (TyCon "Int"))))) ())
(DData Private "Tagged" () ((variant "Tagged" (ConNamed (field "label" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "Tagged")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Tagged" ((rf "label" (PVar "__a0"))) false) (PRec "Tagged" ((rf "label" (PVar "__b0"))) false)) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Debug" ((TyCon "Tagged")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Tagged" ((rf "label" (PVar "__a0"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Tagged {")) (ELit (LString " label = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString " }"))))))))
(DData Private "Event" () ((variant "Click" (ConNamed (field "x" (TyCon "Int")) (field "y" (TyCon "Int")))) (variant "Scroll" (ConPos (TyCon "Int")))) ())
# MARK
(DData Private "Bool" () ((variant "True" (ConPos)) (variant "False" (ConPos))) ())
(DData Private "Option" ("a") ((variant "Some" (ConPos (TyVar "a"))) (variant "None" (ConPos))) ())
(DData Private "Shape" () ((variant "Circle" (ConPos (TyCon "Int"))) (variant "Rect" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DImpl true "Display" ((TyCon "Shape")) () ((im "display" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Circle" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Circle ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0"))))) (arm (PCon "Rect" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Rect ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a1")))))))))
(DData Public "Tree" ("a") ((variant "Leaf" (ConPos)) (variant "Node" (ConPos (TyApp (TyCon "Tree") (TyVar "a")) (TyVar "a") (TyApp (TyCon "Tree") (TyVar "a"))))) ())
(DData Abstract "Color" () ((variant "Red" (ConPos)) (variant "Green" (ConPos)) (variant "Blue" (ConPos))) ())
(DData Private "Shape2" () ((variant "Sphere" (ConPos (TyCon "Int"))) (variant "Box" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DData Private "Shape3" () ((variant "Disc" (ConPos (TyCon "Int"))) (variant "Tri" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "Shape3")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Disc" (PVar "__a0")) (PCon "Disc" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "Tri" (PVar "__a0") (PVar "__a1")) (PCon "Tri" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Shape3")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Disc" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Disc ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "Tri" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Tri ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))))))))
(DData Private "Shape4" () ((variant "Dot" (ConPos (TyCon "Int"))) (variant "Seg" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "Shape4")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Dot" (PVar "__a0")) (PCon "Dot" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "Seg" (PVar "__a0") (PVar "__a1")) (PCon "Seg" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Shape4")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Dot" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Dot ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "Seg" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Seg ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))))))))
(DData Private "Point" () ((variant "Point" (ConNamed (field "x" (TyCon "Int")) (field "y" (TyCon "Int"))))) ())
(DData Private "Tagged" () ((variant "Tagged" (ConNamed (field "label" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "Tagged")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Tagged" ((rf "label" (PVar "__a0"))) false) (PRec "Tagged" ((rf "label" (PVar "__b0"))) false)) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Debug" ((TyCon "Tagged")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Tagged" ((rf "label" (PVar "__a0"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Tagged {")) (ELit (LString " label = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString " }"))))))))
(DData Private "Event" () ((variant "Click" (ConNamed (field "x" (TyCon "Int")) (field "y" (TyCon "Int")))) (variant "Scroll" (ConPos (TyCon "Int")))) ())
