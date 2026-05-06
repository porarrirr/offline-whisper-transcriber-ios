import Foundation
import AVFoundation

class AudioConverter {
    static let shared = AudioConverter()
    
    private init() {}
    
    func convertToWav(inputURL: URL, outputURL: URL, sampleRate: Double = 16000) async throws {
        let inputFile = try AVAudioFile(forReading: inputURL)

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioConverterError.outputFormatCreationFailed
        }

        guard let converter = AVAudioConverter(from: inputFile.processingFormat, to: outputFormat) else {
            throw AudioConverterError.converterCreationFailed
        }

        let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputFormat.settings)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: 4096),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else {
            throw AudioConverterError.bufferCreationFailed
        }

        var reachedEndOfInput = false
        var error: NSError?

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if reachedEndOfInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            do {
                try inputFile.read(into: inputBuffer)
                if inputBuffer.frameLength == 0 {
                    reachedEndOfInput = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inputBuffer
            } catch {
                outStatus.pointee = .endOfStream
                return nil
            }
        }

        while true {
            let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

            if status == .haveData {
                if outputBuffer.frameLength > 0 {
                    try outputFile.write(from: outputBuffer)
                }
            } else if status == .inputRanDry {
                continue
            } else if status == .endOfStream {
                break
            } else if let error = error {
                throw AudioConverterError.conversionFailed(error)
            } else {
                throw AudioConverterError.conversionEndedUnexpectedly
            }
        }
    }
    
    func getAudioDuration(url: URL) -> Double {
        let asset = AVAsset(url: url)
        return CMTimeGetSeconds(asset.duration)
    }
    
    enum AudioConverterError: LocalizedError {
        case outputFormatCreationFailed
        case bufferCreationFailed
        case converterCreationFailed
        case conversionFailed(Error)
        case conversionEndedUnexpectedly
        
        var errorDescription: String? {
            switch self {
            case .outputFormatCreationFailed:
                return "Whisper用の16kHz/mono WAV形式を作成できませんでした"
            case .bufferCreationFailed:
                return "音声変換用バッファを作成できませんでした"
            case .converterCreationFailed:
                return "音声コンバーターを作成できませんでした"
            case .conversionFailed(let error):
                return "音声変換に失敗しました: \(error.localizedDescription)"
            case .conversionEndedUnexpectedly:
                return "音声変換が予期せず終了しました"
            }
        }
    }
}
