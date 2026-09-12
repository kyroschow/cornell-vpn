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

// Never uses readDataToEndOfFile(). A daemonising child (openconnect
// --background) inherits the stdout pipe and holds it open for the life of the
// tunnel, so reading to EOF blocks until the VPN disconnects - which froze the
// UI on "Connecting" while the tunnel was already up. Output is collected
// incrementally instead, and the wait is bounded.
@discardableResult
func run(_ path: String, _ args: [String], stdin: String? = nil,
         timeout: TimeInterval = 120) -> (status: Int32, output: String) {
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

    let lock = NSLock()
    var collected = Data()
    outPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        lock.lock(); collected.append(chunk); lock.unlock()
    }

    do { try proc.run() } catch {
        outPipe.fileHandleForReading.readabilityHandler = nil
        return (-1, "failed to launch \(path): \(error)")
    }

    if let secret = stdin, let pipe = inPipe {
        pipe.fileHandleForWriting.write(Data((secret + "\n").utf8))
        pipe.fileHandleForWriting.closeFile()
    }

    var timedOut = false
    let deadline = Date().addingTimeInterval(timeout)
    while proc.isRunning {
        if Date() >= deadline { timedOut = true; break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    if timedOut {
        proc.terminate()
        Thread.sleep(forTimeInterval: 0.5)
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
    }

    // Drain whatever is buffered, then stop listening.
    let tail = outPipe.fileHandleForReading.availableData
    if !tail.isEmpty { lock.lock(); collected.append(tail); lock.unlock() }
    outPipe.fileHandleForReading.readabilityHandler = nil

    lock.lock(); let data = collected; lock.unlock()
    var text = String(data: data, encoding: .utf8) ?? ""
    if timedOut { text += "\n(timed out after \(Int(timeout))s)" }
    return (timedOut ? -2 : proc.terminationStatus, text)
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

enum LinkStatus {
    case disconnected   // red    - openconnect not running
    case connecting     // yellow - authenticating, or up but no address yet
    case connected      // green  - tunnel carrying a Cornell address

    var dotColor: NSColor {
        switch self {
        case .disconnected: return .systemRed
        case .connecting:   return .systemYellow
        case .connected:    return .systemGreen
        }
    }

    var label: String {
        switch self {
        case .disconnected: return "Cornell VPN — Disconnected"
        case .connecting:   return "Cornell VPN — Connecting…"
        case .connected:    return "Cornell VPN — Connected"
        }
    }
}

struct VPNState {
    var processRunning = false
    var iface: String?
    var ip: String?
    var mtu: String?

    // A running process without an address means authentication is still in
    // flight (or the Duo push has not been approved yet).
    var status: LinkStatus {
        guard processRunning else { return .disconnected }
        return ip == nil ? .connecting : .connected
    }
}

func currentState() -> VPNState {
    guard run("/usr/bin/pgrep", ["-x", "openconnect"], timeout: 5).status == 0 else { return VPNState() }
    // openconnect is running; find the utun carrying a Cornell 10.x address.
    let list = run("/sbin/ifconfig", ["-l"], timeout: 5).output
    for iface in list.split(whereSeparator: { $0 == " " || $0 == "\n" })
        .map(String.init).filter({ $0.hasPrefix("utun") }) {
        let detail = run("/sbin/ifconfig", [iface], timeout: 5).output
        for raw in detail.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("inet ") else { continue }
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count > 1, parts[1].hasPrefix("10.") else { continue }
            var mtu: String?
            if let r = detail.range(of: "mtu ") {
                mtu = String(detail[r.upperBound...].prefix(while: { $0.isNumber }))
            }
            return VPNState(processRunning: true, iface: iface, ip: parts[1], mtu: mtu)
        }
    }
    // Process alive but no tunnel address yet (still connecting).
    return VPNState(processRunning: true)
}

// MARK: - Menu bar icon

// "CU" with a coloured status dot. Deliberately NOT a template image: macOS
// renders template images monochrome, which would flatten the dot to the same
// shade as the text. The text therefore has to follow the menu bar appearance
// itself, which it does because the drawing handler runs at draw time, with
// NSAppearance.current already set — so labelColor resolves correctly in both
// light and dark menu bars.
func statusImage(for status: LinkStatus) -> NSImage {
    let dotSize: CGFloat = 7
    let gap: CGFloat = 3
    let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    let text = NSAttributedString(string: "CU", attributes: [.font: font])
    let textSize = text.size()
    let width = ceil(textSize.width) + gap + dotSize
    let height: CGFloat = 18

    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
        let label = NSAttributedString(string: "CU", attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])
        let ty = (rect.height - textSize.height) / 2
        label.draw(at: NSPoint(x: 0, y: ty))

        status.dotColor.setFill()
        let dot = NSBezierPath(ovalIn: NSRect(
            x: rect.width - dotSize,
            y: (rect.height - dotSize) / 2,
            width: dotSize, height: dotSize))
        dot.fill()
        return true
    }
    image.isTemplate = false
    return image
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
        let state = currentState()
        // A click in progress pins the indicator to yellow: the process may not
        // have started yet, which would otherwise read as disconnected.
        let status: LinkStatus = busy ? .connecting : state.status
        if let button = statusItem.button {
            button.image = statusImage(for: status)
            button.toolTip = busy ? busyLabel : status.label
        }
        statusItem.menu = buildMenu(state, status: status)
    }

    func buildMenu(_ state: VPNState, status: LinkStatus) -> NSMenu {
        let menu = NSMenu()

        let headerItem = NSMenuItem(title: busy ? busyLabel : status.label,
                                    action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        if status == .connected, let ip = state.ip {
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
        } else if status != .disconnected {
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
