import Cocoa
import CoreGraphics
import BeamhookKit

/// NSSystemDefined event type (NX_SYSDEFINED from <IOKit/hidsystem/IOLLEvent.h>).
private let kSystemDefinedEventType: UInt32 = 14

/// Owns a CGEventTap on a dedicated background thread + run loop.
/// Threading contract: the public methods (start/stop/ensureEnabled/recreate, isEnabled)
/// are expected to be called from the main thread (AppState/TapWatchdog do so). All
/// mutation of the tap state (eventTap/runLoopSource) is marshalled onto the tap thread
/// via performOnTapThread; the callback runs on the tap thread. Do not call the public
/// methods concurrently from multiple threads.
final class MediaKeyTap {
    typealias Handler = (MediaKey) -> Void

    private let handler: Handler
    /// Browser targets leave transport keys to macOS until tab injection is
    /// available; all other targets keep Beamhook's exclusive routing.
    var transportKeysHijacked = true
    /// When true, hardware volume up/down keys are swallowed and forwarded to the
    /// target app instead of the system. Set from the main thread; read on the tap
    /// thread — a plain Bool is safe here (single-word, tolerates a one-tick stale read).
    var volumeKeysHijacked = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?

    /// `handler` is always invoked on the main thread, for key-down transport keys only.
    init(handler: @escaping Handler) {
        self.handler = handler
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
        threadRunLoop = CFRunLoopGetCurrent()
        createTap()
        CFRunLoopRun()
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
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // System disabled the tap — re-enable and keep the event.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
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
                return Unmanaged.passUnretained(event)
            }
            // Act on key-down only; swallow both down and up to stop other apps /
            // Music auto-launch.
            if decoded.isDown && !decoded.isRepeat {
                DispatchQueue.main.async { [weak self] in self?.handler(key) }
            }
            return nil
        }

        if key.isVolume && volumeKeysHijacked {
            // Forward on key-down AND repeats so holding the key ramps the volume.
            if decoded.isDown {
                DispatchQueue.main.async { [weak self] in self?.handler(key) }
            }
            return nil
        }

        // Everything else (volume keys when not hijacked, mute, ff/rewind) passes through.
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
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Re-enable if disabled, or recreate if the tap object is gone. Safe to call from any thread.
    func ensureEnabled() {
        performOnTapThread { [weak self] in
            guard let self else { return }
            if let tap = self.eventTap {
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
            self.eventTap = nil
            self.createTap()
        }
    }

    func stop() {
        performOnTapThread { [weak self] in
            guard let self else { return }
            if let tap = self.eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
            if let source = self.runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            CFRunLoopStop(CFRunLoopGetCurrent())
            self.runLoopSource = nil
            self.eventTap = nil
            self.threadRunLoop = nil
        }
        thread = nil
    }

    private func performOnTapThread(_ block: @escaping () -> Void) {
        guard let rl = threadRunLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(rl)
    }
}
