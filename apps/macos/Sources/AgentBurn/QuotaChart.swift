import Charts
import SwiftUI

func quotaChartRecordedStroke(ahead: Bool, color: Color) -> Color {
  ahead ? color : BurnTheme.behind
}

struct QuotaChart: View {
  let forecast: Forecast
  let samples: [QuotaSample]
  let color: Color
  var compact = false
  var range = QuotaChartRange.rte
  var now = Date.now
  var resetLabel = "Reset"
  var height: CGFloat? = nil
  /// Beside a full summary, the idle badge only repeats the hero numbers.
  var idleBadge: Bool? = nil
  /// Split Deck style: no header or day bands, edge-only axis labels, and in-chart
  /// labels for now, even pace, the reset outcome and any lockout before reset.
  var minimal = false
  @State private var selected: Date?
  private var muted: Color { compact || minimal ? BurnTheme.quotaMuted : BurnTheme.muted }
  private var showsBadge: Bool { selected != nil || (idleBadge ?? compact) }
  private var domain: ClosedRange<Date> {
    quotaChartWindow(range: range, forecast: forecast, now: now)
  }
  private var scale: ClosedRange<Date> {
    minimal ? domain : quotaChartScale(range: range, forecast: forecast, now: now)
  }
  private var runsOut: Bool { showsForecast && forecast.projectedEnd < forecast.reset }
  private var gridDates: [Date] { quotaChartGridDates(range: range, forecast: forecast, now: now) }
  private var showsForecast: Bool { range == .rte && forecast.projectedUse != nil }
  private var showsIdeal: Bool { range == .rte || range == .rtd }
  private var showsLatest: Bool { domain.contains(forecast.observedAt) }
  private var cursor: Date { selected ?? forecast.observedAt }
  private var drawnSamples: [QuotaSample] { quotaChartDrawnSamples(samples) }
  private var reading: QuotaChartReading {
    quotaChartReading(at: cursor, samples: drawnSamples, forecast: forecast, range: range)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 8 : 10) {
      if !minimal { header }
      chart
    }
    .id(range.rawValue + domain.lowerBound.formatted() + domain.upperBound.formatted())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Quota forecast")
    .accessibilityValue(accessibilityValue)
    .accessibilityHint("Adjust to move the cursor one day at a time.")
    .accessibilityAdjustableAction { direction in
      selected = quotaChartStep(
        from: cursor, forward: direction == .increment, marks: gridDates, domain: domain)
    }
    .help(
      "Drag across the chart to read remaining quota at any time. Recorded holds until the next live reading, then steps with each drop. Missing collector gaps stay connected. Pace spreads the weekly limit evenly until reset. Forecast projects observed usage until the next reset. The recorded line and fill stay green while remaining is ahead of pace, and turn red where remaining falls behind."
    )
  }

  private var chart: some View {
    Chart {
      if !minimal { dayBands }
      RuleMark(x: .value("Date", domain.lowerBound)).foregroundStyle(.clear)
      RuleMark(x: .value("Date", domain.upperBound)).foregroundStyle(.clear)
      if minimal && runsOut { lockoutBand }
      if showsIdeal { paceBand } else { recordedArea }
      if showsIdeal { idealLine }
      if minimal && showsIdeal { paceLabel }
      recordedLine
      if showsForecast { forecastLine }
      if minimal && showsForecast { forecastEnd }
      if showsIdeal && range == .rte && domain.contains(forecast.reset) { resetRule }
      cursorMarks
    }
    // End padding keeps the centered last axis label inside the chart.
    .chartXScale(
      domain: scale.lowerBound...scale.upperBound,
      range: .plotDimension(endPadding: minimal ? 0 : compact ? 12 : 26)
    )
    // Minimal charts keep headroom above 100% for the "Now" label.
    .chartYScale(domain: 0...100, range: .plotDimension(endPadding: minimal ? 16 : 0))
    .chartXSelection(value: $selected)
    .chartYAxis {
      AxisMarks(
        position: .leading,
        values: minimal ? [0, 100] : compact ? [0, 50, 100] : [0, 25, 50, 75, 100]
      ) { value in
        let isBaseline = minimal && value.as(Int.self) == 0
        AxisGridLine(
          stroke: StrokeStyle(lineWidth: isBaseline ? 1 : 0.5, dash: isBaseline ? [] : [3, 5])
        )
        .foregroundStyle(isBaseline ? BurnTheme.grid : BurnTheme.line)
        AxisValueLabel {
          if let number = value.as(Int.self) {
            Text("\(number)%").foregroundStyle(muted).monospacedDigit()
          }
        }
      }
    }
    .chartXAxis {
      let axisDates =
        minimal
        ? [domain.lowerBound, domain.upperBound]
        : quotaChartAxisDates(range: range, forecast: forecast, now: now)
      AxisMarks(values: gridDates) { _ in
        AxisGridLine(stroke: StrokeStyle(lineWidth: minimal ? 0.5 : 1))
          .foregroundStyle(minimal ? BurnTheme.line : BurnTheme.grid)
      }
      if minimal {
        AxisMarks(values: axisDates) { value in
          AxisValueLabel(
            anchor: value.index == 0 ? .topLeading : .topTrailing, collisionResolution: .disabled
          ) {
            if let date = value.as(Date.self) {
              Text(quotaChartEdgeLabel(date, isStart: value.index == 0, forecast: forecast))
                .foregroundStyle(muted).monospacedDigit()
            }
          }
        }
      } else {
        AxisMarks(values: axisDates) { value in
          AxisTick(length: 4, stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(BurnTheme.grid)
          AxisValueLabel {
            if let date = value.as(Date.self) {
              Text(quotaChartAxisLabel(date, range: range, marks: axisDates, compact: compact))
                .foregroundStyle(muted)
                .monospacedDigit()
            }
          }
        }
      }
    }
    .frame(height: height ?? (compact ? 176 : 214))
  }

  /// Hatched span between the projected run-out and the reset: time without quota.
  @ChartContentBuilder private var lockoutBand: some ChartContent {
    RectangleMark(
      xStart: .value("Empty", forecast.projectedEnd), xEnd: .value("Reset", forecast.reset),
      yStart: .value("Low", 0), yEnd: .value("High", 100)
    )
    .foregroundStyle(quotaLockoutHatch())
    .annotation(position: .overlay, alignment: .center) {
      VStack(spacing: 2) {
        Text("Locked out").font(.system(size: 11, weight: .semibold))
        Text(quotaDurationLabel(forecast.reset.timeIntervalSince(forecast.projectedEnd)))
          .font(.system(size: 10.5)).monospacedDigit()
      }
      .foregroundStyle(BurnTheme.behind)
      .fixedSize()
    }
  }

  /// Names the dashed pace line on the side the recorded line leaves free. The line
  /// falls to the right, so text below it extends left and text above it extends right.
  @ChartContentBuilder private var paceLabel: some ChartContent {
    let date = quotaChartPaceLabelDate(forecast: forecast)
    let ahead =
      forecast.remaining >= quotaChartIdealRemaining(at: forecast.observedAt, forecast: forecast)
    PointMark(
      x: .value("Date", date),
      y: .value("Remaining", quotaChartIdealRemaining(at: date, forecast: forecast))
    )
    .symbolSize(0)
    .annotation(
      position: ahead ? .bottomLeading : .topTrailing, spacing: 2,
      overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
    ) {
      Text("even pace").font(.system(size: 10)).foregroundStyle(muted).fixedSize()
    }
  }

  /// Where the forecast lands: the remaining share at reset, or the run-out time.
  @ChartContentBuilder private var forecastEnd: some ChartContent {
    let stroke = runsOut ? BurnTheme.behind : color
    PointMark(
      x: .value("Date", forecast.projectedEnd),
      y: .value("Remaining", forecast.projectedRemaining)
    )
    .symbol {
      Circle().strokeBorder(stroke, lineWidth: 1.5).background(Circle().fill(.background))
        .frame(width: 7, height: 7)
    }
    .annotation(
      position: runsOut
        ? .topTrailing : forecast.projectedRemaining >= 15 ? .bottomLeading : .topLeading,
      spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
    ) {
      Text(
        runsOut
          ? "Empty " + quotaChartRunOutLabel(forecast)
          : "~" + quotaPercentText(forecast.projectedRemaining) + " at reset"
      )
      .font(.system(size: 11, weight: .semibold)).monospacedDigit()
      .foregroundStyle(stroke)
      .fixedSize()
    }
  }

  @ChartContentBuilder private var dayBands: some ChartContent {
    ForEach(
      Array(quotaChartDayBands(range: range, forecast: forecast, now: now).enumerated()),
      id: \.offset
    ) { _, band in
      if band.isCurrent {
        RectangleMark(
          xStart: .value("Start", band.start), xEnd: .value("End", band.end),
          yStart: .value("Low", 0), yEnd: .value("High", 100)
        )
        .foregroundStyle(color.opacity(0.07))
      }
    }
  }

  @ChartContentBuilder private var paceBand: some ChartContent {
    ForEach(
      Array(quotaChartDeltaSegments(samples: drawnSamples, forecast: forecast).enumerated()),
      id: \.offset
    ) { index, segment in
      ForEach(Array(segment.points.enumerated()), id: \.offset) { _, point in
        AreaMark(
          x: .value("Date", point.date),
          yStart: .value("Pace", point.ideal),
          yEnd: .value("Recorded", point.recorded),
          series: .value("Series", "Pace delta \(index)")
        )
        .foregroundStyle(
          (segment.ahead ? BurnTheme.ahead : BurnTheme.behind).opacity(minimal ? 0.2 : 0.28)
        )
        .interpolationMethod(.linear)
      }
    }
  }

  @ChartContentBuilder private var recordedArea: some ChartContent {
    ForEach(Array(drawnSamples.enumerated()), id: \.offset) { _, sample in
      // Step points share a date; the default stacking would sum them past 100%.
      AreaMark(
        x: .value("Date", sample.date), y: .value("Remaining", sample.remaining),
        series: .value("Series", "Recorded area"), stacking: .unstacked
      )
      .foregroundStyle(color.opacity(0.12))
      .interpolationMethod(.linear)
    }
  }

  @ChartContentBuilder private var idealLine: some ChartContent {
    ForEach([domain.lowerBound, min(domain.upperBound, forecast.reset)], id: \.self) { date in
      LineMark(
        x: .value("Date", date),
        y: .value("Remaining", quotaChartIdealRemaining(at: date, forecast: forecast)),
        series: .value("Series", "Pace")
      )
      .foregroundStyle(muted)
      .lineStyle(StrokeStyle(lineWidth: minimal ? 1.25 : 1.5, dash: minimal ? [3, 4] : [4, 4]))
    }
  }

  @ChartContentBuilder private var recordedLine: some ChartContent {
    if showsIdeal {
      ForEach(
        Array(quotaChartDeltaSegments(samples: drawnSamples, forecast: forecast).enumerated()),
        id: \.offset
      ) { index, segment in
        ForEach(Array(segment.points.enumerated()), id: \.offset) { _, point in
          LineMark(
            x: .value("Date", point.date),
            y: .value("Remaining", point.recorded),
            series: .value("Series", "Recorded \(index)")
          )
          .foregroundStyle(
            minimal ? color : quotaChartRecordedStroke(ahead: segment.ahead, color: color)
          )
          .lineStyle(
            StrokeStyle(lineWidth: minimal ? 2.25 : 2.5, lineCap: .round, lineJoin: .round)
          )
          .interpolationMethod(.linear)
        }
      }
    } else {
      ForEach(
        Array(
          quotaRecordedSegments(drawnSamples, connectGaps: range.connectsRecordedGaps).enumerated()
        ),
        id: \.offset
      ) { index, segment in
        ForEach(Array(segment.enumerated()), id: \.offset) { _, sample in
          LineMark(
            x: .value("Date", sample.date), y: .value("Remaining", sample.remaining),
            series: .value("Series", "Recorded \(index)")
          )
          .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2.5))
          .interpolationMethod(.linear)
          if segment.count == 1 {
            PointMark(x: .value("Date", sample.date), y: .value("Remaining", sample.remaining))
              .foregroundStyle(color).symbolSize(18)
          }
        }
      }
    }
  }

  @ChartContentBuilder private var forecastLine: some ChartContent {
    ForEach([0, 1], id: \.self) { index in
      LineMark(
        x: .value("Date", index == 0 ? forecast.observedAt : forecast.projectedEnd),
        y: .value("Remaining", index == 0 ? forecast.remaining : forecast.projectedRemaining),
        series: .value("Series", "Forecast")
      )
      .foregroundStyle(forecastStroke.opacity(minimal ? 0.85 : 0.8))
      .lineStyle(StrokeStyle(lineWidth: minimal ? 1.75 : 2, dash: minimal ? [5, 4] : [6, 5]))
    }
  }

  @ChartContentBuilder private var resetRule: some ChartContent {
    let rule = RuleMark(x: .value("Date", forecast.reset))
      .foregroundStyle(muted.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
    if minimal {
      rule
    } else {
      rule.annotation(position: .leading, alignment: .top, spacing: 4) {
        Text(resetLabel).font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
      }
    }
  }

  @ChartContentBuilder private var cursorMarks: some ChartContent {
    if domain.contains(cursor) {
      if minimal && selected == nil {
        RuleMark(x: .value("Date", cursor), yStart: .value("Low", 0), yEnd: .value("High", 100))
          .foregroundStyle(color.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1))
          .annotation(
            position: .top, spacing: 3,
            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
          ) {
            Text("Now").font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
          }
      } else {
        RuleMark(x: .value("Date", cursor))
          .foregroundStyle(color.opacity(selected == nil ? 0.35 : 0.5))
          .lineStyle(StrokeStyle(lineWidth: 1))
      }
      if let value = reading.value {
        let point = PointMark(x: .value("Date", cursor), y: .value("Remaining", value))
          .foregroundStyle(reading.projected ? cursorStroke.opacity(0.6) : cursorStroke)
          .symbolSize(reading.projected ? 30 : 48)
        if showsBadge {
          point.annotation(
            position: .top, spacing: compact ? 4 : 8,
            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
          ) {
            deltaBadge
          }
        } else {
          point
        }
      }
    }
  }

  private var deltaBadge: some View {
    let delta = reading.paceDelta
    let tone: Color = delta.map { $0 < -0.05 ? BurnTheme.behind : BurnTheme.ahead } ?? muted
    return HStack(spacing: compact ? 3 : 6) {
      Text(quotaChartPercentLabel(reading.value))
        .foregroundStyle(BurnTheme.ink.opacity(compact ? 0.88 : 0.94))
      if let text = badgeDelta(delta) {
        Text("·").foregroundStyle(muted.opacity(0.55))
        Text(text).foregroundStyle(tone.opacity(0.88))
      }
    }
    .font(.system(size: compact ? 9.5 : 11, weight: .medium)).monospacedDigit()
    .padding(.horizontal, compact ? 6 : 8).padding(.vertical, compact ? 2.5 : 4)
    .background {
      Capsule()
        .fill(.ultraThinMaterial)
        .opacity(compact ? 0.58 : 0.86)
    }
    .overlay(Capsule().stroke(Color.white.opacity(compact ? 0.10 : 0.16), lineWidth: 0.5))
  }

  private func badgeDelta(_ delta: Double?) -> String? {
    guard let delta else { return nil }
    if compact {
      if abs(delta) < 0.05 { return "pace" }
      let magnitude = abs(delta).formatted(.number.precision(.fractionLength(1)))
      return delta > 0 ? "+\(magnitude)%" : "−\(magnitude)%"
    }
    return quotaChartDeltaText(delta)
  }

  private var header: some View {
    Group {
      if compact {
        cursorLabel
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          headerSeries
          Spacer(minLength: 4)
          cursorLabel
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var cursorLabel: some View {
    let date = quotaChartCursorLabel(cursor, range: range)
    let prefix = reading.projected ? "Projected · " : selected == nil ? "Latest · " : ""
    let short =
      range == .today
      ? date : cursor.formatted(.dateTime.month(.defaultDigits).day().hour())
    return ViewThatFits(in: .horizontal) {
      cursorText(prefix + date).fixedSize()
      cursorText(date).fixedSize()
      cursorText(short).fixedSize()
      cursorText(short).minimumScaleFactor(0.8)
    }
  }

  private func cursorText(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 12)).foregroundStyle(muted).monospacedDigit()
      .lineLimit(1)
  }

  private var cursorStroke: Color {
    if minimal && !reading.projected { return color }
    return quotaChartRecordedStroke(ahead: (reading.paceDelta ?? 0) >= 0, color: color)
  }

  private var forecastStroke: Color {
    if minimal { return runsOut ? BurnTheme.behind : color }
    return quotaChartRecordedStroke(
      ahead: forecast.remaining
        >= quotaChartIdealRemaining(
          at: forecast.observedAt, forecast: forecast),
      color: color)
  }

  private var headerSeries: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      series("Recorded", reading.recorded, color: cursorStroke, dashed: false)
      if showsForecast { series("Forecast", reading.forecast, color: forecastStroke, dashed: true) }
      if showsIdeal { series("Pace", reading.ideal, color: muted, dashed: true) }
    }
  }

  private var accessibilityValue: String {
    var parts = [
      "\(quotaChartPercentLabel(reading.value)) remaining at \(quotaChartCursorLabel(cursor, range: range))"
    ]
    if let delta = quotaChartDeltaText(reading.paceDelta) { parts.append(delta + " pace") }
    if reading.projected { parts.append("Projected") }
    parts.append(range.label)
    return parts.joined(separator: ". ") + "."
  }

  private func series(_ title: String, _ value: Double?, color: Color, dashed: Bool) -> some View {
    HStack(spacing: 5) {
      Path { path in
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 12, y: 0))
      }
      .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 3] : []))
      .frame(width: 12, height: 1)
      Text(title).foregroundStyle(muted)
      Text(quotaChartPercentLabel(value)).foregroundStyle(BurnTheme.ink).monospacedDigit()
    }
    .font(.system(size: 12))
    .lineLimit(1)
    .fixedSize()
  }
}

/// Edge labels for a minimal until-reset chart: clock times for short windows,
/// weekday and day at the start of longer windows, weekday and time at the reset.
func quotaChartEdgeLabel(_ date: Date, isStart: Bool, forecast: Forecast) -> String {
  if forecast.duration <= 86_400 { return date.formatted(date: .omitted, time: .shortened) }
  return isStart
    ? date.formatted(.dateTime.weekday(.abbreviated).day())
    : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

/// Short run-out label for the chart: the time within a day, the weekday otherwise.
func quotaChartRunOutLabel(_ forecast: Forecast) -> String {
  forecast.duration <= 86_400
    ? forecast.projectedEnd.formatted(date: .omitted, time: .shortened)
    : forecast.projectedEnd.formatted(.dateTime.weekday(.abbreviated))
}

/// Places the "even pace" label ahead of now, before any run-out, or behind now
/// when too little of the window is left to fit it.
func quotaChartPaceLabelDate(forecast: Forecast) -> Date {
  let end = forecast.projectedEnd.timeIntervalSince(forecast.start) / forecast.duration
  let fraction =
    end - forecast.elapsed >= 0.25
    ? forecast.elapsed + (end - forecast.elapsed) * 0.5 : forecast.elapsed * 0.5
  return forecast.start.addingTimeInterval(forecast.duration * fraction)
}

/// Whole percentages stay whole ("90%"); anything else keeps one decimal ("96.5%").
func quotaPercentText(_ value: Double) -> String {
  value.formatted(.number.precision(.fractionLength(0...1))) + "%"
}

/// "2h 22m", "45m", or "1d 4h" for spans longer than a day.
func quotaDurationLabel(_ seconds: TimeInterval) -> String {
  let minutes = Int(max(0, seconds) / 60)
  let days = minutes / 1_440
  let hours = minutes % 1_440 / 60
  if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
  if hours > 0 { return String(format: "%dh %02dm", hours, minutes % 60) }
  return "\(minutes)m"
}

/// Diagonal red hatching for the time between a projected run-out and the reset.
func quotaLockoutHatch() -> ImagePaint {
  let size: CGFloat = 6
  let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    NSColor.systemRed.withAlphaComponent(0.3).setStroke()
    let path = NSBezierPath()
    path.lineWidth = 1.6
    for offset in [-size, 0, size] {
      path.move(to: NSPoint(x: offset - 1, y: -1))
      path.line(to: NSPoint(x: offset + size + 1, y: size + 1))
    }
    path.stroke()
    return true
  }
  return ImagePaint(image: Image(nsImage: image))
}
