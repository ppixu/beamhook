import SwiftUI
import BeamhookKit

/// Settings inlined directly into the menubar popover. Deliberately NOT a sheet or
/// separate window: presenting either from a MenuBarExtra(.window) popover makes the
/// popover lose key focus and dismiss, so toggles appeared to do nothing until reopen.
struct SettingsSection: View {
    @EnvironmentObject var state: AppState

    @State private var addingApp = false
    @State private var displayName = ""
    @State private var bundleID = ""
    @State private var playPause = ""
    @State private var next = ""
    @State private var previous = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings").font(.headline)

            Toggle("Launch at login", isOn: Binding(
                get: { state.loginItemEnabled },
                set: { state.setLoginItem($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)

            customAppsList

            DisclosureGroup("Add a custom app…", isExpanded: $addingApp) {
                addAppForm
            }
            .font(.subheadline)
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

    private var addAppForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter the app's bundle ID and AppleScript commands.")
                .font(.caption2).foregroundStyle(.secondary)
            field("Display name", $displayName, "My Player")
            field("Bundle ID", $bundleID, "com.example.player")
            field("Play/Pause", $playPause, "tell application \"My Player\" to playpause")
            field("Next (optional)", $next, "tell application \"My Player\" to next track")
            field("Previous (optional)", $previous, "tell application \"My Player\" to previous track")
            HStack {
                Spacer()
                Button("Cancel") { resetForm() }
                Button("Add") { addApp() }
                    .disabled(displayName.isEmpty || bundleID.isEmpty || playPause.isEmpty)
            }
        }
        .padding(.top, 4)
    }

    private func field(_ label: String, _ text: Binding<String>, _ placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
        }
    }

    private func addApp() {
        let def = AppDefinition(
            id: UUID().uuidString,
            displayName: displayName,
            bundleID: bundleID,
            isBuiltIn: false,
            playPauseScript: playPause,
            nextScript: next.isEmpty ? nil : next,
            previousScript: previous.isEmpty ? nil : previous,
            volumeScaleKind: .none,
            volumeGetScript: nil,
            volumeSetScript: nil)
        var defs = state.store.loadUserDefined()
        defs.append(def)
        state.store.saveUserDefined(defs)
        state.reloadApps()
        resetForm()
    }

    private func resetForm() {
        displayName = ""; bundleID = ""; playPause = ""; next = ""; previous = ""
        addingApp = false
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
