# META
source_lines=3
stages=TYPES
diagnostics=TYPES
# SOURCE
f x = match x
  MkNope y => y
  _ => 0
# TYPES
TYPE ERROR: Unknown constructor: MkNope
