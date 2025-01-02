#!/bin/bash
set -eo pipefail
shopt -s nullglob

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

termHandler() {
    set +x
    local TESTPATH
    TESTPATH=$2
    _note "Received TERM signal. Stopping $1 test $TESTPATH"
    # pgrep -f bin/behat | xargs -r kill

    if [[ "X$1" == 'Xbehat' && "X$TESTPATH" != 'X' ]]; then
        MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_BEHAT -BNe "UPDATE behat_stat SET time = NULL WHERE build_tag = '${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}' AND path = '$TESTPATH' AND time = 0;" 2>>"$APP_FOLDER/var/logs/mysql_stat_errors.txt" || _error "ERROR can't clear execution time for $TESTPATH ${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}"
    elif [[ "X$1" == 'Xfunctional' && "X$TESTPATH" != 'X' ]]; then
        MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_FUNCTIONAL -BNe "UPDATE functional_stat SET time = NULL WHERE build_tag = '${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}' AND path = '$TESTPATH' AND time = 0;" 2>>"$APP_FOLDER/var/logs/mysql_stat_errors.txt" || _error "ERROR can't clear execution time for $TESTPATH ${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}"
    fi
    exit 143
}

if [ "${1:0:1}" = '-' ]; then
    set -- bash "$@"
elif [ "$1" == 'console' ]; then
    APP_FOLDER=${ORO_APP_FOLDER-/var/www/oro}
    # printenv | sort
    _note "$@"
    shift
    set -- php "$APP_FOLDER/bin/console" "$@"
elif [[ "$1" == 'php-fpm' ]]; then
    mkdir -p /run/php-fpm
    set -- "$@" --nodaemonize
elif [[ "$1" == 'nginx' ]]; then
    set -- "$@"
elif [[ "$1" =~ '-- cron' || "$1" =~ cron$ ]]; then
    shift
    set -- crond -n -x bit -m off "$@"
elif [[ "$1" == 'functional-get-tests-number' ]]; then # Used to get tests number for start
    MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_FUNCTIONAL -BNe "SELECT count(*) FROM functional_stat WHERE build_tag = '${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}' AND time IS NULL;" 2>/dev/null
    exit 0
elif [[ "$1" == 'functional-get-stat' ]]; then # Used for get execution time all tests
    # Get execution time for all test. Then divide it to required time and get number nodes
    MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_FUNCTIONAL -BNe "SELECT IFNULL(ROUND(SUM(t1.time)), 0) AS time FROM (SELECT AVG(time) AS time FROM functional_stat WHERE time IS NOT NULL AND DATE(created_at) > (NOW() - INTERVAL 7 DAY) AND path IN (SELECT path FROM functional_stat WHERE build_tag = '${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}' ) GROUP BY path) as t1;" 2>/dev/null
    exit 0
elif [[ "$1" == 'functional-init' ]]; then # Used for create DB with statistics and fill tests
    _note "Use host=$ORO_DB_STAT_HOST dbname=$ORO_DB_STAT_NAME_FUNCTIONAL build_tag=${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}"
    APP_FOLDER=${ORO_APP_FOLDER-/var/www/oro}
    # Create DB and tables. Need it if run local and use local DB for statistics
    MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 -Be "create database IF NOT EXISTS $ORO_DB_STAT_NAME_FUNCTIONAL"
    MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_FUNCTIONAL -Be "CREATE TABLE IF NOT EXISTS functional_stat (id INT NOT NULL AUTO_INCREMENT, PRIMARY KEY(id), path varchar(1024) COLLATE utf8_unicode_ci DEFAULT NULL, build_tag varchar(100) COLLATE utf8_unicode_ci DEFAULT NULL, UNIQUE KEY IDX_FUNC_BUILD_TAG (path(500), build_tag(100)), created_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, time INT(10) DEFAULT NULL)"
    # By default mysql not allow use local infile. Check this and enable. For enable use root user.
    LOCAL_INFILE=$(MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_FUNCTIONAL -BNe "SELECT @@GLOBAL.local_infile;" 2>>"$APP_FOLDER/var/logs/mysql_stat_errors.txt")
    if [[ "X$LOCAL_INFILE" != "X1" ]]; then
        MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --local-infile=1 --user=root --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_FUNCTIONAL -Be 'SET GLOBAL local_infile=1;' 2>>"$APP_FOLDER/var/logs/mysql_stat_errors.txt" || :
    fi
    # Collect tests and load it to DB with time=NULL. We use check if time=NULL for detect if test was executed.
    pushd "$APP_FOLDER" >/dev/null 2>&1 || _error "Can't go to folder $APP_FOLDER"
    if [[ "X$TESTS_LIST" == "X" ]]; then
        ORO_TESTS_PATH="${ORO_TESTS_PATH-vendor/oro}"
        _note "Collect tests from $ORO_TESTS_PATH"
        TESTS_LIST=$(find -L "$ORO_TESTS_PATH" -ipath "**tests/functional" -print0 | xargs -0 -r -I{} find -L {} -maxdepth 1 -mindepth 1 \( -name "*[tT]est.php" -o -type d \) | xargs -r -I{} sh -c "test -f {} && grep -Li 'abstract class' {} || echo {}" | sort -u | grep -E -v $EXCLUDED_TESTS - || : | xargs -r -I{} echo "{}")
        if [[ "X$TESTS_LIST" == 'X' ]]; then
            _warn "Tests not found. Nothing to test."
            exit 0
        fi
    fi
    _note "List tests:"
    echo "$TESTS_LIST"
    echo "$TESTS_LIST" | xargs -r -n1 | sort -u | grep -E -v $EXCLUDED_TESTS - | xargs -r -I{} echo "'{}','${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}'" | MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --local-infile=1 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_FUNCTIONAL -Be "LOAD DATA LOCAL INFILE '/dev/stdin' REPLACE INTO TABLE functional_stat COLUMNS TERMINATED BY ',' ENCLOSED BY '\'' (path, build_tag) ;"
    _note "List tests from DB:"
    MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_FUNCTIONAL -BNe "SELECT t1.path as path FROM functional_stat AS t1 WHERE t1.build_tag = '${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}' AND t1.time IS NULL ORDER BY (SELECT MAX(t2.time) FROM functional_stat AS t2 WHERE t2.path=t1.path AND DATE(created_at) > (NOW() - INTERVAL 7 DAY)) DESC;" 2>>"$APP_FOLDER/var/logs/mysql_stat_errors.txt"
    popd >/dev/null 2>&1 || _error "Can't back from folder $APP_FOLDER"
    exit 0
elif [[ "$1" == 'functional' ]]; then
    RETVAL_GLOBAL=0
    APP_FOLDER=${ORO_APP_FOLDER-/var/www/oro}
    ORO_TEST_SUTE_FUNCTIONAL=${ORO_TEST_SUTE_FUNCTIONAL-functional}
    # trap 'copy_logs $APP_FOLDER' EXIT INT TERM
    if [[ "X$ORO_FUNCTIONAL_ARGS" == "X" ]]; then
        mkdir -p "$APP_FOLDER"/var/logs/{junit,functional}
        _note "Use host=$ORO_DB_STAT_HOST dbname=$ORO_DB_STAT_NAME_FUNCTIONAL build_tag=${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}"
        # In cycle get next test name for run.
        while true; do
            TESTPATH=$(MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=50 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_FUNCTIONAL -BNe "START TRANSACTION; SELECT @P := t1.path FROM functional_stat AS t1 WHERE t1.build_tag = '${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}' AND t1.time IS NULL ORDER BY (SELECT MAX(t2.time) FROM functional_stat AS t2 WHERE t2.path=t1.path AND DATE(created_at) > (NOW() - INTERVAL 7 DAY)) DESC LIMIT 1 FOR UPDATE; UPDATE functional_stat SET time = '0' WHERE build_tag = '${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}' AND path = @P; COMMIT;" 2>>"$APP_FOLDER/var/logs/mysql_stat_errors.txt" || _error "ERROR can't get test path with build_tag=${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}")
            # Check if have test for run. And exit if empty
            [[ "X$TESTPATH" == 'X' ]] && break
            trap 'termHandler functional $TESTPATH' SIGTERM
            LOGNAME="$(echo -n "$TESTPATH" | sed 's|[Tt]ests/[Ff]unctional/||g; s|vendor/||g; s|\/|_|g' | tail -c 230)"
            ts=$(date +%s%N)
            set +e
            # Save execution time in file and then use it for put in DB. Log saved in tmp file. If test failed it will collect in error file and show at the end. Passed tests are shown immediately.
            "$APP_FOLDER/bin/phpunit" --do-not-cache-result --testsuite="$ORO_TEST_SUTE_FUNCTIONAL" --colors=always "$TESTPATH" $ORO_FUNCTIONAL_ARGS --log-junit="var/logs/junit/functional_$LOGNAME.xml" >"$APP_FOLDER/var/logs/functional_output.log" 2>&1
            RETVAL=$?
            set -e
            tt=$((($(date +%s%N) - $ts) / 1000000))
            if [[ $RETVAL -eq 0 ]]; then
                # Show log
                _note "Testing $TESTPATH"
                cat "$APP_FOLDER/var/logs/functional_output.log"
                MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_FUNCTIONAL -BNe "UPDATE functional_stat SET time = '$tt' WHERE build_tag = '${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}' AND path = '$TESTPATH';" 2>>"$APP_FOLDER/var/logs/mysql_stat_errors.txt" || _error "ERROR can't update execution time for $TESTPATH ${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}"
            else
                # Collect logs to error log and set variable that test failed
                cat "$APP_FOLDER/var/logs/functional_output.log" >>"$APP_FOLDER/var/logs/functional_errors.log"
                RETVAL_GLOBAL=1
            fi
            [[ -e "$APP_FOLDER/var/logs/functional_output.log" ]] && mv -f "$APP_FOLDER/var/logs/functional_output.log" "$APP_FOLDER/var/logs/functional/${LOGNAME}.output.log" || :
            [[ -e "$APP_FOLDER/var/logs/test.log" ]] && mv -f "$APP_FOLDER/var/logs/test.log" "$APP_FOLDER/var/logs/functional/$LOGNAME.test.log" || :
        done
    else
        trap 'termHandler functional' SIGTERM
        mkdir -p "$APP_FOLDER"/var/logs/{junit,functional}
        set -x +e
        "$APP_FOLDER/bin/phpunit" --do-not-cache-result --colors=always --log-junit="var/logs/junit/functional.xml" $ORO_FUNCTIONAL_ARGS
        RETVAL=$?
        set -e +x
        if [ $RETVAL -ne 0 ]; then
            RETVAL_GLOBAL=1
        fi
        [[ -e "$APP_FOLDER/var/logs/test.log" ]] && mv -f "$APP_FOLDER/var/logs/test.log" "$APP_FOLDER/logs/functional/test.log" || :
    fi
    # reset owner for logs
    # chown -R "$CURRENT_UID" "$APP_FOLDER/var/logs"
    [[ -d "$APP_FOLDER/var/logs_host" ]] && cp -rf "$APP_FOLDER"/var/logs/* "$APP_FOLDER"/var/logs_host/ || :
    [[ -d "$APP_FOLDER/var/logs_host" ]] && chown -R "$CURRENT_UID" "$APP_FOLDER/var/logs_host" || :
    [[ -e "$APP_FOLDER/var/logs/functional_errors.log" ]] && cat "$APP_FOLDER/var/logs/functional_errors.log"
    if [[ "X$ORO_DEBUG_STOP" != "X" ]]; then
        _warn "Sleep for debug"
        tail -f /dev/null
    fi
    exit $RETVAL_GLOBAL
elif [[ "$1" == 'behat-get-tests-number' ]]; then # Used to get tests number for start
    MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_BEHAT -BNe "SELECT count(*) FROM behat_stat WHERE build_tag = '${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}' AND time IS NULL;" 2>/dev/null
    exit 0
elif [[ "$1" == 'behat-get-stat' ]]; then # Used for get execution time all tests
    # Get execution time for all test. Then divide it to required time and get number nodes
    MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_BEHAT -BNe "SELECT IFNULL(ROUND(SUM(t1.time)), 0) AS time FROM (SELECT AVG(time) AS time FROM behat_stat WHERE time IS NOT NULL AND DATE(created_at) > (NOW() - INTERVAL 7 DAY) AND path IN (SELECT path FROM behat_stat WHERE build_tag = '${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}' ) GROUP BY path) as t1;" 2>/dev/null
    exit 0
elif [[ "$1" == 'behat-init' ]]; then # Used for create DB with statistics and fill tests
    APP_FOLDER=${ORO_APP_FOLDER-/var/www/oro}
    _note "Use host=$ORO_DB_STAT_HOST dbname=$ORO_DB_STAT_NAME_BEHAT build_tag=${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}"
    # Create DB and tables. Need it if run local and use local DB for statistics
    MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 -Be "create database IF NOT EXISTS $ORO_DB_STAT_NAME_BEHAT" 2>>"$APP_FOLDER/var/logs/mysql_stat_errors.txt"
    MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_BEHAT -Be "CREATE TABLE IF NOT EXISTS behat_stat (id INT NOT NULL AUTO_INCREMENT, PRIMARY KEY(id), path varchar(1024) COLLATE utf8_unicode_ci DEFAULT NULL, build_tag varchar(100) COLLATE utf8_unicode_ci DEFAULT NULL, UNIQUE KEY IDX_FUNC_BUILD_TAG (path(500), build_tag(100)), created_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, time INT(10) DEFAULT NULL, attempt INT(8) DEFAULT NULL)" 2>>"$APP_FOLDER/var/logs/mysql_stat_errors.txt"
    # By default mysql not allow use local infile. Check this and enable. For enable use root user.
    LOCAL_INFILE=$(MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_BEHAT -BNe "SELECT @@GLOBAL.local_infile;" 2>>"$APP_FOLDER/var/logs/mysql_stat_errors.txt")
    if [[ "X$LOCAL_INFILE" != "X1" ]]; then
        MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --local-infile=1 --user=root --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_BEHAT -Be 'SET GLOBAL local_infile=1;' 2>>"$APP_FOLDER/var/logs/mysql_stat_errors.txt" || :
    fi
    # Remove tests with tag before add and if tag not empty
    if [[ "X${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}" != 'X' ]]; then
        MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_BEHAT -BNe "DELETE FROM behat_stat WHERE build_tag='${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}';" 2>>"$APP_FOLDER/var/logs/mysql_stat_errors.txt"
    fi
    # Collect tests and load it to DB with time=NULL. We use check if time=NULL for detect if test was executed.
    pushd "$APP_FOLDER" >/dev/null 2>&1 || _error "Can't go to folder $APP_FOLDER"
    if [[ "X$TESTS_LIST" == "X" ]]; then
        mkdir -p "$APP_FOLDER"/var/logs/{junit,behat}
        # Prepare behat.yml and run behat for recive features
        if [[ ! -e "$APP_FOLDER/var/logs/behat/behat.yml" ]]; then
            ORO_ARTIFACT_DIR=${ORO_ARTIFACT_DIR-'behat/'}
            if [[ "X$ORO_APP_PROTOCOL" == 'Xhttps' ]]; then
                NGINX_PORT=$ORO_NGINX_HTTPS_PORT
            else
                NGINX_PORT=$ORO_NGINX_HTTP_PORT
            fi
            # Don't set port if it's standart
            if [[ $NGINX_PORT -eq 80 || $NGINX_PORT -eq 443 ]]; then
                NGINX_PORT=''
            else
                NGINX_PORT=":$NGINX_PORT"
            fi
            sed "/wd_host:/s|wd_host:.*|wd_host: 'http://$ORO_CHROME_HOST:$ORO_CHROME_PORT'|g; s|@ORO_APP_DOMAIN@|$ORO_APP_PROTOCOL://$ORO_APP_DOMAIN${NGINX_PORT}/|g; s|@BUILD_URL@|$BUILD_URL|g; s|@ARTIFACT_DIR@|$ORO_ARTIFACT_DIR|g; s|@ORO_APP_FOLDER@|$ORO_APP_FOLDER|g" "$APP_FOLDER/behat_oro.yml" >"$APP_FOLDER/var/logs/behat/behat.yml"
        fi
        _note "List features from behat:"
        set -x
        "$APP_FOLDER/bin/behat" -v --available-features --tags="$ORO_BEHAT_TAGS" $ORO_BEHAT_OPTIONS -c "$APP_FOLDER/var/logs/behat/behat.yml"
        set +x
        "$APP_FOLDER/bin/behat" --available-features --tags="$ORO_BEHAT_TAGS" $ORO_BEHAT_OPTIONS -c "$APP_FOLDER/var/logs/behat/behat.yml" | sort -u | sed "s|^$APP_FOLDER/||" | xargs -r -i echo "'{}','${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}'" | MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --local-infile=1 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_BEHAT -Be "LOAD DATA LOCAL INFILE '/dev/stdin' REPLACE INTO TABLE behat_stat COLUMNS TERMINATED BY ',' ENCLOSED BY '\'' (path, build_tag) ;" 2>>"$APP_FOLDER/var/logs/mysql_stat_errors.txt"
    else
        echo "$TESTS_LIST" | xargs -r -n1 | sort -u | xargs -r -i echo "'{}','${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}'" | MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --local-infile=1 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_BEHAT -Be "LOAD DATA LOCAL INFILE '/dev/stdin' REPLACE INTO TABLE behat_stat COLUMNS TERMINATED BY ',' ENCLOSED BY '\'' (path, build_tag) ;" 2>>"$APP_FOLDER/var/logs/mysql_stat_errors.txt"
    fi
    _note "List features from DB:"
    MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_BEHAT -BNe "SELECT t1.path as path FROM behat_stat AS t1 WHERE t1.build_tag = '${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}' AND t1.time IS NULL ORDER BY (SELECT MAX(t2.time) FROM behat_stat AS t2 WHERE t2.path=t1.path AND DATE(created_at) > (NOW() - INTERVAL 7 DAY)) DESC;" 2>>"$APP_FOLDER/var/logs/mysql_stat_errors.txt"
    popd >/dev/null 2>&1 || _error "Can't back from folder $APP_FOLDER"
    # wait to prevent quick exit and second run
    sleep 15
    exit 0
elif [[ "$1" == 'behat' ]]; then
    shift
    APP_FOLDER=${ORO_APP_FOLDER-/var/www/oro}
    mkdir -p "$APP_FOLDER"/var/logs/{junit,behat}
    # WEBSERVER_IP=$(dig -4 "$ORO_NGINX_HOST" +short)
    # _note "Point $ORO_APP_DOMAIN to $WEBSERVER_IP in /etc/hosts"
    # echo "$WEBSERVER_IP $ORO_APP_DOMAIN $ORO_APP_ADDON_DOMAINS" >>/etc/hosts
    if [[ ! -e "$APP_FOLDER/var/logs/behat/behat.yml" ]]; then
        if [[ "X$ORO_APP_PROTOCOL" == 'Xhttps' ]]; then
            NGINX_PORT=$ORO_NGINX_HTTPS_PORT
        else
            NGINX_PORT=$ORO_NGINX_HTTP_PORT
        fi
        # Don't set port if it's standart
        if [[ $NGINX_PORT -eq 80 || $NGINX_PORT -eq 443 ]]; then
            NGINX_PORT=''
        else
            NGINX_PORT=":$NGINX_PORT"
        fi
        ORO_ARTIFACT_DIR=${ORO_ARTIFACT_DIR-'behat/'}
        sed "/wd_host:/s|wd_host:.*|wd_host: 'http://$ORO_CHROME_HOST:$ORO_CHROME_PORT'|g; s|@ORO_APP_DOMAIN@|$ORO_APP_PROTOCOL://$ORO_APP_DOMAIN${NGINX_PORT}/|g; s|@BUILD_URL@|$BUILD_URL|g; s|@ARTIFACT_DIR@|$ORO_ARTIFACT_DIR|g; s|@ORO_APP_FOLDER@|$ORO_APP_FOLDER|g" "$APP_FOLDER/behat_oro.yml" >"$APP_FOLDER/var/logs/behat/behat.yml"
    fi
    # Install CAROOT certificate to Firefox and/or Chrome/Chromium trust store
    # TODO: Add home folder for www-data
    # if [[ -f "$CAROOT/rootCA-key.pem" && -f "$CAROOT/rootCA.pem" ]]; then
    #     _note "Install CAROOT sertificate in nss from $CAROOT"
    # if [[ ! -d "$HOME/.pki/nssdb" ]]; then
    #     mkdir -p "$HOME/.pki/nssdb"
    #     chmod 700 "$HOME/.pki/nssdb"
    #     certutil -N --empty-password -d "$HOME/.pki/nssdb"
    # fi
    # TRUST_STORES=nss mkcert -install
    # fi
    RETVAL_GLOBAL=0
    # trap 'copy_logs $APP_FOLDER' EXIT INT TERM
    if [[ "X$ORO_BEHAT_ARGS" == "X" ]]; then
        _note "Use host=$ORO_DB_STAT_HOST dbname=$ORO_DB_STAT_NAME_BEHAT build_tag=${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}"
        # In cycle get next test name for run.
        while :; do
            TESTPATH=$(MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=50 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_BEHAT -BNe "START TRANSACTION; SELECT @P := t1.path FROM behat_stat AS t1 WHERE t1.build_tag = '${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}' AND t1.time IS NULL ORDER BY (SELECT MAX(t2.time) FROM behat_stat AS t2 WHERE t2.path=t1.path AND DATE(created_at) > (NOW() - INTERVAL 7 DAY)) DESC LIMIT 1 FOR UPDATE; UPDATE behat_stat SET time = '0' WHERE build_tag = '${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}' AND path = @P; COMMIT;" 2>>"$APP_FOLDER/var/logs/mysql_stat_errors.txt" || _error "ERROR can't get test path with build_tag=${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}")
            # Check if have test for run. And exit if empty
            [[ "X$TESTPATH" == 'X' ]] && break
            trap 'termHandler behat $TESTPATH' SIGTERM
            attempt=0
            while [[ $attempt -lt ${ORO_BEHAT_ATTEMPTS:-1} ]]; do
                attempt=$((attempt + 1))
                _note "Attempt=$attempt from ${ORO_BEHAT_ATTEMPTS:-1} Testing $TESTPATH"
                LOGNAME="$(echo -n "$TESTPATH" | sed 's|[Tt]ests/[Bb]ehat/[Ff]eatures/||g; s|vendor/||g; s|\.feature||g; s|\/|_|g' | tail -c 230)_$attempt"
                ts=$(date +%s%N)
                set +e -x
                # Save execution time in file and then use it for put in DB. Log saved in tmp file. If test failed it will collect in error file and show at the end. Passed tests are shown immediately.
                "$APP_FOLDER/bin/behat" -c "$APP_FOLDER/var/logs/behat/behat.yml" --do-not-run-consumer --strict --colors -f pretty -o std -f junit -o "var/logs/junit/$LOGNAME" $ORO_BEHAT_OPTIONS "$@" $ORO_BEHAT_ARGS -- "$APP_FOLDER/$TESTPATH" 2>&1 | tee -a "$APP_FOLDER/var/logs/behat_output.log"
                RETVAL=$?
                set -e +x
                tt=$((($(date +%s%N) - $ts) / 1000000))
                # Show log with cat to prevent mix output from different threads
                # cat "$APP_FOLDER/var/logs/behat_output.log" || :
                [[ -e "$APP_FOLDER/var/logs/prod.log" ]] && mv -f "$APP_FOLDER/var/logs/prod.log" "$APP_FOLDER/var/logs/behat/$LOGNAME.prod.log"
                [[ -e "$APP_FOLDER/var/logs/mq.log" ]] && mv -f "$APP_FOLDER/var/logs/mq.log" "$APP_FOLDER/var/logs/behat/$LOGNAME.mq.log"
                [[ -e "$APP_FOLDER/var/logs/browser.log" ]] && mv -f "$APP_FOLDER/var/logs/browser.log" "$APP_FOLDER/var/logs/behat/$LOGNAME.browser.log"
                if [[ $RETVAL -ne 0 ]]; then
                    # Collect logs to error log and set variable that test failed
                    mv -f "$APP_FOLDER/var/logs/behat_output.log" "$APP_FOLDER/var/logs/$LOGNAME.errors.log" || :
                    # set RETVAL_GLOBAL only for last attempt or fatal error
                    if [[ $attempt -ge ${ORO_BEHAT_ATTEMPTS:-1} ]]; then
                        RETVAL_GLOBAL=$RETVAL
                    fi
                    # exit code 1 means that behat failed, but isolators restored state and ready run next test
                    # if >1, break 2 cycles and restore state
                    if [[ $RETVAL -gt 1 ]]; then
                        RETVAL_GLOBAL=$RETVAL
                        break 2
                    fi
                else
                    MYSQL_PWD=$ORO_DB_STAT_PASSWORD mysql --connect-timeout=5 --user=$ORO_DB_STAT_USER --host=$ORO_DB_STAT_HOST --port=3306 $ORO_DB_STAT_NAME_BEHAT -BNe "UPDATE behat_stat SET time = '$tt', attempt = '$attempt' WHERE build_tag = '${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}' AND path = '$TESTPATH';" 2>>"$APP_FOLDER/var/logs/mysql_stat_errors.txt" || _error "ERROR can't update execution time for $TESTPATH ${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}"
                    mv -f "$APP_FOLDER/var/logs/behat_output.log" "$APP_FOLDER/var/logs/behat/$LOGNAME.output.log" || :
                    break
                fi
            done
        done
    else
        trap 'termHandler behat' SIGTERM
        set -x +e
        "$APP_FOLDER/bin/behat" -c "$APP_FOLDER/var/logs/behat/behat.yml" --do-not-run-consumer --strict --colors -f pretty -o std -f junit -o var/logs/junit $ORO_BEHAT_OPTIONS "$@" -- $ORO_BEHAT_ARGS
        RETVAL=$?
        set -e +x
        if [ $RETVAL -ne 0 ]; then
            RETVAL_GLOBAL=1
        fi
        [[ -e "$APP_FOLDER/var/logs/prod.log" ]] && mv -f "$APP_FOLDER/var/logs/prod.log" "$APP_FOLDER/var/logs/behat/prod.log"
        [[ -e "$APP_FOLDER/var/logs/mq.log" ]] && mv -f "$APP_FOLDER/var/logs/mq.log" "$APP_FOLDER/var/logs/behat/mq.log"
        [[ -e "$APP_FOLDER/var/logs/browser.log" ]] && mv -f "$APP_FOLDER/var/logs/browser.log" "$APP_FOLDER/var/logs/behat/browser.log"
    fi
    # reset owner for logs
    # chown -R "$CURRENT_UID" "$APP_FOLDER/var/logs"
    [[ -d "$APP_FOLDER/var/logs_host" ]] && cp -rf "$APP_FOLDER"/var/logs/* "$APP_FOLDER"/var/logs_host/ || :
    [[ -d "$APP_FOLDER/var/logs_host" ]] && chown -R "$CURRENT_UID" "$APP_FOLDER/var/logs_host" || :
    # [[ -e "$APP_FOLDER/var/logs/behat_errors.log" ]] && cat "$APP_FOLDER/var/logs/behat_errors.log"
    if [[ "X$ORO_DEBUG_STOP" != "X" ]]; then
        _warn "Sleep for debug"
        tail -f /dev/null
    fi
    exit $RETVAL_GLOBAL
fi

exec "$@"
