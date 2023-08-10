#!/bin/bash

set -o pipefail
shopt -s nullglob
shopt -s dotglob

# logging functions
_log() {
    [[ $ORO_ENTRYPOINT_QUIET ]] && return 0
    local type="$1"
    shift
    # accept argument string or stdin
    local text="$*"
    if [ "$#" -eq 0 ]; then text="$(cat)"; fi
    local dt
    dt="$(date --rfc-3339=seconds)"
    printf '%s [%s] [Entrypoint]: %s\n' "$dt" "$type" "$text"
}
_note() {
    _log Note "$@"
}
_warn() {
    _log Warn "$@" >&2
}
_error() {
    _log ERROR "$@" >&2
    exit 1
}

backup_pg_db() {
    local DB_FILE="${1}"
    export PGPASSWORD="$ORO_DB_PASSWORD"
    _note "Backup DB from: $ORO_DB_NAME to file: $DB_FILE"
    mkdir -p "$(dirname "$DB_FILE")"
    set -x
    pg_dump -Fp --no-acl --no-owner --no-privileges -c --if-exists --user="$ORO_DB_USER" --host="$ORO_DB_HOST" --port="$ORO_DB_PORT" "$ORO_DB_NAME" >"$DB_FILE" || _error "Can't create backup to file $DB_FILE"
    set +x
}

restore_pg_db() {
    local DB_FILE="${1}"
    local PG_COMMAND=psql
    local DB_USER_O=" --user=$ORO_DB_ROOT_USER "
    local DB_HOST_O=" --host=$ORO_DB_HOST "
    local DB_PORT_O=" --port=$ORO_DB_PORT "
    export PGPASSWORD="$ORO_DB_ROOT_PASSWORD"

    if [[ "X$ORO_DB_ROOT_USER" == "X" ]]; then
        DB_USER_O="--user=$ORO_DB_USER"
    fi
    ORO_TABLES_NUM=$($PG_COMMAND -q $DB_USER_O $DB_HOST_O $DB_PORT_O $ORO_DB_NAME -t -c "SELECT count(table_name) FROM information_schema.tables WHERE table_schema = 'public';")
    if [ "$ORO_TABLES_NUM" -eq 0 ]; then
        _note "Restore dump from file: $DB_FILE to: $ORO_DB_NAME"
        set -x
        $PG_COMMAND --set ON_ERROR_STOP=on $DB_USER_O $DB_HOST_O $DB_PORT_O -d "$ORO_DB_NAME" <"$DB_FILE" >/dev/null || _error "Can't restore dump"
        $PG_COMMAND -q $DB_USER_O $DB_HOST_O $DB_PORT_O $ORO_DB_NAME -c "GRANT CONNECT ON DATABASE $ORO_DB_NAME TO $ORO_DB_USER;" || _error "Can't grant privileges 1"
        $PG_COMMAND -q $DB_USER_O $DB_HOST_O $DB_PORT_O $ORO_DB_NAME -c "GRANT USAGE ON SCHEMA public TO $ORO_DB_USER;" || _error "Can't grant privileges 2"
        $PG_COMMAND -q $DB_USER_O $DB_HOST_O $DB_PORT_O $ORO_DB_NAME -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $ORO_DB_USER;" || _error "Can't grant privileges 3"
        $PG_COMMAND -q $DB_USER_O $DB_HOST_O $DB_PORT_O $ORO_DB_NAME -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $ORO_DB_USER;" || _error "Can't grant privileges 4"
        $PG_COMMAND -t $DB_USER_O $DB_HOST_O $DB_PORT_O $ORO_DB_NAME -c "SELECT 'ALTER TABLE '|| schemaname || '.' || tablename ||' OWNER TO $ORO_DB_USER;' FROM pg_tables WHERE NOT schemaname IN ('pg_catalog', 'information_schema') ORDER BY schemaname, tablename;" | xargs -r -I {} $PG_COMMAND $DB_USER_O $DB_HOST_O $DB_PORT_O $ORO_DB_NAME -c "{}" >/dev/null || _error "Can't alter 2"
        $PG_COMMAND -t $DB_USER_O $DB_HOST_O $DB_PORT_O $ORO_DB_NAME -c "SELECT 'ALTER SEQUENCE '|| sequence_schema || '.' || sequence_name ||' OWNER TO $ORO_DB_USER;' FROM information_schema.sequences WHERE NOT sequence_schema IN ('pg_catalog', 'information_schema') ORDER BY sequence_schema, sequence_name;" | xargs -r -I {} $PG_COMMAND $DB_USER_O $DB_HOST_O $DB_PORT_O $ORO_DB_NAME -c "{}" >/dev/null || _error "Can't alter 3"
        $PG_COMMAND -t $DB_USER_O $DB_HOST_O $DB_PORT_O $ORO_DB_NAME -c "SELECT 'ALTER VIEW '|| table_schema || '.' || table_name ||' OWNER TO $ORO_DB_USER;' FROM information_schema.views WHERE NOT table_schema IN ('pg_catalog', 'information_schema') ORDER BY table_schema, table_name;" | xargs -r -I {} $PG_COMMAND $DB_USER_O $DB_HOST_O $DB_PORT_O $ORO_DB_NAME -c "{}" >/dev/null || _error "Can't alter 4"
        # Create extention
        $PG_COMMAND -q $DB_USER_O $DB_HOST_O $DB_PORT_O -c 'CREATE EXTENSION IF NOT EXISTS "uuid-ossp";' -d "$ORO_DB_NAME"
        set +x
    else
        set +x
        _note "Skipping dump load, because tables exist"
    fi
}

mongo_get() {
    local DIR_NAME="${1}"
    local DB_NAME="${2}"
    _note "Copy files from mongo DB: $DB_NAME to folder: $DIR_NAME"
    rm -rf "$DIR_NAME"
    mkdir -p "$DIR_NAME"
    pushd "$DIR_NAME" >/dev/null 2>&1 || _error "Error enter to folder $DIR_NAME"
    mongofiles --quiet --uri="mongodb://$ORO_MONGO_USER:$ORO_MONGO_PASSWORD@$ORO_MONGO_HOST:27017" --authenticationDatabase="$DB_NAME" --db="$DB_NAME" list
    set -e
    mongofiles --quiet --uri="mongodb://$ORO_MONGO_USER:$ORO_MONGO_PASSWORD@$ORO_MONGO_HOST:27017" --authenticationDatabase="$DB_NAME" --db="$DB_NAME" list | expand | tr -s ' ' | cut -d' ' -f1 | xargs -n1 -r -I {} bash -c "mkdir -p \$(dirname {}) && mongofiles --quiet --uri='mongodb://$ORO_MONGO_USER:$ORO_MONGO_PASSWORD@$ORO_MONGO_HOST:27017' --authenticationDatabase='$DB_NAME' --db='$DB_NAME' get {} "
    set +e
    popd >/dev/null 2>&1 || _error "Error exit from folder $DIR_NAME"
}

mongo_put() {
    local DIR_NAME="${1}"
    local DB_NAME="${2}"
    ORO_FILES_NUM=$(mongofiles --quiet --uri="mongodb://$ORO_MONGO_USER:$ORO_MONGO_PASSWORD@$ORO_MONGO_HOST:27017" --authenticationDatabase="$DB_NAME" --db="$DB_NAME" list | wc -l)
    if [ "$ORO_FILES_NUM" -eq 0 ]; then
        _note "Copy files from: folder $DIR_NAME to mongo DB: $DB_NAME"
        pushd "$DIR_NAME" >/dev/null 2>&1 || _error "Error enter to folder $DIR_NAME"
        set -e
        find . -type f -printf '%P\n' | xargs -r -I {} bash -c "mongofiles --quiet --uri='mongodb://$ORO_MONGO_USER:$ORO_MONGO_PASSWORD@$ORO_MONGO_HOST:27017' --authenticationDatabase='$DB_NAME' --db='$DB_NAME' put {}"
        set +e
        mongofiles --quiet --uri="mongodb://$ORO_MONGO_USER:$ORO_MONGO_PASSWORD@$ORO_MONGO_HOST:27017" --authenticationDatabase="$DB_NAME" --db="$DB_NAME" list
        popd >/dev/null 2>&1 || _error "Error exit from folder $DIR_NAME"
    else
        _note "Skipping copy files from: folder $DIR_NAME to mongo DB: $DB_NAME, because files exist"
    fi
}

copy_files() {
    local SRC_DIR="${1}"
    local DST_DIR="${2}"
    _note "Copy files from $SRC_DIR to $DST_DIR folders"
    mkdir -p "$DST_DIR"
    rsync -a --delete --progress "$SRC_DIR" "$DST_DIR" || _error "Can't copy from $SRC_DIR to $DST_DIR folders"
}

warmup_cache() {
    _note "Warmup cache"
    set -x
    php "$APP_FOLDER/bin/console" cache:warmup || _error "Can't warmup cache"
    set +x
}

clear_cache() {
    local REDIS_CONNECT REDIS_PROTOCOL i
    _note "Clear cache for $ORO_ENV environment"
    set -x
    rm -rf "$APP_FOLDER/var/cache/$ORO_ENV" || _error "Can't clear cache"
    set +x
    i=0
    for REDIS_CONNECT in ORO_REDIS_SESSION_DSN ORO_REDIS_CACHE_DSN ORO_REDIS_DOCTRINE_DSN ORO_REDIS_LAYOUT_DSN; do
        # Check DSN variables in cycle if set or not. In case if not set generate it from ORO_REDIS_URL
        if [[ "X${!REDIS_CONNECT}" == 'X' && "X$ORO_REDIS_URL" != 'X' ]]; then
            REDIS_CONNECT=$ORO_REDIS_URL/$i
            ((i = i + 1))
        else
            REDIS_CONNECT=${!REDIS_CONNECT}
        fi
        # _note "REDIS_CONNECT=$REDIS_CONNECT"
        REDIS_PROTOCOL=$(echo "$REDIS_CONNECT" | cut -d':' -f1)
        if [[ "$REDIS_PROTOCOL" =~ ^redis ]]; then
            set -x
            redis-cli -u "$REDIS_CONNECT" FLUSHDB || {
                set +x
                _error "Can't run FLUSHDB"
            }
            set +x
        fi
    done
}

reindex() {
    _note "Reindex search engine"
    set -x
    php "$APP_FOLDER/bin/console" oro:search:reindex || _error "Can't reindex search"
    set +x
    if bin/console | grep -q oro:website-search:reindex; then
        _note "Reindex website search engine"
        set -x
        php "$APP_FOLDER/bin/console" oro:website-search:reindex || _error "Can't reindex website search"
        set +x
    fi
}

generate_OAuth_keys() {
    if [ ! -f "$APP_FOLDER/var/oauth_public.key" ]; then
        _note "Generate OpenSSL keys"
        openssl genrsa -out "$APP_FOLDER/var/oauth_private.key" 2048
        openssl rsa -in "$APP_FOLDER/var/oauth_private.key" -pubout -out "$APP_FOLDER/var/oauth_public.key"
    fi
}

update_settiings() {
    if [[ "X$ORO_APP_DOMAIN" != "X" ]]; then
        _note "Update URL: $ORO_APP_PROTOCOL://$ORO_APP_DOMAIN"
        set -x
        php "$APP_FOLDER/bin/console" oro:config:update oro_ui.application_url "$ORO_APP_PROTOCOL://$ORO_APP_DOMAIN" || :
        php "$APP_FOLDER/bin/console" oro:config:update oro_website.url "$ORO_APP_PROTOCOL://$ORO_APP_DOMAIN" || :
        php "$APP_FOLDER/bin/console" oro:config:update oro_website.secure_url "$ORO_APP_PROTOCOL://$ORO_APP_DOMAIN" || :
        set +x
    fi
    if "$APP_FOLDER/bin/console" | grep -q 'oro:b2c-config:update' && [[ "X$ORO_APP_DOMAIN_B2C" != 'X' ]]; then
        _note "Update B2C URL: $ORO_APP_PROTOCOL://$ORO_APP_DOMAIN_B2C"
        set -x
        php "$APP_FOLDER/bin/console" oro:b2c-config:update oro_website.url "$ORO_APP_PROTOCOL://$ORO_APP_DOMAIN_B2C" || :
        php "$APP_FOLDER/bin/console" oro:b2c-config:update oro_website.secure_url "$ORO_APP_PROTOCOL://$ORO_APP_DOMAIN_B2C" || :
        set +x
    fi
    if [[ "X$ORO_USER_NAME" != "X" && "X$ORO_USER_EMAIL" != "X" ]]; then
        _note "Update email $ORO_USER_EMAIL for user $ORO_USER_NAME"
        set -x
        php "$APP_FOLDER/bin/console" oro:user:update "$ORO_USER_NAME" --user-email="$ORO_USER_EMAIL" --user-name="$ORO_USER_NAME"
        set +x
    fi
    # if [[ "X$ORO_LANGUAGE" != "X" && "X$ORO_FORMATTING_CODE" != "X" ]]; then
    #     _note "Update language $ORO_LANGUAGE and formating code $ORO_FORMATTING_CODE"
    #     set -x
    #     php "$APP_FOLDER/bin/console" oro:localization:update --formatting-code="$ORO_FORMATTING_CODE" --language="$ORO_LANGUAGE" || :
    #     php "$APP_FOLDER/bin/console" oro:translation:update --all || :
    #     set +x
    # fi
    if [[ "X$ORO_APP_COUNTRY" != "X" ]]; then
        _note "Update country $ORO_APP_COUNTRY"
        set -x
        php "$APP_FOLDER/bin/console" oro:config:update oro_locale.country "$ORO_APP_COUNTRY" || :
        set +x
    fi
    if [[ "X$ORO_APP_TIMEZONE" != "X" ]]; then
        _note "Update timezone $ORO_APP_TIMEZONE"
        set -x
        php "$APP_FOLDER/bin/console" oro:config:update oro_locale.timezone "$ORO_APP_TIMEZONE" || :
        set +x
    fi
    if [[ "X$ORO_APP_TEMPERATURE_UNIT" != "X" ]]; then
        _note "Update temperature_unit $ORO_APP_TEMPERATURE_UNIT"
        set -x
        php "$APP_FOLDER/bin/console" oro:config:update oro_locale.temperature_unit "$ORO_APP_TEMPERATURE_UNIT" || :
        set +x
    fi
    if [[ "X$ORO_APP_WIND_SPEED_UNIT" != "X" ]]; then
        _note "Update wind_speed_unit $ORO_APP_WIND_SPEED_UNIT"
        set -x
        php "$APP_FOLDER/bin/console" oro:config:update oro_locale.wind_speed_unit "$ORO_APP_WIND_SPEED_UNIT" || :
        set +x
    fi
    if [[ "X$ORO_APP_CURRENCY" != "X" ]]; then
        _note "Update currency $ORO_APP_CURRENCY"
        set -x
        php "$APP_FOLDER/bin/console" oro:config:update oro_currency.default_currency "$ORO_APP_CURRENCY" || :
        set +x
    fi
}

entity_extend_update() {
    local RETVAL FILENAME
    FILENAME=$1

    echo "{ \"status\": \"running\", \"timestamp\": $(date +%s) }" >"$ORO_MULTIHOST_OPERATION_FOLDER/$FILENAME"

    _note "Stop consumer services"
    curl --unix-socket /var/run/docker.sock -s -G -XGET "http://localhost/${DOCKER_API_VERSION}/containers/json" -d 'all=1' --data-urlencode "filters={\"name\":[\"/$COMPOSE_PROJECT_NAME-$ORO_CONSUMER_SERVICE-.*\"]}" | jq -r '.[].Id' | xargs -r -I {} curl --unix-socket /var/run/docker.sock -s -G -XPOST "http://localhost/${DOCKER_API_VERSION}/containers/{}/stop" | jq .
    echo "{ \"status\": \"running\", \"timestamp\": $(date +%s) }" >"$ORO_MULTIHOST_OPERATION_FOLDER/$FILENAME"

    _note "Enable maintenance mode"
    sudo -E -u "$ORO_USER_RUNTIME" bash -c "php /var/www/oro/bin/console oro:maintenance:lock -v --no-interaction"
    touch /var/www/oro/var/cache/maintenance_lock
    echo "{ \"status\": \"running\", \"timestamp\": $(date +%s) }" >"$ORO_MULTIHOST_OPERATION_FOLDER/$FILENAME"

    # Use pause instead stop for keep instance IP
    _note "Pause $ORO_PAUSE_SERVICES services"
    curl --unix-socket /var/run/docker.sock -s -G -XGET "http://localhost/${DOCKER_API_VERSION}/containers/json" -d 'all=1' --data-urlencode "filters={\"name\":[\"/$COMPOSE_PROJECT_NAME-$ORO_PAUSE_SERVICES-.*\"]}" | jq -r '.[].Id' | xargs -r -I {} curl --unix-socket /var/run/docker.sock -s -G -XPOST "http://localhost/${DOCKER_API_VERSION}/containers/{}/pause" | jq .
    echo "{ \"status\": \"running\", \"timestamp\": $(date +%s) }" >"$ORO_MULTIHOST_OPERATION_FOLDER/$FILENAME"

    _note "Run 'console oro:entity-extend:update' operation"
    set +e
    sudo -E -u "$ORO_USER_RUNTIME" bash -c "php /var/www/oro/bin/console oro:entity-extend:update --no-interaction"
    RETVAL=$?
    set -e
    if [ $RETVAL -eq 0 ]; then
        _note "Successfully executed entity extend update"
        echo "{ \"status\": \"success\", \"timestamp\": $(date +%s) }" >"$ORO_MULTIHOST_OPERATION_FOLDER/$FILENAME"
    else
        _warn "Unable to execute entity extend update"
        echo "{ \"status\": \"failed\", \"timestamp\": $(date +%s), \"errorCode\": \"$RETVAL\", }" >"$ORO_MULTIHOST_OPERATION_FOLDER/$FILENAME"
    fi

    _note "Restart $ORO_RESTART_SERVICES services"
    curl --unix-socket /var/run/docker.sock -s -G -XGET "http://localhost/${DOCKER_API_VERSION}/containers/json" -d 'all=1' --data-urlencode "filters={\"name\":[\"/$COMPOSE_PROJECT_NAME-$ORO_RESTART_SERVICES-.*\"]}" | jq -r '.[].Id' | xargs -r -I {} curl --unix-socket /var/run/docker.sock -s -G -XPOST "http://localhost/${DOCKER_API_VERSION}/containers/{}/restart" | jq .

    _note "Start $ORO_CONSUMER_SERVICE service"
    curl --unix-socket /var/run/docker.sock -s -G -XGET "http://localhost/${DOCKER_API_VERSION}/containers/json" -d 'all=1' --data-urlencode "filters={\"name\":[\"/$COMPOSE_PROJECT_NAME-$ORO_CONSUMER_SERVICE-.*\"]}" | jq -r '.[].Id' | xargs -r -I {} curl --unix-socket /var/run/docker.sock -s -G -XPOST "http://localhost/${DOCKER_API_VERSION}/containers/{}/start" | jq .

    if [[ -e /var/www/oro/var/cache/maintenance_lock ]]; then
        _note "Disable maintenance mode"
        sudo -E -u "$ORO_USER_RUNTIME" bash -c "php /var/www/oro/bin/console oro:maintenance:unlock -v --no-interaction"
        rm -f /var/www/oro/var/cache/maintenance_lock || :
    fi

    _note "Finish operation"
}

APP_FOLDER=${ORO_APP_FOLDER-/var/www/oro}
if [ "${1:0:1}" = '-' ]; then
    set -- bash "$@"
elif [ "$1" == 'backup' ]; then
    backup_pg_db '/oro_init/db.sql'
    if [[ -f "$APP_FOLDER/config/parameters.yml" ]] && grep -q '^[[:blank:]]*gaufrette_adapter.public' "$APP_FOLDER/config/parameters.yml"; then
        mongo_get '/oro_init/public_storage' "public_${ORO_MONGO_DATABASE}"
        mongo_get '/oro_init/private_storage' "private_${ORO_MONGO_DATABASE}"
    else
        copy_files "$ORO_BACKUP_DATA/public_storage/" '/oro_init/public_storage'
        copy_files "$ORO_BACKUP_DATA/private_storage/" '/oro_init/private_storage'
    fi
    ls -l --recursive '/oro_init/'
    exit 0
elif [ "$1" == 'backup-pg' ]; then
    backup_pg_db '/oro_init/db.sql'
    exit 0
elif [ "$1" == 'backup-mongo' ]; then
    if [[ -f "$APP_FOLDER/config/parameters.yml" ]] && grep -q '^[[:blank:]]*gaufrette_adapter.public' "$APP_FOLDER/config/parameters.yml"; then
        mongo_get '/oro_init/public_storage' "public_${ORO_MONGO_DATABASE}"
        mongo_get '/oro_init/private_storage' "private_${ORO_MONGO_DATABASE}"
    else
        copy_files "$ORO_BACKUP_DATA/public_storage/" '/oro_init/public_storage'
        copy_files "$ORO_BACKUP_DATA/private_storage/" '/oro_init/private_storage'
    fi
    exit 0
elif [[ "$1" == 'restore' || "$1" == 'restore-test' ]]; then
    restore_pg_db '/oro_init/db.sql'
    if [[ -f "$APP_FOLDER/config/parameters.yml" ]] && grep -q '^[[:blank:]]*gaufrette_adapter.public' "$APP_FOLDER/config/parameters.yml"; then
        mongo_put '/oro_init/public_storage' "public_${ORO_MONGO_DATABASE}"
        mongo_put '/oro_init/private_storage' "private_${ORO_MONGO_DATABASE}"
    else
        chk_files=("${APP_FOLDER}"/public/media/*)
        if ((${#chk_files[*]})); then
            _note "Skipping copy files from: folder /oro_init/public_storage/ to $APP_FOLDER/public/media, because folder not empty"
        else
            copy_files '/oro_init/public_storage/' "$APP_FOLDER/public/media"
        fi
        chk_files=("${APP_FOLDER}"/var/data/*)
        if ((${#chk_files[*]})); then
            _note "Skipping copy files from: folder /oro_init/private_storage/ to $APP_FOLDER/var/data, because folder not empty"
        else
            copy_files '/oro_init/private_storage/' "$APP_FOLDER/var/data"
        fi
    fi
    if [[ "$1" == 'restore' ]]; then
        update_settiings
    fi
    warmup_cache
    reindex
    exit 0
elif [[ "$1" == 'restore-pg' ]]; then
    restore_pg_db '/oro_init/db.sql'
    exit 0
elif [[ "$1" == 'restore-mongo' ]]; then
    if [[ -f "$APP_FOLDER/config/parameters.yml" ]] && grep -q '^[[:blank:]]*gaufrette_adapter.public' "$APP_FOLDER/config/parameters.yml"; then
        mongo_put '/oro_init/public_storage' "public_${ORO_MONGO_DATABASE}"
        mongo_put '/oro_init/private_storage' "private_${ORO_MONGO_DATABASE}"
    fi
    exit 0
elif [[ "$1" == 'restore-files' ]]; then
    chk_files=("${APP_FOLDER}"/public/media/*)
    if ((${#chk_files[*]})); then
        _note "Skipping copy files from: folder /oro_init/public_storage/ to $APP_FOLDER/public/media, because folder not empty"
    else
        copy_files '/oro_init/public_storage/' "$APP_FOLDER/public/media"
    fi
    chk_files=("${APP_FOLDER}"/var/data/*)
    if ((${#chk_files[*]})); then
        _note "Skipping copy files from: folder /oro_init/private_storage/ to $APP_FOLDER/var/data, because folder not empty"
    else
        copy_files '/oro_init/private_storage/' "$APP_FOLDER/var/data"
    fi
    exit 0
elif [[ "$1" == 'reindex' ]]; then
    reindex
    exit 0
elif [[ "$1" == 'warmup-cache' ]]; then
    warmup_cache
    exit 0
elif [[ "$1" == 'update-settiings' ]]; then
    update_settiings
    exit 0
elif [[ "$1" == 'generate-oauth-keys' ]]; then
    generate_OAuth_keys
    exit 0
elif [[ "$1" == 'operator' ]]; then
    _note 'Run operator service'
    [ -d "$ORO_MULTIHOST_OPERATION_FOLDER" ] || _error "The folder $ORO_MULTIHOST_OPERATION_FOLDER not exist"
    rm -rf "${ORO_MULTIHOST_OPERATION_FOLDER:?}"/*
    inotifywait -qm -e 'close_write,moved_to' --format '%e %f' "$ORO_MULTIHOST_OPERATION_FOLDER" |
        while read -r ACTION REQUESTFILENAME; do
            [[ $REQUESTFILENAME =~ ^entity_extend_update_.*\.request\.json$ ]] || continue
            _note "Get ACTION=$ACTION REQUESTFILENAME=$ORO_MULTIHOST_OPERATION_FOLDER/$REQUESTFILENAME"
            OPERATION_NAME=$(jq -r '.operationName' "$ORO_MULTIHOST_OPERATION_FOLDER/$REQUESTFILENAME")
            RESPONSEFILENAME=$(jq -r '.responseFileName' "$ORO_MULTIHOST_OPERATION_FOLDER/$REQUESTFILENAME")
            [[ -e "$ORO_MULTIHOST_OPERATION_FOLDER/$RESPONSEFILENAME" ]] && continue
            [[ $DEBUG ]] && _note "Detect OPERATION_NAME=$OPERATION_NAME"
            case "$OPERATION_NAME" in
            entity_extend_update)
                entity_extend_update "$RESPONSEFILENAME"
                # rm -fv "$ORO_MULTIHOST_OPERATION_FOLDER/$REQUESTFILENAME" || :
                ;;
            esac
        done
    exit 0
elif [[ "$1" == 'update' ]]; then
    clear_cache
    _note 'Run console oro:platform:update --force'
    php "$APP_FOLDER/bin/console" oro:platform:update --force
    exit 0
fi

exec "$@"
