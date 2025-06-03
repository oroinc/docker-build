#!/bin/bash

PROGNAME="${0##*/}"
RED='\033[1;31m'    # Red color
GREEN='\033[1;32m'  # Green color
NC='\033[0m'        # No Color

help() {
    local OPTIONS_SPEC="
$PROGNAME is a wrapper for running SCSS stylelint checkup

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
FILE_DIFF="diff.txt"
DIFF_JAVASCRIPT_STYLELINT="diff_javascript_stylelint.txt"
ALLOWED_SCSS_LIST="allowed_scss_list.txt"
ORO_PUBLIC_PROJECT=${ORO_PUBLIC_PROJECT-harborio.oro.cloud/oro-platform-public}

run() {
    local LOGS
    if [[ ! -d "$APP_SRC" ]]; then
        echo "ERROR: Can't find source"
        exit 1
    fi

    LOGS="$APP_SRC/var/logs"
    mkdir -p "$LOGS"
    : >"$LOGS/javascript_stylelint_output.log"
    : >"$LOGS/$DIFF_JAVASCRIPT_STYLELINT"
    : >"$LOGS/$ALLOWED_SCSS_LIST"

    set -x
    set -o pipefail

    docker run --pull always --security-opt label=disable --tmpfs /tmp --rm \
        -u "$(id -u):$(id -g)" \
        -v "/etc/group:/etc/group:ro" \
        -v "/etc/passwd:/etc/passwd:ro" \
        -v "/etc/shadow:/etc/shadow:ro" \
        -v "${HOME}":"${HOME}":ro \
        -v "$APP_SRC":"$APP_SRC" \
        -v "$LOGS":"$APP_SRC/var/logs" \
        -w "$APP_SRC" \
        --env LOGS="$LOGS" \
        --env ALLOWED_SCSS_LIST="$ALLOWED_SCSS_LIST" \
        "$ORO_PUBLIC_PROJECT/builder:$BASELINE_VERSION" \
        bash -c '
            EXCLUDE_PATTERNS=""
            while IFS= read -r pattern || [ -n "$pattern" ]; do
                [ -z "$pattern" ] && continue
                EXCLUDE_PATTERNS+=" -path \"$pattern\" -o"
            done < .stylelintignore

            EXCLUDE_EXPR="${EXCLUDE_PATTERNS% -o}"

            eval "find -L \"./vendor/oro\" -type f -iname \"*.scss\" -a ! \( $EXCLUDE_EXPR \)" | sort -u > "$LOGS/$ALLOWED_SCSS_LIST"
        '
    if [[ ! -s "$LOGS/$ALLOWED_SCSS_LIST" ]]; then
      echo -e "${RED}ERROR: '$LOGS/$ALLOWED_SCSS_LIST' is either missing or empty.${NC}"
      exit 1
    fi

    # Get .scss diff
    if [[ -e "$LOGS/$FILE_DIFF" ]]; then
        pushd "$WORKDIR" >/dev/null 2>&1 || {
            echo "Can't enter to folder $WORKDIR"
            exit 1
        }

        grep '^package/.*\.scss$' "$LOGS/$FILE_DIFF" \
        | awk '
            {
                split($0, parts, "/");
                pkg = parts[2];
                sub("^package/" pkg "/", "", $0);
                scss_path = $0;

                bundle_path = "./vendor/oro/" pkg "-bundle/" scss_path;
                plain_path  = "./vendor/oro/" pkg       "/" scss_path;

                print bundle_path;
                print plain_path;
            }
        ' \
        | grep -Fxf "$LOGS/$ALLOWED_SCSS_LIST" \
        > "$LOGS/$DIFF_JAVASCRIPT_STYLELINT"

        popd >/dev/null 2>&1 || {
            echo "Can't exit from folder $WORKDIR"
            exit 1
        }
    else
      mv "$LOGS/$ALLOWED_SCSS_LIST" "$LOGS/$DIFF_JAVASCRIPT_STYLELINT"
    fi

    if [[ ! -s "$LOGS/$DIFF_JAVASCRIPT_STYLELINT" ]]; then
        echo -e "${GREEN}Diff $LOGS/$DIFF_JAVASCRIPT_STYLELINT is empty. Nothing to check.${NC}"
        exit 0
    fi

    echo "npm run stylelint-oro"

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
        bash -c "parallel && time parallel --no-notice --gnu -k --lb --xargs \
          --joblog \"$APP_SRC/var/logs/parallel.stylelint.log\" -a \"$LOGS/$DIFF_JAVASCRIPT_STYLELINT\" \
          \"$APP_SRC/node_modules/.bin/stylelint\" {} \
          --config=\"$APP_SRC/.stylelintrc.yml\" \
          --ignore-path \"$APP_SRC/.stylelintignore\" 2>&1" | tee "$LOGS/javascript_stylelint_output.log"

    [[ ${PIPESTATUS[0]} -eq 0 ]] || {
        echo -e "${RED}PROBLEM. Stylelint check failed.${NC}"
        exit 1
    }

    echo -e "${GREEN}Stylelint check passed successfully. No problems found.${NC}"

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
