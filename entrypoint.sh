#!/bin/sh
set -eu
: "${UPSTREAM:?例: git@github.com:owner/repo.git}"
PROTECTED="${PROTECTED_BRANCHES:-main develop}"
case "$PROTECTED" in
  *[*?[]*) echo "entrypoint: PROTECTED_BRANCHES にパターンは使えません（ブランチ名を完全一致で列挙）: $PROTECTED" >&2; exit 1 ;;
esac
CONFIG=/config          # github_key, client_keys.pub, known_hosts を置いたディレクトリ（読み取り専用でマウント）
REPO=/srv/git/repo.git
# root で git ユーザー所有のリポジトリを操作するため safe.directory を指定
g() { git -c safe.directory="$REPO" --git-dir="$REPO" "$@"; }

for f in github_key client_keys.pub known_hosts; do
  [ -s "$CONFIG/$f" ] || { echo "entrypoint: $CONFIG/$f がありません" >&2; exit 1; }
done

KEY=/home/git/.ssh/github_key
AGENT_DIR=/run/git-push-gate
SSH_OPTS="-o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/ssh/github_known_hosts"

# GitHub 用の秘密鍵とホスト鍵（git ユーザーだけが読める）
install -o git -g git -m 600 "$CONFIG/github_key" "$KEY"
install -o root -g root -m 644 "$CONFIG/known_hosts" /etc/ssh/github_known_hosts

if ssh-keygen -y -P '' -f "$KEY" >/dev/null 2>&1; then
  # パスフレーズなし: 鍵ファイルを直接使う
  ssh_cmd="ssh -i $KEY $SSH_OPTS"
  agent_sock=""
else
  # パスフレーズ付き: コンテナ内の ssh-agent に、人間が unlock で一度だけ読み込ませる
  [ -s "$CONFIG/github_key.pub" ] || { echo "entrypoint: パスフレーズ付きの鍵には $CONFIG/github_key.pub も必要です" >&2; exit 1; }
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
# オプション（from= など）付きの行は、前に足すオプションと合わさって無効な鍵になるので拒否する
if grep -Ev '^[[:space:]]*(#|$)' "$CONFIG/client_keys.pub" | grep -Evq '^(ssh-|ecdsa-|sk-)'; then
  echo "entrypoint: $CONFIG/client_keys.pub には、オプションなしの公開鍵だけを書いてください" >&2; exit 1
fi
grep -Ev '^[[:space:]]*(#|$)' "$CONFIG/client_keys.pub" \
  | sed 's|^|command="/usr/local/bin/git-push-gate",restrict |' > /home/git/.ssh/authorized_keys
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
