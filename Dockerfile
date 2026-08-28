# openconnect speaks the same Cisco AnyConnect/ASA protocol as Cisco Secure
# Client, but is built for headless use and has native arm64 packages - so this
# image runs without the Rosetta emulation the Cisco client needed.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openconnect \
        vpnc-scripts \
        iproute2 \
        iputils-ping \
        ca-certificates \
        curl \
        dnsutils \
        netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

COPY entry.sh /entry.sh
RUN chmod +x /entry.sh

# netcat is what the host's ssh ProxyCommand runs inside this container:
#   ProxyCommand docker exec -i cornell-vpn nc %h %p
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ip link show tun0 >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/entry.sh"]
