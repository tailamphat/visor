#!/bin/bash
# Measures a running Visor: scripts/perf.sh [pid|--debug|--release] [-n secs] [--sample] [--json]
#
#   scripts/perf.sh               # the release build if running, else the debug build
#   scripts/perf.sh --debug -n 30 # .build/debug/Visor for 30 s
#   scripts/perf.sh 1234 --sample # a pid, plus a 3 s `sample` saved to a file
#
# Reads `ps -o %cpu` once a second (default 10 s) and reports avg and max CPU,
# plus the physical footprint (`footprint`, falling back to RSS).
# Read-only: it never launches, quits or kills an app.
set -euo pipefail

TARGET=auto
SECS=10
SAMPLE=0
JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) TARGET=debug ;;
    --release) TARGET=release ;;
    -n) SECS="${2:?-n needs seconds}"; shift ;;
    --sample) SAMPLE=1 ;;
    --json) JSON=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *[!0-9]*) echo "unknown option: $1" >&2; exit 2 ;;
    *) TARGET="$1" ;;
  esac
  shift
done
[[ "$SECS" =~ ^[0-9]+$ && "$SECS" -gt 0 ]] || { echo "perf: -n wants a whole number of seconds" >&2; exit 2; }

# Finds a Visor process whose executable path matches a pattern.
find_pid() {
  local pid path
  for pid in $(pgrep -x Visor 2>/dev/null); do
    path="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    if [[ "$path" == $1 ]]; then echo "$pid"; return 0; fi
  done
  return 1
}

case "$TARGET" in
  release) PID="$(find_pid '*.app/Contents/MacOS/Visor')" || { echo "perf: no release Visor running" >&2; exit 1; } ;;
  debug) PID="$(find_pid '*/debug/Visor')" || { echo "perf: no debug Visor running" >&2; exit 1; } ;;
  auto) PID="$(find_pid '*.app/Contents/MacOS/Visor' || find_pid '*/debug/Visor')" || { echo "perf: no Visor running" >&2; exit 1; } ;;
  *) PID="$TARGET" ;;
esac
ps -p "$PID" >/dev/null 2>&1 || { echo "perf: pid $PID is not running" >&2; exit 1; }
EXE="$(ps -o comm= -p "$PID")"

# CPU, one reading a second.
READINGS=()
for ((i = 0; i < SECS; i++)); do
  cpu="$(ps -o %cpu= -p "$PID" 2>/dev/null | tr -d ' ')" || { echo "perf: pid $PID exited" >&2; exit 1; }
  READINGS+=("$cpu")
  [[ $i -lt $((SECS - 1)) ]] && sleep 1
done
STATS="$(printf '%s\n' "${READINGS[@]}" | awk '{ s += $1; if ($1 > m) m = $1 } END { printf "%.1f %.1f", s / NR, m }')"
AVG="${STATS% *}"
MAX="${STATS#* }"

# Memory: physical footprint, else RSS.
MEM_SOURCE=footprint
MEM_MB="$(footprint "$PID" 2>/dev/null | awk '/Footprint:/ {
  for (i = 1; i <= NF; i++) if ($i == "Footprint:") { v = $(i + 1); u = $(i + 2) }
  if (u == "KB") v /= 1024; else if (u == "GB") v *= 1024; else if (u == "B") v /= 1048576
  printf "%.0f", v; exit }')" || true
if [[ -z "$MEM_MB" ]]; then
  MEM_SOURCE=rss
  MEM_MB="$(ps -o rss= -p "$PID" | awk '{ printf "%.0f", $1 / 1024 }')"
fi

SAMPLE_FILE=""
if [[ $SAMPLE == 1 ]]; then
  SAMPLE_FILE="${TMPDIR:-/tmp}/visor-sample-$PID-$(date +%Y%m%d-%H%M%S).txt"
  sample "$PID" 3 -file "$SAMPLE_FILE" >/dev/null 2>&1 || { echo "perf: sample failed" >&2; SAMPLE_FILE=""; }
fi

if [[ $JSON == 1 ]]; then
  printf '{"pid":%s,"exe":"%s","seconds":%s,"cpu_avg":%s,"cpu_max":%s,"memory_mb":%s,"memory_source":"%s","readings":[%s],"sample_file":%s}\n' \
    "$PID" "$EXE" "$SECS" "$AVG" "$MAX" "$MEM_MB" "$MEM_SOURCE" \
    "$(IFS=,; echo "${READINGS[*]}")" \
    "$([[ -n "$SAMPLE_FILE" ]] && echo "\"$SAMPLE_FILE\"" || echo null)"
else
  echo "Visor pid $PID ($EXE)"
  echo "cpu: avg ${AVG}% max ${MAX}% over ${SECS} s"
  echo "memory: ${MEM_MB} MB ($MEM_SOURCE)"
  [[ -n "$SAMPLE_FILE" ]] && echo "sample: $SAMPLE_FILE"
fi
exit 0
