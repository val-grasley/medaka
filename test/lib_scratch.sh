# test/lib_scratch.sh — keep the build/test write-storm OUT OF RAM.
#
# ⚠️ /tmp IS A RAM-BACKED tmpfs, SIZED AT 50% OF RAM BY DEFAULT.
#
# On the dev box that is a **16 GB tmpfs on 31 GB of RAM** (the kernel's stock
# tmpfs default, inherited from systemd's tmp.mount — nobody chose it for this
# workload). So every byte of build scratch competes with the compiler for MEMORY,
# and the failure mode is not "disk full", it is "everything is mysteriously slow".
#
# Measured 2026-07-14: two orphaned scratch dirs from a doc-link scan that had
# finished SIX HOURS EARLIER were holding 11 GB — a third of the machine's RAM —
# while several agents fought over a box whose load average sat above 10 with no
# obviously-guilty process. Because the memory wasn't held by a process at all.
#
# `medaka build` and all 42 gate scripts allocate scratch with `mktemp -d`, which
# honours TMPDIR. So one variable moves the whole write-storm onto disk (957 GB,
# vs 16 GB of RAM) at essentially zero cost: the bottleneck on this workload is
# clang CPU, not scratch I/O, and the page cache absorbs the rest.
#
# Override with MEDAKA_SCRATCH=/some/path. Set TMPDIR yourself and we respect it.

if [ -z "${TMPDIR:-}" ] || [ "${TMPDIR%/}" = "/tmp" ]; then
  _mdk_scratch="${MEDAKA_SCRATCH:-/var/tmp/medaka-scratch}"
  if mkdir -p "$_mdk_scratch" 2>/dev/null && [ -w "$_mdk_scratch" ]; then
    TMPDIR="$_mdk_scratch"
    export TMPDIR
  fi
fi

# Loud guard: a tmpfs that is nearly full starves the box of RAM SILENTLY.
# Warn before that becomes someone else's four-hour mystery.
mdk_warn_if_tmp_full() {
  _pct=$(df /tmp 2>/dev/null | awk 'NR==2 { gsub(/%/,"",$5); print $5 }')
  case "$_pct" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ "$_pct" -ge 80 ]; then
    printf '\n⚠️  /tmp is %s%% full — and it is a RAM-BACKED tmpfs, so this is MEMORY pressure,\n' "$_pct" >&2
    printf '    not disk pressure. Leaked scratch here slows the whole box with no guilty process.\n' >&2
    printf '    Check:  du -sh /tmp/* | sort -rh | head\n' >&2
    printf '    Leaked build dirs:  ls -d /tmp/medaka_build_* 2>/dev/null | wc -l\n\n' >&2
  fi
}
