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
git switch -qC act origin/main; echo y >> .github/actions/a/action.yml; git commit -qam act
expect ng ".github/actions の変更" origin act
git switch -qC co origin/main; echo "* @me" > .github/CODEOWNERS; git add -A; git commit -qm co
expect ok "CODEOWNERS の変更" origin co

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
