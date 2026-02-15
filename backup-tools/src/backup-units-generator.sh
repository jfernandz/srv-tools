#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOT'
usage: backup-units-generator.sh [options]

Options:
  --config <path>              Config file path (default: /etc/backup-tools/config.yaml)
  --units-dir <dir>            Output directory for .service/.timer units (default: /etc/systemd/system)
  --service-config-dir <dir>   Output directory for per-service backup config fragments (default: /etc/backup-tools)
  --backup-script <path>       Backup runner used in ExecStart (default: /usr/bin/backup.sh)
EOT
}

CONFIG_PATH="/etc/backup-tools/config.yaml"
UNITS_DIR="/etc/systemd/system"
SERVICE_CONFIG_DIR="/etc/backup-tools"
BACKUP_SCRIPT="/usr/bin/backup.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --units-dir)
      UNITS_DIR="${2:-}"
      shift 2
      ;;
    --service-config-dir)
      SERVICE_CONFIG_DIR="${2:-}"
      shift 2
      ;;
    --backup-script)
      BACKUP_SCRIPT="${2:-}"
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

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "config not found: $CONFIG_PATH" >&2
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required (https://github.com/mikefarah/yq)" >&2
  exit 1
fi

mkdir -p "$UNITS_DIR" "$SERVICE_CONFIG_DIR"

to_service_unit_name() {
  local name="$1"
  printf '%s.service\n' "$name"
}

is_truthy() {
  local value="${1,,}"
  [[ "$value" == "1" || "$value" == "true" || "$value" == "yes" || "$value" == "on" ]]
}

normalize_bool() {
  local value="${1:-}"
  local fallback="${2:-true}"
  if [[ -z "$value" ]]; then
    printf '%s\n' "$fallback"
    return
  fi
  if is_truthy "$value"; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

write_bash_array() {
  local var_name="$1"
  shift
  printf '%s=(\n' "$var_name"
  local item
  for item in "$@"; do
    printf '  %q\n' "$item"
  done
  printf ')\n'
}

service_exists() {
  local service_unit="$1"
  local load_state
  load_state="$(systemctl show --property=LoadState --value "$service_unit" 2>/dev/null || true)"
  [[ -n "$load_state" && "$load_state" != "not-found" ]]
}

declare -A SERVICES=()

while IFS= read -r service; do
  [[ -n "$service" ]] && SERVICES["$service"]=1
done < <(yq -r '(.services // {} | keys[])' "$CONFIG_PATH")

declare -a GENERATED_REPORT=()

for raw_service in "${!SERVICES[@]}"; do
  if [[ "$raw_service" == *"/"* || "$raw_service" == *" "* ]]; then
    echo "$raw_service: invalid service key (must not contain '/' or spaces)" >&2
    exit 1
  fi

  if [[ "$raw_service" == *.service ]]; then
    echo "$raw_service: service keys under services: must not include .service suffix" >&2
    exit 1
  fi

  service_unit="$(to_service_unit_name "$raw_service")"
  backup_unit_name="backup-${raw_service}"

  if ! service_exists "$service_unit"; then
    echo "$raw_service: service unit not found ($service_unit), skipping" >&2
    continue
  fi

  mapfile -t backup_dirs < <(yq -r --arg s "$raw_service" \
    '. as $root | (($root.services[$s] // {}) | .dirs // $root.defaults.dirs // $root.dirs // [])[]?' \
    "$CONFIG_PATH")
  if [[ "${#backup_dirs[@]}" -eq 0 ]]; then
    echo "$raw_service: dirs must include at least one directory" >&2
    exit 1
  fi

  mapfile -t excludes < <(yq -r --arg s "$raw_service" \
    '. as $root | (($root.services[$s] // {}) | .exclude_patterns // [])[]?' \
    "$CONFIG_PATH")

  backup_dir="$(yq -r --arg s "$raw_service" \
    '. as $root | (($root.services[$s] // {}) | .output_dir // $root.defaults.output_dir // $root.output_dir // "")' \
    "$CONFIG_PATH")"
  if [[ -z "$backup_dir" ]]; then
    echo "$raw_service: output_dir is required" >&2
    exit 1
  fi

  backup_level="$(yq -r --arg s "$raw_service" \
    '. as $root | (($root.services[$s] // {}) | .compression_lvl // $root.defaults.compression_lvl // $root.compression_lvl // 3)' \
    "$CONFIG_PATH")"
  retention_days="$(yq -r --arg s "$raw_service" \
    '. as $root | (($root.services[$s] // {}) | .retention_days // $root.defaults.retention_days // $root.retention_days // 14)' \
    "$CONFIG_PATH")"
  on_calendar="$(yq -r --arg s "$raw_service" \
    '. as $root | (($root.services[$s] // {}) | .on_calendar // $root.defaults.on_calendar // $root.on_calendar // "*-*-* 11:30:00")' \
    "$CONFIG_PATH")"
  randomized_delay="$(yq -r --arg s "$raw_service" \
    '. as $root | (($root.services[$s] // {}) | .randomized_delay // $root.defaults.randomized_delay // $root.randomized_delay // "15m")' \
    "$CONFIG_PATH")"
  persistent_raw="$(yq -r --arg s "$raw_service" \
    '. as $root | (($root.services[$s] // {}) | .persistent // $root.defaults.persistent // $root.persistent // true)' \
    "$CONFIG_PATH")"
  stop_wait_seconds="$(yq -r --arg s "$raw_service" \
    '. as $root | (($root.services[$s] // {}) | .stop_wait_seconds // $root.defaults.stop_wait_seconds // $root.stop_wait_seconds // 300)' \
    "$CONFIG_PATH")"
  restart_after_backup_raw="$(yq -r --arg s "$raw_service" \
    '. as $root | (($root.services[$s] // {}) | .restart_after_backup // $root.defaults.restart_after_backup // $root.restart_after_backup // true)' \
    "$CONFIG_PATH")"

  persistent="$(normalize_bool "$persistent_raw" "true")"
  restart_after_backup="$(normalize_bool "$restart_after_backup_raw" "true")"

  config_path="$SERVICE_CONFIG_DIR/${raw_service}.conf"
  service_unit_path="$UNITS_DIR/${backup_unit_name}.service"
  timer_unit_path="$UNITS_DIR/${backup_unit_name}.timer"

  {
    echo "# Generated by backup-units-generator.sh"
    printf 'SERVICE_NAME=%q\n' "$service_unit"
    printf 'BACKUP_DIR=%q\n' "$backup_dir"
    printf 'BACKUP_LEVEL=%q\n' "$backup_level"
    printf 'BACKUP_RETENTION_DAYS=%q\n' "$retention_days"
    printf 'BACKUP_PREFIX=%q\n' "$raw_service"
    printf 'STOP_WAIT_SECONDS=%q\n' "$stop_wait_seconds"
    printf 'RESTART_AFTER_BACKUP=%q\n' "$restart_after_backup"
    write_bash_array "BACKUP_DIRS" "${backup_dirs[@]}"
    write_bash_array "EXCLUDE_PATTERNS" "${excludes[@]}"
  } > "$config_path"

  exec_line="$(printf 'ExecStart=%q %q' "$BACKUP_SCRIPT" "$config_path")"

  cat > "$service_unit_path" <<EOT
[Unit]
Description=Stop ${service_unit}, backup data, and restart

[Service]
Type=oneshot
${exec_line}
EOT

  cat > "$timer_unit_path" <<EOT
[Unit]
Description=Scheduled backup for ${service_unit}

[Timer]
OnCalendar=${on_calendar}
Persistent=${persistent}
RandomizedDelaySec=${randomized_delay}
Unit=${backup_unit_name}.service

[Install]
WantedBy=timers.target
EOT

  GENERATED_REPORT+=("$service_unit|$config_path|$service_unit_path|$timer_unit_path|$backup_unit_name")
done

paths_block_exists="$(yq -r 'has("paths")' "$CONFIG_PATH")"
if [[ "$paths_block_exists" == "true" ]]; then
  mapfile -t paths_backup_dirs < <(yq -r \
    '(.paths | select(type == "!!seq" or type == "array") | .[]?), (.paths | select(type == "!!map" or type == "object") | .dirs // [] | .[]?)' \
    "$CONFIG_PATH")
  if [[ "${#paths_backup_dirs[@]}" -eq 0 ]]; then
    echo "paths: dirs must include at least one directory (or define paths as a non-empty list)" >&2
    exit 1
  fi

  mapfile -t paths_excludes < <(yq -r \
    '(.paths | select(type == "!!map" or type == "object") | .exclude_patterns // [] | .[]?)' \
    "$CONFIG_PATH")

  paths_backup_dir="$(yq -r \
    '. as $root | (($root.paths | select(type == "!!map" or type == "object") | .output_dir) // $root.defaults.output_dir // $root.output_dir // "")' \
    "$CONFIG_PATH")"
  if [[ -z "$paths_backup_dir" ]]; then
    echo "paths: output_dir is required (or provide global output_dir)" >&2
    exit 1
  fi

  paths_backup_level="$(yq -r \
    '. as $root | (($root.paths | select(type == "!!map" or type == "object") | .compression_lvl) // $root.defaults.compression_lvl // $root.compression_lvl // 3)' \
    "$CONFIG_PATH")"
  paths_retention_days="$(yq -r \
    '. as $root | (($root.paths | select(type == "!!map" or type == "object") | .retention_days) // $root.defaults.retention_days // $root.retention_days // 14)' \
    "$CONFIG_PATH")"
  paths_on_calendar="$(yq -r \
    '. as $root | (($root.paths | select(type == "!!map" or type == "object") | .on_calendar) // $root.defaults.on_calendar // $root.on_calendar // "*-*-* 11:30:00")' \
    "$CONFIG_PATH")"
  paths_randomized_delay="$(yq -r \
    '. as $root | (($root.paths | select(type == "!!map" or type == "object") | .randomized_delay) // $root.defaults.randomized_delay // $root.randomized_delay // "15m")' \
    "$CONFIG_PATH")"
  paths_persistent_raw="$(yq -r \
    '. as $root | (($root.paths | select(type == "!!map" or type == "object") | .persistent) // $root.defaults.persistent // $root.persistent // true)' \
    "$CONFIG_PATH")"
  paths_stop_wait_seconds="$(yq -r \
    '. as $root | (($root.paths | select(type == "!!map" or type == "object") | .stop_wait_seconds) // $root.defaults.stop_wait_seconds // $root.stop_wait_seconds // 300)' \
    "$CONFIG_PATH")"

  paths_persistent="$(normalize_bool "$paths_persistent_raw" "true")"

  paths_config_path="$SERVICE_CONFIG_DIR/paths.conf"
  paths_service_unit_path="$UNITS_DIR/backup-paths.service"
  paths_timer_unit_path="$UNITS_DIR/backup-paths.timer"

  {
    echo "# Generated by backup-units-generator.sh"
    printf 'BACKUP_DIR=%q\n' "$paths_backup_dir"
    printf 'BACKUP_LEVEL=%q\n' "$paths_backup_level"
    printf 'BACKUP_RETENTION_DAYS=%q\n' "$paths_retention_days"
    printf 'BACKUP_PREFIX=%q\n' "paths"
    printf 'STOP_WAIT_SECONDS=%q\n' "$paths_stop_wait_seconds"
    printf 'RESTART_AFTER_BACKUP=%q\n' "false"
    write_bash_array "BACKUP_DIRS" "${paths_backup_dirs[@]}"
    write_bash_array "EXCLUDE_PATTERNS" "${paths_excludes[@]}"
  } > "$paths_config_path"

  paths_exec_line="$(printf 'ExecStart=%q %q' "$BACKUP_SCRIPT" "$paths_config_path")"

  cat > "$paths_service_unit_path" <<EOT
[Unit]
Description=Backup configured paths

[Service]
Type=oneshot
${paths_exec_line}
EOT

  cat > "$paths_timer_unit_path" <<EOT
[Unit]
Description=Scheduled backup for configured paths

[Timer]
OnCalendar=${paths_on_calendar}
Persistent=${paths_persistent}
RandomizedDelaySec=${paths_randomized_delay}
Unit=backup-paths.service

[Install]
WantedBy=timers.target
EOT

  GENERATED_REPORT+=("paths|$paths_config_path|$paths_service_unit_path|$paths_timer_unit_path|backup-paths")
fi

if [[ "${#GENERATED_REPORT[@]}" -eq 0 ]]; then
  echo "no backup artifacts generated; no valid services found and no usable paths block" >&2
  exit 1
fi

echo "Generated backup artifacts:"
for row in "${GENERATED_REPORT[@]}"; do
  IFS='|' read -r service cfg svc timer backup_unit_name <<<"$row"
  echo "- $service"
  echo "  name:   $backup_unit_name"
  echo "  config: $cfg"
  echo "  unit:   $svc"
  echo "  timer:  $timer"
done

echo
echo "Next steps:"
echo "  systemctl daemon-reload"
echo "  systemctl enable --now backup-<service>.timer"
