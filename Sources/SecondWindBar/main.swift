import AppKit
import Carbon.HIToolbox
import SwitchCore
import UserNotifications

/// Menu bar app: shows the active account, switches on request, and acts on limit events that the
/// Claude Code hook leaves in the events folder.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = Store()
    private lazy var engine = Engine(store: store)
    /// All engine work runs here, one thing at a time, off the main thread.
    private let work = DispatchQueue(label: "secondwind.work")
    private var item: NSStatusItem!
    private var status: Status?
    private var tickQueued = false
    private var hotKey: EventHotKeyRef?
    // Touched on the work queue only.
    private var wasRunning = false
    private var firstTick = true
    private var restartSeenAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Claude account")
            button.imagePosition = .imageLeading
            button.title = " –"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        if store.loadConfig().hotkey { registerHotKey() }
        store.log("menu bar app started")

        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    // MARK: Periodic work

    private func tick() {
        guard !tickQueued else { return }
        tickQueued = true
        work.async { [self] in
            defer { DispatchQueue.main.async { self.tickQueued = false } }

            for event in engine.ingestEvents() { report(engine.handle(event), event: event) }

            var s = engine.status()
            let running = !s.active.isEmpty
            // Claude was just closed by hand: bring the other account's list up to date now, so
            // whichever profile opens next sees it.
            if (wasRunning || firstTick) && !running, let r = engine.syncIfIdle() {
                store.log("synced while Claude is closed: \(r)")
                s = engine.status()
            }
            wasRunning = running
            firstTick = false

            // First sign-in on a new profile created an account folder the list was never copied
            // to. Restart that profile once so it loads the shared list.
            if let p = s.needsRestart, s.setupProfile == p {
                if let seen = restartSeenAt {
                    if Date().timeIntervalSince(seen) > 10 {
                        restartSeenAt = nil
                        notify("Loading your sessions", "Claude restarts once to show the shared session list.")
                        run { try self.engine.switchTo(p, reason: "reseed", restart: true) }
                        s = engine.status()
                    }
                } else {
                    restartSeenAt = Date()
                }
            } else {
                restartSeenAt = nil
            }

            DispatchQueue.main.async {
                self.status = s
                self.item.button?.title = " " + s.title
            }
        }
    }

    private func report(_ outcome: LimitOutcome, event: LimitEvent) {
        let cfg = store.loadConfig()
        func name(_ id: Int) -> String { cfg.profile(id)?.name ?? "profile \(id)" }
        switch outcome {
        case .switched(let from, let to):
            notify("\(name(from)) hit its usage limit", "Switched to \(name(to)). Your session is open there.")
        case .skipped(let why, let show):
            if show { notify("\(name(event.profileId)) hit its usage limit", why) }
        case .failed(let why):
            notify("Could not switch accounts", why)
        }
    }

    /// Runs engine work that can throw and tells the user when it fails. Call on the work queue.
    private func run(_ body: () throws -> Void) {
        do { try body() } catch { notify("Could not switch accounts", "\(error)") }
    }

    private func notify(_ title: String, _ body: String) {
        store.log("notify: \(title): \(body)")
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = status ?? engine.status()
        for row in MenuModel.rows(s) {
            switch row.kind {
            case .separator:
                menu.addItem(.separator())
            case .header, .info:
                let mi = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
                mi.isEnabled = false
                menu.addItem(mi)
            case .account(let id):
                let mi = NSMenuItem(title: row.title, action: #selector(pickAccount(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = id
                mi.state = row.checked ? .on : .off
                if let sub = row.subtitle {
                    if #available(macOS 14.4, *) { mi.subtitle = sub } else { mi.toolTip = sub }
                }
                menu.addItem(mi)
            case .toggle:
                let mi = NSMenuItem(title: row.title, action: #selector(toggleAuto), keyEquivalent: "")
                mi.target = self
                mi.state = row.checked ? .on : .off
                menu.addItem(mi)
            case .action(let id):
                let mi = NSMenuItem(title: row.title, action: #selector(act(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = id
                mi.isEnabled = row.enabled
                if id.hasPrefix("switch:") {
                    mi.keyEquivalent = "s"
                    mi.keyEquivalentModifierMask = [.control, .option]
                }
                menu.addItem(mi)
            }
        }
    }

    @objc private func pickAccount(_ sender: NSMenuItem) {
        guard let p = status?.profiles.first(where: { $0.profile.id == sender.tag }) else { return }
        if p.running {
            work.async { self.engine.system.activate(appPath: self.store.loadConfig().appPath) }
        } else if p.ready {
            switchTo(p.profile.id)
        } else {
            setUp(p.profile)
        }
    }

    @objc private func toggleAuto() {
        var cfg = store.loadConfig()
        cfg.autoSwitch.toggle()
        try? store.saveConfig(cfg)
        tick()
    }

    @objc private func act(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if id.hasPrefix("switch:"), let target = Int(id.dropFirst(7)) {
            switchTo(target)
        } else if id == "restart", let p = status?.needsRestart {
            work.async { self.run { try self.engine.switchTo(p, reason: "reseed", restart: true) } }
        } else if id == "open" {
            work.async {
                let cfg = self.store.loadConfig()
                if self.engine.instances(cfg).contains(where: { $0.profileId != nil }) {
                    self.engine.system.activate(appPath: cfg.appPath)
                } else {
                    let last = self.store.loadState().lastSwitch?.to ?? cfg.profiles.first?.id
                    self.run { try self.engine.switchTo(last, reason: "open") }
                }
            }
        } else if id == "quit" {
            NSApp.terminate(nil)
        }
    }

    /// Manual switch. Asks first when a session looks busy, because switching quits Claude.
    private func switchTo(_ target: Int?) {
        let anyRunning = !(status?.active.isEmpty ?? true)
        if anyRunning && ProfileProbe.recentTranscriptWrite(within: 20) {
            let alert = NSAlert()
            alert.messageText = "Claude looks busy"
            alert.informativeText = "Switching accounts quits Claude and stops any session that is still working. Sessions stay in the list and can be continued on the other account."
            alert.addButton(withTitle: "Switch anyway")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        work.async { self.run { try self.engine.switchTo(target, reason: "manual") } }
        tick()
    }

    private func setUp(_ profile: Profile) {
        let alert = NSAlert()
        alert.messageText = "Set up \(profile.name)"
        alert.informativeText = "Claude will quit and reopen on a separate profile. Sign in there with your second account. Your Code sessions are copied over, so the same list appears on both accounts."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        work.async { self.run { try self.engine.switchTo(profile.id, reason: "setup") } }
        tick()
    }

    // MARK: Global shortcut (Control-Option-S)

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.hotKeyPressed() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x4353_5754), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func hotKeyPressed() {
        // Only between two signed-in accounts; setup always goes through the menu.
        guard let s = status, s.active.count == 1, let other = s.profiles.first(where: { !$0.running }), other.ready else {
            NSSound.beep()
            return
        }
        switchTo(other.profile.id)
    }
}

// One copy is enough.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
