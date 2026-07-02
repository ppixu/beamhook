import SwiftUI
import BeamhookKit

/// Login toggle, custom-app management, and the "Add an app…" entry point.
/// Adding an app opens a dedicated window (AddAppWindow), not a sheet — a sheet
/// would dismiss the menu-bar popover.
struct SettingsSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch at login", isOn: Binding(
                get: { state.loginItemEnabled },
                set: { state.setLoginItem($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)

            customAppsList

            Button {
                AddAppWindow.shared.show(state: state)
            } label: {
                Label("Add an app…", systemImage: "plus")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var customAppsList: some View {
        let custom = state.availableApps.filter { !$0.isBuiltIn }
        if !custom.isEmpty {
            ForEach(custom) { app in
                HStack {
                    Text(app.displayName).font(.subheadline)
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
    }

    private func removeCustom(_ app: AppDefinition) {
        var defs = state.store.loadUserDefined()
        defs.removeAll { $0.id == app.id }
        state.store.saveUserDefined(defs)
        state.reloadApps()
        if state.selectedTargetID == app.id {
            state.setTarget(state.availableApps.first?.id ?? "")
        }
    }
}
