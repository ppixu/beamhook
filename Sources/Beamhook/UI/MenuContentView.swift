import SwiftUI
import Combine
import BeamhookKit

private struct MenuRefreshContext: Hashable {
    let targetID: String?
    let isVisible: Bool
}

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
            Menu {
                ForEach(state.availableApps) { app in
                    Button {
                        playing = nil
                        state.setTarget(app.id)
                    } label: {
                        Group {
                            if app.id == state.selectedTargetID {
                                Label(app.displayName, systemImage: "checkmark")
                            } else {
                                Text(app.displayName)
                            }
                        }
                        .foregroundStyle(state.isRunning(bundleID: app.bundleID) ? .primary : .secondary)
                    }
                }
            } label: {
                Text(targetName)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Hook media keys to \(targetName)")

            playPauseButton

            if state.selectedTargetIsBrowser {
                if state.browserMediaInjectionAvailable == true {
                    if state.browserMediaCandidates.isEmpty {
                        Text("No playable browser tabs found.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Picker("Browser player", selection: Binding(
                            get: { state.selectedBrowserMediaID ?? state.browserMediaCandidates.first?.id ?? "" },
                            set: { state.selectBrowserMedia($0) })) {
                            ForEach(state.browserMediaCandidates) { candidate in
                                Text((candidate.isPlaying ? "▶ " : "") + candidate.label)
                                    .tag(candidate.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                    }
                } else if state.browserTargetRunning == false {
                    Text("\(targetName) is not running. macOS will handle play/pause normally.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if state.browserMediaInjectionAvailable == false {
                    Text("macOS is choosing the browser player. Enable JavaScript from Apple Events to pick a specific tab in Beamhook.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Playing-apps section renders its own leading divider + rows, and
            // nothing at all when nothing is playing.
            PlayingAppsList()

            addAppButton

            Divider()
            SettingsSection()

            Divider()
            HStack(spacing: 6) {
                Image("MenuBarIcon")
                    .resizable()
                    .renderingMode(.template)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text("Beamhook")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 200)
        .task(id: state.isMenuVisible) {
            guard state.isMenuVisible else { return }
            while !Task.isCancelled {
                playing = await state.isTargetPlaying()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        .task(id: MenuRefreshContext(
            targetID: state.selectedTargetID,
            isVisible: state.isMenuVisible
        )) {
            guard state.isMenuVisible else { return }
            while !Task.isCancelled {
                await state.refreshBrowserMedia()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
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
    /// Non-scriptable apps ("system volume only") appear only while they're
    /// actually emitting audio. Supported browsers resolve to their YouTube
    /// definitions in AudioProcessMonitor, including Safari's WebKit helper.
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
        // The popover content stays mounted while hidden, so explicitly bind the
        // monitor to its visible lifetime instead of relying on view appearance.
        VStack(alignment: .leading, spacing: 8) {
            let list = rows
            if !list.isEmpty {
                Divider()
                ForEach(list) { app in
                    AppVolumeRow(playing: app)
                }
            }
        }
        .task(id: state.isMenuVisible) {
            if state.isMenuVisible {
                monitor.start()
            } else {
                monitor.stop()
            }
        }
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
                // The hooked app's title is fully opaque; the rest sit back a bit.
                Text(playing.displayName).font(.subheadline)
                    .opacity(isTarget ? 1 : 0.55)
                Spacer()
                Button(isTarget ? "Hooked" : "Hook") { hook() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isTarget)
                    .help(isTarget ? "The media keys already control this app"
                                   : "Send the media keys to this app")
            }
            if scriptable && isTarget {
                Slider(value: $volume, in: 0...100) { editing in
                    if !editing { state.setVolume(Int(volume), for: playing.bundleID) }
                }
                Toggle("Volume keys", isOn: Binding(
                    get: { state.volumeKeysEnabled(bundleID: playing.bundleID) },
                    set: { state.setVolumeKeysEnabled($0, bundleID: playing.bundleID) }))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.caption)
                    .help("Route the hardware volume keys to this app while it's the hooked target")
            } else if isTarget {
                Text("system volume only").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task(id: state.isMenuVisible) {
            guard state.isMenuVisible else { return }
            if let cached = state.volumeByBundle[playing.bundleID] {
                volume = Double(cached); scriptable = true
            } else {
                if let v = await state.volume(for: playing.bundleID) {
                    volume = Double(v); scriptable = true
                    state.volumeByBundle[playing.bundleID] = v
                } else {
                    scriptable = false
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
