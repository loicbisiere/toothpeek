import Foundation

/// Fake printer for dev builds: drives the UI, the menu bar icon and the notifications without a real printer.
/// Picked from the menu bar icon's right-click menu ("Simulate printer"), never shown in release builds.
/// For screenshots: TOOTHPEEK_SIMULATE=printing (a case name) starts on it, TOOTHPEEK_SIMULATE_FRAME=photo.jpg
/// replaces the camera frame.
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

    /// A real P1S frame (docs/images/simulated-camera.jpg), bundled in dev builds only. None under `swift run`:
    /// the window then shows the camera status text.
    static let frame: Data? = (ProcessInfo.processInfo.environment["TOOTHPEEK_SIMULATE_FRAME"]
        ?? Bundle.main.path(forResource: "simulated-camera", ofType: "jpg"))
        .flatMap { FileManager.default.contents(atPath: $0) }
}
