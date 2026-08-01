import SwiftUI
import BeamhookKit

private enum SettingsMetrics {
    /// Inset applied to both tabs, so a row's text and its trailing control sit
    /// the same distance from their respective window edges.
    static let contentInset: CGFloat = 20
}

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
            settingRow(
                title: "Launch at login",
                isOn: Binding(get: { state.loginItemEnabled },
                              set: { state.setLoginItem($0) }))

            settingRow(
                title: "Launch the hooked app on play/pause",
                caption: "Starts the app if it isn't running.",
                isOn: Binding(get: { state.launchTargetOnPlay },
                              set: { state.setLaunchTargetOnPlay($0) }))

            settingRow(
                title: "Show an overlay on play/pause",
                caption: "Flashes the app the keys reached, like the volume overlay.",
                isOn: Binding(get: { state.showPlayPauseHUD },
                              set: { state.setShowPlayPauseHUD($0) }))

            Spacer()
        }
        .padding(.top, 12)
        .padding(.horizontal, SettingsMetrics.contentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Label (plus optional caption) on the left, switch pinned to the trailing
    /// edge — so every row's switch lands on the same vertical line regardless of
    /// how long its label is. A plain `Toggle` sizes to its content instead, which
    /// left each switch wherever its own text happened to end.
    private func settingRow(title: String,
                            caption: String? = nil,
                            isOn: Binding<Bool>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

private struct AppsSettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    AddAppWindow.shared.show(state: state)
                } label: {
                    Label("Add an app…", systemImage: "plus")
                }
                Text("(experimental)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .padding(.horizontal, SettingsMetrics.contentInset)
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
