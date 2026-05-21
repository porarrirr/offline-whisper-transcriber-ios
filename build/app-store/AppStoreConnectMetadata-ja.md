# App Store Connect メタデータ（日本語）

## 基本情報

| 項目 | 値 |
|------|-----|
| アプリ名（30文字以内） | Whisper文字起こし |
| サブタイトル（30文字以内） | オフラインAI音声文字起こし |
| バンドル ID | `com.porarrirr.offlinewhispertranscriber` |
| マーケティング URL | https://porarrirr.github.io/offline-whisper-transcriber-ios/ |
| サポート URL | https://porarrirr.github.io/offline-whisper-transcriber-ios/support.html |
| プライバシーポリシー URL | https://porarrirr.github.io/offline-whisper-transcriber-ios/privacy-policy.html |

## 説明文（4000文字以内）

Whisper文字起こしは、OpenAI Whisper モデルを iPhone 上で動かす音声文字起こしアプリです。

**できること**
- マイク録音の文字起こし
- 音声・動画ファイル（m4a / wav / mp3 / mp4 / mov など）のインポート
- 日本語を含む多言語対応
- 履歴の保存・検索・エクスポート

**オフラインについて**
初回起動時に Whisper モデル（約142MB、Base）をインターネットからダウンロードします。ダウンロード完了後は、文字起こし処理はすべて端末内で完結し、インターネット接続は不要です。

**必要環境**
- iOS 17.0 以降の実機（Simulator 非対応）
- マイク使用時はマイクへのアクセス許可が必要です

広告・トラッキング・アプリ内課金はありません。

## キーワード（100文字以内、カンマ区切り）

文字起こし,Whisper,音声,録音,オフライン,議事録,文字起こしアプリ,音声認識,ローカル,プライバシー

## 審査メモ（App Review Information）

```
【初回セットアップ】
起動後、モデルダウンロード画面が表示されます。「モデルをダウンロード」で
Hugging Face から Whisper モデル（約142MB）を取得してください。完了後に
メイン画面（録音・ファイルインポート）が利用できます。

【オフライン動作】
モデル取得後の文字起こしは端末内のみで処理します。音声・結果を開発者
サーバーへ送信しません。

【テストアカウント】
不要です。

【実機のみ】
Metal / whisper.cpp のため iOS Simulator では動作しません。実機 iOS 17+ で
ご確認ください。

【ショートカット】
TranscribeAudioIntent は iOS 18 以降です。iOS 17 ではアプリ内 UI のみ利用可能です。
```

## 輸出コンプライアンス

- Info.plist: `ITSAppUsesNonExemptEncryption` = `false`
- Connect での回答: **標準的な暗号化のみ**（HTTPS によるモデルダウンロードのみ、独自暗号なし）

## スクリーンショット

- 実機で撮影（Simulator 非対応）
- 推奨: iPhone 6.7"（1290×2796）または 6.5"（1242×2688）を 3〜6 枚
- 権限ダイアログのみの画面は避ける
