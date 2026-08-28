# Cornell CU VPN in Docker

Connects to Cornell's CU VPN (`cuvpn.cuvpn.cornell.edu`) using **openconnect**,
which speaks the same Cisco AnyConnect/ASA protocol as Cisco Secure Client but
is built for headless use and runs natively on arm64.

Alpine-based, ~56MB. `nc` comes from busybox and is what the host's ssh
`ProxyCommand` runs; `vpnc-script` lands at `/etc/vpnc/vpnc-script` on Alpine
and `/usr/share/vpnc-scripts/vpnc-script` on Debian/Ubuntu, so `entry.sh`
detects whichever is present.

## Usage

```sh
cp vpn.env.example vpn.env   # then fill in your NetID and password

make up        # reminds you to approve Duo, waits, confirms the tunnel is up
make status    # is it connected, and on what address
make ssh       # ssh cornell-ece
make logs      # follow the connection log
make down      # disconnect
make rebuild   # after editing Dockerfile/entry.sh, then reconnect
```

Plain compose works too, but `docker compose up -d` detaches, so the "approve
Duo" reminder the entrypoint prints scrolls by unseen - Compose has no
pre-start hook, which is why `make up` exists. Run it in the foreground
(`docker compose up`) or follow the log (`docker compose logs -f`) if you would
rather not use make.

The tunnel is a **split tunnel**: Cornell networks route over `tun0`, everything
else keeps using your normal connection. Cornell DNS servers are configured
inside the container.

## SSH to ECE servers from the host

The tunnel lives in the container's network namespace, so the Mac itself is not
on the VPN. SSH reaches it by running netcat inside the container:

```
Host cornell-ece
  HostName ecelinux.ece.cornell.edu
  User <netid>
  ProxyCommand /usr/local/bin/docker exec -i cornell-vpn nc %h %p
  ServerAliveInterval 30
  ServerAliveCountMax 6
```

Then `ssh cornell-ece` works from the host, and VS Code Remote-SSH picks it up
automatically since it uses the system ssh.

Two details that matter:

- Use the **absolute path** to `docker`. VS Code does not necessarily inherit
  your shell PATH, and `/usr/local/bin` is often missing from it.
- `%h` is resolved *inside* the container, so Cornell's DNS handles it.

The container must be running (`docker compose up -d`) or ssh fails with a
docker error.

To route another container's traffic through the VPN, attach it with
`network_mode: "service:vpn"`.

## Credentials

`vpn.env` is mounted as a Docker **secret**, not passed via `env_file`.

This matters: Compose performs variable interpolation on `env_file` values, so a
password containing `$` is silently corrupted before it reaches the container -
which presents as a plain "Login failed" with no hint of the real cause. Mounting
the file as a secret delivers it byte for byte. Do not "simplify" this back to
`env_file`.

## Gateway notes

- Tunnel group (`--authgroup`) must be `Two-Step_Login` (required since 2021-07-15).
- Username is your bare NetID, not an email address.
- Second password is the Duo factor: `push`, `phone`, `sms`, or a 6-digit passcode.
- `cuvpn.cuvpn.cornell.edu` round-robins across backend nodes. Nodes are
  occasionally out of service and simply time out - `vpn5-asa` was down during
  development. `restart: on-failure` retries; set `VPN_HOST` to pin a specific
  node (e.g. `vpn4-asa.cuvpn.cornell.edu`) if one is reliably up.
- If `docker exec cornell-vpn ip link show tun0` reports an MTU of 576, DTLS is
  failing on your network - the log will also show "Dead Peer Detection
  detected dead peer". Set `VPN_NO_DTLS=1` in `vpn.env` and reconnect; the
  tunnel then runs over TLS/TCP at a stable ~1303 MTU. Working DTLS gives a
  slightly better 1390, so leave it off unless you see the 576 symptom.
- openconnect probes the path MTU and normally settles on 1390. On a
  constrained link (a phone hotspot, for example) it may settle much lower -
  576 was observed on cellular. That is correct adaptation, not a fault: the
  low value is what that link can carry. Check with
  `docker exec cornell-vpn ip link show tun0`.
- `VPN_BASE_MTU` overrides the probe. Only set it if you are confident the path
  really supports it - forcing 1500 on a link that cannot carry it causes
  silent packet loss, which is worse than a small MTU. Leave it unset by
  default.

## Why not Cisco Secure Client?

Cisco's own Linux client was the first approach and is not used here. It
authenticates and downloads the gateway profile fine, but then fails at
`Activating VPN adapter` with "The VPN client driver encountered an error"
(`ConnectMgr::initiateTunnel` -> `CONNECTMGR_ERROR_UNEXPECTED`), with
`vpnagentd` logging nothing further. The tun device itself works in the
container, so the cause is the x86-64 client running under emulation on Docker
Desktop's VM. openconnect speaks the same protocol, runs natively on arm64, and
has none of these problems.

Two quirks worth recording if anyone retries it on a native x86-64 host:

- The Cisco CLI's `Group:` prompt **displays** the tunnel group but does not
  read a line from stdin. Feeding it one shifts every later answer by one
  position, so authentication fails regardless of the credentials.
- `BypassDownloader=true` avoids the downloader but makes the client reject the
  connection for a profile mismatch, since the gateway's profile can then never
  be fetched.
