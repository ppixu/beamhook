import SwiftUI
import MediaKeyKit

struct AddAppSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var bundleID = ""
    @State private var playPause = ""
    @State private var next = ""
    @State private var previous = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a custom app").font(.title3).bold()
            Text("Enter the app's bundle ID and AppleScript commands. Use the app's scripting dictionary for the exact verbs.")
                .font(.caption).foregroundStyle(.secondary)

            field("Display name", $displayName, placeholder: "My Player")
            field("Bundle ID", $bundleID, placeholder: "com.example.player")
            field("Play/Pause script", $playPause, placeholder: "tell application \"My Player\" to playpause")
            field("Next script (optional)", $next, placeholder: "tell application \"My Player\" to next track")
            field("Previous script (optional)", $previous, placeholder: "tell application \"My Player\" to previous track")

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { add() }
                    .disabled(displayName.isEmpty || bundleID.isEmpty || playPause.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func field(_ label: String, _ text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func add() {
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
        dismiss()
    }
}
