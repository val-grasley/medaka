# META
source_lines=3
stages=EVAL
diagnostics=CRASH
# SOURCE
-- non-exhaustive match: EMatch with no matching arm
main = match 5
  0 => "zero"
# CRASH
:0:0: runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match
