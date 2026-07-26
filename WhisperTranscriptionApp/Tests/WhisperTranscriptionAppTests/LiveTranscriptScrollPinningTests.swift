import CoreGraphics
import XCTest
@testable import WhisperTranscriptionApp

/// ライブ文字起こしパネルの自動追従は「最下部に張り付いているか」の一点で決まる。
/// `ScrollGeometry`を組み立てずに判定できるよう切り出した関数の真理値表。
final class LiveTranscriptScrollPinningTests: XCTestCase {
    private let containerHeight: CGFloat = 180
    private let contentHeight: CGFloat = 1000

    /// 最下部までのオフセット(1000 - 180 = 820)
    private var maxOffset: CGFloat { contentHeight - containerHeight }

    func testShorterContentThanContainerIsAtBottom() {
        XCTAssertTrue(
            LiveTranscriptScrollPinning.isAtBottom(
                contentOffsetY: 0,
                contentHeight: 40,
                containerHeight: containerHeight
            )
        )
    }

    func testExactBottomIsAtBottom() {
        XCTAssertTrue(
            LiveTranscriptScrollPinning.isAtBottom(
                contentOffsetY: maxOffset,
                contentHeight: contentHeight,
                containerHeight: containerHeight
            )
        )
    }

    func testWithinThresholdIsAtBottom() {
        XCTAssertTrue(
            LiveTranscriptScrollPinning.isAtBottom(
                contentOffsetY: maxOffset - 10,
                contentHeight: contentHeight,
                containerHeight: containerHeight
            )
        )
    }

    func testJustOutsideThresholdIsNotAtBottom() {
        XCTAssertFalse(
            LiveTranscriptScrollPinning.isAtBottom(
                contentOffsetY: maxOffset - (LiveTranscriptScrollPinning.bottomThreshold + 1),
                contentHeight: contentHeight,
                containerHeight: containerHeight
            )
        )
    }

    func testScrolledWellAboveBottomIsNotAtBottom() {
        XCTAssertFalse(
            LiveTranscriptScrollPinning.isAtBottom(
                contentOffsetY: maxOffset - 100,
                contentHeight: contentHeight,
                containerHeight: containerHeight
            )
        )
    }

    func testTopOfLongContentIsNotAtBottom() {
        XCTAssertFalse(
            LiveTranscriptScrollPinning.isAtBottom(
                contentOffsetY: 0,
                contentHeight: contentHeight,
                containerHeight: containerHeight
            )
        )
    }

    /// ゴム紙的に最下部を超えて引っ張られた状態でも追従は維持する。
    func testOverscrollBeyondBottomIsAtBottom() {
        XCTAssertTrue(
            LiveTranscriptScrollPinning.isAtBottom(
                contentOffsetY: maxOffset + 60,
                contentHeight: contentHeight,
                containerHeight: containerHeight
            )
        )
    }

    func testBottomInsetShiftsBottomOffset() {
        let bottomInset: CGFloat = 50
        let insetMaxOffset = contentHeight + bottomInset - containerHeight

        XCTAssertTrue(
            LiveTranscriptScrollPinning.isAtBottom(
                contentOffsetY: insetMaxOffset,
                contentHeight: contentHeight,
                containerHeight: containerHeight,
                bottomInset: bottomInset
            )
        )
        // インセット分を無視すると最下部と誤判定してしまう位置。
        XCTAssertFalse(
            LiveTranscriptScrollPinning.isAtBottom(
                contentOffsetY: maxOffset,
                contentHeight: contentHeight,
                containerHeight: containerHeight,
                bottomInset: bottomInset
            )
        )
    }

    /// コンテンツが短いときの最上部オフセットは`-topInset`なので、そこが最下部でもある。
    func testShortContentWithTopInsetIsAtBottom() {
        XCTAssertTrue(
            LiveTranscriptScrollPinning.isAtBottom(
                contentOffsetY: -30,
                contentHeight: 40,
                containerHeight: containerHeight,
                topInset: 30
            )
        )
    }
}
