import SwiftUI
import MediaKeyKit

struct MenuContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showingPrefs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !state.hasAccessibility {
                permissionBanner
                Divider()
            }

            Text("Media-key target").font(.headline)
            Picker("Target", selection: Binding(
                get: { state.selectedTargetID ?? state.availableApps.first?.id ?? "" },
                set: { state.setTarget($0) })) {
                ForEach(state.availableApps) { app in
                    Text(app.displayName).tag(app.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            Divider()
            PlayingAppsList()

            Divider()
            HStack {
                Button("Preferences…") { showingPrefs = true }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 320)
        .sheet(isPresented: $showingPrefs) {
            PreferencesView().environmentObject(state)
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accessibility permission needed").font(.headline).foregroundStyle(.red)
            Text("MediaKeyHub needs Accessibility access to capture the media keys.")
                .font(.caption)
            HStack {
                Button("Open Settings") { state.permissions.openAccessibilitySettings() }
                Button("Re-check") { state.refreshPermission() }
            }
        }
    }
}

private struct PlayingAppsList: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Text("Recently playing").font(.headline)
        if #available(macOS 14.2, *) {
            PlayingAppsListAvailable()
        } else {
            Text("Requires macOS 14.2+").font(.caption).foregroundStyle(.secondary)
        }
    }
}

@available(macOS 14.2, *)
private struct PlayingAppsListAvailable: View {
    @EnvironmentObject var state: AppState
    @StateObject private var monitor = AudioProcessMonitor()

    var body: some View {
        Group {
            if monitor.playingApps.isEmpty {
                Text("Nothing playing").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(monitor.playingApps) { app in
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(playing.displayName).font(.subheadline)
            if scriptable {
                Slider(value: $volume, in: 0...100) { editing in
                    if !editing { state.setVolume(Int(volume), for: playing.bundleID) }
                }
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
}
