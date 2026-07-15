# META
source_lines=2
stages=EVAL
diagnostics=CRASH
# SOURCE
-- program with no `main` binding: should error
x = 5
# CRASH
:0:0: runtime error [E-NO-MAIN]: program has no 'main' binding
