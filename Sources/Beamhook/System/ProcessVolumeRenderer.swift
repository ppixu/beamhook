import CoreAudio

/// One tap's stereo PCM → output device. All mutable state is confined to the
/// controller's serial IO queue; rendering allocates nothing and takes no locks.
/// HAL drift compensation keeps capture and playback on the aggregate's clock.
final class ProcessVolumeRenderer {
    var targetGain: Float
    private(set) var currentGain: Float
    private let rampStep: Float
    private let outputChannels: Int

    init(gain: Float, sampleRate: Double, outputChannels: Int) {
        targetGain = gain
        currentGain = gain
        rampStep = 1 / Float(max(1, sampleRate * 0.005))
        self.outputChannels = outputChannels
    }

    /// Accept only formats we can actually render. Unsupported devices fail
    /// before starting a muted tap, leaving the app's original output intact.
    static func isSupported(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && format.mFormatFlags & kAudioFormatFlagIsPacked != 0
            && format.mBitsPerChannel == 32
            && format.mChannelsPerFrame > 0
            && format.mSampleRate.isFinite && format.mSampleRate > 0
            && format.mBytesPerFrame == 4 * (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
                                            ? 1 : format.mChannelsPerFrame)
    }

    /// Returns false on unexpected buffer layouts. Output is always initialized,
    /// including unused frames; never read beyond a buffer during device changes.
    @discardableResult
    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) -> Bool {
        let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let destinations = UnsafeMutableAudioBufferListPointer(output)
        for buffer in destinations {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        // HAL can omit capture data while a process is idle. This is a silent
        // quantum, not a device failure that should tear down the tap.
        if sources.allSatisfy({ $0.mData == nil || $0.mDataByteSize == 0 }) { return true }
        guard let inputFrames = Self.frameCount(sources, channels: 2),
              let outputFrames = Self.frameCount(destinations, channels: outputChannels),
              inputFrames == outputFrames else { return false }
        let target = targetGain.isFinite ? min(1, max(0, targetGain)) : 0
        for frame in 0..<inputFrames {
            currentGain += min(rampStep, max(-rampStep, target - currentGain))
            let left = Self.sample(sources, channel: 0, frame: frame)
            let right = Self.sample(sources, channel: 1, frame: frame)
            if outputChannels == 1 {
                Self.write((left * 0.5 + right * 0.5) * currentGain,
                           to: destinations, channel: 0, frame: frame)
            } else {
                Self.write(left * currentGain, to: destinations, channel: 0, frame: frame)
                Self.write(right * currentGain, to: destinations, channel: 1, frame: frame)
            }
        }
        return true
    }

    private static func frameCount(_ buffers: UnsafeMutableAudioBufferListPointer, channels: Int) -> Int? {
        var total = 0
        var frames: Int?
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            guard count > 0, buffer.mData != nil,
                  Int(buffer.mDataByteSize) % (4 * count) == 0 else { return nil }
            let n = Int(buffer.mDataByteSize) / (4 * count)
            if let frames, n != frames { return nil }
            frames = n
            total += count
        }
        return total == channels ? frames : nil
    }

    private static func sample(_ buffers: UnsafeMutableAudioBufferListPointer, channel: Int, frame: Int) -> Float {
        var channel = channel
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            if channel < count {
                let value = buffer.mData!.assumingMemoryBound(to: Float.self)[frame * count + channel]
                return value.isFinite ? value : 0
            }
            channel -= count
        }
        return 0
    }

    private static func write(_ value: Float, to buffers: UnsafeMutableAudioBufferListPointer,
                              channel: Int, frame: Int) {
        var channel = channel
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            if channel < count {
                buffer.mData!.assumingMemoryBound(to: Float.self)[frame * count + channel] = value
                return
            }
            channel -= count
        }
    }

    /// Validate every stream, not just the first buffer's apparent byte count.
    static func configuration(device: AudioObjectID) -> (sampleRate: Double, outputChannels: Int)? {
        func formats(scope: AudioObjectPropertyScope) -> [AudioStreamBasicDescription]? {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
            var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr else { return nil }
            var result: [AudioStreamBasicDescription] = []
            for stream in streams {
                address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
                var format = AudioStreamBasicDescription()
                size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format) == noErr,
                      isSupported(format) else { return nil }
                result.append(format)
            }
            return result
        }
        guard let inputs = formats(scope: kAudioDevicePropertyScopeInput),
              let outputs = formats(scope: kAudioDevicePropertyScopeOutput),
              let rate = inputs.first?.mSampleRate,
              inputs.reduce(0, { $0 + $1.mChannelsPerFrame }) == 2,
              (inputs + outputs).allSatisfy({ $0.mSampleRate == rate }) else { return nil }
        let channels = Int(outputs.reduce(0, { $0 + $1.mChannelsPerFrame }))
        guard channels == 1 || channels == 2 else { return nil }
        return (rate, channels)
    }
}
