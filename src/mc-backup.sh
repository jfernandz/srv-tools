#!/usr/bin/env bash
set -euo pipefail

INSTANCE="${1:?usage: mc-backup.sh <instance>}"

if [[ -f /etc/default/mc/common.env ]]; then
  # shellcheck disable=SC1091
  source /etc/default/mc/common.env
fi
if [[ -f "/etc/default/mc/${INSTANCE}.env" ]]; then
  # shellcheck disable=SC1090
  source "/etc/default/mc/${INSTANCE}.env"
fi

SERVICE="mc@${INSTANCE}.service"
SRV_DIR="${MC_SERVER_DIR:?MC_SERVER_DIR is required}"
BACKUP_DIR="${MC_BACKUP_DIR:?MC_BACKUP_DIR is required}"
BACKUP_LEVEL="${MC_BACKUP_LEVEL:-3}"
BACKUP_PREFIX="${MC_BACKUP_PREFIX:-$INSTANCE}"
RETENTION_DAYS="${MC_BACKUP_RETENTION_DAYS:-14}"
STAMP="$(date +%F_%H-%M-%S)"
ARCHIVE="$BACKUP_DIR/${BACKUP_PREFIX}_$STAMP.7z"

mkdir -p "$BACKUP_DIR"

systemctl stop "$SERVICE"

restart_service() {
  systemctl start "$SERVICE"
}
trap restart_service EXIT

for _ in {1..30}; do
  systemctl is-active --quiet "$SERVICE" || break
  sleep 10
done

cd "$SRV_DIR"

EXCLUDES=(
  '-xr!dynmap/web'
  '-xr!dynmap/web/*'
  '-xr!*/dynmap/web'
  '-xr!*/dynmap/web/*'
)

if [[ -n "${MC_BACKUP_EXCLUDES:-}" ]]; then
  for pattern in $MC_BACKUP_EXCLUDES; do
    EXCLUDES+=("-xr!$pattern")
  done
fi

7z a -t7z -mx="$BACKUP_LEVEL" "$ARCHIVE" . "${EXCLUDES[@]}"

find "$BACKUP_DIR" -type f -name "${BACKUP_PREFIX}_*.7z" -mtime +"$RETENTION_DAYS" -delete
