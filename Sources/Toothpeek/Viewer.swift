import AppKit
import Combine
import SwiftUI

/// The camera window: the app's only window besides settings. Resizable, can be pinned above other apps.
final class Viewer: NSObject, ObservableObject, NSWindowDelegate {
    /// Above other windows: on its own desktop, or following every desktop and full-screen app.
    enum Pin: String, CaseIterable {
        case off, here, everywhere

        var next: Pin { self == .off ? .here : self == .here ? .everywhere : .off }

        var title: String {
            switch self {
            case .off: String(localized: "Not pinned", bundle: AppLanguage.bundle)
            case .here: String(localized: "Pinned on this desktop", bundle: AppLanguage.bundle)
            case .everywhere: String(localized: "Pinned on all desktops", bundle: AppLanguage.bundle)
            }
        }

        /// The current mode, then what a click does.
        var help: String {
            switch self {
            case .off: String(localized: "Not pinned · click to keep on top on this desktop", bundle: AppLanguage.bundle)
            case .here: String(localized: "Pinned on this desktop · click to follow on all desktops", bundle: AppLanguage.bundle)
            case .everywhere: String(localized: "Pinned on all desktops · click to unpin", bundle: AppLanguage.bundle)
            }
        }
    }

    // Before 3 modes, "pinned" (a Bool) meant all desktops.
    @Published var pin = UserDefaults.standard.string(forKey: "pin").flatMap(Pin.init(rawValue:))
        ?? (UserDefaults.standard.bool(forKey: "pinned") ? .everywhere : .off) {
        didSet {
            UserDefaults.standard.set(pin.rawValue, forKey: "pin")
            applyPin()
        }
    }
    @Published var showInfo = UserDefaults.standard.object(forKey: "showPrintInfo") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInfo, forKey: "showPrintInfo") }
    }
    private let camera: Camera
    private let status: PrinterStatus
    private let updates: UpdateChecker
    private let form: SettingsForm
    private var window: NSWindow?
    private var frameBeforeSettings: NSRect?
    private var editWatch: AnyCancellable?
    private static let frameName = "viewer"
    private static let defaultSize = NSSize(width: 640, height: 360)
    // ponytail: about the full form's height; a longer form scrolls. Measure the form if it grows a lot.
    private static let settingsSize = NSSize(width: 480, height: 680)

    init(camera: Camera, status: PrinterStatus, updates: UpdateChecker, form: SettingsForm) {
        self.camera = camera
        self.status = status
        self.updates = updates
        self.form = form
        super.init()
        editWatch = form.$editing.sink { [weak self] editing in
            if !editing { DispatchQueue.main.async { self?.restoreAfterSettings() } } // Save, Cancel: once the camera is back
        }
    }

    /// Brings the window to the front where it was left. Under `anchor` (the menu bar icon) the first time,
    /// or when the screen it was on is gone.
    func show(under anchor: NSRect?) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "Toothpeek"
            window.isReleasedWhenClosed = false // closing only hides it
            window.delegate = self
            window.contentView = NSHostingView(rootView: ViewerView(camera: camera, status: status, updates: updates, form: form, viewer: self))
            let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameName)") != nil
            window.setFrameAutosaveName(Self.frameName) // restores the saved frame, if any
            self.window = window
            if !saved { place(under: anchor) }
        }
        guard let window else { return }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { place(under: anchor) }
        applyPin()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // activate() is only a request since macOS 14: when it is turned down the window would stay behind the active app.
        window.orderFrontRegardless()
    }

    /// Default size, just under the menu bar icon: for a window lost on another screen.
    func recall(under anchor: NSRect?) {
        show(under: anchor)
        place(under: anchor)
    }

    /// Settings replace the camera in this window, which cannot be resized meanwhile (the form has a fixed width).
    /// A window too small for the form grows, keeping its top-left corner, and gets its frame back on Save or Cancel.
    /// A big enough window keeps its size.
    func showSettings(under anchor: NSRect?) {
        if !form.editing { form.edit() }
        show(under: anchor)
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        window.styleMask.remove(.resizable)
        guard frameBeforeSettings == nil else { return }
        let content = window.contentRect(forFrameRect: window.frame).size
        guard content.width < Self.settingsSize.width || content.height < Self.settingsSize.height else { return }
        let grown = NSSize(width: max(content.width, Self.settingsSize.width), height: max(content.height, Self.settingsSize.height))
        let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: grown)).size
        var frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
        if let area = window.screen?.visibleFrame { // stay on screen
            frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
            frame.origin.y = max(min(frame.minY, area.maxY - frame.height), area.minY)
        }
        frameBeforeSettings = window.frame
        window.setFrame(frame, display: true, animate: true)
    }

    private func restoreAfterSettings() {
        window?.styleMask.insert(.resizable)
        guard let frame = frameBeforeSettings else { return }
        frameBeforeSettings = nil
        window?.setFrame(frame, display: true, animate: true)
    }

    private func place(under anchor: NSRect?) {
        guard let window, !window.styleMask.contains(.fullScreen),
              let screen = NSScreen.screens.first(where: { anchor.map($0.frame.intersects) ?? false }) ?? NSScreen.main
        else { return }
        let area = screen.visibleFrame
        let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.defaultSize)).size
        let x = min(max((anchor?.midX ?? area.midX) - size.width / 2, area.minX), area.maxX - size.width)
        window.setFrame(NSRect(x: x, y: area.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    func toggleFullScreen() {
        guard let window else { return }
        if !window.styleMask.contains(.fullScreen) {
            // A pinned (auxiliary) window cannot become a full-screen space itself.
            window.level = .normal
            window.collectionBehavior = [.fullScreenPrimary]
        }
        window.toggleFullScreen(nil)
    }

    func windowDidExitFullScreen(_ notification: Notification) { applyPin() }

    private func applyPin() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        window.level = pin == .off ? .normal : .floating
        // All desktops: follow every Space and float over other apps' full-screen windows.
        window.collectionBehavior = pin == .everywhere ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenPrimary]
    }
}

/// Camera frame with a magnifier bubble that follows the cursor.
/// `overlay` sits between the frame and the loupe, pinned to the bottom of the image.
struct CameraImage: View {
    let image: NSImage
    var overlay: AnyView?
    @StateObject private var hover = Hover()
    private let lens: CGFloat = 160

    var body: some View {
        GeometryReader { geo in
            // ponytail: zoom = camera's native pixels (min 2x on screen); tune the factor if the loupe looks too soft/strong.
            let zoom = max(2, image.size.width / max(geo.size.width, 1))
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable()
                if let overlay {
                    overlay.frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                }
                if let p = hover.location {
                    Image(nsImage: image).resizable()
                        .frame(width: geo.size.width * zoom, height: geo.size.height * zoom)
                        .offset(x: lens / 2 - p.x * zoom, y: lens / 2 - p.y * zoom)
                        .frame(width: lens, height: lens, alignment: .topLeading)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                        .shadow(radius: 8)
                        .position(p)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover.location = p
                case .ended: hover.location = nil
                }
            }
        }
        .aspectRatio(image.size, contentMode: .fit)
    }
}

final class Hover: ObservableObject { // not @State: its macro plugin ships only with Xcode, not the CLT
    @Published var location: CGPoint?
}

struct ViewerView: View {
    @ObservedObject var camera: Camera
    let status: PrinterStatus
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var form: SettingsForm
    @ObservedObject var viewer: Viewer
    @AppStorage(AppLanguage.key) private var language = "system"

    var body: some View {
        Group {
            if form.editing {
                ScrollView { SettingsView(form: form, updates: updates).frame(maxWidth: .infinity) }
            } else {
                cameraView
            }
        }
        .frame(minWidth: 320, minHeight: 180)
        .environment(\.locale, Locale(identifier: AppLanguage.resolved(language)))
    }

    /// Image pinned to the top at its own aspect ratio. The print info goes under it when it fits there whole
    /// (a tall window), else over the image: never half on the image, half on the black below.
    private var cameraView: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            GeometryReader { geo in
                let ratio = camera.image.map { $0.size.height / max($0.size.width, 1) } ?? 9.0 / 16
                let height = min(geo.size.height, geo.size.width * ratio)
                ViewThatFits(in: .vertical) {
                    VStack(spacing: 0) {
                        picture(infoOver: false).frame(height: height)
                        if viewer.showInfo { PrintOverlay(status: status) }
                    }
                    picture(infoOver: viewer.showInfo).frame(height: height)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
            HStack(spacing: 10) {
                LightButton(status: status)
                Button { viewer.showInfo.toggle() } label: {
                    Image(systemName: viewer.showInfo ? "info.circle.fill" : "info.circle")
                }
                .help(viewer.showInfo ? LocalizedStringKey("Hide print info") : "Show print info")
                Button { viewer.pin = viewer.pin.next } label: {
                    Image(systemName: viewer.pin == .off ? "pin" : "pin.fill")
                        .foregroundStyle(viewer.pin == .everywhere ? .white : .primary)
                        .background { // a background does not change the button's size
                            if viewer.pin == .everywhere { Circle().fill(Color.blue).frame(width: 22, height: 22) }
                        }
                }
                .help(viewer.pin.help)
                Button { viewer.toggleFullScreen() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Full screen (Esc to exit)")
                Button { viewer.showSettings(under: nil) } label: {
                    Image(systemName: "gearshape")
                        .overlay(alignment: .topTrailing) {
                            if updates.available != nil { Circle().fill(Color.blue).frame(width: 6, height: 6).offset(x: 2, y: -2) }
                        }
                }
                .help(updates.available == nil ? "Settings" : "Settings · update available")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(8)
        }
    }

    @ViewBuilder private func picture(infoOver: Bool) -> some View {
        if let image = camera.image {
            CameraImage(image: image, overlay: infoOver ? AnyView(PrintOverlay(status: status)) : nil)
        } else {
            Text(camera.status).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { if infoOver { PrintOverlay(status: status) } } // e.g. "unreachable"
        }
    }
}
