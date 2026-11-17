# git-push-gate

保護ブランチのないリポジトリでも、AIエージェントには main / develop 以外への push だけを許可する中継サーバーです。

GitHub の Rulesets やブランチ保護が使えない環境（プランの制約、管理者権限がない等）で、devcontainer 内の AI エージェントに feature ブランチの push を任せつつ、保護したいブランチへの書き込みは人間だけに残すことを目的にしています。

## 前提条件（必ず守ること）

ゲートが守れるのは「エージェントの push」だけです。エージェントにはワークフロー（`.github/workflows`）と複合アクション（`.github/actions`）を変更させませんが、**人間が書いた既存のワークフローが、エージェントの書き換えたコードを write 権限やシークレット付きで実行できると、ゲートの保証はすべてなくなります**（例: `on: push` + `contents: write` のワークフローが、feature ブランチへの push でも動き、エージェントが書き換えたスクリプトで `git push origin HEAD:main` する）。

- リポジトリの Settings → Actions → General → **Workflow permissions を「Read repository contents and packages permissions」にする**。`permissions` を書いていない既存のワークフロー（`npm test` を実行するだけの CI など）が、write 権限のトークンで動かないようにするため。あわせて「Allow GitHub Actions to create and approve pull requests」を無効にする
- write 権限やシークレットを持つワークフローは、保護ブランチへの `push` でだけ動くようにする（`branches: [main]` など）
- そうしたワークフローを `pull_request` で動かさない（`branches: [main]` で絞っても、main 向けの PR では head 側のコードで動く）
- `issue_comment` などで PR の head を checkout して実行するワークフローを置かない
- デフォルトブランチの `pull_request_target` のワークフローは、エージェントが自分のブランチを base にした PR を作るだけで動く。PR の head を checkout しなくても、特権付きで動くことを前提に中身を確認する
- 特権付きのワークフローを、パターン（`branches: ['release/**']` など）や保護していないブランチ名（`gh-pages` など）で動かさない。エージェントはそういう名前のブランチを作れる（`PROTECTED_BRANCHES` にパターンは書けない）
- デフォルトブランチの `workflow_run` や `on: create` / `delete` のワークフローで、エージェントの push で動いた実行の成果物やブランチ名を、特権付きで使わない
- 設定変数（`vars`）に機密情報を置かない。エージェントのコードを実行するワークフローから読める
- ブランチの内容を使って動く外部のアプリ（自動マージのボット、`gh-pages` からの Pages の公開など）も、エージェントが push したブランチで動きうる
- マージは、レビューしたコミットに限る（`gh pr merge --match-head-commit <SHA>` など）。保護ブランチがないので、レビューの後、マージの直前にエージェントが PR のブランチに push できる

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
- 保護ブランチが GitHub に 1 つでもなければ（名前の間違いなど）、またはデフォルトブランチが保護ブランチに入っていなければ、push を受け付けません。何も守らないまま動くのを防ぐためです。
- GitHub に push できた更新は、ゲートの `/srv/git/repo.git/push-gate.log` に記録します（`docker compose exec git-push-gate cat /srv/git/repo.git/push-gate.log`）。
- ゲートは起動時（パスフレーズ付きの鍵なら unlock の後）に GitHub を fetch します。最初の fetch は全履歴なので時間がかかるためで、UPSTREAM・鍵・known_hosts の間違いもここで分かります（ログに警告が出る）。
- 受け付けは 10 分、GitHub への push は 5 分で打ち切ります。止まったクライアントが、ほかの push を待たせ続けないためです。ただし、受け付けが時間切れになっても、GitHub への push は終わっていることがあります（クライアントには失敗と返る）。その場合は fetch して確かめてください。記録の書き込みに失敗したときも、GitHub への push は成功として扱います。

## 拒否するもの

| 対象 | 理由 |
|---|---|
| 保護ブランチ（既定 `main develop`）の更新・削除 | 本来の目的。大文字・小文字だけが違う名前（`Main` など）も拒否 |
| ブランチ以外の ref（タグなど） | |
| 紛らわしいブランチ名（`HEAD`、`refs/` で始まるもの、40 桁の 16 進数） | 人間やツールが、別の ref やコミット ID と取り違える |
| `.github/workflows` と `.github/actions` の変更 | 下記 |

### ワークフローと複合アクション

エージェントが push したブランチの `.github/workflows` の各ファイルと `.github/actions` は、次の「基準」のどれかと**同一**でなければ拒否します。中身は解析しません。

- 保護ブランチ（main / develop など）
- push 先のブランチの、GitHub 上の今の内容

ワークフローを変えたいときは、人間がホストから GitHub に直接 push してください。push 先のブランチが基準に入るので、人間が変更したワークフローの上には、エージェントがそのままコミットを積めます（rebase や強制 push も、ワークフローに触れなければ通ります）。基準に入る内容は、人間が push したものか、ゲートを通った（＝その時の基準と同一だった）ものだけです。

- ワークフローの削除は許します（ファイルがなければ動かない）。
- 人間が変更したワークフローを含むブランチから、エージェントが別のブランチを作って push すると拒否されます（push 先のブランチがまだ GitHub にないため）。
- 古い main から作ったブランチは、その後 main のワークフローが変わっていると拒否されます。その場合は main に rebase してください。
- `.github` や `.github/workflows` がシンボリックリンクなど、ディレクトリでなければ拒否します。大文字・小文字だけが違う `.GITHUB` や `.github/Workflows` も拒否します。
- 比較は木が正しい形であることを前提にしているので、ゲートは `receive.fsckObjects` で壊れたオブジェクト（並びの壊れた木など）を拒否します。この設定が無効なら、push を受け付けません。

#### 中身を検査しない理由

以前は、ワークフローの中身を検査して安全なものだけを通していましたが、次の理由で、内容による判定は安全にできないと判断しました。

- `pull_request` のワークフローは、PR の head ではなく、GitHub が作る**マージコミット**（`refs/pull/N/merge`）から読まれます。エージェントは自分のブランチどうしの PR を作れるので、それぞれは検査を通る 2 つの変更を組み合わせて、どちらにもない（検査されていない）ワークフローを動かせます。
- YAML の解釈は、パーサーごとに細かく違います（単独の CR を改行とみなすかなど）。ゲートと GitHub の解釈が 1 か所でも違えば、検査をすり抜けられます。
- `pull_request_target` は、PR の head ではなく **base ブランチ**のワークフローが、write 権限とシークレット付きで動きます。エージェントは自分の push したブランチを base にした PR を作れるので、エージェントが書いたワークフローが特権付きで動いてしまいます。

同一かどうかだけを見る方式なら、解析は要らず、動くワークフローは常に人間が書いたものになります。ただし、人間が書いた 2 つの版（main と develop、または main と人間が変更した feature ブランチ）を、エージェントが PR のマージで組み合わせることは理論上できます。

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
| `PROTECTED_BRANCHES` | 保護するブランチ（空白区切り、完全一致。`release/*` のようなパターンは使えない）。すべて GitHub に存在し、デフォルトブランチを含むこと（そうでないと push を受け付けない）。既定 `main develop` |
| `UNLOCK_LIFETIME` | パスフレーズ付きの鍵を解除しておく時間（例: `8h`）。既定は無期限 |
| `MAX_PUSH_SIZE` | 1 回の push で受け付ける大きさの上限（`receive.maxInputSize`）。既定 `500m` |

| マウント先 | 内容 |
|---|---|
| `/config` | `github_key`, `known_hosts`, `client_keys.pub`、パスフレーズ付きなら `github_key.pub`（読み取り専用で可）。クライアント用の秘密鍵は置かない |
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

   クライアント用の鍵は、compose.yaml と同じディレクトリに 1 つだけ作ります（devcontainer をリビルドしても作り直さない）。ゲートには要らないので、ゲートにマウントする `config/` の外に置きます。

   ```sh
   ssh-keygen -t ed25519 -N '' -C git-push-gate-client -f client_key
   cat client_key.pub >> config/client_keys.pub
   docker compose restart
   ```

2. devcontainer を起動したら（リビルドのたびに）、ホストで、このリポジトリを clone したディレクトリから、ワークスペースのディレクトリを指定して [client/attach.sh](client/attach.sh) を実行します。

   ```sh
   sh client/attach.sh ~/src/REPO
   ```

   次を `docker exec` で devcontainer に設定します。どれも `~/.ssh` と `.git/config` に入るので、利用側のリポジトリにはコミットされません。

   - クライアント用の鍵（ホストの `client_key` から渡す。別の場所なら環境変数 `CLIENT_KEY` で指定）
   - ゲートのホスト鍵（ゲートから読むので、フィンガープリントの照合は不要）
   - `~/.ssh/config` の `Host git-push-gate`（公開先が `127.0.0.1` なら `host.docker.internal`、それ以外はその IP）
   - `git remote set-url --push origin ssh://git@git-push-gate/repo.git`

   devcontainer から Docker を操作できる（`docker.sock`・`docker-host.sock`・`DOCKER_HOST`）か、SSH エージェントが転送されていれば、設定せずに止めます。最後にゲートへの接続を確かめ、VS Code の git credential helper が有効なら警告します。devcontainer やゲートが自動で見つからないときは、環境変数 `DEVCONTAINER`・`GATE` などで指定します（スクリプトの先頭を参照）。Windows では WSL のシェルから実行してください。

ゲートのホスト鍵は `/srv/git` のボリュームに保存されるので、コンテナを作り直しても変わりません。

## devcontainer 側で必要な設定

ゲートを置いても、エージェントの環境に書き込み可能な認証情報があれば意味がありません。

- VS Code の `dev.containers.gitCredentialHelperConfigLocation` を `none` にする（ホストの認証情報の自動転送を止める）
- SSH エージェントを転送しない
- `docker.sock` をマウントしない（docker-outside-of-docker の Feature なども使わない）
- ゲートの設定ディレクトリ（`~/.config/git-push-gate` など）をマウントしない
- **devcontainer の定義とワークスペースの `.git` は、エージェントが書き換えられる**ことに注意する
  - `.devcontainer/devcontainer.json` や compose のファイルに、マウント（docker.sock やゲートの設定ディレクトリ）や `initializeCommand`（ホストで動く）を足されると、人間がリビルドしたときに効いてしまう。リビルドの前に差分を確かめる
  - ワークスペースの `.git/config`（`core.fsmonitor`、`core.sshCommand` など）や `.git/hooks` は、ホストでそのディレクトリの git を使うと、ホストで実行される。ホストでは、そのワークスペースで git を使わない（別に clone したものを使う）
- エージェントに渡す GitHub トークン（PR 作成用など）は、対象のリポジトリだけに絞った fine-grained PAT にする
  - **Contents: read**。Contents: write はマージや API 経由のコミットも許してしまう
  - PR を作るなら **Pull requests: write**（PR の作成・コメントだけで、マージには Contents: write が要る）
  - **Actions: write は付けない**（`workflow_dispatch` や再実行で、保護ブランチのワークフローを動かせてしまう）
  - classic PAT の `repo` スコープは書き込みも含むので使わない

## 限界

- クライアント側のガードではなくサーバー側の強制ですが、GitHub のブランチ保護の代わりにはなりません。使えるならそちらが確実です。
- ワークフローが実行するコード（`npm test` から呼ばれるスクリプト、`.github/actions` 以外に置いたローカルアクション（`uses: ./tools/x` など）等）はエージェントが変更できます（上記「前提条件」）。
- 人間が書いた 2 つの版のワークフロー（main と develop など）を、エージェントが PR のマージコミットで組み合わせることは、理論上できます。
- 検査するのは push されたブランチの先端のコミットだけです。途中のコミットはブランチが指さない限り動かないためで、エージェントがゲート以外で ref を作れない（PR 用のトークンが Contents: read）ことが前提です。
- 保護していないブランチは、人間が作ったものでもエージェントが強制 push・削除できます（意図した仕様です）。
- main にある既存のワークフローで、`issue_comment` や `pull_request_review` などで動いて PR の head を checkout するものは、エージェントが PR を作れるので危険です（head 側のコードが base 側の権限で動く）。
- ソースコードの外部送信は防げません。
- Git LFS は使えません（LFS のオブジェクトは HTTPS で送るので、ゲートを通らず、読み取り専用のトークンでは送れない）。

## 今後の課題

- 保護ブランチのワークフローを読み、feature ブランチや `pull_request` で動く特権付きのものがあれば警告する（上記「前提条件」を仕組みで確かめる）
- ゲートのリポジトリのディレクトリを root の所有にし、git ユーザーが書けるのを `objects/` と `refs/` などに限る

## テスト

Docker なしで動く結合テストがあります（git と、util-linux の flock、GNU coreutils か busybox の timeout が必要。macOS ではそのままでは動きません）。

```sh
sh test/run.sh
```

コンテナを使った e2e テストもあります（Docker だけが必要）。イメージ自身を「GitHub」（SSH の git サーバー）とクライアントにも使い、本物の entrypoint・sshd・unlock を通して確認します。

```sh
docker build -t git-push-gate:test .
sh test/e2e.sh
```

## ライセンス

MIT
