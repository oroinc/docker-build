# syntax=docker/dockerfile:1

ARG ORO_BASELINE_VERSION=6.0-latest
ARG ORO_IMAGE_FROM=docker.io/oroinc/runtime

FROM ${ORO_IMAGE_FROM}:${ORO_BASELINE_VERSION}

ARG ORO_IMAGE_FROM
ARG ORO_BASELINE_VERSION

ENV ORO_APP_FOLDER=/var/www/oro \
    ORO_USER=root \
    ORO_USER_RUNTIME=www-data

LABEL com.oroinc.orocloud.app="/var/www/oro" \
    org.opencontainers.image.title="Application runtime image" \
    org.opencontainers.image.description="Application runtime image. Used for run web server, php-fpm, ws, consumer and other services" \
    org.opencontainers.image.authors="ORO Inc." \
    org.opencontainers.image.vendor="ORO Inc." \
    org.opencontainers.image.url="https://github.com/laboro/dev/blob/master/docker-build/docker/README.md" \
    org.opencontainers.image.documentation="https://github.com/laboro/dev/blob/master/docker-build/docker/README.md" \
    org.opencontainers.image.base.name="${ORO_IMAGE_FROM}:${ORO_BASELINE_VERSION}"

RUN --mount=type=bind,target=/source \
    groupadd --system --gid 2001 $ORO_USER_RUNTIME && useradd --home-dir $ORO_APP_FOLDER/var --uid 2002 --gid $ORO_USER_RUNTIME --no-create-home --system $ORO_USER_RUNTIME && \
    rsync -a --delete --exclude-from=/source/.rsync-exclude-prod --chown="$ORO_USER":"$ORO_USER_RUNTIME" /source/ $ORO_APP_FOLDER && \
    mkdir -p "$ORO_APP_FOLDER"/var/{data,cache,logs,sessions,maintenance}; \
    chown -R "$ORO_USER_RUNTIME":"$ORO_USER_RUNTIME" "$ORO_APP_FOLDER"/var/{data,cache,logs,sessions,maintenance} 2>/dev/null; \
    chown -R "$ORO_USER_RUNTIME":"$ORO_USER_RUNTIME" "$ORO_APP_FOLDER"/public/media 2>/dev/null; \
    chown -R "$ORO_USER_RUNTIME":"$ORO_USER" /var/log/php-fpm && \
    chown -R "$ORO_USER":"$ORO_USER_RUNTIME" /var/lib/php/{opcache,session,wsdlcache}

WORKDIR $ORO_APP_FOLDER
VOLUME "$ORO_APP_FOLDER/var/cache"
