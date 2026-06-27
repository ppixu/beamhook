import SwiftUI
import MediaKeyKit

struct PreferencesView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddApp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preferences").font(.title2).bold()

            Toggle("Launch at login", isOn: Binding(
                get: { state.loginItemEnabled },
                set: { state.setLoginItem($0) }))

            HStack {
                Text("Accessibility:")
                Text(state.hasAccessibility ? "Granted" : "Not granted")
                    .foregroundStyle(state.hasAccessibility ? .green : .red)
                if !state.hasAccessibility {
                    Button("Open Settings") { state.permissions.openAccessibilitySettings() }
                }
            }

            Divider()
            HStack {
                Text("Custom apps").font(.headline)
                Spacer()
                Button("Add app…") { showingAddApp = true }
            }

            let custom = state.availableApps.filter { !$0.isBuiltIn }
            if custom.isEmpty {
                Text("No custom apps yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(custom) { app in
                    HStack {
                        Text(app.displayName)
                        Spacer()
                        Button(role: .destructive) {
                            removeCustom(app)
                        } label: { Image(systemName: "trash") }
                    }
                }
            }

            Divider()
            HStack { Spacer(); Button("Done") { dismiss() } }
        }
        .padding(16)
        .frame(width: 360)
        .sheet(isPresented: $showingAddApp) {
            AddAppSheet().environmentObject(state)
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
