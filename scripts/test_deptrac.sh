#!/bin/bash

set -e
PROGNAME="${0##*/}"
RED='\033[1;31m'    # Red color
GREEN='\033[1;32m'  # Green color
NC='\033[0m'        # No Color

help() {
    local OPTIONS_SPEC="
$PROGNAME is a wrapper for running deptrac analysis

$PROGNAME [options]

options:

-h                     | --help                        this help
-b                     | --baseline                    docker images baseline version
-s                     | --source                      application source folder. default is current folder

Example: $PROGNAME

Supported environment variables:

BUILD_CONFIG           folder where deptrac config is located. Default is vendor/oro/platform/build
"
    echo "$OPTIONS_SPEC"
}

BASELINE_VERSION='master-latest'
APP_SRC="$PWD"
ORO_PUBLIC_PROJECT=${ORO_PUBLIC_PROJECT-harborio.oro.cloud/oro-platform-public}
BUILD_CONFIG="${BUILD_CONFIG-vendor/oro/platform/build}"

run() {
    local LOGS
    if [[ ! -d "$APP_SRC" ]]; then
        echo "ERROR: Can't find source"
        exit 1
    fi

    LOGS="$APP_SRC/var/logs"
    mkdir -p "$LOGS"
    : >"$LOGS/deptrac_output.log"

    set -x
    docker run --pull always --security-opt label=disable --tmpfs /tmp --rm \
        -u "$(id -u):$(id -g)" \
        -v "/etc/group:/etc/group:ro" \
        -v "/etc/passwd:/etc/passwd:ro" \
        -v "/etc/shadow:/etc/shadow:ro" \
        -v "${HOME}":"${HOME}":ro \
        -v "$APP_SRC":"$APP_SRC" \
        -v "$LOGS":"$APP_SRC/var/logs" \
        -w "$APP_SRC" \
        "$ORO_PUBLIC_PROJECT/builder:$BASELINE_VERSION" \
        bash -c "php '$APP_SRC/bin/deptrac' analyze --config-file='$APP_SRC/$BUILD_CONFIG/deptrac.yaml' --no-cache --formatter=junit --output='$APP_SRC/var/logs/deptrac.xml'" | tee "$LOGS/deptrac_output.log"

    if [[ ! -f "$APP_SRC/var/logs/deptrac.xml" ]]; then
        echo -e "${RED}ERROR: Deptrac run failed. Output file deptrac.xml not found${NC}"
        exit 1
    fi

    grep -v '<warning ' "$APP_SRC/var/logs/deptrac.xml" > "$APP_SRC/var/logs/filtered.xml"
    mv "$APP_SRC/var/logs/filtered.xml" "$APP_SRC/var/logs/junit/deptrac.xml"

    if grep -q '<failure' "$APP_SRC/var/logs/junit/deptrac.xml"; then
        echo -e "${RED}Deptrac check did not pass. Violations found!${NC}"
        exit 1
    fi

    echo -e "${GREEN}Deptrac check passed successfully. No violations found.${NC}"

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
