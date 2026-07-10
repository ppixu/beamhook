import SwiftUI
import Combine
import BeamhookKit

struct MenuContentView: View {
    @EnvironmentObject var state: AppState
    @State private var playing: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.hasAccessibility {
                permissionBanner
                Divider()
            }

            Text("Hook media keys to:").font(.caption).foregroundStyle(.secondary)
            Picker("Target", selection: Binding(
                get: { state.selectedTargetID ?? state.availableApps.first?.id ?? "" },
                set: { state.setTarget($0) })) {
                ForEach(state.availableApps) { app in
                    Text(app.displayName).tag(app.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            // labelsHidden still reserves the label column on macOS, leaving a
            // leading gap; pull the control flush with the rest of the content.
            .padding(.leading, -8)

            playPauseButton

            // Playing-apps section renders its own leading divider + rows, and
            // nothing at all when nothing is playing.
            PlayingAppsList()

            addAppButton

            Divider()
            SettingsSection()

            Divider()
            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 200)
        .task {
            while !Task.isCancelled {
                playing = await state.isTargetPlaying()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private var targetName: String {
        let id = state.selectedTargetID
        return state.availableApps.first { $0.id == id }?.displayName ?? "target"
    }

    private var playPauseButton: some View {
        Button {
            let wasPlaying = (playing == true)
            state.togglePlayPauseTarget()
            playing = !wasPlaying   // optimistic; the 1.5s poll reconciles with reality
        } label: {
            Image(systemName: playing == true ? "pause.fill" : "play.fill")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
        .help(playing == true ? "Pause \(targetName)" : "Play \(targetName)")
    }

    private var addAppButton: some View {
        Button {
            AddAppWindow.shared.show(state: state)
        } label: {
            Label("Add an app…", systemImage: "plus")
        }
        .controlSize(.small)
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accessibility permission needed").font(.headline).foregroundStyle(.red)
            Text("Beamhook needs Accessibility access to capture the media keys.")
                .font(.caption)
            HStack {
                Button("Open Settings") { state.permissions.openAccessibilitySettings() }
                Button("Re-check") { state.refreshPermission() }
            }
        }
    }
}

private struct PlayingAppsList: View {
    var body: some View {
        if #available(macOS 14.2, *) {
            PlayingAppsListAvailable()
        }
    }
}

@available(macOS 14.2, *)
private struct PlayingAppsListAvailable: View {
    @EnvironmentObject var state: AppState
    @StateObject private var monitor = AudioProcessMonitor()

    /// What to show, deduplicated with currently-playing apps first:
    ///   1. apps with a live audio stream (from Core Audio), plus
    ///   2. known volume-scriptable apps (Spotify, Apple Music, VLC, …) that are
    ///      running — so their volume slider stays available while the app is open,
    ///      not only while it's actively making sound.
    /// Non-scriptable apps ("system volume only", e.g. Safari) appear only while
    /// they're actually emitting audio.
    private var rows: [PlayingApp] {
        var seen = Set<String>()
        var out: [PlayingApp] = []
        for app in monitor.playingApps where seen.insert(app.bundleID).inserted {
            // Prefer a known app's own name (e.g. "Apple Music") over the OS process
            // name ("Music") so the label is the same whether it's playing or just open.
            let name = state.availableApps.first { $0.bundleID == app.bundleID }?.displayName ?? app.displayName
            out.append(PlayingApp(id: app.bundleID, displayName: name, bundleID: app.bundleID))
        }
        let scriptableRunning = state.availableApps
            .filter { state.volumeScriptable(bundleID: $0.bundleID) && state.isRunning(bundleID: $0.bundleID) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        for def in scriptableRunning where seen.insert(def.bundleID).inserted {
            out.append(PlayingApp(id: def.bundleID, displayName: def.displayName, bundleID: def.bundleID))
        }
        return out
    }

    var body: some View {
        // Always present (so the monitor starts), but shows content only when
        // there is something to control.
        VStack(alignment: .leading, spacing: 8) {
            let list = rows
            if !list.isEmpty {
                Divider()
                ForEach(list) { app in
                    AppVolumeRow(playing: app)
                }
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

@available(macOS 14.2, *)
private struct AppVolumeRow: View {
    @EnvironmentObject var state: AppState
    let playing: PlayingApp
    @State private var volume: Double = 50
    @State private var scriptable = false

    private var isTarget: Bool {
        guard let id = state.selectedTargetID,
              let def = state.availableApps.first(where: { $0.id == id }) else { return false }
        return def.bundleID == playing.bundleID
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(playing.displayName).font(.subheadline)
                Spacer()
                Button(isTarget ? "Hooked" : "Hook") { hook() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isTarget)
                    .help(isTarget ? "The media keys already control this app"
                                   : "Send the media keys to this app")
            }
            if scriptable {
                Slider(value: $volume, in: 0...100) { editing in
                    if !editing { state.setVolume(Int(volume), for: playing.bundleID) }
                }
                // The volume-keys opt-in only matters for the hooked app, so
                // the other rows stay compact: name + slider.
                if isTarget {
                    Toggle("Volume keys", isOn: Binding(
                        get: { state.volumeKeysEnabled(bundleID: playing.bundleID) },
                        set: { state.setVolumeKeysEnabled($0, bundleID: playing.bundleID) }))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.caption)
                        .help("Route the hardware volume keys to this app while it's the hooked target")
                    // Non-silent nudge: if the current output has no adjustable volume
                    // the hardware keys do nothing, so suggest routing them here — but
                    // only if the user turns it on.
                    if !state.outputVolumeControllable
                        && !state.volumeKeysEnabled(bundleID: playing.bundleID) {
                        Text("This output has no volume control — turn this on to use the volume keys here.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if isTarget {
                Text("system volume only").font(.caption2).foregroundStyle(.secondary)
            }
        }
        // Dim rounded highlight behind the hooked row. The padding/negative-
        // padding pair keeps every row's layout width identical — the highlight
        // just bleeds evenly around the active one.
        .padding(6)
        .background {
            if isTarget {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            }
        }
        .padding(-6)
        .onAppear {
            if let cached = state.volumeByBundle[playing.bundleID] {
                volume = Double(cached); scriptable = true
            } else {
                Task {
                    if let v = await state.volume(for: playing.bundleID) {
                        volume = Double(v); scriptable = true
                        state.volumeByBundle[playing.bundleID] = v
                    } else {
                        scriptable = false
                    }
                }
            }
        }
        .onChange(of: state.volumeByBundle[playing.bundleID]) { _, newVal in
            if let v = newVal { volume = Double(v) }
        }
    }

    /// Hook the media keys to this app. If it's a known app, just select it;
    /// otherwise open the Add-an-app window prefilled with its details.
    private func hook() {
        if let def = state.availableApps.first(where: { $0.bundleID == playing.bundleID }) {
            state.setTarget(def.id)
        } else {
            AddAppWindow.shared.show(state: state,
                                     prefillName: playing.displayName,
                                     prefillBundleID: playing.bundleID)
        }
    }
}
