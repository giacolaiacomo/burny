// Burny — a tiny macOS menu bar app showing your Claude Code and Codex (ChatGPT) plan limits.
//
// It never contacts Anthropic or OpenAI itself and never touches credentials:
//   Claude Code: runs the official `claude -p /usage` (0 tokens — the same request as typing /usage)
//   Codex:       reads the rate_limits the Codex CLI already logs in ~/.codex/sessions/**/rollout-*.jsonl
// Its only possible network request is the opt-in update check to GitHub's public releases API.

import AppKit
import SwiftUI
import Combine
import UserNotifications

let bundleID = "com.burny.menubar"
let repoSlug = "giacolaiacomo/burny"
let appVersion = "1.4.0"   // install.sh reads this for Info.plist

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
    "Refresh": "Frequenza",
    "Claude every": "Claude ogni",
    "Runs the official /usage: 0 tokens. Codex is read from local logs every 30 s.":
        "Esegue /usage del client ufficiale: 0 token. Codex si legge dai log locali ogni 30 s.",
    "Runs out ~%@ at this pace": "Finisce verso %@ a questo ritmo",
    "At this week's pace it runs out ~%@": "Al ritmo di questa settimana finisce verso %@",
    "Updates when you use Codex.": "Si aggiorna quando usi Codex.",
    "Notifications": "Notifiche",
    "Alert at 80% and 90%": "Avvisa all'80% e al 90%",
    "Once per limit and window.": "Una volta per limite e finestra.",
    "%@ at %d%%": "%@ al %d%%",
    "%@ · resets %@": "%@ · si azzera %@",
    "Updates": "Nuove versioni",
    "Check for updates": "Controlla aggiornamenti",
    "Once a day asks GitHub for the latest release. Nothing else is sent, nothing is installed.":
        "Una volta al giorno chiede a GitHub l'ultima versione. Non invia altro e non installa nulla.",
    "Burny %@ is available": "È disponibile Burny %@",
    "View": "Vedi",
    "You're up to date.": "Sei aggiornato.",
    "Check now": "Controlla ora",
    "Once per limit and window. Also tells you when a limit past 90% resets.":
        "Una volta per limite e finestra. Ti avvisa anche quando un limite oltre il 90% si azzera.",
    "%@: limit reset, you're good to go.": "%@: limite azzerato, puoi ripartire.",
    "~%d%% a day lasts until the reset": "~%d%% al giorno per arrivare al reset",
    "%@ is nearly used up. Other models still have %d%% left this week.":
        "%@ è quasi esaurito. Agli altri modelli resta il %d%% questa settimana.",
    "Show": "Mostra",
    "% used": "% usata",
    "% left": "% rimasta",
    "Time to reset": "Tempo al reset",
    "Icon only": "Solo icona",
    "Where it went": "Dove sono finiti",
    "Reading local logs…": "Leggo i log locali…",
    "%d%% used · %@ tokens": "%d%% usato · %@ token",
    "%@ tokens": "%@ token",
    "≈ $%@ at API prices": "≈ $%@ a prezzi API",
    "What the same usage would cost on the API, at list prices.": "Quanto costerebbe lo stesso utilizzo via API, a prezzi di listino.",
    "%@ vs last week at this point": "%@ rispetto alla settimana scorsa a questo punto",
    "No usage in this window.": "Nessun utilizzo in questa finestra.",
    "Temporary folders": "Cartelle temporanee",
    "Unknown": "Sconosciuto",
    "Other": "Altro",
    "Last 14 days": "Ultimi 14 giorni",
    "today": "oggi",
    "Estimated from Claude Code's and Codex's local logs, weighted by API price. The official % comes from the CLIs. Nothing leaves your Mac.":
        "Stima dai log locali di Claude Code e Codex, pesata sui prezzi API. La % ufficiale viene dai client. Nulla esce dal Mac.",
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

    var measuredAt = Date()        // when `percent` was observed
    var recentRate: Double? = nil  // sessions: % per second over the last 30 min of readings, set by Store

    var isSession: Bool { if case .session = kind { return true }; return false }

    /// Burn rate in % per second. The rules come from replaying ten weeks of real usage logs:
    ///  - session: the last 30 minutes predict best; the average since the window opened raised twice as many false alarms;
    ///  - longer windows: the average since the window opened (nights and idle days included), once a day of it has
    ///    passed; the last few hours swing with every burst of work and were right barely half the time.
    var rate: Double? {
        if isSession { return recentRate }
        guard let r = resetsAt, window > 0, percent > 0 else { return nil }
        let elapsed = window - r.timeIntervalSince(measuredAt)
        guard elapsed >= min(24 * hour, window * 0.2) else { return nil }   // too early in the window to tell
        return percent / elapsed
    }

    /// Weekly limits: the share you can use per day and still last until the reset.
    var dailyBudget: Double? {
        guard case .week = kind, let r = resetsAt, r.timeIntervalSinceNow > 86400, effective < 100 else { return nil }
        return (100 - effective) / (r.timeIntervalSinceNow / 86400)
    }

    /// When the limit hits 100% at the current burn rate. Shown only when it's likely: the pace must reach 115%
    /// before the reset (a 15% margin), and a session forecast only looks one hour ahead. In the replay this cut
    /// false alarms from 17% to 5% of the time (session) and from 12% to 4% (week).
    var runsOutAt: Date? {
        guard percent < 100, let rate, rate > 0, let r = resetsAt, r > Date(),
              -measuredAt.timeIntervalSinceNow < 6 * hour else { return nil }   // no forecasts from stale data
        guard measuredAt.addingTimeInterval((115 - percent) / rate) < r else { return nil }
        let eta = max(measuredAt.addingTimeInterval((100 - percent) / rate), Date())
        if isSession && eta.timeIntervalSinceNow > hour { return nil }
        return eta
    }

    /// The forecast as text, only as precise as it deserves: minutes for a session, the day for a week (the hour once it's close).
    var runsOutText: String? {
        guard let eta = runsOutAt else { return nil }
        if isSession {
            let rounded = Date(timeIntervalSinceReferenceDate: (eta.timeIntervalSinceReferenceDate / 300).rounded() * 300)
            return String(format: tr("Runs out ~%@ at this pace"), shortWhen(rounded))
        }
        let cal = Calendar.current
        let when: String
        if eta.timeIntervalSinceNow < 24 * hour {
            when = shortWhen(cal.dateInterval(of: .hour, for: eta.addingTimeInterval(1800))?.start ?? eta)
        } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: lang == "it" ? "it_IT" : "en_US")
            f.dateFormat = "EEEE"
            when = cal.isDateInTomorrow(eta) ? tr("tomorrow") : f.string(from: eta)
        }
        return String(format: tr("At this week's pace it runs out ~%@"), when)
    }
}

struct Service {
    let name: String
    let plan: String?
    var limits: [Limit]
    let updated: Date?

    /// A per-model weekly bucket (e.g. Fable) past 90% while the all-models week still has room: suggest switching.
    var switchHint: (limit: Limit, text: String)? {
        guard let all = limits.first(where: { $0.kind == .week(model: "all models") }), all.effective < 90,
              let tight = limits.first(where: { if case .week(let m?) = $0.kind { return m != "all models" && $0.effective >= 90 }; return false }),
              case .week(let m?) = tight.kind else { return nil }
        return (tight, String(format: tr("%@ is nearly used up. Other models still have %d%% left this week."), m, Int((100 - all.effective).rounded())))
    }
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
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = f.timeZone
    f.defaultDate = cal.startOfDay(for: Date())   // fields the text omits (year, day, minutes) must not come from the clock
    let str = s.uppercased().replacingOccurrences(of: " AT ", with: " at ")
    for fmt in ["MMM d 'at' h:mma", "MMM d 'at' ha", "h:mma", "ha", "MMM d"] {
        f.dateFormat = fmt
        if var d = f.date(from: str) {
            if fmt.hasPrefix("h"), d < Date() { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }   // time only: next occurrence
            if d < Date().addingTimeInterval(-86400) { d = cal.date(byAdding: .year, value: 1, to: d) ?? d }
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
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? mt
        func lim(_ k: String) -> Limit? {
            guard let d = rl[k] as? [String: Any], let p = (d["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let mins = (d["window_minutes"] as? NSNumber)?.intValue ?? 0
            let kind: Kind = mins >= 10080 ? .week(model: nil) : mins > 0 && mins < 1440 ? .session(hours: mins / 60) : .other(hours: mins / 60)
            var l = Limit(kind: kind, percent: p, resetsAt: epoch(d["resets_at"]), window: Double(mins) * 60)
            l.measuredAt = ts
            return l
        }
        let service = Service(name: "Codex", plan: (rl["plan_type"] as? String)?.capitalized,
                              limits: [lim("primary"), lim("secondary")].compactMap { $0 }, updated: ts)
        if let newest = files.first { codexCache = (newest.0, newest.1, service) }
        return service
    }
    return nil
}

// MARK: Where it went — token usage from the CLIs' own local logs
//
// Claude Code logs each reply with its token usage in ~/.claude/projects/**/*.jsonl; Codex logs token counts in
// its session files. Burny adds these up per hour, project and model, weighted by API list price, to split the
// official % by project. Only numbers, model names, timestamps and the project folder's name are kept. Each file
// is read from where the last look stopped, the totals live in ~/Library/Caches/Burny/usage.json, and all of it
// runs only while the breakdown is open.

/// $ per million tokens: input, output, cache read. Cache writes cost 1.25× input (5 min) or 2× input (1 h).
func claudePrice(_ model: String) -> (Double, Double, Double)? {
    let m = model.lowercased()
    guard m.hasPrefix("claude") else { return nil }   // e.g. "<synthetic>": not a real API call
    if m.contains("fable") || m.contains("mythos") { return m.contains("5-1") ? (10, 50, 0.25) : (10, 50, 1) }
    if m.contains("opus-5-5") { return (4, 20, 0.2) }
    if m.contains("opus") { return (5, 25, 0.5) }
    if m.contains("haiku") { return (1, 5, 0.1) }
    return (3, 15, 0.3)   // Sonnet and anything newer
}

func claudeCost(model: String, usage u: [String: Any]) -> (cost: Double, tokens: Double)? {
    guard let (i, o, r) = claudePrice(model) else { return nil }
    func n(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
    let input = n(u, "input_tokens"), output = n(u, "output_tokens"), read = n(u, "cache_read_input_tokens")
    let write = n(u, "cache_creation_input_tokens")
    let write1h = min(write, n(u["cache_creation"] as? [String: Any] ?? [:], "ephemeral_1h_input_tokens"))
    let cost = input * i + output * o + read * r + (write - write1h) * i * 1.25 + write1h * i * 2
    return (cost / 1e6, input + output + read + write)
}

/// "claude-opus-5-5" → "Opus 5.5", "claude-haiku-4-5-20251001" → "Haiku 4.5", "gpt-6-astra" → "GPT-6 Astra".
func modelName(_ id: String) -> String {
    var parts = id.split(separator: "-").map(String.init)
    if parts.first == "claude" { parts.removeFirst() }
    if parts.last.map({ $0.count == 8 && Int($0) != nil }) == true { parts.removeLast() }
    guard let family = parts.first else { return id }
    if family == "gpt", parts.count > 1 {
        return (["GPT-" + parts[1]] + parts.dropFirst(2).map(\.capitalized)).joined(separator: " ")
    }
    let rest = parts.dropFirst()
    let version = rest.allSatisfy { Int($0) != nil } ? rest.joined(separator: ".") : rest.map(\.capitalized).joined(separator: " ")
    return family.capitalized + (version.isEmpty ? "" : " " + version)
}

let tempProject = "(temp)"

func projectName(_ cwd: String?) -> String {
    guard var cwd, !cwd.isEmpty else { return "?" }
    if let r = cwd.range(of: "/.claude/worktrees/") { cwd = String(cwd[..<r.lowerBound]) }   // agent worktrees count for their project
    if ["/private/var/", "/var/folders/", "/tmp", "/private/tmp"].contains(where: cwd.hasPrefix) { return tempProject }
    if cwd == home.path { return "~" }
    return URL(fileURLWithPath: cwd).lastPathComponent
}

final class UsageLedger {
    struct FileState: Codable {
        var offset: UInt64 = 0
        var lastID: String?, lastKey: String?, lastCost = 0.0, lastTokens = 0.0   // Claude: one reply is logged once per content block
        var project: String?, model: String?, totals: [Double]?                    // Codex: session folder, model, running token totals
    }
    struct Saved: Codable {
        var version = 2
        var files: [String: FileState] = [:]
        var buckets: [String: [Double]] = [:]   // "service\thour\tproject\tmodel" → [cost, tokens]
    }
    static let keepDays = 15.0

    let claudeRoot: URL, codexRoot: URL, cacheURL: URL
    var saved = Saved()
    private let cutoff = Date().addingTimeInterval(-keepDays * 86400)
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(claudeRoot: URL = home.appendingPathComponent(".claude/projects"),
         codexRoot: URL = home.appendingPathComponent(".codex/sessions"),
         cacheURL: URL = home.appendingPathComponent("Library/Caches/Burny/usage.json")) {
        self.claudeRoot = claudeRoot; self.codexRoot = codexRoot; self.cacheURL = cacheURL
        if let d = try? Data(contentsOf: cacheURL), let s = try? JSONDecoder().decode(Saved.self, from: d), s.version == Saved().version {
            saved = s
        }
    }

    /// Reads whatever the logs gained since last time, drops data older than `keepDays`, saves.
    func update() {
        var seen = Set<String>()
        for (service, root, needles) in [("Claude Code", claudeRoot, ["\"usage\":{"]),
                                         ("Codex", codexRoot, ["\"token_count\"", "\"session_meta\"", "\"turn_context\""])] {
            for (url, size) in logFiles(root) {
                let path = url.path
                seen.insert(path)
                var st = saved.files[path] ?? FileState()
                if size < st.offset { st = FileState() }   // file was rewritten: start over
                guard size > st.offset else { saved.files[path] = st; continue }
                st.offset = readLines(url, from: st.offset, needles: needles.map { Data($0.utf8) }) { line in
                    guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
                    if service == "Codex" { codexLine(o, &st) } else { claudeLine(o, &st) }
                }
                saved.files[path] = st
            }
        }
        saved.files = saved.files.filter { seen.contains($0.key) }
        let oldest = Int(cutoff.timeIntervalSince1970 / hour)
        saved.buckets = saved.buckets.filter { k, _ in Int(k.split(separator: "\t")[1]).map { $0 >= oldest } ?? false }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: cacheURL, options: .atomic)
    }

    private func logFiles(_ root: URL) -> [(URL, UInt64)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { item in
            guard let u = item as? URL, u.pathExtension == "jsonl", let v = try? u.resourceValues(forKeys: Set(keys)),
                  (v.contentModificationDate ?? .distantPast) >= cutoff else { return nil }
            return (u, UInt64(v.fileSize ?? 0))
        }
    }

    /// Calls `line` for each complete line after `from` containing one of `needles`; returns the offset after the last full line.
    private func readLines(_ url: URL, from: UInt64, needles: [Data], _ line: (Data) -> Void) -> UInt64 {
        guard let h = try? FileHandle(forReadingFrom: url) else { return from }
        defer { try? h.close() }
        try? h.seek(toOffset: from)
        var offset = from, carry = Data()
        while true {
            let more: Bool = autoreleasepool {
                guard let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                let buf = carry + chunk
                var matches: [Data] = [], consumed = 0
                buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { return }
                    while consumed < raw.count, let nl = memchr(base + consumed, 10, raw.count - consumed) {
                        let end = base.distance(to: UnsafeRawPointer(nl))
                        let hit = needles.contains { n in
                            n.withUnsafeBytes { memmem(base + consumed, end - consumed, $0.baseAddress, n.count) != nil }
                        }
                        if hit { matches.append(Data(bytes: base + consumed, count: end - consumed)) }
                        consumed = end + 1
                    }
                }
                for m in matches { autoreleasepool { line(m) } }
                offset += UInt64(consumed)
                carry = buf.subdata(in: consumed..<buf.count)
                return true
            }
            if !more { break }
        }
        return offset
    }

    private func add(_ key: String, _ cost: Double, _ tokens: Double) {
        var b = saved.buckets[key] ?? [0, 0]
        b[0] += cost; b[1] += tokens
        saved.buckets[key] = b
    }

    private func key(_ service: String, _ at: Date, _ project: String, _ model: String) -> String {
        "\(service)\t\(Int(at.timeIntervalSince1970 / hour))\t\(project)\t\(model)"
    }

    private let isoPlain = ISO8601DateFormatter()
    private func date(_ v: Any?) -> Date? { (v as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) } }

    private func claudeLine(_ o: [String: Any], _ st: inout FileState) {
        guard o["type"] as? String == "assistant", let m = o["message"] as? [String: Any], let model = m["model"] as? String,
              let u = m["usage"] as? [String: Any], let c = claudeCost(model: model, usage: u),
              let at = date(o["timestamp"]), at >= cutoff else { return }
        let id = m["id"] as? String
        if let id, id == st.lastID, let k = st.lastKey {   // same reply again: keep only its latest numbers
            add(k, c.cost - st.lastCost, c.tokens - st.lastTokens)
        } else {
            st.lastKey = key("Claude Code", at, projectName(o["cwd"] as? String), model)
            add(st.lastKey!, c.cost, c.tokens)
        }
        st.lastID = id; st.lastCost = c.cost; st.lastTokens = c.tokens
    }

    private func codexLine(_ o: [String: Any], _ st: inout FileState) {
        guard let p = o["payload"] as? [String: Any] else { return }
        switch o["type"] as? String {
        case "session_meta": st.project = projectName(p["cwd"] as? String)
        case "turn_context": st.model = p["model"] as? String ?? st.model
        default:
            guard p["type"] as? String == "token_count", let info = p["info"] as? [String: Any],
                  let t = info["total_token_usage"] as? [String: Any], let at = date(o["timestamp"]) else { return }
            let now = ["input_tokens", "cached_input_tokens", "output_tokens"].map { (t[$0] as? NSNumber)?.doubleValue ?? 0 }
            let prev = st.totals ?? [0, 0, 0]
            st.totals = now
            let d = now[0] >= prev[0] ? zip(now, prev).map { max(0, $0 - $1) } : now   // totals only grow within a session
            guard at >= cutoff, d.contains(where: { $0 > 0 }) else { return }
            // Relative weight at GPT list-price ratios (cached input 0.1×, output 8×); only shares are shown for Codex.
            let cost = ((d[0] - d[1]) * 1.25 + d[1] * 0.125 + d[2] * 10) / 1e6
            add(key("Codex", at, st.project ?? "?", st.model ?? "codex"), cost, d[0] + d[2])
        }
    }

    /// Totals for a service between two dates, split by project and by model (largest first).
    func split(_ service: String, from: Date, to: Date) -> (cost: Double, tokens: Double, projects: [(String, Double)], models: [(String, Double)]) {
        let lo = Int(from.timeIntervalSince1970 / hour), hi = Int(to.timeIntervalSince1970 / hour)
        var cost = 0.0, tokens = 0.0, projects: [String: Double] = [:], models: [String: Double] = [:]
        for (k, v) in saved.buckets {
            let f = k.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, f[0] == service, let h = Int(f[1]), h >= lo, h <= hi else { continue }
            cost += v[0]; tokens += v[1]
            projects[f[2], default: 0] += v[0]
            models[modelName(f[3]), default: 0] += v[0]
        }
        return (cost, tokens, projects.sorted { $0.value > $1.value }.map { ($0.key, $0.value) },
                models.sorted { $0.value > $1.value }.map { ($0.key, $0.value) })
    }

    /// Cost per local day for the last `days` days, oldest first.
    func daily(_ service: String, days: Int) -> [Double] {
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        var out = [Double](repeating: 0, count: days)
        for (k, v) in saved.buckets {
            let f = k.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 4, f[0] == service, let h = Double(f[1]) else { continue }
            let day = cal.dateComponents([.day], from: cal.startOfDay(for: Date(timeIntervalSince1970: h * hour)), to: today).day ?? days
            if day >= 0 && day < days { out[days - 1 - day] += v[0] }
        }
        return out
    }
}

/// What the breakdown page shows for one service and window.
struct UsagePart: Identifiable {
    let service: String
    let percent: Double?              // the official % used in this window, when known
    let cost: Double, tokens: Double
    let projects: [(name: String, cost: Double)]
    let models: [(name: String, cost: Double)]
    let previous: Double?             // week only: cost at the same point of last week's window
    let daily: [Double]               // week only: cost per day, last 14 days
    var windowDays = 0                // how many of those days fall in the current week window
    var id: String { service }
}

struct Breakdown {
    var bySession: [UsagePart] = []
    var byWeek: [UsagePart] = []

    init(bySession: [UsagePart], byWeek: [UsagePart]) { self.bySession = bySession; self.byWeek = byWeek }

    /// `windows`: per service, the start of the current session and week and their official % used.
    init(_ ledger: UsageLedger, windows: [(service: String, session: (Date, Double?), week: (Date, Double?))]) {
        for w in windows {
            let now = Date()
            let s = ledger.split(w.service, from: w.session.0, to: now), k = ledger.split(w.service, from: w.week.0, to: now)
            let prev = ledger.split(w.service, from: w.week.0.addingTimeInterval(-week), to: now.addingTimeInterval(-week)).cost
            bySession.append(UsagePart(service: w.service, percent: w.session.1, cost: s.cost, tokens: s.tokens,
                                     projects: s.projects.map { ($0.0, $0.1) }, models: s.models.map { ($0.0, $0.1) }, previous: nil, daily: []))
            byWeek.append(UsagePart(service: w.service, percent: w.week.1, cost: k.cost, tokens: k.tokens,
                                       projects: k.projects.map { ($0.0, $0.1) }, models: k.models.map { ($0.0, $0.1) },
                                       previous: prev > 0 ? prev : nil, daily: ledger.daily(w.service, days: 14),
                                       windowDays: 1 + (Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: w.week.0),
                                                                                        to: Calendar.current.startOfDay(for: now)).day ?? 6)))
        }
    }
}

// MARK: Open at login (the LaunchAgent written by install.sh)

enum LoginItem {
    static var domain: String { "gui/\(getuid())" }
    /// install.sh writes com.burny.menubar; `brew services` writes sh.brew.burny (homebrew.mxcl.burny on older Homebrew).
    static let labels = [bundleID, "sh.brew.burny", "homebrew.mxcl.burny"]
    static func plist(_ label: String) -> URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    static var label: String? { labels.first { FileManager.default.fileExists(atPath: plist($0).path) } }

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
        guard let label else { return false }
        let disabled = launchctl(["print-disabled", domain])
        return !disabled.contains("\"\(label)\" => disabled") && !disabled.contains("\"\(label)\" => true")
    }

    static func set(_ on: Bool) {
        if on && label == nil { writeAgent() }
        launchctl([on ? "enable" : "disable", "\(domain)/\(label ?? bundleID)"])
    }

    /// For a copy installed without install.sh or `brew services`: a LaunchAgent that starts this copy at the next login.
    static func writeAgent() {
        guard var exe = Bundle.main.executablePath else { return }
        if let r = exe.range(of: #"/Cellar/burny/[^/]+/"#, options: .regularExpression) { exe.replaceSubrange(r, with: "/opt/burny/") }   // survives brew upgrades
        let agent: [String: Any] = ["Label": bundleID, "ProgramArguments": [exe], "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false]]
        try? FileManager.default.createDirectory(at: plist(bundleID).deletingLastPathComponent(), withIntermediateDirectories: true)
        (agent as NSDictionary).write(to: plist(bundleID), atomically: true)
    }
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
    @Published var barText = defaults.string(forKey: "barText") ?? (defaults.bool(forKey: "showRemaining") ? "left" : "used") {   // used | left | reset | icon
        didSet { Self.defaults.set(barText, forKey: "barText") }
    }
    @Published var refreshMinutes = defaults.object(forKey: "refreshMinutes") as? Int ?? 5 {
        didSet { Self.defaults.set(refreshMinutes, forKey: "refreshMinutes") }
    }
    @Published var launchAtLogin = LoginItem.isEnabled {
        didSet { if launchAtLogin != oldValue { LoginItem.set(launchAtLogin) } }
    }
    @Published var notify = defaults.bool(forKey: "notify") {
        didSet {
            Self.defaults.set(notify, forKey: "notify")
            let center = UNUserNotificationCenter.current()
            if notify { center.requestAuthorization(options: [.alert, .sound]) { _, _ in } } else { center.removeAllPendingNotificationRequests() }
        }
    }
    @Published var checkUpdates = defaults.bool(forKey: "checkUpdates") {
        didSet { Self.defaults.set(checkUpdates, forKey: "checkUpdates"); if checkUpdates { checkForUpdates(force: true) } }
    }
    @Published var update: (version: String, url: URL)?
    @Published var upToDate = false

    @Published var breakdown: Breakdown?
    @Published var readingLogs = false

    /// Each service's current session and week start, from the official limits (or the last 5 h / 7 days).
    func usageWindows() -> [(service: String, session: (Date, Double?), week: (Date, Double?))] {
        [claude, codex].enumerated().map { i, s in
            func window(_ match: (Kind) -> Bool, _ length: TimeInterval) -> (Date, Double?) {
                if let l = s?.limits.first(where: { match($0.kind) }), let r = l.resetsAt, r > Date() { return (r.addingTimeInterval(-l.window), l.effective) }
                return (Date().addingTimeInterval(-length), nil)
            }
            return (i == 0 ? "Claude Code" : "Codex",
                    window({ if case .session = $0 { return true }; return false }, 5 * hour),
                    window({ $0 == .week(model: "all models") || $0 == .week(model: nil) }, week))
        }
    }

    var demo = false   // made-up data for images: don't replace it with the real logs

    func loadBreakdown() {
        guard !readingLogs, !demo else { return }
        readingLogs = true
        let windows = usageWindows()
        DispatchQueue.global(qos: .utility).async {
            // The log scan runs in a short-lived child process, so the memory it needs goes away when it exits.
            let p = Process()
            p.executableURL = Bundle.main.executableURL
            p.arguments = ["--usage-scan"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil { p.waitUntilExit() }
            let b = autoreleasepool { Breakdown(UsageLedger(), windows: windows) }
            DispatchQueue.main.async { self.breakdown = b; self.readingLogs = false }
        }
    }

    private var fetched: (limits: [Limit], at: Date)?
    private var plan: String?
    private var history: [String: [(at: Date, percent: Double)]] = [:]   // recent readings per limit and window

    init() { lang = resolveLanguage(language) }

    /// The limit shown in the menu bar for a service, per the "Limit shown" setting.
    func barLimit(_ s: Service?) -> Limit? {
        s?.limits.filter {
            switch (barMode, $0.kind) {
            case ("session", .session), ("week", .week), ("peak", _): return true
            default: return false
            }
        }.max { $0.effective < $1.effective }
    }
    func barValue(_ s: Service?) -> Double? { barLimit(s)?.effective }

    func reloadLocal() {
        codex = readCodex().map(withRates)
        claude = fetched.map { f in
            withRates(Service(name: "Claude Code", plan: plan, limits: f.limits.map { var l = $0; l.measuredAt = f.at; return l }, updated: f.at))
        }
        if notify { notifyThresholds() }
    }

    private func key(_ s: Service, _ l: Limit) -> String {
        "\(s.name)|\(l.kind)|\(Int(l.resetsAt?.timeIntervalSince1970 ?? 0))"
    }

    /// Records each reading and, for sessions, attaches the burn rate over the last 30 minutes.
    private func withRates(_ s: Service) -> Service {
        var out = s
        out.limits = s.limits.map { l in
            var l = l
            let k = key(s, l)
            var h = history[k] ?? []
            if h.last?.at != l.measuredAt { h.append((l.measuredAt, l.percent)) }
            h.removeAll { $0.at < Date().addingTimeInterval(-7 * hour) }
            history[k] = h
            let recent = h.filter { $0.at >= l.measuredAt.addingTimeInterval(-30 * 60) }
            if l.isSession, let first = recent.first, let last = recent.last, last.at.timeIntervalSince(first.at) >= 20 * 60 {
                l.recentRate = max(0, last.percent - first.percent) / last.at.timeIntervalSince(first.at)
            }
            return l
        }
        return out
    }

    // MARK: Notifications — once per limit, window and threshold

    private func notifyThresholds() {
        var sent = Self.defaults.dictionary(forKey: "notified") as? [String: Int] ?? [:]
        for s in [claude, codex].compactMap({ $0 }) where -(s.updated ?? .distantPast).timeIntervalSinceNow < hour {
            for l in s.limits {
                let k = key(s, l), p = Int(l.effective)
                if p >= 90, sent[k + "|reset"] == nil, let r = l.resetsAt, r.timeIntervalSinceNow > 60 {
                    // Scheduled with the system, so it arrives at the reset even if Burny isn't running then.
                    sent[k + "|reset"] = 1
                    let c = UNMutableNotificationContent()
                    c.title = s.name
                    c.body = String(format: tr("%@: limit reset, you're good to go."), l.label)
                    c.sound = .default
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: r.timeIntervalSinceNow, repeats: false)
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: k + "|reset", content: c, trigger: trigger))
                }
                guard let level = [90, 80].first(where: { p >= $0 }), level > (sent[k] ?? 0) else { continue }
                sent[k] = level
                let c = UNMutableNotificationContent()
                c.title = String(format: tr("%@ at %d%%"), s.name, p)
                var body = String(format: tr("%@ · resets %@"), l.label, shortWhen(l.resetsAt))
                if let f = l.runsOutText { body += " " + f + "." }
                if let hint = s.switchHint, hint.limit.kind == l.kind { body += " " + hint.text }
                c.body = body
                c.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: k, content: c, trigger: nil))
            }
        }
        if sent.count > 60 { sent = [:] }   // old windows; a cleared entry can only re-alert for a live window
        Self.defaults.set(sent, forKey: "notified")
    }

    // MARK: Update check — opt-in, GitHub's public API only, at most once a day

    func checkForUpdates(force: Bool = false) {
        guard checkUpdates else { update = nil; return }
        let last = Self.defaults.double(forKey: "lastUpdateCheck")
        guard force || Date().timeIntervalSince1970 - last > 24 * hour else { return }
        Self.defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")!, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Burny/\(appVersion)", forHTTPHeaderField: "User-Agent")
        URLSession(configuration: .ephemeral).dataTask(with: req) { data, _, _ in   // ephemeral: no cookies, no cache
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String, let page = (obj["html_url"] as? String).flatMap(URL.init(string:)),
                  page.host == "github.com" else { return }
            let v = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            DispatchQueue.main.async {
                self.update = isNewer(v, than: appVersion) ? (v, page) : nil
                self.upToDate = self.update == nil
            }
        }.resume()
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

func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
        return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
    }
    return false
}

/// "18:40", "tomorrow 00:40" or "Sat 3 · 14:00".
func shortWhen(_ d: Date?) -> String {
    guard let d else { return "" }
    let cal = Calendar.current, f = DateFormatter()
    f.locale = Locale(identifier: lang == "it" ? "it_IT" : "en_US")
    f.dateFormat = cal.isDateInToday(d) || cal.isDateInTomorrow(d) ? "HH:mm" : "EEE d · HH:mm"
    return (cal.isDateInTomorrow(d) ? tr("tomorrow") + " " : "") + f.string(from: d)
}

/// "45m", "3h12" or "2d4h", for the menu bar.
func compactUntil(_ d: Date?) -> String? {
    guard let d, d > Date() else { return nil }
    let m = Int(d.timeIntervalSinceNow / 60)
    return m < 60 ? "\(m)m" : m < 1440 ? String(format: "%dh%02d", m / 60, m % 60) : "\(m / 1440)\(tr("d"))\(m % 1440 / 60)h"
}

func resetLine(_ d: Date?) -> String {
    guard let d else { return " " }
    if d < Date() { return tr("Reset") }
    let when = shortWhen(d)
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
            if let f = limit.runsOutText {
                Label(f, systemImage: "flame.fill")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.orange)
            } else if let b = limit.dailyBudget {
                Label(String(format: tr("~%d%% a day lasts until the reset"), Int(b.rounded(.down))), systemImage: "calendar")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
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
    /// Claude is fetched every few minutes; Codex only updates when you use it.
    var stale: Bool {
        guard let u = service?.updated else { return false }
        return -u.timeIntervalSinceNow > (name == "Codex" ? 6 * hour : 30 * 60)
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
                Text(ago(service?.updated)).font(.system(size: 10.5))
                    .foregroundStyle(stale ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
            }
            if let s = service, !s.limits.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(s.limits) { LimitRow(limit: $0, accent: accent) }
                }
                .opacity(stale ? 0.45 : 1)
                if let hint = s.switchHint, !stale {
                    Label(hint.text, systemImage: "arrow.triangle.swap")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if stale && name == "Codex" {
                    Text(tr("Updates when you use Codex.")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            } else {
                Text(tr(emptyMessage)).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055)))
    }
}

enum Page { case limits, breakdown, settings }

struct UsageView: View {
    @ObservedObject var store: Store
    @State var page = Page.limits
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if page != .limits {
                    Button { page = .limits } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                }
                Text(tr(page == .settings ? "Settings" : page == .breakdown ? "Where it went" : "Usage limits")).font(.system(size: 14, weight: .bold))
                Spacer()
                if page == .limits {
                    if store.fetching { ProgressView().controlSize(.small).scaleEffect(0.8) }
                    Button { store.fetch() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help(tr("Refresh now"))
                    Button { page = .breakdown } label: { Image(systemName: "chart.pie") }
                        .buttonStyle(.borderless).help(tr("Where it went"))
                    Button { page = .settings } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help(tr("Settings"))
                } else if page == .breakdown && store.readingLogs {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                }
            }
            if let u = store.update, page == .limits {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.orange)
                    Text(String(format: tr("Burny %@ is available"), u.version)).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button(tr("View")) { NSWorkspace.shared.open(u.url) }.controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
            }
            if page == .settings {
                SettingsView(store: store)
            } else if page == .breakdown {
                BreakdownView(store: store)
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

func dollars(_ v: Double) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "en_US")
    f.numberStyle = .decimal
    f.minimumFractionDigits = v < 100 ? 2 : 0
    f.maximumFractionDigits = v < 100 ? 2 : 0
    return f.string(from: NSNumber(value: v)) ?? String(format: "%.0f", v)
}

func tokenCount(_ t: Double) -> String {
    t >= 1e9 ? String(format: "%.1fB", t / 1e9) : t >= 1e6 ? String(format: "%.1fM", t / 1e6) : t >= 1e3 ? String(format: "%.0fK", t / 1e3) : String(Int(t))
}

struct BreakdownView: View {
    @ObservedObject var store: Store
    @State var tab = "week"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                Text(tr("Session")).tag("session")
                Text(tr("Week")).tag("week")
            }
            .pickerStyle(.segmented).labelsHidden()
            if let b = store.breakdown {
                ForEach(tab == "week" ? b.byWeek : b.bySession) { part in
                    PartCard(part: part, accent: part.service == "Codex" ? codexAccent : claudeAccent, isWeek: tab == "week")
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("Reading local logs…")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            }
            Text(tr("Estimated from Claude Code's and Codex's local logs, weighted by API price. The official % comes from the CLIs. Nothing leaves your Mac."))
                .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { store.loadBreakdown() }
    }
}

struct PartCard: View {
    let part: UsagePart
    let accent: Color
    let isWeek: Bool

    func label(_ name: String) -> String { name == tempProject ? tr("Temporary folders") : name == "?" ? tr("Unknown") : name }

    /// The top projects, the rest folded into "Other"; each with its share of the cost.
    var rows: [(name: String, share: Double)] {
        guard part.cost > 0 else { return [] }
        var r = part.projects.prefix(5).map { (label($0.name), $0.cost / part.cost) }
        let rest = part.projects.dropFirst(5).reduce(0) { $0 + $1.cost }
        if rest > 0 { r.append((tr("Other"), rest / part.cost)) }
        return r
    }

    /// With the official % known, a project's share is shown as points of that limit (they add up to the official %).
    func value(_ share: Double) -> String {
        let v = share * (part.percent ?? 100)
        return v < 1 ? "<1%" : (part.percent == nil ? "" : "≈ ") + "\(Int(v.rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(accent).frame(width: 8, height: 8)
                Text(part.service).font(.system(size: 13, weight: .semibold))
                Spacer()
                if part.service == "Claude Code" && part.cost > 0 {
                    Text(String(format: tr("≈ $%@ at API prices"), dollars(part.cost)))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .help(tr("What the same usage would cost on the API, at list prices."))
                }
            }
            if part.cost <= 0 {
                Text(tr("No usage in this window.")).font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                Group {
                    if let p = part.percent {
                        Text(String(format: tr("%d%% used · %@ tokens"), Int(p.rounded()), tokenCount(part.tokens)))
                    } else {
                        Text(String(format: tr("%@ tokens"), tokenCount(part.tokens)))
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                if isWeek, let prev = part.previous {
                    let delta = (part.cost / prev - 1) * 100
                    Label(String(format: tr("%@ vs last week at this point"), (delta >= 0 ? "+" : "") + "\(Int(delta.rounded()))%"),
                          systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(delta > 15 ? Color.orange : Color.secondary)
                }
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(rows, id: \.name) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(row.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(value(row.share)).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                            }
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.08))
                                    Capsule().fill(accent.opacity(0.8)).frame(width: max(3, g.size.width * row.share))
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                }
                Text(part.models.map { "\($0.name) \(Int(($0.cost / part.cost * 100).rounded()))%" }.joined(separator: " · "))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if isWeek && part.daily.contains(where: { $0 > 0 }) {
                    let top = part.daily.max() ?? 1
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(Array(part.daily.enumerated()), id: \.offset) { i, v in
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(i >= 14 - part.windowDays ? accent.opacity(i == 13 ? 1 : 0.7) : Color.primary.opacity(0.18))
                                    .frame(height: max(2, 30 * v / top))
                            }
                        }
                        .frame(height: 30, alignment: .bottom)
                        HStack {
                            Text(tr("Last 14 days"))
                            Spacer()
                            Text(tr("today"))
                        }
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055)))
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
                SettingRow(label: "Show") {
                    Picker("", selection: $store.barText) {
                        Text(tr("% used")).tag("used")
                        Text(tr("% left")).tag("left")
                        Text(tr("Time to reset")).tag("reset")
                        Text(tr("Icon only")).tag("icon")
                    }
                    .labelsHidden().fixedSize()
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
            SettingsSection(title: "Notifications") {
                SettingRow(label: "Alert at 80% and 90%", note: "Once per limit and window. Also tells you when a limit past 90% resets.") {
                    Toggle("", isOn: $store.notify).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
            }
            SettingsSection(title: "Updates") {
                SettingRow(label: "Check for updates", note: "Once a day asks GitHub for the latest release. Nothing else is sent, nothing is installed.") {
                    Toggle("", isOn: $store.checkUpdates).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                if store.checkUpdates {
                    HStack {
                        if let u = store.update {
                            Text(String(format: tr("Burny %@ is available"), u.version)).foregroundStyle(.orange)
                        } else if store.upToDate {
                            Text(tr("You're up to date."))
                        }
                        Spacer()
                        Button(tr("Check now")) { store.checkForUpdates(force: true) }.controlSize(.small)
                    }
                    .font(.system(size: 11))
                }
            }
            Text("Burny \(appVersion)").font(.system(size: 10.5)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
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
            Timer.scheduledTimer(withTimeInterval: hour, repeats: true) { [weak self] _ in self?.store.checkForUpdates() },   // no-op unless opted in, max once a day
        ]
        store.checkForUpdates()
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
            let l = store.barLimit(s), p = l?.effective   // colour always follows % used
            let att = NSTextAttachment()
            att.image = store.barText == "icon" ? ring(p, accent) : icons[i] ?? ring(p, accent)   // icon only: the ring shows the level
            att.bounds = store.barText == "icon" ? CGRect(x: 0, y: -2, width: 14, height: 14) : CGRect(x: 0, y: -4, width: 17, height: 17)
            title.append(NSAttributedString(attachment: att))
            guard store.barText != "icon" else { continue }
            let color: NSColor = p.map { $0 >= 90 ? .systemRed : $0 >= 75 ? .systemOrange : .labelColor } ?? .secondaryLabelColor
            let text: String? = switch store.barText {
            case "reset": compactUntil(l?.resetsAt)
            case "left": p.map { "\(Int(max(0, 100 - $0).rounded()))%" }
            default: p.map { "\(Int($0.rounded()))%" }
            }
            title.append(NSAttributedString(string: " " + (text ?? "–"), attributes: [.font: font, .foregroundColor: color]))
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
// Dev helpers:  --self-test                                checks the parsers (run by CI)
//               --icon out.png [px]                        renders the app icon
//               --snapshot out.png [dark] [settings|breakdown] [en|it] [demo]  renders the popover (live or made-up data)
//               --usage-log [days]                         prints the per-project split of the local logs

let args = CommandLine.arguments
func png(_ rep: NSBitmapImageRep, _ path: String) {
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

// `Burny --self-test` checks the parsers against real outputs; the CI build runs it so a format change is caught early.
if args.contains("--self-test") {
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { failures += 1 } }

    let usage = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 5% used · resets Sep 28 at 12:40am (Europe/Rome)
    Current week (all models): 28% used · resets Oct 3 at 2pm (Europe/Rome)
    Current week (Fable): 6% used · resets Oct 3 at 2pm (Europe/Rome)

    What's contributing to your limits usage?
    """
    let l = parseUsage(usage)
    check(l.count == 3, "/usage: three limits")
    check(l.map(\.percent) == [5, 28, 6], "/usage: percentages")
    check(l.map(\.kind) == [.session(hours: 5), .week(model: "all models"), .week(model: "Fable")], "/usage: kinds")
    var rome = Calendar(identifier: .gregorian)
    rome.timeZone = TimeZone(identifier: "Europe/Rome")!
    let reset = l.count == 3 ? l[1].resetsAt.map { rome.dateComponents([.month, .day, .hour, .minute], from: $0) } : nil
    check(reset?.month == 10 && reset?.day == 3 && reset?.hour == 14 && reset?.minute == 0, "/usage: reset time and timezone")
    let bare = parseUsage("Current session: 0% used\nCurrent week (all models): 12.5% used · resets 9:05pm (UTC)")
    check(bare.count == 2 && bare[0].resetsAt == nil && bare[1].percent == 12.5 && bare[1].resetsAt != nil, "/usage: no reset, decimals, time only")

    // Codex log: the rate_limits line sits before a >256 KB line, so the backwards reader must cross chunks.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("burny-selftest-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let log = dir.appendingPathComponent("rollout.jsonl")
    let rl = #"{"timestamp":"2026-09-22T22:16:05.696Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":97.0,"window_minutes":300,"resets_at":1790131440},"secondary":{"used_percent":31.0,"window_minutes":10080,"resets_at":1790679309},"plan_type":"plus"}}}"#
    let noise = #"{"type":"response_item","payload":{"text":"\#(String(repeating: "x", count: 300_000))"}}"#
    try? ([#"{"type":"session_meta"}"#, rl, noise].joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
    let line = lastRateLimitLine(log)
    let prim = ((line?["payload"] as? [String: Any])?["rate_limits"] as? [String: Any])?["primary"] as? [String: Any]
    check((prim?["used_percent"] as? NSNumber)?.doubleValue == 97, "codex: rate_limits found across chunks")
    try? FileManager.default.removeItem(at: dir)

    var f = Limit(kind: .session(hours: 5), percent: 50, resetsAt: Date().addingTimeInterval(2 * hour), window: 5 * hour)
    f.recentRate = 60.0 / hour   // 60 % per hour → out in 50 minutes, well before the reset
    check(f.runsOutAt.map { abs($0.timeIntervalSinceNow - 50 * 60) < 5 } == true, "forecast: session runs out within the hour")
    f.recentRate = 20.0 / hour   // out in 2.5 h: too far ahead for a session forecast
    check(f.runsOutAt == nil, "forecast: session looks one hour ahead only")
    f.recentRate = 1.0 / hour
    check(f.runsOutAt == nil, "forecast: lasts until reset")
    let wk2 = Limit(kind: .week(model: nil), percent: 50, resetsAt: Date().addingTimeInterval(5 * 86400), window: week)   // 50% in 2 days
    check(wk2.runsOutAt.map { abs($0.timeIntervalSinceNow - 2 * 86400) < 60 } == true, "forecast: week uses the average since it opened")
    let wk3 = Limit(kind: .week(model: nil), percent: 30, resetsAt: Date().addingTimeInterval(6.6 * 86400), window: week)  // 30% in 10 hours
    check(wk3.runsOutAt == nil, "forecast: no week forecast in its first day")
    let wk = Limit(kind: .week(model: nil), percent: 40, resetsAt: Date().addingTimeInterval(3 * 86400 + 60), window: week)
    check(wk.dailyBudget.map { abs($0 - 20) < 0.1 } == true, "budget: 60% left over 3 days is ~20% a day")
    let fable = Service(name: "Claude Code", plan: nil, limits: [
        Limit(kind: .week(model: "all models"), percent: 50, resetsAt: nil, window: week),
        Limit(kind: .week(model: "Fable"), percent: 93, resetsAt: nil, window: week)], updated: nil)
    check(fable.switchHint?.limit.kind == .week(model: "Fable"), "hint: switch model when one bucket is nearly used up")
    check(compactUntil(Date().addingTimeInterval(3 * hour + 5 * 60 + 30)) == "3h05", "menu bar: compact countdown")
    check(modelName("claude-opus-5-5") == "Opus 5.5" && modelName("claude-haiku-4-5-20251001") == "Haiku 4.5"
          && modelName("gpt-6-astra") == "GPT-6 Astra" && modelName("codex-auto-review") == "Codex Auto Review", "breakdown: model names")
    check(projectName("/Users/x/Projects/app/.claude/worktrees/agent-1") == "app" && projectName("/private/var/folders/a/T/tmp.x") == tempProject,
          "breakdown: project names")
    // A reply logged twice (once per content block) must count once, and a second read must only add new lines.
    let ldir = FileManager.default.temporaryDirectory.appendingPathComponent("burny-ledger-\(getpid())")
    try? FileManager.default.createDirectory(at: ldir.appendingPathComponent("claude/p"), withIntermediateDirectories: true)
    let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
    func reply(_ id: String, _ out: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(ts)","cwd":"/Users/x/demo","message":{"id":"\#(id)","model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":\#(out)}}}"#
    }
    let clog = ldir.appendingPathComponent("claude/p/s.jsonl")
    try? ([reply("a", 0), reply("a", 1_000_000), #"{"type":"user"}"#].joined(separator: "\n") + "\n").write(to: clog, atomically: true, encoding: .utf8)
    let ledger = UsageLedger(claudeRoot: ldir.appendingPathComponent("claude"), codexRoot: ldir.appendingPathComponent("codex"),
                             cacheURL: ldir.appendingPathComponent("usage.json"))
    ledger.update()
    check(abs(ledger.split("Claude Code", from: Date().addingTimeInterval(-hour), to: Date()).cost - 18) < 0.001, "breakdown: duplicate reply counted once ($3 in + $15 out)")
    if let h = try? FileHandle(forWritingTo: clog) { h.seekToEndOfFile(); h.write(Data((reply("b", 0) + "\n").utf8)); try? h.close() }
    let again = UsageLedger(claudeRoot: ldir.appendingPathComponent("claude"), codexRoot: ldir.appendingPathComponent("codex"),
                            cacheURL: ldir.appendingPathComponent("usage.json"))
    again.update()
    let after = again.split("Claude Code", from: Date().addingTimeInterval(-hour), to: Date())
    check(abs(after.cost - 21) < 0.001 && after.projects.first?.0 == "demo", "breakdown: incremental read from the cache")
    try? FileManager.default.removeItem(at: ldir)
    check(isNewer("1.10.0", than: "1.9.2") && !isNewer("1.1.0", than: "1.1.0") && !isNewer("1.0.9", than: "1.1"), "update: version comparison")

    print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

// `Burny --usage-scan` updates the usage cache from the logs and exits; the app runs it as a child process.
if args.contains("--usage-scan") {
    UsageLedger().update()
    exit(0)
}

// `Burny --usage-log [days]` prints the per-project split of the local logs, for checking the numbers by hand.
if let i = args.firstIndex(of: "--usage-log") {
    let days = i + 1 < args.count ? Double(args[i + 1]) ?? 7 : 7
    let start = Date()
    let ledger = UsageLedger()
    ledger.update()
    print(String(format: "read in %.1f s", -start.timeIntervalSinceNow))
    for service in ["Claude Code", "Codex"] {
        let s = ledger.split(service, from: Date().addingTimeInterval(-days * 86400), to: Date())
        print(String(format: "%@: %.2f (API $ for Claude), %.0f tokens", service, s.cost, s.tokens))
        for (name, c) in s.projects.prefix(8) { print(String(format: "  %5.1f%%  %@", c / max(s.cost, 1e-9) * 100, name)) }
        for (name, c) in s.models { print(String(format: "  %5.1f%%  [%@]", c / max(s.cost, 1e-9) * 100, name)) }
    }
    exit(0)
}

if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
    if let rep = drawAppIcon(px: i + 2 < args.count ? Int(args[i + 2]) ?? 1024 : 1024) { png(rep, args[i + 1]) }
    exit(0)
}

/// Made-up, realistic data for the README images and launch material, so real project names never leak into them.
func loadDemo(_ store: Store) {
    store.demo = true
    let now = Date()
    func at(_ h: Double) -> Date { now.addingTimeInterval(h * hour) }
    var session = Limit(kind: .session(hours: 5), percent: 42, resetsAt: at(2.3), window: 5 * hour)
    session.recentRate = 70 / hour   // shows the session forecast
    store.claude = Service(name: "Claude Code", plan: "Max 5x", limits: [
        session,
        Limit(kind: .week(model: "all models"), percent: 58, resetsAt: at(76), window: week),
        Limit(kind: .week(model: "Fable"), percent: 92, resetsAt: at(76), window: week),
    ], updated: now)
    store.codex = Service(name: "Codex", plan: "Plus", limits: [
        Limit(kind: .session(hours: 5), percent: 18, resetsAt: at(3.7), window: 5 * hour),
        Limit(kind: .week(model: nil), percent: 31, resetsAt: at(122), window: week),
    ], updated: now.addingTimeInterval(-12 * 60))
    func part(_ service: String, _ percent: Double, _ cost: Double, _ tokens: Double, _ projects: [(String, Double)],
              _ models: [(String, Double)], previous: Double? = nil, daily: [Double] = []) -> UsagePart {
        var p = UsagePart(service: service, percent: percent, cost: cost, tokens: tokens,
                          projects: projects.map { ($0.0, $0.1 * cost) }, models: models.map { ($0.0, $0.1 * cost) },
                          previous: previous, daily: daily)
        p.windowDays = 4
        return p
    }
    store.breakdown = Breakdown(
        bySession: [
            part("Claude Code", 42, 96.4, 2.1e8, [("acme-web", 0.58), ("api-server", 0.31), ("docs-site", 0.11)], [("Opus 5.5", 0.7), ("Fable 5.1", 0.3)]),
            part("Codex", 18, 0.9, 6.2e6, [("mobile-app", 1)], [("GPT-6 Astra", 1)]),
        ],
        byWeek: [
            part("Claude Code", 58, 1284.5, 2.9e9,
                 [("acme-web", 0.40), ("api-server", 0.24), ("mobile-app", 0.15), ("docs-site", 0.08), ("infra", 0.05), ("playground", 0.03), ("scratch", 0.05)],
                 [("Opus 5.5", 0.64), ("Fable 5.1", 0.26), ("Sonnet 5", 0.10)], previous: 1052,
                 daily: [120, 180, 60, 0, 0, 210, 240, 150, 90, 0, 310, 420, 360, 195]),
            part("Codex", 31, 3.1, 1.8e7, [("mobile-app", 0.62), ("api-server", 0.38)], [("GPT-6 Astra", 0.8), ("GPT-6 Luna", 0.2)],
                 previous: 2.6, daily: [0, 0.2, 0.4, 0, 0, 0.3, 0.1, 0, 0.5, 0.2, 0.9, 0.6, 0.7, 0.2]),
        ])
}

if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    MainActor.assumeIsolated {
        let store = Store()
        if args.contains("en") { lang = "en" } else if args.contains("it") { lang = "it" }
        if args.contains("demo") {
            loadDemo(store)
        } else {
            store.reloadLocal()
            if let l = fetchClaudeUsage() { store.claude = Service(name: "Claude Code", plan: claudePlan(), limits: l, updated: Date()) }
        }
        // Menu bar values, for the README composer: "<claude> <codex>"
        print([store.claude, store.codex].map { store.barValue($0).map { "\(Int($0.rounded()))%" } ?? "–" }.joined(separator: " "))
        if args.contains("breakdown") && !args.contains("demo") {
            let ledger = UsageLedger()
            ledger.update()
            store.breakdown = Breakdown(ledger, windows: store.usageWindows())
        }
        let page: Page = args.contains("settings") ? .settings : args.contains("breakdown") ? .breakdown : .limits
        let host = NSHostingView(rootView: UsageView(store: store, page: page))
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
