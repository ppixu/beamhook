import AppKit
import SwiftUI
import BeamhookKit

extension Notification.Name {
    /// Posted to ask the menu-bar popover to close (e.g. when opening a window).
    static let closeBeamhookMenu = Notification.Name("beamhook.closeMenu")
}

/// Opens the "Add an App" form in a real window (not a sheet — a sheet would
/// dismiss the menu-bar popover). Beamhook is an agent app (LSUIElement), so we
/// briefly switch the activation policy to `.regular` while the window is open so
/// it can become key and accept keyboard input, then back to `.accessory`.
@MainActor
final class AddAppWindow {
    static let shared = AddAppWindow()
    private var window: NSWindow?

    func show(state: AppState, prefillName: String = "", prefillBundleID: String = "") {
        NotificationCenter.default.post(name: .closeBeamhookMenu, object: nil)

        let root = AddAppView(prefillName: prefillName, prefillBundleID: prefillBundleID)
            .environmentObject(state)
        let hosting = NSHostingController(rootView: root)

        let w: NSWindow
        if let existing = window {
            w = existing
            w.contentViewController = hosting
        } else {
            w = NSWindow(contentViewController: hosting)
            w.title = "Add an App"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main
            ) { _ in NSApp.setActivationPolicy(.accessory) }
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func hide() { window?.close() }
}

struct AddAppView: View {
    @EnvironmentObject var state: AppState

    @State private var displayName: String
    @State private var bundleID: String
    @State private var playPause = ""
    @State private var next = ""
    @State private var previous = ""
    @State private var playState = ""
    @State private var showMore = false
    @State private var showManual = false
    @State private var copied = false
    @State private var showScriptConfirmation = false

    init(prefillName: String = "", prefillBundleID: String = "") {
        _displayName = State(initialValue: prefillName)
        _bundleID = State(initialValue: prefillBundleID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Add an app").font(.title2).bold()
                Text("Beamhook controls a native macOS app via a few AppleScript commands. The easiest way to get them:")
                    .foregroundStyle(.secondary)
                Label("Firefox is not supported and cannot be added here.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                aiHelper
                form
            }
            .padding(24)
        }
        .frame(width: 460, height: 560)
        .alert("Trust this AppleScript?", isPresented: $showScriptConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Add & hook") { addApp() }
        } message: {
            Text("Beamhook will run these scripts with your macOS account's permissions. Only continue if you reviewed them and trust their source.")
        }
    }

    // The recommended path: let an AI figure out the settings.
    private var aiHelper: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                copyAIPrompt()
            } label: {
                Label(copied ? "Copied — paste into your AI" : "Copy instructions for AI",
                      systemImage: copied ? "checkmark" : "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Label {
                Text("Review generated scripts before pasting them. AppleScript can run shell commands and access data with your account's permissions.")
            } icon: {
                Image(systemName: "exclamationmark.shield")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            DisclosureGroup("Prefer to do it by hand?", isExpanded: $showManual) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bundle ID — in Terminal:")
                    Text("osascript -e 'id of app \"App Name\"'")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Text("Commands — Script Editor → File → Open Dictionary → pick the app.")
                    Text("Electron/web apps (Amazon Music, TIDAL, Deezer…) have no AppleScript and can't be added.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.top, 6)
            }
            .font(.callout)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Name", $displayName, "My Player")
            field("Bundle ID", $bundleID, "com.example.player")
            field("Play / Pause", $playPause, "tell application \"My Player\" to playpause")

            DisclosureGroup("More commands (optional)", isExpanded: $showMore) {
                VStack(alignment: .leading, spacing: 12) {
                    field("Next", $next, "tell application \"My Player\" to next track")
                    field("Previous", $previous, "tell application \"My Player\" to previous track")
                    field("Play state", $playState, "tell application \"My Player\" to return (player state as text)")
                }
                .padding(.top, 8)
            }
            .font(.callout)

            HStack {
                Spacer()
                Button("Cancel") { AddAppWindow.shared.hide() }
                    .keyboardShortcut(.cancelAction)
                Button("Add & hook") { showScriptConfirmation = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(displayName.isEmpty || bundleID.isEmpty || playPause.isEmpty)
            }
            .padding(.top, 4)
        }
    }

    private func field(_ label: String, _ text: Binding<String>, _ placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
        }
    }

    private func addApp() {
        let def = AppDefinition(
            id: UUID().uuidString,
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            bundleID: bundleID.trimmingCharacters(in: .whitespaces),
            isBuiltIn: false,
            playPauseScript: playPause,
            nextScript: next.isEmpty ? nil : next,
            previousScript: previous.isEmpty ? nil : previous,
            volumeScaleKind: .none,
            volumeGetScript: nil,
            volumeSetScript: nil,
            playStateScript: playState.isEmpty ? nil : playState)
        var defs = state.store.loadUserDefined()
        defs.append(def)
        state.store.saveUserDefined(defs)
        state.reloadApps()
        state.setTarget(def.id)   // "Add & hook" — make it the media-key target
        AddAppWindow.shared.hide()
    }

    private func copyAIPrompt() {
        let name = displayName.isEmpty ? "<the app's name>" : displayName
        let bundle = bundleID.isEmpty ? "" : " (bundle id \(bundleID))"
        let prompt = """
        I want to control an app with Beamhook, a macOS menu-bar app that maps the \
        keyboard's media keys to one app via AppleScript. Help me fill in its \
        "Add an app" form for: \(name)\(bundle).

        Beamhook drives NATIVE macOS apps through their AppleScript dictionary only \
        (no web/Electron apps). Using ONLY commands that exist in this app's real \
        AppleScript dictionary (verify with: sdef /Applications/<App>.app), and NEVER \
        using `do shell script`, `run script`, command-line tools, or network requests, \
        give me:

        1. Bundle identifier (e.g. com.example.app).
        2. Play/Pause — a one-line AppleScript that TOGGLES playback, e.g.
           tell application "<App>" to playpause
           (If there's no playpause verb, use an if/else on the play state.)
        3. Next (optional), e.g. tell application "<App>" to next track
        4. Previous (optional), e.g. tell application "<App>" to previous track
        5. Play state (optional) — a one-liner returning the state as TEXT, e.g.
           tell application "<App>" to return (player state as text)
           (Coerce enum results with "as text", or NSAppleScript returns nil.)

        If the app has no AppleScript dictionary (many Electron/web apps like \
        Amazon Music, TIDAL, Deezer, Plexamp don't), tell me it can't be controlled \
        this way. Return each value on its own line, ready to paste.
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); copied = false }
    }
}
