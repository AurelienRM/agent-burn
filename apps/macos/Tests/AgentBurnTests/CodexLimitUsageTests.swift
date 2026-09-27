import Foundation
import Testing

@testable import AgentBurn

@Test func decodesCodexLimitUsageFromHarnessReport() throws {
  let json = """
    {"agent":"codex","plan":"Pro","liveLimits":true,"window":null,"apiEquivalentPerMonth":0,
     "daily":[],"topModels":[],"pricePerMonth":null,"economics":null,"estimate":null,
     "spendMix":null,"weeklyTrend":null,"imageGenerations":null,
     "limitUsageDaily":[{"date":"2026-09-22","usedPercent":52.9,
       "surfaces":[{"surface":"desktop_app","usedPercent":44.0},{"surface":"cli","usedPercent":8.9}],
       "models":[{"model":"gpt-5.6-sol","speed":"fast","usedPercent":52.9}]}]}
    """
  let report = try JSONDecoder().decode(HarnessReport.self, from: Data(json.utf8))
  let day = try #require(report.limitUsageDaily?.first)
  #expect(day.usedPercent == 52.9)
  #expect(day.surfaces.map(\.surface) == ["desktop_app", "cli"])
  #expect(limitUsageModelLabel(day.models[0]) == "gpt-5.6-sol fast")
}

@Test func limitUsageSegmentsFoldTailSeriesIntoOther() {
  let surfaces = ["cli", "exec", "desktop_app", "vscode", "web", "slack", "linear"]
  let day = LimitUsageDay(
    date: "2026-09-22", usedPercent: 28,
    surfaces: surfaces.enumerated().map {
      LimitUsageSurface(surface: $0.element, usedPercent: Double(7 - $0.offset))
    },
    models: [])

  let segments = limitUsageSegments([day], grouping: .surface)

  #expect(segments.count == 6)
  #expect(segments.first { $0.series == "Other" }?.usedPercent == 3)
  #expect(segments.reduce(0) { $0 + $1.usedPercent } == 28)
}
