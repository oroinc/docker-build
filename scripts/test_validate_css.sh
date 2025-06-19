#!/bin/bash

PROGNAME="${0##*/}"
RED='\033[1;31m'    # Red color
GREEN='\033[1;32m'  # Green color
NC='\033[0m'        # No Color

help() {
    local OPTIONS_SPEC="
$PROGNAME is a wrapper for validating compiled CSS files using Stylelint.

$PROGNAME [options]

options:

-h                     | --help                        this help
-b                     | --baseline                    docker images baseline version
-s                     | --source                      application source folder. default is current folder

Example: $PROGNAME

Supported environment variables:
"
    echo "$OPTIONS_SPEC"
}

BASELINE_VERSION='master-latest'
APP_SRC="$PWD"
ORO_PUBLIC_PROJECT=${ORO_PUBLIC_PROJECT-harborio.oro.cloud/oro-platform-public}

run() {
    local LOGS
    if [[ ! -d "$APP_SRC" ]]; then
        echo "ERROR: Can't find source"
        exit 1
    fi

    LOGS="$APP_SRC/var/logs"
    mkdir -p "$LOGS"
    : >"$LOGS/validate_css_output.log"

    set -x
    set -o pipefail

    echo "npm run build"

    docker run --security-opt label=disable --tmpfs /tmp --rm \
        -u "$(id -u):$(id -g)" \
        -v "/etc/group:/etc/group:ro" \
        -v "/etc/passwd:/etc/passwd:ro" \
        -v "/etc/shadow:/etc/shadow:ro" \
        -v "${HOME}":"${HOME}":ro \
        -v "$APP_SRC":"$APP_SRC" \
        -v "$LOGS":"$APP_SRC/var/logs" \
        -w "$APP_SRC" \
        "$ORO_PUBLIC_PROJECT/builder:$BASELINE_VERSION" \
        bash -c "\"$APP_SRC/node_modules/.bin/webpack\" --mode=production" \
                2>&1 | tee "$LOGS/validate_css_output.log"

    [[ ${PIPESTATUS[0]} -eq 0 ]] || {
        echo -e "${RED}ERROR. npm run build failed.${NC}"
        exit 1
    }

    echo -e "${GREEN}npm run build successfully${NC}"
    echo -e "${GREEN}running npm run validate-css${NC}"

    docker run --security-opt label=disable --tmpfs /tmp --rm \
        -u "$(id -u):$(id -g)" \
        -v "/etc/group:/etc/group:ro" \
        -v "/etc/passwd:/etc/passwd:ro" \
        -v "/etc/shadow:/etc/shadow:ro" \
        -v "${HOME}":"${HOME}":ro \
        -v "$APP_SRC":"$APP_SRC" \
        -v "$LOGS":"$APP_SRC/var/logs" \
        -w "$APP_SRC" \
        "$ORO_PUBLIC_PROJECT/builder:$BASELINE_VERSION" \
        bash -c "\"$APP_SRC/node_modules/.bin/stylelint\" \
                  --config=\"$APP_SRC/.stylelintrc-css.yml\" \
                  --ignore-path=\"$APP_SRC/.stylelintignore-css\" \
                  \"$APP_SRC/public/build/**/*.css\"" \
                2>&1 | tee "$LOGS/validate_css_output.log"

    [[ ${PIPESTATUS[0]} -eq 0 ]] || {
        echo -e "${RED}PROBLEM. CSS validation failed.${NC}"
        exit 1
    }

    echo -e "${GREEN}CSS validation passed successfully. No problems found.${NC}"

    [[ $DEBUG ]] || set +x
}

usage() {
    [ -z "$*" ] || echo "$*"
    echo "Try \`$PROGNAME --help' for more information." >&2
    exit 1
}

OPTIONS=$(getopt -q -n "$PROGNAME" -o hb:s: -l help,baseline:,source: -- "$@")

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
set -e
