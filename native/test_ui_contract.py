#!/usr/bin/env python3
"""Static contracts for the native UI iteration.

These checks guard the source-level contract. Native rendering is exercised by
ui_snapshot_driver.swift; physical pointer tracking remains a separate manual
UI check because it needs a real menu-bar interaction surface.
"""

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parent
SOURCE = (ROOT / "CodexQuotaBar.swift").read_text(encoding="utf-8")
SNAPSHOT_DRIVER = (ROOT / "ui_snapshot_driver.swift").read_text(encoding="utf-8")


class StaticUIContractTests(unittest.TestCase):
    def test_small_ball_geometry_and_center_value_contract(self):
        self.assertIn("NSRect(x: 0, y: 0, width: 54, height: 54)", SNAPSHOT_DRIVER)
        self.assertIn("bounds.insetBy(dx: 8.5, dy: 8.5)", SOURCE)
        self.assertIn("bounds.insetBy(dx: 14, dy: 14)", SOURCE)
        self.assertIn("width: 4.5", SOURCE)
        self.assertIn("width: 2.5", SOURCE)
        self.assertIn("private static let graphiteBallColor", SOURCE)
        self.assertIn("calibratedRed: 36.0 / 255.0", SOURCE)
        self.assertIn("green: 38.0 / 255.0", SOURCE)
        self.assertIn("blue: 43.0 / 255.0", SOURCE)
        self.assertIn("alpha: 0.90", SOURCE)
        self.assertIn("private static let ringTrackColor = NSColor.white.withAlphaComponent(0.11)", SOURCE)
        self.assertIn("Self.ringTrackColor.setStroke()", SOURCE)
        self.assertIn("private static let sevenDayRingColor", SOURCE)
        self.assertIn("calibratedRed: 184.0 / 255.0", SOURCE)
        self.assertIn("green: 192.0 / 255.0", SOURCE)
        self.assertIn("blue: 200.0 / 255.0", SOURCE)
        self.assertIn("alpha: 0.94", SOURCE)
        self.assertIn("color: Self.sevenDayRingColor, width: 2.5", SOURCE)
        self.assertIn("monospacedSystemFont(ofSize: 10.0, weight: .semibold)", SOURCE)
        self.assertIn("drawCenterValue(fiveHour)", SOURCE)

    def test_five_ball_states_and_unknown_state_are_rendered_natively(self):
        for name in (
            "state-both-high",
            "state-5h-low-7d-high",
            "state-5h-high-7d-low",
            "state-5h-orange-7d-high",
            "state-7d-low",
            "state-0",
            "state-100",
            "state-5h-missing",
            "state-7d-missing",
            "state-none",
        ):
            self.assertIn('"' + name + '"', SNAPSHOT_DRIVER)
        self.assertIn("snapshot?.ok == true ? snapshot?.fiveHourLeft : nil", SOURCE)
        self.assertIn('let text = percent.map { "\\(max(0, min(100, $0)))" } ?? "--"', SOURCE)

    def test_menu_uses_real_actions_and_shortcut_without_reopen_loop(self):
        self.assertIn("final class MenuPeriodControlView: NSView", SOURCE)
        self.assertIn("final class MenuDetailRowView: NSView", SOURCE)
        self.assertIn('button.keyEquivalent = "t"', SOURCE)
        self.assertIn("button.keyEquivalentModifierMask = [.command]", SOURCE)
        self.assertIn("tokenRangeItem.submenu = periodMenu", SOURCE)
        self.assertIn("menu.minimumWidth = MenuQuotaRowView.menuWidth", SOURCE)
        self.assertIn("usageMenu.minimumWidth = MenuDetailRowView.menuWidth", SOURCE)
        self.assertIn("settingsMenu.minimumWidth = 220", SOURCE)
        self.assertIn("private static let contentInset: CGFloat = 14", SOURCE)
        self.assertIn("periodLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentInset + 12)", SOURCE)
        self.assertIn("resetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.contentInset)", SOURCE)
        self.assertIn("NSFont.systemFont(ofSize: 13, weight: .medium)", SOURCE)
        self.assertIn("private static let valueColumnWidth: CGFloat = 44", SOURCE)
        self.assertIn("private static let valueResetGap: CGFloat = 8", SOURCE)
        self.assertIn("valueLabel.alignment = .right", SOURCE)
        self.assertIn("label.lineBreakMode = .byTruncatingTail", SOURCE)
        self.assertIn("usageMenu.update()", SOURCE)
        self.assertNotIn("reopenMenuAfterPeriodChange", SOURCE)

    def test_usage_data_is_split_without_fixed_truncating_custom_row(self):
        self.assertIn('NSMenuItem(title: "Input --", action: nil, keyEquivalent: "")', SOURCE)
        self.assertIn('NSMenuItem(title: "Cached --", action: nil, keyEquivalent: "")', SOURCE)
        self.assertIn('NSMenuItem(title: "Output --", action: nil, keyEquivalent: "")', SOURCE)
        self.assertIn("tokenTotalItem.view = tokenTotalView", SOURCE)
        self.assertIn("fiveHourTrendItem.view = fiveHourTrendView", SOURCE)
        self.assertIn('"Updating local statistics…"', SOURCE)

    def test_partial_quota_data_keeps_independent_reset_value(self):
        self.assertIn("let resetText = reset ?? \"--\"", SOURCE)
        self.assertIn("resetLabel.stringValue = QuotaDisplay.resetLabel(resetText)", SOURCE)
        self.assertIn('shortDateTime(snapshot?.sevenDayReset)', SOURCE)

    def test_hover_parser_rejects_error_text_and_bounds_reset_text(self):
        self.assertIn('guard let separator = trimmed.range(of: "·") else', SOURCE)
        self.assertIn('guard period == "5h" || period == "7d" else', SOURCE)
        self.assertIn('guard right.hasPrefix("reset") else', SOURCE)
        self.assertIn('reset.count <= 11', SOURCE)
        self.assertIn("byTruncatingTail", SOURCE)
        self.assertIn("private static let resetFont = NSFont.systemFont(ofSize: 11)", SOURCE)
        self.assertIn("private static let valueRect = NSRect(x: 49, y: 0, width: 44, height: 20)", SOURCE)
        self.assertIn("private static let resetRect = NSRect(x: 101, y: 0, width: 137, height: 20)", SOURCE)
        self.assertIn('draw(row.value, in: Self.valueRect.offsetBy(dx: 0, dy: rowY), font: Self.valueFont, color: row.percent == nil ? .lightGray : .white, alignment: .right)', SOURCE)
        self.assertIn('draw(QuotaDisplay.resetLabel(row.reset), in: Self.resetRect', SOURCE)
        self.assertIn("NSGraphicsContext.saveGraphicsState()", SOURCE)
        self.assertIn('NSSize(width: 252, height: 68)', SOURCE)

    def test_existing_drag_pin_position_and_dismiss_paths_remain_present(self):
        for expression in (
            "window.performDrag(with: event)",
            "togglePinnedDetail()",
            "dismissPinnedDetail()",
            "NSScreen.main?.visibleFrame",
            "preferences.floatingBallX",
            "preferences.floatingBallY",
            "collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]",
        ):
            self.assertIn(expression, SOURCE)

    def test_snapshot_driver_covers_valid_and_invalid_detail_text(self):
        self.assertIn('let detail = "5h: 59%', SNAPSHOT_DRIVER)
        self.assertIn('let longestResetDetail = "5h: 100%', SNAPSHOT_DRIVER)
        self.assertIn('name: "detail-longest-reset"', SNAPSHOT_DRIVER)
        self.assertIn('text: "ChatGPT or Codex app not found."', SNAPSHOT_DRIVER)
        self.assertIn('name: "detail-unavailable"', SNAPSHOT_DRIVER)

    def test_refresh_feedback_is_stateful_and_sanitized(self):
        for text in ("Refreshing…", "Retry refresh", "Last update", "No quota data", "Settings unavailable"):
            self.assertIn(text, SOURCE)
        self.assertIn("struct MenuStatusPresentation: Equatable", SOURCE)
        self.assertIn("static func refreshing(keeping previous: MenuStatusPresentation)", SOURCE)
        self.assertIn("static func refreshFailure(lastUpdated: String?, hasData: Bool = false)", SOURCE)
        self.assertIn("static let operationFailure", SOURCE)
        self.assertIn('let malformed = MenuStatusPresentation.refreshFailure(lastUpdated: "sk-live-secret-token")', SNAPSHOT_DRIVER)
        self.assertIn("assertMenuStatusPresentation()", SNAPSHOT_DRIVER)

    def test_status_item_reacts_to_actual_button_appearance_and_snapshots_both_modes(self):
        self.assertIn("button.observe(\\.effectiveAppearance", SOURCE)
        self.assertIn("button?.effectiveAppearance", SOURCE)
        self.assertIn("lastRenderedAppearanceKey", SOURCE)
        self.assertIn("StatusItemRenderer.appearanceKey", SOURCE)
        self.assertIn('name: "status-light"', SNAPSHOT_DRIVER)
        self.assertIn('name: "status-dark"', SNAPSHOT_DRIVER)
        self.assertIn('"menu-status-settings-error"', SNAPSHOT_DRIVER)


if __name__ == "__main__":
    unittest.main()
