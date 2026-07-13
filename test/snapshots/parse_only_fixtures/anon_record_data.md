# META
source_lines=7
stages=PARSE
# SOURCE
data Point = { x : Int, y : Int }

data Box a = { v : a }

data Named = Named { a : Int, b : Int }

data Multi = Foo Int | Bar { z : Int }
# PARSE
(DData Private "Point" () ((variant "Point" (ConNamed (field "x" (TyCon "Int")) (field "y" (TyCon "Int"))))) ())
(DData Private "Box" ("a") ((variant "Box" (ConNamed (field "v" (TyVar "a"))))) ())
(DData Private "Named" () ((variant "Named" (ConNamed (field "a" (TyCon "Int")) (field "b" (TyCon "Int"))))) ())
(DData Private "Multi" () ((variant "Foo" (ConPos (TyCon "Int"))) (variant "Bar" (ConNamed (field "z" (TyCon "Int"))))) ())
