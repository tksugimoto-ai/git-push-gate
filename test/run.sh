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
git --git-dir=gate.git config gate.protected "main develop"   # 以下 3 つは entrypoint.sh が書き込むもの
git --git-dir=gate.git config receive.fsckObjects true
git --git-dir=gate.git config receive.denyDeleteCurrent ignore
git --git-dir=gate.git config receive.autogc false
# ローカル転送だと quarantine 用の環境変数が上流に漏れるので外す（SSH 越しの GitHub では不要）
git --git-dir=gate.git config remote.upstream.receivepack \
  'env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES git-receive-pack'
cp "$ROOT/hooks/pre-receive" gate.git/hooks/pre-receive
cat > rp <<RP
#!/bin/sh
export SSH_ORIGINAL_COMMAND="git-receive-pack 'repo.git'" GIT_PUSH_GATE_REPO="$T/gate.git"
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
  if [ "$got" = ng ] && ! grep -Eq 'git-push-gate:|\[rejected\]|fsck error' "$T/out"; then got=error; fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "ok   $desc"
  else fail=$((fail+1)); echo "FAIL $desc (expected $want)"; sed 's/^/     /' "$T/out"; fi
}
gh_has() { git --git-dir="$T/gh.git" rev-parse -q --verify "refs/heads/$1" >/dev/null; }
wf() { # ブランチを main から切ってワークフローを書き換え
  git switch -qC "$1" origin/main; printf '%s\n' "$2" > .github/workflows/ci.yml; git commit -qam "$1"
}
human() { # 人間がホストから GitHub に直接 push する（ゲートを通らない）
  ( cd "$T/seed" && git fetch -q && git switch -qC "$1" "origin/${2:-main}" && sh -c "$3" && git add -A \
    && git commit -qm "$1" && git push -q origin "$1" )
  git fetch -q
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

# ワークフローは保護ブランチのどれか 1 つと同一のものだけ（消すのは可）。中身は見ない
wf w1 "on: pull_request";                                          expect ng "ワークフローの変更" origin w1
git switch -qC w2 origin/main; echo 'on: push' > .github/workflows/new.yml; git add -A; git commit -qm w2
expect ng "ワークフローの追加" origin w2
git switch -qC w3 origin/main; echo 'on: push' > ".github/workflows/$(printf '\303\251').yml"; git add -A; git commit -qm w3
expect ng "ASCII 以外を含む名前のワークフローの追加" origin w3
git switch -qC w4 origin/main; git rm -q .github/workflows/ci.yml; git commit -qm w4
expect ok "ワークフローの削除" origin w4
git switch -qC w5 origin/main; git mv .github/workflows/ci.yml .github/workflows/ci2.yml; git commit -qm w5
expect ng "ワークフローの名前の変更" origin w5
git switch -qC w6 origin/main; chmod +x .github/workflows/ci.yml; git commit -qam w6
expect ng "ワークフローの実行権限の変更" origin w6
git switch -qC w7 origin/main; git rm -rq .github/workflows; mkdir -p wfdir
printf 'on: pull_request_target\npermissions: write-all\njobs: {}\n' > wfdir/x.yml; ln -s ../wfdir .github/workflows
git add -A; git commit -qm w7;                                     expect ng ".github/workflows がシンボリックリンク" origin w7
git switch -qC w8 origin/main; git rm -rq .github; mkdir -p gh/workflows; echo 'on: push' > gh/workflows/x.yml; ln -s gh .github
git add -A; git commit -qm w8;                                     expect ng ".github がシンボリックリンク" origin w8
git switch -qC w9 origin/main; mkdir -p .github/workflows/sub; echo 'on: push' > .github/workflows/sub/x.yml; git add -A; git commit -qm w9
expect ng "サブディレクトリへのワークフローの追加" origin w9
git switch -qC w10 origin/main; mkdir -p .GITHUB/workflows; echo 'on: push' > .GITHUB/workflows/y.yml; git add -A; git commit -qm w10
expect ng "大文字の .GITHUB" origin w10
git switch -qC w11 origin/main; mkdir -p .github/Workflows; echo 'on: push' > .github/Workflows/x.yml; git add -A; git commit -qm w11
expect ng "大文字の .github/Workflows" origin w11
git switch -qC w12 origin/main; git rm -rq .github/actions; ln -s ../x .github/actions; git add -A; git commit -qm w12
expect ng ".github/actions がシンボリックリンク" origin w12
# 並びの壊れた木（zzz の後ろに .github）。ls-tree に .github が見えないので、fsck で止める
command -v python3 >/dev/null || { echo "FAIL このテストには python3 が必要です"; exit 1; }
bad=$(python3 - "$(git rev-parse origin/main:.github)" "$(git hash-object -w --stdin </dev/null)" <<'PY' | git hash-object -t tree -w --literally --stdin
import sys
gh, empty = (bytes.fromhex(x) for x in sys.argv[1:])
sys.stdout.buffer.write(b"100644 zzz\0" + empty + b"40000 .github\0" + gh)
PY
)
[ "$bad" != 4b825dc642cb6eb9a060e54bf8d69288fbee4904 ] || { echo "FAIL 並びの壊れた木を作れませんでした"; exit 1; }
expect ng "並びの壊れた木" origin "$(git commit-tree "$bad" -p origin/main -m w13):refs/heads/w13"   # 作業ツリーには取り出さない
git --git-dir="$T/gate.git" config receive.fsckObjects false
git switch -qC w14 origin/main; echo f > f; git add f; git commit -qm w14
expect ng "fsck が無効なゲート" origin w14
git --git-dir="$T/gate.git" config receive.fsckObjects true
# 複数の ref を 1 回で push したとき、1 つでも拒否なら何も GitHub に届かない
git switch -qC multi origin/main; echo m > m; git add m; git commit -qm multi
expect ng "正常な ref と main を同時に push" origin multi HEAD:main
if gh_has multi; then fail=$((fail+1)); echo "FAIL 拒否された push の一部が GitHub に届いた"; else pass=$((pass+1)); echo "ok   拒否された push は一部も GitHub に届かない"; fi
# 人間がワークフローを変えたブランチには、エージェントは push できない（人間がワークフローを試すブランチを守る）
human hw main "printf 'on: pull_request\n' > .github/workflows/ci.yml"
git switch -qC hw origin/hw; echo c > c; git add c; git commit -qm c
expect ng "人間が変更したワークフローのブランチへの push（人間がワークフローを試すブランチを守る）" origin hw
git rebase -q --onto origin/hw HEAD~1; git commit -q --allow-empty -m e
expect ng "人間が変更したワークフローのブランチへの強制 push" --force origin hw
printf 'on: [push]\n' > .github/workflows/ci.yml; git commit -qam hw2
expect ng "人間が変更したワークフローの書き換え" origin hw
git reset -q --hard origin/hw
expect ng "人間が変更したワークフローを別のブランチへ" origin hw:refs/heads/hw-copy
human ha main "echo z >> .github/actions/a/action.yml"
git switch -qC ha origin/ha; echo c > c; git add c; git commit -qm c
expect ng "人間が変更した .github/actions のブランチへの push" origin ha
# 名前を間違えた保護ブランチ
git --git-dir="$T/gate.git" config gate.protected "main develop nosuch"
git switch -qC typo origin/main; echo t > t; git add t; git commit -qm typo
expect ng "GitHub にない保護ブランチ" origin typo
git --git-dir="$T/gate.git" config gate.protected "main develop"
# 紛らわしいブランチ名
git switch -qC odd origin/main; echo o > o; git add o; git commit -qm odd
expect ng "HEAD という名前のブランチ" origin odd:refs/heads/HEAD
expect ng "大文字だけが違う保護ブランチ（Main）" origin odd:refs/heads/Main
expect ng "refs/ で始まるブランチ名" origin odd:refs/heads/refs/tags/v1
# 保護ブランチの一覧が空白だけ
git --git-dir="$T/gate.git" config gate.protected " "
expect ng "保護ブランチの一覧が空のときの削除" origin :develop
git --git-dir="$T/gate.git" config gate.protected "main develop"
expect ng "- で始まるブランチ名" origin odd:refs/heads/-x
expect ng "+ で始まるブランチ名" origin odd:refs/heads/+x
expect ng "@ という名前のブランチ" origin odd:refs/heads/@
expect ng "40 桁の 16 進数のブランチ名" origin "odd:refs/heads/$(git rev-parse HEAD)"
# デフォルトブランチ（main）が保護ブランチに入っていない
git --git-dir="$T/gate.git" config gate.protected "develop"
expect ng "デフォルトブランチが保護されていない" origin odd:refs/heads/odd2
git --git-dir="$T/gate.git" config gate.protected "main develop"
# フックに不正な形式の行が渡ったとき（receive-pack は ref 名を検査する前にフックへ渡す）
if printf 'x refs/heads/main refs/heads/evil\n' | (cd "$T/gate.git" && GIT_DIR=. sh "$ROOT/hooks/pre-receive") >"$T/out" 2>&1 \
   || ! grep -q '不正な更新の指定' "$T/out"
then fail=$((fail+1)); echo "FAIL 不正な形式の行は拒否"; sed 's/^/     /' "$T/out"; else pass=$((pass+1)); echo "ok   不正な形式の行は拒否"; fi
# ref 名の末尾に空白がある行（read で区切ると取り除かれ、整えた名前で GitHub に push してしまう）
if printf '%s %s refs/heads/trail \n' 0000000000000000000000000000000000000000 "$(git rev-parse origin/main)" \
   | (cd "$T/gate.git" && GIT_DIR=. sh "$ROOT/hooks/pre-receive") >"$T/out" 2>&1 || ! grep -q '不正な更新の指定' "$T/out" || gh_has trail
then fail=$((fail+1)); echo "FAIL 末尾に空白のある行は拒否"; sed 's/^/     /' "$T/out"; else pass=$((pass+1)); echo "ok   末尾に空白のある行は拒否"; fi
git switch -qC act origin/main; echo y >> .github/actions/a/action.yml; git commit -qam act
expect ng ".github/actions の変更" origin act
git switch -qC co origin/main; echo "* @me" > .github/CODEOWNERS; git add -A; git commit -qm co
expect ok "CODEOWNERS の変更" origin co

# 複数の保護ブランチの版を 1 つのコミットで混ぜる（develop にだけあるワークフローと、main の .github/actions）
( cd "$T/seed" && git fetch -q && git switch -qC dv origin/develop && echo 'on: push' > .github/workflows/dev-only.yml \
  && echo dv >> .github/actions/a/action.yml && git add -A && git commit -qm dv && git push -q origin HEAD:develop )
git fetch -q
git switch -qC mix origin/main; git checkout -q origin/develop -- .github/workflows/dev-only.yml; git commit -qm mix
expect ng "main と develop の版を混ぜたコミット" origin mix
git switch -qC dvok origin/develop; echo d > d; git add d; git commit -qm dvok
expect ok "develop の内容そのままのコミット" origin dvok
# 2 回に分けても混ぜられない（develop の内容のブランチに、main の .github/actions を載せる）
git checkout -q origin/main -- .github/actions; git commit -qm mix2
expect ng "2 回に分けて main と develop の版を混ぜる" origin dvok
# 人間が main と develop のワークフローを直した後、古い版を持つ既存のブランチ
git switch -qC stale origin/main; echo s > s; git add s; git commit -qm stale
expect ok "古い版になる前のブランチの作成" origin stale
( cd "$T/seed" && git fetch -q && for b in main develop; do git switch -qC "fix-$b" "origin/$b" \
  && printf 'on: push\n# fixed\n' > .github/workflows/ci.yml && git commit -qam "fix $b" && git push -q origin "HEAD:$b"; done )
git fetch -q
echo s2 >> s; git commit -qam stale2
# 古い版を持つ既存のブランチにも push できない（main に rebase すれば通る）
expect ng "人間が main を直した後の、古い版を持つ既存のブランチへの push" origin stale
old_stale=$(git rev-parse HEAD)
git rebase -q origin/main
expect ok "main に rebase した後の push" --force origin stale
# 古い版を新しいブランチに写すのも拒否
expect ng "古い版を持つ新しいブランチ" origin "$old_stale:refs/heads/stale-copy"
# ブランチにはコミットだけ（注釈付きタグのオブジェクトは拒否）
git tag -a -m t tobj origin/main
expect ng "注釈付きタグのオブジェクトをブランチに" origin "$(git rev-parse tobj):refs/heads/tagobj"
# 受け付けを始めた後に、GitHub の保護ブランチが更新された（push の途中で止めて、古い状態で判定させる手口）
git switch -qC race origin/main; echo r > r; git add r; git commit -qm race
( cd "$T/seed" && git fetch -q && git switch -qC fix2 origin/main && echo '# fix2' >> .github/workflows/ci.yml \
  && git commit -qam fix2 && git push -q origin HEAD:main )   # ゲートはまだ fetch していない
if printf '%s %s refs/heads/race\n' 0000000000000000000000000000000000000000 "$(git rev-parse race)" \
   | (cd "$T/gate.git" && GIT_DIR=. sh "$ROOT/hooks/pre-receive") >"$T/out" 2>&1 || ! grep -q '受け付けを始めた後に GitHub で更新' "$T/out" || gh_has race
then fail=$((fail+1)); echo "FAIL 受け付けの途中で保護ブランチが更新されたら拒否"; sed 's/^/     /' "$T/out"; else pass=$((pass+1)); echo "ok   受け付けの途中で保護ブランチが更新されたら拒否"; fi
git fetch -q; git --git-dir="$T/gate.git" fetch -q --prune upstream '+refs/heads/*:refs/heads/*'
# 制御文字を含む行（記録に端末の制御シーケンスを書き込ませない）
if printf '%s %s refs/heads/x\033[2Kx\n' 0000000000000000000000000000000000000000 "$(git rev-parse origin/main)" \
   | (cd "$T/gate.git" && GIT_DIR=. sh "$ROOT/hooks/pre-receive") >"$T/out" 2>&1 || ! grep -q '制御文字' "$T/out" \
   || LC_ALL=C grep -q "$(printf '\033')" "$T/gate.git/push-gate.log"
then fail=$((fail+1)); echo "FAIL 制御文字を含む行は、記録に書かずに拒否"; sed 's/^/     /' "$T/out"; else pass=$((pass+1)); echo "ok   制御文字を含む行は、記録に書かずに拒否"; fi
# push 以外のコマンドも記録する
SSH_ORIGINAL_COMMAND="$(printf 'ls \033[2K')" GIT_PUSH_GATE_REPO="$T/gate.git" sh "$ROOT/bin/git-push-gate" >/dev/null 2>&1 || true
if grep -q 'REJECTED 許可されていないコマンド' "$T/gate.git/push-gate.log" && ! LC_ALL=C grep -q "$(printf '\033')" "$T/gate.git/push-gate.log"
then pass=$((pass+1)); echo "ok   push 以外のコマンドを、中身を書かずに記録"; else fail=$((fail+1)); echo "FAIL push 以外のコマンドを、中身を書かずに記録"; fi
# 許可する接頭辞
git --git-dir="$T/gate.git" config gate.allowedPrefixes "agent/ claude/"
git switch -qC pfx origin/main; echo p > p; git add p; git commit -qm pfx
expect ng "許可されていない接頭辞のブランチ" origin pfx
expect ok "許可された接頭辞のブランチ" origin pfx:refs/heads/agent/pfx
expect ng "許可されていない接頭辞のブランチの削除" origin :stale
git --git-dir="$T/gate.git" config --unset gate.allowedPrefixes
# UTF-8 の C1 制御文字（U+009B は CSI）や、表示の向きを変える文字（U+202E）を含む名前は、記録に書かずに拒否
git switch -qC u8 origin/main; echo u > u; git add u; git commit -qm u8
expect ng "C1 制御文字を含む名前" origin "u8:refs/heads/ok$(printf '\302\233')2J"
expect ng "表示の向きを変える文字を含む名前" origin "u8:refs/heads/x$(printf '\342\200\256')/niaM"
if LC_ALL=C grep -q "$(printf '\302\233')\|$(printf '\342\200\256')" "$T/gate.git/push-gate.log"
then fail=$((fail+1)); echo "FAIL ASCII 以外の文字を記録に書かない"; else pass=$((pass+1)); echo "ok   ASCII 以外の文字を記録に書かない"; fi
# GitHub にある同じ名前のタグ（軽量タグと注釈付きタグ）
( cd "$T/seed" && git tag v9 origin/main && git tag -a -m t v8 origin/main && git push -q origin v9 v8 )
expect ng "軽量タグと同じ名前のブランチ" origin u8:v9
expect ng "注釈付きタグと同じ名前のブランチ" origin u8:refs/heads/v8
expect ok "タグと違う名前のブランチ" origin u8:refs/heads/v7
# 後から同じ名前のタグができたブランチは、更新はできないが、削除はできる
( cd "$T/seed" && git tag v7 origin/main && git push -q origin v7 )
expect ng "タグと同じ名前になったブランチの更新" origin --force origin/main:refs/heads/v7
expect ok "タグと同じ名前になったブランチの削除" origin :refs/heads/v7
# 長すぎる ref 名は、記録に書かずに拒否
long=$(printf 'l%.0s' $(seq 300))
expect ng "255 バイトを超える ref 名" origin "u8:refs/heads/$long"
if grep -q "$long" "$T/gate.git/push-gate.log"
then fail=$((fail+1)); echo "FAIL 長すぎる ref 名を記録に書かない"; else pass=$((pass+1)); echo "ok   長すぎる ref 名を記録に書かない"; fi
# 1 回の push の ref の数は 50 まで
expect ng "51 個の ref を一度に push" origin $(for i in $(seq 51); do printf 'u8:refs/heads/many%s ' "$i"; done)
gh_has many1 && { fail=$((fail+1)); echo "FAIL 51 個のうちどれかが GitHub に届いた"; }
# 判定の間に GitHub の保護ブランチが更新された（ref を送り終える前に人間が main を直す）
# （最後の : は、dash が上の ( ) を fork せずに実行して、push の前にパイプを閉じてしまうのを防ぐ）
# （ゲートにあるコミットを使う。フックを直接呼ぶので、新しいオブジェクトは渡せない）
{ printf '%s %s refs/heads/race2\n' 0000000000000000000000000000000000000000 "$(git rev-parse origin/main)"; sleep 3
  ( cd "$T/seed" && git fetch -q && git switch -qC fix3 origin/main && echo '# fix3' >> .github/workflows/ci.yml \
    && git commit -qam fix3 && git push -q origin HEAD:main ) >/dev/null 2>&1
  : ; } \
  | (cd "$T/gate.git" && GIT_DIR=. sh "$ROOT/hooks/pre-receive") >"$T/out" 2>&1 && rc=0 || rc=1
if [ $rc -eq 0 ] || ! grep -q '受け付けを始めた後に GitHub で更新' "$T/out" || gh_has race2
then fail=$((fail+1)); echo "FAIL 判定の間に保護ブランチが更新されたら拒否"; sed 's/^/     /' "$T/out"; else pass=$((pass+1)); echo "ok   判定の間に保護ブランチが更新されたら拒否"; fi
git fetch -q; git --git-dir="$T/gate.git" fetch -q --prune upstream '+refs/heads/*:refs/heads/*'

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

L="$T/gate.git/push-gate.log"
if grep -v ' REJECTED ' "$L" | grep -q ' refs/heads/feat ' && ! grep -v ' REJECTED ' "$L" | grep -q 'refs/heads/main' \
   && grep ' REJECTED ' "$L" | grep -q 'refs/heads/main への push は禁止'
then pass=$((pass+1)); echo "ok   受け付けた更新と拒否を記録"; else fail=$((fail+1)); echo "FAIL 受け付けた更新と拒否を記録"; sed 's/^/     /' "$L"; fi
# 記録が 10MB を超えたら、拒否は書かない
cp "$L" "$T/log.bak"; head -c 10485760 /dev/zero | tr '\0' x >> "$L"; size=$(wc -c < "$L")
expect ng "記録が大きいときの main への push" origin HEAD:main
SSH_ORIGINAL_COMMAND=ls GIT_PUSH_GATE_REPO="$T/gate.git" sh "$ROOT/bin/git-push-gate" >"$T/out" 2>&1 || true
if [ "$(wc -c < "$L")" -eq "$size" ]; then pass=$((pass+1)); echo "ok   記録が 10MB を超えたら拒否を書かない"; else fail=$((fail+1)); echo "FAIL 記録が 10MB を超えたら拒否を書かない"; fi
mv "$T/log.bak" "$L"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
