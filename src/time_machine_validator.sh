#!/bin/bash
set -u

MAX_AGE_HOURS=48
OUTPUT_DIR=""

usage() {
  echo "Usage: time_machine_validator.sh [--max-age-hours N] [--output DIR]"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-age-hours) MAX_AGE_HOURS="${2:-48}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$MAX_AGE_HOURS" in ''|*[!0-9]*) echo "--max-age-hours must be numeric" >&2; exit 2 ;; esac
[ "$(uname -s)" = "Darwin" ] || { echo "This tool must run on macOS." >&2; exit 1; }

STAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${OUTPUT_DIR:-./time-machine-validation-$STAMP}"
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/time-machine-report.txt"
CSV="$OUTPUT_DIR/snapshots.csv"
JSON="$OUTPUT_DIR/summary.json"
ERRORS="$OUTPUT_DIR/command-errors.log"
: > "$REPORT"; : > "$ERRORS"
echo 'snapshot' > "$CSV"

section() {
  title="$1"; shift
  { printf '\n===== %s =====\n' "$title"; "$@"; } >> "$REPORT" 2>> "$ERRORS" || true
}

section "Collection metadata" /bin/bash -c 'date -u +%Y-%m-%dT%H:%M:%SZ; hostname; sw_vers; id'
section "Time Machine destinations" /usr/bin/tmutil destinationinfo
section "Time Machine status" /usr/bin/tmutil status
section "Latest backup" /usr/bin/tmutil latestbackup
section "Backup exclusions" /usr/bin/tmutil isexcluded /
section "APFS snapshots" /usr/bin/tmutil listlocalsnapshots /
section "Root volume space" /bin/df -h /
section "Recent Time Machine events" /bin/bash -c '/usr/bin/log show --last 48h --style compact --predicate "process == \"backupd\" OR subsystem CONTAINS[c] \"TimeMachine\"" 2>/dev/null | tail -n 3000'

/usr/bin/tmutil listlocalsnapshots / 2>>"$ERRORS" | while IFS= read -r line; do
  [ -n "$line" ] && printf '"%s"\n' "$(printf '%s' "$line" | sed 's/"/""/g')" >> "$CSV"
done

DESTINATIONS="$(/usr/bin/tmutil destinationinfo 2>/dev/null | grep -c '^Name' || true)"
LATEST="$(/usr/bin/tmutil latestbackup 2>/dev/null | tail -n1 || true)"
LATEST_EPOCH=0
if [ -n "$LATEST" ]; then
  stamp=$(basename "$LATEST" | sed 's/\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)-\([0-9]\{6\}\)/\1-\2-\3 \4/')
  LATEST_EPOCH=$(date -j -f '%Y-%m-%d %H%M%S' "$stamp" +%s 2>/dev/null || echo 0)
fi
NOW=$(date +%s)
AGE_HOURS=-1
[ "$LATEST_EPOCH" -gt 0 ] && AGE_HOURS=$(( (NOW - LATEST_EPOCH) / 3600 ))
SNAPSHOTS="$(awk 'END {print NR-1}' "$CSV")"
BACKUP_RUNNING=false
/usr/bin/tmutil status 2>/dev/null | grep -q 'Running = 1' && BACKUP_RUNNING=true
OVERALL="Healthy"
if [ "$DESTINATIONS" -eq 0 ] || [ "$AGE_HOURS" -lt 0 ] || [ "$AGE_HOURS" -gt "$MAX_AGE_HOURS" ]; then OVERALL="Attention required"; fi

cat > "$JSON" <<EOF
{
  "collected_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hostname": "$(hostname)",
  "destinations_detected": $DESTINATIONS,
  "latest_backup": "${LATEST//"/\\"}",
  "latest_backup_age_hours": $AGE_HOURS,
  "maximum_allowed_age_hours": $MAX_AGE_HOURS,
  "local_snapshots": $SNAPSHOTS,
  "backup_running": $BACKUP_RUNNING,
  "overall_status": "$OVERALL"
}
EOF

printf '\nTime Machine validation completed: %s\n' "$OUTPUT_DIR" | tee -a "$REPORT"
