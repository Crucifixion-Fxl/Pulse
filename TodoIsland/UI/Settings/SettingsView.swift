import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject private var launchAtLogin = LaunchAtLoginService.shared
  let openIsland: () -> Void

  var body: some View {
    Form {
      Section("settings.reminders") {
        LabeledContent("settings.permission") {
          Text(permissionLabel)
            .foregroundStyle(permissionColor)
        }

        if model.authorization != .fullAccess {
          Button(
            model.authorization == .notDetermined
              ? "permission.open-island" : "permission.open-settings"
          ) {
            if model.authorization == .notDetermined {
              openIsland()
            } else {
              SystemSettings.openRemindersPrivacy()
            }
          }
        }
      }

      Section("settings.island") {
        LabeledContent("settings.collapsed-island") {
          if model.needsCollapsedIslandVisibilityChoice {
            Button("settings.complete-in-island") { openIsland() }
          } else {
            Picker(
              "settings.collapsed-island",
              selection: Binding(
                get: { model.collapsedIslandVisibility ?? .alwaysVisible },
                set: { model.setCollapsedIslandVisibility($0) }
              )
            ) {
              Text("setup.visibility.always-visible")
                .tag(CollapsedIslandVisibility.alwaysVisible)
              Text("setup.visibility.auto-hide")
                .tag(CollapsedIslandVisibility.autoHide)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 230)
          }
        }

        LabeledContent("settings.fullscreen") {
          Text("settings.fullscreen.policy")
            .foregroundStyle(.secondary)
        }

        Toggle(
          L10n.text("settings.launch-at-login"),
          isOn: Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
          )
        )
      }

      Section("settings.about") {
        LabeledContent("app.name", value: appVersion)
        Text("settings.privacy")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("menu.quit", role: .destructive) { NSApp.terminate(nil) }
      }
    }
    .formStyle(.grouped)
    .padding(16)
    .frame(width: 520, height: 380)
    .task {
      launchAtLogin.refresh()
    }
    .alert(
      L10n.text("error.title"),
      isPresented: Binding(
        get: { launchAtLogin.lastError != nil },
        set: { if !$0 { launchAtLogin.lastError = nil } }
      )
    ) {
      Button(L10n.text("common.ok")) { launchAtLogin.lastError = nil }
    } message: {
      Text(launchAtLogin.lastError ?? "")
    }
  }

  private var permissionLabel: LocalizedStringKey {
    switch model.authorization {
    case .fullAccess: "permission.full-access"
    case .notDetermined: "permission.not-determined"
    case .denied: "permission.denied"
    case .restricted: "permission.restricted"
    }
  }

  private var permissionColor: Color {
    model.authorization == .fullAccess ? .green : .orange
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
  }
}
