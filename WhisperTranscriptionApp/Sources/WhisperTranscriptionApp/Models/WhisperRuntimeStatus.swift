import Foundation

@MainActor
final class WhisperRuntimeStatus: ObservableObject {
    static let shared = WhisperRuntimeStatus()

    @Published private(set) var isLoadingModel = false
    @Published private(set) var accelerationMode: WhisperAccelerationMode = .metal(reason: .encoderMissing)

    private init() {}

    func applySnapshot(isLoadingModel: Bool, accelerationMode: WhisperAccelerationMode) {
        self.isLoadingModel = isLoadingModel
        self.accelerationMode = accelerationMode
    }
}
