#!/bin/sh
# ホストで実行し、devcontainer の push 先を git-push-gate に向ける。利用側のリポジトリは変更しない。
# devcontainer を作り直した（リビルドした）ら、もう一度実行する。
#
#   sh attach.sh [ワークスペースのディレクトリ]   # 既定はカレントディレクトリ
#
# 環境変数（自動で決まらないときに指定する）
#   GATE                 ゲートのコンテナ（既定: compose のサービス名が git-push-gate の、起動中のコンテナ）
#   DEVCONTAINER         devcontainer のコンテナ（既定: ワークスペースのディレクトリから VS Code のラベルで探す）
#   CONTAINER_WORKSPACE  devcontainer 内のワークスペースのパス（既定: マウントから探す）
#   GATE_HOST            devcontainer から見たゲートのホスト名（既定: ポートの公開先から決める）
#   REMOTE               push 先を変える remote（既定: origin）
#   CLIENT_KEY           クライアント用の秘密鍵（既定: ゲートの compose.yaml と同じディレクトリの client_key）
#
# 事前に、クライアント用の鍵 client_key を作り、公開鍵を config/client_keys.pub に登録しておく。
# 秘密鍵はゲートには要らないので、ゲートにマウントする config/ の外に置く。
set -eu
WS=$(cd "${1:-.}" && pwd)
REMOTE="${REMOTE:-origin}"
die() { echo "attach: $*" >&2; exit 1; }
one() { # 1 行だけなら出力、それ以外はエラー
  n=$(printf '%s' "$1" | grep -c . || true)
  [ "$n" -eq 1 ] || die "$2 が $n 個見つかりました。環境変数 $3 で指定してください"
  printf '%s\n' "$1"
}

# --- ゲート ---
GATE="${GATE:-$(one "$(docker ps -q --filter label=com.docker.compose.service=git-push-gate)" ゲートのコンテナ GATE)}"
dir=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$GATE")
CLIENT_KEY="${CLIENT_KEY:-$dir/client_key}"
[ -s "$CLIENT_KEY" ] || die "クライアント用の鍵 $CLIENT_KEY がありません。ゲートの compose.yaml のディレクトリで次を実行してください:
  ssh-keygen -t ed25519 -N '' -C git-push-gate-client -f client_key
  cat client_key.pub >> config/client_keys.pub
  docker compose restart"
hostkey=$(docker exec "$GATE" cut -d' ' -f1,2 /srv/git/ssh_host_keys/ssh_host_ed25519_key.pub)
pub=$(docker port "$GATE" 22/tcp | head -n1)
[ -n "$pub" ] || die "ゲートのポートがホストに公開されていません（compose の ports を確認してください）"
port=${pub##*:}; bind=${pub%:*}
case "$bind" in
  127.0.0.1|'[::1]') host=host.docker.internal ;;   # Docker Desktop
  0.0.0.0|'[::]'|::)                                # すべてのアドレス（README では非推奨）。Docker の種類で決める
    if docker info --format '{{.OperatingSystem}}' | grep -q 'Docker Desktop'; then host=host.docker.internal
    else host=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}'); fi ;;
  *) host=$bind ;;                                  # Linux の Docker Engine（docker0 の IP）
esac
host="${GATE_HOST:-$host}"

# --- devcontainer ---
DC="${DEVCONTAINER:-$(one "$(docker ps -q --filter "label=devcontainer.local_folder=$WS")" "devcontainer（$WS）" DEVCONTAINER)}"
# VS Code が接続するユーザー: remoteUser → containerUser → イメージの USER → root の順
meta() { docker inspect -f '{{index .Config.Labels "devcontainer.metadata"}}' "$DC" | grep -o "\"$1\": *\"[^\"]*\"" | tail -n1 | sed 's/.*"\([^"]*\)"$/\1/'; }
user=$(meta remoteUser); [ -n "$user" ] || user=$(meta containerUser)
[ -n "$user" ] || user=$(docker inspect -f '{{.Config.User}}' "$DC")
user="${user:-root}"
cws="${CONTAINER_WORKSPACE:-$(docker inspect -f '{{range .Mounts}}{{if eq .Source "'"$WS"'"}}{{println .Destination}}{{end}}{{end}}' "$DC" | head -n1)}"
[ -n "$cws" ] || die "devcontainer 内のワークスペースが分かりません。環境変数 CONTAINER_WORKSPACE で指定してください"
x() { docker exec -i -u "$user" "$DC" sh -c "$1"; }

# ゲートを迂回して書き込めてしまう設定があれば、設定せずに止める
x '[ ! -S /var/run/docker.sock ] && [ ! -S /var/run/docker-host.sock ] && [ -z "${DOCKER_HOST:-}" ]' \
  || die "devcontainer から Docker を操作できます（docker.sock・docker-host.sock・DOCKER_HOST。ゲートのコンテナの中身を読めてしまう）。外してください"
x '! ls /tmp/vscode-ssh-auth-*.sock >/dev/null 2>&1 && [ -z "${SSH_AUTH_SOCK:-}" ]' \
  || die "devcontainer に SSH エージェントが転送されています（ホストの鍵で GitHub に直接 push できてしまう）。止めてください"

# 鍵はホストから devcontainer の ~/.ssh へ直接渡す（ワークスペースには置かない）
key=$(cat "$CLIENT_KEY") && [ -n "$key" ] || die "クライアント用の鍵 $CLIENT_KEY を読めません"
x 'umask 077 && mkdir -p ~/.ssh && cat > ~/.ssh/git-push-gate' <<EOF
$key
EOF
x "umask 077 && printf '%s\n' 'git-push-gate $hostkey' > ~/.ssh/git-push-gate_known_hosts
cat > ~/.ssh/git-push-gate.conf <<'CONF'
Host git-push-gate
  HostName $host
  Port $port
  User git
  IdentityFile ~/.ssh/git-push-gate
  IdentitiesOnly yes
  IdentityAgent none
  HostKeyAlias git-push-gate
  UserKnownHostsFile ~/.ssh/git-push-gate_known_hosts
  StrictHostKeyChecking yes
CONF
# Include は Host より前に置く必要があるので、先頭に足す
if ! grep -qx 'Include ~/.ssh/git-push-gate.conf' ~/.ssh/config 2>/dev/null; then
  { echo 'Include ~/.ssh/git-push-gate.conf'; cat ~/.ssh/config 2>/dev/null || true; } > ~/.ssh/config.new
  mv ~/.ssh/config.new ~/.ssh/config
fi"
docker exec -u "$user" "$DC" git -C "$cws" remote set-url --push "$REMOTE" ssh://git@git-push-gate/repo.git

# 接続の確認: ゲートは push 以外を拒否するので、その拒否メッセージが返れば届いている
if x 'ssh -T git-push-gate true 2>&1' | grep -q 'git-push-gate:'; then
  echo "attach: $DC（$cws）の push 先を git-push-gate（$host:$port）に設定しました"
else
  x 'ssh -T git-push-gate true' || true
  die "ゲートに接続できません（上の出力を確認してください）"
fi

# VS Code の credential helper は、VS Code が接続するたびに設定し直すので、警告にとどめる
x 'git config --get-all credential.helper 2>/dev/null | grep -q vscode && echo "attach: 警告: VS Code の git credential helper が有効です（dev.containers.gitCredentialHelperConfigLocation を none に）" >&2
   true'
