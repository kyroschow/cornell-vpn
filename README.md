# Cornell CU VPN

Connects to Cornell's CU VPN with [openconnect](https://www.infradead.org/openconnect/),
running natively on macOS. The Mac itself joins the VPN, so ssh, VS Code
Remote-SSH, browsers and everything else reach Cornell directly — no proxy, no
container, no per-application configuration.

Two files:

| File | Purpose |
|---|---|
| `cornell-vpn` | up / down / status / restart wrapper |
| `cornell.conf` | openconnect settings (no password) — yours, gitignored |
| `cornell.conf.example` | template to copy |

## Install

```sh
brew install openconnect
cp cornell.conf.example cornell.conf   # then set `user` to your NetID
ln -sf "$PWD/cornell-vpn" /opt/homebrew/bin/cornell-vpn
```

`cornell.conf` is gitignored, so your NetID and any local overrides stay out of
the repo. `brew install openconnect` also provides the `vpnc-script` that
installs routes and DNS.

## Use

```sh
cornell-vpn up        # connect  (password prompts, then a Duo push)
cornell-vpn status    # connected? tunnel interface, address, MTU
cornell-vpn down      # disconnect
cornell-vpn restart   # down, then up
```

Then `ssh cornell-ece`, or anything else that needs Cornell.

### Two different passwords

`up` asks for two, in this order. They are not the same:

1. **macOS login password** — for `sudo`. openconnect edits the routing table
   and DNS, which needs root.
2. **Cornell NetID password** — for the VPN. Never stored anywhere.

If you see `Sorry, try again.` that is *sudo* rejecting your **Mac** password.
openconnect says `Login failed.` instead. The prompts are labelled `[1/2]` and
`[2/2]` to keep them apart.

### No retry, by design

If the Duo push is not approved in time, openconnect exits and **nothing
restarts it**. Run `cornell-vpn up` again for a fresh push.

This is deliberate. An automatic retry resubmits your credentials and fires
another push each time; left unattended it will send pushes all night and risks
a Duo fraud lockout. An earlier Docker version of this did exactly that.

openconnect does resume a *briefly dropped* tunnel by itself using the session
cookie, which involves no Duo prompt. Once that cookie is rejected — after a
laptop sleep, or a long outage — it exits and stays exited.

## Menu bar app (optional)

`menubar/` builds a small menu-bar-only app: click the lock icon to connect or
disconnect, with no terminal.

```sh
./menubar/install.sh      # NOT with sudo - it asks when it needs root
```

It builds `/Applications/CornellVPN.app` (no Dock icon), installs a root helper
and a narrow `sudoers.d` rule, and opens Settings so you can save your NetID and
password to the macOS Keychain. After that: click the icon, Connect, approve the
Duo push. Add the app to Login Items to have it start automatically.

Change your NetID or password any time from **Settings** in the menu; *Forget*
clears both. The password lives in the Keychain under service `cornell-vpn` and
can be removed in Keychain Access.

### Security note

The sudoers rule is `NOPASSWD`, which is what makes one click enough. It is
scoped to one root-owned helper that accepts only `up <netid>` and `down`,
validates the NetID, reads a **root-owned** config (a user-writable one could
inject `script = ...`, which openconnect runs as root), and takes the password
on stdin rather than argv.

It also verifies the SHA-256 of `openconnect` and `vpnc-script` before running
them. That check matters: Homebrew's prefix is user-writable, so without it any
process running as you could replace `openconnect` and reach root through the
NOPASSWD rule. Re-run `install.sh` after `brew upgrade openconnect` to
re-record the hashes.

This is still a real trade: a passwordless path to root exists on the machine,
narrowed as far as practical. To drop it, `sudo rm /etc/sudoers.d/cornell-vpn`
and use the `cornell-vpn` CLI, which asks for your password every time.

Uninstall:

```sh
sudo rm -rf /Applications/CornellVPN.app /usr/local/libexec/cornell-vpn-helper \
            /usr/local/etc/cornell-vpn /etc/sudoers.d/cornell-vpn
```

## Configuration

`cornell.conf` is a standard openconnect config file (long options, no `--`),
copied from `cornell.conf.example` and ignored by git.
Two settings are commented out and worth knowing about:

```
# no-dtls = true
# server = https://vpn4-asa.cuvpn.cornell.edu
```

Environment overrides: `CORNELL_VPN_CONFIG`, `CORNELL_VPN_PIDFILE`.

## Gateway notes

- `authgroup` must be `Two-Step_Login`, required by Cornell since 2021-07-15.
- The username is the bare NetID, not an email address.
- The Duo factor is set by form field name rather than prompt order:
  `form-entry = main:secondary_password=push`. Also accepts `phone`, `sms`, or
  a 6-digit passcode. Supplying it by name avoids the ordering bugs that come
  from piping answers blind into the client's prompts.
- **Split tunnel.** Only Cornell networks route over the VPN, so your public IP
  does not change. That is expected, not a failure.

## Troubleshooting

**Connection hangs before the password prompt.** `cuvpn.cuvpn.cornell.edu` is a
load-balancing VIP that redirects to a cluster member (`vpn4-asa` /
`vpn5-asa`). The redirect happens *before* the login form, so a member that is
out of service makes the connection hang with no Duo push at all. `vpn5-asa`
was down 2026-08-28 to at least 08-30. Test the members and pin a healthy one
with `server =` in `cornell.conf`:

```sh
nc -z -w5 132.236.56.113 443   # vpn4-asa
nc -z -w5 132.236.56.114 443   # vpn5-asa
```

**MTU around 576 / slow transfers.** DTLS (UDP) is failing on that network:
openconnect's MTU probe falls back to the IPv4 minimum and the session keeps
dying with "Dead Peer Detection detected dead peer". Uncomment `no-dtls` in
`cornell.conf` and reconnect. A healthy tunnel shows ~1300–1400 in
`cornell-vpn status`.

**`Login failed.`** The NetID password or the Duo factor was rejected — or the
push simply was not approved within about 30 seconds. Nothing retries; run
`cornell-vpn up` again.

## History

This began as a Docker setup and, before that, an attempt to use Cisco's own
Linux client. Both were removed; `git log` has them. Cisco's client
authenticates but fails at "Activating VPN adapter" under x86 emulation on
Apple silicon. Two findings, should anyone retry it:

- The Cisco CLI's `Group:` prompt *displays* the tunnel group but does not read
  a line from stdin. Feeding it one shifts every later answer by one position,
  so authentication fails regardless of the credentials.
- `BypassDownloader=true` skips the crashing downloader, but the client then
  rejects the connection for a profile mismatch, since the gateway's profile
  can no longer be fetched.

The Docker version worked, but put the tunnel in a container network namespace,
so the Mac was never on the VPN — everything had to be funnelled through
`ProxyCommand docker exec -i cornell-vpn nc %h %p`, which covered ssh and
nothing else.
