ARG NGINX_IMAGE=nginx:alpine
FROM ${NGINX_IMAGE}

ARG IMAGE_TITLE="nginx-auto-tls-proxy"
ARG IMAGE_DESCRIPTION="Self-contained auto-configuring nginx reverse proxy with static hosting, SNI TLS, and Let's Encrypt renewal"
ARG IMAGE_LICENSES="MIT"
ARG IMAGE_SOURCE=""
ARG IMAGE_REVISION=""
ARG IMAGE_VERSION=""

LABEL org.opencontainers.image.title="${IMAGE_TITLE}" \
      org.opencontainers.image.description="${IMAGE_DESCRIPTION}" \
      org.opencontainers.image.licenses="${IMAGE_LICENSES}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      org.opencontainers.image.version="${IMAGE_VERSION}"

RUN apk add --no-cache \
    bash \
    openssl \
    certbot

RUN mkdir -p \
    /var/www/acme/.well-known/acme-challenge \
    /ssl \
    /sites \
    /etc/nginx/conf.d \
    /etc/nginx/site-conf.d

COPY nginx.conf        /etc/nginx/nginx.conf
COPY entrypoint.sh     /entrypoint.sh
COPY certbot-deploy.sh /usr/local/bin/certbot-deploy.sh
COPY healthcheck.sh    /usr/local/bin/healthcheck.sh

RUN chmod +x /entrypoint.sh /usr/local/bin/certbot-deploy.sh /usr/local/bin/healthcheck.sh

EXPOSE 80 443

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
