import SwiftUI

struct CompactHarnessView: View {
  @Environment(UsageStore.self) private var store
  let agent: String
  @State private var showsDetails = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let forecast = store.forecast(for: agent) {
        let range = store.chartRange(for: agent)
        VStack(alignment: .leading, spacing: 14) {
          header
          QuotaSummary(
          forecast: forecast,
          samples: store.samples(
            for: agent, range: range, now: store.quotaCheckDate),
          now: store.quotaCheckDate,
          stale: !forecast.isFresh(at: store.quotaCheckDate)
            || store.quotaError(for: agent) != nil,
          staleHelp: store.quotaError(for: agent)
            ?? String(localized: "Showing the last known reading. Update pending."),
          compact: true,
          availableResets: store.reports[agent]?.resetCreditsAvailable,
          rates: store.blendRates(for: agent)
        )
        QuotaChart(
          forecast: forecast,
          samples: store.samples(
            for: agent, range: range, now: store.quotaCheckDate),
          color: BurnTheme.quotaColor(for: agent), compact: true,
          range: range, now: store.quotaCheckDate)

          if let short = store.summary?.subscription?.agents.first(where: { $0.agent == agent })?
            .shortWindow
          {
            let remaining = percentText(max(0, 100 - short.usedPercent), digits: 0)
            detail(
              String(localized: "\(short.label) limit"),
              String(localized: "\(remaining) remaining"))
          }
        }
        .burnCard(padding: 14, radius: 12)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          header
          Spacer(minLength: 4)
          Text(store.isLoading ? "Reading usage…" : "Quota unavailable")
            .font(.system(size: 20, weight: .semibold))
          Text(
            store.isLoading
              ? "Loading your subscription limits."
              : "Sign in to \(harnessName(agent)) and run a session, then refresh."
          )
          .font(.system(size: 12)).foregroundStyle(BurnTheme.quotaMuted)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .burnCard(padding: 14, radius: 12)
      }

      if let error = store.errors[agent] { ReportNotice(message: error) }
      if let error = store.errors["quotaService"] { ReportNotice(message: error) }
      if let error = store.errors["history"] { ReportNotice(message: error) }

      if let report = store.reports[agent] {
        let rates = store.blendRates(for: agent)
        DisclosureGroup("Usage details", isExpanded: $showsDetails) {
          VStack(alignment: .leading, spacing: 12) {
            detail(
              String(localized: "API-equivalent · 30 days"),
              currency(report.apiEquivalentPerMonth))
            if let price = report.pricePerMonth {
              detail(String(localized: "Monthly plan"), currency(price))
            }
            if let forecast = store.forecast(for: agent) {
              let daily = percentText(forecast.dailyAllowance, digits: 1)
              detail(
                String(localized: "Suggested daily pace"),
                String(localized: "\(daily)\u{00A0}/ day"))
            }
            if let dollars = quotaDollarsPerPercentLabel(rates?.dollarsPerPercent) {
              detail(String(localized: "Avg $ / %"), dollars)
            }
            if let tokensPer = quotaTokensPerUnitLabel(rates?.tokensPerDollar, unit: "$") {
              detail(String(localized: "Avg tokens / $"), tokensPer)
            }
            ForEach(Array(report.topModels.prefix(2))) { model in
              detail(model.model, currency(model.cost))
            }
          }.padding(.top, 12)
        }
        .font(.system(size: 12, weight: .medium)).tint(BurnTheme.quotaMuted)
        .burnCard(padding: 12, radius: 12)
      }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      HarnessIcon(agent: agent, size: 22)
      Text(harnessName(agent)).font(.system(size: 13, weight: .semibold))
      Spacer()
      Text(store.reports[agent]?.plan ?? String(localized: "Subscription"))
        .font(.system(size: 11, weight: .medium)).foregroundStyle(BurnTheme.quotaMuted)
        .lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(BurnTheme.track, in: Capsule())
    }
  }

  private func detail(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).foregroundStyle(BurnTheme.quotaMuted).lineLimit(1)
      Spacer(minLength: 12)
      Text(value).monospacedDigit().lineLimit(1)
    }.font(.system(size: 12))
  }
}
