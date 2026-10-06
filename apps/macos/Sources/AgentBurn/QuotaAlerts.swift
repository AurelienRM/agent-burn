import Foundation
import UserNotifications

/// One meter the app can warn about, identified by `key` across launches.
struct QuotaAlertInput: Equatable {
  let key: String
  let title: String
  let remaining: Double
  let reset: Date
}

struct QuotaAlert: Equatable {
  let key: String
  /// Identifies the window or episode already announced, so each fires once.
  let marker: Double
  let title: String
  let body: String
}

let quotaAlertThreshold: Double = 20
/// Claude readings older than this, while the app is collecting, mean the sign-in was lost.
let claudeStaleAlertAge: TimeInterval = 30 * 60

/// Meters at or below the threshold whose current window has not been announced yet.
func quotaAlertsDue(
  _ inputs: [QuotaAlertInput], sent: [String: Double], now: Date,
  threshold: Double = quotaAlertThreshold
) -> [QuotaAlert] {
  inputs.compactMap { input in
    let marker = input.reset.timeIntervalSince1970
    guard input.reset > now, input.remaining <= threshold, sent[input.key] != marker else {
      return nil
    }
    let left = percentText(max(0, input.remaining), digits: 0)
    return QuotaAlert(
      key: input.key, marker: marker,
      title: String(localized: "\(input.title): \(left) left"),
      body: String(
        localized: "Resets in \(quotaDurationLabel(input.reset.timeIntervalSince(now)))."))
  }
}

/// A single alert when Claude stops reporting, announced once per last reading.
func claudeStaleAlertDue(lastReading: Date?, sent: [String: Double], now: Date) -> QuotaAlert? {
  guard let lastReading, now.timeIntervalSince(lastReading) >= claudeStaleAlertAge else {
    return nil
  }
  let marker = lastReading.timeIntervalSince1970
  guard sent["claude-stale"] != marker else { return nil }
  let time = lastReading.formatted(date: .omitted, time: .shortened)
  return QuotaAlert(
    key: "claude-stale", marker: marker,
    title: String(localized: "Claude limits are no longer updating"),
    body: String(
      localized: "No live reading since \(time). Check that Claude Code is signed in."))
}

@MainActor final class QuotaNotifier {
  static let shared = QuotaNotifier()
  private let defaults = UserDefaults.standard
  private static let sentKey = "quotaAlertsSent"

  /// Notifications need a real app bundle; SwiftPM runs and render tests have none.
  static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

  var sent: [String: Double] {
    defaults.dictionary(forKey: Self.sentKey) as? [String: Double] ?? [:]
  }

  func post(_ alerts: [QuotaAlert]) {
    guard Self.isAvailable, !alerts.isEmpty else { return }
    var sent = sent
    for alert in alerts { sent[alert.key] = alert.marker }
    defaults.set(sent, forKey: Self.sentKey)
    Task {
      let center = UNUserNotificationCenter.current()
      guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
        return
      }
      for alert in alerts {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        try? await center.add(
          UNNotificationRequest(
            identifier: "\(alert.key)-\(alert.marker)", content: content, trigger: nil))
      }
    }
  }
}
