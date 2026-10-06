import SwiftUI

enum BurnTheme {
  static let background = Color(nsColor: .windowBackgroundColor)
  static let surface = Color(nsColor: .controlBackgroundColor)
  static let elevated = Color(nsColor: .quaternaryLabelColor).opacity(0.12)
  static let ink = Color.primary
  static let muted = Color.secondary
  static let accent = Color.accentColor
  static let green = Color.green
  static let line = Color(nsColor: .separatorColor).opacity(0.5)
  static let grid = Color(nsColor: .separatorColor)
  static let flame = adaptiveQuotaColor(
    light: NSColor(red: 0.86, green: 0.36, blue: 0.05, alpha: 1),
    dark: NSColor(red: 1, green: 0.52, blue: 0.2, alpha: 1))
  static let card = adaptiveQuotaColor(
    light: NSColor(white: 1, alpha: 0.9), dark: NSColor(white: 1, alpha: 0.055))
  static let cardStroke = adaptiveQuotaColor(
    light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.08))
  static let track = adaptiveQuotaColor(
    light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.1))
  static let hover = adaptiveQuotaColor(
    light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 1, alpha: 0.05))
  /// Recessed panels inside a card.
  static let inset = adaptiveQuotaColor(
    light: NSColor(white: 0, alpha: 0.025), dark: NSColor(white: 0, alpha: 0.16))
  // Pace status: recorded remaining above the ideal line is ahead, below is behind.
  static let ahead = Color.green
  static let behind = Color.red

  // Compact quota text and chart strokes must stay legible on menu material in both appearances.
  static let quotaMuted = adaptiveQuotaColor(
    light: NSColor(white: 0.38, alpha: 1), dark: NSColor(white: 0.68, alpha: 1))
  private static let quotaClaude = adaptiveQuotaColor(
    light: NSColor(red: 0.55, green: 0.26, blue: 0.02, alpha: 1), dark: .systemOrange)

  static func quotaColor(for agent: String) -> Color {
    agent == "claude"
      ? quotaClaude
      : adaptiveQuotaColor(
        light: NSColor(red: 0.04, green: 0.43, blue: 0.18, alpha: 1), dark: .systemGreen)
  }

  private static func adaptiveQuotaColor(light: NSColor, dark: NSColor) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      })
  }

  static func color(for agent: String) -> Color {
    switch agent {
    case "codex": green
    case "claude": .orange
    case "cursor": .purple
    case "opencode": .indigo
    case "openclaw": .red
    case "droid": .teal
    case "gemini": .blue
    case "pi": .yellow
    case "kimi": .cyan
    case "amp": .pink
    default: .gray
    }
  }
}

struct HarnessIcon: View {
  let agent: String
  var size: CGFloat = 32
  var body: some View {
    Group {
      if let image = BrandImages.images[agent] {
        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
      } else {
        Text(String(harnessName(agent).prefix(2))).font(
          .system(size: size * 0.4, weight: .semibold)
        )
        .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

struct StatusBadge: View {
  let text: String
  var color: Color = BurnTheme.green
  var body: some View {
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 5, height: 5)
      Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
    }
    .foregroundStyle(color)
    .padding(.horizontal, 9).padding(.vertical, 5)
    .background(color.opacity(0.09), in: Capsule())
  }
}

struct SectionLabel: View {
  let title: String
  var detail: String = ""
  var body: some View {
    HStack {
      Text(title).font(.system(size: 14, weight: .semibold))
      Spacer()
      if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(BurnTheme.muted) }
    }
  }
}

struct RefreshFooter: View {
  @Environment(UsageStore.self) private var store
  let source: String
  var compact = false
  var body: some View {
    HStack(spacing: 7) {
      Circle().fill(store.errors[source] == nil ? BurnTheme.green : BurnTheme.accent).frame(
        width: 5, height: 5)
      if let date = store.updated[source] {
        // One sentence so each language can place the live duration ("il y a 3 s").
        let elapsed = Text(date, style: .relative)
        Text(
          store.errors[source] == nil
            ? "Updated \(elapsed) ago" : "Last successful update \(elapsed) ago")
      } else if source == "summary", store.summary != nil {
        Text("Saved usage")
      } else if store.isLoading {
        Text("Updating usage…")
      } else {
        Text("Waiting for usage")
      }
      Spacer()
      Text(bundleVersionText())
        .monospacedDigit()
        .accessibilityLabel("App version")
      QuotaCheckButton()
      Button {
        Task { await store.refreshAll() }
      } label: {
        Image(systemName: "arrow.clockwise")
          .symbolEffect(.pulse, isActive: store.isLoading)
      }
      .buttonStyle(.plain).disabled(store.isLoading)
      .help("Refresh usage and live quotas (⌘R)").accessibilityLabel("Refresh usage")
    }
    .font(.system(size: 11)).foregroundStyle(compact ? BurnTheme.quotaMuted : BurnTheme.muted)
  }
}

/// Hard refresh: re-reads every live quota now instead of waiting for the
/// next background collection.
struct QuotaCheckButton: View {
  @Environment(UsageStore.self) private var store
  var label = false

  var body: some View {
    Button {
      Task { await store.refreshAll(hard: true) }
    } label: {
      if label {
        Label("Check now", systemImage: "gauge.with.dots.needle.67percent")
      } else {
        Image(systemName: "gauge.with.dots.needle.67percent")
      }
    }
    .symbolEffect(.pulse, isActive: store.isCheckingQuotas)
    .buttonStyle(.plain).disabled(store.isCheckingQuotas)
    .help(
      "Check live usage now (⇧⌘R). Bypasses saved readings."
    )
    .accessibilityLabel("Check live usage now")
  }
}

struct ReportNotice: View {
  let message: String
  var body: some View {
    Label(message, systemImage: "exclamationmark.circle")
      .font(.system(size: 12)).foregroundStyle(BurnTheme.flame)
      .fixedSize(horizontal: false, vertical: true)
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(
        BurnTheme.flame.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

struct BurnCardModifier: ViewModifier {
  var padding: CGFloat = 16
  var radius: CGFloat = 14
  func body(content: Content) -> some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(BurnTheme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(BurnTheme.cardStroke, lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
  }
}

extension View {
  func burnCard(padding: CGFloat = 16, radius: CGFloat = 14) -> some View {
    modifier(BurnCardModifier(padding: padding, radius: radius))
  }
}

struct IconBadge: View {
  let symbol: String
  var tint: Color = BurnTheme.flame
  var size: CGFloat = 22
  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.5, weight: .semibold))
      .foregroundStyle(tint)
      .frame(width: size, height: size)
      .background(
        tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
      )
      .accessibilityHidden(true)
  }
}

struct CardHeader<Trailing: View>: View {
  let title: String
  var symbol: String? = nil
  var tint: Color = BurnTheme.flame
  @ViewBuilder var trailing: Trailing
  var body: some View {
    HStack(spacing: 8) {
      if let symbol { IconBadge(symbol: symbol, tint: tint) }
      Text(title).font(.system(size: 13, weight: .semibold))
      Spacer(minLength: 8)
      trailing.font(.system(size: 11)).foregroundStyle(BurnTheme.muted)
    }
  }
}

extension CardHeader where Trailing == EmptyView {
  init(title: String, symbol: String? = nil, tint: Color = BurnTheme.flame) {
    self.init(title: title, symbol: symbol, tint: tint) { EmptyView() }
  }
}

struct MetricTile: View {
  let title: String
  let value: String
  var detail = ""
  var symbol: String? = nil
  var tint: Color = BurnTheme.flame
  var compact = false
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 6 : 8) {
      HStack(spacing: 7) {
        if let symbol { IconBadge(symbol: symbol, tint: tint, size: compact ? 18 : 20) }
        Text(title).font(.system(size: compact ? 11 : 12, weight: .medium))
          .foregroundStyle(compact ? BurnTheme.quotaMuted : BurnTheme.muted).lineLimit(1)
      }
      Text(value)
        .font(.system(size: compact ? 21 : 24, weight: .semibold, design: .rounded))
        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        .contentTransition(.numericText())
        .animation(.snappy, value: value)
      if !detail.isEmpty {
        Text(detail).font(.system(size: compact ? 10 : 11))
          .foregroundStyle(compact ? BurnTheme.quotaMuted : BurnTheme.muted).lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

struct ShareBar: View {
  let value: Double
  var tint: Color = BurnTheme.flame
  var height: CGFloat = 5
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(BurnTheme.track)
        Capsule().fill(tint.gradient)
          .frame(width: max(height, geometry.size.width * clamped))
          .opacity(clamped > 0 ? 1 : 0)
      }
    }
    .frame(height: height)
    .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: clamped)
    .accessibilityHidden(true)
  }
  private var clamped: Double { max(0, min(1, value)) }
}

struct HoverRow: ViewModifier {
  @State private var hovering = false
  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 8).padding(.vertical, 6)
      .background(
        hovering ? BurnTheme.hover : .clear,
        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.12), value: hovering)
  }
}

extension View {
  func hoverRow() -> some View { modifier(HoverRow()) }
}
