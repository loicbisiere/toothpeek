import AppKit

/// Fake printer for dev builds: drives the UI, the menu bar icon and the notifications without a real printer.
/// Picked from the menu bar icon's right-click menu ("Simulate printer"), never shown in release builds.
/// For screenshots: TOOTHPEEK_SIMULATE=printing (a case name) starts on it, TOOTHPEEK_SIMULATE_FRAME=photo.jpg
/// replaces the drawn camera frame.
enum Simulation: String, CaseIterable {
    case preparing = "Preparing"
    case printing = "Printing"
    case paused = "Paused"
    case finished = "Finished"
    case canceled = "Canceled"
    case failed = "Failed (error)"
    case idle = "Idle"
    case offline = "Offline (while printing)"
    case unreachable = "Unreachable"

    static let ip = "192.168.1.42"

    func apply(to status: PrinterStatus, camera: Camera) {
        camera.simulate(frame: ![.offline, .unreachable].contains(self))
        switch self {
        case .preparing: status.simulate(Self.report("PREPARE", ["mc_percent": 0, "layer_num": 0, "mc_remaining_time": 62]))
        case .printing: status.simulate(Self.report("RUNNING"))
        case .paused: status.simulate(Self.report("PAUSE"))
        case .finished:
            status.simulate(Self.report("FINISH", ["mc_percent": 100, "mc_remaining_time": 0, "layer_num": 210,
                                                   "nozzle_target_temper": 0, "bed_target_temper": 0]))
        case .canceled: status.simulate(Self.report("FAILED", ["print_error": 0x0300_400C]))
        case .failed: status.simulate(Self.report("FAILED", ["print_error": 0x0700_8001]))
        case .idle: status.simulate(Self.report("IDLE", ["subtask_name": "", "mc_percent": 0, "mc_remaining_time": 0]))
        case .offline: status.simulate(Self.report("RUNNING"), online: false)
        case .unreachable:
            status.simulate([:], online: false,
                            problem: String(localized: "Printer unreachable at \(Self.ip).", bundle: AppLanguage.bundle))
        }
    }

    /// A P1S mid-print with an AMS, as the printer reports it; `changes` override fields.
    private static func report(_ state: String, _ changes: [String: Any] = [:]) -> [String: Any] {
        let tray = { (id: String, type: String, color: String, remain: Int) -> [String: Any] in
            ["id": id, "tray_type": type, "tray_color": color, "remain": remain]
        }
        let base: [String: Any] = [
            "gcode_state": state, "subtask_name": "3DBenchy", "mc_percent": 42, "mc_remaining_time": 37,
            "layer_num": 87, "total_layer_num": 210, "print_error": 0, "hms": [Any](),
            "nozzle_temper": 219.6, "nozzle_target_temper": 220, "bed_temper": 54.8, "bed_target_temper": 55,
            "spd_lvl": 2, "spd_mag": 100, "nozzle_diameter": "0.4", "wifi_signal": "-52dBm",
            "cooling_fan_speed": "15", "big_fan1_speed": "10", "big_fan2_speed": "0",
            "lights_report": [["node": "chamber_light", "mode": "on"]],
            "ams": ["tray_now": "1", "ams": [["tray": [
                tray("0", "PLA", "F2F2F2FF", 80), tray("1", "PETG", "1E88E5FF", 35),
                tray("2", "PLA", "E53935FF", 100), tray("3", "TPU", "212121FF", 12),
            ]]]] as [String: Any],
        ]
        return base.merging(changes) { _, new in new }
    }

    static let frame: Data? = ProcessInfo.processInfo.environment["TOOTHPEEK_SIMULATE_FRAME"]
        .flatMap { FileManager.default.contents(atPath: $0) } ?? drawnFrame

    /// Stand-in camera frame: a dark chamber with a print bed, labeled.
    private static let drawnFrame: Data? = {
        let size = NSSize(width: 1280, height: 720)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: NSColor(white: 0.28, alpha: 1), ending: NSColor(white: 0.07, alpha: 1))?
            .draw(in: NSRect(origin: .zero, size: size), angle: -90)
        NSColor(white: 0.4, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 240, y: 110, width: 800, height: 36), xRadius: 6, yRadius: 6).fill()
        let label = "Simulated camera" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 56, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.55),
        ]
        let labelSize = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: (size.width - labelSize.width) / 2, y: 380), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }()
}
