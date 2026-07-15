# META
source_lines=5
stages=TYPES_USER
# SOURCE
x = 1
-- top-level comment-only line (layout-transparent)
y = 2

main = println (x + y)
# TYPES_USER
x : Int
y : Int
main : Unit
