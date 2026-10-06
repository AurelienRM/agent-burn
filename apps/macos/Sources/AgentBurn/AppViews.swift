import SwiftUI

struct MenuPopover: View {
  @Environment(UsageStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  private var tab: String { store.selection }

  var body: some View {
    @Bindable var store = store
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(nsImage: AppLogo.window).resizable().interpolation(.high)
          .frame(width: 26, height: 26).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text("Agent Burn").font(.system(size: 13, weight: .semibold))
          Text(store.quotaSource.label + " " + menuBarQuotaText(store.remainingPercent))
            .font(.system(size: 11)).foregroundStyle(BurnTheme.quotaMuted).monospacedDigit()
        }
        Spacer()
        if store.isLoading {
          ProgressView().controlSize(.small).accessibilityLabel("Updating usage")
        }
      }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
      PopoverTabs(selection: $store.selection)
        .padding(.horizontal, 14).padding(.bottom, 14)
      ScrollView {
        Group {
          if tab == "summary" {
            OverviewView()
          } else if ["codex", "claude"].contains(tab) {
            HarnessView(agent: tab, compact: true)
          } else {
            SourceUsageView(agent: tab, compact: true)
          }
        }
        .id(tab)
        .transition(.opacity.combined(with: .offset(y: 6)))
        .padding(.horizontal, 14).padding(.bottom, 16)
      }
      .scrollIndicators(.never)
      .frame(height: ["codex", "claude"].contains(tab) ? 460 : 520)
      .animation(.smooth(duration: 0.25), value: tab)
      Rectangle().fill(BurnTheme.line).frame(height: 1)
      VStack(spacing: 10) {
        RefreshFooter(source: ["codex", "claude"].contains(tab) ? tab : "summary", compact: true)
        HStack(spacing: 8) {
          Button {
            store.selection = tab
            openWindow(id: "overview")
            NSApp.activate(ignoringOtherApps: true)
          } label: {
            Label("Open dashboard", systemImage: "macwindow")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(PopoverPillButtonStyle())
          SettingsLink {
            Image(systemName: "gearshape")
          }
          .buttonStyle(PopoverPillButtonStyle(square: true))
          .help("Settings").accessibilityLabel("Settings")
          Button {
            NSApp.terminate(nil)
          } label: {
            Label("Quit", systemImage: "power")
          }
          .buttonStyle(PopoverPillButtonStyle())
          .help("Quit Agent Burn").accessibilityLabel("Quit Agent Burn")
        }
      }.padding(.horizontal, 14).padding(.vertical, 12)
    }
    .frame(width: 440).background(.regularMaterial).foregroundStyle(BurnTheme.ink)
    .tint(BurnTheme.flame)
  }

}

private struct PopoverTabs: View {
  @Binding var selection: String
  @Namespace private var pill
  private let tabs: [(id: String, label: String)] = [
    ("summary", String(localized: "General")), ("codex", "Codex"), ("claude", "Claude"),
    ("cursor", "Cursor"),
  ]
  var body: some View {
    HStack(spacing: 2) {
      ForEach(tabs, id: \.id) { tab in
        let active = selection == tab.id
        Button {
          withAnimation(.snappy(duration: 0.28)) { selection = tab.id }
        } label: {
          HStack(spacing: 5) {
            if tab.id == "summary" {
              Image(systemName: "square.grid.2x2").font(.system(size: 10, weight: .semibold))
            } else {
              HarnessIcon(agent: tab.id, size: 13)
            }
            Text(tab.label)
          }
          .font(.system(size: 12, weight: active ? .semibold : .medium))
          .foregroundStyle(active ? BurnTheme.ink : BurnTheme.quotaMuted)
          .frame(maxWidth: .infinity).padding(.vertical, 6)
          .background {
            if active {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(BurnTheme.card)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                .matchedGeometryEffect(id: "pill", in: pill)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
      }
    }
    .padding(3)
    .background(BurnTheme.track, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Harness")
  }
}

private struct PopoverPillButtonStyle: ButtonStyle {
  var square = false
  func makeBody(configuration: Configuration) -> some View {
    PopoverPill(configuration: configuration, square: square)
  }
}

private struct PopoverPill: View {
  let configuration: ButtonStyle.Configuration
  let square: Bool
  @State private var hovering = false
  var body: some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .padding(.horizontal, square ? 0 : 12).padding(.vertical, 8)
      .frame(width: square ? 34 : nil)
      .background(
        hovering || configuration.isPressed ? BurnTheme.track : BurnTheme.hover,
        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(BurnTheme.cardStroke, lineWidth: 1)
      )
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.12), value: hovering)
  }
}

struct DashboardView: View {
  @Environment(UsageStore.self) private var store
  var body: some View {
    NavigationSplitView {
      DashboardSidebar()
        .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 300)
    } detail: {
      VStack(spacing: 0) {
        ScrollView {
          NativeUsageView(agent: store.selection == "summary" ? nil : store.selection)
            .id(store.selection)
            .transition(.opacity.combined(with: .offset(y: 8)))
            .padding(24).frame(maxWidth: 1280).frame(maxWidth: .infinity)
        }
        .animation(.smooth(duration: 0.3), value: store.selection)
        Divider()
        RefreshFooter(source: "summary").padding(.horizontal, 20).padding(.vertical, 9)
      }
      .background(BurnTheme.background)
      .navigationTitle(
        store.selection == "summary" ? String(localized: "Overview") : harnessName(store.selection)
      )
      .navigationSubtitle(store.period.label)
    }
    .frame(minWidth: 980, minHeight: 650)
    .tint(BurnTheme.flame)
    .toolbar {
      ToolbarItem(placement: .navigation) {
        QuotaSourceMenu()
      }
      ToolbarItem(placement: .primaryAction) {
        PeriodPicker(width: 130).help("Spend period")
      }
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          Task { await store.refreshAll() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Refresh usage and live quotas (⌘R)")
        Button {
          Task { await store.refreshAll(hard: true) }
        } label: {
          Label("Check live usage now", systemImage: "gauge.with.dots.needle.67percent")
        }
        .disabled(store.isCheckingQuotas)
        .help(
          "Check live usage now (⇧⌘R). Bypasses saved readings and renews an expired Claude sign-in."
        )
        SettingsLink { Label("Settings", systemImage: "gearshape") }.help("Settings")
      }
    }
  }
}

private struct DashboardSidebar: View {
  @Environment(UsageStore.self) private var store
  private let subscriptions = ["codex", "claude", "cursor"]
  private var others: [String] {
    store.knownAgents.filter { !subscriptions.contains($0) }
  }
  private var selection: Binding<String?> {
    Binding(get: { store.selection }, set: { if let value = $0 { store.selection = value } })
  }

  var body: some View {
    List(selection: selection) {
      row(id: "summary", title: String(localized: "Overview")) {
        IconBadge(symbol: "flame.fill", size: 20)
      } trailing: {
        spend(store.summary?.totals.totalCost)
      }
      Section("Subscriptions") {
        ForEach(subscriptions, id: \.self) { agent in
          row(id: agent, title: harnessName(agent)) {
            HarnessIcon(agent: agent, size: 20)
          } trailing: {
            quotaBadge(agent)
          }
        }
      }
      if !others.isEmpty {
        Section("Agents") {
          ForEach(others, id: \.self) { agent in
            row(id: agent, title: harnessName(agent)) {
              HarnessIcon(agent: agent, size: 20)
            } trailing: {
              spend(store.summary?.agents.first { $0.agent == agent }?.totalCost)
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
  }

  private func row<Icon: View, Trailing: View>(
    id: String, title: String, @ViewBuilder icon: () -> Icon,
    @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    HStack(spacing: 9) {
      icon()
      Text(title).lineLimit(1)
      Spacer(minLength: 6)
      trailing()
    }
    .padding(.vertical, 2)
    .tag(id)
  }

  @ViewBuilder private func spend(_ value: Double?) -> some View {
    if let value {
      Text(currency(value)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private func quotaBadge(_ agent: String) -> some View {
    if let source = QuotaSource(rawValue: agent),
      let remaining = remainingQuota(
        for: source, forecast: store.forecast(for: agent),
        cursorAccount: store.summary?.cursorAccount,
        claudeAccount: store.summary?.claudeAccount)
    {
      let tone: Color = remaining < 15 ? BurnTheme.behind : remaining < 35 ? .orange : .green
      Text(menuBarQuotaText(remaining))
        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
        .foregroundStyle(tone)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tone.opacity(0.14), in: Capsule())
        .help("\(source.label) quota remaining")
    }
  }
}

struct QuotaSourceMenu: View {
  @Environment(UsageStore.self) private var store
  var body: some View {
    @Bindable var store = store
    Menu {
      ForEach(QuotaSource.allCases) { source in
        Button {
          store.quotaSource = source
        } label: {
          HStack {
            Text(source.label)
            Spacer()
            if let remaining = remainingQuota(
              for: source, forecast: store.forecast(for: source.rawValue),
              cursorAccount: store.summary?.cursorAccount,
              claudeAccount: store.summary?.claudeAccount)
            {
              Text(menuBarQuotaText(remaining))
            }
          }
        }
      }
    } label: {
      Text(
        menuBarQuotaText(
          store.remainingPercent, stale: store.quotaIsStale(at: store.quotaCheckDate))
      )
      .monospacedDigit()
      .fontWeight(.medium)
      .fixedSize()
    }
    .menuIndicator(.visible)
    .fixedSize()
    .id(store.remainingPercent ?? -1)
    .help("Quota shown in the menu bar")
    .accessibilityLabel(
      "\(store.quotaSource.label) \(menuBarQuotaText(store.remainingPercent))")
  }
}

struct QuotaSourceSettings: View {
  @Environment(UsageStore.self) private var store
  var body: some View {
    @Bindable var store = store
    Section("Menu bar quota") {
      Picker("Show remaining", selection: $store.quotaSource) {
        ForEach(QuotaSource.allCases) { source in
          Text(source.label).tag(source)
        }
      }
      Text(
        "The flame in the menu bar and the window toolbar show this remaining percentage. Codex uses the live weekly account meter, Claude uses its weekly limit, and Cursor uses promotional credits while those remain, otherwise the included allowance."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct SettingsView: View {
  var body: some View {
    TabView {
      Form {
        LoginItemSettings()
        AppearanceSettings()
        QuotaSourceSettings()
      }
      .formStyle(.grouped)
      .tabItem { Label("General", systemImage: "gearshape") }
      DataSettings()
        .tabItem { Label("Data", systemImage: "externaldrive") }
      Form { QuotaCollectionSettings() }
        .formStyle(.grouped)
        .tabItem { Label("Background", systemImage: "clock.arrow.circlepath") }
      Form { UpdateSettings() }
        .formStyle(.grouped)
        .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
      AboutSettings()
        .tabItem { Label("About", systemImage: "flame") }
    }
    .frame(width: 560, height: 520)
    .tint(BurnTheme.flame)
  }
}

private struct AboutSettings: View {
  var body: some View {
    VStack(spacing: 14) {
      Spacer()
      Image(nsImage: AppLogo.window).resizable().interpolation(.high)
        .frame(width: 96, height: 96)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .accessibilityHidden(true)
      VStack(spacing: 4) {
        Text("Agent Burn").font(.system(size: 22, weight: .bold, design: .rounded))
        Text("Version \(bundleVersionText())").font(.system(size: 12))
          .foregroundStyle(.secondary).monospacedDigit()
      }
      Text(
        "Spend, tokens and subscription limits for your coding agents. Usage is read from local logs and never sent to an Agent Burn service."
      )
      .font(.system(size: 12)).foregroundStyle(.secondary)
      .multilineTextAlignment(.center).frame(maxWidth: 380)
      HStack(spacing: 10) {
        Link(destination: URL(string: "https://agent-burn.melvynx.dev")!) {
          Label("Website", systemImage: "safari")
        }
        Link(destination: URL(string: "https://github.com/AurelienRM/agent-burn")!) {
          Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        Link(destination: URL(string: "https://agent-burn.melvynx.dev/docs")!) {
          Label("Docs", systemImage: "book")
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.regular)
      Spacer()
      Text("MIT licensed · Based on ccusage").font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct DataSettings: View {
  @Environment(UsageStore.self) private var store
  var body: some View {
    @Bindable var store = store
    Form {
      Section("Data source") {
        TextField("CLI executable", text: $store.customPath, prompt: Text("Bundled agent-burn"))
          .help("Absolute path to the native agent-burn executable")
        Button("Choose executable…") {
          let panel = NSOpenPanel()
          panel.canChooseDirectories = false
          panel.allowsMultipleSelection = false
          panel.message = String(localized: "Choose the native agent-burn executable.")
          if panel.runModal() == .OK, let url = panel.url { store.customPath = url.path }
        }
        Toggle("Use cached pricing and limits", isOn: $store.offline)
        Text(
          "Cached mode skips live subscription requests. Otherwise, the CLI may contact pricing and harness providers."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Log folders") {
        TextField("Codex homes", text: $store.codexHomes, axis: .vertical)
          .lineLimit(2...4).font(.system(.caption, design: .monospaced))
        Text(
          "Comma-separated Codex folders. The normal ~/.codex folder is included alongside the launching profile. Sessions and archived sessions are read by the CLI."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Refresh") {
        Picker("Automatically refresh", selection: $store.refreshMinutes) {
          Text("Every minute").tag(1)
          Text("Every 5 minutes").tag(5)
          Text("Every 15 minutes").tag(15)
          Text("Every 30 minutes").tag(30)
        }
        Button(store.isLoading ? "Refreshing…" : "Apply and refresh") {
          Task { await store.refreshAll() }
        }
      }
    }
    .formStyle(.grouped)
  }
}
