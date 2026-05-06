# Whisper 音声文字起こし iOS アプリ

iPhone内だけで完全オフライン動作する、AI音声文字起こしアプリです。OpenAIのWhisperモデルを搭載し、リアルタイム録音または音声ファイルから高精度な文字起こしを行います。

## 機能

- **リアルタイム録音＆文字起こし**: マイクで録音し、その場でAIがテキスト化
- **ファイル選択対応**: 端末内の音声ファイル（m4a/wav/mp3）を文字起こし
- **完全オフライン**: モデルダウンロード後はインターネット不要
- **履歴保存**: SwiftDataで文字起こし結果を永続化、検索・お気に入り管理
- **ダークモードUI**: 洗練されたダークテーマ、録音波形アニメーション
- **モデル自動ダウンロード**: 初回起動時に自動でモデルを取得（約142MB）

## 必要環境

- **macOS** 14.0 Sonoma 以降
- **Xcode** 15.0 以降
- **iOS** 17.0 以降を搭載した実機（Simulator不可、Metal/GPU推奨）
- **Apple ID**（実機へのインストール用）

## プロジェクト構成

```
WhisperTranscriptionApp/
├── Sources/WhisperTranscriptionApp/    # Swiftソースコード
│   ├── App/                            # Appエントリーポイント
│   ├── Models/                         # 音声処理・Whisperラッパー
│   ├── ViewModels/                     # 状態管理
│   ├── Views/                          # UI（SwiftUI）
│   └── DesignSystem/                   # カラー・フォント定義
├── whisper.cpp/                        # whisper.cpp（Git Submodule）
├── Frameworks/                         # 生成した whisper.xcframework
├── WhisperTranscriptionApp-Bridging-Header.h
├── Info.plist
└── Package.swift
```

## セットアップ手順

### 1. リポジトリのクローン

```bash
git clone --recursive <このリポジトリのURL>
cd WhisperTranscriptionApp
```

既にクローン済みでsubmoduleが空の場合：

```bash
git submodule update --init --recursive
```

### 2. whisper.xcframework のビルド

**Macで**以下を実行します：

```bash
cd whisper.cpp
./build-xcframework.sh
```

ビルドが完了すると、以下のようなパスに `whisper.xcframework` が生成されます：

```
whisper.cpp/build-apple/whisper.xcframework
```

これをプロジェクトの `Frameworks/` ディレクトリにコピーします：

```bash
cp -R whisper.cpp/build-apple/whisper.xcframework Frameworks/
```

> **注意**: `build-xcframework.sh` はXcodeのコマンドラインツールを使用します。失敗する場合はXcodeを起動し、`Xcode > Settings > Locations` でCommand Line Toolsが正しく設定されているか確認してください。

### 3. Xcode プロジェクトの作成（自動生成）

本プロジェクトには `project.yml` が含まれています。**XcodeGen** を使うと、ワンコマンドでXcodeプロジェクトファイルを自動生成できます。

#### XcodeGenのインストール（初回のみ）

```bash
brew install xcodegen
```

> Homebrewがない場合: [https://brew.sh](https://brew.sh) からインストールしてください。

#### プロジェクトファイルの生成

`WhisperTranscriptionApp` ディレクトリ（`project.yml` がある場所）で以下を実行：

```bash
xcodegen generate
```

これで `WhisperTranscriptionApp.xcodeproj` が自動生成されます。

#### 手動で作成する場合

XcodeGenを使わない場合は、Xcodeで新規プロジェクトを手動作成し、以下の手順でファイルを追加・設定してください：

1. **Create New Project**（または File > New > Project）
2. テンプレート: **iOS > App** を選択 → **Next**
3. 以下の通り入力：
   - **Name**: `WhisperTranscriptionApp`
   - **Team**: あなたのApple IDチーム（個人開発用はPersonal Teamで可）
   - **Organization Identifier**: `com.yourname` など（例: `com.example`）
   - **Interface**: `SwiftUI`
   - **Language**: `Swift`
   - **Storage**: `SwiftData`（チェックを入れる）
   - **Include Tests**: 任意（今回は不要）
4. **Next** → 保存先を `WhisperTranscriptionApp/` と**同じ階層ではなく**、その**中**に保存

> 保存時に「Create Git repository on my Mac」のチェックは**外して**ください（既にGit管理されています）。

その後、以下の手順でファイルを追加・設定します。

#### 4.1 Swiftソースファイルの追加

1. 既存の `ContentView.swift` と `WhisperTranscriptionAppApp.swift` は削除（または上書き）
2. **File > Add Files to "WhisperTranscriptionApp"...** を選択
3. `Sources/WhisperTranscriptionApp/` 内の**すべてのフォルダとファイル**を選択
4. **Copy items if needed** のチェックは**外し**、`Create groups` を選択 → **Add**

#### 4.2 Bridging Header の設定

1. `WhisperTranscriptionApp-Bridging-Header.h` をXcodeにドラッグ＆ドロップ（または Add Files）
2. プロジェクト設定 → **Build Settings** タブ → 検索欄に `bridging` と入力
3. **Objective-C Bridging Header** に以下を設定：
   ```
   WhisperTranscriptionApp-Bridging-Header.h
   ```
4. **whisper.h のパスを解決するため**、Build Settings の **Header Search Paths** に以下を追加（Recursiveにチェック）：
   ```
   $(SRCROOT)/whisper.cpp/include
   $(SRCROOT)/whisper.cpp/ggml/include
   ```

#### 4.3 Info.plist の設定

1. プロジェクトに既存の `Info.plist` がある場合はそれを削除
2. 本プロジェクトの `Info.plist` をドラッグ＆ドロップで追加
3. プロジェクト設定 → **Info** タブ → 各設定が反映されているか確認
4. **Privacy - Microphone Usage Description** (`NSMicrophoneUsageDescription`) に「音声を録音して文字起こしするためにマイクへのアクセスが必要です。」と設定されていることを確認

#### 4.4 Framework のリンク

1. **General** タブ → **Frameworks, Libraries, and Embedded Content** セクション
2. **+** ボタン → **Add Other...** → **Add Files...**
3. `Frameworks/whisper.xcframework` を選択 → **Open**
4. `whisper.xcframework` が追加されたら、**Embed** 列が `Embed & Sign` になっていることを確認

#### 4.5 追加Frameworkのリンク

同様に以下のApple純正Frameworkも追加します：

- `AVFoundation.framework`
- `UniformTypeIdentifiers.framework`

（通常は自動でリンクされますが、念のため確認）

### 5. ビルド設定の調整（手動作成時のみ）

XcodeGenを使用した場合は自動で設定されます。手動作成の場合は **Build Settings** で以下を確認・設定：

| 設定項目 | 値 |
|---------|-----|
| **Deployment Target** | iOS 17.0 |
| ** architectures** | arm64 |
| **ENABLE_USER_SCRIPT_SANDBOXING** | NO（whisper.cppビルド時）|
| **OTHER_LDFLAGS** | `-lc++` を追加（C++リンケージ用）|

### 6. モデルの配置（任意）

#### 自動ダウンロード（推奨）

アプリを初回起動すると、自動で `ggml-base.bin` をダウンロードします。Wi-Fi環境で実行してください。

#### 手動配置（オフライン環境でテストする場合）

1. 以下のURLから `ggml-base.bin` をMacでダウンロード：
   ```
   https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
   ```
2. Xcodeを開き、**Window > Devices and Simulators** → 接続中のiPhoneを選択
3. **Installed Apps** から WhisperTranscriptionApp を選択 → **歯車アイコン** → **Download Container...**
4. コンテナ内の `Documents/` に `ggml-base.bin` を配置（またはアプリ内のファイル共有経由）

> **Bundle内蔵の場合**: `ggml-base.bin` をXcodeプロジェクトにドラッグ＆ドロップし、「Copy items if needed」にチェック、ターゲットに含めます。ただしアプリサイズが約150MB増加します。

### 7. ビルドと実行

1. 上部のスキーム選択で、接続した**実機（iPhone）**を選択（Simulatorは選択しない）
2. **Cmd+R** でビルド＆実行
3. 初回起動時にモデルダウンロード画面が表示されます。完了後、メイン画面に遷移します

## トラブルシューティング

### "whisper.h not found" エラー

Bridging Headerのパス設定、またはHeader Search Pathsを確認してください。

### "Undefined symbol: whisper_init_from_file_with_params" などのリンクエラー

`whisper.xcframework` が正しく **Embed & Sign** 設定でリンクされているか確認してください。

### 録音が開始できない / マイク権限ダイアログが出ない

`Info.plist` に `NSMicrophoneUsageDescription` が正しく設定されているか確認してください。

### モデルダウンロードが失敗する

iPhoneの設定 → プライバシーとセキュリティ → ローカルネットワーク / インターネット接続を確認してください。

### 文字起こし処理中にアプリがクラッシュする

メモリ不足の可能性があります。`ggml-base.bin` は処理中に数百MBのメモリを使用します。他のアプリを終了してから試してください。

## カスタマイズ

### モデルの変更

`ModelManager.swift` の `modelURL` と `modelFileName` を変更してください：

| モデル | ファイル名 | サイズ | 精度 |
|--------|-----------|--------|------|
| tiny | `ggml-tiny.bin` | ~75MB | 低 |
| base | `ggml-base.bin` | ~142MB | 中 |
| small | `ggml-small.bin` | ~466MB | 高 |

### 言語の変更

`TranscribeViewModel.swift` の `transcribeAudio` 内で `language: "ja"` を変更：

- 日本語: `"ja"`
- 英語: `"en"`
- 自動判定: `nil`（params.language に nil を渡す）

## ライセンス

本アプリのソースコードはMITライセンスです。whisper.cppはそれぞれのライセンスに従います。
