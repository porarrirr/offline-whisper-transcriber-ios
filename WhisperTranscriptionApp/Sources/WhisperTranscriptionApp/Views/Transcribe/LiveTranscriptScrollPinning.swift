import CoreGraphics

/// ライブ文字起こしパネルが「最下部に張り付いているか」の判定。
/// `ScrollGeometry`はiOS 18+の型なので、単体テストできるよう`CGFloat`だけを受け取る。
enum LiveTranscriptScrollPinning {
    /// ゴム紙的なオーバースクロールやレイアウトの端数を吸収する許容幅。
    static let bottomThreshold: CGFloat = 24

    static func isAtBottom(
        contentOffsetY: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0,
        threshold: CGFloat = bottomThreshold
    ) -> Bool {
        // コンテンツがコンテナより短いときは最上部の`-topInset`が最下部でもある。
        let maxOffset = max(-topInset, contentHeight + bottomInset - containerHeight)
        return contentOffsetY >= maxOffset - threshold
    }
}
