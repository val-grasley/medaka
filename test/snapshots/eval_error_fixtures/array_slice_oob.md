# META
source_lines=1
stages=EVAL
diagnostics=CRASH
# SOURCE
main = [|1, 2, 3|].[0..10]
# CRASH
:0:0: runtime error [E-SLICE-OOB]: slice [0..9] out of bounds
