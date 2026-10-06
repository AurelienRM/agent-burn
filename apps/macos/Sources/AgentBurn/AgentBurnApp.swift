import SwiftUI

@main
enum AgentBurnMain {
  @MainActor static func main() async {
    if CommandLine.arguments.contains("--collect-quotas") {
      do { try await QuotaCollector.collect() } catch {
        FileHandle.standardError.write(
          Data("Quota collection failed: \(error.localizedDescription)\n".utf8))
        exit(1)
      }
    } else {
      AgentBurnApp.main()
    }
  }
}

struct AgentBurnApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var store: UsageStore

  init() {
    let store = UsageStore()
    _store = State(initialValue: store)
    Task { await store.start() }
  }
  var body: some Scene {
    Window("Agent Burn", id: "overview") {
      DashboardView().environment(store)
    }
    .defaultSize(width: 1240, height: 820)
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified)
    .commands {
      UpdateCommands()
      UsageCommands(store: store)
    }
    MenuBarExtra {
      MenuPopover().environment(store)
    } label: {
      // TimelineView in a MenuBarExtra label can continuously invalidate the status item.
      MenuBarLabel(
        remaining: store.remainingPercent, stale: store.quotaIsStale(at: store.quotaCheckDate))
    }
    .menuBarExtraStyle(.window)
    Settings { SettingsView().environment(store) }
  }
}

struct UsageCommands: Commands {
  let store: UsageStore

  var body: some Commands {
    CommandMenu("Usage") {
      Button("Refresh") { Task { await store.refreshAll() } }
        .keyboardShortcut("r")
      Button("Check Live Usage Now") { Task { await store.refreshAll(hard: true) } }
        .keyboardShortcut("r", modifiers: [.command, .shift])
    }
  }
}

struct MenuBarLabel: View {
  let remaining: Double?
  var stale = false
  var body: some View {
    HStack(spacing: 4) {
      Image(nsImage: AppLogo.menuBar)
        .resizable()
        .renderingMode(.original)
        .frame(width: 18, height: 18)
      Text(menuBarQuotaText(remaining, stale: stale)).monospacedDigit()
    }
    .accessibilityLabel("Agent Burn \(menuBarQuotaText(remaining, stale: stale))")
  }
}
