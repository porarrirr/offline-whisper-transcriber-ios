import AVFoundation
import Foundation

/// Stateful, bounded level conditioning for Apple's file transcription input.
/// Process decoded PCM before speech detection; never gate or remove audio.
/// One instance belongs to one conversion, so packet size cannot change the gain.
final class SpeechAudioPreprocessor {
    private var format: AVAudioFormat?
    private var previousInput: [Double] = []
    private var previousOutput: [Double] = []
    private var squareSum = 0.0
    private var measuredFrames = 0
    private var targetGain = 1.0
    private var gain = 1.0
    private var limiterGain = 1.0

    func process(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let inputFormat = input.format
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              inputFormat.commonFormat == .pcmFormatFloat32 || inputFormat.commonFormat == .pcmFormatInt16 else {
            throw AudioConverter.AudioConverterError.unsupportedPCMFormat
        }
        if let format {
            guard format == inputFormat else {
                throw AudioConverter.AudioConverterError.invalidAudioFile
            }
        } else {
            format = inputFormat
            previousInput = .init(repeating: 0, count: Int(inputFormat.channelCount))
            previousOutput = previousInput
        }
        guard let output = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: max(input.frameLength, 1)) else {
            throw AudioConverter.AudioConverterError.bufferCreationFailed
        }
        output.frameLength = input.frameLength
        let channels = Int(inputFormat.channelCount)
        let isInterleaved = inputFormat.isInterleaved
        let isFloat = inputFormat.commonFormat == .pcmFormatFloat32
        // Resolve AVAudioPCMBuffer's channel pointers once per buffer, not twice
        // per sample. Keep the buffers alive for the entire pointer access.
        defer {
            withExtendedLifetime(input) {}
            withExtendedLifetime(output) {}
        }
        let inputFloatChannels = isFloat ? input.floatChannelData : nil
        let outputFloatChannels = isFloat ? output.floatChannelData : nil
        let inputInt16Channels = isFloat ? nil : input.int16ChannelData
        let outputInt16Channels = isFloat ? nil : output.int16ChannelData
        let sampleStride = isInterleaved ? channels : 1
        let sampleRate = inputFormat.sampleRate
        let highPassPole = exp(-2 * Double.pi * 60 / sampleRate)
        let measurementFrames = max(1, Int(sampleRate * 0.1))
        let gainRise = 1 - exp(-1 / (sampleRate * 0.5))
        let gainFall = 1 - exp(-1 / (sampleRate * 0.1))
        let limiterRelease = 1 - exp(-1 / (sampleRate * 0.1))
        var filtered = [Double](repeating: 0, count: channels)

        for frame in 0..<Int(input.frameLength) {
            var framePower = 0.0
            var peak = 0.0
            for channel in 0..<channels {
                let plane = isInterleaved ? 0 : channel
                let offset = frame * sampleStride + (isInterleaved ? channel : 0)
                let sample: Double
                if isFloat {
                    sample = Double(inputFloatChannels![plane][offset])
                } else {
                    sample = Double(inputInt16Channels![plane][offset]) / 32_768
                }
                guard sample.isFinite else {
                    throw AudioConverter.AudioConverterError.invalidAudioFile
                }
                let value = highPassPole * (previousOutput[channel] + sample - previousInput[channel])
                previousInput[channel] = sample
                previousOutput[channel] = value
                filtered[channel] = value
                framePower += value * value
                peak = max(peak, abs(value))
            }
            squareSum += framePower / Double(channels)
            measuredFrames += 1
            if measuredFrames == measurementFrames {
                let rms = sqrt(squareSum / Double(measuredFrames))
                // Do not chase digital silence / very faint background noise.
                // Bound amplification to 6x (+15.6 dB), aiming at -24 dBFS.
                targetGain = rms >= 0.001778 ? min(6, max(1, 0.063096 / rms)) : 1
                squareSum = 0
                measuredFrames = 0
            }
            gain += (targetGain - gain) * (targetGain > gain ? gainRise : gainFall)
            // A click must not turn down minutes of quiet speech. Share the
            // limiter across channels and recover over 100 ms, without clipping.
            let safeGain = peak * gain > 0.95 ? 0.95 / (peak * gain) : 1
            limiterGain = min(safeGain, limiterGain + (1 - limiterGain) * limiterRelease)
            for channel in 0..<channels {
                let plane = isInterleaved ? 0 : channel
                let offset = frame * sampleStride + (isInterleaved ? channel : 0)
                let value = filtered[channel] * gain * limiterGain
                if isFloat {
                    outputFloatChannels![plane][offset] = Float(value)
                } else {
                    outputInt16Channels![plane][offset] = Int16((value * 32_768).rounded())
                }
            }
        }
        return output
    }
}
