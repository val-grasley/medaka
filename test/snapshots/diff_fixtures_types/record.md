# META
source_lines=13
stages=TYPES_USER
# SOURCE
data Point = { x : Int, y : Int }

distSq p = p.x * p.x + p.y * p.y

moveRight p = { p | x = p.x + 1 }

main : <IO> Unit
main =
  let p = Point { x = 3, y = 4 }
  println (distSq p)
  let q = moveRight p
  println q.x
  println (distSq q)
# TYPES_USER
distSq : Point -> Int
moveRight : Point -> Point
main : Unit
