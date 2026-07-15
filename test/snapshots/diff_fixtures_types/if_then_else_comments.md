# META
source_lines=4
stages=TYPES_USER
# SOURCE
main =
  if True -- condition
  then println "yes" -- then branch
  else println "no" -- else branch
# TYPES_USER
main : Unit
