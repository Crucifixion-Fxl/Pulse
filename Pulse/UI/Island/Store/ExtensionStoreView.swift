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
      // An overlay does not contribute its ideal height to the parent.
      // The hidden full-height store must not stretch the authorization pane.
      Color.clear.overlay(alignment: .top) { store() }
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
  @StateObject private var browser: ExtensionStoreBrowser
  @FocusState private var searchFocused: Bool
  private let accent = Color(red: 0.69, green: 0.62, blue: 1)
  private let projectURL = URL(string: "https://github.com/Crucifixion-Fxl/Pulse")!
  private var voiceInstalled: Bool { XiaozhiVoiceSession.isInstalled }
  private var results: [PulseExtension] {
    browser.results(preferences: model.extensionPreferences, voiceInstalled: voiceInstalled)
  }
  private var selected: PulseExtension? {
    ExtensionCatalog.entries.first { $0.id == browser.selectedID }
  }

  init(browser: ExtensionStoreBrowser = ExtensionStoreBrowser()) {
    _browser = StateObject(wrappedValue: browser)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      if browser.showsDeveloper {
        developerContent
      } else if let selected {
        detail(selected)
      } else {
        catalog
      }
    }
    .frame(height: 420, alignment: .top)
    .padding(.horizontal, 16)
    .background {
      GeometryReader { geometry in
        Color.clear.preference(key: ExtensionStoreHeightKey.self, value: geometry.size.height)
      }
    }
    .foregroundStyle(.white)
    .environment(\.colorScheme, .dark)
    .onChange(of: model.isExtensionStorePresented) { _, presented in
      if !presented { searchFocused = false }
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      if selected != nil || browser.showsDeveloper {
        Button { browser.back() } label: {
          Label("market.back", systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
        }.buttonStyle(.plain).foregroundStyle(.secondary)
          .accessibilityIdentifier("market-back")
        Divider().frame(height: 16)
      }
      Text("store.title").font(.system(size: 20, weight: .semibold))
      Spacer(minLength: 4)
      if selected == nil && !browser.showsDeveloper {
        HStack(spacing: 2) {
          ForEach(ExtensionStoreBrowser.Scope.allCases, id: \.self) { scope in
            Button { browser.scope = scope } label: {
              Text(LocalizedStringKey(scope.titleKey))
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(browser.scope == scope ? .white.opacity(0.12) : .clear,
                  in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain)
              .foregroundStyle(browser.scope == scope ? .white : .white.opacity(0.5))
              .accessibilityAddTraits(browser.scope == scope ? .isSelected : [])
              .accessibilityIdentifier("market-scope-\(scope.rawValue)")
          }
        }.padding(3).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        Button { searchFocused = false; browser.showsDeveloper = true } label: {
          Label("market.developer", systemImage: "chevron.left.forwardslash.chevron.right")
            .font(.system(size: 11, weight: .medium))
        }.buttonStyle(.plain).foregroundStyle(accent)
          .accessibilityIdentifier("market-developer")
      }
    }.frame(height: 36)
  }

  private var catalog: some View {
    VStack(spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("market.search", text: $browser.query)
          .textFieldStyle(.plain).font(.system(size: 13))
          .focused($searchFocused).accessibilityIdentifier("market-search")
        if !browser.query.isEmpty {
          Button { browser.query = ""; searchFocused = true } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }.buttonStyle(.plain).help(Text("market.clear"))
            .accessibilityLabel(Text("market.clear"))
        }
      }
      .padding(.horizontal, 12).frame(height: 36)
      .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
      .overlay(RoundedRectangle(cornerRadius: 9)
        .strokeBorder(searchFocused ? accent.opacity(0.7) : .white.opacity(0.08), lineWidth: 1))

      HStack(spacing: 6) {
        ForEach(ExtensionCategory.allCases) { category in
          Button { browser.category = category } label: {
            Text(LocalizedStringKey(category.titleKey)).font(.system(size: 11, weight: .medium))
              .padding(.horizontal, 11).padding(.vertical, 5)
              .background(browser.category == category ? accent.opacity(0.15) : .clear, in: Capsule())
          }.buttonStyle(.plain)
            .foregroundStyle(browser.category == category ? accent : .white.opacity(0.5))
            .accessibilityAddTraits(browser.category == category ? .isSelected : [])
            .accessibilityIdentifier("market-category-\(category.rawValue)")
        }
        Spacer(minLength: 0)
        Text(String(format: L10n.text("market.count"), results.count))
          .font(.system(size: 10)).foregroundStyle(.secondary)
      }

      Group {
        if results.isEmpty {
          VStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 28, weight: .light)).foregroundStyle(accent)
            Text("market.empty").font(.system(size: 15, weight: .medium))
            Text("market.empty.detail").font(.system(size: 11)).foregroundStyle(.secondary)
            Button("market.reset") { browser.resetFilters() }.buttonStyle(.bordered)
              .accessibilityIdentifier("market-reset")
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          let entries = browser.visibleEntries(in: results)
          VStack(spacing: 10) {
            ForEach(0..<2, id: \.self) { row in
              HStack(spacing: 10) {
                ForEach(0..<2, id: \.self) { column in
                  let index = row * 2 + column
                  if index < entries.count {
                    card(entries[index]).frame(maxWidth: .infinity)
                  } else {
                    Color.clear.frame(maxWidth: .infinity).frame(height: 114)
                  }
                }
              }
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
      }.frame(height: 238)

      HStack {
        Label("market.bundled.note", systemImage: "shippingbox")
          .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
        Spacer()
        Button { browser.page = browser.currentPage(for: results) - 1 } label: {
          Image(systemName: "chevron.left").frame(width: 24, height: 24)
        }.disabled(browser.currentPage(for: results) == 0)
          .accessibilityLabel(Text("market.previous")).accessibilityIdentifier("market-previous")
        Text("\(browser.currentPage(for: results) + 1) / \(browser.pageCount(for: results))")
          .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(minWidth: 38)
        Button { browser.page = browser.currentPage(for: results) + 1 } label: {
          Image(systemName: "chevron.right").frame(width: 24, height: 24)
        }.disabled(browser.currentPage(for: results) + 1 >= browser.pageCount(for: results))
          .accessibilityLabel(Text("market.next")).accessibilityIdentifier("market-next")
      }.buttonStyle(.plain).frame(height: 24)
    }
  }

  private func card(_ entry: PulseExtension) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Button { searchFocused = false; browser.show(entry) } label: {
        HStack(alignment: .top, spacing: 11) {
          icon(entry, size: 38)
          VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(entry.titleKey)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(LocalizedStringKey(entry.summaryKey)).font(.system(size: 11))
              .foregroundStyle(.white.opacity(0.55)).lineLimit(2)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.25))
        }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 48, alignment: .top)
          .contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityIdentifier("market-open-\(entry.slug)")
      HStack(spacing: 5) {
        Text(entry.publisher).foregroundStyle(.white.opacity(0.5))
        Text("·").foregroundStyle(.white.opacity(0.25))
        Text("market.bundled").foregroundStyle(.white.opacity(0.35))
        Spacer(minLength: 0)
        action(entry)
      }.font(.system(size: 10))
    }
    .padding(12).frame(height: 114)
    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.065), lineWidth: 1))
  }

  private func icon(_ entry: PulseExtension, size: CGFloat) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.23).fill(tint(entry).opacity(0.13))
      if case .character(let character) = entry.capability {
        CollapsedBotFaceView(size: size * 0.62, isPlaying: false, isHovered: false,
          isAnimated: false, character: character)
      } else {
        Image(systemName: entry.symbol).font(.system(size: size * 0.48, weight: .medium)).foregroundStyle(tint(entry))
      }
    }.frame(width: size, height: size).accessibilityHidden(true)
  }

  private func tint(_ entry: PulseExtension) -> Color {
    switch entry.category {
    case .productivity: Color(red: 0.48, green: 0.69, blue: 1)
    case .status: Color(red: 0.93, green: 0.73, blue: 0.38)
    case .appearance: accent
    case .voice: Color(red: 0.4, green: 0.82, blue: 0.72)
    case .all: accent
    }
  }

  @ViewBuilder
  private func action(_ entry: PulseExtension) -> some View {
    if case .voice(let id) = entry.capability, !voiceInstalled {
      Link(destination: VoiceProviderRegistry.provider(id: id).setupURL) {
        Label("market.setup", systemImage: "arrow.up.right")
      }.buttonStyle(.plain).foregroundStyle(accent)
    } else {
      let active = entry.isEnabled(in: model.extensionPreferences)
      let mutable = entry.canChange(in: model.extensionPreferences)
      Button {
        var preferences = model.extensionPreferences
        entry.apply(to: &preferences)
        model.extensionPreferences = preferences
      } label: {
        HStack(spacing: 4) {
          if active { Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)) }
          Text(LocalizedStringKey(active ? "market.active" : "market.enable"))
        }.padding(.horizontal, 9).frame(height: 23)
          .background(active ? .white.opacity(0.06) : accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
      }.buttonStyle(.plain).foregroundStyle(active ? .white.opacity(0.6) : accent)
        .disabled(!mutable)
        .help(Text(actionHelp(entry)))
        .accessibilityLabel(Text(LocalizedStringKey(entry.titleKey)) + Text(" · ") + Text(LocalizedStringKey(actionHelp(entry))))
        .accessibilityIdentifier("market-action-\(entry.slug)")
    }
  }

  private func actionHelp(_ entry: PulseExtension) -> String {
    guard entry.canChange(in: model.extensionPreferences) else {
      switch entry.capability {
      case .bar: return "store.bars.note"
      case .status: return "store.status.note"
      default: return "market.active"
      }
    }
    return entry.isEnabled(in: model.extensionPreferences) ? "market.disable" : "market.enable"
  }

  private func detail(_ entry: PulseExtension) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 16) {
        icon(entry, size: 58)
        VStack(alignment: .leading, spacing: 6) {
          Text(LocalizedStringKey(entry.titleKey)).font(.system(size: 23, weight: .semibold))
          HStack(spacing: 8) {
            Text(entry.publisher)
            Text("·")
            Text(LocalizedStringKey(entry.category.titleKey))
            Text("market.bundled").padding(.horizontal, 6).padding(.vertical, 2)
              .background(.white.opacity(0.08), in: Capsule())
          }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Spacer()
        action(entry).font(.system(size: 12, weight: .medium))
      }
      Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
      HStack(alignment: .top, spacing: 24) {
        VStack(alignment: .leading, spacing: 12) {
          Text("market.overview").font(.system(size: 12, weight: .semibold))
          Text(LocalizedStringKey(entry.summaryKey)).font(.system(size: 15, weight: .medium))
          Text(LocalizedStringKey(entry.detailKey)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Link(destination: projectURL) {
            Label("market.source", systemImage: "arrow.up.right").font(.system(size: 11))
          }.foregroundStyle(accent)
        }.frame(maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .leading, spacing: 16) {
          metadata("market.publisher", value: entry.publisher)
          metadata("market.identifier", value: entry.id)
          metadata("market.distribution", value: L10n.text("market.bundled"))
          metadata("market.updates", value: L10n.text("market.updates.detail"))
        }.frame(width: 172, alignment: .leading).padding(16)
          .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
      }
    }.padding(.top, 12).frame(maxHeight: .infinity, alignment: .top)
      .padding(.bottom, 12).accessibilityIdentifier("market-detail-\(entry.slug)")
  }

  private func metadata(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(LocalizedStringKey(title)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
      Text(value).font(.system(size: 11)).textSelection(.enabled)
    }
  }

  private var developerContent: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 16) {
        Image(systemName: "shippingbox").font(.system(size: 28, weight: .light)).foregroundStyle(accent)
          .frame(width: 62, height: 62).background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        VStack(alignment: .leading, spacing: 7) {
          Text("market.developer.title").font(.system(size: 22, weight: .semibold))
          Text("market.developer.subtitle").font(.system(size: 12)).foregroundStyle(.secondary)
        }
      }
      HStack(alignment: .top, spacing: 12) {
        developerStep("puzzlepiece.extension", title: "market.developer.build", detail: "market.developer.build.detail")
        developerStep("person.crop.square", title: "market.developer.identity", detail: "market.developer.identity.detail")
        developerStep("shippingbox", title: "market.developer.publish", detail: "market.developer.publish.detail")
      }
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "info.circle").foregroundStyle(accent)
        Text("market.developer.status").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
      }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
      HStack(spacing: 16) {
        Link(destination: projectURL.appendingPathComponent("blob/main/docs/EXTENSION-DEVELOPMENT.md")) {
          Label("market.developer.guide", systemImage: "arrow.up.right")
        }.foregroundStyle(accent)
        Link("market.source", destination: projectURL).foregroundStyle(.secondary)
        Spacer()
        Text("market.developer.pending").foregroundStyle(.white.opacity(0.35))
      }.font(.system(size: 11))
    }.padding(.top, 8).frame(maxHeight: .infinity, alignment: .top)
      .accessibilityIdentifier("market-developer-page")
  }

  private func developerStep(_ symbol: String, title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: symbol).foregroundStyle(accent).font(.system(size: 18))
      Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .semibold))
      Text(LocalizedStringKey(detail)).font(.system(size: 11)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
    }.frame(maxWidth: .infinity, minHeight: 98, alignment: .topLeading).padding(14)
      .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
  }
}
