import Foundation
import Network
import SwiftUI

/// Live print status from the printer's local MQTT broker (TLS on 8883, user `bblp` + access code).
/// Read-only: we only subscribe and ask for a full report ("pushall"), never send print commands.
final class PrinterStatus: ObservableObject {
    @Published private(set) var report: [String: Any] = [:]
    /// Why there is no report, shown instead of the print panel. Set when an attempt dies before the broker accepts us.
    @Published private(set) var problem: String?
    /// nil until the first connection attempt settles (or after stop()).
    @Published private(set) var online: Bool?
    /// When the last report arrived, shown while the printer is offline.
    @Published private(set) var lastReport: Date?
    /// Set when the printer rejects a command (e.g. the light), cleared by the next accepted one.
    @Published private(set) var commandError: String?
    /// Light state requested and not yet confirmed by a report; nil when no light command is in flight.
    @Published private(set) var pendingLight: Bool?
    var onStateChange: ((State, State) -> Void)?
    var onOnlineChange: ((Bool) -> Void)?

    private var connection: NWConnection?
    private var generation = 0
    private var ip = ""
    private var accessCode = ""
    private var serial = ""
    private var lastPacket = Date()
    private var pingTimer: Timer?
    private var accepted = false
    private var reachedPrinter = false // TLS connected this attempt: tells "wrong code" from "unreachable"
    private var trustFailure: PrinterTrust.Failure?
    private var running = false
    private var lastState: State?
    private var offlineCheck: DispatchWorkItem?
    /// A fake printer (dev builds, see Simulation) replaces the connection until endSimulation().
    private(set) var simulated = false

    /// Starts unless already connected (or retrying) to this printer with this code.
    func ensureRunning(ip: String, accessCode: String) {
        guard !simulated else { return }
        guard !running || ip != self.ip || accessCode != self.accessCode else { return }
        start(ip: ip, accessCode: accessCode)
    }

    /// Deliberate stop (window closed, no background monitoring): not an "offline" event.
    func stop() {
        guard !simulated else { return }
        connection?.cancel()
        pingTimer?.invalidate()
        offlineCheck?.cancel()
        offlineCheck = nil
        generation += 1
        running = false
        online = nil
        lastState = nil // after a deliberate stop the first report is a new baseline, not a transition
    }

    func start(ip: String, accessCode: String) {
        connection?.cancel()
        pingTimer?.invalidate()
        generation += 1
        if ip != self.ip || accessCode != self.accessCode {
            report = [:]
            problem = nil
            lastState = nil
            online = nil
        }
        accepted = false
        reachedPrinter = false
        trustFailure = nil
        self.ip = ip
        self.accessCode = accessCode
        guard !ip.isEmpty, !accessCode.isEmpty else { return }
        running = true

        let gen = generation
        let tls = NWProtocolTLS.Options()
        // Genuine Bambu printer, and the one set up? Its serial (certificate common name) is also the MQTT topic.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, done in
            switch PrinterTrust.check(trust) {
            case .success(let serial):
                self?.serial = serial
                done(true)
            case .failure(let failure):
                self?.trustFailure = failure
                done(false)
            }
        }, .main)
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: 8883, using: NWParameters(tls: tls))
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, gen == self.generation else { return }
            switch state {
            case .ready:
                self.reachedPrinter = true
                let connect = Self.string("MQTT") + Data([4, 0xC2, 0, 60]) // v3.1.1, user+password, keepalive 60 s
                    + Self.string("toothpeek-\(UUID().uuidString.prefix(8))") + Self.string("bblp") + Self.string(accessCode)
                conn.send(content: Self.packet(0x10, connect), completion: .idempotent)
                self.lastPacket = Date()
                self.readPacket(conn, gen: gen)
            case .waiting, .failed:
                self.fail(gen)
            default:
                break
            }
        }
        conn.start(queue: .main)
        // An unreachable host can stay "preparing" for over a minute: give up after 10 s and retry.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, gen == self.generation, !self.reachedPrinter else { return }
            self.fail(gen)
        }
    }

    /// Shows `report` as if the printer sent it, with the same state and online/offline callbacks (notifications).
    func simulate(_ report: [String: Any], online: Bool = true, problem: String? = nil) {
        connection?.cancel()
        pingTimer?.invalidate()
        offlineCheck?.cancel()
        offlineCheck = nil
        generation += 1
        running = false
        simulated = true
        pendingLight = nil
        commandError = nil
        self.problem = problem
        if let was = self.online, was != online { onOnlineChange?(online) }
        self.online = online
        self.report = report
        lastReport = Date()
        if let state {
            if let lastState, lastState != state { onStateChange?(lastState, state) }
            lastState = state
        }
    }

    /// Back to the real printer: the next ensureRunning() connects.
    func endSimulation() {
        simulated = false
        report = [:]
        problem = nil
        online = nil
        lastState = nil
    }

    // MARK: MQTT plumbing (just enough of 3.1.1 for one subscription)

    private func handle(_ header: UInt8, _ body: [UInt8], conn: NWConnection, gen: Int) {
        switch header >> 4 {
        case 2: // CONNACK
            guard body.count == 2, body[1] == 0, !serial.isEmpty else { return fail(gen) }
            accepted = true
            problem = nil
            offlineCheck?.cancel()
            offlineCheck = nil
            if online == false { onOnlineChange?(true) }
            online = true
            conn.send(content: Self.packet(0x82, Data([0, 1]) + Self.string("device/\(serial)/report") + Data([0])),
                      completion: .idempotent)
            let pushall = #"{"pushing":{"sequence_id":"0","command":"pushall"}}"#
            conn.send(content: Self.packet(0x30, Self.string("device/\(serial)/request") + Data(pushall.utf8)),
                      completion: .idempotent)
            pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                guard let self, gen == self.generation else { return }
                if Date().timeIntervalSince(self.lastPacket) > 90 { return self.fail(gen) }
                conn.send(content: Data([0xC0, 0]), completion: .idempotent) // PINGREQ
            }
        case 3: // PUBLISH
            guard body.count > 2 else { return }
            let topicLength = Int(body[0]) << 8 | Int(body[1])
            let start = 2 + topicLength + ((header >> 1) & 3 > 0 ? 2 : 0)
            guard start <= body.count,
                  let json = try? JSONSerialization.jsonObject(with: Data(body[start...])) as? [String: Any] else { return }
            if let reply = json["system"] as? [String: Any] { return handleCommandReply(reply) }
            guard let print = json["print"] as? [String: Any] else { return }
            // P1 printers send deltas: merge them. ponytail: shallow merge, fine while nested objects (ams) come whole.
            report.merge(print) { _, new in new }
            lastReport = Date()
            if let target = pendingLight, lightOn == target { pendingLight = nil } // confirmed by the printer
            if let state {
                if let lastState, lastState != state { onStateChange?(lastState, state) }
                // The first report after start() only sets the baseline. Kept across retries on purpose:
                // a print that finished during a Wi-Fi drop is still announced when the connection comes back.
                lastState = state
            }
        default:
            break
        }
    }

    // MARK: Commands (only the chamber light so far; see docs/protocol.md "Commands")

    private var commandSequence = 0

    var canSendCommands: Bool { (accepted || simulated) && lightOn != nil && pendingLight == nil }

    func setLight(_ on: Bool) {
        if simulated { return report["lights_report"] = [["node": "chamber_light", "mode": on ? "on" : "off"]] }
        guard canSendCommands, let connection else { return }
        commandSequence += 1
        commandError = nil
        pendingLight = on
        let sequence = commandSequence
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.pendingLight != nil, self.commandSequence == sequence else { return }
            self.pendingLight = nil
            self.commandError = String(localized: "No answer from the printer to the light command.", bundle: AppLanguage.bundle)
        }
        let command: [String: Any] = ["system": [
            "sequence_id": "\(commandSequence)", "command": "ledctrl", "led_node": "chamber_light",
            "led_mode": on ? "on" : "off", "led_on_time": 500, "led_off_time": 500, "loop_times": 0, "interval_time": 0,
        ]]
        guard let payload = try? JSONSerialization.data(withJSONObject: command) else { return }
        connection.send(content: Self.packet(0x30, Self.string("device/\(serial)/request") + payload), completion: .idempotent)
    }

    /// The printer echoes each command with "result": "success" or a failure "reason"; the new light state
    /// itself arrives in the next report (lights_report).
    private func handleCommandReply(_ reply: [String: Any]) {
        guard reply["command"] as? String == "ledctrl" else { return }
        if reply["result"] as? String == "success" {
            commandError = nil
        } else {
            pendingLight = nil
            let reason = reply["reason"] as? String ?? "?"
            commandError = String(localized: "The printer rejected the light command (\(reason)).", bundle: AppLanguage.bundle)
        }
    }

    private func readPacket(_ conn: NWConnection, gen: Int) {
        read(conn, 1, gen: gen) { header in
            self.readLength(conn, gen: gen) { length in
                let done = { (body: [UInt8]) in
                    self.lastPacket = Date()
                    self.handle(header[0], body, conn: conn, gen: gen)
                    self.readPacket(conn, gen: gen)
                }
                // Printer reports are a few KB; refuse anything huge rather than buffering it.
                guard length <= 1_000_000 else { return self.fail(gen) }
                if length == 0 { done([]) } else { self.read(conn, length, gen: gen, done) }
            }
        }
    }

    private func readLength(_ conn: NWConnection, gen: Int, value: Int = 0, shift: Int = 0, _ then: @escaping (Int) -> Void) {
        read(conn, 1, gen: gen) { byte in
            let value = value | Int(byte[0] & 0x7F) << shift
            guard byte[0] & 0x80 != 0 else { return then(value) }
            guard shift < 21 else { return self.fail(gen) } // MQTT lengths use at most 4 bytes
            self.readLength(conn, gen: gen, value: value, shift: shift + 7, then)
        }
    }

    private func read(_ conn: NWConnection, _ count: Int, gen: Int, _ then: @escaping ([UInt8]) -> Void) {
        conn.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, _ in
            guard let self, gen == self.generation else { return }
            guard let data, data.count == count else { return self.fail(gen) }
            then([UInt8](data))
        }
    }

    private func fail(_ gen: Int) {
        guard gen == generation else { return }
        pendingLight = nil // the command may be lost with the connection
        if let trustFailure {
            problem = trustFailure.message
        } else if !accepted {
            // Connected but closed before CONNACK: the broker does that on a wrong access code.
            problem = reachedPrinter
                ? String(localized: "Print info unavailable: the printer refused the connection. Check the access code.",
                         bundle: AppLanguage.bundle)
                : String(localized: "Printer unreachable at \(ip).", bundle: AppLanguage.bundle)
        }
        if online == nil {
            online = false // never reached since launch: silent, but a later success counts as "back online"
        } else if online == true, offlineCheck == nil {
            // Debounced: Wi-Fi blips reconnect within seconds; a printer turned off does not.
            let check = DispatchWorkItem { [weak self] in
                guard let self, self.running, self.online == true else { return }
                self.offlineCheck = nil
                self.online = false
                self.onOnlineChange?(false)
            }
            offlineCheck = check
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: check)
        }
        connection?.cancel()
        pingTimer?.invalidate()
        generation += 1
        let retryGen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, retryGen == self.generation else { return }
            self.start(ip: self.ip, accessCode: self.accessCode)
        }
    }

    private static func packet(_ type: UInt8, _ body: Data) -> Data {
        var data = Data([type])
        var n = body.count
        repeat {
            var byte = UInt8(n % 128)
            n /= 128
            if n > 0 { byte |= 0x80 }
            data.append(byte)
        } while n > 0
        return data + body
    }

    private static func string(_ s: String) -> Data {
        let bytes = Data(s.utf8)
        return Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)]) + bytes
    }
}

// MARK: Typed view of the report (field names from the printer's "print" JSON)

extension PrinterStatus {
    enum State {
        case idle, preparing, printing, paused, finished, failed

        var label: LocalizedStringKey {
            switch self {
            case .idle: "Idle"
            case .preparing: "Preparing"
            case .printing: "Printing"
            case .paused: "Paused"
            case .finished: "Finished"
            case .failed: "Failed"
            }
        }

        var color: Color {
            switch self {
            case .idle: .gray
            case .preparing: .blue
            case .printing: .green
            case .paused: .orange
            case .finished: .teal
            case .failed: .red
            }
        }

        var symbol: String {
            switch self {
            case .idle: "moon.zzz.fill"
            case .preparing: "hourglass"
            case .printing: "printer.fill"
            case .paused: "pause.fill"
            case .finished: "checkmark"
            case .failed: "exclamationmark.triangle.fill"
            }
        }

        var isActive: Bool { [.printing, .preparing, .paused].contains(self) }
    }

    struct Tray: Identifiable {
        let id: Int
        let type: String
        let color: Color
        let colorHex: String
        let remain: Int?
        let active: Bool
    }

    var state: State? {
        switch report["gcode_state"] as? String {
        case "RUNNING": .printing
        case "PREPARE", "SLICING": .preparing
        case "PAUSE": .paused
        case "FINISH": .finished
        case "FAILED": .failed
        case "IDLE": .idle
        default: nil
        }
    }

    var isActive: Bool { state?.isActive ?? false }
    var fileName: String? { (report["subtask_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var percent: Int? { number("mc_percent").map(Int.init) }
    var remainingMinutes: Int? { number("mc_remaining_time").map(Int.init) }
    var layer: Int? { number("layer_num").map(Int.init) }
    var totalLayers: Int? { number("total_layer_num").map(Int.init) }
    var nozzle: (current: Double, target: Double)? { pair("nozzle_temper", "nozzle_target_temper") }
    var bed: (current: Double, target: Double)? { pair("bed_temper", "bed_target_temper") }
    var speedMagnitude: Int? { number("spd_mag").map(Int.init) }
    var nozzleDescription: String? { (report["nozzle_diameter"] as? String).map { "\($0) mm" } }
    var wifiDBm: Int? { (report["wifi_signal"] as? String).flatMap { Int($0.replacingOccurrences(of: "dBm", with: "")) } }
    /// Bambu reports a user cancel as FAILED with error 0x0300400C ("The task was canceled").
    var wasCanceled: Bool { number("print_error").map(Int.init) == 0x0300_400C }
    var hasError: Bool { ((number("print_error") ?? 0) != 0 && !wasCanceled) || !((report["hms"] as? [Any])?.isEmpty ?? true) }

    var speedLevel: LocalizedStringKey? {
        switch number("spd_lvl").map(Int.init) {
        case 1: "Silent"
        case 2: "Standard"
        case 3: "Sport"
        case 4: "Ludicrous"
        default: nil
        }
    }

    /// Fan speeds come as a 0–15 "gear"; shown as a percentage.
    func fanPercent(_ key: String) -> Int? {
        number(key).map { Int(($0 / 15 * 100 / 10).rounded() * 10) }
    }

    var lightOn: Bool? {
        let lights = report["lights_report"] as? [[String: Any]]
        return (lights?.first { $0["node"] as? String == "chamber_light" }?["mode"] as? String).map { $0 == "on" }
    }

    var trays: [Tray] {
        guard let ams = report["ams"] as? [String: Any], let units = ams["ams"] as? [[String: Any]] else { return [] }
        let current = Int(ams["tray_now"] as? String ?? "")
        return units.enumerated().flatMap { unit, info in
            (info["tray"] as? [[String: Any]] ?? []).compactMap { tray -> Tray? in
                guard let id = Int(tray["id"] as? String ?? ""), let type = tray["tray_type"] as? String, !type.isEmpty else { return nil }
                let index = unit * 4 + id
                return Tray(id: index, type: type, color: Color(hex: tray["tray_color"] as? String), colorHex: tray["tray_color"] as? String ?? "",
                            remain: (tray["remain"] as? NSNumber).map(\.intValue).flatMap { $0 >= 0 ? $0 : nil },
                            active: index == current)
            }
        }
    }

    private func number(_ key: String) -> Double? {
        (report[key] as? NSNumber)?.doubleValue ?? (report[key] as? String).flatMap(Double.init)
    }

    private func pair(_ current: String, _ target: String) -> (current: Double, target: Double)? {
        guard let c = number(current) else { return nil }
        return (c, number(target) ?? 0)
    }
}


extension Color {
    /// "RRGGBB" or "RRGGBBAA" as sent by the printer for filament colors.
    init(hex: String?) {
        guard let hex, hex.count >= 6, let v = UInt32(hex.prefix(6), radix: 16) else { self = .gray; return }
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
