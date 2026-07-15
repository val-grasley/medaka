# META
source_lines=18
stages=TYPES
# SOURCE
-- records: create, field access (incl. nested), update, patterns; parametric
data P = { x : Int, y : Int }
data Box a = { val : a, tag : String }
data Line = { a : P, b : P }
mkP a b = P { x = a, y = b }
getX p = p.x
sumP p = p.x + p.y
moveX p = { p | x = p.x + 1, y = 0 }
dist p = match p
  P { x, y } => x + y
wrap v = Box { val = v, tag = "t" }
unwrap b = b.val
retag b s = { b | tag = s }
getV b = match b
  Box { val } => val
swapBoxes b1 b2 = (b1.val, b2.val)
endY l = l.b.y
mkLine p q = Line { a = p, b = q }
# TYPES
mkP : Int -> Int -> P
getX : P -> Int
sumP : P -> Int
moveX : P -> P
dist : P -> Int
wrap : a -> Box a
unwrap : Box a -> a
retag : Box a -> String -> Box a
getV : Box a -> a
swapBoxes : Box a -> Box b -> (a, b)
endY : Line -> Int
mkLine : P -> P -> Line
