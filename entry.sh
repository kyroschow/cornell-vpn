#!/bin/bash
set -euo pipefail

CRED_FILE=/run/secrets/vpn_credentials

# Parse the mounted credentials file literally: split on the first '=', strip a
# trailing CR and one matching pair of surrounding quotes, and never eval the
# value. Real environment variables take precedence over the file.
if [ -f "$CRED_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"
        val="${line#*=}"
        key="${key// /}"
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac
        case "$key" in
            VPN_NETID)    VPN_NETID="${VPN_NETID:-$val}" ;;
            VPN_PASSWORD) VPN_PASSWORD="${VPN_PASSWORD:-$val}" ;;
            VPN_DUO)      VPN_DUO="${VPN_DUO:-$val}" ;;
            VPN_HOST)     VPN_HOST="${VPN_HOST:-$val}" ;;
            VPN_GROUP)    VPN_GROUP="${VPN_GROUP:-$val}" ;;
            VPN_BASE_MTU) VPN_BASE_MTU="${VPN_BASE_MTU:-$val}" ;;
        esac
    done < "$CRED_FILE"
fi

VPN_HOST="${VPN_HOST:-cuvpn.cuvpn.cornell.edu}"
# Cornell requires this tunnel group (authgroup) as of 2021-07-15.
VPN_GROUP="${VPN_GROUP:-Two-Step_Login}"
# Duo second factor: "push", "phone", "sms", or a 6-digit passcode.
VPN_DUO="${VPN_DUO:-push}"

log() { printf '[entry] %s\n' "$*"; }
fail() {
    log "ERROR: $*"
    sleep 15
    exit 1
}

if [ -z "${VPN_NETID:-}" ] || [ -z "${VPN_PASSWORD:-}" ]; then
    fail "VPN_NETID and VPN_PASSWORD must be set. Copy vpn.env.example to vpn.env and fill it in."
fi

# The tun device is not present in a fresh container namespace.
mkdir -p /dev/net
if [ ! -e /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200 || fail "could not create /dev/net/tun (is the container privileged?)"
    chmod 600 /dev/net/tun
fi

log "connecting to ${VPN_HOST} as ${VPN_NETID} (group: ${VPN_GROUP})"
printf '\n'
printf '  ============================================================\n'
printf '     APPROVE THE DUO %s ON YOUR PHONE NOW\n' "$(printf '%s' "$VPN_DUO" | tr '[:lower:]' '[:upper:]')"
printf '     (times out in ~30s, then the container retries)\n'
printf '  ============================================================\n\n' 

# openconnect reads the password from stdin, then reads the Duo second factor
# from the next line. Fed by process substitution so the password is never
# written to disk or visible in the process list, and so openconnect replaces
# this shell as PID 1 and receives SIGTERM directly for a clean disconnect.
OC_ARGS=(
    --protocol=anyconnect
    --user="$VPN_NETID"
    --authgroup="$VPN_GROUP"
    --passwd-on-stdin
    --interface=tun0
    --script=/usr/share/vpnc-scripts/vpnc-script
)

# openconnect's DTLS MTU probe can settle on 576 bytes, which works but costs
# throughput. Setting VPN_BASE_MTU (try 1500) lets it negotiate a normal MTU.
# Left unset by default because the probed value is the safe one.
if [ -n "${VPN_BASE_MTU:-}" ]; then
    log "using base MTU ${VPN_BASE_MTU}"
    OC_ARGS+=(--base-mtu="$VPN_BASE_MTU")
fi
# exec so openconnect becomes PID 1 and receives SIGTERM directly for a clean
# disconnect. The host reaches this tunnel via `docker exec -i cornell-vpn nc`,
# so no proxy or published port is needed.
exec openconnect "${OC_ARGS[@]}" "$VPN_HOST" \
    < <(printf '%s\n%s\n' "$VPN_PASSWORD" "$VPN_DUO")
