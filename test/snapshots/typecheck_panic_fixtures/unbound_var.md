# META
source_lines=1
stages=TYPES
diagnostics=TYPES
# SOURCE
f x = x + nope
# TYPES
TYPE ERROR: Unbound variable: nope
