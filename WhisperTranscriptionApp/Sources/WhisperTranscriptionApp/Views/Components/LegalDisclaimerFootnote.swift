import SwiftUI

struct LegalDisclaimerFootnote: View {
    var text: String = AppDisclaimer.shortFootnote

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(Theme.sans(11))
            .foregroundColor(Theme.textSecondary.opacity(0.8))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .fixedSize(horizontal: false, vertical: true)
    }
}
