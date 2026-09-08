import AppKit
import Foundation

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
    let image = NSImage(size: view.bounds.size)
    image.lockFocus()
    view.draw(view.bounds)
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CodexQuotaBarSnapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode " + name + "."])
    }
    try png.write(to: outputDirectory.appendingPathComponent(name + ".png"), options: .atomic)
    print(name + " " + String(Int(view.bounds.width)) + "x" + String(Int(view.bounds.height)))
}

@main
struct UISnapshotMain {
    static func main() throws {
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/codexquotabar-ui-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let ballStates: [(String, QuotaSnapshot)] = [
            ("state-0", snapshot(ok: true, fiveHour: 0, sevenDay: 0)),
            ("state-9", snapshot(ok: true, fiveHour: 9, sevenDay: 9)),
            ("state-59", snapshot(ok: true, fiveHour: 59, sevenDay: 59)),
            ("state-100", snapshot(ok: true, fiveHour: 100, sevenDay: 100)),
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
