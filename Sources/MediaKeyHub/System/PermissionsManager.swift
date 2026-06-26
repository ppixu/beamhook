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
}
