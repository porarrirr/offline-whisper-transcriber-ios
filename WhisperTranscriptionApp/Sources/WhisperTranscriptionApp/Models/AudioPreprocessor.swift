import Accelerate
import Foundation

/// 16kHz モノラル Float32 PCM チャンクを前処理する。
/// ファイル 1 本の文字起こしにつき 1 インスタンスを生成して使い回す(正規化ゲインを共有するため)。
/// 正規化ゲインは最初に有声フレームを検出したチャンクで確定する(無音チャンクでは確定しない)。
/// スレッド安全ではない。呼び出しは直列であること(チャンクコールバックは直列なので満たされる)。
final class AudioPreprocessor {
    private static let sampleRate: Double = 16_000.0
    private static let highPassCutoffHz: Double = 80.0
    private static let highPassQ: Double = 0.70710678
    private static let highPassSectionCount = 2
    private static let fftSize = 512
    private static let hopSize = 128
    private static let binCount = 257
    private static let noisePercentile: Double = 0.10
    private static let thresholdMultiplier: Float = 2.0
    private static let floorGain: Float = 0.25
    private static let temporalReleaseFactor: Float = 0.6
    private static let colaNormalization: Float = 2.0
    private static let targetRMS: Float = 0.1
    private static let minGain: Float = 1.0
    private static let maxGain: Float = 10.0
    private static let peakCeiling: Float = 0.891
    private static let rmsFrameLength = 1_600
    private static let activeFrameRMSThreshold: Float = 0.003162

    private var fileGain: Float?

    init() {}

    /// 入力と同じサンプル数の配列を返す。空配列は空配列を返す。
    func process(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else {
            return []
        }

        var mean: Float = 0
        samples.withUnsafeBufferPointer { input in
            vDSP_meanv(
                input.baseAddress!,
                1,
                &mean,
                vDSP_Length(input.count)
            )
        }

        var meanOffset = -mean
        var centered = [Float](repeating: 0, count: samples.count)
        samples.withUnsafeBufferPointer { input in
            centered.withUnsafeMutableBufferPointer { output in
                vDSP_vsadd(
                    input.baseAddress!,
                    1,
                    &meanOffset,
                    output.baseAddress!,
                    1,
                    vDSP_Length(input.count)
                )
            }
        }

        let highPassed = applyHighPass(to: centered)
        let gated = highPassed.count < Self.fftSize
            ? highPassed
            : applySpectralGate(to: highPassed)

        if fileGain == nil {
            fileGain = calculateFileGain(for: gated)
        }

        let normalizedGain = fileGain ?? 1.0
        var chunkPeak: Float = 0
        gated.withUnsafeBufferPointer { input in
            vDSP_maxmgv(
                input.baseAddress!,
                1,
                &chunkPeak,
                vDSP_Length(input.count)
            )
        }

        let appliedGain = chunkPeak > 0
            ? min(normalizedGain, Self.peakCeiling / chunkPeak)
            : normalizedGain
        var output = [Float](repeating: 0, count: gated.count)
        var gain = appliedGain
        gated.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { destination in
                vDSP_vsmul(
                    input.baseAddress!,
                    1,
                    &gain,
                    destination.baseAddress!,
                    1,
                    vDSP_Length(input.count)
                )
            }
        }
        return output
    }

    private func applyHighPass(to samples: [Float]) -> [Float] {
        let omega0 = 2.0 * Double.pi * Self.highPassCutoffHz / Self.sampleRate
        let alpha = sin(omega0) / (2.0 * Self.highPassQ)
        let cosine = cos(omega0)
        let onePlusCosine = 1.0 + cosine
        let a0 = 1.0 + alpha

        let section = [
            (onePlusCosine / 2.0) / a0,
            -onePlusCosine / a0,
            (onePlusCosine / 2.0) / a0,
            (-2.0 * cosine) / a0,
            (1.0 - alpha) / a0
        ]
        let coefficients = section + section

        guard var biquad = vDSP.Biquad<Float>(
            coefficients: coefficients,
            channelCount: 1,
            sectionCount: vDSP_Length(Self.highPassSectionCount),
            ofType: Float.self
        ) else {
            preconditionFailure("Failed to create the high-pass filter")
        }
        return biquad.apply(input: samples)
    }

    private func applySpectralGate(to samples: [Float]) -> [Float] {
        let leadingPadding = Self.fftSize - Self.hopSize
        var padded = [Float](repeating: 0, count: leadingPadding)
        padded.append(contentsOf: samples)
        padded.append(contentsOf: [Float](repeating: 0, count: Self.fftSize))

        let frameCount = (padded.count - Self.fftSize) / Self.hopSize + 1
        let window = makeSqrtHannWindow()
        let fft = makeFFT()
        var powersByBin = [[Float]](
            repeating: [],
            count: Self.binCount
        )
        for bin in 0..<Self.binCount {
            powersByBin[bin].reserveCapacity(frameCount)
        }

        var frame = [Float](repeating: 0, count: Self.fftSize)
        for frameIndex in 0..<frameCount {
            let frameStart = frameIndex * Self.hopSize
            for sampleIndex in 0..<Self.fftSize {
                frame[sampleIndex] = padded[frameStart + sampleIndex] * window[sampleIndex]
            }

            let spectrum = Self.forwardSpectrum(frame, using: fft)
            for bin in 0..<Self.binCount {
                let real = spectrum.real[bin]
                let imaginary = spectrum.imaginary[bin]
                powersByBin[bin].append(real * real + imaginary * imaginary)
            }
        }

        var noiseFloor = [Float](repeating: 0, count: Self.binCount)
        let noiseIndex = Int(
            Self.noisePercentile * Double(frameCount - 1)
        )
        for bin in 0..<Self.binCount {
            powersByBin[bin].sort()
            noiseFloor[bin] = powersByBin[bin][noiseIndex]
        }

        var overlapAdd = [Float](repeating: 0, count: padded.count)
        var previousGain = [Float](repeating: 1.0, count: Self.binCount)

        for frameIndex in 0..<frameCount {
            let frameStart = frameIndex * Self.hopSize
            for sampleIndex in 0..<Self.fftSize {
                frame[sampleIndex] = padded[frameStart + sampleIndex] * window[sampleIndex]
            }

            let spectrum = Self.forwardSpectrum(frame, using: fft)
            var gains = [Float](repeating: 0, count: Self.binCount)
            for bin in 0..<Self.binCount {
                let real = spectrum.real[bin]
                let imaginary = spectrum.imaginary[bin]
                let power = real * real + imaginary * imaginary
                let ratio = noiseFloor[bin] > 0
                    ? power / (Self.thresholdMultiplier * noiseFloor[bin])
                    : 1.0
                gains[bin] = min(max(ratio, Self.floorGain), 1.0)
            }

            var smoothedGains = [Float](repeating: 0, count: Self.binCount)
            for bin in 0..<Self.binCount {
                let previous = bin == 0 ? gains[0] : gains[bin - 1]
                let next = bin == Self.binCount - 1 ? gains[bin] : gains[bin + 1]
                smoothedGains[bin] = (previous + gains[bin] + next) / 3.0
            }

            for bin in 0..<Self.binCount {
                gains[bin] = max(
                    smoothedGains[bin],
                    Self.temporalReleaseFactor * previousGain[bin]
                )
            }
            previousGain = gains

            var filteredReal = spectrum.real
            var filteredImaginary = spectrum.imaginary
            for bin in 0..<Self.binCount {
                filteredReal[bin] *= gains[bin]
                filteredImaginary[bin] *= gains[bin]
            }

            let reconstructed = Self.inverseSamples(
                real: filteredReal,
                imaginary: filteredImaginary,
                using: fft
            )
            for sampleIndex in 0..<Self.fftSize {
                overlapAdd[frameStart + sampleIndex] += reconstructed[sampleIndex] * window[sampleIndex]
            }
        }

        var output = [Float](repeating: 0, count: samples.count)
        for sampleIndex in 0..<samples.count {
            output[sampleIndex] = overlapAdd[leadingPadding + sampleIndex] / Self.colaNormalization
        }
        return output
    }

    /// 有声フレームの RMS からファイル共通ゲインを算出する。有声フレームが無ければ nil(確定しない)。
    private func calculateFileGain(for samples: [Float]) -> Float? {
        var activeRMSValues: [Float] = []
        let completeFrameCount = samples.count / Self.rmsFrameLength
        activeRMSValues.reserveCapacity(completeFrameCount)

        for frameIndex in 0..<completeFrameCount {
            let frameStart = frameIndex * Self.rmsFrameLength
            let frameEnd = frameStart + Self.rmsFrameLength
            var squareSum: Float = 0
            for sample in samples[frameStart..<frameEnd] {
                squareSum += sample * sample
            }
            let frameRMS = sqrt(squareSum / Float(Self.rmsFrameLength))
            if frameRMS > Self.activeFrameRMSThreshold {
                activeRMSValues.append(frameRMS)
            }
        }

        guard !activeRMSValues.isEmpty else {
            return nil
        }

        var activeSquareSum: Float = 0
        for frameRMS in activeRMSValues {
            activeSquareSum += frameRMS * frameRMS
        }
        let activeRMS = sqrt(activeSquareSum / Float(activeRMSValues.count))
        return min(
            max(Self.targetRMS / activeRMS, Self.minGain),
            Self.maxGain
        )
    }

    private func makeSqrtHannWindow() -> [Float] {
        (0..<Self.fftSize).map { index in
            let phase = 2.0 * Double.pi * Double(index) / Double(Self.fftSize)
            return Float(sqrt(0.5 * (1.0 - cos(phase))))
        }
    }

    private func makeFFT() -> vDSP.FFT<DSPSplitComplex> {
        guard let fft = vDSP.FFT(
            log2n: vDSP_Length(log2(Float(Self.fftSize))),
            radix: .radix2,
            ofType: DSPSplitComplex.self
        ) else {
            preconditionFailure("Failed to create the spectral gate FFT")
        }
        return fft
    }

    private static func forwardSpectrum(
        _ frame: [Float],
        using fft: vDSP.FFT<DSPSplitComplex>
    ) -> (real: [Float], imaginary: [Float]) {
        let complexCount = Self.fftSize / 2
        var inputReal = [Float](repeating: 0, count: complexCount)
        var inputImaginary = [Float](repeating: 0, count: complexCount)
        for index in 0..<complexCount {
            inputReal[index] = frame[2 * index]
            inputImaginary[index] = frame[2 * index + 1]
        }
        var outputReal = [Float](repeating: 0, count: complexCount)
        var outputImaginary = [Float](repeating: 0, count: complexCount)

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

        var real = [Float](repeating: 0, count: Self.binCount)
        var imaginary = [Float](repeating: 0, count: Self.binCount)
        real[0] = outputReal[0]
        real[Self.fftSize / 2] = outputImaginary[0]
        for bin in 1..<(Self.fftSize / 2) {
            real[bin] = outputReal[bin]
            imaginary[bin] = outputImaginary[bin]
        }
        return (real, imaginary)
    }

    private static func inverseSamples(
        real: [Float],
        imaginary: [Float],
        using fft: vDSP.FFT<DSPSplitComplex>
    ) -> [Float] {
        let complexCount = Self.fftSize / 2
        var inputReal = [Float](repeating: 0, count: complexCount)
        var inputImaginary = [Float](repeating: 0, count: complexCount)
        inputReal[0] = real[0]
        inputImaginary[0] = real[Self.fftSize / 2]
        for bin in 1..<complexCount {
            inputReal[bin] = real[bin]
            inputImaginary[bin] = imaginary[bin]
        }
        var outputReal = [Float](repeating: 0, count: complexCount)
        var outputImaginary = [Float](repeating: 0, count: complexCount)

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
                        fft.inverse(input: input, output: &output)
                    }
                }
            }
        }

        let scale = 1.0 / (2.0 * Float(Self.fftSize))
        var reconstructed = [Float](repeating: 0, count: Self.fftSize)
        for index in 0..<complexCount {
            reconstructed[2 * index] = outputReal[index] * scale
            reconstructed[2 * index + 1] = outputImaginary[index] * scale
        }
        return reconstructed
    }
}
