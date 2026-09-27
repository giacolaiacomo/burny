// AI Usage Bar — menu bar widget with Claude Code and Codex (ChatGPT) usage limits.
// The app itself makes no network calls and never touches credentials:
//   Claude Code: runs the official `claude -p /usage` (0 tokens, the same request as typing /usage)
//   Codex:       reads the rate_limits the Codex CLI already logs in ~/.codex/sessions/**/rollout-*.jsonl

import AppKit
import SwiftUI
import Combine

// MARK: Model

struct Limit: Identifiable {
    let label: String
    let percent: Double        // 0...100
    let resetsAt: Date?
    let window: TimeInterval   // window length, for the pace marker
    var id: String { label }

    var effective: Double {    // a window whose reset has passed is empty again
        if let r = resetsAt, r < Date() { return 0 }
        return percent
    }
    var pace: Double? {        // fraction of the window already elapsed
        guard let r = resetsAt, r > Date(), window > 0 else { return nil }
        return min(1, max(0, 1 - r.timeIntervalSinceNow / window))
    }
}

struct Service {
    let name: String
    let plan: String?
    let accent: Color
    let limits: [Limit]
    let updated: Date?
}

let home = FileManager.default.homeDirectoryForCurrentUser
let claudeAccent = Color(red: 0.85, green: 0.47, blue: 0.34)
let codexAccent = Color(red: 0.06, green: 0.64, blue: 0.50)
let hour: TimeInterval = 3600, week: TimeInterval = 7 * 24 * 3600

func epoch(_ v: Any?) -> Date? {
    guard let n = (v as? NSNumber)?.doubleValue else { return nil }
    return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
}

func mtime(_ u: URL) -> Date {
    (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
}

// MARK: Claude Code — official /usage (session, week, per-model buckets such as Fable)

func claudeBinary() -> String? {
    ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        .map { NSString(string: $0).expandingTildeInPath }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

func fetchClaudeUsage() -> [Limit]? {
    guard let bin = claudeBinary() else { return nil }
    let cwd = home.appendingPathComponent("Library/Caches/ai-usage-bar")
    try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = ["-p", "/usage", "--output-format", "json", "--no-session-persistence",
                   "--setting-sources", "user", "--settings", "{\"disableAllHooks\":true}"]
    p.currentDirectoryURL = cwd
    var env = ["HOME": home.path, "USER": NSUserName(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "LANG": "en_US.UTF-8"]
    env["TMPDIR"] = ProcessInfo.processInfo.environment["TMPDIR"]
    p.environment = env
    p.standardInput = FileHandle.nullDevice
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let killer = DispatchWorkItem { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }   // never leave a stuck child behind
    DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: killer)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (obj["is_error"] as? Bool) != true, let text = obj["result"] as? String else { return nil }
    let limits = parseUsage(text)
    return limits.isEmpty ? nil : limits
}

// "Current week (Fable): 6% used · resets Oct 3 at 2pm (Europe/Rome)"
func parseUsage(_ text: String) -> [Limit] {
    let re = try! NSRegularExpression(pattern: #"^Current (session|week \((.+?)\)): ([\d.]+)% used(?: · resets (.+?)(?: \(([^)]+)\))?)?\s*$"#, options: .anchorsMatchLines)
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
        func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        guard let pct = g(3).flatMap(Double.init) else { return nil }
        let isSession = g(1) == "session"
        let bucket = g(2) ?? ""
        let label = isSession ? "Sessione · 5h" : "Settimana · " + (bucket == "all models" ? "tutti i modelli" : bucket)
        let reset = g(4).flatMap { parseReset($0, tz: g(5)) }
        return Limit(label: label, percent: pct, resetsAt: reset, window: isSession ? 5 * hour : week)
    }
}

func parseReset(_ s: String, tz: String?) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = tz.flatMap(TimeZone.init(identifier:)) ?? .current
    f.defaultDate = Date()
    let str = s.uppercased().replacingOccurrences(of: " AT ", with: " at ")
    for fmt in ["MMM d 'at' h:mma", "MMM d 'at' ha", "h:mma", "ha", "MMM d"] {
        f.dateFormat = fmt
        if var d = f.date(from: str) {
            if d < Date().addingTimeInterval(-86400) { d = Calendar.current.date(byAdding: .year, value: 1, to: d) ?? d }
            return d
        }
    }
    return nil
}

func claudePlan() -> String? {
    guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let acct = obj["oauthAccount"] as? [String: Any] else { return nil }
    let tier = ((acct["organizationRateLimitTier"] as? String) ?? (acct["organizationType"] as? String) ?? "").lowercased()
    if tier.contains("20x") { return "Max 20x" }
    if tier.contains("5x") { return "Max 5x" }
    if tier.contains("max") { return "Max" }
    if tier.contains("pro") { return "Pro" }
    if tier.contains("team") { return "Team" }
    return nil
}

// MARK: Codex

func readCodex() -> Service? {
    let root = home.appendingPathComponent(".codex/sessions")
    guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
    var files: [(URL, Date)] = []
    for case let u as URL in en where u.pathExtension == "jsonl" { files.append((u, mtime(u))) }
    files.sort { $0.1 > $1.1 }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for (f, mt) in files.prefix(10) {
        guard let h = try? FileHandle(forReadingFrom: f) else { continue }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 4_000_000 ? size - 4_000_000 : 0)   // only the tail matters
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n").reversed() where line.contains("\"primary\":{") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let rl = payload["rate_limits"] as? [String: Any] else { continue }
            func lim(_ k: String) -> Limit? {
                guard let d = rl[k] as? [String: Any], let p = (d["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                let mins = (d["window_minutes"] as? NSNumber)?.doubleValue ?? 0
                let label = mins >= 10080 ? "Settimana" : mins > 0 && mins < 1440 ? "Sessione · \(Int(mins / 60))h" : "Finestra \(Int(mins / 60))h"
                return Limit(label: label, percent: p, resetsAt: epoch(d["resets_at"]), window: mins * 60)
            }
            let ts = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? mt
            return Service(name: "Codex", plan: (rl["plan_type"] as? String)?.capitalized, accent: codexAccent,
                           limits: [lim("primary"), lim("secondary")].compactMap { $0 }, updated: ts)
        }
    }
    return nil
}

// MARK: Open at login (the LaunchAgent written by install.sh)

enum LoginItem {
    static let label = "com.aiusagebar"
    static var domain: String { "gui/\(getuid())" }

    @discardableResult
    static func launchctl(_ args: [String]) -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static var isEnabled: Bool {
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return false }
        let disabled = launchctl(["print-disabled", domain])
        return !disabled.contains("\"\(label)\" => disabled") && !disabled.contains("\"\(label)\" => true")
    }

    static func set(_ on: Bool) { launchctl([on ? "enable" : "disable", "\(domain)/\(label)"]) }
}

// MARK: Store

final class Store: ObservableObject {
    @Published var claude: Service?
    @Published var codex: Service?
    @Published var fetching = false
    @Published var showClaude = UserDefaults.standard.object(forKey: "showClaude") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showClaude, forKey: "showClaude") }
    }
    @Published var showCodex = UserDefaults.standard.object(forKey: "showCodex") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showCodex, forKey: "showCodex") }
    }
    @Published var barMode = UserDefaults.standard.string(forKey: "barMode") ?? "peak" {   // peak | session | week
        didSet { UserDefaults.standard.set(barMode, forKey: "barMode") }
    }
    @Published var showRemaining = UserDefaults.standard.bool(forKey: "showRemaining") {
        didSet { UserDefaults.standard.set(showRemaining, forKey: "showRemaining") }
    }
    @Published var refreshMinutes = UserDefaults.standard.object(forKey: "refreshMinutes") as? Int ?? 5 {
        didSet { UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes") }
    }
    @Published var launchAtLogin = LoginItem.isEnabled {
        didSet { if launchAtLogin != oldValue { LoginItem.set(launchAtLogin) } }
    }

    /// The number shown in the menu bar for a service, per the user's choice (always "% used").
    func barValue(_ s: Service?) -> Double? {
        guard let s else { return nil }
        let pick: [Limit]
        switch barMode {
        case "session": pick = s.limits.filter { $0.window <= 5 * hour }
        case "week": pick = s.limits.filter { $0.window >= week }
        default: pick = s.limits
        }
        return pick.map(\.effective).max()
    }
    private var fetched: (limits: [Limit], at: Date)?

    func reloadLocal() {
        codex = readCodex()
        claude = fetched.map { Service(name: "Claude Code", plan: claudePlan(), accent: claudeAccent, limits: $0.limits, updated: $0.at) }
    }

    func fetch(ifOlderThan age: TimeInterval = 0) {
        if fetching { return }
        if let f = fetched, -f.at.timeIntervalSinceNow < age { return }
        fetching = true
        DispatchQueue.global(qos: .utility).async {
            let l = fetchClaudeUsage()
            DispatchQueue.main.async {
                if let l { self.fetched = (l, Date()) }
                self.fetching = false
                self.reloadLocal()
            }
        }
    }
}

// MARK: Popover UI

func levelColor(_ p: Double, _ accent: Color) -> Color { p >= 90 ? .red : p >= 75 ? .orange : accent }

func resetLine(_ d: Date?) -> String {
    guard let d else { return " " }
    if d < Date() { return "Azzerato" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "it_IT")
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : Calendar.current.isDateInTomorrow(d) ? "'domani' HH:mm" : "EEE d · HH:mm"
    let m = Int(d.timeIntervalSinceNow / 60)
    let rel = m < 60 ? "\(m)m" : m < 1440 ? "\(m / 60)h \(m % 60)m" : "\(m / 1440)g \(m % 1440 / 60)h"
    return "Si azzera tra \(rel) · \(f.string(from: d))"
}

func ago(_ d: Date?) -> String {
    guard let d else { return "" }
    let m = Int(-d.timeIntervalSinceNow / 60)
    return m < 1 ? "adesso" : m < 60 ? "\(m) min fa" : m < 1440 ? "\(m / 60) h fa" : "\(m / 1440) g fa"
}

struct LimitRow: View {
    let limit: Limit
    let accent: Color
    var body: some View {
        let p = limit.effective, c = levelColor(p, accent)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.label).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(p.rounded()))%").font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(c)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if p > 0 {
                        Capsule().fill(LinearGradient(colors: [c.opacity(0.65), c], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, g.size.width * min(p, 100) / 100))
                    }
                    if let pace = limit.pace {   // where you'd be at an even pace
                        RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.45))
                            .frame(width: 2, height: 10).offset(x: g.size.width * pace - 1)
                    }
                }
            }
            .frame(height: 6)
            Text(resetLine(limit.resetsAt)).font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
    }
}

struct ServiceCard: View {
    let service: Service?
    let name: String
    let accent: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(accent).frame(width: 8, height: 8)
                Text(name).font(.system(size: 13, weight: .semibold))
                if let plan = service?.plan {
                    Text(plan).font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(accent.opacity(0.16))).foregroundStyle(accent)
                }
                Spacer()
                Text(ago(service?.updated)).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            if let s = service, !s.limits.isEmpty {
                ForEach(s.limits) { LimitRow(limit: $0, accent: accent) }
            } else {
                Text("Nessun dato: usalo una volta e comparirà qui.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055))
            .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5))
    }
}

struct UsageView: View {
    @ObservedObject var store: Store
    @State var settings = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if settings {
                    Button { settings = false } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                }
                Text(settings ? "Impostazioni" : "Limiti di utilizzo").font(.system(size: 14, weight: .bold))
                Spacer()
                if !settings {
                    if store.fetching { ProgressView().controlSize(.small).scaleEffect(0.8) }
                    Button { store.fetch() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Aggiorna ora")
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("Impostazioni")
                }
            }
            if settings {
                SettingsView(store: store)
            } else {
                ServiceCard(service: store.claude, name: "Claude Code", accent: claudeAccent)
                ServiceCard(service: store.codex, name: "Codex", accent: codexAccent)
                Text("La tacca sulla barra indica dove saresti a ritmo costante.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            Divider()
            HStack {
                Image(systemName: "lock.shield").font(.system(size: 10))
                Text("Solo dati locali e client ufficiali").font(.system(size: 10.5))
                Spacer()
                Button("Esci") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.system(size: 11))
            }
            .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 330)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.055)))
        }
    }
}

struct SettingRow<Control: View>: View {
    let label: String
    var note: String? = nil
    @ViewBuilder let control: Control
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12))
                if let note { Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            control
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection(title: "Generale") {
                SettingRow(label: "Apri al login") {
                    Toggle("", isOn: $store.launchAtLogin).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
            }
            SettingsSection(title: "Barra dei menu") {
                SettingRow(label: "Claude Code") {
                    Toggle("", isOn: $store.showClaude).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                SettingRow(label: "Codex") {
                    Toggle("", isOn: $store.showCodex).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                Divider()
                SettingRow(label: "Limite mostrato", note: store.barMode == "peak" ? "Quello più vicino all'esaurimento, tra sessione e settimana." : nil) {
                    Picker("", selection: $store.barMode) {
                        Text("Più critico").tag("peak")
                        Text("Sessione 5h").tag("session")
                        Text("Settimana").tag("week")
                    }
                    .labelsHidden().fixedSize()
                }
                SettingRow(label: "Percentuale") {
                    Picker("", selection: $store.showRemaining) {
                        Text("Usata").tag(false)
                        Text("Rimasta").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            SettingsSection(title: "Aggiornamento") {
                SettingRow(label: "Claude ogni", note: "Esegue /usage del client ufficiale: 0 token. Codex si legge dai log locali ogni 30 s.") {
                    Picker("", selection: $store.refreshMinutes) {
                        ForEach([2, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }
}

// MARK: Menu bar

func ring(_ p: Double?, _ accent: NSColor) -> NSImage {
    let size: CGFloat = 14
    return NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
        let rect = r.insetBy(dx: 1.75, dy: 1.75)
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = 2.5
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        track.stroke()
        if let p, p > 0 {
            let c = p >= 90 ? NSColor.systemRed : p >= 75 ? NSColor.systemOrange : accent
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: rect.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * CGFloat(min(p, 100)) / 100, clockwise: true)
            arc.lineWidth = 2.5
            arc.lineCapStyle = .round
            c.setStroke()
            arc.stroke()
        }
        return true
    }
}

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let store = Store()
    var bag: AnyCancellable?
    var timers: [Timer] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        popover.behavior = .transient
        let host = NSHostingController(rootView: UsageView(store: store))
        host.sizingOptions = [.preferredContentSize]   // grow/shrink with content instead of clipping
        popover.contentViewController = host
        item.button?.target = self
        item.button?.action = #selector(toggle)
        bag = store.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.render() } }
        store.reloadLocal()
        store.fetch()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.store.reloadLocal() },   // Codex log, cheap
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in                             // Claude /usage
                guard let self else { return }
                self.store.fetch(ifOlderThan: Double(self.store.refreshMinutes * 60) - 5)
            },
        ]
    }

    // The real app icons make it obvious which number is which; fall back to a coloured ring.
    lazy var icons: [NSImage?] = ["/Applications/Claude.app", "/Applications/ChatGPT.app"].map { path in
        FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : nil
    }

    func render() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        let title = NSMutableAttributedString()
        var tip: [String] = []
        let shown = [store.showClaude, store.showCodex]
        for (i, (s, accent)) in [(store.claude, NSColor(claudeAccent)), (store.codex, NSColor(codexAccent))].enumerated() {
            if let s { tip.append(s.name + ": " + s.limits.map { "\($0.label) \(Int($0.effective.rounded()))%" }.joined(separator: ", ")) }
            guard shown[i] else { continue }
            if title.length > 0 { title.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            let att = NSTextAttachment()
            att.image = icons[i] ?? ring(store.barValue(s), accent)
            att.bounds = CGRect(x: 0, y: -4, width: 17, height: 17)
            title.append(NSAttributedString(attachment: att))
            let p = store.barValue(s)   // colour always follows % used
            let color: NSColor = p.map { $0 >= 90 ? .systemRed : $0 >= 75 ? .systemOrange : .labelColor } ?? .secondaryLabelColor
            let shownValue = p.map { store.showRemaining ? max(0, 100 - $0) : $0 }
            title.append(NSAttributedString(string: " " + (shownValue.map { "\(Int($0.rounded()))%" } ?? "–"), attributes: [.font: font, .foregroundColor: color]))
        }
        if title.length == 0 {   // both hidden: keep a clickable glyph
            let att = NSTextAttachment()
            att.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Limiti AI")
            title.append(NSAttributedString(attachment: att))
        }
        item.button?.attributedTitle = title
        item.button?.toolTip = tip.joined(separator: "\n")
    }

    @objc func toggle() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        store.reloadLocal()
        store.fetch(ifOlderThan: 60)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

// `AIUsageBar --snapshot out.png [dark] [settings]` renders the popover to a PNG (for checking the design).
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        let args = CommandLine.arguments
        let store = Store()
        store.reloadLocal()
        if let l = fetchClaudeUsage() { store.claude = Service(name: "Claude Code", plan: claudePlan(), accent: claudeAccent, limits: l, updated: Date()) }
        let host = NSHostingView(rootView: UsageView(store: store, settings: args.contains("settings")))
        host.frame.size = host.fittingSize
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: args.contains("dark") ? .darkAqua : .aqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        host.display()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon
app.run()
