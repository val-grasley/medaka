# META
source_lines=8
stages=TYPES_USER
# SOURCE
main : <IO> Unit
main =
  println 42
  println (2 + 3)
  println (10 - 4)
  println (3 * 7)
  println True
  println False
# TYPES_USER
main : Unit
