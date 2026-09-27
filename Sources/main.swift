// Burny — a tiny macOS menu bar app showing your Claude Code and Codex (ChatGPT) plan limits.
//
// It makes no network calls of its own and never touches credentials:
//   Claude Code: runs the official `claude -p /usage` (0 tokens — the same request as typing /usage)
//   Codex:       reads the rate_limits the Codex CLI already logs in ~/.codex/sessions/**/rollout-*.jsonl

import AppKit
import SwiftUI
import Combine

let bundleID = "com.burny.menubar"

// MARK: Localization (English + Italian; add a language by adding a table)

var lang = "en"

func resolveLanguage(_ pref: String) -> String {
    pref != "system" ? pref : (Locale.preferredLanguages.first?.hasPrefix("it") == true ? "it" : "en")
}

let italian: [String: String] = [
    "Usage limits": "Limiti di utilizzo",
    "Settings": "Impostazioni",
    "Refresh now": "Aggiorna ora",
    "The tick on each bar shows where you'd be at an even pace.": "La tacca sulla barra indica dove saresti a ritmo costante.",
    "Local data and official clients only": "Solo dati locali e client ufficiali",
    "Quit": "Esci",
    "No data yet — use it once and it will show up here.": "Nessun dato: usalo una volta e comparirà qui.",
    "Claude Code CLI not found.": "CLI di Claude Code non trovata.",
    "The claude binary isn't signed by Anthropic, so Burny won't run it.": "Il binario claude non è firmato da Anthropic: Burny non lo esegue.",
    "The claude CLI answered unexpectedly, so Burny stopped calling it. Restart Burny after updating.":
        "La CLI claude ha risposto in modo inatteso: Burny ha smesso di chiamarla. Riavvia Burny dopo un aggiornamento.",
    "Session": "Sessione",
    "Week": "Settimana",
    "all models": "tutti i modelli",
    "Window": "Finestra",
    "Reset": "Azzerato",
    "Resets in %@ · %@": "Si azzera tra %@ · %@",
    "tomorrow": "domani",
    "d": "g",
    "just now": "adesso",
    "%d min ago": "%d min fa",
    "%d h ago": "%d h fa",
    "%d d ago": "%d g fa",
    "General": "Generale",
    "Open at login": "Apri al login",
    "Language": "Lingua",
    "System": "Sistema",
    "Menu bar": "Barra dei menu",
    "Limit shown": "Limite mostrato",
    "The one closest to running out, session or week.": "Quello più vicino all'esaurimento, tra sessione e settimana.",
    "Most critical": "Più critico",
    "5h session": "Sessione 5h",
    "Percentage": "Percentuale",
    "Used": "Usata",
    "Left": "Rimasta",
    "Refresh": "Aggiornamento",
    "Claude every": "Claude ogni",
    "Runs the official /usage: 0 tokens. Codex is read from local logs every 30 s.":
        "Esegue /usage del client ufficiale: 0 token. Codex si legge dai log locali ogni 30 s.",
]

func tr(_ s: String) -> String { lang == "it" ? italian[s] ?? s : s }

// MARK: Model

enum Kind: Hashable {
    case session(hours: Int)
    case week(model: String?)   // nil = all models
    case other(hours: Int)
}

struct Limit: Identifiable {
    let kind: Kind
    let percent: Double        // 0...100
    let resetsAt: Date?
    let window: TimeInterval   // window length, for the pace marker
    var id: Kind { kind }

    var label: String {
        switch kind {
        case .session(let h): return "\(tr("Session")) · \(h)h"
        case .week(nil): return tr("Week")
        case .week(let m?): return "\(tr("Week")) · \(m == "all models" ? tr(m) : m)"
        case .other(let h): return "\(tr("Window")) \(h)h"
        }
    }
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

/// Only ever run the genuine CLI: its code signature must chain to Apple and belong to Anthropic's team.
/// Verifying hashes the whole ~200 MB binary, so it's done once per binary (path + modification date).
private var verifiedClaude: (path: String, mtime: Date)?

func isGenuineClaude(_ path: String) -> Bool {
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let stamp = (resolved.path, mtime(resolved))
    if let v = verifiedClaude, v == stamp { return true }
    // Apple's own codesign tool does the check in a short-lived process, so its buffers don't stay in Burny's memory.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    p.arguments = ["--verify", "-R=anchor apple generic and certificate leaf[subject.OU] = \"Q6L2SF6YDW\"", resolved.path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    let ok = p.terminationStatus == 0
    if ok { verifiedClaude = stamp }
    return ok
}

enum ClaudeStatus { case ok, notInstalled, notGenuine, unexpectedOutput }
var claudeStatus = ClaudeStatus.ok

/// Runs the official `/usage` slash command in a locked-down CLI. Defense in depth — any one layer is enough:
///  - the input is a constant local command, never text from anywhere else, and the model is never called;
///  - no tools, no MCP servers, no settings/hooks/CLAUDE.md, $0.0001 spending cap, no saved session;
///  - sandboxed away from personal folders; minimal environment;
///  - the output must prove no model turn happened (0 turns, $0, 0 ms API), else Burny stops calling it;
///  - from the output only numbers and dates are extracted with a strict regex; nothing is ever executed.
func fetchClaudeUsage() -> [Limit]? {
    guard let bin = claudeBinary() else { claudeStatus = .notInstalled; return nil }
    guard isGenuineClaude(bin) else { claudeStatus = .notGenuine; return nil }
    let cwd = home.appendingPathComponent("Library/Caches/Burny")
    try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    let p = Process()
    let claudeArgs = ["-p", "/usage", "--output-format", "json", "--no-session-persistence",
                      "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}",
                      "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                      "--max-budget-usd", "0.0001"]
    // Fence the CLI off from privacy-protected folders, so macOS never shows a "would like to access
    // your Desktop/Documents…" prompt on Burny's behalf. /usage doesn't need any of them.
    let sandbox = "/usr/bin/sandbox-exec"
    if FileManager.default.isExecutableFile(atPath: sandbox) {
        let fenced = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library/Mobile Documents"]
            .map { "(subpath \"\(home.appendingPathComponent($0).path)\")" }.joined(separator: " ")
        p.executableURL = URL(fileURLWithPath: sandbox)
        p.arguments = ["-p", "(version 1)(allow default)(deny file-read* file-write* \(fenced))", bin] + claudeArgs
    } else {
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = claudeArgs
    }
    p.currentDirectoryURL = cwd
    var env = ["HOME": home.path, "USER": NSUserName(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
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
    let noModel = (obj["num_turns"] as? NSNumber)?.intValue == 0 && (obj["total_cost_usd"] as? NSNumber)?.doubleValue == 0
        && (obj["duration_api_ms"] as? NSNumber)?.intValue == 0
    let limits = parseUsage(text)
    guard noModel, !limits.isEmpty else { claudeStatus = .unexpectedOutput; return nil }   // CLI changed: stop, don't retry
    claudeStatus = .ok
    return limits
}

// "Current week (Fable): 6% used · resets Oct 3 at 2pm (Europe/Rome)"
func parseUsage(_ text: String) -> [Limit] {
    let re = try! NSRegularExpression(pattern: #"^Current (session|week \((.+?)\)): ([\d.]+)% used(?: · resets (.+?)(?: \(([^)]+)\))?)?\s*$"#, options: .anchorsMatchLines)
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
        func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        guard let pct = g(3).flatMap(Double.init) else { return nil }
        let isSession = g(1) == "session"
        let reset = g(4).flatMap { parseReset($0, tz: g(5)) }
        return Limit(kind: isSession ? .session(hours: 5) : .week(model: g(2)), percent: pct, resetsAt: reset,
                     window: isSession ? 5 * hour : week)
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
//
// Sessions live in ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl and can be tens of MB. To stay light we
// only list the newest day folders, re-read a file only when it changes, and scan it backwards in
// small chunks for the last line carrying rate_limits — no whole-file reads, no big strings.

private var codexCache: (url: URL, mtime: Date, service: Service?)?

func recentCodexFiles() -> [(URL, Date)] {
    let fm = FileManager.default
    func subdirs(_ u: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    var days: [URL] = []
    outer: for y in subdirs(home.appendingPathComponent(".codex/sessions")) {
        for m in subdirs(y) { for d in subdirs(m) { days.append(d); if days.count >= 7 { break outer } } }
    }
    let files = days.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
    return files.filter { $0.pathExtension == "jsonl" }.map { ($0, mtime($0)) }.sorted { $0.1 > $1.1 }
}

/// The last JSON line in `url` that carries rate_limits, reading backwards 256 KB at a time (max 8 MB).
func lastRateLimitLine(_ url: URL) -> [String: Any]? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    let needle = Data("\"primary\":{".utf8), chunk: UInt64 = 256 * 1024
    let size = (try? h.seekToEnd()) ?? 0
    var offset = size, buf = Data(), searchEnd = 0
    func parse(_ d: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              (obj["payload"] as? [String: Any])?["rate_limits"] != nil else { return nil }
        return obj
    }
    while offset > 0 && size - offset < 8 * 1024 * 1024 {
        let start = offset > chunk ? offset - chunk : 0
        try? h.seek(toOffset: start)
        guard let part = try? h.read(upToCount: Int(offset - start)) else { return nil }
        buf = part + buf
        searchEnd += part.count
        offset = start
        while let r = buf.range(of: needle, options: .backwards, in: 0..<searchEnd) {
            guard let nl = buf[..<r.lowerBound].lastIndex(of: 10) else {
                if offset == 0, let end = buf.firstIndex(of: 10) { return parse(buf[..<end]) }   // first line of the file
                break                                                                            // line began in an earlier chunk
            }
            let end = buf[r.upperBound...].firstIndex(of: 10) ?? buf.endIndex
            if let obj = parse(buf[(nl + 1)..<end]) { return obj }
            searchEnd = nl
        }
        buf = Data(buf[..<min(buf.count, searchEnd + 64 * 1024)])   // drop the already-searched tail, keep a margin
    }
    return nil
}

func readCodex() -> Service? {
    let files = recentCodexFiles()
    if let newest = files.first, let c = codexCache, c.url == newest.0, c.mtime == newest.1 { return c.service }
    for (f, mt) in files.prefix(10) {
        guard let obj = autoreleasepool(invoking: { lastRateLimitLine(f) }),
              let rl = (obj["payload"] as? [String: Any])?["rate_limits"] as? [String: Any] else { continue }
        func lim(_ k: String) -> Limit? {
            guard let d = rl[k] as? [String: Any], let p = (d["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let mins = (d["window_minutes"] as? NSNumber)?.intValue ?? 0
            let kind: Kind = mins >= 10080 ? .week(model: nil) : mins > 0 && mins < 1440 ? .session(hours: mins / 60) : .other(hours: mins / 60)
            return Limit(kind: kind, percent: p, resetsAt: epoch(d["resets_at"]), window: Double(mins) * 60)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? mt
        let service = Service(name: "Codex", plan: (rl["plan_type"] as? String)?.capitalized,
                              limits: [lim("primary"), lim("secondary")].compactMap { $0 }, updated: ts)
        if let newest = files.first { codexCache = (newest.0, newest.1, service) }
        return service
    }
    return nil
}

// MARK: Open at login (the LaunchAgent written by install.sh)

enum LoginItem {
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
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return false }
        let disabled = launchctl(["print-disabled", domain])
        return !disabled.contains("\"\(bundleID)\" => disabled") && !disabled.contains("\"\(bundleID)\" => true")
    }

    static func set(_ on: Bool) { launchctl([on ? "enable" : "disable", "\(domain)/\(bundleID)"]) }
}

// MARK: Store

final class Store: ObservableObject {
    @Published var claude: Service?
    @Published var codex: Service?
    @Published var fetching = false

    private static let defaults = UserDefaults.standard
    @Published var language = defaults.string(forKey: "language") ?? "system" {   // system | en | it
        didSet { Self.defaults.set(language, forKey: "language"); lang = resolveLanguage(language) }
    }
    @Published var showClaude = defaults.object(forKey: "showClaude") as? Bool ?? true {
        didSet { Self.defaults.set(showClaude, forKey: "showClaude") }
    }
    @Published var showCodex = defaults.object(forKey: "showCodex") as? Bool ?? true {
        didSet { Self.defaults.set(showCodex, forKey: "showCodex") }
    }
    @Published var barMode = defaults.string(forKey: "barMode") ?? "peak" {   // peak | session | week
        didSet { Self.defaults.set(barMode, forKey: "barMode") }
    }
    @Published var showRemaining = defaults.bool(forKey: "showRemaining") {
        didSet { Self.defaults.set(showRemaining, forKey: "showRemaining") }
    }
    @Published var refreshMinutes = defaults.object(forKey: "refreshMinutes") as? Int ?? 5 {
        didSet { Self.defaults.set(refreshMinutes, forKey: "refreshMinutes") }
    }
    @Published var launchAtLogin = LoginItem.isEnabled {
        didSet { if launchAtLogin != oldValue { LoginItem.set(launchAtLogin) } }
    }

    private var fetched: (limits: [Limit], at: Date)?
    private var plan: String?

    init() { lang = resolveLanguage(language) }

    /// The % used shown in the menu bar for a service, per the "Limit shown" setting.
    func barValue(_ s: Service?) -> Double? {
        guard let s else { return nil }
        let pick = s.limits.filter {
            switch (barMode, $0.kind) {
            case ("session", .session), ("week", .week), ("peak", _): return true
            default: return false
            }
        }
        return pick.map(\.effective).max()
    }

    func reloadLocal() {
        codex = readCodex()
        claude = fetched.map { Service(name: "Claude Code", plan: plan, limits: $0.limits, updated: $0.at) }
    }

    func fetch(ifOlderThan age: TimeInterval = 0) {
        if fetching || claudeStatus == .unexpectedOutput || claudeStatus == .notGenuine { return }
        if let f = fetched, -f.at.timeIntervalSinceNow < age { return }
        fetching = true
        DispatchQueue.global(qos: .utility).async {
            let l = fetchClaudeUsage()
            DispatchQueue.main.async {
                if let l { self.fetched = (l, Date()); self.plan = claudePlan() }
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
    if d < Date() { return tr("Reset") }
    let cal = Calendar.current, f = DateFormatter()
    f.locale = Locale(identifier: lang == "it" ? "it_IT" : "en_US")
    f.dateFormat = cal.isDateInToday(d) || cal.isDateInTomorrow(d) ? "HH:mm" : "EEE d · HH:mm"
    let when = (cal.isDateInTomorrow(d) ? tr("tomorrow") + " " : "") + f.string(from: d)
    let m = Int(d.timeIntervalSinceNow / 60)
    let rel = m < 60 ? "\(m)m" : m < 1440 ? "\(m / 60)h \(m % 60)m" : "\(m / 1440)\(tr("d")) \(m % 1440 / 60)h"
    return String(format: tr("Resets in %@ · %@"), rel, when)
}

func ago(_ d: Date?) -> String {
    guard let d else { return "" }
    let m = Int(-d.timeIntervalSinceNow / 60)
    return m < 1 ? tr("just now") : m < 60 ? String(format: tr("%d min ago"), m)
        : m < 1440 ? String(format: tr("%d h ago"), m / 60) : String(format: tr("%d d ago"), m / 1440)
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
    var emptyMessage: String {
        guard name == "Claude Code" else { return "No data yet — use it once and it will show up here." }
        switch claudeStatus {
        case .notInstalled: return "Claude Code CLI not found."
        case .notGenuine: return "The claude binary isn't signed by Anthropic, so Burny won't run it."
        case .unexpectedOutput: return "The claude CLI answered unexpectedly, so Burny stopped calling it. Restart Burny after updating."
        case .ok: return "No data yet — use it once and it will show up here."
        }
    }
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
                Text(tr(emptyMessage)).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055)))
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
                Text(tr(settings ? "Settings" : "Usage limits")).font(.system(size: 14, weight: .bold))
                Spacer()
                if !settings {
                    if store.fetching { ProgressView().controlSize(.small).scaleEffect(0.8) }
                    Button { store.fetch() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help(tr("Refresh now"))
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help(tr("Settings"))
                }
            }
            if settings {
                SettingsView(store: store)
            } else {
                ServiceCard(service: store.claude, name: "Claude Code", accent: claudeAccent)
                ServiceCard(service: store.codex, name: "Codex", accent: codexAccent)
                Text(tr("The tick on each bar shows where you'd be at an even pace."))
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            Divider()
            HStack {
                Image(systemName: "lock.shield").font(.system(size: 10))
                Text(tr("Local data and official clients only")).font(.system(size: 10.5))
                Spacer()
                Button(tr("Quit")) { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.system(size: 11))
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
            Text(tr(title).uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
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
                Text(tr(label)).font(.system(size: 12))
                if let note { Text(tr(note)).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
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
            SettingsSection(title: "General") {
                SettingRow(label: "Open at login") {
                    Toggle("", isOn: $store.launchAtLogin).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                SettingRow(label: "Language") {
                    Picker("", selection: $store.language) {
                        Text(tr("System")).tag("system")
                        Text("English").tag("en")
                        Text("Italiano").tag("it")
                    }
                    .labelsHidden().fixedSize()
                }
            }
            SettingsSection(title: "Menu bar") {
                SettingRow(label: "Claude Code") {
                    Toggle("", isOn: $store.showClaude).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                SettingRow(label: "Codex") {
                    Toggle("", isOn: $store.showCodex).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                Divider()
                SettingRow(label: "Limit shown", note: store.barMode == "peak" ? "The one closest to running out, session or week." : nil) {
                    Picker("", selection: $store.barMode) {
                        Text(tr("Most critical")).tag("peak")
                        Text(tr("5h session")).tag("session")
                        Text(tr("Week")).tag("week")
                    }
                    .labelsHidden().fixedSize()
                }
                SettingRow(label: "Percentage") {
                    Picker("", selection: $store.showRemaining) {
                        Text(tr("Used")).tag(false)
                        Text(tr("Left")).tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            SettingsSection(title: "Refresh") {
                SettingRow(label: "Claude every", note: "Runs the official /usage: 0 tokens. Codex is read from local logs every 30 s.") {
                    Picker("", selection: $store.refreshMinutes) {
                        ForEach([2, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }
}

// MARK: Drawing (menu bar fallback ring, app icon)

func ring(_ p: Double?, _ accent: NSColor) -> NSImage {
    NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
        let rect = r.insetBy(dx: 1.75, dy: 1.75)
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = 2.5
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        track.stroke()
        if let p, p > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: rect.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * CGFloat(min(p, 100)) / 100, clockwise: true)
            arc.lineWidth = 2.5
            arc.lineCapStyle = .round
            (p >= 90 ? NSColor.systemRed : p >= 75 ? NSColor.systemOrange : accent).setStroke()
            arc.stroke()
        }
        return true
    }
}

/// The app icon: Burny, a little flame with eyes, on a warm dark squircle.
func drawAppIcon(px: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    let s = CGFloat(px)
    func rgb(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let body = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)   // Apple icon grid margin
    let squircle = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: rgb(0x2B1B18), ending: rgb(0x120B0A))?.draw(in: squircle, angle: -90)
    squircle.addClip()
    NSGradient(colors: [rgb(0xFF6A1F, 0.38), rgb(0xFF6A1F, 0)])?   // warm glow behind the flame
        .draw(fromCenter: NSPoint(x: body.midX, y: body.minY + body.height * 0.36), radius: 0,
              toCenter: NSPoint(x: body.midX, y: body.minY + body.height * 0.36), radius: body.width * 0.55, options: [])

    // Flame paths in unit coordinates inside a box slightly smaller than the body.
    let box = body.insetBy(dx: body.width * 0.12, dy: body.height * 0.08)
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: box.minX + x * box.width, y: box.minY + y * box.height) }
    func path(_ start: (CGFloat, CGFloat), _ curves: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)]) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: pt(start.0, start.1))
        for c in curves { p.curve(to: pt(c.4, c.5), controlPoint1: pt(c.0, c.1), controlPoint2: pt(c.2, c.3)) }
        p.close()
        return p
    }
    let flame = path((0.50, 0.04), [
        (0.27, 0.04, 0.12, 0.22, 0.14, 0.42),   // left belly
        (0.16, 0.58, 0.26, 0.66, 0.29, 0.78),   // up to the left tongue
        (0.36, 0.70, 0.41, 0.66, 0.45, 0.64),   // into the notch
        (0.44, 0.78, 0.53, 0.90, 0.63, 0.98),   // up to the main tip
        (0.67, 0.86, 0.75, 0.77, 0.80, 0.66),   // right shoulder
        (0.88, 0.52, 0.89, 0.40, 0.86, 0.30),
        (0.80, 0.13, 0.67, 0.04, 0.50, 0.04),
    ])
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = rgb(0xFF4A1A, 0.55)
    shadow.shadowBlurRadius = s * 0.06
    shadow.set()
    NSGradient(colors: [rgb(0xFFB02E), rgb(0xFF6A1F), rgb(0xF2372B)], atLocations: [0, 0.45, 1], colorSpace: .sRGB)?
        .draw(in: flame, angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    let core = path((0.50, 0.10), [
        (0.36, 0.10, 0.27, 0.21, 0.28, 0.35),
        (0.29, 0.48, 0.41, 0.55, 0.50, 0.68),
        (0.58, 0.55, 0.72, 0.48, 0.72, 0.35),
        (0.72, 0.21, 0.64, 0.10, 0.50, 0.10),
    ])
    NSGradient(starting: rgb(0xFFF1A8), ending: rgb(0xFFC23D))?.draw(in: core, angle: 90)

    // Face: two eyes with a highlight, and a small smile.
    for x in [0.42, 0.58] as [CGFloat] {
        let e = pt(x, 0.31), w = box.width * 0.058, h = box.height * 0.085
        rgb(0x3A1408).setFill()
        NSBezierPath(ovalIn: NSRect(x: e.x - w / 2, y: e.y - h / 2, width: w, height: h)).fill()
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: e.x - w * 0.05, y: e.y + h * 0.08, width: w * 0.36, height: w * 0.36)).fill()
    }
    let smile = NSBezierPath()
    smile.move(to: pt(0.455, 0.225))
    smile.curve(to: pt(0.545, 0.225), controlPoint1: pt(0.475, 0.18), controlPoint2: pt(0.525, 0.18))
    smile.lineWidth = box.width * 0.022
    smile.lineCapStyle = .round
    rgb(0x3A1408).setStroke()
    smile.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: Menu bar

final class App: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let store = Store()
    var bag: AnyCancellable?
    var timers: [Timer] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        popover.behavior = .transient
        popover.delegate = self
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
    // Rasterised once at menu bar size (@2x) so the full 1024 px icon isn't kept around.
    lazy var icons: [NSImage?] = ["/Applications/Claude.app", "/Applications/ChatGPT.app"].map { path in
        guard FileManager.default.fileExists(atPath: path),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 34, pixelsHigh: 34, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSWorkspace.shared.icon(forFile: path).draw(in: NSRect(x: 0, y: 0, width: 34, height: 34))
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: 17, height: 17))
        img.addRepresentation(rep)
        return img
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
            let p = store.barValue(s)   // colour always follows % used
            let att = NSTextAttachment()
            att.image = icons[i] ?? ring(p, accent)
            att.bounds = CGRect(x: 0, y: -4, width: 17, height: 17)
            title.append(NSAttributedString(attachment: att))
            let color: NSColor = p.map { $0 >= 90 ? .systemRed : $0 >= 75 ? .systemOrange : .labelColor } ?? .secondaryLabelColor
            let value = p.map { store.showRemaining ? max(0, 100 - $0) : $0 }
            title.append(NSAttributedString(string: " " + (value.map { "\(Int($0.rounded()))%" } ?? "–"), attributes: [.font: font, .foregroundColor: color]))
        }
        if title.length == 0 {   // both hidden: keep a clickable glyph
            let att = NSTextAttachment()
            att.image = NSImage(systemSymbolName: "flame", accessibilityDescription: "Burny")
            title.append(NSAttributedString(attachment: att))
        }
        item.button?.attributedTitle = title
        item.button?.toolTip = tip.joined(separator: "\n")
    }

    func popoverDidClose(_ n: Notification) { popover.contentViewController = nil }

    @objc func toggle() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        store.reloadLocal()
        store.fetch(ifOlderThan: 60)
        // The SwiftUI view is built on open and dropped on close, so it costs no memory while hidden.
        let host = NSHostingController(rootView: UsageView(store: store))
        host.sizingOptions = [.preferredContentSize]   // grow/shrink with content instead of clipping
        popover.contentViewController = host
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

// MARK: Entry point
//
// Dev helpers:  --icon out.png [px]                        renders the app icon
//               --snapshot out.png [dark] [settings] [en|it]  renders the popover with live data

let args = CommandLine.arguments
func png(_ rep: NSBitmapImageRep, _ path: String) {
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
    if let rep = drawAppIcon(px: i + 2 < args.count ? Int(args[i + 2]) ?? 1024 : 1024) { png(rep, args[i + 1]) }
    exit(0)
}

if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    MainActor.assumeIsolated {
        let store = Store()
        if args.contains("en") { lang = "en" } else if args.contains("it") { lang = "it" }
        store.reloadLocal()
        if let l = fetchClaudeUsage() { store.claude = Service(name: "Claude Code", plan: claudePlan(), limits: l, updated: Date()) }
        // Menu bar values, for the README composer: "<claude> <codex>"
        print([store.claude, store.codex].map { store.barValue($0).map { "\(Int($0.rounded()))%" } ?? "–" }.joined(separator: " "))
        let host = NSHostingView(rootView: UsageView(store: store, settings: args.contains("settings")))
        host.frame.size = host.fittingSize
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: args.contains("dark") ? .darkAqua : .aqua)
        win.backgroundColor = .windowBackgroundColor
        win.contentView = host
        for _ in 0..<3 {   // re-measure until stable once the view sits in a window with its appearance
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
        }
        host.display()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            png(rep, args[i + 1])
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon
app.run()
