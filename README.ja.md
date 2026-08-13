# Offline Whisper Transcriber for iOS

[English](README.md) | 日本語

録音した音声や読み込んだファイルを、端末上で動くWhisperによって文字起こしするiPhoneアプリです。使用するモデルをダウンロードした後は、音声を文字起こしサーバーへ送らずに処理できます。

## 主な機能

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) を使ったオンデバイス文字起こし
- 録音後すぐに文字起こし
- M4A、WAV、MP3、MP4、MOVの読み込み
- 日本語を含む約20言語に対応
- 無音を省くVoice Activity Detection
- 検索できる履歴、お気に入り、Siriショートカット
- 容量・速度・精度のバランスを選べる複数のWhisperモデル

## プライバシー

モデルのダウンロード後、文字起こしは端末内で実行されます。音声をプロジェクト独自の文字起こしサービスへアップロードする必要はありません。モデルの取得や、ユーザーが選んだ外部ファイルの読み込みには、それぞれのネットワーク・ファイル提供元を利用します。

## 必要環境

- iOS 17以降。Whisperの利用は実機を推奨
- 開発にはmacOS 14以降とXcode 15以降
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## ビルド

```bash
git clone --recursive https://github.com/porarrirr/offline-whisper-transcriber-ios.git
cd offline-whisper-transcriber-ios/WhisperTranscriptionApp
cd whisper.cpp && ./build-xcframework.sh && cd ..
cp -R whisper.cpp/build-apple/whisper.xcframework Frameworks/
./Scripts/sign-whisper-xcframework.sh
xcodegen generate
open WhisperTranscriptionApp.xcodeproj
```

より詳しいセットアップは [`WhisperTranscriptionApp/README.md`](WhisperTranscriptionApp/README.md) を参照してください。

## ライセンス

アプリのソースコードは [MIT License](LICENSE) で公開しています。サブモジュールと第三者依存関係には、それぞれのライセンスが適用されます。
