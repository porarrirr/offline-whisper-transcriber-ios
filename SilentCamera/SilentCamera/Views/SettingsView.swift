import SwiftUI

struct SettingsView: View {

    @Bindable var viewModel: CameraViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("解像度設定") {
                    ForEach(CaptureQuality.allCases) { quality in
                        Button {
                            viewModel.updateCaptureQuality(quality)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(quality.label)
                                        .foregroundStyle(.primary)
                                    Text(qualityDescription(quality))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if viewModel.settings.captureQuality == quality {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: viewModel.settings.processingMode.icon)
                                .foregroundStyle(.yellow)
                            Text("画像処理モード")
                                .font(.headline)
                        }

                        Text(viewModel.settings.processingMode.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(ProcessingMode.allCases) { mode in
                            Button {
                                viewModel.settings.processingMode = mode
                            } label: {
                                HStack {
                                    Image(systemName: mode.icon)
                                        .frame(width: 24)
                                        .foregroundStyle(viewModel.settings.processingMode == mode ? .yellow : .secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(mode.label)
                                            .foregroundStyle(.primary)
                                        Text(mode.description)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if viewModel.settings.processingMode == mode {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.yellow)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("画像処理")
                } footer: {
                    Text("スタック合成: 複数フレームを重ね合わせてノイズを低減し、画質を向上させます")
                }

                if viewModel.settings.processingMode != .none {
                    Section("処理パラメータ") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("処理強度")
                                Spacer()
                                Text(String(format: "%.0f%%", viewModel.settings.processingIntensity * 100))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }

                            Slider(value: $viewModel.settings.processingIntensity, in: Constants.Processing.minProcessingIntensity...Constants.Processing.maxProcessingIntensity, step: Constants.Processing.processingIntensityStep)
                                .tint(.yellow)
                        }
                        .padding(.vertical, 4)

                        if viewModel.settings.processingMode == .stack || viewModel.settings.processingMode == .denoise {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("フレーム数")
                                    Spacer()
                                    Text("\(viewModel.settings.frameCount)枚")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }

                                Slider(value: Binding(
                                    get: { Float(viewModel.settings.frameCount) },
                                    set: { viewModel.settings.frameCount = Int($0) }
                                ), in: Float(Constants.Processing.minFrameCount)...Float(Constants.Processing.maxFrameCount), step: Float(Constants.Processing.frameCountStep))
                                    .tint(.yellow)

                                Text("多いほどノイズ低減効果が高くなりますが、処理時間が長くなります")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("フラッシュ・ライト") {
                    ForEach(FlashMode.allCases) { mode in
                        Button {
                            viewModel.settings.flashMode = mode
                        } label: {
                            HStack {
                                Image(systemName: mode.icon)
                                    .frame(width: 24)

                                Text(mode.label)
                                    .foregroundStyle(.primary)

                                Spacer()

                                if viewModel.settings.flashMode == mode {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }

                Section("グリッド") {
                    Toggle(isOn: $viewModel.settings.showGrid) {
                        Label("三分割グリッドを表示", systemImage: "grid")
                    }
                }

                Section("情報") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("無音カメラ")
                            .font(.headline)
                        Text("シャッター音を無効にして写真・動画を撮影するアプリです。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("ビデオフレームキャプチャ方式により、確実に無音で撮影します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func qualityDescription(_ quality: CaptureQuality) -> String {
        switch quality {
        case .hd4k:
            return "3840x2160 - 最高画質"
        case .hd1080p:
            return "1920x1080 - 高画質（推奨）"
        case .hd720p:
            return "1280x720 - 標準画質"
        }
    }
}
