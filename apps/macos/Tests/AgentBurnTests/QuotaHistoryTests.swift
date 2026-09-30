import Foundation
import Testing

@testable import AgentBurn

private func reading(_ percent: Double = 14, date: Date = .now) -> QuotaReading {
  QuotaReading(
    agent: "codex", observedAt: date.timeIntervalSince1970 * 1000,
    window: QuotaWindow(
      windowMinutes: 10080, usedPercent: percent, elapsedPercent: 20, apiEquivalentSpent: 0))
}

private func reading(
  _ percent: Double, elapsed: Double, date: Date, agent: String = "codex"
) -> QuotaReading {
  QuotaReading(
    agent: agent, observedAt: date.timeIntervalSince1970 * 1000,
    window: QuotaWindow(
      windowMinutes: 10080, usedPercent: percent, elapsedPercent: elapsed, apiEquivalentSpent: 0))
}

@Test func quotaHistoryCountsScheduledAndPossibleResets() {
  var history = QuotaHistory()
  let start = Date(timeIntervalSince1970: 1_000_000)
  history.record(reading(90, elapsed: 95, date: start), source: "test")
  history.record(reading(4, elapsed: 2, date: start.addingTimeInterval(60)), source: "test")
  history.record(reading(50, elapsed: 40, date: start.addingTimeInterval(120)), source: "test")
  history.record(reading(8, elapsed: 41, date: start.addingTimeInterval(180)), source: "test")
  let resets = history.resets(agent: "codex", source: "test")
  #expect(resets.map(\.scheduled) == [true, false])
  #expect(resets.count == 2)
}

@Test func quotaHistoryDropsOverCountsContradictedWithinTheSameWindow() {
  var history = QuotaHistory()
  let start = Date(timeIntervalSince1970: 1_000_000)
  let week = 10080.0 * 60
  // Same window: elapsed advances with the clock, so every reading shares one start.
  for (index, used) in [40.0, 42, 85, 87, 43, 88, 44].enumerated() {
    let offset = Double(index) * 600
    history.record(
      reading(used, elapsed: 50 + offset / week * 100, date: start.addingTimeInterval(offset)),
      source: "test")
  }
  // A genuine reset starts a new window and is still kept and counted.
  history.record(reading(1, elapsed: 0.5, date: start.addingTimeInterval(4_800)), source: "test")

  let remaining = history.samples(agent: "codex", source: "test").map(\.remaining)
  #expect(remaining == [60, 58, 57, 56, 99])
  #expect(history.resets(agent: "codex", source: "test").count == 1)
}

@Test func quotaHistoryHoldsAnUnconfirmedWeeklySpikeBack() {
  var history = QuotaHistory()
  let start = Date(timeIntervalSince1970: 1_000_000)
  let week = 10080.0 * 60
  func record(_ used: Double, after offset: TimeInterval) {
    history.record(
      reading(used, elapsed: 50 + offset / week * 100, date: start.addingTimeInterval(offset)),
      source: "test")
  }
  for (index, used) in [50.0, 100, 50, 100].enumerated() { record(used, after: Double(index) * 60) }
  #expect(history.current(agent: "codex", source: "test")?.window.usedPercent == 50)
  #expect(history.samples(agent: "codex", source: "test").map(\.remaining) == [50, 50])
  #expect(history.resets(agent: "codex", source: "test").isEmpty)

  // Half an hour without a lower reading confirms the new level.
  record(100, after: 2_400)
  #expect(history.current(agent: "codex", source: "test")?.window.usedPercent == 100)
  #expect(history.samples(agent: "codex", source: "test").map(\.remaining) == [50, 50, 0, 0])
}

@Test func quotaHistoryShowsFastSessionGrowthAsIs() {
  var history = QuotaHistory()
  let start = Date(timeIntervalSince1970: 1_000_000)
  for (index, used) in [10.0, 30].enumerated() {
    history.record(
      QuotaReading(
        agent: "claude-session",
        observedAt: (start.timeIntervalSince1970 + Double(index) * 60) * 1000,
        window: QuotaWindow(
          windowMinutes: 300, usedPercent: used, elapsedPercent: 20 + Double(index) / 3,
          apiEquivalentSpent: 0)),
      source: "test")
  }
  #expect(history.current(agent: "claude-session", source: "test")?.window.usedPercent == 30)
}

@Test func quotaHistorySurvivesCollectorFailureAndCorruptPrimary() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = QuotaHistoryFile(directory: directory)
  var history = QuotaHistory()
  history.record(reading(), source: "test")
  try file.save(history)
  history.fail(agent: "codex", source: "test", message: "Network unavailable")
  try file.save(history)
  #expect(try file.load()?.latest(agent: "codex", source: "test")?.window.usedPercent == 14)
  try Data("broken".utf8).write(to: file.url)
  #expect(try file.load()?.latest(agent: "codex", source: "test")?.window.usedPercent == 14)
}

@Test func quotaCommitsMergeConcurrentWritersAndJournalEveryReading() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = QuotaHistoryFile(directory: directory)
  let source = "|/a,/b"
  let start = Date(timeIntervalSince1970: 1_800_000_000)
  var existing = QuotaHistory()
  existing.record(reading(10, elapsed: 5, date: start, agent: "claude"), source: source)
  try file.save(existing)
  // A stale in-memory copy from another writer must not erase the collector's row.
  try file.commit(
    [reading(20, elapsed: 6, date: start.addingTimeInterval(60), agent: "claude")], source: source)
  try file.commit(
    [reading(30, elapsed: 7, date: start.addingTimeInterval(60), agent: "claude-session")],
    source: source)
  let merged = try #require(try file.load())
  #expect(merged.samples(agent: "claude", source: source).map(\.remaining) == [90, 80])
  #expect(merged.latest(agent: "claude-session", source: source)?.window.usedPercent == 30)

  let csv = try String(contentsOf: file.journal.url, encoding: .utf8)
  #expect(csv.split(separator: "\n").count == 4)
  #expect(csv.hasPrefix(QuotaJournal.header.joined(separator: ",")))
  #expect(csv.contains("\"|/a,/b\",claude,10080,20,80,6"))

  try FileManager.default.removeItem(at: file.url)
  try Data("broken".utf8).write(to: file.url.appendingPathExtension("bak"))
  let rebuilt = try #require(try file.load())
  #expect(rebuilt.samples(agent: "claude", source: source).map(\.remaining) == [90, 80])
  #expect(
    rebuilt.latest(agent: "claude-session", source: source)?.date == start.addingTimeInterval(60))
}

@Test func claudeSessionReadingUsesProviderObservationTime() throws {
  let observed = Date(timeIntervalSince1970: 1_800_000_000)
  let account = ClaudeAccount(
    sessionUsedPercent: 40,
    sessionResetsAtMs: observed.addingTimeInterval(3 * 3600)
      .timeIntervalSince1970 * 1000,
    observedAtMs: observed.timeIntervalSince1970 * 1000)
  let session = try #require(
    claudeSessionReading(account, now: observed.addingTimeInterval(600)))
  #expect(session.date == observed)
  #expect(abs(session.window.elapsedPercent - 40) < 0.001)
}

@Test func quotaHistoryRejectsInvalidAndDuplicateMeasurements() {
  var history = QuotaHistory()
  let sample = reading()
  history.record(sample, source: "test")
  history.record(sample, source: "test")
  history.record(reading(-1), source: "test")
  #expect(history.samples(agent: "codex", source: "test").count == 1)
  #expect(history.latest(agent: "codex", source: "other") == nil)
}

@Test @MainActor func quotaGraphLoadsWithoutCLIOrReportCache() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let suite = "quota-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }
  defaults.set("/missing/cli", forKey: "cliPath")
  defaults.set("/test/codex", forKey: "codexHomes")
  var history = QuotaHistory()
  history.record(reading(), source: "/missing/cli|/test/codex")
  try QuotaHistoryFile(directory: directory).save(history)
  let store = UsageStore(defaults: defaults, storageDirectory: directory)
  #expect(store.forecast(for: "codex")?.remaining == 86)
  #expect(store.samples(for: "codex").map(\.remaining) == [100, 86])
}

@Test func headlessCollectorPersistsSuccessWhileAnotherProviderFails() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let executable = directory.appendingPathComponent("quota fixture")
  let json = String(decoding: try JSONEncoder().encode(reading()), as: UTF8.self)
  try Data(
    """
    #!/bin/sh
    [ "$AGENT_BURN_QUOTA_ONLY" = 1 ] || exit 3
    [ "$2" = codex ] || exit 4
    printf '%s' '\(json)'
    """.utf8
  ).write(to: executable)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  let config = QuotaCollectorConfig(customPath: executable.path, codexHomes: "/test")
  try config.save(directory: directory)
  try await QuotaCollector.collect(directory: directory)
  let saved = try #require(try QuotaHistoryFile(directory: directory).load())
  #expect(saved.latest(agent: "codex", source: config.source)?.window.usedPercent == 14)
  #expect(saved.failures[config.source]?["claude"] != nil)
  #expect(saved.samples(agent: "claude", source: config.source).isEmpty)
}

@Test @MainActor func enabledButStalledCollectorRefreshesDisplayedQuota() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let suite = "quota-recovery-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let executable = directory.appendingPathComponent("quota fixture")
  let payload = directory.appendingPathComponent("reading.json")
  try Data(
    """
    #!/bin/sh
    [ "$AGENT_BURN_QUOTA_ONLY" = 1 ] || exit 3
    [ "$2" = codex ] || exit 4
    cat '\(payload.path)'
    """.utf8
  ).write(to: executable)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  defaults.set(executable.path, forKey: "cliPath")
  defaults.set("/test", forKey: "codexHomes")
  try JSONEncoder().encode(reading(58)).write(to: payload)
  let store = UsageStore(defaults: defaults, storageDirectory: directory)
  await store.collectQuotasNow()
  #expect(store.remainingPercent == 42)
  let next = Date.now.addingTimeInterval(61)
  try JSONEncoder().encode(reading(60)).write(to: payload)
  await store.refreshQuotasIfNeeded(backgroundAvailable: true, now: next)
  #expect(store.remainingPercent == 40)
  #expect(!store.quotaIsStale(at: .now))
  // A failing second provider must not trigger a retry on every five-second tick.
  try JSONEncoder().encode(reading(70)).write(to: payload)
  await store.refreshQuotasIfNeeded(backgroundAvailable: true)
  #expect(store.remainingPercent == 40)
}
