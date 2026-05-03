import Foundation

enum CameraError: LocalizedError {
    case cameraNotFound
    case inputConfigurationFailed
    case outputConfigurationFailed
    case captureFailed
    case processingFailed
    case saveFailed
    case recordingFailed(String)
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .cameraNotFound:
            return "カメラが見つかりません"
        case .inputConfigurationFailed:
            return "カメラ入力の設定に失敗しました"
        case .outputConfigurationFailed:
            return "出力の設定に失敗しました"
        case .captureFailed:
            return "フレームのキャプチャに失敗しました"
        case .processingFailed:
            return "画像処理に失敗しました"
        case .saveFailed:
            return "写真ライブラリへの保存に失敗しました"
        case .recordingFailed(let detail):
            return "動画の保存に失敗しました: \(detail)"
        case .authorizationDenied:
            return "カメラへのアクセスが許可されていません"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .cameraNotFound:
            return "デバイスにカメラが搭載されているか確認してください。"
        case .inputConfigurationFailed:
            return "カメラの再起動をお試しください。"
        case .outputConfigurationFailed:
            return "アプリを再起動してください。"
        case .captureFailed:
            return "もう一度お試しください。"
        case .processingFailed:
            return "処理モードを変更してお試しください。"
        case .saveFailed:
            return "設定から写真ライブラリへのアクセスを許可してください。"
        case .recordingFailed:
            return "もう一度お試しください。"
        case .authorizationDenied:
            return "設定からカメラへのアクセスを許可してください。"
        }
    }
}
