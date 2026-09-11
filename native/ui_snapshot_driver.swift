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
    precondition(loading.refreshTitle == "Refreshing…")
    precondition(!loading.refreshEnabled)
    precondition(loading.statusText == nil)

    let stale = MenuStatusPresentation.refreshFailure(lastUpdated: "09:55")
    precondition(stale.refreshTitle == "Retry refresh")
    precondition(stale.refreshEnabled)
    precondition(stale.statusText == "Showing last update 09:55")
    precondition(stale.statusKind == .stale)

    let noData = MenuStatusPresentation.refreshFailure(lastUpdated: nil)
    precondition(noData.statusText == "No quota data")
    precondition(noData.statusKind == .noData)

    let malformed = MenuStatusPresentation.refreshFailure(lastUpdated: "sk-live-secret-token")
    precondition(malformed.statusText == "No quota data")
    precondition(!malformed.statusText!.contains("secret"))

    let operationFailure = MenuStatusPresentation.operationFailure
    precondition(operationFailure.statusText == "Settings unavailable")
    precondition(!operationFailure.statusText!.contains("/"))
    precondition(MenuStatusPresentation.live.statusText == nil)
}

@main
struct UISnapshotMain {
    static func main() throws {
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/codexquotabar-ui-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        assertMenuStatusPresentation()

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

        let detail = "5h: 59% · reset 09-07 15:30\n7d: 100% · reset 09-12 08:00"
        let hover = HoverInfoView(frame: NSRect(x: 0, y: 0, width: 252, height: 68), text: detail)
        try writePNG(view: hover, name: "detail", outputDirectory: outputDirectory)

        let longestResetDetail = "5h: 100% · reset 12-31 23:59\n7d: --% · reset 01-01 00:00"
        let longestResetHover = HoverInfoView(frame: NSRect(x: 0, y: 0, width: 252, height: 68), text: longestResetDetail)
        try writePNG(view: longestResetHover, name: "detail-longest-reset", outputDirectory: outputDirectory)

        let unavailableHover = HoverInfoView(frame: NSRect(x: 0, y: 0, width: 252, height: 68), text: "ChatGPT or Codex app not found.")
        try writePNG(view: unavailableHover, name: "detail-unavailable", outputDirectory: outputDirectory)
    }
}
