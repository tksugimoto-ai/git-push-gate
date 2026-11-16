FROM alpine:3.20

RUN apk add --no-cache git openssh-server nodejs npm \
 && adduser -D -s /bin/sh git && echo 'git:*' | chpasswd -e \
 && mkdir -p /home/git/.ssh /srv/git && chown -R git:git /home/git /srv/git \
 && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\nAllowUsers git\n' >> /etc/ssh/sshd_config

WORKDIR /usr/local/share/git-push-gate
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY hooks/pre-receive hooks/check-workflows.mjs ./
COPY bin/git-push-gate /usr/local/bin/git-push-gate
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /usr/local/bin/git-push-gate /entrypoint.sh pre-receive

VOLUME /srv/git
EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
