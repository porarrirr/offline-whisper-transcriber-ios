import SwiftUI
import UIKit

private enum SpeechAssetSheetDestination: Identifiable {
    case diagnostics(String)
    case management
    case replacement(target: AppleSpeechLocale)

    var id: String {
        switch self {
        case .diagnostics: return "diagnostics"
        case .management: return "management"
        case .replacement: return "replacement"
        }
    }
}

struct SpeechAssetStatusCard: View {
    @ObservedObject var modelManager: ModelManager
    var showsManagementAction = true
    @State private var presentedSheet: SpeechAssetSheetDestination?

    private var snapshot: SpeechAssetSnapshot { modelManager.speechAssetSnapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                LEDDot(
                    isOn: true,
                    onColor: snapshot.isInstalled ? Theme.amber : stateColor
                )
                Text(snapshot.statusTitle)
                    .font(Theme.sans(15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .accessibilityIdentifier("speechAssetStatusTitle")
                Spacer()
                if let progress = snapshot.measuredProgress {
                    Text("\(Int(progress * 100))%")
                        .font(Theme.mono(14, weight: .semibold))
                        .foregroundColor(Theme.amber)
                }
            }

            if let progress = snapshot.measuredProgress {
                ProgressBar(progress: progress)
                    .frame(height: 6)
                    .accessibilityIdentifier("speechAssetDeterminateProgress")
            } else if showsIndeterminateProgress {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Theme.amber)
                    .accessibilityIdentifier("speechAssetIndeterminateProgress")
            }

            Text(snapshot.statusDetail)
                .font(Theme.sans(12))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("speechAssetStatusDetail")

            if shouldShowNetworkSupplement {
                Label(networkSupplement, systemImage: "network")
                    .font(Theme.sans(11))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actionButtons
        }
        .recorderPanel(padding: 14)
        .task {
            modelManager.refreshSpeechAssetStatus()
        }
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .diagnostics(let report):
                SpeechAssetDiagnosticView(report: report)
            case .management:
                NavigationStack {
                    SpeechAssetManagementView(modelManager: modelManager)
                }
            case .replacement(let target):
                NavigationStack {
                    SpeechReservationReplacementView(targetLocale: target, modelManager: modelManager)
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 10) {
            ForEach(snapshot.userActions(isModelReady: modelManager.isModelReady), id: \.self) { action in
                actionButton(for: action)
            }

            Spacer(minLength: 0)

            if showsDiagnosticsAction {
                Button {
                    presentedSheet = .diagnostics(modelManager.speechAssetDiagnosticReport())
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Diagnostics")
            }
        }
        .font(Theme.sans(12, weight: .semibold))
    }

    @ViewBuilder
    private func actionButton(for action: SpeechAssetUserAction) -> some View {
        switch action {
        case .prepare:
            Button("Use This Language") { modelManager.downloadModel() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("speechAssetPrimaryAction")
        case .retry:
            Button("Retry") { modelManager.retrySpeechAssetPreparation() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("speechAssetPrimaryAction")
        case .resume:
            Button("Resume Preparation") { modelManager.retrySpeechAssetPreparation() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("speechAssetPrimaryAction")
        case .startOver:
            Button("Start Over") { modelManager.retrySpeechAssetPreparation() }
                .buttonStyle(.bordered)
        case .cancel:
            Button("Cancel") { modelManager.cancelDownload() }
                .buttonStyle(.bordered)
                .tint(Theme.rec)
        case .replaceLanguage:
            if showsManagementAction {
                Button("Replace a Language") { presentedSheet = .management }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("speechAssetPrimaryAction")
            }
        }
    }

    private var showsIndeterminateProgress: Bool {
        switch snapshot.state {
        case .checking, .reserving, .systemManagedPending, .verifying:
            return snapshot.isOperationActive || snapshot.inventoryStatus == .downloading
        default:
            return false
        }
    }

    private var showsDiagnosticsAction: Bool {
        switch snapshot.state {
        case .systemManagedPending, .verifying, .offline, .constrainedNetwork,
             .reservationLimitReached, .insufficientStorage, .cancelled, .failed:
            return true
        default:
            return snapshot.hasExtendedWait
        }
    }

    private var shouldShowNetworkSupplement: Bool {
        switch snapshot.state {
        case .systemManagedPending, .offline, .constrainedNetwork:
            return true
        default:
            return false
        }
    }

    private var networkSupplement: String {
        let interfaces = snapshot.network.interfaces.isEmpty
            ? String(localized: "unknown connection")
            : snapshot.network.interfaces.joined(separator: ", ")
        return String(
            format: String(localized: "Current app network path: %@. This does not reveal the Speech model waiting reason."),
            interfaces
        )
    }

    private var stateColor: Color {
        switch snapshot.state {
        case .failed, .insufficientStorage, .unsupported, .reservationLimitReached:
            return Theme.rec
        default:
            return Theme.amber
        }
    }
}

struct SpeechAssetManagementView: View {
    @ObservedObject var modelManager: ModelManager
    @State private var searchText = ""
    @State private var presentedSheet: SpeechAssetSheetDestination?
    @State private var releaseCandidate: SpeechLocaleRecord?

    private var snapshot: SpeechAssetSnapshot { modelManager.speechAssetSnapshot }
    private var reservedCount: Int { snapshot.localeRecords.filter(\.isReserved).count }

    private var matchingRecords: [SpeechLocaleRecord] {
        let records: [SpeechLocaleRecord]
        if searchText.isEmpty {
            records = snapshot.localeRecords
        } else {
            records = snapshot.localeRecords.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.localeIdentifier.localizedCaseInsensitiveContains(searchText)
            }
        }
        return records.sorted(by: alphabeticalOrder)
    }

    private var retainedRecords: [SpeechLocaleRecord] {
        matchingRecords.filter(\.isReserved)
    }

    private var otherRecords: [SpeechLocaleRecord] {
        matchingRecords.filter { !$0.isReserved }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Languages Available to This App")
                    Spacer()
                    Text("\(reservedCount) / \(snapshot.maximumReservedLocales)")
                        .font(Theme.mono(14, weight: .semibold))
                        .foregroundColor(Theme.amber)
                        .accessibilityIdentifier("speechReservationCount")
                }

                SpeechAssetStatusCard(modelManager: modelManager, showsManagementAction: false)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                Text("Languages in this section are ready for this app. iOS manages the model files.")
            }

            if matchingRecords.isEmpty {
                Section {
                    Text("No SpeechTranscriber languages are available on this device.")
                        .foregroundColor(Theme.textSecondary)
                }
            }

            if !retainedRecords.isEmpty {
                Section("Languages Available to This App") {
                    localeRows(retainedRecords)
                }
            }

            if !otherRecords.isEmpty {
                Section("Other Languages") {
                    localeRows(otherRecords)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search Languages")
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("iOS SpeechTranscriber Models")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("iOS SpeechTranscriber Models")
                    .font(Theme.sans(14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    presentedSheet = .diagnostics(modelManager.speechAssetDiagnosticReport())
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Diagnostics")
            }
        }
        .task {
            modelManager.refreshSpeechAssetStatus()
        }
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .diagnostics(let report):
                SpeechAssetDiagnosticView(report: report)
            case .replacement(let target):
                NavigationStack {
                    SpeechReservationReplacementView(targetLocale: target, modelManager: modelManager)
                }
            case .management:
                EmptyView()
            }
        }
        .alert(item: $releaseCandidate) { record in
            Alert(
                title: Text("Remove Language from This App"),
                message: Text(record.isSelected
                    ? LocalizedStringKey("This language is currently selected. It will remain selected but cannot be used until it is prepared again. iOS manages the model file.")
                    : LocalizedStringKey("This language will no longer be available to this app. iOS manages the model file.")),
                primaryButton: .destructive(Text("Remove from This App")) {
                    Task { _ = await modelManager.releaseSpeechAssetReservation(record.reservedLocaleIdentifier ?? "") }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func isActiveOperation(_ record: SpeechLocaleRecord) -> Bool {
        guard snapshot.isOperationActive,
              let active = snapshot.normalizedLocaleIdentifier ?? snapshot.requestedLocaleIdentifier else { return false }
        return SpeechAssetLocaleIdentifier.canonical(active)
            == SpeechAssetLocaleIdentifier.canonical(record.localeIdentifier)
    }

    @ViewBuilder
    private func localeRows(_ records: [SpeechLocaleRecord]) -> some View {
        ForEach(records) { record in
            SpeechLocaleManagementRow(
                record: record,
                isActiveOperation: isActiveOperation(record),
                mutationsDisabled: modelManager.isTranscriptionInProgress || snapshot.isOperationActive,
                onUse: { use(record) },
                onRelease: { releaseCandidate = record }
            )
        }
    }

    private func use(_ record: SpeechLocaleRecord) {
        if !record.isReserved,
           snapshot.maximumReservedLocales > 0,
           reservedCount >= snapshot.maximumReservedLocales {
            presentedSheet = .replacement(target: record.locale)
            return
        }
        modelManager.useSpeechAsset(locale: record.locale)
    }

    private func alphabeticalOrder(_ lhs: SpeechLocaleRecord, _ rhs: SpeechLocaleRecord) -> Bool {
        let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if comparison == .orderedSame {
            return lhs.localeIdentifier.localizedCaseInsensitiveCompare(rhs.localeIdentifier) == .orderedAscending
        }
        return comparison == .orderedAscending
    }
}

private struct SpeechLocaleManagementRow: View {
    let record: SpeechLocaleRecord
    let isActiveOperation: Bool
    let mutationsDisabled: Bool
    let onUse: () -> Void
    let onRelease: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.displayName)
                        .foregroundColor(Theme.textPrimary)
                    Text(record.localeIdentifier.replacingOccurrences(of: "_", with: "-"))
                        .font(Theme.mono(11))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                if record.isSelected {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .font(Theme.sans(11, weight: .semibold))
                        .foregroundColor(Theme.amber)
                }
            }

            HStack(spacing: 8) {
                statusBadge
                if isActiveOperation {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.amber)
                }
            }

            HStack(spacing: 12) {
                if !record.isSelected || !record.isInstalled || !record.isReserved {
                    Button("Use This Language") { onUse() }
                        .buttonStyle(.borderedProminent)
                }
                if record.isReserved {
                    Button("Remove from This App", role: .destructive) { onRelease() }
                        .buttonStyle(.bordered)
                }
            }
            .font(Theme.sans(12, weight: .semibold))
            .disabled(mutationsDisabled || isActiveOperation)
        }
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        let isReady = record.isInstalled && record.isReserved
        let text: LocalizedStringKey = isActiveOperation
            ? "Preparing"
            : (isReady ? "Ready to Use" : "Preparation Required")
        return Text(text)
            .font(Theme.sans(10, weight: .semibold))
            .foregroundColor(isReady || isActiveOperation ? Theme.amber : Theme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background((isReady || isActiveOperation ? Theme.amber : Theme.textSecondary).opacity(0.12))
            .clipShape(Capsule())
    }
}

private struct SpeechReservationReplacementView: View {
    let targetLocale: AppleSpeechLocale
    @ObservedObject var modelManager: ModelManager
    @Environment(\.dismiss) private var dismiss
    @State private var isReplacing = false

    private var reservedRecords: [SpeechLocaleRecord] {
        modelManager.speechAssetSnapshot.localeRecords.filter(\.isReserved)
    }

    var body: some View {
        List {
            Section {
                Text(
                    String(
                        format: String(localized: "To use %@, choose one language to remove from this app."),
                        targetLocale.localizedLocaleName
                    )
                )
                .font(Theme.sans(13))
                .foregroundColor(Theme.textSecondary)
            }

            Section("Languages Available to This App") {
                ForEach(reservedRecords) { record in
                    Button {
                        replace(record)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.displayName)
                                    .foregroundColor(Theme.textPrimary)
                                if record.isSelected {
                                    Text("Selected")
                                        .font(Theme.sans(11))
                                        .foregroundColor(Theme.amber)
                                }
                                Text(
                                    String(
                                        format: String(localized: "Remove %@ and prepare %@"),
                                        record.displayName,
                                        targetLocale.localizedLocaleName
                                    )
                                )
                                .font(Theme.sans(11))
                                .foregroundColor(Theme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(Theme.rec)
                        }
                    }
                    .disabled(isReplacing)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Replace a Language")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func replace(_ record: SpeechLocaleRecord) {
        guard let identifier = record.reservedLocaleIdentifier else { return }
        isReplacing = true
        Task {
            let replaced = await modelManager.replaceSpeechAssetReservation(
                releasing: identifier,
                with: targetLocale
            )
            isReplacing = false
            if replaced { dismiss() }
        }
    }
}

struct SpeechAssetDiagnosticView: View {
    let report: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Review the technical information below before copying it. It contains no audio or transcription text.")
                        .font(Theme.sans(13))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(report)
                        .font(Theme.mono(11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(14)
                        .background(Theme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        UIPasteboard.general.string = report
                        copied = true
                    } label: {
                        Label {
                            Text(copied ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy Diagnostics"))
                        } icon: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.amber)
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Speech Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
