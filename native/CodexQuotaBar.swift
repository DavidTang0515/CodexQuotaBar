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

final class MenuQuotaRowView: NSView {
    static let menuWidth: CGFloat = 300
    static let menuHeight: CGFloat = 24

    private let period: String
    private let periodLabel: NSTextField
    private let valueLabel = NSTextField(labelWithString: "--%")
    private let resetLabel = NSTextField(labelWithString: "reset --")

    init(period: String) {
        self.period = period
        periodLabel = NSTextField(labelWithString: period)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.menuWidth, height: Self.menuHeight))

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(period) quota")
        setAccessibilityValue("Unknown, reset --")

        periodLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        resetLabel.font = NSFont.systemFont(ofSize: 11)
        resetLabel.alignment = .left
        resetLabel.lineBreakMode = .byTruncatingTail
        resetLabel.maximumNumberOfLines = 1
        resetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        resetLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for field in [periodLabel, valueLabel, resetLabel] {
            field.isBordered = false
            field.drawsBackground = false
            field.isEditable = false
            field.isSelectable = false
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }

        NSLayoutConstraint.activate([
            periodLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            periodLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            periodLabel.widthAnchor.constraint(equalToConstant: 28),
            valueLabel.leadingAnchor.constraint(equalTo: periodLabel.trailingAnchor, constant: 7),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 54),
            resetLabel.leadingAnchor.constraint(equalTo: valueLabel.trailingAnchor, constant: 8),
            resetLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            resetLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.menuWidth, height: Self.menuHeight)
    }

    func update(remaining: Int?, reset: String?) {
        let resetText = reset ?? "--"
        guard let remaining else {
            valueLabel.stringValue = "--%"
            valueLabel.textColor = NSColor(calibratedRed: 0.55, green: 0.69, blue: 0.79, alpha: 0.75)
            resetLabel.stringValue = "reset \(resetText)"
            resetLabel.textColor = .secondaryLabelColor
            setAccessibilityValue("\(period) quota unknown, reset \(resetText)")
            return
        }

        let clamped = max(0, min(100, remaining))
        valueLabel.stringValue = "\(clamped)%"
        valueLabel.textColor = MenuQuotaRowView.color(for: clamped)
        resetLabel.stringValue = "reset \(resetText)"
        resetLabel.textColor = .secondaryLabelColor
        setAccessibilityValue("\(period) quota \(clamped) percent, reset \(resetText)")
    }

    private static func color(for percent: Int) -> NSColor {
        if percent > 60 {
            return NSColor(calibratedRed: 0.28, green: 0.78, blue: 0.48, alpha: 1.0)
        }
        if percent >= 20 {
            return NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.28, alpha: 1.0)
        }
        return NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.40, alpha: 1.0)
    }
}

final class MenuPeriodControlView: NSView {
    private static let menuWidth: CGFloat = 320
    private static let menuHeight: CGFloat = 24

    private let button: NSButton
    private let shortcutLabel = NSTextField(labelWithString: "⌘T")
    var onCycle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        button = NSButton(title: "Period: 7 days", target: nil, action: nil)
        super.init(frame: frameRect)

        button.target = self
        button.action = #selector(cycle)
        button.bezelStyle = .inline
        button.alignment = .left
        button.keyEquivalent = "t"
        button.keyEquivalentModifierMask = [.command]
        button.setAccessibilityElement(true)
        button.setAccessibilityLabel("Usage period")
        button.setAccessibilityHelp("Cycle Today, 7 days, 30 days, This month, and All")
        button.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = NSFont.systemFont(ofSize: 11)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.alignment = .right
        shortcutLabel.isBordered = false
        shortcutLabel.drawsBackground = false
        shortcutLabel.isEditable = false
        shortcutLabel.isSelectable = false
        shortcutLabel.setAccessibilityElement(false)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        addSubview(shortcutLabel)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: shortcutLabel.leadingAnchor, constant: -8),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.widthAnchor.constraint(equalToConstant: 32)
        ])
    }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: Self.menuWidth, height: Self.menuHeight))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.menuWidth, height: Self.menuHeight)
    }

    func update(title: String) {
        button.title = title
    }

    @objc private func cycle() {
        onCycle?()
    }
}

final class MenuDetailRowView: NSView {
    static let menuWidth: CGFloat = 320
    static let menuHeight: CGFloat = 22

    private let label: NSTextField

    init(text: String = "") {
        label = NSTextField(labelWithString: text)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.menuWidth, height: Self.menuHeight))

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Usage detail")
        setAccessibilityValue(text)

        label.font = NSFont.systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.isBordered = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.menuWidth, height: Self.menuHeight)
    }

    func update(text: String) {
        label.stringValue = text
        setAccessibilityValue(text)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let usageMenu = NSMenu()
    private let settingsMenu = NSMenu()
    private let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
    private let floatingBallItem = NSMenuItem(title: "Show Floating Ball", action: #selector(toggleFloatingBall), keyEquivalent: "b")
    private let openAtLoginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "l")
    private let fiveHourRow = MenuQuotaRowView(period: "5h")
    private let sevenDayRow = MenuQuotaRowView(period: "7d")
    private lazy var fiveHourItem: NSMenuItem = {
        let item = NSMenuItem()
        item.view = fiveHourRow
        return item
    }()
    private lazy var sevenDayItem: NSMenuItem = {
        let item = NSMenuItem()
        item.view = sevenDayRow
        return item
    }()
    private let trendHeaderItem = NSMenuItem(title: "Usage trend", action: nil, keyEquivalent: "")
    private let fiveHourTrendItem = NSMenuItem(title: "5h current rate: --", action: nil, keyEquivalent: "")
    private let sevenDayTrendItem = NSMenuItem(title: "7d current rate: --", action: nil, keyEquivalent: "")
    private let projectedItem = NSMenuItem(title: "Projected 5h: --", action: nil, keyEquivalent: "")
    private let periodControlView = MenuPeriodControlView()
    private lazy var tokenRangeItem: NSMenuItem = {
        let item = NSMenuItem(title: "Period", action: nil, keyEquivalent: "")
        item.view = periodControlView
        return item
    }()
    private let tokenTotalItem = NSMenuItem(title: "Token: --", action: nil, keyEquivalent: "")
    private let inputTokenItem = NSMenuItem(title: "Input --", action: nil, keyEquivalent: "")
    private let cachedTokenItem = NSMenuItem(title: "Cached --", action: nil, keyEquivalent: "")
    private let outputTokenItem = NSMenuItem(title: "Output --", action: nil, keyEquivalent: "")
    private let tokenTotalView = MenuDetailRowView()
    private let inputTokenView = MenuDetailRowView()
    private let cachedTokenView = MenuDetailRowView()
    private let outputTokenView = MenuDetailRowView()
    private let fiveHourTrendView = MenuDetailRowView()
    private let sevenDayTrendView = MenuDetailRowView()
    private let projectedView = MenuDetailRowView()
    private let usageStatisticsItem = NSMenuItem(title: "Usage statistics", action: nil, keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
    private let clearLocalDataItem = NSMenuItem(title: "Clear Local Data...", action: #selector(clearLocalData), keyEquivalent: "")
    private let stateItem = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
    private lazy var openChatGPTItem = NSMenuItem(title: "Open Codex", action: #selector(openChatGPT), keyEquivalent: "o")
    private lazy var quitItem = NSMenuItem(title: "Quit CodexQuotaBar", action: #selector(quit), keyEquivalent: "q")
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
        usageStatisticsItem.submenu = usageMenu
        settingsItem.submenu = settingsMenu
        menu.minimumWidth = MenuQuotaRowView.menuWidth
        usageMenu.minimumWidth = MenuDetailRowView.menuWidth
        settingsMenu.minimumWidth = 220

        tokenTotalItem.view = tokenTotalView
        inputTokenItem.view = inputTokenView
        cachedTokenItem.view = cachedTokenView
        outputTokenItem.view = outputTokenView
        fiveHourTrendItem.view = fiveHourTrendView
        sevenDayTrendItem.view = sevenDayTrendView
        projectedItem.view = projectedView

        menu.addItem(fiveHourItem)
        menu.addItem(sevenDayItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(refreshItem)
        menu.addItem(usageStatisticsItem)
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        quitItem.target = self
        menu.addItem(quitItem)

        fiveHourItem.title = "5h quota"
        fiveHourItem.setAccessibilityLabel("5-hour quota")
        sevenDayItem.title = "7d quota"
        sevenDayItem.setAccessibilityLabel("7-day quota")

        periodControlView.onCycle = { [weak self] in
            self?.cycleUsageRange()
        }
        usageMenu.addItem(tokenRangeItem)
        usageMenu.addItem(tokenTotalItem)
        usageMenu.addItem(inputTokenItem)
        usageMenu.addItem(cachedTokenItem)
        usageMenu.addItem(outputTokenItem)
        usageMenu.addItem(NSMenuItem.separator())
        usageMenu.addItem(trendHeaderItem)
        usageMenu.addItem(fiveHourTrendItem)
        usageMenu.addItem(sevenDayTrendItem)
        usageMenu.addItem(projectedItem)

        floatingBallItem.target = self
        settingsMenu.addItem(floatingBallItem)
        openChatGPTItem.target = self
        settingsMenu.addItem(openChatGPTItem)
        openAtLoginItem.target = self
        updateOpenAtLoginMenuItem()
        settingsMenu.addItem(openAtLoginItem)
        settingsMenu.addItem(NSMenuItem.separator())
        clearLocalDataItem.target = self
        settingsMenu.addItem(clearLocalDataItem)

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
        fiveHourRow.update(remaining: snapshot?.fiveHourLeft, reset: shortDateTime(snapshot?.fiveHourReset))
        sevenDayRow.update(remaining: snapshot?.sevenDayLeft, reset: shortDateTime(snapshot?.sevenDayReset))
    }

    private func updateTrendItems() {
        let trends = historyStore.trends()
        let fiveHourText = menuTrendText(period: "5h", metric: trends.fiveHour, unit: "h")
        let sevenDayText = menuTrendText(period: "7d", metric: trends.sevenDay, unit: "day")
        fiveHourTrendItem.title = fiveHourText
        sevenDayTrendItem.title = sevenDayText
        fiveHourTrendView.update(text: fiveHourText)
        sevenDayTrendView.update(text: sevenDayText)
        projectedItem.title = trends.projection
        projectedView.update(text: trends.projection)
        usageMenu.update()
    }

    private var selectedUsageRange: String {
        let value = preferences.usageRange ?? "7d"
        return ["today", "7d", "30d", "month", "all"].contains(value) ? value : "7d"
    }

    private func updateUsageItems() {
        let label = usageRangeLabel(selectedUsageRange)
        periodControlView.update(title: "Period: \(label)")
        guard let usage = latestUsage, usage.ok, let summary = usage.ranges[selectedUsageRange] else {
            let tokenText = isUsageRefreshing ? "Token: Scanning local records..." : "Token --"
            tokenTotalItem.title = tokenText
            inputTokenItem.title = "Input --"
            cachedTokenItem.title = "Cached --"
            outputTokenItem.title = "Output --"
            tokenTotalView.update(text: tokenText)
            inputTokenView.update(text: "Input --")
            cachedTokenView.update(text: "Cached --")
            outputTokenView.update(text: "Output --")
            usageMenu.update()
            return
        }
        let tokenText = "Token \(formatTokens(summary.totalTokens))"
        let inputText = "Input \(formatTokens(summary.inputTokens))"
        let cachedText = "Cached \(formatTokens(summary.cachedInputTokens))"
        let outputText = "Output \(formatTokens(summary.outputTokens))"
        tokenTotalItem.title = tokenText
        inputTokenItem.title = inputText
        cachedTokenItem.title = cachedText
        outputTokenItem.title = outputText
        tokenTotalView.update(text: tokenText)
        inputTokenView.update(text: inputText)
        cachedTokenView.update(text: cachedText)
        outputTokenView.update(text: outputText)
        usageMenu.update()
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

    private func menuTrendText(period: String, metric: TrendMetric, unit: String) -> String {
        "\(period) \(menuRateText(metric.currentRate, unit: unit)) · \(menuComparisonText(current: metric.currentRate, previous: metric.previousRate))"
    }

    private func menuRateText(_ value: Double?, unit: String) -> String {
        guard let value else {
            return "rate --"
        }
        return String(format: "rate -%.1f%%/%@", value, unit)
    }

    private func menuComparisonText(current: Double?, previous: Double?) -> String {
        guard let current, let previous else {
            return "prev --"
        }
        let delta = current - previous
        if abs(delta) < 0.05 {
            return "prev flat"
        }
        return String(format: "prev %@%.1f", delta > 0 ? "+" : "", delta)
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

        let bounds = self.bounds
        NSColor.clear.setFill()
        dirtyRect.fill()

        let background = NSBezierPath(ovalIn: bounds.insetBy(dx: 6, dy: 6))
        NSColor.black.withAlphaComponent(0.58).setFill()
        background.fill()

        let fiveHour = snapshot?.ok == true ? snapshot?.fiveHourLeft : nil
        let sevenDay = snapshot?.ok == true ? snapshot?.sevenDayLeft : nil
        drawRing(in: bounds.insetBy(dx: 9.25, dy: 9.25), percent: fiveHour, color: color(for: fiveHour), width: 4.5)
        drawRing(in: bounds.insetBy(dx: 14, dy: 14), percent: sevenDay, color: color(for: sevenDay), width: 3.2)
        drawCenterValue(fiveHour)
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
        if clamped == 100 {
            color.setStroke()
            let full = NSBezierPath(ovalIn: rect)
            full.lineWidth = width
            full.stroke()
            return
        }
        guard clamped > 0 else {
            return
        }
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

    private func drawCenterValue(_ percent: Int?) {
        let text = percent.map { "\(max(0, min(100, $0)))" } ?? "--"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10.0, weight: .semibold),
            .foregroundColor: percent == nil ? color(for: nil) : NSColor.white
        ]
        let textSize = NSString(string: text).size(withAttributes: attributes)
        let origin = NSPoint(
            x: bounds.midX - textSize.width / 2,
            y: bounds.midY - textSize.height / 2
        )
        NSString(string: text).draw(at: origin, withAttributes: attributes)
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
    private static let panelSize = NSSize(width: 252, height: 68)
    private static let periodFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private static let resetLabelFont = NSFont.systemFont(ofSize: 10.5)
    private static let resetValueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    private static let periodRect = NSRect(x: 13, y: 0, width: 24, height: 20)
    private static let valueRect = NSRect(x: 42, y: 0, width: 42, height: 20)
    private static let resetLabelRect = NSRect(x: 91, y: 1, width: 34, height: 18)
    private static let resetValueRect = NSRect(x: 132, y: 1, width: 107, height: 18)

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
        NSColor.white.withAlphaComponent(0.10).setStroke()
        bubble.lineWidth = 1
        bubble.stroke()

        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(2).enumerated() {
            let row = Self.parse(String(line))
            let rowY: CGFloat = index == 0 ? 35 : 10
            draw(row.period, in: Self.periodRect.offsetBy(dx: 0, dy: rowY), font: Self.periodFont, color: .white)
            draw(row.value, in: Self.valueRect.offsetBy(dx: 0, dy: rowY), font: Self.valueFont, color: Self.color(for: row.percent), alignment: .right)
            draw("reset", in: Self.resetLabelRect.offsetBy(dx: 0, dy: rowY), font: Self.resetLabelFont, color: .white.withAlphaComponent(0.70))
            draw(row.reset, in: Self.resetValueRect.offsetBy(dx: 0, dy: rowY), font: Self.resetValueFont, color: .white.withAlphaComponent(0.86))
        }
    }

    static func size(for text: String) -> NSSize {
        panelSize
    }

    private func draw(_ value: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        NSString(string: value).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func parse(_ line: String) -> (period: String, value: String, percent: Int?, reset: String) {
        let placeholder: (period: String, value: String, percent: Int?, reset: String) = (period: "--", value: "--%", percent: nil, reset: "--")
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.range(of: "·") else {
            return placeholder
        }

        let left = String(trimmed[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        let right = String(trimmed[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard let colon = left.firstIndex(of: ":") else {
            return placeholder
        }

        let period = String(left[..<colon]).trimmingCharacters(in: .whitespaces)
        guard period == "5h" || period == "7d" else {
            return placeholder
        }

        let rawValue = String(left[colon...].dropFirst()).trimmingCharacters(in: .whitespaces)
        let value: String
        let percent: Int?
        if rawValue == "--" || rawValue == "--%" {
            value = "--%"
            percent = nil
        } else {
            guard rawValue.hasSuffix("%"),
                  let parsed = Int(rawValue.dropLast()) else {
                return placeholder
            }
            let clamped = max(0, min(100, parsed))
            value = "\(clamped)%"
            percent = clamped
        }

        guard right.hasPrefix("reset") else {
            return placeholder
        }
        let reset = String(right.dropFirst("reset".count)).trimmingCharacters(in: .whitespaces)
        guard reset == "--" || reset.count <= 11 else {
            return placeholder
        }
        return (period, value, percent, reset.isEmpty ? "--" : reset)
    }

    private static func color(for percent: Int?) -> NSColor {
        guard let percent else {
            return NSColor(calibratedRed: 0.55, green: 0.69, blue: 0.79, alpha: 0.75)
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
