import AppKit
import Foundation

final class SnapshotCanvasView: NSView {
    private let backgroundColor: NSColor

    init(frame: NSRect, backgroundColor: NSColor) {
        self.backgroundColor = backgroundColor
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
    }
}

func snapshot(ok: Bool, fiveHour: Int?, sevenDay: Int?) -> QuotaSnapshot {
    QuotaSnapshot(
        ok: ok,
        updatedAt: "2026-09-07T12:00:00Z",
        source: ok ? "snapshot-driver" : "unavailable",
        error: ok ? nil : "synthetic unavailable state",
        plan: ok ? "plus" : nil,
        currentQuotaLeft: fiveHour,
        currentQuotaReset: "2026-09-07T15:30:00Z",
        fiveHourLeft: fiveHour,
        sevenDayLeft: sevenDay,
        fiveHourReset: "2026-09-07T15:30:00Z",
        sevenDayReset: "2026-09-12T08:00:00Z"
    )
}

func writePNG(view: NSView, name: String, outputDirectory: URL) throws {
    let host = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
    host.contentView = view
    host.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()

    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw NSError(domain: "CodexQuotaBarSnapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not allocate bitmap for " + name + "."])
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CodexQuotaBarSnapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode " + name + "."])
    }
    try png.write(to: outputDirectory.appendingPathComponent(name + ".png"), options: .atomic)
    print(name + " " + String(Int(view.bounds.width)) + "x" + String(Int(view.bounds.height)))
}

func writePNG(image: NSImage, name: String, outputDirectory: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CodexQuotaBarSnapshot", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode " + name + "."])
    }
    try png.write(to: outputDirectory.appendingPathComponent(name + ".png"), options: .atomic)
    print(name + " " + String(Int(image.size.width)) + "x" + String(Int(image.size.height)))
}

func writePNG(view: NSView, name: String, outputDirectory: URL, backgroundColor: NSColor) throws {
    let canvas = SnapshotCanvasView(frame: view.bounds, backgroundColor: backgroundColor)
    view.frame = canvas.bounds
    canvas.addSubview(view)
    try writePNG(view: canvas, name: name, outputDirectory: outputDirectory)
}

func assertMenuStatusPresentation() {
    let loading = MenuStatusPresentation.refreshing(keeping: .live)
    precondition(loading.refreshTitle == ui("Refreshing…", "正在刷新…"))
    precondition(!loading.refreshEnabled)
    precondition(loading.statusText == nil)

    let stale = MenuStatusPresentation.refreshFailure(lastUpdated: "09:55")
    precondition(stale.refreshTitle == ui("Retry refresh", "重新刷新"))
    precondition(stale.refreshEnabled)
    precondition(stale.statusText == ui("Last update 09:55", "刷新失败 · 上次更新 09:55"))
    precondition(stale.statusKind == .stale)

    let noData = MenuStatusPresentation.refreshFailure(lastUpdated: nil)
    precondition(noData.statusText == ui("No quota data", "暂时无法读取额度"))
    precondition(noData.statusKind == .noData)

    let malformed = MenuStatusPresentation.refreshFailure(lastUpdated: "sk-live-secret-token")
    precondition(malformed.statusText == ui("No quota data", "暂时无法读取额度"))
    precondition(!malformed.statusText!.contains("secret"))

    let operationFailure = MenuStatusPresentation.operationFailure
    precondition(operationFailure.statusText == ui("Settings unavailable", "操作未完成"))
    precondition(!operationFailure.statusText!.contains("/"))
    precondition(MenuStatusPresentation.live.statusText == nil)
    precondition(MenuStatusPresentation.refreshFailure(lastUpdated: "99:99").statusKind == .noData)
    precondition(MenuStatusPresentation.refreshFailure(lastUpdated: nil, hasData: true).statusKind == .stale)
    precondition(MenuStatusPresentation.refreshFailure(lastUpdated: "09-10 09:55").statusKind == .stale)
    let valid = snapshot(ok: true, fiveHour: 59, sevenDay: 100)
    let failed = snapshot(ok: false, fiveHour: nil, sevenDay: nil)
    precondition(QuotaDisplay.snapshot(latest: failed, lastValid: valid)?.fiveHourLeft == 59)
    precondition(QuotaDisplay.snapshot(latest: failed, lastValid: nil) == nil)
    let partial = snapshot(ok: true, fiveHour: nil, sevenDay: 79)
    precondition(QuotaDisplay.snapshot(latest: partial, lastValid: valid)?.fiveHourLeft == nil)
    var retry = RefreshRetryBudget()
    precondition(retry.consume())
    for _ in 0..<10 { precondition(!retry.consume()) }
    retry.beginCycle()
    precondition(retry.consume())
    let timestamp = "2026-09-10T09:55:00.123Z"
    let date = QuotaDisplay.date(timestamp)!
    precondition(QuotaDisplay.updateTime(timestamp, now: date)!.count == 5)
    precondition(QuotaDisplay.updateTime(timestamp, now: date.addingTimeInterval(86400))!.count == 11)
    precondition(QuotaDisplay.resetTime("unsafe raw text") == "--")
    print("PASS state, retry, dates, partial-data and sanitization behavior")
}

@main
struct UISnapshotMain {
    static func main() throws {
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/codexquotabar-ui-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        assertMenuStatusPresentation()

        #if UI_TESTING
        let delegate = AppDelegate()
        let menus = delegate.verifyMenuBehavior(valid: snapshot(ok: true, fiveHour: 59, sevenDay: 100), failed: snapshot(ok: false, fiveHour: nil, sevenDay: nil))
        print("PASS native menu selection, persisted period and failed-refresh appearance transition")
        var customViews: [ObjectIdentifier: NSView] = [:]
        for menu in menus {
            for item in menu.items {
                if let view = item.view {
                    customViews[ObjectIdentifier(item)] = view
                    item.view = nil // NSMenu otherwise resets its custom view's frame origin to zero.
                }
            }
        }
        for (theme, appearance, background) in [("light", NSAppearance.Name.aqua, NSColor(calibratedWhite: 0.97, alpha: 1)), ("dark", NSAppearance.Name.darkAqua, NSColor(calibratedWhite: 0.17, alpha: 1))] {
            for (index, menu) in menus.enumerated() {
                let width: CGFloat = index == 1 ? 320 : 300
                let canvas = SnapshotCanvasView(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(menu.items.filter { !$0.isHidden }.count) * 26 + 16), backgroundColor: background)
                canvas.appearance = NSAppearance(named: appearance)
                var y = canvas.bounds.height - 34
                for item in menu.items where !item.isHidden {
                    if item.isSeparatorItem {
                        let separator = NSBox(frame: NSRect(x: 14, y: y + 12, width: width - 28, height: 1))
                        separator.boxType = .separator
                        canvas.addSubview(separator)
                    } else if let view = customViews[ObjectIdentifier(item)] {
                        let height = view.intrinsicContentSize.height
                        view.translatesAutoresizingMaskIntoConstraints = true
                        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
                        view.appearance = canvas.appearance
                        let rowHost = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
                        rowHost.contentView = view
                        rowHost.layoutIfNeeded()
                        view.layoutSubtreeIfNeeded()
                        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        let image = NSImage(size: view.bounds.size)
                        image.addRepresentation(bitmap)
                        let rendered = NSImageView(frame: NSRect(x: 0, y: y, width: width, height: height))
                        rendered.image = image
                        rendered.imageScaling = .scaleAxesIndependently
                        canvas.addSubview(rendered)
                        rowHost.contentView = nil
                    } else {
                        let label = NSTextField(labelWithString: item.title + (item.submenu == nil ? "" : "  ›"))
                        label.font = .systemFont(ofSize: 13)
                        label.textColor = .labelColor
                        label.frame = NSRect(x: 14, y: y + 3, width: width - 28, height: 22)
                        canvas.addSubview(label)
                    }
                    y -= 26
                }
                try writePNG(view: canvas, name: "menu-composition-\(index)-\(theme)", outputDirectory: outputDirectory)
            }
        }
        #endif
        let lightAppearance = NSAppearance(named: .aqua)
        let darkAppearance = NSAppearance(named: .darkAqua)
        let lightStatus = StatusItemRenderer.image(
            fiveHour: 60,
            sevenDay: 79,
            loading: false,
            ok: true,
            appearance: lightAppearance
        )
        let darkStatus = StatusItemRenderer.image(
            fiveHour: 60,
            sevenDay: 79,
            loading: false,
            ok: true,
            appearance: darkAppearance
        )
        try writePNG(image: lightStatus, name: "status-light", outputDirectory: outputDirectory)
        try writePNG(image: darkStatus, name: "status-dark", outputDirectory: outputDirectory)

        let statusRows: [(String, MenuStatusPresentation)] = [
            ("menu-status-stale", .refreshFailure(lastUpdated: "09:55")),
            ("menu-status-no-data", .refreshFailure(lastUpdated: nil)),
            ("menu-status-settings-error", .operationFailure)
        ]
        for (name, presentation) in statusRows {
            let view = MenuStatusRowView()
            if let text = presentation.statusText {
                view.update(text: text, kind: presentation.statusKind)
            }
            try writePNG(
                view: view,
                name: name,
                outputDirectory: outputDirectory,
                backgroundColor: NSColor(calibratedWhite: 0.96, alpha: 1.0)
            )
        }

        let ballStates: [(String, QuotaSnapshot)] = [
            ("state-both-high", snapshot(ok: true, fiveHour: 85, sevenDay: 78)),
            ("state-5h-low-7d-high", snapshot(ok: true, fiveHour: 9, sevenDay: 82)),
            ("state-5h-high-7d-low", snapshot(ok: true, fiveHour: 82, sevenDay: 9)),
            ("state-5h-orange-7d-high", snapshot(ok: true, fiveHour: 40, sevenDay: 95)),
            ("state-7d-low", snapshot(ok: true, fiveHour: 69, sevenDay: 9)),
            ("state-0", snapshot(ok: true, fiveHour: 0, sevenDay: 0)),
            ("state-100", snapshot(ok: true, fiveHour: 100, sevenDay: 100)),
            ("state-5h-missing", snapshot(ok: true, fiveHour: nil, sevenDay: 84)),
            ("state-7d-missing", snapshot(ok: true, fiveHour: 84, sevenDay: nil)),
            ("state-none", snapshot(ok: false, fiveHour: nil, sevenDay: nil))
        ]

        for (name, state) in ballStates {
            let view = FloatingBallView(frame: NSRect(x: 0, y: 0, width: 54, height: 54))
            view.snapshot = state
            try writePNG(view: view, name: name, outputDirectory: outputDirectory)
        }

        for value: Int? in [nil, 0, 9, 59, 100] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let img = StatusItemRenderer.image(fiveHour: value, sevenDay: value, loading: false, ok: true, appearance: NSAppearance(named: appearance))
                try writePNG(image: img, name: "status-\(value.map(String.init) ?? "unknown")-\(appearance.rawValue)", outputDirectory: outputDirectory)
            }
        }
        let detail = "5h: 59% · reset 09-07 15:30\n7d: 100% · reset 09-12 08:00"
        let hover = HoverInfoView(frame: NSRect(x: 0, y: 0, width: 252, height: 68), text: detail)
        try writePNG(view: hover, name: "detail", outputDirectory: outputDirectory)

        let staleHover = HoverInfoView(frame: NSRect(x: 0, y: 0, width: 252, height: 90), text: detail)
        staleHover.statusText = MenuStatusPresentation.refreshFailure(lastUpdated: "09-10 09:55").statusText
        try writePNG(view: staleHover, name: "detail-stale", outputDirectory: outputDirectory)
        let longestResetDetail = "5h: 100% · reset 12-31 23:59\n7d: --% · reset 01-01 00:00"
        let longestResetHover = HoverInfoView(frame: NSRect(x: 0, y: 0, width: 252, height: 68), text: longestResetDetail)
        try writePNG(view: longestResetHover, name: "detail-longest-reset", outputDirectory: outputDirectory)

        let unavailableHover = HoverInfoView(frame: NSRect(x: 0, y: 0, width: 252, height: 68), text: "ChatGPT or Codex app not found.")
        try writePNG(view: unavailableHover, name: "detail-unavailable", outputDirectory: outputDirectory)
    }
}
