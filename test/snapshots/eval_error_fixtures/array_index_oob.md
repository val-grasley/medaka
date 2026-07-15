# META
source_lines=1
stages=EVAL
diagnostics=CRASH
# SOURCE
main = [|1, 2, 3|].[5]
# CRASH
:0:0: runtime error [E-INDEX-OOB]: index 5 out of bounds
