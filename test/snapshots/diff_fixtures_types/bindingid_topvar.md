# META
source_lines=5
stages=TYPES_USER
# SOURCE
g x = x + 1

h = g 2

main = println h
# TYPES_USER
g : Num a => a -> a
h : Int
main : Unit
