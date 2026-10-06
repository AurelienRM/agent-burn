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
  /// When Anthropic reported these meters; the CLI may serve a shared cached reading.
  let observedAtMs: Double?

  init(
    sessionUsedPercent: Double? = nil, sessionResetsAtMs: Double? = nil,
    weeklyUsedPercent: Double? = nil, weeklyResetsAtMs: Double? = nil,
    scoped: [ClaudeScopedLimit] = [], extraEnabled: Bool? = nil, extraUsedUSD: Double? = nil,
    extraLimitUSD: Double? = nil, extraUsedPercent: Double? = nil, observedAtMs: Double? = nil
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
    self.observedAtMs = observedAtMs
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
    observedAtMs = try container.decodeIfPresent(Double.self, forKey: .observedAtMs)
  }
}

struct ClaudeScopedLimit: Codable, Sendable, Identifiable {
  let name: String
  let usedPercent: Double?
  let resetsAtMs: Double?
  var id: String { name }
}

/// Split Deck: a one-line verdict, then the 5-hour session and weekly limits side by
/// side with their until-reset charts, then slim rows for model-scoped limits and extra usage.
struct ClaudeAccountView: View {
  @Environment(UsageStore.self) private var store
  let account: ClaudeAccount?
  let plan: SubscriptionAgent?
  private var now: Date { store.quotaCheckDate }
  private var tint: Color { BurnTheme.color(for: "claude") }
  private var weekly: Forecast? { store.forecast(for: "claude") }
  /// The newest saved session reading, kept after its window resets for the reset time.
  private var lastSession: Forecast? { store.forecast(for: claudeSessionQuotaAgent) }
  private var session: Forecast? { lastSession.flatMap { $0.reset > now ? $0 : nil } }
  /// The report's status is only as new as the report; a live reading collected
  /// since then proves Claude Code renewed its sign-in.
  private var signInExpired: Bool {
    store.summary?.claudeAccountStatus == "signInExpired"
      && !(weekly?.isFresh(at: now) ?? false)
  }
  private var sessionReset: Date? {
    [claudeDate(account?.sessionResetsAtMs), lastSession?.reset].compactMap { $0 }.max()
  }
  /// The newest moment any Claude meter was read, live or from the report.
  private var lastReading: Date? {
    [weekly?.observedAt, lastSession?.observedAt, claudeDate(account?.observedAtMs)]
      .compactMap { $0 }.max()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      CardHeader(
        title: String(localized: "Claude \(plan?.plan ?? String(localized: "account"))"),
        symbol: "gauge.with.dots.needle.33percent", tint: tint
      ) {
        HStack(spacing: 12) {
          if let price = plan?.pricePerMonth {
            Text("\(currency(price)) / month").monospacedDigit()
          }
          if let latest = weekly ?? session { freshness(latest) }
          QuotaCheckButton(label: true)
        }
      }
      if signInExpired {
        ClaudeVerdictBanner(verdict: claudeSignInExpiredVerdict)
      } else if let verdict = claudeVerdict(session: session, weekly: weekly, now: now) {
        ClaudeVerdictBanner(verdict: verdict)
      }
      if account != nil || weekly != nil || lastSession != nil {
        HStack(alignment: .top, spacing: 14) {
          ClaudeLimitPanel(
            title: String(localized: "5-hour session"), forecast: session,
            samples: store.samples(for: claudeSessionQuotaAgent, range: .rte, now: now),
            now: now, tint: tint, used: account?.sessionUsedPercent,
            resetsAt: sessionReset, lastReading: lastReading, stale: signInExpired)
          ClaudeLimitPanel(
            title: String(localized: "Weekly"), forecast: weekly,
            samples: store.samples(for: "claude", range: .rte, now: now),
            now: now, tint: tint, used: account?.weeklyUsedPercent,
            resetsAt: claudeDate(account?.weeklyResetsAtMs), lastReading: lastReading,
            stale: signInExpired)
        }
      }
      if let account, !account.scoped.isEmpty || showsExtra(account) {
        Divider()
        secondaryMeters(account)
      }
      if account == nil && !signInExpired {
        Text(
          "Live account limits are unavailable. Use Check now with live data enabled to load Claude’s meters."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .burnCard(padding: 18)
  }

  private func freshness(_ forecast: Forecast) -> some View {
    let fresh = forecast.isFresh(at: now) && store.quotaError(for: "claude") == nil
    return HStack(spacing: 6) {
      Circle().fill(fresh ? BurnTheme.ahead : .orange).frame(width: 7, height: 7)
      Text(forecast.observedAt.formatted(date: .omitted, time: .shortened)).monospacedDigit()
    }
    .help(
      fresh
        ? String(localized: "Live reading · updates every minute")
        : store.quotaError(for: "claude")
          ?? String(localized: "Showing the last known reading. Update pending.")
    )
  }

  private func secondaryMeters(_ account: ClaudeAccount) -> some View {
    let count = account.scoped.count + (showsExtra(account) ? 1 : 0)
    return LazyVGrid(
      columns: Array(
        repeating: GridItem(.flexible(), spacing: 28, alignment: .top), count: min(2, count)),
      alignment: .leading, spacing: 14
    ) {
      ForEach(account.scoped) { window in
        ClaudeMeterRow(
          title: String(localized: "\(window.name) · weekly"), used: window.usedPercent,
          tint: tint)
      }
      if showsExtra(account) {
        ClaudeMeterRow(
          title: String(localized: "Extra usage"), used: extraUsedPercent(account), tint: tint,
          value: account.extraUsedUSD.map { extraRemaining(account, used: $0) },
          detail: account.extraLimitUSD.map { String(localized: "of \(currency($0)) limit") })
      }
    }
  }
}

/// The single sentence that says whether both limits last until they reset.
struct ClaudeVerdict: Equatable {
  let atRisk: Bool
  let headline: String
  let detail: String
}

/// The CLI renews an expired Claude Code token itself; this verdict means
/// Anthropic refused the refresh token, so only `/login` in `claude` recovers.
let claudeSignInExpiredVerdict = ClaudeVerdict(
  atRisk: true, headline: String(localized: "Claude Code sign-in expired."),
  detail: String(
    localized:
      "Anthropic refused to renew the sign-in. Run claude in Terminal and use /login. Showing the last saved readings."
  )
)

/// Session run-outs come first because they lock you out soonest.
func claudeVerdict(session: Forecast?, weekly: Forecast?, now: Date) -> ClaudeVerdict? {
  if let session, let verdict = claudeRunOutVerdict(
    session, name: String(localized: "Session"), now: now) {
    return verdict
  }
  if let weekly, let verdict = claudeRunOutVerdict(
    weekly, name: String(localized: "Weekly limit"), now: now) {
    return verdict
  }
  guard session != nil || weekly != nil else { return nil }
  return ClaudeVerdict(
    atRisk: false, headline: String(localized: "On track."),
    detail: session != nil && weekly != nil
      ? String(localized: "At this pace both limits last until they reset.")
      : String(localized: "At this pace the limit lasts until it resets."))
}

private func claudeRunOutVerdict(_ forecast: Forecast, name: String, now: Date) -> ClaudeVerdict? {
  let reset = quotaChartEdgeLabel(forecast.reset, isStart: false, forecast: forecast)
  if forecast.remaining <= 0 {
    return ClaudeVerdict(
      atRisk: true, headline: String(localized: "\(name) reached."),
      detail: String(localized: "It resets \(reset)."))
  }
  guard forecast.projectedEnd < forecast.reset else { return nil }
  let empty = quotaChartEdgeLabel(forecast.projectedEnd, isStart: false, forecast: forecast)
  let left = max(60, forecast.reset.timeIntervalSince(max(now, forecast.observedAt)))
  let pace =
    forecast.duration <= 86_400
    ? String(localized: "Slow to \(quotaRateText(forecast.remaining / (left / 3_600)))/h")
    : String(localized: "Keep under \(quotaRateText(forecast.remaining / (left / 86_400)))/day")
  return ClaudeVerdict(
    atRisk: true, headline: String(localized: "\(name) runs out ≈ \(empty)."),
    detail: String(localized: "\(pace) to last until the \(reset) reset."))
}

private func quotaRateText(_ value: Double) -> String {
  value.formatted(.number.precision(.fractionLength(0...1))) + "%"
}

struct ClaudeVerdictBanner: View {
  let verdict: ClaudeVerdict
  private var tone: Color { verdict.atRisk ? BurnTheme.behind : BurnTheme.ahead }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: verdict.atRisk ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
        .font(.system(size: 14)).foregroundStyle(tone)
      (Text(verdict.headline).fontWeight(.semibold).foregroundStyle(
        verdict.atRisk ? tone : BurnTheme.ink)
        + Text(" " + verdict.detail).foregroundStyle(BurnTheme.muted))
        .font(.system(size: 13)).monospacedDigit()
        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14).padding(.vertical, 11)
    .background(tone.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

/// One limit: remaining share, pace delta, reset countdown and an until-reset chart.
/// Without a collected reading it falls back to the account meter and a plain bar.
struct ClaudeLimitPanel: View {
  let title: String
  let forecast: Forecast?
  let samples: [QuotaSample]
  let now: Date
  let tint: Color
  var used: Double? = nil
  var resetsAt: Date? = nil
  /// When Claude's meters were last read; a reset after it is not confirmed.
  var lastReading: Date? = nil
  /// The readings cannot update, so even a recent one is only the last known value.
  var stale = false

  private var reset: Date? { forecast?.reset ?? resetsAt }
  private var hasReset: Bool { reset.map { $0 <= now } ?? false }
  /// The window ended after the last reading, so a new one may already be running:
  /// claiming a full meter would be a guess.
  private var unconfirmed: Bool {
    guard forecast == nil, hasReset, let reset else { return false }
    return (lastReading ?? .distantPast) < reset
  }
  private var remaining: Double? {
    if let forecast { return forecast.remaining }
    if unconfirmed { return nil }
    if hasReset { return 100 }
    return used.map { max(0, min(100, 100 - $0)) }
  }
  private var paceDelta: Double? {
    guard let forecast else { return nil }
    return quotaChartReading(
      at: forecast.observedAt, samples: samples, forecast: forecast, range: .rte
    ).paceDelta
  }
  private var atRisk: Bool {
    forecast.map { $0.remaining <= 0 || $0.projectedEnd < $0.reset } ?? false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 6) {
          Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold)).tracking(0.6)
            .foregroundStyle(BurnTheme.muted)
          if stale || unconfirmed || forecast.map({ !$0.isFresh(at: now) }) == true {
            Image(systemName: "clock.badge.exclamationmark")
              .font(.system(size: 11)).foregroundStyle(.orange)
              .help("Showing the last known reading. Update pending.")
              .accessibilityLabel("Last known reading; update pending")
          }
          Spacer(minLength: 8)
          resetText
        }
        HStack(alignment: .center, spacing: 8) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(remaining.map(quotaPercentText) ?? "—")
              .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
              .contentTransition(.numericText()).animation(.snappy, value: remaining)
            Text("left").font(.system(size: 14)).foregroundStyle(BurnTheme.muted)
          }
          .lineLimit(1).minimumScaleFactor(0.7)
          .accessibilityElement(children: .combine)
          .accessibilityLabel("\(title) remaining")
          Spacer(minLength: 8)
          if let paceDelta { ClaudePaceBadge(delta: paceDelta) }
        }
      }
      if let forecast {
        QuotaChart(
          forecast: forecast, samples: samples, color: tint, range: .rte, now: now,
          height: 150, idleBadge: false, minimal: true)
      } else {
        placeholder
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(BurnTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(atRisk ? BurnTheme.behind.opacity(0.28) : BurnTheme.cardStroke)
    )
  }

  @ViewBuilder private var resetText: some View {
    if let reset {
      Group {
        if hasReset {
          Text("Reset")
        } else {
          Text("Resets in ")
            + Text(quotaDurationLabel(reset.timeIntervalSince(now)))
            .fontWeight(.semibold).foregroundStyle(BurnTheme.ink)
        }
      }
      .font(.system(size: 12)).foregroundStyle(BurnTheme.muted).monospacedDigit()
      .lineLimit(1).fixedSize()
      .help("Resets \(quotaDateCompact(reset))")
    }
  }

  private var placeholder: some View {
    VStack(alignment: .leading, spacing: 10) {
      Spacer(minLength: 0)
      if let remaining { ShareBar(value: remaining / 100, tint: tint, height: 6) }
      Text(placeholderText)
      .font(.system(size: 11)).foregroundStyle(BurnTheme.muted)
      Spacer(minLength: 0)
    }
    .frame(height: 150)
  }

  private var placeholderText: String {
    if unconfirmed {
      if let lastReading {
        let time = lastReading.formatted(date: .omitted, time: .shortened)
        return String(
          localized: "No live reading since \(time). Check that Claude Code is signed in.")
      }
      return String(localized: "No live reading. Check that Claude Code is signed in.")
    }
    return hasReset
      ? String(localized: "Limit reset. A new window starts with your next request.")
      : String(localized: "The chart appears after the next live reading.")
  }
}

/// "+10 pts ahead" / "−18 pts behind": remaining minus even pace, in percentage points.
struct ClaudePaceBadge: View {
  let delta: Double
  private var tone: Color { delta < -0.05 ? BurnTheme.behind : BurnTheme.ahead }

  var body: some View {
    Text(claudePaceText(delta))
      .font(.system(size: 12, weight: .semibold)).monospacedDigit()
      .foregroundStyle(tone)
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(tone.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .fixedSize()
      .help("Remaining now minus an even pace until reset.")
  }
}

func claudePaceText(_ delta: Double) -> String {
  if abs(delta) < 0.05 { return String(localized: "On pace") }
  let magnitude = abs(delta).formatted(.number.precision(.fractionLength(0...1)))
  return delta > 0
    ? String(localized: "+\(magnitude) pts ahead") : String(localized: "−\(magnitude) pts behind")
}

/// Model-scoped limits and extra usage: title, optional detail, a thin bar and the value.
struct ClaudeMeterRow: View {
  let title: String
  let used: Double?
  var tint: Color = BurnTheme.flame
  var value: String? = nil
  var detail: String? = nil

  private var remaining: Double? { used.map { max(0, min(100, 100 - $0)) } }

  var body: some View {
    HStack(spacing: 16) {
      Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
      if let detail {
        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
      Group {
        if let remaining {
          ShareBar(
            value: remaining / 100, tint: remaining < 15 ? BurnTheme.behind : tint, height: 6)
        } else {
          Spacer(minLength: 0)
        }
      }
      .frame(minWidth: 48, maxWidth: .infinity)
      .layoutPriority(-1)
      Group {
        if let value {
          Text(value).fontWeight(.semibold).foregroundStyle(BurnTheme.ink)
        } else {
          Text(remaining.map(quotaPercentText) ?? "—").fontWeight(.semibold)
            .foregroundStyle(BurnTheme.ink) + Text(" left").foregroundStyle(BurnTheme.muted)
        }
      }
      .font(.system(size: 13)).monospacedDigit()
      .lineLimit(1).fixedSize()
    }
    .accessibilityElement(children: .combine)
  }
}

func claudeDate(_ milliseconds: Double?) -> Date? {
  milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) }
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
  account.extraLimitUSD.map { String(localized: "\(currency(max(0, $0 - used))) left") }
    ?? String(localized: "\(currency(used)) used")
}
