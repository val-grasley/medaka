# META
source_lines=5
stages=TYPES_USER
# SOURCE
g : Float -> Float
g x = x + 1

main : <IO> Unit
main = println (g 2.0)
# TYPES_USER
g : Float -> Float
main : Unit
