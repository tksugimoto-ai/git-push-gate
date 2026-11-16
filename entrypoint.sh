#!/bin/sh
set -eu
: "${UPSTREAM:?例: git@github.com:owner/repo.git}"
PROTECTED="${PROTECTED_BRANCHES:-main develop}"
CONFIG=/config          # github_key, client_keys.pub, known_hosts を置いたディレクトリ（読み取り専用でマウント）
REPO=/srv/git/repo.git

for f in github_key client_keys.pub known_hosts; do
  [ -s "$CONFIG/$f" ] || { echo "entrypoint: $CONFIG/$f がありません" >&2; exit 1; }
done

# GitHub 用の秘密鍵とホスト鍵（git ユーザーだけが読める）
install -o git -g git -m 600 "$CONFIG/github_key" /home/git/.ssh/github_key
install -o root -g root -m 644 "$CONFIG/known_hosts" /etc/ssh/github_known_hosts

# クライアント（devcontainer）の公開鍵を、強制コマンド付きで登録
grep -Ev '^[[:space:]]*(#|$)' "$CONFIG/client_keys.pub" \
  | sed 's|^|command="/usr/local/bin/git-push-gate",restrict |' > /home/git/.ssh/authorized_keys
chown git:git /home/git/.ssh/authorized_keys && chmod 600 /home/git/.ssh/authorized_keys

[ -d "$REPO" ] || git init -q --bare "$REPO"
git --git-dir="$REPO" config remote.upstream.url "$UPSTREAM"   # fetch refspec は付けない
git --git-dir="$REPO" config core.sshCommand \
  "ssh -i /home/git/.ssh/github_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/ssh/github_known_hosts"
git --git-dir="$REPO" config gate.protected "$PROTECTED"
install -o root -g root -m 755 /usr/local/share/git-push-gate/pre-receive "$REPO/hooks/pre-receive"
chown -R git:git "$REPO"
chown root:root "$REPO/hooks" "$REPO/hooks/pre-receive" "$REPO/config"
chmod 644 "$REPO/config"

ssh-keygen -A >/dev/null
exec /usr/sbin/sshd -D -e
