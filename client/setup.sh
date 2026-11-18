#!/bin/sh
# devcontainer の中で、ワークスペースのディレクトリで実行し、push 先を git-push-gate に向ける（ホストでは実行しない）。
# 人間が統合ターミナルで実行しても、AI エージェントに頼んでもよい（秘密の情報は使わない）。
#
#   sh setup.sh <ゲートのアドレス> <ポート> '<ゲートのホスト鍵>'
#   例: sh setup.sh host.docker.internal 2222 'ssh-ed25519 AAAA...'
#
# クライアント用の鍵は devcontainer の中で作り、秘密鍵は外に出さない。表示される公開鍵を、
# 人間がゲートの config/client_keys.pub に足して、ゲートを再起動する。
# 書き込むのは ~/.ssh と .git/config だけで、利用側のリポジトリにコミットされるものはない。
set -eu
[ $# -eq 3 ] || { echo "使い方: sh setup.sh <ゲートのアドレス> <ポート> '<ゲートのホスト鍵>'" >&2; exit 1; }
host=$1; port=$2
set -f; set -- $3   # 「種類 鍵 [コメント]」の形（ゲートの .pub をそのまま貼ってよい）
case "$host" in ''|*[!A-Za-z0-9.:-]*) echo "アドレスが不正です: $host" >&2; exit 1 ;; esac
case "$port" in ''|*[!0-9]*) echo "ポートが不正です: $port" >&2; exit 1 ;; esac
case "${1:-}" in ssh-ed25519) ;; *) echo "ホスト鍵は ssh-ed25519 の公開鍵を指定してください" >&2; exit 1 ;; esac
case "${2:-}" in ''|*[!A-Za-z0-9+/=]*) echo "ホスト鍵が不正です" >&2; exit 1 ;; esac

umask 077
mkdir -p ~/.ssh
[ -f ~/.ssh/git-push-gate ] || ssh-keygen -q -t ed25519 -N '' -C git-push-gate-client -f ~/.ssh/git-push-gate
printf 'git-push-gate %s %s\n' "$1" "$2" > ~/.ssh/git-push-gate_known_hosts
# SSH エージェントは使わず（IdentityAgent none）、この鍵とホスト鍵だけを使う
cat > ~/.ssh/git-push-gate.conf <<EOF
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
EOF
# Include は Host より前に置く必要があるので、先頭に足す
if ! grep -qx 'Include ~/.ssh/git-push-gate.conf' ~/.ssh/config 2>/dev/null; then
  { echo 'Include ~/.ssh/git-push-gate.conf'; cat ~/.ssh/config 2>/dev/null || true; } > ~/.ssh/config.new
  mv ~/.ssh/config.new ~/.ssh/config
fi
git remote set-url --push "${REMOTE:-origin}" ssh://git@git-push-gate/repo.git

echo "push 先を git-push-gate（$host:$port）にしました。"
echo "まだなら、次の公開鍵をゲートの config/client_keys.pub に足して、ゲートを再起動してください:"
cat ~/.ssh/git-push-gate.pub
