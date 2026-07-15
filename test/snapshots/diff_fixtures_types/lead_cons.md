# META
source_lines=4
stages=TYPES_USER
# SOURCE
r = [1, 2]
  :: [[3, 4]]

main = println r
# TYPES_USER
r : List (List Int)
main : Unit
