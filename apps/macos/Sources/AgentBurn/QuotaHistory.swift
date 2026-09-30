import Foundation

struct QuotaReading: Codable, Sendable {
  let agent: String
  let observedAt: Double
  let window: QuotaWindow
  var date: Date { Date(timeIntervalSince1970: observedAt / 1000) }
  /// Start of the limit window this reading belongs to, derived from the
  /// provider-reported elapsed percent. Readings from the same cycle share
  /// the same start; a provider hiccup can briefly replay a superseded
  /// cycle (same old start, new timestamp), which must not rewind the chart.
  var windowStart: Date {
    date.addingTimeInterval(-window.elapsedPercent / 100 * max(1, window.windowMinutes * 60))
  }
}

struct QuotaReset: Equatable {
  let date: Date
  let scheduled: Bool
}

struct QuotaHistory: Codable {
  var version = 1
  var readings: [String: [String: [QuotaReading]]] = [:]
  var failures: [String: [String: String]] = [:]

  @discardableResult
  mutating func record(_ reading: QuotaReading, source: String) -> Bool {
    guard reading.observedAt.isFinite, reading.window.isValid,
      reading.observedAt > (latest(agent: reading.agent, source: source)?.observedAt ?? 0)
    else { return false }
    readings[source, default: [:]][reading.agent, default: []].append(reading)
    failures[source]?[reading.agent] = nil
    return true
  }

  mutating func fail(agent: String, source: String, message: String) {
    failures[source, default: [:]][agent] = message
  }

  func latest(agent: String, source: String) -> QuotaReading? {
    readings[source]?[agent]?.last
  }

  /// Readings with stale replays and over-counts removed. A new window start
  /// means a genuine reset and starts a new segment, but a reading whose window
  /// start matches an older, superseded segment is a provider replay of that old
  /// cycle and is skipped so it cannot carve a dip into the chart. Usage never
  /// falls within one window, so a later, lower reading of the same segment
  /// proves the higher ones before it were provider over-counts (Codex served
  /// 99% while enforcing 49%); those are skipped too.
  func cycleConsistentReadings(agent: String, source: String) -> [QuotaReading] {
    var kept: [(reading: QuotaReading, segment: Int)] = []
    var segmentStarts: [Date] = []
    for reading in readings[source]?[agent] ?? [] {
      let start = reading.windowStart
      if let last = segmentStarts.last, abs(start.timeIntervalSince(last)) <= 300 {
        kept.append((reading, segmentStarts.count - 1))
      } else if segmentStarts.contains(where: { abs(start.timeIntervalSince($0)) <= 300 }) {
        continue
      } else {
        segmentStarts.append(start)
        kept.append((reading, segmentStarts.count - 1))
      }
    }
    var lowestLater: [Int: Double] = [:]
    var consistent: [QuotaReading] = []
    for (reading, segment) in kept.reversed() {
      let used = reading.window.usedPercent
      if let floor = lowestLater[segment], used > floor + 1 { continue }
      lowestLater[segment] = min(used, lowestLater[segment] ?? used)
      consistent.append(reading)
    }
    return consistent.reversed()
  }

  func samples(agent: String, source: String) -> [QuotaSample] {
    cycleConsistentReadings(agent: agent, source: source).map {
      QuotaSample(date: $0.date, remaining: 100 - $0.window.usedPercent)
    }
  }

  func resets(agent: String, source: String) -> [QuotaReset] {
    let points = cycleConsistentReadings(agent: agent, source: source)
    var found: [QuotaReset] = []
    for (index, reading) in points.enumerated() {
      guard index > 0 else { continue }
      let previous = points[index - 1]
      let remaining = 100 - reading.window.usedPercent
      let previousRemaining = 100 - previous.window.usedPercent
      guard remaining > previousRemaining + 1 else { continue }
      found.append(
        QuotaReset(
          date: reading.date,
          scheduled: previous.window.elapsedPercent >= 80 && reading.window.elapsedPercent <= 20
        ))
    }
    return found
  }
}

struct QuotaHistoryFile {
  let directory: URL
  var url: URL { directory.appendingPathComponent("quota-archive.json") }
  private var backup: URL { url.appendingPathExtension("bak") }

  private func decode(_ data: Data) throws -> QuotaHistory {
    let history = try JSONDecoder().decode(QuotaHistory.self, from: data)
    guard history.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
    return history
  }

  var journal: QuotaJournal { QuotaJournal(directory: directory) }

  /// Archive, then its backup, then a rebuild from the append-only CSV journal.
  func load() throws -> QuotaHistory? {
    var failure: Error?
    for candidate in [url, backup] where FileManager.default.fileExists(atPath: candidate.path) {
      do { return try decode(Data(contentsOf: candidate)) } catch { failure = failure ?? error }
    }
    if let rebuilt = try? journal.load() { return rebuilt }
    if let failure { throw failure }
    return nil
  }

  /// Merges readings into the latest archive on disk so concurrent writers
  /// (the app and the background collector) never drop each other's rows.
  @discardableResult
  func commit(
    _ readings: [QuotaReading], source: String,
    failures: [String: String?] = [:]
  ) throws -> QuotaHistory {
    var history = (try? load()) ?? QuotaHistory()
    try? journal.seedIfMissing(from: history)
    let accepted = readings.filter { history.record($0, source: source) }
    for (agent, message) in failures {
      if let message {
        history.fail(agent: agent, source: source, message: message)
      } else {
        history.failures[source]?[agent] = nil
      }
    }
    try? journal.append(accepted.map { (source, $0) })
    try save(history)
    return history
  }

  func save(_ history: QuotaHistory) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    if let data = try? Data(contentsOf: url), (try? decode(data)) != nil {
      try data.write(to: backup, options: .atomic)
    }
    try JSONEncoder().encode(history).write(to: url, options: .atomic)
  }
}
