import Cocoa
import CoreGraphics
import BeamhookKit

/// NSSystemDefined event type (NX_SYSDEFINED from <IOKit/hidsystem/IOLLEvent.h>).
private let kSystemDefinedEventType: UInt32 = 14

/// Owns a CGEventTap on a dedicated background thread + run loop.
/// Threading contract: the public methods (start/stop/ensureEnabled/recreate, isEnabled)
/// are expected to be called from the main thread (AppState/TapWatchdog do so). All
/// mutation of the tap state (eventTap/runLoopSource) is marshalled onto the tap thread
/// via performOnTapThread; the callback runs on the tap thread. Cross-thread routing
/// flags and the run-loop handoff are protected by `stateLock`.
final class MediaKeyTap: @unchecked Sendable {
    typealias Handler = (MediaKey) -> Void

    private struct RoutingState {
        var transportKeysHijacked = true
        var volumeKeysHijacked = false
        var commandVolumeRouting = true
        var targetCanTakeVolume = false
    }

    private let handler: Handler
    /// Told about transport key-downs the tap deliberately let macOS keep
    /// (browser target without tab control). Purely informational — the event
    /// has already been passed through by the time this runs — so the app can
    /// explain where the key actually went instead of appearing to drop it.
    private let passthroughHandler: Handler?
    private let stateLock = NSLock()
    private var routingState = RoutingState()

    /// Browser targets leave transport keys to macOS until tab injection is
    /// available; all other targets keep Beamhook's exclusive routing.
    var transportKeysHijacked: Bool {
        get { withStateLock { routingState.transportKeysHijacked } }
        set { withStateLock { routingState.transportKeysHijacked = newValue } }
    }

    /// When true, hardware volume up/down keys are swallowed and forwarded to the
    /// target app instead of the system.
    var volumeKeysHijacked: Bool {
        get { withStateLock { routingState.volumeKeysHijacked } }
        set { withStateLock { routingState.volumeKeysHijacked = newValue } }
    }

    /// The global "⌘ + volume keys control the hooked app" setting. Only governs
    /// the Command chord; the plain keys are unaffected either way.
    var commandVolumeRouting: Bool {
        get { withStateLock { routingState.commandVolumeRouting } }
        set { withStateLock { routingState.commandVolumeRouting = newValue } }
    }

    /// The target exposes a volume Beamhook can drive AND is running. Kept here
    /// rather than resolved in the callback because asking NSWorkspace on the tap
    /// thread would put an unbounded call in front of every key press.
    var targetCanTakeVolume: Bool {
        get { withStateLock { routingState.targetCanTakeVolume } }
        set { withStateLock { routingState.targetCanTakeVolume = newValue } }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?

    /// Both handlers are always invoked on the main thread, for fresh (non-repeat)
    /// key-downs only: `handler` for transport keys the tap swallowed and routed,
    /// `passthroughHandler` for transport keys it handed back to macOS.
    init(handler: @escaping Handler, passthroughHandler: Handler? = nil) {
        self.handler = handler
        self.passthroughHandler = passthroughHandler
    }

    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "com.beamhook.tap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    private func threadMain() {
        let runLoop = CFRunLoopGetCurrent()
        withStateLock { threadRunLoop = runLoop }
        createTap()
        CFRunLoopRun()
        withStateLock { threadRunLoop = nil }
    }

    private func createTap() {
        let mask = CGEventMask(1) << CGEventMask(kSystemDefinedEventType)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let mySelf = Unmanaged<MediaKeyTap>.fromOpaque(userInfo!).takeUnretainedValue()
            return mySelf.handle(type: type, event: event)
        }
        // `self` is passed unretained to the C callback; it MUST outlive the installed tap.
        // Guaranteed because AppState holds this MediaKeyTap for the whole app lifetime.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: userInfo) else {
            NSLog("MediaKeyTap: failed to create tap — Accessibility not granted?")
            return
        }
        withStateLock { eventTap = tap }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Internal rather than private so the unit tests can drive it with
    /// synthetic events; only the tap callback calls it in production.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // System disabled the tap — re-enable and keep the event.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = withStateLock({ eventTap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == kSystemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Int16(MediaKeyDecoder.systemDefinedMediaKeysSubtype),
              let decoded = MediaKeyDecoder.decode(subtype: Int(nsEvent.subtype.rawValue),
                                                   data1: nsEvent.data1)
        else {
            return Unmanaged.passUnretained(event)  // mouse events, other system events
        }

        let key = decoded.key

        if key.isHandledTransport {
            if !transportKeysHijacked {
                // macOS keeps the key. Say so (fresh key-downs only, matching
                // the routed branch below) — otherwise a hooked-but-degraded
                // browser target looks identical to a working hook while the
                // key controls whatever app macOS's now-playing picks.
                if decoded.isDown && !decoded.isRepeat {
                    DispatchQueue.main.async { [weak self] in self?.passthroughHandler?(key) }
                }
                return Unmanaged.passUnretained(event)
            }
            // Act on key-down only; swallow both down and up to stop other apps /
            // Music auto-launch.
            if decoded.isDown && !decoded.isRepeat {
                DispatchQueue.main.async { [weak self] in self?.handler(key) }
            }
            return nil
        }

        if key.isVolume {
            let commandHeld = event.flags.contains(.maskCommand)
            let routing = withStateLock { routingState }
            switch VolumeKeyRouting.destination(commandHeld: commandHeld,
                                                hijacked: routing.volumeKeysHijacked,
                                                commandRoutingEnabled: routing.commandVolumeRouting,
                                                targetCanTakeVolume: routing.targetCanTakeVolume) {
            case .app:
                // Forward on key-down AND repeats so holding the key ramps the volume.
                if decoded.isDown {
                    DispatchQueue.main.async { [weak self] in self?.handler(key) }
                }
                return nil
            case .system:
                // macOS gives Command + volume no meaning of its own, so a press
                // that reaches the system must arrive as an ordinary volume key
                // rather than a modified shortcut.
                if commandHeld {
                    event.flags = event.flags.subtracting(.maskCommand)
                }
                return Unmanaged.passUnretained(event)
            }
        }

        // Everything else (mute, ff/rewind) passes through.
        return Unmanaged.passUnretained(event)
    }

    /// Send a normal system play/pause key pair. Used by the menu button when a
    /// browser target is in native pass-through mode.
    static func postNativePlayPause() {
        let playKeyCode = 16 // NX_KEYTYPE_PLAY
        for isDown in [true, false] {
            let keyFlags = isDown ? 0xA00 : 0xB00
            let data1 = (playKeyCode << 16) | keyFlags
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil,
                subtype: 8,
                data1: data1, data2: -1)
            event?.cgEvent?.post(tap: CGEventTapLocation.cghidEventTap)
        }
    }

    var isEnabled: Bool {
        guard let tap = withStateLock({ eventTap }) else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Re-enable if disabled, or recreate if the tap object is gone. Safe to call from any thread.
    func ensureEnabled() {
        performOnTapThread { [weak self] in
            guard let self else { return }
            if let tap = self.withStateLock({ self.eventTap }) {
                if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                self.createTap()
            }
        }
    }

    /// Full teardown + recreate, for the silently-inert failure mode and after wake.
    func recreate() {
        performOnTapThread { [weak self] in
            guard let self else { return }
            if let source = self.runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            self.runLoopSource = nil
            self.withStateLock { self.eventTap = nil }
            self.createTap()
        }
    }

    func stop() {
        performOnTapThread { [weak self] in
            guard let self else { return }
            if let tap = self.withStateLock({ self.eventTap }) {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            if let source = self.runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            CFRunLoopStop(CFRunLoopGetCurrent())
            self.runLoopSource = nil
            self.withStateLock {
                self.eventTap = nil
                self.threadRunLoop = nil
            }
        }
        thread = nil
    }

    private func performOnTapThread(_ block: @escaping () -> Void) {
        guard let rl = withStateLock({ threadRunLoop }) else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    @discardableResult
    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }
}
