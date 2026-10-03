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
/// whose only job is to keep the tap read. Mute-only callbacks ignore the data.
/// Volume-controlled apps instead replay the samples through a gain ramp.
/// No audio is stored.
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
    @Published private(set) var volumes: [String: Int]
    @Published private(set) var volumeErrors: [String: String] = [:]
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
        let renderer: ProcessVolumeRenderer?
    }

    /// Active mutes keyed by the process object they silence. Engine-queue only.
    private var mutes: [AudioObjectID: ActiveMute] = [:]
    private var timer: Timer?
    private var controlledIdentity: [AudioObjectID: String] = [:]
    private var observedOutput: AudioObjectID?
    private var outputListener: AudioObjectPropertyListenerBlock?

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
        self.volumes = PerAppMutePreference.volumes(defaults)
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
        volumes = [:]
        volumeErrors = [:]
        PerAppMutePreference.setVolumes([:], in: defaults)
        setMeterWatchlist([])
        applyAndReschedule()
    }

    func volume(for bundleID: String) -> Int { volumes[bundleID] ?? 100 }

    func setVolume(_ percent: Int, bundleID: String) {
        guard !bundleID.hasPrefix("com.github.ppixu.beamhook") else { return }
        let next = min(100, max(0, percent))
        guard next != volume(for: bundleID) else { return }
        // Keep a live renderer at 100% until the process exits so the final step
        // ramps smoothly. Only levels below 100% survive a Beamhook restart.
        volumes[bundleID] = next
        PerAppMutePreference.setVolumes(volumes, in: defaults)
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
        let audible = Set(loudObjects.compactMap { meterIdentity[$0] ?? controlledIdentity[$0] }).intersection(watch)
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
        let muted = mutedBundleIDs
        let levels = volumes
        engine.async { [weak self] in self?.reconcile(muted: muted, levels: levels) }
        if muted.isEmpty && levels.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.applyAndReschedule()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// Engine-queue only. Existing renderers receive gain updates on their IO
    /// queue; changing the slider does not rebuild devices or interrupt audio.
    private func reconcile(muted: Set<String>, levels: [String: Int]) {
        let bundles = muted.union(levels.keys)
        var wanted: [AudioObjectID: String] = [:]
        if !bundles.isEmpty {
            for obj in AudioProcessMonitor.processObjectIDs() {
                guard let bid = AudioProcessMonitor.rowBundleID(for: obj),
                      bundles.contains(bid), !bid.hasPrefix("com.github.ppixu.beamhook") else { continue }
                wanted[obj] = bid
            }
        }
        for (obj, assembly) in mutes where wanted[obj] == nil {
            tearDown(assembly)
            mutes[obj] = nil
            controlledIdentity[obj] = nil
            loudLock.lock(); loudUntil[obj] = nil; loudLock.unlock()
        }
        var errors: [String: String] = [:]
        for (obj, bid) in wanted {
            let needsRenderer = levels[bid] != nil && !muted.contains(bid)
            let gain: Float = muted.contains(bid) ? 0 : Float(levels[bid] ?? 100) / 100
            if let assembly = mutes[obj] {
                if let renderer = assembly.renderer {
                    ioQueue.async { renderer.targetGain = gain }
                    continue
                }
                if !needsRenderer { continue }
                tearDown(assembly)
                mutes[obj] = nil
            }
            // A controlled tap also supplies the meter; never run a second tap
            // on the same process alongside playback.
            if let meter = meters.removeValue(forKey: obj) { tearDown(meter) }
            meterIdentity[obj] = nil
            switch buildAssembly(for: obj, muteBehavior: .muted,
                                 playbackGain: needsRenderer ? gain : nil) {
            case .success(let assembly):
                mutes[obj] = assembly
                controlledIdentity[obj] = bid
                DispatchQueue.main.async { [weak self] in self?.permissionGranted = true }
            case .processGone:
                break
            case .failure(let err):
                Self.log.error("Audio control failed for app \(bid, privacy: .public), object \(obj): \(err)")
                if let message = Self.volumeError(for: err,
                        isRunningOutput: AudioProcessMonitor.isRunningOutput(obj)) {
                    errors[bid] = message
                }
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.volumeErrors != errors else { return }
            self.volumeErrors = errors
        }
    }

    /// Browsers keep idle audio helpers around after pausing. Their tap format
    /// may be unavailable until output resumes, or the helper may disappear
    /// during setup. Keep the saved volume usable and let reconciliation retry;
    /// only a failure on a live output should disable the app's controls.
    static func volumeError(for status: OSStatus, isRunningOutput: Bool) -> String? {
        guard isRunningOutput, status != noErr,
              status != kAudioHardwareBadObjectError else { return nil }
        return status == kAudioDeviceUnsupportedFormatError
            ? "Volume control could not initialize the audio stream. Beamhook will retry automatically."
            : "Audio control failed. Check System Audio Recording permission and try again."
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
                               ioBlock: AudioDeviceIOBlock? = nil,
                               playbackGain: Float? = nil) -> BuildResult {
        let outputDevice = Self.defaultOutputDevice()
        let bundleID = AudioProcessMonitor.rowBundleID(for: obj) ?? "unknown"
        var diagnostics: [String] = []
        func failure(_ status: OSStatus, stage: String) -> BuildResult {
            let detail = diagnostics.joined(separator: "; ")
            Self.log.error("Audio setup failed: app=\(bundleID, privacy: .public), process=\(obj), output=\(outputDevice?.id ?? 0), stage=\(stage, privacy: .public), status=\(status), details=\(detail, privacy: .public)")
            return status == kAudioHardwareBadObjectError ? .processGone : .failure(status)
        }
        let description = CATapDescription(stereoMixdownOfProcesses: [obj])
        description.muteBehavior = muteBehavior
        description.isPrivate = true
        description.name = "Beamhook mute"

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr, tapID != kAudioObjectUnknown else {
            return failure(err, stage: "create process tap")
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
        if let outputUID = outputDevice?.uid {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey as String] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey as String] = [
                [kAudioSubDeviceUIDKey as String: outputUID,
                 kAudioSubDeviceInputChannelsKey as String: 0]
            ]
        }

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard err == noErr, aggregateID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            return failure(err, stage: "create aggregate")
        }

        // The read that engages the mute (and the permission). For a mute the
        // buffers are deliberately ignored; the HAL hands the output side to us
        // pre-zeroed, so leaving it untouched plays silence.
        var renderer: ProcessVolumeRenderer?
        var callback = ioBlock ?? { _, _, _, _, _ in }
        if let gain = playbackGain {
            // A tap initially defaults to 48 kHz even on a 44.1 kHz output.
            // Set the private aggregate to the physical output's existing rate;
            // HAL converts the tap using drift compensation. Never retune the
            // user's hardware just to accommodate our capture stream.
            guard let outputDevice,
                  Self.matchOutputRate(aggregate: aggregateID, output: outputDevice.id,
                                       diagnostic: { diagnostics.append($0) }) else {
                AudioHardwareDestroyAggregateDevice(aggregateID)
                AudioHardwareDestroyProcessTap(tapID)
                return failure(kAudioDeviceUnsupportedFormatError, stage: "match output sample rate")
            }
            guard let configuration = ProcessVolumeRenderer.configuration(device: aggregateID,
                    diagnostic: { diagnostics.append($0) }) else {
                AudioHardwareDestroyAggregateDevice(aggregateID)
                AudioHardwareDestroyProcessTap(tapID)
                return failure(kAudioDeviceUnsupportedFormatError, stage: "validate aggregate streams")
            }
            let playback = ProcessVolumeRenderer(gain: gain, sampleRate: configuration.sampleRate,
                                                 outputChannels: configuration.outputChannels)
            renderer = playback
            var invalidated = false // IO-queue confined, just like the renderer.
            callback = { [weak self] _, input, _, output, _ in
                guard playback.render(input: input, output: output) else {
                    if !invalidated {
                        invalidated = true
                        self?.engine.async { [weak self] in
                            guard let self, self.mutes[obj]?.aggregateID == aggregateID else { return }
                            self.rebuildAssemblies()
                        }
                    }
                    return
                }
                if playback.currentGain > 0 {
                    self?.notePeak(obj: obj, bufferList: UnsafePointer(output))
                }
            }
        }
        var ioProcID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue, callback)
        guard err == noErr, let ioProcID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return failure(err, stage: "create IO callback")
        }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return failure(err, stage: "start IO")
        }

        return .success(ActiveMute(tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID, renderer: renderer))
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
            self?.observeOutputFormat()
            self?.rebuildAssemblies()
        }
        engine.async { [weak self] in self?.observeOutputFormat() }
    }

    /// A Bluetooth profile or Audio MIDI Setup can change the format without
    /// changing the default device. Rebuild against its new clock/layout too.
    private func observeOutputFormat() {
        let selectors: [AudioObjectPropertySelector] = [kAudioDevicePropertyNominalSampleRate,
                                                        kAudioDevicePropertyStreamConfiguration]
        if let device = observedOutput, let listener = outputListener {
            for selector in selectors {
                var address = AudioObjectPropertyAddress(mSelector: selector,
                    mScope: selector == kAudioDevicePropertyStreamConfiguration
                        ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(device, &address, engine, listener)
            }
        }
        observedOutput = Self.defaultOutputDevice()?.id
        guard let device = observedOutput else { outputListener = nil; return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebuildAssemblies() }
        outputListener = listener
        for selector in selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: selector == kAudioDevicePropertyStreamConfiguration
                    ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(device, &address, engine, listener)
        }
    }

    private func rebuildAssemblies() {
        for assembly in mutes.values { tearDown(assembly) }
        mutes = [:]
        controlledIdentity = [:]
        for assembly in meters.values { tearDown(assembly) }
        meters = [:]
        meterIdentity = [:]
        loudLock.lock(); loudUntil = [:]; loudLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.applyAndReschedule() }
    }

    private static func matchOutputRate(aggregate: AudioObjectID, output: AudioObjectID,
                                        diagnostic: (String) -> Void) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let readStatus = AudioObjectGetPropertyData(output, &address, 0, nil, &size, &rate)
        diagnostic("physical output nominal rate=\(rate), readStatus=\(readStatus)")
        guard readStatus == noErr, rate.isFinite, rate > 0 else { return false }
        let writeStatus = AudioObjectSetPropertyData(aggregate, &address, 0, nil, size, &rate)
        diagnostic("set aggregate nominal rate=\(rate), writeStatus=\(writeStatus)")
        return writeStatus == noErr
    }

    private static func defaultOutputDevice() -> (id: AudioObjectID, uid: String)? {
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
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return (device, uid as String)
    }
}
