## Agent Implementation Guidelines

### フォールバック実装の禁止
実装方法が明確に定まっている場合、失敗時の代替手段（フォールバック）を連鎖させてはならない。
**禁止パターン例：**
- 「Aを試して失敗したらBを試す」という連鎖的な実装
- 本来使うべきAPIや手法が存在するにもかかわらず、エラー時に別のAPIや回避策へ切り替えるコード
- `try { correctWay() } catch { fallbackWay() }` のような構造で、`fallbackWay` が本来不要なもの
**正しいアプローチ：**
- 正しい実装方法を一つ特定し、それが機能しない場合はエラーを明示して止める
- フォールバックが必要と感じた場合は、まず実装方法の選定が正しいか再確認する
- 不確かな場合はまず既存実装と仕様を調査する。挙動・仕様の選択が残る場合に人間に確認を求める。不要なフォールバックは実装しない
> フォールバックは「どちらでもよい場合」にのみ使う。「正しい方法がある場合」に使うのはバグの隠蔽である。

### XcodeGen & iOS 開発ルール
- **`.xcodeproj` の直接編集禁止**:
  - `WhisperTranscriptionApp.xcodeproj` は XcodeGen によって `project.yml` から自動生成されます。Xcode 上で手動で設定を変更したり、ファイルを直接グループに追加したりしないでください（次回再生成時に上書きされます）。
- **ファイルの追加・削除・構成変更**:
  - 生成される Xcode プロジェクトの構成に影響するファイルやフォルダの新規作成、削除、移動、または `project.yml` の変更を行った後は、 `WhisperTranscriptionApp` ディレクトリで以下のコマンドを実行してプロジェクトファイルを再生成してください。
    ```bash
    xcodegen generate
    ```
- **whisper.xcframework のビルド**:
  - 今回のビルド・検証に xcframework が必要で、未配置または `whisper.cpp` 内の関連ソースコード・ビルド設定を変更した場合は、`whisper.cpp/` 内の `build-xcframework.sh` を実行してフレームワークを再構築し、`Frameworks/` にコピーしたあと `Scripts/sign-whisper-xcframework.sh` を実行して Apple Development 証明書で署名してください。
- **iOS 17+ & SwiftUI/SwiftData 設計方針**:
  - 本アプリは iOS 17.0+ をターゲットとしています。SwiftUI や SwiftData（`@Observable` マクロ、`@Query` 等）のモダンな書き方を優先してください。

# Codex Git Guardrails

- `/Users/porari` is a home directory, not a Git repository.
- Never run `git init` in `/Users/porari`.
- Never run `git status`, `git add`, `git commit`, `git push`, or `git init` in `/Users/porari`.
- Before the first Git operation in the intended project directory, verify the root with `git rev-parse --show-toplevel`. Repeat this check when the working directory or repository structure changes; the verification command itself is exempt.
- If Git resolves the repository root to `/Users/porari`, stop and do not continue.
- Always set Git command `workdir` to the target project's absolute path.
- If the project root is not explicitly known, ask the user before touching Git.
