import Foundation
import Testing

@testable import AgentBurn

private let now = Date(timeIntervalSince1970: 1_791_300_000)

@Test func quotaAlertFiresOncePerWindowAtOrBelowTheThreshold() {
  let reset = now.addingTimeInterval(3_600)
  let low = QuotaAlertInput(key: "claude-session", title: "Session", remaining: 18, reset: reset)
  let healthy = QuotaAlertInput(key: "codex", title: "Codex", remaining: 64, reset: reset)
  let due = quotaAlertsDue([low, healthy], sent: [:], now: now)
  #expect(due.map(\.key) == ["claude-session"])
  #expect(due.first?.marker == reset.timeIntervalSince1970)
  #expect(quotaAlertsDue([low], sent: ["claude-session": reset.timeIntervalSince1970], now: now)
    .isEmpty)
  let nextWindow = QuotaAlertInput(
    key: "claude-session", title: "Session", remaining: 10, reset: reset.addingTimeInterval(18_000))
  #expect(
    quotaAlertsDue([nextWindow], sent: ["claude-session": reset.timeIntervalSince1970], now: now)
      .count == 1)
}

@Test func quotaAlertIgnoresWindowsThatAlreadyReset() {
  let ended = QuotaAlertInput(
    key: "claude", title: "Weekly", remaining: 5, reset: now.addingTimeInterval(-60))
  #expect(quotaAlertsDue([ended], sent: [:], now: now).isEmpty)
}

@Test func claudeStaleAlertWaitsHalfAnHourAndFiresOncePerReading() {
  let recent = now.addingTimeInterval(-10 * 60)
  let old = now.addingTimeInterval(-45 * 60)
  #expect(claudeStaleAlertDue(lastReading: recent, sent: [:], now: now) == nil)
  #expect(claudeStaleAlertDue(lastReading: nil, sent: [:], now: now) == nil)
  let alert = claudeStaleAlertDue(lastReading: old, sent: [:], now: now)
  #expect(alert?.key == "claude-stale")
  #expect(
    claudeStaleAlertDue(
      lastReading: old, sent: ["claude-stale": old.timeIntervalSince1970], now: now) == nil)
}

@Test func claudeSessionRemainingFallsBackToTheRunningAccountMeter() {
  let running = ClaudeAccount(
    sessionUsedPercent: 53, sessionResetsAtMs: now.addingTimeInterval(600).timeIntervalSince1970
      * 1000)
  #expect(claudeSessionRemainingPercent(session: nil, account: running, now: now) == 47)
  let ended = ClaudeAccount(
    sessionUsedPercent: 53, sessionResetsAtMs: now.addingTimeInterval(-600).timeIntervalSince1970
      * 1000)
  #expect(claudeSessionRemainingPercent(session: nil, account: ended, now: now) == nil)
}
