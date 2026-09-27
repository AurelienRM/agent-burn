import SwiftUI

struct OverviewView: View {
  @Environment(UsageStore.self) private var store

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center) {
        Text("Overview").font(.system(size: 15, weight: .semibold))
        Spacer()
        PeriodPicker(width: 130).controlSize(.small)
      }
      .padding(.horizontal, 4)
      if let error = store.errors["summary"] { ReportNotice(message: error) }
      if let report = store.summary {
        HStack(spacing: 10) {
          MetricTile(
            title: "Spend", value: currency(report.totals.totalCost),
            detail: "API-equivalent · \(store.period.label)", symbol: "dollarsign",
            compact: true
          )
          .burnCard(padding: 12, radius: 12)
          MetricTile(
            title: "Tokens", value: tokens(report.totals.totalTokens),
            detail: "\(report.agents.count) agents", symbol: "square.stack.3d.up.fill",
            tint: .blue, compact: true
          )
          .burnCard(padding: 12, radius: 12)
        }
        quotaGrid
        busiest(report)
        if !report.models.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "Top models", symbol: "cpu", tint: .purple) {
              Text("\(report.models.count) models")
            }
            ForEach(Array(report.models.prefix(3))) { model in
              HStack(spacing: 10) {
                Text(model.model).lineLimit(1).help(model.model)
                Spacer()
                Text(tokens(model.totalTokens)).foregroundStyle(BurnTheme.quotaMuted)
                Text(currency(model.totalCost)).fontWeight(.medium)
                  .frame(minWidth: 72, alignment: .trailing)
              }
              .font(.system(size: 12)).monospacedDigit()
            }
          }
          .burnCard(padding: 12, radius: 12)
        }
        Label(
          "API-equivalent usage estimates token value, not your subscription bill.",
          systemImage: "info.circle"
        )
        .font(.system(size: 11)).foregroundStyle(BurnTheme.quotaMuted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          IconBadge(symbol: "flame.fill", size: 34)
          Text(store.isLoading ? "Gathering your local usage…" : "Connect your usage")
            .font(.system(size: 17, weight: .semibold))
          Text(
            "Agent Burn reads the same local harness logs as the CLI. Choose the executable in Settings if it isn't detected automatically."
          )
          .font(.system(size: 12)).foregroundStyle(BurnTheme.quotaMuted)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
        .burnCard()
      }
    }
  }

  @ViewBuilder private var quotaGrid: some View {
    let quotas = QuotaSource.allCases.compactMap { source -> (QuotaSource, Double)? in
      remainingQuota(
        for: source, forecast: store.forecast(for: source.rawValue),
        cursorAccount: store.summary?.cursorAccount,
        claudeAccount: store.summary?.claudeAccount
      ).map { (source, $0) }
    }
    if !quotas.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        CardHeader(title: "Quota remaining", symbol: "gauge.with.dots.needle.67percent", tint: .green)
        HStack(spacing: 8) {
          ForEach(quotas, id: \.0) { source, remaining in
            quotaTile(source, remaining: remaining)
          }
        }
      }
      .burnCard(padding: 12, radius: 12)
    }
  }

  private func quotaTile(_ source: QuotaSource, remaining: Double) -> some View {
    let tone: Color = remaining < 15 ? BurnTheme.behind : remaining < 35 ? .orange : .green
    return Button {
      withAnimation(.snappy) { store.selection = source.rawValue }
    } label: {
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 5) {
          HarnessIcon(agent: source.rawValue, size: 14)
          Text(source.label).font(.system(size: 11, weight: .medium))
            .foregroundStyle(BurnTheme.quotaMuted)
        }
        Text(quotaChartPercentLabel(remaining))
          .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
          .contentTransition(.numericText())
          .animation(.snappy, value: remaining)
        ShareBar(value: remaining / 100, tint: tone, height: 4)
      }
      .padding(9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(BurnTheme.hover, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    .buttonStyle(.plain)
    .help("Open \(source.label)")
    .accessibilityLabel("\(source.label) \(quotaChartPercentLabel(remaining)) remaining")
  }

  private func busiest(_ report: SummaryReport) -> some View {
    let agents = Array(report.agents.sorted { $0.totalCost > $1.totalCost }.prefix(6))
    let top = max(agents.first?.totalCost ?? 0, 0.01)
    return VStack(alignment: .leading, spacing: 6) {
      CardHeader(title: "Busiest agents", symbol: "flame.fill") {
        Text(store.period.label)
      }
      .padding(.bottom, 4)
      if agents.isEmpty {
        Text("No local usage in this period. Run an agent session or choose a longer range.")
          .font(.system(size: 12)).foregroundStyle(BurnTheme.quotaMuted)
      }
      ForEach(agents) { agent in
        Button {
          withAnimation(.snappy) { store.selection = agent.agent }
        } label: {
          HStack(spacing: 10) {
            HarnessIcon(agent: agent.agent, size: 22)
            VStack(alignment: .leading, spacing: 5) {
              HStack {
                Text(harnessName(agent.agent)).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(tokens(agent.totalTokens)).font(.system(size: 11))
                  .foregroundStyle(BurnTheme.quotaMuted)
                Text(currency(agent.totalCost)).font(.system(size: 12, weight: .semibold))
                  .frame(minWidth: 72, alignment: .trailing)
              }
              ShareBar(
                value: agent.totalCost / top, tint: BurnTheme.color(for: agent.agent), height: 4)
            }
          }
          .monospacedDigit()
        }
        .buttonStyle(.plain)
        .hoverRow()
        .padding(.horizontal, -8)
        .accessibilityLabel(
          "\(harnessName(agent.agent)), \(currency(agent.totalCost)), \(tokens(agent.totalTokens)) tokens"
        )
      }
    }
    .burnCard(padding: 12, radius: 12)
  }
}
