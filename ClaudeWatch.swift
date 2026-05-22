import Cocoa

// MARK: - Config
let USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
let SETTINGS_URL = "https://claude.ai/settings/usage"
let KEYCHAIN_SERVICE = "Claude Code-credentials"
let REFRESH_INTERVAL: TimeInterval = 300  // 5 minutes
// extra_usage dollar amounts come back in cents; divide to get dollars.
let CENTS_PER_DOLLAR = 100.0

// MARK: - Models
struct UsageWindow: Decodable {
    let utilization: Double
    let resets_at: String?
}
struct ExtraUsage: Decodable {
    let is_enabled: Bool
    let monthly_limit: Double?
    let used_credits: Double?
    let utilization: Double?
    let currency: String?
}
struct Usage: Decodable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let seven_day_opus: UsageWindow?
    let seven_day_sonnet: UsageWindow?
    let extra_usage: ExtraUsage?
}

enum FetchResult {
    case ok(Usage)
    case authError
    case error(String)
}

// MARK: - Keychain
/// Reads the Claude Code OAuth access token from the login keychain by
/// shelling out to `security` (the access path we verified works).
func readAccessToken() -> String? {
    let p = Process()
    p.launchPath = "/usr/bin/security"
    p.arguments = ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let raw = String(data: data, encoding: .utf8) else { return nil }
    let blob = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let d = blob.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    let oauth = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
    return oauth["accessToken"] as? String
}

// MARK: - Fetch
func fetchUsage(_ completion: @escaping (FetchResult) -> Void) {
    guard let token = readAccessToken() else {
        completion(.error("No token in keychain")); return
    }
    var req = URLRequest(url: URL(string: USAGE_URL)!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.setValue("ClaudeWatch/0.1", forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 20
    req.cachePolicy = .reloadIgnoringLocalCacheData
    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err = err { completion(.error(err.localizedDescription)); return }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { completion(.authError); return }
        guard code == 200, let data = data else { completion(.error("HTTP \(code)")); return }
        do { completion(.ok(try JSONDecoder().decode(Usage.self, from: data))) }
        catch { completion(.error("parse error")) }
    }.resume()
}

// MARK: - Formatting helpers
func bar(_ pct: Double, width: Int = 10) -> String {
    let filled = max(0, min(width, Int((pct / 100.0 * Double(width)).rounded())))
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}

let isoParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let isoParserNoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func formatReset(_ iso: String?) -> String {
    guard let iso = iso else { return "" }
    guard let date = isoParser.date(from: iso) ?? isoParserNoFrac.date(from: iso) else { return "" }
    let cal = Calendar.current
    let out = DateFormatter()
    if cal.isDateInToday(date) {
        out.dateFormat = "h:mm a"; return "today \(out.string(from: date))"
    } else if cal.isDateInTomorrow(date) {
        out.dateFormat = "h:mm a"; return "tomorrow \(out.string(from: date))"
    } else {
        out.dateFormat = "EEE h:mm a"; return out.string(from: date)
    }
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

/// Compact time remaining until an ISO8601 instant, e.g. "2h33m" or "44m".
func countdown(_ iso: String?) -> String {
    guard let iso = iso,
          let date = isoParser.date(from: iso) ?? isoParserNoFrac.date(from: iso) else { return "" }
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return "now" }
    let h = secs / 3600, m = (secs % 3600) / 60
    return h > 0 ? "\(h)h\(m)m" : "\(m)m"
}

/// Two vertical "flood bars" (session, weekly) that fill from the bottom in red.
func makeBarsImage(_ a: Double, _ b: Double) -> NSImage {
    let w: CGFloat = 20, h: CGFloat = 14
    let barW: CGFloat = 6.5, gap: CGFloat = 3, radius: CGFloat = 1.25
    let total = barW * 2 + gap
    let startX = (w - total) / 2
    let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
        let xs = [startX, startX + barW + gap]
        let vals = [a, b]
        for (i, x) in xs.enumerated() {
            let track = NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: barW, height: h),
                                     xRadius: radius, yRadius: radius)
            NSColor.gray.withAlphaComponent(0.35).setFill()
            track.fill()
            let pct = max(0, min(100, vals[i])) / 100.0
            let fillH = h * CGFloat(pct)
            if fillH > 0.5 {
                let fill = NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: barW, height: fillH),
                                        xRadius: radius, yRadius: radius)
                NSColor.systemRed.setFill()
                fill.fill()
            }
            // Thin white outline so the bar's extent is visible.
            let outline = NSBezierPath(roundedRect: NSRect(x: x + 0.4, y: 0.4, width: barW - 0.8, height: h - 0.8),
                                       xRadius: radius, yRadius: radius)
            outline.lineWidth = 0.8
            NSColor.white.setStroke()
            outline.stroke()
        }
        return true
    }
    img.isTemplate = false   // keep the red fill (template images ignore color)
    return img
}

// MARK: - App
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?
    var minuteTimer: Timer?
    var lastUpdated: Date?
    var fiveReset: String?   // ISO8601 of next 5h reset, for the countdown

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem.button?.title = "C …"
        menu.delegate = self
        menu.autoenablesItems = false   // keep info rows full-color, not dimmed
        statusItem.menu = menu
        rebuildMenu(rows: ["Loading…"], footer: "Fetching…")
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: REFRESH_INTERVAL, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Tick the countdown text every minute without re-fetching.
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateCountdownText()
        }
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    func refresh() {
        fetchUsage { [weak self] result in
            DispatchQueue.main.async { self?.apply(result) }
        }
    }

    func apply(_ result: FetchResult) {
        switch result {
        case .authError:
            setTitle("⚠ auth", warn: true)
            rebuildMenu(rows: ["Token expired or rejected.",
                               "Open Claude Code to refresh your login."], footer: nil)
        case .error(let msg):
            setTitle("⚠", warn: true)
            rebuildMenu(rows: ["Couldn't fetch usage:", msg], footer: nil)
        case .ok(let u):
            lastUpdated = Date()
            renderUsage(u)
        }
    }

    func renderUsage(_ u: Usage) {
        var rows: [String] = []
        func add(_ label: String, _ w: UsageWindow?) {
            guard let w = w else { return }
            var line = "\(pad(label, 14))\(pad(String(format: "%.0f%%", w.utilization), 5)) \(bar(w.utilization))"
            let reset = formatReset(w.resets_at)
            if !reset.isEmpty { line += "  ↻ \(reset)" }
            rows.append(line)
        }
        add("Session 5h", u.five_hour)
        add("Weekly 7d", u.seven_day)
        add("Weekly Opus", u.seven_day_opus)
        add("Weekly Sonnet", u.seven_day_sonnet)

        if let e = u.extra_usage, e.is_enabled,
           let usedC = e.used_credits, let limitC = e.monthly_limit {
            let used = usedC / CENTS_PER_DOLLAR
            let limit = limitC / CENTS_PER_DOLLAR
            let util = e.utilization ?? (limitC > 0 ? usedC / limitC * 100 : 0)
            let money = String(format: "$%.2f/$%.2f", used, limit)
            rows.append("\(pad("Extra spend", 14))\(pad(String(format: "%.0f%%", util), 5)) \(bar(util))  \(money)")
        }
        if rows.isEmpty { rows = ["No active usage windows"] }

        // Menu-bar icon = two vertical flood bars (session 5h, weekly 7d) + 5h countdown.
        fiveReset = u.five_hour?.resets_at
        setBars(five: u.five_hour?.utilization ?? 0, weekly: u.seven_day?.utilization ?? 0)

        let footer = lastUpdated.map { d -> String in
            let f = DateFormatter(); f.dateFormat = "h:mm a"
            return "Updated \(f.string(from: d))"
        }
        rebuildMenu(rows: rows, footer: footer)
    }

    func setBars(five: Double, weekly: Double) {
        guard let button = statusItem.button else { return }
        button.image = makeBarsImage(five, weekly)
        let reset = countdown(fiveReset)
        button.imagePosition = reset.isEmpty ? .imageOnly : .imageLeading
        button.attributedTitle = NSAttributedString(
            string: reset.isEmpty ? "" : " \(reset)",
            attributes: [.font: NSFont.menuBarFont(ofSize: 0)])
        button.toolTip = "Session 5h: \(Int(five))%"
            + (reset.isEmpty ? "" : " (resets in \(reset))")
            + "   Weekly 7d: \(Int(weekly))%"
    }

    /// Refresh just the countdown text from the stored reset time (no network).
    func updateCountdownText() {
        guard let button = statusItem.button, button.image != nil else { return }
        let reset = countdown(fiveReset)
        button.imagePosition = reset.isEmpty ? .imageOnly : .imageLeading
        button.attributedTitle = NSAttributedString(
            string: reset.isEmpty ? "" : " \(reset)",
            attributes: [.font: NSFont.menuBarFont(ofSize: 0)])
    }

    func setTitle(_ s: String, warn: Bool) {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.imagePosition = .noImage
        button.toolTip = nil
        if warn {
            button.attributedTitle = NSAttributedString(
                string: s,
                attributes: [.foregroundColor: NSColor.systemRed,
                             .font: NSFont.menuBarFont(ofSize: 0)])
        } else {
            button.attributedTitle = NSAttributedString(string: s)
        }
    }

    func rebuildMenu(rows: [String], footer: String?) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "Claude Usage", action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(string: "Claude Usage", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor])
        menu.addItem(header)
        menu.addItem(.separator())

        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for text in rows {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: monoFont,
                .foregroundColor: NSColor.labelColor])
            menu.addItem(item)
        }

        menu.addItem(.separator())
        if let footer = footer {
            let f = NSMenuItem(title: footer, action: nil, keyEquivalent: "")
            f.attributedTitle = NSAttributedString(string: footer, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor])
            menu.addItem(f)
        }
        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openItem = NSMenuItem(title: "Open usage page…", action: #selector(openSettings), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ClaudeWatch", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc func refreshClicked() { refresh() }
    @objc func openSettings() { NSWorkspace.shared.open(URL(string: SETTINGS_URL)!) }
    @objc func quitClicked() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
