# META
source_lines=18
stages=CORE_IR
# SOURCE
-- user-defined interface + impls, argument-position dispatch
interface Shape a where
  area : a -> Int
  name : a -> String
data Circle = Circle Int
data Square = Square Int
data Rect = Rect Int Int
impl Shape Circle where
  area (Circle r) = 3 * r * r
  name _ = "circle"
impl Shape Square where
  area (Square s) = s * s
  name _ = "square"
impl Shape Rect where
  area (Rect w h) = w * h
  name _ = "rect"
describe s = name s ++ ":" ++ intToString (area s)
main = (area (Circle 2), area (Square 3), area (Rect 2 5), describe (Circle 1), describe (Rect 3 3))
# CORE_IR
(CProgram ((CBind "describe" (CClause ((PVar "s")) (CBinPrim "++" (CBinPrim "++" (CApp (CVar "name" AGlobal) (CVar "s" (ALocal 0 0))) (CLit (LString ":"))) (CApp (CVar "intToString" AGlobal) (CApp (CVar "area" AGlobal) (CVar "s" (ALocal 0 0))))))) (CBind "main" (CClause () (CTuple (CApp (CVar "area" AGlobal) (CApp (CVar "Circle" AGlobal) (CLit (LInt 2)))) (CApp (CVar "area" AGlobal) (CApp (CVar "Square" AGlobal) (CLit (LInt 3)))) (CApp (CVar "area" AGlobal) (CApp (CApp (CVar "Rect" AGlobal) (CLit (LInt 2))) (CLit (LInt 5)))) (CApp (CVar "describe" AGlobal) (CApp (CVar "Circle" AGlobal) (CLit (LInt 1)))) (CApp (CVar "describe" AGlobal) (CApp (CApp (CVar "Rect" AGlobal) (CLit (LInt 3))) (CLit (LInt 3)))))))) ((ca "Circle" 1) (ca "Square" 1) (ca "Rect" 2)) ((ct "Circle" "Circle") (ct "Square" "Square") (ct "Rect" "Rect")) ((CImplEntry "area" 0 (CImplTagged "Circle" "Shape|Circle|" "Shape" (0) ((PCon "Circle" (PVar "r"))) (CBinPrim "*" (CBinPrim "*" (CLit (LInt 3)) (CVar "r" (ALocal 0 0))) (CVar "r" (ALocal 0 0))))) (CImplEntry "name" 0 (CImplTagged "Circle" "Shape|Circle|" "Shape" (0) (PWild) (CLit (LString "circle")))) (CImplEntry "area" 0 (CImplTagged "Square" "Shape|Square|" "Shape" (0) ((PCon "Square" (PVar "s"))) (CBinPrim "*" (CVar "s" (ALocal 0 0)) (CVar "s" (ALocal 0 0))))) (CImplEntry "name" 0 (CImplTagged "Square" "Shape|Square|" "Shape" (0) (PWild) (CLit (LString "square")))) (CImplEntry "area" 0 (CImplTagged "Rect" "Shape|Rect|" "Shape" (0) ((PCon "Rect" (PVar "w") (PVar "h"))) (CBinPrim "*" (CVar "w" (ALocal 0 0)) (CVar "h" (ALocal 0 1))))) (CImplEntry "name" 0 (CImplTagged "Rect" "Shape|Rect|" "Shape" (0) (PWild) (CLit (LString "rect"))))))
