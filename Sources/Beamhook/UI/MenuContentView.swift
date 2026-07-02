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

            Text("Hook play to").font(.caption).foregroundStyle(.secondary)
            Picker("Target", selection: Binding(
                get: { state.selectedTargetID ?? state.availableApps.first?.id ?? "" },
                set: { state.setTarget($0) })) {
                ForEach(state.availableApps) { app in
                    Text(app.displayName).tag(app.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            playPauseButton

            if state.volumeKeysActive {
                Label("Volume keys set \(targetName)'s volume", systemImage: "speaker.wave.2.fill")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // Playing-apps section renders its own leading divider + rows, and
            // nothing at all when nothing is playing.
            PlayingAppsList()

            Divider()
            SettingsSection()

            Divider()
            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 260)
        .onAppear { playing = state.isTargetPlaying() }
        .task {
            while !Task.isCancelled {
                playing = state.isTargetPlaying()
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
            HStack {
                Image(systemName: playing == true ? "pause.fill" : "play.fill")
                Text(playing == true ? "Pause" : "Play")
                Text(targetName).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
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
    // Volume-scriptable apps (Spotify, Music, …) that have played this session,
    // so we can keep offering their volume slider after they stop — as long as
    // they're still running. Non-scriptable ("system volume") apps aren't kept.
    @State private var everPlayedScriptable: [String: String] = [:]   // bundleID -> name

    /// Currently-playing apps, plus scriptable apps that played and are still
    /// running (deduplicated, current ones first).
    private var rows: [PlayingApp] {
        var seen = Set<String>()
        var out: [PlayingApp] = []
        for app in monitor.playingApps where seen.insert(app.bundleID).inserted {
            out.append(app)
        }
        for (bid, name) in everPlayedScriptable.sorted(by: { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }) {
            guard !seen.contains(bid), state.isRunning(bundleID: bid) else { continue }
            out.append(PlayingApp(id: bid, displayName: name, bundleID: bid))
            seen.insert(bid)
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
        .onReceive(monitor.$playingApps) { apps in
            for app in apps where state.volumeScriptable(bundleID: app.bundleID) {
                everPlayedScriptable[app.bundleID] = app.displayName
            }
        }
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

    /// Volume keys are taken over automatically (regardless of the checkbox) when
    /// this app is the hooked target and the current output has no adjustable volume.
    private var autoVolumeKeys: Bool {
        isTarget && scriptable && !state.outputVolumeControllable
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
                Toggle("Volume keys", isOn: Binding(
                    get: { autoVolumeKeys || state.isVolumeHooked(bundleID: playing.bundleID) },
                    set: { state.setVolumeHooked($0, bundleID: playing.bundleID) }))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.caption)
                    .disabled(autoVolumeKeys)
                    .help(autoVolumeKeys
                          ? "On automatically — this output device has no volume control"
                          : "Send the hardware volume keys to this app when it's the hooked target")
            } else {
                Text("system volume only").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if let v = state.volume(for: playing.bundleID) {
                volume = Double(v); scriptable = true
            } else {
                scriptable = false
            }
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
