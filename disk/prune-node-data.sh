#!/usr/bin/env bash
#
# prune-node-data.sh — age-based pruner for a Hyperliquid node's output files.
#
#   ./prune-node-data.sh --dry-run             report what would be deleted
#   ./prune-node-data.sh --apply               delete
#   ./prune-node-data.sh --apply --config /etc/hl-node-retention.conf
#
# DRY RUN IS THE DEFAULT. You have to type --apply.
#
# WHY YOU NEED THIS
# -----------------
# Every `--write-*` flag on the node writes a continuous stream of files under
# the data directory, and nothing deletes them. The raw book-diff stream alone is
# multiple GB per hour on mainnet; a full flag set fills a large disk in days. A
# full disk does not degrade the node, it stops it — and stopping a node that is
# behind can cost a full state bootstrap to recover.
#
# We sized one stream's retention from a throughput estimate, the real feed came
# in at roughly double, and the box hit 82% root usage before anyone noticed.
# Measure your own rates with `du -sh` over an hour before choosing numbers.
#
# WHAT IT DOES
# ------------
# For each rule in the config: find files under <data-dir>/<pattern>/ whose mtime
# is older than <hours> and delete them. Age-based deletion by mtime is chosen
# over anything cleverer on purpose — it is trivially auditable, it is idempotent,
# and it cannot mistake "the file currently being written" for "an old file" as
# long as you keep at least one hour of retention.
#
# 🔴 SAFETY: this script only ever deletes FILES, never directories, only under
# the configured data directory, only matching a configured pattern, and never
# inside an excluded directory. It refuses to run if the data directory is not an
# absolute path or does not exist.
#
# Run it from a systemd timer every 10 minutes. See the unit at the bottom of
# this file's --help output, or ../systemd/.

set -euo pipefail

DATA_DIR="${HL_DATA_DIR:-$HOME/hl/data}"
CONFIG="${HL_RETENTION_CONFIG:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/retention.example.conf}"
MODE=dryrun

# Directories that are never touched regardless of what a pattern matches. These
# hold logs and small state files you will want when something goes wrong, and
# they are tiny — there is no reason to prune them and every reason not to.
EXCLUDES=(node_logs visor_child_stderr rate_limited_ips log)

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)    MODE=apply ;;
    --dry-run)  MODE=dryrun ;;
    --config)   shift; CONFIG="${1:?--config needs a path}" ;;
    --data-dir) shift; DATA_DIR="${1:?--data-dir needs a path}" ;;
    -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '[prune] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "FATAL $*"; exit 1; }

# Refuse anything that could turn into a delete at the filesystem root. An unset
# or relative DATA_DIR is the classic way a pruner eats a box.
case "$DATA_DIR" in
  /*) : ;;
  *)  die "data dir must be an absolute path, got '$DATA_DIR'" ;;
esac
[ "$DATA_DIR" != "/" ] || die "refusing to operate on /"
[ -d "$DATA_DIR" ]     || die "data dir does not exist: $DATA_DIR"
[ -r "$CONFIG" ]       || die "config not readable: $CONFIG"

log "data dir : $DATA_DIR"
log "config   : $CONFIG"
log "mode     : $MODE"

# Build the -path exclusions once, as an argv array so paths with spaces survive.
prune_args=()
for ex in "${EXCLUDES[@]}"; do
  prune_args+=(-path "$DATA_DIR/$ex" -prune -o)
done

total_files=0
total_bytes=0

# Config format, one rule per line:   <subdirectory>  <retention-hours>
# '#' starts a comment; blank lines are ignored.
while read -r pattern hours _rest; do
  # Skip comments and blanks. The ${pattern#\#} test catches a '#' in column 1.
  [ -z "${pattern:-}" ] && continue
  [ "${pattern#\#}" != "$pattern" ] && continue

  case "$hours" in
    ''|*[!0-9]*) log "SKIP malformed rule: '$pattern $hours'"; continue ;;
  esac

  target="$DATA_DIR/$pattern"
  if [ ! -d "$target" ]; then
    log "skip $pattern (no such directory)"
    continue
  fi

  # A retention of 0 would mean "delete everything including what is being
  # written right now". Refuse it; the minimum useful value is 1 hour.
  if [ "$hours" -lt 1 ]; then
    log "SKIP $pattern: retention must be >= 1 hour (got $hours)"
    continue
  fi

  # find -mmin takes MINUTES. Using minutes rather than -mtime (whole days)
  # is what makes sub-day retention possible at all.
  minutes=$(( hours * 60 ))

  # -type f: files only, never directories. -mmin +N: strictly older than N
  # minutes. -print0 / read -d '': survive filenames with spaces or newlines.
  count=0
  bytes=0
  while IFS= read -r -d '' f; do
    sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
    count=$(( count + 1 ))
    bytes=$(( bytes + sz ))
    if [ "$MODE" = apply ]; then
      rm -f -- "$f"
    fi
  done < <(find "$target" "${prune_args[@]}" -type f -mmin "+$minutes" -print0 2>/dev/null)

  if [ "$count" -gt 0 ]; then
    log "$(printf '%-28s %-7s %6d files  %8.2f GiB  (older than %sh)' \
      "$pattern" "$([ "$MODE" = apply ] && echo deleted || echo would)" \
      "$count" "$(echo "$bytes" | awk '{printf "%.2f", $1/1073741824}')" "$hours")"
  fi
  total_files=$(( total_files + count ))
  total_bytes=$(( total_bytes + bytes ))
done < "$CONFIG"

log "$(printf 'total: %d files, %.2f GiB' "$total_files" \
      "$(echo "$total_bytes" | awk '{printf "%.2f", $1/1073741824}')")"

# Report disk headroom either way — the number you actually care about.
df -h "$DATA_DIR" | awk 'NR==2 {printf "[prune] filesystem %s: %s used of %s (%s)\n", $6, $3, $2, $5}' >&2

[ "$MODE" = dryrun ] && log "DRY RUN — nothing was deleted (pass --apply)"
exit 0
