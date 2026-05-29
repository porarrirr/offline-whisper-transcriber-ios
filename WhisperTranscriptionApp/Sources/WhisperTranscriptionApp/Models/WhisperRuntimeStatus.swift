import Foundation

@MainActor
final class WhisperRuntimeStatus: ObservableObject {
    static let shared = WhisperRuntimeStatus()

    @Published private(set) var isLoadingModel = false
    @Published private(set) var probeStateDescription = "pending"
    @Published private(set) var useCoreMLForSession = true

    private init() {}

    func applySnapshot(isLoadingModel: Bool, probeStateDescription: String, useCoreMLForSession: Bool) {
        self.isLoadingModel = isLoadingModel
        self.probeStateDescription = probeStateDescription
        self.useCoreMLForSession = useCoreMLForSession
    }
}
