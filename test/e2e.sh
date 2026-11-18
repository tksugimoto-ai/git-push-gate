#!/bin/sh
# コンテナを使った e2e テスト。必要なのは Docker だけ。
# イメージ自身を「GitHub」（SSH の git サーバー）とクライアントにも使い、本物の entrypoint・sshd を通す。
#   docker build -t git-push-gate:test . && sh test/e2e.sh
set -eu
IMAGE="${IMAGE:-git-push-gate:test}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
P="gpg-e2e-$$"            # コンテナ名・ネットワーク名の接頭辞
T=$(mktemp -d)
NET="$P-net"

cleanup() {
  docker rm -f "$P-github" "$P-gate" "$P-dev" >/dev/null 2>&1 || true
  docker volume rm -f "$P-data" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  # コンテナ内で root が作ったファイルを消す
  docker run --rm -v "$T:/w" --entrypoint sh "$IMAGE" -c 'rm -rf /w/* /w/.[!.]*' >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

# イメージの中でコマンドを実行する（$T を /w にマウント。RUN_NET でネットワークを変えられる）
run() {
  docker run --rm --network "${RUN_NET:-$NET}" -v "$T:/w" --entrypoint sh \
    -e GIT_AUTHOR_NAME=t -e GIT_AUTHOR_EMAIL=t@example.com -e GIT_COMMITTER_NAME=t -e GIT_COMMITTER_EMAIL=t@example.com \
    "$IMAGE" -c "$1"
}
# クライアントの ssh（鍵と known_hosts をそのまま指定）
GSSH='ssh -i /w/client/id_ed25519 -o "UserKnownHostsFile=/w/config/known_hosts /w/client/known_hosts_gate"'

pass=0; fail=0
check() { # check 説明 条件（$T/out に出力を書くと、失敗時に表示する）
  : > "$T/out"
  if eval "$2"; then pass=$((pass+1)); echo "ok   $1"
  else fail=$((fail+1)); echo "FAIL $1"; sed 's/^/     /' "$T/out"; fi
}

docker network create "$NET" >/dev/null
mkdir -p "$T/config" "$T/client" "$T/github"
cp "$ROOT/test/e2e-github.sh" "$T/github/start.sh"

# 鍵: GitHub 用（パスフレーズなし・付き）、クライアント用
run 'ssh-keygen -q -t ed25519 -N "" -C gate -f /w/github_key_plain
     ssh-keygen -q -t ed25519 -N secret -C gate-pp -f /w/github_key_pp
     ssh-keygen -q -t ed25519 -N "" -C client -f /w/client/id_ed25519
     cat /w/github_key_plain.pub /w/github_key_pp.pub > /w/github/authorized_keys
     cp /w/client/id_ed25519.pub /w/github/client.pub
     cp /w/client/id_ed25519.pub /w/config/client_keys.pub'

# 「GitHub」: ネットワーク上の名前は github.com
docker run -d --name "$P-github" --network "$NET" --network-alias github.com \
  -v "$T/github:/github:ro" --entrypoint sh "$IMAGE" /github/start.sh >/dev/null

wait_ssh() { # wait_ssh ホスト名 コンテナ → known_hosts の行を出力
  run "for i in \$(seq 30); do ssh-keyscan -t ed25519 $1 2>/dev/null | grep . && exit 0; sleep 1; done; exit 1" \
    || { echo "$1 の sshd が起動しません" >&2; docker logs "$2" >&2; exit 1; }
}
wait_ssh github.com "$P-github" > "$T/config/known_hosts"

start_gate() { # start_gate 鍵ファイル名 [追加の docker run 引数...]
  key=$1; shift
  docker rm -f "$P-gate" >/dev/null 2>&1 || true
  run "cp /w/$key /w/config/github_key && cp /w/$key.pub /w/config/github_key.pub"
  docker run -d --name "$P-gate" --network "$NET" --network-alias gate \
    -e UPSTREAM=git@github.com:repo.git -v "$T/config:/config:ro" -v "$P-data:/srv/git" \
    "$@" "$IMAGE" >/dev/null
  wait_ssh gate "$P-gate" > "$T/client/known_hosts_gate"
}

# クライアント（devcontainer 相当）。fetch は「GitHub」から直接、push はゲートへ。
client() {
  run "set -e; export GIT_SSH_COMMAND='$GSSH'
    git clone -q git@github.com:repo.git /tmp/dev && cd /tmp/dev
    git remote set-url --push origin ssh://git@gate/repo.git
    $1" >"$T/out" 2>&1
}
gh_has() { docker exec "$P-github" git --git-dir=/home/git/repo.git rev-parse -q --verify "refs/heads/$1" >/dev/null; }
commit() { echo "echo $1 > $1 && git add $1 && git commit -qm $1"; }

gate_has() { docker exec "$P-gate" git --git-dir=/srv/git/repo.git rev-parse -q --verify "refs/heads/$1" >/dev/null; }
# --- パスフレーズなしの鍵 ---
start_gate github_key_plain
check "起動時に GitHub を fetch している" 'gate_has develop'

check "feature ブランチの push が GitHub に届く" \
  'client "git switch -qc feat && $(commit a) && git push -q origin feat" && gh_has feat'
check "main への push は拒否" \
  '! client "$(commit b) && git push -q origin HEAD:main" && grep -q git-push-gate: "$T/out"'
check "ワークフローの変更は拒否" \
  '! client "echo \"# x\" >> .github/workflows/ci.yml && git commit -qam wf && git push -q origin HEAD:refs/heads/wf" && grep -q git-push-gate: "$T/out" && ! gh_has wf'
check "任意のコマンドは拒否" \
  '! run "$GSSH git@gate cat /etc/passwd" >"$T/out" 2>&1 && grep -q 許可されていません "$T/out" && ! grep -q root: "$T/out"'
check "ゲートからの clone（upload-pack）は拒否" \
  '! run "GIT_SSH_COMMAND='"'"'$GSSH'"'"' git clone -q ssh://git@gate/repo.git /tmp/x" >"$T/out" 2>&1 && grep -q 許可されていません "$T/out"'
check "登録されていない鍵は拒否" \
  '! run "ssh-keygen -q -t ed25519 -N \"\" -f /tmp/k && ssh -i /tmp/k -o BatchMode=yes -o UserKnownHostsFile=/w/client/known_hosts_gate git@gate git-receive-pack /repo.git" >"$T/out" 2>&1 && grep -q "Permission denied" "$T/out"'

docker restart "$P-gate" >/dev/null
wait_ssh gate "$P-gate" >/dev/null
check "再起動後も push できる" \
  'client "git switch -qc feat2 && $(commit c) && git push -q origin feat2" && gh_has feat2'

# compose を使わない devcontainer（既定の bridge で名前解決なし）から、ホストに公開したポート経由で push
cp "$T/client/known_hosts_gate" "$T/known_hosts_gate_before"
GW=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')
start_gate github_key_plain -p "$GW::22"
check "コンテナを作り直してもホスト鍵が変わらない" 'cmp "$T/client/known_hosts_gate" "$T/known_hosts_gate_before"'
PORT=$(docker port "$P-gate" 22/tcp | sed 's/.*://' | head -n1)
check "既定の bridge からゲートウェイ経由で push できる" 'RUN_NET=bridge run "set -e
    h=\$(ip route | awk \"/default/{print \\\$3}\")
    git init -q -b bridge /tmp/d && cd /tmp/d && $(commit x)
    GIT_SSH_COMMAND='"'"'$GSSH -o HostKeyAlias=gate'"'"' git push -q ssh://git@\$h:$PORT/repo.git bridge" >"$T/out" 2>&1 && gh_has bridge'

# client/setup.sh: devcontainer に見立てたコンテナの中で実行し、push 先をゲートに向ける
docker run -d --name "$P-dev" --network "$NET" -v "$ROOT/client:/client:ro" \
  --entrypoint sh "$IMAGE" -c 'adduser -D -u 1001 dev && sleep 1000000' >/dev/null
until docker exec "$P-dev" id dev >/dev/null 2>&1; do sleep 1; done
docker exec -u dev "$P-dev" sh -c "mkdir /home/dev/ws && cd /home/dev/ws && git init -q -b viasetup &&
  git remote add origin https://github.invalid/repo.git && $(commit x | sed 's/git commit/git -c user.name=t -c user.email=t@example.com commit/')"
hostkey=$(docker exec "$P-gate" cat /srv/git/ssh_host_keys/ssh_host_ed25519_key.pub)
setup() { docker exec -u dev -w /home/dev/ws "$P-dev" sh /client/setup.sh gate 22 "$hostkey"; }
check "setup.sh が公開鍵を表示する" 'setup >"$T/out" 2>&1 && grep -q "^ssh-ed25519 .* git-push-gate-client$" "$T/out"'
pub=$(grep '^ssh-ed25519 .* git-push-gate-client$' "$T/out")
check "公開鍵を登録する前は push できない" \
  '! docker exec -u dev -w /home/dev/ws "$P-dev" git push -q origin viasetup >"$T/out" 2>&1 && ! gh_has viasetup'
run "echo '$pub' >> /w/config/client_keys.pub"
docker restart "$P-gate" >/dev/null; wait_ssh gate "$P-gate" >/dev/null
check "公開鍵を登録した後は、setup.sh で設定した devcontainer から push できる" \
  'docker exec -u dev -w /home/dev/ws "$P-dev" git push -q origin viasetup >"$T/out" 2>&1 && gh_has viasetup'
check "setup.sh を 2 回実行しても、鍵を作り直さず、設定も重複しない" \
  'setup >"$T/out" 2>&1 && grep -qF "$pub" "$T/out" &&
   [ "$(docker exec -u dev "$P-dev" grep -c git-push-gate.conf /home/dev/.ssh/config)" = 1 ]'
check "setup.sh は不正なホスト鍵を拒否する" \
  '! docker exec -u dev -w /home/dev/ws "$P-dev" sh /client/setup.sh gate 22 "ssh-rsa AAAA" >"$T/out" 2>&1'
docker rm -f "$P-dev" >/dev/null

# --- パスフレーズ付きの鍵 ---
start_gate github_key_pp -e UNLOCK_LIFETIME=1h
# ゲートの起動後に「GitHub」だけにブランチを作る（unlock の後の fetch で入るはず）
docker exec "$P-github" git --git-dir=/home/git/repo.git branch fromgh main
check "unlock の前はまだ fetch していない" '! gate_has fromgh'

check "unlock 前の push は「ロックされています」で拒否" \
  '! client "git switch -qc feat3 && $(commit d) && git push -q origin feat3" && grep -q ロックされています "$T/out" && ! gh_has feat3'
# 人間の unlock（パスフレーズは SSH_ASKPASS で渡す）
docker exec "$P-gate" sh -c 'printf "#!/bin/sh\necho secret\n" > /tmp/askpass && chmod 755 /tmp/askpass'
check "unlock" \
  'docker exec -e SSH_ASKPASS=/tmp/askpass -e SSH_ASKPASS_REQUIRE=force "$P-gate" unlock >"$T/out" 2>&1'
check "unlock の後に GitHub を fetch している" 'gate_has fromgh'
check "unlock 後の push が GitHub に届く" \
  'client "git switch -qc feat3 && $(commit d) && git push -q origin feat3" && gh_has feat3'
check "unlock 後も develop への push は拒否" \
  '! client "$(commit e) && git push -q origin HEAD:develop" && grep -q git-push-gate: "$T/out"'
check "push した更新が記録されている" 'docker exec "$P-gate" grep -q " refs/heads/feat3 " /srv/git/repo.git/push-gate.log'
check "鍵がエージェントに読み込まれている" \
  'docker exec "$P-gate" su -s /bin/sh git -c "SSH_AUTH_SOCK=/run/git-push-gate/agent.sock ssh-add -l" | grep -q gate-pp'

# コンテナを再起動すると、またロックされる（ssh-agent はコンテナの中にあるため）
docker restart "$P-gate" >/dev/null
wait_ssh gate "$P-gate" >/dev/null
check "再起動の後は、またロックされている" \
  '! client "git switch -qc feat4 && $(commit f) && git push -q origin feat4" && grep -q ロックされています "$T/out" && ! gh_has feat4'
# UNLOCK_LIFETIME が過ぎると、自動でロックされる
start_gate github_key_pp -e UNLOCK_LIFETIME=20
docker exec "$P-gate" sh -c 'printf "#!/bin/sh\necho secret\n" > /tmp/askpass && chmod 755 /tmp/askpass'
check "UNLOCK_LIFETIME を短くして unlock" \
  'docker exec -e SSH_ASKPASS=/tmp/askpass -e SSH_ASKPASS_REQUIRE=force "$P-gate" unlock >"$T/out" 2>&1'
check "UNLOCK_LIFETIME の間は push できる" \
  'client "git switch -qc feat5 && $(commit g) && git push -q origin feat5" && gh_has feat5'
sleep 22
check "UNLOCK_LIFETIME が過ぎると、またロックされる" \
  '! client "git switch -qc feat6 && $(commit h) && git push -q origin feat6" && grep -q ロックされています "$T/out" && ! gh_has feat6'

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
