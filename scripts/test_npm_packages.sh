#!/bin/bash

PROGNAME="${0##*/}"
RED='\033[1;31m'    # Red color
GREEN='\033[1;32m'  # Green color
NC='\033[0m'        # No Color

help() {
    local OPTIONS_SPEC="
$PROGNAME runs ESLint/Stylelint and type-check on the npm-package/* projects
inside the Oro builder image.

$PROGNAME [options]

options:

-h                     | --help                        this help
-b                     | --baseline                    docker images baseline version
-s                     | --source                      application source folder. default is current folder
-r <folder>            | --repositorypath=<folder>     monorepo root. default is auto-detected from --source
"
    echo "$OPTIONS_SPEC"
}

BASELINE_VERSION='master-latest'
APP_SRC="$PWD"
ORO_PUBLIC_PROJECT=${ORO_PUBLIC_PROJECT-harborio.oro.cloud/oro-platform-public}
WORKDIR=''
ISOLATED=''

run() {
    local LOGS XDG_BASE
    if [[ ! -d "$APP_SRC" ]]; then
        echo "ERROR: Can't find source"
        exit 1
    fi
    APP_SRC=$(realpath "$APP_SRC")
    # Detect workdir (monorepo root) if empty. The cs stage runs this from the application
    # dir (e.g. application/commerce-crm-ee); the npm-package/* projects live at the monorepo
    # root, two levels up. Same idiom as test_phpcs.sh / composer.sh.
    if [[ "X$WORKDIR" == "X" ]]; then
        if [[ "$(basename "$(dirname "$APP_SRC")")" == "application" ]]; then
            WORKDIR="$(dirname "$(dirname "$APP_SRC")")"
        else
            WORKDIR=$APP_SRC
        fi
    fi
    if [[ ! -f "$WORKDIR/npm-package/pnpm-workspace.yaml" ]]; then
        echo "ERROR: Could not locate the monorepo root (npm-package/pnpm-workspace.yaml); resolved WORKDIR='$WORKDIR'"
        exit 1
    fi

    LOGS="$APP_SRC/var/logs"
    mkdir -p "$LOGS/junit"
    find "$LOGS/junit" -name "npm-packages-*.xml" ! -name "npm-packages-browser-*.xml" -delete
    rm -rf "$LOGS/commerce-ui-storybook"
    : >"$LOGS/npm_packages_output.log"

    # HOME is mounted read-only, but pnpm needs writable dirs for its self-installed
    # version (packageManager pin), store, and cache. Constraints: not /tmp (docker
    # --tmpfs is noexec and capped at 64M, the downloaded pnpm binary can't run), and
    # not a path inside the workspace mount (pnpm's self-switch would find the root
    # package.json packageManager pin above its temp dir and recurse forever). So the
    # host dir lives under the workspace, but it is mounted at /xdg in the container.
    XDG_BASE="$WORKDIR/var/cache/xdg"
    mkdir -p "$XDG_BASE"/{data,cache,config,state}

    # The cs checks (validate_css, javascript_stylelint) run in parallel against this same
    # WORKDIR and resolve application/*/node_modules. A "pnpm install" at WORKDIR re-links
    # those app members to a freshly created workspace-root store, which breaks validate_css.
    # Assemble a throwaway workspace with only the npm members (no application/**) and run the
    # install + lint there, so pnpm never touches the shared app tree the other checks read.
    ISOLATED="$WORKDIR/var/npm-iso"
    # remove the scratch on every exit path, including early failure and interrupts
    trap 'rm -rf "$ISOLATED"' EXIT INT TERM
    rm -rf "$ISOLATED"
    mkdir -p "$ISOLATED"
    if ! rsync -a --exclude 'node_modules' "$WORKDIR/npm-package/" "$ISOLATED/npm-package/"; then
        echo "ERROR: failed to assemble isolated npm workspace at $ISOLATED"
        exit 1
    fi

    set -x
    set -o pipefail

    docker run --pull always --security-opt label=disable --tmpfs /tmp --rm \
        -u "$(id -u):$(id -g)" \
        -v "/etc/group:/etc/group:ro" \
        -v "/etc/passwd:/etc/passwd:ro" \
        -v "/etc/shadow:/etc/shadow:ro" \
        -v "${HOME}":"${HOME}":ro \
        -v "$ISOLATED":"$ISOLATED" \
        -v "$LOGS":/reports \
        -v "$XDG_BASE":/xdg \
        -w "$ISOLATED" \
        --env XDG_DATA_HOME=/xdg/data \
        --env XDG_CACHE_HOME=/xdg/cache \
        --env XDG_CONFIG_HOME=/xdg/config \
        --env XDG_STATE_HOME=/xdg/state \
        "$ORO_PUBLIC_PROJECT/builder:$BASELINE_VERSION" \
        bash -c '
            set -u
            STATUS=0
            FAILED_CHECKS=()
            check() {
                echo "::: running: $* :::"
                if ! "$@"; then
                    echo "::: FAILED: $* :::"
                    STATUS=1
                    FAILED_CHECKS+=("$*")
                fi
            }

            # Environment report: one place to diagnose CI-only failures from the log.
            echo "::: debug: node=$(node -v 2>&1) id=$(id) pwd=$PWD :::"
            echo "::: debug: pnpm=$(pnpm -v 2>&1 || true) :::"
            df -h "$PWD" /tmp 2>/dev/null | sed "s/^/::: debug: /"
            mount 2>/dev/null | grep -E "$PWD|/tmp" | sed "s/^/::: debug: /"

            # Fail loudly if the workspace root is wrong: pnpm treats a no-match
            # --filter as success (exit 0), so a bad root would otherwise pass green.
            for pkg in nuxt-storefront commerce-ui validation storefront-json-api-sdk json-api-sdk-generator nuxt-modules/csrf nuxt-modules/lighthouse nuxt-modules/oroapi-sdk-resolver; do
                if [ ! -d "npm-package/$pkg" ]; then
                    echo "::: ERROR: npm-package/$pkg not found under $PWD — wrong workspace root? :::"
                    exit 1
                fi
            done

            # --ignore-scripts: lint/type-check needs no lifecycle hooks, and they fail
            # on a fresh checkout (nuxt prepare needs a built commerce-ui dist/).
            # NOTE: this whole block runs inside single quotes - no apostrophes here.
            pnpm --dir npm-package install --frozen-lockfile --ignore-scripts || exit 1

            # Checks grouped per package - each runs only the scripts it
            # defines. To cover a new package, append a block below.

            check pnpm --dir npm-package/validation run build
            check pnpm --dir npm-package/validation run eslint
            check pnpm --dir npm-package/validation run type-check
            check pnpm --dir npm-package/validation run test \
                --reporter=default --reporter=junit --outputFile.junit=/reports/junit/npm-packages-validation.xml

            check env NODE_OPTIONS="--test-reporter=spec --test-reporter-destination=stdout --test-reporter=junit --test-reporter-destination=/reports/junit/npm-packages-stylelint-config.xml" \
                pnpm --dir npm-package/stylelint-config run test

            check pnpm --dir npm-package/commerce-ui run eslint
            check pnpm --dir npm-package/commerce-ui run stylelint
            check pnpm --dir npm-package/commerce-ui run type-check
            # commerce-ui tests run in test_npm_packages_browser.sh
            check pnpm --dir npm-package/commerce-ui run build
            check env NODE_OPTIONS=--max-old-space-size=4096 pnpm --dir npm-package/commerce-ui run build-storybook --output-dir /reports/commerce-ui-storybook

            check pnpm --dir npm-package/commerce-ui-nuxt run build
            check pnpm --dir npm-package/commerce-ui-nuxt run eslint
            check pnpm --dir npm-package/commerce-ui-nuxt run type-check
            check pnpm --dir npm-package/commerce-ui-nuxt run test \
                --reporter=default --reporter=junit --outputFile.junit=/reports/junit/npm-packages-commerce-ui-nuxt.xml

            check pnpm --dir npm-package/nuxt-modules/csrf run build
            check pnpm --dir npm-package/nuxt-modules/csrf run eslint
            check pnpm --dir npm-package/nuxt-modules/csrf run type-check
            check pnpm --dir npm-package/nuxt-modules/csrf run test \
                --reporter=default --reporter=junit --outputFile.junit=/reports/junit/npm-packages-nuxt-csrf.xml

            check pnpm --dir npm-package/nuxt-modules/lighthouse run build
            check pnpm --dir npm-package/nuxt-modules/lighthouse run eslint
            check pnpm --dir npm-package/nuxt-modules/lighthouse run type-check
            check pnpm --dir npm-package/nuxt-modules/lighthouse run test \
                --reporter=default --reporter=junit --outputFile.junit=/reports/junit/npm-packages-nuxt-lighthouse.xml

            check pnpm --dir npm-package/nuxt-modules/oroapi-sdk-resolver run build
            check pnpm --dir npm-package/nuxt-modules/oroapi-sdk-resolver run eslint
            check pnpm --dir npm-package/nuxt-modules/oroapi-sdk-resolver run type-check
            check pnpm --dir npm-package/nuxt-modules/oroapi-sdk-resolver run test \
                --reporter=default --reporter=junit --outputFile.junit=/reports/junit/npm-packages-nuxt-oroapi-sdk-resolver.xml

            check pnpm --dir npm-package/storefront-json-api-sdk run eslint

            check pnpm --dir npm-package/json-api-sdk-generator run eslint

            check pnpm --dir npm-package/nuxt-storefront run eslint
            check pnpm --dir npm-package/nuxt-storefront run stylelint

            if [ "${#FAILED_CHECKS[@]}" -gt 0 ]; then
                echo "::: summary: ${#FAILED_CHECKS[@]} check(s) failed :::"
                printf "::: FAILED: %s :::\n" "${FAILED_CHECKS[@]}"
            else
                echo "::: summary: all checks passed :::"
            fi

            exit $STATUS
        ' 2>&1 | tee "$LOGS/npm_packages_output.log"

    local rc=${PIPESTATUS[0]}
    if [[ $rc -eq 0 ]]; then
        echo -e "${GREEN}npm-package lint/type-check passed.${NC}"
    else
        echo -e "${RED}PROBLEM. npm-package lint/type-check failed.${NC}"
        echo "Reports saved next to npm_packages_output.log: junit/npm-packages-*.xml, commerce-ui-storybook/"
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
