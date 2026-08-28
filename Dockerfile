# openconnect speaks the same Cisco AnyConnect/ASA protocol as Cisco Secure
# Client, but is built for headless use and has native arm64 packages - so this
# image runs without emulation.
#
# Alpine over Ubuntu: ~56MB vs ~306MB for the same functionality.
FROM alpine:3.20

# bash      - entry.sh uses arrays and process substitution; busybox ash has neither
# openconnect - also pulls in /etc/vpnc/vpnc-script for route and DNS setup
# iproute2  - `ip` for the tun0 checks
# busybox provides `nc`, which the host's ssh ProxyCommand runs:
#   ProxyCommand docker exec -i cornell-vpn nc %h %p
RUN apk add --no-cache \
        openconnect \
        iproute2 \
        bash \
        ca-certificates

COPY entry.sh /entry.sh
RUN chmod +x /entry.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ip link show tun0 >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/entry.sh"]
