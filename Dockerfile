FROM alpine:3.20

RUN apk add --no-cache git openssh-server openssh-client nodejs flock \
 && git config --system safe.directory /srv/git/repo.git \
 && adduser -D -s /bin/sh git && echo 'git:*' | chpasswd -e \
 && mkdir -p /home/git/.ssh /srv/git && chown -R git:git /home/git /srv/git \
 && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\nAllowUsers git\n' >> /etc/ssh/sshd_config

WORKDIR /usr/local/share/git-push-gate
COPY package.json package-lock.json ./
# npm は依存の導入にだけ使い、イメージには残さない
RUN apk add --no-cache --virtual .npm npm && npm ci --omit=dev && npm cache clean --force && apk del .npm
COPY hooks/pre-receive hooks/check-workflows.mjs ./
COPY bin/git-push-gate bin/unlock /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /usr/local/bin/git-push-gate /usr/local/bin/unlock /entrypoint.sh pre-receive

VOLUME /srv/git
EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
