import AppKit
import SwiftUI
import BeamhookKit

/// Opens the "Add an App" form in a real window (not a sheet — a sheet would
/// dismiss the menu-bar popover). Beamhook is an agent app (LSUIElement), so we
/// briefly switch the activation policy to `.regular` while the window is open so
/// it can become key and accept keyboard input, then back to `.accessory`.
@MainActor
final class AddAppWindow {
    static let shared = AddAppWindow()
    private var window: NSWindow?

    func show(state: AppState, prefillName: String = "", prefillBundleID: String = "") {
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
    @State private var copied = false

    init(prefillName: String = "", prefillBundleID: String = "") {
        _displayName = State(initialValue: prefillName)
        _bundleID = State(initialValue: prefillBundleID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                form
            }
            .padding(22)
        }
        .frame(width: 540, height: 660)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add an app").font(.title2).bold()
            Text("Beamhook controls **native macOS apps** through their AppleScript dictionary. To add one, it needs the app's bundle identifier and a few AppleScript commands.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Label("Find the **bundle ID** in Terminal:", systemImage: "1.circle.fill")
                Text("osascript -e 'id of app \"App Name\"'")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Label("Find the **commands** in Script Editor → File → Open Dictionary → pick the app (or `sdef /Applications/App.app`).", systemImage: "2.circle.fill")
                Label("Electron / web apps (Amazon Music, TIDAL, Deezer, Plexamp) usually have **no** AppleScript and can't be added.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            HStack(spacing: 10) {
                Button {
                    copyAIPrompt()
                } label: {
                    Label(copied ? "Copied!" : "Copy instructions for AI", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                }
                Text("Paste into Claude / ChatGPT to get the exact settings, then fill them in below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Display name", $displayName, "My Player")
            field("Bundle ID", $bundleID, "com.example.player")
            field("Play / Pause  (required)", $playPause, "tell application \"My Player\" to playpause")
            field("Next  (optional)", $next, "tell application \"My Player\" to next track")
            field("Previous  (optional)", $previous, "tell application \"My Player\" to previous track")
            field("Play state  (optional)", $playState, "tell application \"My Player\" to return (player state as text)")

            HStack {
                Spacer()
                Button("Cancel") { AddAppWindow.shared.hide() }
                    .keyboardShortcut(.cancelAction)
                Button("Add & hook") { addApp() }
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
        AppleScript dictionary (verify with: sdef /Applications/<App>.app), give me:

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
