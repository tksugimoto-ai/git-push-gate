#!/bin/sh
set -eu
die() { echo "entrypoint: $*" >&2; exit 1; }
: "${UPSTREAM:?例: git@github.com:owner/repo.git}"
PROTECTED="${PROTECTED_BRANCHES:-main develop}"   # 既定値はここだけ（フックは gate.protected を読む）
case "$PROTECTED" in
  *[*?[]*) die "PROTECTED_BRANCHES にパターンは使えません（ブランチ名を完全一致で列挙）: $PROTECTED" ;;
esac
# 空白だけなどで 0 件になると何も守らないので拒否。区切りは空白 1 つにそろえる（パターンは上で拒否済み）
# shellcheck disable=SC2086
set -- $PROTECTED; [ $# -gt 0 ] || die "PROTECTED_BRANCHES が空です"; PROTECTED="$*"; set --
CONFIG=/config          # github_key, client_keys.pub, known_hosts を置いたディレクトリ（読み取り専用でマウント）
REPO=/srv/git/repo.git  # root で操作できるよう、Dockerfile で safe.directory に登録してある
g() { git --git-dir="$REPO" "$@"; }

for f in github_key client_keys.pub known_hosts; do
  [ -s "$CONFIG/$f" ] || die "$CONFIG/$f がありません"
done

KEY=/home/git/.ssh/github_key
AGENT_DIR=/run/git-push-gate
# 止まった接続が後の push をすべて待たせないよう、タイムアウトを付ける（BatchMode: 対話的な入力を求めない）
SSH_OPTS="-o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/ssh/github_known_hosts -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"

# GitHub 用の秘密鍵とホスト鍵（git ユーザーだけが読める）
install -o git -g git -m 600 "$CONFIG/github_key" "$KEY"
install -o root -g root -m 644 "$CONFIG/known_hosts" /etc/ssh/github_known_hosts

if ssh-keygen -y -P '' -f "$KEY" >/dev/null 2>&1; then
  # パスフレーズなし: 鍵ファイルを直接使う
  ssh_cmd="ssh -i $KEY $SSH_OPTS"
  agent_sock=""
else
  # パスフレーズ付き: コンテナ内の ssh-agent に、人間が unlock で一度だけ読み込ませる
  [ -s "$CONFIG/github_key.pub" ] || die "パスフレーズ付きの鍵には $CONFIG/github_key.pub も必要です"
  install -o git -g git -m 644 "$CONFIG/github_key.pub" "$KEY.pub"
  install -d -o git -g git -m 700 "$AGENT_DIR"
  agent_sock="$AGENT_DIR/agent.sock"
  rm -f "$agent_sock"
  su -s /bin/sh git -c "ssh-agent -a $agent_sock" >/dev/null
  # -i に公開鍵を渡すと、エージェント内の対応する鍵だけを使う
  ssh_cmd="ssh -i $KEY.pub -o IdentityAgent=$agent_sock $SSH_OPTS"
  echo "entrypoint: 鍵はロックされています。ホストで次を実行してください: docker compose exec git-push-gate unlock" >&2
fi

# クライアント（devcontainer）の公開鍵を、強制コマンド付きで登録
keys=$(grep -Ev '^[[:space:]]*(#|$)' "$CONFIG/client_keys.pub" || true)
# オプション（from= など）付きの行は、前に足すオプションと合わさって無効な鍵になるので拒否する
[ -n "$keys" ] || die "$CONFIG/client_keys.pub に公開鍵がありません"
if printf '%s\n' "$keys" | grep -Evq '^(ssh-|ecdsa-|sk-)'; then
  die "$CONFIG/client_keys.pub には、オプションなしの公開鍵だけを書いてください"
fi
printf '%s\n' "$keys" | sed 's|^|command="/usr/local/bin/git-push-gate",restrict |' > /home/git/.ssh/authorized_keys
chown git:git /home/git/.ssh/authorized_keys && chmod 600 /home/git/.ssh/authorized_keys

[ -d "$REPO" ] || git init -q --bare "$REPO"
g config remote.upstream.url "$UPSTREAM"   # fetch refspec は付けない
g config core.sshCommand "$ssh_cmd"
if [ -n "$agent_sock" ]; then
  g config gate.agentSocket "$agent_sock"
else
  g config --unset gate.agentSocket || true
fi
g config gate.protected "$PROTECTED"
install -o root -g root -m 755 /usr/local/share/git-push-gate/pre-receive "$REPO/hooks/pre-receive"
chown -R git:git "$REPO"
chown root:root "$REPO/hooks" "$REPO/hooks/pre-receive" "$REPO/config"
chmod 644 "$REPO/config"

# ホスト鍵はボリュームに置き、コンテナを作り直しても変わらないようにする（クライアントの known_hosts が合うように）
HOSTKEYS=/srv/git/ssh_host_keys
install -d -o root -g root -m 700 "$HOSTKEYS"
[ -s "$HOSTKEYS/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N '' -C git-push-gate -f "$HOSTKEYS/ssh_host_ed25519_key"
exec /usr/sbin/sshd -D -e -h "$HOSTKEYS/ssh_host_ed25519_key"
