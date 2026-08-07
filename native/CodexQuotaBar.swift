import AppKit
import Foundation
import SQLite3
import ServiceManagement

struct QuotaSnapshot: Decodable {
    let ok: Bool
    let updatedAt: String?
    let source: String?
    let error: String?
    let plan: String?
    let currentQuotaLeft: Int?
    let currentQuotaReset: String?
    let fiveHourLeft: Int?
    let sevenDayLeft: Int?
    let fiveHourReset: String?
    let sevenDayReset: String?

    var displayedQuotaLeft: Int? {
        currentQuotaLeft ?? fiveHourLeft
    }

    var displayedQuotaReset: String? {
        currentQuotaReset ?? fiveHourReset
    }
}

struct UsageSnapshot: Decodable {
    let schemaVersion: Int
    let ok: Bool
    let updatedAt: String?
    let error: String?
    let sourceStatus: UsageSourceStatus?
    let pricingStatus: PricingStatus?
    let ranges: [String: UsageRangeSnapshot]
}

struct UsageSourceStatus: Decodable {
    let discoveredFiles: Int
    let indexedFiles: Int
    let changedFiles: Int
    let errors: [String]
}

struct PricingStatus: Decodable {
    let status: String?
    let fetchedAt: String?
    let errors: [String]
}

struct UsageRangeSnapshot: Decodable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningTokens: Int64
    let totalTokens: Int64
    let pricedTokens: Int64
    let unpricedTokens: Int64
    let estimatedCostUSD: Double?
    let models: [ModelUsageSnapshot]
    let daily: [DailyUsageSnapshot]
}

struct ModelUsageSnapshot: Decodable {
    let model: String
    let totalTokens: Int64
    let estimatedCostUSD: Double?
    let priced: Bool
}

struct DailyUsageSnapshot: Decodable {
    let date: String
    let totalTokens: Int64
    let estimatedCostUSD: Double
}

struct AppPreferences: Codable {
    var showFloatingBall: Bool = true
    var floatingBallX: Double?
    var floatingBallY: Double?

    static func load() -> AppPreferences {
        guard let data = try? Data(contentsOf: fileURL()) else {
            return AppPreferences()
        }
        return (try? JSONDecoder().decode(AppPreferences.self, from: data)) ?? AppPreferences()
    }

    func save() {
        do {
            let directory = Self.supportDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(self)
            try data.write(to: Self.fileURL(), options: [.atomic])
        } catch {
            // Preferences are only UI convenience. Ignore write failures so quota display still works.
        }
    }

    static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("CodexQuotaBar", isDirectory: true)
    }

    static func fileURL() -> URL {
        supportDirectory().appendingPathComponent("preferences.json")
    }
}

struct QuotaHistoryEntry {
    let capturedAt: String
    let fiveHourLeft: Int?
    let sevenDayLeft: Int?
    let fiveHourReset: String?
    let sevenDayReset: String?
    let plan: String?
    let source: String?
}

struct TrendMetric {
    let currentRate: Double?
    let previousRate: Double?
}

final class QuotaHistoryStore {
    private enum TrendKind {
        case fiveHour
        case sevenDay
    }

    private let retention: TimeInterval = 30 * 24 * 60 * 60

    private var fileURL: URL {
        AppPreferences.supportDirectory().appendingPathComponent("history.sqlite")
    }

    func record(snapshot: QuotaSnapshot) {
        guard snapshot.ok, snapshot.displayedQuotaLeft != nil || snapshot.sevenDayLeft != nil else {
            return
        }

        let entry = QuotaHistoryEntry(
            capturedAt: snapshot.updatedAt ?? isoString(Date()),
            fiveHourLeft: snapshot.displayedQuotaLeft,
            sevenDayLeft: snapshot.sevenDayLeft,
            fiveHourReset: snapshot.displayedQuotaReset,
            sevenDayReset: snapshot.sevenDayReset,
            plan: snapshot.plan,
            source: snapshot.source
        )

        do {
            let db = try openDatabase()
            defer { sqlite3_close(db) }
            try insert(entry: entry, db: db)
            try prune(db: db)
        } catch {
            // History is informational. Ignore write failures so live quota remains available.
        }
    }

    func trends(now: Date = Date()) -> (fiveHour: TrendMetric, sevenDay: TrendMetric, projection: String) {
        let entries = loadEntries()
        let fiveHour = TrendMetric(
            currentRate: rate(entries: entries, now: now, window: 60 * 60, offset: 0, kind: .fiveHour),
            previousRate: rate(entries: entries, now: now, window: 60 * 60, offset: 60 * 60, kind: .fiveHour)
        )
        let sevenDay = TrendMetric(
            currentRate: rate(entries: entries, now: now, window: 24 * 60 * 60, offset: 0, kind: .sevenDay),
            previousRate: rate(entries: entries, now: now, window: 24 * 60 * 60, offset: 24 * 60 * 60, kind: .sevenDay)
        )
        return (fiveHour, sevenDay, projectedText(entries: entries, currentRate: fiveHour.currentRate))
    }

    static func moveLocalDataToTrash() throws {
        let manager = FileManager.default
        let directory = AppPreferences.supportDirectory()
        if manager.fileExists(atPath: directory.path) {
            var trashedURL: NSURL?
            try manager.trashItem(at: directory, resultingItemURL: &trashedURL)
        }
    }

    private func loadEntries() -> [QuotaHistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let db = try? openDatabase() else {
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT captured_at, five_hour_left, seven_day_left, five_hour_reset, seven_day_reset, plan, source
        FROM quota_snapshots
        ORDER BY captured_at ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var entries: [QuotaHistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            entries.append(
                QuotaHistoryEntry(
                    capturedAt: columnText(statement, 0) ?? "",
                    fiveHourLeft: columnInt(statement, 1),
                    sevenDayLeft: columnInt(statement, 2),
                    fiveHourReset: columnText(statement, 3),
                    sevenDayReset: columnText(statement, 4),
                    plan: columnText(statement, 5),
                    source: columnText(statement, 6)
                )
            )
        }
        return entries
    }

    private func openDatabase() throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: AppPreferences.supportDirectory(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(fileURL.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "CodexQuotaBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open history database."])
        }
        try exec(
            db: db,
            sql: """
            CREATE TABLE IF NOT EXISTS quota_snapshots (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              captured_at TEXT NOT NULL,
              five_hour_left INTEGER,
              seven_day_left INTEGER,
              five_hour_reset TEXT,
              seven_day_reset TEXT,
              plan TEXT,
              source TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_quota_snapshots_captured_at
            ON quota_snapshots(captured_at);
            """
        )
        return db
    }

    private func insert(entry: QuotaHistoryEntry, db: OpaquePointer) throws {
        let sql = """
        INSERT INTO quota_snapshots
        (captured_at, five_hour_left, seven_day_left, five_hour_reset, seven_day_reset, plan, source)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(statement) }

        bindText(statement, 1, entry.capturedAt)
        bindInt(statement, 2, entry.fiveHourLeft)
        bindInt(statement, 3, entry.sevenDayLeft)
        bindText(statement, 4, entry.fiveHourReset)
        bindText(statement, 5, entry.sevenDayReset)
        bindText(statement, 6, entry.plan)
        bindText(statement, 7, entry.source)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(db)
        }
    }

    private func prune(db: OpaquePointer, now: Date = Date()) throws {
        let cutoff = isoString(now.addingTimeInterval(-retention))
        let sql = "DELETE FROM quota_snapshots WHERE captured_at < ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, cutoff)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(db)
        }
    }

    private func exec(db: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite error."
            sqlite3_free(errorMessage)
            throw NSError(domain: "CodexQuotaBar", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bindInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int(statement, index, Int32(value))
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func columnInt(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int(statement, index))
    }

    private func sqliteError(_ db: OpaquePointer) -> NSError {
        let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "SQLite error."
        return NSError(domain: "CodexQuotaBar", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func rate(entries: [QuotaHistoryEntry], now: Date, window: TimeInterval, offset: TimeInterval, kind: TrendKind) -> Double? {
        let end = now.addingTimeInterval(-offset)
        let start = end.addingTimeInterval(-window)
        let samples = entries.compactMap { entry -> (date: Date, entry: QuotaHistoryEntry)? in
            guard let entryDate = date(entry.capturedAt), entryDate >= start, entryDate <= end else {
                return nil
            }
            return (entryDate, entry)
        }

        guard samples.count >= 2, let first = samples.first?.date, let last = samples.last?.date else {
            return nil
        }

        var consumed = 0
        for index in 1..<samples.count {
            let previous = samples[index - 1].entry
            let current = samples[index].entry
            guard reset(previous, kind: kind) == reset(current, kind: kind),
                  let previousLeft = left(previous, kind: kind),
                  let currentLeft = left(current, kind: kind),
                  currentLeft < previousLeft else {
                continue
            }
            consumed += previousLeft - currentLeft
        }

        guard consumed > 0 else {
            return nil
        }

        let elapsed = max(last.timeIntervalSince(first), 60)
        let scale = kind == .fiveHour ? 3600.0 : 24 * 3600.0
        return Double(consumed) / elapsed * scale
    }

    private func projectedText(entries: [QuotaHistoryEntry], currentRate: Double?) -> String {
        guard let latest = entries.last, let left = latest.fiveHourLeft, let rate = currentRate, rate > 0 else {
            return "Projected quota: --"
        }
        let hours = Double(left) / rate
        if hours < 1 {
            return "Projected quota: ~\(max(1, Int(round(hours * 60))))m"
        }
        let wholeHours = Int(hours)
        let minutes = Int(round((hours - Double(wholeHours)) * 60))
        return "Projected quota: ~\(wholeHours)h \(minutes)m"
    }

    private func left(_ entry: QuotaHistoryEntry, kind: TrendKind) -> Int? {
        kind == .fiveHour ? entry.fiveHourLeft : entry.sevenDayLeft
    }

    private func reset(_ entry: QuotaHistoryEntry, kind: TrendKind) -> String? {
        kind == .fiveHour ? entry.fiveHourReset : entry.sevenDayReset
    }

    private func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let openCockpitItem = NSMenuItem(title: "Open Codex Meter", action: #selector(showCockpit), keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
    private let floatingBallItem = NSMenuItem(title: "Show Floating Ball", action: #selector(toggleFloatingBall), keyEquivalent: "b")
    private let openAtLoginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "l")
    private let currentQuotaItem = NSMenuItem(title: "Current quota: --", action: nil, keyEquivalent: "")
    private let resetItem = NSMenuItem(title: "Reset: --", action: nil, keyEquivalent: "")
    private let updatedItem = NSMenuItem(title: "Last refresh: --", action: nil, keyEquivalent: "")
    private let clearLocalDataItem = NSMenuItem(title: "Clear Local Data...", action: #selector(clearLocalData), keyEquivalent: "")
    private let stateItem = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
    private var timer: Timer?
    private var retryTimer: Timer?
    private var isRefreshing = false
    private var latestSnapshot: QuotaSnapshot?
    private var latestUsage: UsageSnapshot?
    private var floatingPanel: NSPanel?
    private var floatingView: FloatingBallView?
    private var preferences = AppPreferences.load()
    private lazy var cockpitController = CockpitWindowController(
        refreshHandler: { [weak self] in self?.refreshNow() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        updateButton(snapshot: nil, loading: true)
        if preferences.showFloatingBall {
            showFloatingBall()
        }
        refresh(includePriceRefresh: true)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh(includePriceRefresh: false)
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-probe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                self.cockpitController.runUIProbe(anchor: self.statusItem.button) { samples in
                    if let data = try? JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]),
                       let output = String(data: data, encoding: .utf8) {
                        print(output)
                        fflush(stdout)
                    }
                    NSMenu.setMenuBarVisible(true)
                    NSApp.terminate(nil)
                }
            }
        } else if ProcessInfo.processInfo.arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.showCockpit()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--preview-detail") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.showCockpit()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    self?.cockpitController.showDetailForPreview()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        retryTimer?.invalidate()
    }

    private func configureMenu() {
        openCockpitItem.target = self
        menu.addItem(openCockpitItem)
        menu.addItem(NSMenuItem.separator())
        refreshItem.target = self
        menu.addItem(stateItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(currentQuotaItem)
        menu.addItem(resetItem)
        menu.addItem(updatedItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(refreshItem)
        floatingBallItem.target = self
        menu.addItem(floatingBallItem)
        openAtLoginItem.target = self
        updateOpenAtLoginMenuItem()
        menu.addItem(openAtLoginItem)

        let openChatGPT = NSMenuItem(title: "Open ChatGPT", action: #selector(openChatGPT), keyEquivalent: "o")
        openChatGPT.target = self
        menu.addItem(openChatGPT)

        menu.addItem(NSMenuItem.separator())
        clearLocalDataItem.target = self
        menu.addItem(clearLocalDataItem)
        let quit = NSMenuItem(title: "Quit CodexQuotaBar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.toolTip = "CodexQuotaBar"
    }

    @objc private func refreshNow() {
        refresh(includePriceRefresh: true)
    }

    private func refresh(includePriceRefresh: Bool) {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        refreshItem.isEnabled = false
        stateItem.title = "Refreshing..."
        updateButton(snapshot: nil, loading: true)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = self?.readQuota()
            let usage = self?.readUsage(refreshPrices: includePriceRefresh)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                self.refreshItem.isEnabled = true
                self.apply(snapshot: snapshot)
                self.apply(usage: usage)
            }
        }
    }

    private func helperURL() -> URL? {
        if let resource = Bundle.main.url(forResource: "codex_quota", withExtension: "py") {
            return resource
        }
        let source = URL(fileURLWithPath: #filePath)
        return source.deletingLastPathComponent().appendingPathComponent("codex_quota.py")
    }

    private func usageHelperURL() -> URL? {
        if let resource = Bundle.main.url(forResource: "codex_usage", withExtension: "py") {
            return resource
        }
        let source = URL(fileURLWithPath: #filePath)
        return source.deletingLastPathComponent().appendingPathComponent("codex_usage.py")
    }

    private func readUsage(refreshPrices: Bool) -> UsageSnapshot? {
        guard let helper = usageHelperURL() else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper.path] + (refreshPrices ? ["--refresh-prices"] : [])
        process.environment = [
            "HOME": NSHomeDirectory(),
            "CODEX_HOME": NSHomeDirectory() + "/.codex",
            "LOGNAME": NSUserName(),
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            "USER": NSUserName()
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return try JSONDecoder().decode(UsageSnapshot.self, from: data)
        } catch {
            return nil
        }
    }

    private func readQuota() -> QuotaSnapshot {
        guard let helper = helperURL() else {
            return QuotaSnapshot(
                ok: false,
                updatedAt: isoNow(),
                source: "unavailable",
                error: "Helper not found.",
                plan: nil,
                currentQuotaLeft: nil,
                currentQuotaReset: nil,
                fiveHourLeft: nil,
                sevenDayLeft: nil,
                fiveHourReset: nil,
                sevenDayReset: nil
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper.path]
        process.environment = [
            "HOME": NSHomeDirectory(),
            "CODEX_HOME": NSHomeDirectory() + "/.codex",
            "LOGNAME": NSUserName(),
            "PATH": "/Applications/ChatGPT.app/Contents/Resources:/Applications/Codex.app/Contents/Resources:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "SHELL": "/bin/zsh",
            "TMPDIR": NSTemporaryDirectory(),
            "USER": NSUserName()
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return QuotaSnapshot(
                ok: false,
                updatedAt: isoNow(),
                source: "unavailable",
                error: "Could not start helper: \(error.localizedDescription)",
                plan: nil,
                currentQuotaLeft: nil,
                currentQuotaReset: nil,
                fiveHourLeft: nil,
                sevenDayLeft: nil,
                fiveHourReset: nil,
                sevenDayReset: nil
            )
        }

        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()

        do {
            return try JSONDecoder().decode(QuotaSnapshot.self, from: data)
        } catch {
            return QuotaSnapshot(
                ok: false,
                updatedAt: isoNow(),
                source: "unavailable",
                error: "Could not parse helper output.",
                plan: nil,
                currentQuotaLeft: nil,
                currentQuotaReset: nil,
                fiveHourLeft: nil,
                sevenDayLeft: nil,
                fiveHourReset: nil,
                sevenDayReset: nil
            )
        }
    }

    private func apply(snapshot: QuotaSnapshot?) {
        latestSnapshot = snapshot
        updateButton(snapshot: snapshot, loading: false)
        floatingView?.snapshot = snapshot

        guard let snapshot else {
            stateItem.title = "Unavailable"
            currentQuotaItem.title = "Current quota: --"
            resetItem.title = "Reset: --"
            updatedItem.title = "Last refresh: --"
            cockpitController.update(quota: nil, usage: latestUsage)
            return
        }

        if snapshot.ok {
            stateItem.title = "Live quota"
            retryTimer?.invalidate()
            retryTimer = nil
        } else {
            stateItem.title = "Unavailable: \(snapshot.error ?? "unknown error")"
            scheduleRetryIfNeeded()
        }

        currentQuotaItem.title = "Current quota: \(percentText(snapshot.displayedQuotaLeft))"
        resetItem.title = "Reset: \(shortDateTime(snapshot.displayedQuotaReset))"
        updatedItem.title = "Last refresh: \(shortTime(snapshot.updatedAt))"
        cockpitController.update(quota: latestSnapshot, usage: latestUsage)
    }

    private func apply(usage: UsageSnapshot?) {
        latestUsage = usage
        cockpitController.update(quota: latestSnapshot, usage: usage)
        if latestSnapshot?.ok == true, usage?.ok == true {
            stateItem.title = "Live quota · local usage"
        } else if latestSnapshot?.ok == true {
            stateItem.title = "Live quota · usage unavailable"
        }
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else {
            showCockpit()
            return
        }
        if event.type == .rightMouseUp {
            if let button = statusItem.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            }
        } else {
            toggleCockpit()
        }
    }

    @objc private func showCockpit() {
        cockpitController.update(quota: latestSnapshot, usage: latestUsage)
        cockpitController.show(anchor: statusItem.button)
    }

    private func toggleCockpit() {
        if cockpitController.isVisible {
            cockpitController.hide()
        } else {
            showCockpit()
        }
    }

    private func scheduleRetryIfNeeded() {
        guard retryTimer == nil else {
            return
        }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.retryTimer = nil
            self?.refresh(includePriceRefresh: false)
        }
    }

    private func updateButton(snapshot: QuotaSnapshot?, loading: Bool) {
        let quota = snapshot?.displayedQuotaLeft
        let image = renderStatusImage(quota: quota, loading: loading, ok: snapshot?.ok ?? false)
        statusItem.length = image.size.width
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = statusToolTip(snapshot: snapshot)
    }

    private func renderStatusImage(quota: Int?, loading: Bool, ok: Bool) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = NSSize(width: 76, height: 20)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        NSColor.clear.setFill()
        rect.fill()

        drawCompactRow(percent: quota, y: 4.0, loading: loading, ok: ok)

        image.unlockFocus()
        image.isTemplate = false
        image.size = NSSize(width: floor(size.width / scale * scale), height: size.height)
        return image
    }

    private func drawCompactRow(percent: Int?, y: CGFloat, loading: Bool, ok: Bool) {
        let filled = barsFilled(percent)
        let color = quotaColor(percent: percent, loading: loading, ok: ok)
        for index in 0..<5 {
            let x = CGFloat(index * 8)
            let bar = NSBezierPath(roundedRect: NSRect(x: x, y: y + 1.2, width: 5.0, height: 10.0), xRadius: 2.5, yRadius: 2.5)
            if index < filled {
                color.setFill()
            } else {
                NSColor.systemBlue.withAlphaComponent(0.22).setFill()
            }
            bar.fill()
        }

        let percentAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.0, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        NSString(string: percentText(percent)).draw(at: NSPoint(x: 46, y: y - 0.8), withAttributes: percentAttributes)
    }

    private func drawRow(label: String, percent: Int?, y: CGFloat, loading: Bool, ok: Bool) {
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 8.2, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        NSString(string: label).draw(at: NSPoint(x: 0, y: y), withAttributes: labelAttributes)

        let filled = barsFilled(percent)
        let color = quotaColor(percent: percent, loading: loading, ok: ok)
        for index in 0..<5 {
            let x = CGFloat(38 + index * 7)
            let bar = NSBezierPath(roundedRect: NSRect(x: x, y: y + 1.4, width: 4.0, height: 7.2), xRadius: 2.0, yRadius: 2.0)
            if index < filled {
                color.setFill()
            } else {
                NSColor.systemBlue.withAlphaComponent(0.22).setFill()
            }
            bar.fill()
        }

        let percentAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.2, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        NSString(string: percentText(percent)).draw(at: NSPoint(x: 76, y: y), withAttributes: percentAttributes)
    }

    private func barsFilled(_ percent: Int?) -> Int {
        guard let percent else { return 0 }
        return max(0, min(5, Int(ceil(Double(percent) / 20.0))))
    }

    private func quotaColor(percent: Int?, loading: Bool, ok: Bool) -> NSColor {
        if loading || !ok || percent == nil {
            return NSColor(calibratedRed: 0.55, green: 0.69, blue: 0.79, alpha: 0.55)
        }
        if percent! > 60 {
            return NSColor(calibratedRed: 0.28, green: 0.78, blue: 0.48, alpha: 1.0)
        }
        if percent! >= 20 {
            return NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.28, alpha: 1.0)
        }
        return NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.40, alpha: 1.0)
    }

    private func quotaColor(percent: Int?) -> NSColor {
        quotaColor(percent: percent, loading: false, ok: percent != nil)
    }

    private func percentText(_ value: Int?) -> String {
        guard let value else { return "--%" }
        return "\(max(0, min(100, value)))%"
    }

    private func rateText(_ value: Double?, unit: String) -> String {
        guard let value else {
            return "--"
        }
        return String(format: "-%.1f%% / %@", value, unit)
    }

    private func comparisonText(current: Double?, previous: Double?) -> String {
        guard let current, let previous else {
            return "vs prev --"
        }
        let delta = current - previous
        if abs(delta) < 0.05 {
            return "vs prev flat"
        }
        return String(format: "vs prev %@%.1f", delta > 0 ? "+" : "", delta)
    }

    private func shortTime(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "--" }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else { return value }
        let output = DateFormatter()
        output.dateFormat = "HH:mm"
        return output.string(from: date)
    }

    private func shortDateTime(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "--" }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else { return value }
        let output = DateFormatter()
        output.dateFormat = "MM-dd HH:mm"
        return output.string(from: date)
    }

    private func statusToolTip(snapshot: QuotaSnapshot?) -> String {
        guard let snapshot else {
            return "CodexQuotaBar\nQuota: --"
        }
        if !snapshot.ok {
            return "CodexQuotaBar\nUnavailable: \(snapshot.error ?? "unknown error")"
        }
        return """
        CodexQuotaBar
        Quota: \(percentText(snapshot.displayedQuotaLeft))
        Reset: \(shortDateTime(snapshot.displayedQuotaReset))
        Last refresh: \(shortTime(snapshot.updatedAt))
        """
    }

    private func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    @objc private func openChatGPT() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.open(appURL)
            return
        }

        for path in [
            "/Applications/ChatGPT.app",
            NSHomeDirectory() + "/Applications/ChatGPT.app",
            "/Applications/Codex.app",
            NSHomeDirectory() + "/Applications/Codex.app"
        ] where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }

        stateItem.title = "ChatGPT or Codex app not found."
    }

    @objc private func toggleFloatingBall() {
        if let floatingPanel, floatingPanel.isVisible {
            floatingPanel.orderOut(nil)
            preferences.showFloatingBall = false
            preferences.save()
            floatingBallItem.title = "Show Floating Ball"
            return
        }

        preferences.showFloatingBall = true
        preferences.save()
        showFloatingBall()
    }

    private func showFloatingBall() {
        if floatingPanel == nil {
            let size = NSSize(width: 54, height: 54)
            let origin = floatingBallOrigin(size: size)
            let panel = NSPanel(
                contentRect: NSRect(origin: origin, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.acceptsMouseMovedEvents = true
            panel.delegate = self

            let view = FloatingBallView(frame: NSRect(origin: .zero, size: size))
            view.toolTipProvider = { [weak self] snapshot in
                self?.statusToolTip(snapshot: snapshot) ?? "CodexQuotaBar"
            }
            view.clickHandler = { [weak self] in
                self?.showCockpit()
            }
            view.snapshot = latestSnapshot
            panel.contentView = view

            floatingPanel = panel
            floatingView = view
        }

        floatingPanel?.makeKeyAndOrderFront(nil)
        floatingBallItem.title = "Hide Floating Ball"
    }

    private func floatingBallOrigin(size: NSSize) -> NSPoint {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let defaultOrigin = NSPoint(x: screenFrame.maxX - size.width - 28, y: screenFrame.maxY - size.height - 80)

        guard let savedX = preferences.floatingBallX, let savedY = preferences.floatingBallY else {
            return defaultOrigin
        }

        let minX = screenFrame.minX + 8
        let maxX = screenFrame.maxX - size.width - 8
        let minY = screenFrame.minY + 8
        let maxY = screenFrame.maxY - size.height - 8
        return NSPoint(
            x: min(max(CGFloat(savedX), minX), maxX),
            y: min(max(CGFloat(savedY), minY), maxY)
        )
    }

    func windowDidMove(_ notification: Notification) {
        guard let movedWindow = notification.object as? NSWindow, movedWindow === floatingPanel else {
            return
        }
        preferences.floatingBallX = Double(movedWindow.frame.origin.x)
        preferences.floatingBallY = Double(movedWindow.frame.origin.y)
        preferences.save()
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            updateOpenAtLoginMenuItem()
        } catch {
            stateItem.title = "Open at Login failed: \(error.localizedDescription)"
        }
    }

    private func updateOpenAtLoginMenuItem() {
        let enabled = SMAppService.mainApp.status == .enabled
        openAtLoginItem.state = enabled ? .on : .off
        openAtLoginItem.title = enabled ? "Open at Login: On" : "Open at Login: Off"
    }

    @objc private func clearLocalData() {
        let alert = NSAlert()
        alert.messageText = "Clear CodexQuotaBar local data?"
        alert.informativeText = "This moves quota history and UI preferences to Trash. It does not touch ChatGPT, Codex CLI, ~/.codex, prompts, or projects."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            try QuotaHistoryStore.moveLocalDataToTrash()
            preferences = AppPreferences()
            latestUsage = nil
            cockpitController.update(quota: latestSnapshot, usage: nil)
            stateItem.title = "Local CodexQuotaBar data moved to Trash."
        } catch {
            stateItem.title = "Could not clear local data: \(error.localizedDescription)"
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

final class FloatingBallView: NSView {
    var toolTipProvider: ((QuotaSnapshot?) -> String)?
    var clickHandler: (() -> Void)?
    private var hoverPanel: NSPanel?

    var snapshot: QuotaSnapshot? {
        didSet {
            toolTip = toolTipProvider?(snapshot)
            if hoverPanel?.isVisible == true {
                showHoverPanel()
            }
            needsDisplay = true
        }
    }

    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let start = NSEvent.mouseLocation
        window?.performDrag(with: event)
        let end = NSEvent.mouseLocation
        if hypot(end.x - start.x, end.y - start.y) < 4 {
            clickHandler?()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        showHoverPanel()
    }

    override func mouseExited(with event: NSEvent) {
        hideHoverPanel()
    }

    private func showHoverPanel() {
        guard let window, let text = toolTipProvider?(snapshot), !text.isEmpty else {
            return
        }

        let size = HoverInfoView.size(for: text)
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        var origin = NSPoint(x: window.frame.maxX + 8, y: window.frame.midY - size.height / 2)
        if origin.x + size.width > screenFrame.maxX - 8 {
            origin.x = window.frame.minX - size.width - 8
        }
        origin.x = min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)
        origin.y = min(max(origin.y, screenFrame.minY + 8), screenFrame.maxY - size.height - 8)

        let panel = hoverPanel ?? NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.contentView = HoverInfoView(frame: NSRect(origin: .zero, size: size), text: text)
        hoverPanel = panel
        panel.orderFront(nil)
    }

    private func hideHoverPanel() {
        hoverPanel?.orderOut(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds.insetBy(dx: 6, dy: 6)
        NSColor.clear.setFill()
        dirtyRect.fill()

        let background = NSBezierPath(ovalIn: bounds)
        NSColor.black.withAlphaComponent(0.58).setFill()
        background.fill()

        let quota = snapshot?.displayedQuotaLeft
        drawRing(in: bounds.insetBy(dx: 9, dy: 9), percent: quota, color: color(for: quota), width: 4.8)
        drawQuotaLabel(quota, in: bounds)
    }

    private func drawQuotaLabel(_ percent: Int?, in rect: NSRect) {
        let text = percentText(percent)
        let fontSize: CGFloat = text.count >= 3 ? 9.0 : 11.5
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .shadow: shadow
        ]
        let label = NSString(string: text)
        let labelSize = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(
                x: rect.midX - labelSize.width / 2,
                y: rect.midY - labelSize.height / 2
            ),
            withAttributes: attributes
        )
    }

    private func drawRing(in rect: NSRect, percent: Int?, color: NSColor, width: CGFloat) {
        let track = NSBezierPath(ovalIn: rect)
        NSColor.white.withAlphaComponent(0.16).setStroke()
        track.lineWidth = width
        track.stroke()

        guard let percent else {
            return
        }
        let clamped = max(0, min(100, percent))
        let start: CGFloat = 90
        let end = start - CGFloat(clamped) / 100.0 * 360.0
        let path = NSBezierPath()
        path.appendArc(
            withCenter: NSPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2,
            startAngle: start,
            endAngle: end,
            clockwise: true
        )
        color.setStroke()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.stroke()
    }

    private func color(for percent: Int?) -> NSColor {
        guard let percent else {
            return NSColor(calibratedRed: 0.55, green: 0.69, blue: 0.79, alpha: 0.65)
        }
        if percent > 60 {
            return NSColor(calibratedRed: 0.28, green: 0.78, blue: 0.48, alpha: 1.0)
        }
        if percent >= 20 {
            return NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.28, alpha: 1.0)
        }
        return NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.40, alpha: 1.0)
    }

    private func percentText(_ value: Int?) -> String {
        guard let value else { return "--" }
        return "\(max(0, min(100, value)))"
    }
}

final class HoverInfoView: NSView {
    private static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 10
    private static let lineHeight: CGFloat = 18

    private let text: String

    init(frame frameRect: NSRect, text: String) {
        self.text = text
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let bubble = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.78).setFill()
        bubble.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Self.lineHeight
        paragraph.maximumLineHeight = Self.lineHeight
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        NSString(string: text).draw(in: bounds.insetBy(dx: Self.horizontalPadding, dy: Self.verticalPadding), withAttributes: attributes)
    }

    static func size(for text: String) -> NSSize {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font
        ]
        let lines = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
        let textSize = NSString(string: text).boundingRect(
            with: NSSize(width: 320, height: 240),
            options: [.usesLineFragmentOrigin],
            attributes: attributes
        ).size
        return NSSize(
            width: max(174, ceil(textSize.width) + Self.horizontalPadding * 2),
            height: ceil(CGFloat(lines) * Self.lineHeight + Self.verticalPadding * 2)
        )
    }
}

final class CockpitWindowController: NSObject, NSWindowDelegate {
    private enum Mode {
        case compact
        case detail
    }

    private let compactSize = NSSize(width: 430, height: 232)
    private let detailSize = NSSize(width: 430, height: 407)
    private let refreshHandler: () -> Void
    private var mode: Mode = .compact
    private var selectedRange = "all"
    private var quota: QuotaSnapshot?
    private var usage: UsageSnapshot?
    private var panel: NSPanel?
    private var anchorTopCenter: NSPoint?
    private var detailContainer: NSView?
    private var detailHeightConstraint: NSLayoutConstraint?
    private var detailButton: NSButton?
    private var headerContainer: NSView?
    private var summaryContainer: NSView?
    private var trendContainer: NSView?
    private var modelsContainer: NSView?
    private var menuBarKeepAliveTimer: Timer?
    private var globalClickMonitor: Any?
    private var appResignObserver: NSObjectProtocol?
    private var transitionGeneration = 0

    init(refreshHandler: @escaping () -> Void) {
        self.refreshHandler = refreshHandler
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func update(quota: QuotaSnapshot?, usage: UsageSnapshot?) {
        self.quota = quota
        self.usage = usage
        if isVisible {
            render()
        }
    }

    func showDetailForPreview() {
        showDetail()
    }

    func show(anchor: NSStatusBarButton?) {
        guard let anchor, let anchorPoint = anchorTopCenter(for: anchor) else { return }
        let panel = ensurePanel()
        anchorTopCenter = anchorPoint
        render()
        if !panel.isVisible {
            startHoldingMenuBarVisible()
            NSApp.activate(ignoringOtherApps: true)
            let size = mode == .compact ? compactSize : detailSize
            panel.setFrame(frame(size: size, below: anchorPoint), display: true)
            panel.orderFrontRegardless()
            startDismissMonitoring()
        }
    }

    func hide() {
        stopHoldingMenuBarVisible()
        stopDismissMonitoring()
        transitionGeneration += 1
        mode = .compact
        panel?.orderOut(nil)
    }

    func runUIProbe(anchor: NSStatusBarButton?, completion: @escaping ([[String: Any]]) -> Void) {
        guard let anchor else {
            completion([["error": "missing status item anchor"]])
            return
        }
        show(anchor: anchor)
        var samples: [[String: Any]] = []
        func sample(_ stage: String) {
            guard let panel else { return }
            var row: [String: Any] = [
                "stage": stage,
                "menuBarVisible": NSMenu.menuBarVisible(),
                "panelX": panel.frame.minX,
                "panelTop": panel.frame.maxY,
                "panelHeight": panel.frame.height,
                "panelVisible": panel.isVisible,
            ]
            if let headerContainer {
                let rect = panel.convertToScreen(headerContainer.convert(headerContainer.bounds, to: nil))
                row["headerX"] = rect.minX
                row["headerTop"] = rect.maxY
            }
            if let summaryContainer {
                let rect = panel.convertToScreen(summaryContainer.convert(summaryContainer.bounds, to: nil))
                row["summaryX"] = rect.minX
                row["summaryTop"] = rect.maxY
            }
            row["detailHeight"] = detailHeightConstraint?.constant ?? -1
            row["detailAlpha"] = detailContainer?.alphaValue ?? -1
            if let trendContainer {
                let rect = panel.convertToScreen(trendContainer.convert(trendContainer.bounds, to: nil))
                row["trendTop"] = rect.maxY
                row["trendHeight"] = rect.height
            }
            if let modelsContainer {
                let rect = panel.convertToScreen(modelsContainer.convert(modelsContainer.bounds, to: nil))
                row["modelsTop"] = rect.maxY
                row["modelsHeight"] = rect.height
            }
            samples.append(row)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            sample("compact")
            func stressMenuRestore(_ index: Int) {
                guard index < 5 else {
                    self.showDetail()
                    for (sampleIndex, delay) in [0.02, 0.08, 0.16, 0.24, 0.36].enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            sample("expand-\(sampleIndex)")
                            if sampleIndex == 4 {
                                self.showCompact()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                                    sample("collapsed")
                                    self.showDetail()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
                                        sample("expanded-before-close")
                                        self.hide()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                            self.show(anchor: anchor)
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                                sample("reopened")
                                                guard let panel = self.panel else {
                                                    completion(samples)
                                                    return
                                                }
                                                self.dismissIfOutside(NSPoint(x: panel.frame.midX, y: panel.frame.midY))
                                                sample("inside-click")
                                                self.dismissIfOutside(NSPoint(x: panel.frame.minX - 20, y: panel.frame.minY - 20))
                                                sample("outside-click")
                                                completion(samples)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    return
                }
                NSMenu.setMenuBarVisible(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    sample("menu-restore-\(index)")
                    stressMenuRestore(index + 1)
                }
            }
            stressMenuRestore(0)
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopHoldingMenuBarVisible()
    }

    private func startHoldingMenuBarVisible() {
        stopHoldingMenuBarVisible()
        NSMenu.setMenuBarVisible(true)
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] timer in
            guard let self, self.panel?.isVisible == true else {
                timer.invalidate()
                return
            }
            if !NSMenu.menuBarVisible() {
                NSMenu.setMenuBarVisible(true)
            }
        }
        menuBarKeepAliveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopHoldingMenuBarVisible() {
        menuBarKeepAliveTimer?.invalidate()
        menuBarKeepAliveTimer = nil
    }

    private func startDismissMonitoring() {
        stopDismissMonitoring()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            DispatchQueue.main.async {
                self?.dismissIfOutside(location)
            }
        }
        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.hide()
        }
    }

    private func stopDismissMonitoring() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
    }

    private func dismissIfOutside(_ location: NSPoint) {
        guard let panel, panel.isVisible, !panel.frame.contains(location) else { return }
        hide()
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }
        let created = NSPanel(
            contentRect: NSRect(origin: .zero, size: compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        created.isFloatingPanel = true
        created.becomesKeyOnlyIfNeeded = true
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.level = .popUpMenu
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        created.delegate = self
        created.contentView = compactView()
        panel = created
        return created
    }

    private func render() {
        guard let panel else { return }
        panel.contentView = compactView()
        guard let anchorTopCenter else { return }
        let size = mode == .compact ? compactSize : detailSize
        panel.setFrame(frame(size: size, below: anchorTopCenter), display: true)
    }

    private func transition(to nextMode: Mode) {
        guard mode != nextMode,
              let panel,
              let anchorTopCenter,
              let detailContainer,
              let detailHeightConstraint else { return }
        mode = nextMode
        transitionGeneration += 1
        let generation = transitionGeneration
        let expanded = nextMode == .detail
        let targetSize = expanded ? detailSize : compactSize
        let targetFrame = frame(size: targetSize, below: anchorTopCenter)
        detailButton?.title = expanded ? "收起详情" : "查看详情"
        detailButton?.action = expanded ? #selector(showCompact) : #selector(showDetail)
        let targetHeight: CGFloat = expanded ? 167 : 0
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            detailHeightConstraint.constant = targetHeight
            detailContainer.alphaValue = expanded ? 1 : 0
            panel.setFrame(targetFrame, display: true)
            panel.contentView?.layoutSubtreeIfNeeded()
            return
        }
        if expanded {
            detailContainer.alphaValue = 0
            detailHeightConstraint.constant = targetHeight
            panel.contentView?.layoutSubtreeIfNeeded()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(targetFrame, display: true)
            }, completionHandler: { [weak self, weak detailContainer] in
                guard let self, self.transitionGeneration == generation, self.mode == .detail, let detailContainer else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    detailContainer.animator().alphaValue = 1
                }
            })
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.08
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                detailContainer.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak detailContainer] in
                guard let self, self.transitionGeneration == generation, self.mode == .compact, let detailContainer else { return }
                detailHeightConstraint.constant = 0
                detailContainer.alphaValue = 0
                panel.contentView?.layoutSubtreeIfNeeded()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.20
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(targetFrame, display: true)
                }
            })
        }
    }

    private func anchorTopCenter(for anchor: NSStatusBarButton) -> NSPoint? {
        guard let window = anchor.window else { return nil }
        let screenRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        return NSPoint(x: screenRect.midX, y: screenRect.minY - 4)
    }

    private func frame(size: NSSize, below anchor: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        let bounds = screen?.frame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let x = min(max(anchor.x - size.width / 2, bounds.minX + 8), bounds.maxX - size.width - 8)
        let y = max(bounds.minY + 8, anchor.y - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func compactView() -> NSView {
        let root = backgroundView()
        let stack = verticalStack(spacing: 8)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
        ])
        let header = headerView(expanded: mode == .detail)
        headerContainer = header
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let cards = summaryCards()
        summaryContainer = cards
        stack.addArrangedSubview(cards)
        cards.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let details = NSView()
        details.translatesAutoresizingMaskIntoConstraints = false
        let detailContent = detailContentView()
        detailContent.translatesAutoresizingMaskIntoConstraints = false
        details.addSubview(detailContent)
        NSLayoutConstraint.activate([
            detailContent.leadingAnchor.constraint(equalTo: details.leadingAnchor),
            detailContent.trailingAnchor.constraint(equalTo: details.trailingAnchor),
            detailContent.topAnchor.constraint(equalTo: details.topAnchor),
            detailContent.heightAnchor.constraint(equalToConstant: 167),
        ])
        details.alphaValue = mode == .detail ? 1 : 0
        details.wantsLayer = true
        details.layer?.masksToBounds = true
        stack.addArrangedSubview(details)
        details.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let height = details.heightAnchor.constraint(equalToConstant: mode == .detail ? 167 : 0)
        height.isActive = true
        detailContainer = details
        detailHeightConstraint = height
        let footer = statusFooter()
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return root
    }

    private func detailView() -> NSView {
        let root = backgroundView()
        let stack = verticalStack(spacing: 8)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        let header = headerView(expanded: true)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let cards = summaryCards()
        stack.addArrangedSubview(cards)
        cards.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let summary = usage?.ranges[selectedRange]
        let lower = NSStackView()
        lower.orientation = .horizontal
        lower.spacing = 8
        lower.distribution = .fill
        let chartCard = CockpitPanelView()
        let chartStack = verticalStack(spacing: 5)
        chartCard.addSubview(chartStack)
        NSLayoutConstraint.activate([
            chartStack.leadingAnchor.constraint(equalTo: chartCard.leadingAnchor, constant: 10),
            chartStack.trailingAnchor.constraint(equalTo: chartCard.trailingAnchor, constant: -10),
            chartStack.topAnchor.constraint(equalTo: chartCard.topAnchor, constant: 9),
            chartStack.bottomAnchor.constraint(equalTo: chartCard.bottomAnchor, constant: -9),
        ])
        let chartHeader = NSStackView()
        chartHeader.orientation = .horizontal
        chartHeader.addArrangedSubview(label("Token 趋势", size: 12, weight: .semibold))
        chartHeader.addArrangedSubview(NSView())
        chartHeader.addArrangedSubview(label(rangeTitle(selectedRange), size: 10, color: .secondaryLabelColor))
        chartStack.addArrangedSubview(chartHeader)
        chartHeader.widthAnchor.constraint(equalTo: chartStack.widthAnchor).isActive = true
        let chart = UsageTrendView(points: summary?.daily ?? [])
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 78).isActive = true
        chartStack.addArrangedSubview(chart)
        chartStack.addArrangedSubview(label(tokenComposition(summary), size: 10.5, color: .secondaryLabelColor))
        chartCard.widthAnchor.constraint(equalToConstant: 250).isActive = true
        lower.addArrangedSubview(chartCard)
        let modelsCard = CockpitPanelView()
        let modelsStack = verticalStack(spacing: 5)
        modelsCard.addSubview(modelsStack)
        NSLayoutConstraint.activate([
            modelsStack.leadingAnchor.constraint(equalTo: modelsCard.leadingAnchor, constant: 9),
            modelsStack.trailingAnchor.constraint(equalTo: modelsCard.trailingAnchor, constant: -9),
            modelsStack.topAnchor.constraint(equalTo: modelsCard.topAnchor, constant: 9),
            modelsStack.bottomAnchor.constraint(lessThanOrEqualTo: modelsCard.bottomAnchor, constant: -9),
        ])
        modelsStack.addArrangedSubview(label("模型构成", size: 12, weight: .semibold))
        let topModels = Array((summary?.models ?? []).prefix(4))
        if topModels.isEmpty {
            modelsStack.addArrangedSubview(label("暂无 Token 数据", size: 10.5, color: .secondaryLabelColor))
        } else {
            for item in topModels {
                modelsStack.addArrangedSubview(modelRow(item))
            }
        }
        lower.addArrangedSubview(modelsCard)
        stack.addArrangedSubview(lower)
        lower.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let footer = statusFooter()
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return root
    }

    private func headerView(expanded: Bool) -> NSView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.addArrangedSubview(label("Codex Meter", size: 14, weight: .semibold))
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = (quota?.ok == true ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7)])
        header.addArrangedSubview(dot)
        header.addArrangedSubview(NSView())
        let toggle = button(expanded ? "收起详情" : "查看详情", action: expanded ? #selector(showCompact) : #selector(showDetail))
        detailButton = toggle
        header.addArrangedSubview(toggle)
        header.addArrangedSubview(button("刷新", action: #selector(refreshPressed)))
        header.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return header
    }

    private func summaryCards() -> NSView {
        let summary = usage?.ranges[selectedRange]
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        row.addArrangedSubview(CockpitCardView(
            title: "额度",
            value: quotaValueText(),
            subtitle: quotaResetText(),
            accent: .systemTeal,
            symbolName: "clock",
            control: quotaRangeButton()
        ))
        row.addArrangedSubview(CockpitCardView(
            title: "Codex Token",
            value: formatTokens(summary?.totalTokens),
            subtitle: tokenComposition(summary),
            accent: .systemBlue,
            symbolName: "chart.bar.xaxis",
            control: usageRangeButton()
        ))
        row.addArrangedSubview(CockpitCardView(
            title: "API 等价值",
            value: formatCost(summary?.estimatedCostUSD),
            subtitle: priceCoverage(summary),
            accent: .systemOrange,
            symbolName: "dollarsign.circle",
            control: syncLabel()
        ))
        row.heightAnchor.constraint(equalToConstant: 128).isActive = true
        return row
    }

    private func detailContentView() -> NSView {
        let summary = usage?.ranges[selectedRange]
        let lower = NSStackView()
        lower.orientation = .horizontal
        lower.spacing = 8
        lower.distribution = .fill
        lower.alignment = .top

        let chartCard = CockpitPanelView()
        let chartStack = verticalStack(spacing: 5)
        chartCard.addSubview(chartStack)
        NSLayoutConstraint.activate([
            chartStack.leadingAnchor.constraint(equalTo: chartCard.leadingAnchor, constant: 10),
            chartStack.trailingAnchor.constraint(equalTo: chartCard.trailingAnchor, constant: -10),
            chartStack.topAnchor.constraint(equalTo: chartCard.topAnchor, constant: 9),
            chartStack.bottomAnchor.constraint(equalTo: chartCard.bottomAnchor, constant: -9),
        ])
        let chartHeader = NSStackView()
        chartHeader.orientation = .horizontal
        chartHeader.addArrangedSubview(label("Token 趋势", size: 12, weight: .semibold))
        chartHeader.addArrangedSubview(NSView())
        chartHeader.addArrangedSubview(label(rangeTitle(selectedRange), size: 10, color: .secondaryLabelColor))
        chartStack.addArrangedSubview(chartHeader)
        chartHeader.widthAnchor.constraint(equalTo: chartStack.widthAnchor).isActive = true
        let chart = UsageTrendView(points: summary?.daily ?? [])
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 72).isActive = true
        chartStack.addArrangedSubview(chart)
        let stats = NSStackView()
        stats.orientation = .horizontal
        stats.distribution = .fillEqually
        stats.spacing = 5
        stats.addArrangedSubview(detailStat(title: "输入", value: formatTokens(summary?.inputTokens)))
        stats.addArrangedSubview(detailStat(title: "缓存", value: formatTokens(summary?.cachedInputTokens)))
        stats.addArrangedSubview(detailStat(title: "输出", value: formatTokens(summary?.outputTokens)))
        chartStack.addArrangedSubview(stats)
        stats.widthAnchor.constraint(equalTo: chartStack.widthAnchor).isActive = true
        chartCard.widthAnchor.constraint(equalToConstant: 250).isActive = true
        trendContainer = chartCard
        lower.addArrangedSubview(chartCard)
        chartCard.heightAnchor.constraint(equalTo: lower.heightAnchor).isActive = true

        let modelsCard = CockpitPanelView()
        let modelsStack = verticalStack(spacing: 4)
        modelsCard.addSubview(modelsStack)
        NSLayoutConstraint.activate([
            modelsStack.leadingAnchor.constraint(equalTo: modelsCard.leadingAnchor, constant: 9),
            modelsStack.trailingAnchor.constraint(equalTo: modelsCard.trailingAnchor, constant: -9),
            modelsStack.topAnchor.constraint(equalTo: modelsCard.topAnchor, constant: 9),
            modelsStack.bottomAnchor.constraint(lessThanOrEqualTo: modelsCard.bottomAnchor, constant: -9),
        ])
        let modelsHeader = NSStackView()
        modelsHeader.orientation = .horizontal
        modelsHeader.addArrangedSubview(label("模型构成", size: 12, weight: .semibold))
        modelsHeader.addArrangedSubview(NSView())
        modelsHeader.addArrangedSubview(label("Top 4", size: 9.5, color: .secondaryLabelColor))
        modelsStack.addArrangedSubview(modelsHeader)
        modelsHeader.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
        let topModels = Array((summary?.models ?? []).prefix(4))
        let maximum = topModels.map(\.totalTokens).max() ?? 0
        if topModels.isEmpty {
            modelsStack.addArrangedSubview(label("暂无 Token 数据", size: 10.5, color: .secondaryLabelColor))
        } else {
            for item in topModels {
                modelsStack.addArrangedSubview(modelRow(item, maximum: maximum))
            }
        }
        modelsContainer = modelsCard
        lower.addArrangedSubview(modelsCard)
        modelsCard.heightAnchor.constraint(equalTo: lower.heightAnchor).isActive = true
        return lower
    }

    private func detailStat(title: String, value: String) -> NSView {
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 7
        panel.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.34).cgColor
        let stack = verticalStack(spacing: 1)
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -4),
        ])
        stack.addArrangedSubview(label(title, size: 9, color: .secondaryLabelColor))
        stack.addArrangedSubview(label(value, size: 10.5, weight: .semibold))
        return panel
    }

    private func statusFooter() -> NSView {
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.addArrangedSubview(label(usageStatusText(), size: 10.5, color: .secondaryLabelColor))
        footer.addArrangedSubview(NSView())
        footer.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return footer
    }

    private func backgroundView() -> NSView {
        let effect = CockpitBackdropView()
        effect.translatesAutoresizingMaskIntoConstraints = false
        return effect
    }

    private func verticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let value = NSButton(title: title, target: self, action: action)
        value.bezelStyle = .rounded
        value.controlSize = .small
        return value
    }

    private func quotaRangeButton() -> NSView {
        return label("7 天", size: 10, weight: .medium, color: .secondaryLabelColor)
    }

    private func usageRangeButton() -> NSView {
        let control = NSPopUpButton()
        control.addItems(withTitles: ["今天", "7 天", "30 天", "本月", "全部"])
        let keys = ["today", "7d", "30d", "month", "all"]
        control.selectItem(at: keys.firstIndex(of: selectedRange) ?? 4)
        control.target = self
        control.action = #selector(usageRangeChanged(_:))
        control.controlSize = .mini
        return control
    }

    private func syncLabel() -> NSView {
        let value = label("同步", size: 10, weight: .medium, color: .secondaryLabelColor)
        value.alignment = .center
        return value
    }

    private func quotaValueText() -> String {
        let value = quota?.sevenDayLeft ?? quota?.currentQuotaLeft
        return value.map { "\($0)%" } ?? "--%"
    }

    private func quotaResetText() -> String {
        let value = quota?.sevenDayReset ?? quota?.currentQuotaReset
        return value == nil ? "等待额度数据" : "重置 \(shortDateTime(value))"
    }

    private func rangeTitle(_ key: String) -> String {
        ["today": "今天", "7d": "7 天", "30d": "30 天", "month": "本月", "all": "全部"][key] ?? "全部"
    }

    private func modelRow(_ item: ModelUsageSnapshot) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        let name = label(item.model, size: 10, weight: .medium)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(name)
        row.addArrangedSubview(NSView())
        let detail = item.priced
            ? "\(formatTokens(item.totalTokens))  \(formatCost(item.estimatedCostUSD))"
            : "\(formatTokens(item.totalTokens))  未计价"
        row.addArrangedSubview(label(detail, size: 9.5, color: item.priced ? .secondaryLabelColor : .systemOrange))
        return row
    }

    private func modelRow(_ item: ModelUsageSnapshot, maximum: Int64) -> NSView {
        let stack = verticalStack(spacing: 2)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        let name = label(item.model, size: 9.5, weight: .medium)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(name)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(label(formatTokens(item.totalTokens), size: 9.2, color: .secondaryLabelColor))
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let track = NSView()
        track.wantsLayer = true
        track.layer?.cornerRadius = 1.5
        track.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
        track.translatesAutoresizingMaskIntoConstraints = false
        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 1.5
        fill.layer?.backgroundColor = NSColor.systemBlue.cgColor
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        let fraction = maximum > 0 ? min(1, CGFloat(item.totalTokens) / CGFloat(maximum)) : 0
        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: 3),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: fraction),
        ])
        stack.addArrangedSubview(track)
        track.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func tokenComposition(_ value: UsageRangeSnapshot?) -> String {
        guard let value else { return "等待本机数据" }
        return "输入 \(formatTokens(value.inputTokens)) · 输出 \(formatTokens(value.outputTokens))"
    }

    private func priceCoverage(_ value: UsageRangeSnapshot?) -> String {
        guard let value else { return "官方 API 标准价估算" }
        if value.unpricedTokens > 0 {
            return "\(formatTokens(value.unpricedTokens)) 未计价"
        }
        return "官方 API 标准价估算"
    }

    private func usageStatusText() -> String {
        guard let usage else { return "正在读取本机 Token 数据…" }
        if !usage.ok {
            return "Token 数据不可用：\(usage.error ?? "未知错误")"
        }
        let files = usage.sourceStatus?.indexedFiles ?? 0
        let priceState: String
        switch usage.pricingStatus?.status {
        case "live": priceState = "价格已从 OpenAI 更新"
        case "partial": priceState = "部分价格已更新"
        case "cached": priceState = "使用上次价格"
        default: priceState = "使用内置官方价格"
        }
        return "仅扫描本机 \(files) 个日志文件 · \(priceState) · \(shortTime(usage.updatedAt))"
    }

    private func formatTokens(_ value: Int64?) -> String {
        guard let value else { return "--" }
        let number = Double(value)
        if number >= 1_000_000_000 { return String(format: "%.2fB", number / 1_000_000_000) }
        if number >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
        if number >= 1_000 { return String(format: "%.1fK", number / 1_000) }
        return "\(value)"
    }

    private func formatCost(_ value: Double?) -> String {
        guard let value else { return "$--" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "$"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    private func shortTime(_ value: String?) -> String {
        guard let value, let date = isoDate(value) else { return "--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func shortDateTime(_ value: String?) -> String {
        guard let value, let date = isoDate(value) else { return "--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func isoDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    @objc private func refreshPressed() {
        refreshHandler()
    }

    @objc private func showDetail() {
        transition(to: .detail)
    }

    @objc private func showCompact() {
        transition(to: .compact)
    }

    @objc private func usageRangeChanged(_ sender: NSPopUpButton) {
        let keys = ["today", "7d", "30d", "month", "all"]
        guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < keys.count else { return }
        selectedRange = keys[sender.indexOfSelectedItem]
        render()
    }
}

final class CockpitBackdropView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let colors: [NSColor] = [
            NSColor.systemBlue.withAlphaComponent(0.10),
            NSColor.systemPurple.withAlphaComponent(0.07),
            NSColor.white.withAlphaComponent(0.04),
        ]
        NSGradient(colors: colors)?.draw(in: bounds, angle: -35)
    }
}

class CockpitPanelView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.44).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.42).cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.08
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        nil
    }
}

final class CockpitCardView: CockpitPanelView {
    init(title: String, value: String, subtitle: String, accent: NSColor, symbolName: String, control: NSView) {
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 124),
        ])

        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .centerY
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: title)
        icon.contentTintColor = accent
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22)])
        top.addArrangedSubview(icon)
        top.addArrangedSubview(NSView())
        top.addArrangedSubview(control)
        stack.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let heading = NSTextField(labelWithString: title)
        heading.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        heading.textColor = .secondaryLabelColor
        stack.addArrangedSubview(heading)
        let amount = NSTextField(labelWithString: value)
        amount.font = NSFont.monospacedDigitSystemFont(ofSize: 23, weight: .bold)
        amount.textColor = .labelColor
        amount.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(amount)
        let detail = NSTextField(labelWithString: subtitle)
        detail.font = NSFont.systemFont(ofSize: 10.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(detail)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

final class UsageTrendView: NSView {
    private let points: [DailyUsageSnapshot]

    init(points: [DailyUsageSnapshot]) {
        self.points = points
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let plot = bounds.insetBy(dx: 8, dy: 20)
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: plot.minX, y: plot.minY))
        baseline.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        baseline.stroke()

        guard !points.isEmpty, let maximum = points.map(\.totalTokens).max(), maximum > 0 else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            NSString(string: "暂无趋势数据").draw(at: NSPoint(x: plot.midX - 38, y: plot.midY), withAttributes: attributes)
            return
        }

        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let fraction = points.count == 1 ? 0.5 : CGFloat(index) / CGFloat(points.count - 1)
            let x = plot.minX + plot.width * fraction
            let y = plot.minY + plot.height * CGFloat(Double(point.totalTokens) / Double(maximum))
            if index == 0 { path.move(to: NSPoint(x: x, y: y)) }
            else { path.line(to: NSPoint(x: x, y: y)) }
        }
        path.lineWidth = 2.5
        path.lineJoinStyle = .round
        NSColor.systemTeal.setStroke()
        path.stroke()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
