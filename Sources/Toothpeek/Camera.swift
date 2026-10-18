import AppKit
import Network

/// Streams JPEG frames from a Bambu P1/A1 camera over LAN (TLS on port 6000).
/// Protocol: see docs/protocol.md. Everything runs on the main queue.
final class Camera: ObservableObject {
    @Published var image: NSImage?
    @Published var status = String(localized: "Not configured", bundle: AppLanguage.bundle)
    @Published var live = false
    var onFrame: ((Data) -> Void)?
    private(set) var lastJPEG: Data?

    private var connection: NWConnection?
    private var generation = 0
    private var ip = ""
    private var accessCode = ""
    private var lastFrame = Date()
    private var trustFailure: PrinterTrust.Failure?
    private var running = false
    private var simulated = false

    /// Starts unless already streaming from this printer with this code.
    func ensureRunning(ip: String, accessCode: String) {
        guard !simulated else { return }
        guard !running || ip != self.ip || accessCode != self.accessCode else { return }
        start(ip: ip, accessCode: accessCode)
    }

    func stop() {
        guard !simulated else { return }
        connection?.cancel()
        generation += 1
        running = false
        live = false
    }

    /// A still test frame instead of the stream (dev builds, see Simulation). No frame: a printer that cannot be reached.
    func simulate(frame: Bool) {
        connection?.cancel()
        generation += 1
        running = false
        simulated = true
        lastJPEG = frame ? Simulation.frame : nil
        image = lastJPEG.flatMap(NSImage.init(data:))
        status = frame ? "Simulated camera" : String(localized: "Connecting to \(Simulation.ip)…", bundle: AppLanguage.bundle)
        live = frame
    }

    func endSimulation() {
        simulated = false
        live = false
        image = nil
    }

    func start(ip: String, accessCode: String) {
        connection?.cancel()
        generation += 1
        self.ip = ip
        self.accessCode = accessCode
        live = false
        trustFailure = nil
        guard !ip.isEmpty, !accessCode.isEmpty else { status = String(localized: "Not configured", bundle: AppLanguage.bundle); return }
        running = true

        let tls = NWProtocolTLS.Options()
        // Only send the access code to a genuine Bambu printer, the one set up (PrinterTrust).
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, done in
            if case .failure(let failure) = PrinterTrust.check(trust) {
                self?.trustFailure = failure
                return done(false)
            }
            done(true)
        }, .main)
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: 6000, using: NWParameters(tls: tls))
        connection = conn
        status = String(localized: "Connecting to \(ip)…", bundle: AppLanguage.bundle)

        let gen = generation
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, gen == self.generation else { return }
            switch state {
            case .ready:
                conn.send(content: Self.authPacket(accessCode), completion: .contentProcessed { _ in })
                self.lastFrame = Date()
                self.readFrame(conn, gen: gen)
            case .waiting(let error), .failed(let error):
                self.fail("\(error)", gen: gen)
            default:
                break
            }
        }
        conn.start(queue: .main)
    }

    /// One frame, then disconnect: for notifications, so no video flows in the background.
    /// Calls back with nil after 10 s.
    static func grabFrame(_ done: @escaping (Data?) -> Void) {
        let once = Camera()
        var finished = false
        let finish = { (data: Data?) in
            guard !finished else { return }
            finished = true
            once.onFrame = nil
            once.stop()
            done(data)
        }
        once.onFrame = { finish($0) }
        once.start(ip: UserDefaults.standard.string(forKey: "printerIP") ?? "",
                   accessCode: AccessCode.value)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(nil) }
    }

    static func authPacket(_ accessCode: String) -> Data {
        var data = Data()
        for value: UInt32 in [0x40, 0x3000, 0, 0] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        for field in ["bblp", accessCode] {
            let bytes = Data(field.utf8.prefix(32))
            data.append(bytes)
            data.append(Data(count: 32 - bytes.count))
        }
        return data
    }

    private func readFrame(_ conn: NWConnection, gen: Int) {
        // The printer can stop sending without closing the socket (sleep, Wi-Fi drop).
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, gen == self.generation, Date().timeIntervalSince(self.lastFrame) > 10 else { return }
            self.fail(String(localized: "no frame for 10s", bundle: AppLanguage.bundle), gen: gen)
        }
        conn.receive(minimumIncompleteLength: 16, maximumLength: 16) { [weak self] header, _, _, error in
            guard let self, gen == self.generation else { return }
            guard let header, header.count == 16 else { return self.fail(error.map { "\($0)" } ?? String(localized: "connection closed", bundle: AppLanguage.bundle), gen: gen) }
            let b = [UInt8](header)
            let size = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16
            guard size > 0, size < 5_000_000 else { return self.fail(String(localized: "bad frame size \(size)", bundle: AppLanguage.bundle), gen: gen) }

            conn.receive(minimumIncompleteLength: size, maximumLength: size) { data, _, _, error in
                guard gen == self.generation else { return }
                guard let data, data.count == size else { return self.fail(error.map { "\($0)" } ?? String(localized: "connection closed", bundle: AppLanguage.bundle), gen: gen) }
                self.lastFrame = Date()
                self.lastJPEG = data
                if let img = NSImage(data: data) {
                    self.image = img
                    self.status = String(localized: "Live · \(self.ip)", bundle: AppLanguage.bundle)
                    self.live = true
                }
                self.onFrame?(data)
                self.readFrame(conn, gen: gen)
            }
        }
    }

    private func fail(_ reason: String, gen: Int) {
        connection?.cancel()
        generation += 1 // drop callbacks from the dead connection
        live = false
        status = trustFailure?.message ?? String(localized: "Disconnected (\(reason)), retrying…", bundle: AppLanguage.bundle)
        let retryGen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, retryGen == self.generation else { return }
            self.start(ip: self.ip, accessCode: self.accessCode)
        }
    }
}
