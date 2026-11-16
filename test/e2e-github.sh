#!/bin/sh
# e2e テスト用の「GitHub」。git ユーザーの SSH で /home/git/repo.git を公開する。
set -eu
install -o git -g git -m 700 -d /home/git/.ssh
# ゲートの鍵（push 用）とクライアントの鍵（fetch 用。本番では読み取り専用のトークンに相当）
cat /github/authorized_keys /github/client.pub > /home/git/.ssh/authorized_keys
chown git:git /home/git/.ssh/authorized_keys && chmod 600 /home/git/.ssh/authorized_keys

R=/home/git/repo.git
git init -q --bare -b main "$R"
S=$(mktemp -d)
git -C "$S" init -q -b main
mkdir -p "$S/.github/workflows"
printf 'on: push\npermissions: {contents: read}\njobs: {}\n' > "$S/.github/workflows/ci.yml"
echo seed > "$S/README"
git -C "$S" add -A
git -C "$S" -c user.name=t -c user.email=t@example.com commit -qm init
git -C "$S" push -q "$R" main main:develop
chown -R git:git "$R"

ssh-keygen -A >/dev/null
exec /usr/sbin/sshd -D -e
