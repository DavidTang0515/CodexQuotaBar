import AppKit
import Darwin
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

}

struct UsageSnapshot: Decodable {
    let ok: Bool
    let updatedAt: String?
    let error: String?
    let sourceStatus: UsageSourceStatus?
    let ranges: [String: UsageRangeSnapshot]
}

struct UsageSourceStatus: Decodable {
    let discoveredFiles: Int
    let indexedFiles: Int
    let changedFiles: Int
    let errors: [String]
}

struct UsageRangeSnapshot: Decodable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningTokens: Int64
    let totalTokens: Int64
}

struct AppPreferences: Codable {
    var showFloatingBall: Bool = true
    var floatingBallX: Double?
    var floatingBallY: Double?
    var usageRange: String?

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
        guard snapshot.ok, snapshot.fiveHourLeft != nil || snapshot.sevenDayLeft != nil else {
            return
        }

        let entry = QuotaHistoryEntry(
            capturedAt: snapshot.updatedAt ?? isoString(Date()),
            fiveHourLeft: snapshot.fiveHourLeft,
            sevenDayLeft: snapshot.sevenDayLeft,
            fiveHourReset: snapshot.fiveHourReset,
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
        for url in [
            AppPreferences.fileURL(),
            AppPreferences.supportDirectory().appendingPathComponent("history.sqlite"),
            AppPreferences.supportDirectory().appendingPathComponent("quota-history.jsonl"),
            AppPreferences.supportDirectory().appendingPathComponent("usage.sqlite"),
            AppPreferences.supportDirectory().appendingPathComponent("usage.sqlite-wal"),
            AppPreferences.supportDirectory().appendingPathComponent("usage.sqlite-shm")
        ] where manager.fileExists(atPath: url.path) {
            var trashedURL: NSURL?
            try manager.trashItem(at: url, resultingItemURL: &trashedURL)
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
            return "Projected 5h: --"
        }
        let hours = Double(left) / rate
        if hours < 1 {
            return "Projected 5h: ~\(max(1, Int(round(hours * 60))))m"
        }
        let wholeHours = Int(hours)
        let minutes = Int(round((hours - Double(wholeHours)) * 60))
        return "Projected 5h: ~\(wholeHours)h \(minutes)m"
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
    private let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
    private let floatingBallItem = NSMenuItem(title: "Show Floating Ball", action: #selector(toggleFloatingBall), keyEquivalent: "b")
    private let openAtLoginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "l")
    private let fiveHourItem = NSMenuItem(title: "5h: --", action: nil, keyEquivalent: "")
    private let sevenDayItem = NSMenuItem(title: "7d: --", action: nil, keyEquivalent: "")
    private let resetItem = NSMenuItem(title: "Reset: --", action: nil, keyEquivalent: "")
    private let updatedItem = NSMenuItem(title: "Last refresh: --", action: nil, keyEquivalent: "")
    private let trendHeaderItem = NSMenuItem(title: "Usage trend", action: nil, keyEquivalent: "")
    private let fiveHourTrendItem = NSMenuItem(title: "5h: --", action: nil, keyEquivalent: "")
    private let sevenDayTrendItem = NSMenuItem(title: "7d: --", action: nil, keyEquivalent: "")
    private let projectedItem = NSMenuItem(title: "Projected 5h: --", action: nil, keyEquivalent: "")
    private let tokenHeaderItem = NSMenuItem(title: "Local Token", action: nil, keyEquivalent: "")
    private let tokenRangeItem = NSMenuItem(title: "Period: 7 days", action: #selector(cycleUsageRange), keyEquivalent: "t")
    private let tokenTotalItem = NSMenuItem(title: "Token: --", action: nil, keyEquivalent: "")
    private let tokenCompositionItem = NSMenuItem(title: "Input -- · Cached -- · Output --", action: nil, keyEquivalent: "")
    private let clearLocalDataItem = NSMenuItem(title: "Clear Local Data...", action: #selector(clearLocalData), keyEquivalent: "")
    private let stateItem = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
    private let historyStore = QuotaHistoryStore()
    private var timer: Timer?
    private var retryTimer: Timer?
    private var isRefreshing = false
    private var isUsageRefreshing = false
    private var latestSnapshot: QuotaSnapshot?
    private var latestUsage: UsageSnapshot?
    private var lastValidSnapshot: QuotaSnapshot?
    private var operationError: String?
    private var lastRenderedFiveHour: Int?
    private var lastRenderedSevenDay: Int?
    private var lastRenderedLoading = false
    private var lastRenderedOK = false
    private var floatingPanel: NSPanel?
    private var floatingView: FloatingBallView?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var preferences = AppPreferences.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        updateButton(snapshot: nil, loading: true)
        if preferences.showFloatingBall {
            showFloatingBall()
        }
        installDetailDismissMonitors()
        refreshNow()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        retryTimer?.invalidate()
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
    }

    private func configureMenu() {
        refreshItem.target = self
        menu.addItem(stateItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(fiveHourItem)
        menu.addItem(sevenDayItem)
        menu.addItem(resetItem)
        menu.addItem(updatedItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(trendHeaderItem)
        menu.addItem(fiveHourTrendItem)
        menu.addItem(sevenDayTrendItem)
        menu.addItem(projectedItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(tokenHeaderItem)
        tokenRangeItem.target = self
        menu.addItem(tokenRangeItem)
        menu.addItem(tokenTotalItem)
        menu.addItem(tokenCompositionItem)
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

        statusItem.menu = menu
        statusItem.button?.toolTip = "CodexQuotaBar"
    }

    @objc private func refreshNow() {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        refreshItem.isEnabled = false
        stateItem.title = "Refreshing..."
        updateDetailText()
        refreshUsage()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = self?.readQuota()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                self.refreshItem.isEnabled = true
                self.apply(snapshot: snapshot)
            }
        }
    }

    private func refreshUsage() {
        guard !isUsageRefreshing else { return }
        isUsageRefreshing = true
        updateUsageItems()
        updateDetailText()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let usage = self?.readUsage()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isUsageRefreshing = false
                self.latestUsage = usage
                self.updateUsageItems()
                self.updateDetailText()
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

    private func readUsage() -> UsageSnapshot? {
        guard let helper = usageHelperURL() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper.path]
        process.environment = [
            "HOME": NSHomeDirectory(),
            "CODEX_HOME": NSHomeDirectory() + "/.codex",
            "LOGNAME": NSUserName(),
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "SHELL": "/bin/zsh",
            "TMPDIR": NSTemporaryDirectory(),
            "USER": NSUserName()
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if completed.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 1)
            }
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
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
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completed.signal()
        }

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

        if completed.wait(timeout: .now() + 15) == .timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 1)
            }
            return unavailableSnapshot(error: "Refresh timed out.")
        }
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

        guard let snapshot else {
            stateItem.title = "Unavailable"
            applyDisplayedSnapshot(lastValidSnapshot)
            updateDetailText()
            return
        }

        if snapshot.ok {
            stateItem.title = "Live quota"
            operationError = nil
            lastValidSnapshot = snapshot
            historyStore.record(snapshot: snapshot)
            retryTimer?.invalidate()
            retryTimer = nil
            applyDisplayedSnapshot(snapshot)
            updateTrendItems()
        } else {
            stateItem.title = "Quota unavailable"
            applyDisplayedSnapshot(lastValidSnapshot)
            scheduleRetryIfNeeded()
        }
        updateDetailText()
    }

    private func applyDisplayedSnapshot(_ snapshot: QuotaSnapshot?) {
        updateButton(snapshot: snapshot, loading: snapshot == nil && latestSnapshot == nil)
        floatingView?.snapshot = snapshot
        fiveHourItem.title = "5h: \(percentText(snapshot?.fiveHourLeft))"
        sevenDayItem.title = "7d: \(percentText(snapshot?.sevenDayLeft))"
        resetItem.title = "Reset: 5h \(shortTime(snapshot?.fiveHourReset)) / 7d \(shortTime(snapshot?.sevenDayReset))"
        updatedItem.title = "Last refresh: \(shortTime(snapshot?.updatedAt))"
    }

    private func updateTrendItems() {
        let trends = historyStore.trends()
        fiveHourTrendItem.title = "5h: \(rateText(trends.fiveHour.currentRate, unit: "h")) \(comparisonText(current: trends.fiveHour.currentRate, previous: trends.fiveHour.previousRate))"
        sevenDayTrendItem.title = "7d: \(rateText(trends.sevenDay.currentRate, unit: "day")) \(comparisonText(current: trends.sevenDay.currentRate, previous: trends.sevenDay.previousRate))"
        projectedItem.title = trends.projection
    }

    private var selectedUsageRange: String {
        let value = preferences.usageRange ?? "7d"
        return ["today", "7d", "30d", "month", "all"].contains(value) ? value : "7d"
    }

    private func updateUsageItems() {
        let label = usageRangeLabel(selectedUsageRange)
        tokenRangeItem.title = "Period: \(label)"
        guard let usage = latestUsage, usage.ok, let summary = usage.ranges[selectedUsageRange] else {
            tokenTotalItem.title = isUsageRefreshing ? "Token: Scanning local records..." : "Token: --"
            tokenCompositionItem.title = "Input -- · Cached -- · Output --"
            return
        }
        tokenTotalItem.title = "Token: \(formatTokens(summary.totalTokens))"
        tokenCompositionItem.title = "Input \(formatTokens(summary.inputTokens)) · Cached \(formatTokens(summary.cachedInputTokens)) · Output \(formatTokens(summary.outputTokens))"
    }

    @objc private func cycleUsageRange() {
        let ranges = ["today", "7d", "30d", "month", "all"]
        let current = ranges.firstIndex(of: selectedUsageRange) ?? 1
        preferences.usageRange = ranges[(current + 1) % ranges.count]
        preferences.save()
        updateUsageItems()
        updateDetailText()
    }

    private func usageRangeLabel(_ value: String) -> String {
        switch value {
        case "today": return "Today"
        case "30d": return "30 days"
        case "month": return "This month"
        case "all": return "All"
        default: return "7 days"
        }
    }

    private func formatTokens(_ value: Int64) -> String {
        let number = Double(value)
        if number >= 1_000_000_000 { return String(format: "%.2fB", number / 1_000_000_000) }
        if number >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
        if number >= 1_000 { return String(format: "%.1fK", number / 1_000) }
        return "\(value)"
    }

    private func scheduleRetryIfNeeded() {
        guard retryTimer == nil else {
            return
        }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.retryTimer = nil
            self?.refreshNow()
        }
    }

    private func updateButton(snapshot: QuotaSnapshot?, loading: Bool) {
        let fiveHour = snapshot?.fiveHourLeft
        let sevenDay = snapshot?.sevenDayLeft
        let ok = snapshot?.ok ?? false
        statusItem.button?.toolTip = detailText()
        guard fiveHour != lastRenderedFiveHour || sevenDay != lastRenderedSevenDay || loading != lastRenderedLoading || ok != lastRenderedOK else {
            return
        }
        let image = renderStatusImage(fiveHour: fiveHour, sevenDay: sevenDay, loading: loading, ok: ok)
        statusItem.length = image.size.width
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageOnly
        lastRenderedFiveHour = fiveHour
        lastRenderedSevenDay = sevenDay
        lastRenderedLoading = loading
        lastRenderedOK = ok
    }

    private func renderStatusImage(fiveHour: Int?, sevenDay: Int?, loading: Bool, ok: Bool) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = NSSize(width: 84, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        NSColor.clear.setFill()
        rect.fill()

        drawRow(label: "5h", percent: fiveHour, y: 13.0, loading: loading, ok: ok)
        drawRow(label: "7d", percent: sevenDay, y: 2.5, loading: loading, ok: ok)

        image.unlockFocus()
        image.isTemplate = false
        image.size = NSSize(width: floor(size.width / scale * scale), height: size.height)
        return image
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
            let x = CGFloat(21 + index * 7)
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
        NSString(string: percentText(percent)).draw(at: NSPoint(x: 60, y: y), withAttributes: percentAttributes)
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
        let displayed = snapshot?.ok == true ? snapshot : lastValidSnapshot
        return [
            "5h: \(percentText(displayed?.fiveHourLeft)) · reset \(shortDateTime(displayed?.fiveHourReset))",
            "7d: \(percentText(displayed?.sevenDayLeft)) · reset \(shortDateTime(displayed?.sevenDayReset))"
        ].joined(separator: "\n")
    }

    private func detailText() -> String {
        statusToolTip(snapshot: latestSnapshot)
    }

    private func updateDetailText() {
        let text = detailText()
        statusItem.button?.toolTip = text
        floatingView?.detailText = text
    }

    private func unavailableSnapshot(error: String) -> QuotaSnapshot {
        QuotaSnapshot(
            ok: false,
            updatedAt: isoNow(),
            source: "unavailable",
            error: error,
            plan: nil,
            currentQuotaLeft: nil,
            currentQuotaReset: nil,
            fiveHourLeft: nil,
            sevenDayLeft: nil,
            fiveHourReset: nil,
            sevenDayReset: nil
        )
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
            panel.isMovableByWindowBackground = false
            panel.acceptsMouseMovedEvents = true
            panel.delegate = self

            let view = FloatingBallView(frame: NSRect(origin: .zero, size: size))
            view.onTogglePinnedDetail = { [weak view] in
                view?.togglePinnedDetail()
            }
            view.snapshot = latestSnapshot
            view.detailText = detailText()
            panel.contentView = view

            floatingPanel = panel
            floatingView = view
        }

        floatingPanel?.makeKeyAndOrderFront(nil)
        floatingBallItem.title = "Hide Floating Ball"
    }

    private func installDetailDismissMonitors() {
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.floatingPanel {
                self.floatingView?.dismissPinnedDetail()
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.floatingView?.dismissPinnedDetail()
        }
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
            operationError = "Open at Login failed: \(error.localizedDescription)"
            stateItem.title = "Open at Login unavailable"
            updateDetailText()
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
        alert.informativeText = "This moves quota history, the local Token index, and UI preferences to Trash. It does not touch ChatGPT, Codex CLI, ~/.codex, prompts, or projects."
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
            updateTrendItems()
            updateUsageItems()
            operationError = nil
            stateItem.title = "Local CodexQuotaBar data moved to Trash."
            updateDetailText()
        } catch {
            operationError = "Could not clear local data: \(error.localizedDescription)"
            stateItem.title = "Could not clear local data"
            updateDetailText()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

final class FloatingBallView: NSView {
    var onTogglePinnedDetail: (() -> Void)?
    private var hoverPanel: NSPanel?
    private var hoverView: HoverInfoView?
    private var detailPinned = false
    private var pointerInside = false

    var snapshot: QuotaSnapshot? {
        didSet {
            if oldValue?.fiveHourLeft != snapshot?.fiveHourLeft
                || oldValue?.sevenDayLeft != snapshot?.sevenDayLeft
                || oldValue?.ok != snapshot?.ok {
                needsDisplay = true
            }
        }
    }

    var detailText = "5h: -- · reset --\n7d: -- · reset --" {
        didSet {
            toolTip = detailText
            if hoverPanel?.isVisible == true, oldValue != detailText {
                showHoverPanel()
            }
        }
    }

    override var mouseDownCanMoveWindow: Bool {
        false
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
        pointerInside = true
        showHoverPanel()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        if !detailPinned {
            hideHoverPanel()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = window.frame.origin
        window.performDrag(with: event)
        let end = window.frame.origin
        if hypot(end.x - start.x, end.y - start.y) < 3 {
            onTogglePinnedDetail?()
        }
    }

    func togglePinnedDetail() {
        detailPinned.toggle()
        if detailPinned {
            showHoverPanel()
        } else {
            hideHoverPanel()
        }
    }

    func dismissPinnedDetail() {
        guard detailPinned else { return }
        detailPinned = false
        if !pointerInside {
            hideHoverPanel()
        }
    }

    private func showHoverPanel() {
        guard let window, !detailText.isEmpty else {
            return
        }

        let size = HoverInfoView.size(for: detailText)
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        var origin = NSPoint(x: window.frame.maxX + 8, y: window.frame.maxY - size.height)
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
        let frame = NSRect(origin: origin, size: size)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        let contentView = hoverView ?? HoverInfoView(frame: NSRect(origin: .zero, size: size), text: detailText)
        contentView.frame = NSRect(origin: .zero, size: size)
        contentView.update(text: detailText)
        if panel.contentView !== contentView {
            panel.contentView = contentView
        }
        hoverPanel = panel
        hoverView = contentView
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

        let fiveHour = snapshot?.fiveHourLeft
        let sevenDay = snapshot?.sevenDayLeft
        drawRing(in: bounds.insetBy(dx: 7, dy: 7), percent: fiveHour, color: color(for: fiveHour), width: 4.5)
        drawRing(in: bounds.insetBy(dx: 16, dy: 16), percent: sevenDay, color: color(for: sevenDay), width: 3.2)
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

}

final class HoverInfoView: NSView {
    private static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 10
    private static let lineHeight: CGFloat = 18
    private static let maximumTextWidth: CGFloat = 280

    private var text: String

    init(frame frameRect: NSRect, text: String) {
        self.text = text
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(text: String) {
        guard self.text != text else { return }
        self.text = text
        needsDisplay = true
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
        paragraph.lineBreakMode = .byCharWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        NSString(string: text).draw(in: bounds.insetBy(dx: Self.horizontalPadding, dy: Self.verticalPadding), withAttributes: attributes)
    }

    static func size(for text: String) -> NSSize {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Self.lineHeight
        paragraph.maximumLineHeight = Self.lineHeight
        paragraph.lineBreakMode = .byCharWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .paragraphStyle: paragraph
        ]
        let textSize = NSString(string: text).boundingRect(
            with: NSSize(width: Self.maximumTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        ).size
        return NSSize(
            width: max(174, min(Self.maximumTextWidth, ceil(textSize.width)) + Self.horizontalPadding * 2),
            height: ceil(textSize.height) + Self.verticalPadding * 2
        )
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
