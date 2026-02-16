#!/usr/bin/env bash
set -euo pipefail

INSTANCE="${1:?usage: mc-tmux-stop.sh <instance>}"

if [[ -f /etc/default/mc/common.env ]]; then
  # shellcheck disable=SC1091
  source /etc/default/mc/common.env
fi
if [[ -f "/etc/default/mc/${INSTANCE}.env" ]]; then
  # shellcheck disable=SC1090
  source "/etc/default/mc/${INSTANCE}.env"
fi

MC_TMUX_SESSION="${MC_TMUX_SESSION:-mc-${INSTANCE}}"
MC_STOP_TIMEOUT="${MC_STOP_TIMEOUT:-120}"
MC_STOP_WARN_PLAYERS="${MC_STOP_WARN_PLAYERS:-1}"
MC_STOP_WARN_DELAY="${MC_STOP_WARN_DELAY:-6}"
MC_STOP_WARN_FILE="${MC_STOP_WARN_FILE:-}"

if ! tmux has-session -t "$MC_TMUX_SESSION" 2>/dev/null; then
  exit 0
fi

if [[ "$MC_STOP_WARN_PLAYERS" == "1" ]]; then
  default_warn_commands=(
    'title @a times 10 80 20'
    'title @a subtitle {"text":"Maintenance stop in 60s. ETA: 5-10m.","color":"yellow"}'
    'title @a title {"text":"Server notice","color":"gold","bold":true}'
    'title @a subtitle {"text":"Parada de mantenimiento en 30s. Duración: 5-10 min.","color":"yellow"}'
    'title @a title {"text":"Aviso del servidor","color":"gold","bold":true}'
    'title @a subtitle {"text":"Maintenance stop in 10s. ETA: 5-10m.","color":"red","bold":true}'
    'title @a title {"text":"Server notice","color":"gold","bold":true}'
    'title @a subtitle {"text":"Iniciando parada ahora. Duración: 5-10 min.","color":"red","bold":true}'
    'title @a title {"text":"Aviso del servidor","color":"gold","bold":true}'
    'title @a subtitle {"text":"Iniciando parada de mantenimiento ahora.","color":"red","obfuscated":true}'
    'title @a title {"text":"XXXXXX","color":"dark_purple","obfuscated":true}'
  )

  warn_commands=()
  if [[ -n "$MC_STOP_WARN_FILE" ]]; then
    if [[ -r "$MC_STOP_WARN_FILE" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        warn_commands+=("$line")
      done < "$MC_STOP_WARN_FILE"
    else
      echo "MC_STOP_WARN_FILE is set but not readable: $MC_STOP_WARN_FILE" >&2
    fi
  fi

  if (( ${#warn_commands[@]} == 0 )); then
    warn_commands=("${default_warn_commands[@]}")
  fi

  for cmd in "${warn_commands[@]}"; do
    tmux send-keys -t "$MC_TMUX_SESSION" "$cmd" C-m
    sleep "$MC_STOP_WARN_DELAY"
  done
fi

tmux send-keys -t "$MC_TMUX_SESSION" "stop" C-m

for ((i=0; i<MC_STOP_TIMEOUT; i++)); do
  if ! tmux has-session -t "$MC_TMUX_SESSION" 2>/dev/null; then
    exit 0
  fi
  sleep 1
done

# Last resort to avoid hanging stop forever.
tmux kill-session -t "$MC_TMUX_SESSION"
