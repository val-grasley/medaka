# META
source_lines=20
stages=TYPES_USER
# SOURCE
data Shape = Circle Int | Rect Int Int deriving (Display)

area s =
  match s
    Circle r => r * r
    Rect w h => w * h

perimeter s =
  match s
    Circle r => 2 * r
    Rect w h => 2 * (w + h)

main : <IO> Unit
main =
  let c = Circle 5
  let r = Rect 3 4
  println c
  println (area c)
  println (area r)
  println (perimeter r)
# TYPES_USER
area : Shape -> Int
perimeter : Shape -> Int
main : Unit
