import SwiftUI

// MARK: - Panels

/// 筐体パネル。カード相当の基本面。
struct RecorderPanelModifier: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            }
    }
}

/// LCDディスプレイ面。両モードとも常に暗い。
struct DisplayPanelModifier: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.display)
                    .overlay {
                        LinearGradient(
                            colors: [Color.white.opacity(0.05), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.displayStroke, lineWidth: 1)
            }
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func recorderPanel(padding: CGFloat = 16) -> some View {
        modifier(RecorderPanelModifier(padding: padding))
    }

    func displayPanel(padding: CGFloat = 16) -> some View {
        modifier(DisplayPanelModifier(padding: padding))
    }
}

// MARK: - Labels

/// 機材の刻印風ラベル(モノスペース・大文字・字間広め)
struct TechLabel: View {
    let text: LocalizedStringKey
    var color: Color = Theme.textSecondary

    var body: some View {
        Text(text)
            .font(Theme.mono(11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(1.6)
            .foregroundStyle(color)
    }
}

/// LEDインジケーター
struct LEDDot: View {
    let isOn: Bool
    var onColor: Color = Theme.rec

    var body: some View {
        Circle()
            .fill(isOn ? onColor : Theme.panelInset)
            .frame(width: 9, height: 9)
            .overlay {
                Circle().strokeBorder(Theme.stroke, lineWidth: 1)
            }
            .shadow(color: isOn ? onColor.opacity(0.8) : .clear, radius: 4)
    }
}

// MARK: - Buttons

/// アンバーの主ボタン
struct RecorderProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(15, weight: .semibold))
            .foregroundStyle(Theme.onAmber)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.amberFill)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

/// 溝に沈んだ副ボタン
struct RecorderQuietButtonStyle: ButtonStyle {
    var role: ButtonRole?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(15, weight: .medium))
            .foregroundStyle(role == .destructive ? Theme.rec : Theme.textPrimary)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(Theme.panelInset)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
}

extension ButtonStyle where Self == RecorderProminentButtonStyle {
    static var recorderProminent: RecorderProminentButtonStyle { RecorderProminentButtonStyle() }
}

extension ButtonStyle where Self == RecorderQuietButtonStyle {
    static var recorderQuiet: RecorderQuietButtonStyle { RecorderQuietButtonStyle() }
    static var recorderQuietDestructive: RecorderQuietButtonStyle { RecorderQuietButtonStyle(role: .destructive) }
}

// MARK: - Rows

/// 入力ソース選択などの行(パネル内の1行)
struct RecorderActionRow: View {
    let icon: String
    let title: Text
    let subtitle: Text?

    init(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey?) {
        self.icon = icon
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
    }

    init(icon: String, title: Text, subtitle: Text?) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.amber)
                .frame(width: 34, height: 34)
                .background(Theme.panelInset)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(Theme.sans(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    subtitle
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Warning strip

/// エラー・警告の帯
struct WarningStrip: View {
    let message: String
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                    .padding(.top, 1)

                Text(message)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(Theme.mono(13, weight: .semibold))
                }
                .buttonStyle(.recorderQuiet)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warningWash)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.amber.opacity(0.35), lineWidth: 1)
        }
    }
}

// MARK: - Timecode

/// HH:MM:SS表示
func formatTimecode(_ time: TimeInterval) -> String {
    let total = Int(time)
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}
