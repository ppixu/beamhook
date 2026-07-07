import CoreAudio
import Foundation

/// Tracks whether the current default output device has an adjustable volume.
/// When it doesn't (many audio interfaces / aggregate / HDMI devices — e.g. a
/// Scarlett Solo), the hardware volume keys do nothing. Beamhook surfaces this as a
/// UI hint suggesting the user route the keys to the target app; it does NOT take
/// them over automatically (that silent behavior was removed).
final class AudioOutputMonitor: ObservableObject {
    @Published private(set) var outputVolumeControllable: Bool = true

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private static var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func start() {
        refresh()
        guard listenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, DispatchQueue.main, block)
    }

    func stop() {
        guard let block = listenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, DispatchQueue.main, block)
        listenerBlock = nil
    }

    func refresh() {
        let controllable = Self.defaultOutputDevice().map(Self.deviceHasSettableVolume) ?? true
        if controllable != outputVolumeControllable { outputVolumeControllable = controllable }
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, &size, &device)
        return (status == noErr && device != 0) ? device : nil
    }

    private static func deviceHasSettableVolume(_ device: AudioObjectID) -> Bool {
        // Try the master element first, then the first two channels.
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var settable = DarwinBoolean(false)
            if AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue {
                return true
            }
        }
        return false
    }
}
