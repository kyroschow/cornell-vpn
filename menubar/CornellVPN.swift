// Cornell VPN menu bar app.
//
// LSUIElement (see Info.plist in install.sh): no Dock icon, no windows except
// Settings. Connect/disconnect go through the root helper installed at
// HELPER_PATH via a narrow NOPASSWD sudoers rule, so a click needs no password.
// The NetID password lives in the macOS Keychain and is handed to the helper on
// stdin, never in argv.

import AppKit
import Security

let HELPER_PATH = "/usr/local/libexec/cornell-vpn-helper"
let KEYCHAIN_SERVICE = "cornell-vpn"
let NETID_KEY = "netid"

// MARK: - Shell

@discardableResult
func run(_ path: String, _ args: [String], stdin: String? = nil) -> (status: Int32, output: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = outPipe
    var inPipe: Pipe?
    if stdin != nil {
        inPipe = Pipe()
        proc.standardInput = inPipe
    }
    do { try proc.run() } catch { return (-1, "failed to launch \(path): \(error)") }
    if let secret = stdin, let pipe = inPipe {
        pipe.fileHandleForWriting.write(Data((secret + "\n").utf8))
        pipe.fileHandleForWriting.closeFile()
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - Keychain

enum Keychain {
    static func set(_ password: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KEYCHAIN_SERVICE,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KEYCHAIN_SERVICE,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KEYCHAIN_SERVICE,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - VPN state

struct VPNState {
    var connected = false
    var iface: String?
    var ip: String?
    var mtu: String?
}

func currentState() -> VPNState {
    guard run("/usr/bin/pgrep", ["-x", "openconnect"]).status == 0 else { return VPNState() }
    // openconnect is running; find the utun carrying a Cornell 10.x address.
    let list = run("/sbin/ifconfig", ["-l"]).output
    for iface in list.split(whereSeparator: { $0 == " " || $0 == "\n" })
        .map(String.init).filter({ $0.hasPrefix("utun") }) {
        let detail = run("/sbin/ifconfig", [iface]).output
        for raw in detail.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("inet ") else { continue }
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count > 1, parts[1].hasPrefix("10.") else { continue }
            var mtu: String?
            if let r = detail.range(of: "mtu ") {
                mtu = String(detail[r.upperBound...].prefix(while: { $0.isNumber }))
            }
            return VPNState(connected: true, iface: iface, ip: parts[1], mtu: mtu)
        }
    }
    // Process alive but no tunnel address yet (still connecting).
    return VPNState(connected: true)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var busy = false
    var busyLabel = ""
    var settingsWindow: NSWindow?
    var netIDField: NSTextField!
    var passwordField: NSSecureTextField!

    var netID: String {
        get { UserDefaults.standard.string(forKey: NETID_KEY) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: NETID_KEY) }
    }

    func applicationDidFinishLaunching(_: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if netID.isEmpty { showSettings() }
    }

    // MARK: UI

    func refresh() {
        let state = busy ? VPNState() : currentState()
        let symbol = busy ? "arrow.triangle.2.circlepath"
                          : (state.connected ? "lock.shield.fill" : "lock.shield")
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Cornell VPN")
            button.image?.isTemplate = true
        }
        statusItem.menu = buildMenu(state)
    }

    func buildMenu(_ state: VPNState) -> NSMenu {
        let menu = NSMenu()

        let header: String
        if busy { header = busyLabel }
        else if state.connected { header = "Cornell VPN — Connected" }
        else { header = "Cornell VPN — Disconnected" }
        let headerItem = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        if state.connected, let ip = state.ip {
            var detail = "\(state.iface ?? "utun")  ·  \(ip)"
            if let mtu = state.mtu { detail += "  ·  MTU \(mtu)" }
            let d = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
            d.isEnabled = false
            menu.addItem(d)
        }

        menu.addItem(.separator())

        if busy {
            let b = NSMenuItem(title: "Working…", action: nil, keyEquivalent: "")
            b.isEnabled = false
            menu.addItem(b)
        } else if state.connected {
            menu.addItem(NSMenuItem(title: "Disconnect",
                                    action: #selector(disconnect), keyEquivalent: "d"))
        } else {
            let c = NSMenuItem(title: "Connect", action: #selector(connect), keyEquivalent: "c")
            if netID.isEmpty { c.isEnabled = false }
            menu.addItem(c)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: netID.isEmpty ? "Set NetID & Password…" : "Settings (\(netID))…",
                                action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil { item.target = self }
        return menu
    }

    func notify(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = style
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: Actions

    @objc func connect() {
        let user = netID
        guard !user.isEmpty else { showSettings(); return }
        guard let password = Keychain.get(account: user) else {
            notify("No password saved", "No Keychain password for \(user). Open Settings and save it.",
                   style: .warning)
            showSettings()
            return
        }

        busy = true
        busyLabel = "Connecting — approve the Duo push"
        refresh()

        DispatchQueue.global(qos: .userInitiated).async {
            let result = run("/usr/bin/sudo", ["-n", HELPER_PATH, "up", user], stdin: password)
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                if result.status != 0 {
                    let out = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if out.contains("a password is required") || out.contains("sudo:") {
                        self.notify("Helper not authorised",
                                    "sudo refused to run the helper without a password. Re-run install.sh.\n\n\(out)",
                                    style: .critical)
                    } else if out.contains("Login failed") {
                        self.notify("Login failed",
                                    "The gateway rejected the login, or the Duo push was not approved in time. Nothing is retried — click Connect again.\n\n\(out)",
                                    style: .warning)
                    } else {
                        self.notify("Connection failed", out.isEmpty ? "openconnect exited non-zero." : out,
                                    style: .warning)
                    }
                }
            }
        }
    }

    @objc func disconnect() {
        busy = true
        busyLabel = "Disconnecting…"
        refresh()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run("/usr/bin/sudo", ["-n", HELPER_PATH, "down"])
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                if result.status != 0 {
                    self.notify("Disconnect failed",
                                result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                                style: .warning)
                }
            }
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: Settings

    @objc func showSettings() {
        if let w = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 190),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Cornell VPN"
        window.center()
        window.isReleasedWhenClosed = false

        let content = NSView(frame: window.contentLayoutRect)

        func label(_ text: String, y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 20, y: y, width: 90, height: 20)
            l.alignment = .right
            return l
        }

        content.addSubview(label("NetID:", y: 130))
        netIDField = NSTextField(frame: NSRect(x: 120, y: 128, width: 230, height: 24))
        netIDField.stringValue = netID
        netIDField.placeholderString = "abc123"
        content.addSubview(netIDField)

        content.addSubview(label("Password:", y: 95))
        passwordField = NSSecureTextField(frame: NSRect(x: 120, y: 93, width: 230, height: 24))
        passwordField.placeholderString = netID.isEmpty ? "NetID password" : "unchanged — type to replace"
        content.addSubview(passwordField)

        let note = NSTextField(wrappingLabelWithString:
            "Stored in your macOS Keychain (service “cornell-vpn”). Remove it any time in Keychain Access.")
        note.frame = NSRect(x: 20, y: 45, width: 340, height: 34)
        note.font = .systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor
        content.addSubview(note)

        let save = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        save.frame = NSRect(x: 265, y: 10, width: 90, height: 28)
        save.keyEquivalent = "\r"
        content.addSubview(save)

        let forget = NSButton(title: "Forget", target: self, action: #selector(forgetSettings))
        forget.frame = NSRect(x: 165, y: 10, width: 90, height: 28)
        content.addSubview(forget)

        window.contentView = content
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func saveSettings() {
        let newID = netIDField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newID.isEmpty else {
            notify("NetID required", "Enter your NetID.", style: .warning); return
        }
        guard newID.range(of: "^[A-Za-z0-9_-]{2,32}$", options: .regularExpression) != nil else {
            notify("Invalid NetID", "Letters, digits, - and _ only.", style: .warning); return
        }

        let oldID = netID
        let typed = passwordField.stringValue

        if !typed.isEmpty {
            guard Keychain.set(typed, account: newID) else {
                notify("Keychain error", "Could not save the password.", style: .critical); return
            }
        } else if oldID != newID {
            // NetID changed but no new password typed: move the existing one.
            if let existing = Keychain.get(account: oldID) {
                _ = Keychain.set(existing, account: newID)
            } else {
                notify("Password needed", "No password stored for \(newID). Type it above.", style: .warning)
                return
            }
        } else if Keychain.get(account: newID) == nil {
            notify("Password needed", "No password stored yet. Type it above.", style: .warning)
            return
        }

        if oldID != newID && !oldID.isEmpty { Keychain.delete(account: oldID) }
        netID = newID
        passwordField.stringValue = ""
        passwordField.placeholderString = "unchanged — type to replace"
        refresh()
        settingsWindow?.close()
    }

    @objc func forgetSettings() {
        if !netID.isEmpty { Keychain.delete(account: netID) }
        netID = ""
        netIDField.stringValue = ""
        passwordField.stringValue = ""
        refresh()
        notify("Cleared", "NetID and Keychain password removed.")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
