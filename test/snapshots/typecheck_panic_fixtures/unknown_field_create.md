# META
source_lines=3
stages=TYPES
diagnostics=TYPES
# SOURCE
data Pt = { x : Int }

f = Pt { x = 1, y = 2 }
# TYPES
TYPE ERROR: Field 'y' does not belong to record 'Pt'
