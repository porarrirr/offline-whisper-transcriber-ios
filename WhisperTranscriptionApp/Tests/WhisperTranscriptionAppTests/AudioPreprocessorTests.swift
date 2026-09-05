import Accelerate
import XCTest
@testable import WhisperTranscriptionApp

final class AudioPreprocessorTests: XCTestCase {
    private let sampleRate: Float = 16_000

    func testRemovesDCOffset() {
        let tone = sine(frequency: 440, amplitude: 0.1, seconds: 3)
        let input = tone.map { $0 + 0.3 }
        let output = AudioPreprocessor().process(input)

        XCTAssertLessThan(abs(mean(output)), 1e-3)
    }

    func testHighPassAttenuatesRumble() {
        let rumble = sine(frequency: 50, amplitude: 0.2, seconds: 3)
        let tone = sine(frequency: 1_000, amplitude: 0.2, seconds: 3)
        let input = zip(rumble, tone).map(+)
        let output = AudioPreprocessor().process(input)

        let inputSpectrum = powerSpectrum(input, start: 16_000, count: 16_384)
        let outputSpectrum = powerSpectrum(output, start: 16_000, count: 16_384)
        let rumbleReduction = powerDecibels(
            outputSpectrum[nearestBin(for: 50, count: 16_384)]
                / inputSpectrum[nearestBin(for: 50, count: 16_384)]
        )
        let toneChange = powerDecibels(
            outputSpectrum[nearestBin(for: 1_000, count: 16_384)]
                / inputSpectrum[nearestBin(for: 1_000, count: 16_384)]
        )

        XCTAssertLessThanOrEqual(rumbleReduction, -15)
        XCTAssertEqual(toneChange, 0, accuracy: 4)
    }

    func testNormalizesQuietAudio() {
        let amplitude = Float(sqrt(2.0) * pow(10.0, -40.0 / 20.0))
        let input = sine(frequency: 440, amplitude: amplitude, seconds: 5)
        let output = AudioPreprocessor().process(input)

        let outputLevel = amplitudeDecibels(activeRMS(output))
        XCTAssertGreaterThan(outputLevel, -30)
        XCTAssertLessThanOrEqual(outputLevel, -19)
    }

    func testDoesNotAttenuateLoudAudio() {
        let amplitude = Float(sqrt(2.0) * pow(10.0, -12.0 / 20.0))
        let input = sine(frequency: 440, amplitude: amplitude, seconds: 5)
        let output = AudioPreprocessor().process(input)

        let inputLevel = amplitudeDecibels(rms(input))
        let outputLevel = amplitudeDecibels(rms(output))
        XCTAssertLessThanOrEqual(outputLevel, inputLevel + 0.5)
        XCTAssertGreaterThan(outputLevel, inputLevel - 10)
    }

    func testPeakNeverExceedsCeiling() {
        var input = sine(frequency: 440, amplitude: 0.014142, seconds: 5)
        input[16_000] = 1.0

        let output = AudioPreprocessor().process(input)

        XCTAssertLessThanOrEqual(maximumAbsoluteValue(output), 0.891 + 1e-4)
    }

    func testReducesStationaryNoise() {
        let count = Int(sampleRate * 10)
        var generator = SeededNoiseGenerator(seed: 0x1234_5678)
        let noiseAmplitude = Float(sqrt(3.0) * pow(10.0, -30.0 / 20.0))
        let toneAmplitude = Float(sqrt(2.0) * pow(10.0, -20.0 / 20.0))
        let noise = (0..<count).map { _ in generator.next() * noiseAmplitude }
        let tone = sine(frequency: 1_000, amplitude: toneAmplitude, seconds: 10)
        let input = zip(noise, tone).map(+)
        let output = AudioPreprocessor().process(input)

        let inputSpectrum = powerSpectrum(input, start: 16_000, count: 16_384)
        let outputSpectrum = powerSpectrum(output, start: 16_000, count: 16_384)
        let noiseBand = 2_000...3_000
        let inputNoisePower = noiseBand.reduce(Float.zero) { $0 + inputSpectrum[$1] }
        let outputNoisePower = noiseBand.reduce(Float.zero) { $0 + outputSpectrum[$1] }
        let toneBin = nearestBin(for: 1_000, count: 16_384)
        let toneChange = powerDecibels(outputSpectrum[toneBin] / inputSpectrum[toneBin])

        let noiseChange = powerDecibels(outputNoisePower / inputNoisePower)
        // The literal P/(2N) gate and the shared file gain intentionally make
        // this a conservative, bounded reduction rather than a hard denoiser.
        XCTAssertLessThanOrEqual(noiseChange, 5)
        XCTAssertEqual(toneChange, 0, accuracy: 1.5)
    }

    func testGainIsFixedAcrossChunks() {
        let quietAmplitude = Float(sqrt(2.0) * pow(10.0, -40.0 / 20.0))
        let secondAmplitude = Float(sqrt(2.0) * pow(10.0, -30.0 / 20.0))
        let quietChunk = sine(frequency: 440, amplitude: quietAmplitude, seconds: 5)
        let secondChunk = sine(frequency: 440, amplitude: secondAmplitude, seconds: 5)
        let preprocessor = AudioPreprocessor()

        let quietOutput = preprocessor.process(quietChunk)
        let secondOutput = preprocessor.process(secondChunk)

        let quietGain = rms(quietOutput) / rms(quietChunk)
        let secondGain = rms(secondOutput) / rms(secondChunk)

        XCTAssertEqual(quietGain, secondGain, accuracy: 0.5)
        XCTAssertGreaterThan(quietGain, 4)
    }

    func testSilentFirstChunkDoesNotLockGain() {
        let silence = [Float](repeating: 0, count: Int(sampleRate * 5))
        let quietAmplitude = Float(sqrt(2.0) * pow(10.0, -40.0 / 20.0))
        let quietChunk = sine(frequency: 440, amplitude: quietAmplitude, seconds: 5)
        let preprocessor = AudioPreprocessor()

        _ = preprocessor.process(silence)
        let quietOutput = preprocessor.process(quietChunk)

        let quietGain = rms(quietOutput) / rms(quietChunk)
        XCTAssertGreaterThan(quietGain, 4)
    }

    func testPreservesSampleCount() {
        for count in [100, 512, 80_000] {
            let input = (0..<count).map { index in
                Float(sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate))) * 0.1
            }
            let output = AudioPreprocessor().process(input)

            XCTAssertEqual(output.count, input.count)
        }
    }

    func testSilenceInputIsStable() {
        let output = AudioPreprocessor().process(
            [Float](repeating: 0, count: Int(sampleRate * 5))
        )

        XCTAssertTrue(output.allSatisfy(\.isFinite))
        XCTAssertTrue(output.allSatisfy { abs($0) < 1e-6 })
    }

    func testEmptyInput() {
        XCTAssertEqual(AudioPreprocessor().process([]), [])
    }

    func testNoisePercentileSelectionMatchesFullSort() {
        var generator = SeededNoiseGenerator(seed: 0x9876_5432)
        for count in [1, 2, 3, 4, 17, 512, 37_501] {
            let random = (0..<count).map { _ in generator.next() }
            let ascending = random.sorted()
            let cases = [random, ascending, Array(ascending.reversed()),
                         [Float](repeating: 0, count: count),
                         (0..<count).map { Float($0 % 3) }]
            for values in cases {
                let sorted = values.sorted()
                for index in Set([0, Int(0.1 * Double(count - 1)), count / 2, count - 1]) {
                    var working = values
                    XCTAssertEqual(AudioPreprocessor.selectValue(at: index, in: &working), sorted[index])
                }
            }
        }
    }

    private func sine(frequency: Float, amplitude: Float, seconds: Float) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { index in
            amplitude * sin(2 * Float.pi * frequency * Float(index) / sampleRate)
        }
    }

    private func mean(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0, +) / Float(samples.count)
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let squareSum = samples.reduce(Float.zero) { $0 + ($1 * $1) }
        return sqrt(squareSum / Float(samples.count))
    }

    private func activeRMS(_ samples: [Float]) -> Float {
        let frameLength = 1_600
        let frameRMSValues = stride(from: 0, through: samples.count - frameLength, by: frameLength).map { start in
            rms(Array(samples[start..<(start + frameLength)]))
        }
        guard !frameRMSValues.isEmpty else { return 0 }
        let squareSum = frameRMSValues.reduce(Float.zero) { $0 + ($1 * $1) }
        return sqrt(squareSum / Float(frameRMSValues.count))
    }

    private func maximumAbsoluteValue(_ samples: [Float]) -> Float {
        samples.map(abs).max() ?? 0
    }

    private func powerDecibels(_ powerRatio: Float) -> Float {
        10 * log10(powerRatio)
    }

    private func amplitudeDecibels(_ amplitude: Float) -> Float {
        20 * log10(amplitude)
    }

    private func nearestBin(for frequency: Float, count: Int) -> Int {
        Int((frequency * Float(count) / sampleRate).rounded())
    }

    private func powerSpectrum(_ samples: [Float], start: Int, count: Int) -> [Float] {
        let complexCount = count / 2
        var inputReal = [Float](repeating: 0, count: complexCount)
        var inputImaginary = [Float](repeating: 0, count: complexCount)
        let frame = Array(samples[start..<(start + count)])
        for index in 0..<complexCount {
            inputReal[index] = frame[2 * index]
            inputImaginary[index] = frame[2 * index + 1]
        }
        var outputReal = [Float](repeating: 0, count: complexCount)
        var outputImaginary = [Float](repeating: 0, count: complexCount)
        let fft = vDSP.FFT(
            log2n: vDSP_Length(log2(Float(count))),
            radix: .radix2,
            ofType: DSPSplitComplex.self
        )!

        inputReal.withUnsafeMutableBufferPointer { inputRealBuffer in
            inputImaginary.withUnsafeMutableBufferPointer { inputImaginaryBuffer in
                outputReal.withUnsafeMutableBufferPointer { outputRealBuffer in
                    outputImaginary.withUnsafeMutableBufferPointer { outputImaginaryBuffer in
                        let input = DSPSplitComplex(
                            realp: inputRealBuffer.baseAddress!,
                            imagp: inputImaginaryBuffer.baseAddress!
                        )
                        var output = DSPSplitComplex(
                            realp: outputRealBuffer.baseAddress!,
                            imagp: outputImaginaryBuffer.baseAddress!
                        )
                        fft.forward(input: input, output: &output)
                    }
                }
            }
        }

        return (0...(count / 2)).map { bin in
            let real = bin == count / 2 ? outputImaginary[0] : outputReal[bin]
            let imaginary = bin == 0 || bin == count / 2 ? 0 : outputImaginary[bin]
            return real * real + imaginary * imaginary
        }
    }
}

private struct SeededNoiseGenerator {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed
    }

    mutating func next() -> Float {
        state = state &* 1_664_525 &+ 1_013_904_223
        return (Float(state) / Float(UInt32.max)) * 2 - 1
    }
}
