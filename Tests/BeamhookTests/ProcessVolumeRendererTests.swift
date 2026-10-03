import XCTest
import CoreAudio
@testable import Beamhook

final class ProcessVolumeRendererTests: XCTestCase {
    /// Own the storage for arbitrary interleaved/planar HAL buffer layouts.
    private final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        init(_ values: [[Float]], channels: [UInt32]) {
            list = AudioBufferList.allocate(maximumBuffers: values.count)
            list.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(values.count)
            for i in values.indices {
                let data = UnsafeMutablePointer<Float>.allocate(capacity: max(1, values[i].count))
                data.initialize(from: values[i], count: values[i].count)
                list[i] = AudioBuffer(mNumberChannels: channels[i],
                                      mDataByteSize: UInt32(values[i].count * 4), mData: data)
            }
        }
        func samples(_ index: Int) -> [Float] {
            Array(UnsafeBufferPointer(start: list[index].mData!.assumingMemoryBound(to: Float.self),
                                      count: Int(list[index].mDataByteSize) / 4))
        }
        deinit {
            for buffer in list { buffer.mData!.assumingMemoryBound(to: Float.self).deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    func testStereoGainPreservesChannelsAndPolarity() {
        let input = Buffers([[1, -1, 0.4, -0.2]], channels: [2])
        let output = Buffers([[99, 99, 99, 99]], channels: [2])
        let renderer = ProcessVolumeRenderer(gain: 0.5, sampleRate: 48000, outputChannels: 2)
        XCTAssertTrue(renderer.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer))
        XCTAssertEqual(output.samples(0), [0.5, -0.5, 0.2, -0.1])
    }

    func testPlanarInputCanRenderInterleavedAndViceVersa() {
        let planar = Buffers([[1, 0.2], [-1, -0.4]], channels: [1, 1])
        let interleaved = Buffers([[0, 0, 0, 0]], channels: [2])
        let output = Buffers([[0, 0], [0, 0]], channels: [1, 1])
        let renderer = ProcessVolumeRenderer(gain: 1, sampleRate: 44100, outputChannels: 2)
        XCTAssertTrue(renderer.render(input: planar.list.unsafePointer, output: interleaved.list.unsafeMutablePointer))
        XCTAssertEqual(interleaved.samples(0), [1, -1, 0.2, -0.4])
        XCTAssertTrue(renderer.render(input: interleaved.list.unsafePointer, output: output.list.unsafeMutablePointer))
        XCTAssertEqual(output.samples(0), [1, 0.2])
        XCTAssertEqual(output.samples(1), [-1, -0.4])
    }

    func testMonoOutputAveragesStereoInsteadOfDroppingOneSide() {
        let input = Buffers([[1, -1, 0.6, 0.2]], channels: [2])
        let output = Buffers([[99, 99]], channels: [1])
        let renderer = ProcessVolumeRenderer(gain: 0.5, sampleRate: 48000, outputChannels: 1)
        XCTAssertTrue(renderer.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer))
        XCTAssertEqual(output.samples(0)[0], 0)
        XCTAssertEqual(output.samples(0)[1], 0.2, accuracy: 0.00001)
    }

    func testGainChangesRampAcrossCallbacksAndMuteReachesZero() {
        let input = Buffers([Array(repeating: 1, count: 240)], channels: [2])
        let output = Buffers([Array(repeating: 99, count: 240)], channels: [2])
        let renderer = ProcessVolumeRenderer(gain: 1, sampleRate: 48000, outputChannels: 2)
        renderer.targetGain = 0
        renderer.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        let first = output.samples(0)
        XCTAssertGreaterThan(first[0], 0.99)
        XCTAssertEqual(first[0], first[1])
        XCTAssertEqual(first.last!, 0.5, accuracy: 0.00001)
        renderer.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        XCTAssertLessThan(output.samples(0)[0], first.last!)
        XCTAssertEqual(output.samples(0).last!, 0, accuracy: 0.00001)
        renderer.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        XCTAssertEqual(output.samples(0), Array(repeating: 0, count: 240))
        renderer.targetGain = 0.35
        renderer.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        XCTAssertEqual(output.samples(0).last!, 0.35, accuracy: 0.00001)
    }

    func testUnexpectedLayoutsOrFrameCountsFailWithZeroedOutput() {
        let renderer = ProcessVolumeRenderer(gain: 1, sampleRate: 48000, outputChannels: 2)
        for (samples, channels) in [([[Float(1), 1]], [UInt32(1)]),
                                    ([[Float(1), 1, 1, 1]], [UInt32(2)]),
                                    ([[Float(1)], [1, 1]], [UInt32(1), 1])] {
            let input = Buffers(samples, channels: channels)
            let output = Buffers([[99, 99]], channels: [2])
            XCTAssertFalse(renderer.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer))
            XCTAssertEqual(output.samples(0), [0, 0])
        }
    }

    func testIdleInputPlaysSilenceWithoutRequestingARebuild() {
        let input = Buffers([[]], channels: [2])
        let output = Buffers([[99, 99]], channels: [2])
        let renderer = ProcessVolumeRenderer(gain: 0.5, sampleRate: 48000, outputChannels: 2)
        XCTAssertTrue(renderer.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer))
        XCTAssertEqual(output.samples(0), [0, 0])
    }

    func testNonfiniteInputDoesNotPoisonOutput() {
        let input = Buffers([[.nan, .infinity, -.infinity, 1]], channels: [2])
        let output = Buffers([[99, 99, 99, 99]], channels: [2])
        let renderer = ProcessVolumeRenderer(gain: 0.5, sampleRate: 48000, outputChannels: 2)
        renderer.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        XCTAssertEqual(output.samples(0), [0, 0, 0, 0.5])
    }

    func testFormatValidationRejectsIntegerOrPaddedAudio() {
        var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        XCTAssertTrue(ProcessVolumeRenderer.isSupported(format))
        format.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
        format.mBytesPerFrame = 4
        XCTAssertTrue(ProcessVolumeRenderer.isSupported(format))
        format.mBytesPerFrame = 8
        XCTAssertFalse(ProcessVolumeRenderer.isSupported(format))
        format.mBytesPerFrame = 4
        format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        XCTAssertFalse(ProcessVolumeRenderer.isSupported(format))
    }
}
