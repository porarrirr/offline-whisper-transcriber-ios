import SwiftUI
import UIKit

/// フィールドレコーダー基調のデザイントークン。
/// ダーク: ほぼ黒の筐体 + アンバー。ライト: 明るい計器パネル + アンバー。
/// LCDディスプレイ(`display`系)は両モードとも常に暗い画面で、実機レコーダーの表示部を模す。
enum Theme {
    // MARK: - Chassis (adaptive)

    /// 画面全体の背景(筐体)
    static let background = adaptive(light: 0xE9EAE6, dark: 0x0B0C0E)
    /// パネル(カード)面
    static let panel = adaptive(light: 0xF7F7F4, dark: 0x17191D)
    /// パネルより一段沈んだ面(ボタン溝、チップ背景など)
    static let panelInset = adaptive(light: 0xE0E1DC, dark: 0x101216)
    /// パネル境界のヘアライン
    static let stroke = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.09)
            : UIColor.black.withAlphaComponent(0.12)
    })

    static let textPrimary = adaptive(light: 0x1B1C1E, dark: 0xF2F2F0)
    static let textSecondary = adaptive(light: 0x5D6165, dark: 0x9BA0A6)

    // MARK: - Accents

    /// アンバーの塗り(ボタン等)。両モード共通。
    static let amberFill = Color(hex: 0xFFAD1F)
    /// アンバー塗りの上に載せる文字色
    static let onAmber = Color(hex: 0x1A1200)
    /// テキスト・アイコンとしてのアンバー(ライトでは暗めにして可読性を確保)
    static let amber = adaptive(light: 0xA96A00, dark: 0xFFB020)
    /// 録音中の赤
    static let rec = adaptive(light: 0xD73327, dark: 0xFF4A3D)
    /// 警告表示の背景
    static let warningWash = adaptive(light: 0xF7E9D4, dark: 0x2A1F10)

    // MARK: - LCD display (always dark)

    /// LCD画面の背景。ライトモードでも常に暗い。
    static let display = Color(hex: 0x101113)
    static let displayStroke = Color.white.opacity(0.08)
    /// LCD上の主要表示(アンバー発光)
    static let displayAmber = Color(hex: 0xFFB020)
    /// LCD上の弱い表示
    static let displayDim = Color(hex: 0xFFB020).opacity(0.38)
    /// LCD上の白系テキスト
    static let displayText = Color(hex: 0xEDEDE8)
    static let displayTextDim = Color(hex: 0xEDEDE8).opacity(0.55)

    // MARK: - Fonts

    /// 計器の数値・タイムコード用モノスペース
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// 見出し・本文(標準サンセリフ)
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // MARK: - Helpers

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
