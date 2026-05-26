import AppKit
import Foundation
import OpenAIEgressCore
import UserNotifications

struct AppConfig {
    let publicIPProbes: [PublicIPProbe]
    let traceURL: URL
    let apiURL: URL
    let notificationOpenURL: URL
    let expectedCountries: Set<String>
    let refreshInterval: TimeInterval
    let notifyOnChange: Bool
    let notifyOnUnexpected: Bool
    let logDirectory: URL
    let stateDirectory: URL

    static func load() -> AppConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appSupport = home.appendingPathComponent("Library/Application Support/openai-egress-monitor")
        let logDir = home.appendingPathComponent("Library/Logs/openai-egress-monitor")
        let values = parseShellConfig(at: appSupport.appendingPathComponent("openai-egress-monitor.conf"))
        let trace = urlValue(values["TRACE_URL"], default: "https://chatgpt.com/cdn-cgi/trace")
        return AppConfig(
            publicIPProbes: publicIPProbes(from: values),
            traceURL: trace,
            apiURL: urlValue(values["API_URL"], default: "https://api.openai.com"),
            notificationOpenURL: urlValue(values["NOTIFICATION_OPEN_URL"], default: trace.absoluteString),
            expectedCountries: Set(splitWords(values["EXPECTED_LOCS"] ?? "JP SG").map { $0.uppercased() }),
            refreshInterval: max(TimeInterval(Int(values["REFRESH_INTERVAL_SECONDS"] ?? "") ?? 300), 30),
            notifyOnChange: boolValue(values["NOTIFY_ON_CHANGE"], default: true),
            notifyOnUnexpected: boolValue(values["NOTIFY_ON_UNEXPECTED"], default: true),
            logDirectory: URL(fileURLWithPath: expandPath(values["LOG_DIR"], default: logDir.path)),
            stateDirectory: appSupport
        )
    }

    private static func parseShellConfig(at url: URL) -> [String: String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for rawLine in content.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = expandPath(value, default: value)
        }
        return values
    }

    private static func urlValue(_ value: String?, default defaultValue: String) -> URL {
        URL(string: value ?? defaultValue) ?? URL(string: defaultValue)!
    }

    private static func publicIPProbes(from values: [String: String]) -> [PublicIPProbe] {
        if let raw = values["PUBLIC_IP_PROBES"] {
            let probes = raw
                .split(separator: ";")
                .compactMap { PublicIPProbe.parse(String($0)) }
            if !probes.isEmpty {
                return probes
            }
        }

        let legacyURL = urlValue(values["IPINFO_URL"], default: "https://ipinfo.io/json")
        return [
            PublicIPProbe(adapter: .ipinfoJSON, url: legacyURL),
            PublicIPProbe(adapter: .ipapiJSON, url: URL(string: "https://ipapi.co/json/")!),
            PublicIPProbe(adapter: .ipwhoisJSON, url: URL(string: "https://ipwho.is/")!),
        ]
    }

    private static func splitWords(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }).map(String.init)
    }

    private static func boolValue(_ value: String?, default defaultValue: Bool) -> Bool {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }

    private static func expandPath(_ value: String?, default defaultValue: String) -> String {
        let raw = value ?? defaultValue
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if raw == "$HOME" { return home }
        if raw.hasPrefix("$HOME/") { return home + String(raw.dropFirst("$HOME".count)) }
        if raw.hasPrefix("~/") { return home + String(raw.dropFirst(1)) }
        return raw
    }
}

struct EgressState {
    var timestamp = Date()
    var publicInfo: IPInfo?
    var trace: ChatGPTTrace?
    var apiColo: String?
    var apiCFRay: String?
    var publicProvider: String?
    var publicProviderURL: String?
    var publicError: String?
    var traceError: String?
    var apiError: String?

    var traceCountry: String? { trace?.country?.uppercased() }
    var statusTitle: String { CountryDisplay.statusTitle(for: traceCountry ?? publicInfo?.country) }
}

@MainActor
enum EgressFetcher {
    static func fetch(config: AppConfig) async -> EgressState {
        var state = EgressState(timestamp: Date())

        var publicErrors: [String] = []
        for probe in config.publicIPProbes {
            do {
                let data = try await fetchData(from: probe.url)
                state.publicInfo = try probe.adapter.decode(data)
                state.publicProvider = probe.adapter.rawValue
                state.publicProviderURL = probe.url.absoluteString
                break
            } catch {
                publicErrors.append("\(probe.adapter.rawValue) \(probe.url.absoluteString): \(error.localizedDescription)")
            }
        }
        if state.publicInfo == nil {
            state.publicError = publicErrors.joined(separator: " | ")
        }

        do {
            let data = try await fetchData(from: config.traceURL)
            let body = String(data: data, encoding: .utf8) ?? ""
            state.trace = ChatGPTTrace.parse(body)
        } catch {
            state.traceError = error.localizedDescription
        }

        do {
            var request = URLRequest(url: config.apiURL)
            request.httpMethod = "HEAD"
            let response = try await fetchResponse(for: request)
            if let response = response as? HTTPURLResponse {
                state.apiCFRay = response.value(forHTTPHeaderField: "cf-ray")
                state.apiColo = state.apiCFRay?.split(separator: "-").last.map(String.init)
            }
        } catch {
            state.apiError = error.localizedDescription
        }

        return state
    }

    private static func fetchData(from url: URL, attempts: Int = 2) async throws -> Data {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                return data
            } catch {
                lastError = error
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    private static func fetchResponse(for request: URLRequest, attempts: Int = 2) async throws -> URLResponse {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                return response
            } catch {
                lastError = error
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
        throw lastError ?? URLError(.unknown)
    }
}

final class EgressStore {
    private let config: AppConfig
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(config: AppConfig) {
        self.config = config
        encoder.outputFormatting = [.sortedKeys]
    }

    func previousSnapshot() -> EgressSnapshot? {
        let url = config.stateDirectory.appendingPathComponent("latest-snapshot.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(EgressSnapshot.self, from: data)
    }

    func persist(_ state: EgressState) {
        try? FileManager.default.createDirectory(at: config.logDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: config.stateDirectory, withIntermediateDirectories: true)
        let snapshot = EgressSnapshot(publicCountry: state.publicInfo?.country, traceCountry: state.trace?.country)
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: config.stateDirectory.appendingPathComponent("latest-snapshot.json"))
        }
        writeLatestText(state)
        appendJSONL(state)
    }

    private func writeLatestText(_ state: EgressState) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let text = """
        OpenAI egress status
        time: \(formatter.string(from: state.timestamp))
        public_ip: \(state.publicInfo?.ip ?? "UNKNOWN")
        public_country: \(state.publicInfo?.country ?? "UNKNOWN")
        public_city: \(state.publicInfo?.city ?? "UNKNOWN")
        public_coordinates: \(state.publicInfo?.coordinateDisplay ?? "UNKNOWN")
        public_provider: \(state.publicProvider ?? "UNKNOWN")
        public_provider_url: \(state.publicProviderURL ?? "UNKNOWN")
        trace_ip: \(state.trace?.ip ?? "UNKNOWN")
        trace_country: \(state.trace?.country ?? "UNKNOWN")
        trace_colo: \(state.trace?.colo ?? "UNKNOWN")
        trace_http: \(state.trace?.http ?? "UNKNOWN")
        trace_tls: \(state.trace?.tls ?? "UNKNOWN")
        api_colo: \(state.apiColo ?? "UNKNOWN")
        api_cf_ray: \(state.apiCFRay ?? "UNKNOWN")
        public_error: \(state.publicError ?? "")
        trace_error: \(state.traceError ?? "")
        api_error: \(state.apiError ?? "")
        """
        try? text.write(to: config.logDirectory.appendingPathComponent("latest.txt"), atomically: true, encoding: .utf8)
    }

    private func appendJSONL(_ state: EgressState) {
        let line: [String: String] = [
            "timestamp": ISO8601DateFormatter().string(from: state.timestamp),
            "public_ip": state.publicInfo?.ip ?? "",
            "public_country": state.publicInfo?.country ?? "",
            "public_city": state.publicInfo?.city ?? "",
            "public_coordinates": state.publicInfo?.coordinateDisplay ?? "",
            "public_provider": state.publicProvider ?? "",
            "public_provider_url": state.publicProviderURL ?? "",
            "trace_ip": state.trace?.ip ?? "",
            "trace_country": state.trace?.country ?? "",
            "trace_colo": state.trace?.colo ?? "",
            "trace_http": state.trace?.http ?? "",
            "trace_tls": state.trace?.tls ?? "",
            "api_colo": state.apiColo ?? "",
            "api_cf_ray": state.apiCFRay ?? "",
            "public_error": state.publicError ?? "",
            "trace_error": state.traceError ?? "",
            "api_error": state.apiError ?? "",
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return }
        let url = config.logDirectory.appendingPathComponent("openai-egress.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((json + "\n").utf8))
        }
    }
}

@MainActor
final class StatusViewController: NSViewController {
    private let config: AppConfig
    private var state: EgressState?

    init(config: AppConfig) {
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 246))
        rebuild()
    }

    func update(state: EgressState) {
        self.state = state
        rebuild()
    }

    private func rebuild() {
        guard isViewLoaded else { return }
        view.subviews.forEach { $0.removeFromSuperview() }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])

        root.addArrangedSubview(section(title: "Public IP", rows: [
            ("IP", state?.publicInfo?.ip ?? "--"),
            ("Country", state?.publicInfo?.countryDisplay ?? "--"),
            ("City", state?.publicInfo?.city ?? "--"),
            ("Coordinates", state?.publicInfo?.coordinateDisplay ?? "--"),
        ], error: state?.publicError))

        root.addArrangedSubview(separator())

        let httpTLS = [state?.trace?.http, state?.trace?.tls].compactMap { $0 }.joined(separator: " / ")
        root.addArrangedSubview(section(title: "ChatGPT Trace", rows: [
            ("IP", state?.trace?.ip ?? "--"),
            ("Country", state?.trace?.countryDisplay ?? "--"),
            ("Colo", state?.trace?.colo ?? "--"),
            ("HTTP / TLS", httpTLS.isEmpty ? "--" : httpTLS),
        ], error: state?.traceError))

    }

    private func section(title: String, rows: [(String, String)], error: String?) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(titleLabel)

        if let error, !error.isEmpty {
            let errorLabel = NSTextField(wrappingLabelWithString: error)
            errorLabel.font = .systemFont(ofSize: 12)
            errorLabel.textColor = .systemRed
            stack.addArrangedSubview(errorLabel)
            return stack
        }

        for row in rows {
            stack.addArrangedSubview(rowView(label: row.0, value: row.1))
        }
        return stack
    }

    private func rowView(label: String, value: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 13, weight: .semibold)
        labelField.textColor = .secondaryLabelColor
        labelField.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let valueField = NSTextField(wrappingLabelWithString: value)
        valueField.font = .systemFont(ofSize: 15)
        valueField.maximumNumberOfLines = 2

        row.addArrangedSubview(labelField)
        row.addArrangedSubview(valueField)
        row.widthAnchor.constraint(equalToConstant: 344).isActive = true
        return row
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 344).isActive = true
        return line
    }

}

@MainActor
final class StatusMenuRenderer {
    private let config: AppConfig
    private weak var delegate: AppDelegate?
    private var state: EgressState?
    private let launchAtLoginManager = LaunchAtLoginManager()

    init(config: AppConfig, delegate: AppDelegate) {
        self.config = config
        self.delegate = delegate
    }

    func update(state: EgressState) {
        self.state = state
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        addSection(
            to: menu,
            title: "Public Network",
            subtitle: state?.publicProvider ?? "public IP provider",
            rows: [
                ("IP", state?.publicInfo?.ip ?? "--"),
                ("Country", state?.publicInfo?.countryDisplay ?? "--"),
                ("City", state?.publicInfo?.city ?? "--"),
                ("Coordinates", state?.publicInfo?.coordinateDisplay ?? "--"),
            ],
            error: state?.publicError
        )

        menu.addItem(.separator())

        let httpTLS = [state?.trace?.http, state?.trace?.tls].compactMap { $0 }.joined(separator: " / ")
        addSection(
            to: menu,
            title: "ChatGPT Edge",
            subtitle: "chatgpt.com / Cloudflare",
            rows: [
                ("IP", state?.trace?.ip ?? "--"),
                ("Country", state?.trace?.countryDisplay ?? "--"),
                ("Colo", state?.trace?.colo ?? "--"),
                ("HTTP / TLS", httpTLS.isEmpty ? "--" : httpTLS),
            ],
            error: state?.traceError
        )

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(AppDelegate.refreshNowFromMenu), keyEquivalent: "r")
        refreshItem.target = delegate
        menu.addItem(refreshItem)

        let traceItem = NSMenuItem(title: "Open ChatGPT Trace", action: #selector(AppDelegate.openTrace), keyEquivalent: "t")
        traceItem.target = delegate
        menu.addItem(traceItem)

        let logsItem = NSMenuItem(title: "Open Logs", action: #selector(AppDelegate.openLogs), keyEquivalent: "l")
        logsItem.target = delegate
        menu.addItem(logsItem)

        menu.addItem(.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(AppDelegate.toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = delegate
        launchItem.state = launchAtLoginManager.isEnabled ? .on : .off
        menu.addItem(launchItem)

        let quitItem = NSMenuItem(title: "Quit EgressMonitor", action: #selector(AppDelegate.quit), keyEquivalent: "q")
        quitItem.target = delegate
        menu.addItem(quitItem)

        return menu
    }

    private func addSection(
        to menu: NSMenu,
        title: String,
        subtitle: String,
        rows: [(String, String)],
        error: String?
    ) {
        let titleItem = NSMenuItem()
        titleItem.view = headerView(title: title, subtitle: subtitle)
        menu.addItem(titleItem)

        if let error, !error.isEmpty {
            let item = NSMenuItem()
            item.view = rowView(label: "Error", value: error, isError: true)
            menu.addItem(item)
            return
        }

        for row in rows {
            let item = NSMenuItem()
            item.view = rowView(label: row.0, value: row.1)
            menu.addItem(item)
        }
    }

    private func headerView(title: String, subtitle: String) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 34))

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: 14, y: 16, width: 160, height: 14)

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 10, weight: .regular)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.alignment = .right
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.frame = NSRect(x: 174, y: 16, width: 148, height: 14)

        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        return view
    }

    private func rowView(label: String, value: String, isError: Bool = false) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: isError ? 38 : 26))

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 12, weight: .semibold)
        labelField.textColor = .secondaryLabelColor
        labelField.frame = NSRect(x: 14, y: isError ? 18 : 5, width: 88, height: 16)

        let valueField = NSTextField(wrappingLabelWithString: value)
        valueField.font = .systemFont(ofSize: 13, weight: .regular)
        valueField.textColor = isError ? .systemRed : .labelColor
        valueField.maximumNumberOfLines = isError ? 2 : 1
        valueField.lineBreakMode = .byTruncatingMiddle
        valueField.frame = NSRect(x: 108, y: isError ? 6 : 4, width: 214, height: isError ? 28 : 18)

        view.addSubview(labelField)
        view.addSubview(valueField)
        return view
    }
}

struct LaunchAtLoginManager {
    private let label = "com.local.egress-monitor"

    var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.local.egress-monitor.plist")
    }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            install()
        } else {
            uninstall()
        }
    }

    private func install() {
        guard let executableURL = Bundle.main.executableURL else { return }
        let directory = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.path],
            "RunAtLoad": true,
            "StandardOutPath": "/tmp/openai-egress-status.out",
            "StandardErrorPath": "/tmp/openai-egress-status.err",
        ]

        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return
        }

        try? data.write(to: plistURL, options: .atomic)
        _ = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        _ = runLaunchctl(["enable", "gui/\(getuid())/\(label)"])
    }

    private func uninstall() {
        try? FileManager.default.removeItem(at: plistURL)
    }

    private func runLaunchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menuRenderer: StatusMenuRenderer!
    private var refreshTimer: Timer?
    private let config = AppConfig.load()
    private lazy var store = EgressStore(config: config)
    private lazy var notificationDelegate = NotificationDelegate(openURL: config.notificationOpenURL)
    private let launchAtLoginManager = LaunchAtLoginManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = notificationDelegate
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "--"

        menuRenderer = StatusMenuRenderer(config: config, delegate: self)
        statusItem.menu = menuRenderer.buildMenu()

        refreshNow()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: config.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    @objc func refreshNowFromMenu() {
        refreshNow()
    }

    @objc func openTrace() {
        NSWorkspace.shared.open(config.notificationOpenURL)
    }

    @objc func openLogs() {
        NSWorkspace.shared.open(config.logDirectory)
    }

    @objc func toggleLaunchAtLogin() {
        launchAtLoginManager.setEnabled(!launchAtLoginManager.isEnabled)
        statusItem.menu = menuRenderer.buildMenu()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    private func refreshNow() {
        statusItem.button?.title = "..."
        Task {
            let previous = store.previousSnapshot()
            let state = await EgressFetcher.fetch(config: config)
            store.persist(state)
            menuRenderer.update(state: state)
            statusItem.menu = menuRenderer.buildMenu()
            statusItem.button?.title = state.statusTitle
            sendNotificationsIfNeeded(previous: previous, state: state)
        }
    }

    private func sendNotificationsIfNeeded(previous: EgressSnapshot?, state: EgressState) {
        let current = EgressSnapshot(publicCountry: state.publicInfo?.country, traceCountry: state.trace?.country)
        if config.notifyOnUnexpected, let country = state.traceCountry, !EgressAlertPolicy.isTraceCountryExpected(country, expectedCountries: config.expectedCountries) {
            notify(title: "ChatGPT Trace Unexpected", body: "loc=\(country), colo=\(state.trace?.colo ?? "UNKNOWN")")
            return
        }
        if config.notifyOnChange, EgressAlertPolicy.shouldNotifyCountryChange(previous: previous, current: current) {
            notify(title: "ChatGPT Trace Country Changed", body: "\(previous?.traceCountry ?? "?") -> \(current.traceCountry ?? "UNKNOWN")")
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["openURL": config.notificationOpenURL.absoluteString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let openURL: URL

    init(openURL: URL) {
        self.openURL = openURL
        super.init()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let fallbackURL = openURL
        let raw = response.notification.request.content.userInfo["openURL"] as? String
        let url = raw.flatMap(URL.init(string:)) ?? fallbackURL
        Task.detached { @MainActor in NSWorkspace.shared.open(url) }
        completionHandler()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
