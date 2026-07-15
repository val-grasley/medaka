# META
source_lines=7
stages=TYPES_USER
# SOURCE
main =
  if True
  then
    if False
    then println "a"
    else println "b"
  else println "c"
# TYPES_USER
main : Unit
