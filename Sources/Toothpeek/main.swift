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

ToothpeekApp.main()

struct ToothpeekApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            ContentView(camera: delegate.camera, status: delegate.status, viewer: delegate.viewer, updates: delegate.updates)
        } label: {
            MenuBarLabel(status: delegate.status)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let camera = Camera()
    let status = PrinterStatus()
    let viewer = Viewer()
    let updates = UpdateChecker()
    private lazy var notifier = Notifier(camera: camera)

    // static, not main.swift globals: those are initialized in top-level order, i.e. after ToothpeekApp.main() runs.
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
        iconCache[key] = image
        return image
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, no Dock icon
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
        viewer.show(camera: camera, status: status)
        return false
    }
}

struct ContentView: View {
    @ObservedObject var camera: Camera
    let status: PrinterStatus
    let viewer: Viewer
    @ObservedObject var updates: UpdateChecker
    @StateObject private var form = SettingsForm() // not @State: its macro plugin ships only with Xcode, not the CLT
    @AppStorage(AppLanguage.key) private var language = "system"

    var body: some View {
        Group {
            if form.editing {
                SettingsView(form: form, updates: updates) // saving changes the defaults, which reconnects (AppDelegate.updateConnections)
            } else {
                VStack(spacing: 8) {
                    if let image = camera.image {
                        // Explicit 16:9 size: the menu bar window otherwise sizes itself from the image's tiny ideal size.
                        CameraImage(image: image).frame(width: 460, height: 259)
                    } else {
                        ProgressView().frame(width: 460, height: 259)
                    }
                    PrintPanel(status: status)
                    HStack(spacing: 6) {
                        Circle().fill(camera.live ? Color.green : Color.orange).frame(width: 7, height: 7)
                        Text(camera.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        LightButton(status: status)
                        iconButton("macwindow.on.rectangle", help: "Open in a resizable window you can pin on top") {
                            viewer.show(camera: camera, status: status)
                        }
                        iconButton("gearshape", help: updates.available == nil ? "Settings" : "Settings · update available") { form.edit() }
                            .overlay(alignment: .topTrailing) {
                                if updates.available != nil {
                                    Circle().fill(Color.blue).frame(width: 6, height: 6).offset(x: -2, y: 1)
                                }
                            }
                        iconButton("power", help: "Quit Toothpeek") { NSApp.terminate(nil) }
                    }
                }
                .padding(10)
            }
        }
        .frame(width: 480)
        .background(GeometryReader { WindowFitter(size: $0.size) })
        .environment(\.locale, Locale(identifier: AppLanguage.resolved(language)))
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// The MenuBarExtra window grows with its content but keeps its height when the content shrinks
/// (leaving settings, hiding details), so the content sits low under an empty band.
/// Refit the window to the content, keeping its top edge under the menu bar.
struct WindowFitter: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { // the view has no window yet on first layout
            guard let window = view.window else { return }
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            guard abs(frame.height - window.frame.height) > 0.5 else { return }
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
    }
}

/// Menu bar icon whose frame follows the printer: color of the print state, dashed when offline,
/// plain (template) when idle or unknown.
struct MenuBarLabel: View {
    @ObservedObject var status: PrinterStatus

    var body: some View {
        let icon: NSImage = {
            if status.online == false { return AppDelegate.menuBarIcon(ring: nil, dashed: true) }
            guard status.online == true, let state = status.state, state != .idle else { return AppDelegate.menuBarIcon(ring: nil) }
            return AppDelegate.menuBarIcon(ring: NSColor(state.color))
        }()
        Image(nsImage: icon).renderingMode(icon.isTemplate ? .template : .original)
    }
}
