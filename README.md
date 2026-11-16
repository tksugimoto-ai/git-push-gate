# git-push-gate

保護ブランチのないリポジトリでも、AIエージェントには main / develop 以外への push だけを許可する中継サーバーです。

GitHub の Rulesets やブランチ保護が使えない環境（プランの制約、管理者権限がない等）で、devcontainer 内の AI エージェントに feature ブランチの push を任せつつ、保護したいブランチへの書き込みは人間だけに残すことを目的にしています。

## 仕組み

```
devcontainer (エージェント)                git-push-gate コンテナ                    GitHub
  fetch ───────────────────────────────────────────────────────────────────────▶  (読み取り専用トークン)
  push ──SSH (コンテナ間専用の鍵)──▶  sshd → git-push-gate → pre-receive ──SSH──▶  (GitHub 用の鍵はここだけ)
```

- GitHub に書き込める鍵は git-push-gate コンテナだけが持ち、エージェントの環境には置きません。
- エージェントの SSH 鍵は `authorized_keys` の強制コマンドで `git-push-gate` に固定され、push（`git-receive-pack`）以外は実行できません。
- push を受け付ける前に GitHub の最新状態を fetch するので、fast-forward の判定は GitHub と一致します。
- `pre-receive` フックが検査し、通った更新だけをその場で GitHub に push します（`--atomic` と `--force-with-lease`）。GitHub 側で失敗すればエージェントの push も失敗します。

## 拒否するもの

| 対象 | 理由 |
|---|---|
| 保護ブランチ（既定 `main develop`）の更新・削除 | 本来の目的 |
| ブランチ以外の ref（タグなど） | |
| `.github/actions` の変更 | 既存のワークフローがシークレットや write 権限付きで呼んでいる可能性があり、単体では安全か判定できない |
| ポリシーに合わない `.github/workflows` の変更 | 下記 |

### ワークフローのポリシー

保護ブランチのどれとも内容が異なるワークフローファイルだけを検査します。次のどれかに当てはまると拒否します。

- トップレベルの `permissions` がない、またはどこかに write がある（job 単位・`write-all` を含む）
- ファイル内に `secrets` という文字列がある
- `pull_request_target` / `workflow_run` トリガー
- `environment:` の指定
- GitHub ホストのランナー（`ubuntu-*` / `windows-*` / `macos-*`）以外の `runs-on`（self-hosted や式を含む）
- 重複キー・アンカー・エイリアス・タグなどの曖昧な YAML

ワークフローを経由した書き込み（Actions の `GITHUB_TOKEN` で main に push する等）やシークレットの持ち出しを防ぐためです。拒否されたコミットはエージェントの手元に残るので、必要なら人間が push してください。

## 使い方

### 1. 鍵とホスト鍵を用意する

**ワークスペース（devcontainer にマウントされるディレクトリ）の外**に設定ディレクトリを作ります。

```sh
dir=~/.config/git-push-gate/REPO
mkdir -p "$dir" && cd "$dir"

# GitHub 用の鍵（この用途専用に作る）
ssh-keygen -t ed25519 -N '' -C git-push-gate -f github_key
# → github_key.pub を GitHub に登録（可能なら書き込み可の Deploy key、無理ならアカウントの SSH 鍵）

# GitHub のホスト鍵。表示されたフィンガープリントを GitHub のドキュメントと照合すること
ssh-keyscan -t ed25519 github.com > known_hosts
ssh-keygen -lf known_hosts

# devcontainer 側の公開鍵（複数行可）
cp /path/to/devcontainer_key.pub client_keys.pub
```

> [!WARNING]
> アカウントに登録した SSH 鍵は、そのアカウントが書き込めるすべてのリポジトリに書き込めます。既存の鍵は使い回さず、専用の鍵を作ってください。

### 2. compose に追加する

[examples/compose.yaml](examples/compose.yaml) を参照してください。

| 環境変数 | 説明 |
|---|---|
| `UPSTREAM` | 必須。例: `git@github.com:owner/repo.git` |
| `PROTECTED_BRANCHES` | 保護するブランチ（空白区切り）。既定 `main develop` |

| マウント先 | 内容 |
|---|---|
| `/config` | `github_key`, `known_hosts`, `client_keys.pub`（読み取り専用で可） |
| `/srv/git` | 中継用の bare リポジトリ（ボリューム推奨） |

### 3. devcontainer 側の remote を設定する

```sh
git remote set-url origin https://github.com/owner/repo.git     # fetch は GitHub から直接
git remote set-url --push origin ssh://git@git-push-gate/repo.git
```

## devcontainer 側で必要な設定

ゲートを置いても、エージェントの環境に書き込み可能な認証情報があれば意味がありません。

- VS Code の `dev.containers.gitCredentialHelperConfigLocation` を `none` にする（ホストの認証情報の自動転送を止める）
- SSH エージェントを転送しない
- `docker.sock` をマウントしない
- エージェントに渡す GitHub トークン（PR 作成用など）は **Contents: read** にする。Contents: write はマージや API 経由のコミットも許してしまう

## 限界

- クライアント側のガードではなくサーバー側の強制ですが、GitHub のブランチ保護の代わりにはなりません。使えるならそちらが確実です。
- ワークフローが実行するコード（`npm test` から呼ばれるスクリプト等）はエージェントが変更できます。write 権限やシークレットを持つ既存ワークフローは、保護ブランチへの push でだけ動くようにしてください。
- ソースコードの外部送信は防げません。

## テスト

Docker なしで動く結合テストがあります（git と Node.js が必要）。

```sh
npm ci
npm test
```

## ライセンス

MIT
