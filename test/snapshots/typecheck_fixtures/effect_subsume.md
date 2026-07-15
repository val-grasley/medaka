# META
source_lines=11
stages=TYPES
# SOURCE
-- Phase 146 subsumption (must be ACCEPTED): a pure function passed into an
-- effect-allowing parameter slot.  pure ⊆ <IO>, and the contravariant parameter
-- row stays closed under instantiate, so the pure argument legitimately subsumes.
pureId : String -> Unit
pureId s = pureId s

useEff : (String -> <IO> Unit) -> Unit
useEff f = useEff f

run : Unit
run = useEff pureId
# TYPES
pureId : String -> Unit
useEff : (String -> <IO> Unit) -> Unit
run : Unit
