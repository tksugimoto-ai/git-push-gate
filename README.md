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

#### write 権限を検査する理由

同じリポジトリのブランチから動くワークフローは、`permissions:` に書けば write 権限を得られます（得られないのは fork からの場合だけです）。組織のオーナーが禁止していれば得られませんが、外からは確認できないので、それを前提にはしていません。トップレベルの `permissions` を必須にしているのは、`permissions` を書くと書かなかった権限が none になり、既定の権限設定に左右されなくなるためです。

#### `pull_request_target` / `workflow_run` を禁止する理由

- `pull_request_target` は、PR の head ではなく **base ブランチ**のワークフローが、write 権限とシークレット付きで動きます。エージェントは PR 用のトークンで、自分の push したブランチを base にした PR を作れるので、エージェントが書いたワークフローが write 権限付きで動いてしまいます。このため禁止は必須です。
- `workflow_run` はデフォルトブランチにあるものしか動かないので、本来は保護ブランチのワークフローしか動きませんが、念のため禁止しています。

## 使い方

### 1. 鍵とホスト鍵を用意する

**ワークスペース（devcontainer にマウントされるディレクトリ）の外**に設定ディレクトリを作ります。

```sh
dir=~/.config/git-push-gate/REPO
mkdir -p "$dir" && cd "$dir"

# GitHub 用の鍵（この用途専用に作る。パスフレーズは付けても付けなくてもよい）
ssh-keygen -t ed25519 -C git-push-gate -f github_key
# → github_key.pub を GitHub に登録（下記「GitHub 用の鍵の選び方」を参照）

# GitHub のホスト鍵。表示されたフィンガープリントを GitHub のドキュメントと照合すること
ssh-keyscan -t ed25519 github.com > known_hosts
ssh-keygen -lf known_hosts

# devcontainer 側の公開鍵（複数行可）
cp /path/to/devcontainer_key.pub client_keys.pub
```

#### パスフレーズ

パスフレーズ付きの鍵の場合は `github_key.pub` も同じディレクトリに置いてください。起動後は鍵がロックされた状態になり、エージェントからの push は「ロックされています」というエラーで止まります。ホストで一度だけ次を実行すると、コンテナを止めるまで有効になります。

```sh
docker compose exec git-push-gate unlock
```

環境変数 `UNLOCK_LIFETIME`（例: `8h`）を指定すると、その時間が経つと自動で再ロックされます。

#### GitHub 用の鍵の選び方

| 方法 | 書き込める範囲 | 手間 |
|---|---|---|
| Deploy key（書き込み可） | 対象リポジトリだけ | リポジトリの管理者権限が必要 |
| マシンユーザーの SSH 鍵 | 招待されたリポジトリだけ | アカウントの作成と招待が必要 |
| 自分のアカウントに専用の鍵を追加 | 自分が書き込めるすべてのリポジトリ | 鍵を登録するだけ |

自分のアカウントの鍵でも、ホストにはもともと同じ範囲の認証情報（普段の push に使っているもの）があり、エージェントからは読めない場所に置くので、増えるリスクは「ホスト上の鍵ファイルが 1 つ増える」ことです。既存の鍵は使い回さず、漏れたときにそれだけ取り消せる専用の鍵にしてください。

### 2. compose に追加する

[examples/compose.yaml](examples/compose.yaml) を参照してください。

| 環境変数 | 説明 |
|---|---|
| `UPSTREAM` | 必須。例: `git@github.com:owner/repo.git` |
| `PROTECTED_BRANCHES` | 保護するブランチ（空白区切り）。既定 `main develop` |
| `UNLOCK_LIFETIME` | パスフレーズ付きの鍵を解除しておく時間（例: `8h`）。既定は無期限 |

| マウント先 | 内容 |
|---|---|
| `/config` | `github_key`, `known_hosts`, `client_keys.pub`、パスフレーズ付きなら `github_key.pub`、`client/attach.sh` を使うなら `client_key`（読み取り専用で可） |
| `/srv/git` | 中継用の bare リポジトリと sshd のホスト鍵（ボリューム推奨） |

### 3. devcontainer 側の remote を設定する

```sh
git remote set-url origin https://github.com/owner/repo.git     # fetch は GitHub から直接
git remote set-url --push origin ssh://git@git-push-gate/repo.git
```

### 利用側のリポジトリを変更せずに使う（compose を使わない devcontainer）

devcontainer.json が `image` や Dockerfile の方式で compose を使っていない場合は、ゲートを別に起動し、ポートをホストに公開してつなぎます。利用側のリポジトリにコミットする変更は要りません。

devcontainer は既定の bridge ネットワークで動くのでコンテナ名では届かず、Feature では `--network` を指定できないためです。compose 方式でも、devcontainer.json の `dockerComposeFile` に書かれたファイルしか読まれない（`docker-compose.override.yml` や `COMPOSE_FILE` は使われない）ので、ゲートを足すには devcontainer.json の変更が要ります。

1. ワークスペースの外に [examples/standalone/compose.yaml](examples/standalone/compose.yaml) を置き、同じディレクトリの `config/` に鍵などを置いて起動します。

   ```sh
   cd ~/.config/git-push-gate/REPO
   docker info --format '{{.OperatingSystem}}'   # Docker Desktop か、それ以外か
   echo GATE_BIND=172.17.0.1 > .env               # Docker Desktop 以外のときだけ（docker0 の IP）
   docker compose up -d
   ```

   | Docker | 公開先（`GATE_BIND`） | devcontainer から見たゲート |
   |---|---|---|
   | Docker Desktop（Mac / Windows。WSL2 バックエンドを含む） | `127.0.0.1`（既定） | `host.docker.internal` |
   | Linux・WSL に直接入れた Docker Engine | docker0 の IP（多くは `172.17.0.1`） | デフォルトゲートウェイ（docker0 の IP） |

   `0.0.0.0` には公開しないでください（LAN に公開されます）。Docker Desktop の経路は未検証です。

   クライアント用の鍵は、この設定ディレクトリに 1 つだけ作ります（devcontainer をリビルドしても作り直さない）。

   ```sh
   ssh-keygen -t ed25519 -N '' -C git-push-gate-client -f config/client_key
   cat config/client_key.pub >> config/client_keys.pub
   docker compose restart
   ```

2. devcontainer を起動したら（リビルドのたびに）、ホストで、このリポジトリを clone したディレクトリから、ワークスペースのディレクトリを指定して [client/attach.sh](client/attach.sh) を実行します。

   ```sh
   sh client/attach.sh ~/src/REPO
   ```

   次を `docker exec` で devcontainer に設定します。どれも `~/.ssh` と `.git/config` に入るので、利用側のリポジトリにはコミットされません。

   - クライアント用の鍵（ゲートのコンテナから直接渡す）
   - ゲートのホスト鍵（ゲートから読むので、フィンガープリントの照合は不要）
   - `~/.ssh/config` の `Host git-push-gate`（公開先が `127.0.0.1` なら `host.docker.internal`、それ以外はその IP）
   - `git remote set-url --push origin ssh://git-push-gate/repo.git`

   最後にゲートへの接続を確かめ、SSH エージェントの転送・docker.sock・VS Code の git credential helper が見つかれば警告します。devcontainer やゲートが自動で見つからないときは、環境変数 `DEVCONTAINER`・`GATE` などで指定します（スクリプトの先頭を参照）。Windows では WSL のシェルから実行してください。

ゲートのホスト鍵は `/srv/git` のボリュームに保存されるので、コンテナを作り直しても変わりません。

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

コンテナを使った e2e テストもあります（Docker だけが必要）。イメージ自身を「GitHub」（SSH の git サーバー）とクライアントにも使い、本物の entrypoint・sshd・unlock を通して確認します。

```sh
docker build -t git-push-gate:test .
sh test/e2e.sh
```

## ライセンス

MIT
