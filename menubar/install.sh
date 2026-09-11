#!/bin/bash
# Build and install the Cornell VPN menu bar app.
#
# Installs, using sudo where required:
#   /Applications/CornellVPN.app            the menu bar app (no Dock icon)
#   /usr/local/libexec/cornell-vpn-helper   root helper (root:wheel 0755)
#   /usr/local/etc/cornell-vpn/cornell.conf root-owned openconnect config
#   /usr/local/etc/cornell-vpn/integrity.sha256
#   /etc/sudoers.d/cornell-vpn              NOPASSWD rule, helper only
#
# Re-run after `brew upgrade openconnect` to re-record the integrity hashes.
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP=/Applications/CornellVPN.app
HELPER=/usr/local/libexec/cornell-vpn-helper
CONFDIR=/usr/local/etc/cornell-vpn
OPENCONNECT=/opt/homebrew/bin/openconnect
VPNC_SCRIPT=/opt/homebrew/etc/vpnc/vpnc-script
SUDOERS=/etc/sudoers.d/cornell-vpn

die() { printf 'install: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" -ne 0 ] || die "run WITHOUT sudo - it will ask when it needs root."
[ -x "$OPENCONNECT" ]  || die "openconnect not found at $OPENCONNECT (brew install openconnect)"
[ -r "$VPNC_SCRIPT" ]  || die "vpnc-script not found at $VPNC_SCRIPT"
command -v swiftc >/dev/null || die "swiftc not found (install Xcode or the Command Line Tools)"

USER_NAME="$(id -un)"

step "Building CornellVPN.app"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$BUILD/CornellVPN.app/Contents/MacOS"
swiftc -O -o "$BUILD/CornellVPN.app/Contents/MacOS/CornellVPN" "$HERE/CornellVPN.swift"

cat > "$BUILD/CornellVPN.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CornellVPN</string>
  <key>CFBundleDisplayName</key><string>Cornell VPN</string>
  <key>CFBundleIdentifier</key><string>local.cornell-vpn.menubar</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>CornellVPN</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Menu bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

step "Installing the app to $APP (may ask for your password)"
sudo rm -rf "$APP"
sudo cp -R "$BUILD/CornellVPN.app" /Applications/
sudo chown -R root:wheel "$APP"

step "Installing the root helper and config"
sudo install -d -o root -g wheel -m 755 /usr/local/libexec "$CONFDIR"
sudo install -o root -g wheel -m 755 "$HERE/cornell-vpn-helper" "$HELPER"

# Root-owned config. Deliberately omits `user` (passed as an argument) and
# `script` (passed explicitly), so nothing user-writable feeds openconnect.
sudo tee "$CONFDIR/cornell.conf" >/dev/null <<CONF
# Managed by cornell-vpn install.sh. Root-owned on purpose: the helper runs
# openconnect as root, and a user-writable config could inject
# "script = /tmp/evil", which openconnect would execute as root.
protocol = anyconnect
server = https://cuvpn.cuvpn.cornell.edu
authgroup = Two-Step_Login
form-entry = main:secondary_password=push
# Uncomment if the tunnel MTU collapses to ~576 on your network:
# no-dtls = true
CONF
sudo chown root:wheel "$CONFDIR/cornell.conf"
sudo chmod 644 "$CONFDIR/cornell.conf"

step "Recording integrity hashes for openconnect and vpnc-script"
# /opt/homebrew is user-writable, so the helper refuses to run either file if
# it changes. Re-run this installer after upgrading openconnect.
shasum -a 256 "$OPENCONNECT" "$VPNC_SCRIPT" | sudo tee "$CONFDIR/integrity.sha256" >/dev/null
sudo chown root:wheel "$CONFDIR/integrity.sha256"
sudo chmod 644 "$CONFDIR/integrity.sha256"

step "Installing the sudoers rule"
TMP_SUDOERS="$(mktemp)"
cat > "$TMP_SUDOERS" <<RULE
# Lets $USER_NAME bring the Cornell VPN up/down from the menu bar without a
# password. Scoped to this one root-owned helper, which validates its arguments
# and verifies binary hashes. Remove with: sudo rm $SUDOERS
$USER_NAME ALL=(root) NOPASSWD: $HELPER
RULE
# visudo -c refuses to install a syntactically broken rule, which would
# otherwise be able to lock you out of sudo entirely.
visudo -cf "$TMP_SUDOERS" >/dev/null || { rm -f "$TMP_SUDOERS"; die "generated sudoers rule is invalid - not installing"; }
sudo install -o root -g wheel -m 440 "$TMP_SUDOERS" "$SUDOERS"
rm -f "$TMP_SUDOERS"

step "Verifying"
sudo -n "$HELPER" 2>&1 | grep -q "usage:" \
    && echo "  helper runs without a password" \
    || die "helper did not run passwordless - check $SUDOERS"

open "$APP"
cat <<DONE

==> Installed.

  The lock icon is now in your menu bar.
  First run opens Settings - enter your NetID and password (saved to Keychain).
  Then: click the icon -> Connect -> approve the Duo push.

  To start it at login:
    System Settings > General > Login Items > add /Applications/CornellVPN.app

  To uninstall:
    sudo rm -rf $APP $HELPER $CONFDIR $SUDOERS

  After 'brew upgrade openconnect', re-run this installer to re-record hashes.
DONE
