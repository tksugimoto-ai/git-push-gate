#!/bin/sh
# e2e テスト用の「GitHub」。git ユーザーの SSH で /home/git/repo.git を公開する。
set -eu
install --owner git --group git --mode 700 --directory /home/git/.ssh
# ゲートの鍵（push 用）とクライアントの鍵（fetch 用。本番では読み取り専用のトークンに相当）
cat /github/authorized_keys /github/client.pub > /home/git/.ssh/authorized_keys
chown git:git /home/git/.ssh/authorized_keys && chmod 600 /home/git/.ssh/authorized_keys

BARE_REPO=/home/git/repo.git
git init --quiet --bare --initial-branch main "$BARE_REPO"
SEED_DIR=$(mktemp --directory)
git -C "$SEED_DIR" init --quiet --initial-branch main
mkdir --parents "$SEED_DIR/.github/workflows"
printf 'on: push\npermissions: {contents: read}\njobs: {}\n' > "$SEED_DIR/.github/workflows/ci.yml"
echo seed > "$SEED_DIR/README"
git -C "$SEED_DIR" add --all
git -C "$SEED_DIR" -c user.name=t -c user.email=t@example.com commit --quiet --message init
git -C "$SEED_DIR" push --quiet "$BARE_REPO" main main:develop
chown --recursive git:git "$BARE_REPO"

# HTTPS（git の smart HTTP、Basic 認証）でも公開する。PAT で接続するゲートの確認用（URL は https://github.com/git/repo.git）
if [ -s /github/tls/server.pem ]; then
  cat > /etc/lighttpd/git.conf <<'EOF'
server.modules = ("mod_openssl", "mod_auth", "mod_authn_file", "mod_alias", "mod_setenv", "mod_cgi")
server.port = 443
server.username = "git"
server.groupname = "git"
server.document-root = "/var/empty"
ssl.engine = "enable"
ssl.pemfile = "/github/tls/server.pem"
auth.backend = "plain"
auth.backend.plain.userfile = "/github/tls/users"
auth.require = ("/git/" => ("method" => "basic", "realm" => "git", "require" => "valid-user"))
alias.url = ("/git" => "/usr/libexec/git-core/git-http-backend")
cgi.assign = ("/git-http-backend" => "")
setenv.add-environment = ("GIT_PROJECT_ROOT" => "/home/git", "GIT_HTTP_EXPORT_ALL" => "1")
EOF
  mkdir --parents /var/empty
  lighttpd -f /etc/lighttpd/git.conf
fi

ssh-keygen -A >/dev/null
exec /usr/sbin/sshd -D -e
