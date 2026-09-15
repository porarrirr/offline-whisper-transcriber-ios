import Foundation

struct TranscriptContextBuilder: Sendable {
    struct Chunk: Identifiable, Sendable, Equatable {
        let id: Int
        let text: String
    }

    let maximumChunkCharacters: Int

    init(maximumChunkCharacters: Int = 8_000) {
        self.maximumChunkCharacters = maximumChunkCharacters
    }

    func chunks(from transcript: String) -> [Chunk] {
        let paragraphs = transcript
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let units = paragraphs.isEmpty ? [transcript] : paragraphs
        var result: [String] = []
        var current = ""

        for unit in units {
            for piece in split(unit) {
                let separator = current.isEmpty ? "" : "\n"
                if current.count + separator.count + piece.count <= maximumChunkCharacters {
                    current += separator + piece
                } else {
                    if !current.isEmpty { result.append(current) }
                    current = piece
                }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.enumerated().map { Chunk(id: $0.offset, text: $0.element) }
    }

    func relevantChunks(for question: String, in chunks: [Chunk], limit: Int = 2) -> [Chunk] {
        let terms = searchTerms(in: question)
        guard !terms.isEmpty else { return Array(chunks.prefix(limit)) }
        return chunks
            .map { chunk in
                let folded = chunk.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                let score = terms.reduce(into: 0) { total, term in
                    total += folded.components(separatedBy: term).count - 1
                }
                return (chunk, score)
            }
            .sorted {
                if $0.1 == $1.1 { return $0.0.id < $1.0.id }
                return $0.1 > $1.1
            }
            .prefix(limit)
            .map(\.0)
    }

    private func split(_ text: String) -> [String] {
        guard text.count > maximumChunkCharacters else { return [text] }
        var pieces: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maximumChunkCharacters, limitedBy: text.endIndex) ?? text.endIndex
            pieces.append(String(text[start..<end]))
            start = end
        }
        return pieces
    }

    private func searchTerms(in text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var terms = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        let cjkCharacters = folded.filter { character in
            character.unicodeScalars.contains { scalar in
                (0x3040...0x30FF).contains(scalar.value) ||
                    (0x3400...0x9FFF).contains(scalar.value)
            }
        }
        if cjkCharacters.count >= 2 {
            terms += zip(cjkCharacters, cjkCharacters.dropFirst()).map { String([$0, $1]) }
        }
        return Array(Set(terms))
    }
}
