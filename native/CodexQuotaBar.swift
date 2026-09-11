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

func ui(_ english: String, _ chinese: String) -> String {
    (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? chinese : english
}

enum QuotaDisplay {
    static func snapshot(latest: QuotaSnapshot?, lastValid: QuotaSnapshot?) -> QuotaSnapshot? {
        latest?.ok == true ? latest : lastValid
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }

    static func updateTime(_ text: String?, now: Date = Date()) -> String? {
        guard let date = date(text) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func resetTime(_ text: String?, now: Date = Date()) -> String {
        updateTime(text, now: now) ?? "--"
    }

    static func resetLabel(_ time: String) -> String {
        time == "--" ? ui("Reset unknown", "重置时间未知") : ui("reset \(time)", "\(time) 重置")
    }
}

struct RefreshRetryBudget {
    private(set) var available = true
    mutating func beginCycle() { available = true }
    mutating func consume() -> Bool {
        guard available else { return false }
        available = false
        return true
    }
}

enum MenuStatusKind: Equatable {
    case normal
    case stale
    case noData
    case operationError
}

struct MenuStatusPresentation: Equatable {
    let refreshTitle: String
    let refreshEnabled: Bool
    let statusText: String?
    let statusKind: MenuStatusKind

    static let live = MenuStatusPresentation(
        refreshTitle: ui("Refresh", "刷新"),
        refreshEnabled: true,
        statusText: nil,
        statusKind: .normal
    )

    static func refreshing(keeping previous: MenuStatusPresentation) -> MenuStatusPresentation {
        MenuStatusPresentation(
            refreshTitle: ui("Refreshing…", "正在刷新…"),
            refreshEnabled: false,
            statusText: previous.statusText,
            statusKind: previous.statusKind
        )
    }

    static func refreshFailure(lastUpdated: String?, hasData: Bool = false) -> MenuStatusPresentation {
        if let lastUpdated, isClockText(lastUpdated) {
            return MenuStatusPresentation(
                refreshTitle: ui("Retry refresh", "重新刷新"),
                refreshEnabled: true,
                statusText: ui("Last update \(lastUpdated)", "刷新失败 · 上次更新 \(lastUpdated)"),
                statusKind: .stale
            )
        }
        return MenuStatusPresentation(
            refreshTitle: ui("Retry refresh", "重新刷新"),
            refreshEnabled: true,
            statusText: hasData ? ui("Showing previous quota", "刷新失败 · 保留上次额度") : ui("No quota data", "暂时无法读取额度"),
            statusKind: hasData ? .stale : .noData
        )
    }

    private static func isClockText(_ value: String) -> Bool {
        let patterns = ["HH:mm", "MM-dd HH:mm"]
        return patterns.contains { pattern in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            formatter.isLenient = false
            guard let date = formatter.date(from: value) else { return false }
            return formatter.string(from: date) == value
        }
    }

    static let operationFailure = MenuStatusPresentation(
        refreshTitle: ui("Refresh", "刷新"),
        refreshEnabled: true,
        statusText: ui("Settings unavailable", "操作未完成"),
        statusKind: .operationError
    )
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
        if let path = ProcessInfo.processInfo.environment["CODEX_QUOTA_BAR_SUPPORT_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
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
        guard let latest = entries.last, let left = latest.fiveHourLeft else {
            return "Projected 5h: " + ui("Insufficient data", "数据不足")
        }
        if left == 0 { return "Projected 5h: " + ui("Exhausted", "额度已用尽") }
        guard let rate = currentRate, rate > 0 else {
            return "Projected 5h: " + ui("Insufficient data", "数据不足")
        }
        let hours = Double(left) / rate
        if let reset = QuotaDisplay.date(latest.fiveHourReset), reset > Date(),
           Date().addingTimeInterval(hours * 3600) >= reset {
            return "Projected 5h: " + ui("Until reset", "预计够用至重置")
        }
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
    private static let contentInset: CGFloat = 14
    private static let periodColumnWidth: CGFloat = 28
    private static let valueColumnWidth: CGFloat = 44
    private static let periodValueGap: CGFloat = 7
    private static let valueResetGap: CGFloat = 8

    private let indicator = NSView()
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

        periodLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        valueLabel.alignment = .right
        resetLabel.font = NSFont.systemFont(ofSize: 11)
        resetLabel.alignment = .right
        resetLabel.lineBreakMode = .byTruncatingTail
        resetLabel.maximumNumberOfLines = 1
        resetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        resetLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 2
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.setAccessibilityElement(false)
        addSubview(indicator)
        for field in [periodLabel, valueLabel, resetLabel] {
            field.isBordered = false
            field.drawsBackground = false
            field.isEditable = false
            field.isSelectable = false
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }

        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentInset),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 4),
            indicator.heightAnchor.constraint(equalToConstant: 4),
            periodLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentInset + 12),
            periodLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            periodLabel.widthAnchor.constraint(equalToConstant: Self.periodColumnWidth),
            valueLabel.leadingAnchor.constraint(equalTo: periodLabel.trailingAnchor, constant: Self.periodValueGap),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: Self.valueColumnWidth),
            resetLabel.leadingAnchor.constraint(equalTo: valueLabel.trailingAnchor, constant: Self.valueResetGap),
            resetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.contentInset),
            resetLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.menuWidth, height: Self.menuHeight)
    }

    func update(remaining: Int?, reset: String?, fullReset: String? = nil) {
        let resetText = reset ?? "--"
        if let date = QuotaDisplay.date(fullReset) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .long
            toolTip = QuotaDisplay.resetLabel(formatter.string(from: date))
        } else {
            toolTip = QuotaDisplay.resetLabel(resetText)
        }
        guard let remaining else {
            valueLabel.stringValue = "--%"
            valueLabel.textColor = .secondaryLabelColor
            indicator.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
            resetLabel.stringValue = QuotaDisplay.resetLabel(resetText)
            resetLabel.textColor = .secondaryLabelColor
            setAccessibilityValue("\(period) quota unknown, reset \(resetText)")
            return
        }

        let clamped = max(0, min(100, remaining))
        valueLabel.stringValue = "\(clamped)%"
        valueLabel.textColor = .labelColor
        indicator.layer?.backgroundColor = MenuQuotaRowView.color(for: clamped).cgColor
        resetLabel.stringValue = QuotaDisplay.resetLabel(resetText)
        resetLabel.textColor = .secondaryLabelColor
        setAccessibilityValue("\(period) quota \(clamped) percent, reset \(resetText)")
    }

    private static func color(for percent: Int) -> NSColor {
        if percent > 60 {
            return NSColor(calibratedRed: 0.14, green: 0.51, blue: 0.29, alpha: 1.0)
        }
        if percent >= 20 {
            return NSColor(calibratedRed: 0.72, green: 0.42, blue: 0, alpha: 1.0)
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
    static let menuHeight: CGFloat = 24
    private let label = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!

    init(text: String = "") {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.menuWidth, height: Self.menuHeight))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        for field in [label, valueLabel] {
            field.font = NSFont.systemFont(ofSize: 13)
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setAccessibilityElement(false)
            addSubview(field)
        }
        valueLabel.alignment = .right
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
        NSLayoutConstraint.activate([
            leading,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        update(text: text)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.menuWidth, height: Self.menuHeight) }
    func update(text: String) { update(label: text, value: "") }
    func update(label title: String, value: String, emphasized: Bool = false, nested: Bool = false, help: String? = nil) {
        label.stringValue = title
        valueLabel.stringValue = value
        label.font = .systemFont(ofSize: 13, weight: emphasized ? .semibold : .regular)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: emphasized ? .semibold : .regular)
        label.textColor = nested ? .secondaryLabelColor : .labelColor
        valueLabel.textColor = label.textColor
        leading.constant = nested ? 26 : 14
        toolTip = help ?? "\(title) \(value)"
        setAccessibilityLabel(title)
        setAccessibilityValue(value)
        setAccessibilityHelp(toolTip)
    }
}

final class MenuStatusRowView: NSView {
    static let menuWidth: CGFloat = MenuQuotaRowView.menuWidth
    static let menuHeight: CGFloat = 22

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.menuWidth, height: Self.menuHeight))

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Quota status")
        setAccessibilityValue("")

        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.isBordered = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.menuWidth, height: Self.menuHeight)
    }

    func update(text: String, kind: MenuStatusKind) {
        label.stringValue = text
        label.textColor = kind == .operationError ? .systemOrange : .secondaryLabelColor
        setAccessibilityValue(text)
    }
}

struct StatusItemRenderer {
    static let size = NSSize(width: 88, height: 24)

    static func image(fiveHour: Int?, sevenDay: Int?, loading: Bool, ok: Bool, appearance: NSAppearance?) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = NSImage(size: Self.size)
        image.lockFocus()

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: Self.size).fill()

        drawRow(label: "5h", percent: fiveHour, y: 13.0, loading: loading, ok: ok, appearance: appearance)
        drawRow(label: "7d", percent: sevenDay, y: 2.5, loading: loading, ok: ok, appearance: appearance)

        image.unlockFocus()
        image.isTemplate = false
        image.size = NSSize(width: floor(Self.size.width / scale * scale), height: Self.size.height)
        return image
    }

    static func appearanceKey(for appearance: NSAppearance?) -> String {
        let name = appearance?.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
        return name == .darkAqua ? "darkAqua" : "aqua"
    }

    private static func drawRow(label: String, percent: Int?, y: CGFloat, loading: Bool, ok: Bool, appearance: NSAppearance?) {
        let foreground = foregroundColor(for: appearance)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: foreground
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
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: foreground
        ]
        let text = NSString(string: percentText(percent))
        let width = text.size(withAttributes: percentAttributes).width
        text.draw(at: NSPoint(x: Self.size.width - 1 - width, y: y), withAttributes: percentAttributes)
    }

    private static func foregroundColor(for appearance: NSAppearance?) -> NSColor {
        let name = appearance?.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
        return name == .darkAqua ? .white : NSColor(calibratedWhite: 0.16, alpha: 1.0)
    }

    private static func barsFilled(_ percent: Int?) -> Int {
        guard let percent else { return 0 }
        return max(0, min(5, Int(ceil(Double(percent) / 20.0))))
    }

    private static func quotaColor(percent: Int?, loading: Bool, ok: Bool) -> NSColor {
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

    private static func percentText(_ value: Int?) -> String {
        guard let value else { return "--%" }
        return "\(max(0, min(100, value)))%"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let usageMenu = NSMenu()
    private let settingsMenu = NSMenu()
    private let refreshItem = NSMenuItem(title: ui("Refresh", "刷新"), action: #selector(refreshNow), keyEquivalent: "r")
    private let floatingBallItem = NSMenuItem(title: ui("Show Floating Ball", "显示悬浮球"), action: #selector(toggleFloatingBall), keyEquivalent: "b")
    private let openAtLoginItem = NSMenuItem(title: ui("Open at Login", "登录时启动"), action: #selector(toggleOpenAtLogin), keyEquivalent: "l")
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
    private let trendHeaderItem = NSMenuItem(title: ui("Usage trend", "额度趋势"), action: nil, keyEquivalent: "")
    private let fiveHourTrendItem = NSMenuItem(title: "5h current rate: --", action: nil, keyEquivalent: "")
    private let sevenDayTrendItem = NSMenuItem(title: "7d current rate: --", action: nil, keyEquivalent: "")
    private let projectedItem = NSMenuItem(title: "Projected 5h: --", action: nil, keyEquivalent: "")
    private let periodMenu = NSMenu()
    private let tokenRangeItem = NSMenuItem(title: "Period", action: nil, keyEquivalent: "")
    private let cyclePeriodItem = NSMenuItem(title: "Next period", action: #selector(cycleUsageRange), keyEquivalent: "t")
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
    private let usageStatisticsItem = NSMenuItem(title: ui("Usage statistics", "用量统计"), action: nil, keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: ui("Settings", "设置"), action: nil, keyEquivalent: "")
    private let clearLocalDataItem = NSMenuItem(title: ui("Clear Local Data...", "将本地数据移到废纸篓…"), action: #selector(clearLocalData), keyEquivalent: "")
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let stateView = MenuStatusRowView()
    private lazy var openChatGPTItem = NSMenuItem(title: ui("Open Codex", "打开 Codex"), action: #selector(openChatGPT), keyEquivalent: "o")
    private lazy var quitItem = NSMenuItem(title: ui("Quit CodexQuotaBar", "退出 CodexQuotaBar"), action: #selector(quit), keyEquivalent: "q")
    private let historyStore = QuotaHistoryStore()
    private var timer: Timer?
    private var retryTimer: Timer?
    private var retryBudget = RefreshRetryBudget()
    private var isClearingData = false
    private var isRefreshing = false
    private var isUsageRefreshing = false
    private var usageRefreshFailed = false
    private var latestSnapshot: QuotaSnapshot?
    private var latestUsage: UsageSnapshot?
    private var lastValidSnapshot: QuotaSnapshot?
    private var statusPresentation = MenuStatusPresentation.live
    private var lastRenderedFiveHour: Int?
    private var lastRenderedSevenDay: Int?
    private var lastRenderedLoading = false
    private var lastRenderedOK = false
    private var lastRenderedAppearanceKey: String?
    private var appearanceObservation: NSKeyValueObservation?
    private var floatingPanel: NSPanel?
    private var floatingView: FloatingBallView?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var preferences = AppPreferences.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        observeStatusItemAppearance()
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
        appearanceObservation?.invalidate()
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
    }

    private func observeStatusItemAppearance() {
        guard let button = statusItem.button else { return }
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            self.lastRenderedAppearanceKey = nil
            self.updateButton(snapshot: QuotaDisplay.snapshot(latest: self.latestSnapshot, lastValid: self.lastValidSnapshot), loading: self.isRefreshing && self.lastValidSnapshot == nil)
        }
    }

    private func configureMenu() {
        refreshItem.target = self
        menu.autoenablesItems = false
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
        stateItem.view = stateView
        stateItem.isHidden = true

        menu.addItem(fiveHourItem)
        menu.addItem(sevenDayItem)
        menu.addItem(stateItem)
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

        tokenRangeItem.submenu = periodMenu
        for range in ["today", "7d", "30d", "month", "all"] {
            let item = NSMenuItem(title: usageRangeLabel(range), action: #selector(selectUsageRange(_:)), keyEquivalent: "")
            item.representedObject = range
            item.target = self
            periodMenu.addItem(item)
        }
        periodMenu.addItem(.separator())
        cyclePeriodItem.title = ui("Next period", "下一个周期")
        cyclePeriodItem.target = self
        periodMenu.addItem(cyclePeriodItem)
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

    private func applyStatusPresentation() {
        refreshItem.title = statusPresentation.refreshTitle
        refreshItem.isEnabled = statusPresentation.refreshEnabled
        stateItem.isHidden = statusPresentation.statusText == nil
        if let statusText = statusPresentation.statusText {
            stateView.update(text: statusText, kind: statusPresentation.statusKind)
        }
        menu.update()
    }

    @objc private func refreshNow() {
        startRefresh(isRetry: false)
    }

    private func startRefresh(isRetry: Bool) {
        guard !isRefreshing && !isClearingData else {
            return
        }
        if !isRetry { retryBudget.beginCycle() }
        retryTimer?.invalidate()
        retryTimer = nil
        isRefreshing = true
        statusPresentation = .refreshing(keeping: statusPresentation)
        applyStatusPresentation()
        updateDetailText()
        refreshUsage()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = self?.readQuota()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                self.apply(snapshot: snapshot)
            }
        }
    }

    private func refreshUsage() {
        guard !isUsageRefreshing && !isClearingData else { return }
        isUsageRefreshing = true
        updateUsageItems()
        updateDetailText()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let usage = self?.readUsage()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isUsageRefreshing = false
                self.usageRefreshFailed = usage?.ok != true
                if usage?.ok == true || self.latestUsage == nil { self.latestUsage = usage }
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
        if let support = ProcessInfo.processInfo.environment["CODEX_QUOTA_BAR_SUPPORT_DIR"] {
            process.environment?["CODEX_QUOTA_BAR_SUPPORT_DIR"] = support
        }
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

        if let support = ProcessInfo.processInfo.environment["CODEX_QUOTA_BAR_SUPPORT_DIR"] {
            process.environment?["CODEX_QUOTA_BAR_SUPPORT_DIR"] = support
        }
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
            statusPresentation = .refreshFailure(lastUpdated: lastValidUpdateText(), hasData: lastValidSnapshot != nil)
            applyStatusPresentation()
            applyDisplayedSnapshot(lastValidSnapshot)
            scheduleRetryIfNeeded()
            updateDetailText()
            return
        }

        if snapshot.ok {
            statusPresentation = .live
            applyStatusPresentation()
            lastValidSnapshot = snapshot
            historyStore.record(snapshot: snapshot)
            retryTimer?.invalidate()
            retryTimer = nil
            applyDisplayedSnapshot(snapshot)
            updateTrendItems()
        } else {
            statusPresentation = .refreshFailure(lastUpdated: lastValidUpdateText(), hasData: lastValidSnapshot != nil)
            applyStatusPresentation()
            applyDisplayedSnapshot(lastValidSnapshot)
            scheduleRetryIfNeeded()
        }
        updateDetailText()
    }

    private func applyDisplayedSnapshot(_ snapshot: QuotaSnapshot?) {
        updateButton(snapshot: snapshot, loading: snapshot == nil && latestSnapshot == nil)
        floatingView?.snapshot = snapshot
        fiveHourRow.update(remaining: snapshot?.fiveHourLeft, reset: shortDateTime(snapshot?.fiveHourReset), fullReset: snapshot?.fiveHourReset)
        sevenDayRow.update(remaining: snapshot?.sevenDayLeft, reset: shortDateTime(snapshot?.sevenDayReset), fullReset: snapshot?.sevenDayReset)
    }

    private func updateTrendItems() {
        let trends = historyStore.trends()
        fiveHourTrendView.update(label: ui("5h consumption", "5h 消耗"), value: menuRateText(trends.fiveHour.currentRate, unit: "h"),
                                 help: menuTrendText(period: "5h", metric: trends.fiveHour, unit: "h"))
        sevenDayTrendView.update(label: ui("7d consumption", "7d 消耗"), value: menuRateText(trends.sevenDay.currentRate, unit: "day"),
                                help: menuTrendText(period: "7d", metric: trends.sevenDay, unit: "day"))
        projectedView.update(label: ui("5h estimate", "5h 预计可用"), value: trends.projection.replacingOccurrences(of: "Projected 5h: ", with: ""),
                             help: ui("Estimated from recent quota consumption; not Token usage.", "根据近期额度消耗速率估计，并非 Token 用量。"))
        usageMenu.update()
    }

    private var selectedUsageRange: String {
        let value = preferences.usageRange ?? "7d"
        return ["today", "7d", "30d", "month", "all"].contains(value) ? value : "7d"
    }

    private func updateUsageItems() {
        let label = usageRangeLabel(selectedUsageRange)
        tokenRangeItem.title = ui("Period: \(label)", "统计周期：\(label)")
        for item in periodMenu.items {
            item.state = (item.representedObject as? String) == selectedUsageRange ? .on : .off
        }
        let summary = latestUsage?.ok == true ? latestUsage?.ranges[selectedUsageRange] : nil
        let total = summary.map { formatTokens($0.totalTokens) } ?? "--"
        let scanning = isUsageRefreshing ? ui("Updating local statistics…", "正在更新本地统计…") : nil
        tokenTotalView.update(label: ui("Local Token", "本地 Token"), value: total, emphasized: true,
                              help: scanning ?? summary.map { "\($0.totalTokens) Token" })
        inputTokenView.update(label: ui("Input", "输入"), value: summary.map { formatTokens($0.inputTokens) } ?? "--",
                             help: summary.map { "\($0.inputTokens)" })
        cachedTokenView.update(label: ui("Of which cached", "其中缓存"), value: summary.map { formatTokens($0.cachedInputTokens) } ?? "--", nested: true,
                              help: summary.map { ui("Included in input: \($0.cachedInputTokens)", "包含在输入中：\($0.cachedInputTokens)") })
        outputTokenView.update(label: ui("Output", "输出"), value: summary.map { formatTokens($0.outputTokens) } ?? "--",
                              help: summary.map { "\($0.outputTokens)" })
        tokenTotalItem.title = scanning ?? ui("Local Token \(total)", "本地 Token \(total)")
        if usageRefreshFailed && !isUsageRefreshing {
            let previous = QuotaDisplay.updateTime(latestUsage?.updatedAt) ?? "--"
            tokenTotalView.update(label: ui("Local Token · saved", "本地 Token · 上次数据"), value: total, emphasized: true,
                                  help: ui("Update failed. Last update: \(previous)", "更新失败，上次更新：\(previous)"))
        }
        if isUsageRefreshing {
            tokenTotalView.update(label: ui("Local Token · updating", "本地 Token · 更新中"), value: total, emphasized: true, help: scanning)
        }
        usageMenu.update()
    }

    @objc private func selectUsageRange(_ sender: NSMenuItem) {
        guard let range = sender.representedObject as? String,
              ["today", "7d", "30d", "month", "all"].contains(range) else { return }
        preferences.usageRange = range
        preferences.save()
        updateUsageItems()
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
        case "today": return ui("Today", "今天")
        case "30d": return ui("30 days", "最近 30 天")
        case "month": return ui("This month", "本月")
        case "all": return ui("All", "全部记录")
        default: return ui("7 days", "最近 7 天")
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
            return "--"
        }
        return String(format: ui("%.1f pp/%@", "%.1f 百分点/%@"), value, unit == "h" ? ui("h", "小时") : ui("day", "天"))
    }

    private func menuComparisonText(current: Double?, previous: Double?) -> String {
        guard let current, let previous else {
            return ui("Previous period: insufficient data", "上期：数据不足")
        }
        let delta = current - previous
        if abs(delta) < 0.05 {
            return ui("Unchanged from previous period", "与上期持平")
        }
        return String(format: ui("vs previous: %@%.1f pp", "较上期：%@%.1f 个百分点"), delta > 0 ? "+" : "", delta)
    }

    private func scheduleRetryIfNeeded() {
        guard retryTimer == nil, retryBudget.consume() else {
            return
        }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.retryTimer = nil
            self?.startRefresh(isRetry: true)
        }
    }

    private func updateButton(snapshot: QuotaSnapshot?, loading: Bool) {
        let fiveHour = snapshot?.fiveHourLeft
        let sevenDay = snapshot?.sevenDayLeft
        let ok = snapshot?.ok ?? false
        let appearance = statusItem.button?.effectiveAppearance
        let appearanceKey = StatusItemRenderer.appearanceKey(for: appearance)
        statusItem.button?.toolTip = detailText()
        guard fiveHour != lastRenderedFiveHour
                || sevenDay != lastRenderedSevenDay
                || loading != lastRenderedLoading
                || ok != lastRenderedOK
                || appearanceKey != lastRenderedAppearanceKey else {
            return
        }
        let image = StatusItemRenderer.image(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            loading: loading,
            ok: ok,
            appearance: appearance
        )
        statusItem.length = image.size.width
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageOnly
        lastRenderedFiveHour = fiveHour
        lastRenderedSevenDay = sevenDay
        lastRenderedLoading = loading
        lastRenderedOK = ok
        lastRenderedAppearanceKey = appearanceKey
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

    private func lastValidUpdateText() -> String? {
        QuotaDisplay.updateTime(lastValidSnapshot?.updatedAt)
    }

    private func shortDateTime(_ value: String?) -> String {
        QuotaDisplay.resetTime(value)
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
        floatingView?.statusText = statusPresentation.statusText
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

        statusPresentation = .operationFailure
        applyStatusPresentation()
    }

    @objc private func toggleFloatingBall() {
        if let floatingPanel, floatingPanel.isVisible {
            floatingView?.closeDetail()
            floatingPanel.orderOut(nil)
            preferences.showFloatingBall = false
            preferences.save()
            floatingBallItem.title = ui("Show Floating Ball", "显示悬浮球")
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
            view.snapshot = QuotaDisplay.snapshot(latest: latestSnapshot, lastValid: lastValidSnapshot)
            view.detailText = detailText()
            panel.contentView = view

            floatingPanel = panel
            floatingView = view
        }

        floatingPanel?.makeKeyAndOrderFront(nil)
        floatingBallItem.title = ui("Hide Floating Ball", "隐藏悬浮球")
    }

    private func installDetailDismissMonitors() {
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53, self.floatingView?.detailIsVisible == true {
                    self.floatingView?.dismissPinnedDetail(force: true)
                    return nil
                }
                return event
            }
            if event.window !== self.floatingPanel && self.floatingView?.ownsDetailWindow(event.window) != true {
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
            statusPresentation = .operationFailure
            applyStatusPresentation()
        }
    }

    private func updateOpenAtLoginMenuItem() {
        let enabled = SMAppService.mainApp.status == .enabled
        openAtLoginItem.state = enabled ? .on : .off
        openAtLoginItem.title = ui("Open at Login", "登录时启动")
    }

    @objc private func clearLocalData() {
        guard !isRefreshing && !isUsageRefreshing else {
            let alert = NSAlert()
            alert.messageText = ui("Wait for refresh to finish", "请等待刷新完成")
            alert.runModal()
            return
        }
        isClearingData = true
        defer { isClearingData = false }
        let alert = NSAlert()
        alert.messageText = ui("Move local data to Trash?", "将本地数据移到废纸篓？")
        alert.informativeText = ui("Moves only the app's quota history, Token index and preferences to Trash. Recoverable from Trash. Codex data and projects are untouched.", "仅将本工具的额度历史、Token 索引和偏好移到废纸篓，可从废纸篓恢复。不会处理 Codex 数据或项目。")
        alert.alertStyle = .warning
        alert.informativeText += "\n\n" + AppPreferences.supportDirectory().path
        alert.addButton(withTitle: ui("Cancel", "取消"))
        alert.addButton(withTitle: ui("Move to Trash", "移到废纸篓"))

        guard alert.runModal() == .alertSecondButtonReturn else {
            return
        }

        do {
            try QuotaHistoryStore.moveLocalDataToTrash()
            preferences = AppPreferences()
            latestUsage = nil
            updateTrendItems()
            updateUsageItems()
            statusPresentation = .live
            applyStatusPresentation()
        } catch {
            statusPresentation = .operationFailure
            applyStatusPresentation()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

final class QuotaDetailPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class FloatingBallView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(ui("Codex quota details", "Codex 额度详情"))
        setAccessibilityHelp(ui("Press to pin details. Drag to move.", "点击固定详情，拖动移动。"))
    }
    required init?(coder: NSCoder) { nil }
    override func accessibilityPerformPress() -> Bool {
        togglePinnedDetail()
        return true
    }

    private static let graphiteBallColor = NSColor(
        calibratedRed: 36.0 / 255.0,
        green: 38.0 / 255.0,
        blue: 43.0 / 255.0,
        alpha: 0.90
    )

    private static let ringTrackColor = NSColor.white.withAlphaComponent(0.11)

    // Fixed identity color for the 7-day ring; it communicates the period, not quota state.
    private static let sevenDayRingColor = NSColor(
        calibratedRed: 184.0 / 255.0,
        green: 192.0 / 255.0,
        blue: 200.0 / 255.0,
        alpha: 0.94
    )

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

    private var pendingShow: DispatchWorkItem?
    private var pendingHide: DispatchWorkItem?
    private var pointerInDetail = false
    private var visibilityGeneration = 0
    var detailIsVisible: Bool { hoverPanel?.isVisible == true }
    func ownsDetailWindow(_ candidate: NSWindow?) -> Bool { candidate != nil && candidate === hoverPanel }
    var statusText: String? {
        didSet { if oldValue != statusText && detailIsVisible { showHoverPanel() } }
    }

    var detailText = "5h: -- · reset --\n7d: -- · reset --" {
        didSet {
            toolTip = detailText
            setAccessibilityValue(detailText)
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
        pendingHide?.cancel()
        pendingShow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pointerInside else { return }
            self.showHoverPanel()
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        pendingShow?.cancel()
        scheduleHide()
    }

    private func scheduleHide() {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerInside, !self.pointerInDetail, !self.detailPinned else { return }
            self.hideHoverPanel()
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
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
        pendingShow?.cancel()
        pendingHide?.cancel()
        detailPinned.toggle()
        if detailPinned {
            showHoverPanel()
            hoverPanel?.makeKey()
        } else {
            hideHoverPanel()
        }
    }

    func dismissPinnedDetail(force: Bool = false) {
        guard detailPinned || force else { return }
        detailPinned = false
        pendingShow?.cancel()
        pendingHide?.cancel()
        hideHoverPanel()
    }

    func closeDetail() {
        pointerInside = false
        pointerInDetail = false
        dismissPinnedDetail(force: true)
    }

    private func showHoverPanel() {
        guard let window, !detailText.isEmpty else {
            return
        }

        let size = NSSize(width: 252, height: statusText == nil ? 68 : 90)
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        var origin = NSPoint(x: window.frame.maxX + 8, y: window.frame.maxY - size.height)
        if origin.x + size.width > screenFrame.maxX - 8 {
            origin.x = window.frame.minX - size.width - 8
        }
        origin.x = min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)
        origin.y = min(max(origin.y, screenFrame.minY + 8), screenFrame.maxY - size.height - 8)

        let panel = hoverPanel ?? QuotaDetailPanel(
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
        panel.ignoresMouseEvents = false
        let contentView = hoverView ?? HoverInfoView(frame: NSRect(origin: .zero, size: size), text: detailText)
        contentView.frame = NSRect(origin: .zero, size: size)
        contentView.update(text: detailText)
        contentView.statusText = statusText
        contentView.isPinned = detailPinned
        contentView.onPointerChange = { [weak self] inside in
            guard let self else { return }
            self.pointerInDetail = inside
            if inside { self.pendingHide?.cancel() } else { self.scheduleHide() }
        }
        if panel.contentView !== contentView {
            panel.contentView = contentView
        }
        hoverPanel = panel
        hoverView = contentView
        visibilityGeneration += 1
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func hideHoverPanel() {
        guard let panel = hoverPanel else { return }
        visibilityGeneration += 1
        let generation = visibilityGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            guard self?.visibilityGeneration == generation else { return }
            panel?.orderOut(nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds
        NSColor.clear.setFill()
        dirtyRect.fill()

        let background = NSBezierPath(ovalIn: bounds.insetBy(dx: 6, dy: 6))
        Self.graphiteBallColor.setFill()
        background.fill()

        let fiveHour = snapshot?.ok == true ? snapshot?.fiveHourLeft : nil
        let sevenDay = snapshot?.ok == true ? snapshot?.sevenDayLeft : nil
        drawRing(in: bounds.insetBy(dx: 8.5, dy: 8.5), percent: fiveHour, color: color(for: fiveHour), width: 4.5)
        drawRing(in: bounds.insetBy(dx: 14, dy: 14), percent: sevenDay, color: Self.sevenDayRingColor, width: 2.5)
        drawCenterValue(fiveHour)
    }

    private func drawRing(in rect: NSRect, percent: Int?, color: NSColor, width: CGFloat) {
        let track = NSBezierPath(ovalIn: rect)
        Self.ringTrackColor.setStroke()
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
    private static let periodFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private static let resetFont = NSFont.systemFont(ofSize: 11)
    private static let periodRect = NSRect(x: 14, y: 0, width: 28, height: 20)
    private static let valueRect = NSRect(x: 49, y: 0, width: 44, height: 20)
    private static let resetRect = NSRect(x: 101, y: 0, width: 137, height: 20)

    private var text: String
    var onPointerChange: ((Bool) -> Void)?
    var statusText: String? { didSet { needsDisplay = true } }
    var isPinned = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onPointerChange?(true) }
    override func mouseExited(with event: NSEvent) { onPointerChange?(false) }

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
        NSColor(calibratedRed: 0.15, green: 0.16, blue: 0.18, alpha: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.96).setFill()
        bubble.fill()
        NSColor.white.withAlphaComponent(isPinned ? 0.30 : 0.14).setStroke()
        bubble.lineWidth = 1
        bubble.stroke()

        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(2).enumerated() {
            let row = Self.parse(String(line))
            let rowY: CGFloat = (index == 0 ? 35 : 10) + (statusText == nil ? 0 : 22)
            draw(row.period, in: Self.periodRect.offsetBy(dx: 0, dy: rowY), font: Self.periodFont, color: .white)
            draw(row.value, in: Self.valueRect.offsetBy(dx: 0, dy: rowY), font: Self.valueFont, color: row.percent == nil ? .lightGray : .white, alignment: .right)
            draw(QuotaDisplay.resetLabel(row.reset), in: Self.resetRect.offsetBy(dx: 0, dy: rowY), font: Self.resetFont, color: .white.withAlphaComponent(0.76), alignment: .right)
        }
        if let statusText {
            draw(statusText, in: NSRect(x: 14, y: 8, width: 224, height: 16), font: .systemFont(ofSize: 10), color: .lightGray)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(ui("Quota details", "额度详情"))
        setAccessibilityValue(text + (statusText.map { "\n" + $0 } ?? ""))
        setAccessibilityHelp(isPinned ? ui("Pinned. Escape to close.", "已固定，按 Esc 关闭。") : ui("Hover details", "悬停详情"))
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

#if UI_TESTING
extension AppDelegate {
    func verifyMenuBehavior(valid: QuotaSnapshot, failed: QuotaSnapshot) -> [NSMenu] {
        precondition(ProcessInfo.processInfo.environment["CODEX_QUOTA_BAR_SUPPORT_DIR"] != nil)
        configureMenu()
        observeStatusItemAppearance()
        apply(snapshot: valid)
        apply(snapshot: failed)
        precondition(lastRenderedFiveHour == valid.fiveHourLeft)
        precondition(statusPresentation.statusKind == .stale)
        statusItem.button?.appearance = NSAppearance(named: .darkAqua)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(lastRenderedFiveHour == valid.fiveHourLeft)
        precondition(lastRenderedSevenDay == valid.sevenDayLeft)
        precondition(lastRenderedAppearanceKey == "darkAqua")
        retryTimer?.invalidate()
        retryTimer = nil
        let range = UsageRangeSnapshot(inputTokens: 10_200_000, cachedInputTokens: 8_600_000,
                                       outputTokens: 2_200_000, reasoningTokens: 0, totalTokens: 12_400_000)
        latestUsage = UsageSnapshot(ok: true, updatedAt: valid.updatedAt, error: nil, sourceStatus: nil,
                                    ranges: Dictionary(uniqueKeysWithValues: ["today", "7d", "30d", "month", "all"].map { ($0, range) }))
        updateUsageItems()
        for (index, key) in ["today", "7d", "30d", "month", "all"].enumerated() {
            periodMenu.performActionForItem(at: index)
            precondition(selectedUsageRange == key)
            precondition(AppPreferences.load().usageRange == key)
            precondition(periodMenu.items.filter { $0.state == .on }.count == 1)
        }
        periodMenu.performActionForItem(at: periodMenu.numberOfItems - 1)
        precondition(selectedUsageRange == "today")
        periodMenu.performActionForItem(at: 1)
        precondition(selectedUsageRange == "7d")
        statusPresentation = .refreshing(keeping: .live)
        applyStatusPresentation()
        precondition(!refreshItem.isEnabled)
        apply(snapshot: valid)
        precondition(stateItem.isHidden)
        precondition(refreshItem.isEnabled)
        precondition(cachedTokenView.accessibilityValue() as? String == "8.6M")
        NSStatusBar.system.removeStatusItem(statusItem)
        appearanceObservation?.invalidate()
        return [menu, usageMenu, settingsMenu, periodMenu]
    }
}
#endif
