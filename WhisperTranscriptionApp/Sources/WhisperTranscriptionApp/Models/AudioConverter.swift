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

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if reachedEndOfInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            do {
                inputReadPosition = inputFile.framePosition
                try inputFile.read(into: inputBuffer)
                if inputBuffer.frameLength == 0 {
                    reachedEndOfInput = true
                    outStatus.pointee = .endOfStream
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
                        throw AudioConverterError.emptyAudioFile
                    }
                    return samples
                }
                continue
            case .endOfStream:
                guard !samples.isEmpty else {
                    throw AudioConverterError.emptyAudioFile
                }
                return samples
            case .error:
                if let error {
                    AppLogger.error(
                        "音声変換に失敗しました: \(conversionDetails), readPosition=\(inputReadPosition)",
                        context: "AudioConverter",
                        error: error
                    )
                    throw AudioConverterError.conversionFailed(error)
                } else {
                    throw AudioConverterError.conversionEndedUnexpectedly
                }
            @unknown default:
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
