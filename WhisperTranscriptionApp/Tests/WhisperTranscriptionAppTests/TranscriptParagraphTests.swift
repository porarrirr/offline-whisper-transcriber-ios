import XCTest
@testable import WhisperTranscriptionApp

final class TranscriptParagraphTests: XCTestCase {
    func testLongSegmentUsesSentenceParagraphsWithoutChangingEditSourceOrTiming() {
        let text = String(repeating: "これは長い説明です。", count: 90)
        let source = TranscriptionSegment(id: 0, start: 5, end: 50, text: text)
        let paragraphs = TranscriptParagraph.make(from: [source])
        XCTAssertGreaterThan(paragraphs.count, 1)
        XCTAssertEqual(paragraphs.flatMap(\.parts).map(\.text).joined(), text)
        for paragraph in paragraphs {
            XCTAssertEqual(paragraph.segments, [source])
            XCTAssertNil(paragraph.activeSegment(at: 4))
            XCTAssertEqual(paragraph.activeSegment(at: 10), 0)
        }
    }

    func testFragmentsStayTogetherAndKeepTiming() {
        let segments = ["簡単な問題", "な", "ん", "で", "す。"].enumerated().map {
            TranscriptionSegment(id: $0.offset, start: Double($0.offset), end: Double($0.offset + 1), text: $0.element)
        }
        let paragraphs = TranscriptParagraph.make(from: segments)
        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].segments, segments)
        XCTAssertEqual(paragraphs[0].activeSegment(at: 1), 1)
        XCTAssertNil(paragraphs[0].activeSegment(at: 5))
    }

    func testPauseSeparatesParagraphsWithoutInventingSpeech() {
        let segments = [
            TranscriptionSegment(id: 0, start: 0, end: 1, text: "最初の話。"),
            TranscriptionSegment(id: 1, start: 4, end: 6, text: "次の話。")
        ]
        let paragraphs = TranscriptParagraph.make(from: segments)
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertNil(paragraphs[0].activeSegment(at: 2))
        XCTAssertNil(paragraphs[1].activeSegment(at: 2))
        XCTAssertEqual(paragraphs[1].activeSegment(at: 4), 0)
    }

    func testSentenceBoundaryBreaksLongPassage() {
        let segments = [
            TranscriptionSegment(id: 0, start: 0, end: 10, text: String(repeating: "説明", count: 60) + "。"),
            TranscriptionSegment(id: 1, start: 10, end: 20, text: "続きです。")
        ]
        XCTAssertEqual(TranscriptParagraph.make(from: segments).count, 2)
    }
}

import AVFoundation

@MainActor
final class TranscriptPlaybackTests: XCTestCase {
    func testPlaybackSeekPauseAndHighlightFollowAudioClock() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        samples.initialize(repeating: 0, count: Int(buffer.frameLength))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let player = AudioPlayer()
        defer { player.stop() }
        player.prepare(url: url)
        XCTAssertNil(player.errorMessage)
        let paragraph = try XCTUnwrap(TranscriptParagraph.make(from: [
            .init(id: 0, start: 0, end: 0.8, text: "最初。"),
            .init(id: 1, start: 0.8, end: 2, text: "続き。")
        ]).first)
        player.play()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(player.isPlaying)
        XCTAssertGreaterThan(player.currentTime, 0)
        XCTAssertEqual(paragraph.activeSegment(at: player.currentTime), 0)
        player.seek(to: 1)
        player.prepare(url: url) // The playback panel can reappear during scrolling.
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.currentTime, 1)
        XCTAssertEqual(paragraph.activeSegment(at: player.currentTime), 1)
        player.pause()
        let pausedTime = player.currentTime
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(player.currentTime, pausedTime)
        player.play(from: 0)
        XCTAssertEqual(paragraph.activeSegment(at: player.currentTime), 0)
        player.stop()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0)
    }
}
