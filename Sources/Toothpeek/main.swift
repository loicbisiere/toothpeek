import Combine
import SwiftUI

// `Toothpeek --snapshot out.jpg` grabs one frame and exits (uses BAMBU_IP / BAMBU_ACCESS_CODE).
if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let out = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "frame.jpg"
    let env = ProcessInfo.processInfo.environment
    let camera = Camera()
    camera.onFrame = { data in
        do {
            try data.write(to: URL(fileURLWithPath: out))
            print("OK: saved \(out) (\(data.count) bytes)")
        } catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }
    camera.start(ip: env["BAMBU_IP"] ?? "", accessCode: env["BAMBU_ACCESS_CODE"] ?? "")
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
        print("FAIL: \(camera.status)")
        exit(1)
    }
    dispatchMain()
}

// `Toothpeek --discover` prints printers announcing themselves on the LAN for 15 s.
if CommandLine.arguments.contains("--discover") {
    let discovery = Discovery()
    let printed = discovery.$printers.sink { for p in $0.suffix(1) { print("\(p.name) (\(p.model)) \(p.ip)") } }
    discovery.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
        _ = printed
        exit(discovery.printers.isEmpty ? 1 : 0)
    }
    dispatchMain()
}

// `Toothpeek --status` prints the print status once the printer reports it (uses BAMBU_IP / BAMBU_ACCESS_CODE).
if CommandLine.arguments.contains("--status") {
    let env = ProcessInfo.processInfo.environment
    let status = PrinterStatus()
    let printed = status.$report.sink { report in
        guard !report.isEmpty else { return }
        DispatchQueue.main.async {
            print("state=\(String(describing: status.state)) file=\(status.fileName ?? "-") percent=\(status.percent ?? -1)",
                  "remaining=\(status.remainingMinutes ?? -1)min layer=\(status.layer ?? -1)/\(status.totalLayers ?? -1)",
                  "nozzle=\(String(describing: status.nozzle)) bed=\(String(describing: status.bed))",
                  "trays=\(status.trays.map { "\($0.type)\($0.active ? "*" : "") \($0.remain ?? -1)%" })")
            exit(0)
        }
    }
    status.start(ip: env["BAMBU_IP"] ?? "", accessCode: env["BAMBU_ACCESS_CODE"] ?? "")
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
        _ = printed
        print("FAIL: \(status.problem ?? "no report")")
        exit(1)
    }
    dispatchMain()
}

// `Toothpeek --light on|off` switches the chamber light and prints the resulting state (uses BAMBU_IP / BAMBU_ACCESS_CODE).
if let i = CommandLine.arguments.firstIndex(of: "--light"), CommandLine.arguments.count > i + 1 {
    let wanted = CommandLine.arguments[i + 1] == "on"
    let env = ProcessInfo.processInfo.environment
    let status = PrinterStatus()
    var sent = false
    let watch = status.$report.sink { _ in
        DispatchQueue.main.async {
            if let error = status.commandError { print("FAIL: \(error)"); exit(1) }
            guard let light = status.lightOn else { return }
            if !sent {
                sent = true
                status.setLight(wanted)
                print("light was \(light ? "on" : "off"), sent \(wanted ? "on" : "off"), pending=\(status.pendingLight != nil)")
            } else if light == wanted {
                print("OK: light is \(light ? "on" : "off"), pending=\(status.pendingLight != nil)")
                exit(0)
            }
        }
    }
    status.start(ip: env["BAMBU_IP"] ?? "", accessCode: env["BAMBU_ACCESS_CODE"] ?? "")
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
        _ = watch
        print("FAIL: \(status.commandError ?? status.problem ?? "no confirmation")")
        exit(1)
    }
    dispatchMain()
}

// `Toothpeek --check-update 0.1.0` prints what the update checker would say for that installed version.
if let i = CommandLine.arguments.firstIndex(of: "--check-update"), CommandLine.arguments.count > i + 1 {
    let current = CommandLine.arguments[i + 1]
    URLSession.shared.dataTask(with: URL(string: "https://api.github.com/repos/loicbisiere/toothpeek/releases/latest")!) { data, _, _ in
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard let tag = json?["tag_name"] as? String else { print("FAIL: no release info"); exit(1) }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        print("latest=\(latest) installed=\(current) update=\(UpdateChecker.isNewer(latest, than: current))")
        exit(0)
    }.resume()
    dispatchMain()
}

let appDelegate = AppDelegate() // NSApplication.delegate is weak: this global keeps it alive
NSApplication.shared.delegate = appDelegate
NSApp.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    let camera = Camera()
    let status = PrinterStatus()
    let updates = UpdateChecker()
    private let form = SettingsForm()
    private lazy var viewer = Viewer(camera: camera, status: status, updates: updates, form: form)
    private lazy var notifier = Notifier(camera: camera)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var watches: [AnyCancellable] = []
    private var simulation: Simulation?

    // static, not main.swift globals: those are initialized in top-level order, i.e. after NSApp.run() starts.
    private static var iconCache: [String: NSImage] = [:]

    /// Printer frame with an eye and a print bed (same drawing as icon/make_icon.swift, redrawn for 18 pt).
    /// `ring` nil: template image, macOS tints it for light/dark menu bars. A color: the frame shows the print state.
    static func menuBarIcon(ring: NSColor?, dashed: Bool = false) -> NSImage {
        let key = "\(ring.map { "\($0)" } ?? "template")-\(dashed)"
        if let cached = iconCache[key] { return cached }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let ink = ring == nil ? NSColor.black : NSColor.labelColor // drawn per appearance, so labelColor adapts
            (ring ?? ink).setStroke()
            let frame = NSBezierPath(roundedRect: NSRect(x: 2.75, y: 1.75, width: 12.5, height: 14.5), xRadius: 2.5, yRadius: 2.5)
            frame.lineWidth = ring == nil ? 1.5 : 1.8
            if dashed { frame.setLineDash([2, 1.6], count: 2, phase: 0) }
            frame.stroke()

            ink.setFill()
            let eye = NSBezierPath() // almond shape centered at (9, 10)
            eye.move(to: NSPoint(x: 4.8, y: 10))
            eye.curve(to: NSPoint(x: 13.2, y: 10), controlPoint1: NSPoint(x: 6.9, y: 13.4), controlPoint2: NSPoint(x: 11.1, y: 13.4))
            eye.curve(to: NSPoint(x: 4.8, y: 10), controlPoint1: NSPoint(x: 11.1, y: 6.6), controlPoint2: NSPoint(x: 6.9, y: 6.6))
            eye.fill()
            NSGraphicsContext.current?.compositingOperation = .clear // pupil: see-through
            NSBezierPath(ovalIn: NSRect(x: 7.6, y: 8.6, width: 2.8, height: 2.8)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(roundedRect: NSRect(x: 5, y: 4, width: 8, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill() // bed
            return true
        }
        image.isTemplate = ring == nil
        image.accessibilityDescription = "Toothpeek"
        iconCache[key] = image
        return image
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        installMainMenu()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // receive(on:) runs after the change: @Published fires before the new value is stored.
        watches.append(status.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in self?.updateIcon() })
        updateIcon()
        if form.editing { showSettings() } // first launch: nothing to show until the printer is set
        _ = notifier // create now: it is the notification center delegate and backs "Send a test notification"
        status.onStateChange = { [weak self] old, new in
            guard let self else { return }
            self.notifier.printStateChanged(from: old, to: new, status: self.status)
        }
        status.onOnlineChange = { [weak self] online in self?.notifier.printerOnline(online) }

        // Re-evaluate what to keep connected whenever a window shows/hides or a setting changes.
        let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didResignKeyNotification, UserDefaults.didChangeNotification,
                     AccessCode.didChange]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.updateConnections() } // let the window state settle first
            }
        }
        updateConnections()
        updates.onNewVersion = { [weak self] release in
            guard let self else { return }
            self.notifier.updateAvailable(release.version, homebrew: self.updates.installedWithHomebrew)
        }
        updates.start()
        if updates.currentVersion == nil, let name = ProcessInfo.processInfo.environment["TOOTHPEEK_SIMULATE"] { // dev builds
            simulation = Simulation.allCases.first { "\($0)" == name }
            simulation?.apply(to: status, camera: camera)
            if simulation != nil { viewer.show(under: iconFrame) }
        }
        // Permission is per bundle id: re-ask if notifications are on but macOS has not decided yet (e.g. after a rename).
        if UserDefaults.standard.bool(forKey: Notifier.enabledKey) { Notifier.requestAuthorization { _ in } }
    }

    /// Video only while a window shows it. Status (MQTT, a few KB) also in the background if enabled.
    func updateConnections() {
        let ip = UserDefaults.standard.string(forKey: "printerIP") ?? ""
        let code = AccessCode.value
        let windowVisible = NSApp.windows.contains {
            $0.isVisible && $0.occlusionState.contains(.visible) && !String(describing: type(of: $0)).contains("StatusBar")
        }
        if windowVisible { camera.ensureRunning(ip: ip, accessCode: code) } else { camera.stop() }
        let background = UserDefaults.standard.object(forKey: "backgroundMonitoring") as? Bool ?? true
        if windowVisible || background { status.ensureRunning(ip: ip, accessCode: code) } else { status.stop() }
    }

    // Opening the app again (Finder, Spotlight) shows the camera window: a menu bar app has no other visible launch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        viewer.show(under: iconFrame)
        return false
    }

    /// Menu bar icon whose frame follows the printer: color of the print state, dashed when offline,
    /// plain (template) when idle or unknown.
    private func updateIcon() {
        let icon: NSImage
        if status.online == false {
            icon = Self.menuBarIcon(ring: nil, dashed: true)
        } else if status.online == true, let state = status.state, state != .idle {
            icon = Self.menuBarIcon(ring: NSColor(state.color))
        } else {
            icon = Self.menuBarIcon(ring: nil)
        }
        statusItem.button?.image = icon
    }

    private var iconFrame: NSRect? { statusItem.button?.window?.frame }

    /// Click: show the camera window where it was left. Double-click: bring it back under the icon,
    /// for when it is lost on another screen. Right-click (or control-click): the menu.
    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            statusItem.menu = makeMenu()
            statusItem.button?.performClick(nil) // opens the menu
            statusItem.menu = nil // or left clicks would open it too
        } else if event.clickCount == 2 {
            viewer.recall(under: iconFrame)
        } else {
            viewer.show(under: iconFrame)
        }
    }

    private func makeMenu() -> NSMenu {
        func item(_ title: String.LocalizationValue, _ action: Selector, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: String(localized: title, bundle: AppLanguage.bundle), action: action, keyEquivalent: key)
            item.target = self
            return item
        }
        let menu = NSMenu()
        menu.addItem(item("Show the camera", #selector(showViewer)))
        menu.addItem(item("Bring back under the icon", #selector(recallViewer)))
        menu.addItem(.separator())
        for pin in Viewer.Pin.allCases {
            let entry = NSMenuItem(title: pin.title, action: #selector(setPin(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = pin.rawValue
            entry.state = viewer.pin == pin ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        if let release = updates.available {
            menu.addItem(item("Version \(release.version) available", #selector(showSettings)))
        }
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        if updates.currentVersion == nil { menu.addItem(simulationItem()) } // dev builds only
        menu.addItem(.separator())
        menu.addItem(item("Quit Toothpeek", #selector(NSApplication.terminate(_:)), key: "q"))
        menu.items.last?.target = NSApp
        return menu
    }

    /// Dev tool, in English only: pick a fake printer state to test the UI without a printer.
    private func simulationItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Simulate printer", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let real = NSMenuItem(title: "Off (real printer)", action: #selector(simulate(_:)), keyEquivalent: "")
        real.target = self
        real.state = simulation == nil ? .on : .off
        menu.addItem(real)
        menu.addItem(.separator())
        for scenario in Simulation.allCases {
            let entry = NSMenuItem(title: scenario.rawValue, action: #selector(simulate(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = scenario.rawValue
            entry.state = simulation == scenario ? .on : .off
            menu.addItem(entry)
        }
        item.submenu = menu
        return item
    }

    @objc private func simulate(_ sender: NSMenuItem) {
        simulation = (sender.representedObject as? String).flatMap(Simulation.init(rawValue:))
        if let simulation {
            simulation.apply(to: status, camera: camera)
        } else {
            status.endSimulation()
            camera.endSimulation()
            updateConnections()
        }
    }

    @objc private func showViewer() { viewer.show(under: iconFrame) }
    @objc private func recallViewer() { viewer.recall(under: iconFrame) }
    @objc private func setPin(_ sender: NSMenuItem) {
        if let pin = (sender.representedObject as? String).flatMap(Viewer.Pin.init(rawValue:)) { viewer.pin = pin }
    }

    @objc func showSettings() { viewer.showSettings(under: iconFrame) }

    /// Never shown (menu bar app), but it is what routes ⌘, ⌘W ⌘Q and copy/paste in text fields.
    private func installMainMenu() {
        func submenu(_ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem()
            item.submenu = NSMenu()
            items.forEach { item.submenu?.addItem($0) }
            return item
        }
        let main = NSMenu()
        main.addItem(submenu([
            NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","),
            NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]))
        main.addItem(submenu([
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ]))
        NSApp.mainMenu = main
    }
}
