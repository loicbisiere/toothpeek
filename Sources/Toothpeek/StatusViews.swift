import SwiftUI

/// Print info in the camera window, on a translucent dark card, over or under the image.
/// Over it, drops the details first when the image is too small for them.
struct PrintOverlay: View {
    @ObservedObject var status: PrinterStatus

    var body: some View {
        if status.state == nil, let problem = status.problem {
            ProblemRow(text: problem)
                .padding(10)
                .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 12))
                .environment(\.colorScheme, .dark)
                .padding(12)
                .allowsHitTesting(false)
        } else if status.state != nil {
            ViewThatFits(in: .vertical) {
                card(details: true)
                card(details: false)
            }
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false) // keep the loupe working underneath
        }
    }

    private func card(details: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = status.commandError {
                ProblemRow(text: error)
            }
            PrintSummary(status: status)
            if details {
                Divider().opacity(0.6)
                PrintDetails(status: status)
            }
        }
        .padding(12)
        .frame(maxWidth: 640)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 14))
        .padding(12)
    }
}

/// State pill, file name, percent, progress bar, time left, ETA, layers.
struct PrintSummary: View {
    @ObservedObject var status: PrinterStatus

    var body: some View {
        if let state = status.state {
            let offline = status.online == false
            VStack(alignment: .leading, spacing: 8) {
                if offline {
                    // The report is the last one received: say so instead of showing a print that seems to go on.
                    Label {
                        if let since = status.lastReport {
                            Text("Offline · last update \(Text(since, style: .time))")
                        } else {
                            Text("Offline")
                        }
                    } icon: {
                        Image(systemName: "wifi.slash")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    StatePill(state: state)
                    if let file = status.fileName, state != .idle {
                        Text(verbatim: file).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if status.isActive, let percent = status.percent {
                        Text(verbatim: "\(percent)%").font(.title3.weight(.semibold)).monospacedDigit()
                    }
                }
                if status.isActive {
                    ProgressBar(fraction: Double(status.percent ?? 0) / 100, color: state.color)
                    HStack(spacing: 14) {
                        if let minutes = status.remainingMinutes, !offline { // a stale ETA would drift with every redraw
                            Metric(symbol: "clock", text: Text(verbatim: Self.duration(minutes)), help: "Time remaining")
                            Metric(symbol: "flag.checkered",
                                   text: Text(Date().addingTimeInterval(Double(minutes) * 60), style: .time),
                                   help: "Estimated end")
                        }
                        if let layer = status.layer, let total = status.totalLayers, total > 0 {
                            Metric(symbol: "square.stack.3d.up", text: Text(verbatim: "\(layer)/\(total)"), help: "Layer")
                        }
                    }
                    .opacity(offline ? 0.5 : 1)
                }
            }
        }
    }

    static func duration(_ minutes: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: AppLanguage.resolved()) // follow the app language
        formatter.calendar = calendar
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
    }
}

/// Temperatures, speed, fans, light, Wi-Fi, nozzle, AMS, errors.
struct PrintDetails: View {
    @ObservedObject var status: PrinterStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 8) {
                if let nozzle = status.nozzle {
                    Detail(symbol: "flame", label: "Nozzle", value: temperature(nozzle), color: heat(nozzle))
                }
                if let bed = status.bed {
                    Detail(symbol: "square.bottomhalf.filled", label: "Bed", value: temperature(bed), color: heat(bed))
                }
                if let speed = status.speedLevel {
                    Detail(symbol: "speedometer", label: "Speed",
                           value: Text(speed) + Text(verbatim: " · \(status.speedMagnitude ?? 100)%"), color: .blue)
                }
                if let fan = status.fanPercent("cooling_fan_speed") {
                    Detail(symbol: "fan", label: "Part fan", value: Text(verbatim: "\(fan)%"), color: fan > 0 ? .cyan : .secondary)
                }
                if let fan = status.fanPercent("big_fan1_speed") {
                    Detail(symbol: "fan", label: "Aux fan", value: Text(verbatim: "\(fan)%"), color: fan > 0 ? .cyan : .secondary)
                }
                if let fan = status.fanPercent("big_fan2_speed") {
                    Detail(symbol: "fan", label: "Chamber fan", value: Text(verbatim: "\(fan)%"), color: fan > 0 ? .cyan : .secondary)
                }
                if let light = status.lightOn {
                    Detail(symbol: light ? "lightbulb.fill" : "lightbulb", label: "Light",
                           value: light ? Text("On") : Text("Off"), color: light ? .yellow : .secondary)
                }
                if let dbm = status.wifiDBm {
                    Detail(symbol: "wifi", label: "Wi-Fi", value: Text(verbatim: "\(dbm) dBm"),
                           color: dbm > -60 ? .green : dbm > -75 ? .orange : .red)
                }
                if let nozzle = status.nozzleDescription {
                    Detail(symbol: "smallcircle.filled.circle", label: "Nozzle size", value: Text(verbatim: nozzle))
                }
            }
            if !status.trays.isEmpty {
                AMSStrip(trays: status.trays)
            }
            if status.hasError {
                Label("The printer reports an error", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
            }
        }
    }

    private func temperature(_ t: (current: Double, target: Double)) -> Text {
        t.target > 0
            ? Text(verbatim: "\(Int(t.current.rounded()))° / \(Int(t.target))°")
            : Text(verbatim: "\(Int(t.current.rounded()))°")
    }

    /// Off: grey. Heating or cooling toward target: orange. Holding target: red (hot).
    private func heat(_ t: (current: Double, target: Double)) -> Color {
        guard t.target > 0 else { return .secondary }
        return abs(t.current - t.target) > 3 ? .orange : .red
    }
}

struct AMSStrip: View {
    let trays: [PrinterStatus.Tray]

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "AMS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(trays) { tray in
                HStack(spacing: 5) {
                    Circle()
                        .fill(tray.color)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.primary.opacity(0.3), lineWidth: 0.5))
                        .overlay(Circle().stroke(Color.green, lineWidth: 2).padding(-3).opacity(tray.active ? 1 : 0))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: tray.type).font(.caption2.weight(tray.active ? .bold : .regular))
                        if let remain = tray.remain {
                            Text(verbatim: "\(remain)%").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct ProblemRow: View {
    let text: String

    var body: some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.caption)
    }
}

struct ProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color.gradient).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

struct StatePill: View {
    let state: PrinterStatus.State

    var body: some View {
        Label {
            Text(state.label)
        } icon: {
            Image(systemName: state.symbol)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(state.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(state.color.opacity(0.18), in: Capsule())
    }
}

struct Metric: View {
    let symbol: String
    let text: Text
    let help: LocalizedStringKey

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            text.monospacedDigit()
        }
        .font(.caption)
        .help(help)
    }
}

struct Detail: View {
    let symbol: String
    let label: LocalizedStringKey
    let value: Text
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                value.font(.caption.weight(.medium)).monospacedDigit()
            }
        }
    }
}

/// Chamber light switch: the first command Toothpeek sends (exploration, see the README roadmap).
struct LightButton: View {
    @ObservedObject var status: PrinterStatus

    var body: some View {
        // While a command is in flight, show the requested state, pulsing, and ignore clicks until the printer confirms.
        let pending = status.pendingLight != nil
        let on = status.pendingLight ?? status.lightOn ?? false
        Button {
            status.setLight(!on)
        } label: {
            Image(systemName: on ? "lightbulb.fill" : "lightbulb")
                .foregroundStyle(on ? Color.yellow : Color.secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: pending)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(!status.canSendCommands && !pending) // keep full color while pending; setLight ignores clicks then
        .allowsHitTesting(!pending)
        .help(status.commandError.map { Text(verbatim: $0) } ?? (on ? Text("Turn the chamber light off") : Text("Turn the chamber light on")))
    }
}
