# App Store 提出チェックリスト

## リポジトリ内（コード）

- [x] App Icon (`Resources/Assets.xcassets/AppIcon.appiconset`)
- [x] Privacy Manifest (`PrivacyInfo.xcprivacy`)
- [x] `NSMicrophoneUsageDescription`
- [x] `ITSAppUsesNonExemptEncryption` = false
- [x] バージョン: `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
- [x] 設定画面からプライバシーポリシー・サポート URL へリンク

## GitHub Pages（手動）

- [ ] リポジトリ Settings → Pages → Branch: `main` / Folder: `/docs`
- [ ] マーケティング: https://porarrirr.github.io/offline-whisper-transcriber-ios/
- [ ] サポート: https://porarrirr.github.io/offline-whisper-transcriber-ios/support.html
- [ ] プライバシー: https://porarrirr.github.io/offline-whisper-transcriber-ios/privacy-policy.html
- [ ] 免責事項: https://porarrirr.github.io/offline-whisper-transcriber-ios/disclaimer.html

## Xcode / ビルド

- [x] `cd WhisperTranscriptionApp && xcodegen generate`（ローカル検証済み）
- [x] Release `iphoneos` ビルド成功（`CODE_SIGNING_ALLOWED=NO`、Privacy Manifest / App Icon / 輸出コンプライアンス確認済み）
- [x] 未署名 Archive 成功（`build/WhisperTranscriptionApp.xcarchive`）
- [ ] Xcode Organizer → **署名付き** Archive → Validate App → 成功
- [ ] Distribute App → App Store Connect にアップロード

## App Store Connect

- [ ] アプリ登録（バンドル ID: `com.porarrirr.offlinewhispertranscriber`）
- [ ] 説明文・キーワード・サポート URL・プライバシー URL
- [ ] App Privacy（`privacy-labels-ja.md` 参照）
- [ ] スクリーンショット（実機 3〜6 枚）
- [ ] ビルドの輸出コンプライアンス回答
- [ ] 年齢制限（通常 4+）
- [ ] 審査メモ入力（`AppStoreConnectMetadata-ja.md` 参照）
- [ ] **審査に提出**（ユーザー確認後）

## 審査前の動作確認（実機）

- [ ] 初回モデルダウンロード → 文字起こし成功
- [ ] マイク録音 → 文字起こし成功
- [ ] ファイルインポート → 文字起こし成功
- [ ] 設定からプライバシーポリシー・サポートが開ける
