import AppKit
import CoreAudio
import OSLog
import BeamhookKit

/// Mutes individual apps with Core Audio process taps, no AppleScript (or any
/// cooperation from the app) required. This is what makes otherwise
/// uncontrollable apps — Electron players, chat apps with notification dings —
/// mutable from the popover.
///
/// A tap alone does NOT mute: `CATapMuteBehavior.muted` only suppresses the
/// process's output while the tap is actually being read (verified on macOS 26
/// — a bare muted tap changes nothing audible). So each muted process gets the
/// full assembly: a muted tap, plus a private aggregate device containing the
/// tap and the default output device (as the clock), plus a do-nothing IO proc
/// whose only job is to keep the tap read. The IO callbacks ignore the data;
/// Beamhook never records anything.
///
/// Reading tap audio is what the System Audio Recording permission gates
/// (`NSAudioCaptureUsageDescription`; revocable under Privacy & Security →
/// Screen & System Audio Recording). Merely creating a tap is not gated, which
/// is why the prompt appears at first mute/probe IO rather than earlier.
///
/// Taps die with their process (and with Beamhook: coreaudiod discards a
/// client's taps when it exits, so quitting Beamhook unmutes everything). The
/// muted set therefore persists by bundle id, and a 2s poll — running only
/// while something is muted — re-taps matching processes as they (re)appear.
///
/// Threading: the public API and the published properties are main-thread only,
/// like every other AppState collaborator. The HAL calls all run on `engine`,
/// because tap/aggregate work can block while the permission prompt is on
/// screen and must never stall the main thread (the popover and the key tap
/// live there).
@available(macOS 14.2, *)
final class ProcessMuteController: ObservableObject {
    @Published private(set) var mutedBundleIDs: Set<String>
    /// nil until a tap attempt settles it. False drives the Settings hint that
    /// links to the Privacy pane — without it a denied permission is
    /// indistinguishable from mute buttons that silently do nothing.
    @Published private(set) var permissionGranted: Bool?
    /// Watched apps that were audibly emitting within the last beat — the
    /// popover's EQ animation for apps with no other play-state source.
    @Published private(set) var audibleApps: Set<String> = []

    private let defaults: UserDefaults
    private let engine = DispatchQueue(label: "com.github.ppixu.beamhook.mute")
    /// Queue the do-nothing IO callbacks land on. Separate from `engine` so
    /// audio-rate callbacks never queue behind a blocked tap creation.
    private let ioQueue = DispatchQueue(label: "com.github.ppixu.beamhook.mute.io")

    /// Everything one muted process needs; see the type comment for why a tap
    /// alone is not enough. Engine-queue only.
    private struct ActiveMute {
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        let ioProcID: AudioDeviceIOProcID
    }

    /// Active mutes keyed by the process object they silence. Engine-queue only.
    private var mutes: [AudioObjectID: ActiveMute] = [:]
    private var timer: Timer?

    // Metering (see `setMeterWatchlist`): the same tap assembly, unmuted, whose
    // IO block measures peaks instead of ignoring the buffers.
    private var meters: [AudioObjectID: ActiveMute] = [:]      // engine-queue only
    private var meterIdentity: [AudioObjectID: String] = [:]   // engine-queue only
    private var meterWatchlist: Set<String> = []               // main thread only
    private var meterTimer: Timer?
    /// Written from the IO queue, read from the engine — hence its own lock.
    private let loudLock = NSLock()
    private var loudUntil: [AudioObjectID: TimeInterval] = [:]

    private static let log = Logger(subsystem: "com.github.ppixu.beamhook", category: "Mute")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.mutedBundleIDs = PerAppMutePreference.mutedBundleIDs(defaults)
        observeDefaultOutputChanges()
    }

    /// Begin managing taps (feature enabled — at launch or via Settings).
    func start() {
        applyAndReschedule()
    }

    /// Feature disabled: drop every tap (unmuting the apps) and forget the set.
    /// The preference side is cleared by `PerAppMutePreference.setEnabled(false)`.
    func stopAndClear() {
        mutedBundleIDs = []
        setMeterWatchlist([])
        applyAndReschedule()
    }

    func isMuted(_ bundleID: String) -> Bool {
        mutedBundleIDs.contains(bundleID)
    }

    func setMuted(_ muted: Bool, bundleID: String) {
        if muted {
            mutedBundleIDs.insert(bundleID)
        } else {
            mutedBundleIDs.remove(bundleID)
        }
        PerAppMutePreference.setMutedBundleIDs(mutedBundleIDs, in: defaults)
        applyAndReschedule()
    }

    /// Trigger the System Audio Recording prompt by briefly running the whole
    /// mute assembly — unmuted, on an arbitrary process — since only reading a
    /// tap is gated. Once the user has answered, later attempts don't prompt
    /// again, so this also serves as the "Re-check" probe after a trip to
    /// System Settings.
    func requestPermission() {
        engine.async { [weak self] in
            guard let self else { return }
            var granted: Bool?
            // A process can die between enumeration and the create call; only a
            // live process's answer says anything about the permission.
            for obj in AudioProcessMonitor.processObjectIDs() {
                switch self.buildAssembly(for: obj, muteBehavior: .unmuted) {
                case .success(let probe):
                    // Long enough for the IO to actually start (and macOS to
                    // count it as a capture attempt), short enough to go
                    // unnoticed. Nothing is read out of the buffers.
                    Thread.sleep(forTimeInterval: 0.3)
                    self.tearDown(probe)
                    granted = true
                case .processGone:
                    continue
                case .failure(let err):
                    Self.log.error("Permission probe failed: \(err)")
                    granted = false
                }
                break
            }
            if let granted, granted { Self.log.notice("Permission probe succeeded") }
            guard let granted else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.permissionGranted = granted
                if granted { self.applyAndReschedule() }
            }
        }
    }

    // MARK: - Emission metering

    /// Apps whose "actually making sound" state the popover wants live. Core
    /// Audio's running-output flag is too sticky for an animation (a paused
    /// player keeps its stream open; Unity holds one open, silent, for a whole
    /// play-mode session), and apps with no scripting expose no play state —
    /// so for those rows the truth comes from listening: an unmuted tap whose
    /// IO block measures peaks. Empty set (menu closed, feature off) tears all
    /// meters down. Main thread only.
    func setMeterWatchlist(_ bundleIDs: Set<String>) {
        guard bundleIDs != meterWatchlist else { return }
        meterWatchlist = bundleIDs
        if bundleIDs.isEmpty {
            meterTimer?.invalidate()
            meterTimer = nil
            if !audibleApps.isEmpty { audibleApps = [] }
        } else if meterTimer == nil {
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self else { return }
                let watch = self.meterWatchlist
                self.engine.async { [weak self] in self?.meterTick(watch: watch) }
            }
            RunLoop.main.add(t, forMode: .common)
            meterTimer = t
        }
        let watch = bundleIDs
        engine.async { [weak self] in self?.meterTick(watch: watch) }
    }

    /// Engine-queue only: reconcile the meter assemblies, then publish which
    /// watched apps were audible within the last beat.
    private func meterTick(watch: Set<String>) {
        var wanted: [AudioObjectID: String] = [:]
        if !watch.isEmpty {
            for obj in AudioProcessMonitor.processObjectIDs()
            where AudioProcessMonitor.isRunningOutput(obj) && mutes[obj] == nil {
                guard let bid = AudioProcessMonitor.rowBundleID(for: obj),
                      watch.contains(bid) else { continue }
                wanted[obj] = bid
            }
        }
        for (obj, meter) in meters where wanted[obj] == nil {
            tearDown(meter)
            meters[obj] = nil
            meterIdentity[obj] = nil
            loudLock.lock(); loudUntil[obj] = nil; loudLock.unlock()
        }
        for (obj, bid) in wanted where meters[obj] == nil {
            let block: AudioDeviceIOBlock = { [weak self] _, inInputData, _, _, _ in
                self?.notePeak(obj: obj, bufferList: inInputData)
            }
            if case .success(let assembly) = buildAssembly(for: obj, muteBehavior: .unmuted,
                                                           ioBlock: block) {
                meters[obj] = assembly
                meterIdentity[obj] = bid
            }
        }

        let now = Date().timeIntervalSinceReferenceDate
        loudLock.lock()
        let loudObjects = loudUntil.filter { $0.value > now }.map(\.key)
        loudLock.unlock()
        let audible = Set(loudObjects.compactMap { meterIdentity[$0] })
        DispatchQueue.main.async { [weak self] in
            guard let self, self.audibleApps != audible else { return }
            self.audibleApps = audible
        }
    }

    /// IO-queue: cheap peak probe. Every 8th sample is plenty to detect
    /// presence, and taps deliver Float32, so a threshold of 0.002 (~-54 dB)
    /// separates sound from a stream of zeros.
    private func notePeak(obj: AudioObjectID, bufferList: UnsafePointer<AudioBufferList>) {
        var peak: Float = 0
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            var index = 0
            while index < count {
                let value = abs(samples[index])
                if value > peak { peak = value }
                index += 8
            }
        }
        guard peak > 0.002 else { return }
        loudLock.lock()
        loudUntil[obj] = Date().timeIntervalSinceReferenceDate + 0.45
        loudLock.unlock()
    }

    // MARK: - Tap management

    /// Reconcile the mute assemblies with the muted set now, and keep a slow
    /// poll running while anything is muted so a muted app that (re)launches is
    /// re-tapped. Main thread only.
    private func applyAndReschedule() {
        let wanted = mutedBundleIDs
        engine.async { [weak self] in self?.reconcile(muted: wanted) }
        if mutedBundleIDs.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                let wanted = self.mutedBundleIDs
                self.engine.async { [weak self] in self?.reconcile(muted: wanted) }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// Engine-queue only.
    private func reconcile(muted: Set<String>) {
        var wanted = Set<AudioObjectID>()
        if !muted.isEmpty {
            for obj in AudioProcessMonitor.processObjectIDs()
            where muted.contains(AudioProcessMonitor.rowBundleID(for: obj) ?? "") {
                wanted.insert(obj)
            }
        }
        for (obj, mute) in mutes where !wanted.contains(obj) {
            tearDown(mute)
            mutes[obj] = nil
        }
        for obj in wanted where mutes[obj] == nil {
            switch buildAssembly(for: obj, muteBehavior: .muted) {
            case .success(let mute):
                Self.log.notice("Muting process object \(obj) (tap \(mute.tapID), aggregate \(mute.aggregateID))")
                mutes[obj] = mute
                DispatchQueue.main.async { [weak self] in self?.permissionGranted = true }
            case .processGone:
                break
            case .failure(let err):
                Self.log.error("Mute assembly failed for object \(obj): \(err)")
                DispatchQueue.main.async { [weak self] in self?.permissionGranted = false }
            }
        }
    }

    private enum BuildResult {
        case success(ActiveMute)
        /// The process quit mid-build — not an error and says nothing about
        /// the permission.
        case processGone
        case failure(OSStatus)
    }

    /// Engine-queue only. Assembles tap + private aggregate + running IO proc.
    /// `ioBlock` nil means the do-nothing read that engages a mute; the meters
    /// pass a block that measures the buffers instead.
    private func buildAssembly(for obj: AudioObjectID,
                               muteBehavior: CATapMuteBehavior,
                               ioBlock: AudioDeviceIOBlock? = nil) -> BuildResult {
        let description = CATapDescription(stereoMixdownOfProcesses: [obj])
        description.muteBehavior = muteBehavior
        description.isPrivate = true
        description.name = "Beamhook mute"

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr, tapID != kAudioObjectUnknown else {
            return err == kAudioHardwareBadObjectError ? .processGone : .failure(err)
        }

        // The default output serves as the aggregate's clock; without a real
        // device the tap-only aggregate never pulls IO. A default-output switch
        // is handled by rebuilding every assembly (see the property listener).
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Beamhook mute",
            kAudioAggregateDeviceUIDKey as String: "com.github.ppixu.beamhook.mute.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]
        if let outputUID = Self.defaultOutputDeviceUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey as String] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey as String] = [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ]
        }

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard err == noErr, aggregateID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            return .failure(err)
        }

        // The read that engages the mute (and the permission). For a mute the
        // buffers are deliberately ignored; the HAL hands the output side to us
        // pre-zeroed, so leaving it untouched plays silence.
        var ioProcID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue,
                                                 ioBlock ?? { _, _, _, _, _ in })
        guard err == noErr, let ioProcID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return .failure(err)
        }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return .failure(err)
        }

        return .success(ActiveMute(tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID))
    }

    /// Engine-queue only.
    private func tearDown(_ mute: ActiveMute) {
        AudioDeviceStop(mute.aggregateID, mute.ioProcID)
        AudioDeviceDestroyIOProcID(mute.aggregateID, mute.ioProcID)
        AudioHardwareDestroyAggregateDevice(mute.aggregateID)
        AudioHardwareDestroyProcessTap(mute.tapID)
    }

    /// The aggregates are clocked by the default output device, so when the
    /// user switches outputs (headphones, AirPlay) every assembly is rebuilt on
    /// the new clock — otherwise the mutes would keep running against a device
    /// that may go away entirely.
    private func observeDefaultOutputChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, engine
        ) { [weak self] _, _ in
            guard let self else { return }
            for (obj, mute) in self.mutes {
                self.tearDown(mute)
                self.mutes[obj] = nil
            }
            for (obj, meter) in self.meters {
                self.tearDown(meter)
                self.meters[obj] = nil
                self.meterIdentity[obj] = nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Re-runs the reconcile with the current set (and keeps the
                // poll timer consistent with it); the meter timer's next tick
                // rebuilds the meters the same way.
                self.applyAndReschedule()
            }
        }
    }

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else {
            return nil
        }
        return uid as String
    }
}
