# Offline Whisper Transcriber for iOS

iPhone上で完全オフライン動作するAI音声文字起こしアプリ。OpenAI Whisperモデル ([whisper.cpp](https://github.com/ggerganov/whisper.cpp)) をオンデバイスで実行し、音声ファイル・リアルタイム録音から高精度な文字起こしを行います。

> 詳細なセットアップ手順は [WhisperTranscriptionApp/README.md](WhisperTranscriptionApp/README.md) を参照してください。

## 主な特徴

- **完全オフライン** — モデルダウンロード後はインターネット不要。すべての推論がデバイス上で完結
- **リアルタイム録音 & 文字起こし** — 録音完了後すぐにテキスト化
- **ファイルインポート対応** — m4a / wav / mp3 / mp4 / mov から文字起こし
- **マルチ言語** — 日本語を含む約20言語に対応
- **VAD（Voice Activity Detection）** — 無音区間を自動スキップ
- **履歴管理** — SwiftDataで永続化、検索・お気に入り・Siriショートカット対応
- **ダークモード UI** — SwiftUIによる洗練されたダークテーマ

## 技術スタック

| レイヤー | 技術 |
|----------|------|
| 言語 | Swift 5.9 |
| UI | SwiftUI |
| 永続化 | SwiftData, UserDefaults |
| 音声処理 | AVFoundation |
| Whisperエンジン | whisper.cpp (C/C++) + Metal GPUアクセラレーション |
| プロジェクト生成 | XcodeGen |
| CI/CD | GitHub Actions (macOS 15, タグプッシュでunsigned IPAビルド) |

## 必要環境

- macOS 14.0 Sonoma 以降
- Xcode 15.0 以降
- iOS 17.0 以降の実機（Simulator非対応）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）

## クイックスタート

```bash
# サブモジュール込みでクローン
git clone --recursive https://github.com/porarrirr/offline-whisper-transcriber-ios.git
cd offline-whisper-transcriber-ios/WhisperTranscriptionApp

# whisper.xcframework のビルド（初回のみ・必要に応じて）
cd whisper.cpp && ./build-xcframework.sh && cd ..

# Xcodeプロジェクト生成 & ビルド
xcodegen generate
open WhisperTranscriptionApp.xcodeproj
```

## プロジェクト構成

```
dff/
├── README.md
├── AGENTS.md
├── .github/workflows/          # CI/CD（unsigned IPA ビルド）
├── WhisperTranscriptionApp/
│   ├── README.md               # 詳細セットアップ手順
│   ├── Package.swift
│   ├── project.yml             # XcodeGen 設定
│   ├── Info.plist
│   ├── Frameworks/whisper.xcframework
│   ├── whisper.cpp/            # Git Submodule
│   └── Sources/WhisperTranscriptionApp/
│       ├── App/                # エントリポイント
│       ├── Models/             # Whisperラッパー・音声処理
│       ├── ViewModels/         # 状態管理
│       ├── Views/              # SwiftUI ビュー
│       ├── AppIntents/         # Siri/Shortcuts 対応
│       └── DesignSystem/       # カラー・フォント
```

## モデルサイズ比較

| モデル | ファイル名 | サイズ | 精度 |
|--------|-----------|--------|------|
| Tiny | `ggml-tiny.bin` | ~39MB | 低 |
| Base | `ggml-base.bin` | ~142MB | 中（デフォルト） |
| Small | `ggml-small.bin` | ~466MB | 高 |
| Large v3 Turbo | `ggml-large-v3-turbo.bin` | ~874MB | 最高 |

## ライセンス

本アプリのソースコードは MIT ライセンスです。whisper.cpp は各ライセンスに従います。
