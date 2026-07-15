# META
source_lines=5
stages=TYPES_USER
# SOURCE
x : Float
x = 0

main : <IO> Unit
main = println x
# TYPES_USER
x : Float
main : Unit
