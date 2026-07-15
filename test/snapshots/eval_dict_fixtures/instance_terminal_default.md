# META
source_lines=17
stages=EVAL
# SOURCE
-- TYPECHECK-AUDIT S1: a TERMINAL impl body at a return-position method. The
-- `impl Default (List a) requires Default a` body `def = []` uses no inner method,
-- so usesImplDict adds NO leading dict param — the body is a terminal value. After
-- narrowing+stripping, `def : List Int` is the bare `VList []`. Applying the
-- route's impl/method dicts to it would over-apply ("applied non-function: []").
-- The awaits-args gate in EMethodAt (mirroring lib/eval.ml:869-873) drops the
-- dicts onto a non-awaiting value, so this yields `[]` matching the oracle.
interface Default a where
  def : a

impl Default Int where
  def = 0

impl Default (List a) requires Default a where
  def = []

main = putStrLn (debug (def : List Int))
# EVAL
[]
