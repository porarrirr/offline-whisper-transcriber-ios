import Foundation
import AVFoundation

class AudioConverter {
    static let shared = AudioConverter()
    
    private init() {}
    
    func convertToWhisperSamples(inputURL: URL, sampleRate: Double = 16000) async throws -> [Float] {
        let inputFile = try AVAudioFile(forReading: inputURL)
        let inputFormat = inputFile.processingFormat
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0, sampleRate > 0 else {
            throw AudioConverterError.invalidAudioFile
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioConverterError.outputFormatCreationFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioConverterError.converterCreationFailed
        }

        let inputCapacity: AVAudioFrameCount = 4096
        let outputCapacity = AVAudioFrameCount(
            max(1024, ceil(Double(inputCapacity) * sampleRate / inputFormat.sampleRate) + 16)
        )

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity) else {
            throw AudioConverterError.bufferCreationFailed
        }

        var samples: [Float] = []
        if inputFile.length > 0 {
            let estimatedFrameCount = Int(ceil(Double(inputFile.length) * sampleRate / inputFormat.sampleRate))
            samples.reserveCapacity(max(estimatedFrameCount, 0))
        }

        var reachedEndOfInput = false
        var inputReadError: Error?
        var inputReadPosition: AVAudioFramePosition = inputFile.framePosition
        let conversionDetails = Self.conversionDetails(
            inputURL: inputURL,
            inputFormat: inputFormat,
            outputFormat: outputFormat,
            inputFile: inputFile
        )
        AppLogger.info(
            "音声変換を開始しました: \(conversionDetails), inputCapacity=\(inputCapacity), outputCapacity=\(outputCapacity)",
            context: "AudioConverter"
        )

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if reachedEndOfInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            inputReadPosition = inputFile.framePosition
            if inputFile.length > 0 && inputReadPosition >= inputFile.length {
                reachedEndOfInput = true
                outStatus.pointee = .endOfStream
                AppLogger.info(
                    "音声入力の終端に到達しました: \(conversionDetails), readPosition=\(inputReadPosition), samples=\(samples.count)",
                    context: "AudioConverter"
                )
                return nil
            }

            do {
                try inputFile.read(into: inputBuffer)
                if inputBuffer.frameLength == 0 {
                    reachedEndOfInput = true
                    outStatus.pointee = .endOfStream
                    AppLogger.info(
                        "音声入力の読み込みが空で終了しました: \(conversionDetails), readPosition=\(inputReadPosition), samples=\(samples.count)",
                        context: "AudioConverter"
                    )
                    return nil
                }
                outStatus.pointee = .haveData
                return inputBuffer
            } catch {
                inputReadError = error
                outStatus.pointee = .endOfStream
                AppLogger.error(
                    "音声入力の読み込みに失敗しました: \(conversionDetails), readPosition=\(inputReadPosition)",
                    context: "AudioConverter",
                    error: error
                )
                return nil
            }
        }

        while true {
            if let inputReadError {
                throw AudioConverterError.conversionFailed(inputReadError)
            }

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                throw AudioConverterError.bufferCreationFailed
            }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
            if let inputReadError {
                throw AudioConverterError.conversionFailed(inputReadError)
            }

            if outputBuffer.frameLength > 0 {
                guard let channelData = outputBuffer.floatChannelData?[0] else {
                    throw AudioConverterError.unsupportedPCMFormat
                }
                let frameCount = Int(outputBuffer.frameLength)
                samples.append(contentsOf: UnsafeBufferPointer(start: channelData, count: frameCount))
            }

            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                if reachedEndOfInput && outputBuffer.frameLength == 0 {
                    guard !samples.isEmpty else {
                        AppLogger.error(
                            "音声変換結果が空です: status=inputRanDry, \(conversionDetails), readPosition=\(inputReadPosition)",
                            context: "AudioConverter"
                        )
                        throw AudioConverterError.emptyAudioFile
                    }
                    AppLogger.info(
                        "音声変換が完了しました: status=inputRanDry, \(conversionDetails), readPosition=\(inputReadPosition), samples=\(samples.count), duration=\(Self.sampleDuration(samples.count, sampleRate: sampleRate))",
                        context: "AudioConverter"
                    )
                    return samples
                }
                continue
            case .endOfStream:
                guard !samples.isEmpty else {
                    AppLogger.error(
                        "音声変換結果が空です: status=endOfStream, \(conversionDetails), readPosition=\(inputReadPosition)",
                        context: "AudioConverter"
                    )
                    throw AudioConverterError.emptyAudioFile
                }
                AppLogger.info(
                    "音声変換が完了しました: status=endOfStream, \(conversionDetails), readPosition=\(inputReadPosition), samples=\(samples.count), duration=\(Self.sampleDuration(samples.count, sampleRate: sampleRate))",
                    context: "AudioConverter"
                )
                return samples
            case .error:
                if let error {
                    AppLogger.error(
                        "音声変換に失敗しました: status=error, \(conversionDetails), readPosition=\(inputReadPosition), samples=\(samples.count)",
                        context: "AudioConverter",
                        error: error
                    )
                    throw AudioConverterError.conversionFailed(error)
                } else {
                    AppLogger.error(
                        "音声変換がエラー詳細なしで終了しました: status=error, \(conversionDetails), readPosition=\(inputReadPosition), samples=\(samples.count)",
                        context: "AudioConverter"
                    )
                    throw AudioConverterError.conversionEndedUnexpectedly
                }
            @unknown default:
                AppLogger.error(
                    "音声変換が未知の状態で終了しました: status=\(status), \(conversionDetails), readPosition=\(inputReadPosition), samples=\(samples.count)",
                    context: "AudioConverter"
                )
                throw AudioConverterError.conversionEndedUnexpectedly
            }
        }
    }
    
    func getAudioDuration(url: URL) -> Double {
        let asset = AVAsset(url: url)
        return CMTimeGetSeconds(asset.duration)
    }

    private static func conversionDetails(
        inputURL: URL,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        inputFile: AVAudioFile
    ) -> String {
        "url=\(inputURL.lastPathComponent), input=\(formatDescription(inputFormat)), output=\(formatDescription(outputFormat)), length=\(inputFile.length)"
    }

    private static func formatDescription(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate))Hz/\(format.channelCount)ch/\(format.commonFormat)"
    }

    private static func sampleDuration(_ sampleCount: Int, sampleRate: Double) -> String {
        String(format: "%.2fs", Double(sampleCount) / sampleRate)
    }
    
    enum AudioConverterError: LocalizedError {
        case outputFormatCreationFailed
        case bufferCreationFailed
        case converterCreationFailed
        case invalidAudioFile
        case emptyAudioFile
        case unsupportedPCMFormat
        case conversionFailed(Error)
        case conversionEndedUnexpectedly
        
        var errorDescription: String? {
            switch self {
            case .outputFormatCreationFailed:
                return "Whisper用の16kHz/mono PCM形式を作成できませんでした"
            case .bufferCreationFailed:
                return "音声変換用バッファを作成できませんでした"
            case .converterCreationFailed:
                return "音声コンバーターを作成できませんでした"
            case .invalidAudioFile:
                return "音声ファイルのチャンネル情報が不正です"
            case .emptyAudioFile:
                return "音声データが空です"
            case .unsupportedPCMFormat:
                return "対応していないPCM形式です"
            case .conversionFailed(let error):
                let nsError = error as NSError
                return "音声変換に失敗しました: \(nsError.localizedDescription)（domain: \(nsError.domain), code: \(nsError.code)）"
            case .conversionEndedUnexpectedly:
                return "音声変換が予期せず終了しました"
            }
        }
    }
}
