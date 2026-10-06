import Combine
import Sparkle
import SwiftUI

@MainActor final class AppUpdater: ObservableObject {
  static let shared = AppUpdater()
  private let controller: SPUStandardUpdaterController
  @Published private(set) var canCheck = false
  private var observation: AnyCancellable?

  /// Plain SwiftPM executables, render tests and fork builds have no update feed.
  static let isConfigured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil

  private init() {
    controller = SPUStandardUpdaterController(
      startingUpdater: Self.isConfigured, updaterDelegate: nil, userDriverDelegate: nil)
    observation = controller.updater.publisher(for: \.canCheckForUpdates)
      .receive(on: RunLoop.main)
      .sink { [weak self] in self?.canCheck = $0 }
  }

  var automaticallyChecks: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }

  func check() { controller.checkForUpdates(nil) }
}

struct UpdateSettings: View {
  @ObservedObject private var updater = AppUpdater.shared
  var body: some View {
    Section("App updates") {
      if AppUpdater.isConfigured { controls } else {
        Text("Automatic updates are off in this build. Pull the fork and rebuild to update.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private var controls: some View {
    Group {
      Toggle(
        "Automatically check for updates",
        isOn: Binding(
          get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
      Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
      Text("Signed updates are delivered from the open-source GitHub releases.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct UpdateCommands: Commands {
  @ObservedObject private var updater = AppUpdater.shared
  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
    }
  }
}
