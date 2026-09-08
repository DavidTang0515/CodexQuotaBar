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
        self.assertIn("bounds.insetBy(dx: 9.25, dy: 9.25)", SOURCE)
        self.assertIn("bounds.insetBy(dx: 14, dy: 14)", SOURCE)
        self.assertIn("width: 4.5", SOURCE)
        self.assertIn("width: 3.2", SOURCE)
        self.assertIn("monospacedSystemFont(ofSize: 10.0, weight: .semibold)", SOURCE)
        self.assertIn("drawCenterValue(fiveHour)", SOURCE)

    def test_five_ball_states_and_unknown_state_are_rendered_natively(self):
        for name in ("state-0", "state-9", "state-59", "state-100", "state-none"):
            self.assertIn('"' + name + '"', SNAPSHOT_DRIVER)
        self.assertIn("snapshot?.ok == true ? snapshot?.fiveHourLeft : nil", SOURCE)
        self.assertIn('let text = percent.map { "\\(max(0, min(100, $0)))" } ?? "--"', SOURCE)

    def test_menu_uses_real_actions_and_shortcut_without_reopen_loop(self):
        self.assertIn("final class MenuPeriodControlView: NSView", SOURCE)
        self.assertIn("final class MenuDetailRowView: NSView", SOURCE)
        self.assertIn('button.keyEquivalent = "t"', SOURCE)
        self.assertIn("button.keyEquivalentModifierMask = [.command]", SOURCE)
        self.assertIn("periodControlView.onCycle", SOURCE)
        self.assertIn("menu.minimumWidth = MenuQuotaRowView.menuWidth", SOURCE)
        self.assertIn("usageMenu.minimumWidth = MenuDetailRowView.menuWidth", SOURCE)
        self.assertIn("settingsMenu.minimumWidth = 220", SOURCE)
        self.assertIn("label.lineBreakMode = .byTruncatingTail", SOURCE)
        self.assertIn("usageMenu.update()", SOURCE)
        self.assertNotIn("reopenMenuAfterPeriodChange", SOURCE)

    def test_usage_data_is_split_without_fixed_truncating_custom_row(self):
        self.assertIn('NSMenuItem(title: "Input --", action: nil, keyEquivalent: "")', SOURCE)
        self.assertIn('NSMenuItem(title: "Cached --", action: nil, keyEquivalent: "")', SOURCE)
        self.assertIn('NSMenuItem(title: "Output --", action: nil, keyEquivalent: "")', SOURCE)
        self.assertIn("tokenTotalItem.view = tokenTotalView", SOURCE)
        self.assertIn("fiveHourTrendItem.view = fiveHourTrendView", SOURCE)
        self.assertIn('"Token: Scanning local records..."', SOURCE)

    def test_partial_quota_data_keeps_independent_reset_value(self):
        self.assertIn("let resetText = reset ?? \"--\"", SOURCE)
        self.assertIn('resetLabel.stringValue = "reset \\(resetText)"', SOURCE)
        self.assertIn('shortDateTime(snapshot?.sevenDayReset)', SOURCE)

    def test_hover_parser_rejects_error_text_and_bounds_reset_text(self):
        self.assertIn('guard let separator = trimmed.range(of: "·") else', SOURCE)
        self.assertIn('guard period == "5h" || period == "7d" else', SOURCE)
        self.assertIn('guard right.hasPrefix("reset") else', SOURCE)
        self.assertIn('reset.count <= 11', SOURCE)
        self.assertIn("byTruncatingTail", SOURCE)
        self.assertIn("private static let resetValueRect", SOURCE)
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


if __name__ == "__main__":
    unittest.main()
