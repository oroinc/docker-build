
ARG ORO_BASELINE_VERSION=5.1-latest
ARG ORO_IMAGE_FROM=harborio.oro.cloud/oro-platform-public/init

FROM ${ORO_IMAGE_FROM}:${ORO_BASELINE_VERSION}

ARG ORO_IMAGE_FROM
ARG ORO_BASELINE_VERSION

ENV ORO_APP_FOLDER=/var/www/oro \
    ORO_USER=root \
    ORO_USER_RUNTIME=www-data

LABEL com.oroinc.orocloud.app="/var/www/oro" \
    com.oroinc.orocloud.image_type="init-app" \
    org.opencontainers.image.title="Application init image" \
    org.opencontainers.image.description="Application init image. Used for configure web server, php-fpm services" \
    org.opencontainers.image.authors="ORO Inc." \
    org.opencontainers.image.vendor="ORO Inc." \
    org.opencontainers.image.url="https://github.com/laboro/dev/blob/master/docker-build/docker/README.md" \
    org.opencontainers.image.documentation="https://github.com/laboro/dev/blob/master/docker-build/docker/README.md" \
    org.opencontainers.image.base.name="${ORO_IMAGE_FROM}:${ORO_BASELINE_VERSION}"

RUN --mount=type=bind,target=/source <<EOR
    set -ex
    rsync -a --delete --exclude-from=/source/.rsync-exclude-prod --chown="$ORO_USER":"$ORO_USER" /source/ $ORO_APP_FOLDER
    mkdir -p "$ORO_APP_FOLDER"/var/{data,cache,logs,sessions,maintenance,multihost}
    chown -R "$ORO_USER_RUNTIME":"$ORO_USER_RUNTIME" "$ORO_APP_FOLDER"/var/{data,cache,logs,sessions,maintenance,multihost} 2>/dev/null
    mkdir -p "$ORO_APP_FOLDER"/public/{media,bundles,js}
    chown -R "$ORO_USER_RUNTIME":"$ORO_USER_RUNTIME" "$ORO_APP_FOLDER"/public/{media,bundles,js} 2>/dev/null
    chown -R "$ORO_USER_RUNTIME":"$ORO_USER" /var/log/php-fpm
    chown -R "$ORO_USER":"$ORO_USER_RUNTIME" /var/lib/php/{opcache,session,wsdlcache}
EOR

WORKDIR $ORO_APP_FOLDER
VOLUME "/var/www/oro"
VOLUME "$ORO_APP_FOLDER/var/cache"
