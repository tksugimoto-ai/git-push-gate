# e2e テスト用の「GitHub」の HTTPS 版（git の smart HTTP と Basic 認証）。PAT で接続するゲートの確認に使う
ARG IMAGE=git-push-gate:test
FROM ${IMAGE}
RUN apk add --no-cache lighttpd lighttpd-mod_auth git-daemon openssl
