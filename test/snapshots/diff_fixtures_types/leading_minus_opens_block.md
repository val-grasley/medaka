# META
source_lines=5
stages=TYPES_USER
# SOURCE
x = 5
y =
  - x

main = println y
# TYPES_USER
x : Int
y : Int
main : Unit
