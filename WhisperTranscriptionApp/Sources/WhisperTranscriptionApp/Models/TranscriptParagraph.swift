import Foundation

/// Presentation only: source segments and their original timing remain editable.
struct TranscriptParagraph: Identifiable, Equatable {
    let id: Int
    struct Part: Equatable {
        let segment: TranscriptionSegment
        let text: String
    }
    let parts: [Part]
    var segments: [TranscriptionSegment] { parts.map(\.segment) }

    static func make(from segments: [TranscriptionSegment]) -> [Self] {
        var result: [Self] = []
        var current: [Part] = []
        var length = 0
        func flush() {
            guard !current.isEmpty else { return }
            result.append(Self(id: result.count, parts: current))
            current = []
            length = 0
        }
        for segment in segments where !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let previous = current.last {
                let endsSentence = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .last.map { "。！？.!?」』\"".contains($0) } ?? false
                let pause = segment.start - previous.segment.end
                if pause >= 2 || (endsSentence && length >= 100) || length >= 350 {
                    flush()
                }
            }
            if segment.text.count > 350 {
                flush()
                for text in readingChunks(segment.text) {
                    result.append(Self(id: result.count, parts: [Part(segment: segment, text: text)]))
                }
            } else {
                current.append(Part(segment: segment, text: segment.text))
                length += segment.text.count
            }
        }
        flush()
        return result
    }

    /// Split long recognition segments at sentence boundaries without inventing finer timestamps.
    static func readingChunks(_ text: String, targetLength: Int = 180) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "\n" || (current.count >= targetLength && "。！？.!?".contains(character)) {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(current) }
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(current) }
        return chunks
    }

    func activeSegment(at time: TimeInterval) -> Int? {
        // Half-open intervals avoid highlighting two adjacent segments at a boundary.
        parts.lastIndex { $0.segment.start <= time && time < $0.segment.end }
    }
}
