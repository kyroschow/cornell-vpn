# Cornell CU VPN

Connects to Cornell's CU VPN with **openconnect**, natively on macOS. The Mac
itself joins the VPN, so ssh, VS Code Remote-SSH, browsers and everything else
reach Cornell directly.

## Install

```sh
brew install openconnect
ln -sf "$PWD/cornell-vpn" /opt/homebrew/bin/cornell-vpn
```

Set `user` in `cornell.conf` to your NetID.

## Use

```sh
cornell-vpn up       # prompts for password, then sends a Duo push
cornell-vpn status   # connected? tunnel address and MTU
cornell-vpn down     # disconnect
cornell-vpn restart  # down, then up
```

`up` needs `sudo` (openconnect edits the routing table and DNS) and asks for
your NetID password. It never stores it.

Then `ssh cornell-ece`, or anything else that needs Cornell.

## No retry, by design

If the Duo push is not approved in time, openconnect exits and **nothing
restarts it**. Run `cornell-vpn up` again for a fresh push.

This is deliberate. An automatic retry resubmits the credentials and fires
another push each time; an unattended loop will spam your phone overnight and
risks a Duo fraud lockout. That happened with the earlier Docker version.

openconnect does resume a *briefly dropped* tunnel on its own using the session
cookie, which involves no Duo prompt. Once that cookie is rejected - after a
laptop sleep, or a long outage - it exits and stays exited.

## Gateway notes

- Tunnel group (`authgroup`) must be `Two-Step_Login`, required since 2021-07-15.
- Username is the bare NetID, not an email address.
- Second factor is `push`, `phone`, `sms`, or a 6-digit passcode, set via
  `form-entry = main:secondary_password=...`.
- `cuvpn.cuvpn.cornell.edu` is a load-balancing VIP that redirects to a cluster
  member (`vpn4-asa` / `vpn5-asa`). The redirect happens *before* the login
  form, so a member that is out of service makes the connection hang with no
  Duo push at all. `vpn5-asa` was down 2026-08-28 to at least 08-30. If
  connections hang, test the members and pin a healthy one with `server =` in
  `cornell.conf`:
  ```sh
  nc -z -w5 132.236.56.113 443   # vpn4-asa
  nc -z -w5 132.236.56.114 443   # vpn5-asa
  ```
- Split tunnel: only Cornell networks route over the VPN, so your public IP
  will not change. That is expected.
- If `cornell-vpn status` reports an MTU near 576, DTLS is failing on that
  network - uncomment `no-dtls` in `cornell.conf` and reconnect.

## History

This started as a Docker setup, removed in favour of running openconnect
directly; `git log` has it. Cisco's own Linux client was tried first and
abandoned: it authenticates but fails at "Activating VPN adapter" under x86
emulation on Apple silicon. Two findings from that, if anyone retries it:

- The Cisco CLI's `Group:` prompt *displays* the tunnel group but does not read
  a line from stdin. Feeding it one shifts every later answer by one position,
  so authentication fails regardless of the credentials.
- `BypassDownloader=true` skips the crashing downloader but then rejects the
  connection for a profile mismatch, since the gateway's profile can no longer
  be fetched.
