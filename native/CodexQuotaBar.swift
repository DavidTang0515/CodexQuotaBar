import AppKit
import Foundation
import ServiceManagement

struct QuotaSnapshot: Decodable {
    let ok: Bool
    let updatedAt: String?
    let source: String?
    let error: String?
    let plan: String?
    let fiveHourLeft: Int?
    let sevenDayLeft: Int?
    let fiveHourReset: String?
    let sevenDayReset: String?
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

    private static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("CodexQuotaBar", isDirectory: true)
    }

    private static func fileURL() -> URL {
        supportDirectory().appendingPathComponent("preferences.json")
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
    private let stateItem = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
    private var timer: Timer?
    private var retryTimer: Timer?
    private var isRefreshing = false
    private var latestSnapshot: QuotaSnapshot?
    private var floatingPanel: NSPanel?
    private var floatingView: FloatingBallView?
    private var preferences = AppPreferences.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        updateButton(snapshot: nil, loading: true)
        if preferences.showFloatingBall {
            showFloatingBall()
        }
        refreshNow()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        retryTimer?.invalidate()
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
        menu.addItem(refreshItem)
        floatingBallItem.target = self
        menu.addItem(floatingBallItem)
        openAtLoginItem.target = self
        updateOpenAtLoginMenuItem()
        menu.addItem(openAtLoginItem)

        let openCodex = NSMenuItem(title: "Open Codex", action: #selector(openCodex), keyEquivalent: "o")
        openCodex.target = self
        menu.addItem(openCodex)

        menu.addItem(NSMenuItem.separator())
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
        updateButton(snapshot: nil, loading: true)

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

    private func helperURL() -> URL? {
        if let resource = Bundle.main.url(forResource: "codex_quota", withExtension: "py") {
            return resource
        }
        let source = URL(fileURLWithPath: #filePath)
        return source.deletingLastPathComponent().appendingPathComponent("codex_quota.py")
    }

    private func readQuota() -> QuotaSnapshot {
        guard let helper = helperURL() else {
            return QuotaSnapshot(
                ok: false,
                updatedAt: isoNow(),
                source: "unavailable",
                error: "Helper not found.",
                plan: nil,
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
            "PATH": "/Applications/Codex.app/Contents/Resources:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
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
            fiveHourItem.title = "5h: --"
            sevenDayItem.title = "7d: --"
            resetItem.title = "Reset: --"
            updatedItem.title = "Last refresh: --"
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

        fiveHourItem.title = "5h: \(percentText(snapshot.fiveHourLeft))"
        sevenDayItem.title = "7d: \(percentText(snapshot.sevenDayLeft))"
        resetItem.title = "Reset: 5h \(shortTime(snapshot.fiveHourReset)) / 7d \(shortTime(snapshot.sevenDayReset))"
        updatedItem.title = "Last refresh: \(shortTime(snapshot.updatedAt))"
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
        let five = snapshot?.fiveHourLeft
        let seven = snapshot?.sevenDayLeft
        let image = renderStatusImage(fiveHour: five, sevenDay: seven, loading: loading, ok: snapshot?.ok ?? false)
        statusItem.length = image.size.width
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "CodexQuotaBar 5h \(percentText(five)) / 7d \(percentText(seven))"
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

    private func shortTime(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "--" }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else { return value }
        let output = DateFormatter()
        output.dateFormat = "HH:mm"
        return output.string(from: date)
    }

    private func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    @objc private func openCodex() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Codex.app"))
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
            panel.delegate = self

            let view = FloatingBallView(frame: NSRect(origin: .zero, size: size))
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

final class FloatingBallView: NSView {
    var snapshot: QuotaSnapshot? {
        didSet {
            needsDisplay = true
        }
    }

    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds.insetBy(dx: 6, dy: 6)
        NSColor.clear.setFill()
        dirtyRect.fill()

        let background = NSBezierPath(ovalIn: bounds)
        NSColor.black.withAlphaComponent(0.58).setFill()
        background.fill()

        let five = snapshot?.fiveHourLeft
        let seven = snapshot?.sevenDayLeft
        drawRing(in: bounds.insetBy(dx: 7, dy: 7), percent: five, color: color(for: five), width: 4.5)
        drawRing(in: bounds.insetBy(dx: 16, dy: 16), percent: seven, color: color(for: seven), width: 3.2)
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
