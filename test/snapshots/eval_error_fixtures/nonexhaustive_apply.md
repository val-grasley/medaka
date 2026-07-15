# META
source_lines=3
stages=EVAL
diagnostics=CRASH
# SOURCE
-- non-exhaustive match: single-clause function with non-matching arg
f 0 = "zero"
main = f 5
# CRASH
:0:0: runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match
