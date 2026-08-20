import Cocoa
import Network

// MARK: - Config
let APP_VERSION = "0.10"
let USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
let SETTINGS_URL = "https://claude.ai/settings/usage"
let KEYCHAIN_SERVICE = "Claude Code-credentials"
// Some Claude Code installs store credentials in this file instead of the keychain.
let CREDENTIALS_FILE = "~/.claude/.credentials.json"
// The usage endpoint shares a small (~5-request) rate-limit bucket with Claude
// Code and everything else using the same OAuth token, so poll gently in the
// background — opening the menu triggers an on-demand refresh when it matters.
let REFRESH_INTERVAL: TimeInterval = 900  // 15 minutes
// After a 429, wait at least this long before the next automatic poll, doubling
// per consecutive throttle up to the cap, so the widget stops fighting the limit.
let BACKOFF_MIN: TimeInterval = 15 * 60
let BACKOFF_MAX: TimeInterval = 60 * 60
// Shown data older than this (because fetches keep failing) is flagged stale.
let STALE_AFTER: TimeInterval = 20 * 60
// When the OAuth token is within this many minutes of expiring, the popup warns
// and offers the login button proactively — before fetches start failing.
let EXPIRY_WARN_MINUTES = 60.0
// Last-good usage is cached here so a restart (e.g. during a 429 backoff) can show
// the previous figures, flagged stale, instead of a bare error until the first
// successful fetch lands.
let CACHE_FILE = "~/Library/Caches/com.traviswheeler.claudewatch/last-usage.json"
// extra_usage dollar amounts come back in cents; divide to get dollars.
let CENTS_PER_DOLLAR = 100.0
// Bar fill is yellow normally, switching to red once a window passes this %.
let WARN_THRESHOLD = 60.0
let NORMAL_COLOR = NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.0, alpha: 1.0)  // yellow
let WARN_COLOR = NSColor.systemRed

// MARK: - Models
struct UsageWindow: Codable {
    let utilization: Double
    let resets_at: String?
}
struct ExtraUsage: Codable {
    let is_enabled: Bool
    let monthly_limit: Double?
    let used_credits: Double?
    let utilization: Double?
    let currency: String?
}
struct Usage: Codable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let seven_day_opus: UsageWindow?
    let seven_day_sonnet: UsageWindow?
    let extra_usage: ExtraUsage?
}

enum FetchResult {
    case ok(Usage)
    case authError            // 401/403 — credentials problem
    case transient(String)    // 429 / 5xx / network — keep showing last good data
    case error(String)
}

// MARK: - Credentials
// Claude Code stores its OAuth credentials in one of two places depending on
// platform/version/config: the macOS login keychain, or ~/.claude/.credentials.json.
// We read both and use whichever token is fresher, so ClaudeWatch works either way.
struct Credentials {
    let accessToken: String
    let expiresAt: Date?   // when the access token stops working
}

/// Parse a Claude Code credentials JSON blob. The shape is the same in the
/// keychain and the file: an optional `claudeAiOauth` wrapper around
/// `accessToken` + `expiresAt` (a Unix-millis timestamp).
func parseCredentials(_ data: Data) -> Credentials? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let oauth = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
    guard let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
    let expiry = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
    return Credentials(accessToken: token, expiresAt: expiry)
}

/// Read credentials from the login keychain via `security find-generic-password`.
func credentialsFromKeychain() -> Credentials? {
    let p = Process()
    p.launchPath = "/usr/bin/security"
    p.arguments = ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }   // item not found → nil
    // `security -w` prints the raw secret (our JSON) followed by a newline.
    let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let json = trimmed?.data(using: .utf8) else { return nil }
    return parseCredentials(json)
}

/// Read credentials from ~/.claude/.credentials.json.
func credentialsFromFile() -> Credentials? {
    let path = (CREDENTIALS_FILE as NSString).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return parseCredentials(data)
}

/// The current OAuth credentials. Claude Code may use either storage backend, so
/// read both and prefer whichever token expires later — that way a stale leftover
/// in one location never shadows a freshly written token in the other.
func readCredentials() -> Credentials? {
    let found = [credentialsFromFile(), credentialsFromKeychain()].compactMap { $0 }
    return found.max { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }
}

// MARK: - Last-good cache
// Persist the most recent successful reading so a relaunch has something to show
// (flagged stale) even before its first fetch succeeds — important when that first
// fetch lands on a 429 backoff and there's no in-memory fallback yet.
struct CachedUsage: Codable {
    let usage: Usage
    let updatedAt: Date
    let fiveReset: String?
}

func saveCache(_ u: Usage, updatedAt: Date, fiveReset: String?) {
    let path = (CACHE_FILE as NSString).expandingTildeInPath
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    if let data = try? enc.encode(CachedUsage(usage: u, updatedAt: updatedAt, fiveReset: fiveReset)) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

func loadCache() -> CachedUsage? {
    let path = (CACHE_FILE as NSString).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    return try? dec.decode(CachedUsage.self, from: data)
}

// MARK: - Fetch
func fetchUsage(token: String, _ completion: @escaping (FetchResult) -> Void) {
    var req = URLRequest(url: URL(string: USAGE_URL)!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.setValue("ClaudeWatch/0.1", forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 20
    req.cachePolicy = .reloadIgnoringLocalCacheData
    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err = err {
            logTransient("network: \(err.localizedDescription)")
            completion(.transient("network: \(err.localizedDescription)")); return
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 {
            logTransient("HTTP \(code) auth-rejected (token present but refused)")
            completion(.authError); return
        }
        if code == 429 {
            logTransient("HTTP 429 rate-limited")
            completion(.transient("rate-limited (HTTP 429)")); return
        }
        if (500...599).contains(code) {
            logTransient("HTTP \(code) server error")
            completion(.transient("server (HTTP \(code))")); return
        }
        guard code == 200, let data = data else {
            logTransient("HTTP \(code) unexpected")
            completion(.error("HTTP \(code)")); return
        }
        do { completion(.ok(try JSONDecoder().decode(Usage.self, from: data))) }
        catch { completion(.error("parse error")) }
    }.resume()
}

/// Append a one-line transient-error record to /tmp/claude-watch-fetch.log so we
/// can tell after the fact whether "API busy" was a real 429 or a local network
/// blip. The file is bounded to ~64 KB; older lines are dropped when it grows.
func logTransient(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/claude-watch-fetch.log")
    if let h = try? FileHandle(forWritingTo: url) {
        defer { try? h.close() }
        if (try? h.seekToEnd()) ?? 0 > 65_536 {
            try? h.seek(toOffset: 0)
            try? h.truncate(atOffset: 0)
        }
        h.write(data)
    } else {
        try? data.write(to: url)
    }
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

/// The real local time zone, re-resolved on every call. Launchd-spawned agents
/// don't reliably inherit the system zone (TimeZone.current can come back as
/// GMT), so read it straight from the /etc/localtime symlink. Re-resolving
/// dynamically also picks up DST/zone changes without restarting the agent, and
/// recovers if the symlink read transiently failed at startup.
var localZone: TimeZone {
    if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/etc/localtime"),
       let range = target.range(of: "zoneinfo/") {
        let id = String(target[range.upperBound...])
        if let tz = TimeZone(identifier: id) { return tz }
    }
    return TimeZone.current
}

/// Calendar pinned to the real local zone (for today/tomorrow comparisons).
var localCalendar: Calendar {
    var c = Calendar.current
    c.timeZone = localZone
    return c
}

/// A DateFormatter pinned to the real local zone.
func localFormatter(_ fmt: String) -> DateFormatter {
    let f = DateFormatter()
    f.timeZone = localZone
    f.dateFormat = fmt
    return f
}

func formatReset(_ iso: String?) -> String {
    guard let iso = iso else { return "" }
    guard let date = isoParser.date(from: iso) ?? isoParserNoFrac.date(from: iso) else { return "" }
    if localCalendar.isDateInToday(date) {
        return "today \(localFormatter("h:mm a").string(from: date))"
    } else if localCalendar.isDateInTomorrow(date) {
        return "tomorrow \(localFormatter("h:mm a").string(from: date))"
    } else {
        return localFormatter("EEE h:mm a").string(from: date)
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
    let barW: CGFloat = 7.8, gap: CGFloat = 3, radius: CGFloat = 1.25
    let total = barW * 2 + gap
    let startX = (w - total) / 2
    let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
        let xs = [startX, startX + barW + gap]
        let vals = [a, b]
        for (i, x) in xs.enumerated() {
            let track = NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: barW, height: h),
                                     xRadius: radius, yRadius: radius)
            NSColor.black.withAlphaComponent(0.85).setFill()
            track.fill()
            let pct = max(0, min(100, vals[i])) / 100.0
            let fillH = h * CGFloat(pct)
            if fillH > 0.5 {
                let fill = NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: barW, height: fillH),
                                        xRadius: radius, yRadius: radius)
                (vals[i] >= WARN_THRESHOLD ? WARN_COLOR : NORMAL_COLOR).setFill()
                fill.fill()
            }
        }
        return true
    }
    img.isTemplate = false   // keep the red fill (template images ignore color)
    return img
}

// MARK: - Self-update
// The app is built from a git checkout; install.sh records that checkout's path
// in the bundle's Info.plist (CWSourcePath). We fetch from there with the user's
// existing git/SSH auth — no GitHub token needed for the private repo.

/// Path to the source checkout, recorded in Info.plist by install.sh.
func sourceRepoPath() -> String? {
    Bundle.main.object(forInfoDictionaryKey: "CWSourcePath") as? String
}

/// Run a command, capturing combined stdout/stderr. Returns (status, output).
@discardableResult
func runCommand(_ launchPath: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.launchPath = launchPath
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    do { try p.run() } catch { return (-1, "") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

struct UpdateInfo { let version: String }

/// Fetch from origin; report a pending update if the checkout is behind upstream.
/// The version string is the latest reachable tag, else a commit count. Returns
/// nil if up to date, not a tracked git checkout, or the path is unknown.
func checkForUpdate() -> UpdateInfo? {
    guard let repo = sourceRepoPath() else { return nil }
    let git = "/usr/bin/git"
    guard FileManager.default.fileExists(atPath: git) else { return nil }
    _ = runCommand(git, ["-C", repo, "fetch", "--tags", "--quiet"])  // best-effort; ignore net errors
    let (st, out) = runCommand(git, ["-C", repo, "rev-list", "--count", "HEAD..@{u}"])
    guard st == 0,
          let behind = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)),
          behind > 0 else { return nil }
    let (tst, tout) = runCommand(git, ["-C", repo, "describe", "--tags", "--abbrev=0", "@{u}"])
    let tag = tout.trimmingCharacters(in: .whitespacesAndNewlines)
    let version = (tst == 0 && !tag.isEmpty) ? tag : "\(behind) new commit\(behind == 1 ? "" : "s")"
    return UpdateInfo(version: version)
}

/// Launch update.sh detached (nohup) so it survives this process being
/// relaunched by the LaunchAgent during the rebuild.
func launchUpdate() {
    guard let repo = sourceRepoPath() else { return }
    let p = Process()
    p.launchPath = "/bin/sh"
    p.arguments = ["-c", "nohup '\(repo)/update.sh' > /tmp/claude-watch-update.log 2>&1 &"]
    try? p.run()
}

// MARK: - App
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?
    var minuteTimer: Timer?
    var lastUpdated: Date?
    var fiveReset: String?   // ISO8601 of next 5h reset, for the countdown
    var lastUsage: Usage?    // last successful fetch, shown through transient blips
    var lastFetchAt: Date?   // for debouncing menu-open refreshes
    var tokenExpiry: Date?   // OAuth access-token expiry, for the proactive warning
    var throttleStreak = 0   // consecutive 429s, for exponential backoff
    var backoffUntil: Date?  // no automatic polling before this time (after a 429)
    var updateInfo: UpdateInfo?       // set when a newer version is available
    var updateTimer: Timer?
    var loginWaitTimer: Timer?        // polls for a new token after "Log in to Claude…"
    var lastUpdateCheckAt: Date?      // for debouncing update checks
    let pathMonitor = NWPathMonitor() // watches network reachability (laptops drop Wi-Fi)
    var networkUp = true              // last known network state
    var authRetries = 0              // quick self-heal attempts after an auth failure
    var chasedReset: String?          // 5h resets_at we've already re-fetched after it lapsed
    var appNapActivity: NSObjectProtocol?  // held to keep macOS from App-Napping our timers

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem.button?.title = "C …"
        menu.delegate = self
        menu.autoenablesItems = false   // keep info rows full-color, not dimmed
        statusItem.menu = menu
        rebuildMenu(rows: ["Loading…"], footer: "Fetching…")

        // Keep the 15-minute background poll firing on schedule. As a windowless
        // accessory app we're a prime App Nap candidate, which would throttle the
        // timers and leave the numbers frozen until the menu is next opened. This
        // opts out of napping while still letting the Mac sleep normally.
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Keep the usage poll firing on schedule")

        // Watch network reachability: don't pester the usage API while offline
        // (that's what made a dropped Wi-Fi look like a login failure), and fetch
        // the instant the network comes back instead of waiting for the next poll.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let up = path.status == .satisfied
                let cameBack = up && !self.networkUp
                self.networkUp = up
                if !up { self.showOffline() }
                else if cameBack { self.refresh() }
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))

        // Re-fetch when the Mac wakes (a laptop's usage is stale after sleep).
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        // Show the last-good reading immediately (with its real timestamp) so a
        // relaunch isn't blank, and so a first fetch that lands on a 429 has a
        // fallback to display instead of a bare error.
        if let c = loadCache() {
            lastUsage = c.usage
            lastUpdated = c.updatedAt
            fiveReset = c.fiveReset
            renderUsage(c.usage)
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: REFRESH_INTERVAL, repeats: true) { [weak self] _ in
            self?.refresh(force: false)   // automatic poll: respects backoff after 429s
        }
        // Tick the countdown text every minute without re-fetching.
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateCountdownText()
        }
        // Check for a new version at launch, then every 6 hours.
        runUpdateCheck()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.runUpdateCheck()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh(force: false)
        // Opportunistic update check, at most every 30 min (runs async; no UI lag).
        if lastUpdateCheckAt == nil || Date().timeIntervalSince(lastUpdateCheckAt!) > 1800 {
            runUpdateCheck()
        }
    }

    /// Check for an update off the main thread (git fetch hits the network), then
    /// refresh the menu so the "Update available" item appears/disappears.
    func runUpdateCheck() {
        lastUpdateCheckAt = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = checkForUpdate()
            DispatchQueue.main.async {
                self?.updateInfo = info
                if let u = self?.lastUsage { self?.renderUsage(u) }
            }
        }
    }

    func refresh(force: Bool = true) {
        // Automatic polls (force == false) back off after 429s and debounce;
        // user-initiated ones (Refresh now, post-login) always go through.
        if !force {
            if let until = backoffUntil, Date() < until { return }
            if let last = lastFetchAt, Date().timeIntervalSince(last) < 30 { return }
        }
        // No network: don't hit the API (it would just error and look like a
        // failure). NWPathMonitor will call us back the moment we're reconnected.
        if !networkUp { showOffline(); return }
        lastFetchAt = Date()
        guard let creds = readCredentials() else {
            tokenExpiry = nil
            logTransient("no credentials found (file=\(credentialsFromFile() != nil), keychain=\(credentialsFromKeychain() != nil))")
            apply(.authError)   // no token = not logged in; same login fix
            return
        }
        tokenExpiry = creds.expiresAt
        fetchUsage(token: creds.accessToken) { [weak self] result in
            DispatchQueue.main.async { self?.apply(result) }
        }
    }

    func apply(_ result: FetchResult) {
        switch result {
        case .ok(let u):
            throttleStreak = 0
            backoffUntil = nil
            authRetries = 0
            lastUsage = u
            let now = Date()
            lastUpdated = now
            renderUsage(u)
            saveCache(u, updatedAt: now, fiveReset: u.five_hour?.resets_at)
        case .authError:
            // Keep a gentle self-heal retry going: a 401 often clears once Claude
            // Code rotates the token and readCredentials picks up the fresh one.
            // Each retry spends one of the ~5 shared rate-limit tokens, so cap it at
            // two spaced attempts before settling back onto the normal 15-min poll.
            let retryScheduled = authRetries < 2
            if retryScheduled {
                authRetries += 1
                let delay = authRetries == 1 ? 30.0 : 90.0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
            }
            // Don't slam the alarming "⚠ login" plaque up on a brief blip. If the
            // stored token still looks valid and we have good numbers, keep showing
            // them and let the retry clear it quietly. Only surface the login prompt
            // once the token has actually expired, the retries are spent, or there's
            // nothing to fall back on.
            let tokenExpired = tokenExpiry.map { $0 < Date() } ?? false
            if !tokenExpired, retryScheduled, let u = lastUsage {
                renderUsage(u)
                return
            }
            setTitle("⚠ login", warn: true)
            rebuildMenu(rows: ["Claude login expired or rejected.",
                               "Click below to sign in again."],
                        footer: nil, link: "Open claude.ai/settings/usage ↗",
                        login: true)
        case .transient(let msg):
            // Rate-limited: back off (doubling per consecutive 429, capped) so we
            // stop draining the shared bucket and let it refill.
            if msg.contains("429") {
                throttleStreak += 1
                let wait = min(BACKOFF_MAX, BACKOFF_MIN * pow(2, Double(throttleStreak - 1)))
                backoffUntil = Date().addingTimeInterval(wait)
            }
            // Keep the last good bars if we have them, but flag them as stale.
            if let u = lastUsage {
                renderUsage(u, staleNote: "API busy")
            } else {
                setTitle("⚠", warn: true)
                rebuildMenu(rows: ["Couldn't reach usage API: \(msg).", "Will retry shortly."],
                            footer: nil, link: "Open claude.ai/settings/usage ↗")
            }
        case .error(let msg):
            setTitle("⚠", warn: true)
            rebuildMenu(rows: ["Couldn't fetch usage (\(msg))."],
                        footer: nil, link: "Open claude.ai/settings/usage ↗")
        }
    }

    func renderUsage(_ u: Usage, staleNote: String? = nil, forceNote: Bool = false) {
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

        // Proactively warn while the login still works but is about to expire,
        // so the user can refresh before fetches start failing.
        var loginSoon = false
        if let exp = tokenExpiry {
            let mins = exp.timeIntervalSinceNow / 60
            if mins > 0 && mins < EXPIRY_WARN_MINUTES {
                rows.append("")
                rows.append("⚠ Login expires in \(Int(mins.rounded()))m — sign in soon")
                loginSoon = true
            }
        }

        // Menu-bar icon = two vertical flood bars (session 5h, weekly 7d) + 5h countdown.
        fiveReset = u.five_hour?.resets_at
        setBars(five: u.five_hour?.utilization ?? 0, weekly: u.seven_day?.utilization ?? 0)

        // Flag the data as stale once it's old and fetches are failing, so the
        // frozen numbers aren't mistaken for current ones.
        let old = lastUpdated.map { Date().timeIntervalSince($0) > STALE_AFTER } ?? false
        var footer = lastUpdated.map { d -> String in
            let f = localFormatter("h:mm a")
            return "Updated \(f.string(from: d))"
        }
        // Show the note when the data is genuinely stale, or when the caller forces
        // it (offline is a known fact, so flag it immediately even if data is fresh).
        if let note = staleNote, old || forceNote, let f = footer {
            footer = "⚠ \(note) — last good \(f.replacingOccurrences(of: "Updated ", with: ""))"
        }
        rebuildMenu(rows: rows, footer: footer, login: loginSoon)
    }

    /// Shown while the network is down: keep the last-good bars (flagged) if we
    /// have them, otherwise a plain "waiting for network" note — never an alarming
    /// login/auth error, since the token is fine and we simply can't reach the API.
    func showOffline() {
        if let u = lastUsage {
            renderUsage(u, staleNote: "No network", forceNote: true)
        } else {
            setTitle("⚠ net", warn: true)
            rebuildMenu(rows: ["Waiting for network…",
                               "Usage will update once you're back online."],
                        footer: nil, link: "Open claude.ai/settings/usage ↗")
        }
    }

    @objc func didWake() {
        // Give Wi-Fi/keychain a moment to come back after wake, then refresh.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refresh() }
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
        // The 5h window's reset time just lapsed: the shown figures belong to a
        // finished window, so pull the fresh one instead of sitting on "now" until
        // the next scheduled poll. Once per reset value (respecting 429 backoff) so
        // we don't drain the shared rate-limit bucket chasing a slow server rollover.
        if reset == "now", let r = fiveReset, r != chasedReset {
            chasedReset = r
            refresh(force: false)
        }
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

    func rebuildMenu(rows: [String], footer: String?, link: String? = nil, login: Bool = false) {
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

        if login {
            let title = "🔑 Log in to Claude…"
            let loginItem = NSMenuItem(title: title, action: #selector(loginClicked), keyEquivalent: "")
            loginItem.target = self
            loginItem.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.linkColor,
                .font: NSFont.boldSystemFont(ofSize: 12)])
            menu.addItem(loginItem)
        }

        if let link = link {
            let linkItem = NSMenuItem(title: link, action: #selector(openSettings), keyEquivalent: "")
            linkItem.target = self
            linkItem.attributedTitle = NSAttributedString(string: link, attributes: [
                .foregroundColor: NSColor.linkColor,
                .font: NSFont.systemFont(ofSize: 12)])
            menu.addItem(linkItem)
        }

        if let up = updateInfo {
            menu.addItem(.separator())
            let title = "⬆ Update available (\(up.version))"
            let upItem = NSMenuItem(title: title, action: #selector(updateClicked), keyEquivalent: "")
            upItem.target = self
            upItem.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.systemGreen,
                .font: NSFont.boldSystemFont(ofSize: 12)])
            menu.addItem(upItem)
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
        let verStr = "ClaudeWatch v\(APP_VERSION)"
        let ver = NSMenuItem(title: verStr, action: nil, keyEquivalent: "")
        ver.attributedTitle = NSAttributedString(string: verStr, attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11)])
        menu.addItem(ver)
        let quit = NSMenuItem(title: "Quit ClaudeWatch", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc func refreshClicked() { refresh() }
    @objc func openSettings() { NSWorkspace.shared.open(URL(string: SETTINGS_URL)!) }

    /// Open Terminal and run `claude auth login` so the user can refresh the
    /// expired OAuth token (the browser flow writes a fresh one to the credential
    /// store). Runs in a visible Terminal because login is interactive (browser +
    /// prompts). The flow can take a while, so instead of guessing a delay we watch
    /// the local credential store — a cheap keychain/file read, no network — and do
    /// a single fetch the moment the stored token actually changes.
    @objc func loginClicked() {
        let oldToken = readCredentials()?.accessToken   // may be nil (never logged in)
        let osa = """
        tell application "Terminal"
            activate
            do script "claude auth login"
        end tell
        """
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", osa]
        try? p.run()

        loginWaitTimer?.invalidate()
        let deadline = Date().addingTimeInterval(5 * 60)   // give up after 5 minutes
        loginWaitTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let current = readCredentials()?.accessToken
            if let current = current, current != oldToken {
                t.invalidate(); self.loginWaitTimer = nil
                self.refresh()   // fresh token in hand → one network fetch (bypasses backoff)
            } else if Date() > deadline {
                t.invalidate(); self.loginWaitTimer = nil
            }
        }
    }
    @objc func quitClicked() { NSApp.terminate(nil) }

    @objc func updateClicked() {
        let alert = NSAlert()
        alert.messageText = "Update ClaudeWatch?"
        alert.informativeText = "This pulls the latest source, rebuilds, and relaunches the app."
            + (updateInfo.map { "\n\nAvailable: \($0.version)" } ?? "")
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { launchUpdate() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
