import AppKit
import SwiftUI

struct WeatherStatusView: View {
  @ObservedObject var store: WeatherStore
  let isActive: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showsDetails = false

  var body: some View {
    Button { showsDetails.toggle() } label: {
      HStack(spacing: 7) {
        Spacer(minLength: 0)
        Image(systemName: store.snapshot?.symbol ?? "cloud.sun.fill")
          .symbolRenderingMode(.palette)
          .foregroundStyle(iconColor, .white.opacity(0.85))
          .font(.system(size: 18, weight: .medium))
          .frame(width: 24)
          .contentTransition(.symbolEffect(.replace))
        if let weather = store.snapshot {
          Text(weather.temperatureText)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
            .fixedSize()
          VStack(alignment: .leading, spacing: 1) {
            Text(weather.city).font(.system(size: 10, weight: .medium))
            Text(L10n.text(store.isStale ? "weather.stale" : weather.conditionKey))
              .font(.system(size: 9)).foregroundStyle(.white.opacity(0.48))
          }
          .lineLimit(1)
          .truncationMode(.tail)
        } else {
          VStack(alignment: .leading, spacing: 1) {
            Text(L10n.text("weather.title")).font(.system(size: 11, weight: .medium))
            Text(L10n.text(store.issue?.messageKey ?? "weather.locating"))
              .font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
          }.lineLimit(1)
        }
      }
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityText)
    .accessibilityHidden(!isActive)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: store.snapshot)
    .popover(isPresented: $showsDetails, arrowEdge: .bottom) { details.preferredColorScheme(.dark) }
    .task(id: isActive) {
      guard isActive else { showsDetails = false; return }
      while !Task.isCancelled {
        await store.refresh()
        do { try await Task.sleep(for: .seconds(120)) } catch { return }
      }
    }
  }

  private var iconColor: Color {
    guard let weather = store.snapshot else { return .white.opacity(0.5) }
    if weather.code >= 51 { return .cyan.opacity(0.9) }
    return weather.isDay ? .yellow : Color(red: 0.65, green: 0.72, blue: 1)
  }

  private var accessibilityText: String {
    guard let weather = store.snapshot else { return L10n.text(store.issue?.messageKey ?? "weather.locating") }
    return "\(weather.city) \(weather.temperatureText)C \(L10n.text(weather.conditionKey))"
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let weather = store.snapshot {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(weather.city).font(.headline)
            Text(L10n.text(weather.conditionKey)).foregroundStyle(.secondary)
          }
          Spacer()
          Image(systemName: weather.symbol).symbolRenderingMode(.multicolor).font(.system(size: 28))
        }
        Text("\(weather.temperatureText)C").font(.system(size: 34, weight: .light, design: .rounded))
        Text(String(format: L10n.text("weather.high-low"), Int(weather.high.rounded()), Int(weather.low.rounded())))
          .font(.system(size: 12)).foregroundStyle(.secondary)
        HStack(spacing: 4) {
          Text(L10n.text(store.isStale ? "weather.last-update" : "weather.updated"))
          Text(weather.observedAt, style: .time)
        }.font(.system(size: 10)).foregroundStyle(.secondary)
      } else {
        Text(L10n.text("weather.title")).font(.headline)
        Text(L10n.text(store.issue?.messageKey ?? "weather.locating"))
          .font(.system(size: 12)).foregroundStyle(.secondary)
      }
      if store.issue == .locationDenied {
        Button(L10n.text("weather.location-settings")) {
          NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
        }
      }
      HStack {
        Link("Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
          .font(.system(size: 10)).foregroundStyle(.secondary)
        Spacer()
        Button {
          Task { await store.refresh(force: true) }
        } label: {
          Image(systemName: "arrow.clockwise")
        }.buttonStyle(.plain).disabled(store.isLoading)
          .help(L10n.text("weather.refresh"))
          .accessibilityLabel(L10n.text("weather.refresh"))
      }
    }
    .padding(18)
    .frame(width: 240)
  }
}
