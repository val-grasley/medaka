# META
source_lines=228
stages=DESUGAR,MARK
# SOURCE
{- time.mdk — durations + a UTC civil calendar, plus thin wrappers over the
   `<Clock>` externs (`wallTimeSec` / `monotonicSec` / `sleepMs`).

   Import with `import time.*` (or select names, e.g.
   `import time.{fromEpochSeconds, formatIso}`).

   ── Scope ──────────────────────────────────────────────────────────────
   • UTC ONLY.  There is no timezone / DST database (that is a P2 follow-up).
     Every `DateTime` here is civil UTC; `formatIso` always emits a `Z` suffix.
   • The calendar core (`fromEpochSeconds` / `toEpochSeconds`) uses Howard
     Hinnant's days-from-civil / civil-from-days algorithm — pure Int
     arithmetic, correct across leap years and for negative (pre-1970) epochs.
     Medaka's `/` truncates toward zero, so the seconds→days split uses a
     `floorDiv` helper; Hinnant's own `era` adjustments already assume
     truncating division, so they are used verbatim.

   ── Effect labels ──────────────────────────────────────────────────────
   The three externs all carry the `<Clock>` effect.  `sleepMs` reuses
   `<Clock>` for cohesion with the time domain — there is no `<Sleep>` label
   and adding one is out of scope.  Unlike the file externs, `<Clock>`
   externs DO run under the interpreter (`medaka run`): there the interpreter
   oracle has no FFI to the clock, so `wallTimeSec` / `monotonicSec` return
   fixed plausible values and `sleepMs` is a no-op.  On native `build` they
   call the real C clock / `nanosleep`. -}

-- ── Duration ────────────────────────────────────────────────────────────
-- | A time span, stored as a whole number of MILLISECONDS.
public export data Duration = Duration Int

-- | A duration of `n` milliseconds.
--
-- > toMillis (millis 250)
-- 250
export millis : Int -> Duration
millis n = Duration n

-- | A duration of `n` seconds.
--
-- > toMillis (seconds 5)
-- 5000
export seconds : Int -> Duration
seconds n = Duration (n * 1000)

-- | A duration of `n` minutes.
--
-- > toSeconds (minutes 2)
-- 120
export minutes : Int -> Duration
minutes n = Duration (n * 60000)

-- | A duration of `n` hours.
--
-- > toSeconds (hours 1)
-- 3600
export hours : Int -> Duration
hours n = Duration (n * 3600000)

-- | A duration of `n` days.
--
-- > toSeconds (days 1)
-- 86400
export days : Int -> Duration
days n = Duration (n * 86400000)

-- | The duration as whole milliseconds.
export toMillis : Duration -> Int
toMillis (Duration ms) = ms

-- | The duration as whole seconds (truncated toward zero).
--
-- > toSeconds (millis 2500)
-- 2
export toSeconds : Duration -> Int
toSeconds (Duration ms) = ms / 1000

-- | Add two durations.
--
-- > toMillis (addDuration (seconds 1) (millis 500))
-- 1500
export addDuration : Duration -> Duration -> Duration
addDuration (Duration a) (Duration b) = Duration (a + b)

-- | Subtract the second duration from the first.
--
-- > toMillis (subDuration (seconds 2) (millis 500))
-- 1500
export subDuration : Duration -> Duration -> Duration
subDuration (Duration a) (Duration b) = Duration (a - b)

-- ── UTC civil calendar ──────────────────────────────────────────────────
-- | A civil UTC date-and-time.  `month` is 1-12, `day` is 1-31.
public export data DateTime =
  | DateTime {
      year : Int,
      month : Int,
      day : Int,
      hour : Int,
      minute : Int,
      second : Int,
    }

-- Floor division (Medaka `/` truncates toward zero; the calendar needs floor
-- so that a negative epoch maps to the correct earlier day).
floorDiv : Int -> Int -> Int
floorDiv a b =
  let q = a / b
  let r = a - q * b
  if r != 0 && r < 0 != (b < 0) then q - 1 else q

-- Days since 1970-01-01 for a civil (y, m, d).  Hinnant's days_from_civil.
daysFromCivil : Int -> Int -> Int -> Int
daysFromCivil y0 m d =
  let y = if m <= 2 then y0 - 1 else y0
  let era = (if y >= 0 then y else y - 399) / 400
  let yoe = y - era * 400
  let mp = if m > 2 then m - 3 else m + 9
  let doy = (153 * mp + 2) / 5 + d - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468

-- Civil (year, month, day) for a day count since 1970-01-01.
-- Hinnant's civil_from_days.
civilFromDays : Int -> (Int, Int, Int)
civilFromDays z0 =
  let z = z0 + 719468
  let era = (if z >= 0 then z else z - 146096) / 146097
  let doe = z - era * 146097
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = if mp < 10 then mp + 3 else mp - 9
  (if m <= 2 then y + 1 else y, m, d)

-- | Convert Unix epoch seconds (UTC) to a civil `DateTime`.  Supports
-- negative (pre-1970) inputs.
--
-- > formatIso (fromEpochSeconds 0)
-- "1970-01-01T00:00:00Z"
-- > formatIso (fromEpochSeconds 1000000000)
-- "2001-09-09T01:46:40Z"
-- > formatIso (fromEpochSeconds 951782400)
-- "2000-02-29T00:00:00Z"
-- > formatIso (fromEpochSeconds 1709164800)
-- "2024-02-29T00:00:00Z"
-- > formatIso (fromEpochSeconds (0 - 1))
-- "1969-12-31T23:59:59Z"
export fromEpochSeconds : Int -> DateTime
fromEpochSeconds secs =
  let ds = floorDiv secs 86400
  let sod = secs - ds * 86400
  match civilFromDays ds
    (y, m, d) => DateTime {
      year = y,
      month = m,
      day = d,
      hour = sod / 3600,
      minute = (sod / 60) % 60,
      second = sod % 60,
    }

-- | Convert a civil `DateTime` (UTC) to Unix epoch seconds.  Inverse of
-- `fromEpochSeconds`.
--
-- > toEpochSeconds (fromEpochSeconds 1000000000)
-- 1000000000
export toEpochSeconds : DateTime -> Int
toEpochSeconds dt =
  daysFromCivil dt.year dt.month dt.day * 86400 + dt.hour * 3600 + dt.minute * 60 +
    dt.second

-- Zero-pad a non-negative Int to two digits.
pad2 : Int -> String
pad2 n = if n < 10 then "0" ++ intToString n else intToString n

-- Zero-pad a non-negative Int to (at least) four digits, for ISO years.
pad4 : Int -> String
pad4 n =
  if n < 10 then
    "000" ++ intToString n
  else if n < 100 then
    "00" ++ intToString n
  else if n < 1000 then
    "0" ++ intToString n
  else
    intToString n

-- | Render a `DateTime` as ISO 8601 `YYYY-MM-DDThh:mm:ssZ` (zero-padded, UTC).
--
-- > formatIso (DateTime { year = 2024, month = 3, day = 5, hour = 7, minute = 8, second = 9 })
-- "2024-03-05T07:08:09Z"
export formatIso : DateTime -> String
formatIso dt = "\{pad4 dt.year}-\{pad2 dt.month}-\{pad2 dt.day}T\{pad2 dt.hour}:\{pad2 dt.minute}:\{pad2 dt.second}Z"

-- ── Effectful helpers (over the `<Clock>` externs) ──────────────────────
-- | Current wall-clock time in Unix epoch seconds (Float).
export now : Unit -> <Clock> Float
now u = wallTimeSec u

-- | Current UTC civil time, from the wall clock (floored to whole seconds).
export nowDateTime : Unit -> <Clock> DateTime
nowDateTime u = fromEpochSeconds (floatToInt (wallTimeSec u))

-- | A monotonic-clock reading in seconds (immune to wall-clock adjustment).
-- Use two readings to time an interval, or `elapsedSince`.
export monotonic : Unit -> <Clock> Float
monotonic u = monotonicSec u

-- | Seconds elapsed on the monotonic clock since an earlier `monotonic ()`
-- reading.  Time a block with `let t0 = monotonic ()  … elapsedSince t0`.
export elapsedSince : Float -> <Clock> Float
elapsedSince start = monotonicSec () - start

-- | Sleep for `ms` milliseconds.
export sleep : Int -> <Clock> Unit
sleep ms = sleepMs ms

-- | Sleep for `s` seconds.
export sleepSeconds : Int -> <Clock> Unit
sleepSeconds s = sleepMs (s * 1000)

-- Round-trip: epoch → civil → epoch is the identity (n constrained ≥ 0 to a
-- sane band; negatives are supported too, see the `fromEpochSeconds (0 - 1)`
-- doctest).
prop "epoch round-trips through the civil calendar" (n : Int) =
  let s = 1000000 + (if n < 0 then 0 - n else n) % 3000000000
  toEpochSeconds (fromEpochSeconds s) == s
# DESUGAR
(DData Public "Duration" () ((variant "Duration" (ConPos (TyCon "Int")))) ())
(DTypeSig true "millis" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "millis" ((PVar "n")) (EApp (EVar "Duration") (EVar "n")))
(DTypeSig true "seconds" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "seconds" ((PVar "n")) (EApp (EVar "Duration") (EBinOp "*" (EVar "n") (ELit (LInt 1000)))))
(DTypeSig true "minutes" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "minutes" ((PVar "n")) (EApp (EVar "Duration") (EBinOp "*" (EVar "n") (ELit (LInt 60000)))))
(DTypeSig true "hours" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "hours" ((PVar "n")) (EApp (EVar "Duration") (EBinOp "*" (EVar "n") (ELit (LInt 3600000)))))
(DTypeSig true "days" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "days" ((PVar "n")) (EApp (EVar "Duration") (EBinOp "*" (EVar "n") (ELit (LInt 86400000)))))
(DTypeSig true "toMillis" (TyFun (TyCon "Duration") (TyCon "Int")))
(DFunDef false "toMillis" ((PCon "Duration" (PVar "ms"))) (EVar "ms"))
(DTypeSig true "toSeconds" (TyFun (TyCon "Duration") (TyCon "Int")))
(DFunDef false "toSeconds" ((PCon "Duration" (PVar "ms"))) (EBinOp "/" (EVar "ms") (ELit (LInt 1000))))
(DTypeSig true "addDuration" (TyFun (TyCon "Duration") (TyFun (TyCon "Duration") (TyCon "Duration"))))
(DFunDef false "addDuration" ((PCon "Duration" (PVar "a")) (PCon "Duration" (PVar "b"))) (EApp (EVar "Duration") (EBinOp "+" (EVar "a") (EVar "b"))))
(DTypeSig true "subDuration" (TyFun (TyCon "Duration") (TyFun (TyCon "Duration") (TyCon "Duration"))))
(DFunDef false "subDuration" ((PCon "Duration" (PVar "a")) (PCon "Duration" (PVar "b"))) (EApp (EVar "Duration") (EBinOp "-" (EVar "a") (EVar "b"))))
(DData Public "DateTime" () ((variant "DateTime" (ConNamed (field "year" (TyCon "Int")) (field "month" (TyCon "Int")) (field "day" (TyCon "Int")) (field "hour" (TyCon "Int")) (field "minute" (TyCon "Int")) (field "second" (TyCon "Int"))))) ())
(DTypeSig false "floorDiv" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "floorDiv" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "q") (EBinOp "/" (EVar "a") (EVar "b"))) (DoLet false false (PVar "r") (EBinOp "-" (EVar "a") (EBinOp "*" (EVar "q") (EVar "b")))) (DoExpr (EIf (EBinOp "&&" (EBinOp "!=" (EVar "r") (ELit (LInt 0))) (EBinOp "!=" (EBinOp "<" (EVar "r") (ELit (LInt 0))) (EBinOp "<" (EVar "b") (ELit (LInt 0))))) (EBinOp "-" (EVar "q") (ELit (LInt 1))) (EVar "q")))))
(DTypeSig false "daysFromCivil" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "daysFromCivil" ((PVar "y0") (PVar "m") (PVar "d")) (EBlock (DoLet false false (PVar "y") (EIf (EBinOp "<=" (EVar "m") (ELit (LInt 2))) (EBinOp "-" (EVar "y0") (ELit (LInt 1))) (EVar "y0"))) (DoLet false false (PVar "era") (EBinOp "/" (EIf (EBinOp ">=" (EVar "y") (ELit (LInt 0))) (EVar "y") (EBinOp "-" (EVar "y") (ELit (LInt 399)))) (ELit (LInt 400)))) (DoLet false false (PVar "yoe") (EBinOp "-" (EVar "y") (EBinOp "*" (EVar "era") (ELit (LInt 400))))) (DoLet false false (PVar "mp") (EIf (EBinOp ">" (EVar "m") (ELit (LInt 2))) (EBinOp "-" (EVar "m") (ELit (LInt 3))) (EBinOp "+" (EVar "m") (ELit (LInt 9))))) (DoLet false false (PVar "doy") (EBinOp "-" (EBinOp "+" (EBinOp "/" (EBinOp "+" (EBinOp "*" (ELit (LInt 153)) (EVar "mp")) (ELit (LInt 2))) (ELit (LInt 5))) (EVar "d")) (ELit (LInt 1)))) (DoLet false false (PVar "doe") (EBinOp "+" (EBinOp "-" (EBinOp "+" (EBinOp "*" (EVar "yoe") (ELit (LInt 365))) (EBinOp "/" (EVar "yoe") (ELit (LInt 4)))) (EBinOp "/" (EVar "yoe") (ELit (LInt 100)))) (EVar "doy"))) (DoExpr (EBinOp "-" (EBinOp "+" (EBinOp "*" (EVar "era") (ELit (LInt 146097))) (EVar "doe")) (ELit (LInt 719468))))))
(DTypeSig false "civilFromDays" (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "civilFromDays" ((PVar "z0")) (EBlock (DoLet false false (PVar "z") (EBinOp "+" (EVar "z0") (ELit (LInt 719468)))) (DoLet false false (PVar "era") (EBinOp "/" (EIf (EBinOp ">=" (EVar "z") (ELit (LInt 0))) (EVar "z") (EBinOp "-" (EVar "z") (ELit (LInt 146096)))) (ELit (LInt 146097)))) (DoLet false false (PVar "doe") (EBinOp "-" (EVar "z") (EBinOp "*" (EVar "era") (ELit (LInt 146097))))) (DoLet false false (PVar "yoe") (EBinOp "/" (EBinOp "-" (EBinOp "+" (EBinOp "-" (EVar "doe") (EBinOp "/" (EVar "doe") (ELit (LInt 1460)))) (EBinOp "/" (EVar "doe") (ELit (LInt 36524)))) (EBinOp "/" (EVar "doe") (ELit (LInt 146096)))) (ELit (LInt 365)))) (DoLet false false (PVar "y") (EBinOp "+" (EVar "yoe") (EBinOp "*" (EVar "era") (ELit (LInt 400))))) (DoLet false false (PVar "doy") (EBinOp "-" (EVar "doe") (EBinOp "-" (EBinOp "+" (EBinOp "*" (ELit (LInt 365)) (EVar "yoe")) (EBinOp "/" (EVar "yoe") (ELit (LInt 4)))) (EBinOp "/" (EVar "yoe") (ELit (LInt 100)))))) (DoLet false false (PVar "mp") (EBinOp "/" (EBinOp "+" (EBinOp "*" (ELit (LInt 5)) (EVar "doy")) (ELit (LInt 2))) (ELit (LInt 153)))) (DoLet false false (PVar "d") (EBinOp "+" (EBinOp "-" (EVar "doy") (EBinOp "/" (EBinOp "+" (EBinOp "*" (ELit (LInt 153)) (EVar "mp")) (ELit (LInt 2))) (ELit (LInt 5)))) (ELit (LInt 1)))) (DoLet false false (PVar "m") (EIf (EBinOp "<" (EVar "mp") (ELit (LInt 10))) (EBinOp "+" (EVar "mp") (ELit (LInt 3))) (EBinOp "-" (EVar "mp") (ELit (LInt 9))))) (DoExpr (ETuple (EIf (EBinOp "<=" (EVar "m") (ELit (LInt 2))) (EBinOp "+" (EVar "y") (ELit (LInt 1))) (EVar "y")) (EVar "m") (EVar "d")))))
(DTypeSig true "fromEpochSeconds" (TyFun (TyCon "Int") (TyCon "DateTime")))
(DFunDef false "fromEpochSeconds" ((PVar "secs")) (EBlock (DoLet false false (PVar "ds") (EApp (EApp (EVar "floorDiv") (EVar "secs")) (ELit (LInt 86400)))) (DoLet false false (PVar "sod") (EBinOp "-" (EVar "secs") (EBinOp "*" (EVar "ds") (ELit (LInt 86400))))) (DoExpr (EMatch (EApp (EVar "civilFromDays") (EVar "ds")) (arm (PTuple (PVar "y") (PVar "m") (PVar "d")) () (ERecordCreate "DateTime" ((fa "year" (EVar "y")) (fa "month" (EVar "m")) (fa "day" (EVar "d")) (fa "hour" (EBinOp "/" (EVar "sod") (ELit (LInt 3600)))) (fa "minute" (EBinOp "%" (EBinOp "/" (EVar "sod") (ELit (LInt 60))) (ELit (LInt 60)))) (fa "second" (EBinOp "%" (EVar "sod") (ELit (LInt 60)))))))))))
(DTypeSig true "toEpochSeconds" (TyFun (TyCon "DateTime") (TyCon "Int")))
(DFunDef false "toEpochSeconds" ((PVar "dt")) (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EApp (EApp (EApp (EVar "daysFromCivil") (EFieldAccess (EVar "dt") "year")) (EFieldAccess (EVar "dt") "month")) (EFieldAccess (EVar "dt") "day")) (ELit (LInt 86400))) (EBinOp "*" (EFieldAccess (EVar "dt") "hour") (ELit (LInt 3600)))) (EBinOp "*" (EFieldAccess (EVar "dt") "minute") (ELit (LInt 60)))) (EFieldAccess (EVar "dt") "second")))
(DTypeSig false "pad2" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "pad2" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 10))) (EBinOp "++" (ELit (LString "0")) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))))
(DTypeSig false "pad4" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "pad4" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 10))) (EBinOp "++" (ELit (LString "000")) (EApp (EVar "intToString") (EVar "n"))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 100))) (EBinOp "++" (ELit (LString "00")) (EApp (EVar "intToString") (EVar "n"))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 1000))) (EBinOp "++" (ELit (LString "0")) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))))))
(DTypeSig true "formatIso" (TyFun (TyCon "DateTime") (TyCon "String")))
(DFunDef false "formatIso" ((PVar "dt")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "pad4") (EFieldAccess (EVar "dt") "year")))) (ELit (LString "-"))) (EApp (EVar "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "month")))) (ELit (LString "-"))) (EApp (EVar "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "day")))) (ELit (LString "T"))) (EApp (EVar "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "hour")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "minute")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "second")))) (ELit (LString "Z"))))
(DTypeSig true "now" (TyFun (TyCon "Unit") (TyEffect ("Clock") None (TyCon "Float"))))
(DFunDef false "now" ((PVar "u")) (EApp (EVar "wallTimeSec") (EVar "u")))
(DTypeSig true "nowDateTime" (TyFun (TyCon "Unit") (TyEffect ("Clock") None (TyCon "DateTime"))))
(DFunDef false "nowDateTime" ((PVar "u")) (EApp (EVar "fromEpochSeconds") (EApp (EVar "floatToInt") (EApp (EVar "wallTimeSec") (EVar "u")))))
(DTypeSig true "monotonic" (TyFun (TyCon "Unit") (TyEffect ("Clock") None (TyCon "Float"))))
(DFunDef false "monotonic" ((PVar "u")) (EApp (EVar "monotonicSec") (EVar "u")))
(DTypeSig true "elapsedSince" (TyFun (TyCon "Float") (TyEffect ("Clock") None (TyCon "Float"))))
(DFunDef false "elapsedSince" ((PVar "start")) (EBinOp "-" (EApp (EVar "monotonicSec") (ELit LUnit)) (EVar "start")))
(DTypeSig true "sleep" (TyFun (TyCon "Int") (TyEffect ("Clock") None (TyCon "Unit"))))
(DFunDef false "sleep" ((PVar "ms")) (EApp (EVar "sleepMs") (EVar "ms")))
(DTypeSig true "sleepSeconds" (TyFun (TyCon "Int") (TyEffect ("Clock") None (TyCon "Unit"))))
(DFunDef false "sleepSeconds" ((PVar "s")) (EApp (EVar "sleepMs") (EBinOp "*" (EVar "s") (ELit (LInt 1000)))))
(DProp false "epoch round-trips through the civil calendar" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "s") (EBinOp "+" (ELit (LInt 1000000)) (EBinOp "%" (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")) (ELit (LInt 3000000000))))) (DoExpr (EBinOp "==" (EApp (EVar "toEpochSeconds") (EApp (EVar "fromEpochSeconds") (EVar "s"))) (EVar "s")))))
# MARK
(DData Public "Duration" () ((variant "Duration" (ConPos (TyCon "Int")))) ())
(DTypeSig true "millis" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "millis" ((PVar "n")) (EApp (EVar "Duration") (EVar "n")))
(DTypeSig true "seconds" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "seconds" ((PVar "n")) (EApp (EVar "Duration") (EBinOp "*" (EVar "n") (ELit (LInt 1000)))))
(DTypeSig true "minutes" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "minutes" ((PVar "n")) (EApp (EVar "Duration") (EBinOp "*" (EVar "n") (ELit (LInt 60000)))))
(DTypeSig true "hours" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "hours" ((PVar "n")) (EApp (EVar "Duration") (EBinOp "*" (EVar "n") (ELit (LInt 3600000)))))
(DTypeSig true "days" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "days" ((PVar "n")) (EApp (EVar "Duration") (EBinOp "*" (EVar "n") (ELit (LInt 86400000)))))
(DTypeSig true "toMillis" (TyFun (TyCon "Duration") (TyCon "Int")))
(DFunDef false "toMillis" ((PCon "Duration" (PVar "ms"))) (EVar "ms"))
(DTypeSig true "toSeconds" (TyFun (TyCon "Duration") (TyCon "Int")))
(DFunDef false "toSeconds" ((PCon "Duration" (PVar "ms"))) (EBinOp "/" (EVar "ms") (ELit (LInt 1000))))
(DTypeSig true "addDuration" (TyFun (TyCon "Duration") (TyFun (TyCon "Duration") (TyCon "Duration"))))
(DFunDef false "addDuration" ((PCon "Duration" (PVar "a")) (PCon "Duration" (PVar "b"))) (EApp (EVar "Duration") (EBinOp "+" (EVar "a") (EVar "b"))))
(DTypeSig true "subDuration" (TyFun (TyCon "Duration") (TyFun (TyCon "Duration") (TyCon "Duration"))))
(DFunDef false "subDuration" ((PCon "Duration" (PVar "a")) (PCon "Duration" (PVar "b"))) (EApp (EVar "Duration") (EBinOp "-" (EVar "a") (EVar "b"))))
(DData Public "DateTime" () ((variant "DateTime" (ConNamed (field "year" (TyCon "Int")) (field "month" (TyCon "Int")) (field "day" (TyCon "Int")) (field "hour" (TyCon "Int")) (field "minute" (TyCon "Int")) (field "second" (TyCon "Int"))))) ())
(DTypeSig false "floorDiv" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "floorDiv" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "q") (EBinOp "/" (EVar "a") (EVar "b"))) (DoLet false false (PVar "r") (EBinOp "-" (EVar "a") (EBinOp "*" (EVar "q") (EVar "b")))) (DoExpr (EIf (EBinOp "&&" (EBinOp "!=" (EVar "r") (ELit (LInt 0))) (EBinOp "!=" (EBinOp "<" (EVar "r") (ELit (LInt 0))) (EBinOp "<" (EVar "b") (ELit (LInt 0))))) (EBinOp "-" (EVar "q") (ELit (LInt 1))) (EVar "q")))))
(DTypeSig false "daysFromCivil" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "daysFromCivil" ((PVar "y0") (PVar "m") (PVar "d")) (EBlock (DoLet false false (PVar "y") (EIf (EBinOp "<=" (EVar "m") (ELit (LInt 2))) (EBinOp "-" (EVar "y0") (ELit (LInt 1))) (EVar "y0"))) (DoLet false false (PVar "era") (EBinOp "/" (EIf (EBinOp ">=" (EVar "y") (ELit (LInt 0))) (EVar "y") (EBinOp "-" (EVar "y") (ELit (LInt 399)))) (ELit (LInt 400)))) (DoLet false false (PVar "yoe") (EBinOp "-" (EVar "y") (EBinOp "*" (EVar "era") (ELit (LInt 400))))) (DoLet false false (PVar "mp") (EIf (EBinOp ">" (EVar "m") (ELit (LInt 2))) (EBinOp "-" (EVar "m") (ELit (LInt 3))) (EBinOp "+" (EVar "m") (ELit (LInt 9))))) (DoLet false false (PVar "doy") (EBinOp "-" (EBinOp "+" (EBinOp "/" (EBinOp "+" (EBinOp "*" (ELit (LInt 153)) (EVar "mp")) (ELit (LInt 2))) (ELit (LInt 5))) (EVar "d")) (ELit (LInt 1)))) (DoLet false false (PVar "doe") (EBinOp "+" (EBinOp "-" (EBinOp "+" (EBinOp "*" (EVar "yoe") (ELit (LInt 365))) (EBinOp "/" (EVar "yoe") (ELit (LInt 4)))) (EBinOp "/" (EVar "yoe") (ELit (LInt 100)))) (EVar "doy"))) (DoExpr (EBinOp "-" (EBinOp "+" (EBinOp "*" (EVar "era") (ELit (LInt 146097))) (EVar "doe")) (ELit (LInt 719468))))))
(DTypeSig false "civilFromDays" (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "civilFromDays" ((PVar "z0")) (EBlock (DoLet false false (PVar "z") (EBinOp "+" (EVar "z0") (ELit (LInt 719468)))) (DoLet false false (PVar "era") (EBinOp "/" (EIf (EBinOp ">=" (EVar "z") (ELit (LInt 0))) (EVar "z") (EBinOp "-" (EVar "z") (ELit (LInt 146096)))) (ELit (LInt 146097)))) (DoLet false false (PVar "doe") (EBinOp "-" (EVar "z") (EBinOp "*" (EVar "era") (ELit (LInt 146097))))) (DoLet false false (PVar "yoe") (EBinOp "/" (EBinOp "-" (EBinOp "+" (EBinOp "-" (EVar "doe") (EBinOp "/" (EVar "doe") (ELit (LInt 1460)))) (EBinOp "/" (EVar "doe") (ELit (LInt 36524)))) (EBinOp "/" (EVar "doe") (ELit (LInt 146096)))) (ELit (LInt 365)))) (DoLet false false (PVar "y") (EBinOp "+" (EVar "yoe") (EBinOp "*" (EVar "era") (ELit (LInt 400))))) (DoLet false false (PVar "doy") (EBinOp "-" (EVar "doe") (EBinOp "-" (EBinOp "+" (EBinOp "*" (ELit (LInt 365)) (EVar "yoe")) (EBinOp "/" (EVar "yoe") (ELit (LInt 4)))) (EBinOp "/" (EVar "yoe") (ELit (LInt 100)))))) (DoLet false false (PVar "mp") (EBinOp "/" (EBinOp "+" (EBinOp "*" (ELit (LInt 5)) (EVar "doy")) (ELit (LInt 2))) (ELit (LInt 153)))) (DoLet false false (PVar "d") (EBinOp "+" (EBinOp "-" (EVar "doy") (EBinOp "/" (EBinOp "+" (EBinOp "*" (ELit (LInt 153)) (EVar "mp")) (ELit (LInt 2))) (ELit (LInt 5)))) (ELit (LInt 1)))) (DoLet false false (PVar "m") (EIf (EBinOp "<" (EVar "mp") (ELit (LInt 10))) (EBinOp "+" (EVar "mp") (ELit (LInt 3))) (EBinOp "-" (EVar "mp") (ELit (LInt 9))))) (DoExpr (ETuple (EIf (EBinOp "<=" (EVar "m") (ELit (LInt 2))) (EBinOp "+" (EVar "y") (ELit (LInt 1))) (EVar "y")) (EVar "m") (EVar "d")))))
(DTypeSig true "fromEpochSeconds" (TyFun (TyCon "Int") (TyCon "DateTime")))
(DFunDef false "fromEpochSeconds" ((PVar "secs")) (EBlock (DoLet false false (PVar "ds") (EApp (EApp (EVar "floorDiv") (EVar "secs")) (ELit (LInt 86400)))) (DoLet false false (PVar "sod") (EBinOp "-" (EVar "secs") (EBinOp "*" (EVar "ds") (ELit (LInt 86400))))) (DoExpr (EMatch (EApp (EVar "civilFromDays") (EVar "ds")) (arm (PTuple (PVar "y") (PVar "m") (PVar "d")) () (ERecordCreate "DateTime" ((fa "year" (EVar "y")) (fa "month" (EVar "m")) (fa "day" (EVar "d")) (fa "hour" (EBinOp "/" (EVar "sod") (ELit (LInt 3600)))) (fa "minute" (EBinOp "%" (EBinOp "/" (EVar "sod") (ELit (LInt 60))) (ELit (LInt 60)))) (fa "second" (EBinOp "%" (EVar "sod") (ELit (LInt 60)))))))))))
(DTypeSig true "toEpochSeconds" (TyFun (TyCon "DateTime") (TyCon "Int")))
(DFunDef false "toEpochSeconds" ((PVar "dt")) (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EApp (EApp (EApp (EVar "daysFromCivil") (EFieldAccess (EVar "dt") "year")) (EFieldAccess (EVar "dt") "month")) (EFieldAccess (EVar "dt") "day")) (ELit (LInt 86400))) (EBinOp "*" (EFieldAccess (EVar "dt") "hour") (ELit (LInt 3600)))) (EBinOp "*" (EFieldAccess (EVar "dt") "minute") (ELit (LInt 60)))) (EFieldAccess (EVar "dt") "second")))
(DTypeSig false "pad2" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "pad2" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 10))) (EBinOp "++" (ELit (LString "0")) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))))
(DTypeSig false "pad4" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "pad4" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 10))) (EBinOp "++" (ELit (LString "000")) (EApp (EVar "intToString") (EVar "n"))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 100))) (EBinOp "++" (ELit (LString "00")) (EApp (EVar "intToString") (EVar "n"))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 1000))) (EBinOp "++" (ELit (LString "0")) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))))))
(DTypeSig true "formatIso" (TyFun (TyCon "DateTime") (TyCon "String")))
(DFunDef false "formatIso" ((PVar "dt")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "pad4") (EFieldAccess (EVar "dt") "year")))) (ELit (LString "-"))) (EApp (EMethodRef "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "month")))) (ELit (LString "-"))) (EApp (EMethodRef "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "day")))) (ELit (LString "T"))) (EApp (EMethodRef "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "hour")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "minute")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "second")))) (ELit (LString "Z"))))
(DTypeSig true "now" (TyFun (TyCon "Unit") (TyEffect ("Clock") None (TyCon "Float"))))
(DFunDef false "now" ((PVar "u")) (EApp (EVar "wallTimeSec") (EVar "u")))
(DTypeSig true "nowDateTime" (TyFun (TyCon "Unit") (TyEffect ("Clock") None (TyCon "DateTime"))))
(DFunDef false "nowDateTime" ((PVar "u")) (EApp (EVar "fromEpochSeconds") (EApp (EVar "floatToInt") (EApp (EVar "wallTimeSec") (EVar "u")))))
(DTypeSig true "monotonic" (TyFun (TyCon "Unit") (TyEffect ("Clock") None (TyCon "Float"))))
(DFunDef false "monotonic" ((PVar "u")) (EApp (EVar "monotonicSec") (EVar "u")))
(DTypeSig true "elapsedSince" (TyFun (TyCon "Float") (TyEffect ("Clock") None (TyCon "Float"))))
(DFunDef false "elapsedSince" ((PVar "start")) (EBinOp "-" (EApp (EVar "monotonicSec") (ELit LUnit)) (EVar "start")))
(DTypeSig true "sleep" (TyFun (TyCon "Int") (TyEffect ("Clock") None (TyCon "Unit"))))
(DFunDef false "sleep" ((PVar "ms")) (EApp (EVar "sleepMs") (EVar "ms")))
(DTypeSig true "sleepSeconds" (TyFun (TyCon "Int") (TyEffect ("Clock") None (TyCon "Unit"))))
(DFunDef false "sleepSeconds" ((PVar "s")) (EApp (EVar "sleepMs") (EBinOp "*" (EVar "s") (ELit (LInt 1000)))))
(DProp false "epoch round-trips through the civil calendar" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "s") (EBinOp "+" (ELit (LInt 1000000)) (EBinOp "%" (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")) (ELit (LInt 3000000000))))) (DoExpr (EBinOp "==" (EApp (EVar "toEpochSeconds") (EApp (EVar "fromEpochSeconds") (EVar "s"))) (EVar "s")))))
