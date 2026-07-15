# META
source_lines=1
stages=EVAL
diagnostics=CRASH
# SOURCE
main = "hello".[10]
# CRASH
:0:0: runtime error [E-INDEX-OOB]: index 10 out of bounds
