import Foundation
import Testing

@testable import AgentBurn

@Test func claudeAccountSurvivesArchivalProjection() throws {
  let report = try JSONDecoder().decode(
    SummaryReport.self,
    from: Data(
      """
      {"totals":{"totalCost":0,"totalTokens":0},"agents":[],"models":[],"claudeAccount":{"sessionUsedPercent":18,"weeklyUsedPercent":9,"weeklyResetsAtMs":1790000000000,"scoped":[{"name":"Fable","usedPercent":15}],"extraEnabled":true,"extraUsedUSD":25,"extraLimitUSD":1000,"extraUsedPercent":2.5}}
      """.utf8))
  let projected = MetricsArchive().report(period: .all, live: report)
  #expect(projected.claudeAccount?.sessionUsedPercent == 18)
  #expect(projected.claudeAccount?.weeklyUsedPercent == 9)
  #expect(projected.claudeAccount?.scoped.first?.name == "Fable")
  #expect(projected.claudeAccount?.extraUsedUSD == 25)
}

@Test func claudeRemainingUsesWeeklyMeterWhenForecastIsMissing() throws {
  let account = try JSONDecoder().decode(
    ClaudeAccount.self,
    from: Data(#"{"weeklyUsedPercent":12,"scoped":[]}"#.utf8))
  #expect(
    remainingQuota(for: .claude, forecast: nil, cursorAccount: nil, claudeAccount: account) == 88)
}

@Test func extraUsagePercentFallsBackToUsedOverLimit() {
  let account = ClaudeAccount(extraUsedUSD: 25, extraLimitUSD: 1000)
  #expect(extraUsedPercent(account) == 2.5)
}

private func claudeForecast(minutes: Double, elapsed: Double, used: Double, at now: Date)
  -> Forecast
{
  Forecast(
    window: QuotaWindow(
      windowMinutes: minutes, usedPercent: used, elapsedPercent: elapsed, apiEquivalentSpent: 0),
    observedAt: now, isLive: true)
}

@Test func claudeVerdictIsOnTrackWhenBothLimitsLastUntilReset() {
  let now = Date(timeIntervalSince1970: 1_790_000_000)
  let verdict = claudeVerdict(
    session: claudeForecast(minutes: 300, elapsed: 20, used: 10, at: now),
    weekly: claudeForecast(minutes: 10080, elapsed: 25, used: 3, at: now), now: now)
  #expect(verdict?.atRisk == false)
  #expect(verdict?.detail == "At this pace both limits last until they reset.")
}

@Test func claudeVerdictNamesSessionRunOutAndHourlyPace() throws {
  let now = Date(timeIntervalSince1970: 1_790_000_000)
  let session = claudeForecast(minutes: 300, elapsed: 20, used: 38, at: now)
  let verdict = try #require(
    claudeVerdict(
      session: session, weekly: claudeForecast(minutes: 10080, elapsed: 25, used: 34, at: now),
      now: now))
  let empty = session.projectedEnd.formatted(date: .omitted, time: .shortened)
  #expect(verdict.atRisk)
  #expect(verdict.headline == "Session runs out ≈ \(empty).")
  // 62% left over the remaining 4 hours.
  #expect(verdict.detail.hasPrefix("Slow to 15.5%/h to last until the "))
}

@Test func claudeVerdictFallsBackToWeeklyDailyPace() throws {
  let now = Date(timeIntervalSince1970: 1_790_000_000)
  let verdict = try #require(
    claudeVerdict(
      session: nil, weekly: claudeForecast(minutes: 10080, elapsed: 50, used: 80, at: now),
      now: now))
  #expect(verdict.headline.hasPrefix("Weekly limit runs out ≈ "))
  // 20% left over the remaining 3.5 days.
  #expect(verdict.detail.hasPrefix("Keep under 5.7%/day"))
  #expect(claudeVerdict(session: nil, weekly: nil, now: now) == nil)
}

@Test func claudePanelLabelsUsePointsAndCompactDurations() {
  #expect(claudePaceText(10) == "+10 pts ahead")
  #expect(claudePaceText(-18.04) == "−18 pts behind")
  #expect(claudePaceText(21.46) == "+21.5 pts ahead")
  #expect(claudePaceText(0.01) == "On pace")
  #expect(quotaPercentText(90) == "90%")
  #expect(quotaPercentText(96.54) == "96.5%")
  #expect(quotaDurationLabel(4 * 3_600) == "4h 00m")
  #expect(quotaDurationLabel(2 * 3_600 + 22 * 60) == "2h 22m")
  #expect(quotaDurationLabel(45 * 60) == "45m")
  #expect(quotaDurationLabel(5 * 86_400 + 6 * 3_600) == "5d 6h")
}
