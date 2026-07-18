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
        let state = snapshot.state
        HStack(spacing: 10) {
            switch state {
            case .checking:
                if snapshot.inventoryStatus == .supported {
                    Button("Prepare") { modelManager.downloadModel() }
                        .buttonStyle(.borderedProminent)
                }
                Button("Recheck") { modelManager.recheckSpeechAssets() }
                    .buttonStyle(.bordered)
            case .reserving, .downloading:
                Button("Cancel") { modelManager.cancelDownload() }
                    .buttonStyle(.bordered)
                    .tint(Theme.rec)
            case .systemManagedPending:
                Button("Recheck") { modelManager.recheckSpeechAssets() }
                    .buttonStyle(.bordered)
                Button("Retry") { modelManager.retrySpeechAssetPreparation() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") { modelManager.cancelDownload() }
                    .buttonStyle(.bordered)
                    .tint(Theme.rec)
            case .verifying, .offline, .constrainedNetwork:
                Button("Recheck") { modelManager.recheckSpeechAssets() }
                    .buttonStyle(.bordered)
                Button("Retry") { modelManager.retrySpeechAssetPreparation() }
                    .buttonStyle(.borderedProminent)
                if snapshot.isOperationActive {
                    Button("Cancel") { modelManager.cancelDownload() }
                        .buttonStyle(.bordered)
                        .tint(Theme.rec)
                }
            case .reservationLimitReached:
                if showsManagementAction {
                    Button("Manage Languages") { presentedSheet = .management }
                        .buttonStyle(.borderedProminent)
                }
            case .insufficientStorage, .cancelled, .failed:
                Button("Recheck") { modelManager.recheckSpeechAssets() }
                    .buttonStyle(.bordered)
                Button("Retry") { modelManager.retrySpeechAssetPreparation() }
                    .buttonStyle(.borderedProminent)
            case .installed:
                if !modelManager.isModelReady {
                    Button("Retain for This App") { modelManager.downloadModel() }
                        .buttonStyle(.borderedProminent)
                }
            case .unsupported:
                EmptyView()
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

    private var filteredRecords: [SpeechLocaleRecord] {
        guard !searchText.isEmpty else { return snapshot.localeRecords }
        return snapshot.localeRecords.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.localeIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Retained languages")
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
                Text("A reservation keeps a language available to this app. Releasing it does not immediately delete the system-managed model.")
            }

            Section("Available Languages") {
                if filteredRecords.isEmpty {
                    Text("No SpeechTranscriber languages are available on this device.")
                        .foregroundColor(Theme.textSecondary)
                } else {
                    ForEach(filteredRecords) { record in
                        SpeechLocaleManagementRow(
                            record: record,
                            isActiveOperation: isActiveOperation(record),
                            mutationsDisabled: modelManager.isTranscriptionInProgress || snapshot.isOperationActive,
                            onSelect: { select(record) },
                            onPrepare: { prepare(record) },
                            onRelease: { releaseCandidate = record }
                        )
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search Languages")
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Speech Models")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
            modelManager.recheckSpeechAssets()
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
                title: Text("Release Language Reservation"),
                message: Text(record.isSelected
                    ? LocalizedStringKey("This is the selected language. It will remain selected but transcription will be unavailable until it is prepared again. The model file may remain on the device because iOS manages deletion.")
                    : LocalizedStringKey("This removes the language reservation for this app. The model file may remain on the device because iOS manages deletion.")),
                primaryButton: .destructive(Text("Release")) {
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

    private func select(_ record: SpeechLocaleRecord) {
        modelManager.switchModel(model: .appleSpeech(record.locale))
    }

    private func prepare(_ record: SpeechLocaleRecord) {
        if !record.isReserved, reservedCount >= snapshot.maximumReservedLocales {
            presentedSheet = .replacement(target: record.locale)
            return
        }
        modelManager.prepareSpeechAsset(locale: record.locale)
    }
}

private struct SpeechLocaleManagementRow: View {
    let record: SpeechLocaleRecord
    let isActiveOperation: Bool
    let mutationsDisabled: Bool
    let onSelect: () -> Void
    let onPrepare: () -> Void
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
                statusBadge(record.isInstalled ? "Downloaded" : "Not Downloaded", active: record.isInstalled)
                statusBadge(record.isReserved ? "Retained" : "Not Retained", active: record.isReserved)
                if isActiveOperation {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.amber)
                }
            }

            HStack(spacing: 12) {
                if !record.isSelected {
                    Button("Use") { onSelect() }
                        .buttonStyle(.bordered)
                }
                if !record.isInstalled || !record.isReserved {
                    Button("Add / Prepare") { onPrepare() }
                        .buttonStyle(.borderedProminent)
                }
                if record.isReserved {
                    Button("Release", role: .destructive) { onRelease() }
                        .buttonStyle(.bordered)
                }
            }
            .font(Theme.sans(12, weight: .semibold))
            .disabled(mutationsDisabled || isActiveOperation)
        }
        .padding(.vertical, 4)
    }

    private func statusBadge(_ text: LocalizedStringKey, active: Bool) -> some View {
        Text(text)
            .font(Theme.sans(10, weight: .semibold))
            .foregroundColor(active ? Theme.amber : Theme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background((active ? Theme.amber : Theme.textSecondary).opacity(0.12))
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
                        format: String(localized: "To add %@, choose one retained language to release."),
                        targetLocale.localizedLocaleName
                    )
                )
                .font(Theme.sans(13))
                .foregroundColor(Theme.textSecondary)
            }

            Section("Retained Languages") {
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
        .navigationTitle("Replace Language")
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
