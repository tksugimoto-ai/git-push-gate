# git-push-gate

保護ブランチのないリポジトリでも、AIエージェントには main / develop 以外への push だけを許可する中継サーバーです。

GitHub の Rulesets やブランチ保護が使えない環境（プランの制約、管理者権限がない等）で、devcontainer 内の AI エージェントに feature ブランチの push を任せつつ、保護したいブランチへの書き込みは人間だけに残すことを目的にしています。

## 前提条件（必ず守ること）

ゲートが守れるのは「エージェントの push」だけです。**GitHub Actions のワークフローが、エージェントの書き換えたコードを write 権限やシークレット付きで実行できると、ゲートの保証はすべてなくなります**（例: main と同じ内容の `on: push` + `contents: write` のワークフローを feature ブランチに置き、それが呼ぶスクリプトを `git push origin HEAD:main` に書き換える）。

- write 権限やシークレットを持つワークフローは、保護ブランチへの `push` でだけ動くようにする（`branches: [main]` など）
- そうしたワークフローを `pull_request` で動かさない（`branches: [main]` で絞っても、main 向けの PR では head 側のコードで動く）
- `issue_comment` などで PR の head を checkout して実行するワークフローを置かない
- 特権付きのワークフローを、パターン（`branches: ['release/**']` など）や保護していないブランチ名（`gh-pages` など）で動かさない。エージェントはそういう名前のブランチを作れる（`PROTECTED_BRANCHES` にパターンは書けない）
- デフォルトブランチの `workflow_run` や `on: create` / `delete` のワークフローで、エージェントの push で動いた実行の成果物やブランチ名を、特権付きで使わない
- 設定変数（`vars`）に機密情報を置かない。シークレットと違い、エージェントのワークフローから読める

ゲートは、エージェントが**変更した**ワークフローを検査しますが、保護ブランチと同じ内容のワークフローが実行するコード（スクリプトや `.github/actions` 以外のローカルアクション）は検査しません。また、検査するのは push されたブランチの先端のコミットだけです。途中のコミットに危険なワークフローがあっても、ブランチがそれを指さない限り動かないためで、エージェントがゲート以外で ref を作れない（PR 用のトークンが Contents: read）ことが前提です。

## 仕組み

```
devcontainer (エージェント)                git-push-gate コンテナ                    GitHub
  fetch ───────────────────────────────────────────────────────────────────────▶  (読み取り専用トークン)
  push ──SSH (コンテナ間専用の鍵)──▶  sshd → git-push-gate → pre-receive ──SSH──▶  (GitHub 用の鍵はここだけ)
```

- GitHub に書き込める鍵は git-push-gate コンテナだけが持ち、エージェントの環境には置きません。
- エージェントの SSH 鍵は `authorized_keys` の強制コマンドで `git-push-gate` に固定され、push（`git-receive-pack`）以外は実行できません。
- push を受け付ける前に GitHub の最新状態を fetch するので、fast-forward の判定は GitHub と一致します。
- `pre-receive` フックが検査し、通った更新だけをその場で GitHub に push します（`--atomic` と `--force-with-lease`）。lease には、クライアントが送ってきた値ではなく、直前に fetch した GitHub の値を使います。GitHub 側で失敗すればエージェントの push も失敗します。
- 保護ブランチが GitHub に 1 つでもなければ（名前の間違いなど）、push を受け付けません。何も守らないまま動くのを防ぐためです。

## 拒否するもの

| 対象 | 理由 |
|---|---|
| 保護ブランチ（既定 `main develop`）の更新・削除 | 本来の目的 |
| ブランチ以外の ref（タグなど） | |
| `.github/actions` の変更 | 既存のワークフローがシークレットや write 権限付きで呼んでいる可能性があり、単体では安全か判定できない（守れるのはこのディレクトリだけ。下記「限界」を参照） |
| ポリシーに合わない `.github/workflows` の変更 | 下記 |

### ワークフローのポリシー

保護ブランチのどれとも内容が異なるワークフローファイルだけを検査します。知らないものは拒否する方針で、次のどれかに当てはまると拒否します。

- トップレベルの `permissions` がない、またはどこかに write がある（job 単位・`write-all` を含む）
- `secrets` という文字列がある（ファイルの文字列と、`"\x73ecrets"` のようなエスケープを解釈した後の値の両方を見る）
- 許可していないトリガー。許可するのは `push` / `pull_request` / `pull_request_review` / `pull_request_review_comment` / `workflow_dispatch` / `workflow_call` / `merge_group` だけ（`pull_request_target` / `workflow_run` などは不可）
- 許可していないキー（トップレベル・job とも。大文字の `On:` や `Runs-On:` も不可）。`environment:` も不可
- GitHub ホストのランナーの標準ラベル（`ubuntu-latest` / `ubuntu-24.04` / `windows-2025` / `macos-15-xlarge` など）以外の `runs-on`（self-hosted や式を含む）。セルフホストのランナーには、この形のラベルを付けないこと
- job の `uses:` で、同じコミットの `./.github/workflows/` 以外の再利用可能なワークフローを呼ぶ（外部のものは中身を検査できない）
- 重複キー・アンカー・エイリアス・タグ・ディレクティブ（`%YAML 1.1` など）を使った曖昧な YAML
- `.github` や `.github/workflows` がシンボリックリンクなど、ディレクトリでない

ワークフローを経由した書き込み（Actions の `GITHUB_TOKEN` で main に push する等）やシークレットの持ち出しを防ぐためです。拒否されたコミットはエージェントの手元に残るので、必要なら人間が push してください。古い main から作ったブランチは、その後 main のワークフローが変わっていると「変更した」とみなされて拒否されることがあります。その場合は main に rebase してください。

`concurrency` は許可しているので、エージェントのワークフローが保護ブランチのデプロイと同じグループ名（文字列で書ける）を使うと、デプロイを待たせたり取り消したりできます。影響は実行が止まることだけで、書き込みやシークレットの取得はできません。問題になる場合は、デプロイに `concurrency` を使わないでください（どのグループにも入っていない実行は影響を受けません）。

#### write 権限を検査する理由

同じリポジトリのブランチから動くワークフローは、`permissions:` に書けば write 権限を得られます（得られないのは fork からの場合だけです）。組織のオーナーが禁止していれば得られませんが、外からは確認できないので、それを前提にはしていません。トップレベルの `permissions` を必須にしているのは、`permissions` を書くと書かなかった権限が none になり、既定の権限設定に左右されなくなるためです。

#### `pull_request_target` / `workflow_run` を禁止する理由

- `pull_request_target` は、PR の head ではなく **base ブランチ**のワークフローが、write 権限とシークレット付きで動きます。エージェントは PR 用のトークンで、自分の push したブランチを base にした PR を作れるので、エージェントが書いたワークフローが write 権限付きで動いてしまいます。このため禁止は必須です。
- `workflow_run` はデフォルトブランチにあるものしか動かないので、エージェントが書いたものは動きませんが、念のため禁止しています。ただし、デフォルトブランチにある `workflow_run` のワークフローが、エージェントの push で動いた実行の成果物を特権付きで使うと危険です（上記「前提条件」）。

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

# devcontainer 側の公開鍵（複数行可。from= などのオプションは付けない）
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
| `PROTECTED_BRANCHES` | 保護するブランチ（空白区切り、完全一致。`release/*` のようなパターンは使えない）。すべて GitHub に存在すること（ないと push を受け付けない）。既定 `main develop` |
| `UNLOCK_LIFETIME` | パスフレーズ付きの鍵を解除しておく時間（例: `8h`）。既定は無期限 |

| マウント先 | 内容 |
|---|---|
| `/config` | `github_key`, `known_hosts`, `client_keys.pub`、パスフレーズ付きなら `github_key.pub`、`client/attach.sh` を使うなら `client_key`（読み取り専用で可） |
| `/srv/git` | 中継用の bare リポジトリと sshd のホスト鍵（ボリューム推奨） |

### 3. devcontainer 側の remote を設定する

devcontainer に、クライアント用の秘密鍵（`client_keys.pub` に登録したものと対）と、ゲートのホスト鍵を置きます。どちらもワークスペースの外（`~/.ssh` など）に置いてください。ゲートのホスト鍵は、ホストで次のように取り出せます（`git-push-gate` は compose のサービス名）。

```sh
docker compose exec git-push-gate cat /srv/git/ssh_host_keys/ssh_host_ed25519_key.pub | awk '{print "git-push-gate", $1, $2}'
# → devcontainer の ~/.ssh/known_hosts に追記する
```

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
   - `git remote set-url --push origin ssh://git@git-push-gate/repo.git`

   docker.sock や SSH エージェントの転送が見つかれば、設定せずに止めます。最後にゲートへの接続を確かめ、VS Code の git credential helper が有効なら警告します。devcontainer やゲートが自動で見つからないときは、環境変数 `DEVCONTAINER`・`GATE` などで指定します（スクリプトの先頭を参照）。Windows では WSL のシェルから実行してください。

ゲートのホスト鍵は `/srv/git` のボリュームに保存されるので、コンテナを作り直しても変わりません。

## devcontainer 側で必要な設定

ゲートを置いても、エージェントの環境に書き込み可能な認証情報があれば意味がありません。

- VS Code の `dev.containers.gitCredentialHelperConfigLocation` を `none` にする（ホストの認証情報の自動転送を止める）
- SSH エージェントを転送しない
- `docker.sock` をマウントしない
- エージェントに渡す GitHub トークン（PR 作成用など）は、対象のリポジトリだけに絞った fine-grained PAT にする
  - **Contents: read**。Contents: write はマージや API 経由のコミットも許してしまう
  - PR を作るなら **Pull requests: write**（PR の作成・コメントだけで、マージには Contents: write が要る）
  - **Actions: write は付けない**（`workflow_dispatch` や再実行で、保護ブランチのワークフローを動かせてしまう）
  - classic PAT の `repo` スコープは書き込みも含むので使わない

## 限界

- クライアント側のガードではなくサーバー側の強制ですが、GitHub のブランチ保護の代わりにはなりません。使えるならそちらが確実です。
- ワークフローが実行するコード（`npm test` から呼ばれるスクリプト、`.github/actions` 以外に置いたローカルアクション（`uses: ./tools/x` など）等）はエージェントが変更できます。write 権限やシークレットを持つ既存ワークフローは、保護ブランチへの push でだけ動くようにしてください。`pull_request` は base ブランチで絞り込むので、`branches: [main]` でも main 向けの PR では head 側のコードで動く点に注意してください。
- 保護していないブランチは、人間が作ったものでもエージェントが強制 push・削除できます（意図した仕様です）。
- main にある既存のワークフローで、`issue_comment` や `pull_request_review` などで動いて PR の head を checkout するものは、エージェントが PR を作れるので危険です（head 側のコードが base 側の権限で動く）。
- ソースコードの外部送信は防げません。

## 今後の課題

- 変更されていないワークフローも検査し、feature ブランチや `pull_request` で動く特権付きのワークフローがあれば拒否する（上記「前提条件」を仕組みで強制する）
- ワークフローの検査を、GitHub 用の鍵を読めない別のユーザーで動かす（依存ライブラリが乗っ取られた場合の被害を抑える）
- 依存ライブラリ（`yaml`）をリポジトリに取り込み、npm のレジストリに依存しない

## テスト

Docker なしで動く結合テストがあります（git、Node.js、util-linux の flock、GNU か busybox の sed が必要。macOS ではそのままでは動きません）。

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
