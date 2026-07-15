# META
source_lines=4
stages=TYPES_USER
# SOURCE
x = {- has { unbalanced brace in block comment -} 1
y = 2

main = println (x + y)
# TYPES_USER
x : Int
y : Int
main : Unit
