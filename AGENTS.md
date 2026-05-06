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
- 不確かな場合はフォールバックを書くのではなく、人間に確認を求める
> フォールバックは「どちらでもよい場合」にのみ使う。「正しい方法がある場合」に使うのはバグの隠蔽である。
# Codex Git Guardrails

- `C:\Users\nmrhr` is a home directory, not a Git repository.
- Never run `git init` in `C:\Users\nmrhr`.
- Never run `git status`, `git add`, `git commit`, `git push`, or `git init` in `C:\Users\nmrhr`.
- Before any Git operation, run `git rev-parse --show-toplevel` in the intended project directory.
- If Git resolves the repository root to `C:\Users\nmrhr`, stop and do not continue.
- Always set Git command `workdir` to the target project's absolute path.
- If the project root is not explicitly known, ask the user before touching Git.
