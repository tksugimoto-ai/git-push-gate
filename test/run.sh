#!/bin/sh
# Docker なしで動く結合テスト。ローカルの bare リポジトリを GitHub に見立て、
# SSH の代わりに --receive-pack で git-push-gate を直接起動する。
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir -p "$HOME"; git config --global init.defaultBranch main; git config --global advice.detachedHead false
cd "$T"

# 「GitHub」
git init -q --bare gh.git
git clone -q gh.git seed 2>/dev/null
( cd seed && mkdir -p .github/workflows .github/actions/a \
  && printf 'on: push\n' > .github/workflows/ci.yml && echo x > .github/actions/a/action.yml \
  && git add -A && git commit -qm init && git push -q origin main main:develop )

# ゲート側のリポジトリ（entrypoint.sh 相当）
git init -q --bare gate.git
git --git-dir=gate.git config remote.upstream.url "$T/gh.git"
git --git-dir=gate.git config gate.protected "main develop"   # entrypoint.sh が書き込むもの
# ローカル転送だと quarantine 用の環境変数が上流に漏れるので外す（SSH 越しの GitHub では不要）
git --git-dir=gate.git config remote.upstream.receivepack \
  'env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES git-receive-pack'
cp "$ROOT/hooks/pre-receive" gate.git/hooks/pre-receive
cat > rp <<RP
#!/bin/sh
export SSH_ORIGINAL_COMMAND="git-receive-pack 'repo.git'" GIT_PUSH_GATE_REPO="$T/gate.git" \
  GIT_PUSH_GATE_CHECK="$ROOT/hooks/check-workflows.mjs"
exec "$ROOT/bin/git-push-gate"
RP
chmod +x rp

# 開発環境（fetch は「GitHub」、push はゲート）
git clone -q gh.git dev
cd dev
git remote set-url --push origin "$T/gate.git"
git config remote.origin.receivepack "$T/rp"
git config push.negotiate false

pass=0; fail=0
expect() { # expect ok|ng 説明 push引数...
  want=$1; desc=$2; shift 2
  if git push "$@" >"$T/out" 2>&1; then got=ok; else got=ng; fi
  # 拒否はゲートか git の正規の拒否によるものに限る（別の理由での失敗を見逃さない）
  if [ "$got" = ng ] && ! grep -Eq 'git-push-gate:|\[rejected\]' "$T/out"; then got=error; fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "ok   $desc"
  else fail=$((fail+1)); echo "FAIL $desc (expected $want)"; sed 's/^/     /' "$T/out"; fi
}
gh_has() { git --git-dir="$T/gh.git" rev-parse -q --verify "refs/heads/$1" >/dev/null; }
wf() { # ブランチを main から切ってワークフローを書き換え
  git switch -qC "$1" origin/main; printf '%s\n' "$2" > .github/workflows/ci.yml; git commit -qam "$1"
}

git switch -qc feat; echo a > a; git add a; git commit -qm a
expect ok "feature ブランチの新規作成" origin feat
gh_has feat || { echo "FAIL GitHub に feat がない"; fail=$((fail+1)); }
expect ng "main への push" origin HEAD:main
expect ng "develop への push" origin feat:develop
expect ng "main の削除" origin :main
expect ng "タグ" origin HEAD:refs/tags/v1

# 人間が GitHub 側で feat を進めた
( cd "$T/seed" && git fetch -q && git switch -qc feat origin/feat && echo h > h && git add h \
  && git commit -qm human && git push -q origin feat )
echo b > b; git add b; git commit -qm b
expect ng "GitHub 側が先行しているときの通常 push" origin feat
git fetch -q; git rebase -q origin/feat
expect ok "取り込んだ後の push" origin feat
git commit -q --amend -m b2
expect ok "強制 push" --force origin feat
expect ok "feature ブランチの削除" origin :feat

OK='on: [push, pull_request]
permissions:
  contents: read
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm test'
wf w1 "$OK";                                                       expect ok "安全なワークフロー" origin w1
wf w2 "on: push
jobs:
  t:
    runs-on: ubuntu-latest
    steps: [{run: echo}]";                                         expect ng "permissions 省略" origin w2
wf w3 "$(echo "$OK" | sed 's/^  test:/  test:\n    permissions: {contents: write}/')"; expect ng "job で write" origin w3
wf w4 "$(echo "$OK" | sed 's/npm test/echo ${{ secrets.TOKEN }}/')"; expect ng "secrets 参照" origin w4
wf w5 "$(echo "$OK" | sed 's/ubuntu-latest/[self-hosted]/')";    expect ng "self-hosted ランナー" origin w5
wf w6 "$(echo "$OK" | sed 's/^on: .*/on: pull_request_target/')"; expect ng "pull_request_target" origin w6
wf w7 "$OK
permissions: write-all";                                           expect ng "重複キー" origin w7
wf w8 "$(echo "$OK" | sed 's/^permissions:/x: \&p write-all\npermissions:/')"; expect ng "アンカー" origin w8
git switch -qC w9 origin/main; printf 'on: pull_request_target\npermissions: write-all\njobs: {}\n' > ".github/workflows/$(printf '\303\251').yml"
git add -A; git commit -qm w9;                                     expect ng "ASCII 以外を含むファイル名" origin w9
# YAML の書き方でポリシーを回避しようとするもの
wf w10 "$(echo "$OK" | sed 's/npm test/"echo ${{ toJSON(\\x73ecrets) }}"/')"; expect ng "エスケープで書いた secrets" origin w10
wf w11 "%YAML 1.1
---
$(echo "$OK" | sed 's/^on: .*/on: pull_request_target/')";        expect ng "YAML 1.1 のディレクティブ" origin w11
wf w12 "$(echo "$OK" | sed 's/^on: .*/On: pull_request_target/')"; expect ng "大文字の On:" origin w12
wf w13 "$(echo "$OK" | sed 's/^on: .*/on: Pull_Request_Target/')"; expect ng "大文字を混ぜたトリガー名" origin w13
wf w14 "$(echo "$OK" | sed 's/^jobs:/Jobs:/; s/ubuntu-latest/self-hosted/')"; expect ng "大文字の Jobs:" origin w14
wf w15 "$(echo "$OK" | sed 's/runs-on: ubuntu-latest/Runs-On: self-hosted/')"; expect ng "大文字の Runs-On:" origin w15
wf w16 "on: push
permissions: {contents: read}
jobs:
  t:
    uses: evil/repo/.github/workflows/x.yml@main"; expect ng "外部の再利用可能なワークフロー" origin w16
wf w17 "on: push
permissions: {contents: read}
jobs:
  t:
    uses: ./.github/workflows/ci.yml";             expect ok "同じリポジトリの再利用可能なワークフロー" origin w17
git switch -qC w18 origin/main; git rm -rq .github/workflows; mkdir -p wfdir
printf 'on: pull_request_target\npermissions: write-all\njobs: {}\n' > wfdir/x.yml; ln -s ../wfdir .github/workflows
git add -A; git commit -qm w18;                                    expect ng ".github/workflows がシンボリックリンク" origin w18
# 名前を間違えた保護ブランチ
git --git-dir="$T/gate.git" config gate.protected "main develop nosuch"
git switch -qC typo origin/main; echo t > t; git add t; git commit -qm typo
expect ng "GitHub にない保護ブランチ" origin typo
git --git-dir="$T/gate.git" config gate.protected "main develop"
wf w19 "$(echo "$OK" | sed 's/ubuntu-latest/ubuntu-my-selfhosted/')"; expect ng "ubuntu- で始まる独自ラベル" origin w19
wf w20 "$(echo "$OK" | sed 's/ubuntu-latest/macos-15-xlarge/')";     expect ok "GitHub ホストのラベル（macos-15-xlarge）" origin w20
# 紛らわしいブランチ名
git switch -qC odd origin/main; echo o > o; git add o; git commit -qm odd
expect ng "HEAD という名前のブランチ" origin odd:refs/heads/HEAD
expect ng "大文字だけが違う保護ブランチ（Main）" origin odd:refs/heads/Main
expect ng "refs/ で始まるブランチ名" origin odd:refs/heads/refs/tags/v1
# 保護ブランチの一覧が空白だけ
git --git-dir="$T/gate.git" config gate.protected " "
expect ng "保護ブランチの一覧が空のときの削除" origin :develop
git --git-dir="$T/gate.git" config gate.protected "main develop"
git switch -qC act origin/main; echo y >> .github/actions/a/action.yml; git commit -qam act
expect ng ".github/actions の変更" origin act
git switch -qC co origin/main; echo "* @me" > .github/CODEOWNERS; git add -A; git commit -qm co
expect ok "CODEOWNERS の変更" origin co

# パスフレーズ付きの鍵が未解除のとき
if command -v ssh-agent >/dev/null; then
  eval "$(ssh-agent -a "$T/agent.sock")" >/dev/null
  git --git-dir="$T/gate.git" config gate.agentSocket "$T/agent.sock"
  git switch -qC locked origin/main; echo l > l; git add l; git commit -qm l
  expect ng "鍵のロック中" origin locked
  grep -q 'ロックされています' "$T/out" || { echo "FAIL ロックのメッセージがない"; fail=$((fail+1)); }
  ssh-keygen -q -t ed25519 -N '' -f "$T/k"; SSH_AUTH_SOCK="$T/agent.sock" ssh-add -q "$T/k" 2>/dev/null
  expect ok "鍵の解除後" origin locked
  git --git-dir="$T/gate.git" config --unset gate.agentSocket
  kill "$SSH_AGENT_PID"
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
