import Foundation

struct TranscriptContextBuilder: Sendable {
    struct Chunk: Identifiable, Sendable, Equatable {
        let id: Int
        let text: String
        let startCharacter: Int
        let endCharacter: Int

        func approximateTimeRange(transcriptLength: Int, duration: TimeInterval) -> ClosedRange<TimeInterval>? {
            guard transcriptLength > 0, duration > 0 else { return nil }
            let start = duration * Double(startCharacter) / Double(transcriptLength)
            let end = duration * Double(endCharacter) / Double(transcriptLength)
            return start...min(duration, end)
        }
    }

    let maximumChunkCharacters: Int
    let overlapCharacters: Int

    init(maximumChunkCharacters: Int = 10_000, overlapCharacters: Int = 500) {
        precondition(maximumChunkCharacters > 0)
        precondition(overlapCharacters >= 0 && overlapCharacters < maximumChunkCharacters)
        self.maximumChunkCharacters = maximumChunkCharacters
        self.overlapCharacters = overlapCharacters
    }

    /// ASRが語中で改行・分割した断片を、CJKや句読点の境界を考慮して再結合する。
    func normalizedTranscript(_ transcript: String) -> String {
        TranscriptionSegment.joinedPlainText(
            from: transcript.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        )
    }

    /// セグメント境界は信用せず、正規化した全文を重なり付きの固定長ウィンドウにする。
    func chunks(from transcript: String) -> [Chunk] {
        let normalized = normalizedTranscript(transcript)
        guard !normalized.isEmpty else { return [] }
        var chunks: [Chunk] = []
        var startOffset = 0
        let strideLength = maximumChunkCharacters - overlapCharacters

        while startOffset < normalized.count {
            let start = normalized.index(normalized.startIndex, offsetBy: startOffset)
            let endOffset = min(startOffset + maximumChunkCharacters, normalized.count)
            let end = normalized.index(normalized.startIndex, offsetBy: endOffset)
            chunks.append(Chunk(
                id: chunks.count,
                text: String(normalized[start..<end]),
                startCharacter: startOffset,
                endCharacter: endOffset
            ))
            guard endOffset < normalized.count else { break }
            startOffset += strideLength
        }
        return chunks
    }
}
