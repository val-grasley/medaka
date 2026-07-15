# META
source_lines=17
stages=TYPES_USER
# SOURCE
-- Phase 146 gap 2: user-declared effect labels.  `effect KV`/`effect Log`
-- register labels usable in rows; a <KV> body subsumes under a <KV, Log> bound.
-- The effectful functions typecheck (exercising propagation + subsumption) but
-- are not reached from `main`, so EVAL stays clean.
effect KV
effect Log

extern kvGet : String -> <KV> String

get : String -> <KV> String
get k = kvGet k

handler : String -> <KV, Log> String
handler k = get k

main : <IO> Unit
main = println "effect labels ok"
# TYPES_USER
kvGet : String -> <KV> String
get : String -> <KV> String
handler : String -> <KV, Log> String
main : Unit
