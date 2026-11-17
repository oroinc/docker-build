#!/bin/bash

PROGNAME="${0##*/}"
RED='\033[1;31m'    # Red color
GREEN='\033[1;32m'  # Green color
NC='\033[0m'        # No Color

help() {
    local OPTIONS_SPEC="
$PROGNAME checks the npmrc files for literal credentials and for registry lines that differ between the
workspaces that define a catalog (tool/check-npmrc.mjs) inside the Oro builder image.

$PROGNAME [options]

options:

-h                     | --help                        this help
-b                     | --baseline                    docker images baseline version
-s                     | --source                      application source folder. default is current folder
-r <folder>            | --repositorypath=<folder>     monorepo root. default is auto-detected from --source
"
    echo "$OPTIONS_SPEC"
}

BASELINE_VERSION='7.0-latest'
APP_SRC="$PWD"
ORO_PUBLIC_PROJECT=${ORO_PUBLIC_PROJECT-harborio.oro.cloud/oro-platform-public}
WORKDIR=''

run() {
    local LOGS
    if [[ ! -d "$APP_SRC" ]]; then
        echo "ERROR: Can't find source"
        exit 1
    fi
    APP_SRC=$(realpath "$APP_SRC")
    # Detect workdir (monorepo root) if empty
    if [[ "X$WORKDIR" == "X" ]]; then
        if [[ "$(basename "$(dirname "$APP_SRC")")" == "application" ]]; then
            WORKDIR="$(dirname "$(dirname "$APP_SRC")")"
        else
            WORKDIR=$APP_SRC
        fi
    fi
    if [[ ! -f "$WORKDIR/tool/check-npmrc.mjs" ]]; then
        echo "ERROR: Could not locate the monorepo root (tool/check-npmrc.mjs); resolved WORKDIR='$WORKDIR'"
        exit 1
    fi

    LOGS="$APP_SRC/var/logs"
    mkdir -p "$LOGS"
    : >"$LOGS/pnpm_config_output.log"

    set -x
    set -o pipefail

    # The checks only read the files that git lists, so the whole checkout is mounted read-only.
    docker run --pull always --security-opt label=disable --tmpfs /tmp --rm \
        -u "$(id -u):$(id -g)" \
        -v "/etc/group:/etc/group:ro" \
        -v "/etc/passwd:/etc/passwd:ro" \
        -v "/etc/shadow:/etc/shadow:ro" \
        -v "${HOME}":"${HOME}":ro \
        -v "$WORKDIR":"$WORKDIR":ro \
        -w "$WORKDIR" \
        "$ORO_PUBLIC_PROJECT/builder:$BASELINE_VERSION" \
        node tool/check-npmrc.mjs 2>&1 | tee "$LOGS/pnpm_config_output.log"

    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        echo -e "${GREEN}npmrc check passed.${NC}"
    else
        echo -e "${RED}PROBLEM. npmrc check failed.${NC}"
        exit 1
    fi

    [[ $DEBUG ]] || set +x
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
set -e
