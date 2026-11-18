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
# /srv/git は git ユーザーの持ち物なので、root が書き込む前に、シンボリックリンクに差し替えられていないか確かめる
for p in "$REPO" "$REPO/config" "$REPO/hooks" "$REPO/hooks/pre-receive"; do
  [ ! -L "$p" ] || die "$p がシンボリックリンクです"
done
g config remote.upstream.url "$UPSTREAM"   # fetch refspec は付けない
g config core.sshCommand "$ssh_cmd"
if [ -n "$agent_sock" ]; then
  g config gate.agentSocket "$agent_sock"
else
  g config --unset gate.agentSocket || true
fi
g config gate.protected "$PROTECTED"
# 許可する接頭辞（空白区切り。例: "agent/ claude/"）。設定すると、それ以外のブランチは作成・更新・削除させない
PREFIXES="${ALLOWED_BRANCH_PREFIXES:-}"
case "$PREFIXES" in
  *[*?[]*) die "ALLOWED_BRANCH_PREFIXES にパターンは使えません（接頭辞を列挙）: $PREFIXES" ;;
esac
# shellcheck disable=SC2086
set -- $PREFIXES; PREFIXES="$*"; set --
# 制限なしは「*」と書く（フックは、設定を読めなければ拒否する。パターンは上で拒否しているので取り違えない）
g config gate.allowedPrefixes "${PREFIXES:-*}"
# 壊れたオブジェクト（同じ名前の項目が 2 つある木など）は受け付けない
g config receive.fsckObjects true
# 変な mode（40777 や 100600 など）も拒否する（既定では警告だけで、ls-tree は正規化して表示する）
g config receive.fsck.badFilemode error
# bare リポジトリの HEAD が指すブランチ（master など）の削除を receive-pack が拒否すると、
# GitHub では削除済みなのにクライアントには失敗と返るので、拒否させない（保護は pre-receive が行う）
g config receive.denyDeleteCurrent ignore
# receive-pack が裏で起動する gc は、ロックのファイル記述子を引き継いで次の push を待たせるので止める
g config receive.autogc false
# 受け付ける大きさの上限（ボリュームを埋められないように）
g config receive.maxInputSize "${MAX_PUSH_SIZE:-500m}"
install -o root -g root -m 755 /usr/local/share/git-push-gate/pre-receive "$REPO/hooks/pre-receive"
chown -R -h git:git "$REPO"   # -h: シンボリックリンクの先を変えない
chown -h root:root "$REPO/hooks" "$REPO/hooks/pre-receive" "$REPO/config"
chmod 644 "$REPO/config"

# ホスト鍵はボリュームに置き、コンテナを作り直しても変わらないようにする（クライアントの known_hosts が合うように）
HOSTKEYS=/srv/git/ssh_host_keys
install -d -o root -g root -m 700 "$HOSTKEYS"
[ -s "$HOSTKEYS/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N '' -C git-push-gate -f "$HOSTKEYS/ssh_host_ed25519_key"

# 最初の fetch（全履歴）は時間がかかるので、push の前に時間制限なしで済ませておく。
# UPSTREAM・鍵・known_hosts の間違いもここで分かる。パスフレーズ付きの鍵は unlock の後に行う
if [ -z "$agent_sock" ]; then
  su -s /bin/sh git -c "git --git-dir=$REPO fetch --prune --no-tags --quiet upstream '+refs/heads/*:refs/heads/*'" \
    || echo "entrypoint: 警告: GitHub から fetch できません（UPSTREAM・鍵・known_hosts を確認してください）" >&2
fi
# push の中では gc を止めているので、起動時に整理する（push を受け付ける前なのでロックは要らない）。
# どこからも使われていないオブジェクト（拒否された push の証明書など）も、すぐ消す（ゲートは GitHub の写しなので、消して困るものはない）
su -s /bin/sh git -c "git --git-dir=$REPO gc --auto --quiet && git --git-dir=$REPO prune --expire=now" || echo "entrypoint: 警告: gc に失敗しました" >&2
exec /usr/sbin/sshd -D -e -h "$HOSTKEYS/ssh_host_ed25519_key"
