#!/bin/bash

PROGNAME="${0##*/}"
RED='\033[1;31m'    # Red color
GREEN='\033[1;32m'  # Green color
NC='\033[0m'        # No Color

help() {
    local OPTIONS_SPEC="
$PROGNAME is a wrapper for running behat CS analysis

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
WORKDIR=''
DIFF_FEATURE="diff_behat_wiring_cs.txt"
FILE_DIFF="diff.txt"
ALLOWED_FEATURES="allowed_features.txt"
ORO_PUBLIC_PROJECT=${ORO_PUBLIC_PROJECT-harborio.oro.cloud/oro-platform-public}

run() {
    local LOGS
    if [[ ! -d "$APP_SRC" ]]; then
        echo "ERROR: Can't find source"
        exit 1
    fi

    LOGS="$APP_SRC/var/logs"
    mkdir -p "$LOGS"
    : >"$LOGS/behat_wiring_cs_output.log"
    : >"$LOGS/$DIFF_FEATURE"
    : >"$LOGS/$ALLOWED_FEATURES"

    # Detect workdir if empty
    if [[ "X$WORKDIR" == "X" ]]; then
        if [[ "$(basename "$(dirname "$APP_SRC")")" == "application" ]]; then
            WORKDIR="$(dirname "$(dirname "$APP_SRC")")"
        else
            WORKDIR=$APP_SRC
        fi
    fi

    set +e
    set -x
    set -o pipefail

    # Get allowed files list
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
        bash -c "
            ORO_ENV=behat_test php '$APP_SRC/bin/behat' --available-features \
            > '$LOGS/$ALLOWED_FEATURES'"

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        echo -e "${RED}ERROR. Available features list creation failed (Docker exit code).${NC}"
        exit 1
    fi

    if [[ ! -s "$LOGS/$ALLOWED_FEATURES" ]]; then
        echo -e "${RED}ERROR. Available features list is empty or missing: $LOGS/$ALLOWED_FEATURES${NC}"
        exit 1
    fi

    # Get .feature diff
    if [[ -e "$LOGS/$FILE_DIFF" ]]; then
        pushd "$WORKDIR" >/dev/null 2>&1 || {
            echo "Can't enter to folder $WORKDIR"
            exit 1
        }

        grep '^package/.*\.feature$' "$LOGS/$FILE_DIFF" \
        | awk -v app_src="$APP_SRC" '
          {
            split($0, parts, "/");
            pkg = parts[2];
            sub("^package/" pkg "/", "", $0);
            feature_path = $0;

            bundle_path = app_src "/vendor/oro/" pkg "-bundle/" feature_path;
            plain_path  = app_src "/vendor/oro/" pkg       "/" feature_path;

            print bundle_path;
            print plain_path;
          }
        ' \
        | grep -Fxf "$LOGS/$ALLOWED_FEATURES" \
        > "$LOGS/$DIFF_FEATURE"

        popd >/dev/null 2>&1 || {
            echo "Can't exit from folder $WORKDIR"
            exit 1
        }
    else
      mv "$LOGS/$ALLOWED_FEATURES" "$LOGS/$DIFF_FEATURE"
    fi

#    if [[ -f "$LOGS/$ALLOWED_FEATURES" ]]; then
#        rm "$LOGS/$ALLOWED_FEATURES"
#    fi

    if [[ ! -s "$LOGS/$DIFF_FEATURE" ]]; then
        echo -e "${GREEN}Diff $LOGS/$DIFF_FEATURE is empty. Nothing to check.${NC}"
        exit 0
    fi

    # Run Behat CS checkup
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
        bash -c "
            parallel && time parallel --no-notice --gnu -k --lb --xargs -n1 \
            --joblog \"$LOGS/parallel.behat_wiring_cs.log\" -a \"$LOGS/$DIFF_FEATURE\" \
            ORO_ENV=behat_test php '$APP_SRC/bin/behat' -c '$APP_SRC/behat.yml.dist' \
            --colors --check=cs \
            -f progress {}" \
            2>&1 | tee "$LOGS/behat_wiring_cs_output.log"

    [[ ${PIPESTATUS[0]} -eq 0 ]] || {
        echo -e "${RED}ERROR. Behat wiring CS check failed.${NC}"
        exit 1
    }

    echo -e "${GREEN}Behat wiring CS check passed successfully. No errors found.${NC}"

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
