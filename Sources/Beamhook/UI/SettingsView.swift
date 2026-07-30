import SwiftUI
import BeamhookKit

/// Beamhook's settings. Presented in a real window by `SettingsWindow` — never a
/// sheet, which would dismiss the menu-bar popover it was opened from.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppsSettingsTab()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
        }
        .padding(20)
        // Min/ideal rather than a fixed size: the window's style mask now
        // includes `.resizable`, and a hard-fixed frame here would leave it
        // draggable but visually inert. The Apps tab's list is the one that
        // actually benefits — it only fits ~5 rows at the original 300pt.
        .frame(minWidth: 440, idealWidth: 440, minHeight: 300, idealHeight: 300)
    }
}

private struct GeneralSettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Launch at login", isOn: Binding(
                get: { state.loginItemEnabled },
                set: { state.setLoginItem($0) }))

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Launch the hooked app on play/pause", isOn: Binding(
                    get: { state.launchTargetOnPlay },
                    set: { state.setLaunchTargetOnPlay($0) }))
                Text("Starts the app if it isn't running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .toggleStyle(.switch)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AppsSettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                AddAppWindow.shared.show(state: state)
            } label: {
                Label("Add an app…", systemImage: "plus")
            }

            let custom = state.availableApps.filter { !$0.isBuiltIn }
            if custom.isEmpty {
                Text("No custom apps yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                List(custom) { app in
                    HStack {
                        Text(app.displayName)
                        Spacer()
                        Button(role: .destructive) {
                            removeCustom(app)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(app.displayName)")
                    }
                }
            }

            Spacer()
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func removeCustom(_ app: AppDefinition) {
        var defs = state.store.loadUserDefined()
        defs.removeAll { $0.id == app.id }
        state.store.saveUserDefined(defs)
        state.reloadApps()
        if state.selectedTargetID == app.id {
            state.setTarget(nil)
        }
    }
}
