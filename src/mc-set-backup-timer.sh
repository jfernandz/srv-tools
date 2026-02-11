#!/usr/bin/env bash
set -euo pipefail

INSTANCE="${1:?usage: mc-set-backup-timer.sh <instance>}"

if [[ -f /etc/default/mc/common.env ]]; then
  # shellcheck disable=SC1091
  source /etc/default/mc/common.env
fi
if [[ -f "/etc/default/mc/${INSTANCE}.env" ]]; then
  # shellcheck disable=SC1090
  source "/etc/default/mc/${INSTANCE}.env"
fi

ON_CALENDAR="${MC_BACKUP_ON_CALENDAR:-*-*-* 11:30:00}"
RANDOMIZED_DELAY_SEC="${MC_BACKUP_RANDOMIZED_DELAY_SEC:-15m}"
PERSISTENT="${MC_BACKUP_PERSISTENT:-true}"
TIMER_NAME="mc-backup@${INSTANCE}.timer"
TIMER_PATH="/etc/systemd/system/${TIMER_NAME}"

cat > "$TIMER_PATH" <<EOC
[Unit]
Description=Scheduled MC backup (${INSTANCE})

[Timer]
OnCalendar=${ON_CALENDAR}
Persistent=${PERSISTENT}
RandomizedDelaySec=${RANDOMIZED_DELAY_SEC}
Unit=mc-backup@${INSTANCE}.service

[Install]
WantedBy=timers.target
EOC

systemctl daemon-reload
systemctl enable --now "$TIMER_NAME"
systemctl status "$TIMER_NAME" --no-pager -n 0
