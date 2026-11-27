import AppKit
import Carbon
import OSAKit
import BeamhookKit

struct ChromiumTarget: Equatable, Sendable {
    let browser: BrowserKind
    let processID: pid_t

    static func desktop(_ browser: BrowserKind) -> Self? {
        guard let app = browser.desktopApplication else { return nil }
        return Self(browser: browser, processID: app.processIdentifier)
    }

    /// A named AppleScript target can resolve to a headless copy of the same
    /// app. Keep the browser's scripting dictionary and pin its events to
    /// the desktop process. The caller holds AppleScriptExecutor's script lock.
    func execute(_ source: String) -> ScriptResult {
        guard let language = OSALanguage(forName: "AppleScript") else { return .scriptFailed }
        let instance = OSALanguageInstance(language: language)
        var originalSend: OSASendUPP?
        var originalContext: UnsafeMutableRawPointer?
        let component = instance.componentInstance
        guard OSAGetSendProc(component, &originalSend, &originalContext) == noErr,
              let originalSend else { return .scriptFailed }
        var routing = BrowserEventRouting(target: self, send: originalSend, context: originalContext)
        return withUnsafeMutablePointer(to: &routing) { pointer in
            guard OSASetSendProc(component, BrowserEventRouting.sendEvent, pointer) == noErr else {
                return .scriptFailed
            }
            defer { OSASetSendProc(instance.componentInstance, originalSend, originalContext) }
            let script = OSAScript(source: source, from: nil, languageInstance: instance, using: [])
            var error: NSDictionary?
            guard let result = script.executeAndReturnError(&error) else {
                if let error { NSLog("AppleScript error: \(error)") }
                return .scriptFailed
            }
            return ScriptResult(output: result.stringValue, succeeded: true)
        }
    }
}

private struct BrowserEventRouting {
    let target: ChromiumTarget
    let send: OSASendUPP
    let context: UnsafeMutableRawPointer?

    // Scripting additions and events to the interpreter must still reach their
    // original recipient. Only replace an address belonging to the same browser.
    static let sendEvent: OSASendUPP = { event, reply, mode, priority, timeout, idle, filter, context in
        guard let context else { return OSErr(paramErr) }
        let routing = context.assumingMemoryBound(to: Self.self).pointee
        var pid: pid_t = 0
        var type: DescType = 0
        var size = 0
        let status = AEGetAttributePtr(event, AEKeyword(keyAddressAttr), DescType(typeKernelProcessID),
                                       &type, &pid, MemoryLayout.size(ofValue: pid), &size)
        guard status == noErr, pid != routing.target.processID,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == routing.target.browser.bundleID
        else { return routing.send(event, reply, mode, priority, timeout, idle, filter, routing.context) }

        var redirected = AppleEvent()
        let copied = AEDuplicateDesc(event, &redirected)
        guard copied == noErr else { return copied }
        defer { AEDisposeDesc(&redirected) }
        let address = NSAppleEventDescriptor(processIdentifier: routing.target.processID)
        let addressed = AEPutAttributeDesc(&redirected, AEKeyword(keyAddressAttr), address.aeDesc)
        guard addressed == noErr else { return addressed }
        return routing.send(&redirected, reply, mode, priority, timeout, idle, filter, routing.context)
    }
}
