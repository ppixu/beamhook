import Cocoa
import CoreGraphics
import os
import BeamhookKit

/// A keyboard tap that exists only while any Beamhook HUD is on screen. It
/// swallows Command-arrow keys (and the ⌘PgUp/⌘PgDn aliases) for the volume-source picker
/// and hands every other keystroke back untouched. Between `disarm()` and the
/// next `arm()` there is no keyboard tap at all, so Beamhook never sees ordinary
/// typing.
///
/// Threading: `arm()`/`disarm()` are called on the main thread. The tap lives on
/// a dedicated thread's run loop — an installed keyboard tap delays every
/// keystroke on the system until its callback returns, so it must never wait on
/// a busy main thread. The tap objects are touched only on that thread.
final class SourcePickerKeyTap: @unchecked Sendable {
    typealias Handler = (SourcePickerKey) -> Void

    private static let log = Logger(subsystem: "com.github.ppixu.beamhook", category: "SourcePicker")

    private let handler: Handler
    private let lock = NSLock()
    private var runLoop: CFRunLoop?          // guarded by `lock`
    private var thread: Thread?              // main thread only
    private var eventTap: CFMachPort?        // tap thread only
    private var runLoopSource: CFRunLoopSource?   // tap thread only

    /// `handler` runs on the main queue, for key-downs (auto-repeat included, so
    /// holding ⌘↓ walks the list).
    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func arm() {
        startThreadIfNeeded()
        performOnTapThread { [weak self] in self?.installTap() }
    }

    func disarm() {
        performOnTapThread { [weak self] in self?.removeTap() }
    }

    /// Internal rather than private so the unit tests can drive it with
    /// synthetic events; only the tap callback calls it in production.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        guard let key = SourcePickerKey.match(
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            command: flags.contains(.maskCommand),
            shift: flags.contains(.maskShift),
            option: flags.contains(.maskAlternate),
            control: flags.contains(.maskControl))
        else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown {
            DispatchQueue.main.async { [weak self] in self?.handler(key) }
        }
        // Swallow the key-up too, so the frontmost app never sees half a chord.
        return nil
    }

    private func startThreadIfNeeded() {
        guard thread == nil else { return }
        let started = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self else { started.signal(); return }
            self.lock.withLock { self.runLoop = CFRunLoopGetCurrent() }
            // A run loop with no sources returns at once; a port keeps it alive
            // between arms.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            started.signal()
            CFRunLoopRun()
        }
        t.name = "com.beamhook.source-picker-tap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        started.wait()
    }

    private func installTap() {
        guard eventTap == nil else { return }
        let mask = (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue))
            | (CGEventMask(1) << CGEventMask(CGEventType.keyUp.rawValue))
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let me = Unmanaged<SourcePickerKeyTap>.fromOpaque(userInfo!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        // `self` is passed unretained; AppState holds this object for the app's
        // whole lifetime, so it always outlives the installed tap.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Self.log.error("could not create the source-picker keyboard tap")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    private func removeTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        eventTap = nil
        runLoopSource = nil
    }

    private func performOnTapThread(_ block: @escaping () -> Void) {
        guard let rl = lock.withLock({ runLoop }) else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(rl)
    }
}
