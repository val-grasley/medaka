# META
source_lines=13
stages=CORE_IR
# SOURCE
-- interface with a default method, overridden by one impl
interface Greet a where
  hello : a -> String
  loud : a -> String
  loud x = hello x ++ "!"
data En = En
data Fr = Fr
impl Greet En where
  hello _ = "hi"
impl Greet Fr where
  hello _ = "salut"
  loud _ = "SALUT!!"
main = (hello En, loud En, hello Fr, loud Fr)
# CORE_IR
(CProgram ((CBind "main" (CClause () (CTuple (CApp (CVar "hello" AGlobal) (CVar "En" AGlobal)) (CApp (CVar "loud" AGlobal) (CVar "En" AGlobal)) (CApp (CVar "hello" AGlobal) (CVar "Fr" AGlobal)) (CApp (CVar "loud" AGlobal) (CVar "Fr" AGlobal)))))) ((ca "En" 0) (ca "Fr" 0)) ((ct "En" "En") (ct "Fr" "Fr")) ((CImplEntry "loud" 1 (CImplDefault ((PVar "x")) (CBinPrim "++" (CApp (CVar "hello" AGlobal) (CVar "x" (ALocal 0 0))) (CLit (LString "!"))))) (CImplEntry "hello" 0 (CImplTagged "En" "Greet|En|" "Greet" (0) (PWild) (CLit (LString "hi")))) (CImplEntry "loud" 0 (CImplTagged "En" "Greet|En|" "Greet" (0) ((PVar "x")) (CBinPrim "++" (CApp (CVar "hello" AGlobal) (CVar "x" (ALocal 0 0))) (CLit (LString "!"))))) (CImplEntry "hello" 0 (CImplTagged "Fr" "Greet|Fr|" "Greet" (0) (PWild) (CLit (LString "salut")))) (CImplEntry "loud" 0 (CImplTagged "Fr" "Greet|Fr|" "Greet" (0) (PWild) (CLit (LString "SALUT!!"))))))
