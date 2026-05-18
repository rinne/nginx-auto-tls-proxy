ARG NGINX_IMAGE=nginx:alpine
FROM ${NGINX_IMAGE}

ARG IMAGE_TITLE="nginx-auto-tls-proxy"
ARG IMAGE_DESCRIPTION="Self-contained auto-configuring nginx reverse proxy with static hosting, SNI TLS, and Let's Encrypt renewal"
ARG IMAGE_LICENSES="MIT"
ARG IMAGE_SOURCE=""
ARG IMAGE_REVISION=""
ARG IMAGE_VERSION=""
ARG WITH_PHP=0
ARG PHP_TRACK=85

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

RUN set -e ; \
    if [ "$WITH_PHP" = "1" ]; then \
        apk add --no-cache \
            fcgi \
            "php${PHP_TRACK}" \
            "php${PHP_TRACK}-fpm" \
            "php${PHP_TRACK}-mbstring" \
            "php${PHP_TRACK}-intl" \
            "php${PHP_TRACK}-curl" \
            "php${PHP_TRACK}-xml" \
            "php${PHP_TRACK}-dom" \
            "php${PHP_TRACK}-xmlreader" \
            "php${PHP_TRACK}-xmlwriter" \
            "php${PHP_TRACK}-simplexml" \
            "php${PHP_TRACK}-gd" \
            "php${PHP_TRACK}-zip" \
            "php${PHP_TRACK}-fileinfo" \
            "php${PHP_TRACK}-session" \
            "php${PHP_TRACK}-tokenizer" \
            "php${PHP_TRACK}-pdo" \
            "php${PHP_TRACK}-pdo_mysql" \
            "php${PHP_TRACK}-pdo_pgsql" \
            "php${PHP_TRACK}-pdo_sqlite" \
            "php${PHP_TRACK}-mysqli" \
            "php${PHP_TRACK}-iconv" \
            "php${PHP_TRACK}-phar" \
            "php${PHP_TRACK}-ctype" \
            "php${PHP_TRACK}-bcmath" \
            "php${PHP_TRACK}-sodium" \
            "php${PHP_TRACK}-openssl" ; \
        mkdir -p \
            /etc/nginx-auto-tls-proxy \
            /usr/local/sbin \
            "/etc/php${PHP_TRACK}/conf.d" \
            "/etc/php${PHP_TRACK}/php-fpm.d" \
            "/var/log/php${PHP_TRACK}" ; \
        ln -sf "/usr/sbin/php-fpm${PHP_TRACK}" /usr/local/sbin/php-fpm ; \
        ln -sf "/etc/php${PHP_TRACK}"          /etc/nginx-auto-tls-proxy/php ; \
        ln -sf /dev/stderr "/var/log/php${PHP_TRACK}/error.log" ; \
    fi

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
COPY php/              /opt/nginx-auto-tls-proxy/php-templates/

RUN chmod +x /entrypoint.sh /usr/local/bin/certbot-deploy.sh /usr/local/bin/healthcheck.sh

RUN if [ "$WITH_PHP" = "1" ]; then \
        cp /opt/nginx-auto-tls-proxy/php-templates/php-fpm.conf    "/etc/php${PHP_TRACK}/php-fpm.conf" ; \
        cp /opt/nginx-auto-tls-proxy/php-templates/zz-defaults.ini "/etc/php${PHP_TRACK}/conf.d/zz-defaults.ini" ; \
        rm -f "/etc/php${PHP_TRACK}/php-fpm.d/www.conf" ; \
    fi

EXPOSE 80 443

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
