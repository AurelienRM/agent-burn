import Charts
import SwiftUI

struct LimitUsageDay: Codable, Sendable, Identifiable {
  let date: String
  let usedPercent: Double
  let surfaces: [LimitUsageSurface]
  let models: [LimitUsageModel]
  var id: String { date }
}

struct LimitUsageSurface: Codable, Sendable {
  let surface: String
  let usedPercent: Double
}

struct LimitUsageModel: Codable, Sendable {
  let model: String
  let speed: String?
  let usedPercent: Double
}

enum LimitUsageGrouping: String, CaseIterable, Identifiable {
  case surface, model
  var id: String { rawValue }
  var label: String {
    self == .surface ? String(localized: "Surface") : String(localized: "Model")
  }
}

struct LimitUsageSegment: Identifiable, Equatable {
  let date: Date
  let day: String
  let series: String
  let usedPercent: Double
  var id: String { day + series }
}

private let limitUsageSeriesLimit = 5
let limitUsageOtherSeries = String(localized: "Other")

func limitUsageSurfaceLabel(_ surface: String) -> String {
  switch surface {
  case "cli": "CLI"
  case "exec": "Exec"
  case "desktop_app": String(localized: "Desktop app")
  case "work_desktop": String(localized: "Desktop app (work)")
  case "vscode": String(localized: "IDE extension")
  case "jetbrains": "JetBrains"
  case "web": String(localized: "Cloud")
  case "work_web": String(localized: "Cloud (work)")
  case "mobile": String(localized: "Mobile")
  case "work_mobile": String(localized: "Mobile (work)")
  case "github": "GitHub"
  case "github_code_review": String(localized: "Code review")
  case "slack": "Slack"
  case "linear": "Linear"
  case "sdk": "SDK"
  case "agent_identity": String(localized: "Agent identity")
  default: limitUsageOtherSeries
  }
}

func limitUsageModelLabel(_ model: LimitUsageModel) -> String {
  model.speed == "fast" ? String(localized: "\(model.model) fast") : model.model
}

/// Stacked segments per day, keeping the largest series over the period and
/// folding the tail into "Other" so the legend stays readable.
func limitUsageSegments(_ days: [LimitUsageDay], grouping: LimitUsageGrouping)
  -> [LimitUsageSegment]
{
  let perDay: [(LimitUsageDay, [(String, Double)])] = days.map { day in
    let values =
      grouping == .surface
      ? day.surfaces.map { (limitUsageSurfaceLabel($0.surface), $0.usedPercent) }
      : day.models.map { (limitUsageModelLabel($0), $0.usedPercent) }
    return (day, values)
  }
  var totals: [String: Double] = [:]
  for (_, values) in perDay {
    for (series, percent) in values { totals[series, default: 0] += percent }
  }
  let kept = Set(
    totals.filter { $0.key != limitUsageOtherSeries }
      .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
      .prefix(limitUsageSeriesLimit).map(\.key))
  return perDay.flatMap { day, values -> [LimitUsageSegment] in
    guard let date = usageDayDate(day.date) else { return [] }
    var grouped: [String: Double] = [:]
    for (series, percent) in values {
      grouped[kept.contains(series) ? series : limitUsageOtherSeries, default: 0] += percent
    }
    return grouped.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map {
      LimitUsageSegment(date: date, day: day.date, series: $0.key, usedPercent: $0.value)
    }
  }
}

struct CodexLimitUsageChart: View {
  let days: [LimitUsageDay]
  @State private var grouping = LimitUsageGrouping.surface
  @State private var selected: Date?

  private var segments: [LimitUsageSegment] {
    limitUsageSegments(days, grouping: grouping)
  }
  private var seriesOrder: [String] {
    var totals: [String: Double] = [:]
    for segment in segments { totals[segment.series, default: 0] += segment.usedPercent }
    return totals.sorted { lhs, rhs in
      if lhs.key == limitUsageOtherSeries { return false }
      if rhs.key == limitUsageOtherSeries { return true }
      return lhs.value > rhs.value
    }.map(\.key)
  }
  private var selectedDay: LimitUsageDay? {
    guard let selected else { return nil }
    let key = quotaDayKey(selected)
    return days.first { $0.date == key }
  }
  private var total: Double { days.reduce(0) { $0 + $1.usedPercent } }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Weekly limit used per day").font(.headline)
        Picker("Group by", selection: $grouping) {
          ForEach(LimitUsageGrouping.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).frame(width: 160).labelsHidden()
        .accessibilityLabel("Group weekly limit usage by")
        Spacer()
        Text(
          selectedDay.map(tooltip)
            ?? String(localized: "\(percentLabel(total)) over \(days.count) days")
        )
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Chart {
        ForEach(segments) { segment in
          BarMark(
            x: .value("Day", segment.date, unit: .day),
            y: .value("Weekly limit", segment.usedPercent)
          )
          .foregroundStyle(by: .value("Series", segment.series))
          .accessibilityLabel(segment.day + " " + segment.series)
          .accessibilityValue(percentLabel(segment.usedPercent))
        }
        if let selected {
          RuleMark(x: .value("Day", selected, unit: .day)).foregroundStyle(.secondary.opacity(0.4))
        }
      }
      .chartForegroundStyleScale(domain: seriesOrder)
      .chartXSelection(value: $selected)
      .chartYAxis {
        AxisMarks(position: .leading) { value in
          AxisGridLine()
          AxisValueLabel { if let percent = value.as(Double.self) { Text(percentLabel(percent)) } }
        }
      }
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
          AxisValueLabel(format: .dateTime.month(.abbreviated).day())
        }
      }
      .chartLegend(position: .bottom, alignment: .leading)
      .frame(height: 210)
      Text(
        "Share of the weekly limit consumed each day, as reported by ChatGPT’s Codex usage dashboard."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func tooltip(_ day: LimitUsageDay) -> String {
    let parts =
      grouping == .surface
      ? day.surfaces.prefix(3).map {
        "\(limitUsageSurfaceLabel($0.surface)) \(percentLabel($0.usedPercent))"
      }
      : day.models.prefix(3).map { "\(limitUsageModelLabel($0)) \(percentLabel($0.usedPercent))" }
    return ([day.date + " · " + percentLabel(day.usedPercent)] + parts).joined(separator: " · ")
  }

  private func percentLabel(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0))) + "%"
  }
}
