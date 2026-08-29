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
            VPN_NO_DTLS)  VPN_NO_DTLS="${VPN_NO_DTLS:-$val}" ;;
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
# Debian/Ubuntu ship this under /usr/share, Alpine under /etc. openconnect
# calls it on connect to install routes and DNS.
VPNC_SCRIPT=""
for candidate in /etc/vpnc/vpnc-script /usr/share/vpnc-scripts/vpnc-script; do
    if [ -x "$candidate" ]; then VPNC_SCRIPT="$candidate"; break; fi
done
[ -n "$VPNC_SCRIPT" ] || fail "vpnc-script not found - routes and DNS cannot be configured"

OC_ARGS=(
    --protocol=anyconnect
    --user="$VPN_NETID"
    --authgroup="$VPN_GROUP"
    --passwd-on-stdin
    --interface=tun0
    --script="$VPNC_SCRIPT"
)

# openconnect's DTLS MTU probe can settle on 576 bytes, which works but costs
# throughput. Setting VPN_BASE_MTU (try 1500) lets it negotiate a normal MTU.
# Left unset by default because the probed value is the safe one.
# DTLS (UDP) can be unreliable on some paths: openconnect's MTU probe fails,
# it falls back to the 576-byte IPv4 minimum, and the session repeatedly dies
# with "Dead Peer Detection detected dead peer". Disabling DTLS runs everything
# over TLS/TCP, which negotiates a normal 1390 MTU and stays up. Check with
# `docker exec cornell-vpn ip link show tun0`.
if [ "${VPN_NO_DTLS:-0}" = "1" ]; then
    log "DTLS disabled - tunnelling over TLS/TCP"
    OC_ARGS+=(--no-dtls)
fi

if [ -n "${VPN_BASE_MTU:-}" ]; then
    log "using base MTU ${VPN_BASE_MTU}"
    OC_ARGS+=(--base-mtu="$VPN_BASE_MTU")
fi
# openconnect runs in the background rather than via exec so its output can be
# inspected after it exits. That distinction matters: a REJECTED LOGIN must not
# be retried automatically. Every retry submits the credentials again and fires
# another Duo push, so an unattended loop (tunnel drops overnight, nobody
# approves) will spam the phone all night and risks a Duo fraud lockout.
CONNECT_LOG="$(mktemp)"
set +e
openconnect "${OC_ARGS[@]}" "$VPN_HOST" \
    < <(printf '%s\n%s\n' "$VPN_PASSWORD" "$VPN_DUO") \
    > >(tee "$CONNECT_LOG") 2>&1 &
OC_PID=$!

# Forward container shutdown to openconnect so the tunnel closes cleanly.
trap 'kill -TERM "$OC_PID" 2>/dev/null; wait "$OC_PID" 2>/dev/null; exit 0' TERM INT
wait "$OC_PID"
set -e

sleep 1   # let tee flush before reading

if grep -q "Login failed" "$CONNECT_LOG"; then
    rm -f "$CONNECT_LOG"
    log "authentication rejected - was the Duo ${VPN_DUO} approved in time?"
    log "NOT retrying: each attempt sends another push. Run 'make up' when ready."
    exit 0        # exit 0 so `restart: on-failure` leaves this stopped
fi

rm -f "$CONNECT_LOG"
log "connection ended - exiting non-zero so the restart policy reconnects"
exit 1
