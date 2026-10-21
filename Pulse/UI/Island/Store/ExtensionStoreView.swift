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
  @State private var hoveredID: String?
  private let accent = Color(red: 0.56, green: 0.66, blue: 1)
  private let projectURL = URL(string: "https://github.com/Crucifixion-Fxl/Pulse")!
  private var voiceInstalled: Bool { XiaozhiVoiceSession.isInstalled }
  private var results: [PulseExtension] {
    browser.results(preferences: model.extensionPreferences, voiceInstalled: voiceInstalled)
  }
  private var selected: PulseExtension? { browser.selection(in: results) }

  init(browser: ExtensionStoreBrowser = ExtensionStoreBrowser()) {
    _browser = StateObject(wrappedValue: browser)
  }

  var body: some View {
    HStack(spacing: 0) {
      catalogSidebar
        .frame(width: 252)
        .background(.white.opacity(0.025))
        .accessibilityIdentifier("market-catalog-sidebar")
      Rectangle().fill(.white.opacity(0.09)).frame(width: 1)
      Group {
        if browser.showsDeveloper { developerContent }
        else if let selected { detail(selected) }
        else { emptyContent }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(.leading, 24).padding(.trailing, 16).padding(.vertical, 18)
    }
    .frame(height: 420)
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

  private var catalogSidebar: some View {
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        HStack {
          Text("Catalog").font(.system(size: 13, weight: .semibold))
          Spacer()
          Text(String(format: L10n.text("market.count"), results.count))
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.bottom, 12)
        HStack(spacing: 7) {
          Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
          TextField("market.search.short", text: $browser.query)
            .textFieldStyle(.plain).font(.system(size: 12))
            .focused($searchFocused).accessibilityIdentifier("market-search")
          if !browser.query.isEmpty {
            Button { browser.query = ""; searchFocused = true } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }.buttonStyle(.plain).accessibilityLabel(Text("market.clear"))
          }
        }.padding(.horizontal, 9).frame(height: 30)
          .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
          .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(searchFocused ? accent.opacity(0.8) : .white.opacity(0.08), lineWidth: 1))
        HStack(spacing: 12) {
          ForEach(ExtensionStoreBrowser.Scope.allCases, id: \.self) { scope in
            Button { browser.scope = scope; browser.showsDeveloper = false } label: {
              Text(LocalizedStringKey(scope.titleKey))
                .font(.system(size: 11, weight: browser.scope == scope ? .semibold : .regular))
                .frame(height: 32)
                .overlay(alignment: .bottom) {
                  if browser.scope == scope { Rectangle().fill(accent).frame(height: 2) }
                }
            }.buttonStyle(.plain)
              .foregroundStyle(browser.scope == scope ? .white : .white.opacity(0.45))
              .accessibilityAddTraits(browser.scope == scope ? .isSelected : [])
              .accessibilityIdentifier("market-scope-\(scope.rawValue)")
          }
          Spacer(minLength: 0)
          Menu {
            Picker("market.category", selection: $browser.category) {
              ForEach(ExtensionCategory.allCases) { category in
                Text(LocalizedStringKey(category.titleKey)).tag(category)
              }
            }
          } label: {
            Image(systemName: browser.category == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
              .foregroundStyle(browser.category == .all ? .white.opacity(0.5) : accent)
          }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(Text("market.category")).accessibilityLabel(Text("market.category"))
            .accessibilityIdentifier("market-category")
        }
      }.padding(.horizontal, 12).padding(.top, 14)
      .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }

      VStack(spacing: 2) {
        ForEach(browser.visibleEntries(in: results)) { entry in catalogRow(entry) }
        if results.isEmpty {
          Text("market.empty").font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.top, 24).frame(maxWidth: .infinity)
        }
        Spacer(minLength: 0)
      }.padding(.horizontal, 6).padding(.top, 6)

      HStack(spacing: 5) {
        Button { searchFocused = false; browser.showsDeveloper.toggle() } label: {
          Image(systemName: "chevron.left.forwardslash.chevron.right")
            .font(.system(size: 12)).frame(width: 28, height: 28)
        }.foregroundStyle(browser.showsDeveloper ? accent : .white.opacity(0.45))
          .help(Text("market.developer")).accessibilityLabel(Text("market.developer"))
          .accessibilityIdentifier("market-developer")
        Spacer()
        Button { browser.page = browser.currentPage(for: results) - 1 } label: {
          Image(systemName: "chevron.left").frame(width: 24, height: 28)
        }.disabled(browser.currentPage(for: results) == 0)
          .accessibilityLabel(Text("market.previous")).accessibilityIdentifier("market-previous")
        Text("\(browser.currentPage(for: results) + 1) / \(browser.pageCount(for: results))")
          .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        Button { browser.page = browser.currentPage(for: results) + 1 } label: {
          Image(systemName: "chevron.right").frame(width: 24, height: 28)
        }.disabled(browser.currentPage(for: results) + 1 >= browser.pageCount(for: results))
          .accessibilityLabel(Text("market.next")).accessibilityIdentifier("market-next")
      }.buttonStyle(.plain).padding(.horizontal, 10).padding(.bottom, 8)
    }
  }

  private func catalogRow(_ entry: PulseExtension) -> some View {
    let isSelected = selected?.id == entry.id && !browser.showsDeveloper
    let active = entry.isEnabled(in: model.extensionPreferences) && (entry.category != .voice || voiceInstalled)
    return Button { searchFocused = false; browser.show(entry) } label: {
      HStack(spacing: 10) {
        icon(entry, size: 32)
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 4) {
            Text(LocalizedStringKey(entry.titleKey)).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            if active {
              Image(systemName: "checkmark").font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.45)).accessibilityLabel(Text("market.active"))
            }
          }
          Text(LocalizedStringKey(entry.summaryKey)).font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.45)).lineLimit(1)
        }
      }.padding(.horizontal, 10).frame(height: 52)
        .background(isSelected ? accent.opacity(0.13) : (hoveredID == entry.id ? .white.opacity(0.045) : .clear),
          in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
          if isSelected { Capsule().fill(accent).frame(width: 2, height: 22) }
        }.contentShape(Rectangle())
    }.buttonStyle(.plain)
      .onHover { hoveredID = $0 ? entry.id : nil }
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .accessibilityIdentifier("market-open-\(entry.slug)")
  }

  private var emptyContent: some View {
    VStack(spacing: 12) {
      Image(systemName: "magnifyingglass").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
      Text("market.empty").font(.system(size: 15, weight: .medium))
      Text("market.empty.detail").font(.system(size: 11)).foregroundStyle(.secondary)
      Button("market.reset") { browser.resetFilters() }.buttonStyle(.bordered)
        .accessibilityIdentifier("market-reset")
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
          if active && !mutable { Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)) }
          Text(LocalizedStringKey(active && mutable ? "market.disable" : (active ? "market.active" : "market.enable")))
        }.padding(.horizontal, 9).frame(height: 28)
          .background(active ? .white.opacity(0.06) : accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
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
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 14) {
        icon(entry, size: 52)
        VStack(alignment: .leading, spacing: 7) {
          Text(LocalizedStringKey(entry.titleKey)).font(.system(size: 21, weight: .semibold)).lineLimit(1)
          HStack(spacing: 7) {
            Text(entry.publisher).foregroundStyle(accent)
            Text("·").foregroundStyle(.secondary)
            Text("market.bundled").foregroundStyle(.secondary)
          }.font(.system(size: 11))
        }
        Spacer(minLength: 0)
      }
      Text(LocalizedStringKey(entry.summaryKey)).font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.6)).lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
      HStack(spacing: 12) {
        action(entry).font(.system(size: 11, weight: .medium))
        if entry.isEnabled(in: model.extensionPreferences) && (entry.category != .voice || voiceInstalled) {
          Label("market.active", systemImage: "checkmark.circle")
            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
        }
      }.padding(.top, 14)
      HStack {
        Text("market.overview").font(.system(size: 11, weight: .medium)).padding(.vertical, 12)
          .overlay(alignment: .bottom) { Rectangle().fill(accent).frame(height: 2) }
        Spacer()
        Text(LocalizedStringKey(entry.category.titleKey)).font(.system(size: 10)).foregroundStyle(.secondary)
      }.padding(.top, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
      Text(LocalizedStringKey(entry.detailKey)).font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.65)).lineSpacing(5)
        .fixedSize(horizontal: false, vertical: true).padding(.top, 15)
      Spacer(minLength: 12)
      HStack(alignment: .top, spacing: 24) {
        metadata("market.identifier", value: entry.id)
        metadata("market.updates", value: L10n.text("market.updates.detail"))
      }
      Link(destination: projectURL) {
        Label("market.source", systemImage: "arrow.up.right").font(.system(size: 11))
      }.foregroundStyle(accent).padding(.top, 14)
    }.accessibilityIdentifier("market-detail-\(entry.slug)")
  }

  private func metadata(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(LocalizedStringKey(title)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
      Text(value).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).textSelection(.enabled)
    }
  }

  private var developerContent: some View {
    VStack(alignment: .leading, spacing: 18) {
      Image(systemName: "chevron.left.forwardslash.chevron.right")
        .font(.system(size: 26, weight: .light)).foregroundStyle(accent)
      Text("market.developer.title").font(.system(size: 21, weight: .semibold))
      Text("market.developer.subtitle").font(.system(size: 12)).foregroundStyle(.secondary)
      Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
      Text("market.developer.status").font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
        .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
      Link(destination: projectURL.appendingPathComponent("blob/main/docs/EXTENSION-DEVELOPMENT.md")) {
        Label("market.developer.guide", systemImage: "arrow.up.right")
      }.font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
      Spacer()
      Text("market.developer.pending").font(.system(size: 10)).foregroundStyle(.secondary)
    }.accessibilityIdentifier("market-developer-page")
  }
}
