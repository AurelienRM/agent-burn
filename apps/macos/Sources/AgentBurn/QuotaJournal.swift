import Foundation

/// Append-only CSV mirror of every accepted quota reading. The JSON archive is
/// rewritten on each collection; this journal only ever grows, so a crash,
/// a bad write, or a lost archive can always be rebuilt from it.
struct QuotaJournal {
  static let fileName = "quota-readings.csv"
  static let header = [
    "observed_at", "observed_at_ms", "source", "agent", "window_minutes", "used_percent",
    "remaining_percent", "elapsed_percent", "resets_at", "api_equivalent_spent",
  ]

  let directory: URL
  var url: URL { directory.appendingPathComponent(Self.fileName) }

  /// Writes the whole archive once, so the journal starts complete.
  func seedIfMissing(from history: QuotaHistory) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    let rows = history.readings.flatMap { source, agents in
      agents.values.flatMap { $0.map { (source, $0) } }
    }
    .sorted { $0.1.observedAt < $1.1.observedAt }
    try append(rows)
  }

  func append(_ rows: [(source: String, reading: QuotaReading)]) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let isNew = !FileManager.default.fileExists(atPath: url.path)
    var text = isNew ? Self.line(Self.header) : ""
    for row in rows { text += Self.line(Self.fields(row.reading, source: row.source)) }
    guard !text.isEmpty else { return }
    if isNew {
      try Data(text.utf8).write(to: url, options: .atomic)
      return
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
  }

  /// Rebuilds readings in observation order; unreadable rows are skipped.
  func load() throws -> QuotaHistory? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let text = try String(contentsOf: url, encoding: .utf8)
    let rows = text.split(whereSeparator: \.isNewline).dropFirst().compactMap {
      Self.reading(Self.parse(String($0)))
    }
    guard !rows.isEmpty else { return nil }
    var history = QuotaHistory()
    for row in rows.sorted(by: { $0.reading.observedAt < $1.reading.observedAt }) {
      history.record(row.reading, source: row.source)
    }
    return history
  }

  private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  private static func fields(_ reading: QuotaReading, source: String) -> [String] {
    let window = reading.window
    let resetsAt = reading.date.addingTimeInterval(
      (100 - window.elapsedPercent) / 100 * window.windowMinutes * 60)
    return [
      timestamp.format(reading.date), String(Int64(reading.observedAt)), source,
      reading.agent, number(window.windowMinutes), number(window.usedPercent),
      number(100 - window.usedPercent), number(window.elapsedPercent),
      timestamp.format(resetsAt), number(window.apiEquivalentSpent),
    ]
  }

  private static func reading(_ fields: [String]) -> (source: String, reading: QuotaReading)? {
    guard fields.count >= header.count, let observedAt = Double(fields[1]),
      let minutes = Double(fields[4]), let used = Double(fields[5]),
      let elapsed = Double(fields[7]), let spent = Double(fields[9])
    else { return nil }
    let reading = QuotaReading(
      agent: fields[3], observedAt: observedAt,
      window: QuotaWindow(
        windowMinutes: minutes, usedPercent: used, elapsedPercent: elapsed,
        apiEquivalentSpent: spent))
    return reading.window.isValid ? (fields[2], reading) : nil
  }

  private static func number(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 1e15
      ? String(Int64(value)) : String(format: "%.4f", value)
  }

  private static func line(_ fields: [String]) -> String {
    fields.map { field in
      field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
        ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
    }.joined(separator: ",") + "\n"
  }

  private static func parse(_ line: String) -> [String] {
    var fields: [String] = []
    var field = ""
    var quoted = false
    var iterator = line.makeIterator()
    while let character = iterator.next() {
      if quoted {
        if character == "\"" {
          if let next = iterator.next() {
            if next == "\"" {
              field.append("\"")
            } else {
              quoted = false
              if next == "," {
                fields.append(field)
                field = ""
              } else {
                field.append(next)
              }
            }
          } else {
            quoted = false
          }
        } else {
          field.append(character)
        }
      } else if character == "\"" {
        quoted = true
      } else if character == "," {
        fields.append(field)
        field = ""
      } else {
        field.append(character)
      }
    }
    fields.append(field)
    return fields
  }
}
