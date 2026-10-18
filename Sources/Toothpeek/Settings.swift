import ServiceManagement
import SwiftUI

/// App language, switchable live: SwiftUI views get it through `.environment(\.locale)`,
/// plain strings through `String(localized:bundle: AppLanguage.bundle)`.
enum AppLanguage {
    static let key = "appLanguage"

    /// "en" or "fr". The "system" choice follows macOS between the two, and falls back to English.
    static func resolved(_ choice: String? = UserDefaults.standard.string(forKey: key)) -> String {
        guard let choice, choice != "system" else { return Bundle.preferredLocalizations(from: ["en", "fr"]).first ?? "en" }
        return choice
    }

    static var bundle: Bundle {
        Bundle.main.path(forResource: resolved(), ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}

/// Draft settings: nothing is persisted or applied until Save.
final class SettingsForm: ObservableObject {
    @Published var ip = ""
    @Published var code = ""
    @Published var editing = false
    @Published var showCodeHelp = false
    @Published var language = "system"
    @Published var loginError: String?
    @Published var notificationsDenied = false

    init() {
        load()
        editing = !isConfigured
    }

    var isConfigured: Bool {
        !(UserDefaults.standard.string(forKey: "printerIP") ?? "").isEmpty
            && !AccessCode.value.isEmpty
    }

    /// Bambu access codes are 8 characters. The camera only checks the first 8, MQTT checks all of them.
    var codeIsValid: Bool { code.count == 8 }

    func edit() {
        load() // drop any unsaved draft from a cancelled edit
        editing = true
    }

    func save() {
        UserDefaults.standard.set(language, forKey: AppLanguage.key) // views re-render through @AppStorage
        UserDefaults.standard.set(ip, forKey: "printerIP")
        AccessCode.value = code
        UserDefaults.standard.removeObject(forKey: PrinterTrust.serialKey) // saving = (re)accepting the printer at this IP
        editing = false
    }

    private func load() {
        ip = UserDefaults.standard.string(forKey: "printerIP") ?? ""
        code = AccessCode.value
        language = UserDefaults.standard.string(forKey: AppLanguage.key) ?? "system"
    }

    // Source of truth is macOS itself (System Settings > Login Items), not a stored flag.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginError = nil
            } catch {
                loginError = String(localized: "Login item: \(error.localizedDescription) (only works from Toothpeek.app)", bundle: AppLanguage.bundle)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var form: SettingsForm
    let updates: UpdateChecker
    @StateObject private var discovery = Discovery()
    @AppStorage("backgroundMonitoring") private var background = true
    @AppStorage(Notifier.enabledKey) private var notifications = false
    @AppStorage(Notifier.imagesKey) private var notificationImages = true

    private let codeHelp: LocalizedStringKey =
        "8-character code shown on the printer's screen: Settings (gear icon) > WLAN, below the IP address."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Settings").font(.headline)
                    Text(verbatim: "Toothpeek").font(.caption).foregroundStyle(.secondary)
                }
            }

            section("Printer") {
                row("IP address") {
                    TextField(text: $form.ip) { Text(verbatim: "192.168.1.42") }
                        .textFieldStyle(.roundedBorder)
                }
                Divider()
                row("Access code") {
                    SecureField("8 characters", text: $form.code).textFieldStyle(.roundedBorder)
                        .overlay(alignment: .trailing) {
                            if !form.code.isEmpty, !form.codeIsValid {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).padding(.trailing, 6)
                                    .help("The access code has exactly 8 characters.")
                            }
                        }
                    Button { form.showCodeHelp.toggle() } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(codeHelp)
                    .popover(isPresented: $form.showCodeHelp, arrowEdge: .trailing) {
                        Text(codeHelp).padding(12).frame(width: 260).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            section("Found on your network") {
                if discovery.printers.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching…").foregroundStyle(.secondary)
                    }
                }
                ForEach(discovery.printers, id: \.ip) { printer in
                    Button { form.ip = printer.ip } label: {
                        HStack {
                            Image(systemName: "printer.fill").foregroundStyle(.secondary)
                            Text(verbatim: printer.name)
                            Text(verbatim: printer.model).foregroundStyle(.secondary)
                            Spacer()
                            Text(verbatim: printer.ip).monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName: "checkmark").foregroundStyle(.tint).opacity(form.ip == printer.ip ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Use this printer")
                }
            }

            section("Notifications") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Monitor in the background")
                        Text("Print status only, no video: a few KB, even with the window closed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(isOn: $background) { Text("Monitor in the background") }
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications")
                        Group {
                            if background {
                                Text("Start, pause, cancel, end (with a camera frame), printer online/offline.")
                            } else {
                                Text("Needs background monitoring to work with the window closed.")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(isOn: Binding(get: { notifications }, set: { on in
                        guard on else { notifications = false; return }
                        Notifier.requestAuthorization { granted in
                            notifications = granted
                            form.notificationsDenied = !granted
                        }
                    })) { Text("Notifications") }
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                if form.notificationsDenied {
                    HStack {
                        Text("Notifications are blocked for Toothpeek in System Settings.").font(.caption).foregroundStyle(.red)
                        Button("Open…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                        .controlSize(.small)
                    }
                }
                if notifications {
                    HStack {
                        Text("Include a camera image")
                        Spacer()
                        Toggle(isOn: $notificationImages) { Text("Include a camera image") }
                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                    .help("The image shows the inside of the printer and can appear on the lock screen.")
                    Button("Send a test notification") { Notifier.shared?.sendTest() }.controlSize(.small)
                }
            }

            section("General") {
                HStack {
                    Text("Language")
                    Spacer()
                    Picker(selection: $form.language) {
                        Text("System").tag("system")
                        Text(verbatim: "English").tag("en")
                        Text(verbatim: "Français").tag("fr")
                    } label: {
                        Text("Language")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                HStack {
                    Text("Open at login")
                    Spacer()
                    Toggle(isOn: $form.launchAtLogin) { Text("Open at login") }
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                if SMAppService.mainApp.status == .requiresApproval {
                    Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let error = form.loginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Divider()
                UpdatesRow(updates: updates)
            }

            HStack {
                Spacer()
                if form.isConfigured {
                    Button("Cancel") { form.editing = false }.keyboardShortcut(.cancelAction)
                }
                Button("Save") { form.save() }
                .keyboardShortcut(.defaultAction)
                .disabled(form.ip.isEmpty || !form.codeIsValid)
            }
        }
        .padding(14)
        .frame(width: 480)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .onReceive(discovery.$printers) { found in
            // Only when unambiguous: any LAN device can announce itself as a printer.
            if form.ip.isEmpty, found.count == 1 { form.ip = found[0].ip }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label).frame(width: 100, alignment: .leading)
            content()
        }
    }
}

/// The printer access code, in the login Keychain. It also grants full control of the printer, so it does not
/// belong in the plain-text preferences. Cached after the first read: the app needs it on every reconnect, and
/// an ad hoc signed build asks for Keychain access again after each update (once "Always Allow" is clicked).
enum AccessCode {
    static let didChange = Notification.Name("ToothpeekAccessCodeDidChange")

    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.loicbisiere.Toothpeek",
        kSecAttrAccount as String: "accessCode",
    ]
    private static var cached: String?

    static var value: String {
        get {
            if let cached { return cached }
            let code = read() ?? migrateFromPreferences() ?? ""
            cached = code
            return code
        }
        set {
            guard newValue != value else { return }
            store(newValue)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    private static func store(_ code: String) {
        SecItemDelete(query as CFDictionary)
        if !code.isEmpty {
            var item = query
            item[kSecValueData as String] = Data(code.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock // also readable at login
            SecItemAdd(item as CFDictionary, nil)
        }
        cached = code
    }

    private static func read() -> String? {
        var item = query
        item[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Versions up to 0.1 kept the code in the preferences: move it once, then delete the plain-text copy.
    private static func migrateFromPreferences() -> String? {
        guard let old = UserDefaults.standard.string(forKey: "accessCode") else { return nil }
        store(old)
        UserDefaults.standard.removeObject(forKey: "accessCode")
        return old
    }
}

/// "Check for updates" switch, current status, and how to update (Homebrew command or release page).
struct UpdatesRow: View {
    @ObservedObject var updates: UpdateChecker
    @AppStorage(UpdateChecker.enabledKey) private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check for updates")
                    Text("Once a day, on GitHub. Toothpeek never installs anything by itself.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(isOn: $enabled) { Text("Check for updates") }
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            HStack {
                if updates.checking {
                    Text("Checking…").foregroundStyle(.secondary)
                } else if let error = updates.error {
                    Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .foregroundStyle(.orange)
                } else if let release = updates.available {
                    Label("Version \(release.version) available", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue)
                } else if let current = updates.currentVersion {
                    if let checked = updates.lastCheck {
                        Label {
                            Text("Toothpeek \(current) is up to date · checked at \(Text(checked, style: .time))")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    } else {
                        Text(verbatim: "Toothpeek \(current)").foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    updates.check()
                } label: {
                    if updates.checking {
                        ProgressView().controlSize(.small).frame(width: 40) // same footprint as the label
                    } else {
                        Text("Check now")
                    }
                }
                .controlSize(.small)
                .disabled(updates.currentVersion == nil || updates.checking)
            }
            .animation(.default, value: updates.checking)
            .font(.caption)
            if let release = updates.available {
                if updates.installedWithHomebrew {
                    HStack {
                        Text(verbatim: "brew upgrade --cask toothpeek").font(.caption.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew upgrade --cask toothpeek", forType: .string)
                        }
                        .controlSize(.small)
                    }
                } else {
                    Button("Download") { NSWorkspace.shared.open(release.page) }.controlSize(.small)
                }
            }
        }
    }
}
