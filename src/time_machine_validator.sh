#!/bin/bash
set -u

MAX_AGE_HOURS=48
OUTPUT_DIR=""
REPAIR=false
DRY_RUN=false
ASSUME_YES=false
START_BACKUP=false

usage() {
  cat <<'EOF'
Usage: time_machine_validator.sh [options]

Options:
  --max-age-hours N   Maximum acceptable backup age (default: 48)
  --output DIR        Report directory
  --repair            Repair safe Time Machine service/configuration issues
  --start-backup      Start an automatic backup during repair
  --dry-run           Show repair actions without changing the Mac
  --yes               Skip the repair confirmation prompt
  -h, --help          Show this help

Exit codes: 0 healthy/success, 10 attention required, 20 repair failed,
            2 invalid arguments, 3 platform/privilege error.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-age-hours) MAX_AGE_HOURS="${2:-48}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --repair) REPAIR=true; shift ;;
    --start-backup) START_BACKUP=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$MAX_AGE_HOURS" in ''|*[!0-9]*) echo "--max-age-hours must be numeric" >&2; exit 2 ;; esac
[ "$(uname -s)" = "Darwin" ] || { echo "This tool must run on macOS." >&2; exit 3; }
if $REPAIR && [ "$(id -u)" -ne 0 ]; then
  echo "Repair mode requires administrator privileges. Run with sudo." >&2
  exit 3
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${OUTPUT_DIR:-./time-machine-validation-$STAMP}"
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/time-machine-report.txt"
CSV="$OUTPUT_DIR/snapshots.csv"
JSON="$OUTPUT_DIR/summary.json"
ERRORS="$OUTPUT_DIR/command-errors.log"
ACTION_LOG="$OUTPUT_DIR/repair-actions.log"
BACKUP_DIR="$OUTPUT_DIR/pre-repair-backup"
: > "$REPORT"; : > "$ERRORS"; : > "$ACTION_LOG"
echo 'snapshot' > "$CSV"

log_action() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$ACTION_LOG"; }
section() {
  title="$1"; shift
  { printf '\n===== %s =====\n' "$title"; "$@"; } >> "$REPORT" 2>> "$ERRORS" || true
}
run_action() {
  description="$1"; shift
  if $DRY_RUN; then
    log_action "DRY-RUN: $description :: $*"
    return 0
  fi
  log_action "RUN: $description :: $*"
  if "$@" >> "$ACTION_LOG" 2>&1; then
    log_action "OK: $description"
    return 0
  fi
  log_action "FAILED: $description"
  return 1
}
confirm_repair() {
  $ASSUME_YES && return 0
  printf 'Apply guarded Time Machine repairs? [y/N] '
  read answer
  case "$answer" in y|Y|yes|YES) return 0 ;; *) echo "Repair cancelled."; exit 10 ;; esac
}

collect() {
  section "Collection metadata" /bin/bash -c 'date -u +%Y-%m-%dT%H:%M:%SZ; hostname; sw_vers; id'
  section "Time Machine destinations" /usr/bin/tmutil destinationinfo
  section "Time Machine status" /usr/bin/tmutil status
  section "Latest backup" /usr/bin/tmutil latestbackup
  section "Automatic backup setting" /usr/bin/tmutil isautomatic
  section "Backup exclusions" /usr/bin/tmutil isexcluded /
  section "APFS snapshots" /usr/bin/tmutil listlocalsnapshots /
  section "Root volume space" /bin/df -h /
  section "Recent Time Machine events" /bin/bash -c '/usr/bin/log show --last 48h --style compact --predicate "process == \"backupd\" OR subsystem CONTAINS[c] \"TimeMachine\"" 2>/dev/null | tail -n 3000'
}

collect
/usr/bin/tmutil listlocalsnapshots / 2>>"$ERRORS" | while IFS= read -r line; do
  [ -n "$line" ] && printf '"%s"\n' "$(printf '%s' "$line" | sed 's/"/""/g')" >> "$CSV"
done

REPAIR_FAILURES=0
if $REPAIR; then
  confirm_repair
  mkdir -p "$BACKUP_DIR"
  if [ -f /Library/Preferences/com.apple.TimeMachine.plist ]; then
    if $DRY_RUN; then
      log_action "DRY-RUN: back up /Library/Preferences/com.apple.TimeMachine.plist"
    else
      cp -p /Library/Preferences/com.apple.TimeMachine.plist "$BACKUP_DIR/" 2>>"$ACTION_LOG" || REPAIR_FAILURES=$((REPAIR_FAILURES + 1))
    fi
  fi
  /usr/bin/tmutil destinationinfo > "$BACKUP_DIR/destinationinfo.txt" 2>/dev/null || true
  /usr/bin/tmutil status > "$BACKUP_DIR/status.txt" 2>/dev/null || true

  AUTO_RAW="$(/usr/bin/tmutil isautomatic 2>/dev/null || true)"
  echo "$AUTO_RAW" | grep -qi '1\|enabled' || run_action "Enable automatic Time Machine backups" /usr/bin/tmutil enable || REPAIR_FAILURES=$((REPAIR_FAILURES + 1))
  run_action "Restart the Time Machine backup service" /bin/launchctl kickstart -k system/com.apple.backupd || REPAIR_FAILURES=$((REPAIR_FAILURES + 1))
  if $START_BACKUP; then
    run_action "Start an automatic Time Machine backup" /usr/bin/tmutil startbackup --auto || REPAIR_FAILURES=$((REPAIR_FAILURES + 1))
  fi

  printf '\n===== Post-repair verification =====\n' >> "$REPORT"
  /usr/bin/tmutil isautomatic >> "$REPORT" 2>> "$ERRORS" || true
  /usr/bin/tmutil destinationinfo >> "$REPORT" 2>> "$ERRORS" || true
  /usr/bin/tmutil status >> "$REPORT" 2>> "$ERRORS" || true
fi

DESTINATIONS="$(/usr/bin/tmutil destinationinfo 2>/dev/null | grep -c '^Name' || true)"
LATEST="$(/usr/bin/tmutil latestbackup 2>/dev/null | tail -n1 || true)"
LATEST_EPOCH=0
if [ -n "$LATEST" ]; then
  backup_stamp=$(basename "$LATEST" | sed 's/\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)-\([0-9]\{6\}\)/\1-\2-\3 \4/')
  LATEST_EPOCH=$(date -j -f '%Y-%m-%d %H%M%S' "$backup_stamp" +%s 2>/dev/null || echo 0)
fi
NOW=$(date +%s)
AGE_HOURS=-1
[ "$LATEST_EPOCH" -gt 0 ] && AGE_HOURS=$(( (NOW - LATEST_EPOCH) / 3600 ))
SNAPSHOTS="$(awk 'END {print NR-1}' "$CSV")"
BACKUP_RUNNING=false
/usr/bin/tmutil status 2>/dev/null | grep -q 'Running = 1' && BACKUP_RUNNING=true
AUTOMATIC_ENABLED=false
/usr/bin/tmutil isautomatic 2>/dev/null | grep -qi '1\|enabled' && AUTOMATIC_ENABLED=true
OVERALL="Healthy"
if [ "$DESTINATIONS" -eq 0 ] || [ "$AGE_HOURS" -lt 0 ] || [ "$AGE_HOURS" -gt "$MAX_AGE_HOURS" ] || ! $AUTOMATIC_ENABLED; then OVERALL="Attention required"; fi
[ "$REPAIR_FAILURES" -gt 0 ] && OVERALL="Repair failed"

safe_latest=$(printf '%s' "$LATEST" | sed 's/\\/\\\\/g; s/"/\\"/g')
cat > "$JSON" <<EOF
{
  "collected_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hostname": "$(hostname)",
  "destinations_detected": $DESTINATIONS,
  "latest_backup": "$safe_latest",
  "latest_backup_age_hours": $AGE_HOURS,
  "maximum_allowed_age_hours": $MAX_AGE_HOURS,
  "local_snapshots": $SNAPSHOTS,
  "backup_running": $BACKUP_RUNNING,
  "automatic_backups_enabled": $AUTOMATIC_ENABLED,
  "repair_requested": $REPAIR,
  "dry_run": $DRY_RUN,
  "repair_failures": $REPAIR_FAILURES,
  "overall_status": "$OVERALL"
}
EOF

printf '\nTime Machine validation completed: %s\n' "$OUTPUT_DIR" | tee -a "$REPORT"
if [ "$REPAIR_FAILURES" -gt 0 ]; then exit 20; fi
[ "$OVERALL" = "Healthy" ] && exit 0
exit 10
