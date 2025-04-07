#!/bin/bash
# Script wraps execution of dependency management tools (composer and npm) to
# application builder contatiner so no additional software should be installed on the host.
# By default runs dependencies installation

set -e
PROGNAME="${0##*/}"
RED='\033[1;31m' # Red color
NC='\033[0m'     # No Color

help() {
    local OPTIONS_SPEC="\

$PROGNAME is a wrapper for all composer operations that allow to isolate host dependencies on composer, php and nodejs

$PROGNAME [options] [-- '<composer command>']

options:

-h  | --help            this help
-b  | --baseline        docker images baseline version
-s  | --source          path to application source code. Default is current folder
-r  | --repositorypath  path to application dependancy repositories in case if composer dependencyes relying on local filesystem
-p  | --properties      enable mongo and/or redis in parameters.yml. If you specify both services, put in quotes and separate with a space
-- <composer command>   command for composer. If not set, by default use '--optimize-autoloader --prefer-dist install' command

All composer environment variables supported: https://getcomposer.org/doc/03-cli.md#environment-variables.

Example: COMPOSER=dev.json COMPOSER_AUTH='\"http-basic\": {\"github.com\": {\"username\": \"x-access-token\", \"password\": \"xxx\"}}' composer.sh -b 5.1-1.0 -s /path/to/application -r /path/to/repository -p 'mongo redis'
"
    echo "$OPTIONS_SPEC"

}

BASELINE_VERSION='master-latest'
ORO_PUBLIC_PROJECT=${ORO_PUBLIC_PROJECT-harborio.oro.cloud/oro-platform-public}
# path to application source code. Can be defined with "-s" option
APP_SRC="$PWD"
# path to composer repositories on local file system. Can be defined with "-r" option
REPO_PATH="$APP_SRC"
# command passed to composer
COMPOSER_COMMAND='--optimize-autoloader --prefer-dist install'
COMPOSER_VARIABLES='-e COMPOSER -e COMPOSER_ALLOW_SUPERUSER -e COMPOSER_ALLOW_XDEBUG -e COMPOSER_AUTH -e COMPOSER_BIN_DIR -e COMPOSER_CACHE_DIR -e COMPOSER_CAFILE -e COMPOSER_DISABLE_XDEBUG_WARN -e COMPOSER_DISCARD_CHANGES -e COMPOSER_HOME -e COMPOSER_HTACCESS_PROTECT -e COMPOSER_MEMORY_LIMIT -e COMPOSER_MIRROR_PATH_REPOS -e COMPOSER_NO_INTERACTION -e COMPOSER_PROCESS_TIMEOUT -e COMPOSER_ROOT_VERSION -e COMPOSER_VENDOR_DIR -e COMPOSER_RUNTIME_ENV -e HTTP_PROXY -e COMPOSER_MAX_PARALLEL_HTTP -e HTTP_PROXY_REQUEST_FULLURI -e HTTPS_PROXY_REQUEST_FULLURI -e COMPOSER_SELF_UPDATE_TARGET -e NO_PROXY -e COMPOSER_DISABLE_NETWORK -e COMPOSER_DEBUG_EVENTS -e COMPOSER_NO_DEV -e COMPOSER_PREFER_STABLE -e COMPOSER_PREFER_LOWEST -e COMPOSER_IGNORE_PLATFORM_REQ -e COMPOSER_IGNORE_PLATFORM_REQS'
# services which can be set in parameters.yml
PROPERTIES=''

set +e
OPTIONS=$(getopt -q -n "$PROGNAME" -o hb:s:r:p: -l help,baseline:,source:,repositorypath:,properties: -- "$@")
RETVAL=$?
if [ $RETVAL -ne 0 ]; then
    echo "ERROR: unrecognized option: $1" >&2
    exit 1
fi
eval set -- "$OPTIONS"
set -e
while :; do
    case "$1" in
    -h | --help)
        set +x
        help
        exit 0
        ;;
    -b | --baseline)
        shift
        if [[ "X$1" != "X" ]]; then
            BASELINE_VERSION="$1"
        fi
        ;;
    -s | --source)
        shift
        if [[ "X$1" != "X" ]]; then
            APP_SRC="$1"
        fi
        ;;
    -r | --repositorypath)
        shift
        if [[ "X$1" != "X" ]]; then
            REPO_PATH="$1"
        fi
        ;;
    -p | --properties)
        shift
        if [[ "X$1" != "X" ]]; then
            PROPERTIES=$1
        fi
        ;;
    --)
        shift
        # Check if composer command parameter defined
        if [[ "X$1" != "X" ]]; then
            COMPOSER_COMMAND="$*"
        fi
        break
        ;;
    *)
        echo "ERROR: unrecognized option: $1"
        exit 1
        ;;
    esac
    shift
done

run_composer() {
    # Try to pull before manual, because --pull always fail if image not exist remotely https://github.com/moby/moby/issues/36794
    docker image pull --quiet "$ORO_PUBLIC_PROJECT/builder:$BASELINE_VERSION" ||:
    # Run composer
    set -x
    time docker run --rm --memory=7g --security-opt label=disable --tmpfs /tmp -u "$(id -u):$(id -g)" -v "/etc/group:/etc/group:ro" -v "/etc/passwd:/etc/passwd:ro" -v "/etc/shadow:/etc/shadow:ro" -v "${HOME}":"${HOME}" -v "$REPO_PATH":"$REPO_PATH" -v "$APP_SRC":"$APP_SRC" -w "$APP_SRC" -e ORO_DB_VERSION $COMPOSER_VARIABLES "$ORO_PUBLIC_PROJECT/builder:$BASELINE_VERSION" bash -c "set -x && composer -vvv --ansi --no-interaction --working-dir='$APP_SRC' $1" || {
        set +x
        echo -e "${RED}ERROR to run composer${NC}"
        exit 1
    }
    set +x
}

usage() {
    [ -z "$*" ] || echo "$*"
    echo "Try \`$PROGNAME --help' for more information." >&2
    exit 1
}

if [[ -d "$APP_SRC" ]]; then
    APP_SRC=$(realpath "$APP_SRC")
else
    echo "ERROR: Can't find application source code folder."
    exit 1
fi
if [[ -d "$REPO_PATH" ]]; then
    REPO_PATH=$(realpath "$REPO_PATH")
else
    echo "ERROR: Can't find repository folder."
    exit 1
fi

# shellcheck disable=SC1091
[[ -f "$APP_SRC/.env-build" ]] && . "$APP_SRC/.env-build"
# shellcheck disable=SC1090
[[ -f "$DOT_ENV_BUILD" ]] && . "$DOT_ENV_BUILD"

run_composer "$COMPOSER_COMMAND"
if [[ "X$PROPERTIES" != 'X' ]]; then
    run_composer "set-parameters $PROPERTIES"
fi
