# META
source_lines=2
stages=TYPES
diagnostics=TYPES
# SOURCE
f r = match r
  Nope { a = x } => x
# TYPES
TYPE ERROR: Unknown record type: Nope
