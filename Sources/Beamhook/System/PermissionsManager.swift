import AppKit
import ApplicationServices

final class PermissionsManager {
    var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Checks and, if needed, shows the system "grant Accessibility" prompt.
    @discardableResult
    func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The Automation list, where Apple-event permission per controlled app lives.
    /// This is a different grant from Accessibility: denying it costs the volume
    /// sliders and play state, while the media keys themselves keep working.
    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
