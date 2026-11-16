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

# イメージの中でコマンドを実行する（$T を /w にマウント）
run() { docker run --rm --network "$NET" -v "$T:/w" --entrypoint sh "$IMAGE" -c "$1"; }

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "ok   $1"; }
ng()   { fail=$((fail+1)); echo "FAIL $1"; [ -f "$T/out" ] && sed 's/^/     /' "$T/out"; return 0; }

docker network create "$NET" >/dev/null
mkdir -p "$T/config" "$T/client" "$T/github"
cp "$ROOT/test/e2e-github.sh" "$T/github/start.sh"

# 鍵: GitHub 用（パスフレーズなし・付き）、クライアント用
run 'ssh-keygen -q -t ed25519 -N "" -C gate -f /w/github_key_plain
     ssh-keygen -q -t ed25519 -N secret -C gate-pp -f /w/github_key_pp
     ssh-keygen -q -t ed25519 -N "" -C client -f /w/client/id_ed25519
     cat /w/github_key_plain.pub /w/github_key_pp.pub > /w/github/authorized_keys
     cp /w/client/id_ed25519.pub /w/github/client.pub
     cp /w/client/id_ed25519.pub /w/config/client_keys.pub
     cp /w/client/id_ed25519 /w/config/client_key'

# 「GitHub」: ネットワーク上の名前は github.com
docker run -d --name "$P-github" --network "$NET" --network-alias github.com \
  -v "$T/github:/github:ro" --entrypoint sh "$IMAGE" /github/start.sh >/dev/null

wait_ssh() { # wait_ssh ホスト名 → known_hosts の行を出力
  i=0
  until run "ssh-keyscan -t ed25519 $1 2>/dev/null | grep -q ." 2>/dev/null; do
    i=$((i+1)); [ "$i" -lt 30 ] || { echo "$1 の sshd が起動しません" >&2; docker logs "$2" >&2; exit 1; }
    sleep 1
  done
  run "ssh-keyscan -t ed25519 $1 2>/dev/null"
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
  run "set -e
    mkdir -p ~/.ssh && cp /w/client/id_ed25519 ~/.ssh/ && chmod 600 ~/.ssh/id_ed25519
    cat /w/config/known_hosts /w/client/known_hosts_gate > ~/.ssh/known_hosts
    git config --global user.name t; git config --global user.email t@example.com
    git config --global init.defaultBranch main; git config --global push.negotiate false
    git clone -q git@github.com:repo.git /tmp/dev && cd /tmp/dev
    git remote set-url --push origin ssh://git@gate/repo.git
    $1" >"$T/out" 2>&1
}
gh_has() { docker exec "$P-github" git --git-dir=/home/git/repo.git rev-parse -q --verify "refs/heads/$1" >/dev/null; }

# --- パスフレーズなしの鍵 ---
start_gate github_key_plain

if client 'git switch -qc feat && echo a > a && git add a && git commit -qm a && git push -q origin feat' && gh_has feat
then ok "feature ブランチの push が GitHub に届く"; else ng "feature ブランチの push が GitHub に届く"; fi

if ! client 'echo b > b && git add b && git commit -qm b && git push -q origin HEAD:main' \
   && grep -q 'git-push-gate:' "$T/out"
then ok "main への push は拒否"; else ng "main への push は拒否"; fi

if ! run "cp /w/client/id_ed25519 /tmp/k && chmod 600 /tmp/k &&
   ssh -i /tmp/k -o UserKnownHostsFile=/w/client/known_hosts_gate git@gate 'cat /etc/passwd'" >"$T/out" 2>&1 \
   && grep -q '許可されていません' "$T/out" && ! grep -q root: "$T/out"
then ok "任意のコマンドは拒否"; else ng "任意のコマンドは拒否"; fi

if ! run "cp /w/client/id_ed25519 /tmp/k && chmod 600 /tmp/k &&
   GIT_SSH_COMMAND='ssh -i /tmp/k -o UserKnownHostsFile=/w/client/known_hosts_gate' git clone -q ssh://git@gate/repo.git /tmp/x" >"$T/out" 2>&1 \
   && grep -q '許可されていません' "$T/out"
then ok "ゲートからの clone（upload-pack）は拒否"; else ng "ゲートからの clone（upload-pack）は拒否"; fi

if ! run "ssh-keygen -q -t ed25519 -N '' -f /tmp/k &&
   ssh -i /tmp/k -o BatchMode=yes -o UserKnownHostsFile=/w/client/known_hosts_gate git@gate git-receive-pack /repo.git" >"$T/out" 2>&1 \
   && grep -q "Permission denied" "$T/out"
then ok "登録されていない鍵は拒否"; else ng "登録されていない鍵は拒否"; fi

docker restart "$P-gate" >/dev/null
wait_ssh gate "$P-gate" >/dev/null
if client 'git switch -qc feat2 && echo c > c && git add c && git commit -qm c && git push -q origin feat2' && gh_has feat2
then ok "再起動後も push できる"; else ng "再起動後も push できる"; fi

# compose を使わない devcontainer（既定の bridge で名前解決なし）から、ホストに公開したポート経由で push
cp "$T/client/known_hosts_gate" "$T/known_hosts_gate_before"
GW=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')
start_gate github_key_plain -p "$GW::22"
if cmp -s "$T/client/known_hosts_gate" "$T/known_hosts_gate_before"
then ok "コンテナを作り直してもホスト鍵が変わらない"; else rm -f "$T/out"; ng "コンテナを作り直してもホスト鍵が変わらない"; fi
PORT=$(docker port "$P-gate" 22/tcp | sed 's/.*://' | head -n1)
if docker run --rm -v "$T:/w" --entrypoint sh "$IMAGE" -c "set -e
    h=\$(ip route | awk '/default/{print \$3}')
    mkdir -p ~/.ssh && cp /w/client/id_ed25519 ~/.ssh/ && chmod 600 ~/.ssh/id_ed25519
    sed \"s/^gate /[\$h]:$PORT /\" /w/client/known_hosts_gate > ~/.ssh/known_hosts
    git init -q -b bridge /tmp/d && cd /tmp/d && echo x > x && git add x
    git -c user.name=t -c user.email=t@example.com commit -qm x
    git push -q ssh://git@\$h:$PORT/repo.git bridge" >"$T/out" 2>&1 && gh_has bridge
then ok "既定の bridge からゲートウェイ経由で push できる"; else ng "既定の bridge からゲートウェイ経由で push できる"; fi

# client/attach.sh: VS Code が作る devcontainer に見立てたコンテナの push 先をゲートに向ける
mkdir -p "$T/ws"
docker run -d --name "$P-dev" -v "$T/ws:/workspaces/ws" \
  --label "devcontainer.local_folder=$T/ws" --label 'devcontainer.metadata=[{"remoteUser":"dev"}]' \
  --entrypoint sh "$IMAGE" -c 'adduser -D -u 1001 dev && sleep 1000000' >/dev/null
until docker exec "$P-dev" id dev >/dev/null 2>&1; do sleep 1; done
docker exec "$P-dev" sh -c 'chown dev /workspaces/ws && su dev -c "cd /workspaces/ws && git init -q -b attached &&
  git remote add origin https://github.invalid/repo.git && echo x > x && git add x &&
  git -c user.name=t -c user.email=t@example.com commit -qm x"'
if GATE="$P-gate" sh "$ROOT/client/attach.sh" "$T/ws" >"$T/out" 2>&1 &&
   docker exec -u dev -w /workspaces/ws "$P-dev" git push -q origin attached >>"$T/out" 2>&1 && gh_has attached
then ok "attach.sh で設定した devcontainer から push できる"; else ng "attach.sh で設定した devcontainer から push できる"; fi
if GATE="$P-gate" sh "$ROOT/client/attach.sh" "$T/ws" >"$T/out" 2>&1 &&
   [ "$(docker exec -u dev "$P-dev" grep -c git-push-gate.conf /home/dev/.ssh/config)" = 1 ]
then ok "attach.sh は 2 回実行しても設定が重複しない"; else ng "attach.sh は 2 回実行しても設定が重複しない"; fi
docker rm -f "$P-dev" >/dev/null

# --- パスフレーズ付きの鍵 ---
start_gate github_key_pp -e UNLOCK_LIFETIME=1h

if ! client 'git switch -qc feat3 && echo d > d && git add d && git commit -qm d && git push -q origin feat3' \
   && grep -q 'ロックされています' "$T/out" && ! gh_has feat3
then ok "unlock 前の push は「ロックされています」で拒否"; else ng "unlock 前の push は「ロックされています」で拒否"; fi

# 人間の unlock（パスフレーズは SSH_ASKPASS で渡す）
docker exec "$P-gate" sh -c 'printf "#!/bin/sh\necho secret\n" > /tmp/askpass && chmod 755 /tmp/askpass'
if docker exec -e SSH_ASKPASS=/tmp/askpass -e SSH_ASKPASS_REQUIRE=force "$P-gate" unlock >"$T/out" 2>&1
then ok "unlock"; else ng "unlock"; fi

if client 'git switch -qc feat3 && echo d > d && git add d && git commit -qm d && git push -q origin feat3' && gh_has feat3
then ok "unlock 後の push が GitHub に届く"; else ng "unlock 後の push が GitHub に届く"; fi

if ! client 'echo e > e && git add e && git commit -qm e && git push -q origin HEAD:develop' \
   && grep -q 'git-push-gate:' "$T/out"
then ok "unlock 後も develop への push は拒否"; else ng "unlock 後も develop への push は拒否"; fi

if docker exec "$P-gate" sh -c 'su -s /bin/sh git -c "SSH_AUTH_SOCK=/run/git-push-gate/agent.sock ssh-add -l"' | grep -q gate-pp
then ok "鍵がエージェントに読み込まれている"; else rm -f "$T/out"; ng "鍵がエージェントに読み込まれている"; fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
