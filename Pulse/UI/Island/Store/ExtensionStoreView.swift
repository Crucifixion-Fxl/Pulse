import SwiftUI

struct ExtensionStoreHeightKey: PreferenceKey {
  static var defaultValue: CGFloat { 0 }
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// Keep both destinations mounted for the expanded session. Only their
/// opacity animates; controls, scroll position and layout survive a toggle.
struct ExtensionStoreTransition<Panel: View, Store: View>: View {
  let isPresented: Bool
  let reduceMotion: Bool
  @ViewBuilder var panel: () -> Panel
  @ViewBuilder var store: () -> Store

  var body: some View {
    ZStack(alignment: .top) {
      panel()
        .transaction { $0.animation = nil }
        .opacity(isPresented ? 0 : 1)
        .allowsHitTesting(!isPresented)
        .accessibilityElement(children: .contain)
        .accessibilityHidden(isPresented)
      store()
        .transaction { $0.animation = nil }
        .opacity(isPresented ? 1 : 0)
        .allowsHitTesting(isPresented)
        .accessibilityElement(children: .contain)
        .accessibilityHidden(!isPresented)
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isPresented)
  }
}

struct ExtensionStoreButton: View {
  @EnvironmentObject private var model: AppModel
  var displayID: String?

  var body: some View {
    if model.canUseActiveList {
      Button { model.toggleExtensionStore(on: displayID) } label: {
        Image(systemName: model.isExtensionStorePresented ? "square.grid.2x2.fill" : "square.grid.2x2")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.white.opacity(0.8))
          .frame(width: 24, height: 26)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(Text(model.isExtensionStorePresented ? "store.close" : "store.open"))
      .accessibilityLabel(Text(model.isExtensionStorePresented ? "store.close" : "store.open"))
      .accessibilityIdentifier("extension-store-toggle")
      .accessibilityAddTraits(model.isExtensionStorePresented ? .isSelected : [])
    }
  }
}

struct ExtensionStoreView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("store.title").font(.system(size: 21, weight: .semibold))
        Text("store.subtitle").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      HStack(alignment: .top, spacing: 14) {
        VStack(alignment: .leading, spacing: 14) {
          section("store.bars") {
            ForEach(IslandSidebarItem.allCases) { item in
              Toggle(isOn: Binding(get: { model.extensionPreferences.bars.contains(item.rawValue) },
                set: { model.extensionPreferences.setBar(item.rawValue, enabled: $0) })) {
                  Label(item.title, systemImage: item.symbol)
                }
                .disabled(model.extensionPreferences.bars == [item.rawValue])
                .accessibilityIdentifier("store-bar-\(item.rawValue)")
            }
            Text("store.bars.note").font(.system(size: 10)).foregroundStyle(.secondary)
          }
          section("store.status") {
            ForEach(ExtensionPreferences.availableStatusItems, id: \.self) { item in
              Toggle(LocalizedStringKey("store.status." + item), isOn: Binding(
                get: { model.extensionPreferences.statusItems.contains(item) },
                set: { model.extensionPreferences.setStatusItem(item, enabled: $0) }))
                .disabled(item == "bot")
                .accessibilityIdentifier("store-status-\(item)")
            }
            Text("store.status.note").font(.system(size: 10)).foregroundStyle(.secondary)
          }
        }
        VStack(alignment: .leading, spacing: 14) {
          section("store.bots") {
            HStack(spacing: 8) {
              ForEach(BotCharacter.allCases) { bot in
                Button { model.extensionPreferences.bot = bot } label: {
                  VStack(spacing: 6) {
                    CollapsedBotFaceView(size: 28, isPlaying: false, isHovered: false,
                      isAnimated: false, character: bot)
                    Text(LocalizedStringKey(bot.titleKey)).font(.system(size: 10))
                  }
                  .frame(maxWidth: .infinity).padding(.vertical, 9)
                  .background(model.extensionPreferences.bot == bot ? .white.opacity(0.16) : .white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey(bot.titleKey)))
                .accessibilityAddTraits(model.extensionPreferences.bot == bot ? .isSelected : [])
              }
            }
          }
          section("store.effects") {
            Picker("store.effects", selection: $model.extensionPreferences.wakeEffect) {
              ForEach(WakeEffect.allCases) { effect in
                Text(LocalizedStringKey(effect.titleKey)).tag(effect)
              }
            }.labelsHidden().pickerStyle(.segmented)
            Text("store.effects.note").font(.system(size: 10)).foregroundStyle(.secondary)
          }
          section("store.providers") {
            ForEach(VoiceProviderRegistry.providers) { provider in
              HStack {
                Button { model.extensionPreferences.voiceProviderID = provider.id } label: {
                  Label(provider.title, systemImage: model.extensionPreferences.voiceProviderID == provider.id
                    ? "checkmark.circle.fill" : "circle")
                }.buttonStyle(.plain)
                Spacer()
                Text(provider.isInstalled() ? "store.installed" : "store.not-installed")
                  .font(.system(size: 10)).foregroundStyle(.secondary)
              }
              Link("store.setup", destination: provider.setupURL).font(.system(size: 11))
            }
            Text("store.providers.note").font(.system(size: 10)).foregroundStyle(.secondary)
          }
        }
      }
      .toggleStyle(.checkbox)
      .font(.system(size: 12))
      .padding(.bottom, 8)
    }
    .padding(.horizontal, 16)
    .fixedSize(horizontal: false, vertical: true)
    .background {
      GeometryReader { geometry in
        Color.clear.preference(key: ExtensionStoreHeightKey.self, value: geometry.size.height)
      }
    }
    .foregroundStyle(.white)
    .environment(\.colorScheme, .dark)
  }

  private func section<Content: View>(_ title: LocalizedStringKey,
    @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
  }
}
