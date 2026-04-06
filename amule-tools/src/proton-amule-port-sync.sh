#!/usr/bin/env bash
set -u
set -o pipefail

# ProtonVPN NAT-PMP gateway inside the tunnel
GATEWAY="${GATEWAY:-10.2.0.1}"

# NAT-PMP lease duration and refresh interval
LIFETIME="${LIFETIME:-60}"
SLEEP_SECS="${SLEEP_SECS:-45}"

# aMule settings
AMULE_USER="${AMULE_USER:-pi}"
AMULE_CONF="${AMULE_CONF:-/home/pi/.aMule/amule.conf}"
AMULE_SERVICE="${AMULE_SERVICE:-amule-daemon.service}"

# Optional VPN interface check, for example tun0 or wg0
VPN_IFACE="${VPN_IFACE:-}"

# Runtime state
STATE_DIR="${STATE_DIR:-/run/proton-amule-port-sync}"
PORT_FILE="${PORT_FILE:-$STATE_DIR/current_port}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        log "Missing required command: $1"
        exit 1
    }
}

check_prereqs() {
    require_cmd natpmpc
    require_cmd awk
    require_cmd sed
    require_cmd grep
    require_cmd ip
    require_cmd systemctl
    require_cmd pgrep
    require_cmd pkill
    require_cmd install
    require_cmd stat
    require_cmd chown
    require_cmd chmod
    require_cmd mv
    require_cmd mktemp

    if [ ! -f "$AMULE_CONF" ]; then
        log "aMule config not found: $AMULE_CONF"
        exit 1
    fi
}

check_gateway() {
    if [ -n "$VPN_IFACE" ]; then
        ip route get "$GATEWAY" 2>/dev/null | grep -q "dev $VPN_IFACE" || {
            log "Gateway $GATEWAY is not routed through $VPN_IFACE"
            return 1
        }
    else
        ip route get "$GATEWAY" >/dev/null 2>&1 || {
            log "Gateway $GATEWAY is not reachable"
            return 1
        }
    fi
}

extract_mapped_port() {
    awk '
        /Mapped public port/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "port") {
                    print $(i+1)
                    exit
                }
            }
        }
    '
}

request_forwarded_port() {
    local udp_out tcp_out udp_port tcp_port

    udp_out="$(natpmpc -a 1 0 udp "$LIFETIME" -g "$GATEWAY" 2>&1)" || {
        printf '%s\n' "$udp_out" >&2
        return 1
    }
    printf '%s\n' "$udp_out" >&2

    tcp_out="$(natpmpc -a 1 0 tcp "$LIFETIME" -g "$GATEWAY" 2>&1)" || {
        printf '%s\n' "$tcp_out" >&2
        return 1
    }
    printf '%s\n' "$tcp_out" >&2

    udp_port="$(printf '%s\n' "$udp_out" | extract_mapped_port | head -n1)"
    tcp_port="$(printf '%s\n' "$tcp_out" | extract_mapped_port | head -n1)"

    if [ -z "$udp_port" ] || [ -z "$tcp_port" ]; then
        log "Could not parse mapped port from natpmpc output" >&2
        return 1
    fi

    if [ "$udp_port" != "$tcp_port" ]; then
        log "UDP/TCP mapped to different ports: UDP=$udp_port TCP=$tcp_port" >&2
        return 1
    fi

    printf '%s\n' "$tcp_port"
}

read_emule_ports() {
    awk '
        BEGIN {
            in_emule = 0
            port = ""
            udp = ""
        }
        /^\[eMule\]$/ {
            in_emule = 1
            next
        }
        /^\[/ && $0 != "[eMule]" {
            in_emule = 0
        }
        in_emule && /^Port=/ {
            sub(/^Port=/, "", $0)
            port = $0
        }
        in_emule && /^UDPPort=/ {
            sub(/^UDPPort=/, "", $0)
            udp = $0
        }
        END {
            printf "%s %s\n", port, udp
        }
    ' "$AMULE_CONF"
}

update_emule_ports() {
    local new_port="$1"
    local tmp owner group mode

    tmp="$(mktemp "${AMULE_CONF}.tmp.XXXXXX")" || return 1

    owner="$(stat -c '%u' "$AMULE_CONF")" || {
        rm -f "$tmp"
        return 1
    }
    group="$(stat -c '%g' "$AMULE_CONF")" || {
        rm -f "$tmp"
        return 1
    }
    mode="$(stat -c '%a' "$AMULE_CONF")" || {
        rm -f "$tmp"
        return 1
    }

    awk -v new_port="$new_port" '
        BEGIN {
            in_emule = 0
            saw_emule = 0
            saw_port = 0
            saw_udp = 0
        }

        /^\[eMule\]$/ {
            in_emule = 1
            saw_emule = 1
            print
            next
        }

        /^\[/ && $0 != "[eMule]" {
            if (in_emule) {
                if (!saw_port) print "Port=" new_port
                if (!saw_udp)  print "UDPPort=" new_port
            }
            in_emule = 0
            print
            next
        }

        in_emule && /^Port=/ {
            if (!saw_port) {
                print "Port=" new_port
                saw_port = 1
            }
            next
        }

        in_emule && /^UDPPort=/ {
            if (!saw_udp) {
                print "UDPPort=" new_port
                saw_udp = 1
            }
            next
        }

        {
            print
        }

        END {
            if (!saw_emule) {
                print "[eMule]"
                print "Port=" new_port
                print "UDPPort=" new_port
            } else if (in_emule) {
                if (!saw_port) print "Port=" new_port
                if (!saw_udp)  print "UDPPort=" new_port
            }
        }
    ' "$AMULE_CONF" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }

    chown "$owner:$group" "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    chmod "$mode" "$tmp" || {
        rm -f "$tmp"
        return 1
    }

    mv "$tmp" "$AMULE_CONF"
}

stop_amule() {
    log "Stopping $AMULE_SERVICE"
    systemctl stop "$AMULE_SERVICE" || return 1

    local i
    for i in $(seq 1 30); do
        if ! pgrep -u "$AMULE_USER" -x amuled >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    if pgrep -u "$AMULE_USER" -x amuled >/dev/null 2>&1; then
        log "amuled is still running after stop timeout"
        return 1
    fi

    if pgrep -u "$AMULE_USER" -x amuleweb >/dev/null 2>&1; then
        log "Killing leftover amuleweb processes"
        pkill -u "$AMULE_USER" -x amuleweb || true
        sleep 1
    fi

    return 0
}

start_amule() {
    log "Starting $AMULE_SERVICE"
    systemctl start "$AMULE_SERVICE"
}

sync_amule_port_if_needed() {
    local new_port="$1"
    local current_port current_udp

    read -r current_port current_udp <<EOF
$(read_emule_ports)
EOF

    if [ "$current_port" = "$new_port" ] && [ "$current_udp" = "$new_port" ]; then
        log "aMule already configured with Port=$new_port UDPPort=$new_port"
        return 1
    fi

    log "aMule config needs update: Port=${current_port:-<unset>} UDPPort=${current_udp:-<unset>} -> $new_port"

    stop_amule || return 1
    update_emule_ports "$new_port" || return 1
    start_amule || return 1

    return 0
}

main() {
    mkdir -p "$STATE_DIR"
    chmod 0755 "$STATE_DIR"

    check_prereqs
    log "Starting Proton -> aMule port sync loop"
    log "Gateway=$GATEWAY Lifetime=$LIFETIME Sleep=$SLEEP_SECS"

    while true; do
        if ! check_gateway; then
            log "VPN gateway check failed, retrying in $SLEEP_SECS seconds"
            sleep "$SLEEP_SECS"
            continue
        fi

        new_port="$(request_forwarded_port)"
        rc=$?
        if [ $rc -ne 0 ] || [ -z "$new_port" ]; then
            log "Port request failed, retrying in $SLEEP_SECS seconds"
            sleep "$SLEEP_SECS"
            continue
        fi

        printf '%s\n' "$new_port" > "$PORT_FILE"
        chmod 0644 "$PORT_FILE"

        sync_amule_port_if_needed "$new_port" || true

        sleep "$SLEEP_SECS"
    done
}

main "$@"
