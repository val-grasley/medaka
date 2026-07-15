# META
source_lines=2
stages=TYPES_USER
# SOURCE
main : <IO> Unit
main = println (sum [1.0, 2.0, 3.0])
# TYPES_USER
main : Unit
