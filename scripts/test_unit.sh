#!/bin/bash
#  Script wraps execution of PHPUnit
set -e
PROGNAME="${0##*/}"
RED='\033[1;31m' # Red color
NC='\033[0m'     # No Color

help() {
    local OPTIONS_SPEC="\

$PROGNAME is a wrapper for phpunit installed in container that allow to isolate host dependencies

$PROGNAME [options] [-- '<options for phpunit>']

options:

-h  | --help            this help
-b  | --baseline        docker images baseline version
-s  | --source          application source floder. default is current folder
<option for phpunit>    any option for phpunit. If empty run test for all find folders with path **Tests/Unit**

Example: $PROGNAME vendor/oro/platform/src/Oro/Component/Config/Tests/Unit/Loader

Supported environments variables. All variables can set in order from .env file, then from source folder .env-build and finaly from variable DOT_ENV_BUILD.

ORO_TESTS_PATH         folder for search unit tests. Default is vendor/oro

"
    echo "$OPTIONS_SPEC"

}

BASELINE_VERSION='master-latest'
APP_SRC="$PWD"
ORO_PUBLIC_PROJECT=${ORO_PUBLIC_PROJECT-harborio.oro.cloud/oro-platform-public}
ORO_TESTS_PATH="${ORO_TESTS_PATH:-vendor/oro}"
ORO_TEST_SUTE_UNIT=${ORO_TEST_SUTE_UNIT-unit}
UNIT_ARGS=''
# export XDG_DATA_HOME=/tmp

run() {
    local LOGS
    if [[ -d "$APP_SRC" ]]; then
        echo "Found sources in folder $APP_SRC"
    else
        echo "ERROR: Can't find source"
        exit 1
    fi
    # shellcheck disable=SC1091
    [[ -f "$APP_SRC/.env-build" ]] && . "$APP_SRC/.env-build"
    # shellcheck disable=SC1090
    [[ -f "$DOT_ENV_BUILD" ]] && . "$DOT_ENV_BUILD"
    LOGS="$APP_SRC/var/logs"
    mkdir -p "$LOGS"
    if [[ ! -e $HOME/.parallel/ignored_vars ]]; then
        mkdir -p "$HOME/.parallel"
        docker run --pull always --security-opt label=disable --rm -u "$(id -u):$(id -g)" -v "/etc/group:/etc/group:ro" -v "/etc/passwd:/etc/passwd:ro" -v "/etc/shadow:/etc/shadow:ro" -v "${HOME}":"${HOME}" "$ORO_PUBLIC_PROJECT/builder:$BASELINE_VERSION" parallel --record-env
    fi
    if [[ "X$UNIT_ARGS" == "X" ]]; then
        :>"$LOGS/phpunit_errors.log"
        pushd "$APP_SRC" >/dev/null 2>&1 || {
            echo "Can't enter to folder $APP_SRC"
            exit 1
        }
        find "$ORO_TESTS_PATH" -type f -path "**Tests/Unit**" -name '*Test.php' -print0 | xargs -0 dirname | sort -u >"$LOGS/unitList.txt"
        popd >/dev/null 2>&1 || {
            echo "Can't exit from folder $APP_SRC"
            exit 1
        }
        set -x
        docker run --pull always --security-opt label=disable --tmpfs /tmp --rm -u "$(id -u):$(id -g)" -v "/etc/group:/etc/group:ro" -v "/etc/passwd:/etc/passwd:ro" -v "/etc/shadow:/etc/shadow:ro" -v "${HOME}":"${HOME}":ro -v "$APP_SRC":"$APP_SRC" -v "$LOGS":"$APP_SRC/var/logs" -w "$APP_SRC" "$ORO_PUBLIC_PROJECT/builder:$BASELINE_VERSION" bash -c "time parallel --compress --no-notice --gnu -k --lb --env _  --joblog '$APP_SRC/var/logs/parallel.unit.log' -a '$APP_SRC/var/logs/unitList.txt' \"export TMPDIR=\\\$(mktemp -d --tmpdir=/tmp unit.XXXXXXXXXXXXXXXXX) && bin/phpunit --testsuite=$ORO_TEST_SUTE_UNIT --colors=always --cache-result-file='/tmp/.phpunit.result.cache' --log-junit='$APP_SRC/var/logs/junit/unit{#}.xml' {} >'$APP_SRC/var/logs/phpunit_output_{%}.log' 2>&1 ; [[ \\\${PIPESTATUS[0]} -eq 0 ]] && cat '$APP_SRC/var/logs/phpunit_output_{%}.log' || { cat '$APP_SRC/var/logs/phpunit_output_{%}.log' >> '$APP_SRC/var/logs/phpunit_errors.log' ; exit 1 ; } \"" || {
            echo "=============Errors output =============="
            cat "$LOGS/phpunit_errors.log"
            rm -rf "$LOGS"/phpunit_output_*
            echo -e "${RED}ERROR to run phpunit${NC}"
            exit 1
        }
        rm -rf "$LOGS"/phpunit_output_*
    else
        set -x
        docker run --pull always --security-opt label=disable --rm --tmpfs /tmp -u "$(id -u):$(id -g)" -v "/etc/group:/etc/group:ro" -v "/etc/passwd:/etc/passwd:ro" -v "/etc/shadow:/etc/shadow:ro" -v "${HOME}":"${HOME}":ro -v "$APP_SRC":"$APP_SRC" -v "$LOGS":"$APP_SRC/var/logs" -w "$APP_SRC" "$ORO_PUBLIC_PROJECT/builder:$BASELINE_VERSION" bash -c "bin/phpunit --testsuite=$ORO_TEST_SUTE_UNIT --colors=always --cache-result-file='/tmp/.phpunit.result.cache' --log-junit='$APP_SRC/var/logs/junit/unit.xml' $UNIT_ARGS" || {
            echo -e "${RED}ERROR to run phpunit${NC}"
            exit 1
        }
    fi
}

usage() {
    [ -z "$*" ] || echo "$*"
    echo "Try \`$PROGNAME --help' for more information." >&2
    exit 1
}

set +e
OPTIONS=$(getopt -q -n "$PROGNAME" -o hb:s:t: -l help,baseline:,source:test: -- "$@")
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
            APP_SRC="$(realpath "$1")"
        fi
        ;;
    --)
        shift
        if [[ "X$1" != "X" ]]; then
            UNIT_ARGS="$*"
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

run
