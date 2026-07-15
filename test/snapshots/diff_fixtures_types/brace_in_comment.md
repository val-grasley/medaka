# META
source_lines=4
stages=TYPES_USER
# SOURCE
x = 1 -- has { unbalanced brace in comment
y = 2

main = println (x + y)
# TYPES_USER
x : Int
y : Int
main : Unit
