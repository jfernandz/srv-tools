#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOT'
usage: backup-fetcher.sh [options]

Retrieve backups from a remote host over SSH using rsync.

Options:
  --user <name>             Remote SSH user (required)
  --host <hostname>         Remote SSH host (required)
  --source <path>           Remote source directory/file (required)
  --destination <path>      Local destination directory (required)
  --port <port>             SSH port (default: 22)
  --identity-file <path>    SSH private key file
  --delete                  Delete local files not present on remote source
  --dry-run                 Show what would change without copying data
  --max-retention-days <n>  Delete destination files older than <n> days after fetch
  --install                 Generate a systemd service unit and exit
  --install-timer           Generate a systemd timer unit (implies --install)
  --on-calendar <expr>      OnCalendar value for generated timer
  --unit-name <name>        Base unit name without suffix (default: backup-fetcher)
  --systemd-dir <path>      Unit output directory (default: /etc/systemd/system)
  --exec-path <path>        ExecStart path in generated service (default: /usr/local/bin/backup-fetcher.sh)
  --service-env-file <path> EnvironmentFile path in generated service
                            (template is created during --install if missing)
  -h, --help                Show this help

Environment variables:
  FETCH_USER
  FETCH_HOST
  FETCH_SOURCE
  FETCH_DESTINATION
  FETCH_PORT
  FETCH_IDENTITY_FILE
  FETCH_DELETE
  FETCH_DRY_RUN
  FETCH_MAX_RETENTION_DAYS

Precedence: CLI options override environment variables.

Examples:
  backup-fetcher.sh \
    --user backup \
    --host backup.example.com \
    --source /srv/backups/ \
    --destination /srv/restore/backups

  backup-fetcher.sh \
    --user backup \
    --host 192.168.1.20 \
    --source /srv/backups/httpd/ \
    --destination /tmp/httpd-backups \
    --port 2222 \
    --identity-file ~/.ssh/id_ed25519 \
    --dry-run

  FETCH_USER=backup \
  FETCH_HOST=backup.example.com \
  FETCH_SOURCE=/srv/backups/ \
  FETCH_DESTINATION=/srv/restore/backups \
  backup-fetcher.sh

  backup-fetcher.sh \
    --user backup \
    --host backup.example.com \
    --source /srv/backups/ \
    --destination /srv/restore/backups \
    --max-retention-days 30

  backup-fetcher.sh --install

  backup-fetcher.sh --install-timer --on-calendar "*-*-* 01:30:00"
EOT
}

normalize_bool() {
  local value="${1:-}"
  local fallback="${2:-false}"
  local normalized="${value,,}"

  if [[ -z "$normalized" ]]; then
    printf '%s\n' "$fallback"
    return
  fi

  case "$normalized" in
    1|true|yes|on)
      printf 'true\n'
      ;;
    0|false|no|off)
      printf 'false\n'
      ;;
    *)
      echo "invalid boolean value: $value" >&2
      exit 1
      ;;
  esac
}

normalize_unit_name() {
  local value="$1"

  if [[ "$value" == *.service ]]; then
    value="${value%.service}"
  fi

  if [[ "$value" == *.timer ]]; then
    value="${value%.timer}"
  fi

  if [[ -z "$value" ]]; then
    echo "unit name cannot be empty" >&2
    exit 1
  fi

  if [[ "$value" == *"/"* || "$value" == *" "* ]]; then
    echo "unit name must not contain '/' or spaces: $value" >&2
    exit 1
  fi

  printf '%s\n' "$value"
}

write_service_unit() {
  local service_path="$1"
  local env_file="$2"
  local exec_path="$3"

  cat > "$service_path" <<EOT
[Unit]
Description=Fetch backups from remote host
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-${env_file}
ExecStart=${exec_path}

[Install]
WantedBy=multi-user.target
EOT
}

write_timer_unit() {
  local timer_path="$1"
  local unit_name="$2"
  local on_calendar="$3"

  cat > "$timer_path" <<EOT
[Unit]
Description=Scheduled backup fetch job

[Timer]
OnCalendar=${on_calendar}
Persistent=true
Unit=${unit_name}.service

[Install]
WantedBy=timers.target
EOT
}

write_env_template() {
  local env_path="$1"

  cat > "$env_path" <<'EOT'
# backup-fetcher environment file
# Required:
FETCH_USER=
FETCH_HOST=
FETCH_SOURCE=
FETCH_DESTINATION=

# Optional:
FETCH_PORT=22
# FETCH_IDENTITY_FILE=/root/.ssh/id_ed25519
FETCH_DELETE=false
FETCH_DRY_RUN=false
# FETCH_MAX_RETENTION_DAYS=30
EOT
}

CLI_REMOTE_USER=""
CLI_REMOTE_HOST=""
CLI_SOURCE_PATH=""
CLI_DESTINATION_PATH=""
CLI_SSH_PORT=""
CLI_IDENTITY_FILE=""
CLI_USE_DELETE=false
CLI_USE_DELETE_SET=false
CLI_DRY_RUN=false
CLI_DRY_RUN_SET=false
CLI_MAX_RETENTION_DAYS=""
INSTALL_SERVICE=false
INSTALL_TIMER=false
ON_CALENDAR=""
UNIT_NAME="backup-fetcher"
SYSTEMD_DIR="/etc/systemd/system"
EXEC_PATH="/usr/local/bin/backup-fetcher.sh"
SERVICE_ENV_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      CLI_REMOTE_USER="${2:-}"
      shift 2
      ;;
    --host)
      CLI_REMOTE_HOST="${2:-}"
      shift 2
      ;;
    --source)
      CLI_SOURCE_PATH="${2:-}"
      shift 2
      ;;
    --destination)
      CLI_DESTINATION_PATH="${2:-}"
      shift 2
      ;;
    --port)
      CLI_SSH_PORT="${2:-}"
      shift 2
      ;;
    --identity-file)
      CLI_IDENTITY_FILE="${2:-}"
      shift 2
      ;;
    --delete)
      CLI_USE_DELETE=true
      CLI_USE_DELETE_SET=true
      shift
      ;;
    --dry-run)
      CLI_DRY_RUN=true
      CLI_DRY_RUN_SET=true
      shift
      ;;
    --max-retention-days)
      CLI_MAX_RETENTION_DAYS="${2:-}"
      shift 2
      ;;
    --install)
      INSTALL_SERVICE=true
      shift
      ;;
    --install-timer)
      INSTALL_TIMER=true
      shift
      ;;
    --on-calendar)
      ON_CALENDAR="${2:-}"
      shift 2
      ;;
    --unit-name)
      UNIT_NAME="${2:-}"
      shift 2
      ;;
    --systemd-dir)
      SYSTEMD_DIR="${2:-}"
      shift 2
      ;;
    --exec-path)
      EXEC_PATH="${2:-}"
      shift 2
      ;;
    --service-env-file)
      SERVICE_ENV_FILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

UNIT_NAME="$(normalize_unit_name "$UNIT_NAME")"
if [[ -z "$SERVICE_ENV_FILE" ]]; then
  SERVICE_ENV_FILE="/etc/backup-tools/${UNIT_NAME}.env"
fi

if [[ "$INSTALL_TIMER" == "true" ]]; then
  INSTALL_SERVICE=true
fi

if [[ "$INSTALL_TIMER" == "true" && -z "$ON_CALENDAR" ]]; then
  echo "--on-calendar is required with --install-timer" >&2
  exit 1
fi

if [[ "$INSTALL_SERVICE" == "true" ]]; then
  mkdir -p "$SYSTEMD_DIR"
  env_dir="$(dirname "$SERVICE_ENV_FILE")"
  mkdir -p "$env_dir"

  service_path="${SYSTEMD_DIR}/${UNIT_NAME}.service"
  write_service_unit "$service_path" "$SERVICE_ENV_FILE" "$EXEC_PATH"
  echo "generated service unit: $service_path"

  if [[ -f "$SERVICE_ENV_FILE" ]]; then
    echo "env template already exists: $SERVICE_ENV_FILE"
  else
    write_env_template "$SERVICE_ENV_FILE"
    echo "generated env template: $SERVICE_ENV_FILE"
  fi

  if [[ "$INSTALL_TIMER" == "true" ]]; then
    timer_path="${SYSTEMD_DIR}/${UNIT_NAME}.timer"
    write_timer_unit "$timer_path" "$UNIT_NAME" "$ON_CALENDAR"
    echo "generated timer unit: $timer_path"
  fi

  echo "next: systemctl daemon-reload"
  if [[ "$INSTALL_TIMER" == "true" ]]; then
    echo "next: systemctl enable --now ${UNIT_NAME}.timer"
  else
    echo "next: systemctl enable --now ${UNIT_NAME}.service"
  fi
  exit 0
fi

REMOTE_USER="${FETCH_USER:-}"
REMOTE_HOST="${FETCH_HOST:-}"
SOURCE_PATH="${FETCH_SOURCE:-}"
DESTINATION_PATH="${FETCH_DESTINATION:-}"
SSH_PORT="${FETCH_PORT:-22}"
IDENTITY_FILE="${FETCH_IDENTITY_FILE:-}"
USE_DELETE="$(normalize_bool "${FETCH_DELETE:-}" "false")"
DRY_RUN="$(normalize_bool "${FETCH_DRY_RUN:-}" "false")"
MAX_RETENTION_DAYS="${FETCH_MAX_RETENTION_DAYS:-}"

if [[ -n "$CLI_REMOTE_USER" ]]; then
  REMOTE_USER="$CLI_REMOTE_USER"
fi

if [[ -n "$CLI_REMOTE_HOST" ]]; then
  REMOTE_HOST="$CLI_REMOTE_HOST"
fi

if [[ -n "$CLI_SOURCE_PATH" ]]; then
  SOURCE_PATH="$CLI_SOURCE_PATH"
fi

if [[ -n "$CLI_DESTINATION_PATH" ]]; then
  DESTINATION_PATH="$CLI_DESTINATION_PATH"
fi

if [[ -n "$CLI_SSH_PORT" ]]; then
  SSH_PORT="$CLI_SSH_PORT"
fi

if [[ -n "$CLI_IDENTITY_FILE" ]]; then
  IDENTITY_FILE="$CLI_IDENTITY_FILE"
fi

if [[ "$CLI_USE_DELETE_SET" == "true" ]]; then
  USE_DELETE="$CLI_USE_DELETE"
fi

if [[ "$CLI_DRY_RUN_SET" == "true" ]]; then
  DRY_RUN="$CLI_DRY_RUN"
fi

if [[ -n "$CLI_MAX_RETENTION_DAYS" ]]; then
  MAX_RETENTION_DAYS="$CLI_MAX_RETENTION_DAYS"
fi

if [[ -z "$REMOTE_USER" ]]; then
  echo "--user is required (or set FETCH_USER)" >&2
  exit 1
fi

if [[ -z "$REMOTE_HOST" ]]; then
  echo "--host is required (or set FETCH_HOST)" >&2
  exit 1
fi

if [[ -z "$SOURCE_PATH" ]]; then
  echo "--source is required (or set FETCH_SOURCE)" >&2
  exit 1
fi

if [[ -z "$DESTINATION_PATH" ]]; then
  echo "--destination is required (or set FETCH_DESTINATION)" >&2
  exit 1
fi

if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]]; then
  echo "--port must be numeric" >&2
  exit 1
fi

if [[ -n "$MAX_RETENTION_DAYS" && ! "$MAX_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
  echo "--max-retention-days must be numeric" >&2
  exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
  echo "rsync is required" >&2
  exit 1
fi

if ! command -v ssh >/dev/null 2>&1; then
  echo "ssh is required" >&2
  exit 1
fi

if [[ -n "$IDENTITY_FILE" && ! -f "$IDENTITY_FILE" ]]; then
  echo "identity file not found: $IDENTITY_FILE" >&2
  exit 1
fi

mkdir -p "$DESTINATION_PATH"

ssh_cmd=(ssh -p "$SSH_PORT")
if [[ -n "$IDENTITY_FILE" ]]; then
  ssh_cmd+=(-i "$IDENTITY_FILE")
fi

rsync_args=(
  -az
  --partial
  --info=progress2
  --rsh "${ssh_cmd[*]}"
)

if [[ "$USE_DELETE" == "true" ]]; then
  rsync_args+=(--delete)
fi

if [[ "$DRY_RUN" == "true" ]]; then
  rsync_args+=(--dry-run)
fi

remote_spec="${REMOTE_USER}@${REMOTE_HOST}:${SOURCE_PATH}"

rsync "${rsync_args[@]}" "$remote_spec" "$DESTINATION_PATH/"

if [[ -n "$MAX_RETENTION_DAYS" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "skipping retention prune because --dry-run is enabled"
  else
    find "$DESTINATION_PATH" -type f -mtime +"$MAX_RETENTION_DAYS" -delete
  fi
fi
