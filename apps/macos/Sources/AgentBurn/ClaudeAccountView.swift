import SwiftUI

struct ClaudeAccount: Codable, Sendable {
  let sessionUsedPercent: Double?
  let sessionResetsAtMs: Double?
  let weeklyUsedPercent: Double?
  let weeklyResetsAtMs: Double?
  var scoped: [ClaudeScopedLimit]
  let extraEnabled: Bool?
  let extraUsedUSD: Double?
  let extraLimitUSD: Double?
  let extraUsedPercent: Double?

  init(
    sessionUsedPercent: Double? = nil, sessionResetsAtMs: Double? = nil,
    weeklyUsedPercent: Double? = nil, weeklyResetsAtMs: Double? = nil,
    scoped: [ClaudeScopedLimit] = [], extraEnabled: Bool? = nil, extraUsedUSD: Double? = nil,
    extraLimitUSD: Double? = nil, extraUsedPercent: Double? = nil
  ) {
    self.sessionUsedPercent = sessionUsedPercent
    self.sessionResetsAtMs = sessionResetsAtMs
    self.weeklyUsedPercent = weeklyUsedPercent
    self.weeklyResetsAtMs = weeklyResetsAtMs
    self.scoped = scoped
    self.extraEnabled = extraEnabled
    self.extraUsedUSD = extraUsedUSD
    self.extraLimitUSD = extraLimitUSD
    self.extraUsedPercent = extraUsedPercent
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionUsedPercent = try container.decodeIfPresent(Double.self, forKey: .sessionUsedPercent)
    sessionResetsAtMs = try container.decodeIfPresent(Double.self, forKey: .sessionResetsAtMs)
    weeklyUsedPercent = try container.decodeIfPresent(Double.self, forKey: .weeklyUsedPercent)
    weeklyResetsAtMs = try container.decodeIfPresent(Double.self, forKey: .weeklyResetsAtMs)
    scoped = try container.decodeIfPresent([ClaudeScopedLimit].self, forKey: .scoped) ?? []
    extraEnabled = try container.decodeIfPresent(Bool.self, forKey: .extraEnabled)
    extraUsedUSD = try container.decodeIfPresent(Double.self, forKey: .extraUsedUSD)
    extraLimitUSD = try container.decodeIfPresent(Double.self, forKey: .extraLimitUSD)
    extraUsedPercent = try container.decodeIfPresent(Double.self, forKey: .extraUsedPercent)
  }
}

struct ClaudeScopedLimit: Codable, Sendable, Identifiable {
  let name: String
  let usedPercent: Double?
  let resetsAtMs: Double?
  var id: String { name }
}

/// One card for every Claude meter: the weekly quota chart, a smaller 5-hour
/// session chart, then slim rows for model-scoped limits and extra usage.
struct ClaudeAccountView: View {
  @Environment(UsageStore.self) private var store
  let account: ClaudeAccount?
  let plan: SubscriptionAgent?
  private var now: Date { store.quotaCheckDate }
  private var tint: Color { BurnTheme.color(for: "claude") }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Label(
            "Claude " + (plan?.plan ?? "account"), systemImage: "gauge.with.dots.needle.33percent"
          )
          .font(.headline)
          Spacer()
          if let price = plan?.pricePerMonth {
            Text(currency(price) + " / month").foregroundStyle(.secondary)
          }
        }
        weekly
        Divider()
        session
        if let account, !account.scoped.isEmpty || showsExtra(account) {
          Divider()
          VStack(spacing: 12) {
            ForEach(account.scoped) { window in
              ClaudeMeterRow(
                title: window.name + " weekly", used: window.usedPercent,
                detail: "Resets " + claudeDate(window.resetsAtMs))
            }
            if showsExtra(account) {
              ClaudeMeterRow(
                title: "Extra usage", used: extraUsedPercent(account),
                value: account.extraUsedUSD.map { extraRemaining(account, used: $0) },
                detail: account.extraLimitUSD.map { "of " + currency($0) + " limit" }
                  ?? "Enabled this cycle")
            }
          }
        }
        if account == nil {
          Text(
            "Live account limits are unavailable. Refresh with live data enabled to load Claude’s meters."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }.padding(12)
    }
  }

  @ViewBuilder private var weekly: some View {
    @Bindable var store = store
    if let forecast = store.forecast(for: "claude") {
      let range = store.quotaChartRange
      let samples = store.samples(for: "claude", range: range, now: now)
      HStack(alignment: .top, spacing: 28) {
        QuotaSummary(
          forecast: forecast, samples: samples, now: now,
          stale: !forecast.isFresh(at: now) || store.quotaError(for: "claude") != nil,
          staleHelp: store.quotaError(for: "claude")
            ?? "Showing the last known reading. Update pending.",
          rates: store.blendRates(for: "claude")
        )
        .frame(width: 236, alignment: .leading)
        VStack(alignment: .trailing, spacing: 8) {
          QuotaChartRangePicker(range: $store.quotaChartRange)
          QuotaChart(forecast: forecast, samples: samples, color: tint, range: range, now: now)
            .id(range)
        }
      }
    } else {
      ClaudeMeterRow(
        title: "Weekly", used: account?.weeklyUsedPercent,
        detail: "Resets " + claudeDate(account?.weeklyResetsAtMs))
    }
  }

  @ViewBuilder private var session: some View {
    if let forecast = store.forecast(for: claudeSessionQuotaAgent), forecast.reset > now {
      let samples = store.samples(for: claudeSessionQuotaAgent, range: .rte, now: now)
      HStack(alignment: .top, spacing: 28) {
        ClaudeSessionSummary(
          forecast: forecast, samples: samples, now: now, stale: !forecast.isFresh(at: now)
        )
        .frame(width: 236, alignment: .leading)
        QuotaChart(
          forecast: forecast, samples: samples, color: tint, compact: true, range: .rte,
          now: now, height: 120)
      }
    } else {
      ClaudeMeterRow(
        title: "Session · 5 hours", used: account?.sessionUsedPercent,
        detail: "Resets " + claudeDate(account?.sessionResetsAtMs, time: true))
    }
  }
}

/// Compact 5-hour session block: remaining, pace, reset time and a short chart.
struct ClaudeSessionSummary: View {
  let forecast: Forecast
  let samples: [QuotaSample]
  let now: Date
  var stale = false

  private var paceDelta: Double? {
    quotaChartReading(at: forecast.observedAt, samples: samples, forecast: forecast, range: .rte)
      .paceDelta
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Text("Session · 5 hours").font(.subheadline.weight(.medium))
        if stale {
          Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
            .help("Showing the last known reading. Update pending.")
            .accessibilityLabel("Last known session reading; update pending")
        }
      }
      Text(quotaChartPercentLabel(forecast.remaining))
        .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
        .contentTransition(.numericText()).animation(.snappy, value: forecast.remaining)
        .accessibilityLabel("Session remaining")
      if let pace = quotaChartDeltaText(paceDelta), let paceDelta {
        StatusBadge(text: pace, color: paceDelta < -0.05 ? BurnTheme.behind : BurnTheme.ahead)
          .help("Recorded remaining minus even pace across the 5-hour window.")
      }
      Text(
        "Resets in \(quotaTimeLeft(forecast, now: now)) · "
          + forecast.reset.formatted(date: .omitted, time: .shortened)
      )
      .font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Fallback and secondary meters: title, reset detail, remaining value and a thin bar.
struct ClaudeMeterRow: View {
  let title: String
  let used: Double?
  var value: String? = nil
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.subheadline.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text(value ?? remainingLabel(used) + " left")
          .font(.subheadline.weight(.semibold)).monospacedDigit()
      }
      if let used {
        ProgressView(value: max(0, min(100, 100 - used)), total: 100).tint(.orange)
          .accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

func claudeDate(_ milliseconds: Double?, time: Bool = false) -> String {
  guard let milliseconds else { return "unavailable" }
  return Date(timeIntervalSince1970: milliseconds / 1000).formatted(
    date: .abbreviated, time: time ? .shortened : .omitted)
}

func remainingLabel(_ used: Double?) -> String {
  guard let used else { return "Unavailable" }
  return max(0, min(100, 100 - used)).formatted(.number.precision(.fractionLength(1))) + "%"
}

/// Extra usage is noise until it is switched on or has actually been spent.
func showsExtra(_ account: ClaudeAccount) -> Bool {
  account.extraEnabled == true || (account.extraUsedUSD ?? 0) > 0
}

func extraUsedPercent(_ account: ClaudeAccount) -> Double? {
  if let used = account.extraUsedPercent { return max(0, min(100, used)) }
  guard let used = account.extraUsedUSD, let limit = account.extraLimitUSD, limit > 0 else {
    return nil
  }
  return max(0, min(100, used / limit * 100))
}

func extraRemaining(_ account: ClaudeAccount, used: Double) -> String {
  account.extraLimitUSD.map { currency(max(0, $0 - used)) + " left" } ?? currency(used) + " used"
}
