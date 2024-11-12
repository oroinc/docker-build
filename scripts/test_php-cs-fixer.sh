#!/bin/bash

set -e
PROGNAME="${0##*/}"
RED='\033[1;31m' # Red color
NC='\033[0m'     # No Color

help() {
    local OPTIONS_SPEC="\

$PROGNAME is a wrapper for run php-cs-fixer operations that allow to isolate host dependencies

$PROGNAME [options]

options:

-h                     | --help                        this help
-b                     | --baseline                    docker images baseline version
-s                     | --source                      application source floder. default is current folder
-r <folder>            | --repositorypath=<folder>     path to application dependancy repositories in case if composer dependencyes relying on local filesystem

Example: $PROGNAME

Supported environments variables. All variables can set in order from .env file, then from source folder .env-build and finaly from variable DOT_ENV_BUILD. You can also set them on the command line.

BUILD_CONFIG            folder where located config file for phpmd. Default is vendor/oro/platform/build
FILE_DIFF               diff file name with list of changed files. Without it or empty check all php files. Default is diff.txt

"
    echo "$OPTIONS_SPEC"

}

BASELINE_VERSION='master-latest'
APP_SRC="$PWD"
ORO_PUBLIC_PROJECT=${ORO_PUBLIC_PROJECT-harborio.oro.cloud/oro-platform-public}
WORKDIR=''
BUILD_CONFIG="${BUILD_CONFIG-vendor/oro/platform/build}"
DIFF_PHP="diff_php-cs-fixer.txt"
FILE_DIFF="diff.txt"
EXCLUDED_PACKAGES="(/doctrine-extensions|/magento1|/crm-magento1-connector|/magento-contact-us|/crm-magento-embedded-contact-us|/api-doc-bundle|/maker|/oauth2-server/src/Oro/Bundle/OAuth2ServerBundle/Controller/ClientController.php)"
ORO_TESTS_PATH="${ORO_TESTS_PATH-vendor/oro}"
# Variable for fix work with new php-8.2
export PHP_CS_FIXER_IGNORE_ENV=1

run() {
    local LOGS
    if [[ ! -d "$APP_SRC" ]]; then
        echo "ERROR: Can't find source"
        exit 1
    fi
    # Detect workdir if empty
    if [[ "X$WORKDIR" == "X" ]]; then
        if [[ "$(basename "$(dirname "$APP_SRC")")" == "application" ]]; then
            WORKDIR="$(dirname "$(dirname "$APP_SRC")")"
        else
            WORKDIR=$APP_SRC
        fi
    fi
    # shellcheck disable=SC1091
    [[ -f "$APP_SRC/.env-build" ]] && . "$APP_SRC/.env-build"
    # shellcheck disable=SC1090
    [[ -f "$DOT_ENV_BUILD" ]] && . "$DOT_ENV_BUILD"
    LOGS="$APP_SRC/var/logs"
    if [[ ! -e $HOME/.parallel/ignored_vars ]]; then
        mkdir -p "$HOME/.parallel"
        docker run --pull always --security-opt label=disable --rm -u "$(id -u):$(id -g)" -v "/etc/group:/etc/group:ro" -v "/etc/passwd:/etc/passwd:ro" -v "/etc/shadow:/etc/shadow:ro" -v "${HOME}":"${HOME}" "$ORO_PUBLIC_PROJECT/builder:$BASELINE_VERSION" parallel --record-env
    fi
    if [[ -e "$LOGS/$FILE_DIFF" ]]; then
        pushd "$WORKDIR" >/dev/null 2>&1 || {
            echo "Can't enter to folder $WORKDIR"
            exit 1
        }
        echo "Found $LOGS/$FILE_DIFF and use it for create \"$LOGS/$DIFF_PHP\""
        echo "grep '^package.*\.php$' \"$LOGS/$FILE_DIFF\" | grep -E -v \"$EXCLUDED_PACKAGES\" | xargs -ri bash -c 'test -f {} && echo {}' >\"$LOGS/$DIFF_PHP\""
        set +e
        grep '^package.*\.php$' "$LOGS/$FILE_DIFF" | grep -E -v "$EXCLUDED_PACKAGES" | xargs -ri bash -c 'test -f {} && echo {}' >"$LOGS/$DIFF_PHP"
        set -e
        popd >/dev/null 2>&1 || {
            echo "Can't exit from folder $WORKDIR"
            exit 1
        }
        ORO_APP_FOLDER="$WORKDIR"
    else
        pushd "$APP_SRC" >/dev/null 2>&1 || {
            echo "Can't enter to folder $APP_SRC"
            exit 1
        }
        echo "find -L \"$ORO_TESTS_PATH\" -type f -iname '*.php' | grep -E -v \"$EXCLUDED_PACKAGES\" | uniq | sort > \"$LOGS/$DIFF_PHP\""
        find -L "$ORO_TESTS_PATH" -type f -iname '*.php' | grep -E -v "$EXCLUDED_PACKAGES" | uniq | sort >"$LOGS/$DIFF_PHP"
        popd >/dev/null 2>&1 || {
            echo "Can't exit from folder $APP_SRC"
            exit 1
        }
        ORO_APP_FOLDER="$APP_SRC"
    fi
    if [[ ! -s "$LOGS/$DIFF_PHP" ]]; then
        echo "Diff $LOGS/$DIFF_PHP is empty. Nothing to check"
        exit 0
    fi
    mkdir -p "$LOGS/static_analysis"
    set -x
    docker run --pull always --security-opt label=disable --tmpfs /tmp --rm -u "$(id -u):$(id -g)" -e PHP_CS_FIXER_IGNORE_ENV -v "/etc/group:/etc/group:ro" -v "/etc/passwd:/etc/passwd:ro" -v "/etc/shadow:/etc/shadow:ro" -v "${HOME}":"${HOME}":ro -v "$WORKDIR":"$WORKDIR" -v "$APP_SRC":"$APP_SRC" -v "$LOGS":"$APP_SRC/var/logs" -w "$ORO_APP_FOLDER" "$ORO_PUBLIC_PROJECT/builder:$BASELINE_VERSION" bash -c "time parallel --no-notice --gnu -k --lb --env _ --xargs --joblog '$APP_SRC/var/logs/parallel.csfixer.log' -a '$APP_SRC/var/logs/$DIFF_PHP' \"'$APP_SRC/bin/php-cs-fixer' fix {} --verbose --dry-run --config='$APP_SRC/$BUILD_CONFIG/.php-cs-fixer.php' --format=checkstyle --diff 2> /dev/null | tee -a '$APP_SRC/var/logs/static_analysis/php-cs-fixer_{#}.xml' | grep 'file name=\|error severity='; [[ \\\${PIPESTATUS[0]} -eq 0 ]] || exit \\\${PIPESTATUS[0]}\"" || {
        echo -e "${RED}ERROR to run php-cs-fixer${NC}"
        exit 1
    }
}

usage() {
    [ -z "$*" ] || echo "$*"
    echo "Try \`$PROGNAME --help' for more information." >&2
    exit 1
}

OPTIONS=$(getopt -q -n "$PROGNAME" -o hb:s:r: -l help,baseline:,source:,repositorypath: -- "$@")

eval set -- "$OPTIONS"

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
            APP_SRC="$(realpath "$1")"
        fi
        ;;
    -r | --repositorypath)
        shift
        if [[ "X$1" != "X" ]]; then
            WORKDIR="$1"
        fi
        ;;
    --)
        shift
        break
        ;;
    *)
        echo "ERROR: unrecognized option: $1"
        exit 1
        ;;
    esac
    shift
done

run
